#!/usr/bin/env bats
# ==============================================================================
# Unit — one decision per CUDA lane start: a live suspend holder refuses it
# ==============================================================================
# WHY (card GPU-LANE-ARBITRATION-001, measured 2026-11-04 00:36-00:52Z, ProArt-P16):
# the CUDA chat lane had two controllers. A 70B autotune row held
# /dev/shm/llama-watchdog-cuda.suspend with live pid 3998; the watchdog honoured the
# hold twice ("not starting llama-cuda-qwen3coder-30b-chat"), and at 00:42:59 the unit
# was started anyway by something systemd never named. At 00:46:03 the watchdog
# enforced the hold with SIGKILL mid-prompt and four agent sessions lost the turn.
# The hold was right; the second controller was the defect.
#
# The fix puts the decision in the unit's own start transaction
# (systemd/llama-cuda-lane-arbiter.conf: ExecCondition=... check %n), so every path —
# an agent's `systemctl --user start`, a script, a timer, the guard, systemd's own
# Restart= — meets the same rule. bin/llama-lane-arbiter.sh is that rule's program.
#
# WHAT THESE CASES PIN (expected values from the card and the .conf contract, not read
# back off the implementation):
#   * exit 0 = may start, exit 78 (EX_CONFIG) = refused — the code the unit's
#     ExecCondition reads as "skip", so a refusal is not a failure state;
#   * a live holder refuses; a STALE marker (dead pid) does not, or one SIGKILLed
#     holder would wedge the lane down for hours (the 2026-10-11 4h22m outage);
#   * a unit outside the scope is never refused — the embedding lane is deliberately
#     out of scope, because LLAMA_LANE_KEEP_UNITS keeps it resident through a drain;
#   * `start` refuses BEFORE systemd: the stub records argv, and a held lane must
#     record nothing at all;
#   * a declared requester is recorded, so a refusal says WHO asked;
#   * a bad invocation is EX_USAGE (64), not a silent allow.
#
# HERMETIC: both seams are pinned in setup — LLAMA_WATCHDOG_CUDA_SUSPEND_FILE (never
# the box's real /dev/shm marker) and LLAMA_LANE_ARBITER_SCOPE (never the box's host
# profile) — and `systemctl` is a stub on PATH. No case asks this box its own state.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    SRC="$REPO_ROOT/bin/llama-lane-arbiter.sh"
    STUB_DIR="$BATS_TEST_TMPDIR/stubs"
    mkdir -p "$STUB_DIR"
    # The systemctl stub records the argv it was given and succeeds. A start that
    # reached systemd is therefore visible in the log, and one that never did is not.
    cat > "$STUB_DIR/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
exit 0
STUB
    chmod +x "$STUB_DIR/systemctl"
    export SYSTEMCTL_LOG="$BATS_TEST_TMPDIR/systemctl.calls"
    # The real `systemctl` must never be reachable: a broken seam here would start the
    # box's live chat lane out of a unit test.
    export PATH="$STUB_DIR:/usr/bin:/bin"

    export LLAMA_WATCHDOG_CUDA_SUSPEND_FILE="$BATS_TEST_TMPDIR/llama-watchdog-cuda.suspend"
    MARK="$LLAMA_WATCHDOG_CUDA_SUSPEND_FILE"
    export LLAMA_LANE_ARBITER_SCOPE="llama-cuda-qwen3coder-30b-chat"
    IN_SCOPE="llama-cuda-qwen3coder-30b-chat"
    OUT_OF_SCOPE="llama-cuda-llama32-3b-chat"
    unset LLAMA_LANE_REQUESTER
    HOLDER=""
}

teardown() {
    # A live holder started by a case is ours to reap; nothing outlives the test.
    if [[ -n "$HOLDER" ]]
    then
        kill "$HOLDER" 2>/dev/null || true
    fi
}

# hold_with_live_pid — start a holder, record its pid in the marker, and keep it alive.
# The pid is the marker's own claim, so the refusal can be asserted against it.
hold_with_live_pid() {
    sleep 30 &
    HOLDER=$!
    printf '%s\n' "$HOLDER" > "$MARK"
}

@test "check: no marker is ALLOWED, exit 0" {
    run bash "$SRC" check "$IN_SCOPE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ALLOWED"* ]]
}

@test "check: a LIVE holder REFUSES with exit 78 and names the pid" {
    hold_with_live_pid
    run bash "$SRC" check "$IN_SCOPE"
    [ "$status" -eq 78 ]
    [[ "$output" == *"REFUSED"* ]]
    [[ "$output" == *"$HOLDER"* ]]
}

@test "check: a DEAD holder is not a hold — exit 0, the lane may start" {
    # A SIGKILLed holder cannot release its own marker (its EXIT trap never runs), so
    # treating a dead pid as held is what kept the lane down for 4h22m on 2026-10-11.
    sleep 0.05 &
    dead=$!
    wait "$dead"
    printf '%s\n' "$dead" > "$MARK"
    # Precondition: the recorded pid must really be dead, or this case asserts nothing.
    run kill -0 "$dead"
    [ "$status" -ne 0 ]
    run bash "$SRC" check "$IN_SCOPE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ALLOWED"* ]]
}

@test "check: a unit outside the scope is ALLOWED while the marker is held" {
    hold_with_live_pid
    run bash "$SRC" check "$OUT_OF_SCOPE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"not in the CUDA-suspend scope"* ]]
}

@test "start: a held lane exits 78 and NEVER reaches systemd" {
    hold_with_live_pid
    run bash "$SRC" start "$IN_SCOPE" "unit-test"
    [ "$status" -eq 78 ]
    [[ "$output" == *"REFUSED"* ]]
    # The whole point of one decision point: a refusal must happen before the start
    # transaction, not after it.
    [ ! -f "$SYSTEMCTL_LOG" ] || [ ! -s "$SYSTEMCTL_LOG" ]
}

@test "start: an unheld lane records the requester and calls systemctl exactly once" {
    export LLAMA_LANE_REQUESTER='test-requester'
    run bash "$SRC" start "$IN_SCOPE" "unit-test"
    [ "$status" -eq 0 ]
    [[ "$output" == *"requester=test-requester"* ]]
    [ -f "$SYSTEMCTL_LOG" ]
    [ "$(wc -l < "$SYSTEMCTL_LOG")" -eq 1 ]
    [ "$(cat "$SYSTEMCTL_LOG")" = "--user start $IN_SCOPE.service" ]
}

@test "an unknown verb and a missing unit are EX_USAGE (64), not a silent allow" {
    run bash "$SRC" nonsense
    [ "$status" -eq 64 ]
    run bash "$SRC" check
    [ "$status" -eq 64 ]
    run bash "$SRC" start
    [ "$status" -eq 64 ]
}
