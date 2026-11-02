#!/usr/bin/env bats
# ==============================================================================
# Unit Tests — the sanctioned-binary list must name the tree that EXISTS
# ==============================================================================
# THE REGRESSION (2026-11-02 12:55Z), found only because another fix exposed it:
#
#   probe: foreign-app pid=1592447 llama-server
#          exe=/home/wayne/llama.cpp/build-cuda/bin/llama-server
#
# The reporting lane was serving a 96%-utilisation prefill on :18087. That is OUR
# server, at OUR path, holding the card for OUR request — and gpu-busy called it
# foreign and answered BUSY. The watchdog acts on BUSY, so the probe would have
# stopped the lane for the crime of being itself.
#
# THE CAUSE IS A COPY THAT DRIFTED, NOT A WRONG IDEA. _sanctioned_exes() defaults
# to $HOME/llama.cpp/build/bin/llama-server while this box builds and serves from
# build-cuda/. scripts/01-constants.sh resolved exactly this on 2026-11-01 ("build/
# held nothing while build-cuda/ served the card") by naming the tree that exists.
# gpu-busy.sh is standalone by design — its own comment says the constants "are
# repeated here rather than imported" — so it kept the pre-correction answer. A
# standalone copy of a decision is a copy that can go stale, and this one had.
#
# WHY IT WAS INVISIBLE FOR ELEVEN HOURS: while the native libname resolved the
# wrong libcuda, nvidia-smi failed first and the probe answered BUSY with a
# truthful "nvidia-smi-unavailable". The false-foreign verdict only became
# reachable once the probe could see the card again. A fix that restores sight can
# reveal a second fault underneath it; that is an argument for the fix, not against.
#
# These tests never start a server or touch the real card: they extract the real
# definitions and drive them against a synthetic $HOME tree.
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
SRC="$REPO_ROOT/bin/gpu-busy.sh"

setup() {
    TAC_TEST_TMPDIR="$(mktemp -d)"
    export TAC_TEST_TMPDIR
    # Extract the real definitions, stopping before the main block, so the assertions
    # run the shipped code rather than a paraphrase of it.
    local last
    last=$(grep -n '^if busy; then$' "$SRC" | tail -1 | cut -d: -f1)
    [ -n "$last" ] || { echo "could not locate the main block in $SRC" >&2; return 1; }
    head -n "$((last - 2))" "$SRC" > "$TAC_TEST_TMPDIR/probe.sh"
    cp "$REPO_ROOT/bin/_tac-bin-lib.sh" "$TAC_TEST_TMPDIR/_tac-bin-lib.sh"
}

teardown() {
    rm -rf "$TAC_TEST_TMPDIR"
}

# Build a fake llama tree under the sandbox HOME. Only the trees named are created,
# so "which tree exists" is the variable under test.
make_tree() {
    local kind="$1"    # cuda | legacy | both | none
    FAKE_HOME="$TAC_TEST_TMPDIR/home"
    mkdir -p "$FAKE_HOME"
    case "$kind" in
        cuda)   mkdir -p "$FAKE_HOME/llama.cpp/build-cuda/bin"
                printf '#!/bin/sh\n' > "$FAKE_HOME/llama.cpp/build-cuda/bin/llama-server"
                chmod +x "$FAKE_HOME/llama.cpp/build-cuda/bin/llama-server" ;;
        legacy) mkdir -p "$FAKE_HOME/llama.cpp/build/bin"
                printf '#!/bin/sh\n' > "$FAKE_HOME/llama.cpp/build/bin/llama-server"
                chmod +x "$FAKE_HOME/llama.cpp/build/bin/llama-server" ;;
        both)   mkdir -p "$FAKE_HOME/llama.cpp/build-cuda/bin" "$FAKE_HOME/llama.cpp/build/bin"
                printf '#!/bin/sh\n' > "$FAKE_HOME/llama.cpp/build-cuda/bin/llama-server"
                printf '#!/bin/sh\n' > "$FAKE_HOME/llama.cpp/build/bin/llama-server"
                chmod +x "$FAKE_HOME/llama.cpp/build-cuda/bin/llama-server" \
                         "$FAKE_HOME/llama.cpp/build/bin/llama-server" ;;
        none)   : ;;
    esac
    export FAKE_HOME
}

# Echo what _sanctioned_exes resolves, with HOME pointed at the fake tree and the
# two override variables out of the picture (they take precedence by design).
resolved_exes() {
    env -u LLAMA_CUDA_SERVER_BIN -u LLAMA_XE_SERVER_BIN HOME="$FAKE_HOME" \
        bash -c 'source "$1"; _sanctioned_exes' _ "$TAC_TEST_TMPDIR/probe.sh"
}

@test "build-cuda is named when it is the tree that exists (the live case)" {
    make_tree cuda
    run resolved_exes
    [ "$status" -eq 0 ]
    [ "$output" = "$FAKE_HOME/llama.cpp/build-cuda/bin/llama-server" ]
}

@test "the legacy build tree is still honoured when build-cuda is absent" {
    make_tree legacy
    run resolved_exes
    [ "$status" -eq 0 ]
    [ "$output" = "$FAKE_HOME/llama.cpp/build/bin/llama-server" ]
}

@test "build-cuda wins when both trees exist" {
    make_tree both
    run resolved_exes
    [ "$status" -eq 0 ]
    [ "$output" = "$FAKE_HOME/llama.cpp/build-cuda/bin/llama-server" ]
}

@test "an explicit LLAMA_CUDA_SERVER_BIN still overrides the tree probe" {
    make_tree cuda
    explicit="$TAC_TEST_TMPDIR/explicit-llama-server"
    printf '#!/bin/sh\n' > "$explicit"; chmod +x "$explicit"
    run env LLAMA_CUDA_SERVER_BIN="$explicit" HOME="$FAKE_HOME" \
        bash -c 'source "$1"; _sanctioned_exes' _ "$TAC_TEST_TMPDIR/probe.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "$explicit" ]
}

# The falsification that matters: a list naming ONLY the legacy tree cannot sanction
# a resident at the build-cuda path. That is the exact shape of the eleven-hour gap —
# the pre-fix default named build/bin, the lane ran build-cuda, and the probe answered
# foreign. Without this arm the tests above are equally consistent with the old code
# having worked, which is the null-result trap in its usual costume.
@test "a legacy-only sanction list cannot cover a build-cuda resident (the defect)" {
    make_tree legacy
    run env -u LLAMA_CUDA_SERVER_BIN -u LLAMA_XE_SERVER_BIN HOME="$FAKE_HOME" \
        bash -c 'source "$1"; _is_sanctioned_exe "$2"' _ "$TAC_TEST_TMPDIR/probe.sh" \
        "$FAKE_HOME/llama.cpp/build-cuda/bin/llama-server"
    # The exe does not exist in this tree and the list names only build/bin: the
    # shipped code must NOT sanction it, which is why the live lane read foreign.
    [ "$status" -ne 0 ]
}

@test "the same resident IS sanctioned once the list names its tree" {
    make_tree cuda
    run env -u LLAMA_CUDA_SERVER_BIN -u LLAMA_XE_SERVER_BIN HOME="$FAKE_HOME" \
        bash -c 'source "$1"; _is_sanctioned_exe "$2"' _ "$TAC_TEST_TMPDIR/probe.sh" \
        "$FAKE_HOME/llama.cpp/build-cuda/bin/llama-server"
    [ "$status" -eq 0 ]
}

# --- the libcuda resolution half -------------------------------------------------
# A probe that resolves the wrong libcuda reports "GPU unavailable" about a card that
# is serving. Pinned here because the verdict it produced (nvidia-smi-unavailable) is
# indistinguishable from a genuinely dead driver, which is what invited a restart.
@test "the probe prepends the WSL driver dir when that libcuda exists" {
    [ -e /usr/lib/wsl/lib/libcuda.so.1 ] || skip "no WSL driver dir on this host"
    run env -u LD_LIBRARY_PATH bash -c 'source "$1"; printf "%s" "${LD_LIBRARY_PATH%%:*}"' _ \
        "$TAC_TEST_TMPDIR/probe.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "/usr/lib/wsl/lib" ]
}

@test "a caller's own LD_LIBRARY_PATH is kept, not replaced" {
    [ -e /usr/lib/wsl/lib/libcuda.so.1 ] || skip "no WSL driver dir on this host"
    run env LD_LIBRARY_PATH="/opt/mine" bash -c 'source "$1"; printf "%s" "$LD_LIBRARY_PATH"' _ \
        "$TAC_TEST_TMPDIR/probe.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "/usr/lib/wsl/lib:/opt/mine" ]
}

@test "libcuda_shadowed names a native libcuda that precedes the WSL one" {
    run bash -c 'source "$1"; libcuda_shadowed' _ "$TAC_TEST_TMPDIR/probe.sh"
    [ "$status" -eq 0 ]
    # Either the host is clean (empty) or a native package is shadowing (an absolute path).
    case "$output" in
        "") ;;                                   # nothing shadows the WSL dir
        /usr/lib/*/libcuda.so.1) ;;               # a native package, reported by path
        *) false ;;
    esac
}

# ==============================================================================
# THE DRIFT GUARD (2026-11-02, Rook's proposed durable repair)
# ==============================================================================
# gpu-busy.sh is standalone by design — it CARRIES A COPY of the tree decision that
# scripts/01-constants.sh owns, rather than importing it. Measured on 2026-11-02, that
# copy kept the pre-correction answer for eleven hours and nothing could notice: no
# owner, no shared source, no test comparing them. A lane was nearly stopped for the
# crime of being itself, and the log line said `foreign-app`, which is a thing a reader
# stops investigating.
#
# The tests above pin the COPY's behaviour. They are all equally green if the copy and
# the original disagree, because they never look at the original. These two do: they
# source the real scripts/01-constants.sh and require it to name the same binary. A future
# change to the constants that gpu-busy does not follow now fails a suite instead of
# killing a serving lane.
constants_exe() {
    env -u LLAMA_CUDA_SERVER_BIN -u LLAMA_XE_SERVER_BIN HOME="$FAKE_HOME" \
        bash -c 'source "$1" >/dev/null 2>&1; printf %s "$LLAMA_SERVER_BIN"' \
        _ "$REPO_ROOT/scripts/01-constants.sh"
}

@test "the standalone copy agrees with 01-constants.sh on the CUDA tree" {
    make_tree cuda
    run resolved_exes
    [ "$status" -eq 0 ]
    probe_exe="$output"
    run constants_exe
    [ "$status" -eq 0 ]
    if [ "$output" != "$probe_exe" ]; then
        echo "gpu-busy.sh resolves:      $probe_exe" >&2
        echo "01-constants.sh names:     $output" >&2
        echo "gpu-busy.sh carries a COPY of this decision and it has drifted." >&2
        echo "Fix the copy, or make gpu-busy.sh import the constants." >&2
        false
    fi
}

@test "the standalone copy agrees with 01-constants.sh on the legacy tree" {
    make_tree legacy
    run resolved_exes
    [ "$status" -eq 0 ]
    probe_exe="$output"
    run constants_exe
    [ "$status" -eq 0 ]
    [ "$output" = "$probe_exe" ]
}
