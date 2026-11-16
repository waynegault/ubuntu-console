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

# ── LLAMA-LANE-CONTENTION-001: telling a DEFERRAL from a failure ─────────────

@test "heavy-job: --status exits 0 while BUSY too, so the answer is the TEXT" {
    # Measured 2026-11-08, and the reason the watchdog helper parses the line: a caller that
    # tests only the exit status reads "free" ALWAYS.  Catches a later change that makes the
    # two answers differ in status without telling any caller.
    _hold_lock 3
    run env -u HEAVY_JOB_HELD HEAVY_JOB_LOCK="$HLOCK" "$HJ" --status
    [ "$status" -eq 0 ]
    [[ "$output" == *"BUSY"* ]]
}

@test "heavy-job: _tac_heavy_job_busy_from reads the status text (pure, no lock)" {
    source "$REPO_ROOT/bin/_tac-bin-lib.sh"
    run _tac_heavy_job_busy_from "heavy-job: BUSY — pid=1 started=2026-11-04T04:25:51Z cmd=autotune-rows.sh"
    [ "$status" -eq 0 ]
    run _tac_heavy_job_busy_from "heavy-job: free (last holder: pid=9)"
    [ "$status" -eq 1 ]
    # An unreadable answer is NOT busy: a broken helper must not strand a dead lane.
    run _tac_heavy_job_busy_from ""
    [ "$status" -eq 1 ]
}

@test "heavy-job: _tac_heavy_job_busy asks the real lock, and HEAVY_JOB_BIN is the seam" {
    source "$REPO_ROOT/bin/_tac-bin-lib.sh"
    _hold_lock 3
    run env -u HEAVY_JOB_HELD HEAVY_JOB_BIN="$HJ" HEAVY_JOB_LOCK="$HLOCK" \
        bash -c 'source "$1"; _tac_heavy_job_busy' _ "$REPO_ROOT/bin/_tac-bin-lib.sh"
    [ "$status" -eq 0 ]

    local stub="$BATS_TEST_TMPDIR/free-hj"
    printf '#!/usr/bin/env bash\necho "heavy-job: free"\nexit 0\n' > "$stub"
    chmod +x "$stub"
    run env HEAVY_JOB_BIN="$stub" bash -c 'source "$1"; _tac_heavy_job_busy' _ "$REPO_ROOT/bin/_tac-bin-lib.sh"
    [ "$status" -eq 1 ]
}

@test "LLAMA-LANE-CONTENTION-001: recover() defers to a heavy job BEFORE it touches the unit" {
    # The card's fix direction: "the restart policy must defer to a live campaign".  Measured
    # 2026-11-04: two starts and two stops in six minutes under autotune-rows.sh, unit left
    # failed.  This pins the WIRING — a pure predicate nothing calls proves nothing — and the
    # ORDER: the guard must precede the first systemctl call, or it defers after the damage.
    local body flat
    body=$(sed -n '/^recover() {/,/^}/p' "$REPO_ROOT/bin/llama-watchdog.sh")
    flat=$(printf '%s' "$body" | tr '\n' ' ')
    [[ "$body" == *"_tac_heavy_job_busy"* ]]
    # The deferred branch is an explanation, not a failure: it returns 0 and says why.
    [[ "$flat" == *"recover DEFERRED"*"return 0"* ]]
    local guard_line restart_line
    guard_line=$(printf '%s\n' "$body" | grep -n '_tac_heavy_job_busy' | head -1 | cut -d: -f1)
    restart_line=$(printf '%s\n' "$body" | grep -n 'systemctl --user' | head -1 | cut -d: -f1)
    [ -n "$guard_line" ] && [ -n "$restart_line" ]
    [ "$guard_line" -lt "$restart_line" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# LLAMA-LANE-PARK-001 — the two guards that decide "someone else owns the card"
# must share ONE definition, and a held lane must SAY it is held.
# ─────────────────────────────────────────────────────────────────────────────
# Measured 2026-11-15T18:52Z: `heavy-job --status` answered "free (last holder pid=7682
# 16:40:54Z)" while `fuser gpu.lock` showed a LIVE sweep.  recover() tested only
# _tac_heavy_job_busy, so it proceeded to start; the start gate at the `else` arm refused
# on gpu_claim_held; the lane landed inactive with each guard assuming the other owned it.
# The card's own direction was to derive the population from the LOCK rather than from who
# remembers to register, so both guards now ask the same two questions.

@test "LLAMA-LANE-PARK-001: recover() defers on a gpu.lock holder, not only a registered heavy job" {
    # Would catch: the exact 2026-11-15 shape — a lock holder that never registered as a
    # heavy job.  A test that only asserted _tac_heavy_job_busy would pass on the broken
    # code, which is why this asserts the SECOND predicate by name.
    local body
    body=$(sed -n '/^recover() {/,/^}/p' "$REPO_ROOT/bin/llama-watchdog.sh")
    [[ "$body" == *"_tac_heavy_job_busy || gpu_claim_held"* ]]
}

@test "LLAMA-LANE-PARK-001: the deferral predicate is the SAME one the start gate uses" {
    # The defect was two guards disagreeing, so pinning either one alone is not enough:
    # the deferral must name the same predicate the start gate refuses on.  If someone
    # later narrows one side, this fails rather than silently re-opening the gap.
    local recover_body gate_body
    recover_body=$(sed -n '/^recover() {/,/^}/p' "$REPO_ROOT/bin/llama-watchdog.sh")
    # NOTE: the `else` this range used to stop at is the INNER one three lines into the
    # branch, so gate_body could never contain the start-gate predicates it is asserted
    # about and those assertions passed vacuously.  Anchored on the last line of the arm.
    local _s _e
    _s=$(grep -n "GPU free but CUDA unit not active" "$REPO_ROOT/bin/llama-watchdog.sh" | head -1 | cut -d: -f1)
    _e=$(grep -n 'log "GPU free and \$CUDA_UNIT not active' "$REPO_ROOT/bin/llama-watchdog.sh" | head -1 | cut -d: -f1)
    gate_body=$(sed -n "${_s},${_e}p" "$REPO_ROOT/bin/llama-watchdog.sh")
    [[ -n "$gate_body" ]]
    [[ "$recover_body" == *"gpu_claim_held"* ]]
    [[ "$gate_body" == *"gpu_claim_held"* ]]
}

@test "LLAMA-LANE-PARK-001: a held lane ANNOUNCES the hold once per state change" {
    # Would catch: the silence that made the 2026-11-15 park take 26 minutes to find.  The
    # timer was healthy and ticking every five minutes and logged NOTHING on those ticks.
    # parked_announce is the fix; this pins that the held branch calls it, and that the
    # helper is state-change-gated rather than logging every tick.
    local gate_body helper
    # NOTE: the `else` this range used to stop at is the INNER one three lines into the
    # branch, so gate_body could never contain the start-gate predicates it is asserted
    # about and those assertions passed vacuously.  Anchored on the last line of the arm.
    local _s _e
    _s=$(grep -n "GPU free but CUDA unit not active" "$REPO_ROOT/bin/llama-watchdog.sh" | head -1 | cut -d: -f1)
    _e=$(grep -n 'log "GPU free and \$CUDA_UNIT not active' "$REPO_ROOT/bin/llama-watchdog.sh" | head -1 | cut -d: -f1)
    gate_body=$(sed -n "${_s},${_e}p" "$REPO_ROOT/bin/llama-watchdog.sh")
    [[ -n "$gate_body" ]]
    [[ "$gate_body" == *"parked_announce"* ]]
    helper=$(sed -n '/^parked_announce() {/,/^}/p' "$REPO_ROOT/bin/llama-watchdog.sh")
    # The gate: an unchanged reason returns early, so a long hold does not spam the log.
    [[ "$helper" == *'[[ "$prev" == "$reason" ]]'* ]]
    [[ "$helper" == *"return 0"* ]]
}

@test "LLAMA-LANE-PARK-001: parked_announce logs once, then stays quiet, then re-announces a NEW reason" {
    # Behavioural, not textual: run the REAL helper against a sandboxed marker file.
    # Would catch: a helper that logs every tick (noise) or never logs (the original bug).
    #
    # The helpers are EXTRACTED rather than sourced: llama-watchdog.sh runs its dispatch at
    # the bottom of the file, so sourcing it would start supervising lanes from a test.
    local marker helpers out1 out2 out3
    marker="$BATS_TEST_TMPDIR/parked"
    helpers="$BATS_TEST_TMPDIR/parked-helpers.sh"
    {
        # `log` comes from bin/_tac-bin-lib.sh in production; a stub keeps this case about
        # the announce GATE rather than about the logger's formatting.
        echo 'log() { printf "%s\n" "$*"; }'
        sed -n '/^parked_announce() {/,/^}/p' "$REPO_ROOT/bin/llama-watchdog.sh"
        sed -n '/^parked_clear() {/,/^}/p' "$REPO_ROOT/bin/llama-watchdog.sh"
    } > "$helpers"
    # The extraction must have found both functions, or every assertion below is vacuous.
    grep -q '^parked_announce() {' "$helpers"
    grep -q '^parked_clear() {' "$helpers"

    _run_announce() {
        bash -c '
            source "$1"
            TAC_LOG_TO_FILE=0
            CUDA_PARKED_FILE="$2"
            parked_announce "unit-a" "$3"
        ' _ "$helpers" "$marker" "$1"
    }
    out1=$(_run_announce "held by a bench")
    [[ "$out1" == *"PARKED unit-a: held by a bench"* ]]
    out2=$(_run_announce "held by a bench")
    [[ -z "$out2" ]]
    out3=$(_run_announce "held by a gpu.lock holder")
    [[ "$out3" == *"PARKED unit-a: held by a gpu.lock holder"* ]]
}

@test "LLAMA-LANE-PARK-001: parked_clear is silent when nothing was recorded" {
    # An always-on lane calls this every tick; a clear that logged would be the noise the
    # announce gate exists to avoid.
    local marker helpers out
    marker="$BATS_TEST_TMPDIR/parked-clear"
    helpers="$BATS_TEST_TMPDIR/parked-helpers-clear.sh"
    {
        echo 'log() { printf "%s\n" "$*"; }'
        sed -n '/^parked_announce() {/,/^}/p' "$REPO_ROOT/bin/llama-watchdog.sh"
        sed -n '/^parked_clear() {/,/^}/p' "$REPO_ROOT/bin/llama-watchdog.sh"
    } > "$helpers"
    out=$(bash -c '
        source "$1"
        TAC_LOG_TO_FILE=0
        CUDA_PARKED_FILE="$2"
        parked_clear
    ' _ "$helpers" "$marker")
    [[ -z "$out" ]]
    [[ ! -e "$marker" ]]
}

@test "LLAMA-LANE-PARK-001 item 3: an EXPIRED gpustop marker is not the same fact as NO marker" {
    # v34.  gpustop_active answers "no" for two different worlds — we never stopped this lane,
    # and we stopped it but the 1800s window ran out.  Collapsing them charged a stop WE
    # designed to the flap counter, and three of those in an hour hold the tier down.
    # Would catch: the helper being folded back into gpustop_active.
    local helpers out
    helpers="$BATS_TEST_TMPDIR/gpustop-helpers.sh"
    {
        echo 'log() { printf "%s\n" "$*"; }'
        sed -n '/^gpustop_active() {/,/^}/p' "$REPO_ROOT/bin/llama-watchdog.sh"
        sed -n '/^gpustop_stale() {/,/^}/p' "$REPO_ROOT/bin/llama-watchdog.sh"
    } > "$helpers"
    grep -q '^gpustop_stale() {' "$helpers"

    _probe() { # _probe <marker-file> -> "active stale"
        bash -c '
            source "$1"
            CUDA_GPUSTOP_FILE="$2"
            a=0; s=0
            gpustop_active && a=1
            gpustop_stale  && s=1
            printf "%s %s\n" "$a" "$s"
        ' _ "$helpers" "$1"
    }
    local now; now=$(date +%s)

    # absent: neither — we never stopped this lane
    out=$(_probe "$BATS_TEST_TMPDIR/absent")
    [[ "$out" == "0 0" ]]

    # live: active, not stale
    printf '%s\n' "$(( now + 600 ))" > "$BATS_TEST_TMPDIR/live"
    out=$(_probe "$BATS_TEST_TMPDIR/live")
    [[ "$out" == "1 0" ]]

    # expired: STALE but NOT active — the case that used to be indistinguishable from absent
    printf '%s\n' "$(( now - 600 ))" > "$BATS_TEST_TMPDIR/expired"
    out=$(_probe "$BATS_TEST_TMPDIR/expired")
    [[ "$out" == "0 1" ]]

    # garbage: neither.  An unparseable marker is not evidence of anything, so it must not
    # reach the recovery arm (and must not be treated as live either).
    printf 'not-a-number\n' > "$BATS_TEST_TMPDIR/garbage"
    out=$(_probe "$BATS_TEST_TMPDIR/garbage")
    [[ "$out" == "0 0" ]]
}

@test "LLAMA-LANE-PARK-001 item 3: provably_idle requires all four readings, and fails CLOSED on an unknown" {
    # The card's open question.  "No gpu.lock holder" is NOT idle: measured 2026-11-15T18:52Z,
    # no actionable holder, the compute table EMPTY, and 6998 MiB still in use with 1181 MiB
    # free.  Would catch: the arm degrading to "the lock is gone", which is the same
    # substitution that caused the original park with the sign flipped.
    local helpers
    helpers="$BATS_TEST_TMPDIR/idle-helpers.sh"
    {
        echo 'log() { printf "%s\n" "$*"; }'
        echo '_tac_heavy_job_busy() { return "${STUB_BUSY:-1}"; }'
        echo 'gpu_claim_held() { return "${STUB_LOCK:-1}"; }'
        echo 'gpu_busy() { return "${STUB_PROBE_BUSY:-1}"; }'
        echo 'nvidia-smi() { printf "%s\n" "${STUB_POWER:-2.14}"; }'
        sed -n '/^provably_idle() {/,/^}/p' "$REPO_ROOT/bin/llama-watchdog.sh"
    } > "$helpers"
    grep -q '^provably_idle() {' "$helpers"

    _idle() { # _idle -> 0 idle, 1 not idle
        bash -c 'source "$1"; GPU_BUSY_PROBE_ERROR=${STUB_PROBE_ERR:-0}; IDLE_POWER_W=10; provably_idle' _ "$helpers"
    }

    # all four agree -> idle
    out=$(STUB_POWER=2.14 _idle && echo idle || echo held)
    [[ "$out" == "idle" ]]

    # a heavy job -> held
    out=$(STUB_BUSY=0 STUB_POWER=2.14 _idle && echo idle || echo held)
    [[ "$out" == "held" ]]

    # a live gpu.lock holder -> held (this is the 2026-11-15 holder that was never a CUDA user)
    out=$(STUB_LOCK=0 STUB_POWER=2.14 _idle && echo idle || echo held)
    [[ "$out" == "held" ]]

    # the probe says BUSY -> held
    out=$(STUB_PROBE_BUSY=0 STUB_POWER=2.14 _idle && echo idle || echo held)
    [[ "$out" == "held" ]]

    # the probe ERRORED: free verdict, but "unknown" is not "idle" -> held (FAIL CLOSED)
    out=$(STUB_PROBE_ERR=1 STUB_POWER=2.14 _idle && echo idle || echo held)
    [[ "$out" == "held" ]]

    # the card is drawing power -> held
    out=$(STUB_POWER=48.0 _idle && echo idle || echo held)
    [[ "$out" == "held" ]]

    # no power reading at all -> held (an unreadable figure proves nothing)
    out=$(STUB_POWER="[N/A]" _idle && echo idle || echo held)
    [[ "$out" == "held" ]]
}

@test "LLAMA-LANE-PARK-001 item 3: the free-tick gate consults the expired marker BEFORE the death arm" {
    # Order matters and is the whole fix: if the unexpected-death arm is reached first, the
    # stop is charged as a flap and provably_idle is never asked.  This pins the branch order
    # in the source, because no unit-level stub can observe the ordering safely.
    local gate_body start_line end_line
    start_line=$(grep -n "GPU free but CUDA unit not active" "$REPO_ROOT/bin/llama-watchdog.sh" | head -1 | cut -d: -f1)
    end_line=$(grep -n 'log "GPU free and \$CUDA_UNIT not active' "$REPO_ROOT/bin/llama-watchdog.sh" | head -1 | cut -d: -f1)
    [[ -n "$start_line" && -n "$end_line" ]]
    (( start_line < end_line ))
    gate_body=$(sed -n "${start_line},${end_line}p" "$REPO_ROOT/bin/llama-watchdog.sh")
    # The range must actually CONTAIN the arm, or every assertion below is vacuous — the
    # failure mode this suite exists to catch, found in this very test on first run: the
    # original sed range stopped at the first inner `else`, three lines in.
    [[ "$gate_body" == *"elif gpustop_stale && provably_idle; then"* ]]
    # the recovery arm must sit above the hold arms and the flap charge
    local stale_line hold_line count_line
    stale_line=$(printf '%s\n' "$gate_body" | grep -n "gpustop_stale && provably_idle" | head -1 | cut -d: -f1)
    hold_line=$(printf '%s\n' "$gate_body" | grep -n "flap_hold_active" | head -1 | cut -d: -f1)
    count_line=$(printf '%s\n' "$gate_body" | grep -n 'flap_record "\$FLAP_CUDA"' | head -1 | cut -d: -f1)
    [[ -n "$stale_line" && -n "$hold_line" && -n "$count_line" ]]
    (( stale_line < hold_line ))
    (( stale_line < count_line ))
}
