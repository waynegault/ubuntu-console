#!/usr/bin/env bash
# autotune-resume.sh - re-arm the autotune remainder after a WSL restart, and KEEP
# the campaign running until the rows are certified.
#
# WHY THIS EXISTS.  A restart ends everything in the distro.  Measured 2026-10-15:
# the running chunk is a child of the Qwen session's cli.js pair, which is itself a
# child of the VS Code window's extension host - so it dies with the CLIENT, never
# mind `wsl --shutdown`.  This is the re-arm, shipped as a systemd USER unit so that
# it is not a child of any window: systemd/autotune-resume.service.
#
# THE LOOP (v2, Wayne 2026-10-15).  v1 SURVIVED a restart but never caused one: it
# `exec`d the chunk, so the script died with it, and nothing re-derived the plan or
# armed a second restart.  Measured that night: a peer's ONE-SHOT restart fired at
# 07:30, the unit claimed its 13-row plan, the chunk ran to the cycle-budget halt at
# 08:41, and the campaign then STOPPED with 11 rows left - because the only product
# of a halt was a printed suggestion.  Now the chunk runs as a CHILD, its exit code
# is read, and a BUDGET halt that made progress re-derives the plan and arms the next
# restart, so the remainder is worked through unattended.
#
# THE PLAN IS THE GATE.  The scope is an owner decision (2026-10-13: the uncertified
# rows plus the flagged family, by MODEL FILE NAME), so `--plan` writes it to a plan
# file where it can be READ before it is trusted, rather than being re-derived
# silently at every boot.  With no plan this exits 0 and says so: a boot does
# nothing, loudly.
#
# THE PLAN IS CLAIMED ONCE, AND THE CLAIM IS THE RESUME MARKER.  Before the run the plan
# is copied to the log home and moved aside (not deleted), so a boot loop cannot re-tune
# rows it already has.  The claim is RETIRED (`<claim>.retired`) the moment the chunk's
# exit code has been read and acted on, so a claim still UNRETIRED means this boot never
# heard how its chunk ended - a restart in the middle, not a campaign that finished.
# Measured 2026-10-15 14:34:58 BST: the chunk was killed by a teardown SIGTERM, the plan
# had already been claimed and moved aside, and the next boot read "no plan ... nothing to
# resume" with 8 rows left UNMEASURED - the campaign died without saying so.  v3 closes
# that: a boot that finds an unretired claim re-derives the remainder and resumes it, and
# prints the claim it recovered from.
#
# FOUR STOPS KEEP THAT FROM BEING A REBOOT LOOP.  A boot that did not SHRINK the
# remainder; a remainder that is empty; a CI job executing on THIS box (a restart
# cancels it, and a cancelled run leaves main red here); and a cap on consecutive
# automatic restarts.  Each is a line in continue_after(), not an accident.
#
# THE ENTRY POINT IS bin/autotune-rows.sh, never scripts/run-autotune-batch.sh: only
# the wrapper takes the box lock (bin/heavy-job) and holds the CUDA lane down for the
# whole run.  This script inherits that serialisation rather than adding a second one.
#
# USAGE
#   autotune-resume.sh --plan      derive the remainder and write the plan
#   autotune-resume.sh             execute the plan, then continue the campaign
#   autotune-resume.sh --status    the plan, the ledger, the chunk, and the loop
#   autotune-resume.sh --ensure-armed  re-arm a restart whose fire never rebooted us
#   autotune-resume.sh --help | --version
#
# EXIT CODES
#   exit 0 = nothing to do, the campaign finished, or it continues (a restart armed)
#   exit 1 = a plan exists but nothing in it is runnable, or the entry point is missing
#   exit 2 = a bad argument
#   exit 3 = the chunk stopped for the ADAPTER with the budget unspent (propagated)
#   exit 4 = the campaign PAUSED: it will not resume by itself (the auto-restart cap, a CI job
#            that will not drain, or a plan that cannot be written).  v7: a spent cycle budget is
#            NO LONGER a pause on its own - the loop keeps going while rows are owed.
#
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 17
#   v17 (2026-10-18): AN EXHAUSTED CI WAIT ARMS A BOUNDED RETRY INSTEAD OF STOPPING.
#   Wayne's ruling, option (b).  Measured the same evening: the chunk ended 20:19:24, the arm
#   waited its 900 s and at 20:34:26 PAUSED because a CI job was executing - while the run
#   that mattered had ended at 20:34:15, nine seconds before the deadline, and a second run
#   held the queue to 20:45:35.  A PAUSE is a dead end (the unit is oneshot and nothing
#   re-enters it), so the box sat idle until a hand re-arm at 21:38.  Both exhaustion sites -
#   the arm and the pre-claim chunk gate - now call schedule_retry, which arms a transient
#   systemd timer that starts this unit again after RETRY_DELAY_S, bounded by RETRY_MAX so a
#   permanently busy queue ends in a named stop.  The budget resets when a chunk starts.
#   v15 (2026-10-18): THE WARNING STOPPED BEING PART OF THE COUNT.  Measured after the 14:17
#   restart: the unit's PATH is the systemd default (no `~/.local/bin`), so `gh` is not found,
#   the queued probe fails, and `ci_workers` printed "WARN …\n0" — the caller's numeric test then
#   failed on EVERY poll and `wait_for_ci_clear` slept for 55 minutes with a clear queue, holding
#   the whole campaign.  The count is now the only thing on stdout, and the warning is printed by
#   `wait_for_ci_clear` once, where its stdout is not captured.  Also: `gh` genuinely is not on
#   that PATH, so the queued half is inert INSIDE the unit until the unit's PATH or the probe's
#   own resolution is fixed — the local-worker half still gates, which is the safe fallback v13
#   promised.
#   v14 (2026-10-18): two defects in v13's own queued probe, both found by running it.
#   (1) `gh run list` prints `[]` when nothing is queued, so `grep -o databaseId` exits 1 — and
#   under `pipefail` that turned a CLEAR answer into a reported failure ("probe unavailable")
#   while the count it printed was 0.  The count is now guarded on the key being present, so
#   "none queued" is a successful zero.  (2) The failure reason was assigned inside
#   `$(ci_queued_runs)` — a SUBSHELL — so it never reached the caller and the WARN read
#   "(no detail)"; the probe now PRINTS the reason and the caller captures it.  Neither defect
#   could make the gate unsafe (the local count still gated), but both made it lie about why.
#   v13 (2026-10-18): THE CI GATE SEES A RUN THAT IS QUEUED, AND REQUIRES THE BOX TO STAY CLEAR.
#   Measured the same day: the gate read 0 CI jobs at 12:03:37 and a job started at 12:03:38, one
#   second later, so the chunk claimed a contended box and measured two rows at 0.9 cycles/min
#   instead of 3.05.  Two changes, option A of Wayne's ruling: (1) `ci_queued_runs` asks GitHub
#   for QUEUED + IN PROGRESS runs, so a push is visible within seconds rather than only when the
#   runner picks the job up; it degrades to the local count and SAYS SO once per boot when the
#   probe cannot answer, because "unknown" must not read as busy or a network-less box would never
#   claim a plan; (2) `wait_for_ci_clear` needs CI_SETTLE_POLLS (2) CONSECUTIVE zeros — a single
#   zero is a sample, and the gap between two jobs is exactly what it looked like.  Both counts
#   have their own seams (`TAC_RESUME_CI_QUEUED_CMD`, `TAC_RESUME_CI_LOCAL_CMD`) so a test pins
#   them rather than letting a foreign Runner.Worker decide the answer.
#   v12 (2026-10-18): THE CAP NO LONGER PARKS A CAMPAIGN THAT STILL OWES ROWS.  Wayne's ruling,
#   option b: the 8-restart cap bounds restarts WITHIN a campaign; it is not a reason to leave
#   work and a GPU idle.  Measured the same night — the loop stopped at 06:16:29 with 2 rows owed
#   and 8/8 used, and the box sat idle for 4 h 41 m because that stop existed only in the journal.
#   At the cap with rows owed, arm_restart now RESETS THE COUNTER FILE (via reset_restart_count,
#   the same path `--plan` uses — never a re-plan, which would re-derive the scope from the
#   registry) and arms, logging the figure it replaced so a runaway arm loop stays visible.
#   v11 (2026-10-17): the ARM's refusal NAMES its bound ("arm bound 900s").  The proof that the
#   arm and the chunk consult different bounds could not distinguish them while both refusals
#   read identically; with the value in the message, a live run (chunk bound 0, arm bound 5, CI
#   busy only at the arm) printed "arm bound 5s" and settled which constant is used.  No
#   behaviour change — this is the probe's own hook made permanent.
#   v10 (2026-10-17): A SIGNAL MUST NOT LOSE THE ARM SILENTLY, AND THE ARM GETS ITS OWN BOUND.
#   Measured the same day: the unit was SIGTERMed (`code=killed, status=15/TERM`) at 14:07:50,
#   seventeen minutes into `arm_restart`'s CI wait, and the campaign then sat IDLE for three
#   hours — the plan was intact, nothing was armed, and nothing re-armed it.  Two changes.
#   (a) `ARM_CI_WAIT_S` (900 s) bounds the ARM's CI wait separately from the CHUNK's
#   `CI_WAIT_S` (18000 s, raised in v9 because a chunk gate must outlast a CI RUN): the arm is
#   the last step of a oneshot in the boot transaction, so a five-hour sleep there is exposure,
#   not patience — it now lands promptly or declines loudly.  (b) `run_plan` installs TERM/INT
#   traps that name the signal, state that the plan is left in place and NO restart was armed,
#   and print the exact `--restart --delay` command to re-arm by hand; the next boot resumes
#   either way.  The trap cannot identify the SENDER, so the next occurrence still needs a look —
#   it will no longer be a bare `status=15/TERM` found three hours later.
#   v9 (2026-10-17): THE CI-DRAIN BOUND MUST OUTLAST A CI RUN.  Wayne's ruling the same day, choosing
#   (a): raise the bound rather than add a watcher.  `CI_WAIT_S` was 900 s, so a single
#   `systemctl start` could never outlive a drain - the unit paused on the wait's expiry (measured
#   01:07 BST: a CI run outlasted it and the loop paused with the plan intact), which is what made
#   "resume when the runner drains" a manual step needing a hand-written watcher.  It is now
#   18000 s (5 h): it outlasts a CI run and still sits under the unit's `TimeoutStartSec=21600`,
#   so systemd cannot kill the wait.  A versioned watcher was considered and REJECTED for now
#   (he keeps it in reserve, verbatim: "if drains routinely outlast a 5-hour bound, a timer is the
#   tracked artifact I'd want, not a script") - a watcher is NOT self-starting, so closing the gap
#   with one would have needed a systemd timer to launch it, which is more machinery than the bound.
#   v8 (2026-10-17): THE MEASUREMENT OPENS THE CI GATE ITSELF.  `wait_for_ci_clear` guarded only
#   `arm_restart`, so the chunk ran regardless of a CI job and the rows it measured were taken under
#   load - the outcome Wayne's rule forbids ("do not re-arm any measurement while a CI worker is
#   alive"), and the reason a re-certification needs a quiet box.  Measured 2026-10-17: a resumed
#   chunk was measuring while `/home/wayne/actions-runner-console/bin/Runner.Worker spawnclient` was
#   live, AND `--status` reported `CI jobs on this box: 1` in the same minute - the gate's own probe
#   already knew, and only the ARMING path consulted it.  The chunk now waits on the same bounded
#   helper (same `CI_WAIT_S`, same seam) before CLAIMING the plan, and an exhausted wait PAUSES
#   (exit 4) with the plan left in place, so a later boot or start resumes it unchanged.
#   v7 (2026-10-16): THE LOOP KEEPS GOING WHILE ROWS ARE OWED - it no longer stalls on a boot that
#   did not shrink the remainder, and a stop no longer CONSUMES the plan.  Wayne, verbatim: "i want
#   autotune to be much smoother than this!"  Two defects, both measured.  (a) `continue_after`
#   advanced only on the exit-4 budget halt AND only when the re-derived remainder SHRANK - which
#   contradicted his own ruling that the INDICATIVE rows stay in the SCOPE and are RETRIED: a boot
#   that retried them and certified nothing shrank nothing, so the loop PAUSED (measured 18:45: a
#   full 64-cycle boot, then ActiveState=failed with nothing armed, plan none, 11 rows still owed).
#   The stop is now the EMPTY remainder; the remaining guards are the 8-restart cap and
#   arm_restart's bounded wait for a CI job to drain, both of which still bound the retries.  (b) The
#   non-continuing paths returned BEFORE `write_plan`, so a pause left `plan: none` - a later boot
#   then read "nothing to resume" and the campaign could not restart without a HAND re-plan.  Every
#   stop now writes the remainder back first.  The ADAPTER stall (exit 3) is still a stop - the
#   budget was not the reason, so a person looks - but it too leaves a resumable plan.
#   v6 (2026-10-16): a durable SCOPE, and a certified NEW QUANT stops being pinned.  Two measured
#   defects, one fix each.  (a) A hand-written plan lasted exactly ONE boot: every registry row reads
#   `autotuned=yes`, so `derive_rows` selects nothing and `continue_after` -> `write_plan` re-derived
#   the plan down to the two ruled NEW QUANTs, dropping the EMPTY `meas_state` rows one boot after they
#   were added by hand (measured 2026-10-16: the 09:08 and 10:31 boots each claimed a 15-row hand-written
#   plan; the 09:42 and 11:52 boots claimed 2).  `SCOPE` (autotune-resume.scope.rows) is an owner-written
#   list that `plan_rows()` unions into the remainder and that survives every re-derivation - a row the
#   registry now reports as `certified` drops out of it, so the plan still SHRINKS and the loop still arms.
#   (b) The NEW_QUANTS branch pinned `law-chat-Q2_K` and `Spark-X2.5-4B` into EVERY derivation by name, so
#   each boot re-measured two rows that were already certified (~40 of a boot's 60 cycles); the branch now
#   also requires the row's `meas_state` (field 44) to be other than `certified`.  VERSION 4.0.0 -> 4.1.0.
#   v5 (2026-10-15): CHUNK_PATTERN is overridable (TAC_RESUME_CHUNK_PATTERN).  The full unit
#   run caught the defect this closes: `pgrep -f` matches any process whose argv CONTAINS the
#   pattern, so a foreign waiter carrying the word `run-autotune-batch` made --status report a
#   live chunk and turned three cases' expectations into someone else's state.  The suite now
#   pins what counts as a chunk, so no foreign process can decide a case.
#   v4 (2026-10-15): a claim is "cut off" only when NO chunk is running.  Measured 23:37 on the
#   boot that certified law-chat: --status printed "UNREPORTED previous run ... its chunk was
#   cut off" on the SAME screen as "a chunk IS live", because a claim stays unretired for the
#   whole duration of its run.  Both the recovery and the report now consult the process table,
#   so a second run can no longer start beside a live one either.
#   v3 (2026-10-15): an UNRETIRED claim now RESUMES the campaign.  A restart that killed the
#   chunk (measured 14:34:58 BST, 8 rows left) used to leave no plan and no recovery, so the
#   next boot read "nothing to resume" and the campaign died without saying so.  The claim is
#   retired as soon as the entry point's exit code has been read, and a boot that finds one
#   still unretired re-derives the remainder and continues; --status surfaces it.
#   v2 (2026-10-15): the chunk runs as a CHILD so its exit code can be read; a budget halt
#   that shrank the remainder re-derives the plan and arms the restart (four stops, cap 8).
VERSION="4.2.0"

set -uo pipefail

EXIT_FAILED=1  # a plan exists but cannot be run, or its entry point is missing
EXIT_USAGE=2   # the caller asked for something this script cannot do
EXIT_ADAPTER=3 # the chunk stalled with the cycle budget UNSPENT: a person looks
# v7: EXIT_BUDGET is GONE.  The loop no longer branches on the chunk's exit 4 (the spent cycle
# budget) - it continues while rows are owed - so the constant had no reader and shellcheck said
# so (SC2034).  The VALUE still matters: it is what the chunk returns, and the Module Version note
# above records it.  EXIT_PAUSED keeps that value for the paths that genuinely stop.
EXIT_PAUSED=4  # the campaign PAUSED: the cap, a CI job that will not drain, or an unwritable plan

REPO="${REPO:-/home/wayne/ubuntu-console}"
REGISTRY="${TAC_RESUME_REGISTRY:-$HOME/.llm/models.conf}"
MODEL_DIR="${TAC_RESUME_MODEL_DIR:-${LLAMA_MODEL_DIR:-/mnt/m/active}}"
STATE_DIR="${TAC_RESUME_STATE_DIR:-${TAC_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/tactical-console}}"
LOGDIR="${TAC_RESUME_LOGDIR:-$HOME/.llm/autotune-logs}"
ENTRY="${TAC_RESUME_ENTRY:-$REPO/bin/autotune-rows.sh}"
PLAN="${TAC_RESUME_PLAN:-$STATE_DIR/autotune-resume.rows}"
# The owner-written SCOPE, if present (v6): rows that must be measured every boot REGARDLESS of what
# the derivation says, because the derivation answers "what is the REGISTRY owed?" and - with every
# registry row reading `autotuned=yes` - answers it with nothing.  One model file name per line, in
# the order it should be measured; PARKED_ROWS still wins, and a row the registry now reports as
# `certified` is dropped so the plan keeps shrinking.  This is what carries a hand-written plan past
# the first boot.
SCOPE="${TAC_RESUME_SCOPE:-$STATE_DIR/autotune-resume.scope.rows}"
RESTART_TOOL="${TAC_RESUME_RESTART_TOOL:-$REPO/bin/wsl-restart.sh}"

# The loop's knobs, all overridable so a test drives them without touching Windows.
ARM_MAX="${TAC_RESUME_ARM_MAX:-8}"             # consecutive automatic restarts allowed
ARM_DELAY_MIN="${TAC_RESUME_ARM_DELAY:-3}"     # minutes after the halt to restart
# The bound must outlast a CI RUN, not a CI poll.  A single `systemctl start` can never outlive
# a drain if the wait expires first - and it did: measured 2026-10-17, a CI run outlasted the old
# 900 s, the loop PAUSED on the wait's expiry, and "resume when the runner drains" became a manual
# step.  It must also sit UNDER the unit's TimeoutStartSec (21600) or systemd kills the wait.
CI_WAIT_S="${TAC_RESUME_CI_WAIT_S:-18000}"      # 5 h: outlasts a CI run, under TimeoutStartSec 21600
CI_POLL_S="${TAC_RESUME_CI_POLL_S:-30}"
# How many CONSECUTIVE zero readings mean "clear".  One is a sample, not a clearance: it can
# be the gap between two jobs, which is what let a chunk claim the plan one second before a
# CI job started (measured 2026-10-18, 12:03:37 vs 12:03:38).  Two spans one poll of quiet.
CI_SETTLE_POLLS="${TAC_RESUME_CI_SETTLE_POLLS:-2}"
# The ARM's wait is a DIFFERENT question from the chunk's, and conflating them cost three idle
# hours on 2026-10-17.  The chunk needs a bound longer than a CI run (5 h); the arm is the LAST
# step of a oneshot that sits in the boot transaction, and it was SIGTERMed at 14:07:50 —
# seventeen minutes into a CI wait that could legally last five HOURS — after which nothing was
# armed and nothing re-armed it.  A short bound makes the arm either land promptly or decline
# loudly, so a signal has a narrow window instead of a whole afternoon.
ARM_CI_WAIT_S="${TAC_RESUME_ARM_CI_WAIT_S:-900}"   # 15 min: arm promptly, or say so
RESTARTS_FILE="$STATE_DIR/autotune-resume.auto-restarts"
# A PAUSE is otherwise a DEAD END: this unit is oneshot and nothing re-enters it, so an exhausted
# CI wait leaves the campaign idle until a boot or a hand start.  Measured 2026-10-18 20:34:26 —
# the arm's 900 s expired nine seconds after one CI run ended (20:34:15) while a second run held
# the queue to 20:45:35, and the box sat idle until a hand re-arm at 21:38.  Wayne's ruling,
# option (b): an exhausted wait ARMS A BOUNDED RETRY instead of stopping.
RETRY_DELAY_S="${TAC_RESUME_RETRY_DELAY_S:-900}"   # 15 min: a CI job's typical tail
RETRY_MAX="${TAC_RESUME_RETRY_MAX:-8}"             # consecutive retries, then a named stop
RETRIES_FILE="$STATE_DIR/autotune-resume.retries"
SELF_UNIT="${TAC_RESUME_SELF_UNIT:-autotune-resume.service}"
RETRY_UNIT="autotune-resume-retry"

# THE ARM RECORD (v4.2.0).  `--restart --delay N` is `schtasks /create` + `/run`: it returns 0
# when the task is REGISTERED, minutes before the wrapper makes its decision.  So the loop used
# to bump RESTARTS_FILE and exit believing a reboot was coming, while the wrapper could still
# SKIP the restart afterwards (the chunk gate, the fleet gate, a task the Task Scheduler
# dropped) - and nothing re-armed it, because the unit is boot-scoped and there was no boot.
# Measured cause: 2026-10-18, the fleet gate landed and could skip a fire; the counter then
# counted a restart that never happened and the campaign sat parked with rows owed, which is
# the stall Wayne ruled against on 06:16 and again on 10-17.
# This file records what the arm PROMISED: the fire time, the boot id it was armed from, and
# the rows owed.  The keeper timer reads it and re-arms only when that promise was broken.
ARMED_FILE="$STATE_DIR/autotune-resume.armed"
KEEPER_REARMS_FILE="$STATE_DIR/autotune-resume.keeper-rearms"
KEEPER_MAX_REARMS="${TAC_RESUME_KEEPER_MAX_REARMS:-4}"

# The scope Wayne ruled on 2026-10-13, by MODEL FILE NAME and never by row number (a
# row number is only a view of the registry, reassigned by every `model scan`): the
# uncertified rows, the flagged family (p2_tps above tps), and the two rows ruled NEW
# QUANTS.  Derived live from the registry, so it cannot go stale behind a hand list.
NEW_QUANTS='law-chat-Q2_K.gguf|Spark-X2.5-4B-Q4_K_M.gguf'

# PARKED rows - deliberately OUT of the plan (Wayne, 2026-10-15).  A row that cannot
# certify still spends a boot's remainder every time, and this one ends every boot at
# the same place.  Measured 2026-10-15: MemSFT entered the batch at cycle 43 and left
# the boot spent at 63 - 20 of the boot's 60 cycles - inside the filled-cache TPS
# floor descent, which re-spawns a server once per ctx step and never clears the
# floor.  So it stays flagged in the registry whatever it costs, and comes back in
# every derivation.  Parked is not deleted: the row and its columns are untouched.
PARKED_ROWS='MemSFT-Qwen3-Law-Memory-8B.Q2_K.gguf'

# The bracket class keeps a chunk probe from matching its OWN command line.  Overridable
# since v5: the pattern is a pgrep pattern, so ANY process whose argv merely CONTAINS one of
# these words reads as a live chunk - measured 2026-10-15 01:17, a harness waiter running
# `while pgrep -f 'run-autotune-batch'` made two cases take the "a chunk is already running"
# branch, i.e. a foreign process decided them.  The seam lets a suite PIN what counts as a
# chunk (the same override the restart wrapper carries as TAC_WSL_RESTART_CHUNK_PATTERN).
CHUNK_PATTERN="${TAC_RESUME_CHUNK_PATTERN:-autotune[-]rows|run-autotune[-]batch|autotune[-]model|bench[-]rows}"

# Print the usage block out of this file's own header, so the two cannot drift.
usage() {
    sed -n '/^# USAGE$/,/^#$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# Why a row is parked, printed WITH the row so the operator never has to look it up.
parked_reason() {
    case "$1" in
        MemSFT-Qwen3-Law-Memory-8B.Q2_K.gguf)
            printf '%s' \
                "never clears the filled-cache TPS floor, so the ctx descent re-spawns " \
                "a server until the boot's budget is gone (measured 2026-10-15: 20 of " \
                "the boot's 60 cycles), and it stays flagged, returning every time" ;;
        *) printf '%s' "parked by this script's PARKED_ROWS list" ;;
    esac
}

# Name every parked row, so a row missing from a plan is accounted for rather than
# merely absent.
report_parked() {
    local _p
    for _p in $PARKED_ROWS; do
        printf 'parked (out of the plan): %s\n' "$_p"
        printf '  because: %s\n' "$(parked_reason "$_p")"
    done
}

# The ruled scope rule, as a pure derivation: prints the rows, writes nothing, so a
# caller can compare the remainder before and after a run.
derive_rows() {
    awk -F'|' -v nq="$NEW_QUANTS" -v parked="$PARKED_ROWS" '
        $1 ~ /^[0-9]+$/ && NF > 1 {
            if (parked != "" && $3 ~ ("^(" parked ")$")) next
            t = $17 + 0; p = $25 + 0
            # A ruled NEW QUANT stays in BY NAME - but only while it is not certified (v6).  Pinning it
            # unconditionally re-measured law-chat-Q2_K and Spark-X2.5-4B on EVERY boot after both had
            # certified, about 40 of the 60-cycle boot budget (measured 2026-10-16).
            if ($18 != "yes" || (p > t && t > 0) || ($3 ~ ("^(" nq ")$") && $44 != "certified")) print $3
        }' "$REGISTRY" | sort -u
}

# The owner's SCOPE rows, in file order: PARKED still wins, and a row the registry now reports as
# `certified` drops out - that is what lets the plan SHRINK as rows land, so `continue_after` keeps
# arming.  A row measured but still `indicative` STAYS (it is owed a quiet-box re-measure).  With no
# scope file this prints nothing, so a box without one behaves exactly as it did before v6.
scope_rows() {
    [[ -r "$SCOPE" ]] || return 0
    awk -F'|' -v parked="$PARKED_ROWS" '
        NR == FNR { if ($1 ~ /^[0-9]+$/ && NF > 1 && $44 == "certified") done[$3] = 1; next }
        $0 == "" { next }
        parked != "" && $0 ~ ("^(" parked ")$") { next }
        done[$0] { next }
        { print $0 }
    ' "$REGISTRY" "$SCOPE" | awk '!seen[$0]++'
}

# What the loop should carry: the SCOPE first (the owner's explicit choice, so it is measured while the
# boot's budget lasts), then the derived remainder, de-duplicated.
plan_rows() {
    { scope_rows; derive_rows; } | awk '!seen[$0]++'
}

# Derive the remainder and write it as the plan, printing it so the scope that is
# about to run can be read in the same breath.
write_plan() {
    local _rows
    if [[ ! -r "$REGISTRY" ]]; then
        printf 'ERROR: registry not readable: %s\n' "$REGISTRY"
        return "$EXIT_FAILED"
    fi
    _rows=$(plan_rows)
    if [[ -z "$_rows" ]]; then
        printf 'nothing to plan: every row is certified and unflagged (%s)\n' "$REGISTRY"
        report_parked
        return 0
    fi
    mkdir -p "$(dirname "$PLAN")"
    printf '%s\n' "$_rows" > "$PLAN"
    printf 'wrote %s with %s row(s):\n' "$PLAN" "$(printf '%s\n' "$_rows" | wc -l)"
    printf '  %s\n' "$_rows"
    report_parked
    return 0
}

# A chunk executing on THIS box, as a yes/no.  The claim says "a run was owed"; the process
# table says "that run is still going" - and only the two TOGETHER mean "cut off".  A claim
# stays unretired for the WHOLE duration of its chunk, so without this test --status reported
# "UNREPORTED previous run ... its chunk was cut off" on the same screen as "a chunk IS live"
# (measured 2026-10-15 23:37), and a second boot-time run could have started beside the first.
chunk_is_live() {
    pgrep -f "$CHUNK_PATTERN" >/dev/null 2>&1
}

# The newest claim that was never RETIRED, or nothing.  A claim is written just before a
# chunk is handed the rows and retired once the entry point's exit code has been read, so a
# claim still unretired AND no chunk running means THIS boot never heard how its chunk ended
# - a restart in the middle (or a crash), never a campaign that finished.  Glob order is name
# order and every stamp is `date +%Y%m%d-%H%M%S`, so the last match is the newest.
latest_unretired_claim() {
    local _f _newest=""
    for _f in "$PLAN".claimed-*; do
        [[ -e "$_f" ]] || continue
        # A claim's own RETIREMENT MARKER matches the glob too, so it must be skipped by
        # NAME as well as by the sibling test below - otherwise the marker is mistaken for
        # an unretired claim and every reported-on run reads as cut off.
        [[ "$_f" == *.retired ]] && continue
        [[ -e "$_f.retired" ]] && continue
        _newest="$_f"
    done
    [[ -n "$_newest" ]] || return 1
    printf '%s\n' "$_newest"
}

# Mark a claim as REPORTED: the entry point's exit code has been read and acted on, so the
# next boot must not mistake this run for one that was cut off.  Retirement is what makes
# "unretired" mean "we never heard how it ended", which is the whole recovery signal.
retire_claim() {
    [[ -n "${1:-}" && -e "${1:-}" ]] || return 0
    : > "$1.retired"
}

# The boot-scoped CUDA cycle ledger, or a named absence on a fresh boot.  Reported,
# never a gate: the process table says whether a chunk is live.
ledger_value() {
    local _f _v="absent (fresh boot)"
    for _f in /dev/shm/autotune-cuda-cycles-*; do
        [[ -e "$_f" ]] || continue
        _v="$(< "$_f")"
    done
    printf '%s' "$_v"
}

# How many automatic restarts have been armed since the last `--plan`.
restart_count() {
    local _n=0
    if [[ -r "$RESTARTS_FILE" ]]; then
        _n=$(< "$RESTARTS_FILE")
    fi
    printf '%s' "${_n:-0}"
}

# `--plan` is the deliberate act that starts a campaign, so it clears the counter.
reset_restart_count() {
    mkdir -p "$STATE_DIR"
    printf '0\n' > "$RESTARTS_FILE"
}

# How many retries have been scheduled since the last successful claim.
retry_count() {
    local _n=0
    if [[ -r "$RETRIES_FILE" ]]; then
        _n=$(< "$RETRIES_FILE")
    fi
    printf '%s' "${_n:-0}"
}

# A successful claim clears the retry budget.
reset_retry_count() {
    mkdir -p "$STATE_DIR"
    printf '0\n' > "$RETRIES_FILE"
}

# Arm a transient systemd timer that starts this unit again after RETRY_DELAY_S, so an exhausted
# CI wait becomes a RETRY rather than a stop.  Bounded by RETRY_MAX: a permanently busy queue ends
# in a named stop instead of an endless wake-up loop.
schedule_retry() {
    local _n
    _n=$(retry_count)
    if (( _n >= RETRY_MAX )); then
        printf 'retry budget spent: %s/%s — a boot or a hand start is needed\n' "$_n" "$RETRY_MAX"
        return 1
    fi
    if [[ -n "${TAC_RESUME_RETRY_CMD:-}" ]]; then
        if ! "${TAC_RESUME_RETRY_CMD}" "$RETRY_DELAY_S" "$RETRY_UNIT" "$SELF_UNIT"; then
            printf 'retry NOT armed: %s failed\n' "$TAC_RESUME_RETRY_CMD"
            return 1
        fi
    else
        if systemctl --user is-active --quiet "${RETRY_UNIT}.timer"; then
            systemctl --user stop "${RETRY_UNIT}.timer" \
                || printf 'WARN: could not clear the previous retry timer\n'
        fi
        if ! systemd-run --user --on-active="${RETRY_DELAY_S}s" --unit="$RETRY_UNIT" --collect \
                systemctl --user start "$SELF_UNIT"; then
            printf 'retry NOT armed: systemd-run failed\n'
            return 1
        fi
    fi
    mkdir -p "$STATE_DIR"
    printf '%s\n' "$(( _n + 1 ))" > "$RETRIES_FILE"
    printf 'retry %s/%s armed: %s starts in %ss\n' \
        "$(( _n + 1 ))" "$RETRY_MAX" "$SELF_UNIT" "$RETRY_DELAY_S"
    return 0
}

# GitHub says a run is QUEUED or IN PROGRESS for this repo, as a count.  The local worker
# count is authoritative for "a job is EXECUTING", but it only becomes non-zero when the
# runner PICKS THE JOB UP — measured 2026-10-18: the gate read 0 at 12:03:37 and the job
# started at 12:03:38, one second later, so the chunk claimed a contended box.  A push is
# visible to `gh` within seconds, which is the warning the local probe cannot give.
# Returns non-zero when the probe cannot answer; the caller degrades to the local count.
ci_queued_runs() {
    local _slug _out
    if [[ -n "${TAC_RESUME_CI_QUEUED_CMD:-}" ]]; then
        "$TAC_RESUME_CI_QUEUED_CMD"
        return $?
    fi
    # swallow-ok: a PRESENCE probe — "no gh here" is the answer, and ci_workers names it in its WARN
    command -v gh >/dev/null 2>&1 || return 1
    _slug="${TAC_RESUME_CI_REPO:-}"
    if [[ -z "$_slug" ]]; then
        # Capture the reason rather than discarding it: a checkout with no remote is a real
        # case and its message is what the one-time WARN reports.
        local _remote
        if ! _remote=$(git -C "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" remote get-url origin 2>&1); then
            _ci_queued_err="no origin remote: $(printf '%s\n' "$_remote" | head -1)"
            return 1
        fi
        _slug=$(printf '%s\n' "$_remote" | sed -E 's#^.*github\.com[:/]##; s#\.git$##')
    fi
    if [[ -z "$_slug" ]]; then
        printf 'no GitHub repo slug could be resolved from this checkout\n'
        return 1
    fi
    # Merge stderr rather than discard it: the reason the probe failed is what the one-time
    # WARN reports, and a discarded diagnostic is the failure this repo has already paid for.
    _out=$(timeout 20 gh run list -R "$_slug" --status queued --status in_progress \
        --json databaseId --limit 20 2>&1)
    if [[ $? -ne 0 ]]; then
        printf '%s\n' "$(printf '%s\n' "$_out" | grep -m1 -E '.' || echo 'gh exited non-zero with no message')"
        return 1
    fi
    # `gh` prints `[]` when nothing is queued, and an empty array makes grep exit 1 — with
    # `pipefail` that turned a CLEAR answer into a reported failure (measured 2026-10-18: the
    # gate warned "probe unavailable" while `gh` had answered `[]` and rc 0).  Count only when
    # the key is present, so "none queued" is a successful zero rather than an error.
    case "$_out" in
        *databaseId*) printf '%s\n' "$_out" | grep -o 'databaseId' | wc -l ;;
        *) printf '0\n' ;;
    esac
}

# A CI job EXECUTING on this box, as a count, from the process table.  Its own seam because
# the count is host state: a test that cannot pin it is decided by whatever else this box is
# running (measured 2026-10-17, a foreign `[R]unner.Worker` chose the answer).
ci_local_workers() {
    local _n
    if [[ -n "${TAC_RESUME_CI_LOCAL_CMD:-}" ]]; then
        _n=$("$TAC_RESUME_CI_LOCAL_CMD") || _n=""
        printf '%s\n' "${_n:-0}"
        return 0
    fi
    # swallow-ok: `pgrep -c` exits 1 when nothing matches, and "nothing matches" IS
    # the clean answer this row reports
    _n=$(pgrep -cf '[R]unner.Worker') || _n=0
    printf '%s\n' "${_n:-0}"
}

# A CI job executing on THIS box, as a count.  A restart cancels it, and a cancelled
# run leaves main red here, so this is a gate rather than a note.
ci_workers() {
    local _n _q
    if [[ -n "${TAC_RESUME_CI_WORKERS_CMD:-}" ]]; then
        _n=$("$TAC_RESUME_CI_WORKERS_CMD") || _n=""
        printf '%s\n' "${_n:-0}"
        return 0
    fi
    _n=$(ci_local_workers)
    # The COUNT is the only thing on stdout.  A warning printed here becomes PART of the value
    # the caller compares, and the gate then never sees a numeric zero — measured 2026-10-18:
    # `gh` is not on the unit's PATH, so every poll returned "WARN…\n0" and the loop slept for
    # 55 minutes with a clear queue.  wait_for_ci_clear prints the warning instead, where its
    # stdout is not captured.
    if _q=$(ci_queued_runs) && [[ "$_q" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$(( ${_n:-0} + _q ))"
        return 0
    fi
    printf '%s\n' "${_n:-0}"
}

# Wait, bounded, for the CI job to finish.  Returns 1 on EXHAUSTION - it aborts
# rather than falling through to the restart it guards (a bounded wait whose only
# failure path is the action it guards is the shape that has bitten this repo).
wait_for_ci_clear() {
    local _bound="${1:-$CI_WAIT_S}" _n _deadline _clear=0 _why
    # Say it HERE, once, where stdout is not captured.  A warning printed inside $(ci_workers)
    # becomes part of the count and the gate never sees a numeric zero — measured 2026-10-18:
    # the unit's PATH has no `gh`, so every poll returned "WARN…\n0" and the loop slept for 55
    # minutes with a clear queue.  The count itself is always a bare number.
    if ! _why=$(ci_queued_runs); then
        printf 'WARN: the queued-run probe is unavailable (%s) — counting LOCAL workers only\n' \
            "${_why:-no detail}"
        printf '  a push whose job has not started yet is invisible to this gate\n'
    fi
    _deadline=$(( SECONDS + _bound ))
    while :; do
        _n=$(ci_workers)
        if [[ "$_n" =~ ^[0-9]+$ ]] && (( _n == 0 )); then
            _clear=$(( _clear + 1 ))
            # A single zero is a SAMPLE, not a clearance: it can be the gap between two jobs,
            # which is what let a chunk claim the plan one second before a CI job (measured
            # 2026-10-18, gate 12:03:37 / job 12:03:38).  Require CONSECUTIVE quiet polls.
            if (( _clear >= CI_SETTLE_POLLS )); then
                return 0
            fi
        else
            _clear=0
        fi
        if (( SECONDS >= _deadline )); then
            return 1
        fi
        sleep "$CI_POLL_S"
    done
}

# An epoch as a readable stamp.  GNU `date` is what is installed here, but a bare
# `date -d @N` that fails would print an empty field into a log line that the reader then
# has to interpret, so the raw epoch is the fallback and the failure is deliberately not
# an error: the caller is always a human-readable message, never a decision.
fmt_epoch() {
    # swallow-ok: cosmetic stamp; the raw epoch is the fallback, and no decision reads this
    date -d "@${1:-0}" '+%F %T' 2>/dev/null || printf '%s' "${1:-?}"
}

# The id of the boot we are in, as an epoch, from /proc/stat's `btime`.  It is the only
# cheap fact that tells "the arm fired and rebooted us" from "the arm was dropped in THIS
# boot" - a wall-clock comparison could not, because a skipped fire leaves the clock moving.
boot_epoch() {
    awk '/^btime /{print $2; found=1} END{if (!found) exit 1}' /proc/stat
}

# Record what the arm PROMISED: fire epoch, the boot it was armed from, rows owed at arm
# time.  Written only after the Task Scheduler accepted the registration, so it describes
# an arm that exists rather than one that was merely attempted.
record_arm() {
    local _fire _rows
    _fire=$(( $(date +%s) + ARM_DELAY_MIN * 60 ))
    _rows=$(plan_rows | awk 'END{print NR}')
    mkdir -p "$STATE_DIR"
    printf '%s %s %s\n' "$_fire" "$(boot_epoch || echo 0)" "${_rows:-0}" > "$ARMED_FILE"
}

# Drop an arm record written by an EARLIER boot: that restart fired and rebooted us, so
# the promise is spent.  A record from THIS boot is kept either way - a fire time already
# behind us in the same boot is the broken promise the keeper exists to act on.
clear_fired_marker() {
    local _fire _boot _rows _cur
    [[ -f "$ARMED_FILE" ]] || return 0
    if ! read -r _fire _boot _rows < "$ARMED_FILE"; then
        rm -f "$ARMED_FILE"
        return 0
    fi
    _cur=$(boot_epoch || echo 0)
    if [[ "${_boot:-0}" != "$_cur" ]]; then
        rm -f "$ARMED_FILE"
        printf 'keeper: the arm from boot %s fired - record cleared\n' "${_boot:-?}"
    fi
    return 0
}

# Arm the next restart through the TRACKED tool, and read its registration back.
# Nothing here touches Windows itself: bin/wsl-restart.sh owns that, including the
# chunk gate that refuses to cut a row in half.
arm_restart() {
    local _n _rc=0
    _n=$(restart_count)
    if (( _n >= ARM_MAX )); then
        # Wayne's ruling 2026-10-18 (option b): the cap bounds restarts WITHIN a campaign; it
        # does not park one that still owes rows.  Measured the same night — the loop stopped at
        # 06:16:29 with 2 rows owed and 8/8 used, and the GPU sat idle for 4 h 41 m because that
        # stop existed only in the journal.  The reset is the documented one: the COUNTER FILE,
        # never `--plan` (which re-derives the scope from the registry).  It is logged with the
        # figure it replaced, so a runaway arm loop stays visible rather than silent.
        printf 'cap reached: %s/%s automatic restarts - RESETTING the counter and continuing\n' \
            "$_n" "$ARM_MAX"
        printf '  (Wayne, 2026-10-18: a cap must not park a campaign that still owes rows)\n'
        reset_restart_count
        _n=0
    fi
    if ! wait_for_ci_clear "$ARM_CI_WAIT_S"; then
        printf 'NOT arming a restart: a CI job is executing on this box (arm bound %ss)\n' "$ARM_CI_WAIT_S"
        printf '  a restart cancels it, and a cancelled run leaves main red here\n'
        printf '  re-arm by hand when the queue is empty: %s --restart --delay %s\n' \
            "$RESTART_TOOL" "$ARM_DELAY_MIN"
        # v16: a PAUSE used to be a dead end (nothing re-enters a oneshot).  Schedule the retry.
        schedule_retry
        return "$EXIT_PAUSED"
    fi
    if [[ ! -x "$RESTART_TOOL" ]]; then
        printf 'ERROR: the restart tool is not executable: %s\n' "$RESTART_TOOL"
        return "$EXIT_PAUSED"
    fi
    "$RESTART_TOOL" --restart --delay "$ARM_DELAY_MIN" || _rc=$?
    if (( _rc != 0 )); then
        printf 'ERROR: %s exited %s - NOT armed\n' "$RESTART_TOOL" "$_rc"
        return "$EXIT_PAUSED"
    fi
    mkdir -p "$STATE_DIR"
    printf '%s\n' "$(( _n + 1 ))" > "$RESTARTS_FILE"
    record_arm
    printf 'armed restart %s/%s: the next boot resumes the remainder at %s\n' \
        "$(( _n + 1 ))" "$ARM_MAX" "$(date -Iseconds)"
    return 0
}

# --ensure-armed: the keeper timer's ONE job - re-arm a promise that was broken.
#
# It deliberately cannot start a campaign.  It acts only when an arm was RECORDED and its
# fire time passed in the same boot with no task registered: that is the signature of a
# fire the wrapper skipped (the chunk gate, the fleet gate) or a registration the Task
# Scheduler dropped.  A campaign that is running normally has no record, because a boot
# clears it; a campaign a person stopped has no record either, so the keeper stays out of
# the way.  That narrowness is the point - a supervisor that can start work on its own
# guess is a second campaign engine, and this box already has one.
ensure_armed() {
    local _fire _boot _rows _now _rc=0 _n=0 _owed=0
    clear_fired_marker
    if [[ ! -f "$ARMED_FILE" ]]; then
        printf 'keeper: no arm outstanding - nothing to do\n'
        return 0
    fi
    if ! read -r _fire _boot _rows < "$ARMED_FILE"; then
        printf 'keeper: the arm record is unreadable - discarding it (it proves nothing)\n'
        rm -f "$ARMED_FILE"
        return 0
    fi
    _now=$(date +%s)
    if (( _fire > _now )); then
        printf 'keeper: the restart is still due (%s) - nothing to do\n' \
            "$(fmt_epoch "$_fire")"
        return 0
    fi
    # Past its fire time in the same boot.  Registered still means the wrapper has not run
    # yet (an operator prompt waiting, a slow chunk gate): overdue is not broken.
    "$RESTART_TOOL" --status >/dev/null 2>&1 || _rc=$?
    case "$_rc" in
        0) : ;;  # nothing armed: the promise WAS broken, fall through
        1) printf 'keeper: the restart is armed and overdue - the wrapper has not fired yet, nothing to do\n'
           return 0 ;;
        *) printf 'keeper: the Task Scheduler could not be read (status %s) - not re-arming blind\n' "$_rc"
           return "$EXIT_PAUSED" ;;
    esac
    # Nothing armed.  Was the work actually still owed, and is anything already happening?
    _owed=$(plan_rows | awk 'END{print NR}')
    if (( ${_owed:-0} == 0 )); then
        printf 'keeper: no rows owed (the arm was for %s) - the campaign is done, record cleared\n' "${_rows:-?}"
        rm -f "$ARMED_FILE"
        return 0
    fi
    if chunk_is_live; then
        printf 'keeper: a chunk IS running with %s row(s) owed - the campaign is already moving,\n' "$_owed"
        printf '  so the dropped restart costs nothing yet; not arming over a live chunk\n'
        return 0
    fi
    # Absent on the first re-arm of a boot, and absent means zero - the counter is only
    # ever written by this function.
    # swallow-ok: an absent counter IS zero; only this function ever writes it
    _n=$(cat "$KEEPER_REARMS_FILE" 2>/dev/null || echo 0)
    [[ "$_n" =~ ^[0-9]+$ ]] || _n=0
    if (( _n >= KEEPER_MAX_REARMS )); then
        printf 'keeper: the restart was dropped %s time(s) in this boot (cap %s) and %s row(s) are owed\n' \
            "$_n" "$KEEPER_MAX_REARMS" "$_owed"
        printf '  NOT re-arming again - a person decides. Re-arm by hand:\n'
        printf '    %s --restart --delay %s\n' "$RESTART_TOOL" "$ARM_DELAY_MIN"
        return "$EXIT_PAUSED"
    fi
    mkdir -p "$STATE_DIR"
    printf '%s\n' "$(( _n + 1 ))" > "$KEEPER_REARMS_FILE"
    printf 'keeper: the restart armed at %s never fired in this boot, %s row(s) are owed - RE-ARMING (%s/%s)\n' \
        "$(fmt_epoch "$_fire")" "$_owed" \
        "$(( _n + 1 ))" "$KEEPER_MAX_REARMS"
    if ! arm_restart; then
        printf 'keeper: the re-arm FAILED - the campaign needs a person now\n'
        return "$EXIT_PAUSED"
    fi
    return 0
}

# THE LOOP.  Read the chunk's exit code and decide whether the campaign carries on.
# ONLY the budget halt is resumable, and only when this boot SHRANK the remainder -
# a restart that would re-run the same rows buys nothing but a reboot.
continue_after() {
    local _rc="$1" _before="$2" _after=0
    if (( _rc == EXIT_ADAPTER )); then
        printf 'not continuing: the chunk stopped for the ADAPTER with the budget UNSPENT\n'
        printf '  the ledger is not the explanation, so a restart would not help - a person looks\n'
        # ...but the remainder is still OWED, so it is written back: a stop must never consume the
        # plan, or the campaign cannot resume without a hand re-plan (v7).
        write_plan || return "$EXIT_PAUSED"
        return "$EXIT_ADAPTER"
    fi
    # v7: KEEP GOING while rows are owed.  This used to advance only on the exit-4 budget halt, and
    # only when the remainder SHRANK - which contradicted Wayne's own ruling that the INDICATIVE rows
    # stay in the SCOPE and are RETRIED (2026-10-16): a boot that retried them and certified nothing
    # shrank nothing, so the loop PAUSED and the campaign stalled after ONE boot (measured 18:45 - a
    # full 64-cycle boot, then ActiveState=failed, nothing armed, plan none, 11 rows still owed).
    # Wayne, 2026-10-16: "i want autotune to be much smoother than this!"  The stop is now the EMPTY
    # remainder; the guards that bound the retries are the 8-restart cap and arm_restart's bounded
    # wait for a CI job to drain, and an adapter stall (handled above) still stops for a person.
    _after=$(plan_rows | awk 'END { print NR }')
    if (( _after == 0 )); then
        printf 'the remainder is EMPTY - the campaign is complete; no restart armed\n'
        return 0
    fi
    printf 'still owed: %s row(s) (this boot was handed %s and exited %s): re-planning and arming\n' \
        "$_after" "$_before" "$_rc"
    write_plan || return "$EXIT_PAUSED"
    arm_restart
}

# A signal here used to be a SILENT loss.  Measured 2026-10-17: the unit was SIGTERMed
# (`code=killed, status=15/TERM`) at 14:07:50 inside the arm's CI wait, the journal carried only
# "Failed with result 'signal'", and the campaign then sat IDLE for three hours — the plan was
# intact, but nothing was armed and nothing re-armed it.  Naming the signal, saying the plan
# survives, and printing the re-arm command is what turns the next occurrence into one line.
_on_signal() {
    printf '\n=== signal %s at %s — plan left in place; NO restart armed\n' "$1" "$(date '+%F %T %Z')"
    printf '=== the next boot resumes it. To re-arm now:\n'
    printf '===   %s --restart --delay %s\n' "$RESTART_TOOL" "$ARM_DELAY_MIN"
    exit "$EXIT_PAUSED"
}

# Run the plan: drop a row whose model file is gone (an unloadable row still burns
# CUDA cycles walking ctx - see the load-failure note), claim the plan, hand over.
run_plan() {
    trap '_on_signal TERM' TERM
    trap '_on_signal INT' INT
    # This boot IS the restart an arm record was waiting for (or it is a fresh boot with
    # a stale record): clear it before anything else, so the keeper never re-arms on it.
    clear_fired_marker
    local _row _kept=() _missing=0 _rc=0 _recover=""
    if [[ ! -f "$PLAN" ]]; then
        # No plan, but a claim that was never retired means the last chunk was CUT OFF
        # rather than finished: its exit code was never read, so nothing re-derived the
        # remainder or armed a restart.  Re-derive from the registry and carry on.  The
        # never-armed case (no plan AND no unretired claim) still does nothing, loudly.
        if _recover="$(latest_unretired_claim)"; then
            if chunk_is_live; then
                # The claim is unretired simply because its chunk is STILL RUNNING.  Starting
                # a second run beside it would double the CUDA cycle spend and fight it for
                # the card, so this is a stop, not a recovery.
                printf 'a chunk is already running and holds the claim: %s\n' "$_recover"
                printf '  its claim is retired when its exit code is read - nothing to recover\n'
                return 0
            fi
            printf 'no plan at %s, but the previous run was never reported on: %s\n' \
                "$PLAN" "$_recover"
            printf '  a restart cut its chunk off, so this boot re-derives the remainder\n'
            write_plan || return "$EXIT_PAUSED"
            retire_claim "$_recover"
            if [[ ! -f "$PLAN" ]]; then
                printf 'the remainder is EMPTY - the campaign is complete\n'
                return 0
            fi
        else
            printf 'no plan at %s - nothing to resume (write one with --plan)\n' "$PLAN"
            return 0
        fi
    fi
    if [[ ! -x "$ENTRY" ]]; then
        printf 'ERROR: entry point not executable: %s\n' "$ENTRY"
        return "$EXIT_FAILED"
    fi
    while IFS= read -r _row; do
        [[ -n "$_row" ]] || continue
        if [[ -f "$MODEL_DIR/$_row" ]]; then
            _kept+=("$_row")
        else
            printf 'dropping %s: no such model file under %s\n' "$_row" "$MODEL_DIR"
            _missing=$(( _missing + 1 ))
        fi
    done < "$PLAN"

    if [[ "${#_kept[@]}" -eq 0 ]]; then
        # Nothing runnable is a decision for a person: the plan is KEPT so it can be
        # fixed, and the missing count is named rather than implied.
        printf 'ERROR: nothing runnable in %s (%s row(s) dropped, model dir %s)\n' \
            "$PLAN" "$_missing" "$MODEL_DIR"
        return "$EXIT_FAILED"
    fi

    # v8: the MEASUREMENT opens the CI gate itself.  `wait_for_ci_clear` used to guard only
    # `arm_restart`, so the chunk ran regardless and a CI job executing on this box contaminated
    # the rows it measured - the outcome Wayne's rule forbids ("do not re-arm any measurement
    # while a CI worker is alive"), and the reason a re-certification needs a quiet box.  The wait
    # is the SAME helper with the SAME bound, and an exhausted wait PAUSES - and it pauses BEFORE
    # the claim below, so the plan stays in place and a later boot or start resumes it unchanged.
    if ! wait_for_ci_clear; then
        printf 'a CI job is executing on this box - PAUSING rather than measuring under load\n'
        printf '  waited %ss; nothing was claimed, and %s is left in place for a later run\n' \
            "$CI_WAIT_S" "$PLAN"
        # v16: a PAUSE used to be a dead end (nothing re-enters a oneshot).  Schedule the retry.
        schedule_retry
        return "$EXIT_PAUSED"
    fi
    # The gate cleared and a chunk is about to run: this attempt SUCCEEDED, so the retry budget
    # starts over.  Without this a long campaign would spend its budget one CI delay at a time.
    reset_retry_count

    # Claim it BEFORE the run: a boot loop must not re-tune rows it already has.  The claim
    # doubles as the resume marker (latest_unretired_claim): it is retired as soon as the
    # exit code below has been read, so an UNRETIRED one means exactly "cut off".
    mkdir -p "$LOGDIR"
    local _stamp _claim
    _stamp="$(date +%Y%m%d-%H%M%S)"
    cp "$PLAN" "$LOGDIR/autotune-resume-$_stamp.rows"
    mv "$PLAN" "$PLAN.claimed-$_stamp"
    _claim="$PLAN.claimed-$_stamp"
    printf 'resuming %s row(s) through %s (claimed as %s.claimed-%s)\n' \
        "${#_kept[@]}" "$ENTRY" "$PLAN" "$_stamp"
    # A CHILD, not `exec`: the exit code is the loop's input, and `exec` threw it
    # away by replacing this process with the chunk.
    "$ENTRY" "${_kept[@]}" || _rc=$?
    printf 'entry point exited %s after %s row(s) were handed to it\n' "$_rc" "${#_kept[@]}"
    # RETIRE before deciding: the exit code HAS been read, so this run is no longer an
    # interrupted one however continue_after resolves it.  A stall that stops for a person
    # must not look like a cut-off chunk on the next boot.
    retire_claim "$_claim"
    continue_after "$_rc" "${#_kept[@]}"
}

# One line per fact: the plan, the boot ledger, whether a chunk is live, and the
# state of the loop itself.
show_status() {
    local _live=0 _pids=""
    if [[ -f "$PLAN" ]]; then
        printf 'plan: %s (%s row(s))\n' "$PLAN" "$(grep -c . "$PLAN")"
        sed 's/^/  /' "$PLAN"
    else
        printf 'plan: none at %s\n' "$PLAN"
    fi
    printf 'boot CUDA cycle ledger: %s\n' "$(ledger_value)"
    _pids=$(pgrep -f "$CHUNK_PATTERN") || _live=1
    if [[ "$_live" -eq 0 ]]; then
        printf 'a chunk IS live: %s\n' "$_pids"
    else
        printf 'no chunk in flight\n'
    fi
    printf 'model dir: %s\n' "$MODEL_DIR"
    local _claim=""
    if _claim="$(latest_unretired_claim)"; then
        if chunk_is_live; then
            printf 'claim in flight: %s\n' "$_claim"
            printf '  its chunk IS running - the claim is retired when its exit code is read\n'
        else
            printf 'UNREPORTED previous run: %s\n' "$_claim"
            printf '  its chunk was cut off before its exit code was read - the next boot re-derives and resumes\n'
        fi
    fi
    printf 'automatic restarts armed since --plan: %s (cap %s)\n' "$(restart_count)" "$ARM_MAX"
    if [[ -f "$ARMED_FILE" ]]; then
        local _f _b _r
        read -r _f _b _r < "$ARMED_FILE" || _f=""
        printf 'arm record: fired due %s from boot %s with %s row(s) owed (boot %s)\n' \
            "$(fmt_epoch "${_f:-0}")" \
            "${_b:-?}" "${_r:-?}" "$(boot_epoch || echo 0)"
    else
        printf 'arm record: none outstanding\n'
    fi
    printf 'CI jobs on this box: %s (a restart waits for these to drain)\n' "$(ci_workers)"
    report_parked
    return 0
}

# Argument parsing only; the default action is the unit's ExecStart.
main() {
    case "${1:-}" in
        --plan)    reset_restart_count; write_plan ;;
        --status)  show_status ;;
        --ensure-armed) ensure_armed ;;
        "")        run_plan ;;
        --help|-h) usage; return 0 ;;
        --version|-V) printf 'autotune-resume %s\n' "$VERSION"; return 0 ;;
        *) printf 'ERROR: unknown argument: %s\n' "$1"; usage; return "$EXIT_USAGE" ;;
    esac
}

main "$@"

# end of file
