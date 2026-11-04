#!/usr/bin/env bash
# turn-checks.sh — ONE UserPromptSubmit hook: the per-turn checks, cheap-first.
#
# Three checks used to be three separate UserPromptSubmit hooks (gate-status-check,
# guard-patch-check, memory-markdownlint), each registered and spawned per turn.  That
# was three registrations to keep in sync and a hidden run order (the CLI runs hooks in
# registration order, so the expensive markdown lint could run before the cheap gate
# read).  This single entry point runs them in cheap-to-expensive order, so a failed
# store gate or a reverted guard patch surfaces before the markdown lint spends its time.
#
# Each check is an independent script that ALWAYS exits 0 (a degraded check is a warning,
# never a blocker) and prints NOTHING when clean.  This wrapper adds no output of its own
# and exits 0, so a clean turn still costs no tokens — the same contract as the three it
# runs.
#
# Deliberately NOT `set -e`: a failing child check must never abort this wrapper — the
# wrapper's contract is "always exit 0", so a child's non-zero status (which none of them
# returns today) degrades to silence, not a broken turn.
#
# AI INSTRUCTION: Increment version on significant changes.
# Module Version: 2
#   v2 (2026-11-04): end with the repo's `# end of file` sentinel; the hygiene case over
#   tools/qwen-hooks/*.sh was red because this file stopped on code.
#   v1 (2026-10-31): first versioned form.

set -u

DIR="$(cd "$(dirname "$0")" && pwd)"

# 1. gate-status (cheapest: one `test -f`, then exit).
"$DIR/gate-status-check.sh"

# 2. guard-patch (cheap: runs the patch script's own --check).
"$DIR/guard-patch-check.sh"

# 3. memory-markdownlint (expensive: find + lint the notes changed since the last run).
"$DIR/memory-markdownlint.sh"

exit 0

# end of file
