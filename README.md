# Tactical Console Profile

> **Repo:** [`waynegault/ubuntu-console`](https://github.com/waynegault/ubuntu-console)
> **Environment:** WSL2 Ubuntu 24.04 on Windows 11 Pro
> **Hardware:** Intel i9 / Intel Iris Xe (iGPU) / RTX 3050 Ti 4 GB VRAM (CUDA)
> **Shell:** Bash 5.2+

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/waynegault/ubuntu-console)

The **Tactical Console Profile** is a modular Bash environment that turns a
WSL2 Ubuntu shell into a unified command-and-control console. A thin loader
(`tactical-console.bashrc`) sources its 16 profile modules from `scripts/` in
dependency order, driven by the shared list in `scripts/_module-list.sh`.

**Non-interactive access:** `env.sh` is a library loader that sources all
modules except `13-init.sh`, making ~100+ shell functions available to MCP
tools, AI agents, cron jobs, and automation scripts via `tac-exec`.

---

## Contents

- [Features](#features)
- [PowerShell Translation Prep](#powershell-translation-prep)
- [Design Principles](#design-principles)
- [Installation](#installation)
- [Command Reference](#command-reference)
- [Dashboard & Shell Interface](#dashboard--shell-interface)
- [Local LLM System](#local-llm-system)
- [OpenClaw Integration](#openclaw-integration)
- [Maintenance Pipeline](#maintenance-pipeline)
- [Testing](#testing)
- [Architecture & Developer Guide](#architecture--developer-guide)
- [Repository Layout](#repository-layout)
- [Dependencies](#dependencies)
- [AI Agent Access (tac-exec)](#ai-agent-access-tac-exec)
- [Troubleshooting](#troubleshooting)
- [CI Status](#ci-status)

---

## Features

- **System telemetry** — CPU, dual GPU (iGPU + CUDA), memory, disk, battery in a 78-column dashboard
- **Local LLM inference** — Full lifecycle management of `llama-cpp-python==0.3.23` server with OpenAI-compatible API
- **OpenClaw agent framework** — Gateway lifecycle, agent orchestration, backup/restore, knowledge graph
- **Maintenance** — 20-step `up` pipeline with per-step cooldowns and race condition protection
- **Deployment** — Git commit/push with optional LLM-generated commit messages (PID-verified, secret detection)
- **Knowledge graph** — Interactive Cytoscape.js visualisation via `oc g`
- **Virtual environment auto-activation** — `cd` override activates/deactivates `.venv` automatically

## PowerShell Translation Prep

This repository now includes non-invasive prep artifacts to make AI-assisted
translation to PowerShell deterministic and easier to validate:

- `.agents/pwsh-build-prompt.md` — Translation strategy, workflow, and AI build prompt
- `docs/contracts/command-contracts.yaml` — Starter command behavior contract
- `docs/contracts/state-contracts.yaml` — Cross-module state contracts
- `tools/capture-golden-fixtures.sh` — Snapshot selected command outputs for parity checks
- `tests/fixtures/golden/README.md` — Fixture format and extension guidance

Use these to drive a behavior-first port (PowerShell should match contracts and
fixtures, not Bash implementation details).

## Design Principles

| Principle | Implementation |
|---|---|
| **Determinism** | Every maintenance step is idempotent with 24h cooldowns using `flock` |
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
up             # Run 20-step system maintenance
```

---

## Command Reference

> Quick overview of the most common commands. The complete reference is this section — `docs/reference.md` was consolidated into it on 2026-09-15.

| Command | Category | Description |
|---|---|---|
| `m` | Dashboard | Render full tactical dashboard |
| `h` | Help | Show command help index |
| `up` | Maintenance | 20-step system maintenance pipeline |
| `cls` / `c` | Shell | Clear screen + banner |
| `reload` | Shell | Full profile reload (`exec bash`) |
| `sysinfo` | System | One-line hardware summary |
| `get-ip` | Network | WSL + WAN IP addresses |
| `cpwd` | Utility | Copy path to Windows clipboard |
| `cl` | Utility | Quick temp cleanup (`--report` shows a dry run) |
| `logtrim` | Utility | Trim logs > 1 MB to last 1000 lines |
| `oedit` | Editor | Open `tactical-console.bashrc` in VS Code |
| `code` | Editor | Open anything in VS Code |
| `so` | OpenClaw | Start gateway and auto-start Local LLM if needed |
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
| `oc-refresh-keys` | OpenClaw | Re-import Windows API keys; sync OC SecretRefs |
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
| `model bench [MODEL...]` | LLM | Benchmark all or selected on-disk models (auto-runs autotune first when profile is missing), persist TSV |
| `model autotune N` | LLM | Optimize for no OOM, max context, max TPS; save per-model profile |
| `model bench-diff` | LLM | Compare two benchmark TSV runs |
| `model bench-history` | LLM | Summarise recent benchmark runs |
| `serve N` / `halt` | LLM | Aliases for `model use N` / `model stop` |
| `wake` | GPU | Lock GPU persistence mode |
| `burn` | LLM | Stress test + TPS benchmark |
| `chat:` | LLM | Multi-turn chat REPL |
| `chat-context` | LLM | File context → LLM |
| `chat-pipe` | LLM | Stdin context → LLM |
| `explain` | LLM | Explain last command |
| `wtf` | LLM | Topic explanation REPL |
| `mkproj` | Dev | Scaffold Python project |
| `commit:` | Git | Commit with message and push |
| `commit_deploy` | Git | Function behind `commit:` alias |
| `commit_auto` | Git | LLM-generated commit message (PID-verified) + push |

---


| `cls` | Shell | Clear screen + banner |
| `docs-sync` | Utility | Check the docs for drift against current repo facts |
| `oc-env` | OpenClaw | Dump env vars |
| `oc-config` | OpenClaw | Get/set config |
| `model bench` | LLM | Benchmark all on-disk models, persist TSV; auto-runs autotune when missing and skips discouraged quant auto-autotune unless `LLM_ALLOW_AUTOTUNE_DISCOURAGED=1` |
| `model bench-diff` / `model bench-compare` | LLM | Compare two benchmark runs |
| `commit:` / `commit_deploy` | Git | Stage all + commit with YOUR message + push |
| `commit` | Git | Alias for `commit_auto` — LLM-generated message (PID-verified, secret detection) + push |

## Dashboard & Shell Interface

### The Dashboard (`m`)

```
+------------------------------------------------------------------------------+
|                      TACTICAL DASHBOARD                      (ver.: 5.177)  |
|------------------------------------------------------------------------------|
|  SYSTEM TIME  :: Wednesday 09:14 22/04/2026                                 |
|  UPTIME       :: 0d 2h 41m                                                  |
|  BATTERY      :: A/C POWERED                                                |
|  CPU / GPU    :: CPU 3% | iGPU 2% | NVIDIA 0%                               |
|  MEMORY       :: 2.77 / 47.04 Gb                                            |
|  STORAGE      :: C: 995 Gb free | WSL: 877 Gb free                          |
|------------------------------------------------------------------------------|
|  GPU          :: RTX 3050 Ti | 0% Load | 62°C | 3897 / 4096 Mb             |
|  GPU ENGINES  :: 3D 0% | VDec 0%                                           |
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
|        up | xo | serve <n> | halt | chat: | commit | g | h | pwsh          |
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

<!-- merged from docs/reference.md on 2026-09-15 -->

#### The Dashboard (`m`)

Type `m` at any prompt to render the full-screen Tactical Dashboard:

```text
(sample output — values vary with machine state)
|                      TACTICAL DASHBOARD                      (ver.: 2.12) |
|  SYSTEM TIME  :: Saturday 03:04 07/03/2026                                |
|  UPTIME       :: 0d 0h 24m                                                |
|  BATTERY      :: A/C POWERED                                              |
|  CPU / GPU    :: CPU 3% | iGPU 2% | NVIDIA 0%                              |
|  MEMORY       :: 2.77 / 47.04 Gb                                          |
|  STORAGE      :: C: 995 Gb free | WSL: 877 Gb free                        |
|  GPU          :: RTX 3050 Ti | 0% Load | 62°C | 3897 / 4096 Mb            |
|  GPU ENGINES  :: 3D 0% | VDec 0%                                          |
|  LOCAL LLM    :: ACTIVE Llama-3.2-3B-Q4_K_M | 12.6 t/s                    |
|  WSL          :: ACTIVE  Ubuntu-24.04  (6.6.87.2-microsoft-standard-WSL2) |
|  OPENCLAW     :: [ONLINE]  v2026.3.2    (or [NOT INSTALLED] if missing)   |
|  SESSIONS     :: 8 Active (cached 34s ago)  (hidden if not installed)     |
|  ACTIVE AGENT :: 14% (18k of 128k)        (hidden if not installed)       |
|  TARGET REPO  :: main                                                     |
|  SEC STATUS   :: SECURE                                                   |
|            up | xo | serve <n> | halt | chat: | commit | g | h | pwsh      |
```

Colour thresholds: **Green** < 75% · **Yellow** 75–90% · **Red** > 90%.

#### Help (`h`)

Type `h` to render the full command reference inside a box-drawn panel.
**OpenClaw-aware:** when OpenClaw is not installed, all OpenClaw-related
sections are hidden to reduce clutter.

#### Navigation & Convenience

|---|---|
| `c` or `cls` | Clear screen and redraw the startup banner |
| `cl` | Quick cleanup of `python-*.exe` and `.pytest_cache` in `$PWD` |
| `sysinfo` | One-line: `CPU: 12% RAM: 5.2/15.4 Gb Disk: 142 Gb iGPU: 3%/47°C CUDA: 12%` |
| `get-ip` | Show WSL IP and external WAN IP |
| `code <path>` | Open anything in VS Code (lazy-resolved path) |


The `cd` command is overridden. When you enter a directory containing
`.venv/bin/activate`, it is automatically sourced; when you leave the project
tree, `deactivate` is called automatically. The dashboard shows active venvs
under the "CLOAKING" row.

If venv activation fails, a warning is printed and `VIRTUAL_ENV` is cleared
to prevent confusion.

#### Shell Prompt

```
```

- **▼** — Present if user is in the `sudo` group (admin badge).
- **✓ / ×** — Green checkmark or red cross for last command exit status.
- **(myenv)** — Active Python virtual environment name.
- Empty-enter detection: pressing Enter with no command clears the error badge.

**Inter-prompt spacing:** A single blank line separates consecutive prompts via
PS1's leading `\n`. PS0 is intentionally unset — using both PS0 and PS1
newlines produces a double blank line after silent commands like `cd`.


## Local LLM System

Built on [llama-cpp-python](https://github.com/abetlen/llama-cpp-python) (pinned to `0.3.23`). Models are GGUF files managed via a pipe-delimited registry, served on port 8081 with an OpenAI-compatible API. Runtime defaults are tuned for RTX 3050 Ti 4GB + i9-12900HK (`n_gpu_layers=24`, `n_threads=6`, `n_ctx=4096`, `flash_attn=true`, `offload_kqv=true`, `cache_type_k=q8_0`).

### Model Registry

Located at `~/.llm/models.conf` (`$LLM_REGISTRY`) — 37-column pipe-delimited (schema v6; the first 20 columns are shown below), auto-generated by `model scan`:

```
#|name|file|size_gb|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|fit_target_mb|backend|mmap_mode|flash_attn|tps|autotuned|is_default|in_vram
1|Phi-4-mini|microsoft_Phi-4-mini-instruct-Q6_K.gguf|3.0G|Q6_K/q8_0|phi3|32|8192|8|1024|256|1|256|llama_server|auto|on|58.2|yes|no|no
2|Qwen3-8B|Qwen_Qwen3-8B-Q4_K_M.gguf|4.7G|Q4_K_M/q8_0|qwen2|28|4096|8|1024|256|1|256|llama_server|auto|on|35.1|yes|no|no
```

### Hardware Tuning

| Parameter | Value | Rationale |
|---|---|---|
| `-ngl 999` | max offload | llama.cpp offloads the maximum layers that fit in VRAM at runtime |
| `-t` (threads) | dynamic | CPU-only: 80%, partial offload: 70%, full GPU: 50% of `nproc` |
| `--batch-size` | 4096 (GPU) / 512 (CPU) | Larger batches improve prompt eval speed on GPU |
| `--flash-attn on` | GPU only | Reduces VRAM bandwidth — critical for 4 GB GPUs |
| `--load-mode none` | adaptive (`LLAMA_NO_MMAP_MODE`) | Improves stability under low VRAM / WSL / MoE workloads by reducing mmap paging stalls. `--no-mmap` was **removed** upstream (build 10955 rejects it as a fatal `invalid argument`) — see `docs/llama-cpp-runtime-audit.md` §1 |
| `--jinja` | always | Enables Jinja2 chat templates from GGUF metadata |
| Bind address | `127.0.0.1` | Loopback only — no LAN exposure |

### Quantization Guide

`config/quant-guide.conf` rates quants for the RTX 3050 Ti:

| Rating | Quants |
|---|---|
| **recommended** | Q4_K_M, Q4_K_S |
| **acceptable** | Q3_K_M/L/S, Q5_K_M/S, Q2_K, IQ variants, Q8_0, F16 |
| **discouraged** | Q6_K, F32, BF16 — too large for 4 GB VRAM |

`model scan` auto-archives discouraged quants. `model download` warns (does not block) when downloading a discouraged quant. The rating is matched against the filename, so it is not size-aware: `Q8_0`/`F16` are *acceptable* because they fit small (1–3B) models, even though a 7–8B `Q8_0`/`F16` is CPU-only on this GPU.

### Chat & Inference

| Command | What It Does |
|---|---|
| `chat:` | Multi-turn REPL — full JSON history, SSE streaming, `end-chat` to exit |
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
| `~/.llm/models.conf` | Model registry (`$LLM_REGISTRY`) |
| `/mnt/m/.llm/bench_*.tsv` | Benchmark history |
| `~/ubuntu-console/config/quant-guide.conf` | Quantization ratings (`$QUANT_GUIDE`) |
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
    └── cuda-llama-server (CUDA card, port 18083)
```

### API Key Bridge

On shell start, `__bridge_windows_api_keys()` calls `pwsh.exe` (5s timeout) to read Windows environment variables matching `API[_-]?KEY|TOKEN`. Results are written to `/dev/shm/tac_win_api_keys` (`chmod 600`, tmpfs — never hits disk). Cache TTL: 3600s. Force refresh with `oc-refresh-keys`.

For the OpenClaw gateway (systemd, not a shell child), `so()` reads the cache and injects keys via `systemctl --user set-environment` before starting the service — narrowed (2026-09-13) to only the vars the gateway resolves as SecretRefs (config + agent auth profiles), not the whole bridged set.

### Gateway Lifecycle

| Command | What It Does |
|---|---|
| `so` | Start gateway — injects API keys into systemd, starts service, polls port 18789 |
| `xo` | Stop gateway only (use `oc restart` to restart from an AI agent context) |
| `oc-restart` | Native restart: `openclaw gateway restart` |
| `oc-health` | Deep probe: checks port 18789, calls `openclaw health --json` |
| `oc-refresh-keys` | Re-bridge Windows API keys + sync OC SecretRefs |

### Backup & Restore

`oc-backup` creates a ZIP of: `openclaw.json`, `auth.json`, `workspace/`, `agents/`, `models.conf`, `~/.bashrc` loader, `tactical-console.bashrc`, `~/.local/bin/oc-*`, systemd units. Saved to `~/.openclaw/backups/snapshot_YYYYMMDD_HHMMSS.zip`.

`oc-restore` prompts for confirmation, validates ZIP contents, supports `--dry-run`.

### Knowledge Graph (`oc g` / `kgraph`)

`oc g` launches the interactive graph viewer (Cytoscape.js, persisted to `~/.openclaw/kgraph.sqlite`).
The `kgraph` CLI exposes the full toolchain — install it globally:

```bash
uv tool install ./scripts          # from repo root
uv tool install openclaw-kgraph   # future: from PyPI
```

**CLI commands:** `--ast`, `--update`, `--watch`, `--report`, `--communities`,
`--god-nodes`, `--call-flow`, `--mcp`, `--confidence`, `--query`, `--path`,
`--explain`, `--pr-dashboard`, `--benchmark`, `--audit`, `--install-hook`.
See `docs/openclaw.md` for full reference.

Graph views: `overview` (default), `topics`, `files`, `semantic`, `raw`.
A React + AntV G6 dev frontend lives in `frontend-g6/` (Vite port 5173).

**Architecture:** All graph data flows through Pydantic models (`GraphNode`,
`GraphEdge`, `Graph`, `GraphBuilder`) defined in `scripts/kgraph/models.py`.
Edge endpoints are canonicalised to `source`/`target` (legacy `from`/`to`
auto-mapped). Concept aliases and classification data are externalised to
`config/concept-aliases.json`. The HTML viewer template lives in
`scripts/kgraph/templates/kgraph.html`.

### Key Paths

| Path | Purpose |
|---|---|
| `~/.openclaw/` | OpenClaw root (`$OC_ROOT`) |
| `~/.openclaw/workspace/` | Active workspace |
| `~/.openclaw/agents/` | Agent definitions |
| `~/.openclaw/backups/` | ZIP snapshots |
| `~/.openclaw/openclaw.json` | Global configuration |
| `~/.openclaw/logs/bash-errors.log` | ERR trap log |
| `/dev/shm/tac_win_api_keys` | Bridged API keys cache (chmod 600, tmpfs) |

---

## Maintenance Pipeline

Run `up` for the 20-step pipeline:

| Step | What It Does |
|---|---|
| 1. Internet Connectivity | Pings `github.com` |
| 2. Linux Update | `apt-get update` (24h cooldown), dry-run validation, then upgrade (7d cooldown) |
| 3. NPM Packages | `npm update -g` when global packages exist |
| 4. Cargo Crates | `cargo install-update -a` when `cargo-install-update` is available |
| 5. R Packages | Updates CRAN and Bioconductor packages |
| 6. OpenClaw Framework | Runs `openclaw doctor` (skipped if not installed) |
| 7-10. OpenClaw Plugins | Updates Gigabrain/Lossless-Claw/OpenStinger and runs post-update drift checks |
| 11. Python Venv | Updates outdated packages in the active venv |
| 12. Python Fleet | Scans installed `/usr/bin/python3.*` versions |
| 13. GPU Status | Queries `nvidia-smi` readiness (with cache race guard) |
| 14. Temp File Sanitation | Cleans known temp artifacts under `/tmp/openclaw` |
| 15. Disk Space Audit | Warns if any mount exceeds 90% |
| 16. Systemd Units | Verifies OpenClaw gateway user unit presence |
| 17. Stale Processes | Kills orphaned `llama-server` instances |
| 18. Docs Sync | Checks tracked repo facts for documentation drift (README, pytest.ini) |
| 19. Docker Prune | Runs `docker system prune` when Docker is installed |
| 20. NPM Cache Clean | Verifies/cleans npm cache (24h cooldown) |

### Cooldown System

Each network/package step has a cooldown in `~/.openclaw/maintenance_cooldowns.txt` (Unix timestamps). APT index: 24h; APT upgrade: 7d; most other network steps: 24h. `flock -x` prevents race conditions when `up` runs in parallel.

## Testing

The project uses two test frameworks: **BATS** (bash automated testing) for shell functions, and **pytest** for Python code. A bridge module (`tests/test_bats_bridge.py`) exposes each individual BATS `@test` block as a separate pytest test, giving a **unified test view** in VS Code's Python Test Explorer (1001 total tests: 659 BATS + 342 Python).

### Running Tests

| Command | What it runs | Est. time |
|---------|-------------|-----------|
| `unittest` | All BATS suites + Python tests (via `tools/run-tests.sh`) | 20-40 min |
| `unittest --fast` | Fast static-analysis BATS only (`tactical-console-fast.bats`) | ~2 min |
| `pytest tests/` | Python tests + the BATS bridge (add `--ignore=tests/test_bats_bridge.py` for Python only) | varies |
| `pytest tests/test_bats_bridge.py -k "test_tactical_console_fast"` | Single BATS file via bridge | ~2 min |
| `bats tests/tactical-console-fast.bats --timing` | Single BATS file directly | ~2 min |
| `.venv/bin/python3 -m mypy` | Type checks (mypy; config in `pyproject.toml`) | ~30s |
| `.venv/bin/pyright` | Type checks (pyright; config in `pyproject.toml`) | ~30s |
| VS Code Testing panel (flask icon) | All tests unified in one tree — click ► on any test | Varies |

### Test Bridge (`test_bats_bridge.py`)

Each `.bats` file is parsed at collection time to discover all `@test` blocks. One pytest test function is generated per block with a sanitized name (alphanumeric only). Results are cached per file: the first test from a file triggers the full BATS run; subsequent tests read from cache.

For individual test runs (e.g. VS Code clicking one test), `bats --filter` is used to execute only the requested test — dropping per-test runtime from ~900s to ~18s for the large `tactical-console.bats` suite.

### Key Infrastructure Files

- `tests/conftest.py` — BATS suite serialization lock (prevents parallel runs), VS Code discovery guard (`_is_vscode_discovery()`), stale lock cleanup
- `tests/test_bats_bridge.py` — Dynamic test generation, TAP output parser with diagnostic line capture, marker-based filtering (`-m bats_unit`, `bats_fast`, `bats_full`, `bats_integration`)
- `tests/test_bats_lock_fixture.py` — Tests for the lock fixture itself
- `tools/run-tests.sh` — CLI test runner invoked by `unittest` command

### Test Counts

| Suite | File | Count | Timeout |
|-------|------|-------|---------|
| Full behavioural | `tactical-console.bats` | 386 | 900s |
| Fast static analysis | `tactical-console-fast.bats` | 53 | 180s |
| Function availability | `tactical-console-function-availability.bats` | 2 | 180s |
| Unit (refresh-keys, so-startup, llama-cpp inventory, spec-decode, autotune, agent-use, clean-orphans, module-versions) | `tests/unit/*.bats` | 66 | 120s |
| Integration (maintenance, model-lifecycle, backup, watchdog, refresh-keys, bench) | `tests/integration/*.bats` | 119 | 300s |
| Python (kgraph, kgraph-wiring, models, untested-modules, lock-fixture) | `tests/test_*.py` | 338 | 200s |
| **Total** | | **964** | |

---

## Architecture & Developer Guide

### Module Architecture

The profile is a thin loader that sources 16 profile modules from `scripts/`. The order lives in one shared list (`scripts/_module-list.sh`, via `__tac_module_list`) that **both** `tactical-console.bashrc` and `env.sh` read, so the interactive and library loaders can never drift:

```bash
source "$_tac_module_dir/_module-list.sh"
mapfile -t _tac_expected_modules < <(__tac_module_list)
```

`09-openclaw.sh` and `11-llm-manager.sh` are thin loaders listed in that shared
list: each sources its `09a/c-f` / `11a-f` sub-modules in dependency order and
also carries load-time logic (the OpenClaw availability probe, the
`__LLAMA_DRIVE_MOUNTED` fallback). Listing the thin loaders (rather than their
sub-modules) means nothing is sourced twice. Module counts and line counts are
verified by `tools/docs-sync-check.sh` in CI — this table intentionally omits
line counts because they drift.

| Module | Purpose |
|---|---|
| `01-constants.sh` | All paths, ports, env vars. Single source of truth. `__TAC_OPENCLAW_OK` functional check. |
| `02-error-handling.sh` | ERR trap → `bash-errors.log` (exit codes ≥ 2; exit 1 filtered) |
| `03-design-tokens.sh` | ANSI colour constants (`readonly`, re-source safe) |
| `04-aliases.sh` | Short commands, VS Code wrappers, tactical shortcuts |
| `05-ui-engine.sh` | Box-drawing: `__tac_header`, `__fRow`, `__hRow`, `__strip_ansi`, `__threshold_color` |
| `06-hooks.sh` | `cd` override (venv auto-activate), prompt (PS1), `__test_port`, admin badge |
| `07-telemetry.sh` | CPU + dual GPU, NVIDIA detail, battery, git, disk, tokens, OC version, LLM slots |
| `08-maintenance.sh` | `up` (20 steps), `cl`, `get-ip`, `sysinfo`, `logtrim`, cooldown system with flock |
| `09-openclaw.sh` | Thin loader → sources `09a-f` sub-modules |
| `09a-oc-gateway.sh` | OpenClaw gateway: `so`, `xo`, `oc`, `oc-restart`, `ocstart`, `ocstop`, `oc-purge`, `ockeys`, `oc-refresh-keys` |
| `09b-gog.sh` | Google CLI (gog) detection and helpers |
| `09c-oc-core.sh` | Core `oc` wrappers: backup/restore, `oc-agent-use`, `oc-diag`, `oc-doctor-local`, `oc-failover`, `wacli` |
| `09d-oc-agents.sh` | Agent helpers: `oc-kgraph`, `owk`, `ologs`, `ocroot`, `lc`, `oc-update`, `oc-cron`, `oc-skills` |
| `09e-oc-health.sh` | Health suite: `oc-health`, `oc-plugins`, `oc-plugin-update`, `oc-tail`, `oc-channels`, `oc-sec` |
| `09f-oc-misc.sh` | Misc: `oc-stinger`, `oc-tui`, `oc-config`, `oc-docs`, `oc-usage`, `oc-local-llm`, `oc-sync-models`, `ocms`, `oc-browser`, `oc-nodes`, `oc-sandbox`, `oc-env`, `oc-cache-clear`, `oc-trust-sync`, `mem-index`, `oc-memory-search` |
| `10-deployment.sh` | `mkproj` (disk space check), `commit_deploy`, `commit_auto` |
| `11-llm-manager.sh` | Thin loader → sources `11a-f` sub-modules |
| `11a-llm-registry.sh` | Registry CRUD, sync, renumber |
| `11b-llm-autotune.sh` | Autotune infrastructure for optimal model parameters |
| `11c-llm-server.sh` | LLM server lifecycle, health, Python resolution |
| `11d-llm-gpu.sh` | GPU status, GGUF metadata, calculations |
| `11e-llm-model.sh` | Model management, streaming chat, burn, bench, explain |
| `11f-llm-runtime.sh` | Runtime helpers: `wake`, `model`, `serve`, `halt`, `mlogs`, `local_chat`, `chat-context` |
| `12-dashboard-help.sh` | `tactical_dashboard` (OpenClaw-aware), `tactical_help`, `bashrc_diagnose` |
| `13-init.sh` | `mkdir -p`, completions, WSL loopback fix, bridge call, EXIT trap (chained) |
| `14-wsl-extras.sh` | WSL/X11 startup helpers, OpenClaw completions sourcing (guarded), vault env loading |
| `15-model-recommender.sh` | AI model recommendations by use case (`bc` fallback for integer math) |

**Utility scripts** (in `tools/`, not sourced as profile modules):

| Script | Purpose |
|---|---|
| `tools/capture-golden-fixtures.sh` | Snapshot selected command output for PowerShell parity checks |
| `tools/check-agent-use.sh` | Agent-usage regression check (CI via fixtures; live `/dev/shm` on demand) |
| `tools/check-repo-boundaries.sh` | Repo ownership boundary guard (CI) |
| `tools/clean-orphans.sh` | Kill orphaned bench/llama-server keeper processes (refuses while a bench/autotune is live) |
| `tools/docs-sync-check.sh` | Docs drift guard: module count, loader version, test totals, per-directory breakdowns — in README and `pytest.ini` (CI) |
| `tools/import-windows-env.sh` | Import Windows user environment variables |
| `tools/lint.sh` | Static analysis: `bash -n` + shellcheck + Unicode safety |
| `tools/mirror-vault.sh` | Sync Obsidian vault to Windows |
| `tools/normalize-fixture.sh` | Normalise captured golden fixtures |
| `tools/run-tests.sh` | Pretty-printed BATS test runner |
| `tools/sync-openclaw-completion.sh` | Refresh OpenClaw bash completion word lists |

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
09-openclaw          ← 01, 03, 05, 06   (thin loader → 09a-f)  │
09b-gog              ← 01                                      │
10-deployment        ← 01, 03, 05, 06                          │
11-llm-manager       ← 01, 03, 05, 06   (thin loader → 11a-f)  │
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

`TACTICAL_PROFILE_VERSION` is auto-computed: `_TAC_LOADER_VERSION . sum(all module versions)`. Each module has a `# Module Version: N` comment that is incremented on any change. The loader is currently v9.

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
| Host metrics (CPU + iGPU + NVIDIA) | 10s | `typeperf.exe` (iGPU + dGPU engines) + `nvidia-smi` (compute fallback) |
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

`env.sh` sources the modules named in the shared list `scripts/_module-list.sh` (the same list the interactive loader reads, so the two can never drift), skipping `13-init.sh` (interactive side-effects); standalone executables like `18-lint.sh` are not listed, and utility scripts in `tools/` are never sourced. It is idempotent (`__TAC_ENV_LOADED` guard) and sets `TAC_LIBRARY_MODE=1`.

`bin/tac-exec` sources `env.sh` then runs `"$@"`, symlinked to `~/.local/bin/tac-exec`.

---

<!-- merged from docs/architecture.md on 2026-09-15 -->

#### Modular Architecture

The profile is split into a thin loader (`tactical-console.bashrc`, ~253 lines)
and 16 numbered profile modules under `scripts/`. Each module has a metadata block
documenting its dependencies and exports:

```bash
```

Both loaders read one **shared list** of module names (not a glob), guaranteeing
load order and keeping the interactive and library paths identical:

```bash

for _tac_mod in "${_tac_expected_modules[@]}"; do
    _tac_f="$_tac_module_dir/${_tac_mod}.sh"
    [[ -f "$_tac_f" ]] && source "$_tac_f"
done
unset _tac_mod _tac_expected_modules
```

`env.sh` iterates the same list and skips `13-init.sh`, whose side-effects are
interactive-only.

Numeric prefixes enforce the dependency chain — `01-constants.sh` loads first,
`15-model-recommender.sh` loads last. Utility scripts live in `tools/` and
`scripts/` (see tables below), are not profile modules, and are never sourced
by either loader.

> **Monolith backup:** The pre-modularisation single-file version
> (`tactical-console.bashrc.monolith`, 5,184 lines) has been removed from the
> repository. It is preserved in git history if needed for reference or
> rollback.

**Profile modules** (sourced in order by the loader — approximate `wc -l` line counts):

| Module | File | Lines | Purpose |
| --- | --- | --- | --- |
| §0 | `tactical-console.bashrc` | ~253 | Version, AI editor rules, architecture map, array-based module loader, missing module warning |
| §1 | `scripts/01-constants.sh` | ~459 | All paths, ports, env vars. Single source of truth. `__TAC_OPENCLAW_OK` functional check. |
| §2 | `scripts/02-error-handling.sh` | ~265 | ERR trap → `bash-errors.log` (exit codes ≥ 2, whitelisted commands excluded) |
| §3 | `scripts/03-design-tokens.sh` | ~38 | ANSI colour constants (`readonly`, re-source safe) |
| §4 | `scripts/04-aliases.sh` | ~462 | Short commands, VS Code wrappers, tactical shortcuts (`c`, `cls`, `le`, `lo` with PIPESTATUS) |
| §5 | `scripts/05-ui-engine.sh` | ~560 | Box-drawing primitives: `__tac_header`, `__fRow`, `__hRow`, `__strip_ansi`, `__threshold_color` |
| §6 | `scripts/06-hooks.sh` | ~177 | `cd` override (venv auto-activate), prompt (`PS1`), `__test_port`, admin badge |
| §7 | `scripts/07-telemetry.sh` | ~396 | Host metrics (CPU + dual GPU), NVIDIA detail, battery, git, disk, tokens, OC version, LLM slots — all background-cached via `__cache_fresh` with trap cleanup |
| §8 | `scripts/08-maintenance.sh` | ~1775 | `up` (20 steps), `cl`, `get-ip`, `sysinfo`, `logtrim`, `docs-sync`, cooldown system with `flock` |
| §9 | `scripts/09-openclaw.sh` (thin loader) | ~54 | Sources 09a–09f sub-modules in order |
| §9a | `scripts/09a-oc-gateway.sh` | ~724 | Gateway lifecycle: `so()`, start/stop/health, Tailscale cycling, API key bridge |
| §9b | `scripts/09b-gog.sh` | ~175 | Google CLI (`gog`) detection, setup helpers, and integration shims |
| §9c | `scripts/09c-oc-core.sh` | ~345 | Core dispatcher: `oc()`, `xo()`, shortcut commands |
| §9d | `scripts/09d-oc-agents.sh` | ~1159 | Agent management, API keys, secrets rotation |
| §9e | `scripts/09e-oc-health.sh` | ~1093 | Health checks, diagnostics, failover, utilities |
| §9f | `scripts/09f-oc-misc.sh` | ~608 | KGraph, stinger, backup/restore, mem-index |
| §10 | `scripts/10-deployment.sh` | ~479 | `mkproj` (disk space check), `deploy_sync`, `commit_deploy`, `commit_auto` (PID-verified, secret detection) |
| §11 | `scripts/11-llm-manager.sh` (thin loader) | ~42 | Sources 11a–11f sub-modules in order |
| §11a | `scripts/11a-llm-registry.sh` | ~267 | Registry CRUD: `__llm_registry_sync_state`, `__renumber_registry`, entry helpers |
| §11b | `scripts/11b-llm-autotune.sh` | ~723 | Autotune infrastructure: profile save, ctx estimation, blob upsert |
| §11c | `scripts/11c-llm-server.sh` | ~537 | Server lifecycle: start/stop, health checks, Python binary resolution |
| §11d | `scripts/11d-llm-gpu.sh` | ~1081 | GPU status, GGUF metadata parsing, calculations (`__calc_gpu_layers`, `__calc_ctx_size`) |
| §11e | `scripts/11e-llm-model.sh` | ~3277 | Model commands: scan, list, use (7 helpers), bench, download, archive, delete, doctor |
| §11f | `scripts/11f-llm-runtime.sh` | ~712 | Runtime: `serve`, `burn`, `local_chat`, SSE streaming, explain, `wtf_repl` |
| §12 | `scripts/12-dashboard-help.sh` | ~707 | `tactical_dashboard` (OpenClaw-aware), `tactical_help`, `bashrc_diagnose` (OpenClaw status) |
| §13 | `scripts/13-init.sh` | ~204 | `mkdir -p` (OpenClaw-aware), completions, loopback fix, bridge call, exit trap (chained) |
| §14 | `scripts/14-wsl-extras.sh` | ~157 | WSL/X11 startup helpers, vault env loading |
| §15 | `scripts/15-model-recommender.sh` | ~198 | AI model recommendations by use case (`bc` fallback for integer math) |

**Utility scripts** (not profile modules — never sourced by the loader):

| File | Purpose |
| --- | --- |
| `scripts/autotune-model.sh` | Model autotune runner (standalone). |
| `scripts/run-autotune-batch.sh` | Batch autotune across multiple models. |
| `scripts/retune-band-chunk.sh` | Run one chunk of the threshold-band re-tune (suspends the CUDA lane, derives the row set from the registry). |
| `scripts/load-vault-env.sh` | Load vault environment variables (standalone). |
| `scripts/oc-update-enhanced.sh` | Enhanced OpenClaw update helper. |
| `scripts/spec-decode-bench.sh` | SPEC-DEC-003/006 per-prompt acceptance bench (standalone). |
| `scripts/spec_dec_crossover.sh` | SPEC-DEC-005 concurrency crossover measurement (standalone). |
| `scripts/prompt-sets.sh` | Shared SPEC-DEC-006 workload prompt sets (sourced by the benches). |
| `scripts/18-lint.sh` | Repo static-analysis wrapper — delegates to `tools/lint.sh`. |
| `tools/capture-golden-fixtures.sh` | Capture baseline command outputs for PowerShell parity checks. |
| `tools/check-agent-use.sh` | Agent-usage regression check (`$TAC_CACHE_DIR`; CI runs it via fixtures). |
| `tools/check-repo-boundaries.sh` | Enforce the repo ownership boundary contract. CI guard. |
| `tools/clean-orphans.sh` | Kill orphaned bench/llama-server keeper processes. |
| `tools/docs-sync-check.sh` | Verify README matches current repo facts (counts/version). CI guard. |
| `tools/import-windows-env.sh` | Standalone script to import Windows user environment variables. |
| `tools/lint.sh` | Static analysis: `bash -n` + shellcheck + Unicode safety. CI linter. |
| `tools/mirror-vault.sh` | Sync Obsidian vault from WSL to Windows. |
| `tools/normalize-fixture.sh` | Normalise captured golden fixtures (strip dynamic fields). |
| `tools/run-tests.sh` | Pretty-printed BATS test runner. |
| `tools/sync-openclaw-completion.sh` | Refresh the OpenClaw bash completion word lists. |

#### Repository Boundaries

This repository intentionally excludes investigator/pipeline implementation code.
If feedback references symbols like `pipeline/model_benchmark.py`,
`BenchmarkCase`, `BenchmarkResult`, or `_normalize_confidence_label`, treat that
as out-of-scope for this repo unless those files are explicitly introduced.

Use `tools/check-repo-boundaries.sh` to enforce this contract. The check scans
`scripts/`, `tools/`, `bin/`, and `tests/` for forbidden cross-repo symbols and
fails fast when boundaries are violated.

#### Dependency Graph

```text
01-constants.sh ────────────────────────────────────────────┐
02-error-handling.sh       ← 01                             │
03-design-tokens.sh        (standalone)                     │
04-aliases.sh              ← 01                             │
05-ui-engine.sh            ← 01, 03                         │
06-hooks.sh                ← 01, 03                         │
07-telemetry.sh            ← 01, 03, 05                     │
08-maintenance.sh          ← 01, 03, 05, 07                 │
09-openclaw.sh (thin)     ─┐                                │
  09a-oc-gateway.sh       ← 01, 03, 05, 06                 │
  09b-gog.sh              ← 01                             │
  09c-oc-core.sh          ← 09a                             │
  09d-oc-agents.sh        ← 09c                             │
  09e-oc-health.sh        ← 09c                             │
  09f-oc-misc.sh          ← 09c                             │
10-deployment.sh           ← 01, 03, 05                     │
11-llm-manager.sh (thin) ─┐                                │
  11a-llm-registry.sh     ← 01                              │
  11b-llm-autotune.sh     ← 11a                             │
  11c-llm-server.sh       ← 01, 11a                         │
  11d-llm-gpu.sh          ← 01, 03                          │
  11e-llm-model.sh        ← 11a, 11b, 11c, 11d             │
  11f-llm-runtime.sh      ← 11e                             │
12-dashboard-help.sh       ← 01, 03, 05, 07, 06, 09, 11    │
13-init.sh                 ← all above                      │
14-wsl-extras.sh           ← 01 (optional startup helpers) ─┘
15-model-recommender.sh    ← 01, 11
```

#### Naming Conventions

| --- | --- | --- |

**Never** use PascalCase or camelCase for function names.

#### Non-Interactive Access (`env.sh` + `tac-exec`)

The interactive guard in `tactical-console.bashrc` (`case $-`) prevents
non-interactive shells (exec environments, cron, AI agents) from loading the
profile. This is intentional — `sftp` and `rsync` must not trigger UI
side-effects. But AI agents and automation scripts need access to the ~100+
functions defined in the profile.

**`env.sh`** is a library loader that sources all 16 profile modules (01–15
plus `09b-gog`), bypassing the interactive guard and skipping `13-init.sh`
(which runs screen clear, completions, WSL loopback fixes, and EXIT traps)
and utility scripts in `tools/`. It reads the canonical load order from
`scripts/_module-list.sh` — the same list the interactive loader uses — so the
two module sets can never drift. It is idempotent (guarded by
`__TAC_ENV_LOADED`) and sets `TAC_LIBRARY_MODE=1` so functions can detect
non-interactive sourcing if needed.

**`bin/tac-exec`** sources `env.sh` then runs `"$@"`. It is symlinked to
`~/.local/bin/tac-exec` for PATH access.

```bash
tac-exec oc health
tac-exec model list
tac-exec so
tac-exec serve 4

```

Thin wrappers in `~/.local/bin/` (`so`, `xo`, `serve`, `oc-backup`, etc.)
delegate to `tac-exec` rather than re-implementing function logic. This
ensures all callers use the canonical function definitions with full error
handling, pre-flight checks, and UI formatting.

**Rule:** Never extract bash functions as standalone scripts. Always
delegate through `tac-exec`.

#### Cross-Cutting State

These variables are written in one section and read by another. They are the
coupling points that must be preserved during modularisation:

| Variable | Written By | Read By | Medium |
| --- | --- | --- | --- |
| `LAST_TPS` | `burn`, `__llm_stream` (§11) | `tactical_dashboard` (§12) | `/dev/shm/last_tps` |
| `__LAST_LLM_RESPONSE` | `__llm_chat_send` (§11) | `local_chat` (§11) | Shell variable |
| `ACTIVE_LLM_FILE` | `model use` (§11) | `oc-local-llm` (§9), dashboard (§12) | `/dev/shm/active_llm` |
| Host metrics cache | `tac_hostmetrics.sh` (external) | `__get_host_metrics` (§7), dashboard (§12) | `/dev/shm/tac_hostmetrics` |
| LLM slots cache | `__get_llm_slots` (§7) | `tactical_dashboard` (§12) | `/dev/shm/tac_llm_slots` |
| OC version cache | `__get_oc_version` (§7) | `tactical_dashboard` (§12) | `/dev/shm/tac_oc_version` |
| `VSCODE_BIN` | `__resolve_vscode_bin` (§1) | aliases (§4) | Shell variable + `/dev/shm/vscode_path` |
| `_TAC_ADMIN_BADGE` | hooks (§6) | `custom_prompt_command` (§6) | Shell variable |
| `CooldownDB` | constants (§1) | maintenance (§8) | `~/.openclaw/maintenance_cooldowns.txt` |
| `__TAC_HAS_BATTERY` | constants (§1) | `__get_battery` (§7) | Shell variable |
| `__TAC_INITIALIZED` | init (§13) | init (§13) | Shell variable |
| `__TAC_BG_PIDS` | `tactical_dashboard` (§12) | EXIT trap (§13) | Shell array (reset per render) |
| `_TAC_LOADER_VERSION` | `tactical-console.bashrc` (§0) | version computation (§0) | Shell variable |
| `TACTICAL_PROFILE_VERSION` | computed: `loader_ver.sum(module_versions)` | dashboard (§12), env info (§9) | Shell export |

#### Telemetry Caching Strategy

All telemetry functions follow the same pattern to avoid blocking the UI.
The shared helper `__cache_fresh <path> <ttl>` centralises the freshness
check:

```bash
__cache_fresh() {
    [[ -f "$1" ]] && (( $(date +%s) - $(stat -c %Y "$1") < $2 ))
}

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
}
```

Cache TTLs per metric:

| Metric | TTL | Rationale |
| --- | --- | --- |
| Host Metrics (CPU + iGPU + NVIDIA) | 10s | iGPU from `typeperf.exe` 3D engine, NVIDIA dGPU from Windows engine counters with `nvidia-smi` compute fallback |
| GPU (NVIDIA detail) | 10s | nvidia-smi is slow (~1.2s) |
| OC Sessions | 60s | Uses `openclaw sessions --all-agents --json`; displays cache age |
| OC Version | 86400s (24h) | CLI version barely changes |
| LLM Slots | 5s | Async query to llama.cpp `/slots` endpoint |

All caches use **atomic writes** (`write .tmp` → `mv .tmp final`) to prevent
partial reads by concurrent dashboard renders.

#### Port Checking

`__test_port` uses `ss -tln "sport = :PORT"` to query the kernel socket
table. This returns in ~20ms and never hangs, unlike the previous
`/dev/tcp` approach which would block indefinitely on closed ports in WSL2
(no TCP RST sent for refused connections).

#### UI Engine

All box-drawing functions use `printf -v` for padding generation (zero
subshells). The `__strip_ansi` function is pure bash regex — no `sed`, no
forks — critical because it is called 20+ times per dashboard render.

Layout constants are derived from `UIWidth` (default 80):

- `__fRow` value column: `UIWidth - 20` characters
- `__hRow` description column: `UIWidth - 22` characters
- Values exceeding their column width are truncated with `...`

#### Error Handling

The ERR trap logs to `~/.openclaw/logs/bash-errors.log` with timestamps:

```text
2026-03-07 14:32:01 [EXIT 127] some_missing_command --flag
```

Exit code 1 is **filtered out** because `grep`, `test`, and `[[ ]]` return 1
for normal "not found" / "false" conditions. Only exit codes ≥ 2 are logged.

#### Security Measures

1. **LLM loopback binding** — `llama-server` binds to `127.0.0.1`, not `0.0.0.0`.
2. **API key cache** — `chmod 600` on tmpfs (`/dev/shm`). Never written to disk.
3. **Commit auto guard** — `commit_auto` blocks sending git diffs to non-localhost LLM URLs and verifies `llama-server` PID is actually running before sending.
4. **oc-llm-sync.sh integrity** — SHA256 hash is verified before sourcing. Mismatches skip the source and warn. Use `oc-trust-sync` to record a new trusted hash.
5. **ERR trap** — All failed commands (exit ≥ 2) are logged with timestamps.
6. **Bridge timeout** — `pwsh.exe` calls have a 5-second `timeout` to prevent hangs.
7. **Sudo guard** — WSL loopback fix uses `sudo -n` (non-interactive only).
8. **Variable name validation** — Bridge skips vars with non-`[a-zA-Z0-9_]` characters.

---

The profile was modularised in v3.0 (splitting a ~5,184-line monolith). The
pre-modularisation file was preserved as `tactical-console.bashrc.monolith`
but has since been removed from the repository (it remains in git history).

**Ordering rules:** `01-constants.sh` must load first (everything depends on
it). `13-init.sh` runs the interactive startup side-effects (screen clear,
completions, WSL loopback fixes, EXIT traps); the canonical order in
`scripts/_module-list.sh` places it near the end, followed only by
`14-wsl-extras.sh` and `15-model-recommender.sh`. All other modules can be
reordered as long as their `@depends` are satisfied.

#### Benefits Realised

| Benefit | Detail |
| --- | --- |
| **Faster iteration** | Edit `11e-llm-model.sh` without scrolling past 500 lines of unrelated server or GPU code. |
| **Targeted testing** | `bash -n scripts/09a-oc-gateway.sh` checks only gateway functions. |
| **Selective loading** | On a server with no GPU, skip `11d-llm-gpu.sh`. On a headless box, skip `12-dashboard-help.sh`. |
| **Reduced merge conflicts** | Edits to OpenClaw and LLM code never touch the same file. |
| **Git blame clarity** | `git log scripts/09c-oc-core.sh` shows only core dispatcher changes. |
| **Easier onboarding** | A new developer reads one 200-line module instead of a 5,184-line monolith. |

#### Monolith Backup

The file `tactical-console.bashrc.monolith` was the last pre-split version of
the profile. It has been removed from the working tree but remains in git
history. To restore it for reference or emergency rollback:

```bash
git show HEAD~N:tactical-console.bashrc.monolith > tactical-console.bashrc.monolith
```

(Replace `N` with the number of commits since removal, or use the commit hash
where it was last present.)

#### Risks & Mitigations

| Risk | Mitigation |
| --- | --- |
| Source order bugs | Numeric prefixes enforce deterministic ordering. `bash -n` runs on every module in CI. |
| `readonly` collisions on re-source | Already guarded with `[[ -z "${C_Reset:-}" ]]`. |
| Missing module breaks shell | The loader warns if expected module count doesn't match; each `[[ -f ]]` guards gracefully. |
| Performance regression (many `source` calls) | 16 `source` calls add < 10ms total. Measured on this hardware. |
| Utility scripts accidentally sourced | Array-based loader (not glob) — only the 16 named profile modules are sourced. |

---

## Repository Layout

```
~/ubuntu-console/
├── tactical-console.bashrc            # Thin loader + module sourcing loop
├── env.sh                             # Non-interactive library loader (all modules except 13-init.sh)
├── install.sh                         # Idempotent installer
├── config/
│   ├── quant-guide.conf               # Quantization priority ratings (editable)
│   └── concept-aliases.json           # kgraph concept classification data
├── bin/
│   ├── tac-exec                       # Bootstrap: source env.sh + exec "$@"
│   ├── tac_hostmetrics.sh             # Host CPU + iGPU + NVIDIA dGPU load/engines
│   ├── llama-watchdog.sh              # Watchdog: auto-restart with -ngl 999, --prio 2
│   ├── bench-timeout-runner.sh        # Bench subprocess runner with PID tracking + cleanup
│   ├── oc-gpu-status                  # Thin wrapper → tac-exec gpu-status
│   ├── oc-model-status                # Thin wrapper → tac-exec ocms
│   ├── oc-model-switch                # Thin wrapper → tac-exec serve
│   ├── oc-quick-diag                  # Thin wrapper → tac-exec oc diag
│   └── oc-wake                        # Thin wrapper → tac-exec wake
├── scripts/                           # Profile modules (01-15, 09a-f, 11a-f) + kgraph package
│   ├── 01-constants.sh                #   All paths, ports, env vars
│   ├── 02-error-handling.sh           #   ERR trap
│   ├── 03-design-tokens.sh            #   ANSI colour constants
│   ├── 04-aliases.sh                  #   Short commands, VS Code wrappers
│   ├── 05-ui-engine.sh                #   Box-drawing primitives
│   ├── 06-hooks.sh                    #   cd override, prompt, port test
│   ├── 07-telemetry.sh                #   CPU, GPU, battery, git, disk, tokens
│   ├── 08-maintenance.sh              #   up (20 steps), cl, get-ip, sysinfo
│   ├── 09-openclaw.sh                 #   Thin loader → 09a-f sub-modules
│   ├── 09a-oc-gateway.sh              #     Gateway: so, xo, oc, ockeys, oc-refresh-keys
│   ├── 09b-gog.sh                     #   Google CLI (gog) detection and helpers
│   ├── 09c-oc-core.sh                 #     Core: backup/restore, oc-agent-use, oc-failover
│   ├── 09d-oc-agents.sh               #     Agents: oc-kgraph, owk, oc-update, oc-cron
│   ├── 09e-oc-health.sh               #     Health: oc-health, oc-plugins, oc-sec
│   ├── 09f-oc-misc.sh                 #     Misc: oc-stinger, oc-env, oc-cache-clear, mem-index
│   ├── 10-deployment.sh               #   mkproj, git commit+push, deploy
│   ├── 11-llm-manager.sh              #   Thin loader → 11a-f sub-modules
│   ├── 11a-llm-registry.sh            #     Registry CRUD, sync, renumber
│   ├── 11b-llm-autotune.sh            #     Autotune infrastructure
│   ├── 11c-llm-server.sh              #     Server lifecycle, health
│   ├── 11d-llm-gpu.sh                 #     GPU status, GGUF metadata, calc
│   ├── 11e-llm-model.sh               #     Model mgmt, chat, burn, bench
│   ├── 11f-llm-runtime.sh             #     Runtime: wake, serve, halt, mlogs
│   ├── 12-dashboard-help.sh           #   Dashboard ('m') and Help ('h')
│   ├── 13-init.sh                     #   mkdir, completions, WSL loopback, exit trap
│   ├── 14-wsl-extras.sh               #   WSL/X11 helpers, completions, vault env
│   ├── 15-model-recommender.sh        #   AI model recommendations by use case
│   ├── _module-list.sh                #   Canonical module load order (shared by both loaders)
│   ├── _startup-env.sh                #   Shared startup env fragment (sourced by loader + env.sh)
│   └── kgraph/                        #   Knowledge graph Python package (23 modules)
│       ├── models.py                  #     GraphNode, GraphEdge, Graph, GraphBuilder
│       └── templates/kgraph.html      #     Cytoscape.js viewer template
├── tools/                             # Standalone utility scripts (not sourced)
│   ├── capture-golden-fixtures.sh     #   Snapshot command output for PowerShell parity checks
│   ├── check-agent-use.sh             #   Agent-usage regression check (CI via fixtures)
│   ├── check-repo-boundaries.sh       #   Repo ownership boundary guard
│   ├── clean-orphans.sh               #   Kill orphaned bench/llama-server processes
│   ├── docs-sync-check.sh             #   Docs drift guard (counts in README and pytest.ini)
│   ├── import-windows-env.sh          #   Import Windows user environment variables
│   ├── lint.sh                        #   bash -n + shellcheck + Unicode safety
│   ├── mirror-vault.sh                #   Sync Obsidian vault to Windows
│   ├── normalize-fixture.sh           #   Normalise captured fixtures
│   ├── run-tests.sh                   #   BATS test runner
│   └── sync-openclaw-completion.sh    #   Refresh OpenClaw bash completions
├── docs/                              # Reference documentation
│   ├── AGENT-GUIDELINES.md            #   AI agent operating manual
│   ├── inspection.md                  #   Audit checklist
│   ├── llm.md                         #   Local LLM stack: registry, tuning, autotune, build
│   ├── llama-cpp-runtime-audit.md     #   Measured findings + evidence appendix
│   ├── openclaw.md                    #   OpenClaw integration guide
│   └── contracts/                     #   PowerShell translation contracts (YAML)
├── .agents/
│   └── pwsh-build-prompt.md           #   PowerShell translation strategy + AI build prompt
├── frontend-g6/                       # React + AntV G6 dev frontend (untracked; optional)
│   └── src/                           #   App.jsx, G6App.jsx, CytoscapeApp.jsx
├── tests/
│   ├── conftest.py                    # Pytest config — BATS lock serialization, VS Code discovery guard
│   ├── _paths.py                      # Shared sys.path bootstrap for kgraph imports
│   ├── tactical-console.bats          # BATS full suite (386 tests, ~5-15 min)
│   ├── tactical-console-fast.bats     # Fast subset (53 tests, ~2 min)
│   ├── tactical-console-function-availability.bats  # Function availability checks (2 tests)
│   ├── test_bats_bridge.py            # BATS→pytest bridge: exposes each @test as an individual pytest test
│   ├── test_bats_lock_fixture.py      # Tests for conftest lock fixture
│   ├── test_kgraph.py                 # Python tests for kgraph package (92 tests)
│   ├── test_kgraph_wiring.py          # kgraph wiring/orphan detection tests (13 tests)
│   ├── test_models.py                 # Pydantic model tests (37 tests)
│   ├── test_untested_modules.py       # Tests for call_flow, update, life_index, benchmark, etc.
│   ├── unit/                          # BATS unit tests (99 tests: 7+4+8+5+5+6+19+4+8+7+26)
│   └── integration/                   # BATS integration tests (119 tests: 14+42+10+22+5+26)
└── systemd/
    ├── llama-watchdog.service
    ├── llama-watchdog.timer
    ├── llama-xe-minicpm5-1b-chat.service
    ├── llama-xe-embeddinggemma-embed.service
    ├── llama-cuda-llama32-3b-chat.service
    └── llama-cuda-qwen35-4b-pipeline.service
```

### Symlink Map

| System Path | Source |
|---|---|
| `~/.bashrc` | Thin loader (not in repo — sources `tactical-console.bashrc`) |
| `~/.local/bin/<name>` | Every file in `bin/` — `tac-exec`, `tac_hostmetrics.sh`, `llama-watchdog.sh`, `bench-timeout-runner.sh`, `oc-*` wrappers — **symlinked**, except the four the card launchers and their helpers occupy (`llama-cuda-server`, `llama-xe-server`, `llama-gpu-clear.sh`, `gpu-busy.sh`), which are installed as one-line `exec` shims so the stable path stays real |
| `~/.local/bin/load-vault-env.sh` | `scripts/load-vault-env.sh` |
| `~/.local/bin/oc-update-enhanced.sh` | `scripts/oc-update-enhanced.sh` |
| `~/.config/systemd/user/<unit>` | Every file in `systemd/`, plus **relative** legacy-name symlinks (`llama-server.service` → `llama-xe-minicpm5-1b-chat.service`, …). Relative on purpose: an absolute alias makes systemd load a second unit for the same service |

---

<!-- merged from docs/architecture.md §10 on 2026-09-15: its Directory Structure and Symlink Map duplicated this section and were dropped -->

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


end of file

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

**Not required for LLM streaming:** Python (streaming is pure bash + curl + jq), Ruby, Docker.
**Required for `oc g` / kgraph tooling:** Python 3.12+, `pydantic>=2.0`, `networkx>=3.0` (declared in `scripts/pyproject.toml`).

---

<!-- merged from docs/architecture.md §9 -->

### What Is NOT Required

- **Python** — All LLM streaming is pure bash + curl + jq.
- **Ruby** — Never used.
- **Docker** — The gateway runs as a native systemd service.

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

Full AI agent operating manual: [docs/AGENT-GUIDELINES.md](docs/AGENT-GUIDELINES.md)

---

## Troubleshooting

**Dashboard shows stale or missing data**
Run `oc-cache-clear` to wipe all `/dev/shm/tac_*` caches, then `m` again.

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

<!-- merged from docs/troubleshooting.md on 2026-09-15 -->

---
title: Troubleshooting
description: Common issues and solutions — stale dashboard data, gateway crashes, API key bridging, LLM offline, slow rendering, commit failures, sync hash mismatches, cooldown issues, and slow shell startup.
---


### Dashboard shows stale or missing data

First render after clearing will show "Querying..." for some metrics while
background refreshes run.

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


## CI Status

[![CI](.github/workflows/ci.yml)](.github/workflows/ci.yml)

- **Fast tests:** `bats tests/tactical-console-fast.bats` (~20s, 53 tests)
- **Full tests:** `bats tests/tactical-console.bats` (386 BATS unit tests)
- **Unit suites (86 tests overall):** CI runs `tests/unit/01`, `02`, `09`, `10`, `11`, `12`; nightly adds `05`–`08`. `04-llama-cpp-inventory` is excluded from both — it performs live downloads and mutates the host.
- **Integration suites (119 tests overall):** both run `tests/integration/01`–`05` plus `e2e-bench-autotune` (the e2e suite re-runs its own regression subset, so it is the slow part of the gate).
- **Lint:** `tools/lint.sh` (bash -n + shellcheck + Unicode safety) with three modes — whole repo (default), `--staged` (staged `.sh`, used by the pre-commit hook) and `--files F...` (an explicit list, used by the BATS suites) — so the shellcheck flags live in exactly one place, and shellcheck runs `-x --source-path` so the source-following SC1090/SC1091 class resolves instead of being suppressed. shellcheck itself is pinned to 0.11.0 via `tools/install-shellcheck.sh`, which CI runs so local and CI diagnostics cannot drift (0.9.0 reported SC2317 where 0.11.0 reports SC2329 for the same code).
- **Git hooks:** tracked in `tools/hooks/` (`pre-commit`, `post-commit`, `post-merge`) and activated by `git config core.hooksPath <repo>/tools/hooks`, which `install.sh` sets. They are tracked because `.git/hooks/` is not version-controlled — an inlined copy of the shellcheck loop there drifted from `tools/lint.sh` on 2026-09-15, when only one of the two copies of the flags was updated.
- **Docs sync:** `tools/docs-sync-check.sh` (docs drift guard — fails CI on stale module counts, versions, or test totals, wherever they are stated)
- **Nightly:** full suite runs nightly via `.github/workflows/nightly.yml` (scheduled + manual dispatch)

Run locally:

```bash
bats tests/tactical-console-fast.bats   # Quick feedback
bats tests/tactical-console.bats        # Full suite
bats tests/unit/*.bats                  # Unit tests
bats tests/integration/*.bats           # Integration tests
tools/lint.sh                           # Static analysis
```

<!-- end of file -->