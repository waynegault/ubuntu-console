# Tactical Console Profile

> **Repo:** [`waynegault/ubuntu-console`](https://github.com/waynegault/ubuntu-console)
> **Environment:** WSL2 Ubuntu 24.04 on Windows 11 Pro
> **Hardware:** Intel i9 / Intel Iris Xe (iGPU) / RTX 3050 Ti 4 GB VRAM (CUDA)
> **Shell:** Bash 5.2+

The **Tactical Console Profile** is a modular Bash environment that turns a
WSL2 Ubuntu shell into a unified command-and-control console. A thin loader
(`tactical-console.bashrc`) sources 16 numbered profile modules from `scripts/`
in dependency order.

**Non-interactive access:** `env.sh` is a library loader that sources all
modules except `13-init.sh`, making ~100+ shell functions available to MCP
tools, AI agents, cron jobs, and automation scripts via `tac-exec`.

---

## Contents

- [Features](#features)
- [Installation](#installation)
- [Command Reference](#command-reference)
- [Dashboard & Shell Interface](#dashboard--shell-interface)
- [Local LLM System](#local-llm-system)
- [OpenClaw Integration](#openclaw-integration)
- [Maintenance Pipeline](#maintenance-pipeline)
- [Architecture & Developer Guide](#architecture--developer-guide)
- [Repository Layout](#repository-layout)
- [Dependencies](#dependencies)
- [AI Agent Access (tac-exec)](#ai-agent-access-tac-exec)
- [Troubleshooting](#troubleshooting)
- [CI Status](#ci-status)

---

## Features

- **System telemetry** — CPU, dual GPU (iGPU + CUDA), memory, disk, battery in a 78-column dashboard
- **Local LLM inference** — Full lifecycle management of `llama-server` (llama.cpp) with OpenAI-compatible API
- **OpenClaw agent framework** — Gateway lifecycle, agent orchestration, backup/restore, knowledge graph
- **Maintenance** — 13-step `up` pipeline with per-step cooldowns and race condition protection
- **Deployment** — Git commit/push with optional LLM-generated commit messages (PID-verified, secret detection)
- **Knowledge graph** — Interactive Cytoscape.js visualisation via `oc g`
- **Virtual environment auto-activation** — `cd` override activates/deactivates `.venv` automatically

## Design Principles

| Principle | Implementation |
|---|---|
| **Determinism** | Every maintenance step is idempotent with 7-day cooldowns using `flock` |
| **Zero Dependencies Beyond Coreutils** | All LLM streaming is pure `bash + curl + jq` — no Python |
| **Instant UI** | Telemetry uses `/dev/shm` caching with atomic background refresh |
| **Security First** | LLM binds to `127.0.0.1`; API key cache is `chmod 600` on tmpfs |
| **Hardware Awareness** | `-ngl 999` auto-offload, dynamic CPU thread scaling by GPU workload |

---

## Installation

### Prerequisites

- WSL2 with Ubuntu 24.04
- NVIDIA GPU with CUDA passthrough (for local LLM)
- PowerShell 7.4+ (`pwsh.exe` in WSL interop PATH)
- 20 GB free disk space

### Setup

```bash
cd ~
git clone https://github.com/waynegault/ubuntu-console.git
cd ubuntu-console
./install.sh     # Creates thin ~/.bashrc loader + symlinks to ~/.local/bin/
exec bash
```

### First Commands

```bash
h              # Show help index (all commands)
m              # Open tactical dashboard (system stats)
up             # Run 13-step system maintenance
```

---

## Command Reference

| Command | Category | Description |
|---|---|---|
| `m` | Dashboard | Render full tactical dashboard |
| `h` | Help | Show command help index |
| `up` | Maintenance | 13-step system maintenance pipeline |
| `cls` / `c` | Shell | Clear screen + banner |
| `reload` | Shell | Full profile reload (`exec bash`) |
| `sysinfo` | System | One-line hardware summary |
| `get-ip` | Network | WSL + WAN IP addresses |
| `cpwd` | Utility | Copy path to Windows clipboard |
| `cl` | Utility | Quick temp cleanup (`--dry-run` supported) |
| `logtrim` | Utility | Trim logs > 1 MB to last 1000 lines |
| `oedit` | Editor | Open `tactical-console.bashrc` in VS Code |
| `code` | Editor | Open anything in VS Code |
| `so` | OpenClaw | Start gateway (warns if local LLM provider offline) |
| `xo` | OpenClaw | Stop gateway |
| `oc-restart` | OpenClaw | Restart gateway |
| `oc-health` | OpenClaw | Deep health probe (`--json` / `--plain`) |
| `os` | OpenClaw | List sessions |
| `oa` | OpenClaw | List agents |
| `ocstart` | OpenClaw | Send agent turn |
| `ocstop` | OpenClaw | Stop agent |
| `status` | OpenClaw | Quick status |
| `ocstat` | OpenClaw | Full status |
| `ocgs` | OpenClaw | Deep gateway status |
| `ockeys` | OpenClaw | Show API key visibility |
| `oc-refresh-keys` | OpenClaw | Force re-import API keys from Windows |
| `oc-backup` | OpenClaw | Snapshot config + scripts + systemd units to ZIP |
| `oc-restore` | OpenClaw | Restore from ZIP (`--dry-run` supported) |
| `oc-diag` | OpenClaw | 5-point diagnostic |
| `oc-doctor-local` | OpenClaw | End-to-end local gateway + llama.cpp validation |
| `oc-failover` | OpenClaw | Cloud fallback toggle (`on`/`off`/`status`) |
| `oc g` | OpenClaw | Launch knowledge graph server + open in browser |
| `oc-local-llm` | OpenClaw | Bind OpenClaw to local llama.cpp |
| `oc-sync-models` | OpenClaw | Sync model registry with OpenClaw |
| `oc-trust-sync` | OpenClaw | Record current `oc-llm-sync.sh` SHA256 as trusted |
| `wacli` | OpenClaw | WhatsApp CLI wrapper (auto-injects `--store` flag) |
| `le` / `lo` / `lc` | Logs | Gateway stderr / stdout / rotate |
| `model list` | LLM | Show numbered model registry (▶ = active) |
| `model use N` | LLM | Start model #N with optimal settings |
| `model stop` | LLM | Stop inference server |
| `model status` | LLM | Show running model details (`--json` / `--plain`) |
| `model doctor` | LLM | Validate registry/default/GPU/watchdog/ports |
| `model recommend` | LLM | Rank models for a 4 GB VRAM system |
| `model info N` | LLM | Full details for model #N |
| `model scan` | LLM | Scan GGUF files, read metadata, rebuild registry |
| `model download` | LLM | Fetch from HuggingFace (warns on discouraged quants) |
| `model delete N` | LLM | Delete model #N from disk (`--dry-run`) |
| `model archive N` | LLM | Move model #N to archive (`--dry-run`) |
| `model bench` | LLM | Benchmark all on-disk models, persist TSV |
| `model bench-diff` | LLM | Compare two benchmark TSV runs |
| `model bench-history` | LLM | Summarise recent benchmark runs |
| `serve N` / `halt` | LLM | Aliases for `model use N` / `model stop` |
| `wake` | GPU | Lock GPU persistence mode |
| `burn` | LLM | Stress test + TPS benchmark |
| `chatl` | LLM | Multi-turn chat REPL |
| `chat-context` | LLM | File context → LLM |
| `chat-pipe` | LLM | Stdin context → LLM |
| `explain` | LLM | Explain last command |
| `wtf` | LLM | Topic explanation REPL |
| `mkproj` | Dev | Scaffold Python project |
| `commitd` | Git | Commit with message + push + deploy |
| `commit_auto` | Git | LLM-generated commit message (PID-verified) + push |
| `deploy` | Deploy | Rsync to production workspace |

---

## Dashboard & Shell Interface

### The Dashboard (`m`)

```
+------------------------------------------------------------------------------+
|                      TACTICAL DASHBOARD                      (ver.: 5.120)  |
|------------------------------------------------------------------------------|
|  SYSTEM TIME  :: Wednesday 09:14 22/04/2026                                 |
|  UPTIME       :: 0d 2h 41m                                                  |
|  BATTERY      :: A/C POWERED                                                |
|  CPU / GPU    :: CPU 3% | iGPU 2% | CUDA 0%                                 |
|  MEMORY       :: 2.77 / 47.04 Gb                                            |
|  STORAGE      :: C: 995 Gb free | WSL: 877 Gb free                          |
|------------------------------------------------------------------------------|
|  GPU          :: RTX 3050 Ti | 0% Load | 62°C | 3897 / 4096 Mb             |
|  LOCAL LLM    :: ACTIVE Phi-4-mini-Q6_K | 14.2 t/s                         |
|  WSL          :: ACTIVE  Ubuntu-24.04  (6.6.87.2-microsoft-standard-WSL2)   |
|------------------------------------------------------------------------------|
|  OPENCLAW     :: [ONLINE]  v2026.3.2                                        |
|  SESSIONS     :: 8 Active (cached 34s ago)                                  |
|  ACTIVE AGENT :: 14% (18k of 128k)                                          |
|------------------------------------------------------------------------------|
|  TARGET REPO  :: main                                                       |
|  SEC STATUS   :: SECURE                                                     |
|------------------------------------------------------------------------------|
|            up | xo | serve | halt | chatl | commitd | status | h            |
+------------------------------------------------------------------------------+
```

Colour thresholds: green < 75%, yellow 75–90%, red > 90% utilisation.
OpenClaw rows are hidden when OpenClaw is not installed.

### Shell Prompt

```
username ▼ ✓ ~/projects/myapp (myenv) >
```

- **▼** — Admin badge (sudo group member)
- **✓ / ×** — Green tick or red cross for last exit status
- **(myenv)** — Active Python virtual environment
- **Blank line spacing** — PS1 starts with `\n`. PS0 is intentionally unset to prevent double spacing.

### Virtual Environment Auto-Activation

The `cd` override automatically sources `.venv/bin/activate` when entering a project directory, and calls `deactivate` when leaving.

### Convenience Commands

| Command | What It Does |
|---|---|
| `c` / `cls` | Clear screen + redraw startup banner |
| `reload` | `exec bash` — full profile reload |
| `cpwd` | Copy current directory path to Windows clipboard |
| `cl` | Remove `python-*.exe` / `.pytest_cache` from `$PWD` |
| `sysinfo` | One-line: CPU / RAM / Disk / iGPU / CUDA |
| `get-ip` | WSL IP + external WAN IP |
| `logtrim` | Trim any log file > 1 MB to its last 1000 lines |
| `oedit` | Open `tactical-console.bashrc` in VS Code |

---

## Local LLM System

Built on [llama.cpp](https://github.com/ggerganov/llama.cpp). Models are GGUF files managed via a pipe-delimited registry, served on port 8081 with an OpenAI-compatible API. All functions are pure bash + curl + jq.

### Model Registry

Located at `/mnt/m/.llm/models.conf` — 11-field pipe-delimited, auto-generated by `model scan`:

```
#|name|file|size_gb|arch|quant|layers|gpu_layers|ctx|threads|tps
1|Phi-4-mini|microsoft_Phi-4-mini-instruct-Q6_K.gguf|3.0|phi3|Q6_K|32|32|8192|8|58.2
2|Qwen3-8B|Qwen_Qwen3-8B-Q4_K_M.gguf|4.7|qwen2|Q4_K_M|36|28|4096|8|35.1
```

### Hardware Tuning

| Parameter | Value | Rationale |
|---|---|---|
| `-ngl 999` | max offload | llama.cpp offloads the maximum layers that fit in VRAM at runtime |
| `-t` (threads) | dynamic | CPU-only: 80%, partial offload: 70%, full GPU: 50% of `nproc` |
| `--batch-size` | 4096 (GPU) / 512 (CPU) | Larger batches improve prompt eval speed on GPU |
| `--flash-attn on` | GPU only | Reduces VRAM bandwidth — critical for 4 GB GPUs |
| `--jinja` | always | Enables Jinja2 chat templates from GGUF metadata |
| Bind address | `127.0.0.1` | Loopback only — no LAN exposure |

### Quantization Guide

`quant-guide.conf` rates quants for the RTX 3050 Ti:

| Rating | Quants |
|---|---|
| **recommended** | Q4_K_M, Q4_K_S |
| **acceptable** | Q3_K_M/L/S, Q5_K_M/S, Q2_K, IQ variants |
| **discouraged** | Q6_K, Q8_0, F16, F32, BF16 — too large for 4 GB VRAM |

`model scan` auto-archives discouraged quants. `model download` warns (does not block) when downloading a discouraged quant.

### Chat & Inference

| Command | What It Does |
|---|---|
| `chatl [msg]` | Multi-turn REPL — full JSON history, SSE streaming, `end-chat` to exit |
| `chat-context <file> "question"` | Feed a file as context (capped at 16,000 chars) |
| `chat-pipe` | Pipe stdin: `cat error.log \| chat-pipe "What's wrong?"` |
| `explain` | Explain the last command run (uses `fc -ln -2 -2`) |
| `wtf [topic]` | Topic explanation REPL |
| `burn` | ~1,300 token physics prompt, nanosecond-precision TPS benchmark |

### Key Paths

| Path | Purpose |
|---|---|
| `/mnt/m/active/` | Active GGUF model files (`$LLAMA_MODEL_DIR`) |
| `/mnt/m/archive/` | Archived models (`$LLAMA_ARCHIVE_DIR`) |
| `/mnt/m/.llm/models.conf` | Model registry (`$LLM_REGISTRY`) |
| `/mnt/m/.llm/bench_*.tsv` | Benchmark history |
| `~/ubuntu-console/quant-guide.conf` | Quantization ratings (`$QUANT_GUIDE`) |
| `/dev/shm/active_llm` | Active model number (integer) |
| `/dev/shm/llama-server.log` | Server stdout/stderr |
| `/dev/shm/last_tps` | Last measured tokens/sec |

---

## OpenClaw Integration

OpenClaw is a Node.js AI agent framework running as a systemd user service on port 18789. The profile wraps the full OpenClaw CLI with ergonomic shell commands.

### Architecture

```
Windows 11 Pro
└── PowerShell 7 (pwsh.exe) — API keys in Windows User env
    │  pwsh.exe bridge (5s timeout)
    ▼
WSL2 Ubuntu 24.04
└── ~/.bashrc → tactical-console.bashrc → 09-openclaw.sh
    ├── __bridge_windows_api_keys() → /dev/shm/tac_win_api_keys (chmod 600)
    │   └── systemctl --user set-environment KEY=VALUE (for gateway)
    ├── openclaw-gateway.service (port 18789)
    └── llama-server (port 8081)
```

### API Key Bridge

On shell start, `__bridge_windows_api_keys()` calls `pwsh.exe` (5s timeout) to read Windows environment variables matching `API[_-]?KEY|TOKEN`. Results are written to `/dev/shm/tac_win_api_keys` (`chmod 600`, tmpfs — never hits disk). Cache TTL: 3600s. Force refresh with `oc-refresh-keys`.

For the OpenClaw gateway (systemd, not a shell child), `so()` reads the cache and injects keys via `systemctl --user set-environment` before starting the service.

### Gateway Lifecycle

| Command | What It Does |
|---|---|
| `so` | Start gateway — injects API keys into systemd, starts service, polls port 18789 |
| `xo` | Stop gateway only (use `oc restart` to restart from an AI agent context) |
| `oc-restart` | Native restart: `openclaw gateway restart` |
| `oc-health` | Deep probe: checks port 18789, calls `openclaw health --json` |
| `oc-refresh-keys` | Force re-bridge Windows API keys |

### Backup & Restore

`oc-backup` creates a ZIP of: `openclaw.json`, `auth.json`, `workspace/`, `agents/`, `models.conf`, `~/.bashrc` loader, `tactical-console.bashrc`, `~/.local/bin/oc-*`, systemd units. Saved to `~/.openclaw/backups/snapshot_YYYYMMDD_HHMMSS.zip`.

`oc-restore` prompts for confirmation, validates ZIP contents, supports `--dry-run`.

### Knowledge Graph (`oc g`)

`oc g` starts `scripts/kgraph.py` (Python HTTP server + Cytoscape.js frontend) and opens the browser. Graph is persisted to `~/.openclaw/kgraph.json` and mirrored to `~/.openclaw/kgraph.sqlite`.

Graph views: `overview` (default), `topics`, `files`, `semantic`, `raw`. A React + AntV G6 development frontend lives in `frontend-g6/` (Vite port 5173).

### Key Paths

| Path | Purpose |
|---|---|
| `~/.openclaw/` | OpenClaw root (`$OC_ROOT`) |
| `~/.openclaw/workspace/` | Active workspace |
| `~/.openclaw/agents/` | Agent definitions |
| `~/.openclaw/backups/` | ZIP snapshots |
| `~/.openclaw/openclaw.json` | Global configuration |
| `~/.openclaw/bash-errors.log` | ERR trap log |
| `/dev/shm/tac_win_api_keys` | Bridged API keys cache (chmod 600, tmpfs) |

---

## Maintenance Pipeline

Run `up` for the 13-step pipeline:

| Step | What It Does |
|---|---|
| 1. Internet | Pings `github.com` |
| 2. APT Packages | `apt-get update` (24h cooldown) + `upgrade --no-install-recommends` (7d) |
| 3. NPM & Cargo | `npm update -g` + `cargo install-update -a` |
| 4. R Packages | Updates CRAN and Bioconductor packages |
| 5. OpenClaw | Runs `openclaw doctor` (skipped if not installed) |
| 6. Python Venv | Reports active virtual environments |
| 7. Python Fleet | Scans `/usr/bin/python3.*` |
| 8. GPU Status | Queries `nvidia-smi` readiness |
| 9. Sanitation | Cleans `/tmp/openclaw` temp files |
| 10. Disk Space | Warns if any mount exceeds 90% |
| 11. Stale Processes | Kills orphaned `llama-server` instances |
| 12. README Sync | Checks tracked repo facts for documentation drift |
| 13. Documentation Drift | Lightweight README accuracy check |

### Cooldown System

Each network/package step has a cooldown in `~/.openclaw/maintenance_cooldowns.txt` (Unix timestamps). APT index: 24h; all other network steps: 7d. `flock -x` prevents race conditions when `up` runs in parallel.

---

## Architecture & Developer Guide

### Module Architecture

The profile is a thin loader (~195 lines) that sources 16 numbered profile modules from `scripts/` via an explicit array (not a glob) to guarantee load order:

```bash
_tac_expected_modules=(
    01-constants 02-error-handling 03-design-tokens 04-aliases
    05-ui-engine 06-hooks 07-telemetry 08-maintenance 09-openclaw 09b-gog
    10-deployment 11-llm-manager 12-dashboard-help 13-init 14-wsl-extras
    15-model-recommender
)
```

| Module | Lines | Purpose |
|---|---|---|
| `01-constants.sh` | 338 | All paths, ports, env vars. Single source of truth. `__TAC_OPENCLAW_OK` functional check. |
| `02-error-handling.sh` | 62 | ERR trap → `bash-errors.log` (exit codes ≥ 2; exit 1 filtered) |
| `03-design-tokens.sh` | 48 | ANSI colour constants (`readonly`, re-source safe) |
| `04-aliases.sh` | 428 | Short commands, VS Code wrappers, tactical shortcuts |
| `05-ui-engine.sh` | 534 | Box-drawing: `__tac_header`, `__fRow`, `__hRow`, `__strip_ansi`, `__threshold_color` |
| `06-hooks.sh` | 192 | `cd` override (venv auto-activate), prompt (PS1), `__test_port`, admin badge |
| `07-telemetry.sh` | 361 | CPU + dual GPU, NVIDIA detail, battery, git, disk, tokens, OC version, LLM slots |
| `08-maintenance.sh` | 1461 | `up` (13 steps), `cl`, `get-ip`, `sysinfo`, `logtrim`, cooldown system with flock |
| `09-openclaw.sh` | 3105 | Full OpenClaw wrapper suite (gateway, backup, bridge, `oc-failover`, wacli, `oc-kgraph`) |
| `09b-gog.sh` | 165 | Google CLI (gog) detection and helpers |
| `10-deployment.sh` | 460 | `mkproj` (disk space check), `deploy_sync`, `commit_deploy`, `commit_auto` |
| `11-llm-manager.sh` | 3209 | Model management, streaming chat, burn, bench, explain, `__calc_gpu_layers`, `__gguf_metadata` |
| `12-dashboard-help.sh` | 680 | `tactical_dashboard` (OpenClaw-aware), `tactical_help`, `bashrc_diagnose` |
| `13-init.sh` | 134 | `mkdir -p`, completions, WSL loopback fix, bridge call, EXIT trap (chained) |
| `14-wsl-extras.sh` | 134 | WSL/X11 startup helpers, OpenClaw completions sourcing (guarded), vault env loading |
| `15-model-recommender.sh` | 194 | AI model recommendations by use case (`bc` fallback for integer math) |

**Utility scripts** (numbered 16–20, not sourced as profile modules):

| Script | Purpose |
|---|---|
| `16-check-oc-agent-use.sh` | Agent usage regression checker (CI/tests) |
| `17-import-windows-user-env.sh` | Import Windows user environment variables |
| `18-lint.sh` | Static analysis: `bash -n` + shellcheck + Unicode safety |
| `19-mirror-gigabrain-vault-to-windows.sh` | Sync Obsidian vault to Windows |
| `20-run-tests.sh` | Pretty-printed BATS test runner |

### Dependency Graph

```
01-constants ──────────────────────────────────────────────────┐
02-error-handling    ← 01                                      │
03-design-tokens       (standalone)                            │
04-aliases           ← 01                                      │
05-ui-engine         ← 01, 03                                  │
06-hooks             ← 01, 03                                  │
07-telemetry         ← 01, 03, 05                              │
08-maintenance       ← 01, 03, 05, 07                          │
09-openclaw          ← 01, 03, 05, 06                          │
09b-gog              ← 01                                      │
10-deployment        ← 01, 03, 05, 06                          │
11-llm-manager       ← 01, 03, 05, 06                          │
12-dashboard-help    ← 01, 03, 05, 06, 07, 09, 11             │
13-init              ← all above                               │
14-wsl-extras        ← 01 (optional startup helpers) ──────────┘
15-model-recommender ← 01, 11
```

### Naming Conventions

| Pattern | Meaning | Examples |
|---|---|---|
| `__double_underscore` | Internal/private helper | `__test_port`, `__get_host_metrics`, `__strip_ansi` |
| `kebab-case` | User-facing command | `oc-health`, `get-ip`, `oc-backup` |
| Lowercase abbreviation | Tactical shortcut | `so`, `xo`, `cl`, `m`, `h` |

Never use PascalCase or camelCase for function names.

### Version System

`TACTICAL_PROFILE_VERSION` is auto-computed: `_TAC_LOADER_VERSION . sum(all module versions)`. Each module has a `# Module Version: N` comment that is incremented on any change. The loader is currently v5.

### Telemetry Caching

All telemetry functions follow the same pattern to avoid blocking the UI:

```bash
function __get_METRIC() {
    local cache="$TAC_CACHE_DIR/tac_METRIC"
    __cache_fresh "$cache" TTL && { cat "$cache"; return; }
    # Launch background refresh (atomic write: .tmp → mv)
    ( compute_value > "${cache}.tmp" && mv "${cache}.tmp" "$cache" ) &>/dev/null &
    # Return stale data immediately
    [[ -f "$cache" ]] && cat "$cache" || echo "Querying..."
}
```

| Metric | TTL | Notes |
|---|---|---|
| Host metrics (CPU + iGPU + CUDA) | 10s | `typeperf.exe` (iGPU) + `nvidia-smi` (CUDA) |
| NVIDIA GPU detail | 10s | `nvidia-smi` takes ~1.2s cold |
| Battery | 120s | Changes slowly |
| Context used | 30s | Scans `agents/*/sessions/sessions.json` via `jq` |
| OC sessions | 60s | `openclaw sessions --all-agents --json` |
| OC version | 86400s | CLI version rarely changes |
| LLM slots | 5s | Async query to llama.cpp `/slots` |

### Security Measures

1. **LLM loopback binding** — `llama-server` binds to `127.0.0.1` only
2. **API key cache** — `chmod 600`, tmpfs (`/dev/shm`), never written to disk
3. **Commit guard** — `commit_auto` blocks non-localhost LLM URLs; verifies `llama-server` PID before sending diffs
4. **`oc-llm-sync.sh` integrity** — SHA256 verified before sourcing; run `oc-trust-sync` to record new hash
5. **ERR trap** — All failed commands (exit ≥ 2) logged with timestamps to `bash-errors.log`
6. **Bridge timeout** — `pwsh.exe` calls wrapped in `timeout 5`
7. **Variable name validation** — Bridge skips vars with non-`[A-Z0-9_]` characters

### Non-Interactive Access

`env.sh` sources modules `01-15` (skipping `13-init.sh` and utility scripts 16-20). It is idempotent (`__TAC_ENV_LOADED` guard) and sets `TAC_LIBRARY_MODE=1`.

`bin/tac-exec` sources `env.sh` then runs `"$@"`, symlinked to `~/.local/bin/tac-exec`.

---

## Repository Layout

```
~/ubuntu-console/
├── tactical-console.bashrc            # Thin loader + module sourcing loop
├── env.sh                             # Non-interactive library loader
├── install.sh                         # Idempotent installer
├── quant-guide.conf                   # Quantization priority ratings (editable)
├── bin/
│   ├── tac-exec                       # Bootstrap: source env.sh + exec "$@"
│   ├── tac_hostmetrics.sh             # Host CPU + iGPU (typeperf) + CUDA (nvidia-smi)
│   ├── llama-watchdog.sh              # Watchdog: auto-restart with -ngl 999, --prio 2
│   ├── oc-gpu-status                  # Thin wrapper → tac-exec gpu-status
│   ├── oc-model-status                # Thin wrapper → tac-exec ocms
│   ├── oc-model-switch                # Thin wrapper → tac-exec serve
│   ├── oc-quick-diag                  # Thin wrapper → tac-exec oc diag
│   └── oc-wake                        # Thin wrapper → tac-exec wake
├── scripts/                           # Profile modules (01-15, 09b) + utility scripts (16-20)
│   ├── 01-constants.sh                #   All paths, ports, env vars
│   ├── 02-error-handling.sh           #   ERR trap
│   ├── 03-design-tokens.sh            #   ANSI colour constants
│   ├── 04-aliases.sh                  #   Short commands, VS Code wrappers
│   ├── 05-ui-engine.sh                #   Box-drawing primitives
│   ├── 06-hooks.sh                    #   cd override, prompt, port test
│   ├── 07-telemetry.sh                #   CPU, GPU, battery, git, disk, tokens
│   ├── 08-maintenance.sh              #   up (13 steps), cl, get-ip, sysinfo
│   ├── 09-openclaw.sh                 #   Gateway, backup, kgraph, wacli
│   ├── 09b-gog.sh                     #   Google CLI (gog) detection and helpers
│   ├── 10-deployment.sh               #   mkproj, git commit+push, deploy
│   ├── 11-llm-manager.sh              #   Model mgmt, chat, burn, bench
│   ├── 12-dashboard-help.sh           #   Dashboard ('m') and Help ('h')
│   ├── 13-init.sh                     #   mkdir, completions, WSL loopback, exit trap
│   ├── 14-wsl-extras.sh               #   WSL/X11 helpers, completions, vault env
│   ├── 15-model-recommender.sh        #   AI model recommendations by use case
│   ├── 16-check-oc-agent-use.sh       #   Agent usage regression checker
│   ├── 17-import-windows-user-env.sh  #   Import Windows user environment variables
│   ├── 18-lint.sh                     #   bash -n + shellcheck + Unicode safety
│   ├── 19-mirror-gigabrain-vault-to-windows.sh  # Sync Obsidian vault to Windows
│   ├── 20-run-tests.sh                #   BATS test runner
│   └── kgraph/                        #   Knowledge graph Python package
├── docs/                              # Reference documentation
│   ├── architecture.md                #   Developer guide, module details, ADR rationale
│   ├── adr/                           #   Architecture decision records
│   └── HAL-COMMAND-CATALOG.md         #   AI agent command reference
├── frontend-g6/                       # React + AntV G6 knowledge graph frontend
│   └── src/                           #   App.jsx, G6App.jsx, CytoscapeApp.jsx
├── tests/
│   ├── tactical-console.bats          # 473 BATS unit tests
│   ├── tactical-console-fast.bats     # Fast subset (41 tests, ~20s)
│   └── test_kgraph.py                 # Python tests for kgraph
└── systemd/
    ├── llama-watchdog.service
    └── llama-watchdog.timer
```

### Symlink Map

| System Path | Source |
|---|---|
| `~/.bashrc` | Thin loader (not in repo — sources `tactical-console.bashrc`) |
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

---

## Dependencies

### System Requirements

| Component | Requirement |
|---|---|
| OS | Windows 11 Pro with WSL2 |
| WSL Distribution | Ubuntu 24.04 |
| Shell | Bash 5.2+ |
| GPU | NVIDIA RTX 3050 Ti or any CUDA-capable GPU |
| PowerShell | 7.4+ (`pwsh.exe` in WSL interop PATH) |

### Required Packages

| Package | Used By |
|---|---|
| `jq` | All LLM/SSE functions, token scanning |
| `curl` | LLM API calls, health checks, WAN IP |
| `ss` (iproute2) | `__test_port` port checking |
| `typeperf.exe` | Host CPU + iGPU telemetry (Windows built-in, via WSL interop) |
| `nvidia-smi` | CUDA GPU telemetry (WSL NVIDIA driver) |
| `git` | Deployment, commit, sec status |
| `rsync` | Deploy sync |
| `zip` / `unzip` | `oc-backup` / `oc-restore` |

### Optional Packages

| Package | Used By |
|---|---|
| `huggingface-cli` | `model download` |
| `cargo` + `install-update` | `up` step 3 |
| `npm` | `up` step 3 |
| `openclaw` CLI | All `oc-*` commands |

**Not required:** Python (all LLM streaming is pure bash + curl + jq), Ruby, Docker.

---

## AI Agent Access (tac-exec)

All shell functions are accessible to AI agents and automation without an interactive shell:

```bash
# Any tac function via tac-exec
tac-exec model status
tac-exec model status --json
tac-exec so
tac-exec oc health
tac-exec gpu-status

# Or source directly
source ~/ubuntu-console/env.sh && oc backup
```

### JSON Output

```bash
tac-exec model status --json
# {"online":true,"port":8081,"active_num":"1",...}

tac-exec model list --json | jq '.models[] | select(.active==true) | .name'
```

### File Reading Mode

Commands that open VS Code for humans output content instead when `TAC_READ_MODE=1` or `--read` is used:

```bash
tac-exec --read llmconf    # Read models.conf
tac-exec --read mlogs      # Read last 100 lines of LLM log
tac-exec --read occonf     # Read openclaw.json
```

### Setup for AI Agents

```bash
# Ensure tac-exec is in the exec allowlist
echo '{"tac-exec": true}' >> ~/.openclaw/exec-approvals.json

# Optional: install the tactical-console OpenClaw skill
cp -r ~/ubuntu-console/skills/tactical-console ~/.openclaw/skills/
openclaw skills enable tactical-console
```

Full AI agent command catalog: [docs/HAL-COMMAND-CATALOG.md](docs/HAL-COMMAND-CATALOG.md)

---

## Troubleshooting

**Dashboard shows stale or missing data**
Run `oc-cache-clear` to wipe all `/dev/shm/tac_*` caches, then `m` again.

**CONTEXT USED shows "No data"**
No agent sessions with non-zero `totalTokens` exist yet. The row scans `agents/*/sessions/sessions.json` for the newest entry. Create an agent session to populate it.

**`so` shows "CRASHED - CHECK LOGS"**
Run `le` for gateway errors. Most common cause: missing API keys — run `oc-refresh-keys` then `so` again.

**`ockeys` shows WSL ✗ for keys**
Run `oc-refresh-keys`. If still failing, verify `pwsh.exe` is accessible: `command -v pwsh.exe`.

**LLM shows OFFLINE**
Check `model status`. Start one with `model use 1`. If it fails to boot, check `cat /dev/shm/llama-server.log`. Run `wake` first to prevent GPU WDDM sleep.

**Dashboard takes > 1 second to render**
All telemetry refreshes run as `( ... ) &>/dev/null &`. If blocking, check that every background subshell includes `&>/dev/null` before `&`. The `typeperf.exe` call takes ~4s cold — it must use this pattern.

**`commit_auto` fails with "LLM URL is not localhost"**
`commit_auto` blocks non-local LLM endpoints as a security measure. Ensure `LOCAL_LLM_URL` is `http://127.0.0.1:8081/v1/chat/completions`.

**`oc-llm-sync.sh hash mismatch — skipped`**
File has been modified. Run `oc-trust-sync` to record the new hash as trusted.

**`up` shows everything as CACHED**
Delete `~/.openclaw/maintenance_cooldowns.txt` to force all steps to re-run.

**Shell starts slowly**
The only slow startup operation is `__bridge_windows_api_keys` (5s timeout, runs once per hour). If `pwsh.exe` is unreachable, the timeout prevents a hang.

---

## CI Status

[![CI](.github/workflows/ci.yml)](.github/workflows/ci.yml)

- **Fast tests:** `bats tests/tactical-console-fast.bats` (~20s, 41 tests)
- **Full tests:** `bats tests/tactical-console.bats` (473 BATS unit tests)
- **Lint:** `scripts/18-lint.sh` (bash -n + shellcheck + Unicode safety)

Run locally:

```bash
bats tests/tactical-console-fast.bats   # Quick feedback
bats tests/tactical-console.bats        # Full suite
scripts/18-lint.sh                      # Static analysis
```

# end of file
