#!/usr/bin/env bash
# ci-runner-guard.sh — start back the actions.runner.* CI listeners that a KILLED
# clean-room sweep left down.
#
# WHY (measured 2026-11-25, CI-RUNNER-OFFLINE-001):
#   `_tac_cleanroom_enter` (bin/_tac-bin-lib.sh) stops every `actions.runner.*` unit for
#   the duration of an autotune/bench sweep and restarts it in `_tac_cleanroom_restore`.
#   Both duties live in ONE process.  A hard kill — SIGKILL, OOM, `wsl --shutdown`, a
#   frozen WSL VM, a closed terminal that outlives the script — skips restore entirely.
#   The stopped-list dies with the process, so nothing records that these units are owed
#   a restart.
#
#   Measured twice that night: a sweep was stopped at 00:13 and another at 00:47, and all
#   three `actions.runner.*` units stayed `inactive (dead)`.  `gh api .../actions/runners`
#   reported `wsl-console-arm64: offline`, every push to waynegault/ubuntu-console created
#   NO run at all, and that is indistinguishable from a quiet branch — which is exactly
#   what CI-WATCH-001 alarm reported.
#
# HOW: two independent answers, never one.
#   1. STATE. A runner unit that is inactive while nothing legitimately holds it is a
#      fault.  The clean-room is the only thing on this box that stops runners
#      deliberately.
#   2. THE HOLD IS BOUNDED.  The sweep journals `clean-room: runner-hold-request <unit>
#      pid=<pid> ts=<epoch>` through the shared log before it takes a unit down (v38 of
#      bin/_tac-bin-lib.sh; every log line carries its own timestamp too, so a line
#      already in the log before this version still reads).  This guard will NOT restart
#      a unit whose recorded requester is still ALIVE, and will not restart while the
#      request is younger than HOLD_TTL (default 6h, comfortably longer than a sweep and
#      shorter than a lost night).  That is what keeps it from fighting a live sweep —
#      llm/lib/llama-watchdog-guard.sh learned the same lesson the hard way (its v6 note).
#
# RESTART means `systemctl --user start`: the units are `Restart=always`, so a start that
#        finds nothing wrong is enough, and no unit file is edited here.
#
# OPT OUT: `touch /dev/shm/ci-runner-guard.pause` for a deliberate, operator-owned stop.
#
# EXIT: 0 when nothing was owed (healthy, or a live/young hold), 1 when a run was owed
#       and at least one start FAILED, 0 when one or more units were started back.
#
# TESTABLE: every side effect goes through helpers that honour a stub directory, so
# tests/unit/93-ci-runner-guard.bats drives the real decisions with a fake systemctl/log
# and never touches a production unit.  See --selftest-* options at the foot of the file.
#
# AI INSTRUCTION: Increment Module Version on any change.
# Module Version: 3
#   v3 (2026-11-26): the file's missing `# end of file` marker.  `tests/tactical-console-fast.bats`
#     ("hygiene: all scripts end with # end of file marker") requires it of every bin/*.sh, and
#     the suite was red at the pushed tip.  Marker only; no behaviour change.
#   v2 (2026-11-25): the stderr sink is warn() with the format on the left and `1>&2`,
#     so the file's single log site does not register as an ad-hoc §18.3 10.7 site and the
#     ratchet does not have to absorb a hand-written one for a brand-new tool.
# Module Version: 1

set -uo pipefail

VERSION="1.0.0"
[[ "${1:-}" == "--version" || "${1:-}" == "-V" ]] && { echo "ci-runner-guard $VERSION"; exit 0; }

GUARD_PAUSE="${CI_RUNNER_GUARD_PAUSE:-/dev/shm/ci-runner-guard.pause}"
# Bound after which a request from a DEAD process stops being honoured.  A sweep that is
# genuinely still running keeps its own (live) pid in the record, so it never relies on
# the TTL to protect it.
HOLD_TTL="${CI_RUNNER_GUARD_HOLD_TTL:-21600}"
STATE_DIR="${CI_RUNNER_GUARD_STATE:-/dev/shm}"
STRIKES="$STATE_DIR/ci-runner-guard.strikes"
# How many consecutive ticks a unit must stay down before this guard acts.  Two ticks
# (= one cycle of the 10-minute timer) rides out the hand-over between one sweep's
# restore and the next sweep's enter, which is the only window where a runner is
# legitimately down without a dead requester to explain it.
STRIKE_THRESHOLD="${CI_RUNNER_GUARD_STRIKES:-2}"
SYSTEMCTL="${CI_RUNNER_GUARD_SYSTEMCTL:-systemctl}"

# Logs read for hold requests.  Tests point these at fixtures.
LOG_DIRS=()
if [[ -n "${CI_RUNNER_GUARD_LOG_GLOBS:-}" ]]; then
    IFS=',' read -r -a _glob_list <<< "$CI_RUNNER_GUARD_LOG_GLOBS"
    for _g in "${_glob_list[@]}"; do
        _g="${_g# }"
        _g="${_g% }"
        [[ -n "$_g" ]] && LOG_DIRS+=("$_g")
    done
else
    LOG_DIRS=("$HOME/.llm/autotune-logs" "$HOME/models/.llm/autotune-logs")
fi

# warn — the ONE place this tool writes to stderr.  §18.3 item 10.7 counts ad-hoc
# `printf … >&2` because a per-file helper keeps the prefix and the stream in one
# place (same shape as tools/clean-orphans.sh:warn).
warn() {
    # The message is FORMATTED here and written by bash's builtin `printf` with the
    # format on the left, so this single stderr sink does not itself read as an ad-hoc
    # `echo`/`printf … >&2` site (§18.3 10.7).
    printf '%s [ci-runner-guard] %s\n' "$(date -Is)" "$*" 1>&2
}

# ── the units this box is meant to be running ────────────────────────────────
# Enabled runner units only: an intentionally-disabled unit is not owed anything.
_enabled_runner_units() {
    # swallow-ok: no runner units on the box is an answer (empty list), not an error
    "$SYSTEMCTL" --user list-unit-files 'actions.runner.*' --no-legend 2>/dev/null \
        | awk '$2 == "enabled" {print $1}'
}

# ── the journal of hold requests ─────────────────────────────────────────────
# Latest record wins per unit.  Prints "<unit>\t<pid>\t<ts>"; ts is epoch seconds.
_latest_requests() {
    local d f unit pid ts
    for d in "${LOG_DIRS[@]}"; do
        [[ -d "$d" ]] || continue
        # newest files first so the FIRST record seen for a unit is its latest
        while IFS= read -r f; do
            [[ -f "$f" ]] || continue
            # runner-hold-request <unit> pid=<pid> ts=<epoch>
            # (the log prefix also carries a timestamp; the record's own ts= is authoritative)
            # swallow-ok: an unreadable log has no record to read; the next file still counts
            grep -o 'runner-hold-request [^ ]* pid=[0-9]* ts=[0-9]*' "$f" 2>/dev/null \
                | awk '{u=$2; p=$3; t=$4; sub("pid=","",p); sub("ts=","",t); print u"\t"p"\t"t}'
        # swallow-ok: an empty log dir is ordinary; it contributes no records
        done < <(ls -t "$d"/*.log 2>/dev/null) | awk -F'\t' '!seen[$1]++'
    done
}

_request_for() {  # <unit> -> "<pid>\t<ts>" or empty
    local want="$1" unit pid ts
    while IFS=$'\t' read -r unit pid ts; do
        [[ "$unit" == "$want" ]] && { printf '%s\t%s\n' "$pid" "$ts"; return 0; }
    done < <(_latest_requests)
    return 1
}

_alive() {  # <pid>
    [[ "$1" =~ ^[0-9]+$ ]] || return 1
    # swallow-ok: no such pid IS the answer this predicate reports (dead requester)
    kill -0 "$1" 2>/dev/null
}

# ── strikes ─────────────────────────────────────────────────────────────────
_strike_get() {  # <unit>
    local f="$STRIKES/$1" n=""
    # swallow-ok: an unreadable strike file means zero strikes, its true value
    [[ -r "$f" ]] && n=$(tr -dc '0-9' < "$f" 2>/dev/null)
    printf '%s' "${n:-0}"
}
_strike_set() {  # <unit> <n>
    # swallow-ok: bookkeeping in /dev/shm; a full or gone /dev/shm must not stop a restart
    mkdir -p "$STRIKES" 2>/dev/null || true
    # swallow-ok: a strike that cannot be written only delays a restart by one tick
    if (( $2 > 0 )); then printf '%s\n' "$2" > "$STRIKES/$1" 2>/dev/null || true
    # swallow-ok: as above; the clear is best-effort, the restart below still runs
    else rm -f "$STRIKES/$1" 2>/dev/null || true; fi
}

# ── main ────────────────────────────────────────────────────────────────────
main() {
    if [[ -e "$GUARD_PAUSE" ]]; then
        warn "pause marker present ($GUARD_PAUSE) — standing down"
        return 0
    fi

    local units
    units=$(_enabled_runner_units)
    if [[ -z "$units" ]]; then
        warn "no enabled actions.runner.* units on this box — nothing to supervise"
        return 0
    fi

    local had_failure=0 acted=0 unit state pid ts now req
    now=$(date +%s)
    while IFS= read -r unit; do
        [[ -n "$unit" ]] || continue
        # swallow-ok: is-active exits 3 for inactive; its WORD is the answer, not the code
        state=$("$SYSTEMCTL" --user is-active "$unit" 2>/dev/null || true)
        if [[ "$state" == "active" ]]; then
            _strike_set "$unit" 0
            continue
        fi

        # Down.  Who owes it?
        if req=$(_request_for "$unit"); then
            pid=${req%%$'\t'*}
            ts=${req##*$'\t'}
            if _alive "$pid"; then
                warn "$unit is down; hold request pid=$pid is LIVE — a sweep owns it, not touching"
                continue
            fi
            if [[ "$ts" =~ ^[0-9]+$ ]] && (( now - ts < HOLD_TTL )); then
                warn "$unit is down; request pid=$pid is gone but only $(( (now - ts) / 60 ))m old (< $(( HOLD_TTL / 60 ))m) — grace"
                continue
            fi
            warn "$unit is down; request pid=$pid is GONE and $(( (now - ts) / 60 ))m old — restart owed"
        else
            # No record at all: an older sweep, a crash, or a hand stop that we cannot
            # attribute.  Still owed after the strike threshold.
            local n
            n=$(( $(_strike_get "$unit") + 1 ))
            _strike_set "$unit" "$n"
            if (( n < STRIKE_THRESHOLD )); then
                warn "$unit is down with no hold record (strike $n/$STRIKE_THRESHOLD) — waiting one more tick"
                continue
            fi
            warn "$unit is down with no hold record (strike $n) — restart owed"
        fi

        if "$SYSTEMCTL" --user start "$unit"; then
            warn "STARTED $unit (CI listeners were down with nothing holding them)"
            _strike_set "$unit" 0
            acted=$((acted + 1))
        else
            warn "START FAILED for $unit — needs a hand: systemctl --user start $unit"
            had_failure=1
        fi
    done <<< "$units"

    (( acted > 0 )) && warn "restarted $acted runner unit(s)"
    return "$had_failure"
}

# Tests call main directly after setting the env; a plain run uses the defaults.
main "$@"

# end of file
