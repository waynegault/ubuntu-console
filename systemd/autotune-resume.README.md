# autotune-resume.service — the boot re-arm, and the two gates it does not open itself

**What it is.** A user unit that runs `bin/autotune-resume.sh` once per boot, so a WSL
restart does not silently end the tuning campaign. Measured 2026-10-15: a running chunk
is a child of the Qwen session's `cli.js` pair, which is a child of the VS Code window's
extension host — so it dies with the *client*, never mind `wsl --shutdown`, and nothing
re-armed it.

**Why a user unit and not the session.** The re-arm has to survive the thing it exists
for. A job launched from a chat session is a descendant of that window, so it cannot.
`WantedBy=default.target` puts this one under the user manager instead.

**Nothing happens until BOTH gates are opened, and both are deliberate:**

1. **Enable it** — `systemctl --user enable --now autotune-resume.service`.
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

**What it does NOT do.** It does not restart WSL, and it does not decide the scope. For
the restart half see `bin/wsl-restart.sh` (`--schedule HH:MM` for the recurring form,
whose wrapper is gated on a chunk check so a busy box skips that night).
