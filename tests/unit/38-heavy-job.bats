#!/usr/bin/env bats
# ==============================================================================
# Unit — bin/heavy-job: one saturating job at a time, and the WIRING that makes it bite
# ==============================================================================
# WHY (2026-10-01).  Measured 2026-09-29 23:43: load 24.82/22.61/19.61 on a 16-core box,
# the top consumers an investigator `mypy pipeline`, three investigator REPLs, an
# `ubuntu-console kgraph update` and llama-server; agent turns took ~11.5 minutes to
# reach model_call_started.  The Gateway's cgroup weight protects the CONTROL PLANE — it
# does not reduce the load.  bin/heavy-job is the missing coordination: ONE exclusive
# flock, held for the whole run, self-releasing on death (SIGKILL included).
#
# WHAT THIS SUITE IS FOR.  A wrapper nobody routes through blocks nothing, and a case
# that calls the wrapper DIRECTLY proves only that the wrapper works — it cannot see
# whether a saturating job was actually wired up.  That failure already happened in this
# repo: five passing cases called a helper directly while the row was wired into the
# WRONG command, so nothing real ever called it.  The acceptance case below therefore
# runs the REAL wired script, with the lock held by a second heavy-job, and asserts the
# observable Wayne specified:
#
#     "with a second `heavy-job` job running, the wired command prints
#      `heavy-job: waiting for the heavy-job lock...` and does not run concurrently;
#      `heavy-job --status` afterwards reads free."
#
# The expected values come from that criterion, not from this implementation: the wait is
# observed as ELAPSED WALL TIME, which a pass-through cannot fake, and the "did not run
# concurrently" claim is that measurement rather than a log line.
#
# Hermetic: HEAVY_JOB_LOCK points under $BATS_TEST_TMPDIR, so no case touches the real
# /tmp/heavy-job.lock and no case can queue behind — or hold off — a heavy job on this
# box.  HEAVY_JOB_HELD is cleared for every invocation on purpose: this suite may itself
# be run by tools/run-tests.sh, which now HOLDS the box-wide lock and exports that mark,
# and a pass-through would otherwise silently skip the very path under test.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    HJ="$REPO_ROOT/bin/heavy-job"
    HLOCK="$BATS_TEST_TMPDIR/heavy-job.lock"
}

# Hold the lock with a real second heavy-job until it is demonstrably held.  Polling
# rather than sleeping a fixed amount: the point of the acceptance case is that the
# wired command meets a HELD lock, so the test must not race the holder's own startup.
_hold_lock() {
    env -u HEAVY_JOB_HELD HEAVY_JOB_LOCK="$HLOCK" "$HJ" sleep "${1:-3}" &
    _HOLDER_PID=$!
    local _i
    for _i in $(seq 1 60); do
        env -u HEAVY_JOB_HELD HEAVY_JOB_LOCK="$HLOCK" "$HJ" --status | grep -q BUSY && return 0
        sleep 0.1
    done
    echo "the holder never took the lock — cannot test serialisation" >&2
    return 1
}

# ── 1. The wrapper itself ────────────────────────────────────────────────────

@test "heavy-job: --status reads free when nothing holds the lock" {
    run env -u HEAVY_JOB_HELD HEAVY_JOB_LOCK="$HLOCK" "$HJ" --status
    [ "$status" -eq 0 ]
    [[ "$output" == "heavy-job: free"* ]]
}

@test "heavy-job: a held lock reads BUSY and names the holder" {
    _hold_lock 3
    run env -u HEAVY_JOB_HELD HEAVY_JOB_LOCK="$HLOCK" "$HJ" --status
    [[ "$output" == "heavy-job: BUSY"* ]]
    [[ "$output" == *"sleep 3"* ]]
    wait "$_HOLDER_PID"
    run env -u HEAVY_JOB_HELD HEAVY_JOB_LOCK="$HLOCK" "$HJ" --status
    [[ "$output" == "heavy-job: free"* ]]
}

# The masking bug 1.0.0 shipped: `touch "$LOCK" 2>/dev/null || true` followed by
# `flock -n "$LOCK" -c true` read an UNUSABLE lock path as "somebody holds it", so a real
# failure was reported as contention.  The criterion is that an unusable lock path is an
# ERROR — never a fabricated BUSY, and never a fabricated free.
@test "heavy-job: an unusable lock path is an ERROR, not a false BUSY or free" {
    run env -u HEAVY_JOB_HELD HEAVY_JOB_LOCK="$BATS_TEST_TMPDIR/no/such/dir/hj.lock" \
        "$HJ" --status
    [ "$status" -eq 4 ]
    [[ "$output" == *"cannot create or read the lock file"* ]]
}

@test "heavy-job: an unusable lock path fails the JOB rather than running it unlocked" {
    # Same failure, the other entry point: a job that cannot take the lock must NOT run
    # as if it had.  The wrapped command here would create a file, so the file's absence
    # is the observable — not the exit status alone.
    local sentinel="$BATS_TEST_TMPDIR/sentinel"
    run env -u HEAVY_JOB_HELD HEAVY_JOB_LOCK="$BATS_TEST_TMPDIR/no/such/dir/hj.lock" \
        "$HJ" touch "$sentinel"
    [ "$status" -ne 0 ]
    [ ! -e "$sentinel" ]
}

# ── 2. Re-entrancy: the nesting the wired flows actually do ──────────────────
# The autotune batch calls the per-model autotuner; the band re-tune calls the batch.  A
# second flock on a lock our OWN ancestor holds does not re-enter — flock is per open file
# description — it blocks, and the flow deadlocks against itself.  The discriminator is
# the exit status: 2 is the script's own usage exit, whereas a deadlock is killed by the
# timeout (124) instead.

@test "heavy-job: a wired script nested in a heavy session passes through (no self-deadlock)" {
    run timeout 10 env -u HEAVY_JOB_HELD HEAVY_JOB_LOCK="$HLOCK" \
        "$HJ" bash "$REPO_ROOT/scripts/retune-band-chunk.sh"
    [ "$status" -eq 2 ]
    [[ "$output" == *"usage: "* ]]
}

@test "heavy-job: a second nested heavy-job invocation is a pass-through, not a deadlock" {
    run timeout 10 env -u HEAVY_JOB_HELD HEAVY_JOB_LOCK="$HLOCK" \
        "$HJ" "$HJ" true
    [ "$status" -eq 0 ]
}

# ── 3. The wiring: every saturating entry point reaches the wrapper ──────────
# The criterion is "at most ONE heavy job runs box-wide", so each saturating entry point
# must route through bin/heavy-job.  This is the deterministic check that the wiring
# EXISTS; the acceptance case below then runs one of these scripts for real, so the suite
# is not limited to grepping source.

@test "heavy-job: every saturating entry point in this repo routes through bin/heavy-job" {
    local f
    for f in scripts/run-autotune-batch.sh \
             scripts/autotune-model.sh \
             scripts/retune-band-chunk.sh \
             scripts/spec-decode-bench.sh \
             tools/run-tests.sh; do
        grep -q 'bin/heavy-job' "$REPO_ROOT/$f" || {
            echo "not serialised through bin/heavy-job: $f"
            return 1
        }
    done
    # The explicit kgraph update — the named ubuntu-console offender in the 2026-09-29
    # measurement — reached from `oc g --reindex` / `oc kgraph`.
    grep -q 'TACTICAL_REPO_ROOT/bin/heavy-job' "$REPO_ROOT/scripts/09f-oc-misc.sh" || {
        echo "oc-kgraph's --reindex is not serialised"
        return 1
    }
}

@test "heavy-job: the kgraph COMMIT path is deliberately NOT wired (nesting would deadlock)" {
    # tools/hooks/post-commit rebuilds the graph on EVERY commit while the commit lock is
    # held.  Taking the box-wide heavy lock there would nest one box-wide lock inside
    # another and deadlock against any lane holding it and waiting to commit — so those
    # hook files must stay clear of it.  This case fails if anyone "completes" the wiring
    # by adding it to the commit path.
    local h
    for h in pre-commit post-commit pre-push post-merge; do
        ! grep -q 'heavy-job' "$REPO_ROOT/tools/hooks/$h" || {
            echo "tools/hooks/$h takes the box-wide heavy lock — that deadlocks commits"
            return 1
        }
    done
}

# ── 4. Acceptance: a REAL wired command waits, and the lock is free after ────

@test "heavy-job: a wired command waits for a running heavy job, then --status reads free" {
    # The wired command is the REAL scripts/retune-band-chunk.sh, not a helper.  A
    # no-argument call reaches its usage exit (2) before it touches the GPU, so the case
    # is cheap and side-effect free while still exercising the shipped prologue.
    _hold_lock 3

    local started ended
    started=$(date +%s)
    run env -u HEAVY_JOB_HELD HEAVY_JOB_LOCK="$HLOCK" \
        bash "$REPO_ROOT/scripts/retune-band-chunk.sh"
    ended=$(date +%s)

    # (a) it announced the wait ...
    [[ "$output" == *"heavy-job: waiting for the heavy-job lock"* ]]
    # (b) ... and did NOT run concurrently.  A pass-through prints no wait line and
    #     finishes in well under a second, so elapsed wall time is the observable that
    #     separates serialised from not — an assertion nothing but a real wait satisfies.
    [ "$(( ended - started ))" -ge 1 ]
    # (c) the script still ran, once the lock was free: 2 is its own usage exit.
    [ "$status" -eq 2 ]
    [[ "$output" == *"usage: "* ]]

    wait "$_HOLDER_PID"

    # (d) and afterwards the lock is free again — no leaked holder.
    run env -u HEAVY_JOB_HELD HEAVY_JOB_LOCK="$HLOCK" "$HJ" --status
    [ "$status" -eq 0 ]
    [[ "$output" == "heavy-job: free"* ]]
}
