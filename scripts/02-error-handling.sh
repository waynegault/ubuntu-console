# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154
# ─── Module: 02-error-handling ───────────────────────────────────────────────────────
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# TACTICAL_PROFILE_VERSION auto-computes from the sum of all module versions.
# Module Version: 2
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
function __tac_err_handler() {
    __tac_last_err=$?
    
    # Skip logging for exit code 1 (common false positives)
    if (( __tac_last_err <= 1 ))
    then
        return
    fi
    
    # Skip logging for whitelisted commands that return non-zero as normal behavior
    # shellcheck disable=SC2221,SC2222
    case "$BASH_COMMAND" in
        grep*|fgrep*|egrep*) return ;;  # No match is normal
        test*|\[*|\[\[*) return ;;       # False condition is normal (patterns intentionally overlap)
        diff*|cmp*) return ;;            # Files differ is normal
        ping*) return ;;                  # Host unreachable is diagnostic info
        timeout*) return ;;               # Timeout is expected behavior
        curl*) return ;;                  # HTTP errors are expected for probes
        jq*) return ;;                    # Invalid JSON is expected for probes
    esac
    
    echo "$(date +"%Y-%m-%d %H:%M:%S") [EXIT $__tac_last_err] $BASH_COMMAND" >> "$ErrorLogPath" 2>/dev/null
}
set -E
trap '__tac_err_handler' ERR


# end of file
