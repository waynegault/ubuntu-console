#!/home/linuxbrew/.linuxbrew/bin/bash
# shellcheck disable=SC1091
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 4
#===============================================================================
# run-autotune-batch.sh — Run autotune sequentially on all untuned models
#
# Usage: run-autotune-batch.sh [model nums...]
#   Default: all models where field 18 (autotuned) != "yes"
#
# Interleaves a VRAM-aware drain between each model to prevent OOM cascade.
# Estimates total run time and reports progress.
#
# WSL2 dxgkrnl guard (2026-09-05): repeated CUDA context create/destroy cycles
# leak GPU VA reservations and degrade the adapter until the WSL VM hangs (which
# drops VS Code's remote connection and kills the batch mid-model). This batch
# now halts GRACEFULLY — instead of crashing WSL — when any of:
#   (a) the CUDA context-cycle budget is exceeded (CUDA_CYCLE_BUDGET),
#   (b) a chunk size is reached (MAX_MODELS_PER_CHUNK), or
#   (c) the WSL2 GPU health detector reports degradation.
# On halt it prints the remaining models and the exact resume command. The only
# real fix for an exhausted adapter is `wsl --shutdown` from Windows; the cycle
# counter is namespaced by boot ID, so a restart starts a fresh counter.
#
# Timing estimate per model (RTX 3050 4GB, WSL2 NTFS mount, autotune v4):
#   quick: ctx discovery + beam search + filled-cache certification
#   <2GB models:  ~20-30 min (8 ctx × 2-3 combos + beam + cert)
#   >=2GB models: ~30-50 min (1 combo + beam + ngl/KV sweep + filled cert)
#   39 models total:  roughly 10-20 hours
#===============================================================================

set -uo pipefail

_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$_SELF_DIR/.." || exit 1
source env.sh 2>/dev/null || { echo "Failed to source env.sh"; exit 1; }

# Parse model list
if [ $# -eq 0 ]; then
    MODELS=$(awk -F'|' '$1 ~ /^[0-9]+$/ && $18 != "yes" {print $1}' "$LLM_REGISTRY" | sort -n | tr '\n' ' ')
else
    MODELS="$*"
fi

read -r -a MODEL_ARRAY <<< "$MODELS"
TOTAL=${#MODEL_ARRAY[@]}
COUNT=0
HALT_REASON=""

# --- WSL2 dxgkrnl cycle-budget knobs ---
# The leak is proportional to the number of CUDA context create/destroy cycles;
# a batch that runs too long in one WSL session hangs the VM. The counter file
# is namespaced by boot ID (a WSL restart is the only leak reset, and it changes
# the boot ID). Override via env to tune for a different GPU / WSL build.
_AUTOTUNE_BOOT_ID="$(tr -d '-' < /proc/sys/kernel/random/boot_id 2>/dev/null | cut -c1-12)"
CUDA_CYCLE_FILE="${CUDA_CYCLE_FILE:-/tmp/autotune-cuda-cycles-${_AUTOTUNE_BOOT_ID:-unknown}}"
CUDA_CYCLE_BUDGET="${CUDA_CYCLE_BUDGET:-250}"       # CUDA context create/destroy cycles before halt
MAX_MODELS_PER_CHUNK="${MAX_MODELS_PER_CHUNK:-0}"   # 0 = unlimited; else halt after this many models
export CUDA_CYCLE_FILE

cuda_cycles() {
    [[ -f "$CUDA_CYCLE_FILE" ]] && cat "$CUDA_CYCLE_FILE" 2>/dev/null || echo 0
}

echo "model autotune all"
echo "  models: ${TOTAL} untuned"
echo "  cycle budget: ${CUDA_CYCLE_BUDGET} (current $(cuda_cycles))"
echo "  start:  $(date '+%H:%M')"
echo ""

#------------------------------------------------------------------------------
# VRAM drain — poll total GPU memory, not process list
# (WSL2's nvidia-smi process listing doesn't expose process names)
#------------------------------------------------------------------------------
drain_vram() {
    local before after
    before=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader 2>/dev/null | awk '{print $1}')
    # CUDA-scoped llama kill — never the Xe fleet / persistent units.
    if declare -f __llm_kill_cuda_llama_servers &>/dev/null; then
        __llm_kill_cuda_llama_servers || true
    else
        echo "WARN: __llm_kill_cuda_llama_servers not loaded — skipping llama cleanup" >&2
    fi
    local waited=0
    while [ "$waited" -lt 15 ]; do
        sleep 1
        waited=$((waited + 1))
        after=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader 2>/dev/null | awk '{print $1}')
        [[ "$after" -le "$before" ]] && break
    done
    waited=0
    while [ "$waited" -lt 10 ]; do
        if ! ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq '(^|:)8081$'; then
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done
}

#------------------------------------------------------------------------------
# WSL2 GPU health — HARD gate (2026-09-05): returns non-zero when degraded so
# the batch halts instead of warning and continuing into a VM hang. The
# investigator repo's check_wsl_gpu.py reads the dmesg reserve_gpu_va EOVERFLOW
# signature; when degraded, measured tps collapses and llama-server may die
# silently mid-run. The only fix is a WSL restart (wsl --shutdown).
#------------------------------------------------------------------------------
check_wsl_gpu_health() {
    local script="$HOME/investigator/scripts/check_wsl_gpu.py" rc
    [ -f "$script" ] || return 0
    sh "$script" >/dev/null 2>&1
    rc=$?
    if [ "$rc" -eq 1 ]; then
        echo "HALT: WSL2 GPU paravirtualization degraded — measured tps may collapse and llama-server may die silently." >&2
        echo "      Restart WSL (wsl --shutdown), then re-run the remaining models below." >&2
        return 1
    fi
    return 0
}

# Initial drain
drain_vram

for ((i = 0; i < TOTAL; i++)); do
    m="${MODEL_ARRAY[$i]}"

    # Halt gate BEFORE the next model: cycle budget + chunk size.
    _cyc=$(cuda_cycles)
    if [[ "$_cyc" =~ ^[0-9]+$ ]] && [[ "$_cyc" -ge "$CUDA_CYCLE_BUDGET" ]]; then
        HALT_REASON="CUDA context-cycle budget reached (${_cyc} >= ${CUDA_CYCLE_BUDGET})"
        break
    fi
    if [[ "$MAX_MODELS_PER_CHUNK" -gt 0 && "$COUNT" -ge "$MAX_MODELS_PER_CHUNK" ]]; then
        HALT_REASON="chunk size reached (${MAX_MODELS_PER_CHUNK} models this WSL session)"
        break
    fi

    COUNT=$((COUNT + 1))
    printf '\n[%d/%d] model #%s (cyc %s/%s) ... ' "$COUNT" "$TOTAL" "$m" "$(cuda_cycles)" "$CUDA_CYCLE_BUDGET"
    if bash "$HOME/ubuntu-console/scripts/autotune-model.sh" "$m" 2>&1; then
        printf 'done\n'
    else
        printf 'failed\n'
    fi
    drain_vram
    if ! check_wsl_gpu_health; then
        HALT_REASON="WSL2 GPU paravirtualization degraded"
        break
    fi
done

echo ""

if [[ -n "$HALT_REASON" ]]; then
    REMAINING=("${MODEL_ARRAY[@]:COUNT}")
    echo "=== HALTED: ${HALT_REASON} ==="
    if [[ ${#REMAINING[@]} -gt 0 ]]; then
        echo "  remaining models: ${REMAINING[*]}"
        echo "  resume:  wsl --shutdown (from Windows), then:"
        echo "    bash ~/ubuntu-console/scripts/run-autotune-batch.sh ${REMAINING[*]}"
        echo "  (or run with no args to auto-resume every still-untuned model)"
    fi
else
    echo "=== done: ${TOTAL} models tuned ==="
fi

# end of file marker
