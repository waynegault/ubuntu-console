#!/usr/bin/env bash
# llama-lane-arbiter.sh — THE one place a CUDA lane start is allowed or refused.
#
# CARD: GPU-LANE-ARBITRATION-001 (a946d421)
#
# THE DEFECT (measured 2026-11-04 00:36-00:52Z, ProArt-P16):
#   /dev/shm/llama-watchdog-cuda.suspend held live pid 3998 (a 70B autotune row). The
#   watchdog honoured it twice — 00:36:02 and 00:41:03 "CUDA lane suspended — held by
#   live pid 3998; not starting llama-cuda-qwen3coder-30b-chat". At 00:42:59 the unit
#   was STARTED ANYWAY, with no watchdog line and nothing in scripts/, bin/ or
#   workspace/scripts/ issuing it. At 00:46:03 the watchdog enforced the hold and
#   SIGKILLed the server mid-prompt (45,056 tokens, 140 s in); four agent sessions lost
#   the turn and the fleet ran on a cloud fallback.
#
#   Two controllers with opposite intentions, no arbitration, and the loser is every
#   in-flight turn. The hold was legitimate; the defect is the second controller.
#
# WHY THIS IS AN ExecCondition ON THE UNIT, NOT ANOTHER CHECK IN THE WATCHDOG:
#   A check in the watchdog arbitrates exactly the starts the watchdog issues. The
#   start at 00:42:59 came from somewhere else, and systemd does not log the caller,
#   so a second check would have been as blind as the first. Putting the rule in the
#   unit's own start transaction means EVERY path — an agent's `systemctl --user
#   start`, a script, a timer, the guard, systemd's own Restart=, a dependency —
#   passes through one decision point, and none of them can be the exception.
#
#   ExecCondition (not ExecStartPre) because a refusal is not a fault: measured on
#   systemd 259 (throwaway unit, 2026-11-10), exit 78 produced
#       "Skipped due to 'exec-condition'. Condition check resulted in ... being skipped."
#   with ActiveState=inactive, Result=success and NRestarts=0 — no failure state, no
#   Restart=always storm, and the lane never allocates VRAM or loads a model. An
#   ExecStartPre refusal would have marked the unit failed and re-run every RestartSec.
#
# THE RULE IS NOT RE-IMPLEMENTED HERE. _tac_suspend_held (bin/_tac-bin-lib.sh) is the
#   one definition acquirers and readers already share: HELD means the marker exists,
#   carries a numeric pid, and that pid is alive. A stale marker (dead holder) is NOT
#   held, so this cannot wedge the lane down for hours the way the 2026-10-11 4h22m
#   outage did.
#
# SCOPE: the marker governs the CUDA CHAT lane (LLAMA_CUDA_LANE_UNIT from the host
#   profile). The embedding lane is deliberately OUT of scope: LLAMA_LANE_KEEP_UNITS
#   keeps it resident through a VRAM drain, so refusing its restart while a bench holds
#   the card would take memory search down for the length of the bench — a different
#   subsystem broken to protect a measurement. Override with LLAMA_LANE_ARBITER_SCOPE
#   (space-separated unit names) when a host wants a wider or narrower hold.
#
# REQUESTER ATTRIBUTION (the card's second requirement): systemd records no caller, so
#   a refusal has to say WHO asked. This reads the live client out of /proc: the
#   process whose argv names the unit with a start verb, plus its cwd and its ancestor
#   chain. That is the requesting shell, agent or script by name, not a guess. Callers
#   that go through `start` below may also declare themselves with LLAMA_LANE_REQUESTER,
#   which is recorded verbatim. When nothing can be resolved the line says UNRESOLVED
#   and prints the systemd invocation id — an honest "cannot tell" rather than a name.
#
# USAGE
#   llama-lane-arbiter.sh check <unit>          exit 0 = may start, 78 = refused
#   llama-lane-arbiter.sh start <unit> [reason] attribute, check, then systemctl start
#   llama-lane-arbiter.sh scope <unit>          print in-scope / out-of-scope
#
# AI INSTRUCTION: Increment version on significant changes.
# Module Version: 1

set -uo pipefail

_BIN_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd "$(dirname "$_BIN_PATH")/.." && pwd)"

TAC_LOG_TAG="lane-arbiter"
export TAC_LOG_TAG
# shellcheck source=_tac-bin-lib.sh
source "$REPO_ROOT/bin/_tac-bin-lib.sh"

SUSPEND_FILE="${LLAMA_WATCHDOG_CUDA_SUSPEND_FILE:-/dev/shm/llama-watchdog-cuda.suspend}"
# 78 is EX_CONFIG in sysexits(3) and is what the unit's ExecCondition treats as "skip".
REFUSED_RC=78
# Three candidates is enough to name a caller and its wrapper without printing the box.
MAX_CANDIDATES=3

# warn — this tool's ONE stderr path, so every degradation has the same shape (§18.3 10.7).
warn() { printf 'llama-lane-arbiter: %s\n' "$*" >&2; }

# _usage — print the USAGE block from this file's own header, then exit 64 (EX_USAGE).
_usage() {
    sed -n '/^# USAGE$/,/^# AI INSTRUCTION/p' "$_BIN_PATH" | sed 's/^# \{0,1\}//' >&2
    # 64 is EX_USAGE: the caller asked for something this tool cannot parse.
    exit 64
}

# _proc_cmdline — a pid's argv with NULs shown as spaces, so a match is readable in a report.
# swallow-ok: a pid that exited between the scan and this read has no cmdline; empty is the answer, not an error
_proc_cmdline() { tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null; }
# _proc_comm — a pid's short command name (the name ps and the cgroup would agree on).
# swallow-ok: a vanished pid has no comm; the caller renders an unknown name rather than failing
_proc_comm() { cat "/proc/$1/comm" 2>/dev/null; }
# _proc_ppid — a pid's parent id, read from /proc/PID/status (no `ps` dependency).
# swallow-ok: a vanished pid has no status; the chain simply ends at the last live hop
_proc_ppid() { sed -n 's/^PPid:[[:space:]]*//p' "/proc/$1/status" 2>/dev/null; }

# _chain <pid> — "pid(comm)<-pid(comm)<-..." up to six hops. The parent chain is what
# turns a bare `systemctl` into the shell or agent that ran it.
_chain() {
    local _p="$1" _hops=0 _out=""
    while [[ "$_p" =~ ^[0-9]+$ ]] && (( _p > 1 )) && (( _hops < 6 )); do
        _out+="${_out:+<-}$_p($(_proc_comm "$_p"))"
        _p="$(_proc_ppid "$_p")"
        _hops=$(( _hops + 1 ))
    done
    printf '%s' "$_out"
}

# _self_tree — our own ancestors. Excluded from the scan: this script's own argv names
# the unit (that is the argument), and it is not the requester.
_self_tree() {
    local _p="$$" _hops=0
    while [[ "$_p" =~ ^[0-9]+$ ]] && (( _p > 1 )) && (( _hops < 32 )); do
        printf '%s\n' "$_p"
        _p="$(_proc_ppid "$_p")"
        _hops=$(( _hops + 1 ))
    done
}

# _requester <unit-basename> — one line naming who asked, or an honest UNRESOLVED.
_requester() {
    local _base="$1" _self _p _cmd _cwd _n=0 _found=""
    if [[ -n "${LLAMA_LANE_REQUESTER:-}" ]]; then
        printf 'requester=%s pid=%s chain=%s' "$LLAMA_LANE_REQUESTER" "$$" "$(_chain "$$")"
        return 0
    fi
    _self=" $(_self_tree | tr '\n' ' ') "
    for _p in /proc/[0-9]*; do
        _p="${_p#/proc/}"
        [[ "$_self" == *" $_p "* ]] && continue
        _cmd="$(_proc_cmdline "$_p")"
        [[ -n "$_cmd" ]] || continue
        [[ "$_cmd" == *"$_base"* ]] || continue
        # A START verb, so a process that merely NAMES the unit (a log tail, a grep, this
        # script's own check) is not attributed. The same rule bin/gpu-busy.sh uses.
        [[ "$_cmd" =~ (^|[[:space:]])(start|restart|try-restart|reload-or-restart)([[:space:]]|$) ]] || continue
        # A process that exited since the scan has no cwd; "unknown" is a weaker claim, never a wrong one.
        # swallow-ok: empty cwd is rendered as unreadable by the line below, not treated as a match
        _cwd="$(readlink "/proc/$_p/cwd" 2>/dev/null)"
        _found+="pid=${_p} argv='${_cmd% }' cwd=${_cwd:-unreadable} chain=$(_chain "$_p"); "
        _n=$(( _n + 1 ))
        (( _n >= MAX_CANDIDATES )) && break
    done
    if [[ -n "$_found" ]]; then
        printf 'requester=%s' "$_found"
    else
        printf 'requester=UNRESOLVED (no live process names %s with a start verb; systemd invocation %s)' \
            "$_base" "${INVOCATION_ID:-unknown}"
    fi
}

# _scope_units — the units this marker governs, from the host profile.
_scope_units() {
    if [[ -n "${LLAMA_LANE_ARBITER_SCOPE:-}" ]]; then
        printf '%s' "$LLAMA_LANE_ARBITER_SCOPE"
        return 0
    fi
    # shellcheck source=../tools/host-profile.sh
    source "$REPO_ROOT/tools/host-profile.sh"
    # A profile that cannot be applied leaves the scope empty, and an empty scope matches no
    # unit — the arbiter would then allow every start it exists to refuse.  The failure is
    # REPORTED rather than swallowed; the caller still sees the empty scope, so this line
    # changes no decision, only whether the operator hears about it.
    if ! tac_host_profile_apply >/dev/null 2>&1; then
        warn "host profile did not apply — the scope may be empty, so nothing is held"
    fi
    printf '%s' "${LLAMA_CUDA_LANE_UNIT:-}"
}

# _in_scope <unit-basename> — 0 = this unit is held by the marker.
_in_scope() {
    local _unit="${1%.service}" _s
    for _s in $(_scope_units); do
        [[ "${_s%.service}" == "$_unit" ]] && return 0
    done
    # Profile unresolved (no match, two matches, unknown override): the marker's own
    # documented meaning is the CUDA CHAT lane, so hold that and nothing else. Refusing
    # every CUDA unit on an unreadable profile would take the embedding lane down with it.
    if [[ -z "$(_scope_units)" && "$_unit" == llama-cuda-*-chat ]]; then
        return 0
    fi
    return 1
}

# check <unit> — the arbitration decision. 0 = may start, 78 = refused (journalled).
check() {
    local _unit="${1%.service}" _pid
    if ! _in_scope "$_unit"; then
        log "ALLOWED start of $_unit — not in the CUDA-suspend scope [$(_scope_units)]"
        return 0
    fi
    # THE rule, shared with the acquirers and every other reader. It logs its own
    # "suspend: HELD/NOT HELD" line, which is the reason a refusal is legible later.
    if ! _tac_suspend_held "$SUSPEND_FILE"; then
        log "ALLOWED start of $_unit — no live suspend holder at $SUSPEND_FILE"
        return 0
    fi
    _pid="$(_tac_suspend_pid "$SUSPEND_FILE")"
    log "REFUSED start of $_unit — $SUSPEND_FILE is HELD by live pid $_pid ($(_proc_comm "$_pid"));" \
        "$(_requester "$_unit")"
    return "$REFUSED_RC"
}

# start <unit> [reason] — the sanctioned path for agents and scripts. It declares the
# requester BEFORE asking, so even a start that systemd then skips is attributable.
start() {
    local _unit="${1%.service}" _reason="${2:-}" _rc
    log "REQUESTED start of $_unit — $(_requester "$_unit")${_reason:+ — reason: $_reason}"
    check "$_unit"
    _rc=$?
    (( _rc == 0 )) || return "$_rc"
    systemctl --user start "$_unit.service"
    _rc=$?
    if (( _rc != 0 )); then
        log "start of $_unit FAILED (systemctl rc=$_rc) — the unit's own journal has the reason"
        return "$_rc"
    fi
    # Deliberately not "started": the unit's ExecCondition arbitrated again a moment
    # later, and a skipped unit returns 0 from systemctl. The journal is the record.
    log "ISSUED start of $_unit (ExecCondition on the unit re-arbitrated it)"
    return 0
}

case "${1:-}" in
    check)
        [[ $# -ge 2 ]] || _usage
        check "$2"
        ;;
    start)
        [[ $# -ge 2 ]] || _usage
        shift
        start "$@"
        ;;
    scope)
        [[ $# -ge 2 ]] || _usage
        if _in_scope "$2"; then echo in-scope; else echo out-of-scope; fi
        ;;
    *)
        _usage
        ;;
esac

# end of file
