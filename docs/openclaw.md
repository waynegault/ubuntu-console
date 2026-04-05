---
title: OpenClaw Integration
description: Complete reference for OpenClaw integration — architecture, API key bridge, gateway lifecycle, logs, agent & session management, configuration, backup & restore, knowledge graph, and key paths.
---

# OpenClaw Integration

## What Is OpenClaw?

OpenClaw is a Node.js-based AI agent framework (v2026.3.2) that runs as a
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

**Security:** API key cache file permissions are validated (600 or 644 only).
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

**For the OpenClaw gateway** (which runs under systemd, not as a child of the
shell), `so()` reads the cache file and injects each variable into the systemd
user session via `systemctl --user set-environment KEY=VALUE` before starting
the service. This ensures the Node.js gateway process has access to all
bridged API keys.

## Gateway Lifecycle

| Command | What It Does |
|---|---|
| `so` | Start the OpenClaw gateway. Injects API keys into systemd, runs `openclaw gateway start`, waits 3s, checks port 18789. **Fails gracefully if OpenClaw not installed.** |
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

## Knowledge Graph (`oc g`)

`oc g` (or `oc-kgraph`) launches an interactive knowledge graph visualisation.
It starts a Python HTTP server (`scripts/kgraph.py`) that serves a
Cytoscape.js frontend, then opens the browser. The graph is persisted to
`~/.openclaw/kgraph.json` and mirrored into `~/.openclaw/kgraph.sqlite`.

**What `oc g` is best for:**
- browsing OpenClaw-derived file/topic/actor relationships
- inspecting semantic links between chunks or documents
- debugging graph extraction and memory structure
- keeping a small editable manual graph when needed

**Features:**
- Create, edit, and delete nodes and edges with labels
- Multiple graph views: `overview`, `topics`, `files`, `semantic`, `raw`
- Semantic threshold control for noisy similarity edges
- Cluster nodes by attribute or label prefix (compound parent nodes)
- Toggle edge/node labels
- Graph source/view metadata shown in the toolbar
- Graph data saved via `GET`/`POST` to `/graph.json`

**Recommended use:**
- `overview` = default human-friendly browsing
- `topics` = topic/entity centric exploration
- `files` = document/file structure only
- `semantic` = strongest similarity edges only
- `raw` = full unprojected graph for debugging

A separate React + AntV G6 frontend lives in `frontend-g6/` for development
use (`npm run dev` on Vite port 5173). Both UIs read the same persisted graph
state, while the Cytoscape tool can also derive views directly from the
OpenClaw memory DB.

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
| `~/.local/bin/tac_hostmetrics.sh` | Host CPU + iGPU (typeperf 3D) + CUDA (nvidia-smi compute) |
| `~/.local/bin/llama-watchdog.sh` | Watchdog: auto-restart llama-server |

← [Back to README](../README.md)

# end of file
