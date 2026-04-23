# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154
# ─── Module: 02-error-handling ───────────────────────────────────────────────────────
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# TACTICAL_PROFILE_VERSION auto-computes from the sum of all module versions.
# Module Version: 5
# ==============================================================================
# 2. ERROR HANDLING
# ==============================================================================
# @modular-section: error-handling
# @depends: constants
# @exports: (none — sets ERR trap only)
#
# Trap ERR to log failed commands with timestamps for post-mortem debugging.
# Exit code 1 is filtered out because grep/test/[[ return 1 for normal
# "not found" / "false" conditions and would flood the log with false positives.
# Only exit codes >= 2 (real errors) are logged.
#
# WHITELIST: Commands that commonly return non-zero for expected reasons.
# These are excluded from logging to reduce noise:
#   - grep, fgrep, egrep: return 1 when no match found (normal operation)
#   - test, [, [[ : return 1 when condition is false (normal operation)
#   - diff, cmp: return 1 when files differ (normal operation)
#   - ping: returns 1 when host unreachable (network diagnostics)
#   - timeout: returns 124 when command times out (expected behavior)
#   - curl: returns 22 for HTTP 404 (expected for API probes)
#   - jq: returns 5 when input is not JSON (expected for probes)
# Extracted to a named function for clarity (traps with inline code are hard to read).
# __tac_last_err intentionally global — traps cannot use `local`.

# Ensure error log directory exists BEFORE setting trap (prevents errors on first use)
mkdir -p "$(dirname "$ErrorLogPath")" 2>/dev/null

function __tac_redact_command() {
    local _cmd="$1"

    # Mask common secret-bearing patterns before persistence to disk.
    _cmd=$(printf '%s' "$_cmd" | sed -E \
        -e 's/(OPENCLAW_GATEWAY_PASSWORD=)[^[:space:]]+/\1<redacted>/g' \
        -e 's/(SSHPASS=)[^[:space:]]+/\1<redacted>/g' \
        -e 's/(--authkey=)tskey-[^[:space:]">]+/\1<redacted>/g' \
        -e 's/([?&]authkey=)[^[:space:]"&]+/\1<redacted>/g' \
        -e 's/([Bb]earer[[:space:]]+)[A-Za-z0-9._=-]+/\1<redacted>/g' \
        -e 's/((password|token|api[_-]?key)=)[^[:space:]"]+/\1<redacted>/gi')

    # Mask redis-style password arg (redis-cli -a secret).
    _cmd=$(printf '%s' "$_cmd" | sed -E 's/([[:space:]]-a[[:space:]]+)[^[:space:]]+/\1<redacted>/g')
    printf '%s' "$_cmd"
}

function __tac_is_internal_noise_command() {
    local _cmd="$1"
    case "$_cmd" in
        ""|"return \"\$1\""|"return 127"|"\"\$@\" 2>&1") return 0 ;;
        "/usr/lib/command-not-found -- \"\$1\"") return 0 ;;
        "custom_prompt_command"|*"BASH_COMMAND"*|*"__tac_err_handler"*) return 0 ;;
        *"__bridge_windows_api_keys"*) return 0 ;;
    esac
    return 1
}

function __tac_emit_shell_hint() {
    local _cmd="$1"
    local _hint_key=""
    local _hint_file="/dev/shm/tac_shell_hint_keys"

    case "$_cmd" in
        Copy-*|Get-*|Set-*|Remove-*|Start-*|Stop-*|taskkill*|powershell*|pwsh*)
            _hint_key="powershell"
            ;;
        cmd.exe*|dir\ *|type\ *|del\ *|setx\ *)
            _hint_key="cmd"
            ;;
        wsl\ *)
            _hint_key="wsl"
            ;;
    esac

    [[ -z "$_hint_key" ]] && return

    if [[ -f "$_hint_file" ]] && grep -qx "$_hint_key" "$_hint_file" 2>/dev/null
    then
        return
    fi

    printf '%s\n' "$_hint_key" >> "$_hint_file" 2>/dev/null || true
    case "$_hint_key" in
        powershell)
            echo "$(date +"%Y-%m-%d %H:%M:%S") [HINT] PowerShell syntax detected in bash. Run via: pwsh -NoProfile -Command '<command>'" >> "$ErrorLogPath" 2>/dev/null
            ;;
        cmd)
            echo "$(date +"%Y-%m-%d %H:%M:%S") [HINT] Windows cmd syntax detected in bash. Run via: cmd.exe /C \"<command>\"" >> "$ErrorLogPath" 2>/dev/null
            ;;
        wsl)
            echo "$(date +"%Y-%m-%d %H:%M:%S") [HINT] 'wsl' command was run inside WSL. Use native Linux command or run from Windows terminal." >> "$ErrorLogPath" 2>/dev/null
            ;;
    esac
}

function __tac_log_dedup_gate() {
    local _signature="$1"
    local _now
    _now=$(date +%s)

    local _sig_file="/dev/shm/tac_err_last_sig"
    local _ts_file="/dev/shm/tac_err_last_sig_ts"
    local _supp_file="/dev/shm/tac_err_suppressed_count"
    local _window=15

    local _last_sig=""
    local _last_ts=0
    local _supp=0

    [[ -f "$_sig_file" ]] && _last_sig=$(< "$_sig_file")
    [[ -f "$_ts_file" ]] && _last_ts=$(< "$_ts_file")
    [[ -f "$_supp_file" ]] && _supp=$(< "$_supp_file")

    if [[ "$_signature" == "$_last_sig" ]] && (( _now - _last_ts < _window ))
    then
        printf '%s' $(( _supp + 1 )) > "$_supp_file" 2>/dev/null || true
        return 1
    fi

    if (( _supp > 0 ))
    then
        echo "$(date +"%Y-%m-%d %H:%M:%S") [INFO] Suppressed ${_supp} duplicate error entrie(s) for previous signature." >> "$ErrorLogPath" 2>/dev/null
    fi

    printf '%s' "$_signature" > "$_sig_file" 2>/dev/null || true
    printf '%s' "$_now" > "$_ts_file" 2>/dev/null || true
    printf '%s' 0 > "$_supp_file" 2>/dev/null || true
    return 0
}

function __tac_ssh_circuit_breaker_allows_log() {
    local _cmd="$1"
    local _err="$2"
    local _now
    _now=$(date +%s)

    case "$_cmd" in
        ssh\ *|ssh)
            ;;
        *)
            return 0
            ;;
    esac

    (( _err == 255 )) || return 0

    local _state_file="/dev/shm/tac_ssh_fail_state"
    local _window=120
    local _trip_after=5
    local _mute_for=180

    local _start=0 _count=0 _mute_until=0
    if [[ -f "$_state_file" ]]
    then
        IFS=' ' read -r _start _count _mute_until < "$_state_file" 2>/dev/null || true
    fi

    if (( _mute_until > _now ))
    then
        return 1
    fi

    if (( _start == 0 || _now - _start > _window ))
    then
        _start="$_now"
        _count=1
    else
        _count=$(( _count + 1 ))
    fi

    if (( _count >= _trip_after ))
    then
        _mute_until=$(( _now + _mute_for ))
        printf '%s %s %s\n' "$_start" "$_count" "$_mute_until" > "$_state_file" 2>/dev/null || true
        echo "$(date +"%Y-%m-%d %H:%M:%S") [SSH-CIRCUIT] Repeated ssh failures detected; suppressing duplicate ssh EXIT 255 logs for ${_mute_for}s." >> "$ErrorLogPath" 2>/dev/null
        return 1
    fi

    printf '%s %s %s\n' "$_start" "$_count" 0 > "$_state_file" 2>/dev/null || true
    return 0
}

function __tac_err_handler() {
    __tac_last_err=$?
    local _raw_cmd="$BASH_COMMAND"
    local _cmd
    _cmd=$(__tac_redact_command "$_raw_cmd")
    local _label="EXIT $__tac_last_err"

    # Skip logging for exit code 1 (common false positives)
    if (( __tac_last_err <= 1 ))
    then
        return
    fi

    # Keep expected shell internals out of the error log.
    if __tac_is_internal_noise_command "$_raw_cmd"
    then
        return
    fi

    # Skip logging for whitelisted commands that return non-zero as normal behavior
    # shellcheck disable=SC2221,SC2222
    case "$_raw_cmd" in
        grep*|fgrep*|egrep*) return ;;  # No match is normal
        test*|\[*|\[\[*) return ;;       # False condition is normal (patterns intentionally overlap)
        diff*|cmp*) return ;;            # Files differ is normal
        ping*) return ;;                  # Host unreachable is diagnostic info
        timeout*) return ;;               # Timeout is expected behavior
        curl*) return ;;                  # HTTP errors are expected for probes
        jq*) return ;;                    # Invalid JSON is expected for probes
        *nvm.sh*) return ;;               # NVM returns exit code 3 when already loaded or in non-interactive shell
    esac

    case "$__tac_last_err" in
        130) _label="INTERRUPTED 130" ;;
        124) _label="TIMEOUT 124" ;;
        127) _label="NOT_FOUND 127" ;;
    esac

    if ! __tac_ssh_circuit_breaker_allows_log "$_raw_cmd" "$__tac_last_err"
    then
        return
    fi

    local _sig="${_label}|$_cmd"
    if ! __tac_log_dedup_gate "$_sig"
    then
        return
    fi

    if (( __tac_last_err == 127 ))
    then
        local _missing
        _missing="${_raw_cmd%% *}"
        if [[ -n "$_missing" ]] && [[ "$_missing" != *"/"* ]] && ! command -v "$_missing" >/dev/null 2>&1
        then
            local _miss_file="/dev/shm/tac_missing_cmd_once"
            if [[ ! -f "$_miss_file" ]] || ! grep -qx "$_missing" "$_miss_file" 2>/dev/null
            then
                printf '%s\n' "$_missing" >> "$_miss_file" 2>/dev/null || true
                echo "$(date +"%Y-%m-%d %H:%M:%S") [MISSING-TOOL] Command not found: ${_missing}. Preflight with: command -v ${_missing}" >> "$ErrorLogPath" 2>/dev/null
            fi
        fi
        __tac_emit_shell_hint "$_raw_cmd"
    fi

    echo "$(date +"%Y-%m-%d %H:%M:%S") [${_label}] ${_cmd}" >> "$ErrorLogPath" 2>/dev/null
}
set -E
trap '__tac_err_handler' ERR


# end of file
