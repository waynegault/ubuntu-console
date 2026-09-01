#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# sync-openclaw-completion.sh — Regenerate the repo-versioned OpenClaw bash
# completion script (scripts/completions/openclaw.bash).
# ==============================================================================
# Purpose: The OpenClaw CLI self-updates frequently, so the generated bash
# completion script must be refreshed to cover new subcommands. The script is
# versioned in this repo (not the tool-owned state dir) and sourced by
# 13-init.sh, making regeneration a repo operation: run this after
# `openclaw update` and commit the result.
#
# Usage: tools/sync-openclaw-completion.sh
# ==============================================================================
# AI INSTRUCTION: On ANY change to this file, increment the Module Version.
# Module Version: 1
# ==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$REPO_ROOT/scripts/completions/openclaw.bash"
GEN="$(mktemp)"
FINAL="$(mktemp)"
trap 'rm -f "$GEN" "$GEN.err" "$FINAL"' EXIT

if ! command -v openclaw >/dev/null 2>&1; then
    echo "error: openclaw not found on PATH — cannot regenerate completions" >&2
    exit 1
fi

if ! openclaw completion --shell bash >"$GEN" 2>"$GEN.err"; then
    echo "error: 'openclaw completion --shell bash' failed:" >&2
    sed 's/^/  /' "$GEN.err" >&2
    exit 1
fi

if [[ ! -s "$GEN" ]]; then
    echo "error: openclaw produced empty completion output" >&2
    exit 1
fi

mkdir -p "$(dirname "$OUT")"
{
    cat <<'HEADER'
# ==============================================================================
# OpenClaw bash completions — GENERATED FILE, do not edit by hand.
# Regenerate with: tools/sync-openclaw-completion.sh
# Source: `openclaw completion --shell bash`
# ==============================================================================
HEADER
    cat "$GEN"
} >"$FINAL"

if [[ -f "$OUT" ]] && cmp -s "$FINAL" "$OUT"; then
    echo "Unchanged: $OUT ($(wc -l < "$OUT") lines)"
else
    cp "$FINAL" "$OUT"
    echo "Wrote $OUT ($(wc -l < "$OUT") lines)"
fi

exit 0

# end of file
