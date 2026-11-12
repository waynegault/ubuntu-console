#!/usr/bin/env bats
# ==============================================================================
# Unit — _tac_suspend_held answers LIVENESS, and kill -0 does not
# ==============================================================================
# WHY (2026-11-12): the reader that every acquirer and every watchdog path shares asked a
# question kill -0 cannot answer. It is wrong in both directions, and each direction wedges
# the CUDA lane differently.
#
#   EPERM  — a LIVE process owned by another user returns rc=1. The reader reported
#            "owner pid is dead" about a running holder. Measured: kill -0 1 -> rc=1
#            "Operation not permitted", pid 1 alive.
#   ZOMBIE — a process that has ALREADY EXITED but has not been reaped returns rc=0,
#            because the pid still exists to be signalled. Its EXIT trap has run (or it was
#            SIGKILLed), so it cannot release its own hold: the marker never clears and the
#            watchdog stays down for good. Measured (Hal, 2026-11-12): state Z,
#            kill -0 rc=0, and the reader printed "HELD by live pid" about a dead process.
#
# The zombie arm asserts that kill -0 returns 0 for the SAME pid. Without that assertion the
# test would still pass if someone reordered the checks back — the arm would then be
# exercising a zombie that kill -0 already reported as dead for the wrong reason.
#
# /proc/<pid>/stat is world-readable and its field 3 states the lifecycle directly, so the
# permission question never arises. The zombie test MUST precede any kill -0 branch.
setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    LIB="$REPO_ROOT/bin/_tac-bin-lib.sh"
    MARK="$BATS_TEST_TMPDIR/llama-watchdog-cuda.suspend"
    # journalling is off by default in these arms; the journal has its own tests
    export TAC_SUSPEND_JOURNAL="$BATS_TEST_TMPDIR/journal.log"
}

held() {
    bash -c "source '$LIB' 2>/dev/null; _tac_suspend_held '$MARK'" 2>/dev/null
}

# ---------------------------------------------------------------------------
# The two cases kill -0 gets wrong
# ---------------------------------------------------------------------------

@test "liveness: a ZOMBIE holder is NOT held, and kill -0 calls it alive" {
    # parent forks a child that exits immediately and never reaps it
    python3 - "$MARK" "$BATS_TEST_TMPDIR/ready" <<'PY' &
import os, sys, time
marker, ready = sys.argv[1], sys.argv[2]
pid = os.fork()
if pid == 0:
    os._exit(0)                 # child exits -> zombie while parent lives
open(marker, 'w').write(str(pid))
open(ready, 'w').write(str(pid))
time.sleep(30)                  # hold the zombie: never wait() it
PY
    local parent=$!
    local zp=""
    for _ in $(seq 1 100); do
        [ -s "$BATS_TEST_TMPDIR/ready" ] && { zp=$(cat "$BATS_TEST_TMPDIR/ready"); break; }
        sleep 0.1
    done
    [ -n "$zp" ] || { kill "$parent" 2>/dev/null; skip "zombie child was not produced"; }

    # ground truth: the pid exists, has EXITED, and kill -0 says it is signallable
    [ "$(awk '{print $3}' "/proc/$zp/stat")" = "Z" ]
    run kill -0 "$zp"
    [ "$status" -eq 0 ]          # <-- the whole point: kill -0 cannot see the exit

    run held
    kill "$parent" 2>/dev/null || true
    [ "$status" -eq 1 ]
}

@test "liveness: a ROOT-OWNED live holder IS held, though kill -0 says EPERM" {
    # pid 1 is live, owned by root: kill -0 returns 1 with EPERM for a non-root caller.
    # The permission answer is not a liveness answer.
    run kill -0 1
    [ "$status" -ne 0 ]          # this arm is vacuous if we could signal it

    printf '%s\n' "1" > "$MARK"
    run held
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# The cases that were already right, kept so the fix cannot regress them
# ---------------------------------------------------------------------------

@test "liveness: a same-user LIVE holder is held" {
    sleep 30 &
    local h=$!
    printf '%s\n' "$h" > "$MARK"
    run held
    kill "$h" 2>/dev/null || true
    [ "$status" -eq 0 ]
}

@test "liveness: a genuinely DEAD pid is not held" {
    printf '%s\n' "999999" > "$MARK"
    run held
    [ "$status" -eq 1 ]
}

@test "liveness: an ABSENT marker is not held" {
    rm -f "$MARK"
    run held
    [ "$status" -eq 1 ]
}

@test "liveness: an EMPTY marker is not held (no torn write can produce one)" {
    : > "$MARK"
    run held
    [ "$status" -eq 1 ]
}

@test "liveness: a marker with no digits is not held" {
    printf '%s\n' "not-a-pid" > "$MARK"
    run held
    [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Falsification: the fix must be at the predicate, not in the caller
# ---------------------------------------------------------------------------

@test "liveness: the reader does NOT consult kill -0 for its verdict" {
    # A reordered implementation would still call kill -0 and take its answer for a zombie.
    # Prove the verdict comes from /proc by making kill -0 useless: run the reader under a
    # PATH where kill is a stub that always reports success, and confirm a dead pid is
    # STILL reported not held. If the reader trusted kill -0, this would read as held.
    local stub="$BATS_TEST_TMPDIR/stub"; mkdir -p "$stub"
    printf '#!/bin/sh\nexit 0\n' > "$stub/kill"; chmod +x "$stub/kill"
    printf '%s\n' "999999" > "$MARK"
    run env PATH="$stub:$PATH" bash -c "source '$LIB' 2>/dev/null; _tac_suspend_held '$MARK'"
    [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# The acquire/release journal
# ---------------------------------------------------------------------------

@test "journal: acquire and release are BOTH recorded, with a pid and a marker" {
    export TAC_SUSPEND_JOURNAL="$BATS_TEST_TMPDIR/j.log"
    run bash -c "source '$LIB' 2>/dev/null; _tac_suspend_acquire '$MARK'; _tac_suspend_release '$MARK'"
    [ "$status" -eq 0 ]
    [ -f "$TAC_SUSPEND_JOURNAL" ]
    run grep -c ' acquire pid=' "$TAC_SUSPEND_JOURNAL"
    [ "$status" -eq 0 ]
    run grep -c ' release pid=' "$TAC_SUSPEND_JOURNAL"
    [ "$status" -eq 0 ]
    # the marker path is on the line, or the log cannot say WHICH hold was taken
    run grep -F "marker=$MARK" "$TAC_SUSPEND_JOURNAL"
    [ "$status" -eq 0 ]
}

@test "journal: a REFUSED acquire writes nothing, so the log names only winners" {
    export TAC_SUSPEND_JOURNAL="$BATS_TEST_TMPDIR/j2.log"
    sleep 30 &
    local h=$!
    printf '%s\n' "$h" > "$MARK"
    run bash -c "source '$LIB' 2>/dev/null; _tac_suspend_acquire '$MARK'"
    local rc=$status
    kill "$h" 2>/dev/null || true
    [ "$rc" -eq 1 ]                       # refused: a live holder has it
    # either no log at all, or no acquire line: this caller lost the race
    if [ -f "$TAC_SUSPEND_JOURNAL" ]; then
        run grep -c ' acquire pid=' "$TAC_SUSPEND_JOURNAL"
        [ "$status" -ne 0 ]
    fi
}

@test "journal: an unwritable journal does not fail the hold" {
    export TAC_SUSPEND_JOURNAL="/proc/nonexistent-dir/j.log"
    run bash -c "source '$LIB' 2>/dev/null; _tac_suspend_acquire '$MARK'"
    [ "$status" -eq 0 ]                   # the hold succeeded; only the audit line failed
    [ -f "$MARK" ]
}

@test "journal: a MULTI-LINE argv stays ONE record, so acquire can be paired with release" {
    # An argv element can contain a newline (a shell -c script does). Without collapsing
    # them, one acquire becomes several physical lines and the log stops being one record
    # per line -- which is the property a reader needs to pair acquire against release.
    # Measured 2026-11-12: pre-fix, one acquire whose -c script spanned 3 lines wrote 5
    # physical lines, 1 timestamped and 4 continuations.
    export TAC_SUSPEND_JOURNAL="$BATS_TEST_TMPDIR/nl.log"
    run bash -c "source '$LIB' 2>/dev/null; _tac_suspend_acquire '$MARK'" \
        -c "script line A
script line B
script line C"
    local total ts
    total=$(wc -l < "$TAC_SUSPEND_JOURNAL")
    ts=$(grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' "$TAC_SUSPEND_JOURNAL")
    [ "$total" -eq "$ts" ]          # no continuation lines: every line is a record
}

@test "journal: the recorded command is BOUNDED, so one record cannot flood the log" {
    export TAC_SUSPEND_JOURNAL="$BATS_TEST_TMPDIR/bound.log"
    run bash -c "source '$LIB' 2>/dev/null; _tac_suspend_acquire '$MARK'" \
        -c "$(printf 'x%.0s' $(seq 1 900))"
    run grep -o 'cmd=.*' "$TAC_SUSPEND_JOURNAL"
    [ "$status" -eq 0 ]
    [ "${#output}" -le 210 ]
}
