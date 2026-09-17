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

    # Selection logic: highest ctx above TPS floor wins.
    [[ "$fn_src" == *"higher ctx"* || "$fn_src" == *"BEST_CTX"* ]]
    [[ "$fn_src" == *"BEST_CTX"* ]]
    [[ "$fn_src" == *"BEST_TPS"* ]]
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

# __llm_median_from_list and __llm_stddev_from_list were asserted here too, but
# nothing in the module tree ever called them and neither appears in 11b's
# @exports — this assertion was the only thing keeping them alive. Removed with
# the functions on 2026-09-16 (docs/inspection.md 4.3.4).
@test "integration: autotune profile save helper exists" {
    declare -f __llm_autotune_profile_save >/dev/null 2>&1
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

@test "integration: autotune-model.sh accepts a row number OR a model file name" {
    local fn_src
    fn_src=$(< "$REPO_ROOT/scripts/autotune-model.sh")

    # The model reference is a row number OR a GGUF file name; the FILE name is the row's
    # identity and is what is carried to the save, so a rescan cannot re-point a run
    # (2026-09-16).  This used to assert "MODEL_NUM must be a number".
    [[ "$fn_src" == *"Usage: autotune-model.sh MODEL_NUM|MODEL_FILE"* ]]
    [[ "$fn_src" == *"is not a model file in the registry"* ]]
    [[ "$fn_src" == *'__llm_registry_file_for_row'* ]]
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

@test "integration: autotune invalid model reference exits quickly" {
    run timeout 3 bash "$REPO_ROOT/scripts/autotune-model.sh" notanumber
    [[ "$status" -ne 124 ]]
    [[ "$output" == *"not a model file in the registry"* ]]
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

@test "integration: autotune-model.sh has an mmap fallback via --load-mode" {
    local fn_src
    fn_src=$(< "$REPO_ROOT/scripts/autotune-model.sh")

    [[ "$fn_src" == *"mmap"* ]]
    # 2026-09-14: llama.cpp build 10955 REMOVED --mmap/--no-mmap/--mlock.  A
    # launch carrying them dies with "error: invalid argument" and the server
    # never starts, so pin the replacement AND the absence of the old spelling
    # as an *assignment* (the prose above deliberately names the removed flags,
    # so only the assignment form is checked).  The regression is fatal.
    [[ "$fn_src" == *'mmap_flag=(--load-mode none)'* ]]
    if echo "$fn_src" | grep -qE 'mmap_flag=\(?"?(--no-mmap|--mmap|--mlock)"?\)?'; then
        echo "FAIL: mmap_flag assigns a flag that build 10955 rejects (fatal at launch)"
        return 1
    fi
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
    printf '%s\n' '#|name|file|size_gb|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|fit_target_mb|backend|mmap_mode|flash_attn|tps|autotuned|is_default|in_vram' > "$bench_root/.llm/models.conf"

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

# ─────────────────────────────────────────────────────────────────────────────
# A rescan must not discard curated/measured registry fields
# ─────────────────────────────────────────────────────────────────────────────
# `model scan` recomposes EVERY row from the GGUF, so any field it does not
# deliberately carry forward is silently lost.  Two were measured on 2026-09-17:
#   * the display name — the operator curates it because Unsloth/HF merges write
#     junk into `general.name` (rows displayed as "Unsloth_Gguf_Swgaw2A2",
#     "Hf Model", "Merged"); the scan re-derived that junk over the curation.
#   * the KV cache types (field 5's /k/v) — decided by the autotune's KV-quant
#     sweep and NOT derivable from the GGUF; the scan reset three rows from
#     q4_0/q4_0 to the q8_0/q8_0 env default, ~doubling KV bytes per token and
#     invalidating the ctx each row was certified at (row 26: 139,264).
# Both now carry forward from the previous row for the same FILE name.

@test "integration: a rescan keeps the curated name and the measured KV quant" {
    local sb="$TAC_TEST_TMPDIR/scan"
    mkdir -p "$sb/models"
    "$TAC_PYTHON" "$REPO_ROOT/tests/helpers/make-gguf-fixture.py" \
        junk-name "$sb/models/Curated-Test.Q4_K_M.gguf" >/dev/null
    # The scan skips files under 300 MB.  Pad sparsely: only the GGUF header is read, so
    # the tail costs no real disk, and the quant label comes from the FILE name.
    truncate -s 400M "$sb/models/Curated-Test.Q4_K_M.gguf"

    export LLAMA_MODEL_DIR="$sb/models"
    export LLM_REGISTRY="$sb/models.conf"
    {
        printf '%s\n' '#|name|file|size_gb|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|fit_target_mb|backend|mmap_mode|flash_attn|tps|autotuned|is_default|in_vram'
        printf '%s\n' '1|Curated Name|Curated-Test.Q4_K_M.gguf|0.4G|Q4_K_M/q4_0/q4_0|qwen2|999|32768|6|1024|256|1|256|native|auto|on|22.5|yes|no|no'
    } > "$LLM_REGISTRY"

    # `model scan` refuses unless the drive root is a MOUNTPOINT, and 01-constants decided
    # that at SOURCE time from the inherited LLAMA_DRIVE_ROOT — so it cannot be fixed by
    # exporting a different root here.  The e2e suite points LLAMA_DRIVE_ROOT at a temp dir,
    # which made this test pass standalone and fail when G3 ran the suite nested.  The gate
    # exists to stop model downloads filling the WSL rootfs; this sandbox contains none, so
    # satisfy the precondition directly instead of inheriting the ambient answer.
    __LLAMA_DRIVE_MOUNTED=1

    run __model_scan
    [[ "$status" -eq 0 ]]
    # The operator's name survives the fixture's junk general.name
    # ("Unsloth_Gguf_JunkFixture") instead of being overwritten by it ...
    grep -q '^[0-9]*|Curated Name|Curated-Test.Q4_K_M.gguf|' "$LLM_REGISTRY"
    # ... and the junk name does NOT appear in the row at all ...
    ! grep -q 'Unsloth_Gguf_JunkFixture' "$LLM_REGISTRY"
    # ... and the measured K/V cache types carry across (pre-fix: q8_0/q8_0).
    grep -q '/q4_0/q4_0' "$LLM_REGISTRY"
}

# end of file
