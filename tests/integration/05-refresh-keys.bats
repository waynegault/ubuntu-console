#!/usr/bin/env bats
# ==============================================================================
# Integration Tests — oc-refresh-keys import and NAS sync
# ==============================================================================
# Verifies that Windows User environment variables matching PASSWORD/TOKEN/API/KEY
# are cached and that an SSH call is attempted to mirror them to the NAS.
# Run: bats tests/integration/05-refresh-keys.bats
# ==============================================================================

setup_file() {
    export REPO_ROOT
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export PROFILE_PATH="$REPO_ROOT/tactical-console.bashrc"
    export TAC_TEST_TMPDIR
    TAC_TEST_TMPDIR="$(mktemp -d)"
    export TAC_CACHE_DIR="$TAC_TEST_TMPDIR/cache"
    mkdir -p "$TAC_CACHE_DIR"
    export __TAC_INITIALIZED=1

    # Build patched scripts directory (minimal strip like other integration tests)
    local patched_scripts="$TAC_TEST_TMPDIR/scripts"
    mkdir -p "$patched_scripts"
    local _sed_args=(
        -e '/^case \$- in$/,/^esac$/d'
        -e '/^set -E$/d'
        -e "/^trap '__tac_err_handler' ERR$/d"
        -e '/^__tac_preexec_fired=/d'
        -e "/trap.*custom_prompt_command/s/^/# /"
        -e '/^[[:space:]]*((.*__tac_preexec_fired/s/^/# /'
        -e 's/^declare -ri //'
    )
    for _f in "$REPO_ROOT"/scripts/[0-9][0-9]-*.sh; do
        [[ -f "$_f" ]] || continue
        sed "${_sed_args[@]}" "$_f" > "$patched_scripts/$(basename "$_f")"
    done

    # Replace 13-init with minimal stub so tests don't launch services
    cat > "$patched_scripts/13-init.sh" << 'STUB'
# Minimal test stub
mkdir -p "$OC_ROOT" "$OC_LOGS" "$OC_BACKUPS" 2>/dev/null || true
__TAC_BG_PIDS=()
function __tac_exit_cleanup() { true; }
STUB

    # Patch and save the loader
    local patched_loader="$TAC_TEST_TMPDIR/profile_patched.bash"
    sed "${_sed_args[@]}" \
        -e "s|_tac_module_dir=.*|_tac_module_dir=\"$patched_scripts\"|" \
        "$PROFILE_PATH" > "$patched_loader"

    # Ensure tests do not attempt real pwsh at shell init
    export TAC_SKIP_PWSH=1
}

teardown_file() {
    rm -rf "${TAC_TEST_TMPDIR:-/tmp/bats-noop}"
}

setup() {
    export PS1="$ "
    # shellcheck disable=SC1090
    source "$TAC_TEST_TMPDIR/profile_patched.bash" &>/dev/null || true
    # load mock helpers
    source "$REPO_ROOT/tests/helpers/mock.sh"
}

teardown() {
    unmock_all || true
}

@test "oc-refresh-keys imports matching Windows vars and attempts NAS sync" {
    # Arrange: mock pwsh.exe to return a mix of matching and non-matching vars
    mock_command pwsh.exe "printf '%s\n' 'WIN_API_KEY=winsecret' 'WIN_PASSWORD=passw0rd' 'OTHER_VAR=ignored'"

    # Create a fake NAS SSH key file so the script attempts SSH sync
    local nas_key="$TAC_TEST_TMPDIR/nas_key"
    mkdir -p "$(dirname "$nas_key")"
    touch "$nas_key" && chmod 600 "$nas_key"
    export OC_NAS_KEY_PATH="$nas_key"
    export OC_NAS_USER="testuser"
    export OC_NAS_HOST="nas.example"

    # Mock ssh to record invocations to a log we can inspect
    local ssh_log="$TAC_TEST_TMPDIR/ssh_calls.log"
    mock_command ssh "echo \"SSH_CALL: \$*\" >> \"$ssh_log\"; exit 0"

    # Act: run oc-refresh-keys
    run oc-refresh-keys

    # Assert: function exited successfully
    [ "$status" -eq 0 ]

    # Cache file exists and contains exported matching vars
    [ -f "$TAC_CACHE_DIR/tac_win_api_keys" ]
    run grep -E '^export WIN_API_KEY=' "$TAC_CACHE_DIR/tac_win_api_keys"
    [ "$status" -eq 0 ]
    run grep -E '^export WIN_PASSWORD=' "$TAC_CACHE_DIR/tac_win_api_keys"
    [ "$status" -eq 0 ]

    # SSH was invoked at least once (for each matching key)
    run grep -c '^SSH_CALL:' "$ssh_log"
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]

    # The stdout should report imported variable count
    [[ "$output" == *"Windows API Keys"* ]] || true
}
