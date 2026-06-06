#!/usr/bin/env bash
# ==============================================================================
# clean-orphans.sh — Kill orphaned model bench infrastructure.
#
# Purpose:  Clean up leftover llama-server, stdin keeper (sleep-loop),
#           and bench processes that accumulate when model bench or
#           llama-server is killed abruptly.
#
# These orphans happen because:
#   1. llama-server uses a FIFO stdin keeper (bash subshell with sleep loop)
#      that gets reparented to init/1 when the parent is killed.
#   2. The bench lock file /tmp/llm-bench.lock survives SIGKILL.
#   3. Sleeping keeper processes can accumulate across VS Code terminal sessions.
#
# Usage:    clean-orphans          — Show matching processes, prompt before kill
#           clean-orphans --force  — Kill without prompting
#           clean-orphans --check  — Just report, don't kill
# ==============================================================================
set -euo pipefail

FORCE=0
CHECK=0
for arg in "$@"; do
    case "$arg" in
        --force|-f) FORCE=1 ;;
        --check|-c) CHECK=1 ;;
    esac
done

# Safety guard: do not reap processes while an active autotune session owns the
# lock. This prevents accidental termination of legitimate in-flight probes.
AUTOTUNE_LOCK_FILE="${LLM_AUTOTUNE_LOCK_FILE:-/tmp/llm-autotune.lock}"
AUTOTUNE_OWNER_PID=""
AUTOTUNE_ACTIVE=0
if [[ -f "$AUTOTUNE_LOCK_FILE" ]]; then
    AUTOTUNE_OWNER_PID=$(cat "$AUTOTUNE_LOCK_FILE" 2>/dev/null || true)
    if [[ "$AUTOTUNE_OWNER_PID" =~ ^[0-9]+$ ]] && kill -0 "$AUTOTUNE_OWNER_PID" 2>/dev/null; then
        AUTOTUNE_ACTIVE=1
    fi
fi

if (( AUTOTUNE_ACTIVE == 1 )) && [[ "${CLEAN_ORPHANS_IGNORE_ACTIVE_AUTOTUNE:-0}" != "1" ]]; then
    echo "[clean-orphans] Active autotune detected (owner PID=$AUTOTUNE_OWNER_PID, lock=$AUTOTUNE_LOCK_FILE)."
    echo "[clean-orphans] Refusing cleanup to avoid killing a live run."
    echo "[clean-orphans] If this is definitely stale, rerun with CLEAN_ORPHANS_IGNORE_ACTIVE_AUTOTUNE=1."
    exit 2
fi

# Gather orphan processes
declare -a ORPHANS=()
declare -A SEEN_PIDS=()
declare -a LIVE_MODEL_SHELLS=()

add_orphan() {
    local pid="$1"
    local cmd="$2"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 0
    [[ -n "${SEEN_PIDS[$pid]:-}" ]] && return 0
    SEEN_PIDS["$pid"]=1
    ORPHANS+=("$pid|$cmd")
}

# Live model-shell wrappers are allowed to own keeper sleeps.
for modelshell_file in /tmp/llm-modelshell.*.pid /tmp/llm-modelshell.pid; do
    [[ -f "$modelshell_file" ]] || continue
    modelshell_pid=$(< "$modelshell_file")
    [[ "$modelshell_pid" =~ ^[0-9]+$ ]] || continue
    if kill -0 "$modelshell_pid" 2>/dev/null; then
        LIVE_MODEL_SHELLS+=("$modelshell_pid")
    fi
done

# 1. Stdin keepers: processes holding open /tmp/llm-stdin.* FIFOs
while read -r pid cmd; do
    if [[ "$pid" =~ ^[0-9]+$ ]] && [[ "$cmd" == *"llm-stdin"* ]]; then
        add_orphan "$pid" "$cmd"
    fi
done < <(pgrep -af 'llm-stdin' 2>/dev/null || true)

# 2. Keeper sleep loops from known keeper PID files.
# This is intentionally strict to avoid killing unrelated sleep processes on a
# shared host.
for keeper_file in /tmp/llm-keeper.*.pid; do
    [[ -f "$keeper_file" ]] || continue
    keeper_pid=$(< "$keeper_file")
    [[ "$keeper_pid" =~ ^[0-9]+$ ]] || continue
    if kill -0 "$keeper_pid" 2>/dev/null; then
        keeper_cmd=$(ps -p "$keeper_pid" -o args= 2>/dev/null || true)
        keeper_ppid=$(ps -o ppid= -p "$keeper_pid" 2>/dev/null | tr -d '[:space:]')
        if [[ "$keeper_cmd" == *"sleep 3600"* ]] && {
            [[ "$keeper_ppid" == "1" ]] || ! [[ " ${LIVE_MODEL_SHELLS[*]} " == *" ${keeper_ppid} "* ]];
        }; then
            add_orphan "$keeper_pid" "$keeper_cmd"
        fi
    fi
done

# 2b. Keeper sleep loops that lost their PID file or were reparented to an
# unexpected shell by the terminal relay.
while read -r pid cmd; do
    if [[ "$pid" =~ ^[0-9]+$ ]] && [[ "$cmd" == *"sleep 3600"* ]]; then
        ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
        if [[ -z "$ppid" ]] || [[ "$ppid" == "1" ]] || ! [[ " ${LIVE_MODEL_SHELLS[*]} " == *" ${ppid} "* ]]; then
            add_orphan "$pid" "$cmd"
        fi
    fi
done < <(pgrep -af 'sleep 3600' 2>/dev/null || true)

# 3. llama-server instances spawned by bench (have --no-mmap, no terminal)
while read -r pid cmd; do
    if [[ "$pid" =~ ^[0-9]+$ ]] && [[ "$cmd" == *"llama-server"*"no-mmap"* ]]; then
        add_orphan "$pid" "$cmd"
    fi
done < <(pgrep -af 'llama-server.*no-mmap' 2>/dev/null || true)

# 4. Stale bench PID and lock files
STALE_LOCK=0
STALE_PID=0
[[ -f /tmp/llm-bench.lock ]] && STALE_LOCK=1
[[ -f /tmp/llm-bench.pid ]] && STALE_PID=1

# 5. Stale keeper PID files
STALE_KEEPERS=0
for f in /tmp/llm-keeper.*.pid; do
    [[ -f "$f" ]] && STALE_KEEPERS=1 && break
done

# Report
if (( ${#ORPHANS[@]} == 0 )) && (( STALE_LOCK == 0 )) && (( STALE_PID == 0 )) && (( STALE_KEEPERS == 0 )); then
    echo "[clean-orphans] No orphan processes or stale files found."
    exit 0
fi

echo "[clean-orphans] Found:"
if (( ${#ORPHANS[@]} > 0 )); then
    echo "  Processes to kill:"
    for entry in "${ORPHANS[@]}"; do
        IFS='|' read -r pid cmd <<< "$entry"
        echo "    PID=$pid  CMD=${cmd:0:100}"
    done
fi
(( STALE_LOCK == 1 )) && echo "  Stale lock: /tmp/llm-bench.lock"
(( STALE_PID == 1 )) && echo "  Stale PID:  /tmp/llm-bench.pid"
(( STALE_KEEPERS == 1 )) && echo "  Stale keeper PID files in /tmp/llm-keeper.*.pid"

if (( CHECK == 1 )); then
    exit 0
fi

if (( FORCE == 0 )); then
    echo ""
    read -r -p "Kill these processes and clean up? [y/N] " reply
    case "$reply" in
        y|Y|yes|YES) ;;
        *) echo "[clean-orphans] Cancelled."; exit 1 ;;
    esac
fi

# Kill processes
for entry in "${ORPHANS[@]}"; do
    IFS='|' read -r pid cmd <<< "$entry"
    if kill -TERM "$pid" 2>/dev/null; then
        echo "[clean-orphans] Sent TERM to PID $pid"
    fi
done

sleep 1

# SIGKILL any survivors
for entry in "${ORPHANS[@]}"; do
    IFS='|' read -r pid cmd <<< "$entry"
    if kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null
        echo "[clean-orphans] Sent KILL to PID $pid"
    fi
done

# Clean stale files
rm -f /tmp/llm-bench.lock /tmp/llm-bench.pid /tmp/llm-keeper.*.pid
echo "[clean-orphans] Stale files removed."

echo "[clean-orphans] Done."
