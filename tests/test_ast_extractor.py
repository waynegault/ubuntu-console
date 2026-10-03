"""Tests for kgraph.ast_extractor — tree-sitter extraction and no-parser fallbacks."""

import os
import sys
import tempfile
import unittest
from unittest import mock

from _paths import SCRIPT_DIR
import kgraph

# `_paths` puts the repo's scripts/ on sys.path; assert the bootstrap ran
# rather than letting a later `import kgraph` fail with a confusing ImportError.
if not os.path.isdir(SCRIPT_DIR):
    raise RuntimeError(f"kgraph scripts/ dir not found: {SCRIPT_DIR}")


class TestAstExtractor(unittest.TestCase):
    """Exercise tree-sitter extraction on a synthetic repo.

    The parser is an optional extra; without it these tests skip rather than
    asserting parser output that cannot exist.
    """

    def setUp(self):
        if not kgraph.ast_available():
            self.skipTest("tree-sitter grammars not installed")
        td = tempfile.TemporaryDirectory()
        self.addCleanup(td.cleanup)
        self.root = td.name
        self._write("main.py", "import os\nimport helper\n\n"
                               "class Greeter:\n    pass\n\n"
                               "def hello(name):\n    print(name)\n    return len(name)\n\n"
                               "async def aio():\n    pass\n")
        self._write("helper.py", "def hello():\n    return 1\n")
        self._write("run.sh", "#!/bin/bash\nMY_VAR=1\ngreet() {\n  echo hi\n}\ngreet\n")
        self._write("pkg/mod.py", "def pkgfunc():\n    pass\n")
        self._write("pkg/sub/deep.py", "def deepfunc():\n    pass\n")
        self._write(".hidden/h.py", "def hiddenfunc():\n    pass\n")

    def _write(self, rel, text):
        path = os.path.join(self.root, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)

    def _ids(self, result):
        return {n["id"] for n in result["nodes"]}

    def _edges(self, result):
        return {(e["source"], e["target"], e["label"]) for e in result["edges"]}

    def test_extracts_python_definitions_imports_and_calls(self):
        result = kgraph.extract_repo_graph(self.root)
        ids = self._ids(result)
        # The fixture declares `class Greeter`.  Ids carry the language AND the name
        # verbatim, so this is ast_class:python:Greeter — not the old lowercased
        # 'greeter' slug, which also refused to round-trip.
        for nid in ("ast_file:main-py", "ast_func:python:hello", "ast_class:python:Greeter",
                    "ast_module:python:os", "ast_module:python:helper", "ast_call:python:print"):
            self.assertIn(nid, ids)
        edges = self._edges(result)
        for edge in (("ast_file:main-py", "ast_func:python:hello", "defines"),
                     ("ast_file:main-py", "ast_class:python:Greeter", "defines"),
                     ("ast_file:main-py", "ast_module:python:os", "imports"),
                     ("ast_file:main-py", "ast_call:python:print", "calls")):
            self.assertIn(edge, edges)
        by_id = {n["id"]: n for n in result["nodes"]}
        self.assertTrue(by_id["ast_func:python:aio"]["async"])
        self.assertFalse(by_id["ast_func:python:hello"]["async"])
        # Two identical calls collapse onto one node and one edge.
        self._write("twice.py", "def go():\n    pass\n\ngo()\ngo()\n")
        calls = [(e["source"], e["target"], e["label"])
                 for e in kgraph.extract_repo_graph(self.root)["edges"]
                 if e["source"] == "ast_file:twice-py" and e["label"] == "calls"]
        self.assertEqual(calls, [("ast_file:twice-py", "ast_call:python:go", "calls")])

    def test_extracts_bash_variables_imports_and_call_links(self):
        result = kgraph.extract_repo_graph(self.root, include_variables=True)
        self.assertIn("ast_func:bash:greet", self._ids(result))
        # The fixture declares MY_VAR.  Ids carry the language and keep the name verbatim
        # — case and underscores included — so this is ast_var:bash:MY_VAR, not the old
        # lowercased 'my-var' slug, which could not round-trip.
        self.assertIn("ast_var:bash:MY_VAR", self._ids(result))
        self.assertNotIn("ast_var:bash:MY_VAR", self._ids(kgraph.extract_repo_graph(self.root)))
        edges = self._edges(result)
        self.assertIn(("ast_file:run-sh", "ast_func:bash:greet", "defines"), edges)
        self.assertIn(("ast_module:python:helper", "ast_file:helper-py", "resolves_to"), edges)
        self.assertIn(("ast_call:bash:greet", "ast_func:bash:greet", "calls"), edges)
        # print() has no definition in the tree, so it stays unlinked — and a Python call
        # can only ever resolve to a Python definition, which is the point of the
        # language segment.
        self.assertNotIn(("ast_call:python:print", "ast_func:python:print", "calls"), edges)
        self.assertNotIn(("ast_call:python:print", "ast_func:bash:print", "calls"), edges)

    def test_maps_extra_extensions_and_skips_hidden_and_unreadable(self):
        self._write("script.zsh", "greet_zsh() {\n  echo hi\n}\n")
        self._write("thing.pyw", "def pywfunc():\n    pass\n")
        self._write("locked.py", "def locked():\n    pass\n")
        locked = os.path.join(self.root, "locked.py")
        os.chmod(locked, 0o000)
        self.addCleanup(os.chmod, locked, 0o644)
        ids = self._ids(kgraph.extract_repo_graph(self.root))
        self.assertIn("ast_func:bash:greet_zsh", ids)  # .zsh maps to the bash grammar
        self.assertIn("ast_func:python:pywfunc", ids)  # .pyw maps to the python grammar
        self.assertNotIn("ast_func:python:locked", ids)  # unreadable file is skipped
        self.assertIn("ast_func:python:hello", ids)  # other files still parse
        self.assertNotIn("ast_func:python:hiddenfunc", ids)  # .hidden/ is ignored

    def test_subdirs_max_files_empty_and_meta(self):
        subdirs = kgraph.extract_repo_graph(self.root, subdirs=["pkg"])
        self.assertIn("ast_func:python:pkgfunc", self._ids(subdirs))
        self.assertIn("ast_func:python:deepfunc", self._ids(subdirs))
        self.assertNotIn("ast_func:python:hello", self._ids(subdirs))
        self.assertEqual(kgraph.extract_repo_graph(self.root, max_files=1)["_meta"]["files_parsed"], 1)
        with tempfile.TemporaryDirectory() as empty:
            result = kgraph.extract_repo_graph(empty)
        self.assertEqual((result["nodes"], result["_meta"]["files_parsed"]), ([], 0))
        full = kgraph.extract_repo_graph(self.root)
        self.assertEqual((full["_meta"]["source"], set(full["_meta"]["languages"])),
                         ("ast", {"python", "bash"}))

    def test_skips_files_whose_grammar_is_not_loaded(self):
        from kgraph import ast_extractor
        with mock.patch.object(ast_extractor, "_LANGUAGES", {"bash": ast_extractor._LANGUAGES["bash"]}):
            ids = self._ids(kgraph.extract_repo_graph(self.root))
        self.assertNotIn("ast_func:python:hello", ids)  # python grammar dropped
        self.assertIn("ast_func:bash:greet", ids)


class TestAstExtractorWithoutParser(unittest.TestCase):
    def test_node_text_returns_empty_on_decode_failure(self):
        from kgraph import ast_extractor
        fake = type("N", (), {"start_byte": 0, "end_byte": 2})()
        self.assertEqual(ast_extractor._node_text(fake, b"\xff\xfe"), "")

    def test_ast_available_false_without_grammars(self):
        from kgraph import ast_extractor
        with mock.patch.object(ast_extractor, "_LANGUAGES", {}), \
                mock.patch.object(ast_extractor, "_load_grammars", return_value={}):
            self.assertFalse(ast_extractor.ast_available())

    def test_grammar_import_failure_disables_availability(self):
        from kgraph import ast_extractor
        with mock.patch.object(ast_extractor, "_LANGUAGES", {}), \
                mock.patch.object(ast_extractor, "_AST_AVAILABLE", True), \
                mock.patch.dict(sys.modules, {"tree_sitter_bash": None}):
            self.assertFalse(ast_extractor.ast_available())

    def test_extract_repo_graph_without_parser_returns_error(self):
        from kgraph import ast_extractor
        with mock.patch.object(ast_extractor, "_AST_AVAILABLE", False), \
                mock.patch.object(ast_extractor, "_LANGUAGES", {}):
            result = kgraph.extract_repo_graph("/tmp/does-not-exist-kgraph")
        self.assertEqual((result["nodes"], result["_meta"]["error"]), ([], "tree-sitter not available"))

    def test_extraction_helpers_guard_missing_grammars_and_languages(self):
        from kgraph import ast_extractor
        from kgraph.models import GraphBuilder
        builder = GraphBuilder()
        with mock.patch.object(ast_extractor, "_LANGUAGES", {}):
            ast_extractor._extract_bash_defs(None, b"", "a.sh", "f", builder, True, "file:a.sh")
            ast_extractor._extract_python_defs(None, b"", "a.py", "f", builder, True, "file:a.py")
            ast_extractor._extract_calls(None, b"", "python", "a.py", "f", builder, "file:a.py")
        self.assertEqual(builder.nodes_list, [])
        with mock.patch.object(ast_extractor, "_LANGUAGES", {"ruby": object()}):
            ast_extractor._extract_calls(None, b"", "ruby", "a.rb", "f", builder, "file:a.rb")
        self.assertEqual(builder.nodes_list, [])

    def test_link_call_defs_skips_unnamed_call_nodes(self):
        from kgraph import ast_extractor
        from kgraph.models import GraphBuilder
        builder = GraphBuilder()
        builder.add_node({"id": "ast_call:x", "label": "  ", "type": "call"})
        ast_extractor._link_call_defs(builder)
        self.assertFalse(builder.has_edge("ast_call:x", "ast_func:", "calls"))


if __name__ == "__main__":
    unittest.main()
