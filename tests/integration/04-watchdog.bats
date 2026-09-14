#!/usr/bin/env bats
# ==============================================================================
# Integration Tests — Llama Watchdog (v3.5, dual-lane)
# ==============================================================================
# Tests llama-watchdog.sh v3.5: health probing (including the 503 "loading"
# signal), 2-strike recovery, the always-on Xe lane, the GPU-gated CUDA lane,
# and the v3.5 NV-only suspend flag. All external commands (curl, systemctl,
# gpu-busy.sh) are mocked so the suite is hermetic and never touches the live
# llama-server.service.
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
    export LLAMA_WATCHDOG_NV_SUSPEND_FILE="$TAC_TEST_TMPDIR/llama-watchdog-nv.suspend"
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

    # Mock systemctl --user. `show` reports per-unit state from xe_state/nv_state;
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
            *nvidia*) cat "$SYSTEMCTL_MOCK_STATE/nv_state" 2>/dev/null || echo "inactive" ;;
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
          "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-nv.strikes" 2>/dev/null || true
    rm -f "$LLM_BENCH_LOCK_FILE" "$LLAMA_WATCHDOG_NV_SUSPEND_FILE" 2>/dev/null || true
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
    echo "active" > "$WATCHDOG_MOCK_STATE/nv_state"

    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ ! -f "$WATCHDOG_MOCK_STATE/restart_called" ]]
}

@test "integration: watchdog restarts the Xe lane on the 2nd consecutive failure" {
    echo "active" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "active" > "$WATCHDOG_MOCK_STATE/nv_state"

    # First failure: strike 1, no restart yet.
    run "$WATCHDOG_SCRIPT"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"strike 1/2"* ]]
    [[ ! -f "$WATCHDOG_MOCK_STATE/restart_called" ]]

    # Second failure: strike 2, recovery via systemctl restart.
    run "$WATCHDOG_SCRIPT"
    [[ "$status" -eq 0 ]]
    [[ -f "$WATCHDOG_MOCK_STATE/restart_called" ]]
    grep -q "restart llama-server.service" "$SYSTEMCTL_MOCK_LOG"
    [[ "$output" == *"Recovery successful"* ]]
}

@test "integration: watchdog leaves a still-loading (503) Xe lane alone" {
    echo "active" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "active" > "$WATCHDOG_MOCK_STATE/nv_state"
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
    echo "active" > "$WATCHDOG_MOCK_STATE/nv_state"
    touch "$WATCHDOG_MOCK_STATE/loading"

    run "$WATCHDOG_SCRIPT"
    run "$WATCHDOG_SCRIPT"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"CUDA unit still loading (503)"* ]]
    [[ ! -f "$WATCHDOG_MOCK_STATE/restart_called" ]]
    [[ "$(cat "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-nv.strikes" 2>/dev/null || echo 0)" == "0" ]]
}

@test "integration: watchdog stops the CUDA lane while the GPU is busy" {
    echo "active" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "active" > "$WATCHDOG_MOCK_STATE/nv_state"
    touch "$WATCHDOG_MOCK_STATE/busy"

    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"GPU busy — stopping llama-server-nvidia"* ]]
    grep -q "stop llama-server-nvidia.service" "$SYSTEMCTL_MOCK_LOG"
    [[ ! -f "$WATCHDOG_MOCK_STATE/restart_called" ]]
}

@test "integration: a busy GPU is not misreported as a probe failure" {
    # gpu-busy.sh signals BUSY with exit 1 (the JSON goes to stdout). That is a
    # normal answer, so the watchdog must not log its probe-failure warning —
    # otherwise a held GPU spams the journal on every tick.
    echo "active" > "$WATCHDOG_MOCK_STATE/nv_state"
    touch "$WATCHDOG_MOCK_STATE/busy"

    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"GPU busy — stopping llama-server-nvidia"* ]]
    [[ "$output" != *"probe failed"* ]]
}

@test "integration: a gpu-busy probe error fails closed and warns" {
    # exit 2 is a real probe error: the GPU cannot be proven free, so it must be
    # treated as BUSY (CUDA lane stopped) and reported once.
    echo "active" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "active" > "$WATCHDOG_MOCK_STATE/nv_state"
    touch "$WATCHDOG_MOCK_STATE/gpu-probe-error"

    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"probe failed"* ]]
    [[ "$output" == *"GPU busy — stopping llama-server-nvidia"* ]]
    grep -q "stop llama-server-nvidia.service" "$SYSTEMCTL_MOCK_LOG"
}

@test "integration: watchdog skips the Xe lane when the bench lock is present" {
    echo "active" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "active" > "$WATCHDOG_MOCK_STATE/nv_state"
    touch "$LLM_BENCH_LOCK_FILE"

    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Xe down but bench lock present"* ]]
    [[ ! -f "$WATCHDOG_MOCK_STATE/restart_called" ]]
}

@test "integration: NV suspend keeps the CUDA lane down while the GPU is free" {
    # The v3.5 suspend flag is the whole point: hold the CUDA lane down on a GPU
    # the probe reports FREE, because a bench is measuring TPS and wants the card.
    echo "active" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "inactive" > "$WATCHDOG_MOCK_STATE/nv_state"
    touch "$LLAMA_WATCHDOG_NV_SUSPEND_FILE"

    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"CUDA lane suspended"* ]]
    [[ ! -f "$WATCHDOG_MOCK_STATE/start_called" ]]
    [[ ! -f "$WATCHDOG_MOCK_STATE/restart_called" ]]
}

@test "integration: NV suspend stops an active CUDA lane and leaves Xe alone" {
    touch "$WATCHDOG_MOCK_STATE/healthy"
    echo "active" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "active" > "$WATCHDOG_MOCK_STATE/nv_state"
    touch "$LLAMA_WATCHDOG_NV_SUSPEND_FILE"

    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"CUDA lane suspended — stopping llama-server-nvidia"* ]]
    grep -q "stop llama-server-nvidia.service" "$SYSTEMCTL_MOCK_LOG"
    grep -qv "stop llama-server.service" "$SYSTEMCTL_MOCK_LOG"
    [[ ! -f "$WATCHDOG_MOCK_STATE/restart_called" ]]
}

@test "integration: NV suspend does NOT suppress Xe recovery (unlike bench_lock)" {
    # bench_lock skips Xe restarts too; the NV-only flag must not, otherwise
    # suspending the CUDA lane would quietly disable Xe self-healing.
    echo "active" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "inactive" > "$WATCHDOG_MOCK_STATE/nv_state"
    touch "$LLAMA_WATCHDOG_NV_SUSPEND_FILE"

    run "$WATCHDOG_SCRIPT"
    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$output" != *"bench lock present"* ]]
    [[ -f "$WATCHDOG_MOCK_STATE/restart_called" ]]
    grep -q "restart llama-server.service" "$SYSTEMCTL_MOCK_LOG"
}

@test "integration: NV suspend resets CUDA strikes so a resumed lane starts clean" {
    echo "active" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "inactive" > "$WATCHDOG_MOCK_STATE/nv_state"
    printf '2\n' > "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-nv.strikes"
    touch "$LLAMA_WATCHDOG_NV_SUSPEND_FILE"

    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$(cat "$LLAMA_WATCHDOG_STRIKE_DIR/llama-watchdog-nv.strikes")" == "0" ]]
}

@test "integration: watchdog skips the Xe lane while systemd is already activating" {
    echo "activating" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "active" > "$WATCHDOG_MOCK_STATE/nv_state"
    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Xe unit activating"* ]]
    [[ ! -f "$WATCHDOG_MOCK_STATE/restart_called" ]]
}

@test "integration: watchdog skips the CUDA lane while systemd is already activating" {
    touch "$WATCHDOG_MOCK_STATE/healthy"
    echo "active" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "activating" > "$WATCHDOG_MOCK_STATE/nv_state"

    run "$WATCHDOG_SCRIPT"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"CUDA unit activating"* ]]
    # Must not start (or restart) a unit that systemd is mid-start on.
    [[ ! -f "$WATCHDOG_MOCK_STATE/start_called" ]]
    [[ ! -f "$WATCHDOG_MOCK_STATE/restart_called" ]]
}

@test "integration: watchdog resets a failed Xe unit before restarting" {
    echo "failed" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "active" > "$WATCHDOG_MOCK_STATE/nv_state"

    # First failure only strikes; reset-failed happens inside recovery (strike 2).
    run "$WATCHDOG_SCRIPT"
    [[ ! -f "$WATCHDOG_MOCK_STATE/reset_failed_called" ]]

    run "$WATCHDOG_SCRIPT"
    [[ "$status" -eq 0 ]]
    [[ -f "$WATCHDOG_MOCK_STATE/reset_failed_called" ]]
    [[ -f "$WATCHDOG_MOCK_STATE/restart_called" ]]
    grep -q "reset-failed llama-server.service" "$SYSTEMCTL_MOCK_LOG"
}

@test "integration: watchdog logs a failed recovery without a non-zero exit" {
    echo "active" > "$WATCHDOG_MOCK_STATE/xe_state"
    echo "active" > "$WATCHDOG_MOCK_STATE/nv_state"
    touch "$WATCHDOG_MOCK_STATE/fail_restart"
    touch "$WATCHDOG_MOCK_STATE/fail_start"

    run "$WATCHDOG_SCRIPT"
    run "$WATCHDOG_SCRIPT"

    # v3.0 always exits 0 (the user timer should not latch failed); a recovery
    # that cannot come up is reported on stdout instead.
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"recover failed for llama-server"* ]]
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

# end of file
