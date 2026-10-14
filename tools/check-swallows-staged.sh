#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# check-swallows-staged.sh — the silent-swallow ratchet, SCOPED TO THE STAGED SET.
# ==============================================================================
# WHY THIS EXISTS — the failure it catches (measured 2026-10-14):
#   A push was refused by the whole-tree swallow gate, `FAIL
#   bin/openclaw-update-capture-prune.sh: 13 unclassified swallow(s) and no baseline
#   row`, for a file added by a PEER commit already on the local branch.  The block
#   landed on every other pusher, not on its author: tools/hooks/pre-commit (this
#   repo's core.hooksPath) ran only the secret scan, `tools/lint.sh --staged` and the
#   module-version guard, and a NEW file in the swallow corpus is a HARD FAIL by
#   design — so it stayed invisible until someone tried to publish.
#
# WHAT IT DOES: applies the swallow check's OWN two rules — a per-file unclassified
#   count ABOVE its tools/contracts-swallows-baseline.tsv row, or a corpus file with
#   unclassified sites and NO baseline row — to the files STAGED FOR THIS COMMIT
#   only.  A STALE row (a count BELOW its baseline) is FREE and never refuses: a fall
#   is a fix, not drift.
#
# NOT A WHOLE-TREE VERDICT: the scan is the tool's own and covers the whole corpus
#   (read-only, ~1 s), but the pass/fail DECISION is intersected with
#   `git diff --cached --name-only --diff-filter=ACM`.  This repo's working tree is
#   SHARED with peer sessions, so a whole-tree verdict would refuse YOUR commit for a
#   co-worker's in-flight file — the exact failure being removed.  `git diff --cached`
#   honours the index git uses for the commit (GIT_INDEX_FILE), so a pathspec commit
#   sees exactly the paths it carries.
#
# WHY IT DELEGATES THE COUNTING: the site SCANNER is tools/contracts_check.py, reached
#   read-only through `tools/check-contracts.sh swallows --print-baseline`.  A per-line
#   `grep` HERE would UNDERCOUNT — a line carrying both `|| true` and `2>/dev/null` is
#   TWO sites, and the tool counts per occurrence — and a second scanner could disagree
#   with the push gate.  This script reads the tool's OWN per-file counts
#   (`unclassified <TAB> <path> <TAB> <n>`) and compares them to the tool's OWN
#   baseline file, so the hook and `tools/check-contracts.sh swallows` cannot disagree
#   about a file both of them see.
#
# Usage:
#   tools/check-swallows-staged.sh            # the staged files of this repository
#   tools/check-swallows-staged.sh --repo DIR # the staged files of DIR (tests)
#
# Exit 0 = no staged file carries a NEW unclassified swallow.
# Exit 1 = at least one staged file does (named with its count and its baseline).
# Exit 2 = the check could not run (not a git repository, or the scanner could not run).
# ==============================================================================
# AI INSTRUCTION: Increment version on significant changes.
# Module Version: 1
set -uo pipefail

self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$self_dir/.." && pwd)"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) repo="${2:?--repo needs a path}"; shift 2 ;;
        --version | -V) echo "check-swallows-staged 1"; exit 0 ;;
        *) echo "check-swallows-staged: unknown argument '$1'" >&2; exit 2 ;;
    esac
done

if ! git -C "$repo" rev-parse --git-dir >/dev/null; then
    echo "check-swallows-staged: '$repo' is not a git repository — cannot scope to a staged set" >&2
    exit 2
fi

# ── The staged set for THIS commit ─────────────────────────────────────────
# Not filtered to *.sh or to the corpus: the corpus includes extensionless files
# (`bin/*`, `tools/hooks/*`), so the correct test is membership in the scan's own
# output, below — a path the scan never emitted is simply not a corpus file.
staged="$(git -C "$repo" diff --cached --name-only --diff-filter=ACM)" || {
    echo "check-swallows-staged: 'git diff --cached' failed in '$repo'" >&2
    exit 2
}
if [[ -z "$staged" ]]; then
    echo "check-swallows-staged: no staged files — nothing to check"
    exit 0
fi

declare -A is_staged=()
while IFS= read -r path; do
    [[ -n "$path" ]] && is_staged["$path"]=1
done <<< "$staged"

# ── The tool's OWN per-file population (read-only; never a verdict) ────────
# `--print-baseline` prints `unclassified <TAB> <rel> <TAB> <n>` for every corpus
# file with unclassified sites and always exits 0 (a dump, not a check), so a
# non-zero here means the SCANNER could not run — fail closed rather than pass on
# a population that was never measured.
if ! measured_raw="$("$self_dir/check-contracts.sh" swallows --print-baseline --repo "$repo")"; then
    echo "check-swallows-staged: the swallow scanner could not run" >&2
    echo "check-swallows-staged:   (tools/check-contracts.sh swallows --print-baseline --repo $repo)" >&2
    exit 2
fi

declare -A measured=()
while IFS=$'\t' read -r kind rel count; do
    [[ "$kind" == "unclassified" ]] || continue
    [[ -n "$rel" && -n "$count" ]] || continue
    measured["$rel"]="$count"
done <<< "$measured_raw"

# ── The baseline, read from the same file the scanner names ────────────────
# The scanner treats an absent baseline file as an empty baseline ("that is what
# makes the bare tool fail on a tree that carries no record"), so a missing file
# leaves `known` empty and every staged corpus file with a site is reported as
# having no row — the tool's own behaviour, not a weaker parse of it.
declare -A known=()
baseline_file="$repo/tools/contracts-swallows-baseline.tsv"
if [[ -f "$baseline_file" ]]; then
    while IFS=$'\t' read -r kind rel count; do
        [[ "$kind" == "unclassified" ]] || continue
        [[ -n "$rel" && -n "$count" ]] || continue
        known["$rel"]="$count"
    done < "$baseline_file"
fi

# ── The verdict: the tool's two rules, scoped to the staged set ────────────
fails=0
while IFS= read -r rel; do
    [[ -n "${is_staged[$rel]:-}" ]] || continue
    count="${measured[$rel]}"
    if [[ -n "${known[$rel]:-}" ]]; then
        base="${known[$rel]}"
        if (( count > base )); then
            printf '  FAIL  %s: %s unclassified swallow(s) against a baseline of %s — a NEW swallow needs a reason: mark it `# swallow-ok: <why>`, or fix the swallow\n' \
                "$rel" "$count" "$base" >&2
            fails=$((fails + 1))
        fi
    else
        printf '  FAIL  %s: %s unclassified swallow(s) and no baseline row. Mark each one on its own line or the line directly above it (`# swallow-ok: <one-line reason>`), or record the count in tools/contracts-swallows-baseline.tsv as a deliberate act\n' \
            "$rel" "$count" >&2
        fails=$((fails + 1))
    fi
done < <(printf '%s\n' "${!measured[@]}" | sort)

if (( fails > 0 )); then
    echo "check-swallows-staged: FAIL — $fails staged file(s) carry a NEW unclassified swallow" >&2
    echo "  A new swallow is a decision: mark it with a reason on the site, or on the line directly" >&2
    echo "  above it, or fix the swallow. Rows BELOW the baseline are free and are not reported here" >&2
    echo "  (the whole-tree gate reports those as STALE)." >&2
    exit 1
fi
echo "check-swallows-staged: OK — no staged file carries a NEW unclassified swallow"

# end of file
