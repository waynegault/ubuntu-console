"""kgraph — Knowledge graph server, AST extractor, community detection, MCP, and CLI tools."""

__version__ = "2.0.0"

# Lazy imports — modules are loaded on first access to avoid paying the
# startup cost of importing all 16 submodules (tree-sitter, networkx, HTTP
# server, MCP server, AST extractor, etc.) on every `kgraph --help`.
# Use `from kgraph import <name>` as normal; the import machinery is unchanged.
# The __all__ list respects the public API contract.

import typing as _t

if _t.TYPE_CHECKING:
    # Mirror of the lazy registrations below: gives type checkers real
    # definitions for `from kgraph import X` / `kgraph.X` without paying the
    # runtime import cost (the __getattr__ shim handles execution).
    from .ast_extractor import ast_available, extract_repo_graph
    from .benchmark import benchmark_graph_vs_raw, print_benchmark
    from .call_flow import generate_call_flow_html, generate_call_flow_mermaid
    from .cli import main
    from .community import (
        communities_available,
        compute_centrality,
        detect_communities,
        find_god_nodes,
    )
    from .confidence import confidence_stats, tag_confidence
    from .constants import (
        CANONICAL_CONCEPTS_DEFAULT,
        GRAPH_DB_DEFAULT,
        LIFE_ROOT_DEFAULT,
        MEMORY_DB_CANDIDATES,
        SAMPLE_GRAPH,
        load_canonical_data,
        normalize_canonical_name,
    )
    from .graph_db import (
        init_graph_db,
        load_from_graph_db,
        resolve_memory_db_path,
        save_to_graph_db,
    )
    from .html import HTML_TMPL, ensure_parent_dir, generate_html
    from .life_index import load_life_index, load_relations, merge_relations, resolve_life_root
    from .mcp_server import serve_mcp
    from .memory_import import load_from_memory_db
    from .models import (
        ConfidenceLevel,
        Graph,
        GraphBuilder,
        GraphEdge,
        GraphMeta,
        GraphNode,
        estimate_tokens,
        slugify,
    )
    from .pr_dashboard import generate_pr_dashboard
    from .projection import project_graph
    from .query import explain_node, find_path, format_explain, format_path, query_nodes
    from .report import generate_report
    from .server import resolve_serve_target, serve_file
    from .update import incremental_update, merge_graphs, start_watch
    from .validate import sanitize_label, validate_graph_payload

_MODULES: dict[str,
                 _t.Callable[[], object]] = {}


def __getattr__(name: str) -> object:
    """Lazy-load submodule attribute on first access via `from kgraph import X`.

    Each submodule is imported exactly once, on the first attribute access
    that requires it.
    """
    fn = _MODULES.get(name)
    if fn is not None:
        return fn()
    raise AttributeError(f"module 'kgraph' has no attribute {name!r}")


def _lazy(mod_path: str, attrs: list[str]) -> None:
    """Register a lazy loader for *attrs* that imports *mod_path*."""
    for a in attrs:
        def _loader(mp: str = mod_path, al: str = a) -> object:
            return _import_one(mp, al)
        _MODULES[a] = _memo(_loader)


_imported_cache: dict[str, object] = {}


def _import_one(mod_path: str, attr: str) -> object:
    if attr not in _imported_cache:
        import importlib
        _imported_cache[attr] = getattr(importlib.import_module(mod_path, package="kgraph"), attr)
    return _imported_cache[attr]


def _memo(fn: _t.Callable[[], object]) -> _t.Callable[[], object]:
    """Return a wrapper that calls *fn* once and caches the result."""
    sentinel = object()
    val: object = sentinel

    def wrapper() -> object:
        nonlocal val
        if val is sentinel:
            val = fn()
        return val
    return wrapper


# ── Register lazy loaders ─────────────────────────────────────────────
_lazy(".models", [
    "ConfidenceLevel", "GraphNode", "GraphEdge", "GraphMeta", "Graph",
    "GraphBuilder", "slugify", "estimate_tokens",
])
_lazy(".constants", [
    "MEMORY_DB_CANDIDATES", "GRAPH_DB_DEFAULT", "LIFE_ROOT_DEFAULT",
    "CANONICAL_CONCEPTS_DEFAULT", "SAMPLE_GRAPH", "load_canonical_data",
    "normalize_canonical_name",
])
_lazy(".html", ["HTML_TMPL", "ensure_parent_dir", "generate_html"])
_lazy(".projection", ["project_graph"])
_lazy(".life_index", ["resolve_life_root", "load_life_index", "load_relations", "merge_relations"])
_lazy(".graph_db", ["resolve_memory_db_path", "init_graph_db", "load_from_graph_db", "save_to_graph_db"])
_lazy(".server", ["resolve_serve_target", "serve_file"])
_lazy(".memory_import", ["load_from_memory_db"])
_lazy(".ast_extractor", ["ast_available", "extract_repo_graph"])
_lazy(".community", ["communities_available", "detect_communities", "compute_centrality", "find_god_nodes"])
_lazy(".confidence", ["tag_confidence", "confidence_stats"])
_lazy(".report", ["generate_report"])
_lazy(".query", ["query_nodes", "find_path", "explain_node", "format_explain", "format_path"])
_lazy(".call_flow", ["generate_call_flow_mermaid", "generate_call_flow_html"])
_lazy(".update", ["incremental_update", "start_watch", "merge_graphs"])
_lazy(".mcp_server", ["serve_mcp"])
_lazy(".validate", ["validate_graph_payload", "sanitize_label"])
_lazy(".pr_dashboard", ["generate_pr_dashboard"])
_lazy(".benchmark", ["benchmark_graph_vs_raw", "print_benchmark"])
_lazy(".cli", ["main"])

__all__ = [
    "__version__",
    "ConfidenceLevel", "GraphNode", "GraphEdge", "GraphMeta", "Graph",
    "GraphBuilder", "slugify", "estimate_tokens",
    "MEMORY_DB_CANDIDATES", "GRAPH_DB_DEFAULT", "LIFE_ROOT_DEFAULT",
    "CANONICAL_CONCEPTS_DEFAULT", "SAMPLE_GRAPH", "load_canonical_data",
    "normalize_canonical_name",
    "HTML_TMPL", "ensure_parent_dir", "generate_html",
    "project_graph",
    "resolve_life_root", "load_life_index", "load_relations", "merge_relations",
    "resolve_memory_db_path", "init_graph_db", "load_from_graph_db", "save_to_graph_db",
    "resolve_serve_target", "serve_file",
    "load_from_memory_db",
    "main",
    "ast_available", "extract_repo_graph",
    "communities_available", "detect_communities", "compute_centrality", "find_god_nodes",
    "tag_confidence", "confidence_stats",
    "generate_report",
    "query_nodes", "find_path", "explain_node", "format_explain", "format_path",
    "generate_call_flow_mermaid", "generate_call_flow_html",
    "incremental_update", "start_watch", "merge_graphs",
    "serve_mcp",
    "validate_graph_payload", "sanitize_label",
    "generate_pr_dashboard",
    "benchmark_graph_vs_raw", "print_benchmark",
]
