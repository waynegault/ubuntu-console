# shellcheck shell=bash
# shellcheck disable=SC2034,SC2059,SC2154
# ─── Module: 08-maintenance ───────────────────────────────────────────────────────
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# TACTICAL_PROFILE_VERSION auto-computes from the sum of all module versions.
# Module Version: 5
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
#
# RACE CONDITION FIX: Uses flock for exclusive access to CooldownDB during
# check+set to prevent two parallel `up` runs from both passing the check.
# ---------------------------------------------------------------------------
# Module-level sink variable for nameref when caller doesn't provide one.
# This ensures __check_cooldown works even if caller doesn't declare _cd_sink.
_cd_sink=""
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

    # Use flock for exclusive access to prevent race conditions
    local last_run diff
    {
        flock -x 200 || return 1
        last_run=$(grep "^${key}=" "$CooldownDB" 2>/dev/null | tail -n 1 | cut -d= -f2)
        last_run=${last_run:-0}
        diff=$(( now - last_run ))
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
    } 200>"$CooldownDB.lock"
}

# ---------------------------------------------------------------------------
# __set_cooldown — Record that a maintenance task was just completed.
# Usage: __set_cooldown <key> <now_timestamp>
# RACE CONDITION FIX: Uses flock for exclusive access during update.
# ---------------------------------------------------------------------------
function __set_cooldown() {
    local key="$1" now="$2"
    mkdir -p "$(dirname "$CooldownDB")" 2>/dev/null || true
    # Rewrite the cooldown database: remove old entry, append new timestamp.
    # Use flock for exclusive access to prevent race conditions with __check_cooldown
    {
        flock -x 200 || return 1
        {
            grep -v "^${key}=" "$CooldownDB" 2>/dev/null
            echo "${key}=${now}"
        } > "${CooldownDB}.tmp" && mv "${CooldownDB}.tmp" "$CooldownDB"
    } 200>"$CooldownDB.lock"
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

    # Validate: reject unexpected arguments
    if [[ $# -gt 1 ]]
    then
        __tac_info "Usage" "[up [--force|-f]]" "$C_Error"
        return 1
    fi

    command clear
    __tac_header "SYSTEM MAINTENANCE" "open"
    local errCount=0
    local now
    now=$(date +%s)

    # Performance tracking: record start time for metrics
    local start_time=$now

    # hours_left is set by __check_cooldown via nameref (no subshell needed).
    # When __check_cooldown returns 1 (still cooling down), hours_left holds
    # the remaining time string (e.g. "6d 12h").
    local hours_left=""
    # _cd_sink is module-level (declared above) — no need to redeclare
    touch "$CooldownDB" 2>/dev/null

    # Performance tracking: record start time
    local start_time=$now

    # [1/13] Connectivity
    if ping -c 1 -W 2 github.com >/dev/null 2>&1
    then
        __tac_line "[1/13] Internet Connectivity" "[ESTABLISHED]" "$C_Success"
    else
        __tac_line "[1/13] Internet Connectivity" "[LOST]" "$C_Error"
        ((errCount++))
    fi

    # [2/13] APT Index Update (24h cooldown) + Package Upgrade (7d cooldown)
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
        # Dry-run first to detect dependency issues before actual upgrade
        if ! sudo apt upgrade --dry-run -y --no-install-recommends >/dev/null 2>&1
        then
            __tac_line "[2/13] APT Packages" "[DRY-RUN FAILED]" "$C_Warning"
            ((errCount++))
        else
            sudo apt upgrade -y --no-install-recommends >/dev/null 2>&1
            local apt_rc=$?
            if (( apt_rc == 0 ))
            then
                sudo apt autoremove -y >/dev/null 2>&1
                __tac_line "[2/13] APT Packages" "[UPDATED]" "$C_Success"
                __set_cooldown "apt" "$now"
                __set_cooldown "apt_index" "$now"  # upgrade implies fresh index
            else
                __tac_line "[2/13] APT Packages" "[FAILED]" "$C_Error"
                ((errCount++))
            fi
        fi
    else
        if (( apt_did_update ))
        then
            __tac_line "[2/13] APT Index" "[REFRESHED]" "$C_Success"
        else
            __tac_line "[2/13] APT Packages" "[CACHED - ${hours_left} LEFT]" "$C_Dim"
        fi
    fi

    # [3/13] NPM / Cargo
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
                    __tac_line "[3/13] NPM Packages" "[UPDATED]" "$C_Success"
                else
                    __tac_line "[3/13] NPM Packages" "[FAILED]" "$C_Warning"
                    pkg_err=1
                fi
            else
                __tac_line "[3/13] NPM Packages" "[NO GLOBAL PACKAGES]" "$C_Dim"
                npm_did_update=1  # Nothing to update = success
            fi
        else
            __tac_line "[3/13] NPM Packages" "[NOT INSTALLED]" "$C_Dim"
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
                    __tac_line "[4/13] Cargo Crates" "[UPDATED]" "$C_Success"
                else
                    __tac_line "[4/13] Cargo Crates" "[FAILED]" "$C_Warning"
                    pkg_err=1
                fi
            else
                __tac_line "[4/13] Cargo Crates" "[SKIP - install cargo-update]" "$C_Dim"
                cargo_did_update=1  # Tool not installed = skip, not failure
            fi
        else
            __tac_line "[4/13] Cargo Crates" "[NOT INSTALLED]" "$C_Dim"
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
        __tac_line "[3/13] NPM Packages" "[CACHED - ${hours_left} LEFT]" "$C_Dim"
        __tac_line "[4/13] Cargo Crates" "[CACHED - ${hours_left} LEFT]" "$C_Dim"
    fi

    # [5/13] R Packages (CRAN + Bioconductor)
    # Uses Windows PowerShell script to avoid lock directory issues when running from WSL.
    if __check_cooldown "r_pkgs" "$now" hours_left "$force_mode"
    then
        local r_err=0 r_did_update=0
        local ps1_script="/mnt/c/Programs/bat Files/update-r-packages.ps1"

        # Check if PowerShell is available
        if command -v powershell.exe >/dev/null 2>&1
        then
            # Check if our helper script exists
            if [[ -f "$ps1_script" ]]
            then
                # Get package count before update (for verification)
                local pkg_count_before
                local _ps_cmd="& { (Get-InstalledModule -ErrorAction SilentlyContinue).Count"
                _ps_cmd+=" + (Get-Package -ProviderName NuGet -ErrorAction SilentlyContinue).Count }"
                pkg_count_before=$(timeout 30 powershell.exe -NoProfile -NonInteractive \
                    -Command "$_ps_cmd" 2>/dev/null || echo "0")

                # Run the Windows PowerShell script
                local update_output
                update_output=$(timeout 300 powershell.exe -NoProfile -NonInteractive -File "$ps1_script" 2>&1)
                local ps_rc=$?

                if (( ps_rc == 0 )) || [[ "$update_output" == *"SUCCESS"* ]]
                then
                    r_did_update=1
                    # Verify by checking if update message appeared
                    local _verified=0
                    [[ "$update_output" == *"Updating R packages"* ]] && _verified=1
                    [[ "$update_output" == *"successfully unpacked"* ]] && _verified=1
                    [[ "$update_output" == *"updated index"* ]] && _verified=1
                    if (( _verified == 1 ))
                    then
                        __tac_line "[5/13] R Packages" "[UPDATED - Verified]" "$C_Success"
                    else
                        __tac_line "[5/13] R Packages" "[UPDATED]" "$C_Success"
                    fi
                elif [[ "$update_output" == *"ERROR"* ]] || (( ps_rc != 0 ))
                then
                    r_err=1
                    __tac_line "[5/13] R Packages" "[FAILED]" "$C_Warning"
                else
                    r_did_update=1
                    __tac_line "[5/13] R Packages" "[NO UPDATE NEEDED]" "$C_Dim"
                fi
            else
                # Helper script not found - skip with helpful message
                r_did_update=1
                __tac_line "[5/13] R Packages" "[SKIP - PS1 helper missing]" "$C_Dim"
            fi
        else
            # PowerShell not available - try direct R (legacy fallback)
            local _rscript=""
            if command -v Rscript >/dev/null 2>&1
            then
                _rscript="Rscript"
            else
                # WSL fallback: Windows R
                local _win_r
                for _win_r in "/mnt/c/Program Files/R"/R-*/bin/x64/Rscript.exe; do
                    [[ -x "$_win_r" ]] && _rscript="$_win_r"
                done
            fi

            if [[ -n "$_rscript" ]]
            then
                local pkg_count
                pkg_count=$(timeout 10 "$_rscript" -e 'cat(length(installed.packages()))' 2>/dev/null || echo "0")

                if [[ "$pkg_count" -gt 1 ]]
                then
                    r_did_update=1
                    __tac_line "[5/13] R Packages" "[SKIP - Run from Windows]" "$C_Dim"
                else
                    r_did_update=1
                    __tac_line "[5/13] R Packages" "[NO USER PACKAGES]" "$C_Dim"
                fi
            else
                __tac_line "[5/13] R Packages" "[NOT INSTALLED]" "$C_Dim"
            fi
        fi

        if (( r_err == 0 && r_did_update == 1 ))
        then
            __set_cooldown "r_pkgs" "$now"
        elif (( r_err == 1 ))
        then
            ((errCount++))
        fi
    else
        __tac_line "[5/13] R Packages" "[CACHED - ${hours_left} LEFT]" "$C_Dim"
    fi

    # [6/13] OpenClaw verification — runs 'openclaw doctor' for real health check.
    # --non-interactive: skip all prompts (safe for unattended maintenance).
    # --no-workspace-suggestions: suppress noisy "workspace not optimised" hints.
    if __check_cooldown "openclaw" "$now" hours_left "$force_mode"
    then
        if [[ "$__TAC_OPENCLAW_OK" == "1" ]]
        then
            local doc_rc
            timeout 30 openclaw doctor --non-interactive --no-workspace-suggestions >/dev/null 2>&1
            doc_rc=$?
            if (( doc_rc == 0 ))
            then
                __tac_line "[6/13] OpenClaw Framework" "[HEALTHY]" "$C_Success"
            elif (( doc_rc == 124 ))
            then
                __tac_line "[6/13] OpenClaw Framework" "[TIMED OUT]" "$C_Warning"
                ((errCount++))
            else
                __tac_line "[6/13] OpenClaw Framework" "[ISSUES FOUND - run oc doc-fix]" "$C_Warning"
                ((errCount++))
            fi
            __set_cooldown "openclaw" "$now"
        else
            __tac_line "[6/13] OpenClaw Framework" "[NOT INSTALLED]" "$C_Dim"
        fi
    else
        __tac_line "[6/13] OpenClaw Framework" "[CACHED - ${hours_left} LEFT]" "$C_Dim"
    fi

    # [7/13] OpenClaw Plugin Updates — pull latest from upstream for path-installed plugins.
    # Checks gigabrain, lossless-claw, and OpenStinger for git updates.
    if __check_cooldown "oc_plugins" "$now" hours_left "$force_mode"
    then
        local plugin_updated=0 plugin_err=0
        local plugins_dir="$HOME/.openclaw/extensions"
        local vendor_dir="$HOME/.openclaw/vendor"

        # gigabrain plugin update check
        if [[ -d "$plugins_dir/gigabrain" ]]
        then
            if [[ -d "$plugins_dir/gigabrain/.git" ]]
            then
                # Full git repo — pull from upstream
                local gb_remote
                gb_remote=$(git -C "$plugins_dir/gigabrain" remote get-url origin 2>/dev/null || echo "")
                if [[ "$gb_remote" == *"legendaryvibecoder/gigabrain"* ]]
                then
                    if git -C "$plugins_dir/gigabrain" pull --ff-only >/dev/null 2>&1
                    then
                        __tac_line "[7/13] Gigabrain Plugin" "[UPDATED]" "$C_Success"
                        plugin_updated=1
                    else
                        __tac_line "[7/13] Gigabrain Plugin" "[UP TO DATE]" "$C_Dim"
                    fi
                else
                    __tac_line "[7/13] Gigabrain Plugin" "[SKIP - custom remote]" "$C_Dim"
                fi
            else
                __tac_line "[7/13] Gigabrain Plugin" "[SKIP - not a git repo]" "$C_Dim"
            fi
        else
            __tac_line "[7/13] Gigabrain Plugin" "[NOT INSTALLED]" "$C_Dim"
        fi

        # lossless-claw plugin update check
        if [[ -d "$plugins_dir/lossless-claw" ]]
        then
            if [[ -d "$plugins_dir/lossless-claw/.git" ]]
            then
                # Full git repo — pull from upstream
                local lc_remote
                lc_remote=$(git -C "$plugins_dir/lossless-claw" remote get-url origin 2>/dev/null || echo "")
                if [[ "$lc_remote" == *"Martian-Engineering/lossless-claw"* ]]
                then
                    if git -C "$plugins_dir/lossless-claw" pull --ff-only >/dev/null 2>&1
                    then
                        __tac_line "[8/13] Lossless-Claw Plugin" "[UPDATED]" "$C_Success"
                        plugin_updated=1
                    else
                        __tac_line "[8/13] Lossless-Claw Plugin" "[UP TO DATE]" "$C_Dim"
                    fi
                else
                    __tac_line "[8/13] Lossless-Claw Plugin" "[SKIP - custom remote]" "$C_Dim"
                fi
            else
                __tac_line "[8/13] Lossless-Claw Plugin" "[SKIP - not a git repo]" "$C_Dim"
            fi
        else
            __tac_line "[8/13] Lossless-Claw Plugin" "[NOT INSTALLED]" "$C_Dim"
        fi

        # OpenStinger update check
        if [[ -d "$vendor_dir/openstinger" ]]
        then
            if [[ -d "$vendor_dir/openstinger/.git" ]]
            then
                # Full git repo — pull from upstream
                local os_remote
                os_remote=$(git -C "$vendor_dir/openstinger" remote get-url origin 2>/dev/null || echo "")
                if [[ "$os_remote" == *"srikanthbellary/openstinger"* ]]
                then
                    if git -C "$vendor_dir/openstinger" pull --ff-only >/dev/null 2>&1
                    then
                        __tac_line "[9/13] OpenStinger" "[UPDATED]" "$C_Success"
                        plugin_updated=1
                    else
                        __tac_line "[9/13] OpenStinger" "[UP TO DATE]" "$C_Dim"
                    fi
                else
                    __tac_line "[9/13] OpenStinger" "[SKIP - custom remote]" "$C_Dim"
                fi
            else
                __tac_line "[9/13] OpenStinger" "[SKIP - not a git repo]" "$C_Dim"
            fi
        else
            __tac_line "[9/13] OpenStinger" "[NOT INSTALLED]" "$C_Dim"
        fi

        if (( plugin_updated == 1 ))
        then
            __set_cooldown "oc_plugins" "$now"
        else
            __tac_line "[7/13] OpenClaw Plugins" "[ALL UP TO DATE]" "$C_Dim"
        fi
    else
        __tac_line "[7/13] OpenClaw Plugins" "[CACHED - ${hours_left} LEFT]" "$C_Dim"
    fi

    # [8/13] Python Venv (a.k.a. "Cloaking" = active virtual environment isolation)
    if [[ -n "$VIRTUAL_ENV" ]]
    then
        __tac_line "[8/13] Python Venv Cloaking" "[$(basename "$VIRTUAL_ENV")]" "$C_Success"
    else
        __tac_line "[8/13] Python Venv Cloaking" "[INACTIVE]" "$C_Dim"
    fi

    # [9/13] Python Fleet
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
            __tac_line "[9/13] Python Fleet" "[${v_list[*]} VERIFIED]" "$C_Success"
            __set_cooldown "pyfleet" "$now"
        else
            __tac_line "[9/13] Python Fleet" "[NO VERSIONS DETECTED]" "$C_Warning"
            ((errCount++))
        fi
    else
        __tac_line "[9/13] Python Fleet" "[CACHED - ${hours_left} LEFT]" "$C_Dim"
    fi

    # [10/13] GPU Checks — __get_gpu returns CSV or a sentinel string.
    # Sentinels: "N/A" (no nvidia-smi), "Querying..." (first-boot cache miss),
    # or contains "OFFLINE" (driver crash / WSL GPU passthrough failure).
    local gpu
    gpu=$(__get_gpu)

    if [[ "$gpu" != "N/A" && "$gpu" != "Querying..." && "$gpu" != *"OFFLINE"* ]]
    then
        __tac_line "[11/13] RTX 3050 Ti" "[READY]" "$C_Success"
    else
        __tac_line "[10/13] GPU Status" "[OFFLINE OR ERROR]" "$C_Warning"
        ((errCount++))
    fi

    # [11/13] Sanitation — clean known temp locations, NOT the user's $PWD.
    # Only removes temp artifacts from /tmp/openclaw and the OC_ROOT directory.
    local count=0
    if [[ -d /tmp/openclaw ]]
    then
        while IFS= read -r -d '' _tmpf
        do
            rm -f "$_tmpf" && ((count++))
        done < <(find /tmp/openclaw \( -name '*.tmp' -o -name 'python-*.exe' \) -print0 2>/dev/null)
    fi
    __tac_line "[12/13] Temp File Sanitation" "[$count CLEANED]" "$C_Success"

    # [12/13] Disk Space Audit — warn if any mount point exceeds 90%
    local disk_warn=0
    while read -r pct mount
    do
        local pct_num=${pct%\%}
        # Validate pct_num is numeric before comparison
        [[ ! "$pct_num" =~ ^[0-9]+$ ]] && continue
        if (( pct_num >= 90 ))
        then
            __tac_line "[13/13] Disk: $mount" "[${pct} USED - LOW SPACE]" "$C_Error"
            disk_warn=1
            ((errCount++))
        fi
    done < <(df -h --output=pcent,target 2>/dev/null \
        | tail -n +2 | grep -v '/snap/' \
        | grep -v '/mnt/wsl/docker-desktop')
    (( disk_warn == 0 )) && __tac_line "[13/13] Disk Space Audit" "[ALL MOUNTS < 90%]" "$C_Success"

    # [14/17] Stale Process Cleanup — kill orphaned llama-server instances.
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
            __tac_line "[14/17] Stale Processes" "[${stale_count} BOOTING - GRACE PERIOD]" "$C_Dim"
        else
            pkill -u "$USER" -x llama-server 2>/dev/null
            rm -f "$ACTIVE_LLM_FILE"
            __tac_line "[14/17] Stale Processes" "[$stale_count ORPHAN(S) KILLED]" "$C_Warning"
        fi
    else
        __tac_line "[14/17] Stale Processes" "[CLEAN]" "$C_Success"
    fi

    # [15/17] Documentation drift guard — lightweight README accuracy check.
    if __check_cooldown "docs_sync" "$now" hours_left "$force_mode"
    then
        if __docs_sync_check
        then
            __tac_line "[15/17] README Sync" "[OK]" "$C_Success"
        else
            __tac_line "[15/17] README Sync" "[DRIFT DETECTED]" "$C_Warning"
            ((errCount++))
        fi
        __set_cooldown "docs_sync" "$now"
    else
        __tac_line "[15/17] README Sync" "[CACHED - ${hours_left} LEFT]" "$C_Dim"
    fi

    # [16/17] Docker Prune — clean unused containers, images, and build cache.
    if command -v docker >/dev/null 2>&1
    then
        local docker_freed
        docker_freed=$(docker system prune -f --volumes 2>&1 \
            | grep "Total reclaimed space" \
            | grep -oP '[\d.]+[MGK]B' || echo "")
        if [[ -n "$docker_freed" ]]
        then
            __tac_line "[16/17] Docker Prune" "[FREED $docker_freed]" "$C_Success"
        else
            __tac_line "[16/17] Docker Prune" "[CLEAN]" "$C_Dim"
        fi
    else
        __tac_line "[16/17] Docker Prune" "[SKIP - Docker not installed]" "$C_Dim"
    fi

    # [17/17] NPM Cache Clean — verify and clean npm cache.
    if command -v npm >/dev/null 2>&1
    then
        local npm_cache_result
        npm_cache_result=$(npm cache verify 2>&1 | grep -E "Cache cleaned|Cache size" || echo "")
        if [[ "$npm_cache_result" == *"Cache cleaned"* ]]
        then
            local cleaned_size
            cleaned_size=$(echo "$npm_cache_result" | grep -oP '[\d.]+[MGK]B' || echo "unknown")
            __tac_line "[17/17] NPM Cache Clean" "[FREED $cleaned_size]" "$C_Success"
        elif [[ "$npm_cache_result" == *"Cache size"* ]]
        then
            __tac_line "[17/17] NPM Cache Clean" "[NO ACTION NEEDED]" "$C_Dim"
        else
            __tac_line "[17/17] NPM Cache Clean" "[VERIFIED]" "$C_Dim"
        fi
    else
        __tac_line "[17/17] NPM Cache Clean" "[SKIP - NPM not installed]" "$C_Dim"
    fi

    __tac_divider
    if (( errCount > 0 ))
    then
        __tac_line "Maintenance Status" "[COMPLETED WITH $errCount ISSUE(S)]" "$C_Warning"
    else
        __tac_line "Maintenance Status" "[SYSTEMS AT PEAK PARITY]" "$C_Success"
    fi

    # Performance summary: show total execution time
    local total_time=$(( $(date +%s) - start_time ))
    __tac_line "Execution Time" "[${total_time}s]" "$C_Dim"

    # Write metrics to file for trend analysis
    local metrics_file="$OC_ROOT/maintenance-history.csv"
    mkdir -p "$(dirname "$metrics_file")" 2>/dev/null
    echo "$(date -Iseconds),$total_time,$errCount" >> "$metrics_file" 2>/dev/null

    __tac_footer
}

# ---------------------------------------------------------------------------
# cl — Quick cleanup without the full maintenance run.
# Usage: cl [--light] [--report] [--yes]
#   --light:  Only clean python cache (old behavior)
#   --report: Show what could be cleaned (no deletion)
#   --yes:    Skip confirmation prompts
# ---------------------------------------------------------------------------
function cl() {
    local light_mode=0 report_mode=0 yes_mode=0

    # Parse arguments
    while [[ $# -gt 0 ]]
    do
        case "$1" in
            --light|-l) light_mode=1 ;;
            --report|-r) report_mode=1 ;;
            --yes|-y) yes_mode=1 ;;
            *) __tac_info "Usage" "[cl [--light] [--report] [--yes]]" "$C_Error"; return 1 ;;
        esac
        shift
    done

    # Report mode: show what could be cleaned without deleting
    if (( report_mode == 1 ))
    then
        __tac_header "CLEANUP REPORT" "open"

        # Current directory debris
        local pwd_debris=0
        if [[ -d .pytest_cache ]] || compgen -G "python-*.exe" > /dev/null
        then
            pwd_debris=1
            __tac_line "Python cache in $PWD" "[FOUND]" "$C_Warning"
        else
            __tac_line "Python cache in $PWD" "[CLEAN]" "$C_Success"
        fi

        # Broken symlinks
        local broken_links
        broken_links=$(find ~ -xtype l 2>/dev/null | wc -l)
        if (( broken_links > 0 ))
        then
            __tac_line "Broken symlinks in ~" "[$broken_links found]" "$C_Warning"
        else
            __tac_line "Broken symlinks in ~" "[NONE]" "$C_Success"
        fi

        # PATH ghosts (Linux side)
        local path_ghosts=0
        local IFS=':'
        local ghost_paths=()
        for p in $PATH
        do
            if [[ -n "$p" && ! -d "$p" ]]
            then
                ((path_ghosts++))
                ghost_paths+=("$p")
            fi
        done
        if (( path_ghosts > 0 ))
        then
            __tac_line "Non-existent PATH entries" "[$path_ghosts ghosts]" "$C_Warning"
            # Show first 3 ghost paths as examples
            local i
            for (( i=0; i<path_ghosts && i<3; i++ ))
            do
                __tac_info "  Ghost" "${ghost_paths[$i]}" "$C_Dim"
            done
            if (( path_ghosts > 3 ))
            then
                __tac_info "  ..." "+$((path_ghosts - 3)) more" "$C_Dim"
            fi
            # Find where PATH is set (check common locations)
            local path_source=""
            if grep -q "export PATH=" "$HOME/.bashrc" 2>/dev/null
            then
                path_source="$HOME/.bashrc"
            elif grep -q "export PATH=" "$TACTICAL_REPO_ROOT/scripts/"*.sh 2>/dev/null
            then
                path_source=$(grep -l "export PATH=" "$TACTICAL_REPO_ROOT/scripts/"*.sh 2>/dev/null | head -1)
            fi
            if [[ -n "$path_source" ]]
            then
                __tac_info "  PATH set in" "$path_source" "$C_Dim"
                __tac_info "  Fix" "Edit $path_source manually" "$C_Dim"
            else
                __tac_info "  Fix" "Search for 'export PATH=' in profile files" "$C_Dim"
            fi
        else
            __tac_line "Non-existent PATH entries" "[NONE]" "$C_Success"
        fi

        # Windows System PATH ghosts (WSL-specific check)
        local win_ghosts=()
        local IFS=':'
        for p in $PATH
        do
            if [[ "$p" == "/mnt/c/"* ]] && [[ ! -d "$p" ]]
            then
                # Convert to Windows format
                local win_path
                win_path=$(echo "$p" | sed 's|/mnt/c/|C:\\|' | sed 's|/|\\|g')
                win_ghosts+=("$win_path")
            fi
        done
        if (( ${#win_ghosts[@]} > 0 ))
        then
            __tac_line "Windows System PATH ghosts" "[${#win_ghosts[@]} found]" "$C_Warning"
            for wg in "${win_ghosts[@]}"
            do
                __tac_info "  Windows" "$wg" "$C_Dim"
            done
            __tac_info "  Fix" "Run PowerShell script below (admin)" "$C_Dim"
        fi

        # Systemd ghost units
        if command -v systemctl >/dev/null 2>&1
        then
            local systemd_ghosts
            systemd_ghosts=$(systemctl --user list-units --all --state=not-found 2>/dev/null \
                | grep -c "not-found" || echo 0)
            if (( systemd_ghosts > 0 ))
            then
                __tac_line "Systemd ghost units" "[$systemd_ghosts not-found]" "$C_Warning"
            else
                __tac_line "Systemd ghost units" "[NONE]" "$C_Success"
            fi
        fi

        # APT cache
        if command -v apt-get >/dev/null 2>&1
        then
            local apt_size
            apt_size=$(du -sh /var/cache/apt/archives 2>/dev/null | cut -f1 || echo "0")
            __tac_line "APT cache size" "[$apt_size]" "$C_Text"
        fi

        # Brew cache
        if command -v brew >/dev/null 2>&1
        then
            local brew_size
            brew_size=$(brew cleanup --dry-run 2>&1 | grep -oP '[\d.]+[MGK]B' | head -1 || echo "0")
            __tac_line "Brew reclaimable" "[$brew_size]" "$C_Text"
        fi

        # Journal logs
        if command -v journalctl >/dev/null 2>&1
        then
            local journal_size
            journal_size=$(journalctl --disk-usage 2>&1 | grep -oP '[\d.]+[MGK]B' || echo "0")
            __tac_line "Journal logs" "[$journal_size]" "$C_Text"
        fi

        # Docker (if installed)
        if command -v docker >/dev/null 2>&1
        then
            local docker_size
            docker_size=$(docker system df 2>&1 | grep "Images" | awk '{print $4}' || echo "0")
            __tac_line "Docker images" "[$docker_size]" "$C_Text"
        fi

        __tac_footer

        # If Windows ghosts found, show PowerShell cleanup script
        if (( ${#win_ghosts[@]} > 0 ))
        then
            printf '\n%s\n' "${C_Highlight}--- PowerShell Cleanup (Run as ADMIN) ---${C_Reset}"
            printf '%s\n' "${C_Dim}Copy and paste this into Windows PowerShell (Admin):${C_Reset}"
            printf '\n%s\n' "\$GhostList = @("

            # Build ghost list for PowerShell
            local first=1
            for wg in "${win_ghosts[@]}"
            do
                if (( first ))
                then
                    printf "'%s'" "$wg"
                    first=0
                else
                    printf ",'%s'" "$wg"
                fi
            done
            printf '%s\n\n' ");"

            printf '%s\n' "# Function to clean a specific registry path"
            printf '%s\n' "function Clean-RegistryPath (\$RegPath) {"
            printf '%s\n' "    \$Current = (Get-ItemProperty -Path \$RegPath -ErrorAction SilentlyContinue).Path"
            printf '%s\n' "    if (\$Current) {"
            printf '%s\n' "        \$New = (\$Current -split ';' | Where-Object { \
\$_ -and \$GhostList -notcontains \$_ }) -join ';'"
            printf '%s\n' "        Set-ItemProperty -Path \$RegPath -Name 'Path' -Value \$New"
            printf '%s\n' "        return \$true"
            printf '%s\n' "    }"
            printf '%s\n' "    return \$false"
            printf '%s\n' "}"
            printf '\n%s\n' "# Clean User PATH"
            printf '%s\n' "if (Clean-RegistryPath 'Registry::HKEY_CURRENT_USER\Environment') {"
            printf '%s\n' "    Write-Host \"✓ User PATH cleaned.\" -ForegroundColor Green"
            printf '%s\n' "}"
            printf '\n%s\n' "# Clean System PATH"
            printf '%s\n' "if (Clean-RegistryPath 'Registry::HKEY_LOCAL_MACHINE\System\CurrentControlSet\Control\
Session Manager\Environment') {"
            printf '%s\n' "    Write-Host \"✓ System PATH cleaned.\" -ForegroundColor Green"
            printf '%s\n' "}"
            printf '\n%s\n\n' "Write-Host \"DONE! Run 'wsl --shutdown' in Windows to see changes in WSL.\" \
                -ForegroundColor Cyan"
        fi

        return 0
    fi

    # Light mode: only python cache (old behavior)
    if (( light_mode == 1 ))
    then
        local count
        count=$(__cleanup_temps)
        __tac_info "Sanitation..." "[$count artifacts removed]" "$C_Success"
        return 0
    fi

    # Default: Full deep cleanup
    local deep_count=0

    # APT cleanup
    if command -v sudo >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1
    then
        if (( yes_mode == 0 ))
        then
            read -r -e -p "Clean APT cache? [y/N]: " confirm
            if [[ "${confirm,,}" != "y" && "${confirm,,}" != "yes" ]]
            then
                __tac_info "APT cleanup" "[SKIPPED]" "$C_Dim"
            else
                sudo apt-get autoremove -y >/dev/null 2>&1 && sudo apt-get autoclean >/dev/null 2>&1
                __tac_info "APT cleanup" "[COMPLETE]" "$C_Success"
                ((deep_count++))
            fi
        else
            sudo apt-get autoremove -y >/dev/null 2>&1 && sudo apt-get autoclean >/dev/null 2>&1
            __tac_info "APT cleanup" "[COMPLETE]" "$C_Success"
            ((deep_count++))
        fi
    fi

    # Brew cleanup
    if command -v brew >/dev/null 2>&1
    then
        if (( yes_mode == 0 ))
        then
            read -r -e -p "Run brew cleanup? [y/N]: " confirm
            if [[ "${confirm,,}" != "y" && "${confirm,,}" != "yes" ]]
            then
                __tac_info "Brew cleanup" "[SKIPPED]" "$C_Dim"
            else
                brew cleanup --prune=all >/dev/null 2>&1
                __tac_info "Brew cleanup" "[COMPLETE]" "$C_Success"
                ((deep_count++))
            fi
        else
            brew cleanup --prune=all >/dev/null 2>&1
            __tac_info "Brew cleanup" "[COMPLETE]" "$C_Success"
            ((deep_count++))
        fi
    fi

    # Journal vacuum
    if command -v journalctl >/dev/null 2>&1
    then
        if (( yes_mode == 0 ))
        then
            read -r -e -p "Vacuum journal logs (>3 days)? [y/N]: " confirm
            if [[ "${confirm,,}" != "y" && "${confirm,,}" != "yes" ]]
            then
                __tac_info "Journal vacuum" "[SKIPPED]" "$C_Dim"
            else
                journalctl --vacuum-time=3d >/dev/null 2>&1
                __tac_info "Journal vacuum" "[COMPLETE]" "$C_Success"
                ((deep_count++))
            fi
        else
            journalctl --vacuum-time=3d >/dev/null 2>&1
            __tac_info "Journal vacuum" "[COMPLETE]" "$C_Success"
            ((deep_count++))
        fi
    fi

    # Docker cleanup
    if command -v docker >/dev/null 2>&1
    then
        if (( yes_mode == 0 ))
        then
            read -r -e -p "Prune Docker system? [y/N]: " confirm
            if [[ "${confirm,,}" != "y" && "${confirm,,}" != "yes" ]]
            then
                __tac_info "Docker prune" "[SKIPPED]" "$C_Dim"
            else
                docker system prune -f --volumes >/dev/null 2>&1
                __tac_info "Docker prune" "[COMPLETE]" "$C_Success"
                ((deep_count++))
            fi
        else
            docker system prune -f --volumes >/dev/null 2>&1
            __tac_info "Docker prune" "[COMPLETE]" "$C_Success"
            ((deep_count++))
        fi
    fi

    # Systemd ghost reset (safe - just clears failed state)
    if command -v systemctl >/dev/null 2>&1
    then
        systemctl --user reset-failed >/dev/null 2>&1
        __tac_info "Systemd ghosts" "[RESET]" "$C_Success"
        ((deep_count++))
    fi

    # NPM cache cleanup (safe - regenerates on demand)
    if command -v npm >/dev/null 2>&1
    then
        npm cache verify --silent >/dev/null 2>&1
        __tac_info "NPM cache" "[VERIFIED]" "$C_Success"
        ((deep_count++))
    fi

    # Thumbnail cache (safe - regenerates on demand)
    if [[ -d ~/.cache/thumbnails ]]
    then
        rm -rf ~/.cache/thumbnails/* 2>/dev/null
        __tac_info "Thumbnail cache" "[CLEARED]" "$C_Success"
        ((deep_count++))
    fi

    # Trash (safe - user-initiated cleanup)
    if [[ -d ~/.local/share/Trash/files ]]
    then
        rm -rf ~/.local/share/Trash/files/* ~/.local/share/Trash/info/* 2>/dev/null
        __tac_info "Trash" "[EMPTIED]" "$C_Success"
        ((deep_count++))
    fi

    # Broken symlinks (list only, don't auto-delete)
    local broken_links
    broken_links=$(find ~ -xtype l 2>/dev/null | wc -l)
    if (( broken_links > 0 ))
    then
        __tac_info "Broken symlinks" "[$broken_links found]" "$C_Warning"
        # Show first 3 as examples
        local broken_sample
        broken_sample=$(find ~ -xtype l -print 2>/dev/null | head -3)
        while IFS= read -r link
        do
            __tac_info "  Example" "$link" "$C_Dim"
        done <<< "$broken_sample"
        if (( broken_links > 3 ))
        then
            __tac_info "  ..." "+$((broken_links - 3)) more" "$C_Dim"
        fi
        __tac_info "  Fix" "Run 'find ~ -xtype l -delete' manually" "$C_Dim"
    fi

    # Summary
    if (( deep_count > 0 ))
    then
        __tac_info "Deep cleanup" "[$deep_count subsystems cleaned]" "$C_Success"
    else
        __tac_info "Sanitation..." "[No cleanup performed]" "$C_Dim"
    fi
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
