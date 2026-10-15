#!/usr/bin/env bash
# wsl-restart.sh - restart the WSL distro from INSIDE it, and restart the VS Code
# client with it, so the client returns on a fresh remote relay.
#
# WHY A TASK SCHEDULER ENTRY.  `wsl.exe --shutdown` invoked inside the distro
# deadlocks: it has to terminate the distro that is hosting its own caller, so it
# waits on its own interop session.  The Task Scheduler runs the same command with
# no WSL session of its own, so nothing waits on anything.  Do not "simplify" this
# back into an in-distro `wsl.exe --shutdown`.
#
# WHY THE CLIENT IS RESTARTED TOO.  If the VM restarts under a live VS Code
# client, that client keeps re-resolving the WSL authority to the SAME relay port,
# forever, for EVERY window of that app instance - the port whose relay died with
# the VM - and every connect to it dies with `WebSocket close with status code
# 1006`.  After five attempts the error is treated as permanent.  Measured
# 2026-10-15: three windows of one app instance all resolved 127.0.0.1:10417 while
# a fresh app start resolved 127.0.0.1:10987 and connected immediately.  So
# "Developer: Reload Window" and opening a new window both reuse the dead port;
# only a fresh app process rebuilds the relay.  That is the half this script adds:
# closing and relaunching the client is not optional, it is the cure.
#
# WHAT THIS SCRIPT DOES (run from WSL)
#   1. renders the Windows-side wrapper %HOME%=C:\Users\wayne\wsl-restart-action.cmd
#   2. registers the one-shot task `tac-wsl-restart` to run it ~2 minutes later
#   3. reads the registration back and prints the trigger time, then returns
#
# WHAT THE WRAPPER THEN DOES (Windows side, in the Task Scheduler's own session)
#   - appends every step to C:\Users\wayne\wsl-restart-action.log
#   - closes the VS Code client: WM_CLOSE first so hot-exit can write its backups,
#     bounded, then forced
#   - `wsl.exe --shutdown`
#   - waits, bounded, for the distro to answer again
#   - relaunches the client on a fresh relay: code.cmd --remote wsl+ubuntu-24.04 <folder>
#   - deletes its OWN task registration
#
# WHY THE SELF-DELETE IS LOAD-BEARING.  The recipe this replaces was
# `schtasks /create ... /run ... /delete`.  Its `/delete` could NEVER run: `/run`
# ran `wsl.exe --shutdown`, which killed the distro hosting the shell that was
# going to perform the deletion.  The task was therefore always left registered,
# with its one-time `/st` trigger still armed - measured 2026-10-15 on
# `tac-wsl-restart`: Last Run 01:44:48, still Ready, Next Run 23:59:00, i.e. a
# SECOND unplanned restart ~22 h later.  Here the trigger is a near-future minute
# that actually fires, and the deletion happens on the Windows side after the
# restart, where nothing can kill it.
#
# THE SEQUENCE ENDS THIS SESSION.  Closing the client kills the extension host and
# `wsl.exe --shutdown` kills everything else in the distro.  Arm it only when a
# restart is actually wanted; `--status` is the safe way to look.
#
# USAGE
#   wsl-restart.sh --restart [--folder PATH] [--delay MINUTES]
#   wsl-restart.sh --status
#   wsl-restart.sh --dry-run [--folder PATH]     # render the wrapper, arm nothing
#   wsl-restart.sh --help | --version
#   --restart exits 0 when armed, 2 for a bad argument.  --status exits 0 with
#   nothing armed, 1 when a restart IS armed, 2 when the Task Scheduler could not
#   be read at all - never read that third one as "nothing armed".
#
# THE TASK RUNS ONLY WHILE WAYNE IS LOGGED ON.  Measured 2026-10-15 on a probe
# task created exactly this way: `Logon Mode: Interactive only`.  That is also what
# lets the wrapper's relaunch reach the desktop - a task given a background token
# would start the client in a session nobody can see, which would look like "the
# restart worked but VS Code never came back".  A trigger missed because the user
# is logged off leaves the registration behind, which `--status` reports; the
# wrapper's log is the other tell.
#
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 2
#   v2 (2026-10-15): record the measured Logon Mode ("Interactive only") - it is
#   both what lets the wrapper's relaunch reach the desktop and what bounds the
#   task to a logged-on user.
VERSION="1.0.1"

set -uo pipefail

TASK_NAME="tac-wsl-restart"
DISTRO="Ubuntu-24.04"
FOLDER_DEFAULT="/home/wayne/ubuntu-console"
DELAY_MINUTES_DEFAULT=2
WAIT_TRIES=20          # wrapper: bounded distro wait, 5 s apart (100 s)
CLOSE_GRACE_SECONDS=15 # wrapper: bounded graceful-close wait before the forced kill

# The three paths the wrapper needs, in the form the WINDOWS side must use.
WRAPPER_WIN_DEFAULT='C:\Users\wayne\wsl-restart-action.cmd'
LOG_WIN_DEFAULT='C:\Users\wayne\wsl-restart-action.log'
CODE_CMD_WIN_DEFAULT='%LOCALAPPDATA%\Programs\Microsoft VS Code\bin\code.cmd'

# Overridable so a test can exercise the argv without touching Windows state, and
# so the wrapper's location can move without editing the script.
SCHTASKS_BIN="${TAC_WSL_RESTART_SCHTASKS:-/mnt/c/Windows/System32/schtasks.exe}"
WRAPPER_WIN="${TAC_WSL_RESTART_WRAPPER_WIN:-$WRAPPER_WIN_DEFAULT}"
WRAPPER_UNIX="${TAC_WSL_RESTART_WRAPPER_UNIX:-/mnt/c/Users/wayne/wsl-restart-action.cmd}"
LOG_WIN="${TAC_WSL_RESTART_LOG_WIN:-$LOG_WIN_DEFAULT}"
LOG_UNIX="${TAC_WSL_RESTART_LOG_UNIX:-/mnt/c/Users/wayne/wsl-restart-action.log}"
CODE_CMD_UNIX_DEFAULT='/mnt/c/Users/wayne/AppData/Local/Programs/Microsoft VS Code/bin/code.cmd'
CODE_CMD_UNIX="${TAC_WSL_RESTART_CODE_CMD_UNIX:-$CODE_CMD_UNIX_DEFAULT}"
CODE_CMD_WIN="${TAC_WSL_RESTART_CODE_CMD_WIN:-$CODE_CMD_WIN_DEFAULT}"

# Deliberately NOT named `log`: bin/_tac-bin-lib.sh owns that name (a gate asserts
# it is defined exactly once, there).  This script wants the caller to READ its
# output, and the file log is the wrapper's, so a private one-line stderr writer
# is the whole requirement.
_say() { printf '%s\n' "$*" >&2; }

# Exit codes, named rather than spelled as bare literals at each site so a reader
# does not have to guess what a `return 2` meant there.
EXIT_STATUS_ARMED=1    # --status: a restart IS armed (0 is the "nothing armed" case)
EXIT_STATUS_UNKNOWN=2  # --status: the Task Scheduler could not be read
EXIT_USAGE=2           # the caller asked for something this script cannot do

# Print the usage block out of this file's own header, so the two cannot drift.
usage() {
    local _block
    _block=$(sed -n '/^# USAGE$/,/^#$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//')
    _say "$_block"
}

# A bounded Windows interop call.  Interop costs seconds and has been seen to hang
# outright (a `schtasks /delete` that did its work and then never returned, 2026-10-15),
# so every call is bounded and its EFFECT is read back separately - never trusted
# from its exit status alone.
_win() {
    local _bound="$1"; shift
    timeout "$_bound" "$@"
}

# The wrapper that runs on the Windows side.  CRLF is deliberate: cmd.exe parses a
# LF-only .cmd unreliably around labels and goto, and this file is full of both.
render_wrapper() {
    local _folder="$1"
    printf '%s\r\n' \
        '@echo off' \
        "REM Generated by ubuntu-console bin/wsl-restart.sh v${VERSION} - do not edit." \
        "REM Regenerated on every --restart; edit the tracked script instead." \
        'setlocal' \
        "set \"LOG=${LOG_WIN}\"" \
        '' \
        'echo [%DATE% %TIME%] wsl-restart-action: start >> "%LOG%"' \
        '' \
        'REM 1. Close the VS Code client. WM_CLOSE first so hot-exit writes its' \
        'REM    backups, bounded, then forced. This is the half that clears the' \
        'REM    cached remote relay: only a fresh app process re-resolves it.' \
        'taskkill /im Code.exe >> "%LOG%" 2>&1' \
        "ping -n $(( CLOSE_GRACE_SECONDS + 1 )) 127.0.0.1 >nul" \
        'taskkill /f /im Code.exe >> "%LOG%" 2>&1' \
        '' \
        'REM 2. Restart the distro. Must run here, never inside the distro.' \
        'wsl.exe --shutdown >> "%LOG%" 2>&1' \
        'ping -n 11 127.0.0.1 >nul' \
        '' \
        'REM 3. Wait, BOUNDED, for the distro to answer again. Exhaustion is' \
        'REM    logged and the relaunch is still attempted - the client boots the' \
        'REM    distro itself - but it is never a silent fall-through.' \
        'set TRIES=0' \
        ':wait_distro' \
        "wsl.exe -d ${DISTRO} -u wayne -- true >nul 2>&1" \
        'if not errorlevel 1 goto distro_up' \
        'set /a TRIES+=1' \
        "if %TRIES% GEQ ${WAIT_TRIES} goto distro_timeout" \
        'ping -n 6 127.0.0.1 >nul' \
        'goto wait_distro' \
        ':distro_up' \
        "echo [%DATE% %TIME%] distro answering after %TRIES% tries >> \"%LOG%\"" \
        'goto relaunch' \
        ':distro_timeout' \
        "echo [%DATE% %TIME%] WARN: distro did not answer after ${WAIT_TRIES} tries >> \"%LOG%\"" \
        ':relaunch' \
        '' \
        'REM 4. Relaunch the client on a fresh relay. Absolute, because the' \
        'REM    wrapper gets no shell profile.' \
        "set \"CODE_CMD=${CODE_CMD_WIN}\"" \
        "echo [%DATE% %TIME%] relaunching: %CODE_CMD% --remote wsl+${DISTRO} ${_folder} >> \"%LOG%\"" \
        "\"%CODE_CMD%\" --remote wsl+${DISTRO} \"${_folder}\" >> \"%LOG%\" 2>&1" \
        'ping -n 11 127.0.0.1 >nul' \
        'tasklist /fi "IMAGENAME eq Code.exe" >> "%LOG%" 2>&1' \
        '' \
        'REM 5. Delete our own registration. The trigger has already fired, so a' \
        'REM    failure here cannot re-fire it; it only leaves a spent row behind,' \
        'REM    which "wsl-restart.sh --status" reports.' \
        "schtasks.exe /delete /f /tn ${TASK_NAME} >> \"%LOG%\" 2>&1" \
        'echo [%DATE% %TIME%] wsl-restart-action: done >> "%LOG%"' \
        'endlocal' \
        '# end of file'
}

# Render the wrapper onto its Windows-side path, or fail loudly - a wrapper that
# did not reach disk would be reported as armed anyway.
write_wrapper() {
    local _folder="$1"
    if ! render_wrapper "$_folder" > "$WRAPPER_UNIX"; then
        _say "ERROR: cannot write the wrapper to $WRAPPER_UNIX"
        return 1
    fi
    _say "wrote $WRAPPER_UNIX (the Windows side runs it as $WRAPPER_WIN)"
    return 0
}

# Ask the Task Scheduler whether our task is registered, and print its state.
# Bounded, and the output is the EVIDENCE (a bare exit status proves nothing).
task_state() {
    local _out
    _out=$(_win 30 "$SCHTASKS_BIN" /query /tn "$TASK_NAME" /fo LIST /v 2>&1) || {
        printf '%s\n' "$_out" | grep -qiE 'cannot find|does not exist|no such' \
            && return 1
        # Any other failure is not proof of absence - say so instead of guessing.
        _say "WARN: schtasks could not be read: $(printf '%s' "$_out" | head -1)"
        return "$EXIT_STATUS_UNKNOWN"
    }
    printf '%s\n' "$_out" | grep -iE 'TaskName|Next Run Time|Last Run Time|Last Result|Status|Task To Run' |
        sed 's/^[[:space:]]*//'
    return 0
}

# Refuse to arm anything unless every path the wrapper will need is present.
check_preconditions() {
    local _rc=0
    if [[ ! -x "$SCHTASKS_BIN" ]]; then
        _say "ERROR: schtasks not found or not executable at $SCHTASKS_BIN"
        _rc=1
    fi
    if [[ ! -d "$(dirname "$WRAPPER_UNIX")" ]]; then
        _say "ERROR: wrapper directory does not exist: $(dirname "$WRAPPER_UNIX")"
        _rc=1
    fi
    # Fail closed: a wrapper that would run with no client to relaunch is worse
    # than no wrapper, because the restart still happens.
    if [[ ! -f "$CODE_CMD_UNIX" ]]; then
        _say "ERROR: VS Code CLI not found at $CODE_CMD_UNIX - the relaunch would fail"
        _rc=1
    fi
    return "$_rc"
}

# Render the wrapper and register the one-shot task that runs it on the Windows side.
arm_restart() {
    local _folder="$1" _delay="$2" _when_unix _st _sd _state
    if ! check_preconditions; then
        return 1
    fi

    # A leftover from an earlier run is worth saying out loud before overwriting.
    if _state=$(task_state); then
        _say "WARN: a $TASK_NAME registration already exists:"
        _say "$_state"
        _say "WARN: overwriting it."
    fi

    if ! write_wrapper "$_folder"; then
        return 1
    fi

    # The trigger is a near-future MINUTE that actually fires: a spent one-time
    # trigger cannot re-fire, which is what makes this design safe even if the
    # self-delete never runs.  /sd is explicit because UK-locale Windows reads
    # DD/MM/YYYY and a crossing of midnight must land on tomorrow's date.
    _when_unix=$(date -d "+${_delay} minutes" +%H:%M)
    _st="$_when_unix"
    _sd=$(date -d "+${_delay} minutes" +%d/%m/%Y)

    if ! _win 60 "$SCHTASKS_BIN" /create /f /tn "$TASK_NAME" \
            /tr "$WRAPPER_WIN" /sc once /sd "$_sd" /st "$_st" >/dev/null 2>&1; then
        _say "ERROR: schtasks /create failed (bounded at 60 s) - task NOT armed"
        return 1
    fi

    # Verify the EFFECT, not the return: read the registration back and show the
    # trigger.  A silent no-op here is exactly the failure this script exists to end.
    if ! _state=$(task_state); then
        _say "ERROR: /create returned success but no registration can be read back"
        return 1
    fi
    _say "armed: $TASK_NAME fires at $_st on $_sd (Windows local time)"
    _say "$_state"
    _say "the wrapper logs to $LOG_WIN; this session ends with the client."
    return 0
}

# Report the registration and the wrapper's log.  Exit 0 = nothing armed, 1 = a
# restart IS armed, 2 = the Task Scheduler could not be read, which is never
# absence and must not read as one.
show_status() {
    local _state _rc=0 _verdict=0
    _state=$(task_state) || _rc=$?
    case "$_rc" in
        0)
            _say "ARMED - a restart is pending:"
            _say "$_state"
            _verdict="$EXIT_STATUS_ARMED"
            ;;
        1)
            _say "not registered (no $TASK_NAME task) - no restart is pending"
            ;;
        *)
            _say "WARN: the schtasks query itself failed; state unknown, never absence"
            _verdict="$EXIT_STATUS_UNKNOWN"
            ;;
    esac
    if [[ -f "$LOG_UNIX" ]]; then
        _say "--- last 15 lines of $LOG_WIN"
        tail -n 15 "$LOG_UNIX" >&2
    else
        _say "no wrapper log at $LOG_WIN (the wrapper has not run since it was written)"
    fi
    return "$_verdict"
}

# Argument parsing only; --restart is never reached by accident.
main() {
    local _mode="" _folder="$FOLDER_DEFAULT" _delay="$DELAY_MINUTES_DEFAULT"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --restart) _mode="restart" ;;
            --status)  _mode="status" ;;
            --dry-run) _mode="dry-run" ;;
            --folder)  _folder="${2:?--folder needs a path}"; shift ;;
            --delay)   _delay="${2:?--delay needs minutes}"; shift ;;
            --help|-h) usage; return 0 ;;
            --version|-V) printf 'wsl-restart %s\n' "$VERSION"; return 0 ;;
            *) _say "ERROR: unknown argument: $1"; usage; return "$EXIT_USAGE" ;;
        esac
        shift
    done
    case "$_mode" in
        restart)
            # A zero-minute delay computes a trigger that has already passed, and
            # schtasks refuses a past start time - so require at least one minute
            # and let the failure be the loud kind rather than a surprise.
            [[ "$_delay" =~ ^[0-9]+$ && "$_delay" -ge 1 ]] ||
                { _say "ERROR: --delay must be a whole number of minutes, at least 1"; return "$EXIT_USAGE"; }
            arm_restart "$_folder" "$_delay"
            ;;
        status)  show_status ;;
        dry-run)
            # Renders the wrapper to stdout RAW (CRLF intact, so the line endings
            # are inspectable) and touches nothing else - no file, no task.
            render_wrapper "$_folder"
            ;;
        *) usage; return "$EXIT_USAGE" ;;
    esac
}

main "$@"

# end of file
