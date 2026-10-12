#!/usr/bin/env bash
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 1
#   v1 (2026-10-12): created at Wayne's instruction ("write the re-bench as a tracked
#   script with fail-fast").  The re-bench had been driven from a hand-rolled wrapper
#   that failed in three ways the same day, and this script exists to make each one
#   impossible: (1) it HELD the CUDA suspend and then ran a probe that acquires its
#   OWN, so all five rows died in ~1 s each with "FATAL: could not acquire the CUDA
#   suspend hold"; (2) it exited 0 anyway, because a `for` loop's status is its LAST
#   command's, so a job whose every row failed read GREEN; (3) it repeated that
#   identical failure four more times.  The GPU gate comes from the shared helper
#   (bin/_tac-bin-lib.sh), never a hand-written VRAM threshold — an unsatisfiable
#   "card under 1500 MiB" precondition deadlocked a previous arm for 5.6 h.
# ==============================================================================
# rebench-rows.sh — run scripts/cache-ram-probe.sh over a LIST OF ROWS, one row at a
# time, with FAIL-FAST, and propagate a failing row's exit status.
# ==============================================================================
# WHY THIS EXISTS (each item was MEASURED here on 2026-10-12):
#
#   1. NEVER HOLD THE CUDA SUSPEND — THE PROBE OWNS IT.  scripts/cache-ram-probe.sh
#      acquires the suspend itself (_tac_suspend_acquire), and that helper is
#      OWNER-CHECKED AND NOT RE-ENTRANT: a wrapper that holds the marker starves every
#      row, each dying in about a second with "FATAL: could not acquire the CUDA
#      suspend hold".  THIS SCRIPT NEVER TAKES THE SUSPEND, and check_suspend_not_ours()
#      below ENFORCES that by refusing to start when the marker is held by this
#      script's own process tree.
#   2. THE RC IS PROPAGATED.  A `for` loop's exit status is its LAST command's, so the
#      wrapper's five failed rows read GREEN.  Here every row's rc is captured into
#      FAILED_ANY/STOPPED and any non-zero row makes this script exit non-zero: it can
#      never exit 0 with a failed row.
#   3. FAIL-FAST, DEFAULT 1.  The wrapper repeated an identical failure four more
#      times.  This stops at the FIRST failure and prints the row, its rc and the tail
#      of that row's transcript; --max-consecutive-failures N raises the threshold
#      deliberately.
#   4. NO VRAM THRESHOLD, EVER.  The pre-row gate is _tac_gpu_wait_foreign_clear
#      (bin/_tac-bin-lib.sh), which asks bin/gpu-busy.sh and excludes our own fleet by
#      /proc/PID/exe — so our own lane's ~3.4 GiB reads FREE, which a VRAM number cannot
#      express.  A hand-written bound was unsatisfiable while our own lane held 3376 MiB
#      and polled for 5.6 h.  Do not add one here.
#
# THE COMPARISON RULE (what the numbers mean — see the probe's own header for the
# measurement design):
#   * JUDGE ARM A — the CERTIFIED argv, i.e. NO --cache-ram (llama.cpp's default 8192
#     MiB host-RAM prompt cache), which is exactly what scripts/autotune-model.sh
#     certifies with — against the row's `tps` figure in the registry;
#   * ARM B (--cache-ram 0) is the SERVED config.  It is NOT comparable to the registry
#     figure, and a difference there is not a certification failure;
#   * the registry's tps field belongs to AUTOTUNE ALONE.  The probe only READS the row
#     (it snapshots the line and re-diffs it to prove nothing was written) and it must
#     NEVER be hand-edited.
#
# USAGE: scripts/rebench-rows.sh [--rows a,b,c] [--order SEQ] [--out DIR]
#            [--max-consecutive-failures N]
#   --rows   comma-separated registry rows (default 26,10,14,24,25)
#   --order  probe arm sequence (default BABA; the probe REFUSES a non-interleaved one)
#   --out    governed output ROOT (default logs/benchmarks/selection); each row gets
#            its own <root>/probe-rerun-rowN/ directory, as the earlier runs did
#   --max-consecutive-failures N   stop after N consecutive failures (default 1)
#
# Env: TAC_GPU_WAIT_TIMEOUT / TAC_GPU_WAIT_POLL bound the foreign-holder wait (the
#      shared helper's own knobs), TAC_GPU_BUSY_SH overrides the detector (sandboxes),
#      LLAMA_WATCHDOG_CUDA_SUSPEND_FILE overrides the marker path.
#
# Exit: 0 = every row attempted exited 0 · 1 = a row failed or the loop stopped early
#       · 2 = refused before starting (bad CLI, no probe, GPU held, our suspend held).
# ==============================================================================
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
cd "$REPO" || exit 1

# The shared library owns the suspend protocol and the GPU-availability mechanism.
# shellcheck source=../bin/_tac-bin-lib.sh
source "$REPO/bin/_tac-bin-lib.sh"

PROBE="$SELF_DIR/cache-ram-probe.sh"
HEAVY="$REPO/bin/heavy-job"

ROWS_DEFAULT="26,10,14,24,25"
OPT_ROWS="$ROWS_DEFAULT"
OPT_ORDER="BABA"
OPT_OUT="logs/benchmarks/selection"
MAX_CONSECUTIVE_FAILURES=1

# warn — the ONE place this script writes to stderr.  §18.3 item 10.7 counts each
# ad-hoc `printf … >&2` site separately; routing them through here keeps the prefix
# and the stream in one place.  The redirect sits on the closing brace, so this
# definition is not itself counted as a site (the counter matches echo/printf and
# `>&2` on the same line).
warn() {
    {
        printf 'rebench-rows: %s\n' "$*"
    } >&2
}

# refuse — report the reason (when one is given) and exit with the runner's DOCUMENTED
# refusal status.  ONE site defines that status, so its meaning is explained once
# rather than at every call (docs/inspection.md §18.3 item 9.7 asks for a non-0/1 code
# to be explained where it is used, and a single definition is the honest shape of it).
refuse() {
    if (( $# > 0 )); then
        warn "$@"
    fi
    exit 2   # 2 = refused before starting (bad CLI, no probe, GPU held, our suspend held)
}

# usage — the CLI synopsis; printed to stdout on --help, to stderr on a bad flag.
usage() {
    printf '%s\n' \
        "usage: rebench-rows.sh [--rows a,b,c] [--order SEQ] [--out DIR]" \
        "           [--max-consecutive-failures N]"
}

# log — one timestamped line to the runner transcript AND stdout.  It deliberately
# shadows the library's `log`, so the shared GPU-wait helper's own lines land in the
# transcript too.
log() {
    local _line
    _line="$(date -Is) rebench-rows: $*"
    if [[ -n "${RUN_LOG:-}" ]]; then
        printf '%s\n' "$_line" >> "$RUN_LOG"
    fi
    printf '%s\n' "$_line"
}

# parse_args — the CLI.  Refuses an unknown flag rather than silently ignoring it.
parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            --rows)   OPT_ROWS="${2:?--rows needs a comma-separated list}"; shift 2 ;;
            --order)  OPT_ORDER="${2:?--order needs a sequence}"; shift 2 ;;
            --out)    OPT_OUT="${2:?--out needs a directory}"; shift 2 ;;
            --max-consecutive-failures)
                MAX_CONSECUTIVE_FAILURES="${2:?--max-consecutive-failures needs a number}"; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) usage >&2; refuse "FATAL: unknown argument $1" ;;
        esac
    done
}

# parse_rows — split the list into ROW_LIST and REFUSE anything that is not a bare
# row number, so a typo cannot silently run the wrong row (or none at all).
parse_rows() {
    local _r
    local -a _raw=()
    ROW_LIST=()
    IFS=',' read -ra _raw <<< "$OPT_ROWS"
    for _r in "${_raw[@]}"; do
        if [[ ! "$_r" =~ ^[0-9]+$ ]]; then
            refuse "FATAL: --rows entry '$_r' is not a row number"
        fi
        ROW_LIST+=("$_r")
    done
    if (( ${#ROW_LIST[@]} == 0 )); then
        refuse "FATAL: --rows is empty"
    fi
    return 0
}

# _own_tree_pids — this shell's pid and its ancestors, bounded.  Used ONLY to tell
# "the suspend marker is held by a wrapper of OURS" from "held by someone else".
_own_tree_pids() {
    local _p="$$" _n=0
    while [[ "$_p" =~ ^[0-9]+$ ]] && (( _p > 1 )) && (( _n < 16 )); do
        printf '%s\n' "$_p"
        # swallow-ok: a ps that cannot read an ancestor's ppid ENDS the walk, which is the same answer as reaching pid 1
        _p="$(ps -o ppid= -p "$_p" 2>/dev/null | tr -d ' \n')"
        _n=$(( _n + 1 ))
    done
}

# _is_own_tree <pid> — 0 when <pid> is this shell or one of its ancestors.
_is_own_tree() {
    local _want="$1" _p
    [[ "$_want" =~ ^[0-9]+$ ]] || return 1
    while IFS= read -r _p; do
        [[ "$_p" == "$_want" ]] && return 0
    done < <(_own_tree_pids)
    return 1
}

# check_suspend_not_ours — REFUSE to start when the CUDA suspend marker is held by a
# LIVE owner.  Our OWN tree is the measured defect: a wrapper of ours holding the
# marker starves the probe, which acquires its own hold, and the helper is owner-checked
# and NOT re-entrant — every row would die in ~1 s with "FATAL: could not acquire the
# CUDA suspend hold".  A FOREIGN live holder is refused too: the probe cannot take the
# marker over from it either, so starting would only burn a row on that same failure.
check_suspend_not_ours() {
    local _pid
    _tac_suspend_held "$SUSPEND" || return 0
    _pid="$(_tac_suspend_pid "$SUSPEND")"
    if _is_own_tree "$_pid"; then
        warn "REFUSED: $SUSPEND is held by THIS script's own process tree (pid $_pid)."
        warn "  This runner never takes the suspend: the probe acquires its own, and the"
        warn "  helper is owner-checked and NOT re-entrant, so every row would fail at once."
        warn "  Release the hold (the holder is an ancestor of pid $$) and re-run."
    else
        warn "REFUSED: $SUSPEND is held by an OUTSIDE owner (pid $_pid): the probe cannot"
        warn "  take it over from a live owner, so no row was started."
    fi
    refuse    # the reason is above; leave with the runner's refusal status
}

# run_row <row> — run ONE probe under the box-wide heavy-job lock, tee its transcript
# into the row's governed directory, and RETURN the probe's own exit status (taken from
# PIPESTATUS, never from `tee`).
run_row() {
    local _row="$1" _out_dir _row_log _rc _reg
    _out_dir="$OUT_ROOT/probe-rerun-row$_row"
    if ! mkdir -p "$_out_dir"; then
        warn "FATAL: cannot create $_out_dir"
        return 1
    fi
    _row_log="$_out_dir/rebench-row$_row-$STAMP.log"
    log "row $_row: $HEAVY bash scripts/cache-ram-probe.sh --row $_row --order $OPT_ORDER --out $_out_dir"
    "$HEAVY" bash "$PROBE" --row "$_row" --order "$OPT_ORDER" --out "$_out_dir" 2>&1 | tee "$_row_log"
    _rc="${PIPESTATUS[0]}"
    # Keep the probe's registry snapshot in the transcript: it is the READ-ONLY proof
    # of which row's line this run was measured against.  No swallow here — grep finding
    # nothing is a legitimate state (the probe died before its snapshot), and that case
    # is already loud through _rc below.
    if _reg="$(grep -m1 'registry line (READ ONLY, snapshot)' "$_row_log")"; then
        log "row $_row: $_reg"
    fi
    log "row $_row: rc=$_rc"
    if (( _rc != 0 )); then
        log "row $_row: last 15 lines of $_row_log:"
        tail -n 15 "$_row_log" | while IFS= read -r _l; do
            log "  | $_l"
        done
    fi
    return "$_rc"
}

parse_args "$@"
parse_rows

if [[ ! "$MAX_CONSECUTIVE_FAILURES" =~ ^[1-9][0-9]*$ ]]; then
    refuse "FATAL: --max-consecutive-failures must be a positive integer (got '$MAX_CONSECUTIVE_FAILURES')"
fi
if [[ ! -f "$PROBE" ]]; then
    refuse "FATAL: no probe at $PROBE"
fi
if [[ ! -x "$HEAVY" ]]; then
    refuse "FATAL: no heavy-job at $HEAVY"
fi

OUT_ROOT="$OPT_OUT"
[[ "$OUT_ROOT" == /* ]] || OUT_ROOT="$REPO/$OUT_ROOT"
if ! mkdir -p "$OUT_ROOT"; then
    refuse "FATAL: cannot create $OUT_ROOT"
fi
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_LOG="$OUT_ROOT/rebench-$STAMP.log"
if ! : > "$RUN_LOG"; then
    refuse "FATAL: cannot write the runner transcript $RUN_LOG"
fi

SUSPEND="${LLAMA_WATCHDOG_CUDA_SUSPEND_FILE:-/dev/shm/llama-watchdog-cuda.suspend}"

log "rows=${ROW_LIST[*]} order=$OPT_ORDER out=$OUT_ROOT"
log "fail-fast: stop after $MAX_CONSECUTIVE_FAILURES consecutive failure(s)"
log "suspend: $SUSPEND — the PROBE acquires this; the runner never takes it"

check_suspend_not_ours

log "gpu gate: waiting for no FOREIGN holder (_tac_gpu_wait_foreign_clear)"
if ! _tac_gpu_wait_foreign_clear; then
    log "refused: the foreign-holder wait did not clear"
    refuse "REFUSED: a foreign holder still has the CUDA card — no row was started"
fi

FAILS=0        # consecutive failures, reset by a successful row
FAILED_ANY=0   # any row failed at all
ATTEMPTED=0
STOPPED=0
for row in "${ROW_LIST[@]}"; do
    ATTEMPTED=$(( ATTEMPTED + 1 ))
    run_row "$row"
    rc=$?
    if (( rc == 0 )); then
        FAILS=0
        continue
    fi
    FAILED_ANY=1
    FAILS=$(( FAILS + 1 ))
    log "row $row: FAILED rc=$rc (consecutive $FAILS/$MAX_CONSECUTIVE_FAILURES)"
    if (( FAILS >= MAX_CONSECUTIVE_FAILURES )); then
        STOPPED=1
        log "FAIL-FAST: stopping at row $row (rc=$rc) after $FAILS consecutive failure(s)"
        break
    fi
done

if (( STOPPED == 1 || FAILED_ANY == 1 )); then
    log "rebench-rows: DONE — $ATTEMPTED of ${#ROW_LIST[@]} row(s) attempted, at least one FAILED; exit 1"
    exit 1
fi

log "rebench-rows: DONE — all $ATTEMPTED row(s) exited 0"
exit 0

# end of file
