"""kgraph — Serve an interactive Cytoscape-based knowledge graph.

Features:
- Cytoscape.js frontend (from CDN)
- Edit/create/delete nodes and edges
- Edge labels and node labels with toggles
- Cluster by node attribute or by label prefix (creates compound parent nodes)
- Persistent store via GET/POST /graph.json (defaults to ~/.openclaw/kgraph.json)

This package was decomposed from a single 3200+ line module into
logical submodules for maintainability.  All public symbols are
re-exported here so existing imports continue to work unchanged.
"""

__version__ = "1.0.0"

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
]
