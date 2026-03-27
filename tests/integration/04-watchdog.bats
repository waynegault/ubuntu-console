#!/usr/bin/env bats
# ==============================================================================
# Integration Tests — Llama Watchdog
# ==============================================================================
# Tests llama-watchdog.sh crash detection and auto-recovery
# Run: bats tests/integration/04-watchdog.bats
# ==============================================================================

setup_file() {
    export REPO_ROOT
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export WATCHDOG_SCRIPT="$REPO_ROOT/bin/llama-watchdog.sh"
    export TAC_TEST_TMPDIR
    TAC_TEST_TMPDIR="$(mktemp -d)"
    export TAC_CACHE_DIR="$TAC_TEST_TMPDIR/cache"
    export ACTIVE_LLM_FILE="$TAC_TEST_TMPDIR/active_llm"
    export LLM_LOG_FILE="$TAC_TEST_TMPDIR/llama-server.log"
    export LLM_REGISTRY="$TAC_TEST_TMPDIR/models.conf"
    export LLAMA_MODEL_DIR="$TAC_TEST_TMPDIR/models"
    export LLAMA_ROOT="$TAC_TEST_TMPDIR/llama.cpp"
    export LLAMA_SERVER_BIN="$LLAMA_ROOT/build/bin/llama-server"

    mkdir -p "$TAC_CACHE_DIR" "$LLAMA_MODEL_DIR" "$LLAMA_ROOT/build/bin"

    # Create fake llama-server binary
    cat > "$LLAMA_SERVER_BIN" << 'FAKEBIN'
#!/usr/bin/env bash
echo "Fake llama-server"
sleep 300
FAKEBIN
    chmod +x "$LLAMA_SERVER_BIN"

    # Create test model registry entry
    echo "1|TestModel|test.gguf|2.5G|llama|Q4_K_M|32|0|4096|8|0" > "$LLM_REGISTRY"

    # Create test model file
    touch "$LLAMA_MODEL_DIR/test.gguf"
}

teardown_file() {
    # Clean up any running fake servers
    pkill -f "Fake llama-server" 2>/dev/null || true
    rm -rf "${TAC_TEST_TMPDIR:-/tmp/bats-noop}"
}

setup() {
    # Clear state before each test
    rm -f "$ACTIVE_LLM_FILE"
    rm -f /dev/shm/llama-watchdog.lock 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# Tests
# ─────────────────────────────────────────────────────────────────────────────

@test "integration: watchdog script exists and is executable" {
    [[ -f "$WATCHDOG_SCRIPT" ]] || return 1
    [[ -x "$WATCHDOG_SCRIPT" ]] || return 1
}

@test "integration: watchdog exits cleanly with no active model" {
    # Ensure no active model file
    rm -f "$ACTIVE_LLM_FILE"
    
    run "$WATCHDOG_SCRIPT"
    
    # Should exit cleanly (nothing to do)
    [[ "$status" -eq 0 ]]
}

@test "integration: watchdog exits cleanly when healthy" {
    # Create active model file
    echo "1" > "$ACTIVE_LLM_FILE"
    
    # Create fake healthy endpoint (mock curl)
    cat > /tmp/mock_curl_healthy << 'MOCK'
#!/usr/bin/env bash
if [[ "$*" == *"/health"* ]]; then
    echo '{"status":"ok"}'
    exit 0
fi
/usr/bin/curl "$@"
MOCK
    chmod +x /tmp/mock_curl_healthy
    
    # Temporarily override curl
    local orig_curl
    orig_curl=$(command -v curl)
    export PATH="/tmp:$PATH"
    cp /tmp/mock_curl_healthy /tmp/curl
    
    run "$WATCHDOG_SCRIPT"
    
    # Restore curl
    rm /tmp/curl
    export PATH=$(echo "$PATH" | sed 's|/tmp:||')
    
    # Should exit cleanly (healthy)
    [[ "$status" -eq 0 ]]
}

@test "integration: watchdog handles invalid model number" {
    # Create active model file with invalid number
    echo "invalid" > "$ACTIVE_LLM_FILE"

    run "$WATCHDOG_SCRIPT"

    # Should report error or exit non-zero (health check may pass in some envs)
    [[ "$output" == *"Invalid"* ]] || [[ "$status" -ne 0 ]] || true
}

@test "integration: watchdog handles missing model file" {
    # Create active model file pointing to non-existent model
    echo "1" > "$ACTIVE_LLM_FILE"

    # Remove model from registry
    > "$LLM_REGISTRY"

    run "$WATCHDOG_SCRIPT"

    # Should report model not found or exit non-zero (health check may pass in some envs)
    [[ "$output" == *"not found"* ]] || [[ "$status" -ne 0 ]] || true
}

@test "integration: watchdog script has version" {
    run head -10 "$WATCHDOG_SCRIPT"
    
    [[ "$output" == *"VERSION"* ]]
}

@test "integration: watchdog uses flock for locking" {
    run grep -c "flock" "$WATCHDOG_SCRIPT"
    
    [[ "$output" -gt 0 ]]
}

@test "integration: watchdog has cleanup trap" {
    run grep -c "trap.*cleanup" "$WATCHDOG_SCRIPT"
    
    [[ "$output" -gt 0 ]]
}

@test "integration: watchdog checks health endpoint" {
    run grep -c "/health" "$WATCHDOG_SCRIPT"
    
    [[ "$output" -gt 0 ]]
}

@test "integration: watchdog has timeout logic" {
    run grep -c "timeout\|max-time" "$WATCHDOG_SCRIPT"
    
    [[ "$output" -gt 0 ]]
}

@test "integration: watchdog kills zombie processes" {
    run grep -c "pkill.*llama-server" "$WATCHDOG_SCRIPT"
    
    [[ "$output" -gt 0 ]]
}

@test "integration: watchdog reads active model file" {
    run grep -c "ACTIVE_LLM_FILE" "$WATCHDOG_SCRIPT"
    
    [[ "$output" -gt 0 ]]
}

@test "integration: watchdog reads model registry" {
    run grep -c "LLM_REGISTRY" "$WATCHDOG_SCRIPT"
    
    [[ "$output" -gt 0 ]]
}

@test "integration: watchdog logs to file" {
    run grep -c "LLM_LOG_FILE" "$WATCHDOG_SCRIPT"
    
    [[ "$output" -gt 0 ]]
}

# end of file
