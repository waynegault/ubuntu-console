#!/usr/bin/env bash
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 32
#   v32 (2026-11-23): truncate pre-flight boot_id to 12 chars to match batch/row ledger files;
#     re-select indicative slow rows in --all-but-done; default AUTOTUNE_AUTO_RESTART=0 on
#     interactive TTYs; clarify unspent-budget exit-3 summary line.
#   v31 (2026-11-23): the derived scopes (--all / --all-but-done) drop DRAFT HEADS.  Row 7
#     is a 1.26 GiB `dflash` draft (arch `dflash`), not a chat model, and both scopes offered
#     it for a sweep that can only fail — it is passed beside its target as
#     --spec-draft-model.  The arch list is LLM_DRAFT_ARCHS (01-constants v62); the basename
#     is no signal here, because this draft's name carries neither `mtp-` nor `dflash`.
#   v30 (2026-11-19): derive REPO and bin/heavy-job from this script's realpath instead of
#     hardcoding /home/wayne/github-wsl/ubuntu-console, and invoke "$REPO/scripts/run-autotune-batch.sh"
#     explicitly so worktree and secondary-clone invocations never run another checkout's code.
#   v29 (2026-11-18): the lane is THIS box's, from its profile, and an empty answer REFUSES.
#     `${LLAMA_CUDA_LANE_UNIT:-llama-cuda-llama32-3b-chat.service}` named the Dell's unit in
#     code shared with the ASUS box; it never fired while the profile loaded, but a shell
#     without one would have held down a lane that does not exist here and then measured
#     beside the serving lane.  The fallback is TAC_HOST_PRIMARY_LANE and an empty lane stops
#     the run BEFORE the clean-room tears anything down.
#   v28 (2026-11-17): the heartbeat STOPPED DISPLACING THE HOLD RELEASE.  v27 gave it its own
#     `trap 'kill $_HEARTBEAT_PID' EXIT`, and a second EXIT trap REPLACES the first rather than
#     chaining: measured with `bash -c 'trap "echo A" EXIT; trap "echo B" EXIT'` -> prints only
#     B.  So v27 dropped `_tac_suspend_release` and `_tac_cleanroom_restore` on every exit path
#     inside that block — the CUDA card stayed marked held and every census tenant the
#     clean-room stopped stayed stopped (the embedding KEEP lane among them).  `bash -n` is
#     clean and no suite drove the caller, so nothing caught it.  There is now exactly ONE EXIT
#     handler, and it chains all three duties; the trailing `trap - EXIT` that cleared the
#     release for the rest of the run is gone with it.  Guarded by two cases in
#     tests/unit/68-autotune-rows-quiet-gate.bats.
#   v27 (2026-11-17): the batch's output reaches the TERMINAL, not only the log.  Line 374
#     was `>> "$LOG" 2>&1` where every other line in this wrapper tees, so after "baseline
#     cleared" the operator saw a frozen screen for 30-50 minutes across three rows and
#     reasonably asked whether it was stuck — measured this evening, twice.  It is now
#     `| tee -a "$LOG"` (same log, live output) plus a once-a-minute heartbeat to /dev/tty
#     naming elapsed time, the ledger and the running row's pid, because the batch prints in
#     bursts and a gap between two of its lines is still silence.
#   v26 (2026-11-17): the ledger is READ AT THE START, and a spent one RESTARTS the box.
#     Three runs measured nothing tonight (20:46, 00:55, the 13:21 batch) because the
#     batch halts on exit 4 and NOTHING did the one thing that fixes it: the restart
#     lived only in autotune-resume.service, which a direct `model autotune` never
#     tells.  Two halves, both here:
#       (a) a PRE-FLIGHT refusal: before the clean-room stops a single lane, a spent
#           ledger arms the restart and exits 4 — so a doomed run no longer tears the
#           lanes down first.
#       (b) the same arm on the batch's own exit 4, for a ledger that filled mid-run.
#     Both reuse bin/wsl-restart.sh (a bare `wsl --shutdown` deadlocks in-guest), both
#     refuse when a CI job is executing, and AUTOTUNE_AUTO_RESTART=0 opts out.
#     The suspend hold and the clean-room are released BEFORE the arm: a restart ends
#     this process, so the box must be handed back first.
#   v25 (2026-11-12): delegate clean-room enter/restore to shared _tac_cleanroom_enter /
#       _tac_cleanroom_restore in bin/_tac-bin-lib.sh so autotune-rows, bench-rows, and
#       `model bench` share one implementation.
#   v24 (2026-11-11): clean-room stops unsupervised CUDA llama-servers (no systemd unit) so
#       the census no longer refuses on a `model use` or hand-started server; opt out with
#       AUTOTUNE_CLEAN_ROOM_REAP_UNSUPERVISED=0.  `model autotune` now routes through here.
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
# Sourced by realpath so the ~/.local/bin symlink, worktrees, and secondary clones all resolve.
_SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
_SCRIPT_REPO="$(cd "$_SCRIPT_DIR/.." && pwd)"
# shellcheck source=_tac-bin-lib.sh
source "$_SCRIPT_DIR/_tac-bin-lib.sh"

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
    exec "$_SCRIPT_REPO/bin/heavy-job" \
        "${BASH:-bash}" "${BASH_SOURCE[0]}" "$@"
fi

REPO="${REPO:-$_SCRIPT_REPO}"
# The restart method this repo owns (bin/wsl-restart.sh), overridable so a test can
# substitute a recorder — the same seam autotune-resume.sh uses for its own arming.
RESTART_TOOL="${TAC_RESUME_RESTART_TOOL:-$REPO/bin/wsl-restart.sh}"
# Resolve the host profile so the registry, store and lane are THIS box's (a box
# whose store moved off ~/.llm, or whose CUDA lane is not the old box's, names its
# own).  01-constants exports LLM_REGISTRY / LLM_STATE_DIR / LLAMA_MODEL_DIR /
# LLAMA_CUDA_LANE_UNIT from the profile, so the children inherit the same paths.
# shellcheck source=01-constants.sh
source "$REPO/scripts/01-constants.sh"
REGISTRY="${LLM_REGISTRY:-$HOME/.llm/models.conf}"
SUSPEND="${LLAMA_WATCHDOG_CUDA_SUSPEND_FILE:-/dev/shm/llama-watchdog-cuda.suspend}"
# THE LANE IS THE PROFILE'S, never a hardcoded unit name (v28).  This read
# `${LLAMA_CUDA_LANE_UNIT:-llama-cuda-llama32-3b-chat.service}`, and that fallback is the
# DELL XPS's lane (intel-xe-cuda.conf:80) sitting in code shared with the ASUS box.  It
# never fired while the profile loaded — but it names the wrong machine's lane on any shell
# where it did not (env.sh failing, a bare `bash bin/autotune-rows.sh`, a CI runner with no
# profile), which is the per-box leak the profile layer exists to prevent.
# The fallback is now TAC_HOST_PRIMARY_LANE, which EVERY profile declares (asus: the coder
# lane, intel: the Xe lane), and an empty answer REFUSES rather than guesses: stopping the
# wrong unit is worse than stopping none, because the sweep would then run beside a serving
# lane and the next row would fail its VRAM baseline for a reason nobody can read.
LANE="${LLAMA_CUDA_LANE_UNIT:-${TAC_HOST_PRIMARY_LANE:-}}"
if [[ -z "$LANE" ]]; then
    warn "autotune-rows: REFUSING — no CUDA lane resolved (LLAMA_CUDA_LANE_UNIT and"
    warn "  TAC_HOST_PRIMARY_LANE are both empty)."
    warn "  The host profile did not load, so this shell cannot say which lane to hold down."
    warn "  Source env.sh (or tools/host-profile.sh) and re-run; guessing a lane is not an option."
    exit 1
fi
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
    # A DRAFT HEAD (arch in LLM_DRAFT_ARCHS, e.g. `dflash`) is not a standalone model: it is
    # passed beside its target as --spec-draft-model, so a sweep for one can only fail.
    # Measured 2026-11-23: row 7 is NVIDIA-...-LiLiCorr.gguf, a 1.26 GiB `dflash` draft, and
    # --all-but-done selected it as a chat model.  The basename says nothing, so the ARCH is
    # what both scopes test, from the one declaration in 01-constants.sh.
    --all-but-done)
        shift
        mapfile -t ROWS < <(awk -F'|' -v draft_archs="${LLM_DRAFT_ARCHS:-}" '
            $1 ~ /^[0-9]+$/ && $18 != "yes" && !($18 == "slow" && $44 != "indicative") \
                && tolower($6) !~ /embedding/ \
                && index(" " draft_archs " ", " " tolower($6) " ") == 0 {print $3}
        ' "$REGISTRY" | sort)
        DERIVED=1
        ;;
    --all)
        shift
        mapfile -t ROWS < <(awk -F'|' -v draft_archs="${LLM_DRAFT_ARCHS:-}" '
            $1 ~ /^[0-9]+$/ && tolower($6) !~ /embedding/ \
                && index(" " draft_archs " ", " " tolower($6) " ") == 0 {print $3}
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

# ── PRE-FLIGHT: a spent ledger is not somebody else's problem (v26) ────────
# The batch refuses on exit 4 anyway, but it does so AFTER the clean-room has stood
# down every tenant, watchdog and CI runner — so three runs tonight each tore the box
# down, discovered the same spent ledger, and put it back, measuring nothing.  Reading
# it here means a doomed run costs nothing and the restart it needs is armed at once.
# `CUDA_CYCLE_BUDGET` must match scripts/run-autotune-batch.sh's default (60); the
# ledger file is boot-scoped, named the same way by both.
# swallow-ok: an unreadable boot_id names an "unknown" ledger, which reads 0 and only reports
_boot_id="$(tr -d '-' < /proc/sys/kernel/random/boot_id 2>/dev/null | cut -c1-12)"
# The override is HONOURED: scripts/autotune-model.sh and run-autotune-batch.sh both read
# CUDA_CYCLE_FILE, so a wrapper that computed its own path would report a different ledger
# from the one the batch it launches halts on — and no test could seed one.
_ledger_file="${CUDA_CYCLE_FILE:-/dev/shm/autotune-cuda-cycles-${_boot_id:-unknown}}"
_ledger_now=0
# swallow-ok: an absent ledger means zero cycles, its true value before the first run
if [[ -r "$_ledger_file" ]]; then
    _ledger_now=$(< "$_ledger_file")
fi
[[ "$_ledger_now" =~ ^[0-9]+$ ]] || _ledger_now=0
if (( _ledger_now >= ${CUDA_CYCLE_BUDGET:-60} )); then
    {
        echo "=== PRE-FLIGHT: the CUDA cycle ledger reads ${_ledger_now} (budget ${CUDA_CYCLE_BUDGET:-60}) —"
        echo "    this boot's measuring is done.  Nothing was stood down and nothing was measured."
    } | tee -a "$LOG"
    _tac_suspend_release "$SUSPEND"
    # NOT `exit 4` here: the arm at the foot of this file is the one place that decides
    # whether a restart is safe (CI workers, the tool's presence, the opt-out), and a
    # second copy of that decision is how the two would drift apart.
    rc=4
else
    _autotune_preflight_ok=1
fi

if [[ "${_autotune_preflight_ok:-0}" == "1" ]]; then

# ── Clean-room tenants (shared in bin/_tac-bin-lib.sh) ─────────────────────
# Every declared tenant, watchdog, CI runner, and unsupervised CUDA server is stopped
# for the sweep and restored on exit, however it ends.  AUTOTUNE_CLEAN_ROOM=0 opts out.
AUTOTUNE_CLEAN_ROOM="${AUTOTUNE_CLEAN_ROOM:-1}"
# The ONE EXIT handler in this file.  Everything that must happen however the script ends goes
# here, chained through _autotune_exit_prologue — never as a second `trap ... EXIT` further
# down, which would replace this one (see the heartbeat below, measured 2026-11-17).
_autotune_exit_prologue() {
    _tac_suspend_release "$SUSPEND"
    _tac_cleanroom_restore
    # swallow-ok: no heartbeat yet on the exits above its start, and one already gone is the state sought
    [[ -z "${_HEARTBEAT_PID:-}" ]] || kill "$_HEARTBEAT_PID" 2>/dev/null
}
trap '_autotune_exit_prologue' EXIT
# ...and when the WRAPPER is the thing signalled, the case block below never runs at all
# (measured 2026-11-03: `pkill -TERM` on this script left the log ending on a probe result,
# with no verdict).  Say it, then exit through the EXIT trap so the hold is still released.
trap '{ echo "=== WRAPPER KILLED by a signal — the rows were NOT measured to a verdict" \
            | tee -a "$LOG"
        exit 130; }' TERM INT
_tac_cleanroom_enter "$REPO" "$LANE" "$LOG"

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
echo "=== card free before start: $(_tac_gpu_used_mib) MiB used" | tee -a "$LOG"

# LIVE OUTPUT, not log-only (v27).  This line used `>> "$LOG" 2>&1`, so the terminal showed
# nothing at all from here until the batch ended — measured 2026-11-17: after "baseline
# cleared" the operator saw a frozen screen for 30-50 minutes across three rows and
# reasonably asked whether it was stuck.  Every other line in this wrapper tees; this one
# did not.  `tee -a` keeps the log identical (the append-across-runs behaviour the log NAME
# is built for) while showing the row headers, probes and winners as they happen.
#
# _heartbeat — one line a minute on the CONTROLLING TERMINAL while the batch runs.
# It is the answer to a measured complaint: after "baseline cleared" the screen was frozen
# for 30-50 minutes across three rows, and the run looked stuck.  It writes to fd 3, never
# to stdout, so the log keeps its verdict and gains no noise.
# A run with no controlling terminal must simply have no heartbeat: `exec 3<>/dev/tty`
# FAILS without one, and a `2>/dev/null` on `done` cannot swallow that because the redirect
# is evaluated before the command runs (measured 2026-11-17: the loop died with
# "/dev/tty: No such device or address" and rc=1 under a no-tty run).  The guard is here,
# INSIDE the function, so the definition stays top-level and the comment-above rule holds.
_heartbeat() {
    # swallow-ok: no controlling terminal (cron, CI) is the "no heartbeat" answer, not a failure
    exec 3<>/dev/tty 2>/dev/null || return 0
    local _start _now _ledger _pid
    _start=$(date +%s)
    while :; do
        sleep 60
        _now=$(date +%s)
        # swallow-ok: no row in flight yet is an empty pid, which the message simply omits
        _pid=$(pgrep -f 'scripts/autotune-model\.sh' | head -1)
        # swallow-ok: an absent ledger before the first probe reads as 0, its true value
        _ledger=$(cat /dev/shm/autotune-cuda-cycles-* 2>/dev/null || echo 0)
        printf '    … still running: %dm%02ds elapsed, ledger %s, %s\n' \
            "$(( (${_now} - ${_start}) / 60 ))" "$(( (${_now} - ${_start}) % 60 ))" \
            "${_ledger}" "${_pid:+autotune-model pid $_pid}" >&3
    done
}
_heartbeat &
_HEARTBEAT_PID=$!
# The heartbeat must never outlive the batch, however the batch ends.  It CANNOT have its own
# `trap ... EXIT`: that REPLACES the release trap installed above rather than chaining to it,
# so the suspend hold and the clean-room restore would both be silently dropped and the CUDA
# card would stay marked held with every census tenant stopped (measured 2026-11-17; `bash -n`
# is clean and no case saw it).  There is exactly ONE EXIT handler in this file and it owns
# both — see `tests/unit/68-autotune-rows-quiet-gate.bats`, which asserts the count AND that
# the release functions actually run.

bash "$REPO/scripts/run-autotune-batch.sh" "${ROWS[@]}" 2>&1 | tee -a "$LOG"
rc=${PIPESTATUS[0]}
# swallow-ok: a heartbeat already gone is the state sought, and the EXIT trap stops it again
kill "$_HEARTBEAT_PID" 2>/dev/null || :
fi   # end: _autotune_preflight_ok (a pre-flight refusal skips the batch, not the arm)

{
    case "$rc" in
        4) echo "=== batch exited 4 (cycle budget spent — one boot's measuring is done)" ;;
        3) echo "=== batch exited 3 (row halted with cycle budget UNSPENT —" \
                "inspect halt reason above before rebooting)" ;;
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

# ── A SPENT LEDGER RESTARTS THE BOX (v26, 2026-11-17) ─────────────────────
# The ledger is boot-scoped, so "this boot's measuring is done" has exactly one
# remedy: the next boot.  Until now nothing did it.  The restart lived only in
# autotune-resume.service, which arms after a halt it can SEE — and a direct
# `model autotune 8 9 11` never tells it, so the box sat at 63/60 and refused three
# runs tonight (20:46, 00:55, and the 13:21 batch) having measured nothing.
#
# It reuses the method this repo already owns rather than a bare `wsl --shutdown`,
# which deadlocks when run inside the distro (bin/wsl-restart.sh's own header).
# THREE gates, and each refuses rather than guesses:
#   * AUTOTUNE_AUTO_RESTART=0 opts out (an operator watching a row run);
#   * a CI job on this box refuses — the restart would kill it, and a killed run is
#     not a cancelled one (the same bound autotune-resume's arm_restart uses);
#   * the tool must be executable.
# The EXIT trap releases the suspend hold and restores the clean-room BEFORE the arm,
# because a restart is a reboot: it ends this process, so the box must be handed back
# first or the lanes would come up under a stale hold.
if (( rc == 4 )); then
    _auto_restart_def=1
    if [[ -z "${AUTOTUNE_AUTO_RESTART+x}" && -t 0 && -t 1 ]]; then
        _auto_restart_def=0
    fi
    if [[ -z "${AUTOTUNE_AUTO_RESTART+x}" && "$_auto_restart_def" == "0" ]]; then
        echo "=== restart NOT armed: interactive terminal" \
             "(pass AUTOTUNE_AUTO_RESTART=1 to auto-restart)" | tee -a "$LOG"
    elif [[ "${AUTOTUNE_AUTO_RESTART:-$_auto_restart_def}" != "1" ]]; then
        echo "=== restart NOT armed: AUTOTUNE_AUTO_RESTART=0 (spent ledger; restart by hand)" | tee -a "$LOG"
    # -x is the right test for an absolute path; `command -v` only finds things on PATH,
    # and this is a full path by default — requiring BOTH failed the arm even when the
    # tool was present (measured 2026-11-17: "restart FAILED to arm" with wsl-restart.sh
    # executable at the default path).
    elif [[ ! -x "$RESTART_TOOL" ]]; then
        echo "=== restart NOT armed: $RESTART_TOOL is not executable — restart WSL by hand" | tee -a "$LOG"
    elif _ci=$(pgrep -cf '[R]unner.Worker') && [[ "${_ci:-0}" =~ ^[0-9]+$ ]] && (( _ci > 0 )); then
        echo "=== restart NOT armed: ${_ci} CI job(s) executing on this box — a restart would kill them" | tee -a "$LOG"
        echo "    re-arm by hand when the queue is empty:" | tee -a "$LOG"
        echo "      $RESTART_TOOL --restart --delay ${AUTOTUNE_RESTART_DELAY:-3}" | tee -a "$LOG"
    else
        # swallow-ok: a failed release must not block the reboot; the EXIT trap releases again
        _tac_suspend_release "$SUSPEND" 2>/dev/null || true
        _tac_cleanroom_restore
        echo "=== spent ledger: arming a WSL restart (the next boot resumes the remainder)" | tee -a "$LOG"
        if "$RESTART_TOOL" --restart --delay "${AUTOTUNE_RESTART_DELAY:-3}" >> "$LOG" 2>&1; then
            echo "=== restart ARMED via $RESTART_TOOL" | tee -a "$LOG"
        else
            echo "=== restart FAILED to arm (see log) — restart WSL by hand" | tee -a "$LOG"
        fi
    fi
fi
exit "$rc"

# end of file
