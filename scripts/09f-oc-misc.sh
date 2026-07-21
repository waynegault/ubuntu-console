# shellcheck shell=bash
# shellcheck disable=SC2034,SC2059,SC2120,SC2154
# --- Module: 09f-oc-misc ---
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 1
# ==============================================================================
# 09f-oc-misc — Miscellaneous OC commands (kgraph, stinger, mem-index)
# ==============================================================================

function oc-kgraph() {
    local KG_PKG="$TACTICAL_REPO_ROOT/scripts/kgraph"
    if [[ ! -d "$KG_PKG" ]]; then
        __tac_info "kgraph" "[NOT FOUND: $KG_PKG]" "$C_Error"
        return 1
    fi

    local do_reindex=false
    local arg
    for arg in "$@"; do
        case "$arg" in
            --reindex|--refresh) do_reindex=true ;;
            --restart) ;;
            -h|--help)
                printf '%s\n' "Usage: oc g [--reindex|--refresh] [--restart]"
                printf '%s\n' "  --reindex  Sync memory DB to graph DB (memory auto-indexed)"
                printf '%s\n' "  --restart  Force-restart kgraph server"
                printf '%s\n' ""
                printf '%s\n' "Graph roles:"
                printf '%s\n' "  Obsidian/Gigabrain = curated human memory browser"
                printf '%s\n' "  oc g               = operational / derived graph browser"
                printf '%s\n' "  OpenStinger        = temporal/entity recall layer"
                printf '%s\n' ""
                printf '%s\n' "Views in oc g UI: overview, topics, files, semantic, raw"
                return 0
                ;;
            *) ;;
        esac
    done

    if $do_reindex; then
        __tac_info "kgraph" "[SYNCING MEMORY DB + AST — GRAPH DB]" "$C_Info"
        "$TAC_PYTHON" - <<'PY' >/dev/null 2>&1 || true
import sys, os
repo_root = os.environ.get('TACTICAL_REPO_ROOT', '/home/wayne/ubuntu-console')
if repo_root:
    sys.path.insert(0, os.path.join(repo_root, 'scripts'))
from kgraph import (
    resolve_memory_db_path, load_from_memory_db, load_from_graph_db,
    save_to_graph_db, extract_repo_graph, tag_confidence
)
from kgraph.update import merge_graphs
from kgraph.confidence import confidence_stats

# Load existing graph DB (preserving user edits)
graph_db = os.path.expanduser('~/.openclaw/kgraph.sqlite')
graph = load_from_graph_db(graph_db)

# Merge memory DB
memory_db = resolve_memory_db_path()
if memory_db:
    try:
        mem = load_from_memory_db(memory_db)
        graph = merge_graphs(graph, mem)
    except Exception:
        pass

# Run AST extraction on ubuntu-console repo
if repo_root:
    try:
        ast = extract_repo_graph(repo_root, max_files=100)
        graph = merge_graphs(graph, ast)
    except Exception:
        pass

graph = tag_confidence(graph)
save_to_graph_db(graph_db, graph)
PY
        local _rc=$?
        if [[ $_rc -eq 0 ]]; then
            __tac_info "kgraph" "[REINDEX COMPLETE]" "$C_Success"
        else
            __tac_info "kgraph" "[REINDEX FAILED: $_rc]" "$C_Error"
        fi
    fi

    # Always relaunch to avoid stale in-memory code/data across edits.
    # Kill whatever currently owns the port first (including legacy copies).
    local PORT=46139
    fuser -k "${PORT}/tcp" >/dev/null 2>&1 || true
    if pgrep -u "$USER" -f "kgraph --serve" >/dev/null 2>&1; then
        # -f required: target is python3 with a module invocation, -x would only match process name
        pkill -u "$USER" -f "kgraph --serve" >/dev/null 2>&1 || true
    fi
    sleep 0.3
    set +m
    setsid "$TAC_PYTHON" -m kgraph --serve --embed --host 127.0.0.1 --port "$PORT" >/dev/null 2>&1 &
    disown
    set -m

    # Embedded mode serves a single HTML file plus /graph.json API.
    # Open the file path directly; opening / can yield a directory listing.
    local URL="http://127.0.0.1:${PORT}/kgraph.html"

    # Guard: only open URLs bound to localhost to prevent open-redirect.
    if [[ "$URL" != http://127.0.0.1:* && "$URL" != http://localhost:* ]]; then
        printf 'Refusing to open non-localhost URL: %s\n' "$URL"
        return 1
    fi

    __tac_info "Knowledge Graph" "[LAUNCHING — OVERVIEW VIEW]" "$C_Success"
    printf 'URL: %s\n' "$URL"
    printf '%s\n' 'Use the toolbar to switch views: overview, topics, files, semantic, raw.'

    # Wait up to ~5s for the server to respond, then give browsers a tiny
    # extra moment so we do not race a freshly-bound socket.
    local i
    local server_ready=1
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if command -v curl >/dev/null 2>&1; then
            if curl -sSf --max-time 5 --connect-timeout 3 --head "$URL" >/dev/null 2>&1; then
                server_ready=0
                break
            fi
        else
            if (echo > /dev/tcp/127.0.0.1/${PORT}) >/dev/null 2>&1; then
                server_ready=0
                break
            fi
        fi
        sleep 0.5
    done
    sleep 0.3

    if [[ $server_ready -ne 0 ]]; then
        printf '\nWarning: kgraph server slow to bind.\n'
        printf 'URL may still come up: %s\n' "$URL"
    fi

    # Try launchers in a strict order and only claim success when the launcher
    # itself exits successfully.
    local opened=1
    local opener_used="manual"
    if [[ -f /proc/version ]] && grep -qi microsoft /proc/version 2>/dev/null; then
        if command -v wslview >/dev/null 2>&1; then
            if wslview "$URL" >/dev/null 2>&1; then
                opened=0
                opener_used="wslview"
            fi
        fi

        if [[ $opened -ne 0 ]] && command -v powershell.exe >/dev/null 2>&1; then
            if timeout 10 powershell.exe -NoProfile -Command "Start-Process '$URL'" >/dev/null 2>&1; then
                opened=0
                opener_used="powershell.exe"
            fi
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
        local b
        for b in "${browsers[@]}"; do
            if command -v "$b" >/dev/null 2>&1; then
                if "$b" "$URL" >/dev/null 2>&1 & then
                    opened=0
                    opener_used="$b"
                    break
                fi
            fi
        done
    fi

    if [[ $opened -ne 0 ]] && command -v xdg-open >/dev/null 2>&1; then
        if xdg-open "$URL" >/dev/null 2>&1; then
            opened=0
            opener_used="xdg-open"
        fi
    fi

    if [[ $opened -eq 0 ]]; then
        printf 'Launcher: %s\n' "$opener_used"
    else
        printf '\nCould not launch a browser automatically. Open this URL manually: %s\n' "$URL"
        printf 'Launchers tried: wslview, powershell.exe, browser fallbacks, xdg-open\n'
    fi
}

# ==============================================================================
# OPENCLAW ENVIRONMENT VARIABLES
# ==============================================================================
# These are exported here so they are available to OpenClaw and any child
# processes. This keeps ~/.bashrc clean and ensures all OC-related config
# lives in the version-controlled module.

# Deep Recall provider — Python script for life memory recall
export OPENCLAW_LCM_DEEP_RECALL_CMD="$TAC_PYTHON $OC_ROOT/life/deep-recall-provider-lcm.py"

# ---------------------------------------------------------------------------
# mem-index — Rebuild OpenClaw vector memory index.
# Thin wrapper: delegates to openclaw CLI with graceful fallback.
# ---------------------------------------------------------------------------
function mem-index() {
    if [[ "$__TAC_OPENCLAW_OK" == "1" ]]
    then
        command openclaw mem-index "$@"
    else
        __tac_info "OpenClaw" "[NOT INSTALLED]" "$C_Warning"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# oc-memory-search — Search vector memory index.
# Thin wrapper: delegates to openclaw CLI with graceful fallback.
# ---------------------------------------------------------------------------
function oc-memory-search() {
    if [[ "$__TAC_OPENCLAW_OK" == "1" ]]
    then
        command openclaw memory search "$@"
    else
        __tac_info "OpenClaw" "[NOT INSTALLED]" "$C_Warning"
        return 1
    fi
}

# end of file
function owk() {
    cd "$OC_WORKSPACE" 2>/dev/null || { __tac_info "Workspace" "[NOT FOUND]" "$C_Error"; return 1; }
}

# ---------------------------------------------------------------------------
# ologs — cd to OpenClaw logs directory.
# ---------------------------------------------------------------------------
function ologs() {
    cd "$OC_LOGS" 2>/dev/null || { __tac_info "Logs" "[NOT FOUND]" "$C_Error"; return 1; }
}

# ---------------------------------------------------------------------------
# ocroot — cd to OpenClaw root directory.
# ---------------------------------------------------------------------------
function ocroot() {
    cd "$OC_ROOT" 2>/dev/null || { __tac_info "Root" "[NOT FOUND]" "$C_Error"; return 1; }
}

# ---------------------------------------------------------------------------
# lc — Clear the console log view baseline for le/lo.
# Notes:
# - This does not delete journal entries.
# - le/lo read this marker and only show logs after this point.
# ---------------------------------------------------------------------------
function lc() {
    local _marker_dir="${OC_ROOT:-$HOME/.openclaw}/state"
    local _marker_file="${_marker_dir}/console-log-clear.epoch"

    mkdir -p "$_marker_dir" 2>/dev/null || true
    date +%s > "$_marker_file"

    __tac_info "Logs" "[CLEARED]" "$C_Success"
}

# ---------------------------------------------------------------------------
# oc-update — Update the OpenClaw CLI to the latest version.
# Optional helper: uses enhanced update script (if present) to
# handle permission issues automatically.
# ---------------------------------------------------------------------------
function oc-update() {
    local enhanced_script="$HOME/.openclaw/workspace/scripts/oc-update-enhanced.sh"

    # Use enhanced update script if available
    if [[ -f "$enhanced_script" ]]
    then
        exec "$enhanced_script"
        return $?
    fi

    # Fallback to original update method
    if [[ "$__TAC_OPENCLAW_OK" != "1" ]]; then
        __tac_info "OpenClaw CLI" "[NOT INSTALLED]" "$C_Error"
        return 1
    fi
    __tac_info "Checking for updates..." "[WORKING]" "$C_Dim"
    local out
    out=$(openclaw update 2>&1)
    local rc=$?
    if (( rc == 0 ))
    then
        __tac_info "Update" "[COMPLETE]" "$C_Success"
        [[ -n "$out" ]] && printf '%s\n' "${C_Dim}${out}${C_Reset}"
    else
        __tac_info "Update" "[FAILED - rc=$rc]" "$C_Error"
        [[ -n "$out" ]] && printf '%s\n' "${C_Dim}${out}${C_Reset}"
    fi
}

# ---------------------------------------------------------------------------
# oc-health — Comprehensive OpenClaw system health check.
# Optional helper: runs richer diagnostics via oc-health-check.py when present;
# otherwise falls back to built-in health checks.
# ---------------------------------------------------------------------------
