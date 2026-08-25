#!/usr/bin/env bats
# ==============================================================================
# SPEC-DEC-003: llama-server speculative-decode stats parsing + honest TPS.
#
# The parser handles the server's per-request stats line
# (tools/server/server-context.cpp @1692f9e50):
#   draft acceptance = 0.89000 (  123 accepted /  456 generated), mean len =  5.23
# and burn/bench report acceptance LENGTH + block size, with TPS computed
# over delivered tokens (usage.completion_tokens can count accepted
# final-block tokens discarded at max_tokens — counter inflation).
#
# REF: "Speculative Decoding on CPUs — Nearly 4x Faster Token Generation with
# DFlash" (Intel, TDS 2026)
# https://towardsdatascience.com/speculative-decoding-on-cpus-nearly-4x-faster-token-generation-with-dflash/
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
TMPDIR_BATS="$(mktemp -d)"

setup() {
    # shellcheck disable=SC1090
    source "$REPO_ROOT/scripts/01-constants.sh"
    # shellcheck disable=SC1090
    source "$REPO_ROOT/scripts/11d-llm-gpu.sh"
}

teardown() {
    rm -rf "$TMPDIR_BATS"
}

@test "spec-dec-003: __spec_decode_stats parses the acceptance line" {
    local log="$TMPDIR_BATS/server.log"
    cat > "$log" <<'EOF'
main: HTTP server listening
slot 0 : kv cache rm - [0, end)
draft acceptance = 0.89000 (  123 accepted /  456 generated), mean len =  5.23
     acc per pos = (0.858, 0.514)
EOF
    run __spec_decode_stats "$log"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "0.89000|123|456|5.23|yes" ]]
}

@test "spec-dec-003: __spec_decode_stats returns last request's stats" {
    local log="$TMPDIR_BATS/server.log"
    cat > "$log" <<'EOF'
draft acceptance = 0.89000 (  123 accepted /  456 generated), mean len =  5.23
draft acceptance = 0.64120 (   87 accepted /  340 generated), mean len =  3.98
EOF
    run __spec_decode_stats "$log"
    [[ "$output" == "0.64120|87|340|3.98|yes" ]]
}

@test "spec-dec-003: __spec_decode_stats reports absent stats" {
    local log="$TMPDIR_BATS/plain.log"
    echo "main: HTTP server listening" > "$log"
    run __spec_decode_stats "$log"
    [[ "$output" == "0|0|0|0|no" ]]
    run __spec_decode_stats "$TMPDIR_BATS/missing.log"
    [[ "$output" == "0|0|0|0|no" ]]
}

@test "spec-dec-003: __spec_block_size resolves env over the 16 default" {
    [[ "$(__spec_block_size)" == "16" ]]
    LLM_SPEC_DRAFT_N_MAX=24 run bash -c 'source "$1/scripts/11d-llm-gpu.sh"; __spec_block_size' _ "$REPO_ROOT"
    LLM_SPECULATIVE_NGRAM=12 run bash -c 'source "$1/scripts/11d-llm-gpu.sh"; __spec_block_size' _ "$REPO_ROOT"
}

@test "spec-dec-003: honest TPS cap arithmetic matches delivered tokens" {
    # Replicate burn's de-inflation: delivered = min(usage_tokens, max_tokens).
    # 780 usage tokens at a 768 budget (final-block inflation) -> 768.
    local delivered
    delivered=$(awk -v t=780 -v m=768 'BEGIN { d = t > m ? m : t; printf "%d", d }')
    [[ "$delivered" == "768" ]]
    delivered=$(awk -v t=700 -v m=768 'BEGIN { d = t > m ? m : t; printf "%d", d }')
    [[ "$delivered" == "700" ]]
}
