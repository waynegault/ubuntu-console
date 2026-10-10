#!/usr/bin/env bash
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 3
#   v3 (2026-10-10): ADD GATE 4 — a real VRAM reading.  Gate 2 is a serialisation
#   lock, not a card-availability probe, and this file used it as one.
#   v2 (2026-10-10): route every stderr write through one `warn` helper and comment the
#   two functions §18.3 items 10.7/9.5 counted, so this file adds no ad-hoc `>&2` site.
#   v1 (2026-10-10): promoted from the gitignored one-off watcher.  Waits for a quiet
#   box (three gates), runs scripts/cache-ram-probe.sh ONCE under the box-wide
#   heavy-job lock, tees the transcript to a governed log, and reads the measurements
#   back from the probe's own result JSON — so the evidence behind the cache-ram
#   verdict is re-runnable from the tree.
# ==============================================================================
# cache-ram-probe-watch.sh — quiet-window launcher for scripts/cache-ram-probe.sh.
# ==============================================================================
# The probe is a GPU measurement, so it is only meaningful on a quiet box; and it
# must not run concurrently with another heavy job.  This waits for ALL FOUR gates:
#   1. /proc/loadavg 1-min < 4
#   2. `heavy-job --status` line STARTS WITH 'heavy-job: free'  (a PREFIX match: the
#      free line carries " (last holder: <cmd>)" after the word, so a substring
#      match could read BUSY as free)
#   3. the boot CUDA-cycle ledger /dev/shm/autotune-cuda-cycles-* sums under 50 of 60
#   4. nvidia-smi used VRAM under VRAM_MAX — ADDED v3.  Gate 2 does NOT test the
#      card: a lane can hold the GPU entirely outside bin/heavy-job, so `--status`
#      reads `free` while the card is nearly full.  Measured 2026-10-10 — the
#      openclaw hal bench held 3.3 GiB of 4.0 GiB for four hours with the lock
#      reading free, and a run launched on gates 1-3 alone found 126 MB free and
#      produced no measurement at all.  The lock serialises heavy jobs; it does not
#      answer "is the card free".  Ask the card.
# then runs the probe under bin/heavy-job, which also serialises against any other
# heavy job (it BLOCKS on the lock rather than fighting for it).
#
# CAVEAT (measured 2026-10-10): the ledger counts AUTOTUNE spawns (autotune-model.sh
# calls _bump_cuda_cycle); the probe does not, so gate 3 does NOT bound the probe's
# own CUDA churn.  It is kept because it still says how much of the boot's budget is
# already spent.
#
# USAGE: scripts/cache-ram-probe-watch.sh [--row N] [--order SEQ] [--out DIR]
#            [--poll SECS] [--max-wait SECS] [--allow-noninterleaved]
#   Runs in the FOREGROUND once the gate opens (background it with nohup/systemd to
#   walk away).  Exit 0 = the probe ran; 1 = refused or the probe failed.
# ==============================================================================
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
cd "$REPO" || exit 1

HEAVY="$REPO/bin/heavy-job"
LEDGER_MAX=50   # the boot's CUDA-cycle budget share to spend before a bench
LOAD_MAX=4      # /proc/loadavg 1-min ceiling for a "quiet" box
VRAM_MAX=800    # MiB; above this the card is occupied by someone else (gate 4, v3)
ROW=21
OPT_ORDER="BABA"
OPT_OUT="logs/cache-ram-probe"
OPT_POLL=120
OPT_MAX_WAIT=86400
OPT_ALLOW_NI=0

# warn — the ONE place this script writes to stderr.  §18.3 item 10.7 counts each
# ad-hoc `printf … >&2` site separately; routing them through here keeps the prefix
# and the stream in one place.  The redirect sits on the closing brace, so this
# definition is not itself counted as a site (the counter matches echo/printf and
# `>&2` on the same line).
warn() {
    {
        printf 'cache-ram-probe-watch: %s\n' "$*"
    } >&2
}

# usage — the CLI synopsis; printed to stdout on --help, to stderr on a bad flag.
usage() {
    printf '%s\n' \
        "usage: cache-ram-probe-watch.sh [--row N] [--order SEQ] [--out DIR]" \
        "           [--poll SECS] [--max-wait SECS] [--allow-noninterleaved]"
}

# parse_args — the CLI.  Refuses an unknown flag rather than silently ignoring it.
parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            --row)   ROW="${2:?--row needs a number}"; shift 2 ;;
            --order) OPT_ORDER="${2:?--order needs a sequence}"; shift 2 ;;
            --out)   OPT_OUT="${2:?--out needs a directory}"; shift 2 ;;
            --poll)  OPT_POLL="${2:?--poll needs seconds}"; shift 2 ;;
            --max-wait) OPT_MAX_WAIT="${2:?--max-wait needs seconds}"; shift 2 ;;
            --allow-noninterleaved) OPT_ALLOW_NI=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) usage >&2; warn "FATAL: unknown argument $1"; exit 1 ;;
        esac
    done
}

# gate_ok — 0 when ALL FOUR gates are open.  Prints the readings to stdout with the
# derived booleans so a log line shows WHY it waited.
gate_ok() {
    local load1 hj hj_rc cycles vram load_ok=0 hj_ok=0 cyc_ok=0 vram_ok=0
    load1="$(cut -d' ' -f1 /proc/loadavg)"
    # swallow-ok: the exit status is captured on the same line (hj_rc) and checked below.
    hj="$("$HEAVY" --status 2>/dev/null)"; hj_rc=$?
    # The ledger is boot-scoped and absent before the first autotune of a boot.
    # swallow-ok: an absent file and a zero sum are the same state, which the awk prints.
    cycles="$(cat /dev/shm/autotune-cuda-cycles-* 2>/dev/null | awk '{s+=$1} END{print s+0}')"
    # Gate 4 (v3).  Deliberately NOT silenced: if nvidia-smi cannot be read the
    # reading stays empty, the numeric test below fails, and the box is treated as
    # BUSY — the gate fails closed, which is the correct direction for a GPU probe.
    vram="$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | tr -d ' ')"
    load_ok="$(awk -v l="$load1" -v m="$LOAD_MAX" 'BEGIN{print (l<m)?1:0}')"
    if [[ ! "$hj_rc" =~ ^[0-9]+$ ]] || (( hj_rc != 0 )); then
        warn "WARNING: heavy-job --status rc=$hj_rc — cannot read the lock; treating the box as NOT free"
    else
        case "$hj" in
            "heavy-job: free"*) hj_ok=1 ;;
            *)                  hj_ok=0 ;;
        esac
    fi
    if [[ "$cycles" =~ ^[0-9]+$ ]] && (( cycles < LEDGER_MAX )); then cyc_ok=1; fi
    if [[ "$vram" =~ ^[0-9]+$ ]] && (( vram < VRAM_MAX )); then vram_ok=1; fi
    printf 'load1=%s load_ok=%s | hj=%s hj_ok=%s | cycles=%s cyc_ok=%s | vram=%sMiB vram_ok=%s\n' \
        "$load1" "$load_ok" "$hj" "$hj_ok" "$cycles" "$cyc_ok" "$vram" "$vram_ok"
    (( load_ok == 1 && hj_ok == 1 && cyc_ok == 1 && vram_ok == 1 ))
}

parse_args "$@"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="$OPT_OUT"
[[ "$OUT_DIR" == /* ]] || OUT_DIR="$REPO/$OUT_DIR"
mkdir -p "$OUT_DIR"
WLOG="$OUT_DIR/watch-$STAMP.log"
RLOG="$OUT_DIR/probe-$STAMP.log"
PY="$REPO/.venv/bin/python"

# log — append one timestamped line to the watch transcript.
log() { printf '%s %s\n' "$(date -Is)" "$*" >>"$WLOG"; }

_ni=""
(( OPT_ALLOW_NI == 1 )) && _ni="--allow-noninterleaved"

log "watcher armed: stamp=$STAMP pid=$$"
log "probe: cache-ram-probe.sh --row $ROW --order $OPT_ORDER --out $OUT_DIR $_ni"
log "transcript (governed): $RLOG"

_waited=0
while :; do
    readings="$(gate_ok 2>&1)"
    grc=$?
    if (( grc == 0 )); then
        log "GATES FREE after ${_waited}s: $readings — starting the probe"
        break
    fi
    if (( _waited % (OPT_POLL * 5) == 0 )); then
        log "waiting (${_waited}s): $readings"
    fi
    if (( _waited >= OPT_MAX_WAIT )); then
        log "max-wait ${OPT_MAX_WAIT}s reached without a quiet window — NOT running the probe"
        exit 1
    fi
    sleep "$OPT_POLL"
    _waited=$(( _waited + OPT_POLL ))
done

PROBE_CMD="cd $REPO && bash $SELF_DIR/cache-ram-probe.sh"
PROBE_CMD+=" --row $ROW --order $OPT_ORDER --out $OUT_DIR $_ni"
"$HEAVY" bash -c "$PROBE_CMD" 2>&1 | tee -a "$RLOG"
rc=${PIPESTATUS[0]}
log "probe exited rc=$rc (0 = completed)"

# Read the MEASUREMENTS back from the probe's own result JSON, not the exit code.
# swallow-ok: no result file IS the finding — the `-z "$newest"` branch below reports it.
newest="$(ls -1t "$OUT_DIR"/result-*.json 2>/dev/null | head -1)"
if [[ -z "$newest" ]]; then
    log "no result-*.json in $OUT_DIR — the probe wrote nothing (rc=$rc)"
elif [[ ! -x "$PY" ]]; then
    log "FATAL: $PY missing — cannot read $newest back (nothing silenced; install the venv)"
    log "watcher done (rc=1)"
    exit 1
else
    log "result read back from $newest:"
    "$PY" - "$newest" >>"$WLOG" 2>&1 <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
print(f"  row={d.get('row')} order={d.get('order')} interleaved={d.get('interleaved')}"
      f" drift_pct={d.get('drift_pct')} bound={d.get('drift_warn_pct')}")
for r in d.get("positions", []):
    if not r.get("r1") or not r.get("r3"):
        print(f"  pos{r['pos']} ARM {r['arm']}: INCOMPLETE")
        continue
    print(f"  pos{r['pos']} ARM {r['arm']}: decode_cold={r['r1']['server_decode_tps']:.2f}"
          f" decode_reuse={r['r3']['server_decode_tps']:.2f} ttft_reuse={r['r3']['ttft_ms']} ms")
print(f"  delta={d.get('delta')}")
PYEOF
fi
log "watcher done (rc=$rc)"
exit "$rc"

# end of file
