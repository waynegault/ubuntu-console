#!/usr/bin/env bats
# ==============================================================================
# Unit — oc-restart-check's exit code is a closed three-way enumeration
# ==============================================================================
# Contract entry `oc-restart-check` (docs/contracts/command-contracts.yaml) publishes a
# `disposition: decision` with a bound: exit_code 0 safe / 1 not safe / 2 could not measure,
# "a closed three-way enumeration, so no other result is valid".  That entry had no
# `verified_by:` node — tests/test_oc_restart_check.py covers the probe's DECISION logic, but
# it is a pytest file and `verified_by:` requires a BATS `@test` node.
#
# WHAT THIS NODE ADDS: the pytest file monkeypatches the probes, so it never exercises the
# command's own wiring.  This node runs the exported command end to end (`bin/tac-exec`, the
# documented non-interactive entry point) and pins the criterion the entry states: exactly one
# of the three codes comes back, with a verdict on stdout.  It can disagree — a fourth code, a
# broken dispatch, or an empty report all fail it.
#
# The probe is READ-ONLY (effect: read) and its verdict depends on live state, so the exit
# code is asserted to be a MEMBER of the set, never a fixed value.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
}

@test "oc-restart-check: exit codes are the closed three-way enumeration (0 safe, 1 not safe, 2 could not measure)" {
    run "$REPO_ROOT/bin/tac-exec" oc-restart-check
    case "$status" in
        0 | 1 | 2) : ;;
        *)
            echo "oc-restart-check exited $status, outside the closed enumeration {0,1,2}"
            echo "output: $output"
            return 1
            ;;
    esac
    # ...and a verdict really came back: an exit code alone is not the report the entry promises.
    [[ "$output" == *restart* ]]
}

# end of file
