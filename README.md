# Tactical Console Profile v2.21 — Comprehensive Reference

> **File:** `~/ubuntu-console/tactical-console.bashrc` (sourced via thin `~/.bashrc` loader)
> **Repo:** [`waynegault/ubuntu-console`](https://github.com/waynegault/ubuntu-console)
> **Environment:** WSL2 Ubuntu 24.04 on Windows 11 Pro
> **Hardware:** Intel i9 / Intel Iris Xe (iGPU) / RTX 3050 Ti 4 GB VRAM (CUDA) / Laptop
> **Author:** Wayne
> **Last Major Audit:** March 2026 (v2.09–v2.12: four audit rounds; v2.17–v2.21: 71-item audit + GPU optimisation + quant enforcement)

---

## Table of Contents

1. [Purpose & Philosophy](#1-purpose--philosophy)
2. [Getting Started — Usage Guide](#2-getting-started--usage-guide)
3. [OpenClaw Integration](#3-openclaw-integration)
4. [Local LLM System](#4-local-llm-system)
5. [Developer Guide — How the File Works](#5-developer-guide--how-the-file-works)
6. [Modularisation Plan](#6-modularisation-plan)
7. [Command Reference](#7-command-reference)
8. [Dependencies & Requirements](#8-dependencies--requirements)
9. [Troubleshooting](#9-troubleshooting)
10. [Repository Layout](#10-repository-layout)

---

## 1. Purpose & Philosophy

The **Tactical Console Profile** is a monolithic Bash environment that turns a
WSL2 Ubuntu shell into a unified command-and-control console. It manages:

- **System telemetry** — CPU, dual GPU (Intel Iris iGPU via `typeperf.exe` +
  NVIDIA RTX CUDA via `nvidia-smi`), memory, disk, battery, all rendered in
  a 78-column box-drawn dashboard.
- **Local LLM inference** — Full lifecycle management of `llama-server`
  (llama.cpp) with model registry, GPU/CPU offloading, and streaming chat.
- **OpenClaw agent framework** — Gateway lifecycle, agent orchestration,
  session management, backup/restore, and API key bridging from Windows.
- **Maintenance** — A 10-step `up` pipeline that updates APT, NPM, Cargo,
  validates Python fleets, audits disk space, and kills orphaned processes.
- **Deployment** — Git commit/push with optional LLM-generated commit
  messages, plus rsync to an OpenClaw production workspace.

### Design Principles

| Principle | Implementation |
|---|---|
| **Determinism** | Every maintenance step is idempotent with 7-day cooldowns. The `up` command always converges to the same desired state. |
| **Zero Dependencies Beyond Coreutils** | All LLM streaming is pure `bash + curl + jq`. No Python, Ruby, or Node is used in the shell layer itself. |
| **Instant UI** | Telemetry uses `/dev/shm` caching with background subshell refresh. The dashboard renders stale-but-instant data while new data fetches asynchronously. |
| **Security First** | LLM binds to `127.0.0.1` only. API key cache is `chmod 600` on `tmpfs`. Git diff is blocked from cloud LLM endpoints. ERR trap logs all failures for post-mortem. |
| **Hardware Awareness** | `-ngl 999` auto-offloads maximum GPU layers at runtime, CPU threads scale dynamically via `nproc`, and `--flash-attn` + `--prio 2` are tuned for the RTX 3050 Ti 4 GB VRAM ceiling. |

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
╔══════════════════════════════════════════════════════════════════════════════╗
║                              TACTICAL DASHBOARD                  (ver.: 2.12)║
╠══════════════════════════════════════════════════════════════════════════════╣
║  SYSTEM TIME  :: Saturday 03:04 07/03/2026                                   ║
║  UPTIME       :: 0d 0h 24m                                                   ║
║  BATTERY      :: A/C POWERED                                                 ║
║  CPU / GPU    :: CPU 3% | iGPU 2% | CUDA 0%                                 ║
║  MEMORY       :: 2.77 / 47.04 Gb                                             ║
║  STORAGE      :: C: 995 Gb free | WSL: 877 Gb free                           ║
╠══════════════════════════════════════════════════════════════════════════════╣
║  GPU          :: RTX 3050 Ti | 0% Load | 62°C | 3897 / 4096 Mb               ║
║  LOCAL LLM    :: ACTIVE Phi-4-mini-Q6_K | 14.2 t/s                           ║
║  WSL          :: ACTIVE  Ubuntu-24.04  (6.6.87.2-microsoft-standard-WSL2)    ║
╠══════════════════════════════════════════════════════════════════════════════╣
║  OPENCLAW     :: [ONLINE]  v2026.3.2                                         ║
║  SESSIONS     :: 8 Active                                                    ║
║  CONTEXT USED :: 14% (18k of 128k)                                           ║
╠══════════════════════════════════════════════════════════════════════════════╣
║  TARGET REPO  :: main                                                        ║
║  SEC STATUS   :: SECURE                                                      ║
╠══════════════════════════════════════════════════════════════════════════════╣
║            up | xo | serve | halt | chatl | commitd | status | h            ║
╚══════════════════════════════════════════════════════════════════════════════╝
```

The dashboard colour-codes values at industry-standard thresholds:
- **Green:** < 75% utilisation
- **Yellow:** 75–90%
- **Red:** > 90%

### Help (`h`)

Type `h` to render the full command reference inside a box-drawn panel. Every
command documented here is also listed in the help index.

### System Maintenance (`up`)

Run `up` to execute the 10-step maintenance pipeline:

| Step | What It Does |
|---|---|
| 1. Internet Connectivity | Pings `github.com` |
| 2. APT Packages | Split cooldown: `apt-get update` (24h) + `upgrade --no-install-recommends` (7d) |
| 3. NPM & Cargo | `npm update -g` and `cargo install-update -a` |
| 4. OpenClaw Framework | Runs `openclaw doctor` |
| 5. Python Venv Cloaking | Reports active virtual environment |
| 6. Python Fleet | Scans `/usr/bin/python3.*` for installed versions |
| 7. GPU Status | Queries `nvidia-smi` readiness |
| 8. Sanitation | Cleans temp files from `/tmp/openclaw` |
| 9. Disk Space Audit | Warns if any mount exceeds 90% |
| 10. Stale Processes | Kills orphaned `llama-server` instances |

Each step that involves network or package operations has a **cooldown**
stored in `~/.openclaw/maintenance_cooldowns.txt`. APT index refresh uses a
24-hour cooldown; APT upgrade and all other network steps use a 7-day
cooldown. The cooldown uses Unix timestamps and shows remaining time
(e.g., `[CACHED - 4d 12h LEFT]`).

### Navigation & Convenience

| Command | What It Does |
|---|---|
| `cls` | Clear screen and redraw the startup banner |
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
**systemd user service** on port 18789. It provides multi-agent orchestration,
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
│  │  │  │  __bridge_windows_api_keys()        │  │  │  │
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

### API Key Bridge

The profile bridges API keys from the Windows User environment into WSL. This
is necessary because WSL2 does not inherit Windows environment variables by
default, but cloud LLM providers (used as fallback) need API keys.

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
| `so` | Start the OpenClaw gateway. Injects API keys into systemd, runs `openclaw gateway start`, waits 3s, checks port 18789. |
| `xo` | Stop the gateway. Runs `openclaw gateway stop`, then `systemctl --user stop openclaw-gateway.service`, removes supervisor lock. |
| `oc-restart` | Stop then start (`xo` + `so`). |
| `oc-health` | Deep probe: checks port 18789, then calls `openclaw health --json` and parses the status field. |
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
| `ocstat` | Full status: `openclaw status --all` |
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
| `oc-sec` | Deep security audit: `openclaw security audit --deep` |
| `oc-docs` | Search OpenClaw docs from the terminal |
| `ocdoc-fix` | Run `openclaw doctor --fix` with automatic config backup |
| `oc-cache-clear` | Wipe all `/dev/shm/tac_*` telemetry caches |

### Backup & Restore

| Command | What It Does |
|---|---|
| `oc-backup` | ZIP snapshot of OpenClaw config (`openclaw.json`, `auth.json`), `workspace/`, `agents/`, `models.conf`, `~/.bashrc` loader, `tactical-console.bashrc`, standalone scripts (`~/.local/bin/oc-*`, `llama-watchdog.sh`, `tac_hostmetrics.sh`), and systemd units. Saved to `~/.openclaw/backups/snapshot_YYYYMMDD_HHMMSS.zip`. |
| `oc-restore` | Restore from the most recent snapshot (destructive — prompts for confirmation). Validates ZIP contents and accepts config-only backups. |

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
| `oc-failover` | Cloud fallback: `oc-failover on`, `off`, `status` |
| `oc-local-llm` | Bind OpenClaw's model provider to local llama.cpp |
| `oc-sync-models` | Sync model registry with OpenClaw scan |
| `oc-trust-sync` | Record current `oc-llm-sync.sh` SHA256 hash as trusted |

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
| `~/.config/systemd/user/openclaw-gateway.service` | systemd unit file |
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
| Health poll | 30 × 1s | Waits up to 30 seconds for model boot. |

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
| `model use N` | Start model #N with `-ngl 999`, dynamic threads, `--flash-attn on`, `--prio 2`, `--mlock`, `--jinja`. Batch sizes: 4096/1024 for GPU, 512/512 for CPU-only. Reports actual GPU offload count after boot. Polls `/health` for up to 30s. |
| `model stop` | `pkill` the llama-server process, remove state file |
| `model status` | Show currently running model details |
| `model info N` | Display full details for model #N including on-disk status |
| `model bench` | Benchmark all on-disk models: starts each, runs burn-in, records TPS. Results persist to `/mnt/m/.llm/bench_*.tsv`. |
| `model delete N` | Permanently delete model #N from disk and deregister |
| `model archive N` | Move model #N to `/mnt/m/archive/` and deregister |
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

## 5. Developer Guide — How the File Works

### Section Architecture

The file is divided into 14 numbered sections (§0–§13). Each section has a
metadata block documenting its dependencies and exports:

```bash
# @modular-section: <name>
# @depends: <comma-separated section names>
# @exports: <public functions/variables>
```

| Section | Name | Lines | Purpose |
|---|---|---|---|
| §0 | `ai-instructions` | ~L19 | Version, changelog, AI editor rules, formatting mandates, architecture map |
| §1 | `constants` | ~L150 | All paths, ports, env vars. Single source of truth. |
| §2 | `error-handling` | ~L259 | ERR trap → `bash-errors.log` (exit codes ≥ 2 only) |
| §3 | `aliases` | ~L272 | Short commands, VS Code wrappers, tactical shortcuts |
| §4 | `design-tokens` | ~L325 | ANSI colour constants (`readonly`, re-source safe) |
| §5 | `ui-engine` | ~L350 | Box-drawing primitives: `__tac_header`, `__fRow`, `__hRow`, etc. |
| §6 | `hooks` | ~L560 | `cd` override, prompt (`PS1`), `__test_port` |
| §7 | `telemetry` | ~L632 | Host metrics (CPU + dual GPU via typeperf), NVIDIA detail, battery, git, disk, tokens, OC version, LLM slots — all background-cached via `__cache_fresh` |
| §8 | `maintenance` | ~L843 | `up`, `cl`, `get-ip`, `sysinfo`, `logtrim`, cooldown system (split APT) |
| §9 | `openclaw` | ~L1186 | Full OpenClaw wrapper suite (gateway, backup, bridge, `oc-trust-sync`, `oc-failover`, etc.) |
| §10 | `deployment` | ~L1932 | `mkproj`, `deploy_sync`, `commit_deploy`, `commit_auto` (PID-verified) |
| §11 | `llm-manager` | ~L2210 | `__require_llm`, model management, streaming chat, burn, bench, explain |
| §12 | `dashboard-help` | ~L2891 | `tactical_dashboard` and `tactical_help` renderers |
| §13 | `init` | ~L3175 | `mkdir -p`, completions, loopback fix, bridge call, exit trap (chained) |

### Dependency Graph

```
§0 AI Instructions
§1 Constants ──────────────────────────────────────────────┐
§2 Error Handling ← §1                                     │
§3 Aliases ← §1                                            │
§4 Design Tokens (standalone)                               │
§5 UI Engine ← §1, §4                                      │
§6 Hooks ← §1, §4                                          │
§7 Telemetry ← §1, §4, §5                                  │
§8 Maintenance ← §1, §4, §5, §7                            │
§9 OpenClaw ← §1, §4, §5, §6                               │
§10 Deployment ← §1, §4, §5, §6                            │
§11 LLM Manager ← §1, §4, §5, §6                          │
§12 Dashboard & Help ← §1, §4, §5, §7, §6, §9, §11        │
§13 Init ← all above ─────────────────────────────────────┘
```

### Naming Conventions

| Pattern | Meaning | Examples |
|---|---|---|
| `__double_underscore` | Internal/private helper | `__test_port`, `__get_host_metrics`, `__strip_ansi` |
| `kebab-case` | User-facing command | `oc-health`, `get-ip`, `oc-backup` |
| Lowercase abbreviation | Tactical shortcut | `so`, `xo`, `cl`, `m`, `h` |

**Never** use PascalCase or camelCase for function names.

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
| OC Sessions | 60s | Uses `openclaw sessions --all-agents --json` |
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

## 6. Modularisation Plan

### Current State

The file is ~4,150 lines in `~/ubuntu-console/tactical-console.bashrc`
(sourced by a thin `~/.bashrc` loader). While it works correctly,
this monolithic structure has clear drawbacks:

- **Cognitive load** — Difficult to find specific functions without the
  architecture map or `grep`.
- **Merge conflicts** — Any edit risks colliding with unrelated sections.
- **Testing** — Cannot source individual sections in isolation.
- **Selective loading** — All 128 functions load on every shell start, even
  if only basic commands are needed.

### Target Structure

Split into `~/.bashrc.d/` with one file per section, loaded by the thin
`~/.bashrc` orchestrator (which currently just sources the monolith):

```
~/.bashrc                          # Thin loader (< 20 lines)
~/.bashrc.d/
├── 00-constants.sh                # §1 Global constants
├── 01-error-handling.sh           # §2 ERR trap
├── 02-aliases.sh                  # §3 Short commands
├── 03-design-tokens.sh            # §4 ANSI colours
├── 04-ui-engine.sh                # §5 Box-drawing primitives
├── 05-hooks.sh                    # §6 cd override, prompt, port test
├── 06-telemetry.sh                # §7 CPU, GPU, battery, etc.
├── 07-maintenance.sh              # §8 up, cl, sysinfo, logtrim
├── 08-openclaw.sh                 # §9 Full OpenClaw wrapper suite
├── 09-deployment.sh               # §10 mkproj, deploy, commit
├── 10-llm-manager.sh              # §11 Model mgmt, chat, burn
├── 11-dashboard-help.sh           # §12 Dashboard and help renderers
└── 12-init.sh                     # §13 Startup side-effects
```

### The Loader

```bash
# ~/.bashrc — Tactical Console Profile Loader
case $- in *i*) ;; *) return ;; esac

TAC_DIR="$HOME/ubuntu-console"
for _tac_module in "$TAC_DIR"/.bashrc.d/[0-9][0-9]-*.sh; do
    [[ -f "$_tac_module" ]] && source "$_tac_module"
done
unset _tac_module
```

### How to Execute the Split

1. **Create the directory:** `mkdir -p ~/.bashrc.d`
2. **Extract sections** — The `@modular-section` annotations already mark
   exact boundaries. Use `sed` or a script to split on the `# ====` section
   dividers.
3. **Add guards to design-tokens** — Wrap `readonly` declarations with
   `[[ -z "${C_Reset:-}" ]]` (already done in the current file).
4. **Resolve cross-cutting state** — All cross-module communication already
   goes through `/dev/shm` files or exported variables (documented in
   §5 above). No code changes needed — just ensure `00-constants.sh` is
   sourced first.
5. **Test incrementally** — After extracting each module, run `bash -n` on
   both the module and the loader. Verify `m`, `h`, `so`, `serve`, and `up`
   still work.
6. **Update the loader** — Change `~/.bashrc` to source the `.bashrc.d/`
   modules instead of the monolith.

### Ordering Rules

Files are numbered `00–12` to enforce source order. The dependency graph
(§5 above) dictates that:

- `00-constants.sh` must be first (everything depends on it).
- `03-design-tokens.sh` must precede `04-ui-engine.sh`.
- `12-init.sh` must be last (runs startup side-effects).
- All other modules can be reordered as long as their `@depends` are
  satisfied.

### Benefits

| Benefit | Detail |
|---|---|
| **Faster iteration** | Edit `10-llm-manager.sh` without scrolling past 1900 lines of unrelated code. |
| **Targeted testing** | `bash -n ~/.bashrc.d/08-openclaw.sh` checks only OpenClaw functions. |
| **Selective loading** | On a server with no GPU, skip `10-llm-manager.sh`. On a headless box, skip `11-dashboard-help.sh`. |
| **Reduced merge conflicts** | Two developers editing OpenClaw and LLM code never touch the same file. |
| **Git blame clarity** | `git log 08-openclaw.sh` shows only OpenClaw changes, not unrelated telemetry fixes. |
| **Easier onboarding** | A new developer reads one 200-line module instead of a 4,150-line monolith. |

### Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Source order bugs | Numeric prefixes enforce deterministic ordering. Test with `bash -n` after every change. |
| `readonly` collisions on re-source | Already guarded with `[[ -z "${C_Reset:-}" ]]`. |
| Missing module breaks shell | The loader's `[[ -f ]]` guard skips missing files gracefully. Add an `echo` warning for missing expected modules. |
| Performance regression (many `source` calls) | 13 `source` calls add < 5ms total. Measured on this hardware. |

---

## 7. Command Reference

### Quick Reference Card

| Command | Category | Description |
|---|---|---|
| `m` | Dashboard | Render full tactical dashboard |
| `h` | Help | Show command help index |
| `up` | Maintenance | 10-step system maintenance |
| `cls` | Shell | Clear screen + banner |
| `reload` | Shell | Full profile reload (`exec bash`) |
| `sysinfo` | System | One-line hardware summary |
| `get-ip` | Network | WSL + WAN IP addresses |
| `cpwd` | Utility | Copy path to clipboard |
| `cl` | Utility | Quick temp cleanup |
| `logtrim` | Utility | Trim logs > 1 MB |
| `oedit` | Editor | Open `tactical-console.bashrc` in VS Code |
| `code` | Editor | Open anything in VS Code |
| `so` | OpenClaw | Start gateway (warns if local LLM provider offline) |
| `xo` | OpenClaw | Stop gateway |
| `oc-restart` | OpenClaw | Restart gateway |
| `oc-health` | OpenClaw | Deep health probe |
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
| `oc-restore` | OpenClaw | Restore from ZIP (validates contents) |
| `oc-diag` | OpenClaw | 5-point diagnostic |
| `oc-env` | OpenClaw | Dump env vars |
| `oc-config` | OpenClaw | Get/set config |
| `oc-failover` | OpenClaw | Cloud fallback toggle (on/off/status) |
| `oc-local-llm` | OpenClaw | Link to local LLM |
| `oc-sync-models` | OpenClaw | Sync model registry |
| `oc-trust-sync` | OpenClaw | Save current oc-llm-sync.sh SHA256 as trusted |
| `le` / `lo` / `lc` | Logs | View stderr / stdout / clear |
| `model list` | LLM | Show numbered model registry (▶ = active) |
| `model use N` | LLM | Start model #N with optimal GPU/ctx/thread settings |
| `model stop` | LLM | Stop inference server |
| `model status` | LLM | Show running model details |
| `model info N` | LLM | Full details for model #N |
| `model scan` | LLM | Scan GGUF files, read metadata, rebuild registry |
| `model download` | LLM | Fetch from HuggingFace |
| `model delete N` | LLM | Delete model #N from disk and registry |
| `model archive N` | LLM | Move model #N to archive and deregister |
| `model bench` | LLM | Benchmark all on-disk models, persist TSV |
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
The canonical profile lives in the repo; `~/.bashrc` is a thin loader
that sources it.

### Directory Structure

```
~/ubuntu-console/
├── tactical-console.bashrc    # Main profile (sourced by ~/.bashrc thin loader)
├── quant-guide.conf           # Quantization priority ratings (editable)
├── README.md                  # This file
├── inspection.md              # Audit checklist
├── .gitignore
├── install.sh                 # Installer for new machines
├── bin/
│   ├── llama-watchdog.sh      # Watchdog: auto-restart with -ngl 999, --prio 2
│   └── tac_hostmetrics.sh     # Host CPU + iGPU (typeperf) + CUDA (nvidia-smi)
├── scripts/
│   └── lint.sh                # ShellCheck + bash -n linter for all scripts
└── systemd/
    ├── llama-watchdog.service # systemd unit for watchdog
    └── llama-watchdog.timer   # systemd timer (runs every 60s)
```

### Symlink Map

| System Path | Repo Path |
|---|---|
| `~/.bashrc` | thin loader (not in repo — sources `tactical-console.bashrc`) |
| `/mnt/m/.llm/models.conf` | `llm/models.conf` (not currently in repo) |
| `~/.local/bin/llama-watchdog.sh` | `bin/llama-watchdog.sh` |
| `~/.local/bin/tac_hostmetrics.sh` | `bin/tac_hostmetrics.sh` |
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
`reload` to apply. All edits go in `~/ubuntu-console/tactical-console.bashrc`
(or associated repo files) — never edit `~/.bashrc` directly.

Commit and push:

```bash
cd ~/ubuntu-console
git add -A && git commit -m "description" && git push
```

---

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

**Tactical Console Profile v2.21 :: WSL2 Ubuntu 24.04 :: Designed for Determinism**
