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
    rm -rf "$MOCK_BIN_DIR"
}

@test "oc-refresh-keys imports matching Windows vars and attempts NAS sync" {
    # Arrange: capture pwsh.exe invocation and return already-filtered vars.
    local pwsh_log="$TAC_TEST_TMPDIR/pwsh_calls.log"
    __mock_command_local pwsh.exe "echo \"PWSH_CALL: \$*\" >> \"$pwsh_log\"; printf '%s\\n' 'WIN_API_KEY=winsecret' 'WIN_TOKEN=tok123'"

    # Create a fake NAS SSH key file so the script attempts SSH sync
    local nas_key="$TAC_TEST_TMPDIR/nas_key"
    mkdir -p "$(dirname "$nas_key")"
    touch "$nas_key" && chmod 600 "$nas_key"
    export OC_NAS_KEY_PATH="$nas_key"
    export OC_NAS_USER="testuser"
    export OC_NAS_HOST="nas.example"

    # Mock ssh to record invocations to a log we can inspect
    local ssh_log="$TAC_TEST_TMPDIR/ssh_calls.log"
    __mock_command_local ssh "echo \"SSH_CALL: \$*\" >> \"$ssh_log\"; exit 0"

    # Act: run oc-refresh-keys
    run oc-refresh-keys

    # Assert: function exited successfully
    [ "$status" -eq 0 ]
    local refresh_output="$output"

    # Cache file exists and contains exported matching vars
    [ -f "$TAC_CACHE_DIR/tac_win_api_keys" ]
    run grep -E '^export WIN_API_KEY=' "$TAC_CACHE_DIR/tac_win_api_keys"
    [ "$status" -eq 0 ]
    run grep -E '^export WIN_TOKEN=' "$TAC_CACHE_DIR/tac_win_api_keys"
    [ "$status" -eq 0 ]

    # Bridge command should request only TOKEN/API_KEY-style names from PowerShell
    run grep -E 'TOKEN\|API\(_\|-\)\?KEY' "$pwsh_log"
    [ "$status" -eq 0 ]

    # SSH was invoked at least once (for each matching key)
    run grep -c '^SSH_CALL:' "$ssh_log"
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]

    # The stdout should report imported variable count
    [[ "$refresh_output" == *"imported"* ]]
}

@test "oc-refresh-keys syncs OpenClaw SecretRefs only for present env credentials" {
    # Bridge returns a non-mapped var; the mapped credential is supplied via env.
    __mock_command_local pwsh.exe "printf '%s\\n' 'WIN_API_KEY=winsecret'"
    rm -f "$OC_MOCK_LOG"

    export QWEN_TOKEN_PLAN_API_KEY="test-qwen-key"
    unset GEMINI_API_KEY

    run oc-refresh-keys
    [ "$status" -eq 0 ]

    # Present mapped credential -> SecretRef builder invoked for that path.
    run grep -F "config set models.providers.qwen-token-plan.apiKey --ref-provider default --ref-source env --ref-id QWEN_TOKEN_PLAN_API_KEY" "$OC_MOCK_LOG"
    [ "$status" -eq 0 ]

    # Absent mapped credential -> no ref written for that path (no unresolved ref).
    run grep -F "plugins.entries.google.config.webSearch.apiKey" "$OC_MOCK_LOG"
    [ "$status" -ne 0 ]
}
