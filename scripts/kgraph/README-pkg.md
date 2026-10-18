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
kgraph -h                             # All commands
kgraph serve                          # Start web viewer
kgraph html --output graph.html       # Generate static HTML
kgraph update                         # Incremental rebuild
kgraph wiring --repo DIR              # Analyze source-tree wiring (orphans, broken imports, weak wiring, facades)
kgraph watch                          # Watch mode (auto-rebuild on file changes)
kgraph mcp                            # MCP server for LLM tool-call access
kgraph report                         # Write GRAPH_REPORT.md
kgraph path --path A B                # Path between two nodes; --path-mode bfs (default) | strongest
kgraph audit                          # Show security audit report
kgraph pr-dashboard                   # Generate PR dashboard
kgraph install-hook                   # Install git post-commit hook
kgraph uninstall-hook                 # Remove git hook
kgraph remove-source --remove-source KEY  # Remove one source document's assertions
```

`kgraph mcp` serves 6 tools over JSON-RPC on localhost — `kgraph_query`,
`kgraph_path`, `kgraph_explain`, `kgraph_community`, `kgraph_report` and
`kgraph_stats`. Its write tool
(`kgraph_report`) is accepted **only** with `Content-Type: application/json`,
must not carry a cross-origin `Origin`, and writes only inside
`KG_REPORTS_DIR` (default `~/.openclaw/kgraph-reports`) via a path relative to
it — absolute paths and `..` are rejected. `GET /graph.json` echoes CORS only
for the Vite dev frontend's origin and redacts memory text.

Every data-tool result is an untrusted-content envelope:
`{"trust": "untrusted", "source": "kgraph graph (repository source + memory records)",
"notice": "...", "content": <payload>}`. The payload is unchanged under
`content`; `content` is a list for `kgraph_query` and an object for the other
five. Each tool description carries the same notice, so a consumer sees the
trust value at discovery time. `list_tools` is metadata, not graph text, and is
not wrapped; neither are `{"error": ...}` results, which are server-generated.
The HTML viewer's `_check_xss` is an XSS control, not an injection control, and
does not apply to this consumer.

Graph JSON validation is a module entry point, not a CLI flag:

```bash
python -m kgraph.validate graph.json
```

## Calibrating the INFERRED/AMBIGUOUS thresholds

`confidence.SEMANTIC_INFERRED_MIN` and `COOCCURRENCE_INFERRED_MIN` are hand-picked
defaults, and the population they govern is currently empty: the built graph has no
scored edges at all, so no threshold can be measured yet. `kgraph.calibrate` is the
harness for the day that changes — it is also the fastest way to check the state.

```bash
# 1. Draw a sample. Writes sample.csv (blank `real` column), signals.json and
#    provenance.json. The score is deliberately NOT in the CSV you label.
python -m kgraph.calibrate --export /tmp/kg-sample --limit 200 --seed 0

# 2. Fill the `real` column with true/false, then score it. Prints one
#    precision/recall curve per signal and names the operating point.
python -m kgraph.calibrate --score /tmp/kg-sample --min-precision 0.90 \
    --report /tmp/kg-sample/report.md
```

Exit 2 means "no number can be named": either nothing scored to sample, or fewer than
`MIN_SAMPLE` (50) labelled edges, or a one-class sample. The harness never writes a
constant into the source — a re-run cannot change behaviour by accident, and the
report is the review evidence for a hand edit.

## Importing a memory source

`kgraph import-source` writes a source into the `files`/`chunks` store the graph
reader consumes, so the existing co-occurrence/similarity pass is the only graph
builder. Markdown memory is the first adapter:

```bash
kgraph import-source --source markdown --source-path ~/.openclaw/memory \
    --source-db ~/.openclaw/kgraph-memory-source.sqlite
kgraph update --import-db ~/.openclaw/kgraph-memory-source.sqlite --source-dir .
```

For a document tree (the investigator Layer 1-5 directories), use the directory
adapter. It reads the text-bearing files (`*.md`, `*.txt`, `*.html`) and skips
PDF/DOCX; a binary extractor supplies those separately.

```bash
kgraph import-source --source directory --source-kind investigator-layer3 \
    --source-path "/home/wayne/investigator/data/Layer 3 Rebuttal" \
    --source-db ~/.openclaw/kgraph-layer3.sqlite
kgraph update --import-db ~/.openclaw/kgraph-layer3.sqlite --source-dir .
```

Measured 2026-10-18: 211 text files -> 211 chunks -> 778 nodes, 1,385 edges,
4 scored (a 4-row export sample).

For the investigator production Chroma store, use `--source chroma`; it matches
`mves_layer` (integer) and `layer` (string). L4's tag is synthetic fixtures while
the real report is untagged, so do not treat it as the layer.

```bash
kgraph import-source --source chroma \
    --source-path /home/wayne/investigator/production/vector_db/chroma.sqlite3 \
    --layer-values 1,2,3,5 --source-db ~/.openclaw/kgraph-layers.sqlite
```
Measured 2026-10-18: L1 136, L2 26,271, L3 51,885, L5 85,045 tagged chunks.

The seam is the `MemorySource` protocol (`kgraph.source_import`): yield one
`SourceRecord` per document section, set `source_kind` (for example
`investigator-layer1`), and put the layer/case/document in `path` so the graph's
file nodes carry the provenance. `source_meta` keeps the kind/date/section for
audit. Re-importing a path replaces its chunks; a source root that loses a file
is pruned on the next import.

## CLI Entry Points

| Command  | Function |
|----------|----------|
| `kgraph` | Main CLI (`kgraph.cli:main`) — every feature is a flag on this one command |

## Dependencies

- Python ≥ 3.12
- `networkx` ≥ 3.0 and `pydantic` ≥ 2.0 (required — installed automatically)
- `tree-sitter` (extra: `pip install './scripts[ast]'`) — required for AST extraction
- `git` on `PATH` (for `--pr-dashboard`)
