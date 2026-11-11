#!/usr/bin/env bash
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 23
#   v23 (2026-11-11): clean-room holds actions.runner.* services so CI jobs do not spawn mid-sweep and contend the box.
# Module Version: 22
#   v22 (2026-11-10): handle --help / -h cleanly with exit 0 before taking the heavy-job lock.
# Module Version: 21
#   v21 (2026-11-10): an EXPLICIT row's tombstone override is now LOUD.  Naming a row stays a
#       deliberate override (the documented contract), but it used to say nothing about the
#       retirement: measured 00:53 today, `autotune-rows.sh 5` ran
#       Qwen3.8-Flash-Next-Coder-cut240 — retired as "qwen4exp.expert_count is an array, the
#       loader reads u32 — re-convert" — because the registry had been RENUMBERED at 00:11 and
#       row 5 now names a different model.  The run cost its staging time and said nothing.
#       The reason now prints before the quiet gate, and a row NUMBER is resolved to its FILE
#       through the registry, so the warning names the artefact the tombstone lists.
# Module Version: 20
#   v20 (2026-11-07): §18.3 10.7 — one `warn` helper replaces all ten hand-written `>&2`
#       sites, so every refusal and warning has the same shape.  And the clean-room's
#       `systemctl --user stop "$LANE" ... || true` no longer swallows a FAILED stop: a
#       stop returns 0 for an inactive unit, so a non-zero status means the lane may still
#       hold the card, and it now says so instead of reading as success.
#   v19 (2026-11-07): §18.3 — the log-name assignment v17 added was 132 chars, so it is
#       split into the base and the `_to_<last>` suffix.  The value is byte-identical
#       (the suffix is appended, not rebuilt), and the name still cannot escape LOGDIR.
#   v17 (2026-11-06, Jarvis): THE LOG NAME IS A NAME, NOT A PATH. The line below built it from
#   ${ROWS[0]} .. ${ROWS[-1]}, and an HF-cache row path carries two or three slashes
#   (`models--org--name/snapshots/<sha>/file.gguf`). Those slashes are DIRECTORY SEPARATORS, so
#   the redirect targeted subdirectories nobody had created: "No such file or directory (os error 2)"
#   (journal 2026-11-06T22:50:35Z, reproduced 23:22Z). The batch died on row one, certified stayed
#   8 -> 8, and autotune-resume CORRECTLY refused to arm on exit 1 - the campaign paused for a
#   filename, not for a model. Sanitising alone is not enough: that name was 313 chars, and
#   sanitised alone the basename was 245, i.e. ENAMETOOLONG at 255. So sanitise AND cap, 100 each.
#   Measured after the fix: 190-byte basename, no slash, opens.
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

# --help / -h answers and exits 0 BEFORE the heavy-job lock is taken or any probe runs
# (AGENTS.md §2, CLI entrypoint discipline).  Placed above warn() deliberately: §18.3 10.4
# measures a function as "up to the next definition", so a top-level block inserted after
# warn() would lengthen warn's own span past 100 lines and rise the ratchet.
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    echo "Usage: $(basename "$0") [--force-live-fleet] <row|file>... | --all-but-done | --all"
    echo "  --all-but-done     autotune all rows where autotuned is not yes/slow (skipping embeddings)"
    echo "  --all              autotune all rows (skipping embeddings)"
    echo "  --force-live-fleet bypass the quiet-fleet check"
    echo "  row|file...        specific row numbers or model file names to tune"
    exit 0
fi

# warn - the script's ONE stderr path, so every refusal and warning has the same shape
# and a caller can grep it (10.7).  Nothing below writes to stderr by hand.
warn() { printf '%s\n' "$*" >&2; }

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
    '')             warn "usage: $(basename "$0") <row|file>... | --all-but-done | --all"; exit 2 ;;
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
# AN EXPLICIT ROW IS HONOURED (the documented override) BUT NEVER SILENTLY.  A retirement is a
# decision with a reason — a GGUF the loader cannot read, weights at 4 tps — and the operator
# naming a row deserves that reason before the card is taken.  Measured 2026-11-10 00:53: the
# registry was renumbered at 00:11, `autotune-rows.sh 5` therefore named a DIFFERENT model than
# the plan meant, and the run staged a retired artefact while saying nothing about it.
if [[ "$DERIVED" != 1 ]]
then
    for _r in "${ROWS[@]}"
    do
        _rfile="$_r"
        if [[ "$_r" =~ ^[0-9]+$ ]]
        then
            _rfile="$(awk -F'|' -v n="$_r" '$1 == n {print $3; exit}' "$REGISTRY")"
        fi
        if _rwhy="$(_tac_retired_reason "$_rfile")"
        then
            warn "row '$_r' is RETIRED: ${_rwhy:-no reason recorded}"
            warn "  running it because you named it explicitly; a derived scope needs"
            warn "  TAC_RESUME_INCLUDE_RETIRED=1 to re-add a retired row instead"
        fi
    done
fi
if (( ${#ROWS[@]} == 0 )); then
    warn "autotune-rows: no rows selected — nothing to do"
    exit 0
fi

# ── Quiet-fleet gate (2026-11-03) ────────────────────────────────────────────
# A live agent turn and a measurement contend for the same CPU, so a row measured
# alongside one describes the contention rather than the model. autotune-resume.service
# asks this question before it claims a plan; every other caller - a hand-started sweep
# above all - now asks it here. Fail closed: a gate that cannot answer (exit 2) refuses too.
GATE="${AUTOTUNE_QUIET_GATE:-$REPO/bin/autotune-resume-quiet-gate.py}"
if (( FORCE_LIVE_FLEET )); then
    warn "quiet-fleet gate: BYPASSED by --force-live-fleet — the fleet may be live, so the reading may be contended"
elif [[ -n "${AUTOTUNE_QUIET_GATE_PASSED:-}" ]]; then
    warn "quiet-fleet gate: already passed by the resume loop (AUTOTUNE_QUIET_GATE_PASSED=1)"
elif [[ -f "$GATE" ]]; then
    if "$GATE" --check; then
        warn "quiet-fleet gate: fleet is quiet"
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
    warn "WARN: quiet-fleet gate not found at $GATE — proceeding UNGATED"
fi

# v17: a log NAME, never a path. `/` in a row would become a separator (ENOENT) and the
# uncapped name is 313 chars (ENAMETOOLONG), so sanitise first and cap each side at 100.
_log_name_part() {
    local s="${1//\//_}"
    printf '%s' "${s:0:100}"
}
LOG="$LOGDIR/autotune-$(date +%Y%m%d-%H%M%S)-rows-$(_log_name_part "${ROWS[0]}")"
LOG+="${ROWS[*]:+_to_$(_log_name_part "${ROWS[-1]}")}.log"
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
    warn "autotune-rows: REFUSING — $SUSPEND is held by a live run (owner pid ${_owner_pid:-unknown})"
    exit 1
fi
# THE FLEET MUST NOT TRY A LANE THIS RUN IS ABOUT TO DENY (Wayne, 2026-11-07).  The
# clean-room stops the coder lane a few lines below, and that lane is the fleet PRIMARY
# model, so without this every agent request pays an ECONNREFUSED before failover
# (measured 2026-11-06 23:41-23:42).  Switched HERE, the moment this run OWNS the card,
# not at clean-room time: a run that refuses for want of the card changes nothing.
if ! bash "$REPO/bin/fleet-model.sh" sweep >> "$LOG" 2>&1; then
    echo "=== WARNING: fleet model NOT switched - agents will be denied $(basename "$LANE") during this sweep" | tee -a "$LOG"
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
_RUNNERS_STOPPED=()
# cleanroom_restore restores stopped watchdogs, tenants, runners and fleet model.
cleanroom_restore() {
    local _t _w _r
    # Timers back FIRST: a tenant restored while the watchdog is still held stays up, and
    # the watchdog's next tick then finds it healthy instead of restarting it.
    for _w in "${_WATCHDOGS_STOPPED[@]:-}"; do
        [[ -n "$_w" ]] || continue
# swallow-ok: a failed release is reported by the else branch below, never hidden
        if systemctl --user start "$_w" >/dev/null 2>&1; then
            echo "clean-room: released watchdog $_w"
        else
            warn "clean-room: FAILED to release $_w - start it by hand"
        fi
    done
    _WATCHDOGS_STOPPED=()
    for _t in "${_TENANTS_STOPPED[@]:-}"; do
        [[ -n "$_t" ]] || continue
# swallow-ok: a failed restore is reported by the else branch on the next line, never hidden
        if systemctl --user start "$_t" >/dev/null 2>&1; then
            echo "clean-room: restored tenant $_t"
        else
            warn "clean-room: FAILED to restore $_t - start it by hand"
        fi
    done
    _TENANTS_STOPPED=()
    for _r in "${_RUNNERS_STOPPED[@]:-}"; do
        [[ -n "$_r" ]] || continue
# swallow-ok: a failed release is reported by the else branch below, never hidden
        if systemctl --user start "$_r" >/dev/null 2>&1; then
            echo "clean-room: released runner $_r"
        else
            warn "clean-room: FAILED to release runner $_r - start it by hand"
        fi
    done
    _RUNNERS_STOPPED=()
    # ...and the fleet goes back to the lane it was on, LAST: switching before the tenant
    # is serving would hand every agent a lane that cannot answer yet.
    if ! bash "$REPO/bin/fleet-model.sh" restore; then
        warn "clean-room: FAILED to restore the fleet model - run bin/fleet-model.sh restore"
    fi
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
    _runner_units=""
    _r=""
    # CI runners contend the box if a push or cron triggers a job mid-sweep (Wayne, 2026-11-11).
    # Holding the runner services prevents Runner.Worker from spawning during the bench.
# swallow-ok: systemctl error listing units is handled by empty output
    _runner_units=$(systemctl --user list-unit-files 'actions.runner.*' --no-legend 2>/dev/null | awk '{print $1}')
    for _r in $_runner_units; do
        [[ -n "$_r" ]] || continue
        systemctl --user is-active --quiet "$_r" || continue
# swallow-ok: a failed hold is reported by the else branch below, never hidden
        if systemctl --user stop "$_r" >/dev/null 2>&1; then
            _RUNNERS_STOPPED+=("$_r")
            echo "clean-room: held runner $_r (prevents CI contention during sweep)" | tee -a "$LOG"
        else
            echo "clean-room: could NOT hold runner $_r - CI may contend the sweep" | tee -a "$LOG"
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
# A stop that FAILS is not the same as a lane that was already down: `systemctl stop`
# returns 0 for an inactive unit, so a non-zero status means the lane may still hold the
# card.  Say so — the VRAM baseline below then refuses rather than measuring a contended
# card.  (The old `|| true` swallowed both cases alike, so a failed stop read as success.)
if ! systemctl --user stop "$LANE" >/dev/null 2>&1; then
    warn "clean-room: could not stop $LANE — the card may still be held; the baseline below decides"
fi

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
