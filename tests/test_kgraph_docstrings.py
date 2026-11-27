"""Docstring edges: `documents`, first sentence, capped — and never a USE.

Wayne's rule (2026-11-27): "Go — docstrings only, first sentence, cap 120".

Each case names the wrong outcome it detects:

* a whole docstring as the label makes the node unreadable — this repo's run to hundreds
  of words;
* a docstring behind a shebang or a licence comment must still be found: tree-sitter
  parses those as siblings of the body, and Python's own rule skips past them;
* a `documents` edge counted as a USE would let documenting an uncalled function mark it
  alive, masking exactly the dead code the certification bar exists to find.
"""

from __future__ import annotations

import ast
from pathlib import Path

from kgraph.ast_extractor import _first_sentence, extract_repo_graph


def _docstrings(body: str):
    import tempfile

    root = Path(tempfile.mkdtemp())
    (root / "a.py").write_text(body, encoding="utf-8")
    graph = extract_repo_graph(str(root))
    docs = [(n["id"], n["label"]) for n in graph["nodes"] if n["type"] == "docstring"]
    edges = [(e["source"], e["target"], e["label"]) for e in graph["edges"] if e["label"] == "documents"]
    return docs, edges


def test_only_the_first_sentence_is_kept():
    """Detects: the whole docstring becoming the label."""
    assert _first_sentence("Do the thing. Then another clause follows.") == "Do the thing."


def test_a_period_inside_a_token_does_not_end_the_sentence():
    """Detects: `scripts/kgraph/html.py` truncated at `kgraph.`"""
    text = "Explain scripts/kgraph/html.py and its template. Second sentence."
    assert _first_sentence(text) == "Explain scripts/kgraph/html.py and its template."


def test_the_cap_truncates_with_an_ellipsis():
    """Detects: an over-long sentence kept whole."""
    out = _first_sentence("x" * 300, cap=120)
    assert len(out) == 120
    assert out.endswith("…")


def test_a_docstring_behind_a_shebang_is_found(tmp_path):
    """Detects: the tree-sitter trap — a leading comment skipped by Python but not here."""
    docs, edges = _docstrings(
        '#!/usr/bin/env python3\n"""Module doc."""\n\n\ndef f():\n    """Do it."""\n    return 1\n'
    )
    assert any(label == "Do it." for _, label in docs)
    assert any(target == "ast_func:python:f" for _, target, _ in edges)


def test_a_class_docstring_documents_the_class():
    """Detects: classes left undocumented while functions are covered."""
    docs, edges = _docstrings('class C:\n    """A thing."""\n    pass\n')
    assert any(target == "ast_class:python:C" for _, target, _ in edges)


def test_documents_is_not_counted_as_a_use():
    """Detects: documentation marking an uncalled function as called.

    The check is the audit's own rule — `calls`/`registers` are uses, `documents` is
    not — applied to the label tuple the audit exports, so this case fails if someone
    adds `documents` to it.
    """
    from tools import kgraph_deadcode_audit as audit

    source = Path(audit.__file__).read_text(encoding="utf-8")
    tree = ast.parse(source)
    uses: tuple[str, ...] | None = None
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign) and any(getattr(t, "id", "") == "_USE_LABELS" for t in node.targets):
            uses = tuple(ast.literal_eval(node.value))
    assert uses == ("calls", "registers"), f"a `documents` edge must never count as a use; got {uses}"
