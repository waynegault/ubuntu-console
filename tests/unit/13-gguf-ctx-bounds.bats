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
#   3. The Phase-4 TPS-floor descent walked a fixed x3/4 ladder and could step
#      OVER the value the registry held.  Row 12 (Phi-3.5-mini, native 131072)
#      went 9216 -> 6656, skipping 8192 — the value that row had recorded — and
#      certified 6,656 without ever measuring 8,192.  The filled-cache tps is
#      flat (5.05 -> 6.05 from 131K down to 9216) and then jumps to 25.65 at
#      6,656, so 8,192 sits exactly where the answer changes and the run settled
#      it by arithmetic instead of by measurement.  (That recorded 8,192 was
#      itself an artifact of the parser bug in (1) — never a measurement — which
#      is the point: a registry value nothing had verified.)
#      __autotune_descent_candidates now builds the candidate list up front and
#      injects the previously recorded ctx into it, so the walk still descends (a
#      genuinely unusable value is rejected on its own merits) but can no longer
#      skip a value without testing it.
#
# None of the three needs a GPU: a GGUF header is metadata, so a zero-tensor
# fixture is enough (tests/helpers/make-gguf-fixture.py), the bounds are
# arithmetic, and the descent candidates are pure integer arithmetic.
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

# --- Phase-4 descent candidates ---------------------------------------------
# __autotune_descent_candidates <from> <min_ctx> <prev> -> descending ctx list.
# Every value is below `from`, none below `min_ctx`, none repeated; a `prev`
# inside [min_ctx, from) is merged IN (that is the bug-3 fix), anything outside
# is ignored.

@test "descent-candidates: a previously recorded ctx is merged into the ladder" {
    # The measured row-12 walk, with the ctx that row had recorded (8192) added —
    # the value the ladder used to step over between 9216 and 6656.
    local out; out="$(__autotune_descent_candidates 131072 4096 8192 | tr '\n' ' ')"
    [[ "$out" == "98304 73728 55296 41472 30720 23040 16896 12288 9216 8192 6656 4608 4096 " ]]
}

@test "descent-candidates: without a held value it is the plain x3/4 walk" {
    local out; out="$(__autotune_descent_candidates 131072 4096 0 | tr '\n' ' ')"
    [[ "$out" == "98304 73728 55296 41472 30720 23040 16896 12288 9216 6656 4608 4096 " ]]
    # and 8192 is genuinely absent from that walk — the regression this guards.
    [[ "$out" != *" 8192 "* ]]
}

@test "descent-candidates: the start value is never itself a candidate" {
    # The walk starts BELOW the value that already failed the floor; repeating it
    # would burn a CUDA cycle re-testing the window that triggered the descent.
    local out; out="$(__autotune_descent_candidates 16384 4096 16384)"
    [[ "$(printf '%s\n' "$out" | grep -c '^16384$')" == "0" ]]
    # a prev equal to `from` is likewise not injected as a duplicate.
    [[ "$(printf '%s\n' "$out" | grep -c '^16384$')" == "0" ]]
}

@test "descent-candidates: a prev outside [min_ctx, from) is ignored" {
    local below above
    below="$(__autotune_descent_candidates 16384 4096 2048)"
    [[ "$below" != *"2048"* ]]
    above="$(__autotune_descent_candidates 16384 4096 65536)"
    [[ "$above" != *"65536"* ]]
}

@test "descent-candidates: a malformed min_ctx falls back to the 4096 floor" {
    local out; out="$(__autotune_descent_candidates 8192 "" 0 | tr '\n' ' ')"
    [[ "$out" == "6144 4608 4096 " ]]
    out="$(__autotune_descent_candidates 8192 0 0 | tr '\n' ' ')"
    [[ "$out" == "6144 4608 4096 " ]]
}

@test "descent-candidates: a malformed start value yields nothing and succeeds" {
    local junk
    for junk in "" "bogus" 0 "-4096"; do
        run __autotune_descent_candidates "$junk" 4096 8192
        [[ "$status" -eq 0 ]] || { echo "non-zero exit for from='$junk'"; return 1; }
        [[ -z "$output" ]] || { echo "output for from='$junk': '$output'"; return 1; }
    done
}

@test "descent-candidates: strictly descending and duplicate-free everywhere" {
    # The property the whole fix rests on: each rung is strictly lower than the
    # last, so the walk advances monotonically and never re-tests a window.
    local from min prev out last cur
    for from in 512 4096 8192 65536 131072; do
        for min in 512 4096 8192; do
            for prev in 0 512 4096 8192 65536 131072; do
                out="$(__autotune_descent_candidates "$from" "$min" "$prev")"
                [[ -z "$out" ]] && continue
                [[ "$(printf '%s\n' "$out" | grep -c "^${from}$")" == "0" ]] \
                    || { echo "contains from for $from/$min/$prev: '$out'"; return 1; }
                last=""
                while IFS= read -r cur; do
                    [[ "$cur" =~ ^[0-9]+$ ]] || { echo "non-numeric '$cur' for $from/$min/$prev"; return 1; }
                    [[ "$cur" -ge "$min" ]] || { echo "below min for $from/$min/$prev: '$out'"; return 1; }
                    if [[ -n "$last" ]]; then
                        (( cur < last )) || { echo "not strictly descending for $from/$min/$prev: '$out'"; return 1; }
                    fi
                    last="$cur"
                done <<< "$out"
            done
        done
    done
}

# --- __autotune_fa_retry -----------------------------------------------------
# Criterion (2026-11-03): an OOM is a FIT verdict and must NOT be retried with
# --flash-attn off, because FA off allocates the full attention buffer — it asks for
# MORE of the resource that just ran out. Measured: two such retries at ctx 131072 and
# 65536 with a 39.8 GB row on the 96 GiB pool drove the 29.8 GiB guest into the kernel
# OOM killer, which killed openclaw-gateway.service 7 times in 25 minutes.
# An arch that cannot run FA is the opposite case and still gets its one retry.

@test "fa-retry: an OOM descends instead of retrying with flash attention off" {
    # Fails if: the retry returns for an OOM (the defect), i.e. the probe asks for
    # more memory than the attempt that just failed.
    [ "$(__autotune_fa_retry oom on)" = "descend" ]
}

@test "fa-retry: a model load failure still gets one retry with flash attention off" {
    # Fails if: the gate becomes blanket and an FA-incompatible arch loses the only
    # recovery this script has for it.
    [ "$(__autotune_fa_retry load_fail on)" = "retry" ]
}

@test "fa-retry: an unclassified failure keeps the retry (never lose the recovery)" {
    # Fails if: an unknown/other failure is treated as OOM and the retry is dropped.
    [ "$(__autotune_fa_retry other on)" = "retry" ]
}

@test "fa-retry: with flash attention already off there is nothing to retry" {
    # Fails if: the decision ignores the current state and loops a retry forever.
    [ "$(__autotune_fa_retry oom off)" = "noop" ]
    [ "$(__autotune_fa_retry load_fail off)" = "noop" ]
}

# --- __kv_mb_per_1k (KV geometry, card bf92711c) ------------------------------
# Criterion (2026-11-03): the KV estimate comes from the model's GEOMETRY when the header
# carries it, and falls back to the old shape-agnostic constant — saying so — when it does
# not. Measured on Qwen3-Coder-30B (48 layers, kv_heads 4, head_dim 128):
# 48*2*4*128*1.06*1024/1048576 = 50.88 MiB/1k against the old constant's 96.

@test "kv-estimate: geometry gives the arithmetic cost, not the layer constant" {
    [ "$(__kv_mb_per_1k 48 4 128 1.06)" = "50.88" ]
}

@test "kv-estimate: more KV heads cost more, and the constant ignores that" {
    # Same layers, 32 KV heads instead of 4 -> 8x the KV. A shape-blind constant cannot
    # tell these apart, which is the defect this closes.
    [ "$(__kv_mb_per_1k 48 32 128 1.06)" = "407.04" ]
}

@test "kv-estimate: no geometry falls back to the old constant" {
    # Fails if: a header without the KV keys returns a geometry-derived number.
    [ "$(__kv_mb_per_1k 48)" = "96.00" ]
}

@test "kv-estimate: the fallback is a PREDICATE the caller reports, not a silent value" {
    # Fails if: a missing geometry becomes indistinguishable from a measured one. The
    # warning lives in the caller (autotune-model's warn) so the function keeps one stream.
    ! __kv_geometry_known 0 0
    ! __kv_geometry_known 4 0
    ! __kv_geometry_known 0 128
    __kv_geometry_known 4 128
}

# --- __autotune_spec_worth_keeping (spec-decode, 2026-11-03) -------------------
# Criterion: a spec-decode block is only RECORDED when its draft actually placed tokens.
# Measured on gpt-oss-120b: the sweep's own line read `block 4: 31.28 tps (accept len 0,
# rate 0)` and the row then certified `spec_type=ngram spec_n_max=8 spec_accept_len=0`,
# so every token paid a draft lookup for zero gain and the recorded tps was measured with
# that overhead in place.

@test "spec-decode: a block that accepts nothing is NOT worth keeping" {
    # Fails if: tps alone can record a draft that never hits.
    ! __autotune_spec_worth_keeping 0 0
    ! __autotune_spec_worth_keeping 0 0.0
}

@test "spec-decode: a block that places tokens IS worth keeping" {
    # Fails if: the gate becomes blanket and a real spec win is discarded.
    __autotune_spec_worth_keeping 3 0.75
    __autotune_spec_worth_keeping 1
}

@test "spec-decode: a missing or unparsable metric is not evidence of a win" {
    # Fails if: an empty counter reads as success. 0 is the honest reading of "no evidence".
    ! __autotune_spec_worth_keeping "" ""
    ! __autotune_spec_worth_keeping "n/a" ""
}

@test "spec-decode: the predicate EXISTS (a missing function must not read as 'not worth keeping')" {
    # `! __missing` is TRUE — a nonexistent command also returns non-zero — so the two
    # negative cases above would pass vacuously if this function were ever lost (measured
    # 2026-11-03: a peer tree-restore removed it and two cases still went green).
    declare -f __autotune_spec_worth_keeping >/dev/null
}

@test "spec-decode: the block sweep stops after two zero-accept blocks" {
    # Each block costs a CUDA cycle plus a full model load; measured 2026-11-03 four
    # blocks were walked and every one accepted nothing. Two consecutive zeros is the stop.
    # Fails if: the sweep keeps spending cycles after the evidence is in, or stops early
    # on a single zero (a later, larger block can legitimately start hitting).
    declare -f __autotune_spec_sweep_stop >/dev/null
    ! __autotune_spec_sweep_stop 0
    ! __autotune_spec_sweep_stop 1
    __autotune_spec_sweep_stop 2
    __autotune_spec_sweep_stop 3
}

# --- model sizing across a shard set ---------------------------------------
# A row names ONE file and llama.cpp loads the whole SET, so a stat on the named path
# reports shard 1 and under-counts the model. Measured 2026-11-04 in this box's log:
# the 88.0 GiB Flash-Next row printed "model 42788 MiB" (shard 1 of 3) and derived
# START_CTX 262144 from it; the 53.9 GiB 70B row printed "model 38016 MiB".
# The fixtures are synthetic sizes so the cases assert the arithmetic, not this box.

@test "model-bytes: a split GGUF is the sum of its shards, not the named one" {
    # Fails if: sizing reads only the path the row names (7168 -> 4096), which is the
    # defect that made BUDGET and START_CTX describe half a model.
    mkdir -p "$TMPDIR_BATS"
    local stem="$TMPDIR_BATS/split-model"
    head -c 4096 /dev/zero > "$stem-00001-of-00003.gguf"
    head -c 2048 /dev/zero > "$stem-00002-of-00003.gguf"
    head -c 1024 /dev/zero > "$stem-00003-of-00003.gguf"
    run __autotune_model_bytes "$stem-00001-of-00003.gguf"
    [ "$status" -eq 0 ]
    [ "$output" = "7168" ]
}

@test "model-bytes: a single-file model is its own size" {
    # The other direction: a non-split path must not be inflated or zeroed.
    mkdir -p "$TMPDIR_BATS"
    local f="$TMPDIR_BATS/single-model.gguf"
    head -c 5000 /dev/zero > "$f"
    run __autotune_model_bytes "$f"
    [ "$status" -eq 0 ]
    [ "$output" = "5000" ]
}

@test "model-bytes: an absent path yields 0 rather than an error" {
    # Fails if: a missing model aborts under `set -e` instead of being reported as 0 —
    # the row then dies before it can refuse with a reason.
    run __autotune_model_bytes "$TMPDIR_BATS/absent-00001-of-00002.gguf"
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "model-bytes: the symbol exists (a missing one passes the cases above vacuously)" {
    declare -f __autotune_model_bytes >/dev/null
}
