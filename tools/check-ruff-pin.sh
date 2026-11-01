#!/usr/bin/env bash
# check-ruff-pin.sh — one ruff version, enforced across every file that restates it.
#
# ruff is pinned for CI in .github/ci-requirements.txt (ruff==X.Y.Z) and, because the
# ruff-pre-commit hook downloads its OWN ruff, restated as a git tag in
# .pre-commit-config.yaml (rev: vX.Y.Z).  A bump in one without the other is silent
# drift that makes local pre-commit and CI lint different bytes (measured 2026-09-18
# with ruff).  This guard refuses a commit where the two disagree, and — when the
# project venv has a ruff — where the venv's installed ruff disagrees with both.
# ci-requirements.txt is the single source; the other two are verified against it,
# never maintained in parallel.
#
# The check reads the WORKING TREE, not the index.  A version bump edits both files
# together (the bump is one change), so the working tree already holds the new values
# when the commit runs; the only case it misses is a `git add -p` that stages one file
# and not the other, which the push-time whole-tree lint still sees.
#
# AI INSTRUCTION: Increment version on significant changes.
# Module Version: 1
set -uo pipefail

repo="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
pre_commit="$repo/.pre-commit-config.yaml"
ci_req="$repo/.github/ci-requirements.txt"
venv_ruff="$repo/.venv/bin/ruff"

fail=0

# The ruff `rev:` is the one that FOLLOWS the ruff-pre-commit repo line, not the first
# `rev:` in the file (pre-commit-hooks has its own, v5.0.0).
pre_rev="$(awk '/ruff-pre-commit/{f=1} f && /^[[:space:]]+rev:[[:space:]]+v[0-9]/{sub(/.*v/, ""); sub(/[^0-9.].*/, ""); print; exit}' "$pre_commit")"
ci_rev="$(awk '/^ruff==/{sub(/^ruff==/, ""); sub(/[^0-9.].*/, ""); print; exit}' "$ci_req")"

if [[ -z "$pre_rev" ]]; then
    echo "check-ruff-pin: no ruff 'rev: vX.Y.Z' found in $pre_commit" >&2
    fail=1
fi
if [[ -z "$ci_rev" ]]; then
    echo "check-ruff-pin: no 'ruff==X.Y.Z' found in $ci_req" >&2
    fail=1
fi

if [[ -n "$pre_rev" && -n "$ci_rev" && "$pre_rev" != "$ci_rev" ]]; then
    echo "check-ruff-pin: ruff version drift — .pre-commit-config.yaml rev=v$pre_rev vs ci-requirements.txt ruff==$ci_rev" >&2
    fail=1
fi

if [[ -x "$venv_ruff" ]]; then
    venv_rev="$("$venv_ruff" --version | awk '{for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+$/) {print $i; exit}}')"
    if [[ -n "$ci_rev" && -n "$venv_rev" && "$venv_rev" != "$ci_rev" ]]; then
        echo "check-ruff-pin: ruff version drift — .venv/bin/ruff $venv_rev vs ci-requirements.txt ruff==$ci_rev" >&2
        fail=1
    fi
fi

if (( fail != 0 )); then
    echo "check-ruff-pin: bump ci-requirements.txt (the single source), then match .pre-commit-config.yaml and the venv" >&2
    exit 1
fi

echo "check-ruff-pin: ruff $ci_rev consistent (pre-commit, CI, venv)"
exit 0
