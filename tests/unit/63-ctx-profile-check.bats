#!/usr/bin/env bats
# ==============================================================================
# Unit — scripts/check-ctx-profile.sh: observed-input-profile verdicts and the
# exit-code contract.
# ==============================================================================
# WHY THIS EXISTS (CTXBUDGET-003).  The checker exists so an empty observed
# profile cannot read as a pass: at HEAD every registry row has cols 35-37 empty,
# so "nothing measured" is the common case.  The contract these cases pin:
#
#   all rows profile-missing -> exit 2 (unless --allow-unmeasured)
#   any  row profile-under   -> exit 1
#   any  row profile-over    -> exit 0, or exit 1 with --fail-over
#   a row that fits          -> exit 0
#
# The expected values come from the RULING (keep MAX-ctx certification; flag the
# relationship) and from the 1024-token rounding stated in the helper, not from
# the script's current output.  FALSIFICATION: an implementation that exits 0 on
# an all-missing registry fails case 1; one that ignores --fail-over fails the
# second half of case 4.
#
# HERMETIC: a temp registry is passed with --registry; no GPU, no live registry.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export REPO_ROOT
    # The registry header is the schema, so build fixtures from the same source.
    source "$REPO_ROOT/scripts/01-constants.sh"
    CHECK="$REPO_ROOT/scripts/check-ctx-profile.sh"
    REG="$BATS_TEST_TMPDIR/models.conf"
    unset LLM_CTX_OUTPUT_RESERVE
}

# _write_registry <avg_prompt_tokens> <ctx>
# One row with the real 45-column schema; only cols 8 and 37 carry test data.
_write_registry() {
    local avg="$1" ctx="$2"
    local -a f=()
    local i
    f[0]='1'; f[1]='Model One'; f[2]='model-one.gguf'; f[3]='1.0G'
    f[4]='Q4_K_M/q8_0'; f[5]='qwen2'; f[6]='24'; f[7]="$ctx"
    f[8]='6'; f[9]='1024'; f[10]='256'; f[11]='1'; f[12]='1024'
    f[13]='llama_server'; f[14]='auto'; f[15]='on'; f[16]='0'
    f[17]='no'; f[18]='no'; f[19]='no'
    for (( i = 20; i <= 44; i++ )); do f[i]=''; done
    f[36]="$avg"
    {
        printf '%s\n' "$LLM_REGISTRY_HEADER"
        local IFS='|'
        printf '%s\n' "${f[*]}"
    } > "$REG"
}

@test "ctx-profile: an all-missing registry exits 2, never 0" {
    _write_registry "" 8192
    run "$CHECK" --registry "$REG"
    [ "$status" -eq 2 ]
    [[ "$output" == *"profile-missing"* ]]
    [[ "$output" == *"avg=missing"* ]]
    [[ "$output" == *"0 fits, 0 over, 0 under, 1 profile-missing"* ]]
}

@test "ctx-profile: a legacy 44-column header still gets a verdict, not a refusal" {
    {
        printf '%s\n' "${LLM_REGISTRY_HEADER%|ctx_policy}"
        printf '%s\n' "1|Model One|model-one.gguf|1.0G|Q4_K_M/q8_0|qwen2|24|8192|6|1024|256|1|1024|llama_server|auto|on|0|no|no|no"
    } > "$REG"
    run "$CHECK" --registry "$REG"
    [ "$status" -eq 2 ]
    [[ "$output" == *"profile-missing"* ]]
}

@test "ctx-profile: --allow-unmeasured makes an all-missing registry exit 0" {
    _write_registry "" 8192
    run "$CHECK" --registry "$REG" --allow-unmeasured
    [ "$status" -eq 0 ]
    [[ "$output" == *"profile-missing"* ]]
}

@test "ctx-profile: a fitting window exits 0" {
    _write_registry 1000 5120
    run "$CHECK" --registry "$REG"
    [ "$status" -eq 0 ]
    [[ "$output" == *"profile-fits:5120"* ]]
}

@test "ctx-profile: an under-reserved window exits 1" {
    _write_registry 1000 4096
    run "$CHECK" --registry "$REG"
    [ "$status" -eq 1 ]
    [[ "$output" == *"profile-under:5120"* ]]
}

@test "ctx-profile: an over-reserved window exits 0, and 1 with --fail-over" {
    _write_registry 1000 8192
    run "$CHECK" --registry "$REG"
    [ "$status" -eq 0 ]
    [[ "$output" == *"profile-over:5120"* ]]
    run "$CHECK" --registry "$REG" --fail-over
    [ "$status" -eq 1 ]
}

@test "ctx-profile: --reserve changes the recommended window" {
    _write_registry 1000 2048
    run "$CHECK" --registry "$REG" --reserve 1024
    [ "$status" -eq 0 ]
    [[ "$output" == *"profile-fits:2048"* ]]
}

@test "ctx-profile: an unreadable registry is a named non-zero failure" {
    run "$CHECK" --registry "$BATS_TEST_TMPDIR/absent.conf"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not readable"* ]]
}
