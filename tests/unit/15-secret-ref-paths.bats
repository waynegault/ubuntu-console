#!/usr/bin/env bats
# ==============================================================================
# Unit Tests — every SecretRef mapping path is a REAL config field
# ==============================================================================
# `__oc_apply_secret_refs` (scripts/09d-oc-agents.sh) holds a table of
# "<config dot-path> -> <ENV_VAR>" rows.  A row naming a path the config schema
# does not have is worse than inert:
#
#   * `set_path` creates the intermediate objects with `setdefault`, so the write
#     lands on a leaf nothing reads and the credential is never injected — while
#     the table still looks complete;
#   * the refs go out in ONE batched `openclaw config patch`, and that command
#     VALIDATES, so a single bad row aborts every other pending SecretRef update
#     in the same run.
#
# That is how `plugins.entries.typesafe-ai.apiKey` survived review on 2026-09-22:
# the real field is `skills.entries.typesafe-ai.apiKey` (installed skills live
# under `skills.entries`; a plugin entry has no `apiKey` of its own), so
# TYPESAFE_API_KEY stayed un-injected while the mapping looked complete.
#
# The oracle is the product's own validator — the same `openclaw config patch
# --dry-run` the mapping writes through — not a schema copy kept in this repo,
# which could drift the same way the row did.
#
# This file deliberately does NOT mock openclaw, so it requires the real CLI, and
# it validates against a throwaway EMPTY config (OPENCLAW_CONFIG_PATH) so the live
# ~/.openclaw/openclaw.json is neither read for its contents nor written.  The
# checker also pins its OWN throwaway state dir (OPENCLAW_STATE_DIR,
# check-secret-ref-paths.py), because `openclaw config patch` consults the host's
# state DB on every call and that DB's transient state must not decide this
# verdict — measured 2026-09-30, a healthy tree went red with "is undergoing
# offline maintenance" (a self-update) and, minutes later, "Cannot edit retained
# config at plugins.entries.brave.config" (an unfinished plugin upgrade).  The
# third case below is the regression guard for that pin.  Where the CLI is
# unavailable (the CI runner installs bats, not openclaw) the first two cases
# cannot run and skip rather than pretending to pass.
#
# The CLI is NOT required for the parse-and-attribute logic, and the cases at the
# bottom exercise it under CI: the checker's input seam is the `openclaw config
# patch --dry-run` subprocess, so a recorded transcript of that command
# (tests/fixtures/secret-ref-paths/, captured on this box 2026-10-02 with a
# throwaway OPENCLAW_CONFIG_PATH and OPENCLAW_STATE_DIR; the OK line's own config
# path is normalized to <config> per tests/fixtures/golden/README.md) is replayed
# through a stand-in `openclaw` on PATH.  That keeps the checker's real
# stdout+stderr parsing and error-path attribution under test without the CLI.
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
CHECK="$REPO_ROOT/tests/helpers/check-secret-ref-paths.py"
SCRIPT="$REPO_ROOT/scripts/09d-oc-agents.sh"
FIXTURES="$REPO_ROOT/tests/fixtures/secret-ref-paths"
FIXTURE_OK="$FIXTURES/patch-dry-run-ok.txt"
FIXTURE_REJECTED="$FIXTURES/patch-dry-run-rejected.txt"
TMPDIR_BATS="$(mktemp -d)"

setup() {
    # An empty base config: the merged patch is what gets schema-checked, so the
    # check stays hermetic and independent of the live config's contents.
    printf '{}\n' > "$TMPDIR_BATS/base-config.json"
    export OPENCLAW_CONFIG_PATH="$TMPDIR_BATS/base-config.json"
}

teardown() {
    rm -rf "$TMPDIR_BATS"
}

@test "every SecretRef mapping path is a real config field (2026-09-22)" {
    command -v openclaw >/dev/null 2>&1 || skip "openclaw CLI not available to validate against"

    run python3 "$CHECK"
    # Exit 2 is the checker's "could not check" — never a pass.
    if [ "$status" -eq 2 ]; then
        skip "config schema unavailable: $output"
    fi
    [ "$status" -eq 0 ]
}

@test "the SecretRef path check fails on a mapping path the schema rejects (teeth, 2026-09-22 regression)" {
    # Without this, a check that validated nothing at all would still pass.
    # Restore the exact historical bug in a COPY of the script and assert the
    # check fails and names the row.
    command -v openclaw >/dev/null 2>&1 || skip "openclaw CLI not available to validate against"

    local bad="$TMPDIR_BATS/09d-bad-path.sh"
    sed 's|("skills.entries.typesafe-ai.apiKey"|("plugins.entries.typesafe-ai.apiKey"|' \
        "$SCRIPT" > "$bad"
    # If the table has moved, the substitution silently no-ops and this test would
    # be asserting nothing — so prove the fixture really carries the bad row.
    grep -qF '("plugins.entries.typesafe-ai.apiKey", "TYPESAFE_API_KEY")' "$bad"

    run python3 "$CHECK" --script "$bad"
    [ "$status" -eq 1 ]
    [[ "$output" == *"plugins.entries.typesafe-ai.apiKey"* ]]
    [[ "$output" == *"TYPESAFE_API_KEY"* ]]
}

@test "hermetic: the check hands the CLI a throwaway state dir, never the host's (2026-09-30 regression)" {
    # Regression guard for the 2026-09-30 CI red.  `openclaw config patch` consults
    # the OpenClaw state DB on every call, and on this box that DB is taken offline
    # while an `openclaw` self-update runs and can carry an unfinished plugin upgrade.
    # Either one turns the suite red for a reason that has nothing to do with the
    # mapping table, so the checker must hand the CLI a state dir of its own.  A fake
    # CLI records the OPENCLAW_STATE_DIR it was given — this needs no real openclaw,
    # and it fails the moment the pin is dropped.
    local fakebin="$TMPDIR_BATS/bin"
    mkdir -p "$fakebin"
    cat > "$fakebin/openclaw" <<FAKE
#!/usr/bin/env bash
printf '%s\n' "\${OPENCLAW_STATE_DIR:-<unset>}" > "$TMPDIR_BATS/openclaw-state-dir.txt"
exit 0
FAKE
    chmod +x "$fakebin/openclaw"

    run env PATH="$fakebin:$PATH" python3 "$CHECK"
    [ "$status" -eq 0 ]

    local seen
    seen="$(cat "$TMPDIR_BATS/openclaw-state-dir.txt")"
    # It must be the checker's own temp dir ...
    [[ "$seen" == */check-secret-ref-paths-state-* ]]
    # ... and never the host's live state dir, which is what leaked before the fix.
    [[ "$seen" != "$HOME/.openclaw/state" ]]
}

# Build a stand-in `openclaw` that replays a recorded transcript and exit code,
# then print the bin dir to put first on PATH.  The checker's ONLY input from the
# CLI is the command's stdout+stderr and its exit status, so replaying both is a
# faithful stand-in — no openclaw install is needed to exercise the parsing.
_fake_openclaw_replay() {  # <transcript.txt> <exit-code>
    local transcript="$1" rc="$2"
    local bin="$TMPDIR_BATS/replay-$(basename "$transcript" .txt)"
    mkdir -p "$bin"
    cat > "$bin/openclaw" <<FAKE
#!/usr/bin/env bash
cat "$transcript"
exit $rc
FAKE
    chmod +x "$bin/openclaw"
    printf '%s\n' "$bin"
}

@test "recorded dry-run: a successful transcript passes the check without the CLI (CI)" {
    # Catches: a checker that reports failure on the validator's own success —
    # e.g. one that treats any stdout, or a non-empty message, as an error, which
    # would make a healthy tree look red for every operator.
    local bin rc
    rc="$(cat "$FIXTURES/patch-dry-run-ok.exit")"
    bin="$(_fake_openclaw_replay "$FIXTURE_OK" "$rc")"

    run env PATH="$bin:$PATH" python3 "$CHECK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK:"* ]]
}

@test "recorded dry-run: a rejection is attributed to its mapping row (teeth, CI)" {
    # Catches: a checker that passes a path the validator rejected, or that fails
    # without naming the offending row so the operator cannot find it.  The
    # recorded transcript names the historical bug shape; the script copy restores
    # that row (~plugins.entries.typesafe-ai) so attribution has something to blame.
    local bad="$TMPDIR_BATS/09d-bad-path.sh"
    sed 's|("skills.entries.typesafe-ai.apiKey"|("plugins.entries.typesafe-ai.apiKey"|' \
        "$SCRIPT" > "$bad"
    # If the table has moved, the substitution silently no-ops and this case would
    # be asserting nothing — so prove the fixture really carries the bad row.
    grep -qF '("plugins.entries.typesafe-ai.apiKey", "TYPESAFE_API_KEY")' "$bad"

    local bin rc
    rc="$(cat "$FIXTURES/patch-dry-run-rejected.exit")"
    bin="$(_fake_openclaw_replay "$FIXTURE_REJECTED" "$rc")"

    run env PATH="$bin:$PATH" python3 "$CHECK" --script "$bad"
    [ "$status" -eq 1 ]
    [[ "$output" == *"plugins.entries.typesafe-ai.apiKey"* ]]
    [[ "$output" == *"TYPESAFE_API_KEY"* ]]
}

@test "recorded dry-run: a rejection it cannot blame on a row still fails (CI)" {
    # Catches: reporting SUCCESS BY OMISSION — a validator refusal whose path the
    # checker cannot pin to a row must still exit non-zero and say so, never pass
    # because it had nothing to print.  Same transcript, the UNMODIFIED script:
    # `plugins.entries.typesafe-ai` is not one of its rows.
    local bin rc
    rc="$(cat "$FIXTURES/patch-dry-run-rejected.exit")"
    bin="$(_fake_openclaw_replay "$FIXTURE_REJECTED" "$rc")"

    run env PATH="$bin:$PATH" python3 "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no row could be blamed directly"* ]]
}
