#!/usr/bin/env bats
# ==============================================================================
# Unit — keeping the gh keyring fall-through closed over time
# ==============================================================================
# Two durability guards for the 2026-09-23 fix (commit 37931f6f):
#
#   * `oc-health`'s journal row (B) — a token-less `gh` reaching the system
#     credential store is the signature of the fall-through coming back. The scan
#     is the detection half of a hole that cannot be closed in-repo (a caller that
#     bypasses PATH), so it must not stay silent when it fires.
#   * the boot unit (D) — `/dev/shm` is wiped by a reboot, so the bridged names are
#     absent from the systemd user manager until something re-bridges. The unit is
#     only useful if its ExecStart still resolves, so that linkage is pinned here.
#
# Hermetic: the journal is a fixture behind a stub `journalctl`; no journal is read
# and no unit is started.
#
# NOT ASSERTED, deliberately: the "journalctl unavailable" branch of the detector.
# Making `command -v journalctl` fail needs a PATH with no /usr/bin, which also
# removes the tools `__tac_info` needs to print anything at all — so the sandbox
# cannot exercise it without becoming a test of the sandbox.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    MOCK_BIN_DIR="$BATS_TEST_TMPDIR/mocks"
    mkdir -p "$MOCK_BIN_DIR"
    export PATH="$MOCK_BIN_DIR:$PATH"

    # The journal is a fixture; the stub ignores journalctl's own arguments.
    cat > "$MOCK_BIN_DIR/journalctl" <<'MOCK'
#!/usr/bin/env bash
cat "${JOURNAL_FIXTURE:-/dev/null}"
MOCK
    chmod +x "$MOCK_BIN_DIR/journalctl"

    # shellcheck source=scripts/01-constants.sh
    source "$REPO_ROOT/scripts/01-constants.sh"
    # shellcheck source=scripts/02-error-handling.sh
    source "$REPO_ROOT/scripts/02-error-handling.sh"
    # shellcheck source=scripts/03-design-tokens.sh
    source "$REPO_ROOT/scripts/03-design-tokens.sh"
    # shellcheck source=scripts/05-ui-engine.sh
    source "$REPO_ROOT/scripts/05-ui-engine.sh"
    # shellcheck source=scripts/09e-oc-health.sh
    source "$REPO_ROOT/scripts/09e-oc-health.sh"
}

@test "keyring watch: a gh activation in the journal is named, with the count and the time" {
    export JOURNAL_FIXTURE="$BATS_TEST_TMPDIR/journal.txt"
    cat > "$JOURNAL_FIXTURE" <<'LOG'
Sep 23 10:52:57 XPS15-9520 dbus-daemon[1309]: [session uid=1000 pid=1309] Activating service name='org.freedesktop.secrets' requested by ':1.777' (uid=1000 pid=52913 comm="gh auth token --hostname github.com" label="kernel")
Sep 23 11:20:01 XPS15-9520 dbus-daemon[1309]: [session uid=1000 pid=1309] Activating service name='org.freedesktop.secrets' requested by ':1.900' (uid=1000 pid=60001 comm="gh api user" label="kernel")
LOG

    run __oc_gh_keyring_recurrence
    [ "$status" -eq 0 ]
    [[ "$output" == *"Token-less gh"* ]]
    [[ "$output" == *"2 keyring activation(s) in 7 days"* ]]
    # The timestamp of the LAST hit, which is how a reader finds it again.
    [[ "$output" == *"Sep 23 11:20:01"* ]]
}

@test "keyring watch: a non-gh activation is not a hit" {
    export JOURNAL_FIXTURE="$BATS_TEST_TMPDIR/journal.txt"
    cat > "$JOURNAL_FIXTURE" <<'LOG'
Sep 23 11:20:01 XPS15-9520 dbus-daemon[1309]: [session uid=1000 pid=1309] Activating service name='org.freedesktop.secrets' requested by ':1.900' (uid=1000 pid=60001 comm="secret-tool" label="kernel")
LOG

    run __oc_gh_keyring_recurrence
    [ "$status" -eq 0 ]
    [[ "$output" == *"none in 7 days"* ]]
    [[ "$output" != *"activation(s)"* ]]
}

@test "keyring watch: an empty journal reports none, not an error" {
    export JOURNAL_FIXTURE="$BATS_TEST_TMPDIR/empty.txt"
    : > "$JOURNAL_FIXTURE"

    run __oc_gh_keyring_recurrence
    [ "$status" -eq 0 ]
    [[ "$output" == *"none in 7 days"* ]]
}

@test "boot unit: ExecStart reaches the console dispatch, and is a oneshot at boot" {
    local unit="$REPO_ROOT/systemd/openclaw-refresh-keys.service"
    [ -f "$unit" ]
    grep -q '^Type=oneshot$' "$unit"
    grep -q '^ExecStart=%h/.local/bin/tac-exec oc refresh-keys$' "$unit"
    grep -q '^WantedBy=default.target$' "$unit"

    # The linkage that makes the ExecStart real: the launcher exists in the repo,
    # and the `oc` dispatch table routes `refresh-keys` to the function. The case
    # arms are column-aligned, so match on whitespace rather than one literal space.
    [ -x "$REPO_ROOT/bin/tac-exec" ]
    grep -Eq '^[[:space:]]*refresh-keys\)[[:space:]]+oc-refresh-keys\b' \
        "$REPO_ROOT/scripts/09c-oc-core.sh"
}

@test "boot unit: install.sh installs every file in systemd/ (so the unit ships)" {
    # The unit is only present after an install because install.sh links systemd/*;
    # this pins that contract rather than the file list, so a new unit needs no
    # second edit here.
    grep -q 'for f in "$REPO"/systemd/\*' "$REPO_ROOT/install.sh"
    grep -q 'link "systemd/\$_bn" "\$HOME/.config/systemd/user/\$_bn"' "$REPO_ROOT/install.sh"
}
