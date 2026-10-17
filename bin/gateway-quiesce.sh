#!/usr/bin/env bash
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 1
# ─────────────────────────────────────────────────────────────────────────────
# gateway-quiesce.sh — stop the OpenClaw gateway and WAIT for it to go inactive,
# before the distro is torn down.
#
# WHY (measured 2026-10-17).  bin/wsl-restart.sh reboots the distro with
# `wsl.exe --shutdown`, which kills every process inside it.  A gateway stopped
# that way is killed MID-DRAIN:
#
#   12:41:21  [admission] closed: stop (SIGTERM)
#   12:41:22  [gateway] draining active work before stop … sessionAdmissions=1
#   12:41:48  (VM down — the drain never finished)
#   12:42:53  NEXT START REFUSED: "OpenClaw state at …/openclaw.sqlite is
#             undergoing offline maintenance; retry when it finishes."
#
# That refusal cost a second attempt and ~8 minutes before /health answered 200;
# the 10:48 restart cost three attempts and ~13 minutes the same way.  Stopping
# the unit first, and waiting until systemd reports it inactive, is what makes the
# next boot's start clean.
#
# NEVER GATES THE RESTART: exit 0 = quiesced, exit 1 = it did not stop inside the
# bound.  The wrapper logs either and proceeds — a restart that will not happen is
# worse than a gateway that starts uncleanly.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

# A `wsl.exe -d … -- <cmd>` hop is not a login shell, so the user manager's
# runtime directory may be unset — and without it `systemctl --user` cannot reach
# the bus at all.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

UNIT="${TAC_QUIESCE_UNIT:-openclaw-gateway.service}"
BOUND="${TAC_QUIESCE_BOUND_S:-120}"

if ! systemctl --user is-active --quiet "$UNIT"; then
    printf 'quiesce: %s is not running — nothing to stop\n' "$UNIT"
    exit 0
fi

_start=$SECONDS
printf 'quiesce: stopping %s (bound %ss) so the next boot starts it cleanly\n' "$UNIT" "$BOUND"
systemctl --user stop "$UNIT"

_deadline=$(( SECONDS + BOUND ))
while (( SECONDS < _deadline )); do
    if ! systemctl --user is-active --quiet "$UNIT"; then
        printf 'quiesce: %s stopped in %ss\n' "$UNIT" "$(( SECONDS - _start ))"
        exit 0
    fi
    sleep 2
done

printf 'quiesce: WARN %s still active after %ss — the restart proceeds anyway\n' "$UNIT" "$BOUND"
exit 1

# end of file
