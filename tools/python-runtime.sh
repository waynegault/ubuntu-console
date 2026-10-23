#!/usr/bin/env bash
# AI INSTRUCTION: Increment version on significant changes.
# Module Version: 4
#   v4 (2026-10-22): a LINKED WORKTREE resolves the PRIMARY checkout's venv.  The
#   pre-push hook materialises HEAD with `git worktree add` and runs the gates there;
#   that tree has no .venv of its own, so the probe fell through to PATH, where
#   Homebrew's python3 has no PyYAML — and tools/check-contracts.sh refused ("a
#   partial contract check is a silent pass") on every push made with a dirty tree.
#   Measured 2026-10-22 on two consecutive pushes.
#   v3 (2026-10-16): added the repo's `# end of file` sentinel, which this file never carried -
#   the nightly's hygiene case ("tools/*.sh scripts end with # end of file marker") only runs
#   nightly, so push CI stayed green while the tip was red there.
#   v2 (2026-10-15): reject a configured TAC_PYTHON that cannot be executed.

# _tac_python_path <repo-root> — prefer the repository venv (also when <repo-root>
# is a LINKED WORKTREE, whose venv lives in the primary checkout), then an explicit
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

    # A LINKED WORKTREE CARRIES NO .venv OF ITS OWN.  The pre-push hook materialises
    # HEAD with `git worktree add` and runs the gates there, so the venv holding the
    # project's dependencies is in the PRIMARY checkout.  Ask git where that is (the
    # common dir's parent) and probe it — the normal main-checkout path never reaches
    # this block, because the loop above answered.
    if [[ -d "$repo_root" ]]
    then
        local common_dir=""
        # swallow-ok: a non-repository root is EXPECTED here (fixture trees, e.g. tests/unit/50); git's "not a git repository" line is not an error, and the override/PATH fallbacks below still decide
        if ! common_dir="$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
        then
            common_dir=""
        fi
        if [[ -n "$common_dir" ]]
        then
            local main_root="${common_dir%/*}"
            for candidate in "$main_root/.venv/bin/python3" "$main_root/.venv/bin/python"; do
                if [[ -x "$candidate" ]]; then
                    printf '%s\n' "$candidate"
                    return 0
                fi
            done
        fi
    fi

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

# end of file
