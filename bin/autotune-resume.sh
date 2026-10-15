#!/usr/bin/env bash
# autotune-resume.sh - re-arm the autotune remainder after a WSL restart.
#
# WHY THIS EXISTS.  A restart ends everything in the distro.  Measured 2026-10-15:
# the running chunk is a child of the Qwen session's cli.js pair, which is itself a
# child of the VS Code window's extension host - so it dies with the CLIENT, never
# mind `wsl --shutdown`.  Nothing re-armed it, so a restart meant the tuner stopped
# until a person noticed.  This is the re-arm, shipped as a systemd USER unit so that
# it is not a child of any window: systemd/autotune-resume.service.
#
# THE PLAN IS THE GATE.  The scope is an owner decision (2026-10-13: the uncertified
# rows plus the flagged family, by MODEL FILE NAME), so `--plan` writes it to a plan
# file where it can be READ before it is trusted, rather than being re-derived
# silently at every boot.  With no plan this exits 0 and says so: a boot does nothing,
# loudly.
#
# THE PLAN IS CLAIMED ONCE.  Before the run it is copied to the log home and moved
# aside (not deleted), so a boot loop cannot re-tune rows it already has, and the
# operator can see exactly what ran.
#
# THE ENTRY POINT IS bin/autotune-rows.sh, never scripts/run-autotune-batch.sh: only
# the wrapper takes the box lock (bin/heavy-job) and holds the CUDA lane down for the
# whole run.  This script inherits that serialisation rather than adding a second one.
#
# USAGE
#   autotune-resume.sh --plan      derive the remainder and write the plan
#   autotune-resume.sh             execute the plan (the unit's ExecStart)
#   autotune-resume.sh --status    the plan, the ledger, and whether a chunk is live
#   autotune-resume.sh --help | --version
#
# EXIT CODES
#   exit 0 = nothing to do (no plan), or the run was handed to the entry point
#   exit 1 = a plan exists but nothing in it is runnable, or the entry point is missing
#   exit 2 = a bad argument
#
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 1
VERSION="1.0.0"

set -uo pipefail

EXIT_FAILED=1  # a plan exists but cannot be run, or its entry point is missing
EXIT_USAGE=2   # the caller asked for something this script cannot do

REPO="${REPO:-/home/wayne/ubuntu-console}"
REGISTRY="${TAC_RESUME_REGISTRY:-$HOME/.llm/models.conf}"
MODEL_DIR="${TAC_RESUME_MODEL_DIR:-${LLAMA_MODEL_DIR:-/mnt/m/active}}"
STATE_DIR="${TAC_RESUME_STATE_DIR:-${TAC_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/tactical-console}}"
LOGDIR="${TAC_RESUME_LOGDIR:-$HOME/.llm/autotune-logs}"
ENTRY="${TAC_RESUME_ENTRY:-$REPO/bin/autotune-rows.sh}"
PLAN="${TAC_RESUME_PLAN:-$STATE_DIR/autotune-resume.rows}"

# The scope Wayne ruled on 2026-10-13, by MODEL FILE NAME and never by row number (a
# row number is only a view of the registry, reassigned by every `model scan`): the
# uncertified rows, the flagged family (p2_tps above tps), and the two rows ruled NEW
# QUANTS.  Derived live from the registry, so it cannot go stale behind a hand list.
NEW_QUANTS='law-chat-Q2_K.gguf|Spark-X2.5-4B-Q4_K_M.gguf'

# The bracket class keeps a chunk probe from matching its own command line.
CHUNK_PATTERN='autotune[-]rows|run-autotune[-]batch|autotune[-]model|bench[-]rows'

# Print the usage block out of this file's own header, so the two cannot drift.
usage() {
    sed -n '/^# USAGE$/,/^#$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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

# Derive the remainder by the ruled scope rule and write it as the plan, printing it
# so the scope that is about to run can be read in the same breath.
write_plan() {
    local _rows
    if [[ ! -r "$REGISTRY" ]]; then
        printf 'ERROR: registry not readable: %s\n' "$REGISTRY"
        return "$EXIT_FAILED"
    fi
    _rows=$(awk -F'|' -v nq="$NEW_QUANTS" '
        $1 ~ /^[0-9]+$/ && NF > 1 {
            t = $17 + 0; p = $25 + 0
            if ($18 != "yes" || (p > t && t > 0) || $3 ~ ("^(" nq ")$")) print $3
        }' "$REGISTRY" | sort -u)
    if [[ -z "$_rows" ]]; then
        printf 'nothing to plan: every row is certified and unflagged (%s)\n' "$REGISTRY"
        return 0
    fi
    mkdir -p "$(dirname "$PLAN")"
    printf '%s\n' "$_rows" > "$PLAN"
    printf 'wrote %s with %s row(s):\n' "$PLAN" "$(printf '%s\n' "$_rows" | wc -l)"
    printf '  %s\n' "$_rows"
    return 0
}

# Run the plan: drop a row whose model file is gone (an unloadable row still burns
# CUDA cycles walking ctx - see the load-failure note), claim the plan, hand over.
run_plan() {
    local _row _kept=() _missing=0
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
    exec "$ENTRY" "${_kept[@]}"
}

# One line per fact: the plan, the boot ledger, and whether a chunk is live right now.
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
    return 0
}

# Argument parsing only; the default action is the unit's ExecStart.
main() {
    case "${1:-}" in
        --plan)    write_plan ;;
        --status)  show_status ;;
        "")        run_plan ;;
        --help|-h) usage; return 0 ;;
        --version|-V) printf 'autotune-resume %s\n' "$VERSION"; return 0 ;;
        *) printf 'ERROR: unknown argument: %s\n' "$1"; usage; return "$EXIT_USAGE" ;;
    esac
}

main "$@"

# end of file
