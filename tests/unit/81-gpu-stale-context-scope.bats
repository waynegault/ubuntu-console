#!/usr/bin/env bats
# ==============================================================================
# Unit — the stale-CUDA python sweep must not kill another job's process
# ==============================================================================
# Measured 2026-11-06, 00:55: a `model bench` printed "VRAM killed 1 stale GPU
# process(es)" for a python process holding a CUDA context while another agent's
# pipeline was running in the transient unit `vexed-uphold-full.service`.  The
# sweep was a pure name test — any python in the compute-apps list that was not
# llama-server — so it could take a live foreign run's process mid-case.
#
# The rule is now explicit and pure: __gpu_stale_context_verdict refuses a
# process that a systemd unit owns (whatever the unit is), and one younger than
# LLM_GPU_STALE_MIN_AGE_S.  What is left is a leftover nobody owns, which is the
# only thing this cleanup was ever for.
#
# Hermetic: the verdict takes comm/unit/age as arguments, so no card, no kill and
# no systemd unit is involved.  One wiring case reads the sweep's own text,
# because a helper nobody calls would satisfy every arm below and change nothing.
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
MODULE="$REPO_ROOT/scripts/11d-llm-gpu.sh"

setup() {
    source "$REPO_ROOT/scripts/01-constants.sh"
    source "$REPO_ROOT/scripts/11d-llm-gpu.sh"
    # A missing verdict function answers rc 127, and every "is refused" arm below
    # reads that as a refusal — the cases would pass against a module with no rule
    # at all.  Fail on that FIRST (measured: this file's own falsifier run).
    declare -F __gpu_stale_context_verdict >/dev/null
}

@test "sweep: a python process inside a named unit is never a candidate" {
    # Catches: the 00:55 kill.  The unit is the ownership signal — it does not
    # matter whether it is a lane, CI or another agent's transient run.
    run __gpu_stale_context_verdict python3 vexed-uphold-full.service 86400
    [ "$status" -ne 0 ]
    run __gpu_stale_context_verdict python3 llama-cuda-qwen3coder-30b-chat.service 86400
    [ "$status" -ne 0 ]
}

@test "sweep: an old unowned python context is still reaped" {
    # Catches: a fix that stopped killing anything at all, leaving the VRAM leak
    # this helper exists for (an orphaned context survives a crashed run).
    run __gpu_stale_context_verdict python3 "" 900
    [ "$status" -eq 0 ]
}

@test "sweep: an unowned context younger than the age bound is left alone" {
    # Catches: killing the process a run has just launched — its parent may already
    # have exec'd away, so ownership alone is not the whole test.
    run __gpu_stale_context_verdict python3 "" 30
    [ "$status" -ne 0 ]
    # the bound is profile/configurable, and moving it must move the verdict
    export LLM_GPU_STALE_MIN_AGE_S=10
    run __gpu_stale_context_verdict python3 "" 30
    [ "$status" -eq 0 ]
}

@test "sweep: an unreadable age is not a licence to kill" {
    # Catches: an empty `ps -o etimes` (the process exited mid-read) passing a
    # numeric-looking `(( ))` zero-test and authorising a kill.
    run __gpu_stale_context_verdict python3 "" ""
    [ "$status" -ne 0 ]
    run __gpu_stale_context_verdict python3 "" "N/A"
    [ "$status" -ne 0 ]
}

@test "sweep: a llama-server is never reaped by this path" {
    # Catches: a name sweep taking a lane or a `model use` server, which their own
    # helpers own.
    run __gpu_stale_context_verdict llama-server "" 86400
    [ "$status" -ne 0 ]
    run __gpu_stale_context_verdict llama-server llama-cuda-qwen3coder-30b-chat.service 86400
    [ "$status" -ne 0 ]
}

@test "sweep: the kill path consults the verdict, with the unit and the age read" {
    # Catches: the helper landing but the loop still killing on a bare name test —
    # every case above would stay green.
    local body
    body=$(sed -n '/^function __gpu_clear_stale_processes/,/^}/p' "$MODULE")
    [[ "$body" == *"__gpu_stale_context_verdict"* ]]
    [[ "$body" == *"ps -o cgroup="* ]]
    [[ "$body" == *"ps -o etimes="* ]]
    # and the old bare-name kill is gone
    [[ "$body" != *'if [[ "$_gpu_cmd" == python* ]]'* ]]
}
