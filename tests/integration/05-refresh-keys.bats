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
    rm -f /dev/shm/tac_pwsh_bridge_warned

    # Mock openclaw so SecretRef sync never touches the real config during tests.
    # Capture the `config patch --stdin` payload so tests can assert SecretRefs
    # without invoking the real CLI (refs are batched into one patch call).
    export OC_MOCK_LOG="$TAC_TEST_TMPDIR/openclaw_calls.log"
    export OC_MOCK_PATCH_FILE="$TAC_TEST_TMPDIR/openclaw_patch_stdin.json"
    __mock_command_local openclaw "if [ \"\$*\" = 'config patch --stdin' ]; then cat > \"$OC_MOCK_PATCH_FILE\"; fi; echo \"OPENCLAW_CALL: \$*\" >> \"$OC_MOCK_LOG\"; exit 0"

    # Mock systemctl so we don't touch the real systemd user manager or unit file.
    export SYSTEMCTL_LOG="$TAC_TEST_TMPDIR/systemctl_calls.log"
    __mock_command_local systemctl "echo \"SYSTEMCTL_CALL: \$*\" >> \"$SYSTEMCTL_LOG\"; exit 0"

    # Source only required modules for oc-refresh-keys to keep the test harness stable.
    # shellcheck disable=SC1090
    source "$REPO_ROOT/scripts/01-constants.sh"
    # shellcheck disable=SC1090
    source "$REPO_ROOT/scripts/02-error-handling.sh"
    # shellcheck disable=SC1090
    source "$REPO_ROOT/scripts/03-design-tokens.sh"
    # shellcheck disable=SC1090
    source "$REPO_ROOT/scripts/05-ui-engine.sh"
    # shellcheck disable=SC1090
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
