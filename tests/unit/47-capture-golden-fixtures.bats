#!/usr/bin/env bats
# ==============================================================================
# Unit — tools/capture-golden-fixtures.sh: a failed capture is not "complete"
# ==============================================================================
# Card 90eee0c2 (AUDIT-2026-10-02): capture() printed `<name> (rc=N)` per command
# and the script then printed an unconditional "Fixture capture complete." and
# exited 0 however many captures had failed — a success message with nothing behind
# it.  These cases drive the SHIPPED script in a sandbox whose bin/tac-exec exits
# non-zero (or zero): the script derives REPO_ROOT from its own location, so
# copying it under $SANDBOX/tools makes the sandbox's bin/tac-exec the one it runs
# and keeps the real box's commands (and the live profile) out of the test.
#
# The expected tally is not read off the script: it comes from the card's
# acceptance — a failed capture must be NAMED and the run must exit non-zero.
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
SCRIPT="$REPO_ROOT/tools/capture-golden-fixtures.sh"

# _sandbox <exit-code> — a throwaway repo root whose bin/tac-exec exits <exit-code>.
_sandbox() {
    local rc="$1" root="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$root/tools" "$root/bin"
    cp "$SCRIPT" "$root/tools/capture-golden-fixtures.sh"
    cat > "$root/bin/tac-exec" <<SH
#!/usr/bin/env bash
echo "stub tac-exec"
exit $rc
SH
    chmod +x "$root/bin/tac-exec"
    printf '%s\n' "$root"
}

@test "capture-golden-fixtures: a failing capture is named and the run exits non-zero" {
    local root
    root="$(_sandbox 7)"
    run "$root/tools/capture-golden-fixtures.sh" --out "$root/out"

    [[ "$status" -ne 0 ]] || { echo "a run whose every capture failed exited 0"; return 1; }
    [[ "$output" == *"captured: help_h (rc=7) FAILED"* ]] \
        || { echo "the per-command line does not mark the failure: $output"; return 1; }
    # The tally is honest: every one of the seven captures failed.
    [[ "$output" == *"0/7 captured, 7 FAILED"* ]] \
        || { echo "the run does not name the failure count: $output"; return 1; }
}

@test "capture-golden-fixtures: a clean capture exits 0 and reports zero failures" {
    local root
    root="$(_sandbox 0)"
    run "$root/tools/capture-golden-fixtures.sh" --out "$root/out"

    [[ "$status" -eq 0 ]] || { echo "a clean capture exited $status"; return 1; }
    [[ "$output" == *"7/7 captured, 0 FAILED"* ]] \
        || { echo "the clean run's tally is wrong: $output"; return 1; }
    [[ "$output" != *"FAILED (see above)"* ]]
}

# Exit 5 is `oc health`'s STALLED code — the listener is bound and dark past the
# post-bind grace, and the action is ALERT, NEVER RESTART (Wayne, 2026-10-07;
# scripts/oc-health-check.py::EXIT_BY_SUMMARY).  A capture taken on such a box is
# FAITHFUL, so counting it as a failure reddened the run for a probe that worked.  The
# expected values here come from that contract, not from the script's behaviour: a stall
# is captured and NAMED, the tally stays at zero failures, and the run exits 0 — while
# `rc 1` (and every other non-zero code) stays a failure, pinned by the first case.
@test "capture-golden-fixtures: rc 5 is a captured-but-STALLED fixture, not a failure" {
    local root
    root="$(_sandbox 5)"
    run "$root/tools/capture-golden-fixtures.sh" --out "$root/out"

    [[ "$status" -eq 0 ]] || { echo "a stalled capture exited $status"; return 1; }
    [[ "$output" == *"captured: help_h (rc=5) STALLED"* ]] \
        || { echo "the per-command line does not name the stall: $output"; return 1; }
    [[ "$output" == *"7/7 captured, 0 FAILED; 7 STALLED"* ]] \
        || { echo "the tally does not report the stalls separately from failures: $output"; return 1; }
    [[ "$output" != *"(see above)"* ]] \
        || { echo "the run printed the failure summary for a stall: $output"; return 1; }
    # The fixture format carries the state without being forced: the meta keeps the raw
    # code, so a consumer can tell a stall (5) from a failure (1) from the file itself.
    [[ "$(cat "$root/out/help_h.meta")" == *"exit_code: 5"* ]] \
        || { echo "the meta does not record the stall's exit code"; return 1; }
}

# ── tools/sync-openclaw-completion.sh: ONE capture, TWO writes (v4) ───────────
#
# The tool wrote only the repo fallback while scripts/13-init.sh PREFERS the CLI's own
# copy in $HOME/.openclaw/completions — which the CLI rewrites only on update, so the
# preferred copy lagged.  Wayne's decision: refresh BOTH from the same capture.  The
# CLI itself is stubbed here — the real `openclaw completion` takes minutes in plugin
# teardown — and the stub COUNTS its invocations, so "exactly once" is measured
# rather than inferred.

# _completion_sandbox — sandbox repo root + sandbox HOME + a counting stub `openclaw`.
# The tool derives REPO_ROOT from its own location and the preferred path from $HOME,
# so both writes land in the sandbox and neither real copy is touched.
_completion_sandbox() {
    local root="$BATS_TEST_TMPDIR/comp-repo"
    mkdir -p "$root/tools" "$BATS_TEST_TMPDIR/comp-home/.openclaw/completions" \
             "$BATS_TEST_TMPDIR/comp-bin"
    cp "$REPO_ROOT/tools/sync-openclaw-completion.sh" "$root/tools/sync-openclaw-completion.sh"
    chmod +x "$root/tools/sync-openclaw-completion.sh"
    cat > "$BATS_TEST_TMPDIR/comp-bin/openclaw" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_CALLS"
printf '\n_openclaw_completion() {\n  COMPREPLY=( stub )\n}\ncomplete -F _openclaw_completion openclaw\n'
STUB
    chmod +x "$BATS_TEST_TMPDIR/comp-bin/openclaw"
    printf '%s\n' "$root"
}

@test "sync-openclaw-completion: ONE capture writes BOTH copies, and a re-run is unchanged" {
    # Catches: (i) a SECOND CLI invocation — that call spends minutes in plugin
    # teardown, which is what the tool's timeout exists for, so capturing twice
    # doubles both the cost and the risk; (ii) writing only the repo fallback while
    # the loader prefers ~/.openclaw (the v3 defect); (iii) a re-run that rewrites
    # instead of reporting Unchanged, per path.
    local root home preferred repo
    root="$(_completion_sandbox)"
    home="$BATS_TEST_TMPDIR/comp-home"
    preferred="$home/.openclaw/completions/openclaw.bash"
    repo="$root/scripts/completions/openclaw.bash"
    export STUB_CALLS="$BATS_TEST_TMPDIR/openclaw-calls"
    : > "$STUB_CALLS"

    run env HOME="$home" PATH="$BATS_TEST_TMPDIR/comp-bin:$PATH" "$root/tools/sync-openclaw-completion.sh"
    [[ "$status" -eq 0 ]] || { echo "the tool failed: $output"; return 1; }

    # (a) BOTH copies are written, each in the shape its path is supposed to carry.
    [[ -s "$preferred" ]] || { echo "the PREFERRED copy was not written"; return 1; }
    [[ -s "$repo" ]] || { echo "the fallback copy was not written"; return 1; }
    grep -q 'GENERATED FILE, do not edit by hand' "$repo" \
        || { echo "the fallback lost its GENERATED header"; return 1; }
    ! grep -q 'GENERATED FILE' "$preferred" \
        || { echo "the preferred copy was given a header the CLI does not write there"; return 1; }
    # ...and both carry the SAME capture: the preferred copy is the repo copy minus
    # its 5-line header.
    [[ "$(sed -n '6,$p' "$repo")" == "$(cat "$preferred")" ]] \
        || { echo "the two copies are not the same capture"; return 1; }

    # (b) the CLI was invoked EXACTLY ONCE — counted from the stub's own log.
    [[ "$(wc -l < "$STUB_CALLS")" -eq 1 ]] \
        || { echo "expected 1 CLI invocation, saw $(wc -l < "$STUB_CALLS"): $(cat "$STUB_CALLS")"; return 1; }

    # (c) a second run reports Unchanged for BOTH paths and invokes the CLI once more.
    run env HOME="$home" PATH="$BATS_TEST_TMPDIR/comp-bin:$PATH" "$root/tools/sync-openclaw-completion.sh"
    [[ "$status" -eq 0 ]] || { echo "the re-run failed: $output"; return 1; }
    [[ "$output" == *"Unchanged: $preferred"* ]] \
        || { echo "no Unchanged line for the preferred copy: $output"; return 1; }
    [[ "$output" == *"Unchanged: $repo"* ]] \
        || { echo "no Unchanged line for the fallback: $output"; return 1; }
    [[ "$(wc -l < "$STUB_CALLS")" -eq 2 ]] \
        || { echo "the re-run did not invoke the CLI exactly once: $(wc -l < "$STUB_CALLS")"; return 1; }
}
