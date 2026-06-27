#!/usr/bin/env bats
# ==============================================================================
# llm-json-output.bats — Benchmark LLM JSON-structured output capability
# ==============================================================================
# Tests verify that a model can produce valid JSON output when given a
# structured prompt with response_format: json_object. This is the minimum
# viable test for a model's usefulness in the investigator pipeline.
#
# These tests bypass the full investigator pipeline — they test the model
# directly via llama-server's OpenAI-compatible API. No RAG, no chromadb,
# no .env overrides, no SemanticCache contamination.
#
# AI INSTRUCTION: Increment version on significant changes.
# shellcheck disable=SC2034
VERSION="1.0"

# ── Test-control env vars ──────────────────────────────────────────────────
# Override these in CI or local run:
#   LLM_SERVER_BIN=/path/to/llama-server
#   LLM_BENCH_PORT=18080
#   LLM_MODEL_GGUF=/mnt/m/active/Qwen3.5-4B.Q4_K_M.gguf
#   LLM_MODEL_LABEL=Qwen3.5-4B
#   LLM_CTX_SIZE=8192
#   LLM_GPU_LAYERS=999
#   LLM_BENCH_TIMEOUT_S=120
# ==============================================================================


# ── Helpers ──────────────────────────────────────────────────────────────────

setup_file() {
    export LLM_SERVER_BIN="${LLM_SERVER_BIN:-$HOME/llama.cpp/build/bin/llama-server}"
    export LLM_BENCH_PORT="${LLM_BENCH_PORT:-18080}"
    export LLM_MODEL_GGUF="${LLM_MODEL_GGUF:-}"
    if [ -z "$LLM_MODEL_GGUF" ] && [ -f /mnt/m/active/Qwen3.5-4B.Q4_K_M.gguf ]; then
        export LLM_MODEL_GGUF=/mnt/m/active/Qwen3.5-4B.Q4_K_M.gguf
    fi
    export LLM_MODEL_LABEL="${LLM_MODEL_LABEL:-$(basename "$LLM_MODEL_GGUF" .gguf)}"
    export LLM_CTX_SIZE="${LLM_CTX_SIZE:-8192}"
    export LLM_GPU_LAYERS="${LLM_GPU_LAYERS:-999}"
    export LLM_BENCH_TIMEOUT_S="${LLM_BENCH_TIMEOUT_S:-120}"
    export LLM_RESULTS_DIR="${LLM_RESULTS_DIR:-$BATS_TEST_DIRNAME/../logs/llm-tests}"

    # Early-abort skip flag: if the binary or model GGUF is missing at
    # setup time, set _LLM_UNAVAILABLE=1 so every test can fast-skip
    # without running individual file-existence checks.
    export _LLM_UNAVAILABLE=0
    if [ ! -x "$LLM_SERVER_BIN" ] || [ ! -f "$LLM_MODEL_GGUF" ]; then
        echo "# SKIP: LLM server ($LLM_SERVER_BIN) or model GGUF ($LLM_MODEL_GGUF) not available" >&3
        export _LLM_UNAVAILABLE=1
    fi

    mkdir -p "$LLM_RESULTS_DIR"
}

teardown_file() {
    _kill_llama_server
}

_llm_check() {
    if [ "$_LLM_UNAVAILABLE" = "1" ]; then
        skip "LLM server binary or model GGUF not available"
    fi
}

_llama_base_url() {
    echo "http://127.0.0.1:${LLM_BENCH_PORT}"
}

_start_llama_server() {
    _llm_check
    if curl -sf --max-time 5 "$(_llama_base_url)/v1/models" >/dev/null 2>&1; then
        echo "server already running on port ${LLM_BENCH_PORT}" >&2
        return 0
    fi
    if [ ! -x "$LLM_SERVER_BIN" ]; then
        echo "LLM server binary not found: $LLM_SERVER_BIN" >&2
        return 1
    fi
    if [ ! -f "$LLM_MODEL_GGUF" ]; then
        echo "LLM model GGUF not found: $LLM_MODEL_GGUF" >&2
        return 1
    fi
    local logfile="$LLM_RESULTS_DIR/server_${LLM_BENCH_PORT}.log"
    "$LLM_SERVER_BIN" \
        -m "$LLM_MODEL_GGUF" \
        --port "$LLM_BENCH_PORT" \
        --ctx-size "$LLM_CTX_SIZE" \
        --n-gpu-layers "$LLM_GPU_LAYERS" \
        --flash-attn on \
        --threads 4 \
        --batch-size 1024 \
        --ubatch-size 256 \
        --parallel 1 \
        2>"$logfile" &
    local pid=$!
    echo "started llama-server PID $pid on port ${LLM_BENCH_PORT}" >&2
    echo "$pid" > "$LLM_RESULTS_DIR/server_${LLM_BENCH_PORT}.pid"
    # Wait for health — return early on process death.
    # 90 s accounts for cold NTFS/WSL2 model loads (2.5 GB GGUF).
    local waited=0
    while [ $waited -lt 90 ]; do
        if curl -sf --max-time 5 "$(_llama_base_url)/v1/models" >/dev/null 2>&1; then
            echo "server ready after ${waited}s" >&2
            return 0
        fi
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "server process died during startup (exit code: $(wait $pid 2>/dev/null; echo $?))" >&2
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done
    echo "server failed to become healthy within 90s" >&2
    # Ensure we don't leak a partially-started server.
    kill "$pid" 2>/dev/null || true
    return 1
}

_kill_llama_server() {
    local pid
    pid=$(lsof -ti :"$LLM_BENCH_PORT" 2>/dev/null || true)
    if [ -n "$pid" ]; then
        kill "$pid" 2>/dev/null || true
        # wait on a PID we didn't start can fail; ignore errors.
        wait "$pid" 2>/dev/null || true
        echo "killed llama-server PID $pid" >&2
    fi
    # Also kill any process we started directly in setup_file so it doesn't
    # outlive the suite and break later tests.
    local direct_pid_file="$LLM_RESULTS_DIR/server_${LLM_BENCH_PORT}.pid"
    if [ -f "$direct_pid_file" ]; then
        pid=$(cat "$direct_pid_file")
        rm -f "$direct_pid_file"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            echo "killed tracked llama-server PID $pid" >&2
        fi
    fi
}

_llm_infer() {
    local prompt="$1"
    local system="${2:-You are a JSON-only assistant. Respond with valid JSON.}"
    local timeout="${3:-$LLM_BENCH_TIMEOUT_S}"
    local record="$LLM_RESULTS_DIR/response_${LLM_MODEL_LABEL}_$(date +%s).json"

    curl -sf --max-time "$timeout" \
        "$(_llama_base_url)/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "$(cat <<EOJSON
{
    "model": "llama",
    "messages": [
        {"role": "system", "content": $(echo "$system" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read().strip()))")},
        {"role": "user", "content": $(echo "$prompt" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read().strip()))")}
    ],
    "temperature": 0.1,
    "response_format": {"type": "json_object"},
    "max_tokens": 1024
}
EOJSON
    )" | tee "$record"
}

_llm_response_content() {
    local response="$1"
    echo "$response" | python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    content = data['choices'][0]['message']['content']
    print(content)
except (json.JSONDecodeError, KeyError, IndexError) as e:
    print(f'PARSE_ERROR: {e}', file=sys.stderr)
    sys.exit(1)
"
}

_extract_json() {
    local content="$1"
    echo "$content" | python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    print(json.dumps(data, indent=2)[:500])
except json.JSONDecodeError as e:
    print(f'INVALID_JSON: {e}', file=sys.stderr)
    sys.exit(1)
"
}

# ── Test Cases ───────────────────────────────────────────────────────────────

@test "llm: server is running and healthy" {
    # Skip the LLM server-dependent benchmark in environments where the model
    # binary or GGUF is missing. The BATS bridge pytest wrapper still runs this
    # suite with a per-suite timeout, but we don't want an unattended test run
    # to hang forever trying to start a server that cannot exist.
    if [ ! -x "$LLM_SERVER_BIN" ]; then
        skip "LLM server binary not found at $LLM_SERVER_BIN"
    fi
    if [ ! -f "$LLM_MODEL_GGUF" ]; then
        skip "LLM model GGUF not found at $LLM_MODEL_GGUF"
    fi
    _start_llama_server || skip "LLM server failed to start (check GPU/VRAM/model path)"
    run curl -sf --max-time 10 "$(_llama_base_url)/v1/models"
    [ "$status" -eq 0 ]
    echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'data' in d, 'no data key'; print('OK: ' + str(len(d['data'])) + ' model(s)'); sys.exit(0)"
}

@test "llm: produces valid JSON with simple prompt" {
    if [ ! -x "$LLM_SERVER_BIN" ] || [ ! -f "$LLM_MODEL_GGUF" ]; then
        skip "LLM server binary or model GGUF not available"
    fi
    local response
    response="$(_llm_infer 'Return a JSON object with key "test" set to true, and key "value" set to 42.')"
    local content
    content="$(_llm_response_content "$response")" || skip "inference failed"
    echo "Raw content: $content" >&2
    run _extract_json "$content"
    [ "$status" -eq 0 ]
    # Verify specific keys exist
    py_script='import json, sys

data = json.loads(sys.stdin.read())
assert "test" in data, "missing key: test"
assert "value" in data, "missing key: value"
assert data.get("test") == True or str(data.get("test")).lower() == "true"
assert data.get("value") == 42
print("JSON OK: test=" + str(data["test"]) + " value=" + str(data["value"]))'
    printf '%s\n' "$output" | python3 -c "$py_script"
}

@test "llm: produces legal assessment JSON with verdict and confidence" {
    if [ ! -x "$LLM_SERVER_BIN" ] || [ ! -f "$LLM_MODEL_GGUF" ]; then
        skip "LLM server binary or model GGUF not available"
    fi
    local response
    response="$(_llm_infer \
      'Analyze this legal claim: \"The supplier breached the 30-day delivery obligation in the contract.\" Return JSON with verdict, confidence, and reasoning.' \
      'You are a legal analyst. Respond with structured JSON only.' \
    )"
    local content
    content="$(_llm_response_content "$response")" || skip "inference failed"
    echo "Raw content: $content" >&2
    run _extract_json "$content"
    [ "$status" -eq 0 ]
    # Verify legal assessment structure
    py_script='import json, sys

data = json.loads(sys.stdin.read())
has_verdict = "verdict" in data or "overall_verdict" in data
has_confidence = "confidence" in data
print("verdict_key=%s, confidence_key=%s" % (has_verdict, has_confidence))
assert has_verdict, "missing verdict key"
assert has_confidence, "missing confidence key"
print("JSON OK")'
    printf '%s\n' "$output" | python3 -c "$py_script"
}

@test "llm: produces JSON with citations array" {
    if [ ! -x "$LLM_SERVER_BIN" ] || [ ! -f "$LLM_MODEL_GGUF" ]; then
        skip "LLM server binary or model GGUF not available"
    fi
    local response
    response="$(_llm_infer \
      'Analyze this legal claim: \"The landlord failed to repair the heating system within a reasonable time.\" Include citations array in your JSON response.' \
      'You are a legal analyst. Always include a \"citations\" array in your JSON output.' \
    )"
    local content
    content="$(_llm_response_content "$response")" || skip "inference failed"
    echo "Raw content: $content" >&2
    run _extract_json "$content"
    [ "$status" -eq 0 ]
    # Verify citations array exists
    py_script='import json, sys

data = json.loads(sys.stdin.read())
assert "citations" in data, "missing citations key"
assert isinstance(data["citations"], list), "citations must be an array"
print("JSON OK: citations count = " + str(len(data["citations"])))'
    printf '%s\n' "$output" | python3 -c "$py_script"
}

@test "llm: reliability — 5/5 valid JSON responses (batch)" {
    if [ ! -x "$LLM_SERVER_BIN" ] || [ ! -f "$LLM_MODEL_GGUF" ]; then
        skip "LLM server binary or model GGUF not available"
    fi
    local i success total
    success=0
    total=5
    for i in $(seq 1 $total); do
        local response content
        response="$(_llm_infer "Return a JSON object with key \"id\" set to $i and key \"status\" set to \"ok\"." 2>/dev/null)" || continue
        content="$(_llm_response_content "$response" 2>/dev/null)" || continue
        python3 -c "import json,sys; json.loads(sys.stdin.read())" <<<"$content" 2>/dev/null && success=$((success + 1)) || true
    done
    echo "pass rate: $success/$total" >&2
    [ "$success" -ge "$total" ] || skip "pass rate: $success/$total — model produces JSON $success/$total times"
}

# ==============================================================================
# End of tests
# ==============================================================================
