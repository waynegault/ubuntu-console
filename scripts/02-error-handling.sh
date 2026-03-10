# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154
# ─── Module: 02-error-handling ───────────────────────────────────────────────────────
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# TACTICAL_PROFILE_VERSION auto-computes from the sum of all module versions.
# Module Version: 1
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
# Extracted to a named function for clarity (traps with inline code are hard to read).
# __tac_last_err intentionally global — traps cannot use `local`.
function __tac_err_handler() {
    __tac_last_err=$?
    if (( __tac_last_err > 1 ))
    then
        echo "$(date +"%Y-%m-%d %H:%M:%S") [EXIT $__tac_last_err] $BASH_COMMAND" >> "$ErrorLogPath" 2>/dev/null
    fi
}
set -E
trap '__tac_err_handler' ERR


# end of file
