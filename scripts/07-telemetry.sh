# shellcheck shell=bash
# shellcheck disable=SC2034,SC2059
# ─── Module: 07-telemetry ───────────────────────────────────────────────────────
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# TACTICAL_PROFILE_VERSION auto-computes from the sum of all module versions.
# Module Version: 3
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
#
# Error handling: Uses local variable for stat timestamp to avoid arithmetic
# errors if stat fails. Falls back to 0 (epoch) which makes cache appear stale.
# ---------------------------------------------------------------------------
function __cache_fresh() {
    local _cache_path="$1" _ttl="$2" _ts _now
    [[ -f "$_cache_path" ]] || return 1
    _ts=$(stat -c %Y "$_cache_path" 2>/dev/null) || _ts=0
    _now=$(date +%s)
    (( _now - _ts < _ttl ))
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
    local c_drive
    c_drive=$(df -h /mnt/c 2>/dev/null | awk 'NR==2 {print $4" free"}' | sed "$__unit_fix")
    local wsl_drive
    wsl_drive=$(df -h / | awk 'NR==2 {print $4" free"}' | sed "$__unit_fix")
    if [[ -n "$c_drive" ]]
    then
        echo "C: $c_drive | WSL: $wsl_drive"
    else
        df -h / | awk 'NR==2 {print $4" free ("$5" used)"}' | sed "$__unit_fix"
    fi
}

# ---------------------------------------------------------------------------
# __get_host_metrics — Return CPU% | GPU0% | GPU1% from Windows host (10s TTL).
# Uses typeperf.exe for CPU + both GPUs (Intel Iris + NVIDIA RTX) in one call.
# Async refresh pattern: on the first call after the 10s cache expires,
# returns the stale cached values immediately while spawning a background
# subshell to refresh via tac_hostmetrics.sh (~4s typeperf round-trip).
# This avoids blocking the dashboard render on slow Windows IPC.
# Falls back to "0|0|0" on first boot when no cache exists yet.
#
# Race condition fix: Uses PID-suffixed temp file to avoid conflicts if
# multiple shells refresh simultaneously. Temp file is cleaned up on exit.
# ---------------------------------------------------------------------------
function __get_host_metrics() {
    local cache="$TAC_CACHE_DIR/tac_hostmetrics"
    local cache_tmp="${cache}.$$"  # PID-suffixed to avoid race conditions
    if ! __cache_fresh "$cache" 10
    then
        ( bash "$TACTICAL_REPO_ROOT/bin/tac_hostmetrics.sh" > "$cache_tmp" 2>/dev/null \
            && { mv "$cache_tmp" "$cache" || rm -f "$cache_tmp"; } ) &>/dev/null &
        __TAC_BG_PIDS+=("$!")
    fi
    # Return stale cache data while background refresh runs.
    # Fall back to zeros when cache doesn't exist yet (first boot).
    if [[ -f "$cache" ]]
    then
        cat "$cache"
    else
        echo "0|0|0"
    fi
}

# ---------------------------------------------------------------------------
# __resolve_smi — Locate the nvidia-smi binary.
# Checks WSL_NVIDIA_SMI first (set in §1 constants to /usr/lib/wsl/lib/nvidia-smi),
# because the WSL-specific path is not on PATH by default. Falls back to PATH.
# Returns the path on stdout; returns 1 if not found.
# ---------------------------------------------------------------------------
function __resolve_smi() {
    local smi="$WSL_NVIDIA_SMI"
    [[ -x "$smi" ]] && { echo "$smi"; return 0; }
    smi=$(command -v nvidia-smi 2>/dev/null || true)
    [[ -n "$smi" && -x "$smi" ]] && { echo "$smi"; return 0; }
    return 1
}

# ---------------------------------------------------------------------------
# __get_gpu — Return CSV: name,temp,utilization,mem_used,mem_total (10s TTL).
# NVIDIA-only detail for the GPU COMPUTE dashboard row.
#
# Race condition fix: Uses PID-suffixed temp file to avoid conflicts if
# multiple shells refresh simultaneously. Temp file is cleaned up on failure.
# ---------------------------------------------------------------------------
function __get_gpu() {
    local cache="$TAC_CACHE_DIR/tac_gpu"
    local cache_tmp="${cache}.$$"  # PID-suffixed to avoid race conditions
    if __cache_fresh "$cache" 10
    then
        cat "$cache"; return
    fi
    (
        local smi_cmd
        smi_cmd=$(__resolve_smi)
        if [[ -n "$smi_cmd" ]]
        then
            local raw
            raw=$("$smi_cmd" \
                --query-gpu=name,temperature.gpu,utilization.gpu,memory.used,memory.total \
                --format=csv,noheader,nounits 2>/dev/null)
            if [[ -n "$raw" ]]
            then
                printf '%s' "${raw//NVIDIA GeForce /}" > "$cache_tmp" \
                    && { mv "$cache_tmp" "$cache" || rm -f "$cache_tmp"; }
            else
                echo "N/A" > "$cache_tmp" && { mv "$cache_tmp" "$cache" || rm -f "$cache_tmp"; }
            fi
        else
            echo "N/A" > "$cache_tmp" && { mv "$cache_tmp" "$cache" || rm -f "$cache_tmp"; }
        fi
    ) &>/dev/null &
    __TAC_BG_PIDS+=("$!")
    if [[ -f "$cache" ]]
    then
        cat "$cache"
    else
        echo "Querying..."
    fi
}

# ---------------------------------------------------------------------------
# __get_battery — Return battery percentage + status string (120s TTL).
# Uses /sys/class/power_supply on laptops; skips pwsh entirely on desktops
# (detected once at startup via __TAC_HAS_BATTERY).
#
# Race condition fix: Uses PID-suffixed temp file to avoid conflicts if
# multiple shells refresh simultaneously. Temp file is cleaned up on failure.
# ---------------------------------------------------------------------------
function __get_battery() {
    local cache="$TAC_CACHE_DIR/tac_batt"
    local cache_tmp="${cache}.$$"  # PID-suffixed to avoid race conditions
    if __cache_fresh "$cache" 120
    then
        cat "$cache"; return
    fi
    (
        if (( __TAC_HAS_BATTERY == 1 ))
        then
            local cap
            cap=$(cat /sys/class/power_supply/BAT0/capacity 2>/dev/null || echo "100")
            local bstat
            bstat=$(cat /sys/class/power_supply/BAT0/status 2>/dev/null || echo "Unknown")
            echo "${cap}% (${bstat})" > "$cache_tmp" && { mv "$cache_tmp" "$cache" || rm -f "$cache_tmp"; }
        else
            echo "A/C POWERED" > "$cache_tmp" && { mv "$cache_tmp" "$cache" || rm -f "$cache_tmp"; }
        fi
    ) &>/dev/null &
    __TAC_BG_PIDS+=("$!")
    if [[ -f "$cache" ]]
    then
        cat "$cache"
    else
        echo "Querying..."
    fi
}

# ---------------------------------------------------------------------------
# __get_git — Return "branch|SECURE" or "branch|BREACHED" for git repos.
# Returns empty string if not inside a git worktree.
# ---------------------------------------------------------------------------
function __get_git() {
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1
    then
        local branch
        branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
        local dirty
        if [[ -n $(git status --porcelain) ]]
        then
            dirty="BREACHED"
        else
            dirty="SECURE"
        fi
        echo "$branch|$dirty"
    fi
}

# ---------------------------------------------------------------------------
# __get_tokens — Read token usage from the most-recent OpenClaw session (30s TTL).
# Scans agents/*/sessions/sessions.json for the newest session with inputTokens.
# Returns "used|limit" or "N/A|0".
# ---------------------------------------------------------------------------
# Performance note (I2): Uses `jq -s` (slurp) to process all session files
# in a single jq invocation, avoiding the previous N+1 pattern (one jq per file).
# The background subshell ensures the dashboard never blocks.
function __get_tokens() {
    local cache="$TAC_CACHE_DIR/tac_tokens"
    local cache_tmp="${cache}.$$"  # PID-suffixed to avoid race conditions
    if __cache_fresh "$cache" 30
    then
        cat "$cache"; return
    fi
    (
        local files=()
        while IFS= read -r f
        do
            files+=("$f")
        done < <(find "$OC_AGENTS" -name "sessions.json" -type f \
            -printf '%T@ %p\n' 2>/dev/null | \
            sort -n -r | head -n 10 | cut -d' ' -f2-)

        local result=""
        if (( ${#files[@]} > 0 ))
        then
            result=$(jq -s -r '
                [ .[]
                  | to_entries[].value
                  | select(.inputTokens != null and .inputTokens > 0
                          and .contextTokens != null and .contextTokens > 0) ]
                | sort_by(.updatedAt) | last
                | "\(.inputTokens)|\(.contextTokens)"
            ' "${files[@]}" 2>/dev/null)
        fi

        if [[ -n "$result" && "$result" != "null|null" ]]
        then
            echo "$result" > "$cache_tmp" && { mv "$cache_tmp" "$cache" || rm -f "$cache_tmp"; }
        else
            echo "N/A|0" > "$cache_tmp" && { mv "$cache_tmp" "$cache" || rm -f "$cache_tmp"; }
        fi
    ) &>/dev/null &
    __TAC_BG_PIDS+=("$!")
    if [[ -f "$cache" ]]
    then
        cat "$cache"
    else
        echo "Querying...|0"
    fi
}

# ---------------------------------------------------------------------------
# __get_oc_version — Fetch OpenClaw CLI version (24h TTL — barely changes).
#
# Race condition fix: Uses PID-suffixed temp file to avoid conflicts if
# multiple shells refresh simultaneously. Temp file is cleaned up on failure.
# ---------------------------------------------------------------------------
function __get_oc_version() {
    local cache="$TAC_CACHE_DIR/tac_ocversion"
    local cache_tmp="${cache}.$$"  # PID-suffixed to avoid race conditions
    if __cache_fresh "$cache" "$COOLDOWN_DAILY"
    then
        cat "$cache"; return
    fi
    (
        local ocVersion="UNKNOWN"
        if command -v openclaw >/dev/null
        then
            ocVersion=$(openclaw --version 2>/dev/null | awk '{print $2}' | tr -d '\r\n')
            [[ -n "$ocVersion" ]] && ocVersion="v${ocVersion#v}"
        fi
        echo "$ocVersion" > "$cache_tmp" && { mv "$cache_tmp" "$cache" || rm -f "$cache_tmp"; }
    ) &>/dev/null &
    __TAC_BG_PIDS+=("$!")
    if [[ -f "$cache" ]]
    then
        cat "$cache"
    else
        echo "Querying..."
    fi
}

# ---------------------------------------------------------------------------
# __get_oc_metrics — Fetch OpenClaw session count (60s TTL) + version (24h TTL).
# Returns "count|age|version".
#   count — from `openclaw sessions` (cached in /dev/shm, 60s TTL)
#   age   — seconds since the cached value was last refreshed ("0" = fresh)
#
# Race condition fix: Uses PID-suffixed temp file to avoid conflicts if
# multiple shells refresh simultaneously. Temp file is cleaned up on failure.
# ---------------------------------------------------------------------------
function __get_oc_metrics() {
    local ver
    ver=$(__get_oc_version)

    local cache="$TAC_CACHE_DIR/tac_ocmetrics"
    local cache_tmp="${cache}.$$"  # PID-suffixed to avoid race conditions
    if ! __cache_fresh "$cache" 60
    then
        (
            local sessionCount=0
            if command -v openclaw >/dev/null
            then
                sessionCount=$(openclaw sessions --all-agents --json 2>/dev/null | jq -r '.count // 0' 2>/dev/null)
                sessionCount=${sessionCount:-0}
            fi
            echo "$sessionCount" > "$cache_tmp" && { mv "$cache_tmp" "$cache" || rm -f "$cache_tmp"; }
        ) &>/dev/null &
        __TAC_BG_PIDS+=("$!")
    fi

    local api_count age
    if [[ -f "$cache" ]]
    then
        api_count=$(< "$cache")
        age=$(( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || echo 0) ))
    else
        api_count="Querying..."
        age=0
    fi

    echo "${api_count}|${age}|${ver}"
}

# ---------------------------------------------------------------------------
# __get_llm_slots — Async-cached query to llama.cpp /slots endpoint (5s TTL).
# Returns JSON from the /slots API, or empty string if unavailable.
#
# Race condition fix: Uses PID-suffixed temp file to avoid conflicts if
# multiple shells refresh simultaneously. Temp file is cleaned up on failure.
# ---------------------------------------------------------------------------
function __get_llm_slots() {
    local cache="$TAC_CACHE_DIR/tac_llm_slots"
    local cache_tmp="${cache}.$$"  # PID-suffixed to avoid race conditions
    if __cache_fresh "$cache" 5
    then
        cat "$cache"; return
    fi
    (
        if __test_port "$LLM_PORT"
        then
            curl -sf --max-time 2 "http://127.0.0.1:${LLM_PORT}/slots" > "$cache_tmp" 2>/dev/null \
                && { mv "$cache_tmp" "$cache" || rm -f "$cache_tmp"; }
        fi
    ) &>/dev/null &
    __TAC_BG_PIDS+=("$!")
    [[ -f "$cache" ]] && cat "$cache"
}


# end of file
