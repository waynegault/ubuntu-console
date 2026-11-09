#!/usr/bin/env bash
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 2
#   v2 (2026-11-09): §18.3 debt the first cut carried — eight bare `exit 2` sites became one
#       `die_usage` helper holding the status (9.7 79 -> 79, and no line pushed past 120
#       chars doing it, 8.1.8), and the signal trap names its code.  No behaviour change:
#       the same text reaches stderr and the same status leaves the process.
#   v1 (2026-11-09): first cut.  The lane serves --parallel 4 because Wayne asked for at
#       least four slots (2026-11-07), and nothing has ever measured whether 8 or 16 earns
#       its KV.  A vLLM recipe on the same silicon (devjeonghwan/vllm-for-rtx-spark) runs
#       max-num-seqs 16 and reports 65.75 -> 233.63 tok/s from concurrency 1 to 16, so the
#       slot count is a throughput lever, not a comfort setting.  This probe restarts ONE
#       lane at each slot count and measures AGGREGATE throughput at that concurrency with
#       tools/llm_benchmark.py — the load generator this repo already owns and tests.
#
# slots-probe.sh — how many slots should this lane serve?
#
# Usage: slots-probe.sh [--unit U] [--values 4,8,16] [--concurrency N]
#                       [--prompt-tokens N] [--max-tokens N] [--repetitions N]
#                       [--out DIR] [--dry-run]
#
# WHAT IT MEASURES, AND WHAT IT DOES NOT
#   Per slot count: aggregate decode tok/s with N concurrent streams (the number that
#   decides a slot count), plus the per-stream rate and the KV each slot costs
#   (ctx / parallel).  It does NOT re-tune ctx, batch or quantisation — those stay as the
#   lane serves them, so the arms differ in ONE variable.
#
# WHY A RESTART PER ARM
#   --parallel is fixed at process start, so a slot count cannot be changed on a live
#   server.  The probe therefore stops the lane, starts the SAME argv with only --parallel
#   replaced, measures, and restores the lane on exit (trap), including on a signal.
#
# WHY IT IS NOT PART OF cache-ram-probe.sh
#   That probe's measurement is a single-stream BABA prompt sequence: it answers "what does
#   a returning conversation cost", and slots do not help one stream — they divide its ctx.
#   Measuring slots needs a CONCURRENT load generator, which is tools/llm_benchmark.py.
#   The unit-argv parsing below is the same method as cache-ram-probe.sh's __base_from_unit
#   (that script runs its own main, so it cannot be sourced for the helper).
#
# Exit: 0 measured, 1 refused or a failed arm, 2 usage.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BENCH="$REPO_ROOT/tools/llm_benchmark.py"
TAC_PYTHON="${TAC_PYTHON:-$REPO_ROOT/.venv/bin/python3}"
# swallow-ok: a missing python3 is reported by the -x check in parse_args, which refuses
[[ -x "$TAC_PYTHON" ]] || TAC_PYTHON="$(command -v python3 || true)"

UNIT="${LLAMA_CUDA_LANE_UNIT:-}"
VALUES="4,8,16"
CONCURRENCY=""
PROMPT_TOKENS=1800
MAX_TOKENS=256
REPETITIONS=3
OUT_DIR=""
DRY_RUN=0
HEALTH_TIMEOUT=180

# Named exit codes (§18.3 9.7).  The header documents 0/1/2, and a bare `exit 2` at eight
# call sites is exactly the shape that item counts: an exit code is part of a function's
# interface, so it gets a name here rather than a comment repeated eight times.
readonly EXIT_USAGE=2
readonly EXIT_INTERRUPTED=130

# warn — this tool's ONE stderr path, so every refusal has the same shape (10.7).
warn() { printf 'slots-probe: %s\n' "$*" >&2; }

# die_usage — refuse a bad invocation.  One place holds the usage status, so the eight
# argument checks below name their reason and nothing else (9.7), and each stays inside
# the line budget (8.1.8) instead of repeating `exit "$EXIT_USAGE"` on a long line.
die_usage() { warn "FATAL: $*"; exit "$EXIT_USAGE"; }

# usage — the CLI synopsis; stdout on --help, stderr on a bad flag.
usage() {
    printf '%s\n' \
        "usage: slots-probe.sh [--unit U] [--values 4,8,16] [--concurrency N]" \
        "                     [--prompt-tokens N] [--max-tokens N] [--repetitions N]" \
        "                     [--out DIR] [--dry-run]"
}

# parse_args — the CLI.  Refuses an unknown flag rather than silently ignoring it.
parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            --unit) UNIT="${2:?--unit needs a unit name}"; shift 2 ;;
            --values) VALUES="${2:?--values needs a comma list}"; shift 2 ;;
            --concurrency) CONCURRENCY="${2:?--concurrency needs a number}"; shift 2 ;;
            --prompt-tokens) PROMPT_TOKENS="${2:?--prompt-tokens needs a number}"; shift 2 ;;
            --max-tokens) MAX_TOKENS="${2:?--max-tokens needs a number}"; shift 2 ;;
            --repetitions) REPETITIONS="${2:?--repetitions needs a number}"; shift 2 ;;
            --out) OUT_DIR="${2:?--out needs a directory}"; shift 2 ;;
            --dry-run) DRY_RUN=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) usage >&2; die_usage "unknown argument $1" ;;
        esac
    done
    [[ -n "$UNIT" ]] || { usage >&2; die_usage "--unit is required (or set LLAMA_CUDA_LANE_UNIT)"; }
    [[ "$PROMPT_TOKENS" =~ ^[1-9][0-9]*$ ]] || die_usage "--prompt-tokens must be a positive integer"
    [[ "$MAX_TOKENS" =~ ^[1-9][0-9]*$ ]] || die_usage "--max-tokens must be a positive integer"
    [[ "$REPETITIONS" =~ ^[1-9][0-9]*$ ]] || die_usage "--repetitions must be a positive integer"
    [[ -z "$CONCURRENCY" || "$CONCURRENCY" =~ ^[1-9][0-9]*$ ]] \
        || die_usage "--concurrency must be a positive integer"
    # Validate the slot list HERE, not only where it is emitted: a bad entry inside a
    # process substitution cannot set this script's exit status, so a dry run would print
    # a plan and exit 0 (measured 2026-11-09 by this suite's own case).
    local _v
    local -a _vals=()
    IFS=',' read -ra _vals <<< "$VALUES"
    for _v in "${_vals[@]}"; do
        [[ "$_v" =~ ^[1-9][0-9]*$ ]] || die_usage "--values entry '$_v' is not a positive integer"
    done
    [[ -x "$TAC_PYTHON" ]] || { warn "FATAL: no python3 (set TAC_PYTHON)"; exit 1; }
    [[ -f "$BENCH" ]] || { warn "FATAL: $BENCH is missing"; exit 1; }
}

# _slot_values — the requested slot counts, one per line, refusing anything unusable.
# A zero or a non-number is a refusal, not a skipped arm: an arm that silently vanishes
# reads as "measured and equal" in the summary.
_slot_values() {
    local _v
    local -a _parts=()
    IFS=',' read -ra _parts <<< "$VALUES"
    for _v in "${_parts[@]}"; do
        [[ "$_v" =~ ^[1-9][0-9]*$ ]] || { warn "FATAL: --values entry '$_v' is not a positive integer"; return 1; }
        printf '%s\n' "$_v"
    done
}

# _unit_argv — the lane's own argv, with --parallel removed so the arm's value is the only
# one present (a duplicate would be the malformed-arm shape cache-ram-probe.sh records).
# Sets BASE (array), PORT, MODEL_PATH, MODEL_ID, CTX.
_unit_argv() {
    local _line _argv _i
    _line=$(systemctl --user show "$UNIT" -p ExecStart --value) \
        || { warn "FATAL: no ExecStart for $UNIT"; return 1; }
    _argv="${_line#*argv[]=}"
    _argv="${_argv%% ;*}"
    if [[ -z "$_argv" || "$_argv" == "$_line" ]]; then
        warn "FATAL: could not parse argv from $UNIT"
        return 1
    fi
    local -a _words=() _out=()
    read -ra _words <<< "$_argv"
    for (( _i=0; _i<${#_words[@]}; _i++ )); do
        case "${_words[_i]}" in
            --parallel) _i=$(( _i + 1 )); continue ;;
            # Valued-less: every arm adds it, so a copy in the base would be a duplicate.
            --kv-unified) continue ;;
            --port) PORT="${_words[_i+1]:-$PORT}" ;;
            --ctx-size) CTX="${_words[_i+1]:-$CTX}" ;;
            --alias) MODEL_ID="${_words[_i+1]:-$MODEL_ID}" ;;
            -m|--model) MODEL_PATH="${_words[_i+1]:-}" ;;
        esac
        _out+=("${_words[_i]}")
    done
    BASE=("${_out[@]}")
    [[ -n "$MODEL_PATH" ]] || { warn "FATAL: $UNIT names no model"; return 1; }
    [[ -n "$MODEL_ID" ]] || MODEL_ID="${MODEL_PATH##*/}"
    return 0
}

# _quant_from_name — the quantisation token in a GGUF filename, or "unknown".
# The bench artifact records it so two runs are comparable; a guess would be worse than
# the word "unknown", which is what an unrecognised name gets.
_quant_from_name() {
    local _n="${1##*/}"
    if [[ "$_n" =~ (IQ[0-9][A-Z0-9_]*|Q[0-9][A-Z0-9_]*|BF16|F16|F32|FP8) ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    else
        printf 'unknown\n'
    fi
}

# _workload_jsonl <path> — one fixed prompt, repeated by the bench tool's --repetitions.
# Deterministic text, so two arms see the same tokens; the prompt is not saved by the tool.
_workload_jsonl() {
    "$TAC_PYTHON" - "$1" "$PROMPT_TOKENS" <<'PYEOF'
import json, sys
path, tokens = sys.argv[1], int(sys.argv[2])
seed = "The quick brown fox jumps over the lazy dog. "
content = (seed * ((tokens * 5) // len(seed) + 1))[: tokens * 5]
with open(path, "w", encoding="utf-8") as fh:
    fh.write(json.dumps({"id": "slots", "prompt": content}) + "\n")
PYEOF
}

# _wait_health — bounded wait for the arm's server to answer /health.
_wait_health() {
    local _waited=0
    while (( _waited < HEALTH_TIMEOUT )); do
        if curl -fsS --max-time 2 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
        _waited=$(( _waited + 2 ))
    done
    warn "FATAL: the arm's server did not answer /health within ${HEALTH_TIMEOUT}s"
    return 1
}

# _restore_lane — put the lane back.  Installed as the EXIT trap BEFORE the first stop, so
# a refusal, a failed arm or a signal all leave the box serving what it served before.
_restore_lane() {
    [[ "${LANE_STOPPED:-0}" == "1" ]] || return 0
    if systemctl --user start "$UNIT" >/dev/null 2>&1; then
        printf 'slots-probe: restored %s\n' "$UNIT"
    else
        warn "FAILED to restart $UNIT — start it by hand"
    fi
    LANE_STOPPED=0
}

# _run_arm <slots> <outdir> — stop the lane, serve at <slots>, measure, stop the arm.
# Returns non-zero when the arm could not be measured; the caller records that as a
# NOT-RUN rather than as a slow slot count.
_run_arm() {
    local _slots="$1" _dir="$2"
    # Two statements, not one: a later word in the same `local` cannot see an earlier one
    # (SC2318), so the log and artifact paths would have been built from empty values.
    local _log="$_dir/arm-${_slots}.log" _art="$_dir/arm-${_slots}.json"
    local _conc="${CONCURRENCY:-$_slots}"
    # A stop that FAILS is not "already down": `systemctl stop` exits 0 for an inactive
    # unit, so a non-zero status means the lane may still hold the port.  Say so — the
    # health wait below then decides, and a held port fails the arm rather than measuring
    # a server this probe did not start.
    if ! systemctl --user stop "$UNIT" >/dev/null 2>&1; then
        warn "could not stop $UNIT — the arm's port may still be held"
    fi
    LANE_STOPPED=1
    "${BASE[@]}" --parallel "$_slots" --kv-unified >"$_log" 2>&1 &
    local _pid=$!
    if ! _wait_health; then
        # swallow-ok: the arm's server may have exited on its own; the health wait already decided
        kill "$_pid" 2>/dev/null || true
        return 1
    fi
    # swallow-ok: same as above — a server that died during load has nothing to kill
    _workload_jsonl "$_dir/workload.jsonl" || { kill "$_pid" 2>/dev/null || true; return 1; }
    "$TAC_PYTHON" "$BENCH" run \
        --endpoint "http://127.0.0.1:${PORT}" \
        --workloads "$_dir/workload.jsonl" \
        --output "$_art" \
        --model-id "$MODEL_ID" \
        --model-file "$MODEL_PATH" \
        --quantization "$(_quant_from_name "$MODEL_PATH")" \
        --runtime-version "${RUNTIME_VERSION:-unknown}" \
        --runtime-build "${RUNTIME_BUILD:-unknown}" \
        --context-size "$CTX" \
        --max-tokens "$MAX_TOKENS" \
        --repetitions "$REPETITIONS" \
        --concurrency "$_conc" \
        --force >>"$_log" 2>&1
    local _rc=$?
    # swallow-ok: the arm's server is expected to be alive here; a kill that finds it gone is the same end state
    kill "$_pid" 2>/dev/null || true
    # swallow-ok: wait's status is the server's, not the measurement's — the bench's rc is returned
    wait "$_pid" 2>/dev/null || true
    return "$_rc"
}

# _summarise <outdir> <ctx> <values-csv> — the table and the JSON, from the arms' artifacts.
# A REQUESTED arm with no artifact is printed as NOT-RUN: an arm that never measured must
# not read as a slot count that measured badly, and must not vanish from the table either.
_summarise() {
    "$TAC_PYTHON" - "$1" "$2" "$3" <<'PYEOF'
import json, pathlib, sys
out = pathlib.Path(sys.argv[1])
ctx = int(sys.argv[2]) if sys.argv[2].isdigit() else 0
requested = [int(v) for v in sys.argv[3].split(",") if v.strip().isdigit()]
rows = []
for slots in sorted(set(requested)):
    art = out / f"arm-{slots}.json"
    agg = per = None
    if art.is_file():
        try:
            doc = json.loads(art.read_text(encoding="utf-8"))
            summary = doc["workloads"][0]["summary"]
            agg = (summary.get("concurrency_group_decode_tokens_per_second") or {}).get("median")
            per = (summary.get("decode_tokens_per_second") or {}).get("median")
        except (OSError, KeyError, IndexError, ValueError):
            agg = per = None
    rows.append({"slots": slots, "aggregate_tps": agg, "per_stream_tps": per,
                 "kv_mib_per_slot": round(ctx / slots / 1024, 1) if slots and ctx else None})
print(f"{'slots':>5} {'aggregate tok/s':>16} {'per-stream tok/s':>17} {'ctx/slot':>9}")
for r in rows:
    agg = "NOT-RUN" if r["aggregate_tps"] is None else f"{r['aggregate_tps']:.2f}"
    per = "NOT-RUN" if r["per_stream_tps"] is None else f"{r['per_stream_tps']:.2f}"
    kv = "-" if r["kv_mib_per_slot"] is None else f"{r['kv_mib_per_slot']:.0f} MiB"
    print(f"{r['slots']:>5} {agg:>16} {per:>17} {kv:>9}")
(out / "summary.json").write_text(json.dumps({"ctx": ctx, "arms": rows}, indent=2) + "\n",
                                  encoding="utf-8")
PYEOF
}

# dry_run — prove the plan and the argv rewrite, start nothing.
dry_run() {
    local _v
    printf 'slots-probe: DRY RUN — nothing is stopped, started or measured\n'
    printf '  unit:   %s\n' "$UNIT"
    printf '  model:  %s\n' "$MODEL_PATH"
    printf '  port:   %s   ctx: %s\n' "$PORT" "$CTX"
    printf '  base:   %s\n' "${BASE[*]}"
    while IFS= read -r _v; do
        printf '  arm %s: %s --parallel %s --kv-unified   (concurrency %s)\n' \
            "$_v" "${BASE[0]}" "$_v" "${CONCURRENCY:-$_v}"
    done < <(_slot_values)
}

# main — parse, prove the plan, then measure each arm and restore the lane.
main() {
    parse_args "$@"
    _unit_argv || exit 1
    if (( DRY_RUN == 1 )); then
        dry_run
        return 0
    fi
    OUT_DIR="${OUT_DIR:-$REPO_ROOT/logs/slots-probe/$(date -u +%Y%m%dT%H%M%SZ)}"
    mkdir -p "$OUT_DIR" || { warn "FATAL: cannot create $OUT_DIR"; exit 1; }
    trap '_restore_lane' EXIT
    trap 'exit "$EXIT_INTERRUPTED"' INT TERM
    local _v _rc=0
    while IFS= read -r _v; do
        printf 'slots-probe: arm %s slots (concurrency %s)\n' "$_v" "${CONCURRENCY:-$_v}"
        if ! _run_arm "$_v" "$OUT_DIR"; then
            warn "arm $_v did not measure — recorded as NOT-RUN"
            _rc=1
        fi
    done < <(_slot_values)
    _summarise "$OUT_DIR" "$CTX" "$VALUES"
    printf 'slots-probe: artifacts in %s\n' "$OUT_DIR"
    return "$_rc"
}

main "$@"
# end of file
