#!/usr/bin/env bats
# ==============================================================================
# Unit — a DIRECT autotune run asks the quiet-fleet gate
# ==============================================================================
# WHY (2026-11-03): the gate only ever guarded the boot/resume path, so a hand-started
# `bin/autotune-rows.sh <row>` reached the card ungated — measured that day at 22:07, a
# sweep launched from a live shell while an agent turn was running. A turn and a
# measurement contend for the same CPU, so the tps measured beside one describes the
# contention rather than the model.
#
# Hermetic: AUTOTUNE_QUIET_GATE points at a gate this test owns, and HEAVY_JOB_HELD=1 keeps
# the box-wide lock out of it (the script reads the variable as "our parent holds it").
# Every case refuses BEFORE the lane is touched; no case lets a run reach the GPU.
setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    ENTRY="$REPO_ROOT/bin/autotune-rows.sh"
    GATE="$BATS_TEST_TMPDIR/gate"
    export HEAVY_JOB_HELD=1
    export AUTOTUNE_QUIET_GATE="$GATE"
    unset AUTOTUNE_QUIET_GATE_PASSED
}

make_gate() { printf '#!/bin/sh\nexit %s\n' "$1" > "$GATE"; chmod +x "$GATE"; }

@test "gate: a busy fleet REFUSES the run" {
    make_gate 1
    run "$ENTRY" some-model.gguf
    [ "$status" -eq 1 ]
    [[ "$output" == *"REFUSING"* ]]
    [[ "$output" == *"--force-live-fleet"* ]]
}

@test "gate: an unanswerable probe (exit 2) refuses too — fail closed" {
    make_gate 2
    run "$ENTRY" some-model.gguf
    [ "$status" -eq 1 ]
    [[ "$output" == *"rc=2"* ]]
}

@test "gate: --force-live-fleet is consumed as a flag, never as a model file" {
    make_gate 1
    run "$ENTRY" --force-live-fleet
    [ "$status" -eq 2 ]
    [[ "$output" == *"usage:"* ]]
}

@test "gate: the resume loop marks its own pass so the gate is asked once" {
    run grep -F 'AUTOTUNE_QUIET_GATE_PASSED=1 "$ENTRY"' "$REPO_ROOT/bin/autotune-resume.sh"
    [ "$status" -eq 0 ]
}

# WHY (2026-11-17): the suspend hold and the clean-room restore are released by ONE
# `trap ... EXIT` (line ~348).  A second `trap ... EXIT` REPLACES it rather than chaining,
# so any later `trap '...' EXIT` in this wrapper silently drops the release — the CUDA card
# stays marked held and every clean-room tenant stays stopped.  Measured while v27 added a
# heartbeat with `trap 'kill "$_HEARTBEAT_PID"' EXIT`: the two traps cannot coexist, and
# `bash -n` is clean, so nothing static catches it.
#
# A helper-level case cannot see this: suite 93 exercises _tac_suspend_acquire/release
# directly, which stays green while the CALLER's trap is gone.  So this drives the real
# entry point and asserts the observable — a marker the release seams write.  The lib is
# loaded by `realpath "$BASH_SOURCE"/../_tac-bin-lib.sh` (line ~125), so a COPY of the tree
# with those two functions replaced is the seam: no new override variable is introduced
# just for a test.
@test "trap: the EXIT path releases the hold and restores the clean-room" {
    local root="$BATS_TEST_TMPDIR/tree" marker="$BATS_TEST_TMPDIR/released"
    mkdir -p "$root/bin"
    cp "$ENTRY" "$root/bin/autotune-rows.sh"
    cp "$REPO_ROOT/bin/_tac-bin-lib.sh" "$root/bin/_tac-bin-lib.sh"
    # The baseline probe is REFUSED so the run aborts at the `_baseline_rc != 0` exit (1),
    # which is BEFORE the batch is launched.  Nothing here may reach the GPU or a lane:
    # measured 2026-11-17, an earlier draft of this case let the real batch run against the
    # live card and started a row.  LLM_STATE_DIR keeps the log out of the real log tree.
    cat >> "$root/bin/_tac-bin-lib.sh" <<EOF

# Overridable seams for tests/unit/68: record that the release ran.
_tac_suspend_release() { printf 'release %s\n' "\$1" >> "$marker"; return 0; }
_tac_cleanroom_restore() { printf 'restore\n' >> "$marker"; return 0; }
_tac_cleanroom_enter() { return 0; }
_tac_gpu_wait_baseline() { printf 'reason=test-refused\n'; return 1; }
_tac_gpu_used_mib() { return 0; }
_tac_adapter_health_check() { return 0; }
EOF
    chmod +x "$root/bin/autotune-rows.sh"
    printf '#!/bin/sh\nexit 0\n' > "$BATS_TEST_TMPDIR/gate-ok"
    chmod +x "$BATS_TEST_TMPDIR/gate-ok"

    # Measured 2026-11-17: this case leaves ONE log file in the profile's own log dir,
    # because tac_host_profile_apply UNSETS LLM_STATE_DIR and the profile reassigns it, so
    # no env var can redirect it (the same trap as suite 85's census).  The dir is resolved
    # from the profile rather than hardcoded, and the file is removed afterwards so repeated
    # runs do not accumulate.
    local _logdir _before _after
    _logdir="$(bash -c 'source '"$REPO_ROOT"'/tools/host-profile.sh 2>/dev/null; tac_host_profile_apply 2>/dev/null; printf %s "${LLM_STATE_DIR:-$HOME/.llm}"' 2>/dev/null)/autotune-logs"
    _before=$(ls -t "$_logdir" 2>/dev/null | head -1)

    run env REPO="$REPO_ROOT" HEAVY_JOB_HELD=1 AUTOTUNE_QUIET_GATE="$BATS_TEST_TMPDIR/gate-ok" \
        CUDA_CYCLE_FILE="$BATS_TEST_TMPDIR/ledger" \
        LLAMA_WATCHDOG_CUDA_SUSPEND_FILE="$BATS_TEST_TMPDIR/suspend" \
        "$root/bin/autotune-rows.sh" some-model.gguf

    _after=$(ls -t "$_logdir" 2>/dev/null | head -1)
    if [ -n "$_after" ] && [ "$_after" != "$_before" ] && [ -f "$_logdir/$_after" ]; then
        rm -f "$_logdir/$_after"
    fi

    # The run must have ended on the baseline abort, never on a launched batch.
    [ "$status" -eq 1 ] || {
        echo "expected the baseline abort (exit 1), got status=$status"
        echo "output=$output"
        return 1
    }
    [[ "$output" == *"VRAM baseline is not clear"* ]] || {
        echo "the baseline abort did not run; output=$output"
        return 1
    }
    [ -f "$marker" ] || {
        echo "the EXIT trap ran neither release function (marker absent)"
        return 1
    }
    grep -q '^restore$' "$marker" || {
        echo "_tac_cleanroom_restore never ran on exit; marker was: $(cat "$marker")"
        return 1
    }
}

# The guard for the SHAPE, and the one that names the offender.  A second `trap ... EXIT`
# replaces the first, so the release and any helper cleanup cannot both be EXIT handlers.
# The handler may either spell the release inline or call a function that does it, so the
# check follows ONE level of indirection rather than pinning a literal — the case must
# survive a refactor into a function (it caught exactly that on 2026-11-17) while still
# refusing a trap that has lost the release.
@test "trap: exactly one EXIT handler is installed, and it reaches the release" {
    local traps
    traps=$(grep -nE "^[[:space:]]*trap .* EXIT" "$ENTRY")
    [ "$(printf '%s\n' "$traps" | grep -c .)" -eq 1 ] || {
        echo "a second 'trap ... EXIT' REPLACES the first and drops the hold release:"
        printf '%s\n' "$traps"
        return 1
    }
    # The handler body: the release either sits in the trap string, or in the function it
    # names.  Resolve the function name out of the trap and grep that function's body too.
    local body="$traps" callee
    callee=$(printf '%s\n' "$traps" | grep -oE "'_?[a-z_]+'" | tr -d "'" | head -1)
    if [ -n "$callee" ] && grep -qE "^[[:space:]]*${callee}\(\)" "$ENTRY"; then
        body="$body
$(awk -v f="$callee" '$0 ~ "^[[:space:]]*"f"\\(\\)" {on=1} on {print} on && /^}/ && NR>1 {exit}' "$ENTRY")"
    fi
    printf '%s\n' "$body" | grep -q '_tac_suspend_release' || {
        echo "the single EXIT trap (and its callee, if any) does not release the suspend hold:"
        printf '%s\n' "$traps"
        return 1
    }
    # A bare `trap - EXIT` would clear the release for the rest of the script.
    ! grep -qE "^[[:space:]]*trap - EXIT" "$ENTRY" || {
        echo "a bare 'trap - EXIT' clears the release trap:"
        grep -nE "^[[:space:]]*trap - EXIT" "$ENTRY"
        return 1
    }
}
