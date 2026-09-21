#!/usr/bin/env bash
# gpu-busy.sh — reliable "CUDA card actually in use" detector for local-llm gating.
# Version: 1.5.0 (2026-09-21: the declared-workload check proves the artefact is
#          being EXECUTED, not merely NAMED — identity from /proc/PID/exe (or comm
#          when exe is another user's and unreadable), plus an argv element that is
#          a path to the file.  The pattern still selects candidates, so the file
#          name travels with every call.  Before this, `pgrep -f` alone counted a
#          `cat /usr/local/bin/clear_vram.sh` in an operator's own shell as a
#          declared workload and the watchdog stopped a serving CUDA lane on a free
#          card — the third variant of the same command-line-mention defect, after
#          1.4.0 (signal 2) and 1.3.0 (the patterns themselves))
# Version: 1.4.0 (2026-09-16: signal 2 identifies a resident by its /proc/PID/exe
#          resolved against the sanctioned CUDA/Xe binaries, instead of by the
#          NAME "llama-server" — which any process that merely MENTIONS the string
#          could satisfy, so a stray server from another build path was read as
#          ours and the card looked free)
# Version: 1.3.0 (2026-09-15: the declared-workload patterns name real artefacts
#          instead of bare words, and this probe's own process chain is excluded —
#          a shell that merely mentioned "autotune" was read as a bench and the
#          watchdog took a healthy CUDA lane down)
# Module Version: 5
# AI INSTRUCTION: After any code change, increment the Version value in this file.
#
# CARD DISCIPLINE: this script is about the CUDA card only.  The Xe card is a
# different card with its own lanes (xe-llama-server :18081, xe-llama-embed
# :18080) and its own lifecycle.  Nothing here says anything about the Xe card,
# and nothing here should ever gate or stop an Xe lane.
#
# A single nvidia-smi snapshot is NOT reliable (utilization reads 0% between
# tokens; a bench can be idle for seconds between model loads). VRAM footprint
# alone is NOT reliable either (llama-server always holds ~3.8GB of the 4GB
# card). So we combine five signals; ANY true => CUDA card BUSY:
#
#   1. Utilization samples — max over N samples exceeds threshold (actually computing)
#   2. Foreign compute-app PIDs — a resident whose /proc/PID/exe is not one of the
#      two sanctioned llama-server binaries holds a CUDA context (someone else is
#      loaded on the GPU).  Both are allowed: the Xe binary is ours, and the Xe
#      lane must go on serving whether or not CUDA is clear.
#   3. Declared GPU workloads — a known GPU-hungry artefact is being EXECUTED
#      (model_selection_bench, autotune, llama-bench, clear_vram).  Read as
#      "executed", never as "named": the identity is the running executable, so a
#      reader (cat/grep/less/tail) that merely mentions the file does not count.
#      A false BUSY is not the safe direction here — it stops the lane.
#   4. Lock files — /tmp/llm-bench.lock (bench/autotune convention; watchdog
#      already honours it)
#   5. Another agent's ownership lock (the investigator pipeline's flock).  Signal
#      2 CANNOT see it: their bench server and our own CUDA lane are the SAME
#      binary (llama.cpp/build/bin/llama-server), so a name-based foreign-app
#      check mistakes one for the other.  The flock is the only reliable
#      discriminator, and honouring it is what keeps ONE LLM on the card.
#
# Exit: 0 = GPU FREE (safe to run local LLM), 1 = GPU BUSY.
# --json : print {"busy":true,"reasons":[...]} (exit code still set).
# --wait SECONDS : poll until free or timeout; exit 0 free, 1 still busy, 2 error.
# Env: GPU_BUSY_UTIL_THRESHOLD (default 15 %), GPU_BUSY_SAMPLES (default 5),
#      GPU_BUSY_SAMPLE_INTERVAL (default 0.5 s), GPU_BUSY_LOG (default none)
set -u

UTIL_THRESHOLD="${GPU_BUSY_UTIL_THRESHOLD:-15}"
SAMPLES="${GPU_BUSY_SAMPLES:-2}"
SAMPLE_INTERVAL="${GPU_BUSY_SAMPLE_INTERVAL:-1.5}"
BENCH_LOCK="${LLM_BENCH_LOCK_FILE:-/tmp/llm-bench.lock}"
LOG_FILE="${GPU_BUSY_LOG:-}"

log() { [[ -n "$LOG_FILE" ]] && printf '%s [gpu-busy] %s\n' "$(date -Iseconds)" "$*" >> "$LOG_FILE"; }

REASONS=()

util_busy() {
    local max_util=0 s out rc
    for _ in $(seq 1 "$SAMPLES"); do
        out=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null); rc=$?
        # While the driver is unavailable every sample is a *crashing* nvidia-smi, and
        # each crash makes WSL capture a core dump (kernel-log noise + jitter). One
        # failed probe is enough proof they will all fail: stop sampling and let
        # foreign_apps_busy() fail closed with reason nvidia-smi-unavailable.
        (( rc != 0 )) && return 1
        s=$(tr -dc '0-9' <<<"$out")
        [[ -z "$s" ]] && s=0
        (( s > max_util )) && max_util=$s
        (( s >= UTIL_THRESHOLD )) && { REASONS+=("util=${s}%>=${UTIL_THRESHOLD}%"); return 0; }
        sleep "$SAMPLE_INTERVAL"
    done
    return 1
}

foreign_apps_busy() {
    local pid comm cmdline exe smi_out smi_rc _a
    # When the driver/NVML blocks GPU access, nvidia-smi exits non-zero AND prints
    # its error text on STDOUT. Without this guard that text was read as a pid,
    # yielding the nonsense reason "foreign-app pid=Failed to initialize NVML...".
    # We cannot prove the GPU is free, so FAIL CLOSED with a truthful reason.
    smi_out=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null)
    smi_rc=$?
    if (( smi_rc != 0 )) || grep -qvE '^[0-9]*$' <<< "${smi_out:-0}"; then
        REASONS+=("nvidia-smi-unavailable")
        return 0
    fi
    # The residents this probe must not report as foreign, resolved to their real
    # paths. Matched on /proc/PID/exe — never on comm or cmdline: a NAME matches
    # any process that merely MENTIONS the string (a `tail -f llama-server.log`, a
    # shell running `grep llama-server`), and the Xe build carries the same binary
    # NAME as the CUDA one, so a name cannot tell the two cards' servers apart
    # either. These defaults mirror 01-constants.sh (LLAMA_CUDA_SERVER_BIN /
    # LLAMA_XE_SERVER_BIN); this probe is standalone and does not source the
    # console, so they are repeated here rather than imported.
    local -a _allowed=()
    for _a in "${LLAMA_CUDA_SERVER_BIN:-$HOME/llama.cpp/build/bin/llama-server}" \
              "${LLAMA_XE_SERVER_BIN:-$HOME/llama.cpp/build-opencl/bin/llama-server}"
    do
        _allowed+=("$(readlink -f "$_a" 2>/dev/null || true)")
    done
    while IFS= read -r pid; do
        pid="${pid%$'\r'}"
        [[ -z "$pid" ]] && continue
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        [[ "$pid" == "$$" ]] && continue
        comm=$(cat "/proc/$pid/comm" 2>/dev/null || echo "")
        cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || echo "")
        # A sanctioned server holding the card is expected: skip only if the
        # RESOLVED binary is one of the two above, so a same-named server from any
        # other build path stays foreign and still reports busy.
        exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)
        if [[ -n "$exe" ]]; then
            for _a in "${_allowed[@]}"; do
                [[ -n "$_a" && "$exe" == "$_a" ]] && continue 2
            done
        fi
        # OpenClaw embedding workers are a node/python process, so their exe is an
        # interpreter rather than the worker itself: they are identified by the
        # name in the command line that launched them.
        case "$cmdline" in
            *memory-core-local-embedding-worker*) continue ;;
        esac
        REASONS+=("foreign-app pid=$pid $comm exe=${exe:-unreadable}")
        return 0
    done <<< "$smi_out"
    return 1
}

declared_workload_busy() {
    local _why=""
    # Patterns here name a real artefact — a script PATH or an executable — and
    # never a bare word.  A bare word matches any process whose command line
    # merely contains it: on 2026-09-15 `pgrep -f "llama-bench|autotune"` matched
    # a human's interactive `grep -iE 'llama|autotune'`, this probe reported BUSY,
    # and the watchdog STOPPED a healthy, serving CUDA lane on a free card.  A
    # false BUSY is not the safe direction here: it takes the lane down.
    #
    # Naming the artefact was not enough either.  A pattern only SELECTS candidates
    # by command line; _any_executing_process then proves the process is RUNNING the
    # artefact.  On 2026-09-21 a `cat /usr/local/bin/clear_vram.sh` in an operator's
    # shell was selected by the clear_vram pattern, this probe answered BUSY, and the
    # watchdog stopped the CUDA lane on a free card.  So every call below passes the
    # artefact's FILE NAME alongside its pattern.
    if _any_executing_process 'model_selection_bench\.py' model_selection_bench.py; then
        _why="model_selection_bench"
    fi
    # llama.cpp's bench tool, matched on COMM: a mention in someone's command line
    # cannot produce a comm match, so this one cannot self-match at all.
    if [[ -z "$_why" ]] && pgrep -x llama-bench >/dev/null 2>&1; then
        _why="llama-bench"
    fi
    # A console autotune/bench run — by script path, not by the word "autotune".
    if [[ -z "$_why" ]] \
        && _any_executing_process '/(autotune-model|run-autotune-batch|retune-band-chunk)\.sh' \
               autotune-model.sh run-autotune-batch.sh retune-band-chunk.sh; then
        _why="autotune"
    fi
    # The investigator's path-pinned bench wrapper (~/.local/bin/cuda-llama-bench).
    if [[ -z "$_why" ]] && _any_executing_process '/cuda-llama-bench' cuda-llama-bench; then
        _why="cuda-llama-bench"
    fi
    # A VRAM-clearing helper.
    if [[ -z "$_why" ]] && _any_executing_process 'clear_vram\.sh' clear_vram.sh; then
        _why="clear_vram"
    fi
    if [[ -n "$_why" ]]; then
        REASONS+=("declared:$_why")
        return 0
    fi
    return 1
}

# PIDs of this probe and its ancestry, bounded.  A `pgrep -f` runs against every
# process on the box, including the shell that asked the question, so the probe's
# own chain is excluded from the declared-workload match — otherwise the check can
# answer "busy" because of how the caller happened to be invoked.
_self_chain() {
    local p=$$ n=0
    while [[ "$p" =~ ^[0-9]+$ ]] && (( p > 1 )) && (( n < 8 )); do
        printf '%s\n' "$p"
        p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' \n')
        n=$((n + 1))
    done
}

# 0 when this executable NAME is something that RUNS a script — a shell, an
# interpreter, or a privilege/exec wrapper.  Readers and editors (cat, grep, less,
# tail, head, diff, sed, awk, vim) are deliberately absent: they can only NAME an
# artefact, and reading a name as a run is what took the CUDA lane down.
_is_interpreter() {
    case "$1" in
        bash|sh|dash|zsh|ksh|ash|busybox) return 0 ;;
        python|python[0-9]*|perl|perl5*|ruby) return 0 ;;
        sudo|doas|su|env|runuser|systemd-run) return 0 ;;
    esac
    return 1
}

# 0 when process <pid> is really EXECUTING one of the named artefacts, 1 when it
# merely names one.  Two gates, and neither is a command-line substring:
#
#   (a) the running executable IS the artefact — a compiled bench, or a script the
#       kernel exec'd directly (the kernel then names the process after the script);
#   (b) the running executable is an interpreter/shell/wrapper AND an argv element
#       is a PATH whose file name is the artefact.
#
# Identity comes from /proc/PID/exe, which `exec -a` cannot forge.  For another
# user's process — a root-run clear_vram.sh is the real case — exe is unreadable,
# and the kernel's own /proc/PID/comm is used instead: comm is the executable's
# name, so it keeps the same discipline, and unlike argv a mere mention cannot
# reach it (the comm match is the repo's existing idiom — see pgrep -x llama-bench).
#
# In gate (b) the argv element must be a path, i.e. ONE WORD.  `cat <file>` passed
# to `bash -c` is a single element with a space in it and does not qualify, which is
# exactly the incident this exists for.
_process_executes() {
    local _pid="$1"; shift
    local _name _exe_base _elem
    local -a _argv=()
    _exe_base=$(readlink -f "/proc/$_pid/exe" 2>/dev/null || true)
    _exe_base="${_exe_base##*/}"
    if [[ -z "$_exe_base" ]]; then
        IFS= read -r _exe_base < "/proc/$_pid/comm" 2>/dev/null || true
    fi
    for _name in "$@"; do
        [[ -n "$_exe_base" && "$_exe_base" == "$_name" ]] && return 0
    done
    _is_interpreter "$_exe_base" || return 1
    mapfile -d '' -t _argv < "/proc/$_pid/cmdline" 2>/dev/null || true
    for _elem in "${_argv[@]}"; do
        [[ "$_elem" == *[[:space:]]* ]] && continue
        for _name in "$@"; do
            [[ "${_elem##*/}" == "$_name" ]] && return 0
        done
    done
    return 1
}

# _any_executing_process <pgrep -f pattern> <artefact name>... — 0 when a process
# outside this probe's own process chain is EXECUTING one of the artefacts, 1
# otherwise.  The pattern only SELECTS candidates by command line (cheap, and it
# keeps the artefact deliberately named); _process_executes decides.  Without that
# second gate any process that merely NAMED the artefact — a cat, a grep, a tail —
# was counted as a declared workload and stopped a serving lane (2026-09-21).
_any_executing_process() {
    local _pat="$1"; shift
    local _pid _s _is_self
    local -a _self=()
    mapfile -t _self < <(_self_chain)
    while read -r _pid; do
        [[ "$_pid" =~ ^[0-9]+$ ]] || continue
        _is_self=0
        for _s in "${_self[@]}"; do
            [[ "$_pid" == "$_s" ]] && _is_self=1
        done
        (( _is_self )) && continue
        _process_executes "$_pid" "$@" && return 0
    done < <(pgrep -f "$_pat" 2>/dev/null)
    return 1
}

lock_busy() {
    if [ -f "$BENCH_LOCK" ]; then
        REASONS+=("lock:$BENCH_LOCK")
        return 0
    fi
    return 1
}

cuda_owner_busy() {
    # Signal 5: another agent owns the CUDA card (the investigator pipeline's
    # flock, taken for the whole of a local-model run).  Path precedence mirrors
    # investigator/config/paths.py:gpu_lock_path() EXACTLY, and the probe is
    # existence-gated — `flock -n` also fails on a MISSING path, so reading a
    # failed probe as "held" would report busy forever on a box that never took
    # the lock.
    local _lock="${INVESTIGATOR_GPU_LOCK:-${INVESTIGATOR_PRODUCTION_OUTPUT:-$HOME/investigator/production}/runtime/gpu.lock}"
    [[ -e "$_lock" ]] || return 1
    if flock -n "$_lock" -c true 2>/dev/null; then
        return 1   # we took it, so nobody else holds it
    fi
    REASONS+=("cuda-owned-by-another-run pid=$(tr -dc '0-9' < "$_lock" 2>/dev/null || true)")
    return 0
}

busy() {
    util_busy || foreign_apps_busy || declared_workload_busy || lock_busy || cuda_owner_busy
}

emit() {
    local state="$1" reasons=""
    # An empty REASONS array expanded to a lone empty string, emitting the invalid
    # reason reasons:[""] on the free path; build the list only when non-empty.
    if (( ${#REASONS[@]} > 0 )); then
        reasons=$(printf '"%s",' "${REASONS[@]}" | sed 's/,$//')
    fi
    if [ "${JSON_OUT:-0}" = "1" ]; then
        printf '{"busy":%s,"reasons":[%s]}\n' "$state" "$reasons"
    fi
    log "busy=$state reasons=${REASONS[*]:-none}"
}

JSON_OUT=0
case "${1:-}" in
    --json) JSON_OUT=1 ;;
    --wait)
        JSON_OUT=1
        WAIT_SECS="${2:-300}"
        waited=0
        while [ "$waited" -lt "$WAIT_SECS" ]; do
            REASONS=()
            if ! busy; then emit false; exit 0; fi
            sleep 5
            waited=$((waited + 5))
        done
        emit true
        exit 1
        ;;
esac

REASONS=()
if busy; then
    emit true
    exit 1
fi
emit false
exit 0

# end of file
