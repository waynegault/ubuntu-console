#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# _startup-env.sh — Shared startup environment optimizations.
# ==============================================================================
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 2
#
# Single source of truth for the NODE_COMPILE_CACHE / OPENCLAW_NO_RESPAWN /
# NODE_OPTIONS startup blocks. Sourced by BOTH:
#   - tactical-console.bashrc (interactive profile)
#   - env.sh (non-interactive library loader)
# Keeping the blocks in one fragment prevents them from diverging.
#
# Underscore prefix: NOT a numbered module. Not matched by the module globs
# ([0-9][0-9]-*.sh / [0-9][0-9][a-z]-*.sh), so it is only ever sourced
# explicitly by the two loaders above.
#
# shellcheck disable=SC1090,SC1091
# ==============================================================================

# NODE_COMPILE_CACHE: Cache compiled JS for repeated CLI runs
export NODE_COMPILE_CACHE="${NODE_COMPILE_CACHE:-/var/tmp/openclaw-compile-cache}"
mkdir -p "$NODE_COMPILE_CACHE" 2>/dev/null || true

# Homebrew Node@24 — pin the specific Node version used by openclaw/gateway
# (moved here from ~/.bashrc so the loader stays thin). 13-init re-checks the
# same path for interactive shells; the guard makes this idempotent.
if [[ -d "/home/linuxbrew/.linuxbrew/opt/node@24/bin" ]] \
    && [[ ":$PATH:" != *":/home/linuxbrew/.linuxbrew/opt/node@24/bin:"* ]]
then
    export PATH="/home/linuxbrew/.linuxbrew/opt/node@24/bin:$PATH"
fi

# OPENCLAW_NO_RESPAWN: Skip self-respawn overhead
export OPENCLAW_NO_RESPAWN="${OPENCLAW_NO_RESPAWN:-1}"

# NODE_OPTIONS: Prefer IPv4 DNS — this machine has no IPv6 default route,
# causing Node.js fetch() to time out on IPv6 connection attempts.
# ${NODE_OPTIONS:-} keeps this safe under `set -u` callers (autotune-model.sh).
if [[ "${NODE_OPTIONS:-}" != *"dns-result-order"* ]]; then
    export NODE_OPTIONS="${NODE_OPTIONS:+$NODE_OPTIONS }--dns-result-order=ipv4first"
fi

# end of file
