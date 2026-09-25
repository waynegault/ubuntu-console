#!/usr/bin/env bats
# ==============================================================================
# Unit — the [17/20]-family report rows: a FAILED probe is not a clean answer
# ==============================================================================
# WHY THIS EXISTS (2026-09-24): five report/probe fixes landed in 08-maintenance.sh
# (commit b064adcc) and two of the functions involved — check-graph-integrity and
# copy_path — had NO test at all, which is how they came to report a failure as a
# success in the first place:
#
#   * check-graph-integrity read three failed sqlite3 queries as 0 orphans, 0 duplicates
#     and 0 isolated nodes: a BROKEN registry reported as a CLEAN graph;
#   * copy_path printed "[Clipboard] <path>" in the SUCCESS colour whether or not
#     clip.exe existed, so a copy that never happened read as one that did;
#   * __set_cooldown rewrote the cooldown DB from a source it could not read, which
#     drops every OTHER step's cooldown;
#   * and `up` swallows a failed loopback repair, so its own "[COMPLETED WITH N
#     ISSUE(S)]" line could say 0 while 127.0.0.2 was missing.
#
# Each case asserts the ROW and the return code, because "it printed something" is not
# the property: the property is that the reader can tell the two apart.
#
# HERMETIC: HOME, OC_ROOT and the cooldown DB are sandboxed; no case touches a real
# registry, a real log or the Windows clipboard.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export REPO_ROOT
    SANDBOX="$(mktemp -d)"
    export SANDBOX
    export HOME="$SANDBOX/home"
    export TAC_TEST_TMPDIR="$SANDBOX/tac"
    export TAC_CACHE_DIR="$SANDBOX/cache"
    mkdir -p "$HOME" "$TAC_TEST_TMPDIR" "$TAC_CACHE_DIR"

    # shellcheck source=env.sh
    source "$REPO_ROOT/env.sh"

    # Stubs AFTER the source: a loader re-defines the real functions on top of anything
    # stubbed earlier.  __tac_line/__tac_info are flattened so the assertions can match
    # the status words without colour codes.
    __tac_line() { printf 'LINE %s\n' "$*"; }
    __tac_info() { printf 'INFO %s\n' "$*"; }
    __tac_header() { printf 'HEADER %s\n' "$*"; }

    # The registry the graph check reads, AFTER the source so 01-constants.sh cannot
    # win: OC_ROOT is exported by that module, and the check builds
    # "$OC_ROOT/memory/registry.sqlite" from it.
    export OC_ROOT="$SANDBOX/oc"
    mkdir -p "$OC_ROOT/memory"
    export CooldownDB="$SANDBOX/cooldowns.txt"
    touch "$CooldownDB"
}

teardown() {
    cd /
    rm -rf "$SANDBOX"
}

@test "graph-integrity: an unreadable registry is CHECK FAILED, never a clean graph" {
    # A real file at the real path, but not a database: sqlite3 refuses it, which is the
    # shape the old code read as "0 orphans / 0 duplicates / nothing to report".
    printf 'this is not a sqlite database\n' > "$OC_ROOT/memory/registry.sqlite"

    run check-graph-integrity
    [ "$status" -eq 2 ]
    [[ "$output" == *"[CHECK FAILED - the registry could not be queried]"* ]]
    [[ "$output" != *"clean"* ]]
}

@test "graph-integrity: a broken registry with --quiet still fails the check" {
    # --quiet silences the ROW, not the verdict: a caller that asked for no output must
    # still be able to see, from the exit code, that the check could not run.
    printf 'not a database either\n' > "$OC_ROOT/memory/registry.sqlite"

    run check-graph-integrity --quiet
    [ "$status" -eq 2 ]
    [[ -z "$output" ]]
}

@test "copy_path: a missing clip.exe is a reported failure, not a quiet success" {
    # An empty PATH directory as the only source of clip.exe: `command -v` finds nothing,
    # which is the state the old row mis-reported in the SUCCESS colour.
    _stub_dir="$SANDBOX/empty-bin"
    mkdir -p "$_stub_dir"
    PATH="$_stub_dir:/usr/bin:/bin" run copy_path
    [ "$status" -eq 1 ]
    [[ "$output" == *"[COPY FAILED - clip.exe unavailable or refused]"* ]]
    [[ "$output" != *"[$(pwd)]"* ]]
}

@test "copy_path: a working clip.exe still reports the copy" {
    mkdir -p "$SANDBOX/bin"
    cat > "$SANDBOX/bin/clip.exe" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
SH
    chmod +x "$SANDBOX/bin/clip.exe"

    PATH="$SANDBOX/bin:/usr/bin:/bin" run copy_path
    [ "$status" -eq 0 ]
    [[ "$output" == *"[$(pwd)]"* ]]
    [[ "$output" != *"COPY FAILED"* ]]
}

@test "cooldown: a DB that cannot be read is left alone, and says so" {
    # The rewrite is a read-modify-write, so a failed READ must not become a write: doing
    # so drops every other step's cooldown and makes apt/npm re-fire early.  chmod 000 is
    # the cheapest unreadable DB (the tests run as the owning user, not root).
    printf 'apt_index=1000\nnpm_global=2000\n' > "$CooldownDB"
    chmod 000 "$CooldownDB"

    run __set_cooldown "new_key" 3000
    [ "$status" -eq 1 ]
    [[ "$output" == *"[REWRITE SKIPPED - cannot read cooldowns.txt]"* ]]

    chmod 644 "$CooldownDB"
    run cat "$CooldownDB"
    # ...and nothing was lost.
    [[ "$output" == *"apt_index=1000"* ]]
    [[ "$output" == *"npm_global=2000"* ]]
}

@test "cooldown: the ordinary no-match read still rewrites the DB" {
    # grep exits 1 when the key is absent, which is EVERY first write — the fix must not
    # turn the healthy path into a skip.
    printf 'apt_index=1000\n' > "$CooldownDB"

    run __set_cooldown "new_key" 3000
    [ "$status" -eq 0 ]

    run cat "$CooldownDB"
    [[ "$output" == *"apt_index=1000"* ]]
    [[ "$output" == *"new_key=3000"* ]]
}

@test "up: a failed loopback repair is counted, not just printed" {
    # Static by design: the call sits inside `up`, and driving that function end to end
    # means running all 20 steps against the real box.  What is assertable is the WIRING —
    # errCount must receive the failure, or the run's own summary cannot mention it.
    grep -q '__tac_fix_loopback || errCount=$(( errCount + 1 ))' "$REPO_ROOT/scripts/08-maintenance.sh" \
        || { echo "the loopback failure is not counted into errCount"; return 1; }
    # ...and the old bare swallow must be gone, not merely joined by a second call.
    run grep -c '__tac_fix_loopback || true' "$REPO_ROOT/scripts/08-maintenance.sh"
    [ "$output" = "0" ]
}
