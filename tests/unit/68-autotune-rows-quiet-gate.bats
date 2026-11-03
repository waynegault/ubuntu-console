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
