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
#   llama-xe-qwen25-3b-chat.service (:18085).  Same card as LANE 1, so it takes
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
# Recovery goes through systemctl --user restart/stop/start so the unit's
# ExecStartPre GPU-clear and tuned parameters are preserved. Never pkill/spawn
# directly. The Xe unit is boot-enabled and gateway-managed (always-on).
# LIMITATION: llama.cpp /health answers 200 while a decode thread is hung on a
# GPU fault, so decode-hangs are bounded by gateway provider timeouts (idea 2),
# not by this script; this script recovers process death / start-limit states.
# AI: Do not add streaming, partial-offload, or auto-download logic to this script.
# AI INSTRUCTION: Increment version on significant changes.
# Module Version: 11
#   Bump counter for tools/check-module-versions.sh, which parses exactly this
#   line (it is what makes an edit here fail the pre-commit guard until the
#   number moves).  Deliberately separate from VERSION= below: the marker
#   changes on ANY edit, VERSION= on significant ones (it is what --version
#   prints).  Added 2026-09-14 — until then this was the only GPU-adjacent
#   script in the repo outside the version guard.
VERSION="3.13"

# --version works without taking the lock (diagnostic; also keeps VERSION used).
if [[ "${1:-}" == "--version" || "${1:-}" == "-V" ]]; then
    echo "llama-watchdog $VERSION"
    exit 0
fi
set -uo pipefail

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
# Canonical port default kept in the LLM_SERVICE_PORT=... form the cross-script
# contract check parses; the lanes alias it below.
LLM_SERVICE_PORT="${LLM_SERVICE_PORT:-18081}"
XE_PORT="$LLM_SERVICE_PORT"
# Card-first unit names (see docs/llm.md's card map).  Kept suffix-less because
# systemd resolves a bare name to its .service, and these are used both as
# `systemctl` arguments and in log lines.
XE_UNIT="llama-xe-minicpm5-1b-chat"
CUDA_PORT="${LLM_CUDA_PORT:-18083}"
CUDA_UNIT="llama-cuda-llama32-3b-chat"
# The CPU tier (v3.10) holds no card — it is the tail of the chain — so it takes
# no gpu_busy/suspend gate, but it is bench-lock aware like the Xe lane.
CPU_PORT="${LLM_CPU_PORT:-18084}"
CPU_UNIT="llama-cpu-qwen25-3b-chat"
# The second Xe lane (v3.11).  Card-first sibling of XE_UNIT: same Xe/OpenCL card,
# different model, so it takes the Xe lane's shape rather than the CUDA lane's.
XE3B_PORT="${LLM_XE3B_PORT:-18085}"
XE3B_UNIT="llama-xe-qwen25-3b-chat"
STRIKE_XE="$WATCHDOG_STRIKE_DIR/llama-watchdog-xe.strikes"
STRIKE_CUDA="$WATCHDOG_STRIKE_DIR/llama-watchdog-cuda.strikes"
STRIKE_CPU="$WATCHDOG_STRIKE_DIR/llama-watchdog-cpu.strikes"
STRIKE_XE3B="$WATCHDOG_STRIKE_DIR/llama-watchdog-xe3b.strikes"
# CUDA flap detection (v3.8).  One epoch-seconds stamp per unexpected CUDA-lane
# death, pruned to FLAP_WINDOW_S; nothing else reads this file.  Env-overridable
# like the strike/lock paths so the integration suite can sandbox it — a flap
# count that leaked between test cases would make the warnings untrustworthy.
FLAP_CUDA="${LLAMA_WATCHDOG_CUDA_FLAP_FILE:-$WATCHDOG_STRIKE_DIR/llama-watchdog-cuda.flaps}"
# The CPU lane's own counter.  Same rolling window and threshold; no hold file —
# see the v3.10 note in the header for why the CUDA cooling-off must not be copied.
FLAP_CPU="${LLAMA_WATCHDOG_CPU_FLAP_FILE:-$WATCHDOG_STRIKE_DIR/llama-watchdog-cpu.flaps}"
# The second Xe lane's counter.  Same rolling window and threshold; no hold file —
# see the v3.11 note in the header for why the CUDA cooling-off must not be copied.
FLAP_XE3B="${LLAMA_WATCHDOG_XE3B_FLAP_FILE:-$WATCHDOG_STRIKE_DIR/llama-watchdog-xe3b.flaps}"
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

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [watchdog] $*"; }

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
gpustop_clear() { rm -f "$CUDA_GPUSTOP_FILE" 2>/dev/null || true; }

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
            _msg+=" The lane is down on a DRIVER fault, not on a workload: the Xe lane serves,"
            _msg+=" and the fix is host-side (wsl --shutdown / GPU driver update)."
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

# cuda_suspended — the CUDA lane is held down on purpose (a bench/autotune run is
# measuring TPS and wants the card to itself).  Scoped to the CUDA lane only:
# unlike bench_lock it must NOT suppress Xe recovery.
cuda_suspended() { [[ -f "$CUDA_SUSPEND_FILE" ]]; }

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
    local unit="$1" port="$2" state
    state=$(systemctl --user show "$unit.service" -p ActiveState --value 2>/dev/null || true)
    if [[ "$state" == "failed" ]]; then
        systemctl --user reset-failed "$unit.service" 2>/dev/null || true
    fi
    if ! systemctl --user restart "$unit.service" 2>/dev/null; then
        systemctl --user start "$unit.service" 2>/dev/null || { log "recover failed for $unit"; return 1; }
    fi
    log "Restart issued: $unit"
    if wait_healthy "$port" 150; then
        log "Recovery successful — $unit healthy on :${port}"
        return 0
    fi
    log "Recovery failed: $unit not healthy on :${port} within 150s"
    return 1
}

# ============================================================
# LANE 1: Xe llama-server — always-on
# ============================================================
xe_state=$(systemctl --user show "$XE_UNIT.service" -p ActiveState --value 2>/dev/null || true)
health "$XE_PORT"; xe_health=$?
if (( xe_health == 0 )); then
    strike_reset "$STRIKE_XE"
elif [[ "$xe_state" == "activating" ]]; then
    log "Xe unit activating — systemd handling recovery; skipping"
    strike_reset "$STRIKE_XE"
elif (( xe_health == 2 )); then
    # 503 = process up, model still loading. Striking or bouncing a loading
    # unit only lengthens the outage (and can trip the start-limit).
    log "Xe unit still loading (503) — leaving alone"
    strike_reset "$STRIKE_XE"
elif bench_lock; then
    log "Xe down but bench lock present — skipping restart (port may be claimed)"
else
    strike_inc "$STRIKE_XE"
    s=$(strike_get "$STRIKE_XE")
    log "Xe health check failed on :${XE_PORT} (unit=${xe_state:-unknown}, strike ${s}/2)"
    if [[ "$s" -ge 2 ]]; then
        if recover "$XE_UNIT" "$XE_PORT"; then strike_reset "$STRIKE_XE"; fi
    else
        log "Xe strike 1/2 — will restart if next check also fails"
    fi
fi

# ============================================================
# LANE 2: CUDA card — llama-cuda-llama32-3b-chat — runs only while GPU free
# ============================================================
cuda_state=$(systemctl --user show "$CUDA_UNIT.service" -p ActiveState --value 2>/dev/null || true)
if cuda_suspended; then
    # CUDA-only suspend: keep the CUDA lane down (and take it down if it is up).
    # Strikes reset so a resumed lane does not inherit strikes accrued while it
    # was deliberately stopped.
    if [[ "$cuda_state" == "active" ]]; then
        log "CUDA lane suspended — stopping $CUDA_UNIT (freeing VRAM; Xe lane serves)"
        systemctl --user stop "$CUDA_UNIT.service" 2>/dev/null || true
    else
        log "CUDA lane suspended ($CUDA_SUSPEND_FILE present) — not starting $CUDA_UNIT yet"
    fi
    # A suspend is its own deliberate stop; a stale GPU-busy marker must not
    # survive it and explain away the first real death after a resume.
    gpustop_clear
    strike_reset "$STRIKE_CUDA"
elif gpu_busy; then
    # GPU in use by foreign workload -> Xe lane serves (Wayne policy)
    # Before acting on "busy", say WHICH busy this is when the gate failed closed
    # for a driver-level reason (v3.13): the probe's own reason cannot distinguish
    # "a workload holds the card" from "the driver is gone", and those need
    # opposite responses from a human.  Rate-limited inside the helper (one probe
    # per hold window), and read-only — the stop/start decisions stay here.
    gpu_classify_driver_failclosed
    if [[ "$cuda_state" == "active" ]]; then
        log "GPU busy — stopping $CUDA_UNIT (freeing VRAM; Xe lane serves)${GPU_BUSY_REASONS:+ [probe: $GPU_BUSY_REASONS]}"
        systemctl --user stop "$CUDA_UNIT.service" 2>/dev/null || true
    fi
    # Mark the stop as OURS, renewed on every busy tick.  Without this the next
    # tick where the card frees sees a down unit and counts the stop as an
    # UNEXPECTED death (v3.8), so three deliberate stops in an hour tripped the
    # flap alert and the 30min cooling-off — leaving the CUDA tier offline on an
    # idle card while the log blamed a dead lane that never died.
    gpustop_mark
    strike_reset "$STRIKE_CUDA"
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
    if bench_lock; then
        log "GPU free but bench lock present — not starting $CUDA_UNIT yet"
    else
        # Down with a free card is USUALLY an unexpected death (v3.8) — but not if
        # WE stopped it for a foreign GPU owner and the card has since freed.  The
        # marker is SINGLE-USE: consuming it here means it can explain exactly one
        # restart and can never mask a genuine death afterwards.
        if gpustop_active; then
            log "GPU free; the stop was ours for a foreign owner — restarting $CUDA_UNIT without recording a flap"
            gpustop_clear
        else
            # An unexpected death: down, card free, nothing suspending us.  Count it
            # BEFORE any recovery below so the alert and the action appear together.
            flap_record "$FLAP_CUDA"
            flap_alert "$CUDA_UNIT" "$FLAP_CUDA" "bin/gpu-busy.sh --json for a foreign GPU owner"
        fi
        if flap_hold_active; then
            log "CUDA lane held down after repeated flaps — not starting $CUDA_UNIT (cooling-off; delete $FLAP_HOLD_FILE to lift it early)"
        elif (( $(flap_count "$FLAP_CUDA") >= FLAP_THRESHOLD )); then
            # At the threshold the restart STOPS.  A lane dying every few minutes is
            # either being evicted by something outside our control or is broken; in
            # both cases another context cycle makes it worse, not better.
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

# ============================================================
# LANE 3: CPU — llama-cpu-qwen25-3b-chat — the chain's tail, no card
# ============================================================
# Deliberately the same shape as the Xe lane (always-on, 2-strike, bench-lock
# aware) and not the CUDA lane's: there is no card to gate on, no VRAM to free
# and no foreign owner to defer to, so "is it up?" is the whole question.  What
# this lane exists for is the case systemd CANNOT cover — Restart=always returns
# the process after a kill, but systemd stops trying once the unit trips
# StartLimitBurst and parks it in `failed`, which is exactly the state this tier
# was found in after its four kills, with nothing left to lift it.
cpu_state=$(systemctl --user show "$CPU_UNIT.service" -p ActiveState --value 2>/dev/null || true)
health "$CPU_PORT"; cpu_health=$?
if (( cpu_health == 0 )); then
    strike_reset "$STRIKE_CPU"
elif [[ "$cpu_state" == "activating" ]]; then
    log "CPU unit activating — systemd handling recovery; skipping"
    strike_reset "$STRIKE_CPU"
elif (( cpu_health == 2 )); then
    log "CPU unit still loading (503) — leaving alone"
    strike_reset "$STRIKE_CPU"
elif bench_lock; then
    log "CPU down but bench lock present — skipping restart"
else
    strike_inc "$STRIKE_CPU"
    s=$(strike_get "$STRIKE_CPU")
    # An unexpected death: down, not mid-start, not loading, nothing holding us off.
    flap_record "$FLAP_CPU"
    flap_alert "$CPU_UNIT" "$FLAP_CPU" "the unit journal for the signaller (this lane holds no card, so a GPU sweep cannot explain it)"
    log "CPU health check failed on :${CPU_PORT} (unit=${cpu_state:-unknown}, strike ${s}/2)"
    if [[ "$s" -ge 2 ]]; then
        if recover "$CPU_UNIT" "$CPU_PORT"; then strike_reset "$STRIKE_CPU"; fi
    else
        log "CPU strike 1/2 — will restart if next check also fails"
    fi
fi

# ============================================================
# LANE 4: Xe (second lane) — llama-xe-qwen25-3b-chat — always-on, same card as LANE 1
# ============================================================
# LANE 1's shape, deliberately, and not the CUDA lane's: this unit is on the SAME
# Xe/OpenCL card as LANE 1, so the gpu_busy/suspend gate is the wrong question — it
# asks whether the NVIDIA card is free, and a lane that never touches that card
# cannot be deferred to by it.  There is no VRAM to free here either, so "is it up?"
# is again the whole question, with the bench lock as the one gate.  The unit ran
# enabled with Restart=always and still sat `failed` for 22h because StartLimitBurst
# (6 in 600s) parks it and nothing lifted it — the same gap LANE 3 exists to close.
xe3b_state=$(systemctl --user show "$XE3B_UNIT.service" -p ActiveState --value 2>/dev/null || true)
health "$XE3B_PORT"; xe3b_health=$?
if (( xe3b_health == 0 )); then
    strike_reset "$STRIKE_XE3B"
elif [[ "$xe3b_state" == "activating" ]]; then
    log "Xe3B unit activating — systemd handling recovery; skipping"
    strike_reset "$STRIKE_XE3B"
elif (( xe3b_health == 2 )); then
    log "Xe3B unit still loading (503) — leaving alone"
    strike_reset "$STRIKE_XE3B"
elif bench_lock; then
    log "Xe3B down but bench lock present — skipping restart"
else
    strike_inc "$STRIKE_XE3B"
    s=$(strike_get "$STRIKE_XE3B")
    # An unexpected death: down, not mid-start, not loading, no bench holding us off.
    # The hint names the two sweeps on record for this box; a clean stop (success/0) is
    # what a hosted bench or a VRAM sweep looks like, and neither is a fault in the lane.
    flap_record "$FLAP_XE3B"
    flap_alert "$XE3B_UNIT" "$FLAP_XE3B" "docs/llm.md's bench-vs-lane note (a hosted bench session or a VRAM sweep stops lanes by name)"
    log "Xe3B health check failed on :${XE3B_PORT} (unit=${xe3b_state:-unknown}, strike ${s}/2)"
    if [[ "$s" -ge 2 ]]; then
        if recover "$XE3B_UNIT" "$XE3B_PORT"; then strike_reset "$STRIKE_XE3B"; fi
    else
        log "Xe3B strike 1/2 — will restart if next check also fails"
    fi
fi

# Assert the window invariant on every lane that is up (2026-09-14).  This is
# the check that would have caught the registry's parallel=16 dividing every
# served window, and that catches a --fit or --parallel drift on a unit.
window_check "$XE_UNIT" "$XE_PORT"
window_check "$CUDA_UNIT" "$CUDA_PORT"
window_check "$CPU_UNIT" "$CPU_PORT"
window_check "$XE3B_UNIT" "$XE3B_PORT"

exit 0

# end of file
