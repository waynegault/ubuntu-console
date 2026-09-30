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
