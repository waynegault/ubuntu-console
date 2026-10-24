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

# ==============================================================================
# 13-init's loopback0 notice — "not created yet" is not "missing"
# ==============================================================================
# Measured 2026-10-22: boot 22:51:58, tac-loopback0.service finished 22:52:23,
# and the interactive shells started at 22:52:10 / 22:52:12 — inside the unit's
# start window.  The absence was real at that instant, and the notice stayed on
# screen long after the interface existed, which reads as a fault that never
# cleared.  The split the fix draws:
#
#   boot still in progress  -> "not created yet"   (a race; nothing to repair)
#   boot finished           -> the alarm           (a genuine absence)
#   state unreadable, PID 1 systemd -> "not created yet"  (still the race)
#   state unreadable, no systemd    -> the alarm           (nothing will create it)
#
# The third line is the 2026-10-24 defect: boot 19:02:56, the unit ran 19:03:43,
# "Startup finished in 53.181s" at 19:03:49, and a shell started 19:03:06 — the
# manager was starting, yet the banner claimed "missing", because the probe had
# returned nothing usable and `else` turned "could not ask" into a measurement.
#
# Each case drives the REAL scripts/13-init.sh with `ip`, `systemctl` and `ps`
# stubs on PATH and HOME in the sandbox, so the module's own state dirs are
# throwaway.
# ==============================================================================

# _write_stubs — `ip` answers the link question, `systemctl` reports the boot
# state, `ps` reports PID 1 (13-init reads it only to classify an unreadable
# state, and the stub is what lets a case pin which init was booted).
_write_stubs() {
    cat > "$STUB_DIR/ip" <<'STUB'
#!/usr/bin/env bash
# Absent: every query fails.  Present: the link query succeeds AND the address
# query prints the address — the module has two branches, so a stub that only
# answers the first would make the "interface exists" control report the address
# as missing instead of staying quiet.
if [[ "${STUB_LINK_PRESENT:-0}" != "1" ]]; then
    exit 1
fi
if [[ "${1:-}" == "addr" ]]; then
    printf '    inet 127.0.0.2/8 scope host loopback0\n'
fi
exit 0
STUB
    cat > "$STUB_DIR/systemctl" <<'STUB'
#!/usr/bin/env bash
if [[ -n "${STUB_SYSTEM_STATE:-}" ]]; then
    printf '%s\n' "$STUB_SYSTEM_STATE"
fi
exit "${STUB_SYSTEM_EXIT:-0}"
STUB
    cat > "$STUB_DIR/ps" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${STUB_PID1_COMM:-systemd}"
STUB
    chmod +x "$STUB_DIR/ip" "$STUB_DIR/systemctl" "$STUB_DIR/ps"
}

# _run_init [NAME=VALUE...] — source the real module in a throwaway environment.
# Errexit is enabled in this shell, and the module's own systemctl probe is
# errexit-safe by construction (its `if` guard), so the child needs no -e/-u.
_run_init() {
    _write_stubs
    mkdir -p "$BATS_TEST_TMPDIR/home" "$BATS_TEST_TMPDIR/oc" "$BATS_TEST_TMPDIR/oc-workspace"
    env -u __TAC_INITIALIZED -u __TAC_DISPLAY_BANNER \
        HOME="$BATS_TEST_TMPDIR/home" \
        PATH="$STUB_DIR:$PATH" \
        BASH_COMPLETION_SCRIPT= \
        OC_ROOT="$BATS_TEST_TMPDIR/oc" \
        OC_LOGS="$BATS_TEST_TMPDIR/oc/logs" \
        OC_BACKUPS="$BATS_TEST_TMPDIR/oc/backups" \
        OC_WORKSPACE="$BATS_TEST_TMPDIR/oc-workspace" \
        __TAC_OPENCLAW_OK=0 \
        C_Info= C_Warning= C_Reset= \
        "$@" \
        bash --noprofile --norc -c "cd '$BATS_TEST_TMPDIR' && source '$REPO_ROOT/scripts/13-init.sh'" 2>&1
}

@test "13-init loopback0: a shell that starts before systemd finishes says NOT CREATED YET" {
    # Catches the pre-fix wording: it called this race "loopback0 missing" and
    # told the reader to run a repair the boot unit was already performing.
    run _run_init STUB_LINK_PRESENT=0 STUB_SYSTEM_STATE=starting
    [ "$status" -eq 0 ]
    [[ "$output" == *"loopback0 not created yet"* ]]
    [[ "$output" != *"loopback0 missing"* ]]
}

@test "13-init loopback0: once the boot has finished, a genuine absence keeps the ALARM" {
    # Catches the over-correction: treating every absence as "not yet" would stop
    # reporting a real fault on a box that has been up for hours.
    run _run_init STUB_LINK_PRESENT=0 STUB_SYSTEM_STATE=running
    [ "$status" -eq 0 ]
    [[ "$output" == *"loopback0 missing"* ]]
    [[ "$output" != *"not created yet"* ]]
}

@test "13-init loopback0: an unreadable state with NO systemd is an ALARM, never 'fine'" {
    # Catches the silent failure the 2026-10-22 fix protected: on the truncated
    # /etc/wsl.conf boot, WSL's own init is PID 1 and nothing will ever run the
    # unit, so "unknown" must not fold into "still booting".
    run _run_init STUB_LINK_PRESENT=0 STUB_SYSTEM_STATE= STUB_SYSTEM_EXIT=1 \
        STUB_PID1_COMM=init
    [ "$status" -eq 0 ]
    [[ "$output" == *"loopback0 missing"* ]]
}

@test "13-init loopback0: an unreadable state on a systemd box is the RACE, not the alarm" {
    # The 2026-10-24 defect, measured: boot 19:02:56, the unit ran 19:03:43,
    # "Startup finished in 53.181s" at 19:03:49, and the shell started 19:03:06 —
    # systemd was mid-start, the probe answered nothing usable, and the banner
    # claimed "loopback0 missing".  Catches that: "could not ask" must not be
    # reported as a measured absence while systemd is the init.
    run _run_init STUB_LINK_PRESENT=0 STUB_SYSTEM_STATE= STUB_SYSTEM_EXIT=1 \
        STUB_PID1_COMM=systemd
    [ "$status" -eq 0 ]
    [[ "$output" == *"loopback0 not created yet"* ]]
    [[ "$output" != *"loopback0 missing"* ]]
}

@test "13-init loopback0: an unreadable state is never reported as FINE" {
    # The first two unreadable-state cases differ only in the verdict, so this one
    # pins the invariant they share: a state that could not be read still says so —
    # it must not fall silent (0.1: silence is the one answer that hides a fault).
    run _run_init STUB_LINK_PRESENT=0 STUB_SYSTEM_STATE= STUB_SYSTEM_EXIT=1 \
        STUB_PID1_COMM=systemd
    [ "$status" -eq 0 ]
    [[ "$output" == *"loopback0"* ]]
}

@test "13-init loopback0: an interface that exists says nothing at all" {
    # Catches the opposite spam: a check that warns regardless of state would put
    # a notice on every shell of a healthy box.
    run _run_init STUB_LINK_PRESENT=1 STUB_SYSTEM_STATE=running
    [ "$status" -eq 0 ]
    [[ "$output" != *"loopback0"* ]]
}

# end of file
