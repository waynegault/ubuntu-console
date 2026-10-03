#!/usr/bin/env bash
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 2
# TRACKED HERE since 2026-10-01: this script lived only as a loose ~/.local/bin copy, so a
# change to it was unversioned and unreviewable.  Code that is exclusively supportive of
# ubuntu-console belongs in this repo; install.sh links every file in bin/ into
# ~/.local/bin, so the stable path keeps resolving while the body is reviewable here.
#
# bench-rows.sh — re-measure registry rows at their RECORDED settings (validation).
#
# Usage: bench-rows.sh <row> [<row> ...]      # e.g. bench-rows.sh 4 6 8
#
# WHAT THIS PROVES, AND WHAT IT DOES NOT
#   It proves the recorded ctx/batch still LOADS and still performs comparably — the
#   reality test for a row whose certification predates today's code changes.  It does
#   NOT re-prove that the recorded settings are optimal: that needs the full search
#   (~16 cycles/row), and is what autotune-rows.sh is for.  Treat a material tps drop
#   here as the trigger for a full re-autotune of that row, not as a new certification.
#
# WHY A WRAPPER AT ALL
#   `model bench` spawns its own CUDA server on the interactive lane port, so the CUDA
#   chat lane must be down and the watchdog must not start it mid-run (its policy is to
#   start the lane whenever the GPU is free — which is exactly the window between
#   benchmark cases).  Same hold pattern as autotune-rows.sh: suspend file held, lane
#   stopped, trap releases.  Kept as a SEPARATE script rather than a mode of that one so
#   a validation pass can never be routed through the autotune cycle budget by accident
#   — the budget meters autotune spawns only (verified: _bump_cuda_cycle lives only in
#   autotune-model.sh), and that distinction is deliberate until it is fixed.
set -uo pipefail

# Shared helpers (_free_mib) — see bin/_tac-bin-lib.sh.  Sourced by realpath so
# the ~/.local/bin symlink and the repo path both resolve.
# shellcheck source=_tac-bin-lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/_tac-bin-lib.sh"

# ── Box-wide heavy-job serialisation (bin/heavy-job) ─────────────────────────
# At most ONE heavy job runs on this box at a time: two of them oversubscribe all
# 16 cores and starve every interactive turn (bin/heavy-job records the
# measurement).  Re-entrant — an enclosing heavy-job exports HEAVY_JOB_HELD, so a
# bench invoked from inside another heavy flow passes through instead of
# deadlocking on the lock its own parent holds.  Resolved from this script's own
# location so the guard does not depend on ~/.local/bin being on PATH.
if [[ -z "${HEAVY_JOB_HELD:-}" ]]; then
    exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/heavy-job" \
        "${BASH:-bash}" "${BASH_SOURCE[0]}" "$@"
fi

REPO="${REPO:-/home/wayne/ubuntu-console}"
SUSPEND="${LLAMA_WATCHDOG_CUDA_SUSPEND_FILE:-/dev/shm/llama-watchdog-cuda.suspend}"
LANE="${LLAMA_CUDA_LANE_UNIT:-llama-cuda-llama32-3b-chat.service}"
LOGDIR="$HOME/.llm/autotune-logs"
mkdir -p "$LOGDIR"

if (( $# == 0 )); then
    echo "usage: $(basename "$0") <row> [<row> ...]" >&2
    exit 2
fi

# Name the log after the FIRST and LAST row, and keep the name bounded.  `$*` joined EVERY
# argument, and rows are addressed by .gguf FILE NAME (the durable identity), so a 6-row
# validation overflowed NAME_MAX and `tee` refused the path before a single bench ran —
# measured 2026-09-17: bench exited 1 with "File name too long" at line 68.  Row NUMBERS hid
# this, because ~20 of them fit comfortably.  Same convention as autotune-rows.sh.
_bench_first="$1"
_bench_last="${!#}"
if (( $# == 1 )); then
    LOG="$LOGDIR/bench-$(date +%Y%m%d-%H%M%S)-rows-${_bench_first}.log"
else
    LOG="$LOGDIR/bench-$(date +%Y%m%d-%H%M%S)-rows-${_bench_first}_to_${_bench_last}.log"
fi
(( ${#LOG} > 240 )) && LOG="${LOG:0:200}-trunc.log"
cd "$REPO" || exit 1

{
    echo "=== bench-validate ${#} row(s): $*"
    echo "=== started $(date -Iseconds)"
    # swallow-ok: the ledger is boot-scoped and absent before the first autotune of a boot; absent means zero cycles, and this only reports it
    echo "=== ledger (autotune cycles, NOT charged by this path): $(cat /dev/shm/autotune-cuda-cycles-* 2>/dev/null || echo 0)"
    echo "=== lane held down: $LANE   suspend: $SUSPEND"
    echo "=== TAC_BENCH_FIT=${TAC_BENCH_FIT:-off} (off = measure the CERTIFIED configuration)"
    echo "=== log: $LOG"
} | tee -a "$LOG"

# Measure the configuration the row was CERTIFIED with.  Bench mode otherwise fits by
# default (--fit on), which shrinks the served window on the 4 GB card — measured
# 2026-09-16: advertised 8192, served 2048, tps 9.9 against the autotune's 29.13.  With
# --fit off a row whose certified ctx genuinely cannot fit will fail loudly instead of
# being silently measured at a different size, which is the behaviour a validation wants.
export TAC_BENCH_FIT="${TAC_BENCH_FIT:-off}"

touch "$SUSPEND"
trap 'rm -f "$SUSPEND"' EXIT
# swallow-ok: the lane may already be down, and a down lane is the state this line seeks either way
systemctl --user stop "$LANE" >/dev/null 2>&1 || true

for _ in $(seq 1 45); do
    _free="$(_free_mib)"
    [[ "$_free" =~ ^[0-9]+$ ]] || break
    (( _free > 3000 )) && break
    sleep 2
done
echo "=== card free before start: ${_free:-unknown} MiB" >> "$LOG"

# The repo's own non-interactive function runner; `model bench` accepts several rows.
"$HOME/.local/bin/tac-exec" model bench "$@" >> "$LOG" 2>&1
rc=$?
{
    echo "=== bench exited $rc at $(date -Iseconds)"
    echo "=== log: $LOG"
} | tee -a "$LOG"
exit "$rc"

# end of file
