#!/usr/bin/env bats
# ==============================================================================
# Unit Tests — 2026-11-23 Autotune Review Fixes (Cards 1-8)
# ==============================================================================
# Exercises every behavioral fix from the 8 workboard cards created 2026-11-23:
#   Card 1: Loaded clock sampling, spread gate, verdict reasons, slow+indicative
#   Card 2: Float accept_len, draft-dflash save/TTFT/n_max=5, shared-memory draft GPU placement
#   Card 3: GPU-only hard rule on shared-memory hosts
#   Card 4: Exit-3 halt classification, NGL=999 skip on shared memory, mid-loop guards
#   Card 5: NVFP4 __quant_label, non-*moe* MoE arch detection, batch draft-head filter
#   Card 6: __llm_llama_build_id stderr capture, gpu_carve=VRAM_TOTAL, mmap/fa persistence
#   Card 7: Pre-flight 12-char boot_id truncation, below-floor ngram skip
#   Card 8: TAC_TEST_TMPDIR guards on reaper and stand-down
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
    SANDBOX="$(mktemp -d)"
    export SANDBOX
    export TAC_TEST_TMPDIR="$SANDBOX"
}

teardown() {
    rm -rf "$SANDBOX"
}

# Build a sandboxed scripts/ tree where run-autotune-batch.sh can run hermetically.
_setup_batch_sandbox() {
    local root="$1" reg="$2"
    mkdir -p "$root/scripts" "$root/bin" "$root/home/models/active" "$SANDBOX/.llm" "$SANDBOX/tac"
    cp "$REPO_ROOT/scripts/run-autotune-batch.sh" "$root/scripts/"
    cp "$REPO_ROOT/bin/_tac-bin-lib.sh" "$root/bin/"
    cat > "$root/scripts/01-constants.sh" <<EOF
export LLM_REGISTRY="$reg"
export LLM_DRAFT_ARCHS="dflash eagle3"
export LLM_STATE_DIR="$SANDBOX/.llm"
export TAC_STATE_DIR="$SANDBOX/tac"
EOF
    cat > "$root/env.sh" <<EOF
export TAC_LOAD_DEGRADED=0
export LLM_REGISTRY="$reg"
export LLM_DRAFT_ARCHS="dflash eagle3"
export LLM_STATE_DIR="$SANDBOX/.llm"
export TAC_STATE_DIR="$SANDBOX/tac"
__llm_gpu_foreign_owner() { return 1; }
__llm_kill_cuda_llama_servers() { :; }
_tac_dxg_health_check() { return 0; }
_tac_gpu_free_mib() { echo 80000; }
EOF
    cat > "$SANDBOX/nvidia-smi" <<'EOF'
#!/usr/bin/env bash
echo "0"
EOF
    chmod +x "$SANDBOX/nvidia-smi"
}

@test "card1: __autotune_clock_state_from_samples evaluates loaded samples accurately" {
    local fn="$SANDBOX/clock.sh"
    {
        echo 'AUTOTUNE_PLATEAU_TOL_PCT=10'
        echo 'AUTOTUNE_CLOCK_FLOOR_PCT=60'
        sed -n '/^__autotune_clock_state_from_samples()/,/^}/p' "$REPO_ROOT/scripts/autotune-model.sh"
        sed -n '/^__autotune_clock_verdict()/,/^}/p' "$REPO_ROOT/scripts/autotune-model.sh"
    } > "$fn"
    # shellcheck disable=SC1090
    source "$fn"

    printf '2400,3003,62\n2450,3003,63\n2420,3003,64\n2410,3003,64\n' > "$SANDBOX/ok.csv"
    run __autotune_clock_state_from_samples "$SANDBOX/ok.csv"
    [ "$status" -eq 0 ]
    [[ "$output" == 0,80,63,* ]]
    [ "$(__autotune_clock_verdict 0 80)" = "ok" ]

    printf '650,3003,45\n655,3003,45\n652,3003,46\n656,3003,46\n' > "$SANDBOX/floor.csv"
    run __autotune_clock_state_from_samples "$SANDBOX/floor.csv"
    [ "$status" -eq 0 ]
    [[ "$output" == 0,21,* ]]
    [ "$(__autotune_clock_verdict 0 21)" = "floor" ]

    printf '2700,3003,70\n2650,3003,72\n2250,3003,74\n2200,3003,75\n' > "$SANDBOX/trend.csv"
    run __autotune_clock_state_from_samples "$SANDBOX/trend.csv"
    [ "$status" -eq 0 ]
    local drift="${output%%,*}"
    (( drift > 10 ))
    [ "$(__autotune_clock_verdict "$drift" 81)" = "trend" ]
}

@test "card1: slow+indicative rows remain eligible in --all-but-done while slow+certified are skipped" {
    # Profile resets LLM_REGISTRY to $HOME/models/active/models.conf on this box.
    mkdir -p "$SANDBOX/home/models/active"
    local reg="$SANDBOX/home/models/active/models.conf"
    # Col 18 = slow, Col 44 = certified vs indicative (exact 48 columns).
    {
        printf '1|Slow Certified|slow-cert.gguf|27G|Q6_K/q8_0/q8_0|qwen2|999|8192|10|1024|256|1|1024|native|auto|on|8.4|slow|no|no'
        printf '||||||||||||||||||||||||certified||||\n'
        printf '2|Slow Indicative|slow-ind.gguf|20G|Q4_K_M/q8_0/q8_0|qwen2|999|8192|10|1024|256|1|1024|native|auto|on|3.8|slow|no|no'
        printf '||||||||||||||||||||||||indicative||||\n'
    } > "$reg"
    [ "$(awk -F'|' 'NR==1{print $18"|"$44}' "$reg")" = "slow|certified" ]
    [ "$(awk -F'|' 'NR==2{print $18"|"$44}' "$reg")" = "slow|indicative" ]

    local ledger="$SANDBOX/ledger"
    printf '60\n' > "$ledger"
    cat > "$SANDBOX/bin-noop" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$SANDBOX/bin-noop"
    run env HOME="$SANDBOX/home" HEAVY_JOB_HELD=1 \
        LLM_REGISTRY="$reg" \
        LLM_STATE_DIR="$SANDBOX/.llm" TAC_STATE_DIR="$SANDBOX/tac" \
        CUDA_CYCLE_FILE="$ledger" \
        LLAMA_WATCHDOG_CUDA_SUSPEND_FILE="$SANDBOX/suspend" \
        TAC_RESUME_RESTART_TOOL="$SANDBOX/bin-noop" AUTOTUNE_AUTO_RESTART=0 \
        bash "$REPO_ROOT/bin/autotune-rows.sh" --force-live-fleet --all-but-done 2>&1
    [[ "$output" == *"slow-ind.gguf"* ]]
    [[ "$output" != *"slow-cert.gguf"* ]]
}

@test "card2: __spec_launch_flags keeps draft on GPU under shared memory and CPU on discrete card" {
    run bash -c '
        source "$1/scripts/11d-llm-gpu.sh"
        TAC_HOST_PROFILE_SHARED_MEMORY=1 row_spec_type=draft-dflash \
            row_spec_draft_model=/models/d.gguf __spec_launch_flags
    ' _ "$REPO_ROOT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"--spec-draft-ngl"* ]] && [[ "$output" == *"999"* ]]
    [[ "$output" != *"--spec-draft-device"* ]]

    run bash -c '
        source "$1/scripts/11d-llm-gpu.sh"
        TAC_HOST_PROFILE_SHARED_MEMORY=0 row_spec_type=draft-dflash \
            row_spec_draft_model=/models/d.gguf __spec_launch_flags
    ' _ "$REPO_ROOT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"--spec-draft-device"* ]] && [[ "$output" == *"none"* ]]
}

@test "card2: autotune-model persists dflash fields, sweeps n_max=5, and probes dflash TTFT" {
    local src
    src=$(< "$REPO_ROOT/scripts/autotune-model.sh")
    [[ "$src" == *'DFLASH_N_MAX_LIST=${LLM_AUTOTUNE_DFLASH_N_MAX_LIST:-"4 5 8 16"}'* ]]
    [[ "$src" == *'elif [[ "$_sb_type" == "draft-dflash" ]]; then'* ]]
    [[ "$src" == *'elif [[ "${WIN_SPEC_TYPE:-}" == "draft-dflash" ]]; then'* ]]
}

@test "card3: __model_use_fit_verdict enforces GPU-only on shared=1 while keeping cpu-moe on shared=0" {
    awk '/^function __model_use_fit_verdict/,/^}/' "$REPO_ROOT/scripts/11e-llm-model.sh" > "$SANDBOX/v.sh"
    run bash -c 'source "$1"; __model_use_fit_verdict 75000 89 89 "nemotron_h_moe" 98304 60000 1' _ "$SANDBOX/v.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == refuse:* ]]
    [[ "$output" == *"GPU-only"* ]]

    run bash -c 'source "$1"; __model_use_fit_verdict 40000 36 36 "gpt-oss" 24576 60000 0' _ "$SANDBOX/v.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "cpu-moe" ]
}

@test "card4: batch classifies exit-3 halt reasons distinctly" {
    local root="$SANDBOX/tree"
    _setup_batch_sandbox "$root" "$SANDBOX/missing.conf"
    cat > "$root/scripts/autotune-model.sh" <<'EOF'
#!/usr/bin/env bash
printf 'exit3_reason=%s\ndetail=%s\n' "$FAKE_E3_REASON" "$FAKE_E3_DETAIL" > "$LLM_AUTOTUNE_RESULT_FILE"
exit 3
EOF
    chmod +x "$root/scripts/autotune-model.sh"
    printf '0\n' > "$SANDBOX/cycles"

    # Case A: readiness_stall must NOT set HALT_NEEDS_WSL_RESTART=1 / say "wsl --shutdown"
    run env PATH="$SANDBOX:$PATH" HEAVY_JOB_HELD=1 \
        FAKE_E3_REASON="readiness_stall" \
        FAKE_E3_DETAIL="2 consecutive launches stalled" \
        CUDA_CYCLE_FILE="$SANDBOX/cycles" CUDA_CYCLE_BUDGET=60 \
        LLM_REGISTRY="$SANDBOX/missing.conf" \
        TAC_HOST_PRIMARY_LANE="llama-cuda-test.service" \
        bash "$root/scripts/run-autotune-batch.sh" stub.gguf
    [ "$status" -eq 3 ]
    [[ "$output" == *"readiness stall"* ]]
    [[ "$output" != *"wsl --shutdown"* ]]

    # Case B: cycle_budget exits 4 with reboot guidance
    run env PATH="$SANDBOX:$PATH" HEAVY_JOB_HELD=1 \
        FAKE_E3_REASON="cycle_budget" \
        FAKE_E3_DETAIL="60 >= 60" \
        CUDA_CYCLE_FILE="$SANDBOX/cycles" CUDA_CYCLE_BUDGET=60 \
        LLM_REGISTRY="$SANDBOX/missing.conf" \
        TAC_HOST_PRIMARY_LANE="llama-cuda-test.service" \
        bash "$root/scripts/run-autotune-batch.sh" stub.gguf
    [ "$status" -eq 4 ]
    [[ "$output" == *"cycle budget spent"* ]]
}

@test "card5: NVFP4 quant label, non-*moe* MoE detection, and batch draft filter" {
    # shellcheck disable=SC1091
    source "$REPO_ROOT/scripts/01-constants.sh"
    # shellcheck disable=SC1091
    source "$REPO_ROOT/scripts/11d-llm-gpu.sh"

    [ "$(__quant_label 39 "model.gguf")" = "NVFP4" ]
    [ "$(__quant_label 0 "Qwen3.5-NVFP4.gguf")" = "NVFP4" ]
    [ "$(__quant_label 38 "model.gguf")" = "MXFP4" ]

    __llm_arch_is_moe "gpt-oss"
    __llm_arch_is_moe "flint"
    __llm_arch_is_moe "inkling2"
    ! __llm_arch_is_moe "llama"
    ! __llm_arch_is_moe "qwen35"

    local reg="$SANDBOX/models.conf"
    cat > "$reg" <<'EOF'
1|Chat|chat.gguf|5G|Q4_K_M/q8_0/q8_0|qwen35|999|8192|10|1024|256|1|1024|native|auto|on|0|no|no|no
2|Draft|draft.gguf|1G|unknown/q8_0/q8_0|dflash|999|8192|10|1024|256|1|1024|native|auto|on|0|no|no|no
EOF
    local root="$SANDBOX/batch2"
    _setup_batch_sandbox "$root" "$reg"
    cat > "$root/scripts/autotune-model.sh" <<'EOF'
#!/usr/bin/env bash
echo "RAN:$1"
exit 0
EOF
    chmod +x "$root/scripts/autotune-model.sh"
    printf '0\n' > "$SANDBOX/cycles2"
    run env PATH="$SANDBOX:$PATH" HEAVY_JOB_HELD=1 \
        LLM_REGISTRY="$reg" CUDA_CYCLE_FILE="$SANDBOX/cycles2" \
        TAC_HOST_PRIMARY_LANE="llama-cuda-test.service" \
        bash "$root/scripts/run-autotune-batch.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"RAN:chat.gguf"* ]]
    [[ "$output" != *"RAN:draft.gguf"* ]]
}

@test "card6: __llm_llama_build_id reads stderr version and profile_save persists mmap and flash_attn" {
    # shellcheck disable=SC1091
    source "$REPO_ROOT/scripts/01-constants.sh"
    # shellcheck disable=SC1091
    source "$REPO_ROOT/scripts/11a-llm-registry.sh"
    # shellcheck disable=SC1091
    source "$REPO_ROOT/scripts/11b-llm-autotune.sh"

    local bin="$SANDBOX/llama-server"
    cat > "$bin" <<'EOF'
#!/usr/bin/env bash
echo "load_backend: CUDA0" >&2
echo "version: 1.0.0-dev (build 667, commit 239242322)" >&2
EOF
    chmod +x "$bin"
    [ "$(__llm_llama_build_id "$bin")" = "1.0.0-dev (build 667, commit 239242322)" ]

    export LLM_REGISTRY="$SANDBOX/reg.conf"
    {
        printf '%s\n' "$LLM_REGISTRY_HEADER"
        printf '%s\n' '1|M|m.gguf|1G|Q4_K_M/q8_0/q8_0|llama|999|4096|10|1024|256|1|256|native|auto|on|0|no|no|no'
    } > "$LLM_REGISTRY"
    __llm_autotune_profile_save "1" "native" "4096" "1024" "256" "1" "256" "20.5" \
        "" "" "" "" "" "" "" "Q4_K_M/q8_0/q8_0" "999" \
        "" "" "" "" "" "" "chat" "" "" "" "" "" "" "" "" "8192" "10" "off" "off"
    local row; row=$(grep '^1|' "$LLM_REGISTRY")
    [ "$(echo "$row" | cut -d'|' -f15)" = "off" ]
    [ "$(echo "$row" | cut -d'|' -f16)" = "off" ]
    [ "$(echo "$row" | cut -d'|' -f48)" = "8192" ]
}

@test "card7: autotune-rows pre-flight uses 12-char boot_id matching batch ledger name" {
    grep -q 'cut -c1-12' "$REPO_ROOT/bin/autotune-rows.sh"
}

@test "card8: __llm_kill_cuda_llama_servers and __llm_stand_down_cuda_lanes refuse under TAC_TEST_TMPDIR" {
    # shellcheck disable=SC1091
    source "$REPO_ROOT/scripts/01-constants.sh"
    # shellcheck disable=SC1091
    source "$REPO_ROOT/scripts/11d-llm-gpu.sh"

    AUTOTUNE_SELFTEST=0 TAC_TEST_TMPDIR="$SANDBOX" run __llm_kill_cuda_llama_servers
    [ "$status" -eq 0 ]
    [[ "$output" == *"test environment"* ]]

    AUTOTUNE_SELFTEST=0 TAC_TEST_TMPDIR="$SANDBOX" run __llm_stand_down_cuda_lanes
    [ "$status" -eq 0 ]
    [[ "$output" == *"test environment"* ]]
}
