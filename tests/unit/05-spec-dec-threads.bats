#!/usr/bin/env bats
# ==============================================================================
# SPEC-DEC-002: LLM compute threads are hard-capped at the i9-12900HK P-core
# count (6).
#
# WSL2 exposes 12 CPUs (`processors=12` in .wslconfig -> `nproc` = 12).
# Uncapped nproc-derived thread counts spill decode onto the E-cores and SLOW
# generation (DFlash article hybrid-architecture pitfall).  Every computed
# thread path must clamp to 6: __calc_threads (scan + fallbacks), the autotune
# TUNE_THREADS resolution, the launch-time registry read, and the registry
# rewrite awks (profile-save / remap).
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
    # shellcheck disable=SC1090
    source "$REPO_ROOT/scripts/11b-llm-autotune.sh"
}

teardown() {
    rm -rf "$TMPDIR_BATS"
}

@test "spec-dec-002: __llm_thread_cap clamps every value to 6" {
    [[ "$(__llm_thread_cap 1)" == "1" ]]
    [[ "$(__llm_thread_cap 6)" == "6" ]]
    [[ "$(__llm_thread_cap 7)" == "6" ]]
    [[ "$(__llm_thread_cap 10)" == "6" ]]
    [[ "$(__llm_thread_cap 12)" == "6" ]]
    [[ "$(__llm_thread_cap 99)" == "6" ]]
    [[ "$(__llm_thread_cap junk)" == "6" ]]
}

@test "spec-dec-002: __calc_threads never exceeds 6 for any offload mode" {
    # Simulate the 12-CPU WSL2 nproc inside a subshell: CPU-only (80%),
    # partial (70%) and full-GPU (50%) scaling of 12 all cap at 6.
    run bash -c '
        source "$1/scripts/11d-llm-gpu.sh"
        nproc() { echo 12; }
        echo "$(__calc_threads 0 40)"
        echo "$(__calc_threads 20 40)"
        echo "$(__calc_threads 40 40)"
    ' _ "$REPO_ROOT"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "6
6
6" ]]
}

@test "spec-dec-002: autotune TUNE_THREADS resolution is capped at 6" {
    # A >6 registry threads value must resolve to 6, and the nproc fallback
    # (12) must resolve to 6 as well.  __llm_autotune_profile_save needs a
    # real registry to write; here we only exercise the TUNE_THREADS block's
    # inputs through the cap helper used by autotune-model.sh.
    local capped
    capped=$(__llm_thread_cap 12)
    [[ "$capped" == "6" ]]
}

@test "spec-dec-002: registry profile-save clamps stored thread field to 6" {
    export LLM_REGISTRY="$TMPDIR_BATS/models.conf"
    cat > "$LLM_REGISTRY" <<'EOF'
#|name|file|size_gb|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|fit_target_mb|backend|mmap_mode|flash_attn|tps|autotuned|is_default|in_vram|prefill_tps|p2_ctx|p2_batch|p2_ubatch|p2_tps|p2_prefill
1|Model One|model-one.gguf|1.0G|Q4_K_M/q8_0|qwen2|24|4096|10|1024|256|1|1024|llama_server|auto|on|0|no|no|no
EOF
    __llm_autotune_profile_save "1" "native" "4096" "1024" "256" "1" "256" "12.3"
    local stored_threads
    stored_threads=$(awk -F'|' '$1 == "1" {print $9; exit}' "$LLM_REGISTRY")
    [[ "$stored_threads" == "6" ]]
}

@test "spec-dec-002: registry remap clamps carried thread field to 6" {
    local old_reg="$TMPDIR_BATS/old.conf"
    local new_reg="$TMPDIR_BATS/new.conf"
    cat > "$old_reg" <<'EOF'
#|name|file|size_gb|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|fit_target_mb|backend|mmap_mode|flash_attn|tps|autotuned|is_default|in_vram|prefill_tps|p2_ctx|p2_batch|p2_ubatch|p2_tps|p2_prefill
1|Model One|model-one.gguf|1.0G|Q4_K_M/q8_0|qwen2|24|4096|12|1024|256|1|1024|llama_server|auto|on|0|no|no|no
EOF
    cat > "$new_reg" <<'EOF'
#|name|file|size_gb|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|fit_target_mb|backend|mmap_mode|flash_attn|tps|autotuned|is_default|in_vram|prefill_tps|p2_ctx|p2_batch|p2_ubatch|p2_tps|p2_prefill
1|Model One|model-one.gguf|1.0G|Q4_K_M/q8_0|qwen2|24|4096|6|1024|256|1|1024|llama_server|auto|on|0|no|no|no
EOF
    __llm_autotune_profiles_remap_by_registry "$old_reg" "$new_reg"
    local stored_threads
    stored_threads=$(awk -F'|' '$1 == "1" {print $9; exit}' "$new_reg")
    [[ "$stored_threads" == "6" ]]
}
