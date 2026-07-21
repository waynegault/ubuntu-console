"""AST-based code-to-concept extraction using tree-sitter.

Extracts function/class/variable definitions, call graphs, and
file-level dependencies from source files (Bash, Python).
No API calls — deterministic, language-specific parsing.

Produces a ``Graph`` model with typed nodes and labelled edges,
suitable for merging into the main kgraph via ``GraphBuilder``.
"""

from __future__ import annotations

import logging
from pathlib import Path

from .models import Graph, GraphBuilder, slugify

logger = logging.getLogger(__name__)

_AST_AVAILABLE = False
try:
    from tree_sitter import Language, Parser, Query, QueryCursor
    _AST_AVAILABLE = True
except ImportError:
    Parser = None  # type: ignore[assignment,misc]

_LANGUAGES: dict[str, object] = {}


def _load_grammars() -> dict:
    """Lazy-load tree-sitter language grammars."""
    global _LANGUAGES, _AST_AVAILABLE
    if _LANGUAGES or not _AST_AVAILABLE:
        return _LANGUAGES
    try:
        import tree_sitter_bash
        import tree_sitter_python
        _LANGUAGES["bash"] = Language(tree_sitter_bash.language())
        _LANGUAGES["python"] = Language(tree_sitter_python.language())
    except ImportError:
        _AST_AVAILABLE = False
    return _LANGUAGES


# ── helpers ─────────────────────────────────────────────────────────────


def _query_captures(lang: Language, query_text: str, root_node) -> list[tuple]:
    """Run a tree-sitter query and return (node, capture_name) tuples."""
    q = Query(lang, query_text)
    cursor = QueryCursor(q)
    results = []
    for _pattern_index, captures_dict in cursor.matches(root_node):
        for cap_name, nodes in captures_dict.items():
            for node in nodes:
                results.append((node, cap_name))
    return results


def _node_text(node, code: bytes) -> str:
    try:
        return code[node.start_byte:node.end_byte].decode("utf-8")
    except (UnicodeDecodeError, IndexError) as exc:
        logger.warning("Failed to decode node text from source bytes: %s", exc)
        return ""


# ── file extension → language lookup ──────────────────────────────────

EXT_LANG = {
    ".sh": "bash",
    ".bash": "bash",
    ".zsh": "bash",
    ".py": "python",
    ".pyw": "python",
}

# ── Bash query patterns ───────────────────────────────────────────────

BASH_QUERIES = {
    "function_def": """
      (function_definition
        name: (word) @name
      ) @func
    """,
    "function_call": """
      (command_name
        (word) @call
      )
    """,
    "variable_def": """
      (variable_assignment
        name: (variable_name) @name
      ) @assign
    """,
}

# ── Python query patterns ────────────────────────────────────────────

PYTHON_QUERIES = {
    "function_def": """
      (function_definition
        name: (identifier) @name
      ) @func
    """,
    "class_def": """
      (class_definition
        name: (identifier) @name
      ) @class
    """,
    "import": """
      (import_statement
        name: (dotted_name) @module
      )
    """,
    "import_from": """
      (import_from_statement
        module_name: (dotted_name) @module
        name: (dotted_name) @name
      )
    """,
    "function_call": """
      (call
        function: (identifier) @call
      )
    """,
    "method_call": """
      (call
        function: (attribute
          attribute: (identifier) @call
        )
      )
    """,
}


# ── public API ────────────────────────────────────────────────────────


def ast_available() -> bool:
    """Return True when tree-sitter and grammars are installed."""
    _load_grammars()
    return _AST_AVAILABLE and bool(_LANGUAGES)


def extract_repo_graph(repo_root: str, **kwargs) -> dict:
    """Walk a repo directory and extract nodes/edges via AST.

    Returns a plain dict (``{'nodes': [...], 'edges': [...]}``) for
    backward compatibility with callers that merge via ``GraphBuilder``.
    """
    _load_grammars()
    if not _AST_AVAILABLE:
        return {"nodes": [], "edges": [], "_meta": {"error": "tree-sitter not available"}}

    include_variables = kwargs.get("include_variables", False)
    max_files = kwargs.get("max_files", 0)
    scan_subdirs = kwargs.get("subdirs")

    builder = GraphBuilder()

    # ── file discovery ──
    root = Path(repo_root).resolve()
    source_files: list[tuple[Path, str]] = []
    for ext, lang in EXT_LANG.items():
        for fpath in root.glob(f"**/*{ext}"):
            parts = fpath.relative_to(root).parts
            if any(p.startswith(".") or p in ("venv", "node_modules", "__pycache__", "dist", "build", ".git") for p in parts):
                continue
            if scan_subdirs:
                if not any(fpath.relative_to(root).as_posix().startswith(s) for s in scan_subdirs):
                    continue
            source_files.append((fpath, lang))

    if max_files and len(source_files) > max_files:
        source_files = source_files[:max_files]

    # ── per-file extraction ──
    parsers: dict[str, Parser] = {}
    file_node_ids: dict[str, str] = {}

    for fpath, lang in source_files:
        grammar_lang = _LANGUAGES.get(lang)
        if not grammar_lang:
            continue
        if lang not in parsers:
            parsers[lang] = Parser(grammar_lang)
        parser = parsers[lang]

        try:
            code = fpath.read_bytes()
        except OSError:
            continue

        rel_path = fpath.relative_to(root).as_posix()
        file_id = f"ast_file:{slugify(rel_path)}"
        file_node_ids[rel_path] = file_id

        builder.add_node({
            "id": file_id,
            "label": fpath.name,
            "type": "file",
            "path": str(fpath),
            "rel_path": rel_path,
            "language": lang,
            "source": "ast",
        })

        tree = parser.parse(code)
        root_node = tree.root_node

        if lang == "python":
            _extract_python_defs(root_node, code, rel_path, file_id, builder, include_variables)
        elif lang == "bash":
            _extract_bash_defs(root_node, code, rel_path, file_id, builder, include_variables)

        _extract_calls(root_node, code, lang, rel_path, file_id, builder)

    # ── inter-file refs from imports ──
    graph = builder.build()
    _resolve_import_edges(file_node_ids, graph, builder)
    graph = builder.build()

    result = graph.to_dict()
    result["_meta"] = {
        "source": "ast",
        "files_parsed": len(source_files),
        "languages": list({lang for _, lang in source_files}),
    }
    return result


# ── language-specific extraction helpers ──────────────────────────────


def _extract_bash_defs(root_node, code: bytes, rel_path: str, file_id: str,
                       builder: GraphBuilder, include_variables: bool) -> None:
    """Extract bash function definitions and variable assignments."""
    lang = _LANGUAGES.get("bash")
    if not lang:
        return

    for node, tag in _query_captures(lang, BASH_QUERIES["function_def"], root_node):
        if tag == "name":
            name = _node_text(node, code)
            if not name or not name.strip():
                continue
            nid = f"ast_func:{slugify(name)}"
            builder.add_node({
                "id": nid, "label": name.strip(), "type": "function",
                "language": "bash", "source": "ast", "file": rel_path,
                "confidence": "EXTRACTED",
            })
            builder.add_edge({"source": file_id, "target": nid, "label": "defines", "confidence": "EXTRACTED"})

    if include_variables:
        for node, tag in _query_captures(lang, BASH_QUERIES["variable_def"], root_node):
            if tag == "name":
                name = _node_text(node, code)
                if not name or not name.strip():
                    continue
                nid = f"ast_var:{slugify(name)}"
                builder.add_node({
                    "id": nid, "label": name.strip(), "type": "variable",
                    "language": "bash", "source": "ast", "confidence": "EXTRACTED",
                })
                builder.add_edge({"source": file_id, "target": nid, "label": "defines", "confidence": "EXTRACTED"})


def _extract_python_defs(root_node, code: bytes, rel_path: str, file_id: str,
                         builder: GraphBuilder, include_variables: bool) -> None:
    """Extract Python function and class definitions."""
    lang = _LANGUAGES.get("python")
    if not lang:
        return

    for node, tag in _query_captures(lang, PYTHON_QUERIES["function_def"], root_node):
        if tag == "name":
            name = _node_text(node, code)
            if not name or not name.strip():
                continue
            nid = f"ast_func:{slugify(name)}"
            parent = node.parent
            is_async = parent and parent.type == "function_definition" and any(
                c.type == "async" for c in parent.children
            )
            builder.add_node({
                "id": nid, "label": name.strip(), "type": "function",
                "language": "python", "source": "ast", "file": rel_path,
                "confidence": "EXTRACTED", "async": is_async,
            })
            builder.add_edge({"source": file_id, "target": nid, "label": "defines", "confidence": "EXTRACTED"})

    for node, tag in _query_captures(lang, PYTHON_QUERIES["class_def"], root_node):
        if tag == "name":
            name = _node_text(node, code)
            if not name or not name.strip():
                continue
            nid = f"ast_class:{slugify(name)}"
            builder.add_node({
                "id": nid, "label": name.strip(), "type": "class",
                "language": "python", "source": "ast", "file": rel_path,
                "confidence": "EXTRACTED",
            })
            builder.add_edge({"source": file_id, "target": nid, "label": "defines", "confidence": "EXTRACTED"})

    for query_key in ("import", "import_from"):
        for node, tag in _query_captures(lang, PYTHON_QUERIES[query_key], root_node):
            if tag == "module":
                module = _node_text(node, code)
                if module:
                    nid = f"ast_module:{slugify(module)}"
                    builder.add_node({
                        "id": nid, "label": module.strip(), "type": "module",
                        "language": "python", "source": "ast", "confidence": "EXTRACTED",
                    })
                    builder.add_edge({"source": file_id, "target": nid, "label": "imports", "confidence": "EXTRACTED"})


def _extract_calls(root_node, code: bytes, lang: str, rel_path: str,
                   file_id: str, builder: GraphBuilder) -> None:
    """Extract function/method call references."""
    grammar_lang = _LANGUAGES.get(lang)
    if not grammar_lang:
        return

    if lang == "python":
        queries = [PYTHON_QUERIES["function_call"], PYTHON_QUERIES["method_call"]]
    elif lang == "bash":
        queries = [BASH_QUERIES["function_call"]]
    else:
        return

    seen_calls: set[str] = set()
    for qtext in queries:
        for node, tag in _query_captures(grammar_lang, qtext, root_node):
            if tag != "call":
                continue
            name = _node_text(node, code)
            if not name or not name.strip() or name.strip() in seen_calls:
                continue
            seen_calls.add(name.strip())
            nid = f"ast_call:{slugify(name)}"
            builder.add_node({
                "id": nid, "label": name.strip(), "type": "call",
                "language": lang, "source": "ast", "confidence": "EXTRACTED",
            })
            builder.add_edge({"source": file_id, "target": nid, "label": "calls", "confidence": "EXTRACTED"})


def _resolve_import_edges(file_node_ids: dict[str, str], graph: Graph,
                          builder: GraphBuilder) -> None:
    """Connect import nodes to file nodes when module name matches path."""
    for n in graph.nodes:
        if n.type != "module":
            continue
        label = n.label.strip().lower()
        for rel_path, fid in file_node_ids.items():
            rel_stem = Path(rel_path).stem.lower().replace("-", "_")
            if label == rel_stem or label.endswith("." + rel_stem):
                builder.add_edge({"source": n.id, "target": fid, "label": "resolves_to", "confidence": "INFERRED"})
                break