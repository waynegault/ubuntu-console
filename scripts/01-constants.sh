# shellcheck shell=bash
# shellcheck disable=SC2034
# ─── Module: 01-constants ───────────────────────────────────────────────────────
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# TACTICAL_PROFILE_VERSION auto-computes from the sum of all module versions.
# Module Version: 1
# ==============================================================================

# ==============================================================================
# 1. GLOBAL CONSTANTS (ALL PATHS / PORTS DEFINED HERE)
# ==============================================================================
# @modular-section: constants
# @depends: none
# @depended-on-by: aliases (§3), design-tokens (§4), ui-engine (§5), hooks (§6),
#   telemetry (§7), maintenance (§8), openclaw (§9), deployment (§10),
#   llm-manager (§11), dashboard (§12), init (§13)
# @exports: AI_STORAGE_ROOT,
#   OC_ROOT, OPENCLAW_ROOT, OC_WORKSPACE, OC_AGENTS, OC_LOGS, OC_BACKUPS,
#   CooldownDB, ErrorLogPath, OC_TMP_LOG, LLAMA_ROOT,
#   LLAMA_MODEL_DIR, LLAMA_DRIVE_ROOT, LLAMA_ARCHIVE_DIR, LLAMA_SERVER_BIN,
#   LLM_REGISTRY, ACTIVE_LLM_FILE, QUANT_GUIDE,
#   LLM_LOG_FILE, LLM_TPS_CACHE, TAC_CACHE_DIR, VENV_DIR, UIWidth, LAST_TPS,
#   LLM_PORT, OC_PORT, LOCAL_LLM_URL, __TAC_HAS_BATTERY, __resolve_vscode_bin,
#   VSCODE_BIN, WSL_NVIDIA_SMI, PATH, HISTCONTROL

# ---- Storage Roots ----
export AI_STORAGE_ROOT="$HOME"

# ---- OpenClaw ----
export OC_ROOT="$AI_STORAGE_ROOT/.openclaw"
# DEPRECATION: OPENCLAW_ROOT is the old name. OC_ROOT is canonical.
# If no external scripts reference OPENCLAW_ROOT, this line can be removed.
# Used by: oc-env display (§9).
export OPENCLAW_ROOT="$OC_ROOT"
export OC_WORKSPACE="$OC_ROOT/workspace"
export OC_AGENTS="$OC_ROOT/agents"
export OC_LOGS="$OC_ROOT/logs"
export OC_BACKUPS="$OC_ROOT/backups"
export CooldownDB="$OC_ROOT/maintenance_cooldowns.txt"
export ErrorLogPath="$OC_ROOT/bash-errors.log"
export OC_TMP_LOG="/tmp/openclaw/openclaw.log"

# ---- LLM / llama.cpp ----
export LLAMA_ROOT="$AI_STORAGE_ROOT/llama.cpp"
export LLAMA_DRIVE_ROOT="/mnt/m"                # Root of the model drive
export LLAMA_MODEL_DIR="$LLAMA_DRIVE_ROOT/active"
export LLAMA_ARCHIVE_DIR="$LLAMA_DRIVE_ROOT/archive"
# Quantization priority guide — editable config controlling download warnings.
# See ~/ubuntu-console/quant-guide.conf for rating/description of each quant.
export QUANT_GUIDE="$HOME/ubuntu-console/quant-guide.conf"
# Detect drive size at startup; falls back to 200 GB if df unavailable.
# WARNING: If the drive is not mounted, all capacity calculations will use
# the 200GB fallback, which may over- or under-estimate available space.
# Check mountpoint first to prevent model downloads writing to the WSL rootfs.
__LLAMA_DRIVE_MOUNTED=1
if ! mountpoint -q "$LLAMA_DRIVE_ROOT" 2>/dev/null
then
    __LLAMA_DRIVE_MOUNTED=0
fi
LLAMA_DRIVE_SIZE=$(df -B1 --output=size "$LLAMA_DRIVE_ROOT" 2>/dev/null | awk 'NR==2{print $1+0}')
if [[ -z "$LLAMA_DRIVE_SIZE" || "$LLAMA_DRIVE_SIZE" == "0" ]]
then
    LLAMA_DRIVE_SIZE=$((200 * 1024 * 1024 * 1024))
fi
export LLAMA_DRIVE_SIZE
export LLAMA_SERVER_BIN="$LLAMA_ROOT/build/bin/llama-server"
export LLAMA_BUILD_VERSION
LLAMA_BUILD_VERSION=$(git -C "$LLAMA_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
export LLM_REGISTRY="$LLAMA_DRIVE_ROOT/.llm/models.conf"
export ACTIVE_LLM_FILE="/dev/shm/active_llm"
export LLM_LOG_FILE="/dev/shm/llama-server.log"
export LLM_TPS_CACHE="/dev/shm/last_tps"

# ---- (Python SSE helper removed — all streaming is now pure bash + curl + jq) ----

# ---- Telemetry & System Paths ----
export TAC_CACHE_DIR="/dev/shm"
# VENV_DIR is shell-local only (not exported). Used by the cd() override
# in §6 to auto-activate Python virtual environments on directory change.
VENV_DIR=".venv"
export BASH_COMPLETION_SCRIPT="/usr/share/bash-completion/bash_completion"

# ---- VS Code Path (Lazy-initialized on first use to avoid slow pwsh call at startup) ----
VSCODE_BIN=""
# Resolve the VS Code binary path, caching the result for subsequent calls.
function __resolve_vscode_bin() {
    [[ -n "$VSCODE_BIN" ]] && return
    if [[ -f "$TAC_CACHE_DIR/vscode_path" ]]
    then
        VSCODE_BIN=$(< "$TAC_CACHE_DIR/vscode_path")
    else
        local win_user
        win_user=$(pwsh.exe -NoProfile -Command '[Environment]::UserName' 2>/dev/null | tr -d '\r')
        VSCODE_BIN="/mnt/c/Users/${win_user}/AppData/Local/Programs/Microsoft VS Code/bin/code"
        if [[ ! -x "$VSCODE_BIN" ]]
        then
            VSCODE_BIN=$(command -v code 2>/dev/null || echo "")
        fi
        if [[ -n "$VSCODE_BIN" ]]
        then
            echo "$VSCODE_BIN" > "$TAC_CACHE_DIR/vscode_path.tmp" \
                && mv "$TAC_CACHE_DIR/vscode_path.tmp" "$TAC_CACHE_DIR/vscode_path"
        fi
    fi
}

export WSL_NVIDIA_SMI="/usr/lib/wsl/lib/nvidia-smi"

# ---- GitHub Copilot CLI ----
export COPILOT_CLI_DIR="$HOME/.vscode-server/data/User/globalStorage/github.copilot-chat/copilotCli"

# ---- Hugging Face ----
export HF_HOME="${HF_HOME:-$HOME/hf_cache}"

# ---- Network & API ----
export LLM_PORT=8081
export OC_PORT=18789
export LOCAL_LLM_URL="http://127.0.0.1:${LLM_PORT}/v1/chat/completions"

# ---- Hardware Tuning (Intel i9 / RTX 3050 Ti 4GB VRAM) ----
# These are DEFAULTS, used when the model registry does not specify per-model
# values. The registry format (models.conf) supports per-model overrides:
#   profile|name|size|proc|file|gpu_layers|ctx_size|threads
# If the last three fields are missing or empty, these defaults are used.
export LLAMA_GPU_LAYERS=33   # Default GPU layers (full offload for small models)
export LLAMA_CPU_THREADS=12  # Default CPU threads
export LLAMA_CTX_SIZE=4096   # Default context window size

# ---- Named Constants (avoid magic numbers scattered through functions) ----
if [[ -z "${VRAM_TOTAL_BYTES+x}" ]]; then
declare -ri VRAM_TOTAL_BYTES=$((4 * 1024 * 1024 * 1024))  # 4 GB RTX 3050 Ti
fi
if [[ -z "${VRAM_USABLE_PCT+x}" ]]; then
declare -ri VRAM_USABLE_PCT=95       # Percentage usable after driver overhead
fi
if [[ -z "${VRAM_THRESHOLD_PCT+x}" ]]; then
declare -ri VRAM_THRESHOLD_PCT=85    # Threshold for "fits in VRAM" decisions
fi
if [[ -z "${COOLDOWN_DAILY+x}" ]]; then
declare -ri COOLDOWN_DAILY=86400     # 24 hours in seconds
fi
if [[ -z "${COOLDOWN_WEEKLY+x}" ]]; then
declare -ri COOLDOWN_WEEKLY=604800   # 7 days in seconds
fi
if [[ -z "${LOG_MAX_BYTES+x}" ]]; then
declare -ri LOG_MAX_BYTES=1048576    # 1 MB - logtrim threshold
fi
if [[ -z "${MOE_DEFAULT_CTX+x}" ]]; then
declare -ri MOE_DEFAULT_CTX=8192     # Default context size for MoE models
fi
if [[ -z "${LLAMA_DRIVE_FALLBACK_BYTES+x}" ]]; then
declare -ri LLAMA_DRIVE_FALLBACK_BYTES=$((200 * 1024 * 1024 * 1024))  # 200 GB
fi

# ---- Battery detection (cached once at startup to skip pwsh fallback on desktops) ----
if [[ -d /sys/class/power_supply/BAT0 ]]
then
    __TAC_HAS_BATTERY=1
else
    __TAC_HAS_BATTERY=0
fi

# ---- UI Context & Core Environment ----
export UIWidth="${UIWidth:-80}"
# LAST_TPS holds the most recent inference speed measurement (tokens/sec).
# Initialised to "Untested" so the dashboard displays a meaningful label
# before any LLM inference has run in this session.
# Shell-local only (not exported) — intentional. The dashboard reads it in
# the same shell. LLM_TPS_CACHE is the file-backed persistent version in
# /dev/shm. Precedence: LLM_TPS_CACHE is read on dashboard render; LAST_TPS
# is the fallback when the cache file does not yet exist.
LAST_TPS="Untested"

# Unicode-safe UI tokens (use \u escapes so source file remains ASCII)
# Box drawing tokens

# Box drawing tokens (guarded so re-sourcing is idempotent)
if [[ -z "${BOX_TL:-}" ]]; then readonly BOX_TL=$'\u2554'; fi
if [[ -z "${BOX_TR:-}" ]]; then readonly BOX_TR=$'\u2557'; fi
if [[ -z "${BOX_BL:-}" ]]; then readonly BOX_BL=$'\u255A'; fi
if [[ -z "${BOX_BR:-}" ]]; then readonly BOX_BR=$'\u255D'; fi
if [[ -z "${BOX_LM:-}" ]]; then readonly BOX_LM=$'\u2560'; fi
if [[ -z "${BOX_RM:-}" ]]; then readonly BOX_RM=$'\u2563'; fi
if [[ -z "${BOX_H:-}" ]]; then readonly BOX_H=$'\u2550'; fi
if [[ -z "${BOX_V:-}" ]]; then readonly BOX_V=$'\u2551'; fi
if [[ -z "${BOX_SL:-}" ]]; then readonly BOX_SL=$'\u2500'; fi
if [[ -z "${BOX_SLC:-}" ]]; then readonly BOX_SLC=$'\u255F'; fi
if [[ -z "${BOX_SRC:-}" ]]; then readonly BOX_SRC=$'\u2562'; fi

# General glyphs

# General glyphs (guarded so re-sourcing is idempotent)
if [[ -z "${DEGREE:-}" ]]; then readonly DEGREE=$'\u00B0'; fi
if [[ -z "${CHECK_MARK:-}" ]]; then readonly CHECK_MARK=$'\u2713'; fi
if [[ -z "${CROSS_MARK:-}" ]]; then readonly CROSS_MARK=$'\u2717'; fi
if [[ -z "${BULLET:-}" ]]; then readonly BULLET=$'\u25CF'; fi
if [[ -z "${ARROW_R:-}" ]]; then readonly ARROW_R=$'\u2192'; fi
if [[ -z "${WARN_SIGN:-}" ]]; then readonly WARN_SIGN=$'\u26A0'; fi

# Spinner (ASCII fallback to avoid glyph proliferation in many files)
if [[ -z "${SPINNER_ASCII:-}" ]]; then readonly SPINNER_ASCII='/-\\|'; fi
if [[ -z "${PLAY_MARK:-}" ]]; then readonly PLAY_MARK=$'\u25B6'; fi
if [[ -z "${TRI_DOWN:-}" ]]; then readonly TRI_DOWN=$'\u25BC'; fi

# Guard against PATH duplication on re-source (e.g., source ~/.bashrc).
# Each block checks whether the directory is already in PATH before prepending.

# ~/.local/bin — pip-installed CLI tools (hf, openclaw, etc.)
if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]
then
    export PATH="$HOME/.local/bin:$PATH"
fi

# ~/.npm-global/bin — globally installed npm packages
if [[ ":$PATH:" != *":$HOME/.npm-global/bin:"* ]]
then
    export PATH="$HOME/.npm-global/bin:$PATH"
fi

# Homebrew (Linuxbrew) — Go binaries, wacli, etc.
if [[ -d "/home/linuxbrew/.linuxbrew/bin" && ":$PATH:" != *":/home/linuxbrew/.linuxbrew/bin:"* ]]
then
    export PATH="/home/linuxbrew/.linuxbrew/bin:$PATH"
fi

# GitHub Copilot CLI (only if directory exists)
if [[ -d "$COPILOT_CLI_DIR" && ":$PATH:" != *":$COPILOT_CLI_DIR:"* ]]
then
    export PATH="$COPILOT_CLI_DIR:$PATH"
fi

# HISTCONTROL=ignoreboth combines 'ignorespace' (commands starting with a
# space are not recorded) and 'ignoredups' (consecutive duplicate commands
# are not recorded). This keeps history clean while preserving unique entries.
export HISTCONTROL=ignoreboth
export HISTTIMEFORMAT="%Y-%m-%d %H:%M:%S  "

# histappend: append (not overwrite) on shell exit
shopt -s histappend

# checkwinsize: update LINES/COLUMNS after each command
shopt -s checkwinsize

export HISTSIZE=100000
export HISTFILESIZE=200000
# HISTIGNORE: commands too short or frequently typed to be worth recording.
# These are navigation commands that would dominate history otherwise.
export HISTIGNORE="ls:ll:la:l:h:m:cls"

# PS0 intentionally unset — PS1's leading \n handles all inter-prompt spacing.
# Setting PS0="\n" would double-space prompts when commands produce no output.


# end of file
