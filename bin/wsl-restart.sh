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
# THE CHUNK GATE (--precheck).  A restart cuts a running autotune/bench row in half
# and wastes that row's measurement, so the wrapper asks the DISTRO whether a chunk
# is in flight BEFORE it touches anything - the ledger, the process table and the box
# lock all live there, and the Windows side can read none of them.  Busy means the
# restart is SKIPPED and the distro and client are left exactly as they were; the
# next scheduled fire tries again.  A distro that is not running has nothing to cut,
# so that case proceeds.
#
# WHAT THIS SCRIPT DOES (run from WSL)
#   1. renders the Windows-side wrapper (one-shot or daily, see --schedule)
#   2. registers the task that runs it, then reads the registration back
#   3. prints the trigger; it never waits for the restart
#
# WHAT THE WRAPPER THEN DOES (Windows side, in the Task Scheduler's own session)
#   - appends every step to C:\Users\wayne\wsl-restart-action.log
#   - CHUNK GATE: asks the distro first, and stops here when a chunk is in flight
#   - closes the VS Code client: WM_CLOSE first so hot-exit can write its backups,
#     bounded, then forced
#   - `wsl.exe --shutdown`
#   - waits, bounded, for the distro to answer again
#   - relaunches the client on a fresh relay: code.cmd --remote wsl+ubuntu-24.04 <folder>
#   - deletes its own task registration, but ONLY in one-shot mode - a daily
#     schedule has to survive its own run
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
# THIS SCRIPT DOES NOT RESUME WORK.  A restart ends the Qwen session and any chunk
# launched from it: both are children of the window's extension host.  Resuming the
# autotune after a boot is bin/autotune-resume.sh's job, which is deliberately a
# separate unit because its arming is an owner decision, not a side effect here.
#
# USAGE
#   wsl-restart.sh --restart [--folder PATH] [--delay MINUTES]   one-shot restart
#   wsl-restart.sh --schedule [daily] HH:MM                      recurring restart
#   wsl-restart.sh --unschedule                                  remove the task
#   wsl-restart.sh --status                                      is one armed?
#   wsl-restart.sh --precheck                                    safe to restart now?
#   wsl-restart.sh --dry-run [--folder PATH]                     render, arm nothing
#   wsl-restart.sh --help | --version
#   --restart exits 0 when armed, 2 for a bad argument.  --status exits 0 with
#   nothing armed, 1 when a restart IS armed, 2 when the Task Scheduler could not
#   be read at all - never read that third one as "nothing armed".  --precheck
#   exits 0 clear, 1 a chunk is in flight, 2 the check itself failed (which is NOT
#   a clear).
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
# Module Version: 3
#   v3 (2026-10-15): the chunk gate (--precheck) and the prompt's own rule that a
#   restart must not cut a running row; a persistent --schedule/--unschedule, whose
#   wrapper deliberately does NOT self-delete; and the wrapper's destructive steps
#   now sit behind the gate.
#   v2 (2026-10-15): record the measured Logon Mode ("Interactive only") - it is
#   both what lets the wrapper's relaunch reach the desktop and what bounds the
#   task to a logged-on user.
VERSION="1.1.0"

set -uo pipefail

TASK_NAME="tac-wsl-restart"
DISTRO="Ubuntu-24.04"
FOLDER_DEFAULT="/home/wayne/ubuntu-console"
DELAY_MINUTES_DEFAULT=2
WAIT_TRIES=20          # wrapper: bounded distro wait, 5 s apart (100 s)
CLOSE_GRACE_SECONDS=15 # wrapper: bounded graceful-close wait before the forced kill

# Processes whose presence means a restart would cut a row in half.  Bracket-classed
# so the pattern cannot match a probe's own command line, and it covers the batch, the
# per-row driver and the bench cousins (rebench-rows.sh contains `bench-rows`).  The
# override exists so a suite can drive both branches of the gate with real processes.
CHUNK_PATTERN="${TAC_WSL_RESTART_CHUNK_PATTERN:-autotune[-]rows|run-autotune[-]batch|autotune[-]model|bench[-]rows}"

# The paths the wrapper needs, in the form the WINDOWS side must use.
WRAPPER_WIN_DEFAULT='C:\Users\wayne\wsl-restart-action.cmd'
DAILY_WRAPPER_WIN_DEFAULT='C:\Users\wayne\wsl-restart-daily.cmd'
LOG_WIN_DEFAULT='C:\Users\wayne\wsl-restart-action.log'
CODE_CMD_WIN_DEFAULT='%LOCALAPPDATA%\Programs\Microsoft VS Code\bin\code.cmd'

# Overridable so a test can exercise the argv without touching Windows state, and
# so the wrapper's location can move without editing the script.
SCHTASKS_BIN="${TAC_WSL_RESTART_SCHTASKS:-/mnt/c/Windows/System32/schtasks.exe}"
WRAPPER_WIN="${TAC_WSL_RESTART_WRAPPER_WIN:-$WRAPPER_WIN_DEFAULT}"
WRAPPER_UNIX="${TAC_WSL_RESTART_WRAPPER_UNIX:-/mnt/c/Users/wayne/wsl-restart-action.cmd}"
DAILY_WRAPPER_WIN="${TAC_WSL_RESTART_DAILY_WRAPPER_WIN:-$DAILY_WRAPPER_WIN_DEFAULT}"
DAILY_WRAPPER_UNIX="${TAC_WSL_RESTART_DAILY_WRAPPER_UNIX:-/mnt/c/Users/wayne/wsl-restart-daily.cmd}"
LOG_WIN="${TAC_WSL_RESTART_LOG_WIN:-$LOG_WIN_DEFAULT}"
LOG_UNIX="${TAC_WSL_RESTART_LOG_UNIX:-/mnt/c/Users/wayne/wsl-restart-action.log}"
CODE_CMD_UNIX_DEFAULT='/mnt/c/Users/wayne/AppData/Local/Programs/Microsoft VS Code/bin/code.cmd'
CODE_CMD_UNIX="${TAC_WSL_RESTART_CODE_CMD_UNIX:-$CODE_CMD_UNIX_DEFAULT}"
CODE_CMD_WIN="${TAC_WSL_RESTART_CODE_CMD_WIN:-$CODE_CMD_WIN_DEFAULT}"
# The chunk gate's implementation, reached from the Windows side.  ~/.local/bin is the
# stable path install.sh maintains for exactly this kind of caller.
GATE_CMD_UNIX="${TAC_WSL_RESTART_GATE_CMD:-$HOME/.local/bin/wsl-restart.sh}"

# Deliberately NOT named `log`: bin/_tac-bin-lib.sh owns that name (a gate asserts
# it is defined exactly once, there).  This script wants the caller to READ its
# output, and the file log is the wrapper's, so a private one-line stderr writer
# is the whole requirement.
_say() { printf '%s\n' "$*" >&2; }

# Exit codes, named rather than spelled as bare literals at each site so a reader
# does not have to guess what a `return 2` meant there.
EXIT_STATUS_ARMED=1    # --status: a restart IS armed (0 is the "nothing armed" case)
EXIT_STATUS_UNKNOWN=2  # --status / --precheck: could not be determined, never "clear"
EXIT_PRE_BUSY=1        # --precheck: a chunk is in flight, do NOT restart
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

# The WSL-side half of the chunk gate: is a chunk in flight RIGHT NOW?  The wrapper
# runs this before anything destructive, because a restart cuts a live row in half.
#   exit 0 = nothing running, safe to restart
#   exit 1 = a chunk is running, do NOT restart
#   exit 2 = the check itself failed, which is NOT a clear
precheck() {
    local _pids="" _rc=0 _ledger="absent (fresh boot)" _f _p
    _pids=$(pgrep -f "$CHUNK_PATTERN") || _rc=$?
    case "$_rc" in
        0)
            _say "BUSY: a chunk is in flight - restart refused"
            for _p in $_pids; do
                # A pid that exited since pgrep has no cmdline, and the gate's DECISION
                # never depends on this text - the pid is reported either way.
                # swallow-ok: /proc/<pid>/cmdline is unreadable for a pid that just exited
                _say "  pid $_p: $(tr '\0' ' ' < "/proc/$_p/cmdline" 2>/dev/null | cut -c1-110)"
            done
            # "exit 3" is the batch's own documented halt signal, not this script's.
            _say "  wait for the batch to halt on its cycle budget (exit 3), then restart"
            return "$EXIT_PRE_BUSY"
            ;;
        1)
            for _f in /dev/shm/autotune-cuda-cycles-*; do
                [[ -e "$_f" ]] || continue
                _ledger="$(< "$_f")"
            done
            _say "CLEAR: no chunk in flight; the boot CUDA cycle ledger reads $_ledger"
            return 0
            ;;
        *)
            # Fail closed: an unreadable process table must never license a restart.
            _say "UNKNOWN: pgrep failed (rc=$_rc) - not a clear, restart refused"
            return "$EXIT_STATUS_UNKNOWN"
            ;;
    esac
}

# The wrapper that runs on the Windows side.  CRLF is deliberate: cmd.exe parses a
# LF-only .cmd unreliably around labels and goto, and this file is full of both.
# `_mode` is `oneshot` (fired once, deletes its own registration) or `scheduled`
# (a daily task that must survive its own run).
render_wrapper() {
    local _folder="$1" _mode="$2" _delete_line
    if [[ "$_mode" == "oneshot" ]]; then
        _delete_line="schtasks.exe /delete /f /tn ${TASK_NAME} >> \"%LOG%\" 2>&1"
    else
        _delete_line='echo [%DATE% %TIME%] scheduled mode: registration KEPT for the next fire >> "%LOG%"'
    fi
    printf '%s\r\n' \
        '@echo off' \
        "REM Generated by ubuntu-console bin/wsl-restart.sh v${VERSION} - do not edit." \
        "REM Regenerated on every --restart/--schedule; edit the tracked script instead." \
        "REM mode=${_mode}" \
        'setlocal' \
        "set \"LOG=${LOG_WIN}\"" \
        '' \
        'echo [%DATE% %TIME%] wsl-restart-action: start >> "%LOG%"' \
        "echo [%DATE% %TIME%] mode=${_mode} >> \"%LOG%\"" \
        '' \
        'REM 0. CHUNK GATE. Ask the distro whether an autotune/bench chunk is in' \
        'REM    flight BEFORE anything destructive: a restart cuts a live row in half' \
        'REM    and wastes its measurement. The check has to run on the WSL side -' \
        'REM    the process table and the boot ledger live there. A distro that is' \
        'REM    NOT running has nothing to cut, so that case proceeds.' \
        'set GATE=clear' \
        'wsl.exe --list --running | findstr /i /c:"ubuntu" >nul 2>&1' \
        'if errorlevel 1 goto gate_clear' \
        "wsl.exe -d ${DISTRO} -u wayne -- ${GATE_CMD_UNIX} --precheck >> \"%LOG%\" 2>&1" \
        'if errorlevel 2 goto gate_unknown' \
        'if errorlevel 1 goto gate_busy' \
        'goto gate_clear' \
        ':gate_busy' \
        'set GATE=busy' \
        'echo [%DATE% %TIME%] chunk gate BUSY - restart SKIPPED, distro and client untouched >> "%LOG%"' \
        'goto final' \
        ':gate_unknown' \
        'set GATE=unknown' \
        'echo [%DATE% %TIME%] WARN: chunk gate could not answer - restart SKIPPED (fail closed) >> "%LOG%"' \
        'goto final' \
        ':gate_clear' \
        'echo [%DATE% %TIME%] chunk gate clear - proceeding >> "%LOG%"' \
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
        ':final' \
        '' \
        'REM 5. One-shot: delete our own registration (the trigger has already fired,' \
        'REM    so a failure here cannot re-fire it; a skipped restart still spends it,' \
        'REM    and the gate line above says which happened). Scheduled: KEEP it, or the' \
        'REM    daily job would remove itself on its first run.' \
        "$_delete_line" \
        'echo [%DATE% %TIME%] wsl-restart-action: done >> "%LOG%"' \
        'endlocal' \
        '# end of file'
}

# Render the wrapper onto its Windows-side path, or fail loudly - a wrapper that
# did not reach disk would be reported as armed anyway.
write_wrapper() {
    local _folder="$1" _mode="$2" _dest_unix _dest_win
    if [[ "$_mode" == "scheduled" ]]; then
        _dest_unix="$DAILY_WRAPPER_UNIX"; _dest_win="$DAILY_WRAPPER_WIN"
    else
        _dest_unix="$WRAPPER_UNIX"; _dest_win="$WRAPPER_WIN"
    fi
    if ! render_wrapper "$_folder" "$_mode" > "$_dest_unix"; then
        _say "ERROR: cannot write the wrapper to $_dest_unix"
        return 1
    fi
    _say "wrote $_dest_unix (the Windows side runs it as $_dest_win)"
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
    local _fields='TaskName|Next Run Time|Last Run Time|Last Result|Status|Task To Run|Schedule Type'
    printf '%s\n' "$_out" | grep -iE "$_fields" | sed 's/^[[:space:]]*//'
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
    # The gate's implementation must be reachable from the Windows side, or every
    # fire would skip itself as "unknown" and no restart would ever happen.
    if [[ ! -x "$GATE_CMD_UNIX" ]]; then
        _say "ERROR: the chunk gate is not executable at $GATE_CMD_UNIX"
        _say "       (install.sh links bin/* into ~/.local/bin; run it, or ln -s this script)"
        _rc=1
    fi
    return "$_rc"
}

# Say out loud when a registration is already there, before overwriting it.
warn_if_registered() {
    local _state
    if _state=$(task_state); then
        _say "WARN: a $TASK_NAME registration already exists:"
        _say "$_state"
        _say "WARN: overwriting it."
    fi
    return 0
}

# Verify the EFFECT, not the return: read the registration back and show the
# trigger.  A silent no-op here is exactly the failure this script exists to end.
confirm_armed() {
    local _state _what="$1"
    if ! _state=$(task_state); then
        _say "ERROR: /create returned success but no registration can be read back"
        return 1
    fi
    _say "armed: $_what"
    _say "$_state"
    return 0
}

# Render the wrapper and register the one-shot task that runs it on the Windows side.
arm_restart() {
    local _folder="$1" _delay="$2" _st _sd
    if ! check_preconditions; then
        return 1
    fi
    warn_if_registered
    if ! write_wrapper "$_folder" oneshot; then
        return 1
    fi

    # The trigger is a near-future MINUTE that actually fires: a spent one-time
    # trigger cannot re-fire, which is what makes this design safe even if the
    # self-delete never runs.  /sd is explicit because UK-locale Windows reads
    # DD/MM/YYYY and a crossing of midnight must land on tomorrow's date.
    _st=$(date -d "+${_delay} minutes" +%H:%M)
    _sd=$(date -d "+${_delay} minutes" +%d/%m/%Y)

    if ! _win 60 "$SCHTASKS_BIN" /create /f /tn "$TASK_NAME" \
            /tr "$WRAPPER_WIN" /sc once /sd "$_sd" /st "$_st" >/dev/null 2>&1; then
        _say "ERROR: schtasks /create failed (bounded at 60 s) - task NOT armed"
        return 1
    fi
    confirm_armed "$TASK_NAME fires at $_st on $_sd (Windows local time)" || return 1
    _say "the wrapper logs to $LOG_WIN; this session ends with the client."
    return 0
}

# Register the DAILY task.  Its wrapper keeps its own registration, because a
# schedule that deletes itself on the first run is a one-shot with extra steps.
schedule_restart() {
    local _folder="$1" _time="$2"
    if [[ ! "$_time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        _say "ERROR: --schedule needs a 24h HH:MM time, got: $_time"
        return "$EXIT_USAGE"
    fi
    if ! check_preconditions; then
        return 1
    fi
    warn_if_registered
    if ! write_wrapper "$_folder" scheduled; then
        return 1
    fi
    if ! _win 60 "$SCHTASKS_BIN" /create /f /tn "$TASK_NAME" \
            /tr "$DAILY_WRAPPER_WIN" /sc daily /st "$_time" >/dev/null 2>&1; then
        _say "ERROR: schtasks /create (daily) failed (bounded at 60 s) - NOT scheduled"
        return 1
    fi
    confirm_armed "$TASK_NAME runs daily at $_time (Windows local time)" || return 1
    _say "each fire is gated on the chunk check, so a busy box skips that night and"
    _say "tries again the next; the log records which happened: $LOG_WIN"
    return 0
}

# Remove the registration, and prove it by reading back - the /delete call itself
# has been measured hanging after doing its work, so its status is not the verdict.
unschedule() {
    if ! task_state >/dev/null 2>&1; then
        _say "nothing to remove: no $TASK_NAME registration"
        return 0
    fi
    _win 90 "$SCHTASKS_BIN" /delete /f /tn "$TASK_NAME" >/dev/null 2>&1
    if task_state >/dev/null 2>&1; then
        _say "ERROR: the registration is still readable after /delete"
        return 1
    fi
    _say "removed: no $TASK_NAME registration remains"
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
    local _mode="" _folder="$FOLDER_DEFAULT" _delay="$DELAY_MINUTES_DEFAULT" _time="" _want=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --restart)    _mode="restart" ;;
            --status)     _mode="status" ;;
            --precheck)   _mode="precheck" ;;
            --unschedule) _mode="unschedule" ;;
            --dry-run)    _mode="dry-run" ;;
            --schedule)   _mode="schedule"; shift; _want="${1:-}"
                          if [[ "$_want" == "daily" ]]; then shift; _want="${1:-}"; fi
                          _time="$_want" ;;
            --folder)     _folder="${2:?--folder needs a path}"; shift ;;
            --delay)      _delay="${2:?--delay needs minutes}"; shift ;;
            --help|-h)    usage; return 0 ;;
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
        schedule)   schedule_restart "$_folder" "$_time" ;;
        unschedule) unschedule ;;
        status)     show_status ;;
        precheck)   precheck ;;
        dry-run)
            # Renders the wrapper to stdout RAW (CRLF intact, so the line endings
            # are inspectable) and touches nothing else - no file, no task.
            render_wrapper "$_folder" oneshot
            ;;
        *) usage; return "$EXIT_USAGE" ;;
    esac
}

main "$@"

# end of file
