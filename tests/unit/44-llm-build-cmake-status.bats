#!/usr/bin/env bats
# ==============================================================================
# Unit — llm-build reads CMake's status, not `tail`'s (card 50ab5c38)
# ==============================================================================
# `llm-build` (scripts/11e-llm-model.sh) runs both CMake steps through
# `... 2>&1 | tail -5`.  With no pipefail set (the profile deliberately does not
# set it — scripts/04-aliases.sh's openclaw wrapper relies on that), a pipeline's
# status is its LAST command's, i.e. tail's 0.  So:
#
#   * the configure step's `|| { error; return 1; }` never fired, and
#   * the build step's `local rc=$?` read 0,
#
# and a failed cmake fell through to the "Done" report.  Worse, with a binary
# already on disk from a previous build, the function then returned SUCCESS having
# produced nothing new — a stale binary presented as a fresh build.
#
# These cases stub `cmake` and give the function a stale executable at
# $LLAMA_ROOT/build/bin/llama-server.  The fix reads `${PIPESTATUS[0]}` (the repo
# idiom, scripts/04-aliases.sh); pre-fix, both "must fail" cases below report rc 0
# and "Done" — falsified 2026-10-02 against the pre-fix module.
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

# Source the module set llm-build's output helpers come from.  Nothing here runs
# at source time (13-init, the one module with side effects, is deliberately not
# loaded).
_load_modules() {
    source "$REPO_ROOT/scripts/01-constants.sh"
    source "$REPO_ROOT/scripts/03-design-tokens.sh"
    source "$REPO_ROOT/scripts/05-ui-engine.sh"
    source "$REPO_ROOT/scripts/11e-llm-model.sh"
}

setup() {
    _load_modules
    LLAMA_ROOT="$(mktemp -d)"
    mkdir -p "$LLAMA_ROOT/build/bin"
    # A STALE binary: this is what the pre-fix path reports as "built".
    printf '#!/usr/bin/env bash\nexit 0\n' > "$LLAMA_ROOT/build/bin/llama-server"
    chmod +x "$LLAMA_ROOT/build/bin/llama-server"
    export LLAMA_ROOT
    # cmake stub: `-B` is the configure step, `--build` the build step.  A stub runs
    # in the pipeline subshell because shell functions are inherited there.  When
    # CMAKE_LOG is set, every invocation's arguments are recorded so a case can assert
    # WHICH tree and WHICH architecture reached cmake, not merely that it ran.
    cmake() {
        [[ -z "${CMAKE_LOG:-}" ]] || printf '%s\n' "$*" >> "$CMAKE_LOG"
        case "${1:-}" in
            -B) return "${STUB_CONFIGURE_RC:-0}" ;;
            --build) return "${STUB_BUILD_RC:-0}" ;;
            *) return 0 ;;
        esac
    }
}

teardown() {
    rm -rf "$LLAMA_ROOT"
}

# _run_build — run llm-build and print "<rc>\n<combined output>".  The command
# substitution confines llm-build's own `cd "$LLAMA_ROOT"` to a subshell so the
# test's cwd is untouched; `|| rc=$?` keeps it errexit-safe.
_run_build() {
    local out rc=0
    out="$(llm-build --no-pull --yes 2>&1)" || rc=$?
    printf '%s\n%s\n' "$rc" "$out"
}

@test "llm-build: a failed CONFIGURE is named and fails, not reported as done (card 50ab5c38)" {
    # Catches: the configure pipeline reading tail's 0, so a failed cmake is
    # invisible and the stale binary is reported as a fresh build.
    STUB_CONFIGURE_RC=1
    local result rc out
    result="$(_run_build)"
    rc="${result%%$'\n'*}"
    out="${result#*$'\n'}"
    [ "$rc" -ne 0 ]
    [[ "$out" == *"CMake configuration failed"* ]]
    [[ "$out" != *"Done"* ]]
}

@test "llm-build: a failed BUILD is named and fails, not reported as done (card 50ab5c38)" {
    # Catches: `local rc=$?` reading tail's 0 after `cmake --build ... | tail -5`,
    # so a failed build returns success over the stale binary.
    STUB_CONFIGURE_RC=0
    STUB_BUILD_RC=1
    local result rc out
    result="$(_run_build)"
    rc="${result%%$'\n'*}"
    out="${result#*$'\n'}"
    [ "$rc" -ne 0 ]
    [[ "$out" == *"Build failed"* ]]
    [[ "$out" != *"Done"* ]]
}

@test "llm-build: a successful configure+build still reports Done and returns 0 (control)" {
    # The control that keeps the two cases above honest: both stubs succeed, so the
    # function must reach the Done report and return 0.  A "fix" that merely returned
    # non-zero would fail here.
    STUB_CONFIGURE_RC=0
    STUB_BUILD_RC=0
    local result rc out
    result="$(_run_build)"
    rc="${result%%$'\n'*}"
    out="${result#*$'\n'}"
    [ "$rc" -eq 0 ]
    [[ "$out" == *"Done"* ]]
}

# ---- v83 (2026-11-05): the tree and the architecture ------------------------
# Both literal defaults this section guards were measured on the arm64 box, where
# each produced a rebuild that served nothing: `cmake -B build` filled a tree no
# launcher reads (the serving tree is build-cuda/), and a card the driver could not
# answer for fell back to a hard-coded sm_86 on a 12.1 GPU.

@test "llm-build: builds the tree LLAMA_BUILD_DIR names, not build/ (v83)" {
    # Catches: the fixed $LLAMA_ROOT/build.  On the arm64 box a rebuild then lands in
    # build/ while both lanes keep serving build-cuda/ - Done is reported and nothing
    # that serves has changed.
    export LLAMA_BUILD_DIR="$LLAMA_ROOT/build-cuda"
    CMAKE_LOG="$BATS_TEST_TMPDIR/cmake.log"
    : > "$CMAKE_LOG"
    mkdir -p "$LLAMA_BUILD_DIR/bin"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$LLAMA_BUILD_DIR/bin/llama-server"
    chmod +x "$LLAMA_BUILD_DIR/bin/llama-server"

    local result rc out
    result="$(_run_build)"
    rc="${result%%$'\n'*}"
    out="${result#*$'\n'}"
    [ "$rc" -eq 0 ]
    [[ "$out" == *"Done"* ]]
    grep -qF -- "-B $LLAMA_BUILD_DIR" "$CMAKE_LOG"
    grep -qF -- "--build $LLAMA_BUILD_DIR" "$CMAKE_LOG"
}

@test "llm-build: the architecture is the card's, read from the driver (v83)" {
    # Criterion (v83): -DCMAKE_CUDA_ARCHITECTURES carries the card's compute capability,
    # so one command targets sm_121 on this box and sm_86 on the x86 box.
    # Catches: any fixed default reaching a card it does not fit.
    CMAKE_LOG="$BATS_TEST_TMPDIR/cmake.log"
    : > "$CMAKE_LOG"
    mkdir -p "$BATS_TEST_TMPDIR/driver"
    printf '#!/usr/bin/env bash\nprintf "12.1\\n"\n' > "$BATS_TEST_TMPDIR/driver/nvidia-smi"
    chmod +x "$BATS_TEST_TMPDIR/driver/nvidia-smi"
    PATH="$BATS_TEST_TMPDIR/driver:$PATH"

    local result rc
    result="$(_run_build)"
    rc="${result%%$'\n'*}"
    [ "$rc" -eq 0 ]
    grep -qF -- "-DCMAKE_CUDA_ARCHITECTURES=121" "$CMAKE_LOG"
}

@test "llm-build: a card that cannot be read is answered by LLAMA_CUDA_ARCH (v83)" {
    # The host profile's declaration is the only fallback there is: an unreadable
    # driver plus a declared 121 must configure for 121.
    CMAKE_LOG="$BATS_TEST_TMPDIR/cmake.log"
    : > "$CMAKE_LOG"
    mkdir -p "$BATS_TEST_TMPDIR/nocard"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$BATS_TEST_TMPDIR/nocard/nvidia-smi"
    chmod +x "$BATS_TEST_TMPDIR/nocard/nvidia-smi"
    PATH="$BATS_TEST_TMPDIR/nocard:$PATH"
    LLAMA_CUDA_ARCH=121

    local result rc
    result="$(_run_build)"
    rc="${result%%$'\n'*}"
    [ "$rc" -eq 0 ]
    grep -qF -- "-DCMAKE_CUDA_ARCHITECTURES=121" "$CMAKE_LOG"
}

@test "llm-build: an unreadable card with no declared arch refuses instead of guessing (v83)" {
    # Catches: the old `local cuda_arch="86"`, which compiled Ampere kernels on a
    # Blackwell card and printed the guess as a stated fallback.  Nothing is configured.
    CMAKE_LOG="$BATS_TEST_TMPDIR/cmake.log"
    : > "$CMAKE_LOG"
    mkdir -p "$BATS_TEST_TMPDIR/nocard"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$BATS_TEST_TMPDIR/nocard/nvidia-smi"
    chmod +x "$BATS_TEST_TMPDIR/nocard/nvidia-smi"
    PATH="$BATS_TEST_TMPDIR/nocard:$PATH"
    unset LLAMA_CUDA_ARCH

    local result rc out
    result="$(_run_build)"
    rc="${result%%$'\n'*}"
    out="${result#*$'\n'}"
    [ "$rc" -ne 0 ]
    [[ "$out" == *"LLAMA_CUDA_ARCH"* ]]
    [[ "$out" != *"Done"* ]]
    [ ! -s "$CMAKE_LOG" ]
}
