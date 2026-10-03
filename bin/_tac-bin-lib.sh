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
# Module Version: 1
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

# end of file
