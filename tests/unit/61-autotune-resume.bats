#!/usr/bin/env bats
# ==============================================================================
# Unit — bin/autotune-resume.sh: the boot re-arm for the autotune remainder.
# ==============================================================================
# WHY THIS EXISTS.  Measured 2026-10-15: a running chunk is a child of the Qwen
# session's cli.js pair, which is a child of the VS Code window's extension host - so
# a restart ends it, and NOTHING re-armed it.  A restart therefore stopped the tuner
# until a person noticed.  The expected values here come from that job, not from the
# script's current output:
#
#   * with no plan, a boot does nothing and SAYS so (exit 0, a named line);
#   * `--plan` derives Wayne's ruled scope (uncertified + flagged family + the two
#     ruled new quants, by model file name) from the registry;
#   * the plan is CLAIMED once, so a boot loop cannot re-tune rows it already has;
#   * a row whose model file is gone is DROPPED, and if nothing is runnable the unit
#     fails, keeps the plan, and names the count.
#
# FALSIFICATION.  Case 2 fails against any derivation that hardcodes row NUMBERS
# instead of reading the registry (a row number is reassigned by every `model scan`).
# Case 5 fails against a claim-first-then-check implementation, which would leave the
# operator's plan consumed by a run that never happened.
#
# THE LOOP (v2 cases below).  These pin the half v1 never built: v1 `exec`d the chunk,
# so the script died with it and nothing re-derived the plan or armed a second restart
# — measured 2026-10-15, the campaign simply stopped at the first budget halt with 11
# rows left.  The budget case fails against any version that does not arm; the
# no-progress case against one that arms without progress; the cap case against one
# that arms for ever; the CI case against one that cancels another lane's run.
#
# No env.sh: the script is standalone and is driven here as a subprocess through its
# documented TAC_RESUME_* seams, so nothing from the module tree is sourced.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export REPO_ROOT
    SCRIPT="$REPO_ROOT/bin/autotune-resume.sh"
    export SCRIPT

    SANDBOX="$(mktemp -d)"
    export SANDBOX
    export TAC_RESUME_REGISTRY="$SANDBOX/models.conf"
    export TAC_RESUME_MODEL_DIR="$SANDBOX/models"
    export TAC_RESUME_STATE_DIR="$SANDBOX/state"
    export TAC_RESUME_LOGDIR="$SANDBOX/logs"
    export TAC_RESUME_ENTRY="$SANDBOX/entry.sh"
    export TAC_RESUME_PLAN="$SANDBOX/state/autotune-resume.rows"
    # PIN what counts as a chunk.  The probe is `pgrep -f`, so ANY process whose argv merely
    # CONTAINS the pattern reads as a live chunk — measured 2026-10-15 01:17, a harness waiter
    # running `while pgrep -f 'run-autotune-batch'` made two cases fail both in the full unit
    # run and standalone.  Inert here, so no chunk is live unless a case says so.
    export TAC_RESUME_CHUNK_PATTERN='tac-resume-no-such-chunk-9f3a'
    ARGV_LOG="$SANDBOX/entry.argv"
    export ARGV_LOG

    mkdir -p "$TAC_RESUME_MODEL_DIR" "$TAC_RESUME_STATE_DIR" "$TAC_RESUME_LOGDIR"

    # A stub entry point: records the rows it was handed, so the case can assert what
    # the resume actually asked for, and exits with the code this boot's chunk ended
    # on — v2 reads that code to decide whether the campaign continues.
    ENTRY_RC_FILE="$SANDBOX/entry.rc"
    export ENTRY_RC_FILE
    printf '0\n' > "$ENTRY_RC_FILE"
    cat > "$TAC_RESUME_ENTRY" <<'ENTRY_EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$ARGV_LOG"
_rc=0
[[ -r "${ENTRY_RC_FILE:-}" ]] && _rc=$(< "$ENTRY_RC_FILE")
exit "$_rc"
ENTRY_EOF
    chmod +x "$TAC_RESUME_ENTRY"

    # The loop's two out-of-tree collaborators, both stubbed: the restart tool (so no
    # Windows state is touched) and the CI-worker count (so a runner on this box
    # cannot silently decide a case — the shipped default is a real `pgrep`).
    RESTART_ARGV="$SANDBOX/restart.argv"
    export RESTART_ARGV
    RESTART_TOOL_STUB="$SANDBOX/restart-stub.sh"
    export RESTART_TOOL_STUB
    cat > "$RESTART_TOOL_STUB" <<'RESTART_EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$RESTART_ARGV"
exit 0
RESTART_EOF
    chmod +x "$RESTART_TOOL_STUB"
    export TAC_RESUME_RESTART_TOOL="$RESTART_TOOL_STUB"

    CI_WORKERS_STUB="$SANDBOX/ci-workers.sh"
    export CI_WORKERS_STUB
    _write_ci_workers 0
    export TAC_RESUME_CI_WORKERS_CMD="$CI_WORKERS_STUB"
    export TAC_RESUME_ARM_DELAY=1
    export TAC_RESUME_CI_WAIT_S=0
    export TAC_RESUME_CI_POLL_S=1

    # Registry rows carry the real column layout: 3 = model file, 17 = tps,
    # 18 = certified (yes/no), 25 = p2_tps.  Built by position so the field count
    # cannot drift with a hand-typed pipe run.
    _row() {
        local n="$1" f="$2" tps="$3" cert="$4" p2="$5" i out=""
        out="$n|m|$f"
        for i in 4 5 6 7 8 9 10 11 12 13 14 15 16; do out+="|0"; done
        out+="|$tps|$cert"
        for i in 19 20 21 22 23 24; do out+="|0"; done
        out+="|$p2"
        printf '%s\n' "$out"
    }
    {
        _row 1 uncertified.gguf 2.00 no  0.00
        _row 2 flagged.gguf     1.00 yes 5.00
        _row 3 certified.gguf   3.00 yes 1.00
        _row 4 law-chat-Q2_K.gguf 4.00 yes 0.00
    } > "$TAC_RESUME_REGISTRY"

    : > "$TAC_RESUME_MODEL_DIR/uncertified.gguf"
    : > "$TAC_RESUME_MODEL_DIR/flagged.gguf"
    : > "$TAC_RESUME_MODEL_DIR/certified.gguf"
    : > "$TAC_RESUME_MODEL_DIR/law-chat-Q2_K.gguf"
}

teardown() {
    [[ -n "${SANDBOX:-}" ]] && rm -rf "$SANDBOX"
}

@test "autotune-resume: with no plan a boot does nothing, says so, and calls nothing" {
    run "$SCRIPT" 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"no plan at"* ]]
    [[ "$output" == *"nothing to resume"* ]]
    [ ! -e "$ARGV_LOG" ]
}

@test "autotune-resume: --plan derives the ruled scope from the registry, by file name" {
    run "$SCRIPT" --plan 2>&1
    [ "$status" -eq 0 ]
    [ -f "$TAC_RESUME_PLAN" ]

    # Included: the uncertified row, the flagged family, and the ruled new quants.
    grep -q '^uncertified.gguf$' "$TAC_RESUME_PLAN"
    grep -q '^flagged.gguf$' "$TAC_RESUME_PLAN"
    grep -q '^law-chat-Q2_K.gguf$' "$TAC_RESUME_PLAN"
    # Excluded: certified and unflagged.
    ! grep -q '^certified.gguf$' "$TAC_RESUME_PLAN"
    # Named by FILE, never by row number.
    ! grep -qE '^[0-9]+$' "$TAC_RESUME_PLAN"
}

@test "autotune-resume: a SCOPE row survives the derivation, and a CERTIFIED new quant is not re-run" {
    # v6.  The derivation answers "what is the REGISTRY owed?", and because every registry row reads
    # autotuned=yes it answers "nothing" - so a hand-written plan was re-derived away one boot after it
    # was added (measured 2026-10-16: a 15-row hand plan claimed by the 09:08 and 10:31 boots, 2 rows by
    # the 09:42 and 11:52 boots).  SCOPE is the durable half, and a row the registry now reports as
    # certified leaves it, so the plan still SHRINKS and `continue_after` still arms.
    local scope="$SANDBOX/state/autotune-resume.scope.rows"
    printf 'scope-owed.gguf\nscope-done.gguf\n' > "$scope"
    : > "$TAC_RESUME_MODEL_DIR/scope-owed.gguf"
    : > "$TAC_RESUME_MODEL_DIR/scope-done.gguf"

    # A 44-column row, so the meas_state axis the v6 rule reads actually exists.  The shared `_row`
    # helper builds 25 fields, which is why the older fixture could not exercise that branch.
    _row44() { # <n> <file> <cert> <meas_state>
        local n="$1" f="$2" c="$3" m="$4" i out=""
        out="$n|m|$f"
        for i in 4 5 6 7 8 9 10 11 12 13 14 15 16; do out+="|0"; done
        out+="|4.00|$c"
        for i in 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43; do out+="|0"; done
        out+="|$m"
        printf '%s\n' "$out"
    }
    {
        _row44 5 scope-owed.gguf yes ""
        _row44 6 scope-done.gguf yes certified
        _row44 7 law-chat-Q2_K.gguf yes certified
    } > "$TAC_RESUME_REGISTRY"

    run env TAC_RESUME_SCOPE="$scope" "$SCRIPT" --plan 2>&1
    [ "$status" -eq 0 ]
    # A scope row the registry has NOT certified is carried, though the derivation drops it.
    grep -q '^scope-owed.gguf$' "$TAC_RESUME_PLAN"
    # One it HAS certified drops out, so the plan shrinks and the loop keeps arming.
    ! grep -q '^scope-done.gguf$' "$TAC_RESUME_PLAN"
    # ...and a CERTIFIED ruled new quant is no longer pinned into every derivation (~40 of a boot's
    # 60 cycles, measured 2026-10-16).
    ! grep -q '^law-chat-Q2_K.gguf$' "$TAC_RESUME_PLAN"
}

@test "autotune-resume: a plan is executed through the entry point and CLAIMED once" {
    printf 'uncertified.gguf\nflagged.gguf\n' > "$TAC_RESUME_PLAN"
    run "$SCRIPT" 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"resuming 2 row(s)"* ]]

    # The entry point got exactly those rows, once.
    [ "$(wc -l < "$ARGV_LOG")" -eq 2 ]
    grep -q '^uncertified.gguf$' "$ARGV_LOG"
    grep -q '^flagged.gguf$' "$ARGV_LOG"

    # Claimed: a copy in the log home, the claim kept aside rather than destroyed, and (v7) the
    # REMAINDER re-written at the path a boot looks at - so the next boot RESUMES instead of
    # finding nothing.  v3 also writes a RETIREMENT marker beside the claim, so the claim is
    # counted EXCLUDING that marker - the marker matches the same glob.
    [ -f "$TAC_RESUME_PLAN" ]
    [ "$(ls -1 "$TAC_RESUME_LOGDIR" | grep -c '\.rows$')" -eq 1 ]
    local _claim_n _marker_n
    _claim_n=$(ls -1 "$TAC_RESUME_STATE_DIR"/autotune-resume.rows.claimed-* 2>/dev/null \
        | grep -vc '\.retired$')
    _marker_n=$(ls -1 "$TAC_RESUME_STATE_DIR"/autotune-resume.rows.claimed-*.retired 2>/dev/null \
        | wc -l)
    [ "$_claim_n" -eq 1 ]
    [ "$_marker_n" -eq 1 ]

    # v7: a second boot RESUMES the re-written remainder rather than finding nothing, because the
    # campaign continues by design now - those rows are still OWED, they simply did not certify.
    # "CLAIMED ONCE" is what this case proves, and the claim/marker assertions above are its proof.
    run "$SCRIPT" 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"resuming"* ]]
}

@test "autotune-resume: a row whose model file is gone is dropped and the rest still run" {
    rm -f "$TAC_RESUME_MODEL_DIR/flagged.gguf"
    printf 'uncertified.gguf\nflagged.gguf\n' > "$TAC_RESUME_PLAN"
    run "$SCRIPT" 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"dropping flagged.gguf"* ]]
    [[ "$output" == *"resuming 1 row(s)"* ]]
    [ "$(wc -l < "$ARGV_LOG")" -eq 1 ]
    grep -q '^uncertified.gguf$' "$ARGV_LOG"
}

@test "autotune-resume: nothing runnable fails, names the count, and KEEPS the plan" {
    rm -f "$TAC_RESUME_MODEL_DIR/uncertified.gguf" "$TAC_RESUME_MODEL_DIR/flagged.gguf"
    printf 'uncertified.gguf\nflagged.gguf\n' > "$TAC_RESUME_PLAN"
    run "$SCRIPT" 2>&1
    [ "$status" -eq 1 ]
    [[ "$output" == *"nothing runnable"* ]]
    [[ "$output" == *"2 row(s) dropped"* ]]
    # The plan survives, so the operator can fix it; nothing was called.
    [ -f "$TAC_RESUME_PLAN" ]
    [ ! -e "$ARGV_LOG" ]
}

# _write_ci_workers N — the count the loop's CI gate reads.  A FILE, not a real
# runner: the shipped default is `pgrep -cf '[R]unner.Worker'`, and on a box that
# runs other repos' CI (and this suite's own CI) that would decide these cases for us.
_write_ci_workers() {
    cat > "$CI_WORKERS_STUB" <<EOS
#!/usr/bin/env bash
printf '%s\n' "$1"
EOS
    chmod +x "$CI_WORKERS_STUB"
}

# ── THE LOOP (v2) ─────────────────────────────────────────────────────────────
# v1 `exec`d the chunk, so the script died with it: nothing re-derived the plan and
# nothing armed another restart, and the campaign stopped at the first budget halt
# (measured 2026-10-15, 11 rows left).  The cases below drive the exit code the chunk
# leaves behind, which is the loop's only input.

@test "autotune-resume: a budget halt that SHRANK the remainder re-plans and ARMS a restart" {
    printf 'uncertified.gguf\nflagged.gguf\n' > "$TAC_RESUME_PLAN"
    # One row certified this boot, so it leaves the derivation; flagged.gguf stays.
    {
        _row 1 uncertified.gguf 2.00 yes 1.00
        _row 2 flagged.gguf     1.00 yes 5.00
    } > "$TAC_RESUME_REGISTRY"
    printf '4\n' > "$ENTRY_RC_FILE"

    run "$SCRIPT" 2>&1
    [ "$status" -eq 0 ]
    # v7 wording: the loop reports what is still OWED rather than the shrink it used to require.
    [[ "$output" == *"still owed: 1 row(s)"* ]]
    [[ "$output" == *"armed restart 1/8"* ]]

    # Armed through the TRACKED tool, which owns the Windows side and the chunk gate.
    grep -q '^--restart$' "$RESTART_ARGV"
    grep -q '^--delay$' "$RESTART_ARGV"

    # The plan is re-derived for the next boot, and it is the still-owed row.
    [ -f "$TAC_RESUME_PLAN" ]
    [ "$(grep -c . "$TAC_RESUME_PLAN")" -eq 1 ]
    grep -q '^flagged.gguf$' "$TAC_RESUME_PLAN"

    # The counter counts RESTARTS, not boots: that is what the cap bounds.
    [ "$(cat "$TAC_RESUME_STATE_DIR/autotune-resume.auto-restarts")" = "1" ]
}

@test "autotune-resume: a budget halt that did NOT shrink the remainder STILL arms (v7 criterion)" {
    # CRITERION CHANGE (Wayne, 2026-10-16): the INDICATIVE rows stay in the SCOPE and are RETRIED,
    # and he asked for a "much smoother" campaign - so a boot that retried them and certified
    # nothing is PROGRESS, not a reason to stop.  This case previously asserted the OPPOSITE
    # ("does not arm"), and that stop contradicted the ruling: it stalled the campaign after ONE
    # boot (measured 18:45 - a full 64-cycle boot, then ActiveState=failed, plan none, 11 owed).
    # The guards that bound the retries now are the 8-restart cap and arm_restart's CI-drain wait.
    printf 'uncertified.gguf\nflagged.gguf\n' > "$TAC_RESUME_PLAN"
    printf '4\n' > "$ENTRY_RC_FILE"
    # The registry is untouched, so the same rows (and more) are still owed.
    run "$SCRIPT" 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"still owed"* ]]
    grep -q '^--restart$' "$RESTART_ARGV"

    # ...and the plan SURVIVES the decision, so a later boot can resume with no hand re-plan.
    [ -f "$TAC_RESUME_PLAN" ]
    [ "$(grep -c . "$TAC_RESUME_PLAN")" -ge 1 ]
}

@test "autotune-resume: an adapter STALL is not resumed — the budget was not the reason" {
    printf 'uncertified.gguf\n' > "$TAC_RESUME_PLAN"
    printf '3\n' > "$ENTRY_RC_FILE"
    run "$SCRIPT" 2>&1
    [ "$status" -eq 3 ]
    [[ "$output" == *"budget UNSPENT"* ]]
    [[ "$output" == *"a person looks"* ]]
    [ ! -e "$RESTART_ARGV" ]
}

@test "autotune-resume: an EMPTY remainder ends the campaign and arms nothing" {
    printf 'flagged.gguf\n' > "$TAC_RESUME_PLAN"
    printf '4\n' > "$ENTRY_RC_FILE"
    # Every row certified and unflagged, no ruled new quant: nothing is owed.
    { _row 1 flagged.gguf 5.00 yes 1.00; } > "$TAC_RESUME_REGISTRY"

    run "$SCRIPT" 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"remainder is EMPTY"* ]]
    [ ! -e "$RESTART_ARGV" ]
}

@test "autotune-resume: a CI job on this box PAUSES the loop rather than being cancelled" {
    printf 'uncertified.gguf\nflagged.gguf\n' > "$TAC_RESUME_PLAN"
    {
        _row 1 uncertified.gguf 2.00 yes 1.00
        _row 2 flagged.gguf     1.00 yes 5.00
    } > "$TAC_RESUME_REGISTRY"
    printf '4\n' > "$ENTRY_RC_FILE"
    _write_ci_workers 2

    run "$SCRIPT" 2>&1
    [ "$status" -eq 4 ]
    [[ "$output" == *"a CI job is executing on this box"* ]]
    [ ! -e "$RESTART_ARGV" ]

    # v8 criterion change (Wayne's ruling "1a", 2026-10-17): the gate now sits at the MEASUREMENT,
    # not only at the arming.  `wait_for_ci_clear` used to guard `arm_restart` alone, so the chunk
    # ran regardless and its rows were measured under a live CI job - measured 2026-10-17, while
    # `/home/wayne/actions-runner-console/bin/Runner.Worker spawnclient` was executing and
    # `--status` read `CI jobs on this box: 1` in the same minute.  Falsification against the
    # pre-v8 code: the entry point IS invoked there and the plan IS claimed.
    [ ! -e "$ARGV_LOG" ]
    [ -f "$TAC_RESUME_PLAN" ]
    grep -q '^uncertified.gguf$' "$TAC_RESUME_PLAN"
    [ -z "$(ls "$TAC_RESUME_PLAN".claimed-* 2>/dev/null)" ]
}

@test "autotune-resume: the automatic-restart cap stops the loop and names the reset" {
    printf 'uncertified.gguf\nflagged.gguf\n' > "$TAC_RESUME_PLAN"
    {
        _row 1 uncertified.gguf 2.00 yes 1.00
        _row 2 flagged.gguf     1.00 yes 5.00
    } > "$TAC_RESUME_REGISTRY"
    printf '4\n' > "$ENTRY_RC_FILE"
    printf '8\n' > "$TAC_RESUME_STATE_DIR/autotune-resume.auto-restarts"

    run "$SCRIPT" 2>&1
    [ "$status" -eq 4 ]
    [[ "$output" == *"8 automatic restarts already (cap 8)"* ]]
    [[ "$output" == *"--plan"* ]]
    [ ! -e "$RESTART_ARGV" ]
}

@test "autotune-resume: --plan PARKS a row that can never certify, and names the reason" {
    {
        _row 1 MemSFT-Qwen3-Law-Memory-8B.Q2_K.gguf 9.10 yes 11.13
        _row 2 flagged.gguf 1.00 yes 5.00
    } > "$TAC_RESUME_REGISTRY"

    run "$SCRIPT" --plan 2>&1
    [ "$status" -eq 0 ]
    # The parked row is kept OUT of the plan and NAMED, with its reason.
    ! grep -q '^MemSFT' "$TAC_RESUME_PLAN"
    grep -q '^flagged.gguf$' "$TAC_RESUME_PLAN"
    [[ "$output" == *"parked (out of the plan): MemSFT-Qwen3-Law-Memory-8B.Q2_K.gguf"* ]]
    [[ "$output" == *"never clears the filled-cache TPS floor"* ]]
    # A fresh campaign resets the loop's counter.
    [ "$(cat "$TAC_RESUME_STATE_DIR/autotune-resume.auto-restarts")" = "0" ]
}

# ── THE CLAIM IS THE RESUME MARKER (v3) ───────────────────────────────────────
# v2 claimed the plan and moved it aside, so a restart that killed the chunk left NO plan
# and NO record that a run was owed: measured 2026-10-15 14:34:58 BST, the next boot read
# "no plan ... nothing to resume" and 8 rows were never measured.  The claim is retired the
# moment the exit code has been read, so an UNRETIRED claim means exactly "cut off".

# Falsification: fails against v2, which had no recovery path at all and would print
# "no plan ... nothing to resume" and call nothing.
@test "autotune-resume: a chunk cut off after the claim is RE-DERIVED and resumed" {
    printf 'uncertified.gguf\n' > "$TAC_RESUME_PLAN.claimed-20261015-134149"

    run "$SCRIPT" 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"the previous run was never reported on"* ]]
    [[ "$output" == *"re-derives the remainder"* ]]

    # The RULED remainder was re-derived and handed over, not the claim's own list.
    grep -q '^uncertified.gguf$' "$ARGV_LOG"
    grep -q '^law-chat-Q2_K.gguf$' "$ARGV_LOG"

    # BOTH claims are retired - the recovered one and this boot's own - so a second boot cannot
    # RE-RECOVER anything.  v7: it also finds the REMAINDER this boot wrote and resumes it, which
    # is the point; what this asserts is that it does NOT take the recovery path a second time.
    [ -e "$TAC_RESUME_PLAN.claimed-20261015-134149.retired" ]
    run "$SCRIPT" 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" != *"the previous run was never reported on"* ]]
}

# Falsification: fails against a scan that does not skip the ".retired" NAME - the marker
# file itself matches the claim glob, so a reported-on run reads as cut off.
@test "autotune-resume: a claim that WAS reported on resumes nothing" {
    printf 'uncertified.gguf\n' > "$TAC_RESUME_PLAN.claimed-20261015-190635"
    : > "$TAC_RESUME_PLAN.claimed-20261015-190635.retired"

    run "$SCRIPT" 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"no plan at"* ]]
    [[ "$output" == *"nothing to resume"* ]]
    [ ! -e "$ARGV_LOG" ]
}

# Falsification: fails when --status does not report the claim at all, which is how a
# cut-off campaign stayed invisible to the operator.
@test "autotune-resume: --status names an unreported claim" {
    printf 'uncertified.gguf\n' > "$TAC_RESUME_PLAN.claimed-20261015-134149"

    run "$SCRIPT" --status 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"UNREPORTED previous run"* ]]
    [[ "$output" == *"claimed-20261015-134149"* ]]
}

# Falsification: fails before v4, where the claim ALONE decided "cut off" - so --status named
# a run as unreported on the same screen as "a chunk IS live", and a boot could have started a
# second run beside the live one.
@test "autotune-resume: a claim whose chunk is STILL RUNNING is not called cut off" {
    printf 'uncertified.gguf\n' > "$TAC_RESUME_PLAN.claimed-20261015-134149"
    # The ONE case that wants a live chunk, so it pins the probe to its own fixture rather than
    # the inert default — a real `run-autotune-batch` elsewhere on the box cannot decide it.
    export TAC_RESUME_CHUNK_PATTERN='autotune-rows-fake'
    # A live process whose cmdline matches the chunk probe, as the real wrapper's does.
    ( exec -a autotune-rows-fake sleep 30 ) &
    local _fake=$!
    sleep 1

    run "$SCRIPT" --status 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"claim in flight"* ]]
    [[ "$output" != *"UNREPORTED previous run"* ]]

    # A bare boot must NOT start a second run beside the live one.
    run "$SCRIPT" 2>&1
    [[ "$output" == *"already running"* ]]
    [ ! -e "$ARGV_LOG" ]

    if ! kill "$_fake" 2>/dev/null; then
        printf 'note: the fake chunk had already exited\n' >&2
    fi
}

# end of file
