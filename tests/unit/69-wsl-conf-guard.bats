#!/usr/bin/env bats
# ==============================================================================
# Unit — scripts/14-wsl-extras.sh: __tac_ensure_wsl_conf
# ==============================================================================
# WHY THIS EXISTS.  /etc/wsl.conf is the only carrier of `[boot] systemd=true`, so a
# truncation there boots the box with WSL's own init and NOTHING supervised (measured
# 2026-10-08: Gateway, 36 user units and three CI listeners all down, and no systemd
# meant no loopback0 either).  The guard added for it (commit 6e0b4503) was proved once
# by hand and never committed as a test, and on 2026-10-22 it failed twice over, in
# every interactive shell on this distro:
#
#   1. It required one FIXED value (`generateResolvConf = false`) while the live file
#      held `true` — set deliberately at 03:00 the same day with `dnsTunneling=true`,
#      where WSL MUST keep writing /etc/resolv.conf or DNS and the tailnet search
#      domain go stale.  So a correct file looked broken at every shell start.
#   2. Its before-copy was written as "$_conf.bak-<ts>", i.e. into root-owned /etc,
#      so a non-root shell could never create it.  The guard then aborted before
#      repairing anything, which is why the warning repeated instead of clearing.
#
# The expectations below come from that requirement — the three keys must survive, the
# before-copy must be readable by this user, and a correct file must be LEFT ALONE —
# not from the function's output.
#
# FALSIFICATION.  Case 1 fails against the pre-fix guard (it warned on the live value
# and tried to repair it).  Case 2 fails against a guard pinned to either single value.
# Case 3 fails against a guard that silently does nothing, backs up into /etc, or drops
# the fleet-supervision keys.  Case 4 fails against one that writes an unparseable value
# straight back.  Case 5 fails against one that reports success for a file it never
# wrote.
#
# No /etc/wsl.conf is ever touched: TAC_WSL_CONF redirects the whole function.
# ==============================================================================

setup_file() {
    export REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
}

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export REPO_ROOT
    export HOME="$BATS_TEST_TMPDIR/home"
    export TAC_STATE_DIR="$BATS_TEST_TMPDIR/state"
    export TAC_WSL_CONF="$BATS_TEST_TMPDIR/wsl.conf"
    mkdir -p "$HOME" "$TAC_STATE_DIR"

    # shellcheck source=scripts/01-constants.sh
    source "$REPO_ROOT/scripts/01-constants.sh"

    # 01-constants.sh re-exports the REAL paths at source time, so a sandbox set only
    # above is a no-op — it must be re-asserted here or the guard writes live state.
    export HOME="$BATS_TEST_TMPDIR/home"
    export TAC_STATE_DIR="$BATS_TEST_TMPDIR/state"
    export TAC_WSL_CONF="$BATS_TEST_TMPDIR/wsl.conf"

    # Non-interactive, so 14-wsl-extras.sh's interactive guard returns immediately:
    # this defines the helpers and runs no side effects.
    # shellcheck source=scripts/14-wsl-extras.sh
    source "$REPO_ROOT/scripts/14-wsl-extras.sh"
}

@test "wsl.conf guard: a correct file with generateResolvConf = true is silent and untouched" {
    # 2026-10-22: this exact file is what the box runs (dnsTunneling=true needs WSL to
    # own /etc/resolv.conf).  Silence and an unchanged mtime/content are the fix.
    cat > "$TAC_WSL_CONF" <<'EOF'
[network]
generateResolvConf = true
[boot]
systemd=true
[interop]
appendWindowsPath = false
EOF
    local before
    before=$(sha256sum "$TAC_WSL_CONF")

    run __tac_ensure_wsl_conf

    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    [ "$(sha256sum "$TAC_WSL_CONF")" = "$before" ]
    [ ! -d "$TAC_STATE_DIR/backups" ]
}

@test "wsl.conf guard: generateResolvConf = false is also accepted (either value)" {
    # The value is a DNS policy choice, not an invariant: `false` is legitimate for an
    # operator-maintained /etc/resolv.conf.  Only the key's PRESENCE is required.
    cat > "$TAC_WSL_CONF" <<'EOF'
[network]
generateResolvConf = false
[boot]
systemd=true
[interop]
appendWindowsPath = false
EOF
    local before
    before=$(sha256sum "$TAC_WSL_CONF")

    run __tac_ensure_wsl_conf

    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    [ "$(sha256sum "$TAC_WSL_CONF")" = "$before" ]
}

@test "wsl.conf guard: the truncated file is repaired, backed up where this user can write, and reported" {
    # The 2026-10-08 shape: a bare [network] block, both fleet keys gone.
    printf '[network]\n' > "$TAC_WSL_CONF"

    run __tac_ensure_wsl_conf

    [ "$status" -eq 0 ]
    grep -qx 'systemd=true' "$TAC_WSL_CONF"
    grep -qx 'appendWindowsPath = false' "$TAC_WSL_CONF"
    grep -qE '^generateResolvConf = (true|false)$' "$TAC_WSL_CONF"

    # The before-copy must exist somewhere this user owns.  Writing it beside the
    # target (root-owned /etc) is the defect that made the guard abort forever.
    local bak
    bak=$(find "$TAC_STATE_DIR/backups" -type f -name 'wsl.conf.bak-*')
    [ -n "$bak" ]
    [ "$(wc -l < "$bak")" -eq 1 ]
    grep -qx '\[network\]' "$bak"

    [[ "$output" == *"RESTORED"* ]]
    [[ "$output" == *"systemd=true"* ]]
    [[ "$output" == *"appendWindowsPath = false"* ]]
    [[ "$output" == *"$bak"* ]]
}

@test "wsl.conf guard: a bare key with no [boot]/[interop] beyond it is repaired to WSL's default" {
    # The key is present but the sections around it are gone: still a truncation, and
    # the repair has to choose a value.  It writes `true`, WSL's own default and what
    # the current dnsTunneling setup needs — never the broken file's absence.
    cat > "$TAC_WSL_CONF" <<'EOF'
[network]
generateResolvConf = yes
EOF

    run __tac_ensure_wsl_conf

    [ "$status" -eq 0 ]
    grep -qx 'generateResolvConf = true' "$TAC_WSL_CONF"
    grep -qx 'systemd=true' "$TAC_WSL_CONF"
    grep -qx 'appendWindowsPath = false' "$TAC_WSL_CONF"
    [[ "$output" == *"unparseable generateResolvConf value"* ]]
}

@test "wsl.conf guard: an unwritable file is reported and left alone, never reported as repaired" {
    printf '[network]\n' > "$TAC_WSL_CONF"
    chmod 0444 "$TAC_WSL_CONF"

    run __tac_ensure_wsl_conf

    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot write $TAC_WSL_CONF"* ]]
    [[ "$output" != *"RESTORED"* ]]
    [ "$(cat "$TAC_WSL_CONF")" = "[network]" ]
}

# end of file
