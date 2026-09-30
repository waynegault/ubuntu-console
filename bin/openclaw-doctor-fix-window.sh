#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# openclaw-doctor-fix-window.sh — run `openclaw doctor --fix` in a REAL window.
# ==============================================================================
# WHY THIS EXISTS (measured 2026-09-30).
#   `openclaw doctor --fix` cannot enter maintenance while the Gateway owns
#   ~/.openclaw/state/openclaw.sqlite:
#       Doctor could not enter maintenance. GatewayStateOwnerContentionError: OpenClaw
#       state database is busy at …; … Stop the Gateway service and other OpenClaw
#       processes using this state, then run openclaw doctor --fix from an independent
#       shell.
#   A bare `systemctl --user stop` is NOT enough on this host: the graceful drain can exit
#   1, which trips OnFailure=openclaw-gateway-guard.service and revives the Gateway in
#   ~60 ms — measured, it flapped ~9x during the 2026.9.7 window. So the guard's own
#   dead-man switch ~/.openclaw/.gateway-hold is armed FIRST, and the stop goes through
#   the console's canonical wrapper (safe-stop-gateway.py) so it is VERIFIED, not assumed.
#
# ORDERING — the trap that cost two runs (measured 2026-09-30).
#   `doctor --fix` finishes by RESTARTING the Gateway ("Restarted systemd service ….
#   Gateway restarted and verified").  An `openclaw update repair` placed AFTER it
#   therefore re-hits the contention and records finalize:doctor=skipped — update_runs
#   rows 73 and 74 both did; row 75, run ALONE with the Gateway stopped, is the one that
#   completed.  Hence RUN_UPDATE_REPAIR=1 makes `update repair` run FIRST, off by default.
#
# USAGE
#   openclaw-doctor-fix-window.sh                  hold -> stop -> doctor --fix -> restore
#   DOCTOR_FIX_YES=1    also pass --yes (no TTY; the non-TTY equivalent of answering the
#                       interactive "update gateway service config? -> Yes")
#   RUN_UPDATE_REPAIR=1 run `openclaw update repair` FIRST (see ORDERING)
#   STOP_ONLY=1         arm the hold and STOP, then exit — use this to run `doctor --fix`
#                       by hand with its real prompts, then finish with RESTORE=1
#   RESTORE=1           clear the hold and start the Gateway (counterpart of STOP_ONLY)
#   HOLD_MAX_AGE_S=…    hold lifetime (default 3600; only STOP_ONLY needs it long)
#
#   DETACHED — use when the stop could take the invoking shell with it (the stop kills the
#   unit cgroup).  The unit supplies the env, so the script sources nothing:
#     systemd-run --user --unit=openclaw-doctor-fix --collect --property=Type=oneshot \
#       --property=TimeoutStartSec=3600 \
#       --property=EnvironmentFile=-/home/wayne/.openclaw/gateway.systemd.env \
#       /home/wayne/ubuntu-console/bin/openclaw-doctor-fix-window.sh
#
# EXIT  0 window completed · 1 the stop was refused or the Gateway could not be stopped, so
#       NOTHING was repaired · 2 doctor --fix non-zero · 3 doctor REPAIRED STATE but its own
#       61 s Gateway-readiness budget expired before the listener opened; this script then
#       waited for the Gateway itself and it is up (measured 2026-09-30: this host's startup
#       is ~102 s under load, so 3 is the normal outcome on a busy box)
#
# AI INSTRUCTION: Increment version on significant changes.
# Module Version: 3
#   v3 (2026-09-30): honour the safe-stop refusal (a DO NOT STOP used to be downgraded to a
#   warning, so doctor ran against a LIVE Gateway and failed with a misleading contention
#   error); exit codes now match this header (`exit "$doctor_rc"` returned 1 for a doctor
#   rc=1, which was indistinguishable from "refused, nothing stopped"); the post-window
#   `doctor --lint` and `update status` now run AFTER the Gateway is back, because running
#   them while the maintenance scope was still closing returned
#   "... read scope is closing or closed" for nearly every check; and a doctor rc caused
#   only by its readiness budget is reported as 3 rather than as a failed repair.
#   v2 (2026-09-30): add the repo-required `# end of file` marker. Its absence turned main
#   RED (CI run 36752500465, Fast Test Suite test 25: "hygiene: all scripts end with
#   # end of file marker"), so the file could not ship as committed in 5bc52634.
#   v1 (2026-09-30): first version, replacing the ad-hoc
#   ~/Backups/openclaw/scripts/doctor-maintenance-window-2026.9.7.sh.  Adds STOP_ONLY /
#   RESTORE modes for the interactive case and fixes that script's ordering trap
#   (update repair ran after doctor --fix and re-hit the contention).
set -uo pipefail

# Explicit PATH: a `systemd-run` transient unit gets only the default PATH — no Linuxbrew,
# no node — so `openclaw` would not resolve and the preflight would refuse the run. Measured
# 2026-09-30 on the first detached attempt ("FATAL preflight: --version failed — nothing
# stopped"), which is the preflight doing its job: nothing was stopped. Same shape as the
# self-check unit's `Environment=PATH=…`.
export PATH="/home/wayne/.openclaw/bin:/home/linuxbrew/.linuxbrew/opt/node@24/bin:/home/linuxbrew/.linuxbrew/bin:/home/wayne/.local/bin:/usr/local/bin:/usr/bin:/bin"

OPENCLAW="${OPENCLAW_BIN:-/home/linuxbrew/.linuxbrew/bin/openclaw}"
OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
UNIT="openclaw-gateway.service"
HOLD="$OPENCLAW_HOME/.gateway-hold"
SAFE_STOP="$OPENCLAW_HOME/workspace/scripts/safe-stop-gateway.py"
PY="$OPENCLAW_HOME/.venv/bin/python3"
HOLD_MAX_AGE_S="${HOLD_MAX_AGE_S:-3600}"

log() { printf '%s %s\n' "$(date -Is)" "$*"; }

# state_of — the unit's state, with no stderr suppression and no swallowed status: an
# assignment does not abort under `set -uo pipefail`, and is-active writes the state to
# stdout for every state including inactive/failed.
state_of() { systemctl --user is-active "$UNIT"; }

clear_hold() {
  rm -f "$HOLD"
  systemctl --user unset-environment OPENCLAW_GUARD_HOLD_MAX_AGE
}

start_gateway() {
  systemctl --user reset-failed "$UNIT"
  if [ "$(state_of)" != active ]; then
    systemctl --user start "$UNIT"
  fi
  local i
  for ((i = 0; i < 60; i++)); do
    [ "$(state_of)" = active ] && break
    sleep 5
  done
  log "gateway: state=$(state_of)"
}

arm_hold() {
  systemctl --user set-environment OPENCLAW_GUARD_HOLD_MAX_AGE="$HOLD_MAX_AGE_S"
  touch "$HOLD"
  log "hold armed at $HOLD (guard max age ${HOLD_MAX_AGE_S}s)"
}

stop_gateway() {
  if [ -x "$PY" ] && [ -f "$SAFE_STOP" ]; then
    log "stopping via the canonical wrapper (verified stop)"
    "$PY" "$SAFE_STOP" --yes --force
    return $?
  fi
  log "NOTE: $SAFE_STOP not found — falling back to a plain stop (the hold still applies)"
  systemctl --user stop "$UNIT"
}

# hold_fresh — the guard is the only thing that can undo the stop, so re-touch the switch
# for as long as this script is running (a hold older than the max age is IGNORED).
KEEP=""
start_hold_keeper() {
  ( while [ -e "$HOLD" ]; do touch "$HOLD"; sleep 60; done ) & KEEP=$!
}
stop_hold_keeper() { [ -n "$KEEP" ] && kill "$KEEP"; }

if [ "${RESTORE:-0}" = "1" ]; then
  log "=== RESTORE: clearing the hold and starting $UNIT"
  clear_hold
  start_gateway
  log "=== RESTORE done"
  exit 0
fi

restore() {
  stop_hold_keeper
  restore_done=1
  if [ "${STOP_ONLY:-0}" = "1" ]; then
    log "STOP_ONLY: leaving the Gateway DOWN and the hold ARMED."
    log "  run doctor --fix by hand now, then finish with:  RESTORE=1 $0"
    log "  (the hold is a dead-man switch: once it is older than ${HOLD_MAX_AGE_S}s the guard"
    log "   may start the Gateway again, so do not leave this for hours unwatched)"
    return 0
  fi
  log "RESTORE: clearing hold + guard env; ensuring $UNIT is up"
  clear_hold
  start_gateway
  log "RESTORE done: version=$("$OPENCLAW" --version)"
}

# --- preflight: prove the CLI runs BEFORE anything is stopped -----------------
if [ ! -x "$OPENCLAW" ]; then log "FATAL preflight: $OPENCLAW not executable — nothing stopped"; exit 1; fi
if ! "$OPENCLAW" --version; then log "FATAL preflight: --version failed — nothing stopped"; exit 1; fi
log "=== window start | version=$("$OPENCLAW" --version)"

arm_hold
start_hold_keeper
restore_done=0
trap 'if [ "$restore_done" = "0" ]; then restore; fi' EXIT

# The stop is a GATE, not a warning. safe-stop-gateway.py refuses a red pre-flight with exit 2
# and deliberately has no override for it; exit 1 is its "warned, and --force was not given"
# (this script always passes --force) and 4 is "the stop command itself failed". Downgrading
# any of those to a warning is what made doctor run against a LIVE Gateway and fail with
# "GatewayStateOwnerContentionError ... state database is busy" — an error that reads like a
# doctor/state defect and sends the operator to the wrong place (measured 2026-09-30). Exit 3
# is different: the unit DID go inactive, only the shutdown was not clean, and doctor can run.
stop_rc=0
stop_gateway || stop_rc=$?
case "$stop_rc" in
  0) : ;;
  3) log "NOTE: the stop verified $UNIT is down but the shutdown was not clean (rc=3); continuing." ;;
  *)
    log "FATAL: the stop was refused or failed (rc=$stop_rc) — nothing was stopped and doctor was NOT run."
    log "  A DO NOT STOP pre-flight verdict is not overridable (see safe-stop-gateway.py --help)."
    log "  Resolve the finding above (often load, or another process holding the state), then re-run."
    exit 1
    ;;
esac
log "gateway after stop: state=$(state_of)"
if [[ "$(state_of)" == active ]]; then
  log "FATAL: $UNIT is still active after the stop — doctor would be refused. Not running doctor."
  exit 1
fi
log "processes still holding the state (must be empty for doctor to enter maintenance):"
pgrep -af 'dist/index.js gateway'

if [ "${STOP_ONLY:-0}" = "1" ]; then
  restore
  exit 0
fi

# The gateway env (~/.openclaw/gateway.systemd.env) is deliberately NOT sourced here: a `.`
# of a runtime path is an unreachable source that gates the repo's shellcheck pass, and
# suppressing it would hide the reason. Whoever invokes this supplies the env — the
# DETACHED form passes it as a systemd EnvironmentFile (see USAGE), and an interactive
# shell already has it.

repair_rc="skipped (RUN_UPDATE_REPAIR=1 to include it)"
if [ "${RUN_UPDATE_REPAIR:-0}" = "1" ]; then
  log "=== update repair (opt-in; FIRST, while the Gateway is down)"
  "$OPENCLAW" update repair
  repair_rc=$?
  log "=== update repair exited rc=$repair_rc"
fi

doctor_flags=()
[ "${DOCTOR_FIX_YES:-0}" = "1" ] && doctor_flags+=(--yes)
DOCTOR_LOG="$OPENCLAW_HOME/logs/doctor-fix-window-$(date +%Y%m%d-%H%M%S).log"
log "=== doctor --fix ${doctor_flags[*]:-}  (note: it restarts the Gateway itself at the end)"
log "    full output: $DOCTOR_LOG"
# Capture as well as stream: doctor's own words are the only way to tell a failed repair from
# its too-short readiness budget — the exit code alone cannot (both are rc=1).
"$OPENCLAW" doctor --fix "${doctor_flags[@]}" 2>&1 | tee "$DOCTOR_LOG"
doctor_rc="${PIPESTATUS[0]}"
log "=== doctor --fix exited rc=$doctor_rc"

# doctor repairs the state and THEN restarts the Gateway itself, waiting only a fixed 61 s for
# the listener. Under load this host's startup is ~102 s, so doctor reports failure after a
# SUCCESSFUL repair: "Doctor repaired state, but the managed Gateway did not become ready:
# Readiness budget exhausted after 61s". That is a timing miss, not a repair failure, so it is
# classified separately; `restore` below waits for the Gateway itself (60 x 5 s) and exit 3 is
# only returned if the Gateway really is up.
doctor_note=""
if [[ "$doctor_rc" != 0 ]] \
   && grep -q "Doctor repaired state" "$DOCTOR_LOG" \
   && grep -q "Readiness budget exhausted" "$DOCTOR_LOG"; then
  doctor_note="state-repaired;doctor-readiness-budget-expired"
  log "NOTE: doctor reports a SUCCESSFUL repair — only its own Gateway-readiness check timed out."
fi

# Leave the window FIRST, then run the read-only post-window checks: while the maintenance
# scope is still closing they report "... read scope is closing or closed" for nearly every
# check, which is not a verdict (measured 2026-09-30).
restore

log "=== doctor --lint (post-window; informational)"
"$OPENCLAW" doctor --lint
log "=== update status"
"$OPENCLAW" update status
log "=== window end (doctor rc=$doctor_rc; ${doctor_note:-doctor-clean}; repair rc=$repair_rc)"

if [[ "$doctor_rc" == 0 ]]; then
  exit 0
fi
if [[ -n "$doctor_note" ]]; then
  if [[ "$(state_of)" == active ]]; then
    exit 3  # doctor's repair SUCCEEDED; only its own readiness budget expired — the Gateway is up
  fi
  log "NOTE: the Gateway is NOT active after the restore — this is a failed window, not a timing miss."
fi
exit 2  # doctor --fix itself exited non-zero (see the window log it was captured to)
# end of file
