#!/usr/bin/env bats
# ==============================================================================
# Unit — the two GPU messages that lied on 2026-11-06
# ==============================================================================
# Both were measured in one `model bench` run on this box (arm64 WSL2, driver 621.12):
#
#   1. `GPU Persistence [FAILED - passwordless sudo required for nvidia-smi]` was
#      printed for a card whose persistence mode ALREADY read `Enabled`.  wake() ran
#      `sudo -n nvidia-smi -pm 1` unconditionally, so with no passwordless sudo the
#      failure was the probe's, not the driver's — the setting never needed changing.
#      The mode query costs no privilege and is now read first; only a `Disabled`
#      reading escalates, and that failure names the one command that fixes it.
#
#   2. An autotune refusal printed an EMPTY "Held by:" block while the same run's
#      census named its unlisted holder (a foreign agent's llama-server in a transient
#      unit).  The report read `nvidia-smi --query-compute-apps`, which this host leaves
#      empty even with the card full; the holder list now comes from the process table
#      (/proc/PID/exe, the same source the census uses), with nvidia-smi kept for the
#      per-process MiB when it can attribute one.
#
# Hermetic: nvidia-smi is a stub on PATH, sudo is a shell function, and the "holder" is
# a copy of /bin/sleep wearing the llama-server path the scan matches.  Nothing here
# queries, stops or kills a live lane or the live card.
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
    STUB="$BATS_TEST_TMPDIR"
    mkdir -p "$STUB/bin"

    # nvidia-smi stub: the persistence mode comes from $STUB/mode, every invocation is
    # recorded, and the card-detail query answers plausibly so wake()'s summary prints.
    cat > "$STUB/bin/nvidia-smi" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB/calls"
case "$*" in
    *--query-gpu=persistence_mode*) cat "$STUB/mode" ;;
    *--query-gpu=utilization.gpu*)  printf '0, 1024, 73728, 41\n' ;;
    *--query-compute-apps*)         : ;;   # the blindness this host really has
    *)                              : ;;
esac
EOS
    chmod +x "$STUB/bin/nvidia-smi"
    : > "$STUB/calls"
    : > "$STUB/sudo-calls"
    : > "$STUB/mode"
    export PATH="$STUB/bin:$PATH"
    export STUB

    # sudo as a FUNCTION, so the test controls "passwordless sudo" without a policy.
    # The `-n` is dropped before running, exactly as real sudo would; the invocation is
    # recorded so a denied escalation still proves what was asked for.
    sudo() {
        printf '%s\n' "$*" >> "$STUB/sudo-calls"
        shift
        case "$(cat "$STUB/sudo")" in
            ok) "$@" ;;
            *)  printf 'sudo: a password is required\n' >&2; return 1 ;;
        esac
    }

    source "$REPO_ROOT/scripts/01-constants.sh"
    source "$REPO_ROOT/scripts/03-design-tokens.sh"
    source "$REPO_ROOT/scripts/05-ui-engine.sh"
    source "$REPO_ROOT/scripts/07-telemetry.sh"
    source "$REPO_ROOT/scripts/11d-llm-gpu.sh"
    __resolve_smi() { printf '%s\n' "$STUB/bin/nvidia-smi"; }
}

teardown() {
    if [[ -n "${HOLDER_PID:-}" ]]
    then
        kill "$HOLDER_PID" 2>/dev/null || true
        wait "$HOLDER_PID" 2>/dev/null || true
    fi
}

# ── wake: no privilege is spent on a setting that is already on ─────────────
@test "wake: an Enabled card is reported without any privileged call" {
    # Catches: the unconditional `sudo -n … -pm 1` that made a healthy card report
    # "passwordless sudo required" (the 2026-11-06 bench header).
    printf 'Enabled\n' > "$STUB/mode"
    printf 'deny\n' > "$STUB/sudo"

    run wake
    [ "$status" -eq 0 ]
    [[ "$output" == *"[ENABLED]"* ]]
    [[ "$output" != *"sudo"* ]]
    # the only invocation is the mode query: -pm was never attempted
    ! grep -q -- '-pm' "$STUB/sudo-calls"
}

@test "wake: a Disabled card with no passwordless sudo names the command, not a policy" {
    # Catches: the misleading "passwordless sudo required for nvidia-smi" — which said
    # nothing about what the card needed — and a silent success on a card left Off.
    printf 'Disabled\n' > "$STUB/mode"
    printf 'deny\n' > "$STUB/sudo"

    run wake
    [ "$status" -eq 1 ]
    [[ "$output" == *"-pm 1"* ]]
    [[ "$output" != *"passwordless sudo required"* ]]
    grep -q -- '-pm 1' "$STUB/sudo-calls"
}

@test "wake: a Disabled card that root may change is enabled and reported as such" {
    # Catches: a fix that stopped escalating at all, leaving persistence permanently Off.
    printf 'Disabled\n' > "$STUB/mode"
    printf 'ok\n' > "$STUB/sudo"

    run wake
    [ "$status" -eq 0 ]
    [[ "$output" == *"[ENABLED]"* ]]
    grep -q -- '-pm 1' "$STUB/sudo-calls"
}

@test "wake: a driver with no persistence switch is not an error and not a sudo attempt" {
    # Catches: reporting a PV guest's N/A as a failure, or spending sudo on it.
    printf 'N/A\n' > "$STUB/mode"
    printf 'ok\n' > "$STUB/sudo"

    run wake
    [ "$status" -eq 0 ]
    ! grep -q -- '-pm' "$STUB/sudo-calls"
}

# ── the holder report: the process table when nvidia-smi is blind ──────────
@test "holder report: names a holder nvidia-smi cannot see" {
    # Catches: the empty "Held by:" block measured on 2026-11-06, where the census named
    # the offending unit and the report that exists to do so printed nothing.
    #
    # The stand-in must be a REAL executable at that path: /proc/PID/exe is the identity
    # the scan reads, and this box's coreutils is the uutils multicall binary, which
    # refuses a name it does not implement ("coreutils: unknown program 'llama-server'").
    # A copy of CPython needs PYTHONHOME pinned to sys.base_prefix or it dies importing
    # `encodings` from a prefix holding no stdlib (measured in 12-gpu-exclusivity).
    mkdir -p "$STUB/llama.cpp/build-cuda/bin"
    cp "$(command -v python3)" "$STUB/llama.cpp/build-cuda/bin/llama-server"
    PYTHONHOME=$("$(command -v python3)" -c 'import sys; print(sys.base_prefix)')
    export PYTHONHOME
    "$STUB/llama.cpp/build-cuda/bin/llama-server" -c 'import time; time.sleep(300)' &
    HOLDER_PID=$!
    # Prove the stand-in is running from that path BEFORE the report is judged by it.
    [[ "$(readlink -f "/proc/$HOLDER_PID/exe")" == "$STUB/llama.cpp/build-cuda/bin/llama-server" ]]

    # Run the report in a CHILD with a PATH built from scratch.  In-process, sourcing
    # 01-constants can prepend /usr/lib/wsl/lib (the REAL nvidia-smi) and the runner's
    # environment may carry exported functions — and `__llm_cuda_server_pids` trusts a
    # compute-apps list that answers, so the real card's lane won and this case failed in
    # CI on 2026-11-06 while passing here.  env -i makes the stub the only nvidia-smi.
    run env -i PATH="$STUB/bin:/usr/bin:/bin" bash -c '
        source "$1"
        [[ "$(command -v nvidia-smi)" == "$2" ]] || { echo "STUB NOT RESOLVED"; exit 3; }
        __llm_vram_holder_report
    ' _ "$REPO_ROOT/scripts/11d-llm-gpu.sh" "$STUB/bin/nvidia-smi"
    [ "$status" -eq 0 ]
    [[ "$output" == *"pid $HOLDER_PID"* ]]
    [[ "$output" == *"$STUB/llama.cpp/build-cuda/bin/llama-server"* ]]
}

@test "holder report: an unrelated resident process is not named as a holder" {
    # Catches: the other direction — a report that lists whatever is running.  Identity
    # is /proc/PID/exe (a llama.cpp build), never a name, so a sleep is not a tenant.
    sleep 300 &
    HOLDER_PID=$!

    run __llm_vram_holder_report
    [ "$status" -eq 0 ]
    [[ "$output" != *"pid $HOLDER_PID"* ]]
}
