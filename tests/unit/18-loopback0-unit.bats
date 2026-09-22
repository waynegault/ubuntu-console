#!/usr/bin/env bats
# ==============================================================================
# Unit — systemd/system/tac-loopback0.service (boot repair for 127.0.0.2)
# ==============================================================================
# Why this unit is a SYSTEM unit: WSL2 mirrored networking does not create the
# loopback0 dummy interface, OpenClaw's node-to-node traffic needs 127.0.0.2 on
# it, and a USER unit cannot create a host interface.  Before it existed the
# repair was on-demand only (__tac_fix_loopback, via `up`), so every restart
# brought the warning back.
#
# Four properties are pinned here, each one a way the unit could look fine and
# do nothing:
#   1. something installs it (a unit only on one machine is not a repair);
#   2. systemd accepts it (a unit systemd rejects never runs);
#   3. the ip steps tolerate an interface that is already present, while the
#      verification step is NOT allowed to fail silently;
#   4. that verification actually discriminates — it fails when the address is
#      missing, so a no-op run cannot report success.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    UNIT="$REPO_ROOT/systemd/system/tac-loopback0.service"
    STUB_DIR="$BATS_TEST_TMPDIR/stub"
    mkdir -p "$STUB_DIR"
}

@test "loopback0 unit: ships in the repo and install.sh copies system units" {
    [ -f "$UNIT" ]

    # The installer is what puts it in /etc/systemd/system and enables it; without
    # that reference the unit exists only on the machine it was written on.
    run grep -q 'systemd/system' "$REPO_ROOT/install.sh"
    [ "$status" -eq 0 ]

    # And it must not be swept into the USER unit loop, which would install it
    # where it cannot create an interface.
    run grep -c 'link "systemd/$_bn" "\$HOME/.config/systemd/user/\$_bn"' "$REPO_ROOT/install.sh"
    [ "$output" = "1" ]
}

@test "loopback0 unit: systemd-analyze verify accepts it" {
    run systemd-analyze verify "$UNIT"
    [ "$status" -eq 0 ]
}

@test "loopback0 unit: the ip steps tolerate an existing interface, the guard does not" {
    # Every ExecStart is `-`-prefixed because each fails harmlessly on an
    # interface that already exists ("File exists" / "Address already
    # assigned") — and a mid-session `up` or a re-run of install.sh must not
    # leave a failed unit behind.
    run grep -c '^ExecStart=-/usr/sbin/ip ' "$UNIT"
    [ "$output" = "3" ]

    # The guard is the opposite: it is the only thing that makes those ignored
    # failures safe, so it must be able to fail the unit.
    run grep -q '^ExecStartPost=-' "$UNIT"
    [ "$status" -ne 0 ]
}

@test "loopback0 unit: the guard matches only when the address is present" {
    # Take the SHIPPED ExecStartPost command apart and point its absolute ip path
    # at a stub, so the flags exercised are the ones in the unit file rather than
    # a re-typed copy that could drift away from it.
    local guard
    guard=$(grep '^ExecStartPost=' "$UNIT")
    guard=${guard#ExecStartPost=/bin/sh -c }
    guard=${guard#\'}
    guard=${guard%\'}
    [[ "$guard" == *"grep -qF 127.0.0.2/"* ]]
    [[ "$guard" == *"/usr/sbin/ip"* ]]
    guard=${guard//\/usr\/sbin\/ip/$STUB_DIR/ip}

    cat > "$STUB_DIR/ip" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${STUB_IP_OUTPUT:-}"
STUB
    chmod +x "$STUB_DIR/ip"

    # Absent — the state a fresh boot starts in.  The guard must FAIL, or the
    # unit would report success having created nothing.
    run env STUB_IP_OUTPUT='Device "loopback0" does not exist.' bash -c "$guard"
    [ "$status" -ne 0 ]

    # A neighbouring address must not satisfy it: the trailing "/" in the pattern
    # is what keeps 127.0.0.20 out.
    run env STUB_IP_OUTPUT='    inet 127.0.0.20/8 scope host loopback0' bash -c "$guard"
    [ "$status" -ne 0 ]

    # Present — the state the ExecStart steps are supposed to reach.
    run env STUB_IP_OUTPUT='    inet 127.0.0.2/8 scope host loopback0' bash -c "$guard"
    [ "$status" -eq 0 ]
}

# end of file
