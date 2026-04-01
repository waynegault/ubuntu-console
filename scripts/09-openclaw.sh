# shellcheck shell=bash
# shellcheck disable=SC1090,SC1091,SC2015,SC2016,SC2034,SC2059,SC2086,SC2154,SC2317
# ─── Module: 09-openclaw ───────────────────────────────────────────────────────
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# TACTICAL_PROFILE_VERSION auto-computes from the sum of all module versions.
# Module Version: 13
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
#   oc-browser, oc-nodes, oc-sandbox, oc-env, oc-cache-clear,
#   oc-diag, oc-doctor-local, oc-failover, wacli, oc-kgraph, __is_openclaw_installed

# ==============================================================================
# OPENCLAW INSTALLATION CHECK (Evaluated once at profile load time)
# ==============================================================================
# __TAC_OPENCLAW_OK is set to 1 only if openclaw CLI exists AND responds to --version.
# This functional check is performed once when this module loads.
# All code should check __TAC_OPENCLAW_OK instead of running `command -v openclaw`.
if command -v openclaw >/dev/null 2>&1 && openclaw --version >/dev/null 2>&1; then
    __TAC_OPENCLAW_OK=1
else
    __TAC_OPENCLAW_OK=0
fi

# ---------------------------------------------------------------------------
# __is_openclaw_installed — Check if OpenClaw CLI is installed AND functional.
# Returns 0 if __TAC_OPENCLAW_OK is set (openclaw responded to --version), 1 otherwise.
# This uses the cached result from profile load time for efficiency.
# ---------------------------------------------------------------------------
function __is_openclaw_installed() {
    [[ "$__TAC_OPENCLAW_OK" == "1" ]]
}

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
# __so_check_healthy — Check if gateway is already running and healthy.
# Returns 0 if healthy (nothing to do), 1 if needs startup.
# ---------------------------------------------------------------------------
function __so_check_healthy() {
    if __test_port "$OC_PORT"
    then
        if pgrep -x llama-server >/dev/null 2>&1 && __test_port "${LLM_PORT:-8081}"
        then
            __tac_info "Local LLM" "[RUNNING on PORT $LLM_PORT]" "$C_Success"
        else
            # Gateway is up but LLM is not — this is NOT healthy state
            __tac_info "Local LLM" "[OFFLINE — will start]" "$C_Warning"
            return 1
        fi
        __tac_info "Gateway" "[RUNNING on PORT $OC_PORT]" "$C_Success"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# __so_clear_stale_state — Clear stale systemd service state.
# Returns 0 if state was cleared, 1 if no stale state found.
# ---------------------------------------------------------------------------
function __so_clear_stale_state() {
    local _svc="$1"
    local _pre_state
    _pre_state=$(systemctl --user show -p SubState --value "$_svc" 2>/dev/null)
    if [[ "$_pre_state" == "auto-restart" || "$_pre_state" == "failed" ]]
    then
        __tac_info "Gateway" "[STALE — clearing ${_pre_state} state]" "$C_Warning"
        systemctl --user stop "$_svc" 2>/dev/null
        systemctl --user reset-failed "$_svc" 2>/dev/null
        sleep 1
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# __so_free_port — Free port held by orphan process.
# Returns 0 if port freed or not held, 1 if still blocked.
# ---------------------------------------------------------------------------
function __so_free_port() {
    local _port="$1"
    local _svc="openclaw-gateway.service"
    if __test_port "$_port"
    then
        __tac_info "Gateway" "[PORT $_port HELD — freeing]" "$C_Warning"
        openclaw gateway stop >/dev/null 2>&1
        systemctl --user stop "$_svc" 2>/dev/null
        sleep 1
        if __test_port "$_port"
        then
            # Try auto-killing a Windows holder
            if __so_check_win_port "$_port"
            then
                return 1
            fi
            # Re-check after auto-kill
            if __test_port "$_port"
            then
                __tac_info "Gateway" "[PORT $_port BLOCKED]" "$C_Error"
                return 1
            fi
        fi
    fi
    return 0
}

# ---------------------------------------------------------------------------
# __so_cycle_tailscale_serve — Cycle Tailscale Serve if conflicting.
# Sets _ts_serve_active=1 if cycled (caller must restore).
# Uses global _ts_serve_active variable.
# ---------------------------------------------------------------------------
function __so_cycle_tailscale_serve() {
    local _port="$1"
    _ts_serve_active=0
    if command -v tailscale &>/dev/null
    then
        if tailscale serve status 2>/dev/null | grep -q ":$_port\b"
        then
            _ts_serve_active=1
            __tac_info "Tailscale Serve" "[CYCLING — port $_port proxy]" "$C_Dim"
            sudo -n tailscale serve off 2>/dev/null
            rm -f /tmp/openclaw-1000/gateway.*.lock 2>/dev/null
            sleep 1
        fi
    fi
}

# ---------------------------------------------------------------------------
# __so_push_api_keys — Push API keys into systemd user environment.
# SECURITY: Validates key names before using indirect expansion to prevent
# command injection. Only allows uppercase letters, digits, and underscores.
# ---------------------------------------------------------------------------
function __so_push_api_keys() {
    if [[ -f "$TAC_CACHE_DIR/tac_win_api_keys" ]]; then
        # Validate file permissions (should be 600 or 644, owned by user)
        local _file_perms
        _file_perms=$(stat -c '%a' "$TAC_CACHE_DIR/tac_win_api_keys" 2>/dev/null || echo "777")
        if [[ "$_file_perms" != "600" && "$_file_perms" != "644" ]]
        then
            __tac_info "Security" "[SKIP api keys - unsafe permissions $_file_perms]" "$C_Warning"
            return 1
        fi
        source "$TAC_CACHE_DIR/tac_win_api_keys" 2>/dev/null || {
            __tac_info "Security" "[SKIP api keys - source failed]" "$C_Warning"
            return 1
        }
    fi
    local _key
    while IFS= read -r _line
    do
        _key="${_line#export }"
        _key="${_key%%=*}"
        # SECURITY: Validate key name matches safe pattern before indirect expansion
        if [[ ! "$_key" =~ ^[A-Z_][A-Z0-9_]*$ ]]
        then
            __tac_info "Security" "[SKIP invalid key name: $_key]" "$C_Warning"
            continue
        fi
        [[ -n "$_key" && -n "${!_key:-}" ]] && systemctl --user set-environment "${_key}=${!_key}" 2>/dev/null
    done < <(grep '^export ' "$TAC_CACHE_DIR/tac_win_api_keys" 2>/dev/null)
}

# ---------------------------------------------------------------------------
# __so_ensure_llm_running — Ensure local LLM is running.
# Starts default model if needed, shows spinner during startup.
# Returns 0 if LLM is running and healthy, 1 on failure.
# ---------------------------------------------------------------------------
function __so_ensure_llm_running() {
    if pgrep -x llama-server >/dev/null 2>&1 && __test_port "$LLM_PORT"
    then
        # LLM already running — show which model
        local _so_active_num=""
        [[ -f "$ACTIVE_LLM_FILE" ]] && _so_active_num=$(< "$ACTIVE_LLM_FILE")
        local _so_entry=""
        [[ -n "$_so_active_num" ]] && _so_entry=$(__llm_active_entry 2>/dev/null || true)
        if [[ -n "$_so_active_num" && -n "$_so_entry" ]]
        then
            local _so_mname
            IFS='|' read -r _ _so_mname _ <<< "$_so_entry"
            __tac_info "Local LLM" "[RUNNING on PORT $LLM_PORT] #${_so_active_num} ${_so_mname}" "$C_Success"
        else
            __tac_info "Local LLM" "[RUNNING on PORT $LLM_PORT]" "$C_Success"
        fi
        return 0
    fi

    # LLM not running — resolve default and start it
    local _so_def_file=""
    _so_def_file=$(__llm_default_file 2>/dev/null || true)

    # If no default is set, auto-select the first model from the registry
    if [[ -z "$_so_def_file" && -f "$LLM_REGISTRY" ]]
    then
        _so_def_file=$(awk -F'|' 'NR>0 && $3!="" {print $3; exit}' "$LLM_REGISTRY" 2>/dev/null)
    fi

    if [[ -z "$_so_def_file" ]]
    then
        __tac_info "Error" \
            "[Local LLM offline and no models available. Run 'model scan' to discover models.]" \
            "$C_Error"
        return 1
    fi

    # Look up human-readable model name from registry
    local _so_model_name
    local _so_def_entry=""
    _so_def_entry=$(__llm_registry_entry_by_file "$_so_def_file" 2>/dev/null || true)
    if [[ -n "$_so_def_entry" ]]
    then
        IFS='|' read -r _ _so_model_name _ <<< "$_so_def_entry"
    fi
    : "${_so_model_name:=$_so_def_file}"

    # Enable GPU persistence mode before starting the model
    wake 2>/dev/null || true

    # Start the LLM using serve in non-interactive mode
    # Redirect output to avoid interleaving with our status messages
    { TAC_NONINTERACTIVE=1 serve >/dev/null 2>&1 & } 2>/dev/null

    # Wait for llama-server process to appear (give it up to 10 seconds)
    local _wait_count=0
    while (( _wait_count < 20 ))
    do
        if pgrep -x llama-server >/dev/null 2>&1
        then
            break
        fi
        sleep 0.5
        ((_wait_count++))
    done

    if ! pgrep -x llama-server >/dev/null 2>&1
    then
        __tac_info "Local LLM" "[FAILED TO START - process exited immediately]" "$C_Error"
        return 1
    fi

    local _spin_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local _sw=0 _sw_max=90

    while (( _sw < _sw_max ))
    do
        printf '\r  %s' "${C_Dim}${_spin_chars:_sw%10:1} Starting ${_so_model_name} (${_sw}s)${C_Reset}  "
        if __llm_is_healthy
        then
            break
        fi
        if ! pgrep -x llama-server >/dev/null 2>&1
        then
            break
        fi
        sleep 1
        ((_sw++))
    done
    printf '\r%s\r' "$(printf '%*s' 60 '')"

    # Verify LLM is healthy
    if __llm_is_healthy
    then
        __tac_info "Local LLM" "[ONLINE on PORT $LLM_PORT] ${_so_model_name} (${_sw}s)" "$C_Success"
        return 0
    fi

    __tac_info "Local LLM" "[FAILED TO START — check: tail $LLM_LOG_FILE]" "$C_Error"
    return 1
}

# ---------------------------------------------------------------------------
# __so_start_gateway — Start gateway and wait for ready state.
# Returns 0 if gateway is ready, 1 on failure.
# ---------------------------------------------------------------------------
function __so_start_gateway() {
    local _svc="$1"
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

        printf '\r%s' "  ${C_Dim}${_spin_chars:elapsed%10:1} Starting gateway (${elapsed}s)${C_Reset}  "

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

        if (( elapsed == 15 && !ready ))
        then
            systemctl --user is-active --quiet "$_svc" 2>/dev/null && max_wait=30
        fi
    done
    printf '\r%s\r' "$(printf '%*s' 40 '')"

    # Report result
    if (( ready ))
    then
        __tac_info "Gateway" "[ONLINE] (port $OC_PORT, ${elapsed}s)" "$C_Success"
        return 0
    elif systemctl --user is-active --quiet "$_svc" 2>/dev/null
    then
        __tac_info "Gateway" "[STARTING — port not ready]" "$C_Warning"
        printf '%s\n' "  ${C_Dim}Service active after ${elapsed}s but port $OC_PORT not responding.${C_Reset}"
        printf '%s\n' "  ${C_Dim}Retry in a moment or run 'le' for logs.${C_Reset}"
        return 0
    else
        __tac_info "Gateway" "[FAILED]" "$C_Error"
        __so_show_errors "$_svc"
        printf '%s\n' "  ${C_Dim}Run 'xo' then 'so' to retry, or 'le' for logs.${C_Reset}"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# so — Start the OpenClaw gateway (systemd-managed service).
# Injects bridged API keys into the systemd user session before starting.
# If gateway is already running, only starts the LLM without restarting gateway.
# ---------------------------------------------------------------------------
function so() {
    if [[ "$__TAC_OPENCLAW_OK" != "1" ]]; then
        __tac_info "OpenClaw" "[NOT INSTALLED - cannot start gateway]" "$C_Error"
        return 1
    fi
    local _svc="openclaw-gateway.service"
    local _ts_serve_active=0
    local _gateway_already_running=0

    # Check if gateway is already running
    if __test_port "$OC_PORT"
    then
        _gateway_already_running=1
        # Check if LLM is also running
        if pgrep -x llama-server >/dev/null 2>&1 && __test_port "${LLM_PORT:-8081}"
        then
            __tac_info "Local LLM" "[RUNNING on PORT $LLM_PORT]" "$C_Success"
            __tac_info "Gateway" "[RUNNING on PORT $OC_PORT]" "$C_Success"
            return 0
        fi
        # Gateway running but LLM offline — only start LLM
        __tac_info "Gateway" "[RUNNING on PORT $OC_PORT]" "$C_Success"
    else
        # Gateway is offline — full startup sequence
        # Pre-flight: clear stale state
        __so_clear_stale_state "$_svc"

        # Pre-flight: free port if held
        if ! __so_free_port "$OC_PORT"
        then
            return 1
        fi

        # Pre-flight: check Windows port conflict
        if ! __test_port "$OC_PORT" && __so_check_win_port "$OC_PORT" --block
        then
            return 1
        fi

        # Pre-flight: cycle Tailscale Serve if conflicting
        __so_cycle_tailscale_serve "$OC_PORT"

        # Push API keys to systemd environment
        __so_push_api_keys
    fi

    # Ensure LLM is running (common path for both scenarios)
    if ! __so_ensure_llm_running
    then
        return 1
    fi

    # Start gateway only if it wasn't already running
    if (( _gateway_already_running == 0 ))
    then
        if ! __so_start_gateway "$_svc"
        then
            return 1
        fi

        # Restore Tailscale Serve if we cycled it
        if (( _ts_serve_active ))
        then
            sudo -n tailscale serve --bg "http://127.0.0.1:$OC_PORT" >/dev/null 2>&1 \
                && __tac_info "Tailscale Serve" "[RESTORED]" "$C_Success"
        fi
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

    local _win_holder _win_proc_name
    _win_holder=$(timeout 5 powershell.exe -NoProfile -NonInteractive -Command "
        \$c = Get-NetTCPConnection -LocalPort $_port -State Listen -ErrorAction SilentlyContinue \
            | Select-Object -First 1
        if (\$c) {
            \$p = Get-Process -Id \$c.OwningProcess -ErrorAction SilentlyContinue
            '{0}|{1}' -f \$p.ProcessName, \$c.OwningProcess
        }
    " 2>/dev/null | tr -d '\r')

    [[ -z "$_win_holder" ]] && return 1

    # Parse process name and PID separately for validation
    _win_proc_name="${_win_holder%%|*}"
    local _pid_only="${_win_holder##*|}"

    __tac_info "Gateway" "[PORT ${_port} BLOCKED — Windows: ${_win_proc_name} (PID ${_pid_only})]" "$C_Warning"

    # Validate process name before killing — only auto-kill known/safe processes
    # Safe targets: node, python, llama-server, openclaw, code (VS Code), pwsh, powershell
    local _safe_proc=0
    case "${_win_proc_name,,}" in
        node|python|python3|llama-server|openclaw|code|pwsh|powershell|docker*)
            _safe_proc=1
            ;;
    esac

    # Auto-kill the Windows process via taskkill.exe (only if safe or user requested)
    if command -v taskkill.exe &>/dev/null
    then
        if (( _safe_proc == 0 ))
        then
            # Unknown process — warn user and require manual intervention
            __tac_info "Gateway" "[SKIP KILL — unknown process '${_win_proc_name}']" "$C_Warning"
            printf '%s\n' "  ${C_Dim}Manual kill (if safe): taskkill /PID ${_pid_only} /F${C_Reset}"
            return 0
        fi
        __tac_info "Gateway" "[KILLING Windows PID ${_pid_only}]" "$C_Warning"
        taskkill.exe /PID "$_pid_only" /F &>/dev/null
        sleep 1
        # Verify the port is now free
        local _still_held
        _still_held=$(timeout 3 powershell.exe -NoProfile -NonInteractive -Command "
            \$c = Get-NetTCPConnection -LocalPort $_port -State Listen -ErrorAction SilentlyContinue
            if (\$c) { 'yes' }
        " 2>/dev/null | tr -d '\r')
        if [[ "$_still_held" == "yes" ]]
        then
            __tac_info "Gateway" "[PORT ${_port} STILL BLOCKED]" "$C_Error"
            printf '%s\n' "  ${C_Dim}Manual fix: taskkill /PID ${_pid_only} /F (from Windows)${C_Reset}"
            return 0
        fi
        __tac_info "Gateway" "[PORT ${_port} FREED]" "$C_Success"
        return 1  # port cleared — caller should NOT abort
    fi

    # No taskkill.exe — fall back to manual instructions
    if [[ "$_block" == "--block" ]]
    then
        __tac_info "Gateway" "[PORT $OC_PORT BLOCKED — Windows]" "$C_Error"
    fi
    printf '%s\n' "  ${C_Dim}Kill it from Windows: taskkill /PID ${_pid_only} /F${C_Reset}"
    return 0
}

# ---------------------------------------------------------------------------
# xo — Stop the OpenClaw gateway.
# Uses 'openclaw gateway stop' then systemctl for clean shutdown.
# NOTE FOR AI AGENTS: xo only STOPS the gateway — it will NOT restart it.
#   To restart, use:  openclaw gateway restart   (or the alias: oc restart)
# ---------------------------------------------------------------------------
function xo() {
    if [[ "$__TAC_OPENCLAW_OK" != "1" ]]; then
        __tac_info "OpenClaw" "[NOT INSTALLED - cannot stop gateway]" "$C_Error"
        return 1
    fi
    local _svc="openclaw-gateway.service"
    local _was_running=0

    # Hint for AI agents: xo stops but does not restart.
    if [[ -n "${OPENCLAW_AGENT_ID:-}" || -n "${AGENT_MODE:-}" ]]; then
        printf '%s\n' "${C_Warning:-}⚠ xo only stops the gateway. To restart, run: openclaw gateway restart${C_Reset}"
    fi

    # Check if anything is actually running before we try to stop
    if systemctl --user is-active --quiet "$_svc" 2>/dev/null \
        || __test_port "$OC_PORT"
    then
        _was_running=1
    fi

    openclaw gateway stop >/dev/null 2>&1
    systemctl --user stop "$_svc" 2>/dev/null
    sleep 0.5
    rm -f "$OC_ROOT/supervisor.lock"

    if (( _was_running ))
    then
        __tac_info "Gateway Processes" "[TERMINATED]" "$C_Error"
    else
        __tac_info "Gateway" "[NOT RUNNING]" "$C_Dim"
    fi
}

# ---------------------------------------------------------------------------
# oc — Unified OpenClaw command dispatcher.
# Usage: oc <subcommand> [args...]
# With no arguments, prints available subcommands.
# ---------------------------------------------------------------------------
function oc() {
    local sub="${1:-}"

    # Ensure gateway token is available for CLI commands
    export OPENCLAW_TOKEN="${OPENCLAW_TOKEN:-a3ac821b07f6884d3bf40650f1530e2d}"

    # Show help if no subcommand provided
    if [[ -z "$sub" ]]
    then
        printf '%s\n' "${C_Highlight}oc — OpenClaw Command Reference${C_Reset}"
        printf '%s\n' ""
        printf '%s\n' "${C_Highlight}Gateway${C_Reset}"
        printf '  %-20s %s\n' "restart"      "Full gateway restart: stop, wait, start"
        printf '  %-20s %s\n' "gs"           "Gateway deep health probe"
        printf '  %-20s %s\n' "status"       "Show detailed status (--all)"
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
        printf '  %-20s %s\n' "doctor-local" "Validate local gateway + llama.cpp path end-to-end"
        printf '  %-20s %s\n' "failover"     "Cloud LLM fallback (on|off|status)"
        printf '  %-20s %s\n' "refresh-keys" "Re-import Windows API keys into WSL"
        # 'trust-sync' command removed
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
        printf '%s\n' ""
        printf '%s\n' "${C_Highlight}Tools${C_Reset}"
        printf '  %-20s %s\n' "g"            "Launch knowledge graph server in browser"
        return 0
    fi
    shift

    # Security: Use whitelist approach for subcommand validation
    # Only allow known subcommands matching pattern: lowercase letters, digits, hyphens
    if [[ ! "$sub" =~ ^[a-z][-a-z0-9]*$ ]]
    then
        __tac_info "SECURITY" "[INVALID SUBCOMMAND: $sub]" "$C_Error"
        return 1
    fi

    case "$sub" in
        # Gateway
        restart)       oc-restart "$@" ;;
        gs)            ocgs "$@" ;;
        status)        oc-status "$@" ;;
        stat)          oc-status "$@" ;;  # Legacy alias
        health)        oc-health "$@" ;;
        tail)          oc-tail "$@" ;;
        v)             ocv "$@" ;;
        update)        oc-update "$@" ;;
        tui)           oc-tui "$@" ;;
        # Agents & Sessions
        start)         ocstart "$@" ;;
        stop)          ocstop "$@" ;;
        agent-turn)    ocstart "$@" ;;
        agent-use)     oc-agent-use "$@" ;;
        agent-usage)   oc-agent-use "$@" ;;
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
        doctor-local)  oc-doctor-local "$@" ;;
        failover)      oc-failover "$@" ;;
        refresh-keys)  oc-refresh-keys "$@" ;;
        # trust-sync removed
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
        # Tools
        g)             oc-kgraph "$@" ;;
        *)
            printf '%s\n' "${C_Error}Unknown subcommand:${C_Reset} $sub"
            printf '%s\n' "${C_Dim}Run 'oc' with no arguments for a list of commands.${C_Reset}"
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# oc-restart — Restart the OpenClaw gateway (systemd-managed service).
# Now uses the native OpenClaw CLI restart for reliability.
# ---------------------------------------------------------------------------
function oc-restart() {
    if [[ "$__TAC_OPENCLAW_OK" != "1" ]]; then
        __tac_info "OpenClaw" "[NOT INSTALLED - cannot restart gateway]" "$C_Error"
        return 1
    fi
    openclaw gateway restart "$@"
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
# oc-agent-use — Show per-agent active session counts (simple, cached).
#
# Data flow:
#   1. Read oc_agents.json and oc_sessions.json from /dev/shm cache
#   2. If caches are stale, refresh from `openclaw agents list --json` /
#      `openclaw sessions --all-agents --json` (background for agents, sync for sessions)
#   3. Build per-agent stats via jq grouping pipeline → oc_agent_stats.tsv
#   4. Render a formatted table with token usage, cap%, and colored bars
#   5. Cache the rendered text to /dev/shm/oc_agent_use.txt (5s TTL)
# ---------------------------------------------------------------------------
function oc-agent-use() {
    local cache="/dev/shm/oc_agent_use.txt"
    local ttl=5

    # Serve cached rendering when fresh
    if [[ -f "$cache" ]] && (( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || echo 0) < ttl )); then
        cat "$cache"; return 0
    fi

    # Use async JSON caches for agents and sessions (fast, non-blocking)
    local agent_cache="$TAC_CACHE_DIR/oc_agents.json"
    local session_cache="$TAC_CACHE_DIR/oc_sessions.json"

    # Refresh agents cache when stale (3s TTL).
    # Prefer not to block rendering: refresh agents list in background when possible.
    local now mtime
    now=$(date +%s)
    if [[ -f "$agent_cache" ]]; then
        mtime=$(stat -c %Y "$agent_cache" 2>/dev/null || echo 0)
    else
        mtime=0
    fi
    if (( now - mtime > 3 )); then
        if [[ "$__TAC_OPENCLAW_OK" == "1" ]]; then
            if [[ -t 1 ]]; then
                ( openclaw agents list --json > "${agent_cache}.tmp" 2>/dev/null \
                  || openclaw agents --json > "${agent_cache}.tmp" 2>/dev/null ) \
                  && mv "${agent_cache}.tmp" "$agent_cache" 2>/dev/null || true
            else
                ( openclaw agents list --json > "${agent_cache}.tmp" 2>/dev/null \
                  || openclaw agents --json > "${agent_cache}.tmp" 2>/dev/null ) \
                  && mv "${agent_cache}.tmp" "$agent_cache" 2>/dev/null || true &
            fi
        fi
    fi

    # Refresh sessions cache when stale (5s TTL) — keep synchronous so session
    # counts remain snappy and consistent for the dashboard.
    if [[ -f "$session_cache" ]]; then
        mtime=$(stat -c %Y "$session_cache" 2>/dev/null || echo 0)
    else
        mtime=0
    fi
    if (( now - mtime > 5 )); then
        if [[ "$__TAC_OPENCLAW_OK" == "1" ]]; then
                ( openclaw sessions --all-agents --json > "${session_cache}.tmp" 2>/dev/null \
                    || openclaw sessions --json > "${session_cache}.tmp" 2>/dev/null ) \
                    && mv "${session_cache}.tmp" "$session_cache" 2>/dev/null || true
        fi
    fi

    # Read cached JSON (may be stale on first run)
    local agents_json sessions_json
    [[ -f "$agent_cache" ]] && agents_json=$(cat "$agent_cache") || agents_json=""
    [[ -f "$session_cache" ]] && sessions_json=$(cat "$session_cache") || sessions_json=""

    # Fallback to immediate CLI if no cache exists yet (first-run)
    if [[ -z "$agents_json" && "$__TAC_OPENCLAW_OK" == "1" ]]; then
        agents_json=$(openclaw agents list --json 2>/dev/null \
            || openclaw agents --json 2>/dev/null || true)
    fi
    if [[ -z "$sessions_json" && "$__TAC_OPENCLAW_OK" == "1" ]]; then
        sessions_json=$(openclaw sessions --all-agents --json 2>/dev/null \
            || openclaw sessions --json 2>/dev/null || true)
    fi

    local tmp_agents tmp_sessions
    tmp_agents=$(mktemp) || tmp_agents="/tmp/oc_agents.$$"
    tmp_sessions=$(mktemp) || tmp_sessions="/tmp/oc_sessions.$$"

    # Extract agent id -> name mapping (best-effort)
    printf '%s' "$agents_json" | jq -r '
            (if type=="array" then . elif (.agents? or .items?) then (.agents // .items) else . end)
            | map(
                { id: ( .id // .agent_id // .slug // .key // .name ),
                  name: ( .identityName // .identity_name // .name // .display_name // .id ) }
              )
            | unique_by(.id)
            | .[]? | "\(.id)\t\(.name)"' 2>/dev/null > "$tmp_agents" || true

    # Build per-agent token aggregates (input, output, total, cap).
    # Produces a TSV with one row per agent: id \t input \t output \t total \t cap.
    # Uses a small TSV cache for instant reads during rendering.
    local stats_cache="$TAC_CACHE_DIR/oc_agent_stats.tsv"
    local stats_ttl=5

    # If the aggregated stats cache is stale, recompute from sessions_json
    if [[ -f "$stats_cache" ]]; then
        mtime=$(stat -c %Y "$stats_cache" 2>/dev/null || echo 0)
    else
        mtime=0
    fi
    if (( now - mtime > stats_ttl )); then
        # Aggregate sessions_json → per-agent token sums.
        # jq pipeline: normalise agent ID field name (many JSON shapes),
        # extract token counts, group by agent, sum input/output/total
        # and take max cap (context window) per agent. Output as TSV.
        ( printf '%s' "$sessions_json" \
            | jq -r '
                def aid: .agentId // .agent_id // .agent // .agentName // .agent_name;
                (.sessions // .items // . // [])
                | (if type=="array" then . else [] end)
                | map({
                    agent: aid,
                    input: (.inputTokens // 0),
                    output: (.outputTokens // 0),
                    total: (.totalTokens // 0),
                    cap: (.contextTokens // 0)
                  })
                | group_by(.agent)
                | map({
                    id: .[0].agent,
                    input: (map(.input) | add),
                    output: (map(.output) | add),
                    total: (map(.total) | add),
                    cap: (map(.cap) | max)
                  })[]
                | "\(.id)\t\(.input)\t\(.output)\t\(.total)\t\(.cap)"' \
            > "${stats_cache}.tmp" 2>/dev/null ) \
            && mv "${stats_cache}.tmp" "$stats_cache" 2>/dev/null || true
    fi

    local tmp_stats
    tmp_stats=$(mktemp) || tmp_stats="/tmp/oc_stats.$$"
    # Read precomputed aggregated stats and flatten into tab-separated lines.
    # Avoid blocking: if stats cache is missing or stale, start recompute
    # in the background and render a fast fallback immediately.
    if [[ -f "$stats_cache" ]]; then
        # stats cache is already TSV — copy directly for fastest reads
        cat "$stats_cache" > "$tmp_stats" 2>/dev/null || true
    else
        # kick off background recompute from the authoritative session cache file
        if [[ -f "$session_cache" && -s "$session_cache" ]]; then
            if [[ -t 1 ]]; then
                ( jq -r '
                    def aid: .agentId // .agent_id // .agent // .agentName // .agent_name;
                    (.sessions // .items // . // [])
                    | (if type=="array" then . else [] end)
                    | map({ agent: aid,
                        input: (.inputTokens // 0),
                        output: (.outputTokens // 0),
                        total: (.totalTokens // 0),
                        cap: (.contextTokens // 0) })
                    | group_by(.agent)
                    | map({ id: .[0].agent,
                        input: (map(.input) | add),
                        output: (map(.output) | add),
                        total: (map(.total) | add),
                        cap: (map(.cap) | max) })[]
                    | "\(.id)\t\(.input)\t\(.output)\t\(.total)\t\(.cap)"' "$session_cache" 2>/dev/null \
                    > "${stats_cache}.tmp" && mv "${stats_cache}.tmp" "$stats_cache" 2>/dev/null )
            else
                ( jq -r '
                    def aid: .agentId // .agent_id // .agent // .agentName // .agent_name;
                    (.sessions // .items // . // [])
                    | (if type=="array" then . else [] end)
                    | map({ agent: aid,
                        input: (.inputTokens // 0),
                        output: (.outputTokens // 0),
                        total: (.totalTokens // 0),
                        cap: (.contextTokens // 0) })
                    | group_by(.agent)
                    | map({ id: .[0].agent,
                        input: (map(.input) | add),
                        output: (map(.output) | add),
                        total: (map(.total) | add),
                        cap: (map(.cap) | max) })[]
                    | "\(.id)\t\(.input)\t\(.output)\t\(.total)\t\(.cap)"' "$session_cache" 2>/dev/null \
                    > "${stats_cache}.tmp" && mv "${stats_cache}.tmp" "$stats_cache" 2>/dev/null ) &
            fi
        fi
        # fast fallback: list known agents with zeroed stats so rendering is immediate
        if [[ -f "$tmp_agents" ]]; then
            while IFS=$'\t' read -r id name; do
                [[ -z "$id" ]] && continue
                printf '%s\t0\t0\t0\t0\n' "$id" >> "$tmp_stats"
            done < "$tmp_agents"
        else
            # no agent list either; create empty tmp_stats so downstream code
            # will render the session_count header and return quickly
            : > "$tmp_stats"
        fi
    fi

    # Merge agent names (from agents list) and per-agent token stats (from
    # sessions aggregation) into associative arrays for rendering.
    declare -A amap input_sum output_sum total_sum cap_val
    if [[ -f "$tmp_agents" ]]; then
        while IFS=$'\t' read -r id name; do
            [[ -z "$id" ]] && continue
            amap["$id"]="$name"
        done < "$tmp_agents"
    fi
    local total_agents=0 total_active=0
    if [[ -f "$tmp_stats" ]]; then
        while IFS=$'\t' read -r id inp out tot cap; do
            [[ -z "$id" ]] && continue
            input_sum["$id"]=${inp:-0}
            output_sum["$id"]=${out:-0}
            total_sum["$id"]=${tot:-0}
            cap_val["$id"]=${cap:-0}
            # ensure name exists
            [[ -z "${amap[$id]:-}" ]] && amap["$id"]="$id"
            total_active=$(( total_active + ${tot:-0} ))
        done < "$tmp_stats"
    fi

    # total_agents should reflect number of registered agents (from agents list)
    if [[ -f "$tmp_agents" ]]; then
        total_agents=$(wc -l < "$tmp_agents" 2>/dev/null || echo 0)
    else
        total_agents=${#amap[@]}
    fi

    # session_count: number of active sessions (prefer .count from sessions JSON)
    local session_count
    session_count=$(printf '%s' "$sessions_json" | jq -r '.count // (.sessions|length) // 0' 2>/dev/null || echo 0)
    total_active=$((session_count))

    # If agents list existed but no sessions, ensure amap entries present
    if (( total_agents == 0 )); then
        for id in "${!amap[@]}"; do
            input_sum["$id"]=${input_sum[$id]:-0}
            output_sum["$id"]=${output_sum[$id]:-0}
            total_sum["$id"]=${total_sum[$id]:-0}
            cap_val["$id"]=${cap_val[$id]:-0}
            (( total_agents++ ))
        done
    fi

    # Helper: humanize token counts to k/m-unit strings (e.g. 1500 → "1.5k")
    _human() {
        local n=$1
        if (( n >= 1000000 )); then
            awk -v v="$n" 'BEGIN{printf "%.1fm", v/1000000}'
        elif (( n >= 1000 )); then
            awk -v v="$n" 'BEGIN{printf "%.1fk", v/1000}'
        else
            echo "$n"
        fi
    }
    _human_one() { _human "$1"; }
    _human_cap_k() {
        local n=$1
        if (( n >= 1000 )); then
            awk -v v="$n" 'BEGIN{printf "%dk", int((v+500)/1000)}'
        else
            echo "$n"
        fi
    }

    # Assemble sorted list by percent (desc)
    local lines_file
    lines_file=$(mktemp) || lines_file="/tmp/oc_lines.$$"
    for id in "${!amap[@]}"; do
        local in_s=${input_sum[$id]:-0}
        local out_s=${output_sum[$id]:-0}
        local reported_tot=${total_sum[$id]:-0}
        local cap=${cap_val[$id]:-0}
        # Compute total: prefer reported total, but if it's smaller than
        # the observed sum(input+output), use the larger value so numbers
        # reconcile (some OpenClaw shapes report context-only totals).
        local tot
        local sum_io=$(( in_s + out_s ))
        if (( reported_tot > 0 )); then
            if (( sum_io > reported_tot )); then
                tot=$sum_io
            else
                tot=$reported_tot
            fi
        else
            tot=$sum_io
        fi
        # persist computed total so downstream logic sees reconciled value
        total_sum["$id"]=$tot
        # default cap when missing
        if (( cap == 0 )); then cap=131072; fi
        # percent (rounded)
        local pct
        if (( cap > 0 )); then
            pct=$(( (tot * 100 + cap/2) / cap ))
        else
            pct=0
        fi
        printf '%d\t%s\t%s\t%s\t%s\n' "$pct" "$id" "$tot" "$cap" "$in_s" >> "$lines_file"
    done

    local outtmp="${cache}.tmp"
    {
        # Prepare labelled lines and compute max label width for alignment
        local labels_tmp
        labels_tmp=$(mktemp) || labels_tmp="/tmp/oc_labels.$$"
        while IFS=$'\t' read -r pct id tot cap inpt; do
            # Include agents that appear in the sessions-derived stats even if
            # their total token count is zero. Only skip agents that have no
            # session-derived entry and zero tokens.
            if [[ "${tot:-0}" -eq 0 && -z "${total_sum[$id]+set}" ]]; then
                continue
            fi
            local display label
            display=${amap[$id]:-$id}
            label="${display}"
            # store label plus the rest
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$label" "$pct" "$id" "$tot" "$cap" "$inpt" >> "$labels_tmp"
        done < <(sort -rn "$lines_file")

        # compute printable agent count and max label width
        local raw_max capw label_max printable_count
        printable_count=$(awk -F"\t" '$4 > 0 {c++} END {print (c+0)}' "$labels_tmp")
        # compute raw max label length
        raw_max=$(awk -F"\t" '{ if (length($1) > m) m=length($1) } END { print (m==""?0:m) }' "$labels_tmp")
        if [[ -n "${UIWidth:-}" && ${UIWidth} -gt 60 ]]; then
            local cap_candidate=$(( UIWidth - 48 ))
            if (( cap_candidate > 14 )); then capw=14; else capw=$cap_candidate; fi
        else
            capw=14
        fi
        label_max=$raw_max
        if (( label_max > capw )); then label_max=$capw; fi
        if (( printable_count > 0 )); then
            printf 'ACTIVE AGENT CONTEXT USE (%d/%d active)\n\n' "$total_active" "$total_agents"
        fi
        # Print formatted lines with aligned labels (skip agents with zero total)
        while IFS=$'\t' read -r label pct id tot cap inpt; do
            # hide agents that have zero total tokens
            if [[ -z "${tot:-}" || ${tot:-0} -eq 0 ]]; then
                continue
            fi
            local label_display tot_h in_h out_h cap_h color in_col out_col
            # Build base label (without trailing colon), truncate to label_max
            local label_base
            label_base="$label"
            if (( ${#label_base} > label_max )); then
                label_base="${label_base:0:$((label_max-3))}..."
            fi
            # We'll print the name padded to label_max, then a single ': ' separator
            label_display="$label_base"
            tot_h=$(_human_one "$tot")
            in_h=$(_human_one "$inpt")
            out_h=$(_human_one "${output_sum[$id]:-0}")
            cap_h=$(_human_cap_k "$cap")
            # Do not embed colour codes in the cache; render plain percent
            # and let the dashboard apply colouring when displaying.
            in_col="${in_h}"
            out_col="${out_h}"
            local pct_display
            pct_display="${pct}%"
            printf "  %s: %s (%s of %s) \u2B06 %s \u2B07 %s\n" \
                "$label_display" "$pct_display" "$tot_h" "$cap_h" "$in_col" "$out_col"
        done < "$labels_tmp"
        rm -f "$labels_tmp"
    } > "$outtmp"

    mv "$outtmp" "$cache" 2>/dev/null || cp "$outtmp" "$cache" 2>/dev/null
    cat "$cache"
    rm -f "$tmp_agents" "$tmp_stats" "$lines_file" 2>/dev/null || true
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
        Where-Object { $_.Key -match "(?i)API_KEY|TOKEN|PASSWORD" } |
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
        [[ -z "$name" || ! "$name" =~ ^[a-zA-Z0-9_]+$ ]] && continue
        [[ -z "$val" ]] && continue
        # Reject values with embedded newlines (could inject extra commands)
        [[ "$val" == *$'\n'* ]] && continue
        printf 'export %s=%q\n' "$name" "$val" >> "$tmpfile"
    done <<< "$raw"
    mv "$tmpfile" "$cache"
    chmod 600 "$cache"
    source "$cache" 2>/dev/null
}

# (oc-sync-keys-to-bridge removed; behavior merged into oc-refresh-keys)

# ---------------------------------------------------------------------------
# oc-refresh-keys — Force re-import of Windows API keys into WSL and persist to systemd env
# ---------------------------------------------------------------------------
function oc-refresh-keys() {
    rm -f "$TAC_CACHE_DIR/tac_win_api_keys"
    __bridge_windows_api_keys
    if [[ -f "$TAC_CACHE_DIR/tac_win_api_keys" ]]
    then
        local cache="$TAC_CACHE_DIR/tac_win_api_keys"
        local envd_dir="$HOME/.config/environment.d"
        local envd_file="$envd_dir/90-openclaw.conf"
        mkdir -p "$envd_dir"

        # Extract exported lines and strip leading 'export '
        awk '/^export / { sub(/^export /, ""); print }' "$cache" > "$envd_file.tmp" 2>/dev/null || true
        mv "$envd_file.tmp" "$envd_file" 2>/dev/null || true
        chmod 600 "$envd_file" 2>/dev/null || true
        __tac_info "Env Bridge" "[SYNCED → $(basename \"$envd_file\")]" "$C_Success"

        # Reload user manager and import variables into the running session
        systemctl --user daemon-reload 2>/dev/null || true
        while IFS= read -r _line; do
            [[ -z "$_line" ]] && continue
            _name="${_line%%=*}"
            _val="${_line#*=}"
            if [[ "$_val" == \"*\" && "$_val" == *\" ]]; then
                _val="${_val:1:-1}"
            fi
            systemctl --user set-environment "${_name}=${_val}" 2>/dev/null || true
        done < "$envd_file"

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

        # Verify backup integrity
        __tac_info "Verifying backup..." "[CHECKSUM]" "$C_Dim"
        if unzip -tq "$zipPath" >/dev/null 2>&1
        then
            __tac_info "Backup Integrity" "[VERIFIED — ${human_sz}KB]" "$C_Success"
        else
            __tac_info "Backup Integrity" "[CORRUPTED — DELETE AND RETRY]" "$C_Error"
            rm -f "$zipPath"
            return 1
        fi

        # Test restore structure (dry-run listing)
        if unzip -l "$zipPath" | grep -q "workspace/"
        then
            __tac_info "Restore Test" "[STRUCTURE VALID]" "$C_Success"
        fi

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
    local dry_run=0
    case "${1:-}" in
        --dry-run|-n) dry_run=1 ;;
    esac

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

    if (( ! dry_run ))
    then
        printf '%s\n' "${C_Warning}WARNING: This will DESTROY the current workspace and agents.${C_Reset}"
        printf '%s\n' "${C_Dim}Restoring from: $(basename "$latest")${C_Reset}"
        read -r -p "${C_Warning}Continue? [y/N]: ${C_Reset}" confirm
        if [[ "${confirm,,}" != "y" ]]
        then
            __tac_info "Restore" "[CANCELLED]" "$C_Dim"; return 0
        fi
    fi

    if (( ! dry_run ))
    then
        # Stop gateway inline (avoid calling xo which prints its own UI)
        openclaw gateway stop >/dev/null 2>&1
        # pkill -x matches only the exact process name (not substrings)
        pkill -u "$USER" -x openclaw 2>/dev/null

        __tac_info "Purging active configurations..." "[WORKING]" "$C_Dim"
    fi

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

    if (( dry_run ))
    then
        __tac_info "Restore" "[DRY RUN]" "$C_Warning"
        __tac_info "Snapshot" "$(basename "$latest")" "$C_Dim"
        [[ -d "$tmp_restore/.openclaw/workspace" ]] && __tac_info "Would Restore" "$OC_WORKSPACE" "$C_Dim"
        [[ -d "$tmp_restore/.openclaw/agents" ]] && __tac_info "Would Restore" "$OC_AGENTS" "$C_Dim"
        [[ -f "$tmp_restore/.openclaw/openclaw.json" ]] && __tac_info "Would Restore" "$OC_ROOT/openclaw.json" "$C_Dim"
        [[ -f "$tmp_restore/.openclaw/auth.json" ]] && __tac_info "Would Restore" "$OC_ROOT/auth.json" "$C_Dim"
        [[ -f "$tmp_restore/.llm/models.conf" ]] && __tac_info "Would Restore" "$LLM_REGISTRY" "$C_Dim"
        [[ -f "$tmp_restore/.bashrc" ]] && __tac_info "Would Restore" "$HOME/.bashrc" "$C_Dim"
        rm -rf "$tmp_restore"
        return 0
    fi

    # Only destroy directories that the backup will replace — a config-only
    # restore must NOT wipe workspace/agents if it has no replacements.
    # Atomic swap: rename current → .bak, move new into place, then remove .bak.
    # If the move fails, the .bak can be manually restored (no total-loss window).
    mkdir -p "$OC_ROOT" "$(dirname "$LLM_REGISTRY")"
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
        mkdir -p "$TACTICAL_REPO_ROOT"
        cp "$tmp_restore/ubuntu-console/tactical-console.bashrc" "$TACTICAL_REPO_ROOT/tactical-console.bashrc"
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
    local restored_systemd_units=0
    for _rs in .config/systemd/user/llama-watchdog.service \
               .config/systemd/user/llama-watchdog.timer
    do
        if [[ -f "$tmp_restore/$_rs" ]]
        then
            mkdir -p "$(dirname "$HOME/$_rs")"
            cp "$tmp_restore/$_rs" "$HOME/$_rs"
            restored_systemd_units=1
        fi
    done
    if (( restored_systemd_units )) && command -v systemctl >/dev/null 2>&1
    then
        systemctl --user daemon-reload >/dev/null 2>&1 || true
    fi
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
    if [[ "$__TAC_OPENCLAW_OK" != "1" ]]; then
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
    local output_mode="human"
    case "${1:-}" in
        --json) output_mode="json" ;;
        --plain) output_mode="plain" ;;
    esac

    local cli_installed=1
    local port_listening=0
    local health_status="unknown"

    if [[ "$__TAC_OPENCLAW_OK" != "1" ]]
    then
        cli_installed=0
        if [[ "$output_mode" == "json" ]]
        then
            printf '{"cli_installed":false,"port":%s,"port_listening":false,"health_status":"missing_cli"}\n' \
                "$OC_PORT"
            return 1
        fi
        if [[ "$output_mode" == "plain" ]]
        then
            printf '%s\n' "cli_installed=0"
            printf '%s\n' "port=$OC_PORT"
            printf '%s\n' "port_listening=0"
            printf '%s\n' "health_status=missing_cli"
            return 1
        fi
        __tac_info "OpenClaw CLI" "[NOT INSTALLED]" "$C_Error"
        return 1
    fi
    if __test_port "$OC_PORT"
    then
        port_listening=1
    else
        if [[ "$output_mode" == "json" ]]
        then
            printf '{"cli_installed":true,"port":%s,"port_listening":false,"health_status":"port_closed"}\n' \
                "$OC_PORT"
            return 1
        fi
        if [[ "$output_mode" == "plain" ]]
        then
            printf '%s\n' "cli_installed=1"
            printf '%s\n' "port=$OC_PORT"
            printf '%s\n' "port_listening=0"
            printf '%s\n' "health_status=port_closed"
            return 1
        fi
        __tac_info "Gateway Port $OC_PORT" "[NOT LISTENING]" "$C_Error"
        return 1
    fi
    # Use direct curl to /health endpoint (doesn't require auth)
    local health_out
    health_out=$(curl -sf --max-time 3 "http://127.0.0.1:${OC_PORT}/health" 2>/dev/null)
    if [[ -n "$health_out" ]]
    then
        local ok_val
        ok_val=$(jq -r '.ok // false' <<< "$health_out" 2>/dev/null)
        if [[ "$ok_val" == "true" ]]
        then
            health_status="ok"
        else
            local status_val
            status_val=$(jq -r '.status // "unknown"' <<< "$health_out" 2>/dev/null)
            [[ -z "$status_val" || "$status_val" == "null" ]] && status_val="unknown"
            health_status="$status_val"
        fi
    else
        health_status="no_response"
    fi

    if [[ "$output_mode" == "json" ]]
    then
        printf '{'
        printf '"cli_installed":%s,' "$([[ $cli_installed -eq 1 ]] && echo true || echo false)"
        printf '"port":%s,' "$OC_PORT"
        printf '"port_listening":%s,' "$([[ $port_listening -eq 1 ]] && echo true || echo false)"
        printf '"health_status":"%s"' "$(__llm_json_escape "$health_status")"
        printf '}\n'
        [[ "$health_status" == "ok" || "$health_status" == "healthy" ]]
        return
    fi

    if [[ "$output_mode" == "plain" ]]
    then
        printf '%s\n' "cli_installed=$cli_installed"
        printf '%s\n' "port=$OC_PORT"
        printf '%s\n' "port_listening=$port_listening"
        printf '%s\n' "health_status=$health_status"
        [[ "$health_status" == "ok" || "$health_status" == "healthy" ]]
        return
    fi

    __tac_info "Gateway Port $OC_PORT" "[LISTENING]" "$C_Success"
    local health_color=$C_Warning
    if [[ $health_status == "ok" || $health_status == "healthy" ]]
    then
        health_color=$C_Success
    fi
    if [[ "$health_status" == "no_response" ]]
    then
        __tac_info "Health Probe" "[NO RESPONSE]" "$C_Warning"
    else
        __tac_info "Health Status" "[${health_status^^}]" "$health_color"
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
        update)  oc-plugin-update "$2" ;;
        *)       echo "Usage: oc-plugins {list|doctor|enable|disable|update} [id]" ;;
    esac
}

# ---------------------------------------------------------------------------
# oc-plugin-update — Update OpenClaw plugins from upstream git repos.
# Usage: oc-plugin-update [plugin-id|--all]
# Updates gigabrain, lossless-claw, and OpenStinger from their GitHub repos.
# ---------------------------------------------------------------------------
function oc-plugin-update() {
    local plugin_id="${1:---all}"
    local plugins_dir="$HOME/.openclaw/extensions"
    local vendor_dir="$HOME/.openclaw/vendor"
    local updated=0

    __tac_header "OPENCLAW PLUGIN UPDATE" "open"

    update_plugin() {
        local id="$1" repo_url="$2" target_dir="$3"
        local plugin_dir="$target_dir/$id"

        if [[ ! -d "$plugin_dir" ]]
        then
            # Not installed — clone fresh
            __tac_info "$id" "[INSTALLING from $repo_url]" "$C_Success"
            if git clone --depth 1 "$repo_url" "$plugin_dir" 2>&1
            then
                __tac_line "$id" "[INSTALLED]" "$C_Success"
                return 0
            else
                __tac_line "$id" "[INSTALL FAILED]" "$C_Error"
                return 1
            fi
        elif [[ -d "$plugin_dir/.git" ]]
        then
            # Git repo — pull updates
            local current_remote
            current_remote=$(git -C "$plugin_dir" remote get-url origin 2>/dev/null || echo "")
            if [[ "$current_remote" == *"$repo_url"* ]]
            then
                if git -C "$plugin_dir" pull --ff-only >/dev/null 2>&1
                then
                    __tac_line "$id" "[UPDATED]" "$C_Success"
                    return 0
                else
                    __tac_line "$id" "[UP TO DATE]" "$C_Dim"
                    return 0
                fi
            else
                __tac_line "$id" "[SKIP - different remote]" "$C_Warning"
                __tac_info "  Current" "$current_remote" "$C_Dim"
                __tac_info "  Expected" "$repo_url" "$C_Dim"
                return 1
            fi
        else
            # Not a git repo — offer to reinstall
            __tac_line "$id" "[REINSTALL REQUIRED]" "$C_Warning"
            __tac_info "  Reason" "Not a git repository" "$C_Dim"
            __tac_info "  Action" "Run: rm -rf '$plugin_dir' && oc-plugin-update $id" "$C_Dim"
            return 1
        fi
    }

    case "$plugin_id" in
        gigabrain)
            if update_plugin "gigabrain" "https://github.com/legendaryvibecoder/gigabrain.git" "$plugins_dir"
            then
                ((updated++))
            fi
            ;;
        lossless-claw)
            if update_plugin "lossless-claw" "https://github.com/Martian-Engineering/lossless-claw.git" "$plugins_dir"
            then
                ((updated++))
            fi
            ;;
        openstinger)
            if update_plugin "openstinger" "https://github.com/srikanthbellary/openstinger.git" "$vendor_dir"
            then
                ((updated++))
            fi
            ;;
        --all|"")
            if update_plugin "gigabrain" "https://github.com/legendaryvibecoder/gigabrain.git" "$plugins_dir"
            then
                ((updated++))
            fi
            if update_plugin "lossless-claw" "https://github.com/Martian-Engineering/lossless-claw.git" "$plugins_dir"
            then
                ((updated++))
            fi
            if update_plugin "openstinger" "https://github.com/srikanthbellary/openstinger.git" "$vendor_dir"
            then
                ((updated++))
            fi
            ;;
        *)
            __tac_info "Error" "Unknown plugin: $plugin_id" "$C_Error"
            __tac_info "Usage" "oc-plugin-update [gigabrain|lossless-claw|openstinger|--all]" "$C_Dim"
            return 1
            ;;
    esac

    __tac_divider
    if (( updated > 0 ))
    then
        __tac_line "Update Status" "[$updated plugin(s) processed]" "$C_Success"
        __tac_info "Note" "Run 'openclaw plugins doctor' to verify" "$C_Dim"
    else
        __tac_line "Update Status" "[NO UPDATES]" "$C_Dim"
    fi
    __tac_footer
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
# oc-stinger — OpenStinger MCP memory server management.
# Usage: oc-stinger {start|stop|status|logs|progress|doctor|restart}
# ---------------------------------------------------------------------------
function oc-stinger() {
    local action="${1:-status}"
    local os_dir="$HOME/.openclaw/vendor/openstinger"
    local os_script="$os_dir/scripts/start.sh"
    local os_venv_python="$os_dir/.venv/bin/python"

    case "$action" in
        start)
            __tac_header "OPENSTINGER START" "open"
            # Start FalkorDB + PostgreSQL
            if docker compose -f "$os_dir/docker-compose.yml" up -d 2>&1
            then
                __tac_line "Containers" "[STARTED]" "$C_Success"
            else
                __tac_line "Containers" "[FAILED]" "$C_Error"
                return 1
            fi
            sleep 2
            # Start Gradient MCP server (Tier 3) in background
            if pgrep -f "openstinger.gradient.mcp.server" >/dev/null 2>&1
            then
                __tac_line "MCP Server" "[ALREADY RUNNING]" "$C_Dim"
            else
                cd "$os_dir" && source "$os_dir/.venv/bin/activate" && \
                    nohup "$os_venv_python" -m openstinger.gradient.mcp.server \
                    > "$os_dir/.openstinger/openstinger.log" 2>&1 &
                sleep 3
                if pgrep -f "openstinger.gradient.mcp.server" >/dev/null 2>&1
                then
                    __tac_line "MCP Server (Gradient)" "[STARTED on port 8766]" "$C_Success"
                else
                    __tac_line "MCP Server" "[FAILED - check logs]" "$C_Error"
                fi
            fi
            __tac_footer
            ;;
        stop)
            __tac_header "OPENSTINGER STOP" "open"
            # Stop MCP server
            if pkill -f "openstinger.mcp.server" 2>/dev/null || \
               pkill -f "openstinger.gradient.mcp.server" 2>/dev/null
            then
                __tac_line "MCP Server" "[STOPPED]" "$C_Success"
            else
                __tac_line "MCP Server" "[NOT RUNNING]" "$C_Dim"
            fi
            # Stop containers
            if docker compose -f "$os_dir/docker-compose.yml" down 2>&1
            then
                __tac_line "Containers" "[STOPPED]" "$C_Success"
            else
                __tac_line "Containers" "[FAILED]" "$C_Warning"
            fi
            __tac_footer
            ;;
        restart)
            oc-stinger stop
            sleep 2
            oc-stinger start
            ;;
        status)
            __tac_header "OPENSTINGER STATUS" "open"
            # Check MCP server
            if pgrep -f "openstinger.gradient.mcp.server" >/dev/null 2>&1
            then
                __tac_line "MCP Server (Gradient)" "[RUNNING]" "$C_Success"
            elif pgrep -f "openstinger.mcp.server" >/dev/null 2>&1
            then
                __tac_line "MCP Server (Tier 1)" "[RUNNING]" "$C_Success"
            else
                __tac_line "MCP Server" "[STOPPED]" "$C_Warning"
            fi
            # Check FalkorDB (container name pattern: openstinger-*falkordb*)
            if docker ps --filter "name=falkordb" --format "{{.Status}}" 2>/dev/null | grep -q "Up"
            then
                __tac_line "FalkorDB" "[RUNNING]" "$C_Success"
            else
                __tac_line "FalkorDB" "[STOPPED]" "$C_Warning"
            fi
            # Check PostgreSQL (for Gradient tier)
            if docker ps --filter "name=openstinger-postgres" --format "{{.Status}}" 2>/dev/null | grep -q "Up"
            then
                __tac_line "PostgreSQL" "[RUNNING]" "$C_Success"
            else
                __tac_line "PostgreSQL" "[NOT RUNNING]" "$C_Dim"
            fi
            # Check database
            if [[ -f "$os_dir/.openstinger/openstinger.db" ]]
            then
                local db_size
                db_size=$(du -h "$os_dir/.openstinger/openstinger.db" 2>/dev/null | cut -f1)
                __tac_line "SQLite DB" "[$db_size]" "$C_Success"
            else
                __tac_line "SQLite DB" "[NOT FOUND]" "$C_Warning"
            fi
            # Check SSE endpoint
            if curl -s --connect-timeout 2 "http://localhost:8766/sse" >/dev/null 2>&1
            then
                __tac_line "SSE Endpoint" "[READY on :8766]" "$C_Success"
            else
                __tac_line "SSE Endpoint" "[NOT REACHABLE]" "$C_Warning"
            fi
            __tac_footer
            ;;
        logs)
            tail -f "$os_dir/.openstinger/openstinger.log" 2>/dev/null || \
                echo "Log file not found: $os_dir/.openstinger/openstinger.log"
            ;;
        progress)
            if command -v openstinger-cli >/dev/null 2>&1
            then
                openstinger-cli progress
            elif [[ -f "$os_dir/.venv/bin/openstinger-cli" ]]
            then
                "$os_dir/.venv/bin/openstinger-cli" progress
            else
                __tac_info "Error" "openstinger-cli not found" "$C_Warning"
                __tac_info "Tip" "Run: cd $os_dir && pip install -e ." "$C_Dim"
            fi
            ;;
        doctor)
            if [[ -x "$os_script" ]]
            then
                "$os_script" doctor
            else
                __tac_info "Error" "Doctor script not found: $os_script" "$C_Error"
            fi
            ;;
        *)
            echo "Usage: oc-stinger {start|stop|status|logs|progress|doctor|restart}"
            return 1
            ;;
    esac
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
# Note: The period argument is accepted for compatibility but currently
#       shows all-time stats since the openclaw CLI doesn't support date filtering.
# ---------------------------------------------------------------------------
function oc-usage() {
    local session_cache="$TAC_CACHE_DIR/oc_sessions.json"

    # Refresh sessions cache if stale or missing (5s TTL)
    local now mtime
    now=$(date +%s)
    if [[ -f "$session_cache" ]]; then
        mtime=$(stat -c %Y "$session_cache" 2>/dev/null || echo 0)
    else
        mtime=0
    fi

    if (( now - mtime > 5 )); then
        if [[ "$__TAC_OPENCLAW_OK" == "1" ]]; then
            ( openclaw sessions --all-agents --json > "${session_cache}.tmp" 2>/dev/null \
                || openclaw sessions --json > "${session_cache}.tmp" 2>/dev/null ) \
                && mv "${session_cache}.tmp" "$session_cache" 2>/dev/null || true
        fi
    fi

    # Read cached JSON or fetch directly
    local sessions_json
    if [[ -f "$session_cache" ]]; then
        sessions_json=$(cat "$session_cache")
    elif [[ "$__TAC_OPENCLAW_OK" == "1" ]]; then
        sessions_json=$(openclaw sessions --all-agents --json 2>/dev/null \
            || openclaw sessions --json 2>/dev/null || true)
    fi

    if [[ -z "$sessions_json" || "$sessions_json" == "null" ]]; then
        __tac_info "Usage" "[No session data available]" "$C_Warning"
        return 0
    fi

    # Aggregate token stats from all sessions
    local stats
    stats=$(printf '%s' "$sessions_json" | jq -r '
        # Normalize input: handle array, object with .sessions, or object with .items
        (if type=="array" then .
         elif (.sessions?) then .sessions
         elif (.items?) then .items
         else . end)
        | map(. // {})
        | {
            total_input: (map(.inputTokens // 0) | add // 0),
            total_output: (map(.outputTokens // 0) | add // 0),
            total_tokens: (map(.totalTokens // 0) | add // 0),
            total_context: (map(.contextTokens // 0) | add // 0),
            session_count: length,
            total_cost: (map(.costUSD // .totalCost // 0) | add // 0)
          }
        | "Input: \(.total_input)\nOutput: \(.total_output)\nTotal: \(.total_tokens)\n"
        + "Context: \(.total_context)\nSessions: \(.session_count)\nCost: $\(.total_cost)"
    ' 2>/dev/null)

    if [[ -z "$stats" ]]; then
        __tac_info "Usage" "[No token data found in sessions]" "$C_Warning"
        return 0
    fi

    # Display formatted usage stats
    printf '%s\n' "${C_Highlight}OpenClaw Usage Statistics${C_Reset}"
    printf '%s\n' ""
    printf '%s\n' "$stats" | while IFS= read -r line; do
        printf '%s\n' "  $line"
    done
}

# ---------------------------------------------------------------------------
# oc-memory-search — Search OpenClaw's vector memory index.
# Note: The 'openclaw memory search' command was removed. Memory search is now
# performed automatically by agents during conversation. Users can view memory
# contents via the knowledge graph UI (oc g) or by inspecting the memory DB.
# ---------------------------------------------------------------------------
function oc-memory-search() {
    local query="${1:-}"

    if [[ -z "$query" ]]
    then
        printf '%s\n' "${C_Highlight}Memory Search${C_Reset}"
        printf '%s\n' ""
        printf '%s\n' "${C_Dim}Note:${C_Reset} The 'openclaw memory search' command was removed."
        printf '%s\n' "Memory indexing and search is now performed automatically by agents."
        printf '%s\n' ""
        printf '%s\n' "${C_Highlight}Alternatives:${C_Reset}"
        printf '  %-20s %s\n' "oc g" "View memory in knowledge graph UI"
        printf '  %-20s %s\n' "mem-index" "Check memory index status (no-op, auto-indexed)"
        printf '%s\n' ""
        printf '%s\n' "${C_Dim}Memory DB location:${C_Reset} ~/.openclaw/agents/*/memory/registry.sqlite"
        return 0
    fi

    # Attempt to search via kgraph.py (if search capability exists)
    local repo_root="${TACTICAL_REPO_ROOT:-$HOME/ubuntu-console}"
    if [[ -f "$repo_root/scripts/kgraph.py" ]]
    then
        local result
        result=$(python3 "$repo_root/scripts/kgraph.py" --help 2>&1 | grep -c "search" || true)
        if [[ "$result" -gt 0 ]]
        then
            python3 "$repo_root/scripts/kgraph.py" search "$query" 2>/dev/null && return 0
        fi
    fi

    # Fallback: show memory files directly
    __tac_info "memory-search" "[Query: $query]" "$C_Info"
    printf '%s\n' "${C_Dim}Memory files (most recent first):${C_Reset}"

    local found=0
    while IFS= read -r f
    do
        if [[ -f "$f" ]]
        then
            printf '  %s\n' "$f"
            ((found++))
            [[ $found -ge 5 ]] && break
        fi
    done < <(find "$OC_AGENTS" -name "registry.sqlite" -type f 2>/dev/null | head -5)

    if [[ $found -eq 0 ]]
    then
        __tac_info "memory-search" "[No memory databases found]" "$C_Warning"
    fi
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
    local _entry=""
    _entry=$(__llm_active_entry 2>/dev/null || true)
    if [[ -n "$_entry" ]]
    then
        IFS='|' read -r _ _name _file _ <<< "$_entry"
        [[ -n "$_name" ]] && model_name="$_name"
        [[ -n "$_file" ]] && model_file="$_file"
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
    # Scan all configured providers except OpenRouter (free tier has no tool support)
    # Use grep to filter out any openrouter lines as fallback
    openclaw models scan --no-probe --yes 2>&1 | grep -v "openrouter/"
    __tac_info "Model Registry" "[SYNCED WITH OPENCLAW]" "$C_Success"
}

# ocms — Alias for oc-sync-models (oc ms shorthand)
# ---------------------------------------------------------------------------
function ocms() {
    oc-sync-models "$@"
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
    local dry_run=0
    case "${1:-}" in
        --dry-run|-n) dry_run=1 ;;
    esac

    local count=0
    local _had_nullglob=0; shopt -q nullglob && _had_nullglob=1
    shopt -s nullglob
    for f in "$TAC_CACHE_DIR"/tac_*
    do
        if [[ -f "$f" ]]
        then
            if (( dry_run ))
            then
                ((count++))
            elif rm -f "$f"
            then
                ((count++))
            fi
        fi
    done
    (( _had_nullglob )) || shopt -u nullglob
    if (( dry_run ))
    then
        __tac_info "Telemetry Cache" "[$count file(s) would be cleared]" "$C_Warning"
    else
        __tac_info "Telemetry Cache" "[$count file(s) cleared]" "$C_Success"
    fi
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

    # Note: Probe session files from ocms are now cleaned up automatically in [3/5]
    # This section archives truly orphaned session files (deleted from sessions.json)

    printf '%s\n' "${C_Highlight}[1/5] openclaw doctor${C_Reset}"
    # Use --fix to avoid interactive prompts, capture output
    # Suppress startup optimization warnings (we set them in env.sh)
    openclaw doctor --fix 2>&1 | grep -v "NODE_COMPILE_CACHE\|OPENCLAW_NO_RESPAWN\|Suggested env" | head -n 35
    echo ""

    printf '%s\n' "${C_Highlight}[2/5] Gateway Status${C_Reset}"
    # Check both /health and /api/health endpoints
    local gw_healthy=0
    if curl -sf --max-time 3 "http://127.0.0.1:${OC_PORT:-18789}/health" -o /dev/null 2>/dev/null
    then
        gw_healthy=1
    elif curl -sf --max-time 3 "http://127.0.0.1:${OC_PORT:-18789}/api/health" -o /dev/null 2>/dev/null
    then
        gw_healthy=1
    fi

    if (( gw_healthy ))
    then
        printf '%s\n' "  ${C_Success}● Gateway reachable on port ${OC_PORT:-18789}${C_Reset}"
        # Show quick health status
        local hresp
        hresp=$(curl -sf --max-time 2 "http://127.0.0.1:${OC_PORT:-18789}/health" 2>/dev/null)
        if [[ -n "$hresp" ]]
        then
            local hstatus
            hstatus=$(echo "$hresp" | jq -r '.status // .ok // "unknown"' 2>/dev/null)
            [[ "$hstatus" == "true" ]] && hstatus="ok"
            printf '  %s\n' "${C_Info}  Status: ${hstatus^^}${C_Reset}"
        fi
    else
        printf '%s\n' "  ${C_Error}● Gateway NOT reachable on port ${OC_PORT:-18789}${C_Reset}"
        printf '  %s\n' "${C_Warning}  Start with: oc start${C_Reset}"
    fi
    echo ""

    printf '%s\n' "${C_Highlight}[3/5] Model Provider Status${C_Reset}"
    # Run model status check, then clean up probe files it creates
    ocms 2>&1 | grep -v "\[agent/embedded\]\|context overflow\|error=402" | head -n 25

    # Clean up probe session files created by ocms (they are temporary)
    local probe_count=0
    for f in "$OC_AGENTS/main/sessions"/probe-*.jsonl
    do
        [[ -f "$f" ]] && rm -f "$f" && ((probe_count++))
    done 2>/dev/null
    if (( probe_count > 0 ))
    then
        printf '\n  %s\n' "${C_Info}● Cleaned up $probe_count temporary probe session files${C_Reset}"
    fi
    echo ""

    printf '%s\n' "${C_Highlight}[4/5] Environment Variables${C_Reset}"
    oc-env 2>&1
    # Show optimization status
    echo ""
    printf '  %s\n' "${C_Highlight}Startup Optimizations:${C_Reset}"
    if [[ -n "$NODE_COMPILE_CACHE" ]]
    then
        printf '  %s\n' "${C_Success}  ● NODE_COMPILE_CACHE=$NODE_COMPILE_CACHE${C_Reset}"
    else
        printf '  %s\n' "${C_Warning}  ○ NODE_COMPILE_CACHE not set (slower CLI startup)${C_Reset}"
    fi
    if [[ "${OPENCLAW_NO_RESPAWN:-0}" == "1" ]]
    then
        printf '  %s\n' "${C_Success}  ● OPENCLAW_NO_RESPAWN=1${C_Reset}"
    else
        printf '  %s\n' "${C_Warning}  ○ OPENCLAW_NO_RESPAWN not set (extra startup overhead)${C_Reset}"
    fi
    echo ""

    printf '%s\n' "${C_Highlight}[5/5] Recent Logs (last 15 lines)${C_Reset}"
    # Check multiple log locations
    local log_found=0
    for logf in "$OC_TMP_LOG" "$OC_LOGS/openclaw.log" "$OC_ROOT/logs/openclaw.log" "/tmp/openclaw/openclaw.log"
    do
        if [[ -f "$logf" ]]
        then
            tail -n 15 "$logf"
            log_found=1
            break
        fi
    done
    if (( ! log_found ))
    then
        echo "  ${C_Info}(no log file found)${C_Reset}"
        echo "  Logs location: $OC_LOGS"
    fi
    echo ""
    __tac_footer
    __tac_info "Diagnostics" "[Complete]" "$C_Success"
}

# ---------------------------------------------------------------------------
# oc-doctor-local — Validate the full local OpenClaw + llama.cpp path.
# Usage: oc doctor-local [--json|--plain]
# ---------------------------------------------------------------------------
function oc-doctor-local() {
    local output_mode="human"
    case "${1:-}" in
        --json) output_mode="json" ;;
        --plain) output_mode="plain" ;;
    esac

    local openclaw_installed=1
    local gateway_port=0
    local gateway_health="unknown"
    local llm_port=0
    local llm_health=0
    local model_sync=0
    local key_cache=0
    local oc_config=0
    local active_model=""
    local issues=0

    [[ "$__TAC_OPENCLAW_OK" == "1" ]] || openclaw_installed=0
    __test_port "$OC_PORT" && gateway_port=1
    __test_port "$LLM_PORT" && llm_port=1
    __llm_is_healthy && llm_health=1
    [[ -f "$TAC_CACHE_DIR/tac_win_api_keys" ]] && key_cache=1
    [[ -f "$OC_ROOT/openclaw.json" ]] && oc_config=1

    local active_entry=""
    active_entry=$(__llm_active_entry 2>/dev/null || true)
    if [[ -n "$active_entry" ]]
    then
        IFS='|' read -r _ active_model _ <<< "$active_entry"
    fi

    if (( openclaw_installed ))
    then
        local _oc_health_json=""
        _oc_health_json=$(oc-health --json 2>/dev/null || true)
        gateway_health=$(jq -r '.health_status // "unknown"' <<< "$_oc_health_json" 2>/dev/null)
        local provider_json=""
        provider_json=$(openclaw config get models.providers.local-llama 2>/dev/null || true)
        if [[ -n "$provider_json" && "$provider_json" != "null" && "$provider_json" == *"127.0.0.1:${LLM_PORT}"* ]]
        then
            model_sync=1
        fi
    else
        gateway_health="missing_cli"
    fi

    (( openclaw_installed )) || ((issues++))
    (( gateway_port )) || ((issues++))
    [[ "$gateway_health" == "ok" || "$gateway_health" == "healthy" ]] || ((issues++))
    (( llm_port )) || ((issues++))
    (( llm_health )) || ((issues++))
    (( model_sync )) || ((issues++))
    (( key_cache )) || ((issues++))
    (( oc_config )) || ((issues++))

    if [[ "$output_mode" == "json" ]]
    then
        printf '{'
        printf '"openclaw_installed":%s,' "$([[ $openclaw_installed -eq 1 ]] && echo true || echo false)"
        printf '"gateway_port":%s,' "$([[ $gateway_port -eq 1 ]] && echo true || echo false)"
        printf '"gateway_health":"%s",' "$(__llm_json_escape "$gateway_health")"
        printf '"llm_port":%s,' "$([[ $llm_port -eq 1 ]] && echo true || echo false)"
        printf '"llm_health":%s,' "$([[ $llm_health -eq 1 ]] && echo true || echo false)"
        printf '"model_sync":%s,' "$([[ $model_sync -eq 1 ]] && echo true || echo false)"
        printf '"key_cache":%s,' "$([[ $key_cache -eq 1 ]] && echo true || echo false)"
        printf '"oc_config":%s,' "$([[ $oc_config -eq 1 ]] && echo true || echo false)"
        printf '"active_model":"%s",' "$(__llm_json_escape "$active_model")"
        printf '"issues":%s' "$issues"
        printf '}\n'
        (( issues == 0 ))
        return
    fi

    if [[ "$output_mode" == "plain" ]]
    then
        printf '%s\n' "openclaw_installed=$openclaw_installed"
        printf '%s\n' "gateway_port=$gateway_port"
        printf '%s\n' "gateway_health=$gateway_health"
        printf '%s\n' "llm_port=$llm_port"
        printf '%s\n' "llm_health=$llm_health"
        printf '%s\n' "model_sync=$model_sync"
        printf '%s\n' "key_cache=$key_cache"
        printf '%s\n' "oc_config=$oc_config"
        printf '%s\n' "active_model=$active_model"
        printf '%s\n' "issues=$issues"
        (( issues == 0 ))
        return
    fi

    __tac_header "LOCAL AI DOCTOR" "open"
    __tac_info "OpenClaw CLI" "[$([[ $openclaw_installed -eq 1 ]] && echo INSTALLED || echo MISSING)]" \
        "$([[ $openclaw_installed -eq 1 ]] && printf '%s' "$C_Success" || printf '%s' "$C_Error")"
    __tac_info "Gateway Port" "[$([[ $gateway_port -eq 1 ]] && echo LISTENING || echo CLOSED)]" \
        "$([[ $gateway_port -eq 1 ]] && printf '%s' "$C_Success" || printf '%s' "$C_Error")"
    local gateway_health_color="$C_Warning"
    [[ "$gateway_health" == "ok" || "$gateway_health" == "healthy" ]] && gateway_health_color="$C_Success"
    __tac_info "Gateway Health" "[${gateway_health^^}]" "$gateway_health_color"
    __tac_info "LLM Port" "[$([[ $llm_port -eq 1 ]] && echo LISTENING || echo CLOSED)]" \
        "$([[ $llm_port -eq 1 ]] && printf '%s' "$C_Success" || printf '%s' "$C_Error")"
    __tac_info "LLM Health" "[$([[ $llm_health -eq 1 ]] && echo OK || echo OFFLINE_OR_LOADING)]" \
        "$([[ $llm_health -eq 1 ]] && printf '%s' "$C_Success" || printf '%s' "$C_Warning")"
    __tac_info "Provider Sync" "[$([[ $model_sync -eq 1 ]] && echo OK || echo DRIFT)]" \
        "$([[ $model_sync -eq 1 ]] && printf '%s' "$C_Success" || printf '%s' "$C_Warning")"
    __tac_info "Key Cache" "[$([[ $key_cache -eq 1 ]] && echo PRESENT || echo MISSING)]" \
        "$([[ $key_cache -eq 1 ]] && printf '%s' "$C_Success" || printf '%s' "$C_Warning")"
    __tac_info "Config File" "[$([[ $oc_config -eq 1 ]] && echo PRESENT || echo MISSING)]" \
        "$([[ $oc_config -eq 1 ]] && printf '%s' "$C_Success" || printf '%s' "$C_Warning")"
    [[ -n "$active_model" ]] && __tac_info "Active Model" "[$active_model]" "$C_Dim"
    __tac_info "Summary" "[$issues issue(s)]" \
        "$([[ $issues -eq 0 ]] && printf '%s' "$C_Success" || printf '%s' "$C_Warning")"
    __tac_footer
    (( issues == 0 ))
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

# ---------------------------------------------------------------------------
# wacli — Wrapper that defaults --store to the OpenClaw store location.
#   Passes all arguments through; only appends --store if not already given.
# ---------------------------------------------------------------------------
function wacli() {
    local has_store=false
    local arg
    for arg in "$@"; do
        if [[ "$arg" == "--store" ]]; then
            has_store=true
            break
        fi
    done
    if $has_store; then
        command wacli "$@"
    else
        command wacli --store "$HOME/.openclaw/store/wacli" "$@"
    fi
}
export -f wacli

# ---------------------------------------------------------------------------
# oc-kgraph — Launch the kgraph knowledge-graph server and open in browser.
# Starts scripts/kgraph.py on localhost:46139, waits for it to bind, then
# opens the page in the default browser.
#
# Options:
#   --reindex   Rebuild OpenClaw memory index and sync graph DB before launch
#   --restart   Force-restart kgraph server before launch
#   -h|--help   Show usage
# ---------------------------------------------------------------------------
function oc-kgraph() {
    local KG_PY="$TACTICAL_REPO_ROOT/scripts/kgraph.py"
    if [[ ! -f "$KG_PY" ]]; then
        __tac_info "kgraph" "[NOT FOUND: $KG_PY]" "$C_Error"
        return 1
    fi

    local do_reindex=false
    local arg
    for arg in "$@"; do
        case "$arg" in
            --reindex|--refresh) do_reindex=true ;;
            --restart) ;;
            -h|--help)
                printf '%s\n' "Usage: oc g [--reindex|--refresh] [--restart]"
                printf '%s\n' "  --reindex  Sync memory DB to graph DB (memory auto-indexed)"
                printf '%s\n' "  --restart  Force-restart kgraph server"
                printf '%s\n' ""
                printf '%s\n' "Graph roles:"
                printf '%s\n' "  Obsidian/Gigabrain = curated human memory browser"
                printf '%s\n' "  oc g               = operational / derived graph browser"
                printf '%s\n' "  OpenStinger        = temporal/entity recall layer"
                printf '%s\n' ""
                printf '%s\n' "Views in oc g UI: overview, topics, files, semantic, raw"
                return 0
                ;;
        esac
    done

    if $do_reindex; then
        __tac_info "kgraph" "[SYNCING MEMORY DB TO GRAPH DB]" "$C_Info"
        # Note: 'openclaw memory index' was removed; memory is auto-indexed by gateway.
        # We just sync from the memory DB to the graph DB.

        # Sync indexed memory DB -> dedicated graph DB used by oc g.
        python3 - <<'PY' >/dev/null 2>&1 || true
import sys
import os
repo_root = os.environ.get('TACTICAL_REPO_ROOT')
if repo_root:
    sys.path.insert(0, repo_root)
from scripts import kgraph
memory_db = kgraph.resolve_memory_db_path()
if memory_db:
    graph = kgraph.load_from_memory_db(memory_db)
    kgraph.save_to_graph_db(os.path.expanduser('~/.openclaw/kgraph.sqlite'), graph)
PY
    fi

    # Always relaunch to avoid stale in-memory code/data across edits.
    # Kill whatever currently owns the port first (including legacy copies).
    local PORT=46139
    fuser -k "${PORT}/tcp" >/dev/null 2>&1 || true
    if pgrep -f "$KG_PY" >/dev/null 2>&1; then
        pkill -f "$KG_PY" >/dev/null 2>&1 || true
    fi
    sleep 0.3
    setsid python3 "$KG_PY" --serve --embed --host 127.0.0.1 --port "$PORT" >/dev/null 2>&1 &
    disown

    # Embedded mode serves a single HTML file plus /graph.json API.
    # Open the file path directly; opening / can yield a directory listing.
    local URL="http://127.0.0.1:${PORT}/kgraph.html"

    # Guard: only open URLs bound to localhost to prevent open-redirect.
    if [[ "$URL" != http://127.0.0.1:* && "$URL" != http://localhost:* ]]; then
        printf 'Refusing to open non-localhost URL: %s\n' "$URL"
        return 1
    fi

    __tac_info "Knowledge Graph" "[LAUNCHING — OVERVIEW VIEW]" "$C_Success"
    printf 'URL: %s\n' "$URL"
    printf '%s\n' 'Use the toolbar to switch views: overview, topics, files, semantic, raw.'

    # Wait up to ~5s for the server to respond, then give browsers a tiny
    # extra moment so we do not race a freshly-bound socket.
    local i
    local server_ready=1
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if command -v curl >/dev/null 2>&1; then
            if curl -sSf --head "$URL" >/dev/null 2>&1; then
                server_ready=0
                break
            fi
        else
            if (echo > /dev/tcp/127.0.0.1/${PORT}) >/dev/null 2>&1; then
                server_ready=0
                break
            fi
        fi
        sleep 0.5
    done
    sleep 0.3

    if [[ $server_ready -ne 0 ]]; then
        printf '\nWarning: kgraph server slow to bind.\n'
        printf 'URL may still come up: %s\n' "$URL"
    fi

    # Try launchers in a strict order and only claim success when the launcher
    # itself exits successfully.
    local opened=1
    local opener_used="manual"
    if [[ -f /proc/version ]] && grep -qi microsoft /proc/version 2>/dev/null; then
        if command -v wslview >/dev/null 2>&1; then
            if wslview "$URL" >/dev/null 2>&1; then
                opened=0
                opener_used="wslview"
            fi
        fi

        if [[ $opened -ne 0 ]] && command -v powershell.exe >/dev/null 2>&1; then
            if powershell.exe -NoProfile -Command "Start-Process '$URL'" >/dev/null 2>&1; then
                opened=0
                opener_used="powershell.exe"
            fi
        fi
    fi

    if [[ $opened -ne 0 ]]; then
        local browsers=(
            msedge
            microsoft-edge
            microsoft-edge-stable
            microsoft-edge-dev
            chromium-browser
            chromium
            google-chrome
            google-chrome-stable
            brave-browser
            firefox
        )
        local b
        for b in "${browsers[@]}"; do
            if command -v "$b" >/dev/null 2>&1; then
                if "$b" "$URL" >/dev/null 2>&1 & then
                    opened=0
                    opener_used="$b"
                    break
                fi
            fi
        done
    fi

    if [[ $opened -ne 0 ]] && command -v xdg-open >/dev/null 2>&1; then
        if xdg-open "$URL" >/dev/null 2>&1; then
            opened=0
            opener_used="xdg-open"
        fi
    fi

    if [[ $opened -eq 0 ]]; then
        printf 'Launcher: %s\n' "$opener_used"
    else
        printf '\nCould not launch a browser automatically. Open this URL manually: %s\n' "$URL"
        printf 'Launchers tried: wslview, powershell.exe, browser fallbacks, xdg-open\n'
    fi
}

# ==============================================================================
# OPENCLAW ENVIRONMENT VARIABLES
# ==============================================================================
# These are exported here so they are available to OpenClaw and any child
# processes. This keeps ~/.bashrc clean and ensures all OC-related config
# lives in the version-controlled module.

# Deep Recall provider — Python script for life memory recall
export OPENCLAW_LCM_DEEP_RECALL_CMD="python3 $OC_ROOT/life/deep-recall-provider-lcm.py"

# end of file
