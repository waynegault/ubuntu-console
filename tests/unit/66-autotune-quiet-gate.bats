#!/usr/bin/env bats
# ==============================================================================
# Unit — the autotune pre-claim FLEET gate
# ==============================================================================
# WHY (Wayne, 2026-10-19: "version the quiet-gate into ubuntu-console with a test").  The gate
# decides whether the autotune resume loop may claim a plan: a live agent turn means a measurement
# would contend with it, so the campaign waits.
#
# It shipped first as MACHINE-LOCAL code at ~/.openclaw/bin/autotune-resume-quiet-gate.py, where
# nothing tested it — and it then held the campaign for hours on three `session_windows` rows left
# `running` by cron sessions from 2026-09-01, 09-04 and 09-10 (39-48 days old).  Reading
# `status='running'` alone, the gate could NEVER clear.  The staleness bound that fixes it is the
# behaviour pinned below.
#
# Hermetic: FLEET_AGENT_DB_GLOB points at this test's temp tree, so no real agent database is read.
setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export GATE="$REPO_ROOT/bin/autotune-resume-quiet-gate.py"
    export TMP="$BATS_TEST_TMPDIR"
    export FLEET_AGENT_DB_GLOB="$TMP/agents/*/agent/openclaw-agent.sqlite"
    # The SHIPPED bound; a case that needs another value overrides it locally.
    unset FLEET_STALE_AFTER_S
}

# make_db <agent> <status> <last_update_ms>
make_db() {
    local agent="$1" status="$2" last="$3"
    mkdir -p "$TMP/agents/$agent/agent"
    python3 - "$TMP/agents/$agent/agent/openclaw-agent.sqlite" "$status" "$last" <<'PY'
import sqlite3, sys

db, status, last = sys.argv[1], sys.argv[2], int(sys.argv[3])
con = sqlite3.connect(db)
con.execute(
    "CREATE TABLE session_windows (session_key TEXT, status TEXT,"
    " updated_at INTEGER, created_at INTEGER)"
)
con.execute(
    "INSERT INTO session_windows VALUES (?,?,?,?)",
    (f"agent:x:cron:{status}", status, last, last),
)
con.commit()
con.close()
PY
}

now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }

@test "quiet-gate: a LIVE turn BLOCKS the plan claim" {
    make_db hal running "$(now_ms)"

    run python3 "$GATE" --check
    [ "$status" -eq 1 ]
    [[ "$output" == *"1 running turn(s): hal:agent:x:cron:running"* ]]
}

@test "quiet-gate: a running row last written 48 days ago does NOT block, and is NAMED" {
    # The measured defect: three such rows held the campaign for hours.
    make_db hal running "$(( $(now_ms) - 48 * 86400 * 1000 ))"

    run python3 "$GATE" --check
    [ "$status" -eq 0 ]
    [[ "$output" == *"IGNORING 1 STALE window(s)"* ]]
    [[ "$output" == *"48d"* ]]
    [[ "$output" == *"fleet is quiet"* ]]
}

@test "quiet-gate: a finished window does not block (control)" {
    make_db hal done "$(now_ms)"

    run python3 "$GATE" --check
    [ "$status" -eq 0 ]
    [[ "$output" == *"fleet is quiet"* ]]
}

@test "quiet-gate: the staleness bound is the seam, so a fresh row past it blocks again" {
    # Same 48-day-old row, but with the bound widened past its age: it is a live turn again.
    make_db hal running "$(( $(now_ms) - 48 * 86400 * 1000 ))"
    export FLEET_STALE_AFTER_S=$(( 60 * 86400 * 1000 / 1000 ))

    run python3 "$GATE" --check
    [ "$status" -eq 1 ]
    [[ "$output" == *"running turn(s)"* ]] || [[ "$output" == *"running turn(s):"* ]]
}

@test "quiet-gate: no agent databases REFUSES to arm (fail closed)" {
    mkdir -p "$TMP/agents"

    run python3 "$GATE" --check
    [ "$status" -eq 2 ]
    [[ "$output" == *"no agent DBs match"* ]]
}

@test "quiet-gate: an unreadable database REFUSES to arm (fail closed)" {
    mkdir -p "$TMP/agents/hal/agent"
    printf 'not a sqlite database' > "$TMP/agents/hal/agent/openclaw-agent.sqlite"

    run python3 "$GATE" --check
    [ "$status" -eq 2 ]
    [[ "$output" == *"cannot read"* ]]
}
