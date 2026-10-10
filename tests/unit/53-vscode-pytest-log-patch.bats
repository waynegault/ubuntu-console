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
    # The recorder runs as a pytest PLUGIN, so its cases need an interpreter that has pytest.
    # Prefer the repo venv (this box's only pytest-carrying interpreter), else PATH python3 — the
    # same prefer-venv-else-PATH shape tools/count-ratchet.sh:74 and import-windows-env.sh's
    # _tac_python_path use.  A hardcoded "$REPO_ROOT/.venv/bin/python3" was a HOST-ONLY path:
    # .venv is gitignored and actions/checkout cleans it, so on the CI runner the path does not
    # exist and the three recorder cases below died with `env: …: No such file or directory`
    # (exit 127, run 38041966565 — red).  Resolve, then VERIFY pytest imports; where no
    # interpreter carries it the cases SKIP with a printed reason rather than fail on a path that
    # only a dev box has (the same "a test for a host could not pass on the host" defect
    # tests/unit/50-python-interpreter-resolution.bats:38 records).
    PY="$REPO_ROOT/.venv/bin/python3"
    if [[ ! -x "$PY" ]]; then
        PY="$(command -v python3 2>/dev/null || true)"
    fi
    if [[ -z "$PY" ]] || ! "$PY" -c 'import pytest' >/dev/null 2>&1; then
        PY=""
    fi
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

# ── The recorder's own contract: a run that produced NOTHING must say why ──────────────────
# Measured 2026-10-10 in the investigator workspace: the Testing panel passes every selected node id
# EXPLICITLY, so ONE id that no longer exists — a renamed test — makes pytest treat the whole
# selection as a usage error: it collects everything, runs nothing and exits 4.  The results file
# carried only `exit_status: 4` with `counts.total: 0`, so nothing on disk said why.  The first two
# cases pin the fields that now explain it; the third pins that a HEALTHY run grows neither, because
# a field that always appears reads as "no errors" without anyone having checked.

write_tiny_test() {
    cat > "$WORK/test_tiny.py" <<'PY'
def test_tiny() -> None:
    assert True
PY
}

# Run the recorder as a plugin on $1 (a pytest argument), with its log dir redirected so the case
# never touches ~/.cache, and never loads a conftest from the repo (cwd and arg both live in $WORK).
run_recorder_on() {
    local logdir="$1"; shift
    env -C "$WORK" VSCODE_PYTEST_LOG_DIR="$logdir" \
        PYTHONPATH="$REPO_ROOT/tools/vscode-pytest-log" \
        "$PY" -m pytest -q -p vscode_pytest_log "$@"
}

latest_json() {
    ls "$1"/*/latest.json | head -1
}

@test "test-log recorder: a selection pytest cannot collect records WHY (usage_error names the id)" {
    [ -n "$PY" ] || skip "no pytest-capable interpreter (no $REPO_ROOT/.venv, and PATH python3 lacks pytest)"
    LOGDIR="$WORK/vpl-usage"; mkdir -p "$LOGDIR"; write_tiny_test
    run run_recorder_on "$LOGDIR" "$WORK/test_tiny.py::NoSuchClass::no_such_test"
    [ "$status" -eq 4 ]
    run "$PY" -c "import json,sys; print(json.load(open(sys.argv[1])).get('usage_error',''))" "$(latest_json "$LOGDIR")"
    [ "$status" -eq 0 ]
    [[ "$output" == *"not found"* ]]
    [[ "$output" == *"no_such_test"* ]]
}

@test "test-log recorder: a file that cannot be imported records its collection error" {
    [ -n "$PY" ] || skip "no pytest-capable interpreter (no $REPO_ROOT/.venv, and PATH python3 lacks pytest)"
    LOGDIR="$WORK/vpl-collect"; mkdir -p "$LOGDIR"
    printf 'def test_broken(:\n' > "$WORK/test_broken.py"
    run run_recorder_on "$LOGDIR" "$WORK/test_broken.py"
    [ "$status" -eq 2 ]
    run "$PY" -c "import json,sys; d=json.load(open(sys.argv[1])); ce=d.get('collection_errors') or []; print(ce[0]['nodeid'] if ce else 'MISSING')" "$(latest_json "$LOGDIR")"
    [ "$status" -eq 0 ]
    [[ "$output" == *"test_broken.py"* ]]
}

@test "test-log recorder: a healthy run grows NEITHER error field" {
    [ -n "$PY" ] || skip "no pytest-capable interpreter (no $REPO_ROOT/.venv, and PATH python3 lacks pytest)"
    LOGDIR="$WORK/vpl-ok"; mkdir -p "$LOGDIR"; write_tiny_test
    run run_recorder_on "$LOGDIR" "$WORK/test_tiny.py"
    [ "$status" -eq 0 ]
    run "$PY" -c "import json,sys; d=json.load(open(sys.argv[1])); print('usage_error' in d, 'collection_errors' in d, d['counts']['total'])" "$(latest_json "$LOGDIR")"
    [ "$status" -eq 0 ]
    [ "$output" = "False False 1" ]
}

# end of file
