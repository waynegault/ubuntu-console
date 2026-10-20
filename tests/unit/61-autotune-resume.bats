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
    # The settle is proved by its OWN case; the rest of the matrix runs a 0-bound gate and must
    # not gain a poll for it.  The shipped default (2) is asserted from the SOURCE there.
    export TAC_RESUME_CI_SETTLE_POLLS=1

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
    # _row stops at column 25, i.e. the PRE-PROVENANCE shape, whose meas_state is EMPTY —
    # and an empty state is NOT owed on its own (v21).  This variant fills columns 26-43
    # and pins meas_state (column 44), for the v21 criterion that selects an INDICATIVE row.
    _row_state() {
        local state="$1"
        shift
        _row "$@" | awk -F'|' -v s="$state" '
            BEGIN { OFS = "|" }
            { for (i = NF + 1; i <= 43; i++) $i = "0"; $44 = s; print }
        '
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

@test "autotune-resume: at the CAP with rows owed it RESETS the counter and ARMS (Wayne 2026-10-18)" {
    # CRITERION (Wayne, 2026-10-18, option b): the 8-restart cap bounds restarts WITHIN a
    # campaign; reaching it must not park a campaign that still owes rows.  Catches the shipped
    # behaviour, which stopped at 06:16:29 with 2 rows owed and left the GPU idle for 4 h 41 m
    # because that stop existed only in the journal.
    printf 'uncertified.gguf\nflagged.gguf\n' > "$TAC_RESUME_PLAN"
    {
        _row 1 uncertified.gguf 2.00 yes 1.00
        _row 2 flagged.gguf     1.00 yes 5.00
    } > "$TAC_RESUME_REGISTRY"
    printf '4\n' > "$ENTRY_RC_FILE"
    # The counter is already AT the cap before the arm is attempted.
    printf '8\n' > "$TAC_RESUME_STATE_DIR/autotune-resume.auto-restarts"

    run "$SCRIPT" 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"cap reached: 8/8"* ]] || { echo "the cap must be reported (got: $output)"; return 1; }
    [[ "$output" == *"armed restart 1/8"* ]] || { echo "it must ARM after the reset (got: $output)"; return 1; }

    # Re-based, not incremented past the cap: the next boot starts a fresh batch of 8.
    [ "$(cat "$TAC_RESUME_STATE_DIR/autotune-resume.auto-restarts")" = "1" ]
    grep -q '^--restart$' "$RESTART_ARGV"
}

@test "autotune-resume: a QUEUED run gates the chunk, and the settle needs two quiet polls" {
    # CRITERION (Wayne, 2026-10-18, option A): the gate must see a run that is QUEUED, not only one
    # the runner has PICKED UP — measured 12:03:37 (gate read 0) vs 12:03:38 (the job started), after
    # which the chunk measured at 0.9 cycles/min instead of 3.05.  And a single zero is a SAMPLE, not
    # a clearance: the gap between two jobs is exactly what it looked like.
    printf 'uncertified.gguf\nflagged.gguf\n' > "$TAC_RESUME_PLAN"
    _row 1 uncertified.gguf 2.00 yes 1.00 > "$TAC_RESUME_REGISTRY"
    printf '4\n' > "$ENTRY_RC_FILE"

    local stub="$SANDBOX/ci-seq.sh" seq="$SANDBOX/ci-seq.txt"
    cat > "$stub" <<'EOS'
#!/usr/bin/env bash
first=$(head -1 "$CI_SEQ_FILE")
sed -i '1d' "$CI_SEQ_FILE"
printf '%s\n' "${first:-0}"
EOS
    chmod +x "$stub"
    printf '#!/usr/bin/env bash\nprintf "0\\n"\n' > "$SANDBOX/ci-queued.sh"
    chmod +x "$SANDBOX/ci-queued.sh"

    # The local probe is the sequence; the queued probe answers 0 so the two sum to the sequence.
    unset TAC_RESUME_CI_WORKERS_CMD
    export TAC_RESUME_CI_QUEUED_CMD="$SANDBOX/ci-queued.sh"
    export TAC_RESUME_CI_LOCAL_CMD="$stub" CI_SEQ_FILE="$seq"
    export TAC_RESUME_CI_SETTLE_POLLS=2 TAC_RESUME_CI_POLL_S=1 TAC_RESUME_CI_WAIT_S=2

    # (1) FALSIFIER: 0,1,0 is NOT two consecutive quiet polls.  The old one-zero rule cleared at
    # the first 0 and claimed the plan; this must PAUSE, leaving the plan in place.
    printf '0\n1\n0\n0\n' > "$seq"
    run "$SCRIPT" 2>&1
    [ "$status" -eq 4 ] || { echo "a 0,1,0 sequence must PAUSE (got $status)"; return 1; }
    [[ "$output" == *"a CI job is executing on this box"* ]]
    grep -q '^uncertified.gguf$' "$TAC_RESUME_PLAN"

    # (2) CONTROL: two consecutive quiet polls clear the gate and allow the chunk.
    printf '0\n0\n0\n' > "$seq"
    run "$SCRIPT" 2>&1
    [ "$status" -eq 0 ] || { echo "two consecutive quiet polls must clear (got $status)"; return 1; }
}

@test "autotune-resume: a QUEUED run counts as CI before any worker exists" {
    # Catches the shipped pre-v13 behaviour, where ci_workers counted ONLY local [R]unner.Worker
    # processes, so a run sitting in GitHub's queue was invisible until the runner picked it up.
    printf 'uncertified.gguf\nflagged.gguf\n' > "$TAC_RESUME_PLAN"
    _row 1 uncertified.gguf 2.00 yes 1.00 > "$TAC_RESUME_REGISTRY"
    printf '4\n' > "$ENTRY_RC_FILE"

    printf '#!/usr/bin/env bash\nprintf "0\\n"\n' > "$SANDBOX/ci-local.sh"
    printf '#!/usr/bin/env bash\nprintf "1\\n"\n' > "$SANDBOX/ci-queued.sh"
    chmod +x "$SANDBOX/ci-local.sh" "$SANDBOX/ci-queued.sh"
    unset TAC_RESUME_CI_WORKERS_CMD
    export TAC_RESUME_CI_LOCAL_CMD="$SANDBOX/ci-local.sh"
    export TAC_RESUME_CI_QUEUED_CMD="$SANDBOX/ci-queued.sh"

    run "$SCRIPT" 2>&1
    [ "$status" -eq 4 ] || { echo "a QUEUED run must gate with no worker running (got $status)"; return 1; }
    [[ "$output" == *"a CI job is executing on this box"* ]]
    [ ! -e "$ARGV_LOG" ]
}

@test "autotune-resume: an exhausted CI wait ARMS A RETRY, and the budget stops it" {
    # CRITERION (Wayne, 2026-10-18, option b): an exhausted CI wait must RE-ENTER the loop instead
    # of dead-ending.  Measured that evening: the arm's 900 s expired nine seconds after one CI run
    # ended (20:34:15) while a second held the queue to 20:45:35, nothing was armed, and the box sat
    # idle until a hand start at 21:38.  The shipped pre-v16 code PAUSED and stopped there.
    printf 'uncertified.gguf\n' > "$TAC_RESUME_PLAN"
    _row 1 uncertified.gguf 2.00 yes 1.00 > "$TAC_RESUME_REGISTRY"
    printf '0\n' > "$ENTRY_RC_FILE"
    _write_ci_workers 1                       # a CI job is executing: the gate cannot clear
    export RETRY_ARGV="$SANDBOX/retry.argv"
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$RETRY_ARGV"\n' > "$SANDBOX/retry-stub.sh"
    chmod +x "$SANDBOX/retry-stub.sh"
    export TAC_RESUME_RETRY_CMD="$SANDBOX/retry-stub.sh"
    : > "$RETRY_ARGV"

    # (1) The wait exhausts: a retry is armed with the shipped delay and the unit it must start.
    run "$SCRIPT" 2>&1
    [ "$status" -eq 4 ] || { echo "an exhausted wait must still pause (got $status)"; return 1; }
    [[ "$output" == *"retry 1/8 armed"* ]] || { echo "the retry was not announced (got: $output)"; return 1; }
    grep -qxF '900 autotune-resume-retry autotune-resume.service' "$RETRY_ARGV" \
        || { echo "the retry called with the wrong argv: $(cat "$RETRY_ARGV")"; return 1; }
    [ "$(cat "$TAC_RESUME_STATE_DIR/autotune-resume.retries")" = "1" ]
    # A retry is not a chunk: the plan stays and nothing was measured.
    grep -q '^uncertified.gguf$' "$TAC_RESUME_PLAN"
    [ ! -e "$ARGV_LOG" ]

    # (2) The budget is spent: the stub must NOT run again, and the stop must be NAMED.
    printf '8\n' > "$TAC_RESUME_STATE_DIR/autotune-resume.retries"
    : > "$RETRY_ARGV"
    run "$SCRIPT" 2>&1
    [ "$status" -eq 4 ]
    [[ "$output" == *"retry budget spent: 8/8"* ]] || { echo "a spent budget must say so (got: $output)"; return 1; }
    [ ! -s "$RETRY_ARGV" ]
}

@test "autotune-resume: a chunk is an INVOCATION, not a mention (v18 anchor)" {
    # CRITERION (Wayne, 2026-10-18): the 23:37 reading "a chunk IS live: 435033" was a
    # `shellcheck -s bash -x --severity=warning … <files>` process from the CI lint job. Its file
    # list names bin/autotune-rows.sh, and an unanchored `pgrep -f` matched that mention, so a LINT
    # read as a measurement - enough to skip the loop's CI gate and to hold the supervisor.
    # The predicate is checked by PID rather than by its total, so a real chunk running on this
    # box cannot make either assertion vacuous.
    # The harness PINS TAC_RESUME_CHUNK_PATTERN (so a foreign process cannot decide its cases);
    # this case is about the SHIPPED default, so the pin is dropped before it is expanded.
    unset TAC_RESUME_CHUNK_PATTERN
    eval "$(sed -n '/^_CHUNK_NAMES=/,/^CHUNK_PATTERN=/p' "$SCRIPT")"
    [[ -n "${CHUNK_PATTERN:-}" ]] || { echo "CHUNK_PATTERN is not defined"; return 1; }

    printf '#!/usr/bin/env bash\nsleep 20\n' > "$SANDBOX/autotune-rows.sh"
    chmod +x "$SANDBOX/autotune-rows.sh"
    bash "$SANDBOX/autotune-rows.sh" & _real=$!
    python3 -c 'import time; time.sleep(20)' autotune-rows.sh & _decoy=$!
    sleep 1

    # The predicate is applied to each process's OWN command line, read from /proc, so this
    # depends on nothing but the regex (pgrep is not guaranteed on the suite's sandboxed PATH).
    _cmdline() { tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null; }

    # CONTROL: a real invocation matches, so the negative below cannot pass vacuously.
    _cmdline "$_real" | grep -Eq "$CHUNK_PATTERN" \
        || { echo "a real bash invocation must match the chunk pattern (got: $(_cmdline "$_real"))"; kill "$_real" "$_decoy" 2>/dev/null; return 1; }
    # FALSIFIER: a decoy that only NAMES the script (argv[0] is python3) must not.
    if _cmdline "$_decoy" | grep -Eq "$CHUNK_PATTERN"; then
        echo "a process that only NAMES the script must not read as a live chunk (got: $(_cmdline "$_decoy"))"
        kill "$_real" "$_decoy" 2>/dev/null
        return 1
    fi
    kill "$_real" "$_decoy" 2>/dev/null
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

    # v9 criterion (Wayne's ruling "1a" -> (a), 2026-10-17): the shipped CI bound must OUTLAST a CI
    # RUN and still sit UNDER the unit's TimeoutStartSec.  Too short and a single `systemctl start`
    # can never outlive a drain - measured 2026-10-17, the old 900 s expired first and the loop
    # PAUSED, which is what made "resume when the runner drains" a manual step.  Too long and
    # systemd kills the wait mid-flight.  Both values are read from the SOURCE, deliberately: this
    # case runs with TAC_RESUME_CI_WAIT_S=0, so the env says nothing about the shipped default.
    # Removing the bound, or raising it past the unit's timeout, fails here.
    local _wait _tmo
    _wait=$(grep -oE '\$\{TAC_RESUME_CI_WAIT_S:-[0-9]+\}' "$SCRIPT" | grep -oE '[0-9]+')
    _tmo=$(grep -oE '^TimeoutStartSec=[0-9]+' "$REPO_ROOT/systemd/autotune-resume.service" | grep -oE '[0-9]+')
    [ -n "$_wait" ] && [ -n "$_tmo" ]
    [ "$_wait" -lt "$_tmo" ]

    # v10 criterion (2026-10-17): the ARM waits on its OWN short bound and a signal SAYS what
    # happened.  Measured: the unit was SIGTERMed at 14:07:50, seventeen minutes into an arm wait
    # that could legally last five HOURS; nothing was armed, nothing re-armed it, and the campaign
    # sat idle for three hours with the plan intact.  Removing ARM_CI_WAIT_S, pointing the arm
    # back at the chunk's long bound, or dropping the traps fails here.
    grep -q 'ARM_CI_WAIT_S="${TAC_RESUME_ARM_CI_WAIT_S:-900}"' "$SCRIPT"
    grep -q 'wait_for_ci_clear "$ARM_CI_WAIT_S"' "$SCRIPT"
    grep -q "trap '_on_signal TERM' TERM" "$SCRIPT"
    # ... while the CHUNK's own gate keeps the long bound (no argument means CI_WAIT_S).
    grep -q 'local _bound="${1:-$CI_WAIT_S}"' "$SCRIPT"
}

@test "autotune-resume: --plan SELECTS an indicative row and MemSFT by name (v21)" {
    {
        # MemSFT: tuned once (yes), p2 BELOW tps (not flagged), measurement EMPTY — so the
        # ONLY thing that can select it is its NEW_QUANTS name entry.
        _row 1 MemSFT-Qwen3-Law-Memory-8B.Q2_K.gguf 9.10 yes 1.00
        # Not flagged either: selected purely because its measurement is INDICATIVE.
        _row_state indicative 2 drifted.gguf 5.00 yes 1.00
        _row 3 certified.gguf 3.00 yes 1.00
    } > "$TAC_RESUME_REGISTRY"

    run "$SCRIPT" --plan 2>&1
    [ "$status" -eq 0 ]
    # Wayne, 2026-10-19 ("i want thos 6 autotuned"): a measurement that is not certified is owed
    # work — an INDICATIVE row by state, and MemSFT by NAME (its state is EMPTY, the pre-provenance
    # shape, which is not owed on its own).  The 2026-10-15 park is LIFTED, so nothing is parked.
    grep -q '^MemSFT-Qwen3-Law-Memory-8B.Q2_K.gguf$' "$TAC_RESUME_PLAN"
    grep -q '^drifted.gguf$' "$TAC_RESUME_PLAN"
    ! grep -q '^certified.gguf$' "$TAC_RESUME_PLAN"
    [[ "$output" != *"parked (out of the plan)"* ]]
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

@test "autotune-resume: a row that keeps failing the drift gate is CAPPED as unacceptable" {
    # CRITERION (2026-10-20): a row measured INDICATIVE_CAP times without a certification is
    # recorded, not retried for ever.  Measured the same day: row 24 was re-measured 17 times in
    # seven hours at 38-67 % drift against a 25 % bound, on a card held at 85-89 C.  Catches the
    # shipped behaviour, which would have armed an 18th identical attempt.
    printf 'capped.gguf\n' > "$TAC_RESUME_PLAN"
    { _row_state indicative 1 capped.gguf 25.00 yes 25.00; } > "$TAC_RESUME_REGISTRY"
    : > "$TAC_RESUME_MODEL_DIR/capped.gguf"
    # Already at cap-1, so this measurement is the third.
    printf 'capped.gguf 2\n' > "$TAC_RESUME_STATE_DIR/autotune-resume.indicative-streak"
    printf '4\n' > "$ENTRY_RC_FILE"

    run "$SCRIPT" 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"meas_state=unacceptable"* ]]
    # Terminal: the row leaves the plan, so the remainder is EMPTY and nothing is armed.
    [[ "$output" == *"remainder is EMPTY"* ]]
    [ "$(awk -F'|' '$1==1{print $44}' "$TAC_RESUME_REGISTRY")" = "unacceptable" ]
    ! grep -q '^capped.gguf$' "$TAC_RESUME_PLAN" 2>/dev/null
    [ "$(awk '{print $2}' "$TAC_RESUME_STATE_DIR/autotune-resume.indicative-streak")" -eq 3 ]
    [ ! -e "$RESTART_ARGV" ] || ! grep -q '^--restart$' "$RESTART_ARGV"
}

@test "autotune-resume: below the cap the indicative row stays OWED and its count advances" {
    # The control for the case above: the cap must not act early, or a row that could certify on
    # the next quiet boot would be thrown away after one bad night.
    printf 'capped.gguf\n' > "$TAC_RESUME_PLAN"
    { _row_state indicative 1 capped.gguf 25.00 yes 25.00; } > "$TAC_RESUME_REGISTRY"
    : > "$TAC_RESUME_MODEL_DIR/capped.gguf"
    printf 'capped.gguf 1\n' > "$TAC_RESUME_STATE_DIR/autotune-resume.indicative-streak"
    printf '4\n' > "$ENTRY_RC_FILE"

    run "$SCRIPT" 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"still owed: 1 row(s)"* ]]
    [ "$(awk -F'|' '$1==1{print $44}' "$TAC_RESUME_REGISTRY")" = "indicative" ]
    [ "$(awk '{print $2}' "$TAC_RESUME_STATE_DIR/autotune-resume.indicative-streak")" -eq 2 ]
    grep -q '^--restart$' "$RESTART_ARGV"
}

@test "autotune-resume: a SCOPE row marked unacceptable cannot re-enter the plan" {
    # The terminal state has to hold in BOTH derivations.  derive_rows selects only
    # `indicative`, and scope_rows must exclude `unacceptable` too - otherwise a scope file
    # puts a capped row back on the next boot and defeats the cap.
    local scope="$SANDBOX/state/autotune-resume.scope.rows"
    printf 'capped.gguf\n' > "$scope"
    { _row_state unacceptable 1 capped.gguf 25.00 yes 25.00; } > "$TAC_RESUME_REGISTRY"
    : > "$TAC_RESUME_MODEL_DIR/capped.gguf"

    run env TAC_RESUME_SCOPE="$scope" "$SCRIPT" --plan 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing to plan"* ]]
    [ ! -e "$TAC_RESUME_PLAN" ] || ! grep -q '^capped.gguf$' "$TAC_RESUME_PLAN"
}

# end of file
