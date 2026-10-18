#!/usr/bin/env bash
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 3
#   v1 (2026-10-18): the FLEET GATE — a distro reset must not cut live agent turns.
# ─────────────────────────────────────────────────────────────────────────────
# fleet-quiesce.sh — is the FLEET quiet enough to reset this distro?
#
#   --check [--quiet]     one reading; exit 0 clear, 1 busy, 2 unknown
#   --drain [--quiet]     poll to a bound; exit 0 clear, 1 still busy, 2 unknown
#
# WHY IT EXISTS (Wayne, 2026-10-18).  A WSL restart kills every process in the
# distro: the gateway, both CI runners, and every in-flight agent turn.  The
# restart path already gates on two things — a live autotune/bench chunk and a
# live CI job — and both gates are about MEASUREMENTS.  Neither asks whether an
# agent turn is mid-flight, so a turn that was three tool calls from a commit was
# cut off with no chance to checkpoint.  The observed cost is not hypothetical:
# six distro boots in one day took the Chief lane, 23 undeliverable messages and
# several interrupted runs with them.
#
# WHAT "LIVE" MEANS HERE.  The gateway already accounts for its own in-flight work
# and publishes it in `openclaw status --json` under
# `shutdownBudget.activeWork` (rootRequests, cronRuns, sessionMutations,
# terminalPersistence, lifecycleWrites).  A non-zero sum is work the gateway is
# holding right now; zero is a fleet with nothing in flight.  Reading the
# gateway's own accounting beats probing session files: the gateway is the thing
# that knows, and it is the thing a restart destroys.
#
# FAIL CLOSED.  A status probe that errors, times out, or returns no
# `activeWork` object is UNKNOWN (2), never "clear".  An unreadable fleet must not
# license a restart.
#
# THE DRAIN IS THE OPPORTUNITY.  `--drain` is not a poll-until-lucky loop: it is
# the window in which running turns can finish, commit, or write a handover.  It
# holds the restart, up to the bound, and then says "still busy" so the caller can
# skip rather than cut.  Nothing here messages the agents; a turn that is already
# running gets its time.
#
# ENV SEAMS (the suite drives each branch without a gateway):
#   TAC_FLEET_STATUS_CMD       command printing the status JSON  (default: openclaw status --json)
#   TAC_FLEET_BOUND_S          drain bound in seconds            (default: 330 = the gateway's own 325 s shutdown budget + 5)
#   TAC_FLEET_POLL_S           seconds between readings          (default: 20)
#   TAC_FLEET_PROBE_TIMEOUT_S  per-reading timeout               (default: 90)
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

# A `wsl.exe -d … -- <cmd>` hop is not a login shell: the user manager's runtime
# directory may be unset (gateway-quiesce.sh hit the same thing), and openclaw
# lives on linuxbrew's PATH rather than in the default one.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export HOME="${HOME:-/home/wayne}"
export PATH="$HOME/.local/bin:/home/linuxbrew/.linuxbrew/bin:$PATH"

# 330 s, not 600 (Wayne, 2026-10-18).  The gateway declares its OWN shutdown budget -
# `shutdownBudget.timeoutMs` in `openclaw status --json` - and on this box it is 325 s with
# a 10 s reserve.  Waiting longer than the platform's own answer protects turns the platform
# would itself abandon, and every extra minute is a minute the autotune campaign neither
# measures nor restarts.  A short bound is only safe because a skipped restart is now
# recoverable: autotune-resume.sh records the arm and its keeper timer re-arms a fire the
# wrapper dropped, so "skip" costs a retry instead of parking the campaign.
BOUND="${TAC_FLEET_BOUND_S:-330}"
POLL="${TAC_FLEET_POLL_S:-20}"
# 90 s, measured rather than guessed (2026-10-18 17:44).  `openclaw status --json` is a node
# process that reads live gateway state; it took 15.5 s at load 7 and was still running at 25 s
# under a spike, which the old bound KILLED - so the gate answered UNKNOWN and the wrapper
# skipped, correctly but for a reason that would have repeated: a routinely unanswerable gate
# turns into skip/churn now that the keeper re-arms a dropped fire.  UNKNOWN still fails closed;
# it just has to mean "the probe is broken", not "the box was busy".
PROBE_TIMEOUT="${TAC_FLEET_PROBE_TIMEOUT_S:-90}"
STATUS_CMD="${TAC_FLEET_STATUS_CMD:-openclaw status --json}"

QUIET=0
MODE=""

# read_active — one reading of the gateway's own accounting. Prints one line and
# returns 0 clear, 1 busy, 2 unknown. The counts are printed even when busy so a
# post-mortem log says WHAT held the restart, not merely that something did.
read_active() {
    local _json _rc
    # A failing probe IS the answer here - it becomes UNKNOWN below, which the caller
    # treats as "do not restart"; the message would add nothing the exit code does not.
    # swallow-ok: probe failure becomes UNKNOWN (fail closed), not a silent pass
    _json=$(timeout "$PROBE_TIMEOUT" bash -c "$STATUS_CMD" 2>/dev/null) || _rc=$?
    if [[ "${_rc:-0}" -ne 0 || -z "$_json" ]]; then
        printf 'UNKNOWN: the status probe failed (rc=%s) — not a clear\n' "${_rc:-0}"
        return 2
    fi
    # Parsed in python: the shape is the gateway's, and a shell match on a JSON
    # object silently reads a missing key as zero — the exact false-clear this
    # gate exists to prevent.
    local _out
    # No stderr suppression here on purpose: a traceback goes to the wrapper log, and
    # the "${_out:-...}" fallback below turns an empty parse into UNKNOWN (fail closed).
    _out=$(printf '%s' "$_json" | python3 -c '
import json, os, sys
try:
    d = json.load(sys.stdin)
except Exception as exc:
    print("UNKNOWN: unparseable status JSON (%s) - not a clear" % exc)
    sys.exit(2)
aw = (d.get("shutdownBudget") or {}).get("activeWork")
if not isinstance(aw, dict):
    print("UNKNOWN: status JSON has no shutdownBudget.activeWork - not a clear")
    sys.exit(2)
counts = {k: v for k, v in aw.items() if isinstance(v, int)}
total = sum(counts.values())
detail = " ".join("%s=%s" % (k, v) for k, v in sorted(counts.items()))
if total > 0:
    print("BUSY: %s in flight (%s) - the restart would cut them" % (total, detail))
    sys.exit(1)
print("CLEAR: no agent work in flight (%s)" % detail)
sys.exit(0)
')
    _rc=$?
    printf '%s\n' "${_out:-UNKNOWN: the status probe produced no reading — not a clear}"
    [[ -n "$_out" ]] || return 2
    return "$_rc"
}

# check — one reading, in the caller's own idiom.
check() {
    local _rc=0
    read_active || _rc=$?
    return "$_rc"
}

# drain — hold the restart while work is in flight, up to the bound. A clear
# reading returns immediately; an UNKNOWN reading also returns immediately (a
# probe that cannot answer will not answer differently in 20 seconds, and a
# restart must not be held on a broken instrument).
drain() {
    local _start=$SECONDS _rc=0 _last=""
    while :; do
        _last=$(read_active) && _rc=0 || _rc=$?
        (( QUIET )) || printf 'fleet gate: %s\n' "$_last"
        case "$_rc" in
            0) (( QUIET )) || printf 'fleet gate: CLEAR after %ss — safe to reset\n' "$(( SECONDS - _start ))"; return 0 ;;
            2) (( QUIET )) || printf 'fleet gate: UNKNOWN — the caller fails closed\n'; return 2 ;;
        esac
        if (( SECONDS - _start >= BOUND )); then
            (( QUIET )) || printf 'fleet gate: STILL BUSY after %ss (bound) — do not cut these turns\n' "$(( SECONDS - _start ))"
            return 1
        fi
        sleep "$POLL"
    done
}

# A usage error reports on stdout with exit 2 — distinct from 1, which means busy.
# This helper is invoked through a `wsl.exe -- <cmd>` hop whose caller merges both
# streams into one log, so hand-rolling stderr here would add nothing.
while (($#)); do
    case "$1" in
        --check) MODE="check" ;;
        --drain) MODE="drain" ;;
        --quiet) QUIET=1 ;;
        *) printf 'usage: %s [--check|--drain] [--quiet]\n' "$0"; exit 2 ;;  # usage error: 2
    esac
    shift
done

case "${MODE:-check}" in
    check) check ;;
    drain) drain ;;
esac

# end of file
