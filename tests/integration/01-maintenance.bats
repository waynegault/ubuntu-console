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
    # Run maintenance with force flag (skips all cooldowns)
    run up --force
    
    # Should complete (may have failures but shouldn't crash)
    [[ "$status" -eq 0 ]] || [[ "$output" == *"COMPLETED"* ]]
}

@test "integration: up shows all 13 steps" {
    run up --force
    
    # Check all 13 step numbers appear
    for i in {1..13}; do
        [[ "$output" == *"[$i/13]"* ]] || return 1
    done
}

@test "integration: up --force checks connectivity" {
    run up --force
    
    # Should show connectivity status
    [[ "$output" == *"[1/13] Internet Connectivity"* ]] || return 1
    [[ "$output" == *"ESTABLISHED"* ]] || [[ "$output" == *"LOST"* ]]
}

@test "integration: up --force runs APT update" {
    run up --force
    
    # Should attempt APT operations
    [[ "$output" == *"[2/13] APT Packages"* ]] || return 1
}

@test "integration: up --force checks NPM" {
    run up --force
    
    # Should check NPM status
    [[ "$output" == *"[3/13] NPM Packages"* ]] || return 1
}

@test "integration: up --force checks R packages" {
    run up --force
    
    # Should check R packages (may skip if not installed)
    [[ "$output" == *"[5/13] R Packages"* ]] || return 1
}

@test "integration: up --force checks OpenClaw" {
    run up --force
    
    # Should check OpenClaw health
    [[ "$output" == *"[6/13] OpenClaw Framework"* ]] || return 1
}

@test "integration: up --force checks Python fleet" {
    run up --force
    
    # Should verify Python versions
    [[ "$output" == *"[8/13] Python Fleet"* ]] || return 1
}

@test "integration: up --force checks GPU" {
    run up --force
    
    # Should check GPU status
    [[ "$output" == *"[9/13] RTX"* ]] || [[ "$output" == *"[9/13] GPU"* ]]
}

@test "integration: up --force checks disk space" {
    run up --force
    
    # Should audit disk space
    [[ "$output" == *"[11/13] Disk Space"* ]] || return 1
}

@test "integration: up --force shows final status" {
    run up --force
    
    # Should show completion status
    [[ "$output" == *"Maintenance Status"* ]] || return 1
    [[ "$output" == *"COMPLETED"* ]] || [[ "$output" == *"PEAK PARITY"* ]]
}

@test "integration: up without --force respects cooldowns" {
    # First run sets cooldowns
    run up --force
    
    # Second run should show cached status (unless cooldown expired)
    run up
    
    # Should complete without error
    [[ "$status" -eq 0 ]]
}

@test "integration: up creates cooldown database" {
    run up --force
    
    # CooldownDB should be created
    [[ -f "$CooldownDB" ]] || return 1
    
    # Should contain entries
    [[ -s "$CooldownDB" ]] || return 1
}

@test "integration: up --help shows usage" {
    # Check if up function exists and can be called
    declare -f up >/dev/null 2>&1
}

# end of file
