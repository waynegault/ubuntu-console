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
    export LLAMA_MODEL_DIR="$TAC_TEST_TMPDIR/models"
    mkdir -p "$LLAMA_MODEL_DIR"
}

teardown_file() {
    rm -rf "${TAC_TEST_TMPDIR:-/tmp/bats-noop}"
}

setup() {
    # Load all profile functions via env.sh (the non-interactive library loader)
    source "$REPO_ROOT/env.sh" 2>/dev/null || true

    # Override AFTER sourcing — 01-constants.sh sets LLM_REGISTRY to the real path.
    export LLM_REGISTRY="$TAC_TEST_TMPDIR/models.conf"
    export LLAMA_MODEL_DIR="$TAC_TEST_TMPDIR/models"
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

@test "integration: __model_list exposes quant rating" {
    local fn_src
    fn_src=$(declare -f __model_list 2>/dev/null)

    [[ "$fn_src" == *"RATING"* ]]
    [[ "$fn_src" == *"__llm_quant_rating"* ]]
    [[ "$fn_src" == *'"quant_rating"'* ]]
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

@test "integration: __model_info exposes quant rating" {
    local fn_src
    fn_src=$(declare -f __model_info 2>/dev/null)

    [[ "$fn_src" == *"quant_rating"* ]]
    [[ "$fn_src" == *"__llm_quant_rating"* ]]
}

@test "integration: model has autotune subcommand" {
    local fn_src
    fn_src=$(declare -f model 2>/dev/null)

    [[ "$fn_src" == *"autotune"* ]]
}

@test "integration: autotune-model.sh exposes objective priority" {
    local fn_src
    fn_src=$(< "$REPO_ROOT/scripts/autotune-model.sh")

    [[ "$fn_src" == *"no OOM"* || "$fn_src" == *"BEST_SCORE"* ]]
    [[ "$fn_src" == *"max ctx"* || "$fn_src" == *"BEST_CTX"* ]]
    [[ "$fn_src" == *"max TPS"* || "$fn_src" == *"BEST_TPS"* ]]
}

@test "integration: autotune-model.sh supports binary strategy" {
    local fn_src
    fn_src=$(< "$REPO_ROOT/scripts/autotune-model.sh")
    [[ "$fn_src" == *"START_CTX"* ]]
    [[ "$fn_src" == *"binary probe"* ]]
    [[ "$fn_src" == *"c / 2"* || "$fn_src" == *"c/2"* ]]
}

@test "integration: autotune-model.sh includes stability and pruning knobs" {
    local fn_src
    fn_src=$(< "$REPO_ROOT/scripts/autotune-model.sh")

    [[ "$fn_src" == *"stable"* ]]
    [[ "$fn_src" == *"TPS stable"* ]]
    [[ "$fn_src" == *"nsamples"* ]]
}

@test "integration: autotune-model.sh honors a minimum TPS floor" {
    local fn_src
    fn_src=$(< "$REPO_ROOT/scripts/autotune-model.sh")

    [[ "$fn_src" == *"LLM_MIN_TPS"* ]]
    [[ "$fn_src" == *"MIN_TPS"* ]]
    [[ "$fn_src" == *"below floor"* ]]
}

@test "integration: autotune-model.sh checks quant awareness" {
    local fn_src
    fn_src=$(< "$REPO_ROOT/scripts/autotune-model.sh")

    # Checks GGUF metadata for architecture and layer count
    [[ "$fn_src" == *"__gguf_metadata"* ]]
    [[ "$fn_src" == *"n_layers"* ]]
}

@test "integration: autotune-model.sh sizes model by registry file path" {
    local fn_src
    fn_src=$(< "$REPO_ROOT/scripts/autotune-model.sh")

    [[ "$fn_src" == *'LLAMA_MODEL_DIR/$file'* ]]
    [[ "$fn_src" != *'LLAMA_MODEL_DIR/$name'* ]]
}

@test "integration: autotune profile helpers exist" {
    declare -f __llm_autotune_profile_save >/dev/null 2>&1
    declare -f __llm_median_from_list >/dev/null 2>&1
    declare -f __llm_stddev_from_list >/dev/null 2>&1
}

test_integration_model_bench_autoruns_autotune_when_row_autotuned_no() {
    local fn_src
    fn_src=$(declare -f __model_bench 2>/dev/null)

    [[ "$fn_src" == *"__llm_autotune_done_for_model"* ]]
    [[ "$fn_src" == *"No prior autotune flag"* ]]
    [[ "$fn_src" == *"__model_autotune"* ]]
    [[ "$fn_src" == *"FAIL_AUTOTUNE"* ]]
}

@test "integration: __model_bench can skip discouraged quant autotune unless overridden" {
    local fn_src
    fn_src=$(declare -f __model_bench 2>/dev/null)

    [[ "$fn_src" == *"LLM_ALLOW_AUTOTUNE_DISCOURAGED"* ]]
    [[ "$fn_src" == *"Skipping autotune for discouraged quant"* ]]
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

@test "integration: __model_bench restores INT TERM EXIT traps" {
    local fn_src
    fn_src=$(declare -f __model_bench 2>/dev/null)

    [[ "$fn_src" == *"__bench_restore_traps"* ]]
    [[ "$fn_src" == *"__bench_prev_int_trap"* ]]
    [[ "$fn_src" == *"__bench_prev_term_trap"* ]]
    [[ "$fn_src" == *"__bench_prev_exit_trap"* ]]
}

@test "integration: autotune-model.sh validates required model number" {
    local fn_src
    fn_src=$(< "$REPO_ROOT/scripts/autotune-model.sh")

    [[ "$fn_src" == *"MODEL_NUM must be a number"* ]]
    [[ "$fn_src" == *"Usage: autotune-model.sh MODEL_NUM"* ]]
}

@test "integration: autotune-model.sh preserves lock file on early exit" {
    local fn_src
    fn_src=$(< "$REPO_ROOT/scripts/autotune-model.sh")

    # Script should not delete lock files it didn't create
    [[ "$fn_src" != *"rm -f /tmp/llm-bench.lock"* ]]
}

@test "integration: autotune missing model number exits quickly" {
    run timeout 3 bash "$REPO_ROOT/scripts/autotune-model.sh"
    [[ "$status" -ne 124 ]]
    [[ "$output" == *"Usage"* || "$output" == *"MODEL_NUM"* ]]
}

@test "integration: autotune invalid model number exits quickly" {
    run timeout 3 bash "$REPO_ROOT/scripts/autotune-model.sh" notanumber
    [[ "$status" -ne 124 ]]
    [[ "$output" == *"must be a number"* ]]
}

@test "integration: autotune nonexistent model exits quickly" {
    run timeout 5 bash "$REPO_ROOT/scripts/autotune-model.sh" 99999
    [[ "$status" -ne 124 ]]
    [[ "$output" == *"not found"* || "$output" == *"Error"* ]]
}

@test "integration: autotune-model.sh sources shared helpers" {
    local fn_src
    fn_src=$(< "$REPO_ROOT/scripts/autotune-model.sh")

    [[ "$fn_src" == *"source env.sh"* ]]
    [[ "$fn_src" == *"source scripts/11-llm-manager.sh"* ]]
}

@test "integration: autotune-model.sh has mmap fallback" {
    local fn_src
    fn_src=$(< "$REPO_ROOT/scripts/autotune-model.sh")

    [[ "$fn_src" == *"mmap"* ]]
    [[ "$fn_src" == *"no-mmap"* ]]
}

@test "integration: autotune-model.sh handles LLM_AUTOTUNE_SKIP_LOCK" {
    local fn_src
    fn_src=$(< "$REPO_ROOT/scripts/autotune-model.sh")

    # Script should respect the skip-lock convention (doesn't acquire bench lock)
    [[ "$fn_src" != *"flock /tmp/llm-bench.lock"* ]]
}

@test "integration: bench does not leak shell traps after return" {
    local pre_int pre_term pre_exit post_int post_term post_exit
    pre_int=$(trap -p INT || true)
    pre_term=$(trap -p TERM || true)
    pre_exit=$(trap -p EXIT || true)

    local bench_root="$TAC_TEST_TMPDIR/bench-trap-clean"
    mkdir -p "$bench_root/models" "$bench_root/.llm"
    printf '%s\n' '#|name|file|size_gb|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|fit_target_mb|backend|mmap_mode|tps|autotuned|is_default|in_vram' > "$bench_root/.llm/models.conf"

    LLM_REGISTRY="$bench_root/.llm/models.conf"
    LLAMA_MODEL_DIR="$bench_root/models"
    __model_bench >/dev/null 2>&1 || true

    post_int=$(trap -p INT || true)
    post_term=$(trap -p TERM || true)
    post_exit=$(trap -p EXIT || true)

    [[ "$post_int" == "$pre_int" ]]
    [[ "$post_term" == "$pre_term" ]]
    [[ "$post_exit" == "$pre_exit" ]]
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
