# shellcheck shell=bash
# shellcheck disable=SC2034,SC2059,SC2154
# ─── Module: 12-dashboard-help ───────────────────────────────────────────────────────
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# TACTICAL_PROFILE_VERSION auto-computes from the sum of all module versions.
# Module Version: 2
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
    local systime
    systime=$(date +"%H:%M %A %d/%m/%Y")
    local uptime
    uptime=$(__get_uptime)
    local batt
    batt=$(__get_battery)
    local host_raw
    host_raw=$(__get_host_metrics)
    local cpu gpu0 gpu1
    IFS='|' read -r cpu gpu0 gpu1 <<< "$host_raw"
    # Ensure numeric values for arithmetic (guard against stale/malformed cache)
    [[ "$cpu"  =~ ^[0-9]+$ ]] || cpu=0
    [[ "$gpu0" =~ ^[0-9]+$ ]] || gpu0=0
    [[ "$gpu1" =~ ^[0-9]+$ ]] || gpu1=0
    local disk
    disk=$(__get_disk)
    local _mem_raw
    _mem_raw=$(free -m | awk 'NR==2{printf "%.2f / %.2f Gb|%d", $3/1024, $2/1024, $3*100/$2}')
    local mem="${_mem_raw%|*}"
    local mem_pct="${_mem_raw##*|}"

    __fRow "SYSTEM TIME" "$systime" "$C_Text"
    __fRow "UPTIME" "$uptime" "$C_Text"

    # Battery colour: >50% green, 20-50% yellow, <20% red, A/C=green
    local batt_color=$C_Success
    if [[ "$batt" != "A/C POWERED" && "$batt" =~ ^([0-9]+)% ]]
    then
        local batt_pct=${BASH_REMATCH[1]}
        if (( batt_pct < 20 ))
        then
            batt_color=$C_Error
        elif (( batt_pct < 50 ))
        then
            batt_color=$C_Warning
        fi
    fi
    __fRow "BATTERY" "$batt" "$batt_color"

    local gpu_raw
    gpu_raw=$(__get_gpu)

    # CPU/GPU colour: >90% red, >75% yellow, else green
    local cpu_gpu_color
    local max_gpu=$(( gpu0 > gpu1 ? gpu0 : gpu1 ))
    cpu_gpu_color=$(__threshold_color $(( cpu > max_gpu ? cpu : max_gpu )))
    __fRow "CPU / GPU" "CPU ${cpu}% | iGPU ${gpu0}% | CUDA ${gpu1}%" "$cpu_gpu_color"

    # Memory colour: <75% used=green, 75-90%=yellow, >90%=red
    local mem_color
    mem_color=$(__threshold_color "$mem_pct")
    __fRow "MEMORY" "$mem" "$mem_color"
    __fRow "STORAGE" "$disk" "$C_Text"

    # --- GPU & LLM block ---
    printf '%s\n' "${C_BoxBg}╠${line}╣${C_Reset}"

    local gpu_display="$gpu_raw"
    local g_name="" g_temp="" g_util="" g_mem_u="" g_mem_t=""
    if [[ "$gpu_raw" != "N/A" && "$gpu_raw" != "Querying..." && "$gpu_raw" != *"OFFLINE"* ]]
    then
        IFS=',' read -r g_name g_temp g_util g_mem_u g_mem_t <<< "$gpu_raw"
        g_name="${g_name/ Laptop GPU/}"; g_name="${g_name# }"; g_name="${g_name% }"
        gpu_display="${g_name} | ${g_util// /}% Load | ${g_temp// /}°C | ${g_mem_u// /} / ${g_mem_t// /} Mb"
    fi
    # GPU colour: <75% load=green, 75-90%=yellow, >90%=red
    local gpu_color=$C_Highlight
    if [[ "$gpu_raw" != "N/A" && "$gpu_raw" != "Querying..." && "$gpu_raw" != *"OFFLINE"* ]]
    then
        local g_util_n=${g_util// /}
        g_util_n=${g_util_n%\%}  # Strip trailing % for numeric comparison
        gpu_color=$(__threshold_color "$g_util_n")
    fi
    __fRow "GPU" "$gpu_display" "$gpu_color"

    if __test_port "$LLM_PORT"
    then
        local act_mod="ONLINE"
        local _anum
        _anum=$(cat "$ACTIVE_LLM_FILE" 2>/dev/null)
        if [[ -n "$_anum" && -f "$LLM_REGISTRY" ]]
        then
            local _entry
            _entry=$(awk -F'|' -v n="$_anum" '$1 == n' "$LLM_REGISTRY" 2>/dev/null)
            IFS='|' read -r _ _aname _ <<< "$_entry"
            [[ -n "$_aname" ]] && act_mod="#${_anum} ${_aname}"
        fi
        local tps
        tps=$(cat "$LLM_TPS_CACHE" 2>/dev/null)
        if [[ -z "$tps" && -n "$_entry" ]]; then
            tps=$(awk -F'|' '{print $11}' <<< "$_entry")
            [[ -n "$tps" && "$tps" != "0" ]] && tps="${tps} tps"
        fi
        __fRow "LOCAL LLM" "ACTIVE $act_mod | ${tps:-$LAST_TPS}" "$C_Success"

        # LLM context utilisation via async-cached /slots query
        local slots_json
        slots_json=$(__get_llm_slots)
        if [[ -n "$slots_json" ]]
        then
            local ctx_used ctx_total
            ctx_used=$(printf '%s' "$slots_json" | jq -r '.[0].n_past // 0' 2>/dev/null)
            ctx_total=$(printf '%s' "$slots_json" | jq -r '.[0].n_ctx // 0' 2>/dev/null)
            if (( ctx_total > 0 ))
            then
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
    printf '%s\n' "${C_BoxBg}╠${line}╣${C_Reset}"
    local oc_stat="OFFLINE"
    local oc_active=0
    __test_port "$OC_PORT" && { oc_stat="ONLINE"; oc_active=1; }

    local metrics
    metrics=$(__get_oc_metrics)
    local m_sess m_age m_ver
    IFS='|' read -r m_sess m_age m_ver <<< "$metrics"
    m_sess=${m_sess%$'\r'}; m_age=${m_age%$'\r'}; m_ver=${m_ver%$'\r'}

    local oc_color=$C_Error
    if [[ $oc_active == 1 ]]
    then
        oc_color=$C_Success
    fi
    __fRow "OPENCLAW" "[$oc_stat]  ${m_ver}" "$oc_color"

    local sess_color=$C_Dim
    local age_label=""
    if [[ "$m_sess" != "Querying..." && "$m_sess" =~ ^[0-9]+$ ]]
    then
        (( m_sess > 0 )) && sess_color=$C_Warning
        if [[ "$m_age" =~ ^[0-9]+$ ]] && (( m_age > 0 ))
        then
            age_label=" (cached ${m_age}s ago)"
        else
            age_label=" (live)"
        fi
    fi
    __fRow "SESSIONS" "${m_sess} Active${age_label}" "$sess_color"

    # Replace single-line CONTEXT USED with multi-line ACTIVE AGENTS
    # Render the output of `oc agent-use` inside the dashboard box when OpenClaw is online.
    if [[ $oc_active == 1 ]]
    then
        local cache="/dev/shm/oc_agent_use.txt"
        local agent_use_out=""
        local cache_ttl=5
        if [[ -f "$cache" ]]; then
            # If the cache exists but is stale, kick a background refresh
            # so subsequent renders get fresh data, but still read the
            # current cache for this render to avoid blocking the UI.
            local mtime
            mtime=$(stat -c %Y "$cache" 2>/dev/null || echo 0)
            if (( $(date +%s) - mtime > cache_ttl )); then
                if command -v setsid >/dev/null 2>&1; then
                    setsid oc agent-use >/dev/null 2>&1 </dev/null || true
                else
                    oc agent-use >/dev/null 2>&1 </dev/null &>/dev/null &
                fi
            fi
            agent_use_out=$(cat "$cache" 2>/dev/null || true)
        else
            # Kick off a background refresh so the cache is populated for
            # subsequent renders, but do not block the dashboard render now.
            if command -v setsid >/dev/null 2>&1; then
                setsid oc agent-use >/dev/null 2>&1 </dev/null || true
            else
                ( oc agent-use >/dev/null 2>&1 ) &>/dev/null &
            fi
        fi
        if [[ -z "$agent_use_out" ]]
        then
            __fRow "ACTIVE AGENT" "No data" "$C_Dim"
        else
            # Use __fRow to render the first agent on the same row as the
            # "ACTIVE AGENTS" label so the "::" alignment, colours and
            # right-border padding match other dashboard rows. Subsequent
            # agents are rendered with an empty label so their text lines up
            # under the value column.
            local first=1
            while IFS= read -r _l; do
                l=${_l%$'\r'}
                # Trim leading/trailing spaces and skip blank/header lines
                l=$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' <<< "$l")
                [[ -z "$l" ]] && continue
                [[ "$l" =~ ^ACTIVE[[:space:]]+AGENT ]] && continue
                [[ "$l" =~ ^ACTIVE[[:space:]]+AGENTS ]] && continue
                if (( first == 1 )); then
                    # Insert a colon after the agent name before the numeric data
                    # Ensure a colon follows the agent name. Split at the first
                    # numeric token (the percentages/counts) and insert ':' after
                    # the name if not already present.
                    if [[ "$l" =~ ^([^:]+):?[[:space:]]*([0-9]{1,3}%.*)$ ]]; then
                        name_part="${BASH_REMATCH[1]}"
                        rest_part="${BASH_REMATCH[2]}"
                        name_part="${name_part%:}"
                        # Colourize the leading percent token for the first agent
                        if [[ "$rest_part" =~ ^([0-9]{1,3})% ]]; then
                            local pct_val="${BASH_REMATCH[1]}"
                            local pct_tok="${pct_val}%"
                            local pct_color
                            pct_color=$(__threshold_color "$pct_val")
                            local rest_after
                            rest_after="${rest_part#"${pct_tok}"}"
                            rest_part="${pct_color}${pct_tok}${C_Reset}${rest_after}"
                        fi
                        formatted="${name_part}: ${rest_part}"
                    else
                        # No numeric suffix; just ensure trailing colon on name
                        formatted="$l"
                        [[ "$formatted" != *: ]] && formatted="${formatted}:"
                    fi
                    __fRow "ACTIVE AGENT" "$formatted" ""
                    first=0
                else
                    # Render subsequent agent lines without the " :: " label
                    # but reserve the same label width so values align.
                    # Use the same measurements as __fRow to preserve alignment.
                    local val_width=$(( UIWidth - 20 ))
                    # Split using the original line (preserve ANSI sequences in the
                    # remainder so percent colouring is retained). Use __strip_ansi
                    # only for width calculation below.
                    if [[ "$l" =~ ^([^:]+):?[[:space:]]*([0-9]{1,3}%.*)$ ]]; then
                        name_part="${BASH_REMATCH[1]}"
                        rest_part="${BASH_REMATCH[2]}"
                        name_part="${name_part%:}"
                        # Apply colouring to the leading percent token in rest_part
                        if [[ "$rest_part" =~ ^([0-9]{1,3})% ]]; then
                            local pct_val="${BASH_REMATCH[1]}"
                            local pct_tok="${pct_val}%"
                            local pct_color
                            pct_color=$(__threshold_color "$pct_val")
                            local rest_after
                            rest_after="${rest_part#"${pct_tok}"}"
                            rest_part="${pct_color}${pct_tok}${C_Reset}${rest_after}"
                        fi
                        formatted="${name_part}: ${rest_part}"
                    else
                        formatted="$l"
                        [[ "$formatted" != *: ]] && formatted="${formatted}:"
                    fi
                    local cleanFormatted
                    __strip_ansi "$formatted" cleanFormatted
                    local valPad=$(( val_width - ${#cleanFormatted} ))
                    (( valPad < 0 )) && valPad=0
                    local vPadStr=""; (( valPad > 0 )) && printf -v vPadStr '%*s' "$valPad" ""
                    local labelPad=""; printf -v labelPad '%*s' 12 ""
                    printf "${C_BoxBg}║${C_Reset}"
                    printf "  ${C_Dim}%s${C_Reset}" "$labelPad"
                    # Reserve the same 4-character separator width as __fRow (" :: ")
                    printf "    %s%s${C_BoxBg}║${C_Reset}\n" "$formatted" "$vPadStr"
                fi
            done <<< "$agent_use_out"
            if (( first == 1 )); then
                __fRow "ACTIVE AGENT" "No data" "$C_Dim"
            fi
        fi
    else
        __fRow "ACTIVE AGENT" "OFFLINE" "$C_Dim"
    fi

    # "Cloaking" = active Python virtual environment isolation
    if [[ -n "$VIRTUAL_ENV" ]]
    then
        __fRow "CLOAKING" "ACTIVE ($(basename "$VIRTUAL_ENV"))" "$C_Success"
    fi

    local gitStat
    gitStat=$(__get_git)
    if [[ -n "$gitStat" ]]
    then
        printf '%s\n' "${C_BoxBg}╠${line}╣${C_Reset}"
        local gBranch gSec
        IFS='|' read -r gBranch gSec <<< "$gitStat"
        __fRow "TARGET REPO" "$gBranch" "$C_Warning"
        local sec_color=$C_Success
        if [[ "$gSec" == "BREACHED" ]]
        then
            sec_color=$C_Error
        fi
        __fRow "SEC STATUS" "$gSec" "$sec_color"
    fi

    printf '%s\n' "${C_BoxBg}╠${line}╣${C_Reset}"

    local cmds_toggle
    if [[ $oc_active == 1 ]]
    then
        cmds_toggle="xo"
    else
        cmds_toggle="so"
    fi
    local cmds="up | ${cmds_toggle} | serve <n> | halt | chat: | commit | h"
    local totalPad=$(( UIWidth - 2 - ${#cmds} ))
    local leftPad=$(( totalPad / 2 ))
    local rightPad=$(( totalPad - leftPad ))

    local lCmdPad=""; (( leftPad  > 0 )) && printf -v lCmdPad '%*s' "$leftPad"  ""
    local rCmdPad=""; (( rightPad > 0 )) && printf -v rCmdPad '%*s' "$rightPad" ""

    printf "${C_BoxBg}║%s${C_Dim}%s${C_Reset}%s${C_BoxBg}║${C_Reset}\n" "$lCmdPad" "$cmds" "$rCmdPad"

    printf '%s\n' "${C_BoxBg}╚${line}╝${C_Reset}"
}

# ---------------------------------------------------------------------------
# bashrc_diagnose — Quick health check of the shell environment.
# Reports: bash version, profile version, shell options, key paths, loaded
# functions count, and basic sanity checks.
# ---------------------------------------------------------------------------
function bashrc_diagnose() {
    echo "=== Tactical Console Diagnostics ==="
    echo "Profile version : ${TACTICAL_PROFILE_VERSION:-unknown}"
    echo "Bash version    : ${BASH_VERSION}"
    echo "Shell           : $SHELL"
    echo "Term            : ${TERM:-unset}"
    echo "Interactive     : $(case $- in (*i*) echo yes;; (*) echo no;; esac)"
    local _login_shell
    if shopt -q login_shell
    then
        _login_shell="yes"
    else
        _login_shell="no"
    fi
    echo "Login shell     : $_login_shell"
    echo ""
    echo "=== Key Paths ==="
    echo "AI_STORAGE_ROOT : ${AI_STORAGE_ROOT:-unset}"
    echo "OC_ROOT         : ${OC_ROOT:-unset}"
    echo "LLAMA_ROOT      : ${LLAMA_ROOT:-unset}"
    echo "LLM_REGISTRY    : ${LLM_REGISTRY:-unset}"
    echo "TAC_CACHE_DIR   : ${TAC_CACHE_DIR:-unset}"
    echo ""
    echo "=== Tool Availability ==="
    local tools=(git jq curl nvidia-smi openclaw python3 node npm)
    for t in "${tools[@]}"
    do
        if command -v "$t" >/dev/null 2>&1
        then
            echo "  $t : $(command -v "$t")"
        else
            echo "  $t : NOT FOUND"
        fi
    done
    echo ""
    echo "=== Function Count ==="
    echo "  Public  : $(declare -F | grep -cv ' __')"
    echo "  Private : $(declare -F | grep -c ' __')"
    echo ""
    echo "=== ShellCheck ==="
    if command -v shellcheck >/dev/null 2>&1
    then
        local src="${BASH_SOURCE[0]:-$HOME/ubuntu-console/tactical-console.bashrc}"
        local sc_count
        sc_count=$(shellcheck -s bash "$src" 2>&1 | grep -c '^In ' || true)
        echo "  Findings: $sc_count"
    else
        echo "  shellcheck not installed"
    fi
}

# ---------------------------------------------------------------------------
# bashrc_dryrun — Source the profile in a subshell to check for errors
# without affecting the current session.
# ---------------------------------------------------------------------------
function bashrc_dryrun() {
    local src="${BASH_SOURCE[0]:-$HOME/ubuntu-console/tactical-console.bashrc}"
    echo "Dry-run: sourcing $src in a subshell..."
    if bash -n "$src" 2>&1
    then
        echo "${C_Success}PASS${C_Reset} — No syntax errors."
    else
        echo "${C_Error}FAIL${C_Reset} — Syntax errors detected above."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# tactical_help — Full-screen help index with all commands documented.
# ---------------------------------------------------------------------------
function tactical_help() {
    command clear
    __tac_header "HELP INDEX" "open" "$TACTICAL_PROFILE_VERSION"

    # First section: rendered without leading divider (header already drew one).
    # Uses a manual centred title instead of __hSection to avoid the ╠═══╣ divider.
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
    __hRow "cls / reload" "Clear screen + redraw banner / Full profile reload"
    __hRow "cpwd" "Copy working directory path to Windows clipboard"
    __hRow "cl" "Remove python-*.exe and .pytest_cache in current dir"
    __hRow "logtrim" "Trim log files over 1 Mb to last 1000 lines"
    __hRow "oedit" "Open tactical-console.bashrc in VS Code for editing"
    __hRow "code <path>" "Open any file or directory in VS Code (lazy-resolved)"

    __hSection "OPENCLAW — GATEWAY"
    __hRow "so / xo" "Start / Stop the OpenClaw gateway (xo stops only — use 'oc restart' to restart)"
    __hRow "oc restart" "Full gateway restart (native: openclaw gateway restart)"
    __hRow "oc gs / oc stat" "Gateway deep health probe / Full status --all"
    __hRow "oc health" "Ping gateway HTTP /api/health endpoint"
    __hRow "oc tail" "Live-tail gateway journal logs (Ctrl-C to stop)"
    __hRow "oc v" "Print installed OpenClaw CLI version string"
    __hRow "oc update" "Update the OpenClaw CLI binary to latest release"
    __hRow "oc tui" "Launch the OpenClaw interactive terminal UI"

    __hSection "OPENCLAW — AGENTS & SESSIONS"
    __hRow "os / oa" "List all active sessions / Show registered agents"
    __hRow "oc start" "Dispatch an agent turn (--message '<msg>' required)"
    __hRow "oc stop" "Delete an agent by ID (--agent <id> required)"
    __hRow "oc agent-turn" "Alias for oc start (send an agent turn)"
    __hRow "oc mem-index" "Rebuild the OpenClaw vector memory search index"
    __hRow "oc memory-search" "Semantic search across the OpenClaw memory store"

    __hSection "OPENCLAW — CONFIG & LOGS"
    __hRow "oc conf" "Open openclaw.json global config in VS Code"
    __hRow "oc config" "Read or write OpenClaw config keys (get|set|unset)"
    __hRow "oc env" "Display all OpenClaw and LLM environment variables"
    __hRow "oc keys" "List Windows API keys bridged into the WSL session"
    __hRow "oc ms" "Probe all configured model provider endpoints"
    __hRow "oc doc-fix" "Run openclaw doctor --fix with config backup"
    __hRow "oc logs" "Open the /tmp/openclaw runtime log in VS Code"
    __hRow "le / lo / lc" "Gateway: 40-line tail / 120-line full / Clear all"
    __hRow "oc log-dir" "Change directory to the OpenClaw logs folder"
    __hRow "oc sec" "Run a deep OpenClaw security audit with findings"
    __hRow "oc docs" "Full-text search across OpenClaw documentation"
    __hRow "oc cache-clear" "Remove /dev/shm telemetry caches to force refresh"
    __hRow "oc diag" "5-point check: doctor, gateway, models, env, logs"
    __hRow "oc failover" "Configure cloud LLM fallback (on|off|status)"
    __hRow "oc refresh-keys" "Force re-import of Windows API keys into WSL"

    __hSection "OPENCLAW — DATA & EXTENSIONS"
    __hRow "oc wk / oc root" "Jump to OpenClaw Workspace or Root config dir"
    __hRow "oc backup" "Snapshot workspace + agents to timestamped ZIP"
    __hRow "oc restore" "Restore workspace + agents from a backup ZIP"
    __hRow "oc cron" "Manage OpenClaw scheduled tasks (list|add|runs)"
    __hRow "oc skills" "Show installed and eligible OpenClaw skill modules"
    __hRow "oc plugins" "Manage plugins (list|doctor|enable|disable)"
    __hRow "oc usage" "Display token and cost usage stats (default: 7d)"
    __hRow "oc channels" "Manage messaging channels (list|status|logs)"
    __hRow "oc browser" "Control headless browser (status|start|stop)"
    __hRow "oc nodes" "Manage compute nodes (status|list|describe)"
    __hRow "oc sandbox" "Manage code execution sandboxes (list|recreate)"

    __hSection "OPENCLAW — LLM INTEGRATION"
    __hRow "oc local-llm" "Register local llama.cpp as an OpenClaw provider"
    __hRow "oc sync-models" "Sync models.conf with OpenClaw provider scan"

    __hSection "LLM — MODEL MANAGEMENT"
    __hRow "wake" "Lock NVIDIA GPU persistence mode and WDDM state"
    __hRow "gpu-status" "Detailed NVIDIA GPU stats: util, VRAM, temp, power"
    __hRow "gpu-check" "Quick CUDA verification: device, VRAM, layer offload"
    __hRow "llmconf" "Open the models.conf registry file in VS Code"
    __hRow "model scan" "Scan model dir, read GGUF metadata, auto-calculate params"
    __hRow "model list" "Show numbered model registry (▶ = active)"
    __hRow "model default [N]" "Show current default LLM or set it to model #N"
    __hRow "model use N" "Start model #N with optimal GPU/ctx/thread settings"
    __hRow "model stop" "Stop the local llama-server"
    __hRow "model status" "Show what's currently running"
    __hRow "model info N" "Display full details for model #N"
    __hRow "model bench" "Benchmark all on-disk models and compare TPS"
    __hRow "model delete N" "Permanently delete model #N from disk and registry"
    __hRow "model archive N" "Move model #N to /mnt/m/archive/ and deregister"
    __hRow "model download" "Download GGUF models from Hugging Face (repo:file)"
    __hRow "serve N" "Alias for model use N"
    __hRow "halt" "Stop the local llama.cpp inference server"
    __hRow "mlogs" "Open the llama-server runtime log in VS Code"
    __hRow "burn" "Run ~1300 token stress test and measure live TPS"

    __hSection "LLM — CHAT & EXPLAIN"
    __hRow "chat: [msg]" "Interactive LLM chat session (end-chat to exit)"
    __hRow "  save" "Inside chat: save conversation history to ~/chat_*.json"
    __hRow "chat-context" "Load a file as context then ask questions about it"
    __hRow "chat-pipe" "Pipe stdout from another command as LLM context"
    __hRow "explain" "Ask the local LLM to explain your last command"
    __hRow "wtf [topic]" "Interactive topic explainer REPL (end-chat to exit)"

    __hSection "GIT & PROJECTS"
    __hRow "mkproj <n>" "Scaffold project: PEP-8 main.py, .venv, git init"
    __hRow "commit: <msg>" "Git add, commit with your message, and push"
    __hRow "commit" "Git add + commit (LLM auto-message) + push"
    __hRow "cop" "Launch interactive GitHub Copilot CLI session"
    __hRow "?? <prompt>" "One-shot Copilot prompt (e.g. ?? find large files)"
    __hRow "cop-ask <msg>" "Non-interactive Copilot prompt (spelled-out alias)"
    __hRow "cop-init" "Generate copilot-instructions.md for a project"

    __hSection "DIAGNOSTICS"
    __hRow "bashrc_diagnose" "Health check: versions, paths, tools, functions"
    __hRow "bashrc_dryrun" "Syntax-check the profile without affecting session"

    __tac_footer
}


# end of file
