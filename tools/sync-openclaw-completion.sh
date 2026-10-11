#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# sync-openclaw-completion.sh — Regenerate the repo-versioned OpenClaw bash
# completion script (scripts/completions/openclaw.bash).
# ==============================================================================
# Purpose: The OpenClaw CLI self-updates frequently, so the generated bash
# completion script must be refreshed to cover new subcommands. The script is
# versioned in this repo (not the tool-owned state dir) and consumed by
# 13-init.sh, making regeneration a repo operation: run this after
# `openclaw update` and commit the result.
#
# WHERE IT IS LOADED (corrected 2026-10-11): the CLI ALSO writes its own copy to
# ~/.openclaw/completions/openclaw.bash, and 13-init.sh prefers THAT one, using
# this repo copy only as the fallback for a box where the CLI has not written one.
# The preference is not cosmetic: measured 2026-10-11, this repo copy still emitted
# `tasks` (which the installed CLI no longer emits) while missing `agentmail`,
# `policy` and `storage` (which it now emits). So this regeneration keeps the
# FALLBACK current; the copy a shell normally loads is the CLI's own.
#
# Usage: tools/sync-openclaw-completion.sh
# ==============================================================================
# AI INSTRUCTION: On ANY change to this file, increment the Module Version.
# Module Version: 3
#   v3 (2026-10-11): the CLI call is BOUNDED (`timeout`, default 300 s, override
#   TAC_OC_COMPLETION_TIMEOUT).  Measured 2026-10-11: `openclaw completion` emits its
#   full output and then spends minutes in plugin teardown, so the tool hung for
#   >10 min with the finished output in its own temp file and nothing written — a
#   regeneration that can hang forever is not a regeneration.  The bound fails
#   loudly, naming rc 124.
#   v2 (2026-10-11): the header said 13-init.sh SOURCES this copy; it now prefers
#   the CLI-generated copy and falls back to this one, so the sentence was false.
#   Corrected with the measurement that shows why the preference matters.
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

# BOUNDED (v3).  The CLI emits its completion output promptly and then spends
# MINUTES in plugin teardown: measured 2026-10-11 under load, `CLI cleanup timed out:
# plugin-registration-resources after 5000ms` followed by a "forced retirement after
# 5000ms" per plugin (≈10 of them) plus a 9.2 s SQLite transaction hold.  The
# command therefore outlives its own output, and this tool — which had no bound on
# it — wedged until something outside killed it, while a complete 254 709-byte
# completion set sat in its own temp file.  Every other interop call in this repo is
# wrapped; this one now is too, and a bound that expires FAILS LOUDLY with rc 124
# rather than producing nothing.
_oc_timeout="${TAC_OC_COMPLETION_TIMEOUT:-300}"
timeout "$_oc_timeout" openclaw completion --shell bash >"$GEN" 2>"$GEN.err" || {
    _rc=$?
    echo "error: 'openclaw completion --shell bash' failed (rc=$_rc; 124 = the ${_oc_timeout}s bound expired):" >&2
    sed 's/^/  /' "$GEN.err" >&2
    exit 1
}

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
