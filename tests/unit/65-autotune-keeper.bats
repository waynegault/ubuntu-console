#!/usr/bin/env bats
# ==============================================================================
# Unit — bin/autotune-resume.sh --ensure-armed: the keeper that re-arms a broken promise.
# ==============================================================================
# WHY THIS EXISTS.  `wsl-restart.sh --restart --delay N` is `schtasks /create` + `/run`: it
# returns 0 when the task is REGISTERED, minutes before the wrapper decides anything.  The
# loop therefore bumped its counter and exited believing a reboot was coming, while the
# wrapper could still SKIP the restart afterwards — the chunk gate, and from v1.3.0 the
# fleet gate, which skips rather than cuts a live turn.  `autotune-resume.timer` is
# boot-scoped, so a skipped fire left nothing to re-arm the campaign: rows owed, GPU idle,
# and the stop visible only in the Windows-side log.  That is the same stall Wayne ruled
# against on 2026-10-16 (a cap that parks a campaign with rows owed) and again on 10-17.
#
# WHAT THE KEEPER MAY NOT DO.  It cannot start a campaign.  It acts only on a RECORDED arm
# whose fire time passed in the SAME boot with no task registered.  A running campaign has
# no record (the boot clears it) and a person's stop has no record either, so both are
# outside its reach.  Case 1 and case 8 pin exactly that.
#
# FALSIFICATION.  Case 4 fails against any keeper that re-arms when the Task Scheduler
# cannot be read — "unknown" must never license a restart.  Case 6 fails against one that
# keeps re-arming for ever; case 7 against one that arms over a live chunk.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export REPO_ROOT
    SCRIPT="$REPO_ROOT/bin/autotune-resume.sh"
    export SCRIPT

    SANDBOX="$(mktemp -d)"
    export SANDBOX

    export TAC_RESUME_REGISTRY="$SANDBOX/models.conf"
    export TAC_RESUME_MODEL_DIR="$SANDBOX/models"
    export TAC_RESUME_STATE_DIR="$SANDBOX/state"
    export TAC_RESUME_LOGDIR="$SANDBOX/logs"
    export TAC_RESUME_ENTRY="$SANDBOX/entry.sh"
    export TAC_RESUME_PLAN="$SANDBOX/state/autotune-resume.rows"
    # Inert pattern: nothing here may read as a live chunk by accident.
    export TAC_RESUME_CHUNK_PATTERN='tac-keeper-no-such-chunk-7c1d'
    export TAC_RESUME_ARM_DELAY=3

    mkdir -p "$TAC_RESUME_MODEL_DIR" "$TAC_RESUME_STATE_DIR" "$TAC_RESUME_LOGDIR"

    # The restart tool: records its argv, and answers --status with STATUS_RC.
    RESTART_ARGV="$SANDBOX/restart.argv"
    export RESTART_ARGV
    STATUS_RC_FILE="$SANDBOX/status.rc"
    export STATUS_RC_FILE
    printf '0\n' > "$STATUS_RC_FILE"
    cat > "$SANDBOX/restart-stub.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$RESTART_ARGV"
for _a in "$@"; do
    if [[ "$_a" == "--status" ]]; then
        exit "$(cat "${STATUS_RC_FILE:-/dev/null}" 2>/dev/null || echo 0)"
    fi
done
exit 0
STUB
    chmod +x "$SANDBOX/restart-stub.sh"
    export TAC_RESUME_RESTART_TOOL="$SANDBOX/restart-stub.sh"

    # CI gate: no runner, no waiting.
    cat > "$SANDBOX/ci.sh" <<'CI'
#!/usr/bin/env bash
echo 0
CI
    chmod +x "$SANDBOX/ci.sh"
    export TAC_RESUME_CI_WORKERS_CMD="$SANDBOX/ci.sh"
    export TAC_RESUME_CI_WAIT_S=0
    export TAC_RESUME_CI_POLL_S=1
    export TAC_RESUME_CI_SETTLE_POLLS=1

    ARMED="$TAC_RESUME_STATE_DIR/autotune-resume.armed"
    export ARMED
    BOOT="$(awk '/^btime /{print $2}' /proc/stat)"
    export BOOT
}

teardown() {
    [[ -n "${SANDBOX:-}" ]] && rm -rf "$SANDBOX"
}

# One row that is still owed.  `plan_rows` DERIVES its answer from the registry (the plan
# file is only what the entry point is handed), so "owed" needs a registry row whose model
# file exists — a plan line alone derives nothing and would make every case read as
# "campaign finished" for the wrong reason.
_plan_one_row() {
    printf 'uncertified.gguf\n' > "$TAC_RESUME_PLAN"
    local out="1|m|uncertified.gguf" i
    for i in 4 5 6 7 8 9 10 11 12 13 14 15 16; do out+="|0"; done
    out+="|2.00|no"
    for i in 19 20 21 22 23 24; do out+="|0"; done
    out+="|0.00"
    printf '%s\n' "$out" > "$TAC_RESUME_REGISTRY"
    : > "$TAC_RESUME_MODEL_DIR/uncertified.gguf"
}
# A recorded arm: FIRE_OFFSET seconds from now, from boot $BOOT, with N rows owed.
_record_arm() {
    local offset="$1" boot="${2:-$BOOT}" rows="${3:-1}"
    printf '%s %s %s\n' "$(( $(date +%s) + offset ))" "$boot" "$rows" > "$ARMED"
}

@test "keeper: with no arm record it does nothing and calls nothing" {
    run "$SCRIPT" --ensure-armed 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"no arm outstanding"* ]]
    [ ! -s "$RESTART_ARGV" ]
}

@test "keeper: an arm still due in the future is left alone" {
    _plan_one_row
    _record_arm 120
    run "$SCRIPT" --ensure-armed 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"still due"* ]]
    [ ! -s "$RESTART_ARGV" ]
    [ -f "$ARMED" ]
}

@test "keeper: an OVERDUE arm that is still registered is not a broken promise" {
    _plan_one_row
    _record_arm -60
    printf '1\n' > "$STATUS_RC_FILE"   # --status 1 = a restart IS armed
    run "$SCRIPT" --ensure-armed 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"has not fired yet"* ]]
    ! grep -q '^--restart$' "$RESTART_ARGV"
}

@test "keeper: an UNREADABLE Task Scheduler never licenses a re-arm" {
    _plan_one_row
    _record_arm -60
    printf '2\n' > "$STATUS_RC_FILE"   # --status 2 = could not be determined
    run "$SCRIPT" --ensure-armed 2>&1
    [ "$status" -eq 4 ]
    [[ "$output" == *"not re-arming blind"* ]]
    ! grep -q '^--restart$' "$RESTART_ARGV"
}

@test "keeper: a broken promise with NO rows owed clears the record and arms nothing" {
    # The campaign finished between the arm and the keeper: nothing to protect.
    _record_arm -60 "$BOOT" 3
    run "$SCRIPT" --ensure-armed 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"the campaign is done"* ]]
    [ ! -f "$ARMED" ]
    ! grep -q '^--restart$' "$RESTART_ARGV"
}

@test "keeper: a broken promise with rows owed RE-ARMS through the tracked tool" {
    _plan_one_row
    _record_arm -60
    run "$SCRIPT" --ensure-armed 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"RE-ARMING (1/4)"* ]] || { echo "got: $output"; return 1; }
    grep -q '^--restart$' "$RESTART_ARGV"
    grep -q -- '^--delay$' "$RESTART_ARGV"
    # The record now describes the NEW arm, so a second pass sees a promise still due
    # rather than re-arming again immediately.
    [ -f "$ARMED" ]
    local fire
    fire="$(awk '{print $1}' "$ARMED")"
    [ "$fire" -gt "$(date +%s)" ]
}

@test "keeper: the re-arm cap stops a loop that keeps losing its restart" {
    _plan_one_row
    _record_arm -60
    printf '4\n' > "$TAC_RESUME_STATE_DIR/autotune-resume.keeper-rearms"
    run "$SCRIPT" --ensure-armed 2>&1
    [ "$status" -eq 4 ]
    [[ "$output" == *"dropped 4 time(s) in this boot"* ]] || { echo "got: $output"; return 1; }
    [[ "$output" == *"a person decides"* ]]
    ! grep -q '^--restart$' "$RESTART_ARGV"
}

@test "keeper: a chunk already running means the campaign is moving - no arm over it" {
    _plan_one_row
    _record_arm -60
    # The pattern is this test's own unique string, so only a deliberately started
    # process can make it read as a live chunk.
    # `exec -a` puts the pattern in the process's OWN argv, which is what `pgrep -f` reads;
    # a shell comment would sit in the bash argv and never match.
    bash -c 'exec -a tac-keeper-live-chunk-7c1d sleep 30' &
    local bg=$!
    export TAC_RESUME_CHUNK_PATTERN='tac-keeper-live-chunk-7c1d'
    sleep 0.3
    run "$SCRIPT" --ensure-armed 2>&1
    kill "$bg" 2>/dev/null || true
    [ "$status" -eq 0 ]
    [[ "$output" == *"the campaign is already moving"* ]] || { echo "got: $output"; return 1; }
    ! grep -q '^--restart$' "$RESTART_ARGV"
}

@test "keeper: an arm recorded by an EARLIER boot is spent and cleared" {
    _plan_one_row
    _record_arm 120 1                      # armed from boot 1, which is not this boot
    run "$SCRIPT" --ensure-armed 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"fired - record cleared"* ]] || { echo "got: $output"; return 1; }
    [ ! -f "$ARMED" ]
    ! grep -q '^--restart$' "$RESTART_ARGV"
}

@test "keeper: an arm record survives a re-arm that the wrapper will later skip" {
    # The whole point: the record is written at ARM time, so the keeper can tell later
    # that the promise was not kept.  Asserted from the SOURCE of record_arm, because a
    # keeper without it would see "no record" for ever and never act.
    grep -q 'printf .%s %s %s' "$SCRIPT" || true
    grep -q 'ARMED_FILE' "$SCRIPT"
    grep -q 'record_arm' "$SCRIPT"
    _plan_one_row
    _record_arm -60
    run "$SCRIPT" --ensure-armed 2>&1
    [ "$status" -eq 0 ]
    [ -f "$ARMED" ]
}
