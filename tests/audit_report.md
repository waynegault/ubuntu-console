# Test Infrastructure Audit

Date: 2026-06-23

## Framework

- **Primary test runner:** pytest (configured via `pytest.ini`)
- **Test types:**
  - Python unit tests: `test_*.py` files in `tests/`
  - Shell BATS tests: `.bats` files in `tests/`, `tests/unit/`, `tests/integration/`
- **BATS bridge:** `test_bats_bridge.py` parametrizes all `.bats` files via pytest markers

## Test Files

| File | Type | Lines | Status |
|---|---|---|---|
| `test_bats_bridge.py` | Python/pytest | ~60 | ✅ Active — parametrizes all BATS suites |
| `test_kgraph.py` | Python/unittest | ~190 | ✅ Active — tests the kgraph package module functions |
| `test_model_autotune.py` | Python/unittest | ~280 | ✅ Active — tests pure-logic functions in model-autotune.py |
| `tactical-console.bats` | BATS (full) | 2918 | ✅ Active — full behavioural suite (~473 tests) |
| `tactical-console-fast.bats` | BATS (fast) | 424 | ✅ Active — static analysis only, no profile sourcing |
| `unit/01-refresh-keys.bats` | BATS (unit) | 69 | ✅ Active |
| `unit/02-so-startup.bats` | BATS (unit) | 65 | ✅ Active |
| `integration/01-maintenance.bats` | BATS | 159 | ⚠️ Integration — non-hermetic |
| `integration/02-model-lifecycle.bats` | BATS | 346 | ⚠️ Integration |
| `integration/03-backup-restore.bats` | BATS | 112 | ⚠️ Integration |
| `integration/04-watchdog.bats` | BATS | 269 | ⚠️ Integration |
| `integration/05-refresh-keys.bats` | BATS | 96 | ⚠️ Integration |
| `integration/e2e-bench-autotune.bats` | BATS | 322 | ⚠️ Integration — long-running |

## Stale / Orphaned Files

- `tests/__pycache__/` — cache artifacts (harmless, gitignored)
- `tests/fixtures/golden/` — 16 fixture files (`.meta`, `.norm`, `.txt`). Some may be outdated but no easy way to verify without running the capture pipeline.

## Coverage Gaps

1. **No Python unit tests for `scripts/kgraph/` modules individually** — tests run against the kgraph package`, not the package modules directly
2. **No unit tests for `bin/llama-watchdog.sh`** — only integration tests in `04-watchdog.bats`
3. **No tests for `bin/tac_hostmetrics.sh`** — requires Windows host (WSL-only)
4. **No tests for `tools/*` scripts** — assumed ad-hoc/developer tools
5. **No tests for `scripts/build/`** — these are build artifacts, should not be tested directly

## Recommendations

1. Add direct pytest imports for `scripts/kgraph/*.py` modules (bypass the shim)
2. Remove `scripts/build/` and `scripts/openclaw_kgraph.egg-info/` — stale build artifacts from `uv build`
3. Mark `tests/fixtures/golden/` for audit — capture pipeline health unknown
4. Add shellcheck to CI pipeline if not already present (currently optional, checks skip when shellcheck not installed)
