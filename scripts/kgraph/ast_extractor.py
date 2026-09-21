"""AST-based code-to-concept extraction using tree-sitter.

Extracts function/class/variable definitions, call graphs, and
file-level dependencies from source files (Bash, Python).
No API calls — deterministic, language-specific parsing.

Produces a ``Graph`` model with typed nodes and labelled edges,
suitable for merging into the main kgraph via ``GraphBuilder``.
"""

from __future__ import annotations

import logging
import os
import re
from pathlib import Path
from typing import Any

from .models import Graph, GraphBuilder, slugify

logger = logging.getLogger(__name__)

_AST_AVAILABLE = False
# Pre-declared so the optional tree-sitter import can fall back to None
# without sprinkling `type: ignore` on every use site.
Language: Any
Parser: Any
Query: Any
QueryCursor: Any
try:
    from tree_sitter import Language, Parser, Query, QueryCursor
    _AST_AVAILABLE = True
except ImportError:
    _AST_AVAILABLE = False

_LANGUAGES: dict[str, Any] = {}


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
    except ImportError as exc:
        # A partial/absent grammar set disables AST extraction entirely; log it
        # so the graph silently losing all code nodes is visible.
        logger.warning("tree-sitter grammars unavailable (%s); AST extraction disabled", exc)
        _AST_AVAILABLE = False
    return _LANGUAGES


# ── helpers ─────────────────────────────────────────────────────────────


def _query_captures(lang: Any, query_text: str, root_node) -> list[tuple]:
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


# Characters that may appear in an id verbatim.  Anything else is escaped.
_SYMBOL_SAFE_RE = re.compile(r"^[A-Za-z0-9_.-]+$")
# A shebang naming one of these shells means the file is bash, whatever it is called.
_SHEBANG_RE = re.compile(r"#!.*\b(bash|zsh|sh)\b")


def _symbol_slug(name: str) -> str:
    """Id-safe, INJECTIVE encoding of a symbol name.

    ``slugify`` is lossy — it lowercases AND collapses runs of non-alphanumerics to a
    single ``-`` — so two different functions, ``__model_recommend`` and
    ``model-recommend``, both produced ``model-recommend``.  The second definition
    replaced the first in the graph and a call to either bound to the one surviving
    node; six slugs collided that way (11 definitions, 6 nodes), and the mis-binding
    was verified (a call to ``__model_recommend`` was recorded as calling
    ``model-recommend``).  A symbol id must round-trip its name, so a name that is
    already id-safe is kept verbatim and anything else is escaped character-wise.

    The escaped form is prefixed ``~`` (the safe form can never contain one) and
    escapes ``_`` as well as non-alphanumerics, so an escape can never be mistaken
    for a literal name.  File ids keep using ``slugify``: a repo path is unique and
    the slug is the readable, stable id for it.
    """
    if _SYMBOL_SAFE_RE.match(name):
        return name
    body = "".join(
        ch if (ch.isascii() and (ch.isalnum() or ch in "-.")) else f"_{ord(ch):x}"
        for ch in name
    )
    return f"~{body}"


def _symbol_id(kind: str, lang: str, name: str) -> str:
    """``ast_<kind>:<language>:<injective slug>`` — the id for a named symbol.

    The language is part of the id because the graph is otherwise keyed by the bare
    name: `main` alone merged SIX definitions across bash and Python into one
    `ast_func:main` node carrying six `defines` edges (measured 2026-09-21), so a
    per-`main` verdict was confounded and five of the six definitions were invisible.
    With the language in the id, a call can only resolve to a definition in its own
    language, which is what "who calls this" has always meant here.

    File ids keep `ast_file:<slug>`: a repo path is unique and the readable form is the
    useful one.
    """
    return f"ast_{kind}:{lang}:{_symbol_slug(name)}"


def _shebang_lang(path: Path) -> str | None:
    """The language a script's shebang implies, or None.

    Source files were discovered by EXTENSION alone, so this repo's nine
    extensionless ``bin/*`` scripts were never parsed — including ``bin/tac-exec``,
    the dispatcher every wrapper routes through.  Functions invoked only from those
    files therefore read as call-orphans, which is a coverage gap in the graph
    rather than dead code.
    """
    try:
        with path.open("rb") as fh:
            first = fh.readline(256)
    except OSError as exc:
        logger.debug("skipping unreadable script %s: %s", path, exc, exc_info=True)
        return None
    if not first.startswith(b"#!"):
        return None
    return "bash" if _SHEBANG_RE.match(first.decode("utf-8", "replace").lower()) else None


# ── file extension → language lookup ──────────────────────────────────

# Directories never walked: vendored deps, build output, caches, VCS metadata.
_SKIP_DIRS = ("venv", "node_modules", "__pycache__", "dist", "build", ".git")

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

    # ── file discovery: ONE pruned walk ──
    # Extension first (EXT_LANG), shebang second.  This used to be one
    # `root.glob("**/*<ext>")` per extension plus a separate shebang pass: six
    # unprunable walks of the whole tree, ~82k entries on this repo and almost all of
    # them under .venv, which cost seconds per extraction even when nothing changed.
    # os.walk prunes the skipped directories so they are never entered at all, and the
    # sorted names make the discovered order deterministic (glob order is
    # filesystem-defined, so two checkouts could differ).
    root = Path(repo_root).resolve()
    source_files: list[tuple[Path, str]] = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if not d.startswith(".") and d not in _SKIP_DIRS)
        for name in sorted(filenames):
            if name.startswith("."):
                continue
            fpath = Path(dirpath) / name
            lang = EXT_LANG.get(fpath.suffix)
            if lang is None:
                # Extensionless scripts carry a shebang as their only signal
                # (bin/tac-exec, bin/oc-*, ...); they were invisible before this pass.
                lang = _shebang_lang(fpath)
                if lang is None:
                    continue
            if scan_subdirs and not any(
                fpath.relative_to(root).as_posix().startswith(s) for s in scan_subdirs
            ):
                continue
            source_files.append((fpath, lang))

    if max_files and len(source_files) > max_files:
        source_files = source_files[:max_files]

    # ── per-file extraction ──
    parsers: dict[str, Any] = {}
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
        except OSError as exc:
            logger.debug("skipping unreadable source file %s: %s", fpath, exc, exc_info=True)
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
    _link_call_defs(builder)
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
            nid = _symbol_id("func", "bash", name)
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
                nid = _symbol_id("var", "bash", name)
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
            nid = _symbol_id("func", "python", name)
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
            nid = _symbol_id("class", "python", name)
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
                    nid = _symbol_id("module", "python", module)
                    builder.add_node({
                        "id": nid, "label": module.strip(), "type": "module",
                        "language": "python", "source": "ast", "confidence": "EXTRACTED",
                    })
                    builder.add_edge({"source": file_id, "target": nid, "label": "imports", "confidence": "EXTRACTED"})


# Bash functions that invoke a function NAME handed to them as an argument.  Such a
# call sits in argument position, so the `command_name` query never sees it and the
# dispatched function reads as uncalled — that shape accounted for most of this
# repo's call-orphans.  Only names listed here are treated this way: inferring "this
# function runs its argument" in general would over-connect, because plenty of
# functions take a name they never invoke.  Each entry is verified by reading it:
#   scripts/07-telemetry.sh  _telemetry              — runs "$@"
#   scripts/11e-llm-model.sh __bench_run_with_timeout — declares and runs "$1"
_BASH_DISPATCHERS = {
    "_telemetry",
    "__bench_run_with_timeout",
}


def _extract_dispatched_calls(grammar_lang: Any, root_node, code: bytes, file_id: str,
                              builder: GraphBuilder, seen_calls: set[str]) -> None:
    """Record function names passed to a known dispatcher as call references.

    The edge is deliberately the ordinary call shape — file -> ast_call -> ast_func —
    so `_link_call_defs` resolves it against the whole corpus by name and no new
    resolution machinery is needed.
    """
    for node, tag in _query_captures(grammar_lang, BASH_QUERIES["function_call"], root_node):
        if tag != "call":
            continue
        dispatcher = _node_text(node, code).strip()
        if dispatcher not in _BASH_DISPATCHERS or node.parent is None:
            continue
        command = node.parent.parent
        if command is None:
            continue
        for child in command.children:
            if child.type != "word":
                continue
            name = _node_text(child, code).strip()
            # Bare words only: a quoted/variable/substituted argument is not a
            # function name we can resolve statically.
            if not name or name == dispatcher or name in seen_calls:
                continue
            if any(ch in name for ch in "$`|;&<>()'\" "):
                continue
            seen_calls.add(name)
            nid = _symbol_id("call", "bash", name)
            builder.add_node({
                "id": nid, "label": name, "type": "call",
                "language": "bash", "source": "ast", "confidence": "EXTRACTED",
            })
            builder.add_edge({"source": file_id, "target": nid, "label": "calls",
                              "confidence": "EXTRACTED"})


# A trap handler is shell code held in a STRING, so the `command_name` capture never
# saw the commands inside it.  scripts/11e-llm-model.sh's __bench_cleanup is the case
# that surfaced: it is defined inside another function and invoked ONLY from
# `trap '...; __bench_cleanup; ...' INT|TERM`, so it read as a call-orphan with no
# caller anywhere.  Handler text is re-parsed with the bash grammar and its command
# names recorded as ordinary calls, so the existing whole-corpus name resolution
# binds them with no extra machinery.
_TRAP_STRING_NODES = {"raw_string", "string"}
_BASH_NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_-]*$")


def _trap_handler_node(command):
    """The handler argument of a `trap` command: its first child after the name."""
    seen_name = False
    for child in command.children:
        if not seen_name:
            seen_name = child.type == "command_name"
            continue
        if child.type in (";", "comment"):
            continue
        return child
    return None


def _shell_command_names(grammar_lang: Any, source: str) -> list[str]:
    """The command-position words in a snippet of shell source (a trap handler)."""
    if not source.strip():
        return []
    snippet = source.encode("utf-8")
    parser = Parser(grammar_lang)
    names = []
    for node, tag in _query_captures(grammar_lang, BASH_QUERIES["function_call"],
                                     parser.parse(snippet).root_node):
        if tag != "call":
            continue
        name = _node_text(node, snippet).strip()
        if name:
            names.append(name)
    return names


def _extract_trap_handlers(grammar_lang: Any, root_node, code: bytes, file_id: str,
                           builder: GraphBuilder, seen_calls: set[str]) -> None:
    """Record the calls made from `trap '<handler>' SIGNAL` handler strings."""
    for node, tag in _query_captures(grammar_lang, BASH_QUERIES["function_call"], root_node):
        if tag != "call" or _node_text(node, code).strip() != "trap" or node.parent is None:
            continue
        command = node.parent.parent
        if command is None:
            continue
        handler = _trap_handler_node(command)
        if handler is None:
            continue
        if handler.type in _TRAP_STRING_NODES:
            # An expansion inside the quotes is a name that cannot be resolved
            # statically — same rule as a quoted dispatcher argument.
            if any("expansion" in child.type for child in handler.children):
                continue
            raw = _node_text(handler, code)
            inner = raw[1:-1] if len(raw) >= 2 else ""
        elif handler.type == "word":
            inner = _node_text(handler, code).strip()
        else:
            continue
        for name in _shell_command_names(grammar_lang, inner):
            if name in seen_calls or not _BASH_NAME_RE.match(name):
                continue
            seen_calls.add(name)
            nid = _symbol_id("call", "bash", name)
            builder.add_node({
                "id": nid, "label": name, "type": "call",
                "language": "bash", "source": "ast", "confidence": "EXTRACTED",
            })
            builder.add_edge({"source": file_id, "target": nid, "label": "calls",
                              "confidence": "EXTRACTED"})


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
            nid = _symbol_id("call", lang, name)
            builder.add_node({
                "id": nid, "label": name.strip(), "type": "call",
                "language": lang, "source": "ast", "confidence": "EXTRACTED",
            })
            builder.add_edge({"source": file_id, "target": nid, "label": "calls", "confidence": "EXTRACTED"})

    if lang == "bash":
        _extract_dispatched_calls(grammar_lang, root_node, code, file_id, builder, seen_calls)
        _extract_trap_handlers(grammar_lang, root_node, code, file_id, builder, seen_calls)


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


def _link_call_defs(builder: GraphBuilder) -> None:
    """Link each ``ast_call:<lang>:X`` node to its ``ast_func:<lang>:X`` definition.

    ``_extract_calls`` records which files call a name but never connects the
    call node to the function it resolves to, so "who calls X" is
    untraversable in the graph.  This pass adds ``ast_call:<lang>:X ->
    ast_func:<lang>:X`` edges (labeled "calls") when the definition exists in the
    SAME language — a bash call never resolves to a Python definition, which is what
    the language segment in the id is for.  Calls to external commands / undefined
    names are left unlinked.
    """
    for node in builder.nodes_list:
        if node.type != "call":
            continue
        name = (node.label or "").strip()
        if not name:
            continue
        func_id = _symbol_id("func", node.language or "bash", name)
        if builder.has_node(func_id):
            builder.add_edge({
                "source": node.id,
                "target": func_id,
                "label": "calls",
                "confidence": "INFERRED",
            })
