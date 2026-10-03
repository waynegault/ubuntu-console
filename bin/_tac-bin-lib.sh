#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# _tac-bin-lib.sh — the ONE home for helpers the standalone bin/ scripts share.
# ==============================================================================
# Source by realpath so the helper resolves whether a script is reached through
# its ~/.local/bin symlink, the generated exec shim, or the repo path directly:
#
#     source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/_tac-bin-lib.sh"
#
# install.sh links bin/* into ~/.local/bin, so this companion is installed
# alongside the scripts that source it (and the realpath form finds the repo
# copy either way).
#
# This file sets NO shell options: a sourced file must not change the caller's
# errexit/pipefail/nounset, so each script keeps its own `set` line.
#
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 3
# ==============================================================================

# log — one timestamped line, parameterised so every caller keeps its EXACT
# format.  The five copies this replaced differed only in tag, date format and
# sink; those are read from variables at CALL time:
#   TAC_LOG_TAG     tag rendered as [tag]; unset/empty = no tag
#   TAC_LOG_DATE    the date(1) argument string
#                   (default: the console's '+%Y-%m-%d %H:%M:%S')
#   TAC_LOG_TO_FILE 1 = append to TAC_LOG_FILE; unset/other = stdout
#   TAC_LOG_FILE    destination when TAC_LOG_TO_FILE=1; empty = emit nothing
log() {
    local _ts _line
    _ts=$(date "${TAC_LOG_DATE:-+%Y-%m-%d %H:%M:%S}") || return 0
    if [[ -n "${TAC_LOG_TAG:-}" ]]
    then
        _line="$_ts [${TAC_LOG_TAG}] $*"
    else
        _line="$_ts $*"
    fi
    if [[ "${TAC_LOG_TO_FILE:-0}" == "1" ]]
    then
        [[ -n "${TAC_LOG_FILE:-}" ]] || return 0
        printf '%s\n' "$_line" >> "$TAC_LOG_FILE"
    else
        printf '%s\n' "$_line"
    fi
}

# _free_mib — free VRAM on the CUDA card in MiB (empty when the probe fails).
_free_mib() {
    # swallow-ok: a failing nvidia-smi leaves _free empty, and the numeric guard in the wait loop is what decides — the probe's own error adds nothing
    nvidia-smi --query-gpu=memory.total,memory.used --format=csv,noheader,nounits 2>/dev/null \
        | awk -F', *' '{print $1 - $2; exit}'
}

# _inv_gpu_lock_path — the investigator's cross-process GPU lock path.
# Precedence mirrors config/paths.gpu_lock_path() exactly; the probe that uses
# it is existence-gated because `flock -n` also fails on a missing path.
_inv_gpu_lock_path() {
    printf '%s\n' "${INVESTIGATOR_GPU_LOCK:-${INVESTIGATOR_PRODUCTION_OUTPUT:-$HOME/investigator/production}/runtime/gpu.lock}"
}

# ── CUDA-lane suspend ownership (card 7d3e7b95) ─────────────────────────────
# /dev/shm/llama-watchdog-cuda.suspend holds the CUDA lane down while a bench or
# autotune needs the card.  It used to be touch/rm with NO ownership: a run that
# aborted left it behind (lane down forever), and a run that removed one it did
# not set released ANOTHER run's hold mid-sweep.  The protocol: a run that sets
# the file records its pid in a companion "<file>.owner", refuses to start when a
# LIVE owner already holds it, and removes it only when this run owns it.
_tac_suspend_owner_file() { printf '%s.owner\n' "$1"; }

# The pid recorded for a suspend file, or empty when none/unreadable.
_tac_suspend_owner_pid() {
    local _owner
    _owner="$(_tac_suspend_owner_file "$1")"
    [[ -f "$_owner" ]] || return 0
    tr -dc '0-9' < "$_owner" 2>/dev/null   # swallow-ok: an unreadable owner file yields empty, which the callers read as "no live owner" and take over
}

# True when the recorded owner pid is still alive.
_tac_suspend_owner_alive() {
    local _pid
    _pid="$(_tac_suspend_owner_pid "$1")"
    [[ -n "$_pid" ]] || return 1
    kill -0 "$_pid" 2>/dev/null   # swallow-ok: a failed kill -0 IS the "not alive" answer the caller checks
}

# Acquire the hold: 0 = this run now owns it, 1 = a live owner holds it, 2 = the
# file/owner could not be written.  A stale file (owner gone, or an older writer
# that recorded nothing) is TAKEN OVER rather than refused, so a leftover cannot
# wedge the lane down.
_tac_suspend_acquire() {
    local _f="$1" _owner
    _owner="$(_tac_suspend_owner_file "$_f")"
    if [[ -e "$_f" ]] && _tac_suspend_owner_alive "$_f"; then
        return 1
    fi
    touch "$_f" 2>/dev/null || return 2   # swallow-ok: the failure IS reported as rc 2, which the caller turns into a refusal
    if ! printf '%s\n' "$$" > "$_owner" 2>/dev/null; then   # swallow-ok: the `if !` tests the failure and returns 2
        # An untracked hold is the bug this protocol exists to remove: drop it.
        rm -f "$_f" 2>/dev/null   # swallow-ok: best-effort drop of an untracked hold; rc 2 reports the outcome
        return 2   # 2 = could not record ownership; caller refuses to start
    fi
    return 0
}

# Release the hold ONLY when this run owns it: 0 = removed, 1 = not ours (left).
_tac_suspend_release() {
    local _f="$1" _owner
    if [[ "$(_tac_suspend_owner_pid "$_f")" != "$$" ]]; then
        return 1
    fi
    _owner="$(_tac_suspend_owner_file "$_f")"
    rm -f "$_f" "$_owner" 2>/dev/null   # swallow-ok: `rm -f` is best-effort by definition; the return below is the result
    return 0
}

# end of file
