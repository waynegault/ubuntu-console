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
