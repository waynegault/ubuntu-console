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
# Module Version: 6
#   v6 (2026-10-12): the GPU-availability mechanism moved HERE, reviewed and tested —
#   `_tac_gpu_used_mib` (multi-GPU-safe most-used reading; empty = unreadable),
#   `_tac_gpu_wait_foreign_clear` (bin/gpu-busy.sh --json, exit-code contract; excludes
#   our own fleet, so our lane's ~3.4 GiB reads free) and `_tac_gpu_wait_used_below`
#   (bounded, fails CLOSED on unreadable, ABORTS non-zero with the last reading on
#   exhaustion).  The same gate had been hand-rolled inline three times in one day,
#   each copy wrong differently (fall-through; an unsatisfiable sub-1500-MiB-before-
#   suspend precondition that polled 5.6 h; a multi-line reading that never matched on
#   a multi-GPU box).  Callers use these instead of a hand-written VRAM threshold.
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

# ── GPU availability — the ONE reviewed place for "is the card free, and for us?" ─
#
# WHY THIS EXISTS (2026-10-12).  The same GPU gate was hand-rolled inline THREE times
# in one day and every copy was wrong differently:
#   1. an EXHAUSTED wait fell through and launched into an occupied card;
#   2. a copy required the card under 1500 MiB BEFORE suspending our own lane — which
#      is unsatisfiable, because our CUDA lane legitimately holds ~3376 MiB; it polled
#      5.6 h (its log: from wait 281 the lock read `free` while the card stayed pinned
#      at 3376) and would have run nothing;
#   3. a copy tested nvidia-smi's raw MULTI-LINE output, so on a multi-GPU box the value
#      never matched and the gate could never open.
# None of that is a knowledge gap — it is three unreviewed copies of ONE mechanism.
# Running them found the bugs; review and per-copy tests did not.  So the mechanism
# lives HERE, reviewed and tested, and no caller writes a VRAM threshold by hand again.
#
# THE ORDER IS THE POINT, and it is the bug we repeated: rule out a FOREIGN holder
# FIRST (_tac_gpu_wait_foreign_clear — a lock or a VRAM number cannot see a lane that
# takes the card outside our own bookkeeping), and only THEN suspend our own lane and
# require the card to be genuinely free (_tac_gpu_wait_used_below).  Suspending first
# inverts that and produces an unsatisfiable precondition.

# _tac_gpu_used_mib — the MOST-used card's used VRAM in MiB, or EMPTY when the card
# cannot be read.  MULTI-GPU SAFE (the query prints one line per card, and a bare
# numeric test on the multi-line value never matches) and deliberately NOT silenced:
# an unreadable card is not evidence of a free one, so every caller reads empty as
# "not free" and fails closed.
_tac_gpu_used_mib() {
    # swallow-ok: the READING is the output, not the status — an nvidia-smi that fails leaves it EMPTY, and every caller treats empty as "not free" and fails closed, so its stderr adds nothing.
    nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null \
        | tr -d ' ' \
        | awk 'BEGIN{m=-1} /^[0-9]+$/{if ($1+0>m) m=$1+0} END{if (m<0) print ""; else print m}'
}

# _tac_gpu_wait_foreign_clear [timeout_s] [poll_s] — 0 when NO FOREIGN holder has the
# card, 1 when the bound expires (or the detector cannot run: fail CLOSED).
#
# The detector is bin/gpu-busy.sh, the one that already exists.  ITS INVOCATION, read
# from the tool rather than guessed: `--json` prints {"busy":…,"reasons":[…]} and the
# EXIT CODE is the contract (0 = no foreign holder, 1 = held); a BARE invocation prints
# nothing and gives only the exit code, which is why a bare call told us nothing.  It
# excludes our own fleet's servers (LLAMA_CUDA_SERVER_BIN / LLAMA_XE_SERVER_BIN,
# matched on /proc/PID/exe), so OUR lane holding ~3.4 GiB reads FREE — the distinction
# a VRAM threshold cannot make.  Override the path for a sandbox with TAC_GPU_BUSY_SH.
_tac_gpu_wait_foreign_clear() {
    local _timeout="${1:-${TAC_GPU_WAIT_TIMEOUT:-600}}" _poll="${2:-${TAC_GPU_WAIT_POLL:-5}}"
    local _sh="${TAC_GPU_BUSY_SH:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gpu-busy.sh}"
    local _waited=0 _json _rc
    while :; do
        if [[ ! -x "$_sh" ]]
        then
            log "gpu-wait: cannot run $_sh — failing CLOSED (cannot tell = not free)"
            return 1
        fi
        # swallow-ok: the EXIT CODE is the contract and is checked immediately below; stderr is not part of it, and the JSON is only the message.
        _json="$("$_sh" --json 2>/dev/null)"
        _rc=$?
        if (( _rc == 0 ))
        then
            log "gpu-wait: no foreign holder after ${_waited}s"
            return 0
        fi
        log "gpu-wait: waiting (${_waited}s): ${_json:-<no reading>}"
        if (( _waited >= _timeout ))
        then
            log "gpu-wait: EXHAUSTED after ${_waited}s — still held: ${_json:-<no reading>}; NOT proceeding"
            return 1
        fi
        sleep "$_poll"
        _waited=$(( _waited + _poll ))
    done
}

# _tac_gpu_wait_used_below <max_mib> <timeout_s> [poll_s] — 0 when the MOST-used card
# is strictly under <max_mib> MiB used, 1 otherwise.
#
# Call this ONLY AFTER our lane is suspended: the bound is chosen so it is satisfiable
# once our own ~3.4 GiB is gone (e.g. 800), and it is unsatisfiable while our lane still
# holds the card — which is exactly how the 5.6 h poll happened.
#
# An UNREADABLE card fails CLOSED immediately: the caller has already taken the hold and
# needs PROOF the card freed, so "cannot tell" must never read as "free".  Exhaustion
# returns non-zero with the LAST READING in the message — it never falls through,
# because a wait that ends by proceeding is how a run lands on an occupied card.
_tac_gpu_wait_used_below() {
    local _max="$1" _timeout="$2" _poll="${3:-2}" _used _waited=0
    while :; do
        _used="$(_tac_gpu_used_mib)"
        if [[ ! "$_used" =~ ^[0-9]+$ ]]
        then
            log "gpu-wait: cannot read used VRAM (last: '${_used:-<empty>}') after ${_waited}s — failing CLOSED"
            return 1
        fi
        if (( _used < _max ))
        then
            log "gpu-wait: card free — ${_used} MiB used < ${_max} MiB (after ${_waited}s)"
            return 0
        fi
        if (( _waited >= _timeout ))
        then
            log "gpu-wait: card did NOT free within ${_timeout}s" \
                "(last: ${_used} MiB used, need < ${_max}) — NOT proceeding"
            return 1
        fi
        sleep "$_poll"
        _waited=$(( _waited + _poll ))
    done
}

# end of file
