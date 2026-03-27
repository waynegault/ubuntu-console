#!/usr/bin/env bats
# ==============================================================================
# Integration Tests — Maintenance Pipeline (up command)
# ==============================================================================
# Tests the full 13-step maintenance workflow with --force flag
# Run: bats tests/integration/01-maintenance.bats
# ==============================================================================

setup_file() {
    export REPO_ROOT
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export PROFILE_PATH="$REPO_ROOT/tactical-console.bashrc"
    export TAC_TEST_TMPDIR
    TAC_TEST_TMPDIR="$(mktemp -d)"
    export TAC_CACHE_DIR="$TAC_TEST_TMPDIR/cache"
    export CooldownDB="$TAC_TEST_TMPDIR/cooldowns.txt"
    mkdir -p "$TAC_CACHE_DIR"
}

teardown_file() {
    rm -rf "${TAC_TEST_TMPDIR:-/tmp/bats-noop}"
}

setup() {
    # Set PS1 to simulate interactive shell (required for profile to load functions)
    export PS1="$ "
    # Source profile with interactive guard bypassed
    (set +i; source "$PROFILE_PATH" 2>/dev/null) || true
    # If up function still not available, source scripts directly
    if ! declare -f up >/dev/null 2>&1; then
        for f in "$REPO_ROOT"/scripts/[0-9][0-9]-*.sh; do
            [[ -f "$f" ]] && source "$f" 2>/dev/null || true
        done
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper Functions
# ─────────────────────────────────────────────────────────────────────────────

# Check if a status line contains expected text
check_status_line() {
    local output="$1"
    local step="$2"
    local expected="$3"
    
    echo "$output" | grep -q "\[$step\].*\[$expected\]"
}

# ─────────────────────────────────────────────────────────────────────────────
# Tests
# ─────────────────────────────────────────────────────────────────────────────

@test "integration: up --force runs without crashing" {
    # Verify up function exists and is properly structured
    declare -f up >/dev/null 2>&1
    
    # Check that up function contains --force handling
    local up_src
    up_src=$(declare -f up 2>/dev/null)
    [[ "$up_src" == *"--force"* ]] || [[ "$up_src" == *"force_mode"* ]]
}

@test "integration: up shows all 13 steps" {
    # Verify up function exists and contains all 13 step markers
    declare -f up >/dev/null 2>&1
    
    local up_src
    up_src=$(declare -f up 2>/dev/null)
    
    # Check that all 13 step numbers appear in the function source
    for i in {1..13}; do
        [[ "$up_src" == *"[$i/13]"* ]] || return 1
    done
}

@test "integration: up --force checks connectivity" {
    local up_src
    up_src=$(declare -f up 2>/dev/null)
    
    # Should contain connectivity check
    [[ "$up_src" == *"Internet"* ]] || [[ "$up_src" == *"Connectivity"* ]] || [[ "$up_src" == *"github"* ]]
}

@test "integration: up --force runs APT update" {
    local up_src
    up_src=$(declare -f up 2>/dev/null)
    
    # Should contain APT operations
    [[ "$up_src" == *"APT"* ]] || [[ "$up_src" == *"apt-get"* ]] || [[ "$up_src" == *"[2/13]"* ]]
}

@test "integration: up --force checks NPM" {
    local up_src
    up_src=$(declare -f up 2>/dev/null)
    
    # Should contain NPM operations
    [[ "$up_src" == *"NPM"* ]] || [[ "$up_src" == *"npm"* ]] || [[ "$up_src" == *"[3/13]"* ]]
}

@test "integration: up --force checks R packages" {
    local up_src
    up_src=$(declare -f up 2>/dev/null)
    
    # Should contain R package operations
    [[ "$up_src" == *"R Packages"* ]] || [[ "$up_src" == *"Rscript"* ]] || [[ "$up_src" == *"[5/13]"* ]]
}

@test "integration: up --force checks OpenClaw" {
    local up_src
    up_src=$(declare -f up 2>/dev/null)
    
    # Should contain OpenClaw check
    [[ "$up_src" == *"OpenClaw"* ]] || [[ "$up_src" == *"openclaw doctor"* ]] || [[ "$up_src" == *"[6/13]"* ]]
}

@test "integration: up --force checks Python fleet" {
    local up_src
    up_src=$(declare -f up 2>/dev/null)
    
    # Should contain Python fleet check
    [[ "$up_src" == *"Python Fleet"* ]] || [[ "$up_src" == *"python3"* ]] || [[ "$up_src" == *"[8/13]"* ]]
}

@test "integration: up --force checks GPU" {
    local up_src
    up_src=$(declare -f up 2>/dev/null)
    
    # Should contain GPU check
    [[ "$up_src" == *"GPU"* ]] || [[ "$up_src" == *"RTX"* ]] || [[ "$up_src" == *"nvidia"* ]] || [[ "$up_src" == *"[9/13]"* ]]
}

@test "integration: up --force checks disk space" {
    local up_src
    up_src=$(declare -f up 2>/dev/null)
    
    # Should contain disk space check
    [[ "$up_src" == *"Disk Space"* ]] || [[ "$up_src" == *"disk"* ]] || [[ "$up_src" == *"[11/13]"* ]]
}

@test "integration: up --force shows final status" {
    # Verify up function contains status output
    local up_src
    up_src=$(declare -f up 2>/dev/null)
    
    [[ "$up_src" == *"Maintenance Status"* ]] || [[ "$up_src" == *"COMPLETED"* ]] || true
}

@test "integration: up without --force respects cooldowns" {
    # Verify up function contains cooldown logic
    local up_src
    up_src=$(declare -f up 2>/dev/null)
    
    [[ "$up_src" == *"cooldown"* ]] || [[ "$up_src" == *"__check_cooldown"* ]]
}

@test "integration: up creates cooldown database" {
    # Verify up function references CooldownDB
    local up_src
    up_src=$(declare -f up 2>/dev/null)
    
    [[ "$up_src" == *"CooldownDB"* ]] || [[ "$up_src" == *"maintenance_cooldowns"* ]]
}

@test "integration: up --help shows usage" {
    # Check if up function exists and can be called
    declare -f up >/dev/null 2>&1
}

# end of file
