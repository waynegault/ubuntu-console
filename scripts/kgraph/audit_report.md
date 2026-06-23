# kgraph Scripts Audit

Date: 2026-06-23

## Overview

The `scripts/kgraph/` directory contains a Python package (`openclaw-kgraph v2.0.0`) providing knowledge graph functionality: AST extraction, community detection, MCP server, CLI tools, and HTML visualization.

A backward-compatibility shim exists at `scripts/kgraph.py` that re-exports all public symbols from the package.

## Module Inventory

| Module | Lines | Status | Notes |
|---|---|---|---|
| `__init__.py` | ~130 | ✅ Active | Re-exports all public symbols |
| `__main__.py` | 3 | ✅ Active | `python -m kgraph` entrypoint |
| `cli.py` | ~350 | ✅ Active | argparser-based CLI |
| `constants.py` | ~60 | ⚠️ Bloated imports | See below |
| `graph_db.py` | ~100 | ✅ Active | SQLite + JSON graph storage |
| `html.py` | ~250 | ✅ Active | Cytoscape.js HTML template |
| `server.py` | ~120 | ✅ Active | HTTP server for graph viewer |
| `memory_import.py` | ~75 | ✅ Active | Memory DB import |
| `ast_extractor.py` | ~200 | ✅ Active | Tree-sitter AST extraction |
| `community.py` | ~150 | ✅ Active | Community detection |
| `confidence.py` | ~30 | ✅ Active | Confidence tagging |
| `projection.py` | ~100 | ✅ Active | Graph projection |
| `query.py` | ~100 | ✅ Active | Query/path/explain |
| `report.py` | ~80 | ✅ Active | GRAPH_REPORT.md generation |
| `call_flow.py` | ~60 | ✅ Active | Call-flow HTML/Mermaid |
| `update.py` | ~80 | ✅ Active | Incremental rebuild |
| `mcp_server.py` | ~80 | ✅ Active | MCP server |
| `validate.py` | ~60 | ✅ Active | Input validation |
| `pr_dashboard.py` | ~70 | ✅ Active | PR dashboard HTML |
| `benchmark.py` | ~40 | ✅ Active | Benchmark |

## Unused Imports (Dead Code)

### `scripts/kgraph/constants.py` — 8 unused imports

```python
from functools import partial       # ❌ Not used in this file
from http.server import SimpleHTTPRequestHandler, HTTPServer  # ❌ Not used
import threading                    # ❌ Not used
import argparse                     # ❌ Not used
import webbrowser                   # ❌ Not used
import tempfile                     # ❌ Not used
import shutil                       # ❌ Not used
```

These are likely leftover from when constants.py was a consolidated monolithic module. The HTTP/threading/argparse/webbrowser functionality now lives in `server.py` and `cli.py`. These imports should be removed from `constants.py` and added only where needed.

Note: `sqlite3` and `os`, `json`, `re` are genuinely used for path resolution, canonical data loading, and DB queries.

## Dead Code

- **`scripts/build/` (324K)** — Stale build artifact from `uv build`. This is a `kgraph` package install snapshot that duplicates the live `scripts/kgraph/` package. Should be deleted. Gitignored? Check `.gitignore`.
- **`scripts/openclaw_kgraph.egg-info/` (28K)** — Stale egg-info from `pip install -e .` or `uv build`. Should be deleted.
- **`scripts/kgraph/__pycache__/`** — `.pyc` cache artifacts (harmless, gitignored but clutter)

## Duplication with graphify

The `scripts/kgraph/` package IS the "graphify gap remediation" — it was built as a `pip install`-able package to replace the older monolithic `scripts/graphify.py` / `scripts/kgraph.py` pattern. There is NO separate `graphify` directory or script in this repo.

The `pyproject.toml` references `https://github.com/safishamsi/graphify` as the upstream, confirming this package is meant to be the canonical replacement.

No duplication detected between `scripts/kgraph/` modules — each has a distinct responsibility.

## Build Artifacts (Safe to Remove)

| Path | Size | Reason |
|---|---|---|
| `scripts/build/lib/kgraph/` | 324K | Stale `uv build` output — duplicates `scripts/kgraph/` |
| `scripts/openclaw_kgraph.egg-info/` | 28K | Stale egg-info metadata |
| `scripts/kgraph/__pycache__/` | ~200K | `.pyc` cache (gitignored, safe to `py3clean`) |

## Recommendations

1. **Remove unused imports** from `scripts/kgraph/constants.py` (partial, SimpleHTTPRequestHandler, HTTPServer, threading, argparse, webbrowser, tempfile, shutil)
2. **Add `scripts/build/` to `.gitignore`** or remove it if already ignored
3. **Add `scripts/*.egg-info/` to `.gitignore`** or remove if already ignored
4. **No functional duplication detected** — the kgraph package is well-modularized
