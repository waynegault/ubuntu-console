#!/usr/bin/env bats
# ==============================================================================
# E2E Bench + Autotune — Full User-Journey Test
# ==============================================================================
# Covers: model bench, model autotune, bench-triggered autotune,
#         lock/trap/cleanup, timeout handling, result persistence,
#         lock ownership safety, malformed args, post-run state restoration.
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
    export TAC_TEST_TMPDIR="$(mktemp -d)/tac_bench_e2e"
    mkdir -p "$TAC_TEST_TMPDIR/models" "$TAC_TEST_TMPDIR/.llm"
    echo "stub" > "$TAC_TEST_TMPDIR/models/tuned.gguf"
    echo "stub" > "$TAC_TEST_TMPDIR/models/untuned.gguf"

    cat > "$TAC_TEST_TMPDIR/.llm/models.conf" <<'REGISTRY'
#|name|file|size_gb|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|fit_target_mb|backend|mmap_mode|tps|autotuned|is_default|in_vram
1|Tuned Model|tuned.gguf|0.5G|Q4_K_M/q8_0|llama|24|8192|4|1024|256|1|256|native|auto|88.5|yes|yes|no
2|Untuned Model|untuned.gguf|0.5G|Q4_K_M/q8_0|llama|24|4096|4|1024|256|1|256|native|auto|0|no|no|no
3|Missing File|missing.gguf|0.5G|Q4_K_M/q8_0|llama|24|4096|4|1024|256|1|256|native|auto|0|no|no|no
REGISTRY

    export LLM_REGISTRY="$TAC_TEST_TMPDIR/.llm/models.conf"
    export LLAMA_MODEL_DIR="$TAC_TEST_TMPDIR/models"
    export ACTIVE_LLM_FILE="$TAC_TEST_TMPDIR/.llm/active_llm"
    export LLM_TPS_CACHE="$TAC_TEST_TMPDIR/.llm/last_tps"
    export LLM_AUTOTUNE_LOCK_FILE="$TAC_TEST_TMPDIR/.llm/autotune.lock"
    export LLM_BENCH_LOCK_FILE="$TAC_TEST_TMPDIR/.llm/bench.lock"
    export LLM_BENCH_PID_FILE="$TAC_TEST_TMPDIR/.llm/bench.pid"
    export LLAMA_DRIVE_ROOT="$TAC_TEST_TMPDIR"
    export LLM_AUTOTUNE_TRIALS=1
    export LLM_BENCH_MODEL_TIMEOUT=10
    export LLM_BENCH_LOCK_WAIT_SECONDS=1
    export LLM_AUTOTUNE_LOCK_WAIT_SECONDS=1
    export LLM_AUTOTUNE_WARMUP=0
    echo "1" > "$ACTIVE_LLM_FILE"

    source "$REPO_ROOT/env.sh" >/dev/null 2>&1
}

teardown() {
    rm -rf "$TAC_TEST_TMPDIR" 2>/dev/null || true
    rm -f /tmp/llm-bench.lock /tmp/llm-autotune.lock /tmp/llm-bench.pid 2>/dev/null || true
}

_s() { source "$REPO_ROOT/env.sh" >/dev/null 2>&1; }

# ===== A) PREFLIGHT ==========================================================

@test "[A1] Preflight: no bench/autotune traps in initial state" {
    local e; e=$(trap -p EXIT || true)
    [[ "$e" != *"__bench_cleanup"* ]]
    [[ "$e" != *"__autotune_unlock"* ]]
}

@test "[A2] Preflight: no stale lock files" {
    rm -f "$LLM_AUTOTUNE_LOCK_FILE" "$LLM_BENCH_LOCK_FILE" "$LLM_BENCH_PID_FILE"
    [[ ! -f "$LLM_AUTOTUNE_LOCK_FILE" ]]
    [[ ! -f "$LLM_BENCH_LOCK_FILE" ]]
    [[ ! -f "$LLM_BENCH_PID_FILE" ]]
}

# ===== B) FUNCTION DEFINITION TESTS (from source in setup) ===================

@test "[B1] Bench: __model_bench has singleton guard and cleanup" {
    local src; src=$(declare -f __model_bench 2>/dev/null)
    [[ "$src" == *"__tac_cleanup_stale_locks"* ]]
    [[ "$src" == *"bench_lock_fd"* ]]
    [[ "$src" == *"__bench_cleanup"* ]]
    [[ "$src" == *"__bench_restore_traps"* ]]
    [[ "$src" == *'rm -f "$bench_lock_file"'* ]]
    [[ "$src" != *'rm -f "${LLM_AUTOTUNE_LOCK_FILE'* ]]
}

@test "[B2] Autotune: __model_autotune has lock ownership guard" {
    local src; src=$(declare -f __model_autotune 2>/dev/null)
    [[ "$src" == *"__autotune_lock_owned"* ]]
    [[ "$src" == *'if [[ "$__autotune_lock_owned" == "1"'* ]]
}

@test "[B3] Autotune: __model_autotune validates required option values" {
    local src; src=$(declare -f __model_autotune 2>/dev/null)
    [[ "$src" == *"Missing value for --backend"* ]]
    [[ "$src" == *"Missing value for --ctx-size"* ]]
    [[ "$src" == *"Missing value for --trials"* ]]
}

@test "[B4] Bench: __model_bench restores INT, TERM, EXIT traps" {
    local src; src=$(declare -f __model_bench 2>/dev/null)
    [[ "$src" == *"__bench_prev_int_trap"* ]]
    [[ "$src" == *"__bench_prev_term_trap"* ]]
    [[ "$src" == *"__bench_prev_exit_trap"* ]]
    [[ "$src" == *"__bench_restore_traps"* ]]
}

@test "[B5] Autotune: __model_autotune restores previous EXIT trap" {
    local src; src=$(declare -f __model_autotune 2>/dev/null)
    [[ "$src" == *"__autotune_prev_exit_trap"* ]]
    [[ "$src" == *"trap '__autotune_unlock; __autotune_restore_traps' EXIT"* ]]
}

# ===== C) AUTOTUNE PERSISTENCE ===============================================

@test "[C4] Autotune: profile_save writes all fields + sets autotuned=yes" {
    echo "2" > "$ACTIVE_LLM_FILE"
    run __llm_autotune_profile_save 2 "native" 16384 2048 512 2 512 45.2
    [[ "$status" -eq 0 ]]

    run awk -F'|' '$1==2 {print $8; exit}' "$LLM_REGISTRY"
    [[ "$output" == "16384" ]]
    run awk -F'|' '$1==2 {print $10; exit}' "$LLM_REGISTRY"
    [[ "$output" == "2048" ]]
    run awk -F'|' '$1==2 {print $11; exit}' "$LLM_REGISTRY"
    [[ "$output" == "512" ]]
    run awk -F'|' '$1==2 {print $12; exit}' "$LLM_REGISTRY"
    [[ "$output" == "2" ]]
    run awk -F'|' '$1==2 {print $13; exit}' "$LLM_REGISTRY"
    [[ "$output" == "512" ]]
    run awk -F'|' '$1==2 {print $17; exit}' "$LLM_REGISTRY"
    [[ "$output" == "45.2" ]]
    run awk -F'|' '$1==2 {print $18; exit}' "$LLM_REGISTRY"
    [[ "$output" == "yes" ]]
}

# ===== D) FAILURE PATH =======================================================

@test "[D1] Failure: autotune non-existent model fails fast" {
    run timeout 3 bash -c "source '$REPO_ROOT/env.sh' >/dev/null 2>&1; \
        LLM_REGISTRY=$LLM_REGISTRY LLM_AUTOTUNE_LOCK_FILE=$LLM_AUTOTUNE_LOCK_FILE \
        __model_autotune 999 2>/dev/null || true"
    [[ "$status" -ne 124 ]]
    [[ "$output" == *"not in registry"* ]]
}

@test "[D2] Failure: autotune missing --backend value" {
    run timeout 3 bash -c "source '$REPO_ROOT/env.sh' >/dev/null 2>&1; \
        LLM_REGISTRY=$LLM_REGISTRY LLM_AUTOTUNE_LOCK_FILE=$LLM_AUTOTUNE_LOCK_FILE \
        __model_autotune 1 --backend 2>/dev/null || true"
    [[ "$status" -ne 124 ]]
    [[ "$output" == *"Missing value for --backend"* ]]
}

@test "[D3] Failure: autotune missing --ctx-size value" {
    run timeout 3 bash -c "source '$REPO_ROOT/env.sh' >/dev/null 2>&1; \
        LLM_REGISTRY=$LLM_REGISTRY LLM_AUTOTUNE_LOCK_FILE=$LLM_AUTOTUNE_LOCK_FILE \
        __model_autotune 1 --ctx-size 2>/dev/null || true"
    [[ "$status" -ne 124 ]]
    [[ "$output" == *"Missing value for --ctx-size"* ]]
}

@test "[D4] Failure: autotune missing --trials value" {
    run timeout 3 bash -c "source '$REPO_ROOT/env.sh' >/dev/null 2>&1; \
        LLM_REGISTRY=$LLM_REGISTRY LLM_AUTOTUNE_LOCK_FILE=$LLM_AUTOTUNE_LOCK_FILE \
        __model_autotune 1 --trials 2>/dev/null || true"
    [[ "$status" -ne 124 ]]
    [[ "$output" == *"Missing value for --trials"* ]]
}

@test "[D5] Failure: autotune invalid --ctx-size (non-numeric)" {
    run timeout 3 bash -c "source '$REPO_ROOT/env.sh' >/dev/null 2>&1; \
        LLM_REGISTRY=$LLM_REGISTRY LLM_AUTOTUNE_LOCK_FILE=$LLM_AUTOTUNE_LOCK_FILE \
        __model_autotune 1 --ctx-size abc 2>/dev/null || true"
    [[ "$status" -ne 124 ]]
    [[ "$output" == *"Invalid"* ]]
}

@test "[D6] Failure: autotune --trials 0 fails (must be >= 1)" {
    run timeout 3 bash -c "source '$REPO_ROOT/env.sh' >/dev/null 2>&1; \
        LLM_REGISTRY=$LLM_REGISTRY LLM_AUTOTUNE_LOCK_FILE=$LLM_AUTOTUNE_LOCK_FILE \
        __model_autotune 1 --trials 0 2>/dev/null || true"
    [[ "$status" -ne 124 ]]
    [[ "$output" == *"Invalid"* ]]
}

@test "[D7] Failure: autotune unknown backend" {
    run timeout 3 bash -c "source '$REPO_ROOT/env.sh' >/dev/null 2>&1; \
        LLM_REGISTRY=$LLM_REGISTRY LLM_AUTOTUNE_LOCK_FILE=$LLM_AUTOTUNE_LOCK_FILE \
        __model_autotune 1 --backend nonexistent 2>/dev/null || true"
    [[ "$status" -ne 124 ]]
    [[ "$output" == *"Unknown backend"* ]]
}

# ===== E) CONCURRENCY / LOCKING SAFETY =======================================

@test "[E1] Lock: bench singleton prevents concurrent run" {
    exec {fd}>"$LLM_BENCH_LOCK_FILE"
    flock -x "$fd"
    echo "$$" > "$LLM_BENCH_LOCK_FILE"
    run __model_bench
    [[ "$output" == *"already active"* ]]
    [[ "$status" -ne 0 ]]
    flock -u "$fd"; exec {fd}>&-; rm -f "$LLM_BENCH_LOCK_FILE"
}

@test "[E2] Lock: autotune singleton prevents concurrent run" {
    exec {fd}>"$LLM_AUTOTUNE_LOCK_FILE"
    flock -x "$fd"
    echo "$$" > "$LLM_AUTOTUNE_LOCK_FILE"
    run timeout 3 bash -c "source '$REPO_ROOT/env.sh' >/dev/null 2>&1; \
        LLM_REGISTRY=$LLM_REGISTRY LLM_AUTOTUNE_LOCK_FILE=$LLM_AUTOTUNE_LOCK_FILE \
        __model_autotune 1 2>/dev/null || true"
    [[ "$output" == *"Another autotune is running"* ]]
    [[ "$status" -ne 124 ]]
    flock -u "$fd"; exec {fd}>&-; rm -f "$LLM_AUTOTUNE_LOCK_FILE"
}

@test "[E3] Lock: autotune failure (invalid args) preserves pre-existing lock" {
    echo "424242" > "$LLM_AUTOTUNE_LOCK_FILE"
    run timeout 3 bash -c "source '$REPO_ROOT/env.sh' >/dev/null 2>&1; \
        LLM_REGISTRY=$LLM_REGISTRY LLM_AUTOTUNE_LOCK_FILE=$LLM_AUTOTUNE_LOCK_FILE \
        __model_autotune 1 --trials abc 2>/dev/null || true"
    [[ -f "$LLM_AUTOTUNE_LOCK_FILE" ]]
    rm -f "$LLM_AUTOTUNE_LOCK_FILE"
}

@test "[E4] Lock: skip-lock mode preserves existing lock file" {
    echo "424242" > "$LLM_AUTOTUNE_LOCK_FILE"
    run timeout 3 bash -c "source '$REPO_ROOT/env.sh' >/dev/null 2>&1; \
        LLM_REGISTRY=$LLM_REGISTRY LLM_AUTOTUNE_LOCK_FILE=$LLM_AUTOTUNE_LOCK_FILE \
        LLM_AUTOTUNE_SKIP_LOCK=1 __model_autotune 999 2>/dev/null || true"
    [[ -f "$LLM_AUTOTUNE_LOCK_FILE" ]]
    rm -f "$LLM_AUTOTUNE_LOCK_FILE"
}

@test "[E5] Lock: skip-lock does not clobber PID in lock file" {
    local other_pid=424242
    echo "$other_pid" > "$LLM_AUTOTUNE_LOCK_FILE"
    run timeout 3 bash -c "source '$REPO_ROOT/env.sh' >/dev/null 2>&1; \
        LLM_REGISTRY=$LLM_REGISTRY LLM_AUTOTUNE_LOCK_FILE=$LLM_AUTOTUNE_LOCK_FILE \
        LLM_AUTOTUNE_SKIP_LOCK=1 __model_autotune 999 2>/dev/null || true"
    [[ -f "$LLM_AUTOTUNE_LOCK_FILE" ]]
    local stored; stored=$(cat "$LLM_AUTOTUNE_LOCK_FILE")
    [[ "$stored" == "$other_pid" ]]
    rm -f "$LLM_AUTOTUNE_LOCK_FILE"
}

@test "[E6] Lock: __tac_cleanup_stale_locks removes orphaned files" {
    local dead_pid=99999
    echo "$dead_pid" > "$LLM_BENCH_LOCK_FILE"
    echo "$dead_pid" > "$LLM_BENCH_PID_FILE"
    echo "$dead_pid" > "$LLM_AUTOTUNE_LOCK_FILE"
    __tac_cleanup_stale_locks
    [[ ! -f "$LLM_BENCH_LOCK_FILE" ]]
    [[ ! -f "$LLM_BENCH_PID_FILE" ]]
    [[ ! -f "$LLM_AUTOTUNE_LOCK_FILE" ]]
}

@test "[E7] Lock: __tac_cleanup_stale_locks preserves lock held by our PID" {
    # Must use exec flock to hold an fd, not just echo PID — lsof check
    # requires an actual open file descriptor.
    exec {fd}>"$LLM_BENCH_LOCK_FILE"
    flock -x "$fd"
    __tac_cleanup_stale_locks
    [[ -f "$LLM_BENCH_LOCK_FILE" ]]
    flock -u "$fd"
    exec {fd}>&-
    rm -f "$LLM_BENCH_LOCK_FILE"
}

# ===== F) STATE RESTORATION ==================================================

@test "[F1] Restoration: bench does not leak traps into parent shell" {
    local pre_i pre_t
    pre_i=$(trap -p INT || true)
    pre_t=$(trap -p TERM || true)

    # Copy vars for subshell
    local vars="LLM_REGISTRY=$LLM_REGISTRY LLM_BENCH_LOCK_FILE=$LLM_BENCH_LOCK_FILE \
LLM_BENCH_PID_FILE=$LLM_BENCH_PID_FILE LLAMA_MODEL_DIR=$LLAMA_MODEL_DIR \
ACTIVE_LLM_FILE=$ACTIVE_LLM_FILE LLM_TPS_CACHE=$LLM_TPS_CACHE \
LLAMA_DRIVE_ROOT=$LLAMA_DRIVE_ROOT LLM_BENCH_MODEL_TIMEOUT=10 \
LLM_BENCH_LOCK_WAIT_SECONDS=1"
    # Use empty registry to prevent real model loading
    printf '%s\n' '#|name|file|size_gb|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|fit_target_mb|backend|mmap_mode|tps|autotuned|is_default|in_vram' > /tmp/.bench_trap_registry
    local e_reg=/tmp/.bench_trap_registry

    run bash -c "source '$REPO_ROOT/env.sh' >/dev/null 2>&1; \
        $vars LLM_REGISTRY=$e_reg \
        pi=\$(trap -p INT || true); pt=\$(trap -p TERM || true); \
        __model_bench >/dev/null 2>&1 || true; \
        po=\$(trap -p INT || true); pt2=\$(trap -p TERM || true); \
        [[ \"\$po\" == \"\$pi\" ]] || { echo 'INT LEAK'; exit 1; }; \
        [[ \"\$pt2\" == \"\$pt\" ]] || { echo 'TERM LEAK'; exit 1; }; \
        echo 'TRAPS_OK'"
    [[ "$output" == "TRAPS_OK" ]]
    rm -f /tmp/.bench_trap_registry
}

# ===== G) REGRESSION: EXISTING SUITE ALIGNMENT ===============================

@test "[G1] Regression: existing autotune unit tests pass" {
    run bats --tap "$REPO_ROOT/tests/tactical-console.bats" --filter "autotune" 2>&1
    [[ "$status" -eq 0 ]] && [[ "$output" != *"not ok"* ]]
}

@test "[G2] Regression: existing bench unit tests pass" {
    run bats --tap "$REPO_ROOT/tests/tactical-console.bats" --filter "bench\|Bench" 2>&1
    [[ "$status" -eq 0 ]] && [[ "$output" != *"not ok"* ]]
}

@test "[G3] Regression: existing model-lifecycle integration tests pass" {
    run bash -c "cd $REPO_ROOT && bats --tap $REPO_ROOT/tests/integration/02-model-lifecycle.bats 2>&1 | grep -c 'not ok'"
    [[ "$output" == "0" ]]
}

@test "[G4] Regression: __tac_cleanup_stale_locks function exists" {
    declare -f __tac_cleanup_stale_locks >/dev/null
}
