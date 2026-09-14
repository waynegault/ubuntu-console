#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# check-module-versions.sh — Fail when a changed module's Module Version did not
# move.
# ==============================================================================
# TACTICAL_PROFILE_VERSION is the SUM of every module's `# Module Version: N`
# (see scripts/01-constants.sh), so a forgotten bump mislabels every version
# derived from it — and nothing else notices: the module still loads and its
# tests still pass.
#
# Only files that CARRY the marker are checked, so the VERSION="x.y" helpers
# (bin/*.sh, whose contract is "increment on significant changes") are
# unaffected.  A brand-new file has no previous version to compare against and
# is skipped.
#
# Usage:
#   tools/check-module-versions.sh                  # staged vs HEAD (pre-commit)
#   tools/check-module-versions.sh --staged         # same, explicit
#   tools/check-module-versions.sh --worktree       # worktree vs HEAD
#   tools/check-module-versions.sh --worktree --base origin/main
#   tools/check-module-versions.sh --repo /path     # check another checkout
#
# Exit 0 = every changed module bumped its version (or nothing to check).
# Exit 1 = at least one changed module kept its old version.
# Exit 2 = bad invocation / not a git repository.
# ==============================================================================
# AI INSTRUCTION: Increment version on significant changes.
# Module Version: 1
set -uo pipefail

if [[ "${1:-}" == "--version" || "${1:-}" == "-V" ]]; then
    echo "check-module-versions 1"
    exit 0
fi

# Default to the repository this script lives in (the repo's convention for
# tools/), overridable so a throwaway repo can be checked — that is how the
# unit suite exercises it without touching a real index.
repo_default="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

mode="staged"
base="HEAD"
repo="$repo_default"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --staged)   mode="staged";   shift ;;
        --worktree) mode="worktree"; shift ;;
        --base)     base="${2:?--base needs a git ref}"; shift 2 ;;
        --repo)     repo="${2:?--repo needs a path}";    shift 2 ;;
        *) echo "check-module-versions: unknown argument '$1'" >&2; exit 2 ;;
    esac
done

cd "$repo" || exit 2
if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "check-module-versions: not a git repository — nothing to check" >&2
    exit 2
fi

if [[ "$mode" == "staged" ]]; then
    mapfile -t files < <(git diff --cached --name-only --diff-filter=ACM 2>/dev/null)
else
    mapfile -t files < <(git diff --name-only --diff-filter=ACM "$base" 2>/dev/null)
fi

fail=0
checked=0
for f in "${files[@]}"; do
    [[ "$f" == *.sh ]] || continue

    if [[ "$mode" == "staged" ]]; then
        new=$(git show ":$f" 2>/dev/null | grep -m1 '^# Module Version:' || true)
    else
        new=$(grep -m1 '^# Module Version:' "$f" 2>/dev/null || true)
    fi
    [[ -n "$new" ]] || continue          # no marker in this file (e.g. bin/*.sh)

    old=$(git show "${base}:${f}" 2>/dev/null | grep -m1 '^# Module Version:' || true)
    [[ -n "$old" ]] || continue          # new file — nothing to compare against

    checked=$((checked + 1))
    if [[ "$new" == "$old" ]]; then
        echo "  FAIL  $f  ($new unchanged on a modified file — bump it)"
        fail=1
    fi
done

if (( fail != 0 )); then
    echo "check-module-versions: bump the Module Version of the file(s) above (or commit with --no-verify)" >&2
    exit 1
fi

if (( checked > 0 )); then
    echo "check-module-versions: $checked changed module(s), all versions bumped"
else
    echo "check-module-versions: no changed module versions to check"
fi
exit 0

# end of file
