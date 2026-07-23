# shellcheck shell=bash
# shellcheck disable=SC2034,SC2120,SC2154,SC2015,SC2016,SC1090
# --- Module: 09d-oc-agents ---
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 2
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
    local _warn_once_file="/dev/shm/tac_pwsh_bridge_warned"

    # Stateful downgrade: if pwsh.exe is unavailable, warn once per session.
    if ! command -v pwsh.exe >/dev/null 2>&1
    then
        if [[ ! -f "$_warn_once_file" ]]
        then
            printf '%s\n' "$(date +%s)" > "$_warn_once_file" 2>/dev/null || true
            echo "$(date +"%Y-%m-%d %H:%M:%S") [WARN] __bridge_windows_api_keys: pwsh.exe unavailable; bridge downgraded for this session." >> "$ErrorLogPath" 2>/dev/null
        fi
        return 0
    fi

    # Use cached exports if fresh enough
    if [[ -f "$cache" ]] && (( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || echo 0) < ttl ))
    then
        source "$cache" 2>/dev/null
        return
    fi

    # Fetch matching vars from Windows User environment via PowerShell.
    # Intentional narrow match: API key names, token names, and the gateway
    # password (exact name) so it too is bridged from the canonical Windows env.
    local raw
    raw=$(timeout 5 pwsh.exe -NoProfile -NonInteractive -Command '
        [Environment]::GetEnvironmentVariables("User").GetEnumerator() |
        Where-Object { $_.Key -match "(?i)(TOKEN|API(_|-)?KEY|^OPENCLAW_GATEWAY_PASSWORD$)" } |
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
    source "$cache" 2>/dev/null
    rm -f "$_warn_once_file" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# __oc_upsert_env_kv — Create or update KEY="value" entry in an env file.
# Preserves other lines exactly; rewrites only the matching key line.
# ---------------------------------------------------------------------------
function __oc_upsert_env_kv() {
    local _file="$1"
    local _key="$2"
    local _val="$3"

    [[ -z "$_file" || -z "$_key" ]] && return 1
    [[ ! "$_key" =~ ^[A-Z_][A-Z0-9_]*$ ]] && return 1

    mkdir -p "$(dirname "$_file")"
    [[ -f "$_file" ]] || : > "$_file"

    local _tmp
    _tmp="${_file}.tmp.$$"

    awk -v k="$_key" -v v="$_val" '
        BEGIN { done=0 }
        {
            if ($0 ~ "^" k "=") {
                gsub(/\\/, "\\\\", v)
                gsub(/"/, "\\\"", v)
                print k "=\"" v "\""
                done=1
            } else {
                print $0
            }
        }
        END {
            if (!done) {
                gsub(/\\/, "\\\\", v)
                gsub(/"/, "\\\"", v)
                print k "=\"" v "\""
            }
        }
    ' "$_file" > "$_tmp" && mv "$_tmp" "$_file"
}

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

    local -a _map=(
        "models.providers.qwen-token-plan.apiKey::QWEN_TOKEN_PLAN_API_KEY"
        "plugins.entries.google.config.webSearch.apiKey::GEMINI_API_KEY"
    )

    local _entry _path _var _applied=0 _skipped=0 _failed=0
    for _entry in "${_map[@]}"
    do
        _path="${_entry%%::*}"
        _var="${_entry##*::}"
        if [[ -z "${!_var:-}" ]]
        then
            _skipped=$((_skipped + 1))
            continue
        fi
        if openclaw config set "$_path" --ref-provider default --ref-source env --ref-id "$_var" >/dev/null 2>&1
        then
            _applied=$((_applied + 1))
        else
            _failed=$((_failed + 1))
        fi
    done

    if (( _failed > 0 ))
    then
        __tac_info "Syncing OpenClaw SecretRefs" "[$_applied applied, $_skipped skipped, $_failed failed]" "$C_Warning"
    else
        __tac_info "Syncing OpenClaw SecretRefs" "[$_applied applied, $_skipped skipped]" "$C_Success"
    fi
}

# ---------------------------------------------------------------------------
# oc-refresh-keys — Force re-import of Windows API keys into WSL, persist to
# systemd env, and sync OpenClaw SecretRefs to the refreshed env credentials.
# The Windows User environment is the canonical source; local copies (.env,
# gateway.systemd.env, auth profiles) reference it rather than holding their
# own plaintext values.
# ---------------------------------------------------------------------------
function oc-refresh-keys() {
    local cache="$TAC_CACHE_DIR/tac_win_api_keys"
    local envd_dir="$HOME/.config/environment.d"
    local envd_file="$envd_dir/90-openclaw.conf"
    local _nas_collectors_env="/mnt/HD/HD_a2/butler/cron/openclaw-collectors.env"
    local _nas_user="${OC_NAS_USER:-sshd}"
    local _nas_host="${OC_NAS_HOST:-192.168.33.17}"
    local _nas_key="${OC_NAS_KEY_PATH:-$HOME/.ssh/jarvis_sshd_key}"

    # 1. Pull matching vars from Windows User environment
    if ! command -v pwsh.exe >/dev/null 2>&1
    then
        __tac_info "Reading Windows User environment" "[pwsh.exe unavailable — bridge cannot refresh]" "$C_Warning"
        return 1
    fi

    rm -f "$cache"
    __bridge_windows_api_keys
    if [[ ! -f "$cache" ]]; then
        __tac_info "Reading Windows User environment" "[no vars found — is pwsh.exe available?]" "$C_Warning"
        return 1
    fi

    local count
    count=$(grep -c '^export ' "$cache" || true)
    __tac_info "Reading Windows User environment" "[$count variable(s) imported]" "$C_Success"

    # 2. Write WSL environment.d file and reload systemd user env
    mkdir -p "$envd_dir"
    awk '/^export / { sub(/^export /, ""); print }' "$cache" > "$envd_file.tmp" 2>/dev/null || true
    mv "$envd_file.tmp" "$envd_file" 2>/dev/null || true
    chmod 600 "$envd_file" 2>/dev/null || true
    systemctl --user daemon-reload 2>/dev/null || true
    while IFS= read -r _line; do
        [[ -z "$_line" ]] && continue
        _name="${_line%%=*}"
        _val="${_line#*=}"
        [[ "$_val" == \"*\" ]] && _val="${_val:1:-1}"
        systemctl --user set-environment "${_name}=${_val}" 2>/dev/null || true
    done < "$envd_file"
    __tac_info "Exporting to WSL" "[$envd_file]" "$C_Success"

    # 3. Sync OpenClaw SecretRefs to the refreshed env credentials
    __oc_apply_secret_refs

    # 4. Mirror vars to NAS via SSH
    if [[ -f "$_nas_key" ]] && command -v ssh >/dev/null 2>&1; then
        local _synced_nas=0
        local _k _v _qv
        while IFS= read -r _line; do
            [[ "$_line" =~ ^export[[:space:]]+ ]] || continue
            _k="${_line#export }"; _k="${_k%%=*}"
            [[ "$_k" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
            _v="${!_k:-}"
            [[ -n "$_v" ]] || continue
            printf -v _qv '%q' "$_v"
            if ssh -n -i "$_nas_key" -o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=no \
                "${_nas_user}@${_nas_host}" \
                "sh -c 'f=\"$_nas_collectors_env\"; [ -f \"\$f\" ] || : > \"\$f\"; \
                 if grep -q \"^$_k=\" \"\$f\"; then \
                     sed -i \"s|^$_k=.*|$_k=\\\"${_qv}\\\"|\" \"\$f\"; \
                 else printf \"%s\\n\" \"$_k=\\\"${_qv}\\\"\" >> \"\$f\"; fi'" >/dev/null 2>&1
            then
                ((_synced_nas++))
            fi
        done < "$cache"
        __tac_info "Exporting to NAS" "[$_nas_collectors_env]" "$C_Success"
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