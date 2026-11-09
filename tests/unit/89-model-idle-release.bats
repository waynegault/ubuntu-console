#!/usr/bin/env bats
# ==============================================================================
# Unit - idle release for a `model use` lane (11e v104, bin/llm-idle-release.sh)
# ==============================================================================
# What has to stay true:
#
#   1. ACTIVITY IS THE COUNTERS, NOT THE LOG.  llama-server's own
#      `llamacpp:prompt_tokens_total` (counter) and `llamacpp:requests_processing`
#      (gauge) decide whether the lane is quiet.  A silent lane is released; a lane
#      that served a request during the window, or has one in flight at the
#      deadline, is not.
#   2. THE RELEASE RUNS THE CONSOLE'S OWN STOP PATH (`tac-exec halt`).  It does not
#      signal llama-server: that would leave the active-model pointer and the CUDA
#      card mark behind (the silent-state shape this repo bans).
#   3. THE MONITOR IS FINDABLE AND ENDABLE.  It publishes its pid before the first
#      probe and removes it on exit; `model stop` ends it with the lane it watches.
#      A pid record whose process is not this monitor is discarded, not signalled.
#   4. OFF UNLESS ASKED.  No flag, timeout 0 and bench mode all start nothing.
#
# Hermetic: a python HTTP fixture serves the exposition body from a file the test
# rewrites, and a stub `tac-exec` records the halt instead of stopping anything.
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
SCRIPT="$REPO_ROOT/bin/llm-idle-release.sh"
LAUNCHER="$REPO_ROOT/scripts/11e-llm-model.sh"

setup_file() {
    export SANDBOX
    SANDBOX="$(mktemp -d)"

    cat > "$SANDBOX/metrics.py" <<'PY'
import http.server, socketserver, sys
state = sys.argv[2]

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/metrics":
            self.send_error(404)
            return
        try:
            with open(state, "rb") as handle:
                body = handle.read()
        except OSError:
            self.send_error(503)
            return
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass

socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", int(sys.argv[1])), Handler) as server:
    server.serve_forever()
PY

    cat > "$SANDBOX/tac-exec" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SANDBOX/halt-args"
printf 'halted\n' >> "$SANDBOX/halt-called"
exit 0
SH
    chmod +x "$SANDBOX/tac-exec"

    cat > "$SANDBOX/fake-monitor.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$SANDBOX/monitor-args"
exit 0
SH
    chmod +x "$SANDBOX/fake-monitor.sh"
}

teardown_file() {
    rm -rf "${SANDBOX:-/tmp/bats-noop}"
}

setup() {
    export BODY="$SANDBOX/metrics.body"
    export LOG="$SANDBOX/monitor.log"
    export PIDFILE="$SANDBOX/monitor.pid"
    rm -f "$BODY" "$LOG" "$PIDFILE" "$SANDBOX/halt-called" "$SANDBOX/halt-args" \
          "$SANDBOX/monitor-args"
    SERVER_PID=""
    MON_PID=""
    OTHER_PID=""
    printf 'llamacpp:prompt_tokens_total 100\nllamacpp:requests_processing 0\n' > "$BODY"
}

teardown() {
    # A killed process's `wait` returns 128+signal, which bats reads as a failed
    # teardown; the `:` makes the cleanup's own status the last word.
    if [[ -n "${MON_PID:-}" ]]; then
        kill "$MON_PID" 2>/dev/null
        wait "$MON_PID" 2>/dev/null
        :
    fi
    if [[ -n "${SERVER_PID:-}" ]]; then
        kill "$SERVER_PID" 2>/dev/null
        wait "$SERVER_PID" 2>/dev/null
        :
    fi
    if [[ -n "${OTHER_PID:-}" ]]; then
        kill "$OTHER_PID" 2>/dev/null
        wait "$OTHER_PID" 2>/dev/null
        :
    fi
}

_free_port() {
    python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

_wait_for() {
    local _file="$1" _secs="${2:-10}" _i
    for (( _i=0; _i < _secs * 10; _i++ ))
    do
        [[ -e "$_file" ]] && return 0
        sleep 0.1
    done
    return 1
}

# _serve - the fixture server for one case, on its own port.
_serve() {
    PORT="$(_free_port)"
    python3 "$SANDBOX/metrics.py" "$PORT" "$BODY" &
    SERVER_PID=$!
    local _i
    for (( _i=0; _i < 50; _i++ ))
    do
        curl -s --max-time 1 "http://127.0.0.1:$PORT/metrics" >/dev/null 2>&1 && return 0
        sleep 0.1
    done
    return 1
}

# _watch <timeout> [extra args...]
_watch() {
    local _timeout="$1"
    shift
    "$SCRIPT" --port "$PORT" --timeout "$_timeout" --poll 1 --log "$LOG" \
        --pid-file "$PIDFILE" --exec-cmd "$SANDBOX/tac-exec" "$@" &
    MON_PID=$!
}

# ---------------------------------------------------------------- the monitor
@test "idle release: a silent lane is released through tac-exec halt" {
    _serve || skip "fixture server did not start"

    _watch 2
    _wait_for "$SANDBOX/halt-called" 10 || { echo "the lane was not released"; cat "$LOG"; return 1; }

    [[ "$(< "$SANDBOX/halt-args")" == "halt" ]] \
        || { echo "the stop path was not 'tac-exec halt'"; return 1; }
    # The pid record must not outlive the monitor; a stale record is what makes a
    # later `model stop` signal a recycled pid.
    [[ ! -f "$PIDFILE" ]] || { echo "the pid file survived the release"; return 1; }
    grep -q 'idle' "$LOG" || { echo "the release was not logged"; return 1; }
}

@test "idle release: a request during the window postpones the release" {
    _serve || skip "fixture server did not start"

    # The first probe (at ~1 s) must see the BASELINE, so the first bump waits for
    # it.  A bump before the baseline would simply become the baseline.
    _watch 3
    sleep 2
    printf 'llamacpp:prompt_tokens_total 200\nllamacpp:requests_processing 0\n' > "$BODY"
    sleep 2
    printf 'llamacpp:prompt_tokens_total 300\nllamacpp:requests_processing 0\n' > "$BODY"
    sleep 1

    [[ ! -f "$SANDBOX/halt-called" ]] \
        || { echo "the lane was released although it served requests"; cat "$LOG"; return 1; }
    kill -0 "$MON_PID" 2>/dev/null || { echo "the monitor exited early"; cat "$LOG"; return 1; }
}

@test "idle release: an in-flight request holds the lane past the deadline" {
    _serve || skip "fixture server did not start"
    printf 'llamacpp:prompt_tokens_total 100\nllamacpp:requests_processing 1\n' > "$BODY"

    _watch 1
    sleep 3

    [[ ! -f "$SANDBOX/halt-called" ]] \
        || { echo "a lane with a request in flight was released"; cat "$LOG"; return 1; }
    kill -0 "$MON_PID" 2>/dev/null || { echo "the monitor exited early"; cat "$LOG"; return 1; }
}

@test "idle release: an unreachable metrics endpoint is not idleness" {
    PORT="$(_free_port)"

    _watch 1
    local _rc=0
    wait "$MON_PID" || _rc=$?
    MON_PID=""

    [[ "$_rc" -eq 0 ]] || { echo "the monitor exited $_rc on an unreachable endpoint"; return 1; }
    [[ ! -f "$SANDBOX/halt-called" ]] || { echo "an unreachable probe stopped the lane"; return 1; }
    grep -q 'stopped answering' "$LOG" || { echo "the reason was not logged"; cat "$LOG"; return 1; }
}

@test "idle release: timeout 0 disables the monitor without writing a pid" {
    run "$SCRIPT" --port 1 --timeout 0 --pid-file "$PIDFILE" --exec-cmd "$SANDBOX/tac-exec"
    [[ "$status" -eq 0 ]]
    [[ ! -f "$PIDFILE" ]]
}

@test "idle release: a missing stop command refuses instead of watching" {
    run "$SCRIPT" --port 1 --timeout 5 --pid-file "$PIDFILE" \
        --exec-cmd "$SANDBOX/no-such-command"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"refusing to watch"* ]]
    [[ ! -f "$PIDFILE" ]]
}

@test "idle release: a bad invocation exits 2, a refusal exits 1" {
    run "$SCRIPT" --port not-a-number --timeout 5
    [[ "$status" -eq 2 ]]
    run "$SCRIPT" --port 1 --timeout 5 --poll 0
    [[ "$status" -eq 2 ]]
}

# --------------------------------------------------- the launcher's two helpers
# __model_idle_release_stop is extracted VERBATIM and run with private stubs, so
# the assertions are about the shipped text rather than a paraphrase.
_stop_harness() {
    awk '/^function __model_idle_release_stop\(\)/,/^}/' "$LAUNCHER" > "$SANDBOX/stop-fn.sh"
    grep -q 'llm-idle-release.sh' "$SANDBOX/stop-fn.sh" \
        || { echo "FAIL: stop helper not extracted"; return 1; }
    cat > "$SANDBOX/stop-harness.sh" <<'SH'
set -uo pipefail
__tac_info() { :; }
C_Dim=""
export LLM_IDLE_PID_FILE="$PIDFILE"
source "$1"
__model_idle_release_stop
SH
    bash "$SANDBOX/stop-harness.sh" "$SANDBOX/stop-fn.sh"
}

@test "model stop: the monitor is ended by a pid record that names it" {
    # argv[0] carries the monitor's file name, which is what the helper matches; the
    # process itself is `sleep`, so a TERM ends it at once (a bash waiting on a
    # foreground child defers its own TERM until that child exits).
    bash -c 'exec -a llm-idle-release.sh sleep 300' &
    MON_PID=$!
    printf '%s\n' "$MON_PID" > "$PIDFILE"

    _stop_harness || return 1
    local _i
    for (( _i=0; _i < 30; _i++ ))
    do
        kill -0 "$MON_PID" 2>/dev/null || break
        sleep 0.1
    done

    kill -0 "$MON_PID" 2>/dev/null && { echo "the monitor survived the stop"; return 1; }
    MON_PID=""
    [[ ! -f "$PIDFILE" ]] || { echo "the pid record survived the stop"; return 1; }
}

@test "model stop: a pid record for another program is discarded, not signalled" {
    sleep 300 &
    OTHER_PID=$!
    printf '%s\n' "$OTHER_PID" > "$PIDFILE"

    _stop_harness || return 1
    sleep 0.3

    kill -0 "$OTHER_PID" 2>/dev/null \
        || { echo "an unrelated process was signalled from a stale pid file"; return 1; }
    [[ ! -f "$PIDFILE" ]]
}

@test "model use: the monitor starts only when a positive timeout is asked for" {
    awk '/^function __model_use_start_idle_release\(\)/,/^}/' "$LAUNCHER" \
        > "$SANDBOX/start-fn.sh"
    grep -q 'LLM_IDLE_RELEASE_BIN' "$SANDBOX/start-fn.sh" \
        || { echo "FAIL: start helper not extracted"; return 1; }

    cat > "$SANDBOX/start-harness.sh" <<'SH'
set -uo pipefail
__tac_info() { printf '%s\n' "$2"; }
C_Dim=""
C_Warning=""
source "$1"
LLM_PORT=19999
LLM_LOG_FILE="$SANDBOX/start.log"
LLM_IDLE_PID_FILE="$SANDBOX/start.pid"
LLM_IDLE_RELEASE_BIN="$SANDBOX/fake-monitor.sh"
__model_use_start_idle_release "$2"
SH

    # Zero and non-numeric both start nothing.
    run bash "$SANDBOX/start-harness.sh" "$SANDBOX/start-fn.sh" 0
    [[ "$status" -eq 0 ]]
    [[ ! -f "$SANDBOX/monitor-args" ]]

    run bash "$SANDBOX/start-harness.sh" "$SANDBOX/start-fn.sh" soon
    [[ "$status" -eq 0 ]]
    [[ ! -f "$SANDBOX/monitor-args" ]]

    # A positive value starts the monitor with the lane's port and window.
    run bash "$SANDBOX/start-harness.sh" "$SANDBOX/start-fn.sh" 30
    _wait_for "$SANDBOX/monitor-args" 5 || { echo "the monitor was not started"; return 1; }
    grep -q -- '--port 19999' "$SANDBOX/monitor-args"
    grep -q -- '--timeout 30' "$SANDBOX/monitor-args"
    [[ "$output" == *"30s with no requests"* ]]
}

@test "model use: bench mode starts no monitor even with a timeout set" {
    awk '/^function __model_use_start_idle_release\(\)/,/^}/' "$LAUNCHER" \
        > "$SANDBOX/start-fn.sh"

    cat > "$SANDBOX/bench-harness.sh" <<'SH'
set -uo pipefail
__tac_info() { printf '%s\n' "$2"; }
C_Dim=""
C_Warning=""
source "$1"
__BENCH_MODE=1
LLM_PORT=19999
LLM_LOG_FILE="$SANDBOX/start.log"
LLM_IDLE_PID_FILE="$SANDBOX/start.pid"
LLM_IDLE_RELEASE_BIN="$SANDBOX/fake-monitor.sh"
__model_use_start_idle_release "$2"
SH

    run bash "$SANDBOX/bench-harness.sh" "$SANDBOX/start-fn.sh" 30
    [[ "$status" -eq 0 ]]
    [[ ! -f "$SANDBOX/monitor-args" ]]
}

@test "model use: a requested monitor that cannot start is reported, not hidden" {
    awk '/^function __model_use_start_idle_release\(\)/,/^}/' "$LAUNCHER" \
        > "$SANDBOX/start-fn.sh"

    cat > "$SANDBOX/missing-harness.sh" <<'SH'
set -uo pipefail
__tac_info() { printf '%s\n' "$2"; }
C_Dim=""
C_Warning=""
source "$1"
LLM_PORT=19999
LLM_LOG_FILE="$SANDBOX/start.log"
LLM_IDLE_PID_FILE="$SANDBOX/start.pid"
LLM_IDLE_RELEASE_BIN="$SANDBOX/not-executable"
__model_use_start_idle_release "$2"
SH

    run bash "$SANDBOX/missing-harness.sh" "$SANDBOX/start-fn.sh" 30
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"will NOT be released"* ]]
}

# ------------------------------------------------------------- wiring checks
@test "wiring: the dispatcher parses --idle-timeout and exports it" {
    grep -q -- '--idle-timeout|--idle' "$LAUNCHER" \
        || { echo "model use does not accept --idle-timeout"; return 1; }
    grep -q 'export TAC_IDLE_TIMEOUT=' "$LAUNCHER" \
        || { echo "model use does not pass the window to the launcher"; return 1; }
    grep -q '__model_use_start_idle_release "$_idle_timeout_requested"' "$LAUNCHER" \
        || { echo "the launcher never starts the monitor"; return 1; }
    grep -q 'unset TAC_IDLE_TIMEOUT' "$LAUNCHER" \
        || { echo "the window is not consumed once at launch"; return 1; }
}

@test "wiring: model stop ends the monitor before it stops the lane" {
    awk '/^function __model_stop\(\)/,/^}/' "$LAUNCHER" > "$SANDBOX/stop-body.sh"
    # The first executable line matters: a stop that killed llama-server first would
    # leave a monitor polling a dead port and then acting on it.
    local _first
    _first=$(grep -vE '^\s*(#|$)' "$SANDBOX/stop-body.sh" | sed -n '2p')
    [[ "$_first" == *"__model_idle_release_stop"* ]] \
        || { echo "model stop does not end the monitor first: '$_first'"; return 1; }
}

@test "wiring: serve passes --idle-timeout through to model use" {
    grep -q -- '--idle-timeout|--idle' "$REPO_ROOT/scripts/11f-llm-runtime.sh" \
        || { echo "serve does not accept --idle-timeout"; return 1; }
    grep -q 'export TAC_IDLE_TIMEOUT=' "$REPO_ROOT/scripts/11f-llm-runtime.sh" \
        || { echo "serve does not export the window"; return 1; }
}

# end of file
