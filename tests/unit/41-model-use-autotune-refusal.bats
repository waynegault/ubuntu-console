#!/usr/bin/env bats
# ==============================================================================
# Unit — model use: the AUTOTUNE-002 no-ctx refusal is not discarded
# ==============================================================================
# WHY THIS EXISTS (AUDIT-2026-10-02, card a370221d): __model_use guarded four of
# its six steps with `|| return 1`, but called the last two bare:
#
#     __model_use_configure_params
#     __model_use_build_command
#
# __model_use_configure_params returns 21 on the deliberate AUTOTUNE-002 refusal
# (the models.conf row has no autotuned ctx and no --ctx-size was given).  With the
# call unguarded that status was discarded, the orchestrator continued into
# build_command and then launched the server anyway — with no certified context, on
# the exact path the refusal exists to stop.  `model use N` reported success.
#
# These cases assert the PROPERTY, not the row: `model use` must exit non-zero and
# must NOT reach the launcher.  Everything between resolve_model and the refusal is
# stubbed (it downloads / touches the CUDA card), so the only real code under test
# is the guard and the real AUTOTUNE-002 branch.
#
# FALSIFICATION (2026-10-02): run against the pre-fix file, the two "aborts the
# launch" cases fail — the launcher marker is created and `model use` exits 0.
#
# HERMETIC: HOME, LLM_REGISTRY and LLAMA_MODEL_DIR are sandboxed; the launcher and
# the box-touching steps are stubbed, so no server starts and no download runs.
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

    # Flattened rows: assertions match the status words without colour codes.
    __tac_line() { printf 'LINE %s\n' "$*"; }
    __tac_info() { printf 'INFO %s\n' "$*"; }

    # Sandbox the registry, AFTER the source so 01-constants.sh cannot win.  Row 1
    # is field 8 (ctx) EMPTY and autotuned=no — the row AUTOTUNE-002 refuses.
    export LLM_REGISTRY="$SANDBOX/models.conf"
    export LLAMA_MODEL_DIR="$SANDBOX/models"
    mkdir -p "$LLAMA_MODEL_DIR"
    cat > "$LLM_REGISTRY" <<'EOF'
#|name|file|size_gb|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|fit_target_mb|backend|mmap_mode|flash_attn|tps|autotuned|is_default|in_vram
1|NoCtx|nctx.gguf|1.0G|Q4_K_M/q8_0|qwen2|24||6|1024|256|1|256|llama_server|auto|on|11.0|no|no|no
EOF

    # The launch records itself here; a refused step must never create it.
    LAUNCH_MARKER="$SANDBOX/launched"
    export LAUNCH_MARKER

    unset TAC_CTX_SIZE ctx threads
}

teardown() {
    cd /
    rm -rf "$SANDBOX"
}

# _stub_side_steps — replace the steps that touch the network or the box, and the
# launcher/wait.  resolve_model and __model_use_configure_params stay REAL: the
# former reads the seeded row, the latter is where the refusal is raised.
_stub_side_steps() {
    __model_use_ensure_downloaded() { return 0; }
    __model_use_select_backend() { return 0; }
    __model_use_claim_cuda_card() { return 0; }
    __model_use_launch_server() { : > "$LAUNCH_MARKER"; return 0; }
    __model_use_wait_healthy() { return 0; }
}

@test "configure_params: a row with no ctx and no --ctx-size returns the AUTOTUNE-002 status (21)" {
    # The carried status the guard has to stop on.
    ctx=""

    run __model_use_configure_params

    [ "$status" -eq 21 ]
    [[ "$output" == *"No context for model"* ]]
    [[ "$output" == *"AUTOTUNE-002"* ]]
}

@test "model use: the AUTOTUNE-002 no-ctx refusal aborts the launch" {
    _stub_side_steps

    run model use 1

    [ "$status" -ne 0 ]
    [[ "$output" == *"No context for model"* ]]
    # The property: nothing was launched.
    [ ! -e "$LAUNCH_MARKER" ]
}

@test "model use: a failing build_command is not discarded either" {
    # The second unguarded call.  build_command is documented "returns 0 always"
    # today, but the guard is what stops a future non-zero return from launching.
    _stub_side_steps
    __model_use_configure_params() { return 0; }
    __model_use_build_command() { return 1; }

    run model use 1

    [ "$status" -ne 0 ]
    [ ! -e "$LAUNCH_MARKER" ]
}

@test "model use: a successful configure step still reaches the launch" {
    # The other direction: the guard must not refuse the healthy path.
    _stub_side_steps
    __model_use_configure_params() { return 0; }

    run model use 1

    [ "$status" -eq 0 ]
    [ -e "$LAUNCH_MARKER" ]
}

# end of file
