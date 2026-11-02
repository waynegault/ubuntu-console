#!/usr/bin/env bats
# ==============================================================================
# Unit Tests — the autotune VRAM-baseline tolerance covers the lane it spares
# ==============================================================================
# `scripts/autotune-model.sh` refuses to autotune when total-free VRAM exceeds
# LLM_AUTOTUNE_BASELINE_GAP_MAX.  The host profile sizes that tolerance for the
# DRIVER's reservation alone (~2.9 GiB on this Blackwell box, "no process attached").
#
# But the guard runs AFTER `__llm_stand_down_cuda_lanes`, which deliberately SPARES
# the lanes named in LLAMA_LANE_KEEP_UNITS — on this host the embedding lane.  So the
# tolerated gap must cover the driver PLUS that spared lane's footprint.  It did not:
#
#   measured 2026-11-02, only `llama-cuda-embeddinggemma-embed.service` holding:
#     total 81920 MiB, free 77826 MiB -> gap 4094 MiB
#   tolerance in the host profile: 3500 MiB
#   -> refused by 594 MiB, and the refusal names no remedy that can help, because the
#      holder is the lane the same script is told to keep.
#
# The existing suite could not catch this: `08-autotune-workload.bats` sets
# LLM_AUTOTUNE_BASELINE_GAP_MAX=999999 to bypass the guard, so every case in it runs
# with the guard switched OFF.  An allow arm is not a test of the bound.  This file is
# the refusal-side arm: it pins the shipped value against the measured footprint.
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
PROFILE="$REPO_ROOT/config/hosts.d/asus-n1n-rtx-spark.conf"

# The measured gap on this box with the spared embedding lane the only holder.
# A pin, not a derivation: nvidia-smi reports used_gpu_memory as [N/A] per PID on
# WSL2 dxgkrnl, so the lane's own footprint cannot be read individually — it can
# only be observed as the whole-card delta while it is alone.
SPARED_LANE_FOOTPRINT_MIB=4094

@test "the host profile records the conflict instead of numbing the guard" {
    [ -f "$PROFILE" ]
    run bash -c "source '$PROFILE' >/dev/null 2>&1; printf '%s' \"\${LLM_AUTOTUNE_BASELINE_GAP_MAX:-}\""
    [ "$status" -eq 0 ]
    local tol="$output"
    [ -n "$tol" ]
    # NOT an assertion that the tolerance covers the lane.  Covering it would accept
    # contended measurements, which is the defect the guard exists to prevent.  This
    # pins the OPEN state so nobody quietly raises the number to make a batch pass
    # without recording why: if the value moves above the measured footprint, the
    # unresolved-trade-off note must have moved with it.
    if [ "$tol" -ge "$SPARED_LANE_FOOTPRINT_MIB" ]; then
        run grep -c "KNOWN CONFLICT, 2026-11-02" "$PROFILE"
        [ "$output" -ge 1 ]
    fi
}

@test "the tolerance is still a bound, not a bypass" {
    # A concurrent serving lane holds multiples of the spared lane, and that is what
    # the bound exists to catch.  This control must pass before and after any fix.
    run bash -c "source '$PROFILE' >/dev/null 2>&1; printf '%s' \"\${LLM_AUTOTUNE_BASELINE_GAP_MAX:-}\""
    local tol="$output"
    if [ "$tol" -gt 16384 ]; then
        printf 'LLM_AUTOTUNE_BASELINE_GAP_MAX=%s no longer distinguishes a spared lane from a full card\n' "$tol" >&2
        return 1
    fi
}

@test "the guard's own default is documented as the driver bound, not a lane bound" {
    # scripts/autotune-model.sh defaults to 800 for boxes with no CUDA lane at all.
    # The comment there used to justify it with a "~430 MiB memory-core embedding
    # worker" — a Node worker this box does not run and which the guard's pkill
    # already removes.  The real holder is a CUDA llama-server 5x the tolerance.
    #
    # The assertion is POSITIVE: name the measurement that sized the profile value.
    # An absence check (grep -c "430 MiB" == 0) would also fail on a comment that
    # QUOTES the old figure to explain why it was wrong — which is what the fix does.
    # A test that forbids a string forbids the correction that mentions it.
    run grep -c "4094 MiB" "$REPO_ROOT/scripts/autotune-model.sh"
    [ "$output" -ge 1 ]
}

@test "the stale 2026-08-28 sizing note is gone from the guard" {
    run grep -c "on this box, 2026-08-28" "$REPO_ROOT/scripts/autotune-model.sh"
    [ "$output" -eq 0 ]
}
