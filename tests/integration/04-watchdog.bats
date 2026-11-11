#!/usr/bin/env bats
# ==============================================================================
# Integration Tests — Llama Watchdog (v3.12, four-lane)
# ==============================================================================
# Tests llama-watchdog.sh v3.12: health probing (including the 503 "loading"
# signal), 2-strike recovery, the always-on Xe lane, the GPU-gated CUDA lane,
# the card-free CPU tail lane, the second Xe lane (:18085), the v3.5 CUDA-only
# suspend flag, and the v3.8/v3.10/v3.11 per-lane flap counters. v3.12 adds the
# GPU-busy stop marker: a stop the watchdog made itself must not be counted as a
# flap. All external
# commands (curl, systemctl, gpu-busy.sh) are mocked so the suite is hermetic and
# never touches the live llama-xe-minicpm5-1b-chat.service.
# Run: bats tests/integration/04-watchdog.bats
# ==============================================================================

setup_file() {
    export REPO_ROOT
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export WATCHDOG_SCRIPT="$REPO_ROOT/bin/llama-watchdog.sh"
    export TAC_TEST_TMPDIR
    TAC_TEST_TMPDIR="$(mktemp -d)"
    export WATCHDOG_MOCK_BIN="$TAC_TEST_TMPDIR/mock-bin"
    export WATCHDOG_MOCK_STATE="$TAC_TEST_TMPDIR/state"
    export WATCHDOG_MOCK_HOME="$TAC_TEST_TMPDIR/home"
    export SYSTEMCTL_MOCK_LOG="$TAC_TEST_TMPDIR/systemctl.log"
    export SYSTEMCTL_MOCK_STATE="$WATCHDOG_MOCK_STATE"
    # Sandbox the watchdog's lock/strike files and the bench lock so the suite
    # never mutates live /dev/shm or /tmp state (env overrides in the script).
    export LLAMA_WATCHDOG_LOCK_FILE="$TAC_TEST_TMPDIR/llama-watchdog.lock"
    export LLAMA_WATCHDOG_STRIKE_DIR="$TAC_TEST_TMPDIR"
    export LLM_BENCH_LOCK_FILE="$TAC_TEST_TMPDIR/llm-bench.lock"
    export LLAMA_WATCHDOG_CUDA_SUSPEND_FILE="$TAC_TEST_TMPDIR/llama-watchdog-cuda.suspend"
    # v3.12: the "we stopped it for a foreign GPU owner" marker, sandboxed like
    # the rest (a live marker leaking between cases would mask real flaps).
    export LLAMA_WATCHDOG_CUDA_GPUSTOP_FILE="$TAC_TEST_TMPDIR/llama-watchdog-cuda.gpustop"
    # The lane table, injected through the watchdog's test seam so the suite stays
    # hermetic (the host profile is never resolved).  Four lanes — the Xe baseline,
    # the second Xe lane, the gated CUDA lane, and the CPU tail — exactly the set the
    # pre-profile watchdog hardcoded; the embedding lane is out of scope for this suite.
    export LLAMA_WATCHDOG_LANE_SPECS="llama-xe-minicpm5-1b-chat.service|18081
llama-xe-llama32-3b-chat.service|18085
llama-cuda-llama32-3b-chat.service|18083
llama-cpu-qwen25-3b-chat.service|18084"
    export LLAMA_WATCHDOG_CUDA_LANE_UNIT="llama-cuda-llama32-3b-chat.service"
    mkdir -p "$WATCHDOG_MOCK_BIN" "$WATCHDOG_MOCK_STATE" "$WATCHDOG_MOCK_HOME/.local/bin"

    # The heavy-job seam.  recover() DEFERS while a heavy job holds the box
    # (LLAMA-LANE-CONTENTION-001), and _tac_heavy_job_busy reads the LIVE lock unless this
    # points elsewhere.  Measured 2026-11-10: this suite takes heavy-job itself at
    # collection (conftest, for the BATS bridge), so recover() read BUSY, deferred, and all
    # eight "restarts / resets a failed unit" cases went red together with nothing wrong in
    # the watchdog.  A stub that answers FREE makes them hermetic; no case here is about the
    # deferral itself.
    cat > "$WATCHDOG_MOCK_BIN/heavy-job" <<'MOCK'
#!/usr/bin/env bash
printf 'heavy-job: free\n'
MOCK
    chmod +x "$WATCHDOG_MOCK_BIN/heavy-job"
    export HEAVY_JOB_BIN="$WATCHDOG_MOCK_BIN/heavy-job"

    # v3.0 resolves gpu-busy.sh as $HOME/.local/bin/gpu-busy.sh (GPU_BUSY_SH is
    # no longer honoured), so point HOME at the sandbox and drop the mock there.
    export HOME="$WATCHDOG_MOCK_HOME"

    # Mock curl: /health answers 503 while the "loading" marker exists (model
    # still loading), 200 once "healthy" exists, else connection failure (22).
    cat > "$WATCHDOG_MOCK_BIN/curl" <<'MOCK'
#!/usr/bin/env bash
if [[ "$*" == *"/health"* ]]
then
    if [[ -f "$SYSTEMCTL_MOCK_STATE/healthy" ]]; then
        printf '{"status":"ok"}\n200\n'
        exit 0
    fi
    if [[ -f "$SYSTEMCTL_MOCK_STATE/loading" ]]; then
        printf '{"status":"loading model"}\n503\n'
        exit 0
    fi
    exit 22
fi
if [[ "$*" == *"/v1/models"* ]]
then
    [[ -f "$SYSTEMCTL_MOCK_STATE/healthy" ]] && exit 0
    exit 22
fi
# /slots: llama.cpp's own slot accounting, read by stop_cost to say what a stop cuts.
# Three shapes, because the case that matters is the one where we CANNOT measure: a
# mock that always answered would make "0" and "unmeasured" indistinguishable.
if [[ "$*" == *"/slots"* ]]
then
    if [[ -f "$SYSTEMCTL_MOCK_STATE/slots_unreadable" ]]; then
        exit 22
    fi
    if [[ -f "$SYSTEMCTL_MOCK_STATE/slots_busy" ]]; then
        printf '[{"id":0,"is_processing":true},{"id":1,"is_processing":true},{"id":2,"is_processing":false}]\n'
        exit 0
    fi
    printf '[{"id":0,"is_processing":false},{"id":1,"is_processing":false}]\n'
    exit 0
fi
exit 22
MOCK
    chmod +x "$WATCHDOG_MOCK_BIN/curl"

    # Mock systemctl --user. `show` reports per-unit state from xe_state/cuda_state/
    # cpu_state/xe3b_state; restart/start mark the lane healthy (unless fail_restart/
    # fail_start is set); stop and reset-failed record themselves. The CPU branch MUST
    # precede the catch-all: "llama-cpu-qwen25-3b-chat" does not match *cuda*, so
    # without it the CPU lane would silently read the Xe lane's state. The Xe3B branch
    # has the same requirement and for a sharper reason: BOTH Xe lanes end in
    # "-chat".service and so would otherwise fall through to xe_state together, making
    # one lane's state answer for the other. It is matched on *qwen25-3b*, which also
    # matches the CPU unit's name — CPU is matched first above, deliberately.
    cat > "$WATCHDOG_MOCK_BIN/systemctl" <<'MOCK'
#!/usr/bin/env bash
set -uo pipefail
if [[ "${1:-}" == "--user" ]]; then shift; fi
op="${1:-}"; shift || true
case "$op" in
    show)
        unit="${1:-}"
        # v5.1: answer by the PROPERTY asked for, not by the unit alone. The watchdog
        # now probes LoadState to decide whether a lane is installed at all, and the
        # old mock returned an ActiveState string for any -p argument — so a
        # LoadState query would have read "inactive" and every lane would have looked
        # present, making the skip tests pass without exercising the skip.
        # Walk the args properly: -p takes the NEXT argument as the property name.
        # (An earlier version used a two-state flag inside one case arm, where the
        # [[ ]] test short-circuited before the assignment and only the assignment
        # to `got` ever ran, so the property was always reported as ActiveState and
        # the skip test could never see not-found.)
        prop="ActiveState"
        prev=""
        for a in "$@"; do
            if [[ "$prev" == "-p" ]]; then prop="$a"; fi
            prev="$a"
        done
        case "$unit" in
            *cuda*)        base=cuda ;;
            *cpu*)         base=cpu ;;
            *llama-xe-llama32-3b*) base=xe3b ;;
            *)             base=xe ;;
        esac
        # load_<lane> absent -> live default "loaded"; present in a test -> its value.
        case "$prop" in
            LoadState) cat "$SYSTEMCTL_MOCK_STATE/load_${base}" 2>/dev/null || echo "${LOADSTATE_DEFAULT:-loaded}" ;;
            *)         cat "$SYSTEMCTL_MOCK_STATE/${base}_state" 2>/dev/null || echo "inactive" ;;
        esac
        ;;
    restart)
        echo "restart $*" >> "$SYSTEMCTL_MOCK_LOG"
        [[ -f "$SYSTEMCTL_MOCK_STATE/fail_restart" ]] && exit 1
        touch "$SYSTEMCTL_MOCK_STATE/restart_called" "$SYSTEMCTL_MOCK_STATE/healthy"
        ;;
    start)
        echo "start $*" >> "$SYSTEMCTL_MOCK_LOG"
        [[ -f "$SYSTEMCTL_MOCK_STATE/fail_start" ]] && exit 1
        touch "$SYSTEMCTL_MOCK_STATE/start_called" "$SYSTEMCTL_MOCK_STATE/healthy"
        ;;
    stop)
        echo "stop $*" >> "$SYSTEMCTL_MOCK_LOG"
        touch "$SYSTEMCTL_MOCK_STATE/stop_called"
        rm -f "$SYSTEMCTL_MOCK_STATE/healthy"
        ;;
    reset-failed)
        echo "reset-failed $*" >> "$SYSTEMCTL_MOCK_LOG"
        touch "$SYSTEMCTL_MOCK_STATE/reset_failed_called"
        ;;
    *)
        echo "unhandled: $op $*" >> "$SYSTEMCTL_MOCK_LOG"
        ;;
esac
MOCK
    chmod +x "$WATCHDOG_MOCK_BIN/systemctl"

    # Mock gpu-busy.sh. Mirrors the real contract: exit 0 = FREE, exit 1 = BUSY
    # (with the JSON on stdout), exit 2 = a probe ERROR — the watchdog must
    # treat a BUSY answer as normal (no warning) and only fail closed on errors.
    cat > "$WATCHDOG_MOCK_HOME/.local/bin/gpu-busy.sh" <<'MOCK'
#!/usr/bin/env bash
if [[ -f "$SYSTEMCTL_MOCK_STATE/gpu-probe-error" ]]; then
    echo "mock probe exploded" >&2
    exit 2
fi
if [[ -f "$SYSTEMCTL_MOCK_STATE/busy-smi-unavailable" ]]; then
    echo '{"busy":true,"reasons":["nvidia-smi-unavailable"]}'
    exit 1
fi
if [[ -f "$SYSTEMCTL_MOCK_STATE/busy" ]]; then
    echo '{"busy":true,"reasons":["mock"]}'
    exit 1
fi
echo '{"busy":false,"reasons":[]}'
exit 0
MOCK
    chmod +x "$WATCHDOG_MOCK_HOME/.local/bin/gpu-busy.sh"
}

teardown_file() {
    rm -rf "${TAC_TEST_TMPDIR:-/tmp/bats-noop}"
}

setup() {
    # Reset mock state, mock log, the 2-strike counters, and the bench lock
    # before each test (all sandboxed under $TAC_TEST_TMPDIR).
    # A busy or unreadable card makes gpu_reprobe_free() run every attempt, each preceded
    # by `sleep $GPU_REPROBE_SLEEP_S` (default 5s, 2 attempts) — 10s of wall per case, for a
    # verdict the case asserts and not a duration. Measured 2026-11-05: 11.3s wall against
    # 0.6s of CPU. The ATTEMPT COUNT is untouched, so the re-probe path still runs twice.
    export GPU_REPROBE_SLEEP_S=0
    : > "$SYSTEMCTL_MOCK_LOG" 2>/dev/null || true
    rm -f "$WATCHDOG_MOCK_STATE"/*
    rm -f "$LLAMA_WATCHDOG_LOCK_FILE" \
          "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-xe-minicpm5-1b-chat.strikes" \
          "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-cuda.strikes" \
          "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-cpu-qwen25-3b-chat.strikes" \
          "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-xe-llama32-3b-chat.strikes" \
          "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-cuda.flaps" \
          "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-xe-minicpm5-1b-chat.flaps" \
          "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-cpu-qwen25-3b-chat.flaps" \
          "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-xe-llama32-3b-chat.flaps" \
          "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-cuda.flaphold" \
          "$LLAMA_WATCHDOG_CUDA_GPUSTOP_FILE" 2>/dev/null || true
    # Park LANE 4 in `activating` for every test that does not ask for it. The three
    # pre-existing lanes' tests were written against a two/three-lane script and assert
    # on the ABSENCE of restart/start/stop calls; a fourth lane sitting `inactive` down
    # a live port would take a second strike inside their second run and touch the
    # shared markers. `activating` is the script's own "systemd is already on it" state:
    # skipped, no strike, no action — so LANE 4 is inert until a test writes
    # `inactive`/`failed` itself. Reset it BEFORE the state wipe above, not after.
    echo "activating" > "$WATCHDOG_MOCK_STATE/xe3b_state"
    rm -f "$LLM_BENCH_LOCK_FILE" "$LLAMA_WATCHDOG_CUDA_SUSPEND_FILE" 2>/dev/null || true
    # v3.17: the requested-stop seam and its consume file are per-test, and an env var a
    # case exported survives into the NEXT case (bats runs them in one shell) — a record
    # left behind would be read by every later tick.
    unset INVESTIGATOR_REQUESTED_STOP INVESTIGATOR_GPU_LOCK
    rm -f "$TAC_TEST_TMPDIR/requested-stop" \
          "$TAC_TEST_TMPDIR/llama-watchdog.requested-stop.seen" 2>/dev/null || true
    export PATH="$WATCHDOG_MOCK_BIN:$PATH"
}

# ─────────────────────────────────────────────────────────────────────────────
# Tests
# ─────────────────────────────────────────────────────────────────────────────

@test "integration: watchdog script exists and is executable" {
    [[ -f "$WATCHDOG_SCRIPT" ]] || return 1
    [[ -x "$WATCHDOG_SCRIPT" ]] || return 1
}

@test "integration: watchdog exits cleanly when healthy" {
    touch "$WATCHDOG_MOCK_STATE/healthy"
    echo "active" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "active" > "$WATCHDOG_MOCK_STATE/cuda_state"

    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ ! -f "$WATCHDOG_MOCK_STATE/restart_called" ]]
}

@test "integration: watchdog restarts the Xe lane on the 2nd consecutive failure" {
    echo "active" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "active" > "$WATCHDOG_MOCK_STATE/cuda_state"

    # First failure: strike 1, no restart yet.
    run "$WATCHDOG_SCRIPT"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"strike 1/2"* ]]
    [[ ! -f "$WATCHDOG_MOCK_STATE/restart_called" ]]

    # Second failure: strike 2, recovery via systemctl restart.
    run "$WATCHDOG_SCRIPT"
    [[ "$status" -eq 0 ]]
    [[ -f "$WATCHDOG_MOCK_STATE/restart_called" ]]
    grep -q "restart llama-xe-minicpm5-1b-chat.service" "$SYSTEMCTL_MOCK_LOG"
    [[ "$output" == *"Recovery successful"* ]]
}

@test "integration: watchdog leaves a still-loading (503) Xe lane alone" {
    echo "active" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "active" > "$WATCHDOG_MOCK_STATE/cuda_state"
    touch "$WATCHDOG_MOCK_STATE/loading"

    run "$WATCHDOG_SCRIPT"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"llama-xe-minicpm5-1b-chat still loading (503)"* ]]
    [[ ! -f "$WATCHDOG_MOCK_STATE/restart_called" ]]

    # A second loading tick must not accrue the 2nd strike either.
    run "$WATCHDOG_SCRIPT"
    [[ "$status" -eq 0 ]]
    [[ ! -f "$WATCHDOG_MOCK_STATE/restart_called" ]]
    [[ "$(cat "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-xe-minicpm5-1b-chat.strikes" 2>/dev/null || echo 0)" == "0" ]]
}

@test "integration: watchdog leaves a still-loading (503) CUDA lane alone" {
    echo "active" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "active" > "$WATCHDOG_MOCK_STATE/cuda_state"
    touch "$WATCHDOG_MOCK_STATE/loading"

    run "$WATCHDOG_SCRIPT"
    run "$WATCHDOG_SCRIPT"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"CUDA unit still loading (503)"* ]]
    [[ ! -f "$WATCHDOG_MOCK_STATE/restart_called" ]]
    [[ "$(cat "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-cuda.strikes" 2>/dev/null || echo 0)" == "0" ]]
}

@test "integration: watchdog stops the CUDA lane while the GPU is busy" {
    echo "active" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "active" > "$WATCHDOG_MOCK_STATE/cuda_state"
    touch "$WATCHDOG_MOCK_STATE/busy"

    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"GPU busy — stopping llama-cuda-llama32-3b-chat"* ]]
    grep -q "stop llama-cuda-llama32-3b-chat.service" "$SYSTEMCTL_MOCK_LOG"
    # Card 55a6fe89 defect 1: the stop is SIGKILL, so the unit lands `failed`; a stop we
    # made must not leave it there.  Scoped to the stopped unit — the Xe lane was not
    # stopped, so it must not be reset.
    grep -q "reset-failed llama-cuda-llama32-3b-chat.service" "$SYSTEMCTL_MOCK_LOG"
    ! grep -q "reset-failed llama-xe" "$SYSTEMCTL_MOCK_LOG"
    [[ ! -f "$WATCHDOG_MOCK_STATE/restart_called" ]]
}

@test "integration: a busy GPU is not misreported as a probe failure" {
    # gpu-busy.sh signals BUSY with exit 1 (the JSON goes to stdout). That is a
    # normal answer, so the watchdog must not log its probe-failure warning —
    # otherwise a held GPU spams the journal on every tick.
    echo "active" > "$WATCHDOG_MOCK_STATE/cuda_state"
    touch "$WATCHDOG_MOCK_STATE/busy"

    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"GPU busy — stopping llama-cuda-llama32-3b-chat"* ]]
    [[ "$output" != *"probe failed"* ]]
}

@test "integration: a gpu-busy probe error fails closed and warns" {
    # exit 2 is a real probe error: the GPU cannot be proven free, so it must be
    # treated as BUSY (CUDA lane stopped) and reported once.
    echo "active" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "active" > "$WATCHDOG_MOCK_STATE/cuda_state"
    touch "$WATCHDOG_MOCK_STATE/gpu-probe-error"

    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"probe failed"* ]]
    [[ "$output" == *"GPU busy — stopping llama-cuda-llama32-3b-chat"* ]]
    grep -q "stop llama-cuda-llama32-3b-chat.service" "$SYSTEMCTL_MOCK_LOG"
}

@test "integration: a driver-level probe failure does NOT stop a lane that is serving" {
    # v24, measured 2026-11-02: nvidia-smi rc=9 reported while the card served a
    # 69,632-token prefill at 1,056 tok/s. The stop that followed left the guest
    # unable to create any new CUDA context, so this arm must refuse it.
    echo "active" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "active" > "$WATCHDOG_MOCK_STATE/cuda_state"
    touch "$WATCHDOG_MOCK_STATE/busy-smi-unavailable"
    touch "$WATCHDOG_MOCK_STATE/healthy"      # /health answers 200 -> the lane IS serving

    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"answers /health 200"* ]]
    [[ "$output" == *"the stop is refused"* ]]
    ! grep -q "stop llama-cuda-llama32-3b-chat.service" "$SYSTEMCTL_MOCK_LOG"
    [[ ! -f "$WATCHDOG_MOCK_STATE/stop_called" ]]
    # Not stopping is not the same as masking a later death: this path must not
    # leave a gpustop marker behind that would explain the NEXT death away.
    # The non-empty guard is the point: `[[ ! -f "" ]]` is TRUE, so an unset or
    # empty path would make this assertion pass without ever looking at a file.
    # (The tests at "the GPU-busy marker" below assert the same path DOES exist,
    # so the instrument is proven able to write it, not merely unable to find it.)
    [[ -n "$LLAMA_WATCHDOG_CUDA_GPUSTOP_FILE" ]]
    [[ ! -f "$LLAMA_WATCHDOG_CUDA_GPUSTOP_FILE" ]]
}

@test "integration: a driver-level probe failure DOES stop a lane that is only loading" {
    # The control arm for the case above, and the reason it is keyed on rc==0 rather
    # than on "the lane answers": a 503 is exactly what a restarted lane looks like on
    # a wedged driver. If this arm did not stop, a wedged CUDA tier would sit holding
    # VRAM while answering 503 forever.
    echo "active" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "active" > "$WATCHDOG_MOCK_STATE/cuda_state"
    touch "$WATCHDOG_MOCK_STATE/busy-smi-unavailable"
    touch "$WATCHDOG_MOCK_STATE/loading"      # /health answers 503 -> NOT serving

    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"GPU busy — stopping llama-cuda-llama32-3b-chat"* ]]
    grep -q "stop llama-cuda-llama32-3b-chat.service" "$SYSTEMCTL_MOCK_LOG"
}

@test "integration: a driver-level probe failure stops a lane whose port is dead" {
    # Third arm: neither 200 nor 503 — the port refuses. Nothing is being served, so
    # the fail-closed stop stands (this is the pre-v24 behaviour and it is correct).
    echo "active" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "active" > "$WATCHDOG_MOCK_STATE/cuda_state"
    touch "$WATCHDOG_MOCK_STATE/busy-smi-unavailable"

    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"GPU busy — stopping llama-cuda-llama32-3b-chat"* ]]
    grep -q "stop llama-cuda-llama32-3b-chat.service" "$SYSTEMCTL_MOCK_LOG"
}

@test "integration: watchdog skips the Xe lane when the bench lock is present" {
    echo "active" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "active" > "$WATCHDOG_MOCK_STATE/cuda_state"
    touch "$LLM_BENCH_LOCK_FILE"

    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"llama-xe-minicpm5-1b-chat down but bench lock present"* ]]
    [[ ! -f "$WATCHDOG_MOCK_STATE/restart_called" ]]
}

@test "integration: CUDA suspend keeps the CUDA lane down while the GPU is free" {
    # The v3.5 suspend flag is the whole point: hold the CUDA lane down on a GPU
    # the probe reports FREE, because a bench is measuring TPS and wants the card.
    echo "active" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "inactive" > "$WATCHDOG_MOCK_STATE/cuda_state"
    printf '%s\n' "$$" > "$LLAMA_WATCHDOG_CUDA_SUSPEND_FILE"   # a LIVE owner: an empty marker is NOT held since v5

    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"CUDA lane suspended"* ]]
    [[ ! -f "$WATCHDOG_MOCK_STATE/start_called" ]]
    [[ ! -f "$WATCHDOG_MOCK_STATE/restart_called" ]]
}

@test "integration: CUDA suspend stops an active CUDA lane and leaves Xe alone" {
    touch "$WATCHDOG_MOCK_STATE/healthy"
    echo "active" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "active" > "$WATCHDOG_MOCK_STATE/cuda_state"
    printf '%s\n' "$$" > "$LLAMA_WATCHDOG_CUDA_SUSPEND_FILE"   # a LIVE owner: an empty marker is NOT held since v5

    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"CUDA lane suspended — stopping llama-cuda-llama32-3b-chat"* ]]
    grep -q "stop llama-cuda-llama32-3b-chat.service" "$SYSTEMCTL_MOCK_LOG"
    grep -qv "stop llama-xe-minicpm5-1b-chat.service" "$SYSTEMCTL_MOCK_LOG"
    [[ ! -f "$WATCHDOG_MOCK_STATE/restart_called" ]]
}

@test "integration: a deliberate suspend clears the failed latch it created" {
    # Card 55a6fe89 defect 1.  KillSignal=SIGKILL means the stop completes as
    # Result=signal and systemd keeps ActiveState=failed until something resets it.
    # Measured 2026-11-04: after the 00:46:03Z suspend the lane sat failed and was the
    # box's only failed unit, so a red failed-unit gate outlived the deliberate act.
    touch "$WATCHDOG_MOCK_STATE/healthy"
    echo "active" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "active" > "$WATCHDOG_MOCK_STATE/cuda_state"
    printf '%s\n' "$$" > "$LLAMA_WATCHDOG_CUDA_SUSPEND_FILE"   # a LIVE owner

    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    grep -q "stop llama-cuda-llama32-3b-chat.service" "$SYSTEMCTL_MOCK_LOG"
    grep -q "reset-failed llama-cuda-llama32-3b-chat.service" "$SYSTEMCTL_MOCK_LOG"
    [[ "$output" == *"cleared the failed latch on llama-cuda-llama32-3b-chat"* ]]
    [[ "$output" == *"a deliberate stop is not a fault"* ]]
}

@test "integration: a suspended lane that was already down gets NO latch reset" {
    # The control: the reset belongs to the ACT.  A tick that finds the lane already
    # down performed no stop, so it set no latch — and a reset there would erase the
    # evidence of a death that happened before the suspend.
    echo "active" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "inactive" > "$WATCHDOG_MOCK_STATE/cuda_state"
    printf '%s\n' "$$" > "$LLAMA_WATCHDOG_CUDA_SUSPEND_FILE"   # a LIVE owner

    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"held by live pid"* ]]
    ! grep -q "reset-failed" "$SYSTEMCTL_MOCK_LOG"
}

@test "integration: a suspend stop records how many in-flight turns it cuts" {
    # Card 55a6fe89. The stop is correct policy; its COST was invisible. Measured
    # 2026-11-04T00:46:03Z: one suspend cut three live turns and a session, and the only
    # trace was a gate block naming one unit. The line is the measurement, so assert the
    # NUMBER and that it is logged BEFORE the stop it describes.
    touch "$SYSTEMCTL_MOCK_STATE/healthy"
    touch "$SYSTEMCTL_MOCK_STATE/slots_busy"
    echo "active" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "active" > "$WATCHDOG_MOCK_STATE/cuda_state"
    printf '%s\n' "$$" > "$LLAMA_WATCHDOG_CUDA_SUSPEND_FILE"   # a LIVE owner: an empty marker is NOT held since v5

    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"stop cost: 2 in-flight request(s)"* ]]
    [[ "$output" == *"will be cut by this stop"* ]]
    # Ordering is the claim: a count taken after the stop would describe a lane with no
    # turns left on it, and would always read 0.
    # The line belongs to the ACT, not to the state: the next tick finds the lane already
    # down, says so, and must not re-print a cost for a stop it did not perform. A count
    # logged on every suspended tick would be a number about nothing.
    echo "inactive" > "$WATCHDOG_MOCK_STATE/cuda_state"
    run "$WATCHDOG_SCRIPT"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"CUDA lane suspended — held by live pid"* ]]
    [[ "$output" != *"stop cost:"* ]]
}

@test "integration: a stop on an idle lane says 0, not UNMEASURED" {
    # The control for the arm above: the same code path must still be able to report a
    # stop that cut nothing. Without this, "2" could be a constant.
    touch "$SYSTEMCTL_MOCK_STATE/healthy"
    echo "active" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "active" > "$WATCHDOG_MOCK_STATE/cuda_state"
    printf '%s\n' "$$" > "$LLAMA_WATCHDOG_CUDA_SUSPEND_FILE"

    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"stop cost: 0 in-flight requests"* ]]
    [[ "$output" == *"no live turn is cut by this stop"* ]]
}

@test "integration: an unreadable /slots reports UNMEASURED, never 0" {
    # "could not tell" and "nothing was cut" must not read alike. This fleet has already
    # paid for the other choice (v24: an unreadable nvidia-smi read as "busy" parked a
    # healthy lane for a morning). The stop still happens -- this records, it never vetoes.
    touch "$SYSTEMCTL_MOCK_STATE/healthy"
    touch "$SYSTEMCTL_MOCK_STATE/slots_unreadable"
    echo "active" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "active" > "$WATCHDOG_MOCK_STATE/cuda_state"
    printf '%s\n' "$$" > "$LLAMA_WATCHDOG_CUDA_SUSPEND_FILE"

    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"stop cost: UNMEASURED"* ]]
    [[ "$output" == *"UNKNOWN (not zero)"* ]]
    [[ "$output" != *"stop cost: 0 in-flight"* ]]
    grep -q "stop llama-cuda-llama32-3b-chat.service" "$SYSTEMCTL_MOCK_LOG"
}

@test "integration: the GPU-busy stop records its in-flight cost too" {
    # The other stop site. A busy card is a different reason for the same kill, and the
    # cost is identical -- so it must not be the one path that stays silent.
    touch "$SYSTEMCTL_MOCK_STATE/healthy"
    touch "$SYSTEMCTL_MOCK_STATE/slots_busy"
    touch "$SYSTEMCTL_MOCK_STATE/busy"
    echo "active" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "active" > "$WATCHDOG_MOCK_STATE/cuda_state"

    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"GPU busy — stopping llama-cuda-llama32-3b-chat"* ]]
    [[ "$output" == *"stop cost: 2 in-flight request(s)"* ]]
}

@test "integration: CUDA suspend does NOT suppress Xe recovery (unlike bench_lock)" {
    # bench_lock skips Xe restarts too; the CUDA-only flag must not, otherwise
    # suspending the CUDA lane would quietly disable Xe self-healing.
    echo "active" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "inactive" > "$WATCHDOG_MOCK_STATE/cuda_state"
    printf '%s\n' "$$" > "$LLAMA_WATCHDOG_CUDA_SUSPEND_FILE"   # a LIVE owner: an empty marker is NOT held since v5

    run "$WATCHDOG_SCRIPT"
    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$output" != *"bench lock present"* ]]
    [[ -f "$WATCHDOG_MOCK_STATE/restart_called" ]]
    grep -q "restart llama-xe-minicpm5-1b-chat.service" "$SYSTEMCTL_MOCK_LOG"
}

@test "integration: CUDA suspend resets CUDA strikes so a resumed lane starts clean" {
    echo "active" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "inactive" > "$WATCHDOG_MOCK_STATE/cuda_state"
    printf '2\n' > "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-cuda.strikes"
    printf '%s\n' "$$" > "$LLAMA_WATCHDOG_CUDA_SUSPEND_FILE"   # a LIVE owner: an empty marker is NOT held since v5

    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$(cat "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-cuda.strikes")" == "0" ]]
}

@test "integration: watchdog skips the Xe lane while systemd is already activating" {
    echo "activating" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "active" > "$WATCHDOG_MOCK_STATE/cuda_state"
    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"llama-xe-minicpm5-1b-chat activating"* ]]
    [[ ! -f "$WATCHDOG_MOCK_STATE/restart_called" ]]
}

@test "integration: watchdog skips the CUDA lane while systemd is already activating" {
    touch "$WATCHDOG_MOCK_STATE/healthy"
    echo "active" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "activating" > "$WATCHDOG_MOCK_STATE/cuda_state"

    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"CUDA unit activating"* ]]
    # Must not start (or restart) a unit that systemd is mid-start on.
    [[ ! -f "$WATCHDOG_MOCK_STATE/start_called" ]]
    [[ ! -f "$WATCHDOG_MOCK_STATE/restart_called" ]]
}

@test "integration: watchdog resets a failed Xe unit before restarting" {
    echo "failed" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "active" > "$WATCHDOG_MOCK_STATE/cuda_state"

    # First failure only strikes; reset-failed happens inside recovery (strike 2).
    run "$WATCHDOG_SCRIPT"
    [[ ! -f "$WATCHDOG_MOCK_STATE/reset_failed_called" ]]

    run "$WATCHDOG_SCRIPT"
    [[ "$status" -eq 0 ]]
    [[ -f "$WATCHDOG_MOCK_STATE/reset_failed_called" ]]
    [[ -f "$WATCHDOG_MOCK_STATE/restart_called" ]]
    grep -q "reset-failed llama-xe-minicpm5-1b-chat.service" "$SYSTEMCTL_MOCK_LOG"
}

@test "integration: watchdog logs a failed recovery without a non-zero exit" {
    echo "active" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "active" > "$WATCHDOG_MOCK_STATE/cuda_state"
    touch "$WATCHDOG_MOCK_STATE/fail_restart"
    touch "$WATCHDOG_MOCK_STATE/fail_start"

    run "$WATCHDOG_SCRIPT"
    run "$WATCHDOG_SCRIPT"

    # v3.0 always exits 0 (the user timer should not latch failed); a recovery
    # that cannot come up is reported on stdout instead.
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"recover failed for llama-xe-minicpm5-1b-chat"* ]]
}

@test "integration: watchdog script has version" {
    run grep -c '^VERSION=' "$WATCHDOG_SCRIPT"

    [[ "$output" -gt 0 ]]

    # ...and the marker tools/check-module-versions.sh parses, so a future edit
    # cannot quietly take this file back out of the version guard.  Until
    # 2026-09-14 it was the only GPU-adjacent script outside it.
    run grep -c '^# Module Version:' "$WATCHDOG_SCRIPT"
    [[ "$output" -eq 1 ]]
}

@test "integration: watchdog uses flock for locking" {
    run grep -c "flock" "$WATCHDOG_SCRIPT"

    [[ "$output" -gt 0 ]]
}

@test "integration: watchdog has an EXIT trap for lock cleanup" {
    run grep -c "trap.*EXIT" "$WATCHDOG_SCRIPT"

    [[ "$output" -gt 0 ]]
}

@test "integration: watchdog checks the health and window endpoints" {
    run grep -c "/health" "$WATCHDOG_SCRIPT"

    [[ "$output" -gt 0 ]]

    # Window invariant (2026-09-14): the window a request actually gets must
    # equal the ctx a unit advertises.  --parallel N DIVIDES it (kv_unified
    # defaults to false) and --fit can shrink it, both silently — the registry
    # carried parallel=16 for 34 of 35 rows, so `model use` served ctx/16 while
    # advertising ctx.  This check lives here because the three units do not
    # source the launcher that carries the other copy.
    run grep -c "window_check" "$WATCHDOG_SCRIPT"
    [[ "$output" -ge 2 ]]                       # defined once, called once inside the lane loop

    run grep -q "default_generation_settings.n_ctx" "$WATCHDOG_SCRIPT"
    [[ "$status" -eq 0 ]]                       # the semantics-independent field

    run grep -qF -- '--ctx-size ([0-9]+)' "$WATCHDOG_SCRIPT"
    [[ "$status" -eq 0 ]]                       # advertised ctx read from the unit
                                                # (-F: that text is a REGEX source,
                                                #  so [0-9] would mean "a digit")
}

@test "integration: watchdog has timeout logic" {
    run grep -c "timeout\|max-time" "$WATCHDOG_SCRIPT"

    [[ "$output" -gt 0 ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# CUDA flap counter (v3.8)
# ─────────────────────────────────────────────────────────────────────────────

@test "integration: a repeated CUDA death is counted, and past the threshold it shouts" {
    # The failure this exists for: on 2026-09-16 the lane died 11 times in 4h and
    # every death produced one "CUDA lane healthy" line from the restart below it.
    # A lane dying every few minutes was indistinguishable from one that never
    # missed a beat, so nobody looked.  Below the threshold the restart stays; the
    # silence goes.  AT the threshold v3.9 stops restarting (see the next test).
    echo "active" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "inactive" > "$WATCHDOG_MOCK_STATE/cuda_state"

    run "$WATCHDOG_SCRIPT"
    [[ "$output" != *"WARNING flap"* ]]          # 1st death: below threshold
    [[ -f "$WATCHDOG_MOCK_STATE/start_called" ]] # ...and it is restarted
    rm -f "$WATCHDOG_MOCK_STATE/start_called"
    run "$WATCHDOG_SCRIPT"
    [[ "$output" != *"WARNING flap"* ]]          # 2nd: still below
    [[ -f "$WATCHDOG_MOCK_STATE/start_called" ]] # ...still restarted

    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"WARNING flap: llama-cuda-llama32-3b-chat died 3x"* ]]
    [[ "$(wc -l < "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-cuda.flaps")" -eq 3 ]]
}

@test "integration: at the threshold the watchdog STOPS restarting and holds the lane down" {
    # v3.9: every restart is a CUDA context cycle and the dxgkrnl leak scales with those,
    # so a lane killed every few minutes must not be restarted forever. The hold is
    # announced as POLICY — "deliberately OFFLINE", not a fault — and it has an escape
    # hatch (delete the file).
    echo "active" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "inactive" > "$WATCHDOG_MOCK_STATE/cuda_state"

    run "$WATCHDOG_SCRIPT"   # 1
    run "$WATCHDOG_SCRIPT"   # 2
    rm -f "$WATCHDOG_MOCK_STATE/start_called"
    run "$WATCHDOG_SCRIPT"   # 3 -> threshold

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"deliberately OFFLINE"* ]]
    [[ "$output" != *"starting CUDA lane"* ]]
    [[ ! -f "$WATCHDOG_MOCK_STATE/start_called" ]]
    [[ -f "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-cuda.flaphold" ]]

    # ...and while the hold is live, further runs leave it alone rather than retrying.
    run "$WATCHDOG_SCRIPT"
    [[ "$output" == *"held down after repeated flaps"* ]]
    [[ ! -f "$WATCHDOG_MOCK_STATE/start_called" ]]
}

@test "integration: an EXPIRED hold lets the lane start again" {
    # The cooling-off must not become a silent permanent outage: once it lapses the
    # watchdog resumes normal recovery without anyone having to intervene.
    echo "active" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "inactive" > "$WATCHDOG_MOCK_STATE/cuda_state"
    printf '%s\n' "$(( $(date +%s) - 5 ))" > "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-cuda.flaphold"

    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"starting CUDA lane"* ]]
    [[ -f "$WATCHDOG_MOCK_STATE/start_called" ]]
}

@test "integration: a deliberately suspended CUDA lane is not counted as a flap" {
    # A hold-down (bench/autotune wants the card) is not a death. Counting it
    # would manufacture a warning that sends the next reader hunting a killer
    # that does not exist — and the suspend flag is precisely how a bench holds
    # the lane down for hours.
    echo "active" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "inactive" > "$WATCHDOG_MOCK_STATE/cuda_state"
    printf '%s\n' "$$" > "$LLAMA_WATCHDOG_CUDA_SUSPEND_FILE"   # a LIVE owner: an empty marker is NOT held since v5

    run "$WATCHDOG_SCRIPT"
    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"CUDA lane suspended"* ]]
    [[ "$output" != *"WARNING flap"* ]]
    [[ ! -e "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-cuda.flaps" ]]
}

@test "integration: a LEGACY empty suspend marker does NOT suppress the death count" {
    # THE TRANSITION.  The marker left on disk by a SIGKILLed holder is 0 bytes (its
    # pid sat in a now-orphaned companion).  Under the old existence test that empty
    # file read as "suspended" and kept the lane down for hours; under v5 it carries
    # no pid, so the lane's absence is an UNEXPECTED death: counted AND recovered —
    # no manual `rm` needed.  This is the case that catches a reader still testing
    # the marker's mere existence.
    echo "active" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "inactive" > "$WATCHDOG_MOCK_STATE/cuda_state"
    : > "$LLAMA_WATCHDOG_CUDA_SUSPEND_FILE"                    # the legacy 0-byte shape
    rm -f "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-cuda.flaps"
    rm -f "$WATCHDOG_MOCK_STATE/start_called"

    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$output" != *"CUDA lane suspended"* ]]                 # not honoured as a hold
    [[ "$(wc -l < "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-cuda.flaps")" -eq 1 ]]
    [[ -f "$WATCHDOG_MOCK_STATE/start_called" ]]               # ...and the lane was restored
}

@test "integration: flap stamps outside the window are pruned, not counted" {
    # It is a ROLLING window: three deaths an hour apart is a lane being restarted
    # for unrelated reasons over a working day; three in ten minutes is a flap.
    # Stale stamps must not accumulate into a warning about a lane that has since
    # been healthy for hours.
    echo "active" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "inactive" > "$WATCHDOG_MOCK_STATE/cuda_state"
    local old
    old=$(( $(date +%s) - 7200 ))
    printf '%s\n%s\n%s\n' "$old" "$old" "$old" > "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-cuda.flaps"

    run "$WATCHDOG_SCRIPT"

    [[ "$output" != *"WARNING flap"* ]]
    [[ "$(wc -l < "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-cuda.flaps")" -eq 1 ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# GPU-busy stop marker (v3.12)
# ─────────────────────────────────────────────────────────────────────────────
# The 2026-09-18 repro: the watchdog stopped the CUDA lane for a foreign GPU owner
# three times in an hour, and each stop was then found again by the NEXT free tick
# and counted as an unexpected death — so a lane the watchdog itself had parked was
# declared to be flapping, held offline for 30min on an idle card, and the log
# blamed a killer that never existed. The marker says "that stop was mine".

@test "integration: three deliberate GPU-busy stops do not trip the flap alert or the hold" {
    # Neutralise the always-on lanes (Xe + CPU; the second Xe lane is already parked
    # in `activating` by setup) so only the gated CUDA lane is exercised — the CUDA
    # stop below removes the shared `healthy` marker, which would otherwise read as
    # deaths (and flaps, now that every always-on lane has a flap counter) on them.
    echo "activating" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "activating" > "$WATCHDOG_MOCK_STATE/cpu_state"

    for _ in 1 2 3; do
        # A foreign owner takes the card: the watchdog stops OUR lane on purpose.
        echo "active" > "$WATCHDOG_MOCK_STATE/cuda_state"
        touch "$WATCHDOG_MOCK_STATE/busy"
        run "$WATCHDOG_SCRIPT"
        [[ "$output" == *"GPU busy — stopping llama-cuda-llama32-3b-chat"* ]]
        [[ -f "$LLAMA_WATCHDOG_CUDA_GPUSTOP_FILE" ]]

        # The card frees; the unit is down because WE stopped it, not because it died.
        rm -f "$WATCHDOG_MOCK_STATE/busy"
        echo "inactive" > "$WATCHDOG_MOCK_STATE/cuda_state"
        rm -f "$WATCHDOG_MOCK_STATE/start_called"
        run "$WATCHDOG_SCRIPT"
        [[ "$output" == *"the stop was ours for a foreign owner"* ]]
        [[ -f "$WATCHDOG_MOCK_STATE/start_called" ]]
    done

    [[ "$status" -eq 0 ]]
    [[ "$output" != *"WARNING flap"* ]]
    [[ "$output" != *"deliberately OFFLINE"* ]]
    [[ ! -e "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-cuda.flaps" ]]
    [[ ! -e "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-cuda.flaphold" ]]
}

@test "integration: the GPU-busy marker is single-use — a later death still counts" {
    # The marker explains exactly ONE restart. Once consumed, the next death must
    # be counted normally, or a genuinely broken lane could hide behind a stale
    # "we stopped it ourselves" note for as long as the marker lives.
    touch "$WATCHDOG_MOCK_STATE/healthy"
    echo "active" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "active" > "$WATCHDOG_MOCK_STATE/cuda_state"
    touch "$WATCHDOG_MOCK_STATE/busy"
    run "$WATCHDOG_SCRIPT"                       # our stop -> marker written
    [[ -f "$LLAMA_WATCHDOG_CUDA_GPUSTOP_FILE" ]]

    rm -f "$WATCHDOG_MOCK_STATE/busy"
    echo "inactive" > "$WATCHDOG_MOCK_STATE/cuda_state"
    run "$WATCHDOG_SCRIPT"                       # free tick -> marker consumed
    [[ ! -e "$LLAMA_WATCHDOG_CUDA_GPUSTOP_FILE" ]]
    [[ ! -e "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-cuda.flaps" ]]

    # Now a real death: down, card free, nothing suspending us, no marker left.
    run "$WATCHDOG_SCRIPT"

    [[ "$output" != *"the stop was ours"* ]]
    [[ "$(wc -l < "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-cuda.flaps")" -eq 1 ]]
}

@test "integration: an EXPIRED GPU-busy marker does not suppress a flap" {
    # The TTL is the second bound: a marker whose lane never came back (so no free
    # tick ever consumed it) must stop explaining things once it goes stale.
    touch "$WATCHDOG_MOCK_STATE/healthy"
    echo "active" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "inactive" > "$WATCHDOG_MOCK_STATE/cuda_state"
    printf '%s\n' "$(( $(date +%s) - 5 ))" > "$LLAMA_WATCHDOG_CUDA_GPUSTOP_FILE"

    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$output" != *"the stop was ours"* ]]
    [[ "$(wc -l < "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-cuda.flaps")" -eq 1 ]]
}

@test "integration: the GPU-busy line carries the probe's own reasons" {
    # "GPU busy" alone cannot say which of the five signals fired, so a bench
    # holding the card, a foreign app on it and a util spike all read the same —
    # which is why the 2026-09-19 stop could not be attributed after the fact.
    echo "active" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "active" > "$WATCHDOG_MOCK_STATE/cuda_state"
    touch "$WATCHDOG_MOCK_STATE/busy"

    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"GPU busy — stopping llama-cuda-llama32-3b-chat"* ]]
    [[ "$output" == *"[probe: mock]"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# CPU tail lane (v3.10)
# ─────────────────────────────────────────────────────────────────────────────
# These tests neutralise the other two lanes on purpose. The Xe lane is put in
# `activating` (skipped without a strike) and the GPU is reported busy with the
# CUDA unit inactive (strike reset, no stop/start) — so neither lane can touch the
# shared `healthy` marker and mask the CPU lane's own behaviour.

@test "integration: watchdog restarts the CPU lane on the 2nd consecutive failure" {
    # Before v3.10 this tier had no supervisor at all: Restart=on-failure never
    # undid the four direct kills, and nothing else watched the unit.
    echo "activating" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "inactive" > "$WATCHDOG_MOCK_STATE/cuda_state"
    touch "$WATCHDOG_MOCK_STATE/busy"

    run "$WATCHDOG_SCRIPT"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"llama-cpu-qwen25-3b-chat health check failed on :18084 (unit=inactive, strike 1/2)"* ]]
    [[ ! -f "$WATCHDOG_MOCK_STATE/restart_called" ]]

    run "$WATCHDOG_SCRIPT"
    [[ "$status" -eq 0 ]]
    [[ -f "$WATCHDOG_MOCK_STATE/restart_called" ]]
    grep -q "restart llama-cpu-qwen25-3b-chat.service" "$SYSTEMCTL_MOCK_LOG"
    [[ "$output" == *"Recovery successful — llama-cpu-qwen25-3b-chat healthy on :18084"* ]]
}

@test "integration: watchdog leaves a still-loading (503) CPU lane alone" {
    echo "activating" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "inactive" > "$WATCHDOG_MOCK_STATE/cuda_state"
    touch "$WATCHDOG_MOCK_STATE/busy"
    touch "$WATCHDOG_MOCK_STATE/loading"

    run "$WATCHDOG_SCRIPT"
    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"llama-cpu-qwen25-3b-chat still loading (503)"* ]]
    [[ ! -f "$WATCHDOG_MOCK_STATE/restart_called" ]]
    [[ "$(cat "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-cpu-qwen25-3b-chat.strikes" 2>/dev/null || echo 0)" == "0" ]]
}

@test "integration: watchdog skips the CPU lane while systemd is already activating" {
    echo "activating" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "activating" > "$WATCHDOG_MOCK_STATE/cuda_state"
    echo "activating" > "$WATCHDOG_MOCK_STATE/cpu_state"

    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"llama-cpu-qwen25-3b-chat activating"* ]]
    [[ ! -f "$WATCHDOG_MOCK_STATE/restart_called" ]]
}

@test "integration: watchdog resets a failed CPU unit before restarting" {
    echo "activating" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "inactive" > "$WATCHDOG_MOCK_STATE/cuda_state"
    touch "$WATCHDOG_MOCK_STATE/busy"
    echo "failed" > "$WATCHDOG_MOCK_STATE/cpu_state"

    run "$WATCHDOG_SCRIPT"
    [[ ! -f "$WATCHDOG_MOCK_STATE/reset_failed_called" ]]

    run "$WATCHDOG_SCRIPT"
    [[ "$status" -eq 0 ]]
    [[ -f "$WATCHDOG_MOCK_STATE/reset_failed_called" ]]
    grep -q "reset-failed llama-cpu-qwen25-3b-chat.service" "$SYSTEMCTL_MOCK_LOG"
}

@test "integration: watchdog skips the CPU lane when the bench lock is present" {
    echo "activating" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "inactive" > "$WATCHDOG_MOCK_STATE/cuda_state"
    touch "$WATCHDOG_MOCK_STATE/busy"
    touch "$LLM_BENCH_LOCK_FILE"

    run "$WATCHDOG_SCRIPT"
    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"llama-cpu-qwen25-3b-chat down but bench lock present — skipping restart"* ]]
    [[ ! -f "$WATCHDOG_MOCK_STATE/restart_called" ]]
    [[ "$(cat "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-cpu-qwen25-3b-chat.strikes" 2>/dev/null || echo 0)" == "0" ]]
}

@test "integration: a repeated CPU death is counted, and the lane still restarts (no CUDA hold)" {
    # The v3.8 lesson applies to this tier too: a lane the watchdog silently
    # restarts reads exactly like one that never missed a beat. The CUDA
    # cooling-off must NOT be copied — it exists for the dxgkrnl leak that
    # repeated CUDA context cycles cause, and holding the chain's tail down would
    # delete the tier instead of protecting it.
    echo "activating" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "inactive" > "$WATCHDOG_MOCK_STATE/cuda_state"
    touch "$WATCHDOG_MOCK_STATE/busy"

    # Three deaths already inside the rolling window plus one strike on the board:
    # the next failure is the 4th death AND the 2nd strike, so a single run both
    # warns and recovers — the exact pair the CUDA lane splits with a hold.
    local now
    now=$(date +%s)
    printf '%s\n%s\n%s\n' "$now" "$now" "$now" > "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-cpu-qwen25-3b-chat.flaps"
    printf '1\n' > "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-cpu-qwen25-3b-chat.strikes"

    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"WARNING flap: llama-cpu-qwen25-3b-chat died 4x"* ]]
    [[ "$(wc -l < "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-cpu-qwen25-3b-chat.flaps")" -eq 4 ]]
    [[ -f "$WATCHDOG_MOCK_STATE/restart_called" ]]
    [[ ! -e "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-cpu-qwen25-3b-chat.flaphold" ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# Second Xe lane (v3.11) — llama-xe-llama32-3b-chat (:18085)
# ─────────────────────────────────────────────────────────────────────────────
# These tests neutralise the other three lanes on purpose: the Xe lane and the CPU
# lane are put in `activating` (skipped without a strike) and the GPU is reported
# busy with the CUDA unit inactive (strike reset, no stop/start) — so none of them
# can touch the shared `healthy` marker and mask this lane's own behaviour.

@test "integration: the two Xe lanes are tracked independently" {
    # The trap this lane walked into: both Xe units end in "-chat".service, so a mock
    # (and any real code) that classified units by *cuda*/*cpu*/catch-all made one
    # lane's state answer for the other. Assert the two disagree on the same run.
    echo "activating" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "failed" > "$WATCHDOG_MOCK_STATE/xe3b_state"
    echo "activating" > "$WATCHDOG_MOCK_STATE/cpu_state"
    echo "inactive" > "$WATCHDOG_MOCK_STATE/cuda_state"
    touch "$WATCHDOG_MOCK_STATE/busy"

    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"llama-xe-minicpm5-1b-chat activating"* ]]
    [[ "$output" == *"llama-xe-llama32-3b-chat health check failed on :18085 (unit=failed, strike 1/2)"* ]]
}

@test "integration: watchdog restarts the second Xe lane on the 2nd consecutive failure" {
    # Before v3.11 this unit was enabled, Restart=always, and still sat `failed` for
    # 22h: StartLimitBurst (6 in 600s) parks it and nothing lifted it.
    echo "activating" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "inactive" > "$WATCHDOG_MOCK_STATE/cuda_state"
    echo "activating" > "$WATCHDOG_MOCK_STATE/cpu_state"
    touch "$WATCHDOG_MOCK_STATE/busy"
    echo "inactive" > "$WATCHDOG_MOCK_STATE/xe3b_state"

    run "$WATCHDOG_SCRIPT"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"llama-xe-llama32-3b-chat health check failed on :18085 (unit=inactive, strike 1/2)"* ]]
    [[ ! -f "$WATCHDOG_MOCK_STATE/restart_called" ]]

    run "$WATCHDOG_SCRIPT"
    [[ "$status" -eq 0 ]]
    [[ -f "$WATCHDOG_MOCK_STATE/restart_called" ]]
    grep -q "restart llama-xe-llama32-3b-chat.service" "$SYSTEMCTL_MOCK_LOG"
    [[ "$output" == *"Recovery successful — llama-xe-llama32-3b-chat healthy on :18085"* ]]
}

@test "integration: watchdog leaves a still-loading (503) second Xe lane alone" {
    echo "activating" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "inactive" > "$WATCHDOG_MOCK_STATE/cuda_state"
    echo "activating" > "$WATCHDOG_MOCK_STATE/cpu_state"
    touch "$WATCHDOG_MOCK_STATE/busy"
    echo "inactive" > "$WATCHDOG_MOCK_STATE/xe3b_state"
    touch "$WATCHDOG_MOCK_STATE/loading"

    run "$WATCHDOG_SCRIPT"
    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"llama-xe-llama32-3b-chat still loading (503)"* ]]
    [[ ! -f "$WATCHDOG_MOCK_STATE/restart_called" ]]
    [[ "$(cat "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-xe-llama32-3b-chat.strikes" 2>/dev/null || echo 0)" == "0" ]]
}

@test "integration: watchdog skips the second Xe lane while systemd is already activating" {
    echo "activating" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "inactive" > "$WATCHDOG_MOCK_STATE/cuda_state"
    echo "activating" > "$WATCHDOG_MOCK_STATE/cpu_state"
    touch "$WATCHDOG_MOCK_STATE/busy"
    echo "activating" > "$WATCHDOG_MOCK_STATE/xe3b_state"

    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"llama-xe-llama32-3b-chat activating"* ]]
    [[ ! -f "$WATCHDOG_MOCK_STATE/restart_called" ]]
}

@test "integration: watchdog resets a failed second Xe unit before restarting" {
    # The live state this lane was found in (start-limit-hit): `restart` alone would
    # not clear it, so reset-failed must come first.
    echo "activating" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "inactive" > "$WATCHDOG_MOCK_STATE/cuda_state"
    echo "activating" > "$WATCHDOG_MOCK_STATE/cpu_state"
    touch "$WATCHDOG_MOCK_STATE/busy"
    echo "failed" > "$WATCHDOG_MOCK_STATE/xe3b_state"

    run "$WATCHDOG_SCRIPT"
    [[ ! -f "$WATCHDOG_MOCK_STATE/reset_failed_called" ]]

    run "$WATCHDOG_SCRIPT"
    [[ "$status" -eq 0 ]]
    [[ -f "$WATCHDOG_MOCK_STATE/reset_failed_called" ]]
    grep -q "reset-failed llama-xe-llama32-3b-chat.service" "$SYSTEMCTL_MOCK_LOG"
}

@test "integration: watchdog skips the second Xe lane when the bench lock is present" {
    # A hosted bench session stopping lanes is the documented killer of this lane, and
    # benches take the lock — so the lock is the gate that keeps us from fighting one.
    echo "activating" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "inactive" > "$WATCHDOG_MOCK_STATE/cuda_state"
    echo "activating" > "$WATCHDOG_MOCK_STATE/cpu_state"
    touch "$WATCHDOG_MOCK_STATE/busy"
    echo "inactive" > "$WATCHDOG_MOCK_STATE/xe3b_state"
    touch "$LLM_BENCH_LOCK_FILE"

    run "$WATCHDOG_SCRIPT"
    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"llama-xe-llama32-3b-chat down but bench lock present — skipping restart"* ]]
    [[ ! -f "$WATCHDOG_MOCK_STATE/restart_called" ]]
    [[ "$(cat "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-xe-llama32-3b-chat.strikes" 2>/dev/null || echo 0)" == "0" ]]
}

@test "integration: a repeated second-Xe death is counted, and the lane still restarts (no CUDA hold)" {
    # Same reasoning as the CPU tier: a lane the watchdog silently restarts reads
    # exactly like one that never missed a beat. The CUDA cooling-off must NOT be
    # copied here — it exists for the dxgkrnl leak that repeated CUDA context cycles
    # cause, this lane holds no CUDA context, and holding it down would delete the
    # chain tier rather than protect it.
    echo "activating" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "inactive" > "$WATCHDOG_MOCK_STATE/cuda_state"
    echo "activating" > "$WATCHDOG_MOCK_STATE/cpu_state"
    touch "$WATCHDOG_MOCK_STATE/busy"
    # Must be set explicitly: setup() parks LANE 4 in `activating`, which the script
    # skips without a strike, so a flap could never be recorded.
    echo "inactive" > "$WATCHDOG_MOCK_STATE/xe3b_state"

    local now
    now=$(date +%s)
    printf '%s\n%s\n%s\n' "$now" "$now" "$now" > "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-xe-llama32-3b-chat.flaps"
    printf '1\n' > "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-xe-llama32-3b-chat.strikes"

    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"WARNING flap: llama-xe-llama32-3b-chat died 4x"* ]]
    [[ "$(wc -l < "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-xe-llama32-3b-chat.flaps")" -eq 4 ]]
    [[ -f "$WATCHDOG_MOCK_STATE/restart_called" ]]
    [[ ! -e "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-xe-llama32-3b-chat.flaphold" ]]
}

@test "integration: a lane whose unit is NOT INSTALLED is skipped, not restarted" {
    # The live defect, 2026-11-01 00:22Z: three of the four lanes named units this box
    # does not have. The lane bodies did not care — they probed a dead port, struck,
    # and called recover(), which spends 150s in wait_healthy on a port nobody serves.
    # Three of those blew systemd's start budget and `llama-watchdog.service` itself
    # was reported `failed (Result=timeout)`. LoadState is the field that can tell
    # "not installed" from "stopped": both read `inactive` in ActiveState.
    rm -f "$WATCHDOG_MOCK_STATE"/*_state
    echo "not-found" > "$WATCHDOG_MOCK_STATE/load_xe"
    echo "not-found" > "$WATCHDOG_MOCK_STATE/load_cuda"
    echo "not-found" > "$WATCHDOG_MOCK_STATE/load_cpu"
    echo "not-found" > "$WATCHDOG_MOCK_STATE/load_xe3b"
    # Nothing is up, so every lane would strike and restart if the skip were missing.
    printf '1\n' > "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-xe-minicpm5-1b-chat.strikes"
    printf '1\n' > "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-cuda.strikes"
    printf '1\n' > "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-cpu-qwen25-3b-chat.strikes"
    printf '1\n' > "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-xe-llama32-3b-chat.strikes"

    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"llama-xe-minicpm5-1b-chat not installed on this host"* ]]
    [[ "$output" == *"llama-cpu-qwen25-3b-chat not installed on this host"* ]]
    [[ "$output" == *"llama-xe-llama32-3b-chat not installed on this host"* ]]
    [[ ! -f "$WATCHDOG_MOCK_STATE/restart_called" ]]
    [[ ! -f "$WATCHDOG_MOCK_STATE/start_called" ]]
    # Strikes must not accrue against a unit that does not exist: an absent lane is a
    # policy answer, and a counter climbing on it would eventually read as a sick lane.
    [[ "$(cat "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-xe-minicpm5-1b-chat.strikes")" == "1" ]]
}

@test "integration: NEGATIVE ARM — an installed lane that is DOWN still restarts" {
    # Without this, the skip test above is equally consistent with a watchdog that
    # cannot restart anything at all. The skip must be conditional on LoadState, so
    # flipping only that one field has to restore the old behaviour.
    rm -f "$WATCHDOG_MOCK_STATE"/*_state
    echo "loaded" > "$WATCHDOG_MOCK_STATE/load_xe"
    echo "inactive" > "$WATCHDOG_MOCK_STATE/xe_state"
    printf '1\n' > "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-xe-minicpm5-1b-chat.strikes"

    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Restart issued: llama-xe-minicpm5-1b-chat"* ]]
    [[ -f "$WATCHDOG_MOCK_STATE/restart_called" ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# v3.15 — the flap hold must not feed itself, and a live GPU claim is not a death
# ─────────────────────────────────────────────────────────────────────────────

@test "integration: a tick during a live flap hold stamps NO new death and does not extend it" {
    # Measured 2026-11-02 on the live box: the hold was entered at 02:57:27, and the
    # 03:30:12 and 03:35:12 ticks each recorded a fresh death ("died 4x", "died 5x")
    # for a lane nobody had tried to start, then 03:30:12 re-armed the hold for another
    # 30 min.  A held lane could therefore never come back: every expiry found a stamp
    # its own ticks had just written.  This is the regression test for that ratchet.
    echo "active" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "inactive" > "$WATCHDOG_MOCK_STATE/cuda_state"

    run "$WATCHDOG_SCRIPT"   # 1
    run "$WATCHDOG_SCRIPT"   # 2
    run "$WATCHDOG_SCRIPT"   # 3 -> hold entered
    [[ "$(wc -l < "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-cuda.flaps")" -eq 3 ]]
    hold_before="$(cat "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-cuda.flaphold")"
    rm -f "$WATCHDOG_MOCK_STATE/start_called"

    run "$WATCHDOG_SCRIPT"   # 4 -> held: no count, no start, no re-arm

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"held down after repeated flaps"* ]]
    [[ "$output" != *"WARNING flap"* ]]
    [[ "$output" != *"starting CUDA lane"* ]]
    [[ ! -f "$WATCHDOG_MOCK_STATE/start_called" ]]
    [[ "$(wc -l < "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-cuda.flaps")" -eq 3 ]]
    [[ "$(cat "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-cuda.flaphold")" == "$hold_before" ]]
}

@test "integration: an expired hold clears itself and starts the lane WITHOUT a death stamp" {
    # The other half of the ratchet: at expiry the lane is down BECAUSE the hold kept
    # it down, so that is not an unexpected death.  It must be cleared and started, and
    # the stamp count must not grow — otherwise the next tick re-enters the hold from
    # stamps that describe the outage the hold itself caused.
    echo "active" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "inactive" > "$WATCHDOG_MOCK_STATE/cuda_state"
    now=$(date +%s)
    printf '%s\n%s\n%s\n' "$now" "$now" "$now" > "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-cuda.flaps"
    printf '%s\n' "$(( now - 5 ))" > "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-cuda.flaphold"

    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"cooling-off ended"* ]]
    [[ "$output" == *"starting CUDA lane"* ]]
    [[ "$output" != *"WARNING flap"* ]]
    [[ -f "$WATCHDOG_MOCK_STATE/start_called" ]]
    [[ ! -e "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-cuda.flaphold" ]]
    [[ "$(wc -l < "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-cuda.flaps")" -eq 3 ]]
}

@test "integration: a LIVE GPU ownership flock parks the CUDA lane without counting a death" {
    # The instrument that disagreed with the guard on 2026-11-02: bench_lock() reads the
    # marker FILE, the investigator bench takes a FLOCK, so the watchdog called the card
    # unclaimed 14 s after the guard called it claimed and started lanes into the bench's
    # queued stop jobs.  This is the flock arm, and the NEGATIVE ARM beside it is the
    # release: no lock, same state, lane starts.
    export INVESTIGATOR_GPU_LOCK="$TAC_TEST_TMPDIR/gpu.lock"
    : > "$INVESTIGATOR_GPU_LOCK"
    ( flock -n 9 && sleep 20 ) 9>"$INVESTIGATOR_GPU_LOCK" &
    holder=$!
    sleep 0.3
    echo "active" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "inactive" > "$WATCHDOG_MOCK_STATE/cuda_state"

    run "$WATCHDOG_SCRIPT"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"a bench holds the card"* ]]
    [[ "$output" != *"WARNING flap"* ]]
    [[ ! -f "$WATCHDOG_MOCK_STATE/start_called" ]]
    [[ ! -e "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-cuda.flaps" ]]

    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    rm -f "$INVESTIGATOR_GPU_LOCK"

    # NEGATIVE ARM: with the claim gone the same down lane is started.
    run "$WATCHDOG_SCRIPT"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"starting CUDA lane"* ]]
    [[ -f "$WATCHDOG_MOCK_STATE/start_called" ]]
}


# ─────────────────────────────────────────────────────────────────────────────
# v3.17 — the requested-stop record: WHO asked for THIS stop
# ─────────────────────────────────────────────────────────────────────────────
# The investigator writes "requested-stop pid= start= ttl= unit= ts=" BEFORE its own
# `systemctl stop` (pipeline/gpu/_exclusive.py:645) and nothing on the console side read
# it, so a stop a gpu.lock holder had asked for was charged to the lane as an unexpected
# death.  The record is the only instrument that outlives the flock's release:
# gpu_claim_held probes the PRESENT and the kernel drops the flock on release.
#
# The falsification is the pair below, and it is deliberately the SAME record shape:
# live requester -> attributed, nothing stamped; dead requester -> refused, stamped.

# _reqstop_start <pid> — the epoch the WRITER stores in `start=`: btime plus
# /proc/<pid>/stat field 22 in CLOCK TICKS (pipeline/gpu/_lock.py process_start_epoch).
# Computed here from the PUBLISHED definition instead of calling the reader's helper, so
# a units mistake in bin/_tac-bin-lib.sh cannot be mirrored by the test and pass.
_reqstop_start() {
    local _stat _rest _btime _clk
    local -a _f
    _stat="$(cat "/proc/$1/stat")"
    _rest="${_stat##*)}"
    read -r -a _f <<<"$_rest"
    _btime="$(awk '/^btime /{print $2}' /proc/stat)"
    _clk="$(getconf CLK_TCK)"
    echo $(( _btime + _f[19] / _clk ))
}

# _reqstop_write <pid> <start> <ttl> — one record line, as the investigator writes it.
_reqstop_write() {
    printf 'requested-stop pid=%s start=%s ttl=%s unit=llama-cuda-llama32-3b-chat.service ts=%s\n' \
        "$1" "$2" "$3" "$(date +%s)" > "$INVESTIGATOR_REQUESTED_STOP"
}

@test "integration: a LIVE requested-stop record is attributed, not counted, and consumed once" {
    export INVESTIGATOR_REQUESTED_STOP="$TAC_TEST_TMPDIR/requested-stop"
    export LLAMA_WATCHDOG_REQSTOP_SEEN_FILE="$TAC_TEST_TMPDIR/llama-watchdog.requested-stop.seen"
    echo "active" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "inactive" > "$WATCHDOG_MOCK_STATE/cuda_state"
    _reqstop_write "$$" "$(_reqstop_start $$)" "$(( $(date +%s) + 21600 ))"

    run "$WATCHDOG_SCRIPT"

    # The units trap: a reader comparing `start=` with field 22 RAW would refuse this
    # record (ticks vs epoch) and stamp a death — which is what this arm forbids.
    [[ "$status" -eq 0 ]]
    _expect="REQUESTED by a live claim (pid $$,"
    [[ "$output" == *"$_expect"* ]]
    [[ "$output" == *"starting CUDA lane"* ]]
    [[ "$output" != *"WARNING flap"* ]]
    [[ ! -e "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-cuda.flaps" ]]
    [[ -f "$WATCHDOG_MOCK_STATE/start_called" ]]
    [[ -f "$LLAMA_WATCHDOG_REQSTOP_SEEN_FILE" ]]

    # SINGLE USE: the same record, the lane down again, and the record must NOT explain a
    # second restart — its 6 h TTL would otherwise mask a genuine death hours later.
    rm -f "$WATCHDOG_MOCK_STATE/start_called"
    echo "inactive" > "$WATCHDOG_MOCK_STATE/cuda_state"
    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"ALREADY CONSUMED"* ]]
    # flap_alert speaks only AT the threshold, so a single stamp is silent by design and
    # the STAMP FILE is the evidence — asserting the alert line here would have been an
    # assertion about a different object (and failed for the right output, wrongly).
    [[ "$(grep -c . "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-cuda.flaps")" -eq 1 ]]
}

@test "integration: a requested-stop record whose REQUESTER IS DEAD is refused, and the death is counted" {
    export INVESTIGATOR_REQUESTED_STOP="$TAC_TEST_TMPDIR/requested-stop"
    export LLAMA_WATCHDOG_REQSTOP_SEEN_FILE="$TAC_TEST_TMPDIR/llama-watchdog.requested-stop.seen"
    echo "active" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "inactive" > "$WATCHDOG_MOCK_STATE/cuda_state"
    sleep 0.05 &
    _dead=$!
    wait "$_dead" 2>/dev/null || true
    _reqstop_write "$_dead" 1 "$(( $(date +%s) + 21600 ))"

    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"not attributable"* ]]
    # The REASON must be the dead requester, not an unparsable line: this arm passed for
    # the wrong reason once, while the parse case was stripping `ttl=` from itself and
    # every record read as MALFORMED — a refusal is not evidence of the reason for it.
    [[ "$output" != *"MALFORMED"* ]]
    [[ "$output" != *"REQUESTED by a live claim"* ]]
    [[ "$(grep -c . "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-cuda.flaps")" -eq 1 ]]
}

@test "integration: a RECYCLED pid does not inherit a stop request" {
    export INVESTIGATOR_REQUESTED_STOP="$TAC_TEST_TMPDIR/requested-stop"
    export LLAMA_WATCHDOG_REQSTOP_SEEN_FILE="$TAC_TEST_TMPDIR/llama-watchdog.requested-stop.seen"
    echo "active" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "inactive" > "$WATCHDOG_MOCK_STATE/cuda_state"
    # Alive pid, wrong start: exactly what a reused pid looks like to the reader.
    _reqstop_write "$$" "$(( $(_reqstop_start $$) - 3600 ))" "$(( $(date +%s) + 21600 ))"

    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"a recycled pid"* ]]
    [[ "$output" != *"REQUESTED by a live claim"* ]]
    [[ "$(grep -c . "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-cuda.flaps")" -eq 1 ]]
}

@test "integration: an EXPIRED requested-stop record is refused, not honoured on age alone" {
    export INVESTIGATOR_REQUESTED_STOP="$TAC_TEST_TMPDIR/requested-stop"
    export LLAMA_WATCHDOG_REQSTOP_SEEN_FILE="$TAC_TEST_TMPDIR/llama-watchdog.requested-stop.seen"
    echo "active" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "inactive" > "$WATCHDOG_MOCK_STATE/cuda_state"
    _reqstop_write "$$" "$(_reqstop_start $$)" "$(( $(date +%s) - 60 ))"

    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"EXPIRED"* ]]
    [[ "$output" != *"REQUESTED by a live claim"* ]]
    [[ "$(grep -c . "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-cuda.flaps")" -eq 1 ]]
}


@test "integration: a MALFORMED requested-stop record is refused, and says so" {
    export INVESTIGATOR_REQUESTED_STOP="$TAC_TEST_TMPDIR/requested-stop"
    export LLAMA_WATCHDOG_REQSTOP_SEEN_FILE="$TAC_TEST_TMPDIR/llama-watchdog.requested-stop.seen"
    echo "active" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "inactive" > "$WATCHDOG_MOCK_STATE/cuda_state"
    # A line that names the unit but carries an unusable pid/ttl: the reader must report
    # "cannot tell", not fall through to a silence that reads as "no request".
    printf 'requested-stop pid=x ttl=x unit=llama-cuda-llama32-3b-chat.service ts=x\n' \
        > "$INVESTIGATOR_REQUESTED_STOP"

    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"MALFORMED"* ]]
    [[ "$output" != *"REQUESTED by a live claim"* ]]
    [[ "$(grep -c . "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-cuda.flaps")" -eq 1 ]]
}

# end of file
