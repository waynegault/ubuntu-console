#!/usr/bin/env bats
# ==============================================================================
# Unit — standalone scripts must REPORT a failed profile-module source
# ==============================================================================
# WHY THIS EXISTS (card f5bf87bc, AUDIT-2026-10-02): three standalone scripts
# re-sourced the profile modules with `source <mod> 2>/dev/null || true`, discarding
# BOTH the error and the exit status.  A module that failed to source (syntax error,
# missing file, broken dependency) left the script running with none of the
# definitions it later calls — silently.  The fix routes the load through the existing
# shared helper `__tac_source_submodules`, which names a missing file AND a file that
# exists but fails to source (and counts it in __TAC_SUBMODULE_FAILURES).
#
# These cases assert the PROPERTY a reader gets — a named report on stderr — both
# statically (the swallow is gone) and behaviourally (the helper reports a seeded
# broken module).
#
# FALSIFICATION (2026-10-02): against the pre-fix tree the first case fails — the
# scripts carried `source scripts/01-constants.sh 2>/dev/null || true` (and friends),
# so a broken module printed nothing.
#
# HERMETIC: the helper is exercised against throwaway modules under $SANDBOX; no
# module in the repo is touched, and nothing reaches the GPU or the network.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export REPO_ROOT
    SANDBOX="$(mktemp -d)"
    export SANDBOX
    mkdir -p "$SANDBOX/scripts"
}

teardown() {
    cd /
    rm -rf "$SANDBOX"
}

@test "guarded source: the standalone scripts no longer swallow the module source" {
    local f
    for f in scripts/autotune-model.sh scripts/spec-decode-bench.sh scripts/spec_dec_crossover.sh; do
        # The exact swallowed forms are gone...
        ! grep -Eq 'source +scripts/(01-constants|11-llm-manager|prompt-sets)\.sh +2>/dev/null' "$REPO_ROOT/$f" || {
            echo "$f still swallows a module source"
            return 1
        }
        # ...and the load now goes through the reporting helper.
        grep -q '__tac_source_submodules' "$REPO_ROOT/$f" || {
            echo "$f does not load its modules through __tac_source_submodules"
            return 1
        }
    done
}

@test "guarded source: a broken module is REPORTED, not swallowed" {
    printf 'if then fi (( (\n' > "$SANDBOX/scripts/01-constants.sh"
    cat > "$SANDBOX/drive.sh" <<DRIVE
#!/usr/bin/env bash
source "$REPO_ROOT/scripts/_startup-env.sh"
__tac_source_submodules "$SANDBOX/scripts" "unit-label" 01-constants
printf 'FAILURES=%s\n' "\${__TAC_SUBMODULE_FAILURES:-0}"
DRIVE
    run bash "$SANDBOX/drive.sh"
    [[ "$output" == *"unit-label: sub-module"*"failed to load"* ]]
    [[ "$output" == *"FAILURES=1"* ]]
}

@test "guarded source: a missing module is REPORTED" {
    run bash -c "source '$REPO_ROOT/scripts/_startup-env.sh'; __tac_source_submodules '$SANDBOX/scripts' 'unit-label' absent-module"
    [[ "$output" == *"unit-label: missing sub-module"* ]]
}

@test "guarded source: a clean module loads with no report" {
    printf 'printf "loaded\\n"\n' > "$SANDBOX/scripts/ok-mod.sh"
    run bash -c "source '$REPO_ROOT/scripts/_startup-env.sh'; __tac_source_submodules '$SANDBOX/scripts' 'unit-label' ok-mod"
    [[ "$output" != *"failed to load"* ]]
    [[ "$output" != *"missing sub-module"* ]]
}
