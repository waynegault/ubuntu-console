#!/usr/bin/env bats
# ==============================================================================
# Unit — the daemon guard patch is visible where a human actually looks
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

@test "guard patch: the row prints on the path this box actually takes" {
    # No enhanced checker in the sandbox HOME, so oc-health takes its own fallback
    # path — the one it really uses here. __test_port comes from 06-hooks, which this
    # harness does not carry, so it is stubbed; the assertion is about OUR row.
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
