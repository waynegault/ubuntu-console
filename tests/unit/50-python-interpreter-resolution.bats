#!/usr/bin/env bats
# ==============================================================================
# Unit — the shell tools run Python under the project venv, not a bare python3
# ==============================================================================
# Card 117e3303.  A tool that invokes `python3` from PATH silently uses a
# different interpreter from the repo's .venv — which on this box is the only one
# carrying the project's dependencies (the venv is 3.14; system python3.12 lacks
# them).  tools/count-ratchet.sh already prefers $REPO_ROOT/.venv/bin/python3;
# this file covers the two remaining sites:
#
#   * tools/import-windows-env.sh — _tac_python_path() must print the venv python
#     when one exists and PATH python3 when none does.  The Windows bridge itself
#     cannot run under CI (no pwsh.exe), so the script's source guard lets these
#     cases exercise the resolver directly.
#   * scripts/09d-oc-agents.sh — its embedded JSON helpers must invoke the
#     profile's $TAC_PYTHON resolver, not a bare python3.
#
# Hermetic: sandbox .venv trees and a recording interpreter shim; no real config.
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
IMPORT_SCRIPT="$REPO_ROOT/tools/import-windows-env.sh"
MODULE="$REPO_ROOT/scripts/09d-oc-agents.sh"

setup() {
    TAC_TEST_TMPDIR="$(mktemp -d)"
    export TAC_TEST_TMPDIR
}

teardown() {
    rm -rf "$TAC_TEST_TMPDIR"
}

@test "import-windows-env resolves the repo venv python when one exists" {
    # Failure caught: the resolver returns a bare `python3` even though the repo
    # ships .venv/bin/python3, so the bridge would run under the wrong interpreter.
    run bash -c 'source "$1" >/dev/null 2>&1; _tac_python_path' _ "$IMPORT_SCRIPT"
    [ "$status" -eq 0 ]
    [ "$output" = "$REPO_ROOT/.venv/bin/python3" ]
    [ -x "$output" ]
}

@test "import-windows-env resolves a venv that ships only bin/python3" {
    # Failure caught: a resolver keyed on `.venv/bin/python` (no 3) misses a venv
    # that ships only the python3-suffixed binary and falls back to PATH python3.
    local sandbox="$TAC_TEST_TMPDIR/venv-only-python3"
    mkdir -p "$sandbox/tools" "$sandbox/.venv/bin"
    cp "$IMPORT_SCRIPT" "$sandbox/tools/import-windows-env.sh"
    printf '#!/bin/sh\nexit 0\n' > "$sandbox/.venv/bin/python3"
    chmod +x "$sandbox/.venv/bin/python3"

    run bash -c 'source "$1" >/dev/null 2>&1; _tac_python_path' _ \
        "$sandbox/tools/import-windows-env.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "$sandbox/.venv/bin/python3" ]
}

@test "import-windows-env falls back to PATH python3 when no venv exists" {
    # Failure caught: the fallback path stops working, so the tool becomes
    # unusable wherever the repo has no venv.
    local sandbox="$TAC_TEST_TMPDIR/no-venv"
    mkdir -p "$sandbox/tools"
    cp "$IMPORT_SCRIPT" "$sandbox/tools/import-windows-env.sh"

    run bash -c 'source "$1" >/dev/null 2>&1; _tac_python_path' _ \
        "$sandbox/tools/import-windows-env.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "python3" ]
}

@test "09d's JSON helper invokes TAC_PYTHON instead of a bare python3" {
    # Failure caught: the helper shells out to `python3` from PATH and ignores the
    # profile's TAC_PYTHON resolver, so the venv interpreter is bypassed.
    local shim="$TAC_TEST_TMPDIR/py-shim"
    export SHIM_LOG="$TAC_TEST_TMPDIR/shim.log"
    REAL_PY="$(command -v python3)"
    export REAL_PY
    cat > "$shim" <<'STUB'
#!/usr/bin/env bash
printf 'invoked\n' >> "$SHIM_LOG"
exec "$REAL_PY" "$@"
STUB
    chmod +x "$shim"

    # Sandbox what the helper reads so nothing host-specific is touched.
    export OPENCLAW_CONFIG_PATH="$TAC_TEST_TMPDIR/openclaw.json"
    export OPENCLAW_STATE_DIR="$TAC_TEST_TMPDIR/state"
    printf '{}\n' > "$OPENCLAW_CONFIG_PATH"
    mkdir -p "$OPENCLAW_STATE_DIR"

    # The helper reads only its arguments and shells out to the interpreter, so the
    # module sources on its own (its top guard sets __TAC_MOD_09D_OC_AGENTS_LOADED).
    run bash -c 'source "$1" >/dev/null 2>&1; export TAC_PYTHON="$2"; __oc_gateway_resolved_env_names' \
        _ "$MODULE" "$shim"
    [ "$status" -eq 0 ]
    [ -s "$SHIM_LOG" ]
}
