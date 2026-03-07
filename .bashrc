# ==============================================================================
# SYNOPSIS
#       Tactical Console Profile (Bash)
#       Admin: Wayne | Environment: WSL2 (Ubuntu 24.04) / RTX 3050 Ti
# ==============================================================================

# ==============================================================================
# INTERACTIVE GUARD
# ==============================================================================
# Prevent execution in non-interactive shells (like sftp/rsync)
case $- in
    *i*) ;;
      *) return ;;
esac

# ==============================================================================
#  0. MANDATORY INSTRUCTIONS FOR AI EDITORS
# ==============================================================================
# @modular-section: ai-instructions
# @depends: none
#
# AI INSTRUCTION: Increment version on significant changes.
export TACTICAL_PROFILE_VERSION="2.13"

# CHANGELOG:
# 2.13 (2026-03-07) — Added GitHub Copilot CLI integration: COPILOT_CLI_DIR
#        constant, PATH entry, `cop`/`??`/`cop-ask`/`cop-init` aliases.
# 2.12 (2026-03-07) — Final review tidy: defensive-quoted all 15 __test_port
#        call sites ("$LLM_PORT"/"$OC_PORT"). Moved __require_llm from §6 to §11
#        (co-located with its 7 call sites). model bench renders as single open
#        box with __tac_divider (was closed banner + nested header). Fixed PS3
#        leak in second model assign select. Architecture map line numbers
#        updated to match actual section positions.
# 2.11 (2026-03-07) — Full audit implementation: fixed model bench box rendering
#        ("open" style), oc-diag box rendering, oc-restore validation accepts
#        config-only backups, __get_tokens jq null guard, commit_auto PID-based
#        llama-server verification. Dashboard /slots query moved to async cache
#        (__get_llm_slots). __get_oc_metrics split into 60s sessions + 24h
#        version caches. Added __require_llm helper (deduplicates jq+port
#        checks). Replaced eval nullglob restore with flag pattern (3 sites).
#        __fRow dead-code safety-net commented. __TAC_BG_PIDS reset per
#        dashboard render. model bench persists results to ~/.llm/bench_*.tsv.
#        EXIT trap chains with existing traps. Section comments in dashboard.
#        up() step 2 inline logic comments. CHANGELOG dates added.
# 2.10 (2026-03-07) — Hal analysis round 2: llama.cpp perf flags (--batch-size 512,
#        --ubatch-size 512, --cont-batching, --flash-attn GPU-only) in model
#        start, oc-model-switch, llama-watchdog.sh. model swap calls oc-local-llm
#        to update OpenClaw provider. so() warns if provider targets offline local
#        LLM. oc-backup/oc-restore expanded to cover .bashrc, standalone scripts,
#        systemd units. apt upgrade uses --no-install-recommends; split APT
#        cooldown (apt_index 24h / apt 7d). models.conf extended to 8-field
#        format with per-model gpu_layers, ctx_size, threads. New standalone
#        script: oc-gpu-status (agent-accessible NVIDIA GPU summary).
# 2.09 (2026-03-06) — Audit + Hal cross-ref: 25-item implementation covering P0-P3 fixes.
#        Atomic vscode_path write, __check_cooldown per-key support, defensive
#        guards across dashboard, model, and OpenClaw integration functions.
# 2.08 (2026-03-05) — Audit implementation: P0 fixed &&/|| color chain in dashboard (emitted
#        two values), removed duplicate unguarded completions source. P1 so()
#        API key injection uses indirect expansion (${!_key}) instead of raw
#        =‑splitting %q-quoted strings, commit_deploy gates on commit exit code,
#        model start/info use awk instead of unanchored grep. P2 design tokens
#        switched to ANSI-C $'\e[…]' quoting — eliminates ~60 forks per render,
#        removed echo -e subshells in __tac_info/__tac_line/__fRow, oc-cache-
#        clear nullglob guard, dead model pull code removed, GPU sleep retry
#        in up() removed, dashboard GPU parsed once (was twice), TPS read from
#        cache file. Docker Desktop mounts filtered from disk audit.
# 2.07 (2026-03-04) — Full audit pass: P0 find -delete OR-precedence bug, model pull alias
#        (spaces illegal in bash aliases → case branch). P1 deploy gated on
#        push success, model list UIWidth-derived, chat REPL now has multi-turn
#        conversation history, oc-llm-sync.sh SHA256 integrity check. P2 pure-
#        bash __strip_ansi (zero forks), sysinfo single free call, __cleanup_temps
#        restricted to safe dirs, atomic cache writes, openclaw doctor in up().
#        New functions: chat-pipe, model swap, oc-diag, oc-failover. oc-local-llm
#        reads actual model name. mkproj checks for python3/git. Improved bridge
#        regex specificity. Modularisation notes on cross-cutting state.
# 2.06 — Tuned constants: UIWidth 78→80 (overridable), cooldown 24h→7d with
#        d/h display, colour thresholds 33/66→75/90 (industry standard),
#        diff head 200→500, token scan 10→25 files. Windows API key bridge:
#        __bridge_windows_api_keys auto-imports API_KEY/TOKEN/SECRET vars from
#        Windows User env into WSL on shell start (1h cache). oc-refresh-keys.
# 2.05 — Audit fixes: __get_tokens pipe bug, __strip_ansi helper, UIWidth-derived
#        layout constants, HOURS_LEFT refactor, localhost guard on commit_auto,
#        re-source guard for clear_tactical, background job cleanup trap, new
#        utility functions (oc-env, oc-cache-clear, chat-context, model pull).
# 2.04 — Pure bash SSE streaming; removed Python dependency.

# AI INSTRUCTION: Follow these terminal formatting rules strictly:
# 1. A blank line must exist between the bottom of any UI border and the command prompt.
# 2. A blank line must exist between prompt lines if there is no output (e.g., hitting Enter).
# 3. If there is command output, a blank line must exist AFTER the output, before the next prompt.
# 4. Do not cut off rendering code before the comment '# end of file' is reached. never remove the comment '# end of file'. when creating a file, always ensure there is a comment, 'end of file' unless the file format does not permit comments (eg JSON).
#
# IMPLEMENTATION NOTE:
# - PS1 starts with "\n" — this produces exactly one blank line between any prompt pair,
#   whether the previous command had output or not. PS0 is intentionally unset.
# - DO NOT add manual `echo ""` to the end of UI functions, as PS1 natively handles the gap.
# - DO NOT set PS0 — it would add a second blank line for commands with no output.
#
# NAMING CONVENTION:
# - User-facing commands: kebab-case (oc-health, get-ip, oc-backup)
# - Internal helpers / UI primitives: __double_underscore prefix (__tac_header, __get_host_metrics)
# - Short tactical aliases: lowercase abbreviations (so, xo, cl, up, m, h)
# - NEVER use PascalCase or CamelCase for function names.
#
# DEPENDENCY NOTE:
# - jq is REQUIRED for JSON parsing and SSE stream parsing throughout this profile.
# - curl is REQUIRED for all LLM API calls (streaming and non-streaming).
# - python3 is NOT required. All LLM functions are pure bash + curl + jq.

# ==============================================================================
# ARCHITECTURE MAP (approximate line numbers — update after major refactors)
# ==============================================================================
# ┌─  0. AI Instructions    ─ Rules for AI editors & formatting mandates   (~L19)
# ├─  1. Global Constants    ─ All paths, ports, env vars (single truth)   (~L143)
# ├─  2. Error Handling      ─ Bash ERR trap → bash-errors.log             (~L251)
# ├─  3. Alias Definitions   ─ Short commands, VS Code wrappers            (~L264)
# ├─  4. Design Tokens       ─ ANSI color constants (readonly)             (~L317)
# ├─  5. UI Helper Engine    ─ Box-drawing primitives (__tac_* family)      (~L342)
# ├─  6. System Hooks        ─ cd override, prompt (PS1), port test        (~L552)
# ├─  7. Telemetry           ─ CPU, GPU, battery, git, disk, tokens        (~L624)
# ├─  8. Maintenance         ─ get-ip, up, cl, cpwd, sysinfo, logtrim     (~L835)
# ├─  9. OpenClaw Manager    ─ Gateway, backup, cron, skills, plugins      (~L1178)
# ├─ 10. Deployment          ─ mkproj scaffold, rsync, git commit+push     (~L1924)
# ├─ 11. LLM Manager         ─ model mgmt, chat, burn, explain             (~L2202)
# ├─ 12. Dashboard & Help    ─ Tactical Dashboard ('m') and Help ('h')     (~L2876)
# └─ 13. Initialization      ─ mkdir, completions, WSL loopback fix        (~L3160)
#
# CROSS-CUTTING STATE (needs attention during modularisation):
# - LAST_TPS: written by burn/llm_stream (§11) → read by dashboard (§12) via LLM_TPS_CACHE
# - __LAST_LLM_RESPONSE: written by __llm_chat_send (§11) → read by local_chat (§11)
# - ACTIVE_LLM_FILE: written by model start (§11) → read by oc-local-llm (§9), dashboard (§12)
# - __resolve_vscode_bin: defined in constants (§1) → called by aliases (§3)
# - _TAC_ADMIN_BADGE: set in hooks (§6) → read by custom_prompt_command (§6), safe within section
# - CooldownDB: defined in constants (§1) → read/written by maintenance (§8), up (§8)
# - __TAC_HAS_BATTERY: set in constants (§1) → read by __get_battery (§7)
# - __tac_last_hist_num: written by custom_prompt_command (§6) → read by same, safe within section
# - VSCODE_BIN: lazy-init by __resolve_vscode_bin (§1) → used by aliases (§3)
# - __TAC_INITIALIZED: set by init (§13) → guards re-source idempotency
#
# MODULARISATION GUIDE:
#   Split order must match section numbering (§0–§13).  Each module sources
#   after its @depends list.  Functions in @exports are the public API of that
#   section; anything without __ prefix is user-facing.  Use a thin loader:
#     for f in ~/.bashrc.d/*.sh; do source "$f"; done
#   Readonly vars (C_* design tokens) must be guarded with [[ -z "${C_Reset:-}" ]]
#   to survive re-source.  All /dev/shm caches are inherently cross-module safe.
# ==============================================================================

# ==============================================================================
# 1. GLOBAL CONSTANTS (ALL PATHS / PORTS DEFINED HERE)
# ==============================================================================
# @modular-section: constants
# @depends: none
# @exports: WAYNE_HOME, AI_STORAGE_ROOT, TacticalRoot, OpenClawWorkspace,
#   OPENCLAW_ROOT, OC_ROOT, OC_WORKSPACE, OC_AGENTS, OC_LOGS, OC_BACKUPS,
#   CooldownDB, ErrorLogPath, OC_TMP_LOG, LLAMA_ROOT,
#   LLAMA_MODEL_DIR, LLAMA_SERVER_BIN, LLM_REGISTRY, ACTIVE_LLM_FILE,
#   LLM_LOG_FILE, LLM_TPS_CACHE, TAC_CACHE_DIR, VENV_DIR, UIWidth, LAST_TPS,
#   LLM_PORT, OC_PORT, LOCAL_LLM_URL, __TAC_HAS_BATTERY, __resolve_vscode_bin,
#   VSCODE_BIN, WSL_NVIDIA_SMI, PATH, HISTCONTROL

# ---- Storage Roots (Future-proofed for C:\AI\ and M:\AI\ migration) ----
export WAYNE_HOME="$HOME"
export AI_STORAGE_ROOT="$HOME"

# ---- Workspace Roots ----
export TacticalRoot="$AI_STORAGE_ROOT/console"
export OpenClawWorkspace="$AI_STORAGE_ROOT/OpenClaw_Prod"

# ---- OpenClaw ----
export OPENCLAW_ROOT="$AI_STORAGE_ROOT/.openclaw"
export OC_ROOT="$OPENCLAW_ROOT" # Kept for backward compatibility
export OC_WORKSPACE="$OC_ROOT/workspace"
export OC_AGENTS="$OC_ROOT/agents"
export OC_LOGS="$OC_ROOT/logs"
export OC_BACKUPS="$OC_ROOT/backups"
export CooldownDB="$OC_ROOT/maintenance_cooldowns.txt"
export ErrorLogPath="$OC_ROOT/bash-errors.log"
export OC_TMP_LOG="/tmp/openclaw/openclaw.log"

# ---- LLM / llama.cpp ----
export LLAMA_ROOT="$AI_STORAGE_ROOT/llama.cpp"
export LLAMA_MODEL_DIR="$LLAMA_ROOT/models"
export LLAMA_SERVER_BIN="$LLAMA_ROOT/build/bin/llama-server"
export LLM_REGISTRY="$AI_STORAGE_ROOT/.llm/models.conf"
export ACTIVE_LLM_FILE="/dev/shm/active_llm"
export LLM_LOG_FILE="/dev/shm/llama-server.log"
export LLM_TPS_CACHE="/dev/shm/last_tps"

# ---- (Python SSE helper removed — all streaming is now pure bash + curl + jq) ----

# ---- Telemetry & System Paths ----
export TAC_CACHE_DIR="/dev/shm"
export VENV_DIR=".venv"
export BASH_COMPLETION_SCRIPT="/usr/share/bash-completion/bash_completion"

# ---- VS Code Path (Lazy-initialized on first use to avoid slow pwsh call at startup) ----
VSCODE_BIN=""
__resolve_vscode_bin() {
    [[ -n "$VSCODE_BIN" ]] && return
    if [[ -f "$TAC_CACHE_DIR/vscode_path" ]]; then
        VSCODE_BIN=$(< "$TAC_CACHE_DIR/vscode_path")
    else
        local win_user
        win_user=$(pwsh.exe -NoProfile -Command '[Environment]::UserName' 2>/dev/null | tr -d '\r')
        VSCODE_BIN="/mnt/c/Users/${win_user}/AppData/Local/Programs/Microsoft VS Code/bin/code"
        if [[ ! -x "$VSCODE_BIN" ]]; then
            VSCODE_BIN=$(command -v code 2>/dev/null || echo "")
        fi
        if [[ -n "$VSCODE_BIN" ]]; then
            echo "$VSCODE_BIN" > "$TAC_CACHE_DIR/vscode_path.tmp" \
                && mv "$TAC_CACHE_DIR/vscode_path.tmp" "$TAC_CACHE_DIR/vscode_path"
        fi
    fi
}

export WSL_NVIDIA_SMI="/usr/lib/wsl/lib/nvidia-smi"

# ---- GitHub Copilot CLI ----
export COPILOT_CLI_DIR="$HOME/.vscode-server/data/User/globalStorage/github.copilot-chat/copilotCli"

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

# ---- Battery detection (cached once at startup to skip pwsh fallback on desktops) ----
if [ -d /sys/class/power_supply/BAT0 ]; then
    __TAC_HAS_BATTERY=1
else
    __TAC_HAS_BATTERY=0
fi

# ---- UI Context & Core Environment ----
export UIWidth="${UIWidth:-80}"
export LAST_TPS="Untested"

# Guard against PATH duplication on re-source (e.g., source ~/.bashrc)
[[ ":$PATH:" != *":$HOME/.local/bin:"* ]] && export PATH="$HOME/.local/bin:$PATH"
[[ ":$PATH:" != *":$HOME/.npm-global/bin:"* ]] && export PATH="$HOME/.npm-global/bin:$PATH"
[[ -d "$COPILOT_CLI_DIR" && ":$PATH:" != *":$COPILOT_CLI_DIR:"* ]] && export PATH="$COPILOT_CLI_DIR:$PATH"

export HISTCONTROL=ignoreboth
export HISTTIMEFORMAT="%Y-%m-%d %H:%M:%S  "
shopt -s histappend checkwinsize
export HISTSIZE=100000
export HISTFILESIZE=200000
export HISTIGNORE="ls:ll:la:l:h:m:cls"

# PS0 intentionally unset — PS1's leading \n handles all inter-prompt spacing.
# Setting PS0="\n" would double-space prompts when commands produce no output.

# ==============================================================================
# 2. ERROR HANDLING
# ==============================================================================
# @modular-section: error-handling
# @depends: constants
# @exports: (none — sets ERR trap only)
#
# Trap ERR to log failed commands with timestamps for post-mortem debugging.
# Exit code 1 is filtered out because grep/test/[[ return 1 for normal
# "not found" / "false" conditions and would flood the log with false positives.
# Only exit codes >= 2 (real errors) are logged.
trap '__tac_last_err=$?; (( __tac_last_err > 1 )) && echo "$(date +"%Y-%m-%d %H:%M:%S") [EXIT $__tac_last_err] $BASH_COMMAND" >> "$ErrorLogPath" 2>/dev/null' ERR

# ==============================================================================
# 3. ALIAS DEFINITIONS & SHORTCUTS
# ==============================================================================
# @modular-section: aliases
# @depends: constants
# @exports: code, oedit, llmconf, oclogs, le, lo, occonf, os, oa, ocstat,
#   ocgs, ocv, mem-index, status, ocms, cop, cop-ask, cop-init (plus standard shell aliases)

# Core OS
alias ls='ls --color=auto'
alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
alias alert='notify-send --urgency=low -i "$([ $? = 0 ] && echo terminal || echo error)" "$(history|tail -n1|sed -e '\''s/^\s*[0-9]\+\s*//;s/[;&|]\s*alert$//'\'')"'

# Tactical UI & Navigation
alias h='tactical_help'
alias cls='clear_tactical'
alias reload='__sync_bashrc_tracked; command clear; exec bash'
alias m='tactical_dashboard'
alias cpwd='copy_path'

# Dev Tools & VS Code Wrappers (lazy-resolved — no pwsh hit at shell start)
code()    { __resolve_vscode_bin; "$VSCODE_BIN" "$@"; }
oedit()   { __resolve_vscode_bin; "$VSCODE_BIN" "$WAYNE_HOME/.bashrc"; echo "VS Code opened... (run 'reload' to sync tracked copy)"; }
llmconf() { __resolve_vscode_bin; "$VSCODE_BIN" "$LLM_REGISTRY"; echo "VS Code opened..."; }
oclogs()  { __resolve_vscode_bin; "$VSCODE_BIN" "$OC_TMP_LOG"; echo "VS Code opened..."; }
le()      { journalctl --user -u openclaw-gateway.service --no-pager -n 60 --output=cat 2>&1 | tail -40; }
lo()      { journalctl --user -u openclaw-gateway.service --no-pager -n 120 --output=cat 2>&1; }
occonf()  { __resolve_vscode_bin; "$VSCODE_BIN" "$OC_ROOT/openclaw.json"; echo "VS Code opened..."; }

alias deploy='deploy_sync'
alias commit:='commit_deploy'
alias commit='commit_auto'
alias oc-agent-turn='ocstart'

# OpenClaw shortcuts (functions defined in section 9)
os()         { openclaw sessions; }
oa()         { openclaw agents list; }
ocstat()     { openclaw status --all; }
ocgs()       { openclaw gateway status --deep; }
ocv()        { openclaw --version; }
mem-index()  { openclaw memory index; }
status()     { openclaw status; }
ocms()       { openclaw models status --probe; }

# GitHub Copilot CLI
alias '??'='copilot -p'
alias cop='copilot'
cop-init() { copilot init; }
cop-ask()  { copilot -p "$*"; }

# LLM & Inference
alias chat:='local_chat'
alias 'wtf:'='wtf_repl'

# ==============================================================================
# 4. DESIGN TOKENS
# ==============================================================================
# @modular-section: design-tokens
# @depends: none
# @exports: C_Reset, C_BoxBg, C_Border, C_Text, C_Dim, C_Highlight, C_Success,
#   C_Warning, C_Error, C_Info (all readonly)
#
# ANSI colour constants for the tactical UI. Declared readonly so they cannot be
# accidentally mutated. They are NOT exported — child processes do not need them.
# C_BoxBg uses 256-color (38;5;30) for the unique teal border tone; all others
# use basic 16-color codes for maximum terminal compatibility.
if [[ -z "${C_Reset:-}" ]]; then
    readonly C_Reset=$'\e[0m'
    readonly C_BoxBg=$'\e[38;5;30m'    # DarkCyan (256-color)
    readonly C_Border=$'\e[36m'        # Cyan
    readonly C_Text=$'\e[37m'          # White
    readonly C_Dim=$'\e[90m'           # Gray
    readonly C_Highlight=$'\e[96m'     # Light Cyan
    readonly C_Success=$'\e[32m'       # Green
    readonly C_Warning=$'\e[33m'       # Yellow
    readonly C_Error=$'\e[31m'         # Red
    readonly C_Info=$'\e[34m'          # Blue
fi

# ==============================================================================
# 5. UI HELPER ENGINE
# ==============================================================================
# @modular-section: ui-engine
# @depends: constants, design-tokens
# @exports: __strip_ansi, __tac_header, __tac_footer, __tac_divider, __tac_info,
#   __tac_line, __fRow, __hSection, __hRow, __show_header, clear_tactical
#
# All __tac_* functions render box-drawn UI elements using the UIWidth constant.
# They use printf -v for padding generation (no subshells / no seq) for speed.
# Helper functions (__fRow, __hRow, __hSection) are defined here to keep all
# UI primitives in one section. They are prefixed with __ to signal "internal".
#
# DIVIDER STYLES (intentional distinction):
#   ╠═══╣  Major section break (double-line) — used in dashboard between blocks
#   ╟───╢  Within-section divider (single-line) — __tac_divider(), used in up()

# ---------------------------------------------------------------------------
# __strip_ansi — Strip ANSI escape codes from a string (pure bash, zero forks).
# Usage: __strip_ansi "string_with_colors" result_var
#   Sets the named variable to the stripped text using bash regex only.
#   No subshells, no sed — critical for dashboard render speed (called 20+ times).
# ---------------------------------------------------------------------------
__strip_ansi() {
    local input="$1" varname="$2" tmp
    tmp="$input"
    while [[ "$tmp" =~ $'\e\['[0-9\;]*[mK] ]]; do
        tmp="${tmp//${BASH_REMATCH[0]}/}"
    done
    printf -v "$varname" '%s' "$tmp"
}

# ---------------------------------------------------------------------------
# __tac_header — Render a box header with centred title.
# Usage: __tac_header "TITLE" [open|closed] [version]
# ---------------------------------------------------------------------------
function __tac_header() {
    local title="$1"
    local style="${2:-closed}"
    local version="$3"

    local inner_width=$((UIWidth - 2))
    local line; printf -v line '%*s' "$inner_width" ''; line="${line// /═}"

    local pad_left=$(( (inner_width - ${#title}) / 2 ))
    local pad_right=$(( inner_width - ${#title} - pad_left ))

    local left_space=""; (( pad_left  > 0 )) && printf -v left_space  '%*s' "$pad_left"  ""
    local right_space=""; (( pad_right > 0 )) && printf -v right_space '%*s' "$pad_right" ""

    local base_str="${left_space}${title}${right_space}"

    printf "${C_BoxBg}╔${line}╗${C_Reset}\n"

    if [[ -n "$version" ]]; then
        local ver_str="(ver.: $version)"
        local ver_len=${#ver_str}
        local left_part="${base_str:0:$((inner_width - ver_len))}"
        printf "${C_BoxBg}║${C_Reset}${C_Highlight}%s${C_Reset}${C_Dim}%s${C_Reset}${C_BoxBg}║${C_Reset}\n" "$left_part" "$ver_str"
    else
        printf "${C_BoxBg}║${C_Reset}${C_Highlight}%s${C_Reset}${C_BoxBg}║${C_Reset}\n" "$base_str"
    fi

    if [[ "$style" == "open" ]]; then
        printf "${C_BoxBg}╠${line}╣${C_Reset}\n"
    elif [[ "$style" == "closed" ]]; then
        printf "${C_BoxBg}╚${line}╝${C_Reset}\n"
    fi
}

# ---------------------------------------------------------------------------
# __tac_footer — Render the closing bottom border of a box.
# ---------------------------------------------------------------------------
function __tac_footer() {
    local inner_width=$((UIWidth - 2))
    local line; printf -v line '%*s' "$inner_width" ''; line="${line// /═}"
    printf "${C_BoxBg}╚${line}╝${C_Reset}\n"
}

# ---------------------------------------------------------------------------
# __tac_divider — Render a single-line horizontal divider within a box.
# ---------------------------------------------------------------------------
function __tac_divider() {
    local inner_width=$((UIWidth - 2))
    local line; printf -v line '%*s' "$inner_width" ''; line="${line// /─}"
    printf "${C_BoxBg}╟${line}╢${C_Reset}\n"
}

# ---------------------------------------------------------------------------
# __tac_info — Borderless status line for quick command feedback.
# Usage: __tac_info "Label" "[STATUS]" "$C_Color"
# ---------------------------------------------------------------------------
__tac_info() {
    local label="$1" status="$2" color="${3:-$C_Text}"
    local cleanLabel; __strip_ansi "$label" cleanLabel
    local cleanStatus; __strip_ansi "$status" cleanStatus
    local padLen=$(( UIWidth - ${#cleanLabel} - ${#cleanStatus} ))
    (( padLen < 1 )) && padLen=1
    local pad; printf -v pad '%*s' "$padLen" ""
    printf "${C_Dim}%b${C_Reset}%s${color}%b${C_Reset}\n" "$label" "$pad" "$status"
}

# ---------------------------------------------------------------------------
# __tac_line — Render a bordered row with action text and right-aligned status.
# Usage: __tac_line "Action text" "[STATUS]" "$C_Color"
# Inner text area = UIWidth - 4 (borders + 1-space padding each side).
# ---------------------------------------------------------------------------
function __tac_line() {
    local action="$1" status="$2" color="${3:-$C_Text}"
    local inner_text=$(( UIWidth - 4 ))  # 78 - 4 = 74 (borders + padding)
    local cleanAction; __strip_ansi "$action" cleanAction
    local cleanStatus; __strip_ansi "$status" cleanStatus

    local contentLen=$(( ${#cleanAction} + ${#cleanStatus} ))
    local padLength=$(( inner_text - contentLen ))
    (( padLength < 1 )) && padLength=1

    local padding; printf -v padding '%*s' "$padLength" ""
    printf "${C_BoxBg}║${C_Reset} %b%s%b%b%b ${C_BoxBg}║${C_Reset}\n" "$action" "$padding" "$color" "$status" "$C_Reset"
}

# ---------------------------------------------------------------------------
# __fRow — Dashboard row: "LABEL      :: value" inside box borders.
# Truncates values to prevent border overflow.
# Layout: 2 indent + 12 label + 4 " :: " + val_width + border = UIWidth
# val_width = UIWidth - 20 (2 indent, 12 label, 4 sep, 2 borders)
# Usage: __fRow "LABEL" "value" "$C_Color"
# ---------------------------------------------------------------------------
function __fRow() {
    local label="$1"
    local val="$2"
    local color="${3:-$C_Text}"
    local val_width=$(( UIWidth - 20 ))  # 78 - 20 = 58
    # Strip ANSI codes to measure visible length
    local cleanVal; __strip_ansi "$val" cleanVal
    # Primary truncation: cap at val_width visible chars
    if (( ${#cleanVal} > val_width )); then
        cleanVal="${cleanVal:0:$((val_width - 3))}..."
        val="$cleanVal"
    fi
    local labelPad=$(( 12 - ${#label} ))
    local valPad=$(( val_width - ${#cleanVal} ))
    # Belt-and-suspenders guard — should never trigger after primary truncation
    if (( valPad < 0 )); then
        val="${val:0:$((${#val} + valPad - 3))}..."
        cleanVal="${cleanVal:0:$((${#cleanVal} + valPad))}..."
        valPad=0
    fi

    local lPadStr=""; (( labelPad > 0 )) && printf -v lPadStr '%*s' "$labelPad" ""
    local vPadStr=""; (( valPad  > 0 )) && printf -v vPadStr '%*s' "$valPad"  ""

    printf "${C_BoxBg}║${C_Reset}"
    printf "  ${C_Dim}%s%s :: ${C_Reset}" "$label" "$lPadStr"
    printf "${color}%s${C_Reset}" "$val"
    printf "%s${C_BoxBg}║${C_Reset}\n" "$vPadStr"
}

# ---------------------------------------------------------------------------
# __hSection — Help index section header (centred, double-line border).
# Usage: __hSection "SECTION TITLE"
# ---------------------------------------------------------------------------
function __hSection() {
    local title="$1"
    local inner_width=$((UIWidth - 2))
    local sep; printf -v sep '%*s' "$inner_width" ''; sep="${sep// /═}"
    local pad_left=$(( (inner_width - ${#title}) / 2 ))
    local pad_right=$(( inner_width - ${#title} - pad_left ))

    local left_space=""; (( pad_left  > 0 )) && printf -v left_space  '%*s' "$pad_left"  ""
    local right_space=""; (( pad_right > 0 )) && printf -v right_space '%*s' "$pad_right" ""

    printf "${C_BoxBg}╠${sep}╣${C_Reset}\n"
    printf "${C_BoxBg}║${C_Reset}${C_Warning}%s%s%s${C_Reset}${C_BoxBg}║${C_Reset}\n" "$left_space" "$title" "$right_space"
}

# ---------------------------------------------------------------------------
# __hRow — Help index row: "  command        description" inside box borders.
# Layout derived from UIWidth: cmd_width=18, desc_width = UIWidth - 22.
# Usage: __hRow "command" "Description of what it does"
# ---------------------------------------------------------------------------
function __hRow() {
    local cmd="$1"
    local cmd_width=18
    local desc_width=$(( UIWidth - 22 ))  # 78 - 2 borders - 2 indent - 18 cmd = 56
    local desc="${2:0:$desc_width}"
    local cmdPad=$(( cmd_width - ${#cmd} ))
    local descPad=$(( desc_width - ${#desc} ))

    local lPadStr=""; (( cmdPad  > 0 )) && printf -v lPadStr '%*s' "$cmdPad"  ""
    local rPadStr=""; (( descPad > 0 )) && printf -v rPadStr '%*s' "$descPad" ""

    printf "${C_BoxBg}║  ${C_Highlight}%s%s${C_Text}%s%s${C_BoxBg}║${C_Reset}\n" "$cmd" "$lPadStr" "$desc" "$rPadStr"
}

# ---------------------------------------------------------------------------
# __show_header — Display the oneliner startup banner.
# ---------------------------------------------------------------------------
function __show_header() {
    __tac_header "Bash v${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]} :: 'm' for Dashboard, 'h' for Help."
}

# ---------------------------------------------------------------------------
# clear_tactical — Clear screen and redraw the startup banner.
# ---------------------------------------------------------------------------
function clear_tactical() {
    command clear
    __show_header
}

# ==============================================================================
# 6. SYSTEM HOOKS & OVERRIDES
# ==============================================================================
# @modular-section: hooks
# @depends: constants, design-tokens, ui-engine
# @exports: cd (override), custom_prompt_command, __test_port,
#   _TAC_ADMIN_BADGE, PROMPT_COMMAND

# ---------------------------------------------------------------------------
# cd — Override to auto-activate/deactivate Python virtual environments.
# Activates .venv/bin/activate when entering a directory that contains one.
# Deactivates when leaving the project root (trailing-slash check prevents
# false positives like /home/wayne/project2 matching /home/wayne/project).
# ---------------------------------------------------------------------------
function cd() {
    builtin cd "$@" || return $?

    # Auto-activate .venv if present in new directory
    if [[ -f "$VENV_DIR/bin/activate" ]]; then
        source "$VENV_DIR/bin/activate"
        return
    fi

    # Auto-deactivate if we left the project root
    if [[ -n "$VIRTUAL_ENV" ]]; then
        local venv_root; venv_root=$(dirname "$VIRTUAL_ENV")
        local current_wd; current_wd=$(pwd -P)
        if [[ "$current_wd" != "$venv_root" && "$current_wd" != "$venv_root/"* ]]; then
            type deactivate >/dev/null 2>&1 && deactivate
        fi
    fi
}

if [[ " $(id -nG 2>/dev/null) " == *" sudo "* ]]; then
    _TAC_ADMIN_BADGE=" \[${C_Warning}\]▼\[${C_Reset}\]"
else
    _TAC_ADMIN_BADGE=""
fi

function custom_prompt_command() {
    local lastExit=$?
    history -a

    # If history number hasn't changed, user pressed Enter with no command —
    # clear the error badge so × doesn't persist across empty prompts.
    local -a _hist_arr=($(history 1 2>/dev/null))
    local hist_num="${_hist_arr[0]}"
    if [[ "$hist_num" == "${__tac_last_hist_num:-}" ]]; then
        lastExit=0
    fi
    __tac_last_hist_num="$hist_num"

    local ps1_user="\[${C_Highlight}\]\u\[${C_Reset}\]"
    local exit_badge=" \[${C_Error}\]×\[${C_Reset}\] "
    (( lastExit == 0 )) && exit_badge=" \[${C_Success}\]✓\[${C_Reset}\] "
    local ps1_path="\[${C_Info}\]\w\[${C_Reset}\]"
    local ps1_venv=""
    [[ -n "$VIRTUAL_ENV" ]] && ps1_venv=" \[${C_Success}\]($(basename "$VIRTUAL_ENV"))\[${C_Reset}\]"

    PS1="\n${ps1_user}${_TAC_ADMIN_BADGE}${exit_badge}${ps1_path}${ps1_venv} \[${C_Dim}\]> \[${C_Reset}\]"
}

if [[ "$PROMPT_COMMAND" != *"custom_prompt_command"* ]]; then
    PROMPT_COMMAND="custom_prompt_command${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
fi

# ---------------------------------------------------------------------------
# __test_port — Instant port check via kernel socket table (returns 0 if listening).
# Usage: __test_port <port_number>
# ---------------------------------------------------------------------------
function __test_port() { ss -tln "sport = :$1" 2>/dev/null | grep -q LISTEN; }

# ==============================================================================
# 7. TELEMETRY & HARDWARE (FAST CACHING)
# ==============================================================================
# @modular-section: telemetry
# @depends: constants, design-tokens, ui-engine
# @exports: __cache_fresh, __get_uptime, __get_disk, __get_host_metrics, __get_gpu,
#   __get_battery, __get_git, __get_tokens, __get_oc_version, __get_oc_metrics,
#   __get_llm_slots
#
# All telemetry functions use /dev/shm caching and background subshells to avoid
# blocking the dashboard render. Cache TTLs are tuned per metric volatility.

# ---------------------------------------------------------------------------
# __cache_fresh — Check if a cache file exists and is younger than TTL seconds.
# Usage: __cache_fresh <cache_path> <ttl_seconds>  →  returns 0 (fresh) or 1
# Deduplicates the repeated freshness-check pattern across all telemetry funcs.
# ---------------------------------------------------------------------------
__cache_fresh() {
    [[ -f "$1" ]] && (( $(date +%s) - $(stat -c %Y "$1" 2>/dev/null || echo 0) < $2 ))
}

# ---------------------------------------------------------------------------
# __get_uptime — Format system uptime as "Xd Yh Zm".
# ---------------------------------------------------------------------------
function __get_uptime() {
    awk '{print int($1/86400)"d "int(($1%86400)/3600)"h "int(($1%3600)/60)"m"}' /proc/uptime
}

# ---------------------------------------------------------------------------
# __get_disk — Summarise free space on C: and WSL root.
# ---------------------------------------------------------------------------
function __get_disk() {
    local __unit_fix='s/\([0-9.]\)G/\1 Gb/;s/\([0-9.]\)M/\1 Mb/;s/\([0-9.]\)T/\1 Tb/'
    local c_drive; c_drive=$(df -h /mnt/c 2>/dev/null | awk 'NR==2 {print $4" free"}' | sed "$__unit_fix")
    local wsl_drive; wsl_drive=$(df -h / | awk 'NR==2 {print $4" free"}' | sed "$__unit_fix")
    if [[ -n "$c_drive" ]]; then
        echo "C: $c_drive | WSL: $wsl_drive"
    else
        df -h / | awk 'NR==2 {print $4" free ("$5" used)"}' | sed "$__unit_fix"
    fi
}

# ---------------------------------------------------------------------------
# __get_host_metrics — Return CPU% | GPU0% | GPU1% from Windows host (10s TTL).
# Uses typeperf.exe for CPU + both GPUs (Intel Iris + NVIDIA RTX) in one call.
# On first call after cache expiry, returns stale data while background
# refresh runs (~4s via typeperf).
# ---------------------------------------------------------------------------
function __get_host_metrics() {
    local cache="$TAC_CACHE_DIR/tac_hostmetrics"
    if ! __cache_fresh "$cache" 10; then
        ( bash "$HOME/.local/bin/tac_hostmetrics.sh" > "${cache}.tmp" 2>/dev/null && mv "${cache}.tmp" "$cache" ) &>/dev/null &
        __TAC_BG_PIDS+=("$!")
    fi
    [[ -f "$cache" ]] && cat "$cache" || echo "0|0|0"
}

# ---------------------------------------------------------------------------
# __get_gpu — Return CSV: name,temp,utilization,mem_used,mem_total (10s TTL).
# NVIDIA-only detail for the GPU COMPUTE dashboard row.
# ---------------------------------------------------------------------------
function __get_gpu() {
    local cache="$TAC_CACHE_DIR/tac_gpu"
    if __cache_fresh "$cache" 10; then
        cat "$cache"; return
    fi
    (
        local smi_cmd="$WSL_NVIDIA_SMI"
        [[ ! -f "$smi_cmd" ]] && smi_cmd=$(command -v nvidia-smi 2>/dev/null)
        if [[ -n "$smi_cmd" && -x "$smi_cmd" ]]; then
            local raw; raw=$("$smi_cmd" --query-gpu=name,temperature.gpu,utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null)
            [[ -n "$raw" ]] && printf '%s' "${raw//NVIDIA GeForce /}" > "${cache}.tmp" && mv "${cache}.tmp" "$cache"
        else
            echo "N/A" > "${cache}.tmp" && mv "${cache}.tmp" "$cache"
        fi
    ) &>/dev/null &
    __TAC_BG_PIDS+=("$!")
    [[ -f "$cache" ]] && cat "$cache" || echo "Querying..."
}

# ---------------------------------------------------------------------------
# __get_battery — Return battery percentage + status string (120s TTL).
# Uses /sys/class/power_supply on laptops; skips pwsh entirely on desktops
# (detected once at startup via __TAC_HAS_BATTERY).
# ---------------------------------------------------------------------------
function __get_battery() {
    local cache="$TAC_CACHE_DIR/tac_batt"
    if __cache_fresh "$cache" 120; then
        cat "$cache"; return
    fi
    (
        if (( __TAC_HAS_BATTERY == 1 )); then
            local cap; cap=$(cat /sys/class/power_supply/BAT0/capacity 2>/dev/null || echo "100")
            local bstat; bstat=$(cat /sys/class/power_supply/BAT0/status 2>/dev/null || echo "Unknown")
            echo "${cap}% (${bstat})" > "${cache}.tmp" && mv "${cache}.tmp" "$cache"
        else
            echo "A/C POWERED" > "${cache}.tmp" && mv "${cache}.tmp" "$cache"
        fi
    ) &>/dev/null &
    __TAC_BG_PIDS+=("$!")
    [[ -f "$cache" ]] && cat "$cache" || echo "Querying..."
}

# ---------------------------------------------------------------------------
# __get_git — Return "branch|SECURE" or "branch|BREACHED" for git repos.
# Returns empty string if not inside a git worktree.
# ---------------------------------------------------------------------------
function __get_git() {
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        local branch; branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
        local dirty; dirty=$([[ -n $(git status --porcelain) ]] && echo "BREACHED" || echo "SECURE")
        echo "$branch|$dirty"
    fi
}

# ---------------------------------------------------------------------------
# __get_tokens — Read token usage from the most-recent OpenClaw session (30s TTL).
# Scans agents/*/sessions/sessions.json for the newest session with totalTokens.
# Returns "used|limit" or "N/A|0".
# ---------------------------------------------------------------------------
function __get_tokens() {
    local cache="$TAC_CACHE_DIR/tac_tokens"
    if __cache_fresh "$cache" 30; then
        cat "$cache"; return
    fi
    (
        local found=0
        while IFS= read -r f; do
            local result
            result=$(jq -r '
                [ to_entries[].value
                  | select(.totalTokens != null and .totalTokens > 0
                          and .contextTokens != null and .contextTokens > 0) ]
                | sort_by(.updatedAt) | last
                | "\(.totalTokens)|\(.contextTokens)"
            ' "$f" 2>/dev/null)
            if [[ -n "$result" && "$result" != "null|null" ]]; then
                echo "$result" > "${cache}.tmp" && mv "${cache}.tmp" "$cache"
                found=1
                break
            fi
        done < <(find "$OC_AGENTS" -name "sessions.json" -type f \
            -printf '%T@ %p\n' 2>/dev/null | \
            sort -n -r | head -n 10 | cut -d' ' -f2-)
        (( found == 0 )) && echo "N/A|0" > "${cache}.tmp" && mv "${cache}.tmp" "$cache"
    ) &>/dev/null &
    __TAC_BG_PIDS+=("$!")
    [[ -f "$cache" ]] && cat "$cache" || echo "Querying...|0"
}

# ---------------------------------------------------------------------------
# __get_oc_version — Fetch OpenClaw CLI version (24h TTL — barely changes).
# ---------------------------------------------------------------------------
function __get_oc_version() {
    local cache="$TAC_CACHE_DIR/tac_ocversion"
    if __cache_fresh "$cache" 86400; then
        cat "$cache"; return
    fi
    (
        local ocVersion="UNKNOWN"
        if command -v openclaw >/dev/null; then
            ocVersion=$(openclaw --version 2>/dev/null | awk '{print $NF}' | tr -d '\r\n')
            [[ -n "$ocVersion" ]] && ocVersion="v${ocVersion#v}"
        fi
        echo "$ocVersion" > "${cache}.tmp" && mv "${cache}.tmp" "$cache"
    ) &>/dev/null &
    __TAC_BG_PIDS+=("$!")
    [[ -f "$cache" ]] && cat "$cache" || echo "Querying..."
}

# ---------------------------------------------------------------------------
# __get_oc_metrics — Fetch OpenClaw session count (60s TTL) + version (24h TTL).
# Combines the session count and cached version into "count|version".
# ---------------------------------------------------------------------------
function __get_oc_metrics() {
    local ver; ver=$(__get_oc_version)
    local cache="$TAC_CACHE_DIR/tac_ocmetrics"
    if __cache_fresh "$cache" 60; then
        cat "$cache"; return
    fi
    (
        local sessionCount=0
        if command -v openclaw >/dev/null; then
            sessionCount=$(openclaw sessions --all-agents --json 2>/dev/null | jq -r '.count // 0' 2>/dev/null)
            sessionCount=${sessionCount:-0}
        fi
        echo "$sessionCount|$ver" > "${cache}.tmp" && mv "${cache}.tmp" "$cache"
    ) &>/dev/null &
    __TAC_BG_PIDS+=("$!")
    [[ -f "$cache" ]] && cat "$cache" || echo "Querying...|$ver"
}

# ---------------------------------------------------------------------------
# __get_llm_slots — Async-cached query to llama.cpp /slots endpoint (5s TTL).
# Returns JSON from the /slots API, or empty string if unavailable.
# ---------------------------------------------------------------------------
function __get_llm_slots() {
    local cache="$TAC_CACHE_DIR/tac_llm_slots"
    if __cache_fresh "$cache" 5; then
        cat "$cache"; return
    fi
    (
        if __test_port "$LLM_PORT"; then
            curl -sf --max-time 2 "http://127.0.0.1:${LLM_PORT}/slots" > "${cache}.tmp" 2>/dev/null \
                && mv "${cache}.tmp" "$cache"
        fi
    ) &>/dev/null &
    __TAC_BG_PIDS+=("$!")
    [[ -f "$cache" ]] && cat "$cache"
}

# ==============================================================================
# 8. MAINTENANCE & UTILS
# ==============================================================================
# @modular-section: maintenance
# @depends: constants, design-tokens, ui-engine, telemetry
# @exports: __cleanup_temps, __check_cooldown, __set_cooldown, get-ip, up, cl,
#   __sync_bashrc_tracked, copy_path, sysinfo, logtrim

# ---------------------------------------------------------------------------
# __cleanup_temps — Remove temp files from known safe locations only.
# Only cleans python-*.exe and .pytest_cache from $PWD. Does NOT remove
# *.log files (too dangerous in arbitrary directories). Used by cl().
# ---------------------------------------------------------------------------
__cleanup_temps() {
    local count=0
    local f
    local _had_nullglob=0; shopt -q nullglob && _had_nullglob=1
    shopt -s nullglob
    for f in python-*.exe .pytest_cache; do
        if [[ -e "$f" ]]; then
            rm -rf "$f" && ((count++))
        fi
    done
    (( _had_nullglob )) || shopt -u nullglob
    echo "$count"
}

# ---------------------------------------------------------------------------
# __check_cooldown — Check if a maintenance task's 7-day cooldown has expired.
# Usage: time_left=$(__check_cooldown <key> <now_timestamp>)
# Returns 0 if cooldown has expired (task should run), 1 if still active.
# On return 1, prints remaining time (e.g. "6d 12h") to stdout.
# Dependencies: $CooldownDB must be set and touchable.
# ---------------------------------------------------------------------------
__check_cooldown() {
    local key="$1" now="$2"
    # Per-key cooldown periods (default 7 days)
    local cooldown
    case "$key" in
        apt_index)  cooldown=86400  ;;  # 24 hours — security index
        apt)        cooldown=604800 ;;  # 7 days  — package upgrades
        *)          cooldown=604800 ;;  # 7 days  — everything else
    esac
    local last_run; last_run=$(grep "^${key}=" "$CooldownDB" 2>/dev/null | tail -n 1 | cut -d= -f2)
    last_run=${last_run:-0}
    local diff=$(( now - last_run ))
    if (( diff < cooldown )); then
        local remaining=$(( cooldown - diff ))
        local days=$(( remaining / 86400 ))
        local hours=$(( (remaining % 86400) / 3600 ))
        if (( days > 0 )); then
            echo "${days}d ${hours}h"
        else
            echo "${hours}h"
        fi
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# __set_cooldown — Record that a maintenance task was just completed.
# Usage: __set_cooldown <key> <now_timestamp>
# ---------------------------------------------------------------------------
__set_cooldown() {
    local key="$1" now="$2"
    { grep -v "^${key}=" "$CooldownDB" 2>/dev/null; echo "${key}=${now}"; } > "${CooldownDB}.tmp" && mv "${CooldownDB}.tmp" "$CooldownDB"
}

# ---------------------------------------------------------------------------
# get-ip — Show WSL Ubuntu IP and external WAN IP.
# Renamed from ip() to avoid shadowing /usr/bin/ip (used by WSL loopback fix).
# ---------------------------------------------------------------------------
function get-ip() {
    local wslIp; wslIp=$(hostname -I | awk '{print $1}')
    [[ -z "$wslIp" ]] && wslIp="UNKNOWN"
    __tac_info "WSL Ubuntu IP" "[$wslIp]" "$C_Success"

    local extIp; extIp=$(curl -s --connect-timeout 2 https://api.ipify.org)
    [[ -z "$extIp" ]] && extIp="TIMEOUT / UNAVAILABLE"
    __tac_info "External WAN IP" "[$extIp]" "$([[ $extIp == TIMEOUT* ]] && echo "$C_Error" || echo "$C_Warning")"
}

# ---------------------------------------------------------------------------
# up — Run 10-step system maintenance with 24h cooldowns per step.
# Cooldown functions (__check_cooldown / __set_cooldown) are defined above
# in this section to avoid leaking nested function definitions.
# ---------------------------------------------------------------------------
function up() {
    command clear
    __tac_header "SYSTEM MAINTENANCE" "open"
    local errCount=0
    local now; now=$(date +%s)
    local hours_left=0
    touch "$CooldownDB" 2>/dev/null

    # [1/10] Connectivity
    if ping -c 1 -W 2 github.com >/dev/null 2>&1; then
        __tac_line "[1/10] Internet Connectivity" "[ESTABLISHED]" "$C_Success"
    else
        __tac_line "[1/10] Internet Connectivity" "[LOST]" "$C_Error"
        ((errCount++))
    fi

    # [2/10] APT Index Update (24h cooldown) + Package Upgrade (7d cooldown)
    # Logic:
    #   1. If apt_index cooldown (24h) expired → update index only
    #   2. If apt cooldown (7d) expired → upgrade packages (updates index if not already done)
    #   3. If only index was refreshed → show that
    #   4. If both cached → show "CACHED"
    local apt_did_update=0
    if hours_left=$(__check_cooldown "apt_index" "$now"); then
        if sudo apt-get update >/dev/null 2>&1; then
            apt_did_update=1
            __set_cooldown "apt_index" "$now"
        fi
    fi
    if hours_left=$(__check_cooldown "apt" "$now"); then
        (( apt_did_update )) || sudo apt-get update >/dev/null 2>&1
        sudo apt-get upgrade -y --no-install-recommends >/dev/null 2>&1
        local apt_rc=$?
        if (( apt_rc == 0 )); then
            __tac_line "[2/10] APT Packages" "[UPDATED]" "$C_Success"
            __set_cooldown "apt" "$now"
            __set_cooldown "apt_index" "$now"  # upgrade implies fresh index
        else
            __tac_line "[2/10] APT Packages" "[FAILED]" "$C_Error"
            ((errCount++))
        fi
    else
        if (( apt_did_update )); then
            __tac_line "[2/10] APT Index" "[REFRESHED]" "$C_Success"
        else
            __tac_line "[2/10] APT Packages" "[CACHED - ${hours_left} LEFT]" "$C_Dim"
        fi
    fi

    # [3/10] NPM / Cargo
    if hours_left=$(__check_cooldown "npm_cargo" "$now"); then
        local pkg_err=0
        command -v npm >/dev/null && { npm update -g --quiet >/dev/null 2>&1 || pkg_err=1; }
        command -v cargo >/dev/null && { cargo install-update -a >/dev/null 2>&1 || pkg_err=1; }

        if (( pkg_err == 0 )); then
            __tac_line "[3/10] NPM & Cargo Crates" "[UPDATED]" "$C_Success"
            __set_cooldown "npm_cargo" "$now"
        else
            __tac_line "[3/10] NPM & Cargo Crates" "[WARNING/FAILED]" "$C_Warning"
            ((errCount++))
        fi
    else
        __tac_line "[3/10] NPM & Cargo Crates" "[CACHED - ${hours_left} LEFT]" "$C_Dim"
    fi

    # [4/10] OpenClaw verification — runs 'openclaw doctor' for real health check
    if hours_left=$(__check_cooldown "openclaw" "$now"); then
        if command -v openclaw >/dev/null; then
            local doc_out; doc_out=$(openclaw doctor 2>&1)
            local doc_rc=$?
            if (( doc_rc == 0 )); then
                __tac_line "[4/10] OpenClaw Framework" "[HEALTHY]" "$C_Success"
            else
                __tac_line "[4/10] OpenClaw Framework" "[ISSUES FOUND - run ocdoc-fix]" "$C_Warning"
                ((errCount++))
            fi
            __set_cooldown "openclaw" "$now"
        else
            __tac_line "[4/10] OpenClaw Framework" "[MISSING]" "$C_Error"
            ((errCount++))
        fi
    else
        __tac_line "[4/10] OpenClaw Framework" "[CACHED - ${hours_left} LEFT]" "$C_Dim"
    fi

    # [5/10] Python Venv (a.k.a. "Cloaking" = active virtual environment isolation)
    if [[ -n "$VIRTUAL_ENV" ]]; then
        __tac_line "[5/10] Python Venv Cloaking" "[$(basename "$VIRTUAL_ENV")]" "$C_Success"
    else
        __tac_line "[5/10] Python Venv Cloaking" "[INACTIVE]" "$C_Dim"
    fi

    # [6/10] Python Fleet
    if hours_left=$(__check_cooldown "pyfleet" "$now"); then
        local py_versions=()
        local _py
        for _py in /usr/bin/python3.[0-9]*; do
            [[ -x "$_py" ]] && py_versions+=("$_py")
        done
        if [[ ${#py_versions[@]} -gt 0 ]]; then
            local v_list=()
            for py in "${py_versions[@]}"; do
                v_list+=("$(basename "$py")")
            done
            __tac_line "[6/10] Python Fleet" "[${v_list[*]} VERIFIED]" "$C_Success"
            __set_cooldown "pyfleet" "$now"
        else
            __tac_line "[6/10] Python Fleet" "[NO VERSIONS DETECTED]" "$C_Warning"
            ((errCount++))
        fi
    else
        __tac_line "[6/10] Python Fleet" "[CACHED - ${hours_left} LEFT]" "$C_Dim"
    fi

    # [7/10] GPU Checks
    local gpu; gpu=$(__get_gpu)

    if [[ "$gpu" != "N/A" && "$gpu" != "Querying..." && "$gpu" != *"OFFLINE"* ]]; then
        __tac_line "[7/10] RTX 3050 Ti" "[READY]" "$C_Success"
    else
        __tac_line "[7/10] GPU Status" "[OFFLINE OR ERROR]" "$C_Warning"
        ((errCount++))
    fi

    # [8/10] Sanitation — clean known temp locations, NOT the user's $PWD.
    # Only removes temp artifacts from /tmp/openclaw and the OC_ROOT directory.
    local count=0
    if [[ -d /tmp/openclaw ]]; then
        while IFS= read -r -d '' _tmpf; do
            rm -f "$_tmpf" && ((count++))
        done < <(find /tmp/openclaw \( -name '*.tmp' -o -name 'python-*.exe' \) -print0 2>/dev/null)
    fi
    __tac_line "[8/10] Temp File Sanitation" "[$count CLEANED]" "$C_Success"

    # [9/10] Disk Space Audit — warn if any mount point exceeds 90%
    local disk_warn=0
    while read -r pct mount; do
        local pct_num=${pct%\%}
        if (( pct_num >= 90 )); then
            __tac_line "[9/10] Disk: $mount" "[${pct} USED - LOW SPACE]" "$C_Error"
            disk_warn=1
            ((errCount++))
        fi
    done < <(df -h --output=pcent,target 2>/dev/null | tail -n +2 | grep -v '/snap/' | grep -v '/mnt/wsl/docker-desktop')
    (( disk_warn == 0 )) && __tac_line "[9/10] Disk Space Audit" "[ALL MOUNTS < 90%]" "$C_Success"

    # [10/10] Stale Process Cleanup — kill orphaned llama-server instances
    # Uses pgrep -f (not PID-based port check) intentionally: we want ALL
    # llama-server processes, not just the one on $LLM_PORT. Orphans may
    # exist on other ports or have lost their listen socket.
    local stale_pids; stale_pids=$(pgrep -f llama-server 2>/dev/null | wc -l)
    if (( stale_pids > 0 )) && ! __test_port "$LLM_PORT"; then
        pkill -f llama-server 2>/dev/null
        rm -f "$ACTIVE_LLM_FILE"
        __tac_line "[10/10] Stale Processes" "[$stale_pids ORPHAN(S) KILLED]" "$C_Warning"
    else
        __tac_line "[10/10] Stale Processes" "[CLEAN]" "$C_Success"
    fi

    __tac_divider
    if (( errCount > 0 )); then
        __tac_line "Maintenance Status" "[COMPLETED WITH $errCount ISSUE(S)]" "$C_Warning"
    else
        __tac_line "Maintenance Status" "[SYSTEMS AT PEAK PARITY]" "$C_Success"
    fi
    __tac_footer
}

# ---------------------------------------------------------------------------
# cl — Quick cleanup without the full maintenance run.
# ---------------------------------------------------------------------------
function cl() {
    local count; count=$(__cleanup_temps)
    __tac_info "Sanitation..." "[$count artifacts removed]" "$C_Success"
}

# ---------------------------------------------------------------------------
# __sync_bashrc_tracked — Copy ~/.bashrc to the git-tracked backup in .openclaw.
# Called automatically by 'reload'. No-op if files are identical.
# ---------------------------------------------------------------------------
__sync_bashrc_tracked() {
    local src="$HOME/.bashrc"
    local dst="$OPENCLAW_ROOT/bashrc.tracked"
    if [[ -f "$src" ]] && ! cmp -s "$src" "$dst" 2>/dev/null; then
        cp "$src" "$dst"
        ( cd "$OPENCLAW_ROOT" && git add bashrc.tracked && git commit -m "Auto-sync .bashrc (v${TACTICAL_PROFILE_VERSION})" --quiet ) 2>/dev/null
        __tac_info ".bashrc backup" "[SYNCED + COMMITTED]" "$C_Success"
    fi
}

# ---------------------------------------------------------------------------
# copy_path — Copy the current working directory to the Windows clipboard.
# ---------------------------------------------------------------------------
function copy_path() {
    pwd | tr -d '\r\n' | clip.exe 2>/dev/null
    __tac_info "Clipboard" "[$(pwd)]" "$C_Success"
}

# ---------------------------------------------------------------------------
# sysinfo — One-line hardware summary without the full dashboard.
# Usage: sysinfo
# ---------------------------------------------------------------------------
function sysinfo() {
    local host_raw; host_raw=$(__get_host_metrics)
    local cpu gpu0 gpu1
    IFS='|' read -r cpu gpu0 gpu1 <<< "$host_raw"
    cpu=${cpu:-0}; gpu0=${gpu0:-0}; gpu1=${gpu1:-0}
    local mem_used mem_total mem_pct
    read -r mem_used mem_total mem_pct <<< "$(free -m | awk 'NR==2{printf "%.1f %.1f %d", $3/1024, $2/1024, $3*100/$2}')"
    local disk; disk=$(df -h / | awk 'NR==2{print $4}' | sed 's/\([0-9.]\)G/\1 Gb/;s/\([0-9.]\)M/\1 Mb/')
    local gpu_raw; gpu_raw=$(__get_gpu)
    local gpu_info="N/A" gpu_color=$C_Dim
    if [[ "$gpu_raw" != "N/A" && "$gpu_raw" != "Querying..." ]]; then
        local _g_name g_temp g_util _g_mu _g_mt
        IFS=',' read -r _g_name g_temp g_util _g_mu _g_mt <<< "$gpu_raw"
        g_util=${g_util// /}; g_util=${g_util%%%}; g_temp=${g_temp// /}
        gpu_info="${g_util}%/${g_temp}°C"
        if (( g_util > 90 )); then gpu_color=$C_Error
        elif (( g_util > 75 )); then gpu_color=$C_Warning
        else gpu_color=$C_Success; fi
    fi
    # CPU colour
    local cpu_color=$C_Success
    if (( cpu > 90 )); then cpu_color=$C_Error
    elif (( cpu > 75 )); then cpu_color=$C_Warning; fi
    # Memory colour
    local mem_color=$C_Success
    if (( mem_pct > 90 )); then mem_color=$C_Error
    elif (( mem_pct > 75 )); then mem_color=$C_Warning; fi
    # GPU1 colour (same thresholds as CPU/GPU0)
    local gpu1_color=$C_Success
    if (( gpu1 > 90 )); then gpu1_color=$C_Error
    elif (( gpu1 > 75 )); then gpu1_color=$C_Warning; fi
    echo -e "${C_Dim}CPU:${C_Reset} ${cpu_color}${cpu}%${C_Reset} ${C_Dim}RAM:${C_Reset} ${mem_color}${mem_used} / ${mem_total} Gb${C_Reset} ${C_Dim}Disk:${C_Reset} ${disk} ${C_Dim}GPU0:${C_Reset} ${gpu_color}${gpu_info}${C_Reset} ${C_Dim}GPU1:${C_Reset} ${gpu1_color}${gpu1}%${C_Reset}"
}

# ---------------------------------------------------------------------------
# logtrim — Trim logs larger than 1 MB to their last 1000 lines.
# ---------------------------------------------------------------------------
function logtrim() {
    local total=0
    local _had_nullglob=0; shopt -q nullglob && _had_nullglob=1
    shopt -s nullglob
    for logfile in "$OC_LOGS"/*.log "$ErrorLogPath" "$LLM_LOG_FILE"; do
        if [[ -f "$logfile" ]] && (( $(stat -c%s "$logfile" 2>/dev/null || echo 0) > 1048576 )); then
            tail -n 1000 "$logfile" > "${logfile}.tmp" || continue
            mv "${logfile}.tmp" "$logfile" || { rm -f "${logfile}.tmp"; continue; }
            ((total++))
        fi
    done
    (( _had_nullglob )) || shopt -u nullglob
    __tac_info "Trimmed Logs (>1 Mb)" "[$total files]" "$C_Success"
}

# ==============================================================================
# 9. OPENCLAW MANAGER
# ==============================================================================
# @modular-section: openclaw
# @depends: constants, design-tokens, ui-engine, hooks
# @exports: so, xo, oc-restart, ocstart, ocstop, ockeys, ocdoc-fix,
#   __bridge_windows_api_keys, oc-refresh-keys, oc-backup, oc-restore,
#   owk, ologs, ocroot, lc, oc-update, oc-health, oc-cron, oc-skills,
#   oc-plugins, oc-tail, oc-channels, oc-sec, oc-tui, oc-config,
#   oc-docs, oc-usage, oc-memory-search, oc-local-llm, oc-sync-models,
#   oc-browser, oc-nodes, oc-sandbox, oc-env, oc-cache-clear, oc-trust-sync,
#   oc-diag, oc-failover

# ---------------------------------------------------------------------------
# so — Start the OpenClaw gateway (systemd-managed service).
# Injects bridged API keys into the systemd user session before starting.
# ---------------------------------------------------------------------------
function so() {
    if __test_port "$OC_PORT"; then
        __tac_info "Gateway Status" "[ALREADY RUNNING]" "$C_Warning"
        return
    fi

    # Push bridged API keys into the systemd user environment so the
    # openclaw-gateway.service can see them. Systemd user services do NOT
    # inherit the interactive shell's exported vars (they run in an
    # isolated activation context). We must push each key explicitly via
    # 'systemctl --user set-environment' so the service's ExecStart can
    # read them. The cache file uses printf %q quoting, so we read key
    # names from the file and use indirect expansion (${!_key}) to get
    # the properly evaluated values that were already sourced at startup.
    local _key
    while IFS= read -r _line; do
        _key="${_line#export }"
        _key="${_key%%=*}"
        [[ -n "$_key" && -n "${!_key:-}" ]] && systemctl --user set-environment "${_key}=${!_key}" 2>/dev/null
    done < <(grep '^export ' "$TAC_CACHE_DIR/tac_win_api_keys" 2>/dev/null)

    # If provider is configured for local LLM, warn if it's not running
    local _prov_url; _prov_url=$(openclaw config get provider.baseUrl 2>/dev/null)
    if [[ "$_prov_url" == *"127.0.0.1:${LLM_PORT}"* ]] && ! __test_port "$LLM_PORT"; then
        __tac_info "Local LLM" "[OFFLINE — provider points to localhost:$LLM_PORT]" "$C_Warning"
        echo -e "  ${C_Dim}Run 'serve <profile>' to start the LLM before gateway.${C_Reset}"
    fi

    openclaw gateway start >/dev/null 2>&1
    sleep 3

    if __test_port "$OC_PORT"; then
        __tac_info "Supervisor Process" "[DISPATCHED AND ONLINE]" "$C_Success"
    else
        if systemctl --user is-active --quiet openclaw-gateway.service 2>/dev/null; then
            __tac_info "Supervisor Process" "[BOOTING]" "$C_Warning"
        else
            __tac_info "Supervisor Process" "[CRASHED - CHECK LOGS]" "$C_Error"
            echo -e "  ${C_Dim}Run 'le' to view the startup errors.${C_Reset}"
        fi
    fi
}

# ---------------------------------------------------------------------------
# xo — Stop the OpenClaw gateway.
# Uses 'openclaw gateway stop' then systemctl for clean shutdown.
# ---------------------------------------------------------------------------
function xo() {
    openclaw gateway stop >/dev/null 2>&1
    systemctl --user stop openclaw-gateway.service 2>/dev/null
    sleep 0.5
    rm -f "$OC_ROOT/supervisor.lock"
    __tac_info "Gateway Processes" "[TERMINATED]" "$C_Success"
}

# ---------------------------------------------------------------------------
# oc-restart — Stop and restart the OpenClaw gateway.
# ---------------------------------------------------------------------------
function oc-restart() {
    xo
    sleep 1
    so
}

# ---------------------------------------------------------------------------
# ocstart — Send an agent turn to OpenClaw.
# Usage: ocstart -m "<message>" [--to <E.164>] [--agent <id>]
# ---------------------------------------------------------------------------
ocstart() {
    if [[ -z "$*" ]]; then
        echo -e "${C_Dim}Usage:${C_Reset} ocstart --message \"<message>\" [--to <E.164>] [--agent <id>]"
        echo -e "${C_Dim}  --message     Message body for the agent (required)${C_Reset}"
        echo -e "${C_Dim}  --to          Recipient number in E.164 format${C_Reset}"
        echo -e "${C_Dim}  --agent       Agent ID to target${C_Reset}"
        echo -e "${C_Dim}  --session-id  Explicit session ID${C_Reset}"
        echo -e "${C_Dim}  --thinking    Thinking level (off|minimal|low|medium|high|xhigh)${C_Reset}"
        return 1
    fi
    openclaw agent "$@"
}

# ---------------------------------------------------------------------------
# ocstop — Delete / stop an agent.
# Usage: ocstop --agent <id>
# ---------------------------------------------------------------------------
ocstop() {
    if [[ -z "$*" ]]; then
        echo -e "${C_Dim}Usage:${C_Reset} ocstop --agent <id>"
        echo -e "${C_Dim}  --agent  Agent ID to stop (required)${C_Reset}"
        echo -e "${C_Dim}  Tip: run 'oa' to list agents${C_Reset}"
        return 1
    fi
    openclaw agents delete "$@"
}

# ---------------------------------------------------------------------------
# ockeys — Show Windows environment API keys and their WSL visibility.
# Wraps the pwsh call in timeout to prevent hangs after sleep/hibernate.
# ---------------------------------------------------------------------------
ockeys() {
    echo -e "${C_Highlight}API Keys & Tokens (Windows Environment → WSL):${C_Reset}"
    local found=0
    while IFS='=' read -r name val; do
        [[ -z "$name" ]] && continue
        local upper; upper=${name^^}
        if [[ "$upper" == *API_KEY* || "$upper" == *API-KEY* || "$upper" == *TOKEN* || "$upper" == *APIKEY* ]]; then
            local masked="${val:0:4}...${val: -4}"
            [[ ${#val} -lt 10 ]] && masked="(too short)"
            local oc_visible=""
            if printenv "$name" >/dev/null 2>&1; then
                oc_visible="${C_Success}WSL ✓${C_Reset}"
            else
                oc_visible="${C_Error}WSL ✗${C_Reset}"
            fi
            echo -e "  ${C_Dim}$name${C_Reset}  $masked  $oc_visible"
            ((found++))
        fi
    done < <(timeout 5 pwsh.exe -NoProfile -Command '
        [Environment]::GetEnvironmentVariables("User").GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }
    ' 2>/dev/null | tr -d '\r')
    if (( found == 0 )); then
        __tac_info "Windows User Env" "[NO API-KEY / TOKEN VARS FOUND]" "$C_Warning"
    else
        echo -e "  ${C_Dim}$found key(s) found in Windows User environment${C_Reset}"
    fi
}

# ---------------------------------------------------------------------------
# ocdoc-fix — Run openclaw doctor --fix with automatic config backup.
# ---------------------------------------------------------------------------
ocdoc-fix() {
    local cfg="$OC_ROOT/openclaw.json"
    local bak="${cfg}.pre-doctor"
    if [[ -f "$cfg" ]]; then
        cp "$cfg" "$bak"
        __tac_info "Config Backup" "[SAVED → $(basename "$bak")]" "$C_Success"
    fi
    openclaw doctor --fix
    if [[ -f "$bak" && -f "$cfg" ]]; then
        echo -e "${C_Dim}If settings were overwritten, restore with:${C_Reset}"
        echo -e "  ${C_Highlight}cp $bak $cfg${C_Reset}"
    fi
}

# ---------------------------------------------------------------------------
# __bridge_windows_api_keys — Import Windows User environment variables
# containing API_KEY or TOKEN into the WSL environment.
# Uses a /dev/shm cache (TTL 3600s = 1h) to avoid a slow pwsh call on
# every shell start. Run 'oc-refresh-keys' to force a re-import.
# Security: cache is chmod 600 and lives in tmpfs (RAM only, no disk).
# ---------------------------------------------------------------------------
__bridge_windows_api_keys() {
    local cache="$TAC_CACHE_DIR/tac_win_api_keys"
    local ttl=3600

    # Use cached exports if fresh enough
    if [[ -f "$cache" ]] && (( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || echo 0) < ttl )); then
        source "$cache" 2>/dev/null
        return
    fi

    # Fetch matching vars from Windows User environment via PowerShell
    # Broad match: any var containing API_KEY, API-KEY, APIKEY, or TOKEN
    local raw
    raw=$(timeout 5 pwsh.exe -NoProfile -NonInteractive -Command '
        [Environment]::GetEnvironmentVariables("User").GetEnumerator() |
        Where-Object { $_.Key -match "API[_-]?KEY|TOKEN" } |
        ForEach-Object { "$($_.Key)=$($_.Value)" }
    ' 2>/dev/null | tr -d '\r')

    [[ -z "$raw" ]] && return 1

    # Build a sourceable cache file, skipping vars with invalid names
    local tmpfile="${cache}.tmp"
    : > "$tmpfile"
    while IFS='=' read -r name val; do
        [[ -z "$name" || "$name" =~ [^a-zA-Z0-9_] ]] && continue
        [[ -z "$val" ]] && continue
        printf 'export %s=%q\n' "$name" "$val" >> "$tmpfile"
    done <<< "$raw"
    mv "$tmpfile" "$cache"
    chmod 600 "$cache"
    source "$cache" 2>/dev/null
}

# ---------------------------------------------------------------------------
# oc-refresh-keys — Force re-import of Windows API keys into WSL.
# ---------------------------------------------------------------------------
oc-refresh-keys() {
    rm -f "$TAC_CACHE_DIR/tac_win_api_keys"
    __bridge_windows_api_keys
    if [[ -f "$TAC_CACHE_DIR/tac_win_api_keys" ]]; then
        local count; count=$(wc -l < "$TAC_CACHE_DIR/tac_win_api_keys")
        __tac_info "Windows API Keys" "[$count variable(s) imported]" "$C_Success"
    else
        __tac_info "Windows API Keys" "[BRIDGE FAILED - pwsh timeout?]" "$C_Warning"
    fi
}

# ---------------------------------------------------------------------------
# oc-backup — Snapshot OpenClaw config, workspace, agents, LLM registry,
# .bashrc profile, standalone scripts, and systemd units.
# ---------------------------------------------------------------------------
function oc-backup() {
    if ! command -v zip >/dev/null; then
        __tac_info "Dependency" "[zip not installed]" "$C_Error"
        echo -e "  ${C_Dim}Install: sudo apt install zip${C_Reset}"
        return 1
    fi

    local stamp; stamp=$(date +"%Y%m%d_%H%M%S")
    mkdir -p "$OC_BACKUPS"
    local zipPath="$OC_BACKUPS/snapshot_$stamp.zip"

    __tac_info "Compressing Configuration & Agents..." "[WORKING]" "$C_Dim"

    (
        cd "$AI_STORAGE_ROOT" || exit 1
        local -a targets=()
        # Core OpenClaw state
        [[ -d ".openclaw/workspace" ]] && targets+=(".openclaw/workspace")
        [[ -d ".openclaw/agents" ]]    && targets+=(".openclaw/agents")
        [[ -f ".openclaw/openclaw.json" ]] && targets+=(".openclaw/openclaw.json")
        [[ -f ".openclaw/auth.json" ]]     && targets+=(".openclaw/auth.json")
        [[ -f ".llm/models.conf" ]]        && targets+=(".llm/models.conf")
        # Shell profile and standalone scripts
        [[ -f ".bashrc" ]]                && targets+=(".bashrc")
        local _script
        for _script in .local/bin/oc-model-status .local/bin/oc-model-switch \
                       .local/bin/oc-quick-diag .local/bin/oc-gpu-status \
                       .local/bin/oc-wake \
                       .local/bin/llama-watchdog.sh .local/bin/tac_hostmetrics.sh; do
            [[ -f "$_script" ]] && targets+=("$_script")
        done
        # Systemd units
        for _script in .config/systemd/user/llama-watchdog.service \
                       .config/systemd/user/llama-watchdog.timer; do
            [[ -f "$_script" ]] && targets+=("$_script")
        done

        if (( ${#targets[@]} > 0 )); then
            zip -r -q "$zipPath" "${targets[@]}"
        fi
    )

    if [[ -f "$zipPath" ]]; then
        local sz; sz=$(stat -c%s "$zipPath" 2>/dev/null || echo "0")
        local human_sz=$(( sz / 1024 ))
        __tac_info "Snapshot Archive" "[CREATED — ${human_sz}KB]" "$C_Success"
        echo -e "  ${C_Dim}Path: $zipPath${C_Reset}"

        # Prune old snapshots — keep the 10 most recent
        local -a all_snaps=()
        local _s
        while IFS= read -r _s; do
            all_snaps+=("$_s")
        done < <(ls -1t "$OC_BACKUPS"/snapshot_*.zip 2>/dev/null)
        local keep=10
        if (( ${#all_snaps[@]} > keep )); then
            local pruned=0
            local i
            for (( i=keep; i<${#all_snaps[@]}; i++ )); do
                rm -f "${all_snaps[$i]}"
                (( pruned++ ))
            done
            __tac_info "Pruned Old Snapshots" "[$pruned removed, keeping $keep]" "$C_Dim"
        fi
    else
        __tac_info "Target Directories" "[NOT FOUND]" "$C_Error"
    fi
}

# ---------------------------------------------------------------------------
# oc-restore — Rollback OpenClaw state from the most recent snapshot.
# DESTRUCTIVE: Deletes current workspace and agents. Prompts for confirmation.
# ---------------------------------------------------------------------------
function oc-restore() {
    local latest=""
    local -a snaps=("$OC_BACKUPS"/snapshot_*.zip)
    if [[ -e "${snaps[0]}" ]]; then
        local f newest="" newest_t=0
        for f in "${snaps[@]}"; do
            local t; t=$(stat -c %Y "$f" 2>/dev/null) || continue
            (( t > newest_t )) && newest_t=$t && newest="$f"
        done
        latest="$newest"
    fi
    if [[ -z "$latest" ]]; then
        __tac_info "Available Snapshots" "[NONE FOUND]" "$C_Error"
        return
    fi

    echo -e "${C_Warning}WARNING: This will DESTROY the current workspace and agents.${C_Reset}"
    echo -e "${C_Dim}Restoring from: $(basename "$latest")${C_Reset}"
    read -r -p $'\e[33mContinue? [y/N]: \e[0m' confirm
    [[ "${confirm,,}" != "y" ]] && { __tac_info "Restore" "[CANCELLED]" "$C_Dim"; return; }

    # Stop gateway inline (avoid calling xo which prints its own UI)
    openclaw gateway stop >/dev/null 2>&1
    pkill -f 'openclaw (gateway|start)' 2>/dev/null

    __tac_info "Purging active configurations..." "[WORKING]" "$C_Dim"

    # Extract to a temp directory first, validate, then swap — protects
    # against corrupt ZIPs destroying current state with nothing to replace it.
    local tmp_restore; tmp_restore=$(mktemp -d "${OC_BACKUPS}/restore_XXXXXX")
    __tac_info "Extracting to staging area..." "[WORKING]" "$C_Dim"
    if ! unzip -q "$latest" -d "$tmp_restore"; then
        __tac_info "State Rollback" "[FAILED — ZIP ERROR, current state preserved]" "$C_Error"
        rm -rf "$tmp_restore"
        return 1
    fi

    # Validate that the extracted archive has at least one known restorable asset
    if [[ ! -d "$tmp_restore/.openclaw/workspace" && ! -d "$tmp_restore/.openclaw/agents" \
       && ! -f "$tmp_restore/.openclaw/openclaw.json" && ! -f "$tmp_restore/.bashrc" \
       && ! -f "$tmp_restore/.llm/models.conf" ]]; then
        __tac_info "State Rollback" "[FAILED — ZIP has no recognisable content]" "$C_Error"
        rm -rf "$tmp_restore"
        return 1
    fi

    # Only destroy directories that the backup will replace — a config-only
    # restore must NOT wipe workspace/agents if it has no replacements.
    [[ -d "$tmp_restore/.openclaw/workspace" ]] && rm -rf "$OC_WORKSPACE" && mv "$tmp_restore/.openclaw/workspace" "$OC_WORKSPACE"
    [[ -d "$tmp_restore/.openclaw/agents" ]]    && rm -rf "$OC_AGENTS"    && mv "$tmp_restore/.openclaw/agents" "$OC_AGENTS"
    # Restore config files if they were backed up
    [[ -f "$tmp_restore/.openclaw/openclaw.json" ]] && mv "$tmp_restore/.openclaw/openclaw.json" "$OC_ROOT/openclaw.json"
    [[ -f "$tmp_restore/.openclaw/auth.json" ]]     && mv "$tmp_restore/.openclaw/auth.json" "$OC_ROOT/auth.json"
    [[ -f "$tmp_restore/.llm/models.conf" ]]        && mv "$tmp_restore/.llm/models.conf" "$LLM_REGISTRY"
    # Restore shell profile and standalone scripts if present
    [[ -f "$tmp_restore/.bashrc" ]] && cp "$tmp_restore/.bashrc" "$HOME/.bashrc"
    local _rs
    for _rs in .local/bin/oc-model-status .local/bin/oc-model-switch \
               .local/bin/oc-quick-diag .local/bin/oc-gpu-status \
               .local/bin/oc-wake \
               .local/bin/llama-watchdog.sh .local/bin/tac_hostmetrics.sh; do
        if [[ -f "$tmp_restore/$_rs" ]]; then
            mkdir -p "$(dirname "$HOME/$_rs")"
            cp "$tmp_restore/$_rs" "$HOME/$_rs"
            chmod +x "$HOME/$_rs"
        fi
    done
    # Restore systemd units if present
    for _rs in .config/systemd/user/llama-watchdog.service \
               .config/systemd/user/llama-watchdog.timer; do
        if [[ -f "$tmp_restore/$_rs" ]]; then
            mkdir -p "$(dirname "$HOME/$_rs")"
            cp "$tmp_restore/$_rs" "$HOME/$_rs"
        fi
    done
    rm -rf "$tmp_restore"

    __tac_info "State Rollback" "[COMPLETE]" "$C_Success"
    echo -e "${C_Dim}Tip: run 'so' to restart the gateway.${C_Reset}"
}

owk()    { cd "$OC_WORKSPACE" 2>/dev/null || __tac_info "Workspace" "[NOT FOUND]" "$C_Error"; }
ologs()  { cd "$OC_LOGS"      2>/dev/null || __tac_info "Logs"      "[NOT FOUND]" "$C_Error"; }
ocroot() { cd "$OC_ROOT"      2>/dev/null || __tac_info "Root"      "[NOT FOUND]" "$C_Error"; }

# ---------------------------------------------------------------------------
# lc — Rotate the gateway systemd journal logs.
# ---------------------------------------------------------------------------
function lc() {
    journalctl --user --rotate --vacuum-time=1s -u openclaw-gateway.service >/dev/null 2>&1
    __tac_info "Logs" "[CLEARED]" "$C_Success"
}

# ---------------------------------------------------------------------------
# oc-update — Update the OpenClaw CLI to the latest version.
# ---------------------------------------------------------------------------
function oc-update() {
    if ! command -v openclaw >/dev/null; then
        __tac_info "OpenClaw CLI" "[NOT INSTALLED]" "$C_Error"
        return 1
    fi
    __tac_info "Checking for updates..." "[WORKING]" "$C_Dim"
    local out; out=$(openclaw update 2>&1)
    local rc=$?
    if (( rc == 0 )); then
        __tac_info "Update" "[COMPLETE]" "$C_Success"
        [[ -n "$out" ]] && echo -e "${C_Dim}${out}${C_Reset}"
    else
        __tac_info "Update" "[FAILED - rc=$rc]" "$C_Error"
        [[ -n "$out" ]] && echo -e "${C_Dim}${out}${C_Reset}"
    fi
}

# ---------------------------------------------------------------------------
# oc-health — Deep gateway health probe via the OpenClaw CLI.
# Uses jq for JSON parsing instead of Python.
# ---------------------------------------------------------------------------
function oc-health() {
    if ! command -v openclaw >/dev/null; then
        __tac_info "OpenClaw CLI" "[NOT INSTALLED]" "$C_Error"
        return 1
    fi
    if __test_port "$OC_PORT"; then
        __tac_info "Gateway Port $OC_PORT" "[LISTENING]" "$C_Success"
    else
        __tac_info "Gateway Port $OC_PORT" "[NOT LISTENING]" "$C_Error"
        return 1
    fi
    local health_out; health_out=$(openclaw health --json 2>/dev/null)
    if [[ -n "$health_out" ]]; then
        local hstatus
        hstatus=$(jq -r '.status // "unknown"' <<< "$health_out" 2>/dev/null)
        [[ -z "$hstatus" ]] && hstatus="parse_error"
        __tac_info "Health Status" "[${hstatus^^}]" \
            "$([[ $hstatus == "ok" || $hstatus == "healthy" ]] && echo "$C_Success" || echo "$C_Warning")"
    else
        __tac_info "Health Probe" "[NO RESPONSE]" "$C_Warning"
    fi
}

# ---------------------------------------------------------------------------
# oc-cron — OpenClaw scheduler management (list / add / runs).
# ---------------------------------------------------------------------------
function oc-cron() {
    local action="${1:-list}"
    shift 2>/dev/null
    case "$action" in
        list) openclaw cron list ;;
        add)  openclaw cron add "$@" ;;
        runs) openclaw cron runs "$@" ;;
        *)    echo "Usage: oc-cron {list|add|runs} [args...]" ;;
    esac
}

# ---------------------------------------------------------------------------
# oc-skills — List installed and eligible OpenClaw skills.
# ---------------------------------------------------------------------------
function oc-skills() {
    if command -v clawhub >/dev/null 2>&1; then
        clawhub list
    else
        openclaw skills list --eligible
    fi
}

# ---------------------------------------------------------------------------
# oc-plugins — OpenClaw plugin management.
# ---------------------------------------------------------------------------
function oc-plugins() {
    local action="${1:-list}"
    case "$action" in
        list)    openclaw plugins list ;;
        doctor)  openclaw plugins doctor ;;
        enable)  openclaw plugins enable "$2" ;;
        disable) openclaw plugins disable "$2" ;;
        *)       echo "Usage: oc-plugins {list|doctor|enable|disable} [id]" ;;
    esac
}

# ---------------------------------------------------------------------------
# oc-tail — Live-tail the OpenClaw gateway logs in the terminal.
# ---------------------------------------------------------------------------
function oc-tail() {
    openclaw logs --follow
}

# ---------------------------------------------------------------------------
# oc-channels — Channel management wrapper (list/status/logs/add/remove).
# ---------------------------------------------------------------------------
function oc-channels() {
    local action="${1:-list}"
    shift 2>/dev/null
    case "$action" in
        list)   openclaw channels list ;;
        status) openclaw channels status --probe ;;
        logs)   openclaw channels logs "$@" ;;
        add)    openclaw channels add "$@" ;;
        remove) openclaw channels remove "$@" ;;
        *)      echo "Usage: oc-channels {list|status|logs|add|remove} [args...]" ;;
    esac
}

# ---------------------------------------------------------------------------
# oc-sec — Run a deep security audit on the OpenClaw installation.
# ---------------------------------------------------------------------------
function oc-sec() {
    openclaw security audit --deep
}

# ---------------------------------------------------------------------------
# oc-tui — Launch the OpenClaw built-in terminal user interface.
# ---------------------------------------------------------------------------
function oc-tui() {
    openclaw tui
}

# ---------------------------------------------------------------------------
# oc-config — Get or set OpenClaw configuration values.
# Usage: oc-config get <key> | set <key> <value> | unset <key>
# ---------------------------------------------------------------------------
function oc-config() {
    if [[ -z "$*" ]]; then
        echo -e "${C_Dim}Usage:${C_Reset} oc-config get <key> | set <key> <value> | unset <key>"
        return 1
    fi
    openclaw config "$@"
}

# ---------------------------------------------------------------------------
# oc-docs — Search the OpenClaw documentation from the terminal.
# ---------------------------------------------------------------------------
function oc-docs() {
    if [[ -z "$*" ]]; then
        echo -e "${C_Dim}Usage:${C_Reset} oc-docs <search query>"
        return 1
    fi
    openclaw docs "$*"
}

# ---------------------------------------------------------------------------
# oc-usage — Show recent token/cost usage statistics.
# Usage: oc-usage [period] (default: 7d)
# ---------------------------------------------------------------------------
function oc-usage() {
    openclaw usage --last "${1:-7d}"
}

# ---------------------------------------------------------------------------
# oc-memory-search — Search OpenClaw's vector memory index.
# ---------------------------------------------------------------------------
function oc-memory-search() {
    if [[ -z "$*" ]]; then
        echo -e "${C_Dim}Usage:${C_Reset} oc-memory-search <query>"
        return 1
    fi
    openclaw memory search "$*"
}

# ---------------------------------------------------------------------------
# oc-local-llm — Configure OpenClaw to use the local llama.cpp server.
# Binds OpenClaw's model provider to the local inference endpoint so agents
# use your RTX 3050 Ti instead of paying for cloud API calls.
# ---------------------------------------------------------------------------
function oc-local-llm() {
    if ! __test_port "$LLM_PORT"; then
        __tac_info "Local LLM" "[OFFLINE - Start a model first]" "$C_Error"
        return 1
    fi
    # Read the actual model name from the active LLM state file
    local model_name="local"
    if [[ -f "$ACTIVE_LLM_FILE" ]]; then
        local _raw; _raw=$(< "$ACTIVE_LLM_FILE")
        local _name; IFS='|' read -r _ _name _ _ <<< "$_raw"
        [[ -n "$_name" ]] && model_name="$_name"
    fi
    openclaw config set provider.name "openai-compatible"
    openclaw config set provider.baseUrl "http://127.0.0.1:${LLM_PORT}/v1"
    openclaw config set provider.model "$model_name"
    openclaw gateway restart 2>/dev/null
    # Verify the gateway actually came back up after reconfiguration
    sleep 2
    if __test_port "$OC_PORT"; then
        __tac_info "OpenClaw → Local LLM" "[LINKED: $model_name on port $LLM_PORT]" "$C_Success"
    else
        __tac_info "OpenClaw → Local LLM" "[LINKED but gateway not responding]" "$C_Warning"
    fi
}

# ---------------------------------------------------------------------------
# oc-sync-models — Sync the local model registry with OpenClaw's model scan.
# ---------------------------------------------------------------------------
function oc-sync-models() {
    openclaw models scan --no-probe --yes
    __tac_info "Model Registry" "[SYNCED WITH OPENCLAW]" "$C_Success"
}

# ---------------------------------------------------------------------------
# oc-browser — OpenClaw browser automation lifecycle.
# ---------------------------------------------------------------------------
function oc-browser() {
    local action="${1:-status}"
    shift 2>/dev/null
    case "$action" in
        status) openclaw browser status ;;
        start)  openclaw browser start ;;
        stop)   openclaw browser stop ;;
        open)   openclaw browser open "$@" ;;
        *)      echo "Usage: oc-browser {status|start|stop|open} [args...]" ;;
    esac
}

# ---------------------------------------------------------------------------
# oc-nodes — List and inspect connected OpenClaw nodes.
# ---------------------------------------------------------------------------
function oc-nodes() {
    local action="${1:-status}"
    shift 2>/dev/null
    case "$action" in
        status)   openclaw nodes status ;;
        list)     openclaw nodes list ;;
        describe) openclaw nodes describe "$@" ;;
        *)        echo "Usage: oc-nodes {status|list|describe} [args...]" ;;
    esac
}

# ---------------------------------------------------------------------------
# oc-sandbox — Manage OpenClaw agent sandboxes.
# ---------------------------------------------------------------------------
function oc-sandbox() {
    local action="${1:-list}"
    shift 2>/dev/null
    case "$action" in
        list)     openclaw sandbox list ;;
        recreate) openclaw sandbox recreate ;;
        explain)  openclaw sandbox explain ;;
        *)        echo "Usage: oc-sandbox {list|recreate|explain}" ;;
    esac
}

# ---------------------------------------------------------------------------
# oc-env — Dump all OpenClaw and LLM related environment variables.
# ---------------------------------------------------------------------------
oc-env() {
    __tac_header "ENVIRONMENT VARIABLES" "open"
    __tac_line "OPENCLAW_ROOT" "[$OPENCLAW_ROOT]" "$C_Highlight"
    __tac_line "OC_WORKSPACE" "[$OC_WORKSPACE]" "$C_Dim"
    __tac_line "OC_AGENTS" "[$OC_AGENTS]" "$C_Dim"
    __tac_line "OC_LOGS" "[$OC_LOGS]" "$C_Dim"
    __tac_line "OC_PORT" "[$OC_PORT]" "$C_Highlight"
    __tac_divider
    __tac_line "LLAMA_ROOT" "[$LLAMA_ROOT]" "$C_Highlight"
    __tac_line "LLAMA_MODEL_DIR" "[$LLAMA_MODEL_DIR]" "$C_Dim"
    __tac_line "LLM_PORT" "[$LLM_PORT]" "$C_Highlight"
    __tac_line "LOCAL_LLM_URL" "[$LOCAL_LLM_URL]" "$C_Dim"
    __tac_line "LLAMA_GPU_LAYERS" "[$LLAMA_GPU_LAYERS]" "$C_Dim"
    __tac_line "LLAMA_CPU_THREADS" "[$LLAMA_CPU_THREADS]" "$C_Dim"
    __tac_divider
    __tac_line "AI_STORAGE_ROOT" "[$AI_STORAGE_ROOT]" "$C_Dim"
    __tac_line "UIWidth" "[$UIWidth]" "$C_Dim"
    __tac_line "PROFILE VERSION" "[$TACTICAL_PROFILE_VERSION]" "$C_Success"
    __tac_footer
}

# ---------------------------------------------------------------------------
# oc-cache-clear — Wipe all /dev/shm telemetry caches to force a refresh.
# ---------------------------------------------------------------------------
oc-cache-clear() {
    local count=0
    local _had_nullglob=0; shopt -q nullglob && _had_nullglob=1
    shopt -s nullglob
    for f in "$TAC_CACHE_DIR"/tac_*; do
        [[ -f "$f" ]] && rm -f "$f" && ((count++))
    done
    (( _had_nullglob )) || shopt -u nullglob
    __tac_info "Telemetry Cache" "[$count file(s) cleared]" "$C_Success"
}

# ---------------------------------------------------------------------------
# oc-trust-sync — Record current oc-llm-sync.sh hash as trusted.
# ---------------------------------------------------------------------------
oc-trust-sync() {
    local src="$OC_WORKSPACE/oc-llm-sync.sh"
    if [[ ! -f "$src" ]]; then
        __tac_info "oc-llm-sync.sh" "[NOT FOUND]" "$C_Error"
        return 1
    fi
    sha256sum "$src" 2>/dev/null | cut -d' ' -f1 > "$OC_ROOT/oc-llm-sync.sha256"
    __tac_info "Trusted Hash" "[UPDATED]" "$C_Success"
}

# ---------------------------------------------------------------------------
# oc-diag — Combined diagnostic dump: OpenClaw doctor + gateway status +
#            model status + environment variables + recent log tail.
# ---------------------------------------------------------------------------
oc-diag() {
    __tac_header "OpenClaw Diagnostic Report" "open"
    echo ""

    echo -e "${C_Highlight}[1/5] openclaw doctor${C_Reset}"
    openclaw doctor 2>&1 | head -n 30
    echo ""

    echo -e "${C_Highlight}[2/5] Gateway Status${C_Reset}"
    if curl -sf "http://127.0.0.1:${OC_PORT:-18789}/api/health" -o /dev/null 2>/dev/null; then
        echo -e "  ${C_Success}● Gateway reachable on port ${OC_PORT:-18789}${C_Reset}"
    else
        echo -e "  ${C_Error}● Gateway NOT reachable on port ${OC_PORT:-18789}${C_Reset}"
    fi
    echo ""

    echo -e "${C_Highlight}[3/5] Model Provider Status${C_Reset}"
    ocms 2>&1 | head -n 20
    echo ""

    echo -e "${C_Highlight}[4/5] Environment Variables${C_Reset}"
    oc-env 2>&1
    echo ""

    echo -e "${C_Highlight}[5/5] Recent Logs (last 15 lines)${C_Reset}"
    if [[ -f "$OC_TMP_LOG" ]]; then
        tail -n 15 "$OC_TMP_LOG"
    else
        echo "  (no log file found at $OC_TMP_LOG)"
    fi
    echo ""
    __tac_footer
    __tac_info "Diagnostics" "[Complete]" "$C_Success"
}

# ---------------------------------------------------------------------------
# oc-failover — Configure cloud model fallback for when local LLM is down.
#   Usage: oc-failover [on|off|status]
# ---------------------------------------------------------------------------
oc-failover() {
    local action="${1:-status}"
    case "$action" in
        on)
            if [[ -z "${OPENAI_API_KEY:-}" && -z "${ANTHROPIC_API_KEY:-}" ]]; then
                __tac_info "Failover" "[No cloud API key found — set OPENAI_API_KEY or ANTHROPIC_API_KEY]" "$C_Error"
                return 1
            fi
            # Verify the fallback model list is configured before enabling
            local fb_models; fb_models=$(openclaw config get llm.fallback.models 2>/dev/null)
            if [[ -z "$fb_models" || "$fb_models" == "null" ]]; then
                __tac_info "Failover" "[No fallback models configured — set llm.fallback.models first]" "$C_Warning"
            fi
            openclaw config set llm.fallback.enabled true 2>/dev/null
            __tac_info "Failover" "[Cloud fallback ENABLED]" "$C_Success"
            ;;
        off)
            openclaw config set llm.fallback.enabled false 2>/dev/null
            __tac_info "Failover" "[Cloud fallback DISABLED]" "$C_Warning"
            ;;
        status)
            local val; val=$(openclaw config get llm.fallback.enabled 2>/dev/null || echo "unknown")
            __tac_info "Failover" "[llm.fallback.enabled = $val]" "$C_Info"
            # Show the actual fallback chain so the user knows what will activate
            local chain; chain=$(openclaw config get llm.fallback.models 2>/dev/null)
            if [[ -n "$chain" && "$chain" != "null" ]]; then
                __tac_info "Chain" "$chain" "$C_Dim"
            else
                __tac_info "Chain" "[No fallback models configured]" "$C_Warning"
            fi
            ;;
        *)
            echo -e "${C_Dim}Usage:${C_Reset} oc-failover [on|off|status]"
            ;;
    esac
}

# ==============================================================================
# 10. DEPLOYMENT & SCAFFOLDING
# ==============================================================================
# @modular-section: deployment
# @depends: constants, design-tokens, ui-engine, hooks
# @exports: mkproj, deploy_sync, commit_deploy, commit_auto

# ---------------------------------------------------------------------------
# mkproj — Scaffold a new Python project with PEP-8 main.py, tests, venv, git.
# ---------------------------------------------------------------------------
function mkproj() {
    local n="$1"
    if [[ -z "$n" ]]; then
        __tac_info "Project Name Required" "[mkproj <Name>]" "$C_Error"
        return
    fi
    if [[ -d "$n" ]]; then
        __tac_info "Directory $n" "[ALREADY EXISTS]" "$C_Error"
        return
    fi

    # Verify required tools before creating any files
    if ! command -v python3 >/dev/null 2>&1; then
        __tac_info "python3" "[NOT FOUND — install before using mkproj]" "$C_Error"
        return 1
    fi
    if ! command -v git >/dev/null 2>&1; then
        __tac_info "git" "[NOT FOUND — install before using mkproj]" "$C_Error"
        return 1
    fi

    mkdir -p "$n/src" "$n/tests"
    cd "$n" || return

    echo "# Core dependencies" > requirements.txt
    printf "__pycache__/\n.venv/\n.env\n*.log\n.pytest_cache/\n" > .gitignore
    printf "ENVIRONMENT=development\nLOG_LEVEL=DEBUG\n" > .env.example
    touch src/__init__.py

    cat << 'EOF' > src/main.py
"""
Module: main.py
Description: Primary entry point.
Author: Wayne
"""
import sys
import logging
import argparse
from pathlib import Path

def setup_logging(debug: bool = False) -> logging.Logger:
    level = logging.DEBUG if debug else logging.INFO
    logging.basicConfig(level=level, format='%(asctime)s | %(levelname)-8s | %(message)s', datefmt='%Y-%m-%d %H:%M:%S')
    return logging.getLogger(__name__)

def execute_task(logger: logging.Logger, target_dir: Path) -> None:
    logger.info(f"Initiating sequence in: {target_dir}")
    if not target_dir.exists():
        logger.error(f"Target directory missing: {target_dir}")
        sys.exit(1)
    logger.info("Task sequence completed successfully.")

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--debug', action='store_true')
    parser.add_argument('--target', type=Path, default=Path.cwd())
    args = parser.parse_args()
    logger = setup_logging(args.debug)
    try:
        execute_task(logger, args.target)
    except Exception as e:
        logger.exception("A critical unhandled failure occurred.")
        sys.exit(1)

if __name__ == '__main__':
    main()
EOF

    cat << 'EOF' > tests/test_core.py
import pytest

def test_initial_sanity():
    assert True
EOF

    git init >/dev/null 2>&1

    # Auto-initialize venv
    __tac_info "Python Environment" "[CREATING .venv...]" "$C_Dim"
    python3 -m venv .venv
    if [[ -f ".venv/bin/activate" ]]; then
        source .venv/bin/activate
        pip install --upgrade pip --quiet
        pip install -r requirements.txt --quiet
        __tac_info "Python Dependencies" "[INSTALLED]" "$C_Success"
    else
        __tac_info "Python Environment" "[FAILED]" "$C_Error"
    fi

    __tac_info "Directory & Git Init" "[SUCCESS]" "$C_Success"
    __tac_info "PEP8 src/main.py Scaffold" "[INJECTED]" "$C_Success"
    __tac_info "tests/, .env, requirements" "[CREATED]" "$C_Success"
}

# ---------------------------------------------------------------------------
# deploy_sync — Rsync ~/console to the OpenClaw production workspace.
# ---------------------------------------------------------------------------
function deploy_sync() {
    if [[ ! -d "$OpenClawWorkspace" ]]; then
        mkdir -p "$OpenClawWorkspace"
        __tac_info "Created target" "$OpenClawWorkspace"
    fi

    __tac_header "DEPLOYMENT MANAGER" "open"
    __tac_line "Syncing ~/console -> OpenClaw Workspace..." "[WORKING]" "$C_Dim"

    rsync -a --delete --exclude ".git" --exclude "__pycache__" --exclude ".venv" "$TacticalRoot/" "$OpenClawWorkspace/" >/dev/null 2>&1
    local rc=$?
    if (( rc == 0 )); then
        __tac_line "Folder Parity" "[ACHIEVED]" "$C_Success"
    else
        __tac_line "Folder Parity" "[SYNC FAILED]" "$C_Error"
    fi
    __tac_footer
}

# ---------------------------------------------------------------------------
# commit_deploy — Stage, commit with a given message, push, then deploy.
# ---------------------------------------------------------------------------
function commit_deploy() {
    local msg="$*"
    if [[ -z "$msg" ]]; then
        __tac_info "Commit message required" "[commit: <msg>]" "$C_Error"
        return
    fi

    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        __tac_info "Repository Check" "[NOT A GIT REPO]" "$C_Error"
        return
    fi

    # Verify a remote is configured before attempting push
    if ! git remote get-url origin >/dev/null 2>&1; then
        __tac_info "Remote Check" "[NO ORIGIN CONFIGURED]" "$C_Error"
        return
    fi

    if [[ -z $(git status --porcelain) ]]; then
        __tac_info "Workspace" "[CLEAN - NO CHANGES]" "$C_Dim"
        return
    fi

    __tac_header "VERSION CONTROL" "open"

    local modCount; modCount=$(git status --porcelain | wc -l)
    __tac_line "Staging $modCount file(s)..." "[WORKING]" "$C_Dim"
    git add .

    __tac_line "Committing: \"$msg\"..." "[WORKING]" "$C_Dim"
    if ! git commit -m "$msg" --quiet; then
        __tac_line "Commit" "[FAILED]" "$C_Error"
        __tac_footer
        return 1
    fi

    __tac_line "Syncing with origin..." "[WORKING]" "$C_Dim"
    git push --quiet
    local push_rc=$?

    if (( push_rc == 0 )); then
        __tac_line "Repository Sync" "[SUCCESS]" "$C_Success"
    else
        __tac_line "Repository Sync" "[REMOTE PUSH FAILED]" "$C_Error"
    fi

    __tac_footer
    (( push_rc == 0 )) && deploy_sync
}

# ---------------------------------------------------------------------------
# commit_auto — Stage, generate commit message via local LLM, push, deploy.
# Uses curl + jq (not Python) for the non-streaming LLM request.
#
# SECURITY WARNING: The git diff is sent to $LOCAL_LLM_URL. If this URL is
# ever reconfigured to point to a cloud API, diffs containing secrets (API
# keys, passwords) will be leaked. Ensure LOCAL_LLM_URL always points to a
# local-only inference server (127.0.0.1).
# ---------------------------------------------------------------------------
function commit_auto() {
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        __tac_info "Repository Check" "[NOT A GIT REPO]" "$C_Error"
        return
    fi
    if ! git remote get-url origin >/dev/null 2>&1; then
        __tac_info "Remote Check" "[NO ORIGIN CONFIGURED]" "$C_Error"
        return
    fi
    # Security: block diff leak to non-localhost LLM endpoints
    if [[ "$LOCAL_LLM_URL" != http://127.0.0.1:* && "$LOCAL_LLM_URL" != http://localhost:* ]]; then
        __tac_info "SECURITY" "[BLOCKED: LLM URL is not localhost]" "$C_Error"
        return 1
    fi
    if [[ -z $(git status --porcelain) ]]; then
        __tac_info "Workspace" "[CLEAN - NO CHANGES]" "$C_Dim"
        return
    fi
    if ! __test_port "$LLM_PORT"; then
        __tac_info "LLM Required" "[OFFLINE - Start a model first]" "$C_Error"
        return
    fi
    # Verify the process listening on $LLM_PORT is actually llama-server
    local _llm_pid; _llm_pid=$(ss -tlnp "sport = :$LLM_PORT" 2>/dev/null | grep -oP 'pid=\K[0-9]+')
    if [[ -z "$_llm_pid" ]] || ! grep -q llama-server "/proc/$_llm_pid/cmdline" 2>/dev/null; then
        __tac_info "SECURITY" "[BLOCKED: port $LLM_PORT is not llama-server]" "$C_Error"
        return 1
    fi

    git add .
    local diff_stat; diff_stat=$(git diff --cached --stat 2>/dev/null)
    local diff_body; diff_body=$(git diff --cached 2>/dev/null | head -500)
    local diff="${diff_stat}
---
${diff_body}"

    __tac_info "Generating commit message..." "[LLM]" "$C_Dim"

    local prompt="Write a concise git commit message (one line, max 72 chars, imperative mood) for the following diff. Return ONLY the message, no quotes or explanation."
    local payload
    payload=$(jq -n \
        --arg prompt "$prompt" \
        --arg diff "${diff:0:3000}" \
        '{messages: [{role: "user", content: ($prompt + "\n\n" + $diff)}], max_tokens: 80, temperature: 0.3}')

    local raw_response
    raw_response=$(curl -s --max-time 30 "$LOCAL_LLM_URL" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null)
    local msg
    msg=$(printf '%s' "$raw_response" | jq -r '.choices[0].message.content // empty' 2>/dev/null | \
        tr -d '"' | head -c 72 | head -1)

    if [[ -z "$msg" || "$msg" == "null" ]]; then
        __tac_info "LLM" "[FAILED TO GENERATE MESSAGE]" "$C_Error"
        git reset HEAD >/dev/null 2>&1
        return
    fi

    echo -e "${C_Highlight}Proposed:${C_Reset} $msg"
    while true; do
        read -r -e -p $'\e[90mAccept? [Y/n/edit]: \e[0m' confirm
        case "${confirm,,}" in
            y|yes|"") break ;;
            n|no)
                __tac_info "Commit" "[CANCELLED]" "$C_Dim"
                git reset HEAD >/dev/null 2>&1
                return
                ;;
            e|edit)
                read -r -e -p $'\e[96mMessage: \e[0m' -i "$msg" msg
                [[ -z "$msg" ]] && { __tac_info "Commit" "[CANCELLED]" "$C_Dim"; git reset HEAD >/dev/null 2>&1; return; }
                break
                ;;
            *) echo "Please enter y, n, or e." ;;
        esac
    done

    git commit -m "$msg" --quiet
    __tac_info "Committed" "[$msg]" "$C_Success"
    git push --quiet
    local push_rc=$?
    if (( push_rc == 0 )); then
        __tac_info "Repository Sync" "[SUCCESS]" "$C_Success"
    else
        __tac_info "Repository Sync" "[REMOTE PUSH FAILED]" "$C_Error"
    fi
    (( push_rc == 0 )) && deploy_sync
}

# ==============================================================================
# 11. LLM MODEL MANAGER & OPENCLAW INTEROP
# ==============================================================================
# @modular-section: llm-manager
# @depends: constants, design-tokens, ui-engine, hooks
# @exports: wake, model, serve, halt, mlogs, burn, explain, wtf_repl,
#   __llm_sse_core, __llm_stream, __llm_chat_send, local_chat, chat-context,
#   chat-pipe, __require_llm

# ---------------------------------------------------------------------------
# __require_llm — Verify jq is installed and the local LLM is listening.
# Returns 1 with diagnostic output if either check fails.
# Deduplicates the repeated jq + port checks across LLM functions.
# ---------------------------------------------------------------------------
__require_llm() {
    if ! command -v jq >/dev/null 2>&1; then
        echo -e "${C_Error}[jq missing]${C_Reset} Install: sudo apt install -y jq"
        return 1
    fi
    if ! __test_port "$LLM_PORT"; then
        __tac_info "Llama Server" "[OFFLINE]" "$C_Error"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# wake — Lock the GPU into persistent mode to prevent WDDM sleep in WSL2.
# NOTE: Persistence mode (-pm 1) is a runtime setting and does NOT survive
# WSL restarts. You must re-run 'wake' after each 'wsl --shutdown'.
# ---------------------------------------------------------------------------
function wake() {
    local smi_cmd="$WSL_NVIDIA_SMI"
    [[ ! -f "$smi_cmd" ]] && smi_cmd=$(command -v nvidia-smi)

    sudo "$smi_cmd" -pm 1 >/dev/null 2>&1

    local stat; stat=$("$smi_cmd" --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader 2>/dev/null || echo "ERROR")
    __tac_info "GPU Persistence" "[$stat]" "$C_Success"
    echo -e "${C_Dim}Note: -pm 1 does not survive WSL restarts. Re-run 'wake' after reboot.${C_Reset}"
}

# ---------------------------------------------------------------------------
# model — Unified LLM model manager.
# Subcommands: list, start, stop, active, info, assign, test, download, pull, swap.
# ---------------------------------------------------------------------------
function model() {
    local action=$1
    local target=$2
    local tbl_inner=$(( UIWidth - 4 ))  # inner text area for table rows

    case "$action" in
        list)
            __tac_header "LLM REGISTRY: $LLM_REGISTRY" "open"

            # Fixed-width columns: PROFILE(13) | NAME(25) | SIZE(8) | PROC(8)
            # Display width = 2+13+2+25+2+8+2+8 = 62; pad to UIWidth-2.
            local _iw=$(( UIWidth - 2 ))  # inner display width between ║...║
            local header; header=$(printf "  %-13s│ %-25s│ %-8s│ %-8s" "PROFILE" "FRIENDLY NAME" "SIZE" "PROC")
            local _hpad=$(( _iw - 62 )); local _hsp=""; (( _hpad > 0 )) && printf -v _hsp '%*s' "$_hpad" ""
            printf "${C_BoxBg}║${C_Reset}${C_Dim}%s%s${C_Reset}${C_BoxBg}║${C_Reset}\n" "$header" "$_hsp"

            local sep_inner; sep_inner=$(printf '  ─────────────┼──────────────────────────┼─────────┼')
            # Extend last segment with ─ to fill remaining width
            local _sep_fill=$(( _iw - 62 + 9 )); local _seg=""; printf -v _seg '%*s' "$_sep_fill" ""; _seg="${_seg// /─}"
            sep_inner+="$_seg"
            printf "${C_BoxBg}║${C_Reset}${C_Dim}%s${C_Reset}${C_BoxBg}║${C_Reset}\n" "$sep_inner"

            if [[ -f "$LLM_REGISTRY" ]]; then
                while IFS='|' read -r prof friendly size proc file _rest; do
                    [[ "$prof" == "profile" || -z "$prof" ]] && continue
                    local strict_name="${friendly:0:25}"
                    # Normalise size: e.g. 4.4G → 4.4 Gb
                    local norm_size="${size#"${size%%[! ]*}"}"; norm_size="${norm_size/%G/ Gb}"; norm_size="${norm_size/%M/ Mb}"
                    local row; row=$(printf "  %-13s│ %-25s│ %-8s│ %-8s" "$prof" "$strict_name" "$norm_size" "$proc")
                    local _rpad=$(( _iw - 62 )); local _rsp=""; (( _rpad > 0 )) && printf -v _rsp '%*s' "$_rpad" ""
                    printf "${C_BoxBg}║${C_Reset}%s%s${C_BoxBg}║${C_Reset}\n" "$row" "$_rsp"
                done < "$LLM_REGISTRY"
            fi

            __tac_divider
            local rem="Use 'model assign' to map profiles to specific models."
            local rPad_left=$(( (_iw - ${#rem}) / 2 ))
            local rPad_right=$(( _iw - ${#rem} - rPad_left ))

            local lPadStr; printf -v lPadStr '%*s' "$rPad_left" ""
            local rPadStr; printf -v rPadStr '%*s' "$rPad_right" ""

            printf "${C_BoxBg}║${C_Reset}${C_Dim}%s%s%s${C_Reset}${C_BoxBg}║${C_Reset}\n" "$lPadStr" "$rem" "$rPadStr"
            __tac_footer
            ;;

        start)
            [[ -z "$target" ]] && { __tac_info "Usage" "[model start <profile>]" "$C_Error"; return 1; }
            local entry; entry=$(awk -F'|' -v p="$target" '$1 == p' "$LLM_REGISTRY" 2>/dev/null)
            [[ -z "$entry" ]] && { __tac_info "Model Error" "[Profile '$target' not in registry]" "$C_Error"; return 1; }

            # Registry format: profile|name|size|proc|file[|gpu_layers|ctx_size|threads]
            # Fields 6-8 are optional; defaults from LLAMA_GPU_LAYERS/CTX_SIZE/CPU_THREADS
            IFS='|' read -r prof friendly size proc file m_gpu_layers m_ctx_size m_threads <<< "$entry"
            local model_path="$LLAMA_MODEL_DIR/$file"

            # Resolve per-model params or fall back to global defaults
            local use_gpu_layers="${m_gpu_layers:-$LLAMA_GPU_LAYERS}"
            local use_ctx_size="${m_ctx_size:-$LLAMA_CTX_SIZE}"
            local use_threads="${m_threads:-$LLAMA_CPU_THREADS}"

            [[ ! -f "$model_path" ]] && { __tac_info "Model Error" "[File $file missing]" "$C_Error"; return 1; }

            [[ ! -x "$LLAMA_SERVER_BIN" ]] && { __tac_info "Server Binary" "[NOT FOUND: $LLAMA_SERVER_BIN]" "$C_Error"; return 1; }

            __tac_info "Llama Server" "Purging existing instances..." "$C_Warning"
            pkill -f llama-server 2>/dev/null
            sleep 1

            # Bind to 127.0.0.1 only (not 0.0.0.0) to prevent LAN exposure
            local cmd=("$LLAMA_SERVER_BIN" "-m" "$model_path" "--port" "$LLM_PORT" "--host" "127.0.0.1")
            # Context window, memory lock, batch sizes, continuous batching
            cmd+=("--ctx-size" "$use_ctx_size" "--mlock")
            cmd+=("--batch-size" "512" "--ubatch-size" "512" "--cont-batching")
            if [[ "$proc" == "gpu" ]]; then
                cmd+=("--n-gpu-layers" "$use_gpu_layers" "--flash-attn")
                __tac_info "Hardware" "RTX 3050 Ti: ${use_gpu_layers} layers, ctx ${use_ctx_size}, flash-attn" "$C_Highlight"
            else
                cmd+=("--threads" "$use_threads")
                __tac_info "Hardware" "i9 CPU: ${use_threads} threads, ctx ${use_ctx_size}" "$C_Highlight"
            fi

            (nohup "${cmd[@]}" > "$LLM_LOG_FILE" 2>&1 &)

            # Store state: profile | name | size | processor
            echo "$prof|$friendly|$size|$proc" > "${ACTIVE_LLM_FILE}.tmp" 2>/dev/null \
                && mv "${ACTIVE_LLM_FILE}.tmp" "$ACTIVE_LLM_FILE" \
                || __tac_info "Warning" "[/dev/shm full — state not saved]" "$C_Warning"

            __tac_info "Status" "Booting $friendly ($size)..." "$C_Warning"
            local ready=0
            for _ in {1..30}; do
                if __test_port "$LLM_PORT" && curl -sf "http://127.0.0.1:$LLM_PORT/health" >/dev/null; then ready=1; break; fi
                sleep 1
            done
            if (( ready == 1 )); then __tac_info "API Endpoint" "ONLINE [Port $LLM_PORT]" "$C_Success"
            else __tac_info "API Endpoint" "FAILED OR TIMEOUT" "$C_Error"; fi
            ;;

        stop)
            pkill -f llama-server 2>/dev/null
            rm -f "$ACTIVE_LLM_FILE"
            __tac_info "Llama Server" "[TERMINATED]" "$C_Success"
            ;;

        active)
            if [[ -f "$ACTIVE_LLM_FILE" ]] && pgrep -f llama-server >/dev/null; then
                local raw; raw=$(cat "$ACTIVE_LLM_FILE")
                IFS='|' read -r a_prof a_name a_size a_proc <<< "$raw"
                __tac_info "Active Profile" "$a_prof" "$C_Highlight"
                __tac_info "Model Name" "$a_name" "$C_Success"
                __tac_info "Processor" "${a_proc:-gpu}" "$C_Text"
                __tac_info "Parameter Size" "${a_size:-N/A}" "$C_Dim"
            else
                __tac_info "Status" "[IDLE]" "$C_Dim"
            fi
            ;;

        info)
            [[ -z "$target" ]] && { __tac_info "Usage" "[model info <profile>]" "$C_Error"; return 1; }
            local entry; entry=$(awk -F'|' -v p="$target" '$1 == p' "$LLM_REGISTRY" 2>/dev/null)
            [[ -z "$entry" ]] && { __tac_info "Profile" "['$target' not found]" "$C_Error"; return 1; }
            IFS='|' read -r prof friendly size proc file _gl _cs _th <<< "$entry"
            __tac_info "Profile" "$prof" "$C_Highlight"
            __tac_info "Model" "$friendly" "$C_Success"
            __tac_info "Size" "$size" "$C_Text"
            __tac_info "Processor" "$proc" "$C_Text"
            __tac_info "File" "$file" "$C_Dim"
            __tac_info "GPU Layers" "${_gl:-$LLAMA_GPU_LAYERS} (default: $LLAMA_GPU_LAYERS)" "$C_Dim"
            __tac_info "Context Size" "${_cs:-$LLAMA_CTX_SIZE} (default: $LLAMA_CTX_SIZE)" "$C_Dim"
            __tac_info "CPU Threads" "${_th:-$LLAMA_CPU_THREADS} (default: $LLAMA_CPU_THREADS)" "$C_Dim"
            if [[ -f "$LLAMA_MODEL_DIR/$file" ]]; then
                __tac_info "On Disk" "[FOUND]" "$C_Success"
            else
                __tac_info "On Disk" "[MISSING]" "$C_Error"
            fi
            ;;

        test)
            # Quick health-check ping to a running model without a full burn-in.
            if ! __test_port "$LLM_PORT"; then
                __tac_info "Status" "[OFFLINE]" "$C_Error"
                return 1
            fi
            local health; health=$(curl -s "http://localhost:$LLM_PORT/health" 2>/dev/null)
            if [[ -n "$health" ]]; then
                __tac_info "API Health" "[RESPONDING]" "$C_Success"
                if [[ -f "$ACTIVE_LLM_FILE" ]]; then
                    IFS='|' read -r p n s pr <<< "$(cat "$ACTIVE_LLM_FILE")"
                    __tac_info "Model" "$n ($s)" "$C_Highlight"
                fi
            else
                __tac_info "API Health" "[NOT RESPONDING]" "$C_Error"
            fi
            ;;

        assign)
            if [[ ! -f "$LLM_REGISTRY" ]]; then
                __tac_info "Registry" "[File not found]" "$C_Error"
                return 1
            fi

            local target_prof=""
            echo -e "${C_Highlight}Select Profile Slot to Reassign:${C_Reset}"
            local _saved_ps3="$PS3"
            PS3="Choose slot index: "
            select opt in "fast" "think" "experi" "cancel"; do
                case $opt in
                    fast|think|experi) target_prof="$opt"; break ;;
                    cancel) PS3="$_saved_ps3"; return 0 ;;
                    *) echo "Invalid choice." ;;
                esac
            done
            PS3="$_saved_ps3"
            [[ -z "$target_prof" ]] && { __tac_info "Assign" "[CANCELLED]" "$C_Dim"; return 0; }

            echo -e "\n${C_Highlight}Select Model for '$target_prof':${C_Reset}"
            # Build model list AND track corresponding line numbers to avoid
            # index mismatch when the registry contains blank or header lines.
            local models=()
            local line_nums=()
            local model_files=()
            local line_no=0
            while IFS='|' read -r p n s pr f _rest; do
                ((line_no++))
                [[ "$p" == "profile" || -z "$p" ]] && continue
                models+=("$n ($s)")
                line_nums+=("$line_no")
                model_files+=("$f")
            done < "$LLM_REGISTRY"

            PS3="Choose model index (or 0 to cancel): "
            select m_opt in "${models[@]}"; do
                if [[ "$REPLY" == "0" ]]; then PS3="$_saved_ps3"; return 0; fi
                if [[ -n "$m_opt" ]]; then
                    local chosen_idx=$((REPLY - 1))
                    local chosen_line=${line_nums[$chosen_idx]}
                    local chosen_file=${model_files[$chosen_idx]}
                    break
                fi
            done
            PS3="$_saved_ps3"

            # Guard against EOF / Ctrl-D exiting select without a choice
            [[ -z "$chosen_line" ]] && { __tac_info "Assign" "[CANCELLED]" "$C_Dim"; return 0; }

            # Validate that the model file exists on disk
            if [[ -n "$chosen_file" && ! -f "$LLAMA_MODEL_DIR/$chosen_file" ]]; then
                __tac_info "Warning" "[Model file '$chosen_file' not found on disk]" "$C_Warning"
                read -r -p $'\e[33mAssign anyway? [y/N]: \e[0m' confirm
                [[ "${confirm,,}" != "y" ]] && return
            fi

            # Rebuild registry: unassign old profile, assign chosen line
            local temp_reg="${LLM_REGISTRY}.tmp"
            awk -F'|' -v prof="$target_prof" -v target_line="$chosen_line" 'BEGIN{OFS="|"}
                {
                    if ($1 == prof) $1 = "unallocated";
                    if (NR == target_line) $1 = prof;
                    print $0
                }' "$LLM_REGISTRY" > "$temp_reg"

            mv "$temp_reg" "$LLM_REGISTRY"
            __tac_info "Registry" "[Reassigned '$target_prof' slot]" "$C_Success"
            ;;

        pull|download)
            if [[ -z "$target" ]]; then
                echo -e "${C_Dim}Usage:${C_Reset} model download <hf-repo/filename>"
                echo -e "${C_Dim}  Downloads a GGUF model from HuggingFace Hub to $LLAMA_MODEL_DIR${C_Reset}"
                echo -e "${C_Dim}  Example: model download TheBloke/Llama-3-8B-GGUF/llama-3-8b.Q4_K_M.gguf${C_Reset}"
                echo -e "${C_Dim}  Requires: pip install huggingface-hub${C_Reset}"
                return 1
            fi
            if ! command -v huggingface-cli >/dev/null 2>&1; then
                __tac_info "Dependency" "[huggingface-cli not found]" "$C_Error"
                echo -e "  ${C_Dim}Install: pip install huggingface-hub${C_Reset}"
                return 1
            fi
            mkdir -p "$LLAMA_MODEL_DIR"
            __tac_info "Downloading..." "$target" "$C_Warning"
            huggingface-cli download "$target" --local-dir "$LLAMA_MODEL_DIR" --local-dir-use-symlinks False
            local dl_rc=$?
            if (( dl_rc == 0 )); then
                __tac_info "Download" "[COMPLETE]" "$C_Success"
            else
                __tac_info "Download" "[FAILED]" "$C_Error"
            fi
            ;;

        swap)
            # Stop current model, start a new one, and update OpenClaw provider.
            # Usage: model swap <profile>
            [[ -z "$target" ]] && { __tac_info "Usage" "[model swap <profile>]" "$C_Error"; return 1; }
            model stop
            sleep 1
            model start "$target"
            # If OpenClaw gateway is running, re-link it to the new model
            if __test_port "$OC_PORT"; then
                oc-local-llm
            fi
            ;;

        bench)
            # Benchmark all on-disk registered models. Starts each in turn,
            # runs a burn-in, records TPS, then produces a comparison table.
            [[ ! -f "$LLM_REGISTRY" ]] && { __tac_info "Registry" "[Not found]" "$C_Error"; return 1; }
            __tac_header "MODEL BENCHMARK SUITE" "open"

            local -a bench_prof=() bench_name=() bench_size=() bench_proc=() bench_tps=()
            while IFS='|' read -r p n s pr f _rest; do
                [[ "$p" == "profile" || -z "$p" ]] && continue
                [[ ! -f "$LLAMA_MODEL_DIR/$f" ]] && continue
                bench_prof+=("$p"); bench_name+=("$n"); bench_size+=("$s"); bench_proc+=("$pr")
            done < "$LLM_REGISTRY"

            if (( ${#bench_prof[@]} == 0 )); then
                __tac_info "Bench" "[No on-disk models found]" "$C_Warning"
                return 1
            fi

            echo -e "${C_Dim}Benchmarking ${#bench_prof[@]} model(s)...${C_Reset}\n"

            for i in "${!bench_prof[@]}"; do
                echo -e "${C_Highlight}[$(( i + 1 ))/${#bench_prof[@]}] ${bench_name[$i]} (${bench_size[$i]})${C_Reset}"
                model start "${bench_prof[$i]}" 2>/dev/null
                sleep 2

                # Run burn and capture TPS from cache
                burn 2>/dev/null
                local tps_val="FAIL"
                [[ -f "$LLM_TPS_CACHE" ]] && tps_val=$(< "$LLM_TPS_CACHE")
                bench_tps+=("$tps_val")

                model stop 2>/dev/null
                sleep 1
            done

            # Results table
            echo ""
            __tac_divider
            printf "${C_Dim}  %-13s %-25s %-8s %-6s %s${C_Reset}\n" "PROFILE" "MODEL" "SIZE" "PROC" "TPS"
            printf "${C_Dim}  ─────────────────────────────────────────────────────────────${C_Reset}\n"
            for i in "${!bench_prof[@]}"; do
                printf "  %-13s %-25s %-8s %-6s %s\n" \
                    "${bench_prof[$i]}" "${bench_name[$i]}" "${bench_size[$i]}" "${bench_proc[$i]}" "${bench_tps[$i]}"
            done
            __tac_footer

            # Persist results to TSV for historical comparison
            local bench_file="$AI_STORAGE_ROOT/.llm/bench_$(date +%Y%m%d_%H%M%S).tsv"
            {
                printf "profile\tmodel\tsize\tprocessor\ttps\n"
                for i in "${!bench_prof[@]}"; do
                    printf "%s\t%s\t%s\t%s\t%s\n" \
                        "${bench_prof[$i]}" "${bench_name[$i]}" "${bench_size[$i]}" "${bench_proc[$i]}" "${bench_tps[$i]}"
                done
            } > "$bench_file"
            __tac_info "Results saved" "[$bench_file]" "$C_Dim"
            ;;

        *)
            echo "Usage: model {list|start|stop|active|info|assign|test|download|pull|swap|bench}"
            ;;
    esac
}

# Convenience wrappers — 'serve'/'halt' mirror common muscle memory
serve() { model start "$1"; }
halt()  { model stop; }

function mlogs() {
    __resolve_vscode_bin
    "$VSCODE_BIN" "$LLM_LOG_FILE"
    echo "VS Code opened..."
}

# ---------------------------------------------------------------------------
# burn — Stress test the local LLM with a ~1300 token physics prompt.
# Uses non-streaming request with accurate server-reported completion_tokens.
# Pure bash + curl + jq with nanosecond timing.
# ---------------------------------------------------------------------------
function burn() {
    __require_llm || return 1
    command clear
    __tac_header "HARDWARE BURN-IN STRESS TEST"

    echo -e "${C_Dim}Testing: ~1300 token synthetic physics response...${C_Reset}"
    echo -e "${C_Highlight}Processing ....${C_Reset}"

    local prompt="Explain the complete theory of special relativity in extreme detail, including the mathematical derivations for time dilation."

    # Non-streaming request — curl + jq, with bash nanosecond timing.
    local payload
    payload=$(jq -n --arg p "$prompt" '{messages: [{role: "user", content: $p}], max_tokens: 1500, temperature: 0.7}')

    local start_ns; start_ns=$(date +%s%N)
    local response
    response=$(curl -s --max-time 120 "$LOCAL_LLM_URL" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null)
    local end_ns; end_ns=$(date +%s%N)

    if [[ -z "$response" ]]; then
        echo -e "${C_Error}[API Error]${C_Reset} No response — model may still be booting. Retry in 5s."
        return 1
    fi

    # Check for HTTP-level error in response body
    local err_msg
    err_msg=$(printf '%s' "$response" | jq -r '.error.message // empty' 2>/dev/null)
    if [[ -n "$err_msg" ]]; then
        echo -e "${C_Warning}[API Status]${C_Reset} $err_msg"
        return 1
    fi

    local elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
    local elapsed_s=$(( elapsed_ms / 1000 ))
    local elapsed_dec=$(( (elapsed_ms % 1000) / 100 ))

    # Prefer server-reported completion_tokens; fall back to word count
    local tokens
    tokens=$(printf '%s' "$response" | jq -r '.usage.completion_tokens // 0' 2>/dev/null)
    if (( tokens == 0 )); then
        tokens=$(printf '%s' "$response" | jq -r '.choices[0].message.content // ""' 2>/dev/null | wc -w)
    fi

    local tps_int=0 tps_dec=0
    if (( elapsed_ms > 0 && tokens > 0 )); then
        local tps_x10=$(( tokens * 10000 / elapsed_ms ))
        tps_int=$(( tps_x10 / 10 ))
        tps_dec=$(( tps_x10 % 10 ))
    fi

    echo -e "${C_Dim}Hint: If inference was slow, first run \"wake\" to lock WDDM state.${C_Reset}"
    echo -e "${C_Success}Burn complete in ${elapsed_s}.${elapsed_dec}s with ${tokens} output tokens giving ${tps_int}.${tps_dec} t/s${C_Reset}"
    echo "${tps_int}.${tps_dec} t/s" > "${LLM_TPS_CACHE}.tmp" && mv "${LLM_TPS_CACHE}.tmp" "$LLM_TPS_CACHE"

    [[ -f "$LLM_TPS_CACHE" ]] && LAST_TPS=$(< "$LLM_TPS_CACHE")
}

# ---------------------------------------------------------------------------
# explain — Ask the local LLM to explain the last command run in the terminal.
# Uses `fc -ln -2 -2` instead of history parsing for reliability with HISTCONTROL.
# ---------------------------------------------------------------------------
function explain() {
    local last_cmd; last_cmd=$(fc -ln -2 -2 2>/dev/null | sed 's/^\s*//')
    if [[ -z "$last_cmd" ]]; then
        __tac_line "Explain" "[NO PREVIOUS COMMAND FOUND]" "$C_Warning"
        return 1
    fi
    __llm_stream "Explain this bash command and diagnose any potential errors:\n$last_cmd"
}

# ---------------------------------------------------------------------------
# wtf_repl — Ask the local LLM to explain a tool or concept (toggle mode).
# Type a topic, get an explanation, then type another. 'end-chat' or Ctrl-C to exit.
# Aliased as 'wtf:' in section 3.
# ---------------------------------------------------------------------------
function wtf_repl() {
    local initial="$*"
    __require_llm || return 1

    # Trap Ctrl-C so it breaks the loop cleanly (exit 0, no error badge)
    trap 'echo; trap - INT; return 0' INT

    # If called with args, handle the first query then enter the loop
    if [[ -n "$initial" ]]; then
        __llm_stream "Explain how to use the following tool or concept:\n$initial"
    fi
    echo -e "${C_Dim}wtf: mode — type a topic (or 'end-chat' / Ctrl-C to exit)${C_Reset}"
    while true; do
        local topic
        read -r -e -p $'\e[96mwtf: \e[0m' topic || break
        [[ -z "$topic" ]] && continue
        [[ "$topic" == "end-chat" ]] && break
        __llm_stream "Explain how to use the following tool or concept:\n$topic"
    done

    trap - INT
}

# ---------------------------------------------------------------------------
# __llm_sse_core — Shared SSE streaming engine for all LLM functions.
# Called by __llm_stream (one-shot prompts) and __llm_chat_send (multi-turn).
# Pure bash + curl + jq. Posts payload to llama.cpp OpenAI-compatible API,
# streams SSE delta chunks, computes TPS, caches metrics.
# Sets __LAST_LLM_RESPONSE with the full response text.
# Usage: __llm_sse_core "$json_payload"
# ---------------------------------------------------------------------------
__llm_sse_core() {
    local payload="$1"
    __LAST_LLM_RESPONSE=""

    local start_ns; start_ns=$(date +%s%N)
    local chunk_count=0
    local server_tokens=0
    local response_text=""

    while IFS= read -r line; do
        [[ "$line" != data:* ]] && continue
        local payload_data="${line#data: }"
        [[ "$payload_data" == "[DONE]" ]] && break

        local content
        content=$(printf '%s' "$payload_data" | jq -r '.choices[0].delta.content // empty' 2>/dev/null)
        if [[ -n "$content" ]]; then
            printf '%s' "$content"
            response_text+="$content"
            ((chunk_count++))
        fi

        local srv_tok
        srv_tok=$(printf '%s' "$payload_data" | jq -r '.usage.completion_tokens // empty' 2>/dev/null)
        [[ -n "$srv_tok" && "$srv_tok" != "null" ]] && server_tokens=$srv_tok
    done < <(curl -s --no-buffer --max-time 300 -X POST "$LOCAL_LLM_URL" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null | tr -d '\r')

    local end_ns; end_ns=$(date +%s%N)
    local elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
    local tokens=$server_tokens
    local approx=""
    if (( tokens == 0 )); then tokens=$chunk_count; approx="~"; fi

    if (( tokens > 0 && elapsed_ms > 0 )); then
        local tps_x10=$(( tokens * 10000 / elapsed_ms ))
        local tps_int=$(( tps_x10 / 10 ))
        local tps_dec=$(( tps_x10 % 10 ))
        local elapsed_s=$(( elapsed_ms / 1000 ))
        printf '\n\e[90m[%s.%s t/s | %s%s tokens | %ss]\e[0m\n' \
            "$tps_int" "$tps_dec" "$approx" "$tokens" "$elapsed_s"
        echo "${tps_int}.${tps_dec} t/s" > "${LLM_TPS_CACHE}.tmp" && mv "${LLM_TPS_CACHE}.tmp" "$LLM_TPS_CACHE"
    else
        echo
    fi

    [[ -f "$LLM_TPS_CACHE" ]] && LAST_TPS=$(< "$LLM_TPS_CACHE")
    __LAST_LLM_RESPONSE="$response_text"
}

# ---------------------------------------------------------------------------
# __llm_stream — SSE streaming helper for explain / wtf / chat.
# Usage: __llm_stream "prompt text" [show_header: 1|0] [messages_json]
#   If messages_json is provided (a valid JSON array), it is sent directly
#   instead of wrapping prompt in a single user message. This enables
#   multi-turn conversation history for local_chat.
# MODULARISATION NOTE: writes LLM_TPS_CACHE, read by tactical_dashboard.
# ---------------------------------------------------------------------------
__llm_stream() {
    local prompt="$1"
    local show_header="${2:-1}"
    local messages_json="${3:-}"
    __require_llm || return 1

    local payload
    if [[ -n "$messages_json" ]]; then
        payload=$(jq -n --argjson msgs "$messages_json" '{messages: $msgs, stream: true}')
    else
        payload=$(jq -n --arg p "$prompt" '{messages: [{role: "user", content: $p}], stream: true}')
    fi

    (( show_header == 1 )) && echo -e "\n${C_Highlight}AI Analysis:${C_Reset}\n"

    __llm_sse_core "$payload"
}

# ---------------------------------------------------------------------------
# __llm_chat_send — Send a message with conversation history to the local LLM.
# Usage: __llm_chat_send "user message" "messages_json_array"
#   Returns: the assistant's response text is captured via __LAST_LLM_RESPONSE.
# ---------------------------------------------------------------------------
__llm_chat_send() {
    local user_msg="$1"
    local messages_json="$2"
    __require_llm || return 1

    local payload
    payload=$(jq -n --argjson msgs "$messages_json" '{messages: $msgs, stream: true}')

    __llm_sse_core "$payload"
}

# ---------------------------------------------------------------------------
# local_chat — Interactive chat REPL with multi-turn conversation history.
# Accumulates user and assistant messages so the LLM has context of the full
# conversation. First argument (if any) becomes the opening message.
# Type 'end-chat' or press Ctrl-C to return to the shell.
# Aliased as 'chat:' in section 3.
# ---------------------------------------------------------------------------
function local_chat() {
    __require_llm || return 1

    # Trap Ctrl-C: clean up nested function, restore trap, exit cleanly
    trap 'echo; unset -f __send_chat_msg 2>/dev/null; trap - INT; return 0' INT

    # Conversation history as a JSON array string
    local history='[]'

    __send_chat_msg() {
        local user_msg="$1"
        # Append user message to history
        history=$(printf '%s' "$history" | jq --arg m "$user_msg" '. + [{role: "user", content: $m}]')
        echo
        __llm_chat_send "$user_msg" "$history"
        # Append assistant response to history
        if [[ -n "$__LAST_LLM_RESPONSE" ]]; then
            history=$(printf '%s' "$history" | jq --arg m "$__LAST_LLM_RESPONSE" '. + [{role: "assistant", content: $m}]')
        fi
    }

    local initial="$*"
    # If called with an initial prompt, send it first
    if [[ -n "$initial" ]]; then
        __send_chat_msg "$initial"
    fi
    echo -e "${C_Dim}chat: mode — type a message (or 'end-chat' / 'save' / Ctrl-C to exit)${C_Reset}"
    while true; do
        local msg
        echo
        read -r -e -p $'\e[96mchat: \e[0m' msg || break
        [[ -z "$msg" ]] && continue
        [[ "$msg" == "end-chat" ]] && break
        if [[ "$msg" == "save" ]]; then
            local save_file="$HOME/chat_$(date +%Y%m%d_%H%M%S).json"
            printf '%s' "$history" | jq '.' > "$save_file" 2>/dev/null \
                && echo -e "${C_Success}Saved to $save_file${C_Reset}" \
                || echo -e "${C_Error}Failed to save${C_Reset}"
            continue
        fi
        __send_chat_msg "$msg"
    done

    unset -f __send_chat_msg
    trap - INT
}

# ---------------------------------------------------------------------------
# chat-context — Feed a file as context then ask the local LLM about it.
# Usage: chat-context <file> "question about this file"
# The file content is prepended as context to the user's question.
# ---------------------------------------------------------------------------
chat-context() {
    if [[ -z "$1" ]]; then
        echo -e "${C_Dim}Usage:${C_Reset} chat-context <file> \"question about this file\""
        return 1
    fi
    local file="$1"; shift
    local question="$*"
    if [[ ! -f "$file" ]]; then
        __tac_info "File" "[NOT FOUND: $file]" "$C_Error"
        return 1
    fi
    __require_llm || return 1
    # Cap file content to stay within context window (configurable via env)
    local max_chars="${CHAT_CONTEXT_MAX:-16000}"
    local content; content=$(head -c "$max_chars" "$file")
    local prompt="Here is the content of '$file':\n\n\`\`\`\n${content}\n\`\`\`\n\n${question:-Explain this file.}"
    __llm_stream "$prompt"
}

# ---------------------------------------------------------------------------
# chat-pipe — Pipe stdin as context and ask the local LLM about it.
# Usage: cat error.log | chat-pipe "What's wrong here?"
# ---------------------------------------------------------------------------
chat-pipe() {
    __require_llm || return 1
    local ctx; ctx=$(cat)
    if [[ -z "$ctx" ]]; then
        __tac_info "stdin" "[EMPTY — pipe some content]" "$C_Error"
        return 1
    fi
    local question="${*:-Explain this.}"
    __llm_stream "${ctx}\n\n${question}"
}

# ==============================================================================
# 12. DASHBOARD & HELP
# ==============================================================================
# @modular-section: dashboard-help
# @depends: constants, design-tokens, ui-engine, telemetry, hooks, openclaw, llm-manager
# @exports: tactical_dashboard, tactical_help

# ---------------------------------------------------------------------------
# tactical_dashboard — Full-screen system status panel.
# ---------------------------------------------------------------------------
function tactical_dashboard() {
    command clear
    __TAC_BG_PIDS=()  # Reset to avoid unbounded growth across renders
    local line; printf -v line '%*s' "$((UIWidth - 2))" ''; line="${line// /═}"

    __tac_header "TACTICAL DASHBOARD" "open" "$TACTICAL_PROFILE_VERSION"

    # --- System metrics block ---
    local systime; systime=$(date +"%A %H:%M %d/%m/%Y")
    local uptime; uptime=$(__get_uptime)
    local batt; batt=$(__get_battery)
    local host_raw; host_raw=$(__get_host_metrics)
    local cpu gpu0 gpu1
    IFS='|' read -r cpu gpu0 gpu1 <<< "$host_raw"
    cpu=${cpu:-0}; gpu0=${gpu0:-0}; gpu1=${gpu1:-0}
    local disk; disk=$(__get_disk)
    local _mem_raw; _mem_raw=$(free -m | awk 'NR==2{printf "%.2f / %.2f Gb|%d", $3/1024, $2/1024, $3*100/$2}')
    local mem="${_mem_raw%|*}"
    local mem_pct="${_mem_raw##*|}"

    __fRow "SYSTEM TIME" "$systime" "$C_Text"
    __fRow "UPTIME" "$uptime" "$C_Text"

    # Battery colour: >50% green, 20-50% yellow, <20% red, A/C=green
    local batt_color=$C_Success
    if [[ "$batt" != "A/C POWERED" && "$batt" =~ ^([0-9]+)% ]]; then
        local batt_pct=${BASH_REMATCH[1]}
        if (( batt_pct < 20 )); then batt_color=$C_Error
        elif (( batt_pct < 50 )); then batt_color=$C_Warning
        fi
    fi
    __fRow "BATTERY" "$batt" "$batt_color"

    local gpu_raw; gpu_raw=$(__get_gpu)

    # CPU/GPU colour: >90% red, >75% yellow, else green
    local cpu_gpu_color=$C_Success
    local max_gpu=$(( gpu0 > gpu1 ? gpu0 : gpu1 ))
    if (( cpu > 90 || max_gpu > 90 )); then cpu_gpu_color=$C_Error
    elif (( cpu > 75 || max_gpu > 75 )); then cpu_gpu_color=$C_Warning
    fi
    __fRow "CPU / GPU" "CPU ${cpu}% | GPU0 ${gpu0}% | GPU1 ${gpu1}%" "$cpu_gpu_color"

    # Memory colour: <75% used=green, 75-90%=yellow, >90%=red
    local mem_color=$C_Success
    if (( mem_pct > 90 )); then mem_color=$C_Error
    elif (( mem_pct > 75 )); then mem_color=$C_Warning
    fi
    __fRow "MEMORY" "$mem" "$mem_color"
    __fRow "STORAGE" "$disk" "$C_Text"

    # --- GPU & LLM block ---
    echo -e "${C_BoxBg}╠${line}╣${C_Reset}"

    local gpu_display="$gpu_raw"
    local g_name="" g_temp="" g_util="" g_mem_u="" g_mem_t=""
    if [[ "$gpu_raw" != "N/A" && "$gpu_raw" != "Querying..." && "$gpu_raw" != *"OFFLINE"* ]]; then
        IFS=',' read -r g_name g_temp g_util g_mem_u g_mem_t <<< "$gpu_raw"
        g_name="${g_name/ Laptop GPU/}"; g_name="${g_name# }"; g_name="${g_name% }"
        gpu_display="${g_name} | ${g_util// /}% Load | ${g_temp// /}°C | ${g_mem_u// /} / ${g_mem_t// /} Mb"
    fi
    # GPU colour: <75% load=green, 75-90%=yellow, >90%=red
    local gpu_color=$C_Highlight
    if [[ "$gpu_raw" != "N/A" && "$gpu_raw" != "Querying..." && "$gpu_raw" != *"OFFLINE"* ]]; then
        local g_util_n=${g_util// /}
        gpu_color=$C_Success
        if (( g_util_n > 90 )); then gpu_color=$C_Error
        elif (( g_util_n > 75 )); then gpu_color=$C_Warning
        fi
    fi
    __fRow "GPU COMPUTE" "$gpu_display" "$gpu_color"

    if __test_port "$LLM_PORT"; then
        local raw; raw=$(cat "$ACTIVE_LLM_FILE" 2>/dev/null)
        IFS='|' read -r a_prof a_name a_size a_proc <<< "$raw"
        local act_mod="${a_name:-ONLINE}"
        local tps; tps=$(cat "$LLM_TPS_CACHE" 2>/dev/null)
        __fRow "LOCAL LLM" "ACTIVE $act_mod | ${tps:-$LAST_TPS}" "$C_Success"

        # LLM context utilisation via async-cached /slots query
        local slots_json; slots_json=$(__get_llm_slots)
        if [[ -n "$slots_json" ]]; then
            local ctx_used ctx_total
            ctx_used=$(printf '%s' "$slots_json" | jq -r '.[0].n_past // 0' 2>/dev/null)
            ctx_total=$(printf '%s' "$slots_json" | jq -r '.[0].n_ctx // 0' 2>/dev/null)
            if (( ctx_total > 0 )); then
                local ctx_pct=$(( ctx_used * 100 / ctx_total ))
                local ctx_color=$C_Success
                (( ctx_pct >= 90 )) && ctx_color=$C_Error
                (( ctx_pct >= 75 && ctx_pct < 90 )) && ctx_color=$C_Warning
                __fRow "LLM CONTEXT" "${ctx_pct}% (${ctx_used}/${ctx_total} tokens)" "$ctx_color"
            fi
        fi
    else
        __fRow "LOCAL LLM" "OFFLINE" "$C_Dim"
    fi

    __fRow "WSL" "ACTIVE  ${WSL_DISTRO_NAME:-UNKNOWN}  ($(uname -r))" "$C_Success"

    # --- OpenClaw status block ---
    echo -e "${C_BoxBg}╠${line}╣${C_Reset}"
    local oc_stat="OFFLINE"
    local oc_active=0
    __test_port "$OC_PORT" && { oc_stat="ONLINE"; oc_active=1; }

    local metrics; metrics=$(__get_oc_metrics)
    local m_sess m_ver
    IFS='|' read -r m_sess m_ver <<< "$metrics"
    m_sess=${m_sess%$'\r'}; m_ver=${m_ver%$'\r'}

    __fRow "OPENCLAW" "[$oc_stat]  ${m_ver}" "$([[ $oc_active == 1 ]] && echo "$C_Success" || echo "$C_Error")"

    local sess_color=$C_Dim
    if [[ "$m_sess" != "Querying..." && "$m_sess" =~ ^[0-9]+$ ]]; then
        [[ $m_sess -gt 0 ]] && sess_color=$C_Warning
    fi
    __fRow "SESSIONS" "$m_sess Active" "$sess_color"

    local tokens; tokens=$(__get_tokens)
    if [[ "$tokens" == "Querying..."* || "$tokens" == "N/A"* ]]; then
        __fRow "CONTEXT USED" "No data" "$C_Dim"
    else
        local t_used t_limit
        IFS='|' read -r t_used t_limit <<< "$tokens"
        t_used=${t_used%$'\r'}; t_limit=${t_limit%$'\r'}
        local t_pct=$(( t_limit > 0 ? t_used * 100 / t_limit : 0 ))
        local h_used h_limit
        if (( t_used >= 1000 )); then h_used="$(( t_used / 1000 ))k"; else h_used="$t_used"; fi
        if (( t_limit >= 1000 )); then h_limit="$(( t_limit / 1000 ))k"; else h_limit="$t_limit"; fi
        __fRow "CONTEXT USED" "${t_pct}% (${h_used} of ${h_limit})" "$([[ $t_pct -ge 90 ]] && echo "$C_Error" || echo "$C_Success")"
    fi

    # "Cloaking" = active Python virtual environment isolation
    [[ -n "$VIRTUAL_ENV" ]] && __fRow "CLOAKING" "ACTIVE ($(basename "$VIRTUAL_ENV"))" "$C_Success"

    local gitStat; gitStat=$(__get_git)
    if [[ -n "$gitStat" ]]; then
        echo -e "${C_BoxBg}╠${line}╣${C_Reset}"
        local gBranch gSec
        IFS='|' read -r gBranch gSec <<< "$gitStat"
        __fRow "TARGET REPO" "$gBranch" "$C_Warning"
        __fRow "SEC STATUS" "$gSec" "$([[ $gSec == "BREACHED" ]] && echo "$C_Error" || echo "$C_Success")"
    fi

    echo -e "${C_BoxBg}╠${line}╣${C_Reset}"

    local cmds="up | $([[ $oc_active == 1 ]] && echo "xo" || echo "so") | serve | halt | chat: | commit | status | h"
    local totalPad=$(( UIWidth - 2 - ${#cmds} ))
    local leftPad=$(( totalPad / 2 ))
    local rightPad=$(( totalPad - leftPad ))

    local lCmdPad=""; (( leftPad  > 0 )) && printf -v lCmdPad '%*s' "$leftPad"  ""
    local rCmdPad=""; (( rightPad > 0 )) && printf -v rCmdPad '%*s' "$rightPad" ""

    printf "${C_BoxBg}║%s${C_Dim}%s${C_Reset}%s${C_BoxBg}║${C_Reset}\n" "$lCmdPad" "$cmds" "$rCmdPad"

    echo -e "${C_BoxBg}╚${line}╝${C_Reset}"
}

# ---------------------------------------------------------------------------
# tactical_help — Full-screen help index with all commands documented.
# ---------------------------------------------------------------------------
function tactical_help() {
    command clear
    __tac_header "HELP INDEX" "open" "$TACTICAL_PROFILE_VERSION"

    # First section title without leading divider (header already drew one)
    local __iw=$((UIWidth - 2))
    local __title="SYSTEM"
    local __pl=$(( (__iw - ${#__title}) / 2 ))
    local __pr=$(( __iw - ${#__title} - __pl ))
    local __ls=""; (( __pl > 0 )) && printf -v __ls '%*s' "$__pl" ""
    local __rs=""; (( __pr > 0 )) && printf -v __rs '%*s' "$__pr" ""
    printf "${C_BoxBg}║${C_Reset}${C_Warning}%s%s%s${C_Reset}${C_BoxBg}║${C_Reset}\n" "$__ls" "$__title" "$__rs"
    __hRow "m" "Open Tactical Dashboard with live system stats"
    __hRow "h" "Display this command reference with all shortcuts"
    __hRow "up" "Run 10-step maintenance: updates, caches, GPU, disk"
    __hRow "sysinfo" "One-line summary: CPU load, RAM, disk usage, GPU"
    __hRow "get-ip" "Show WSL internal IP and external WAN address"
    __hRow "cls / reload" "Clear screen + redraw banner / Full .bashrc reload"
    __hRow "cpwd" "Copy working directory path to Windows clipboard"
    __hRow "cl" "Remove python-*.exe and .pytest_cache in current dir"
    __hRow "logtrim" "Trim log files over 1 Mb to last 1000 lines"
    __hRow "oedit" "Open the .bashrc profile in VS Code for editing"
    __hRow "code <path>" "Open any file or directory in VS Code (lazy-resolved)"

    __hSection "OPENCLAW — GATEWAY"
    __hRow "so / xo" "Start / Stop the OpenClaw gateway (systemd)"
    __hRow "oc-restart" "Full gateway restart: stop, wait, then start"
    __hRow "ocgs / ocstat" "Gateway deep health probe / Full status --all"
    __hRow "oc-health" "Ping gateway HTTP /api/health endpoint"
    __hRow "oc-tail" "Live-tail gateway journal logs (Ctrl-C to stop)"
    __hRow "ocv" "Print installed OpenClaw CLI version string"
    __hRow "oc-update" "Update the OpenClaw CLI binary to latest release"
    __hRow "oc-tui" "Launch the OpenClaw interactive terminal UI"
    __hRow "status" "Quick overview of session health and recipients"

    __hSection "OPENCLAW — AGENTS & SESSIONS"
    __hRow "os / oa" "List all active sessions / Show registered agents"
    __hRow "ocstart" "Dispatch an agent turn (-m '<message>' required)"
    __hRow "ocstop" "Delete an agent by ID (--agent <id> required)"
    __hRow "oc-agent-turn" "Alias for ocstart (send an agent turn)"
    __hRow "mem-index" "Rebuild the OpenClaw vector memory search index"
    __hRow "oc-memory-search" "Semantic search across the OpenClaw memory store"

    __hSection "OPENCLAW — CONFIG & LOGS"
    __hRow "occonf" "Open openclaw.json global config in VS Code"
    __hRow "oc-config" "Read or write OpenClaw config keys (get|set|unset)"
    __hRow "oc-env" "Display all OpenClaw and LLM environment variables"
    __hRow "ockeys" "List Windows API keys bridged into the WSL session"
    __hRow "ocms" "Probe all configured model provider endpoints"
    __hRow "ocdoc-fix" "Run openclaw doctor --fix with config backup"
    __hRow "oclogs" "Open the /tmp/openclaw runtime log in VS Code"
    __hRow "le / lo / lc" "Gateway: 40-line stderr / 120-line full / Clear all"
    __hRow "ologs" "Change directory to the OpenClaw logs folder"
    __hRow "oc-sec" "Run a deep OpenClaw security audit with findings"
    __hRow "oc-docs" "Full-text search across OpenClaw documentation"
    __hRow "oc-cache-clear" "Remove /dev/shm telemetry caches to force refresh"
    __hRow "oc-diag" "5-point check: doctor, gateway, models, env, logs"
    __hRow "oc-failover" "Configure cloud LLM fallback (on|off|status)"
    __hRow "oc-refresh-keys" "Force re-import of Windows API keys into WSL"
    __hRow "oc-trust-sync" "Save current oc-llm-sync.sh SHA256 as trusted"

    __hSection "OPENCLAW — DATA & EXTENSIONS"
    __hRow "owk / ocroot" "Jump to OpenClaw Workspace or Root config dir"
    __hRow "oc-backup" "Snapshot workspace + agents to timestamped ZIP"
    __hRow "oc-restore" "Restore workspace + agents from a backup ZIP"
    __hRow "oc-cron" "Manage OpenClaw scheduled tasks (list|add|runs)"
    __hRow "oc-skills" "Show installed and eligible OpenClaw skill modules"
    __hRow "oc-plugins" "Manage plugins (list|doctor|enable|disable)"
    __hRow "oc-usage" "Display token and cost usage stats (default: 7d)"
    __hRow "oc-channels" "Manage messaging channels (list|status|logs)"
    __hRow "oc-browser" "Control headless browser (status|start|stop)"
    __hRow "oc-nodes" "Manage compute nodes (status|list|describe)"
    __hRow "oc-sandbox" "Manage code execution sandboxes (list|recreate)"

    __hSection "OPENCLAW — LLM INTEGRATION"
    __hRow "oc-local-llm" "Register local llama.cpp as an OpenClaw provider"
    __hRow "oc-sync-models" "Sync models.conf with OpenClaw provider scan"

    __hSection "LLM — MODEL MANAGEMENT"
    __hRow "wake" "Lock NVIDIA GPU persistence mode and WDDM state"
    __hRow "llmconf" "Open the models.conf registry file in VS Code"
    __hRow "model list" "Show all models with profile, size and processor"
    __hRow "model info" "Display full details for a named profile slot"
    __hRow "model assign" "Assign a .gguf model file to a profile slot"
    __hRow "model active" "Show the currently loaded and running LLM"
    __hRow "model test" "Health-check ping to the running LLM endpoint"
    __hRow "model download" "Download a GGUF model from HuggingFace Hub"
    __hRow "model pull" "Alias for model download (Ollama-style shorthand)"
    __hRow "model swap" "Hot-swap: stop current model and start a new one"
    __hRow "model bench" "Benchmark all on-disk models and compare TPS"
    __hRow "serve <prof>" "Boot a model by profile name (fast|think|experi)"
    __hRow "halt" "Stop the local llama.cpp inference server"
    __hRow "mlogs" "Open the llama-server runtime log in VS Code"
    __hRow "burn" "Run ~1300 token stress test and measure live TPS"

    __hSection "LLM — CHAT & EXPLAIN"
    __hRow "chat: [msg]" "Interactive LLM chat session (end-chat to exit)"
    __hRow "  save" "Inside chat: save conversation history to ~/chat_*.json"
    __hRow "chat-context" "Load a file as context then ask questions about it"
    __hRow "chat-pipe" "Pipe stdout from another command as LLM context"
    __hRow "explain" "Ask the local LLM to explain your last command"
    __hRow "wtf: [topic]" "Interactive topic explainer REPL (end-chat to exit)"

    __hSection "GIT & PROJECTS"
    __hRow "mkproj <n>" "Scaffold project: PEP-8 main.py, .venv, git init"
    __hRow "commit: <m>" "Git add, commit with your message, push and deploy"
    __hRow "commit" "Git add + commit (LLM auto-message) + push + deploy"
    __hRow "deploy" "Rsync ~/console directory to OpenClaw_Prod"
    __hRow "cop" "Launch interactive GitHub Copilot CLI session"
    __hRow "?? <prompt>" "One-shot Copilot prompt (e.g. ?? find large files)"
    __hRow "cop-ask <msg>" "Non-interactive Copilot prompt (spelled-out alias)"
    __hRow "cop-init" "Generate copilot-instructions.md for a project"

    __tac_footer
}

# ==============================================================================
# 13. INITIALIZATION
# ==============================================================================
# @modular-section: init
# @depends: all sections above
# @exports: (none — runs startup side-effects only)

# Create required directories
mkdir -p "$OC_ROOT" "$OC_LOGS" "$OC_BACKUPS" "$TacticalRoot" "$AI_STORAGE_ROOT/.llm"

# Check for required dependencies
if ! command -v jq >/dev/null 2>&1; then
    echo -e "\e[33m[Tactical Profile]\e[0m Missing: jq (required). Run: sudo apt install -y jq"
fi

# Initialize UI (guard prevents screen-clear on re-source)
if [[ -z "${__TAC_INITIALIZED:-}" ]]; then
    clear_tactical
    __TAC_INITIALIZED=1
fi

# Load completions safely (only once — guarded with -f check)
[[ -f "$BASH_COMPLETION_SCRIPT" ]] && . "$BASH_COMPLETION_SCRIPT"
[[ -f "$OC_ROOT/completions/openclaw.bash" ]] && source "$OC_ROOT/completions/openclaw.bash"

# Fix Loopback for WSL Mirrored Networking (Idempotent & Pulse-Free).
# Uses 'command ip' to call /usr/bin/ip directly, avoiding any function shadow.
if ! command ip link show loopback0 >/dev/null 2>&1; then
    if sudo -n true 2>/dev/null; then
        sudo ip link add loopback0 type dummy 2>/dev/null
        sudo ip link set loopback0 up 2>/dev/null
        sudo ip addr add 127.0.0.2/8 dev loopback0 2>/dev/null
    fi
fi

# OpenClaw LLM sync function (added by Hal)
# NOTE: This silently sources an external script. If the file is compromised,
# it executes in the interactive shell. Hash is verified against a trusted
# reference file and logged for auditability.
if [[ -f "$OC_WORKSPACE/oc-llm-sync.sh" ]]; then
    _sync_hash=$(sha256sum "$OC_WORKSPACE/oc-llm-sync.sh" 2>/dev/null | cut -d' ' -f1)
    echo "$(date +"%Y-%m-%d %H:%M:%S") [SOURCE] oc-llm-sync.sh SHA256=${_sync_hash:-unknown}" >> "$ErrorLogPath" 2>/dev/null
    if [[ -f "$OC_ROOT/oc-llm-sync.sha256" ]]; then
        _trusted_hash=$(< "$OC_ROOT/oc-llm-sync.sha256")
        if [[ "$_sync_hash" != "$_trusted_hash" ]]; then
            echo -e "\e[33m[Tactical Profile]\e[0m oc-llm-sync.sh hash mismatch — skipped (run 'oc-trust-sync' to update)"
            unset _sync_hash _trusted_hash
        else
            source "$OC_WORKSPACE/oc-llm-sync.sh" 2>/dev/null || true
            unset _sync_hash _trusted_hash
        fi
    else
        # No trusted hash file yet — source but warn
        source "$OC_WORKSPACE/oc-llm-sync.sh" 2>/dev/null || true
        unset _sync_hash
    fi
fi

# Bridge Windows User API keys into WSL so OpenClaw fallback providers work.
# Cached in /dev/shm for 1 hour; run 'oc-refresh-keys' to force refresh.
__bridge_windows_api_keys

# Clean up background telemetry subshells on shell exit.
# Only kills PIDs we spawned for caching — not user-started background jobs.
# Chains with any pre-existing EXIT trap to avoid silently overwriting it.
__TAC_BG_PIDS=()
__tac_exit_cleanup() {
    local pid
    for pid in "${__TAC_BG_PIDS[@]}"; do
        kill "$pid" 2>/dev/null
    done
}
_tac_prev_exit_trap=$(trap -p EXIT | sed "s/trap -- '//;s/' EXIT//")
trap '__tac_exit_cleanup; '"${_tac_prev_exit_trap:-}" EXIT
unset _tac_prev_exit_trap

# ==============================================================================
# end of file

# OpenClaw Completion
source "/home/wayne/.openclaw/completions/openclaw.bash"
