#!/usr/bin/env bash
# shellcheck shell=bash
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 3
# bench-resume.sh — make a bench sweep survive a restart.
#
# The autotune campaign has a plan + a boot timer + the box's restart wrapper. The
# bench had none: `bench-rows.sh 1 2 ... 27` held a shell, and a WSL restart (routine
# on this box, because the CUDA cycle ledger is boot-scoped) simply lost the sweep.
#
# Usage:
#   bench-resume.sh --plan <row> [<row> ...]   write the plan (the gate)
#   bench-resume.sh --run                      claim the plan and run bench-rows.sh
#   bench-resume.sh --status                   show the plan
#   bench-resume.sh --clear                    drop the plan
#
# `--run` is what the boot unit calls. It runs the tracked bench wrapper, which takes
# the box lock and holds the CUDA lane down. The plan is cleared only on success, so a
# failed or interrupted sweep is retried on the next boot rather than silently lost.
#
# Env seams (pinned by tests/unit/68-bench-resume.bats):
#   TAC_STATE_DIR        state directory (default XDG state/tactical-console)
#   BENCH_RESUME_PLAN    plan path (default $TAC_STATE_DIR/bench-resume.rows)
#   BENCH_RESUME_CMD     the bench command (default this script's own bench-rows.sh)
#   BENCH_RESUME_ARGS    extra args passed before the rows (default none)
#
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
STATE_DIR="${TAC_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/tactical-console}"
PLAN="${BENCH_RESUME_PLAN:-$STATE_DIR/bench-resume.rows}"
BENCH="${BENCH_RESUME_CMD:-$SELF_DIR/bench-rows.sh}"

# Print the usage block to stderr, for a usage error.
usage() {
    printf '%s\n' \
        'usage: bench-resume.sh --plan <row> [<row> ...]' \
        '       bench-resume.sh --run | --status | --clear'
}

case "${1:-}" in
    --plan)
        shift
        if (( $# == 0 )); then
            printf 'ERROR: --plan needs at least one row\n' >&2
            # 2 = usage error
            exit 2
        fi
        mkdir -p "$(dirname "$PLAN")" || exit 1
        printf '%s\n' "$@" > "$PLAN" || exit 1
        printf 'bench plan: %s (%s row(s))\n' "$PLAN" "$#"
        ;;
    --run)
        if [[ ! -r "$PLAN" ]]; then
            printf 'no bench plan at %s — nothing to resume\n' "$PLAN"
            exit 0
        fi
        mapfile -t rows < "$PLAN"
        if (( ${#rows[@]} == 0 )); then
            rm -f "$PLAN"
            printf 'empty bench plan removed\n'
            exit 0
        fi
        printf 'resuming bench: %s\n' "${rows[*]}"
        # shellcheck disable=SC2086  # BENCH_RESUME_ARGS is deliberately word-split
        "$BENCH" ${BENCH_RESUME_ARGS:-} "${rows[@]}"
        rc=$?
        if (( rc == 0 )); then
            rm -f "$PLAN"
            printf 'bench plan cleared: %s\n' "$PLAN"
        else
            printf 'bench plan KEPT (rc=%s): %s\n' "$rc" "$PLAN" >&2
        fi
        exit "$rc"
        ;;
    --status)
        if [[ -r "$PLAN" ]]; then
            printf 'plan: %s (%s row(s))\n' "$PLAN" "$(grep -c . "$PLAN")"
            sed 's/^/  /' "$PLAN"
        else
            printf 'plan: none at %s\n' "$PLAN"
        fi
        ;;
    --clear)
        if [[ -e "$PLAN" ]]; then
            rm -f "$PLAN"
            printf 'bench plan cleared: %s\n' "$PLAN"
        else
            printf 'no bench plan at %s\n' "$PLAN"
        fi
        ;;
    *)
        usage >&2
        # 2 = usage error
        exit 2
        ;;
esac

# end of file
