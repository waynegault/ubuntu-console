#!/usr/bin/env bash
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 1
# ==============================================================================
# retune-band-chunk.sh — run ONE chunk of the threshold-band re-tune.
#
# The row set is whatever the registry's band criterion selects NOW.  Derive it,
# never reuse a written-down list: the registry has been renumbered twice in a
# day (35 rows -> 27, rows deleted from the middle), so a hardcoded table is
# stale by the time it is read.  The criterion is field 17 (the profile-2
# decode-TPS ratio p2_tps/tps) inside [2.5, 9.0]:
#
#   awk -F'|' '$1 ~ /^[0-9]+$/ && $17+0>=2.5 && $17+0<=9.0 {print $1, $2, $17, $25}' \
#       ~/.llm/models.conf
#
# Why a wrapper rather than run-autotune-batch.sh directly:
#   * the batch needs the CUDA lane kept DOWN for the whole chunk.  Between
#     benches the GPU is briefly free, and the watchdog's policy is to start the
#     CUDA lane whenever the GPU is free — which would steal VRAM mid-sweep.
#     That is exactly what the CUDA suspension file is for.
#   * /dev/shm is wiped by a WSL restart, so the suspension file must be re-set
#     after every reboot.  That is the step that is easy to forget, so it lives
#     here next to the run.
#
# The chunk size is small (2 rows) on purpose: the WSL2 dxgkrnl context-cycle
# budget (CUDA_CYCLE_BUDGET=60, boot-scoped) is consumed by every bench spawn,
# and a 7/8B row burns most of a boot's worth.  Halting deliberately at 2 rows
# keeps the run on the safe side of the documented degradation knee.  Set
# MAX_MODELS_PER_CHUNK=0 to let the cycle budget be the only cap.
#
# Usage: retune-band-chunk.sh <row> [row ...]
#   (the batch prints the resume command for the remaining rows when it halts)
# ==============================================================================
set -uo pipefail

_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Same env override and default as bin/llama-watchdog.sh — keep the two in step.
SUSPEND="${LLAMA_WATCHDOG_CUDA_SUSPEND_FILE:-/dev/shm/llama-watchdog-cuda.suspend}"

if [[ $# -eq 0 ]]
then
    echo "usage: $0 <row> [row ...]" >&2
    exit 2
fi

# Cycle ledger, boot-scoped exactly as run-autotune-batch.sh names it (a WSL
# restart is the only leak reset and it changes the boot ID), so this reports the
# same counter the batch enforces.
_autotune_boot_id="$(tr -d '-' < /proc/sys/kernel/random/boot_id 2>/dev/null | cut -c1-12)"
_cycle_file="/dev/shm/autotune-cuda-cycles-${_autotune_boot_id:-unknown}"
cycle_now() { [[ -f "$_cycle_file" ]] && cat "$_cycle_file" 2>/dev/null || echo 0; }

touch "$SUSPEND" || { echo "Cannot set $SUSPEND - refusing to start" >&2; exit 1; }
echo "[retune] CUDA lane suspended for this chunk ($SUSPEND)"
echo "[retune] cycle budget before: $(cycle_now)/60"
echo

MAX_MODELS_PER_CHUNK="${MAX_MODELS_PER_CHUNK:-2}" \
    bash "$_SELF_DIR/run-autotune-batch.sh" "$@"
rc=$?

echo
echo "[retune] batch exit=${rc} ; cycle budget after: $(cycle_now)/60"
echo "[retune] the lane stays suspended until the file is removed (a WSL restart wipes /dev/shm)"
exit "$rc"

# end of file
