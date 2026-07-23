---
title: OpenClaw Integration
description: Complete reference for OpenClaw integration — architecture, API key bridge, gateway lifecycle, logs, agent & session management, configuration, backup & restore, knowledge graph, and key paths.
---

# OpenClaw Integration

## What Is OpenClaw?

OpenClaw is a Node.js-based AI agent framework (v2026.7.2-beta.3) that runs as a
**systemd user service** on port 18789. It provides multi-agent orchestration,
session management, and tool-use capabilities. The Tactical
Profile wraps the entire OpenClaw CLI with ergonomic shell commands.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  Windows 11 Pro                                     │
│  ┌───────────────────────────────────────────────┐  │
│  │ PowerShell 7.5.4 (pwsh.exe)                   │  │
│  │  └── Environment Variables (API keys)         │  │
│  └───────────────────────────────────────────────┘  │
│         │ pwsh.exe bridge (timeout 5s)              │
│         ▼                                           │
│  ┌───────────────────────────────────────────────┐  │
│  │ WSL2 Ubuntu 24.04                             │  │
│  │  ┌─ ~/.bashrc (thin loader) ────────────────┐  │  │
│  │  │  source tactical-console.bashrc           │  │  │
│  │  │  ┌─ tactical-console.bashrc ───────────┐  │  │  │
│  │  │  │  sources scripts/01..14-*.sh        │  │  │  │
│  │  │  │  ┌─ 09-openclaw.sh ──────────────┐  │  │  │  │
│  │  │  │  │  __bridge_windows_api_keys()  │  │  │  │  │
│  │  │  │       │                             │  │  │  │
│  │  │  │       ▼                             │  │  │  │
│  │  │  │  /dev/shm/tac_win_api_keys (cache)  │  │  │  │
│  │  │  │       │ source + systemctl set-env  │  │  │  │
│  │  │  │       ▼                             │  │  │  │
│  │  │  │  systemd user session ─────────┐   │  │  │  │
│  │  │  │       │                        │   │  │  │  │
│  │  │  │       ▼                        ▼   │  │  │  │
│  │  │  │  openclaw-gateway.service  llama   │  │  │  │
│  │  │  │  (port 18789)             (8081)   │  │  │  │
│  │  │  └────────────────────────────────────┘  │  │  │
│  │  └─────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

## API Key Bridge

The profile bridges API keys from the Windows User environment into WSL. This
is necessary because WSL2 does not inherit Windows environment variables by
default, but cloud LLM providers (used as fallback) need API keys.

**Security:** API key cache file permissions are validated (600 only).
Key names are validated against `^[A-Z_][A-Z0-9_]*$` before indirect expansion
to prevent command injection.

**How it works:**

1. On shell start, `__bridge_windows_api_keys()` calls `pwsh.exe` (with 5s
   timeout) to read Windows User environment variables.
2. It filters for variables matching the regex `API[_-]?KEY|TOKEN`.
3. Matching key-value pairs are written to `/dev/shm/tac_win_api_keys` as
   `export KEY=VALUE` lines (`chmod 600`, tmpfs — never hits disk).
4. The cache file is `source`d into the shell environment.
5. Cache TTL is 3600 seconds (1 hour). Run `oc-refresh-keys` to force refresh.
6. `oc-refresh-keys` then syncs OpenClaw SecretRefs (see below) so config
   credentials reference the refreshed environment instead of holding
   plaintext copies.

**For the OpenClaw gateway** (which runs under systemd, not as a child of the
shell), `so()` reads the cache file and injects each variable into the systemd
user session via `systemctl --user set-environment KEY=VALUE` before starting
the service. This ensures the Node.js gateway process has access to all
bridged API keys.

### SecretRef Sync

`~/.config/environment.d/90-openclaw.conf` remains the **backing store** for
API keys: a SecretRef does not store a secret, it references an environment
variable that OpenClaw resolves at gateway activation. Keeping keys in the
environment (bridged from Windows) and referencing them by name is what lets
the plaintext copies be removed from `openclaw.json`.

After refreshing the environment, `oc-refresh-keys` maps a small set of
config-managed credentials to env-backed SecretRefs using the same builder
`openclaw secrets configure` uses:

```bash
openclaw config set <config-path> --ref-provider default --ref-source env --ref-id <ENV_VAR>
```

This writes `{"source":"env","provider":"default","id":"<ENV_VAR>"}` into the
config field (preflighted and written atomically; skipped when the env var is
absent, so an unresolved ref is never created). Current mapping (defined in
`scripts/09d-oc-agents.sh`, `__oc_apply_secret_refs`):

| Config path | Env var |
|---|---|
| `models.providers.qwen-token-plan.apiKey` | `QWEN_TOKEN_PLAN_API_KEY` |
| `plugins.entries.google.config.webSearch.apiKey` | `GEMINI_API_KEY` |

Verify with `openclaw secrets audit --check`. Auth-profile keys stored in the
per-agent SQLite stores are migrated separately via
`openclaw secrets configure --agent <id>`.

## Gateway Lifecycle

| Command | What It Does |
|---|---|
| `so` | Start the OpenClaw gateway. Injects API keys into systemd, ensures Local LLM is running (auto-starts from default/first registry model when needed), then starts gateway and waits for port 18789 readiness. **Fails gracefully if OpenClaw not installed.** |
| `xo` | Stop the gateway (**stop only — does not restart**). Runs `openclaw gateway stop`, then `systemctl --user stop openclaw-gateway.service`, removes supervisor lock. When called from an AI agent context, prints a warning to use `openclaw gateway restart` instead. **Fails gracefully if OpenClaw not installed.** |
| `oc-restart` | Restart gateway (native: `openclaw gateway restart`). **Fails gracefully if OpenClaw not installed.** |
| `oc-health` | Deep probe: checks port 18789, then calls `openclaw health --json` and parses the status field. Supports `--json` and `--plain` for automation. |
| `oc-tail` | Live-tail gateway logs via `openclaw logs --follow`. |

## Logs

| Command | What It Does |
|---|---|
| `le` | Show last 40 lines of gateway stderr from `journalctl --user -u openclaw-gateway.service` |
| `lo` | Show last 120 lines of gateway stdout from `journalctl` |
| `lc` | Rotate and vacuum the gateway journal logs |
| `oclogs` | Open `/tmp/openclaw/openclaw.log` in VS Code |
| `ologs` | `cd` into the OpenClaw logs directory |

## Agent & Session Management

| Command | What It Does |
|---|---|
| `os` | List active sessions (`openclaw sessions`) |
| `oa` | List registered agents (`openclaw agents list`) |
| `ocstart` | Send an agent turn: `ocstart -m "message" [--to E.164] [--agent id]` |
| `ocstop` | Delete an agent: `ocstop --agent <id>` |

| `status` | Quick overview: `openclaw status` |
| `oc-status` | Full status: `openclaw status --all` |
| `ocstat` | Legacy alias for `oc-status` |
| `ocgs` | Deep gateway probe: `openclaw gateway status --deep` |
| `mem-index` | Reindex OpenClaw memory files |
| `oc-memory-search` | Search vector memory index |

## Configuration & Diagnostics

| Command | What It Does |
|---|---|
| `occonf` | Open `~/.openclaw/openclaw.json` in VS Code |
| `oc-config` | Get/set config values: `oc-config get <key>`, `oc-config set <key> <val>` |
| `oc-env` | Dump all OC and LLM environment variables in a box-drawn panel |
| `ockeys` | Show Windows API keys and their WSL visibility status |
| `ocms` | Probe model provider status |
| `oc-diag` | 5-point diagnostic: doctor, gateway, models, env vars, recent logs |
| `oc-doctor-local` | Validate the full local OpenClaw + llama.cpp path end-to-end. Supports `--json` and `--plain`. |
| `oc-sec` | Deep security audit: `openclaw security audit --deep` |
| `oc-docs` | Search OpenClaw docs from the terminal |
| `ocdoc-fix` | Run `openclaw doctor --fix` with automatic config backup |
| `oc-cache-clear` | Wipe all `/dev/shm/tac_*` telemetry caches. Supports `--dry-run`. |

## Backup & Restore

| Command | What It Does |
|---|---|
| `oc-backup` | ZIP snapshot of OpenClaw config (`openclaw.json`, `auth.json`), `workspace/`, `agents/`, `models.conf`, `~/.bashrc` loader, `tactical-console.bashrc`, standalone scripts (`~/.local/bin/oc-*`, `llama-watchdog.sh`, `tac_hostmetrics.sh`), and systemd units. Saved to `~/.openclaw/backups/snapshot_YYYYMMDD_HHMMSS.zip`. |
| `oc-restore` | Restore from the most recent snapshot (destructive — prompts for confirmation). Validates ZIP contents, accepts config-only backups, and supports `--dry-run`. |

## Extensions & Advanced

| Command | What It Does |
|---|---|
| `oc-update` | Update OpenClaw CLI to latest version |
| `ocv` | Print CLI version |
| `oc-tui` | Launch the OpenClaw interactive terminal UI |
| `oc-cron` | Scheduler: `oc-cron list`, `oc-cron add`, `oc-cron runs` |
| `oc-skills` | List installed/eligible skills |
| `oc-plugins` | Plugin management: `list`, `doctor`, `enable`, `disable` |
| `oc-usage` | Token/cost stats: `oc-usage [period]` (default: 7d) |
| `oc-channels` | Channel management: `list`, `status`, `logs`, `add`, `remove` |
| `oc-browser` | Browser automation: `status`, `start`, `stop`, `open` |
| `oc-nodes` | Node management: `status`, `list`, `describe` |
| `oc-sandbox` | Sandbox management: `list`, `recreate`, `explain` |
| `wacli` | WhatsApp CLI wrapper. Automatically injects `--store ~/.openclaw/store/wacli` unless `--store` is already provided. Passes all arguments through. |
| `oc-failover` | Cloud fallback: `oc-failover on`, `off`, `status` |
| `oc-local-llm` | Bind OpenClaw's model provider to local llama.cpp |
| `oc-sync-models` | Sync model registry with OpenClaw scan |
| `oc-trust-sync` | Record current `oc-llm-sync.sh` SHA256 hash as trusted |

## Knowledge Graph (`oc g` / `kgraph`)

The kgraph package (`scripts/kgraph/`) is a full knowledge graph toolchain:
interactive viewer, AST code extractor, community detection, MCP server,
and CLI tools for graph navigation.

### Interactive Viewer (`oc g`)

`oc g` (or `oc-kgraph`) launches the Cytoscape.js graph viewer. Graph data is
persisted to `~/.openclaw/kgraph.sqlite` (primary) and mirrored to
`~/.openclaw/kgraph.json`. A React + AntV G6 frontend lives in `frontend-g6/`
for development (`npm run dev` on port 5173). Both read the same persisted graph.

### CLI Mode (`kgraph`)

The `kgraph` CLI is installable as a standalone tool via `uv tool install ./scripts`
from the repo root. It exposes all features as subcommands:

| Command | Description |
|---------|------------|
| `kgraph --serve` | Launch interactive viewer (same as `oc g`) |
| `kgraph --ast --repo .` | Extract AST code concepts from a repo |
| `kgraph --update --source-dir .` | Incremental rebuild (memory DB → AST → communities) |
| `kgraph --watch` | Watch files and auto-rebuild |
| `kgraph --report` | Generate GRAPH_REPORT.md with god nodes, communities, surprises |
| `kgraph --communities` | Detect communities/clusters in the graph |
| `kgraph --god-nodes` | List most central nodes by composite centrality |
| `kgraph --call-flow` | Generate call-flow HTML/Mermaid from AST data |
| `kgraph --mcp` | Serve MCP JSON-RPC server for LLM tool-call access |
| `kgraph --query <pattern>` | Find nodes matching a label/type |
| `kgraph --path <src> <dst>` | Shortest path between two nodes |
| `kgraph --explain <node>` | Describe a node and its connections |
| `kgraph --confidence` | Show edge confidence breakdown (EXTRACTED/INFERRED/AMBIGUOUS) |
| `kgraph --pr-dashboard` | Generate PR dashboard correlating git history ↔ graph nodes |
| `kgraph --benchmark` | Run token-reduction benchmark (graph vs raw files) |
| `kgraph --audit` | Show security audit report |
| `kgraph --install-hook` | Install git post-commit/post-merge hooks for auto-rebuild |

### Interactive Viewer Features

- **Multi-view projections:** `overview` (default), `topics`, `files`, `semantic`, `raw`
- Create, edit, delete nodes and edges with labels
- Semantic threshold control for noisy similarity edges
- Cluster nodes by attribute or label prefix
- Toggle edge/node labels
- Graph source/view metadata shown in the toolbar
- Graph data saved via `GET`/`POST` to `/graph.json`
- **Rate-limited POST** (30 req/min) — returns 429 with Retry-After

### AST Code Extraction (`kgraph --ast`)

Extracts function definitions, class definitions, calls, imports, and file
dependencies from source code using tree-sitter. Supports Bash and Python.
Deterministic, zero API calls. 26+ language grammars available.

```bash
kgraph --ast --repo /path/to/repo --ast-subdirs scripts --output ast-graph.json
kgraph --confidence --graph ast-graph.json
kgraph --god-nodes --graph ast-graph.json
```

### Community Detection (`kgraph --communities`)

Uses networkx (Louvain/greedy modularity) to detect semantic clusters.
Also computes degree, betweenness, and eigenvector centrality to identify
"god nodes" — the most central concepts in the graph.

### Confidence Tagging (`kgraph --confidence`)

Every graph edge is tagged with one of:
- **EXTRACTED** — directly from source (AST parse, explicit DB relation)
- **INFERRED** — derived via co-occurrence or semantic similarity
- **AMBIGUOUS** — low-confidence, needs verification

### MCP Server (`kgraph --mcp`)

Exposes 5 tools via JSON-RPC over HTTP (binds localhost only):
- `kgraph_query` — search nodes by pattern
- `kgraph_path` — shortest path between two nodes
- `kgraph_explain` — node description with connections
- `kgraph_report` — generate current graph report
- `kgraph_stats` — basic graph statistics

Clients connect to `http://127.0.0.1:8331` (configurable port).

### Git Hooks (`kgraph --install-hook`)

Installs post-commit and post-merge hooks that auto-rebuild the graph
when source files change. Detects changes via tree-sitter and runs
`kgraph --update` automatically.

### Installation

```bash
# From repo (recommended — updates with repo)
uv tool install ./scripts

# Standalone (when published to PyPI)
uv tool install openclaw-kgraph

# With AST support (Bash + Python grammars)
uv tool install ./scripts --extra ast
```

## Key Paths

| Path | Purpose |
|---|---|
| `~/.openclaw/` | OpenClaw root (`$OC_ROOT`) |
| `~/.openclaw/workspace/` | Active workspace |
| `~/.openclaw/agents/` | Agent definitions |
| `~/.openclaw/logs/` | Log files |
| `~/.openclaw/backups/` | ZIP snapshots |
| `~/.openclaw/openclaw.json` | Global configuration |
| `~/.openclaw/bash-errors.log` | ERR trap log |
| `~/.openclaw/maintenance_cooldowns.txt` | Cooldown timestamps |
| `~/.openclaw/completions/openclaw.bash` | Bash completions |
| `~/.openclaw/.env.bridge` | Generated env bridge consumed by the gateway service |
| `~/.openclaw/kgraph.json` | JSON mirror of the editable knowledge graph |
| `~/.openclaw/kgraph.sqlite` | Primary persisted SQLite store for `oc g` |
| `~/.openclaw/state/memory/gigabrain-workspace/obsidian-vault/` | Gigabrain-exported Obsidian vault root |
| `~/.config/systemd/user/openclaw-gateway.service` | systemd unit file |
| `~/.config/systemd/user/openclaw-gateway.service.d/env-bridge.conf` | Gateway env-bridge drop-in (ExecStartPre + EnvironmentFile) |
| `~/.config/systemd/user/llama-watchdog.service` | Watchdog systemd unit |
| `~/.config/systemd/user/llama-watchdog.timer` | Watchdog timer |
| `/dev/shm/tac_win_api_keys` | Bridged API key cache (tmpfs) |
| `~/.local/bin/tac_hostmetrics.sh` | Host CPU + iGPU + NVIDIA dGPU load/engines |
| `~/.local/bin/llama-watchdog.sh` | Watchdog: auto-restart llama-server |

← [Back to README](../README.md)

# end of file
