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

# stub_timeout — redefine `timeout` so it runs its command IN-PROCESS.
#
# WHY (measured 2026-11-26).  Every `openclaw` call in 09c-oc-core.sh is wrapped, e.g.
# `timeout -k 10 900 openclaw memory session-backfill ...`.  `timeout` is an EXTERNAL
# binary, so it resolves `openclaw` through PATH and never consults a shell function —
# a test that stubs `openclaw() { ... }` stubs nothing, the real CLI runs, and the case
# fails on behaviour nobody wrote a test for.  Three cases failed exactly that way, each
# carrying the real binary's "Unknown agent id" body.
#
# The shim drops `-k <dur>` and the duration, then runs the remaining argv here, so the
# command IS a shell function and the stub is reached.  It implements no deadline on
# purpose: a case that needs one should say so, and none here does.
stub_timeout() {
    timeout() {
        while [[ $# -gt 0 && "$1" == -* ]]; do
            case "$1" in
                -k|--kill-after) shift 2 ;;
                *)                shift   ;;
            esac
        done
        [[ $# -gt 0 ]] && shift   # the duration
        "$@"
    }
}

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

# ---------------------------------------------------------------------------
# 2026-11-25: Wayne, "i don't think it works properly".  The three behavioural
# defects were a substring classifier that kept cron RUNS forever, a dry run that
# did not list the destructive arm, and no memory step at all.
# ---------------------------------------------------------------------------

@test "classifier: a cron RUN session is deleted, its job session is kept" {
    source "$REPO_ROOT/scripts/09c-oc-core.sh"
    # The exact shape measured on the box, 2026-11-25.
    [ "$(__oc_purge_classify_key 'agent:sarah:cron:70d7121e-e88d-436b-ae4a-2b60ce130f87')" = "cronjob" ]
    [ "$(__oc_purge_classify_key 'agent:sarah:cron:70d7121e-e88d-436b-ae4a-2b60ce130f87:run:bef428f2-28ae-436d-b172-d97aaf138924')" = "cronrun" ]
}

@test "classifier: a main is main, a whatsapp lane is neither main nor cron" {
    source "$REPO_ROOT/scripts/09c-oc-core.sh"
    [ "$(__oc_purge_classify_key 'agent:hal:main')" = "main" ]
    [ "$(__oc_purge_classify_key 'agent:hal:whatsapp:direct:+447720061019')" = "ephemeral" ]
}

@test "classifier: a sub-agent under a cron parent is classified subagent, not cronrun" {
    source "$REPO_ROOT/scripts/09c-oc-core.sh"
    # Narrower meaning wins: Wayne asked for sub-agent sessions to be deleted explicitly, so the
    # class must be nameable even when a cron job parented it.
    [ "$(__oc_purge_classify_key 'agent:hal:sub:abc123')" = "subagent" ]
    [ "$(__oc_purge_classify_key 'agent:hal:subagent:abc123')" = "subagent" ]
}

@test "the delete set is derived from ONE place, so preview cannot list a set the run does not delete" {
    # Same defect shape as the reset scope in v37: two derivations drift. The raw grep excludes
    # comments because the header documents the old filter and a raw count reads the prose.
    run bash -c "grep -v '^[[:space:]]*#' '$REPO_ROOT/scripts/09c-oc-core.sh' \
        | grep -c '__oc_purge_delete_keys'"
    # 1 function definition + 1 call in the dry run + 1 call in the delete batch = 3 code lines.
    [ "$output" = "3" ]
}

@test "the old substring filter is gone from the delete path" {
    # It kept every `agent:<a>:cron:<job>:run:<id>`. If this string returns, 21 cron-run
    # sessions silently become permanent again.
    run bash -c "grep -v '^[[:space:]]*#' '$REPO_ROOT/scripts/09c-oc-core.sh' \
        | grep -c \"grep -vE '(:main\$|:cron:)'\""
    [ "$output" = "0" ]
}

@test "oc-purge has a memory step, and it refuses an agent whose flush cannot be shown" {
    # Defect A: measured 2026-11-25, grep for memory|distill|flush|persist over oc-purge and its
    # four helpers returned 0. The gate must exist AND be wired before the reset.
    run bash -c "grep -v '^[[:space:]]*#' '$REPO_ROOT/scripts/09c-oc-core.sh' \
        | grep -c '__oc_purge_memory_flush'"
    # definition + call in the reset loop + this arm's own reference = at least 2
    [ "$output" -ge 2 ]
}

@test "a workspace-less agent is refused rather than reset blind" {
    export HOME="$TAC_TEST_TMPDIR"
    mkdir -p "$HOME/.openclaw/agents/ghost/agent"
    OC_AGENTS="$HOME/.openclaw/agents"
    source "$REPO_ROOT/scripts/09c-oc-core.sh"
    run __oc_purge_memory_flush ghost
    [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# 2026-11-26: the 2026-11-25T23:20Z run was measured against its own intent.  These
# pin the four gates that let it pass while doing nothing.
# ---------------------------------------------------------------------------

@test "gate: an ERROR body from session-backfill REFUSES the reset (it used to pass as 0 candidates)" {
    # The defect, measured: the error body is {"ok":false,"error":{...}}, it carries no
    # candidateCount, so `(.candidateCount // ...) // 0` returned 0 with jq rc 0 -- and
    # "0 candidates" was a PASS arm.  A failed backfill and an empty one were the same thing.
    export HOME="$TAC_TEST_TMPDIR"
    mkdir -p "$HOME/.openclaw/agents/hal/agent" "$HOME/.openclaw/workspace-hal"
    OC_AGENTS="$HOME/.openclaw/agents"
    source "$REPO_ROOT/scripts/09c-oc-core.sh"
    __tac_info() { :; }
    # EVERY call in the module is wrapped in `timeout`, an EXTERNAL binary that resolves
    # `openclaw` through PATH and never consults a shell function. A case that defines
    # `openclaw()` and not `stub_timeout` runs the REAL CLI -- measured 2026-11-26, that is
    # what made this case pass for the wrong reason and then fail after the fixture changed.
    stub_timeout
    # The CLI exits 0 on this body (measured), so the stub must too.
    openclaw() {
        printf '%s\n' '{"ok":false,"error":{"type":"cli_error","message":"Unknown agent id"}}'
        return 0
    }
    run __oc_purge_memory_flush hal
    [ "$status" -eq 1 ]
}

@test "gate: ok:true with 0 candidates returns 2 (nothing to do), not 1 and not a silent 0" {
    export HOME="$TAC_TEST_TMPDIR"
    mkdir -p "$HOME/.openclaw/agents/hal/agent" "$HOME/.openclaw/workspace-hal"
    OC_AGENTS="$HOME/.openclaw/agents"
    source "$REPO_ROOT/scripts/09c-oc-core.sh"
    __tac_info() { :; }
    stub_timeout
    openclaw() {
        # THE REAL SUCCESS BODY (measured 2026-11-26): no `ok` field at all.
        printf '%s\n' '{"agentId":"hal","workspaceDir":"/tmp/ws","applied":true,"days":[],"candidateCount":0,"stagedEntries":0}'
        return 0
    }
    run __oc_purge_memory_flush hal
    [ "$status" -eq 2 ]
}

@test "gate: ok:true with candidates but no durable change REFUSES the reset" {
    export HOME="$TAC_TEST_TMPDIR"
    mkdir -p "$HOME/.openclaw/agents/hal/agent" "$HOME/.openclaw/workspace-hal"
    OC_AGENTS="$HOME/.openclaw/agents"
    source "$REPO_ROOT/scripts/09c-oc-core.sh"
    __tac_info() { :; }
    stub_timeout
    # A REAL success body (no `ok` key) that reports candidates, with no index growth and no
    # DREAMS.md change: the flush must REFUSE, because nothing durable was proven.
    openclaw() {
        printf '%s\n' '{"agentId":"hal","workspaceDir":"/tmp/ws","applied":true,"days":[],"candidateCount":22,"stagedEntries":0}'
        return 0
    }
    run __oc_purge_memory_flush hal
    [ "$status" -eq 1 ]
}

@test "gate: a fee-free promote body that says ok:false counts as a FAILED promote" {
    # Last night counted 14 exit codes of 0 while every body carried a secrets failure.
    export TAC_TEST_TMPDIR
    source "$REPO_ROOT/scripts/09c-oc-core.sh"
    __tac_info() { :; }
    __oc_purge_offline_window() { "$@"; }        # pretend the stop/start worked
    __oc_purge_promote_possible() { return 0; }  # pretend admission is possible
    openclaw() {
        printf '%s\n' '{"ok":false,"error":{"type":"cli_error","message":"[secrets] memory promote: gateway secrets.resolve unavailable"}}'
        return 0                          # rc 0 -- the defect
    }
    run __oc_purge_memory_promote_all hal
    [ "$status" -eq 1 ]
}

@test "promote is attempted for the flushed agents only" {
    source "$REPO_ROOT/scripts/09c-oc-core.sh"
    __tac_info() { :; }
    __oc_purge_offline_window() { "$@"; }
    __oc_purge_promote_possible() { return 0; }
    stub_timeout
    local _args="$TAC_TEST_TMPDIR/args"
    : > "$_args"
    # THE REAL BODY SHAPE (measured 2026-11-26): no `ok` field exists. `{"ok":true}` is not
    # what this CLI emits, and a fixture that answers a shape the tool never produces tests
    # the stub rather than the code.
    openclaw() {
        printf '%s\n' "$*" >> "$_args"
        printf '%s\n' '{"workspaceDir":"/tmp/ws","storePath":"s","lockPath":"l","audit":{},"candidates":[],"apply":{"applied":0,"appended":0}}'
        return 0
    }
    run __oc_purge_memory_promote_all finn juno
    [ "$status" -eq 0 ]
    grep -q -- '--agent finn' "$_args"
    grep -q -- '--agent juno' "$_args"
    ! grep -q -- '--agent hal' "$_args"
}

@test "delete: one agent's refusal does not stop the other agents" {
    source "$REPO_ROOT/scripts/09c-oc-core.sh"
    __tac_info() { :; }
    stub_timeout
    __oc_purge_session_keys() { printf '%s\n' \
        agent:sarah:cron:j1:run:r1 agent:sarah:cron:j1:run:r2 \
        agent:hal:cron:j2:run:r3 agent:hal:main agent:sarah:main ; }
    local _calls="$TAC_TEST_TMPDIR/calls"
    : > "$_calls"
    openclaw() {
        printf '%s\n' "$*" >> "$_calls"
        # sarah's batch is refused; hal's lands.  The old code sent ONE batch and lost both.
        if [[ "$*" == *sarah* ]]; then return 1; fi
        printf '%s\n' '{"ok":true}'
        return 0
    }
    run __oc_purge_delete_sessions
    [ "$status" -eq 1 ]
    grep -q 'agent:hal:cron:j2:run:r3' "$_calls"
    # the report line: deleted mains cron runs failures invisible (six fields, v50)
    [[ "$output" == "1 2 0 3 1 0" ]]
}

@test "read-back counts STORE rows, not just the CLI roster" {
    # The defect: roster said 0 non-main sessions while 21 :run: rows sat in the stores.
    command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 not installed"
    source "$REPO_ROOT/scripts/09c-oc-core.sh"
    __tac_info() { :; }
    local _db="$OC_AGENTS/hal/agent/openclaw-agent.sqlite"
    mkdir -p "$OC_AGENTS/hal/agent"
    sqlite3 "$_db" "create table session_windows(session_key text);"
    sqlite3 "$_db" "insert into session_windows values
        ('agent:hal:main'),('agent:hal:cron:job1'),
        ('agent:hal:cron:job1:run:r1'),('agent:hal:cron:job1:run:r2'),
        ('agent:hal:whatsapp:direct:+447');"
    run __oc_purge_store_left_count
    [ "$status" -eq 0 ]
    [ "$output" = "3" ]
}

@test "promote: the REAL body has no ok field, and that is a pass, not 14 FAILED lanes" {
    # v46 asserted `.ok == true` on this body. Measured 2026-11-26 in a live offline window:
    # the keys are workspaceDir, storePath, lockPath, audit, candidates[, apply] -- there is no
    # `ok`, so that gate was false on every SUCCESSFUL run. This is the falsification: the body
    # below is copied from a real run, and the verdict must not be FAILED.
    export HOME="$TAC_TEST_TMPDIR"
    mkdir -p "$HOME/.openclaw/workspace-hal"
    source "$REPO_ROOT/scripts/09c-oc-core.sh"
    __tac_info() { :; }
    __oc_purge_offline_window() { "$@"; }
    __oc_purge_promote_possible() { return 0; }
    stub_timeout
    openclaw() {
        printf '%s\n' '[secrets] memory promote: gateway secrets.resolve unavailable (ECONNREFUSED); resolved command secrets locally.'
        printf '%s\n' '{"workspaceDir":"/tmp/ws","storePath":"s","lockPath":"l","audit":{"entryCount":512},"candidates":[],"apply":{"applied":0,"appended":0}}'
        return 0
    }
    run __oc_purge_memory_promote_all hal
    [ "$status" -eq 0 ]
    [[ "$output" != *FAILED* ]]
}

@test "promote: a MEMORY.md whose sha changed is the proof the prose was written" {
    export HOME="$TAC_TEST_TMPDIR"
    mkdir -p "$HOME/.openclaw/workspace-hal"
    printf 'before\n' > "$HOME/.openclaw/workspace-hal/MEMORY.md"
    source "$REPO_ROOT/scripts/09c-oc-core.sh"
    # PRINT the verdict: every other case stubs this out, which is why this one asserts on a
    # word the helper emits rather than on an exit code alone.
    __tac_info() { printf '%s\n' "${2:-}"; }
    __oc_purge_offline_window() { "$@"; }
    __oc_purge_promote_possible() { return 0; }
    stub_timeout
    openclaw() {
        printf 'after\n' > "$HOME/.openclaw/workspace-hal/MEMORY.md"
        printf '%s\n' '{"workspaceDir":"/tmp/ws","storePath":"s","lockPath":"l","audit":{},"candidates":[],"apply":{"applied":1}}'
        return 0
    }
    run __oc_purge_memory_promote_all hal
    [ "$status" -eq 0 ]
    [[ "$output" == *"written"* ]]
}

@test "promote probe: the SUCCESS spelling is accepted, a bare secret failure is not" {
    source "$REPO_ROOT/scripts/09c-oc-core.sh"
    __tac_info() { :; }
    stub_timeout
    # A WORKING offline promote still prints the secrets.resolve line and then resolves
    # locally. v46 refused on the first half, so the window never opened on a healthy box.
    openclaw() {
        printf '%s\n' '[secrets] memory promote: gateway secrets.resolve unavailable (ECONNREFUSED); resolved command secrets locally.'
        printf '%s\n' '{"workspaceDir":"/tmp/ws","storePath":"s","lockPath":"l","audit":{},"candidates":[]}'
        return 0
    }
    run __oc_purge_promote_possible hal
    [ "$status" -eq 0 ]

    openclaw() {
        printf '%s\n' '[secrets] memory promote: gateway secrets.resolve unavailable (ECONNREFUSED).'
        return 0
    }
    run __oc_purge_promote_possible hal
    [ "$status" -eq 1 ]
}

@test "flush: the REAL success body has no ok field, and that must NOT refuse the reset" {
    # Measured 2026-11-26 by running a real purge: `memory session-backfill --apply --json`
    # emits agentId, workspaceDir, applied, rem, days, candidateCount, stagedEntries,
    # writtenDiaryEntries, replacedDiaryEntries, batchCount, batches -- and NO `ok`. v46
    # asserted `.ok == true`, so all 14 lanes were refused with "memory flush not proven"
    # and the purge did nothing. This body is copied from a live run.
    export HOME="$TAC_TEST_TMPDIR"
    mkdir -p "$HOME/.openclaw/agents/hal/agent" "$HOME/.openclaw/workspace-hal"
    OC_AGENTS="$HOME/.openclaw/agents"
    source "$REPO_ROOT/scripts/09c-oc-core.sh"
    __tac_info() { :; }
    stub_timeout
    openclaw() {
        printf '%s\n' '{"agentId":"hal","workspaceDir":"/tmp/ws","applied":true,"rem":false,"days":[],'
        printf '%s\n' ' "candidateCount":0,"stagedEntries":0,"writtenDiaryEntries":0,'
        printf '%s\n' ' "replacedDiaryEntries":0,"batchCount":1,"batches":[{"batch":1,"days":0}]}'
        return 0
    }
    run __oc_purge_memory_flush hal
    [ "$status" -eq 2 ]
}

@test "flush: an ERROR body still refuses, because ok:false rides the error path" {
    export HOME="$TAC_TEST_TMPDIR"
    mkdir -p "$HOME/.openclaw/agents/hal/agent" "$HOME/.openclaw/workspace-hal"
    OC_AGENTS="$HOME/.openclaw/agents"
    source "$REPO_ROOT/scripts/09c-oc-core.sh"
    __tac_info() { :; }
    stub_timeout
    openclaw() {
        printf '%s\n' '{"ok":false,"error":{"type":"cli_error","message":"Unknown agent id"}}'
        return 0
    }
    run __oc_purge_memory_flush hal
    [ "$status" -eq 1 ]
}

@test "flush: a body with NEITHER applied nor error is unreadable and refuses" {
    export HOME="$TAC_TEST_TMPDIR"
    mkdir -p "$HOME/.openclaw/agents/hal/agent" "$HOME/.openclaw/workspace-hal"
    OC_AGENTS="$HOME/.openclaw/agents"
    source "$REPO_ROOT/scripts/09c-oc-core.sh"
    __tac_info() { :; }
    stub_timeout
    openclaw() { printf '%s\n' '{"something":"else"}'; return 0; }
    run __oc_purge_memory_flush hal
    [ "$status" -eq 1 ]
}

@test "delete: a batch the CLI cannot SEE is INVISIBLE, not a refusal and not a deletion" {
    # Measured 2026-11-26 in a real purge: 21 `:run:` keys answered
    #   {"ok":false,"status":"not_found","error":"Session not found..."}
    # while the store still held a `session_windows` row for each with status `done`, and
    # `sessions cleanup --fix-missing` did not see them either. Counting that as a refusal
    # failed the whole run for a state the CLI cannot reach; counting it as deleted would
    # claim 21 deletions that did not happen. It is a third thing, so it gets its own count.
    source "$REPO_ROOT/scripts/09c-oc-core.sh"
    __tac_info() { :; }
    stub_timeout
    __oc_purge_session_keys() { printf '%s\n' \
        agent:sarah:cron:j1:run:r1 agent:sarah:cron:j1:run:r2 agent:sarah:main ; }
    openclaw() {
        printf '%s\n' '{"ok":false,"error":{"type":"cli_error","message":"Session delete did not complete for every requested key."},"results":['
        printf '%s\n' '{"key":"agent:sarah:cron:j1:run:r1","ok":false,"status":"not_found"},'
        printf '%s\n' '{"key":"agent:sarah:cron:j1:run:r2","ok":false,"status":"not_found"}]}'
        return 0
    }
    run __oc_purge_delete_sessions
    # 0 deleted, 1 main kept, 0 cron jobs, 2 runs, 0 failures, 2 invisible -- and rc 0,
    # because the CLI did not refuse anything it could have done.
    [ "$status" -eq 0 ]
    [[ "$output" == "0 1 0 2 0 2" ]]
}

@test "delete: a MIXED batch is still a refusal, because part of it could have landed" {
    source "$REPO_ROOT/scripts/09c-oc-core.sh"
    __tac_info() { :; }
    stub_timeout
    __oc_purge_session_keys() { printf '%s\n' agent:sarah:cron:j1:run:r1 agent:sarah:cron:j1:run:r2 ; }
    openclaw() {
        printf '%s\n' '{"ok":false,"error":{"type":"cli_error"},"results":['
        printf '%s\n' '{"key":"agent:sarah:cron:j1:run:r1","ok":false,"status":"not_found"},'
        printf '%s\n' '{"key":"agent:sarah:cron:j1:run:r2","ok":false,"status":"error"}]}'
        return 0
    }
    run __oc_purge_delete_sessions
    [ "$status" -eq 1 ]
    # the body is echoed to the report on a refusal, so match the final line only
    [[ "${lines[-1]}" == "0 0 0 2 1 0" ]]
}

@test "flush: [secrets] chatter ahead of the JSON must not make a healthy body unreadable" {
    # THE DEFECT THAT SURVIVED THE .ok FIX (measured 2026-11-26). The module captures the
    # backfill with `2>&1`, and the CLI writes `[secrets] ...` lines to stderr BEFORE the JSON.
    # jq on that capture fails to parse, so every success check read as failure and a real
    # purge skipped all 14 resets -- while a hand-filtered call of the same command returned 2.
    export HOME="$TAC_TEST_TMPDIR"
    mkdir -p "$HOME/.openclaw/agents/hal/agent" "$HOME/.openclaw/workspace-hal"
    OC_AGENTS="$HOME/.openclaw/agents"
    source "$REPO_ROOT/scripts/09c-oc-core.sh"
    __tac_info() { :; }
    stub_timeout
    openclaw() {
        printf '%s\n' '[secrets] skills.entries.agentmail-cli.apiKey: *** entry is disabled.'
        printf '%s\n' '[secrets] memory promote: gateway secrets.resolve unavailable; resolved locally.'
        printf '%s\n' '{"agentId":"hal","workspaceDir":"/tmp/ws","applied":true,"days":[],"candidateCount":0,"stagedEntries":0}'
        return 0
    }
    run __oc_purge_memory_flush hal
    [ "$status" -eq 2 ]
}
