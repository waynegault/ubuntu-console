#!/usr/bin/env bats
# ==============================================================================
# Integration Tests — Llama Watchdog (v3.8, dual-lane)
# ==============================================================================
# Tests llama-watchdog.sh v3.8: health probing (including the 503 "loading"
# signal), 2-strike recovery, the always-on Xe lane, the GPU-gated CUDA lane,
# the v3.5 CUDA-only suspend flag, and the v3.8 CUDA flap counter. All external
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
    mkdir -p "$WATCHDOG_MOCK_BIN" "$WATCHDOG_MOCK_STATE" "$WATCHDOG_MOCK_HOME/.local/bin"

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
exit 22
MOCK
    chmod +x "$WATCHDOG_MOCK_BIN/curl"

    # Mock systemctl --user. `show` reports per-unit state from xe_state/cuda_state;
    # restart/start mark the lane healthy (unless fail_restart/fail_start is set);
    # stop and reset-failed record themselves.
    cat > "$WATCHDOG_MOCK_BIN/systemctl" <<'MOCK'
#!/usr/bin/env bash
set -uo pipefail
if [[ "${1:-}" == "--user" ]]; then shift; fi
op="${1:-}"; shift || true
case "$op" in
    show)
        unit="${1:-}"
        case "$unit" in
            *cuda*) cat "$SYSTEMCTL_MOCK_STATE/cuda_state" 2>/dev/null || echo "inactive" ;;
            *)        cat "$SYSTEMCTL_MOCK_STATE/xe_state" 2>/dev/null || echo "inactive" ;;
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
    : > "$SYSTEMCTL_MOCK_LOG" 2>/dev/null || true
    rm -f "$WATCHDOG_MOCK_STATE"/*
    rm -f "$LLAMA_WATCHDOG_LOCK_FILE" \
          "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-xe.strikes" \
          "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-cuda.strikes" \
          "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-cuda.flaps" \
          "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-cuda.flaphold" 2>/dev/null || true
    rm -f "$LLM_BENCH_LOCK_FILE" "$LLAMA_WATCHDOG_CUDA_SUSPEND_FILE" 2>/dev/null || true
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
    [[ "$output" == *"Xe unit still loading (503)"* ]]
    [[ ! -f "$WATCHDOG_MOCK_STATE/restart_called" ]]

    # A second loading tick must not accrue the 2nd strike either.
    run "$WATCHDOG_SCRIPT"
    [[ "$status" -eq 0 ]]
    [[ ! -f "$WATCHDOG_MOCK_STATE/restart_called" ]]
    [[ "$(cat "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-xe.strikes" 2>/dev/null || echo 0)" == "0" ]]
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

@test "integration: watchdog skips the Xe lane when the bench lock is present" {
    echo "active" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "active" > "$WATCHDOG_MOCK_STATE/cuda_state"
    touch "$LLM_BENCH_LOCK_FILE"

    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Xe down but bench lock present"* ]]
    [[ ! -f "$WATCHDOG_MOCK_STATE/restart_called" ]]
}

@test "integration: CUDA suspend keeps the CUDA lane down while the GPU is free" {
    # The v3.5 suspend flag is the whole point: hold the CUDA lane down on a GPU
    # the probe reports FREE, because a bench is measuring TPS and wants the card.
    echo "active" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "inactive" > "$WATCHDOG_MOCK_STATE/cuda_state"
    touch "$LLAMA_WATCHDOG_CUDA_SUSPEND_FILE"

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
    touch "$LLAMA_WATCHDOG_CUDA_SUSPEND_FILE"

    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"CUDA lane suspended — stopping llama-cuda-llama32-3b-chat"* ]]
    grep -q "stop llama-cuda-llama32-3b-chat.service" "$SYSTEMCTL_MOCK_LOG"
    grep -qv "stop llama-xe-minicpm5-1b-chat.service" "$SYSTEMCTL_MOCK_LOG"
    [[ ! -f "$WATCHDOG_MOCK_STATE/restart_called" ]]
}

@test "integration: CUDA suspend does NOT suppress Xe recovery (unlike bench_lock)" {
    # bench_lock skips Xe restarts too; the CUDA-only flag must not, otherwise
    # suspending the CUDA lane would quietly disable Xe self-healing.
    echo "active" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "inactive" > "$WATCHDOG_MOCK_STATE/cuda_state"
    touch "$LLAMA_WATCHDOG_CUDA_SUSPEND_FILE"

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
    touch "$LLAMA_WATCHDOG_CUDA_SUSPEND_FILE"

    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$(cat "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-cuda.strikes")" == "0" ]]
}

@test "integration: watchdog skips the Xe lane while systemd is already activating" {
    echo "activating" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "active" > "$WATCHDOG_MOCK_STATE/cuda_state"
    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Xe unit activating"* ]]
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
    [[ "$output" -ge 3 ]]                       # defined once, called once per lane

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
    touch "$LLAMA_WATCHDOG_CUDA_SUSPEND_FILE"

    run "$WATCHDOG_SCRIPT"
    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"CUDA lane suspended"* ]]
    [[ "$output" != *"WARNING flap"* ]]
    [[ ! -e "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-cuda.flaps" ]]
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

# end of file
