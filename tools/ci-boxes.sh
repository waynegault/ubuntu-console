#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# ci-boxes.sh — which per-box CI arms this repo's pushes must run.
# ==============================================================================
# The per-box jobs (`behavioral`, `python-unit`) named their matrix as a literal
# `[ARM64, X64]`.  A literal asserts "both boxes exist" without ever reading
# whether they do, and an arm whose runner is absent does not fail — it QUEUES.
# A run that can never conclude is worse than a red one: nothing is reported, so
# nothing is decided, and the gate reads as "still running" forever.
#
# Measured 2026-11-19: `wsl-console-1` (X64, on the XPS 15) was offline and that
# host was unreachable over SSH, while `wsl-console-arm64` served every push.
# Run 44512057230 sat `queued` on `Behavioral BATS (X64)` and could not finish.
#
# SOURCE OF TRUTH: `config/hosts.d/*.conf` — the same files `tools/host-profile.sh`
# resolves a box from.  A profile declares its CI box as
#     TAC_HOST_CI_BOX=ARM64            # the runner label this box answers
#     TAC_HOST_CI_BOX_ENABLED=1        # 0 retires the arm without deleting tuning
# so bringing a box back is a one-line config edit, and the matrix cannot drift
# from the profiles the jobs actually run on.
#
# This file is PARSED, never sourced: a config read must not execute code, and a
# stray `exit` or `set -e` in a profile must not be able to end this script early
# and leave the matrix half-built.
#
# Usage:
#   tools/ci-boxes.sh            # ARM64          (matrix literal, space separated)
#   tools/ci-boxes.sh --json     # ["ARM64"]
#   tools/ci-boxes.sh --check    # 0 and the list; 2 when empty (never guesses)
# ==============================================================================
# AI INSTRUCTION: Increment version on significant changes.
# Module Version: 1
#   v1 (2026-11-19): first cut — the CI box matrix is derived from the host
#   profiles instead of a hand-written literal that queued forever.
# ==============================================================================
set -uo pipefail

_ci_boxes_root() {
    # From this script's own location, so a caller's cwd cannot change which
    # profiles are read (the `git ls-files`-from-another-lane defect class).
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    printf '%s\n' "$(cd "$here/.." && pwd)"
}

# _conf_value FILE KEY — the last assignment of KEY in FILE, unquoted.
# Handles `KEY=value`, `KEY="value"` and `KEY='value'`; ignores comments.
_conf_value() {
    local file="$1" key="$2" line val=""
    while IFS= read -r line; do
        case "$line" in
            "$key="* )
                val="${line#*=}"
                # strip one layer of matching quotes
                case "$val" in
                    \"*\") val="${val#\"}"; val="${val%\"}" ;;
                    \'*\') val="${val#\'}"; val="${val%\'}" ;;
                esac
                val="${val%%[[:space:]]#*}"
                val="${val%"${val##*[![:space:]]}"}"
                ;;
        esac
    done < "$file"
    printf '%s' "$val"
}

ci_boxes_list() {
    local root conf id arch box enabled
    local -a confs=() out=()
    root="$(_ci_boxes_root)"
    shopt -s nullglob
    confs=("$root"/config/hosts.d/*.conf)
    shopt -u nullglob

    if [ "${#confs[@]}" -eq 0 ]; then
        printf 'ci-boxes: no profiles under %s/config/hosts.d — refusing to guess a CI matrix\n' \
            "$root" >&2
        return 2
    fi

    for conf in "${confs[@]}"; do
        # A `*-quant-guide.conf` companion is not a machine identity: host-profile.sh
        # v13 skips them, and a profile with no id is skipped here for the same reason.
        id="$(_conf_value "$conf" TAC_HOST_PROFILE_ID)"
        [ -n "$id" ] || continue

        box="$(_conf_value "$conf" TAC_HOST_CI_BOX)"
        if [ -z "$box" ]; then
            # Derive from the declared architecture rather than inventing a name.
            arch="$(_conf_value "$conf" TAC_HOST_PROFILE_ARCH)"
            case "$arch" in
                aarch64|arm64)      box=ARM64 ;;
                x86_64|amd64|x64)   box=X64 ;;
                * )
                    printf 'ci-boxes: %s declares arch=%s and no TAC_HOST_CI_BOX — refusing to name a box\n' \
                        "$id" "${arch:-<unset>}" >&2
                    return 2
                    ;;
            esac
        fi

        enabled="$(_conf_value "$conf" TAC_HOST_CI_BOX_ENABLED)"
        [ -n "$enabled" ] || enabled=1
        if [ "$enabled" = "0" ]; then
            printf 'ci-boxes: skipping %s (%s disabled)\n' "$box" "$id" >&2
            continue
        fi
        out+=("$box")
    done

    if [ "${#out[@]}" -eq 0 ]; then
        printf 'ci-boxes: every profile retires its CI box — refusing to emit an empty matrix\n' >&2
        return 2
    fi
    # sort -u: two profiles may legitimately name the same box (one per tuning),
    # and a duplicate matrix arm would run the same job twice on one runner.
    printf '%s\n' "${out[@]}" | sort -u | tr '\n' ' ' | sed 's/ *$//'
    printf '\n'
}

case "${1:-}" in
    "" ) ci_boxes_list ;;
    --json )
        list="$(ci_boxes_list)" || exit $?
        printf '['
        first=1
        for b in $list; do
            [ "$first" -eq 1 ] || printf ','
            printf '"%s"' "$b"
            first=0
        done
        printf ']\n'
        ;;
    --check )
        list="$(ci_boxes_list)" || exit $?
        [ -n "${list// /}" ] || { printf 'ci-boxes: empty matrix\n' >&2; exit 2; }
        printf '%s\n' "$list"
        ;;
    * )
        printf 'ci-boxes: unknown argument: %s (use --json or --check)\n' "$1" >&2
        exit 2
        ;;
esac
# end of file
