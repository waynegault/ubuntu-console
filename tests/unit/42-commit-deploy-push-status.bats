#!/usr/bin/env bats
# ==============================================================================
# Unit — commit_deploy: a FAILED push must not return success
# ==============================================================================
# WHY THIS EXISTS (card cf05ce24, AUDIT-2026-10-02): commit_deploy read the push's
# status and reported it ("[REMOTE PUSH FAILED]" in the error colour) — but neither
# branch RETURNED, so the function's exit status was the footer's, always 0. A
# caller writing `commit_deploy "msg" && deploy-something` therefore ran the next
# step after a sync that never reached the remote.
#
# These cases assert the PROPERTY a caller reads — the exit status — not the row:
# a rejected push must be non-zero, and it must not also print the success token.
#
# FALSIFICATION (2026-10-02): against the pre-fix commit_deploy the rejected-push
# case fails — it returns 0 (the footer's status) while printing the failure row.
#
# HERMETIC: a throwaway git repo and a local bare "origin" with a pre-receive hook
# that rejects the push. No network, and HOME is sandboxed.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export REPO_ROOT
    SANDBOX="$(mktemp -d)"
    export SANDBOX
    export HOME="$SANDBOX/home"
    export TAC_TEST_TMPDIR="$SANDBOX/tac"
    export TAC_CACHE_DIR="$SANDBOX/cache"
    mkdir -p "$HOME" "$TAC_TEST_TMPDIR" "$TAC_CACHE_DIR"

    # shellcheck source=env.sh
    source "$REPO_ROOT/env.sh"

    # Flatten the UI rows so the assertions match the status words without colour.
    __tac_line() { printf 'LINE %s\n' "$*"; }
    __tac_info() { printf 'INFO %s\n' "$*"; }
    __tac_header() { printf 'HEADER %s\n' "$*"; }
    __tac_footer() { printf 'FOOTER\n'; }

    # A local bare "origin"; individual cases may install a rejecting hook.
    ORIGIN="$SANDBOX/origin.git"
    git init --bare --quiet "$ORIGIN"

    WORK="$SANDBOX/work"
    mkdir -p "$WORK"
    git init --quiet "$WORK"
    git -C "$WORK" config user.email "test@example.invalid"
    git -C "$WORK" config user.name "Test"
    # Let a bare `git push` create and track the branch, so the push actually
    # reaches the remote (and its hook) instead of failing on "no upstream".
    git -C "$WORK" config push.autoSetupRemote true
    git -C "$WORK" remote add origin "$ORIGIN"
    printf 'baseline\n' > "$WORK/baseline.txt"
    git -C "$WORK" add baseline.txt
    git -C "$WORK" commit --quiet -m baseline
    printf 'hello world\n' > "$WORK/note.txt"

    cd "$WORK"
}

teardown() {
    cd /
    rm -rf "$SANDBOX"
}

# _reject_pushes — arm the origin so any push is refused by the remote.
_reject_pushes() {
    cat > "$ORIGIN/hooks/pre-receive" <<'HOOK'
#!/usr/bin/env bash
echo "push rejected by the test fixture" >&2
exit 1
HOOK
    chmod +x "$ORIGIN/hooks/pre-receive"
}

_stub_commit_auto_dependencies() {
    __test_port() { return 0; }
    __llm_proc_is_server() { return 0; }
    ss() { printf 'LISTEN users:(("llama-server",pid=4242,fd=1))\n'; }
    curl() {
        case "${COMMIT_AUTO_CURL_MODE:-success}" in
            transport-failure)
                printf '%s\n' "curl: simulated local inference failure" >&2
                return 22
                ;;
            malformed-response)
                printf '%s\n' '{"choices":'
                ;;
            success)
                printf '%s\n' '{"choices":[{"message":{"content":"generated test message"}}]}'
                ;;
        esac
    }
}

@test "commit_deploy: a rejected push returns non-zero and never claims SUCCESS" {
    _reject_pushes

    run commit_deploy "test commit"

    # The caller-visible contract: a failed sync is a failed command.
    [ "$status" -ne 0 ]
    [[ "$output" == *"[REMOTE PUSH FAILED]"* ]]
    # ...and the success token is not printed alongside it (the old shape's lie).
    [[ "$output" != *"[SUCCESS]"* ]]
    # The push was really attempted: the commit exists locally.
    run git log -1 --format=%s
    [ "$output" = "test commit" ]
}

@test "commit_deploy: a successful push returns zero and reports SUCCESS" {
    # The other direction: a guard that turned every push into a failure would be
    # its own bug, so the healthy path is asserted too.
    run commit_deploy "test commit"

    [ "$status" -eq 0 ]
    [[ "$output" == *"[SUCCESS]"* ]]
    [[ "$output" != *"[REMOTE PUSH FAILED]"* ]]
    # The commit reached the remote: HEAD and its tracked upstream are one commit.
    run bash -c '[[ "$(git rev-parse HEAD)" == "$(git rev-parse "@{u}")" ]]'
    [ "$status" -eq 0 ]
}

@test "commit_auto: local inference transport failure is non-zero and leaves files uncommitted" {
    _stub_commit_auto_dependencies
    export COMMIT_AUTO_CURL_MODE=transport-failure
    printf 'pre-staged change\n' > "$WORK/pre-staged.txt"
    git add pre-staged.txt

    run commit_auto

    [ "$status" -ne 0 ]
    [[ "$output" == *"simulated local inference failure"* ]]
    [[ "$output" == *"[REQUEST FAILED]"* ]]
    [ -f "$WORK/note.txt" ]
    [ "$(git log -1 --format=%s)" = "baseline" ]
    [ "$(git diff --cached --name-only)" = "pre-staged.txt" ]
    [ -z "$(git --git-dir="$ORIGIN" for-each-ref --format='%(refname)' refs/heads)" ]
}

@test "commit_auto: malformed model response is non-zero and reports parse failure" {
    _stub_commit_auto_dependencies
    export COMMIT_AUTO_CURL_MODE=malformed-response
    printf 'pre-staged change\n' > "$WORK/pre-staged.txt"
    git add pre-staged.txt

    run commit_auto

    [ "$status" -ne 0 ]
    [[ "$output" == *"parse error"* ]]
    [[ "$output" == *"[FAILED TO GENERATE MESSAGE]"* ]]
    [ -f "$WORK/note.txt" ]
    [ "$(git log -1 --format=%s)" = "baseline" ]
    [ "$(git diff --cached --name-only)" = "pre-staged.txt" ]
}

@test "commit_auto: cancellation preserves the pre-existing index" {
    _stub_commit_auto_dependencies
    printf 'pre-staged change\n' > "$WORK/pre-staged.txt"
    git add pre-staged.txt

    run commit_auto <<< "n"

    [ "$status" -eq 0 ]
    [[ "$output" == *"[CANCELLED]"* ]]
    [ "$(git diff --cached --name-only)" = "pre-staged.txt" ]
    [ -f "$WORK/note.txt" ]
    [ "$(git log -1 --format=%s)" = "baseline" ]
}

@test "commit_auto: generated message is committed and pushed only after acceptance" {
    _stub_commit_auto_dependencies
    export COMMIT_AUTO_CURL_MODE=success

    run commit_auto <<< "y"

    [ "$status" -eq 0 ]
    [[ "$output" == *"generated test message"* ]]
    [[ "$output" == *"[SUCCESS]"* ]]
    [ "$(git log -1 --format=%s)" = "generated test message" ]
    [ -z "$(git status --porcelain)" ]
    run bash -c '[[ "$(git rev-parse HEAD)" == "$(git rev-parse "@{u}")" ]]'
    [ "$status" -eq 0 ]
}

# end of file
