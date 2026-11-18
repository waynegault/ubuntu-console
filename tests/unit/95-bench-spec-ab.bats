#!/usr/bin/env bats
# ==============================================================================
# Unit Tests — bench-spec-ab.sh argument resolution (BENCH-SPEC-AB-001)
# ==============================================================================
# bench-spec-ab.sh measures a lane's OWN argv twice, once with a speculative flag and
# once without.  Two properties decide whether that measurement means anything, and
# both are testable with no card and no systemd:
#
#   1. The argv comes from the UNIT (so the bench measures what the lane runs).  The
#      seam is BENCH_SPEC_AB_UNIT_TEXT, a file read instead of `systemctl --user cat`.
#   2. The BASELINE ARM CARRIES NO SPEC FLAG.  This is not hypothetical: the first
#      --print-plan run on 2026-11-18 printed --spec-type on BOTH arms, because the
#      lane's own drop-in had just enabled it.  Both arms would have been the same
#      experiment, and the run would have "measured" a zero difference.  A planner
#      that cannot separate its arms is the whole defect class this suite exists for.
#
# The refusal case points LLAMA_WATCHDOG_CUDA_SUSPEND_FILE at a temp file so a held
# marker cannot suspend the box's real CUDA lane for the length of a test run.
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
SCRIPT="$REPO_ROOT/bin/bench-spec-ab.sh"
TMPDIR_BATS="$(mktemp -d)"

# A unit whose ExecStart already carries the flag, exactly as 61-ngram-mod.conf made
# this box's lane look — plus a %h that must be expanded and a port that must move.
FAKE_UNIT="$TMPDIR_BATS/fake.service"
cat > "$FAKE_UNIT" <<'UNIT'
[Service]
ExecStart=%h/.local/bin/llama-cuda-server -m /models/x.gguf --port 18087 --host 127.0.0.1 --ctx-size 131072 --batch-size 2048 --parallel 4 --spec-type ngram-mod
UNIT

setup() {
    export BENCH_SPEC_AB_UNIT_TEXT="$FAKE_UNIT"
    export LLAMA_WATCHDOG_CUDA_SUSPEND_FILE="$TMPDIR_BATS/suspend.marker"
}

teardown() {
    rm -rf "$TMPDIR_BATS"
}

# plan <arm> — the printed arm's argv, with the log path dropped so the assertion is
# about flags and the window, not about a timestamped filename.
plan() {
    local _line
    _line="$(bash "$SCRIPT" --print-plan --set agentic 2>/dev/null | grep "^$1:" | sed 's/^[a-z]*: *//')"
    printf '%s\n' "${_line%% --log-file*}"
}

@test "the argv is read from the unit, with %h expanded and the port moved" {
    run plan baseline
    [ "$status" -eq 0 ]
    # The window the lane actually serves comes through unchanged...
    [[ "$output" == *"--ctx-size 131072"* ]]
    [[ "$output" == *"--batch-size 2048"* ]]
    [[ "$output" == *"--parallel 4"* ]]
    # ...%h is expanded, and the bench port is NOT the lane's own (a bind on 18087
    # would collide with the unit the EXIT trap restarts).
    [[ "$output" == *"$HOME/.local/bin/llama-cuda-server"* ]]
    [[ "$output" == *"--port 18090"* ]]
    [[ "$output" != *"--port 18087"* ]]
}

@test "the baseline arm strips the unit's own spec flag; the spec arm carries exactly one" {
    run plan baseline
    [ "$status" -eq 0 ]
    [[ "$output" != *"--spec-type"* ]]

    run plan spec
    [ "$status" -eq 0 ]
    [[ "$output" == *"--spec-type ngram-mod"* ]]
    # Exactly one: a second copy would mean the strip missed the unit's token.
    local _count
    _count="$(grep -o -- '--spec-type' <<< "$output" | wc -l | tr -d ' ')"
    [ "$_count" -eq 1 ]
}

@test "a held suspend marker refuses the run instead of measuring" {
    printf '%s\n' "$$" > "$LLAMA_WATCHDOG_CUDA_SUSPEND_FILE"
    run bash "$SCRIPT" --set agentic --reps 1
    rm -f "$LLAMA_WATCHDOG_CUDA_SUSPEND_FILE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"REFUSING"* ]]
}
