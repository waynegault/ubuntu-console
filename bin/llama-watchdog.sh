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
# Recovery goes through systemctl --user restart/stop/start so the unit's
# ExecStartPre GPU-clear and tuned parameters are preserved. Never pkill/spawn
# directly. The Xe unit is boot-enabled and gateway-managed (always-on).
# LIMITATION: llama.cpp /health answers 200 while a decode thread is hung on a
# GPU fault, so decode-hangs are bounded by gateway provider timeouts (idea 2),
# not by this script; this script recovers process death / start-limit states.
# AI: Do not add streaming, partial-offload, or auto-download logic to this script.
# AI INSTRUCTION: Increment version on significant changes.
# shellcheck disable=SC2034  # VERSION is read by external tooling, not this script
VERSION="3.1"
set -uo pipefail

# Prevent concurrent runs (timer could fire while a slow restart is in progress).
# Cleanup is inlined into the trap (rather than a named function) so shellcheck
# does not flag the body as unreachable (SC2317) for a function invoked only by
# trap; a suppression comment would be the wrong fix.
trap 'flock -u 200 2>/dev/null || true; rm -f /dev/shm/llama-watchdog.lock 2>/dev/null || true' EXIT INT TERM

exec 200>/dev/shm/llama-watchdog.lock
flock -n 200 || { echo "$(date '+%Y-%m-%d %H:%M:%S') [watchdog] Another instance running - skipping"; exit 0; }

# -- Shared constants --
# Canonical port default kept in the LLM_SERVICE_PORT=... form the cross-script
# contract check parses; the lanes alias it below.
LLM_SERVICE_PORT="${LLM_SERVICE_PORT:-18081}"
XE_PORT="$LLM_SERVICE_PORT"
XE_UNIT="llama-server"
NV_PORT="${LLM_NVIDIA_PORT:-18083}"
NV_UNIT="llama-server-nvidia"
STRIKE_XE="/dev/shm/llama-watchdog-xe.strikes"
STRIKE_NV="/dev/shm/llama-watchdog-nv.strikes"

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

strike_get() { cat "$1" 2>/dev/null || echo 0; }
strike_reset() { printf '0\n' > "$1" 2>/dev/null || true; }
strike_inc() {
    local f="$1" n; n=$(strike_get "$f"); n=$((n+1)); printf '%s\n' "$n" > "$f" 2>/dev/null || true
}

gpu_busy() {
    local j; j=$("$HOME/.local/bin/gpu-busy.sh" --json 2>/dev/null || true)
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
