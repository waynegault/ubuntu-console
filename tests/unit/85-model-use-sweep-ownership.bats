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

# end of file
