#!/usr/bin/env bash
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 2
# standby-awake.sh — the only thing that decides whether standby-keeper runs.
#   v2 (2026-11-05). A silent GPU verdict is logged with its exit code instead of a bare "gpu:";
#                    the timer-tick latency below is stated. No signal or decision changes.
#   v1 (2026-11-04). INSTALLED and LIVE; reached through this repo's bin/ symlink.
#
# WHY A SUPERVISOR AND NOT A FLAG. The keeper must be on for EVERY measurement, whoever started it:
# my campaign cells, the autotune engine (a separate systemd unit), or a one-off bench. A wrapper only
# protects the runners that use the wrapper, so the protector would be dark for the rows that matter
# most. This keys on EVIDENCE that a run is in progress instead of on who started it:
#   1. the exclusive-card marker every llama/bench runner holds while it owns the card
#      (/dev/shm/llama-watchdog-cuda.suspend — already read by llama-watchdog.sh,
#      lane-restore-watch.sh, autotune-rows.sh and bench-rows.sh, so this is a fourth reader of the
#      box's existing "card is owned" flag, not a new concept)
#   2. autotune-resume.service active (the engine holds the card for a whole chunk)
#   3. gpu-busy.sh reports a real, unsanctioned workload (covers a foreign or vLLM server)
#
# COST. Signals 1 and 2 are a stat() and a systemctl call, so the steady state is almost free. The GPU
# probe is several nvidia-smi calls, so it runs ONLY when the cheap signals are silent — which is
# exactly when the keeper state is about to change, so it is paid at transitions, not every tick.
#
# FAIL-SAFE DIRECTION. An unreadable probe keeps the keeper running: awake costs power, damped clocks
# cost a whole campaign of wrong numbers (see bin/standby-keeper.sh for the 3.3x measurement).
#
# LATENCY, MEASURED. The keeper starts on the next timer tick, so a run that begins just after one
# waits up to 30 s for protection. Measured 2026-11-05: marker created ~00:19:49Z, "START keeper
# because marker" logged 00:19:51Z (~2 s); removal stopped it 00:20:26Z, also one tick. The tick
# itself survives Modern Standby — 45 of 46 expected fires landed inside the 22:43:56-23:06:44Z
# standby window — so the wait is a scheduler delay, never a frozen clock.
#
# Known gap, stated rather than hidden: a measurement started with NONE of those three signals present
# will run on a damped card. Add a signal here rather than a flag at the call site.
set -u
export PATH="${PATH:-/usr/local/bin:/usr/bin:/bin}:/home/wayne/.local/bin:/usr/lib/wsl/lib"
MARKER=${STANDBY_AWAKE_MARKER:-/dev/shm/llama-watchdog-cuda.suspend}
LOG=${STANDBY_AWAKE_LOG:-/home/wayne/logs/campaign/standby-awake.log}
KEEPER=${STANDBY_AWAKE_KEEPER:-standby-keeper.service}
ENGINE=${STANDBY_AWAKE_ENGINE:-autotune-resume.service}
# One line per state CHANGE, appended; a per-tick log would be 2,880 lines a day of "nothing happened".
log(){ printf "%s %s\n" "$(date -u +%FT%TZ)" "$*" >> "$LOG"; }
why=""
[[ -e "$MARKER" ]] && why="marker"
# is-active prints the state on stdout and exits non-zero for an inactive unit, so stderr carries
# only "unit not found" — and an unknown unit must read as "not running a chunk".
# swallow-ok: the only text suppressed is systemd's "unit not found", not a failure of this script.
case "$(systemctl --user is-active "$ENGINE" 2>/dev/null)" in
  # Only a transitioning or active engine means a chunk is running. `failed`/`inactive` are the
  # ordinary between-chunk states, and `deactivating` has already released the card, so neither is
  # allowed to keep the keeper awake — no catch-all arm on purpose.
  active|activating|reloading) why="${why:+$why,}autotune" ;;
esac
# Same probe against the keeper itself; "absent" reads as not-active, which is the answer that makes
# this script start it rather than assume it is up.
# swallow-ok: suppresses systemd's "unit not found" only; the verdict itself comes from stdout.
now=$(systemctl --user is-active "$KEEPER" 2>/dev/null)
if [[ -z "$why" ]]; then
  out=$(gpu-busy.sh 2>&1); rc=$?
  if [[ "$rc" -ne 0 ]]; then
    if [[ -n "$out" ]]; then
      why="gpu:$(printf %s "$out" | tr "\n" " " | cut -c1-120)"
    else
      # A non-zero exit with no text is the fail-safe direction (hold the box awake), but it used to
      # log the reason as a bare "gpu:" — unreadable later (standby-awake.log, 2026-11-04T23:59:13Z).
      # Name the code so the entry says why an unknown workload kept the box up.
      why="gpu:gpu-busy.sh exited $rc with no output"
    fi
  fi
fi
if [[ -n "$why" ]]; then
  if [[ "$now" != "active" ]]; then
    if systemctl --user start "$KEEPER"; then log "START keeper because $why"; else log "FAILED to start keeper ($why)"; fi
  fi
else
  if [[ "$now" = "active" ]]; then
    if systemctl --user stop "$KEEPER"; then log "STOP keeper: no run in progress"; else log "FAILED to stop keeper"; fi
  fi
fi
exit 0

# end of file
