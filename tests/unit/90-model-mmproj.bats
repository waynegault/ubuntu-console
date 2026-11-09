#!/usr/bin/env bats
# ==============================================================================
# Unit - the multimodal projector in the launch argv (11e v104)
# ==============================================================================
# The failure this file exists for: a vision row launched without --mmproj is
# HEALTHY.  /health answers, text completions work, and every image request fails
# on its own - so nothing in the lane's state says the projector is missing.  The
# launch is the only place that can say it.
#
# What has to stay true:
#
#   1. A projector beside the model (mmproj*.gguf) is passed as --mmproj.  The
#      preferred names are F16 then BF16; any other mmproj*.gguf is still used.
#   2. LLAMA_MMPROJ names another file deliberately, and it wins over a sibling.
#      A named file that does not exist WARNS and launches without one; it does
#      not silently substitute the sibling.
#   3. A row whose arch (or file name) reads as vision with no projector present
#      says so before launch.  A non-vision row stays silent.
#   4. Bench mode passes none: the autotune certifies an argv without a projector,
#      and `model bench` must reproduce that argv.
#
# Hermetic: the builder is extracted VERBATIM and run against fixture directories
# under $BATS_TEST_TMPDIR; __tac_info, __spec_launch_flags and
# __llm_registry_field are stubs.
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
LAUNCHER="$REPO_ROOT/scripts/11e-llm-model.sh"

setup() {
    export SANDBOX="$BATS_TEST_TMPDIR/fixtures"
    mkdir -p "$SANDBOX"
    for _d in f16 bf16 other none
    do
        mkdir -p "$SANDBOX/$_d"
        : > "$SANDBOX/$_d/model.gguf"
    done
    : > "$SANDBOX/f16/mmproj-F16.gguf"
    : > "$SANDBOX/bf16/mmproj-BF16.gguf"
    : > "$SANDBOX/other/mmproj-ggml-model.gguf"
    : > "$SANDBOX/custom.gguf"
    mkdir -p "$SANDBOX/vlname"
    : > "$SANDBOX/vlname/Llama-3.2-11B-Vision-Instruct.gguf"
    : > "$SANDBOX/none/model.gguf"
}

teardown() {
    rm -rf "${SANDBOX:-/tmp/bats-noop}"
}

# _build <dir> <arch> [bench] [llama_mmproj] [model_name]
# Runs the shipped builder and prints its argv, one token per line.
_build() {
    local _dir="$1" _arch="$2" _bench="${3:-}" _mmproj="${4:-}" \
          _model_name="${5:-model.gguf}"
    awk '/^function __model_use_build_command\(\)/,/^}/' "$LAUNCHER" \
        > "$SANDBOX/builder.sh"
    grep -q -- '--mmproj' "$SANDBOX/builder.sh" \
        || { echo "FAIL: builder not extracted"; return 1; }

    cat > "$SANDBOX/harness.sh" <<'EOS'
set -uo pipefail
__spec_launch_flags() { :; }
__tac_info() { printf '%s\n' "$2"; }
__llm_registry_field() { :; }
source "$1"
llm_backend="native"
LLAMA_SERVER_BIN="/stub/llama-server"
model_path="$2/${6:-model.gguf}"
LLM_PORT=18099
ctx=8192
batch_size=512
ubatch_size=256
threads=4
gpu_layers=99
fit_target_mb=1024
parallel_slots=1
row_flash_attn=true
row_kv_k=q8_0
row_kv_v=q8_0
row_mmap_mode=auto
arch="$3"
free_vram_mb=3000
model_bytes=1000000
C_Warning=""
if [[ "${4:-}" == "bench" ]]; then export __BENCH_MODE=1; else unset __BENCH_MODE; fi
if [[ -n "${5:-}" ]]; then export LLAMA_MMPROJ="$5"; fi
__model_use_build_command || { echo "FAIL: builder returned non-zero"; exit 1; }
printf '%s\n' "${cmd[@]}"
EOS
    bash "$SANDBOX/harness.sh" "$SANDBOX/builder.sh" "$SANDBOX/$_dir" \
        "$_arch" "$_bench" "$_mmproj" "$_model_name"
}

# _has_flag_value <argv> <flag> <value> - true when the flag is followed by exactly
# that value.  A substring check would pass on a flag whose argument is missing.
_has_flag_value() {
    local _argv="$1" _flag="$2" _value="$3"
    printf '%s\n' "$_argv" | grep -A1 -x -- "$_flag" | grep -qxF -- "$_value"
}

# --------------------------------------------------------------- the projector
@test "mmproj: an F16 projector beside the model is passed as --mmproj" {
    run _build f16 qwen2
    [[ "$status" -eq 0 ]]
    _has_flag_value "$output" "--mmproj" "$SANDBOX/f16/mmproj-F16.gguf" \
        || { echo "the F16 projector was not passed; argv:"; printf '%s\n' "$output"; return 1; }
    [[ "$(printf '%s\n' "$output" | grep -c -x -- '--mmproj')" -eq 1 ]]
}

@test "mmproj: BF16 is preferred when it is the one present" {
    run _build bf16 qwen2
    [[ "$status" -eq 0 ]]
    _has_flag_value "$output" "--mmproj" "$SANDBOX/bf16/mmproj-BF16.gguf"
}

@test "mmproj: any other mmproj*.gguf is still used" {
    run _build other qwen2
    [[ "$status" -eq 0 ]]
    _has_flag_value "$output" "--mmproj" "$SANDBOX/other/mmproj-ggml-model.gguf"
}

@test "mmproj: LLAMA_MMPROJ wins over a sibling projector" {
    run _build f16 qwen2 "" "$SANDBOX/custom.gguf"
    [[ "$status" -eq 0 ]]
    _has_flag_value "$output" "--mmproj" "$SANDBOX/custom.gguf" \
        || { echo "the named projector was not used; argv:"; printf '%s\n' "$output"; return 1; }
    if _has_flag_value "$output" "--mmproj" "$SANDBOX/f16/mmproj-F16.gguf"
    then
        echo "the sibling projector was used instead of LLAMA_MMPROJ"
        return 1
    fi
}

@test "mmproj: a named projector that does not exist warns and launches without one" {
    run _build f16 qwen2 "" "$SANDBOX/no-such.gguf"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"does not exist"* ]] || { echo "the missing file was silent"; return 1; }
    [[ "$output" != *"--mmproj"$'\n'* ]] || { echo "a missing projector was still passed"; return 1; }
    # ...and it must NOT fall back to the sibling: the operator named a file.
    if printf '%s\n' "$output" | grep -q 'f16/mmproj-F16.gguf'
    then
        echo "a missing LLAMA_MMPROJ silently fell back to the sibling"
        return 1
    fi
}

@test "mmproj: a vision arch with no projector warns before launch" {
    run _build none qwen2vl
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"reads as a vision model"* ]] \
        || { echo "a vision arch with no projector was silent; argv:"; printf '%s\n' "$output"; return 1; }
    [[ "$output" != *"--mmproj"* ]]
}

@test "mmproj: a vision-looking file name with no projector warns before launch" {
    # The arch column comes from the GGUF, and a converted VL export can carry a
    # plain text arch; the file name is the second signal.
    run _build vlname llama "" "" "Llama-3.2-11B-Vision-Instruct.gguf"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"reads as a vision model"* ]] \
        || { echo "a VL file name with no projector was silent"; return 1; }
}

@test "mmproj: a text row with no projector stays silent" {
    run _build none qwen2
    [[ "$status" -eq 0 ]]
    [[ "$output" != *"--mmproj"* ]]
    [[ "$output" != *"vision model"* ]]
    [[ "$output" != *"does not exist"* ]]
}

@test "mmproj: bench mode passes no projector, reproducing the certified argv" {
    run _build f16 qwen2vl bench
    [[ "$status" -eq 0 ]]
    [[ "$output" != *"--mmproj"* ]] \
        || { echo "a bench argv gained --mmproj; the certified argv moved"; return 1; }
    [[ "$output" != *"reads as a vision model"* ]] \
        || { echo "bench mode warned about a projector it deliberately omits"; return 1; }
}

# end of file
