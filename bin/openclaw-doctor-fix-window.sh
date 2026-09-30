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
# EXIT  0 window completed · 1 preflight failed, nothing stopped · 2 doctor --fix non-zero
#
# AI INSTRUCTION: Increment version on significant changes.
# Module Version: 1
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

stop_gateway || log "WARNING: the stop wrapper returned non-zero — verifying anyway"
log "gateway after stop: state=$(state_of)"
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
log "=== doctor --fix ${doctor_flags[*]:-}  (note: it restarts the Gateway itself at the end)"
"$OPENCLAW" doctor --fix "${doctor_flags[@]}"
doctor_rc=$?
log "=== doctor --fix exited rc=$doctor_rc"

log "=== doctor --lint"; "$OPENCLAW" doctor --lint
log "=== update status"; "$OPENCLAW" update status
log "=== window end (doctor rc=$doctor_rc; repair rc=$repair_rc)"

exit "$doctor_rc"
