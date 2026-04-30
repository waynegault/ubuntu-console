---
title: Architecture
description: Developer guide to the modular profile architecture — module layout, dependency graph, naming conventions, non-interactive access, telemetry caching, UI engine, error handling, security measures, and repository layout.
---

# Architecture & Developer Guide

## 5. Developer Guide — How the Profile Works

### Modular Architecture

The profile is split into a thin loader (`tactical-console.bashrc`, ~225 lines)
and 16 numbered profile modules under `scripts/`. Each module has a metadata block
documenting its dependencies and exports:

```bash
# @modular-section: <name>
# @depends: <comma-separated section names>
# @exports: <public functions/variables>
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
```

The loader iterates an **explicit array** of expected module names (not a glob),
guaranteeing load order and preventing accidental sourcing of utility scripts:

```bash
_tac_expected_modules=(
    01-constants 02-error-handling 03-design-tokens 04-aliases
    05-ui-engine 06-hooks 07-telemetry 08-maintenance 09-openclaw 09b-gog
    10-deployment 11-llm-manager 12-dashboard-help 13-init 14-wsl-extras
    15-model-recommender
)

for _tac_mod in "${_tac_expected_modules[@]}"; do
    _tac_f="$_tac_module_dir/${_tac_mod}.sh"
    [[ -f "$_tac_f" ]] && source "$_tac_f"
done
unset _tac_mod _tac_expected_modules
```

Numeric prefixes enforce the dependency chain — `01-constants.sh` loads first,
`15-model-recommender.sh` loads last. Five **utility scripts** (`16–20`) are
not profile modules and are never sourced by either loader.

> **Monolith backup:** The pre-modularisation single-file version is preserved
> as `tactical-console.bashrc.monolith` (5,184 lines) for reference and
> rollback.

**Profile modules** (sourced in order by the loader):

| Module | File | Lines | Purpose |
|---|---|---|---|
| §0 | `tactical-console.bashrc` | ~225 | Version, AI editor rules, architecture map, array-based module loader, missing module warning |
| §1 | `scripts/01-constants.sh` | 342 | All paths, ports, env vars. Single source of truth. `__TAC_OPENCLAW_OK` functional check. |
| §2 | `scripts/02-error-handling.sh` | 258 | ERR trap → `bash-errors.log` (exit codes ≥ 2, whitelisted commands excluded) |
| §3 | `scripts/03-design-tokens.sh` | 48 | ANSI colour constants (`readonly`, re-source safe) |
| §4 | `scripts/04-aliases.sh` | 421 | Short commands, VS Code wrappers, tactical shortcuts (`c`, `cls`, `le`, `lo` with PIPESTATUS) |
| §5 | `scripts/05-ui-engine.sh` | 534 | Box-drawing primitives: `__tac_header`, `__fRow`, `__hRow`, `__strip_ansi`, `__threshold_color` |
| §6 | `scripts/06-hooks.sh` | 197 | `cd` override (venv auto-activate), prompt (`PS1`), `__test_port`, admin badge |
| §7 | `scripts/07-telemetry.sh` | 361 | Host metrics (CPU + dual GPU), NVIDIA detail, battery, git, disk, tokens, OC version, LLM slots — all background-cached via `__cache_fresh` with trap cleanup |
| §8 | `scripts/08-maintenance.sh` | 1461 | `up` (13 steps), `cl`, `get-ip`, `sysinfo`, `logtrim`, `docs-sync`, cooldown system with `flock` |
| §9 | `scripts/09-openclaw.sh` | 3217 | Full OpenClaw wrapper suite (gateway, backup, bridge, `oc-failover`, wacli, `oc-kgraph`, whitelist subcommand validation, process kill safety) |
| §9b | `scripts/09b-gog.sh` | 165 | Google CLI (`gog`) detection, setup helpers, and integration shims |
| §10 | `scripts/10-deployment.sh` | 460 | `mkproj` (disk space check), `deploy_sync`, `commit_deploy`, `commit_auto` (PID-verified, secret detection) |
| §11 | `scripts/11-llm-manager.sh` | 3209 | `__require_llm`, model management, streaming chat, burn, bench, explain, `__calc_gpu_layers`, `__gguf_metadata` |
| §12 | `scripts/12-dashboard-help.sh` | 681 | `tactical_dashboard` (OpenClaw-aware), `tactical_help`, `bashrc_diagnose` (OpenClaw status) |
| §13 | `scripts/13-init.sh` | 134 | `mkdir -p` (OpenClaw-aware), completions, loopback fix, bridge call, exit trap (chained) |
| §14 | `scripts/14-wsl-extras.sh` | 138 | WSL/X11 startup helpers, OpenClaw completions sourcing (guarded), vault env loading |
| §15 | `scripts/15-model-recommender.sh` | 194 | AI model recommendations by use case (`bc` fallback for integer math) |

**Utility scripts** (moved to `tools/`; not profile modules — never sourced by the loader):

| File | Purpose |
|---|---|
| `tools/check-agent-use.sh` | Agent usage regression checker — CI/tests only. |
| `tools/import-windows-env.sh` | Standalone script to import Windows user environment variables. |
| `tools/lint.sh` | Static analysis: `bash -n` + shellcheck + Unicode safety. CI linter. |
| `tools/mirror-vault.sh` | Sync Obsidian vault from WSL to Windows. |
| `tools/run-tests.sh` | Pretty-printed BATS test runner (489 tests). |

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
09b-gog.sh                 ← 01                             │
10-deployment.sh           ← 01, 03, 05, 06                 │
11-llm-manager.sh          ← 01, 03, 05, 06                 │
12-dashboard-help.sh       ← 01, 03, 05, 07, 06, 09, 11    │
13-init.sh                 ← all above                      │
14-wsl-extras.sh           ← 01 (optional startup helpers) ─┘
15-model-recommender.sh    ← 01, 11
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

**`env.sh`** is a library loader that sources all 16 profile modules (01–15
plus `09b-gog`), bypassing the interactive guard and skipping `13-init.sh`
(which runs screen clear, completions, WSL loopback fixes, and EXIT traps)
and utility scripts 16–20. Because `09b-gog.sh` does not match the
`[0-9][0-9]-*.sh` glob it is sourced explicitly after the main loop. It is
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
| `VSCODE_BIN` | `__resolve_vscode_bin` (§1) | aliases (§4) | Shell variable + `/dev/shm/vscode_path` |
| `_TAC_ADMIN_BADGE` | hooks (§6) | `custom_prompt_command` (§6) | Shell variable |
| `CooldownDB` | constants (§1) | maintenance (§8) | `~/.openclaw/maintenance_cooldowns.txt` |
| `__TAC_HAS_BATTERY` | constants (§1) | `__get_battery` (§7) | Shell variable |
| `__TAC_INITIALIZED` | init (§13) | init (§13) | Shell variable |
| `__TAC_BG_PIDS` | `tactical_dashboard` (§12) | EXIT trap (§13) | Shell array (reset per render) |
| `_TAC_LOADER_VERSION` | `tactical-console.bashrc` (§0) | version computation (§0) | Shell variable |
| `TACTICAL_PROFILE_VERSION` | computed: `loader_ver.sum(module_versions)` | dashboard (§12), env info (§9) | Shell export |

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

## 6. Modular Architecture — Benefits

The profile was modularised in v3.0 (splitting a ~5,184-line monolith). The
pre-modularisation file is preserved as `tactical-console.bashrc.monolith`
for reference and emergency rollback.

**Ordering rules:** `01-constants.sh` must load first (everything depends on
it). `13-init.sh` must load last (runs startup side-effects). All other
modules can be reordered as long as their `@depends` are satisfied.

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
| Missing module breaks shell | The loader warns if expected module count doesn't match; each `[[ -f ]]` guards gracefully. |
| Performance regression (many `source` calls) | 16 `source` calls add < 10ms total. Measured on this hardware. |
| Utility scripts accidentally sourced | Array-based loader (not glob) — only the 16 named profile modules are sourced. |

---

## 9. Dependencies & Requirements

### System Requirements

| Component | Requirement |
|---|---|
| **OS** | Windows 11 Pro with WSL2 |
| **WSL Distribution** | Ubuntu 24.04 |
| **Shell** | Bash 5.2+ |
| **GPU** | NVIDIA RTX 3050 Ti (or any CUDA-capable GPU) |
| **PowerShell** | 7.4+ (as `pwsh.exe` in WSL interop PATH) |

### Required Packages

| Package | Used By | Install |
|---|---|---|
| `jq` | All LLM/SSE functions, token scanning | `sudo apt install jq` |
| `curl` | LLM API calls, health checks, WAN IP | Pre-installed |
| `ss` (iproute2) | `__test_port` port checking | Pre-installed |
| `grep` / `awk` / `sed` | Telemetry parsing, text processing | Pre-installed |
| `find` | Token scanning, temp cleanup, session counting | Pre-installed |
| `systemctl` / `journalctl` | OpenClaw gateway lifecycle, logs | Pre-installed (systemd) |
| `typeperf.exe` | Host CPU + iGPU telemetry | Windows built-in (WSL interop) |
| `nvidia-smi` | CUDA/compute GPU telemetry | WSL NVIDIA driver |
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

### What Is NOT Required

- **Python** — All LLM streaming is pure bash + curl + jq.
- **Ruby** — Never used.
- **Docker** — The gateway runs as a native systemd service.

---

## 10. Repository Layout

All project files live in a single Git repository at
`~/ubuntu-console/` (remote: `github.com/waynegault/ubuntu-console`).
`~/.bashrc` is a thin loader that sources `tactical-console.bashrc`, which in
turn sources the 16 numbered profile modules from `scripts/` using an
explicit array.

**~/.bashrc enforcement:** The file is read-only (mode 444) and protected by
10 unit tests that prevent pollution with functions, aliases, exports, or
extra source commands.

### Directory Structure

```
~/ubuntu-console/
├── tactical-console.bashrc            # Thin loader + array-based module sourcing loop
├── tactical-console.bashrc.monolith   # Pre-modularisation backup (frozen snapshot)
├── env.sh                             # Non-interactive library loader (modules 01-15 except 13-init.sh)
├── install.sh                         # Idempotent installer for new machines
├── config/
│   └── quant-guide.conf               # Quantization priority ratings (editable)
├── README.md                          # Repository documentation
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
├── scripts/                           # Profile modules (01-15, 09b) + utility scripts (16-20)
│   ├── 01-constants.sh                #   All paths, ports, env vars
│   ├── 02-error-handling.sh           #   ERR trap (exit ≥ 2 logged)
│   ├── 03-design-tokens.sh            #   ANSI colour constants
│   ├── 04-aliases.sh                  #   Short commands, VS Code wrappers
│   ├── 05-ui-engine.sh                #   Box-drawing primitives
│   ├── 06-hooks.sh                    #   cd override, prompt, port test
│   ├── 07-telemetry.sh                #   CPU, GPU, battery, git, disk, tokens
│   ├── 08-maintenance.sh              #   up (13 steps), cl, get-ip, sysinfo, logtrim, docs-sync
│   ├── 09-openclaw.sh                 #   Gateway, backup, bridge, oc-failover, wacli, kgraph
│   ├── 09b-gog.sh                     #   Google CLI (gog) detection and helpers
│   ├── 10-deployment.sh               #   mkproj (disk check), git commit+push, deploy
│   ├── 11-llm-manager.sh              #   Model mgmt, chat, burn, bench, explain
│   ├── 12-dashboard-help.sh           #   Dashboard ('m') and Help ('h'), bashrc_diagnose
│   ├── 13-init.sh                     #   mkdir, completions, WSL loopback, exit trap
│   ├── 14-wsl-extras.sh               #   WSL/X11 helpers, completions, vault env
│   ├── 15-model-recommender.sh        #   AI model recommendations by use case
│   └── kgraph/                        #   Knowledge graph Python package
├── tools/                             # Standalone utility scripts (not sourced)
│   ├── check-agent-use.sh             #   Agent usage regression checker (CI)
│   ├── import-windows-env.sh          #   Import Windows user env vars (standalone)
│   ├── lint.sh                        #   bash -n + shellcheck + Unicode safety
│   ├── mirror-vault.sh                #   Sync Obsidian vault to Windows
│   ├── run-tests.sh                   #   BATS test runner (489 tests)
├── frontend-g6/                       # React + AntV G6 knowledge graph frontend
│   ├── package.json                   #   Vite 5 + React 18 + G6 5.0
│   └── src/                           #   App.jsx, G6App.jsx, CytoscapeApp.jsx
├── docs/                              # Reference documentation
│   ├── AGENT-GUIDELINES.md            #   AI agent operating manual
│   ├── architecture.md                #   This file
│   ├── llm.md                         #   Local LLM stack reference
│   ├── openclaw.md                    #   OpenClaw integration guide
│   ├── reference.md                   #   Command reference + dashboard
│   └── troubleshooting.md             #   Diagnostics and fixes
├── tests/
│   ├── tactical-console.bats          # 489 BATS unit tests
│   ├── tactical-console-fast.bats     # Fast subset (47 tests, ~20s)
│   └── test_kgraph.py                 # Python tests for kgraph package
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

← [Back to README](../README.md)

# end of file
