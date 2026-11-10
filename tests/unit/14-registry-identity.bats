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
    # The scan calls __calc_gpu_layers/__calc_ctx_size, which live in 11d; without it the
    # suite would leave the row's placement columns empty and test the scan against a
    # console that does not exist.
    source "$REPO_ROOT/scripts/11d-llm-gpu.sh"
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

@test "registry-identity: a below-floor verdict saves autotuned=slow, not yes and not no" {
    # Criterion (2026-11-03): field 18 is the SCOPE key. A row that was profiled and
    # measured below LLM_MIN_TPS at every ctx must read "slow" — "yes" would let something
    # serve it as certified, and "no" made every future --all-but-done sweep re-spend a
    # full descent on a verdict that cannot change (the 39.8 GB 70B plateaued at ~6 tps
    # across 4096..131072 and was re-selected by construction).
    # Fails if: the caller's verdict is ignored (always "yes"), or the state lands on a
    # different row.
    AUTOTUNE_SAVE_STATE=slow __llm_autotune_profile_save "gamma.gguf" "native" "4608" "1024" "256" "1" "256" "5.7"
    run awk -F'|' '$3 == "gamma.gguf" {print $17, $18}' "$LLM_REGISTRY"
    [[ "$output" == "5.7 slow" ]]

    # Control: the default path still certifies, so "slow" cannot become the only outcome.
    __llm_autotune_profile_save "gamma.gguf" "native" "4608" "1024" "256" "1" "256" "30.1"
    run awk -F'|' '$3 == "gamma.gguf" {print $18}' "$LLM_REGISTRY"
    [[ "$output" == "yes" ]]
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

@test "model scan: a model nested below the store is registered by its relative path" {
    # Wayne, 2026-11-05: "i want to be able to use all llms in active or below. cant we point
    # to the appropriate file nomatter where it is nested in active?"  The row's file column
    # is the path RELATIVE to the store, which a flat name already satisfies, and which the
    # "$LLAMA_MODEL_DIR/$file" join every consumer uses resolves unchanged.
    local d="$LLAMA_MODEL_DIR/models--org--repo/snapshots/rev"
    mkdir -p "$d"
    truncate -s 400M "$d/nested.gguf"        # sparse: over the 300 MB floor, no real blocks
    # The WALK and the stored path are what this pins; the GGUF parser has its own coverage,
    # so a fabricated header here would test the parser rather than the walk.
    __gguf_metadata() { printf 'Nested model|qwen2|40|8192|8\n'; }

    run __model_scan
    [ "$status" -eq 0 ] || { echo "scan failed: $output"; return 1; }
    local rel
    rel=$(awk -F'|' '$3 ~ /nested\.gguf$/ {print $3}' "$LLM_REGISTRY")
    [ "$rel" = "models--org--repo/snapshots/rev/nested.gguf" ] \
        || { echo "row did not keep the relative path: '$rel'"; return 1; }
    [[ -f "$LLAMA_MODEL_DIR/$rel" ]] \
        || { echo "the stored path does not resolve through the store join"; return 1; }
}

@test "model scan: a flattened hardlink and its nested original are ONE row" {
    # The same inode under two paths must not become two rows: flattening then rescanning
    # would otherwise duplicate every model it flattened.
    local d="$LLAMA_MODEL_DIR/models--org--repo/snapshots/rev"
    mkdir -p "$d"
    truncate -s 400M "$d/dupe.gguf"
    ln "$d/dupe.gguf" "$LLAMA_MODEL_DIR/dupe.gguf"     # the flattened copy
    __gguf_metadata() { printf 'Dupe|qwen2|40|8192|8\n'; }

    run __model_scan
    [ "$status" -eq 0 ] || { echo "scan failed: $output"; return 1; }
    [ "$(awk -F'|' '$3 ~ /dupe\.gguf/ {n++} END {print n+0}' "$LLM_REGISTRY")" -eq 1 ] \
        || { echo "one model produced several rows:"; grep -F 'dupe.gguf' "$LLM_REGISTRY"; return 1; }
    # ...and the FLAT name wins, so row numbers do not move for a flattened model.
    [ "$(awk -F'|' '$3 == "dupe.gguf" {print $3}' "$LLM_REGISTRY")" = "dupe.gguf" ] \
        || { echo "the nested copy was registered instead of the flat one"; return 1; }
}

@test "model scan: a split model's shards are looked for in its OWN directory" {
    # A nested download keeps its shards beside it, never in the store root — grouping them
    # at the root would report every nested split model as incomplete.
    local d="$TMPDIR_BATS/deep/sub/dir"
    mkdir -p "$d"
    : > "$d/split-00001-of-00002.gguf"
    run __model_split_shards_missing "$TMPDIR_BATS/deep" "sub/dir/split-00001-of-00002.gguf"
    [ "$status" -eq 0 ]
    [[ "$output" == *"split-00002-of-00002.gguf"* ]] \
        || { echo "the missing shard was not reported: $output"; return 1; }

    : > "$d/split-00002-of-00002.gguf"
    run __model_split_shards_missing "$TMPDIR_BATS/deep" "sub/dir/split-00001-of-00002.gguf"
    [ -z "$output" ] || { echo "a complete set was reported incomplete: $output"; return 1; }

    # Control: a FLAT path (no directory component) keeps working — the relative-path form
    # must not have replaced the bare-name case.
    : > "$LLAMA_MODEL_DIR/flat-00001-of-00002.gguf"
    run __model_split_shards_missing "$LLAMA_MODEL_DIR" "flat-00001-of-00002.gguf"
    [[ "$output" == *"flat-00002-of-00002.gguf"* ]] \
        || { echo "the flat case broke: $output"; return 1; }
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

# --- schema remap (card e0579318) --------------------------------------------
# __llm_autotune_profiles_remap_by_registry carries tuning columns by filename after
# a scan/renumber.  It used to hardcode a 32-column header and accept only 20/26/32-
# wide rows, so against the LIVE 39-column registry it matched neither arm: the
# output was the header alone, the >=2-line guard refused it, and the callers'
# `|| true` swallowed the refusal — every tuning column silently blank.

# __row39 — a 39-column registry row with recognisable values in the columns the
# remap carries (2=name, 3=file, 8=ctx, 17=tps, 33=workload, 34=ttft, 39=repeat_last_n)
# and blank elsewhere; pass "" for a value to blank a column, as a fresh scan leaves it.
__row39() {  # <num> <file> <ctx> <tps> <workload> <ttft> <repeat_last_n>
    local num="$1" file="$2" ctx="$3" tps="$4" workload="$5" ttft="$6" rln="$7" i v out=""
    for ((i = 1; i <= 39; i++)); do
        v=""
        case "$i" in
            1) v="$num" ;;
            2) v="Model $num" ;;
            3) v="$file" ;;
            4) v="1.0G" ;;
            5) v="Q4_K_M/q8_0" ;;
            6) v="qwen2" ;;
            7) v="24" ;;
            8) v="$ctx" ;;
            9) v="6" ;;
            10) v="1024" ;;
            11) v="256" ;;
            12) v="1" ;;
            13) v="256" ;;
            14) v="llama_server" ;;
            15) v="auto" ;;
            16) v="on" ;;
            17) v="$tps" ;;
            18) v="yes" ;;
            19) v="no" ;;
            20) v="no" ;;
            21) v="20.0" ;;
            33) v="$workload" ;;
            34) v="$ttft" ;;
            39) v="$rln" ;;
        esac
        out+="${out:+|}${v}"
    done
    printf '%s\n' "$out"
}

@test "remap: every column survives a remap to the CURRENT header width (card e0579318)" {
    # Catches: a remap that no-ops on the CURRENT schema — the pre-fix code emitted a
    # 32-column header, matched neither 37 nor 39 wide rows, and left the scanned row
    # with blank tuning.  The 33-39 columns are the ones it silently dropped.
    #
    # 2026-10-13: the row is PADDED TO THE HEADER, and 2b grew the header 39 -> 44
    # (cols 40-44), so the width is DERIVED from the header rather than pinned to the
    # 39 the schema happened to be when this case was written.
    local old="$TMPDIR_BATS/old39.conf" new="$TMPDIR_BATS/new39.conf"
    {
        printf '%s\n' "$LLM_REGISTRY_HEADER"
        __row39 1 alpha.gguf 4096 11.5 chat 1234 64
    } > "$old"
    {
        printf '%s\n' "$LLM_REGISTRY_HEADER"
        __row39 1 alpha.gguf "" "" "" "" ""
    } > "$new"

    __llm_autotune_profiles_remap_by_registry "$old" "$new"

    local row ncols
    row=$(awk -F'|' '$3 == "alpha.gguf"' "$new")
    ncols=$(awk -F'|' 'NR==1{print NF}' "$new")
    # The header is the schema: the row is padded to the header's width, whatever it is.
    # Assert the width really is wider than the 39 this case was written against, so the
    # derived check below cannot pass vacuously on a future narrow schema.
    [ "$ncols" -gt 39 ]
    [ "$(awk -F'|' '{print NF}' <<< "$row")" -eq "$ncols" ]
    [[ "$(cut -d'|' -f8 <<< "$row")" == "4096" ]]
    [[ "$(cut -d'|' -f17 <<< "$row")" == "11.5" ]]
    # The columns the old 32-column remap dropped:
    [[ "$(cut -d'|' -f33 <<< "$row")" == "chat" ]]
    [[ "$(cut -d'|' -f34 <<< "$row")" == "1234" ]]
    [[ "$(cut -d'|' -f39 <<< "$row")" == "64" ]]
    # Header == the ONE definition, not a stale copy.
    [[ "$(head -1 "$new")" == "$LLM_REGISTRY_HEADER" ]]
}

@test "renumber: a failed tuning remap is NAMED, not swallowed (card e0579318)" {
    # Catches: the `|| true` that hid a remap failure — the renumber would look
    # healthy while every row lost its tuning.  Seed the failure by refusing the
    # remap, which is what a stale schema (or a write error) looked like from here.
    __llm_autotune_profiles_remap_by_registry() { return 1; }
    run __renumber_registry 2
    # The renumber itself still succeeds (the registry is already written)...
    [ "$status" -eq 0 ]
    # ...but the failure is REPORTED by name, not silently dropped.
    [[ "$output" == *"tuning-column remap failed"* ]]
}

# ------------------------------------------------------------------------------
# `model scan` must not give an embedding export a registry row.
# Wayne, 2026-11-05: "we really shouldnt have any embedding models in this registry".
# The row was removed by hand the same day; these cases stop it coming back.  The two
# signals are pinned SEPARATELY because they catch different exporters: the arch names
# EmbeddingGemma, while Qwen3-Embedding exports arch `qwen3` and is visible only in its
# pooling metadata.  The third case is the control — without it a predicate that always
# returned true would pass both of the others.
# ------------------------------------------------------------------------------

@test "model scan: an embedding export is recognised by its ARCH" {
    printf 'GGUF\x00\x00\x00\x00gemma-embedding\n' > "$TMPDIR_BATS/embed-arch.gguf"
    run __model_is_embedding "$TMPDIR_BATS/embed-arch.gguf" gemma-embedding
    [ "$status" -eq 0 ]
}

@test "model scan: an embedding export with a CHAT arch is caught by its pooling metadata" {
    # The failure this exists for: Qwen3-Embedding's arch is `qwen3`, identical to a chat
    # model's, so an arch-only test lets the model that prompted the ruling straight back in.
    printf 'GGUFqwen3\x00qwen3.pooling_type\x00' > "$TMPDIR_BATS/embed-pool.gguf"
    run __model_is_embedding "$TMPDIR_BATS/embed-pool.gguf" qwen3
    [ "$status" -eq 0 ]
}

@test "model scan: a chat export with neither signal is NOT treated as embedding" {
    printf 'GGUFqwen3\x00qwen3.block_count\x00' > "$TMPDIR_BATS/chat.gguf"
    run __model_is_embedding "$TMPDIR_BATS/chat.gguf" qwen3
    [ "$status" -eq 1 ]
}

# ------------------------------------------------------------------------------
# `model scan` must not give a multimodal PROJECTOR a registry row.
# Measured 2026-11-10: mmproj-BF16.gguf (931 MB, arch `clip`) is over the scan's 300 MB
# floor, so it registered as a SECOND row named "Qwen3.8-27B" beside the 50.9 GiB model
# of the same name.  That row can never load — the launcher hands a projector to
# llama.cpp as --mmproj, never as -m — and it is selectable by every registry consumer.
# ------------------------------------------------------------------------------

@test "model scan: on a shared-memory host the fit budget is the GUEST, not the carve" {
    # Criterion (measured 2026-11-10 on the RTX Spark box): a 50.9 GiB dense model LOADED
    # AND SERVED with -ngl 999 on a 32,768 MiB pool, because there the pool is a reservation
    # backed by the guest's own RAM.  The scan judged it against the carve instead, so every
    # rescan re-marked the row CPU-only and silently undid the launch (it did, twice).
    #
    # Fails if: the decision is taken against the card on a shared-memory host, or if the
    # reserve is dropped (an 80 GiB model would then "fit" an 86 GiB guest and be asked for
    # a full offload it cannot back).
    local GiB=$(( 1024 * 1024 * 1024 ))
    local card=$(( 32 * GiB )) guest=$(( 86 * GiB ))
    # 50 GiB: inside the guest budget (86 - 12 = 74), outside the 32 GiB carve.
    [ "$(__gpu_layers_fit $(( 50 * GiB )) 65 qwen35 "$card" "$guest" 0)" = "0" ] \
        || { echo "the non-shared arm stopped using the card's carve"; return 1; }
    [ "$(__gpu_layers_fit $(( 50 * GiB )) 65 qwen35 "$card" "$guest" 1)" = "999" ] \
        || { echo "the shared arm did not use the guest budget"; return 1; }
    # 80 GiB: beyond the guest budget once the reserve is kept.
    [ "$(__gpu_layers_fit $(( 80 * GiB )) 65 qwen35 "$card" "$guest" 1)" = "0" ] \
        || { echo "the reserve was dropped: a model larger than the guest was offloaded"; return 1; }
    # The MoE arm is unchanged: the caller decides placement from the layer count.
    [ "$(__gpu_layers_fit $(( 80 * GiB )) 40 qwen35moe "$card" "$guest" 1)" = "40" ] \
        || { echo "the MoE arm changed"; return 1; }
    # An unreadable guest falls back to the card, not to a guess.
    [ "$(__gpu_layers_fit $(( 50 * GiB )) 65 qwen35 "$card" "" 1)" = "0" ] \
        || { echo "a missing guest total did not fall back to the card"; return 1; }
}

@test "model scan: a projector is recognised by its name, in either case and any path" {
    # The launcher's own candidate list is mmproj-F16.gguf / mmproj-BF16.gguf / mmproj*.gguf,
    # so the predicate has to match what the launcher would actually pass.
    run __model_is_projector "mmproj-BF16.gguf"
    [ "$status" -eq 0 ]
    run __model_is_projector "mmproj-F16.gguf"
    [ "$status" -eq 0 ]
    run __model_is_projector "MMPROJ-f16.gguf"
    [ "$status" -eq 0 ]
    run __model_is_projector "/store/active/mmproj-model-f16.gguf"
    [ "$status" -eq 0 ]
    # Control: the weights beside it are not a projector.
    run __model_is_projector "Qwen3.8-27B-BF16-00001-of-00002.gguf"
    [ "$status" -eq 1 ]
    run __model_is_projector "/store/active/Qwen3.8-27B-UD-Q4_K_M.gguf"
    [ "$status" -eq 1 ]
}

@test "model scan: a speculative draft head (mtp- / dflash) is recognised and skipped" {
    run __model_is_draft_head "mtp-Qwen3.8-27B-Q4_0.gguf"
    [ "$status" -eq 0 ]
    run __model_is_draft_head "/store/active/Qwen3.8-27B-DFlash2-Q4_K_M.gguf"
    [ "$status" -eq 0 ]
    run __model_is_draft_head "Qwen3.8-27B-UD-Q4_K_M.gguf"
    [ "$status" -eq 1 ]
}

@test "model scan: a projector beside its weights does not become a row" {
    truncate -s 400M "$LLAMA_MODEL_DIR/Qwen3.8-27B-BF16-00001-of-00002.gguf"
    truncate -s 400M "$LLAMA_MODEL_DIR/Qwen3.8-27B-BF16-00002-of-00002.gguf"
    truncate -s 400M "$LLAMA_MODEL_DIR/mmproj-BF16.gguf"
    # The walk and the filter are what this pins; the parser has its own coverage.
    __gguf_metadata() { printf 'Qwen3.8-27B|qwen35|65|262144|32\n'; }

    run __model_scan
    [ "$status" -eq 0 ] || { echo "scan failed: $output"; return 1; }

    # Exactly one row, and it is the model — not the projector.
    [ "$(awk -F'|' '$1 ~ /^[0-9]+$/ {n++} END {print n+0}' "$LLM_REGISTRY")" -eq 1 ] \
        || { echo "expected one row, got:"; grep -v '^#' "$LLM_REGISTRY"; return 1; }
    [ "$(awk -F'|' '$3 ~ /mmproj/ {n++} END {print n+0}' "$LLM_REGISTRY")" -eq 0 ] \
        || { echo "the projector registered as a model:"; grep -F 'mmproj' "$LLM_REGISTRY"; return 1; }
    [ "$(awk -F'|' '$3 == "Qwen3.8-27B-BF16-00001-of-00002.gguf" {print $3}' "$LLM_REGISTRY")" \
        = "Qwen3.8-27B-BF16-00001-of-00002.gguf" ] \
        || { echo "the model itself was not registered:"; grep -v '^#' "$LLM_REGISTRY"; return 1; }
    # The row is sized as the whole two-shard set, so the projector's bytes never leak in.
    [ "$(awk -F'|' '$3 ~ /^Qwen3\.8-27B-BF16/ {print $4}' "$LLM_REGISTRY")" = "0.8G" ] \
        || { echo "the split size is wrong: $(awk -F'|' '$3 ~ /^Qwen3\.8-27B-BF16/ {print $4}' "$LLM_REGISTRY")"; return 1; }
}

@test "8d144104: a save records the MEASURING binary's build, and keeps the one it replaced" {
    # Criterion — Wayne, 2026-11-04, verbatim: "Bench rows should carry build identity", given
    # "for the avoidance of doubt".  So: every certified row records the build it was measured
    # with AS THE BINARY REPORTS IT, and a re-bench under a DIFFERENT build is distinguishable
    # from the previous measurement rather than silently overwriting it.
    #
    # Catches: a save that records no build at all; one that overwrites the previous identity;
    # and one that churns col 47 on a repeat run under the SAME build (which would erase the
    # history the column exists to keep).
    local _args=( "beta.gguf" "native" "8192" "1024" "256" "1" "256" "12.5" "" "21.0" )
    local i
    # Args 11..31 are empty (11b takes 32 positionals; the 32nd is the build identity).
    for (( i=10; i<=30; i++ )); do _args+=(""); done
    _args[25]="load8"      # 26 meas_load
    _args[26]="3"          # 27 meas_n
    _args[29]="certified"  # 30 meas_state

    __llm_autotune_profile_save "${_args[@]}" "0.9.0-dev (build 166, commit 3ed7284f2)"
    local row
    row=$(awk -F'|' '$3 == "beta.gguf" {print; exit}' "$LLM_REGISTRY")
    [ "$(cut -d'|' -f46 <<< "$row")" = "0.9.0-dev (build 166, commit 3ed7284f2)" ]
    [ -z "$(cut -d'|' -f47 <<< "$row")" ]

    # A re-bench under a DIFFERENT build: col 46 moves, col 47 remembers what it replaced.
    __llm_autotune_profile_save "${_args[@]}" "0.9.1-dev (build 170, commit aaaaaaa)"
    row=$(awk -F'|' '$3 == "beta.gguf" {print; exit}' "$LLM_REGISTRY")
    [ "$(cut -d'|' -f46 <<< "$row")" = "0.9.1-dev (build 170, commit aaaaaaa)" ]
    [ "$(cut -d'|' -f47 <<< "$row")" = "0.9.0-dev (build 166, commit 3ed7284f2)" ]

    # The same build again: col 47 must NOT be rewritten to the current value.
    __llm_autotune_profile_save "${_args[@]}" "0.9.1-dev (build 170, commit aaaaaaa)"
    row=$(awk -F'|' '$3 == "beta.gguf" {print; exit}' "$LLM_REGISTRY")
    [ "$(cut -d'|' -f47 <<< "$row")" = "0.9.0-dev (build 166, commit 3ed7284f2)" ]
}

@test "sharded lifecycle: __model_row_files resolves all shards of a split row, and single files unchanged" {
    truncate -s 10M "$LLAMA_MODEL_DIR/Split-Model-00001-of-00003.gguf"
    truncate -s 10M "$LLAMA_MODEL_DIR/Split-Model-00002-of-00003.gguf"
    truncate -s 10M "$LLAMA_MODEL_DIR/Split-Model-00003-of-00003.gguf"
    truncate -s 10M "$LLAMA_MODEL_DIR/alpha.gguf"

    run __model_row_files "$LLAMA_MODEL_DIR" "Split-Model-00001-of-00003.gguf"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 3 ]
    [ "${lines[0]}" = "$LLAMA_MODEL_DIR/Split-Model-00001-of-00003.gguf" ]
    [ "${lines[1]}" = "$LLAMA_MODEL_DIR/Split-Model-00002-of-00003.gguf" ]
    [ "${lines[2]}" = "$LLAMA_MODEL_DIR/Split-Model-00003-of-00003.gguf" ]

    # Single-file control
    run __model_row_files "$LLAMA_MODEL_DIR" "alpha.gguf"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 1 ]
    [ "${lines[0]}" = "$LLAMA_MODEL_DIR/alpha.gguf" ]
}

@test "sharded lifecycle: model archive and model delete act on every shard of a split row" {
    truncate -s 10M "$LLAMA_MODEL_DIR/Split-Model-00001-of-00002.gguf"
    truncate -s 10M "$LLAMA_MODEL_DIR/Split-Model-00002-of-00002.gguf"
    export LLAMA_ARCHIVE_DIR="$TMPDIR_BATS/archived"
    export LLAMA_DRIVE_ROOT="$TMPDIR_BATS"
    export ACTIVE_LLM_FILE="$TMPDIR_BATS/active_llm"
    export LLM_DEFAULT_FILE="$TMPDIR_BATS/default_llm"
    mkdir -p "$LLAMA_ARCHIVE_DIR"
    printf '4|Split-Model|Split-Model-00001-of-00002.gguf|0.1G|Q4_K_M/q8_0/q8_0|qwen35|999|4096|8|1024|256|1|256|native|auto|on|0|no|no|no|0|0|0|0|0|0|||||||||||||||||||||\n' >> "$LLM_REGISTRY"

    # Archive row 4: both shards move to LLAMA_ARCHIVE_DIR
    __model_archive 4 <<< "y"
    [ ! -f "$LLAMA_MODEL_DIR/Split-Model-00001-of-00002.gguf" ]
    [ ! -f "$LLAMA_MODEL_DIR/Split-Model-00002-of-00002.gguf" ]
    [ -f "$LLAMA_ARCHIVE_DIR/Split-Model-00001-of-00002.gguf" ]
    [ -f "$LLAMA_ARCHIVE_DIR/Split-Model-00002-of-00002.gguf" ]

    # Put both shards back and test __model_delete
    mv "$LLAMA_ARCHIVE_DIR"/Split-Model-*-of-00002.gguf "$LLAMA_MODEL_DIR/"
    printf '4|Split-Model|Split-Model-00001-of-00002.gguf|0.1G|Q4_K_M/q8_0/q8_0|qwen35|999|4096|8|1024|256|1|256|native|auto|on|0|no|no|no|0|0|0|0|0|0|||||||||||||||||||||\n' >> "$LLM_REGISTRY"

    __model_delete 4 <<< "y"
    [ ! -f "$LLAMA_MODEL_DIR/Split-Model-00001-of-00002.gguf" ]
    [ ! -f "$LLAMA_MODEL_DIR/Split-Model-00002-of-00002.gguf" ]
}

@test "sharded lifecycle: model download expands a subfolder shard spec and routes through llm-pull" {
    export __LLAMA_DRIVE_MOUNTED=1
    export LLAMA_ARCHIVE_DIR="$TMPDIR_BATS/archived"
    export LLAMA_DRIVE_ROOT="$TMPDIR_BATS"
    export TACTICAL_REPO_ROOT="$REPO_ROOT"
    mkdir -p "$LLAMA_ARCHIVE_DIR" "$TMPDIR_BATS/bin"

    cat > "$TMPDIR_BATS/bin/hf" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    cat > "$TMPDIR_BATS/bin/llm-pull" <<'STUB'
#!/usr/bin/env bash
printf '%s|%s\n' "$1" "$2" > "$LLM_MODELS_DIR/.pull-recorded"
truncate -s 400M "$LLM_MODELS_DIR/Split-New-00001-of-00002.gguf"
truncate -s 400M "$LLM_MODELS_DIR/Split-New-00002-of-00002.gguf"
STUB
    chmod +x "$TMPDIR_BATS/bin/hf" "$TMPDIR_BATS/bin/llm-pull"
    PATH="$TMPDIR_BATS/bin:$PATH"
    __gguf_metadata() { printf 'Split-New|qwen35|40|131072|32\n'; }

    run __model_download "unsloth/Split-New-GGUF:BF16/Split-New-00001-of-00002.gguf"
    [ "$status" -eq 0 ]
    [ "$(cat "$LLAMA_MODEL_DIR/.pull-recorded")" = "unsloth/Split-New-GGUF|BF16/Split-New-*-of-00002.gguf" ]
    [ -f "$LLAMA_MODEL_DIR/Split-New-00001-of-00002.gguf" ]
    [ -f "$LLAMA_MODEL_DIR/Split-New-00002-of-00002.gguf" ]
    [ "$(awk -F'|' '$3 == "Split-New-00001-of-00002.gguf" {print $4}' "$LLM_REGISTRY")" = "0.8G" ]
}
