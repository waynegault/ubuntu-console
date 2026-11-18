#!/usr/bin/env bash
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 1
#   v1 (2026-11-18): first tracked version.  Replaces a throwaway harness that measured
#   --spec-type ngram-mod on this box's chat lane by hand (2026-11-18 11:07-11:13 GMT);
#   the numbers in the commit are that run's, re-measured here on the same argv.
#===============================================================================
# bench-spec-ab.sh — A/B one CUDA lane's OWN argv with one extra speculative-decoding flag.
#
# WHY THIS IS NOT A MODE OF THE OTHER TWO BENCHES
#   bench-rows.sh re-measures registry rows through llama-bench.  spec-decode-bench.sh
#   measures acceptance against a server someone else launched.  Speculative decoding
#   cannot be measured by llama-bench at all (`llama-bench --help | grep -c spec-type`
#   reads 0 — measured 2026-11-18), and its two arms need the lane's real command line,
#   so this wrapper owns the window and launches the argv twice.  It MEASURES; it does
#   not certify and it changes no unit.
#
# THE PROPERTY THAT MATTERS: the argv is READ FROM THE UNIT (`systemctl --user cat`), so
#   the bench measures what the lane actually runs, including whichever drop-ins are
#   installed.  A copy of the command line in this file would drift the first time a
#   drop-in moved the window, and the bench would keep certifying the old one.
#
# WHAT IT REPORTS: generation tok/s per prompt per arm, the server's own draft counts,
#   and the emitted TEXT.  With greedy sampling both arms must agree; a difference is
#   REPORTED, never hidden — speculation can flip an argmax tie (measured 2026-11-18:
#   identical on a cold pool, different once drafts were accepted).
#
# Usage:  bench-spec-ab.sh [--unit UNIT] [--set all|physics|legal|agentic]
#                          [--reps N] [--max-tokens N] [--port N]
#                          [--spec-type TYPE] [--print-plan]
#   --set        shared prompt set (scripts/prompt-sets.sh, default agentic)
#   --reps       repetitions per prompt per arm (default 2)
#   --print-plan resolve and print both arms, touch no hardware, exit 0
#
# Exit: 0 both arms measured; 1 pre-flight, refusal or measurement failure; 2 usage.
#===============================================================================

set -uo pipefail

# ── Box-wide heavy-job serialisation ─────────────────────────────────────────
# Same prologue as bench-rows.sh: re-entrant through HEAVY_JOB_HELD so an enclosing
# heavy job passes through instead of deadlocking on its own lock.
if [[ -z "${HEAVY_JOB_HELD:-}" ]]; then
    exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/heavy-job" \
        "${BASH:-bash}" "$(readlink -f "${BASH_SOURCE[0]}")" "$@"
fi

REPO="${REPO:-/home/wayne/github-wsl/ubuntu-console}"
# shellcheck source=../scripts/01-constants.sh
source "$REPO/scripts/01-constants.sh"
# The lane resolver lives in the shared library; 01-constants does NOT provide it.
# shellcheck source=_tac-bin-lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/_tac-bin-lib.sh"
# shellcheck source=../scripts/prompt-sets.sh
source "$REPO/scripts/prompt-sets.sh"

SUSPEND="${LLAMA_WATCHDOG_CUDA_SUSPEND_FILE:-/dev/shm/llama-watchdog-cuda.suspend}"
LOGDIR="${LLM_STATE_DIR:-$HOME/.llm}/autotune-logs"
mkdir -p "$LOGDIR"

AB_PORT=18090
UNIT=""
SPEC_FLAG="--spec-type ngram-mod"
REPS=2
MAX_TOKENS=256
PROMPT_SET="agentic"
PRINT_PLAN=0

# _ab_usage — the usage block, so an argument error names it instead of guessing.
_ab_usage() {
    sed -n 's/^# Usage:  bench-spec-ab.sh/usage: bench-spec-ab.sh/p' "${BASH_SOURCE[0]}" >&2
    sed -n '/^#   --set /,/^#$/p' "${BASH_SOURCE[0]}" | sed 's/^#   /        /;s/^#$//' >&2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --unit)       UNIT="$2"; shift 2 ;;
        --set)        PROMPT_SET="$2"; shift 2 ;;
        --reps)       REPS="$2"; shift 2 ;;
        --max-tokens) MAX_TOKENS="$2"; shift 2 ;;
        --port)       AB_PORT="$2"; shift 2 ;;
        --spec-type)  SPEC_FLAG="--spec-type $2"; shift 2 ;;
        --print-plan) PRINT_PLAN=1; shift ;;
        -h|--help)    _ab_usage; exit 0 ;;
        *)            echo "bench-spec-ab: unknown argument '$1'" >&2; _ab_usage; exit 2 ;;
    esac
done

if ! [[ "$REPS" =~ ^[0-9]+$ ]] || (( REPS <= 0 )); then
    echo "bench-spec-ab: --reps must be a positive integer" >&2
    exit 2
fi
if ! [[ "$MAX_TOKENS" =~ ^[0-9]+$ ]] || (( MAX_TOKENS <= 0 )); then
    echo "bench-spec-ab: --max-tokens must be a positive integer" >&2
    exit 2
fi
[[ "$AB_PORT" =~ ^[0-9]+$ ]] || { echo "bench-spec-ab: --port must be numeric" >&2; exit 2; }

[[ -n "$UNIT" ]] || UNIT="$(_tac_cuda_lane_unit)"
if [[ -z "$UNIT" ]]; then
    echo "bench-spec-ab: REFUSING — no CUDA lane resolved (host profile not loaded)" >&2
    exit 1
fi

# _lane_argv — the EFFECTIVE ExecStart of the unit, %h expanded, as one line.
# BENCH_SPEC_AB_UNIT_TEXT names a file to read instead of systemctl: that is the test
# seam, so the argv logic can be exercised with no systemd and no card.
_lane_argv() {
    local _text
    if [[ -n "${BENCH_SPEC_AB_UNIT_TEXT:-}" ]]; then
        _text="$(cat "$BENCH_SPEC_AB_UNIT_TEXT")"
    else
        _text="$(systemctl --user cat "$UNIT")" || return 1
    fi
    # The LAST ExecStart= wins: drop-ins apply in name order, so the tail is effective.
    # swallow-ok: an absent ExecStart prints empty, and the caller refuses on empty
    _text="$(sed -n 's/^ExecStart=//p' <<< "$_text" | tail -1)"
    _text="${_text//%h/$HOME}"
    printf '%s' "$_text"
}

# _arm_argv <baseline|spec> — the lane's argv on the bench port, with the flag added
# for `spec` and STRIPPED from both arms first.  The strip is not tidiness: once a
# drop-in enables speculation on the lane, the argv read from the unit already carries
# it, and a baseline that carried it too would be the same experiment twice — measured
# 2026-11-18 by --print-plan on this very lane, which printed --spec-type on both arms.
# Fails closed if --port is not in the two-token form it can rewrite: binding the lane's
# own port would collide with the unit the trap restarts.
_arm_argv() {
    local _arm="$1" _src _out="" _tok
    local -a _toks
    _src="$(_lane_argv)" || return 1
    [[ -n "$_src" ]] || return 1
    read -r -a _toks <<< "$_src"
    local _i=0 _port_seen=0 _stripped=""
    while (( _i < ${#_toks[@]} )); do
        _tok="${_toks[_i]}"
        case "$_tok" in
            --port)      _out+="--port $AB_PORT "; _port_seen=1; _i=$((_i + 2)); continue ;;
            --alias)     _out+="--alias bench-spec-ab "; _i=$((_i + 2)); continue ;;
            --spec-type) _stripped="$_tok ${_toks[_i + 1]:-}"; _i=$((_i + 2)); continue ;;
            *)           ;;
        esac
        _out+="$_tok "
        _i=$((_i + 1))
    done
    (( _port_seen == 1 )) || { echo "bench-spec-ab: REFUSING — no '--port N' in $UNIT" >&2; return 1; }
    if [[ -n "$_stripped" ]]; then
        echo "bench-spec-ab: stripped the unit's own '$_stripped' from the $_arm arm" >&2
    fi
    if [[ "$_arm" == "spec" ]]; then
        _out+="$SPEC_FLAG "
    fi
    printf '%s--log-file %s/spec-ab-%s.log' "$_out" "$LOGDIR" "$_arm"
}

# _ab_healthy — 1 while nothing answers /health on the bench port.
_ab_healthy() {
    [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        "http://127.0.0.1:$AB_PORT/health")" == "200" ]]
}

# _ab_wait_up <server-pid> <seconds> — wait for /health 200, or fail on an early exit.
_ab_wait_up() {
    local _pid="$1" _seconds="$2" _waited=0
    while (( _waited < _seconds )); do
        # swallow-ok: a dead pid is the condition this loop tests, not a failure
        if ! kill -0 "$_pid" 2>/dev/null; then
            echo "bench-spec-ab: server exited during load (pid $_pid)" >&2
            return 1
        fi
        if _ab_healthy; then
            return 0
        fi
        sleep 2
        _waited=$((_waited + 2))
    done
    echo "bench-spec-ab: server did not become healthy within ${_seconds}s" >&2
    return 1
}

# _ab_stop <pid> — terminate a bench server and wait for the port to free.
_ab_stop() {
    local _pid="$1" _waited=0
    # swallow-ok: an already-stopped server is the goal; kill rc is the race with its exit
    kill -0 "$_pid" 2>/dev/null || return 0
    # swallow-ok: liveness is re-read below; a signal racing the exit must not abort the stop
    kill -TERM "$_pid" 2>/dev/null
    while (( _waited < 30 )); do
        # swallow-ok: same loop condition — absence ends the wait
        kill -0 "$_pid" 2>/dev/null || return 0
        sleep 1
        _waited=$((_waited + 1))
    done
    # swallow-ok: last resort; a process that died between the check and now is stopped
    kill -KILL "$_pid" 2>/dev/null
    return 0
}

# _ab_ask <prompt> — one greedy completion; prints "tg draft accepted sha" on one line.
# A 2-consecutive-error guard is the caller's (Wayne's bench rule): an errored case is
# not data, and this returns non-zero so the caller can count it.
_ab_ask() {
    local _prompt="$1" _payload _resp _code
    _payload="$(jq -n --arg p "$_prompt" --argjson mt "$MAX_TOKENS" \
        '{messages: [{role: "user", content: $p}], max_tokens: $mt, temperature: 0}')"
    _resp="$(curl -sS --max-time 600 "http://127.0.0.1:$AB_PORT/v1/chat/completions" \
        -H 'Content-Type: application/json' -d "$_payload")" || return 1
    [[ -n "$_resp" ]] || return 1
    _code="$(printf '%s' "$_resp" | jq -r '
        [ (.timings.predicted_per_second // 0),
          (.timings.draft_n // 0),
          (.timings.draft_n_accepted // 0),
          ((.choices[0].message.content // "") | @base64) ] | @tsv')" || return 1
    printf '%s\n' "$_code"
}

# _ab_measure <arm> — start the arm, send the prompt set REPS times, print rows.
# Rows: <arm>\t<prompt>\t<rep>\t<tg>\t<draft>\t<accepted>\t<sha>
_ab_measure() {
    local _arm="$1" _argv _pid _i _rep _row _tg _draft _acc _b64 _sha _errors=0
    _argv="$(_arm_argv "$_arm")" || return 1
    echo "=== arm $_arm: ${_argv%% --log-file*}"
    local -a _args
    read -r -a _args <<< "$_argv"
    "${_args[@]}" >/dev/null 2>&1 &
    _pid=$!
    _ab_wait_up "$_pid" 300 || { _ab_stop "$_pid"; return 1; }
    # One discard request so CUDA graph capture is not counted as a measurement.  A
    # failure here aborts: /health answered but the server cannot complete a request,
    # and every number after it would be an artifact of that condition.
    if ! _ab_ask "Say ok." >/dev/null; then
        echo "bench-spec-ab: warm-up request failed on arm $_arm — aborting" \
             "(a server that answers /health but not a request is not measurable)" >&2
        _ab_stop "$_pid"
        return 1
    fi
    for (( _i = 0; _i < ${#PROMPTS[@]}; _i++ )); do
        for (( _rep = 1; _rep <= REPS; _rep++ )); do
            if ! _row="$(_ab_ask "${PROMPTS[_i]}")"; then
                _errors=$((_errors + 1))
                echo "  ${PROMPT_NAMES[_i]} rep $_rep ERROR (${_errors} consecutive)" >&2
                if (( _errors >= 2 )); then
                    _ab_stop "$_pid"
                    echo "bench-spec-ab: ABORT after 2 consecutive errors (bench fail-fast)" >&2
                    return 1
                fi
                continue
            fi
            _errors=0
            _tg="$(cut -f1 <<< "$_row")"
            _draft="$(cut -f2 <<< "$_row")"
            _acc="$(cut -f3 <<< "$_row")"
            _b64="$(cut -f4 <<< "$_row")"
            _sha="$(printf '%s' "$_b64" | base64 -d | sha256sum | cut -c1-16)"
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$_arm" "${PROMPT_NAMES[_i]}" "$_rep" "$_tg" "$_draft" "$_acc" "$_sha"
            printf '  %-12s rep %s  tg=%8.2f  draft=%s accepted=%s\n' \
                "${PROMPT_NAMES[_i]}" "$_rep" "$_tg" "$_draft" "$_acc"
        done
    done
    _ab_stop "$_pid"
    return 0
}

__resolve_prompt_set "$PROMPT_SET" || {
    echo "bench-spec-ab: unknown --set '$PROMPT_SET' (all|physics|legal|agentic)" >&2
    exit 1
}

if (( PRINT_PLAN == 1 )); then
    echo "unit:   $UNIT"
    echo "prompts: $PROMPT_SET (${#PROMPTS[@]})  reps: $REPS  max_tokens: $MAX_TOKENS"
    echo "baseline: $( _arm_argv baseline )" || exit 1
    echo "spec:     $( _arm_argv spec )" || exit 1
    exit 0
fi

# ── The window: same order as bench-rows.sh, same helpers ────────────────────
if ! _tac_suspend_acquire "$SUSPEND"; then
    _owner="$(_tac_suspend_pid "$SUSPEND")"
    echo "bench-spec-ab: REFUSING — $SUSPEND is held by a live run" \
         "(owner pid ${_owner:-unknown})" >&2
    exit 1
fi
LOG="$LOGDIR/spec-ab-$(date +%Y%m%d-%H%M%S)-$PROMPT_SET.log"
trap '_tac_suspend_release "$SUSPEND"; _tac_cleanroom_restore' EXIT

{
    echo "=== bench-spec-ab $UNIT  set=$PROMPT_SET reps=$REPS max_tokens=$MAX_TOKENS"
    echo "=== started $(date -Iseconds)  port=$AB_PORT  flag=$SPEC_FLAG"
    echo "=== suspend: $SUSPEND  lane: $UNIT"
} | tee -a "$LOG"

_tac_cleanroom_enter "$REPO" "$UNIT" "$LOG"
_baseline_rc=0
_baseline_out="$(_tac_gpu_wait_baseline 90 2)" || _baseline_rc=$?
printf '%s\n' "$_baseline_out" | tee -a "$LOG"
if (( _baseline_rc != 0 )); then
    echo "bench-spec-ab: ABORT — the VRAM baseline is not clear; nothing measured" | tee -a "$LOG"
    exit 1
fi

{
    _ab_measure baseline || exit 1
    _ab_measure spec || exit 1
} 2>&1 | tee -a "$LOG"

echo "=== done $(date -Iseconds) — the lane is restored by the EXIT trap" | tee -a "$LOG"
exit 0
