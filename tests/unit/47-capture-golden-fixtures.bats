#!/usr/bin/env bats
# ==============================================================================
# Unit — tools/capture-golden-fixtures.sh: a failed capture is not "complete"
# ==============================================================================
# Card 90eee0c2 (AUDIT-2026-10-02): capture() printed `<name> (rc=N)` per command
# and the script then printed an unconditional "Fixture capture complete." and
# exited 0 however many captures had failed — a success message with nothing behind
# it.  These cases drive the SHIPPED script in a sandbox whose bin/tac-exec exits
# non-zero (or zero): the script derives REPO_ROOT from its own location, so
# copying it under $SANDBOX/tools makes the sandbox's bin/tac-exec the one it runs
# and keeps the real box's commands (and the live profile) out of the test.
#
# The expected tally is not read off the script: it comes from the card's
# acceptance — a failed capture must be NAMED and the run must exit non-zero.
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
SCRIPT="$REPO_ROOT/tools/capture-golden-fixtures.sh"

# _sandbox <exit-code> — a throwaway repo root whose bin/tac-exec exits <exit-code>.
_sandbox() {
    local rc="$1" root="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$root/tools" "$root/bin"
    cp "$SCRIPT" "$root/tools/capture-golden-fixtures.sh"
    cat > "$root/bin/tac-exec" <<SH
#!/usr/bin/env bash
echo "stub tac-exec"
exit $rc
SH
    chmod +x "$root/bin/tac-exec"
    printf '%s\n' "$root"
}

@test "capture-golden-fixtures: a failing capture is named and the run exits non-zero" {
    local root
    root="$(_sandbox 7)"
    run "$root/tools/capture-golden-fixtures.sh" --out "$root/out"

    [[ "$status" -ne 0 ]] || { echo "a run whose every capture failed exited 0"; return 1; }
    [[ "$output" == *"captured: help_h (rc=7) FAILED"* ]] \
        || { echo "the per-command line does not mark the failure: $output"; return 1; }
    # The tally is honest: every one of the seven captures failed.
    [[ "$output" == *"0/7 captured, 7 FAILED"* ]] \
        || { echo "the run does not name the failure count: $output"; return 1; }
}

@test "capture-golden-fixtures: a clean capture exits 0 and reports zero failures" {
    local root
    root="$(_sandbox 0)"
    run "$root/tools/capture-golden-fixtures.sh" --out "$root/out"

    [[ "$status" -eq 0 ]] || { echo "a clean capture exited $status"; return 1; }
    [[ "$output" == *"7/7 captured, 0 FAILED"* ]] \
        || { echo "the clean run's tally is wrong: $output"; return 1; }
    [[ "$output" != *"FAILED (see above)"* ]]
}

# Exit 5 is `oc health`'s STALLED code — the listener is bound and dark past the
# post-bind grace, and the action is ALERT, NEVER RESTART (Wayne, 2026-10-07;
# scripts/oc-health-check.py::EXIT_BY_SUMMARY).  A capture taken on such a box is
# FAITHFUL, so counting it as a failure reddened the run for a probe that worked.  The
# expected values here come from that contract, not from the script's behaviour: a stall
# is captured and NAMED, the tally stays at zero failures, and the run exits 0 — while
# `rc 1` (and every other non-zero code) stays a failure, pinned by the first case.
@test "capture-golden-fixtures: rc 5 is a captured-but-STALLED fixture, not a failure" {
    local root
    root="$(_sandbox 5)"
    run "$root/tools/capture-golden-fixtures.sh" --out "$root/out"

    [[ "$status" -eq 0 ]] || { echo "a stalled capture exited $status"; return 1; }
    [[ "$output" == *"captured: help_h (rc=5) STALLED"* ]] \
        || { echo "the per-command line does not name the stall: $output"; return 1; }
    [[ "$output" == *"7/7 captured, 0 FAILED; 7 STALLED"* ]] \
        || { echo "the tally does not report the stalls separately from failures: $output"; return 1; }
    [[ "$output" != *"(see above)"* ]] \
        || { echo "the run printed the failure summary for a stall: $output"; return 1; }
    # The fixture format carries the state without being forced: the meta keeps the raw
    # code, so a consumer can tell a stall (5) from a failure (1) from the file itself.
    [[ "$(cat "$root/out/help_h.meta")" == *"exit_code: 5"* ]] \
        || { echo "the meta does not record the stall's exit code"; return 1; }
}
