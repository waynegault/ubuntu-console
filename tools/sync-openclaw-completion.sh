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
# Module Version: 4
#   v4 (2026-10-11, Wayne's decision): ONE capture, TWO writes.  The tool wrote only
#   the repo fallback, while scripts/13-init.sh PREFERS the CLI's own copy in
#   ~/.openclaw/completions — which the CLI rewrites only on update, so it lagged
#   (Oct 9 / 74 tokens) behind a fresh capture (80).  Both are now written from the
#   single capture: the preferred copy BARE (matching the shape the CLI itself
#   writes there — no header), the fallback with its GENERATED header.  Each write
#   goes to a temp file in the destination's directory and is renamed, so a partial
#   or failed capture cannot break either copy, and idempotence is per path.
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
# The loader (scripts/13-init.sh) prefers the CLI's OWN copy and falls back to the
# repo-versioned one, so BOTH are written from the ONE capture below.  Writing only
# the fallback left the preferred copy to lag until the CLI next updated it
# (measured 2026-10-11: preferred Oct 9 / 74 tokens against a fresh capture of 80).
REPO_OUT="$REPO_ROOT/scripts/completions/openclaw.bash"
STATE_OUT="$HOME/.openclaw/completions/openclaw.bash"
GEN="$(mktemp)"
GEN_ERR="$GEN.err"
trap 'rm -f "$GEN" "$GEN_ERR"' EXIT

# warn — the ONE place this tool writes to stderr.  §18.3 item 10.7 counts each
# ad-hoc `echo/printf … >&2` site separately; routing them through here keeps the
# stream and the prefix in one place.  The redirect sits on the closing brace, so
# this definition is not itself counted as a site (the counter matches echo/printf
# and `>&2` on the same line).
warn() {
    {
        printf 'error: %s\n' "$*"
    } >&2
}

if ! command -v openclaw >/dev/null 2>&1; then
    warn "openclaw not found on PATH — cannot regenerate completions"
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
#
# ONE capture, TWO writes (v4): the CLI is invoked exactly once — a second capture
# would double both the cost and the teardown risk this bound exists for.
_oc_timeout="${TAC_OC_COMPLETION_TIMEOUT:-300}"
timeout "$_oc_timeout" openclaw completion --shell bash >"$GEN" 2>"$GEN_ERR" || {
    _rc=$?
    warn "'openclaw completion --shell bash' failed (rc=$_rc; 124 = the ${_oc_timeout}s bound expired):"
    sed 's/^/  /' "$GEN_ERR" >&2
    exit 1
}

if [[ ! -s "$GEN" ]]; then
    warn "openclaw produced empty completion output"
    exit 1
fi

# _tac_emit_completion <destination> <bare|headered>
#
#   bare     — the capture verbatim.  This is the SHAPE THE CLI ITSELF WRITES to
#              ~/.openclaw/completions (read 2026-10-11: no header, and it opens
#              with a blank line before `_openclaw_completion() {`).  The format of
#              the copy the loader PREFERS is not ours to change, and a header here
#              would be transient anyway — the CLI's next update-derived write would
#              drop it, leaving the file's shape dependent on which writer ran last.
#   headered — the repo fallback, which carries the 5-line GENERATED header the tool
#              has always emitted (the blank line after it is the capture's own).
#
# Written to a temp file IN THE DESTINATION'S DIRECTORY and renamed, so a partial or
# failed write can never leave either copy broken — the same rule the vault-bridge
# write follows, and the reason the temp is not in /tmp (a cross-filesystem mv is not
# atomic).
_tac_emit_completion() {
    local _dst="$1" _mode="$2" _tmp
    mkdir -p "$(dirname "$_dst")" || return 1
    _tmp="$(mktemp "$(dirname "$_dst")/.oc-completion.XXXXXX")" || return 1
    if [[ "$_mode" == "headered" ]]
    then
        cat <<'HEADER' >"$_tmp"
# ==============================================================================
# OpenClaw bash completions — GENERATED FILE, do not edit by hand.
# Regenerate with: tools/sync-openclaw-completion.sh
# Source: `openclaw completion --shell bash`
# ==============================================================================
HEADER
    fi
    cat "$GEN" >>"$_tmp"
    if [[ -f "$_dst" ]] && cmp -s "$_tmp" "$_dst"
    then
        rm -f "$_tmp"
        echo "Unchanged: $_dst ($(wc -l < "$_dst") lines)"
        return 0
    fi
    chmod 644 "$_tmp"
    if ! mv -f "$_tmp" "$_dst"   # swallow-ok: the `if !` tests the failure, reports it and clears the temp
    then
        rm -f "$_tmp"
        warn "could not replace $_dst"
        return 1
    fi
    echo "Wrote: $_dst ($(wc -l < "$_dst") lines)"
    return 0
}

_oc_ok=0
_tac_emit_completion "$STATE_OUT" bare || _oc_ok=1
_tac_emit_completion "$REPO_OUT" headered || _oc_ok=1
exit "$_oc_ok"

# end of file
