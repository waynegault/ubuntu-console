#!/usr/bin/env bats
# ==============================================================================
# Unit Tests — a test runner is not a GPU tenant
# ==============================================================================
# THE REGRESSION (2026-11-01 19:22:01 and again 19:27:08):
#
#   [watchdog] GPU busy — stopping llama-cuda-qwen3coder-30b-chat (freeing VRAM;
#              Xe lane serves) [probe: foreign-app pid=1453778 python
#              exe=/opt/python/cpython-3.12.16-linux-aarch64-gnu/bin/python3.12]
#
# pid 1453778 was a VS Code pytest run in another workspace. Importing torch opens
# /dev/dxg, so WSL's nvidia-smi lists the process as a CUDA compute app with
# `used_gpu_memory [N/A]` — no device memory at all. The probe read that as "a
# stranger holds the card" and the watchdog stopped our lane while it was SERVING
# (slot task 11693, an 81k-token prompt in flight). The second stop was the proof
# that it repeats: same pid, same reason, six minutes later.
#
# Two halves are pinned here, because either alone leaves the lane dead:
#   1. foreign_apps_busy() must not name such a resident foreign;
#   2. sanctioned_residents_only() must ignore it too, or utilisation still counts —
#      a serving server pins util far past the threshold, so the heuristic would
#      condemn the lane for its own work, the 2026-10-23 regression again.
#
# And the exemption is pinned SCOPED: an unsanctioned resident that is not a test
# runner still reports foreign, so the fail-closed direction survives.
#
# NOTE: these tests never execute bin/gpu-busy.sh's main body. They extract the
# function definitions verbatim and drive them with a stubbed nvidia-smi, so no
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
    PYTEST_PID=""
    CONTROL_PID=""

    mkdir -p "$TAC_TEST_TMPDIR/bin"
    cat > "$TAC_TEST_TMPDIR/bin/nvidia-smi" <<'EOS'
#!/usr/bin/env bash
case "$*" in
    *--query-compute-apps=pid*)  printf '%s\n' "${STUB_PIDS:-}" ;;
    *--query-gpu=utilization.gpu*) printf '%s\n' "${STUB_UTIL:-0}" ;;
    *--query-gpu=memory.used*)   printf '%s\n' "${STUB_VRAM:-0}" ;;
    *) exit 0 ;;
esac
EOS
    chmod +x "$TAC_TEST_TMPDIR/bin/nvidia-smi"
    cat > "$TAC_TEST_TMPDIR/bin/pgrep" <<'EOS'
#!/usr/bin/env bash
# No process matches in this sandbox, whatever the pattern: the declared-workload
# signal reads the LIVE process table otherwise.
exit 1
EOS
    chmod +x "$TAC_TEST_TMPDIR/bin/pgrep"
    # The lane-metrics probe is a live HTTP read of :18087 (sanctioned_lane_serving).
    # Pin it: a real lane serving on the box while the suite runs would otherwise flip
    # these cases, and the default answers "no metric" so fail-closed is what is tested.
    cat > "$TAC_TEST_TMPDIR/bin/curl" <<'EOS'
#!/usr/bin/env bash
[ -n "${STUB_METRICS:-}" ] || exit 7
printf '%s\n' "$STUB_METRICS"
EOS
    chmod +x "$TAC_TEST_TMPDIR/bin/curl"
    export LLAMA_CUDA_LANE_PORT=18087
    unset STUB_METRICS
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
}

teardown() {
    [ -n "${PYTEST_PID:-}" ] && kill "$PYTEST_PID" 2>/dev/null
    [ -n "${CONTROL_PID:-}" ] && kill "$CONTROL_PID" 2>/dev/null
    rm -rf "$TAC_TEST_TMPDIR"
}

# A live resident shaped exactly like the incident: an interpreter (unsanctioned exe)
# whose command line names a test-runner script.
start_test_runner() {
    printf 'import time\ntime.sleep(60)\n' > "$TAC_TEST_TMPDIR/run_pytest_script.py"
    python3 "$TAC_TEST_TMPDIR/run_pytest_script.py" &
    PYTEST_PID=$!
    for _ in $(seq 1 20); do
        [ -e "/proc/$PYTEST_PID/exe" ] && break
        sleep 0.1
    done
}

start_sanctioned_server() {
    sleep 60 &
    CONTROL_PID=$!
    for _ in $(seq 1 20); do
        [ -e "/proc/$CONTROL_PID/exe" ] && break
        sleep 0.1
    done
}

run_probe() {
    bash "$TAC_TEST_TMPDIR/probe.sh"
}

@test "a test-runner resident does not condemn a sanctioned serving lane (the 19:22 regression)" {
    start_sanctioned_server
    start_test_runner
    export LLAMA_CUDA_SERVER_BIN="$(readlink -f /bin/sleep)"
    export STUB_PIDS="$CONTROL_PID
$PYTEST_PID"
    export STUB_UTIL=95

    run run_probe
    [ "$status" -eq 0 ]
    # Free, and the audit line names the suppression rather than staying silent.
    [[ "$output" == free\ reasons=*"util-suppressed:95%"* ]]
    [[ "$output" != *"busy"* ]]
}

@test "the test-runner exemption is scoped: a plain unsanctioned resident still reads foreign" {
    start_sanctioned_server
    start_test_runner
    export LLAMA_CUDA_SERVER_BIN="$(readlink -f /usr/bin/true)"
    export STUB_PIDS="$CONTROL_PID
$PYTEST_PID"
    export STUB_UTIL=0

    run run_probe
    [ "$status" -eq 0 ]
    [[ "$output" == *"foreign-app pid=$CONTROL_PID"* ]]
    # the test runner is not named as a reason of its own
    [[ "$output" != *"foreign-app pid=$PYTEST_PID"* ]]
}
