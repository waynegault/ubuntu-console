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
# Bound the probe's own timeout too: without this each read is capped at 10s, so a stub
# that wedges costs more than the poll window it was meant to remove.
export TAC_SMI_TIMEOUT=2
__llm_gpu_foreign_owner() { return 1; }
__llm_kill_cuda_llama_servers() { :; }
_tac_dxg_health_check() { return 0; }
_tac_gpu_free_mib() { echo 80000; }
EOF
    # drain_vram breaks only on a STRICT drop, so a constant reading makes it burn all 15
    # one-second polls -- and it runs once before the loop AND once per row, which is why
    # cards 4/5 cost 30.7s/30.9s (two drains) and case 11 cost 107.4s (eight). Report a
    # lower figure on every call so the first poll breaks on iteration 1.
    cat > "$SANDBOX/nvidia-smi" <<EOF
#!/usr/bin/env bash
_n_file="$SANDBOX/smi-calls"
_n=\$(cat "\$_n_file" 2>/dev/null) || _n=0
# Decrement by ONE, never by a step: the reading must stay a positive integer for the
# batch's ^[0-9]+\$ test, and a negative figure would read as "no VRAM reading" and force
# the full drain window this stub exists to avoid. One is also still a strict drop.
printf '%s\n' "\$(( 20000 - _n ))"
printf '%s\n' "\$(( _n + 1 ))" > "\$_n_file"
EOF
    chmod +x "$SANDBOX/nvidia-smi"
    # Prove the stub wins the lookup the batch will make. A PATH stub has lost to a live
    # tool on this box before; if that happened here the suite would poll the real card
    # and pay the wait it exists to remove.
    if [[ "$(PATH="$SANDBOX:$PATH" command -v nvidia-smi)" != "$SANDBOX/nvidia-smi" ]]; then
        echo "STUB NOT RESOLVED: nvidia-smi resolves to $(PATH="$SANDBOX:$PATH" command -v nvidia-smi), not $SANDBOX/nvidia-smi" >&2
        return 1
    fi
}

@test "card1: __autotune_clock_state_from_samples evaluates loaded samples accurately" {
    local fn="$SANDBOX/clock.sh"
    {
        echo 'AUTOTUNE_PLATEAU_TOL_PCT=10'
        echo 'AUTOTUNE_CLOCK_FLOOR_PCT=60'
        sed -n '/^__autotune_clock_state_from_samples()/,/^}/p' "$REPO_ROOT/scripts/autotune-model.sh"
        sed -n '/^__autotune_clock_verdict()/,/^}/p' "$REPO_ROOT/scripts/autotune-model.sh"
    } > "$fn"
    # shellcheck source=/dev/null
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
    # shellcheck source=/dev/null
    source "$REPO_ROOT/scripts/01-constants.sh"
    # shellcheck source=/dev/null
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
    # shellcheck source=/dev/null
    source "$REPO_ROOT/scripts/01-constants.sh"
    # shellcheck source=/dev/null
    source "$REPO_ROOT/scripts/11a-llm-registry.sh"
    # shellcheck source=/dev/null
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
    # shellcheck source=/dev/null
    source "$REPO_ROOT/scripts/01-constants.sh"
    # shellcheck source=/dev/null
    source "$REPO_ROOT/scripts/11d-llm-gpu.sh"

    # PIN the foreign-owner probe to "no because I own it", so this case asks a question
    # about the CODE.  It reads the live GPU lock, and with a lock held on the box the
    # stand-down correctly refuses for that reason first and never reaches the test-env
    # branch — measured 2026-11-27, the case then failed on a box whose only difference was
    # a live lock.  The lock path has its own cases in 12-gpu-exclusivity.bats; pinning here
    # is the same rule as pinning a keep-list in a census case.
    __llm_gpu_foreign_owner() { return 1; }

    AUTOTUNE_SELFTEST=0 TAC_TEST_TMPDIR="$SANDBOX" run __llm_kill_cuda_llama_servers
    [ "$status" -eq 0 ]
    [[ "$output" == *"test environment"* ]]

    AUTOTUNE_SELFTEST=0 TAC_TEST_TMPDIR="$SANDBOX" run __llm_stand_down_cuda_lanes
    [ "$status" -eq 0 ]
    [[ "$output" == *"test environment"* ]]
}

@test "batch: consecutive loader_vintage failures do not trip CONSECUTIVE_FAILURES halt" {
    local root="$SANDBOX/tree_lv"
    _setup_batch_sandbox "$root" "$SANDBOX/missing.conf"
    cat > "$root/scripts/autotune-model.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    lv1.gguf|lv2.gguf)
        printf 'classification=loader_vintage\n' > "$LLM_AUTOTUNE_RESULT_FILE"
        exit 1 ;;
    ok.gguf)
        echo "OK:$1"
        exit 0 ;;
    sys1.gguf|sys2.gguf)
        printf 'classification=unclassified\n' > "$LLM_AUTOTUNE_RESULT_FILE"
        exit 1 ;;
esac
EOF
    chmod +x "$root/scripts/autotune-model.sh"
    printf '0\n' > "$SANDBOX/cycles_lv"

    # Two consecutive loader_vintage rows must NOT halt; row 3 (ok.gguf) must run and batch exits 1 for FAILED_ROWS.
    run env PATH="$SANDBOX:$PATH" HEAVY_JOB_HELD=1 \
        CUDA_CYCLE_FILE="$SANDBOX/cycles_lv" CUDA_CYCLE_BUDGET=60 \
        LLM_REGISTRY="$SANDBOX/missing.conf" \
        TAC_HOST_PRIMARY_LANE="llama-cuda-test.service" \
        bash "$root/scripts/run-autotune-batch.sh" lv1.gguf lv2.gguf ok.gguf
    [ "$status" -eq 1 ]
    [[ "$output" == *"per-model, continuing"* ]]
    [[ "$output" == *"OK:ok.gguf"* ]]
    [[ "$output" == *"finished: 1/3 tuned, 2 failed"* ]]
    [[ "$output" != *"HALTED:"* ]]
    [[ "$output" == *"FAILED"* ]] && [[ "$output" == *"lv1.gguf"* ]] && [[ "$output" == *"lv2.gguf"* ]]

    # Two consecutive systemic failures still halt as designed.
    run env PATH="$SANDBOX:$PATH" HEAVY_JOB_HELD=1 \
        CUDA_CYCLE_FILE="$SANDBOX/cycles_lv" CUDA_CYCLE_BUDGET=60 \
        LLM_REGISTRY="$SANDBOX/missing.conf" \
        TAC_HOST_PRIMARY_LANE="llama-cuda-test.service" \
        bash "$root/scripts/run-autotune-batch.sh" sys1.gguf sys2.gguf ok.gguf
    [ "$status" -eq 1 ]
    [[ "$output" == *"2 consecutive row failures"* ]]
    [[ "$output" != *"OK:ok.gguf"* ]]
}

@test "autotune: unknown quant prefix refreshes via __quant_label and spread logs samples" {
    # shellcheck source=/dev/null
    source "$REPO_ROOT/scripts/01-constants.sh"
    # shellcheck source=/dev/null
    source "$REPO_ROOT/scripts/11d-llm-gpu.sh"

    local _qc="unknown/q8_0/q8_0" _gguf_ftype="39" MODEL_FILE="flint-nvfp4.gguf"
    local WIN_KVK="q8_0" WIN_KVV="q8_0" KV_QUANT_SAVE="" _quant_prefix="${_qc%%/*}"
    if [[ -z "$_quant_prefix" || "$_quant_prefix" == "unknown" ]] && declare -f __quant_label >/dev/null 2>&1; then
        local _q_derived
        _q_derived=$(__quant_label "${_gguf_ftype:-}" "$MODEL_FILE")
        [[ -n "$_q_derived" && "$_q_derived" != "unknown" ]] && _quant_prefix="$_q_derived"
    fi
    [[ -n "$_quant_prefix" ]] && KV_QUANT_SAVE="${_quant_prefix}/${WIN_KVK}/${WIN_KVV}"
    [ "$KV_QUANT_SAVE" = "NVFP4/q8_0/q8_0" ]

    grep -q '/tmp/at-spread-vals-\$\$' "$REPO_ROOT/scripts/autotune-model.sh"
    grep -q 'echo "    samples:' "$REPO_ROOT/scripts/autotune-model.sh"
}

@test "autotune: winning spec-decode promotes BEST_TPS and applies WIN_SPEC across post probes" {
    local fn="$SANDBOX/spec_helpers.sh"
    {
        sed -n '/^_apply_win_spec()/,/^}/p' "$REPO_ROOT/scripts/autotune-model.sh"
        sed -n '/^_clear_bench_spec()/,/^}/p' "$REPO_ROOT/scripts/autotune-model.sh"
    } > "$fn"
    # shellcheck source=/dev/null
    source "$fn"

    WIN_SPEC_TYPE="draft-mtp"
    WIN_SPEC_N_MAX="4"
    WIN_SPEC_DRAFT_PATH="/models/mtp.gguf"
    WIN_SPEC_NGL="999"
    _apply_win_spec
    [ "$BENCH_SPEC_TYPE" = "draft-mtp" ]
    [ "$BENCH_SPEC_N_MAX" = "4" ]
    [ "$BENCH_SPEC_DRAFT_MODEL" = "/models/mtp.gguf" ]
    [ "$BENCH_SPEC_NGL" = "999" ]

    _clear_bench_spec
    [ "$BENCH_SPEC_TYPE" = "off" ]
    [ -z "$BENCH_SPEC_N_MAX" ]
    [ -z "$BENCH_SPEC_DRAFT_MODEL" ]
    [ -z "$BENCH_SPEC_NGL" ]

    local src
    src=$(< "$REPO_ROOT/scripts/autotune-model.sh")
    [[ "$src" == *'BEST_TPS="$_sb_best_tps"'* ]]
    [[ "$src" == *'if [[ "${P2_CTX:-0}" == "${BEST_CTX:-0}" ]]; then'* ]]
    [[ "$src" == *'P2_TPS="$BEST_TPS"'* ]]
    [[ "$src" == *$'_apply_win_spec\n            for _th_cand'* ]]
    [[ "$src" == *$'_apply_win_spec\n        _meas_pos2='* ]]
}
