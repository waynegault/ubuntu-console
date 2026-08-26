#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2154
#===============================================================================
# spec_dec_crossover.sh — SPEC-DEC-005 concurrency crossover measurement.
#
# Measures the parallel level at which speculative decoding flips from a net
# gain to a net loss (the "crossover"): for each parallel slot count, launch
# llama-server with spec-decode ON (ngram block B) and OFF, fire N concurrent
# completions of the legal-RAG prompt set, and compare aggregate
# delivered-token throughput (SPEC-DEC-003 de-inflation: min(usage.completion
# _tokens, max_tokens) per request).  The crossover is the smallest parallel
# where spec-OFF aggregate TPS >= spec-ON aggregate TPS.
#
# Procedure documented in investigator docs/spec-dec-policy.md
# ("Crossover measurement").  The (ctx, parallel) envelope from AUTOTUNE-004
# is the ceiling: launching --parallel P above the model's recorded envelope
# over-subscribes the 4 GB card, so the sweep stops at the envelope.
#
# Usage:
#   spec_dec_crossover.sh --model NUM [--block-size N] [--ctx N]
#       [--parallel-list "1 2 4"] [--requests N] [--max-tokens N]
#       [--port N] [--out PATH]
#
# REF: "Speculative Decoding on CPUs — Nearly 4x Faster Token Generation
# with DFlash" (Intel, TDS 2026)
# https://towardsdatascience.com/speculative-decoding-on-cpus-nearly-4x-faster-token-generation-with-dflash/
#===============================================================================

set -uo pipefail

_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$_SELF_DIR/.." || exit 1

MODEL=""
BLOCK_SIZE=16
CTX=""
PARALLEL_LIST="1 2 4"
REQUESTS=8
MAX_TOKENS=256
PORT=18083
OUT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --model) MODEL="${2:-}"; shift 2 ;;
        --block-size) BLOCK_SIZE="${2:-16}"; shift 2 ;;
        --ctx) CTX="${2:-}"; shift 2 ;;
        --parallel-list) PARALLEL_LIST="${2:-}"; shift 2 ;;
        --requests) REQUESTS="${2:-8}"; shift 2 ;;
        --max-tokens) MAX_TOKENS="${2:-256}"; shift 2 ;;
        --port) PORT="${2:-18083}"; shift 2 ;;
        --out) OUT="${2:-}"; shift 2 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

[[ -n "$MODEL" ]] || { echo "Error: --model NUM required" >&2; exit 1; }

source env.sh 2>/dev/null || { echo "Failed to source env.sh" >&2; exit 1; }
source scripts/prompt-sets.sh 2>/dev/null || true

ENTRY=$(grep "^${MODEL}|" "$LLM_REGISTRY" 2>/dev/null) || {
    echo "Error: Model #${MODEL} not found in registry" >&2; exit 1; }

IFS='|' read -r _num name file size _qc _arch gpu_layers _ctx _thr _ba _ub _pa _fi _be _mm _fa _tps _autotuned _isdef _vram _prefill _p2ctx _p2b _p2u _p2tps _p2pf _stype _sdmodel _snmax _sngl _sdevice _sacceptlen _workload _ttft _bctx _bmaxch _bavgpt <<< "$ENTRY"

MODEL_PATH="$LLAMA_MODEL_DIR/$file"
[[ -f "$MODEL_PATH" ]] || { echo "Error: File not found: $MODEL_PATH" >&2; exit 1; }

# Registry params (thread cap 6 = SPEC-DEC-002 P-core ceiling).
TUNE_THREADS=$_thr
[[ "$TUNE_THREADS" =~ ^[0-9]+$ ]] || TUNE_THREADS=4
(( TUNE_THREADS > 6 )) && TUNE_THREADS=6
BATCH=$_ba; U_BATCH=$_ub
[[ "$BATCH" =~ ^[0-9]+$ ]] || BATCH=1024
[[ "$U_BATCH" =~ ^[0-9]+$ ]] || U_BATCH=512
[[ -z "$CTX" ]] && CTX=$_ctx
[[ "$CTX" =~ ^[0-9]+$ ]] || { echo "Error: cannot resolve ctx for model $MODEL" >&2; exit 1; }
[[ "$BLOCK_SIZE" =~ ^[0-9]+$ ]] || BLOCK_SIZE=16
[[ "$REQUESTS" =~ ^[0-9]+$ ]] || REQUESTS=8
[[ "$MAX_TOKENS" =~ ^[0-9]+$ ]] || MAX_TOKENS=256

echo "spec-dec crossover — ${name} (${file}, ${size})"
echo "  ctx=${CTX} batch=${BATCH}/${U_BATCH} threads=${TUNE_THREADS} block=${BLOCK_SIZE}"
echo "  parallel list: ${PARALLEL_LIST}  requests/level: ${REQUESTS}  max_tokens: ${MAX_TOKENS}"

LLAMA_BIN="${LLAMA_SERVER_BIN:-$HOME/llama.cpp/build/bin/llama-server}"
WORKDIR="/tmp/spec-crossover-$$"
mkdir -p "$WORKDIR"

# Prompt pool: the legal-RAG set (SPEC-DEC-006) — the investigator's real
# workload distribution for this measurement.
declare -a PROMPT_POOL=("${PROMPTS_LEGAL[@]:-}")
if [[ ${#PROMPT_POOL[@]} -eq 0 ]]; then
    PROMPT_POOL=(
        "Analyse whether the employer engaged with the mediation process in good faith, citing the passages that support your verdict."
        "Does the respondent have a prima facie case for constructive dismissal? Assess each element against the evidence."
        "Weigh the causation evidence against the contributory-conduct evidence and determine the appropriate reduction."
        "Assess whether the PCP put the claimant at a particular disadvantage and whether the justification meets the proportionality test."
        "Interpret 'such other period as the tribunal considers reasonable' in the context of the ACAS early-conciliation extension."
    )
fi

# aggregate_throughput <parallel> <spec_flag> — fire REQUESTS concurrent
# completions, print "delivered|usage|elapsed_ms".
aggregate_throughput() {
    local _parallel="$1" _spec_on="$2"
    local _port="$PORT"
    local _log="$WORKDIR/server-p${_parallel}-spec${_spec_on}.log"
    local _pid=""

    # ── launch server ────────────────────────────────────────────────────────
    local -a spec_args=()
    if [[ "$_spec_on" == "1" ]]; then
        spec_args=(--spec-type ngram-mod \
            --spec-ngram-mod-n-max "$BLOCK_SIZE" \
            --spec-ngram-mod-n-min "$BLOCK_SIZE")
    fi
    local _ngl=999
    [[ "$gpu_layers" =~ ^[0-9]+$ ]] && _ngl="$gpu_layers"
    "$LLAMA_BIN" --model "$MODEL_PATH" --port "$_port" --host 127.0.0.1 \
        --ctx-size "$CTX" --batch-size "$BATCH" --ubatch-size "$U_BATCH" \
        --threads "$TUNE_THREADS" --n-gpu-layers "$_ngl" \
        --parallel "$_parallel" --fit off --flash-attn on --kv-offload \
        --cache-type-k q8_0 --cache-type-v q8_0 \
        "${spec_args[@]}" \
        > "$_log" 2>&1 &
    _pid=$!
    local _hw=0
    while [[ $_hw -lt 90 ]]; do
        sleep 1; _hw=$((_hw + 1))
        kill -0 "$_pid" 2>/dev/null || { echo "server died at launch" >&2; return 1; }
        curl -sS --max-time 2 "http://127.0.0.1:$_port/health" 2>/dev/null | grep -q 'ok' && break
    done
    if [[ $_hw -ge 90 ]]; then
        echo "server failed to become healthy (parallel=$_parallel spec=$_spec_on)" >&2
        kill -9 "$_pid" 2>/dev/null
        return 1
    fi
    # Pre-flight: one real completion (load may outlast /health).
    local _pf=0 _w=0
    while [[ $_w -lt 60 ]]; do
        if curl -sS --max-time 5 "http://127.0.0.1:$_port/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d '{"messages":[{"role":"user","content":"hi"}],"max_tokens":1,"temperature":0}' \
            2>/dev/null | "$TAC_PYTHON" -c "import sys,json;print(json.load(sys.stdin).get('usage',{}).get('completion_tokens',0))" 2>/dev/null | grep -q '[1-9]'; then
            _pf=1; break
        fi
        kill -0 "$_pid" 2>/dev/null || break
        sleep 1; _w=$((_w + 1))
    done
    if [[ $_pf -ne 1 ]]; then
        echo "server pre-flight failed (parallel=$_parallel spec=$_spec_on)" >&2
        kill -9 "$_pid" 2>/dev/null
        return 1
    fi

    # ── fire REQUESTS concurrent completions ────────────────────────────────
    local _start_ns _end_ns
    _start_ns=$(date +%s%N)
    local _i _pi
    for (( _i = 0; _i < REQUESTS; _i++ )); do
        _pi=$(( _i % ${#PROMPT_POOL[@]} ))
        "$TAC_PYTHON" - "$_port" "$_pi" "$MAX_TOKENS" "$WORKDIR/resp-p${_parallel}-spec${_spec_on}-${_i}.json" << 'PYEOF' &
import json, sys, urllib.request
port, idx, max_tokens, out = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
pool = [
    "Analyse whether the employer engaged with the mediation process in good faith, citing the passages that support your verdict.",
    "Does the respondent have a prima facie case for constructive dismissal? Assess each element against the evidence.",
    "Weigh the causation evidence against the contributory-conduct evidence and determine the appropriate reduction.",
    "Assess whether the PCP put the claimant at a particular disadvantage and whether the justification meets the proportionality test.",
    "Interpret 'such other period as the tribunal considers reasonable' in the context of the ACAS early-conciliation extension.",
]
payload = json.dumps({
    "messages": [
        {"role": "system", "content": "You are a legal analyst. Respond concisely."},
        {"role": "user", "content": pool[idx % len(pool)]},
    ],
    "max_tokens": max_tokens,
    "temperature": 0,
}).encode()
req = urllib.request.Request(
    f"http://127.0.0.1:{port}/v1/chat/completions",
    data=payload,
    headers={"Content-Type": "application/json"},
)
try:
    with urllib.request.urlopen(req, timeout=600) as resp:
        data = json.loads(resp.read())
    with open(out, "w") as f:
        json.dump({"ok": True, "data": data}, f)
except Exception as exc:
    with open(out, "w") as f:
        json.dump({"ok": False, "error": str(exc)}, f)
PYEOF
    done
    wait
    _end_ns=$(date +%s%N)

    kill "$_pid" 2>/dev/null; sleep 1; kill -9 "$_pid" 2>/dev/null

    # ── aggregate ────────────────────────────────────────────────────────────
    "$TAC_PYTHON" - "$WORKDIR" "$_spec_on" "$MAX_TOKENS" "$_start_ns" "$_end_ns" << 'PYEOF'
import glob, json, os, sys
workdir, spec_on, max_tokens, start_ns, end_ns = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
delivered = 0
usage = 0
ok = 0
errors = 0
for path in glob.glob(os.path.join(workdir, f"resp-p*spec{spec_on}-*.json")):
    try:
        with open(path) as f:
            rec = json.load(f)
    except Exception:
        errors += 1
        continue
    if not rec.get("ok"):
        errors += 1
        continue
    data = rec["data"]
    u = data.get("usage", {}) or {}
    u_tokens = int(u.get("completion_tokens", 0) or 0)
    usage += u_tokens
    delivered += min(u_tokens, max_tokens)
    ok += 1
elapsed_ms = (int(end_ns) - int(start_ns)) / 1_000_000.0
tps = (delivered * 1000.0 / elapsed_ms) if elapsed_ms > 0 else 0.0
print(f"{delivered}|{usage}|{elapsed_ms:.0f}|{tps:.2f}|{ok}|{errors}")
PYEOF
}

echo ""
echo "  measuring crossover (spec block ${BLOCK_SIZE}, ${REQUESTS} concurrent requests)"
echo "  ============================================================================="
RESULTS_FILE="$WORKDIR/results.tsv"
: > "$RESULTS_FILE"

for _p in $PARALLEL_LIST; do
    [[ "$_p" =~ ^[0-9]+$ ]] || continue
    _on=$(aggregate_throughput "$_p" "1") || { echo "  parallel ${_p}: spec-ON launch failed — stopping sweep" >&2; break; }
    _off=$(aggregate_throughput "$_p" "0") || { echo "  parallel ${_p}: spec-OFF launch failed — stopping sweep" >&2; break; }
    IFS='|' read -r _on_d _on_u _on_ms _on_tps _on_ok _on_err <<< "$_on"
    IFS='|' read -r _off_d _off_u _off_ms _off_tps _off_ok _off_err <<< "$_off"
    _ratio=$(awk -v on="$_on_tps" -v off="$_off_tps" 'BEGIN { if (off > 0) printf "%.2f", on/off; else print "inf" }')
    echo "  parallel ${_p}: spec-ON ${_on_tps} t/s (${_on_d}/${_on_u} tok, ${_on_ms} ms)  spec-OFF ${_off_tps} t/s (${_off_d}/${_off_u} tok, ${_off_ms} ms)  ratio ${_ratio}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$_p" "$_on_tps" "$_off_tps" "$_ratio" "$_on_d" "$_off_d" >> "$RESULTS_FILE"
done

echo ""
# ── verdict: smallest parallel where spec-OFF >= spec-ON ─────────────────────
CROSSOVER=""
while IFS=$'\t' read -r _p _on _off _ratio _on_d _off_d; do
    if [[ -z "$CROSSOVER" ]] && awk -v on="$_on" -v off="$_off" 'BEGIN { exit !(off >= on) }'; then
        CROSSOVER="$_p"
    fi
done < "$RESULTS_FILE"
if [[ -z "$CROSSOVER" ]]; then
    echo "  crossover: none in [$PARALLEL_LIST] — spec-decode stays a net GAIN at every tested parallel level"
    CROSSOVER=">$(echo "$PARALLEL_LIST" | tr ' ' '\n' | tail -1)"
else
    echo "  crossover: parallel=${CROSSOVER} — spec-decode flips to a net LOSS at parallel >= ${CROSSOVER}"
fi
echo "  (model ${MODEL} ${name}, block ${BLOCK_SIZE}, ctx ${CTX})"

# ── persist ──────────────────────────────────────────────────────────────────
if [[ -n "$OUT" ]]; then
    {
        echo "{"
        echo "  \"model\": \"${name}\","
        echo "  \"model_num\": \"${MODEL}\","
        echo "  \"block_size\": ${BLOCK_SIZE},"
        echo "  \"ctx\": ${CTX},"
        echo "  \"requests_per_level\": ${REQUESTS},"
        echo "  \"crossover_parallel\": \"${CROSSOVER}\","
        echo "  \"levels\": ["
        _first=1
        while IFS=$'\t' read -r _p _on _off _ratio _on_d _off_d; do
            [[ $_first -eq 1 ]] || echo ","
            printf '    {"parallel": %s, "spec_on_tps": %s, "spec_off_tps": %s, "ratio": %s, "spec_on_delivered": %s, "spec_off_delivered": %s}' \
                "$_p" "$_on" "$_off" "$_ratio" "$_on_d" "$_off_d"
            _first=0
        done < "$RESULTS_FILE"
        echo ""
        echo "  ]"
        echo "}"
    } > "$OUT"
    echo "wrote $OUT"
fi

rm -rf "$WORKDIR"
