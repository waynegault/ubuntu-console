#!/usr/bin/env bats
# ==============================================================================
# Integration Tests — Backup and Restore
# ==============================================================================
# Behavioural tests for oc-backup / oc-restore: build a sandboxed storage root
# and backups dir, run the real functions, and assert on the resulting snapshot
# and restore behaviour — not on substrings of the functions' own bodies.
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
    # Load all profile functions via env.sh (the non-interactive library loader)
    source "$REPO_ROOT/env.sh" 2>/dev/null || true
}

# _make_storage — build the sandboxed "storage root" that oc-backup archives
# (AI_STORAGE_ROOT) plus a fresh OC_BACKUPS. Sets the global STORAGE_ROOT.
# MUST be called directly (not via $(...) — exports would not propagate).
STORAGE_ROOT=""
_make_storage() {
    STORAGE_ROOT="$TAC_TEST_TMPDIR/ai"
    rm -rf "$STORAGE_ROOT"
    mkdir -p "$STORAGE_ROOT/.openclaw/workspace"
    echo "workspace payload" > "$STORAGE_ROOT/.openclaw/workspace/note.txt"
    echo "# fake bashrc" > "$STORAGE_ROOT/.bashrc"
    export AI_STORAGE_ROOT="$STORAGE_ROOT"
    export OC_BACKUPS="$TAC_TEST_TMPDIR/backups"
    rm -rf "$OC_BACKUPS"
    return 0
}

_newest_snapshot() {
    ls -1t "$OC_BACKUPS"/snapshot_*.zip 2>/dev/null | head -1
}

# ─────────────────────────────────────────────────────────────────────────────
# Existence
# ─────────────────────────────────────────────────────────────────────────────

@test "integration: oc-backup function exists" {
    declare -f oc-backup >/dev/null 2>&1
}

@test "integration: oc-restore function exists" {
    declare -f oc-restore >/dev/null 2>&1
}

# ─────────────────────────────────────────────────────────────────────────────
# oc-backup — behaviour
# ─────────────────────────────────────────────────────────────────────────────

@test "integration: oc-backup writes a snapshot containing the workspace" {
    _make_storage
    run oc-backup
    [[ "$status" -eq 0 ]]
    local snap
    snap=$(_newest_snapshot)
    [[ -n "$snap" ]]
    unzip -l "$snap" | grep -q '\.openclaw/workspace/note\.txt'
}

@test "integration: oc-backup snapshot passes an integrity check" {
    _make_storage
    run oc-backup
    [[ "$status" -eq 0 ]]
    local snap
    snap=$(_newest_snapshot)
    [[ -n "$snap" ]]
    unzip -tq "$snap" >/dev/null 2>&1
}

@test "integration: oc-backup includes the shell profile when present" {
    _make_storage
    run oc-backup
    [[ "$status" -eq 0 ]]
    local snap
    snap=$(_newest_snapshot)
    unzip -l "$snap" | grep -qE '[[:space:]]\.bashrc$'
}

@test "integration: oc-backup prunes to the 10 most recent snapshots" {
    _make_storage
    mkdir -p "$OC_BACKUPS"
    local i
    for (( i = 0; i < 11; i++ )); do
        local f="$OC_BACKUPS/snapshot_2020010${i}_000000.zip"
        : > "$f"
        touch -d "2020-01-0$(( (i % 9) + 1 ))" "$f"
    done
    run oc-backup
    [[ "$status" -eq 0 ]]
    local count
    count=$(ls -1 "$OC_BACKUPS"/snapshot_*.zip 2>/dev/null | wc -l)
    [[ "$count" -le 10 ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# oc-restore — behaviour
# ─────────────────────────────────────────────────────────────────────────────

@test "integration: oc-restore --dry-run reports the snapshot" {
    _make_storage
    mkdir -p "$OC_BACKUPS"
    ( cd "$STORAGE_ROOT" && zip -r -q "$OC_BACKUPS/snapshot_test.zip" ".openclaw/workspace" )
    run oc-restore --dry-run
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"DRY RUN"* ]]
}

@test "integration: oc-restore --dry-run leaves current state untouched" {
    _make_storage
    mkdir -p "$OC_BACKUPS"
    ( cd "$STORAGE_ROOT" && zip -r -q "$OC_BACKUPS/snapshot_test.zip" ".openclaw/workspace" )
    local before
    before=$(cat "$STORAGE_ROOT/.openclaw/workspace/note.txt")
    run oc-restore --dry-run
    [[ "$status" -eq 0 ]]
    [[ "$(cat "$STORAGE_ROOT/.openclaw/workspace/note.txt")" == "$before" ]]
}

@test "integration: oc-restore errors when no snapshot exists" {
    _make_storage
    mkdir -p "$OC_BACKUPS"
    run oc-restore --dry-run
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"NONE FOUND"* ]]
}

@test "integration: oc-restore rejects an archive with no recognisable content" {
    _make_storage
    mkdir -p "$OC_BACKUPS" "$TAC_TEST_TMPDIR/junk"
    echo "junk" > "$TAC_TEST_TMPDIR/junk/random.txt"
    ( cd "$TAC_TEST_TMPDIR/junk" && zip -q "$OC_BACKUPS/snapshot_test.zip" "random.txt" )
    run oc-restore --dry-run
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"no recognisable content"* ]]
}

# end of file
