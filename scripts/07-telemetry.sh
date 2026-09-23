# shellcheck shell=bash
# ─── Module: 07-telemetry ───────────────────────────────────────────────────────
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# TACTICAL_PROFILE_VERSION auto-computes from the sum of all module versions.
# Module Version: 13
# ==============================================================================
# 7. TELEMETRY & HARDWARE (FAST CACHING)
# ==============================================================================
# @modular-section: telemetry
# @depends: constants, design-tokens, ui-engine
# @exports: _telemetry, __tac_track_bg_job, __cache_fresh, __cache_age_suffix,
#   __get_uptime, __get_disk,
#   __get_host_metrics, __get_gpu_engines, __get_gpu, __get_battery,
#   __get_git, __get_oc_version, __get_oc_metrics, __get_llm_slots
#
# All telemetry functions use /dev/shm caching and background subshells to avoid
# blocking the dashboard render. Cache TTLs are tuned per metric volatility.

# ---------------------------------------------------------------------------
# _telemetry <getter> [args...] — run a telemetry getter in the CURRENT shell
# and capture its printed value in the global _telemetry_out.
#
# A command substitution (`x=$(__get_y)`) runs the getter in a subshell, so the
# background cache refreshes it launches become children of that subshell and
# their PIDs never reach __TAC_BG_PIDS — the EXIT cleanup would then kill
# nothing. Running the getter here keeps those jobs children of the interactive
# shell, so the PID tracking and cleanup are real.
# ---------------------------------------------------------------------------
function _telemetry() {
    local _tel_out
    if ! _tel_out=$(mktemp 2>/dev/null); then
        # mktemp failed (e.g. an unusable TMPDIR). Falling through would run the
        # getter with `> ""`, printing its output into the middle of the
        # dashboard while _telemetry_out stayed empty. Fall back to a plain
        # command substitution so the value is still captured — at the cost of
        # the background-refresh PID tracking this helper exists to preserve.
        printf '%s\n' "[telemetry] warning: mktemp failed; falling back to command substitution" >&2
        _telemetry_out=$("$@")
        return 0
    fi
    "$@" > "$_tel_out"
    _telemetry_out=$(< "$_tel_out")
    rm -f "$_tel_out"
}

# ---------------------------------------------------------------------------
# __tac_track_bg_job <pid> — Record a background refresh job for EXIT cleanup,
# and disown it so bash never prints a job-COMPLETION notice for it.
#
# Suppressing the notices takes two parts, because bash emits two of them:
#
#   * "[n] <pid>" at FORK time, when the spawn statement runs.  Only a redirect
#     in effect AT THAT STATEMENT can silence it, so the caller wraps the spawn
#     as `{ ( ... ) &>/dev/null & } 2>/dev/null`.  disown cannot help — measured
#     2026-09-22: with disown alone the start notice still printed seven times
#     into a dashboard render, and `set +m` did not suppress it either.
#   * "[n]+ Done <command>" at the next command boundary, and <command> is the
#     job's ENTIRE body — dozens of lines of source for the multi-line refreshes
#     below, dumped where the next prompt appears.  `disown` drops the job from
#     the JOB TABLE, so that one is never printed.
#
# The PID stays valid after disown, so the EXIT trap's `kill` still works
# (measured: a disowned job is still killed on exit).  Measured over 800
# spawn/disown pairs, interactive and not: disown never failed, so nothing is
# suppressed here.
#
# Every background spawn in this module and in §12 goes through both parts.
# ---------------------------------------------------------------------------
function __tac_track_bg_job() {
    __TAC_BG_PIDS+=("$1")
    disown "$1"
}

# ---------------------------------------------------------------------------
# __cache_fresh — Check if a cache file exists and is younger than TTL seconds.
# Usage: __cache_fresh <cache_path> <ttl_seconds>  →  returns 0 (fresh) or 1
# Deduplicates the repeated freshness-check pattern across all telemetry funcs.
#
# Error handling: Uses local variable for stat timestamp to avoid arithmetic
# errors if stat fails. Falls back to 0 (epoch) which makes cache appear stale.
#
# Portability: Uses GNU stat (-c %Y). For BSD/macOS stat, use (-f %m).
# This profile is Linux-only (WSL2 focus); BSD support would require:
#   _ts=$(stat -f %m "$_cache_path" 2>/dev/null || stat -c %Y "$_cache_path" 2>/dev/null) || _ts=0
# ---------------------------------------------------------------------------
function __cache_fresh() {
    local _cache_path="$1" _ttl="$2" _ts _now
    [[ -f "$_cache_path" ]] || return 1
    _ts=$(stat -c %Y "$_cache_path" 2>/dev/null) || _ts=0
    _now=$(date +%s)
    (( _now - _ts < _ttl ))
}

# ---------------------------------------------------------------------------
# __cache_age_suffix <cache_path> <stale_after_s> — the freshness marker a
# rendered cache value must carry, or "" while the value is young enough to be
# shown as current.
#
# Card CLAIMED-SUCCESS-WITNESS-001 (item 2): the dashboard renders /dev/shm
# caches whose freshness is per-cache, and nothing said so.  The stale value
# looked exactly like a live one — a day-old agent list or TPS read as current —
# which is the same "success reported for state that is not true" failure the
# read-back witnesses cover, one layer up at the surface.
#
# The band is the DISPLAY bound, not the cache's TTL, and the two are
# deliberately different: `oc_agent_use.txt` has a 5s TTL, but its refresh is an
# async background job (and `oc agent-use` itself takes seconds), so a render
# routinely reads a value a few seconds past its TTL.  A marker at the TTL would
# therefore fire on every normal render and teach the reader to ignore it — the
# one outcome worse than no marker.  Past the bound the value is no longer this
# render's data, and the suffix says how old it is.
#
# Format follows the SESSIONS row's existing convention (07/12: `${m_sess}
# Active (cached ${m_age}s ago)`): a space, "cached Ns ago", nothing new invented.
# ---------------------------------------------------------------------------
function __cache_age_suffix() {
    local _path="$1" _stale_after="$2" _ts _age
    [[ -n "$_path" && -f "$_path" ]] || { printf '%s' ""; return 0; }
    [[ "$_stale_after" =~ ^[0-9]+$ ]] || { printf '%s' ""; return 0; }
    # `|| return 1` rather than a redirect: a stat that fails here means the cache
    # vanished between the test above and this read, and that must be audible (the
    # caller then renders no marker, which is what a missing cache gets anyway).
    _ts=$(stat -c %Y "$_path") || return 1
    _age=$(( $(date +%s) - _ts ))
    (( _age > _stale_after )) || { printf '%s' ""; return 0; }
    printf ' (cached %ss ago — STALE)' "$_age"
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
    # One df for the WSL root, capturing free space and use% together, so the
    # fallback branch does not re-run df (it previously forked it twice).
    local wsl_free wsl_pct
    read -r wsl_free wsl_pct < <(df -h / | awk 'NR==2 {print $4, $5}')
    wsl_free=$(printf '%s' "$wsl_free" | sed "$__unit_fix")
    if [[ -n "$c_drive" ]]
    then
        echo "C: $c_drive | WSL: ${wsl_free} free"
    else
        echo "${wsl_free} free (${wsl_pct} used)"
    fi
}

# ---------------------------------------------------------------------------
# __refresh_host_metrics — Spawn a background refresh for host + engine caches.
# Shared helper used by __get_host_metrics and __get_gpu_engines so both caches
# are regenerated from one typeperf sample whenever either side goes stale.
# ---------------------------------------------------------------------------
function __refresh_host_metrics() {
    local cache="$TAC_CACHE_DIR/tac_hostmetrics"
    local engines_cache="$TAC_CACHE_DIR/tac_gpu_engines"
    # PID alone is insufficient: __get_host_metrics, __get_gpu_engines and
    # __get_gpu can each call this during one dashboard render while the cache
    # is still stale, so two same-shell refreshes would target the same temp
    # path and clobber each other mid-write. $RANDOM makes each call unique.
    local _tmp_token="$$.$RANDOM"
    local cache_tmp="${cache}.${_tmp_token}"
    local engines_tmp="${engines_cache}.${_tmp_token}"
    if ! __cache_fresh "$cache" 10 || ! __cache_fresh "$engines_cache" 10
    then
        { ( trap 'rm -f "$cache_tmp" "$engines_tmp"' EXIT; \
          TAC_GPU_ENGINES_OUT="$engines_tmp" \
          bash "$TACTICAL_REPO_ROOT/bin/tac_hostmetrics.sh" > "$cache_tmp" 2>/dev/null \
            && { mv "$cache_tmp" "$cache" || rm -f "$cache_tmp"; } \
            && { [[ -f "$engines_tmp" ]] && mv "$engines_tmp" "$engines_cache"; } ) &>/dev/null & } 2>/dev/null
        __tac_track_bg_job "$!"
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
# Race condition fix: temp files carry a PID + random token to avoid conflicts
# if multiple shells — or multiple calls in one shell — refresh simultaneously.
# Temp files are cleaned up on exit.
# ---------------------------------------------------------------------------
function __get_host_metrics() {
    local cache="$TAC_CACHE_DIR/tac_hostmetrics"
    __refresh_host_metrics
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
# __get_gpu_engines — Return a short NVIDIA dGPU engine summary (10s TTL).
# Value is produced alongside __get_host_metrics from the same typeperf sample.
# Falls back to "Idle" on first boot when no cache exists yet.
# ---------------------------------------------------------------------------
function __get_gpu_engines() {
    local cache="$TAC_CACHE_DIR/tac_gpu_engines"
    __refresh_host_metrics
    if [[ -f "$cache" ]]
    then
        cat "$cache"
    else
        echo "Idle"
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
    { (
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
                local g_name g_temp g_util g_mem_u g_mem_t
                IFS=',' read -r g_name g_temp g_util g_mem_u g_mem_t <<< "$raw"

                g_name="${g_name//NVIDIA GeForce /}"
                g_name="${g_name# }"; g_name="${g_name% }"
                g_temp="${g_temp# }"; g_temp="${g_temp% }"
                g_mem_u="${g_mem_u# }"; g_mem_u="${g_mem_u% }"
                g_mem_t="${g_mem_t# }"; g_mem_t="${g_mem_t% }"

                local gpu1_host g_util_n host_raw _cpu _gpu0
                host_raw=$(__get_host_metrics)
                IFS='|' read -r _cpu _gpu0 gpu1_host <<< "$host_raw"
                g_util_n="${g_util// /}"
                [[ "$g_util_n" =~ ^[0-9]+$ ]] || g_util_n=0
                [[ "$gpu1_host" =~ ^[0-9]+$ ]] || gpu1_host=0
                if (( gpu1_host > g_util_n ))
                then
                    g_util_n=$gpu1_host
                fi

                printf '%s,%s,%s,%s,%s' "$g_name" "$g_temp" "$g_util_n" "$g_mem_u" "$g_mem_t" > "$cache_tmp" \
                    && { mv "$cache_tmp" "$cache" || rm -f "$cache_tmp"; }
            else
                echo "N/A" > "$cache_tmp" && { mv "$cache_tmp" "$cache" || rm -f "$cache_tmp"; }
            fi
        else
            echo "N/A" > "$cache_tmp" && { mv "$cache_tmp" "$cache" || rm -f "$cache_tmp"; }
        fi
    ) &>/dev/null & } 2>/dev/null
    __tac_track_bg_job "$!"
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
    { (
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
    ) &>/dev/null & } 2>/dev/null
    __tac_track_bg_job "$!"
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
        branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || branch="UNKNOWN"
        branch=${branch:-UNKNOWN}
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
    { ( trap 'rm -f "$cache_tmp"' EXIT; \
      local ocVersion="UNKNOWN"
      if [[ "$__TAC_OPENCLAW_OK" == "1" ]]
      then
          ocVersion=$(openclaw --version 2>/dev/null | awk '{print $2}' | tr -d '\r\n')
          [[ -n "$ocVersion" ]] && ocVersion="v${ocVersion#v}"
      fi
      echo "$ocVersion" > "$cache_tmp" && { mv "$cache_tmp" "$cache" || rm -f "$cache_tmp"; }
    ) &>/dev/null & } 2>/dev/null
    __tac_track_bg_job "$!"
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
    _telemetry __get_oc_version
    ver=$_telemetry_out

    local cache="$TAC_CACHE_DIR/tac_ocmetrics"
    local cache_tmp="${cache}.$$"  # PID-suffixed to avoid race conditions
    if ! __cache_fresh "$cache" 60
    then
        { ( trap 'rm -f "$cache_tmp"' EXIT; \
          local sessionCount=0
          if [[ "$__TAC_OPENCLAW_OK" == "1" ]]
          then
              sessionCount=$(openclaw sessions --all-agents --json 2>/dev/null | jq -r '.count // 0' 2>/dev/null)
              sessionCount=${sessionCount:-0}
          fi
          echo "$sessionCount" > "$cache_tmp" && { mv "$cache_tmp" "$cache" || rm -f "$cache_tmp"; }
        ) &>/dev/null & } 2>/dev/null
        __tac_track_bg_job "$!"
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
    { (
        if __test_port "$LLM_PORT"
        then
            curl -sf --max-time 2 "http://127.0.0.1:${LLM_PORT}/slots" > "$cache_tmp" 2>/dev/null \
                && { mv "$cache_tmp" "$cache" || rm -f "$cache_tmp"; }
        fi
    ) &>/dev/null & } 2>/dev/null
    __tac_track_bg_job "$!"
    [[ -f "$cache" ]] && cat "$cache"
}


# end of file

# end of file marker
