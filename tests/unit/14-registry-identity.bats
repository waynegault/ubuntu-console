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
    # The two-direction resolvers live in 11a beside the canonical entry lookups; the
    # autotune save that consumes them lives in 11b.
    source "$REPO_ROOT/scripts/11a-llm-registry.sh"
    source "$REPO_ROOT/scripts/11b-llm-autotune.sh"
    # Provenance registration (UBC-GRPO-004): the command lives in 11e and the prompt-set
    # revision in prompt-sets.sh, a standalone library its own consumers source directly.
    source "$REPO_ROOT/scripts/03-design-tokens.sh"
    source "$REPO_ROOT/scripts/05-ui-engine.sh"
    source "$REPO_ROOT/scripts/_startup-env.sh"
    source "$REPO_ROOT/scripts/prompt-sets.sh"
    source "$REPO_ROOT/scripts/11e-llm-model.sh"
    export LLM_REGISTRY="$TMPDIR_BATS/models.conf"
    export LLAMA_MODEL_DIR="$TMPDIR_BATS/active"
    mkdir -p "$LLAMA_MODEL_DIR"
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

# --- trained-artifact provenance (card UBC-GRPO-004) -------------------------
# A trained model lands as an ORDINARY row — the launchers, the autotuner and the units
# keep reading the same 37 fields — but a row cannot say WHY the artifact exists: which
# benchmark and held-out set scored it, and which revision of the served prompt contract
# it was trained under (the card's §4 rule: a reward win measured under a template that
# then moves is not a win). Those live in a sidecar keyed by the model FILE name, so a
# rescan cannot move them onto another model.

@test "trained provenance: the prompt-set revision is a content address" {
    local before
    before="$(__prompt_set_revision legal)"
    [[ "$before" == legal@* ]]
    # Same content, same revision.
    [[ "$(__prompt_set_revision legal)" == "$before" ]]
    # A different set is a different revision...
    [[ "$(__prompt_set_revision agentic)" != "$before" ]]
    # ...and moving a prompt body moves the revision, which is the whole point of it.
    PROMPTS_LEGAL+=("A newly added clause changes the contract")
    [[ "$(__prompt_set_revision legal)" != "$before" ]]
    # An unknown set is refused, not hashed into something plausible.
    run __prompt_set_revision nope
    [[ "$status" -ne 0 ]]
    [[ -z "$output" ]]
}

@test "trained provenance: the sidecar is keyed by model FILE, not by row number" {
    run __llm_provenance_write "beta.gguf" "bench-2026-09-27" "heldout-b" "legal@abc123def456" "deadbeef" "pilot"
    [[ "$status" -eq 0 ]]
    local path="$TMPDIR_BATS/provenance/beta.gguf.json"
    [[ -f "$path" ]]
    run grep -F '"benchmark": "bench-2026-09-27"' "$path"
    [[ "$status" -eq 0 ]]
    run grep -F '"held_out": "heldout-b"' "$path"
    [[ "$status" -eq 0 ]]
    run grep -F '"prompt_set": "legal@abc123def456"' "$path"
    [[ "$status" -eq 0 ]]

    # The identity rule again: renumber the registry and the record still resolves by name.
    __prepend_model
    __renumber
    [[ "$(__llm_registry_row_for_file beta.gguf)" != "2" ]]
    run __llm_provenance_read "beta.gguf"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *'"benchmark": "bench-2026-09-27"'* ]]
    # An unknown model has no record — refused, not empty-and-happy.
    run __llm_provenance_read "ghost.gguf"
    [[ "$status" -ne 0 ]]
}

# ── a GGUF stand-in for the registration cases (the magic is what is checked) ──
__fake_gguf() {
    printf 'GGUF' > "$1"
    head -c 512 /dev/zero | tr '\0' 'x' >> "$1"
}

@test "register-trained: refuses without the --benchmark/--held-out that make a row answerable" {
    __fake_gguf "$LLAMA_MODEL_DIR/alpha.gguf"
    run __model_register_trained alpha.gguf
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"--benchmark"* ]]
    [[ ! -f "$TMPDIR_BATS/provenance/alpha.gguf.json" ]]
    # Half the provenance is not enough either.
    run __model_register_trained alpha.gguf --benchmark bench-x
    [[ "$status" -ne 0 ]]
    [[ ! -f "$TMPDIR_BATS/provenance/alpha.gguf.json" ]]
}

@test "register-trained: refuses a non-GGUF file, and a GGUF with no registry row" {
    printf 'not a gguf at all' > "$LLAMA_MODEL_DIR/alpha.gguf"
    run __model_register_trained alpha.gguf --benchmark b --held-out h
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"not a GGUF"* ]]

    __fake_gguf "$LLAMA_MODEL_DIR/untracked.gguf"
    run __model_register_trained untracked.gguf --benchmark b --held-out h
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"no registry row"* ]]
}

@test "register-trained: records the artifact's hash and the contract revision it was trained under" {
    __fake_gguf "$LLAMA_MODEL_DIR/alpha.gguf"
    run __model_register_trained alpha.gguf --benchmark bench-2026-09-27 --held-out heldout-a --prompt-set legal
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"registered row 1"* ]]

    local path="$TMPDIR_BATS/provenance/alpha.gguf.json" rev
    [[ -f "$path" ]]
    rev="$(__prompt_set_revision legal)"
    run grep -F "\"prompt_set\": \"$rev\"" "$path"
    [[ "$status" -eq 0 ]]
    # The bytes are tied to the row: the recorded hash is the file's own.
    run grep -F "\"sha256\": \"$(sha256sum "$LLAMA_MODEL_DIR/alpha.gguf" | awk '{print $1}')\"" "$path"
    [[ "$status" -eq 0 ]]
}

@test "register-trained: loads prompt-sets on demand, because it is not a console module" {
    # prompt-sets.sh is a standalone library (spec-decode-bench.sh, autotune-model.sh and
    # spec_dec_crossover.sh source it directly) and is NOT in the interactive module list.
    # With it not loaded — the state a plain console shell is in — the command must still
    # register, sourcing it through __tac_source_submodules. Both halves of "not loaded"
    # have to be cleared: the function AND the library's own include guard, without which
    # re-sourcing is a no-op that leaves the function undefined.
    unset -f __prompt_set_revision
    unset __TAC_MOD_PROMPT_SETS_LOADED
    __fake_gguf "$LLAMA_MODEL_DIR/alpha.gguf"
    # `run` executes this in a subshell, so the loaded function is visible to the command
    # and not to this test — which is why the status and the recorded revision ARE the
    # proof that the load happened: nothing else in this shell can compute it.
    run __model_register_trained alpha.gguf --benchmark b --held-out h --prompt-set legal
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"prompt set : legal@"* ]]
    run grep -F '"prompt_set": "legal@' "$TMPDIR_BATS/provenance/alpha.gguf.json"
    [[ "$status" -eq 0 ]]
}

@test "register-trained: a library it cannot load is refused, not silently skipped" {
    # The same on-demand load with the library unreachable: the command must refuse and
    # write nothing. A silent skip here would record a row whose prompt contract is
    # unknown — exactly the unanswerable artifact this path exists to prevent.
    unset -f __prompt_set_revision
    unset __TAC_MOD_PROMPT_SETS_LOADED
    __fake_gguf "$LLAMA_MODEL_DIR/alpha.gguf"
    local _saved_root="$TACTICAL_REPO_ROOT"
    export TACTICAL_REPO_ROOT="$TMPDIR_BATS/nowhere"

    run __model_register_trained alpha.gguf --benchmark b --held-out h --prompt-set legal
    [[ "$status" -ne 0 ]]
    [[ ! -f "$TMPDIR_BATS/provenance/alpha.gguf.json" ]]
    # The load failure itself is reported (the helper writes to stderr), not swallowed.
    [[ "$output" == *"prompt set"* ]]

    export TACTICAL_REPO_ROOT="$_saved_root"
}
