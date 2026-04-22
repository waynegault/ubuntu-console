# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154
# ─── Module: 04-aliases ───────────────────────────────────────────────────────
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# TACTICAL_PROFILE_VERSION auto-computes from the sum of all module versions.
# Module Version: 13
# ==============================================================================
# 3. ALIAS DEFINITIONS & SHORTCUTS
# ==============================================================================
# @modular-section: aliases
# @depends: constants
# @exports: code, oedit, llmconf, oclogs, le, lo, ocui, occhat, occonf, os, oa, ocstat,
#   ocgs, ocv, status, ocms, cop, cop-ask, cop-init (plus standard shell aliases)
#   Note: owk → 'oc wk', ologs → 'oc log-dir'

# __os_fetch_cached — Fetch JSON with TTL cache.
# Reads cache if fresh (<cache_ttl seconds); otherwise runs the supplied command
# (passed as separate tokens after the first two arguments), validates JSON,
# writes cache, and returns the result. No eval — command tokens are passed
# directly to the shell via "$@".
function __os_fetch_cached() {
    local cache_file="$1" cache_ttl="$2"
    shift 2
    if [[ -f "$cache_file" ]]; then
        local _now _mtime
        _now=$(date +%s)
        _mtime=$(stat -c %Y "$cache_file" 2>/dev/null || echo 0)
        if (( _now - _mtime < cache_ttl )); then
            cat "$cache_file"; return 0
        fi
    fi
    local _result
    _result=$("$@" 2>/dev/null) || true
    if [[ -n "$_result" ]] && echo "$_result" | jq empty 2>/dev/null; then
        printf '%s' "$_result" > "$cache_file"
    fi
    printf '%s' "$_result"
}

# ---- Core OS Aliases ----
alias ls='ls --color=auto'
alias grep='grep --color=auto'
# fgrep/egrep are deprecated in modern coreutils. These aliases ensure
# backward compat if any inherited scripts call them. Safe to remove once
# confirmed no scripts in ~/console or ~/.openclaw reference fgrep/egrep.
alias fgrep='grep -F --color=auto'
alias egrep='grep -E --color=auto'
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'

# ---- Tactical UI & Navigation ----
alias h='tactical_help'
alias cls='clear_tactical'
alias c='clear_tactical'
alias reload='command clear; exec bash'
alias m='tactical_dashboard'
alias cpwd='copy_path'
alias unittest='"$TACTICAL_REPO_ROOT"/scripts/20-run-tests.sh'

# g — Shortcut for 'oc g' (launch knowledge graph server).
alias g='oc g'

# ---- Dev Tools & VS Code Wrappers (lazy-resolved — no pwsh hit at shell start) ----
# Path resolution is centralised in __resolve_vscode_bin (§1).
# Single-file wrappers (oedit, llmconf, etc.) use __vsc_open (§5).
# code() passes raw args and skips __vsc_open to support multi-arg/folder usage.
function code() {
    __resolve_vscode_bin
    if [[ -z "${VSCODE_BIN:-}" || ! -x "$VSCODE_BIN" ]]
    then
        __tac_info "VS Code" "[NOT FOUND]" "$C_Error"
        return 1
    fi
    "$VSCODE_BIN" "$@"
}
# oedit — Open tactical-console.bashrc in VS Code for editing.
function oedit() {
    __vsc_open "$TACTICAL_REPO_ROOT/tactical-console.bashrc" "VS Code opened... (run 'reload' to apply changes)"
}
# llmconf — Open the LLM model registry config in VS Code.
function llmconf() {
    __vsc_open "$LLM_REGISTRY"
}
# oclogs — Open the OpenClaw temporary log file in VS Code.
function oclogs() {
    __vsc_open "$OC_TMP_LOG"
}
# le — Show the last 40 lines of the OpenClaw gateway journal.
function le() {
    local _pat
    local _marker_file="${OC_ROOT:-$HOME/.openclaw}/state/console-log-clear.epoch"
    local _since_arg=()
    _pat='\berror\b|\bfailed\b|\bfailovererror\b|\btimeout\b|\btimed out\b|\bunauthorized\b|\bsecurity warning\b|\bexception\b|\btraceback\b|\bconnection error\b|\bpassword_missing\b|\bcode=1008\b|\b404 No models\b|\b503 Loading model\b|\bmodel_not_found\b|\bcontext overflow\b|\brequires target <E\.164\|group JID>\b|\bMCP server connection timed out\b'
    if [[ -r "$_marker_file" ]]; then
        local _epoch
        _epoch=$(tr -dc '0-9' < "$_marker_file")
        if [[ -n "$_epoch" ]]; then
            _since_arg=(--since "@$_epoch")
        fi
    fi
    journalctl --user -u openclaw-gateway.service --no-pager "${_since_arg[@]}" -n 300 --output=cat 2>&1 \
        | grep -Ei "$_pat" \
        | tail -40
    return "${PIPESTATUS[0]}"
}
# lo — Show the last 120 lines of the OpenClaw gateway journal.
function lo() {
    local _pat
    local _marker_file="${OC_ROOT:-$HOME/.openclaw}/state/console-log-clear.epoch"
    local _since_arg=()
    _pat='\berror\b|\bfailed\b|\bfailovererror\b|\btimeout\b|\btimed out\b|\bunauthorized\b|\bsecurity warning\b|\bexception\b|\btraceback\b|\bconnection error\b|\bpassword_missing\b|\bcode=1008\b|\b404 No models\b|\b503 Loading model\b|\bmodel_not_found\b|\bcontext overflow\b|\brequires target <E\.164\|group JID>\b|\bMCP server connection timed out\b'
    if [[ -r "$_marker_file" ]]; then
        local _epoch
        _epoch=$(tr -dc '0-9' < "$_marker_file")
        if [[ -n "$_epoch" ]]; then
            _since_arg=(--since "@$_epoch")
        fi
    fi
    journalctl --user -u openclaw-gateway.service --no-pager "${_since_arg[@]}" -n 300 --output=cat 2>&1 \
        | grep -Eiv "$_pat" \
        | tail -120
    return "${PIPESTATUS[0]}"
}
# __oc_open_local_url — Open a local OpenClaw URL in the default browser.
# Uses 127.0.0.1 to avoid browser HTTPS-first upgrades on localhost.
function __oc_open_local_url() {
    local url="$1"

    if [[ -z "$url" || "$url" != http://127.0.0.1:* ]]; then
        __tac_info "OpenClaw" "[REFUSING NON-LOCAL URL]" "$C_Error"
        return 1
    fi

    if command -v wslview >/dev/null 2>&1; then
        wslview "$url" >/dev/null 2>&1 && return 0
    fi
    if command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$url" >/dev/null 2>&1 && return 0
    fi

    printf '%s\n' "$url"
    return 0
}

# ocui — Open OpenClaw Control UI on the loopback IPv4 URL.
function ocui() {
    local _port="${OC_PORT:-18789}"
    __oc_open_local_url "http://127.0.0.1:${_port}/?gatewayUrl=ws%3A%2F%2F127.0.0.1%3A${_port}"
}

# occhat — Open the chat page with a target session.
# Usage: occhat [sessionKey]
# Example: occhat agent:hal:main
function occhat() {
    local _port="${OC_PORT:-18789}"
    local _session="${1:-agent:hal:main}"
    local _encoded_session

    _encoded_session=$(printf '%s' "$_session" | sed 's/:/%3A/g')
    __oc_open_local_url "http://127.0.0.1:${_port}/chat?gatewayUrl=ws%3A%2F%2F127.0.0.1%3A${_port}&session=${_encoded_session}"
}
# occonf — Open the OpenClaw config (openclaw.json) in VS Code.
# In read mode (TAC_READ_MODE=1): outputs config content instead.
function occonf() {
    if [[ "${TAC_READ_MODE:-}" == "1" ]]
    then
        if [[ -f "$OC_ROOT/openclaw.json" ]]
        then
            printf '%s\n' "=== $OC_ROOT/openclaw.json ==="
            cat "$OC_ROOT/openclaw.json"
        else
            __tac_info "Config" "[NOT FOUND: $OC_ROOT/openclaw.json]" "$C_Warning"
        fi
        return 0
    fi
    if [[ -f "$OC_ROOT/openclaw.json" ]]; then
        __vsc_open "$OC_ROOT/openclaw.json"
    else
        __tac_info "Config" "[NOT FOUND - $OC_ROOT/openclaw.json]" "$C_Warning"
    fi
}

# ---- Git Shortcuts ----
# commit: <msg> — git add + commit with YOUR message + push
# commit        — git add + commit with LLM-generated message + push
alias 'commit:'='commit_deploy'
alias commit='commit_auto'

# ---- OpenClaw Shortcuts (functions defined in §9) ----
# Wrapper: strip the leading blank line that openclaw always prints.
# Skip filtering for interactive/redirected commands to avoid breaking TTY.
# Does a live check for openclaw CLI availability.
function openclaw() {
    # Use cached install check (set at profile load time) — avoids forking openclaw --version
    if [[ "$__TAC_OPENCLAW_OK" != "1" ]]; then
        __tac_info "OpenClaw" "[NOT INSTALLED]" "$C_Warning"
        return 127
    fi
    if [[ -t 1 ]] && [[ "$1" != "tui" && "$1" != "logs" ]]
    then
        command openclaw "$@" | sed '1{/^$/d}'
    else
        command openclaw "$@"
    fi
}

# os — List OpenClaw sessions (all agents) with missing agents highlighted.
# Shows session names/labels and highlights agents without active sessions.
# Optimized: Uses cached data with TTL, combines jq calls, minimizes API calls.
function os() {
    export OPENCLAW_TOKEN="${OPENCLAW_TOKEN:-a3ac821b07f6884d3bf40650f1530e2d}"

    if [[ "$__TAC_OPENCLAW_OK" != "1" ]]; then
        __tac_info "OpenClaw" "[NOT INSTALLED]" "$C_Error"
        return 1
    fi

    local agent_cache="$TAC_CACHE_DIR/oc_agents.json"
    local session_cache="$TAC_CACHE_DIR/oc_sessions.json"
    local cache_ttl=5  # seconds

    # Fetch cached or live JSON (single helper eliminates duplication)
    local sessions_json agents_json
    sessions_json=$(__os_fetch_cached "$session_cache" "$cache_ttl" openclaw sessions --all-agents --json)
    [[ -z "$sessions_json" ]] && sessions_json=$(__os_fetch_cached "$session_cache" "$cache_ttl" openclaw sessions --json)
    agents_json=$(__os_fetch_cached "$agent_cache" "$cache_ttl" openclaw agents list --json)
    [[ -z "$agents_json" ]] && agents_json=$(__os_fetch_cached "$agent_cache" "$cache_ttl" openclaw agents --json)

    # Single jq call to extract all session data at once, sorted by agent name then age (youngest first)
    # Tokens column: input/output right-aligned to 11 chars, then percentage in parens
    local session_data
    session_data=$(printf '%s' "$sessions_json" | jq -r '
        (if type=="array" then . elif (.sessions?) then .sessions elif (.items?) then .items else . end)
        | .[]? | [
            (.agentId // .agent_id // .agent // "unknown"),
            (.sessionId // .id // "unknown"),
            (.key // .sessionId // .id // "unknown"),
            (.ageMs // .age // 0 | tostring),
            (.model // .modelName // "unknown"),
            ((.inputTokens // 0 | tostring) + "/" + (.outputTokens // 0 | tostring)) as $nums |
            (((.inputTokens // 0) + (.outputTokens // 0)) * 100 / (.contextTokens // 131072 | if . == 0 then 1 else . end) | floor | tostring) as $pct |
            (($nums | " " * (11 - length)) + $nums) + " (" + $pct + "%)"
          ] | @tsv' 2>/dev/null | sort -t$'\t' -k1,1f -k4,4n)

    # Count sessions and get agent list from session_data
    local session_count=0 store_count=0 agents_list=""
    if [[ -n "$session_data" ]]; then
        session_count=$(echo "$session_data" | wc -l)
        store_count=$(echo "$session_data" | awk -F'\t' '{print $1}' | sort -u | wc -l)
        agents_list=$(echo "$session_data" | awk -F'\t' '{print $1}' | sort -u | paste -sd',' | sed 's/,/, /g')
    fi

    # Build agent id -> name mapping (single jq call)
    local -A agent_names
    while IFS=$'\t' read -r _id _name; do
        [[ -n "$_id" ]] && agent_names["$_id"]="$_name"
    done < <(printf '%s' "$agents_json" | jq -r '
        (if type=="array" then . elif (.agents? or .items?) then (.agents // .items) else . end)
        | map({ id: (.id // .agent_id // .slug // .key // .name),
                name: (.identityName // .identity_name // .name // .display_name // .id) })
        | unique_by(.id)
        | .[]? | "\(.id)\t\(.name)"' 2>/dev/null)

    # Build session key -> label, cost, status mapping from sessions.json files
    local -A session_labels session_costs session_statuses
    for _sessions_file in "$OC_AGENTS"/*/sessions/sessions.json; do
        if [[ -f "$_sessions_file" ]]; then
            while IFS='|' read -r _skey _label _cost _status; do
                [[ -n "$_skey" ]] && session_labels["$_skey"]="$_label"
                [[ -n "$_skey" ]] && session_costs["$_skey"]="$_cost"
                [[ -n "$_skey" ]] && session_statuses["$_skey"]="$_status"
            done < <(jq -r 'to_entries[] | [.key, (.value.label // "N/A"), (.value.estimatedCostUsd // 0), (.value.status // "unknown")] | join("|")' "$_sessions_file" 2>/dev/null)
        fi
    done

    # Build set of agents with sessions
    local -A agents_with_sessions
    while IFS=$'\t' read -r _agent_id _rest; do
        [[ -n "$_agent_id" ]] && agents_with_sessions["$_agent_id"]=1
    done < <(printf '%s\n' "$session_data" | cut -f1)

    # Header
    if [[ -n "$agents_list" && "$store_count" != "0" ]]; then
        printf '%s\n' "${C_Highlight}${store_count} Agent session stores: ${agents_list}${C_Reset}"
    else
        printf '%s\n' "${C_Dim}0 Agent session stores: (none)${C_Reset}"
    fi
    printf '\n%s\n' "${C_Highlight}${session_count} Sessions:${C_Reset}"

    # Print sessions table header with underline
    if (( session_count > 0 )); then
        printf '\n%s\n' "${C_Dim}Agent          Label                                      Key                         Age         Model            Tokens      (ctx %)      Cost    Status  ${C_Reset}"
        printf '%s\n' "${C_Dim}────────────   ────────────────────────────────────────   ─────────────────────────   ─────────   ──────────────   ─────────────────────   ──────   ────────${C_Reset}"

        # Parse and display sessions
        local total_cost=0
        while IFS=$'\t' read -r agent session_id key age_ms model tokens; do
            local agent_name="${agent_names[$agent]:-$agent}"
            local session_label="${session_labels[$key]:-}"
            local session_cost="${session_costs[$key]:-0}"
            local session_status="${session_statuses[$key]:-unknown}"
            # Convert ageMs to human-readable format
            local age_str
            if [[ "$age_ms" =~ ^[0-9]+$ ]]; then
                local age_sec=$((age_ms / 1000))
                if (( age_sec < 60 )); then
                    age_str="${age_sec}s ago"
                elif (( age_sec < 3600 )); then
                    age_str="$((age_sec / 60))m ago"
                elif (( age_sec < 86400 )); then
                    age_str="$((age_sec / 3600))h ago"
                else
                    age_str="$((age_sec / 86400))d ago"
                fi
            else
                age_str="$age_ms"
            fi
            # Use label if set, otherwise show session ID
            local display_label="${session_label:-${session_id:0:10}}"
            # Format cost (round to 2 decimal places)
            local cost_str
            if [[ "$session_cost" =~ ^[0-9]*\.[0-9]+$ ]]; then
                cost_str=$(printf '$%.2f' "$session_cost")
            else
                cost_str="\$0.00"
            fi
            # Truncate/pad fields for display (Tokens column: 22 chars, right-aligned for bracket alignment)
            printf '%-12s   %-40s   %-25s   %-9s   %-14s   %-22s   %-6s   %s\n' \
                "${agent_name:0:12}" "${display_label:0:40}" "${key:0:25}" "${age_str:0:9}" "${model:0:14}" "$tokens" "$cost_str" "$session_status"
            # Accumulate total cost (no subprocess — bash integer arithmetic on micro-cents)
            if [[ "$session_cost" =~ ^[0-9]*\.[0-9]+$ ]]; then
                total_cost=$(awk "BEGIN {printf \"%.6f\", $total_cost + $session_cost}")
            fi
        done <<< "$session_data"

        # Print total cost with underline (aligned with Cost column)
        local total_cost_display
        total_cost_display=$(printf '$%.2f' "$total_cost")
        local total_label="Total cost: ${total_cost_display}"
        local total_len=${#total_label}
        local total_underline=""
        for ((i=0; i<total_len; i++)); do total_underline+="─"; done
        printf '\n'
        printf '%128s%s\n' "" "${total_label}"
        printf '%128s%s\n' "" "${total_underline}"
    else
        printf '%s\n' "${C_Dim}No sessions found.${C_Reset}"
    fi

    # Show agents without sessions (highlighted)
    local missing_count=0
    local missing_list=""
    while IFS=$'\t' read -r _id _name; do
        if [[ -n "$_id" && -z "${agents_with_sessions[$_id]:-}" ]]; then
            ((missing_count++))
            missing_list="${missing_list:+$missing_list, }${_name:-$_id}"
        fi
    done < <(printf '%s' "$agents_json" | jq -r '
        (if type=="array" then . elif (.agents? or .items?) then (.agents // .items) else . end)
        | map({ id: (.id // .agent_id // .slug // .key // .name),
                name: (.identityName // .identity_name // .name // .display_name // .id) })
        | unique_by(.id)
        | .[]? | "\(.id)\t\(.name)"' 2>/dev/null)

    if (( missing_count > 0 )); then
        printf '\n%s\n' "${C_Warning}Agents without sessions: $missing_count ($missing_list)${C_Reset}"
    fi
}
# oa — List OpenClaw agents.
function oa() {
    openclaw agents list
}
# oc-status — Show detailed OpenClaw status (--all).
function oc-status() {
    # Export token for gateway auth
    export OPENCLAW_TOKEN="${OPENCLAW_TOKEN:-a3ac821b07f6884d3bf40650f1530e2d}"
    openclaw status --all
}
# ocstat — Legacy alias for oc-status (deprecated).
function ocstat() {
    oc-status "$@"
}
# ocgs — Show OpenClaw gateway status with deep probe.
function ocgs() {
    # Export token for gateway auth
    export OPENCLAW_TOKEN="${OPENCLAW_TOKEN:-a3ac821b07f6884d3bf40650f1530e2d}"
    openclaw gateway status --deep
}
# ocv — Print the OpenClaw version.
function ocv() {
    openclaw --version
}
# status — Show basic OpenClaw status.
function status() {
    # Export token for gateway auth
    export OPENCLAW_TOKEN="${OPENCLAW_TOKEN:-a3ac821b07f6884d3bf40650f1530e2d}"
    openclaw status
}
# ocms — Show OpenClaw model status with live probe.
function ocms() {
    oc-sync-models "$@"
}

# ---- GitHub Copilot CLI ----
alias '??'='copilot -p'
alias cop='copilot'
# cop-init — Initialize GitHub Copilot CLI.
function cop-init() {
    copilot init
}
# cop-ask — Ask GitHub Copilot CLI a question.
function cop-ask() {
    copilot -p "$*"
}

# ---- LLM & Inference ----
# chat:      — interactive multi-turn chat with local LLM (end-chat to exit)
# wtf <topic>— ask the local LLM to explain a tool or concept (REPL mode)
alias chat:='local_chat'
alias wtf='wtf_repl'

# ---- System Maintenance ----
# wsl-up — Update WSL kernel and Microsoft distribution (requires Windows).
# This is a host-level operation, separate from WSL-internal 'up' maintenance.
# For WSL-internal updates (APT, NPM, etc.), use 'up' instead.
function wsl-up() {
    powershell.exe -NoProfile -NonInteractive -Command "wsl --update"
}

# end of file
