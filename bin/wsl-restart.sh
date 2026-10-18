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
#   1. renders the Windows-side wrapper and the operator gate (one-shot or daily,
#      see --schedule)
#   2. registers the task that runs it, then reads the registration back
#   3. prints the trigger; it never waits for the restart
#
# WHAT THE WRAPPER THEN DOES (Windows side, in the Task Scheduler's own session)
#   - appends every step to C:\Users\wayne\wsl-restart-action.log
#   - CHUNK GATE: asks the distro first, and stops here when a chunk is in flight
#   - OPERATOR GATE: when the box looks OBVIOUSLY IN USE (a VS Code client running
#     AND input within the idle window), a popup asks whether to cancel, and expires
#     by itself after a few seconds.  No answer, an OK, a missing prompt, or a popup
#     that cannot be shown all mean RESTART AS PLANNED - the schedule stays the
#     default and cancelling is the exception.  ONLY an explicit Cancel stops it; that
#     re-arms the task for a later retry and SKIPS the self-delete below.
#   - COMPACTS the VS Code state DBs while the client is down (step 3b, through
#     bin/vscode-state-compact.sh): only a VACUUM returns the pages a deleted value
#     freed, and this is the one window in which nothing holds those DBs open.
#     OPPORTUNISTIC - its output is logged and its exit code never gates the relaunch.
#   - closes the VS Code client: WM_CLOSE first so hot-exit can write its backups,
#     bounded, then forced
#   - `wsl.exe --shutdown`
#   - waits, bounded, for the distro to answer again
#   - relaunches EVERY window the restart closed, each on a fresh relay, from the URIs step 0c
#     captured (vscode-remote://...); the configured folder is the fallback:
#     code.cmd --remote wsl+ubuntu-24.04 <folder>
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
#   wsl-restart.sh --restart [--folder PATH] [--delay MINUTES]   one-shot restart in N min
#   wsl-restart.sh --schedule HH:MM                              one-shot restart at HH:MM
#   wsl-restart.sh --schedule daily HH:MM                        recurring (daily) restart
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
# Module Version: 18
#   v18 (2026-10-18): same change, one line shortened to stay under the 120-column bound (8.1.8).
#   v17 (2026-10-18): STEP 3a STARTS THE GATEWAY AGAIN, EVEN IF IT WAS DOWN BEFORE THE RESTART.
#   v16 stopped it before the teardown, which cured the mid-drain kill — but stopping is half the
#   job: `enabled` is not `running`, so a gateway that was ALREADY down (a failed start, an update
#   window, a hand stop) stayed down across the reboot, because the only thing that normally starts
#   it is the boot itself.  Ordered by Wayne: "update the restart code to restart gateway even if
#   the gatway was down before restart".  Step 3a runs `gateway-quiesce.sh --ensure-running` through
#   the same hop, which issues `systemctl --user start` — idempotent, so it is a no-op when the boot
#   already brought the unit up, and never a `restart` that would stack a second stop on a gateway
#   still cold-starting.  Bounded and non-gating: a refusal is logged and the relaunch proceeds.
#   v16 (2026-10-17): STEP 1b QUIESCES THE GATEWAY BEFORE THE VM IS TORN DOWN.  `wsl.exe
#   --shutdown` kills every process in the distro, and a gateway killed that way is killed
#   MID-DRAIN.  Measured at the 12:41 restart: `[admission] closed: stop (SIGTERM)` at 12:41:21,
#   `draining active work before stop … sessionAdmissions=1` at 12:41:22, the VM down at 12:41:48
#   — and the NEXT start REFUSED at 12:42:53: "OpenClaw state at …/openclaw.sqlite is undergoing
#   offline maintenance; retry when it finishes", costing a second attempt and ~8 minutes before
#   /health answered 200.  The 10:48 restart cost three attempts and ~13 minutes the same way.
#   The wrapper now runs bin/gateway-quiesce.sh through the same `wsl.exe -d … -- <cmd>` hop the
#   gate and the compaction step use: it stops the unit and waits, bounded, for systemd to report
#   it inactive.  It NEVER gates the restart — a WARN in its excerpt means the stop did not land
#   and the restart proceeds anyway, because a restart that does not happen is worse than a
#   gateway that starts uncleanly.  This is the third mechanism measured in this area and the
#   first that acts on the SHUTDOWN rather than on stacking (e35754dc) or the guard (9abb008c).
#   v15 (2026-10-17): THE ARM SURFACES ITS OWN CAUSE, AND CLEARS A SPENT LEFTOVER FIRST.  Measured the
#   same day at 03:04 BST: the loop could not arm and the journal carried only "schtasks /create failed
#   (bounded at 60 s) - task NOT armed", because the call discarded its own output - reconstructing the
#   cause then took several probes and still did not converge.  A SPENT registration WAS present at that
#   moment (`--status`: "registered but SPENT", Next Run Time N/A), so the arm now deletes a leftover
#   registration before creating (bounded 30 s, and a refusal is REPORTED rather than assumed), and a
#   failed /create prints the tool's own first lines.  `/create` itself measured healthy (rc 0 in 1 s on
#   a fresh name), so a name-independent failure is unlikely and the leftover is the prime suspect;
#   clearing it removes the class whether or not it was this instance's cause.  The bound still ABORTS -
#   nothing here waits unbounded.
#   v14 (2026-10-17): ONLY a WSL folder may be reopened as a WSL REMOTE WINDOW.  Wayne's ruling,
#   2026-10-17, verbatim: "ensure that only wsl repos are opened in wsl remote in vs code. eg quicken
#   prices should not be opened in wsl mode."  The client serialises a WINDOWS folder that was opened
#   from the distro side as `vscode-remote://wsl+<distro>/<drive>:/...` - a WSL authority wrapping a
#   Windows drive path - so step 4 relaunched it as a WSL remote window pointing at a path that cannot
#   exist in the distro (measured 2026-10-17: the capture carried `.../wsl+ubuntu-24.04/c:/Users/wayne/
#   GitHub/Python/Projects/quicken_prices`).  capture_windows now rewrites that shape to its LOCAL
#   `file:///<drive>:/...` form, which step 4 reopens with `--folder-uri` as an ordinary Windows window.
#   The tell is the single-letter drive segment, which cannot be an absolute Linux path, so the rule
#   cannot touch a real WSL folder.  A unit case pins both directions: the Windows path becomes local,
#   and a genuine `/home/...` path is left as a WSL remote.
#   v13 (2026-10-17): v12's `call` ADDS A SECOND PERCENT-EXPANSION PASS, and that pass ate the `%2`
#   of `wsl%2B<distro>` and the `%3` of `file:///c%3A`, so every window the restart resurrected came
#   up corrupt and disconnected.  Measured in a scratch .cmd reproducing this file's OWN `for /f` +
#   `call` construct under `cmd /c`: the file's `vscode-remote://wsl%2Bubuntu-24.04/p` reaches the
#   callee as `vscode-remote://wslBubuntu-24.04/p` - the `%2` expands to the (empty) second argument
#   and the `B` survives - which is exactly the client's refusal, "Invalid remote authority:
#   wslBubuntu-24.04", and `file:///c%3A/Users/wayne/x` arrived as `file:///cA/Users/wayne/x`.
#   Measured the two forms that DO survive: a DOUBLED `%` (`wsl%%2B...` -> `wsl%2B...`, `c%%3A/x` ->
#   `c%3A/x`) and the DECODED character (`wsl+ubuntu-24.04` passed through untouched).  capture_windows
#   now takes the second: it decodes `%2B`->`+` and `%3A`->`:` so the list carries the authority the
#   client stores anyway, doubles any remaining `%` so no other escape can be eaten, and REPAIRS an
#   authority that an earlier corrupt fire already wrote back into the client's own storage
#   (`vscode-remote://wsl<not-plus>...<distro>/` -> `wsl+<distro>/`) - storage is this capture's own
#   input, so without that repair the broken window is resurrected on every subsequent restart.
#   The configured-folder FALLBACK gets the same `%`-doubling.  A unit case cannot prove cmd.exe
#   behaviour, so the case pins the RENDERED mechanism (no bare `%` survives to the `call`).
#   v12 (2026-10-16): THE WRAPPER'S TAIL NEVER RAN, so the one-shot never self-deleted.  Measured:
#   `grep -c 'wsl-restart-action: done'` = 0 against 16 `start` lines, and the 16:37 fire's log ends
#   at the three `relaunching window:` echoes with nothing after them.  The tail holds the ONE-SHOT's
#   self-delete, so every fire left a SPENT registration (`Next Run Time: N/A`, `Status: Ready`) whose
#   trigger can never fire again - and `--status` reported that stale token as ARMED, which is what
#   stood a watcher down mid-task.  Two fixes, one per half.  (a) The relaunch now invokes the client
#   through `call`: a .cmd invoked from a .cmd WITHOUT `call` does not return to its caller, a standard
#   cmd.exe rule, and the relaunch is the ONE place here that hands control to another batch file.
#   (b) `--status` no longer calls a registration ARMED when it has no trigger left: a one-shot whose
#   `Next Run Time` is `N/A`/empty is reported as SPENT, so the report matches the mechanism whatever
#   killed the tail.  A unit case cannot prove the RUNTIME here (it is cmd.exe behaviour, not rendered
#   text) - it pins the mechanism, the same shape as the operator gate's stdout case.
#   v11 (2026-10-16): a BARE `--schedule HH:MM` is now ONE-SHOT.  Wayne's `--schedule 22:57`
#   was expected to arm a single restart but registered a DAILY task instead, and the next
#   one-shot arm (`--restart --delay`) OVERWROTE it - so NOTHING was armed and the evening
#   campaign never started (measured 2026-10-16: the bare time produced `/sc daily`, and a
#   later `--status`-less sweep read nothing scheduled).  A bare time now arms a ONE-SHOT at
#   that clock time - today when it is still ahead, else tomorrow - and its wrapper deletes
#   its own registration.  `daily HH:MM` (and the explicit `once HH:MM` synonym) select the
#   form, so the recurring meaning has to be asked for.
#   v10 (2026-10-16): v9 CAPTURED NOTHING in production.  It matched `"folder":"` exactly while
#   VS Code writes `"folder": "` - a space - so the window list was always empty and step 4 fell
#   back to the one configured folder, which is the very defect v9 exists to fix.  Measured in
#   wsl-restart-action.log at 05:39: "capture: 0 open window(s)" then "no captured windows".
#   The pattern is whitespace-tolerant now, and the case's fixture uses the REAL spacing, which
#   is why the case could not disagree before.
#   v9 (2026-10-15): EVERY window the restart closes is reopened, not just the configured
#   folder (Wayne: "restart all instances of vs code that were closed, not just the
#   ubuntu-console instance").  Step 0c captures VS Code's own windowsState.openedWindows as
#   one vscode-remote:// URI per open window - measured 3 open, each on wsl+ubuntu-24.04 -
#   and step 4 loops that list with --folder-uri, which reopens a window on its OWN authority
#   and folder.  The configured folder stays as the FALLBACK, so an unreadable capture behaves
#   exactly as v8 did.  The capture runs on the DISTRO side through the wrapper's existing
#   `wsl.exe -d ... -- <cmd>` hop, so no PowerShell is quoted inside the .cmd.
#   v8 (2026-10-15): step 3b's block moved OUT of render_wrapper into
#   render_compaction_step().  Inlining it had pushed that function past the §18.3 10.4
#   hundred-line bound, which the pre-push ratchet caught and refused - the same
#   extraction the operator gate needed, for the same reason.  No behaviour change; the
#   generated order is unchanged and pinned by a case.
#   v7 (2026-10-15): step 3b — COMPACT the VS Code state DBs inside the window this
#   wrapper already creates.  The client is killed in step 1 and relaunched in step 4,
#   so between the distro answering and that relaunch nothing holds those DBs open,
#   and only a VACUUM returns the pages a deleted value freed (measured: 152,252,416
#   free of 153,202,688 in the profile's state.vscdb).  It runs bin/vscode-state-compact.sh
#   through wsl.exe, logs its output, and NEVER branches on it: the restart is the job.
#   The helper's absence is an arm-time WARN, not a precondition failure.
#   v6 (2026-10-15): the cancel path EXITS.  v4 "named" the cancel code and dropped
#   the `exit` with it, so the generated script evaluated `$CancelCode` and fell off
#   the end - PowerShell exits 0, which the wrapper reads as "restart as planned", so
#   a Cancel would have been IGNORED and the window would have closed anyway.
#   tests/unit/60-wsl-restart.bats:360 caught it (the tip's CI was red on that case)
#   and the fix is `exit $CancelCode`.
#   v5 (2026-10-15): the gate's own logging goes to STDOUT.  The first live fire
#   (12:25 BST) proved the gate RAN - the wrapper logged "operator gate clear -
#   proceeding" - but every line the gate wrote was lost: it Add-Content'd to the
#   wrapper's log file, which the wrapper holds OPEN for the whole run, so PowerShell
#   raised GetContentWriterIOError at wsl-restart-prompt.ps1:15.  The wrapper already
#   appends the gate's stdout to that same log, so Write-Output is both lock-free and
#   in the one place a reader looks.  A unit case cannot see this class (it is a
#   runtime file-lock, not rendered text); the case added here pins the MECHANISM.
#   v4 (2026-10-15): the OPERATOR GATE (Wayne's ask: "if it is obvious i am using vs
#   code, i get to choose if the wsl restart goes ahead or not ... if i dont answer
#   within 10 seconds, we restart as planned").  The wrapper runs a rendered
#   PowerShell prompt BEFORE anything is closed; it asks only when the box looks
#   obviously in use (a VS Code client running AND input within the idle window), its
#   popup expires by itself, and the EXPIRY RESOLVES TO THE RESTART - so the schedule
#   stays the default and cancelling is the exception.  A cancel re-arms the task for
#   a retry and SKIPS the wrapper's self-delete, which would otherwise remove the
#   registration the gate has just refreshed.
#   v3 (2026-10-15): the chunk gate (--precheck) and the prompt's own rule that a
#   restart must not cut a running row; a persistent --schedule/--unschedule, whose
#   wrapper deliberately does NOT self-delete; and the wrapper's destructive steps
#   now sit behind the gate.
#   v2 (2026-10-15): record the measured Logon Mode ("Interactive only") - it is
#   both what lets the wrapper's relaunch reach the desktop and what bounds the
#   task to a logged-on user.
VERSION="1.2.0"

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

# The OPERATOR GATE (Wayne, 2026-10-15): when the box is OBVIOUSLY in use, the
# restart asks before it closes a window someone is reading.  "Obviously in use" is
# a running VS Code client AND input within IDLE seconds; the choice is a popup that
# expires after TIMEOUT seconds, and the EXPIRY RESOLVES TO THE PLAN - no answer
# means the restart proceeds, so the schedule stays the default and cancelling is the
# exception.  A cancel re-arms the task for RETRY minutes rather than killing the
# campaign, because the campaign is what asked for the restart.
PROMPT_WIN_DEFAULT='C:\Users\wayne\wsl-restart-prompt.ps1'
PROMPT_IDLE_S="${TAC_WSL_RESTART_PROMPT_IDLE_S:-120}"
PROMPT_TIMEOUT_S="${TAC_WSL_RESTART_PROMPT_TIMEOUT_S:-10}"
PROMPT_RETRY_MIN="${TAC_WSL_RESTART_PROMPT_RETRY_MIN:-20}"
PROMPT_WIN="${TAC_WSL_RESTART_PROMPT_WIN:-$PROMPT_WIN_DEFAULT}"
PROMPT_UNIX="${TAC_WSL_RESTART_PROMPT_UNIX:-/mnt/c/Users/wayne/wsl-restart-prompt.ps1}"
# The chunk gate's implementation, reached from the Windows side.  ~/.local/bin is the
# stable path install.sh maintains for exactly this kind of caller.
GATE_CMD_UNIX="${TAC_WSL_RESTART_GATE_CMD:-$HOME/.local/bin/wsl-restart.sh}"
# The compaction step the wrapper runs while the client is CLOSED (step 3b): only a VACUUM
# returns the pages a deleted value freed, and this restart is the one window where nothing
# holds the state DBs open.  Same stable path convention as the gate.
COMPACT_CMD_UNIX="${TAC_WSL_RESTART_COMPACT_CMD:-$HOME/.local/bin/vscode-state-compact.sh}"
# The QUIESCE step (1b) the wrapper runs BEFORE `wsl.exe --shutdown`: it stops the OpenClaw
# gateway and waits for it to go inactive, so the next boot's start is not refused by the state
# DB's "offline maintenance" marker (see the Module Version note).  Same stable path convention.
QUIESCE_CMD_UNIX="${TAC_WSL_RESTART_QUIESCE_CMD:-$HOME/.local/bin/gateway-quiesce.sh}"

# The window list the CAPTURE step writes and step 4 reads back: every VS Code window OPEN at
# restart time, one vscode-remote:// URI per line.
# Wayne, 2026-10-15: the wrapper closed EVERY Code.exe instance and then relaunched ONE window
# (`--remote wsl+<distro> <folder>`), so every other window the restart had closed stayed closed.
# The source is VS Code's OWN windowsState (measured the same day: 3 open windows, each a
# `vscode-remote://wsl%2B<distro>/<path>` URI), so the list is exactly what the client would
# have restored.  Windows-visible on purpose: the generated .cmd reads it with `for /f`, and the
# capture itself runs on the DISTRO side through the wrapper's existing `wsl.exe -d ... -- <cmd>`
# hop - which is also why it needs no PowerShell quoting inside a batch file.
STORAGE_UNIX_DEFAULT='/mnt/c/Users/wayne/AppData/Roaming/Code/User/globalStorage/storage.json'
WINDOWS_TXT_WIN_DEFAULT='C:\Users\wayne\wsl-restart-windows.txt'
STORAGE_UNIX="${TAC_WSL_RESTART_STORAGE_UNIX:-$STORAGE_UNIX_DEFAULT}"
WINDOWS_TXT_WIN="${TAC_WSL_RESTART_WINDOWS_TXT_WIN:-$WINDOWS_TXT_WIN_DEFAULT}"
WINDOWS_TXT_UNIX="${TAC_WSL_RESTART_WINDOWS_TXT_UNIX:-/mnt/c/Users/wayne/wsl-restart-windows.txt}"

# capture_windows — write the OPEN windows' URIs to the list step 4 relaunches from.  Runs on
# the distro side, BEFORE the client is closed, because the client owns this state file while it
# is up.  It never fails the restart: an unreadable file or no windows leaves an EMPTY list, and
# step 4 then falls back to the single configured folder - the behaviour that existed before.
capture_windows() {
    local _n=0
    : > "$WINDOWS_TXT_UNIX"
    if [[ ! -r "$STORAGE_UNIX" ]]; then
        _say "capture: no window state at $STORAGE_UNIX - step 4 falls back to the configured folder"
        return 0
    fi
    # `"folder": "<uri>"` appears once per open window in windowsState.openedWindows; JSON does
    # not escape `/`, so the value is taken verbatim.  sorted -u so a window listed twice in the
    # file is relaunched once, never twice.
    # THE SPACE AFTER THE COLON IS REAL, and it cost a production no-op: v9 matched `"folder":"`
    # exactly while the file writes `"folder": "`, so 0 windows were captured and step 4 fell
    # back to one folder - measured 2026-10-16 05:39 in wsl-restart-action.log ("capture: 0 open
    # window(s)" then "no captured windows").  The case's fixture omitted the space too, so it
    # could not disagree.  [[:space:]]* accepts either serialisation.
    # Each line is `<kind>|<uri>`: a folder window reopens with --folder-uri, a multi-root
    # workspace window (`"configPath"`) with --file-uri, so workspace windows are not dropped.
    # v13: the wrapper hands each value to the client through `call`, whose SECOND percent pass ate
    # the `%2` of `%2B` and the `%3` of `%3A` (measured; see the Module Version note).  So decode the
    # two escapes these URIs actually carry, double whatever `%` is left so no other escape can be
    # eaten, and repair an authority an earlier corrupt fire wrote back into this capture's own
    # INPUT - without the repair, a stored `wslbubuntu-24.04` is re-emitted, re-launched, and the
    # broken window comes back on every restart.  The repair matches the LOWERCASED distro because
    # that is what a URI authority carries (`wsl+ubuntu-24.04`), while $DISTRO is WSL's own casing
    # (`Ubuntu-24.04`); matching $DISTRO here would have matched nothing and repaired nothing.
    # v14: the authority repair runs BEFORE the drive-path rewrite, because a corrupt authority
    # (`wslbubuntu-24.04`) does not match the rewrite's `wsl+` prefix and would never be rewritten.
    # The order is decode -> repair -> drive-path -> double, and the doubling is LAST so that a `%`
    # introduced by an earlier rule cannot slip through to the `call` unescaped.
    # swallow-ok: the client can be mid-write here, and an EMPTY list IS the answer - step 4 falls back
    grep -oE '"(folder|configPath)":[[:space:]]*"[^"]*"' "$STORAGE_UNIX" 2>/dev/null |
        sed -E -e 's/^"folder":[[:space:]]*"/folder-uri|/' \
               -e 's/^"configPath":[[:space:]]*"/file-uri|/' \
               -e 's/"$//' \
               -e 's/%2B/+/g' \
               -e 's/%3A/:/g' \
               -e "s#(vscode-remote://)wsl[^+/]*${DISTRO,,}/#\1wsl+${DISTRO,,}/#" \
               -e 's#^([a-z]+-uri[|])vscode-remote://wsl[+][^/]+/([A-Za-z]):/#\1file:///\2:/#' \
               -e 's/%/%%/g' |
        sort -u > "$WINDOWS_TXT_UNIX"
    # swallow-ok: grep -c exits 1 on zero matches, and zero IS the count this line reports
    _n=$(grep -c . "$WINDOWS_TXT_UNIX" 2>/dev/null) || _n=0
    _say "capture: $_n open window(s) -> $WINDOWS_TXT_UNIX"
    return 0
}

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

# The OPERATOR GATE, rendered as the PowerShell the wrapper calls before it touches
# anything.  WHY IT EXISTS (Wayne, 2026-10-15): the restart is armed UNATTENDED, and
# closing the client under someone who is reading is the one cost the campaign should
# not pay silently.  The window is deliberately short and its expiry resolves to the
# PLAN - that is what keeps this a courtesy rather than a second, hidden approval.
render_prompt() {
    printf '%s\n' \
        "# Generated by ubuntu-console bin/wsl-restart.sh v${VERSION} - do not edit." \
        '# OPERATOR GATE - ask before a restart that would close a window in use.' \
        '# Exit 0 = restart as planned.  Exit 3 = the operator cancelled it.' \
        '# Its own lines go to STDOUT, which the wrapper appends to its log: writing to' \
        '# that log DIRECTLY fails, because the wrapper holds it open for the whole run' \
        '# and Add-Content raises GetContentWriterIOError (measured 2026-10-15 12:25).' \
        'param(' \
        "  [int]\$IdleSeconds = ${PROMPT_IDLE_S}," \
        "  [int]\$TimeoutSeconds = ${PROMPT_TIMEOUT_S}," \
        "  [int]\$RetryMinutes = ${PROMPT_RETRY_MIN}," \
        "  [string]\$WrapperWin = '${WRAPPER_WIN}'," \
        "  [string]\$TaskName = '${TASK_NAME}'" \
        ')' \
        '' \
        'function Write-Gate([string]$m) {' \
        '    $stamp = (Get-Date).ToString("dd/MM/yyyy HH:mm:ss")' \
        '    Write-Output "[$stamp] operator gate: $m"' \
        '}' \
        '' \
        '# The code the wrapper treats as a CANCEL - its `if errorlevel 3` branch.' \
        '$CancelCode = 3' \
        '' \
        '# How long since the last input ANYWHERE on this desktop.  A failure to read it' \
        '# is treated as "in use", so the fallback is to ASK rather than to skip the ask.' \
        '$idle = -1' \
        'try {' \
        '    Add-Type -Namespace TacPrompt -Name Idle -MemberDefinition @"
        [DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
        [StructLayout(LayoutKind.Sequential)] public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
        public static uint IdleMs() {
            var i = new LASTINPUTINFO();
            i.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
            if (!GetLastInputInfo(ref i)) { return 4294967295u; }
            return unchecked((uint)Environment.TickCount) - i.dwTime;
        }
"@' \
        '    $idle = [int]([TacPrompt.Idle]::IdleMs() / 1000)' \
        '} catch {' \
        '    Write-Gate "idle probe FAILED ($($_.Exception.Message)) - asking anyway"' \
        '}' \
        '' \
        '$code = @(Get-Process -Name Code -ErrorAction SilentlyContinue).Count' \
        'if ($code -eq 0) {' \
        '    Write-Gate "no VS Code client running - restart as planned"' \
        '    exit 0' \
        '}' \
        'if ($idle -ge $IdleSeconds) {' \
        '    Write-Gate "client running but idle ${idle}s (>= $IdleSeconds) - restart as planned"' \
        '    exit 0' \
        '}' \
        '' \
        '# OBVIOUSLY IN USE.  The popup is topmost and expires by itself; -1 is the' \
        '# expiry, and an expiry, an OK or a popup that could not be shown all mean the' \
        '# restart proceeds.  ONLY an explicit Cancel stops it.' \
        '$answer = -1' \
        'try {' \
        '    $ws = New-Object -ComObject WScript.Shell' \
        '    $text = "A WSL restart is due now (autotune).  VS Code looks in use' \
        '        (input ${idle}s ago).  Cancel to keep this session open."' \
        "    \$answer = \$ws.Popup(\$text, \$TimeoutSeconds, 'WSL restart', 4096 + 48 + 1)" \
        '} catch {' \
        '    Write-Gate "popup could not be shown ($($_.Exception.Message)) - restart as planned"' \
        '    exit 0' \
        '}' \
        'if ($answer -ne 2) {' \
        '    Write-Gate "no cancel (popup returned $answer) - restart as planned"' \
        '    exit 0' \
        '}' \
        '' \
        '# CANCELLED.  Re-arm rather than quit: the campaign asked for this restart, so a' \
        '# cancel postpones it.  The wrapper SKIPS its own delete on this path, or it' \
        '# would remove the registration being refreshed here.' \
        '$when = (Get-Date).AddMinutes($RetryMinutes)' \
        'Write-Gate "CANCELLED by the operator - re-arming for $($when.ToString("dd/MM/yyyy HH:mm"))"' \
        '& schtasks.exe /create /f /tn $TaskName /tr $WrapperWin /sc once `' \
        '    /sd $when.ToString("dd/MM/yyyy") /st $when.ToString("HH:mm") 2>&1 `' \
        '    | ForEach-Object { Write-Gate "schtasks: $_" }' \
        'exit $CancelCode' \
        '# end of file'
}

# The wrapper's OPERATOR GATE block, printed by its own function so render_wrapper
# stays a readable list of STEPS rather than one hundred-line printf (§18.3 10.4).
# Exit 3 from the prompt is the ONLY cancel; a missing prompt, a crash, an OK and the
# popup's own expiry all fall through to the restart.
render_operator_gate() {
    printf '%s\r\n' \
        '' \
        'REM 0b. OPERATOR GATE. Run the prompt FIRST, before anything is closed: it asks' \
        'REM     only when the box looks obviously in use (a VS Code client running AND' \
        'REM     input within the idle window), its popup expires by itself, and the' \
        'REM     EXPIRY RESOLVES TO THIS RESTART: it goes ahead unless the operator' \
        'REM     cancels, and a cancel is the ONLY thing that stops it.  On a cancel the' \
        'REM     gate has already re-armed the task, so this wrapper must NOT delete it.' \
        'if not exist "%PROMPT%" (' \
        '    echo [%DATE% %TIME%] WARN: operator gate missing at %PROMPT% - restarting without asking >> "%LOG%"' \
        '    goto operator_go' \
        ')' \
        'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PROMPT%" >> "%LOG%" 2>&1' \
        'if errorlevel 3 goto operator_cancel' \
        'if errorlevel 1 echo [%DATE% %TIME%] WARN: gate exited %ERRORLEVEL% - restart as planned >> "%LOG%"' \
        ':operator_go' \
        'echo [%DATE% %TIME%] operator gate clear - proceeding >> "%LOG%"'
}

# The wrapper's COMPACTION step (3b), printed by its own function so render_wrapper stays a
# readable list of STEPS.  It runs inside the window this wrapper creates - the client is
# killed in step 1 and relaunched in step 4 - and it is never branched on: the restart is
# the job, so a locked DB or a missing helper costs an opportunity, never the relaunch.
render_compaction_step() {
    printf '%s\r\n' \
        'REM 3b. COMPACT the VS Code state DBs. The client was killed in step 1 and is' \
        'REM     relaunched BELOW, so this is the one moment nothing holds those DBs' \
        'REM     open - and only a VACUUM returns the pages a deleted value freed' \
        'REM     (measured 2026-10-15: 152,252,416 free of 153,202,688). It is' \
        'REM     OPPORTUNISTIC: the RESTART IS THE JOB. Its output is logged, its exit' \
        'REM     code is NOT branched on, and a missing helper or a locked DB cannot' \
        'REM     stop the relaunch - so this line never gates anything.' \
        "wsl.exe -d ${DISTRO} -u wayne -- ${COMPACT_CMD_UNIX} >> \"%LOG%\" 2>&1" \
        ''
}

# The wrapper's CAPTURE step (0c), printed by its own function so render_wrapper stays a
# readable list of STEPS.  It runs AFTER the operator gate (a cancel must not capture) and
# BEFORE step 1, because the client owns the state file while it is up.  The capture runs on
# the DISTRO side through the same `wsl.exe -d ... -- <cmd>` hop the gate and the compaction
# use, so no PowerShell has to be quoted inside a batch file.  It never gates the restart: a
# failure leaves an EMPTY list and step 4 falls back to the configured folder.
render_capture_step() {
    printf '%s\r\n' \
        'REM 0c. CAPTURE the open windows BEFORE step 1 closes them.  Every window this' \
        'REM     restart is about to close is recorded as its own vscode-remote:// URI, so' \
        'REM     step 4 can reopen ALL of them instead of only the configured folder.' \
        "wsl.exe -d ${DISTRO} -u wayne -- ${GATE_CMD_UNIX} --capture-windows >> \"%LOG%\" 2>&1" \
        ''
}

# The wrapper's RELAUNCH step (4), printed by its own function so render_wrapper stays a
# readable list of STEPS - the SAME extraction the operator gate and the compaction step
# needed (v8), because inlining this block pushed render_wrapper past the §18.3 10.4
# hundred-line bound and the pre-push ratchet refused it.  It reopens EVERY window step 0c
# captured, each on its OWN authority and folder; the configured folder is the FALLBACK, so
# an unreadable capture behaves exactly as it did before v9.
render_relaunch_step() {
    local _folder="$1"
    printf '%s\r\n' \
        'REM 4. Relaunch EVERY window that was open, on a fresh relay. Absolute, because' \
        'REM    the wrapper gets no shell profile. Step 0c captured the URIs, and' \
        'REM    --folder-uri reopens a window on its OWN authority and folder. The' \
        'REM    configured folder is the FALLBACK (Wayne, 2026-10-15: this step used to' \
        'REM    relaunch one window and leave every other window the restart closed shut).' \
        "set \"CODE_CMD=${CODE_CMD_WIN}\"" \
        "set \"WINDOWS_TXT=${WINDOWS_TXT_WIN}\"" \
        'set RELAUNCHED=0' \
        'if exist "%WINDOWS_TXT%" for /f "usebackq tokens=1,2 delims=|" %%K in ("%WINDOWS_TXT%") do (' \
        '    echo [%DATE% %TIME%] relaunching window: %%K %%L >> "%LOG%"' \
        '    REM `call` is load-bearing - a .cmd invoked from a .cmd WITHOUT it does not return,' \
        '    REM so this step would never hand control back and the self-delete below never ran.' \
        '    REM Measured 2026-10-16 - the wrapper logged ZERO done lines across 16 fires.' \
        '    call "%CODE_CMD%" --%%K "%%L" >> "%LOG%" 2>&1' \
        '    set RELAUNCHED=1' \
        ')' \
        'if "%RELAUNCHED%"=="0" (' \
        "    echo [%DATE% %TIME%] no captured windows - relaunching the configured folder >> \"%LOG%\"" \
        "    echo [%DATE% %TIME%] relaunching: %CODE_CMD% --remote wsl+${DISTRO} ${_folder} >> \"%LOG%\"" \
        "    call \"%CODE_CMD%\" --remote wsl+${DISTRO} \"${_folder//%/%%}\" >> \"%LOG%\" 2>&1" \
        ')'
}

# The wrapper's QUIESCE step (1b), printed by its own function for the same §18.3 reason as the
# gate and the compaction step: render_wrapper stays a readable list of STEPS.
# MEASURED 2026-10-17 — the VM killed the gateway mid-drain at 12:41:48 and the NEXT start was
# refused with "state … is undergoing offline maintenance", costing a retry and ~8 minutes; the
# 10:48 restart cost three attempts and ~13 minutes the same way.
render_quiesce_step() {
    printf '%s\r\n' \
        '' \
        'REM 1b. QUIESCE the OpenClaw gateway BEFORE the VM is torn down. A gateway killed by' \
        'REM     --shutdown leaves its state DB marked "undergoing offline maintenance", and the' \
        'REM     NEXT start is then REFUSED (measured 2026-10-17: refused at 12:42:53 after a' \
        'REM     mid-drain kill at 12:41:48 — a retry and ~8 minutes; the 10:48 restart cost' \
        'REM     three attempts and ~13). The helper stops the unit and waits, BOUNDED, for' \
        'REM     systemd to report it inactive. It NEVER gates the restart: a WARN in its' \
        'REM     excerpt means the stop did not land, and the restart proceeds anyway.' \
        "wsl.exe -d ${DISTRO} -u wayne -- ${QUIESCE_CMD_UNIX} >> \"%LOG%\" 2>&1" \
        ''
}

# STEP 3a — the gateway is STARTED again once the VM answers (v17).  Step 1b stops it before
# the teardown, but stopping is only half the job: `enabled` is not `running`, so a gateway
# that was ALREADY down before the restart (a failed start, an update window, a hand stop)
# stayed down, because the only thing that normally starts it is the boot itself.  The
# helper's `--ensure-running` uses `systemctl --user start` — idempotent, so it is a no-op
# when the boot already brought the unit up, and never a `restart` that would stack a second
# stop on a gateway still cold-starting.  Bounded, and it never gates the relaunch.
render_gateway_start_step() {
    printf '%s\r\n' \
        '' \
        'REM 3a. START the OpenClaw gateway again - even if it was down BEFORE the restart.' \
        'REM     Step 1b stopped it; an enabled unit normally returns at boot, but a gateway' \
        'REM     that was already down (failed start, update window, hand stop) would stay' \
        'REM     down. `systemctl --user start` is a no-op when it is already running, so this' \
        'REM     never stacks a restart. Bounded; a refusal is logged and the relaunch' \
        'REM     proceeds - the exit code is reported, never trusted to be zero.' \
        "wsl.exe -d ${DISTRO} -u wayne -- ${QUIESCE_CMD_UNIX} --ensure-running >> \"%LOG%\" 2>&1" \
        "if errorlevel 1 echo [%DATE% %TIME%] WARN: gateway start unconfirmed - see ensure: >> \"%LOG%\"" \
        ''
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
        "set \"PROMPT=${PROMPT_WIN}\"" \
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
        'echo [%DATE% %TIME%] chunk gate clear - proceeding >> "%LOG%"'
    # The operator gate prints itself (render_operator_gate): keeping it inline pushed
    # this function past the §18.3 10.4 hundred-line bound, and the STEP LIST is what a
    # reader comes here for.
    render_operator_gate
    render_capture_step
    printf '%s\r\n' \
        '' \
        'REM 1. Close the VS Code client. WM_CLOSE first so hot-exit writes its' \
        'REM    backups, bounded, then forced. This is the half that clears the' \
        'REM    cached remote relay: only a fresh app process re-resolves it.' \
        'taskkill /im Code.exe >> "%LOG%" 2>&1' \
        "ping -n $(( CLOSE_GRACE_SECONDS + 1 )) 127.0.0.1 >nul" \
        'taskkill /f /im Code.exe >> "%LOG%" 2>&1' \
        ''
    # STEP 1b — the gateway is stopped and waited for BEFORE the VM goes down (v16).
    render_quiesce_step
    printf '%s\r\n' \
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
        ''
    # STEP 3a — the gateway is STARTED again once the distro answers (v17).
    render_gateway_start_step
    # The compression step prints itself (render_compaction_step): inlining it pushed this
    # function past the §18.3 10.4 hundred-line bound, and the STEP LIST is what a reader
    # comes here for.
    render_compaction_step
    render_relaunch_step "$_folder"
    printf '%s\r\n' \
        'ping -n 11 127.0.0.1 >nul' \
        'tasklist /fi "IMAGENAME eq Code.exe" >> "%LOG%" 2>&1' \
        'goto final' \
        ':operator_cancel' \
        'echo [%DATE% %TIME%] the operator CANCELLED: distro and client untouched, a retry is armed >> "%LOG%"' \
        'goto finished' \
        ':final' \
        '' \
        'REM 5. One-shot: delete our own registration (the trigger has already fired,' \
        'REM    so a failure here cannot re-fire it; a skipped restart still spends it,' \
        'REM    and the gate line above says which happened). Scheduled: KEEP it, or the' \
        'REM    daily job would remove itself on its first run.  The cancel path SKIPS' \
        'REM    this delete: the gate has just re-armed the registration it would remove.' \
        "$_delete_line" \
        ':finished' \
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
    # The OPERATOR GATE's script travels WITH the wrapper: the wrapper calls it on every
    # fire, so a missing prompt would be a caller with no callee.  It is regenerated on
    # each arm, like the wrapper, so a threshold change lands on the next restart.
    if ! render_prompt > "$PROMPT_UNIX"; then
        _say "ERROR: cannot write the operator gate to $PROMPT_UNIX"
        return 1
    fi
    _say "wrote $PROMPT_UNIX (the wrapper calls it as $PROMPT_WIN)"
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
    # The operator gate's script is written beside the wrapper, so the same directory
    # has to exist for it - an unwritable prompt is a restart that cannot ask.
    if [[ ! -d "$(dirname "$PROMPT_UNIX")" ]]; then
        _say "ERROR: operator-gate directory does not exist: $(dirname "$PROMPT_UNIX")"
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
    # ADVISORY, not a gate: a missing compaction helper costs an OPPORTUNITY, never the
    # restart - step 3b logs whatever it says, and the relaunch happens regardless.
    if [[ ! -x "$COMPACT_CMD_UNIX" ]]; then
        _say "WARN: compaction helper not executable at $COMPACT_CMD_UNIX"
        _say "      step 3b will log a failure and the restart will proceed without it"
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
    local _folder="$1" _delay="$2" _st _sd _create_out
    if ! check_preconditions; then
        return 1
    fi
    warn_if_registered
    # v15: CLEAR a leftover registration before creating.  At the 03:04 failure a spent one was
    # present; `/create /f` should overwrite it, but a second registration state that /f cannot
    # replace is exactly what an unexplained create failure looks like, and this costs ~1 s.
    if task_state >/dev/null 2>&1; then
        if ! _win 30 "$SCHTASKS_BIN" /delete /f /tn "$TASK_NAME" >/dev/null 2>&1; then
            _say "WARN: a $TASK_NAME registration exists and could not be cleared; /f must overwrite it"
        fi
    fi
    if ! write_wrapper "$_folder" oneshot; then
        return 1
    fi

    # The trigger is a near-future MINUTE that actually fires: a spent one-time
    # trigger cannot re-fire, which is what makes this design safe even if the
    # self-delete never runs.  /sd is explicit because UK-locale Windows reads
    # DD/MM/YYYY and a crossing of midnight must land on tomorrow's date.
    _st=$(date -d "+${_delay} minutes" +%H:%M)
    _sd=$(date -d "+${_delay} minutes" +%d/%m/%Y)

    # v15: the tool's OWN message is printed on failure.  It used to go to /dev/null, so the
    # journal could only say "failed" - which is the expectation, not the cause.
    if ! _create_out=$(_win 60 "$SCHTASKS_BIN" /create /f /tn "$TASK_NAME" \
            /tr "$WRAPPER_WIN" /sc once /sd "$_sd" /st "$_st" 2>&1); then
        _say "ERROR: schtasks /create failed (bounded at 60 s) - task NOT armed"
        if [[ -n "$_create_out" ]]; then
            _say "  schtasks says: $(printf '%s\n' "$_create_out" | head -3 | tr '\n' ' ')"
        else
            _say "  schtasks printed nothing: it either timed out at the bound or was refused"
        fi
        return 1
    fi
    confirm_armed "$TASK_NAME fires at $_st on $_sd (Windows local time)" || return 1
    _say "the wrapper logs to $LOG_WIN; this session ends with the client."
    return 0
}

# Register a restart at a NAMED clock time.  `_recur` picks the form: `daily` is the
# recurring task whose wrapper keeps its own registration, `once` is the DEFAULT - a
# single fire whose wrapper deletes itseIf, so a bare time resumes a campaign without
# becoming a nightly habit (v11; see the Module Version note for the production miss
# this closes).
schedule_restart() {
    local _folder="$1" _time="$2" _recur="${3:-once}" _st _sd
    if [[ ! "$_time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        _say "ERROR: --schedule needs a 24h HH:MM time, got: $_time"
        return "$EXIT_USAGE"
    fi
    if ! check_preconditions; then
        return 1
    fi
    warn_if_registered
    if [[ "$_recur" == "daily" ]]; then
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
    fi
    # ONE-SHOT at a named clock time.  The date is TODAY when the time is still ahead,
    # otherwise TOMORROW, so a time that has already passed means the next occurrence
    # rather than a past trigger schtasks refuses.
    if [[ "$(date +%H:%M)" < "$_time" ]]; then
        _sd=$(date +%d/%m/%Y)
    else
        _sd=$(date -d '+1 day' +%d/%m/%Y)
    fi
    _st="$_time"
    if ! write_wrapper "$_folder" oneshot; then
        return 1
    fi
    if ! _win 60 "$SCHTASKS_BIN" /create /f /tn "$TASK_NAME" \
            /tr "$WRAPPER_WIN" /sc once /sd "$_sd" /st "$_st" >/dev/null 2>&1; then
        _say "ERROR: schtasks /create (once) failed (bounded at 60 s) - NOT armed"
        return 1
    fi
    confirm_armed "$TASK_NAME fires once at $_st on $_sd (Windows local time)" || return 1
    _say "the wrapper logs to $LOG_WIN; a boot resumes the campaign (autotune-resume)."
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
            # REGISTERED is not the same as ARMED.  A one-shot whose trigger has FIRED reads
            # `Next Run Time: N/A` and can never fire again - measured 2026-10-16, when the wrapper
            # failed to reach its self-delete and this branch called the spent token ARMED, which
            # stood a watcher down mid-task.  Report a triggerless registration as SPENT.
            if printf '%s\n' "$_state" | grep -qiE '^Next Run Time:[[:space:]]*(N/A|<None>)?[[:space:]]*$'; then
                _say "registered but SPENT - no trigger left, so no restart is pending:"
                _say "$_state"
                _verdict=0
            else
                _say "ARMED - a restart is pending:"
                _say "$_state"
                _verdict="$EXIT_STATUS_ARMED"
            fi
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
    local _recur="once"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --restart)    _mode="restart" ;;
            --status)     _mode="status" ;;
            --precheck)   _mode="precheck" ;;
            # Handled during parsing, like --version: the capture is a pure read of VS Code's
            # own window state and must not need the preconditions a restart does.
            --capture-windows) capture_windows; return 0 ;;
            --unschedule) _mode="unschedule" ;;
            --dry-run)    _mode="dry-run" ;;
            # A BARE HH:MM is one-shot (the default); `daily` and the explicit `once`
            # select the recurring and one-shot forms.  See the Module Version note.
            --schedule)   _mode="schedule"; shift; _want="${1:-}"; _recur="once"
                          if [[ "$_want" == "daily" ]]; then _recur="daily"; shift; _want="${1:-}"
                          elif [[ "$_want" == "once" ]]; then shift; _want="${1:-}"; fi
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
        schedule)   schedule_restart "$_folder" "$_time" "$_recur" ;;
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
