# shellcheck shell=bash
# No file-level disables any more.  This module is analysed as part of the module
# graph (tools/lint.sh), so the constants it exports for other modules and the
# variables it reads from an earlier-loaded one both resolve honestly, and its
# sources are followed.  SC2016 is NOT disabled at file level — it is scoped to
# the three embedded-script sites below, so a genuinely mis-quoted expansion
# anywhere else in this file still gets flagged.
# --- Module: 09d-oc-agents ---
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 29
# ==============================================================================
# 09d-oc-agents
# ==============================================================================
# @modular-section: openclaw
# @depends: constants, design-tokens, ui-engine
# @exports: oc-agent-use, ockeys, ocdoc-fix, oc-refresh-keys,
#   oc-rotate-exposed-secrets

# Idempotent include guard: sub-modules are sourced both by their thin
# loader and directly by the profile/env loaders, so run the body once.
[[ -n "${__TAC_MOD_09D_OC_AGENTS_LOADED:-}" ]] && return 0
__TAC_MOD_09D_OC_AGENTS_LOADED=1

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

    local tmp_agents
    tmp_agents=$(mktemp) || tmp_agents="/tmp/oc_agents.$$"

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
    # Nested helpers — capture $_human (main formatting function) from parent scope
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
        if (( cap == 0 )); then
            cap=131072
        fi
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
            if (( cap_candidate > 14 )); then
                capw=14
            else
                capw=$cap_candidate
            fi
        else
            capw=14
        fi
        label_max=$raw_max
        if (( label_max > capw )); then
            label_max=$capw
        fi
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
    # SC2016: the `-Command` payload inside this loop is PowerShell, not bash —
    # `$($_.Key)` must reach pwsh unexpanded, so the single quoting is correct.
    # shellcheck disable=SC2016
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
    done < <(timeout 20 pwsh.exe -NoProfile -Command '
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
    # Honor TAC_CACHE_DIR so a sandboxed shell (tests) never touches the real
    # /dev/shm flag; production TAC_CACHE_DIR is /dev/shm, so behaviour is the same.
    local _warn_once_file="${TAC_CACHE_DIR:-/dev/shm}/tac_pwsh_bridge_warned"

    # Session-level guard: if pwsh.exe was previously unavailable or timed
    # out, skip retrying for the rest of this session. The warning file is
    # cleared on success so a working bridge is retried.
    # This avoids a ~20s hang on every shell init when pwsh.exe exists on
    # PATH but WSL interop is broken (common with WSL mirrored networking).
    if [[ -f "$_warn_once_file" ]]
    then
        # Source stale cache if it exists (from a prior session that worked).
        # $cache is generated at runtime from the Windows user environment, so
        # there is nothing here for shellcheck to follow.  The directive names
        # that — it is SC1090's own suggested remedy, not a disabled check.
        # shellcheck source=/dev/null
        [[ -f "$cache" ]] && source "$cache" 2>/dev/null
        return 0
    fi

    # Stateful downgrade: if pwsh.exe is unavailable, warn once per session.
    if ! command -v pwsh.exe >/dev/null 2>&1
    then
        printf '%s\n' "$(date +%s)" > "$_warn_once_file" 2>/dev/null || true
        echo "$(date +"%Y-%m-%d %H:%M:%S") [WARN] __bridge_windows_api_keys: pwsh.exe unavailable; bridge downgraded for this session." >> "$ErrorLogPath" 2>/dev/null
        return 0
    fi

    # Use cached exports if fresh enough
    if [[ -f "$cache" ]] && (( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || echo 0) < ttl ))
    then
        # shellcheck source=/dev/null
        source "$cache" 2>/dev/null
        return
    fi

    # Fetch matching vars from Windows User environment via PowerShell.
    # Match any variable whose name is credential-shaped: TOKEN, API_KEY /
    # API-KEY, PASSWORD, a *_KEY / *_SECRET suffix, *_CLIENT_ID, or a bare
    # *_API (case-insensitive). Covers GEMINI_API_KEY, OPENAI_API_KEY,
    # OPENCLAW_GATEWAY_TOKEN, OPENCLAW_GATEWAY_PASSWORD, plus the names the
    # earlier narrower pattern silently missed: OPENCLAW_WEB_SEARCH_KEY,
    # MICROSOFT_CLIENT_ID, HERE_NOW_API. Non-credential vars (Path, TEMP,
    # TMP, NODE_OPTIONS, OneDrive*, Chocolatey*, *DIR, *HOME) stay excluded.
    local raw
    # 20s, not 5s: a cold pwsh.exe start plus the User-env enumeration has been
    # measured at 3-10s over WSL interop, and a 5s cap silently returned a
    # truncated variable set (partial cache) instead of failing cleanly.
    # SC2016: PowerShell payload (see the ockeys loop above) — `$($_.Key)` must
    # not be expanded by bash.
    # shellcheck disable=SC2016
    raw=$(timeout 20 pwsh.exe -NoProfile -NonInteractive -Command '
        [Environment]::GetEnvironmentVariables("User").GetEnumerator() |
        Where-Object { $_.Key -match "(?i)(TOKEN|API(_|-)?KEY|PASSWORD|_KEY$|_SECRET|_CLIENT_ID$|_API$)" } |
        ForEach-Object { "$($_.Key)=$($_.Value)" }
    ' 2>/dev/null | tr -d '\r')

    if [[ -z "$raw" ]]
    then
        if [[ ! -f "$_warn_once_file" ]]
        then
            printf '%s\n' "$(date +%s)" > "$_warn_once_file" 2>/dev/null || true
            echo "$(date +"%Y-%m-%d %H:%M:%S") [WARN] __bridge_windows_api_keys: pwsh.exe returned no data; bridge downgraded for this session." >> "$ErrorLogPath" 2>/dev/null
        fi
        return 0
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
    # shellcheck source=/dev/null
    source "$cache" 2>/dev/null
    rm -f "$_warn_once_file" 2>/dev/null || true
}

# (Removed 2026-09-20: __oc_upsert_env_kv — unreferenced repo-wide; env-file writes
# go through __oc_sync_gateway_env_file.)

# (oc-sync-keys-to-bridge removed; behavior merged into oc-refresh-keys)

# ---------------------------------------------------------------------------
# __oc_apply_secret_refs — Map imported env credentials to OpenClaw SecretRefs.
#
# Mirrors what `openclaw secrets configure` writes for env-backed credentials:
# each supported config field becomes
#   { "source": "env", "provider": "default", "id": "<ENV_VAR>" }
# via `openclaw config set <path> --ref-provider default --ref-source env
# --ref-id <ENV_VAR>` (the canonical SecretRef builder). The secret itself stays
# in the env credential store refreshed by oc-refresh-keys; only the plaintext
# copy in openclaw.json is replaced by a reference.
#
# Safety:
#   - Applies a ref only when its env var is present and non-empty in the
#     current environment (sourced from the bridge cache), so an unresolved
#     ref is never created.
#   - `openclaw config set` runs SecretRef preflight and writes atomically, so
#     a field is left untouched if the ref would not resolve.
#   - Idempotent: re-running re-asserts the same refs.
#
# Mapping table: "<config dot-path>::<ENV_VAR_NAME>". Extend here when a new
# env-backed credential is confirmed to match a supported SecretRef field
# (see: openclaw docs reference/secretref-credential-surface).
# ---------------------------------------------------------------------------
function __oc_apply_secret_refs() {
    if ! command -v openclaw >/dev/null 2>&1
    then
        __tac_info "Syncing OpenClaw SecretRefs" "[openclaw not found — skipped]" "$C_Warning"
        return 0
    fi

    # Batch all env-backed SecretRefs into ONE `openclaw config patch` (single
    # validated write) — and skip the patch entirely when nothing changed, so a
    # no-op refresh performs no config writes at all.
    local _patch_info _patch _applied=0 _skipped=0 _failed=0
    _patch_info=$(python3 - <<'PYEOF'
import json, os, sys
entries = [
    # Web Search Plugin API Keys
    ("plugins.entries.google.config.webSearch.apiKey", "GEMINI_API_KEY"),
    ("plugins.entries.brave.config.webSearch.apiKey", "BRAVE_API_KEY"),
    ("plugins.entries.tavily.config.webSearch.apiKey", "TAVILY_API_KEY"),
    ("plugins.entries.perplexity.config.webSearch.apiKey", "PERPLEXITY_API_KEY"),
    ("plugins.entries.xai.config.webSearch.apiKey", "XAI_API_KEY"),
    ("plugins.entries.moonshot.config.webSearch.apiKey", "MOONSHOT_API_KEY"),
    ("plugins.entries.firecrawl.config.webSearch.apiKey", "FIRECRAWL_API_KEY"),
    # Model Provider API Keys (direct-consumption providers; deepseek uses an
    # auth profile below, not a models.providers ref)
    ("models.providers.openai.apiKey", "OPENAI_API_KEY"),
    ("models.providers.anthropic.apiKey", "ANTHROPIC_API_KEY"),
    ("models.providers.groq.apiKey", "GROQ_API_KEY"),
    ("models.providers.moonshot.apiKey", "MOONSHOT_API_KEY"),
    ("models.providers.openrouter.apiKey", "OPENROUTER_API_KEY"),
    ("models.providers.xai.apiKey", "XAI_API_KEY"),
    ("models.providers.qwen.apiKey", "QWEN_API_KEY"),
    ("models.providers.nvidia.apiKey", "NVIDIA_API_KEY"),
    ("models.providers.fireworks.apiKey", "FIREWORKS_API_KEY"),
    ("models.providers.huggingface.apiKey", "HUGGINGFACE_TOKEN"),
    # NOT mapped, deliberately: models.providers.inception.apiKey. `inception` is a
    # CUSTOM provider, and the schema refuses a patch that creates one without
    # baseUrl + models ("custom model providers must declare baseUrl"; a provider
    # overlay without them is only supported for BUNDLED providers). The refs go
    # out in ONE validated batch, so a row that validates only while the provider
    # block happens to exist can abort every other ref update the day it does not.
    # tests/unit/15-secret-ref-paths.bats catches exactly that, against an empty
    # base config. INCEPTION_API_KEY therefore stays store-backed, and the
    # refresh's own report names it so the gap stays visible (2026-09-22).
    # Tool / Platform API Keys
    # `tools.web.fetch.firecrawl.*` is a LEGACY shape the current schema rejects
    # ("tools.web.fetch: Unrecognized key: firecrawl"); openclaw doctor --fix
    # migrates it to the plugin entry below (docs/tools/web-fetch.md: "Legacy
    # tools.web.fetch.firecrawl.* config auto-migrates to
    # plugins.entries.firecrawl.config.webFetch").  A row the schema rejects is
    # worse than inert: `config patch` validates, so one bad row aborts the
    # whole batched SecretRef write (2026-09-22).
    ("plugins.entries.firecrawl.config.webFetch.apiKey", "FIRECRAWL_API_KEY"),
    ("tools.web.search.serp.apiKey", "SERP_API_KEY"),
    # Skill credentials -- installed skills live under skills.entries, NOT
    # plugins.entries: a row pointing at a non-existent path writes a leaf
    # nothing reads and the real ref is left un-injected (TYPESAFE_API_KEY,
    # 2026-09-22). Confirm the field against the real config before adding a row.
    ("skills.entries.typesafe-ai.apiKey", "TYPESAFE_API_KEY"),
    # Both of these were store-backed, so the key was bridged from Windows and
    # declared in the config yet never reached the gateway by name; mapping them
    # makes the env the single maintained channel (2026-09-22).
    ("skills.entries.agentmail-cli.apiKey", "AGENTMAIL_API_KEY"),
]

def set_path(node, path, value):
    parts = path.split(".")
    for p in parts[:-1]:
        node = node.setdefault(p, {})
    node[parts[-1]] = value

def get_path(node, path):
    for p in path.split("."):
        if not isinstance(node, dict) or p not in node:
            return None
        node = node[p]
    return node

cfg = {}
try:
    with open(os.path.expanduser("~/.openclaw/openclaw.json")) as f:
        cfg = json.load(f)
except Exception as exc:
    print(f"[tac] warning: could not read openclaw.json ({exc}); patching from an empty config", file=sys.stderr)

patch, changed, skipped = {}, 0, 0
for path, var in entries:
    if not os.environ.get(var):
        skipped += 1
        continue
    ref = {"source": "env", "provider": "default", "id": var}
    if get_path(cfg, path) == ref:
        continue  # already correct — no write needed
    set_path(patch, path, ref)
    changed += 1

# 2026-09-22: name the credentials the config REFERENCES but this table does not
# map. A ref that is not env-backed (source "store", or an older shape) reaches no
# env var, so oc-refresh-keys cannot inject it and the key reads as "imported from
# Windows but missing" — the TYPESAFE_API_KEY confusion, where the key sat in the
# bridge and was declared in the config and still never reached the gateway.
# Report the exact path and env var so the fix is the one-line table edit above.
# Never rewrite the ref here: a store-backed ref may be deliberate.
# 2026-09-22 (Pass C): ONE report for the three states a bridged key can be in,
# replacing two separate ones — the env sync listed every un-consumed key by name,
# and this walk named every non-env ref. Only the THIRD state is actionable, so
# only it is named; the second is a count, because a key with no consumer yet is
# not an error (RESMED_PASSWORD is waiting for one and otherwise reads as one of
# 27 failures).
#   injected        an env-backed ref exists, or this run is writing one
#   waiting         nothing in the config references it yet
#   NOT injectable  the config references it from a NON-env source (store), which
#                   no env var can ever fill — needs a mapping row or a decision
refs_env, refs_other = set(), []
def _collect(node, prefix=""):
    if isinstance(node, dict):
        if isinstance(node.get("id"), str) and "source" in node:
            if node.get("source") == "env":
                refs_env.add(node["id"])
            else:
                refs_other.append((node["id"], prefix, node.get("source")))
        for key, value in node.items():
            _collect(value, "{}.{}".format(prefix, key) if prefix else key)
    elif isinstance(node, list):
        for i, value in enumerate(node):
            _collect(value, "{}[{}]".format(prefix, i))

_collect(cfg)
# The table is about to make these env-backed, so count them as injected rather
# than reporting the pre-patch state (the staleness fixed in the reorder earlier).
refs_env |= {var for _, var in entries if os.environ.get(var)}
bridged = set()
_cache_file = os.path.join(os.environ.get("TAC_CACHE_DIR", "/dev/shm"), "tac_win_api_keys")
try:
    with open(_cache_file, encoding="utf-8") as _fh:
        for _line in _fh:
            if _line.startswith("export "):
                _nm = _line[7:].split("=", 1)[0]
                if _nm and _nm == _nm.upper() and _nm.replace("_", "").isalnum():
                    bridged.add(_nm)
except OSError as _exc:
    print("[tac] gateway env: cannot read the bridge cache ({})".format(_exc), file=sys.stderr)
if bridged:
    _injected = len(bridged & refs_env)
    _gaps = sorted({(v, p, s) for (v, p, s) in refs_other if v in bridged})
    _waiting = len(bridged - refs_env - {v for v, _p, _s in refs_other})
    _msg = "[tac] gateway env: {} injected, {} waiting for a consumer".format(_injected, _waiting)
    if _gaps:
        _msg += " -- NOT injectable (config refs with a NON-env source): " + ", ".join(
            "{}@{} (source {})".format(v, p, s) for v, p, s in _gaps
        )
    print(_msg, file=sys.stderr)
print(json.dumps({"patch": patch, "changed": changed, "skipped": skipped}))
PYEOF
)
    _patch=$(printf '%s' "$_patch_info" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)['patch']))" 2>/dev/null)
    _applied=$(printf '%s' "$_patch_info" | python3 -c "import json,sys; print(json.load(sys.stdin)['changed'])" 2>/dev/null)
    _skipped=$(printf '%s' "$_patch_info" | python3 -c "import json,sys; print(json.load(sys.stdin)['skipped'])" 2>/dev/null)
    if (( _applied > 0 )) && ! printf '%s' "$_patch" | openclaw config patch --stdin >/dev/null 2>&1; then
        _failed=$_applied
        _applied=0
    fi

    # ================================================================
    # Auth Profile SecretRef sync (SQLite credential stores)
    #
    # Keys managed via auth profiles (not models.providers.<id>.apiKey):
    #   DEEPSEEK_API_KEY  →  deepseek:default.keyRef
    #   OLLAMA_API_KEY    →  ollama:default.keyRef
    #
    # These live in per-agent `openclaw-agent.sqlite` tables.
    #
    # Format: <profile-id>:<provider>::<cred-type>::<env-var>
    # NOTE: the profile's `provider` field must equal the real provider id —
    # the auth resolver matches profiles via cred.provider === providerId
    # (listProfilesForProvider). Using "default" makes the keyRef invisible
    # to resolution (deepseek auth then fails with "No API key found").
    # ================================================================
    local _agents_root="${OC_AGENTS:-$HOME/.openclaw/agents}"
    # One python process for ALL agents x profiles (was one subprocess per
    # agent per profile — 45 spawns). Merges into each store's 'primary' row.
    local _auth_info _auth_applied=0 _auth_skipped=0 _auth_failed=0
    _auth_info=$(python3 - "$_agents_root" <<'PYEOF' 2>/dev/null
import json, os, sqlite3, sys, time
agents_root = sys.argv[1]
# Format: (profile_id, provider, cred_type, env_var)
auth_map = [
    ("deepseek", "deepseek", "api_key", "DEEPSEEK_API_KEY"),
    ("ollama", "ollama", "api_key", "OLLAMA_API_KEY"),
]
changed = unchanged = skipped = 0
for name in sorted(os.listdir(agents_root)):
    db = os.path.join(agents_root, name, "agent", "openclaw-agent.sqlite")
    if not os.path.isfile(db):
        continue
    con = sqlite3.connect(db, timeout=8.0)
    row = con.execute("SELECT store_json FROM auth_profile_store WHERE store_key='primary'").fetchone()
    store = json.loads(row[0]) if row else {"version": 1, "profiles": {}}
    for pid, provider, ctype, var in auth_map:
        if not os.environ.get(var):
            skipped += 1
            continue
        ref = {"source": "env", "provider": "default", "id": var}
        profile = {"type": ctype, "provider": provider}
        if ctype == "api_key":
            profile["keyRef"] = ref
        else:
            profile["tokenRef"] = ref
        store.setdefault("profiles", {})[pid] = profile
    # Write only when the merged store actually differs — no-op refreshes
    # perform zero sqlite writes. Compare parsed dicts (order-insensitive).
    new_json = json.dumps(store, sort_keys=True)
    if row and json.loads(row[0]) == store:
        unchanged += 1
        con.close()
        continue
    con.execute(
        "INSERT OR REPLACE INTO auth_profile_store (store_key, store_json, updated_at) VALUES ('primary', ?, ?)",
        (new_json, int(time.time() * 1000)),
    )
    con.commit()
    con.close()
    changed += 1
print(json.dumps({"stores_written": changed, "stores_unchanged": unchanged, "skipped": skipped}))
PYEOF
)
    _auth_applied=$(printf '%s' "$_auth_info" | python3 -c "import json,sys; print(json.load(sys.stdin)['stores_written'])" 2>/dev/null)
    _auth_unchanged=$(printf '%s' "$_auth_info" | python3 -c "import json,sys; print(json.load(sys.stdin)['stores_unchanged'])" 2>/dev/null)

    if (( _auth_applied > 0 ))
    then
        __tac_info "Syncing Auth Profile SecretRefs" "[$_auth_applied store(s) written, $_auth_unchanged unchanged]" "$C_Success"
    else
        __tac_info "Syncing Auth Profile SecretRefs" "[no stores changed ($_auth_unchanged verified)]" "$C_Dim"
    fi

    # Combined summary — report config refs and auth-profile writes separately
    # so the counts are not conflated with the number of imported env vars.
    if (( _failed > 0 ))
    then
        __tac_info "Syncing OpenClaw SecretRefs" "[config refs: $_applied applied, $_skipped skipped, $_failed failed | auth profiles: $_auth_applied writes]" "$C_Warning"
    elif (( _applied > 0 || _auth_applied > 0 ))
    then
        __tac_info "Syncing OpenClaw SecretRefs" "[config refs: $_applied applied, $_skipped skipped | auth profiles: $_auth_applied writes]" "$C_Success"
    else
        __tac_info "Syncing OpenClaw SecretRefs" "[nothing to update — all refs current]" "$C_Dim"
    fi
}

# ---------------------------------------------------------------------------
# __oc_gateway_resolved_env_names — print the env var names the OpenClaw gateway
# actually resolves as secrets, one per line, sorted and unique:
#   * env-backed SecretRefs in openclaw.json   ({"source":"env",...,"id":NAME})
#   * env-backed refs in every agent's auth-profile store (auth_profile_store)
#
# 2026-09-13: so()/oc-refresh-keys used to push EVERY bridged Windows var into the
# systemd user manager environment, so every user unit (dbus, pipewire, the llama
# servers, ...) inherited ~45 secrets it never reads — readable by any same-user
# process via /proc/<pid>/environ. Injection is now narrowed to this set. Prints
# nothing if the set cannot be computed (callers warn and fall back).
# ---------------------------------------------------------------------------
function __oc_gateway_resolved_env_names() {
    local _cfg="${OPENCLAW_CONFIG_PATH:-$HOME/.openclaw/openclaw.json}"
    local _state="${OPENCLAW_STATE_DIR:-$HOME/.openclaw}"
    python3 - "$_cfg" "$_state" <<'PY' 2>/dev/null
import glob, json, os, re, shutil, sqlite3, sys, tempfile

cfg_path, state = sys.argv[1], sys.argv[2]
names = set()

raw = None
if os.path.exists(cfg_path):
    with open(cfg_path, encoding='utf-8') as fh:
        raw = fh.read()
if raw is not None:
    doc = None
    try:
        doc = json.loads(raw)
    except Exception:
        # openclaw.json is JSON5 (comments + trailing commas allowed)
        try:
            stripped = re.sub(r'^\s*//.*$', '', raw, flags=re.M)
            doc = json.loads(re.sub(r',(\s*[}\]])', r'\1', stripped))
        except Exception:
            doc = None
    if doc is not None:
        stack = [doc]
        while stack:
            node = stack.pop()
            if isinstance(node, dict):
                if node.get('source') == 'env' and isinstance(node.get('id'), str):
                    names.add(node['id'])
                stack.extend(node.values())
            elif isinstance(node, list):
                stack.extend(node)

for db in glob.glob(os.path.join(state, 'agents', '*', 'agent', 'openclaw-agent.sqlite')):
    tmp = os.path.join(tempfile.mkdtemp(), 'store.sqlite')
    try:
        shutil.copy(db, tmp)
        conn = sqlite3.connect(f'file:{tmp}?mode=ro', uri=True)
        for (blob,) in conn.execute('select store_json from auth_profile_store'):
            for hit in re.finditer(r'"id"\s*:\s*"([A-Z_][A-Z0-9_]*)"', blob or ''):
                names.add(hit.group(1))
        conn.close()
    except Exception:
        continue

print('\n'.join(sorted(names)))
PY
}

# ---------------------------------------------------------------------------
# __oc_sync_gateway_env_file — Push bridged env vars into the systemd user manager
# environment (the secrets channel), which the gateway (a user service) inherits.
# It deliberately does NOT rewrite the unit or gateway.systemd.env — see step 2 for
# why, and reconcile a drifted managed-key list with `openclaw gateway install
# --force`. Restart is signalled only when the bridged
# values actually changed (content-hash comparison — comparing against
# `systemctl --user show-environment` is unreliable because it ANSI-quotes
# values that contain special characters). It also NAMES the bridged vars it
# does not inject, so the narrowing is visible instead of silent (2026-09-21).
# ---------------------------------------------------------------------------
function __oc_sync_gateway_env_file() {
    local _cache="$1"
    [[ -f "$_cache" ]] || return 0

    # Collect all var names from the cache that the gateway may need.
    local _var_names=()
    local _line _name
    while IFS= read -r _line; do
        [[ "$_line" =~ ^export[[:space:]]+ ]] || continue
        _name="${_line#export }"; _name="${_name%%=*}"
        [[ "$_name" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
        _var_names+=("$_name")
    done < "$_cache"

    mapfile -t _var_names < <(printf '%s\n' "${_var_names[@]}" | sort -u)
    ((${#_var_names[@]})) || return 0

    # 2026-09-13: narrow the manager-env push to the vars the gateway actually
    # resolves (see __oc_gateway_resolved_env_names). Fail-open with a warning if
    # the set cannot be computed — a config/DB hiccup must not silently starve
    # the gateway of a key it needs.
    local _resolved _kept=() _n
    _resolved="$(__oc_gateway_resolved_env_names)"
    if [[ -n "$_resolved" ]]; then
        # Iterate the array directly. This used to read it back through
        # `done < <(printf '%s\n' "${_var_names[@]}")`, which forks a printf and
        # a subshell to hand an already-in-memory array to `read` one line at a
        # time — item 6.4's shape without the file it was written for.
        for _n in "${_var_names[@]}"; do
            [[ -n "$_n" ]] || continue
            grep -qxF "$_n" <<< "$_resolved" && _kept+=("$_n")
        done
        _var_names=("${_kept[@]}")
    else
        __tac_info "Security" "[WARN: resolved-env set unavailable — pushing the full bridged set]" "$C_Warning"
    fi

    ((${#_var_names[@]})) || return 0

    # 1. Inject the resolved set, gated on BOTH the bridged values and the
    #    injected names — see __oc_inject_manager_env for why the name set is a
    #    trigger in its own right (2026-09-22).
    __oc_inject_manager_env "$_cache" "${_var_names[@]}"

    # 2. Do NOT rewrite the systemd unit. OpenClaw fingerprints its own unit
    #    definition (path + bytes + manager uid) before it stops the service
    #    for an update/repair, then re-validates it afterwards; an in-place
    #    edit of the Environment= line changes that fingerprint and the repair
    #    aborts with "Gateway service ownership or manager identity changed"
    #    (observed 2026-09-13: `openclaw doctor --fix` could not complete
    #    maintenance after this script rewrote the line at 10:50). The list is
    #    read from the process environment
    #    (readManagedServiceEnvKeysFromEnvironment), so it does not need to
    #    live in the unit at all. Values already reach the gateway through
    #    step 1 (`systemctl --user set-environment`) and the unit's
    #    `EnvironmentFile=-…/gateway.systemd.env`; this list only tunes
    #    hot-reload bookkeeping, and oc-refresh-keys restarts the gateway on
    #    any real value change (steps 5–7) — so nothing is lost by leaving
    #    OpenClaw's own list alone. Reconcile a drifted list by letting
    #    OpenClaw re-author the unit (`openclaw gateway install --force`,
    #    owner action), never by editing it here.

}

# ---------------------------------------------------------------------------
# __oc_inject_manager_env — push the resolved names into the systemd user manager
# environment (the secrets channel the gateway inherits), but only when something
# that affects the injection actually changed: the bridged VALUES (a content hash
# of the cache) or the injected NAME set.
#
# 2026-09-22 — the name set is its own trigger. Consuming a key as an env-backed
# SecretRef changes WHICH names are injected without changing any key VALUE, so a
# hash-only trigger left a newly-declared key out of the manager env for good and
# read exactly like a failed import (TYPESAFE_API_KEY: bridged from Windows and
# declared in openclaw.json, and still never injected, because no bridged value
# had changed since the hash was recorded). Recording the set that was pushed also
# means removing a SecretRef stops re-injecting that name rather than leaving it
# in the manager env forever.
#
# Usage: __oc_inject_manager_env <cache-file> <name>...
# Sets _OC_GW_ENV_CHANGED=1 when it injected, so the caller signals a restart.
# ---------------------------------------------------------------------------
function __oc_inject_manager_env() {
    local _cache="$1"
    shift
    local _hash_file="$TAC_CACHE_DIR/tac_win_api_keys.hash"
    local _set_file="$TAC_CACHE_DIR/tac_win_api_keys.resolved"
    local _hash _prev_hash _now_set _prev_set _name
    _hash=$(grep '^export ' "$_cache" | sort | sha256sum | awk '{print $1}')
    _prev_hash=$(cat "$_hash_file" 2>/dev/null || echo none)
    _now_set=$(printf '%s\n' "$@" | sort -u)
    _prev_set=$(cat "$_set_file" 2>/dev/null || echo none)
    if [[ "$_hash" != "$_prev_hash" || "$_now_set" != "$_prev_set" ]]; then
        for _name in "$@"; do
            systemctl --user set-environment "$_name=${!_name:-}" 2>/dev/null
        done
        _OC_GW_ENV_CHANGED=1
    fi
    # Record BOTH halves of the trigger, so a refresh that changed either one is
    # detected next time and a refresh that changed neither stays a no-op. The
    # set that was pushed is the set that is recorded.
    printf '%s\n' "$_hash" > "$_hash_file"
    printf '%s\n' "$_now_set" > "$_set_file"
}

# ---------------------------------------------------------------------------
# oc-refresh-keys — Force re-import of Windows API keys into WSL, persist to
# systemd env, and sync OpenClaw SecretRefs to the refreshed env credentials.
# The Windows User environment is the canonical source; local copies (.env,
# gateway.systemd.env, auth profiles) reference it rather than holding their
# own plaintext values.
# ---------------------------------------------------------------------------
# oc-export-keys-nas — mirror the bridged key cache to the NAS.
#
# Extracted from oc-refresh-keys (2026-09-22): a backup job does not belong inside
# a key refresh. It keeps its own SSH preflight, one connection per run, and a
# marker recording the CACHE hash it last uploaded — the same hash the refresh
# compares, so "is the mirror behind?" is an exact question. The marker is written
# only after a successful upload, so a failed sync is retried on the next run.
# Run it standalone (`oc export-keys-nas`) or from a timer.
# ---------------------------------------------------------------------------
function oc-export-keys-nas() {
    local cache="$TAC_CACHE_DIR/tac_win_api_keys"
    local _nas_collectors_env="/mnt/HD/HD_a2/butler/cron/openclaw-collectors.env"
    local _nas_user="${OC_NAS_USER:-sshd}"
    # LAN SSH to 192.168.33.20 times out from WSL. The NAS is reachable via
    # Tailscale, but its MagicDNS name (mycloudex2ultra.tail99183.ts.net) does
    # not resolve while Tailscale DNS is off (`tailscale set --accept-dns`), so
    # use the stable Tailscale IP. Override with OC_NAS_HOST if the LAN route is
    # restored or MagicDNS is re-enabled.
    local _nas_host="${OC_NAS_HOST:-100.106.225.96}"
    local _nas_key="${OC_NAS_KEY_PATH:-$HOME/.ssh/jarvis_sshd_key}"
    if [[ ! -f "$cache" ]]
    then
        __tac_info "Exporting to NAS" "[no bridge cache — run 'oc refresh-keys' first]" "$C_Warning"
        return 1
    fi
    # Source the cache. This command iterates the cache for NAMES but reads the
    # VALUES from the environment, so a standalone run (a timer, or right after a
    # reboot) would otherwise export a file containing only its header and then
    # mark that as synced — silent data loss. Sourcing here is a correctness
    # requirement, not a convenience.
    # shellcheck source=/dev/null
    if ! source "$cache" 2>/dev/null
    then
        __tac_info "Exporting to NAS" "[cache unreadable — run 'oc refresh-keys' first]" "$C_Warning"
        return 1
    fi
    local _cache_hash
    _cache_hash=$(grep '^export ' "$cache" | sort | sha256sum | awk '{print $1}')
    local _prev_nas_hash
    _prev_nas_hash=$(cat "$TAC_CACHE_DIR/tac_win_api_keys.nas_hash" 2>/dev/null || echo none)
    local _nas_ssh=()
    if [[ -f "$_nas_key" ]] && command -v ssh >/dev/null 2>&1
    then
        _nas_ssh=(ssh -i "$_nas_key" -o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=no "${_nas_user}@${_nas_host}")
    elif command -v sshpass >/dev/null 2>&1 && [[ -n "${SSH_PASSWORD:-}" ]]
    then
        _nas_ssh=(sshpass -p "$SSH_PASSWORD" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=6 "${_nas_user}@${_nas_host}")
    fi
    if ((${#_nas_ssh[@]}))
    then
        local _synced_nas=0 _nas_skipped=0 _nas_tmp _l _k2 _v2
        _nas_tmp="$(mktemp)"
        {
            printf '# regenerated by oc export-keys-nas %s\n' "$(date -Iseconds)"
            while IFS= read -r _l
            do
                [[ "$_l" =~ ^export[[:space:]]+ ]] || continue
                _k2="${_l#export }"; _k2="${_k2%%=*}"
                [[ "$_k2" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
                _v2="${!_k2:-}"
                [[ -n "$_v2" ]] || continue
                # %q alone is the correct escaping: it yields a shell word that
                # round-trips to the exact value. Wrapping it in double quotes
                # double-escapes (e.g. a "!" password becomes GlowforHomes\!…).
                printf 'export %s=%q\n' "$_k2" "$_v2"
            done < "$cache"
        } > "$_nas_tmp"
        if [[ "$_cache_hash" == "$_prev_nas_hash" ]]
        then
            _nas_skipped=1
        elif "${_nas_ssh[@]}" "cat > \"$_nas_collectors_env.tmp\"" < "$_nas_tmp" >/dev/null 2>&1 \
            && "${_nas_ssh[@]}" "mv \"$_nas_collectors_env.tmp\" \"$_nas_collectors_env\"" >/dev/null 2>&1
        then
            _synced_nas=1
            printf '%s\n' "$_cache_hash" > "$TAC_CACHE_DIR/tac_win_api_keys.nas_hash"
        fi
        rm -f "$_nas_tmp"
        if (( _synced_nas == 1 ))
        then
            __tac_info "Exporting to NAS" "[$_nas_collectors_env]" "$C_Success"
        elif (( _nas_skipped == 1 ))
        then
            __tac_info "Exporting to NAS" "[no changes — skipped]" "$C_Dim"
        else
            __tac_info "Exporting to NAS" "[failed — SSH sync error (auth or connectivity)]" "$C_Warning"
        fi
    else
        local _reason=""
        if ! command -v ssh >/dev/null 2>&1
        then
            _reason="ssh missing"
        elif [[ ! -f "$_nas_key" ]]
        then
            _reason="SSH key missing ($_nas_key)"
        else
            _reason="preflight failed"
        fi
        __tac_info "Exporting to NAS" "[skipped — ${_reason}]" "$C_Warning"
    fi
}

# ---------------------------------------------------------------------------
# __oc_report_gh_credential_surface — state where `gh` gets its token, and
# whether a `gh` call carrying none would reach the system keyring.
#
# `gh` prefers GH_TOKEN/GITHUB_TOKEN over any stored credential, and that
# precedence is absolute: with the token present, `gh auth token --hostname
# github.com` never contacts org.freedesktop.secrets; with it absent, the same
# call ACTIVATES the Secret Service, which creates the default keyring behind a
# password prompt when there is none. Measured 2026-09-23, reproducing the
# 10:52:57 prompt (the ChatGPT/Codex VS Code extension's GitHub-media path runs
# `gh auth token --hostname github.com` from an environment carrying no token).
# Nothing here reported the state that made it possible, which is why this
# witness exists. It reads files and the manager env, never runs `gh`, so it
# cannot prompt. Full record: README "GitHub CLI credentials", docs/openclaw.md.
# Related: bin/gh (installed as ~/.local/bin/gh) closes the PATH gap.
# ---------------------------------------------------------------------------
function __oc_report_gh_credential_surface() {
    local _cache="$1"
    local _cfg_dir="${GH_CONFIG_DIR:-$HOME/.config/gh}"
    local _env_dropin="$HOME/.config/environment.d/90-openclaw.conf"
    local _surfaces=""

    if grep -q '^export GH_TOKEN=' "$_cache"
    then
        _surfaces="bridge cache"
    fi
    # A refresh also runs where there is no user manager at all (agent and CI
    # shells), so a failing systemctl is the honest read here: "no manager env in
    # this context" is a fact this report states, not a defect to hide.
    # swallow-ok: systemctl is absent in agent/CI shells, and the surface set is reported either way
    if systemctl --user show-environment 2>/dev/null | grep -q '^GH_TOKEN='
    then
        _surfaces="${_surfaces:+$_surfaces + }systemd user env"
    fi
    if [[ -f "$_env_dropin" ]] && grep -q '^GH_TOKEN=' "$_env_dropin"
    then
        _surfaces="${_surfaces:+$_surfaces + }environment.d"
    fi

    # gh's own config: hosts.yml recording a user with NO plaintext oauth_token
    # means the credential is not in the FILE, so a gh invoked with no token in
    # its environment has to ASK the credential store — and that ask is what
    # activates gnome-keyring. Do not read more into this than the file shows:
    # measured 2026-09-23 on this box, the Default keyring holds ZERO items, so
    # gh has no stored credential to find; the call activates the service and
    # then fails with "no oauth token found for github.com".
    local _no_plaintext_token="no"
    if [[ -f "$_cfg_dir/hosts.yml" ]] \
        && grep -q '^[[:space:]]*user:' "$_cfg_dir/hosts.yml" \
        && ! grep -q '^[[:space:]]*oauth_token:' "$_cfg_dir/hosts.yml"
    then
        _no_plaintext_token="yes"
    fi

    local _msg _colour
    if [[ -z "$_surfaces" ]]
    then
        _msg="GH_TOKEN on NO env surface — every 'gh' call reaches the credential store"
        _colour="$C_Warning"
    elif [[ "$_no_plaintext_token" == "yes" ]]
    then
        _msg="GH_TOKEN on: $_surfaces — gh's hosts.yml holds no plaintext token"
        _msg+=", so a 'gh' call without the token activates gnome-keyring"
        _colour="$C_Warning"
    else
        _msg="GH_TOKEN on: $_surfaces — gh needs no stored credential"
        _colour="$C_Success"
    fi
    __tac_info "GitHub CLI" "[$_msg]" "$_colour"
}

# ---------------------------------------------------------------------------
function oc-refresh-keys() {
    local cache="$TAC_CACHE_DIR/tac_win_api_keys"
    local count=0

    local _canonical_names="$TAC_CACHE_DIR/tac_win_api_key_names"
    local _prev_cache="$TAC_CACHE_DIR/tac_win_api_keys.prev"

    # 1. Pull matching vars from Windows User environment.
    #    Preserve last-good values so a pwsh.exe outage can't change the var set.
    [[ -f "$cache" ]] && cp "$cache" "$_prev_cache" 2>/dev/null || true
    if command -v pwsh.exe >/dev/null 2>&1; then
        rm -f "$cache" "${TAC_CACHE_DIR:-/dev/shm}/tac_pwsh_bridge_warned"
        __bridge_windows_api_keys
        if [[ -f "$cache" ]]; then
            count=$(grep -c '^export ' "$cache" || true)
            __tac_info "Reading Windows User environment" "[$count variable(s) imported]" "$C_Success"
        fi
    fi

    # 2a. pwsh.exe succeeded — merge Linux-side vars and persist the canonical
    #     key-name set (used to keep the fallback var set identical).
    if [[ -f "$cache" ]]; then
        for _lk in CONTEXT7_API_KEY DEVIN_API_KEY OPENCLAW_GATEWAY_TOKEN; do
            [[ -n "${!_lk:-}" ]] || continue
            grep -q "^export ${_lk}=" "$cache" 2>/dev/null && continue
            printf 'export %s=%q\n' "$_lk" "${!_lk}" >> "$cache"
        done
        # shellcheck source=/dev/null
        source "$cache" 2>/dev/null
        count=$(grep -c '^export ' "$cache" || true)
        grep -oE '^export [A-Z0-9_]+' "$cache" | sed 's/^export //' | sort -u > "$_canonical_names"

    # 2b. Fallback (pwsh.exe unavailable): rebuild the cache using ONLY the
    #     canonical key names — values from the Linux env, falling back to the
    #     last-good values. Keeps the variable set identical across runs (no
    #     pwsh up/down flip-flop), so the gateway restart gate stays quiet.
    elif [[ -f "$_canonical_names" ]]; then
        : > "$cache"
        chmod 600 "$cache" 2>/dev/null || true
        while IFS= read -r _lk; do
            [[ -n "$_lk" ]] || continue
            _lv="${!_lk:-}"
            if [[ -z "$_lv" && -f "$_prev_cache" ]]; then
                _lv=$(sed -n "s/^export ${_lk}=//p" "$_prev_cache" | head -1)
            fi
            [[ -n "$_lv" ]] && printf 'export %s=%q\n' "$_lk" "$_lv"
        done < "$_canonical_names" > "$cache"
        # shellcheck source=/dev/null
        source "$cache" 2>/dev/null
        count=$(grep -c '^export ' "$cache" || true)
        __tac_info "Reading Windows User environment" "[pwsh.exe unavailable — using last-good env ($count vars)]" "$C_Warning"

    else
        # No canonical list yet (first run) — scan the Linux env with the
        # same patterns the Windows bridge uses.
        : > "$cache" 2>/dev/null
        chmod 600 "$cache" 2>/dev/null || true
        while IFS='=' read -r _lk _lv; do
            [[ -z "$_lk" || -z "$_lv" ]] && continue
            [[ "$_lk" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
            [[ "$_lk" =~ [Tt][Oo][Kk][Ee][Nn] ]] || \
                [[ "$_lk" =~ [Aa][Pp][Ii][_-]?[Kk][Ee][Yy] ]] || \
                [[ "$_lk" =~ [Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd] ]] || \
                [[ "$_lk" =~ [Ss][Ee][Cc][Rr][Ee][Tt] ]] || \
                [[ "$_lk" =~ [Cc][Ll][Ii][Ee][Nn][Tt]_[Ii][Dd]$ ]] || \
                [[ "$_lk" =~ [Aa][Pp][Ii]$ ]] || \
                [[ "$_lk" =~ _[Kk][Ee][Yy]$ ]] || continue
            printf 'export %s=%q\n' "$_lk" "$_lv" >> "$cache"
            count=$((count + 1))
        done < <(env | sort -u)
        if [[ "$count" -gt 0 ]]; then
            # shellcheck source=/dev/null
            source "$cache" 2>/dev/null
            grep -oE '^export [A-Z0-9_]+' "$cache" | sed 's/^export //' | sort -u > "$_canonical_names"
            __tac_info "Reading Windows User environment" "[pwsh.exe unavailable — using Linux env vars ($count exported)]" "$C_Warning"
        else
            __tac_info "Reading Windows User environment" "[no vars found — pwsh.exe unavailable and no Linux fallback vars set]" "$C_Warning"
            return 1
        fi
    fi

    # Also re-assert env.shellEnv (worker-side secret resolution) — see
    # __so_ensure_shell_env. Both reports below describe the post-patch config.
    local _OC_GW_ENV_CHANGED=0
    if type -t __so_ensure_shell_env >/dev/null 2>&1; then __so_ensure_shell_env; fi

    # 3. Sync OpenClaw SecretRefs to the refreshed env credentials FIRST, so the
    #    resolved-name set computed in step 4 sees any ref this run has just
    #    converted to env-backed.
    #
    #    2026-09-22: with the order reversed, a newly-mapped key was written as an
    #    env-backed SecretRef and the SAME run still listed it as "reach no
    #    SecretRef" / "not injected", because the resolution had already been
    #    computed against the pre-patch config. The key then only entered the
    #    manager env on the NEXT refresh (measured: AGENTMAIL_API_KEY). Applying
    #    the refs first makes mapping and injection converge in one pass, and it
    #    makes both of this run's reports describe the same post-patch state.
    __oc_apply_secret_refs

    # 4. Push the gateway-resolved bridged vars into the systemd user manager
    #    environment so the running gateway can resolve env-backed SecretRefs
    #    referenced by auth profiles in agent sqlite databases. The unit and
    #    gateway.systemd.env are left alone (see __oc_sync_gateway_env_file,
    #    step 2 — OpenClaw fingerprints its own unit).
    #    Without this, `openclaw doctor` reports "secret reference was not
    #    found" because the gateway process lacks the env vars.
    __oc_sync_gateway_env_file "$cache"

    # 4b. State the GitHub CLI's credential surface. This is a report, not a fix:
    #     it names which surfaces carry GH_TOKEN and whether a `gh` invoked
    #     WITHOUT it would fall through to the system credential store (and so
    #     activate gnome-keyring) — the state that produced the 2026-09-23
    #     10:52:57 keyring prompt, which nothing here was surfacing.
    __oc_report_gh_credential_surface "$cache"

    # 5. Decide whether the gateway needs a restart (its env changed). The
    #    restart is DEFERRED to step 7, after the NAS mirror: a gateway-hosted
    #    run (automation or agent-spawned exec) lives inside THIS service's
    #    cgroup, so restarting the gateway kills this script mid-flight and
    #    silently drops every later step (observed 2026-09-13: the NAS mirror
    #    never ran because the helper died at the restart).
    local _gw_restart_needed=0
    if (( _OC_GW_ENV_CHANGED == 1 )) && command -v openclaw >/dev/null 2>&1 && systemctl --user is-active -q openclaw-gateway.service 2>/dev/null
    then
        _gw_restart_needed=1
    fi

    # 6. The NAS mirror is its own command now (`oc export-keys-nas`): a backup job
    #    — one SSH connection, its own connect timeout, its own retry and marker —
    #    had no business inside a key refresh. It must not go stale unseen, so say
    #    when it is BEHIND rather than silently doing nothing. The marker records the
    #    CACHE hash, the same one compared here, so this is an exact question.
    local _cache_hash _mirror_hash
    _cache_hash=$(grep '^export ' "$cache" | sort | sha256sum | awk '{print $1}')
    _mirror_hash=$(cat "$TAC_CACHE_DIR/tac_win_api_keys.nas_hash" 2>/dev/null || echo none)
    if [[ "$_cache_hash" != "$_mirror_hash" ]]
    then
        __tac_info "NAS mirror" "[behind — run 'oc export-keys-nas' to sync it]" "$C_Warning"
    fi

    # 6. Restart the gateway LAST, once every durable side effect (manager env,
    #    SecretRefs) is committed — see the block below for why this is now a
    #    plain systemctl restart.
    if (( _gw_restart_needed == 1 ))
    then
        # 2026-09-22 (simplification): this block used to run `openclaw gateway
        # restart` inside an embedded bash body, from either a detached unit or a
        # scope, and classify SIX outcomes. Two of those outcomes were the same
        # fact: the CLI's own 45 s readiness probe cannot pass on a box whose cold
        # start runs to minutes (measured: ~2 min 51 s). Worse, the CLI's restart
        # raced the state-lifecycle lock — the stability bundles record it in order
        # (restart_shutdown_timeout → startup_failed → systemd's Restart= recovering
        # it). systemd's own restart is serial: the stop completes before the start,
        # so that overlap cannot arise, and --no-block keeps a slow cold start from
        # hanging the caller. This is the last step, so a gateway-hosted run that
        # dies here loses only its own final log line.
        local _gw_state="" _i
        if systemctl --user restart --no-block openclaw-gateway.service 2>/dev/null
        then
            # A bounded settle, not a readiness wait: the unit reports active as
            # soon as the process is spawned, which is well before it serves.
            for _i in 1 2 3 4 5 6 7 8 9 10
            do
                _gw_state=$(systemctl --user is-active openclaw-gateway.service 2>/dev/null)
                [[ "$_gw_state" == "active" || "$_gw_state" == "failed" ]] && break
                sleep 1
            done
            case "$_gw_state" in
                active) __tac_info "Gateway" "[restarted to pick up refreshed env]" "$C_Success" ;;
                failed) __tac_info "Gateway" "[restart FAILED — env is applied; check 'systemctl --user status openclaw-gateway.service']" "$C_Error" ;;
                *)      __tac_info "Gateway" "[restart issued; unit is $_gw_state — it finishes coming up on its own]" "$C_Warning" ;;
            esac
        else
            __tac_info "Gateway" "[restart NOT issued — env is applied; run 'systemctl --user restart openclaw-gateway.service']" "$C_Warning"
        fi
    fi
}

# ---------------------------------------------------------------------------
# oc-rotate-exposed-secrets — Exposure response helper for bash-errors.log.
# Usage:
#   oc rotate-secrets
#   oc rotate-secrets --sanitize-log
# ---------------------------------------------------------------------------
function oc-rotate-exposed-secrets() {
    local _log="$ErrorLogPath"
    local _sanitize=0
    [[ "${1:-}" == "--sanitize-log" ]] && _sanitize=1

    if [[ ! -f "$_log" ]]
    then
        __tac_info "Secrets Exposure" "[no log file found: $_log]" "$C_Warning"
        return 0
    fi

    local _count
    _count=$(rg -n "OPENCLAW_GATEWAY_PASSWORD|authkey=|tskey-|(^|[[:space:]])-a[[:space:]]+[A-Za-z0-9._-]{8,}|SSHPASS=|Bearer[[:space:]]+[A-Za-z0-9._=-]+|password=|token=" "$_log" 2>/dev/null | wc -l)

    printf '%s\n' "${C_Highlight}Exposure Response Checklist${C_Reset}"
    printf '%s\n' "  1) Rotate OpenClaw gateway auth credentials"
    printf '%s\n' "  2) Rotate Tailscale auth keys if they appeared in command history/logs"
    printf '%s\n' "  3) Rotate Redis/other CLI password args used with '-a'"
    printf '%s\n' "  4) Re-run: oc rotate-secrets --sanitize-log"
    printf '%s\n' "  5) Validate: rg -n 'authkey=|tskey-|OPENCLAW_GATEWAY_PASSWORD| -a ' $_log"
    __tac_info "Secrets Exposure" "[${_count} potential match(es) detected]" "$C_Warning"

    if (( _sanitize == 0 ))
    then
        return 0
    fi

    local _backup
    _backup="${_log}.pre-sanitize.$(date +%Y%m%d_%H%M%S)"
    cp "$_log" "$_backup" || return 1

    sed -E \
        -e 's/(OPENCLAW_GATEWAY_PASSWORD=)[^[:space:]]+/\1<redacted>/g' \
        -e 's/(--authkey=)tskey-[^[:space:]">]+/\1<redacted>/g' \
        -e 's/([?&]authkey=)[^[:space:]"&]+/\1<redacted>/g' \
        -e 's/(SSHPASS=)[^[:space:]]+/\1<redacted>/g' \
        -e 's/([Bb]earer[[:space:]]+)[A-Za-z0-9._=-]+/\1<redacted>/g' \
        -e 's/([[:space:]]-a[[:space:]]+)[^[:space:]]+/\1<redacted>/g' \
        -e 's/((password|token|api[_-]?key)=)[^[:space:]"]+/\1<redacted>/Ig' \
        "$_backup" > "$_log"

    __tac_info "Secrets Exposure" "[sanitized log in place; backup: $_backup]" "$C_Success"
}

# end of file

# end of file
