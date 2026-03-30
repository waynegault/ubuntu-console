# Tactical Console Profile v3.1 - Comprehensive Reference

> **File:** `~/ubuntu-console/tactical-console.bashrc` (thin loader) + `scripts/01–15-*.sh` (modules)
> **Repo:** [`waynegault/ubuntu-console`](https://github.com/waynegault/ubuntu-console)
> **Environment:** WSL2 Ubuntu 24.04 on Windows 11 Pro
> **Hardware:** Intel i9 / Intel Iris Xe (iGPU) / RTX 3050 Ti 4 GB VRAM (CUDA) / Laptop
> **Author:** Wayne
> **Last Major Audit:** March 2026 (v3.0: modularisation from monolith; v3.1: full inspection-audit + UI header refresh + `up` performance fix; follow-up review captured current improvement priorities and roadmap items)
> **Latest Security Update:** March 2026 (comprehensive codebase review: 47 issues fixed including input validation, race conditions, flock for cooldown DB, whitelist regex for subcommands, OpenClaw functional detection)

---

## Table of Contents

1. [Purpose & Philosophy](#1-purpose--philosophy)
2. [Getting Started — Usage Guide](#2-getting-started--usage-guide)
3. [OpenClaw Integration](#3-openclaw-integration)
4. [Local LLM System](#4-local-llm-system)
5. [Developer Guide — How the Profile Works](#5-developer-guide--how-the-profile-works)
6. [Modular Architecture (Completed)](#6-modular-architecture-completed)
7. [Command Reference](#7-command-reference)
8. [Dependencies & Requirements](#8-dependencies--requirements)
9. [Troubleshooting](#9-troubleshooting)
10. [Repository Layout](#10-repository-layout)
11. [Improvement Opportunities](#11-improvement-opportunities)
12. [Proposed Future Functionality](#12-proposed-future-functionality)

---

## 1. Purpose & Philosophy

The **Tactical Console Profile** is a modular Bash environment that turns a
WSL2 Ubuntu shell into a unified command-and-control console. A thin loader
(`tactical-console.bashrc`) sources 15 numbered modules from `scripts/` in
dependency order. It manages:

- **System telemetry** — CPU, dual GPU (Intel Iris iGPU via `typeperf.exe` +
  NVIDIA RTX CUDA via `nvidia-smi`), memory, disk, battery, all rendered in
  a 78-column box-drawn dashboard.
- **Local LLM inference** — Full lifecycle management of `llama-server`
  (llama.cpp) with model registry, GPU/CPU offloading, and streaming chat.
- **OpenClaw agent framework** — Gateway lifecycle, agent orchestration,
  session management, backup/restore, and API key bridging from Windows.
- **Maintenance** — A 15-step `up` pipeline that updates APT, NPM, Cargo, R packages,
  validates Python fleets, audits disk space, cleans Docker/NPM caches, and kills orphaned processes.
  Uses flock for race-condition-free cooldown management.
- **Deployment** — Git commit/push with optional LLM-generated commit
  messages, plus rsync to an OpenClaw production workspace.
- **Knowledge graph** — Interactive node/edge graph visualisation served
  locally via `oc g`, backed by a Python HTTP server and React + AntV G6
  frontend.

### Design Principles

| Principle | Implementation |
|---|---|
| **Determinism** | Every maintenance step is idempotent with 7-day cooldowns. The `up` command always converges to the same desired state. |
| **Zero Dependencies Beyond Coreutils** | All LLM streaming is pure `bash + curl + jq`. No Python, Ruby, or Node is used in the shell layer itself. |
| **Instant UI** | Telemetry uses `/dev/shm` caching with background subshell refresh. The dashboard renders stale-but-instant data while new data fetches asynchronously. |
| **Security First** | LLM binds to `127.0.0.1` only. API key cache is `chmod 600` on `tmpfs`. Git diff is blocked from cloud LLM endpoints. ERR trap logs all failures for post-mortem. |
| **Hardware Awareness** | `-ngl 999` auto-offloads maximum GPU layers at runtime, CPU threads scale dynamically via `nproc`, and `--flash-attn` + `--prio 2` are tuned for the RTX 3050 Ti 4 GB VRAM ceiling. |

---

## Quick Start (5 Minutes)

### Prerequisites

- WSL2 with Ubuntu 24.04
- NVIDIA GPU with CUDA passthrough (for local LLM)
- 20GB free disk space

### Installation

```bash
# Clone the repository
cd ~
git clone https://github.com/waynegault/ubuntu-console.git
cd ubuntu-console

# Run the installer
./install.sh

# Reload your shell
exec bash
```

### First Commands

```bash
h              # Show help index (all commands)
m              # Open tactical dashboard (system stats)
up             # Run 13-step system maintenance
```

### Local LLM Setup

```bash
model list     # See available models
model use 5    # Start model #5 (optimal settings auto-applied)
burn "Hello!"  # Test inference speed (~1300 token stress test)
```

### OpenClaw Gateway

```bash
so             # Start OpenClaw gateway + local LLM
xo             # Stop gateway (LLM continues running)
oc restart     # Full restart (gateway + LLM)
```

### Git Workflow

```bash
git add .
commit_auto    # AI-generated commit message (reviews diff first)
commit: "msg"  # Your own commit message
```

### Common Tasks

| Task | Command |
|------|---------|
| Check system health | `m` (dashboard) |
| View GPU status | `gpu-status` |
| Clean temp files | `cl` |
| Edit profile | `oedit` |
| Open any file in VS Code | `code <path>` |
| Copy current path to clipboard | `cpwd` |

---

## 2. Getting Started — Usage Guide

### First Launch

When a new interactive shell opens, the profile:

1. Guards against non-interactive shells (`case $-`).
2. Exports all path constants and creates required directories.
3. Sets the ERR trap for error logging to `~/.openclaw/bash-errors.log`.
4. Detects battery presence (laptop vs desktop).
5. Bridges Windows API keys into WSL via `pwsh.exe` (cached for 1 hour).
6. Fixes the WSL2 mirrored-networking loopback interface (`loopback0`).
7. Sources OpenClaw completions and the `oc-llm-sync.sh` hook (SHA256-logged).
8. Displays the one-line startup banner.

### The Dashboard (`m`)

Type `m` at any prompt to render the full-screen Tactical Dashboard:

```
+------------------------------------------------------------------------------+
|                      TACTICAL DASHBOARD                      (ver.: 2.12) |
|------------------------------------------------------------------------------|
|  SYSTEM TIME  :: Saturday 03:04 07/03/2026                                |
|  UPTIME       :: 0d 0h 24m                                                |
|  BATTERY      :: A/C POWERED                                              |
|  CPU / GPU    :: CPU 3% | iGPU 2% | CUDA 0%                                |
|  MEMORY       :: 2.77 / 47.04 Gb                                          |
|  STORAGE      :: C: 995 Gb free | WSL: 877 Gb free                        |
|------------------------------------------------------------------------------|
|  GPU          :: RTX 3050 Ti | 0% Load | 62°C | 3897 / 4096 Mb            |
|  LOCAL LLM    :: ACTIVE Phi-4-mini-Q6_K | 14.2 t/s                        |
|  WSL          :: ACTIVE  Ubuntu-24.04  (6.6.87.2-microsoft-standard-WSL2) |
|------------------------------------------------------------------------------|
|  OPENCLAW     :: [ONLINE]  v2026.3.2    (or [NOT INSTALLED] if missing)   |
|  SESSIONS     :: 8 Active (cached 34s ago)  (hidden if not installed)     |
|  ACTIVE AGENT :: 14% (18k of 128k)        (hidden if not installed)       |
|------------------------------------------------------------------------------|
|  TARGET REPO  :: main                                                     |
|  SEC STATUS   :: SECURE                                                   |
|------------------------------------------------------------------------------|
|            up | xo | serve | halt | chatl | commitd | status | h           |
+------------------------------------------------------------------------------+
```

The dashboard colour-codes values at industry-standard thresholds:
- **Green:** < 75% utilisation
- **Yellow:** 75–90%
- **Red:** > 90%

### Help (`h`)

Type `h` to render the full command reference inside a box-drawn panel. Every
command documented here is also listed in the help index.

**OpenClaw-aware:** When OpenClaw is not installed, all OpenClaw-related
sections are hidden from the help display to reduce clutter.

### System Maintenance (`up`)

Run `up` to execute the 13-step maintenance pipeline:

| Step | What It Does |
|---|---|
| 1. Internet Connectivity | Pings `github.com` |
| 2. APT Packages | Split cooldown: `apt-get update` (24h) + `upgrade --no-install-recommends` (7d). Dry-run first to detect dependency issues. |
| 3. NPM & Cargo | `npm update -g` and `cargo install-update -a` |
| 4. R Packages | Updates CRAN and Bioconductor packages when available |
| 5. OpenClaw Framework | Runs `openclaw doctor` (skipped if not installed) |
| 6. Python Venv Cloaking | Reports active virtual environment |
| 7. Python Fleet | Scans `/usr/bin/python3.*` for installed versions |
| 8. GPU Status | Queries `nvidia-smi` readiness |
| 9. Sanitation | Cleans temp files from `/tmp/openclaw` |
| 10. Disk Space Audit | Warns if any mount exceeds 90% (validates numeric input) |
| 11. Stale Processes | Kills orphaned `llama-server` instances |
| 12. README Sync | Checks a few tracked repo facts for documentation drift |
| 13. Documentation Drift | Lightweight README accuracy check |

Each step that involves network or package operations has a **cooldown**
stored in `~/.openclaw/maintenance_cooldowns.txt`. APT index refresh uses a
24-hour cooldown; APT upgrade and all other network steps use a 7-day
cooldown. The cooldown uses Unix timestamps and shows remaining time
(e.g., `[CACHED - 4d 12h LEFT]`).

**Race Condition Fix:** All cooldown operations use `flock -x` for exclusive
access to prevent parallel `up` runs from both passing the same check.

### Navigation & Convenience

| Command | What It Does |
|---|---|
| `c` or `cls` | Clear screen and redraw the startup banner |
| `reload` | `exec bash` — full profile reload |
| `cpwd` | Copy current directory path to Windows clipboard |
| `cl` | Quick cleanup of `python-*.exe` and `.pytest_cache` in `$PWD` |
| `sysinfo` | One-line: `CPU: 12% RAM: 5.2/15.4 Gb Disk: 142 Gb iGPU: 3%/47°C CUDA: 12%` |
| `get-ip` | Show WSL IP and external WAN IP |
| `logtrim` | Trim any log file > 1 MB to its last 1000 lines |
| `oedit` | Open `tactical-console.bashrc` in VS Code |
| `code <path>` | Open anything in VS Code (lazy-resolved path) |

### Virtual Environment Auto-Activation

The `cd` command is overridden. When you enter a directory containing
`.venv/bin/activate`, it is automatically sourced. When you leave the project
directory tree, `deactivate` is called automatically. The dashboard shows
active venvs under the "CLOAKING" row.

**Error handling:** If venv activation fails, a warning is printed and
`VIRTUAL_ENV` is cleared to prevent confusion.

### Shell Prompt

The custom prompt shows:

```
username ▼ ✓ ~/projects/myapp (myenv) >
```

- **▼** — Present if user is in the `sudo` group (admin badge).
- **✓ / ×** — Green checkmark or red cross for last command exit status.
- **(myenv)** — Active Python virtual environment name.
- Empty-enter detection: pressing Enter with no command clears the error badge.

**Inter-prompt spacing:** A single blank line separates consecutive prompts.
This is achieved solely by PS1's leading `\n`. PS0 is intentionally unset —
using both PS0 and PS1 newlines would produce a double blank line after
commands that produce no output (e.g., `cd`).

---

## 3. OpenClaw Integration

### What Is OpenClaw?

OpenClaw is a Node.js-based AI agent framework (v2026.3.2) that runs as a
**systemd user service** on port 18790. It provides multi-agent orchestration,
session management, and tool-use capabilities. The Tactical
Profile wraps the entire OpenClaw CLI with ergonomic shell commands.

### Architecture

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
│  │  │  │  (port 18790)             (8081)   │  │  │  │
│  │  │  └────────────────────────────────────┘  │  │  │
│  │  └─────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

### API Key Bridge

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

### Gateway Lifecycle

| Command | What It Does |
|---|---|
| `so` | Start the OpenClaw gateway. Injects API keys into systemd, runs `openclaw gateway start`, waits 3s, checks port 18790. **Fails gracefully if OpenClaw not installed.** |
| `xo` | Stop the gateway (**stop only — does not restart**). Runs `openclaw gateway stop`, then `systemctl --user stop openclaw-gateway.service`, removes supervisor lock. When called from an AI agent context, prints a warning to use `openclaw gateway restart` instead. **Fails gracefully if OpenClaw not installed.** |
| `oc-restart` | Restart gateway (native: `openclaw gateway restart`). **Fails gracefully if OpenClaw not installed.** |
| `oc-health` | Deep probe: checks port 18790, then calls `openclaw health --json` and parses the status field. Supports `--json` and `--plain` for automation. |
| `oc-tail` | Live-tail gateway logs via `openclaw logs --follow`. |

### Logs

| Command | What It Does |
|---|---|
| `le` | Show last 40 lines of gateway stderr from `journalctl --user -u openclaw-gateway.service` |
| `lo` | Show last 120 lines of gateway stdout from `journalctl` |
| `lc` | Rotate and vacuum the gateway journal logs |
| `oclogs` | Open `/tmp/openclaw/openclaw.log` in VS Code |
| `ologs` | `cd` into the OpenClaw logs directory |

### Agent & Session Management

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

### Configuration & Diagnostics

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

### Backup & Restore

| Command | What It Does |
|---|---|
| `oc-backup` | ZIP snapshot of OpenClaw config (`openclaw.json`, `auth.json`), `workspace/`, `agents/`, `models.conf`, `~/.bashrc` loader, `tactical-console.bashrc`, standalone scripts (`~/.local/bin/oc-*`, `llama-watchdog.sh`, `tac_hostmetrics.sh`), and systemd units. Saved to `~/.openclaw/backups/snapshot_YYYYMMDD_HHMMSS.zip`. |
| `oc-restore` | Restore from the most recent snapshot (destructive — prompts for confirmation). Validates ZIP contents, accepts config-only backups, and supports `--dry-run`. |

### Extensions & Advanced

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

### Knowledge Graph (`oc g`)

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

### Key Paths

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

---

## 4. Local LLM System

### Overview

The profile provides a complete local inference stack built on
[llama.cpp](https://github.com/ggerganov/llama.cpp). Models are stored as
GGUF files, managed through a pipe-delimited registry, and served via the
`llama-server` binary on port 8081. The system exposes an OpenAI-compatible
API at `http://127.0.0.1:8081/v1/chat/completions`.

All LLM functions are **pure bash + curl + jq** — no Python dependency.

### Model Registry

The registry lives at `/mnt/m/.llm/models.conf` and uses an 11-field pipe-delimited
format (auto-generated by `model scan`):

```
#|name|file|size_gb|arch|quant|layers|gpu_layers|ctx|threads|tps
1|llama3.3-8b|llama3.3-8b.gguf|4.4|llama|Q4_K_M|33|33|4096|8|42.5
2|Phi-4-mini|microsoft_Phi-4-mini-instruct-Q6_K.gguf|3.0|phi3|Q6_K|32|32|8192|8|58.2
3|Qwen3-8B|Qwen_Qwen3-8B-Q4_K_M.gguf|4.7|qwen2|Q4_K_M|36|28|4096|8|35.1
```

Fields are auto-calculated by `model scan` from GGUF metadata. The `tps`
column is populated by `model bench`.

### Hardware Tuning

| Parameter | Value | Rationale |
|---|---|---|
| `-ngl 999` | max offload | Tells llama.cpp to offload the maximum layers that fit in VRAM at runtime. More accurate than pre-calculating a fixed count, since available VRAM varies at launch time. |
| `-t` (threads) | dynamic via `nproc` | CPU-only: 80%, partial offload: 70%, full GPU: 50% of available threads. Scales automatically to the host CPU. |
| `--batch-size` | 4096 (GPU) / 512 (CPU) | Larger batches improve prompt eval speed when GPU is active. CPU-only uses smaller batches to avoid memory pressure. |
| `--ubatch-size` | 1024 (GPU) / 512 (CPU) | Micro-batch size for continuous batching. |
| `--flash-attn on` | GPU only | Reduces VRAM bandwidth pressure, critical for 4 GB GPUs. Improves throughput without quality loss. |
| `--prio 2` | always | Elevates llama-server process priority on hybrid CPU systems. |
| `--mlock` | always | Locks model weights in memory to prevent swapping. |
| `--cont-batching` | always | Enables continuous batching for concurrent requests. |
| `--jinja` | always | Enables Jinja2 chat template processing from GGUF metadata (Qwen3, Phi-4, Gemma3). |
| Bind address | `127.0.0.1` | Prevents LAN exposure — loopback only. |
| Health poll | adaptive 45–180s | Shared readiness logic is used by both `model use` and `model bench`, with longer timeouts for CPU-only and larger models. |

### Quantization Guide

The file `~/ubuntu-console/quant-guide.conf` is a manually editable
configuration that rates GGUF quantizations for the RTX 3050 Ti (4 GB VRAM):

| Rating | Quants | Meaning |
|---|---|---|
| **recommended** | Q4_K_M, Q4_K_S | Best balance of speed, quality, and GPU fit. |
| **acceptable** | Q3_K_M/L/S, Q5_K_M/S, Q2_K, IQ variants | Works but may reduce GPU offload or be slower. |
| **discouraged** | Q6_K, Q8_0, F16, F32, BF16 | Too large for 4 GB VRAM — most layers stay on CPU. |

**Integration points:**
- `model download` reads the guide and **warns** (does not block) when downloading a discouraged quant. The user can override interactively.
- `model scan` reads the guide and **auto-archives** discouraged quants from `/mnt/m/active/` to `/mnt/m/archive/`, skipping the currently running model. The registry is renumbered after archival.

Edit `quant-guide.conf` directly to adjust ratings as hardware or advice changes.

### Model Lifecycle Commands

| Command | What It Does |
|---|---|
| `model scan` | Scan `$LLAMA_MODEL_DIR` for GGUF files, read metadata, auto-calculate optimal gpu_layers/ctx/threads, rebuild registry, and auto-archive discouraged quants via `quant-guide.conf`. |
| `model list` | Show numbered model registry with name, file, size, arch, quant, layers, TPS. Active model marked with ▶. |
| `model use N` | Start model #N with `-ngl 999`, dynamic threads, `--flash-attn on`, `--prio 2`, `--mlock`, `--jinja`. Batch sizes: 4096/1024 for GPU, 512/512 for CPU-only. Reports actual GPU offload count after boot. Uses shared adaptive health polling. |
| `model stop` | `pkill` the llama-server process, remove state file |
| `model status` | Show currently running model details. Supports `--json` and `--plain`. |
| `model doctor` | Validate registry integrity, default model wiring, GPU visibility, watchdog state, and local ports |
| `model recommend` | Rank scanned models for a 4 GB VRAM system using quant, size, architecture, and saved TPS |
| `model info N` | Display full details for model #N including on-disk status |
| `model bench` | Benchmark all on-disk models: starts each, runs burn-in, records TPS. Results persist to `/mnt/m/.llm/bench_*.tsv`. |
| `model bench-diff` / `model bench-compare` | Compare two benchmark TSV runs |
| `model bench-history` | Summarise recent saved benchmark TSV runs |
| `model delete N` | Permanently delete model #N from disk and deregister. Supports `--dry-run`. |
| `model archive N` | Move model #N to `/mnt/m/archive/` and deregister. Supports `--dry-run`. |
| `model download` | Download GGUF models from Hugging Face Hub (`repo:file` format). Checks `quant-guide.conf` and warns on discouraged quants. Validates disk space before downloading. |
| `serve N` | Convenience alias for `model use N` |
| `halt` | Convenience alias for `model stop` |
| `wake` | Lock GPU persistence mode (`nvidia-smi -pm 1`) to prevent WDDM sleep |
| `mlogs` | Open the llama-server log file in VS Code |

### State File

When `model use N` starts a model, the **model number** (integer) is written
atomically (`.tmp` → `mv`) to `/dev/shm/active_llm`. The dashboard and
watchdog look up the full registry entry by this number.

After boot, the actual GPU layer offload count is extracted from the
llama-server log and displayed (e.g., `GPU Offload: [offloading 24 layers to GPU]`).

### Chat & Inference Commands

| Command | What It Does |
|---|---|
| `chatl [msg]` | **Multi-turn chat REPL.** Maintains full conversation history as a JSON array. Streams SSE tokens in real time. Type `end-chat` or Ctrl-C to exit. |
| `chat-context <file> "question"` | Feed a file as context, then ask about it (capped at 16,000 chars). |
| `chat-pipe` | Pipe stdin as context: `cat error.log \| chat-pipe "What's wrong?"` |
| `explain` | Explain the last command you ran (uses `fc -ln -2 -2` for reliability). |
| `wtf [topic]` | Topic explanation REPL. Ask about tools/concepts, stay in loop. |

### Streaming Architecture

The `__llm_stream` function implements Server-Sent Events (SSE) parsing in
pure bash:

1. `curl --no-buffer` sends a streaming request to the OpenAI-compatible API.
2. Lines are read one at a time. Lines starting with `data: ` are parsed.
3. `jq` extracts `.choices[0].delta.content` from each SSE chunk.
4. Content is `printf`'d immediately for real-time display.
5. On the final chunk, `usage.completion_tokens` is captured if the server
   reports it; otherwise chunk count is used as an approximation.
6. Tokens-per-second is calculated using `date +%s%N` (nanosecond precision)
   and written to `/dev/shm/last_tps` for dashboard display.

### Burn-In Stress Test

`burn` sends a ~1,300 token physics prompt as a **non-streaming** request,
measures wall time with nanosecond precision, and reports tokens/second. The
result is cached for dashboard display. Useful for benchmarking different
models and GPU states.

`model bench` extends this: it iterates over all on-disk models, boots each
one, runs the burn prompt, collects TPS, and writes a TSV file to
`/mnt/m/.llm/bench_YYYYMMDD_HHMMSS.tsv` for historical comparison. Results are
displayed in a box-drawn summary table.

### OpenClaw ↔ LLM Bridge

- `oc-local-llm` configures OpenClaw to route agent requests through your
  local `llama-server` instead of a cloud provider, saving API costs.
- `oc-sync-models` syncs the local model registry with OpenClaw's model scan.
- `oc-failover on` enables automatic fallback to a cloud provider when the
  local LLM is offline (requires `OPENAI_API_KEY` or `ANTHROPIC_API_KEY`).

### Key Paths

| Path | Purpose |
|---|---|
| `~/llama.cpp/` | llama.cpp installation root (`$LLAMA_ROOT`) |
| `/mnt/m/active/` | Active GGUF model files (`$LLAMA_MODEL_DIR`) |
| `/mnt/m/archive/` | Archived/discouraged models (`$LLAMA_ARCHIVE_DIR`) |
| `~/llama.cpp/build/bin/llama-server` | Server binary (`$LLAMA_SERVER_BIN`) |
| `/mnt/m/.llm/models.conf` | Model registry — 11-field format (`$LLM_REGISTRY`) |
| `/mnt/m/.llm/bench_*.tsv` | Benchmark history from `model bench` |
| `~/ubuntu-console/quant-guide.conf` | Quantization priority ratings (`$QUANT_GUIDE`) |
| `/dev/shm/active_llm` | Active model number (integer) |
| `/dev/shm/llama-server.log` | Server stdout/stderr log |
| `/dev/shm/last_tps` | Last measured tokens/sec |
| `/dev/shm/tac_llm_slots` | Async-cached `/slots` endpoint data (5s TTL) |

---

## 5. Developer Guide — How the Profile Works

### Modular Architecture

The profile is split into a thin loader (`tactical-console.bashrc`, ~195 lines)
and 15 numbered modules under `scripts/`. Each module has a metadata block
documenting its dependencies and exports:

```bash
# @modular-section: <name>
# @depends: <comma-separated section names>
# @exports: <public functions/variables>
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
```

The loader sources every `scripts/[0-9][0-9]-*.sh` file in numeric order.
Numeric prefixes enforce the dependency chain — `01-constants.sh` loads first,
`15-model-recommender.sh` loads last.

> **Monolith backup:** The pre-modularisation single-file version is preserved
> as `tactical-console.bashrc.monolith` (5,184 lines) for reference and
> rollback.

| Module | File | Lines | Purpose |
|---|---|---|---|
| §0 | `tactical-console.bashrc` | 195 | Version, AI editor rules, architecture map, module loader, missing module warning |
| §1 | `scripts/01-constants.sh` | 327 | All paths, ports, env vars. Single source of truth. `__TAC_OPENCLAW_OK` functional check. |
| §2 | `scripts/02-error-handling.sh` | 60 | ERR trap → `bash-errors.log` (exit codes ≥ 2, whitelisted commands excluded) |
| §3 | `scripts/03-design-tokens.sh` | 48 | ANSI colour constants (`readonly`, re-source safe) |
| §4 | `scripts/04-aliases.sh` | 159 | Short commands, VS Code wrappers, tactical shortcuts (`c`, `cls`, `le`, `lo` with PIPESTATUS) |
| §5 | `scripts/05-ui-engine.sh` | 518 | Box-drawing primitives: `__tac_header`, `__fRow`, `__hRow`, `__strip_ansi`, `__threshold_color` |
| §6 | `scripts/06-hooks.sh` | 156 | `cd` override (venv auto-activate), prompt (`PS1`), `__test_port`, admin badge |
| §7 | `scripts/07-telemetry.sh` | 362 | Host metrics (CPU + dual GPU), NVIDIA detail, battery, git, disk, tokens, OC version, LLM slots — all background-cached via `__cache_fresh` with trap cleanup |
| §8 | `scripts/08-maintenance.sh` | 710 | `up` (13 steps), `cl`, `get-ip`, `sysinfo`, `logtrim`, cooldown system with flock |
| §9 | `scripts/09-openclaw.sh` | 2357 | Full OpenClaw wrapper suite (gateway, backup, bridge, `oc-failover`, wacli, `oc-kgraph`, whitelist subcommand validation, process kill safety) |
| §10 | `scripts/10-deployment.sh` | 430 | `mkproj` (disk space check), `deploy_sync`, `commit_deploy`, `commit_auto` (PID-verified, secret detection) |
| §11 | `scripts/11-llm-manager.sh` | 2961 | `__require_llm`, model management, streaming chat, burn, bench, explain, `__calc_gpu_layers`, `__gguf_metadata` |
| §12 | `scripts/12-dashboard-help.sh` | 640 | `tactical_dashboard` (OpenClaw-aware), `tactical_help`, `bashrc_diagnose` (OpenClaw status) |
| §13 | `scripts/13-init.sh` | 148 | `mkdir -p` (OpenClaw-aware), completions, loopback fix, bridge call, exit trap (chained) |
| §14 | `scripts/14-wsl-extras.sh` | 115 | WSL/X11 startup helpers, OpenClaw completions sourcing (guarded), vault env loading |
| §15 | `scripts/15-model-recommender.sh` | 195 | AI model recommendations by use case (bc fallback for integer math) |

### Dependency Graph

```
01-constants.sh ────────────────────────────────────────────┐
02-error-handling.sh       ← 01                             │
03-design-tokens.sh        (standalone)                     │
04-aliases.sh              ← 01                             │
05-ui-engine.sh            ← 01, 03                         │
06-hooks.sh                ← 01, 03                         │
07-telemetry.sh            ← 01, 03, 05                     │
08-maintenance.sh          ← 01, 03, 05, 07                 │
09-openclaw.sh             ← 01, 03, 05, 06                 │
10-deployment.sh           ← 01, 03, 05, 06                 │
11-llm-manager.sh          ← 01, 03, 05, 06                 │
12-dashboard-help.sh       ← 01, 03, 05, 07, 06, 09, 11    │
13-init.sh                 ← all above                      │
14-wsl-extras.sh           ← 01 (optional startup helpers) ─┘
```

### Naming Conventions

| Pattern | Meaning | Examples |
|---|---|---|
| `__double_underscore` | Internal/private helper | `__test_port`, `__get_host_metrics`, `__strip_ansi` |
| `kebab-case` | User-facing command | `oc-health`, `get-ip`, `oc-backup` |
| Lowercase abbreviation | Tactical shortcut | `so`, `xo`, `cl`, `m`, `h` |

**Never** use PascalCase or camelCase for function names.

### Non-Interactive Access (`env.sh` + `tac-exec`)

The interactive guard in `tactical-console.bashrc` (`case $-`) prevents
non-interactive shells (exec environments, cron, AI agents) from loading the
profile. This is intentional — `sftp` and `rsync` must not trigger UI
side-effects. But AI agents and automation scripts need access to the ~100+
functions defined in the profile.

**`env.sh`** is a library loader that sources modules 01–12 directly,
bypassing the interactive guard and skipping `13-init.sh` (which runs
screen clear, completions, WSL loopback fixes, and EXIT traps). It is
idempotent (guarded by `__TAC_ENV_LOADED`) and sets `TAC_LIBRARY_MODE=1`
so functions can detect non-interactive sourcing if needed.

**`bin/tac-exec`** sources `env.sh` then runs `"$@"`. It is symlinked to
`~/.local/bin/tac-exec` for PATH access.

```bash
# AI agent or cron job runs:
tac-exec oc health
tac-exec model list
tac-exec so
tac-exec serve 4

# Or source directly:
source ~/ubuntu-console/env.sh && oc backup
```

Thin wrappers in `~/.local/bin/` (`so`, `xo`, `serve`, `oc-backup`, etc.)
delegate to `tac-exec` rather than re-implementing function logic. This
ensures all callers use the canonical function definitions with full error
handling, pre-flight checks, and UI formatting.

**Rule:** Never extract bash functions as standalone scripts. Always
delegate through `tac-exec`.

### Cross-Cutting State

These variables are written in one section and read by another. They are the
coupling points that must be preserved during modularisation:

| Variable | Written By | Read By | Medium |
|---|---|---|---|
| `LAST_TPS` | `burn`, `__llm_stream` (§11) | `tactical_dashboard` (§12) | `/dev/shm/last_tps` |
| `__LAST_LLM_RESPONSE` | `__llm_chat_send` (§11) | `local_chat` (§11) | Shell variable |
| `ACTIVE_LLM_FILE` | `model use` (§11) | `oc-local-llm` (§9), dashboard (§12) | `/dev/shm/active_llm` |
| Host metrics cache | `tac_hostmetrics.sh` (external) | `__get_host_metrics` (§7), dashboard (§12) | `/dev/shm/tac_hostmetrics` |
| LLM slots cache | `__get_llm_slots` (§7) | `tactical_dashboard` (§12) | `/dev/shm/tac_llm_slots` |
| OC version cache | `__get_oc_version` (§7) | `tactical_dashboard` (§12) | `/dev/shm/tac_oc_version` |
| `VSCODE_BIN` | `__resolve_vscode_bin` (§1) | aliases (§3) | Shell variable + `/dev/shm/vscode_path` |
| `_TAC_ADMIN_BADGE` | hooks (§6) | `custom_prompt_command` (§6) | Shell variable |
| `CooldownDB` | constants (§1) | maintenance (§8) | `~/.openclaw/maintenance_cooldowns.txt` |
| `__TAC_HAS_BATTERY` | constants (§1) | `__get_battery` (§7) | Shell variable |
| `__TAC_INITIALIZED` | init (§13) | init (§13) | Shell variable |
| `__TAC_BG_PIDS` | `tactical_dashboard` (§12) | EXIT trap (§13) | Shell array (reset per render) |

### Telemetry Caching Strategy

All telemetry functions follow the same pattern to avoid blocking the UI.
The shared helper `__cache_fresh <path> <ttl>` centralises the freshness
check:

```bash
__cache_fresh() {
    [[ -f "$1" ]] && (( $(date +%s) - $(stat -c %Y "$1") < $2 ))
}

function __get_METRIC() {
    local cache="$TAC_CACHE_DIR/tac_METRIC"
    # 1. Return cached data if fresh
    if __cache_fresh "$cache" TTL; then
        cat "$cache"; return
    fi
    # 2. Launch background subshell to refresh
    (
        # ... compute new value ...
        echo "$value" > "${cache}.tmp" && mv "${cache}.tmp" "$cache"
    ) &>/dev/null &
    # 3. Return stale data (or placeholder) immediately
    [[ -f "$cache" ]] && cat "$cache" || echo "Querying..."
}
```

Cache TTLs per metric:

| Metric | TTL | Rationale |
|---|---|---|
| Host Metrics (CPU + iGPU + CUDA) | 10s | iGPU from `typeperf.exe` 3D engine, CUDA from `nvidia-smi` compute engine |
| GPU (NVIDIA detail) | 10s | nvidia-smi is slow (~1.2s) |
| Battery | 120s | Changes slowly |
| Context Used | 30s | Scans `agents/*/sessions/sessions.json` for token usage via `jq` |
| OC Sessions | 60s | Uses `openclaw sessions --all-agents --json`; displays cache age |
| OC Version | 86400s (24h) | CLI version barely changes |
| LLM Slots | 5s | Async query to llama.cpp `/slots` endpoint |

All caches use **atomic writes** (`write .tmp` → `mv .tmp final`) to prevent
partial reads by concurrent dashboard renders.

### Port Checking

`__test_port` uses `ss -tln "sport = :PORT"` to query the kernel socket
table. This returns in ~20ms and never hangs, unlike the previous
`/dev/tcp` approach which would block indefinitely on closed ports in WSL2
(no TCP RST sent for refused connections).

### UI Engine

All box-drawing functions use `printf -v` for padding generation (zero
subshells). The `__strip_ansi` function is pure bash regex — no `sed`, no
forks — critical because it is called 20+ times per dashboard render.

Layout constants are derived from `UIWidth` (default 80):
- `__fRow` value column: `UIWidth - 20` characters
- `__hRow` description column: `UIWidth - 22` characters
- Values exceeding their column width are truncated with `...`

### Error Handling

The ERR trap logs to `~/.openclaw/bash-errors.log` with timestamps:

```
2026-03-07 14:32:01 [EXIT 127] some_missing_command --flag
```

Exit code 1 is **filtered out** because `grep`, `test`, and `[[ ]]` return 1
for normal "not found" / "false" conditions. Only exit codes ≥ 2 are logged.

### Security Measures

1. **LLM loopback binding** — `llama-server` binds to `127.0.0.1`, not `0.0.0.0`.
2. **API key cache** — `chmod 600` on tmpfs (`/dev/shm`). Never written to disk.
3. **Commit auto guard** — `commit_auto` blocks sending git diffs to non-localhost LLM URLs and verifies `llama-server` PID is actually running before sending.
4. **oc-llm-sync.sh integrity** — SHA256 hash is verified before sourcing. Mismatches skip the source and warn. Use `oc-trust-sync` to record a new trusted hash.
5. **ERR trap** — All failed commands (exit ≥ 2) are logged with timestamps.
6. **Bridge timeout** — `pwsh.exe` calls have a 5-second `timeout` to prevent hangs.
7. **Sudo guard** — WSL loopback fix uses `sudo -n` (non-interactive only).
8. **Variable name validation** — Bridge skips vars with non-`[a-zA-Z0-9_]` characters.

---

## 6. Modular Architecture (Completed)

### Overview

As of v3.0, the profile has been fully modularised. The original monolithic
single file (~5,184 lines) was split into a thin loader and 14 numbered
modules under `scripts/`. The pre-modularisation file is preserved as
`tactical-console.bashrc.monolith` for reference and emergency rollback.

### Structure

```
~/ubuntu-console/
├── tactical-console.bashrc            # Thin loader (~147 lines) — version,
│                                      #   AI instructions, architecture map,
│                                      #   module sourcing loop
├── tactical-console.bashrc.monolith   # Pre-modularisation backup (5,184 lines)
└── scripts/
    ├── 01-constants.sh                # All paths, ports, env vars
    ├── 02-error-handling.sh           # ERR trap → bash-errors.log
    ├── 03-design-tokens.sh            # ANSI colour constants (readonly)
    ├── 04-aliases.sh                  # Short commands, VS Code wrappers
    ├── 05-ui-engine.sh                # Box-drawing primitives
    ├── 06-hooks.sh                    # cd override, prompt (PS1), port test
    ├── 07-telemetry.sh                # CPU, GPU, battery, git, disk, tokens
    ├── 08-maintenance.sh              # up, cl, get-ip, sysinfo, logtrim
    ├── 09-openclaw.sh                 # Full OpenClaw wrapper suite + oc-kgraph
    ├── 10-deployment.sh               # mkproj, git commit+push, deploy
    ├── 11-llm-manager.sh              # Model mgmt, chat, burn, bench
    ├── 12-dashboard-help.sh           # Dashboard ('m') and Help ('h')
    ├── 13-init.sh                     # mkdir, completions, WSL loopback, exit trap
    └── 14-wsl-extras.sh               # WSL/X11 startup helpers, completions
```

### The Loader

The thin loader in `tactical-console.bashrc` contains the interactive guard,
version constant, AI editor instructions, and a simple sourcing loop:

```bash
_tac_module_dir="$HOME/ubuntu-console/scripts"

for _tac_f in "$_tac_module_dir"/[0-9][0-9]-*.sh
do
    [[ -f "$_tac_f" ]] && source "$_tac_f"
done

unset _tac_f _tac_module_dir
```

### Ordering Rules

Files are numbered `01–13` to enforce source order. The dependency graph
(§5 above) dictates that:

- `01-constants.sh` must be first (everything depends on it).
- `03-design-tokens.sh` must precede `05-ui-engine.sh`.
- `13-init.sh` must be last (runs startup side-effects).
- All other modules can be reordered as long as their `@depends` are
  satisfied.

### Benefits Realised

| Benefit | Detail |
|---|---|
| **Faster iteration** | Edit `11-llm-manager.sh` without scrolling past 1,200 lines of unrelated OpenClaw code. |
| **Targeted testing** | `bash -n scripts/09-openclaw.sh` checks only OpenClaw functions. |
| **Selective loading** | On a server with no GPU, skip `11-llm-manager.sh`. On a headless box, skip `12-dashboard-help.sh`. |
| **Reduced merge conflicts** | Edits to OpenClaw and LLM code never touch the same file. |
| **Git blame clarity** | `git log scripts/09-openclaw.sh` shows only OpenClaw changes. |
| **Easier onboarding** | A new developer reads one 200-line module instead of a 5,184-line monolith. |

### Monolith Backup

The file `tactical-console.bashrc.monolith` is the last pre-split version of
the profile. It is kept in the repository for:

- **Reference** — comparing behaviour before and after modularisation.
- **Emergency rollback** — if the modular loader breaks, `~/.bashrc` can be
  pointed back at the monolith to restore a working shell immediately.

Do not edit the monolith — it is a frozen snapshot.

### Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Source order bugs | Numeric prefixes enforce deterministic ordering. `bash -n` runs on every module in CI. |
| `readonly` collisions on re-source | Already guarded with `[[ -z "${C_Reset:-}" ]]`. |
| Missing module breaks shell | The loader's `[[ -f ]]` guard skips missing files gracefully. |
| Performance regression (many `source` calls) | 13 `source` calls add < 5ms total. Measured on this hardware. |

---

## 7. Command Reference

### Quick Reference Card

| Command | Category | Description |
|---|---|---|
| `m` | Dashboard | Render full tactical dashboard |
| `h` | Help | Show command help index |
| `up` | Maintenance | 12-step system maintenance |
| `cls` | Shell | Clear screen + banner |
| `reload` | Shell | Full profile reload (`exec bash`) |
| `sysinfo` | System | One-line hardware summary |
| `get-ip` | Network | WSL + WAN IP addresses |
| `cpwd` | Utility | Copy path to clipboard |
| `cl` | Utility | Quick temp cleanup (`--dry-run` supported) |
| `docs-sync` | Utility | Check README-tracked repo facts for drift |
| `logtrim` | Utility | Trim logs > 1 MB |
| `oedit` | Editor | Open `tactical-console.bashrc` in VS Code |
| `code` | Editor | Open anything in VS Code |
| `so` | OpenClaw | Start gateway (warns if local LLM provider offline) |
| `xo` | OpenClaw | Stop gateway (stop only — use `oc restart` to restart) |
| `oc-restart` | OpenClaw | Restart gateway (native: openclaw gateway restart) |
| `oc-health` | OpenClaw | Deep health probe (`--json` / `--plain`) |
| `os` | OpenClaw | List sessions |
| `oa` | OpenClaw | List agents |
| `ocstart` | OpenClaw | Send agent turn |
| `ocstop` | OpenClaw | Stop agent |
| `status` | OpenClaw | Quick status |
| `ocstat` | OpenClaw | Full status |
| `ocgs` | OpenClaw | Deep gateway status |
| `ockeys` | OpenClaw | Show API key visibility |
| `oc-refresh-keys` | OpenClaw | Force re-import API keys |
| `oc-backup` | OpenClaw | Snapshot config, scripts, systemd units to ZIP |
| `oc-restore` | OpenClaw | Restore from ZIP (validates contents, `--dry-run`) |
| `oc-diag` | OpenClaw | 5-point diagnostic |
| `oc-doctor-local` | OpenClaw | End-to-end local gateway + llama.cpp validation |
| `oc-env` | OpenClaw | Dump env vars |
| `oc-config` | OpenClaw | Get/set config |
| `oc-failover` | OpenClaw | Cloud fallback toggle (on/off/status) |
| `oc g` | OpenClaw | Launch knowledge graph server and open in browser |
| `oc-local-llm` | OpenClaw | Link to local LLM |
| `oc-sync-models` | OpenClaw | Sync model registry |
| `oc-trust-sync` | OpenClaw | Save current oc-llm-sync.sh SHA256 as trusted |
| `wacli` | OpenClaw | WhatsApp CLI wrapper (auto-injects `--store` flag) |
| `le` / `lo` / `lc` | Logs | View stderr / stdout / clear |
| `model list` | LLM | Show numbered model registry (▶ = active) |
| `model use N` | LLM | Start model #N with optimal GPU/ctx/thread settings |
| `model stop` | LLM | Stop inference server |
| `model status` | LLM | Show running model details (`--json` / `--plain`) |
| `model doctor` | LLM | Validate registry/default/GPU/watchdog/ports |
| `model recommend` | LLM | Rank models for a 4 GB VRAM system |
| `model info N` | LLM | Full details for model #N |
| `model scan` | LLM | Scan GGUF files, read metadata, rebuild registry |
| `model download` | LLM | Fetch from HuggingFace |
| `model delete N` | LLM | Delete model #N from disk and registry (`--dry-run`) |
| `model archive N` | LLM | Move model #N to archive and deregister (`--dry-run`) |
| `model bench` | LLM | Benchmark all on-disk models, persist TSV |
| `model bench-diff` / `model bench-compare` | LLM | Compare two benchmark runs |
| `model bench-history` | LLM | Summarise recent benchmark runs |
| `serve N` / `halt` | LLM | Aliases for use/stop |
| `wake` | GPU | Lock persistence mode |
| `burn` | LLM | Stress test + TPS benchmark |
| `chatl` | LLM | Multi-turn chat REPL |
| `chat-context` | LLM | File context → LLM |
| `chat-pipe` | LLM | Stdin context → LLM |
| `explain` | LLM | Explain last command |
| `wtf` | LLM | Topic explanation REPL |
| `mkproj` | Dev | Scaffold Python project |
| `commitd` | Git | Commit with message + push + deploy |
| `commit` | Git | Commit with LLM message (PID-verified) + push + deploy |
| `deploy` | Deploy | Rsync to production workspace |

---

## 8. Dependencies & Requirements

### System Requirements

| Component | Requirement |
|---|---|
| **OS** | Windows 11 Pro with WSL2 |
| **WSL Distribution** | Ubuntu 24.04 |
| **Shell** | Bash 5.2+ |
| **GPU** | NVIDIA RTX 3050 Ti (or any CUDA-capable GPU) |
| **PowerShell** | 7.4+ (as `pwsh.exe` in WSL interop PATH) |

### Required Packages (All Standard Linux)

| Package | Used By | Install |
|---|---|---|
| `jq` | All LLM/SSE functions, token scanning | `sudo apt install jq` |
| `curl` | LLM API calls, health checks, WAN IP | Pre-installed |
| `ss` (iproute2) | `__test_port` port checking | Pre-installed |
| `grep` / `awk` / `sed` | Telemetry parsing, text processing | Pre-installed |
| `find` | Token scanning, temp cleanup, session counting | Pre-installed |
| `systemctl` / `journalctl` | OpenClaw gateway lifecycle, logs | Pre-installed (systemd) |
| `typeperf.exe` | Host CPU + iGPU (Intel Iris 3D engine) telemetry | Windows built-in (WSL interop) |
| `nvidia-smi` | CUDA/compute GPU telemetry (NVIDIA RTX) — captures LLM/ML workloads that typeperf's 3D engine misses | WSL NVIDIA driver (`/usr/lib/wsl/lib/nvidia-smi`) |
| `git` | Deployment, commit, sec status | `sudo apt install git` |
| `rsync` | Deploy sync | `sudo apt install rsync` |
| `zip` / `unzip` | `oc-backup` / `oc-restore` | `sudo apt install zip unzip` |

### Optional Packages

| Package | Used By | Install |
|---|---|---|
| `huggingface-cli` | `model download` | `pip install huggingface-hub` |
| `cargo` + `install-update` | `up` step 3 (Cargo crate updates) | Rust toolchain |
| `npm` | `up` step 3 (global package updates) | Node.js |
| `openclaw` CLI | All `oc-*` commands | `npm install -g openclaw` |
| `clawhub` | `oc-skills` (optional alternate) | OpenClaw ecosystem |

### What Is NOT Required

- **Python** — All LLM streaming was rewritten to pure bash + curl + jq in v2.04.
- **Ruby** — Never used.
- **Docker** — The gateway runs as a native systemd service.

---

## 9. Troubleshooting

### Dashboard shows stale or missing data

Run `oc-cache-clear` to wipe all `/dev/shm/tac_*` caches, then `m` again.
First render after clearing will show "Querying..." for some metrics while
background refreshes run.

### CONTEXT USED shows "No data"

The CONTEXT USED row reads token usage from the most recently active
OpenClaw agent session. It scans all `agents/*/sessions/sessions.json` files
for the newest session entry containing `totalTokens` and `contextTokens`.
"No data" means either:

1. No agent sessions have been created yet.
2. The session files exist but no session has non-zero `totalTokens`.

The numbers show: **used tokens | context window size** for the most recent
agent session (any agent, not just main/Hal). Values ≥ 1000 are displayed
in `k` notation (e.g., `51k of 128k`). The row turns red at ≥ 90% context
utilisation to warn that the agent conversation is nearing the model limit.

### `so` shows "CRASHED - CHECK LOGS"

1. Run `le` to see gateway startup errors from journalctl.
2. Common cause: missing API keys. Run `oc-refresh-keys` then `so` again.
3. Check the systemd service: `systemctl --user status openclaw-gateway.service`

### `ockeys` shows WSL ✗ for keys

API keys are bridged from Windows but haven't been exported in this shell.
Run `oc-refresh-keys`. If still failing, check `pwsh.exe` is accessible:
`command -v pwsh.exe` should return a path.

### LLM shows OFFLINE

1. Check if a model is running: `model status`
2. Start one: `model use 1` (or any model number from `model list`)
3. If it fails to boot, check `cat /dev/shm/llama-server.log`
4. Run `wake` first to prevent GPU WDDM sleep issues.

### Dashboard takes > 1 second to render

All telemetry functions use background subshells with `&>/dev/null &` to
detach from the calling command substitution. If the dashboard blocks, check
that every `( ... ) &` background refresh includes `&>/dev/null` before `&`
— without it, the `$()` capture waits for the child's inherited pipe FD.
The `typeperf.exe` call in `tac_hostmetrics.sh` takes ~4s cold, so it relies
on this pattern to return stale data instantly while refreshing in the
background.

### `commit` fails with "LLM URL is not localhost"

The `commit_auto` function blocks sending git diffs to non-local LLM
endpoints as a security measure. Ensure `LOCAL_LLM_URL` points to
`http://127.0.0.1:8081/v1/chat/completions`. It also verifies the
`llama-server` process is actually running (PID check) before sending.

### `oc-llm-sync.sh hash mismatch — skipped`

The startup sequence verifies the SHA256 hash of `oc-llm-sync.sh` before
sourcing it. If the file has been modified, sourcing is skipped for safety.
Run `oc-trust-sync` to record the current file's hash as trusted.

### `up` shows everything as CACHED

Each maintenance step has a cooldown (APT index: 24h, APT upgrade and others:
7d). Wait for the cooldown to expire, or delete
`~/.openclaw/maintenance_cooldowns.txt` to force all steps to run.

### Shell starts slowly

The only potentially slow operation at startup is `__bridge_windows_api_keys`
(calls `pwsh.exe` with 5s timeout). The key cache lasts 1 hour, so this only
runs once per hour. If `pwsh.exe` is unreachable, the timeout prevents a hang.

---

## 10. Repository Layout

All project files live in a single Git repository at
`~/ubuntu-console/` (remote: `github.com/waynegault/ubuntu-console`).
`~/.bashrc` is a thin loader that sources `tactical-console.bashrc`, which in
turn sources the 15 numbered modules from `scripts/`.

**~/.bashrc enforcement:** The file is read-only (mode 444) and protected by
10 unit tests that prevent pollution with functions, aliases, exports, or
extra source commands.

### Directory Structure

```
~/ubuntu-console/
├── tactical-console.bashrc            # Thin loader + version + module sourcing loop
├── tactical-console.bashrc.monolith   # Pre-modularisation backup (frozen snapshot)
├── env.sh                             # Non-interactive library loader (all modules except 13-init.sh)
├── install.sh                         # Idempotent installer for new machines
├── quant-guide.conf                   # Quantization priority ratings (editable)
├── README.md                          # This file
├── inspection.md                      # Audit checklist
├── bin/
│   ├── tac-exec                       # Bootstrap: source env.sh + exec "$@"
│   ├── tac_hostmetrics.sh             # Host CPU + iGPU (typeperf) + CUDA (nvidia-smi)
│   ├── llama-watchdog.sh              # Watchdog: auto-restart with -ngl 999, --prio 2
│   ├── oc-gpu-status                  # Thin wrapper → tac-exec gpu-status
│   ├── oc-model-status                # Thin wrapper → tac-exec ocms
│   ├── oc-model-switch                # Thin wrapper → tac-exec serve
│   ├── oc-quick-diag                  # Thin wrapper → tac-exec oc diag
│   └── oc-wake                        # Thin wrapper → tac-exec wake
├── scripts/                           # 15 numbered profile modules (sourced in order)
│   ├── 01-constants.sh                #   All paths, ports, env vars
│   ├── 02-error-handling.sh           #   ERR trap (whitelisted commands)
│   ├── 03-design-tokens.sh            #   ANSI colour constants
│   ├── 04-aliases.sh                  #   Short commands, VS Code wrappers
│   ├── 05-ui-engine.sh                #   Box-drawing primitives
│   ├── 06-hooks.sh                    #   cd override, prompt, port test
│   ├── 07-telemetry.sh                #   CPU, GPU, battery, git, disk, tokens
│   ├── 08-maintenance.sh              #   up (13 steps), cl, get-ip, sysinfo, logtrim
│   ├── 09-openclaw.sh                 #   Gateway, backup, cron, skills, plugins, kgraph
│   ├── 10-deployment.sh               #   mkproj (disk check), git commit+push, deploy
│   ├── 11-llm-manager.sh              #   Model mgmt, chat, burn, bench, explain
│   ├── 12-dashboard-help.sh           #   Dashboard ('m') and Help ('h'), bashrc_diagnose
│   ├── 13-init.sh                     #   mkdir, completions, WSL loopback, exit trap
│   ├── 14-wsl-extras.sh               #   WSL/X11 helpers, completions, vault env
│   ├── 15-model-recommender.sh        #   AI model recommendations by use case
│   ├── kgraph.py                      #   Knowledge graph HTTP server + Cytoscape.js UI
│   ├── check-oc-agent-use.sh          #   Agent usage regression checker
│   ├── lint.sh                        #   ShellCheck + bash -n linter
│   └── run-tests.sh                   #   BATS test runner (483 tests)
├── frontend-g6/                       # React + AntV G6 knowledge graph frontend
│   ├── package.json                   #   Vite 5 + React 18 + G6 5.0
│   └── src/                           #   App.jsx, G6App.jsx, CytoscapeApp.jsx
├── tests/
│   ├── tactical-console.bats          # 473 BATS unit tests (2,368 lines)
│   └── test_kgraph.py                 # Python tests for kgraph.py
└── systemd/
    ├── llama-watchdog.service         # systemd unit for watchdog
    └── llama-watchdog.timer           # systemd timer (runs every 60s)
```

### Symlink Map

| System Path | Repo Path |
|---|---|
| `~/.bashrc` | thin loader (not in repo — sources `tactical-console.bashrc`) |
| `/mnt/m/.llm/models.conf` | `llm/models.conf` (not currently in repo) |
| `~/.local/bin/tac-exec` | `bin/tac-exec` |
| `~/.local/bin/llama-watchdog.sh` | `bin/llama-watchdog.sh` |
| `~/.local/bin/tac_hostmetrics.sh` | `bin/tac_hostmetrics.sh` |
| `~/.local/bin/oc-quick-diag` | `bin/oc-quick-diag` |
| `~/.local/bin/oc-gpu-status` | `bin/oc-gpu-status` |
| `~/.local/bin/oc-model-status` | `bin/oc-model-status` |
| `~/.local/bin/oc-model-switch` | `bin/oc-model-switch` |
| `~/.local/bin/oc-wake` | `bin/oc-wake` |
| `~/.config/systemd/user/llama-watchdog.service` | `systemd/llama-watchdog.service` |
| `~/.config/systemd/user/llama-watchdog.timer` | `systemd/llama-watchdog.timer` |

### Setup on a New Machine

```bash
git clone https://github.com/waynegault/ubuntu-console.git ~/ubuntu-console
cd ~/ubuntu-console
./install.sh     # creates thin ~/.bashrc loader + symlinks
exec bash        # reload profile
```

### Workflow

Use `oedit` to open the profile in VS Code. After saving changes, run
`reload` to apply. All edits go in `~/ubuntu-console/scripts/*.sh`
(or `tactical-console.bashrc` for version/loader changes) — never edit
`~/.bashrc` directly.

Commit and push:

```bash
cd ~/ubuntu-console
git add -A && git commit -m "description" && git push
```

---

### Obsidian + Memory Views

Gigabrain is configured to export an Obsidian-compatible vault under:

- `~/.openclaw/state/memory/gigabrain-workspace/obsidian-vault/`

The intended note content root is:
- `~/.openclaw/state/memory/gigabrain-workspace/obsidian-vault/`

### Vault layout direction
Use a **single vault root**. Do not keep generating a nested structure with an
outer wrapper vault and an inner `Gigabrain/.obsidian` vault.

If you are migrating from an older nested layout, treat the root vault as the
intended destination going forward and mirror that root to Windows for desktop
Obsidian use.

This vault should be opened in Obsidian as a **folder vault**, not as an
individual file. If Obsidian throws an `EISDIR` / “illegal operation on a
directory” error, it usually means the app is failing to watch that WSL path
through the Windows UNC bridge. In that case, prefer copying/syncing the vault
to a native Windows path for desktop Obsidian use.

Recommended viewing split:
- **Obsidian vault** → curated human memory browsing
- **`oc g`** → operational/derived graph exploration and debugging
- **OpenStinger** → temporal/entity recall investigation

---

## OpenStinger Integration

### What It Is
**OpenStinger** is a memory, reasoning, and alignment infrastructure for AI agents. It exposes **30 MCP (Model Context Protocol) tools** that any agent can call natively, built on **FalkorDB** (bi-temporal graph + vector) and **PostgreSQL** (operational audit DB).

### Purpose
- Prevents agents from hallucinating facts, drifting from values, and forgetting context
- Provides a unified memory layer compatible with any agent framework
- Enables memory portability across different agent runtimes and cloud providers
- Offers queryable operational database for audits and compliance

### Three Tiers of Tools

| Tier | Name | Tools | Function |
|------|------|-------|----------|
| **Tier 1** | Memory Harness | 11 | Bi-temporal episodic memory, hybrid BM25 + vector search, date filtering, numeric/IP search |
| **Tier 2** | StingerVault | 11 | Autonomous distillation into structured self-knowledge (identity, domain, constraints), external document ingestion |
| **Tier 3** | Gradient | 8 | Alignment evaluation, drift detection, correction engine, observability tools |

### Key Capabilities
- **30 MCP tools total** served over SSE at `http://localhost:8766/sse`
- **Hybrid search**: semantic (synonyms/paraphrases), date-range filtering, numeric/IP address search, fuzzy entity matching
- **SQL-queryable audit trail**: Every ingestion job, entity merge, and alignment event logged to PostgreSQL
- **Memory portability**: Full memory transfers via Docker volumes between hosts/runtimes

### Compatible Frameworks
OpenClaw, Nanobot, ZeroClaw, NanoClaw, PicoClaw, Claude Code, Cursor, Qwen-Agent, DeerFlow, LangGraph

### Installation

**Requirements:**
- Python 3.10+
- Docker Desktop
- One API key (Anthropic or OpenAI-compatible provider)

**Quick Start (5 minutes):**

```bash
# 1. Clone and install
git clone https://github.com/srikanthbellary/openstinger.git ~/.openclaw/vendor/openstinger
cd ~/.openclaw/vendor/openstinger
python3 -m venv .venv
source .venv/bin/activate
pip install -e "."

# 2. Configure
cp .env.example .env
cp config.yaml.example config.yaml
# Edit .env with API keys, config.yaml with sessions_dir path

# 3. Start FalkorDB
docker compose up -d

# 4. Start OpenStinger
python -m openstinger.mcp.server              # Tier 1 only
python -m openstinger.gradient.mcp.server     # All 3 tiers (30 tools)
```

### Agent Connection
```json
{
  "mcpServers": {
    "openstinger": {
      "baseUrl": "http://localhost:8766/sse"
    }
  }
}
```

### Architecture
- Runs **beside** your agent (never inside it)
- Reads session files **read-only** in the background
- Two containers: FalkorDB + PostgreSQL

### Configuration Highlights
- **Embedding options**: OpenAI, OpenAI-compatible providers (Novita, DeepSeek), or **local via Ollama** (v0.8+)
- **Session formats**: OpenClaw, DeerFlow, Qwen-Agent, or simple JSONL
- **Tier 3 ships in `observe_only` mode** by default — evaluates but doesn't block until enabled

### Browser UIs (auto-start with Docker)
- **FalkorDB Browser**: `http://localhost:3000` (visual graph)
- **Adminer**: `http://localhost:8080` (PostgreSQL inspector)

### Management Commands
```bash
oc-stinger start      # Start OpenStinger MCP server
oc-stinger stop       # Stop OpenStinger
oc-stinger status     # Check server and database status
oc-stinger logs       # Tail server logs
oc-stinger progress   # Show ingestion/processing progress
```

### Production Features
- Memory backup/restore via Docker volumes
- Cloud deployment support (remote agents connect via HTTP SSE)
- BI tool integration (Metabase, Grafana, Superset) for operational visibility

**License:** MIT License

### GPU Utilisation: CUDA vs Task Manager

Windows Task Manager defaults to showing the **3D** engine for GPU utilisation.
CUDA workloads (what llama.cpp uses) run on a different engine — **Compute_0**
or **CUDA**. If Task Manager shows 0% GPU while the LLM is running, change
the graph label from "3D" to "CUDA" or "Compute_0".

The Tactical Console avoids this problem entirely:
- **iGPU** (Intel Iris Xe) is read from `typeperf.exe` (3D engine — correct
  for integrated graphics).
- **CUDA** (NVIDIA RTX) is read from `nvidia-smi --query-gpu=utilization.gpu`,
  which reports the **compute** engine directly. This is the real LLM
  utilisation metric.

Even when measured correctly, LLM inference shows a GPU → CPU → GPU → CPU
bursty pattern (autoregressive sampling). This is normal — not a sign of
misconfiguration. High VRAM usage with bursty GPU utilisation is expected.

---

## 11. Improvement Opportunities

The March 2026 follow-up review identified a small set of near-term priorities.
Those items are now addressed in the current tree:

- **OpenClaw helper duplication removed.** The duplicate `__so_show_errors`
  definition has been consolidated so future edits only have one source of
  truth.
- **Benchmark watchdog restoration hardened.** `model bench` now restores the
  watchdog cleanly even when it exits early with no on-disk models.
- **Shared LLM registry/default lookup helpers extracted.** Default-model,
  active-model, and registry resolution now live behind common helpers used by
  model management and OpenClaw integration paths.
- **Shared llama-server health wait adopted.** `model use` and `model bench`
  now rely on the same readiness helper and timeout policy.
- **Post-refactor cleanup finished.** Small leftovers such as the unused local
  in `model()` were removed while the dispatcher was revisited.
- **README drift guard added.** A lightweight `docs-sync` check is now part of
  the maintenance flow so a few high-signal repo facts are less likely to drift.

---

## 12. Proposed Future Functionality

Several follow-up roadmap items are now implemented: `model doctor`,
`model recommend`, `model bench-history` / `model bench-compare`,
`oc doctor-local`, structured `--json` / `--plain` output for key health/status
commands, and `--dry-run` support for several destructive operations.

The most valuable remaining additions would likely be:

- **Dashboard fault surfacing** — Add a compact “last failure” or watchdog row
  to the dashboard so recent errors are visible without opening logs.
- **Registry provenance and notes** — Allow optional annotations per model
  (source URL, benchmark date, prompt format notes, preferred use case) to make
  the local model inventory more self-documenting.
- **Richer recommendation criteria** — Fold prompt-template compatibility,
  recent stability, and workload-specific hints into `model recommend`.
- **Docs-sync auto-fix mode** — Extend the lightweight drift checker into an
  opt-in fixer that can rewrite a few generated README facts when they change.

---

**Tactical Console Profile v3.1 :: WSL2 Ubuntu 24.04 :: Designed for Determinism**
