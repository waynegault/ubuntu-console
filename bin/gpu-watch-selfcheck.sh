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
# STALENESS BOUND: twice the automation's own schedule period when the JSON carries
# one (schedule.everyMs), else 3600 s.  Twice, not once, because one missed period is
# a hiccup and one in three runs still sees the watcher; a bound of one period would
# report every slow tick as an outage.
#
# READ-ONLY: this script reads the automation's state and prints a verdict.  It never
# starts, stops, enables or re-arms anything — repair is a human decision.
#
# USAGE
#   gpu-watch-selfcheck.sh            silent when healthy; the alarm text when not
#   gpu-watch-selfcheck.sh --json     one JSON object (machine consumers)
#   gpu-watch-selfcheck.sh --version
# EXIT  0 = healthy   1 = alarming (text on stdout)   2 = the automation is unreadable
#
# ENV  GPU_WATCH_SELFCHECK_ID         automation id (default below)
#      GPU_WATCH_SELFCHECK_OPENCLAW   openclaw binary (override point for tests)
#      GPU_WATCH_SELFCHECK_MAX_AGE_S  staleness bound, seconds
#
# AI INSTRUCTION: Increment version on significant changes.
# Module Version: 1
set -uo pipefail

OPENCLAW="${GPU_WATCH_SELFCHECK_OPENCLAW:-openclaw}"
AUTOMATION_ID="${GPU_WATCH_SELFCHECK_ID:-6a1b0ada-eae2-48e9-905a-78a74ba98549}"
MODE="${1:-}"

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

# max_age_seconds <every_ms> — the staleness bound: two schedule periods when the
# JSON carries a period, else 3600 s.  An explicit override wins over both.
max_age_seconds() {
    local _every_ms="$1" _override="${GPU_WATCH_SELFCHECK_MAX_AGE_S:-}"
    if [[ "$_override" =~ ^[0-9]+$ ]] && (( _override > 0 )); then
        printf '%s\n' "$_override"
        return 0
    fi
    if [[ "$_every_ms" =~ ^[0-9]+$ ]] && (( _every_ms > 0 )); then
        printf '%s\n' "$(( _every_ms / 1000 * 2 ))"
        return 0
    fi
    printf '%s\n' "3600"
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

    _json=$("$OPENCLAW" automations get "$AUTOMATION_ID" --json 2>/dev/null); _rc=$?

    _name=$(json_field "$_json" name)
    if (( _rc != 0 )) || [[ -z "$_name" ]]; then
        _state="unreadable"
        _detail="could not read automation ${AUTOMATION_ID} (rc=${_rc}) - this check cannot"
        _detail+=" see the watcher, so it cannot vouch for it"
        emit "$_state" "$_detail" "" "" "" ""
        exit 2   # the check itself cannot run — never a green answer
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
    [[ "$_state" == "ok" ]] || exit 1   # alarming: the exit code carries it too
    exit 0
}

# emit <state> <detail> <name> <status> <age_s> <max_age_s> — the one place the
# verdict becomes output, so the JSON and the human text cannot disagree.  A
# healthy verdict prints NOTHING (this is an automation announce payload, and a
# routine "fine" line every 15 minutes is noise that hides the real alarm).
emit() {
    local _state="$1" _detail="$2" _name="$3" _status="$4" _age_s="$5" _max_age="$6"
    if [[ "$MODE" == "--json" ]]; then
        verdict_json "$_state" "$_detail" "${_name:-unknown}" "${_status:-unknown}" "${_age_s:-}" "${_max_age:-}"
        return 0
    fi
    [[ "$_state" == "ok" ]] && return 0
    printf '%s\n' "WARNING: GPU Passthrough Watch automation self-check: ${_state}"
    printf '%s\n' "${_detail}"
    printf '%s\n' "Why this matters: this automation is what fires the GPU-passthrough watcher,"
    printf '%s\n' "so while it is not running, a lost CUDA-card passthrough is not detected or announced."
    printf '%s\n' "Automation: ${_name:-unknown} (${AUTOMATION_ID})  lastRunStatus=${_status:-unknown}"
    printf '%s\n' "Inspect: ${OPENCLAW} automations get ${AUTOMATION_ID} --json"
}

case "$MODE" in
    --version|-V)
        echo "gpu-watch-selfcheck 1"
        exit 0
        ;;
    --json|"") ;;
    *)
        echo "usage: gpu-watch-selfcheck.sh [--json|--version]" >&2
        exit 2   # bad invocation
        ;;
esac

main

# end of file
