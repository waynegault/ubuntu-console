#!/usr/bin/env bats
# ==============================================================================
# Integration Tests — Llama Watchdog
# ==============================================================================
# Tests llama-watchdog.sh health probing, GPU-busy gating, and systemd-based
# recovery. All external commands (curl, systemctl, gpu-busy.sh) are mocked so
# the suite is hermetic and never touches the live llama-server.service.
# Run: bats tests/integration/04-watchdog.bats
# ==============================================================================

setup_file() {
    export REPO_ROOT
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export WATCHDOG_SCRIPT="$REPO_ROOT/bin/llama-watchdog.sh"
    export TAC_TEST_TMPDIR
    TAC_TEST_TMPDIR="$(mktemp -d)"
    export WATCHDOG_MOCK_BIN="$TAC_TEST_TMPDIR/mock-bin"
    export WATCHDOG_MOCK_STATE="$TAC_TEST_TMPDIR/state"
    export SYSTEMCTL_MOCK_LOG="$TAC_TEST_TMPDIR/systemctl.log"
    export SYSTEMCTL_MOCK_STATE="$WATCHDOG_MOCK_STATE"
    mkdir -p "$WATCHDOG_MOCK_BIN" "$WATCHDOG_MOCK_STATE"

    # Mock curl: /health and /v1/models succeed only once the "healthy" marker
    # exists (set manually, or by the mock systemctl on restart).
    cat > "$WATCHDOG_MOCK_BIN/curl" <<'MOCK'
#!/usr/bin/env bash
if [[ "$*" == *"/health"* || "$*" == *"/v1/models"* ]]
then
    [[ -f "$SYSTEMCTL_MOCK_STATE/healthy" ]] && exit 0
    exit 22
fi
exit 22
MOCK
    chmod +x "$WATCHDOG_MOCK_BIN/curl"

    # Mock systemctl --user: records every call; `show` prints the unit state
    # from the active_state file; `restart` marks the unit healthy (and fails
    # if fail_restart is set); `reset-failed` records itself.
    cat > "$WATCHDOG_MOCK_BIN/systemctl" <<'MOCK'
#!/usr/bin/env bash
set -uo pipefail
if [[ "${1:-}" == "--user" ]]; then shift; fi
op="${1:-}"; shift || true
case "$op" in
    show)
        cat "$SYSTEMCTL_MOCK_STATE/active_state" 2>/dev/null || echo "inactive"
        ;;
    restart)
        echo "restart $*" >> "$SYSTEMCTL_MOCK_LOG"
        if [[ -f "$SYSTEMCTL_MOCK_STATE/fail_restart" ]]; then
            exit 1
        fi
        touch "$SYSTEMCTL_MOCK_STATE/restart_called"
        touch "$SYSTEMCTL_MOCK_STATE/healthy"
        ;;
    reset-failed)
        echo "reset-failed $*" >> "$SYSTEMCTL_MOCK_LOG"
        touch "$SYSTEMCTL_MOCK_STATE/reset_failed_called"
        ;;
    *)
        echo "unhandled: $op $*" >> "$SYSTEMCTL_MOCK_LOG"
        ;;
esac
MOCK
    chmod +x "$WATCHDOG_MOCK_BIN/systemctl"

    # Mock gpu-busy.sh: free unless the "busy" marker exists.
    cat > "$WATCHDOG_MOCK_BIN/gpu-busy" <<'MOCK'
#!/usr/bin/env bash
if [[ -f "$SYSTEMCTL_MOCK_STATE/busy" ]]; then
    echo '{"busy":true,"reasons":["mock"]}'
    exit 1
fi
echo '{"busy":false,"reasons":[]}'
exit 0
MOCK
    chmod +x "$WATCHDOG_MOCK_BIN/gpu-busy"
}

teardown_file() {
    rm -rf "${TAC_TEST_TMPDIR:-/tmp/bats-noop}"
}

setup() {
    # Reset mock state, mock log, and the watchdog lock before each test.
    : > "$SYSTEMCTL_MOCK_LOG" 2>/dev/null || true
    rm -f "$WATCHDOG_MOCK_STATE"/*
    rm -f /dev/shm/llama-watchdog.lock 2>/dev/null || true
    export PATH="$WATCHDOG_MOCK_BIN:$PATH"
    export GPU_BUSY_SH="$WATCHDOG_MOCK_BIN/gpu-busy"
}

# ─────────────────────────────────────────────────────────────────────────────
# Tests
# ─────────────────────────────────────────────────────────────────────────────

@test "integration: watchdog script exists and is executable" {
    [[ -f "$WATCHDOG_SCRIPT" ]] || return 1
    [[ -x "$WATCHDOG_SCRIPT" ]] || return 1
}

@test "integration: watchdog exits cleanly when healthy" {
    touch "$WATCHDOG_MOCK_STATE/healthy"

    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ ! -f "$WATCHDOG_MOCK_STATE/restart_called" ]]
}

@test "integration: watchdog recovers via systemctl restart when unhealthy" {
    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ -f "$WATCHDOG_MOCK_STATE/restart_called" ]]
    grep -q "restart llama-server.service" "$SYSTEMCTL_MOCK_LOG"
    [[ "$output" == *"Recovery successful"* ]]
}

@test "integration: watchdog defers restart while GPU is busy" {
    touch "$WATCHDOG_MOCK_STATE/busy"

    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ ! -f "$WATCHDOG_MOCK_STATE/restart_called" ]]
    [[ "$output" == *"deferring restart"* ]]
}

@test "integration: watchdog skips when bench lock is present" {
    touch /tmp/llm-bench.lock

    run "$WATCHDOG_SCRIPT"

    rm -f /tmp/llm-bench.lock
    [[ "$status" -eq 0 ]]
    [[ ! -f "$WATCHDOG_MOCK_STATE/restart_called" ]]
    [[ "$output" == *"Bench lock present"* ]]
}

@test "integration: watchdog skips while systemd is already activating" {
    echo "activating" > "$WATCHDOG_MOCK_STATE/active_state"

    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ ! -f "$WATCHDOG_MOCK_STATE/restart_called" ]]
    [[ "$output" == *"already activating"* ]]
}

@test "integration: watchdog resets a failed unit before restarting" {
    echo "failed" > "$WATCHDOG_MOCK_STATE/active_state"

    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ -f "$WATCHDOG_MOCK_STATE/reset_failed_called" ]]
    [[ -f "$WATCHDOG_MOCK_STATE/restart_called" ]]
    grep -q "reset-failed llama-server.service" "$SYSTEMCTL_MOCK_LOG"
}

@test "integration: watchdog exits non-zero when systemd restart fails" {
    touch "$WATCHDOG_MOCK_STATE/fail_restart"

    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 1 ]]
    [[ "$output" == *"manual intervention required"* ]]
}

@test "integration: watchdog script has version" {
    run head -10 "$WATCHDOG_SCRIPT"

    [[ "$output" == *"VERSION"* ]]
}

@test "integration: watchdog uses flock for locking" {
    run grep -c "flock" "$WATCHDOG_SCRIPT"

    [[ "$output" -gt 0 ]]
}

@test "integration: watchdog has cleanup trap" {
    run grep -c "trap.*cleanup" "$WATCHDOG_SCRIPT"

    [[ "$output" -gt 0 ]]
}

@test "integration: watchdog checks health endpoint" {
    run grep -c "/health" "$WATCHDOG_SCRIPT"

    [[ "$output" -gt 0 ]]
}

@test "integration: watchdog has timeout logic" {
    run grep -c "timeout\|max-time" "$WATCHDOG_SCRIPT"

    [[ "$output" -gt 0 ]]
}

# end of file
