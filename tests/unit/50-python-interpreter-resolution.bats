#!/usr/bin/env bats
# ==============================================================================
# Unit — the shell tools run Python under the project venv, not a bare python3
# ==============================================================================
# Card 117e3303.  A tool that invokes `python3` from PATH silently uses a
# different interpreter from the repo's .venv — which on this box is the only one
# carrying the project's dependencies (the venv is 3.14; system python3.12 lacks
# them).  tools/count-ratchet.sh already prefers $REPO_ROOT/.venv/bin/python3;
# this file covers the shared resolver and every remaining inline-Python caller:
#
#   * tools/python-runtime.sh — _tac_python_path() must prefer the repository venv,
#     then an explicit TAC_PYTHON, then PATH python3.
#   * tools/import-windows-env.sh and standalone bin/scripts callers must use that
#     resolver rather than bypassing it with a bare python3.
#   * scripts/09d-oc-agents.sh — its embedded JSON helpers must invoke the
#     profile's $TAC_PYTHON resolver, not a bare python3.
#
# Hermetic: sandbox .venv trees and a recording interpreter shim; no real config.
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
PYTHON_RUNTIME="$REPO_ROOT/tools/python-runtime.sh"
MODULE="$REPO_ROOT/scripts/09d-oc-agents.sh"

setup() {
    TAC_TEST_TMPDIR="$(mktemp -d)"
    export TAC_TEST_TMPDIR
}

teardown() {
    rm -rf "$TAC_TEST_TMPDIR"
}

@test "python runtime prefers venv python3 when both venv binaries exist" {
    local sandbox="$TAC_TEST_TMPDIR/venv-both"
    mkdir -p "$sandbox/.venv/bin"
    printf '#!/bin/sh\nexit 0\n' > "$sandbox/.venv/bin/python"
    printf '#!/bin/sh\nexit 0\n' > "$sandbox/.venv/bin/python3"
    chmod +x "$sandbox/.venv/bin/python" "$sandbox/.venv/bin/python3"

    unset TAC_PYTHON
    source "$PYTHON_RUNTIME"
    run _tac_python_path "$sandbox"
    [ "$status" -eq 0 ]
    [ "$output" = "$sandbox/.venv/bin/python3" ]
    [ -x "$output" ]
}

@test "python runtime resolves a venv that ships only bin/python3" {
    local sandbox="$TAC_TEST_TMPDIR/venv-only-python3"
    mkdir -p "$sandbox/.venv/bin"
    printf '#!/bin/sh\nexit 0\n' > "$sandbox/.venv/bin/python3"
    chmod +x "$sandbox/.venv/bin/python3"

    unset TAC_PYTHON
    source "$PYTHON_RUNTIME"
    run _tac_python_path "$sandbox"
    [ "$status" -eq 0 ]
    [ "$output" = "$sandbox/.venv/bin/python3" ]
}

@test "python runtime resolves a venv that ships only bin/python" {
    local sandbox="$TAC_TEST_TMPDIR/venv-only-python"
    mkdir -p "$sandbox/.venv/bin"
    printf '#!/bin/sh\nexit 0\n' > "$sandbox/.venv/bin/python"
    chmod +x "$sandbox/.venv/bin/python"

    unset TAC_PYTHON
    source "$PYTHON_RUNTIME"
    run _tac_python_path "$sandbox"
    [ "$status" -eq 0 ]
    [ "$output" = "$sandbox/.venv/bin/python" ]
}

@test "python runtime uses TAC_PYTHON when no repository venv exists" {
    local sandbox="$TAC_TEST_TMPDIR/no-venv"
    mkdir -p "$sandbox"
    local shim="$TAC_TEST_TMPDIR/python-override"
    printf '#!/bin/sh\nexit 0\n' > "$shim"
    chmod +x "$shim"

    export TAC_PYTHON="$shim"
    source "$PYTHON_RUNTIME"
    run _tac_python_path "$sandbox"
    [ "$status" -eq 0 ]
    [ "$output" = "$shim" ]
}

@test "python runtime rejects an unavailable TAC_PYTHON override" {
    local sandbox="$TAC_TEST_TMPDIR/no-venv-invalid-override"
    mkdir -p "$sandbox" "$TAC_TEST_TMPDIR/empty-path"

    local saved_path="$PATH"
    export TAC_PYTHON="$TAC_TEST_TMPDIR/missing-python"
    export PATH="$TAC_TEST_TMPDIR/empty-path"
    source "$PYTHON_RUNTIME"
    run _tac_python_path "$sandbox"
    export PATH="$saved_path"
    [ "$status" -eq 127 ]
    [[ "$output" == *"TAC_PYTHON is not executable or on PATH"* ]]
}

@test "python runtime falls back to PATH python3 when no venv or override exists" {
    local sandbox="$TAC_TEST_TMPDIR/no-venv"
    mkdir -p "$sandbox"

    unset TAC_PYTHON
    source "$PYTHON_RUNTIME"
    run _tac_python_path "$sandbox"
    [ "$status" -eq 0 ]
    [ "$output" = "python3" ]
}

@test "inline Python callers use the shared interpreter resolver" {
    for script in \
        "$REPO_ROOT/tools/import-windows-env.sh" \
        "$REPO_ROOT/bin/qwen-memory-index-patch.sh" \
        "$REPO_ROOT/bin/qwen-guard-patch.sh" \
        "$REPO_ROOT/bin/qwen-memory-style-patch.sh" \
        "$REPO_ROOT/bin/llama-watchdog-guard.sh" \
        "$REPO_ROOT/scripts/qwen-transcript-retention.sh"
    do
        grep -qF 'tools/python-runtime.sh' "$script"
        grep -qF '_tac_python_path' "$script"
    done
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
