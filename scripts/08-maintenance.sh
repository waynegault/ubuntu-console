# shellcheck shell=bash
# shellcheck disable=SC2034,SC2059,SC2154
# ─── Module: 08-maintenance ───────────────────────────────────────────────────────
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# TACTICAL_PROFILE_VERSION auto-computes from the sum of all module versions.
# Module Version: 4
# ==============================================================================
# 8. MAINTENANCE & UTILS
# ==============================================================================
# @modular-section: maintenance
# @depends: constants, design-tokens, ui-engine, telemetry
# @exports: __cleanup_temps, __check_cooldown, __set_cooldown, get-ip, up, cl,
#   copy_path, sysinfo, logtrim, docs-sync

# ---------------------------------------------------------------------------
# __cleanup_temps — Remove temp files from known safe locations only.
# Only cleans python-*.exe and .pytest_cache from $PWD. Does NOT remove
# *.log files (too dangerous in arbitrary directories). Used by cl().
# ---------------------------------------------------------------------------
function __cleanup_temps() {
    local count=0
    local f
    local _had_nullglob=0; shopt -q nullglob && _had_nullglob=1
    shopt -s nullglob
    for f in python-*.exe .pytest_cache
    do
        if [[ -e "$f" ]]
        then
            rm -rf "$f" && ((count++))
        fi
    done
    (( _had_nullglob )) || shopt -u nullglob
    echo "$count"
}

# ---------------------------------------------------------------------------
# __check_cooldown — Check if a maintenance task's 7-day cooldown has expired.
# Usage: __check_cooldown <key> <now_timestamp> <result_var> [force_mode]
# Returns 0 if cooldown has expired (task should run), 1 if still active.
# On return 1, sets result_var to remaining time (e.g. "6d 12h").
# Uses nameref to avoid subshell overhead (called 5+ times per `up` run).
# Dependencies: $CooldownDB must be set and touchable.
# If force_mode=1, always returns 0 (skip cooldown for testing).
# ---------------------------------------------------------------------------
function __check_cooldown() {
    local key="$1" now="$2" force_mode="${4:-0}"
    local -n __cd_result="${3:-_cd_sink}"

    # Force mode: always run (for testing)
    if (( force_mode == 1 ))
    then
        __cd_result=""
        return 0
    fi

    # Per-key cooldown periods (default 7 days)
    local cooldown
    case "$key" in
        apt_index)  cooldown=$COOLDOWN_DAILY  ;;  # 24 hours - security index
        apt)        cooldown=$COOLDOWN_WEEKLY ;;  # 7 days  - package upgrades
        *)          cooldown=$COOLDOWN_WEEKLY ;;  # 7 days  - everything else
    esac
    local last_run
    last_run=$(grep "^${key}=" "$CooldownDB" 2>/dev/null | tail -n 1 | cut -d= -f2)
    last_run=${last_run:-0}
    local diff=$(( now - last_run ))
    if (( diff < cooldown ))
    then
        local remaining=$(( cooldown - diff ))
        local days=$(( remaining / 86400 ))
        local hours=$(( (remaining % 86400) / 3600 ))
        if (( days > 0 ))
        then
            __cd_result="${days}d ${hours}h"
        else
            __cd_result="${hours}h"
        fi
        return 1
    fi
    __cd_result=""
    return 0
}

# ---------------------------------------------------------------------------
# __set_cooldown — Record that a maintenance task was just completed.
# Usage: __set_cooldown <key> <now_timestamp>
# ---------------------------------------------------------------------------
function __set_cooldown() {
    local key="$1" now="$2"
    mkdir -p "$(dirname "$CooldownDB")" 2>/dev/null || true
    # Rewrite the cooldown database: remove old entry, append new timestamp.
    {
        grep -v "^${key}=" "$CooldownDB" 2>/dev/null
        echo "${key}=${now}"
    } > "${CooldownDB}.tmp" \
        && mv "${CooldownDB}.tmp" "$CooldownDB"
}

# ---------------------------------------------------------------------------
# __docs_sync_check — Compare a few generated repo facts against README.md.
# Lightweight guardrail only: warns on obvious drift, does not rewrite docs.
# @returns 0 if the tracked facts match, 1 if README drift is detected.
# ---------------------------------------------------------------------------
function __docs_sync_check() {
    local readme_path="$TACTICAL_REPO_ROOT/README.md"
    local bats_path="$TACTICAL_REPO_ROOT/tests/tactical-console.bats"
    local env_path="$TACTICAL_REPO_ROOT/env.sh"
    [[ -f "$readme_path" && -f "$bats_path" && -f "$env_path" ]] || return 1

    local expected_tests readme_ok=0
    expected_tests=$(rg -c '^@test ' "$bats_path" 2>/dev/null || grep -c '^@test ' "$bats_path" 2>/dev/null)
    expected_tests=${expected_tests:-0}

    local expected_test_phrase="${expected_tests} BATS unit tests"
    local expected_env_phrase="Non-interactive library loader (all modules except 13-init.sh)"

    if grep -qF "$expected_test_phrase" "$readme_path" \
        && grep -qF "$expected_env_phrase" "$readme_path" \
        && grep -q '\[0-9\]\[0-9\]-\*\.sh' "$env_path"
    then
        readme_ok=1
    fi

    (( readme_ok == 1 ))
}

# ---------------------------------------------------------------------------
# docs-sync — Run a lightweight README drift check against current repo facts.
# @returns 0 if docs are in sync, 1 if drift is detected.
# ---------------------------------------------------------------------------
function docs-sync() {
    if __docs_sync_check
    then
        __tac_info "README Sync" "[OK]" "$C_Success"
        return 0
    fi
    __tac_info "README Sync" "[DRIFT DETECTED - update README.md]" "$C_Warning"
    return 1
}

# ---------------------------------------------------------------------------
# get-ip — Show WSL Ubuntu IP and external WAN IP.
# Renamed from ip() to avoid shadowing /usr/bin/ip (used by WSL loopback fix).
# ---------------------------------------------------------------------------
function get-ip() {
    local wslIp
    wslIp=$(hostname -I | awk '{print $1}')
    [[ -z "$wslIp" ]] && wslIp="UNKNOWN"
    __tac_info "WSL Ubuntu IP" "[$wslIp]" "$C_Success"

    local extIp
    extIp=$(curl -s --connect-timeout 2 https://api.ipify.org)
    [[ -z "$extIp" ]] && extIp="TIMEOUT / UNAVAILABLE"
    local wan_color=$C_Warning
    if [[ $extIp == TIMEOUT* ]]
    then
        wan_color=$C_Error
    fi
    __tac_info "External WAN IP" "[$extIp]" "$wan_color"
}

# ---------------------------------------------------------------------------
# up — Run 12-step system maintenance with cooldowns per step.
# Usage: up [--force]
#   --force: Suspend all cooldowns for testing purposes
# Cooldown functions (__check_cooldown / __set_cooldown) are defined above
# in this section to avoid leaking nested function definitions.
# ---------------------------------------------------------------------------
function up() {
    local force_mode=0
    case "${1:-}" in
        --force|-f) force_mode=1 ;;
    esac

    command clear
    __tac_header "SYSTEM MAINTENANCE" "open"
    local errCount=0
    local now
    now=$(date +%s)
    # hours_left is set by __check_cooldown via nameref (no subshell needed).
    # When __check_cooldown returns 1 (still cooling down), hours_left holds
    # the remaining time string (e.g. "6d 12h").
    local hours_left=""
    local _cd_sink=""  # sink for nameref when no result var is needed
    touch "$CooldownDB" 2>/dev/null

    # [1/12] Connectivity
    if ping -c 1 -W 2 github.com >/dev/null 2>&1
    then
        __tac_line "[1/12] Internet Connectivity" "[ESTABLISHED]" "$C_Success"
    else
        __tac_line "[1/12] Internet Connectivity" "[LOST]" "$C_Error"
        ((errCount++))
    fi

    # [2/12] APT Index Update (24h cooldown) + Package Upgrade (7d cooldown)
    # Logic:
    #   1. If apt_index cooldown (24h) expired → update index only
    #   2. If apt cooldown (7d) expired → upgrade packages (updates index if not already done)
    #   3. If only index was refreshed → show that
    #   4. If both cached → show "CACHED"
    local apt_did_update=0
    if __check_cooldown "apt_index" "$now" hours_left "$force_mode"
    then
        if sudo apt update >/dev/null 2>&1
        then
            apt_did_update=1
            __set_cooldown "apt_index" "$now"
        fi
    fi
    if __check_cooldown "apt" "$now" hours_left "$force_mode"
    then
        (( apt_did_update )) || sudo apt update >/dev/null 2>&1
        sudo apt upgrade -y --no-install-recommends >/dev/null 2>&1
        local apt_rc=$?
        if (( apt_rc == 0 ))
        then
            sudo apt autoremove -y >/dev/null 2>&1
            __tac_line "[2/12] APT Packages" "[UPDATED]" "$C_Success"
            __set_cooldown "apt" "$now"
            __set_cooldown "apt_index" "$now"  # upgrade implies fresh index
        else
            __tac_line "[2/12] APT Packages" "[FAILED]" "$C_Error"
            ((errCount++))
        fi
    else
        if (( apt_did_update ))
        then
            __tac_line "[2/12] APT Index" "[REFRESHED]" "$C_Success"
        else
            __tac_line "[2/12] APT Packages" "[CACHED - ${hours_left} LEFT]" "$C_Dim"
        fi
    fi

    # [3/12] NPM / Cargo
    if __check_cooldown "npm_cargo" "$now" hours_left "$force_mode"
    then
        local npm_did_update=0 cargo_did_update=0 pkg_err=0

        # NPM: Only run if npm is installed and has global packages
        if command -v npm >/dev/null 2>&1
        then
            # Check if there are any global packages to update (exclude npm itself)
            local global_pkgs update_output
            global_pkgs=$(npm list -g --depth=0 2>/dev/null | grep -v "^npm$" | grep -v "^$" | tail -n +2)

            if [[ -n "$global_pkgs" ]]
            then
                update_output=$(npm update -g 2>&1)
                local npm_rc=$?

                # Check for workspace/local package errors (not real failures)
                if (( npm_rc == 0 )) || [[ "$update_output" == *"Workspaces not supported for global packages"* ]]
                then
                    npm_did_update=1
                    __tac_line "[3/12] NPM Packages" "[UPDATED]" "$C_Success"
                else
                    __tac_line "[3/12] NPM Packages" "[FAILED]" "$C_Warning"
                    pkg_err=1
                fi
            else
                __tac_line "[3/12] NPM Packages" "[NO GLOBAL PACKAGES]" "$C_Dim"
                npm_did_update=1  # Nothing to update = success
            fi
        else
            __tac_line "[3/12] NPM Packages" "[NOT INSTALLED]" "$C_Dim"
        fi

        # Cargo: Requires cargo-install-update
        if command -v cargo >/dev/null 2>&1
        then
            # Check if cargo-update is installed (provides cargo-install-update)
            local _has_cargo_update=0
            if command -v cargo-install-update >/dev/null 2>&1
            then
                _has_cargo_update=1
            elif cargo install-update --version >/dev/null 2>&1
            then
                _has_cargo_update=1
            fi

            if (( _has_cargo_update == 1 ))
            then
                if cargo install-update -a >/dev/null 2>&1
                then
                    cargo_did_update=1
                    __tac_line "       Cargo Crates" "[UPDATED]" "$C_Success"
                else
                    __tac_line "       Cargo Crates" "[FAILED]" "$C_Warning"
                    pkg_err=1
                fi
            else
                __tac_line "       Cargo Crates" "[SKIP - install cargo-update]" "$C_Dim"
                cargo_did_update=1  # Tool not installed = skip, not failure
            fi
        else
            __tac_line "       Cargo Crates" "[NOT INSTALLED]" "$C_Dim"
        fi

        # Set cooldown only if both succeeded (or had nothing to update)
        if (( pkg_err == 0 && npm_did_update == 1 && cargo_did_update == 1 ))
        then
            __set_cooldown "npm_cargo" "$now"
        elif (( pkg_err == 1 ))
        then
            ((errCount++))
        fi
    else
        __tac_line "[3/12] NPM Packages" "[CACHED - ${hours_left} LEFT]" "$C_Dim"
        __tac_line "       Cargo Crates" "[CACHED - ${hours_left} LEFT]" "$C_Dim"
    fi

    # [4/12] R Packages (CRAN + Bioconductor)
    if __check_cooldown "r_pkgs" "$now" hours_left "$force_mode"
    then
        local r_err=0 r_did_update=0
        # Resolve Rscript: prefer PATH, then Windows-side install under /mnt/c.
        local _rscript=""
        if command -v Rscript >/dev/null 2>&1
        then
            _rscript="Rscript"
        elif command -v R >/dev/null 2>&1
        then
            _rscript="R"
        else
            # WSL fallback: pick the highest-versioned Rscript.exe on Windows.
            local _win_r
            for _win_r in "/mnt/c/Program Files/R"/R-*/bin/x64/Rscript.exe; do
                [[ -x "$_win_r" ]] && _rscript="$_win_r"
            done
        fi
        if [[ -n "$_rscript" ]]
        then
            # Check if R is responsive (Windows R can timeout)
            local pkg_count
            pkg_count=$(timeout 10 "$_rscript" -e 'cat(length(installed.packages()))' 2>/dev/null || echo "0")

            if [[ "$pkg_count" -gt 1 ]]  # >1 because base packages always exist
            then
                # Run update with timeout and better error handling
                local update_output
                update_output=$(timeout 300 "$_rscript" -e '
                    options(repos = c(CRAN = "https://cloud.r-project.org"))
                    pkgs <- installed.packages()[,1]
                    if (length(pkgs) > 0) {
                        updated <- tryCatch({
                            update.packages(ask=FALSE, checkBuilt=TRUE, Ncpus=1)
                            TRUE
                        }, error=function(e) {
                            cat("ERROR:", conditionMessage(e), "\n", file=stderr())
                            FALSE
                        })
                        if (updated) {
                            if (requireNamespace("BiocManager", quietly=TRUE)) {
                                BiocManager::install(ask=FALSE, update=TRUE)
                            }
                            cat("SUCCESS\n")
                        }
                    } else {
                        cat("NO_PACKAGES\n")
                    }
                ' 2>&1)

                if [[ "$update_output" == *"SUCCESS"* ]]
                then
                    r_did_update=1
                    __tac_line "[4/12] R Packages" "[UPDATED]" "$C_Success"
                elif [[ "$update_output" == *"NO_PACKAGES"* ]]
                then
                    r_did_update=1  # No packages to update = success
                    __tac_line "[4/12] R Packages" "[NO USER PACKAGES]" "$C_Dim"
                elif [[ "$update_output" == *"failed to lock directory"* ]]
                then
                    r_did_update=1  # Lock issue = skip, not failure
                    __tac_line "[4/12] R Packages" "[SKIP - Run from Windows]" "$C_Dim"
                elif [[ "$update_output" == *"TIMED"* ]] || [[ -z "$update_output" && "$pkg_count" == "0" ]]
                then
                    r_did_update=1  # R unresponsive, skip
                    __tac_line "[4/12] R Packages" "[SKIP - R unresponsive]" "$C_Dim"
                else
                    r_err=1
                    __tac_line "[4/12] R Packages" "[FAILED]" "$C_Warning"
                fi
            else
                r_did_update=1  # No packages to update
                __tac_line "[4/12] R Packages" "[NO USER PACKAGES]" "$C_Dim"
            fi
        else
            __tac_line "[4/12] R Packages" "[NOT INSTALLED]" "$C_Dim"
        fi

        if (( r_err == 0 && r_did_update == 1 ))
        then
            __set_cooldown "r_pkgs" "$now"
        elif (( r_err == 1 ))
        then
            ((errCount++))
        fi
    else
        __tac_line "[4/12] R Packages" "[CACHED - ${hours_left} LEFT]" "$C_Dim"
    fi

    # [5/12] OpenClaw verification — runs 'openclaw doctor' for real health check.
    # --non-interactive: skip all prompts (safe for unattended maintenance).
    # --no-workspace-suggestions: suppress noisy "workspace not optimised" hints.
    if __check_cooldown "openclaw" "$now" hours_left "$force_mode"
    then
        if command -v openclaw >/dev/null
        then
            local doc_rc
            timeout 30 openclaw doctor --non-interactive --no-workspace-suggestions >/dev/null 2>&1
            doc_rc=$?
            if (( doc_rc == 0 ))
            then
                __tac_line "[5/12] OpenClaw Framework" "[HEALTHY]" "$C_Success"
            elif (( doc_rc == 124 ))
            then
                __tac_line "[5/12] OpenClaw Framework" "[TIMED OUT]" "$C_Warning"
                ((errCount++))
            else
                __tac_line "[5/12] OpenClaw Framework" "[ISSUES FOUND - run oc doc-fix]" "$C_Warning"
                ((errCount++))
            fi
            __set_cooldown "openclaw" "$now"
        else
            __tac_line "[5/12] OpenClaw Framework" "[MISSING]" "$C_Error"
            ((errCount++))
        fi
    else
        __tac_line "[5/12] OpenClaw Framework" "[CACHED - ${hours_left} LEFT]" "$C_Dim"
    fi

    # [6/12] Python Venv (a.k.a. "Cloaking" = active virtual environment isolation)
    if [[ -n "$VIRTUAL_ENV" ]]
    then
        __tac_line "[6/12] Python Venv Cloaking" "[$(basename "$VIRTUAL_ENV")]" "$C_Success"
    else
        __tac_line "[6/12] Python Venv Cloaking" "[INACTIVE]" "$C_Dim"
    fi

    # [7/12] Python Fleet
    if __check_cooldown "pyfleet" "$now" hours_left "$force_mode"
    then
        local py_versions=()
        local _py
        for _py in /usr/bin/python3.[0-9]*
        do
            [[ -x "$_py" ]] && py_versions+=("$_py")
        done
        if [[ ${#py_versions[@]} -gt 0 ]]
        then
            local v_list=()
            for py in "${py_versions[@]}"
            do
                v_list+=("$(basename "$py")")
            done
            __tac_line "[7/12] Python Fleet" "[${v_list[*]} VERIFIED]" "$C_Success"
            __set_cooldown "pyfleet" "$now"
        else
            __tac_line "[7/12] Python Fleet" "[NO VERSIONS DETECTED]" "$C_Warning"
            ((errCount++))
        fi
    else
        __tac_line "[7/12] Python Fleet" "[CACHED - ${hours_left} LEFT]" "$C_Dim"
    fi

    # [8/12] GPU Checks — __get_gpu returns CSV or a sentinel string.
    # Sentinels: "N/A" (no nvidia-smi), "Querying..." (first-boot cache miss),
    # or contains "OFFLINE" (driver crash / WSL GPU passthrough failure).
    local gpu
    gpu=$(__get_gpu)

    if [[ "$gpu" != "N/A" && "$gpu" != "Querying..." && "$gpu" != *"OFFLINE"* ]]
    then
        __tac_line "[8/12] RTX 3050 Ti" "[READY]" "$C_Success"
    else
        __tac_line "[8/12] GPU Status" "[OFFLINE OR ERROR]" "$C_Warning"
        ((errCount++))
    fi

    # [9/12] Sanitation — clean known temp locations, NOT the user's $PWD.
    # Only removes temp artifacts from /tmp/openclaw and the OC_ROOT directory.
    local count=0
    if [[ -d /tmp/openclaw ]]
    then
        while IFS= read -r -d '' _tmpf
        do
            rm -f "$_tmpf" && ((count++))
        done < <(find /tmp/openclaw \( -name '*.tmp' -o -name 'python-*.exe' \) -print0 2>/dev/null)
    fi
    __tac_line "[9/12] Temp File Sanitation" "[$count CLEANED]" "$C_Success"

    # [10/12] Disk Space Audit — warn if any mount point exceeds 90%
    local disk_warn=0
    while read -r pct mount
    do
        local pct_num=${pct%\%}
        if (( pct_num >= 90 ))
        then
            __tac_line "[10/12] Disk: $mount" "[${pct} USED - LOW SPACE]" "$C_Error"
            disk_warn=1
            ((errCount++))
        fi
    done < <(df -h --output=pcent,target 2>/dev/null \
        | tail -n +2 | grep -v '/snap/' \
        | grep -v '/mnt/wsl/docker-desktop')
    (( disk_warn == 0 )) && __tac_line "[10/12] Disk Space Audit" "[ALL MOUNTS < 90%]" "$C_Success"

    # [11/12] Stale Process Cleanup — kill orphaned llama-server instances.
    # Skip if the active model state file was touched < 60s ago (still booting).
    # Per-PID check: only kill processes that are NOT listening on LLM_PORT.
    local stale_pids
    stale_pids=$(pgrep -x llama-server 2>/dev/null)
    local stale_count=0
    if [[ -n "$stale_pids" ]] && ! __test_port "$LLM_PORT"
    then
        stale_count=$(echo "$stale_pids" | wc -l)
        local _state_age=999
        if [[ -f "$ACTIVE_LLM_FILE" ]]
        then
            _state_age=$(( $(date +%s) - $(stat -c %Y "$ACTIVE_LLM_FILE" 2>/dev/null || echo 0) ))
        fi
        if (( _state_age < 60 ))
        then
            __tac_line "[11/12] Stale Processes" "[${stale_count} BOOTING - GRACE PERIOD]" "$C_Dim"
        else
            pkill -u "$USER" -x llama-server 2>/dev/null
            rm -f "$ACTIVE_LLM_FILE"
            __tac_line "[11/12] Stale Processes" "[$stale_count ORPHAN(S) KILLED]" "$C_Warning"
        fi
    else
        __tac_line "[11/12] Stale Processes" "[CLEAN]" "$C_Success"
    fi

    # [12/12] Documentation drift guard — lightweight README accuracy check.
    if __check_cooldown "docs_sync" "$now" hours_left "$force_mode"
    then
        if __docs_sync_check
        then
            __tac_line "[12/12] README Sync" "[OK]" "$C_Success"
        else
            __tac_line "[12/12] README Sync" "[DRIFT DETECTED]" "$C_Warning"
            ((errCount++))
        fi
        __set_cooldown "docs_sync" "$now"
    else
        __tac_line "[12/12] README Sync" "[CACHED - ${hours_left} LEFT]" "$C_Dim"
    fi

    __tac_divider
    if (( errCount > 0 ))
    then
        __tac_line "Maintenance Status" "[COMPLETED WITH $errCount ISSUE(S)]" "$C_Warning"
    else
        __tac_line "Maintenance Status" "[SYSTEMS AT PEAK PARITY]" "$C_Success"
    fi
    __tac_footer
}

# ---------------------------------------------------------------------------
# cl — Quick cleanup without the full maintenance run.
# ---------------------------------------------------------------------------
function cl() {
    local dry_run=0
    case "${1:-}" in
        --dry-run|-n) dry_run=1 ;;
    esac

    if (( dry_run ))
    then
        local count=0
        local f
        local _had_nullglob=0; shopt -q nullglob && _had_nullglob=1
        shopt -s nullglob
        for f in python-*.exe .pytest_cache
        do
            [[ -e "$f" ]] && ((count++))
        done
        (( _had_nullglob )) || shopt -u nullglob
        __tac_info "Sanitation..." "[$count artifacts would be removed]" "$C_Warning"
        return 0
    fi

    local count
    count=$(__cleanup_temps)
    __tac_info "Sanitation..." "[$count artifacts removed]" "$C_Success"
}

# ---------------------------------------------------------------------------
# copy_path — Copy the current working directory to the Windows clipboard.
# ---------------------------------------------------------------------------
function copy_path() {
    pwd | tr -d '\r\n' | clip.exe 2>/dev/null
    __tac_info "Clipboard" "[$(pwd)]" "$C_Success"
}

# ---------------------------------------------------------------------------
# sysinfo — One-line hardware summary without the full dashboard.
# Usage: sysinfo
# ---------------------------------------------------------------------------
function sysinfo() {
    local host_raw
    host_raw=$(__get_host_metrics)
    local cpu gpu0 gpu1
    IFS='|' read -r cpu gpu0 gpu1 <<< "$host_raw"
    # Ensure numeric values for arithmetic (guard against stale/malformed cache)
    [[ "$cpu"  =~ ^[0-9]+$ ]] || cpu=0
    [[ "$gpu0" =~ ^[0-9]+$ ]] || gpu0=0
    [[ "$gpu1" =~ ^[0-9]+$ ]] || gpu1=0
    local mem_used mem_total mem_pct
    read -r mem_used mem_total mem_pct \
        <<< "$(free -m | awk 'NR==2{printf "%.1f %.1f %d", $3/1024, $2/1024, $3*100/$2}')"
    local disk
    disk=$(df -h / | awk 'NR==2{print $4}' | sed 's/\([0-9.]\)G/\1 Gb/;s/\([0-9.]\)M/\1 Mb/')
    local gpu_raw
    gpu_raw=$(__get_gpu)
    local gpu_info="N/A" gpu_color=$C_Dim
    if [[ "$gpu_raw" != "N/A" && "$gpu_raw" != "Querying..." ]]
    then
        local _g_name g_temp g_util _g_mu _g_mt
        IFS=',' read -r _g_name g_temp g_util _g_mu _g_mt <<< "$gpu_raw"
        # Strip whitespace from nvidia-smi CSV fields
        g_util=${g_util// /}
        # Strip trailing % sign for numeric comparison
        g_util=${g_util%%%}
        # Strip whitespace from temperature
        g_temp=${g_temp// /}
        gpu_info="${g_util}%/${g_temp}${DEGREE}C"
        gpu_color=$(__threshold_color "$g_util")
    fi
    # CPU colour
    local cpu_color
    cpu_color=$(__threshold_color "$cpu")
    # Memory colour
    local mem_color
    mem_color=$(__threshold_color "$mem_pct")
    # GPU1 colour (same thresholds as CPU/GPU0)
    local gpu1_color
    gpu1_color=$(__threshold_color "$gpu1")
    # Design tokens are already ANSI-C quoted ($'\e[…]'), so echo -e is
    # unnecessary. Using printf avoids any accidental backslash interpretation.
    # Build the sysinfo line in segments for readability.
    local _sysline=""
    _sysline+="${C_Dim}CPU:${C_Reset} ${cpu_color}${cpu}%${C_Reset} "
    _sysline+="${C_Dim}RAM:${C_Reset} ${mem_color}${mem_used} / ${mem_total} Gb${C_Reset} "
    _sysline+="${C_Dim}Disk:${C_Reset} ${disk} "
    _sysline+="${C_Dim}iGPU:${C_Reset} ${gpu_color}${gpu_info}${C_Reset} "
    _sysline+="${C_Dim}CUDA:${C_Reset} ${gpu1_color}${gpu1}%${C_Reset}"
    printf '%s\n' "$_sysline"
}

# ---------------------------------------------------------------------------
# logtrim — Trim logs larger than 1 MB to their last 1000 lines.
# ---------------------------------------------------------------------------
function logtrim() {
    local total=0
    local _had_nullglob=0; shopt -q nullglob && _had_nullglob=1
    shopt -s nullglob
    for logfile in "$OC_LOGS"/*.log "$ErrorLogPath" "$LLM_LOG_FILE"
    do
        if [[ -f "$logfile" ]] && (( $(stat -c%s "$logfile" 2>/dev/null || echo 0) > LOG_MAX_BYTES ))
        then
            tail -n 1000 "$logfile" > "${logfile}.tmp" || continue
            [[ -s "${logfile}.tmp" ]] || { rm -f "${logfile}.tmp"; continue; }
            mv "${logfile}.tmp" "$logfile" || { rm -f "${logfile}.tmp"; continue; }
            ((total++))
        fi
    done
    (( _had_nullglob )) || shopt -u nullglob
    __tac_info "Trimmed Logs (>1 Mb)" "[$total files]" "$C_Success"
}


# end of file
