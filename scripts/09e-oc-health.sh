# shellcheck shell=bash
# shellcheck disable=SC2034,SC2059,SC2120,SC2154
# --- Module: 09e-oc-health ---
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 1
# ==============================================================================
# 09e-oc-health
# ==============================================================================

function oc-health() {
    local output_mode="human"
    case "${1:-}" in
        --json) output_mode="json" ;;
        --plain) output_mode="plain" ;;
        --verbose|-v) output_mode="verbose" ;;
        *) ;;
    esac

    # Check if enhanced health check script exists
    local enhanced_script="$HOME/.openclaw/workspace/scripts/oc-health-check.py"

    if [[ -f "$enhanced_script" ]]
    then
        # Use comprehensive health check
        case "$output_mode" in
            json)
                "$TAC_PYTHON" "$enhanced_script" --json
                ;;
            plain)
                "$TAC_PYTHON" "$enhanced_script" --json | jq -r '.checks[] | "\(.name): \(.status) - \(.message)"'
                ;;
            verbose)
                "$TAC_PYTHON" "$enhanced_script" --verbose
                ;;
            *)
                "$TAC_PYTHON" "$enhanced_script"
                ;;
        esac
        return $?
    fi

    # Fallback to basic health check if enhanced script not found
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
                set +m
                cd "$os_dir" || { __tac_line "MCP Server" "[FAILED - dir not found: $os_dir]" "$C_Error"; return 1; }
                source "$os_dir/.venv/bin/activate" && \
                    nohup "$os_venv_python" -m openstinger.gradient.mcp.server \
                    > "$os_dir/.openstinger/openstinger.log" 2>&1 &
                disown
                set -m
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
            # -f required: target is a Node.js module path (not a simple argv[0]), -x would miss it
            if pkill -u "$USER" -f "openstinger.mcp.server" 2>/dev/null || \
               pkill -u "$USER" -f "openstinger.gradient.mcp.server" 2>/dev/null
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
        *) ;;
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
        *) ;;
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
        # Parse new health check format: look for API Health check status
        local api_health_status=""
        api_health_status=$(jq -r '.checks[] | select(.name == "API Health") | .status' <<< "$_oc_health_json" 2>/dev/null || echo "unknown")
        if [[ "$api_health_status" == "OK" || "$api_health_status" == "ok" ]]
        then
            gateway_health="ok"
        else
            gateway_health="unknown"
        fi
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
# Starts the kgraph package on localhost:46139, waits for it to bind, then
# opens the page in the default browser.
#
# Options:
#   --reindex   Rebuild OpenClaw memory index and sync graph DB before launch
#   --restart   Force-restart kgraph server before launch
#   -h|--help   Show usage
# ---------------------------------------------------------------------------
