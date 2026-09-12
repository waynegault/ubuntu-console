#!/usr/bin/env bash
# llama-watchdog.sh - Check local llama-server lanes; recover when unhealthy.
# v3.0 (2026-09-09): dual-unit management + 2-strike restart + GPU-gated CUDA lane.
#   - llama-server.service        (Xe OpenCL,  :18081)  always-on baseline lane
#   - llama-server-nvidia.service (CUDA,       :18083)  runs ONLY while GPU is free;
#     stopped when GPU busy (foreign workload) so VRAM is freed and gateway
#     requests fail fast to the Xe lane (per Wayne 09-09: "if cuda is not being
#     used, it can be used; if it is being used, use xe").
# v3.1 (2026-09-11): honour health()'s 503 "still loading" signal — a loading
#   lane is neither struck nor restarted; drop a redundant re-probe that could
#   swallow a recovery without resetting strikes.
# v3.2 (2026-09-12): NV lane skips a unit that systemd is already activating
#   (mirrors the Xe lane) instead of issuing a start on a mid-start unit.
# v3.3 (2026-09-12): gpu_busy FAILS CLOSED — a failed/empty probe is treated as
#   BUSY, so the CUDA lane is never started on a GPU we cannot prove free; strike
#   read/write failures now warn instead of silently disabling recovery; add
#   --version (also removes the now-unneeded SC2034 suppression for VERSION).
# Recovery goes through systemctl --user restart/stop/start so the unit's
# ExecStartPre GPU-clear and tuned parameters are preserved. Never pkill/spawn
# directly. The Xe unit is boot-enabled and gateway-managed (always-on).
# LIMITATION: llama.cpp /health answers 200 while a decode thread is hung on a
# GPU fault, so decode-hangs are bounded by gateway provider timeouts (idea 2),
# not by this script; this script recovers process death / start-limit states.
# AI: Do not add streaming, partial-offload, or auto-download logic to this script.
# AI INSTRUCTION: Increment version on significant changes.
VERSION="3.3"

# --version works without taking the lock (diagnostic; also keeps VERSION used).
if [[ "${1:-}" == "--version" || "${1:-}" == "-V" ]]; then
    echo "llama-watchdog $VERSION"
    exit 0
fi
set -uo pipefail

# Prevent concurrent runs (timer could fire while a slow restart is in progress).
# Cleanup is inlined into the trap (rather than a named function) so shellcheck
# does not flag the body as unreachable (SC2317) for a function invoked only by
# trap; a suppression comment would be the wrong fix.
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
XE_UNIT="llama-server"
NV_PORT="${LLM_NVIDIA_PORT:-18083}"
NV_UNIT="llama-server-nvidia"
STRIKE_XE="$WATCHDOG_STRIKE_DIR/llama-watchdog-xe.strikes"
STRIKE_NV="$WATCHDOG_STRIKE_DIR/llama-watchdog-nv.strikes"

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

# gpu_busy — 0 (busy) when a foreign workload holds the GPU. FAILS CLOSED: if the
# probe is missing/fails/returns nothing we cannot prove the GPU is free, so we
# treat it as BUSY and the CUDA lane is not started (matches the policy above).
GPU_BUSY_PROBE_WARNED=0
gpu_busy() {
    local j
    if ! j=$("$HOME/.local/bin/gpu-busy.sh" --json 2>/dev/null); then
        if (( GPU_BUSY_PROBE_WARNED == 0 )); then
            log "WARNING: gpu-busy.sh probe failed — treating GPU as BUSY (CUDA lane will not start)"
            GPU_BUSY_PROBE_WARNED=1
        fi
        return 0
    fi
    if [[ -z "$j" ]]; then
        if (( GPU_BUSY_PROBE_WARNED == 0 )); then
            log "WARNING: gpu-busy.sh returned no output — treating GPU as BUSY (CUDA lane will not start)"
            GPU_BUSY_PROBE_WARNED=1
        fi
        return 0
    fi
    grep -q '"busy":true' <<< "$j"
}

bench_lock() { [[ -f "${LLM_BENCH_LOCK_FILE:-/tmp/llm-bench.lock}" ]]; }

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
# LANE 2: CUDA llama-server-nvidia — runs only while GPU free
# ============================================================
nv_state=$(systemctl --user show "$NV_UNIT.service" -p ActiveState --value 2>/dev/null || true)
if gpu_busy; then
    # GPU in use by foreign workload -> Xe lane serves (Wayne policy)
    if [[ "$nv_state" == "active" ]]; then
        log "GPU busy — stopping $NV_UNIT (freeing VRAM; Xe lane serves)"
        systemctl --user stop "$NV_UNIT.service" 2>/dev/null || true
    fi
    strike_reset "$STRIKE_NV"
elif [[ "$nv_state" == "active" ]]; then
    health "$NV_PORT"; nv_health=$?
    if (( nv_health == 0 )); then
        strike_reset "$STRIKE_NV"
    elif (( nv_health == 2 )); then
        # Still loading (503) — do not strike or restart the CUDA lane.
        log "CUDA unit still loading (503) — leaving alone"
        strike_reset "$STRIKE_NV"
    else
        strike_inc "$STRIKE_NV"
        s=$(strike_get "$STRIKE_NV")
        log "CUDA health check failed on :${NV_PORT} (unit=${nv_state}, strike ${s}/2)"
        if [[ "$s" -ge 2 ]]; then
            if recover "$NV_UNIT" "$NV_PORT"; then strike_reset "$STRIKE_NV"; fi
        fi
    fi
elif [[ "$nv_state" == "activating" ]]; then
    # systemd is already bringing the unit up (mirrors the Xe lane): issuing a
    # start would act on a unit that is mid-start.
    log "CUDA unit activating — systemd handling recovery; skipping"
    strike_reset "$STRIKE_NV"
else
    # GPU free but CUDA unit not active -> bring it up (it is the preferred lane when free)
    if bench_lock; then
        log "GPU free but bench lock present — not starting $NV_UNIT yet"
    else
        if [[ "$nv_state" == "failed" ]]; then
            systemctl --user reset-failed "$NV_UNIT.service" 2>/dev/null || true
        fi
        log "GPU free and $NV_UNIT not active — starting CUDA lane"
        if systemctl --user start "$NV_UNIT.service" 2>/dev/null; then
            if wait_healthy "$NV_PORT" 150; then
                log "CUDA lane healthy on :${NV_PORT}"
            else
                log "CUDA lane started but not healthy on :${NV_PORT} within 150s"
            fi
        else
            log "Failed to start $NV_UNIT"
        fi
        strike_reset "$STRIKE_NV"
    fi
fi

exit 0

# end of file
