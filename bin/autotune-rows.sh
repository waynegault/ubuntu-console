#!/usr/bin/env bash
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 16
#   v14 (2026-11-06, Wayne): CLEAN-ROOM. The declared census tenants (the embed
#   lane) are stopped for the sweep and restored on EXIT, so the baseline is a
#   clean card and the TPS are not contended by construction.
#   AUTOTUNE_CLEAN_ROOM=0 opts out and says so in the log.
#   v13 (2026-11-05): the pre-flight asks the SHARED baseline verdict, not a byte
#   threshold.  The 3500 MiB wait was unsatisfiable on this box: the kept embedding
#   lane's 4094 MiB gap exceeds it, so every batch aborted before row one (measured
#   15:10:18 and 2026-11-04 13:23).  Census mode names the tenants that may be
#   resident and caps the hold; no census = the exclusive bound unchanged.  The
#   derived scopes also apply the autotune TOMBSTONE now, so --all-but-done can no
#   longer re-select the archived 70B or the 88 GiB artefact (explicit files still
#   pass; TAC_RESUME_INCLUDE_RETIRED=1 is the override).
#   v11 (2026-11-03): a DIRECT run asks the quiet-fleet gate too. The gate only ever guarded
#   the boot/resume path, so a hand-started sweep reached the card ungated (measured 22:07 that
#   day, launched from a live shell). --force-live-fleet is the named override; the resume loop
#   marks its own pass with AUTOTUNE_QUIET_GATE_PASSED=1 so the question is asked once.
#   v10 (2026-11-01): resolve the host profile (source 01-constants.sh) so the
#   registry, store and CUDA lane are THIS box's, not the generic ~/.llm / old-box
#   lane.  REGISTRY and LOGDIR now derive from the profile's LLM_REGISTRY / LLM_STATE_DIR.
#   v9 (2026-11-01): the --all-but-done / --all scope skips embedding models (arch field 6
#   contains "embedding", e.g. gemma-embedding) — they have no generation to measure.
#   v8 (2026-11-01): the post-stop free-VRAM wait bound is ${LLAMA_GPU_FREE_THRESHOLD_MIB:-800}
#   instead of a hardcoded 800, so a box whose driver reserves more than 800 MiB names its own bound.
#   v6 (2026-10-15): the halt classes are distinguished.  A spent cycle budget is
#   exit 4 (the designed end of one boot's measuring, and the only halt a restart
#   resumes); exit 3 is the OTHER adapter stop — a stall with the budget unspent,
#   which needs a person rather than a reboot.  The log line names which fired, so
#   a reader no longer has to infer it from the ledger.
#   v5 (2026-10-12): the post-stop free-VRAM wait is the shared `_tac_gpu_wait_used_below`
#   (bin/_tac-bin-lib.sh).  The inline loop it replaced broke out on an UNREADABLE reading
#   and fell through on exhaustion, so the batch could launch against an occupied or
#   unknown card; it now ABORTS (exit 1, hold released by the EXIT trap) instead.
#   v4 (2026-10-11): the suspend-owner helper was renamed _tac_suspend_pid
#   (bin/_tac-bin-lib.sh v5 — the pid now lives in the marker itself).
# TRACKED HERE since 2026-10-01: this script lived only as a loose ~/.local/bin copy, so a
# change to it was unversioned and unreviewable.  Code that is exclusively supportive of
# ubuntu-console belongs in this repo; install.sh links every file in bin/ into
# ~/.local/bin, so the stable path keeps resolving while the body is reviewable here.
#
# autotune-rows.sh — autotune the given registry rows with the CUDA lane held down.
#
# Usage: autotune-rows.sh <row> [<row> ...]
#        autotune-rows.sh --all-but-done      (every row with field 18 != yes)
#        autotune-rows.sh --all               (every row — a re-validation sweep)
#
# Why a wrapper: run-autotune-batch.sh needs the CUDA lane down for the WHOLE run, but
# between benches the GPU is briefly free and the watchdog's policy is to start the lane
# whenever it is — which would steal VRAM mid-sweep and make the next bench refuse its
# VRAM baseline.  The suspend file holds it down; the trap releases it, because one left
# behind keeps the lane down for as long as nobody notices.
#
# Durable on purpose (2026-09-16): the previous launcher lived in /tmp and a WSL restart
# deleted it along with the log.  This one logs to ~/.llm/autotune-logs/, which survives.
#
# The CUDA cycle ledger is boot-scoped and the batch HALTS (exit 4) at CUDA_CYCLE_BUDGET
# (60) — that is by design, not a failure: a full 27-row sweep is several sessions, each
# needing a WSL restart to reset the ledger.  Exit 3 is the OTHER adapter stop, a stall
# with the budget UNSPENT, and it is NOT a budget halt: it wants a person, not a reboot.
# On halt the batch prints how to resume, and autotune-resume.service re-derives the
# remainder and arms the next restart by itself after a budget halt that made progress.
set -uo pipefail

# Shared helpers (_tac_suspend_*, _tac_gpu_wait_used_below) — see bin/_tac-bin-lib.sh.
# Sourced by realpath so the ~/.local/bin symlink and the repo path both resolve.
# shellcheck source=_tac-bin-lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/_tac-bin-lib.sh"

# ── Box-wide heavy-job serialisation (bin/heavy-job) ─────────────────────────
# At most ONE heavy job runs on this box at a time: two of them oversubscribe all
# 16 cores and starve every interactive turn (bin/heavy-job records the
# measurement).  Re-entrant — an enclosing heavy-job exports HEAVY_JOB_HELD, so the
# batch this script calls passes through instead of deadlocking on the lock its own
# parent holds.  Resolved from this script's own location so the guard does not
# depend on ~/.local/bin being on PATH.
if [[ -z "${HEAVY_JOB_HELD:-}" ]]; then
    exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/heavy-job" \
        "${BASH:-bash}" "${BASH_SOURCE[0]}" "$@"
fi

REPO="${REPO:-/home/wayne/github-wsl/ubuntu-console}"
# Resolve the host profile so the registry, store and lane are THIS box's (a box
# whose store moved off ~/.llm, or whose CUDA lane is not the old box's, names its
# own).  01-constants exports LLM_REGISTRY / LLM_STATE_DIR / LLAMA_MODEL_DIR /
# LLAMA_CUDA_LANE_UNIT from the profile, so the children inherit the same paths.
# shellcheck source=01-constants.sh
source "$REPO/scripts/01-constants.sh"
REGISTRY="${LLM_REGISTRY:-$HOME/.llm/models.conf}"
SUSPEND="${LLAMA_WATCHDOG_CUDA_SUSPEND_FILE:-/dev/shm/llama-watchdog-cuda.suspend}"
LANE="${LLAMA_CUDA_LANE_UNIT:-llama-cuda-llama32-3b-chat.service}"
LOGDIR="${LLM_STATE_DIR:-$HOME/.llm}/autotune-logs"
mkdir -p "$LOGDIR"

# ── --force-live-fleet (2026-11-03) ──────────────────────────────────────────
# Stripped BEFORE the row arguments are read, so the flag can never be mistaken for a
# model file. It is the deliberate override of the quiet-fleet gate below, nothing else.
FORCE_LIVE_FLEET=0
_args=()
for _arg in "$@"; do
    case "$_arg" in
        --force-live-fleet) FORCE_LIVE_FLEET=1 ;;
        *)                  _args+=("$_arg") ;;
    esac
done
set -- ${_args[@]+"${_args[@]}"}

# 1 = ROWS came from a derived scope (--all / --all-but-done), so the tombstone
# applies.  An explicit file argument is a deliberate override and is not filtered.
DERIVED=0

case "${1:-}" in
    # Embedding models (arch field 6, e.g. gemma-embedding) have no generation to
    # measure, so the sweep skips them instead of burning a row on a probe that can
    # only fail.
    #
    # "slow" is a TERMINAL state beside "yes" (2026-11-03).  A row that measured below
    # LLM_MIN_TPS at every ctx has been profiled — the answer is "too slow" — so
    # re-selecting it every sweep re-spends a full descent for a verdict that cannot
    # change (measured: 5.5-6.2 tps across 4096..131072, 13 probes, then "too slow").
    # --all still re-measures everything, which is the deliberate re-validation sweep.
    --all-but-done)
        shift
        mapfile -t ROWS < <(awk -F'|' '
            $1 ~ /^[0-9]+$/ && $18 != "yes" && $18 != "slow" && tolower($6) !~ /embedding/ {print $3}
        ' "$REGISTRY" | sort)
        DERIVED=1
        ;;
    --all)
        shift
        mapfile -t ROWS < <(awk -F'|' '
            $1 ~ /^[0-9]+$/ && tolower($6) !~ /embedding/ {print $3}
        ' "$REGISTRY" | sort)
        DERIVED=1
        ;;
    '')             echo "usage: $(basename "$0") <row|file>... | --all-but-done | --all" >&2; exit 2 ;;
    *)              ROWS=("$@") ;;
esac
# The TOMBSTONE (shared with the resume loop): a retired row is NOT owed, and a
# derived scope must not re-add it.  Measured 2026-11-05: --all-but-done still
# selected the archived 70B and the 88 GiB artefact, one of which OOM-killed at
# staging.  An explicit file argument is deliberate and is honoured; the documented
# override for a derived scope is TAC_RESUME_INCLUDE_RETIRED=1.
if [[ "$DERIVED" == 1 && "${TAC_RESUME_INCLUDE_RETIRED:-0}" != "1" ]]
then
    _kept=()
    for _r in "${ROWS[@]}"
    do
        _tac_is_retired "$_r" || _kept+=("$_r")
    done
    ROWS=("${_kept[@]}")
fi
if (( ${#ROWS[@]} == 0 )); then
    echo "autotune-rows: no rows selected — nothing to do" >&2
    exit 0
fi

# ── Quiet-fleet gate (2026-11-03) ────────────────────────────────────────────
# A live agent turn and a measurement contend for the same CPU, so a row measured
# alongside one describes the contention rather than the model. autotune-resume.service
# asks this question before it claims a plan; every other caller - a hand-started sweep
# above all - now asks it here. Fail closed: a gate that cannot answer (exit 2) refuses too.
GATE="${AUTOTUNE_QUIET_GATE:-$REPO/bin/autotune-resume-quiet-gate.py}"
if (( FORCE_LIVE_FLEET )); then
    echo "quiet-fleet gate: BYPASSED by --force-live-fleet — the fleet may be live, so the reading may be contended" >&2
elif [[ -n "${AUTOTUNE_QUIET_GATE_PASSED:-}" ]]; then
    echo "quiet-fleet gate: already passed by the resume loop (AUTOTUNE_QUIET_GATE_PASSED=1)" >&2
elif [[ -f "$GATE" ]]; then
    if "$GATE" --check; then
        echo "quiet-fleet gate: fleet is quiet" >&2
    else
        _gate_rc=$?
        {
            echo "autotune-rows: REFUSING — the quiet-fleet gate did not clear (rc=$_gate_rc)."
            echo "  A live agent turn contends for the CPU, so a tps measured beside one"
            echo "  describes the contention, not the model."
            echo "  Re-run when the fleet is idle, or pass --force-live-fleet to override on purpose."
        } >&2
        exit 1
    fi
else
    echo "WARN: quiet-fleet gate not found at $GATE — proceeding UNGATED" >&2
fi

LOG="$LOGDIR/autotune-$(date +%Y%m%d-%H%M%S)-rows-${ROWS[0]}${ROWS[*]:+_to_${ROWS[-1]}}.log"
cd "$REPO" || exit 1

{
    echo "=== autotune ${#ROWS[@]} row(s): ${ROWS[*]}"
    echo "=== started $(date -Iseconds)"
    # swallow-ok: the ledger is boot-scoped and absent before the first autotune of a boot; absent means zero cycles, and this only reports it
    echo "=== ledger before: $(cat /dev/shm/autotune-cuda-cycles-* 2>/dev/null || echo 0)"
    echo "=== lane held down: $LANE   suspend: $SUSPEND"
    echo "=== log: $LOG"
} | tee -a "$LOG"

if ! _tac_suspend_acquire "$SUSPEND"; then
    _owner_pid="$(_tac_suspend_pid "$SUSPEND")"
    echo "autotune-rows: REFUSING — $SUSPEND is held by a live run (owner pid ${_owner_pid:-unknown})" >&2
    exit 1
fi
# Release only when THIS run owns the hold (card 7d3e7b95): the old trap removed a
# hold it may not have set, releasing another run's hold mid-sweep.
trap '_tac_suspend_release "$SUSPEND"' EXIT

# ── Clean-room tenants (Wayne, 2026-11-06) ───────────────────────────────────
# The census PERMITS the embedding lane to stay resident, which keeps memory search
# alive during a sweep - but it also makes every reading contended BY CONSTRUCTION:
# the run prints "TPS from this run are CONTENDED, not clean-room".  Wayne's ruling
# 2026-11-06: autotune runs CLEAN.  Every declared tenant is stopped for the sweep
# and restored when it ends, however it ends.  AUTOTUNE_CLEAN_ROOM=0 opts out (and
# says so in the log, because a contended run must never look like a clean one).
AUTOTUNE_CLEAN_ROOM="${AUTOTUNE_CLEAN_ROOM:-1}"
_TENANTS_STOPPED=()
_WATCHDOGS_STOPPED=()
cleanroom_restore() {
    local _t _w
    # Timers back FIRST: a tenant restored while the watchdog is still held stays up, and
    # the watchdog's next tick then finds it healthy instead of restarting it.
    for _w in "${_WATCHDOGS_STOPPED[@]:-}"; do
        [[ -n "$_w" ]] || continue
# swallow-ok: a failed release is reported by the else branch below, never hidden
        if systemctl --user start "$_w" >/dev/null 2>&1; then
            echo "clean-room: released watchdog $_w"
        else
            echo "clean-room: FAILED to release $_w - start it by hand" >&2
        fi
    done
    _WATCHDOGS_STOPPED=()
    for _t in "${_TENANTS_STOPPED[@]:-}"; do
        [[ -n "$_t" ]] || continue
# swallow-ok: a failed restore is reported by the else branch on the next line, never hidden
        if systemctl --user start "$_t" >/dev/null 2>&1; then
            echo "clean-room: restored tenant $_t"
        else
            echo "clean-room: FAILED to restore $_t - start it by hand" >&2
        fi
    done
    _TENANTS_STOPPED=()
}
trap '_tac_suspend_release "$SUSPEND"; cleanroom_restore' EXIT
# ...and when the WRAPPER is the thing signalled, the case block below never runs at all
# (measured 2026-11-03: `pkill -TERM` on this script left the log ending on a probe result,
# with no verdict).  Say it, then exit through the EXIT trap so the hold is still released.
trap '{ echo "=== WRAPPER KILLED by a signal — the rows were NOT measured to a verdict" \
            | tee -a "$LOG"
        exit 130; }' TERM INT
if [[ "$AUTOTUNE_CLEAN_ROOM" == "1" && -n "${LLM_AUTOTUNE_CENSUS:-}" ]]; then
    echo "=== clean-room: declared tenants will be stopped for the sweep" | tee -a "$LOG"
    # THE WATCHDOG DEFEATED THE CLEAN-ROOM (measured 2026-11-06).  A tenant stopped ON PURPOSE
    # looks dead to llama-watchdog, so at 14:31:20 - strike 2/2 - it restarted the embedding lane
    # nine minutes into a sweep and logged "Recovery successful".  Every reading after that was
    # contended, and the only trace was a baseline warning.  The CUDA suspend marker stops the
    # watchdog STARTING the serving lane; it does not stop it REVIVING a tenant it judges
    # unhealthy, so the timers are held for the duration and released on exit.
    for _w in llama-watchdog.timer llama-watchdog-guard.timer llama-watchdog.service; do
        systemctl --user is-active --quiet "$_w" || continue
# swallow-ok: a failed hold is reported by the else branch below, never hidden
        if systemctl --user stop "$_w" >/dev/null 2>&1; then
            _WATCHDOGS_STOPPED+=("$_w")
            echo "clean-room: held $_w (it would otherwise revive a stopped tenant)" | tee -a "$LOG"
        else
            echo "clean-room: could NOT hold $_w - a tenant may come back mid-sweep" | tee -a "$LOG"
        fi
    done
    for _t in $LLM_AUTOTUNE_CENSUS; do
        if systemctl --user is-active --quiet "$_t"; then
# swallow-ok: a failed stop is reported by the else branch that follows it
            if systemctl --user stop "$_t" >/dev/null 2>&1; then
                _TENANTS_STOPPED+=("$_t")
                echo "clean-room: stopped tenant $_t" | tee -a "$LOG"
            else
                echo "clean-room: could NOT stop $_t - the readings will be CONTENDED" | tee -a "$LOG"
            fi
        fi
    done
    # A stop is asynchronous: wait (bounded) for its memory to leave the card, so the
    # baseline below describes a clean card rather than a race with a dying process.
    # The bound is DERIVED, not declared: at a 24 GiB pool the WDDM driver alone
    # holds ~2.4 GiB, so a fixed 800 MiB "clean" figure can never be met (measured
    # 2026-11-06: 2,477 MiB held with the tenant stopped, and every run warned).  The
    # card is drained when the reading stops FALLING - two equal polls - and that
    # floor is printed, so the number a reader sees is the one this boot measured.
    _cr_prev=""
    _cr_stable=0
    _cr_waited=0
    _cr_used=""
    while (( _cr_waited < 30 )); do
        _cr_used="$(_tac_gpu_used_mib)"
        if [[ "$_cr_used" =~ ^[0-9]+$ ]]; then
            if [[ "$_cr_used" == "$_cr_prev" ]]; then
                _cr_stable=$(( _cr_stable + 1 ))
            else
                _cr_stable=0
            fi
            (( _cr_stable >= 2 )) && break
        fi
        _cr_prev="$_cr_used"
        sleep 2
        _cr_waited=$(( _cr_waited + 2 ))
    done
    if (( _cr_stable >= 2 )); then
        echo "clean-room: card drained - ${_cr_used} MiB is this boot driver floor after ${_cr_waited}s" | tee -a "$LOG"
    else
        echo "clean-room: WARNING still moving (${_cr_used:-unreadable} MiB) after ${_cr_waited}s - readings may be contended" | tee -a "$LOG"
    fi
else
    echo "=== clean-room: DISABLED (AUTOTUNE_CLEAN_ROOM=${AUTOTUNE_CLEAN_ROOM}) - readings are CONTENDED by declaration" | tee -a "$LOG"
fi
# swallow-ok: the lane may already be down, and a down lane is the state this line seeks either way
systemctl --user stop "$LANE" >/dev/null 2>&1 || true

# Require a TRUSTWORTHY baseline before launching the batch — through the SHARED
# verdict (bin/_tac-bin-lib.sh), never a hand-rolled free-VRAM threshold.  The byte
# bound this replaces could not express this box: the guard deliberately spares the
# embedding lane, whose 4094 MiB (driver included) exceeds the 3500 MiB threshold, so
# every batch aborted before its first row (measured 2026-11-05 15:10:18 and again
# 2026-11-04 13:23).  The census mode names the tenants that may be resident and
# caps the whole-card hold; with no census configured it is the exclusive bound it
# always was.  An unreadable card still fails CLOSED.
_baseline_rc=0
_baseline_out="$(_tac_gpu_wait_baseline 90 2)" || _baseline_rc=$?
printf '%s\n' "$_baseline_out" | tee -a "$LOG"
if (( _baseline_rc != 0 )); then
    _baseline_reason=$(sed -n 's/^reason=//p' <<< "$_baseline_out" | head -1)
    if (( _baseline_rc == 2 )); then
        echo "=== ABORT: LLM_AUTOTUNE_CENSUS is set but LLM_AUTOTUNE_CENSUS_MAX_MIB is not" \
             "a positive integer — a census with no bound is not a gate" | tee -a "$LOG"
    else
        echo "=== ABORT: the VRAM baseline is not clear (${_baseline_reason:-unknown})" \
             "— NOT launching the batch" | tee -a "$LOG"
    fi
    exit 1
fi
echo "=== card free before start: $(_tac_gpu_used_mib) MiB used" >> "$LOG"

bash scripts/run-autotune-batch.sh "${ROWS[@]}" >> "$LOG" 2>&1
rc=$?
{
    case "$rc" in
        4) echo "=== batch exited 4 (cycle budget spent — one boot's measuring is done)" ;;
        3) echo "=== batch exited 3 (adapter stalled with the budget UNSPENT — look, do not reboot)" ;;
        129|130|137|143)
            # A KILLED run says so.  Without this, a run stopped by an operator (or by the
            # OOM killer) ended on a bare "batch exited N" or, when the WRAPPER itself was
            # signalled, left no verdict line at all — measured 2026-11-03, when `pkill -TERM`
            # ended a row and the log's last line was a probe result.  The distinction that
            # matters: killed is neither "measured" (exit 0) nor "budget spent" (4).
            echo "=== batch KILLED by signal $((rc - 128)) — not a verdict on the rows" ;;
        *) echo "=== batch exited $rc at $(date -Iseconds)" ;;
    esac
    # swallow-ok: the boot-scoped ledger again — an absent file reports zero cycles, which is its true value
    echo "=== ledger after: $(cat /dev/shm/autotune-cuda-cycles-* 2>/dev/null || echo 0)"
    echo "=== log: $LOG"
} | tee -a "$LOG"
exit "$rc"

# end of file
