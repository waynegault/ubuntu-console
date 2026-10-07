#!/usr/bin/env bats
# ==============================================================================
# Unit — local vendor patches are visible where a human actually looks
# ==============================================================================
# ~/.local/bin/qwen-guard-patch.sh relaxes the daemon's read-only-git allowlist in
# the bundled guard chunks, and every IDE-companion update reverts it — so a cron
# watchdog re-applies it. On 2026-09-27 the watchdog detected the 0.24.6 reversion
# for fifteen hours (30 consecutive runs, 04:47:01 → 19:17:02) and could not repair
# it: the new chunk spelling defeated the patcher's exact-match anchor. Every one of
# those runs ended with exit 0, and this box has no mail transport at all, so the
# report went to a log nobody reads and reached nobody. Detection that cannot be
# delivered is not detection, so `oc health` now shows the state too.
#
# The SECOND patch in this file (2026-09-30) is the same class of thing: the VS Code
# Python extension's pytest wrapper is patched to record every Testing run, and an
# extension update replaces the wrapper and reverts that too. It shares this suite
# deliberately — same failure shape, same row contract, and a NEW tests/unit file
# would not run in CI at all without being named by literal path in a workflow.
#
# What each group is for:
#   * the three states of the helper — the expected values come from the criterion
#     "a reader can tell an unpatched box from a patched one", not from this
#     implementation: applied → APPLIED, cannot-patch → NOT APPLIED plus the way
#     back, no local patch at all → not an error on a box that never had one;
#   * the WIRING, in BOTH branches — the enhanced-checker branch returns before the
#     fallback rows, so a call wired only below it is dead code on a box that has the
#     checker (the same trap the gh-keyring row's own note records);
#   * --json stays clear of the row, as it does for the other forensic row.
#
# Hermetic: the patcher is a stub in the sandbox HOME. No chunk is read or patched,
# and the real ~/.local/bin/qwen-guard-patch.sh is never executed.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"

    # shellcheck source=scripts/01-constants.sh
    source "$REPO_ROOT/scripts/01-constants.sh"
    # shellcheck source=scripts/02-error-handling.sh
    source "$REPO_ROOT/scripts/02-error-handling.sh"
    # shellcheck source=scripts/03-design-tokens.sh
    source "$REPO_ROOT/scripts/03-design-tokens.sh"
    # shellcheck source=scripts/05-ui-engine.sh
    source "$REPO_ROOT/scripts/05-ui-engine.sh"
    # shellcheck source=scripts/09e-oc-health.sh
    source "$REPO_ROOT/scripts/09e-oc-health.sh"
}

# A patcher stub that reports like the real one and exits with the code under test.
stub_patcher() {
    mkdir -p "$HOME/.local/bin"
    cat > "$HOME/.local/bin/qwen-guard-patch.sh" <<MOCK
#!/usr/bin/env bash
echo "  ok       daemon-git-worktree-guard-STUB.js (patch already applied)"
exit $1
MOCK
    chmod +x "$HOME/.local/bin/qwen-guard-patch.sh"
}

@test "guard patch: a patched box reports APPLIED" {
    stub_patcher 0

    run __oc_guard_patch_state
    [ "$status" -eq 0 ]
    [[ "$output" == *"Daemon guard patch"* ]]
    [[ "$output" == *"[APPLIED]"* ]]
    [[ "$output" != *"NOT APPLIED"* ]]
}

@test "guard patch: an unpatched box says so, and names the way back" {
    stub_patcher 1

    run __oc_guard_patch_state
    [ "$status" -eq 0 ]
    [[ "$output" == *"[NOT APPLIED]"* ]]
    # The three things a reader needs to act: what was refused (the patcher's own
    # first line), how to re-apply it, and where the self-heal recorded its attempts.
    [[ "$output" == *"daemon-git-worktree-guard-STUB.js"* ]]
    [[ "$output" == *"qwen-guard-patch.sh re-applies it"* ]]
    [[ "$output" == *"selfheal.log"* ]]
}

@test "guard patch: a box without the local patch is reported, not treated as broken" {
    # No stub: the patcher is absent, which is a legitimate state (the patch is a
    # local choice, not upstream behaviour) — so the row must not read as a fault.
    [ ! -e "$HOME/.local/bin/qwen-guard-patch.sh" ]

    run __oc_guard_patch_state
    [ "$status" -eq 0 ]
    [[ "$output" == *"[not installed]"* ]]
    [[ "$output" != *"NOT APPLIED"* ]]
}

@test "guard patch: the row prints on the fallback path too" {
    # No checker in the sandbox HOME, so oc-health takes its fallback path. That is NOT
    # the path this box takes — install.sh links the checker into place, so the enhanced
    # branch pinned above is the live one here. __test_port comes from 06-hooks, which
    # this harness does not carry, so it is stubbed; the assertion is about OUR row.
    __test_port() { return 0; }
    # `oc-health` reads this flag before it prints any row, and the harness does not
    # carry the module that sets it; without it the fallback reports "NOT INSTALLED"
    # and returns, which is a different test.
    export __TAC_OPENCLAW_OK=1

    run oc-health
    [[ "$output" == *"Gateway Port"* ]]
    [[ "$output" == *"Daemon guard patch"* ]]
}

@test "guard patch: the row is wired into the enhanced-checker branch as well" {
    # That branch RETURNS before the fallback rows, so a call wired only below it is
    # dead code on every box where the checker exists. Running the real function
    # against a stub checker is what pins the wiring; the helper's own cases cannot
    # see it.
    mkdir -p "$HOME/.openclaw/workspace/scripts"
    cat > "$HOME/.openclaw/workspace/scripts/oc-health-check.py" <<'PYSTUB'
print("STUB-ENHANCED-CHECKER")
PYSTUB
    export TAC_PYTHON="${TAC_PYTHON:-python3}"
    stub_patcher 1

    run oc-health
    [[ "$output" == *"STUB-ENHANCED-CHECKER"* ]]
    [[ "$output" == *"Daemon guard patch"* ]]
    [[ "$output" == *"[NOT APPLIED]"* ]]
}

@test "guard patch: --json stays clear of the row" {
    mkdir -p "$HOME/.openclaw/workspace/scripts"
    cat > "$HOME/.openclaw/workspace/scripts/oc-health-check.py" <<'PYSTUB'
print('{"checks": []}')
PYSTUB
    export TAC_PYTHON="${TAC_PYTHON:-python3}"

    run oc-health --json
    [[ "$output" != *"Daemon guard patch"* ]]
}

# ==============================================================================
# Gateway health: the lifecycle verdict is FORWARDED, not re-derived
# ==============================================================================
# `oc health` and `so` disagreed about one moment (2026-10-06): the checker probed
# /health without the lifecycle verdict `so` acts on, so a bound-but-not-serving
# Gateway during its cold start read FAIL while `so` read STARTING. The fix lives in
# the WIRING — `oc-health` must hand the checker `__so_gateway_phase`'s answer, or
# the checker silently falls back to its weaker unit+port+age evidence and the two
# commands re-diverge. A stub checker that echoes the variable is what pins it.
#
# The SECOND string (2026-10-07) is the post-bind evidence: `__so_gateway_bound_age`'s
# answer, which is what tells a listener that JUST bound from one bound and dark for
# minutes (the checker's STALLED row). It travels the same way, and a harness without
# 09a forwards empty — which the checker reads as "no post-bind evidence" rather than
# inventing an age. Both are echoed and pinned here.
gateway_phase_echo_checker() {
    mkdir -p "$HOME/.openclaw/workspace/scripts"
    cat > "$HOME/.openclaw/workspace/scripts/oc-health-check.py" <<'PYSTUB'
import os
print("PHASE=" + os.environ.get("OC_HEALTH_GATEWAY_PHASE", "<unset>"))
print("BINDAGE=" + os.environ.get("OC_HEALTH_GATEWAY_BOUND_AGE_S", "<unset>"))
PYSTUB
    export TAC_PYTHON="${TAC_PYTHON:-python3}"
}

@test "gateway health: so's lifecycle verdict reaches the enhanced checker" {
    gateway_phase_echo_checker
    # 09a-oc-gateway.sh is not sourced in this harness, so stand the classifier in.
    __so_gateway_phase() { printf 'starting\n'; }
    __so_gateway_bound_age() { printf '258\n'; }

    # --json skips the human-only watch rows (the journal-scanning ones are slow on
    # a box with a large journal); the phase wiring is identical in every mode.
    run oc-health --json
    [[ "$output" == *"PHASE=starting"* ]]
    [[ "$output" == *"BINDAGE=258"* ]]
}

@test "gateway health: a harness without the classifier forwards empty verdicts" {
    # __so_gateway_phase is absent here; the checker's own fallback must take over
    # rather than the variable being invented or the row disappearing.
    gateway_phase_echo_checker
    run declare -F __so_gateway_phase
    [ "$status" -ne 0 ]

    run oc-health --json
    [[ "$output" == *"PHASE="* ]]
    [[ "$output" != *"PHASE=starting"* ]]
    # The post-bind string is forwarded the same way: empty, never invented.
    [[ "$output" == *"BINDAGE="* ]]
    [[ "$output" != *"BINDAGE=258"* ]]
}

# ------------------------------------------------------------------------------
# `oc doctor-local` is the checker's OTHER consumer, and it reads the exit code.
#
# WHY THIS EXISTS: the first version branched on `!= 0`, so a stalled gateway (rc 5 —
# exit-code contract, scripts/oc-health-check.py::EXIT_BY_SUMMARY) took the FAILURE
# branch: it discarded the whole JSON and reported gateway health as "unknown", which
# is the wrong outcome these cases are named for.  The three codes now mean the same
# thing in both commands — 0 clean, 5 stalled (alert, do not restart), 1 any other
# issue (repair or restart is legitimate) — so a consumer of either can tell the two
# apart, which is the whole point of giving `stalled` its own code.
#
# The harness: 33's setup already sources 01/02/03/05/09e with a sandboxed HOME, and
# 11a is sourced HERE for `__llm_json_escape` (the json field must be readable, since
# that is the only channel in --json mode — `__oc_note` is silent there).  Every probe
# is stubbed AFTER the sources, module-locally, so no live gateway, port or config is
# touched.  `oc-health` is a shell FUNCTION here: the consumer calls it as one.
doctor_local_prelude() {
    # shellcheck source=scripts/11a-llm-registry.sh
    source "$REPO_ROOT/scripts/11a-llm-registry.sh"
    export __TAC_OPENCLAW_OK=1 LLM_SERVICE_PORT=18081 OC_PORT=18789
    export TAC_CACHE_DIR="$BATS_TEST_TMPDIR/tac-cache" OC_ROOT="$BATS_TEST_TMPDIR/oc"
    mkdir -p "$TAC_CACHE_DIR" "$OC_ROOT"
    : > "$TAC_CACHE_DIR/tac_win_api_keys"
    printf '%s\n' '{}' > "$OC_ROOT/openclaw.json"
    __test_port() { return 0; }
    __llm_is_healthy() { return 0; }
    __llm_active_entry() { printf '%s\n' '1|Model One|model-one.gguf'; }
    openclaw() { printf '{"local":{"baseUrl":"http://127.0.0.1:%s/v1"}}\n' "$LLM_SERVICE_PORT"; }
}

# A checker stub that answers like the real one for a given status/code pair.  The two
# values are GLOBALS, not locals of this helper: bash closes over variables dynamically,
# so a `local` here would be gone by the time `oc-doctor-local` actually calls the stub
# (and naming one `status` would collide with bats' own `$status`).
STUB_OC_HEALTH_STATUS=""
STUB_OC_HEALTH_RC=0
stub_oc_health() {
    STUB_OC_HEALTH_STATUS="$1"
    STUB_OC_HEALTH_RC="$2"
    oc-health() {
        printf '{"checks":[{"name":"gateway_health","status":"%s","message":"gateway health: %s"}]}\n' \
            "$STUB_OC_HEALTH_STATUS" "$STUB_OC_HEALTH_STATUS"
        return "$STUB_OC_HEALTH_RC"
    }
}

@test "oc doctor-local: a stalled gateway reads STALLED from the code, not 'unknown', and exits 5" {
    doctor_local_prelude
    stub_oc_health stalled 5

    run oc-doctor-local --json

    [ "$status" -eq 5 ] || { echo "a stall exited $status, not 5 (alert, do not restart)"; return 1; }
    # The wrong outcome this catches: the report being thrown away and the state flattened.
    [[ "$output" == *'"gateway_health":"stalled"'* ]] \
        || { echo "the json field does not carry the stall: $output"; return 1; }
    [[ "$output" != *'"gateway_health":"unknown"'* ]] \
        || { echo "the stall was flattened to 'unknown'"; return 1; }
    # A stall is not healthy, so it is still counted as an issue.
    [[ "$output" == *'"issues":1'* ]] \
        || { echo "the stall was not counted as an issue: $output"; return 1; }
}

@test "oc doctor-local: a stall is NAMED in human mode with the action it needs" {
    doctor_local_prelude
    stub_oc_health stalled 5

    run oc-doctor-local

    [ "$status" -eq 5 ]
    [[ "$output" == *"gateway stalled — alert, do not restart"* ]] \
        || { echo "human mode does not name the stall and its action: $output"; return 1; }
    [[ "$output" == *"Gateway Health"*"[STALLED]"* ]] \
        || { echo "the row does not read STALLED: $output"; return 1; }
}

@test "oc doctor-local: 0 clean and 1 for a genuine failure keep their meaning" {
    doctor_local_prelude

    # Clean: every probe healthy and the checker's own verdict is ok.
    stub_oc_health ok 0
    run oc-doctor-local --json
    [ "$status" -eq 0 ] || { echo "a clean run exited $status, not 0"; return 1; }
    [[ "$output" == *'"gateway_health":"ok"'* ]]
    [[ "$output" == *'"issues":0'* ]]

    # A genuine failure: the checker failed, so its report is unusable — "repair or
    # restart is legitimate" — and that must NOT be reported as a stall.
    stub_oc_health fail 1
    run oc-doctor-local --json
    [ "$status" -eq 1 ] || { echo "a genuine failure exited $status, not 1"; return 1; }
    [[ "$output" == *'"gateway_health":"unknown"'* ]]
}

# ==============================================================================
# The second patch: the VS Code Testing results logger
# ==============================================================================
# Same contract, read from the patch tool's --check exit code: 0 patched, 1 a reverted
# copy, 2 no Python extension at all (not a fault), 3 the recorder file is missing.
# The stub is a FILE, not a function: the row runs the tool behind `timeout`, which
# EXECs its argument, so a shell function would never be reached.
stub_test_log_tool() {
    mkdir -p "$HOME/.local/bin"
    cat > "$HOME/.local/bin/vscode-pytest-log-patch.py" <<MOCK
#!/usr/bin/env bash
echo "  UNPATCHED  run_pytest_script.py"
exit $1
MOCK
    chmod +x "$HOME/.local/bin/vscode-pytest-log-patch.py"
}

@test "test log patch: a patched box reports APPLIED" {
    stub_test_log_tool 0

    run __oc_vscode_pytest_log_state
    [ "$status" -eq 0 ]
    [[ "$output" == *"Test log patch"* ]]
    [[ "$output" == *"[APPLIED]"* ]]
    [[ "$output" != *"NOT APPLIED"* ]]
}

@test "test log patch: a reverted patch blames the extension update, and names the way back" {
    stub_test_log_tool 1

    run __oc_vscode_pytest_log_state
    [ "$status" -eq 0 ]
    [[ "$output" == *"[NOT APPLIED - an extension update reverts this]"* ]]
    # The reader needs the check's own words and the command that re-applies it —
    # naming an update without a remedy is the 2026-09-27 failure this file records.
    [[ "$output" == *"UNPATCHED"* ]]
    [[ "$output" == *"vscode-pytest-log-patch.py --apply re-applies it"* ]]
}

@test "test log patch: a box with no Python extension is reported, not treated as broken" {
    stub_test_log_tool 2

    run __oc_vscode_pytest_log_state
    [ "$status" -eq 0 ]
    [[ "$output" == *"[no Python extension installed]"* ]]
    [[ "$output" != *"NOT APPLIED"* ]]
}

@test "test log patch: a missing recorder is named as itself, not as an update reversion" {
    # Exit 3 is a different fault with a different remedy (restore the file), so the
    # row must not send the reader to re-apply a patch that is already applied.
    stub_test_log_tool 3

    run __oc_vscode_pytest_log_state
    [ "$status" -eq 0 ]
    [[ "$output" == *"[NOT APPLIED - the recorder is missing]"* ]]
    [[ "$output" != *"extension update"* ]]
}

@test "test log patch: a box without the tool at all is reported, not treated as broken" {
    [ ! -e "$HOME/.local/bin/vscode-pytest-log-patch.py" ]

    run __oc_vscode_pytest_log_state
    [ "$status" -eq 0 ]
    [[ "$output" == *"[not installed]"* ]]
    [[ "$output" != *"NOT APPLIED"* ]]
}

@test "test log patch: the row is wired into the enhanced-checker branch as well" {
    mkdir -p "$HOME/.openclaw/workspace/scripts"
    cat > "$HOME/.openclaw/workspace/scripts/oc-health-check.py" <<'PYSTUB'
print("STUB-ENHANCED-CHECKER")
PYSTUB
    export TAC_PYTHON="${TAC_PYTHON:-python3}"
    stub_test_log_tool 1

    run oc-health
    [[ "$output" == *"STUB-ENHANCED-CHECKER"* ]]
    [[ "$output" == *"Test log patch"* ]]
    [[ "$output" == *"[NOT APPLIED"* ]]
}

@test "test log patch: --json stays clear of the row" {
    mkdir -p "$HOME/.openclaw/workspace/scripts"
    cat > "$HOME/.openclaw/workspace/scripts/oc-health-check.py" <<'PYSTUB'
print('{"checks": []}')
PYSTUB
    export TAC_PYTHON="${TAC_PYTHON:-python3}"

    run oc-health --json
    [[ "$output" != *"Test log patch"* ]]
}
# ==============================================================================
# The markdownlint shim: a full-config --fix must fail closed
# ==============================================================================
# The criterion is the shim's own CONTRACT block (bin/markdownlint): a full-config
# --fix is refused before anything else happens, the fixable config passes through,
# reporting is never restricted, and MARKDOWNLINT_ALLOW_FULL_FIX=1 is the stated
# escape.  Measured 2026-09-30, a full-config fix rewrote a quoted "+ …" to "- …"
# (MD004), and turned a wrapped "#144627/…" into a heading (MD018) — then linted
# clean, so a green exit code was no evidence the text survived.
#
# MARKDOWNLINT_REAL exists so a pass-through case can point at a stub: CI has no
# linuxbrew linter, and an assertion about pass-through must not depend on one
# being installed.  The refusal case deliberately does NOT set it — refusing must
# need no linter at all.
stub_linter() {
    cat > "$BATS_TEST_TMPDIR/linter-stub" <<'MOCK'
#!/usr/bin/env bash
printf 'STUB-LINTER %s\n' "$*"
exit 0
MOCK
    chmod +x "$BATS_TEST_TMPDIR/linter-stub"
    printf '%s' "$BATS_TEST_TMPDIR/linter-stub"
}

@test "markdownlint shim: a full-config --fix is refused, and nothing is written" {
    printf '%s\n' 'a note with trailing spaces   ' > "$BATS_TEST_TMPDIR/note.md"
    local before
    before="$(cat "$BATS_TEST_TMPDIR/note.md")"

    run "$REPO_ROOT/bin/markdownlint" --config "$REPO_ROOT/.markdownlint.json" --fix "$BATS_TEST_TMPDIR/note.md"

    [ "$status" -eq 2 ]
    [[ "$output" == *"refusing --fix under a full config"* ]]
    [[ "$output" == *"markdownlint-fixable.jsonc"* ]]
    [ "$(cat "$BATS_TEST_TMPDIR/note.md")" = "$before" ]
}

@test "markdownlint shim: the fixable config passes through to the linter" {
    mkdir -p "$HOME/.qwen"
    : > "$HOME/.qwen/.markdownlint-fixable.jsonc"
    local stub
    stub="$(stub_linter)"

    run env MARKDOWNLINT_REAL="$stub" "$REPO_ROOT/bin/markdownlint" \
        --config "$HOME/.qwen/.markdownlint-fixable.jsonc" --fix "$BATS_TEST_TMPDIR/note.md"

    [ "$status" -eq 0 ]
    [[ "$output" == *"STUB-LINTER"* ]]
}

@test "markdownlint shim: reporting is never restricted - no --fix passes through" {
    local stub
    stub="$(stub_linter)"

    run env MARKDOWNLINT_REAL="$stub" "$REPO_ROOT/bin/markdownlint" \
        --config /any/other/config.json "$BATS_TEST_TMPDIR/note.md"

    [ "$status" -eq 0 ]
    [[ "$output" == *"STUB-LINTER"* ]]
}

@test "markdownlint shim: the stated override passes a full fix through" {
    local stub
    stub="$(stub_linter)"

    run env MARKDOWNLINT_ALLOW_FULL_FIX=1 MARKDOWNLINT_REAL="$stub" \
        "$REPO_ROOT/bin/markdownlint" --config /any/other/config.json --fix "$BATS_TEST_TMPDIR/note.md"

    [ "$status" -eq 0 ]
    [[ "$output" == *"STUB-LINTER"* ]]
}
