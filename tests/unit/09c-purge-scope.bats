#!/usr/bin/env bats
# Regression tests for oc purge — 2026-10-29 defects.
#
# 1. The dry run and the real run must derive the reset scope from ONE place.  Measured
#    defect: the preview read ${OC_PURGE_RESET_MAIN-hal} and the run read
#    ${OC_PURGE_RESET_MAIN-all}, so with the variable UNSET the preview named one main
#    while the run reset all fourteen.
# 2. An unreadable store must REFUSE, not print "Purge Complete" over its own errors.
# 3. A tombstoned main cannot be reset; the refusal must route to sessions.recover and be
#    reported as a successor, never as a repair.

setup() {
    export REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export TAC_TEST_TMPDIR="$(mktemp -d)"
    export TAC_CACHE_DIR="$TAC_TEST_TMPDIR/cache"
    mkdir -p "$TAC_CACHE_DIR"
    export OC_AGENTS="$TAC_TEST_TMPDIR/agents"
    mkdir -p "$OC_AGENTS"

    source "$REPO_ROOT/scripts/09c-oc-core.sh"

    # Silence the console renderer so assertions read only the function's rc/output.
    __tac_info() { :; }
}

teardown() { rm -rf "$TAC_TEST_TMPDIR"; }

@test "reset scope: unset means every main, not one agent" {
    unset OC_PURGE_RESET_MAIN
    [ "$(__oc_purge_reset_scope)" = "all" ]
}

@test "reset scope: explicit empty disables the reset" {
    OC_PURGE_RESET_MAIN=
    [ -z "$(__oc_purge_reset_scope)" ]
}

@test "reset scope: a name narrows to that agent" {
    OC_PURGE_RESET_MAIN=hal
    [ "$(__oc_purge_reset_scope)" = "hal" ]
}

@test "reset scope is derived once, so preview and run cannot disagree" {
    # The defect was TWO literals with different defaults.  One derivation means the raw
    # parameter expansion appears in exactly one CODE line — comment lines are excluded
    # because the module header documents both of the old defaults, and a raw grep counts
    # that prose (measured: raw 3, code 1).  A count that includes comments is a count of
    # the documentation, not of the behaviour.
    run bash -c "grep -v '^[[:space:]]*#' '$REPO_ROOT/scripts/09c-oc-core.sh' \
        | grep -c 'OC_PURGE_RESET_MAIN-'"
    [ "$output" = "1" ]
}

@test "the single derivation lives in __oc_purge_reset_scope" {
    run bash -c "awk '/^function __oc_purge_reset_scope/,/^}/' \
        '$REPO_ROOT/scripts/09c-oc-core.sh' | grep -c 'OC_PURGE_RESET_MAIN-'"
    [ "$output" = "1" ]
}

@test "census refuses when sqlite3 is unavailable" {
    mkdir -p "$OC_AGENTS/hal/agent"
    : > "$OC_AGENTS/hal/agent/openclaw-agent.sqlite"
    # A PATH with no sqlite3: the census must say so rather than count zero stores.
    run env PATH="/usr/bin:/bin" bash -c \
        "command -v sqlite3 >/dev/null && exit 99; source '$REPO_ROOT/scripts/09c-oc-core.sh'; __tac_info(){ :; }; OC_AGENTS='$OC_AGENTS'; __oc_purge_store_census"
    [ "$status" -eq 1 ]
}

@test "census reports every store readable when they are" {
    command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 not installed"
    mkdir -p "$OC_AGENTS/hal/agent" "$OC_AGENTS/finn/agent"
    sqlite3 "$OC_AGENTS/hal/agent/openclaw-agent.sqlite" "create table t(x);"
    sqlite3 "$OC_AGENTS/finn/agent/openclaw-agent.sqlite" "create table t(x);"
    run __oc_purge_store_census
    [ "$status" -eq 0 ]
}

@test "tombstoned reset routes to sessions.recover and returns 4, never a repair" {
    local _db="$OC_AGENTS/hal/agent/openclaw-agent.sqlite"
    mkdir -p "$OC_AGENTS/hal/agent"
    command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 not installed"
    sqlite3 "$_db" "create table session_nodes(session_key text, current_session_id text, entry_json text);"
    sqlite3 "$_db" "insert into session_nodes values('agent:hal:main','sid-1','{}');"

    # Stub the transport: reset answers with the tombstone refusal, recover succeeds.
    __oc_purge_rpc() {
        [[ "$1" == "sessions.recover" ]] && { printf '%s\n' '{"ok":true}'; return 0; }
        return 1
    }
    __oc_purge_rpc_capture() {
        __OC_PURGE_RPC_OUT='{"ok":false,"error":{"code":"INVALID_REQUEST","message":"Session \"agent:hal:main\" ended during restart recovery. Use /new or /reset to start a replacement session."}}'
        return 1
    }
    run __oc_purge_reset_main "agent:hal:main"
    [ "$status" -eq 4 ]
}

@test "a non-tombstone reset refusal stays a failure, not a recovery" {
    local _db="$OC_AGENTS/hal/agent/openclaw-agent.sqlite"
    mkdir -p "$OC_AGENTS/hal/agent"
    command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 not installed"
    sqlite3 "$_db" "create table session_nodes(session_key text, current_session_id text, entry_json text);"
    sqlite3 "$_db" "insert into session_nodes values('agent:hal:main','sid-1','{}');"
    __oc_purge_rpc() { printf '%s\n' "recover-must-not-be-called" >> "$TAC_TEST_TMPDIR/calls"; return 0; }
    __oc_purge_rpc_capture() { __OC_PURGE_RPC_OUT='{"ok":false,"error":{"code":"INVALID_REQUEST","message":"something else"}}'; return 1; }
    run __oc_purge_reset_main "agent:hal:main"
    [ "$status" -eq 1 ]
    [ ! -e "$TAC_TEST_TMPDIR/calls" ]
}

@test "dry run announces the same reset scope the real run would perform" {
    # The defect as the owner saw it: unset OC_PURGE_RESET_MAIN, and the preview named ONE
    # main while the run reset ALL of them.  This calls the real dry-run arm with the
    # gateway reads stubbed out, and counts what it announces.
    export __TAC_OPENCLAW_OK=1
    export OC_PURGE_RESET_MAIN=; unset OC_PURGE_RESET_MAIN
    local _out="$TAC_TEST_TMPDIR/dry.out"
    __tac_info() { printf '%s %s %s\n' "$1" "$2" "$3" >> "$_out"; }
    __oc_purge_store_census() { return 0; }
    __oc_purge_session_keys() {
        printf '%s\n'             agent:hal:main agent:finn:main agent:sarah:main agent:main:main \
            agent:hal:cron:daily agent:hal:dashboard:abc
    }
    __oc_purge_broken_tombstones() { :; }
    run oc-purge --dry-run
    [ "$status" -eq 0 ]
    grep -q "WOULD RESET every agent main" "$_out"
    [ "$(grep -c '\[WOULD RESET\] agent:' "$_out")" -eq 4 ]
    # The non-main rows are the delete list, never the reset list.
    ! grep -q 'WOULD RESET\] agent:hal:dashboard' "$_out"
}

@test "dry run narrows to one agent when the variable names one" {
    export __TAC_OPENCLAW_OK=1
    export OC_PURGE_RESET_MAIN=hal
    local _out="$TAC_TEST_TMPDIR/dry2.out"
    __tac_info() { printf '%s %s %s\n' "$1" "$2" "$3" >> "$_out"; }
    __oc_purge_store_census() { return 0; }
    __oc_purge_session_keys() { printf '%s\n' agent:hal:main agent:finn:main; }
    __oc_purge_broken_tombstones() { :; }
    run oc-purge --dry-run
    [ "$status" -eq 0 ]
    [ "$(grep -c '\[WOULD RESET\] agent:' "$_out")" -eq 1 ]
    grep -q 'WOULD RESET\] agent:hal:main' "$_out"
}

@test "an archived tombstone is unarchived BEFORE it is reset (the order that works)" {
    # Measured 2026-10-29 on 2026.10.10-beta.4: the reset bypass requires
    # allowRestartTombstoneReplacement && !providerReview, and the reset service passes that
    # flag only when entry.archivedAt === undefined.  An entry that is BOTH archived and
    # tombstoned therefore can never satisfy it, and "use /new or /reset" fails the same
    # way.  patch{archived:false} THEN reset cleared four wedged mains (doctor 4 -> 0).
    # This pins the order, because reset-first is the shape that silently does nothing.
    command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 not installed"
    local _db="$OC_AGENTS/hal/agent/openclaw-agent.sqlite"
    mkdir -p "$OC_AGENTS/hal/agent"
    sqlite3 "$_db" "create table session_nodes(session_key text, current_session_id text, entry_json text);"
    sqlite3 "$_db" "insert into session_nodes values('agent:hal:main','sid-1','{\"archivedAt\":123,\"mainRestartRecovery\":{\"tombstone\":{}}}');"

    local _calls="$TAC_TEST_TMPDIR/calls"
    : > "$_calls"
    # Simulate the gateway: the patch and the reset each clear the entry fields.
    # BOTH transports must be stubbed: the patch goes through __oc_purge_rpc and the reset
    # through __oc_purge_rpc_capture.  Stubbing only the first let this test reach the LIVE
    # gateway and attempt a real reset of agent:hal:main (it failed on expectedSessionId,
    # measured 2026-10-29) — a test must never be able to mutate a live lane.
    __oc_purge_rpc() {
        printf '%s\n' "$1" >> "$_calls"
        sqlite3 "$_db" "update session_nodes set entry_json='{}' where session_key='agent:hal:main';"
        return 0
    }
    __oc_purge_rpc_capture() {
        printf '%s\n' "$1" >> "$_calls"
        __OC_PURGE_RPC_OUT='{"ok":true}'
        sqlite3 "$_db" "update session_nodes set entry_json='{}' where session_key='agent:hal:main';"
        return 0
    }
    run __oc_purge_reset_main "agent:hal:main"
    [ "$status" -eq 0 ]
    [ "$(sed -n '1p' "$_calls")" = "sessions.patch" ]
    [ "$(sed -n '2p' "$_calls")" = "sessions.reset" ]
    [ "$(wc -l < "$_calls")" -eq 2 ]
}
