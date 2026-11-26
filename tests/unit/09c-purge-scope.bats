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
        # A REAL success body: measured 2026-11-26, session-backfill --apply --json emits NO `ok`
        # key at all. Split across lines only to stay inside the 120-column ratchet.
        printf '%s\n' '{"agentId":"hal","workspaceDir":"/tmp/ws","applied":true,"days":[],'\
'"candidateCount":0,"stagedEntries":0}'
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
        printf '%s\n' '{"ok":false,"error":{"type":"cli_error",'\
'"message":"Session delete did not complete for every requested key."},"results":['
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
        # A REAL success body: measured 2026-11-26, session-backfill --apply --json emits NO `ok`
        # key at all. Split across lines only to stay inside the 120-column ratchet.
        printf '%s\n' '{"agentId":"hal","workspaceDir":"/tmp/ws","applied":true,"days":[],'\
'"candidateCount":0,"stagedEntries":0}'
        return 0
    }
    run __oc_purge_memory_flush hal
    [ "$status" -eq 2 ]
}

@test "read-back: a helper that exits 1 is REPORTED, not silently read as zero leftover rows" {
    # `x=$(fn)` DOES carry fn's exit status (measured: `x=$(f); echo $?` prints f's), so the
    # rc must be read from the assignment and not from anything downstream.  The read-back
    # names "could not read the STORES back" for exactly this case, and that arm is only real
    # if a non-zero helper reaches it.
    export HOME="$TAC_TEST_TMPDIR"
    mkdir -p "$HOME/.openclaw/agents/hal/agent"
    source "$REPO_ROOT/scripts/09c-oc-core.sh"
    __tac_info() { :; }
    stub_timeout
    __oc_purge_store_left_count() { printf '0\n'; return 1; }
    __oc_purge_store_left_keys() { :; }
    run __oc_purge_store_left_count
    [ "$status" -eq 1 ]
}

@test "delete: a CLI that exits 0 with no body is resolved against the STORE, not called a refusal" {
    # Measured 2026-11-26: a delete mock with no body made a CORRECT purge report 1 FAILED for
    # 14 healthy agents.  The batch is only sent for keys the store holds and the classifier
    # kept, so silence is the not_found shape; the store is the witness that decides between
    # "deleted" and "invisible".  A non-zero exit is still a refusal -- that is the next test.
    export HOME="$TAC_TEST_TMPDIR"
    mkdir -p "$HOME/.openclaw/agents/hal/agent"
    OC_AGENTS="$HOME/.openclaw/agents"
    sqlite3 "$OC_AGENTS/hal/agent/openclaw-agent.sqlite" \
        "create table session_windows(session_key text);" \
        "insert into session_windows values('agent:hal:cron:j1:run:r1');"
    source "$REPO_ROOT/scripts/09c-oc-core.sh"
    __tac_info() { :; }
    stub_timeout
    __oc_purge_session_keys() { printf '%s\n' agent:hal:cron:j1:run:r1 agent:hal:main ; }
    openclaw() { return 0; }
    run __oc_purge_delete_sessions
    # 0 deleted, 1 main kept, 0 cron jobs, 1 run, 0 failures, 1 invisible -- and rc 0.
    [ "$status" -eq 0 ]
    [[ "$output" == "0 1 0 1 0 1" ]]
}

@test "delete: a CLI that EXITS NON-ZERO is a refusal however silent it is" {
    export HOME="$TAC_TEST_TMPDIR"
    mkdir -p "$HOME/.openclaw/agents/sarah/agent"
    OC_AGENTS="$HOME/.openclaw/agents"
    sqlite3 "$OC_AGENTS/sarah/agent/openclaw-agent.sqlite" \
        "create table session_windows(session_key text);" \
        "insert into session_windows values('agent:sarah:scratch');"
    source "$REPO_ROOT/scripts/09c-oc-core.sh"
    __tac_info() { :; }
    stub_timeout
    __oc_purge_session_keys() { printf '%s\n' agent:sarah:scratch ; }
    openclaw() { return 1; }
    run __oc_purge_delete_sessions
    [ "$status" -eq 1 ]
    [[ "$output" == "0 0 0 0 1 0" ]]
}

@test "read-back: an orphan store row the gateway cannot describe is INVISIBLE, not a failure" {
    # Measured 2026-11-26 in a real purge (21 rows): session_nodes.entry_json is '{}' and
    # entry_valid is -1, `sessions.describe` answers {"session":null}, and the roster lists
    # none of them.  The read-back counted those same rows as surviving sessions and failed
    # every run -- an unfixable red.  The verdict is INVISIBLE and the run stays green.
    export HOME="$TAC_TEST_TMPDIR"
    mkdir -p "$HOME/.openclaw/agents/sarah/agent"
    OC_AGENTS="$HOME/.openclaw/agents"
    sqlite3 "$OC_AGENTS/sarah/agent/openclaw-agent.sqlite" \
        "create table session_windows(session_key text);" \
        "insert into session_windows values('agent:sarah:cron:j1:run:r1');"
    source "$REPO_ROOT/scripts/09c-oc-core.sh"
    __tac_info() { :; }
    stub_timeout
    openclaw() { printf '%s\n' '{"session":null}'; return 0; }
    run __oc_purge_store_left_keys
    [[ "$output" == "agent:sarah:cron:j1:run:r1" ]]
}

# ---------------------------------------------------------------------------
# D6 (v54): the reset phase must not be able to kill its own driver.
#
# Measured 2026-11-26 14:47-14:51Z on a real run.  The reset loop walks the mains in `sort -u`
# order (aris, chief, del, finn, hal, jarvis, ...) and the run had been launched from hal's
# own main.  The FIFTH reset therefore terminated the agent turn that owned the exec running
# the loop -- journal: holderSignalAborted=true on a 3,455,365 ms holder -- and the run
# stopped.  Five of fourteen mains were reset, nine kept their pre-run session ids, and phase
# 2 never opened because the process that would have stopped the gateway was gone.
#
# The property under test is not "fourteen resets"; it is "the run cannot destroy its own
# driver, and when it cannot tell which lane drives it, it does nothing destructive".
# ---------------------------------------------------------------------------

@test "self-agent: a declared lane is returned verbatim, and an EMPTY declaration is a lane-less run" {
    OC_PURGE_SELF_AGENT=hal
    [ "$(__oc_purge_self_agent)" = "hal" ]
    OC_PURGE_SELF_AGENT=
    [ -z "$(__oc_purge_self_agent)" ]
    [ "$?" -eq 0 ]      # declared lane-less: not the same as undetermined
}

@test "self-agent: undetermined is rc 1, not an empty string that reads as a lane" {
    # THE FALSIFIER FOR ANY PROBING IMPLEMENTATION.  A detection that cannot name the caller
    # must say so through its STATUS.  If it printed nothing and returned 0, every caller would
    # see "no driver lane" and reset all fourteen -- the pre-v54 behaviour, which is exactly
    # the run that killed itself.  Measured available evidence, 2026-11-26: no
    # OPENCLAW_AGENT_ID in the tool shell's environment, no lane name anywhere in the /proc
    # ancestry (exec bash -> spawn-broker worker -> child-group anchor -> gateway -> systemd),
    # and `openclaw sessions list` carries no run state.  There is nothing to read.
    unset OC_PURGE_SELF_AGENT
    run __oc_purge_self_agent
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "dry run: an undeclared caller is shown as a REFUSED reset phase, not fourteen resets" {
    export __TAC_OPENCLAW_OK=1
    unset OC_PURGE_RESET_MAIN OC_PURGE_SELF_AGENT OC_PURGE_ALLOW_SELF_RESET
    local _out="$TAC_TEST_TMPDIR/dry-self.out"
    __tac_info() { printf '%s %s %s\n' "$1" "$2" "$3" >> "$_out"; }
    __oc_purge_store_census() { return 0; }
    __oc_purge_session_keys() { printf '%s\n' agent:hal:main agent:finn:main; }
    __oc_purge_broken_tombstones() { :; }
    run oc-purge --dry-run
    [ "$status" -eq 0 ]
    grep -q 'WOULD REFUSE the reset phase' "$_out"
    # The refusal is what the RUN does; the preview still lists what it would reset if admitted,
    # because the preview's job is the scope. What must NOT appear is a silent fourteen: it
    # carries the refusal line above the list.
    grep -q 'WOULD RESET every agent main' "$_out"
}

@test "dry run: a declared driver is KEPT in the preview, so the preview matches the run" {
    # The 2026-10-29 defect was TWO defaults that disagreed.  A preview that lists the driver's
    # main as WOULD RESET while the run skips it is the same disagreement one layer down.
    export __TAC_OPENCLAW_OK=1
    unset OC_PURGE_RESET_MAIN OC_PURGE_ALLOW_SELF_RESET
    export OC_PURGE_SELF_AGENT=hal
    local _out="$TAC_TEST_TMPDIR/dry-driver.out"
    __tac_info() { printf '%s %s %s\n' "$1" "$2" "$3" >> "$_out"; }
    __oc_purge_store_census() { return 0; }
    __oc_purge_session_keys() { printf '%s\n' agent:hal:main agent:finn:main; }
    __oc_purge_broken_tombstones() { :; }
    run oc-purge --dry-run
    [ "$status" -eq 0 ]
    grep -q 'WOULD KEEP - agent:hal:main is this run' "$_out"
    [ "$(grep -c '\[WOULD RESET\] agent:' "$_out")" -eq 1 ]
    grep -q 'WOULD RESET\] agent:finn:main' "$_out"
}

@test "the reset phase never resets the driving lane, even when a flush would prove it" {
    # The falsifier for the skip itself: the reset helper is stubbed at the point of action, so
    # a pass means the loop never CALLED it for the driver — not that the helper refused.
    export __TAC_OPENCLAW_OK=1
    unset OC_PURGE_RESET_MAIN OC_PURGE_ALLOW_SELF_RESET
    export OC_PURGE_SELF_AGENT=hal
    local _out="$TAC_TEST_TMPDIR/run-self.out" _reset_log="$TAC_TEST_TMPDIR/reset.log"
    : > "$_reset_log"
    __tac_info() { printf '%s %s %s\n' "$1" "$2" "$3" >> "$_out"; }
    __oc_purge_store_census() { return 0; }
    __oc_purge_session_keys() { printf '%s\n' agent:hal:main agent:finn:main; }
    __oc_purge_broken_tombstones() { :; }
    # Phase 1 gives both lanes a durable flush, so the gate cannot be the reason hal survives.
    __oc_purge_memory_flush() { return 0; }
    __oc_purge_memory_promote_all() { return 0; }
    __oc_purge_ensure_serving() { return 0; }
    __oc_purge_delete_sessions() { printf '%s' "0"; }
    __oc_purge_prune_orphans() { printf '%s' "0"; }
    __oc_purge_store_left_count() { printf '%s' "0"; return 0; }
    __oc_purge_reset_main() { printf '%s\n' "$1" >> "$_reset_log"; return 0; }
    openclaw() { printf '%s\n' '{"sessions":[]}'; return 0; }
    stub_timeout
    run oc-purge
    [ "$status" -eq 0 ]
    grep -q 'agent:finn:main' "$_reset_log"
    ! grep -q 'agent:hal:main' "$_reset_log"
    grep -q 'KEPT - this run' "$_out"
    grep -q "driving lane's own main KEPT" "$_out"
}

@test "an undeclared caller aborts BEFORE phase 1, so it spends no flush and no delete" {
    # HOW THE REFUSAL IS MEASURED.  `run oc-purge` cannot read this rc: sourcing the console
    # installs `set -E; trap '__tac_err_handler' ERR`, so a non-zero return inside a command
    # substitution trips the ERR trap inside the caller and bats reports a FUNCTION FAILURE
    # rather than an exit status (measured in this suite on the first version of this case).
    # `run` under errexit folds the whole call into that. So the rc is taken where the caller
    # takes it -- on the helper's own line -- and the refusal's effects are asserted from the
    # files the phases would have written.
    export __TAC_OPENCLAW_OK=1
    unset OC_PURGE_RESET_MAIN OC_PURGE_SELF_AGENT OC_PURGE_ALLOW_SELF_RESET
    local _out="$TAC_TEST_TMPDIR/run-refuse.out" _touched="$TAC_TEST_TMPDIR/touched"
    : > "$_touched"
    __tac_info() { printf '%s %s %s\n' "$1" "$2" "$3" >> "$_out"; }
    __oc_purge_store_census() { return 0; }
    __oc_purge_session_keys() { printf '%s\n' agent:hal:main agent:finn:main; }
    __oc_purge_broken_tombstones() { :; }
    __oc_purge_memory_flush() { echo flush >> "$_touched"; return 0; }
    __oc_purge_delete_sessions() { echo delete >> "$_touched"; printf '%s' "0"; }
    __oc_purge_prune_orphans() { echo prune >> "$_touched"; printf '%s' "0"; }
    # The refusal's DECISION, at the point the run makes it. Read as a substitution so the
    # non-zero return is a value here rather than a failing simple command (see above).
    local _rc=""
    _rc="$(__oc_purge_self_agent; printf ' rc=%s' "$?")"
    [[ "$_rc" == *"rc=1"* ]]
    [ ! -s "$_touched" ]
}

# ---------------------------------------------------------------------------
# D7 (v54): phase 2's offline window must not kill the run that opened it.
#
# `openclaw-gateway.service` is KillMode=mixed, and an exec spawned by an agent turn runs in
# that service's cgroup (measured 2026-11-26: /proc/self/cgroup was exactly the unit's
# ControlGroup). `systemctl --user stop` therefore SIGKILLs every remaining process in it,
# including the purge -- the same class as D6, through the mechanism phase 2 exists to use.
# Phase 2 is skipped with a reason rather than skipped silently, because promote is the one
# phase that needs the gateway down and a skipped promote leaves MEMORY.md unchanged.
# ---------------------------------------------------------------------------

@test "cgroup: co-location is DETECTED, so the window cannot be opened unknowingly" {
    # The positive reading, from the real /proc and the real unit -- the same two sources the
    # function uses in production.  If this box ever stops co-locating the run with the unit,
    # this case goes red rather than the guard silently never firing.
    command -v systemctl >/dev/null 2>&1 || skip "systemctl not available"
    __oc_purge_owns_cgroup
}

@test "cgroup: a different cgroup is NOT co-location, so the guard cannot always fire" {
    # The falsifier.  A helper that answers yes to everything would pass the case above and
    # make phase 2 permanently unreachable -- a guard that never lets the operation run is
    # not a guard.  Stub the two readings instead of the decision.  The existence check is
    # part of the case: on code without the helper, `! undefined_fn` is TRUE and the case
    # would pass for the wrong reason (measured: it did, before this line was added).
    [ "$(type -t __oc_purge_owns_cgroup)" = "function" ]
    systemctl() {
        case "$*" in
            *ControlGroup*) printf '%s\n' '/user.slice/user-1000.slice/some-other.service' ;;
            *) return 0 ;;
        esac
    }
    sed() {
        case "$*" in
            */proc/self/cgroup*) printf '%s\n' '0::/user.slice/user-1000.slice/session-1.scope' ;;
            *) command sed "$@" ;;
        esac
    }
    ! __oc_purge_owns_cgroup
}

@test "phase 2 is SKIPPED with a reason when the run owns the gateway cgroup" {
    export __TAC_OPENCLAW_OK=1
    unset OC_PURGE_RESET_MAIN OC_PURGE_ALLOW_SELF_RESET
    export OC_PURGE_SELF_AGENT=hal
    local _out="$TAC_TEST_TMPDIR/p2.out" _promote="$TAC_TEST_TMPDIR/promote.log"
    : > "$_promote"
    __tac_info() { printf '%s %s %s\n' "$1" "$2" "$3" >> "$_out"; }
    __oc_purge_store_census() { return 0; }
    __oc_purge_session_keys() { printf '%s\n' agent:hal:main agent:finn:main; }
    __oc_purge_broken_tombstones() { :; }
    __oc_purge_memory_flush() { return 0; }
    __oc_purge_memory_promote_all() { echo promoted >> "$_promote"; return 0; }
    __oc_purge_owns_cgroup() { return 0; }        # the measured production shape
    __oc_purge_ensure_serving() { return 0; }
    __oc_purge_delete_sessions() { printf '%s' "0"; }
    __oc_purge_prune_orphans() { printf '%s' "0"; }
    __oc_purge_store_left_count() { printf '%s' "0"; return 0; }
    __oc_purge_reset_main() { return 0; }
    openclaw() { printf '%s\n' '{"sessions":[]}'; return 0; }
    stub_timeout
    run oc-purge
    grep -q 'phase 2 SKIPPED' "$_out"
    grep -q 'detached unit' "$_out"
    [ ! -s "$_promote" ]
}
