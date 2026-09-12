# kgraph — Knowledge Graph Tools

A knowledge graph server, AST extractor, community detection, MCP server, and CLI toolkit.

## Installation

The package root is `scripts/` — its `pyproject.toml` builds the
`openclaw-kgraph` distribution and installs the `kgraph` console script.

### Using uv (recommended)

```bash
uv pip install -e scripts
```

> **Non-editable installs are snapshots.** `uv tool install './scripts[ast]'` (or
> `pipx install './scripts[ast]'`) copies the source at install time; after repo
> changes, resync with `uv tool install --force './scripts[ast]'`. The `[ast]`
> extra is required for AST extraction — a resync that omits it (plain
> `uv tool install --force ./scripts`) silently drops tree-sitter and every
> `--update`/`--ast` run falls back to a memory-only graph. The package ships
> `templates/kgraph.html` as package data — an install missing it serves a
> "Template not found" viewer.

### Using pip

```bash
pip install -e scripts
```

### Using pipx

```bash
pipx install './scripts[ast]'
```

Or directly from the source tree:

```bash
cd scripts && pip install -e .
```

## Usage

```bash
kgraph --help               # All commands
kgraph --serve              # Start web viewer
kgraph --output graph.html  # Generate static HTML
kgraph --update             # Incremental rebuild
kgraph --wiring --repo DIR  # Analyze source-tree wiring (orphans, broken imports, weak wiring, facades)
kgraph --watch              # Watch mode (auto-rebuild on file changes)
kgraph --mcp                # MCP server for LLM tool-call access
kgraph --report             # Write GRAPH_REPORT.md
kgraph --audit              # Show security audit report
kgraph --pr-dashboard       # Generate PR dashboard
kgraph --install-hook       # Install git post-commit hook
kgraph --uninstall-hook     # Remove git hook
```

`kgraph --mcp` serves 5 tools over JSON-RPC on localhost. Its write tool
(`kgraph_report`) is accepted **only** with `Content-Type: application/json`,
must not carry a cross-origin `Origin`, and writes only inside
`KG_REPORTS_DIR` (default `~/.openclaw/kgraph-reports`) via a path relative to
it — absolute paths and `..` are rejected. `GET /graph.json` echoes CORS only
for the Vite dev frontend's origin and redacts memory text.

Graph JSON validation is a module entry point, not a CLI flag:

```bash
python -m kgraph.validate graph.json
```

## CLI Entry Points

| Command  | Function |
|----------|----------|
| `kgraph` | Main CLI (`kgraph.cli:main`) — every feature is a flag on this one command |

## Dependencies

- Python ≥ 3.12
- `networkx` ≥ 3.0 and `pydantic` ≥ 2.0 (required — installed automatically)
- `tree-sitter` (extra: `pip install './scripts[ast]'`) — required for AST extraction
- `git` on `PATH` (for `--pr-dashboard`)
