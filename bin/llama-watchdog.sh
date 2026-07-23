#!/usr/bin/env bash
# llama-watchdog.sh - Check llama-server health; restart from active profile if down.
# Called by systemd user timer. Reads /dev/shm state to know which model to restart.
# AI: Do not add streaming, partial-offload, or auto-download logic to this script.
# AI INSTRUCTION: Increment version on significant changes.
# shellcheck disable=SC2034  # VERSION is read by external tooling, not this script
VERSION="2.6"  # Honor registry backend and preserve tuned restart parameters.
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

# REF: ubuntu-console card ca23ec0a — Watchdog uses LLM_PORT (usually 8081).
# Autotune also uses port 8081. When the watchdog is active and autotune runs,
# both compete for the same port. The bench should skip the watchdog during
# autotune runs (handled via LLM_BENCH_LOCK), but the fallback watchdog check
# mirrors the env var. We provide AUTOTUNE_PORT so autotune-model.sh can adopt
# a different port, leaving the watchdog untouched.
# This works because __model_bench stops the service before autotune, and
# bench_run_with_timeout uses LLM_PORT (preserving the watchdog's port).
AUTOTUNE_PORT="${AUTOTUNE_PORT:-18081}"
ACTIVE_LLM_FILE="${ACTIVE_LLM_FILE:-/dev/shm/active_llm}"
LLM_LOG_FILE="${LLM_LOG_FILE:-/dev/shm/llama-server.log}"
export LLM_REGISTRY="${LLM_REGISTRY:-$HOME/.llm/models.conf}"
LLAMA_MODEL_DIR="${LLAMA_MODEL_DIR:-/mnt/m/active}"
LLAMA_ROOT="${LLAMA_ROOT:-$HOME/llama.cpp}"
LLAMA_SERVER_BIN="${LLAMA_SERVER_BIN:-$LLAMA_ROOT/build/bin/llama-server}"
LLM_SERVER_PYTHON_BIN="${LLM_SERVER_PYTHON_BIN:-python3}"
LLM_SERVER_MODULE="${LLM_SERVER_MODULE:-llama_cpp.server}"
LLM_SERVER_PROC_PATTERN="${LLM_SERVER_PROC_PATTERN:-llama_cpp.server|llama-server}"
LLAMA_CPP_PYTHON_VERSION="${LLAMA_CPP_PYTHON_VERSION:-0.3.23}"
LLAMA_CPU_THREADS="${LLAMA_CPU_THREADS:-6}"
LLAMA_GPU_LAYERS="${LLAMA_GPU_LAYERS:-24}"
LLAMA_CTX_SIZE="${LLAMA_CTX_SIZE:-4096}"
LLAMA_FLASH_ATTN="${LLAMA_FLASH_ATTN:-true}"
LLAMA_OFFLOAD_KQV="${LLAMA_OFFLOAD_KQV:-true}"
LLAMA_CACHE_TYPE_K="${LLAMA_CACHE_TYPE_K:-q8_0}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [watchdog] $*"; }

llm_healthy() {
    if curl -sf --max-time 5 "http://127.0.0.1:${LLM_PORT}/health" >/dev/null 2>&1
    then
        return 0
    fi
    curl -sf --max-time 5 "http://127.0.0.1:${LLM_PORT}/v1/models" >/dev/null 2>&1
}

resolve_llm_python_bin() {
    local expected="${LLAMA_CPP_PYTHON_VERSION:-0.3.23}"
    local cand resolved
    local -a candidates=()

    [[ -n "${LLM_SERVER_PYTHON_BIN:-}" ]] && candidates+=("$LLM_SERVER_PYTHON_BIN")
    candidates+=("python3" "python" "/home/linuxbrew/.linuxbrew/bin/python3")

    for cand in "${candidates[@]}"
    do
        resolved=""
        if [[ -x "$cand" ]]
        then
            resolved="$cand"
        else
            resolved=$(command -v "$cand" 2>/dev/null || true)
        fi
        [[ -z "$resolved" ]] && continue

        if "$resolved" - <<'PY' >/dev/null 2>&1
import os
import sys

expected = os.environ.get("LLAMA_CPP_PYTHON_VERSION", "0.3.23")
import llama_cpp  # type: ignore
import uvicorn  # type: ignore
if getattr(llama_cpp, "__version__", "unknown") != expected:
    raise SystemExit(1)
PY
        then
            printf '%s\n' "$resolved"
            return 0
        fi
    done

    return 1
}

resolve_type_k_value() {
    local raw="${LLAMA_CACHE_TYPE_K:-q8_0}"
    case "${raw,,}" in
        q8_0) echo 8 ;;
        f16) echo 1 ;;
        f32) echo 0 ;;
        *)
            if [[ "$raw" =~ ^[0-9]+$ ]]
            then
                echo "$raw"
            else
                echo 8
            fi
            ;;
    esac
}

normalize_backend_label() {
    local raw="${1:-python}"
    case "$raw" in
        native|binary|llama-server|llama_server) printf '%s\n' "native" ;;
        python|llama-cpp-python|module|"") printf '%s\n' "python" ;;
        *) printf '%s\n' "python" ;;
    esac
}

flash_attn_mode() {
    case "${LLAMA_FLASH_ATTN:-true}" in
        true|TRUE|1|yes|YES|on|ON) printf '%s\n' "on" ;;
        false|FALSE|0|no|NO|off|OFF) printf '%s\n' "off" ;;
        *) printf '%s\n' "auto" ;;
    esac
}

# If no model was ever started, nothing to do
if [[ ! -f "$ACTIVE_LLM_FILE" ]]
then
    exit 0
fi

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

log "Health check failed. Attempting restart..."

# Active LLM file stores model number (matches registry $1 field)
active_num=$(< "$ACTIVE_LLM_FILE")
if [[ -z "$active_num" || ! "$active_num" =~ ^[0-9]+$ ]]
then
    log "Invalid or empty model number in active state file."
    exit 1
fi

# Look up model from registry by number
# Registry format:
# num|name|file|size_gb|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|fit_target_mb|backend|mmap_mode|flash_attn|tps|autotuned|is_default|in_vram
entry=$(awk -F'|' -v n="$active_num" '$1 == n' "$LLM_REGISTRY" 2>/dev/null)
if [[ -z "$entry" ]]
then
    log "Model #$active_num not found in registry."
    exit 1
fi

IFS='|' read -r _num name file size _quant_cache _arch gpu_layers ctx threads _batch _ubatch _parallel _fit _backend _mmap_mode _tps _autotuned _is_default _in_vram <<< "$entry"
model_path="$LLAMA_MODEL_DIR/$file"

if [[ ! -f "$model_path" ]]
then
    log "Model file '$file' not found."
    exit 1
fi

use_backend=$(normalize_backend_label "${_backend:-}")
use_gpu="${gpu_layers:-0}"
use_ctx="${ctx:-$LLAMA_CTX_SIZE}"
use_threads="${threads:-$LLAMA_CPU_THREADS}"
use_batch="${_batch:-1024}"
use_ubatch="${_ubatch:-256}"
use_parallel="${_parallel:-1}"
use_fit_target="${_fit:-1024}"
size_tenths=0
if [[ "$size" =~ ^([0-9]+)(\.([0-9]))?G$ ]]
then
    size_tenths=$(( BASH_REMATCH[1] * 10 + ${BASH_REMATCH[3]:-0} ))
fi

# Kill any zombie process. Uses -f (full-command-line match) instead of -x
# (exact process-name match) because the Python backend runs as
# "python3 -m llama_cpp.server" — -x would require killing all python3,
# while -f targets only the specific module path.
pkill -u "$(id -un)" -f "$LLM_SERVER_PROC_PATTERN" 2>/dev/null || true
# Legacy safety: ensure classic llama-server process names are also cleaned up.
# Also uses -f to catch symlinked or path-invoked binaries.
pkill -u "$(id -un)" -f "llama-server" 2>/dev/null || true
sleep 1

# Use the tuned values from the registry row when restarting. Fall back to
# runtime defaults only if the registry entry is incomplete.
[[ -n "${use_threads:-}" ]] || use_threads="${LLAMA_CPU_THREADS:-6}"
[[ -n "${use_ctx:-}" ]] || use_ctx="${LLAMA_CTX_SIZE:-4096}"
if [[ -z "${use_gpu:-}" ]]
then
    use_gpu="${LLAMA_GPU_LAYERS:-24}"
fi

[[ "$use_batch" =~ ^[0-9]+$ ]] || use_batch=1024
[[ "$use_ubatch" =~ ^[0-9]+$ ]] || use_ubatch=256
[[ "$use_parallel" =~ ^[0-9]+$ ]] || use_parallel=1
[[ "$use_fit_target" =~ ^[0-9]+$ ]] || use_fit_target=1024
if (( use_ubatch > use_batch ))
then
    use_ubatch="$use_batch"
fi

cmd=()
if [[ "$use_backend" == "native" ]]
then
    if [[ ! -x "$LLAMA_SERVER_BIN" ]]
    then
        log "Native llama-server binary not found: $LLAMA_SERVER_BIN"
        exit 1
    fi
    local_kv_offload_flag="--kv-offload"
    case "${LLAMA_OFFLOAD_KQV:-true}" in
        false|FALSE|0|no|NO|off|OFF) local_kv_offload_flag="--no-kv-offload" ;;
        *) local_kv_offload_flag="--kv-offload" ;;
    esac

    cmd=("$LLAMA_SERVER_BIN")
    cmd+=("--model" "$model_path" "--port" "$LLM_PORT" "--host" "127.0.0.1")
    cmd+=("--ctx-size" "$use_ctx")
    cmd+=("--batch-size" "$use_batch" "--ubatch-size" "$use_ubatch")
    cmd+=("--threads" "$use_threads" "--n-gpu-layers" "$use_gpu")
    cmd+=("--fit" "on" "--fit-target" "$use_fit_target")
    cmd+=("--flash-attn" "$(flash_attn_mode)")
    cmd+=("$local_kv_offload_flag")
    cmd+=("--cache-type-k" "${LLAMA_CACHE_TYPE_K:-q8_0}")
    cmd+=("--parallel" "$use_parallel")
else
    resolved_python_bin=$(resolve_llm_python_bin || true)
    if [[ -z "$resolved_python_bin" ]]
    then
        log "No compatible Python found with llama-cpp-python==${LLAMA_CPP_PYTHON_VERSION}"
        exit 1
    fi
    LLM_SERVER_PYTHON_BIN="$resolved_python_bin"

    cmd=("$LLM_SERVER_PYTHON_BIN" "-m" "$LLM_SERVER_MODULE")
    cmd+=("--model" "$model_path" "--port" "$LLM_PORT" "--host" "127.0.0.1")
    cmd+=("--n_ctx" "$use_ctx")
    cmd+=("--n_batch" "$use_batch" "--n_ubatch" "$use_ubatch")
    cmd+=("--n_threads" "$use_threads" "--n_gpu_layers" "$use_gpu")
    cmd+=("--flash_attn" "$LLAMA_FLASH_ATTN" "--offload_kqv" "$LLAMA_OFFLOAD_KQV")
    cmd+=("--type_k" "$(resolve_type_k_value)")
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
    if llm_healthy
    then
        log "Restart successful: $name ($size)"
        exit 0
    fi
    sleep 1
done

log "Restart failed: server did not become healthy in ${health_timeout}s"
exit 1

# end of file

# end of file marker
