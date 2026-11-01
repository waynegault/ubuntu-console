#!/usr/bin/env bash
# gate-status-check.sh — surface a failed store gate at the start of a turn.
#
# qwen-gate.sh writes debug/qwen-gate-FAILED on failure and removes it on a
# PASS. This hook prints the marker once per turn; it prints nothing when the
# marker is absent, so a clean store adds no context. It never blocks and never
# clears the marker itself — only a real PASS does that.
#
# AI INSTRUCTION: Increment version on significant changes.
# Module Version: 1
#   v1 (2026-10-31): moved from a bare, unversioned file in ~/.qwen/hooks/ into
#   tools/qwen-hooks/ so it is reviewed and diffed beside the other hooks; no
#   behaviour change.

set -uo pipefail

marker="$HOME/.qwen/debug/qwen-gate-FAILED"
[ -f "$marker" ] || exit 0

echo "qwen-gate FAILED — the store suite is red."
sed -n '1,12p' "$marker"
echo "Fix the failing case; the next PASS removes the marker."
