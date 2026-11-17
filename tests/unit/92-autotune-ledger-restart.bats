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
    "$@" env PATH="$SANDBOX/bin:$PATH" \
        HEAVY_JOB_HELD=1 \
        RESTART_CALLS="$CALLS" \
        TAC_RESUME_RESTART_TOOL="$RECORDER" \
        CUDA_CYCLE_FILE="$ledger_file" \
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
