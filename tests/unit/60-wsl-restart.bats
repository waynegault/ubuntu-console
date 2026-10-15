#!/usr/bin/env bats
# ==============================================================================
# Unit — bin/wsl-restart.sh: restart this distro from inside it, WITH the VS Code
# client, so the client comes back on a fresh remote relay.
# ==============================================================================
# WHY THIS EXISTS.  Two measured failures, both of which "worked":
#
#   1. The recipe it replaces (create, /run, /delete) could NEVER delete: /run ran
#      `wsl.exe --shutdown`, which killed the distro hosting the shell that was going
#      to run /delete, so the task was always left registered with its one-time trigger
#      still armed - measured 2026-10-15 on `tac-wsl-restart`: Last Run 01:44:48,
#      Ready, Next Run 23:59:00, i.e. a SECOND unplanned restart ~22 h later.
#   2. A VM restart under a live VS Code client leaves that client re-resolving the
#      SAME dead relay port for EVERY window of that app instance, each connect dying
#      `WebSocket close with status code 1006`; measured, three windows of one app
#      instance all resolved 127.0.0.1:10417 while a fresh app start resolved
#      127.0.0.1:10987 and connected.  A window reload and a new window both reuse the
#      dead port, so only a fresh app process recovers.
#
# The expected values below come from that requirement - close the client, restart,
# wait bounded, relaunch, delete the task on the WINDOWS side - and not from the
# script's current output.
#
# WHAT THE STUB DOES NOT PROVE.  `schtasks` is stubbed, so these cases prove the ARGV
# this script builds and the read-back it performs, NOT what Windows does with them.
# The wrapper's own run (does the client actually come back on a fresh relay?) needs a
# real restart and is therefore verified by hand at the next deliberate one; a unit
# test cannot reach it.
#
# FALSIFICATION.  Case 3 fails against a wrapper that slept with `timeout` (that
# command needs a console and fails in a non-interactive scheduled task, the only
# context this wrapper ever runs in) or that waited unbounded.  Case 6 fails against a
# `--restart` that never reads its registration back and so reports a silent no-op as
# success.  Case 7 fails against one that arms a restart with no client to relaunch.
#
# No env.sh: bin/wsl-restart.sh is a standalone script driven here as a subprocess
# through its documented TAC_WSL_RESTART_* seams, so nothing from the module tree is
# sourced - the same shape as 59-check-swallows-staged.bats.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export REPO_ROOT
    SCRIPT="$REPO_ROOT/bin/wsl-restart.sh"
    export SCRIPT

    SANDBOX="$(mktemp -d)"
    export SANDBOX
    ARGV_LOG="$SANDBOX/schtasks.argv"
    export ARGV_LOG

    # A stub schtasks: records every argv, and answers /query in one of three modes.
    #   registered -> a registration exists   absent -> "cannot find the file"
    #   broken     -> a failure that is NOT absence (must never read as "absent")
    # A /delete is REMEMBERED, so the read-back guard can be tested: a stub that keeps
    # answering "registered" after a delete can only make the product look broken.
    DELETED_MARKER="$SANDBOX/deleted"
    export DELETED_MARKER
    STUB="$SANDBOX/schtasks"
    cat > "$STUB" <<'STUB_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ARGV_LOG"
case "$*" in
    *"/delete"*)
        : > "$DELETED_MARKER"
        exit 0
        ;;
    *"/query"*)
        if [[ -f "$DELETED_MARKER" ]]; then
            printf 'ERROR: The system cannot find the file specified.\n' >&2
            exit 1
        fi
        case "${QUERY_MODE:-absent}" in
            registered)
                printf 'TaskName:                             \\tac-wsl-restart\n'
                printf 'Next Run Time:                        15/10/2026 23:59:00\n'
                exit 0
                ;;
            broken)
                printf 'ERROR: Access is denied.\n' >&2
                exit 1
                ;;
            *)
                printf 'ERROR: The system cannot find the file specified.\n' >&2
                exit 1
                ;;
        esac
        ;;
esac
exit 0
STUB_EOF
    chmod +x "$STUB"
    export QUERY_MODE=absent

    # The CLI the wrapper relaunches, stubbed so --restart's fail-closed check passes
    # without reaching Wayne's real Windows install.
    CODE_CMD="$SANDBOX/code.cmd"
    : > "$CODE_CMD"
    chmod +x "$CODE_CMD"

    export TAC_WSL_RESTART_SCHTASKS="$STUB"
    export TAC_WSL_RESTART_WRAPPER_UNIX="$SANDBOX/wsl-restart-action.cmd"
    export TAC_WSL_RESTART_WRAPPER_WIN='C:\Users\wayne\wsl-restart-action.cmd'
    export TAC_WSL_RESTART_LOG_UNIX="$SANDBOX/wsl-restart-action.log"
    export TAC_WSL_RESTART_CODE_CMD_UNIX="$CODE_CMD"
}

teardown() {
    [[ -n "${SANDBOX:-}" ]] && rm -rf "$SANDBOX"
}

# The line number of the FIRST line matching a pattern, or 0 when there is none.
# awk rather than grep: it always exits 0, so a miss cannot abort the case under
# bats' errexit and be misread as a pass.
_line_of() {
    printf '%s\n' "$1" | awk -v pat="$2" 'index($0, pat) { print NR; exit }'
}

@test "wsl-restart: the wrapper runs the five steps in order" {
    run "$SCRIPT" --dry-run
    [ "$status" -eq 0 ]

    close_n=$(_line_of "$output" 'taskkill /im Code.exe')
    shutdown_n=$(_line_of "$output" 'wsl.exe --shutdown')
    wait_n=$(_line_of "$output" ':wait_distro')
    relaunch_n=$(_line_of "$output" '--remote wsl+Ubuntu-24.04')
    delete_n=$(_line_of "$output" 'schtasks.exe /delete /f /tn tac-wsl-restart')

    # Every step present, so a later comparison cannot pass on a missing step.
    [ "$close_n" -gt 0 ]
    [ "$shutdown_n" -gt 0 ]
    [ "$wait_n" -gt 0 ]
    [ "$relaunch_n" -gt 0 ]
    [ "$delete_n" -gt 0 ]

    [ "$close_n" -lt "$shutdown_n" ]
    [ "$shutdown_n" -lt "$wait_n" ]
    [ "$wait_n" -lt "$relaunch_n" ]
    [ "$relaunch_n" -lt "$delete_n" ]
}

@test "wsl-restart: the wrapper is CRLF throughout (cmd.exe parses LF-only .cmd badly)" {
    run "$SCRIPT" --dry-run
    [ "$status" -eq 0 ]

    # Every non-empty line must END with CR: a LF-only goto/label file is the failure
    # mode this pins.
    local lines crlf
    lines=$(printf '%s\n' "$output" | awk 'length($0) > 0 { n++ } END { print n+0 }')
    crlf=$(printf '%s\n' "$output" | awk 'length($0) > 0 && substr($0, length($0)) == "\r" { n++ } END { print n+0 }')
    [ "$lines" -gt 0 ]
    [ "$lines" -eq "$crlf" ]
}

@test "wsl-restart: the wrapper's waits are ping-based and the distro wait is bounded" {
    run "$SCRIPT" --dry-run
    [ "$status" -eq 0 ]

    # `timeout` needs a console and fails inside a scheduled task; ping does not.
    ! printf '%s\n' "$output" | grep -q 'timeout /t'
    printf '%s\n' "$output" | grep -q 'ping -n'
    # Bounded: the retry counter is compared against a limit, so exhaustion aborts
    # rather than looping forever.
    printf '%s\n' "$output" | grep -qE 'if %TRIES% GEQ [0-9]+ goto'
}

@test "wsl-restart: --dry-run arms nothing" {
    run "$SCRIPT" --dry-run
    [ "$status" -eq 0 ]

    [ ! -e "$ARGV_LOG" ]
    [ ! -e "$TAC_WSL_RESTART_WRAPPER_UNIX" ]
}

@test "wsl-restart: --restart builds one /create with the task, a one-shot near-future trigger and the Windows wrapper" {
    export QUERY_MODE=registered
    run "$SCRIPT" --restart --delay 2 2>&1
    [ "$status" -eq 0 ]

    # Exactly one /create: a duplicated flag in a generated argv is its own failure mode.
    [ "$(awk '/\/create/ { n++ } END { print n+0 }' "$ARGV_LOG")" -eq 1 ]
    grep -q '/tn tac-wsl-restart' "$ARGV_LOG"
    grep -q '/sc once' "$ARGV_LOG"
    grep -qF '/tr C:\Users\wayne\wsl-restart-action.cmd' "$ARGV_LOG"
    grep -qE '/sd [0-3][0-9]/[0-1][0-9]/20[0-9][0-9]' "$ARGV_LOG"

    # /st must match the script's own clock arithmetic, allowing for a minute boundary
    # between its run and this check - not a fixed literal, which would be a
    # change-detector.
    local st expected
    st=$(awk '{ for (i = 1; i < NF; i++) if ($i == "/st") print $(i+1) }' "$ARGV_LOG")
    expected=$(for d in 1 2 3; do date -d "+$d minutes" +%H:%M; done)
    [[ "$expected" == *"$st"* ]]

    # And the wrapper must actually have reached disk.
    [ -f "$TAC_WSL_RESTART_WRAPPER_UNIX" ]
}

@test "wsl-restart: --restart FAILS when the registration cannot be read back" {
    # The read-back is the guard against reporting a silent no-op as success: /create
    # "succeeds" (the stub exits 0) but no registration can then be read.
    export QUERY_MODE=absent
    run "$SCRIPT" --restart --delay 2 2>&1
    [ "$status" -ne 0 ]
    [[ "$output" == *"no registration can be read back"* ]]
}

@test "wsl-restart: --restart fails closed with no client to relaunch, and arms nothing" {
    export QUERY_MODE=registered
    export TAC_WSL_RESTART_CODE_CMD_UNIX="$SANDBOX/absent-code.cmd"
    run "$SCRIPT" --restart --delay 2 2>&1
    [ "$status" -ne 0 ]
    [[ "$output" == *"VS Code CLI not found"* ]]
    # The restart must NOT have been armed: arming without a relaunch leaves the box
    # restarted and the client dead.
    [ "$(awk '/\/create/ { n++ } END { print n+0 }' "$ARGV_LOG" 2>/dev/null || echo 0)" -eq 0 ]
    [ ! -e "$TAC_WSL_RESTART_WRAPPER_UNIX" ]
}

@test "wsl-restart: --delay 0 is refused (a past trigger is not a restart)" {
    run "$SCRIPT" --restart --delay 0 2>&1
    [ "$status" -eq 2 ]
    [[ "$output" == *"--delay must be"* ]]
    [ ! -e "$ARGV_LOG" ]
}

@test "wsl-restart: --status exit contract - 0 nothing armed, 1 armed, 2 unreadable" {
    export QUERY_MODE=absent
    run "$SCRIPT" --status 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"not registered"* ]]

    export QUERY_MODE=registered
    run "$SCRIPT" --status 2>&1
    [ "$status" -eq 1 ]
    [[ "$output" == *"ARMED"* ]]

    # Unreadable is NOT absence: it must not read as the safe state.
    export QUERY_MODE=broken
    run "$SCRIPT" --status 2>&1
    [ "$status" -eq 2 ]
    [[ "$output" == *"state unknown"* ]]
}

@test "wsl-restart: the chunk gate runs BEFORE anything destructive" {
    # A restart must not cut a running row in half, so the gate has to come first -
    # and a skipped restart must leave the distro AND the client untouched.
    run "$SCRIPT" --dry-run
    [ "$status" -eq 0 ]

    gate_n=$(_line_of "$output" '--precheck')
    skip_n=$(_line_of "$output" 'restart SKIPPED')
    close_n=$(_line_of "$output" 'taskkill /im Code.exe')
    shutdown_n=$(_line_of "$output" 'wsl.exe --shutdown')

    [ "$gate_n" -gt 0 ]
    [ "$skip_n" -gt 0 ]
    [ "$gate_n" -lt "$close_n" ]
    [ "$skip_n" -lt "$close_n" ]
    [ "$gate_n" -lt "$shutdown_n" ]
    # The gate must not fall through to a shutdown on its own: the skip jumps past
    # every destructive step.
    [ "$skip_n" -lt "$shutdown_n" ]
}

@test "wsl-restart: --precheck is 0 clear, 1 when a chunk matches, 2 when the check fails" {
    # Clear: a pattern that matches nothing is the safe answer.
    run env TAC_WSL_RESTART_CHUNK_PATTERN='zzz[-]no-such-process' "$SCRIPT" --precheck 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"CLEAR"* ]]

    # Busy: a real process this harness owns, matched by the same pgrep the product uses.
    sleep 30 &
    local _sleeper=$!
    run env TAC_WSL_RESTART_CHUNK_PATTERN='slee[p] 30' "$SCRIPT" --precheck 2>&1
    kill "$_sleeper" 2>/dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"BUSY"* ]]
    [[ "$output" == *"$_sleeper"* ]]

    # Unreadable: pgrep fails on a malformed pattern, and an unreadable process
    # table must NEVER read as "clear".
    run env TAC_WSL_RESTART_CHUNK_PATTERN='[unclosed' "$SCRIPT" --precheck 2>&1
    [ "$status" -eq 2 ]
    [[ "$output" == *"UNKNOWN"* ]]
}

@test "wsl-restart: --schedule registers a DAILY task whose wrapper keeps its own registration" {
    export QUERY_MODE=registered
    export TAC_WSL_RESTART_DAILY_WRAPPER_UNIX="$SANDBOX/daily.cmd"
    run "$SCRIPT" --schedule 03:30 2>&1
    [ "$status" -eq 0 ]

    [ "$(awk '/\/create/ { n++ } END { print n+0 }' "$ARGV_LOG")" -eq 1 ]
    grep -q '/sc daily' "$ARGV_LOG"
    grep -q '/st 03:30' "$ARGV_LOG"
    grep -qF '/tr C:\Users\wayne\wsl-restart-daily.cmd' "$ARGV_LOG"

    # The whole point of a schedule: it must not delete itself on the first run.
    [ -f "$TAC_WSL_RESTART_DAILY_WRAPPER_UNIX" ]
    ! grep -q 'schtasks.exe /delete' "$TAC_WSL_RESTART_DAILY_WRAPPER_UNIX"
    grep -q 'registration KEPT' "$TAC_WSL_RESTART_DAILY_WRAPPER_UNIX"

    # ...while the one-shot wrapper still does delete itself.
    run "$SCRIPT" --dry-run
    [[ "$output" == *'schtasks.exe /delete /f /tn tac-wsl-restart'* ]]
}

@test "wsl-restart: --schedule refuses a time that is not 24h HH:MM, and arms nothing" {
    run "$SCRIPT" --schedule 25:00 2>&1
    [ "$status" -eq 2 ]
    [[ "$output" == *"--schedule needs a 24h HH:MM"* ]]
    [ ! -e "$ARGV_LOG" ]

    run "$SCRIPT" --schedule lunchtime 2>&1
    [ "$status" -eq 2 ]
}

@test "wsl-restart: --unschedule removes the registration, and says so when there is none" {
    export QUERY_MODE=registered
    run "$SCRIPT" --unschedule 2>&1
    [ "$status" -eq 0 ]
    grep -q '/delete' "$ARGV_LOG"
    [[ "$output" == *"removed"* ]]

    # And with nothing registered it is a no-op, not an error.
    export QUERY_MODE=absent
    run "$SCRIPT" --unschedule 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing to remove"* ]]
}

# end of file
