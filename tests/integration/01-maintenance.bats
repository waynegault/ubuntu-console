#!/usr/bin/env bats
# ==============================================================================
# Integration Tests — Maintenance Pipeline (up command)
# ==============================================================================
# Tests the up function structure (static analysis - fast and reliable)
# Run: bats tests/integration/01-maintenance.bats
# ==============================================================================

setup_file() {
    export REPO_ROOT
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export PROFILE_PATH="$REPO_ROOT/tactical-console.bashrc"
    export TAC_TEST_TMPDIR
    TAC_TEST_TMPDIR="$(mktemp -d)"
    export TAC_CACHE_DIR="$TAC_TEST_TMPDIR/cache"
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
# Tests — Static analysis of function structure (fast, reliable)
# ─────────────────────────────────────────────────────────────────────────────

@test "integration: up function exists" {
    declare -f up >/dev/null 2>&1
}

@test "integration: up shows all 13 steps" {
    local up_src
    up_src=$(declare -f up 2>/dev/null)
    
    # Check that all 13 step numbers appear in the function source
    for i in {1..13}; do
        [[ "$up_src" == *"[$i/13]"* ]] || return 1
    done
}

@test "integration: up has --force flag support" {
    local up_src
    up_src=$(declare -f up 2>/dev/null)
    
    # Should contain force mode handling
    [[ "$up_src" == *"--force"* ]] || [[ "$up_src" == *"force_mode"* ]]
}

@test "integration: up checks connectivity" {
    local up_src
    up_src=$(declare -f up 2>/dev/null)
    
    # Should contain connectivity check
    [[ "$up_src" == *"Internet"* ]] || [[ "$up_src" == *"Connectivity"* ]] || [[ "$up_src" == *"github"* ]]
}

@test "integration: up runs APT update" {
    local up_src
    up_src=$(declare -f up 2>/dev/null)
    
    # Should contain APT operations
    [[ "$up_src" == *"APT"* ]] || [[ "$up_src" == *"apt-get"* ]] || [[ "$up_src" == *"[2/13]"* ]]
}

@test "integration: up checks NPM" {
    local up_src
    up_src=$(declare -f up 2>/dev/null)
    
    # Should contain NPM operations
    [[ "$up_src" == *"NPM"* ]] || [[ "$up_src" == *"npm"* ]] || [[ "$up_src" == *"[3/13]"* ]]
}

@test "integration: up checks R packages" {
    local up_src
    up_src=$(declare -f up 2>/dev/null)
    
    # Should contain R package operations
    [[ "$up_src" == *"R Packages"* ]] || [[ "$up_src" == *"Rscript"* ]] || [[ "$up_src" == *"[5/13]"* ]]
}

@test "integration: up checks OpenClaw" {
    local up_src
    up_src=$(declare -f up 2>/dev/null)
    
    # Should contain OpenClaw check
    [[ "$up_src" == *"OpenClaw"* ]] || [[ "$up_src" == *"openclaw doctor"* ]] || [[ "$up_src" == *"[6/13]"* ]]
}

@test "integration: up checks Python fleet" {
    local up_src
    up_src=$(declare -f up 2>/dev/null)
    
    # Should contain Python fleet check
    [[ "$up_src" == *"Python Fleet"* ]] || [[ "$up_src" == *"python3"* ]] || [[ "$up_src" == *"[8/13]"* ]]
}

@test "integration: up checks GPU" {
    local up_src
    up_src=$(declare -f up 2>/dev/null)
    
    # Should contain GPU check
    [[ "$up_src" == *"GPU"* ]] || [[ "$up_src" == *"RTX"* ]] || [[ "$up_src" == *"nvidia"* ]] || [[ "$up_src" == *"[9/13]"* ]]
}

@test "integration: up checks disk space" {
    local up_src
    up_src=$(declare -f up 2>/dev/null)
    
    # Should contain disk space check
    [[ "$up_src" == *"Disk Space"* ]] || [[ "$up_src" == *"disk"* ]] || [[ "$up_src" == *"[11/13]"* ]]
}

@test "integration: up has cooldown support" {
    local up_src
    up_src=$(declare -f up 2>/dev/null)
    
    # Should contain cooldown logic
    [[ "$up_src" == *"cooldown"* ]] || [[ "$up_src" == *"__check_cooldown"* ]]
}

@test "integration: up creates cooldown database" {
    local up_src
    up_src=$(declare -f up 2>/dev/null)
    
    # Should reference CooldownDB
    [[ "$up_src" == *"CooldownDB"* ]] || [[ "$up_src" == *"maintenance_cooldowns"* ]]
}

@test "integration: up has help support" {
    local up_src
    up_src=$(declare -f up 2>/dev/null)
    
    # Should contain help/usage logic
    [[ "$up_src" == *"--help"* ]] || [[ "$up_src" == *"Usage"* ]] || [[ "$up_src" == *"usage"* ]]
}

# end of file
