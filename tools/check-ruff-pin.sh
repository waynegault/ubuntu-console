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
# Module Version: 3
#   v3 (2026-11-04): end with the repo's `# end of file` sentinel; the hygiene case over
#   tools/*.sh was red because this file stopped on code.
#   v2 (2026-11-01): route the five hand-written `>&2` sites through one warn() helper
#   and wrap the over-long lines, clearing the §18.3 10.7 and 8.1.8 rises.
set -uo pipefail

# warn — Report a problem on stderr.  Mirrors the repo's `warn()` helper (install.sh),
# so the redirect exists once rather than at each call site (§18.3 item 10.7).
warn() {
    printf '%s\n' "$@" >&2
}

repo="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
pre_commit="$repo/.pre-commit-config.yaml"
ci_req="$repo/.github/ci-requirements.txt"
venv_ruff="$repo/.venv/bin/ruff"

fail=0

# The ruff `rev:` is the one that FOLLOWS the ruff-pre-commit repo line, not the first
# `rev:` in the file (pre-commit-hooks has its own, v5.0.0).
pre_rev="$(awk '
    /ruff-pre-commit/ { in_ruff = 1 }
    in_ruff && /^[[:space:]]+rev:[[:space:]]+v[0-9]/ {
        sub(/.*v/, "")
        sub(/[^0-9.].*/, "")
        print
        exit
    }' "$pre_commit")"
ci_rev="$(awk '/^ruff==/ { sub(/^ruff==/, ""); sub(/[^0-9.].*/, ""); print; exit }' "$ci_req")"

if [[ -z "$pre_rev" ]]; then
    warn "check-ruff-pin: no ruff 'rev: vX.Y.Z' found in $pre_commit"
    fail=1
fi
if [[ -z "$ci_rev" ]]; then
    warn "check-ruff-pin: no 'ruff==X.Y.Z' found in $ci_req"
    fail=1
fi

if [[ -n "$pre_rev" && -n "$ci_rev" && "$pre_rev" != "$ci_rev" ]]; then
    warn "check-ruff-pin: ruff version drift —" \
         "  .pre-commit-config.yaml rev=v$pre_rev vs ci-requirements.txt ruff==$ci_rev"
    fail=1
fi

if [[ -x "$venv_ruff" ]]; then
    venv_rev="$("$venv_ruff" --version | awk '{ print $2 }')"
    if [[ -n "$ci_rev" && -n "$venv_rev" && "$venv_rev" != "$ci_rev" ]]; then
        warn "check-ruff-pin: ruff version drift —" \
             "  .venv/bin/ruff $venv_rev vs ci-requirements.txt ruff==$ci_rev"
        fail=1
    fi
fi

if (( fail != 0 )); then
    warn "check-ruff-pin: bump ci-requirements.txt (the single source), then match" \
         "  .pre-commit-config.yaml and the venv"
    exit 1
fi

echo "check-ruff-pin: ruff $ci_rev consistent (pre-commit, CI, venv)"
exit 0

# end of file
