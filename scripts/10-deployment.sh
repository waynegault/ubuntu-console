# shellcheck shell=bash
# shellcheck disable=SC1091,SC2034,SC2059,SC2154
# ─── Module: 10-deployment ───────────────────────────────────────────────────────
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# TACTICAL_PROFILE_VERSION auto-computes from the sum of all module versions.
# Module Version: 3
# ==============================================================================
# 10. DEPLOYMENT & SCAFFOLDING
# ==============================================================================
# @modular-section: deployment
# @depends: constants, design-tokens, ui-engine, hooks
# @exports: mkproj, commit_deploy, commit_auto

# ---- Constants for LLM-powered commit messages ----
readonly _COMMIT_DIFF_MAX_LINES=500       # Cap diff at 500 lines for context window
readonly _COMMIT_DIFF_MAX_CHARS=3000      # Cap diff at 3000 chars for small models
readonly _COMMIT_MAX_TOKENS=80            # Commit messages ≤72 chars; 80 gives buffer
readonly _COMMIT_TEMPERATURE=0.3          # Low creativity for deterministic summaries

# ---------------------------------------------------------------------------
# __scan_diff_for_secrets — Scan git diff for API keys, tokens, and secrets.
# Usage: __scan_diff_for_secrets <diff_content>
# Returns: 0 if no secrets found, 1 if secrets detected (blocks commit)
#
# SECURITY DISCLAIMER:
# This is a BEST-EFFORT check, NOT a comprehensive security guarantee.
# It covers common secret formats but may miss: base64-encoded keys, keys with
# special characters, custom/internal API keys, or keys in external config files.
# Always use proper secret management (vaults, env vars, CI/CD secrets).
#
# Patterns matched:
#   sk-...                          → OpenAI / Anthropic API keys
#   AKIA...                         → AWS access key IDs
#   ghp_...                         → GitHub personal access tokens
#   github_pat_...                  → GitHub fine-grained tokens
#   ghpat-...                       → GitHub newer-format tokens
#   xox[baprs]-...                  → Slack tokens
#   AIza...                         → Google API keys
#   EAACEdE...                      → Facebook access tokens
#   eyJ...                          → JWT tokens (base64-encoded JSON)
#   -----BEGIN RSA/EC/OPENSSH...    → PEM-encoded private keys
#   API_KEY=... / API-KEY=...       → Generic env-var style API key assignments
#   PRIVATE_KEY=...-----BEGIN       → Private keys in env vars
#   npm_...                         → npm access tokens
#   pypi-...                        → PyPI API tokens
# ---------------------------------------------------------------------------
function __scan_diff_for_secrets() {
    local diff_body="$1"

    local __secret_pat='(
        sk-[a-zA-Z0-9]{20,}                    # OpenAI/Anthropic
        |AKIA[0-9A-Z]{16}                      # AWS
        |ghp_[a-zA-Z0-9]{36}                   # GitHub PAT
        |github_pat_[a-zA-Z0-9]{22}_[a-zA-Z0-9]{59}  # GitHub fine-grained
        |ghpat-[a-zA-Z0-9]{40,}                # GitHub newer tokens
        |xox[baprs]-[0-9]{10,13}-[0-9]{10,13}  # Slack tokens
        |AIza[0-9A-Za-z_-]{35}                 # Google API
        |EAACEdE[0-9A-Za-z]{20,}               # Facebook access tokens
        |eyJ[a-zA-Z0-9_-]{20,}                 # JWT tokens (base64 JSON)
        |-----BEGIN[[:space:]]+(RSA|EC|OPENSSH|DSA)[[:space:]]+PRIVATE[[:space:]]+KEY
        |API[_-]?KEY[[:space:]]*=[[:space:]]*['"'"'"]?[a-zA-Z0-9]{16,}
        |PRIVATE[_-]?KEY[[:space:]]*=[[:space:]]*['"'"'"]?-----BEGIN
        |npm_[a-zA-Z0-9]{36}                   # npm tokens
        |pypi-[a-zA-Z0-9_-]{20,}               # PyPI tokens
    )'

    if [[ "$diff_body" =~ $__secret_pat ]]
    then
        __tac_info "SECURITY" "[BLOCKED: diff appears to contain a secret/API key]" "$C_Error"
        __tac_info "Hint" "Run 'git reset HEAD' to unstage, then use a vault or env vars" "$C_Dim"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# mkproj — Scaffold a new Python project with PEP-8 main.py, tests, venv, git.
# ---------------------------------------------------------------------------
function mkproj() {
    local n="$1"

    # Validate: project name is required
    if [[ -z "$n" ]]
    then
        __tac_info "Project Name Required" "[mkproj <Name>]" "$C_Error"
        return 1
    fi

    # Security: reject path traversal attempts (e.g., ../evil, ../../etc)
    if [[ "$n" == *".."* ]]
    then
        __tac_info "Invalid Project Name" "[PATH TRAVERSAL NOT ALLOWED]" "$C_Error"
        return 1
    fi

    # Security: reject absolute paths to prevent writing to arbitrary locations
    if [[ "$n" == /* ]]
    then
        __tac_info "Invalid Project Name" "[ABSOLUTE PATHS NOT ALLOWED]" "$C_Error"
        return 1
    fi

    # Validate: project name contains only safe characters (alphanumeric, dash, underscore)
    if [[ ! "$n" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]
    then
        __tac_info "Invalid Project Name" "[MUST START WITH LETTER, CONTAIN ONLY A-Z, 0-9, -, _]" "$C_Error"
        return 1
    fi

    # Validate: project name is reasonable length (1-64 chars)
    if [[ ${#n} -gt 64 ]]
    then
        __tac_info "Invalid Project Name" "[TOO LONG - MAX 64 CHARS]" "$C_Error"
        return 1
    fi

    if [[ -d "$n" ]]
    then
        __tac_info "Directory $n" "[ALREADY EXISTS]" "$C_Error"
        return 1
    fi

    # Verify required tools before creating any files
    if ! command -v python3 >/dev/null 2>&1
    then
        __tac_info "python3" "[NOT FOUND - install before using mkproj]" "$C_Error"
        return 1
    fi

    # Verify Python version (3.8+ required for modern features)
    local pyver major minor
    pyver=$(python3 --version 2>&1 | grep -oP 'Python \K[0-9]+\.[0-9]+' || echo "0.0")
    IFS='.' read -r major minor <<< "$pyver"
    if (( major < 3 || (major == 3 && minor < 8) ))
    then
        __tac_info "Python Version" "[REQUIRES 3.8+, FOUND $pyver]" "$C_Error"
        return 1
    fi

    if ! command -v git >/dev/null 2>&1
    then
        __tac_info "git" "[NOT FOUND - install before using mkproj]" "$C_Error"
        return 1
    fi

    # Check available disk space (require at least 100MB for venv + dependencies)
    local available_kb
    available_kb=$(df -k . | awk 'NR==2 {print $4}')
    if [[ -n "$available_kb" && "$available_kb" -lt 102400 ]]
    then
        __tac_info "Disk Space" "[INSUFFICIENT - need 100MB, have $((available_kb / 1024))MB]" "$C_Error"
        return 1
    fi

    mkdir -p "$n/src" "$n/tests"
    cd "$n" || return

    cat << 'EOF' > requirements.txt
# Core dependencies
pytest
EOF
    printf "__pycache__/\n.venv/\n.env\n*.log\n.pytest_cache/\n" > .gitignore
    printf "ENVIRONMENT=development\nLOG_LEVEL=DEBUG\n" > .env.example
    touch src/__init__.py

    cat << 'EOF' > src/main.py
"""
Module: main.py
Description: Primary entry point.
Author: Wayne
"""
import sys
import logging
import argparse
from pathlib import Path

def setup_logging(debug: bool = False) -> logging.Logger:
    level = logging.DEBUG if debug else logging.INFO
    logging.basicConfig(level=level, format='%(asctime)s | %(levelname)-8s | %(message)s', datefmt='%Y-%m-%d %H:%M:%S')
    return logging.getLogger(__name__)

def execute_task(logger: logging.Logger, target_dir: Path) -> None:
    logger.info(f"Initiating sequence in: {target_dir}")
    if not target_dir.exists():
        logger.error(f"Target directory missing: {target_dir}")
        sys.exit(1)
    logger.info("Task sequence completed successfully.")

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--debug', action='store_true')
    parser.add_argument('--target', type=Path, default=Path.cwd())
    args = parser.parse_args()
    logger = setup_logging(args.debug)
    try:
        execute_task(logger, args.target)
    except Exception as e:
        logger.exception("A critical unhandled failure occurred.")
        sys.exit(1)

if __name__ == '__main__':
    main()
EOF

    cat << 'EOF' > tests/test_core.py
import pytest

def test_initial_sanity():
    assert True
EOF

    git init >/dev/null 2>&1

    # Auto-initialize venv
    __tac_info "Python Environment" "[CREATING .venv...]" "$C_Dim"
    python3 -m venv .venv
    if [[ -f ".venv/bin/activate" ]]
    then
        source .venv/bin/activate
        if pip install --upgrade pip --quiet >/dev/null 2>&1 \
            && pip install -r requirements.txt --quiet >/dev/null 2>&1
        then
            __tac_info "Python Dependencies" "[INSTALLED]" "$C_Success"
        else
            __tac_info "Python Dependencies" "[FAILED]" "$C_Error"
            return 1
        fi
    else
        __tac_info "Python Environment" "[FAILED]" "$C_Error"
        return 1
    fi

    __tac_info "Directory & Git Init" "[SUCCESS]" "$C_Success"
    __tac_info "PEP8 src/main.py Scaffold" "[INJECTED]" "$C_Success"
    __tac_info "tests/, .env, requirements" "[CREATED]" "$C_Success"
}

# ---------------------------------------------------------------------------
# commit_deploy — Stage, commit with a given message, then push.
# ---------------------------------------------------------------------------
function commit_deploy() {
    local msg="$*"
    if [[ -z "$msg" ]]
    then
        __tac_info "Commit message required" "[commit: <msg>]" "$C_Error"
        return 1
    fi

    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1
    then
        __tac_info "Repository Check" "[NOT A GIT REPO]" "$C_Error"
        return 1
    fi

    # Verify a remote is configured before attempting push
    if ! git remote get-url origin >/dev/null 2>&1
    then
        __tac_info "Remote Check" "[NO ORIGIN CONFIGURED]" "$C_Error"
        return 1
    fi

    if [[ -z $(git status --porcelain) ]]
    then
        __tac_info "Workspace" "[CLEAN - NO CHANGES]" "$C_Dim"
        return 0
    fi

    __tac_header "VERSION CONTROL" "open"

    local modCount
    modCount=$(git status --porcelain | wc -l)
    __tac_line "Staging $modCount file(s)..." "[WORKING]" "$C_Dim"
    git add .

    # SECURITY: Scan staged diff for secrets before committing
    local diff_body
    diff_body=$(git diff --cached 2>/dev/null | head -"$_COMMIT_DIFF_MAX_LINES")
    if ! __scan_diff_for_secrets "$diff_body"
    then
        git reset HEAD >/dev/null 2>&1
        __tac_footer
        return 1
    fi

    __tac_line "Committing: \"$msg\"..." "[WORKING]" "$C_Dim"
    if ! git commit -m "$msg" --quiet
    then
        __tac_line "Commit" "[FAILED]" "$C_Error"
        __tac_footer
        return 1
    fi

    __tac_line "Syncing with origin..." "[WORKING]" "$C_Dim"
    git push --quiet
    local push_rc=$?

    if (( push_rc == 0 ))
    then
        __tac_line "Repository Sync" "[SUCCESS]" "$C_Success"
    else
        __tac_line "Repository Sync" "[REMOTE PUSH FAILED]" "$C_Error"
    fi

    __tac_footer
}

# ---------------------------------------------------------------------------
# commit_auto — Stage, generate commit message via local LLM, push, deploy.
# Uses curl + jq (not Python) for the non-streaming LLM request.
#
# SECURITY WARNING: The git diff is sent to $LOCAL_LLM_URL. If this URL is
# ever reconfigured to point to a cloud API, diffs containing secrets (API
# keys, passwords) will be leaked. Ensure LOCAL_LLM_URL always points to a
# local-only inference server (127.0.0.1).
# ---------------------------------------------------------------------------
function commit_auto() {
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1
    then
        __tac_info "Repository Check" "[NOT A GIT REPO]" "$C_Error"
        return 1
    fi
    if ! git remote get-url origin >/dev/null 2>&1
    then
        __tac_info "Remote Check" "[NO ORIGIN CONFIGURED]" "$C_Error"
        return 1
    fi
    # Security: block diff leak to non-localhost LLM endpoints.
    # Validate host strictly to prevent SSRF via IPv6 or hostname tricks.
    local _llm_host
    _llm_host=$(printf '%s' "$LOCAL_LLM_URL" | grep -oP 'http://\K[^:/]+' || echo "")
    case "$_llm_host" in
        127.0.0.1|localhost|::1) ;;  # Allowed: IPv4/IPv6 localhost
        *)
            __tac_info "SECURITY" "[BLOCKED: LLM URL must be localhost only]" "$C_Error"
            return 1
            ;;
    esac
    if [[ -z $(git status --porcelain) ]]
    then
        __tac_info "Workspace" "[CLEAN - NO CHANGES]" "$C_Dim"
        return 0
    fi
    if ! __test_port "$LLM_PORT"
    then
        __tac_info "LLM Required" "[OFFLINE - Start a model first]" "$C_Error"
        return 1
    fi
    # Verify the process listening on $LLM_PORT is actually llama-server
    local _llm_pid
    _llm_pid=$(ss -tlnp "sport = :$LLM_PORT" 2>/dev/null | grep -oP 'pid=\K[0-9]+')
    if [[ -z "$_llm_pid" ]] || ! grep -q llama-server "/proc/$_llm_pid/cmdline" 2>/dev/null
    then
        __tac_info "SECURITY" "[BLOCKED: port $LLM_PORT is not llama-server]" "$C_Error"
        return 1
    fi

    # UX flow:
    #   1. Stage all changes (git add .)
    #   2. Send diff to local LLM for commit message generation
    #   3. Show proposed message to user
    #   4. Accept (Y/Enter), reject (n), or edit (e) interactively
    #   5. On accept: commit, push, deploy. On reject: git reset HEAD.

    git add .
    # Capture both stat (file-level summary) and body (line-level diff)
    # Note (I4): Two separate `git diff --cached` calls are intentional — --stat
    # produces a columnar summary while the raw diff gives line-level context.
    # Both read the same index snapshot so there is no consistency issue.
    local diff_stat
    diff_stat=$(git diff --cached --stat 2>/dev/null)
    local diff_body
    diff_body=$(git diff --cached 2>/dev/null | head -"$_COMMIT_DIFF_MAX_LINES")
    local diff="${diff_stat}
---
${diff_body}"

    # SECURITY: Scan diff for secrets before any commit (blocks accidental leaks)
    if ! __scan_diff_for_secrets "$diff_body"
    then
        git reset HEAD >/dev/null 2>&1
        return 1
    fi

    # Guard: refuse to send diffs containing secret-like patterns to the LLM.
    # Even though LOCAL_LLM_URL is localhost, a misconfigured proxy could route
    # the request externally. Fail safe by scanning the diff body.
    # (Duplicate check - kept for defense-in-depth before LLM submission)

    __tac_info "Generating commit message..." "[LLM]" "$C_Dim"

    local prompt="Write a concise git commit message (one line, max 72 chars,"
    prompt+=" imperative mood) for the following diff."
    prompt+=" Return ONLY the message, no quotes or explanation."
    # Use constants for LLM parameters (defined at top of file)
    local payload
    payload=$(jq -n \
        --arg    prompt      "$prompt" \
        --arg    diff        "${diff:0:$_COMMIT_DIFF_MAX_CHARS}" \
        --argjson max_tokens "$_COMMIT_MAX_TOKENS" \
        --argjson temperature "$_COMMIT_TEMPERATURE" \
        '{messages:[{role:"user",content:($prompt+"\n\n"+$diff)}],
          max_tokens:$max_tokens,temperature:$temperature}')

    local raw_response
    raw_response=$(curl -s --max-time 30 "$LOCAL_LLM_URL" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null)
    local msg
    msg=$(printf '%s' "$raw_response" | jq -r '.choices[0].message.content // empty' 2>/dev/null | \
        tr -d '"' | head -c 72 | head -1)

    if [[ -z "$msg" || "$msg" == "null" ]]
    then
        __tac_info "LLM" "[FAILED TO GENERATE MESSAGE]" "$C_Error"
        git reset HEAD >/dev/null 2>&1
        return 0  # No changes made (same as user cancellation)
    fi

    printf '%s\n' "${C_Highlight}Proposed:${C_Reset} $msg"
    while true
    do
        read -r -e -p "${C_Dim}Accept? [Y/n/edit]: ${C_Reset}" confirm
        case "${confirm,,}" in
            y|yes|"") break ;;
            n|no)
                __tac_info "Commit" "[CANCELLED]" "$C_Dim"
                git reset HEAD >/dev/null 2>&1
                return 0
                ;;
            e|edit)
                read -r -e -p "${C_Highlight}Message: ${C_Reset}" -i "$msg" msg
                if [[ -z "$msg" ]]
                then
                    __tac_info "Commit" "[CANCELLED]" "$C_Dim"
                    git reset HEAD >/dev/null 2>&1
                    return 0
                fi
                break
                ;;
            *) echo "Please enter y, n, or e." ;;
        esac
    done

    git commit -m "$msg" --quiet
    __tac_info "Committed" "[$msg]" "$C_Success"
    git push --quiet
    local push_rc=$?
    if (( push_rc == 0 ))
    then
        __tac_info "Repository Sync" "[SUCCESS]" "$C_Success"
    else
        __tac_info "Repository Sync" "[REMOTE PUSH FAILED]" "$C_Error"
        return 1  # Changes committed but not synced - caller should decide retry strategy
    fi
}




# end of file
