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
# Module Version: 13
#   v13 (2026-11-06): the nvidia-smi timeout wrappers are split at the wrapper so no
#     call sits on a line over 120 characters (18.3 counter 8.1.8).  Behaviour unchanged: the
#     continuation is whitespace inside a command substitution, so the arguments are identical.
#   v11 (2026-11-05): the VRAM BASELINE lives here, because the row script and BOTH batch
#   wrappers need it and only this file is sourced by all three (11d is a profile module
#   the wrappers do not load).  Identity comes from the PROCESS TABLE, not nvidia-smi:
#   `--query-compute-apps` prints "No running processes found" on this WSL2 box even at
#   36 GiB used (measured 2026-11-05), so a census built on it had no holders to check
#   and its identity rule was vacuous.  Adds _tac_cgroup_unit (the LEAF unit — the first
#   `.service` segment is user@1000.service), _tac_cuda_server_pids, the holder list, the
#   exclusive/census verdict, and a bounded wait.  Also adds the autotune TOMBSTONE
#   readers, so every entry point — not only the resume loop — can honour a retired row.
#   v10 (2026-11-03): _tac_suspend_release waits (bounded) for gpu-busy.sh to report no
#   foreign holder BEFORE unlinking the marker.  Measured at 22:34:13: the marker was
#   released while gpu-busy still named the just-finished autotune, so the watchdog took
#   its designed "GPU busy -> stop the serving lane" path and killed the CUDA tier seconds
#   before the card freed; the lane then waited for the next 5-minute tick.  Releasing the
#   claim is not the same event as the card going idle.  Fail-OPEN at the deadline
#   (TAC_SUSPEND_RELEASE_WAIT_S, default 30s): a marker that outlives its owner is worse
#   than one early release, and an EXIT trap must not hang a run.
#   v9 (2026-11-03): _tac_suspend_owner_is_ancestor - the row runner no longer reports a hold
#   its OWN batch takes for the whole sweep as "another run" threatening the measurement.
#   v8 (2026-11-02): a follow-up edit folded into the same unpushed commit, so the marker
#   moves again — the guard compares against HEAD, and a folded edit is a new change.  The
#   edit itself: the token parse stripped `ttl=` from `$_ttl` instead of `$_tok`, so every
#   record read MALFORMED and a refusal looked like a decision.  Behaviourally that is the
#   one line below; the test that would have caught it now asserts the REASON for a refusal,
#   not the refusal (tests/integration/04-watchdog.bats).
#   v7 (2026-11-02): the requested-stop READER.  The investigator writes
#   "requested-stop pid= start= ttl= unit= ts=" before every lane stop it asks for
#   (pipeline/gpu/_lock.py:186, called from _exclusive.py:645), and its own reader
#   (read_requested_stops) has ZERO production callers — so the console's gated-lane
#   decision consulted only gpustop_active() (ours) and gpu_claim_held() (a probe of the
#   PRESENT: the kernel drops the flock on release, so a stop taken in the claim's last
#   seconds reads as "free").  This adds _inv_requested_stop_path, _inv_proc_start_epoch,
#   requested_stop_active and requested_stop_consume.  The start-time comparison converts
#   /proc/<pid>/stat field 22 from CLOCK TICKS to the epoch the writer stored — see
#   _inv_proc_start_epoch for why getting that backwards refuses every genuine request.
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
    timeout -k 2 "${TAC_SMI_TIMEOUT:-10}" 2>/dev/null \
        nvidia-smi --query-gpu=memory.total,memory.used --format=csv,noheader,nounits \
        | awk -F', *' '{print $1 - $2; exit}'
}

# _inv_gpu_lock_path — the investigator's cross-process GPU lock path.
# Precedence mirrors config/paths.gpu_lock_path() exactly; the probe that uses
# it is existence-gated because `flock -n` also fails on a missing path.
_inv_gpu_lock_path() {
    printf '%s\n' "${INVESTIGATOR_GPU_LOCK:-${INVESTIGATOR_PRODUCTION_OUTPUT:-$HOME/investigator/production}/runtime/gpu.lock}"
}

# ── requested-stop attribution — WHO asked for a lane to go down ─────────────
# The investigator records ONE line per lane stop it requests, BEFORE its own
# `systemctl stop` (pipeline/gpu/_exclusive.py:645 records, then _stop_lane stops):
#
#   requested-stop pid=547448 start=1793592880 ttl=1793614480 \
#                  unit=llama-cuda-qwen3coder-30b-chat.service ts=1793593809
#
# It is the only instrument that names a requester AFTER the claim is gone: the kernel
# drops a flock on release, so gpu_claim_held() answers "free" from then on, and a stop
# taken inside the claim's last seconds is invisible to every probe of the PRESENT.
# Measured 2026-11-02: the guard read the flock as held at 02:46:58, it was gone by
# 02:52:11, and the stop in between could not be attributed by any console-side probe.
#
# VALID means: unit matches, `now <= ttl`, the pid is ALIVE, and its start epoch equals
# the recorded `start=` (so a recycled pid cannot inherit the line).  Anything else is
# NOT "no request was made" — it is "no longer attributable" — so every rejecting reason
# is LOGGED and the caller proceeds exactly as it did before.

# _inv_requested_stop_path — the record's path.  SAME DIRECTORY as the lock, derived
# from it rather than repeated, so one production root moves both.  The override name is
# the WRITER's (pipeline/gpu/_lock.py:59), not a console invention: a sandbox that
# relocates the lock must relocate the record with it, or the reader reads an empty
# file and every stop looks unattributed.
_inv_requested_stop_path() {
    printf '%s\n' "${INVESTIGATOR_REQUESTED_STOP:-$(dirname "$(_inv_gpu_lock_path)")/requested-stop}"
}

# _inv_proc_start_epoch <pid> — the SAME epoch `record_requested_stop` stores in
# `start=`, or EMPTY when it cannot be computed.
#
# THE UNITS ARE THE TRAP.  The writer stores process_start_epoch(), which is
# btime + (/proc/<pid>/stat field 22 in CLOCK TICKS) — i.e. EPOCH SECONDS.  Field 22 on
# its own is a tick count since boot, so comparing `start=` with field 22 directly
# compares seconds with ticks and refuses EVERY genuine request, which then reads
# exactly like "no request was made" — the failure this reader exists to end.  Convert
# the way the writer converts, including its integer division.
_inv_proc_start_epoch() {
    local _pid="$1" _stat _btime _clk _rest _ticks _k _v _ignored
    local -a _fields
    [[ "$_pid" =~ ^[0-9]+$ ]] || return 0
    read -r _stat < "/proc/$_pid/stat" || return 0   # a dead pid has no stat line; empty IS the answer
    # comm (field 2) is parenthesised and may contain spaces or ')', so count from the
    # LAST ')': the field after it is state (field 3), which makes field 22 index 19.
    _rest="${_stat##*)}"
    read -r -a _fields <<<"$_rest"
    _ticks="${_fields[19]:-}"
    _btime=""
    while read -r _k _v _ignored; do
        [[ "$_k" == "btime" ]] || continue
        _btime="$_v"
        break
    done < /proc/stat
    # swallow-ok: an unreadable CLK_TCK leaves this empty and the numeric guard below refuses; a fallback value would be a guess about the running kernel's HZ presented as a measurement
    _clk="$(getconf CLK_TCK 2>/dev/null)"
    [[ "$_ticks" =~ ^[0-9]+$ ]] || return 0
    [[ "$_btime" =~ ^[0-9]+$ ]] || return 0
    [[ "$_clk" =~ ^[0-9]+$ ]] && (( _clk > 0 )) || return 0
    printf '%s\n' "$(( _btime + _ticks / _clk ))"
}

# _inv_requested_stop_seen_path — where spent records are remembered ("<ts> <unit>").
# Beside the watchdog's other state, env-overridable so a suite can sandbox it.
_inv_requested_stop_seen_path() {
    local _dir="${LLAMA_WATCHDOG_STRIKE_DIR:-/dev/shm}"
    printf '%s\n' "${LLAMA_WATCHDOG_REQSTOP_SEEN_FILE:-$_dir/llama-watchdog.requested-stop.seen}"
}

# _requested_stop_consumed <ts> <unit> — 0 when an earlier tick already used this record.
_requested_stop_consumed() {
    local _ts="$1" _unit="${2%.service}" _f
    _f="$(_inv_requested_stop_seen_path)"
    [[ -f "$_f" ]] || return 1
    # swallow-ok: "no match" IS the not-consumed answer this predicate reports, and the file's existence is checked above, so grep's stderr carries nothing the caller can act on
    grep -qxF -- "$_ts $_unit" "$_f" 2>/dev/null
}

# requested_stop_active <unit> — 0 when a LIVE requester asked for <unit> to stop.
#
# On success it sets REQSTOP_PID and REQSTOP_TS (only on success; the caller needs both
# to log and to consume).  It writes NOTHING: a reader that mutates on read could not be
# re-run, and the falsification this function exists for is "same record, live pid →
# stamps nothing; same record, dead pid → stamps as before".
requested_stop_active() {
    local _unit="${1%.service}" _path _line _tok _newest=""
    local _pid _start _ttl _u _ts _now _actual
    local -a _toks
    _path="$(_inv_requested_stop_path)"
    [[ -f "$_path" ]] || return 1
    # Append-only, newest LAST: the last matching line is the current request.  An older
    # line for the unit cannot be newer than it, and its ttl is older too.
    while IFS= read -r _line; do
        [[ -n "${_line//[[:space:]]/}" ]] || continue
        _pid=""; _start=""; _ttl=""; _u=""; _ts=""
        read -r -a _toks <<<"$_line"
        for _tok in "${_toks[@]}"; do
            case "$_tok" in
                pid=*)   _pid="${_tok#pid=}" ;;
                start=*) _start="${_tok#start=}" ;;
                ttl=*)   _ttl="${_tok#ttl=}" ;;
                unit=*)  _u="${_tok#unit=}" ;;
                ts=*)    _ts="${_tok#ts=}" ;;
                # Anything else is prose or a field a newer writer added: the five above
                # are the whole contract, and an unknown token must not be one of them.
                *) ;;
            esac
        done
        [[ "${_u%.service}" == "$_unit" ]] || continue
        _newest="$_pid $_start $_ttl $_ts"
    done < "$_path"
    [[ -n "$_newest" ]] || return 1
    read -r _pid _start _ttl _ts <<<"$_newest"
    if [[ ! "$_pid" =~ ^[0-9]+$ || ! "$_ttl" =~ ^[0-9]+$ || ! "$_ts" =~ ^[0-9]+$ ]]
    then
        log "requested-stop: the record for ${_unit}.service is MALFORMED" \
            "(pid=${_pid:-?} ttl=${_ttl:-?} ts=${_ts:-?}) — not attributable"
        return 1
    fi
    _now="$(date +%s)"
    if (( _now > _ttl ))
    then
        log "requested-stop: the record for ${_unit}.service EXPIRED" \
            "(ttl=$_ttl, now=$_now, pid=$_pid) — not attributable"
        return 1
    fi
    if [[ -z "$_start" || "$_start" == "unknown" ]]
    then
        log "requested-stop: the record for ${_unit}.service (pid $_pid) carries NO start time" \
            "— a recycled pid could own it, so it is not attributable"
        return 1
    fi
    if ! kill -0 "$_pid" 2>/dev/null   # swallow-ok: a failed kill -0 IS the "not alive" answer this predicate reports
    then
        log "requested-stop: requester pid $_pid for ${_unit}.service is GONE — not attributable"
        return 1
    fi
    _actual="$(_inv_proc_start_epoch "$_pid")"
    if [[ "$_actual" != "$_start" ]]
    then
        log "requested-stop: pid $_pid now starts at ${_actual:-unreadable}," \
            "the record says $_start — a recycled pid, not attributable"
        return 1
    fi
    if _requested_stop_consumed "$_ts" "$_unit"
    then
        log "requested-stop: the record for ${_unit}.service (pid $_pid, ts=$_ts)" \
            "was ALREADY CONSUMED by an earlier tick — not attributed twice"
        return 1
    fi
    # Set for the CALLER, not for this file: the watchdog logs the requester and then
    # consumes the record, so the two values must survive the return.  Nothing in this
    # library reads them, which is why SC2034 has to be silenced rather than obeyed.
    # shellcheck disable=SC2034
    REQSTOP_PID="$_pid"
    # shellcheck disable=SC2034
    REQSTOP_TS="$_ts"
    return 0
}

# requested_stop_consume <ts> <unit> — mark one record spent, pruning entries older than
# a day so the file cannot grow without bound.  Consumption is what keeps the record's
# 6 h TTL from masking a GENUINE death: one request may explain exactly one restart.
requested_stop_consume() {
    local _ts="$1" _unit="${2%.service}" _f _now _kept="" _line _pts
    [[ "$_ts" =~ ^[0-9]+$ ]] || return 1
    _f="$(_inv_requested_stop_seen_path)"
    _now="$(date +%s)"
    if [[ -f "$_f" ]]; then
        while IFS= read -r _line; do
            _pts="${_line%% *}"
            [[ "$_pts" =~ ^[0-9]+$ ]] || continue
            if (( _now - _pts <= 86400 )); then _kept+="$_line"$'\n'; fi
        done < "$_f"
    fi
    _kept+="$_ts $_unit"$'\n'
    # swallow-ok: an unwritable consume file degrades to "this record may be attributed twice", which the message names; there is no action a caller could take
    printf '%s' "$_kept" > "$_f" 2>/dev/null \
        || log "WARNING: cannot write the requested-stop consume file $_f — a spent record may be attributed twice"
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

# _tac_suspend_owner_is_ancestor <file> — 0 = the recorded holder is an ANCESTOR of this
# process, 1 = no recorded holder, or a holder outside our own process tree.
#
# Why (2026-11-03): scripts/autotune-model.sh runs INSIDE bin/autotune-rows.sh, which takes
# the hold for the WHOLE sweep. The row script then fails to acquire (correctly) and used to
# report it as "held by another run ... the watchdog may restart the CUDA lane mid-run",
# naming the parent that is deliberately keeping the lane down as a foreign run that
# threatens the measurement. The hold is ours THROUGH the parent, so only a holder outside
# our own tree earns a warning. PPid is read from /proc/<pid>/status (comm can contain
# spaces, so /proc/stat field arithmetic is not safe) and the walk is bounded, so a recycled
# pid cannot loop it.
_tac_suspend_owner_is_ancestor() {
    local _f="$1" _pid _cur=$$ _hops=0
    _pid="$(_tac_suspend_pid "$_f")"
    [[ "$_pid" =~ ^[0-9]+$ ]] || return 1
    while [[ "$_cur" =~ ^[0-9]+$ ]] && (( _cur > 1 )) && (( _hops < 64 )); do
        if [[ "$_cur" == "$_pid" ]]; then return 0; fi
        # swallow-ok: an unreadable /proc entry ends the walk, which is the "not an ancestor" answer
        _cur="$(sed -n 's/^PPid:[[:space:]]*//p' "/proc/$_cur/status" 2>/dev/null)" || return 1
        _hops=$(( _hops + 1 ))
    done
    return 1
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
    # HANDOVER (2026-11-03): releasing the CLAIM is not the same event as the card going
    # idle.  Measured: at 22:34:13 the watchdog logged "suspend: NOT HELD" and, because
    # gpu-busy.sh still reported the just-finished autotune as a foreign holder, it took
    # the designed "GPU busy -> stop the serving lane" path and killed the CUDA lane
    # seconds before the card freed; the lane then stayed down until the next 5-minute
    # tick.  The marker was released while the reason for holding it was still true.
    #
    # Wait (bounded) for no foreign holder, THEN drop the marker: the next tick then sees
    # NOT HELD + free and STARTS the lane instead of stopping it.  Same detector the
    # watchdog uses (gpu-busy.sh exit contract: 0 = nothing foreign holds the card), and
    # it excludes our own fleet servers, so our own residual VRAM reads free.
    #
    # Fail-OPEN on purpose: if the card is still held at the deadline we release anyway.
    # A marker that outlives its owner is worse than one early release (the watchdog is
    # the backstop for a held card), and an EXIT trap must not be able to hang a run.
    local _sh _wait _poll _waited=0 _stuck=1
    _sh="${TAC_GPU_BUSY_SH:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gpu-busy.sh}"
    _wait="${TAC_SUSPEND_RELEASE_WAIT_S:-30}"
    _poll="${TAC_SUSPEND_RELEASE_POLL_S:-3}"
    if [[ -x "$_sh" ]]; then
        while (( _waited < _wait )); do
            if "$_sh" --json >/dev/null 2>&1; then
                _stuck=0
                break
            fi
            sleep "$_poll"
            _waited=$(( _waited + _poll ))
        done
        if (( _stuck == 1 )); then
            log "suspend-release: card still held after ${_waited}s - releasing the marker anyway (watchdog is the backstop)"
        elif (( _waited > 0 )); then
            log "suspend-release: card clear after ${_waited}s - releasing now so the watchdog can restart the lane"
        fi
    fi
    rm -f "$_f" 2>/dev/null   # swallow-ok: best-effort by definition; the return below is the result
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
    timeout -k 2 "${TAC_SMI_TIMEOUT:-10}" nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null \
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

# ── The VRAM BASELINE — who may be resident while we measure? ────────────────
#
# WHY IT LIVES HERE (2026-11-05).  The row script and BOTH batch wrappers need the
# same answer, and only this file is sourced by all three.  `scripts/11d-llm-gpu.sh`
# is a profile module the wrappers do not load.
#
# THE QUESTION IT ANSWERS.  A byte bound ("is the card empty?") cannot express a box
# with a permanent tenant: this box keeps its embedding lane (LLAMA_LANE_KEEP_UNITS),
# and driver + lane measured 4094 MiB against a 3500 MiB bound, so every autotune and
# bench aborted before its first row (2026-11-05 15:10:18; again 2026-11-04 13:23).
# Raising the bound is not the fix — it silently admits a real serving lane.  The
# census asks the actual question: WHICH processes are resident, and are they allowed?
#
# IDENTITY IS THE PROCESS TABLE, NOT nvidia-smi.  On WSL2 dxgkrnl, `nvidia-smi
# --query-compute-apps` answers "No running processes found" even at 36 GiB used
# (measured 2026-11-05), so a census built on it has no holders to check.  Every
# llama-server process is enumerated by /proc/PID/exe (a command line can be forged,
# an exe cannot), and its unit is the LEAF .service of /proc/PID/cgroup.
#
# TWO MODES:
#   exclusive (no census) — free must sit within LLM_AUTOTUNE_BASELINE_GAP_MAX of the
#     card total.  Right for a box with no resident tenant.
#   census (LLM_AUTOTUNE_CENSUS set) — every derived holder must be named, and the
#     whole-card gap must sit within LLM_AUTOTUNE_CENSUS_MAX_MIB.  A pass is
#     CONTENDED: it prints and records baseline=census, so no summary can present its
#     TPS beside a clean-room row.

# _tac_cgroup_unit <cgroup-path> — the LEAF .service in a cgroup path, or empty.
#
# The FIRST match is the wrong one: a user unit's path is
# /user.slice/user-1000.slice/user@1000.service/app.slice/llama-....service, and
# `head -1` answers user@1000.service.  Measured 2026-11-05 in a real refusal:
# "pid 242004 user@1000.service".  Pure: a string in, a unit out.
_tac_cgroup_unit() {
    local _cg="${1:-}" _u=""
    [[ -n "$_cg" ]] || return 0
    # swallow-ok: no .service segment means a non-systemd process; the census reads an empty unit as unlisted
    _u="$(printf '%s' "$_cg" | grep -o '[^/]*\.service' | tail -n 1 || true)"
    printf '%s\n' "$_u"
}

# _tac_cuda_server_pids — pids whose /proc/PID/exe names llama-server, one per line.
#
# ANY build path matches, so a foreign server from another tree is seen and can be
# refused.  Identity is the exe, never argv: `exec -a` can forge a command line and
# cannot forge /proc/PID/exe (the discriminator bin/gpu-busy.sh also uses).
_tac_cuda_server_pids() {
    local _d _exe
    for _d in /proc/[0-9]*
    do
        # swallow-ok: a process that exits mid-scan has no exe link; it cannot be named as a holder
        _exe="$(readlink -f "$_d/exe" 2>/dev/null)" || continue
        _exe="${_exe% (deleted)}"
        [[ "${_exe##*/}" == "llama-server" ]] || continue
        printf '%s\n' "${_d#/proc/}"
    done
}

# _tac_vram_holder_identities — the resident CUDA servers as `pid|unit|exe`.
#
# INJECTION SEAM (LLM_AUTOTUNE_VRAM_HOLDERS_FILE): a gate whose input cannot be
# injected cannot be tested, and a test that mocks the gate tests the mock.  When the
# file is named and readable it IS the holder list; tests drive every arm through it.
_tac_vram_holder_identities() {
    local _f="${LLM_AUTOTUNE_VRAM_HOLDERS_FILE:-}"
    if [[ -n "$_f" && -r "$_f" ]]
    then
        sed -e 's/[[:space:]]*$//' -e '/^$/d' "$_f"
        return 0
    fi
    local _p _cg _unit _exe
    while IFS= read -r _p
    do
        [[ -n "$_p" ]] || continue
        # swallow-ok: a process that exits mid-scan leaves no cgroup; the empty unit reads as unlisted
        _cg="$(ps -o cgroup= -p "$_p" 2>/dev/null)" || _cg=""
        _unit="$(_tac_cgroup_unit "$_cg")"
        # swallow-ok: the same exit leaves no exe; the empty basename is reported as unknown
        _exe="$(readlink -f "/proc/$_p/exe" 2>/dev/null)" || _exe=""
        _exe="${_exe% (deleted)}"
        printf '%s|%s|%s\n' "$_p" "$_unit" "${_exe##*/}"
    done < <(_tac_cuda_server_pids)
}

# _tac_vram_baseline_verdict <free_mib> <total_mib> — may a measurement start?
#
# @stdout key=value: mode=, verdict=pass|refuse, reason=, held_mib=, held_cap_mib=,
#         tenants=, tenant_count=, unlisted=
# @returns 0 pass, 1 refusal, 2 census misconfigured (a census with no bound is not a gate)
_tac_vram_baseline_verdict() {
    local _free="${1:-}" _total="${2:-}"
    local _gap_max="${LLM_AUTOTUNE_BASELINE_GAP_MAX:-800}"
    local _census="${LLM_AUTOTUNE_CENSUS:-}"
    local _cap="${LLM_AUTOTUNE_CENSUS_MAX_MIB:-}"
    local _gap _pid _unit _exe _t _matched _count _unlisted _holders
    if ! [[ "$_free" =~ ^[0-9]+$ && "$_total" =~ ^[0-9]+$ ]]
    then
        printf 'mode=unknown\nverdict=refuse\nreason=unreadable-vram\n'
        return 1
    fi
    # A free reading ABOVE the total is not a clean card; it is a card we cannot read.
    if (( _free > _total ))
    then
        printf 'mode=unknown\nverdict=refuse\nreason=free-exceeds-total\n'
        return 1
    fi
    _gap=$(( _total - _free ))
    if [[ -z "$_census" ]]
    then
        printf 'mode=exclusive\nheld_mib=%s\nheld_cap_mib=%s\n' "$_gap" "$_gap_max"
        if (( _gap > _gap_max ))
        then
            printf 'verdict=refuse\nreason=gap-exceeds-bound\n'
            return 1
        fi
        printf 'verdict=pass\n'
        return 0
    fi
    if ! [[ "$_cap" =~ ^[0-9]+$ ]] || (( _cap <= 0 ))
    then
        printf 'mode=census\nheld_mib=%s\nverdict=refuse\nreason=census-unbounded\n' "$_gap"
        return 2  # 2 = a census with no bound is not a gate
    fi
    _holders="$(_tac_vram_holder_identities)"
    _count=0
    _unlisted=""
    while IFS='|' read -r _pid _unit _exe
    do
        [[ -n "${_pid:-}" ]] || continue
        _count=$(( _count + 1 ))
        _matched=0
        for _t in $_census
        do
            if [[ -n "$_unit" && "$_unit" == "$_t" ]] || [[ -n "$_exe" && "$_exe" == "$_t" ]]
            then
                _matched=1
                break
            fi
        done
        (( _matched )) || _unlisted+="${_pid}:${_unit:-no-unit}:${_exe:-unknown} "
    done <<< "$_holders"
    printf 'mode=census\ntenants=%s\ntenant_count=%s\nheld_mib=%s\nheld_cap_mib=%s\n' \
        "$_census" "$_count" "$_gap" "$_cap"
    if [[ -n "$_unlisted" ]]
    then
        printf 'verdict=refuse\nreason=unlisted-holder\nunlisted=%s\n' "${_unlisted% }"
        return 1
    fi
    if (( _gap > _cap ))
    then
        printf 'verdict=refuse\nreason=held-exceeds-census-cap\n'
        return 1
    fi
    printf 'verdict=pass\n'
    return 0
}

# _tac_gpu_wait_baseline [timeout_s] [poll_s] — bounded wait for a PASSING verdict.
#
# 0 = the baseline cleared; 1 = it did not (an unreadable card fails CLOSED); 2 = the
# census is misconfigured.  Prints the last verdict on stdout so the caller can log WHY
# instead of only "the card did not free".
_tac_gpu_wait_baseline() {
    local _timeout="${1:-90}" _poll="${2:-2}" _waited=0 _free _total _verdict _rc
    while :; do
        # swallow-ok: an unreadable card yields empty, and the verdict refuses on a non-numeric reading
        _free="$(timeout -k 2 "${TAC_SMI_TIMEOUT:-10}" 2>/dev/null \
            nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | head -1 | tr -d ' ')"
        # swallow-ok: same reading, other field; the verdict fails closed on either being unreadable
        _total="$(timeout -k 2 "${TAC_SMI_TIMEOUT:-10}" 2>/dev/null \
            nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1 | tr -d ' ')"
        _verdict="$(_tac_vram_baseline_verdict "$_free" "$_total")"
        _rc=$?
        case "$_rc" in
            0)
                printf '%s\n' "$_verdict"
                log "gpu-wait: baseline cleared after ${_waited}s"
                return 0
                ;;
            2)
                printf '%s\n' "$_verdict"
                log "gpu-wait: the census is MISCONFIGURED — not proceeding"
                return 2  # 2 = a census with no bound is not a gate
                ;;
            *)
                # 1 (a refusal) is not terminal: the holder may exit, so keep waiting
                # until the bound.  Every other code is treated the same way, and the
                # exhaustion below prints the last verdict.
                ;;
        esac
        if (( _waited >= _timeout ))
        then
            printf '%s\n' "$_verdict"
            log "gpu-wait: baseline NOT cleared after ${_waited}s — NOT proceeding"
            return 1
        fi
        sleep "$_poll"
        _waited=$(( _waited + _poll ))
    done
}

# ── The autotune TOMBSTONE — a retired row is not owed, at EVERY entry point ──
#
# The resume loop applies this to its own derivation, but `run-autotune-batch.sh`
# (no args) and `autotune-rows.sh --all-but-done` re-selected the retired rows from
# the registry.  Measured 2026-11-04/05: one row's weights had moved to archived/ and
# the other is the 88 GiB artefact that OOM-killed at staging.
#
# _tac_autotune_retired_file — the tombstone path; TAC_RESUME_RETIRED wins.
_tac_autotune_retired_file() {
    local _state="${TAC_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/tactical-console}"
    printf '%s\n' "${TAC_RESUME_RETIRED:-$_state/autotune-retired.rows}"
}

# _tac_is_retired <model-file> — 0 when the tombstone lists it (first field, before `|`).
_tac_is_retired() {
    local _f="${1:-}" _list
    [[ -n "$_f" ]] || return 1
    _list="$(_tac_autotune_retired_file)"
    [[ -r "$_list" ]] || return 1
    awk -F'|' -v f="$_f" '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        $1 == f { found = 1; exit }
        END { exit(found ? 0 : 1) }
    ' "$_list"
}

# end of file
