#!/usr/bin/env bats
# ==============================================================================
# Unit — kgraph hooks: a FAILED rebuild must be reported by BOTH hooks
# ==============================================================================
# WHY THIS EXISTS (card a6ead879, AUDIT-2026-10-02): tools/hooks/post-commit and
# tools/hooks/post-merge carried near-duplicate rebuild bodies, and only post-commit
# reported the outcome.  post-merge ran `... 2>&1 | sed ...` and dropped the exit
# status, so a merge that broke the graph rebuild was SILENT and the stale graph was
# then queried.  The fix moves the body into tools/hooks/_kgraph-auto-rebuild, which
# both hooks source, so the report cannot drift between them again.
#
# These cases assert the PROPERTY a user reads — the warning about a failed rebuild —
# by running the SHIPPED hook files against a throwaway repo whose kgraph update FAILS.
#
# FALSIFICATION (2026-10-02): against the pre-fix tree the post-merge case fails — the
# hook prints the sed-filtered update output and no "graph update exited" warning.
#
# HERMETIC: a throwaway git repo with a stub .venv/bin/python3. No network, no real
# kgraph, and no path into the live repo's own graph.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export REPO_ROOT
    SANDBOX="$(mktemp -d)"
    export SANDBOX
}

teardown() {
    cd /
    rm -rf "$SANDBOX"
}

# _make_failing_repo <repo> — a throwaway repo whose kgraph update FAILS, carrying
# copies of the shipped hook files so the REAL code paths run.
_make_failing_repo() {
    local repo="$1"
    mkdir -p "$repo/tools/hooks" "$repo/.venv/bin"
    git -C "$repo" init --quiet
    # The import probe (`-c 'import kgraph'`) must succeed so the hook takes the
    # local-module branch; the actual update (`-m kgraph ...`) must FAIL.
    cat > "$repo/.venv/bin/python3" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "-c" ]]; then exit 0; fi
echo "stub: kgraph update blew up"
exit 1
STUB
    chmod +x "$repo/.venv/bin/python3"
    cp "$REPO_ROOT/tools/hooks/_kgraph-auto-rebuild" "$repo/tools/hooks/"
    cp "$REPO_ROOT/tools/hooks/post-commit" "$repo/tools/hooks/"
    cp "$REPO_ROOT/tools/hooks/post-merge" "$repo/tools/hooks/"
}

@test "kgraph hooks: BOTH hooks source the one shared rebuild body" {
    local h
    for h in post-commit post-merge; do
        grep -q '_kgraph-auto-rebuild' "$REPO_ROOT/tools/hooks/$h" || {
            echo "$h does not source the shared helper"
            return 1
        }
        grep -q '_kgraph_auto_rebuild ' "$REPO_ROOT/tools/hooks/$h" || {
            echo "$h does not call the shared helper"
            return 1
        }
    done
}

@test "kgraph hooks: post-merge reports a FAILED rebuild (was silent before)" {
    _make_failing_repo "$SANDBOX/merge"
    run bash -c "cd '$SANDBOX/merge' && bash tools/hooks/post-merge"
    [[ "$output" == *"the graph update exited 1"* ]]
    [[ "$output" == *"the graph may be stale"* ]]
}

@test "kgraph hooks: post-commit reports a FAILED rebuild" {
    _make_failing_repo "$SANDBOX/commit"
    run bash -c "cd '$SANDBOX/commit' && bash tools/hooks/post-commit"
    [[ "$output" == *"the graph update exited 1"* ]]
}

@test "kgraph hooks: a failed rebuild is REPORTED, never fatal (both hooks exit 0)" {
    _make_failing_repo "$SANDBOX/rc"
    run bash -c "cd '$SANDBOX/rc' && bash tools/hooks/post-merge; echo MERGE_RC=\$?"
    [[ "$output" == *"MERGE_RC=0"* ]]
    run bash -c "cd '$SANDBOX/rc' && bash tools/hooks/post-commit; echo COMMIT_RC=\$?"
    [[ "$output" == *"COMMIT_RC=0"* ]]
}
