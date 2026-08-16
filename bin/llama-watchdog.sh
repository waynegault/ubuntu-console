#!/usr/bin/env bash
# llama-watchdog.sh - Check llama-server health; restart the llama-server.service
# unit if down. Called by systemd user timer.
# Recovery goes through systemctl --user restart so the unit's ExecStartPre
# GPU-clear and tuned parameters are preserved. Never pkill/spawn directly.
# The unit is boot-enabled and gateway-managed (always-on); a deliberate stop
# is not a normal flow, so stop the timer first if a sustained stop is needed.
# AI: Do not add streaming, partial-offload, or auto-download logic to this script.
# AI INSTRUCTION: Increment version on significant changes.
# shellcheck disable=SC2034  # VERSION is read by external tooling, not this script
VERSION="2.9"  # GPU-busy gate: defer restart while bench/foreign workload uses GPU.
set -euo pipefail

# Prevent concurrent runs (timer could fire while a slow restart is in progress).
# Lock in /dev/shm (tmpfs) - cleared on reboot, no stale lock persistence.

# Cleanup function to release lock explicitly on exit/interrupt
# shellcheck disable=SC2317  # Called via trap, not directly invoked
cleanup() {
    flock -u 200 2>/dev/null || true
    rm -f /dev/shm/llama-watchdog.lock 2>/dev/null || true
}
trap cleanup EXIT INT TERM

exec 200>/dev/shm/llama-watchdog.lock
flock -n 200 || { echo "$(date '+%Y-%m-%d %H:%M:%S') [watchdog] Another instance running - skipping"; exit 0; }

# -- Shared constants (canonical values live in tactical-console.bashrc §1) --
# Production runs as systemd llama-server.service on LLM_SERVICE_PORT (18081).
# Autotune's scratch port (AUTOTUNE_PORT, 18082) is separate — never probed here.
LLM_SERVICE_PORT="${LLM_SERVICE_PORT:-18081}"
LLM_SERVICE_UNIT="${LLM_SERVICE_UNIT:-llama-server}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [watchdog] $*"; }

llm_healthy() {
    curl -sf --max-time 5 "http://127.0.0.1:${LLM_SERVICE_PORT}/health" >/dev/null 2>&1 ||
        curl -sf --max-time 5 "http://127.0.0.1:${LLM_SERVICE_PORT}/v1/models" >/dev/null 2>&1
}

# If healthy, nothing to do
if llm_healthy
then
    exit 0
fi

# If bench/autotune is running, skip restart to avoid port conflict (ca23ec0a)
bench_lock="${LLM_BENCH_LOCK_FILE:-/tmp/llm-bench.lock}"
if [[ -f "$bench_lock" ]]
then
    log "Bench lock present ($bench_lock) — skipping restart (port may be claimed by autotune)"
    exit 0
fi

# GPU gate (2026-08-16): if the GPU is actually in use by a foreign workload
# (investigator bench, autotune, clear_vram) or utilization is high, defer the
# restart — llama-server would just be killed/evicted again (bench does
# pkill -9 between models). Restart only when the GPU is truly free.
# Note: gpu-busy.sh exits 1 when busy, so judge the JSON output — with
# pipefail the pipeline exit status would mask the match.
GPU_BUSY_SH="${GPU_BUSY_SH:-$HOME/.local/bin/gpu-busy.sh}"
if [[ -x "$GPU_BUSY_SH" ]]
then
    gpu_busy_json=$("$GPU_BUSY_SH" --json 2>/dev/null || true)
    if grep -q '"busy":true' <<< "$gpu_busy_json"
    then
        log "GPU busy (bench/foreign workload) — deferring restart until GPU is clear"
        exit 0
    fi
fi

# Read the unit state. "activating" means systemd is already restarting the
# unit (Restart=always crash loop) — do not stack a second restart on top.
state=$(systemctl --user show "$LLM_SERVICE_UNIT.service" -p ActiveState --value 2>/dev/null || true)
log "Health check failed on :${LLM_SERVICE_PORT} (unit ActiveState=${state:-unknown}). Attempting recovery..."

if [[ "$state" == "activating" ]]
then
    log "Unit already activating — systemd is handling recovery; skipping"
    exit 0
fi

# A failed unit means systemd gave up (start-limit hit) — clear the limit
# before restarting, otherwise the restart is refused.
if [[ "$state" == "failed" ]]
then
    systemctl --user reset-failed "$LLM_SERVICE_UNIT.service" 2>/dev/null || true
fi

if ! systemctl --user restart "$LLM_SERVICE_UNIT.service"
then
    log "systemctl restart failed — unit not recoverable; manual intervention required"
    exit 1
fi
log "Restart issued: systemctl --user restart $LLM_SERVICE_UNIT.service"

# Wait for health. GPU models usually load in <30s; be generous (the unit
# itself allows 600s), and let the next timer tick re-check on failure.
health_timeout="${LLM_WATCHDOG_HEALTH_TIMEOUT:-120}"
for (( _hw=0; _hw < health_timeout; _hw++ ))
do
    if llm_healthy
    then
        log "Recovery successful — llama-server healthy on :${LLM_SERVICE_PORT}"
        exit 0
    fi
    sleep 1
done

log "Recovery failed: server did not become healthy in ${health_timeout}s"
exit 1

# end of file
