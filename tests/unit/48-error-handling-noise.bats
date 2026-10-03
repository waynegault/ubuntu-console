#!/usr/bin/env bats
# ==============================================================================
# Unit — the ERR trap must not log normal systemctl answers or bare `return`
# ==============================================================================
# WHY THIS EXISTS (card b0392f6f, AUDIT-2026-10-02): __tac_err_handler logged two
# classes of NORMAL non-zero exits as errors, and they dominated the log —
# ~/.openclaw/logs/bash-errors.log carried 296 `systemctl is-active` lines and 92
# `return $previous_exit_status` lines. Both are normal answers:
#
#   * systemctl `is-active`/`is-enabled` exit 3 for "inactive"/"disabled", which is
#     how callers ASK the question ("is it running? -> no"), not a failure.
#   * a function whose body is `return $some_status` is propagating its callee's
#     status; the failing command is the callee, not this return.
#
# The fix suppresses ONLY those two shapes. A real systemctl failure (exit 4, a bus
# error, a different subcommand) MUST still be logged, or the trap would hide the
# failures it exists to surface.
#
# A second defect in the same handler (card cb0ef810): the command was written
# verbatim, so a control byte in it made bash-errors.log binary (a 639-NUL line
# stopped `grep` reading the file). __tac_sanitize_log_field now strips NUL/control
# bytes (keeping TAB) before any field is written.
#
# FALSIFICATION: against the pre-fix module every "not logged" case below fails —
# the rc-3 is-active line is written to the log. And if the whitelist were widened
# from "is-active/is-enabled only" to all systemctl invocations, the `restart rc 3`
# case below would fail, because that failure would be suppressed.
#
# The trap is exercised in a CHILD bash (`bash -c`) so sourcing the module — which
# sets `set -E` and its own ERR trap — never clobbers BATS's traps. systemctl is an
# external shim rather than a function: for a shell FUNCTION the trap records the
# body's last command (`return N`) as BASH_COMMAND, not the function invocations, so
# a function shim would test the wrong string.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export REPO_ROOT
    export MODULE="$REPO_ROOT/scripts/02-error-handling.sh"
    # The handler writes to $ErrorLogPath (its real interface), so point it at a
    # throwaway file.
    export ErrorLogPath
    ErrorLogPath="$(mktemp)"
    export SHIMDIR
    SHIMDIR="$(mktemp -d)"
    mkdir -p "$SHIMDIR/bin"
    cat > "$SHIMDIR/bin/systemctl" <<'SHIM'
#!/bin/sh
exit "${SYSTEMCTL_RC:-3}"
SHIM
    chmod +x "$SHIMDIR/bin/systemctl"
    # A per-case unique token: the trap's dedup gate keeps state in /dev/shm and
    # suppresses a repeated signature within 15s, so a fixed command could make a
    # "should log" case silently skip. The token makes every signature unique.
    export PROBE_UNIQ="${BATS_TEST_NUMBER}-$$"
}

teardown() {
    rm -rf "$SHIMDIR"
    rm -f "$ErrorLogPath"
}

# Run one failing command under the real ERR trap and leave the log in $ErrorLogPath.
# `run` (not a bare call) so the child's non-zero exit does not trip BATS's errexit.
_run_under_trap() {
    local rc="$1" command="$2"
    : > "$ErrorLogPath"
    run env "SYSTEMCTL_RC=$rc" "PATH=$SHIMDIR/bin:$PATH" \
        bash -c "source '$MODULE'; $command"
}

@test "err-trap: systemctl is-active rc 3 is not logged (inactive is a normal answer)" {
    _run_under_trap 3 "systemctl is-active probe-$PROBE_UNIQ.service"
    ! grep -q "systemctl is-active probe-$PROBE_UNIQ.service" "$ErrorLogPath"
}

@test "err-trap: systemctl --user is-active --quiet rc 3 is not logged" {
    _run_under_trap 3 "systemctl --user is-active --quiet probe-$PROBE_UNIQ.service"
    ! grep -q "systemctl" "$ErrorLogPath"
}

@test "err-trap: systemctl is-enabled rc 3 is not logged" {
    _run_under_trap 3 "systemctl is-enabled probe-$PROBE_UNIQ.service"
    ! grep -q "systemctl" "$ErrorLogPath"
}

@test "err-trap: a genuine systemctl failure (is-active rc 4) IS logged" {
    _run_under_trap 4 "systemctl is-active broken-$PROBE_UNIQ.service"
    grep -q "systemctl is-active broken-$PROBE_UNIQ.service" "$ErrorLogPath"
    grep -q "EXIT 4" "$ErrorLogPath"
}

@test "err-trap: systemctl rc 3 from a NON-whitelisted subcommand IS logged" {
    _run_under_trap 3 "systemctl restart app-$PROBE_UNIQ.service"
    grep -q "systemctl restart app-$PROBE_UNIQ.service" "$ErrorLogPath"
}

@test "err-trap: a function's own failing 'return 4' is still logged" {
    _run_under_trap 0 "probe_fn() { return 4; }; probe_fn"
    grep -q "EXIT 4" "$ErrorLogPath"
}

@test "noise: a bare return \$* is an internal-noise command" {
    run bash -c "source '$MODULE'; __tac_is_internal_noise_command 'return \$previous_exit_status'"
    [ "$status" -eq 0 ]
}

@test "noise: an ordinary systemctl query is not internal noise" {
    run bash -c "source '$MODULE'; __tac_is_internal_noise_command 'systemctl is-active x'"
    [ "$status" -eq 1 ]
}

# ── card cb0ef810: the log must stay plain text ───────────────────────────────
# A control byte in a logged command turned bash-errors.log binary (a 639-NUL line
# stopped `grep` reading the file). NUL cannot inhabit a bash command WORD — bash
# strips NUL from variables — so the NUL path is pinned on the filter directly
# (fed through a pipe), and the handler path is pinned with a control byte (ESC)
# that CAN reach BASH_COMMAND.

@test "sanitize: NUL bytes are stripped from a log field" {
    raw="$BATS_TEST_TMPDIR/raw.bin"
    clean="$BATS_TEST_TMPDIR/clean.bin"
    printf 'a\0b\0c' > "$raw"
    run bash -c "source '$MODULE'; __tac_sanitize_log_field < '$raw' > '$clean'"
    [ "$status" -eq 0 ]
    run bash -c "LC_ALL=C tr -dc '\\000' < '$clean' | wc -c"
    [ "$output" -eq 0 ]
    run cat "$clean"
    [ "$output" = "abc" ]
}

@test "sanitize: the raw field WOULD carry the NULs (the NUL counter is valid)" {
    raw="$BATS_TEST_TMPDIR/raw.bin"
    printf 'a\0b\0c' > "$raw"
    run bash -c "LC_ALL=C tr -dc '\\000' < '$raw' | wc -c"
    [ "$output" -eq 2 ]
}

@test "sanitize: ESC/CR/DEL are stripped and TAB is kept" {
    raw="$BATS_TEST_TMPDIR/ctl.bin"
    printf 'a\tb\033c\rd\177e' > "$raw"
    run bash -c "source '$MODULE'; __tac_sanitize_log_field < '$raw'"
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'a\tbcde')" ]
}

@test "sanitize: an all-control field sanitizes to empty" {
    raw="$BATS_TEST_TMPDIR/allctl.bin"
    printf '\0\001\002\033' > "$raw"
    run bash -c "source '$MODULE'; __tac_sanitize_log_field < '$raw' | wc -c"
    [ "$status" -eq 0 ]
    [ "$output" -eq 0 ]
}

@test "log: a command carrying a control byte writes no control byte" {
    : > "$ErrorLogPath"
    run env PATH="$SHIMDIR/bin:$PATH" bash -c "source '$MODULE'; ls \$'\033'probe-$PROBE_UNIQ"
    grep -q "EXIT 2" "$ErrorLogPath"
    run grep -q '[[:cntrl:]]' "$ErrorLogPath"
    [ "$status" -ne 0 ]
}

# end of file
