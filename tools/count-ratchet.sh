#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# count-ratchet.sh — fail when a docs/inspection.md §18.3 count RISES.
# ═══════════════════════════════════════════════════════════════════════════════
# §18.3 is a table of ~27 stylistic migration items that a correctness pass counted
# but deliberately did not fix.  Its own closing note says where they belong:
#
#   "This belongs in a ratchet — a guard that fails when the count RISES — not in a
#    per-pass to-do list.  A number with no owner and no enforcement only grows."
#
# This is that guard: a baseline of the current counts, and a non-zero exit when any
# of them grows.  Lowering a number is free (and reported, so the baseline can follow);
# raising one is a deliberate act that has to be re-baselined on purpose.
#
# WHAT THIS IS NOT: a semantic measurement of code quality.  Each counter is a
# deliberately simple, stable pattern over the tracked shell corpus — the point is
# comparability across revisions, not precision.  Re-deriving an item's *true*
# population is a separate exercise (three of §18.3's figures moved when it was done
# on 2026-09-21: 9→10, 10→19, 41→112).  When a counter is re-derived, lower its
# baseline in the same change and say so in the commit.
#
# THREE ITEMS ARE DELIBERATELY NOT RATCHETED: 4.2.1 (`&&` with `||`), 4.2.5 (`if …;
# then` on one line) and 8.2.2 (`readonly` not ALL_CAPS).  Their populations ARE the
# house style — the safe braced `X && { a || b; }` form, §18.3's own 634 sites it calls
# "idiomatic, not a defect", and the documented `C_*` design-token API — so a ratchet on
# them would fail on ordinary new code instead of on drift worth stopping.  This guard's
# first CI run proved the point: the tool file itself carries four of these patterns, so
# adding it raised four counts at once.
#
# THE BASELINE IS CORPUS-RELATIVE, so a NEW shell file raises several counts by itself
# (`git ls-files` lists only tracked files — baseline after committing, and expect one
# deliberate re-baseline when a file is added).
#
# Usage:
#   tools/count-ratchet.sh              # check against tools/ratchet-baseline.tsv
#   tools/count-ratchet.sh --list       # print every counter with its numbers
#   tools/count-ratchet.sh --update     # re-baseline (deliberate; review the diff)
#   tools/count-ratchet.sh --selftest   # prove every counter against a fixture
#   tools/count-ratchet.sh -h
#
# Exit 0 = no count rose · 1 = a count rose · 2 = bad invocation.
#
# The corpus is the tracked shell set: *.sh, *.bashrc and bin/* (git ls-files), with
# comment-only lines excluded.  It is deliberately the same scope §18.3 measured.
#
# --selftest exists because a counter nobody can make go red is not evidence (§3.1):
# every counter is exercised against a fixture whose expected value is written down,
# and the run fails if any counter disagrees.
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASELINE="$REPO_ROOT/tools/ratchet-baseline.tsv"

mode="check"
case "${1:-}" in
    ""|--check)  mode="check" ;;
    --list)      mode="list" ;;
    --update)    mode="update" ;;
    --selftest)  mode="selftest" ;;
    -h|--help)
        sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *)
        echo "usage: count-ratchet.sh [--check|--list|--update|--selftest]" >&2
        exit 2
        ;;
esac

# Prefer the repo's venv python: it is the interpreter the rest of this repo's
# tooling resolves, and the one CI installs deps into (card dd96b63f — this
# wrapper used bare `python3`).
_python="python3"
if [[ -x "$REPO_ROOT/.venv/bin/python3" ]]; then
    _python="$REPO_ROOT/.venv/bin/python3"
fi
if ! command -v "$_python" >/dev/null 2>&1; then
    echo "ERROR: python3 is required (the counters parse shell, and are not line greps)." >&2
    exit 2
fi

# The counters are a real module now (tools/ratchet_check.py) so ruff, mypy and
# pyright see them; this wrapper only selects the interpreter and forwards the
# same argv — `python3 -` and `python3 <file>` both expose the arguments at
# sys.argv[1:].
exec "$_python" "$REPO_ROOT/tools/ratchet_check.py" "$REPO_ROOT" "$BASELINE" "$mode"

# end of file
