#!/usr/bin/env bats
# ==============================================================================
# Unit — model use: a live sweep/bench ownership mark is checked BEFORE any lane stops
# ==============================================================================
# WHY THIS EXISTS (measured 2026-11-07T12:18:47Z, closed 2026-11-08): the coder lane
# llama-cuda-qwen3coder-30b-chat.service was stopped (status=9/KILL, 14.1G memory peak)
# by a `model use` that arrived while another run held the card.  The ordering was the
# defect, not the message:
#
#   __model_use_claim_cuda_card:
#     step 1  foreign GPU lock ............ refuse
#     step 2  STOP THE CUDA LANES ......... runs regardless
#     step 3  _tac_suspend_acquire ........ fails -> Warning -> return 0
#
# So the lane was already down by the time anything looked at the marker, and the
# command reported success afterwards.  A marker reader existed; it was simply on the
# wrong side of the destructive step.  This is the green-because-out-of-scope shape
# applied to ordering: "the marker is honoured" was true of step 3 and false of the
# function.
#
# WHAT THESE CASES ASSERT: the PROPERTY — when the marker is held by a live pid, no
# lane-stop command is issued and model use returns non-zero.  The stop call is a
# recording stub, so the assertion is "nothing was stopped", not "a line was printed".
#
# FALSIFICATION: with step 1b removed, the first case fails twice over — the stub
# records a stop and `model use` exits 0.  Verified against the pre-change file.
#
# HERMETIC: HOME, registry and model dir are sandboxed; systemctl, the launcher and the
# download are stubbed.  Nothing touches the card, no server starts.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export REPO_ROOT
    SANDBOX="$(mktemp -d)"
    export SANDBOX
    export HOME="$SANDBOX/home"
    export TAC_TEST_TMPDIR="$SANDBOX/tac"
    export TAC_CACHE_DIR="$SANDBOX/cache"
    mkdir -p "$HOME" "$TAC_TEST_TMPDIR" "$TAC_CACHE_DIR"

    # shellcheck source=env.sh
    source "$REPO_ROOT/env.sh"

    __tac_line() { printf 'LINE %s\n' "$*"; }
    __tac_info() { printf 'INFO %s\n' "$*"; }

    export LLM_REGISTRY="$SANDBOX/models.conf"
    export LLAMA_MODEL_DIR="$SANDBOX/models"
    mkdir -p "$LLAMA_MODEL_DIR"
    # A healthy row: ctx present, autotuned=yes — so nothing else can refuse this run.
    cat > "$LLM_REGISTRY" <<'EOF'
#|name|file|size_gb|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|fit_target_mb|backend|mmap_mode|flash_attn|tps|autotuned|is_default|in_vram
1|Ready|ready.gguf|1.0G|Q4_K_M/q8_0|qwen2|24|8192|6|1024|256|1|256|llama_server|auto|on|11.0|yes|no|no
EOF

    LAUNCH_MARKER="$SANDBOX/launched"
    STOP_LOG="$SANDBOX/stopped"
    export LAUNCH_MARKER STOP_LOG
    : > "$STOP_LOG"

    # The suspend marker this test controls.
    export LLAMA_WATCHDOG_CUDA_SUSPEND_FILE="$SANDBOX/suspend"

    # systemctl is the lane-stop path; record every stop instead of performing it.
    systemctl() {
        if [[ "${1:-}" == "--user" && "${2:-}" == "stop" ]]; then
            printf '%s\n' "${3:-}" >> "$STOP_LOG"
            return 0
        fi
        return 1
    }
    export -f systemctl

    # Every step that touches the box, minus the one under test.
    __model_use_ensure_downloaded() { return 0; }
    __model_use_select_backend() { return 0; }
    __model_use_configure_params() { return 0; }
    __model_use_build_command() { return 0; }
    __model_use_launch_server() { : > "$LAUNCH_MARKER"; return 0; }
    __model_use_wait_healthy() { return 0; }

    unset TAC_CTX_SIZE ctx threads
}

teardown() {
    cd /
    rm -rf "$SANDBOX"
}

# A pid that is certainly alive and is not this shell: "1" would be init. Use the
# test shell's own parent, which exists for the life of the run.
_live_pid() { printf '%s\n' "$PPID"; }

@test "a marker held by a LIVE pid: no lane is stopped and model use refuses" {
    _live_pid > "$LLAMA_WATCHDOG_CUDA_SUSPEND_FILE"

    run __model_use_claim_cuda_card

    [ "$status" -ne 0 ]
    [[ "$output" == *"held by a live sweep/bench"* ]]
    # THE PROPERTY: the destructive step never ran.
    [ ! -s "$STOP_LOG" ]
}

@test "a marker held by a live pid: model use as a whole refuses and does not launch" {
    _live_pid > "$LLAMA_WATCHDOG_CUDA_SUSPEND_FILE"

    run model use 1

    [ "$status" -ne 0 ]
    [ ! -s "$STOP_LOG" ]
    [ ! -e "$LAUNCH_MARKER" ]
}

@test "a marker whose owner pid is DEAD reads as not held: the claim proceeds" {
    # A killed holder cannot release its own hold; it must never wedge the command.
    printf '999999\n' > "$LLAMA_WATCHDOG_CUDA_SUSPEND_FILE"

    run __model_use_claim_cuda_card

    [ "$status" -eq 0 ]
    # And it now owns the mark itself.
    [ "$(cat "$LLAMA_WATCHDOG_CUDA_SUSPEND_FILE")" = "$$" ]
}

@test "no marker at all: the claim proceeds" {
    rm -f "$LLAMA_WATCHDOG_CUDA_SUSPEND_FILE"

    run __model_use_claim_cuda_card

    [ "$status" -eq 0 ]
    [ -e "$LLAMA_WATCHDOG_CUDA_SUSPEND_FILE" ]
}

@test "__BENCH_MODE=1 honors an ancestor hold without refusing or overwriting the parent pid" {
    local parent_pid
    parent_pid=$(_live_pid)
    printf '%s\n' "$parent_pid" > "$LLAMA_WATCHDOG_CUDA_SUSPEND_FILE"

    run bash -c '
        export HOME="$1" TAC_TEST_TMPDIR="$2" TAC_CACHE_DIR="$3"
        export LLAMA_WATCHDOG_CUDA_SUSPEND_FILE="$4" __BENCH_MODE=1
        source "$5/env.sh"
        __tac_info() { printf "INFO %s\n" "$*"; }
        systemctl() { return 1; }
        export -f systemctl
        __model_use_claim_cuda_card
    ' _ "$HOME" "$TAC_TEST_TMPDIR" "$TAC_CACHE_DIR" "$LLAMA_WATCHDOG_CUDA_SUSPEND_FILE" "$REPO_ROOT"

    [ "$status" -eq 0 ]
    [ "$(cat "$LLAMA_WATCHDOG_CUDA_SUSPEND_FILE")" = "$parent_pid" ]
}

@test "__BENCH_MODE=1 still refuses a hold owned by an unrelated live pid" {
    sleep 30 &
    local stranger_pid=$!
    printf '%s\n' "$stranger_pid" > "$LLAMA_WATCHDOG_CUDA_SUSPEND_FILE"

    __BENCH_MODE=1 run __model_use_claim_cuda_card
    local rc=$status

    kill "$stranger_pid" 2>/dev/null || true
    wait "$stranger_pid" 2>/dev/null || true

    [ "$rc" -ne 0 ]
    [[ "$output" == *"held by a live sweep/bench"* ]]
    [ ! -s "$STOP_LOG" ]
}

@test "__model_bench holds suspend under its live pid, derives large-model timeout, and releases before restore" {
    touch "$LLAMA_MODEL_DIR/ready.gguf" "$LLAMA_MODEL_DIR/huge.gguf"
    cat > "$LLM_REGISTRY" <<'EOF'
#|name|file|size_gb|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|fit_target_mb|backend|mmap_mode|flash_attn|tps|autotuned|is_default|in_vram
1|Ready|ready.gguf|1.0G|Q4_K_M/q8_0|qwen2|24|8192|6|1024|256|1|256|llama_server|auto|on|11.0|yes|no|no
2|Huge|huge.gguf|73.3G|NVFP4/q8_0|nemotron|89|40960|10|1024|512|1|256|llama_server|auto|on|12.0|yes|no|no
EOF
    export ACTIVE_LLM_FILE="$SANDBOX/active_llm"
    printf '%s\n' "ready.gguf" > "$ACTIVE_LLM_FILE"
    local timeout_log="$SANDBOX/timeouts.log"
    local suspend_seen_log="$SANDBOX/suspend_seen.log"
    local restore_log="$SANDBOX/restore.log"

    run bash -c '
        export HOME="$1" TAC_TEST_TMPDIR="$2" TAC_CACHE_DIR="$3"
        export LLAMA_WATCHDOG_CUDA_SUSPEND_FILE="$6"
        export LLM_BENCH_LOCK_FILE="$8/bench.lock"
        export LLM_BENCH_PID_FILE="$8/bench.pid"
        export LLM_BENCH_WATCHDOG_TIMER="nonexistent-bench-test.timer"
        export LLM_BENCH_COOLDOWN_SEC=0
        export TIMEOUT_LOG="$8/timeouts.log"
        export SUSPEND_SEEN_LOG="$8/suspend_seen.log"
        export RESTORE_LOG="$8/restore.log"
        unset LLM_BENCH_MODEL_TIMEOUT
        source "$9/env.sh" >/dev/null || exit 90
        export LLM_REGISTRY="$4" LLAMA_MODEL_DIR="$5" ACTIVE_LLM_FILE="$7"
        export LLM_STATE_DIR="$8/state" LLM_TPS_CACHE="$8/tps"
        export LLM_WINDOW_MISMATCH_CACHE="$8/win_mismatch"
        mkdir -p "$LLM_STATE_DIR"
        __tac_header() { :; }
        __tac_footer() { :; }
        __tac_info() { printf "INFO %s\n" "$*"; }
        __tac_cleanup_stale_locks() { :; }
        __llm_bench_perf_prep() { :; }
        __llm_autotune_done_for_model() { return 0; }
        __model_stop() { :; }
        __gpu_clear_stale_processes() { :; }
        __resolve_smi() { return 1; }
        wake() { :; }
        sudo() { return 0; }
        systemctl() { return 1; }
        __bench_run_with_timeout() {
            printf "%s\n" "$1" >> "$TIMEOUT_LOG"
            shift
            "$@"
        }
        __model_use() {
            if [[ -n "${__BENCH_MODE:-}" ]]; then
                cat "$LLAMA_WATCHDOG_CUDA_SUSPEND_FILE" >> "$SUSPEND_SEEN_LOG"
            else
                if [[ -e "$LLAMA_WATCHDOG_CUDA_SUSPEND_FILE" ]]; then
                    echo "STILL_HELD" >> "$RESTORE_LOG"
                else
                    echo "RELEASED" >> "$RESTORE_LOG"
                fi
            fi
            return 0
        }
        burn() {
            printf "42.0 tps\n" > "$LLM_TPS_CACHE"
            return 0
        }
        __model_bench
    ' _ "$HOME" "$TAC_TEST_TMPDIR" "$TAC_CACHE_DIR" "$LLM_REGISTRY" "$LLAMA_MODEL_DIR" \
        "$LLAMA_WATCHDOG_CUDA_SUSPEND_FILE" "$ACTIVE_LLM_FILE" "$SANDBOX" "$REPO_ROOT"

    [ "$status" -eq 0 ] || { echo "status=$status output=$output"; return 1; }
    # Suspend marker was held under the bench shell pid during the loop and released before restore.
    [ ! -e "$LLAMA_WATCHDOG_CUDA_SUSPEND_FILE" ]
    [ "$(grep -c . "$suspend_seen_log")" -eq 2 ]
    [ "$(cat "$restore_log")" = "RELEASED" ]
    # Model 1 (1.0G) gets health(120) + burn(600) = 720s; Model 2 (73.3G) scales to 876 + 900 = 1776s.
    [ "$(sed -n '1p' "$timeout_log")" -ge 600 ]
    [ "$(sed -n '2p' "$timeout_log")" -gt "$(sed -n '1p' "$timeout_log")" ]
    [ "$(sed -n '2p' "$timeout_log")" -ge 1500 ]
}

# end of file
