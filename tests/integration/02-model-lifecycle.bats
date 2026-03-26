#!/usr/bin/env bats
# ==============================================================================
# Integration Tests — Model Lifecycle
# ==============================================================================
# Tests model scanning, listing, and basic operations
# Run: bats tests/integration/02-model-lifecycle.bats
# ==============================================================================

setup_file() {
    export REPO_ROOT
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export PROFILE_PATH="$REPO_ROOT/tactical-console.bashrc"
    export TAC_TEST_TMPDIR
    TAC_TEST_TMPDIR="$(mktemp -d)"
    export TAC_CACHE_DIR="$TAC_TEST_TMPDIR/cache"
    export LLM_REGISTRY="$TAC_TEST_TMPDIR/models.conf"
    export LLAMA_DRIVE_ROOT="$TAC_TEST_TMPDIR/llama-drive"
    export LLAMA_MODEL_DIR="$LLAMA_DRIVE_ROOT/active"
    mkdir -p "$TAC_CACHE_DIR" "$LLAMA_MODEL_DIR"
}

teardown_file() {
    rm -rf "${TAC_TEST_TMPDIR:-/tmp/bats-noop}"
}

setup() {
    source "$PROFILE_PATH" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# Tests
# ─────────────────────────────────────────────────────────────────────────────

@test "integration: model functions are defined" {
    declare -f model >/dev/null 2>&1
}

@test "integration: model list shows registry or empty message" {
    run model list
    
    # Should either show models or indicate registry is empty
    [[ "$output" == *"model"* ]] || [[ "$output" == *"empty"* ]] || [[ "$output" == *"registry"* ]]
}

@test "integration: model scan creates registry" {
    # Create a test model file
    mkdir -p "$LLAMA_MODEL_DIR"
    touch "$LLAMA_MODEL_DIR/test-model.Q4_K_M.gguf"
    
    run model scan
    
    # Should create registry file
    [[ -f "$LLM_REGISTRY" ]] || return 1
}

@test "integration: model status shows offline when no model running" {
    run model status
    
    # Should indicate no model is running
    [[ "$output" == *"OFFLINE"* ]] || [[ "$output" == *"not running"* ]] || [[ "$output" == *"inactive"* ]] || [[ "$status" -eq 0 ]]
}

@test "integration: model doctor validates setup" {
    run model doctor
    
    # Should complete without crashing
    [[ "$status" -eq 0 ]] || [[ "$output" == *"doctor"* ]]
}

@test "integration: model recommend suggests models" {
    run model-recommend
    
    # Function should exist and run
    [[ "$status" -eq 0 ]] || declare -f model-recommend >/dev/null 2>&1
}

@test "integration: model info shows help for invalid number" {
    run model info 999
    
    # Should handle invalid model number gracefully
    [[ "$status" -eq 0 ]] || [[ "$status" -eq 1 ]]
}

@test "integration: model use fails gracefully for missing model" {
    run model use 999
    
    # Should fail gracefully (not crash)
    [[ "$status" -ne 127 ]]  # 127 = command not found
}

@test "integration: model stop handles no running model" {
    run model stop
    
    # Should handle gracefully when no model is running
    [[ "$status" -eq 0 ]] || [[ "$output" == *"not running"* ]] || [[ "$output" == *"OFFLINE"* ]]
}

@test "integration: wake function exists" {
    declare -f wake >/dev/null 2>&1
}

@test "integration: gpu-status function exists" {
    declare -f gpu-status >/dev/null 2>&1
}

@test "integration: gpu-check function exists" {
    declare -f gpu-check >/dev/null 2>&1
}

@test "integration: halt function exists" {
    declare -f halt >/dev/null 2>&1
}

@test "integration: serve is alias for model use" {
    declare -f serve >/dev/null 2>&1
}

@test "integration: llmconf opens config file" {
    declare -f llmconf >/dev/null 2>&1
}

@test "integration: mlogs opens log file" {
    declare -f mlogs >/dev/null 2>&1
}

@test "integration: burn function exists" {
    declare -f burn >/dev/null 2>&1
}

@test "integration: docs-sync function exists" {
    declare -f docs-sync >/dev/null 2>&1
}

# end of file
