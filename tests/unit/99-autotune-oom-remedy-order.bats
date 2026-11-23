#!/usr/bin/env bats
# ==============================================================================
# Unit Tests — an OOM's remedy ORDER, and that the remedy is reachable
# ==============================================================================
# Measured 2026-11-23 on row 4 (Nemotron-3.5-Super-VL-120B-A12B NVFP4, 73.3 GiB).
# `llama.cpp` failed `cudaMalloc` of 72114 MiB.  The tuner had one remedy in the
# wrong place and one that could not be reached:
#
#   * the -ngl release fired, still OOMed, and the caller halved ctx for three
#     tests (44032 -> 22016 -> 11008) without ever trying expert placement,
#     because the `descend` arm falls through to `_launch_or_record_failure ||
#     return 1` and that return ends the spawn before the failure is read;
#   * `_startup_fail_type` asked "did it fail to load?" before "was there an OOM
#     witness?" — and a failed allocation is both, so `load_fail` won and the
#     flash-attention branch ran instead of any memory remedy.
#
# WHAT THIS PINS is the ORDER, not the numbers: an OOM on a pinned row buys a
# release FIRST (the GPU keeps the layers it can), expert offload SECOND (partial
# first), and nothing for a dense row or one already placed.  The stub cannot
# disagree with a real cluster, so the values come from the rule Wayne set —
# "ensure this keeps the llm working through gpu not cpu".
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/autotune-model.sh"

setup() {
    # Only the two decision functions, extracted rather than sourced: sourcing the
    # whole script would RUN it.
    HARness="$BATS_TEST_TMPDIR/decisions.sh"
    {
        awk '/^function __autotune_oom_remedy\(\)/,/^}/' "$SCRIPT"
        awk '/^# _moe_descent_next/,/^}/' "$SCRIPT" | sed -n '/^_moe_descent_next()/,/^}/p'
    } > "$HARness"
    grep -q '__autotune_oom_remedy' "$HARness"
}

# remedy <ngl> <moe_flags> <has_moe> — the arm's decision, with the ladder reset.
remedy() {
    BENCH_N_CPU_MOE=""
    bash -c 'source "$1"; BENCH_N_CPU_MOE=""; __autotune_oom_remedy "$2" "$3" "$4"' \
        _ "$HARness" "$1" "$2" "$3"
}

# _dflash_branch — the dflash argv branch only, ending before the next elif.
_dflash_branch() {
    local start next
    start="$(grep -n 'BENCH_SPEC_TYPE:-off}" == "draft-dflash"' "$SCRIPT" | cut -d: -f1)"
    next="$(awk -v s="$start" 'NR > s && /^        elif/ {print NR; exit}' "$SCRIPT")"
    [[ -n "$start" && -n "$next" ]] || return 1
    sed -n "${start},$((next - 1))p" "$SCRIPT"
}

@test "a pinned row earns a release first — the GPU keeps the layers it can" {
    [ "$(remedy 89 0 1)" = "release" ]
    # even with the expert ladder available: placement is not the first answer
    [ "$(remedy 999 0 1)" = "release" ]
}

@test "after the release, an unplaced MoE row earns the expert ladder" {
    [ "$(remedy auto 0 1)" = "experts" ]
}

@test "a dense row is never handed expert offload" {
    # Catches the guard being dropped: --n-cpu-moe on a dense model is invalid, and
    # it would silently change every dense row's measurement.
    [ "$(remedy auto 0 0)" = "none" ]
}

@test "a row already carrying --cpu-moe keeps it, and the ladder stands down" {
    # Catches the ladder overriding a placement the profile or the existing rule made:
    # a second, partial placement on top of an all-or-nothing one is not a remedy.
    [ "$(remedy auto 1 1)" = "none" ]
}

@test "the ladder rises and then admits it is spent" {
    # Catches a ladder that returns the same rung forever: every retry would repeat
    # --n-cpu-moe 8 and no OOM would ever be resolved.
    run bash -c 'source "$1"; BENCH_N_CPU_MOE=""
        while n="$(_moe_descent_next)"; do printf "%s " "$n"; BENCH_N_CPU_MOE="$n"; done' \
        _ "$HARness"
    [ "$status" -eq 0 ]
    [ "$output" = "8 16 32 64 999 " ]
}

@test "draft-dflash is reachable through all four seams, or not at all" {
    # Catches the cross-seam gap measured 2026-11-23: the argv builder emitted
    # --spec-draft-* in exactly ONE branch (draft-mtp), and the sweep's type list
    # named only ngram and draft-mtp, so adding the argv branch alone would have
    # been unreachable code that still looked like a feature.
    #
    # The four seams a declared dflash draft must pass through:
    #   1. the capability probe discovers it and sets HAS_DFLASH
    #   2. the sweep's type list offers it when HAS_DFLASH=1
    #   3. the sweep selects DFLASH_DRAFT_PATH for it, on the device
    #   4. the argv builder emits --spec-type draft-dflash WITHOUT --spec-draft-device none
    [ "$(grep -c 'HAS_DFLASH=1' "$SCRIPT")" -eq 1 ]
    [ "$(grep -c 'HAS_DFLASH:-0}" == "1" ]] && _sb_types' "$SCRIPT")" -eq 1 ]
    [ "$(grep -c '_sb_type" == "draft-dflash" &&' "$SCRIPT")" -eq 1 ]
    [ "$(grep -c 'BENCH_SPEC_TYPE:-off}" == "draft-dflash"' "$SCRIPT")" -eq 1 ]
    # and the dflash branch must NOT hand the draft to the CPU
    local block
    block="$(_dflash_branch)"
    [ -n "$block" ]
    # COMMENTS STRIPPED: the branch explains that it does NOT use --spec-draft-device none,
    # and a comment is not argv.  Checking the raw block reds on the prose, not the flags.
    ! grep -vE '^[[:space:]]*#' <<< "$block" | grep -q 'spec-draft-device none'
}

@test "a CPU draft is never emitted for a dflash row" {
    # Wayne's standing rule: no part of a model runs on the CPU.  The generic
    # draft branch forces --spec-draft-device none, so dflash must not fall into it.
    local dflash_block _code
    dflash_block="$(_dflash_branch)"
    [ -n "$dflash_block" ]
    # COMMENTS OUT, because a comment mentioning a flag is not a flag.
    _code="$(grep -vE '^[[:space:]]*#' <<< "$dflash_block")"
    # The draft goes to the DEVICE ...
    grep -q 'spec-draft-ngl' <<< "$_code"
    # ... and never to the CPU.  Measured 2026-11-23: the first version of this case
    # asserted only that the branch CONTAINED spec-draft-ngl, so it passed while the
    # branch also emitted --spec-draft-device none — a test that could not disagree.
    ! grep -q 'spec-draft-device none' <<< "$_code"
}

@test "a rung that dies on its allocation is not a held rung" {
    # Catches the defect measured 2026-11-23: the 120B launched, reported no load
    # failure, was credited as a working rung, and the server then died on
    # `CUDA error: out of memory` inside ggml_backend_cuda_buffer_set_tensor.  The
    # caller halved ctx and the next rung was never earned.  A rung holds only if
    # the process is STILL ALIVE.
    local block
    block="$(awk '/^    _arm_rung_held\(\) \{/,/^    \}/' "$SCRIPT")"
    [ -n "$block" ]
    # it must test liveness, not just the launch's exit status
    grep -q 'kill -0' <<< "$block"
    # and BOTH remedy arms must consult it
    local n
    n="$(grep -c '_arm_rung_held; then' "$SCRIPT")"
    [ "$n" -eq 2 ]
}

@test "the OOM witness outranks the load-failure signature" {
    # The ordering that produced "unsupported model".  Read as text because the
    # classifier is nested inside _bench_spawn and cannot be extracted; this is a
    # structural check, and the real proof is a row that loads.
    local block
    block="$(awk '/^    _startup_fail_type\(\) \{/,/^    \}/' "$SCRIPT")"
    [ -n "$block" ]
    local oom_line load_line
    oom_line="$(grep -n '_oom_witness_present' <<< "$block" | head -1 | cut -d: -f1)"
    load_line="$(grep -n '_startup_load_fail' <<< "$block" | head -1 | cut -d: -f1)"
    [ -n "$oom_line" ] && [ -n "$load_line" ]
    # the OOM test must be the FIRST branch, or a cudaMalloc failure reads as load_fail
    [ "$oom_line" -lt "$load_line" ]
}
