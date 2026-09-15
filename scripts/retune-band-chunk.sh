#!/usr/bin/env bash
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 4
# ==============================================================================
# retune-band-chunk.sh — run ONE chunk of the threshold-band re-tune.
#
# The row set is whatever the registry's band criterion selects NOW.  Derive it,
# never reuse a written-down list: the registry has been renumbered twice in a
# day (35 rows -> 27, rows deleted from the middle), so a hardcoded table is
# stale by the time it is read.  The criterion is field 17 — the certified decode
# `tps` — inside [2.5, 9.0]: rows near the TPS floor, where the ~10% measurement
# error the bench carries is enough to flip role admission.  (Corrected
# 2026-09-15: this header called field 17 "the p2_tps/tps ratio", which it never
# was.)
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
#   * the suspension is scoped to a CHUNK and released on the way out.  It used
#     to be left behind, which held the CUDA lane down for as long as nobody
#     remembered to delete the file — the same "silently down" failure the flag
#     exists to prevent.  If a bench lock survived a failed batch, the watchdog
#     still holds the lane down on its own.
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

# The CUDA lane this chunk needs down.  The same unit bin/llama-watchdog.sh owns
# as CUDA_UNIT — a test asserts the two agree, so the name cannot drift apart.
CUDA_LANE_UNIT="${LLAMA_CUDA_LANE_UNIT:-llama-cuda-llama32-3b-chat.service}"

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

# The suspension file only tells the WATCHDOG to stand the lane down, and the
# watchdog runs on a 300s timer — so for up to five minutes the lane still holds
# ~3.5 GB of the 4 GB card.  The batch's own drain will not evict it either: a
# systemd unit's server is PROTECTED there by design, so it is never reaped.  The
# result is rows that burn on "VRAM baseline not cleared" and measure nothing, which
# is exactly what chunk 2 did (2026-09-15: rows 5 and 7, 3506 MiB still held,
# ledger 0/60).  So stand the lane down HERE, and refuse to start a chunk if the
# card cannot be freed.
release_lane() {
    if rm -f "$SUSPEND" 2>/dev/null; then
        echo "[retune] CUDA lane released ($SUSPEND removed) - the watchdog may start it again"
    else
        echo "[retune] WARNING: could not remove $SUSPEND - the CUDA lane stays down" >&2
    fi
}

if systemctl --user is-active --quiet "$CUDA_LANE_UNIT" 2>/dev/null; then
    echo "[retune] stopping $CUDA_LANE_UNIT (the suspension file alone leaves it up until the watchdog's next tick)"
    systemctl --user stop "$CUDA_LANE_UNIT" 2>/dev/null || true
fi

# Wait for the lane to actually be down (systemd stop is not instant: the server
# unwinds its CUDA context first, which is the whole reason the card is not free
# the moment the unit is stopped).
_waited=0
while (( _waited < 60 ))
do
    systemctl --user is-active --quiet "$CUDA_LANE_UNIT" 2>/dev/null || break
    sleep 5
    _waited=$((_waited + 5))
done

if systemctl --user is-active --quiet "$CUDA_LANE_UNIT" 2>/dev/null; then
    echo "[retune] REFUSING: $CUDA_LANE_UNIT is still active after ${_waited}s, so the bench would refuse its VRAM baseline and measure nothing." >&2
    release_lane
    exit 1
fi

_free_mib="$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | tr -dc '0-9' || true)"
echo "[retune] CUDA lane down (${_waited}s); card free: ${_free_mib:-unknown} MiB"
echo "[retune] cycle budget before: $(cycle_now)/60"
echo

MAX_MODELS_PER_CHUNK="${MAX_MODELS_PER_CHUNK:-2}" \
    bash "$_SELF_DIR/run-autotune-batch.sh" "$@"
rc=$?

echo
echo "[retune] batch exit=${rc} ; cycle budget after: $(cycle_now)/60"
release_lane
exit "$rc"

# end of file
