#!/usr/bin/env bats
# Unit test for oc-refresh-keys using mocks

setup() {
    export REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export TAC_TEST_TMPDIR="$(mktemp -d)"
    export TAC_CACHE_DIR="$TAC_TEST_TMPDIR/cache"
    mkdir -p "$TAC_CACHE_DIR"

    # Load mock helper
    source "$REPO_ROOT/tests/helpers/mock.sh"

    # Source the target script under test
    # shellcheck disable=SC1090
    source "$REPO_ROOT/scripts/09-openclaw.sh"
}

teardown() {
    unmock_all || true
    rm -rf "$TAC_TEST_TMPDIR"
}

@test "oc-refresh-keys caches matching Windows vars and calls ssh" {
    mock_command pwsh.exe "printf '%s\n' 'WIN_API_KEY=winsecret' 'WIN_PASSWORD=passw0rd' 'OTHER_VAR=ignored'"

    local nas_key="$TAC_TEST_TMPDIR/nas_key"
    mkdir -p "$(dirname "$nas_key")"
    touch "$nas_key" && chmod 600 "$nas_key"
    export OC_NAS_KEY_PATH="$nas_key"
    export OC_NAS_USER="testuser"
    export OC_NAS_HOST="nas.example"

    local ssh_log="$TAC_TEST_TMPDIR/ssh_calls.log"
    mock_command ssh "echo \"SSH_CALL: \$*\" >> \"$ssh_log\"; exit 0"

    run oc-refresh-keys
    [ "$status" -eq 0 ]

    [ -f "$TAC_CACHE_DIR/tac_win_api_keys" ]
    run grep -E '^export WIN_API_KEY=' "$TAC_CACHE_DIR/tac_win_api_keys"
    [ "$status" -eq 0 ]
    run grep -E '^export WIN_PASSWORD=' "$TAC_CACHE_DIR/tac_win_api_keys"
    [ "$status" -eq 0 ]

    run grep -c '^SSH_CALL:' "$ssh_log"
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}
