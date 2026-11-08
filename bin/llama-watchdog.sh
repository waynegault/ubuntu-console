#!/usr/bin/env bash
# llama-watchdog.sh - Check local llama-server lanes; recover when unhealthy.
# v3.0 (2026-09-09): dual-unit management + 2-strike restart + GPU-gated CUDA lane.
#   - llama-xe-minicpm5-1b-chat.service        (Xe OpenCL,  :18081)  always-on baseline lane
#   - llama-cuda-llama32-3b-chat.service (CUDA,       :18083)  runs ONLY while GPU is free;
#     stopped when GPU busy (foreign workload) so VRAM is freed and gateway
#     requests fail fast to the Xe lane (per Wayne 09-09: "if cuda is not being
#     used, it can be used; if it is being used, use xe").
# v3.1 (2026-09-11): honour health()'s 503 "still loading" signal — a loading
#   lane is neither struck nor restarted; drop a redundant re-probe that could
#   swallow a recovery without resetting strikes.
# v3.2 (2026-09-12): the CUDA lane skips a unit that systemd is already
#   activating (mirrors the Xe lane) instead of issuing a start on a mid-start unit.
# v3.3 (2026-09-12): gpu_busy FAILS CLOSED — a failed/empty probe is treated as
#   BUSY, so the CUDA lane is never started on a GPU we cannot prove free; strike
#   read/write failures now warn instead of silently disabling recovery; add
#   --version (also removes the now-unneeded SC2034 suppression for VERSION).
# v3.4 (2026-09-12): gpu_busy honours gpu-busy.sh's exit contract — exit 1 is a
#   normal BUSY answer, no longer logged as a probe failure every 60s.
# v3.5 (2026-09-13): add a CUDA-ONLY suspend flag
#   (LLAMA_WATCHDOG_CUDA_SUSPEND_FILE, default /dev/shm/llama-watchdog-cuda.suspend).
#   While it exists the CUDA lane is left down (and stopped if up) WITHOUT
#   touching the Xe lane or this timer.  A bench/autotune run that needs the card
#   to itself previously had to stop the watchdog outright for its whole duration,
#   which left the Xe lane unmonitored; now it suspends just the CUDA lane.  This
#   is deliberately narrower than bench_lock, which also suppresses Xe recovery.
# v3.6 (2026-09-14): assert the WINDOW INVARIANT on every lane that is up —
#   advertised --ctx-size (from the unit's ExecStart) must equal /props
#   n_ctx_slot.  --parallel N DIVIDES the served window by N (kv_unified defaults
#   to false) and --fit can shrink it, both silently; the registry carried
#   parallel=16 for 34 of 35 rows.  Logged, never acted on: a window mismatch is
#   not a crash, so it must not consume a strike or restart a lane.
# v3.7 (2026-09-15): the CUDA lane's internals are card-first.  The old vendor
#   names — NV_UNIT, NV_PORT, STRIKE_NV, nv_suspended() and NV_SUSPEND_FILE —
#   become CUDA_UNIT / CUDA_PORT / STRIKE_CUDA / cuda_suspended() /
#   CUDA_SUSPEND_FILE; the strike and suspend files move to llama-watchdog-cuda.*;
#   and LLM_NVIDIA_PORT becomes LLM_CUDA_PORT.  "nv" named the VENDOR, not the card
#   every other artifact in the fleet names, so in a log the two lanes read as one
#   card under two names; the rename makes the CUDA lane and the Xe lane
#   distinguishable at a glance, which is the whole point of the card-first scheme
#   (docs/llm.md).
# v3.8 (2026-09-16): COUNT CUDA-LANE FLAPS AND SHOUT ABOUT THEM.  The lane died 11
#   times in 4h and the only trace was this watchdog logging "healthy" after each
#   restart, so a lane dying every few minutes read exactly like a lane that never
#   missed a beat.  A flap is a death the watchdog did NOT ask for (unit down, card
#   free, nothing suspended): each one is recorded with a timestamp, held to a
#   rolling window, and past the threshold a WARNING names the count and systemd's
#   verdict for the exit.  Result=success with ExecMainStatus=0 means something
#   ASKED it to stop (SIGTERM — the clean "cleaning up before exit" line), not a
#   crash, which is the discrimination that took a journal dive to make on
#   2026-09-16.  Restarting is still the right action; the silence was the bug.
# v3.9 (2026-09-16): past the flap threshold, STOP restarting and hold the lane down for
#   a cooling-off window (LLAMA_WATCHDOG_FLAP_HOLD_S, default 30min).  Every restart is a
#   CUDA context create/destroy cycle and the dxgkrnl leak is proportional to those, so a
#   lane killed every few minutes is not something to restart forever — and while the
#   hold is live the chain serves from the tier below rather than churning the card.  The
#   hold announces itself as POLICY, not as a fault, so a reader does not go hunting for
#   a broken lane that was deliberately taken out.  Delete the hold file to lift it early.
# v3.10 (2026-09-19): manage the CPU tier as well — llama-cpu-qwen25-3b-chat.service
#   (:18084), the tail of the fallback chain.  It had NO supervisor at all: this
#   script covered only the Xe and CUDA units, and because the unit ran
#   Restart=on-failure a clean stop was never undone — so four direct kills
#   (Sep 17 15:43, Sep 17 16:54, Sep 18 23:46, Sep 19 01:14; each a clean
#   "cleaning up before exit" with no systemd "Stopping" line) left the tier dead
#   for hours (Sep 17 16:54 -> Sep 18 18:42, and again from Sep 19 01:14) and
#   silently gutted the chain.  The unit is now Restart=always, which covers a
#   single kill; this lane is the backstop for what `always` cannot: the unit
#   parked in `failed` after StartLimitBurst (6 in 600s), or simply down.
#   No card is involved, so there is no gpu_busy or suspend gate — only the bench
#   lock, as for the Xe lane.  It gets its own flap counter (a silently-restarted
#   lane reads exactly like one that never missed a beat — the v3.8 lesson,
#   applied to CPU) but NOT the CUDA cooling-off hold: that exists for the
#   dxgkrnl leak repeated CUDA context cycles cause, a CPU lane has no such cost,
#   and holding the chain's tail down would remove the tier rather than protect it.
# v3.11 (2026-09-19): manage the SECOND Xe lane as well —
#   llama-xe-llama32-3b-chat.service (:18085).  Same card as LANE 1, so it takes
#   LANE 1's shape (always-on, 2-strike, bench-lock aware) and NOT the CUDA
#   lane's gpu_busy/suspend gate: that gate asks whether the NVIDIA card is free,
#   which is not a question this lane's card can answer.  It had sat `failed`
#   since 2026-09-18 10:48 (start-limit-hit, 7 restarts inside 600s); every death
#   carried the clean-stop signature (Result=success, ExecMainStatus=0, the
#   "cleaning up before exit" line, no systemd "Stopping" line of its own) at a
#   moment when a hosted bench session was sweeping the box and stopping lanes,
#   and the lane starts and stays healthy now that session is over — so the
#   deaths were a deliberate sweep, not a fault in the lane.  It gets its own
#   flap counter (the v3.8 lesson) and NO cooling-off hold, for the CPU lane's
#   reason: the hold guards the dxgkrnl leak from CUDA context cycles, and this
#   lane holds no CUDA context.  Bench sweeps are the expected killer, and those
#   take the bench lock, which this lane honours.
# v3.12 (2026-09-19): a stop WE made for a foreign GPU owner is no longer counted as
#   a flap.  v3.8 counts "down, card free, nothing suspending us" as an unexpected
#   death, which is right for a lane that fell over -- but wrong for a lane this
#   watchdog stopped two ticks earlier because gpu-busy said so.  Three such designed
#   stops inside the 1h window tripped the threshold and entered the v3.9 cooling-off:
#   the CUDA tier sat OFFLINE on an idle card while the log said "NOT normal
#   operation" and blamed a foreign GPU owner for deaths that never happened
#   (2026-09-18 17:47+17:58+18:09 -> 18:14, and again at 14:03).  The GPU-busy branch
#   now writes a marker, renewed on every busy tick; the free tick consumes it instead
#   of recording a flap.  Single-use and TTL-bounded, so a stale marker cannot mask a
#   genuine dxgkrnl death.  The busy line also carries the probe's own reasons, since
#   "GPU busy" alone cannot say which of the five signals fired.
# v3.13 (2026-09-23): "GPU busy" is no longer taken at face value when the gate failed
#   CLOSED for a DRIVER-level reason.  gpu-busy.sh fails closed, and a busy card and an
#   unusable driver BOTH answer busy:true / exit 1, with only the reason string
#   ("nvidia-smi-unavailable") telling them apart -- so during a real GPU fault the only
#   human-visible signal named the case that needs no action.  The busy branch now
#   classifies that one reason ONCE with gpu-passthrough-check.sh --json and logs which
#   situation it actually is (passthrough BROKEN vs. card genuinely in use).  Probing a
#   broken GPU is a crashing nvidia-smi that WSL captures as a core dump, so the
#   classification is held to one probe per window, reusing this file's existing
#   cooling-off window (LLAMA_WATCHDOG_GPU_CLASSIFY_WINDOW_S, default FLAP_HOLD_S) and
#   the existing hold-marker shape rather than inventing a second rate limit.  Read-only
#   with respect to lanes: actuation is unchanged and stays here.
# v3.14 (2026-11-01): a DRIVER-level fail-closed no longer parks a RUNNING lane on one
#   sample.  Measured that day: the lane was stopped three times in 18 minutes, two of
#   them within ~2.5 minutes of starting, every one [probe: nvidia-smi-unavailable] --
#   and `nvidia-smi -L` answered on three manual runs straight afterwards.  The gate is
#   still fail-CLOSED, and this only defers the STOP: when the reason is driver-level and
#   a re-probe (GPU_REPROBE_ATTEMPTS x GPU_REPROBE_SLEEP_S) finds the card FREE, the stop
#   is skipped and the gpustop marker cleared; if the re-probe stays busy or unreadable,
#   the stop happens exactly as before.  The START path is untouched.
# v3.15 (2026-11-02): the flap counter could hold the CUDA tier down forever without
#   ever trying to start it, and it counted a stop a live GPU claim had asked for.
#   Three measured faults, all in the same hour:
#   (1) THE RATCHET.  The down+card-free branch stamped a death BEFORE it looked at the
#       cooling-off, so a held lane earned a fresh stamp on every tick, and the hold was
#       re-armed at every expiry by stamps it had written itself.  Measured: stamps
#       02:44:50 / 02:47:12 / 02:57:27, hold entered 02:57:27, then 03:30:12 logged
#       "died 4x" and re-armed to 04:00:12 while nothing had attempted a restart, and
#       03:35:12 logged "died 5x".  Now: a live hold counts nothing, an expired hold is
#       cleared and the lane gets the restart the hold owed it, and a hold can only be
#       ENTERED by a death recorded on that same pass.
#   (2) THE INSTRUMENT DISAGREED WITH THE GUARD.  bench_lock() reads the marker FILE
#       /tmp/llm-bench.lock; the investigator bench takes a FLOCK on
#       bin/_inv_gpu_lock_path.  At 02:46:58 the guard read the flock as held and stood
#       down; 14 s later bench_lock read the same card as unclaimed and the tick started
#       both CUDA lanes into the bench's queued stop jobs (stop-sigterm timeout ->
#       SIGKILL, Result=timeout), which the flap counter then charged to the lane.
#       gpu_claim_held() is the flock probe, scoped to the gated lane so a GPU bench
#       still cannot park the CPU fallback.
#   (3) The hold's log line is now emitted only when the hold is what stopped the start,
#       so "deliberately OFFLINE" and "restarting it" can no longer describe one tick.
# Recovery goes through systemctl --user restart/stop/start so the unit's
# ExecStartPre GPU-clear and tuned parameters are preserved. Never pkill/spawn
# directly. The Xe unit is boot-enabled and gateway-managed (always-on).
# LIMITATION: llama.cpp /health answers 200 while a decode thread is hung on a
# GPU fault, so decode-hangs are bounded by gateway provider timeouts (idea 2),
# not by this script; this script recovers process death / start-limit states.
# AI: Do not add streaming, partial-offload, or auto-download logic to this script.
# AI INSTRUCTION: Increment version on significant changes.
# Module Version: 27
#   v27 (2026-11-08): LLM-LANE-STOP-001 option (b) — a gpu-busy probe that ERRORS (unexpected
#     rc, or rc 0 with no JSON: OUR TOOLING failing, not an answer about the card) no longer
#     parks a lane that is SERVING.  The verdict stays fail-closed for the START gate; only the
#     stop on a running, healthy lane is refused, and the line says why.  Measured 2026-11-02:
#     16 stops in 24h, 9 ending 'timeout', each 1.5-2.5 min after a start, 13 agents on hosted
#     fallback every time.  A genuine BUSY answer still stops it (the case has the control).
#   v26 (2026-11-08): recover() defers to a live heavy job (LLAMA-LANE-CONTENTION-001).  Measured
#     2026-11-04: the watchdog restarted the chat lane twice in six minutes while autotune-rows.sh
#     held the card, each start SIGKILLed a second later and the unit left failed.  A campaign owns
#     the card while it runs and its clean-room restores the lane when it ends, so the restart is
#     skipped, with a line saying so — the guard can only prevent a restart, never force one.
#   v24 (2026-11-02): a DRIVER-level probe failure no longer stops a lane that is
#   demonstrably SERVING.  Measured live: at 11:40:41 nvidia-smi answered rc=9 and
#   gpu-busy reported nvidia-smi-unavailable while the same card was prefilling a
#   69,632-token request at 1,056 tok/s on :18087; this script stopped the lane at
#   11:40:51 and SIGKILLed it at :52, which left the WSL2 guest unable to mint ANY
#   new CUDA context (llama-cuda-server then logs "no CUDA-capable device is
#   detected") and took the fleet primary down for the rest of the morning.  The
#   fail-closed gate is right to refuse a START on a card it cannot prove free; it is
#   wrong to kill one that answers /health 200, because that answer is positive
#   evidence the card exists and that OUR lane holds it.  gpu_reprobe_free stays: it
#   answers a different question (is the card free?) and still defers the stop when a
#   re-probe says so.  Deliberate trade, stated: on a wedged driver we can no longer
#   see a foreign owner, so a benchmark may wait rather than be handed a card that
#   cannot be handed over anyway.
#   v23 (2026-11-02): the requested-stop arm.  v22 wired gpu_claim_held, which answers
#   only about the PRESENT — the flock is gone the moment its holder releases, so the
#   stop a claim asked for in its last seconds is unattributable to every console probe,
#   and the next free tick charged it to the lane as a death.  The arm reads the
#   investigator's requested-stop record (bin/_tac-bin-lib.sh, Module Version 7), honours
#   it only for a LIVE requester whose /proc start epoch matches, logs who asked, and
#   consumes it so one request can explain one restart.  Not folded into gpustop_active:
#   that marker is written by THIS script and carries no identity.
#   v22 (2026-11-02): the flap ratchet and the GPU-claim probe — see the v3.15 history
#   entry.  The ratchet was recorded as a code-path reading at 03:20Z and fired five
#   minutes later (03:30:12 "died 4x", 03:35:12 "died 5x"), which is the only reason it
#   is still described here as measured rather than as suspected.
#   v21 (2026-11-01): a driver-level fail-closed no longer parks a RUNNING lane on one
#   probe.  See the v3.14 history entry above for the measurement and the boundary
#   (the start gate stays fail-closed; only the STOP is deferred, and only while a
#   re-probe can still prove the card free).  First written as v20 in this same
#   change-set; the module-version gate compares against HEAD, so folding a follow-up
#   edit (a split log line and this helper's comment) into an unpushed commit needs a
#   second bump.
#   v19 (2026-11-01): the lane set is read from the HOST PROFILE
#   (LLAMA_LANE_SPECS, tools/host-profile.sh) instead of four hardcoded units.  The
#   gated (GPU-suspendable) lane is the profile's LLAMA_CUDA_LANE_UNIT and keeps the
#   "cuda" marker namespace; every other lane is always-on via supervise_always_on,
#   with per-unit strike/flap files.  A box with no resident lanes is a no-op; an
#   unresolvable profile exits 1.  This is what lets the arm64 box's two CUDA lanes
#   (chat + embedding) be supervised instead of reported "not installed".
#   v18 (2026-11-01): wrap the over-long "CUDA lane suspended" log line to fit the
#   120-column bound (§18.3 item 8.1.8) — text only, the message is unchanged.
#   v16 (2026-10-26): LANE 4 addresses the second Xe lane as
#   llama-xe-llama32-3b-chat.service.  The unit's name still claimed the
#   Qwen2.5-3B weights the 2026-10-02 bake-off replaced, so a reader following
#   the watchdog's own log line was sent to a model the lane does not serve.
#   XE3B_UNIT and the two lane comments moved with the unit; the strike and
#   flap file names (llama-watchdog-xe3b.*) are unchanged, since they key the
#   LANE, not the unit name.
#   v15 (2026-10-11): the suspend log line names the LIVE OWNER PID rather than the
#   marker's presence.  Since v5 the marker is honoured only while its recorded pid
#   is alive, so "($CUDA_SUSPEND_FILE present)" misdirected a reader to the file
#   instead of to the holder that must be checked.  Text only; the decision and the
#   "CUDA lane suspended" prefix the tests assert are unchanged.
#   v14 (2026-10-11): cuda_suspended() asks _tac_suspend_held (bin/_tac-bin-lib.sh)
#   instead of testing the marker's EXISTENCE, so a marker whose holder was
#   SIGKILLed (its EXIT trap never ran) reads as NOT held and the lane is restored
#   on the next tick.  Measured 2026-10-11: the CUDA lane had been down 4h22m on a
#   0-byte marker whose recorded owner pid 12148 was long gone.
#   Bump counter for tools/check-module-versions.sh, which parses exactly this
#   line (it is what makes an edit here fail the pre-commit guard until the
#   number moves).  Deliberately separate from VERSION= below: the marker
#   changes on ANY edit, VERSION= on significant ones (it is what --version
#   prints).  Added 2026-09-14 — until then this was the only GPU-adjacent
#   script in the repo outside the version guard.
VERSION="3.18"

# --version works without taking the lock (diagnostic; also keeps VERSION used).
if [[ "${1:-}" == "--version" || "${1:-}" == "-V" ]]; then
    echo "llama-watchdog $VERSION"
    exit 0
fi
set -uo pipefail

# log lives in the shared bin library (one definition, every bin/ caller).
# Sourced by realpath so the ~/.local/bin symlink and the repo path both resolve.
TAC_LOG_TAG="watchdog"
export TAC_LOG_TAG
# shellcheck source=_tac-bin-lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/_tac-bin-lib.sh"

# Prevent concurrent runs (timer could fire while a slow restart is in progress).
# Cleanup is inlined into the trap (rather than a named function) so shellcheck
# does not flag a function invoked only by trap — SC2317 on 0.9.0, SC2329 on
# 0.11.0; a suppression comment would be the wrong fix.
# Lock/strike paths are env-overridable so the integration suite can sandbox
# them; the defaults keep production on /dev/shm.
WATCHDOG_LOCK_FILE="${LLAMA_WATCHDOG_LOCK_FILE:-/dev/shm/llama-watchdog.lock}"
WATCHDOG_STRIKE_DIR="${LLAMA_WATCHDOG_STRIKE_DIR:-/dev/shm}"
# Only the lock HOLDER may unlink the lock file: a non-holder removing it would
# drop the inode the holder still has locked, letting a third instance in.
WATCHDOG_HOLDS_LOCK=0
trap 'if [[ "$WATCHDOG_HOLDS_LOCK" == 1 ]]; then rm -f "$WATCHDOG_LOCK_FILE" 2>/dev/null; fi; flock -u 200 2>/dev/null || true' EXIT INT TERM

exec 200>"$WATCHDOG_LOCK_FILE"
if flock -n 200
then
    WATCHDOG_HOLDS_LOCK=1
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') [watchdog] Another instance running - skipping"
    exit 0
fi

# -- Shared constants --
# The resident lanes come from the HOST PROFILE (config/hosts.d/<id>.conf), not a
# hardcoded list: a lane names a specific GGUF file on ONE box, so it is a property
# of the box.  This script reads LLAMA_LANE_SPECS ("unit|port", one per line)
# exactly as `model lanes` and the cache sampler do.  Under systemd the unit's own
# environment carries no profile, so it is resolved here (tools/host-profile.sh).
#
# Test seam: LLAMA_WATCHDOG_LANE_SPECS (and LLAMA_WATCHDOG_CUDA_LANE_UNIT) inject
# the table directly so the integration suite stays hermetic without resolving the
# host profile — the same seam llm-lane-cache-sample.sh uses (LLM_LANE_CACHE_SPECS).
if [[ -n "${LLAMA_WATCHDOG_LANE_SPECS:-}" ]]; then
    LANE_SPECS="$LLAMA_WATCHDOG_LANE_SPECS"
    CUDA_LANE_UNIT="${LLAMA_WATCHDOG_CUDA_LANE_UNIT%.service}"
    PROFILE_MATCHED=1
else
    # shellcheck source=tools/host-profile.sh
    source "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)/tools/host-profile.sh"
    tac_host_profile_apply   # an unresolvable profile leaves TAC_HOST_PROFILE_MATCHED unset; the check below catches it
    LANE_SPECS="${LLAMA_LANE_SPECS:-}"
    CUDA_LANE_UNIT="${LLAMA_CUDA_LANE_UNIT%.service}"
    PROFILE_MATCHED="${TAC_HOST_PROFILE_MATCHED:-0}"
fi
if [[ "$PROFILE_MATCHED" != "1" ]]; then
    log "WARNING: host profile unresolved — cannot determine which lanes to supervise"
    exit 1
fi
if [[ -z "${LANE_SPECS:-}" ]]; then
    log "no resident lanes declared on profile ${TAC_HOST_PROFILE:-generic} — nothing to supervise"
    exit 0
fi
# Canonical port default kept in the LLM_SERVICE_PORT=... form the cross-script
# contract check parses; the lanes themselves are read from LANE_SPECS below.
LLM_SERVICE_PORT="${LLM_SERVICE_PORT:-18081}"
# The gated (GPU-suspendable) lane is the one the autotune/bench wrappers suspend.
# Its strike/flap/hold/suspend markers keep the historical "cuda" namespace so the
# suspend marker's name stays shared with bin/bench-rows.sh,
# scripts/run-autotune-batch.sh and friends.  CUDA_UNIT and CUDA_PORT are set inside
# supervise_cuda_lane() from the lane it is handed.
CUDA_UNIT=""
CUDA_PORT=""
STRIKE_CUDA="$WATCHDOG_STRIKE_DIR/llama-watchdog-cuda.strikes"
# CUDA flap detection (v3.8).  One epoch-seconds stamp per unexpected CUDA-lane
# death, pruned to FLAP_WINDOW_S; nothing else reads this file.  Env-overridable
# like the strike/lock paths so the integration suite can sandbox it — a flap
# count that leaked between test cases would make the warnings untrustworthy.
FLAP_CUDA="${LLAMA_WATCHDOG_CUDA_FLAP_FILE:-$WATCHDOG_STRIKE_DIR/llama-watchdog-cuda.flaps}"
# Each always-on lane gets its own counter file, derived from its unit name in
# supervise_always_on() below — no fixed per-lane names here any more.
FLAP_WINDOW_S="${LLAMA_WATCHDOG_FLAP_WINDOW_S:-3600}"
FLAP_THRESHOLD="${LLAMA_WATCHDOG_FLAP_THRESHOLD:-3}"
# Cooling-off after repeated flaps (v3.9).  Every restart is a CUDA context create/
# destroy cycle, and the dxgkrnl leak is proportional to those cycles — so a lane being
# killed every few minutes is not something to restart forever.  Past the threshold the
# lane is HELD DOWN until this expires, and the log says so: the chain then serves from
# the next tier (CPU, then the API) instead of churning the card.  Deleting the file
# lifts the hold early, which is the deliberate escape hatch.
FLAP_HOLD_FILE="${LLAMA_WATCHDOG_CUDA_FLAP_HOLD_FILE:-$WATCHDOG_STRIKE_DIR/llama-watchdog-cuda.flaphold}"
FLAP_HOLD_S="${LLAMA_WATCHDOG_FLAP_HOLD_S:-1800}"
# Presence of this file suspends ONLY the CUDA lane (see cuda_suspended).  Kept
# env-overridable like the lock/strike paths so the integration suite sandboxes it.
CUDA_SUSPEND_FILE="${LLAMA_WATCHDOG_CUDA_SUSPEND_FILE:-/dev/shm/llama-watchdog-cuda.suspend}"
# Marker written when the GPU-busy branch stops the CUDA lane on purpose (v3.12).
# It tells the next free tick that this down unit is OURS, not a flap.  Renewed on
# every busy tick, so the TTL only has to outlive the 10min timer rather than the
# whole foreign workload; consumed (single-use) by the free tick, so it can explain
# exactly one restart and never mask a genuine death after that.
CUDA_GPUSTOP_FILE="${LLAMA_WATCHDOG_CUDA_GPUSTOP_FILE:-$WATCHDOG_STRIKE_DIR/llama-watchdog-cuda.gpustop}"
CUDA_GPUSTOP_TTL_S="${LLAMA_WATCHDOG_CUDA_GPUSTOP_TTL_S:-1800}"

# health: 0=ok, 1=down/fail, 2=still loading (503) — treat 2 as "not ready, don't touch"
health() {
    local port="$1" code body
    body=$(curl -s --max-time 5 -w '\n%{http_code}' "http://127.0.0.1:${port}/health" 2>/dev/null)
    code=$(printf '%s' "$body" | tail -1)
    case "$code" in
        200) return 0 ;;
        503) return 2 ;;
        *)   curl -sf --max-time 5 "http://127.0.0.1:${port}/v1/models" >/dev/null 2>&1 && return 0 || return 1 ;;
    esac
}

# Window invariant (2026-09-14).  The window a request actually gets must equal
# the ctx the unit advertises: "--parallel N" DIVIDES it (kv_unified defaults to
# false, measured 2026-09-14) and a "--fit" reduction can shrink it, both
# silently.  The semantics-independent form — advertised --ctx-size == the
# /props n_ctx_slot — holds whether or not -kvu is ever enabled, unlike
# total_slots x n_ctx_slot == ctx (which breaks under -kvu).
# Logged, never acted on: a window mismatch is not a crash, so it must not
# consume a strike or restart a lane.
window_check() {
    local unit="$1" port="$2" advertised served
    health "$port" >/dev/null 2>&1 || return 0   # down or still loading: nothing to assert
    advertised=$(systemctl --user show "${unit}.service" -p ExecStart --value 2>/dev/null \
        | sed -nE 's/.*--ctx-size ([0-9]+).*/\1/p' | head -1)
    served=$(curl -s --max-time 5 "http://127.0.0.1:${port}/props" 2>/dev/null \
        | jq -r '.default_generation_settings.n_ctx // empty' 2>/dev/null)
    if [[ -z "$advertised" || -z "$served" ]]; then
        log "window check :${port} (${unit}) — could not read the ctx (ExecStart --ctx-size='${advertised}', /props n_ctx='${served}')"
        return 0
    fi
    if [[ "$advertised" != "$served" ]]; then
        log "WARNING window mismatch :${port} (${unit}) — advertises ctx ${advertised} but serves ${served} per request; check --parallel (N slots DIVIDE the window unless --kv-unified) and --fit"
    fi
    return 0
}

# Strike counters. A read/write failure must NEVER silently disable recovery —
# warn loudly so a mistyped WATCHDOG_STRIKE_DIR surfaces instead of the watchdog
# logging "strike 1/2" forever. A missing file is the normal first-run case.
strike_get() {
    local f="$1" v
    if [[ ! -e "$f" ]]; then
        echo 0
        return 0
    fi
    if ! v=$(cat "$f" 2>/dev/null); then
        log "WARNING: cannot read strike file $f — treating as 0 strikes"
        echo 0
        return 0
    fi
    if [[ ! "$v" =~ ^[0-9]+$ ]]; then
        log "WARNING: strike file $f has non-numeric content ('$v') — treating as 0 strikes"
        echo 0
        return 0
    fi
    printf '%s\n' "$v"
}
strike_reset() {
    printf '0\n' > "$1" 2>/dev/null || log "WARNING: cannot write strike file $1 (strikes not reset)"
}
strike_inc() {
    local f="$1" n
    n=$(strike_get "$f")
    n=$((n+1))
    printf '%s\n' "$n" > "$f" 2>/dev/null || log "WARNING: cannot write strike file $f (strike not persisted)"
}

# --- GPU-busy stop marker (v3.12) ---
# gpustop_mark -- record that WE stopped the CUDA lane for a foreign GPU owner, so
# the next free tick restarts it without counting a flap.  Renewed on every busy
# tick: the TTL bounds staleness, it does not have to outlive the workload.
gpustop_mark() {
    local until
    until=$(( $(date +%s) + CUDA_GPUSTOP_TTL_S ))
    printf '%s\n' "$until" > "$CUDA_GPUSTOP_FILE" 2>/dev/null \
        || log "WARNING: cannot write the GPU-stop marker $CUDA_GPUSTOP_FILE (a designed stop may be counted as a flap)"
}
# gpustop_active -- is that marker live (present, numeric, not expired)?
gpustop_active() {
    local until
    [[ -e "$CUDA_GPUSTOP_FILE" ]] || return 1
    until=$(cat "$CUDA_GPUSTOP_FILE" 2>/dev/null || true)
    [[ "$until" =~ ^[0-9]+$ ]] || return 1
    (( $(date +%s) < until ))
}
# gpustop_clear — drop the "GPU is busy, keep the lane down" marker.  Stated rather
# than swallowed: if the marker cannot be removed it OUTLIVES the hold it recorded,
# and the next tick then explains a real death away with a stale one (v3.8's point).
gpustop_clear() {
    if ! rm -f "$CUDA_GPUSTOP_FILE"
    then
        log "WARNING: could not remove $CUDA_GPUSTOP_FILE — a stale GPU-busy marker may explain away a real death"
    fi
}

# --- flap bookkeeping (v3.8) ---
# flap_record — stamp an unexpected CUDA-lane death, pruning stamps older than the
# window in the same write so the file cannot grow without bound.  A stamp is only
# ever written where the watchdog concludes "down, card free, nothing suspended".
flap_record() {
    local f="$1" now cutoff kept="" ts
    now=$(date +%s)
    cutoff=$((now - FLAP_WINDOW_S))
    if [[ -e "$f" ]]; then
        while IFS= read -r ts; do
            [[ "$ts" =~ ^[0-9]+$ ]] || continue
            if (( ts >= cutoff )); then kept+="$ts"$'\n'; fi
        done < "$f"
    fi
    kept+="$now"$'\n'
    printf '%s' "$kept" > "$f" 2>/dev/null \
        || log "WARNING: cannot write flap file $f (flap history not persisted)"
}

# flap_count — unexpected deaths currently inside the rolling window.
flap_count() {
    local f="$1" now cutoff n=0 ts
    [[ -e "$f" ]] || { echo 0; return 0; }
    now=$(date +%s)
    cutoff=$((now - FLAP_WINDOW_S))
    while IFS= read -r ts; do
        [[ "$ts" =~ ^[0-9]+$ ]] || continue
        if (( ts >= cutoff )); then n=$((n+1)); fi
    done < "$f"
    echo "$n"
}

# flap_alert <unit> <flaps_file> <hint> — once a lane is dying repeatedly, say so.
# Restarting is still correct, and that is exactly what hid this on 2026-09-16:
# every death produced a "healthy" line and nothing else.  systemd's verdict
# discriminates the two cases that matter — Result=success with ExecMainStatus=0
# is a CLEAN stop (something sent SIGTERM), not a crash — and that discrimination
# is shared by every lane, so only the trailing hint is per-lane.
flap_alert() {
    local unit="$1" flaps="$2" hint="${3:-}" n verdict status
    n=$(flap_count "$flaps")
    if (( n < FLAP_THRESHOLD )); then return 0; fi
    verdict=$(systemctl --user show "$unit.service" -p Result --value 2>/dev/null || true)
    status=$(systemctl --user show "$unit.service" -p ExecMainStatus --value 2>/dev/null || true)
    log "WARNING flap: $unit died ${n}x in $((FLAP_WINDOW_S / 60))min (threshold ${FLAP_THRESHOLD}) — restarting it, but this is NOT normal operation"
    log "WARNING flap: systemd last saw Result=${verdict:-unknown} ExecMainStatus=${status:-unknown}; success/0 means something ASKED it to stop — check ${hint:-the unit journal}, and the unit journal, before trusting this lane"
}

# --- cooling-off (v3.9) ---
# flap_hold_active — inside the cooling-off window?
flap_hold_active() {
    local until
    [[ -e "$FLAP_HOLD_FILE" ]] || return 1
    until=$(cat "$FLAP_HOLD_FILE" 2>/dev/null || true)
    [[ "$until" =~ ^[0-9]+$ ]] || return 1
    (( $(date +%s) < until ))
}

# flap_hold_enter — enter (or extend) the cooling-off window.  What it means matters as
# much as what it does: the lane is deliberately OFFLINE, not broken, and the tier below
# is serving — so a reader does not go hunting a fault that is a policy.
flap_hold_enter() {
    local until
    until=$(( $(date +%s) + FLAP_HOLD_S ))
    printf '%s\n' "$until" > "$FLAP_HOLD_FILE" 2>/dev/null \
        || log "WARNING: cannot write the flap hold file $FLAP_HOLD_FILE (cooling-off not persisted)"
    log "WARNING flap: holding $CUDA_UNIT down for $((FLAP_HOLD_S / 60))min after repeated deaths — the CUDA tier is deliberately OFFLINE and the chain serves from the next tier; delete $FLAP_HOLD_FILE to lift this early"
}

# gpu_busy — 0 (busy) when a foreign workload holds the GPU. FAILS CLOSED: if the
# probe is missing/fails/returns nothing we cannot prove the GPU is free, so we
# treat it as BUSY and the CUDA lane is not started (matches the policy above).
GPU_BUSY_PROBE_WARNED=0
# Reasons from the last probe, for the busy log line.  Set by gpu_busy(), read only
# where that line is emitted; empty when the probe reported none.
GPU_BUSY_REASONS=""
# 1 when the last gpu_busy() answer was OUR TOOLING failing (an unexpected rc, or rc 0
# with no JSON) rather than gpu-busy.sh answering BUSY.  Read by the lane's stop decision.
GPU_BUSY_PROBE_ERROR=0

# Pull the "reasons":[...] entries out of the probe's JSON for the log line.
# Deliberately no jq: the shape is fixed, this runs on every tick, and a parsing
# miss must never change the busy/free verdict.
gpu_busy_reasons() {
    local inner="${1#*\"reasons\":[}"
    # tree-sitter-bash cannot parse a literal ']' inside a parameter-expansion
    # pattern, and that break cost this file's later call edges (flap_alert,
    # flap_record and friends were missing from the graph). Held in a variable
    # instead, which parses identically — note []-bracket-expression forms also
    # fail, so a variable is the only shape that works.
    local _rb=']'
    inner="${inner%%"${_rb}"*}"
    inner="${inner//\",\"/, }"
    GPU_BUSY_REASONS="${inner//\"/}"
}

gpu_busy() {
    local j rc
    GPU_BUSY_REASONS=""
    GPU_BUSY_PROBE_ERROR=0
    j=$("$HOME/.local/bin/gpu-busy.sh" --json 2>/dev/null)
    rc=$?
    # gpu-busy.sh contract: exit 0 = FREE, exit 1 = BUSY, anything else = error.
    # Exit 1 is a NORMAL "busy" answer (the GPU is held), not a probe failure, so
    # it must not be logged as one -- it fires on every busy tick otherwise.
    if (( rc == 0 )) && [[ -n "$j" ]]; then
        if [[ "$j" == *'"busy":true'* ]]; then
            gpu_busy_reasons "$j"
            return 0
        fi
        return 1
    fi
    if (( rc == 1 )); then
        gpu_busy_reasons "$j"
        return 0
    fi
    # Genuine probe failure (unexpected rc, or rc 0 with no JSON) -- FAIL CLOSED.
    # Recorded so the lane's stop decision can tell OUR tooling failing from the card
    # being held: the verdict stays fail-closed either way (LLM-LANE-STOP-001).
    GPU_BUSY_PROBE_ERROR=1
    if (( GPU_BUSY_PROBE_WARNED == 0 )); then
        log "WARNING: gpu-busy.sh probe failed (rc=$rc, ${#j} bytes) — treating GPU as BUSY (CUDA lane will not start)"
        GPU_BUSY_PROBE_WARNED=1
    fi
    return 0
}

# --- driver-level fail-closed classification (v3.13) ---
# THE PROBLEM THIS FIXES: gpu-busy.sh fails CLOSED, and only the REASON STRING
# separates "the card is legitimately busy" from "the driver cannot be talked to".
# The driver case is the single reason "nvidia-smi-unavailable", and during a real
# GPU fault that was the whole human-visible signal: a log line saying "GPU busy",
# which is the case that needs no action, while the lane was held down for a
# reason that was wrong in one of the two situations.  Here the gate's verdict is
# classified ONCE by the passthrough checker and logged, so the stated reason is
# truthful:
#   * state=unavailable -> the passthrough is BROKEN (a host-side fix, none here);
#   * state=ok          -> the driver answers, so the fail-closed verdict was a
#                          transient probe failure and the card is genuinely in use.
#
# RATE LIMIT — asking is not free: a probe of a BROKEN GPU is a crashing
# nvidia-smi, and WSL captures each crash as a core dump (kernel-log noise +
# jitter).  So the classification is held to at most one probe per HOLD WINDOW,
# and it reuses the window this file already has (FLAP_HOLD_S, the CUDA
# cooling-off) rather than introducing a second notion of "how long is too long".
# The marker has the shape the other holds in this file already use — an
# epoch-seconds expiry, written by a _stamp and tested by a _due (gpustop_*,
# flap_hold_*) — and it is deliberately NOT cleared when the card goes free: a
# driver that oscillates broken/free would otherwise re-probe on every episode,
# i.e. every 5 minutes again, which is the hammering this exists to stop.  A
# persistently broken GPU is therefore probed twice an hour, not twelve times.
#
# ACTUATION STAYS HERE.  bin/gpu-passthrough-watch.sh is an observe-only observer
# (it never starts or stops a lane) and this probe is read-only (`nvidia-smi -L`):
# nothing in this path touches a lane, so the watchdog remains the single owner of
# lane actuation.
GPU_CLASSIFY_FILE="${LLAMA_WATCHDOG_GPU_CLASSIFY_FILE:-$WATCHDOG_STRIKE_DIR/llama-watchdog-cuda.gpuclassify}"
GPU_CLASSIFY_WINDOW_S="${LLAMA_WATCHDOG_GPU_CLASSIFY_WINDOW_S:-$FLAP_HOLD_S}"
GPU_PASSTHROUGH_CHECK="${LLAMA_WATCHDOG_GPU_CHECK:-$HOME/.local/bin/gpu-passthrough-check.sh}"

# gpu_driver_failclosed — 0 when the last gpu-busy.sh answer was a DRIVER-level
# fail-closed.  Every shape that means "the driver cannot be talked to" arrives
# here as this ONE reason — nvidia-smi unavailable, "GPU access blocked by the
# OS", or a signal death all make nvidia-smi exit non-zero, and gpu-busy.sh's
# foreign-apps branch collapses them into "nvidia-smi-unavailable"
# (bin/gpu-busy.sh, the fail-closed branch there).  A genuinely busy card
# produces a different reason (util=, foreign-app pid=, lock:, declared:,
# cuda-owned-by-another-run) or none, so this cannot fire on it.
#
# DELIBERATE BOUNDARY: gpu_busy()'s own fail-closed for a probe that errored
# outright (a missing or broken gpu-busy.sh) is NOT classified.  That is a fault
# in our own tooling rather than a driver signal, so asking the passthrough
# checker about the card would answer a different question — and that path
# already logs its warning once (see gpu_busy's GPU_BUSY_PROBE_WARNED).
gpu_driver_failclosed() {
    [[ "$GPU_BUSY_REASONS" == *nvidia-smi-unavailable* ]]
}

# gpu_serving_now — 0 when the gated lane answers /health 200 right now.
#
# WHY (measured 2026-11-02, and it cost a morning): nvidia-smi failing says nothing
# about whether the card WORKS.  At 11:40:41 nvidia-smi answered rc=9 and gpu-busy
# reported nvidia-smi-unavailable while the same card served a 69,632-token prefill on
# :18087 at 1,056 tok/s.  The stop that followed was charged to "GPU busy" and left the
# guest unable to create a new CUDA context at all.  A lane answering /health 200 is
# positive evidence: the card exists, and OUR process is the one holding it.  A lane
# answering 503 ("loading") is NOT that evidence — that is exactly what a restarted
# lane looks like on a wedged driver — so only rc==0 counts here.
gpu_serving_now() {
    health "$CUDA_PORT"
}

# Re-probe dials (v3.14): how many attempts, and how far apart.
GPU_REPROBE_ATTEMPTS=${GPU_REPROBE_ATTEMPTS:-2}
GPU_REPROBE_SLEEP_S=${GPU_REPROBE_SLEEP_S:-5}

# gpu_reprobe_free — 0 when a DRIVER-level fail-closed is contradicted by a
# re-probe, so one transient nvidia-smi miss does not park a running lane.
#
# WHY (measured 2026-11-01): the lane was stopped three times in 18 minutes, two of
# them within ~2.5 minutes of starting, every one with [probe: nvidia-smi-unavailable]
# — while `nvidia-smi -L` answered on three manual runs immediately afterwards.  The
# fault was the probe being intermittently unavailable, not a workload on the card.
#
# The gate itself stays fail-CLOSED: a card we cannot prove free is never STARTED, and
# this helper only ever defers a STOP.  Anything other than an explicit free answer
# keeps BUSY, so a probe that stays unreadable still parks the lane — after N attempts.
gpu_reprobe_free() {
    local i j rc
    for ((i = 1; i <= GPU_REPROBE_ATTEMPTS; i++)); do
        sleep "$GPU_REPROBE_SLEEP_S"
        j=$("$HOME/.local/bin/gpu-busy.sh" --json 2>/dev/null)  # swallow-ok: a failed re-probe keeps the BUSY verdict
        rc=$?
        if (( rc == 0 )) && [[ "$j" == *'"busy":false'* ]]; then
            return 0
        fi
    done
    return 1
}

# gpu_classify_due — 0 when this tick may run the classifier (no hold, an
# unreadable hold, or an expired one).
gpu_classify_due() {
    local until
    [[ -e "$GPU_CLASSIFY_FILE" ]] || return 0
    until=$(cat "$GPU_CLASSIFY_FILE" 2>/dev/null || true)
    [[ "$until" =~ ^[0-9]+$ ]] || return 0
    (( $(date +%s) >= until ))
}

# gpu_classify_stamp — start the hold window, so a broken GPU is not probed again
# on the next tick.
gpu_classify_stamp() {
    local until _msg
    until=$(( $(date +%s) + GPU_CLASSIFY_WINDOW_S ))
    if ! printf '%s\n' "$until" > "$GPU_CLASSIFY_FILE" 2>/dev/null; then
        _msg="WARNING: cannot write the GPU classification hold $GPU_CLASSIFY_FILE"
        _msg+=" — a broken GPU may be re-probed on every tick until it is writable"
        log "$_msg"
    fi
}

# gpu_classify_driver_failclosed — when the gate failed closed for a DRIVER-level
# reason, say which of the two situations it actually is, at most once per window.
# Read-only with respect to lanes: it probes and logs, and never starts or stops
# anything.  The probe's JSON is parsed with the same sed idiom
# bin/gpu-passthrough-watch.sh uses (the shape is fixed, and a parse miss must not
# change the busy/free verdict — the verdict is already decided by this point).
gpu_classify_driver_failclosed() {
    gpu_driver_failclosed || return 0
    gpu_classify_due || return 0
    local _json _rc _state _reason _dxg _crash _win _msg
    _json=$("$GPU_PASSTHROUGH_CHECK" --json 2>/dev/null); _rc=$?
    _state=$(printf '%s' "$_json"  | sed -n 's/.*"state"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    _reason=$(printf '%s' "$_json" | sed -n 's/.*"reason"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    _dxg=$(printf '%s' "$_json"   | sed -n 's/.*"dxg_failures"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')
    _crash=$(printf '%s' "$_json" | sed -n 's/.*"wsl_crashes"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')
    _win=$(printf '%s' "$_json"   | sed -n 's/.*"window_min"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')
    [[ -n "$_state" ]] || _state="error"
    [[ -n "$_reason" ]] || _reason="the classifier produced no JSON (rc=$_rc)"
    case "$_state" in
        unavailable)
            _msg="GPU busy driver-level: classified UNAVAILABLE — the CUDA card's passthrough is BROKEN,"
            _msg+=" not in use (${_reason}; dxg=${_dxg:-?} crash=${_crash:-?} / ${_win:-?}min,"
            _msg+=" via gpu-passthrough-check.sh)."
            _msg+=" The lane is down on a DRIVER fault, not on a workload, so stopping it frees"
            _msg+=" nothing and no local lane takes over; the fix is host-side"
            _msg+=" (wsl --shutdown / GPU driver update)."
            log "$_msg"
            ;;
        ok)
            _msg="GPU busy driver-level: classified OK — nvidia-smi answers, so the fail-closed"
            _msg+=" verdict was a transient probe failure and the card is genuinely in use"
            _msg+=" (${_reason}; dxg=${_dxg:-?} crash=${_crash:-?} / ${_win:-?}min)"
            log "$_msg"
            ;;
        *)
            _msg="WARNING: GPU busy driver-level and the passthrough classifier could not decide"
            _msg+=" (state=${_state}, ${_reason}) — the gate's nvidia-smi-unavailable reason is"
            _msg+=" UNCONFIRMED; the lane stays down until the gate clears"
            log "$_msg"
            ;;
    esac
    gpu_classify_stamp
}

bench_lock() { [[ -f "${LLM_BENCH_LOCK_FILE:-/tmp/llm-bench.lock}" ]]; }

# gpu_claim_held — a live GPU OWNERSHIP CLAIM is held, whatever lock-file convention
# the bench used.  bench_lock above reads the bench/autotune marker FILE
# (/tmp/llm-bench.lock); the investigator pipeline takes a FLOCK instead, on the path
# the supervision guard already probes (bin/_inv_gpu_lock_path).  A file test cannot see
# a flock, and the kernel drops it when the holder dies, so the probe is: can we take it
# right now?  Not being able to means a live owner.
#
# Measured 2026-11-02, and it is why this exists: the guard logged "a bench holds
# gpu.lock — deliberate stop, standing down" at 02:46:58, and 14 s later the tick's
# bench_lock answered "no bench" to the same card, so the watchdog started both CUDA
# lanes into the bench's queued stop jobs.  stop-sigterm timed out twice and systemd
# SIGKILLed the lane (Result=timeout, ExecMainStatus=9); the flap counter then charged
# that wreckage to the lane.  A held claim is the only reliable "someone else owns this
# card" signal on this host: the bench's server and our own lane are the same binary.
#
# Deliberately NOT folded into bench_lock(): that one also gates the always-on lanes
# (the CPU tail among them), and a benchmark on the GPU must not stop the CPU fallback.
gpu_claim_held() {
    local _lock
    _lock="$(_inv_gpu_lock_path)"
    [[ -e "$_lock" ]] || return 1
    # swallow-ok: the probe's exit status IS the question — a held flock means busy.
    if flock -n "$_lock" -c true 2>/dev/null; then
        return 1
    fi
    return 0
}

# cuda_suspended — the CUDA lane is held down on purpose (a bench/autotune run is
# measuring TPS and wants the card to itself).  Scoped to the CUDA lane only:
# unlike bench_lock it must NOT suppress Xe recovery.
#
# The decision is _tac_suspend_held (bin/_tac-bin-lib.sh), NOT the marker's mere
# existence: a marker left by a holder that was SIGKILLed carries a DEAD pid and
# must read as NOT held, or the lane stays down until a human notices (measured
# 2026-10-11: 4h22m on a 0-byte marker whose recorded pid 12148 was gone).
cuda_suspended() { _tac_suspend_held "$CUDA_SUSPEND_FILE"; }

# wait_healthy <port> <timeout_s> — 0 healthy, 1 not
wait_healthy() {
    local port="$1" t="$2" i
    for (( i=0; i<t; i++ )); do
        if health "$port"; then return 0; fi
        # loading (503) is fine, keep waiting; only give up on hard timeout
        sleep 1
    done
    return 1
}

# recover <unit> <port> — issue restart (or start if inactive/failed), then wait
recover() {
    local unit="$1" port="$2" state _out _out2
    # LLAMA-LANE-CONTENTION-001 (measured 2026-11-04): this restarted the chat lane twice in six
    # minutes while autotune-rows.sh held the card — a fight, not a recovery, and the unit was
    # left failed.  A campaign OWNS the card while it runs and its own clean-room puts the lane
    # back when it ends, so a restart now can only be preempted.  Deferring is the whole fix on
    # this side: it can only PREVENT a restart, never force one.
    if _tac_heavy_job_busy; then
        log "recover DEFERRED for $unit — a heavy job holds the box; its clean-room restores the lane when it ends"
        return 0
    fi
    state=$(systemctl --user show "$unit.service" -p ActiveState --value 2>/dev/null || true)
    if [[ "$state" == "failed" ]]; then
        systemctl --user reset-failed "$unit.service" 2>/dev/null || true
    fi
    if ! _out=$(systemctl --user restart "$unit.service" 2>&1); then
        if ! _out2=$(systemctl --user start "$unit.service" 2>&1); then
            # Name the CAUSE, not just the outcome — and keep BOTH messages, since the
            # second call's is not the first one's.  "recover failed" with no reason is
            # what left the 2026-09 CUDA deaths unattributable.
            log "recover failed for $unit — restart: ${_out}; start: ${_out2}"
            return 1
        fi
    fi
    log "Restart issued: $unit"
    if wait_healthy "$port" 150; then
        log "Recovery successful — $unit healthy on :${port}"
        return 0
    fi
    log "Recovery failed: $unit not healthy on :${port} within 150s"
    return 1
}

# lane_present <unit> — is this lane's unit installed on THIS host?
#
# v5.1 (2026-11-01): every lane below was written against a fixed four-lane box, and
# when a unit is RETIRED the lane body does not stop — it probes a dead port, strikes,
# calls recover(), and recover() spends 150s in wait_healthy on a port nobody serves.
# Measured tonight: three absent units x 150s pushed one run past systemd's 300s
# TimeoutStartUSec, so `llama-watchdog.service` itself went `failed (Result=timeout)`
# — the SUPERVISOR failed because the things it supervises no longer exist. A lane
# whose unit is `not-found` is not down; it is not installed, which is a policy answer
# and not a fault, so it is skipped and never restarted. LoadState is the right field:
# ActiveState reads `inactive` for absent and for stopped alike, so it cannot tell the
# two apart — a "down" lane and a "does not exist" lane look identical there.
lane_present() {
    local load
    # swallow-ok: an absent unit or a systemctl hiccup leaves `load` empty, and the
    # -n test below then answers "no", which is the safe direction: a lane we cannot
    # prove is installed is skipped rather than restarted. The error text adds nothing.
    # No swallow needed: this is a READ, and the caller only asks "is it not-found".
    # An absent unit exits non-zero with empty output, which the -n test below
    # already answers as "not installed" — so nothing here hides a real failure.
    load=$(systemctl --user show "${1}.service" -p LoadState --value)
    [[ -n "$load" && "$load" != "not-found" ]]
}

# ============================================================
# Lane helpers — the lane set comes from the host profile (LLAMA_LANE_SPECS).
# ============================================================
# lane_key <unit> — the per-lane tag for the strike/flap files.  "llama-xe-..." ->
# "xe-..."; the gated lane does not use this (it keeps the "cuda" namespace).
lane_key() {
    local u="${1%.service}"
    printf '%s\n' "${u#llama-}"
}

# supervise_always_on <unit> <port> — the Xe/CPU/second-Xe shape: always-on, no GPU
# gate, bench-lock aware, 2-strike recovery, and its own flap counter (the v3.8
# lesson — a silently-restarted lane reads exactly like one that never missed a
# beat).  No cooling-off hold: that guards the dxgkrnl leak from repeated CUDA
# context cycles, and a non-CUDA lane has no such cost.
supervise_always_on() {
    local unit="$1" port="$2" key state h s
    key="$(lane_key "$unit")"
    local strike_file="$WATCHDOG_STRIKE_DIR/llama-watchdog-$key.strikes"
    local flap_file="$WATCHDOG_STRIKE_DIR/llama-watchdog-$key.flaps"
    if ! lane_present "$unit"; then
        log "$unit not installed on this host — skipping, not restarting"
        return 0
    fi
    state=$(systemctl --user show "$unit.service" -p ActiveState --value 2>/dev/null || true)
    health "$port"; h=$?
    if (( h == 0 )); then
        strike_reset "$strike_file"
    elif [[ "$state" == "activating" ]]; then
        log "$unit activating — systemd handling recovery; skipping"
        strike_reset "$strike_file"
    elif (( h == 2 )); then
        # 503 = process up, model still loading. Striking or bouncing a loading
        # unit only lengthens the outage (and can trip the start-limit).
        log "$unit still loading (503) — leaving alone"
        strike_reset "$strike_file"
    elif bench_lock; then
        log "$unit down but bench lock present — skipping restart"
    else
        strike_inc "$strike_file"
        s=$(strike_get "$strike_file")
        # An unexpected death: down, not mid-start, not loading, no bench holding us off.
        flap_record "$flap_file"
        flap_alert "$unit" "$flap_file" "the unit journal for the signaller"
        log "$unit health check failed on :${port} (unit=${state:-unknown}, strike ${s}/2)"
        if [[ "$s" -ge 2 ]]; then
            if recover "$unit" "$port"; then strike_reset "$strike_file"; fi
        else
            log "$unit strike 1/2 — will restart if next check also fails"
        fi
    fi
}
# ============================================================
# The gated lane — the profile's LLAMA_CUDA_LANE_UNIT.  Runs only while GPU free.
# ============================================================
supervise_cuda_lane() {
    CUDA_UNIT="$1"; CUDA_PORT="$2"
    if ! lane_present "$CUDA_UNIT"; then
        log "CUDA lane not installed on this host (CUDA_UNIT unit absent) — skipping, not restarting"
        return 0
    fi
    cuda_state=$(systemctl --user show "$CUDA_UNIT.service" -p ActiveState --value 2>/dev/null || true)
    if cuda_suspended; then
        # CUDA-only suspend: keep the CUDA lane down (and take it down if it is up).
        # Strikes reset so a resumed lane does not inherit strikes accrued while it
        # was deliberately stopped.
        if [[ "$cuda_state" == "active" ]]; then
            log "CUDA lane suspended — stopping $CUDA_UNIT (a deliberate suspend, not a fault)"
            if ! _stop_out=$(systemctl --user stop "$CUDA_UNIT.service" 2>&1)
            then
                log "WARNING: could not stop $CUDA_UNIT — the lane may still hold VRAM: ${_stop_out}"
            fi
        else
            log "CUDA lane suspended — held by live pid $(_tac_suspend_pid "$CUDA_SUSPEND_FILE");" \
                " not starting $CUDA_UNIT"
        fi
        # A suspend is its own deliberate stop; a stale GPU-busy marker must not
        # survive it and explain away the first real death after a resume.
        gpustop_clear
        strike_reset "$STRIKE_CUDA"
    elif gpu_busy; then
        # GPU in use by a declared workload -> free VRAM for it.
        #
        # This comment used to read "-> Xe lane serves (Wayne policy)", and the log line
        # below printed it as fact.  That was true when an Xe lane unit was installed and it
        # is FALSE on a host with none: measured 2026-11-04, `systemctl --user list-units
        # 'llama*'` lists the CUDA embedding lane, this chat lane and two watchdog units --
        # no Xe lane.  So the one line an operator reads after a kill asserted a replacement
        # that did not exist, while every fleet turn was failing over to the cloud model.
        # The STOP is the measurement; what serves afterwards is the gateway's business and
        # this script cannot see it, so it no longer claims to.
        # Before acting on "busy", say WHICH busy this is when the gate failed closed
        # for a driver-level reason (v3.13): the probe's own reason cannot distinguish
        # "a workload holds the card" from "the driver is gone", and those need
        # opposite responses from a human.  Rate-limited inside the helper (one probe
        # per hold window), and read-only — the stop/start decisions stay here.
        gpu_classify_driver_failclosed
        # A DRIVER-level fail-closed is the one "busy" that can be a probe blip
        # rather than a workload, and it must not park a running lane on a single
        # sample (v3.14 — see gpu_reprobe_free's header for the 2026-11-01
        # measurement).  Only the STOP is deferred here; the start gate below is
        # untouched and still fails closed.
        if gpu_driver_failclosed && [[ "$cuda_state" == "active" ]] && gpu_serving_now; then
            # v24: the probe cannot see the card, but the lane is answering 200 on its
            # own port.  That is evidence the STOP would destroy and cannot replace —
            # refused here regardless of what the (unreadable) probe says, and checked
            # BEFORE the re-probe so a wedged driver does not also pay 2x5s of sleeps.
            _msg="GPU reported busy driver-level [probe: $GPU_BUSY_REASONS]"
            log "$_msg but $CUDA_UNIT answers /health 200 on :${CUDA_PORT} — it is SERVING," \
                "so the stop is refused (an unreadable driver probe is not evidence the card is unusable)"
            strike_reset "$STRIKE_CUDA"
        elif gpu_driver_failclosed && [[ "$cuda_state" == "active" ]] && gpu_reprobe_free; then
            _msg="GPU reported busy driver-level [probe: $GPU_BUSY_REASONS]"
            log "$_msg but a re-probe found the card FREE — not stopping $CUDA_UNIT"
            gpustop_clear
            strike_reset "$STRIKE_CUDA"
        elif (( GPU_BUSY_PROBE_ERROR )) && [[ "$cuda_state" == "active" ]] && gpu_serving_now; then
            # LLM-LANE-STOP-001 option (b), accepted 2026-11-01: a probe that ERRORED is our
            # tooling failing (an unexpected rc, or rc 0 with no JSON), not an answer about the
            # card.  The verdict stays fail-closed for the START gate; here a lane already
            # SERVING is left alone, because a failed probe is not evidence the card is held and
            # this stop cannot be undone from here.  Measured 2026-11-02: 16 watchdog stops in
            # 24h, 9 ending 'Failed with result timeout', each 1.5-2.5 min after a start, with
            # 13 agents on hosted fallback every time.
            log "gpu-busy probe ERRORED (no usable answer) — but $CUDA_UNIT answers /health 200" \
                "on :${CUDA_PORT}, so the stop is refused (a failed probe is not a held card)"
            gpustop_clear
            strike_reset "$STRIKE_CUDA"
        else
            if [[ "$cuda_state" == "active" ]]; then
                log "GPU busy — stopping $CUDA_UNIT to free VRAM for the declared workload${GPU_BUSY_REASONS:+ [probe: $GPU_BUSY_REASONS]}"
                if ! _stop_out=$(systemctl --user stop "$CUDA_UNIT.service" 2>&1)
                then
                    log "WARNING: could not stop $CUDA_UNIT — the lane may still hold VRAM: ${_stop_out}"
                fi
            fi
            # Mark the stop as OURS, renewed on every busy tick.  Without this the next
            # tick where the card frees sees a down unit and counts the stop as an
            # UNEXPECTED death (v3.8), so three deliberate stops in an hour tripped the
            # flap alert and the 30min cooling-off — leaving the CUDA tier offline on an
            # idle card while the log blamed a dead lane that never died.
            gpustop_mark
            strike_reset "$STRIKE_CUDA"
        fi
    elif [[ "$cuda_state" == "active" ]]; then
        # The lane is up, so any pending marker has served its purpose (or is stale).
        gpustop_clear
        health "$CUDA_PORT"; cuda_health=$?
        if (( cuda_health == 0 )); then
            strike_reset "$STRIKE_CUDA"
        elif (( cuda_health == 2 )); then
            # Still loading (503) — do not strike or restart the CUDA lane.
            log "CUDA unit still loading (503) — leaving alone"
            strike_reset "$STRIKE_CUDA"
        else
            strike_inc "$STRIKE_CUDA"
            s=$(strike_get "$STRIKE_CUDA")
            log "CUDA health check failed on :${CUDA_PORT} (unit=${cuda_state}, strike ${s}/2)"
            if [[ "$s" -ge 2 ]]; then
                if recover "$CUDA_UNIT" "$CUDA_PORT"; then strike_reset "$STRIKE_CUDA"; fi
            fi
        fi
    elif [[ "$cuda_state" == "activating" ]]; then
        # systemd is already bringing the unit up (mirrors the Xe lane): issuing a
        # start would act on a unit that is mid-start.
        log "CUDA unit activating — systemd handling recovery; skipping"
        gpustop_clear
        strike_reset "$STRIKE_CUDA"
    else
        # GPU free but CUDA unit not active -> bring it up (it is the preferred lane when free)
        if bench_lock || gpu_claim_held; then
            log "GPU free but a bench holds the card — not starting $CUDA_UNIT yet"
        else
            # Down with a free card is USUALLY an unexpected death (v3.8) — but not if
            # WE stopped it for a foreign GPU owner and the card has since freed.  The
            # marker is SINGLE-USE: consuming it here means it can explain exactly one
            # restart and can never mask a genuine death afterwards.
            _held=0
            _counted=0
            if gpustop_active; then
                log "GPU free; the stop was ours for a foreign owner — restarting $CUDA_UNIT without recording a flap"
                gpustop_clear
            elif [[ -e "$FLAP_HOLD_FILE" ]] && flap_hold_active; then
                # A live cooling-off is a deliberate, bounded stop and THIS tick makes no
                # restart attempt, so there is no death to count.  v3.8 stamped one here
                # anyway (flap_record ran before the hold check), so a held lane earned a
                # fresh stamp every timer tick and the hold was re-armed at every expiry
                # by stamps it had written itself: a one-way ratchet that holds the CUDA
                # tier down with zero restart attempts.  Measured 2026-11-02 — stamps at
                # 02:44:50 / 02:47:12 / 02:57:27, hold entered 02:57:27, then 03:30:12
                # and 03:35:12 each logged "died 4x"/"5x" for a lane nothing had tried
                # to start, and 03:30:12 re-armed the hold for another 30 minutes.
                _held=1
            elif [[ -e "$FLAP_HOLD_FILE" ]]; then
                # Expired with the lane still down — but the hold is WHY it is down, so
                # that is not a death either.  Clear it and give the lane the restart
                # the hold owed it, without charging a stamp for the waiting.
                rm -f "$FLAP_HOLD_FILE"
                log "flap cooling-off ended — attempting one restart without counting a death"
            elif requested_stop_active "$CUDA_UNIT.service"; then
                # A LIVE gpu.lock holder asked for this stop: the investigator records
                # the request BEFORE its own `systemctl stop` (pipeline/gpu/_exclusive.py
                # :645), and its reader has no production callers — so until now the
                # console consulted only gpustop_active (OUR marker) and gpu_claim_held
                # (a probe of the PRESENT: the kernel drops the flock on release, so a
                # stop taken inside the claim's last seconds answers "free" to the very
                # next tick — the 02:46:58 -> 02:52:11 shape).  Count nothing, consume
                # the record so it can explain exactly ONE restart, and fall through to
                # the shared restart below: the lane is wanted back, the stop was not
                # a death.  Placed AFTER the hold arms on purpose — a live cooling-off
                # must still win, and an expired one still clears itself first.
                log "GPU free; the stop of $CUDA_UNIT was REQUESTED by a live claim" \
                    "(pid $REQSTOP_PID, ts=$REQSTOP_TS) — restarting without recording a flap"
                requested_stop_consume "$REQSTOP_TS" "$CUDA_UNIT"
            else
                # An unexpected death: down, card free, nothing suspending us.  Count it
                # BEFORE any recovery below so the alert and the action appear together.
                flap_record "$FLAP_CUDA"
                _counted=1
                flap_alert "$CUDA_UNIT" "$FLAP_CUDA" "bin/gpu-busy.sh --json for a foreign GPU owner"
            fi
            if (( _held )); then
                log "CUDA lane held down after repeated flaps — not starting $CUDA_UNIT (cooling-off; delete $FLAP_HOLD_FILE to lift it early)"
            elif (( _counted )) && (( $(flap_count "$FLAP_CUDA") >= FLAP_THRESHOLD )); then
                # At the threshold the restart STOPS.  A lane dying every few minutes is
                # either being evicted by something outside our control or is broken; in
                # both cases another context cycle makes it worse, not better.
                # ONLY a death recorded on THIS pass may enter a hold: a count made of
                # stale stamps describes the past, and re-arming from it was the other
                # half of the ratchet above.
                flap_hold_enter
            else
                if [[ "$cuda_state" == "failed" ]]; then
                    systemctl --user reset-failed "$CUDA_UNIT.service" 2>/dev/null || true
                fi
                log "GPU free and $CUDA_UNIT not active — starting CUDA lane"
                if systemctl --user start "$CUDA_UNIT.service" 2>/dev/null; then
                    if wait_healthy "$CUDA_PORT" 150; then
                        log "CUDA lane healthy on :${CUDA_PORT}"
                    else
                        log "CUDA lane started but not healthy on :${CUDA_PORT} within 150s"
                    fi
                else
                    log "Failed to start $CUDA_UNIT"
                fi
                strike_reset "$STRIKE_CUDA"
            fi
        fi
    fi
}
# ============================================================
# Dispatch — one lane per LLAMA_LANE_SPECS entry, from the host profile.
# The gated lane (LLAMA_CUDA_LANE_UNIT) takes supervise_cuda_lane; every other
# lane is always-on.  The former LANE 1/3/4 bodies are supervise_always_on above.
# ============================================================
while IFS='|' read -r _unit _port
do
    [[ -n "$_unit" ]] || continue
    _unit="${_unit%.service}"
    if [[ -n "$CUDA_LANE_UNIT" && "$_unit" == "$CUDA_LANE_UNIT" ]]; then
        supervise_cuda_lane "$_unit" "$_port"
    else
        supervise_always_on "$_unit" "$_port"
    fi
done <<< "$LANE_SPECS"

# Assert the window invariant on every lane that is up (2026-09-14).  This is
# the check that would have caught the registry's parallel=16 dividing every
# served window, and that catches a --fit or --parallel drift on a unit.
while IFS='|' read -r _unit _port
do
    [[ -n "$_unit" ]] || continue
    window_check "${_unit%.service}" "$_port"
done <<< "$LANE_SPECS"

exit 0

# end of file
