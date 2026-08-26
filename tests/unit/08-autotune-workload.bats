#!/usr/bin/env bats
# ==============================================================================
# AUTOTUNE-001: workload-selectable scoring payload for the autotune TPS floor.
#
# autotune-model.sh certifies the ctx/batch/TPS winner against a
# workload-selectable scoring payload: --workload chat|legal|agentic|mix
# (env LLM_AUTOTUNE_WORKLOAD), reusing the SPEC-DEC-006 legal/agentic prompt
# sets from scripts/prompt-sets.sh (the single shared source with
# spec-decode-bench.sh), and records the workload used in the registry row
# (schema v6, column 33).
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
    # shellcheck disable=SC1090
    source "$REPO_ROOT/scripts/prompt-sets.sh"
    export LLM_REGISTRY="$TMPDIR_BATS/models.conf"
}

teardown() {
    rm -rf "$TMPDIR_BATS"
}

@test "autotune-001: prompt sets resolve per workload (shared with spec-decode-bench)" {
    __resolve_prompt_set legal
    [[ "${#PROMPTS[@]}" -eq 5 ]]
    [[ "${PROMPTS[0]}" == *"mediation"* ]]
    __resolve_prompt_set agentic
    [[ "${#PROMPTS[@]}" -eq 5 ]]
    [[ "${PROMPTS[0]}" == *"search_corpus"* ]]
    __resolve_prompt_set mix
    [[ "${#PROMPTS[@]}" -eq 11 ]]
    __resolve_prompt_set chat
    [[ "${#PROMPTS[@]}" -eq 1 ]]
    __resolve_prompt_set physics
    [[ "${#PROMPTS[@]}" -eq 1 ]]
    # Unknown sets are rejected without clobbering the globals.
    local before_names=("${PROMPT_NAMES[@]}")
    if __resolve_prompt_set bogus; then
        echo "bogus set must fail" >&2
        return 1
    fi
    [[ "${PROMPT_NAMES[*]}" == "${before_names[*]}" ]]
}

@test "autotune-001: profile-save records the workload (col 33, v6 schema)" {
    cat > "$LLM_REGISTRY" <<'EOF'
#|name|file|size_gb|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|fit_target_mb|backend|mmap_mode|flash_attn|tps|autotuned|is_default|in_vram|prefill_tps|p2_ctx|p2_batch|p2_ubatch|p2_tps|p2_prefill
1|Model One|model-one.gguf|1.0G|Q4_K_M/q8_0|qwen2|24|4096|6|1024|256|1|1024|llama_server|auto|on|0|no|no|no
EOF
    __llm_autotune_profile_save "1" "native" "4608" "1024" "256" "1" "256" "12.3" \
        "" "" "" "" "" "" "" "Q4_K_M/q8_0/q8_0" "24" \
        "" "" "" "" "" "" "legal"
    local row
    row=$(grep "^1|" "$LLM_REGISTRY")
    # v6 schema: 37 fields.
    [[ "$(echo "$row" | awk -F'|' '{print NF}')" == "37" ]]
    [[ "$(echo "$row" | cut -d'|' -f33)" == "legal" ]]
    local header
    header=$(head -1 "$LLM_REGISTRY")
    [[ "$(echo "$header" | awk -F'|' '{print NF}')" == "37" ]]
}

@test "autotune-001: autotune-model.sh accepts --workload and env default chat" {
    local src
    src=$(< "$REPO_ROOT/scripts/autotune-model.sh")
    [[ "$src" == *"--workload"* ]]
    [[ "$src" == *"LLM_AUTOTUNE_WORKLOAD"* ]]
    [[ "$src" == *"WORKLOAD=\"\${LLM_AUTOTUNE_WORKLOAD:-chat}\""* ]]
    # Scoring payload + fill payload are workload-driven (prompt sets shared).
    [[ "$src" == *"__workload_payload_json"* ]]
    [[ "$src" == *"PROMPTS_LEGAL[0]"* ]]
    [[ "$src" == *"PROMPTS_AGENTIC[0]"* ]]
    # Workload is recorded in the registry row on save.
    [[ "$src" == *'"$WORKLOAD"'* ]]
    [[ "$src" == *"workload=%s"* ]]
}

@test "autotune-003: profile-save records ttft_ms (col 34, v6 schema)" {
    cat > "$LLM_REGISTRY" <<'EOF'
#|name|file|size_gb|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|fit_target_mb|backend|mmap_mode|flash_attn|tps|autotuned|is_default|in_vram
1|Model One|model-one.gguf|1.0G|Q4_K_M/q8_0|qwen2|24|4096|6|1024|256|1|1024|llama_server|auto|on|0|no|no|no
EOF
    __llm_autotune_profile_save "1" "native" "4608" "1024" "256" "1" "256" "12.3" \
        "" "" "" "" "" "" "" "Q4_K_M/q8_0/q8_0" "24" \
        "" "" "" "" "" "" "legal" "145.5"
    local row
    row=$(grep "^1|" "$LLM_REGISTRY")
    [[ "$(echo "$row" | cut -d'|' -f34)" == "145.5" ]]
    [[ "$(echo "$row" | awk -F'|' '{print NF}')" == "37" ]]
}

@test "autotune-003: autotune-model.sh measures TTFT via a streaming probe" {
    local src
    src=$(< "$REPO_ROOT/scripts/autotune-model.sh")
    [[ "$src" == *"ttft_probe"* ]]
    [[ "$src" == *'"stream": True'* ]]
    [[ "$src" == *"time_starttransfer"* ]] || [[ "$src" == *"delta.get(\"content\")"* ]]
    [[ "$src" == *"TTFT_MS"* ]]
    [[ "$src" == *"ttft_ms=%s"* ]]
}

@test "autotune-004: profile-save records the parallel envelope (field 6)" {
    cat > "$LLM_REGISTRY" <<'EOF'
#|name|file|size_gb|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|fit_target_mb|backend|mmap_mode|flash_attn|tps|autotuned|is_default|in_vram
1|Model One|model-one.gguf|1.0G|Q4_K_M/q8_0|qwen2|24|4096|6|1024|256|1|1024|llama_server|auto|on|0|no|no|no
EOF
    __llm_autotune_profile_save "1" "native" "4608" "1024" "256" "2" "256" "12.3" \
        "" "" "" "" "" "" "" "Q4_K_M/q8_0/q8_0" "24" \
        "" "" "" "" "" "" "legal"
    local row
    row=$(grep "^1|" "$LLM_REGISTRY")
    # parallel column (field 12 incl. model number) = the measured envelope.
    [[ "$(echo "$row" | cut -d'|' -f12)" == "2" ]]
}

@test "autotune-004: autotune-model.sh sweeps the parallel envelope and 11e warns when over-subscribed" {
    local src
    src=$(< "$REPO_ROOT/scripts/autotune-model.sh")
    [[ "$src" == *"parallel envelope"* ]]
    [[ "$src" == *"BENCH_PARALLEL"* ]]
    [[ "$src" == *"WIN_PARALLEL"* ]]
    local e11
    e11=$(< "$REPO_ROOT/scripts/11e-llm-model.sh")
    [[ "$e11" == *"AUTOTUNE-004"* ]]
    [[ "$e11" == *"row_parallel_envelope"* ]]
    [[ "$e11" == *"exceeds the autotuned envelope"* ]]
}
