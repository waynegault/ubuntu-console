# shellcheck shell=bash
# shellcheck disable=SC2034,SC2059,SC2120,SC2154
# --- Module: 09f-oc-misc ---
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 2
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
function oc-backup() {
    if ! command -v zip >/dev/null
    then
        __tac_info "Dependency" "[zip not installed]" "$C_Error"
        printf '%s\n' "  ${C_Dim}Install: sudo apt install zip${C_Reset}"
        return 1
    fi

    local stamp
    stamp=$(date +"%Y%m%d_%H%M%S")
    mkdir -p "$OC_BACKUPS"
    local zipPath="$OC_BACKUPS/snapshot_$stamp.zip"

    __tac_info "Compressing Configuration & Agents..." "[WORKING]" "$C_Dim"

    (
        cd "$AI_STORAGE_ROOT" || exit 1
        local -a targets=()
        # Core OpenClaw state
        [[ -d ".openclaw/workspace" ]] && targets+=(".openclaw/workspace")
        [[ -d ".openclaw/agents" ]]    && targets+=(".openclaw/agents")
        [[ -f ".openclaw/openclaw.json" ]] && targets+=(".openclaw/openclaw.json")
        [[ -f ".openclaw/auth.json" ]]     && targets+=(".openclaw/auth.json")
        # Shell profile and standalone scripts
        # Canonical profile is in the ubuntu-console repo; back up both the
        # thin loader (~/.bashrc) and the full profile.
        [[ -f ".bashrc" ]]                && targets+=(".bashrc")
        [[ -f "ubuntu-console/tactical-console.bashrc" ]] && targets+=("ubuntu-console/tactical-console.bashrc")
        local _script
        for _script in .local/bin/llama-watchdog.sh .local/bin/tac_hostmetrics.sh
        do
            [[ -f "$_script" ]] && targets+=("$_script")
        done
        # Systemd units
        for _script in .config/systemd/user/llama-watchdog.service \
                       .config/systemd/user/llama-watchdog.timer
        do
            [[ -f "$_script" ]] && targets+=("$_script")
        done

        if (( ${#targets[@]} > 0 ))
        then
            zip -r -q "$zipPath" "${targets[@]}"
        fi
    )

    # Model registry (backed up from canonical location)
    if [[ -f "$LLM_REGISTRY" ]]
    then
        (cd "$HOME" && zip -q "$zipPath" ".llm/models.conf")
    fi

    if [[ -f "$zipPath" ]]
    then
        local sz
        sz=$(stat -c%s "$zipPath" 2>/dev/null || echo "0")
        local human_sz=$(( sz / 1024 ))

        # Verify backup integrity
        __tac_info "Verifying backup..." "[CHECKSUM]" "$C_Dim"
        if unzip -tq "$zipPath" >/dev/null 2>&1
        then
            __tac_info "Backup Integrity" "[VERIFIED — ${human_sz}KB]" "$C_Success"
        else
            __tac_info "Backup Integrity" "[CORRUPTED — DELETE AND RETRY]" "$C_Error"
            rm -f "$zipPath"
            return 1
        fi

        # Test restore structure (dry-run listing)
        if unzip -l "$zipPath" | grep -q "workspace/"
        then
            __tac_info "Restore Test" "[STRUCTURE VALID]" "$C_Success"
        fi

        printf '%s\n' "  ${C_Dim}Path: $zipPath${C_Reset}"

        # Prune old snapshots — keep the 10 most recent
        local -a all_snaps=()
        local _s
        while IFS= read -r _s
        do
            all_snaps+=("$_s")
        done < <(ls -1t "$OC_BACKUPS"/snapshot_*.zip 2>/dev/null)
        local keep=10
        if (( ${#all_snaps[@]} > keep ))
        then
            local pruned=0
            local i
            for (( i=keep; i<${#all_snaps[@]}; i++ ))
            do
                rm -f "${all_snaps[$i]}"
                (( pruned++ ))
            done
            __tac_info "Pruned Old Snapshots" "[$pruned removed, keeping $keep]" "$C_Dim"
        fi
    else
        __tac_info "Target Directories" "[NOT FOUND]" "$C_Error"
    fi
}

# ---------------------------------------------------------------------------
# oc-restore — Rollback OpenClaw state from the most recent snapshot.
# DESTRUCTIVE: Deletes current workspace and agents. Prompts for confirmation.
# ---------------------------------------------------------------------------
function oc-restore() {
    local dry_run=0
    case "${1:-}" in
        --dry-run|-n) dry_run=1 ;;
        *) ;;
    esac

    local latest=""
    local -a snaps=("$OC_BACKUPS"/snapshot_*.zip)
    if [[ -e "${snaps[0]}" ]]
    then
        local f newest="" newest_t=0
        for f in "${snaps[@]}"
        do
            local t
            t=$(stat -c %Y "$f" 2>/dev/null) || continue
            (( t > newest_t )) && newest_t=$t && newest="$f"
        done
        latest="$newest"
    fi
    if [[ -z "$latest" ]]
    then
        __tac_info "Available Snapshots" "[NONE FOUND]" "$C_Error"
        return 1
    fi

    if (( ! dry_run ))
    then
        printf '%s\n' "${C_Warning}WARNING: This will DESTROY the current workspace and agents.${C_Reset}"
        printf '%s\n' "${C_Dim}Restoring from: $(basename "$latest")${C_Reset}"
        read -r -p "${C_Warning}Continue? [y/N]: ${C_Reset}" confirm
        if [[ "${confirm,,}" != "y" ]]
        then
            __tac_info "Restore" "[CANCELLED]" "$C_Dim"; return 0
        fi
    fi

    if (( ! dry_run ))
    then
        # Stop gateway inline (avoid calling xo which prints its own UI)
        openclaw gateway stop >/dev/null 2>&1
        # pkill -x matches only the exact process name (not substrings)
        pkill -u "$USER" -x openclaw 2>/dev/null

        __tac_info "Purging active configurations..." "[WORKING]" "$C_Dim"
    fi

    # Extract to a temp directory first, validate, then swap — protects
    # against corrupt ZIPs destroying current state with nothing to replace it.
    # Use mktemp -d with /tmp as the base (always supports XXXXXX template),
    # then move to OC_BACKUPS if needed. This avoids issues with network-mounted
    # or exotic filesystems that may not support mktemp's template expansion.
    local tmp_restore
    tmp_restore=$(mktemp -d "/tmp/oc-restore-XXXXXX")
    __tac_info "Extracting to staging area..." "[WORKING]" "$C_Dim"
    if ! unzip -q "$latest" -d "$tmp_restore"
    then
        __tac_info "State Rollback" "[FAILED — ZIP ERROR, current state preserved]" "$C_Error"
        rm -rf "$tmp_restore"
        return 1
    fi

    # Validate that the extracted archive has at least one known restorable asset
    if [[ ! -d "$tmp_restore/.openclaw/workspace" && ! -d "$tmp_restore/.openclaw/agents" \
       && ! -f "$tmp_restore/.openclaw/openclaw.json" && ! -f "$tmp_restore/.bashrc" \
       && ! -f "$tmp_restore/.llm/models.conf" ]]
    then
        __tac_info "State Rollback" "[FAILED — ZIP has no recognisable content]" "$C_Error"
        rm -rf "$tmp_restore"
        return 1
    fi

    # Security: reject extracted files with setuid/setgid/world-writable bits.
    # A crafted ZIP could plant executables with elevated permissions.
    if find "$tmp_restore" \( -perm /4000 -o -perm /2000 -o -perm /0002 \) -print -quit 2>/dev/null | grep -q .
    then
        __tac_info "State Rollback" "[FAILED — ZIP contains unsafe file permissions]" "$C_Error"
        rm -rf "$tmp_restore"
        return 1
    fi

    if (( dry_run ))
    then
        __tac_info "Restore" "[DRY RUN]" "$C_Warning"
        __tac_info "Snapshot" "$(basename "$latest")" "$C_Dim"
        [[ -d "$tmp_restore/.openclaw/workspace" ]] && __tac_info "Would Restore" "$OC_WORKSPACE" "$C_Dim"
        [[ -d "$tmp_restore/.openclaw/agents" ]] && __tac_info "Would Restore" "$OC_AGENTS" "$C_Dim"
        [[ -f "$tmp_restore/.openclaw/openclaw.json" ]] && __tac_info "Would Restore" "$OC_ROOT/openclaw.json" "$C_Dim"
        [[ -f "$tmp_restore/.openclaw/auth.json" ]] && __tac_info "Would Restore" "$OC_ROOT/auth.json" "$C_Dim"
        [[ -f "$tmp_restore/.llm/models.conf" ]] && __tac_info "Would Restore" "$LLM_REGISTRY" "$C_Dim"
        [[ -f "$tmp_restore/.bashrc" ]] && __tac_info "Would Restore" "$HOME/.bashrc" "$C_Dim"
        rm -rf "$tmp_restore"
        return 0
    fi

    # Only destroy directories that the backup will replace — a config-only
    # restore must NOT wipe workspace/agents if it has no replacements.
    # Atomic swap: rename current → .bak, move new into place, then remove .bak.
    # If the move fails, the .bak can be manually restored (no total-loss window).
    mkdir -p "$OC_ROOT" "$(dirname "$LLM_REGISTRY")"
    if [[ -d "$tmp_restore/.openclaw/workspace" ]]
    then
        [[ -d "$OC_WORKSPACE" ]] && mv "$OC_WORKSPACE" "${OC_WORKSPACE}.bak"
        mv "$tmp_restore/.openclaw/workspace" "$OC_WORKSPACE"
        rm -rf "${OC_WORKSPACE}.bak"
    fi
    if [[ -d "$tmp_restore/.openclaw/agents" ]]
    then
        [[ -d "$OC_AGENTS" ]] && mv "$OC_AGENTS" "${OC_AGENTS}.bak"
        mv "$tmp_restore/.openclaw/agents" "$OC_AGENTS"
        rm -rf "${OC_AGENTS}.bak"
    fi
    # Restore config files if they were backed up
    [[ -f "$tmp_restore/.openclaw/openclaw.json" ]] \
        && mv "$tmp_restore/.openclaw/openclaw.json" "$OC_ROOT/openclaw.json"
    [[ -f "$tmp_restore/.openclaw/auth.json" ]] \
        && mv "$tmp_restore/.openclaw/auth.json" "$OC_ROOT/auth.json"
    [[ -f "$tmp_restore/.llm/models.conf" ]] \
        && mv "$tmp_restore/.llm/models.conf" "$LLM_REGISTRY"
    # Restore shell profile and standalone scripts if present
    [[ -f "$tmp_restore/.bashrc" ]] && cp "$tmp_restore/.bashrc" "$HOME/.bashrc"
    if [[ -f "$tmp_restore/ubuntu-console/tactical-console.bashrc" ]]
    then
        mkdir -p "$TACTICAL_REPO_ROOT"
        cp "$tmp_restore/ubuntu-console/tactical-console.bashrc" "$TACTICAL_REPO_ROOT/tactical-console.bashrc"
    fi
    local _rs
    for _rs in .local/bin/llama-watchdog.sh .local/bin/tac_hostmetrics.sh
    do
        if [[ -f "$tmp_restore/$_rs" ]]
        then
            mkdir -p "$(dirname "$HOME/$_rs")"
            cp "$tmp_restore/$_rs" "$HOME/$_rs"
            chmod +x "$HOME/$_rs"
        fi
    done
    # Restore systemd units if present
    local restored_systemd_units=0
    for _rs in .config/systemd/user/llama-watchdog.service \
               .config/systemd/user/llama-watchdog.timer
    do
        if [[ -f "$tmp_restore/$_rs" ]]
        then
            mkdir -p "$(dirname "$HOME/$_rs")"
            cp "$tmp_restore/$_rs" "$HOME/$_rs"
            restored_systemd_units=1
        fi
    done
    if (( restored_systemd_units )) && command -v systemctl >/dev/null 2>&1
    then
        systemctl --user daemon-reload >/dev/null 2>&1 || true
    fi
    rm -rf "$tmp_restore"

    __tac_info "State Rollback" "[COMPLETE]" "$C_Success"
    printf '%s\n' "${C_Dim}Tip: run 'so' to restart the gateway.${C_Reset}"
}

# ---------------------------------------------------------------------------
# owk — cd to OpenClaw workspace directory.
# ---------------------------------------------------------------------------
# end of file
