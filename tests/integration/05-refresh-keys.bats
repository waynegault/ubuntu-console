#!/usr/bin/env bats
# ==============================================================================
# Integration Tests — oc-refresh-keys import and NAS sync
# ==============================================================================
# Verifies that Windows User environment variables matching TOKEN/API_KEY
# are cached and that an SSH call is attempted to mirror them to the NAS.
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
    export OC_MOCK_LOG="$TAC_TEST_TMPDIR/openclaw_calls.log"
    __mock_command_local openclaw "echo \"OPENCLAW_CALL: \$*\" >> \"$OC_MOCK_LOG\"; exit 0"

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

    # Present mapped credential -> SecretRef builder invoked for that path.
    run grep -F "config set plugins.entries.google.config.webSearch.apiKey --ref-provider default --ref-source env --ref-id GEMINI_API_KEY" "$OC_MOCK_LOG"
    [ "$status" -eq 0 ]

    # Absent (no longer mapped) credential -> no ref written for that path.
    run grep -F "models.providers.qwen-token-plan.apiKey" "$OC_MOCK_LOG"
    [ "$status" -ne 0 ]
}
