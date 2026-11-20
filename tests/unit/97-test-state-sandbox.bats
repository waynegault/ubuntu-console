#!/usr/bin/env bats
# ==============================================================================
# Unit — every suite inherits a SANDBOXED LLM store from the runner
# ==============================================================================
# Measured 2026-11-19: the operator's shell exports the live paths (env.sh:
# LLM_STATE_DIR=~/models/.llm, LLM_REGISTRY=~/models/active/models.conf,
# LLAMA_MODEL_DIR=~/models/active) and tools/run-tests.sh passed them through.  A
# suite that did not pin all of them then wrote production:
#   * 631 of 782 files in ~/models/.llm/backups were Alpha/Beta/Gamma scan fixtures
#     (the scan backup follows LLM_STATE_DIR, scripts/11e-llm-model.sh);
#   * 287 rows-999 logs sat beside the real autotune logs;
#   * autotune-failures.tsv carried stub.gguf tallies;
#   * a 0-byte ~/models/active/beta.gguf appeared in the model store.
#
# The chokepoint is the RUNNER, not each suite, so a suite written tomorrow is
# hermetic without being told.  What these cases pin:
#   * the runner exports the sandbox BEFORE it runs any suite;
#   * it exports it in a clean environment (a live value in the parent must not win
#     — `:=` in the confs means an inherited value would otherwise survive);
#   * a suite run through the runner can NOT see the live store;
#   * a sandbox inside the live store is refused rather than trusted.
# Every case runs the runner's own text, so a refactor that drops the call fails
# here rather than in production six weeks later.
# ==============================================================================

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
RUNNER="$REPO_ROOT/tools/run-tests.sh"
HELPER="$REPO_ROOT/tools/test-state-sandbox.sh"

setup() {
    SANDBOX_HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$SANDBOX_HOME/models/active"
}

@test "runner: every writable LLM path is redirected under the run's temp root" {
    run env -u VIRTUAL_ENV HOME="$SANDBOX_HOME" \
        LLM_STATE_DIR="$SANDBOX_HOME/models/.llm" \
        LLM_REGISTRY="$SANDBOX_HOME/models/active/models.conf" \
        LLAMA_MODEL_DIR="$SANDBOX_HOME/models/active" \
        bash -c 'source "$1" >/dev/null 2>&1; tac_test_state_sandbox "$2"; printf "%s\n%s\n%s\n" \
            "$LLM_STATE_DIR" "$LLM_REGISTRY" "$LLAMA_MODEL_DIR"' _ "$HELPER" "$BATS_TEST_TMPDIR/llm"
    [ "$status" -eq 0 ]
    # The live values were exported above and must NOT survive the call.
    [[ "$output" != *"$SANDBOX_HOME/models"* ]]
    [[ "$output" == *"$BATS_TEST_TMPDIR/llm/"* ]]
    [ -d "$BATS_TEST_TMPDIR/llm/.llm" ]
    [ -d "$BATS_TEST_TMPDIR/llm/active" ]
}

@test "runner: a sandbox inside the live model store is REFUSED" {
    run env -u VIRTUAL_ENV HOME="$SANDBOX_HOME" \
        bash -c 'source "$1" >/dev/null 2>&1; tac_test_state_sandbox "$2"' \
        _ "$HELPER" "$SANDBOX_HOME/models"
    [ "$status" -eq 1 ]
    [[ "$output" == *"refusing a sandbox inside the live model store"* ]]
}

@test "runner: the sandbox is created before the first suite runs" {
    # ORDER, not presence: a call after the bats loop redirects nothing.  Compare the
    # line numbers in the runner's own text.
    local sb_ln bats_ln
    sb_ln=$(grep -n '^tac_test_state_sandbox\|  *tac_test_state_sandbox "\$TAP_DIR/llm"' "$RUNNER" | head -1 | cut -d: -f1)
    bats_ln=$(grep -n 'bats --tap --timing "\$bats_file"' "$RUNNER" | head -1 | cut -d: -f1)
    [ -n "$sb_ln" ]
    [ -n "$bats_ln" ]
    (( sb_ln < bats_ln )) || { echo "sandbox at line $sb_ln, bats at $bats_ln"; return 1; }

    # ...and its failure is a RUN error, not a silently-unsandboxed run.
    run grep -A4 'if ! tac_test_state_sandbox' "$RUNNER"
    [ "$status" -eq 0 ]
    [[ "$output" == *"exit 2"* ]]
    [[ "$output" == *"cannot create the test LLM sandbox"* ]]
}

@test "runner: a suite cannot reach the live store through the runner" {
    # The end-to-end property, measured the way the leak was: run the actual runner
    # against a one-case suite that PRINTS the paths it inherits.  The live values are
    # exported first, exactly as the operator's shell does.
    local fake="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$fake/tools" "$fake/tests/unit" "$fake/.pytest_cache" "$fake/scripts"
    cp "$RUNNER" "$fake/tools/run-tests.sh"
    cp "$HELPER" "$fake/tools/test-state-sandbox.sh"
    cp "$REPO_ROOT/tests/bats-suites.tsv" "$fake/tests/" 2>/dev/null || : > "$fake/tests/bats-suites.tsv"
    # Armed by a marker file rather than by existing: a rogue unit suite in the copy
# would otherwise run for real, and the suite under test here is the RUNNER's
# sandbox, not any case inside it.  With the marker absent the file is a no-op.
    # The probe is written to its own file, not inline in this suite, because the
    # bridge's parser counts a case opener inside a heredoc as a real case
    # (tests/test_bats_bridge.py, test_bridge_parse_matches_bats_count).
    local at='@'
    {
        printf '%s\n' "#!/usr/bin/env bats" "${at}test \"probe: record the LLM paths this suite inherits\" {"
        printf '%s\n' '    [ -e "${PROBE_ARMED:-/nonexistent}" ] || skip "probe not armed"'
        printf '%s\n' "    printf 'STATE=%s\\nMODELS=%s\\nREGISTRY=%s\\n' \\"
        printf '%s\n' '        "${LLM_STATE_DIR:-}" "${LLAMA_MODEL_DIR:-}" "${LLM_REGISTRY:-}" > "$PROBE_OUT"'
        printf '%s\n' "}"
    } > "$fake/tests/unit/00-probe.bats"
    : > "$BATS_TEST_TMPDIR/armed"
    export PROBE_OUT="$BATS_TEST_TMPDIR/probe.out"
    # The default mode (no argument) runs tests/unit/*.bats; `fast` runs a fixed pair
    # that does not include the probe (tools/run-tests.sh:_build_bats_list).
    run env -u VIRTUAL_ENV HOME="$SANDBOX_HOME" PROBE_OUT="$PROBE_OUT" \
        PROBE_ARMED="$BATS_TEST_TMPDIR/armed" \
        LLM_STATE_DIR="$SANDBOX_HOME/models/.llm" \
        LLM_REGISTRY="$SANDBOX_HOME/models/active/models.conf" \
        LLAMA_MODEL_DIR="$SANDBOX_HOME/models/active" \
        HEAVY_JOB_HELD=1 \
        bash "$fake/tools/run-tests.sh"
    [ -f "$PROBE_OUT" ] || { echo "the probe did not run: $output"; return 1; }
    # The live value points at the sandbox home; the inherited one must not be it.
    [[ "$(cat "$PROBE_OUT")" != *"$SANDBOX_HOME/models"* ]]
    [[ "$(cat "$PROBE_OUT")" == *"/llm/.llm"* ]]
}

# end of file
