#!/usr/bin/env bats
# ==============================================================================
# Unit — count-ratchet --update must not delete hand-added baseline provenance
# ==============================================================================
# WHY THIS EXISTS (card fc4d3e29, AUDIT-2026-10-02): tools/ratchet-baseline.tsv
# legitimately carries hand-written `#` provenance — WHY a count was re-baselined —
# and read_baseline has always ignored comment lines. But write_baseline opened the
# file with mode "w" and wrote only a two-line header plus one row per counter, so
# every `--update` DELETED those notes. The file's own comments record the loss more
# than once ("Restored by hand after `--update`: the tool rewrites the file without
# comments."). The fix carries non-header comment lines through the rewrite.
#
# The fixture is a throwaway git repo (the counters read `git ls-files`) with a copy
# of the tool and a baseline the test controls; the real repo file is never touched.
#
# FALSIFICATION (2026-10-02): against the pre-fix tool the first case fails — the
# hand-added note is gone after `--update` (grep counts 0).
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export REPO_ROOT
    SANDBOX="$(mktemp -d)"
    export SANDBOX
    mkdir -p "$SANDBOX/tools"
    TOOL="$SANDBOX/tools/count-ratchet.sh"
    export TOOL
    cp "$REPO_ROOT/tools/count-ratchet.sh" "$TOOL"
    BASELINE="$SANDBOX/tools/ratchet-baseline.tsv"
    export BASELINE

    # A minimal tracked shell corpus, so `git ls-files` returns a file to count.
    printf '#!/usr/bin/env bash\n' > "$SANDBOX/tracked.sh"
    git -C "$SANDBOX" init --quiet
    git -C "$SANDBOX" add tracked.sh
}

teardown() {
    rm -rf "$SANDBOX"
}

_fixture_with_note() {
    printf '# HAND-ADDED PROVENANCE: re-baselined 2026-10-02 for a measured reason (card fc4d3e29).\n4.2.4\t0\n' > "$BASELINE"
}

_fixture_plain() {
    printf '4.2.4\t0\n' > "$BASELINE"
}

@test "count-ratchet --update preserves a hand-added provenance comment" {
    _fixture_with_note

    run "$TOOL" --update

    [ "$status" -eq 0 ]
    run grep -c "HAND-ADDED PROVENANCE" "$BASELINE"
    [ "$output" = "1" ]
    # ...and the rows are still regenerated.
    run grep -c "^10.7" "$BASELINE"
    [ "$output" = "1" ]
}

@test "count-ratchet --update writes the generated header and every counter row" {
    _fixture_plain

    run "$TOOL" --update

    [ "$status" -eq 0 ]
    run grep -c "^# " "$BASELINE"
    [ "$output" = "2" ]
    run grep -c $'^[0-9]' "$BASELINE"
    [ "$output" = "9" ]
}

@test "count-ratchet --update is idempotent for a preserved comment" {
    _fixture_with_note

    run "$TOOL" --update
    [ "$status" -eq 0 ]
    run "$TOOL" --update
    [ "$status" -eq 0 ]

    # A second run must not duplicate the note (each comment appears once).
    run grep -c "HAND-ADDED PROVENANCE" "$BASELINE"
    [ "$output" = "1" ]
}

# end of file
