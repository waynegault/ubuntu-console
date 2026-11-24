#!/usr/bin/env bash
# gate-status-check.sh — surface a failed store gate at the start of a turn.
#
# qwen-gate.sh writes debug/qwen-gate-FAILED on failure and removes it on a
# PASS. This hook prints the marker once per turn; it prints nothing when the
# marker is absent, so a clean store adds no context. It never blocks and never
# clears the marker itself — only a real PASS does that.
#
# AI INSTRUCTION: Increment version on significant changes.
# Module Version: 4
#   v4 (2026-11-24): name the forbidden shortcut beside the instruction. Measured the same
#   day: a peer session cleared a size-ratchet red by raising the note's allowance in
#   tests/store-budget.json instead of trimming the note, because the marker said only
#   "fix the failing case". A raise is a decision for Wayne, never a way to clear the marker.
#   v3 (2026-11-04): end with the repo's `# end of file` sentinel; the hygiene case over
#   tools/qwen-hooks/*.sh was red because this file stopped on code.
#   v2 (2026-11-01): `[ -f ]` -> `[[ -f ]]`, clearing the §18.3 6.7 rise.
#   v1 (2026-10-31): moved from a bare, unversioned file in ~/.qwen/hooks/ into
#   tools/qwen-hooks/ so it is reviewed and diffed beside the other hooks; no
#   behaviour change.

set -uo pipefail

marker="$HOME/.qwen/debug/qwen-gate-FAILED"
[[ -f "$marker" ]] || exit 0

echo "qwen-gate FAILED — the store suite is red."
sed -n '1,12p' "$marker"
echo "Fix the failing case; the next PASS removes the marker."
echo "A size or name red is fixed by trimming the note (and lowering its baseline); raising"
echo "tests/store-budget.json is Wayne's decision, never a way to clear this marker."

# end of file
