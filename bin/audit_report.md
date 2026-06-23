# bin/ and tools/ Audit

Date: 2026-06-23

## bin/ — Standalone scripts

| Script | Lines | Status | Notes |
|---|---|---|---|
| `llama-watchdog.sh` | 270 | ✅ Active | systemd-timer health checker for llama-server |
| `model-autotune.py` | 1180 | ✅ Active | llama-server parameter optimizer |
| `tac_hostmetrics.sh` | 191 | ✅ Active | WSL/Windows host metrics (requires typeperf.exe) |
| `tac-exec` | 108 | ✅ Active | Wrapper to source Tactical Console functions |
| `oc-gpu-status` | 6 | ⚠️ Thin wrapper | Delegates to `tac-exec gpu-status` — minimal overhead but all 5 `oc-*` wrappers have nearly identical structure |
| `oc-model-status` | 6 | ⚠️ Thin wrapper | Delegates to `tac-exec ocms` |
| `oc-model-switch` | 6 | ⚠️ Thin wrapper | Delegates to `tac-exec serve` |
| `oc-quick-diag` | 6 | ⚠️ Thin wrapper | Delegates to `tac-exec oc-diag` |
| `oc-wake` | 6 | ⚠️ Thin wrapper | Delegates to `tac-exec wake` |

### Findings

1. **Duplicated thin wrappers** — `oc-gpu-status`, `oc-model-status`, `oc-model-switch`, `oc-quick-diag`, `oc-wake` all follow the same 6-line pattern. They could be consolidated into a single dispatcher or symbolic links. However, the `oc-` prefix provides discoverability in `$PATH`, so replacing with a single script + symlinks is the pragmatic approach.
2. **`tac-exec` and `tac_hostmetrics.sh`** — These could be prefixed `oc-` for consistency, but that would break existing callers (systemd timers, MCP tools). Leave as-is.
3. **`model-autotune.py`** — Very large (1180 lines). Consider splitting into `bin/` entry point + `lib/` module. No dead code detected.
4. **`bin/__pycache__/`** — Stale `.pyc` build artifact. Should be removed (gitignored but present on disk).

## tools/ — Developer utilities

| Script | Lines | Status | Notes |
|---|---|---|---|
| `capture-golden-fixtures.sh` | 99 | ✅ Active | Records `.txt`/`.norm`/`.meta` golden files |
| `check-agent-use.sh` | 42 | ✅ Active | Verifies AI-generated code has attribution headers |
| `check-repo-boundaries.sh` | 41 | ✅ Active | Ensures WSL/Linux git config boundaries |
| `clean-orphans.sh` | 182 | ⚠️ Potentially stale | Kills orphaned bench infrastructure — references `bm_server.pid` which may be unused now |
| `import-windows-env.sh` | 112 | ✅ Active | WSL environment variable sync from Windows |
| `lint.sh` | 137 | ✅ Active | Pre-commit lint engine (bash -n + shellcheck) |
| `mirror-vault.sh` | 41 | ⚠️ Possibly stale | Syncs Obsidian vault to Windows — may duplicate functionality in `scripts/load-vault-env.sh` |
| `normalize-fixture.sh` | 132 | ✅ Active | Normalizes golden test fixture output |
| `run-tests.sh` | 89 | ✅ Active | Test runner wrapper |

### Findings

1. **`clean-orphans.sh`** — References `LLAMA_ROOT/build/bin/bm_server` PID file pattern. If `bm_server` is unused, the script is dead code.
2. **`mirror-vault.sh`** — Functionality may overlap with `scripts/load-vault-env.sh`. Worth investigating.
3. **No stale scripts** — All tools appear actively used or recently maintained.
4. **`lint.sh`** and `run-tests.sh` — These are the primary CI/dev tools and are actively maintained.

## Recommendations

1. **Consolidate thin wrappers**: Replace `oc-gpu-status`, `oc-model-status`, `oc-model-switch`, `oc-quick-diag`, `oc-wake` with symlinks to `tac-exec` (or a single `oc-bridge` script) since they all call `tac-exec <subcommand>`.
2. **Remove stale `.pyc`**: `bin/__pycache__/` is safe to delete.
3. **Audit `clean-orphans.sh`** for actual usage — if `bm_server` pattern is dead, the script can be removed.
4. **Audit `mirror-vault.sh`** for duplication with the TAC profile vault-loading scripts.
