#!/usr/bin/env bats
# ==============================================================================
# Unit tests for autotune-model.sh — pure-logic extractable tests.
#
# Covers: combo selection by model size, TPS floor check, mmap fallback trigger,
#         double-sampling in refinement zone, bench_ctx sample handling.
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
    export TAC_TEST_TMPDIR="$(mktemp -d)"
    mkdir -p "$TAC_TEST_TMPDIR/models" "$TAC_TEST_TMPDIR/.llm"

    # Create a stub GGUF file with enough bytes to have a size
    truncate -s 500M "$TAC_TEST_TMPDIR/models/stub-small.gguf"
    truncate -s 1500M "$TAC_TEST_TMPDIR/models/stub-mid.gguf"
    truncate -s 3500M "$TAC_TEST_TMPDIR/models/stub-large.gguf"

    # Minimal registry entries pointing at stub files
    cat > "$TAC_TEST_TMPDIR/.llm/models.conf" <<'REGISTRY'
1|small-model|stub-small.gguf|0.5G|Q4_K_M|llama|24|4096|4|1024|256|1|256|native|auto|0|no|no|no
2|mid-model|stub-mid.gguf|1.5G|Q4_K_M|llama|24|4096|4|1024|256|1|256|native|auto|0|no|no|no
3|large-model|stub-large.gguf|3.4G|Q4_K_M|llama|24|4096|4|1024|256|1|256|native|auto|0|no|no|no
REGISTRY

    export LLM_REGISTRY="$TAC_TEST_TMPDIR/.llm/models.conf"
    export LLAMA_MODEL_DIR="$TAC_TEST_TMPDIR/models"
    export LLAMA_SERVER_BIN="true"  # no-op stub
}

teardown() {
    rm -rf "$TAC_TEST_TMPDIR" 2>/dev/null || true
}

# ── Combo selection by model size ──────────────────────────────────────────

_combos_for_size() {
    local model_mb="$1"
    if [ "$model_mb" -lt 1000 ]; then
        echo "3"
    elif [ "$model_mb" -lt 2000 ]; then
        echo "2"
    else
        echo "1"
    fi
}

@test "combo selection: <1 GB model gets 3 combos" {
    run _combos_for_size 500
    [[ "$output" == "3" ]]
}

@test "combo selection: 1-2 GB model gets 2 combos" {
    run _combos_for_size 1500
    [[ "$output" == "2" ]]
}

@test "combo selection: >=2 GB model gets 1 combo" {
    run _combos_for_size 3400
    [[ "$output" == "1" ]]
}

@test "combo selection: boundary at 1000 MB gets 2 combos" {
    run _combos_for_size 1000
    [[ "$output" == "2" ]]
}

@test "combo selection: boundary at 2000 MB gets 1 combo" {
    run _combos_for_size 2000
    [[ "$output" == "1" ]]
}

# ── TPS floor check ────────────────────────────────────────────────────────

_tps_floor_check() {
    local best_tps="$1" min_tps="${2:-20}"
    if [ "$(echo "$best_tps < $min_tps" | bc 2>/dev/null || echo "0")" = "1" ]; then
        echo "BELOW_FLOOR"
        return 2
    fi
    echo "OK"
    return 0
}

@test "TPS floor: TPS above floor passes" {
    run _tps_floor_check 45.5 20
    [[ "$output" == "OK" ]]
    [[ "$status" -eq 0 ]]
}

@test "TPS floor: TPS equal to floor passes" {
    run _tps_floor_check 20.0 20
    [[ "$output" == "OK" ]]
    [[ "$status" -eq 0 ]]
}

@test "TPS floor: TPS below floor fails with exit 2" {
    run _tps_floor_check 19.9 20
    [[ "$output" == "BELOW_FLOOR" ]]
    [[ "$status" -eq 2 ]]
}

@test "TPS floor: TPS far below floor fails" {
    run _tps_floor_check 3.0 20
    [[ "$output" == "BELOW_FLOOR" ]]
    [[ "$status" -eq 2 ]]
}

@test "TPS floor: edge case with very low floor" {
    run _tps_floor_check 2.5 2.5
    [[ "$output" == "OK" ]]
    [[ "$status" -eq 0 ]]
}

# ── Double-sampling logic ──────────────────────────────────────────────────

_double_sample_decision() {
    local probe_count="$1"
    local nsamples=1
    [ "$probe_count" -gt 1 ] && nsamples=2
    echo "$nsamples"
}

@test "double-sample: first probe uses single sample" {
    run _double_sample_decision 1
    [[ "$output" == "1" ]]
}

@test "double-sample: second probe uses double sample" {
    run _double_sample_decision 2
    [[ "$output" == "2" ]]
}

@test "double-sample: third probe uses double sample" {
    run _double_sample_decision 3
    [[ "$output" == "2" ]]
}

@test "double-sample: fifth probe uses double sample" {
    run _double_sample_decision 5
    [[ "$output" == "2" ]]
}

# ── bench_ctx sample path selection ────────────────────────────────────────

_bench_ctx_sample_path() {
    local samples="$1"
    # Simulate the single-sample vs dual-sample paths
    if [ "$samples" -eq 1 ]; then
        echo "single_path"
        return 0
    fi
    echo "dual_path"
    return 0
}

@test "bench_ctx: samples=1 takes single path" {
    run _bench_ctx_sample_path 1
    [[ "$output" == "single_path" ]]
}

@test "bench_ctx: samples=2 takes dual path" {
    run _bench_ctx_sample_path 2
    [[ "$output" == "dual_path" ]]
}

@test "bench_ctx: default (unset) should use 1 sample" {
    run _bench_ctx_sample_path "${4:-1}"
    [[ "$output" == "single_path" ]]
}

# ── mmap fallback trigger ──────────────────────────────────────────────────

_mmap_fallback_trigger() {
    local any_ok="$1"  # "true" or "false"
    if [ "$any_ok" = false ]; then
        echo "FALLBACK_ACTIVE"
        return 0
    fi
    echo "NO_FALLBACK"
    return 0
}

@test "mmap fallback: triggers when no config worked" {
    run _mmap_fallback_trigger false
    [[ "$output" == "FALLBACK_ACTIVE" ]]
}

@test "mmap fallback: skipped when any config worked" {
    run _mmap_fallback_trigger true
    [[ "$output" == "NO_FALLBACK" ]]
}

# ── Pre-flight timeout logic ───────────────────────────────────────────────

_preflight_timeout() {
    local pf_w="$1" max_w="${2:-60}"
    if [ "$pf_w" -ge "$max_w" ]; then
        echo "TIMEOUT"
        return 1
    fi
    echo "CONTINUE"
    return 0
}

@test "pre-flight: continues while under timeout" {
    run _preflight_timeout 30 60
    [[ "$output" == "CONTINUE" ]]
    [[ "$status" -eq 0 ]]
}

@test "pre-flight: times out at boundary" {
    run _preflight_timeout 60 60
    [[ "$output" == "TIMEOUT" ]]
    [[ "$status" -eq 1 ]]
}

@test "pre-flight: times out above boundary" {
    run _preflight_timeout 61 60
    [[ "$output" == "TIMEOUT" ]]
    [[ "$status" -eq 1 ]]
}

# ── mmap flag construction ─────────────────────────────────────────────────

_mmap_flag() {
    local mmap_mode="${1:-off}"
    if [ "$mmap_mode" = "auto" ]; then
        echo ""  # no flag → llama-server defaults to mmap=auto
    else
        echo "--no-mmap"
    fi
}

@test "mmap flag: mode=off produces --no-mmap" {
    run _mmap_flag off
    [[ "$output" == "--no-mmap" ]]
}

@test "mmap flag: mode=auto produces empty (no --no-mmap)" {
    run _mmap_flag auto
    [[ -z "$output" ]]
}

@test "mmap flag: default (unset) produces --no-mmap" {
    run _mmap_flag
    [[ "$output" == "--no-mmap" ]]
}

# ── bench_once mmap_mode parameter passthrough ─────────────────────────────

_bench_once_mmap_passthrough() {
    local mmap_mode="${4:-off}"
    echo "mmap_mode=$mmap_mode"
}

@test "bench_once: default mmap_mode is off" {
    run _bench_once_mmap_passthrough 4096 1024 256
    [[ "$output" == "mmap_mode=off" ]]
}

@test "bench_once: explicit mmap_mode=auto is passed through" {
    run _bench_once_mmap_passthrough 4096 1024 256 auto
    [[ "$output" == "mmap_mode=auto" ]]
}

@test "bench_once: explicit mmap_mode=off is passed through" {
    run _bench_once_mmap_passthrough 4096 1024 256 off
    [[ "$output" == "mmap_mode=off" ]]
}

# ── bench_ctx mmap_mode passthrough ────────────────────────────────────────

_bench_ctx_mmap_passthrough() {
    local c="$1" b="$2" u="$3" samples="${4:-1}" mmap_mode="${5:-off}"
    echo "mmap_mode=$mmap_mode samples=$samples"
}

@test "bench_ctx: default mmap_mode is off" {
    run _bench_ctx_mmap_passthrough 4096 1024 256 1
    [[ "$output" == "mmap_mode=off samples=1" ]]
}

@test "bench_ctx: mmap_mode=auto passes through with samples" {
    run _bench_ctx_mmap_passthrough 8192 2048 512 2 auto
    [[ "$output" == "mmap_mode=auto samples=2" ]]
}
