#!/usr/bin/env bash
# llama-gpu-clear.sh - Ensure the GPU is cleared before llama-server loads.
# Called as ExecStartPre by llama-server-nvidia.service / llama-server-phi4.service.
# Kills stale llama-server processes (crash orphans holding VRAM) and waits
# for VRAM to drain. Restart-aware: on a crash-recovery start (previous run
# failed) with no orphan to kill, the dead server's VRAM is already being
# released by the driver - use a short grace period instead of the full 30s
# drain wait so recovery isn't delayed.
# AI INSTRUCTION: Increment version on significant changes.
# Module Version: 2
VERSION="1.3.0"   # 1.3.0: honour the investigator GPU lock — never reap a foreign bench.

if [[ "${1:-}" == "--version" || "${1:-}" == "-V" ]]; then
    echo "llama-gpu-clear $VERSION"
    exit 0
fi

set -uo pipefail

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [gpu-clear] $*"; }

# The investigator pipeline holds a cross-process GPU flock for the whole
# duration of a local-model run (pipeline/gpu/_lock.py).  Nothing on the
# console side honoured it, so this ExecStartPre — evictor #1 in the
# investigator's own list (BENCH-GPU-EXCLUSIVITY-001) — reaped a foreign
# bench's llama-server mid-run.  Deliberately a local copy of
# scripts/11d-llm-gpu.sh::__llm_gpu_lock_path/__llm_gpu_foreign_owner: this
# script runs as an ExecStartPre and must not depend on the console's module
# tree, which is why it stands alone at all.  tests/unit/12-gpu-exclusivity.bats
# asserts the two copies agree, so they cannot drift.
#
# Path precedence mirrors config/paths.gpu_lock_path() exactly.  The probe is
# existence-gated: `flock -n` also fails on a missing path, and reading that as
# "held" would stop the lane from ever starting on a box that never took it.
_inv_gpu_lock_path() {
    printf '%s\n' "${INVESTIGATOR_GPU_LOCK:-${INVESTIGATOR_PRODUCTION_OUTPUT:-$HOME/investigator/production}/runtime/gpu.lock}"
}

_inv_gpu_foreign_owner() {
    local _lock_path
    _lock_path=$(_inv_gpu_lock_path)
    [[ -e "$_lock_path" ]] || return 1
    flock -n "$_lock_path" -c true 2>/dev/null && return 1
    return 0
}

# 1. Detect recovery context: did the previous run of the calling unit end
#    in a failure (crash/signal/timeout/...) rather than a clean stop?
#    During ExecStartPre the unit's own process isn't running yet, so Result
#    still reflects the last completed run.
result=""
for unit in llama-server-nvidia.service llama-server-phi4.service; do
    r=$(systemctl --user show "$unit" -p Result --value 2>/dev/null | tr -d ' \n' || true)
    case "$r" in
        exit-code|signal|core-dump|timeout|watchdog|resources|oom-kill|start-limit-hit)
            result="$r"
            break
            ;;
    esac
done
case "$result" in
    "")
        RECOVERY=0
        ;;
    *)
        RECOVERY=1
        log "recovery start (previous run: $result)"
        ;;
esac

# 2. Kill stale CUDA llama-server processes. Scoped to the CUDA build and its
#    per-role launchers (llama-nv / llama-phi4 / llama-bench) so the Xe fleet
#    (llama-xe / llama-embed, OpenCL build) is never touched. Processes are
#    matched on their executable, not command line: a shell can mention one of
#    these paths in its arguments, but its executable is still bash.
_cuda_stale_pids() {
    local pid exe
    for pid in /proc/[0-9]*; do
        exe=$(readlink -f "/proc/${pid#/proc/}/exe" 2>/dev/null) || continue
        case "$exe" in
            */llama.cpp/build/bin/llama-server|*/.local/bin/llama-nv|*/.local/bin/llama-phi4|*/.local/bin/llama-bench)
                printf '%s\n' "${pid#/proc/}"
                ;;
        esac
    done
}

GPU_HELD=0
if _inv_gpu_foreign_owner; then
    # The card belongs to another agent's run: its llama-server is not a stale
    # orphan of ours, and reaping it would destroy a bench in flight.  The lane
    # still starts — whether it should run at all is the watchdog's busy-GPU
    # policy, not this script's to overrule.
    GPU_HELD=1
    STALE=""
    log "GPU lock held by another agent's run - NOT reaping CUDA llama processes"
else
    STALE=$(_cuda_stale_pids || true)
    if [[ -n "$STALE" ]]; then
        log "stale CUDA llama-server processes found: $STALE - sending SIGTERM"
        read -r -a stale_pids <<< "$STALE"
        kill -TERM "${stale_pids[@]}" 2>/dev/null || true
        sleep 3
        STALE2=$(_cuda_stale_pids || true)
        if [[ -n "$STALE2" ]]; then
            log "still alive after SIGTERM: $STALE2 - sending SIGKILL"
            read -r -a stale_pids <<< "$STALE2"
            kill -KILL "${stale_pids[@]}" 2>/dev/null || true
            sleep 1
        fi
    else
        log "no stale CUDA llama-server processes"
    fi
fi

# 3. Wait for VRAM to drain (nvidia-smi memory.used < 100 MiB). Full 30s wait
#    on clean starts. On a crash-recovery start with no orphan process, the
#    previous server is already gone, so give the driver a short grace period.
if command -v nvidia-smi >/dev/null 2>&1; then
    MAX_ITER=15
    if [[ "$GPU_HELD" -eq 1 ]]; then
        # A foreign holder's VRAM will not drain however long we wait, so spend
        # the full window only on our own orphans.
        MAX_ITER=3
        log "foreign GPU holder - short VRAM grace (${MAX_ITER} iters)"
    elif [[ "$RECOVERY" -eq 1 && -z "${STALE:-}" ]]; then
        MAX_ITER=3
        log "recovery start with no stale process - short VRAM grace (${MAX_ITER} iters)"
    fi
    for i in $(seq 1 "$MAX_ITER"); do
        USED=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
        if [[ -z "$USED" || "$USED" -lt 100 ]]; then
            log "VRAM clear: ${USED:-unknown} MiB used (iter $i)"
            exit 0
        fi
        sleep 2
    done
    log "WARN: VRAM still at ${USED} MiB after $(( MAX_ITER * 2 ))s - proceeding anyway"
else
    log "nvidia-smi not available - skipping VRAM wait"
fi

exit 0

# end of file