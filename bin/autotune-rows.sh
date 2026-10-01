#!/usr/bin/env bash
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 1
# TRACKED HERE since 2026-10-01: this script lived only as a loose ~/.local/bin copy, so a
# change to it was unversioned and unreviewable.  Code that is exclusively supportive of
# ubuntu-console belongs in this repo; install.sh links every file in bin/ into
# ~/.local/bin, so the stable path keeps resolving while the body is reviewable here.
#
# autotune-rows.sh — autotune the given registry rows with the CUDA lane held down.
#
# Usage: autotune-rows.sh <row> [<row> ...]
#        autotune-rows.sh --all-but-done      (every row with field 18 != yes)
#        autotune-rows.sh --all               (every row — a re-validation sweep)
#
# Why a wrapper: run-autotune-batch.sh needs the CUDA lane down for the WHOLE run, but
# between benches the GPU is briefly free and the watchdog's policy is to start the lane
# whenever it is — which would steal VRAM mid-sweep and make the next bench refuse its
# VRAM baseline.  The suspend file holds it down; the trap releases it, because one left
# behind keeps the lane down for as long as nobody notices.
#
# Durable on purpose (2026-09-16): the previous launcher lived in /tmp and a WSL restart
# deleted it along with the log.  This one logs to ~/.llm/autotune-logs/, which survives.
#
# The CUDA cycle ledger is boot-scoped and the batch HALTS (exit 3) at CUDA_CYCLE_BUDGET
# (60) — that is by design, not a failure: a full 27-row sweep is several sessions, each
# needing a WSL restart to reset the ledger.  On halt this prints the resume command.
set -uo pipefail

# ── Box-wide heavy-job serialisation (bin/heavy-job) ─────────────────────────
# At most ONE heavy job runs on this box at a time: two of them oversubscribe all
# 16 cores and starve every interactive turn (bin/heavy-job records the
# measurement).  Re-entrant — an enclosing heavy-job exports HEAVY_JOB_HELD, so the
# batch this script calls passes through instead of deadlocking on the lock its own
# parent holds.  Resolved from this script's own location so the guard does not
# depend on ~/.local/bin being on PATH.
if [[ -z "${HEAVY_JOB_HELD:-}" ]]; then
    exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/heavy-job" \
        "${BASH:-bash}" "${BASH_SOURCE[0]}" "$@"
fi

REPO="${REPO:-/home/wayne/ubuntu-console}"
REGISTRY="$HOME/.llm/models.conf"
SUSPEND="${LLAMA_WATCHDOG_CUDA_SUSPEND_FILE:-/dev/shm/llama-watchdog-cuda.suspend}"
LANE="${LLAMA_CUDA_LANE_UNIT:-llama-cuda-llama32-3b-chat.service}"
LOGDIR="$HOME/.llm/autotune-logs"
mkdir -p "$LOGDIR"

case "${1:-}" in
    --all-but-done) shift; mapfile -t ROWS < <(awk -F'|' '$1 ~ /^[0-9]+$/ && $18 != "yes" {print $3}' "$REGISTRY" | sort) ;;
    --all)          shift; mapfile -t ROWS < <(awk -F'|' '$1 ~ /^[0-9]+$/ {print $3}' "$REGISTRY" | sort) ;;
    '')             echo "usage: $(basename "$0") <row|file>... | --all-but-done | --all" >&2; exit 2 ;;
    *)              ROWS=("$@") ;;
esac
if (( ${#ROWS[@]} == 0 )); then
    echo "autotune-rows: no rows selected — nothing to do" >&2
    exit 0
fi

LOG="$LOGDIR/autotune-$(date +%Y%m%d-%H%M%S)-rows-${ROWS[0]}${ROWS[*]:+_to_${ROWS[-1]}}.log"
cd "$REPO" || exit 1

{
    echo "=== autotune ${#ROWS[@]} row(s): ${ROWS[*]}"
    echo "=== started $(date -Iseconds)"
    # swallow-ok: the ledger is boot-scoped and absent before the first autotune of a boot; absent means zero cycles, and this only reports it
    echo "=== ledger before: $(cat /dev/shm/autotune-cuda-cycles-* 2>/dev/null || echo 0)"
    echo "=== lane held down: $LANE   suspend: $SUSPEND"
    echo "=== log: $LOG"
} | tee -a "$LOG"

touch "$SUSPEND"
trap 'rm -f "$SUSPEND"' EXIT
# swallow-ok: the lane may already be down, and a down lane is the state this line seeks either way
systemctl --user stop "$LANE" >/dev/null 2>&1 || true

_free_mib() {
    # swallow-ok: a failing nvidia-smi leaves _free empty, and the numeric guard in the wait loop is what decides — the probe's own error adds nothing
    nvidia-smi --query-gpu=memory.total,memory.used --format=csv,noheader,nounits 2>/dev/null \
        | awk -F', *' '{print $1 - $2; exit}'
}
for _ in $(seq 1 45); do
    _free="$(_free_mib)"
    [[ "$_free" =~ ^[0-9]+$ ]] || break
    (( _free > 3000 )) && break
    sleep 2
done
echo "=== card free before start: ${_free:-unknown} MiB" >> "$LOG"

bash scripts/run-autotune-batch.sh "${ROWS[@]}" >> "$LOG" 2>&1
rc=$?
{
    echo "=== batch exited $rc at $(date -Iseconds)"
    # swallow-ok: the boot-scoped ledger again — an absent file reports zero cycles, which is its true value
    echo "=== ledger after: $(cat /dev/shm/autotune-cuda-cycles-* 2>/dev/null || echo 0)"
    echo "=== log: $LOG"
} | tee -a "$LOG"
exit "$rc"

# end of file
