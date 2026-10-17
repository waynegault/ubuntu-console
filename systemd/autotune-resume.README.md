# autotune-resume.service — the boot re-arm, and the two gates it does not open itself

**What it is.** A user unit that runs `bin/autotune-resume.sh` once per boot, so a WSL
restart does not silently end the tuning campaign. Measured 2026-10-15: a running chunk
is a child of the Qwen session's `cli.js` pair, which is a child of the VS Code window's
extension host — so it dies with the *client*, never mind `wsl --shutdown`, and nothing
re-armed it.

**Why a user unit and not the session.** The re-arm has to survive the thing it exists
for. A job launched from a chat session is a descendant of that window, so it cannot.
A user unit runs under the user manager instead — and since 2026-10-17 it is started by
`autotune-resume.timer` (`OnBootSec=2min`), not by `default.target`.

**Why a timer and not `WantedBy=default.target` (2026-10-17).** The service is a
`Type=oneshot` with `TimeoutStartSec=21600`, and a boot-time oneshot keeps the
`default.target` transaction open until it finishes. On 2026-10-17 that starved every
unit ordered `After=default.target`: `graphify-mcp-reload.timer` fired and its start job
sat `waiting` for over an hour (the investigator graph was served stale), and
`stray-root-entry-net.service` never started at all. "Once per boot" is now the timer's
job; the boot no longer waits for a six-hour campaign.

**Nothing happens until BOTH gates are opened, and both are deliberate:**

1. **Enable it** — `systemctl --user enable autotune-resume.timer` (the TIMER, never the
   service: the service is static, so enabling it is a no-op that reads like success).
   `install.sh` LINKS `systemd/*` into `~/.config/systemd/user/` and reloads; it does
   **not** enable user units (the `enable`+`start` loop in it is the `sudo` system set
   under `systemd/system/`). So shipping this file starts nothing.
2. **Write a plan** — `~/.local/bin/autotune-resume.sh --plan`.
   The scope is an owner decision (Wayne, 2026-10-13: the uncertified rows plus the
   flagged family, by **model file name**), so it is written to
   `` $TAC_STATE_DIR/autotune-resume.rows `` and reviewed, not re-derived at every boot.
   With no plan the unit exits 0 and says so — a boot that does nothing says that,
   rather than looking like a resume that failed.

**The plan is claimed once.** Before the run it is copied to `~/.llm/autotune-logs/`
and moved aside as `<plan>.claimed-<stamp>`, so a boot loop cannot re-tune rows it
already has and the operator can read exactly what ran. A row whose model file is
missing is dropped with a line (an unloadable row still burns CUDA cycles walking
`ctx`); if *nothing* is runnable the unit fails, keeps the plan, and names the count.

**The entry point is `bin/autotune-rows.sh`, never `scripts/run-autotune-batch.sh`.**
Only the wrapper takes the box lock (`bin/heavy-job`) and holds the CUDA lane down for
the whole run; this unit inherits that serialisation instead of adding a second lock.

**What it does NOT do.** It does not decide the scope (the plan does, and the plan's
rule is Wayne's ruling), and it does not restart WSL itself — it ARMS a restart through
`bin/wsl-restart.sh`, which owns the Windows side and the chunk gate.

## The loop (v2, 2026-10-15) — why a boot is not the end of the campaign

**v1 survived a restart but never caused one.** It `exec`d the chunk, so the script died
with it, and nothing re-derived the plan or armed a second restart. Measured the night
of 2026-10-15: a peer's ONE-SHOT restart fired at 07:30, the unit claimed its 13-row
plan, the chunk ran to the cycle-budget halt at 08:41 — and the campaign then stopped
with 11 rows left, because the only product of a halt was a printed suggestion. That is
the half Wayne's brief cared about, and it was not built. v2 closes it: the chunk runs as
a CHILD, its exit code is read, and a **budget** halt (exit 4) that SHRANK the remainder
re-derives the plan and arms the next restart.

**Four stops, each deliberate** — an unattended reboot loop is only safe if it cannot
spin doing nothing:

| stop | why |
|---|---|
| the boot did not SHRINK the remainder | a restart would re-run the rows that just ran |
| the remainder is EMPTY | the campaign is complete; nothing to resume |
| a CI job is executing on this box | a restart cancels it, and a cancelled run leaves `main` red here — the arm waits (bounded, 15 min by default) and then PAUSES rather than killing the job |
| `ARM_MAX` consecutive automatic restarts (8) | an absolute cap; `--plan` resets it, so a person chooses a new campaign |

Any of those exits **non-zero**, so the unit reads `failed` — that is the intended
signal (a person decides), not an alarm on expected state.

**A parked row is not a bug.** `PARKED_ROWS` in the script keeps rows out of every
derivation. It currently holds `MemSFT-Qwen3-Law-Memory-8B.Q2_K.gguf`, measured
2026-10-15: that row enters the batch at cycle 43 and leaves the boot spent at 63 — 20
of the boot's 60 cycles — inside Phase 4's filled-cache TPS floor descent, which
re-spawns a server once per ctx step and never clears the floor. It therefore stays
flagged in the registry and returns in every derivation, ending every boot in the same
place. Parked is not deleted: its row and columns are untouched.

**Knobs** (all overridable, all read once at start): `TAC_RESUME_ARM_MAX`,
`TAC_RESUME_ARM_DELAY` (minutes, default 3), `TAC_RESUME_CI_WAIT_S` /
`TAC_RESUME_CI_POLL_S`, `TAC_RESUME_RESTART_TOOL`, and `TAC_RESUME_CI_WORKERS_CMD` (a
command that prints the CI-worker count — the seam the suite drives instead of a runner).
