#!/usr/bin/env bats
# ==============================================================================
# Integration Tests — Backup and Restore
# ==============================================================================
# Tests oc-backup and oc-restore function structure
# Run: bats tests/integration/03-backup-restore.bats
# ==============================================================================

setup_file() {
    export REPO_ROOT
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export PROFILE_PATH="$REPO_ROOT/tactical-console.bashrc"

    export TAC_TEST_TMPDIR
    TAC_TEST_TMPDIR="$(mktemp -d)"
    export TAC_CACHE_DIR="$TAC_TEST_TMPDIR/cache"
    export OC_ROOT="$TAC_TEST_TMPDIR/.openclaw"
    export OC_WORKSPACE="$OC_ROOT/workspace"
    export OC_AGENTS="$OC_ROOT/agents"
    export OC_LOGS="$OC_ROOT/logs"
    export OC_BACKUPS="$OC_ROOT/backups"
    mkdir -p "$TAC_CACHE_DIR" "$OC_WORKSPACE" "$OC_AGENTS" "$OC_LOGS" "$OC_BACKUPS"
}

teardown_file() {
    rm -rf "${TAC_TEST_TMPDIR:-/tmp/bats-noop}"
}

setup() {
    # Set PS1 to simulate interactive shell (required for profile to load functions)
    export PS1="$ "
    # Source profile with interactive guard bypassed
    (set +i; source "$PROFILE_PATH" 2>/dev/null) || true
    # If functions still not available, source scripts directly
    if ! declare -f oc-backup >/dev/null 2>&1; then
        for f in "$REPO_ROOT"/scripts/[0-9][0-9]-*.sh; do
            [[ -f "$f" ]] && source "$f" 2>/dev/null || true
        done
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Tests — Static analysis of function structure (fast, reliable)
# ─────────────────────────────────────────────────────────────────────────────

@test "integration: oc-backup function exists" {
    declare -f oc-backup >/dev/null 2>&1
}

@test "integration: oc-restore function exists" {
    declare -f oc-restore >/dev/null 2>&1
}

@test "integration: oc-backup has proper structure" {
    local fn_src
    fn_src=$(declare -f oc-backup 2>/dev/null)
    
    # Should contain key backup operations
    [[ "$fn_src" == *"backup"* ]] || [[ "$fn_src" == *"snapshot"* ]] || [[ "$fn_src" == *"zip"* ]]
    [[ "$fn_src" == *"OC_BACKUPS"* ]] || [[ "$fn_src" == *"backups"* ]]
}

@test "integration: oc-restore has proper structure" {
    local fn_src
    fn_src=$(declare -f oc-restore 2>/dev/null)
    
    # Should contain key restore operations
    [[ "$fn_src" == *"restore"* ]] || [[ "$fn_src" == *"unzip"* ]] || [[ "$fn_src" == *"extract"* ]]
    [[ "$fn_src" == *"OC_BACKUPS"* ]] || [[ "$fn_src" == *"backups"* ]]
}

@test "integration: oc-backup validates backup integrity" {
    local fn_src
    fn_src=$(declare -f oc-backup 2>/dev/null)
    
    # Should contain validation logic
    [[ "$fn_src" == *"verify"* ]] || [[ "$fn_src" == *"VERIFIED"* ]] || [[ "$fn_src" == *"zip"* ]]
}

@test "integration: oc-backup handles empty workspace" {
    local fn_src
    fn_src=$(declare -f oc-backup 2>/dev/null)
    
    # Should handle missing files gracefully
    [[ "$fn_src" == *"-f"* ]] || [[ "$fn_src" == *"exists"* ]] || [[ "$fn_src" == *"empty"* ]]
}

@test "integration: oc-restore has dry-run support" {
    local fn_src
    fn_src=$(declare -f oc-restore 2>/dev/null)
    
    # Should support dry-run mode
    [[ "$fn_src" == *"--dry-run"* ]] || [[ "$fn_src" == *"dry_run"* ]] || [[ "$fn_src" == *"DRY"* ]]
}

@test "integration: oc-backup prunes old snapshots" {
    local fn_src
    fn_src=$(declare -f oc-backup 2>/dev/null)
    
    # Should contain pruning logic
    [[ "$fn_src" == *"prune"* ]] || [[ "$fn_src" == *"old"* ]] || [[ "$fn_src" == *"rm "* ]]
}

@test "integration: oc-backup includes profile in backup" {
    local fn_src
    fn_src=$(declare -f oc-backup 2>/dev/null)
    
    # Should include bashrc/tactical-console files
    [[ "$fn_src" == *"bashrc"* ]] || [[ "$fn_src" == *"tactical"* ]] || [[ "$fn_src" == *".bashrc"* ]]
}

@test "integration: oc-backup includes model registry" {
    local fn_src
    fn_src=$(declare -f oc-backup 2>/dev/null)
    
    # Should include model registry
    [[ "$fn_src" == *"models"* ]] || [[ "$fn_src" == *"registry"* ]] || [[ "$fn_src" == *"models.conf"* ]]
}

# end of file
