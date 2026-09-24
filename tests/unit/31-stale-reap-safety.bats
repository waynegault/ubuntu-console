#!/usr/bin/env bats
# ==============================================================================
# Unit — [17/20] Stale Processes: the reap fails CLOSED
# ==============================================================================
# WHY THIS EXISTS (2026-09-24): `__up_stale_processes` kills processes, and the ONE
# thing that separates a live model from an orphan is `pid == _port_owner` — the pid
# that owns the LLM_PORT listener.  Both probes that produce it (ss, then the kernel's
# /proc/net/tcp) swallowed their failures, so "nobody is listening" and "we could not
# tell" were the same empty string: an unresolvable port silently removed the
# protection from EVERY candidate.  The function's own header records what that cost
# last time — a per-fd grep that never matched, and the live user-launched server it
# reaped.
#
# The step also had no test at all before this file, which is why the safety rests on
# assertions now: every case runs the REAL step and then checks that the fixture
# process is still alive, because "it did not print a kill row" is not the property
# that matters.
#
# HERMETIC: HOME and every path the step touches are sandboxed, the process list it
# reaps is stubbed, and the tools whose failure is under test are stubbed on PATH.
# Nothing here can reach a real llama-server.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export REPO_ROOT
    SANDBOX="$(mktemp -d)"
    export SANDBOX
    export HOME="$SANDBOX/home"
    export TAC_TEST_TMPDIR="$SANDBOX/tac"
    export TAC_CACHE_DIR="$SANDBOX/cache"
    mkdir -p "$HOME" "$TAC_TEST_TMPDIR" "$TAC_CACHE_DIR" "$SANDBOX/bin"

    # shellcheck source=env.sh
    source "$REPO_ROOT/env.sh"

    # Stubs AFTER the source: a loader re-defines the real functions on top of anything
    # stubbed earlier.  __tac_line is flattened so the assertions can match the status
    # words without colour codes.
    __tac_line() { printf 'LINE %s\n' "$*"; }
    __tac_info() { printf 'INFO %s\n' "$*"; }

    # The step's inputs, sandboxed after the source so 01-constants.sh cannot win.
    export LLM_PORT=18099
    export ACTIVE_LLM_FILE="$SANDBOX/llm-active"
    export ErrorLogPath="$SANDBOX/err.log"

    # The "orphan" every case is about: a real process, so the assertions can ask the
    # kernel whether it survived.  `__llm_server_pids` is stubbed to name it — the real
    # one greps the process table for llama-server.
    sleep 120 &
    FIXTURE_PID=$!
    export FIXTURE_PID
    __llm_server_pids() { printf '%s\n' "$FIXTURE_PID"; }

    # A headless box for the systemd protect-list probe: no unit has a MainPID here,
    # which is the normal case on a machine without the llama units running.
    systemctl() { return 1; }
}

teardown() {
    kill "$FIXTURE_PID" 2>/dev/null || true
    cd /
    rm -rf "$SANDBOX"
}

# _stub <name> <script> — put a stub on PATH and prepend the directory to PATH.
_stub() {
    local _name="$1" _body="$2"
    printf '%s\n' "$_body" > "$SANDBOX/bin/$_name"
    chmod +x "$SANDBOX/bin/$_name"
    export PATH="$SANDBOX/bin:$PATH"
}

# _run_step — call the real step, capture its rows, and leave errCount in $_err.
_run_step() {
    _err=0
    __up_stale_processes "$(date +%s)" 1 _err > "$SANDBOX/out.txt" 2>&1 < /dev/null
}

# _fixture_alive — the property every case asserts: the process the step could not
# prove was an orphan is still running.
_fixture_alive() {
    kill -0 "$FIXTURE_PID" 2>/dev/null
}

@test "stale reap: an unresolvable LLM_PORT listener skips the reap, and says why" {
    _stub ss '#!/usr/bin/env bash
exit 1'
    # awk is what parses the kernel's table, so a failing awk makes BOTH sources
    # unavailable — the state the old code could not tell from "nothing is listening".
    _stub awk '#!/usr/bin/env bash
exit 1'

    _run_step

    run cat "$SANDBOX/out.txt"
    [[ "$output" == *"LINE [17/20] Stale Processes [SKIP - cannot resolve the LLM_PORT listener]"* ]]
    [[ "$output" != *"ORPHAN(S) KILLED"* ]]
    # The property, not the row: the only process it could have killed is still here.
    run _fixture_alive
    [ "$status" -eq 0 ]
}

@test "stale reap: a listener that names its pid is protected from the reap" {
    # The shape `ss` really prints, so the step's own parser is exercised rather than a
    # paraphrase of it: only the pid=N token matters to that parser.
    _stub ss "#!/usr/bin/env bash
printf 'LISTEN 0 128 127.0.0.1:$LLM_PORT 0.0.0.0:* users:((\"sleep\",pid=$FIXTURE_PID,fd=3))\n'"

    _run_step

    run cat "$SANDBOX/out.txt"
    [[ "$output" == *"[CLEAN]"* ]]
    [[ "$output" != *"ORPHAN(S) KILLED"* ]]
    run _fixture_alive
    [ "$status" -eq 0 ]
}

@test "stale reap: a listener with a pid we cannot read is NOT taken for no listener" {
    # ss answered, so the /proc fallback must not "correct" it downwards.  This is the
    # exact confusion the fail-closed guard exists for, and it is why the port probe's
    # answer is a separate flag rather than an empty string.
    _stub ss "#!/usr/bin/env bash
printf 'LISTEN 0 128 127.0.0.1:$LLM_PORT 0.0.0.0:*\n'"

    _run_step

    run cat "$SANDBOX/out.txt"
    [[ "$output" != *"ORPHAN(S) KILLED"* ]]
    run _fixture_alive
    [ "$status" -eq 0 ]
}

@test "stale reap: an unreadable active-model marker skips the reap too" {
    # The boot guard's own fail-closed half: an mtime we cannot read cannot tell a
    # BOOTING model from an old one, and the reap must not run on that guess either.
    printf 'x\n' > "$ACTIVE_LLM_FILE"
    _stub stat '#!/usr/bin/env bash
exit 1'

    _run_step

    run cat "$SANDBOX/out.txt"
    [[ "$output" == *"LINE [17/20] Stale Processes [SKIP - cannot read llm-active]"* ]]
    run _fixture_alive
    [ "$status" -eq 0 ]
}

@test "stale reap: with no listener at all, a non-listening fixture IS reaped" {
    # The other side of the guard: an answered probe that finds no listener leaves every
    # candidate an orphan, so the step still does its job — a fail-closed change that
    # also made the step inert would be a different bug.
    _stub ss '#!/usr/bin/env bash
printf ""'

    _run_step

    run cat "$SANDBOX/out.txt"
    [[ "$output" == *"ORPHAN(S) KILLED"* ]]
    run _fixture_alive
    [ "$status" -ne 0 ]
}
