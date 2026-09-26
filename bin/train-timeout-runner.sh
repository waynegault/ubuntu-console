#!/usr/bin/env bash
# train-timeout-runner.sh - Supervised, card-claiming runner for a GPU training run.
#
# WHY THIS EXISTS (card UBC-GRPO-002).  A GRPO/QLoRA run is the same shape as a
# bench run - minutes to hours of exclusive CUDA-card work - but it had no
# supervision: no pidfile, no structured log, no timeout, and nothing that
# released the card if the trainer died.  bin/bench-timeout-runner.sh is the
# template (pidfile + structured log + orphan cleanup + foreground child, so a
# silent exit 1 stops being undebuggable).  This is a SIBLING rather than a
# generalisation of that file on purpose: the bench path's timeout lives in its
# CALLER (__bench_run_with_timeout in scripts/11e-llm-model.sh), so folding a
# timeout in here would mean refactoring the bench path as well - and the bench
# path is load-bearing for the autotune/bench runs this box uses.  The
# duplication is the supervision boilerplate only.
#
# TWO THINGS THIS ADDS OVER THE BENCH TEMPLATE:
#
#   1. It CLAIMS THE CARD, for the whole run, on the SAME lock the bench/autotune
#      path uses ($LLM_BENCH_LOCK_FILE, flock + content = holder PID, removed on
#      exit).  That is deliberately not a second authority: this box keeps ONE
#      LLM on the card, and joining the existing lock is what makes a training run
#      a HOLDER CLASS of it rather than a parallel rule (Wayne's call, 2026-09-26,
#      on card UBC-GRPO-001; the audit doc's own words are "Training must register
#      as a known tenant, exactly as a bench does").
#      The lock file is REMOVED on exit because bin/gpu-busy.sh's signal 4 reads
#      its EXISTENCE, and a leftover file would read as "card busy" forever.
#      tools/clean-orphans.sh reaps it after a SIGKILL, which is why the same
#      path matters rather than a private one.
#
#   2. It CLEANS UP FAIL CLOSED after a crash.  A trainer killed mid-step leaves
#      VRAM held, and the card cannot be served until it is released.  The
#      cleanup is `bin/llama-gpu-clear.sh` run EXACTLY ONCE, never in a retry
#      loop: every probe of a broken GPU makes WSL capture a core dump (the audit
#      doc's caution), so a failing cleanup must stop probing and say so.  It runs
#      only when this runner actually held the lock - a run that was not a tenant
#      must never reap the serving lane's server.
#
# Usage:
#   bin/train-timeout-runner.sh [-p pidfile] [-l logfile] [-L lockfile]
#                               [-T seconds] [-k grace] [-c clear-script] <command...>
#
#   -p <pidfile>       Write the trainer's PID here (external monitoring).
#   -l <logfile>       Append structured start/exit lines here.
#   -L <lockfile>      Card lock to hold (default $LLM_BENCH_LOCK_FILE).  Pass "" to
#                      run UNSUPERVISED of the card lock (no claim, no cleanup);
#                      say so in the log when you do.
#   -T <seconds>       Timeout for the trainer (default 0 = no timeout).
#   -k <grace>         Seconds between SIGTERM and SIGKILL on timeout (default 30).
#   -c <clear-script>  VRAM release helper (default bin/llama-gpu-clear.sh).
#
# Exit codes:
#   0   - trainer completed, exit status propagated from it otherwise
#   124 - timeout (SIGTERM sent, grace expired)
#   2   - usage error
#   3   - the card lock is held by another run
#
# Smoke test (no GPU, no trainer - supervises `sleep`):
#   bin/train-timeout-runner.sh -l /tmp/t.log -T 2 sleep 30; echo "exit: $?"
#
# AI INSTRUCTION: Increment the Module Version on any change; increment VERSION
# for significant edits.
# Module Version: 1
VERSION="1.0"
set -euo pipefail

pidfile=""
logfile=""
lockfile="${LLM_BENCH_LOCK_FILE:-/tmp/llm-bench.lock}"
timeout_secs=0
grace=30
clear_script="$(cd "$(dirname "$0")" && pwd)/llama-gpu-clear.sh"

while getopts ":p:l:L:T:k:c:V" _opt; do
    case "$_opt" in
        p) pidfile="$OPTARG" ;;
        l) logfile="$OPTARG" ;;
        L) lockfile="$OPTARG" ;;
        T) timeout_secs="$OPTARG" ;;
        k) grace="$OPTARG" ;;
        c) clear_script="$OPTARG" ;;
        V) echo "train-timeout-runner $VERSION"; exit 0 ;;
        *) echo "train-timeout-runner: unknown option -$OPTARG" >&2; exit 2 ;;
    esac
done
shift $((OPTIND - 1))

if (( $# == 0 )); then
    echo "train-timeout-runner: no command given (see the header for usage)" >&2
    exit 2
fi

__ttr_log() {
    local _level="$1"
    shift
    if [[ -n "$logfile" ]]; then
        printf '[%s] [%s] %s\n' "$(date -u +%FT%TZ)" "$_level" "$*" >> "$logfile"
    fi
}

lock_held=0
lock_fd=""
child_pid=""
abnormal=0
# Guards against the cleanup running twice: it is invoked explicitly on the normal
# path (so a reader, and shellcheck, can see it is reachable) AND by the EXIT trap,
# which is what covers a signal or an unexpected abort.
__ttr_done=0

__ttr_cleanup() {
    local _exit_code="${1:-$?}"
    if (( __ttr_done == 1 )); then
        exit "$_exit_code"
    fi
    __ttr_done=1
    set +e
    # swallow-ok: the liveness probe IS the branch taken - a child already reaped means nothing to stop
    if [[ -n "$child_pid" ]] && kill -0 "$child_pid" 2>/dev/null; then
        __ttr_log "INFO" "stopping trainer pid $child_pid (runner exit $_exit_code)"
        # swallow-ok: best-effort TERM on a child the trap may already have reaped; the KILL below is the follow-up
        kill -TERM -- "$child_pid" 2>/dev/null || true
        sleep 1
        # swallow-ok: last-resort KILL of the same child, already logged by the line above
        kill -KILL -- "$child_pid" 2>/dev/null || true
    fi
    # Any other child of this runner (a trainer's own helpers) goes with it.
    while IFS= read -r _cpid; do
        [[ "$_cpid" =~ ^[0-9]+$ ]] || continue
        # swallow-ok: same best-effort TERM for the runner's remaining children; the trap's EXIT line records it
        kill -TERM -- "$_cpid" 2>/dev/null || true
    # swallow-ok: a ps listing that fails reads as "no remaining children"; the EXIT line records the outcome
    done < <(ps -o pid= --ppid $$ 2>/dev/null)

    # A crashed trainer holds VRAM that nothing else can use.  Release it ONCE.
    # No retry loop, deliberately: probing a broken GPU is what makes WSL capture
    # a core dump, so a failed cleanup stops and says so instead of grinding.
    if (( abnormal == 1 && lock_held == 1 )); then
        if [[ -x "$clear_script" ]]; then
            __ttr_log "WARNING" "releasing VRAM after an abnormal exit: $clear_script"
            # Capture the status explicitly: `if ! cmd` would leave $? holding the
            # NEGATION's status (0), and this line would report a failure as "rc 0".
            "$clear_script" >>"$logfile" 2>&1
            local _clear_rc=$?
            if (( _clear_rc != 0 )); then
                __ttr_log "WARNING" "VRAM release FAILED (rc $_clear_rc) - not retrying; the card may stay held"
                echo "train-timeout-runner: VRAM release FAILED (rc $_clear_rc); not retrying" >&2
            fi
        else
            __ttr_log "WARNING" "no clear script at $clear_script - VRAM may stay held after the crash"
            echo "train-timeout-runner: no clear script at $clear_script; VRAM may stay held" >&2
        fi
    fi

    if (( lock_held == 1 )); then
        [[ -n "$pidfile" ]] && rm -f "$pidfile"
        [[ -n "$lockfile" ]] && rm -f "$lockfile"
        __ttr_log "EXIT" "card lock released (exit $_exit_code)"
    fi
    exit "$_exit_code"
}
trap '__ttr_cleanup $?' EXIT INT TERM

# --- Claim the card -----------------------------------------------------------
if [[ -n "$lockfile" ]]; then
    if command -v flock >/dev/null 2>&1; then
        exec {lock_fd}>"$lockfile" || { __ttr_log "ERROR" "cannot open lock $lockfile"; exit 3; }
        if ! flock -w "${LLM_BENCH_LOCK_WAIT_SECONDS:-5}" "$lock_fd"; then
            __ttr_log "ERROR" "the card is already claimed (lock: $lockfile) - refusing to become a second tenant"
            echo "train-timeout-runner: card already claimed ($lockfile)" >&2
            exit 3
        fi
        lock_held=1
        printf '%s\n' "$$" > "$lockfile"
        __ttr_log "INFO" "card claimed: lock=$lockfile holder=$$ (this runner)"
    else
        __ttr_log "WARNING" "flock unavailable - running WITHOUT card exclusivity"
    fi
else
    __ttr_log "WARNING" "started with no card lock (explicitly unsupervised); the watchdog will read this as a foreign workload"
fi

# --- Run the trainer ----------------------------------------------------------
__ttr_log "INFO" "starting: $* (timeout=${timeout_secs}s grace=${grace}s)"
if (( timeout_secs > 0 )); then
    timeout -k "$grace" "$timeout_secs" "$@" &
else
    "$@" &
fi
child_pid=$!
__ttr_log "INFO" "trainer pid: $child_pid"
[[ -n "$pidfile" ]] && printf '%s\n' "$child_pid" > "$pidfile"

if wait "$child_pid"; then
    _wait_exit=0
else
    _wait_exit=$?
fi

if (( _wait_exit != 0 )); then
    abnormal=1
fi
if (( _wait_exit == 124 )); then
    __ttr_log "WARNING" "trainer TIMED OUT after ${timeout_secs}s (SIGTERM, then SIGKILL after ${grace}s)"
else
    __ttr_log "INFO" "trainer exited with code $_wait_exit"
fi

# Explicit finish: releases the lock and (after a crash) the card, then exits with
# the trainer's status.  The EXIT trap covers the paths that never reach this line.
__ttr_cleanup "$_wait_exit"

# end of file
