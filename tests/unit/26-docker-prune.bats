#!/usr/bin/env bats
# ==============================================================================
# Unit — `up`'s [19/20] docker prune must not report a clean it never verified
# ==============================================================================
# Why (card DOCKER-PRUNE-FALSE-CLEAN-001, measured 2026-09-23): the step guarded on
# `command -v docker` alone, and `docker system prune`'s output was parsed for a
# reclaim line.  On this box /usr/bin/docker is a SYMLINK into
# /mnt/wsl/docker-desktop/cli-tools/…, so when that mount is stale `command -v`
# still succeeds while EVERY invocation fails with `Input/output error` (rc 126).
# No reclaim line on a failed prune read as "nothing to reclaim", so the step
# printed `[19/20] Docker Prune [CLEAN]` in the SUCCESS colour — a claimed success
# with no effect, not a harmless no-op.
#
# Hermetic: a stub `docker` on PATH decides what happens, HOME points at a temp dir,
# and no daemon is ever contacted.  The step is called DIRECTLY rather than under
# `run`, because it reports through a `local -n` nameref on the caller's error
# counter — a subshell would hide the increments this suite asserts on.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    TAC_TEST_TMPDIR="$(mktemp -d)"
    export TAC_TEST_TMPDIR
    export HOME="$TAC_TEST_TMPDIR/home"
    export TAC_CACHE_DIR="$TAC_TEST_TMPDIR/cache"
    mkdir -p "$HOME" "$TAC_CACHE_DIR"

    # Per-case stub behaviour, read by the stub at call time:
    #   DOCKER_INFO_RC   non-zero models an unreachable/unexecutable docker
    #   DOCKER_PRUNE_RC  non-zero models a prune that was reached and then failed
    #   DOCKER_PRUNE_OUT what a successful prune prints
    export DOCKER_INFO_RC=0
    export DOCKER_PRUNE_RC=0
    export DOCKER_PRUNE_OUT='Total reclaimed space: 1.5GB'
    export DOCKER_CALLS="$TAC_TEST_TMPDIR/docker.calls"

    export DOCKER_STUB_DIR="$TAC_TEST_TMPDIR/stub"
    mkdir -p "$DOCKER_STUB_DIR"
    cat > "$DOCKER_STUB_DIR/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_CALLS"
case "${1:-}" in
    info)
        if (( ${DOCKER_INFO_RC:-0} != 0 ))
        then
            printf '%s\n' "/usr/bin/docker: Input/output error" >&2
            exit "${DOCKER_INFO_RC}"
        fi
        printf '%s\n' "27.0.0"
        ;;
    system)
        if (( ${DOCKER_PRUNE_RC:-0} != 0 ))
        then
            printf '%s\n' "Error response from daemon: prune failed" >&2
            exit "${DOCKER_PRUNE_RC}"
        fi
        printf '%s\n' "${DOCKER_PRUNE_OUT}"
        ;;
esac
exit 0
STUB
    chmod 755 "$DOCKER_STUB_DIR/docker"
    export PATH="$DOCKER_STUB_DIR:$PATH"

    # shellcheck source=env.sh
    source "$REPO_ROOT/env.sh"

    STEP_OUT=""
    STEP_OUT_FILE="$TAC_TEST_TMPDIR/step.out"
}

teardown() {
    rm -rf "${TAC_TEST_TMPDIR:-/tmp/bats-noop}"
}

# Call the step in THIS shell so `errCount` is genuinely incremented, and read its
# output back from a file (a command substitution would subshell the counter away).
run_step() { # <errCount-name>
    __up_docker_prune 1700000000 1 "$1" > "$STEP_OUT_FILE" 2>&1
    STEP_OUT="$(< "$STEP_OUT_FILE")"
}

@test "docker-prune: an unreachable docker is a SKIP that names the reason, never a clean" {
    export DOCKER_INFO_RC=126
    errCount=0
    run_step errCount

    [[ "$STEP_OUT" == *"SKIP - Docker unreachable"* ]]
    [[ "$STEP_OUT" == *"Input/output error"* ]]
    # the regression this card exists for: a clean must not be claimed
    [[ "$STEP_OUT" != *"[CLEAN]"* ]]
    [[ "$STEP_OUT" != *"[FREED"* ]]
    # ...and the reason must be Docker's own line, not bash's "script: line N:" wrapper
    [[ "$STEP_OUT" != *"08-maintenance.sh: line"* ]]
    # an unreachable Docker Desktop is a stated skip, not a pipeline failure
    [ "$errCount" = "0" ]
}

@test "docker-prune: an unreachable docker never even attempts the prune" {
    export DOCKER_INFO_RC=126
    errCount=0
    run_step errCount

    ! grep -q "system prune" "$DOCKER_CALLS"
    grep -q "^info" "$DOCKER_CALLS"
}

@test "docker-prune: a prune that was reached and failed is reported, and counted" {
    export DOCKER_INFO_RC=0
    export DOCKER_PRUNE_RC=1
    errCount=0
    run_step errCount

    [[ "$STEP_OUT" == *"FAILED (rc=1)"* ]]
    [[ "$STEP_OUT" == *"prune failed"* ]]
    [[ "$STEP_OUT" != *"[CLEAN]"* ]]
    [ "$errCount" = "1" ]
}

@test "docker-prune: only a SUCCESSFUL prune with no reclaim reads as clean" {
    export DOCKER_INFO_RC=0
    export DOCKER_PRUNE_RC=0
    export DOCKER_PRUNE_OUT='Total reclaimed space: 0B'
    errCount=0
    run_step errCount

    [[ "$STEP_OUT" == *"[CLEAN]"* ]]
    [ "$errCount" = "0" ]
}

@test "docker-prune: a successful prune reports what it freed" {
    export DOCKER_INFO_RC=0
    export DOCKER_PRUNE_RC=0
    export DOCKER_PRUNE_OUT='Deleted Volumes:
abc
Total reclaimed space: 1.5GB'
    errCount=0
    run_step errCount

    [[ "$STEP_OUT" == *"[FREED 1.5GB]"* ]]
    [ "$errCount" = "0" ]
}

@test "docker-prune: no docker client at all is the original skip" {
    # An empty PATH is the only hermetic way to hide the REAL /usr/bin/docker; the
    # skip branch returns before the step needs any external command.  PATH is
    # scoped to the call so teardown still has its tools.
    mkdir -p "$TAC_TEST_TMPDIR/emptybin"
    errCount=0
    PATH="$TAC_TEST_TMPDIR/emptybin" run_step errCount

    [[ "$STEP_OUT" == *"SKIP - Docker not installed"* ]]
    [ "$errCount" = "0" ]
}

# end of file
