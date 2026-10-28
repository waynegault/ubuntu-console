#!/usr/bin/env bats
# ==============================================================================
# Unit — architecture portability: x86_64 and aarch64 hosts
# ==============================================================================
# Criterion (the user's requirement, 2026-10-28): this repo must work on an
# Intel x64 box AND on an arm64 box.  That means every pinned download resolves
# the asset built for the HOST, an unsupported architecture is refused with its
# own name, and the two spellings upstream uses (linux.x86_64 / linux.aarch64,
# linux_x64 / linux_arm64) are mapped from ONE host reading.
#
# `uname` is stubbed through PATH — the same seam the suite uses for curl — so
# each case states which machine it is describing and no test needs the other
# architecture's hardware.
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
    MOCK_BIN="$BATS_TEST_TMPDIR/mocks"
    mkdir -p "$MOCK_BIN"
    export PATH="$MOCK_BIN:$PATH"
}

# stub_uname MACHINE — make `uname -m` answer MACHINE for this case.
stub_uname() {
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s"\n' "$1" > "$MOCK_BIN/uname"
    chmod +x "$MOCK_BIN/uname"
}

@test "tac_host_arch maps every spelling of x86_64 to one name" {
    local machine
    for machine in x86_64 amd64 x64; do
        stub_uname "$machine"
        run bash -c 'source "$1"; tac_host_arch' _ "$REPO_ROOT/tools/arch.sh"
        [ "$status" -eq 0 ]
        [ "$output" = "x86_64" ]
    done
}

@test "tac_host_arch maps every spelling of aarch64 to one name" {
    local machine
    for machine in aarch64 arm64; do
        stub_uname "$machine"
        run bash -c 'source "$1"; tac_host_arch' _ "$REPO_ROOT/tools/arch.sh"
        [ "$status" -eq 0 ]
        [ "$output" = "aarch64" ]
    done
}

@test "tac_host_arch refuses an unsupported machine by name, not by guessing" {
    # Catches: riscv64/s390x being mapped to x86_64, which installs a binary the
    # CPU cannot execute.
    stub_uname riscv64
    run bash -c 'source "$1"; tac_host_arch' _ "$REPO_ROOT/tools/arch.sh"
    [ "$status" -eq 2 ]
    [[ "$output" == *"unsupported architecture: riscv64"* ]]
}

@test "shellcheck installer resolves the x86_64 pin" {
    stub_uname x86_64
    run "$REPO_ROOT/tools/install-shellcheck.sh" --print-asset
    [ "$status" -eq 0 ]
    [[ "$output" == *"asset=shellcheck-v0.11.0.linux.x86_64.tar.xz"* ]]
    [[ "$output" == *"sha256=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198"* ]]
}

@test "shellcheck installer resolves the aarch64 pin" {
    # Criterion: upstream publishes a different tarball, with different bytes,
    # for aarch64.  Catches: the x86_64 asset (and its sha256) being installed on
    # arm64, which fails at exec time rather than at install time.
    stub_uname aarch64
    run "$REPO_ROOT/tools/install-shellcheck.sh" --print-asset
    [ "$status" -eq 0 ]
    [[ "$output" == *"asset=shellcheck-v0.11.0.linux.aarch64.tar.xz"* ]]
    [[ "$output" == *"sha256=12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588"* ]]
}

@test "gitleaks installer resolves x64 on x86_64 and arm64 on aarch64" {
    stub_uname x86_64
    run "$REPO_ROOT/tools/install-gitleaks.sh" --print-asset
    [ "$status" -eq 0 ]
    [[ "$output" == *"asset=gitleaks_8.30.1_linux_x64.tar.gz"* ]]

    stub_uname aarch64
    run "$REPO_ROOT/tools/install-gitleaks.sh" --print-asset
    [ "$status" -eq 0 ]
    [[ "$output" == *"asset=gitleaks_8.30.1_linux_arm64.tar.gz"* ]]
    [[ "$output" == *"sha256=e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080"* ]]
}

@test "an unsupported host is refused before any download" {
    stub_uname s390x
    # No curl stub exists here: if the installer reached the download it would
    # hang or fail differently.  The refusal must come from the arch resolution.
    run "$REPO_ROOT/tools/install-shellcheck.sh" --print-asset
    [ "$status" -eq 2 ]
    [[ "$output" == *"unsupported architecture: s390x"* ]]
}

@test "the Xe launcher names the architecture limit on a non-x86 host" {
    # Criterion: Intel Xe/oneAPI is x86_64-only, so an arm64 host must be told
    # that rather than shown "Xe build not executable".  HOSTTYPE is set by bash
    # at startup, so the case overrides it in a shell that SOURCES the launcher.
    run bash -c 'HOSTTYPE=aarch64; source "$1" --help' _ "$REPO_ROOT/bin/llama-xe-server"
    [ "$status" -eq 1 ]
    [[ "$output" == *"x86_64-only"* ]]
}

@test "every Xe and CUDA lane unit is conditioned on x86-64" {
    # Criterion: on an arm64 host those units have no hardware to serve.  A
    # Condition makes systemd SKIP them; without it each start burns restart
    # attempts and the failure reads as a broken build.  Catches: a new lane unit
    # added without the condition, and the condition being deleted in a rename.
    local unit count=0
    for unit in "$REPO_ROOT"/systemd/llama-xe-*.service "$REPO_ROOT"/systemd/llama-cuda-*.service
    do
        count=$((count + 1))
        grep -qx 'ConditionArchitecture=x86-64' "$unit" \
            || { echo "FAIL: $(basename "$unit") lacks ConditionArchitecture=x86-64"; return 1; }
    done
    [ "$count" -eq 5 ] || { echo "FAIL: expected 5 Xe/CUDA units, matched $count"; return 1; }
}

@test "the CPU lane unit stays architecture-neutral" {
    # Control: the filter must not swallow the one lane an arm64 host CAN serve.
    ! grep -q '^ConditionArchitecture=' "$REPO_ROOT/systemd/llama-cpu-qwen25-3b-chat.service"
}

@test "the lane table keeps all five lanes on x86_64" {
    # Control for the narrowing below: on this box the table must be unchanged,
    # because `model lanes` and the cache sampler read it.
    run bash -c 'source "$1"; printf "%s\n" "$LLAMA_LANE_SPECS"' _ "$REPO_ROOT/scripts/01-constants.sh"
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | grep -c .)" -eq 5 ]
    [[ "$output" == *"18084"* ]]
}

@test "the lane table narrows to the CPU lane on a non-x86 host" {
    # Criterion: the Xe/CUDA units are skipped there, so reporting their ports
    # would present five lanes with three permanently down.  Catches: the table
    # staying five-wide on arm64 and the sampler probing dead ports.
    run bash -c 'HOSTTYPE=aarch64; source "$1"; printf "%s\n" "$LLAMA_LANE_SPECS"' \
        _ "$REPO_ROOT/scripts/01-constants.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "llama-cpu-qwen25-3b-chat.service|18084" ]
}
