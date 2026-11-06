#!/usr/bin/env bats
# ==============================================================================
# Unit — tools/hooks/pre-push: a slow gate must be VISIBLE, and a gate that
# exceeds its cap must REFUSE rather than be mistaken for a pass or a hang.
# ==============================================================================
# WHY THIS EXISTS.  Measured 2026-11-06T18:17-18:35Z in this repo while pushing
# 285bbaa4: the hook printed its banner, "tree matches HEAD", and then nothing
# for over 15 minutes, because tools/lint.sh over the whole tree is genuinely
# that slow on a busy box.  From outside the process, "gate still working" and
# "hook wedged" were THE SAME OBSERVATION, so the push was killed twice
# believing it was hung — each kill discarding minutes of finished gate work.
# A gate whose runtime cannot be told from a hang gets killed under pressure,
# which is how a red gate ships: the exact outcome this hook exists to prevent.
#
# CONTRACT (tools/hooks/pre-push header, PROGRESS AND A CAP):
#   start    -> ">>> gate N/M <name> — start HH:MM:SSZ, cap Ns"
#   working  -> "...  still running: <name> (Ns of cap)" every PRE_PUSH_GATE_TICK_SECS
#   green    -> "ok   <name> (Ns)"
#   red      -> "FAIL <name> — push refused (exit N after Ns)"
#   cap hit  -> "TIMEOUT <name> — gate timed out after Ns and was killed", the
#               remaining gates are SKIPPED (named, no verdict) and the push is
#               refused: a cap hit is neither a pass nor a gate failure.
#
# FALSIFICATION.  Against the pre-2026-11-06 hook, cases 1-3 fail: it printed
# one "ok"/"FAIL" line per gate with no start line, no elapsed time, no
# still-running line, and no cap at all — so case 3's gate would run to its own
# 30 s and case 1 would have no timing to assert.  Case 4 fails because the
# counter did not exist.  Nothing here asserts log ORDER beyond start-before-ok,
# and no case asserts the exact wording of a line it does not need.
#
# MUTATED 2026-11-06, on the delivered hook: all four cases fail against the pre-change
# hook; deleting the skip-after-cap, relabelling TIMEOUT as FAIL, and dropping the
# duration from the green line each fail exactly one case.  The `set +e` in the gate
# wrapper is deliberately NOT in that list, because its failure mode is an UNBOUNDED
# wait: measured by hand the same evening with a stub gate that exits 7, the wrapper
# aborted before writing its verdict and the runner printed "still running" for ever.
# Case 2 is what catches it inside a bound — its cap is 5 s, so that regression lands
# as a TIMEOUT line rather than a stalled suite.
# ==============================================================================

setup() {
    REPO_ROOT_SRC="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
    SB="$(mktemp -d)"
    export SB
    # The hook materialises HEAD under ${TMPDIR:-/tmp}; keep every temp artefact inside the sandbox so a
    # test can never disturb a real push on this box.
    export TMPDIR="$SB/tmp"
    mkdir -p "$TMPDIR"
    REPO="$SB/repo"
    git init -q "$REPO"
    git -C "$REPO" config user.email "test@example.invalid"
    git -C "$REPO" config user.name "test"
    mkdir -p "$REPO/tools/hooks"
    cp "$REPO_ROOT_SRC/tools/hooks/pre-push" "$REPO/tools/hooks/pre-push"
    printf 'tracked\n' > "$REPO/file.txt"
    git -C "$REPO" add -A
    git -C "$REPO" commit -qm "fixture"
}

teardown() {
    [[ -n "${SB:-}" ]] && rm -rf "$SB"
}

# _gates <lint-body> <docs-body> — install the two gate stubs and bring the tree back to HEAD so the hook takes
# the no-worktree path (this suite is about the gate runner, not about materialising HEAD — that is case 75).
_gates() {
    printf '#!/usr/bin/env bash\n%s\n' "$1" > "$REPO/tools/lint.sh"
    printf '#!/usr/bin/env bash\n%s\n' "$2" > "$REPO/tools/docs-sync-check.sh"
    chmod +x "$REPO/tools/lint.sh" "$REPO/tools/docs-sync-check.sh"
    git -C "$REPO" add -A
    git -C "$REPO" commit -qm "gates: $1 / $2"
}

@test "pre-push names each gate's start and duration, and says it is still working (2026-11-06)" {
    _gates 'sleep 3; exit 0' 'exit 0'

    PRE_PUSH_GATE_TICK_SECS=1 run bash "$REPO/tools/hooks/pre-push" <<< ""
    [ "$status" -eq 0 ]

    # Start line: index, name, clock time, cap.
    [[ "$output" == *">>> gate 1/2 tools/lint.sh"* ]]
    [[ "$output" == *"start "*"Z, cap "* ]]
    # Liveness: the whole point — silence for minutes must be impossible.
    [[ "$output" == *"...  still running: tools/lint.sh"* ]]
    # Duration on the green line, so "how long did this take" is a reading, not a reconstruction.
    [[ "$output" =~ ok\ \ \ tools/lint\.sh\ \(whole\ tree\)\ \([0-9]+s\) ]]
    # The second gate is announced too, or a two-gate hook could look like a one-gate hook.
    [[ "$output" == *">>> gate 2/2 tools/docs-sync-check.sh"* ]]
}

@test "pre-push reports a red gate with its exit code and does not call it a timeout (2026-11-06)" {
    _gates 'exit 0' 'echo docs-bad >&2; exit 7'

    # The cap is set low HERE for a reason found by mutation: if the wrapper ever stops writing its verdict (the
    # `set +e` regression), a red gate is indistinguishable from a hang and this case would block for the whole
    # default cap. Bounded at 5 s, the regression surfaces as "TIMEOUT" in seconds instead of a stalled suite.
    SECONDS=0
    PRE_PUSH_GATE_TIMEOUT_SECS=5 run bash "$REPO/tools/hooks/pre-push" <<< ""
    local _took=$SECONDS
    [ "$status" -eq 1 ]
    [ "$_took" -lt 15 ]

    [[ "$output" == *"FAIL tools/docs-sync-check.sh — push refused (exit 7 after "* ]]
    # The gate's own words still reach the pusher — a bounded runner must not swallow the diagnosis.
    [[ "$output" == *"docs-bad"* ]]
    # A failure and a cap are different verdicts, and case 3 is where that separation is asserted from the
    # other side; asserting its absence here is what stops one being reported as the other.
    [[ "$output" != *"TIMEOUT"* ]]
    # A green gate before a red one still says it was green.
    [[ "$output" == *"ok   tools/lint.sh (whole tree)"* ]]
}

@test "pre-push refuses on a cap hit, and skips the remaining gate instead of passing it (2026-11-06)" {
    # The gate ignores TERM long enough that only the kill can stop it: the cap must bound the WALL CLOCK, not
    # merely print a line while the gate keeps running.
    _gates 'sleep 30; exit 0' 'exit 0'

    SECONDS=0
    PRE_PUSH_GATE_TIMEOUT_SECS=3 PRE_PUSH_GATE_TICK_SECS=1 \
        run bash "$REPO/tools/hooks/pre-push" <<< ""
    local _took=$SECONDS
    [ "$status" -eq 1 ]

    [[ "$output" == *"TIMEOUT tools/lint.sh (whole tree) — gate timed out after 3s"* ]]
    # The gate that never ran must be NAMED as skipped. Silence here would be the original defect: a push that
    # looks like it checked two gates and checked one.
    [[ "$output" == *"skip   tools/docs-sync-check.sh"* ]]
    [[ "$output" != *"ok   tools/docs-sync-check.sh"* ]]
    # Bounded: 3 s cap plus the kill grace, nowhere near the gate's own 30 s.
    [ "$_took" -lt 20 ]
}

@test "pre-push GATE_TOTAL equals the number of run_gate call sites (2026-11-06)" {
    # A gate that is never called carries no progress line and no verdict, while the counter still says "N/M".
    # Derive both numbers from the hook rather than restating them here.
    local _declared _calls
    _declared="$(sed -n 's/^GATE_TOTAL=\([0-9]*\)$/\1/p' "$REPO/tools/hooks/pre-push")"
    _calls="$(grep -c '^run_gate "' "$REPO/tools/hooks/pre-push")"
    [ -n "$_declared" ]
    [ "$_declared" -eq "$_calls" ]
}
