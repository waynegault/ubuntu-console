#!/usr/bin/env bats
# ==============================================================================
# Unit Tests — registry row identity is the model FILE NAME, not the row number
# ==============================================================================
# Row numbers are assigned by `model scan` and shift whenever a model is added or
# removed.  On 2026-09-16 registering one new model moved everything after it down a
# row (Spark-X2.5-4B took row 26, so the model that had been 26 became 27), which
# silently invalidated a list of queued row numbers and sent work at the wrong entries.
#
# Wayne's rule: "make the model file name the definitive identifier of a row, not a row
# number."  These tests pin the two things that has to mean:
#   1. the registry resolves in both directions (row -> file, file -> row);
#   2. a profile save keyed by FILE NAME lands on that file's row even when the
#      numbering changes underneath it — which is the failure the rule exists for.
# A row number may still be passed (existing callers and the interactive `model N` CLI
# keep working); it is resolved to a file name at that moment and is never the identity
# that is stored.
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
TMPDIR_BATS="$(mktemp -d)"

setup() {
    source "$REPO_ROOT/scripts/01-constants.sh"
    source "$REPO_ROOT/scripts/11b-llm-autotune.sh"
    export LLM_REGISTRY="$TMPDIR_BATS/models.conf"
    cat > "$LLM_REGISTRY" <<'EOF'
#|name|file|size_gb|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|fit_target_mb|backend|mmap_mode|flash_attn|tps|autotuned|is_default|in_vram|prefill_tps|p2_ctx|p2_batch|p2_ubatch|p2_tps|p2_prefill|spec_type|spec_draft_model|spec_n_max|spec_draft_ngl|spec_draft_device|spec_accept_len|workload|ttft_ms|bench_ctx|bench_max_chunks|bench_avg_prompt_tokens
1|Alpha|alpha.gguf|1.0G|Q4_K_M/q8_0|qwen2|24|4096|6|1024|256|1|256|llama_server|auto|on|11.0|yes|no|no|20.0|2048|512|128|22.0|900.0|ngram||8|||0|chat|1000|||
2|Beta|beta.gguf|1.5G|Q4_K_M/q8_0|llama|24|8192|6|1024|256|1|256|llama_server|auto|on|12.0|yes|no|no|21.0|4096|512|128|23.0|950.0|ngram||8|||0|chat|1100|||
3|Gamma|gamma.gguf|2.0G|Q4_K_M/q8_0|phi3|24|16384|6|1024|256|1|256|llama_server|auto|on|13.0|yes|no|no|22.0|8192|512|128|24.0|999.0|ngram||8|||0|chat|1200|||
EOF
}

teardown() {
    rm -rf "$TMPDIR_BATS"
}

# Would a `model scan` do this?: renumber the rows, leaving the files in place.
__renumber() {
    awk -F'|' -v OFS='|' '
        $1 ~ /^[0-9]+$/ { $1 = NR - 1 }
        { print }
    ' "$LLM_REGISTRY" > "$LLM_REGISTRY.renum" && mv "$LLM_REGISTRY.renum" "$LLM_REGISTRY"
}

# Insert a NEW model at the top, as a scan does when a file sorts first.
__prepend_model() {
    awk -F'|' -v OFS='|' '
        NR == 1 { print; next }
        NR == 2 { print "1|Newcomer|aaa-new.gguf|0.5G|Q4_K_M/q8_0|qwen2|24|4096|6|1024|256|1|256|llama_server|auto|on|0|no|no|no|||||||||||||||"; }
        $1 ~ /^[0-9]+$/ { $1 = $1 + 1 }
        { print }
    ' "$LLM_REGISTRY" > "$LLM_REGISTRY.new" && mv "$LLM_REGISTRY.new" "$LLM_REGISTRY"
}

@test "registry-identity: row number resolves to its file name and back" {
    [[ "$(__llm_registry_file_for_row 2)" == "beta.gguf" ]]
    [[ "$(__llm_registry_row_for_file "beta.gguf")" == "2" ]]
    [[ "$(__llm_registry_file_for_row 3)" == "gamma.gguf" ]]
    [[ "$(__llm_registry_row_for_file "gamma.gguf")" == "3" ]]
}

@test "registry-identity: unknown inputs resolve to empty, not to a neighbour" {
    [[ -z "$(__llm_registry_file_for_row 99)" ]]
    [[ -z "$(__llm_registry_row_for_file "nope.gguf")" ]]
    [[ -z "$(__llm_registry_file_for_row "")" ]]
    [[ -z "$(__llm_registry_file_for_row "beta.gguf")" ]]
    [[ -z "$(__llm_registry_row_for_file "")" ]]
}

@test "registry-identity: a numeric save writes the row whose NUMBER was given" {
    __llm_autotune_profile_save "2" "native" "16384" "1024" "256" "1" "256" "30.0"
    run awk -F'|' '$3 == "beta.gguf" {print $8, $17}' "$LLM_REGISTRY"
    [[ "$output" == "16384 30" ]]
    run awk -F'|' '$3 == "alpha.gguf" {print $8, $17}' "$LLM_REGISTRY"
    [[ "$output" == "4096 11.0" ]]
}

@test "registry-identity: a filename save writes THAT file row" {
    __llm_autotune_profile_save "gamma.gguf" "native" "32768" "2048" "512" "1" "256" "40.0"
    run awk -F'|' '$3 == "gamma.gguf" {print $8, $17}' "$LLM_REGISTRY"
    [[ "$output" == "32768 40" ]]
}

@test "registry-identity: a save survives a RENUMBER between capture and write" {
    # The failure the rule exists for: a scan runs while work is queued or in flight.
    local target="gamma.gguf"
    __prepend_model
    __renumber
    # gamma.gguf is no longer row 3 — assert the premise so this test cannot silently
    # stop testing anything if the fixture changes.
    [[ "$(__llm_registry_row_for_file "$target")" != "3" ]]

    __llm_autotune_profile_save "$target" "native" "49152" "2048" "512" "1" "256" "33.0"
    run awk -F'|' -v f="$target" '$3 == f {print $8, $17}' "$LLM_REGISTRY"
    [[ "$output" == "49152 33" ]]
    # ...and nobody else was touched.
    run awk -F'|' '$3 == "alpha.gguf" {print $8, $17}' "$LLM_REGISTRY"
    [[ "$output" == "4096 11.0" ]]
    run awk -F'|' '$3 == "beta.gguf" {print $8, $17}' "$LLM_REGISTRY"
    [[ "$output" == "8192 12.0" ]]
}

@test "registry-identity: a save for an absent file changes nothing" {
    local before
    before="$(cat "$LLM_REGISTRY")"
    run __llm_autotune_profile_save "ghost.gguf" "native" "4096" "1024" "256" "1" "256" "1.0"
    [[ "$status" -ne 0 ]]
    [[ "$(cat "$LLM_REGISTRY")" == "$before" ]]
}

@test "registry-identity: a save for an absent row number changes nothing" {
    local before
    before="$(cat "$LLM_REGISTRY")"
    run __llm_autotune_profile_save "77" "native" "4096" "1024" "256" "1" "256" "1.0"
    [[ "$status" -ne 0 ]]
    [[ "$(cat "$LLM_REGISTRY")" == "$before" ]]
}
