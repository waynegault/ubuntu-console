# kgraph — Knowledge Graph Tools

A knowledge graph server, AST extractor, community detection, MCP server, and CLI toolkit.

## Installation

### Using uv (recommended)

```bash
uv pip install -e scripts/kgraph
```

### Using pip

```bash
pip install -e scripts/kgraph
```

### Using pipx

```bash
pipx install scripts/kgraph
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

## Dependencies

- Python ≥ 3.10
- No external dependencies required (stdlib only)
- tree-sitter (optional: for AST extraction)
- gh CLI (optional: for PR dashboard)
