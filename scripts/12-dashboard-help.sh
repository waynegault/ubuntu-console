# shellcheck shell=bash
# shellcheck disable=SC2034,SC2059,SC2154
# ─── Module: 12-dashboard-help ───────────────────────────────────────────────────────
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# TACTICAL_PROFILE_VERSION auto-computes from the sum of all module versions.
# Module Version: 6
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
    # Reset the background PID tracker. Telemetry __get_* functions append
    # subshell PIDs here; the EXIT trap (__tac_exit_cleanup in §13) kills
    # any still running when the shell exits. Clearing prevents unbounded
    # growth across multiple dashboard renders in a single session.
    __TAC_BG_PIDS=()
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

    # Enhanced battery status with time remaining (if discharging)
    local batt_detail="$batt"
    if [[ "$batt" != "A/C POWERED" && "$batt" != "N/A" ]]
    then
        local time_remaining=0
        local bat_file
        for bat_file in /sys/class/power_supply/BAT*/time_remaining
        do
            if [[ -f "$bat_file" ]]
            then
                time_remaining=$(head -1 < "$bat_file" 2>/dev/null)
                break
            fi
        done
        if [[ -n "$time_remaining" && "$time_remaining" =~ ^[0-9]+$ ]] && (( time_remaining > 0 ))
        then
            local hours=$((time_remaining / 3600))
            local mins=$(( (time_remaining % 3600) / 60 ))
            batt_detail="$batt (~${hours}h ${mins}m)"
        fi
    fi

    # Battery colour: >50% green, 20-50% yellow, <20% red, A/C=green
    local batt_color=$C_Success
    if [[ "$batt" != "A/C POWERED" && "$batt" != "N/A" && "$batt" =~ ^([0-9]+)% ]]
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
    __fRow "BATTERY" "$batt_detail" "$batt_color"

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
        g_util_n=${g_util_n:-0}   # Default to 0 if empty (prevents __threshold_color error)
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
    if [[ "$__TAC_OPENCLAW_OK" != "1" ]]; then
        # OpenClaw CLI not installed — show single status line
        __fRow "OPENCLAW" "[NOT INSTALLED]" "$C_Dim"
    else
        # OpenClaw installed — show detailed status
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
            # Sanitize output: remove control characters (except newlines) to prevent
            # terminal manipulation via ANSI escape sequences or other control codes.
            agent_use_out=$(printf '%s' "$agent_use_out" | tr -d '\000-\010\013-\037\177')
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
                    if [[ "$l" =~ ^(.+?)[[:space:]]+([0-9].*)$ ]]; then
                        name_part="${BASH_REMATCH[1]}"
                        rest_part="${BASH_REMATCH[2]}"
                        name_part="${name_part%:}"
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
                    if [[ "$l" =~ ^(.+?)[[:space:]]+([0-9].*)$ ]]; then
                        name_part="${BASH_REMATCH[1]}"
                        rest_part="${BASH_REMATCH[2]}"
                        name_part="${name_part%:}"
                        # Apply colouring to the leading percent token in rest_part
                        if [[ "$rest_part" =~ ^([0-9]{1,3})% ]]; then
                            local pct_val="${BASH_REMATCH[1]}"
                            local pct_tok="${BASH_REMATCH[1]}%"
                            local pct_color
                            pct_color=$(__threshold_color "$pct_val")
                            rest_part="${rest_part/"$pct_tok"/"${pct_color}${pct_tok}${C_Reset}"}"
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
    fi  # End of $__TAC_OPENCLAW_OK check

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
    local cmds="up | ${cmds_toggle} | serve <n> | halt | chat: | commit | g | h"
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
    if [[ "$__TAC_OPENCLAW_OK" == "1" ]]; then
        echo "OC_ROOT         : ${OC_ROOT:-unset}"
    else
        echo "OC_ROOT         : (OpenClaw not installed)"
    fi
    echo "LLAMA_ROOT      : ${LLAMA_ROOT:-unset}"
    echo "LLM_REGISTRY    : ${LLM_REGISTRY:-unset}"
    echo "TAC_CACHE_DIR   : ${TAC_CACHE_DIR:-unset}"
    echo ""
    echo "=== Tool Availability ==="
    local tools=(git jq curl nvidia-smi openclaw gog python3 node npm)
    for t in "${tools[@]}"
    do
        if command -v "$t" >/dev/null 2>&1
        then
            local tool_path
            tool_path=$(command -v "$t")
            # Special handling for openclaw — check if functional, not just in PATH
            if [[ "$t" == "openclaw" ]]; then
                if [[ "$__TAC_OPENCLAW_OK" == "1" ]]; then
                    echo "  $t : $tool_path"
                else
                    echo "  $t : $tool_path (NOT FUNCTIONAL)"
                fi
            elif [[ "$t" == "gog" ]]; then
                if [[ "$__TAC_GOG_OK" == "1" ]]; then
                    echo "  $t : $tool_path"
                else
                    echo "  $t : $tool_path (NOT FUNCTIONAL)"
                fi
            else
                echo "  $t : $tool_path"
            fi
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
        local src="$TACTICAL_REPO_ROOT/tactical-console.bashrc"
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
    local src="$TACTICAL_REPO_ROOT/tactical-console.bashrc"
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
    __hRow "h" "Display this command reference"
    __hRow "up" "Run 15-step system maintenance"
    __hRow "sysinfo" "One-line summary: CPU, RAM, disk, GPU"
    __hRow "get-ip" "Show WSL and WAN IP addresses"
    __hRow "cls" "Clear screen"
    __hRow "reload" "Full profile reload"
    __hRow "cpwd" "Copy working directory to Windows clipboard"
    __hRow "cl" "Deep cleanup (apt, brew, journal, docker, npm)"
    __hRow "cl --light" "Light cleanup (python cache only)"
    __hRow "cl --report" "Show cleanup report (no deletion)"
    __hRow "logtrim" "Trim logs over 1MB to last 1000 lines"
    __hRow "oedit" "Open tactical-console.bashrc in VS Code"
    __hRow "code <path>" "Open any file or directory in VS Code"

    # OpenClaw sections — only shown if openclaw CLI is installed AND functional
    if [[ "$__TAC_OPENCLAW_OK" == "1" ]]; then
        __hSection "OPENCLAW — GATEWAY"
        __hRow "so" "Start the OpenClaw gateway"
        __hRow "xo" "Stop the OpenClaw gateway"
        __hRow "oc restart" "Full gateway restart"
        __hRow "oc gs" "Gateway deep health probe"
        __hRow "oc status" "Full gateway status --all"
        __hRow "oc health" "Gateway health probe"
        __hRow "oc tail" "Live-tail gateway logs (Ctrl-C)"
        __hRow "oc v" "Print OpenClaw CLI version"
        __hRow "oc update" "Update OpenClaw CLI"
        __hRow "oc tui" "Launch OpenClaw TUI"

        __hSection "OPENCLAW — AGENTS & SESSIONS"
        __hRow "os" "List active sessions"
        __hRow "oa" "Show registered agents"
        __hRow "oc start" "Dispatch agent turn (--message)"
        __hRow "oc stop" "Delete agent by ID"
        __hRow "oc mem-index" "Rebuild vector memory index"
        __hRow "oc memory-search" "Semantic memory search"

        __hSection "OPENCLAW — CONFIG & LOGS"
        __hRow "oc conf" "Open openclaw.json in VS Code"
        __hRow "oc config" "Read/write config keys (get|set)"
        __hRow "oc env" "Show OpenClaw environment vars"
        __hRow "oc keys" "List Windows API keys bridged"
        __hRow "oc ms" "Probe model provider endpoints"
        __hRow "oc doc-fix" "Run openclaw doctor --fix"
        __hRow "oc logs" "Open runtime log in VS Code"
        __hRow "le" "40-line log tail"
        __hRow "lo" "120-line full log"
        __hRow "lc" "Clear all logs"
        __hRow "oc log-dir" "Change to logs folder"
        __hRow "oc sec" "Deep security audit"
        __hRow "oc docs" "Search documentation"
        __hRow "oc cache-clear" "Clear /dev/shm telemetry caches"
        __hRow "oc diag" "5-point health check"
        __hRow "oc doctor-local" "Validate gateway + llama.cpp"
        __hRow "oc failover" "Cloud LLM fallback (on|off)"
        __hRow "oc refresh-keys" "Re-import Windows API keys"

        __hSection "OPENCLAW — DATA & EXTENSIONS"
        __hRow "oc wk" "Change to workspace"
        __hRow "oc root" "Change to root config"
        __hRow "oc backup" "Snapshot workspace + agents"
        __hRow "oc restore" "Restore from backup ZIP"
        __hRow "oc cron" "Manage scheduled tasks"
        __hRow "oc skills" "Show skill modules"
        __hRow "oc plugins" "Manage plugins"
        __hRow "oc usage" "Token/cost stats (7d)"
        __hRow "oc channels" "Messaging channels"
        __hRow "oc browser" "Headless browser"
        __hRow "oc nodes" "Compute nodes"
        __hRow "oc sandbox" "Code sandboxes"

        __hSection "OPENCLAW — LLM INTEGRATION"
        __hRow "oc local-llm" "Register local llama.cpp"
        __hRow "oc sync-models" "Sync models.conf"

        __hSection "OPENCLAW — TOOLS"
        __hRow "oc g" "Launch operational graph browser (overview/topics/files/semantic/raw)"
    fi

    # gog section — only shown if gog CLI is installed AND functional
    if [[ "$__TAC_GOG_OK" == "1" ]]; then
        __hSection "GOG — GOOGLE CLI"
        __hRow "gog-status" "Show auth/config status and accounts"
        __hRow "gog-login <email>" "Authorize and store refresh token"
        __hRow "gog-logout <email>" "Remove stored credentials"
        __hRow "gog-version" "Print gog version"
        __hRow "gog-help" "Show full gog help reference"
        __hRow "gog <command>" "Run gog commands directly"
    fi

    __hSection "LLM — MODEL MANAGEMENT"
    __hRow "wake" "Lock GPU persistence mode"
    __hRow "gpu-status" "NVIDIA GPU: util, VRAM, temp"
    __hRow "gpu-check" "Quick CUDA verification"
    __hRow "llmconf" "Open models.conf in VS Code"
    __hRow "model scan" "Scan and register models"
    __hRow "model list" "Show model registry"
    __hRow "model default [N]" "Show/set default model"
    __hRow "model use N" "Start model #N"
    __hRow "model stop" "Stop llama-server"
    __hRow "model status" "Show running models"
    __hRow "model doctor" "Validate setup"
    __hRow "model recommend" "Rank models for VRAM"
    __hRow "model info N" "Show model #N details"
    __hRow "model bench" "Benchmark all models"
    __hRow "model bench-diff" "Compare benchmark runs"
    __hRow "model bench-history" "Summarise benchmarks"
    __hRow "model delete N" "Delete model #N"
    __hRow "model archive N" "Archive model #N"
    __hRow "model download" "Download from HuggingFace"
    __hRow "serve N" "Alias for model use N"
    __hRow "halt" "Stop llama-server"
    __hRow "mlogs" "Open llama-server log"
    __hRow "burn" "Token stress test (~1300)"
    __hRow "docs-sync" "Check README drift"

    __hSection "LLM — CHAT & EXPLAIN"
    __hRow "chat: [msg]" "Interactive chat session"
    __hRow "chat-context" "Load file as context"
    __hRow "chat-pipe" "Pipe stdout as context"
    __hRow "explain" "Explain last command"
    __hRow "wtf [topic]" "Interactive explainer"

    __hSection "GIT & PROJECTS"
    __hRow "mkproj <n>" "Scaffold Python project"
    __hRow "commit: <msg>" "Commit with message"
    __hRow "commit" "Auto-commit + push"
    __hRow "cop" "Copilot CLI session"
    __hRow "?? <prompt>" "One-shot Copilot prompt"
    __hRow "cop-ask <msg>" "Non-interactive prompt"
    __hRow "cop-init" "Generate instructions.md"

    __hSection "DIAGNOSTICS"
    __hRow "bashrc_diagnose" "Health check"
    __hRow "bashrc_dryrun" "Syntax-check profile"

    __tac_footer
}

# ---------------------------------------------------------------------------
# contextual-help — Show relevant commands based on current context.
# Usage: contextual-help [auto|llm-active|python-dev|git-active|general]
# Auto-detects context if no argument provided.
# ---------------------------------------------------------------------------
function contextual-help() {
    local context="${1:-auto}"

    # Auto-detect context
    if [[ "$context" == "auto" ]]
    then
        if pgrep -x llama-server >/dev/null 2>&1
        then
            context="llm-active"
        elif [[ -n "$VIRTUAL_ENV" ]]
        then
            context="python-dev"
        elif git rev-parse --is-inside-work-tree >/dev/null 2>&1
        then
            context="git-active"
        else
            context="general"
        fi
    fi

    command clear
    __tac_header "CONTEXTUAL HELP: ${context}" "open"

    case "$context" in
        llm-active)
            __hRow "burn" "Send ~1300 token stress test, measure live TPS"
            __hRow "model stop" "Stop the currently active llama-server"
            __hRow "gpu-status" "Check GPU utilization, VRAM, temperature"
            __hRow "mlogs" "View llama-server runtime logs in VS Code"
            __hRow "chat:" "Start interactive chat with active model"
            __hRow "model bench" "Benchmark the active model"
            __tac_info "Tip" "Use 'model status' to see active model details" "$C_Dim"
            ;;
        python-dev)
            __hRow "deactivate" "Exit the current virtual environment"
            __hRow "pytest" "Run Python tests in current directory"
            __hRow "pip list" "Show installed packages in venv"
            __hRow "cl" "Clean python cache files (.pyc, __pycache__)"
            __hRow "mkproj <n>" "Scaffold new Python project with tests"
            __tac_info "Tip" "Virtual env auto-activates on cd into project" "$C_Dim"
            ;;
        git-active)
            __hRow "commit_auto" "AI-generated commit message from diff"
            __hRow "commit_deploy" "Commit with your message and push"
            __hRow "git status" "Show working tree and staging status"
            __hRow "git diff" "Show unstaged and staged changes"
            __hRow "cop" "Launch GitHub Copilot CLI session"
            __tac_info "Tip" "Use 'commit' for LLM-generated commit messages" "$C_Dim"
            ;;
        general|*)
            __hRow "m" "Open tactical dashboard with live system stats"
            __hRow "h" "Show full command reference (this is extended help)"
            __hRow "so" "Start OpenClaw gateway and local LLM"
            __hRow "model use N" "Start model #N with optimal settings"
            __hRow "up" "Run 12-step maintenance and health checks"
            __tac_info "Tip" "Run 'h' for full command index" "$C_Dim"
            ;;
    esac

    __tac_footer
}

# end of file
