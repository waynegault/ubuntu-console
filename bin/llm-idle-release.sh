#!/usr/bin/env bash
# shellcheck shell=bash
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 1
# llm-idle-release.sh - stop a `model use` lane after a quiet interval.
#
# WHY THIS EXISTS.  `model use` takes the CUDA card and holds it until `model stop`:
# the lane is a nohup process with no systemd timer behind it, so a lane left up
# overnight keeps 17-30 GiB of VRAM that a bench or the next model cannot have.
# This is the release path, and it is OPT-IN per launch
# (`model use N --idle-timeout S`).
#
# WHAT COUNTS AS ACTIVITY.  Not the log's mtime: `/health` probes and Prometheus
# scrapes do not write to it, so mtime is neither activity nor its absence
# (measured 2026-11-09 against the resident chat lane).  The counters are
# llama-server's own, served on the lane's own listener:
#   llamacpp:prompt_tokens_total   monotonic; any increase served a request
#   llamacpp:requests_processing   gauge; >0 means a request is in flight now
# The first successful probe is the BASELINE, not activity, so a lane that has
# been quiet since it started is released on schedule.
#
# STOPS THROUGH THE CONSOLE, NOT BY SIGNAL.  On expiry this runs `tac-exec halt`,
# the repo's own stop path: it kills the model subshell tree, clears the
# active-model pointer and releases the CUDA card mark.  Killing llama-server
# here would leave all three behind - the silent-state shape this repo bans.
#
# Env seams (pinned by tests/unit/89-model-idle-release.bats):
#   LLM_IDLE_PID_FILE   monitor pid file (default /dev/shm/llm-idle-release.pid)
#   TAC_EXEC_BIN        the stop command (default: tac-exec on PATH)
#   LLAMA_IDLE_POLL_S   poll interval (default 30)
#
# Usage: llm-idle-release.sh --port N --timeout S [--poll S] [--log FILE]
set -uo pipefail

# warn - the one stderr helper, so call sites never hand-write a redirect.
warn() { cat >&2 <<< "$*"; }

PORT=""
TIMEOUT=""
POLL="${LLAMA_IDLE_POLL_S:-30}"
LOG_FILE=""
PID_FILE="${LLM_IDLE_PID_FILE:-/dev/shm/llm-idle-release.pid}"
EXEC_CMD="${TAC_EXEC_BIN:-}"

# usage - the flag list, printed on --help and on a bad argument.
usage() {
    cat <<'USAGE'
Usage: llm-idle-release.sh --port N --timeout S [options]

  --port N        llama-server port to watch (required)
  --timeout S     seconds with no requests before stopping the lane (required)
  --poll S        seconds between probes (default 30, or LLAMA_IDLE_POLL_S)
  --log FILE      append decisions here (default: stderr)
  --pid-file FILE where to publish this monitor's pid
  --exec-cmd CMD  the stop command (default: tac-exec on PATH)
  --help          show this text
USAGE
}

while [[ $# -gt 0 ]]
do
    case "$1" in
        --port) PORT="${2:-}"; shift 2 ;;
        --timeout) TIMEOUT="${2:-}"; shift 2 ;;
        --poll) POLL="${2:-}"; shift 2 ;;
        --log) LOG_FILE="${2:-}"; shift 2 ;;
        --pid-file) PID_FILE="${2:-}"; shift 2 ;;
        --exec-cmd) EXEC_CMD="${2:-}"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        # usage error: 2 separates a bad invocation from a refused start (1)
        *) warn "unknown argument: $1"; usage; exit 2 ;;
    esac
done

case "$PORT" in
    # usage error: 2 separates a bad invocation from a refused start (1)
    ''|*[!0-9]*) warn "--port must be a whole number"; exit 2 ;;
    *) ;;
esac
case "$TIMEOUT" in
    # usage error: 2 separates a bad invocation from a refused start (1)
    ''|*[!0-9]*) warn "--timeout must be a whole number of seconds"; exit 2 ;;
    *) ;;
esac
case "$POLL" in
    # usage error: 2 separates a bad invocation from a refused start (1)
    ''|*[!0-9]*|0) warn "--poll must be a positive whole number of seconds"; exit 2 ;;
    *) ;;
esac

# One name for the effective path, so the delete sites name the state-contract
# symbol rather than a local alias.
LLM_IDLE_PID_FILE="$PID_FILE"

# A zero timeout is the documented "disabled" value.  The launcher does not start
# the monitor in that case; this arm keeps a hand-run invocation honest.
if (( TIMEOUT == 0 ))
then
    exit 0
fi

# log - one timestamped decision, to the lane log or to stderr.
log() {
    local _msg
    _msg="$(date '+%Y-%m-%d %H:%M:%S') llm-idle-release[$PORT]: $*"
    if [[ -n "$LOG_FILE" ]]
    then
        if ! printf '%s\n' "$_msg" >> "$LOG_FILE"
        then
            warn "llm-idle-release: cannot append to $LOG_FILE"
        fi
    else
        warn "$_msg"
    fi
}

if [[ -z "$EXEC_CMD" ]]
then
    # swallow-ok: an absent tac-exec stays empty, and the guard below is the refusal
    EXEC_CMD="$(command -v tac-exec 2>/dev/null)"
fi
if [[ -z "$EXEC_CMD" || ! -x "$EXEC_CMD" ]]
then
    log "no stop command found (tac-exec); refusing to watch a lane it cannot release"
    exit 1
fi

# Publish the pid BEFORE the first probe, and fail loudly if it cannot be written:
# a monitor the stop path cannot find is a hazard, not a best-effort detail.
_pid_tmp="$PID_FILE.tmp.$$"
if ! { printf '%s\n' "$$" > "$_pid_tmp" && mv "$_pid_tmp" "$PID_FILE"; }
then
    log "cannot write $PID_FILE; refusing to watch (a monitor that cannot be stopped is a hazard)"
    exit 1
fi

# _cleanup - remove OUR pid record on exit, never a newer monitor's.
_cleanup() {
    local _own=""
    if [[ -r "$PID_FILE" ]]
    then
        read -r _own < "$PID_FILE" || _own=""
    fi
    # Only remove OUR record: a newer monitor may already own the path.
    if [[ "$_own" == "$$" ]]
    then
        rm -f "$LLM_IDLE_PID_FILE"
    fi
}
trap _cleanup EXIT
# A trapped TERM must END the loop, not resume it; the EXIT trap then removes the pid
# record.  143 is 128+SIGTERM.
trap 'exit 143' INT TERM   # 128+SIGTERM

# metric - one exposition value from a body, or empty when absent.
metric() {
    awk -v n="llamacpp:$2" '$1 == n { print $2; exit }' <<< "$1"
}

# numeric_change - true when both values parse and differ.  The counters can arrive
# in scientific notation (1.2e+06), so they are compared as numbers, not strings.
numeric_change() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 != b + 0) }'
}

# positive - true when the gauge reads above zero.
positive() {
    awk -v v="$1" 'BEGIN { exit !(v + 0 > 0) }'
}

# probe - the lane's exposition body, or empty when the endpoint does not answer.
probe() {
    # An unreachable endpoint returns empty, which the caller counts as a failed
    # probe and never as activity.
    # swallow-ok: empty is the not-activity answer this function reports
    curl -s --max-time 2 "http://127.0.0.1:$PORT/metrics" 2>/dev/null
}

last_counter=""
last_active="$(date +%s)"
failures=0
log "watching :$PORT; release after ${TIMEOUT}s with no requests (poll ${POLL}s)"

while true
do
    sleep "$POLL"
    now="$(date +%s)"
    body="$(probe)"

    if [[ -z "$body" ]]
    then
        failures=$(( failures + 1 ))
        if (( failures >= 3 ))
        then
            log "metrics stopped answering for ${failures} probes; the lane is gone or unmeasured - exiting"
            exit 0
        fi
        continue
    fi
    failures=0

    proc="$(metric "$body" requests_processing)"
    counter="$(metric "$body" prompt_tokens_total)"

    if [[ -n "$proc" ]] && positive "$proc"
    then
        last_active="$now"
    fi
    if [[ -n "$counter" ]]
    then
        if [[ -n "$last_counter" ]] && numeric_change "$last_counter" "$counter"
        then
            last_active="$now"
        fi
        last_counter="$counter"
    fi

    idle=$(( now - last_active ))
    if (( idle < TIMEOUT ))
    then
        continue
    fi

    # Second probe at the deadline: a request that started during the last poll
    # must not be cut off by the release.
    body="$(probe)"
    proc="$(metric "$body" requests_processing)"
    counter="$(metric "$body" prompt_tokens_total)"
    if [[ -n "$proc" ]] && positive "$proc"
    then
        last_active="$(date +%s)"
        continue
    fi
    if [[ -n "$counter" && -n "$last_counter" ]] && numeric_change "$last_counter" "$counter"
    then
        last_counter="$counter"
        last_active="$(date +%s)"
        continue
    fi

    log "idle ${idle}s (no request since $last_active); releasing the lane via $EXEC_CMD halt"
    # Drop OUR record first: the stop path reads this file and would otherwise send
    # this monitor its own TERM before the stop could complete.
    rm -f "$LLM_IDLE_PID_FILE"
    _rc=0
    if [[ -n "$LOG_FILE" ]]
    then
        LLM_PORT="$PORT" LLM_IDLE_PID_FILE="$PID_FILE" "$EXEC_CMD" halt >> "$LOG_FILE" 2>&1 || _rc=$?
    else
        LLM_PORT="$PORT" LLM_IDLE_PID_FILE="$PID_FILE" "$EXEC_CMD" halt || _rc=$?
    fi
    if (( _rc != 0 ))
    then
        log "stop command exited ${_rc}; the lane may still be serving"
    else
        log "lane released"
    fi
    exit "$_rc"
done

# end of file
