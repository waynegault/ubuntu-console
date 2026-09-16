#!/usr/bin/env bats
# ==============================================================================
# Unit Tests — GGUF metadata parsing and autotune ctx-probe bounds
# ==============================================================================
# Two bug classes, both found on 2026-09-16 while re-certifying registry ctx
# values.  Both were previously catchable ONLY by burning a 4 GB card run —
# which is exactly why they cost what they cost.
#
#   1. __gguf_metadata matched the context key with an unanchored
#      /context_length/ and assigned last-wins, so a Phi-3.5 header's
#      phi3.rope.scaling.original_context_length (4096 — the LongRoPE *original*
#      window, not the usable one) overwrote phi3.context_length (131072).  Five
#      registry rows reported a 4096 window for a 131072-native model, and the
#      same value fed the autotune's ctx ceiling.
#
#   2. The ctx-probe ceiling could land BELOW its floor: MAX_CTX = the model's
#      native window (2048 for legalparam) with MIN_CTX = 4096 made the phase-1
#      loop `while [[ $c -ge $MIN_CTX ]]` run zero iterations, so the row aborted
#      as an "unsupported model" having attempted nothing — three consecutive
#      runs, 30 s each, zero CUDA cycles.
#
# Neither needs a GPU: a GGUF header is metadata, so a zero-tensor fixture is
# enough (tests/helpers/make-gguf-fixture.py), and the bounds are arithmetic.
# The metadata tests are pinned against the fixtures that REPRODUCE the failure —
# verified to fail on the pre-fix parser (6a8b4e1a^) and pass after it, so they
# assert the bug rather than the current output.
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
TMPDIR_BATS="$(mktemp -d)"

setup() {
    source "$REPO_ROOT/scripts/01-constants.sh"
    source "$REPO_ROOT/scripts/11d-llm-gpu.sh"
    source "$REPO_ROOT/scripts/11b-llm-autotune.sh"
}

teardown() {
    rm -rf "$TMPDIR_BATS"
}

# --- helpers ----------------------------------------------------------------
# __fixture <case> — generate a metadata-only GGUF and echo its path.
__fixture() {
    local case="$1" out="$TMPDIR_BATS/$1.gguf"
    "$TAC_PYTHON" "$REPO_ROOT/tests/helpers/make-gguf-fixture.py" "$case" "$out" >/dev/null
    printf '%s' "$out"
}

# __meta_field <file> <field> — 1=name 2=architecture 3=block_count 4=context_length
__meta_field() {
    __gguf_metadata "$1" 2>/dev/null | cut -d'|' -f"$2"
}

# --- GGUF metadata ----------------------------------------------------------
@test "gguf-metadata: the model's own context key beats the rope-scaling original" {
    local f; f="$(__fixture both-keys)"
    # 131072 is phi3.context_length; 4096 is rope.scaling.original_context_length,
    # which the unanchored last-wins match returned instead.
    [[ "$(__meta_field "$f" 4)" == "131072" ]]
    [[ "$(__meta_field "$f" 2)" == "phi3" ]]
    [[ "$(__meta_field "$f" 3)" == "32" ]]
}

@test "gguf-metadata: a rope-scaling key alone is not adopted as the window" {
    local f; f="$(__fixture rope-only)"
    # The fixture's only context-ish key is 2048 — a window the model does NOT
    # have.  Reporting it would be worse than reporting nothing, so the parser
    # must fall back to its own default (4096) instead.
    [[ "$(__meta_field "$f" 4)" != "2048" ]]
    [[ "$(__meta_field "$f" 4)" == "4096" ]]
}

@test "gguf-metadata: general.context_length is accepted when that is all there is" {
    local f; f="$(__fixture general-ctx)"
    [[ "$(__meta_field "$f" 4)" == "8192" ]]
    [[ "$(__meta_field "$f" 2)" == "llama" ]]
}

@test "gguf-metadata: a plain <arch>.context_length parses" {
    local f; f="$(__fixture plain-ctx)"
    [[ "$(__meta_field "$f" 4)" == "32768" ]]
    [[ "$(__meta_field "$f" 3)" == "28" ]]
}

@test "gguf-metadata: a missing context key yields the default, not a wrong value" {
    local f; f="$(__fixture no-ctx)"
    [[ "$(__meta_field "$f" 4)" == "4096" ]]
    [[ "$(__meta_field "$f" 2)" == "llama" ]]
}

# --- ctx-probe bounds -------------------------------------------------------
# __autotune_ctx_bounds <start_raw> <native_ctx> <vram_mult> [min_ctx]
#   -> "start_ctx max_ctx min_ctx"
__bounds() { __autotune_ctx_bounds "$1" "$2" "$3" 4096; }

@test "ctx-bounds: the floor follows the ceiling down for a sub-MIN_CTX window" {
    # legalparam: native 2048, MIN_CTX 4096.  The bug left min_ctx at 4096 with
    # max_ctx 2048, so the phase-1 loop `while [[ $c -ge $MIN_CTX ]]` never ran and
    # the row was reported as an unsupported model having attempted nothing.
    read -r start max min < <(__bounds 8192 2048 2)
    [[ "$start" == "2048" ]]
    [[ "$max" == "2048" ]]
    [[ "$min" == "2048" ]]
    [[ "$min" -le "$start" ]]
}

@test "ctx-bounds: the native window is the binding ceiling when it is the smaller" {
    # cap would be 8192x8 = 65536, but the model's window is 4096: native wins.
    read -r start max _min < <(__bounds 8192 4096 8)
    [[ "$start" == "4096" ]]
    [[ "$max" == "4096" ]]
    # and when the native window is larger than the cap, the cap wins.
    read -r start2 max2 _m2 < <(__bounds 8192 32768 2)
    [[ "$start2" == "8192" ]]
    [[ "$max2" == "16384" ]]
}

@test "ctx-bounds: the VRAM multiplier caps the climb, and raising it raises the ceiling" {
    read -r _s max2  _m2 < <(__bounds 8192 131072 2)
    read -r _s max8  _m8 < <(__bounds 8192 131072 8)
    [[ "$max2" == "16384" ]]
    [[ "$max8" == "65536" ]]
    # Phi-3.5-mini serves 32768 FULL; a 2x cap cannot reach it, an 8x cap can.
    [[ "$max8" -ge 32768 ]]
}

@test "ctx-bounds: without a native window the ceiling stays at the KV-math start" {
    # Pre-existing behaviour, kept on purpose: max_ctx starts at start_ctx, and the
    # VRAM cap (16384 here) cannot RAISE a ceiling.  So a model whose GGUF yields no
    # context_length never climbs above where the KV math put it.
    read -r start max min < <(__bounds 8192 "" 2)
    [[ "$start" == "8192" ]]
    [[ "$max" == "8192" ]]
    [[ "$min" == "4096" ]]
}

@test "ctx-bounds: a junk start value cannot produce an empty or zero bound" {
    read -r start max min < <(__bounds "" "" 2)
    [[ "$start" =~ ^[0-9]+$ ]]
    [[ "$start" -ge 4096 ]]
    [[ "$max" =~ ^[0-9]+$ ]]
    [[ "$min" =~ ^[0-9]+$ ]]
}

@test "ctx-bounds: a junk multiplier falls back to 2 and warns" {
    run __autotune_ctx_bounds 8192 131072 "bogus" 4096
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"not a positive integer"* ]]
    [[ "$output" == *"8192 16384 4096"* ]]
}

@test "ctx-bounds: the invariant holds across the whole input space" {
    # 1 <= min <= start <= max, for every combination a real row can produce —
    # this is the property the phase-1 loop's `while [[ $c -ge $MIN_CTX ]]` needs,
    # and the one the 2026-09-16 bug violated.
    local start_raw native mult out start max min
    for start_raw in 0 100 2048 4096 8192 65536 5000000; do
        for native in "" 0 2048 4096 32768 131072 262144 4194304; do
            for mult in 2 8; do
                out="$(__autotune_ctx_bounds "$start_raw" "$native" "$mult" 4096)"
                read -r start max min <<< "$out"
                [[ "$start" =~ ^[0-9]+$ ]] || { echo "non-numeric start: '$out'"; return 1; }
                [[ "$max" =~ ^[0-9]+$ ]]   || { echo "non-numeric max: '$out'"; return 1; }
                [[ "$min" =~ ^[0-9]+$ ]]   || { echo "non-numeric min: '$out'"; return 1; }
                (( min >= 1 ))     || { echo "min < 1 for $start_raw/$native/$mult: '$out'"; return 1; }
                (( min <= start )) || { echo "min > start for $start_raw/$native/$mult: '$out'"; return 1; }
                (( start <= max )) || { echo "start > max for $start_raw/$native/$mult: '$out'"; return 1; }
            done
        done
    done
}
