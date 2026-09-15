#!/usr/bin/env bash
# llama-gpu-clear.sh - Ensure the GPU is cleared before llama-server loads.
# Called as ExecStartPre by llama-cuda-llama32-3b-chat.service (the CUDA lane).
# Kills stale llama-server processes (crash orphans holding VRAM) and waits
# for VRAM to drain. Restart-aware: on a crash-recovery start (previous run
# failed) with no orphan to kill, the dead server's VRAM is already being
# released by the driver - use a short grace period instead of the full 30s
# drain wait so recovery isn't delayed.
# AI INSTRUCTION: Increment version on significant changes.
# Module Version: 5
VERSION="1.4.1"   # 1.4.1: drop the retired phi4 lane's unit and launcher from the recovery/evict lists.

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
#
#    One unit calls this script (the CUDA chat lane), so it is read directly.
#    Only a failure Result sets RECOVERY=1: a clean `success` is not a recovery
#    start, and the crash-recovery short grace period must not apply to it.
_unit_result=$(systemctl --user show llama-cuda-llama32-3b-chat.service -p Result --value 2>/dev/null | tr -d ' \n' || true)
case "$_unit_result" in
    exit-code|signal|core-dump|timeout|watchdog|resources|oom-kill|start-limit-hit)
        RECOVERY=1
        log "recovery start (previous run: $_unit_result)"
        ;;
    *)
        RECOVERY=0
        ;;
esac

# 2. Kill stale CUDA-card llama-server processes.
#
#    CARD DISCIPLINE: match the CUDA build trees and CUDA launchers, and never
#    touch the Xe fleet.  The two cards are independent — clearing this one must
#    leave the other serving.
#
#      CUDA card: llama.cpp/build/         (LLAMA_SERVER_BIN; cuda-llama-server,
#                                           cuda-llama-bench)
#                 llama.cpp/build-cuda*/   (llama-server-cuda)
#      Xe card:   llama.cpp/build-opencl*/ (xe-llama-server, xe-llama-embed)
#                 — matched only to be explicitly skipped below.
#
#    Matched on the executable, not the command line: a shell can mention one of
#    these paths in its arguments, but its executable is still bash.
#
#    Deliberately NOT matched: ~/.local/opt/llama.cpp/*/bin/llama-server (the
#    plain `llama-server` on PATH).  Nothing records which card that older build
#    serves, so reaping it would be guessing about the card.  See the card map in
#    docs/llm.md.
_cuda_stale_pids() {
    local pid exe
    for pid in /proc/[0-9]*; do
        exe=$(readlink -f "/proc/${pid#/proc/}/exe" 2>/dev/null) || continue
        case "$exe" in
            # The Xe card — never touched, whichever CUDA lane is being cleared.
            */llama.cpp/build-opencl*/bin/llama-server|*/.local/bin/xe-llama-server|*/.local/bin/xe-llama-embed)
                continue ;;
            # The CUDA card.
            */llama.cpp/build/bin/llama-server|*/llama.cpp/build-cuda*/bin/llama-server)
                printf '%s\n' "${pid#/proc/}" ;;
            */.local/bin/cuda-llama-server|*/.local/bin/cuda-llama-bench|*/.local/bin/llama-server-cuda)
                printf '%s\n' "${pid#/proc/}" ;;
        esac
    done
}

if _inv_gpu_foreign_owner; then
    # REFUSE. Only ever one LLM on the CUDA card: if another agent's run owns it,
    # this unit must not start at all.  Starting anyway would put a second
    # llama-server on a 4 GB card, and skipping only the reap (the earlier
    # behaviour) was not enough — the card would be doubly loaded.
    #
    # Exiting non-zero fails the ExecStartPre, so systemd does not start the
    # unit.  The watchdog will not fight it either: it treats a foreign owner as
    # "card busy" (bin/gpu-busy.sh), so it stands down instead of restarting, and
    # the lane returns by itself once the lock is released.
    log "CUDA card is owned by another run (investigator GPU lock) - NOT starting this lane"
    log "  remedy: wait for the holder to finish, or stop it deliberately; do not force-start"
    exit 1
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
    if [[ "$RECOVERY" -eq 1 && -z "${STALE:-}" ]]; then
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