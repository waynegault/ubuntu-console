#!/usr/bin/env bats
# ==============================================================================
# Unit Tests — tools/clean-orphans.sh keeper attribution
# ==============================================================================
# Regression coverage for the keeper reaper. A LIVE `model use` session has the
# topology  model-shell wrapper -> keeper subshell -> `sleep 3600`. The keeper's
# FIFO (fd 3) is what keeps llama-server's stdin open, so reaping a live
# keeper's sleep closes the FIFO and can shut the server down.
#
# The bug this guards against: an ownership check that compares the sleep's
# PARENT (the keeper subshell, whose PID is never in the live model-shell list)
# instead of walking up to the model-shell wrapper — which reaps a live keeper.
# tests/integration/e2e-bench-autotune.bats [E8] covers the same property for
# the sourced __tac_cleanup_stale_locks reaper.
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
SCRIPT="$REPO_ROOT/tools/clean-orphans.sh"

setup() {
    TAC_TEST_TMPDIR="$(mktemp -d)"
    export TAC_TEST_TMPDIR
    export LLM_KEEPER_DIR="$TAC_TEST_TMPDIR/keeper"
    mkdir -p "$LLM_KEEPER_DIR"
    # Sandbox the lock/PID files so a real autotune/bench lock on the host cannot
    # make the script refuse to run (it exits 2 when one is active).
    export LLM_AUTOTUNE_LOCK_FILE="$TAC_TEST_TMPDIR/autotune.lock"
    export LLM_BENCH_LOCK_FILE="$TAC_TEST_TMPDIR/bench.lock"
    export LLM_BENCH_PID_FILE="$TAC_TEST_TMPDIR/bench.pid"
    # The model-shell PID files are read from /tmp (hardcoded in the tool);
    # remember the one we create so teardown removes exactly that.
    export MS_PID_FILE="/tmp/llm-modelshell.tac-test-$$.pid"
    MS_PID=""
    KEEPER_PID=""
    SLEEP_PID=""
}

teardown() {
    # Kill any process we spawned, by PID (never by name — a real host keeper
    # must not be touched).
    local _p
    for _p in "$SLEEP_PID" "$KEEPER_PID" "$MS_PID"; do
        [[ -n "$_p" ]] && kill -TERM "$_p" 2>/dev/null || true
    done
    rm -f "$MS_PID_FILE" 2>/dev/null || true
    rm -rf "$TAC_TEST_TMPDIR" 2>/dev/null || true
}

# _spawn_live_keeper — model shell -> keeper subshell -> sleep 3600, with the
# model shell registered as live. The keeper is run from a script file so its
# argv (like production) does NOT contain "sleep 3600".
_spawn_live_keeper() {
    cat > "$TAC_TEST_TMPDIR/keeper-launcher.sh" <<EOS
cd "$LLM_KEEPER_DIR" || exit 1
sleep 3600
EOS
    ( bash "$TAC_TEST_TMPDIR/keeper-launcher.sh" & wait ) &
    MS_PID=$!
    echo "$MS_PID" > "$MS_PID_FILE"

    local _i
    for _i in $(seq 1 40); do
        KEEPER_PID=$(pgrep -P "$MS_PID" -f 'keeper-launcher' 2>/dev/null | head -1)
        if [[ -n "$KEEPER_PID" ]]; then
            SLEEP_PID=$(pgrep -P "$KEEPER_PID" -f 'sleep 3600' 2>/dev/null | head -1)
        fi
        [[ -n "$SLEEP_PID" ]] && return 0
        sleep 0.2
    done
    return 1
}

@test "clean-orphans: a LIVE keeper owned by a live model shell is not reaped" {
    if ! _spawn_live_keeper; then
        skip "could not spawn the live keeper topology"
    fi
    # Guard the premise: the sleep's parent is the keeper subshell, NOT the
    # model shell — i.e. this is the two-level topology the bug mis-attributed.
    [[ "$(ps -o ppid= -p "$SLEEP_PID" | tr -d '[:space:]')" == "$KEEPER_PID" ]]

    run "$SCRIPT" --check

    [[ "$output" != *"PID=$SLEEP_PID"* ]]
    [[ "$output" != *"PID=$KEEPER_PID"* ]]
}

@test "clean-orphans: an orphaned keeper (no live owner) IS reported" {
    ( cd "$LLM_KEEPER_DIR" && exec sleep 3600 ) &
    SLEEP_PID=$!
    local _i
    for _i in $(seq 1 25); do
        [[ "$(readlink "/proc/$SLEEP_PID/cwd" 2>/dev/null)" == "$LLM_KEEPER_DIR" ]] && break
        sleep 0.2
    done

    run "$SCRIPT" --check

    [[ "$output" == *"PID=$SLEEP_PID"* ]]
}

@test "clean-orphans: a stranger sleep outside the keeper dir is not reported" {
    ( cd / && exec sleep 3600 ) &
    SLEEP_PID=$!
    local _i
    for _i in $(seq 1 25); do
        [[ "$(readlink "/proc/$SLEEP_PID/cwd" 2>/dev/null)" == "/" ]] && break
        sleep 0.2
    done

    run "$SCRIPT" --check

    [[ "$output" != *"PID=$SLEEP_PID"* ]]
}

@test "clean-orphans: a shell that merely mentions llm-stdin is not reported" {
    # A process whose ARGV contains "llm-stdin" but which holds no llm-stdin FD.
    # The marker is passed as $0 and a loop keeps bash from exec-optimising the
    # command away (a plain `bash -c 'x=llm-stdin; sleep 30'` collapses to
    # `sleep 30`, dropping the marker from argv entirely).
    local marker="llm-stdin-tactest-$$"
    bash -c 'while :; do sleep 1; done' "$marker" &
    SLEEP_PID=$!
    local _i
    for _i in $(seq 1 25); do
        pgrep -f "$marker" >/dev/null 2>&1 && break
        sleep 0.2
    done
    # Premise: a `pgrep -f llm-stdin` scan DOES see it, so the old unanchored
    # substring rule would have flagged it. The fd-based rule must not.
    pgrep -f "$marker" >/dev/null

    run "$SCRIPT" --check

    [[ "$output" != *"PID=$SLEEP_PID"* ]]
}
