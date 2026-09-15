#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# _startup-env.sh — Shared startup environment optimizations.
# ==============================================================================
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 5
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
# shellcheck disable=SC1090  # __tac_source_submodules sources sub-modules by name (non-constant path)
# ==============================================================================

# __tac_source_submodules <dir> <label> <name...> — Source a thin loader's
# sub-modules in order, one level deep. Reports a missing file AND a file that
# exists but fails to source, so a broken sub-module never loads silently.
# Shared by the 09-openclaw and 11-llm-manager thin loaders so their loops
# cannot drift. (SC1090 — a dynamic source path — is covered by the file-level
# disable above; no per-line suppression is needed.)
#
# Failures are also COUNTED into __TAC_SUBMODULE_FAILURES (deliberately not
# `local`, so it survives this function): the loader keeps going — a broken
# sub-module must not lock you out of a shell — but callers that can act on it
# (env.sh, autotune-model.sh) need a signal. Before this counter existed, a
# half-loaded console was visible only as stderr lines: on 2026-09-13 a sweep
# "completed" ten rows against a console whose llm-manager helpers never loaded.
function __tac_source_submodules() {
    local _dir="$1" _label="$2"
    shift 2
    local _name _file _rc
    for _name in "$@"
    do
        _file="$_dir/${_name}.sh"
        if [[ ! -f "$_file" ]]
        then
            printf '%s\n' "[tac] ${_label}: missing sub-module $_file" >&2
            __TAC_SUBMODULE_FAILURES=$(( ${__TAC_SUBMODULE_FAILURES:-0} + 1 ))
            continue
        fi
        _rc=0
        source "$_file" || _rc=$?
        if (( _rc != 0 ))
        then
            printf '%s\n' "[tac] ${_label}: sub-module $_file failed to load (rc=$_rc)" >&2
            __TAC_SUBMODULE_FAILURES=$(( ${__TAC_SUBMODULE_FAILURES:-0} + 1 ))
            if [[ -n "${ErrorLogPath:-}" ]]
            then
                echo "$(date +'%Y-%m-%d %H:%M:%S') [SOURCE-FAILED] $_file rc=$_rc" >> "$ErrorLogPath" 2>/dev/null
            fi
        fi
    done
}

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
