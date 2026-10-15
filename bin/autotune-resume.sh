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
# THE PLAN IS CLAIMED ONCE.  Before the run it is copied to the log home and moved
# aside (not deleted), so a boot loop cannot re-tune rows it already has.
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
#   autotune-resume.sh --help | --version
#
# EXIT CODES
#   exit 0 = nothing to do, the campaign finished, or it continues (a restart armed)
#   exit 1 = a plan exists but nothing in it is runnable, or the entry point is missing
#   exit 2 = a bad argument
#   exit 3 = the chunk stopped for the ADAPTER with the budget unspent (propagated)
#   exit 4 = the campaign PAUSED: a budget halt that will not resume by itself
#
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 2
VERSION="2.0.0"

set -uo pipefail

EXIT_FAILED=1  # a plan exists but cannot be run, or its entry point is missing
EXIT_USAGE=2   # the caller asked for something this script cannot do
EXIT_ADAPTER=3 # the chunk stalled with the cycle budget UNSPENT: a person looks
EXIT_BUDGET=4  # the chunk spent the cycle budget: resumable, and the designed halt
EXIT_PAUSED=4  # ...but only when it made progress; otherwise the campaign pauses

REPO="${REPO:-/home/wayne/ubuntu-console}"
REGISTRY="${TAC_RESUME_REGISTRY:-$HOME/.llm/models.conf}"
MODEL_DIR="${TAC_RESUME_MODEL_DIR:-${LLAMA_MODEL_DIR:-/mnt/m/active}}"
STATE_DIR="${TAC_RESUME_STATE_DIR:-${TAC_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/tactical-console}}"
LOGDIR="${TAC_RESUME_LOGDIR:-$HOME/.llm/autotune-logs}"
ENTRY="${TAC_RESUME_ENTRY:-$REPO/bin/autotune-rows.sh}"
PLAN="${TAC_RESUME_PLAN:-$STATE_DIR/autotune-resume.rows}"
RESTART_TOOL="${TAC_RESUME_RESTART_TOOL:-$REPO/bin/wsl-restart.sh}"

# The loop's knobs, all overridable so a test drives them without touching Windows.
ARM_MAX="${TAC_RESUME_ARM_MAX:-8}"             # consecutive automatic restarts allowed
ARM_DELAY_MIN="${TAC_RESUME_ARM_DELAY:-3}"     # minutes after the halt to restart
CI_WAIT_S="${TAC_RESUME_CI_WAIT_S:-900}"       # bounded wait for a CI job to drain
CI_POLL_S="${TAC_RESUME_CI_POLL_S:-30}"
RESTARTS_FILE="$STATE_DIR/autotune-resume.auto-restarts"

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

# The bracket class keeps a chunk probe from matching its own command line.
CHUNK_PATTERN='autotune[-]rows|run-autotune[-]batch|autotune[-]model|bench[-]rows'

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
            if ($18 != "yes" || (p > t && t > 0) || $3 ~ ("^(" nq ")$")) print $3
        }' "$REGISTRY" | sort -u
}

# Derive the remainder and write it as the plan, printing it so the scope that is
# about to run can be read in the same breath.
write_plan() {
    local _rows
    if [[ ! -r "$REGISTRY" ]]; then
        printf 'ERROR: registry not readable: %s\n' "$REGISTRY"
        return "$EXIT_FAILED"
    fi
    _rows=$(derive_rows)
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

# A CI job executing on THIS box, as a count.  A restart cancels it, and a cancelled
# run leaves main red here, so this is a gate rather than a note.
ci_workers() {
    local _n
    if [[ -n "${TAC_RESUME_CI_WORKERS_CMD:-}" ]]; then
        _n=$("$TAC_RESUME_CI_WORKERS_CMD") || _n=""
        printf '%s\n' "${_n:-0}"
        return 0
    fi
    # swallow-ok: `pgrep -c` exits 1 when nothing matches, and "nothing matches" IS
    # the clean answer this row reports
    _n=$(pgrep -cf '[R]unner.Worker') || _n=0
    printf '%s\n' "${_n:-0}"
}

# Wait, bounded, for the CI job to finish.  Returns 1 on EXHAUSTION - it aborts
# rather than falling through to the restart it guards (a bounded wait whose only
# failure path is the action it guards is the shape that has bitten this repo).
wait_for_ci_clear() {
    local _deadline=$(( SECONDS + CI_WAIT_S )) _n
    while :; do
        _n=$(ci_workers)
        if [[ "$_n" =~ ^[0-9]+$ ]] && (( _n == 0 )); then
            return 0
        fi
        if (( SECONDS >= _deadline )); then
            return 1
        fi
        sleep "$CI_POLL_S"
    done
}

# Arm the next restart through the TRACKED tool, and read its registration back.
# Nothing here touches Windows itself: bin/wsl-restart.sh owns that, including the
# chunk gate that refuses to cut a row in half.
arm_restart() {
    local _n _rc=0
    _n=$(restart_count)
    if (( _n >= ARM_MAX )); then
        printf 'NOT arming a restart: %s automatic restarts already (cap %s)\n' "$_n" "$ARM_MAX"
        printf '  the cap is a stop, not a fault - re-run --plan to start a fresh campaign\n'
        return "$EXIT_PAUSED"
    fi
    if ! wait_for_ci_clear; then
        printf 'NOT arming a restart: a CI job is executing on this box\n'
        printf '  a restart cancels it, and a cancelled run leaves main red here\n'
        printf '  re-arm by hand when the queue is empty: %s --restart --delay %s\n' \
            "$RESTART_TOOL" "$ARM_DELAY_MIN"
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
    printf 'armed restart %s/%s: the next boot resumes the remainder at %s\n' \
        "$(( _n + 1 ))" "$ARM_MAX" "$(date -Iseconds)"
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
        return "$EXIT_ADAPTER"
    fi
    if (( _rc != EXIT_BUDGET )); then
        printf 'not continuing: the chunk exited %s (only %s, the spent cycle budget, resumes)\n' \
            "$_rc" "$EXIT_BUDGET"
        return "$_rc"
    fi
    _after=$(derive_rows | awk 'END { print NR }')
    if (( _after == 0 )); then
        printf 'the remainder is EMPTY - the campaign is complete; no restart armed\n'
        return 0
    fi
    if (( _after >= _before )); then
        printf 'NOT arming a restart: this boot did not shrink the remainder (%s -> %s)\n' \
            "$_before" "$_after"
        printf '  the rows it would re-run are the ones that just ran; a person decides\n'
        return "$EXIT_PAUSED"
    fi
    printf 'the remainder shrank %s -> %s in this boot\n' "$_before" "$_after"
    write_plan || return "$EXIT_PAUSED"
    arm_restart
}

# Run the plan: drop a row whose model file is gone (an unloadable row still burns
# CUDA cycles walking ctx - see the load-failure note), claim the plan, hand over.
run_plan() {
    local _row _kept=() _missing=0 _rc=0
    if [[ ! -f "$PLAN" ]]; then
        printf 'no plan at %s - nothing to resume (write one with --plan)\n' "$PLAN"
        return 0
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

    # Claim it BEFORE the run: a boot loop must not re-tune rows it already has.
    mkdir -p "$LOGDIR"
    local _stamp
    _stamp="$(date +%Y%m%d-%H%M%S)"
    cp "$PLAN" "$LOGDIR/autotune-resume-$_stamp.rows"
    mv "$PLAN" "$PLAN.claimed-$_stamp"
    printf 'resuming %s row(s) through %s (claimed as %s.claimed-%s)\n' \
        "${#_kept[@]}" "$ENTRY" "$PLAN" "$_stamp"
    # A CHILD, not `exec`: the exit code is the loop's input, and `exec` threw it
    # away by replacing this process with the chunk.
    "$ENTRY" "${_kept[@]}" || _rc=$?
    printf 'entry point exited %s after %s row(s) were handed to it\n' "$_rc" "${#_kept[@]}"
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
    printf 'automatic restarts armed since --plan: %s (cap %s)\n' "$(restart_count)" "$ARM_MAX"
    printf 'CI jobs on this box: %s (a restart waits for these to drain)\n' "$(ci_workers)"
    report_parked
    return 0
}

# Argument parsing only; the default action is the unit's ExecStart.
main() {
    case "${1:-}" in
        --plan)    reset_restart_count; write_plan ;;
        --status)  show_status ;;
        "")        run_plan ;;
        --help|-h) usage; return 0 ;;
        --version|-V) printf 'autotune-resume %s\n' "$VERSION"; return 0 ;;
        *) printf 'ERROR: unknown argument: %s\n' "$1"; usage; return "$EXIT_USAGE" ;;
    esac
}

main "$@"

# end of file
