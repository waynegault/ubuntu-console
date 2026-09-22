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
# ~/.openclaw/openclaw.json is neither read for its contents nor written.  Where
# the CLI is unavailable (the CI runner installs bats, not openclaw) the check
# cannot run and skips rather than pretending to pass.
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
CHECK="$REPO_ROOT/tests/helpers/check-secret-ref-paths.py"
SCRIPT="$REPO_ROOT/scripts/09d-oc-agents.sh"
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
