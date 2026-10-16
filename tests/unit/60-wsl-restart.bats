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

    # A stub schtasks: records every argv, and answers /query in one of four modes.
    #   registered -> a registration exists   absent -> "cannot find the file"
    #   broken     -> a failure that is NOT absence (must never read as "absent")
    #   spent      -> registered, Ready, and NO trigger left (a one-shot that already fired)
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
            # A ONE-SHOT whose trigger has already FIRED: registered and Ready, but with NO
            # trigger left.  Measured 2026-10-16 after the wrapper failed to reach its own
            # self-delete - `--status` called this spent token ARMED and a watcher stood down.
            spent)
                printf 'TaskName:                             \\tac-wsl-restart\n'
                printf 'Next Run Time:                        N/A\n'
                printf 'Status:                               Ready\n'
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
    export TAC_WSL_RESTART_PROMPT_UNIX="$SANDBOX/wsl-restart-prompt.ps1"
    export TAC_WSL_RESTART_PROMPT_WIN='C:\Users\wayne\wsl-restart-prompt.ps1'
    export TAC_WSL_RESTART_LOG_UNIX="$SANDBOX/wsl-restart-action.log"
    export TAC_WSL_RESTART_CODE_CMD_UNIX="$CODE_CMD"
}

teardown() {
    [[ -n "${SANDBOX:-}" ]] && rm -rf "$SANDBOX"
}

# Falsification: fails before v9, which captured nothing and relaunched ONLY the configured
# folder - so every other window the restart had closed stayed closed (Wayne, 2026-10-15).
@test "wsl-restart: the capture records every open window, and step 4 loops them" {
    local _storage="$SANDBOX/storage.json" _out="$SANDBOX/windows.txt"
    # The spacing is the REAL file's (`"folder": "…"`, a space after the colon).  My first
    # fixture omitted it, so this case validated a pattern that captured NOTHING in production -
    # measured 2026-10-16 05:39: "capture: 0 open window(s)" then the fallback to one folder.
    cat > "$_storage" <<'JSON'
{"windowsState":{"openedWindows":[
 {"folder": "vscode-remote://wsl%2Bubuntu-24.04/home/wayne/ubuntu-console"},
 {"folder": "vscode-remote://wsl%2Bubuntu-24.04/home/wayne/investigator"},
 {"folder": "vscode-remote://wsl%2Bubuntu-24.04/home/wayne/ubuntu-console"}]}}
JSON

    run env TAC_WSL_RESTART_STORAGE_UNIX="$_storage" \
            TAC_WSL_RESTART_WINDOWS_TXT_UNIX="$_out" \
            "$SCRIPT" --capture-windows
    [ "$status" -eq 0 ]
    # THREE entries, TWO distinct URIs: a window listed twice is reopened once, not twice.
    [ "$(wc -l < "$_out")" -eq 2 ]
    grep -q 'investigator' "$_out"

    # Step 4 loops that list, and the configured folder stays as the FALLBACK.
    run "$SCRIPT" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *'--folder-uri'* ]]
    [[ "$output" == *'for /f'* ]]
    [[ "$output" == *'--remote wsl+Ubuntu-24.04'* ]]

    # v12: BOTH relaunch invocations go through `call`.  A .cmd invoked from a .cmd WITHOUT
    # `call` does not return to its caller, so the wrapper would never reach its tail - and the
    # tail is where the one-shot's self-delete lives.  Measured 2026-10-16: ZERO `done` lines
    # across 16 fires, the log ending at the relaunch echoes.  A unit case cannot prove cmd.exe
    # behaviour, so this pins the MECHANISM, as the operator gate's stdout case does.
    [ "$(printf '%s\n' "$output" | grep -c 'call "%CODE_CMD%"')" -eq 2 ]
    ! printf '%s\n' "$output" | grep -qE '^[[:space:]]*"%CODE_CMD%"'
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

    # v12: REGISTERED is not the same as ARMED.  A one-shot whose trigger has already FIRED keeps
    # its registration - `Next Run Time: N/A`, `Status: Ready` - but can never fire again.  Measured
    # 2026-10-16: the wrapper failed to reach its self-delete, the token sat there, and this command
    # called it ARMED, which stood a watcher down mid-task.  It must read as NOT armed.
    export QUERY_MODE=spent
    run "$SCRIPT" --status 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"SPENT"* ]]
    [[ "$output" != *"ARMED - a restart is pending"* ]]

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

@test "wsl-restart: --schedule daily registers a DAILY task whose wrapper keeps its own registration" {
    export QUERY_MODE=registered
    export TAC_WSL_RESTART_DAILY_WRAPPER_UNIX="$SANDBOX/daily.cmd"
    run "$SCRIPT" --schedule daily 03:30 2>&1
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

@test "wsl-restart: a bare --schedule HH:MM arms a ONE-SHOT at that clock time" {
    export QUERY_MODE=registered
    run "$SCRIPT" --schedule 23:45 2>&1
    [ "$status" -eq 0 ]

    [ "$(awk '/\/create/ { n++ } END { print n+0 }' "$ARGV_LOG")" -eq 1 ]
    grep -q '/sc once' "$ARGV_LOG"
    grep -q '/st 23:45' "$ARGV_LOG"
    # A bare time must NOT take the daily form: substituting a DAILY task for the
    # one-shot is the production miss this case exists to catch (2026-10-16 - the
    # evening campaign never fired because `--schedule 22:57` armed `/sc daily`).
    ! grep -q '/sc daily' "$ARGV_LOG"
    grep -qF '/tr C:\Users\wayne\wsl-restart-action.cmd' "$ARGV_LOG"

    # /sd is TODAY when the clock time is still ahead, else TOMORROW - computed here from
    # the requirement, not read off the script's own output.
    local sd want
    sd=$(awk '{ for (i = 1; i < NF; i++) if ($i == "/sd") print $(i+1) }' "$ARGV_LOG")
    if [[ "$(date +%H:%M)" < "23:45" ]]; then want=$(date +%d/%m/%Y); else want=$(date -d '+1 day' +%d/%m/%Y); fi
    [ "$sd" = "$want" ]

    # The ONE-SHOT wrapper is written and deletes its own registration; the recurring
    # form keeps it.  Both halves, so the two modes cannot be confused for each other.
    [ -f "$TAC_WSL_RESTART_WRAPPER_UNIX" ]
    grep -q 'schtasks.exe /delete /f /tn tac-wsl-restart' "$TAC_WSL_RESTART_WRAPPER_UNIX"
    ! grep -q 'registration KEPT' "$TAC_WSL_RESTART_WRAPPER_UNIX"
}

@test "wsl-restart: --schedule refuses a time that is not 24h HH:MM, and arms nothing" {
    run "$SCRIPT" --schedule 25:00 2>&1
    [ "$status" -eq 2 ]
    [[ "$output" == *"--schedule needs a 24h HH:MM"* ]]
    [ ! -e "$ARGV_LOG" ]

    run "$SCRIPT" --schedule lunchtime 2>&1
    [ "$status" -eq 2 ]

    # Daily is only a MODE: with no time it is still an error, not a silent no-op.
    run "$SCRIPT" --schedule daily 2>&1
    [ "$status" -eq 2 ]
    [[ "$output" == *"--schedule needs a 24h HH:MM"* ]]
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

@test "wsl-restart: the OPERATOR GATE asks BEFORE anything is closed, and ships with the wrapper" {
    run "$SCRIPT" --dry-run
    [ "$status" -eq 0 ]

    prompt_n=$(_line_of "$output" 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PROMPT%"')
    close_n=$(_line_of "$output" 'taskkill /im Code.exe')
    [ "$prompt_n" -gt 0 ]
    # ITS WHOLE POINT: the ask happens while the session is still open.  A prompt
    # after the close would be asking about a window it had already taken away.
    [ "$prompt_n" -lt "$close_n" ]
    # Exit 3 is the ONLY cancel.  A missing prompt, a crash, an OK and the popup's own
    # expiry all fall through to the restart - that is what keeps the schedule the
    # default and the cancel the exception.
    printf '%s\n' "$output" | grep -q 'if errorlevel 3 goto operator_cancel'
    printf '%s\n' "$output" | grep -q 'if not exist "%PROMPT%"'

    # ...and the gate's script must reach disk, or the wrapper calls nothing.
    export QUERY_MODE=registered
    run "$SCRIPT" --restart --delay 2 2>&1
    [ "$status" -eq 0 ]
    [ -f "$TAC_WSL_RESTART_PROMPT_UNIX" ]
    grep -q 'Popup(' "$TAC_WSL_RESTART_PROMPT_UNIX"
    # The cancel code is NAMED, never a bare literal - the wrapper tests it with
    # `if errorlevel 3`, so the value and the test have to agree.
    grep -q 'CancelCode = 3' "$TAC_WSL_RESTART_PROMPT_UNIX"
    grep -q 'exit \$CancelCode' "$TAC_WSL_RESTART_PROMPT_UNIX"

    # ...and its own lines go to STDOUT, never into the wrapper's log.  MEASURED on the
    # first live fire (12:25 BST): the gate RAN - the wrapper logged "operator gate
    # clear - proceeding" - but every line the gate itself wrote was LOST, because the
    # wrapper holds its log open for the whole run and Add-Content raised
    # GetContentWriterIOError.  The wrapper already appends the gate's stdout to that
    # same log, so stdout is both lock-free and where a reader looks.  A unit case
    # cannot observe a runtime file lock; it can pin the mechanism that avoids it.
    ! grep -q 'Add-Content' "$TAC_WSL_RESTART_PROMPT_UNIX"
    grep -q 'Write-Output "\[\$stamp\] operator gate: \$m"' "$TAC_WSL_RESTART_PROMPT_UNIX"
    run "$SCRIPT" --dry-run
    [[ "$output" == *'-File "%PROMPT%" >> "%LOG%" 2>&1'* ]]
}

@test "wsl-restart: a CANCELLED restart SKIPS the self-delete and re-arms instead" {
    run "$SCRIPT" --dry-run
    [ "$status" -eq 0 ]

    cancel_n=$(_line_of "$output" ':operator_cancel')
    final_n=$(_line_of "$output" ':final')
    delete_n=$(_line_of "$output" 'schtasks.exe /delete /f /tn tac-wsl-restart')
    finished_n=$(_line_of "$output" ':finished')
    [ "$cancel_n" -gt 0 ]
    [ "$final_n" -gt "$cancel_n" ]
    # The cancel branch jumps PAST the delete: the gate has just re-armed the very
    # registration that delete would remove, so deleting here would cancel the retry.
    [ "$finished_n" -gt "$delete_n" ]
    printf '%s\n' "$output" | awk -v a="$cancel_n" -v b="$finished_n" 'NR>a && NR<b' \
        | grep -q 'goto finished'

    # The re-arm itself is the prompt's job, with a real future minute and the SAME
    # task name - otherwise the retry would never fire.
    export QUERY_MODE=registered
    run "$SCRIPT" --restart --delay 2 2>&1
    grep -q 'AddMinutes($RetryMinutes)' "$TAC_WSL_RESTART_PROMPT_UNIX"
    grep -q '/create /f /tn $TaskName' "$TAC_WSL_RESTART_PROMPT_UNIX"
    grep -q '/sc once' "$TAC_WSL_RESTART_PROMPT_UNIX"
}

@test "wsl-restart: the gate's shipped defaults - a 10s ask, 120s idle, 20min retry" {
    export QUERY_MODE=registered
    run "$SCRIPT" --restart --delay 2 2>&1
    [ "$status" -eq 0 ]
    grep -q '\$TimeoutSeconds = 10' "$TAC_WSL_RESTART_PROMPT_UNIX"
    grep -q '\$IdleSeconds = 120' "$TAC_WSL_RESTART_PROMPT_UNIX"
    grep -q '\$RetryMinutes = 20' "$TAC_WSL_RESTART_PROMPT_UNIX"
    # The expiry resolves to the RESTART: only an explicit Cancel (2) stops it.
    grep -q 'if ($answer -ne 2)' "$TAC_WSL_RESTART_PROMPT_UNIX"
    # "Obviously in use" needs BOTH a client and recent input, and the input probe
    # failing must still ASK rather than skip the ask.
    grep -q 'Get-Process -Name Code' "$TAC_WSL_RESTART_PROMPT_UNIX"
    grep -q 'GetLastInputInfo' "$TAC_WSL_RESTART_PROMPT_UNIX"
    grep -q 'asking anyway' "$TAC_WSL_RESTART_PROMPT_UNIX"
}

@test "wsl-restart: the vacuum runs in the CLOSED window, and never gates the restart" {
    run "$SCRIPT" --dry-run
    [ "$status" -eq 0 ]

    up_n=$(_line_of "$output" ':distro_up')
    vac_n=$(_line_of "$output" 'vscode-state-compact.sh')
    relaunch_n=$(_line_of "$output" '--remote wsl+Ubuntu-24.04')
    close_n=$(_line_of "$output" 'taskkill /im Code.exe')
    [ "$close_n" -gt 0 ]
    [ "$up_n" -gt 0 ]
    [ "$vac_n" -gt 0 ]
    [ "$relaunch_n" -gt 0 ]

    # THE WHOLE POINT: the client is killed in step 1 and relaunched in step 4, so the
    # compaction has to sit between the distro answering and that relaunch - the only
    # window in which nothing holds those state DBs open.  A line either side of it is
    # a VACUUM against a live DB, which SQLite refuses.
    [ "$vac_n" -gt "$close_n" ]
    [ "$vac_n" -gt "$up_n" ]
    [ "$vac_n" -lt "$relaunch_n" ]

    # ...and it must NOT be branched on: an `if errorlevel`/`goto` on its result would let
    # a refusal (locked DB, missing helper) stop the restart, the opposite of the contract.
    ! printf '%s\n' "$output" | grep -qE 'if errorlevel [0-9]+ goto[^\r]*compact'
}

@test "wsl-restart: the compaction helper runs the tool's vacuum mode, and is fail-soft" {
    # The helper owns the flags, so the wrapper's line stays one call.  Drive its own seam
    # with a stub interpreter that records the argv it was handed.
    local stub="$SANDBOX/stub-py" argv="$SANDBOX/stub.argv"
    cat > "$stub" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$ARGV_OUT"
EOS
    chmod +x "$stub"
    # The helper refuses BEFORE the interpreter when the tool is absent (its own
    # fail-soft path), so the tool must exist for this arm to reach the argv.
    printf '#!/usr/bin/env bash\nexit 0\n' > "$SANDBOX/tool.py"
    run env ARGV_OUT="$argv" TAC_COMPACT_TOOL="$SANDBOX/tool.py" TAC_PYTHON="$stub" \
        bash "$REPO_ROOT/bin/vscode-state-compact.sh"
    [ "$status" -eq 0 ]
    grep -q -- '/tool.py --vacuum --apply' "$argv"

    # A MISSING tool is reported and still exits 0: the restart is the job, so a broken
    # compaction can never fail the wrapper that called it.
    run env TAC_COMPACT_TOOL="$SANDBOX/absent-tool.py" bash "$REPO_ROOT/bin/vscode-state-compact.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing compacted"* ]]
}

# end of file
