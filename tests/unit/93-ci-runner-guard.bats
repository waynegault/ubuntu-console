#!/usr/bin/env bats
# ==============================================================================
# Unit — ci-runner-guard restarts only what nothing is holding
# ==============================================================================
# WHY (CI-RUNNER-OFFLINE-001, measured 2026-11-25):
#   `_tac_cleanroom_enter` stops every actions.runner.* unit for a sweep and relies on
#   `_tac_cleanroom_restore` in the SAME process to bring them back.  Two sweeps were
#   hard-killed that night (00:13, 00:47) and all three units stayed `inactive (dead)`
#   for 30+ minutes: `gh api .../actions/runners` reported `wsl-console-arm64: offline`,
#   every push to waynegault/ubuntu-console produced NO run, and that is indistinguishable
#   from a quiet branch.
#
# WHAT THESE CASES ASSERT — each by OUTCOME (a recorded `start`/none), never by a
# printed line:
#   1. active unit                                 -> never touched
#   2. down + hold request whose pid is ALIVE       -> NOT started (a live sweep owns it)
#   3. down + dead pid, record YOUNGER than the TTL -> NOT started (grace)
#   4. down + dead pid, record OLDER than the TTL   -> STARTED
#   5. down + no record at all, under the strikes   -> NOT started yet
#   6. down + no record at all, at the strikes      -> STARTED
#   7. pause marker                                 -> nothing touched
#   8. a start that FAILS                           -> exit 1 (reported, not swallowed)
#
# FALSIFICATION: case 2 is the one that matters.  Replace `_alive` with `false` and
# case 2 goes red: the guard would fight a sweep that is correctly holding the box.
# Verified against that edit.
#
# HERMETIC: a stub systemctl is a FUNCTION in the child shell (the guard's own seam is
# CI_RUNNER_GUARD_SYSTEMCTL, a command name, which the stub satisfies on PATH), and the
# log fixture is a real file whose mtime is irrelevant — the record's own ts= is what is
# read.  No production unit and no /dev/shm state is touched.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export REPO_ROOT
    GUARD="$REPO_ROOT/bin/ci-runner-guard.sh"
    export GUARD
    SANDBOX="$BATS_TEST_TMPDIR/sandbox"
    mkdir -p "$SANDBOX/bin" "$SANDBOX/logs" "$SANDBOX/state"
    export SANDBOX
    export SYS_LOG="$SANDBOX/systemctl.log"
    : > "$SYS_LOG"
    # The stub: list-unit-files reports one enabled runner unit; is-active answers from
    # $ACTIVE which each case sets; anything else is recorded.
    cat > "$SANDBOX/bin/systemctl" <<'EOS'
#!/usr/bin/env bash
if [[ "$1" == "--user" && "$2" == "list-unit-files" ]]; then
    printf "actions.runner.test.unit.service enabled enabled\n"; exit 0
fi
if [[ "$1" == "--user" && "$2" == "is-active" ]]; then
    [[ "${ACTIVE:-}" == "active" ]] && { echo active; exit 0; }
    echo inactive; exit 3
fi
if [[ "$1" == "--user" && "$2" == "start" ]]; then
    printf "%s\n" "$*" >> "$SYS_LOG"
    [[ "${START_FAILS:-0}" == "1" ]] && exit 1
    exit 0
fi
printf "%s\n" "$*" >> "$SYS_LOG"
exit 0
EOS
    chmod +x "$SANDBOX/bin/systemctl"
    export PATH="$SANDBOX/bin:$PATH"
    export CI_RUNNER_GUARD_SYSTEMCTL="$SANDBOX/bin/systemctl"
    export CI_RUNNER_GUARD_STATE="$SANDBOX/state"
    export CI_RUNNER_GUARD_LOG_GLOBS="$SANDBOX/logs"
    export CI_RUNNER_GUARD_PAUSE="$SANDBOX/absent.pause"
    export CI_RUNNER_GUARD_STRIKES=1
    unset ACTIVE START_FAILS
}

# _record <pid> <ts> — write a hold-request line the way the clean-room journals it.
_record() {
    printf '2026-11-25 00:47:08 [autotune] clean-room: runner-hold-request actions.runner.test.unit.service pid=%s ts=%s\n' "$1" "$2" > "$SANDBOX/logs/autotune-1.log"
}

@test "active unit is never touched" {
    export ACTIVE=active
    run bash "$GUARD"
    [ "$status" -eq 0 ]
    [ ! -s "$SYS_LOG" ]
}

@test "down with a LIVE requester: not started (a sweep owns it)" {
    _record $$ "$(date +%s)"      # $$ of the test shell is alive
    run bash "$GUARD"
    [ "$status" -eq 0 ]
    [ ! -s "$SYS_LOG" ]
}

@test "down with a dead requester but a YOUNG record: grace, not started" {
    _record 999999 "$(date +%s)"
    run bash "$GUARD"
    [ "$status" -eq 0 ]
    [ ! -s "$SYS_LOG" ]
}

@test "down with a dead requester and an OLD record: STARTED" {
    _record 999999 "$(( $(date +%s) - 25200 ))"   # 7h, past the 6h default
    run bash "$GUARD"
    [ "$status" -eq 0 ]
    grep -q "start actions.runner.test.unit.service" "$SYS_LOG"
}

@test "down with NO record under the strike threshold: waits one tick" {
    export CI_RUNNER_GUARD_STRIKES=2
    run bash "$GUARD"
    [ "$status" -eq 0 ]
    [ ! -s "$SYS_LOG" ]
}

@test "down with NO record at the strike threshold: STARTED" {
    run bash "$GUARD"
    [ "$status" -eq 0 ]
    grep -q "start actions.runner.test.unit.service" "$SYS_LOG"
}

@test "pause marker stands the guard down" {
    touch "$SANDBOX/paused"
    export CI_RUNNER_GUARD_PAUSE="$SANDBOX/paused"
    _record 999999 "$(( $(date +%s) - 25200 ))"
    run bash "$GUARD"
    [ "$status" -eq 0 ]
    [ ! -s "$SYS_LOG" ]
}

@test "a start that FAILS exits 1" {
    export START_FAILS=1
    _record 999999 "$(( $(date +%s) - 25200 ))"
    run bash "$GUARD"
    [ "$status" -eq 1 ]
}

# end of file
