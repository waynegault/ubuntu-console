#!/usr/bin/env bash
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 12
#   v12 (2026-10-22): HEALTH is rebuilt from the unit's port, and the env export uses
#   `export "${_p?}"`.  Measured: the server loaded and listened on :18085 while the probe
#   polled the row's :18082, so the arm never saw it healthy; and shellcheck SC2163 refused
#   the bare `export "$_p"` in the whole-tree gate.
#   v11 (2026-10-22): `--from-unit` now also sets LANE to that unit and applies its
#   `Environment=`.  Measured on the first two runs: every arm died at load because the
#   probe stopped the CUDA lane (its default) while its server tried to bind :18085,
#   which the untouched Xe lane still held; and the wrapper needs the unit's
#   LD_LIBRARY_PATH/GGML_OPENCL_* to find the OpenCL backend at all.
#   v10 (2026-10-22): the 4.2.4 comment sits INSIDE the `case` body.  The counter only
#   reads a comment while it is inside a case block, so one written above the `case`
#   left the count at 21 and the second push was refused too.  Measured, not inferred:
#   ratchet_check.py's c_case_no_default sets has_comment only when depth is non-zero.
#   v9 (2026-10-22): the new argv `case` carries the explanatory comment §18.3 4.2.4 asks
#   for (it has no `*)` arm because every non-special word falls through unchanged).  The
#   gate refused the first push on that counter; fixed at source, not re-baselined.
#   v8 (2026-10-22): `--from-unit UNIT` takes BASE from the LANE's own ExecStart instead
#   of the models.conf row, stripping the unit's pinned `--cache-ram` pair so the arm's
#   value is the only one.  Measured that day: :18085's row says ctx 36864 / threads 6 /
#   ngl 999 / flash-attn on / ngram, while the unit serves 16384 / 8 / 99 / off / none —
#   a row-based sweep would size a configuration no lane runs (the same rule as the
#   2026-10-21 iGPU correction).  PORT and ctx are read from the unit's argv so the
#   health checks and the report follow the lane, not the registry.
#   v7 (2026-10-22): wraps the two new guard lines. They were one-liners of 124 and
#   131 characters, which took §18.3 8.1.8 from 293 to 295 and refused the push —
#   fixed at source rather than re-baselined. No behaviour change.
#   v6 (2026-10-22): sizing knobs for the per-lane `--cache-ram` budget. `--cache-ram-mb N`
#   sets ARM B's value (default 0 = today's served argv), so the same probe can sweep
#   intermediate budgets instead of only default-8192 vs 0; `--prompt-tokens N` sets the
#   R1/R2 prefix size (default 1800), so a lane can be measured at a conversation length it
#   actually serves rather than at one fixed size. Both are inert unless passed: the defaults
#   reproduce v5 exactly. CARD: SWITCH-CONSOLE-AFFINITY-001 (per-lane budget sizing).
#   v5 (2026-10-21): adds a `--axis reuse` arm pair (A = served argv with
#   `--cache-ram 0`, B = A plus `--cache-reuse N`), an R4 prompt whose prefix
#   diverges mid-way and re-aligns, per-request prompt_tokens counters, and a
#   loud FAIL when the loader prints "cache_reuse is not supported by this
#   context".  Produced the SWITCH-CONSOLE-REUSE-001 verdict on 2026-10-21:
#   accepted by the CPU and three q8_0 chat lanes, engine-disabled for
#   embeddinggemma, and INERT on Llama-3.2-3B (identical cached-token delta,
#   slower prompt_ms at the realign step) — so no lane passes the flag.
#   REF: "The Hidden Cost of LLM Routing: Why Switching Models Costs More"
#   (Nhu Hoang, TDS 2026-10-20) — https://towardsdatascience.com/the-hidden-cost-of-llm-routing-why-switching-models-costs-more/
#   CARD: SWITCH-CONSOLE-REUSE-001
#   v4 (2026-10-12): the post-suspend free-VRAM wait calls the SHARED gate
#   `_tac_gpu_wait_used_below` (bin/_tac-bin-lib.sh) instead of hand-rolling a
#   free-VRAM threshold here.  Same contract as v3 — unreadable fails CLOSED,
#   exhaustion ABORTS with the last reading and never falls through — but the rule now
#   lives in one reviewed place, because this mechanism had been hand-rolled inline
#   three times that day and every copy was wrong differently.  The bound is now 800
#   MiB USED (multi-GPU safe) rather than "> 3000 MiB free".
#   v3 (2026-10-11): the post-suspend free-VRAM wait ABORTS on exhaustion instead of
#   proceeding.  After 45 polls (90 s) the loop used to END and the probe started its
#   measurement on whatever free VRAM it found — the same fall-through that launched a
#   run onto a 3.6 GiB card earlier the same day.  An unreadable reading now refuses
#   too: "cannot tell" is not evidence the card is free, so the wait fails closed.
#   v2 (2026-10-10): route every stderr write through one `warn` helper, comment the two
#   functions §18.3 items 10.7/9.5 counted, note why the arm `case` carries no `*)`, and
#   extract `_summarise_py` from `summarise` so neither exceeds item 10.4's bound.
#   v1 (2026-10-10): promoted from the gitignored one-off that produced the
#   cache-ram divergence verdict.  Tracked so the evidence behind that conclusion
#   is re-runnable from the tree: `--cache-ram` makes NO difference to DECODE
#   (the cold-decode gap follows POSITION, not the arm) but the served config
#   re-prefills on a conversation switch (+5.3 s TTFT here).  Adds the ORDER
#   CONTROL as the default (an interleaved sequence, so a single pass cannot be
#   fooled by the position drift this box shows), the POSITION-DRIFT warning,
#   and a machine-readable result written to the governed --out dir.
# ==============================================================================
# cache-ram-probe.sh — MEASUREMENT-ONLY.  Never writes the model registry.
# ==============================================================================
# QUESTION: does `--cache-ram` move the figures ubuntu-console CERTIFIES?
#
#   Arm A = NO --cache-ram  → llama.cpp's default 8192 MiB host-RAM prompt cache.
#           This is what scripts/autotune-model.sh certifies with (_bench_spawn,
#           scripts/autotune-model.sh:759-766, passes no --cache-ram).
#   Arm B = --cache-ram 0   → what the box SERVES (scripts/11e-llm-model.sh's serve
#           arm + the systemd lane units).
#
# Everything else identical.  Reported per arm: decode tps AND ttft, plus the
# server's own prompt_ms (the prefill component of TTFT).
#
# WHY A THREE-REQUEST SEQUENCE, not one prompt: llama.cpp's prompt cache is the
# HOST-RAM tier that serves a *repeat* of an earlier prefix.  Per the recorded
# measurement (scripts/01-constants.sh, MEASURED 2026-09-23) back-to-back
# IDENTICAL prompts are unaffected at --cache-ram 0 (the slot's own KV covers
# them); the cost lands when a DIFFERENT conversation takes the slot and the
# first one RETURNS.  So a single prompt cannot see the flag.  The sequence:
#   R1 = P1 (cold)          → decode_tps_cold, ttft_cold
#   R2 = P2 (other prefix)  → evicts the slot's P1 KV
#   R3 = P1 again           → CACHE HIT at 8192 (ttft_reuse ≈ small)
#                             vs RE-PROCESS at 0  (ttft_reuse ≈ prefill)
# ttft_reuse is the cache-ram signal; decode_cold tests whether the 8192 MiB host
# reservation moves throughput.
#
# ORDER CONTROL (the default).  Two arms alone are NOT a clean experiment on this
# box: whichever arm runs first is the first CUDA spawn, and the two runs of
# 2026-10-10 showed the COLD decode (R1, which the cache cannot influence) drifting
# 45-65% across POSITION while the arm's own run-to-run spread was only ~13%.  So
# the default sequence INTERLEAVES the arms (BABA — even n, no two adjacent arms
# equal): each arm then occupies an early AND a late position, and "A > B" can be
# told apart from "first > second".  A non-interleaved order is an explicit opt-in
# (--order AB --allow-noninterleaved) and is refused otherwise, because such a run
# cannot separate the arm from the position.
#
# REGISTRY SAFETY: this script only READS ~/.llm/models.conf.  It snapshots the
# row's line at start and re-diffs it at the end, so "nothing was written" is
# PROVEN by a diff rather than asserted.  (scripts/autotune-model.sh would REWRITE
# the row, which is why it is not used here.)
#
# SIGTERM POLICY: every server is stopped with SIGTERM and a grace loop.  SIGKILL
# is used ONLY if the grace expires, and that event is printed loudly.  A
# SIGKILLed CUDA holder orphans its dxgkrnl handles (documented on this box).
#
# TAKES THE CARD: it holds the watchdog off and stops the CUDA lane for the run
# (the bin/bench-rows.sh pattern), then releases so the watchdog restarts it.
#
# USAGE: scripts/cache-ram-probe.sh [--row N] [--port N] [--order SEQ]
#            [--allow-noninterleaved] [--out DIR] [--dry-run]
#   --dry-run proves the two arms' argv and the preflight assertions and exits
#   WITHOUT touching the card — nothing is started, no lane stopped.
# ==============================================================================
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
cd "$REPO" || exit 1

ORDER_DEFAULT="BABA"
# DRIFT_WARN_PCT: the spread of the COLD decode across the run's POSITIONS, above
# which the run is reported as a measurement hazard.  25% is chosen from two
# measured facts on this box: the SAME configuration varied ~13% between runs
# (arm A cold 24.84 / 28.15 tps), while the position drift inside an ~80 s run
# reached 65% (28.21 -> 8.10 tps).  25% sits ~2x the run-to-run noise and well
# below the observed hazard, so it flags drift a single-pass A/B cannot see.
DRIFT_WARN_PCT=25

ROW=21
PORT=18082
OPT_ORDER=""
OPT_ALLOW_NI=0
OPT_OUT="logs/cache-ram-probe"
OPT_DRY=0
OPT_REUSE=256
OPT_AXIS="cache-ram"
REUSE_AXIS=0
OPT_CACHE_MB=0
OPT_PROMPT_TOKENS=1800
OPT_FROM_UNIT=""

# warn — the ONE place this script writes to stderr.  §18.3 item 10.7 counts each
# ad-hoc `printf … >&2` site separately; routing them through here keeps the prefix
# and the stream in one place.  The redirect sits on the closing brace, so this
# definition is not itself counted as a site (the counter matches echo/printf and
# `>&2` on the same line).
warn() {
    {
        printf 'cache-ram-probe: %s\n' "$*"
    } >&2
}

# usage — the CLI synopsis; printed to stdout on --help, to stderr on a bad flag.
usage() {
    printf '%s\n' \
        "usage: cache-ram-probe.sh [--row N] [--port N] [--order SEQ]" \
        "           [--allow-noninterleaved] [--out DIR] [--dry-run]" \
        "           [--axis cache-ram|reuse] [--cache-reuse N]" \
        "           [--cache-ram-mb N] [--prompt-tokens N]"
}

# parse_args — the CLI.  Refuses an unknown flag rather than silently ignoring it.
parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            --row)   ROW="${2:?--row needs a number}"; shift 2 ;;
            --port)  PORT="${2:?--port needs a number}"; shift 2 ;;
            --order) OPT_ORDER="${2:?--order needs a sequence}"; shift 2 ;;
            --allow-noninterleaved) OPT_ALLOW_NI=1; shift ;;
            --out)   OPT_OUT="${2:?--out needs a directory}"; shift 2 ;;
            --dry-run) OPT_DRY=1; shift ;;
            --axis) OPT_AXIS="${2:?--axis needs cache-ram or reuse}"; shift 2 ;;
            --cache-reuse) OPT_REUSE="${2:?--cache-reuse needs a number}"; shift 2 ;;
            --cache-ram-mb) OPT_CACHE_MB="${2:?--cache-ram-mb needs a number}"; shift 2 ;;
            --prompt-tokens) OPT_PROMPT_TOKENS="${2:?--prompt-tokens needs a number}"; shift 2 ;;
            --from-unit) OPT_FROM_UNIT="${2:?--from-unit needs a unit}"; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) usage >&2; warn "FATAL: unknown argument $1"; exit 1 ;;
        esac
    done
    [[ "$OPT_REUSE" =~ ^[0-9]+$ ]] || { usage >&2; warn "FATAL: --cache-reuse must be a non-negative integer"; exit 1; }
    if [[ ! "$OPT_CACHE_MB" =~ ^[0-9]+$ ]]
    then
        usage >&2
        warn "FATAL: --cache-ram-mb must be a non-negative integer"
        exit 1
    fi
    if [[ ! "$OPT_PROMPT_TOKENS" =~ ^[1-9][0-9]*$ ]]
    then
        usage >&2
        warn "FATAL: --prompt-tokens must be a positive integer"
        exit 1
    fi
    case "$OPT_AXIS" in
        cache-ram) ;;
        reuse) REUSE_AXIS=1 ;;
        *) usage >&2; warn "FATAL: --axis must be 'cache-ram' or 'reuse'"; exit 1 ;;
    esac
}

# is_interleaved <seq> — 0 when the sequence alternates with an EVEN arm count of at
# least FOUR.  Even + alternating is what puts each arm in both an early and a late
# position — and that needs >= 4 arms: with only two ("AB") each arm sits in exactly
# one position, so an arm effect and a position effect cannot be told apart at all.
is_interleaved() {
    local seq="$1" i=1
    (( ${#seq} >= 4 && ${#seq} % 2 == 0 )) || return 1
    while (( i < ${#seq} )); do
        [[ "${seq:i-1:1}" != "${seq:i:1}" ]] || return 1
        i=$(( i + 1 ))
    done
    return 0
}

# parse_order <seq-or-empty> <allow-noninterleaved 0|1>
#   Echoes the arm sequence, one arm per line.  Refuses (rc 1) a malformed
#   sequence, and a NON-interleaved one unless the override is given.
parse_order() {
    local seq="$1" allow="$2" i=0 ch
    [[ -n "$seq" ]] || seq="$ORDER_DEFAULT"
    while (( i < ${#seq} )); do
        ch="${seq:i:1}"
        case "$ch" in
            A|B) ;;
            *) warn "FATAL: order '$seq' may contain only A and B (got '$ch')"; return 1 ;;
        esac
        i=$(( i + 1 ))
    done
    if ! is_interleaved "$seq"; then
        if (( allow != 1 )); then
            warn "REFUSED: order '$seq' is not interleaved — a single pass with this order" \
                 "cannot separate the ARM from the POSITION (pass --allow-noninterleaved)"
            return 1
        fi
        warn "WARNING: order '$seq' is not interleaved — arm and position are CONFOUNDED in this run"
    fi
    i=0
    while (( i < ${#seq} )); do
        printf '%s\n' "${seq:i:1}"
        i=$(( i + 1 ))
    done
    return 0
}

# assert_argv <label> <expected --cache-ram count> <argv...>
#   REFUSES to run an argv that is not the one the arm claims.  Two failure classes,
#   both of which start a server that is not measuring what we think it is:
#     (1) a word containing a SPACE — a flag and its value merged into ONE argv
#         element.  This is the 2026-10-10 ARM B bug: the caller passed the whole
#         "--cache-ram 0" as the *value*, so it printed as `--cache-ram --cache-ram 0`
#         and llama.cpp read the second flag as the first flag's value.  A duplicate
#         flag and a miscounted flag are one class: assert the argv you are running.
#     (2) the --cache-ram count must be exactly the arm's (0 for A, 1 for B) with an
#         integer value.
assert_argv() {
    local label="$1" want="$2"
    shift 2
    local -a a=("$@")
    local i w n=0 val=""
    for w in "${a[@]}"; do
        if [[ "$w" == *" "* ]]; then
            printf "  PREFLIGHT FAIL (%s): argv word contains a SPACE -> '%s' (flag+value merged)\n" "$label" "$w"
            return 1
        fi
    done
    for (( i = 0; i < ${#a[@]}; i++ )); do
        if [[ "${a[i]}" == "--cache-ram" ]]; then
            n=$(( n + 1 ))
            val="${a[i+1]:-}"
        fi
    done
    if (( n != want )); then
        printf "  PREFLIGHT FAIL (%s): --cache-ram appears %d time(s), expected %d — REFUSING to start this arm\n" \
            "$label" "$n" "$want"
        return 1
    fi
    if (( want == 1 )) && [[ ! "$val" =~ ^([0-9]+|-1)$ ]]; then
        printf "  PREFLIGHT FAIL (%s): --cache-ram value '%s' is not an integer — refusing\n" "$label" "$val"
        return 1
    fi
    if (( want == 1 )); then
        printf "  PREFLIGHT OK (%s): --cache-ram appears exactly 1 time, value '%s'\n" "$label" "$val"
    else
        printf "  PREFLIGHT OK (%s): --cache-ram absent (0 occurrences, as required)\n" "$label"
    fi
    return 0
}

parse_args "$@"

source env.sh || { warn 'FATAL: failed to source env.sh'; exit 1; }
source "$REPO/bin/_tac-bin-lib.sh"

SUSPEND="${LLAMA_WATCHDOG_CUDA_SUSPEND_FILE:-/dev/shm/llama-watchdog-cuda.suspend}"
LANE="${LLAMA_CUDA_LANE_UNIT:-llama-cuda-llama32-3b-chat.service}"
HEALTH="http://127.0.0.1:${PORT}"
LLAMA_BIN="${LLAMA_SERVER_BIN:-$HOME/llama.cpp/build/bin/llama-server}"
[[ -x "$LLAMA_BIN" ]] || { warn "FATAL: no llama-server at $LLAMA_BIN"; exit 1; }

OUT_DIR="$OPT_OUT"
[[ "$OUT_DIR" == /* ]] || OUT_DIR="$REPO/$OUT_DIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT_JSON="$OUT_DIR/result-$STAMP.json"
# swallow-ok: mktemp's own failure prints its reason and returns non-zero; the call below
# is guarded by the WORKDIR emptiness test, so nothing is lost silently
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/cache-ram-probe.XXXXXX")"
[[ -d "$WORKDIR" ]] || { warn 'FATAL: no workdir'; exit 1; }

# ── snapshot the row (registry-SAFETY proof, part 1) ─────────────────────────
ROW_BEFORE="$(awk -F'|' -v r="$ROW" '$1==r{print; exit}' "$LLM_REGISTRY")"
[[ -n "$ROW_BEFORE" ]] || { warn "FATAL: row $ROW not in $LLM_REGISTRY"; exit 1; }

# Read the row as an ARRAY and bind only the columns this probe uses — a named read
# would leave ~20 unused names and shellcheck rightly flags each (SC2034).
IFS='|' read -ra F <<< "$ROW_BEFORE"
name="${F[1]:-}"; file="${F[2]:-}"; qc="${F[4]:-}"; ngl="${F[6]:-}"; ctx="${F[7]:-}"
thr="${F[8]:-}"; ba="${F[9]:-}"; ub="${F[10]:-}"; pa="${F[11]:-}"; fa="${F[15]:-}"
stype="${F[26]:-}"; snmax="${F[28]:-}"; rp="${F[37]:-}"; rln="${F[38]:-}"
MODEL_PATH="$LLAMA_MODEL_DIR/$file"
[[ -f "$MODEL_PATH" ]] || { warn "FATAL: model file not found: $MODEL_PATH"; exit 1; }
KVK="${qc##*/}"; _kvpre="${qc%/*}"; KVV="${_kvpre##*/}"   # Q4_K_M/q8_0/q8_0 -> q8_0 / q8_0
[[ -n "$KVK" ]] || KVK=q8_0
[[ -n "$KVV" ]] || KVV=q8_0
BLOCK="${snmax:-0}"
[[ "$BLOCK" =~ ^[0-9]+$ ]] && (( BLOCK > 0 )) || BLOCK=16

printf 'cache-ram probe — row %s %s (%s)\n' "$ROW" "$name" "$file"
printf '  registry line (READ ONLY, snapshot): %s\n' "$ROW_BEFORE"
printf '  ctx=%s batch=%s/%s threads=%s ngl=%s parallel=%s flash-attn=%s kv=%s/%s spec=%s(block %s) rp=%s rln=%s\n' \
    "$ctx" "$ba" "$ub" "$thr" "$ngl" "$pa" "$fa" "$KVK" "$KVV" "${stype:-none}" "$BLOCK" "${rp:-unset}" "${rln:-unset}"

# __base_from_unit <unit> — replace BASE with the lane unit's own ExecStart argv.
#
# WHY: a models.conf row describes the AUTOTUNE configuration, and on this box that
# is not what a lane serves.  Measured 2026-10-22: :18085's row says ctx 36864,
# threads 6, ngl 999, flash-attn on and an ngram spec, while the unit serves ctx
# 16384, threads 8, ngl 99, flash-attn off and no spec.  A sweep through the row
# would size a configuration nobody runs.
#
# The unit pins its own --cache-ram; that pair is STRIPPED here so the arm's value
# is the only one in the argv (a duplicate would be the 2026-10-10 malformed arm).
function __base_from_unit() {
    local _unit="$1" _line _argv _i
    _line=$(systemctl --user show "$_unit" -p ExecStart --value) \
        || { warn "FATAL: no ExecStart for $_unit"; return 1; }
    _argv="${_line#*argv[]=}"
    _argv="${_argv%% ;*}"
    if [[ -z "$_argv" || "$_argv" == "$_line" ]]
    then
        warn "FATAL: could not parse argv from $_unit"
        return 1
    fi
    local -a _words=() _out=()
    read -ra _words <<< "$_argv"
    for (( _i=0; _i<${#_words[@]}; _i++ ))
    do
        # Only these three spellings are special; every other argv word falls
        # through unchanged, so a `*)` arm would be an empty no-op.
        case "${_words[_i]}" in
            # The comment must sit INSIDE the block: the counter only reads one
            # while it is inside a case, not one written above the `case`.
            --cache-ram) _i=$(( _i + 1 )); continue ;;
            --port) PORT="${_words[_i+1]:-$PORT}" ;;
            --ctx-size) ctx="${_words[_i+1]:-$ctx}" ;;
        esac
        _out+=("${_words[_i]}")
    done
    BASE=("${_out[@]}")
    # The unit measured IS the lane the probe must stop: LANE defaults to the CUDA
    # lane, so without this the probe stopped the wrong unit and its own server hit
    # a port the untouched lane still held — "server exited during load" on every
    # arm (measured 2026-10-22).
    LANE="$_unit"
    # HEALTH is built from PORT far above, before this function runs, so it still
    # points at the row's port.  Measured 2026-10-22: the server loaded and listened
    # on the unit's :18085 while the probe polled :18082 and never saw it healthy.
    HEALTH="http://127.0.0.1:${PORT}"
    # The argv is not the whole runtime: this lane's unit sets LD_LIBRARY_PATH to the
    # OpenCL build and the GGML_OPENCL_* selectors.  Measured 2026-10-22 — without
    # them every arm died at load ("server exited during load"), because the wrapper
    # found no OpenCL backend.  A systemd unit never reads ~/.bashrc, so these must
    # come from the unit itself.
    local _env _p
    local -a _pairs=()
    _env=$(systemctl --user show "$_unit" -p Environment --value)
    if [[ -n "$_env" ]]
    then
        read -ra _pairs <<< "$_env"
        for _p in "${_pairs[@]}"
        do
            [[ "$_p" == *=* ]] || continue
            _p="${_p#\"}"; _p="${_p%\"}"
            export "${_p?}"
        done
    fi
    printf '  BASE from %s: %s\n' "$_unit" "${BASE[*]}"
}

# The base argv is identical across arms; ONLY --cache-ram differs.
BASE=("$LLAMA_BIN" --model "$MODEL_PATH" --port "$PORT" --host 127.0.0.1
      --ctx-size "$ctx" --batch-size "$ba" --ubatch-size "$ub"
      --threads "$thr" --n-gpu-layers "$ngl"
      --parallel "$pa" --fit off --flash-attn "$fa" --kv-offload
      --cache-type-k "$KVK" --cache-type-v "$KVV")
[[ -n "$rp" ]]  && BASE+=(--repeat-penalty "$rp")
[[ -n "$rln" ]] && BASE+=(--repeat-last-n "$rln")
if [[ "$stype" == "ngram" ]]; then
    BASE+=(--spec-type ngram-mod --spec-ngram-mod-n-max "$BLOCK" --spec-ngram-mod-n-min "$BLOCK")
fi

# --from-unit replaces the ROW-derived argv with the lane's own (see the function's
# WHY block): the row is the autotune configuration, not what the lane serves.
if [[ -n "$OPT_FROM_UNIT" ]]
then
    __base_from_unit "$OPT_FROM_UNIT" || exit 1
fi

# ── fixed prompts (deterministic, ~1800 tokens each) ─────────────────────────
mk_payload() { # <file> <seed-sentence> <approx-tokens> <max_tokens>
    "$TAC_PYTHON" - "$1" "$2" "$3" "$4" <<'PYEOF'
import json, sys
out, seed, tokens, max_tokens = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
reps = (tokens * 5) // max(1, len(seed)) + 1
content = (seed * reps)[: tokens * 5]
json.dump({"messages": [{"role": "user", "content": content}],
           "max_tokens": max_tokens, "temperature": 0, "stream": True}, open(out, "w"))
PYEOF
}

# A mid-prefix divergence that re-aligns: the shape --cache-reuse targets.
mk_diverged() { # <file> <seed-sentence> <approx-tokens> <max_tokens>
    "$TAC_PYTHON" - "$1" "$2" "$3" "$4" <<'PYEOF'
import json, sys
out, seed, tokens, max_tokens = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
reps = (tokens * 5) // max(1, len(seed)) + 1
body = (seed * reps)[: tokens * 5]
half = len(body) // 2
content = body[:half] + " The tribunal adjourned briefly for a procedural ruling. " + body[half:]
json.dump({"messages": [{"role": "user", "content": content}],
           "max_tokens": max_tokens, "temperature": 0, "stream": True}, open(out, "w"))
PYEOF
}

# metrics_pair — "cached processed", or empty when the endpoint is absent.
metrics_pair() {
    # swallow-ok: an absent endpoint yields an empty pair, reported as not-measured
    curl -s --max-time 2 "$HEALTH/metrics" 2>/dev/null \
        | awk '$1 == "llamacpp:prompt_tokens_cached_total" { c = $2 }
               $1 == "llamacpp:prompt_tokens_total"        { p = $2 }
               END { if (c != "" && p != "") printf "%.0f %.0f", c, p }'
}

# ── dry run: prove the argv and the assertions, start nothing ────────────────
dry_run() {
    printf '\nDRY RUN — nothing started, no lane stopped, no suspend taken, registry untouched\n'
    if (( REUSE_AXIS )); then
        local -a ra=("${BASE[@]}" --cache-ram 0 --metrics)
        local -a rb=("${BASE[@]}" --cache-ram 0 --metrics --cache-reuse "$OPT_REUSE")
        printf '  ARM A argv (%d words): %s\n' "${#ra[@]}" "${ra[*]}"
        printf '  ARM B argv (%d words): %s\n' "${#rb[@]}" "${rb[*]}"
        [[ "$(printf '%s\n' "${ra[@]}" | grep -c -x -- '--cache-ram')" -eq 1 ]] \
            || { printf '  PREFLIGHT FAIL: ARM A --cache-ram count != 1\n'; return 1; }
        [[ "$(printf '%s\n' "${rb[@]}" | grep -c -x -- '--cache-reuse')" -eq 1 ]] \
            || { printf '  PREFLIGHT FAIL: ARM B --cache-reuse count != 1\n'; return 1; }
        printf '  PREFLIGHT OK (A/B): --cache-ram 0 on both; --cache-reuse %s only on B\n' "$OPT_REUSE"
        return 0
    fi
    local -a da=("${BASE[@]}") db=("${BASE[@]}" --cache-ram "$OPT_CACHE_MB")
    printf '  ARM A argv (%d words): %s\n' "${#da[@]}" "${da[*]}"
    printf '  ARM B argv (%d words): %s\n' "${#db[@]}" "${db[*]}"
    assert_argv A 0 "${da[@]}" || return 1
    assert_argv B 1 "${db[@]}" || return 1
    printf '  positive control (the merged flag+value that broke ARM B must be REFUSED):\n'
    if assert_argv B 1 "${BASE[@]}" --cache-ram "--cache-ram 0"; then
        printf '  POSITIVE CONTROL FAILED: the merged-argv case was ACCEPTED — the assertion does not work\n'
        return 1
    fi
    printf '  POSITIVE CONTROL OK: the merged flag+value is refused (the exact 2026-10-10 bug)\n'
    printf '  order default: %s (interleaved=%s)\n' "$ORDER_DEFAULT" \
        "$(is_interleaved "$ORDER_DEFAULT" && echo yes || echo no)"
    return 0
}

if (( OPT_DRY == 1 )); then
    dry_run || exit 1
    exit 0
fi

P1_TXT="The investigating officer reviewed the witness statements and the "
P1_TXT+="disciplinary policy before reaching a conclusion on the balance of probabilities. "
P2_TXT="The tribunal considered the respondent's justification for the provision, "
P2_TXT+="criterion or practice and weighed proportionality against the claimant's disadvantage. "
mk_payload "$WORKDIR/p1.json" "$P1_TXT" "$OPT_PROMPT_TOKENS" 128
mk_payload "$WORKDIR/p2.json" "$P2_TXT" "$OPT_PROMPT_TOKENS" 128
mk_diverged "$WORKDIR/p3.json" "$P1_TXT" "$OPT_PROMPT_TOKENS" 128
mk_payload "$WORKDIR/warmup.json" "Warmup" 8 8

# measure <payload.json> <out.json> — TTFT (wall) + the server's own timings from
# the final streamed chunk.  Prints "ttft_ms|delivered|server_decode|prompt_ms|wall".
measure() {
    "$TAC_PYTHON" - "$PORT" "$1" "$2" <<'PYEOF'
import json, sys, time, urllib.request
port, payload_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
with open(payload_path) as f:
    data = json.dumps(json.load(f)).encode()
req = urllib.request.Request(f"http://127.0.0.1:{port}/v1/chat/completions",
                             data=data, headers={"Content-Type": "application/json"}, method="POST")
t0 = time.time_ns(); ttft = 0; delivered = 0; timings = {}; buf = b""
with urllib.request.urlopen(req, timeout=1800) as resp:
    for raw in resp:
        buf += raw
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            s = line.decode("utf-8", "replace").strip()
            if not s.startswith("data: "):
                continue
            payload = s[6:]
            if payload == "[DONE]":
                break
            try:
                obj = json.loads(payload)
            except Exception as exc:
                print(f"[cache-ram-probe] warning: skipping malformed SSE chunk: {exc}", file=sys.stderr)
                continue
            choice = (obj.get("choices") or [{}])[0]
            delta = choice.get("delta") or {}
            if delta.get("content") or delta.get("reasoning_content"):
                if ttft == 0:
                    ttft = (time.time_ns() - t0) // 1_000_000
                delivered += 1
            if obj.get("timings"):
                timings = obj["timings"]
total_ms = (time.time_ns() - t0) // 1_000_000
dec = float(timings.get("predicted_per_second") or 0)
pms = float(timings.get("prompt_ms") or 0)
wall = (delivered * 1000.0 / (total_ms - ttft)) if (total_ms > ttft and delivered > 0) else 0.0
json.dump({"ttft_ms": ttft, "delivered": delivered, "server_decode_tps": dec,
           "server_prompt_ms": pms, "wall_decode_tps": round(wall, 2),
           "total_ms": total_ms, "timings_present": bool(timings)}, open(out_path, "w"))
print(f"{ttft}|{delivered}|{dec:.2f}|{pms:.0f}|{wall:.2f}")
PYEOF
}

# term_server <pid> — SIGTERM, grace, re-check; SIGKILL only on a failed grace.
term_server() {
    local pid="$1" w=0
    [[ "$pid" =~ ^[0-9]+$ ]] || return 0
    # A pid already gone is the state this seeks, so a best-effort TERM is enough.
    # swallow-ok: the liveness loop below is the check; kill's "No such process" adds nothing.
    kill -TERM "$pid" 2>/dev/null
    while (( w < 25 )); do
        # swallow-ok: kill -0's "No such process" IS the answer here, not an error.
        if ! kill -0 "$pid" 2>/dev/null; then
            printf '    teardown: SIGTERM honoured in %ss\n' "$w"
            return 0
        fi
        sleep 1; w=$(( w + 1 ))
    done
    printf '    teardown: SIGTERM GRACE EXPIRED after %ss — sending SIGKILL (reported)\n' "$w"
    # swallow-ok: best-effort last resort, after the grace failure was printed above.
    kill -KILL "$pid" 2>/dev/null
    return 0
}

# The pre-flight parse, kept as a variable so the pipeline stays inside the 120-col
# house limit (tools/count-ratchet.sh item 8.1.8).
_PF_PARSE="import sys,json;print(json.load(sys.stdin).get('usage',{}).get('completion_tokens',0))"

# run_arm <arm-label> <cache-ram VALUE or empty> <position-index>
run_arm() {
    local label="$1" cram_val="$2" pos="$3"
    local pid="" hw=0 out_dir="$WORKDIR/pos${pos}_${label}"
    local want=0
    [[ -n "$cram_val" ]] && want=1
    mkdir -p "$out_dir"
    local axis_label
    if (( REUSE_AXIS )); then
        axis_label="reuse: $([[ "$label" == B ]] && printf '%s' "$OPT_REUSE" || printf 'absent')"
    else
        axis_label="cache-ram: ${cram_val:-OMITTED -> default 8192}"
    fi
    printf '\n=== pos%s ARM %s  (%s)\n' "$pos" "$label" "$axis_label"
    local -a argv=("${BASE[@]}")
    if (( REUSE_AXIS )); then
        # Both arms carry the SERVED --cache-ram 0; only B asks for KV shifting.
        argv+=(--cache-ram 0 --metrics)
        [[ "$label" == B ]] && argv+=(--cache-reuse "$OPT_REUSE")
        printf '    PREFLIGHT (%s): --cache-ram 0; --cache-reuse %s\n' "$label" \
            "$([[ "$label" == B ]] && printf '%s' "$OPT_REUSE" || printf 'absent')"
    else
        [[ -n "$cram_val" ]] && argv+=(--cache-ram "$cram_val")
        assert_argv "$label" "$want" "${argv[@]}" || return 1
    fi
    printf '    argv: %s\n' "${argv[*]}"
    "${argv[@]}" > "$out_dir/server.log" 2>&1 &
    pid=$!
    while (( hw < 120 )); do
        sleep 1; hw=$(( hw + 1 ))
        # swallow-ok: kill -0's message is the ANSWER here; the FAIL row reports it.
        if ! kill -0 "$pid" 2>/dev/null; then
            printf '    FAIL: server exited during load — see %s/server.log\n' "$out_dir"
            return 1
        fi
        # Connection-refused while the server loads is EXPECTED, not a failure.
        # swallow-ok: the loop's 120s timeout is the verdict, so curl's noise tells nothing.
        if curl -sS --max-time 2 "$HEALTH/health" 2>/dev/null | grep -q '"status":"ok"'; then
            break
        fi
    done
    if (( hw >= 120 )); then
        printf '    FAIL: server never healthy in 120s\n'
        term_server "$pid"
        return 1
    fi
    local pf=0 w=0
    while (( w < 60 )); do
        # The connection may be refused while the server finishes binding (EXPECTED) and
        # an empty body is the false case the loop retries; pf==1 below is the verdict.
        if {
            curl -sS --max-time 5 "$HEALTH/v1/chat/completions" \
                -H "Content-Type: application/json" \
                -d '{"messages":[{"role":"user","content":"hi"}],"max_tokens":1,"temperature":0}' \
                | "$TAC_PYTHON" -c "$_PF_PARSE" \
                | grep -q '[1-9]'
        } 2>/dev/null; then   # swallow-ok: EXPECTED load-window noise; pf==1 is the verdict
            pf=1; break
        fi
        # swallow-ok: kill -0's message is the ANSWER; the pf==1 check below reports it.
        if ! kill -0 "$pid" 2>/dev/null; then
            break
        fi
        sleep 1; w=$(( w + 1 ))
    done
    if (( pf != 1 )); then
        printf '    FAIL: pre-flight completion never returned a token\n'
        term_server "$pid"
        return 1
    fi
    printf '    server healthy in %ss, pre-flight ok — measuring (R1 cold, R2 switch, R3 reuse, R4 divergence)\n' "$hw"
    if (( REUSE_AXIS )) && grep -q 'cache_reuse is not supported' "$out_dir/server.log"; then
        printf '    FAIL: the engine DISABLED --cache-reuse for this arm — the exercise is invalid, not a null\n'
        term_server "$pid"
        return 1
    fi
    measure "$WORKDIR/warmup.json" "$out_dir/warmup.json" >/dev/null
    local m0 m1
    m0=$(metrics_pair); measure "$WORKDIR/p1.json" "$out_dir/r1.json"; m1=$(metrics_pair)
    printf '%s\n%s\n' "$m0" "$m1" > "$out_dir/r1.metrics"; printf '    r1 counters: %s -> %s\n' "$m0" "$m1"
    m0=$(metrics_pair); measure "$WORKDIR/p2.json" "$out_dir/r2.json"; m1=$(metrics_pair)
    printf '%s\n%s\n' "$m0" "$m1" > "$out_dir/r2.metrics"; printf '    r2 counters: %s -> %s\n' "$m0" "$m1"
    m0=$(metrics_pair); measure "$WORKDIR/p1.json" "$out_dir/r3.json"; m1=$(metrics_pair)
    printf '%s\n%s\n' "$m0" "$m1" > "$out_dir/r3.metrics"; printf '    r3 counters: %s -> %s\n' "$m0" "$m1"
    m0=$(metrics_pair); measure "$WORKDIR/p3.json" "$out_dir/r4.json"; m1=$(metrics_pair)
    printf '%s\n%s\n' "$m0" "$m1" > "$out_dir/r4.metrics"; printf '    r4 counters: %s -> %s\n' "$m0" "$m1"
    term_server "$pid"
    return 0
}

# _summarise_py <workdir> <order-seq> <result-json> <row> — the measurement reader:
#   walks the pos* directories, prints the per-position table, the per-arm means, the
#   DELTA and the position-drift verdict, and writes the result JSON.  Extracted from
#   `summarise` so each function stays under the §18.3 item 10.4 100-line bound.
_summarise_py() {
    "$TAC_PYTHON" - "$1" "$2" "$3" "$4" "$DRIFT_WARN_PCT" "$REUSE_AXIS" "$OPT_REUSE" <<'PYEOF'
import glob, json, os, re, sys
wd, seq, result_path, row, drift_pct = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], float(sys.argv[5])
reuse_axis = int(sys.argv[6]); reuse_tokens = sys.argv[7]
rows = []
for d in sorted(glob.glob(os.path.join(wd, "pos*")), key=lambda p: int(re.search(r"pos(\d+)", p).group(1))):
    m = re.search(r"pos(\d+)_([AB])$", d)
    if not m:
        continue
    def rr(name, d=d):
        p = os.path.join(d, name)
        return json.load(open(p)) if os.path.exists(p) else None
    rows.append({"pos": int(m.group(1)), "arm": m.group(2),
                 "r1": rr("r1.json"), "r3": rr("r3.json"), "r4": rr("r4.json")})
for r in rows:
    if not r["r1"] or not r["r3"]:
        print(f"  pos{r['pos']} ARM {r['arm']}: INCOMPLETE")
        continue
    print(f"  pos{r['pos']} ARM {r['arm']}: decode_cold={r['r1']['server_decode_tps']:.2f} tps"
          f"  decode_reuse={r['r3']['server_decode_tps']:.2f} tps"
          f"  | ttft_cold={r['r1']['ttft_ms']} ms  ttft_reuse={r['r3']['ttft_ms']} ms"
          f"  | prompt_ms_cold={r['r1']['server_prompt_ms']:.0f}  prompt_ms_reuse={r['r3']['server_prompt_ms']:.0f}")
    if r.get("r4"):
        print(f"         realign: ttft_div={r['r4']['ttft_ms']} ms  prompt_ms_div={r['r4']['server_prompt_ms']:.0f}")
def mean(vals):
    return sum(vals) / len(vals) if vals else float("nan")
arms = {a: [r for r in rows if r["arm"] == a and r["r1"] and r["r3"]] for a in ("A", "B")}
for a in ("A", "B"):
    rs = arms[a]
    if not rs:
        continue
    if reuse_axis:
        lbl = "A (no --cache-reuse)" if a == "A" else f"B (--cache-reuse {reuse_tokens})"
    else:
        lbl = "A (no --cache-ram, default 8192)" if a == "A" else "B (--cache-ram 0)"
    print(f"  ARM {lbl}: n={len(rs)}  mean decode_cold={mean([r['r1']['server_decode_tps'] for r in rs]):.2f}"
          f"  mean decode_reuse={mean([r['r3']['server_decode_tps'] for r in rs]):.2f}"
          f"  mean ttft_reuse={mean([r['r3']['ttft_ms'] for r in rs]):.0f} ms")
delta = None
if arms["A"] and arms["B"]:
    def cold(a):
        return [r['r1']['server_decode_tps'] for r in arms[a]]
    def reuse(a):
        return [r['r3']['server_decode_tps'] for r in arms[a]]
    def ttft_reuse(a):
        return [r['r3']['ttft_ms'] for r in arms[a]]
    dc = mean(cold("A")) - mean(cold("B"))
    dr = mean(reuse("A")) - mean(reuse("B"))
    dt = mean(ttft_reuse("A")) - mean(ttft_reuse("B"))
    delta = {"decode_cold": dc, "decode_reuse": dr, "ttft_reuse": dt}
    print(f"  DELTA (A-B, means): decode_cold {dc:+.2f} tps  decode_reuse {dr:+.2f} tps  ttft_reuse {dt:+.0f} ms")
cold = [r["r1"]["server_decode_tps"] for r in rows if r["r1"]]
drift = None
if len(cold) >= 2 and max(cold) > 0:
    drift = (max(cold) - min(cold)) / max(cold) * 100.0
    print("  per-position cold decode: " + ", ".join(
        f"pos{r['pos']}={r['r1']['server_decode_tps']:.2f}({r['arm']})" for r in rows if r['r1']))
    if drift > drift_pct:
        print(f"  WARN: position drift {drift:.0f}% of the cold decode exceeds the {drift_pct:.0f}% hazard bound —")
        print("        a single-pass A/B on this run could not be attributed to the arm.")
        print("        Interleave the arms (the default) to cancel it.")
    else:
        print(f"  position drift {drift:.0f}% of the cold decode — within the {drift_pct:.0f}% hazard bound")
interleaved = len(seq) > 0 and len(seq) % 2 == 0 and all(seq[i] != seq[i + 1] for i in range(len(seq) - 1))
result = {"row": row, "order": seq, "interleaved": interleaved,
          "drift_pct": drift, "drift_warn_pct": drift_pct,
          "positions": rows, "delta": delta}
try:
    with open(result_path, "w") as f:
        json.dump(result, f, indent=2)
    print(f"  result written: {result_path}")
except OSError as exc:
    print(f"  WARNING: could not write {result_path}: {exc}")
PYEOF
}

# summarise <workdir> <order-seq> <result-json> <row> — the reporting entry point;
#   delegates to _summarise_py.
summarise() {
    _summarise_py "$@"
}

# ── take the card: hold the watchdog off, stop the lane (bin/bench-rows.sh pattern)
if ! _tac_suspend_acquire "$SUSPEND"; then
    warn "FATAL: could not acquire the CUDA suspend hold ($SUSPEND)"
    exit 1
fi
trap '_tac_suspend_release "$SUSPEND"' EXIT
# swallow-ok: a lane already down is the state this seeks; the free-VRAM check below
# is the check that the card was actually released.
systemctl --user stop "$LANE" >/dev/null 2>&1
# THE SHARED GATE (v4).  This wait was hand-rolled here — a free-VRAM threshold polled
# inline — and the same mechanism was hand-rolled wrongly elsewhere twice more the same
# day.  It now calls `_tac_gpu_wait_used_below` (bin/_tac-bin-lib.sh), which owns the
# whole rule: the most-used card (multi-GPU safe), a reading that cannot be read fails
# CLOSED, and EXHAUSTION ABORTS non-zero with the last reading instead of falling
# through — the fall-through that once launched a run onto a card holding 3.6 GiB.
# The bound (800 MiB USED) is chosen so it is satisfiable once OUR lane is down; the
# old free-VRAM test (> 3000 MiB free) said the same thing less directly.
if ! _tac_gpu_wait_used_below 800 90; then
    warn "FATAL: the card did not free for this run (see the gpu-wait line above) — refusing to start"
    exit 1
fi
printf '\ncard free before start: %s MiB used\n' "$(_tac_gpu_used_mib)"

_seq_out="$(parse_order "$OPT_ORDER" "$OPT_ALLOW_NI")"
_prc=$?
if (( _prc != 0 )); then
    warn 'FATAL: refusing to start — the order was rejected (see above)'
    exit 1
fi
[[ -n "$_seq_out" ]] || { warn 'FATAL: the order produced no arms'; exit 1; }
mapfile -t _arm_seq <<< "$_seq_out"
printf 'arm sequence this run: %s\n' "${_arm_seq[*]}"

mkdir -p "$OUT_DIR"
_fail=0
_pos=0
for _arm in "${_arm_seq[@]}"; do
    _pos=$(( _pos + 1 ))
    case "$_arm" in
        # parse_order emits only A and B, so a `*)` arm here would be unreachable; the
        # argument defect it would catch is refused earlier, at the parse.
        A) run_arm A ""  "$_pos" || _fail=1 ;;
        B) run_arm B "$OPT_CACHE_MB" "$_pos" || _fail=1 ;;
    esac
done

printf '\n=== RESULT (row %s %s)\n' "$ROW" "$name"
summarise "$WORKDIR" "${_arm_seq[*]// /}" "$RESULT_JSON" "$ROW"

# ── registry-SAFETY proof, part 2 ────────────────────────────────────────────
ROW_AFTER="$(awk -F'|' -v r="$ROW" '$1==r{print; exit}' "$LLM_REGISTRY")"
if [[ "$ROW_BEFORE" == "$ROW_AFTER" ]]; then
    printf 'registry row %s UNCHANGED (byte-identical before/after) — this probe wrote nothing\n' "$ROW"
else
    printf '!!! REGISTRY ROW %s CHANGED — investigate immediately\n' "$ROW"
    printf '  before: %s\n  after:  %s\n' "$ROW_BEFORE" "$ROW_AFTER"
    _fail=1
fi
printf 'arm sequence: %s   failures: %s\n' "${_arm_seq[*]}" "$_fail"
rm -rf "$WORKDIR"
exit "$_fail"

# end of file
