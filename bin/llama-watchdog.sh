#!/usr/bin/env bash
# llama-watchdog.sh — Check llama-server health; restart from active profile if down.
# Called by systemd user timer. Reads /dev/shm state to know which model to restart.
set -euo pipefail

LLM_PORT="${LLM_PORT:-8081}"
ACTIVE_LLM_FILE="/dev/shm/active_llm"
LLM_LOG_FILE="/dev/shm/llama-server.log"
LLM_REGISTRY="${LLM_REGISTRY:-/home/wayne/.llm/models.conf}"
LLAMA_MODEL_DIR="${LLAMA_MODEL_DIR:-/home/wayne/llama.cpp/models}"
LLAMA_SERVER_BIN="${LLAMA_SERVER_BIN:-/home/wayne/llama.cpp/build/bin/llama-server}"
LLAMA_GPU_LAYERS="${LLAMA_GPU_LAYERS:-33}"
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

IFS='|' read -r prof name size proc < "$ACTIVE_LLM_FILE"
if [[ -z "$prof" ]]; then
    log "No profile in active state file."
    exit 1
fi

# Look up model file from registry
entry=$(awk -F'|' -v p="$prof" '$1 == p' "$LLM_REGISTRY" 2>/dev/null)
if [[ -z "$entry" ]]; then
    log "Profile '$prof' not found in registry."
    exit 1
fi

IFS='|' read -r _p _n _s _proc file m_gpu m_ctx m_threads <<< "$entry"
model_path="$LLAMA_MODEL_DIR/$file"

if [[ ! -f "$model_path" ]]; then
    log "Model file '$file' not found."
    exit 1
fi

use_gpu="${m_gpu:-$LLAMA_GPU_LAYERS}"
use_ctx="${m_ctx:-$LLAMA_CTX_SIZE}"
use_threads="${m_threads:-$LLAMA_CPU_THREADS}"

# Kill any zombie process
pkill -f llama-server 2>/dev/null || true
sleep 1

cmd=("$LLAMA_SERVER_BIN" "-m" "$model_path" "--port" "$LLM_PORT" "--host" "127.0.0.1")
cmd+=("--ctx-size" "$use_ctx" "--mlock")
cmd+=("--batch-size" "512" "--ubatch-size" "512" "--cont-batching")
if [[ "$_proc" == "gpu" ]]; then
    cmd+=("--n-gpu-layers" "$use_gpu" "--flash-attn")
else
    cmd+=("--threads" "$use_threads")
fi

nohup "${cmd[@]}" >> "$LLM_LOG_FILE" 2>&1 &

# Wait for health
for _ in {1..30}; do
    if curl -sf --max-time 2 "http://127.0.0.1:${LLM_PORT}/health" >/dev/null 2>&1; then
        log "Restart successful: $name ($size)"
        exit 0
    fi
    sleep 1
done

log "Restart failed: server did not become healthy in 30s"
exit 1
