# shellcheck shell=bash
# shellcheck disable=SC1090,SC2016,SC2034,SC2059,SC2154
# ─── Module: 09-openclaw ───────────────────────────────────────────────────────
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# TACTICAL_PROFILE_VERSION auto-computes from the sum of all module versions.
# Module Version: 1
# ==============================================================================
# 9. OPENCLAW MANAGER
# ==============================================================================
# @modular-section: openclaw
# @depends: constants, design-tokens, ui-engine, hooks
# @exports: so, xo, oc-restart, ocstart, ocstop, ockeys, ocdoc-fix,
#   __bridge_windows_api_keys, oc-refresh-keys, oc-backup, oc-restore,
#   owk, ologs, ocroot, oc, lc, oc-update, oc-health, oc-cron, oc-skills,
#   oc-plugins, oc-tail, oc-channels, oc-sec, oc-tui, oc-config,
#   oc-docs, oc-usage, oc-memory-search, oc-local-llm, oc-sync-models,
#   oc-browser, oc-nodes, oc-sandbox, oc-env, oc-cache-clear, oc-trust-sync,
#   oc-diag, oc-failover

# ---------------------------------------------------------------------------
# so — Start the OpenClaw gateway (systemd-managed service).
# Injects bridged API keys into the systemd user session before starting.
# ---------------------------------------------------------------------------
function so() {
    local _svc="openclaw-gateway.service"

    # Already healthy — nothing to do.
    if __test_port "$OC_PORT"
    then
        if pgrep -x llama-server >/dev/null 2>&1 && __test_port "$LLM_PORT"
        then
            __tac_info "Local LLM" "[RUNNING]" "$C_Success"
        else
            __tac_info "Local LLM" "[OFFLINE]" "$C_Warning"
        fi
        __tac_info "Gateway" "[ALREADY RUNNING]" "$C_Warning"
        return 0
    fi

    # ── Pre-flight: clear stale service state ──────────────────────────
    # If systemd already has the service in a failed or auto-restart
    # state (e.g. crash loop from a previous run), stop it cleanly and
    # reset the failure counter before attempting a fresh start.
    local _pre_state
    _pre_state=$(systemctl --user show -p SubState --value "$_svc" 2>/dev/null)
    if [[ "$_pre_state" == "auto-restart" || "$_pre_state" == "failed" ]]
    then
        __tac_info "Gateway" "[STALE — clearing ${_pre_state} state]" "$C_Warning"
        systemctl --user stop "$_svc" 2>/dev/null
        systemctl --user reset-failed "$_svc" 2>/dev/null
        sleep 1
    fi

    # ── Pre-flight: detect port held by orphan process ─────────────────
    if __test_port "$OC_PORT"
    then
        __tac_info "Gateway" "[PORT $OC_PORT HELD — freeing]" "$C_Warning"
        openclaw gateway stop >/dev/null 2>&1
        systemctl --user stop "$_svc" 2>/dev/null
        sleep 1
        if __test_port "$OC_PORT"
        then
            __tac_info "Gateway" "[PORT $OC_PORT BLOCKED]" "$C_Error"
            __so_check_win_port "$OC_PORT"
            return 1
        fi
    fi

    # ── Pre-flight: Windows-side port conflict (WSL only) ──────────────
    # WSL shares the Windows network stack. A Windows process binding the
    # port is invisible to ss/lsof but blocks bind() inside WSL. Check
    # proactively so the user gets a clear message instead of a crash loop.
    if ! __test_port "$OC_PORT" && __so_check_win_port "$OC_PORT" --block
    then
        return 1
    fi

    # ── Pre-flight: Tailscale Serve port conflict ──────────────────────
    # Tailscale Serve binds a userspace socket that is invisible to ss/lsof
    # but blocks Node's bind(). If Serve is proxying to our port and the
    # gateway isn't running, we must cycle Serve around the startup.
    local _ts_serve_active=0
    if command -v tailscale &>/dev/null
    then
        if tailscale serve status 2>/dev/null | grep -q ":$OC_PORT\b"
        then
            _ts_serve_active=1
            __tac_info "Tailscale Serve" "[CYCLING — port $OC_PORT proxy]" "$C_Dim"
            sudo -n tailscale serve off 2>/dev/null
            rm -f /tmp/openclaw-1000/gateway.*.lock 2>/dev/null
            sleep 1
        fi
    fi

    # ── Push API keys into the systemd user environment ────────────────
    # Systemd user services don't inherit interactive shell exports.
    # Read key names from the cache file and push via set-environment.
    local _key
    while IFS= read -r _line
    do
        _key="${_line#export }"
        _key="${_key%%=*}"
        [[ -n "$_key" && -n "${!_key:-}" ]] && systemctl --user set-environment "${_key}=${!_key}" 2>/dev/null
    done < <(grep '^export ' "$TAC_CACHE_DIR/tac_win_api_keys" 2>/dev/null)

    # ── Step 1: Ensure local LLM is running ──────────────────────────
    if pgrep -x llama-server >/dev/null 2>&1 && __test_port "$LLM_PORT"
    then
        # LLM is already running — show which model
        local _so_active_num=""
        [[ -f "$ACTIVE_LLM_FILE" ]] && _so_active_num=$(< "$ACTIVE_LLM_FILE")
        if [[ -n "$_so_active_num" && -f "$LLM_REGISTRY" ]]
        then
            local _so_entry
            _so_entry=$(awk -F'|' -v n="$_so_active_num" '$1 == n' "$LLM_REGISTRY" 2>/dev/null)
            local _so_mname
            IFS='|' read -r _ _so_mname _ <<< "$_so_entry"
            __tac_info "Local LLM" "[RUNNING] #${_so_active_num} ${_so_mname}" "$C_Success"
        else
            __tac_info "Local LLM" "[RUNNING]" "$C_Success"
        fi
    else
        # LLM not running — resolve default and start it
        local _so_def_conf="${LLAMA_DRIVE_ROOT:-/mnt/m}/.llm/default_model.conf"
        local _so_def_file=""
        [[ -f "$_so_def_conf" ]] && _so_def_file=$(< "$_so_def_conf")
        if [[ -z "$_so_def_file" ]]
        then
            __tac_info "Error" \
                "[Local LLM offline and no default set. Run 'model default <N>' to configure.]" \
                "$C_Error"
            return 1
        fi
        # Look up human-readable model name from registry
        local _so_model_name
        _so_model_name=$(awk -F'|' -v f="$_so_def_file" '$3 == f {print $2}' "$LLM_REGISTRY" 2>/dev/null)
        : "${_so_model_name:=$_so_def_file}"
        __tac_info "Local LLM" "[OFFLINE]" "$C_Warning"
        # Start the default LLM in background; show a compact spinner
        serve &>/dev/null &
        local _serve_pid=$!
        local _spin_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
        local _sw=0 _sw_max=90
        while kill -0 "$_serve_pid" 2>/dev/null && (( _sw < _sw_max ))
        do
            printf '\r  %s' "${C_Dim}${_spin_chars:_sw%10:1} Starting ${_so_model_name} (${_sw}s)${C_Reset}  "
            # Poll health for early exit once server has had time to launch
            if (( _sw > 3 )) && __test_port "$LLM_PORT"
            then
                local _hb
                _hb=$(curl -s --max-time 2 "http://127.0.0.1:$LLM_PORT/health" 2>/dev/null)
                [[ "$_hb" == *'"ok"'* ]] && break
            fi
            sleep 1
            ((_sw++))
        done
        printf '\r%s\r' "$(printf '%*s' 60 '')"   # clear spinner line
        wait "$_serve_pid" 2>/dev/null
        # Verify LLM is actually healthy
        if __test_port "$LLM_PORT"
        then
            local _final_health
            _final_health=$(curl -s --max-time 3 "http://127.0.0.1:$LLM_PORT/health" 2>/dev/null)
            if [[ "$_final_health" == *'"ok"'* ]]
            then
                __tac_info "Local LLM" "[ONLINE] ${_so_model_name} (${_sw}s)" "$C_Success"
            else
                __tac_info "Local LLM" "[NOT HEALTHY — check: tail $LLM_LOG_FILE]" "$C_Error"
                return 1
            fi
        else
            __tac_info "Local LLM" "[FAILED TO START — check: tail $LLM_LOG_FILE]" "$C_Error"
            return 1
        fi
    fi

    # ── Step 2: Start gateway ──────────────────────────────────────────
    openclaw gateway start >/dev/null 2>&1

    local ready=0 elapsed=0 max_wait=20
    local _restarts_before _spin_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    _restarts_before=$(systemctl --user show -p NRestarts --value "$_svc" 2>/dev/null || echo 0)

    while (( elapsed < max_wait ))
    do
        if __test_port "$OC_PORT"
        then
            ready=1
            break
        fi

        # Spinner with elapsed time — single overwritten line
        printf '\r%s' "  ${C_Dim}${_spin_chars:elapsed%10:1} Starting gateway (${elapsed}s)${C_Reset}  "

        # Every 5s, check for crash loops or hard failure
        if (( elapsed > 0 && elapsed % 5 == 0 ))
        then
            local _restarts_now _sub_state
            _restarts_now=$(systemctl --user show -p NRestarts --value "$_svc" 2>/dev/null || echo 0)
            _sub_state=$(systemctl --user show -p SubState --value "$_svc" 2>/dev/null)

            if (( _restarts_now > _restarts_before + 1 ))
            then
                printf '\r%s\n' "$(printf '%*s' 40 '')"
                __tac_info "Gateway" "[CRASH LOOP]" "$C_Error"
                __so_show_errors "$_svc"
                __so_check_win_port "$OC_PORT"
                printf '%s\n' "  ${C_Dim}Run 'xo' then 'so' to retry.${C_Reset}"
                return 1
            fi
            if [[ "$_sub_state" == "failed" ]]
            then
                printf '\r%s\n' "$(printf '%*s' 40 '')"
                __tac_info "Gateway" "[FAILED]" "$C_Error"
                __so_show_errors "$_svc"
                return 1
            fi
        fi

        sleep 1
        (( elapsed++ ))

        # After initial window, extend if service is still alive
        if (( elapsed == 15 && !ready ))
        then
            systemctl --user is-active --quiet "$_svc" 2>/dev/null && max_wait=30
        fi
    done
    # Clear spinner line
    printf '\r%s\r' "$(printf '%*s' 40 '')"

    # ── Result ─────────────────────────────────────────────────────────
    if (( ready ))
    then
        __tac_info "Gateway" "[ONLINE] (${elapsed}s)" "$C_Success"
    elif systemctl --user is-active --quiet "$_svc" 2>/dev/null
    then
        __tac_info "Gateway" "[STARTING — port not ready]" "$C_Warning"
        printf '%s\n' "  ${C_Dim}Service active after ${elapsed}s but port $OC_PORT not responding.${C_Reset}"
        printf '%s\n' "  ${C_Dim}Retry in a moment or run 'le' for logs.${C_Reset}"
    else
        __tac_info "Gateway" "[FAILED]" "$C_Error"
        __so_show_errors "$_svc"
        printf '%s\n' "  ${C_Dim}Run 'xo' then 'so' to retry, or 'le' for logs.${C_Reset}"
    fi

    # ── Post: restore Tailscale Serve if we cycled it ──────────────────
    if (( _ts_serve_active ))
    then
        sudo -n tailscale serve --bg "http://127.0.0.1:$OC_PORT" >/dev/null 2>&1 \
            && __tac_info "Tailscale Serve" "[RESTORED]" "$C_Dim"
    fi
}

# ---------------------------------------------------------------------------
# __so_show_errors — Extract and display the most recent gateway errors.
# Pulls the last 30 log lines and shows up to 5 matching error patterns.
# ---------------------------------------------------------------------------
function __so_show_errors() {
    local _svc="$1" _errors
    _errors=$(journalctl --user -u "$_svc" --no-pager -n 30 --output=cat 2>&1 \
        | grep -iE 'fail|error|port.*in use|already listening|exited|refused' | tail -5)
    if [[ -n "$_errors" ]]
    then
        printf '%s\n' "  ${C_Dim}Recent errors:${C_Reset}"
        while IFS= read -r _line
        do
            printf '%s\n' "    ${C_Dim}${_line}${C_Reset}"
        done <<< "$_errors"
    fi
}

# ---------------------------------------------------------------------------
# __so_check_win_port — Detect a Windows-side process holding a port (WSL).
# WSL shares the host network stack, so a Windows process binding a port is
# invisible to ss/lsof inside WSL but blocks bind().
# Usage: __so_check_win_port <port> [--block]
#   --block: if a Windows holder is found, print error and return 0 (= caller
#            should abort).  Without --block, just prints an advisory hint.
# Returns 0 if a Windows holder was found (and reported), 1 otherwise.
# ---------------------------------------------------------------------------
function __so_check_win_port() {
    local _port="$1" _block="${2:-}"
    # Only meaningful under WSL with access to PowerShell
    command -v powershell.exe &>/dev/null || return 1

    local _win_holder
    _win_holder=$(timeout 5 powershell.exe -NoProfile -NonInteractive -Command "
        \$c = Get-NetTCPConnection -LocalPort $_port -State Listen -ErrorAction SilentlyContinue
        if (\$c) {
            \$p = Get-Process -Id \$c.OwningProcess -ErrorAction SilentlyContinue
            '{0} (PID {1})' -f \$p.ProcessName, \$c.OwningProcess
        }
    " 2>/dev/null | tr -d '\r')

    [[ -z "$_win_holder" ]] && return 1

    if [[ "$_block" == "--block" ]]
    then
        __tac_info "Gateway" "[PORT $OC_PORT BLOCKED — Windows]" "$C_Error"
    fi
    printf '%s\n' "  ${C_Warning}Windows process holding port ${_port}: ${_win_holder}${C_Reset}"
    local _pid_only
    _pid_only="${_win_holder##*PID }"
    _pid_only="${_pid_only%%)*}"
    printf '%s\n' "  ${C_Dim}Kill it from Windows: taskkill /PID ${_pid_only} /F${C_Reset}"
    return 0
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
# oc — Unified OpenClaw command dispatcher.
# Usage: oc <subcommand> [args...]
# With no arguments, prints available subcommands.
# ---------------------------------------------------------------------------
function oc() {
    local sub="${1:-}"
    if [[ -z "$sub" ]]
    then
        printf '%s\n' "${C_Highlight}oc — OpenClaw Command Reference${C_Reset}"
        printf '%s\n' ""
        printf '%s\n' "${C_Highlight}Gateway${C_Reset}"
        printf '  %-20s %s\n' "restart"      "Full gateway restart: stop, wait, start"
        printf '  %-20s %s\n' "gs"           "Gateway deep health probe"
        printf '  %-20s %s\n' "stat"         "Show detailed status (--all)"
        printf '  %-20s %s\n' "health"       "Ping gateway HTTP /api/health"
        printf '  %-20s %s\n' "tail"         "Live-tail gateway logs (Ctrl-C to stop)"
        printf '  %-20s %s\n' "v"            "Print OpenClaw CLI version"
        printf '  %-20s %s\n' "update"       "Update OpenClaw CLI to latest"
        printf '  %-20s %s\n' "tui"          "Launch the interactive terminal UI"
        printf '%s\n' ""
        printf '%s\n' "${C_Highlight}Agents & Sessions${C_Reset}"
        printf '  %-20s %s\n' "start"        "Dispatch an agent turn (-m '<msg>')"
        printf '  %-20s %s\n' "stop"         "Delete an agent by ID (--agent <id>)"
        printf '  %-20s %s\n' "agent-turn"   "Alias for start"
        printf '  %-20s %s\n' "mem-index"     "Rebuild the vector memory search index"
        printf '  %-20s %s\n' "memory-search" "Semantic search across memory store"
        printf '%s\n' ""
        printf '%s\n' "${C_Highlight}Config & Logs${C_Reset}"
        printf '  %-20s %s\n' "conf"         "Open openclaw.json in VS Code"
        printf '  %-20s %s\n' "config"       "Get/set config keys (get|set|unset)"
        printf '  %-20s %s\n' "env"          "Dump all OC and LLM env variables"
        printf '  %-20s %s\n' "keys"         "List Windows API keys bridged to WSL"
        printf '  %-20s %s\n' "ms"           "Probe model provider endpoints"
        printf '  %-20s %s\n' "doc-fix"      "Run openclaw doctor --fix with backup"
        printf '  %-20s %s\n' "log-dir"      "cd to the OpenClaw logs folder"
        printf '  %-20s %s\n' "logs"         "Open runtime log in VS Code"
        printf '  %-20s %s\n' "sec"          "Deep security audit"
        printf '  %-20s %s\n' "docs"         "Search OpenClaw documentation"
        printf '  %-20s %s\n' "cache-clear"  "Wipe /dev/shm telemetry caches"
        printf '  %-20s %s\n' "diag"         "5-point check: doctor, gw, models, env, logs"
        printf '  %-20s %s\n' "failover"     "Cloud LLM fallback (on|off|status)"
        printf '  %-20s %s\n' "refresh-keys" "Re-import Windows API keys into WSL"
        printf '  %-20s %s\n' "trust-sync"   "Save oc-llm-sync.sh SHA256 as trusted"
        printf '%s\n' ""
        printf '%s\n' "${C_Highlight}Data & Extensions${C_Reset}"
        printf '  %-20s %s\n' "wk"           "cd to OpenClaw workspace directory"
        printf '  %-20s %s\n' "root"         "cd to OpenClaw root directory"
        printf '  %-20s %s\n' "backup"       "Snapshot workspace + agents to ZIP"
        printf '  %-20s %s\n' "restore"      "Restore from most recent backup ZIP"
        printf '  %-20s %s\n' "cron"         "Scheduled tasks (list|add|runs)"
        printf '  %-20s %s\n' "skills"       "List installed/eligible skill modules"
        printf '  %-20s %s\n' "plugins"      "Manage plugins (list|doctor|enable|disable)"
        printf '  %-20s %s\n' "usage"        "Token and cost usage stats (default: 7d)"
        printf '  %-20s %s\n' "channels"     "Messaging channels (list|status|logs)"
        printf '  %-20s %s\n' "browser"      "Browser automation (status|start|stop)"
        printf '  %-20s %s\n' "nodes"        "Compute nodes (status|list|describe)"
        printf '  %-20s %s\n' "sandbox"      "Code sandboxes (list|recreate|explain)"
        printf '%s\n' ""
        printf '%s\n' "${C_Highlight}LLM Integration${C_Reset}"
        printf '  %-20s %s\n' "local-llm"    "Register local llama.cpp as provider"
        printf '  %-20s %s\n' "sync-models"  "Sync models.conf with OC provider scan"
        return 0
    fi
    shift
    case "$sub" in
        # Gateway
        restart)       oc-restart "$@" ;;
        gs)            ocgs "$@" ;;
        stat)          ocstat "$@" ;;
        health)        oc-health "$@" ;;
        tail)          oc-tail "$@" ;;
        v)             ocv "$@" ;;
        update)        oc-update "$@" ;;
        tui)           oc-tui "$@" ;;
        # Agents & Sessions
        start)         ocstart "$@" ;;
        stop)          ocstop "$@" ;;
        agent-turn)    ocstart "$@" ;;
        mem-index)     mem-index "$@" ;;
        memory-search) oc-memory-search "$@" ;;
        # Config & Logs
        conf)          occonf "$@" ;;
        config)        oc-config "$@" ;;
        env)           oc-env "$@" ;;
        keys)          ockeys "$@" ;;
        ms)            ocms "$@" ;;
        doc-fix)       ocdoc-fix "$@" ;;
        log-dir)       ologs "$@" ;;
        logs)          oclogs "$@" ;;
        sec)           oc-sec "$@" ;;
        docs)          oc-docs "$@" ;;
        cache-clear)   oc-cache-clear "$@" ;;
        diag)          oc-diag "$@" ;;
        failover)      oc-failover "$@" ;;
        refresh-keys)  oc-refresh-keys "$@" ;;
        trust-sync)    oc-trust-sync "$@" ;;
        # Data & Extensions
        wk)            owk "$@" ;;
        root)          ocroot "$@" ;;
        backup)        oc-backup "$@" ;;
        restore)       oc-restore "$@" ;;
        cron)          oc-cron "$@" ;;
        skills)        oc-skills "$@" ;;
        plugins)       oc-plugins "$@" ;;
        usage)         oc-usage "$@" ;;
        channels)      oc-channels "$@" ;;
        browser)       oc-browser "$@" ;;
        nodes)         oc-nodes "$@" ;;
        sandbox)       oc-sandbox "$@" ;;
        # LLM Integration
        local-llm)     oc-local-llm "$@" ;;
        sync-models)   oc-sync-models "$@" ;;
        *)
            printf '%s\n' "${C_Error}Unknown subcommand:${C_Reset} $sub"
            printf '%s\n' "${C_Dim}Run 'oc' with no arguments for a list of commands.${C_Reset}"
            return 1
            ;;
    esac
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
# Usage: ocstart --message "<message>" [--to <E.164>] [--agent <id>]
# ---------------------------------------------------------------------------
function ocstart() {
    if [[ -z "$*" ]]
    then
        printf '%s\n' "${C_Dim}Usage:${C_Reset} oc start --message \"<message>\" [--to <E.164>] [--agent <id>]"
        printf '%s\n' "${C_Dim}  --message     Message body for the agent (required)${C_Reset}"
        printf '%s\n' "${C_Dim}  --to          Recipient number in E.164 format${C_Reset}"
        printf '%s\n' "${C_Dim}  --agent       Agent ID to target${C_Reset}"
        printf '%s\n' "${C_Dim}  --session-id  Explicit session ID${C_Reset}"
        printf '%s\n' "${C_Dim}  --thinking    Thinking level (off|minimal|low|medium|high|xhigh)${C_Reset}"
        return 1
    fi
    openclaw agent "$@"
}

# ---------------------------------------------------------------------------
# ocstop — Delete / stop an agent.
# Usage: ocstop --agent <id>
# ---------------------------------------------------------------------------
function ocstop() {
    if [[ -z "$*" ]]
    then
        printf '%s\n' "${C_Dim}Usage:${C_Reset} oc stop --agent <id>"
        printf '%s\n' "${C_Dim}  --agent  Agent ID to stop (required)${C_Reset}"
        printf '%s\n' "${C_Dim}  Tip: run 'oa' to list agents${C_Reset}"
        return 1
    fi
    openclaw agents delete "$@"
}

# ---------------------------------------------------------------------------
# ockeys — Show Windows environment API keys and their WSL visibility.
# Wraps the pwsh call in timeout to prevent hangs after sleep/hibernate.
# ---------------------------------------------------------------------------
function ockeys() {
    printf '%s\n' "${C_Highlight}API Keys & Tokens (Windows Environment → WSL):${C_Reset}"
    local found=0
    while IFS='=' read -r name val
    do
        [[ -z "$name" ]] && continue
        local upper; upper=${name^^}
        if [[ "$upper" == *API_KEY* || "$upper" == *API-KEY* || "$upper" == *TOKEN* || "$upper" == *APIKEY* ]]
        then
            local masked="${val:0:4}...${val: -4}"
            [[ ${#val} -lt 10 ]] && masked="(too short)"
            local oc_visible=""
            if printenv "$name" >/dev/null 2>&1
            then
                oc_visible="${C_Success}WSL ✓${C_Reset}"
            else
                oc_visible="${C_Error}WSL ✗${C_Reset}"
            fi
            printf '%s\n' "  ${C_Dim}$name${C_Reset}  $masked  $oc_visible"
            ((found++))
        fi
    done < <(timeout 5 pwsh.exe -NoProfile -Command '
        [Environment]::GetEnvironmentVariables("User").GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }
    ' 2>/dev/null | tr -d '\r')
    if (( found == 0 ))
    then
        __tac_info "Windows User Env" "[NO API-KEY / TOKEN VARS FOUND]" "$C_Warning"
    else
        printf '%s\n' "  ${C_Dim}$found key(s) found in Windows User environment${C_Reset}"
    fi
}

# ---------------------------------------------------------------------------
# ocdoc-fix — Run openclaw doctor --fix with automatic config backup.
# ---------------------------------------------------------------------------
function ocdoc-fix() {
    local cfg="$OC_ROOT/openclaw.json"
    local bak="${cfg}.pre-doctor"
    if [[ -f "$cfg" ]]
    then
        cp "$cfg" "$bak"
        __tac_info "Config Backup" "[SAVED → $(basename "$bak")]" "$C_Success"
    fi
    openclaw doctor --fix
    if [[ -f "$bak" && -f "$cfg" ]]
    then
        printf '%s\n' "${C_Dim}If settings were overwritten, restore with:${C_Reset}"
        printf '%s\n' "  ${C_Highlight}cp $bak $cfg${C_Reset}"
    fi
}

# ---------------------------------------------------------------------------
# __bridge_windows_api_keys — Import Windows User environment variables
# containing API_KEY or TOKEN into the WSL environment.
# Uses a /dev/shm cache (TTL 3600s = 1h) to avoid a slow pwsh call on
# every shell start. Run 'oc-refresh-keys' to force a re-import.
# Security: cache is chmod 600 and lives in tmpfs (RAM only, no disk).
# ---------------------------------------------------------------------------
function __bridge_windows_api_keys() {
    local cache="$TAC_CACHE_DIR/tac_win_api_keys"
    local ttl=3600

    # Use cached exports if fresh enough
    if [[ -f "$cache" ]] && (( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || echo 0) < ttl ))
    then
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

    if [[ -z "$raw" ]]
    then
        local _warn_msg="__bridge_windows_api_keys:"
        _warn_msg+=" pwsh.exe returned no data (timeout or not installed)"
        echo "$(date +"%Y-%m-%d %H:%M:%S") [WARN] ${_warn_msg}" \
            >> "$ErrorLogPath" 2>/dev/null
        return 1
    fi

    # Build a sourceable cache file, skipping vars with invalid names
    local tmpfile="${cache}.tmp"
    ( umask 077; : > "$tmpfile" )
    while IFS='=' read -r name val
    do
        [[ -z "$name" || "$name" =~ [^a-zA-Z0-9_] ]] && continue
        [[ -z "$val" ]] && continue
        # Reject values with embedded newlines (could inject extra commands)
        [[ "$val" == *$'\n'* ]] && continue
        printf 'export %s=%q\n' "$name" "$val" >> "$tmpfile"
    done <<< "$raw"
    mv "$tmpfile" "$cache"
    chmod 600 "$cache"
    source "$cache" 2>/dev/null
}

# ---------------------------------------------------------------------------
# oc-refresh-keys — Force re-import of Windows API keys into WSL.
# ---------------------------------------------------------------------------
function oc-refresh-keys() {
    rm -f "$TAC_CACHE_DIR/tac_win_api_keys"
    __bridge_windows_api_keys
    if [[ -f "$TAC_CACHE_DIR/tac_win_api_keys" ]]
    then
        local count
        count=$(wc -l < "$TAC_CACHE_DIR/tac_win_api_keys")
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
    if ! command -v zip >/dev/null
    then
        __tac_info "Dependency" "[zip not installed]" "$C_Error"
        printf '%s\n' "  ${C_Dim}Install: sudo apt install zip${C_Reset}"
        return 1
    fi

    local stamp
    stamp=$(date +"%Y%m%d_%H%M%S")
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
        # Shell profile and standalone scripts
        # Canonical profile is in the ubuntu-console repo; back up both the
        # thin loader (~/.bashrc) and the full profile.
        [[ -f ".bashrc" ]]                && targets+=(".bashrc")
        [[ -f "ubuntu-console/tactical-console.bashrc" ]] && targets+=("ubuntu-console/tactical-console.bashrc")
        local _script
        for _script in .local/bin/llama-watchdog.sh .local/bin/tac_hostmetrics.sh
        do
            [[ -f "$_script" ]] && targets+=("$_script")
        done
        # Systemd units
        for _script in .config/systemd/user/llama-watchdog.service \
                       .config/systemd/user/llama-watchdog.timer
        do
            [[ -f "$_script" ]] && targets+=("$_script")
        done

        if (( ${#targets[@]} > 0 ))
        then
            zip -r -q "$zipPath" "${targets[@]}"
        fi
    )

    # Model registry (on M drive, stored as .llm/models.conf in archive)
    if [[ -f "$LLM_REGISTRY" ]]
    then
        (cd "$LLAMA_DRIVE_ROOT" && zip -q "$zipPath" ".llm/models.conf")
    fi

    if [[ -f "$zipPath" ]]
    then
        local sz
        sz=$(stat -c%s "$zipPath" 2>/dev/null || echo "0")
        local human_sz=$(( sz / 1024 ))
        __tac_info "Snapshot Archive" "[CREATED — ${human_sz}KB]" "$C_Success"
        printf '%s\n' "  ${C_Dim}Path: $zipPath${C_Reset}"

        # Prune old snapshots — keep the 10 most recent
        local -a all_snaps=()
        local _s
        while IFS= read -r _s
        do
            all_snaps+=("$_s")
        done < <(ls -1t "$OC_BACKUPS"/snapshot_*.zip 2>/dev/null)
        local keep=10
        if (( ${#all_snaps[@]} > keep ))
        then
            local pruned=0
            local i
            for (( i=keep; i<${#all_snaps[@]}; i++ ))
            do
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
    if [[ -e "${snaps[0]}" ]]
    then
        local f newest="" newest_t=0
        for f in "${snaps[@]}"
        do
            local t
            t=$(stat -c %Y "$f" 2>/dev/null) || continue
            (( t > newest_t )) && newest_t=$t && newest="$f"
        done
        latest="$newest"
    fi
    if [[ -z "$latest" ]]
    then
        __tac_info "Available Snapshots" "[NONE FOUND]" "$C_Error"
        return 1
    fi

    printf '%s\n' "${C_Warning}WARNING: This will DESTROY the current workspace and agents.${C_Reset}"
    printf '%s\n' "${C_Dim}Restoring from: $(basename "$latest")${C_Reset}"
    read -r -p "${C_Warning}Continue? [y/N]: ${C_Reset}" confirm
    if [[ "${confirm,,}" != "y" ]]
    then
        __tac_info "Restore" "[CANCELLED]" "$C_Dim"; return 0
    fi

    # Stop gateway inline (avoid calling xo which prints its own UI)
    openclaw gateway stop >/dev/null 2>&1
    # pkill -x matches only the exact process name (not substrings)
    pkill -u "$USER" -x openclaw 2>/dev/null

    __tac_info "Purging active configurations..." "[WORKING]" "$C_Dim"

    # Extract to a temp directory first, validate, then swap — protects
    # against corrupt ZIPs destroying current state with nothing to replace it.
    local tmp_restore
    tmp_restore=$(mktemp -d "${OC_BACKUPS}/restore_XXXXXX")
    __tac_info "Extracting to staging area..." "[WORKING]" "$C_Dim"
    if ! unzip -q "$latest" -d "$tmp_restore"
    then
        __tac_info "State Rollback" "[FAILED — ZIP ERROR, current state preserved]" "$C_Error"
        rm -rf "$tmp_restore"
        return 1
    fi

    # Validate that the extracted archive has at least one known restorable asset
    if [[ ! -d "$tmp_restore/.openclaw/workspace" && ! -d "$tmp_restore/.openclaw/agents" \
       && ! -f "$tmp_restore/.openclaw/openclaw.json" && ! -f "$tmp_restore/.bashrc" \
       && ! -f "$tmp_restore/.llm/models.conf" ]]
    then
        __tac_info "State Rollback" "[FAILED — ZIP has no recognisable content]" "$C_Error"
        rm -rf "$tmp_restore"
        return 1
    fi

    # Security: reject extracted files with setuid/setgid/world-writable bits.
    # A crafted ZIP could plant executables with elevated permissions.
    if find "$tmp_restore" \( -perm /4000 -o -perm /2000 -o -perm /0002 \) -print -quit 2>/dev/null | grep -q .
    then
        __tac_info "State Rollback" "[FAILED — ZIP contains unsafe file permissions]" "$C_Error"
        rm -rf "$tmp_restore"
        return 1
    fi

    # Only destroy directories that the backup will replace — a config-only
    # restore must NOT wipe workspace/agents if it has no replacements.
    # Atomic swap: rename current → .bak, move new into place, then remove .bak.
    # If the move fails, the .bak can be manually restored (no total-loss window).
    if [[ -d "$tmp_restore/.openclaw/workspace" ]]
    then
        [[ -d "$OC_WORKSPACE" ]] && mv "$OC_WORKSPACE" "${OC_WORKSPACE}.bak"
        mv "$tmp_restore/.openclaw/workspace" "$OC_WORKSPACE"
        rm -rf "${OC_WORKSPACE}.bak"
    fi
    if [[ -d "$tmp_restore/.openclaw/agents" ]]
    then
        [[ -d "$OC_AGENTS" ]] && mv "$OC_AGENTS" "${OC_AGENTS}.bak"
        mv "$tmp_restore/.openclaw/agents" "$OC_AGENTS"
        rm -rf "${OC_AGENTS}.bak"
    fi
    # Restore config files if they were backed up
    [[ -f "$tmp_restore/.openclaw/openclaw.json" ]] \
        && mv "$tmp_restore/.openclaw/openclaw.json" "$OC_ROOT/openclaw.json"
    [[ -f "$tmp_restore/.openclaw/auth.json" ]] \
        && mv "$tmp_restore/.openclaw/auth.json" "$OC_ROOT/auth.json"
    [[ -f "$tmp_restore/.llm/models.conf" ]] \
        && mv "$tmp_restore/.llm/models.conf" "$LLM_REGISTRY"
    # Restore shell profile and standalone scripts if present
    [[ -f "$tmp_restore/.bashrc" ]] && cp "$tmp_restore/.bashrc" "$HOME/.bashrc"
    if [[ -f "$tmp_restore/ubuntu-console/tactical-console.bashrc" ]]
    then
        mkdir -p "$HOME/ubuntu-console"
        cp "$tmp_restore/ubuntu-console/tactical-console.bashrc" "$HOME/ubuntu-console/tactical-console.bashrc"
    fi
    local _rs
    for _rs in .local/bin/llama-watchdog.sh .local/bin/tac_hostmetrics.sh
    do
        if [[ -f "$tmp_restore/$_rs" ]]
        then
            mkdir -p "$(dirname "$HOME/$_rs")"
            cp "$tmp_restore/$_rs" "$HOME/$_rs"
            chmod +x "$HOME/$_rs"
        fi
    done
    # Restore systemd units if present
    for _rs in .config/systemd/user/llama-watchdog.service \
               .config/systemd/user/llama-watchdog.timer
    do
        if [[ -f "$tmp_restore/$_rs" ]]
        then
            mkdir -p "$(dirname "$HOME/$_rs")"
            cp "$tmp_restore/$_rs" "$HOME/$_rs"
        fi
    done
    rm -rf "$tmp_restore"

    __tac_info "State Rollback" "[COMPLETE]" "$C_Success"
    printf '%s\n' "${C_Dim}Tip: run 'so' to restart the gateway.${C_Reset}"
}

# ---------------------------------------------------------------------------
# owk — cd to OpenClaw workspace directory.
# ---------------------------------------------------------------------------
function owk() {
    cd "$OC_WORKSPACE" 2>/dev/null || { __tac_info "Workspace" "[NOT FOUND]" "$C_Error"; return 1; }
}

# ---------------------------------------------------------------------------
# ologs — cd to OpenClaw logs directory.
# ---------------------------------------------------------------------------
function ologs() {
    cd "$OC_LOGS" 2>/dev/null || { __tac_info "Logs" "[NOT FOUND]" "$C_Error"; return 1; }
}

# ---------------------------------------------------------------------------
# ocroot — cd to OpenClaw root directory.
# ---------------------------------------------------------------------------
function ocroot() {
    cd "$OC_ROOT" 2>/dev/null || { __tac_info "Root" "[NOT FOUND]" "$C_Error"; return 1; }
}

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
    if ! command -v openclaw >/dev/null
    then
        __tac_info "OpenClaw CLI" "[NOT INSTALLED]" "$C_Error"
        return 1
    fi
    __tac_info "Checking for updates..." "[WORKING]" "$C_Dim"
    local out
    out=$(openclaw update 2>&1)
    local rc=$?
    if (( rc == 0 ))
    then
        __tac_info "Update" "[COMPLETE]" "$C_Success"
        [[ -n "$out" ]] && printf '%s\n' "${C_Dim}${out}${C_Reset}"
    else
        __tac_info "Update" "[FAILED - rc=$rc]" "$C_Error"
        [[ -n "$out" ]] && printf '%s\n' "${C_Dim}${out}${C_Reset}"
    fi
}

# ---------------------------------------------------------------------------
# oc-health — Deep gateway health probe via the OpenClaw CLI.
# Uses jq for JSON parsing instead of Python.
# ---------------------------------------------------------------------------
function oc-health() {
    if ! command -v openclaw >/dev/null
    then
        __tac_info "OpenClaw CLI" "[NOT INSTALLED]" "$C_Error"
        return 1
    fi
    if __test_port "$OC_PORT"
    then
        __tac_info "Gateway Port $OC_PORT" "[LISTENING]" "$C_Success"
    else
        __tac_info "Gateway Port $OC_PORT" "[NOT LISTENING]" "$C_Error"
        return 1
    fi
    local health_out
    health_out=$(openclaw health --json 2>/dev/null)
    if [[ -n "$health_out" ]]
    then
        local hstatus
        hstatus=$(jq -r '.status // "unknown"' <<< "$health_out" 2>/dev/null)
        [[ -z "$hstatus" ]] && hstatus="parse_error"
        local health_color=$C_Warning
        if [[ $hstatus == "ok" || $hstatus == "healthy" ]]
        then
            health_color=$C_Success
        fi
        __tac_info "Health Status" "[${hstatus^^}]" "$health_color"
    else
        __tac_info "Health Probe" "[NO RESPONSE]" "$C_Warning"
    fi
}

# ---------------------------------------------------------------------------
# oc-cron — OpenClaw scheduler management (list / add / runs).
# ---------------------------------------------------------------------------
function oc-cron() {
    local action="${1:-list}"
    (( $# > 0 )) && shift
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
    if command -v clawhub >/dev/null 2>&1
    then
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
    (( $# > 0 )) && shift
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
    if [[ -z "$*" ]]
    then
        printf '%s\n' "${C_Dim}Usage:${C_Reset} oc-config get <key> | set <key> <value> | unset <key>"
        return 1
    fi
    openclaw config "$@"
}

# ---------------------------------------------------------------------------
# oc-docs — Search the OpenClaw documentation from the terminal.
# ---------------------------------------------------------------------------
function oc-docs() {
    if [[ -z "$*" ]]
    then
        printf '%s\n' "${C_Dim}Usage:${C_Reset} oc-docs <search query>"
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
    if [[ -z "$*" ]]
    then
        printf '%s\n' "${C_Dim}Usage:${C_Reset} oc-memory-search <query>"
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
    if ! __test_port "$LLM_PORT"
    then
        __tac_info "Local LLM" "[OFFLINE - Start a model first]" "$C_Error"
        return 1
    fi
    # Read the active model's name and GGUF filename from the registry
    local model_name="local" model_file=""
    if [[ -f "$ACTIVE_LLM_FILE" ]]
    then
        local _anum
        _anum=$(< "$ACTIVE_LLM_FILE")
        if [[ -n "$_anum" && -f "$LLM_REGISTRY" ]]
        then
            local _entry
            _entry=$(awk -F'|' -v n="$_anum" '$1 == n' "$LLM_REGISTRY" 2>/dev/null)
            IFS='|' read -r _ _name _file _ <<< "$_entry"
            [[ -n "$_name" ]] && model_name="$_name"
            [[ -n "$_file" ]] && model_file="$_file"
        fi
    fi

    # Update the local-llama provider in models.providers (the correct config path).
    # Build the provider JSON with jq and write it in a single config set call.
    local provider_json
    provider_json=$(jq -n \
        --arg url "http://127.0.0.1:${LLM_PORT}/v1" \
        --arg id "${model_file:-local}" \
        --arg name "${model_name} (Local RTX 3050 Ti)" \
        '{
            baseUrl: $url,
            api: "openai-completions",
            models: [{
                id: $id,
                name: $name,
                api: "openai-completions",
                reasoning: false,
                input: ["text"],
                cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }
            }]
        }')
    openclaw config set models.providers.local-llama "$provider_json" 2>/dev/null

    openclaw gateway restart 2>/dev/null
    # Verify the gateway actually came back up after reconfiguration
    sleep 2
    if __test_port "$OC_PORT"
    then
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
    (( $# > 0 )) && shift
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
    (( $# > 0 )) && shift
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
    (( $# > 0 )) && shift
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
function oc-env() {
    __tac_header "ENVIRONMENT VARIABLES" "open"
    __tac_line "OC_ROOT" "[$OC_ROOT]" "$C_Highlight"
    __tac_line "OPENCLAW_ROOT" "[$OPENCLAW_ROOT] (deprecated → OC_ROOT)" "$C_Dim"
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
function oc-cache-clear() {
    local count=0
    local _had_nullglob=0; shopt -q nullglob && _had_nullglob=1
    shopt -s nullglob
    for f in "$TAC_CACHE_DIR"/tac_*
    do
        [[ -f "$f" ]] && rm -f "$f" && ((count++))
    done
    (( _had_nullglob )) || shopt -u nullglob
    __tac_info "Telemetry Cache" "[$count file(s) cleared]" "$C_Success"
}

# ---------------------------------------------------------------------------
# oc-trust-sync — Record current oc-llm-sync.sh hash as trusted.
# ---------------------------------------------------------------------------
function oc-trust-sync() {
    local src="$OC_WORKSPACE/oc-llm-sync.sh"
    if [[ ! -f "$src" ]]
    then
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
function oc-diag() {
    __tac_header "OpenClaw Diagnostic Report" "open"
    echo ""

    printf '%s\n' "${C_Highlight}[1/5] openclaw doctor${C_Reset}"
    openclaw doctor 2>&1 | head -n 30
    echo ""

    printf '%s\n' "${C_Highlight}[2/5] Gateway Status${C_Reset}"
    if curl -sf --max-time 5 "http://127.0.0.1:${OC_PORT:-18789}/api/health" -o /dev/null 2>/dev/null
    then
        printf '%s\n' "  ${C_Success}● Gateway reachable on port ${OC_PORT:-18789}${C_Reset}"
    else
        printf '%s\n' "  ${C_Error}● Gateway NOT reachable on port ${OC_PORT:-18789}${C_Reset}"
    fi
    echo ""

    printf '%s\n' "${C_Highlight}[3/5] Model Provider Status${C_Reset}"
    ocms 2>&1 | head -n 20
    echo ""

    printf '%s\n' "${C_Highlight}[4/5] Environment Variables${C_Reset}"
    oc-env 2>&1
    echo ""

    printf '%s\n' "${C_Highlight}[5/5] Recent Logs (last 15 lines)${C_Reset}"
    if [[ -f "$OC_TMP_LOG" ]]
    then
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
function oc-failover() {
    local action="${1:-status}"
    case "$action" in
        on)
            if [[ -z "${OPENAI_API_KEY:-}" && -z "${ANTHROPIC_API_KEY:-}" ]]
            then
                __tac_info "Failover" "[No cloud API key found — set OPENAI_API_KEY or ANTHROPIC_API_KEY]" "$C_Error"
                return 1
            fi
            # Verify the fallback model list is configured before enabling
            local fb_models
            fb_models=$(openclaw config get llm.fallback.models 2>/dev/null)
            if [[ -z "$fb_models" || "$fb_models" == "null" ]]
            then
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
            local val
            val=$(openclaw config get llm.fallback.enabled 2>/dev/null || echo "unknown")
            __tac_info "Failover" "[llm.fallback.enabled = $val]" "$C_Info"
            # Show the actual fallback chain so the user knows what will activate
            local chain
            chain=$(openclaw config get llm.fallback.models 2>/dev/null)
            if [[ -n "$chain" && "$chain" != "null" ]]
            then
                __tac_info "Chain" "$chain" "$C_Dim"
            else
                __tac_info "Chain" "[No fallback models configured]" "$C_Warning"
            fi
            ;;
        *)
            printf '%s\n' "${C_Dim}Usage:${C_Reset} oc-failover [on|off|status]"
            ;;
    esac
}


# end of file
