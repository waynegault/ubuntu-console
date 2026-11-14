#!/usr/bin/env bats
# ==============================================================================
# Unit — bin/git-commit: `--only` commits with a message file, in git's one valid order
# ==============================================================================
# WHY (measured 2026-11-12, ubuntu-console, commit d71c3dad): three consecutive attempts
# to commit another lane's change-set with `-o` and a message file failed, and neither
# failure named the argument order:
#
#   git commit -o -- <paths> -m "<multi-line body>"
#     -> the body is consumed as a PATHSET: "pathspec '<body>' did not match any file(s)"
#   git commit -o -- <paths> -F <file>
#     -> "-F" and <file> are pathspecs too, because git stops option parsing at `--`
#
# The trap is git's parsing, not the caller's care, so the fix is a wrapper that owns the
# order.  These cases pin the ORDER (the argv git receives) rather than only the outcome:
# a commit that succeeded by luck of argument position would still be wrong tomorrow.
#
# HERMETIC: a throwaway git repo per case, and a `git` stub on PATH that records its argv
# and exits 0 — so no case runs the real commit pipeline, the real hooks, or touches this
# repo's index.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    SRC="$REPO_ROOT/bin/git-commit"
    WORK="$BATS_TEST_TMPDIR"
    STUB="$WORK/stub"
    mkdir -p "$STUB"
    ARGV_LOG="$WORK/git-argv"
    export ARGV_LOG
    cat > "$STUB/git" <<'STUBGIT'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ARGV_LOG"
exit "${STUB_GIT_RC:-0}"
STUBGIT
    chmod +x "$STUB/git"
    PATH="$STUB:$PATH"
    export PATH
    MSG="$WORK/msg.txt"
    printf 'subject line\n\nbody line\n' > "$MSG"
    export MSG
}

# argv — the single line of arguments the git stub received.
argv() { cat "$ARGV_LOG"; }

@test "git-commit: the documented form forwards -F BEFORE -- and the paths after it" {
    # The whole point.  A wrapper that passed `-- paths -F file` would reproduce the bug
    # it exists to prevent; this asserts the exact sequence, not merely success.
    run "$SRC" -F "$MSG" -- path/one path/two
    [ "$status" -eq 0 ]
    [ "$(argv)" = "commit -o -F $MSG -- path/one path/two" ]
}

@test "git-commit: the bare form (no --) is accepted and still emits the correct order" {
    # Callers should not have to remember `--`; the wrapper adds it in the right place.
    run "$SRC" -F "$MSG" path/one
    [ "$status" -eq 0 ]
    [ "$(argv)" = "commit -o -F $MSG -- path/one" ]
}

@test "git-commit: --file= is accepted as the long spelling" {
    run "$SRC" --file="$MSG" path/one
    [ "$status" -eq 0 ]
    [ "$(argv)" = "commit -o -F $MSG -- path/one" ]
}

@test "git-commit: no message file is EX_USAGE, and git is never invoked" {
    # Catches: falling through to a bare `git commit`, which publishes the WHOLE index —
    # including another lane's staging in a shared tree.
    run "$SRC" path/one
    [ "$status" -eq 64 ]
    [[ "$output" == *"message file is required"* ]]
    [ ! -f "$ARGV_LOG" ]
}

@test "git-commit: no paths is EX_USAGE, and git is never invoked" {
    # The same hazard from the other side: `--only` with nothing to commit would either
    # fail or, worse, commit the index.
    run "$SRC" -F "$MSG"
    [ "$status" -eq 64 ]
    [[ "$output" == *"no paths given"* ]]
    [ ! -f "$ARGV_LOG" ]
}

@test "git-commit: an empty message file is refused before git runs" {
    # Catches the measured 2026-11-03 shape: an empty message lets every pre-commit gate
    # run and pass, and only then does git abort — minutes spent, nothing committed.
    : > "$MSG"
    run "$SRC" -F "$MSG" path/one
    [ "$status" -eq 1 ]
    [[ "$output" == *"empty"* ]]
    [ ! -f "$ARGV_LOG" ]
}

@test "git-commit: a missing message file is refused, naming the path" {
    run "$SRC" -F "$WORK/absent.txt" path/one
    [ "$status" -eq 1 ]
    [[ "$output" == *"absent.txt"* ]]
    [ ! -f "$ARGV_LOG" ]
}

@test "git-commit: an unsupported option is EX_USAGE rather than silently forwarded" {
    # A forwarded `-a` would stage tracked modifications the caller did not name.
    run "$SRC" -a -F "$MSG" path/one
    [ "$status" -eq 64 ]
    [[ "$output" == *"unsupported option"* ]]
    [ ! -f "$ARGV_LOG" ]
}

@test "git-commit: git's own failure is returned unchanged, not masked" {
    STUB_GIT_RC=1 run "$SRC" -F "$MSG" path/one
    [ "$status" -eq 1 ]
    [ "$(argv)" = "commit -o -F $MSG -- path/one" ]
}

# end of file
