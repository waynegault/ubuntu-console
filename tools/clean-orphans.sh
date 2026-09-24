#!/usr/bin/env bash
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 5
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
#   4. A bench stops llama-watchdog.timer for its duration and restarts it in a
#      finally block — which SIGKILL skips, leaving the CUDA lane unmanaged with
#      nothing to show that anything is wrong.
#
# Restoring the watchdog timer (item 4) is deliberately gated on leftovers
# actually being found. "Enabled but inactive" is ambiguous on its own — it is
# also exactly what a deliberate `systemctl --user stop` looks like — so this
# tool only concludes that a killed bench left it stopped when that same kill
# left other evidence behind (a stale lock, stale keeper files, or orphans).
#
# Usage:    clean-orphans          — Show matching processes, prompt before kill
#           clean-orphans --force  — Kill without prompting
#           clean-orphans --check  — Just report, don't kill
# ==============================================================================
set -euo pipefail

# warn — the ONE place this tool writes to stderr.  §18.3 item 10.7 counts ad-hoc
# `echo … >&2` because a per-file helper keeps the prefix and the stream in a single
# place; six more hand-written ones tripped the ratchet, which is the counter doing
# its job rather than noise to re-baseline away.
warn() { printf '[clean-orphans] %s\n' "$*" >&2; }

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
# /proc/PID/cwd is ALREADY canonical (no trailing slash, symlinks resolved), so
# normalise the configured dir the same way — otherwise a trailing slash or a
# symlinked path makes every comparison fail and the guards reap nothing.
KEEPER_DIR="${LLM_KEEPER_DIR:-/tmp}"
KEEPER_DIR=$(realpath -m -- "$KEEPER_DIR" 2>/dev/null || printf '%s' "$KEEPER_DIR")

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

# True when $1 is this process or one of its ancestors — a cleanup tool must
# never target its own process tree.
is_self_or_ancestor() {
    local pid="$1" cur="$$" hops=0
    while [[ -n "$cur" && "$cur" != "0" ]] && (( hops < 20 )); do
        if [[ "$cur" == "$pid" ]]; then
            return 0
        fi
        cur=$(ps -o ppid= -p "$cur" 2>/dev/null | tr -d '[:space:]') || cur=""
        if [[ -z "$cur" ]]; then
            return 1
        fi
        hops=$(( hops + 1 ))
    done
    return 1
}

# True when $1 is (or descends from) a live model-shell wrapper, i.e. a keeper
# that belongs to an active `model use` session. The keeper's `sleep 3600` is a
# grandchild of the model shell (model shell -> keeper subshell -> sleep), so the
# walk covers several hops; the live list holds only the model-shell PID.
is_live_owned() {
    local pid="$1" parent hops=0
    [[ -n "$pid" ]] || return 1
    while [[ -n "$pid" && "$pid" != "0" ]] && (( hops < 4 )); do
        if [[ " ${LIVE_MODEL_SHELLS[*]:-} " == *" ${pid} "* ]]; then
            return 0
        fi
        parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]') || parent=""
        if [[ -z "$parent" ]]; then
            return 1
        fi
        pid="$parent"
        hops=$(( hops + 1 ))
    done
    return 1
}

# 1. Processes actually holding an open /tmp/llm-stdin.* FIFO (the keeper's fd 3
#    and the server's stdin). `find -lname` resolves the fd symlinks in C — a
#    per-fd bash `readlink` loop over all of /proc is ~400x slower on WSL — so a
#    shell that merely MENTIONS "llm-stdin" on its command line is not a target,
#    and a live session's server/keeper is spared by the ownership guard.
while IFS= read -r fd_path; do
    pid="${fd_path#/proc/}"
    pid="${pid%%/*}"
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    if is_self_or_ancestor "$pid"; then continue; fi
    if is_live_owned "$pid"; then continue; fi
    add_orphan "$pid" "$(ps -p "$pid" -o args= 2>/dev/null || true)"
done < <(find /proc/[0-9]*/fd -lname '*llm-stdin*' 2>/dev/null || true)

# 2. Keeper subshells named by a keeper PID file. The PID file holds the keeper
# SUBSHELL, whose argv is inherited from the model shell — so it never reads
# "sleep 3600". Identify it by its cwd (the keeper `cd`s to KEEPER_DIR) and take
# ownership from its parent, which is the model-shell wrapper for a live run.
for keeper_file in "$KEEPER_DIR"/llm-keeper.*.pid; do
    [[ -f "$keeper_file" ]] || continue
    keeper_pid=$(cat "$keeper_file" 2>/dev/null || true)
    [[ "$keeper_pid" =~ ^[0-9]+$ ]] || continue
    kill -0 "$keeper_pid" 2>/dev/null || continue
    [[ "$(readlink "/proc/$keeper_pid/cwd" 2>/dev/null || true)" == "$KEEPER_DIR" ]] || continue
    if is_self_or_ancestor "$keeper_pid"; then continue; fi
    if is_live_owned "$keeper_pid"; then continue; fi
    add_orphan "$keeper_pid" "keeper subshell (orphaned; pid file $keeper_file)"
done

# 2b. Keeper sleep loops that lost their PID file, or were reparented. The
# matched process is the keeper's `sleep 3600`; ownership is decided from its
# ancestry (is_live_owned walks up to the model-shell wrapper).
while read -r pid cmd; do
    if [[ "$pid" =~ ^[0-9]+$ ]] && [[ "$cmd" == *"sleep 3600"* ]]; then
        # Only keepers whose cwd is THIS keeper dir (see LLM_KEEPER_DIR).
        [[ "$(readlink "/proc/$pid/cwd" 2>/dev/null || true)" == "$KEEPER_DIR" ]] || continue
        if is_self_or_ancestor "$pid"; then continue; fi
        if is_live_owned "$pid"; then continue; fi
        add_orphan "$pid" "$cmd"
    fi
done < <(pgrep -af 'sleep 3600' 2>/dev/null || true)

# 3. llama-server instances spawned by bench (have --no-mmap, no terminal).
# NOTE: ordinary `model use` servers also launch with --no-mmap on WSL. Protect
# the live port owner on BOTH the interactive and service ports, skip any server
# owned by a live model shell, and fail closed (skip the reaper) when the port
# owner cannot be resolved — never risk killing a live server.
LLM_PORT="${LLM_PORT:-8081}"
LLM_SERVICE_PORT="${LLM_SERVICE_PORT:-18081}"
PORT_OWNERS=""
if command -v ss >/dev/null 2>&1; then
    for _port in "$LLM_PORT" "$LLM_SERVICE_PORT"; do
        _o=$(ss -ltnpH "sport = :$_port" 2>/dev/null | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2 || true)
        if [[ -n "$_o" ]]; then
            PORT_OWNERS+=" $_o"
        fi
    done
else
    warn "Warning: 'ss' not found — cannot resolve the live port owner; skipping the server reaper."
fi
while read -r pid cmd; do
    if [[ "$pid" =~ ^[0-9]+$ ]] && [[ "$cmd" == *"llama-server"*"no-mmap"* ]]; then
        if is_self_or_ancestor "$pid"; then continue; fi
        if is_live_owned "$pid"; then continue; fi
        if [[ -z "$PORT_OWNERS" ]]; then continue; fi
        [[ " $PORT_OWNERS " == *" $pid "* ]] && continue
        add_orphan "$pid" "$cmd"
    fi
done < <(pgrep -af 'llama-server.*no-mmap' 2>/dev/null || true)

# 4. Stale bench PID and lock files (honour the configurable paths — the same
#    variables the rest of the script and the deletion step use).
STALE_LOCK=0
STALE_PID=0
[[ -f "$BENCH_LOCK_FILE" ]] && STALE_LOCK=1
[[ -f "$BENCH_PID_FILE" ]] && STALE_PID=1

# 5. Stale keeper PID files — only those whose recorded keeper is actually gone
#    (a live keeper's file is not stale and must be preserved).
STALE_KEEPERS=0
for f in "$KEEPER_DIR"/llm-keeper.*.pid; do
    [[ -f "$f" ]] || continue
    _kp=$(cat "$f" 2>/dev/null || true)
    if [[ ! "$_kp" =~ ^[0-9]+$ ]] || ! kill -0 "$_kp" 2>/dev/null; then
        STALE_KEEPERS=1
        break
    fi
done

# 6. A killed bench stops llama-watchdog.timer and restarts it in a `finally`,
#    which SIGKILL skips. On its own, "enabled but inactive" proves nothing — it
#    is also what a deliberate `systemctl --user stop` looks like — so this is
#    only acted on when something above proves a kill actually happened.
WATCHDOG_TIMER="${LLAMA_WATCHDOG_TIMER_UNIT:-llama-watchdog.timer}"
WATCHDOG_STOPPED=0
if command -v systemctl >/dev/null 2>&1; then
    _wd_active=$(systemctl --user is-active "$WATCHDOG_TIMER" 2>/dev/null | tr -d ' \n' || true)
    if [[ "$_wd_active" != "active" ]]; then
        _wd_enabled=$(systemctl --user is-enabled "$WATCHDOG_TIMER" 2>/dev/null | tr -d ' \n' || true)
        if [[ "$_wd_enabled" == "enabled" ]]; then
            WATCHDOG_STOPPED=1
        fi
    fi
fi

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
(( STALE_LOCK == 1 )) && echo "  Stale lock: $BENCH_LOCK_FILE"
(( STALE_PID == 1 )) && echo "  Stale PID:  $BENCH_PID_FILE"
(( STALE_KEEPERS == 1 )) && echo "  Stale keeper PID files in $KEEPER_DIR/llm-keeper.*.pid"
if (( WATCHDOG_STOPPED == 1 )); then
    echo "  Stopped unit: $WATCHDOG_TIMER (enabled, so a kill left it off rather than a deliberate stop)"
fi

if (( CHECK == 1 )); then
    exit 0
fi

if (( FORCE == 0 )); then
    echo ""
    # A closed/absent stdin must not abort under `set -e` before the explicit
    # cancel path runs (non-TTY callers: MCP tools, agents, cron, systemd).
    if ! read -r -p "Kill these processes and clean up? [y/N] " reply; then
        warn "No input available — not cleaning up (use --force to skip the prompt)."
        exit 1
    fi
    case "$reply" in
        y|Y|yes|YES) ;;
        *)
            echo "[clean-orphans] Cancelled."
            exit 1
            ;;
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

# SIGKILL any survivors — and CHECK it, then VERIFY it.  This is the CUDA-holding
# path: a llama-server that survives a KILL while we report it killed is how a later
# start ends up as a second CUDA context on the same card (the host dxgkrnl -512
# class).  The KILL is deliberately NOT redirected: when it fails, kill(1)'s own
# reason belongs on stderr rather than being swallowed by a redirect.
_co_failed=0
for entry in "${ORPHANS[@]}"; do
    IFS='|' read -r pid cmd <<< "$entry"
    if kill -0 "$pid" 2>/dev/null; then
        if kill -KILL "$pid"; then
            echo "[clean-orphans] Sent KILL to PID $pid"
        else
            warn "WARNING: KILL failed for PID $pid — it may still be running: $cmd"
            (( _co_failed = _co_failed + 1 ))
        fi
        if kill -0 "$pid" 2>/dev/null; then
            # kill(2) said yes and the process is still there: a zombie, or a signal
            # that did not take.  Either way it is NOT gone, and saying "cleaned"
            # about it is the failure this whole pass exists to stop.
            warn "WARNING: PID $pid is STILL PRESENT after KILL"
            (( _co_failed = _co_failed + 1 ))
        fi
    fi
done

# Clean stale files — never remove a live bench's lock/PID (gate on BENCH_ACTIVE),
# and only remove keeper PID files whose process is actually gone.
if (( BENCH_ACTIVE == 0 )); then
    if ! rm -f "$BENCH_LOCK_FILE" "$BENCH_PID_FILE"; then
        warn "WARNING: could not remove $BENCH_LOCK_FILE / $BENCH_PID_FILE"
        (( _co_failed = _co_failed + 1 ))
    fi
fi
for keeper_file in "$KEEPER_DIR"/llm-keeper.*.pid; do
    [[ -f "$keeper_file" ]] || continue
    keeper_pid=$(cat "$keeper_file" 2>/dev/null || true)
    if [[ ! "$keeper_pid" =~ ^[0-9]+$ ]] || ! kill -0 "$keeper_pid" 2>/dev/null; then
        if ! rm -f "$keeper_file"; then
            warn "WARNING: could not remove stale keeper file $keeper_file"
            (( _co_failed = _co_failed + 1 ))
        fi
    fi
done
# The line below used to say this unconditionally, which is the "reported a clean it
# never verified" shape this repo already fixed once for the docker prune (39f2fb08).
if (( _co_failed == 0 ))
then
    echo "[clean-orphans] Stale files removed."
else
    warn "Stale files removed, but $_co_failed step(s) FAILED — see the warnings above."
fi

# Restore the watchdog a killed bench left stopped. Reached only when leftovers
# were found above, so a deliberate `systemctl --user stop` is never overridden.
if (( WATCHDOG_STOPPED == 1 )); then
    if systemctl --user start "$WATCHDOG_TIMER" 2>/dev/null; then
        echo "[clean-orphans] Restarted $WATCHDOG_TIMER (a kill had left it stopped)."
    else
        warn "WARNING: could not restart $WATCHDOG_TIMER — start it by hand: systemctl --user start $WATCHDOG_TIMER"
    fi
fi

if (( _co_failed == 0 ))
then
    echo "[clean-orphans] Done."
else
    # Exit code left as-is on purpose: this is an interactive tool and its callers
    # read the output; making the code carry the failure is a separate decision.
    warn "Done, with $_co_failed FAILED step(s) — see the warnings above."
fi
# end of file
