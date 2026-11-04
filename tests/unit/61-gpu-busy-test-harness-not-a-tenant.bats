#!/usr/bin/env bats
# ==============================================================================
# Unit Tests — a test harness is not a GPU tenant
# ==============================================================================
# THE REGRESSION (2026-11-04, twice in seven minutes):
#
#   [watchdog] GPU busy - stopping llama-cuda-qwen3coder-30b-chat (freeing VRAM;
#              Xe lane serves) [probe: declared:autotune]
#
# 14:02:56Z was a local bats loop; 14:09:53Z was a VS Code bats run whose ancestry
# was bats-exec-suite <- timeout 400 bats <- the qwen-code companion extension.
# Both were running tests/unit/08-autotune-workload.bats, which executes the REPO's
# own scripts/autotune-model.sh at its real path. The probe answered correctly: a
# real autotune script WAS executing. So the fleet's default CUDA lane was stopped
# to serve a unit test.
#
# This pins the predicate that separates them: a declared workload descended from a
# test harness is SUPPRESSED, and the suppression is printed, because a silent
# suppression is indistinguishable from a probe that found nothing.
#
# The control arm matters as much as the test: the same script with an ordinary
# parent must still report declared:autotune, or the rule would blind the probe to
# every real campaign.
#
# NOTE: these tests never execute bin/gpu-busy.sh's main body. They extract the
# function definitions verbatim and drive them with stubbed nvidia-smi/pgrep, so no
# real GPU state, lane or server is touched.
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
SRC="$REPO_ROOT/bin/gpu-busy.sh"

setup() {
    TAC_TEST_TMPDIR="$(mktemp -d)"
    export TAC_TEST_TMPDIR
    export LLM_BENCH_LOCK_FILE="$TAC_TEST_TMPDIR/bench.lock"
    export INVESTIGATOR_GPU_LOCK="$TAC_TEST_TMPDIR/nonexistent-gpu.lock"
    unset INVESTIGATOR_PRODUCTION_OUTPUT
    unset LLAMA_XE_SERVER_BIN
    HARNESS_PID=""
    DETACHED_PID=""
    mkdir -p "$TAC_TEST_TMPDIR/bin"
    cat > "$TAC_TEST_TMPDIR/bin/nvidia-smi" <<'EOS'
#!/usr/bin/env bash
case "$*" in
    *--query-compute-apps=pid*)  exit 0 ;;
    *--query-gpu=utilization.gpu*) printf '0\n' ;;
    *--query-gpu=memory.used*)   printf '0\n' ;;
    *) exit 0 ;;
esac
EOS
    chmod +x "$TAC_TEST_TMPDIR/bin/nvidia-smi"
    # pgrep hands the probe exactly the pid this test started: the live process table
    # must not decide the answer, or a real campaign running beside the suite flips it.
    cat > "$TAC_TEST_TMPDIR/bin/pgrep" <<'EOS'
#!/usr/bin/env bash
[ "$1" = "-x" ] && exit 1
[ -n "${STUB_PIDS:-}" ] || exit 1
printf '%s\n' "${STUB_PIDS}"
exit 0
EOS
    chmod +x "$TAC_TEST_TMPDIR/bin/pgrep"
    cat > "$TAC_TEST_TMPDIR/bin/curl" <<'EOS'
#!/usr/bin/env bash
exit 7
EOS
    chmod +x "$TAC_TEST_TMPDIR/bin/curl"
    export LLAMA_CUDA_LANE_PORT=18087
    export PATH="$TAC_TEST_TMPDIR/bin:$PATH"

    cp "$REPO_ROOT/bin/_tac-bin-lib.sh" "$TAC_TEST_TMPDIR/_tac-bin-lib.sh"
    local last
    last=$(grep -n '^if busy; then$' "$SRC" | tail -1 | cut -d: -f1)
    [ -n "$last" ] || { echo "could not locate the main block in $SRC" >&2; return 1; }
    head -n "$((last - 2))" "$SRC" > "$TAC_TEST_TMPDIR/probe.sh"
    cat >> "$TAC_TEST_TMPDIR/probe.sh" <<'EOS'
REASONS=()
if busy; then
    printf 'busy reasons=%s\n' "${REASONS[*]}"
else
    printf 'free reasons=%s\n' "${REASONS[*]:-none}"
fi
EOS
    printf '#!/usr/bin/env bash\nsleep 60\n' > "$TAC_TEST_TMPDIR/autotune-model.sh"
    chmod +x "$TAC_TEST_TMPDIR/autotune-model.sh"
}

teardown() {
    [ -n "${DETACHED_PID:-}" ] && kill "$DETACHED_PID" 2>/dev/null
    [ -n "${HARNESS_PID:-}" ] && kill -- -${HARNESS_PID} 2>/dev/null
    [ -n "${HARNESS_PID:-}" ] && kill "$HARNESS_PID" 2>/dev/null
    rm -rf "$TAC_TEST_TMPDIR"
}

# start_autotune <parent-argv0|-> : run the fake autotune-model.sh under a named
# parent, so ps ancestry is real rather than mocked.
start_autotune() {
    local parent="$1"
    if [ "$parent" = "-" ]; then
        # The control must NOT descend from bats, or the rule matches it too and the
        # arm proves nothing. Double-fork: the launcher exits at once, the script
        # reparents to init, and its ancestry is no longer this test. It therefore
        # outlives bats, so teardown kills it by pid.
        setsid bash -c "bash '$TAC_TEST_TMPDIR/autotune-model.sh' >/dev/null 2>&1 & echo \$! > '$TAC_TEST_TMPDIR/detached.pid'" </dev/null >/dev/null 2>&1
        sleep 0.3
        DETACHED_PID=$(cat "$TAC_TEST_TMPDIR/detached.pid" 2>/dev/null || true)
        HARNESS_PID=""
    else
        setsid bash -c "exec -a $parent bash -c 'exec bash $TAC_TEST_TMPDIR/autotune-model.sh'" &
        HARNESS_PID=$!
    fi
    for _ in $(seq 1 40); do
        # The stub pgrep is first on PATH, so ask the real one here.
        if [ "$parent" = "-" ]; then
            STUB_PIDS="$DETACHED_PID"
        else
            STUB_PIDS=$(/usr/bin/pgrep -f "$TAC_TEST_TMPDIR/autotune-model.sh" 2>/dev/null | head -1)
        fi
        export STUB_PIDS
        [ -n "$STUB_PIDS" ] && [ -e "/proc/$STUB_PIDS/cmdline" ] && return 0
        sleep 0.1
    done
    echo "the fake autotune process never started" >&2
    return 1
}

@test "a declared autotune started by a bats harness is suppressed, not a tenant" {
    start_autotune "bats-exec-suite"
    run bash "$TAC_TEST_TMPDIR/probe.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"free"* ]]
    [[ "$output" == *"suppressed:test-harness"* ]]
    [[ "$output" != *"declared:autotune"* ]]
}

@test "the same script with an ordinary parent is still a declared workload" {
    start_autotune "-"
    run bash "$TAC_TEST_TMPDIR/probe.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"busy"* ]]
    [[ "$output" == *"declared:autotune"* ]]
}
