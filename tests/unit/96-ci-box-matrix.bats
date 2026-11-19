#!/usr/bin/env bats
# ==============================================================================
# Unit — the per-box CI matrix is DERIVED, not a hand-written literal
# ==============================================================================
# Criterion: the per-box jobs (`behavioral`, `python-unit`) must name only boxes
# whose runner can actually take the job.  A literal `[ARM64, X64]` cannot notice
# that one box's runner is gone, and an absent runner does not fail an arm — it
# QUEUES it, so the whole run never concludes and the gate says nothing.
#
# Measured 2026-11-19: `wsl-console-1` (X64, on the XPS 15) offline and its host
# unreachable over SSH while `wsl-console-arm64` served every push.  Run
# 44512057230 sat `queued` on `Behavioral BATS (X64)` indefinitely.
#
# The fix derives the matrix from `config/hosts.d/*.conf` — the same files
# tools/host-profile.sh resolves a box from — so adding or retiring a box is a
# config edit and the matrix cannot drift from the profiles the jobs run on.
#
# These cases pin the CONFIG READ and the WORKFLOW WIRING, because the failure
# they exist for was a workflow that never asked the question:
#   - the deriver must read config, not a literal
#   - a retired box must drop out (one line, no workflow edit)
#   - an empty/ambiguous config must REFUSE, not emit [] (an empty matrix is a run
#     with no per-box jobs, which is the same silent green as a queued arm)
#   - both per-box jobs must consume the derived output and depend on it
# ==============================================================================

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
    WORK="$BATS_TEST_TMPDIR/work"
    mkdir -p "$WORK/tools" "$WORK/config/hosts.d" "$WORK/.github/workflows"
    cp "$REPO_ROOT/tools/ci-boxes.sh" "$WORK/tools/ci-boxes.sh"
    chmod +x "$WORK/tools/ci-boxes.sh"
}

# profile ID ARCH [BOX] [ENABLED] — write a minimal host profile into the sandbox.
profile() {
    local id="$1" arch="$2" box="${3:-}" enabled="${4:-}"
    {
        printf 'TAC_HOST_PROFILE_ID="%s"\n' "$id"
        printf 'TAC_HOST_PROFILE_ARCH="%s"\n' "$arch"
        if [ -n "$box" ]; then printf 'TAC_HOST_CI_BOX="%s"\n' "$box"; fi
        if [ -n "$enabled" ]; then printf 'TAC_HOST_CI_BOX_ENABLED=%s\n' "$enabled"; fi
    } > "$WORK/config/hosts.d/$id.conf"
    return 0
}

@test "ci-boxes reads the declared CI box from each profile" {
    profile arm-box aarch64 ARM64
    profile x64-box x86_64 X64
    run "$WORK/tools/ci-boxes.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "ARM64 X64" ]
}

@test "ci-boxes derives the box from the declared arch when TAC_HOST_CI_BOX is absent" {
    profile arm-box aarch64
    profile x64-box x86_64
    run "$WORK/tools/ci-boxes.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "ARM64 X64" ]
}

@test "a retired box drops out of the matrix on one config line" {
    profile arm-box aarch64 ARM64
    profile x64-box x86_64 X64 0
    run --separate-stderr "$WORK/tools/ci-boxes.sh" --json
    [ "$status" -eq 0 ]
    [ "$output" = '["ARM64"]' ]
}

@test "ci-boxes refuses an empty matrix instead of emitting []" {
    profile arm-box aarch64 ARM64 0
    run --separate-stderr "$WORK/tools/ci-boxes.sh" --json
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    [[ "$stderr" == *"refusing to emit an empty matrix"* ]]
}

@test "ci-boxes refuses a profile that names neither a box nor a known arch" {
    profile odd-box riscv64
    run --separate-stderr "$WORK/tools/ci-boxes.sh"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"refusing to name a box"* ]]
}

@test "ci-boxes refuses when config/hosts.d has no profiles at all" {
    run --separate-stderr "$WORK/tools/ci-boxes.sh"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"no profiles"* ]]
}

@test "ci-boxes de-duplicates two profiles naming the same box" {
    profile arm-a aarch64 ARM64
    profile arm-b aarch64 ARM64
    run "$WORK/tools/ci-boxes.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "ARM64" ]
}

@test "ci-boxes parses the conf and never executes it" {
    # A profile that would break a sourcing reader: `exit 7` and a syntax-adjacent
    # line.  A parser is unaffected; a `source` would end the deriver early and
    # leave the matrix half-built.
    printf 'TAC_HOST_PROFILE_ID="arm-box"\nTAC_HOST_PROFILE_ARCH="aarch64"\nTAC_HOST_CI_BOX="ARM64"\nexit 7\n' \
        > "$WORK/config/hosts.d/arm-box.conf"
    run "$WORK/tools/ci-boxes.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "ARM64" ]
}

@test "the repo's own literary matrix is gone: both per-box jobs consume the derived output" {
    local ci="$REPO_ROOT/.github/workflows/ci.yml"
    # The producer exists and publishes `boxes`.
    grep -q '^  boxes:$' "$ci"
    grep -q 'boxes: ${{ steps.derive.outputs.boxes }}' "$ci"
    grep -q 'tools/ci-boxes.sh --json' "$ci"
    # Both consumers take the matrix from it and depend on it.
    [ "$(grep -c 'box: ${{ fromJSON(needs.boxes.outputs.boxes) }}' "$ci")" -eq 2 ]
    [ "$(grep -c '^    needs: boxes$' "$ci")" -eq 2 ]
    # The literal must not come back.
    run grep -n 'box: \[ARM64, X64\]' "$ci"
    [ "$status" -ne 0 ]
}

@test "the repo's own profiles derive a non-empty matrix" {
    run bash -c "'$REPO_ROOT/tools/ci-boxes.sh' --check"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "this box's arm is in the derived matrix while its runner serves CI" {
    # The ARM64 profile must stay enabled: it is the one box that serves.  This is
    # the case that would have caught retiring the wrong profile.
    run bash -c "'$REPO_ROOT/tools/ci-boxes.sh'"
    [[ "$output" == *ARM64* ]]
}
