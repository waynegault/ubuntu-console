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
    # 01-constants sources this box's host profile, which exports an ABSOLUTE
    # LLAMA_BUILD_DIR/LLAMA_CUDA_ARCH.  The fixture must drive those instead, or every
    # case targets the real serving tree (measured: build-cuda/ was configured into a case
    # whose LLAMA_ROOT was a temp dir; llm-build now refuses that mismatch outright).
    unset LLAMA_BUILD_DIR LLAMA_CUDA_ARCH
    # The quiet gate (v85) counts Runner.Worker processes.  These cases run ON a CI runner or
    # beside one, so without this every build case would refuse for a reason it is not testing;
    # the two CI cases below unset/set it explicitly.
    export LLAMA_BUILD_ALLOW_CI=1
    LLAMA_ROOT="$(mktemp -d)"
    mkdir -p "$LLAMA_ROOT/build/bin"
    # A STALE binary: this is what the pre-fix path reports as "built".
    printf '#!/usr/bin/env bash\nexit 0\n' > "$LLAMA_ROOT/build/bin/llama-server"
    chmod +x "$LLAMA_ROOT/build/bin/llama-server"
    export LLAMA_ROOT
    # llm-build now runs every cmake step under bin/heavy-job, which EXECs the command:
    # a shell function would not be inherited by that child, so cmake is a script on PATH.
    # It records its arguments (CMAKE_LOG) and whether the heavy-job lock was held at that
    # moment (CMAKE_LOCK_LOG) - "stays quiet" is the property, not "started".
    MOCK_BIN_DIR="$BATS_TEST_TMPDIR/mockbin"
    mkdir -p "$MOCK_BIN_DIR"
    cat > "$MOCK_BIN_DIR/cmake" <<'CMAKE_STUB'
#!/usr/bin/env bash
[[ -z "${CMAKE_LOG:-}" ]] || printf '%s\n' "$*" >> "$CMAKE_LOG"
if [[ -n "${CMAKE_LOCK_LOG:-}" && -n "${HEAVY_JOB_LOCK:-}" ]]; then
    if flock -n "$HEAVY_JOB_LOCK" -c true 2>/dev/null; then
        echo "no-lock" >> "$CMAKE_LOCK_LOG"
    else
        echo "locked" >> "$CMAKE_LOCK_LOG"
    fi
fi
case "${1:-}" in
    -B) exit "${STUB_CONFIGURE_RC:-0}" ;;
    --build) exit "${STUB_BUILD_RC:-0}" ;;
    *) exit 0 ;;
esac
CMAKE_STUB
    chmod +x "$MOCK_BIN_DIR/cmake"
    export PATH="$MOCK_BIN_DIR:$PATH"
    # Exported, because the cmake stub is a child process now (it used to be a shell
    # function).  A case may reassign it; an exported name stays exported.
    export CMAKE_LOG="$BATS_TEST_TMPDIR/cmake.log"
    # The box's real lock is /tmp/heavy-job.lock; these cases must never touch it, so the
    # suite points heavy-job at its own file and starts from "not already inside a job".
    export HEAVY_JOB_LOCK="$BATS_TEST_TMPDIR/heavy-job.lock"
    : > "$HEAVY_JOB_LOCK"
    unset HEAVY_JOB_HELD
}

teardown() {
    rm -rf "$LLAMA_ROOT"
}

# _run_build — run llm-build and print "<rc>\n<combined output>".  The command
# substitution confines llm-build's own `cd "$LLAMA_ROOT"` to a subshell so the
# test's cwd is untouched; `|| rc=$?` keeps it errexit-safe.
_run_build() {
    local out rc=0
    out="$(llm-build "$@" 2>&1)" || rc=$?
    printf '%s\n%s\n' "$rc" "$out"
}

@test "llm-build: a failed CONFIGURE is named and fails, not reported as done (card 50ab5c38)" {
    # Catches: the configure pipeline reading tail's 0, so a failed cmake is
    # invisible and the stale binary is reported as a fresh build.
    export STUB_CONFIGURE_RC=1
    local result rc out
    result="$(_run_build --no-pull --yes)"
    rc="${result%%$'\n'*}"
    out="${result#*$'\n'}"
    [ "$rc" -ne 0 ]
    [[ "$out" == *"CMake configuration failed"* ]]
    [[ "$out" != *"Done"* ]]
}

@test "llm-build: a failed BUILD is named and fails, not reported as done (card 50ab5c38)" {
    # Catches: `local rc=$?` reading tail's 0 after `cmake --build ... | tail -5`,
    # so a failed build returns success over the stale binary.
    export STUB_CONFIGURE_RC=0
    export STUB_BUILD_RC=1
    local result rc out
    result="$(_run_build --no-pull --yes)"
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
    export STUB_CONFIGURE_RC=0
    export STUB_BUILD_RC=0
    local result rc out
    result="$(_run_build --no-pull --yes)"
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
    result="$(_run_build --no-pull --yes)"
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
    result="$(_run_build --no-pull --yes)"
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
    result="$(_run_build --no-pull --yes)"
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
    result="$(_run_build --no-pull --yes)"
    rc="${result%%$'\n'*}"
    out="${result#*$'\n'}"
    [ "$rc" -ne 0 ]
    [[ "$out" == *"LLAMA_CUDA_ARCH"* ]]
    [[ "$out" != *"Done"* ]]
    [ ! -s "$CMAKE_LOG" ]
}

# ---- v84 (2026-11-05): the quiet gate --------------------------------------
# A rebuild saturates the box and rewrites the tree both lanes execute from, so it
# may only run into a QUIET box and must HOLD the lock while it does.  bin/heavy-job
# is the box's one lock; `--status` exits 0 whether free or BUSY, which is why these
# cases drive the lock itself rather than trusting a status code.

@test "llm-build: refuses to build into a BUSY box, before the pull (v84)" {
    # Catches: a build starting behind a bench/autotune/pytest that holds the lock - the
    # two then fight for every core, and (worse) the pull moves the source under a live
    # lane while the build waits.  --no-pull is deliberately NOT passed here, so a build
    # that got past the gate would print "Fetching latest upstream"; refusal must come first.
    git -C "$LLAMA_ROOT" init -q
    git -C "$LLAMA_ROOT" -c user.email=t@example.com -c user.name=t \
        commit -q --allow-empty -m fixture
    CMAKE_LOG="$BATS_TEST_TMPDIR/cmake.log"
    : > "$CMAKE_LOG"
    # Hold the lock in THIS shell: a background holder leaks its `sleep` child, which
    # inherits the locked descriptor and keeps the lock into the next case (measured - it
    # made the v84 lock case pass against the v83 module).
    exec 9>"$HEAVY_JOB_LOCK"
    flock -x 9
    # Control: the lock really is held, and a fresh open disagrees.  Written as a positive
    # test because errexit is suppressed for `! cmd`, so `! flock ...` as a bare assertion
    # can never fail this case.
    local still_free=0
    flock -n "$HEAVY_JOB_LOCK" -c true 2>/dev/null || still_free=1
    [ "$still_free" -eq 1 ]

    local result rc=0 out=""
    # 9>&- keeps the descriptor out of the child, so the gate sees a BUSY lock the way a
    # real second lane would, not an inherited one.
    out="$( llm-build --yes 9>&- 2>&1 )" || rc=$?
    exec 9>&-

    [ "$rc" -ne 0 ]
    [[ "$out" == *"not quiet"* ]]
    [[ "$out" != *"Fetching latest upstream"* ]]
    [ ! -s "$CMAKE_LOG" ]
}

@test "llm-build: the plan names the tree the lane serves (v84)" {
    # Catches: the old check on the retired ~/.local/bin/cuda-llama-server symlink, which
    # printed "nothing live serves this tree" while both units ran build-cuda/ - the row an
    # operator reads immediately before a rebuild that replaces the serving binary.
    export HOME="$BATS_TEST_TMPDIR/planhome"
    mkdir -p "$HOME"
    export LLAMA_CUDA_SERVER_BIN="$LLAMA_ROOT/build/bin/llama-server"
    export LLAMA_CUDA_LANE_UNIT="llama-test-lane.service"

    local result out
    result="$(_run_build --no-pull --yes)"
    out="${result#*$'\n'}"
    [[ "$out" == *"serves THIS tree"* ]]
    [[ "$out" == *"llama-test-lane.service"* ]]
    [[ "$out" != *"nothing live serves this tree"* ]]
}

@test "llm-build: refuses a build tree outside the checkout (v84)" {
    # Catches: a build landing where the pull never went - the host profile exports an
    # absolute LLAMA_BUILD_DIR, so overriding LLAMA_ROOT alone used to configure (and
    # report Done for) a tree the checkout does not contain.  Measured 2026-11-05.
    export LLAMA_BUILD_DIR="$BATS_TEST_TMPDIR/elsewhere"
    CMAKE_LOG="$BATS_TEST_TMPDIR/cmake.log"
    : > "$CMAKE_LOG"

    local result rc out
    result="$(_run_build --no-pull --yes)"
    rc="${result%%$'\n'*}"
    out="${result#*$'\n'}"
    [ "$rc" -ne 0 ]
    [[ "$out" == *"outside the checkout"* ]]
    [ ! -s "$CMAKE_LOG" ]
}

@test "llm-build: holds the heavy-job lock while cmake runs (v84)" {
    # Criterion (v84): "stays quiet".  Catches: a gate that checks the lock and then
    # releases it, leaving the compile unprotected - a bench would start mid-build.
    CMAKE_LOG="$BATS_TEST_TMPDIR/cmake.log"
    CMAKE_LOCK_LOG="$BATS_TEST_TMPDIR/cmake-lock.log"
    : > "$CMAKE_LOG"
    : > "$CMAKE_LOCK_LOG"
    export CMAKE_LOG CMAKE_LOCK_LOG
    # Precondition: nothing else holds the lock, so "locked" below can only be this build.
    flock -n "$HEAVY_JOB_LOCK" -c true

    local result rc out
    result="$(_run_build --no-pull --yes)"
    rc="${result%%$'\n'*}"
    out="${result#*$'\n'}"
    [ "$rc" -eq 0 ]
    [[ "$out" == *"Done"* ]]
    # EVERY cmake step recorded the lock held: one record per invocation.  The equality,
    # not a literal, so a step added to the flow cannot run unrecorded - the old "2"
    # (configure + build) went stale the moment the companion-tool builds joined the pass,
    # and it failed a correct build.
    [ -s "$CMAKE_LOG" ]
    [ "$(grep -c . "$CMAKE_LOCK_LOG")" -eq "$(grep -c . "$CMAKE_LOG")" ]
    # the two steps that must exist at all, so the equality above cannot be satisfied by a
    # shorter flow (and an unconfigured/unbuilt run cannot pass as quiet)
    grep -qF -- "-B $LLAMA_ROOT/build" "$CMAKE_LOG"
    grep -qF -- "--target llama-server" "$CMAKE_LOG"
    # every recorded step saw the lock held (`! grep` would never fail here: errexit is
    # suppressed for negated commands)
    [ "$(grep -c 'no-lock' "$CMAKE_LOCK_LOG")" -eq 0 ]
    # and heavy-job released it on exit rather than leaking the box's lock
    flock -n "$HEAVY_JOB_LOCK" -c true
}

# ---- v85 (2026-11-05): the quiet gate sees CI ---------------------------------
# A workflow job never takes bin/heavy-job (the workflow calls bats directly), so the
# lock alone reported "free" while a 77-file suite was running.  These cases stand in a
# process whose argv reads Runner.Worker and check both directions of the new gate.

@test "llm-build: refuses when a CI runner job is active (v85)" {
    # Catches: the gate clearing a rebuild into a running CI suite - measured 2026-11-05,
    # when only the heavy-job lock was consulted and it read free.
    unset LLAMA_BUILD_ALLOW_CI
    CMAKE_LOG="$BATS_TEST_TMPDIR/cmake.log"
    : > "$CMAKE_LOG"
    # argv[0] is what pgrep -f reads, so this stands in for a real Runner.Worker
    bash -c 'exec -a Runner.Worker sleep 10' &
    local stand_in=$!
    sleep 0.4

    local result rc out
    result="$(_run_build --no-pull --yes)"
    rc="${result%%$'\n'*}"
    out="${result#*$'\n'}"
    kill "$stand_in" 2>/dev/null || true
    wait "$stand_in" 2>/dev/null || true

    [ "$rc" -ne 0 ]
    [[ "$out" == *"CI runner worker"* ]]
    [[ "$out" != *"Done"* ]]
    [ ! -s "$CMAKE_LOG" ]
}

@test "llm-build: LLAMA_BUILD_ALLOW_CI=1 builds through an active CI job (v85)" {
    # The control that keeps the case above honest: the override must actually override,
    # or "refuses on CI" could be refusing for any reason at all.
    export LLAMA_BUILD_ALLOW_CI=1
    CMAKE_LOG="$BATS_TEST_TMPDIR/cmake.log"
    : > "$CMAKE_LOG"
    bash -c 'exec -a Runner.Worker sleep 10' &
    local stand_in=$!
    sleep 0.4

    local result rc out
    result="$(_run_build --no-pull --yes)"
    rc="${result%%$'\n'*}"
    out="${result#*$'\n'}"
    kill "$stand_in" 2>/dev/null || true
    wait "$stand_in" 2>/dev/null || true

    [ "$rc" -eq 0 ]
    [[ "$out" == *"Done"* ]]
    [ -s "$CMAKE_LOG" ]
}
