#!/usr/bin/env bats
# ==============================================================================
# Unit — a hold taken by our own parent is OURS, not "another run"
# ==============================================================================
# WHY (2026-11-03): scripts/autotune-model.sh runs INSIDE bin/autotune-rows.sh, which takes
# the CUDA-lane hold for the WHOLE sweep. The row script cannot acquire it (correctly) and
# used to print "held by another run ... the watchdog may restart the CUDA lane mid-run" on
# every row — naming the parent that is deliberately keeping the lane down as a foreign
# threat to the measurement it is running.
#
# _tac_suspend_owner_is_ancestor is the seam: the SAME hold is ours through the parent, and
# only a holder outside our own process tree earns a warning.
setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    MARK="$BATS_TEST_TMPDIR/llama-watchdog-cuda.suspend"
}

@test "ancestor: a hold carrying the parent pid reads as OUR hold" {
    printf '%s\n' "$$" > "$MARK"
    run bash -c "source '$REPO_ROOT/bin/_tac-bin-lib.sh'; _tac_suspend_owner_is_ancestor '$MARK'"
    [ "$status" -eq 0 ]
}

@test "ancestor: a hold carrying an unrelated live pid does NOT read as ours" {
    sleep 30 &
    holder=$!
    printf '%s\n' "$holder" > "$MARK"
    run bash -c "source '$REPO_ROOT/bin/_tac-bin-lib.sh'; _tac_suspend_owner_is_ancestor '$MARK'"
    kill "$holder" 2>/dev/null || true
    [ "$status" -eq 1 ]
}

@test "ancestor: no marker is not an ancestor claim, and does not crash" {
    run bash -c "source '$REPO_ROOT/bin/_tac-bin-lib.sh'; _tac_suspend_owner_is_ancestor '$MARK'"
    [ "$status" -eq 1 ]
}

@test "ancestor: the row runner reports the ancestor case and still warns for a stranger" {
    run grep -F 'already held by ancestor pid' "$REPO_ROOT/scripts/autotune-model.sh"
    [ "$status" -eq 0 ]
    run grep -F 'held by another run' "$REPO_ROOT/scripts/autotune-model.sh"
    [ "$status" -eq 0 ]
}
