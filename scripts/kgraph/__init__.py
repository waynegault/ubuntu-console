"""kgraph — Knowledge graph server, AST extractor, community detection, MCP, and CLI tools.

Features:
- Cytoscape.js frontend (from CDN) with multi-view projections
- Edit/create/delete nodes and edges
- Persistent store via SQLite (graph_db) + JSON fallback
- Cluster by node attribute or label prefix
- AST-based code-to-concept extraction (tree-sitter) — Bash/Python
- Community detection with Leiden-like greedy modularity
- God-node / centrality analysis
- GRAPH_REPORT.md generation with surprising connections
- Call-flow HTML / Mermaid export
- Confidence tagging (EXTRACTED/INFERRED/AMBIGUOUS)
- Query/path/explain CLI tools
- MCP server for tool-call graph access
- --update incremental rebuild
- --watch auto-sync mode
- Git hooks for post-commit rebuild

All public symbols are re-exported here so existing imports work unchanged.
"""

__version__ = "2.0.0"

# Constants
from .constants import (
    MEMORY_DB_CANDIDATES,
    GRAPH_DB_DEFAULT,
    LIFE_ROOT_DEFAULT,
    CANONICAL_CONCEPTS_DEFAULT,
    SAMPLE_GRAPH,
    load_canonical_data,
    normalize_canonical_name,
)

# HTML template
from .html import (
    HTML_TMPL,
    ensure_parent_dir,
    generate_html,
)

# Graph projection engine
from .projection import project_graph

# Life index and relations
from .life_index import (
    resolve_life_root,
    load_life_index,
    load_relations,
    merge_relations,
)

# Graph database
from .graph_db import (
    resolve_memory_db_path,
    init_graph_db,
    load_from_graph_db,
    save_to_graph_db,
)

# HTTP server
from .server import (
    resolve_serve_target,
    serve_file,
)

# Memory import
from .memory_import import load_from_memory_db

# AST code-to-concept extraction (tree-sitter)
from .ast_extractor import (
    ast_available,
    extract_repo_graph,
)

# Community detection / clustering
from .community import (
    communities_available,
    detect_communities,
    compute_centrality,
    find_god_nodes,
)

# Confidence tagging
from .confidence import (
    tag_confidence,
    confidence_stats,
)

# Report generation
from .report import (
    generate_report,
)

# Query / path / explain tools
from .query import (
    query_nodes,
    find_path,
    explain_node,
    format_explain,
    format_path,
)

# Call-flow Mermaid / HTML export
from .call_flow import (
    generate_call_flow_mermaid,
    generate_call_flow_html,
)

# Update / watch mode
from .update import (
    incremental_update,
    start_watch,
)

# MCP server
from .mcp_server import serve_mcp

# Input validation / security
from .validate import (
    validate_graph_payload,
    sanitize_label,
)

# PR dashboard
from .pr_dashboard import (
    generate_pr_dashboard,
)

# Benchmark
from .benchmark import (
    benchmark_graph_vs_raw,
    print_benchmark,
)

# CLI
from .cli import main

__all__ = [
    "__version__",
    # constants
    "MEMORY_DB_CANDIDATES",
    "GRAPH_DB_DEFAULT",
    "LIFE_ROOT_DEFAULT",
    "CANONICAL_CONCEPTS_DEFAULT",
    "SAMPLE_GRAPH",
    "load_canonical_data",
    "normalize_canonical_name",
    # html
    "HTML_TMPL",
    "ensure_parent_dir",
    "generate_html",
    # projection
    "project_graph",
    # life_index
    "resolve_life_root",
    "load_life_index",
    "load_relations",
    "merge_relations",
    # graph_db
    "resolve_memory_db_path",
    "init_graph_db",
    "load_from_graph_db",
    "save_to_graph_db",
    # server
    "resolve_serve_target",
    "serve_file",
    # memory_import
    "load_from_memory_db",
    # cli
    "main",
    # ast_extractor
    "ast_available",
    "extract_repo_graph",
    # community
    "communities_available",
    "detect_communities",
    "compute_centrality",
    "find_god_nodes",
    # confidence
    "tag_confidence",
    "confidence_stats",
    # report
    "generate_report",
    # query
    "query_nodes",
    "find_path",
    "explain_node",
    "format_explain",
    "format_path",
    # call_flow
    "generate_call_flow_mermaid",
    "generate_call_flow_html",
    # update
    "incremental_update",
    "start_watch",
    # mcp
    "serve_mcp",
    # validate
    "validate_graph_payload",
    "sanitize_label",
    # pr_dashboard
    "generate_pr_dashboard",
    # benchmark
    "benchmark_graph_vs_raw",
    "print_benchmark",
]
