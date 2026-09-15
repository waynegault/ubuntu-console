#!/home/linuxbrew/.linuxbrew/bin/bash
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 14
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
#   (c) rows fail CONSECUTIVELY (MAX_CONSECUTIVE_FAILURES), which is the batch's
#       own corroboration that something is wrong with the run.
# The WSL2 GPU health detector WARNS rather than halting (changed 2026-09-15,
# Wayne): its dxg EOVERFLOW count tracks HOST state, not this batch's activity —
# last boot it read 22 while the ledger read 18, and at 20 cycles this boot it
# still read 4.  Gating on it cost one WSL restart per row while measuring nothing.
# On halt it prints the remaining models and the exact resume command. The only
# real fix for an exhausted adapter is `wsl --shutdown` from Windows; the cycle
# counter is namespaced by boot ID, so a restart starts a fresh counter.
#
# Exit codes are a contract shared with autotune-model.sh (docs/llm.md):
#   0  every requested row certified
#   1  at least one row failed
#   3  stopped for the ADAPTER — the cycle budget, or a row that exited 3 for
#      consecutive stalls.  Outranks 1: it is the case that needs a WSL restart.
#   (a chunk-cap or foreign-owner halt exits 0 or 1 by whether rows failed)
#
# Timing estimate per model (RTX 3050 4GB, autotune v4). The figures date from
# 2026-06, when the model drive was still a Windows mount — it became native ext4
# on 2026-08-16 — so they are likely pessimistic today:
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
# Only an exhausted adapter (cycle budget) or a degraded paravirtualization is
# fixed by restarting WSL — and a restart also clears the boot-scoped cycle
# ledger.  The footer therefore distinguishes the halt reasons instead of
# printing "wsl --shutdown" for a deliberate chunk-cap stop (2026-09-15).
HALT_NEEDS_WSL_RESTART=0
# A row that FAILED is still owed a run, and the batch must not exit 0 when it
# certified nothing: chunk 2 of the 2026-09-15 re-tune logged `batch exit=0` on a
# 2-of-2 failure, which read as progress.  Both are tracked here.
FAILED_ROWS=()
TUNED_COUNT=0
CONSECUTIVE_FAILURES=0
# Fail-fast (Wayne, 2026-09-10): after this many consecutive row failures, stop and
# fix the cause instead of grinding on — consecutive failures mean something is
# broken, and every further row spends GPU time reproducing it.  Chunk 2 is the
# shape: two rows, both refused on a baseline no row could have passed.
MAX_CONSECUTIVE_FAILURES="${MAX_CONSECUTIVE_FAILURES:-2}"
# One warning per batch is enough for a host-state flag that no longer halts.
_GPU_HEALTH_WARNED=0
# The batch's exit code is a contract (docs/llm.md, and autotune-model.sh's own
# exit 3): 3 = stopped for the ADAPTER, 1 = rows failed, 0 = clean.  A budget halt
# outranks a failed row because it is the condition that needs a WSL restart and it
# explains any failures alongside it.
HALT_EXIT=0

# --- WSL2 dxgkrnl cycle-budget knobs ---
# The leak is proportional to the number of CUDA context create/destroy cycles;
# a batch that runs too long in one WSL session hangs the VM. The ledger is
# namespaced by boot ID — a WSL restart is the only leak reset, and it changes
# the boot ID — and lives in /dev/shm, NOT /tmp: /tmp is cleaned aggressively on
# this box, and a mid-boot clean would silently reset the budget while the leak
# persists (2026-09-14). autotune-model.sh reads the same file and enforces the
# same budget, so a batch and a directly-driven row share one ledger. Override
# via env to tune for a different GPU / WSL build.
_AUTOTUNE_BOOT_ID="$(tr -d '-' < /proc/sys/kernel/random/boot_id 2>/dev/null | cut -c1-12)"
CUDA_CYCLE_FILE="${CUDA_CYCLE_FILE:-/dev/shm/autotune-cuda-cycles-${_AUTOTUNE_BOOT_ID:-unknown}}"
CUDA_CYCLE_BUDGET="${CUDA_CYCLE_BUDGET:-60}"        # CUDA context create/destroy cycles before halt
# The 60 default (was 250) reflects the measured degradation knee: ~26
# launch/kill cycles at 109K ctx collapsed tps ~16 -> ~3.8 (2026-09-05). With
# the ctx probe now capped at ~2x the KV-fit estimate (~54K), each cycle leaks
# ~2x less VA, so ~60 is a safe margin below the ~70-100-cycle threshold at
# that ctx. Override via env for a different GPU / WSL build.
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
    local before="" after=""
    before=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader 2>/dev/null | awk '{print $1}')
    if ! [[ "$before" =~ ^[0-9]+$ ]]; then
        # Empty operands compare equal in bash, which would look like a
        # completed drain after a single sleep — wait the full window instead.
        echo "WARN: nvidia-smi returned no VRAM reading; waiting the full drain window" >&2
        before=""
    fi
    # CUDA-scoped llama kill — never the Xe fleet / persistent units.
    if declare -f __llm_kill_cuda_llama_servers &>/dev/null; then
        __llm_kill_cuda_llama_servers || true
    else
        echo "WARN: __llm_kill_cuda_llama_servers not loaded — skipping llama cleanup" >&2
    fi
    local waited=0
    while [[ $waited -lt 15 ]]; do
        sleep 1
        waited=$((waited + 1))
        after=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader 2>/dev/null | awk '{print $1}')
        # Break only on a strict drop; "unchanged" means the server is not
        # actually gone; an unreadable value means keep waiting.
        if [[ "$after" =~ ^[0-9]+$ ]] && [[ -n "$before" ]] && (( after < before )); then
            break
        fi
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
# wsl_gpu_health_suspect — 0 when the dxgkrnl EOVERFLOW count is HIGH.
#
# A WARNING signal, not a verdict (was a hard gate until 2026-09-15).  The
# investigator repo's check_wsl_gpu.py counts the dmesg reserve_gpu_va EOVERFLOW
# signature, and its own module says to treat a high count as "suspect,
# corroborate with tps" — while this batch used it as a hard halt.  The measured
# data does not support a hard halt: the count tracks host state, not our own
# activity (22 at 18 cycles one boot; 4 at 20 cycles the next).  The batch's
# corroboration is the tps it already measures: a genuinely degraded adapter shows
# up as rows that FAIL, which is what MAX_CONSECUTIVE_FAILURES halts on.
# A real degradation is still fixed only by a WSL restart.
#------------------------------------------------------------------------------
wsl_gpu_health_suspect() {
    local script="$HOME/investigator/scripts/check_wsl_gpu.py" rc
    [ -f "$script" ] || return 1
    sh "$script" >/dev/null 2>&1
    rc=$?
    [ "$rc" -eq 1 ]
}

# Initial drain — skipped when another agent owns the card: there is nothing of
# ours to reap, and waiting for a foreign holder's VRAM to drop cannot succeed.
if declare -f __llm_gpu_foreign_owner &>/dev/null && __llm_gpu_foreign_owner; then
    echo "GPU owned by another agent's run (investigator GPU lock) — skipping the initial drain"
else
    drain_vram
fi

for ((i = 0; i < TOTAL; i++)); do
    m="${MODEL_ARRAY[$i]}"

    # Halt gate BEFORE the next model: cycle budget + chunk size.
    _cyc=$(cuda_cycles)
    if [[ "$_cyc" =~ ^[0-9]+$ ]] && [[ "$_cyc" -ge "$CUDA_CYCLE_BUDGET" ]]; then
        HALT_REASON="CUDA context-cycle budget reached (${_cyc} >= ${CUDA_CYCLE_BUDGET})"
        HALT_EXIT=3
        HALT_NEEDS_WSL_RESTART=1
        break
    fi
    if [[ "$MAX_MODELS_PER_CHUNK" -gt 0 && "$COUNT" -ge "$MAX_MODELS_PER_CHUNK" ]]; then
        HALT_REASON="chunk size reached (${MAX_MODELS_PER_CHUNK} models this WSL session)"
        break
    fi
    # Exclusivity bridge (BENCH-GPU-EXCLUSIVITY-001): another agent can own the
    # card through the investigator's flock.  The cleanup helper honours that
    # lock, so nothing would be killed — but with the card still held every row
    # would fail its VRAM baseline after a wasted spawn.  Halt up front and let
    # the standard footer print the real resume command.
    if declare -f __llm_gpu_foreign_owner &>/dev/null && __llm_gpu_foreign_owner; then
        HALT_REASON="GPU owned by another agent's run (investigator GPU lock, pid $(__llm_gpu_lock_holder 2>/dev/null || true))"
        break
    fi

    COUNT=$((COUNT + 1))
    printf '\n[%d/%d] model #%s (cyc %s/%s) ... ' "$COUNT" "$TOTAL" "$m" "$(cuda_cycles)" "$CUDA_CYCLE_BUDGET"
    _row_rc=0
    bash "$HOME/ubuntu-console/scripts/autotune-model.sh" "$m" 2>&1 || _row_rc=$?
    if (( _row_rc == 0 )); then
        printf 'done\n'
        TUNED_COUNT=$((TUNED_COUNT + 1))
        CONSECUTIVE_FAILURES=0
    else
        printf 'failed (exit %s)\n' "$_row_rc"
        FAILED_ROWS+=("$m")
        CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
        # autotune-model.sh exits 3 for the ADAPTER backstops (the cycle budget, or
        # CUDA_DEGRADE_CONSECUTIVE_STALLS launches alive but never healthy).  One row
        # carrying that signature is enough to stop — it names the adapter, not the
        # model, and a WSL restart is the only fix.  docs/llm.md states this as a
        # contract ("both ... halt (exit 3)"); the batch used to swallow the code and
        # count the row as an ordinary failure.
        if (( _row_rc == 3 )); then
            HALT_REASON="model #${m} exited 3 — the adapter backstop fired (cycle budget or consecutive stalls)"
            HALT_EXIT=3
            HALT_NEEDS_WSL_RESTART=1
            break
        fi
    fi
    drain_vram
    # WARN, do not halt: see the header.  Said once per batch, loudly.
    if (( _GPU_HEALTH_WARNED == 0 )) && wsl_gpu_health_suspect; then
        echo "WARN: the WSL2 GPU health probe reports a high dxg EOVERFLOW count." >&2
        echo "      That count tracks HOST state, not this batch's activity, so it is a SUSPECT flag and not a halt." >&2
        echo "      Continuing. A genuinely degraded adapter shows up as rows that FAIL with collapsing tps." >&2
        _GPU_HEALTH_WARNED=1
    fi
    if (( MAX_CONSECUTIVE_FAILURES > 0 && CONSECUTIVE_FAILURES >= MAX_CONSECUTIVE_FAILURES )); then
        HALT_REASON="${CONSECUTIVE_FAILURES} consecutive row failures — stopping to fix the cause (a degraded adapter is one candidate: check the dxg count and the tps in the failed rows)"
        break
    fi
done

echo ""

# ---------------------------------------------------------------------------
# __rab_footer <halt_reason> <needs_wsl_restart> — print the summary, and return
# the exit code the batch should use.
#
# Two contracts live here, both broken before 2026-09-15:
#   * a row that FAILED is still owed a run, and the un-attempted slice starts at
#     COUNT — so failed rows must be prepended or the resume line silently skips
#     them (chunk 2 printed "remaining models: 18 27" while 5 and 7 had failed and
#     still needed doing);
#   * a batch that certified nothing must not return 0 (chunk 2 logged
#     `batch exit=0` on a 2-of-2 failure, which read as progress in the log).
#
# It reads global state rather than arguments for the row bookkeeping, so the
# contract can be exercised without a GPU (see tests/unit/12-gpu-exclusivity.bats).
# ---------------------------------------------------------------------------
__rab_footer() {
    local _halt_reason="$1" _needs_restart="$2"
    # Failed rows FIRST: they are owed a run.
    REMAINING=("${FAILED_ROWS[@]}" "${MODEL_ARRAY[@]:COUNT}")

    if [[ -n "$_halt_reason" ]]; then
        echo "=== HALTED: ${_halt_reason} ==="
    else
        echo "=== finished: ${TUNED_COUNT}/${TOTAL} tuned, ${#FAILED_ROWS[@]} failed ==="
    fi
    if [[ ${#FAILED_ROWS[@]} -gt 0 ]]; then
        echo "  FAILED (still untuned, and NOT counted as done): ${FAILED_ROWS[*]}"
    fi
    if [[ ${#REMAINING[@]} -gt 0 ]]; then
        echo "  remaining models: ${REMAINING[*]}"
        if [[ "$_needs_restart" == 1 ]]; then
            echo "  resume:  wsl --shutdown (from Windows), then:"
        else
            echo "  resume:"
        fi
        echo "    bash ~/ubuntu-console/scripts/run-autotune-batch.sh ${REMAINING[*]}"
        echo "  (or run with no args to auto-resume every still-untuned model)"
    fi

    if [[ "${HALT_EXIT:-0}" != "0" ]]; then
        return "$HALT_EXIT"
    fi
    (( ${#FAILED_ROWS[@]} > 0 )) && return 1
    return 0
}

__rab_footer "$HALT_REASON" "$HALT_NEEDS_WSL_RESTART"
rc=$?
exit "$rc"

# end of file marker
