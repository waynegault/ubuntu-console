#!/usr/bin/env bats
# ==============================================================================
# Integration Tests — oc-refresh-keys SecretRef sync
# ==============================================================================
# Verifies that oc-refresh-keys maps present env credentials to OpenClaw
# SecretRefs (one batched `config patch --stdin`) while leaving unmapped
# credentials untouched.
# Run: bats tests/integration/05-refresh-keys.bats
# ==============================================================================

setup_file() {
    export REPO_ROOT
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export TAC_TEST_TMPDIR
    TAC_TEST_TMPDIR="$(mktemp -d)"
    export TAC_CACHE_DIR="$TAC_TEST_TMPDIR/cache"
    mkdir -p "$TAC_CACHE_DIR"
}

teardown_file() {
    rm -rf "${TAC_TEST_TMPDIR:-/tmp/bats-noop}"
}

function __mock_command_local() {
    local cmd="$1"
    local behavior="$2"
    cat > "$MOCK_BIN_DIR/$cmd" << MOCK_EOF
#!/usr/bin/env bash
$behavior
MOCK_EOF
    chmod +x "$MOCK_BIN_DIR/$cmd"
}

setup() {
    export MOCK_BIN_DIR="$TAC_TEST_TMPDIR/mocks"
    mkdir -p "$MOCK_BIN_DIR"
    export PATH="$MOCK_BIN_DIR:$PATH"

    # Clear any stale pwsh bridge warning so the mock is actually tried
    # (sandboxed under TAC_CACHE_DIR — never the real /dev/shm flag).
    rm -f "$TAC_CACHE_DIR/tac_pwsh_bridge_warned"

    # Mock openclaw so SecretRef sync never touches the real config during tests.
    # Capture the `config patch --stdin` payload so tests can assert SecretRefs
    # without invoking the real CLI (refs are batched into one patch call).
    export OC_MOCK_LOG="$TAC_TEST_TMPDIR/openclaw_calls.log"
    export OC_MOCK_PATCH_FILE="$TAC_TEST_TMPDIR/openclaw_patch_stdin.json"
    __mock_command_local openclaw "if [ \"\$*\" = 'config patch --stdin' ]; then cat > \"$OC_MOCK_PATCH_FILE\"; fi; echo \"OPENCLAW_CALL: \$*\" >> \"$OC_MOCK_LOG\"; exit 0"

    # Mock systemctl so we don't touch the real systemd user manager or unit file.
    export SYSTEMCTL_LOG="$TAC_TEST_TMPDIR/systemctl_calls.log"
    __mock_command_local systemctl "echo \"SYSTEMCTL_CALL: \$*\" >> \"$SYSTEMCTL_LOG\"; exit 0"

    # Mock systemd-run so the deferred gateway restart (step 7) runs its
    # payload inline instead of creating a real transient scope on the host.
    __mock_command_local systemd-run 'while [[ "${1:-}" == --* ]]; do shift; done; exec "$@"'

    # Source only required modules for oc-refresh-keys to keep the test harness stable.
    # shellcheck source=scripts/01-constants.sh
    source "$REPO_ROOT/scripts/01-constants.sh"
    # shellcheck source=scripts/02-error-handling.sh
    source "$REPO_ROOT/scripts/02-error-handling.sh"
    # shellcheck source=scripts/03-design-tokens.sh
    source "$REPO_ROOT/scripts/03-design-tokens.sh"
    # shellcheck source=scripts/05-ui-engine.sh
    source "$REPO_ROOT/scripts/05-ui-engine.sh"
    # shellcheck source=scripts/_startup-env.sh
    source "$REPO_ROOT/scripts/_startup-env.sh"   # provides __tac_source_submodules
    # shellcheck source=scripts/09-openclaw.sh
    source "$REPO_ROOT/scripts/09-openclaw.sh"

    # Isolate OC_ROOT so tests never touch the real ~/.openclaw.
    export OC_ROOT="$TAC_TEST_TMPDIR/.openclaw"
    mkdir -p "$OC_ROOT"

    # Re-assert sandboxed paths AFTER sourcing: 01-constants.sh unconditionally
    # exports TAC_CACHE_DIR=/dev/shm and derives OC_AGENTS/ErrorLogPath from the
    # real $HOME, so without this the tests would read/write the live bridge
    # cache in /dev/shm and the real error log.
    export TAC_CACHE_DIR="$TAC_TEST_TMPDIR/cache"
    export OC_AGENTS="$OC_ROOT/agents"
    export OC_LOGS="$OC_ROOT/logs"
    export ErrorLogPath="$OC_LOGS/bash-errors.log"
    mkdir -p "$TAC_CACHE_DIR"

    # Sandbox HOME so the systemd unit path resolves inside the test sandbox
    # instead of the real unit file.
    export HOME="$TAC_TEST_TMPDIR"
    mkdir -p "$HOME/.config/systemd/user"
    cat > "$HOME/.config/systemd/user/openclaw-gateway.service" << 'UNIT'
[Service]
Environment=OPENCLAW_SERVICE_MANAGED_ENV_KEYS=GEMINI_API_KEY
UNIT

    # Keep the harness hermetic: drop anything inherited from the real shell
    # that oc-refresh-keys would act on (NAS mirror preflight, Linux-side merge
    # vars) so the tests never reach the network or depend on host env.
    unset OC_NAS_KEY_PATH OC_NAS_USER OC_NAS_HOST SSH_PASSWORD
    unset CONTEXT7_API_KEY DEVIN_API_KEY OPENCLAW_GATEWAY_TOKEN
    unset QWEN_TOKEN_PLAN_API_KEY
}

teardown() {
    rm -rf "${MOCK_BIN_DIR:-}" 2>/dev/null || true
    unset OC_NAS_KEY_PATH OC_NAS_USER OC_NAS_HOST
}

@test "oc-refresh-keys syncs OpenClaw SecretRefs only for present env credentials" {
    # Bridge returns a non-mapped var; the mapped credential is supplied via env.
    __mock_command_local pwsh.exe "printf '%s\\n' 'WIN_API_KEY=winsecret'"
    rm -f "$OC_MOCK_LOG"

    export GEMINI_API_KEY="test-gemini-key"
    unset QWEN_TOKEN_PLAN_API_KEY

    run oc-refresh-keys
    [ "$status" -eq 0 ]

    # Present mapped credential -> one batched `openclaw config patch --stdin`
    # carries the env-backed SecretRef (payload is nested JSON, not dotted paths).
    run grep -F "OPENCLAW_CALL: config patch --stdin" "$OC_MOCK_LOG"
    [ "$status" -eq 0 ]
    run grep -F '"google": {"config": {"webSearch": {"apiKey": {"source": "env", "provider": "default", "id": "GEMINI_API_KEY"' "$OC_MOCK_PATCH_FILE"
    [ "$status" -eq 0 ]

    # Absent (no longer mapped) credential -> no ref written for that path.
    run grep -F 'qwen-token-plan' "$OC_MOCK_LOG" "$OC_MOCK_PATCH_FILE"
    [ "$status" -ne 0 ]
}

@test "oc-refresh-keys preserves digits in the canonical key-name set" {
    # Regression: the canonical-names file was built with an [A-Z_]+ filter,
    # which silently truncated digit-bearing names (CONTEXT7_API_KEY -> CONTEXT)
    # and broke the pwsh-unavailable fallback that rebuilds from that list.
    __mock_command_local pwsh.exe "printf '%s\\n' 'GEMINI_API_KEY=test-gemini-key' 'CONTEXT7_API_KEY=ctx7secret'"

    export GEMINI_API_KEY="test-gemini-key"

    run oc-refresh-keys
    [ "$status" -eq 0 ]

    run grep -Fx "CONTEXT7_API_KEY" "$TAC_CACHE_DIR/tac_win_api_key_names"
    [ "$status" -eq 0 ]

    # The truncated name must not appear.
    run grep -Fx "CONTEXT" "$TAC_CACHE_DIR/tac_win_api_key_names"
    [ "$status" -ne 0 ]
}

@test "oc-refresh-keys records the deferred gateway restart outcome" {
    # Regression: step 7's outcome used to be written by the caller AFTER
    # systemd-run returned, so a caller torn down by its own restart lost the
    # record. The restart body must persist its own outcome.
    __mock_command_local pwsh.exe "printf '%s\\n' 'RESTART_PROBE_API_KEY=probe'"
    rm -f "$TAC_CACHE_DIR/tac_gateway_restart.log"

    export GEMINI_API_KEY="test-gemini-key"

    run oc-refresh-keys
    [ "$status" -eq 0 ]

    local _rlog="$TAC_CACHE_DIR/tac_gateway_restart.log"
    [ -f "$_rlog" ]
    run grep -F "started" "$_rlog"
    [ "$status" -eq 0 ]
    run grep -F "restarted" "$_rlog"
    [ "$status" -eq 0 ]
}

@test "oc-refresh-keys reports an unobserved restart from the scope's own log" {
    # A caller killed mid-restart sees no stdout. It must still report the
    # outcome, read back from the log the scope wrote for itself.
    __mock_command_local pwsh.exe "printf '%s\\n' 'TORN_DOWN_API_KEY=t'"
    __mock_command_local systemd-run 'while [[ "${1:-}" == --* ]]; do shift; done; printf "started 123 2026-01-01T00:00:00+00:00\\n" > "${!#}"'
    rm -f "$TAC_CACHE_DIR/tac_gateway_restart.log"

    export GEMINI_API_KEY="test-gemini-key"

    run oc-refresh-keys
    [ "$status" -eq 0 ]

    # The caller saw no stdout, so it read the scope's log and reported the
    # unobserved outcome rather than claiming success or losing the record.
    [[ "$output" == *"outcome unobserved"* ]]
    run grep -F "started" "$TAC_CACHE_DIR/tac_gateway_restart.log"
    [ "$status" -eq 0 ]
}

@test "oc-refresh-keys detaches the restart when the caller is inside the gateway" {
    # Regression: a gateway-hosted caller that waits on the restart stalls the
    # drain until TimeoutStopSec (5m30s) and still loses the outcome. It must
    # fire a detached transient unit and return at once instead.
    __mock_command_local pwsh.exe "printf '%s\\n' 'DETACH_PROBE_API_KEY=probe'"

    # Report the caller's own cgroup as the gateway's, so this test asserts the
    # gateway-hosted branch wherever it runs (the suite may itself be inside the
    # gateway cgroup, as it is when driven by the agent).
    export SELF_CG="$(awk -F: '/^0::/{print $3}' /proc/self/cgroup)"
    __mock_command_local systemctl 'if [[ "$*" == *"show -p ControlGroup --value openclaw-gateway.service"* ]]; then printf "%s\n" "$SELF_CG"; fi; exit 0'

    # Record how systemd-run was invoked; do NOT run the payload, standing in
    # for a transient service that is started and immediately returns.
    export SYSTEMD_RUN_LOG="$TAC_TEST_TMPDIR/systemd_run_calls.log"
    rm -f "$SYSTEMD_RUN_LOG"
    __mock_command_local systemd-run "echo \"SYSTEMD_RUN: \$*\" >> \"$SYSTEMD_RUN_LOG\"; exit 0"

    export GEMINI_API_KEY="test-gemini-key"

    run oc-refresh-keys
    [ "$status" -eq 0 ]

    # Assert the message first: every later `run` overwrites $output.
    [[ "$output" == *"restart issued (detached"* ]]

    # Detached: a transient --unit, never a blocking --scope.
    run grep -F -- "--unit=" "$SYSTEMD_RUN_LOG"
    [ "$status" -eq 0 ]
    run grep -F -- "--scope" "$SYSTEMD_RUN_LOG"
    [ "$status" -ne 0 ]

    # The service cannot see openclaw without the caller's PATH.
    run grep -F -- "--setenv=PATH=" "$SYSTEMD_RUN_LOG"
    [ "$status" -eq 0 ]
}
