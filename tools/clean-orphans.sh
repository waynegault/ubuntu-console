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
        *) ;;
    esac
done

# Keeper PID files live in LLM_KEEPER_DIR (production /tmp); the keeper also
# runs with that as its cwd, which is how the fallback reaper attributes one.
KEEPER_DIR="${LLM_KEEPER_DIR:-/tmp}"

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

# Safety guard 2: do not reap (or delete the lock/PID of) a live bench. The
# bench holds /tmp/llm-bench.lock (content = owner PID) and /tmp/llm-bench.pid;
# deleting the lock file merely for existing would drop the flock and let a
# second bench start concurrently.
BENCH_LOCK_FILE="${LLM_BENCH_LOCK_FILE:-/tmp/llm-bench.lock}"
BENCH_PID_FILE="${LLM_BENCH_PID_FILE:-/tmp/llm-bench.pid}"
BENCH_ACTIVE=0
if [[ -f "$BENCH_LOCK_FILE" ]]; then
    _bench_lock_owner=$(< "$BENCH_LOCK_FILE")
    if [[ "$_bench_lock_owner" =~ ^[0-9]+$ ]] && kill -0 "$_bench_lock_owner" 2>/dev/null; then
        BENCH_ACTIVE=1
    fi
fi
if (( BENCH_ACTIVE == 0 )) && [[ -f "$BENCH_PID_FILE" ]]; then
    _bench_pid=$(< "$BENCH_PID_FILE")
    if [[ "$_bench_pid" =~ ^[0-9]+$ ]] && kill -0 "$_bench_pid" 2>/dev/null; then
        BENCH_ACTIVE=1
    fi
fi

if (( BENCH_ACTIVE == 1 )) && [[ "${CLEAN_ORPHANS_IGNORE_ACTIVE_BENCH:-0}" != "1" ]]; then
    echo "[clean-orphans] Active bench detected (lock/PID owner alive, lock=$BENCH_LOCK_FILE)."
    echo "[clean-orphans] Refusing cleanup to avoid killing a live run."
    echo "[clean-orphans] If this is definitely stale, rerun with CLEAN_ORPHANS_IGNORE_ACTIVE_BENCH=1."
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
for keeper_file in "$KEEPER_DIR"/llm-keeper.*.pid; do
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
        # Only keepers whose cwd is THIS keeper dir (see LLM_KEEPER_DIR).
        [[ "$(readlink "/proc/$pid/cwd" 2>/dev/null || true)" == "$KEEPER_DIR" ]] || continue
        ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
        if [[ -z "$ppid" ]] || [[ "$ppid" == "1" ]] || ! [[ " ${LIVE_MODEL_SHELLS[*]} " == *" ${ppid} "* ]]; then
            add_orphan "$pid" "$cmd"
        fi
    fi
done < <(pgrep -af 'sleep 3600' 2>/dev/null || true)

# 3. llama-server instances spawned by bench (have --no-mmap, no terminal).
# NOTE: ordinary `model use` servers also launch with --no-mmap on WSL, so this
# must never reap the live port owner or a child of a live model shell.
LLM_PORT="${LLM_PORT:-18081}"
PORT_OWNER=""
if command -v ss >/dev/null 2>&1; then
    PORT_OWNER=$(ss -ltnpH "sport = :$LLM_PORT" 2>/dev/null | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2 || true)
fi
while read -r pid cmd; do
    if [[ "$pid" =~ ^[0-9]+$ ]] && [[ "$cmd" == *"llama-server"*"no-mmap"* ]]; then
        [[ -n "$PORT_OWNER" && "$pid" == "$PORT_OWNER" ]] && continue
        server_ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
        [[ -n "$server_ppid" && " ${LIVE_MODEL_SHELLS[*]:-} " == *" ${server_ppid} "* ]] && continue
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
for f in "$KEEPER_DIR"/llm-keeper.*.pid; do
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
(( STALE_KEEPERS == 1 )) && echo "  Stale keeper PID files in $KEEPER_DIR/llm-keeper.*.pid"

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

# Clean stale files — never remove a live bench's lock/PID (gate on BENCH_ACTIVE),
# and only remove keeper PID files whose process is actually gone.
if (( BENCH_ACTIVE == 0 )); then
    rm -f "$BENCH_LOCK_FILE" "$BENCH_PID_FILE"
fi
for keeper_file in "$KEEPER_DIR"/llm-keeper.*.pid; do
    [[ -f "$keeper_file" ]] || continue
    keeper_pid=$(< "$keeper_file")
    if [[ ! "$keeper_pid" =~ ^[0-9]+$ ]] || ! kill -0 "$keeper_pid" 2>/dev/null; then
        rm -f "$keeper_file"
    fi
done
echo "[clean-orphans] Stale files removed."

echo "[clean-orphans] Done."
# end of file
