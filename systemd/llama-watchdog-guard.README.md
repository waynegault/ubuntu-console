# Supervision-of-the-supervisor: llama-watchdog re-arm guard

**Status: INSTALLED 2026-09-21 09:13 BST** (Wayne approved the systemd/timer change in-session).

## Install layout

| Piece | Installed at |
|---|---|
| Guard script | `~/ubuntu-console/bin/llama-watchdog-guard.sh`, symlinked to `~/.local/bin/llama-watchdog-guard.sh` |
| Units | `~/ubuntu-console/systemd/llama-watchdog-guard.{service,timer}` and `~/.config/systemd/user/` |
| Timer | `OnBootSec=3min`, `OnUnitActiveSec=5min` — verified next fire 09:19:00, manual run `ExecMainStatus=0` (no-op while supervision is healthy) |

## The problem, with the attribution corrected

The llama lane supervisor `llama-watchdog.timer` can be left **stopped with nothing reporting it**.

My W39 review named `investigator-screen.service` as the actor. **That was wrong** — no such unit exists (`systemctl --user list-units` shows only `investigator-absence-rate.{service,timer}`). The real actor is the **model-selection bench**: `investigator/scripts/bench_shared/msb/`, through `pipeline/gpu/_exclusive.py:GpuExclusivityClaim`.

What the claim already does (so the fix is *not* "add a restore"):

- Stops `CLAIMABLE_UNITS` = `llama-watchdog.timer` + the CUDA lane units while it owns the GPU flock.
- `release()` restarts every stopped unit in reverse, then drops the flock — and it runs on **normal exit and on SIGINT/SIGTERM** (`install_signal_handlers`, added 2026-09-17 because "a terminated bench left `llama-watchdog.timer` stopped").
- A 15 s defender thread re-stops anything that starts mid-run.

What is **still** uncovered: a **hard kill** — SIGKILL, OOM killer, `wsl --shutdown`, a crash. `release()` never runs, and the kernel drops the flock with the process, so the box is left with the timer stopped, no claim held, and no alert. Observed windows on 2026-09-19: **~4 h** (10:49→14:48) and **~7.5 h** (14:50→22:17). While that holds, all four lanes are unwatched.

Adding more restore code cannot fix an uncatchable signal. The missing layer is the **detector**, which is what this guard adds.

## Why it cannot fight the bench

`pipeline/gpu/_exclusive.py` holds an exclusive `flock(2)` on `production/runtime/gpu.lock` for as long as a run owns the GPU. A **hard kill drops that flock automatically** (fd closed by the kernel), and a live bench still holds it. So "timer inactive + flock free" is exactly "supervision was lost, and no bench is legitimately responsible". "Timer inactive + flock held" is a deliberate bench stop and the guard exits without touching anything.

The flock test is non-blocking and read-only in effect (`flock -n "$LOCK" -c true`) — it takes and immediately releases the lock, never truncates, never creates side effects.

## Opt-out and alert sink

- Opt-out: `touch /dev/shm/llama-watchdog-guard.pause` suspends the guard for a deliberate, non-bench stop. `rm` it to resume.
- Alert sink: appends `life/alerts/supervision-stall.json`. **Confirmed 2026-09-21:** the `daily-digest` job reads `/home/wayne/.openclaw/life/alerts/`, so a `supervision_stall` row is picked up by the next 09:00 digest. No change needed.
- Two ticks, not one — deliberate, to avoid flapping on a single 5 min window (10 min detection latency).

## Residual / not yet proven

- The hard-kill acceptance test (**2 strikes → re-arm**) has not been exercised in production: it needs the timer to be stopped with no flock held, which is the very condition being protected. Verify on the next real hard kill, or reproduce deliberately with the lane quiet.
