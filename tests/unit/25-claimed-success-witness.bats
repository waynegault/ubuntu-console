#!/usr/bin/env bats
# ==============================================================================
# Unit — CLAIMED-SUCCESS-WITNESS-001: the read-back witnesses, the stale-cache
#        marker at the surface, and the injected-failure cases that make both real.
# ==============================================================================
# Three things this file proves, none of which was previously provable:
#
#   1. `model use` cannot print "ONLINE" for an active-model state it did not
#      record, and `model stop` cannot print "[STOPPED]" for a server that is still
#      running or a port that is still bound (item 1 — the read-back witnesses).
#      The witnesses themselves are exercised for real; the end-to-end cases drive
#      the shipped functions with the effect INJECTED as failed (the state file
#      removed, the port held by a listener, the server never answering).
#   2. A cached value that the dashboard renders as current says so when it is not
#      (item 2): the age marker is produced by the real render, not just by the
#      helper.
#   3. tools/check-contracts.sh verifies the AUTHORED witnesses (item 1's contract
#      half) — a missing file, a symbol that is not a function there, or a witness
#      nothing calls all fail; an exemption must carry a reason.
#
# Hermetic: every case stubs the killers and the card probes and points the state
# files at $BATS_TEST_TMPDIR.  Two deliberate exceptions, both read-only: the real
# `ss` (so "is the port bound?" is a fact about the box, not a stub) and — in the
# render case — the real module code, with every getter that would query the live
# box replaced by a stub.  The one thing this file must never do is kill a
# process: `__llm_server_stop` would take the LIVE fleet lanes (:18081/:18083/
# :18084/:18085) with it, which is why it is stubbed in every case below.
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
CHECKER="$REPO_ROOT/tools/check-contracts.sh"

setup_file() {
    export SANDBOX
    SANDBOX="$(mktemp -d)"

    # A real listener, so "the port is bound" needs no mock.  Bound only in the
    # cases that ask for it; killed in teardown.
    cat > "$SANDBOX/listen.py" <<'PY'
import socket, sys, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1])))
s.listen(1)
time.sleep(60)
PY
}

teardown_file() {
    rm -rf "${SANDBOX:-/tmp/bats-noop}"
}

setup() {
    mkdir -p "$SANDBOX/state"
    export TAC_CACHE_DIR="$SANDBOX/state"
    export ACTIVE_LLM_FILE="$SANDBOX/state/active_llm"
    export LLM_TPS_CACHE="$SANDBOX/state/last_tps"
    export LLM_LOG_FILE="$SANDBOX/state/llama-server.log"
    export LLM_KEEPER_DIR="$SANDBOX/state/keepers"
    export LLM_BENCH_LOCK_FILE="$SANDBOX/state/llm-bench.lock"
    export LLM_AUTOTUNE_LOCK_FILE="$SANDBOX/state/llm-autotune.lock"
    export LLAMA_WATCHDOG_CUDA_SUSPEND_FILE="$SANDBOX/state/cuda.suspend"
    export LLM_PORT="$(_free_port)"
    rm -f "$ACTIVE_LLM_FILE" "$LLM_TPS_CACHE" "$SANDBOX/state/gpu_check.json" 2>/dev/null || true
    LISTENER_PID=""
}

teardown() {
    [[ -n "${LISTENER_PID:-}" ]] && kill "$LISTENER_PID" 2>/dev/null || true
    rm -f "$SANDBOX/state/active_llm" "$SANDBOX/state/last_tps" 2>/dev/null || true
}

# _free_port — an ephemeral port nothing is listening on right now.
_free_port() {
    python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

# _bind_port <port> — hold a real listening socket for the life of one case.
_bind_port() {
    python3 "$SANDBOX/listen.py" "$1" &
    LISTENER_PID=$!
    local _i
    for _i in $(seq 1 40); do
        ss -tln "sport = :$1" 2>/dev/null | grep -q LISTEN && return 0
        sleep 0.1
    done
    return 1
}

# _load_console — source the module set the functions under test come from.  The
# include guards make this idempotent, and nothing in these modules runs at source
# time (13-init, the one module with side effects, is deliberately not loaded).
_load_console() {
    source "$REPO_ROOT/scripts/01-constants.sh"
    source "$REPO_ROOT/scripts/03-design-tokens.sh"
    source "$REPO_ROOT/scripts/05-ui-engine.sh"
    source "$REPO_ROOT/scripts/06-hooks.sh"
    source "$REPO_ROOT/scripts/07-telemetry.sh"
    source "$REPO_ROOT/scripts/11a-llm-registry.sh"
    source "$REPO_ROOT/scripts/11b-llm-autotune.sh"
    source "$REPO_ROOT/scripts/11c-llm-server.sh"
    source "$REPO_ROOT/scripts/11d-llm-gpu.sh"
    source "$REPO_ROOT/scripts/11e-llm-model.sh"
    source "$REPO_ROOT/scripts/12-dashboard-help.sh"
}

# _stub_killers — remove every path in these functions that could touch the live
# box: the process killer, the GPU probe, the registry sync and `oc`.
_stub_killers() {
    __llm_server_stop() { :; }
    __resolve_smi() { return 1; }
    __llm_registry_sync_state() { :; }
    oc() { :; }
}

# _no_backends / _a_backend_alive — the "is a llama backend running?" half of the
# stop witness.  Overridden rather than stubbed with a real process: the real scan
# (__llm_server_pids by /proc/PID/exe) sees this box's LIVE lanes, so a real scan
# would report "not gone" in every case.  That scan has its own suite
# (tests/unit/12-gpu-exclusivity.bats); what is under test here is the composition.
_no_backends() { __llm_server_running() { return 1; }; }
_a_backend_alive() { __llm_server_running() { return 0; }; }

# ── item 1: the witnesses themselves ───────────────────────────────────────
@test "read-back: __llm_active_state_recorded accepts only the model this launch recorded" {
    _load_console
    local _status

    # Nothing recorded (the write never landed / the file was removed).
    _status=0
    __llm_active_state_recorded "model-a.gguf" || _status=$?
    [[ "$_status" -ne 0 ]]

    # A STALE pointer from a previous model: "the file exists" is not the claim.
    _status=0
    printf 'model-b.gguf\n' > "$ACTIVE_LLM_FILE"
    __llm_active_state_recorded "model-a.gguf" || _status=$?
    [[ "$_status" -ne 0 ]]

    # An empty pointer is not a record either.
    _status=0
    : > "$ACTIVE_LLM_FILE"
    __llm_active_state_recorded "" && return 1
    __llm_active_state_recorded "model-a.gguf" || _status=$?
    [[ "$_status" -ne 0 ]]

    # ...and the recorded model is accepted.
    printf 'model-a.gguf\n' > "$ACTIVE_LLM_FILE"
    __llm_active_state_recorded "model-a.gguf"
}

@test "read-back: a write that cannot land leaves the witness failing" {
    _load_console
    # The injected failure item 3 asks for: the state directory cannot be written.
    local ro="$SANDBOX/readonly"
    mkdir -p "$ro"
    chmod 500 "$ro"
    export ACTIVE_LLM_FILE="$ro/active_llm"

    run bash -c 'echo "model-a.gguf" > "${ACTIVE_LLM_FILE}.tmp" 2>&1'
    [[ "$status" -ne 0 ]] || { chmod 700 "$ro"; return 1; }

    __llm_active_state_recorded "model-a.gguf" && return 1
    chmod 700 "$ro"
    return 0
}

@test "read-back: __llm_server_gone needs BOTH halves gone" {
    _load_console
    # _status is reset before EVERY sub-case: carrying a previous failure into the
    # next assertion is how a guard "passes" for the wrong reason (found by mutating
    # __llm_server_gone: the backend half could be deleted with this case still
    # green, because the port case had already left _status non-zero).
    local _status

    _no_backends
    _status=0
    __llm_server_gone || _status=$?
    [[ "$_status" -eq 0 ]] || { echo "no backend, port free: expected gone"; return 1; }

    _bind_port "$LLM_PORT" || skip "could not bind $LLM_PORT in this environment"
    _status=0
    __llm_server_gone || _status=$?
    [[ "$_status" -ne 0 ]] || { echo "port still bound: must not report gone"; return 1; }
    kill "$LISTENER_PID" 2>/dev/null || true
    LISTENER_PID=""

    _a_backend_alive
    _status=0
    __llm_server_gone || _status=$?
    [[ "$_status" -ne 0 ]] || { echo "backend alive with a free port: must not report gone"; return 1; }
}

# ── item 3: the CLI reports FAILURE, not success ───────────────────────────
@test "model stop: a port still served after the teardown is FAILURE, not STOPPED" {
    # A guard, not a nicety: the function also reaps /tmp/llm-modelshell.*.pid
    # trees, and one may belong to a live `model use` session that this suite must
    # not stop.
    compgen -G "/tmp/llm-modelshell.*.pid" >/dev/null && skip "a live model-use session exists"
    _load_console
    _stub_killers
    _no_backends
    _bind_port "$LLM_PORT" || skip "could not bind $LLM_PORT in this environment"

    run __model_stop

    [[ "$status" -ne 0 ]] || { echo "a stop that did not stop exited 0"; return 1; }
    [[ "$output" == *"[FAILED: a llama backend is still running or port $LLM_PORT is still bound"* ]]
    [[ "$output" != *"[STOPPED]"* ]]
}

@test "model stop: a surviving backend is FAILURE even with the port free" {
    compgen -G "/tmp/llm-modelshell.*.pid" >/dev/null && skip "a live model-use session exists"
    _load_console
    _stub_killers
    _a_backend_alive

    run __model_stop

    [[ "$status" -ne 0 ]]
    [[ "$output" == *"[FAILED: a llama backend is still running"* ]]
    [[ "$output" != *"[STOPPED]"* ]]
}

@test "model stop: a stop that really landed still reports STOPPED" {
    # The other half of the guard: a witness that always fails is not a witness.
    compgen -G "/tmp/llm-modelshell.*.pid" >/dev/null && skip "a live model-use session exists"
    _load_console
    _stub_killers
    _no_backends

    run __model_stop

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"[STOPPED]"* ]]
    [[ "$output" != *"[FAILED:"* ]]
}

@test "model use: the state missing at the success line is FAILURE, not ONLINE" {
    _load_console
    _stub_killers
    # The server answers (health stubbed OK) and the pointer is GONE — the shape the
    # old code called success.
    __llm_wait_for_health() { return 0; }
    local size="1.0G" gpu_layers=99 name="Fixture-1B" num=1 ctx=2048 file="fixture.gguf"

    run __model_use_wait_healthy

    [[ "$status" -ne 0 ]] || { echo "ONLINE-shaped success with no recorded state"; return 1; }
    [[ "$output" == *"refusing to report ONLINE"* ]]
    [[ "$output" != *"ONLINE [Port"* ]]
}

@test "model use: the recorded state makes ONLINE honest" {
    _load_console
    _stub_killers
    __llm_wait_for_health() { return 0; }
    local size="1.0G" gpu_layers=99 name="Fixture-1B" num=1 ctx=2048 file="fixture.gguf"
    printf '%s\n' "$file" > "$ACTIVE_LLM_FILE"

    run __model_use_wait_healthy

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"ONLINE [Port $LLM_PORT]"* ]]
}

@test "model use: a server that never answers is FAILURE (the killed-server case)" {
    _load_console
    _stub_killers
    __llm_wait_for_health() { return 1; }
    local size="1.0G" gpu_layers=99 name="Fixture-1B" num=1 ctx=2048 file="fixture.gguf"
    printf '%s\n' "$file" > "$ACTIVE_LLM_FILE"

    run __model_use_wait_healthy

    [[ "$status" -ne 0 ]]
    [[ "$output" == *"FAILED OR TIMEOUT"* ]]
    [[ "$output" != *"ONLINE [Port"* ]]
    # A failed launch must not leave the pointer behind for the next reader.
    [[ ! -f "$ACTIVE_LLM_FILE" ]]
}

@test "model use: the launcher consults the witness and returns non-zero on failure" {
    # Static, and deliberately so: running __model_use_launch_server spawns a
    # server subshell and writes /tmp/llm-modelshell.<pid>.pid, which is a live path
    # this suite does not own.  The functional half of the launcher's witness is the
    # two cases above (the state that is missing at the success line), and the
    # witness's own semantics are covered by the first three cases.
    awk '/^function __model_use_launch_server/,/^}/' "$REPO_ROOT/scripts/11e-llm-model.sh" \
        > "$SANDBOX/launcher.sh"
    grep -q '__llm_active_state_recorded "$file"' "$SANDBOX/launcher.sh" \
        || { echo "the launcher does not read its own write back"; return 1; }
    grep -q 'return 1' "$SANDBOX/launcher.sh" \
        || { echo "the launcher's read-back does not fail the launch"; return 1; }
    # ...and the caller propagates it, or a non-zero launch would be ignored and the
    # command would carry on to the health wait.
    grep -q '__model_use_launch_server || return 1' "$REPO_ROOT/scripts/11e-llm-model.sh"
}

# ── item 2: the surface says when a cached value is stale ──────────────────
@test "stale: __cache_age_suffix is silent while fresh and names the age past the bound" {
    _load_console
    local out

    printf '42\n' > "$LLM_TPS_CACHE"
    out=$(__cache_age_suffix "$LLM_TPS_CACHE" 3600)
    [[ -z "$out" ]] || { echo "a fresh value was marked: '$out'"; return 1; }

    touch -d '2 hours ago' "$LLM_TPS_CACHE"
    out=$(__cache_age_suffix "$LLM_TPS_CACHE" 3600)
    [[ "$out" == *"STALE"* ]]
    # A WINDOW, not the exact figure: `touch` stamps the mtime 7200 s before ITS clock
    # read, and the helper reads the clock again a moment later, so the printed age is
    # 7200 or 7201 depending on which side of a second boundary the two reads land.
    # Pinning "7200" made this case fail in CI (run 36068774956, case 184) with
    # "(cached 7201s ago — STALE)" — a flake, not a defect.  The window is wide enough
    # for that drift and still catches a wrong unit or a missing figure.
    [[ "$out" =~ cached\ 720[0-3]s\ ago ]] || { echo "the age is missing or wrong in '$out'"; return 1; }

    # A missing cache renders as missing, not as a stale value.
    out=$(__cache_age_suffix "$SANDBOX/state/nothing-here" 60)
    [[ -z "$out" ]]

    # A bad bound must not produce a marker with no meaning.
    out=$(__cache_age_suffix "$LLM_TPS_CACHE" "soon")
    [[ -z "$out" ]]
}

# _render — run the real tactical_dashboard with every live getter stubbed, against
# a sandboxed cache directory.  `oc` is stubbed for the same reason as above (it
# would query the live gateway).
_render() {
    export __TAC_OPENCLAW_OK=1
    __TAC_BG_PIDS=()
    oc() { :; }
    __test_port() { return 0; }
    __get_host_metrics() { printf '10|5|3\n'; }
    __get_gpu_engines() { printf 'Idle\n'; }
    __get_gpu() { printf 'RTX 3050 Ti,55,12,1000,4096\n'; }
    __get_battery() { printf 'A/C POWERED\n'; }
    __get_git() { printf 'main|SECURE\n'; }
    __get_oc_version() { printf 'v2026.9.5\n'; }
    __get_oc_metrics() { printf '4|12|v2026.9.5\n'; }
    __get_llm_slots() { printf '[]\n'; }
    __llm_registry_entry_by_file() { printf '16|Qwen2.5-3B|fixture.gguf|1.9G\n'; }
    ( tactical_dashboard )
}

@test "stale: the render marks an ancient TPS value and leaves a fresh one unmarked" {
    _load_console
    printf 'fixture.gguf\n' > "$ACTIVE_LLM_FILE"
    printf '42.5\n' > "$LLM_TPS_CACHE"

    run _render
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"LOCAL LLM"*"42.5"* ]] || { echo "the rate should still render"; return 1; }
    [[ "$output" != *"TPS AGE"* ]] || { echo "a fresh rate was marked stale"; return 1; }

    # The injected failure: the cached rate is a day old, and the row must say so
    # rather than presenting it as the live measurement.
    touch -d '1 day ago' "$LLM_TPS_CACHE"
    run _render
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"TPS AGE"* ]] || { echo "a day-old rate rendered as current"; return 1; }
    [[ "$output" == *"STALE"* ]]
    # Same window as the case above, for the same reason: the age is the difference of
    # two clock reads, so a day-old stamp can render as 86400 or 86401 s.
    [[ "$output" =~ 8640[0-3]s ]] || { echo "the age is missing or wrong in '$output'"; return 1; }
}

@test "stale: the agent block's marker is wired to the same helper" {
    # Static for a stated reason: that block's cache path is the literal
    # /dev/shm/oc_agent_use.txt, so driving it end-to-end from a test would mean
    # writing the LIVE cache (and a fabricated agent list at that).  What is
    # checked here is the wiring of the same helper the TPS row uses for real
    # above; the helper's own behaviour is the case before this one.
    grep -q 'agent_use_age=$(__cache_age_suffix "$cache" 60)' "$REPO_ROOT/scripts/12-dashboard-help.sh" \
        || { echo "the agent block does not compute an age"; return 1; }
    grep -q '__fRow "AGENT AGE"' "$REPO_ROOT/scripts/12-dashboard-help.sh" \
        || { echo "the agent block computes an age and never renders it"; return 1; }
}

# ── item 1's contract half: the checker verifies the witnesses ─────────────
# Fixtures in the 22/24 style: a throwaway tree with a load list, one module that
# exports the command, one contract entry and one decision record.
_write_fixture() {
    rm -rf "$SANDBOX/fixture"
    local fx="$SANDBOX/fixture"
    mkdir -p "$fx/scripts" "$fx/docs/contracts" "$fx/skills/tactical-console" \
             "$fx/.agents/decisions"
    cat > "$fx/scripts/_module-list.sh" <<'SH'
#!/usr/bin/env bash
# Fixture load list.
function __tac_module_list() {
    printf '%s\n' \
        01-alpha \
}
SH
    cat > "$fx/scripts/01-alpha.sh" <<'SH'
# shellcheck shell=bash
# Module Version: 1
# @modular-section: alpha
# @depends: none
# @exports: alpha-cmd

alpha-cmd() { printf '%s\n' alpha; }
ALPHA_STATE="ready"
SH
    cat > "$fx/skills/tactical-console/SKILL.md" <<'MD'
---
name: tactical-console
---

# Fixture skill

| Command | Description | Example |
|---------|-------------|---------|
| `tac-exec alpha-cmd` | Run alpha | Check alpha |
MD
    cat > "$fx/.agents/decisions/fixture-decision.md" <<'MD'
---
name: fixture-decision
date: 2026-09-23
status: active
scope: both
commands: [alpha-cmd]
---

**Decision:** fixture decision.
MD
    cat > "$fx/docs/contracts/state-contracts.yaml" <<'YAML'
version: 2
variables:
  - name: ALPHA_STATE
    producer: scripts/01-alpha.sh
    consumers:
      - unenforced: true
        reader: a human reading the fixture
        why: fixture only — this file asserts the witness check, not state edges
    type: string
    semantics: fixture state
YAML
}

# _write_entry <extra yaml lines> — the contract entry, optionally extended.
_write_entry() {
    cat > "$SANDBOX/fixture/docs/contracts/command-contracts.yaml" <<YAML
version: 2
updated: 2026-09-23
commands:
  - name: alpha-cmd
    family: fixture
    summary: Run the fixture alpha command
    version: 1
    updated: 2026-09-23
    status: active
    scope: both
$1
    contract:
      side_effects:
        - writes the fixture state
      output_shape:
        - one line
      exit_code: 0
YAML
}

# _add_witness <symbol> — define the witness in the module and call it.
_add_witness() {
    cat >> "$SANDBOX/fixture/scripts/01-alpha.sh" <<SH

# $1 — fixture read-back witness.
$1() { [[ -f "\${ALPHA_STATE_FILE:-/nonexistent}" ]]; }
SH
}

@test "witness-check: a mutating entry with no witness is a finding" {
    _write_fixture
    _write_entry "    read_back_exempt: \"\""
    run "$CHECKER" state --repo "$SANDBOX/fixture"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"read_back_exempt:\` needs a reason"* ]]

    _write_entry ""
    run "$CHECKER" state --repo "$SANDBOX/fixture"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"FAIL  alpha-cmd: declares 1 side effect(s) but neither a \`read_back:\`"* ]]
}

@test "witness-check: a declared witness must exist, be a function, and be called" {
    _write_fixture
    _write_entry $'    read_back:\n      - witness: alpha_witness\n        file: scripts/01-alpha.sh\n        asserts: the fixture state was written by the command'

    # Defined but never called in the exporting module: the decorative witness.
    _add_witness alpha_witness
    run "$CHECKER" state --repo "$SANDBOX/fixture"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"never called in"* ]]

    # Called, but not defined where the entry says it is.
    sed -i 's/^alpha_witness() .*$/alpha_witness() { :; }/' "$SANDBOX/fixture/scripts/01-alpha.sh"
    sed -i 's/^alpha-cmd() .*$/alpha-cmd() { alpha_witness; }/' "$SANDBOX/fixture/scripts/01-alpha.sh"
    sed -i 's|file: scripts/01-alpha.sh|file: scripts/09-other.sh|' \
        "$SANDBOX/fixture/docs/contracts/command-contracts.yaml"
    run "$CHECKER" state --repo "$SANDBOX/fixture"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"names missing file 'scripts/09-other.sh'"* ]]

    # A file that exists but does not define the symbol (a variable, not a
    # function) is the same finding.
    sed -i 's|file: scripts/09-other.sh|file: scripts/01-alpha.sh|' \
        "$SANDBOX/fixture/docs/contracts/command-contracts.yaml"
    sed -i 's|^      - witness: alpha_witness|      - witness: ALPHA_STATE|' \
        "$SANDBOX/fixture/docs/contracts/command-contracts.yaml"
    printf 'ALPHA_STATE=""\n' >> "$SANDBOX/fixture/scripts/01-alpha.sh"
    run "$CHECKER" state --repo "$SANDBOX/fixture"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"'ALPHA_STATE' is not a function defined in scripts/01-alpha.sh"* ]]
}

@test "witness-check: a valid witness is verified and counted" {
    _write_fixture
    _write_entry $'    read_back:\n      - witness: alpha_witness\n        file: scripts/01-alpha.sh\n        asserts: the fixture state was written by the command'
    _add_witness alpha_witness
    sed -i 's/^alpha-cmd() .*$/alpha-cmd() { alpha_witness; }/' "$SANDBOX/fixture/scripts/01-alpha.sh"

    run "$CHECKER" state --repo "$SANDBOX/fixture"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"read-back witnesses: 1 verified, 0 not witnessed"* ]]
}

@test "witness-check: an asserted claim shorter than a sentence is not a claim" {
    _write_fixture
    _write_entry $'    read_back:\n      - witness: alpha_witness\n        file: scripts/01-alpha.sh\n        asserts: ok'
    _add_witness alpha_witness
    sed -i 's/^alpha-cmd() .*$/alpha-cmd() { alpha_witness; }/' "$SANDBOX/fixture/scripts/01-alpha.sh"

    run "$CHECKER" state --repo "$SANDBOX/fixture"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"\`asserts:\` must say what the witness reads back"* ]]
}

@test "witness-check: a read-only entry must not declare a witness" {
    _write_fixture
    _write_entry $'    read_back:\n      - witness: alpha_witness\n        file: scripts/01-alpha.sh\n        asserts: nothing at all is written here, so nothing can be read back'
    _add_witness alpha_witness
    sed -i 's/^alpha-cmd() .*$/alpha-cmd() { alpha_witness; }/' "$SANDBOX/fixture/scripts/01-alpha.sh"
    # The entry now declares NO side effects, so there is nothing to read back.
    sed -i 's/^      side_effects:$/      side_effects: []/' \
        "$SANDBOX/fixture/docs/contracts/command-contracts.yaml"
    sed -i '/^        - writes the fixture state$/d' \
        "$SANDBOX/fixture/docs/contracts/command-contracts.yaml"

    run "$CHECKER" state --repo "$SANDBOX/fixture"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"declares a \`read_back:\` witness but its contract lists no side_effects"* ]]
}

@test "witness-check: the real repo's witnesses are verified, and its gaps are declared" {
    # The one case that runs against the real tree (the 16-docs-sync precedent):
    # it pins that the mechanism is live here, not only on fixtures.  The count is
    # not pinned to a number — a new witness should not fail this — but a run that
    # verified NOTHING is a failure, because that is the state where the check
    # asserts nothing.
    run "$CHECKER" state
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"check-contracts[state]: OK"* ]]
    [[ "$output" != *"read-back witnesses: 0 verified"* ]]
    [[ "$output" == *"read-back witnesses: "*" not witnessed (printed above)"* ]]
}

# end of file
