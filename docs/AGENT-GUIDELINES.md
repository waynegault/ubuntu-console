---
title: AI Agent Access — Command Catalog
description: Complete reference for AI agents (Hal) accessing Tactical Console via tac-exec. Covers command categories, JSON output, file reading mode, common workflows, setup, security, and troubleshooting.
---

# Tactical Console — AI Agent Access (tac-exec)

## Single Entry Point

```bash
tac-exec <command> [args...]
```

`tac-exec` sources `~/ubuntu-console/env.sh` (which loads all 16 profile modules
except `13-init.sh`) then executes the command. All ~100+ shell functions become
available without an interactive shell.

**File-reading mode:** Commands that open VS Code for humans output content instead
when called with `--read` or when `TAC_READ_MODE=1` is set.

---

## Setup

```bash
# Verify tac-exec is on PATH
which tac-exec
# /home/wayne/.local/bin/tac-exec

# Ensure tac-exec is in the exec allowlist
jq '.agents.main.allowlist[] | select(.pattern | contains("tac-exec"))' \
  ~/.openclaw/exec-approvals.json

# Install the tactical-console OpenClaw skill (optional — improves discovery)
cp -r ~/ubuntu-console/skills/tactical-console ~/.openclaw/skills/
openclaw skills enable tactical-console
```

---

## Command Categories

### LLM Model Management

| Command | Description | Example Output |
|---------|-------------|----------------|
| `tac-exec model status` | Active model, health, build | `Active #1 Phi-4-mini (3.0G)` `Health OK` |
| `tac-exec model status --json` | JSON output for parsing | `{"online":true,"port":8081,...}` |
| `tac-exec model status --plain` | Key=value for scripting | `online=1` `port=8081` |
| `tac-exec model list` | Numbered model registry (▶ = active) | Table with #, name, size, quant, GPU layers |
| `tac-exec model list --json` | JSON model list | `{"models":[...],"drive":{...}}` |
| `tac-exec model use N` | Start model #N | Spinner + `ONLINE [Port 8081]` |
| `tac-exec model stop` | Stop running LLM | `[STOPPED]` |
| `tac-exec model info N` | Full details for model #N | Config + on-disk status |
| `tac-exec model scan` | Rescan model directory, rebuild registry | Updates `models.conf` |
| `tac-exec model doctor` | Health diagnostic | Checklist: registry, GPU, watchdog, ports |
| `tac-exec model bench` | Benchmark all models | TSV written to `/mnt/m/.llm/bench_*.tsv` |
| `tac-exec model recommend` | Rank models for 4 GB VRAM | Sorted recommendation table |

### Gateway Control

| Command | Description | Output |
|---------|-------------|--------|
| `tac-exec so` | Start gateway (injects API keys, waits for port 18789) | `Local LLM [RUNNING]` `Gateway [RUNNING]` |
| `tac-exec xo` | Stop gateway only | `[TERMINATED]` |
| `tac-exec oc restart` | Full gateway restart (`openclaw gateway restart`) | Stop → Start |
| `tac-exec oc health` | Deep probe: port + `openclaw health --json` | Health status |
| `tac-exec oc health --json` | JSON health output | `{"status":"ok",...}` |

### Direct LLM Control

| Command | Description | Output |
|---------|-------------|--------|
| `tac-exec serve` | Start default LLM model | `ONLINE [Port 8081]` |
| `tac-exec serve N` | Start model #N | `ONLINE [Port 8081]` |
| `tac-exec halt` | Stop LLM | `[STOPPED]` |
| `tac-exec wake` | Lock GPU persistence mode | `[GPU LOCKED]` |
| `tac-exec burn` | ~1300 token stress test + TPS benchmark | TPS result |

### File Reading (use `--read`)

These normally open VS Code; with `--read` they output content to stdout:

| Command | What It Reads |
|---------|---------------|
| `tac-exec --read llmconf` | `~/.llm/models.conf` |
| `tac-exec --read mlogs` | Last 100 lines of `/dev/shm/llama-server.log` |
| `tac-exec --read occonf` | `~/.openclaw/openclaw.json` |
| `tac-exec --read oedit` | `~/ubuntu-console/tactical-console.bashrc` |
| `tac-exec --read oclogs` | OpenClaw temp log |

### Diagnostics

| Command | Description |
|---------|-------------|
| `tac-exec model doctor` | Full LLM health check (registry, GPU, watchdog, ports) |
| `tac-exec oc doctor-local` | End-to-end gateway + llama.cpp validation (`--json`/`--plain`) |
| `tac-exec oc diag` | 5-point diagnostic |
| `tac-exec oc health` | Gateway HTTP health probe |
| `tac-exec le` | Last 40 lines of gateway journal (stderr) |
| `tac-exec lo` | Last 120 lines of gateway journal (stdout) |

### OpenClaw Operations

| Command | Description |
|---------|-------------|
| `tac-exec oc start -m "msg"` | Dispatch agent turn |
| `tac-exec oc stop --agent ID` | Delete agent |
| `tac-exec oc backup` | Create backup ZIP (config, agents, workspace, scripts, systemd) |
| `tac-exec oc-refresh-keys` | Re-bridge Windows API keys + sync OC SecretRefs |
| `tac-exec oc-cache-clear` | Wipe all `/dev/shm/tac_*` telemetry caches |
| `tac-exec ockeys` | Show Windows API keys and their WSL visibility |
| `tac-exec mem-index` | Rebuild OpenClaw memory index |
| `tac-exec oc skills` | List installed skill modules |
| `tac-exec oc tui` | Launch terminal UI |

### System Status

| Command | Description |
|---------|-------------|
| `tac-exec gpu-status` | GPU info (NVIDIA detail) |
| `tac-exec get-ip` | WSL IP + external WAN IP |
| `tac-exec sysinfo` | One-line: CPU / RAM / Disk / iGPU / CUDA |

---

## JSON Output for Programmatic Use

```bash
# Model status as JSON
tac-exec model status --json
# {"online":true,"port":8081,"active_num":"1","active_name":"Phi-4-mini",...}

# Model list as JSON
tac-exec model list --json
# {"models":[{"num":"1","name":"Phi-4-mini","active":true,...}],"drive":{...}}

# Gateway health
tac-exec oc health --json
# {"status":"ok","port":18789,...}
```

Parse with `jq`:

```bash
tac-exec model status --json | jq '.health'
tac-exec model list --json | jq '.models[] | select(.active==true) | .name'
tac-exec model status --json | jq '{llm_online: .online, model: .active_name}'
```

---

## Common Workflows

### Check if the LLM is running

```bash
tac-exec model status
tac-exec model status --json | jq '{online: .online, model: .active_name}'
```

### Start the gateway

```bash
tac-exec so
```

### Switch to model 2

```bash
tac-exec model list       # see available
tac-exec model use 2      # start #2
tac-exec model status     # verify
```

### The gateway is stuck — restart it

```bash
tac-exec oc restart
# or manually:
tac-exec xo && tac-exec so
```

### Start the LLM if offline

```bash
tac-exec model status     # check
tac-exec serve            # default model
tac-exec model use 1      # specific model
```

### Debug LLM issues

```bash
tac-exec model status
tac-exec --read mlogs | tail -50
tac-exec le
tac-exec model doctor
```

### Full diagnostic sequence

```bash
tac-exec model status --json | jq '.'
tac-exec so
tac-exec oc health
tac-exec --read llmconf
tac-exec --read mlogs | tail -50
tac-exec le
```

---

## Error Handling

All commands return:
- **Exit 0** = Success
- **Exit 1** = Failure (check output for details)

Common error strings:
- `[OFFLINE]` — LLM not running → `tac-exec serve`
- `[NOT FOUND]` — File missing → check path or run `tac-exec model scan`
- `[FAILED TO START]` — Model failed to boot → `tac-exec --read mlogs`
- `[PORT BLOCKED]` — Port in use (Windows conflict possible)

Check the ERR trap log for unexpected failures:

```bash
cat ~/.openclaw/logs/bash-errors.log | tail -20
```

---

## Port Reference

| Service | Port | Health URL |
|---------|------|------------|
| LLM (`llama-server`) | 8081 | `http://127.0.0.1:8081/health` |
| Gateway (OpenClaw) | 18789 | `http://127.0.0.1:18789/api/health` |

---

## Key File Locations

| File / Purpose | Path or Command |
|----------------|-----------------|
| Model registry | `tac-exec --read llmconf` → `~/.llm/models.conf` |
| LLM logs | `tac-exec --read mlogs` → `/dev/shm/llama-server.log` |
| OpenClaw config | `tac-exec --read occonf` → `~/.openclaw/openclaw.json` |
| Gateway journal | `tac-exec le` / `tac-exec lo` |
| Shell profile | `tac-exec --read oedit` → `~/ubuntu-console/tactical-console.bashrc` |
| Active model number | `/dev/shm/active_llm` |
| Last TPS measurement | `/dev/shm/last_tps` |
| API key cache | `/dev/shm/tac_win_api_keys` (chmod 600, tmpfs) |

---

## Security

- Commands run as current user by default. Some maintenance and hardware paths
  may use `sudo -n` when available.
- API keys bridged from Windows are stored in `/dev/shm/tac_win_api_keys`
  (`chmod 600`, tmpfs — never hits disk)
- `commit_auto` (alias: `commit`) blocks sending git diffs to non-localhost LLM URLs
- `oc-llm-sync.sh` SHA256 is verified before sourcing
- Exec approval is required (configured in `~/.openclaw/exec-approvals.json`)

---

## Troubleshooting

### `tac-exec` command not found

```bash
which tac-exec                          # should be /home/wayne/.local/bin/tac-exec
ls -la ~/.local/bin/tac-exec           # check symlink
ls -la ~/ubuntu-console/bin/tac-exec  # check source
```

### Commands fail silently

```bash
tac-exec model status 2>&1 | cat       # redirect stderr
cat ~/.openclaw/logs/bash-errors.log | tail -20
```

### env.sh not loading all modules

```bash
bash -c 'source ~/ubuntu-console/env.sh && declare -f model' | head -5
```

### Hal can't run commands — check allowlist

```bash
jq '.agents.main.allowlist[] | select(.pattern | contains("tac-exec"))' \
  ~/.openclaw/exec-approvals.json
```

## Shared GPU — the investigator ownership lock

The GPU is shared with the `investigator` repo's pipeline, which takes a
cross-process **flock** for the whole duration of a local-model run. The lock
path mirrors `investigator/config/paths.py:gpu_lock_path()`:

```
$INVESTIGATOR_GPU_LOCK
else $INVESTIGATOR_PRODUCTION_OUTPUT/runtime/gpu.lock
else ~/investigator/production/runtime/gpu.lock
```

Check it before starting a model, running autotune, or cleaning up GPU
processes:

```bash
L="${INVESTIGATOR_GPU_LOCK:-${INVESTIGATOR_PRODUCTION_OUTPUT:-$HOME/investigator/production}/runtime/gpu.lock}"
if [[ -e "$L" ]] && ! flock -n "$L" -c true 2>/dev/null; then
    echo "GPU owned by another run — do not start anything on the card"
fi
```

Two traps, both learned the hard way (2026-09-15):

* `flock -n` **also fails when the path does not exist**, so a probe without an
  existence gate reads "cannot open the file" as "held" and refuses every run.
* The file's *contents* (the owning PID) are a diagnostic only; the **flock** is
  the authority, and the OS releases it automatically when the owner dies.

The console honours the lock in both CUDA-reap paths
(`11d-llm-gpu.sh::__llm_kill_cuda_llama_servers` and `bin/llama-gpu-clear.sh`),
and `run-autotune-batch.sh` halts up front when the card is held. **Never
`pkill -f llama-server`**: the Xe fleet serves the same binary name, so
`/proc/PID/exe` is the only safe discriminator.

## Conventions when working *in* this repo

* **Git hooks are tracked** in `tools/hooks/` and activated with
  `git config core.hooksPath <repo>/tools/hooks` (which `install.sh` sets).
  Never inline a check in `.git/hooks/` — it is not version-controlled, and an
  inlined copy of the shellcheck loop there drifted from `tools/lint.sh` on
  2026-09-15 when only one of the two copies of the flags was updated.
* **Lint:** `tools/lint.sh` in three modes — whole repo (default), `--staged`
  (what the pre-commit hook runs) and `--files F...` (an explicit list).
  The shellcheck flags live there and nowhere else. Do **not** add
  `# shellcheck disable=` directives: fix the cause — have the module declare
  what it consumes, and let `-x --source-path` resolve the source-following
  SC1090/SC1091 class.
* **Module versions:** `tools/check-module-versions.sh` examines `*.sh` files
  only (so `tools/hooks/*` is exempt) and enforces a bump only for files that
  already carry `# Module Version: N`; a brand-new file is taken as a baseline.
  Every `bin/*.sh` carries one. Bump it on ANY edit, or the commit is refused.
* **Docs:** `tools/docs-sync-check.sh` fails on stale module counts, loader
  version, or test totals — README must match the repo. Update `README.md` and
  `docs/inspection.md` when you change structure, counts or conventions.
* **Tests before a hand-back:** `bats tests/tactical-console-fast.bats` for
  quick feedback, then all `tests/unit/*.bats` plus `tests/tactical-console.bats`
  (386) and the integration suites.

← [Back to README](../README.md)

<!-- end of file -->
