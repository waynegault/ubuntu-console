# shellcheck shell=bash
# shellcheck disable=SC2034
# ─── Module: 04-aliases ───────────────────────────────────────────────────────
# AI INSTRUCTION: On ANY change to this file:
#   1. Increment _TAC_ALIASES_VERSION below (patch for fixes, minor for features).
#   2. Increment TACTICAL_PROFILE_VERSION in tactical-console.bashrc (always).
_TAC_ALIASES_VERSION="3.0.0"
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
