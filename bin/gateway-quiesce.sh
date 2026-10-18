#!/usr/bin/env bash
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 3
#   v3 (2026-10-18): same change, made §18.3-clean — a comment above each function (9.5), the
#   usage line carries its exit-code comment (9.7), and no hand-rolled `>&2` (10.7): the usage
#   text goes to stdout, which the `wsl.exe` hop's caller already merges into one log.
#   v2 (2026-10-18): the UP half (--ensure-running), so a gateway that was already down before
#   the restart is started again after it — `systemctl --user start`, idempotent, never restart.
# ─────────────────────────────────────────────────────────────────────────────
# gateway-quiesce.sh — the gateway's two halves across a distro restart:
#
#   --quiesce (default)   stop it and WAIT for it to go inactive, before the VM dies
#   --ensure-running      START it after the VM returns, even if it was down before
#
# WHY THE DOWN HALF (measured 2026-10-17).  bin/wsl-restart.sh reboots the distro with
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
# WHY THE UP HALF (ordered 2026-10-18).  Stopping it before the teardown answers the
# mid-drain kill, but nothing put it BACK: `enabled` is not `running`, and a gateway
# that was ALREADY down before the restart (a failed start, an update window, a hand
# stop) stays down, because the only thing that normally starts it is the boot itself.
# `systemctl --user start` is idempotent, so this is a no-op when the boot already
# brought it up and a real start when it did not — and it is `start`, never `restart`,
# so it can never stack a second stop on a gateway that is merely still starting.
#
# NEITHER HALF GATES THE RESTART: exit 0 = done, exit 1 = the bound expired.  The
# wrapper logs either and proceeds — a restart that will not happen is worse than a
# gateway that starts uncleanly.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

# A `wsl.exe -d … -- <cmd>` hop is not a login shell, so the user manager's
# runtime directory may be unset — and without it `systemctl --user` cannot reach
# the bus at all.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

UNIT="${TAC_QUIESCE_UNIT:-openclaw-gateway.service}"
BOUND="${TAC_QUIESCE_BOUND_S:-120}"

# quiesce — the DOWN half: stop the unit and wait, bounded, for it to go inactive.
quiesce() {
    if ! systemctl --user is-active --quiet "$UNIT"; then
        printf 'quiesce: %s is not running — nothing to stop\n' "$UNIT"
        return 0
    fi

    local _start=$SECONDS
    printf 'quiesce: stopping %s (bound %ss) so the next boot starts it cleanly\n' "$UNIT" "$BOUND"
    systemctl --user stop "$UNIT"

    local _deadline=$(( SECONDS + BOUND ))
    while (( SECONDS < _deadline )); do
        if ! systemctl --user is-active --quiet "$UNIT"; then
            printf 'quiesce: %s stopped in %ss\n' "$UNIT" "$(( SECONDS - _start ))"
            return 0
        fi
        sleep 2
    done

    printf 'quiesce: WARN %s still active after %ss — the restart proceeds anyway\n' "$UNIT" "$BOUND"
    return 1
}

# ensure_running — the UP half: start the unit if it is not running, idempotently.
ensure_running() {
    # The user manager itself may not answer yet: step 3 only proves the DISTRO is up,
    # and the unit fleet was measured ~44s behind the boot (02:49:56 boot, node 02:50:19,
    # gateway 02:50:40).  So this is a bounded retry, not one call.
    if systemctl --user is-active --quiet "$UNIT"; then
        printf 'ensure: %s already running — start is a no-op\n' "$UNIT"
        return 0
    fi

    local _start=$SECONDS _tries=0
    printf 'ensure: %s is NOT running — starting it (bound %ss)\n' "$UNIT" "$BOUND"
    local _deadline=$(( SECONDS + BOUND ))
    while (( SECONDS < _deadline )); do
        _tries=$(( _tries + 1 ))
        if systemctl --user start "$UNIT"; then
            printf 'ensure: start accepted after %ss (%s tries) — %s\n' \
                "$(( SECONDS - _start ))" "$_tries" "$(systemctl --user is-active "$UNIT" 2>&1)"
            return 0
        fi
        sleep 3
    done

    printf 'ensure: WARN could not start %s within %ss (%s tries) — the wrapper proceeds\n' \
        "$UNIT" "$BOUND" "$_tries"
    return 1
}

# A usage error reports on stdout with exit 2 — distinct from 1, which means a bound expired.
# This helper is invoked through a `wsl.exe -- <cmd>` hop whose caller merges both streams into
# one log, so hand-rolling stderr here would add nothing (item 10.7 asks for a helper instead).
case "${1:-}" in
    ""|--quiesce)     quiesce ;;
    --ensure-running) ensure_running ;;
    *) printf 'usage: %s [--quiesce|--ensure-running]\n' "$0"; exit 2 ;;  # usage error: 2, not 1
esac

# end of file
