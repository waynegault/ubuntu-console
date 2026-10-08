# shellcheck shell=bash
# -----------------------------------------------------------------------------
# Module: 14-wsl-extras
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# TACTICAL_PROFILE_VERSION auto-computes from the sum of all module versions.
# Module Version: 9
# 14. WSL EXTRAS & STARTUP HELPERS
# -----------------------------------------------------------------------------
# Purpose: Move WSL/X11 and OpenClaw startup helpers out of the thin loader.
# This module centralises a few WSL-specific startup helpers that were
# incorrectly placed in ~/.bashrc (the thin loader). It is safe, idempotent,
# and guarded so it won't break interactive shells.
# @modular-section: wsl-extras
# @depends: constants
# @exports: __tac_install_shim, __tac_install_pwsh_shims, __tac_ensure_wsl_conf (internal helpers — the module is otherwise side-effects only)

# __tac_install_shim <dest> — write an executable wrapper from stdin, atomically.
# Writing straight to the destination (`cat > dest && chmod +x dest`) is not
# atomic: an interrupted write leaves an executable but truncated stub, and the
# `[[ ! -x <dest> ]]` guard would then treat it as already installed. Write a
# temp file beside the target, make it executable, then rename it into place.
function __tac_install_shim() {
    local _dest="$1" _tmp
    _tmp=$(mktemp "$_dest.XXXXXX") || {
        printf '%s\n' "[wsl-extras] warning: cannot create a temp file beside $_dest" >&2
        return 1
    }
    # 755 explicitly: mktemp creates 600, and `chmod +x` on that yields 711 —
    # which drops the read bit a script needs, so other users could not run it.
    if cat > "$_tmp" && chmod 755 "$_tmp" && mv -f "$_tmp" "$_dest"
    then
        return 0
    fi
    rm -f "$_tmp"
    printf '%s\n' "[wsl-extras] warning: failed to install the shim at $_dest" >&2
    return 1
}

# __tac_install_pwsh_shims — install the PowerShell wrappers (idempotent).
# Defined outside the interactive guard so it can be exercised directly; it is
# only CALLED from the interactive section below.
function __tac_install_pwsh_shims() {
    # PowerShell wrappers so WSL shells can reliably call Windows PowerShell / pwsh.
    if [[ ! -x "$HOME/.local/bin/powershell.exe" ]]; then
        mkdir -p "$HOME/.local/bin"
        __tac_install_shim "$HOME/.local/bin/powershell.exe" <<'EOF'
#!/usr/bin/env bash
exec /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe "$@"
EOF
    fi
    if [[ ! -x "$HOME/.local/bin/pwsh" ]]; then
        mkdir -p "$HOME/.local/bin"
        __tac_install_shim "$HOME/.local/bin/pwsh" <<'EOF'
#!/usr/bin/env bash
exec '/mnt/c/Program Files/PowerShell/7/pwsh.exe' "$@"
EOF
    fi
    # The bridge (__bridge_windows_api_keys / ockeys / oc-refresh-keys) resolves
    # PowerShell as `pwsh.exe`, so it needs a wrapper under that exact name too.
    # /etc/wsl.conf sets [interop] appendWindowsPath = false, so a bare `pwsh.exe`
    # never resolves; this wrapper is what makes `command -v pwsh.exe` succeed.
    if [[ ! -x "$HOME/.local/bin/pwsh.exe" ]]; then
        mkdir -p "$HOME/.local/bin"
        __tac_install_shim "$HOME/.local/bin/pwsh.exe" <<'EOF'
#!/usr/bin/env bash
exec '/mnt/c/Program Files/PowerShell/7/pwsh.exe' "$@"
EOF
    fi
}

# __tac_ensure_wsl_conf — own /etc/wsl.conf's three required keys, and SAY SO when it repairs one.
#
# WHY THIS EXISTS (2026-10-08).  /etc/wsl.conf was found truncated to a bare `[network]` block (the
# file's mtime was 09:12 that day) having lost `[boot] systemd=true` and `[interop] appendWindowsPath
# = false`.  The consequence was not cosmetic: with no systemd the box came back with PID 1 as WSL's
# own init, so NOTHING was supervised — the Gateway, the 36 user units and the three
# actions.runner.*.service CI listeners were all down — and `loopback0` vanished, because its own
# enabled unit had nothing to run it.  Nothing tracked this file, so the only symptom on a fresh
# shell was a loopback warning that the banner then cleared.
#
# The file is wayne-owned, so a repair needs no sudo; but a repair only takes effect at boot, which
# is why this REPORTS loudly instead of writing quietly.  TAC_WSL_CONF overrides the path so a test
# can drive the whole thing hermetically.
function __tac_ensure_wsl_conf() {
    local _conf="${TAC_WSL_CONF:-/etc/wsl.conf}" _key
    local -a _missing=()
    for _key in "generateResolvConf = false" "systemd=true" "appendWindowsPath = false"; do
        grep -qF "$_key" "$_conf" || _missing+=("$_key")
    done
    if (( ${#_missing[@]} == 0 )); then
        return 0
    fi
    if [[ -e "$_conf" ]] && ! cp -p "$_conf" "$_conf.bak-$(date +%Y%m%d-%H%M%S)"; then
        __wsl_warn "[wsl-extras] WARNING: cannot back up $_conf — leaving it alone"
        return 1
    fi
    if ! cat > "$_conf" <<'WSLCONF'
[network]
generateResolvConf = false
[boot]
systemd=true
[interop]
appendWindowsPath = false
WSLCONF
    then
        __wsl_warn "[wsl-extras] WARNING: cannot write $_conf"
        return 1
    fi
    __wsl_warn \
        "[wsl-extras] RESTORED $_conf — it was missing: ${_missing[*]}" \
        "  With no [boot] systemd=true nothing supervises the fleet (Gateway, user units, CI runners)." \
        "  TAKES EFFECT AT BOOT: restart WSL (Windows side: wsl --shutdown, then reopen)."
    return 0
}

# __wsl_warn <line>... — write warnings to stderr through ONE place.
# The redirection sits on the loop's `done`, not on an `echo`/`printf` line, because §18.3 item
# 10.7 counts hand-written `>&2` on those and asks for a helper.  Two or more warnings is where
# a helper pays for itself; a single one does not, which is why the file's older sites remain.
function __wsl_warn() {
    local _line
    for _line in "$@"; do
        printf '%s\n' "$_line"
    done >&2
}

# Interactive guard — many modules are sourced only for interactive shells
case $- in
    *i*) ;;
      *) return ;;
esac

# Optional helper: load credential vault exports if present (the loader will perform
# safe decryption and export only valid variable names). This keeps
# secrets out of ~/.bashrc and in the existing vault mechanism.
_TAC_LOAD_VAULT=${TAC_LOAD_VAULT:-1}
if [[ "$_TAC_LOAD_VAULT" != "0" && -f "$HOME/.openclaw/credentials/vault/load-vault-env.sh" ]]; then
    if [[ -n "${DEBUG_TAC_STARTUP:-}" ]]; then
        _t0=$(date +%s%N 2>/dev/null || echo 0)
        printf '14: loading vault env... ' >&2
    fi
    # The load script may perform decryption or external commands; guard
    # errors so the interactive shell doesn't fail startup.
    # shellcheck disable=SC1091
    source "$HOME/.openclaw/credentials/vault/load-vault-env.sh" 2>/dev/null || true
    if [[ -n "${DEBUG_TAC_STARTUP:-}" ]]; then
        _t1=$(date +%s%N 2>/dev/null || echo 0)
        if [[ "$_t0" != "0" && "$_t1" != "0" ]]; then
            _ms=$(( (_t1 - _t0) / 1000000 ))
            printf 'done (%d ms)\n' "$_ms" >&2
        else
            printf 'done\n' >&2
        fi
        unset _t0 _t1 _ms
    fi
fi

# WSL X11 / DISPLAY helper (idempotent). Uses the distro's /etc/resolv.conf
# to find the host IP assigned by Windows and export DISPLAY accordingly.
if [[ -r /etc/resolv.conf ]]; then
    if [[ -n "${DEBUG_TAC_STARTUP:-}" ]]; then
        _t0=$(date +%s%N 2>/dev/null || echo 0)
        printf '14: resolving host IP for DISPLAY... ' >&2
    fi
    hostip=$(awk '/^nameserver/ {print $2; exit}' /etc/resolv.conf 2>/dev/null || true)
    if [[ -n "$hostip" ]]; then
        export DISPLAY="${hostip}:0"
        # Intentionally omit `xhost` to avoid blocking or leaking X access
        # during interactive shell startup.
    fi
    if [[ -n "${DEBUG_TAC_STARTUP:-}" ]]; then
        _t1=$(date +%s%N 2>/dev/null || echo 0)
        if [[ "$_t0" != "0" && "$_t1" != "0" ]]; then
            _ms=$(( (_t1 - _t0) / 1000000 ))
            printf 'done (%d ms)\n' "$_ms" >&2
        else
            printf 'done\n' >&2
        fi
        unset _t0 _t1 _ms
    fi
fi

# Ensure local user bin is on PATH — already handled in 01-constants.sh, which
# always loads first; kept out of here to avoid a dead duplicate branch.

# WSL-friendly credential storage workaround for Electron-based tooling
# (for example VS Code launched from this shell). In headless/WSL sessions,
# desktop keyrings often don't prompt reliably; `basic` avoids keyring prompts.
if grep -qi microsoft /proc/version 2>/dev/null; then
    export PASSWORD_STORE="${PASSWORD_STORE:-basic}"
fi

# NVM loading disabled - OpenClaw uses Homebrew, not NVM
# export NVM_DIR="$HOME/.nvm"
# if [[ -s "$NVM_DIR/nvm.sh" ]]; then
#     . "$NVM_DIR/nvm.sh"
# fi
# if [[ -s "$NVM_DIR/bash_completion" ]]; then
#     . "$NVM_DIR/bash_completion"
# fi


# Install the PowerShell wrappers (defined above the interactive guard so they
# can be unit-tested).
__tac_install_pwsh_shims
__tac_ensure_wsl_conf

# NOTE: Do NOT place secrets (API keys, passwords) in this file. Use the
# credential vault at ~/.openclaw/credentials/vault instead.

# end of file

# end of file marker
