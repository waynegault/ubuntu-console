#!/usr/bin/env bats
# ==============================================================================
# Unit — the VS Code Testing results-logger patcher's four --check codes
# ==============================================================================
# bin/vscode-pytest-log-patch.py wires a recorder into the VS Code Python
# extension's pytest wrapper (one copy per installed extension version), so every
# Testing run writes ~/.cache/vscode-pytest/<repo>-<hash8>/*.json.  An extension
# update REPLACES that wrapper and silently reverts the insertion, which is why
# bin/qwen-guard-selfheal.sh probes and re-applies it every cron tick — and why the
# tool's exit codes are a contract its consumers key on (`oc health`'s "Test log
# patch" row reports the state from them):
#
#   0  every installed copy is patched
#   1  at least one installed copy is unpatched (an extension update reverted it)
#   2  no ms-python.python extension copy found (nothing to patch -- not a fault)
#   3  the recorder file is missing from LIB_DIR (--apply REFUSES before patching)
#
# Only 1 is auto-repairable: the tick re-applies on 1, stays quiet on 2, and REPORTS
# 3 because no apply can restore a missing recorder.
#
# Hermetic: the tool derives EVERY path from $HOME (Path("~").expanduser()), so each
# case points HOME at a fixture tree under BATS_TEST_TMPDIR.  The real extension
# copies and ~/.local are never read or written.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    PATCHER="$REPO_ROOT/tools/vscode-pytest-log/vscode-pytest-log-patch.py"
    WORK="$BATS_TEST_TMPDIR"
    FIX="$WORK/home"
    WRAPPER="$FIX/.vscode-server/extensions/ms-python.python-9.9.9/python_files/vscode_pytest/run_pytest_script.py"
    LIB="$FIX/.local/lib/vscode-pytest-log"
    ANCHOR='if __name__ == "__main__":'
    mkdir -p "$FIX"
}

# A wrapper shaped like the extension's: importable, with exactly one anchor.
write_wrapper() {
    local anchors="${1:-1}" i
    mkdir -p "$(dirname "$WRAPPER")"
    {
        printf '%s\n' 'import pytest'
        for ((i = 0; i < anchors; i++)); do printf '%s\n' "$ANCHOR"; done
        printf '%s\n' '    pytest.main()'
    } > "$WRAPPER"
}

write_recorder() {
    mkdir -p "$LIB"
    printf '# stub recorder — the tool only checks that the file exists\n' > "$LIB/vscode_pytest_log.py"
}

@test "test-log patch: no extension copy at all is rc 2, and it writes nothing" {
    run env HOME="$FIX" "$PATCHER" --check
    [ "$status" -eq 2 ]
    [[ "$output" == *"no ms-python.python extension copy found"* ]]
    [ ! -e "$LIB" ]
}

@test "test-log patch: an extension copy with the recorder MISSING is rc 3, and --apply refuses before touching the wrapper" {
    write_wrapper 1
    before="$(sha256sum "$WRAPPER" | awk '{print $1}')"
    run env HOME="$FIX" "$PATCHER" --apply
    [ "$status" -eq 3 ]
    [[ "$output" == *"the recorder is missing from"* ]]
    # The refusal must be BEFORE any write: the wrapper is byte-identical and there
    # is no backup, so a future --apply cannot be fooled by a half-run.
    [ "$(sha256sum "$WRAPPER" | awk '{print $1}')" = "$before" ]
    [ ! -d "$LIB/backups" ]
}

@test "test-log patch: an unpatched copy is rc 1, --apply makes it rc 0, and the block lands exactly once" {
    write_wrapper 1
    write_recorder
    run env HOME="$FIX" "$PATCHER" --check
    [ "$status" -eq 1 ]
    [[ "$output" == *"UNPATCHED"* ]]

    run env HOME="$FIX" "$PATCHER" --apply
    [ "$status" -eq 0 ]
    [[ "$output" == *"patched (backup"* ]]
    [ "$(grep -c '^# >>> vscode-pytest-log >>>$' "$WRAPPER")" -eq 1 ]
    [ "$(grep -c '^# <<< vscode-pytest-log <<<$' "$WRAPPER")" -eq 1 ]
    # ...and the anchor count is preserved, so a second apply cannot double-insert.
    [ "$(grep -c "^${ANCHOR}$" "$WRAPPER")" -eq 1 ]

    run env HOME="$FIX" "$PATCHER" --check
    [ "$status" -eq 0 ]
    [[ "$output" == *"all installed copies are patched"* ]]
}

@test "test-log patch: a second --apply is idempotent and leaves the bytes alone" {
    write_wrapper 1
    write_recorder
    env HOME="$FIX" "$PATCHER" --apply >/dev/null 2>&1
    first="$(sha256sum "$WRAPPER" | awk '{print $1}')"
    run env HOME="$FIX" "$PATCHER" --apply
    [ "$status" -eq 0 ]
    [[ "$output" == *"already patched"* ]]
    [ "$(sha256sum "$WRAPPER" | awk '{print $1}')" = "$first" ]
}

@test "test-log patch: --revert restores the pristine wrapper, and a two-anchor wrapper is REFUSED not patched" {
    write_wrapper 1
    write_recorder
    pristine="$(sha256sum "$WRAPPER" | awk '{print $1}')"
    env HOME="$FIX" "$PATCHER" --apply >/dev/null 2>&1
    run env HOME="$FIX" "$PATCHER" --revert
    [ "$status" -eq 0 ]
    [[ "$output" == *"reverted"* ]]
    [ "$(sha256sum "$WRAPPER" | awk '{print $1}')" = "$pristine" ]

    # A wrapper whose anchor is ambiguous must not be patched blind.
    write_wrapper 2
    before="$(sha256sum "$WRAPPER" | awk '{print $1}')"
    run env HOME="$FIX" "$PATCHER" --apply
    [ "$status" -eq 0 ]
    [[ "$output" == *"REFUSED: 2 anchors, expected exactly one"* ]]
    [ "$(sha256sum "$WRAPPER" | awk '{print $1}')" = "$before" ]
}

# end of file
