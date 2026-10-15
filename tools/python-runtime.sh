#!/usr/bin/env bash
# AI INSTRUCTION: Increment version on significant changes.
# Module Version: 2
#   v2 (2026-10-15): reject a configured TAC_PYTHON that cannot be executed.

# _tac_python_path <repo-root> — prefer the repository venv, then an explicit
# TAC_PYTHON override, then PATH python3. Return a clear error if none is usable.
_tac_python_path() {
    local repo_root="${1:?repository root is required}"
    local candidate

    for candidate in "$repo_root/.venv/bin/python3" "$repo_root/.venv/bin/python"; do
        if [[ -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    if [[ -n "${TAC_PYTHON:-}" ]]; then
        if [[ "$TAC_PYTHON" == */* ]]; then
            if [[ -x "$TAC_PYTHON" ]]; then
                printf '%s\n' "$TAC_PYTHON"
                return 0
            fi
        elif command -v "$TAC_PYTHON" >/dev/null 2>&1; then
            printf '%s\n' "$TAC_PYTHON"
            return 0
        fi
        printf 'python-runtime: TAC_PYTHON is not executable or on PATH: %s\n' \
            "$TAC_PYTHON" >&2
        return 127
    fi

    if command -v python3 >/dev/null 2>&1; then
        printf '%s\n' python3
        return 0
    fi

    printf '%s\n' "python-runtime: no repository venv, TAC_PYTHON, or PATH python3" >&2
    return 127
}
