#!/usr/bin/env bats
# ==============================================================================
# Unit Tests — tools/check-agent-use.sh
# ==============================================================================
# Agent-usage regression checker. Runs hermetically by pointing TAC_CACHE_DIR at
# a fixture dir, so it needs no live /dev/shm caches and can gate CI.
# ==============================================================================

setup_file() {
    export REPO_ROOT
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export CHECK="$REPO_ROOT/tools/check-agent-use.sh"
}

setup() {
    export TAC_TEST_TMPDIR
    TAC_TEST_TMPDIR="$(mktemp -d)"
    export TAC_CACHE_DIR="$TAC_TEST_TMPDIR/cache"
    mkdir -p "$TAC_CACHE_DIR"
}

teardown() {
    rm -rf "${TAC_TEST_TMPDIR:-}"
}

# _fixture <sessions_total> <stats_total> — write the two cache inputs.
_fixture() {
    printf '{"sessions": [{"totalTokens": %s}, {"totalTokens": 0}]}\n' "$1" \
        > "$TAC_CACHE_DIR/oc_sessions.json"
    printf 'agent-a\tx\ty\t%s\n' "$2" > "$TAC_CACHE_DIR/oc_agent_stats.tsv"
}

@test "check-agent-use: matching totals report OK" {
    _fixture 1500 1500
    run "$CHECK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK: aggregated stats match sessions total"* ]]
}

@test "check-agent-use: mismatched totals fail with MISMATCH" {
    _fixture 1500 1200
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"MISMATCH"* ]]
}

@test "check-agent-use: missing sessions file exits 2" {
    printf 'agent-a\tx\ty\t100\n' > "$TAC_CACHE_DIR/oc_agent_stats.tsv"
    run "$CHECK"
    [ "$status" -eq 2 ]
    [[ "$output" == *"sessions file not found"* ]]
}

@test "check-agent-use: missing stats file exits 2" {
    printf '{"sessions": [{"totalTokens": 100}]}\n' > "$TAC_CACHE_DIR/oc_sessions.json"
    run "$CHECK"
    [ "$status" -eq 2 ]
    [[ "$output" == *"stats file not found"* ]]
}

# end of file
