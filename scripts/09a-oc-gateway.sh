# shellcheck shell=bash
# shellcheck disable=SC2034,SC2059,SC2120,SC2154
# --- Module: 09a-oc-gateway ---
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 1
# ==============================================================================
# 09a-oc-gateway
# ==============================================================================

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
        if pgrep -f "${LLM_SERVER_PROC_PATTERN:-llama_cpp.server|llama-server}" >/dev/null 2>&1 && __test_port "${LLM_PORT:-8081}"
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
# __so_clear_wslrelay — Proactively clear wslrelay port conflicts.
# WSL2's networking relay process (wslrelay.exe) can transiently hold ports
# from previous sessions. This function detects and kills wslrelay if it's
# blocking the gateway port, before other startup checks run.
# Returns 0 always (non-blocking — informational only).
# ---------------------------------------------------------------------------
function __so_clear_wslrelay() {
    local _port="$1"
    command -v powershell.exe &>/dev/null || return 0

    local _win_holder _win_proc_name _pid_only
    _win_holder=$(timeout 3 powershell.exe -NoProfile -NonInteractive -Command "
        \$c = Get-NetTCPConnection -LocalPort $_port -State Listen -ErrorAction SilentlyContinue \
            | Select-Object -First 1
        if (\$c) {
            \$p = Get-Process -Id \$c.OwningProcess -ErrorAction SilentlyContinue
            '{0}|{1}' -f \$p.ProcessName, \$c.OwningProcess
        }
    " 2>/dev/null | tr -d '\r')

    [[ -z "$_win_holder" ]] && return 0

    _win_proc_name="${_win_holder%%|*}"
    _pid_only="${_win_holder##*|}"

    # Only act on wslrelay — let other conflicts be handled by __so_check_win_port
    if [[ "${_win_proc_name,,}" != "wslrelay" ]]
    then
        return 0
    fi

    __tac_info "Gateway" "[WSLRELAY HOLDING PORT $_port — clearing]" "$C_Warning"

    if command -v taskkill.exe &>/dev/null
    then
        taskkill.exe /PID "$_pid_only" /F &>/dev/null
        sleep 1

        # Verify the port is now free
        local _still_held
        _still_held=$(timeout 2 powershell.exe -NoProfile -NonInteractive -Command "
            Get-NetTCPConnection -LocalPort $_port -State Listen -ErrorAction SilentlyContinue
        " 2>/dev/null | tr -d '\r')

        if [[ -z "$_still_held" ]]
        then
            __tac_info "Gateway" "[WSLRELAY CLEARED — port $_port free]" "$C_Success"
        else
            __tac_info "Gateway" "[WSLRELAY PERSISTENT — manual intervention may be needed]" "$C_Warning"
        fi
    fi
    return 0
}

# ---------------------------------------------------------------------------
# __so_push_api_keys — Push API keys into systemd user environment.
# SECURITY: Validates key names before using indirect expansion to prevent
# command injection. Only allows uppercase letters, digits, and underscores.
# ---------------------------------------------------------------------------
function __so_push_api_keys() {
    if [[ -f "$TAC_CACHE_DIR/tac_win_api_keys" ]]; then
        # Validate file permissions (must be 600, owned by user)
        local _file_perms
            _file_perms=$(stat -c '%a' "$TAC_CACHE_DIR/tac_win_api_keys" 2>/dev/null || echo "666")
        if [[ "$_file_perms" != "600" ]]
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
    if pgrep -f "${LLM_SERVER_PROC_PATTERN:-llama_cpp.server|llama-server}" >/dev/null 2>&1 && __test_port "$LLM_PORT"
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
        _so_def_file=$(awk -F'|' 'NR>1 && $1 ~ /^[0-9]+$/ && $3!="" {print $3; exit}' "$LLM_REGISTRY" 2>/dev/null)
    fi

    if [[ -z "$_so_def_file" ]]
    then
        __tac_info "Error" \
            "[Local LLM offline and no models available. Run 'model scan' to discover models.]" \
            "$C_Error"
        return 1
    fi

    # Look up human-readable model name and model number from registry
    local _so_model_num=""
    local _so_model_name
    local _so_def_entry=""
    _so_def_entry=$(__llm_registry_entry_by_file "$_so_def_file" 2>/dev/null || true)
    if [[ -n "$_so_def_entry" ]]
    then
        IFS='|' read -r _so_model_num _so_model_name _ <<< "$_so_def_entry"
    fi

    # Fallback for no-default setups: pick the first valid registry row.
    if [[ -z "$_so_model_num" && -f "$LLM_REGISTRY" ]]
    then
        local _so_first_entry=""
        _so_first_entry=$(awk -F'|' 'NR>1 && $1 ~ /^[0-9]+$/ {print; exit}' "$LLM_REGISTRY" 2>/dev/null)
        if [[ -n "$_so_first_entry" ]]
        then
            IFS='|' read -r _so_model_num _so_model_name _so_def_file _ <<< "$_so_first_entry"
        fi
    fi

    : "${_so_model_name:=$_so_def_file}"

    if [[ -z "$_so_model_num" || ! "$_so_model_num" =~ ^[0-9]+$ ]]
    then
        __tac_info "Local LLM" "[FAILED TO RESOLVE MODEL NUMBER - run 'model scan' then 'model default <N>']" "$C_Error"
        return 1
    fi

    # Enable GPU persistence mode before starting the model
    wake 2>/dev/null || true

    # Start resolved model number in non-interactive mode.
    # Running serve in the foreground avoids shell job-control noise ([N] PID).
    local _so_start_ts _so_elapsed
    _so_start_ts=$(date +%s)
    if ! TAC_NONINTERACTIVE=1 serve "$_so_model_num" >/dev/null 2>&1
    then
        __tac_info "Local LLM" "[FAILED TO START — check: tail $LLM_LOG_FILE]" "$C_Error"
        return 1
    fi

    _so_elapsed=$(( $(date +%s) - _so_start_ts ))
    __tac_info "Local LLM" "[ONLINE on PORT $LLM_PORT] ${_so_model_name} (${_so_elapsed}s)" "$C_Success"
    return 0
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
        # Final grace check to avoid false negatives on slow bind/port probe races.
        local _grace_s=0 _grace_max=6
        while (( _grace_s < _grace_max ))
        do
            if __test_port "$OC_PORT"
            then
                __tac_info "Gateway" "[ONLINE] (port $OC_PORT, $((elapsed + _grace_s))s)" "$C_Success"
                return 0
            fi
            if journalctl --user -u "$_svc" --no-pager -n 30 --output=cat 2>/dev/null | grep -q 'ready ('
            then
                __tac_info "Gateway" "[ONLINE — READY SIGNAL]" "$C_Success"
                printf '%s\n' "  ${C_Dim}Service reported ready; port probe lagged briefly.${C_Reset}"
                return 0
            fi
            sleep 1
            ((_grace_s++))
        done

        __tac_info "Gateway" "[STARTING — finalizing]" "$C_Warning"
        printf '%s\n' "  ${C_Dim}Service active after $((elapsed + _grace_max))s; startup still settling.${C_Reset}"
        printf '%s\n' "  ${C_Dim}Run 'le' for logs if this does not clear in a few seconds.${C_Reset}"
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
        if pgrep -f "${LLM_SERVER_PROC_PATTERN:-llama_cpp.server|llama-server}" >/dev/null 2>&1 && __test_port "${LLM_PORT:-8081}"
        then
            __tac_info "Local LLM" "[RUNNING on PORT $LLM_PORT]" "$C_Success"
            __tac_info "Gateway" "[RUNNING on PORT $OC_PORT]" "$C_Success"
            return 0
        fi
        # Gateway running but LLM offline — only start LLM
        __tac_info "Gateway" "[RUNNING on PORT $OC_PORT]" "$C_Success"
    else
        # Gateway is offline — full startup sequence
        # Pre-flight: clear wslrelay port conflicts (WSL2 networking issue)
        __so_clear_wslrelay "$OC_PORT"

        # Pre-flight: clear stale state
        __so_clear_stale_state "$_svc"

        # Pre-flight: free port if held
        if ! __so_free_port "$OC_PORT"
        then
            return 1
        fi

        # Pre-flight: cycle Tailscale Serve if conflicting
        __so_cycle_tailscale_serve "$OC_PORT"

        # Set trap to restore Tailscale Serve on early exit
        if (( _ts_serve_active ))
        then
            trap 'sudo -n tailscale serve --bg "http://127.0.0.1:$OC_PORT" >/dev/null 2>&1; trap - EXIT' EXIT
        fi

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
            # Clear the EXIT trap now that we've restored manually
            trap - EXIT
        fi

        # Auto-create session for default agent (hal) if no sessions exist.
        # Runs silently in background — no UI noise for the user.
        __so_ensure_default_agent_session
    fi
}

# ---------------------------------------------------------------------------
# __so_ensure_default_agent_session — Create a session for the default agent
# (hal) if no sessions exist.
# ---------------------------------------------------------------------------
function __so_ensure_default_agent_session() {
    # Run session check and creation in background to avoid blocking so startup.
    # The session is a convenience feature — it should not delay the user.
    # NOTE: Spawns a detached bash -c subshell with & inside, so the interactive
    # shell never tracks a background job (no [N] PID noise).
    (bash -c '
        # Check if any sessions exist (with timeout to prevent hanging)
        _session_count=$(timeout 10 openclaw sessions --all-agents --json 2>/dev/null | jq -r '\''
            (if type=="array" then . elif (.sessions?) then .sessions elif (.items?) then .items else . end)
            | length'\'' 2>/dev/null) || true

        # Validate numeric output — guard against jq failure or partial output
        if ! [[ "$_session_count" =~ ^[0-9]+$ ]]; then
            _session_count=0
        fi

        if [[ "$_session_count" == "0" ]]; then
            # Synthetic bootstrap pings are disabled by operator preference.
            # No message is sent to create a session implicitly.
            :
        fi
    ' & )
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
    # Safe targets: node, python, llama-server, openclaw, code (VS Code), pwsh, powershell,
    #   wslrelay (WSL2 networking component — known to hold ports transiently)
    local _safe_proc=0
    case "${_win_proc_name,,}" in
        node|python|python3|llama-server|openclaw|code|pwsh|powershell|docker*|wslrelay)
            _safe_proc=1
            ;;
        *) ;;
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
function __oc_gateway_databases_closed() {
    local _deadline=$((SECONDS + 15))
    local _db_root="${OC_ROOT:-$HOME/.openclaw}/state"
    local _targets=()

    [[ -f "$_db_root/memory/lcm.db" ]] && _targets+=("$_db_root/memory/lcm.db")
    [[ -f "$_db_root/store.db" ]] && _targets+=("$_db_root/store.db")

    while (( SECONDS < _deadline )); do
        if (( ${#_targets[@]} == 0 )) || ! lsof "${_targets[@]}" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.2
    done
    return 1
}

function __oc_safe_gateway_shutdown() {
    local _svc="openclaw-gateway.service"

    timeout 10 openclaw gateway stop >/dev/null 2>&1 || true
    timeout 8 systemctl --user stop "$_svc" 2>/dev/null || true

    if ! __oc_gateway_databases_closed; then
        __tac_info "Gateway" "[DB HANDLE CHECK TIMED OUT — continuing safely]" "$C_Warning"
    fi
    rm -f "$OC_ROOT/supervisor.lock"
}

