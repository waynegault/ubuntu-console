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
# Module Version: 5
#   v5 (2026-10-11): the CUDA-suspend marker carries its holder's PID, and
#   _tac_suspend_held is the ONE rule acquirers and readers share — HELD only when
#   the marker exists, carries a numeric pid, and that pid is alive.  Before v5 the
#   pid sat in a companion file and readers tested only the marker's EXISTENCE, so a
#   holder killed with SIGKILL (its EXIT trap never runs) left the lane down for
#   hours.  The acquire write is now atomic (temp + rename in the same directory,
#   /dev/shm) because "empty" is NOT HELD and a torn write would restart the lane
#   mid-bench; release is idempotent and owner-checked.
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

# ── CUDA-lane suspend ownership (card 7d3e7b95; owner-liveness 2026-10-11) ───
# /dev/shm/llama-watchdog-cuda.suspend holds the CUDA lane down while a bench or
# autotune needs the card.
#
# v5: THE HOLDER PID LIVES IN THE SUSPEND FILE ITSELF, and liveness is decided by
# the READER through _tac_suspend_held, so acquirers and readers share ONE rule.
# Until v5 the pid sat in a companion "<file>.owner" and every READER tested only
# that the suspend FILE EXISTED — so a holder killed with SIGKILL, whose `trap …
# EXIT` therefore never ran (unlike bin/heavy-job's flock, which the kernel
# releases on death), kept the lane down until a human noticed.  Measured
# 2026-10-11: the CUDA lane was down 4h22m on a 0-byte marker whose companion
# carried the dead pid 12148.
#
# HELD means: the file EXISTS and carries a NUMERIC PID and that pid is ALIVE.
# Anything else — missing, empty, unparseable, dead owner — is NOT held, and the
# case is LOGGED, so "cannot tell" never passes silently as either answer.
# Deliberately NOT age-based: a legitimate hold lasts HOURS (the 2026-10-11 screen
# ran 4h13m), so a TTL would break a real run.  The owner's liveness is the signal.

# _tac_suspend_pid <file> — the holder pid recorded in the suspend file, or empty.
_tac_suspend_pid() {
    [[ -f "$1" ]] || return 0
    # swallow-ok: an unreadable/empty file yields empty, which every caller reads as "no owner recorded"
    tr -dc '0-9' < "$1" 2>/dev/null
}

# _tac_suspend_held <file> — 0 = HELD, 1 = not held.  THE rule, for readers too.
_tac_suspend_held() {
    local _f="$1" _pid
    if [[ ! -e "$_f" ]]
    then
        log "suspend: NOT HELD — no marker at $_f"
        return 1
    fi
    _pid="$(_tac_suspend_pid "$_f")"
    if [[ -z "$_pid" ]]
    then
        log "suspend: NOT HELD — $_f carries no numeric owner pid (legacy, empty or mid-write marker)"
        return 1
    fi
    if kill -0 "$_pid" 2>/dev/null   # swallow-ok: a failed kill -0 IS the "not alive" answer this predicate reports
    then
        log "suspend: HELD by live pid $_pid ($_f)"
        return 0
    fi
    log "suspend: NOT HELD — owner pid $_pid is dead ($_f); a killed holder cannot release its own hold"
    return 1
}

# Acquire the hold: 0 = this run now owns it, 1 = a LIVE owner holds it, 2 = the
# marker could not be written.  A stale marker — absent, legacy/empty, unparseable,
# or a DEAD owner — is TAKEN OVER rather than refused, so a leftover cannot wedge
# the lane down.
_tac_suspend_acquire() {
    local _f="$1" _tmp
    if _tac_suspend_held "$_f"; then
        return 1
    fi
    # Written to a temp file in the SAME directory (/dev/shm — one filesystem, so the
    # rename is atomic) and moved into place: a reader sees the old marker or the new
    # one, never an EMPTY one mid-write.  That matters more now than before, because
    # "empty" is NOT HELD — a torn write would let the watchdog restart the lane in
    # the microseconds an acquirer spends stamping it.
    _tmp="${_f}.tmp.$$"
    if ! printf '%s\n' "$$" > "$_tmp" 2>/dev/null   # swallow-ok: the `if !` tests the failure and reports rc 2
    then
        rm -f "$_tmp" 2>/dev/null   # swallow-ok: best-effort drop of the temp; rc 2 reports the outcome
        return 2   # 2 = the marker could not be written; the caller refuses to start
    fi
    if ! mv -f "$_tmp" "$_f" 2>/dev/null   # swallow-ok: the `if !` tests the failure and reports rc 2
    then
        rm -f "$_tmp" 2>/dev/null   # swallow-ok: best-effort drop of the temp; rc 2 reports the outcome
        return 2   # 2 = the rename could not be made; the caller refuses to start
    fi
    return 0
}

# Release the hold ONLY when this run owns it: 0 = removed, 1 = not ours (left).
# IDEMPOTENT: a second call (or one after the marker is already gone) is a no-op
# returning 1, so an EXIT trap can fire more than once without error.
_tac_suspend_release() {
    local _f="$1"
    if [[ "$(_tac_suspend_pid "$_f")" != "$$" ]]; then
        return 1
    fi
    rm -f "$_f" 2>/dev/null   # swallow-ok: `rm -f` is best-effort by definition; the return below is the result
    return 0
}

# end of file
