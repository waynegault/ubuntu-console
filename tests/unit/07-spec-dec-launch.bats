#!/usr/bin/env bats
# ==============================================================================
# SPEC-DEC-004: speculative-decoding launch flags + registry schema v5.
#
# `model use` must accept draft/ngram settings and pass only VERIFIED
# llama.cpp flags (--spec-draft-model, --spec-type ngram-mod,
# --spec-ngram-mod-n-max/-n-min, --spec-draft-n-max, --spec-draft-device).
# The registry gains 6 spec columns (27-32); profile-save records the
# autotune block-size winner per model.  On the 4 GB card the draft default
# is CPU placement (--spec-draft-device none).
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
    export LLM_REGISTRY="$TMPDIR_BATS/models.conf"
}

teardown() {
    rm -rf "$TMPDIR_BATS"
}

@test "spec-dec-004: __spec_launch_flags emits only verified flags (ngram)" {
    run bash -c '
        source "$1/scripts/11d-llm-gpu.sh"
        LLM_SPEC_TYPE=ngram LLM_SPEC_DRAFT_N_MAX=8 __spec_launch_flags
    ' _ "$REPO_ROOT"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"--spec-type"* ]] && [[ "$output" == *"ngram-mod"* ]]
    [[ "$output" == *"--spec-ngram-mod-n-max"* ]] && [[ "$output" == *"8"* ]]
    [[ "$output" == *"--spec-ngram-mod-n-min"* ]]
    # No removed flags anywhere.
    [[ "$output" != *"--speculative-ngram"* ]]
    [[ "$output" != *"--draft-model"* ]]
}

@test "spec-dec-004: __spec_launch_flags CPU-places a draft model by default" {
    run bash -c '
        source "$1/scripts/11d-llm-gpu.sh"
        LLM_SPEC_DRAFT_MODEL=/models/draft.gguf __spec_launch_flags
    ' _ "$REPO_ROOT"
    [[ "$output" == *"--spec-draft-model"* ]]
    [[ "$output" == *"--spec-draft-device"* ]]
    [[ "$output" == *"none"* ]]
}

@test "spec-dec-004: __spec_launch_flags honours ngl and disabled knobs" {
    run bash -c '
        source "$1/scripts/11d-llm-gpu.sh"
        LLM_SPEC_DRAFT_MODEL=/models/draft.gguf LLM_SPEC_DRAFT_NGL=20 __spec_launch_flags
    ' _ "$REPO_ROOT"
    [[ "$output" == *"--spec-draft-ngl"* ]] && [[ "$output" == *"20"* ]]
    [[ "$output" != *"--spec-draft-device"* ]]
    run bash -c '
        source "$1/scripts/11d-llm-gpu.sh"
        LLM_SPEC_DRAFT_MODEL=/models/draft.gguf LLM_SPEC_DRAFT_ENABLED=0 __spec_launch_flags
    ' _ "$REPO_ROOT"
    [[ -z "$output" ]]
    run bash -c '
        source "$1/scripts/11d-llm-gpu.sh"
        __spec_launch_flags
    ' _ "$REPO_ROOT"
    [[ -z "$output" ]]
}

@test "spec-dec-004: profile-save writes the spec fields into a v5 registry" {
    cat > "$LLM_REGISTRY" <<'EOF'
#|name|file|size_gb|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|fit_target_mb|backend|mmap_mode|flash_attn|tps|autotuned|is_default|in_vram|prefill_tps|p2_ctx|p2_batch|p2_ubatch|p2_tps|p2_prefill
1|Model One|model-one.gguf|1.0G|Q4_K_M/q8_0|qwen2|24|4096|6|1024|256|1|1024|llama_server|auto|on|0|no|no|no
EOF
    __llm_autotune_profile_save "1" "native" "4096" "1024" "256" "1" "256" "12.3" \
        "" "" "" "" "" "" "" "Q4_K_M/q8_0/q8_0" "24" \
        "ngram" "" "16" "" "" "6.67"
    local row
    row=$(grep "^1|" "$LLM_REGISTRY")
    # v6 schema: 37 fields (v5's 32 + workload/ttft_ms/bench_*).
    [[ "$(echo "$row" | awk -F'|' '{print NF}')" == "37" ]]
    # spec_type(27), spec_draft_n_max(29), spec_accept_len(32).
    [[ "$(echo "$row" | cut -d'|' -f27)" == "ngram" ]]
    [[ "$(echo "$row" | cut -d'|' -f29)" == "16" ]]
    [[ "$(echo "$row" | cut -d'|' -f32)" == "6.67" ]]
    # Legacy 20-col row padded to 37.
    local header
    header=$(head -1 "$LLM_REGISTRY")
    [[ "$(echo "$header" | awk -F'|' '{print NF}')" == "37" ]]
}

@test "spec-dec-004: remap carries the spec fields across a renumber" {
    cat > "$TMPDIR_BATS/old.conf" <<'EOF'
#|name|file|size_gb|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|fit_target_mb|backend|mmap_mode|flash_attn|tps|autotuned|is_default|in_vram|prefill_tps|p2_ctx|p2_batch|p2_ubatch|p2_tps|p2_prefill|spec_type|spec_draft_model|spec_draft_n_max|spec_draft_ngl|spec_draft_device|spec_accept_len
1|Model One|model-one.gguf|1.0G|Q4_K_M/q8_0|qwen2|24|4096|6|1024|256|1|1024|llama_server|auto|on|0|yes|no|no|||||||ngram||16|||6.67
EOF
    cp "$TMPDIR_BATS/old.conf" "$TMPDIR_BATS/new.conf"
    __llm_autotune_profiles_remap_by_registry "$TMPDIR_BATS/old.conf" "$TMPDIR_BATS/new.conf"
    local row
    row=$(grep "^1|" "$TMPDIR_BATS/new.conf")
    [[ "$(echo "$row" | cut -d'|' -f27)" == "ngram" ]]
    [[ "$(echo "$row" | cut -d'|' -f29)" == "16" ]]
    [[ "$(echo "$row" | cut -d'|' -f32)" == "6.67" ]]
}

@test "spec-dec-004: __spec_block_size reads the registry winner" {
    cat > "$LLM_REGISTRY" <<'EOF'
#|name|file|size_gb|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|fit_target_mb|backend|mmap_mode|flash_attn|tps|autotuned|is_default|in_vram|prefill_tps|p2_ctx|p2_batch|p2_ubatch|p2_tps|p2_prefill|spec_type|spec_draft_model|spec_draft_n_max|spec_draft_ngl|spec_draft_device|spec_accept_len
1|Model One|model-one.gguf|1.0G|Q4_K_M/q8_0|qwen2|24|4096|6|1024|256|1|1024|llama_server|auto|on|0|yes|no|no|||||||ngram||16|||6.67
EOF
    echo "1" > "$TMPDIR_BATS/active_llm"
    run bash -c '
        source "$1/scripts/11d-llm-gpu.sh"
        export LLM_REGISTRY="$2/models.conf"
        export ACTIVE_LLM_FILE="$2/active_llm"
        __spec_block_size
    ' _ "$REPO_ROOT" "$TMPDIR_BATS"
    [[ "$output" == "16" ]]
}
