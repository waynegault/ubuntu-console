#!/home/linuxbrew/.linuxbrew/bin/bash
# shellcheck disable=SC1091
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 2
#===============================================================================
# run-autotune-batch.sh — Run autotune sequentially on all untuned models
#
# Usage: run-autotune-batch.sh [model nums...]
#   Default: all models where field 18 (autotuned) != "yes"
#
# Interleaves a VRAM-aware drain between each model to prevent OOM cascade.
# Estimates total run time and reports progress.
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

TOTAL=$(echo "$MODELS" | wc -w)
COUNT=0

echo "model autotune all"
echo "  models: ${TOTAL} untuned"
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

# Initial drain
drain_vram

for m in $MODELS; do
    COUNT=$((COUNT + 1))
    printf '\n[%d/%d] model #%s ... ' "$COUNT" "$TOTAL" "$m"
    if bash "$HOME/ubuntu-console/scripts/autotune-model.sh" "$m" 2>&1; then
        printf 'done\n'
    else
        printf 'failed\n'
    fi
    drain_vram
done

echo ""
echo "=== done: ${TOTAL} models tuned ==="

# end of file marker
