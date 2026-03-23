#!/usr/bin/env bash
# llama-watchdog.sh - Check llama-server health; restart from active profile if down.
# Called by systemd user timer. Reads /dev/shm state to know which model to restart.
# AI: Do not add streaming, partial-offload, or auto-download logic to this script.
# AI INSTRUCTION: Increment version on significant changes.
# shellcheck disable=SC2034  # VERSION is read by external tooling, not this script
VERSION="2.2"
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
# These defaults MUST stay in sync with bashrc. If an env var is exported by
# the interactive shell, ${VAR:-default} picks it up automatically.
LLM_PORT="${LLM_PORT:-8081}"
ACTIVE_LLM_FILE="/dev/shm/active_llm"
LLM_LOG_FILE="/dev/shm/llama-server.log"
LLM_REGISTRY="${LLM_REGISTRY:-/mnt/m/.llm/models.conf}"
LLAMA_MODEL_DIR="${LLAMA_MODEL_DIR:-/mnt/m/active}"
LLAMA_ROOT="${LLAMA_ROOT:-$HOME/llama.cpp}"
LLAMA_SERVER_BIN="${LLAMA_SERVER_BIN:-$LLAMA_ROOT/build/bin/llama-server}"
LLAMA_CPU_THREADS="${LLAMA_CPU_THREADS:-12}"
LLAMA_CTX_SIZE="${LLAMA_CTX_SIZE:-4096}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [watchdog] $*"; }

# If no model was ever started, nothing to do
if [[ ! -f "$ACTIVE_LLM_FILE" ]]
then
    exit 0
fi

# If healthy, nothing to do
if curl -sf --max-time 5 "http://127.0.0.1:${LLM_PORT}/health" >/dev/null 2>&1
then
    exit 0
fi

log "Health check failed. Attempting restart..."

# Active LLM file stores model number (matches registry $1 field)
active_num=$(< "$ACTIVE_LLM_FILE")
if [[ -z "$active_num" || ! "$active_num" =~ ^[0-9]+$ ]]
then
    log "Invalid or empty model number in active state file."
    exit 1
fi

# Look up model from registry by number
# Registry format: num|name|file|size|arch|quant|layers|gpu_layers|ctx|threads|tps
entry=$(awk -F'|' -v n="$active_num" '$1 == n' "$LLM_REGISTRY" 2>/dev/null)
if [[ -z "$entry" ]]
then
    log "Model #$active_num not found in registry."
    exit 1
fi

IFS='|' read -r _num name file size _arch _quant layers gpu_layers ctx threads _tps <<< "$entry"
model_path="$LLAMA_MODEL_DIR/$file"

if [[ ! -f "$model_path" ]]
then
    log "Model file '$file' not found."
    exit 1
fi

use_gpu="${gpu_layers:-0}"
use_ctx="${ctx:-$LLAMA_CTX_SIZE}"
use_threads="${threads:-$LLAMA_CPU_THREADS}"
size_tenths=0
if [[ "$size" =~ ^([0-9]+)(\.([0-9]))?G$ ]]
then
    size_tenths=$(( BASH_REMATCH[1] * 10 + ${BASH_REMATCH[3]:-0} ))
fi

# Kill any zombie process (exact match avoids hitting unrelated processes).
pkill -u "$(id -un)" -x llama-server 2>/dev/null || true
sleep 1

cmd=("$LLAMA_SERVER_BIN" "-m" "$model_path" "--port" "$LLM_PORT" "--host" "127.0.0.1")
cmd+=("--ctx-size" "$use_ctx" "--mlock" "--prio" "2" "--cont-batching" "--jinja")
if (( use_gpu > 0 ))
then
    # Adapt batch/parallel to live free VRAM (4GB cards are sensitive to pressure).
    smi_cmd="${WSL_NVIDIA_SMI:-/usr/lib/wsl/lib/nvidia-smi}"
    if [[ ! -x "$smi_cmd" ]]; then
        smi_cmd=$(command -v nvidia-smi 2>/dev/null || true)
    fi
    free_vram_mb=0
    if [[ -n "$smi_cmd" ]]; then
        free_vram_mb=$("$smi_cmd" --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null \
            | head -1 | tr -d ' ')
    fi
    [[ "$free_vram_mb" =~ ^[0-9]+$ ]] || free_vram_mb=0

    batch_size=4096; ubatch_size=1024; parallel_slots=1
    if (( use_ctx > 8192 || free_vram_mb < 1200 )); then
        batch_size=1024; ubatch_size=256
    elif (( use_ctx > 4096 || free_vram_mb < 1800 )); then
        batch_size=2048; ubatch_size=512
    fi
    if (( size_tenths > 0 && size_tenths < 15 && use_ctx >= 8192 )); then
        batch_size=1024; ubatch_size=256
    fi
    if (( size_tenths >= 15 && size_tenths < 20 && free_vram_mb >= 1200 && use_ctx <= 8192 )); then
        if (( batch_size < 2048 )); then
            batch_size=2048; ubatch_size=512
        fi
    fi
    if (( free_vram_mb >= 1800 && use_ctx <= 4096 )); then
        parallel_slots=2
    fi

    # Keep these two models on known-stable settings during auto-restart.
    if [[ "$name" == "Qwen2.5 Coder 3B Instruct" ]]; then
        (( use_ctx > 4096 )) && use_ctx=4096
        batch_size=2048; ubatch_size=512; parallel_slots=1
    fi
    if [[ "$name" == "Qwen3.5-4B" ]]; then
        (( use_ctx > 3072 )) && use_ctx=3072
        batch_size=2048; ubatch_size=512; parallel_slots=1
    fi
    # Gemma 3 4b It: 3691 MiB VRAM projected at ctx=4096/p=2 vs ~3290 MiB free.
    # Clamp to ctx=2048/p=1 so KV overhead drops ~75% and fits safely.
    if [[ "$name" == "Gemma 3 4b It" ]]; then
        (( use_ctx > 2048 )) && use_ctx=2048
        batch_size=2048; ubatch_size=512; parallel_slots=1
    fi

    cmd+=("--batch-size" "$batch_size" "--ubatch-size" "$ubatch_size")
    cmd+=("--parallel" "$parallel_slots")
    cmd+=("--n-gpu-layers" "999" "--flash-attn" "on" "--threads" "$use_threads")
else
    cmd+=("--parallel" "1")
    cmd+=("--batch-size" "512" "--ubatch-size" "512")
    cmd+=("--n-gpu-layers" "0" "--threads" "$use_threads")
    cmd+=("--cache-type-k" "q8_0" "--cache-type-v" "q8_0")
fi

nohup "${cmd[@]}" >> "$LLM_LOG_FILE" 2>&1 &

# Wait for health — CPU-only models over drvfs (9p) can take 60-90s to mmap
health_timeout=30
(( use_gpu == 0 )) && health_timeout=90
if (( use_gpu > 0 )) && [[ "$name" == "Qwen3.5-4B" ]]; then
    health_timeout=120
elif (( use_gpu > 0 && size_tenths >= 20 )); then
    health_timeout=60
fi
for (( _hw=0; _hw < health_timeout; _hw++ ))
do
    if curl -sf --max-time 2 "http://127.0.0.1:${LLM_PORT}/health" >/dev/null 2>&1
    then
        log "Restart successful: $name ($size)"
        exit 0
    fi
    sleep 1
done

log "Restart failed: server did not become healthy in ${health_timeout}s"
exit 1

# end of file
