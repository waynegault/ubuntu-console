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
    # in the pipeline subshell because shell functions are inherited there.
    cmake() {
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
