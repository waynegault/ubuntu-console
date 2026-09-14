#!/usr/bin/env bash
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 1
# ==============================================================================
# interview-benchmark.sh — run the 5-question "Rook" interview against one model
# in the registry, and report decode/prefill throughput.
#
# Why this exists rather than the old ~/.local/bin/llm-model-test.sh: that script
# reimplemented the launcher and had drifted away from it.  It read the registry
# columns one field off (row #35 would have launched `-ngl 131072 -c 6 -t 1024`),
# passed --mlock (removed upstream — fatal on build 10955), killed processes by
# name (`pkill -f llama-server`, which evicts the Xe fleet) and bound the
# production port :8081 by hand.  Every one of those is structurally impossible
# here: the model is started by the supported launcher and the port is READ from
# the console, never assumed.
#
# Usage: interview-benchmark.sh <model-number>
#        (the model is left serving afterwards; `tac-exec model stop` when done)
# ==============================================================================
set -uo pipefail

# The prompt set is the only thing this wrapper adds; it is what the old script
# was for.  Everything else comes from the console.
QUESTIONS='You are a research agent named Rook. Answer these 5 questions concisely:

1. What is your name and role?
2. Explain what a neural network is in simple terms.
3. What is 15 × 17?
4. Write a short poem about AI.
5. What are your thoughts on the future of local LLMs?

Answers:'

main() {
    local n="${1:-}"
    if [[ ! "$n" =~ ^[0-9]+$ ]]; then
        echo "usage: $(basename "$0") <model-number>" >&2
        return 2
    fi

    echo "[interview] starting model #$n through the supported launcher ..."
    if ! tac-exec model use "$n"; then
        echo "[interview] could not start model #$n" >&2
        return 1
    fi

    # Read the port back from the console — do not assume :8081.
    local port
    port=$(tac-exec model status --plain 2>/dev/null | sed -n 's/^port=//p' | head -1)
    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        echo "[interview] could not determine the serving port from 'model status --plain'" >&2
        return 1
    fi

    local body resp
    body=$(jq -n --arg p "$QUESTIONS" \
        '{prompt: $p, n_predict: 400, temperature: 0.7, stream: false}') || {
        echo "[interview] could not build the request (jq failed)" >&2
        return 1
    }

    echo "[interview] asking the 5 questions on :${port} ..."
    resp=$(curl -s --max-time 300 -H 'Content-Type: application/json' \
        -d "$body" "http://127.0.0.1:${port}/completion") || {
        echo "[interview] request to :${port} failed" >&2
        return 1
    }

    echo
    echo "=== RESPONSE ==="
    printf '%s\n' "$resp" | jq -r '.content // "(no content in the response)"'
    echo
    echo "=== METRICS ==="
    # timings comes from llama.cpp's /completion; /v1/chat/completions does not
    # carry it, which is why this uses the native endpoint.
    printf '%s\n' "$resp" | jq -r '
        "decode: \((.timings.predicted_n // "?") | tostring) tokens in \((.timings.predicted_ms // "?") | tostring) ms"
        + "  ->  \((.timings.predicted_per_second // "?") | if type == "number" then ((.*10|floor)/10|tostring) else tostring end) tps",
        "prefill: \((.timings.prompt_n // "?") | tostring) tokens in \((.timings.prompt_ms // "?") | tostring) ms"
        + "  ->  \((.timings.prompt_per_second // "?") | if type == "number" then ((.*10|floor)/10|tostring) else tostring end) tps"'
    echo
    echo "[interview] model #$n is still serving on :${port} — 'tac-exec model stop' when done."
}

main "$@"

# end of file
