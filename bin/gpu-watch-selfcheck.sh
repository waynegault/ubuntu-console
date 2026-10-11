#!/usr/bin/env bash
# gpu-watch-selfcheck.sh — is the GPU Passthrough Watch automation actually
# RUNNING, or merely configured?
#
# WHY THIS EXISTS (and why it was rewritten)
#   The GPU-passthrough watcher is only as good as the automation that fires it: if
#   the schedule stops firing, the watcher never runs, nothing is announced, and a
#   lost CUDA-card passthrough goes unnoticed — silent, which is the failure mode this
#   whole area exists to make loud.  This script is the one-shot check for that.
#
#   It lived outside version control at ~/.openclaw/bin/gpu-watch-selfcheck.sh (754
#   bytes) and keyed its verdict on `triggerEvalCount`.  OpenClaw stopped emitting that
#   field — measured 2026-09-23 on OpenClaw 2026.9.5: `openclaw automations get <id>
#   --json` carries no triggerEvalCount key at all, while the automation was healthy
#   (state.lastRunStatus "ok", a current lastRunAtMs, an advanced nextRunAtMs).  So the
#   old grep matched nothing and announced "no trigger evaluation recorded ... the
#   watcher would be blind" about a watcher that was running fine.  A FALSE ALARM on
#   the alarm channel is worse than no alarm: it is what teaches a reader to ignore the
#   channel.  Hence the rewrite, here, under version control and tested.
#
# WHAT THE VERDICT KEYS ON — the fields the automation state actually carries:
#   * lastRunStatus  must be "ok"      — a run happened, and it succeeded;
#   * lastRunAtMs    must exist and be recent (see the staleness bound below), so both
#                    "configured but never run" and "stopped running" are alarms;
#   * nextRunAtMs    must exist and not be long overdue — the scheduler advancing its
#                    own clock is the thing a wedged automation loses first.
#   * enabled        false is an alarm, not silence: a deliberately disabled automation
#                    leaves the fleet exactly as blind as a broken one, and the message
#                    names the cause so the reader is not sent hunting a fault.
#   A missing or zero lastRunAtMs is an ALARM.  It is the case this exists for:
#   everything looks configured and nothing runs.
#
# STALENESS BOUND: the LARGER of twice the automation's own schedule period (from
# schedule.everyMs) and a MAINTENANCE-WINDOW FLOOR of 7200 s (2 h).  Twice the period,
# not once, because one missed period is a hiccup and one in three runs still sees the
# watcher.  The floor exists because a PLANNED Gateway outage stops this automation for
# as long as the window runs: measured 2026-09-30, a 33-minute maintenance window left a
# 45-minute run gap (13:57:07 -> 14:42:05 BST) that tripped the old 1800 s bound and
# self-cleared on the catch-up run — i.e. the bound reported a planned outage as a
# fault, the exact false alarm this file exists to avoid.  A longer-period automation
# still gets its proportional (larger) bound.  GPU_WATCH_SELFCHECK_MAX_AGE_S overrides
# both.
#
# READ-ONLY: this script reads the automation's state and prints a verdict.  It never
# starts, stops, enables or re-arms anything — repair is a human decision.
#
# TWO CONSUMERS, SO TWO MODES (2026-09-24)
#   The repo's systemd timer wants the VERDICT every hour: a non-zero exit is what puts
#   the unit in `systemctl --user --failed` (systemd/gpu-watch-selfcheck.service says so
#   in its own words).  The OpenClaw automation wants a MESSAGE when something CHANGES:
#   it runs every 6h and delivers stdout to WhatsApp.
#
#   Those are not the same thing, so they are not the same mode.  The default mode
#   prints the alarm on every run and lets the exit code carry the verdict.  With
#   --announce the message is printed only on a TRANSITION — the state is compared with
#   the last one announced, recorded in the state file below.  The exit code keeps the SAME
#   mapping in both modes — 0 healthy, 1 alarming, 2 unreadable — because the run's STATUS
#   has to say whether the WATCHER is healthy, not merely that the command ran; Wayne's
#   call, 2026-09-24.  Consequence, stated: a standing alarm can also reach OpenClaw's own
#   execution-failure path (2 consecutive failures, 1-hour cooldown, delivered to the job's
#   announce target — docs.openclaw.ai/cli/cron) on top of the transition message.  Stdout
#   IS the delivered message and stays transition-only, so the CHANNEL carries one message
#   per change while the status carries the state.
#
# USAGE
#   gpu-watch-selfcheck.sh            silent when healthy; the alarm text when not
#   gpu-watch-selfcheck.sh --announce message on a state transition only; exit = verdict
#   gpu-watch-selfcheck.sh --json     one JSON object (machine consumers)
#   gpu-watch-selfcheck.sh --version
# EXIT  0 = healthy   1 = alarming (text on stdout)   2 = the automation is unreadable
#       (the same mapping in every mode: --announce included)
#
# ENV  GPU_WATCH_SELFCHECK_ID         automation id (default below)
#      GPU_WATCH_SELFCHECK_OPENCLAW   openclaw binary (override point for tests)
#      GPU_WATCH_SELFCHECK_MAX_AGE_S  staleness bound, seconds
#      GPU_WATCH_SELFCHECK_READY_WAIT_S      before concluding "unreadable", retry the read for
#                                     up to this many seconds (0 = off; set only by the systemd
#                                     unit — the automation leaves it unset)
#      GPU_WATCH_SELFCHECK_READY_INTERVAL_S  seconds between readiness retries (default 20)
#      GPU_WATCH_SELFCHECK_STATE_FILE what --announce announced last
#                                     (default ~/.cache/gpu-watch-selfcheck.state)
#
# AI INSTRUCTION: Increment version on significant changes.
# Module Version: 6
#   v6 (2026-10-11): an opt-in, bounded READINESS WAIT before concluding "unreadable" —
#   GPU_WATCH_SELFCHECK_READY_WAIT_S (seconds; 0 = off, the default) with
#   GPU_WATCH_SELFCHECK_READY_INTERVAL_S (seconds between retries, default 20).  A Gateway
#   that is cold-starting, or being restarted, cannot serve the CLI yet — and calling THAT an
#   unreadable WATCHER reds systemd/gpu-watch-selfcheck.service on every boot and restart,
#   an alarm on expected-to-change state.  The wait is set ONLY by that unit, so the OpenClaw
#   automation's per-tick semantics are unchanged and a human's run stays immediate.  Also:
#   --version now reports the module version by reading its own marker (it had printed "4"
#   against a marker of 5).
#   v5 (2026-09-30): ratchet hygiene only, no behaviour change — v4 put
#   SELFCHECK_MAX_AGE_FLOOR_S between max_age_seconds' doc comment and the function, so
#   §18.3's 9.5 counted it as undocumented; the constant now sits above the comment and
#   the doc is adjacent to the definition again.
#   v3 (2026-09-24): --announce's exit code carries the verdict (Wayne's call), so the
#   automation's run status reads ok only while the watcher is healthy.  The message
#   stays transition-only; the status now reports the checked state, not just that the
#   command ran.
#   v4 (2026-09-30): (a) the staleness bound gains a 2 h maintenance-window FLOOR — a
#   planned Gateway outage stops this automation for the length of the window, and the
#   old 2 x period bound (1800 s) reported every window as a fault (measured across the
#   14:04-14:37 BST outage: a 45 min gap, self-cleared at 14:42:05); (b) the alarm's
#   "Why this matters" premise is CORRECTED — passthrough has a second, Gateway-
#   independent detector (openclaw-gpu-passthrough-watch.timer), so a pause here
#   silences the ANNOUNCEMENT, it does not stop the check.
set -uo pipefail

OPENCLAW="${GPU_WATCH_SELFCHECK_OPENCLAW:-openclaw}"
AUTOMATION_ID="${GPU_WATCH_SELFCHECK_ID:-6a1b0ada-eae2-48e9-905a-78a74ba98549}"
MODE="${1:-}"
STATE_FILE="${GPU_WATCH_SELFCHECK_STATE_FILE:-${XDG_CACHE_HOME:-$HOME/.cache}/gpu-watch-selfcheck.state}"

# Readiness retry (see the ENV block).  Validated here so a bad value cannot reach `sleep`:
# 0 (or a non-integer) means no wait — the default, and the automation's behaviour.
READY_WAIT_S="${GPU_WATCH_SELFCHECK_READY_WAIT_S:-0}"
READY_INTERVAL_S="${GPU_WATCH_SELFCHECK_READY_INTERVAL_S:-20}"
[[ "$READY_WAIT_S" =~ ^[0-9]+$ ]] || READY_WAIT_S=0
if ! [[ "$READY_INTERVAL_S" =~ ^[0-9]+$ ]] || (( READY_INTERVAL_S <= 0 )); then
    READY_INTERVAL_S=20
fi

# --json_field <json> <key> — the string value of a key, else empty.  Same
# sed idiom the rest of the fleet uses on this fixed shape (see
# bin/llama-watchdog.sh's classifier): no jq, so this works wherever the console
# does, and a parse miss yields empty rather than a wrong value.
#
# head -1 is load-bearing, not tidiness: this JSON carries several of these keys
# TWICE (once inside the `state` object and once at the top level, e.g.
# nextRunAtMs/lastRunAtMs/lastRunStatus), so without it the captured value is
# multi-line — "ok\nok" — and every downstream integer/regex test fails against a
# newline.  It did: the first version of this file reported a healthy automation
# as never-run.  The FIRST occurrence is taken deliberately: that is the `state`
# object, which is the authoritative copy (the top-level mirror is for a list view).
json_field() {
    printf '%s' "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
}

# json_num <json> <key> — the numeric value of a key, else empty.
json_num() {
    printf '%s' "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" | head -1
}

# json_bool <json> <key> — "true" or "false", else empty.
json_bool() {
    printf '%s' "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p" | head -1
}

SELFCHECK_MAX_AGE_FLOOR_S=7200

# max_age_seconds <every_ms> — the staleness bound: the larger of two schedule periods
# and the maintenance-window floor.  An explicit override wins over both.
max_age_seconds() {
    local _every_ms="$1" _override="${GPU_WATCH_SELFCHECK_MAX_AGE_S:-}"
    local _bound="$SELFCHECK_MAX_AGE_FLOOR_S"
    if [[ "$_override" =~ ^[0-9]+$ ]] && (( _override > 0 )); then
        printf '%s\n' "$_override"
        return 0
    fi
    if [[ "$_every_ms" =~ ^[0-9]+$ ]] && (( _every_ms > 0 )) \
        && (( _every_ms / 1000 * 2 > _bound )); then
        _bound=$(( _every_ms / 1000 * 2 ))
    fi
    printf '%s\n' "$_bound"
}

# verdict_json <state> <detail> <name> <status> <age_s> <max_age_s> — an age that
# was never computed is JSON null, never an empty slot (that would emit
# `"age_s":,` and no consumer could parse it).
verdict_json() {
    local _state="$1" _detail="$2" _name="$3" _status="$4" _age="$5" _max_age="$6"
    [[ "$_age" =~ ^[0-9]+$ ]] || _age="null"
    [[ "$_max_age" =~ ^[0-9]+$ ]] || _max_age="null"
    printf '{"id":"%s","name":"%s","state":"%s","detail":"%s","last_run_status":"%s","age_s":%s,"max_age_s":%s}\n' \
        "$AUTOMATION_ID" "$_name" "$_state" "$_detail" "${_status:-unknown}" "$_age" "$_max_age"
}

# main — read the automation once and print the verdict.
main() {
    local _json _rc _name _enabled _status _last_ms _next_ms _every_ms
    local _max_age _now_s _age_s _overdue_s _state="" _detail=""
    local _deadline=0

    # Read the automation — with an opt-in bounded readiness WAIT (READY_WAIT_S; 0 by
    # default).  A Gateway that is cold-starting, or mid-restart, cannot serve the CLI
    # yet; reporting THAT as an unreadable WATCHER is what reds the systemd unit on a
    # boot or a restart, so the unit — and only the unit — asks for a retry window.
    if (( READY_WAIT_S > 0 )); then
        _deadline=$(( $(date +%s) + READY_WAIT_S ))
    fi
    while :; do
        _json=$("$OPENCLAW" automations get "$AUTOMATION_ID" --json 2>/dev/null); _rc=$?
        _name=$(json_field "$_json" name)
        if (( _rc == 0 )) && [[ -n "$_name" ]]; then
            break
        fi
        if (( _deadline == 0 )) || (( $(date +%s) >= _deadline )); then
            break
        fi
        sleep "$READY_INTERVAL_S"
    done

    if (( _rc != 0 )) || [[ -z "$_name" ]]; then
        _state="unreadable"
        _detail="could not read automation ${AUTOMATION_ID} (rc=${_rc}) - this check cannot"
        _detail+=" see the watcher, so it cannot vouch for it"
        emit "$_state" "$_detail" "" "" "" ""
        exit "$(exit_code_for "$_state")"   # the check itself cannot run — never green
    fi

    _enabled=$(json_bool "$_json" enabled)
    _status=$(json_field "$_json" lastRunStatus)
    _last_ms=$(json_num "$_json" lastRunAtMs)
    _next_ms=$(json_num "$_json" nextRunAtMs)
    _every_ms=$(json_num "$_json" everyMs)
    _max_age=$(max_age_seconds "$_every_ms")
    _now_s=$(date +%s)

    if [[ "$_enabled" == "false" ]]; then
        _state="disabled"
        _detail="the automation is DISABLED — nothing fires the GPU-passthrough watcher while that is true"
    elif [[ ! "$_last_ms" =~ ^[0-9]+$ ]] || (( _last_ms == 0 )); then
        _state="never-run"
        _detail="no run is recorded at all (lastRunAtMs missing/zero) — the schedule is not firing"
    elif [[ "$_status" != "ok" ]]; then
        _state="failed"
        _detail="the last run reports lastRunStatus=${_status:-unknown}, not ok — the watcher ran"
        _detail+=" and did not finish cleanly"
    else
        _age_s=$(( _now_s - _last_ms / 1000 ))
        if (( _age_s > _max_age )); then
            _state="stale"
            _detail="the last run was ${_age_s}s ago, beyond the ${_max_age}s bound — the schedule has stopped firing"
        elif [[ ! "$_next_ms" =~ ^[0-9]+$ ]] || (( _next_ms == 0 )); then
            _state="stale"
            _detail="no nextRunAtMs is scheduled while the last run is recent — the scheduler is not advancing"
        else
            _overdue_s=$(( _now_s - _next_ms / 1000 ))
            if (( _overdue_s > _max_age )); then
                _state="stale"
                _detail="the next run is ${_overdue_s}s overdue, beyond the ${_max_age}s bound"
                _detail+=" — the scheduler is wedged"
            else
                _state="ok"
                _detail="last run ${_age_s}s ago (bound ${_max_age}s), status ok"
            fi
        fi
    fi

    emit "$_state" "$_detail" "$_name" "$_status" "${_age_s:-}" "$_max_age"
    exit "$(exit_code_for "$_state")"
}

# emit <state> <detail> <name> <status> <age_s> <max_age_s> — the one place the
# verdict becomes output, so the JSON, the transition message and the plain alarm
# cannot disagree about what was found.  A healthy verdict prints NOTHING in either
# text mode (this is an automation announce payload, and a routine "fine" line every
# 15 minutes is noise that hides the real alarm).
emit() {
    local _state="$1" _detail="$2" _name="$3" _status="$4" _age_s="$5" _max_age="$6"
    case "$MODE" in
        --json)
            verdict_json "$_state" "$_detail" "${_name:-unknown}" "${_status:-unknown}" "${_age_s:-}" "${_max_age:-}"
            ;;
        --announce)
            announce "$_state" "$_detail" "$_name" "$_status"
            ;;
        *)
            [[ "$_state" == "ok" ]] && return 0
            alarm_text "$_state" "$_detail" "$_name" "$_status"
            ;;
    esac
}

# read_state — the state --announce delivered last, or empty when none is recorded.
# `[[ -r ]]` rather than a redirect through 2>/dev/null: a first run has no state file,
# and that is an ordinary starting state, not a failure to suppress.
read_state() {
    [[ -r "$STATE_FILE" ]] || return 0
    printf '%s' "$(<"$STATE_FILE")"
}

# write_state <state> — record what was announced.  A failed write is REPORTED on
# stdout rather than swallowed: without the record the next tick repeats the message,
# and an unexplained repeat is what teaches a reader to ignore this channel.
write_state() {
    printf '%s\n' "$1" > "$STATE_FILE" || printf '%s\n' \
        "note: could not record the self-check state in ${STATE_FILE}; the next transition will repeat this message"
}

# alarm_text <state> <detail> <name> <status> — what a reader gets, built in ONE place
# so the two text modes cannot describe the same state differently.
alarm_text() {
    printf '%s\n' "WARNING: GPU Passthrough Watch automation self-check: $1"
    printf '%s\n' "$2"
    printf '%s\n' "Why this matters: this automation is the CRON path that fires the GPU-passthrough"
    printf '%s\n' "watcher and ANNOUNCES a change. Passthrough is still checked independently by the"
    printf '%s\n' "systemd timer openclaw-gpu-passthrough-watch.timer (~10 min, Gateway-independent),"
    printf '%s\n' "so a pause here means the alert path went quiet — the check itself did not stop."
    printf '%s\n' "Automation: ${3:-unknown} (${AUTOMATION_ID})  lastRunStatus=${4:-unknown}"
    printf '%s\n' "Inspect: ${OPENCLAW} automations get ${AUTOMATION_ID} --json"
}

# announce <state> <detail> <name> <status> — the --announce text: a TRANSITION is the
# message.  A standing alarm is not repeated (recording the state is what makes the
# comparison possible), and a recovery IS a transition — otherwise the channel that
# reported the fault never reports that it cleared.  A healthy first run says nothing
# at all, so a fresh box does not open the channel with a routine "fine" line; a first
# run that finds a fault does announce, because a fault must never be the quiet case.
announce() {
    local _state="$1" _detail="$2" _name="$3" _status="$4"
    local _previous
    _previous=$(read_state)
    write_state "$_state"
    if [[ "$_previous" == "$_state" ]]; then
        return 0                                   # unchanged: nothing to deliver
    fi
    if [[ "$_state" != "ok" ]]; then
        alarm_text "$_state" "$_detail" "$_name" "$_status"
        return 0
    fi
    [[ -n "$_previous" ]] || return 0              # first run, healthy: nothing to say
    printf '%s\n' "RECOVERED: the GPU Passthrough Watch automation self-check is healthy again"
    printf '%s\n' "$_detail"
}

# exit_code_for <state> — the verdict as an exit code: 0 healthy, 1 alarming, 2 the
# check itself cannot see the automation.  The SAME mapping in every mode: the
# automation's run status must read ok when the watcher is healthy and error when it is
# not, so the status reports the checked state (see the header's TWO CONSUMERS note for
# the consequence — OpenClaw's own failure path can also fire).
exit_code_for() {
    case "$1" in
        ok)         printf '%s\n' "0" ;;
        unreadable) printf '%s\n' "2" ;;
        *)          printf '%s\n' "1" ;;
    esac
}

case "$MODE" in
    --version|-V)
        # Read the number from this file's OWN module-version marker so the two can never
        # drift — they had: the marker said 5 while this printed 4.  The marker is what
        # tools/check-module-versions.sh bumps on every edit, so it is the source of truth.
        printf 'gpu-watch-selfcheck %s\n' "$(sed -n 's/^# Module Version: //p' "$0" | head -1)"
        exit 0
        ;;
    --json|--announce|"") ;;
    *)
        echo "usage: gpu-watch-selfcheck.sh [--json|--announce|--version]" >&2
        exit 2   # bad invocation
        ;;
esac

main

# end of file
