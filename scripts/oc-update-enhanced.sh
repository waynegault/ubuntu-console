#!/usr/bin/env bash
# ==============================================================================
# oc-update-enhanced — Enhanced OpenClaw updater helper
# ==============================================================================
# AI INSTRUCTION: Increment version on significant changes.
# Module Version: 1
#
# Behavior:
# - Runs `openclaw update` directly.
# - If update fails with a permissions error, attempts ownership repair on
#   common OpenClaw state/config/cache directories (via sudo when available),
#   then retries once.

set -u

_print() {
    printf '%s\n' "$*"
}

_run_update() {
    local _out _rc
    _out=$(openclaw update 2>&1)
    _rc=$?
    printf '%s\n' "$_out"
    return "$_rc"
}

_looks_like_permission_error() {
    local _text="${1:-}"
    [[ "$_text" =~ [Pp]ermission[[:space:]]denied ]] \
        || [[ "$_text" =~ [Oo]peration[[:space:]]not[[:space:]]permitted ]] \
        || [[ "$_text" =~ [Nn]ot[[:space:]]permitted ]] \
        || [[ "$_text" =~ EACCES ]] \
        || [[ "$_text" =~ EPERM ]]
}

_repair_ownership() {
    local _changed=0
    local _dir
    local _dirs=(
        "$HOME/.openclaw"
        "$HOME/.cache/openclaw"
        "$HOME/.config/openclaw"
    )

    if ! command -v sudo >/dev/null 2>&1
    then
        _print "[oc-update-enhanced] sudo not available; cannot auto-repair permissions."
        return 1
    fi

    for _dir in "${_dirs[@]}"
    do
        [[ -e "$_dir" ]] || continue

        if [[ ! -w "$_dir" ]]
        then
            _print "[oc-update-enhanced] repairing ownership: $_dir"
            if sudo chown -R "$USER:$USER" "$_dir" >/dev/null 2>&1
            then
                _changed=1
            fi
        fi
    done

    (( _changed == 1 ))
}

if ! command -v openclaw >/dev/null 2>&1
then
    _print "[oc-update-enhanced] openclaw CLI is not installed or not on PATH."
    exit 1
fi

_print "[oc-update-enhanced] checking for updates..."
update_output="$(_run_update)"
update_rc=$?
printf '%s\n' "$update_output"

if (( update_rc == 0 ))
then
    _print "[oc-update-enhanced] update completed."
    exit 0
fi

if ! _looks_like_permission_error "$update_output"
then
    _print "[oc-update-enhanced] update failed (non-permission error)."
    exit "$update_rc"
fi

_print "[oc-update-enhanced] permission issue detected; attempting automatic repair."
if ! _repair_ownership
then
    _print "[oc-update-enhanced] no permissions were changed; retry skipped."
    exit "$update_rc"
fi

_print "[oc-update-enhanced] retrying update after repair..."
retry_output="$(_run_update)"
retry_rc=$?
printf '%s\n' "$retry_output"

if (( retry_rc == 0 ))
then
    _print "[oc-update-enhanced] update completed after repair."
    exit 0
fi

_print "[oc-update-enhanced] update still failed after repair."
exit "$retry_rc"
