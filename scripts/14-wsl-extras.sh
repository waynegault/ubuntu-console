# shellcheck shell=bash
# -----------------------------------------------------------------------------
# Module: 14-wsl-extras
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# TACTICAL_PROFILE_VERSION auto-computes from the sum of all module versions.
# Module Version: 5
# -----------------------------------------------------------------------------
# Purpose: Move WSL/X11 and OpenClaw startup helpers out of the thin loader.
# This module centralises a few WSL-specific startup helpers that were
# incorrectly placed in ~/.bashrc (the thin loader). It is safe, idempotent,
# and guarded so it won't break interactive shells.
# @modular-section: wsl-extras
# @depends: constants
# @exports: (none — side-effects only: loads completions, sets up X11/WSL env)

# Interactive guard — many modules are sourced only for interactive shells
case $- in
    *i*) ;;
      *) return ;;
esac

# Source OpenClaw completions if they exist
if [[ -f "$HOME/.openclaw/completions/openclaw.bash" ]]; then
    if [[ -n "${DEBUG_TAC_STARTUP:-}" ]]; then
        _t0=$(date +%s%N 2>/dev/null || echo 0)
        printf '14: sourcing openclaw completions... ' >&2
    fi
    # Use a guarded source to avoid errors when the file is missing.
    # shellcheck disable=SC1091
    source "$HOME/.openclaw/completions/openclaw.bash" 2>/dev/null || true
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

# Ensure local user bin is on PATH without polluting the thin ~/.bashrc loader.
if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    export PATH="$HOME/.local/bin:$PATH"
fi

# WSL-friendly credential storage workaround for Electron-based tooling
# (for example VS Code launched from this shell). In headless/WSL sessions,
# desktop keyrings often don't prompt reliably; `basic` avoids keyring prompts.
if grep -qi microsoft /proc/version 2>/dev/null; then
    export PASSWORD_STORE="${PASSWORD_STORE:-basic}"
fi

# NVM loading disabled - OpenClaw uses Homebrew, not NVM
# export NVM_DIR="$HOME/.nvm"
# if [[ -s "$NVM_DIR/nvm.sh" ]]; then
#     # shellcheck disable=SC1091
#     . "$NVM_DIR/nvm.sh"
# fi
# if [[ -s "$NVM_DIR/bash_completion" ]]; then
#     # shellcheck disable=SC1091
#     . "$NVM_DIR/bash_completion"
# fi

# PowerShell wrappers so WSL shells can reliably call Windows PowerShell / pwsh.
if [[ ! -x "$HOME/.local/bin/powershell.exe" ]]; then
    mkdir -p "$HOME/.local/bin"
    cat > "$HOME/.local/bin/powershell.exe" <<'EOF'
#!/usr/bin/env bash
exec /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe "$@"
EOF
    chmod +x "$HOME/.local/bin/powershell.exe"
fi
if [[ ! -x "$HOME/.local/bin/pwsh" ]]; then
    mkdir -p "$HOME/.local/bin"
    cat > "$HOME/.local/bin/pwsh" <<'EOF'
#!/usr/bin/env bash
exec '/mnt/c/Program Files/PowerShell/7/pwsh.exe' "$@"
EOF
    chmod +x "$HOME/.local/bin/pwsh"
fi

# NOTE: Do NOT place secrets (API keys, passwords) in this file. Use the
# credential vault at ~/.openclaw/credentials/vault instead.

# end of file
