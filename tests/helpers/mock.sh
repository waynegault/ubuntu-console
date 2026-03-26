#!/usr/bin/env bash
# ==============================================================================
# Mock Framework for External Commands
# ==============================================================================
# Purpose: Enable testing of functions that depend on external tools
# (openclaw, llama-server, docker, etc.) without requiring them installed.
#
# Usage in test files:
#   source "$REPO_ROOT/tests/helpers/mock.sh"
#
#   @test "test with mocked openclaw" {
#       mock_command openclaw "echo 'mocked output'; return 0"
#       run my_function
#       [[ "$output" == *"mocked output"* ]]
#       unmock_command openclaw
#   }
#
# AI INSTRUCTION: Increment version on significant changes.
# Module Version: 1
# ==============================================================================

# Store original command paths
declare -A __MOCK_ORIGINAL_PATHS=()
declare -A __MOCK_ACTIVE=()

# Create mock directory in temp location
MOCK_BIN_DIR="${MOCK_BIN_DIR:-/tmp/tac_mocks_$$}"
mkdir -p "$MOCK_BIN_DIR"

# ---------------------------------------------------------------------------
# mock_command — Replace a command with a mock implementation
# Usage: mock_command <command_name> <bash_code>
# Example: mock_command openclaw "echo 'mocked'; return 0"
# ---------------------------------------------------------------------------
function mock_command() {
    local cmd="$1"
    local behavior="$2"
    
    # Store original path if not already stored
    if [[ -z "${__MOCK_ORIGINAL_PATHS[$cmd]:-}" ]]
    then
        __MOCK_ORIGINAL_PATHS[$cmd]=$(command -v "$cmd" 2>/dev/null || echo "")
    fi
    
    # Create mock script
    local mock_script="$MOCK_BIN_DIR/$cmd"
    cat > "$mock_script" << MOCK_EOF
#!/usr/bin/env bash
# Mock implementation of $cmd
$behavior
MOCK_EOF
    chmod +x "$mock_script"
    
    # Mark as active
    __MOCK_ACTIVE[$cmd]=1
    
    # Prepend mock dir to PATH (only once)
    if [[ ":$PATH:" != *":$MOCK_BIN_DIR:"* ]]
    then
        export PATH="$MOCK_BIN_DIR:$PATH"
    fi
}

# ---------------------------------------------------------------------------
# unmock_command — Restore original command
# Usage: unmock_command <command_name>
# ---------------------------------------------------------------------------
function unmock_command() {
    local cmd="$1"
    
    # Remove mock script
    rm -f "$MOCK_BIN_DIR/$cmd"
    
    # Mark as inactive
    unset "__MOCK_ACTIVE[$cmd]"
    
    # Restore original if it existed
    if [[ -n "${__MOCK_ORIGINAL_PATHS[$cmd]:-}" ]]
    then
        # Original will be found via normal PATH resolution
        unset "__MOCK_ORIGINAL_PATHS[$cmd]"
    fi
    
    # Clean up mock dir if no more mocks
    if [[ ${#__MOCK_ACTIVE[@]} -eq 0 ]]
    then
        cleanup_mocks
    fi
}

# ---------------------------------------------------------------------------
# unmock_all — Remove all active mocks
# Usage: unmock_all
# ---------------------------------------------------------------------------
function unmock_all() {
    for cmd in "${!__MOCK_ACTIVE[@]}"
    do
        unmock_command "$cmd"
    done
    cleanup_mocks
}

# ---------------------------------------------------------------------------
# cleanup_mocks — Remove mock directory and restore PATH
# Usage: cleanup_mocks
# ---------------------------------------------------------------------------
function cleanup_mocks() {
    rm -rf "$MOCK_BIN_DIR"
    
    # Remove mock dir from PATH
    export PATH="${PATH//$MOCK_BIN_DIR:/}"
}

# ---------------------------------------------------------------------------
# is_mocked — Check if a command is currently mocked
# Usage: if is_mocked openclaw; then ...
# ---------------------------------------------------------------------------
function is_mocked() {
    local cmd="$1"
    [[ -n "${__MOCK_ACTIVE[$cmd]:-}" ]]
}

# ---------------------------------------------------------------------------
# mock_file — Create a mock file with specified content
# Usage: mock_file <path> <content>
# ---------------------------------------------------------------------------
function mock_file() {
    local path="$1"
    local content="$2"
    
    mkdir -p "$(dirname "$path")"
    echo "$content" > "$path"
}

# ---------------------------------------------------------------------------
# mock_json_response — Create a mock JSON response file
# Usage: mock_json_response <file> <key> <value> ...
# Example: mock_json_response /tmp/response.json status ok count 5
# ---------------------------------------------------------------------------
function mock_json_response() {
    local file="$1"
    shift
    
    local json="{"
    local first=1
    while [[ $# -ge 2 ]]
    do
        local key="$1"
        local value="$2"
        shift 2
        
        (( first )) || json+=","
        first=0
        json+="\"$key\":\"$value\""
    done
    json+="}"
    
    mock_file "$file" "$json"
}

# ---------------------------------------------------------------------------
# expect_call — Record and verify command calls
# Usage: 
#   expect_call_setup
#   expect_call openclaw 2  # expect 2 calls
#   # ... run code ...
#   expect_call_verify
# ---------------------------------------------------------------------------
declare -A __MOCK_CALL_COUNTS=()

function expect_call_setup() {
    __MOCK_CALL_COUNTS=()
}

function expect_call() {
    local cmd="$1"
    local expected="$2"
    __MOCK_CALL_COUNTS[$cmd]="$expected:0"
    
    # Wrap the mock to count calls
    if is_mocked "$cmd"
    then
        local current_mock
        current_mock=$(cat "$MOCK_BIN_DIR/$cmd" | tail -n +3)
        mock_command "$cmd" "
(( __MOCK_CALL_COUNTS[$cmd]++ )) || true
$current_mock
"
    fi
}

function expect_call_verify() {
    local failed=0
    for cmd in "${!__MOCK_CALL_COUNTS[@]}"
    do
        local spec="${__MOCK_CALL_COUNTS[$cmd]}"
        local expected="${spec%%:*}"
        local actual="${spec##*:}"
        
        if [[ "$actual" -ne "$expected" ]]
        then
            echo "FAIL: $cmd called $actual times, expected $expected" >&2
            failed=1
        fi
    done
    return $failed
}

# Cleanup on exit
trap cleanup_mocks EXIT

# end of file
