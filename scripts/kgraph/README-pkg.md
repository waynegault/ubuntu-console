# kgraph — Knowledge Graph Tools

A knowledge graph server, AST extractor, community detection, MCP server, and CLI toolkit.

## Installation

### Using uv (recommended)

```bash
uv pip install -e scripts/kgraph
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
pip install -e scripts/kgraph
```

### Using pipx

```bash
pipx install './scripts[ast]'
```

Or directly from the source tree:

```bash
cd scripts/kgraph && pip install -e .
```

## Usage

```bash
kgraph --help               # All commands
kgraph --serve              # Start web viewer
kgraph --output graph.html  # Generate static HTML
kgraph --update             # Incremental rebuild
kgraph --wiring --repo DIR   # Analyze source-tree wiring (orphans, broken imports, weak wiring, facades)
kgraph --watch              # Watch mode (auto-rebuild on file changes)
kgraph --mcp                # MCP server for LLM tool-call access
kgraph --validate file.json # Validate graph JSON
kgraph --security-check file.json  # Security scan
kgraph --pr-dashboard       # Generate PR dashboard
kgraph --install-hook       # Install git post-commit hook
kgraph --uninstall-hook     # Remove git hook
```

## CLI Entry Points

| Command              | Function                  |
|----------------------|---------------------------|
| `kgraph`             | Main CLI                  |
| `kgraph-validate`    | Graph JSON validation     |
| `kgraph-security`    | Security checks           |
| `kgraph-pr-dashboard`| PR dashboard generator    |
| `kgraph-benchmark`   | Token-reduction benchmark |
| `kgraph-audit`       | Security audit            |
| `kgraph-wiring`      | Source-tree wiring analysis  |

## Dependencies

- Python ≥ 3.10
- No external dependencies required (stdlib only)
- tree-sitter (optional: for AST extraction)
- gh CLI (optional: for PR dashboard)
