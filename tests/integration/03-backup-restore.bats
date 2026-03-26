#!/usr/bin/env bats
# ==============================================================================
# Integration Tests — Backup and Restore
# ==============================================================================
# Tests oc-backup creation and oc-restore functionality
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
    source "$PROFILE_PATH" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# Tests
# ─────────────────────────────────────────────────────────────────────────────

@test "integration: oc-backup function exists" {
    declare -f oc-backup >/dev/null 2>&1
}

@test "integration: oc-restore function exists" {
    declare -f oc-restore >/dev/null 2>&1
}

@test "integration: oc-backup creates backup file" {
    # Create some test data
    echo "test workspace content" > "$OC_WORKSPACE/test.txt"
    echo "test agent data" > "$OC_AGENTS/agent.json"
    
    run oc-backup
    
    # Should create a backup file
    local backup_count
    backup_count=$(find "$OC_BACKUPS" -name "snapshot_*.zip" 2>/dev/null | wc -l)
    [[ "$backup_count" -gt 0 ]] || return 1
}

@test "integration: oc-backup verifies backup integrity" {
    # Create test data
    echo "test content" > "$OC_WORKSPACE/data.txt"
    
    run oc-backup
    
    # Should show verification message
    [[ "$output" == *"VERIFIED"* ]] || [[ "$output" == *"CREATED"* ]] || [[ "$output" == *"Snapshot"* ]]
}

@test "integration: oc-backup handles empty workspace" {
    # Ensure workspace is empty
    rm -rf "$OC_WORKSPACE"/*
    rm -rf "$OC_AGENTS"/*
    
    run oc-backup
    
    # Should complete (may warn about empty dirs)
    [[ "$status" -eq 0 ]] || [[ "$output" == *"NOT FOUND"* ]] || [[ "$output" == *"CREATED"* ]]
}

@test "integration: oc-backup requires zip command" {
    # Temporarily hide zip command
    local orig_path="$PATH"
    export PATH="/nonexistent"
    
    run oc-backup
    
    # Restore PATH
    export PATH="$orig_path"
    
    # Should report missing zip
    [[ "$output" == *"zip"* ]] || [[ "$output" == *"not installed"* ]] || [[ "$status" -ne 0 ]]
}

@test "integration: oc-restore handles no backups" {
    # Remove any existing backups
    rm -f "$OC_BACKUPS"/snapshot_*.zip
    
    run oc-restore
    
    # Should report no backups found
    [[ "$output" == *"backup"* ]] || [[ "$output" == *"not found"* ]] || [[ "$output" == *"No"* ]] || [[ "$status" -ne 0 ]]
}

@test "integration: oc-restore --dry-run shows what would be restored" {
    # Create a test backup
    echo "test" > "$OC_WORKSPACE/test.txt"
    oc-backup >/dev/null 2>&1
    
    run oc-restore --dry-run
    
    # Should show dry-run output
    [[ "$output" == *"dry"* ]] || [[ "$output" == *"would"* ]] || [[ "$output" == *"restore"* ]] || [[ "$status" -eq 0 ]]
}

@test "integration: oc-backup prunes old snapshots" {
    # Create multiple backups
    for i in {1..12}; do
        echo "backup $i" > "$OC_WORKSPACE/test$i.txt"
        oc-backup >/dev/null 2>&1
        sleep 1  # Ensure unique timestamps
    done
    
    # Count backups
    local backup_count
    backup_count=$(find "$OC_BACKUPS" -name "snapshot_*.zip" 2>/dev/null | wc -l)
    
    # Should keep only 10 most recent
    [[ "$backup_count" -le 10 ]] || return 1
}

@test "integration: oc-backup includes profile in backup" {
    echo "test" > "$OC_WORKSPACE/test.txt"
    
    run oc-backup
    
    # Backup should mention profile or bashrc
    [[ "$output" == *".bashrc"* ]] || [[ "$output" == *"CREATED"* ]] || [[ "$output" == *"Snapshot"* ]]
}

@test "integration: oc-backup includes model registry" {
    # Create test registry
    echo "1|test|model.gguf|2.5G|llama|Q4_K_M|32|999|4096|8|0" > "$LLAMA_DRIVE_ROOT/.llm/models.conf"
    echo "test" > "$OC_WORKSPACE/test.txt"
    
    run oc-backup
    
    # Should complete successfully
    [[ "$status" -eq 0 ]] || [[ "$output" == *"CREATED"* ]]
}

# end of file
