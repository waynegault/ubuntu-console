#!/usr/bin/env bash
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 1
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

usage() {
    printf '%s\n' \
        "usage: cache-ram-probe.sh [--row N] [--port N] [--order SEQ]" \
        "           [--allow-noninterleaved] [--out DIR] [--dry-run]"
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
            -h|--help) usage; exit 0 ;;
            *) usage >&2; printf 'FATAL: unknown argument %s\n' "$1" >&2; exit 1 ;;
        esac
    done
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
            *) printf "FATAL: order '%s' may contain only A and B (got '%s')\n" "$seq" "$ch" >&2; return 1 ;;
        esac
        i=$(( i + 1 ))
    done
    if ! is_interleaved "$seq"; then
        if (( allow != 1 )); then
            printf "REFUSED: order '%s' is not interleaved — a single pass with this order cannot" "$seq" >&2
            printf " separate the ARM from the POSITION (pass --allow-noninterleaved to override)\n" >&2
            return 1
        fi
        printf "WARNING: order '%s' is not interleaved — arm and position are CONFOUNDED in this run\n" "$seq" >&2
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

source env.sh || { printf 'FATAL: failed to source env.sh\n' >&2; exit 1; }
source "$REPO/bin/_tac-bin-lib.sh"

SUSPEND="${LLAMA_WATCHDOG_CUDA_SUSPEND_FILE:-/dev/shm/llama-watchdog-cuda.suspend}"
LANE="${LLAMA_CUDA_LANE_UNIT:-llama-cuda-llama32-3b-chat.service}"
HEALTH="http://127.0.0.1:${PORT}"
LLAMA_BIN="${LLAMA_SERVER_BIN:-$HOME/llama.cpp/build/bin/llama-server}"
[[ -x "$LLAMA_BIN" ]] || { printf 'FATAL: no llama-server at %s\n' "$LLAMA_BIN" >&2; exit 1; }

OUT_DIR="$OPT_OUT"
[[ "$OUT_DIR" == /* ]] || OUT_DIR="$REPO/$OUT_DIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT_JSON="$OUT_DIR/result-$STAMP.json"
# swallow-ok: mktemp's own failure prints its reason and returns non-zero; the call below
# is guarded by the WORKDIR emptiness test, so nothing is lost silently
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/cache-ram-probe.XXXXXX")"
[[ -d "$WORKDIR" ]] || { printf 'FATAL: no workdir\n' >&2; exit 1; }

# ── snapshot the row (registry-SAFETY proof, part 1) ─────────────────────────
ROW_BEFORE="$(awk -F'|' -v r="$ROW" '$1==r{print; exit}' "$LLM_REGISTRY")"
[[ -n "$ROW_BEFORE" ]] || { printf 'FATAL: row %s not in %s\n' "$ROW" "$LLM_REGISTRY" >&2; exit 1; }

# Read the row as an ARRAY and bind only the columns this probe uses — a named read
# would leave ~20 unused names and shellcheck rightly flags each (SC2034).
IFS='|' read -ra F <<< "$ROW_BEFORE"
name="${F[1]:-}"; file="${F[2]:-}"; qc="${F[4]:-}"; ngl="${F[6]:-}"; ctx="${F[7]:-}"
thr="${F[8]:-}"; ba="${F[9]:-}"; ub="${F[10]:-}"; pa="${F[11]:-}"; fa="${F[15]:-}"
stype="${F[26]:-}"; snmax="${F[28]:-}"; rp="${F[37]:-}"; rln="${F[38]:-}"
MODEL_PATH="$LLAMA_MODEL_DIR/$file"
[[ -f "$MODEL_PATH" ]] || { printf 'FATAL: model file not found: %s\n' "$MODEL_PATH" >&2; exit 1; }
KVK="${qc##*/}"; _kvpre="${qc%/*}"; KVV="${_kvpre##*/}"   # Q4_K_M/q8_0/q8_0 -> q8_0 / q8_0
[[ -n "$KVK" ]] || KVK=q8_0
[[ -n "$KVV" ]] || KVV=q8_0
BLOCK="${snmax:-0}"
[[ "$BLOCK" =~ ^[0-9]+$ ]] && (( BLOCK > 0 )) || BLOCK=16

printf 'cache-ram probe — row %s %s (%s)\n' "$ROW" "$name" "$file"
printf '  registry line (READ ONLY, snapshot): %s\n' "$ROW_BEFORE"
printf '  ctx=%s batch=%s/%s threads=%s ngl=%s parallel=%s flash-attn=%s kv=%s/%s spec=%s(block %s) rp=%s rln=%s\n' \
    "$ctx" "$ba" "$ub" "$thr" "$ngl" "$pa" "$fa" "$KVK" "$KVV" "${stype:-none}" "$BLOCK" "${rp:-unset}" "${rln:-unset}"

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

# ── dry run: prove the argv and the assertions, start nothing ────────────────
dry_run() {
    printf '\nDRY RUN — nothing started, no lane stopped, no suspend taken, registry untouched\n'
    local -a da=("${BASE[@]}") db=("${BASE[@]}" --cache-ram 0)
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
mk_payload "$WORKDIR/p1.json" "$P1_TXT" 1800 128
mk_payload "$WORKDIR/p2.json" "$P2_TXT" 1800 128
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
    # swallow-ok: a pid already gone is the state this seeks; the loop below is the
    # liveness check, so discarding kill's "No such process" loses nothing.
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
    printf '\n=== pos%s ARM %s  (cache-ram: %s)\n' "$pos" "$label" "${cram_val:-OMITTED -> default 8192}"
    local -a argv=("${BASE[@]}")
    [[ -n "$cram_val" ]] && argv+=(--cache-ram "$cram_val")
    printf '    argv: %s\n' "${argv[*]}"
    assert_argv "$label" "$want" "${argv[@]}" || return 1
    "${argv[@]}" > "$out_dir/server.log" 2>&1 &
    pid=$!
    while (( hw < 120 )); do
        sleep 1; hw=$(( hw + 1 ))
        # swallow-ok: kill -0's message is the ANSWER here; the FAIL row reports it.
        if ! kill -0 "$pid" 2>/dev/null; then
            printf '    FAIL: server exited during load — see %s/server.log\n' "$out_dir"
            return 1
        fi
        # swallow-ok: connection-refused while the server loads is EXPECTED; the loop's
        # 120s timeout is the verdict, so curl's noise carries no information.
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
        # swallow-ok (both redirects): the connection may be refused while the server
        # finishes binding (EXPECTED), and parsing an empty body is the false case the
        # loop retries; the pf==1 check below is the verdict.
        if curl -sS --max-time 5 "$HEALTH/v1/chat/completions" -H "Content-Type: application/json" \
            -d '{"messages":[{"role":"user","content":"hi"}],"max_tokens":1,"temperature":0}' 2>/dev/null \
            | "$TAC_PYTHON" -c "$_PF_PARSE" 2>/dev/null | grep -q '[1-9]'; then
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
    printf '    server healthy in %ss, pre-flight ok — measuring (R1 cold, R2 switch, R3 reuse)\n' "$hw"
    measure "$WORKDIR/warmup.json" "$out_dir/warmup.json" >/dev/null
    measure "$WORKDIR/p1.json" "$out_dir/r1.json"
    measure "$WORKDIR/p2.json" "$out_dir/r2.json"
    measure "$WORKDIR/p1.json" "$out_dir/r3.json"
    term_server "$pid"
    return 0
}

# summarise <workdir> <order-seq> <result-json> <row> — print the per-position table,
# the per-arm means, the DELTA, and the position-drift verdict; write the JSON result.
summarise() {
    "$TAC_PYTHON" - "$1" "$2" "$3" "$4" "$DRIFT_WARN_PCT" <<'PYEOF'
import glob, json, os, re, sys
wd, seq, result_path, row, drift_pct = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], float(sys.argv[5])
rows = []
for d in sorted(glob.glob(os.path.join(wd, "pos*")), key=lambda p: int(re.search(r"pos(\d+)", p).group(1))):
    m = re.search(r"pos(\d+)_([AB])$", d)
    if not m:
        continue
    def rr(name, d=d):
        p = os.path.join(d, name)
        return json.load(open(p)) if os.path.exists(p) else None
    rows.append({"pos": int(m.group(1)), "arm": m.group(2), "r1": rr("r1.json"), "r3": rr("r3.json")})
for r in rows:
    if not r["r1"] or not r["r3"]:
        print(f"  pos{r['pos']} ARM {r['arm']}: INCOMPLETE")
        continue
    print(f"  pos{r['pos']} ARM {r['arm']}: decode_cold={r['r1']['server_decode_tps']:.2f} tps"
          f"  decode_reuse={r['r3']['server_decode_tps']:.2f} tps"
          f"  | ttft_cold={r['r1']['ttft_ms']} ms  ttft_reuse={r['r3']['ttft_ms']} ms"
          f"  | prompt_ms_cold={r['r1']['server_prompt_ms']:.0f}  prompt_ms_reuse={r['r3']['server_prompt_ms']:.0f}")
def mean(vals):
    return sum(vals) / len(vals) if vals else float("nan")
arms = {a: [r for r in rows if r["arm"] == a and r["r1"] and r["r3"]] for a in ("A", "B")}
for a in ("A", "B"):
    rs = arms[a]
    if not rs:
        continue
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

# ── take the card: hold the watchdog off, stop the lane (bin/bench-rows.sh pattern)
if ! _tac_suspend_acquire "$SUSPEND"; then
    printf 'FATAL: could not acquire the CUDA suspend hold (%s)\n' "$SUSPEND" >&2
    exit 1
fi
trap '_tac_suspend_release "$SUSPEND"' EXIT
# swallow-ok: a lane already down is the state this seeks; the free-VRAM loop below
# is the check that the card was actually released.
systemctl --user stop "$LANE" >/dev/null 2>&1
_sw=0
while (( _sw < 45 )); do
    _free="$(_free_mib)"
    [[ "$_free" =~ ^[0-9]+$ ]] || break
    (( _free > 3000 )) && break
    sleep 2
    _sw=$(( _sw + 1 ))
done
printf '\ncard free before start: %s MiB\n' "${_free:-unknown}"

_seq_out="$(parse_order "$OPT_ORDER" "$OPT_ALLOW_NI")"
_prc=$?
if (( _prc != 0 )); then
    printf 'FATAL: refusing to start — the order was rejected (see above)\n' >&2
    exit 1
fi
[[ -n "$_seq_out" ]] || { printf 'FATAL: the order produced no arms\n' >&2; exit 1; }
mapfile -t _arm_seq <<< "$_seq_out"
printf 'arm sequence this run: %s\n' "${_arm_seq[*]}"

mkdir -p "$OUT_DIR"
_fail=0
_pos=0
for _arm in "${_arm_seq[@]}"; do
    _pos=$(( _pos + 1 ))
    case "$_arm" in
        A) run_arm A ""  "$_pos" || _fail=1 ;;
        B) run_arm B "0" "$_pos" || _fail=1 ;;
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
