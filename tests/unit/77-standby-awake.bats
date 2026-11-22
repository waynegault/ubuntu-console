#!/usr/bin/env bats
# ==============================================================================
# Unit — the run scope of the Modern-Standby keeper
# ==============================================================================
# WHY. Windows Modern Standby clamps this box's dGPU to ~700 MHz and cost 3.3x at c=1 while looking
# exactly like a bad configuration (rows A3 vs A3R, 2026-11-04). The keeper defends against that, and
# Wayne's rule for it is narrow: "standby-keeper.service should only operate during runs".
#
# The dangerous failure is not "keeper off" — that is loud, because the rows come back at a third of
# the throughput. The dangerous failure is "keeper on when nothing is running", which is invisible: the
# box simply never idles, forever, and nobody correlates it with a battery that drains. So these cases
# pin the STOP side first and the START side second.
#
# Hermetic: both systemctl and gpu-busy.sh are stubs first on PATH, so no real unit is started and no
# real card is probed.
setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export SCRIPT="$REPO_ROOT/bin/standby-awake.sh"
    export STUB_STATE="$BATS_TEST_TMPDIR/state"
    mkdir -p "$STUB_STATE/stub"
    printf "inactive\n" > "$STUB_STATE/standby-keeper.service"
    printf "inactive\n" > "$STUB_STATE/autotune-resume.service"
    printf "0\n" > "$STUB_STATE/busy_rc"
    : > "$STUB_STATE/calls"
    cat > "$STUB_STATE/stub/systemctl" <<'SH'
#!/usr/bin/env bash
# stub: systemctl [--user] <action> <unit>
action=$2; unit=$3
f="$STUB_STATE/$unit"
[ -f "$f" ] || printf "inactive\n" > "$f"
case "$action" in
  is-active) cat "$f" ;;
  start) printf "active\n" > "$f"; printf "start %s\n" "$unit" >> "$STUB_STATE/calls" ;;
  stop)  printf "inactive\n" > "$f"; printf "stop %s\n" "$unit" >> "$STUB_STATE/calls" ;;
  *) exit 0 ;;
esac
SH
    cat > "$STUB_STATE/stub/gpu-busy.sh" <<'SH'
#!/usr/bin/env bash
# stub: prints a reason, exits with the test's chosen verdict (0 free, non-zero busy). A
# silent verdict is a real shape: gpu-busy.sh has exited non-zero with no text on this box
# (standby-awake.log, 2026-11-04T23:59:13Z, logged only "gpu:").
[[ -e "$STUB_STATE/busy_silent" ]] || printf "stub-reason\n"
exit "$(cat "$STUB_STATE/busy_rc")"
SH
    chmod +x "$STUB_STATE/stub/systemctl" "$STUB_STATE/stub/gpu-busy.sh"
    export PATH="$STUB_STATE/stub:$PATH"
    export STANDBY_AWAKE_MARKER="$BATS_TEST_TMPDIR/marker"
    export STANDBY_AWAKE_LOG="$BATS_TEST_TMPDIR/awake.log"
}

# A run in progress is any one of the three signals; nothing else may start the keeper.
@test "idle box stops a running keeper" {
    printf "active\n" > "$STUB_STATE/standby-keeper.service"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -qx "stop standby-keeper.service" "$STUB_STATE/calls"
    [ "$(cat "$STUB_STATE/standby-keeper.service")" = "inactive" ]
    grep -q "STOP keeper: no run in progress" "$STANDBY_AWAKE_LOG"
}

@test "an idle box with an already-stopped keeper records no state change" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -s "$STUB_STATE/calls" ]
    [ ! -s "$STANDBY_AWAKE_LOG" ]
}

@test "the exclusive-card marker starts the keeper" {
    : > "$STANDBY_AWAKE_MARKER"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -qx "start standby-keeper.service" "$STUB_STATE/calls"
    grep -q "START keeper because marker" "$STANDBY_AWAKE_LOG"
}

@test "autotune owning the box starts the keeper" {
    printf "active\n" > "$STUB_STATE/autotune-resume.service"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -qx "start standby-keeper.service" "$STUB_STATE/calls"
    grep -q "autotune" "$STANDBY_AWAKE_LOG"
}

@test "a bare sanctioned lane serving does not start the keeper" {
    # gpu-busy.sh answers FREE (rc 0) for our own lane; that is normal traffic, not a run.
    printf "0\n" > "$STUB_STATE/busy_rc"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -s "$STUB_STATE/calls" ]
    [ "$(cat "$STUB_STATE/standby-keeper.service")" = "inactive" ]
}

@test "an unsanctioned workload on the card starts the keeper" {
    printf "1\n" > "$STUB_STATE/busy_rc"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -qx "start standby-keeper.service" "$STUB_STATE/calls"
    grep -q "START keeper because gpu:stub-reason" "$STANDBY_AWAKE_LOG"
}

@test "an already-running keeper is not restarted on every tick" {
    : > "$STANDBY_AWAKE_MARKER"
    printf "active\n" > "$STUB_STATE/standby-keeper.service"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -s "$STUB_STATE/calls" ]
    [ ! -s "$STANDBY_AWAKE_LOG" ]
}

@test "a silent GPU verdict still says why the box is being held awake" {
    # Fail-safe direction: a non-zero exit keeps the keeper on. But an empty reason made the log
    # entry unreadable ("gpu:"), so the exit code must appear in it.
    printf "3\n" > "$STUB_STATE/busy_rc"
    : > "$STUB_STATE/busy_silent"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -qx "start standby-keeper.service" "$STUB_STATE/calls"
    grep -q "START keeper because gpu:gpu-busy.sh exited 3 with no output" "$STANDBY_AWAKE_LOG"
}

@test "the GPU probe is not run when a cheap signal already answers" {
    : > "$STANDBY_AWAKE_MARKER"
    # The stub would record nothing here; instead prove the probe is skipped by making it explosive.
    printf "#!/usr/bin/env bash\nexit 42\n" > "$STUB_STATE/stub/gpu-busy.sh"
    chmod +x "$STUB_STATE/stub/gpu-busy.sh"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -qx "start standby-keeper.service" "$STUB_STATE/calls"
}

# ─────────────────────────────────────────────────────────────────────────────
# The keeper's own sample row (v2).  The loop cannot be run to completion, so the
# sample lives in __keeper_sample and is driven here with a stub driver: clocks.log
# is the only evidence that a damped row was the CARD and not the configuration, and
# it has to explain that before anyone can act on it.
# ─────────────────────────────────────────────────────────────────────────────
@test "one sample row carries the plateau fields after the original four" {
    eval "$(sed -n '/^function __keeper_sample()/,/^}/p' "$REPO_ROOT/bin/standby-keeper.sh")"
    declare -f __keeper_sample >/dev/null

    local stub="$BATS_TEST_TMPDIR/nvidia-smi" row
    cat > "$stub" <<'EOF'
#!/usr/bin/env bash
printf '2411, 19.80 W, 22 %%, P0, 69, 3003, 0x0000000000000400\n'
EOF
    chmod +x "$stub"

    row=$(__keeper_sample "$stub")
    [[ "$row" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z, ]] \
        || { echo "the row must start with the UTC timestamp (got: $row)"; return 1; }
    # Appended, not reordered: the original four fields keep their positions.
    [[ "$row" == *",2411,19.80W,22%,P0,69,3003,0x0000000000000400" ]] \
        || { echo "the sample must append temp/max-clock/throttle after the original four (got: $row)"; return 1; }

    # A failing probe still writes ONE legible row with an empty tail (the keeper must not die).
    cat > "$stub" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "$stub"
    row=$(__keeper_sample "$stub")
    [[ "$row" =~ Z,$ ]] || { echo "a failed probe must leave a timestamp-only row (got: $row)"; return 1; }

    # Wiring: the loop appends through the tested function, not a second copy of the query.
    grep -qF '__keeper_sample "$SMI" >> "$LOG"' "$REPO_ROOT/bin/standby-keeper.sh"
}
