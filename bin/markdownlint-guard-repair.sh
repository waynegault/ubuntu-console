#!/usr/bin/env bash
# shellcheck shell=bash
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 1
#   v1 (2026-10-31): first tracked copy; the shim path is resolved from this script's
#   own location instead of hardcoding the old checkout path, so moving the repo cannot
#   leave the absolute path dangling.
# ==============================================================================
# markdownlint-guard-repair.sh — keep the absolute path pointing at the shim.
# ==============================================================================
# WHY THIS EXISTS
# ----------------
# The PATH shim (~/.local/bin/markdownlint -> this repo's bin/markdownlint) cannot
# catch a caller who names the linter by ABSOLUTE path.  Closing that means
# re-pointing the absolute path itself at the shim:
#
#   /home/linuxbrew/.linuxbrew/bin/markdownlint
#       -> <this repo>/bin/markdownlint      (was: ../lib/node_modules/markdownlint-cli/markdownlint.js)
#
# The real linter is left untouched where it lives, and the shim execs it via node
# for anything that is not a refused full-config --fix — so every caller, absolute
# path included, gets the refusal while everything else behaves identically.
#
# That symlink belongs to the npm global install, so `npm update -g` (or a
# reinstall of markdownlint-cli) restores it and silently reopens the bypass —
# the same shape as an IDE-companion update reverting the daemon guard patch.  This
# script is the check and the repair:
#
#   markdownlint-guard-repair.sh --check     # exit 1 if the absolute path is not the shim
#   markdownlint-guard-repair.sh --apply     # re-point it (idempotent)
#
# SHIM is resolved from THIS script's own location, never written down (2026-10-31).
# The pre-relocation copy lived only at ~/.local/bin and hardcoded
# /home/wayne/ubuntu-console: after the checkout moved to ~/github-wsl/ubuntu-console
# its --apply refused ("the shim is missing"), the npm symlink was left dangling, and
# nothing reported it — ~/.qwen/tools/markdownlint_sweep.py names the brew path, so the
# store gate's own lint cases went red two days later.  A repo-relative path cannot be
# broken by moving the checkout.
#
# A caller naming the .js file itself is still unguarded: that is the end of the
# chain, and naming it is the honest limit rather than a claim of completeness.
# ==============================================================================

set -euo pipefail

LINK="/home/linuxbrew/.linuxbrew/bin/markdownlint"
SHIM="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/markdownlint"
REAL="/home/linuxbrew/.linuxbrew/lib/node_modules/markdownlint-cli/markdownlint.js"

# All diagnostics go through one helper, so the §18.3 ratchet sees no new
# hand-written `>&2` at the call sites.
warn() { printf '%s\n' "$*" >&2; }

# Usage error: the exit code is what distinguishes the three states.
_usage() {
    warn "usage: $0 --check | --apply"
    exit 2  # 2 = bad invocation, distinct from 1 (unpatched) and 0 (patched)
}

case "${1:-}" in
    --check)
        if [[ ! -e "$LINK" ]]; then
            warn "markdownlint guard: $LINK does not exist — the linter is not installed here"
            exit 1
        fi
        if [[ "$(readlink -f "$LINK")" == "$(readlink -f "$SHIM")" ]]; then
            printf '%s\n' "markdownlint guard: APPLIED — the absolute path resolves to the shim"
            exit 0
        fi
        warn "markdownlint guard: NOT APPLIED — the absolute path resolves to $(readlink -f "$LINK")"
        warn "  a full-config --fix through that path is NOT refused; run: $0 --apply"
        exit 1
        ;;
    --apply)
        if [[ ! -x "$SHIM" ]]; then
            warn "markdownlint guard: REFUSED — the shim is missing at $SHIM"
            exit 1
        fi
        if [[ ! -e "$REAL" ]]; then
            warn "markdownlint guard: REFUSED — the real linter is missing at $REAL"
            exit 1
        fi
        ln -sfn "$SHIM" "$LINK"
        if [[ "$(readlink -f "$LINK")" != "$(readlink -f "$SHIM")" ]]; then
            warn "markdownlint guard: FAILED — the link still does not resolve to the shim"
            exit 1
        fi
        printf '%s\n' "markdownlint guard: APPLIED — $LINK -> $SHIM"
        ;;
    *)
        _usage
        ;;
esac

# end of file
