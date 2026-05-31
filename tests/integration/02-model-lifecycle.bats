#!/usr/bin/env bats
# ==============================================================================
# Integration Tests — Model Lifecycle
# ==============================================================================
# Tests model function structure (static analysis - fast and reliable)
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
    # Load all profile functions via env.sh (the non-interactive library loader)
    source "$REPO_ROOT/env.sh" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# Tests — Static analysis of function structure (fast, reliable)
# ─────────────────────────────────────────────────────────────────────────────

@test "integration: model function exists" {
    declare -f model >/dev/null 2>&1
}

@test "integration: model has list subcommand" {
    local fn_src
    fn_src=$(declare -f model 2>/dev/null)
    
    [[ "$fn_src" == *"list"* ]] || [[ "$fn_src" == *"List"* ]]
}

@test "integration: model has scan subcommand" {
    local fn_src
    fn_src=$(declare -f model 2>/dev/null)
    
    [[ "$fn_src" == *"scan"* ]] || [[ "$fn_src" == *"Scan"* ]] || [[ "$fn_src" == *"registry"* ]]
}

@test "integration: model has status subcommand" {
    local fn_src
    fn_src=$(declare -f model 2>/dev/null)
    
    [[ "$fn_src" == *"status"* ]] || [[ "$fn_src" == *"Status"* ]] || [[ "$fn_src" == *"OFFLINE"* ]]
}

@test "integration: model has doctor subcommand" {
    local fn_src
    fn_src=$(declare -f model 2>/dev/null)
    
    [[ "$fn_src" == *"doctor"* ]] || [[ "$fn_src" == *"Doctor"* ]] || [[ "$fn_src" == *"validate"* ]]
}

@test "integration: model-recommend function exists" {
    declare -f model-recommend >/dev/null 2>&1
}

@test "integration: model has info subcommand" {
    local fn_src
    fn_src=$(declare -f model 2>/dev/null)
    
    [[ "$fn_src" == *"info"* ]] || [[ "$fn_src" == *"Info"* ]]
}

@test "integration: model has autotune subcommand" {
    local fn_src
    fn_src=$(declare -f model 2>/dev/null)

    [[ "$fn_src" == *"autotune"* ]]
}

@test "integration: __model_autotune exposes objective priority" {
    local fn_src
    fn_src=$(declare -f __model_autotune 2>/dev/null)

    [[ "$fn_src" == *"no OOM"* ]]
    [[ "$fn_src" == *"max ctx"* ]]
    [[ "$fn_src" == *"max TPS"* ]]
}

@test "integration: __model_autotune supports binary context strategy" {
    local fn_src
    fn_src=$(declare -f __model_autotune 2>/dev/null)

    [[ "$fn_src" == *"LLM_AUTOTUNE_CTX_STRATEGY"* ]]
    [[ "$fn_src" == *"LLM_AUTOTUNE_MAX_CTX"* ]]
    [[ "$fn_src" == *"LLM_AUTOTUNE_CTX_STEP"* ]]
}

@test "integration: __model_autotune includes stability and pruning knobs" {
    local fn_src
    fn_src=$(declare -f __model_autotune 2>/dev/null)

    [[ "$fn_src" == *"LLM_AUTOTUNE_JITTER_PENALTY"* ]]
    [[ "$fn_src" == *"LLM_AUTOTUNE_EARLY_STOP_MARGIN"* ]]
    [[ "$fn_src" == *"LLM_AUTOTUNE_WARMUP"* ]]
    [[ "$fn_src" == *"LLM_AUTOTUNE_CONFIRM_FINAL"* ]]
}

@test "integration: __model_autotune sizes model by registry file path" {
    local fn_src
    fn_src=$(declare -f __model_autotune 2>/dev/null)

    [[ "$fn_src" == *'LLAMA_MODEL_DIR/$file'* ]]
    [[ "$fn_src" != *'LLAMA_MODEL_DIR/$name'* ]]
}

@test "integration: autotune profile helpers exist" {
    declare -f __llm_autotune_profile_save >/dev/null 2>&1
    declare -f __llm_median_from_list >/dev/null 2>&1
    declare -f __llm_stddev_from_list >/dev/null 2>&1
}

@test "integration: __model_bench auto-runs autotune when row autotuned=no" {
    local fn_src
    fn_src=$(declare -f __model_bench 2>/dev/null)

    [[ "$fn_src" == *"__llm_autotune_done_for_model"* ]]
    [[ "$fn_src" == *"No prior autotune flag"* ]]
    [[ "$fn_src" == *"__model_autotune"* ]]
    [[ "$fn_src" == *"FAIL_AUTOTUNE"* ]]
}

@test "integration: __model_bench disables autotune restore side-effect" {
    local fn_src
    fn_src=$(declare -f __model_bench 2>/dev/null)

    [[ "$fn_src" == *"LLM_AUTOTUNE_RESTORE_PREV=0"* ]]
}

@test "integration: __model_bench cleanup captures original exit status" {
    local fn_src
    fn_src=$(declare -f __model_bench 2>/dev/null)

    [[ "$fn_src" == *'local _exit_code=$?'* ]]
}

@test "integration: __model_bench cleanup does not delete autotune lock" {
    local fn_src
    fn_src=$(declare -f __model_bench 2>/dev/null)

    [[ "$fn_src" != *'rm -f "${LLM_AUTOTUNE_LOCK_FILE:-/tmp/llm-autotune.lock}"'* ]]
}

@test "integration: model has use subcommand" {
    local fn_src
    fn_src=$(declare -f model 2>/dev/null)
    
    [[ "$fn_src" == *"use"* ]] || [[ "$fn_src" == *"Use"* ]] || [[ "$fn_src" == *"start"* ]]
}

@test "integration: model has stop subcommand" {
    local fn_src
    fn_src=$(declare -f model 2>/dev/null)
    
    [[ "$fn_src" == *"stop"* ]] || [[ "$fn_src" == *"Stop"* ]] || [[ "$fn_src" == *"kill"* ]]
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

@test "integration: serve is defined" {
    declare -f serve >/dev/null 2>&1
}

@test "integration: llmconf function exists" {
    declare -f llmconf >/dev/null 2>&1
}

@test "integration: mlogs function exists" {
    declare -f mlogs >/dev/null 2>&1
}

@test "integration: burn function exists" {
    declare -f burn >/dev/null 2>&1
}

@test "integration: docs-sync function exists" {
    declare -f docs-sync >/dev/null 2>&1
}

# end of file
