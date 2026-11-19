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
# Module Version: 2
#   v2 (2026-11-19): refuse RETURNS 2 and the callers propagate it.  It must not
#   `exit`: called from inside a command substitution, `exit` ends only the
#   subshell and the parent goes on to print `[]` with rc 0 — the exact silent
#   green the emptiness check exists to prevent, measured while writing v1.
#   REFUSE_RC names the code once; ci_boxes_list is split (emit_json) to stay
#   under the 100-line function ratchet; say_skip groups its redirect.
#   v1 (2026-11-19): first cut — the CI box matrix is derived from the host
#   profiles instead of a hand-written literal that queued forever.
# ==============================================================================
set -uo pipefail

# REFUSE_RC — 2 = usage: this script cannot answer from its config, and a guessed
# matrix is worse than none. Named so every refusal states the same code once.
REFUSE_RC=2

# say_skip TEXT — one message per call, on stderr, so `--json` stdout stays a
# parseable document a workflow can read. The redirect is GROUPED rather than on
# the printf line, the shape tools/check-hooks-path.sh uses for the same job.
say_skip() {
    {
        printf 'ci-boxes: %s\n' "$*"
    } >&2
}

# refuse TEXT — a config the deriver will not answer from.  Returns 2 and never
# exits: an empty or guessed matrix is a run with no per-box jobs, i.e. a silent
# green, and this function is called from inside a command substitution where
# `exit` would end only the subshell — leaving the parent to print `[]` with rc 0.
# The CALLER propagates the 2.
refuse() {
    say_skip "$*"
    return "$REFUSE_RC"
}

# _ci_boxes_root — the repository root, from this script's own location so a
# caller's cwd cannot change which profiles are read (the defect class where a
# path-only command resolves against the wrong lane's directory and says nothing).
_ci_boxes_root() {
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

# ci_boxes_list — the enabled CI boxes, one per line, deduplicated and sorted.
# Reads every profile under config/hosts.d; derives the box from the declared
# architecture when a profile states no TAC_HOST_CI_BOX.  Refuses (exit 2) on an
# empty config, an unnameable box, or a matrix where every arm is retired.
ci_boxes_list() {
    local root conf id arch box enabled
    local -a confs=() out=()
    root="$(_ci_boxes_root)"
    shopt -s nullglob
    confs=("$root"/config/hosts.d/*.conf)
    shopt -u nullglob

    if [[ "${#confs[@]}" -eq 0 ]]; then
        refuse "no profiles under $root/config/hosts.d — refusing to guess a CI matrix"
        return "$REFUSE_RC"
    fi

    for conf in "${confs[@]}"; do
        # A `*-quant-guide.conf` companion is not a machine identity: host-profile.sh
        # v13 skips them, and a profile with no id is skipped here for the same reason.
        id="$(_conf_value "$conf" TAC_HOST_PROFILE_ID)"
        if [[ -z "$id" ]]; then
            continue
        fi

        box="$(_conf_value "$conf" TAC_HOST_CI_BOX)"
        if [[ -z "$box" ]]; then
            # Derive from the declared architecture rather than inventing a name.
            arch="$(_conf_value "$conf" TAC_HOST_PROFILE_ARCH)"
            case "$arch" in
                aarch64|arm64)      box=ARM64 ;;
                x86_64|amd64|x64)   box=X64 ;;
                * )
                    refuse "$id declares arch=${arch:-<unset>} and no TAC_HOST_CI_BOX — refusing to name a box"
                    return "$REFUSE_RC"
                    ;;
            esac
        fi

        enabled="$(_conf_value "$conf" TAC_HOST_CI_BOX_ENABLED)"
        if [[ -z "$enabled" ]]; then
            enabled=1
        fi
        if [[ "$enabled" == 0 ]]; then
            say_skip "skipping $box ($id disabled)"
            continue
        fi
        out+=("$box")
    done

    if [[ "${#out[@]}" -eq 0 ]]; then
        refuse "every profile retires its CI box — refusing to emit an empty matrix"
        return "$REFUSE_RC"
    fi
    # sort -u: two profiles may legitimately name the same box (one per tuning),
    # and a duplicate matrix arm would run the same job twice on one runner.
    printf '%s\n' "${out[@]}" | sort -u | tr '\n' ' ' | sed 's/ *$//'
    printf '\n'
}

# emit_json LIST — the matrix as a JSON array, which is what fromJSON() consumes.
emit_json() {
    local list="$1" b first=1
    printf '['
    for b in $list; do
        if [[ "$first" -eq 0 ]]; then
            printf ','
        fi
        printf '"%s"' "$b"
        first=0
    done
    printf ']\n'
}

case "${1:-}" in
    "" )
        # A refusal propagates, same reason as --json.
        ci_boxes_list || exit "$REFUSE_RC"
        ;;
    --json )
        # A refusal propagates: an empty matrix would otherwise read as a green run.
        list="$(ci_boxes_list)" || exit "$REFUSE_RC"
        emit_json "$list"
        ;;
    --check )
        # A refusal propagates, same reason as --json.
        list="$(ci_boxes_list)" || exit "$REFUSE_RC"
        printf '%s\n' "$list"
        ;;
    * )
        refuse "unknown argument: $1 (use --json or --check)"
        exit "$REFUSE_RC"
        ;;
esac
# end of file
