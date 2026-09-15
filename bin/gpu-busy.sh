#!/usr/bin/env bash
# gpu-busy.sh — reliable "CUDA card actually in use" detector for local-llm gating.
# Version: 1.2.0 (2026-09-15: tracked in this repo; another run's GPU ownership
#          lock now counts as busy — signal 5)
# Module Version: 1
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
#   2. Foreign compute-app PIDs — a process other than llama-server / embedding
#      workers holds a CUDA context (someone else is loaded on the GPU)
#   3. Declared GPU workloads — known GPU-hungry processes are alive
#      (model_selection_bench, autotune, llama-bench, clear_vram)
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

log() { [ -n "$LOG_FILE" ] && printf '%s [gpu-busy] %s\n' "$(date -Iseconds)" "$*" >> "$LOG_FILE"; }

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
        [ -z "$s" ] && s=0
        [ "$s" -gt "$max_util" ] && max_util=$s
        [ "$s" -ge "$UTIL_THRESHOLD" ] && { REASONS+=("util=${s}%>=${UTIL_THRESHOLD}%"); return 0; }
        sleep "$SAMPLE_INTERVAL"
    done
    return 1
}

foreign_apps_busy() {
    local pid comm cmdline smi_out smi_rc
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
    while IFS= read -r pid; do
        pid="${pid%$'\r'}"
        [ -z "$pid" ] && continue
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        [ "$pid" = "$$" ] && continue
        comm=$(cat "/proc/$pid/comm" 2>/dev/null || echo "")
        cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || echo "")
        # Known-good GPU residents: our llama-server + OpenClaw embedding workers
        case "$comm:$cmdline" in
            *llama-server*) continue ;;
            *memory-core-local-embedding-worker*) continue ;;
        esac
        REASONS+=("foreign-app pid=$pid $comm")
        return 0
    done <<< "$smi_out"
    return 1
}

declared_workload_busy() {
    if pgrep -f "model_selection_bench.py" >/dev/null 2>&1; then
        REASONS+=("declared:model_selection_bench")
        return 0
    fi
    if pgrep -f "llama-bench|autotune" >/dev/null 2>&1; then
        REASONS+=("declared:bench/autotune")
        return 0
    fi
    if pgrep -f "clear_vram.sh" >/dev/null 2>&1; then
        REASONS+=("declared:clear_vram")
        return 0
    fi
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
