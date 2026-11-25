#!/usr/bin/env bats
# ==============================================================================
# MoE expert placement in the registry (col 49, schema v65).
#
# Before this column, a row whose experts sat in host RAM and a row that fit entirely in VRAM
# were stored identically: `gpu_layers` describes every layer, never the experts, and
# `in_vram` describes the current selector.  So an offloaded row could not be told from a
# GPU-only one — the case that matters when the ASUS (GPU-only policy) reads a row measured
# off-box, or when a tps taken with offload is compared with one taken without.
#
# These pin the round trip through the writer, derived from the ONE header definition rather
# than a column number, so a schema that grows again cannot red them for the wrong reason.
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
TMPDIR_BATS="$(mktemp -d)"

setup() {
    source "$REPO_ROOT/scripts/01-constants.sh"
    source "$REPO_ROOT/scripts/11d-llm-gpu.sh"
    source "$REPO_ROOT/scripts/11a-llm-registry.sh"
    source "$REPO_ROOT/scripts/11b-llm-autotune.sh"
    export LLM_REGISTRY="$TMPDIR_BATS/models.conf"
    export LLAMA_MODEL_DIR="$TMPDIR_BATS/active"
    mkdir -p "$LLAMA_MODEL_DIR"
    : > "$LLAMA_MODEL_DIR/moe-one.gguf"
    # A deliberately LEGACY 20-column row: the writer is expected to expand it to the current
    # schema on the first save, which is its documented behaviour for old registries.
    cat > "$LLM_REGISTRY" <<'ROWS'
#|name|file|size_gb|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|fit_target_mb|backend|mmap_mode|flash_attn|tps|autotuned|is_default|in_vram
1|MoE One|moe-one.gguf|60.0G|Q4_K_M/q8_0|gpt-oss|999|8192|6|1024|256|1|1024|llama_server|auto|on|0|no|no|no
ROWS
}

teardown() {
    rm -rf "$TMPDIR_BATS"
}

# The column index the ONE header definition gives this name.  Read from LLM_REGISTRY_HEADER,
# not from the fixture: the fixture starts as a legacy row and the writer expands it.
moe_placement_col() {
    printf '%s\n' "$LLM_REGISTRY_HEADER" \
        | awk -F'|' '{ for (i = 1; i <= NF; i++) if ($i == "moe_placement") { print i; exit } }'
}

# A save with the placement in slot 37.  Padded in a loop rather than by counting empty
# strings: a miscount silently shifts the value into another column, which is the class of
# error this whole column exists to stop.
save_with_placement() {
    local value="${1:-}"
    local -a args=("1" "native" "8192" "1024" "256" "1" "1024" "20.0")
    while (( ${#args[@]} < 36 )); do args+=(""); done
    args+=("$value")
    __llm_autotune_profile_save "${args[@]}"
}

@test "moe-placement: the header names it, at the position the v65 note claims" {
    local col
    col=$(moe_placement_col)
    [ -n "$col" ] || { echo "moe_placement is not in LLM_REGISTRY_HEADER"; return 1; }
    [ "$col" = "49" ] || { echo "header position is $col, not 49 — update the v65 note"; return 1; }
}

@test "moe-placement: a recorded value round-trips while the row is expanded to the schema" {
    local col
    col=$(moe_placement_col)
    save_with_placement "cpu-moe:16"
    local row
    row=$(grep "^1|" "$LLM_REGISTRY")
    # The legacy row must have been padded to the header's width, or the value would sit in a
    # column no reader looks at.
    [ "$(echo "$row" | awk -F'|' '{print NF}')" = "$(awk -F'|' 'NR == 1 {print NF}' "$LLM_REGISTRY")" ] \
        || { echo "row width $(echo "$row" | awk -F'|' '{print NF}') disagrees with the header"; return 1; }
    [ "$(echo "$row" | cut -d'|' -f"$col")" = "cpu-moe:16" ] \
        || { echo "recorded '$(echo "$row" | cut -d'|' -f"$col")' instead of cpu-moe:16"; return 1; }
}

@test "moe-placement: the emitted header is the ONE definition, not a copy" {
    save_with_placement "cpu-moe"
    [ "$(head -1 "$LLM_REGISTRY")" = "$LLM_REGISTRY_HEADER" ] \
        || { echo "the writer emitted a header that differs from LLM_REGISTRY_HEADER"; return 1; }
}

@test "moe-placement: a caller with no placement to report leaves a recorded one alone" {
    # An ordinary re-tune carries no placement.  If it cleared the column, the row would
    # silently read as GPU-only — the misleading direction.
    local col
    col=$(moe_placement_col)
    save_with_placement "cpu-moe"
    __llm_autotune_profile_save "1" "native" "8192" "1024" "256" "1" "1024" "21.0"
    [ "$(grep "^1|" "$LLM_REGISTRY" | cut -d'|' -f"$col")" = "cpu-moe" ] \
        || { echo "a placement-free save cleared the recorded placement"; return 1; }
}

@test "moe-placement: an unrecognised value is refused, not stored as a label" {
    local col
    col=$(moe_placement_col)
    save_with_placement "on-the-cpu-maybe"
    [ -z "$(grep "^1|" "$LLM_REGISTRY" | cut -d'|' -f"$col")" ] \
        || { echo "an unrecognised placement was stored, so a consumer could trust it"; return 1; }
}

@test "moe-placement: model info surfaces a stated placement and stays quiet otherwise" {
    # 05 and 11e are sourced HERE, not in setup: under bats' `set -e` a non-zero return in a
    # module's source body aborts the remainder, leaving __model_info undefined.
    source "$REPO_ROOT/scripts/05-ui-engine.sh"
    source "$REPO_ROOT/scripts/11c-llm-server.sh"
    source "$REPO_ROOT/scripts/11e-llm-model.sh"
    run __model_info 1
    [ "$status" -eq 0 ]
    [[ "$output" != *"moe_placement"* ]] \
        || { echo "a GPU-only row printed a placement it does not have"; return 1; }
    save_with_placement "moe-cache:4096,0.95"
    run __model_info 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"moe_placement"* && "$output" == *"moe-cache:4096,0.95"* ]] \
        || { echo "model info did not surface the recorded placement"; return 1; }
}
