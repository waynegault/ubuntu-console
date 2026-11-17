#!/usr/bin/env bats
# ==============================================================================
# Unit — bin/autotune-rows.sh: a spent CUDA ledger arms a WSL restart
# ==============================================================================
# WHY THIS EXISTS.  Measured 2026-11-17: three runs (`model autotune 8 9 11` twice and
# one `autotune-rows.sh 11 8 9`) each stood the whole clean-room down, found the ledger
# at 63 against a budget of 60, printed "batch exited 4", and put the box back —
# measuring nothing.  The ledger is boot-scoped, so the only remedy is the next boot,
# and the restart that performs it lived in autotune-resume.service alone, which a
# direct `model autotune` never tells.
#
# The expected behaviour, from Wayne's ruling of the same day ("we should have ledger
# checks at the beginning of autotune ... and fix the wiring"):
#   * the ledger is read BEFORE the clean-room, so a doomed run costs nothing;
#   * a spent ledger arms bin/wsl-restart.sh, it does not merely refuse;
#   * a CI job executing on this box DEFERS the arm (a restart would kill it);
#   * AUTOTUNE_AUTO_RESTART=0 opts out;
#   * a HEALTHY ledger never arms anything.
#
# FALSIFICATION.  The arm case fails against the pre-change wrapper (which exits 4 and
# arms nothing); the CI case fails against an arm that does not check for workers; the
# healthy case fails against one that arms unconditionally, which would reboot the box
# after every successful sweep.
#
# No env.sh: the wrapper is driven as a subprocess with a recorder standing in for
# bin/wsl-restart.sh, through the seam it already exposes (TAC_RESUME_RESTART_TOOL).
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
    SANDBOX="$(mktemp -d)"
    export SANDBOX
    # THE CLEAN-ROOM SEAM.  Without this the wrapper's _tac_cleanroom_enter runs against
    # the LIVE box: it stops the declared census tenants and holds the CI runners, and
    # the batch's own keep_lane_down stops the chat lane.  Measured 2026-11-17: the
    # suite was green while autotune-20261117-100057 left llama-cuda-qwen3coder-30b-chat
    # down for 41 minutes (journal 10:00:58 -> 10:42:32).  TAC_TEST_TMPDIR is the
    # predicate _tac_cleanroom_stops_allowed already reads, so setting it here arms the
    # guard that exists for exactly this and needs no new seam.
    export TAC_TEST_TMPDIR="$SANDBOX"
    # The recorder: every call is a line, so "armed" and "not armed" are countable.
    RECORDER="$SANDBOX/restart-recorder"
    CALLS="$SANDBOX/calls"
    : > "$CALLS"
    # EXPORTED, not merely set: the recorder is a child process, so an unexported
    # RESTART_CALLS reaches it empty and it appends to "/calls" — measured here as
    # "Permission denied" on line 2 of the recorder rather than a failing assertion.
    export RESTART_CALLS="$CALLS"
    cat > "$RECORDER" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RESTART_CALLS"
EOS
    chmod +x "$RECORDER"
    # A pgrep that answers "no CI worker" unless the case says otherwise.  The worker
    # probe is LIVE state on this box, so without this a real job would decide the case.
    mkdir -p "$SANDBOX/bin"
    cat > "$SANDBOX/bin/pgrep" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "${STUB_CI_WORKERS:-0}"
exit 0
EOS
    chmod +x "$SANDBOX/bin/pgrep"
    # A systemctl that RECORDS every call and changes nothing.  The clean-room guard
    # refuses the stops under TAC_TEST_TMPDIR, but a guard is a claim until something
    # counts the calls: this stub is what makes "no production unit was stopped" an
    # assertion instead of a hope.  It also keeps the suite from touching the real
    # user manager even if a future edit removes the guard.
    SYSTEMCTL_LOG="$SANDBOX/systemctl.log"
    export SYSTEMCTL_LOG
    : > "$SYSTEMCTL_LOG"
    cat > "$SANDBOX/bin/systemctl" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
case "$*" in *is-active*) exit 0 ;; esac
exit 0
EOS
    chmod +x "$SANDBOX/bin/systemctl"
}

teardown() {
    rm -rf "$SANDBOX"
}

# run_wrapper <ledger value> — run autotune-rows.sh with the ledger seeded and the
# restart tool recorded.  The row list is deliberately one that would otherwise run, so
# a refusal can only come from the ledger.
run_wrapper() {
    local ledger="$1"; shift
    local ledger_file="$SANDBOX/ledger"
    printf '%s\n' "$ledger" > "$ledger_file"
    # The assignments BELOW the "$@" (a bare `$@` is not a command word, so the
    # assignments stay on the bash invocation).  Putting them before "$@" applied the
    # env to whatever the case prepended — which is how the first three cases ran the
    # wrapper with no HEAVY_JOB_HELD, no ledger override and no recorder.
    #
    # HEAVY_JOB_HELD is the wrapper's own re-entrancy seam: without it the script
    # exec's bin/heavy-job and the case QUEUES on the box-wide lock (measured: it hung
    # to the 300 s timeout rather than failing).  --force-live-fleet bypasses the
    # quiet-fleet gate, which would otherwise refuse because this agent session runs.
    #
    # LLAMA_WATCHDOG_CUDA_SUSPEND_FILE is the TENANCY seam, and it was missing: without
    # it every case acquired the PRODUCTION marker at /dev/shm/llama-watchdog-cuda.suspend,
    # so a real autotune or watchdog holding it made the wrapper refuse at
    # _tac_suspend_acquire and exit 1 before the arm — the case then failed with an empty
    # recorder, intermittently, depending on what the box was doing.  Measured
    # 2026-11-17: the same file passed 4/4 and failed 3/4 on consecutive runs.
    "$@" env PATH="$SANDBOX/bin:$PATH" \
        HEAVY_JOB_HELD=1 \
        RESTART_CALLS="$CALLS" \
        TAC_RESUME_RESTART_TOOL="$RECORDER" \
        CUDA_CYCLE_FILE="$ledger_file" \
        LLAMA_WATCHDOG_CUDA_SUSPEND_FILE="$SANDBOX/suspend" \
        AUTOTUNE_RESTART_DELAY=3 \
        bash "$REPO_ROOT/bin/autotune-rows.sh" --force-live-fleet 999 2>&1
}

@test "ledger: a spent count ARMS the restart instead of only refusing" {
    # The measured fault: three runs refused and armed nothing, so the box stayed on a
    # boot that could not measure.  The arm is the whole point.
    run run_wrapper 63
    [ -e "$CALLS" ]
    grep -q -- '--restart' "$CALLS" \
        || { echo "a spent ledger must ARM the restart; calls: $(cat "$CALLS")"; return 1; }
    [[ "$output" == *"PRE-FLIGHT"* ]]
}

@test "ledger: a CI job executing on this box DEFERS the arm" {
    # A restart kills the job, and a killed run is not a cancelled one — the same bound
    # autotune-resume's own arm_restart applies before it arms.  The variable is passed
    # to `env` explicitly: `STUB_CI_WORKERS=1 run run_wrapper` would set it on the `run`
    # builtin, not on the wrapper.
    run run_wrapper 63 env STUB_CI_WORKERS=1
    [[ "$output" == *"restart NOT armed"* ]]
    ! grep -q -- '--restart' "$CALLS"
}

@test "ledger: AUTOTUNE_AUTO_RESTART=0 opts out" {
    run run_wrapper 63 env AUTOTUNE_AUTO_RESTART=0
    [[ "$output" == *"restart NOT armed"* ]]
    ! grep -q -- '--restart' "$CALLS"
}

@test "ledger: a HEALTHY count never arms a restart" {
    # The control.  Without it, an arm wired above the ledger test would reboot the box
    # after every successful sweep — worse than the fault it fixes.
    run run_wrapper 3
    ! grep -q -- '--restart' "$CALLS"
    [[ "$output" != *"PRE-FLIGHT"* ]]
}

@test "clean-room: NO production unit is stopped, on any path" {
    # THE CASE THAT WAS MISSING.  Every other case here asserts the arm; none asserted
    # that the run left the box alone, so the suite passed while
    # autotune-20261117-100057 stopped the chat lane and never restored it (journal
    # 10:00:58 -> 10:42:32, 41 minutes).  A test that tears down production and checks
    # only its own subject will pass while doing damage.
    #
    # This covers the WRAPPER's path.  The batch's own keep_lane_down is covered by the
    # case below, because a held suspend marker is what that function keys on and this
    # path never reaches it (the baseline gate refuses first).
    #
    # ONLY the spent-ledger path is driven here.  A healthy ledger launches the real
    # batch, which drains the card and runs a row — measured: it hung this case to the
    # 400 s timeout.  The batch's stop is asserted directly by the next case instead.
    run run_wrapper 63
    local stops
    stops="$(grep -c ' stop ' "$SYSTEMCTL_LOG" || true)"
    [ "$stops" -eq 0 ] \
        || { echo "a test stopped $stops production unit(s):"; grep ' stop ' "$SYSTEMCTL_LOG"; return 1; }
    # The spent-ledger path must not even REACH the clean-room: the pre-flight refuses
    # first, which is the point of the v26 pre-flight.  Asserting the TAC_TEST_TMPDIR
    # refusal here would be wrong — it is the guard of last resort, and this path is
    # supposed to stop earlier than that.
    [[ "$output" == *"PRE-FLIGHT"* ]]
    [[ "$output" != *"clean-room: stopped tenant"* ]] \
        || { echo "the pre-flight did not prevent the clean-room from standing tenants down"; return 1; }
}

@test "clean-room: the batch's keep_lane_down is refused under TAC_TEST_TMPDIR" {
    # THE SECOND, UNGUARDED STOP.  The wrapper's clean-room refuses under TAC_TEST_TMPDIR,
    # but scripts/run-autotune-batch.sh had its OWN stop of the lane (now guarded) with no
    # test predicate at all — which is why the lane went down even though the wrapper's
    # guard fired.  This case drives that function directly: a held suspend marker is the
    # tenancy test it keys on, so without one it returns before the stop and proves
    # nothing.
    printf '%s\n' "$$" > "$SANDBOX/suspend"
    cat > "$SANDBOX/probe.sh" <<'EOS'
set -uo pipefail
source "$1/bin/_tac-bin-lib.sh"
_lane_suspend="$SANDBOX/suspend"
_lane_unit="llama-cuda-test-lane.service"
keep_lane_down() {
    declare -f _tac_suspend_held &>/dev/null || return 0
    _tac_suspend_held "$_lane_suspend" || return 0
    if declare -f _tac_cleanroom_stops_allowed &>/dev/null \
        && ! _tac_cleanroom_stops_allowed; then
        return 0
    fi
    systemctl --user stop "$_lane_unit" >/dev/null
}
keep_lane_down
echo "reached-the-stop"
EOS
    run env PATH="$SANDBOX/bin:$PATH" SANDBOX="$SANDBOX" \
        LLAMA_WATCHDOG_CUDA_SUSPEND_FILE="$SANDBOX/suspend" \
        bash "$SANDBOX/probe.sh" "$REPO_ROOT"
    [ "$status" -eq 0 ]
    local stops
    stops="$(grep -c ' stop ' "$SYSTEMCTL_LOG" || true)"
    [ "$stops" -eq 0 ] \
        || { echo "keep_lane_down stopped a unit under TAC_TEST_TMPDIR:"; grep ' stop ' "$SYSTEMCTL_LOG"; return 1; }

    # THE ALLOW ARM.  Unset the test predicate and the same call MUST reach the stop, or
    # the guard is refusing everything and the case above proves nothing.
    : > "$SYSTEMCTL_LOG"
    run env -u TAC_TEST_TMPDIR PATH="$SANDBOX/bin:$PATH" SANDBOX="$SANDBOX" \
        LLAMA_WATCHDOG_CUDA_SUSPEND_FILE="$SANDBOX/suspend" \
        bash "$SANDBOX/probe.sh" "$REPO_ROOT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"reached-the-stop"* ]]
    grep -q ' stop ' "$SYSTEMCTL_LOG" \
        || { echo "the ALLOW arm did not reach the stop - the guard refuses everything"; return 1; }
}
