#!/usr/bin/env bats
# ==============================================================================
# 56-two-sided-freshness.bats — a cache mtime in the FUTURE must not read as fresh
# ==============================================================================
# Criterion (peer commit 4717b4be, completed here): an age computed as `now - mtime`
# against a ONE-sided bound lets a future mtime — a clock step, or an explicit
# backdate — make the age NEGATIVE and trip the bound the WRONG way, so a stale cache
# is served as fresh. Every freshness bound must be two-sided.
#
# These cases drive the REAL helpers with a file whose mtime is in the future and
# assert the verdict flips.  Each case states the wrong outcome it catches; the
# control case in each pair proves the same helper STILL honours a genuinely young
# cache, so a helper that simply always said "stale" would fail them.
#
# COVERED: __cache_fresh (07), __tac_probe_ok (01), __cache_age_suffix (07),
# __oc_nas_resolve_host (09d), and the four previously-untested inline guards in
# scripts/08-maintenance.sh:1373 (__up_stale_processes), scripts/09a-oc-gateway.sh:95
# (__so_check_stale_hold), scripts/09e-oc-health.sh (oc-usage's session cache) and
# scripts/12-dashboard-help.sh (__dashboard_oc_active_agents' agent-use cache).
#
# The dashboard guard's cache path was HARD-CODED at /dev/shm/oc_agent_use.txt and its
# staleness branch spawned a real background `oc agent-use`, so it could not be driven
# hermetically; scripts/12-dashboard-help.sh v26 made the path read OC_AGENT_USE_FILE
# (default unchanged), which is what lets the pair at the end of this file point a
# future-dated fixture at $BATS_TEST_TMPDIR and observe the refresh through a stub.
# ==============================================================================

setup_file() {
    export REPO_ROOT
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
}

setup() {
    export REPO_ROOT
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export TAC_CACHE_DIR="$BATS_TEST_TMPDIR/cache"
    export TAC_STATE_DIR="$BATS_TEST_TMPDIR/state"
    export OC_ROOT="$BATS_TEST_TMPDIR/.openclaw"
    export ACTIVE_LLM_FILE="$BATS_TEST_TMPDIR/active_llm"
    mkdir -p "$TAC_CACHE_DIR" "$TAC_STATE_DIR" "$OC_ROOT"
    export __TAC_INITIALIZED=1
    # shellcheck source=env.sh
    source "$REPO_ROOT/env.sh" >/dev/null 2>&1 || true
    # Re-assert the sandbox AFTER sourcing: 01-constants.sh unconditionally exports
    # TAC_CACHE_DIR=/dev/shm, ACTIVE_LLM_FILE=/dev/shm/active_llm and
    # OC_ROOT=$HOME/.openclaw, and derives OC_AGENTS / ErrorLogPath from the real
    # $HOME.  Without this the guards under test would read and write live host state
    # (the /dev/shm bridge cache, the real error log) instead of the fixture.
    export TAC_CACHE_DIR="$BATS_TEST_TMPDIR/cache"
    export TAC_STATE_DIR="$BATS_TEST_TMPDIR/state"
    export OC_ROOT="$BATS_TEST_TMPDIR/.openclaw"
    export ACTIVE_LLM_FILE="$BATS_TEST_TMPDIR/active_llm"
    export OC_AGENTS="$OC_ROOT/agents"
    export ErrorLogPath="$OC_ROOT/logs/bash-errors.log"
    mkdir -p "$TAC_CACHE_DIR" "$TAC_STATE_DIR" "$OC_ROOT" "$OC_AGENTS" "${ErrorLogPath%/*}"
    # No case may reach the live /dev/shm agent-use cache: only the guard-4 pair sets
    # these, and it points them at $BATS_TEST_TMPDIR.
    unset OC_AGENT_USE_FILE OC_AGENT_USE_MARKER
}

# ── __cache_fresh (07-telemetry) — the shared helper behind six call sites ────

@test "freshness: __cache_fresh rejects a cache dated in the FUTURE" {
    # Wrong outcome caught: a future mtime makes the age negative, and a one-sided
    # `(( _now - _ts < _ttl ))` then reads it as FRESH.
    local c="$TAC_CACHE_DIR/future"
    : > "$c"
    touch -d '+1 hour' "$c"
    run __cache_fresh "$c" 3600
    [ "$status" -eq 1 ]
}

@test "freshness: control — __cache_fresh still honours a young cache" {
    local c="$TAC_CACHE_DIR/young"
    : > "$c"
    run __cache_fresh "$c" 3600
    [ "$status" -eq 0 ]
}

# ── __tac_probe_ok (01-constants) — a cached probe result ────────────────────

@test "freshness: __tac_probe_ok re-probes when its cache is dated in the FUTURE" {
    # Wrong outcome caught: the cached "1" is honoured and the (failing) probe is
    # never run, so a future-dated cache reports success.
    printf '1\n' > "$TAC_CACHE_DIR/probe"
    touch -d '+1 hour' "$TAC_CACHE_DIR/probe"
    run __tac_probe_ok probe 3600 false
    [ "$status" -eq 1 ]
}

@test "freshness: control — __tac_probe_ok honours a young cached value" {
    printf '1\n' > "$TAC_CACHE_DIR/probe2"
    run __tac_probe_ok probe2 3600 false
    [ "$status" -eq 0 ]
}

# ── __cache_age_suffix (07-telemetry) — the rendered staleness marker ─────────

@test "freshness: __cache_age_suffix marks a FUTURE mtime as STALE" {
    # Wrong outcome caught: the value renders with NO marker, so a cache dated in
    # the future is displayed as current.
    local c="$BATS_TEST_TMPDIR/age-future"
    : > "$c"
    touch -d '+1 hour' "$c"
    run __cache_age_suffix "$c" 60
    [ "$status" -eq 0 ]
    [[ "$output" == *STALE* ]]
}

@test "freshness: control — __cache_age_suffix leaves a young cache unmarked" {
    local c="$BATS_TEST_TMPDIR/age-young"
    : > "$c"
    run __cache_age_suffix "$c" 60
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

# ── __oc_nas_resolve_host (09d) — the run-time NAS route ─────────────────────

@test "nas route: __oc_nas_resolve_host defaults to the LAN address without OC_NAS_HOST" {
    unset OC_NAS_HOST
    run __oc_nas_resolve_host /nonexistent-key u 1
    [ "$status" -eq 0 ]
    [ "$output" = "192.168.33.20" ]
}

@test "nas route: __oc_nas_resolve_host lets OC_NAS_HOST win" {
    export OC_NAS_HOST=nas.example
    run __oc_nas_resolve_host /nonexistent-key u 1
    [ "$status" -eq 0 ]
    [ "$output" = "nas.example" ]
    unset OC_NAS_HOST
}

# ── __up_stale_processes (08-maintenance) — the model-boot reap guard ─────────

@test "freshness: __up_stale_processes does not take the boot-skip on a FUTURE ACTIVE_LLM_FILE" {
    # Wrong outcome caught: a future mtime makes the boot age negative, and a
    # one-sided `(( _active_age < 60 ))` then runs the "[SKIP - MODEL BOOTING]"
    # early return — orphaned llama-server instances are never reaped while a stale
    # boot marker keeps reading as a fresh one.
    : > "$ACTIVE_LLM_FILE"
    touch -d '+1 hour' "$ACTIVE_LLM_FILE"
    # The reap body below the guard is a no-op here ([CLEAN]): no llama-server PIDs
    # are offered, and systemctl is stubbed so the protected-unit probe never
    # reaches (or kills anything on) real systemd.
    __llm_server_pids() { :; }
    systemctl() { return 1; }
    local errCount=0
    run __up_stale_processes "$(date +%s)" "" errCount
    [ "$status" -eq 0 ]
    [[ "$output" != *"MODEL BOOTING"* ]]
}

@test "freshness: control — __up_stale_processes still skips while the model is booting" {
    : > "$ACTIVE_LLM_FILE"
    __llm_server_pids() { :; }
    systemctl() { return 1; }
    local errCount=0
    run __up_stale_processes "$(date +%s)" "" errCount
    [ "$status" -eq 0 ]
    [[ "$output" == *"MODEL BOOTING"* ]]
}

# ── __so_check_stale_hold (09a-oc-gateway) — the orphaned recovery hold ──────

@test "freshness: __so_check_stale_hold clears a hold dated in the FUTURE" {
    # Wrong outcome caught: a future mtime makes the hold's age negative, and a
    # one-sided `(( _age <= _limit ))` honours it forever — the gateway stays down
    # with no crash and no log line, the exact hole this check exists to close.
    local hold="$OC_ROOT/.gateway-hold"
    : > "$hold"
    touch -d '+1 hour' "$hold"
    run __so_check_stale_hold
    [ "$status" -eq 0 ]
    [[ "$output" == *"STALE HOLD"* ]]
    [ ! -e "$hold" ]
}

@test "freshness: control — __so_check_stale_hold honours a young hold" {
    local hold="$OC_ROOT/.gateway-hold"
    : > "$hold"
    run __so_check_stale_hold
    [ "$status" -eq 1 ]
    [ -e "$hold" ]
}

# ── oc-usage (09e-oc-health) — the session-cache refresh guard ───────────────

@test "freshness: oc-usage refreshes a session cache dated in the FUTURE" {
    # Wrong outcome caught: a future mtime makes `now - mtime` negative, and a
    # one-sided `(( now - mtime > 5 ))` reads it as current — the stale session
    # cache is rendered as live for as long as its mtime stays ahead of the clock.
    local c="$TAC_CACHE_DIR/oc_sessions.json"
    printf '[{"totalTokens":111}]\n' > "$c"
    touch -d '+1 hour' "$c"
    export __TAC_OPENCLAW_OK=1
    # Stub the CLI: its stdout is what the refresh writes into the cache, so a
    # refresh is observable as the refresh's token count reaching the render.
    openclaw() { printf '[{"totalTokens":999}]\n'; }
    run oc-usage
    [ "$status" -eq 0 ]
    [[ "$output" == *"Total: 999"* ]]
}

@test "freshness: control — oc-usage trusts a just-written session cache" {
    local c="$TAC_CACHE_DIR/oc_sessions.json"
    printf '[{"totalTokens":111}]\n' > "$c"
    export __TAC_OPENCLAW_OK=1
    openclaw() { printf '[{"totalTokens":999}]\n'; }
    run oc-usage
    [ "$status" -eq 0 ]
    [[ "$output" == *"Total: 111"* ]]
}

# ── __dashboard_oc_active_agents (12-dashboard-help) — the agent-use cache ────

@test "freshness: __dashboard_oc_active_agents refreshes a cache dated in the FUTURE" {
    # Wrong outcome caught: a future mtime makes `now - mtime` negative, and a
    # one-sided `(( now - mtime > cache_ttl ))` reads the cache as current — the
    # background `oc agent-use` refresh is never kicked, so a stale agent list is
    # rendered as live for as long as its mtime stays ahead of the clock.
    export OC_AGENT_USE_FILE="$BATS_TEST_TMPDIR/oc_agent_use.txt"
    printf 'agent-a: 42%%\n' > "$OC_AGENT_USE_FILE"
    touch -d '+1 hour' "$OC_AGENT_USE_FILE"
    # `oc` is spawned by the function inside a background subshell, so stub it (a
    # shell FUNCTION, which is what the spawn needs — an external file cannot be
    # seen by the subshell's function lookup) and record the spawn as a marker.
    export OC_AGENT_USE_MARKER="$BATS_TEST_TMPDIR/refreshed"
    oc() { : > "$OC_AGENT_USE_MARKER"; }
    run __dashboard_oc_active_agents "───"
    local i=0
    while [[ ! -e "$OC_AGENT_USE_MARKER" && $i -lt 60 ]]; do
        sleep 0.05
        i=$((i + 1))
    done
    [ -e "$OC_AGENT_USE_MARKER" ]
}

@test "freshness: control — __dashboard_oc_active_agents leaves a just-written cache alone" {
    export OC_AGENT_USE_FILE="$BATS_TEST_TMPDIR/oc_agent_use.txt"
    printf 'agent-a: 42%%\n' > "$OC_AGENT_USE_FILE"
    export OC_AGENT_USE_MARKER="$BATS_TEST_TMPDIR/refreshed"
    oc() { : > "$OC_AGENT_USE_MARKER"; }
    run __dashboard_oc_active_agents "───"
    # Grace period: a guard that (wrongly) fired the refresh a moment late, or one
    # that simply always said "stale", still gets caught by this assertion.
    sleep 0.3
    [ ! -e "$OC_AGENT_USE_MARKER" ]
}

# ── scripts/load-vault-env.sh — the Windows env-bridge refresh guard ─────────
#
# The bridge crosses the WSL/Windows boundary and starts pwsh.exe: 1.7-2.1 s per
# call, measured 2026-10-11.  It ran on EVERY interactive shell — the guard was "is
# the helper present", never "is the result stale" — and was the largest single
# contributor to shell startup (`bash -lic true`: 3.0-6.4 s with it, 0.55-0.63 s with
# the vault load skipped).  v7 added the TTL guard these cases pin.

# vault_layout — a sandbox HOME so the loader's own $HOME paths (the bridge helper,
# the bridge file and the candidate vault files) all resolve inside the test.
vault_layout() {
    V_HOME="$BATS_TEST_TMPDIR/vault-home"
    V_BIN="$V_HOME/.local/bin"
    V_LOG="$BATS_TEST_TMPDIR/vault-bridge-calls.log"
    V_BRIDGE="$V_HOME/.openclaw/.env.bridge"
    V_LOADER="$REPO_ROOT/scripts/load-vault-env.sh"
    mkdir -p "$V_BIN" "$V_HOME/.openclaw/credentials/vault"
    : > "$V_LOG"
    export V_LOG   # the stub bridge is a child process: it must see the log path
    # The bridge as the loader calls it: bash <script> <out> <names...>.
    printf '%s\n' '#!/usr/bin/env bash' \
        'printf "%s\n" "$*" >> "${V_LOG:?}"' \
        'printf "%s\n" "OPENAI_API_KEY=stub" > "$1"' \
        'exit 0' > "$V_BIN/import-windows-env.sh"
    chmod +x "$V_BIN/import-windows-env.sh"
    # One candidate file, so the loader gets past its "nothing to read" early return.
    printf '%s\n' 'OPENAI_API_KEY=stub' > "$V_HOME/.openclaw/credentials/vault/vault.env"
    V_PY="$REPO_ROOT/.venv/bin/python3"
    [[ -x "$V_PY" ]] || V_PY="$(command -v python3)"
    export V_PY
}

# vault_run <TAC_VAULT_BRIDGE_TTL> [extra env assignments...]
vault_run() {
    local ttl="$1"
    shift
    run env HOME="$V_HOME" TMPDIR="$BATS_TEST_TMPDIR" TAC_PYTHON="$V_PY" \
        TAC_VAULT_BRIDGE_TTL="$ttl" "$@" \
        bash -c 'source "$1"' _ "$V_LOADER"
}

@test "vault bridge: a MISSING bridge file refreshes it (no result to trust)" {
    # The control the TTL guard must not defeat: with nothing on disk there is no
    # freshness to honour, so the bridge must run.
    vault_layout
    rm -f "$V_BRIDGE"
    vault_run 300
    [[ "$status" -eq 0 ]]
    [[ "$(wc -l < "$V_LOG")" -eq 1 ]]
    [[ -f "$V_BRIDGE" ]]
}

@test "vault bridge: control — a bridge file younger than the TTL is NOT refreshed" {
    # Catches the live defect: pwsh.exe (1.7-2.1 s) started on every interactive
    # shell because nothing ever asked whether the bridge file was stale.
    vault_layout
    printf '%s\n' 'OPENAI_API_KEY=fresh' > "$V_BRIDGE"
    vault_run 300
    [[ "$status" -eq 0 ]]
    [[ ! -s "$V_LOG" ]]
}

@test "vault bridge: a bridge file OLDER than the TTL IS refreshed" {
    # Catches the opposite failure: a TTL that never expires, so a rotated Windows
    # credential is never picked up again.
    vault_layout
    printf '%s\n' 'OPENAI_API_KEY=stale' > "$V_BRIDGE"
    touch -d '2 hours ago' "$V_BRIDGE"
    vault_run 300
    [[ "$status" -eq 0 ]]
    [[ "$(wc -l < "$V_LOG")" -eq 1 ]]
}

@test "vault bridge: a bridge file dated in the FUTURE is refreshed (two-sided)" {
    # Catches a ONE-sided `(( age < TTL ))`: a future mtime makes the age negative,
    # which reads as fresh and would skip the refresh until the clock caught up —
    # the same class of defect this file exists to pin.
    vault_layout
    printf '%s\n' 'OPENAI_API_KEY=future' > "$V_BRIDGE"
    touch -d '+1 hour' "$V_BRIDGE"
    vault_run 300
    [[ "$status" -eq 0 ]]
    [[ "$(wc -l < "$V_LOG")" -eq 1 ]]
}

@test "vault bridge: TTL=0 forces a refresh on every shell (escape hatch)" {
    # The behaviour before v7, kept reachable deliberately: anyone who needs the
    # bridge regenerated per shell sets TAC_VAULT_BRIDGE_TTL=0.
    vault_layout
    printf '%s\n' 'OPENAI_API_KEY=fresh' > "$V_BRIDGE"
    vault_run 0
    [[ "$status" -eq 0 ]]
    [[ "$(wc -l < "$V_LOG")" -eq 1 ]]
}

@test "vault bridge: TAC_VAULT_REFRESH_FROM_WINDOWS=0 still skips the bridge" {
    # The pre-existing switch must keep working — it is the documented way to avoid
    # the Windows call entirely.
    vault_layout
    rm -f "$V_BRIDGE"
    vault_run 300 TAC_VAULT_REFRESH_FROM_WINDOWS=0
    [[ "$status" -eq 0 ]]
    [[ ! -s "$V_LOG" ]]
}
