# Workboard — model bench failure investigation (2026-06-29)

## Card 1 — `cleanup_gpu` failure silently swallowed

**File:** `scripts/autotune-model.sh:486`
**Severity:** High
**Status:** Open

`cleanup_gpu >/dev/null 2>&1 || true` discards the exit code. If port 8081
is still occupied after the 20s wait loop, the script exits 0 with the server
potentially still alive.

**Fix:** Replace `|| true` with at minimum a warning. Retry once; if still
failing, `exit 1` so the bench's autotune-failure path takes over (which runs
`clear_vram.sh`).

---

## Card 2 — `clear_vram.sh` missing between autotune success and bench

**File:** `scripts/11-llm-manager.sh` — `__model_bench`, ~3944 vs ~3958
**Severity:** High
**Status:** Open

Autotune-failure path calls `clear_vram.sh` + `__model_stop` +
`__gpu_clear_stale_processes`. Autotune-success path calls none of those
— jumps straight to `__bench_run_with_timeout`.

**Fix:** Add `clear_vram.sh` between autotune completion and bench on
the success path.

---

## Card 3 — ngl mismatch: autotune tunes 999, bench runs 24

**File:** `scripts/autotune-model.sh:200` vs `scripts/11-llm-manager.sh:2768`
**Severity:** High
**Status:** Open

Autotune discovers ctx/batch with all layers on GPU (999), but the bench
runs with only 24 layers. Different VRAM profiles.

**Fix:** Autotune should resolve ngl using the same logic as `__model_use`.

---

## Card 4 — Watchdog and autotune share port 8081

**File:** `bin/llama-watchdog.sh:28` and `scripts/autotune-model.sh:199`
**Severity:** Medium
**Status:** Open

Both bind to port 8081. `__model_bench` stops the timer but not a
currently-running service instance.

**Fix:** Different port, stop service before autotune, or skip watchdog
when bench lock file exists.

---

## Card 5 — `burn()` auto-recover has no step-down

**File:** `scripts/11-llm-manager.sh:5561`
**Severity:** Medium
**Status:** Open

Auto-recover restarts with the exact same params that caused the crash.
No ctx/batch reduction on repeated failures.

**Fix:** Halve ctx or batch on each successive recovery attempt.

---

## Card 6 — 0-tps results in binary probe not classified as OOM

**File:** `scripts/autotune-model.sh:278-283` and `:412-416`
**Severity:** Medium
**Status:** Open

Tests 9–12 returned "0 tps" not "OOM". The `tps <= 0` bc guard should
catch this but apparently has an edge case.

**Fix:** Add explicit string comparison before the bc test. Log raw output.

---

## Card 7 — `__tac_cleanup_stale_locks` called twice

**File:** `scripts/11-llm-manager.sh:3652` and `:3726`
**Severity:** Low
**Status:** Open

Redundant second call after trap setup.

**Fix:** Remove the second call.

---

## Card 8 — `__bench_run_with_timeout` is a debugging black hole

**File:** `scripts/11-llm-manager.sh:3468-3628`
**Severity:** Low
**Status:** Open

40-line heredoc passed to `setsid bash -lc` with inline traps and PID
tracking. Zero visibility when the subprocess silently exits 1.

**Fix:** Extract to standalone script.

---

## Card 9 — `llm-json-output.bats` belongs in investigator

**Severity:** Low
**Status:** ✅ Done (2026-06-29)

Moved to `~/investigator/tests/`, removed from bridge, pytest.ini, run-tests.sh.
Docs updated with correct test counts.

---

## Card 10 — Registry write paths missing safety guards

**File:** `scripts/11-llm-manager.sh` (model scan, renumber, remove)
**Severity:** High
**Status:** ✅ Done (2026-06-29 — commit 37bf04b)

Three registry mutation paths (model scan, model renumber, model remove)
wrote directly without the `>= 2` line safety check. Fixed: all seven paths
now use tmp → guard → mv pattern.

---

## Card 11 — Pre-commit hook linting entire repo on every commit

**File:** `.git/hooks/pre-commit`
**Severity:** Medium
**Status:** ✅ Done (2026-06-29)

Was calling `scripts/18-lint.sh` which ran shellcheck on all ~24 scripts,
taking >30s and getting killed. Now only lints staged `.sh` files — <2s
for typical commits.

---

## Card 12 — BATS suites hanging in parallel

**File:** `tests/conftest.py` (new)
**Severity:** Medium
**Status:** ✅ Done (2026-06-29 — commit 948cc1b)

11 BATS suites running in parallel (VSCode default) caused 264 concurrent
shellcheck processes. Added `conftest.py` with `flock` serialization.
