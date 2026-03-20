# shellcheck shell=bash
# shellcheck disable=SC2034
# ─── Module: 04-aliases ───────────────────────────────────────────────────────
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# TACTICAL_PROFILE_VERSION auto-computes from the sum of all module versions.
# Module Version: 2
# ==============================================================================
# 3. ALIAS DEFINITIONS & SHORTCUTS
# ==============================================================================
# @modular-section: aliases
# @depends: constants
# @exports: code, oedit, llmconf, oclogs, le, lo, occonf, os, oa, ocstat,
#   ocgs, ocv, mem-index, status, ocms, cop, cop-ask, cop-init (plus standard shell aliases)
#   Note: owk → 'oc wk', ologs → 'oc log-dir', mem-index → 'oc mem-index'

# ---- Core OS Aliases ----
alias ls='ls --color=auto'
alias grep='grep --color=auto'
# fgrep/egrep are deprecated in modern coreutils. These aliases ensure
# backward compat if any inherited scripts call them. Safe to remove once
# confirmed no scripts in ~/console or ~/.openclaw reference fgrep/egrep.
alias fgrep='grep -F --color=auto'
alias egrep='grep -E --color=auto'
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'

# ---- Tactical UI & Navigation ----
alias h='tactical_help'
alias cls='clear_tactical'
alias reload='command clear; exec bash'
alias m='tactical_dashboard'
alias cpwd='copy_path'
alias unittest='~/ubuntu-console/scripts/run-tests.sh'

# g — Launch the kgraph server (serves scripts/kgraph.py --serve)
# Runs in background and attempts to open the browser (kgraph.py handles the URL).
function g() {
    local KG_PY="$HOME/ubuntu-console/scripts/kgraph.py"
    if [[ ! -f "$KG_PY" ]]; then
        echo "kgraph script not found: $KG_PY"
        return 1
    fi

    # If kgraph isn't running, start it on a known local port in background.
    local PORT=46139
    if ! pgrep -f "$KG_PY" >/dev/null 2>&1; then
        setsid python3 "$KG_PY" --serve --embed --host 127.0.0.1 --port "$PORT" >/dev/null 2>&1 &
        disown
    fi

    # kgraph.py writes the embedded page to kgraph.html when --embed is used,
    # so open that path explicitly to avoid a directory listing.
    local URL="http://127.0.0.1:${PORT}/kgraph.html"

    # Guard: only open URLs bound to localhost to prevent open-redirect.
    if [[ "$URL" != http://127.0.0.1:* && "$URL" != http://localhost:* ]]; then
        printf 'Refusing to open non-localhost URL: %s\n' "$URL"
        return 1
    fi

    # immediate user-visible one-liner required by workflow
    echo "Wen page opened"
    printf 'URL: %s\n' "$URL"

    # Open browser after the server binds — poll briefly so the tab
    # opens against a live page.
    # wait up to ~5s for the server to respond
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if command -v curl >/dev/null 2>&1; then
            curl -sSf --head "$URL" >/dev/null 2>&1 && break
        else
            # fallback: try connecting with /dev/tcp
            (echo > /dev/tcp/127.0.0.1/${PORT}) >/dev/null 2>&1 && break
        fi
        sleep 0.5
    done

    # Try WSL/Windows openers first (if running under WSL), then common
    # Linux browser binaries, then fallback to xdg-open.
    local opened=1
    if [[ -f /proc/version ]] && grep -qi microsoft /proc/version 2>/dev/null; then
        # Prefer wslview (wslu) which reliably opens Windows default browser.
        if command -v wslview >/dev/null 2>&1; then
            wslview "$URL" >/dev/null 2>&1 || true
            opened=0
        elif command -v powershell.exe >/dev/null 2>&1; then
            powershell.exe -NoProfile -Command Start-Process -ArgumentList "$URL" >/dev/null 2>&1 || true
            opened=0
        elif command -v pwsh.exe >/dev/null 2>&1; then
            pwsh.exe -NoProfile -Command Start-Process -ArgumentList "$URL" >/dev/null 2>&1 || true
            opened=0
        fi
    fi

    if [[ $opened -ne 0 ]]; then
        local browsers=(
            msedge
            microsoft-edge
            microsoft-edge-stable
            microsoft-edge-dev
            chromium-browser
            chromium
            google-chrome
            google-chrome-stable
            brave-browser
            firefox
        )
        for b in "${browsers[@]}"; do
            if command -v "$b" >/dev/null 2>&1; then
                "$b" "$URL" >/dev/null 2>&1 &>/dev/null || true
                opened=0
                break
            fi
        done
    fi
    if [[ $opened -ne 0 ]]; then
        if command -v xdg-open >/dev/null 2>&1; then
            xdg-open "$URL" >/dev/null 2>&1 || true
        fi
    fi

    # If we couldn't open a browser automatically, print the URL so the user can open it.
    if [[ $opened -ne 0 ]]; then
        printf '\nCould not launch a browser automatically. Open this URL manually: %s\n' "$URL"
    fi
}

# ---- Dev Tools & VS Code Wrappers (lazy-resolved — no pwsh hit at shell start) ----
# Path resolution is centralised in __resolve_vscode_bin (§1).
# Single-file wrappers (oedit, llmconf, etc.) use __vsc_open (§5).
# code() passes raw args and skips __vsc_open to support multi-arg/folder usage.
function code() {
    __resolve_vscode_bin
    "$VSCODE_BIN" "$@"
}
# oedit — Open tactical-console.bashrc in VS Code for editing.
function oedit() {
    __vsc_open "$HOME/ubuntu-console/tactical-console.bashrc" "VS Code opened... (run 'reload' to apply changes)"
}
# llmconf — Open the LLM model registry config in VS Code.
function llmconf() {
    __vsc_open "$LLM_REGISTRY"
}
# oclogs — Open the OpenClaw temporary log file in VS Code.
function oclogs() {
    __vsc_open "$OC_TMP_LOG"
}
# le — Show the last 40 lines of the OpenClaw gateway journal.
function le() {
    journalctl --user -u openclaw-gateway.service --no-pager -n 60 --output=cat 2>&1 | tail -40
}
# lo — Show the last 120 lines of the OpenClaw gateway journal.
function lo() {
    journalctl --user -u openclaw-gateway.service --no-pager -n 120 --output=cat 2>&1
}
# occonf — Open the OpenClaw config (openclaw.json) in VS Code.
function occonf() {
    __vsc_open "$OC_ROOT/openclaw.json"
}

# ---- Git Shortcuts ----
# commit: <msg> — git add + commit with YOUR message + push
# commit        — git add + commit with LLM-generated message + push
alias 'commit:'='commit_deploy'
alias commit='commit_auto'

# ---- OpenClaw Shortcuts (functions defined in §9) ----
# Wrapper: strip the leading blank line that openclaw always prints.
# Skip filtering for interactive/redirected commands to avoid breaking TTY.
function openclaw() {
    if [[ -t 1 ]] && [[ "$1" != "tui" && "$1" != "logs" ]]
    then
        command openclaw "$@" | sed '1{/^$/d}'
    else
        command openclaw "$@"
    fi
}

# os — List OpenClaw sessions.
function os() {
    openclaw sessions
}
# oa — List OpenClaw agents.
function oa() {
    openclaw agents list
}
# ocstat — Show detailed OpenClaw status (--all).
function ocstat() {
    openclaw status --all
}
# ocgs — Show OpenClaw gateway status with deep probe.
function ocgs() {
    openclaw gateway status --deep
}
# ocv — Print the OpenClaw version.
function ocv() {
    openclaw --version
}
# mem-index — Trigger OpenClaw memory indexing.
function mem-index() {
    openclaw memory index
}
# status — Show basic OpenClaw status.
function status() {
    openclaw status
}
# ocms — Show OpenClaw model status with live probe.
function ocms() {
    openclaw models status --probe
}

# ---- GitHub Copilot CLI ----
alias '??'='copilot -p'
alias cop='copilot'
# cop-init — Initialize GitHub Copilot CLI.
function cop-init() {
    copilot init
}
# cop-ask — Ask GitHub Copilot CLI a question.
function cop-ask() {
    copilot -p "$*"
}

# ---- LLM & Inference ----
# chat:      — interactive multi-turn chat with local LLM (end-chat to exit)
# wtf <topic>— ask the local LLM to explain a tool or concept (REPL mode)
alias chat:='local_chat'
alias wtf='wtf_repl'


# end of file
