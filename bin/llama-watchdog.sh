#!/usr/bin/env bash
# llama-watchdog.sh — Check llama-server health; restart from active profile if down.
# Called by systemd user timer. Reads /dev/shm state to know which model to restart.
# AI: Do not add streaming, partial-offload, or auto-download logic to this script.
# AI INSTRUCTION: Increment version on significant changes.
# shellcheck disable=SC2034
VERSION="1.1"
set -euo pipefail

# Prevent concurrent runs (timer could fire while a slow restart is in progress).
# Lock in /dev/shm (tmpfs) — cleared on reboot, no stale lock persistence.
exec 200>/dev/shm/llama-watchdog.lock
flock -n 200 || { echo "$(date '+%Y-%m-%d %H:%M:%S') [watchdog] Another instance running — skipping"; exit 0; }

LLM_PORT="${LLM_PORT:-8081}"
ACTIVE_LLM_FILE="/dev/shm/active_llm"
LLM_LOG_FILE="/dev/shm/llama-server.log"
LLM_REGISTRY="${LLM_REGISTRY:-/mnt/m/.llm/models.conf}"
LLAMA_MODEL_DIR="${LLAMA_MODEL_DIR:-/mnt/m/active}"
LLAMA_SERVER_BIN="${LLAMA_SERVER_BIN:-/home/wayne/llama.cpp/build/bin/llama-server}"
LLAMA_CPU_THREADS="${LLAMA_CPU_THREADS:-12}"
LLAMA_CTX_SIZE="${LLAMA_CTX_SIZE:-4096}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [watchdog] $*"; }

# If no model was ever started, nothing to do
if [[ ! -f "$ACTIVE_LLM_FILE" ]]; then
    exit 0
fi

# If healthy, nothing to do
if curl -sf --max-time 5 "http://127.0.0.1:${LLM_PORT}/health" >/dev/null 2>&1; then
    exit 0
fi

log "Health check failed. Attempting restart..."

# Active LLM file stores model number (matches registry $1 field)
active_num=$(< "$ACTIVE_LLM_FILE")
if [[ -z "$active_num" || ! "$active_num" =~ ^[0-9]+$ ]]; then
    log "Invalid or empty model number in active state file."
    exit 1
fi

# Look up model from registry by number
# Registry format: num|name|file|size|arch|quant|layers|gpu_layers|ctx|threads|tps
entry=$(awk -F'|' -v n="$active_num" '$1 == n' "$LLM_REGISTRY" 2>/dev/null)
if [[ -z "$entry" ]]; then
    log "Model #$active_num not found in registry."
    exit 1
fi

IFS='|' read -r _num name file size _arch _quant layers gpu_layers ctx threads _tps <<< "$entry"
model_path="$LLAMA_MODEL_DIR/$file"

if [[ ! -f "$model_path" ]]; then
    log "Model file '$file' not found."
    exit 1
fi

use_gpu="${gpu_layers:-0}"
use_ctx="${ctx:-$LLAMA_CTX_SIZE}"
use_threads="${threads:-$LLAMA_CPU_THREADS}"

# Kill any zombie process (exact match avoids hitting unrelated processes)
pkill -x llama-server 2>/dev/null || true
sleep 1

cmd=("$LLAMA_SERVER_BIN" "-m" "$model_path" "--port" "$LLM_PORT" "--host" "127.0.0.1")
cmd+=("--ctx-size" "$use_ctx" "--mlock" "--prio" "2" "--cont-batching" "--parallel" "1" "--jinja")
if (( use_gpu > 0 )); then
    # Use -ngl 999 to let llama.cpp offload the maximum layers that fit in VRAM.
    # Larger batches improve prompt eval speed when GPU is active.
    batch_size=512; ubatch_size=512
    if (( use_gpu >= ${layers:-0} )); then
        batch_size=4096; ubatch_size=1024
    fi
    cmd+=("--batch-size" "$batch_size" "--ubatch-size" "$ubatch_size")
    cmd+=("--n-gpu-layers" "999" "--flash-attn" "on" "--threads" "$use_threads")
else
    cmd+=("--batch-size" "512" "--ubatch-size" "512")
    cmd+=("--n-gpu-layers" "0" "--threads" "$use_threads")
    cmd+=("--cache-type-k" "q8_0" "--cache-type-v" "q8_0")
fi

nohup "${cmd[@]}" >> "$LLM_LOG_FILE" 2>&1 &

# Wait for health — CPU-only models over drvfs (9p) can take 60-90s to mmap
health_timeout=30
(( use_gpu == 0 )) && health_timeout=90
for (( _hw=0; _hw < health_timeout; _hw++ )); do
    if curl -sf --max-time 2 "http://127.0.0.1:${LLM_PORT}/health" >/dev/null 2>&1; then
        log "Restart successful: $name ($size)"
        exit 0
    fi
    sleep 1
done

log "Restart failed: server did not become healthy in ${health_timeout}s"
exit 1
