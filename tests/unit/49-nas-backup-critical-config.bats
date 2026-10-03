#!/usr/bin/env bats
# ==============================================================================
# Unit — NAS backup-critical-config: a failed copy must not read as success
# ==============================================================================
# WHY THIS EXISTS (AUDIT-2026-10-02, card 388e5001): backup_one() returned 0
# unconditionally and the script ended with an unconditional
# `echo "Backed up to …"`, so a caller checking only $? saw success even when
# every copy had failed.  The failures were named in the middle of the output,
# but the exit status — the thing a cron job or a monitor reads — said "fine".
#
# The property asserted here is the exit status, because that is the signal that
# lies.  A case that only grepped for "SKIPPED" would have passed against the
# broken script.
#
# HERMETIC: BACKUP_DIR is sandboxed via the env override, and `cp` is a PATH shim
# whose exit code is fixed per case, so the outcome does not depend on which of
# these NAS paths happen to exist on the machine running the suite.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export REPO_ROOT
    SCRIPT="$REPO_ROOT/nas/butler/nas-hardening/backup-critical-config.sh"
    export SCRIPT
    SANDBOX="$(mktemp -d)"
    export SANDBOX
    export BACKUP_DIR="$SANDBOX/backups"
    mkdir -p "$SANDBOX/shim"
}

teardown() {
    rm -rf "$SANDBOX"
}

# _shim_cp <rc> — put a `cp` on PATH that always exits <rc>, fixing every copy's
# outcome regardless of the host.
_shim_cp() {
    printf '#!/bin/sh\nexit %s\n' "$1" > "$SANDBOX/shim/cp"
    chmod +x "$SANDBOX/shim/cp"
}

@test "backup-critical-config: a failed copy exits non-zero and does not claim success" {
    _shim_cp 1

    run env PATH="$SANDBOX/shim:$PATH" sh "$SCRIPT"

    [ "$status" -ne 0 ]
    [[ "$output" == *"FAILED"* ]]
    # The misleading line must be GONE on the failure path, not merely followed
    # by another one — the old script printed it and exited 0.
    [[ "$output" != *"Backed up to"* ]]
}

@test "backup-critical-config: the all-copy control exits zero and reports the backup" {
    # Catches the opposite regression: a "fix" that always exits non-zero would
    # make a healthy backup indistinguishable from a broken one.
    _shim_cp 0

    run env PATH="$SANDBOX/shim:$PATH" sh "$SCRIPT"

    [ "$status" -eq 0 ]
    [[ "$output" == *"Backed up to"* ]]
    [[ "$output" != *"FAILED"* ]]
}

# end of file
