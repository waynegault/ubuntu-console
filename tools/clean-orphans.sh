#!/home/linuxbrew/.linuxbrew/bin/bash
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

# Gather orphan processes
declare -a ORPHANS=()

# 1. Stdin keepers: bash processes holding open /tmp/llm-stdin.* FIFOs
while IFS='|' read -r pid cmd; do
    pid="${pid// /}"
    if [[ "$pid" =~ ^[0-9]+$ ]] && [[ "$cmd" == *"llm-stdin"* ]]; then
        ORPHANS+=("$pid|$cmd")
    fi
done < <(ps -eo pid,args --no-headers 2>/dev/null | grep 'llm-stdin' || true)

# 2. sleep loops that are children of init (reparented orphans)
while IFS='|' read -r pid ppid cmd; do
    pid="${pid// /}"
    ppid="${ppid// /}"
    if [[ "$ppid" == "1" ]] && [[ "$pid" =~ ^[0-9]+$ ]] && [[ "$cmd" == *"sleep"* ]]; then
        ORPHANS+=("$pid|$cmd")
    fi
done < <(ps -eo pid,ppid,args --no-headers 2>/dev/null | grep -E 'sleep (3600|86400)' || true)

# 3. llama-server instances spawned by bench (have --no-mmap, no terminal)
while IFS='|' read -r pid cmd; do
    pid="${pid// /}"
    if [[ "$pid" =~ ^[0-9]+$ ]] && [[ "$cmd" == *"llama-server"*"no-mmap"* ]]; then
        ORPHANS+=("$pid|$cmd")
    fi
done < <(ps -eo pid,args --no-headers 2>/dev/null | grep 'llama-server' | grep 'no-mmap' || true)

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
