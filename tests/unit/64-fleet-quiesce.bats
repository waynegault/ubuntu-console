#!/usr/bin/env bats
# ==============================================================================
# Unit — bin/fleet-quiesce.sh: the FLEET GATE that holds a distro reset while
# agent turns are in flight.
# ==============================================================================
# WHY THIS EXISTS (Wayne, 2026-10-18).  A WSL restart kills the gateway, both CI
# runners and every running agent turn.  The restart path already gates on a live
# autotune chunk and a live CI job, and both are about MEASUREMENTS; neither asks
# whether a turn is mid-flight.  The contract these cases pin:
#
#   no work in flight                     -> exit 0 CLEAR
#   any activeWork counter non-zero       -> exit 1 BUSY
#   status JSON without activeWork        -> exit 2 UNKNOWN (never a clear)
#   unparseable / failing status probe    -> exit 2 UNKNOWN (never a clear)
#   --drain, busy then clear              -> waits, then exit 0
#   --drain, busy past the bound          -> exit 1 (the caller SKIPS the restart)
#   --drain, unknown                      -> exit 2 immediately, no wait
#
# FALSIFICATION: a reader that treats a missing key as zero passes the "no
# activeWork" case as CLEAR and fails it here; a reader that returns 0 on a failed
# probe fails the failing-probe case; a drain that does not re-read fails the
# second --drain case (it would report BUSY on the first reading and quit).
#
# HERMETIC: the status command is a stub script passed through
# TAC_FLEET_STATUS_CMD, and the bound/poll are compressed.  No gateway is involved
# and nothing touches Windows.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export REPO_ROOT
    SCRIPT="$REPO_ROOT/bin/fleet-quiesce.sh"
    export SCRIPT

    STUB_DIR="$BATS_TEST_TMPDIR/stub"
    mkdir -p "$STUB_DIR"
    COUNTER="$BATS_TEST_TMPDIR/calls"
    export COUNTER
    : > "$COUNTER"
}

# stub_status — a status command that prints the given JSON and counts its calls.
stub_status() {
    local body="$1"
    local path="$STUB_DIR/status.sh"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'echo x >> "%s"\n' "$COUNTER"
        printf 'cat <<'"'"'JSON'"'"'\n%s\nJSON\n' "$body"
    } > "$path"
    chmod +x "$path"
    export TAC_FLEET_STATUS_CMD="$path"
}

# stub_sequence — prints the Nth line of a sequence on the Nth call, then repeats
# the last line.  This is what proves the drain RE-READS rather than giving up.
stub_sequence() {
    local path="$STUB_DIR/seq.sh"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'n=$(wc -l < "%s")\n' "$COUNTER"
        printf 'echo x >> "%s"\n' "$COUNTER"
        printf 'case "$n" in\n'
        local i=0
        for line in "$@"; do
            printf '  %s) printf "%%s\\n" %q ;;\n' "$i" "$line"
            i=$(( i + 1 ))
        done
        printf '  *) printf "%%s\\n" %q ;;\n' "${!#}"
        printf 'esac\n'
    } > "$path"
    chmod +x "$path"
    export TAC_FLEET_STATUS_CMD="$path"
}

CLEAR_JSON='{"shutdownBudget":{"activeWork":{"rootRequests":0,"cronRuns":0,"sessionMutations":0,"terminalPersistence":0,"lifecycleWrites":0}}}'
BUSY_JSON='{"shutdownBudget":{"activeWork":{"rootRequests":2,"cronRuns":1,"sessionMutations":0,"terminalPersistence":0,"lifecycleWrites":0}}}'
NOAW_JSON='{"sessions":{"count":51},"gateway":{"state":"running"}}'

@test "fleet-quiesce --check is 0 when nothing is in flight" {
    stub_status "$CLEAR_JSON"
    run "$SCRIPT" --check
    [ "$status" -eq 0 ]
    [[ "$output" == *"CLEAR"* ]]
}

@test "fleet-quiesce --check is 1 when any counter is non-zero, and names the counts" {
    stub_status "$BUSY_JSON"
    run "$SCRIPT" --check
    [ "$status" -eq 1 ]
    [[ "$output" == *"BUSY"* ]]
    # The log has to say WHAT held the restart, not merely that something did.
    [[ "$output" == *"rootRequests=2"* ]]
    [[ "$output" == *"cronRuns=1"* ]]
}

@test "fleet-quiesce --check is 2 when the status JSON has no activeWork (never a clear)" {
    stub_status "$NOAW_JSON"
    run "$SCRIPT" --check
    [ "$status" -eq 2 ]
    [[ "$output" == *"UNKNOWN"* ]]
    [[ "$output" != *"CLEAR"* ]]
}

@test "fleet-quiesce --check is 2 when the status probe fails or prints junk" {
    # A command that exits non-zero is an instrument failure, not a quiet fleet.
    stub_status 'not json at all'
    run "$SCRIPT" --check
    [ "$status" -eq 2 ]
    [[ "$output" == *"UNKNOWN"* ]]

    printf '#!/usr/bin/env bash\nexit 7\n' > "$STUB_DIR/broken.sh"
    chmod +x "$STUB_DIR/broken.sh"
    run env TAC_FLEET_STATUS_CMD="$STUB_DIR/broken.sh" "$SCRIPT" --check
    [ "$status" -eq 2 ]
    [[ "$output" == *"UNKNOWN"* ]]
}

@test "fleet-quiesce --drain waits for a busy fleet to clear, then returns 0" {
    stub_sequence "$BUSY_JSON" "$BUSY_JSON" "$CLEAR_JSON"
    run env TAC_FLEET_BOUND_S=20 TAC_FLEET_POLL_S=1 "$SCRIPT" --drain
    [ "$status" -eq 0 ]
    [[ "$output" == *"CLEAR after"* ]]
    # Three readings: two busy, then clear.  A single-reading implementation fails here.
    [ "$(wc -l < "$COUNTER")" -ge 3 ]
}

@test "fleet-quiesce --drain returns 1 when the fleet is still busy at the bound" {
    stub_status "$BUSY_JSON"
    run env TAC_FLEET_BOUND_S=1 TAC_FLEET_POLL_S=1 "$SCRIPT" --drain
    [ "$status" -eq 1 ]
    [[ "$output" == *"STILL BUSY"* ]]
}

@test "fleet-quiesce --drain does NOT wait on an unknown reading - a broken probe will not heal in 20s" {
    stub_status "$NOAW_JSON"
    run env TAC_FLEET_BOUND_S=30 TAC_FLEET_POLL_S=1 "$SCRIPT" --drain
    [ "$status" -eq 2 ]
    # Exactly one reading: the caller fails closed immediately.
    [ "$(wc -l < "$COUNTER")" -eq 1 ]
}

@test "fleet-quiesce --quiet drops the per-poll commentary but never the verdict" {
    # A silent gate is unusable in a post-mortem: --quiet exists for a caller that
    # logs once, so the one-line verdict is KEPT and only drain commentary is dropped.
    stub_status "$BUSY_JSON"
    run "$SCRIPT" --check --quiet
    [ "$status" -eq 1 ]
    [[ "$output" == *"BUSY"* ]]
    [ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ]
}
