#!/usr/bin/env bats
# ==============================================================================
# Unit — the commit-time shell selection: tools/lint.sh --staged and the hook that
# calls it.
# ==============================================================================
# WHY THIS EXISTS.  Measured 2026-11-05, adding bin/llm-pull: the pre-commit hook
# printed "no staged .sh files — shell lint skipped" on the very commit that ADDED
# an extensionless bin/ script, because BOTH halves of the selection were `.sh`-only
# (the hook's own `grep '\.sh$'` and lint.sh's --staged mode).  `bin/` and
# `tools/hooks/` are extensionless by convention and `tactical-console.bashrc` has no
# suffix either, so the commit-time gate only covered half of the corpus the
# whole-tree loops check.  The same hook's early exit, keyed on that filter, also
# sat BEFORE the Python gates, so a commit staging only .py files skipped them.
#
# The expected values come from the two carriers' stated rule, not from their
# output: `lint.sh --staged` selects the SAME corpus the whole-tree loops above it
# cover (`.sh` anywhere, plus `tactical-console.bashrc`, `bin/*` and
# `tools/hooks/*`, with `_tac_is_shell` excluding a `.py` under bin/), and the hook
# keeps NO copy of that rule.
#
# Each case builds a throwaway git repo: lint.sh resolves REPO_ROOT from its own
# path, so a COPY at $SANDBOX/tools/lint.sh judges $SANDBOX and this tree is never
# touched.  The hook's cases stub the four neighbouring tools it calls, so what runs
# is the hook's own control flow plus the REAL lint.sh selection.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export REPO_ROOT
    SANDBOX="$BATS_TEST_TMPDIR/repo"
    export SANDBOX
    mkdir -p "$SANDBOX/tools/hooks" "$SANDBOX/bin" "$SANDBOX/scripts"

    cp "$REPO_ROOT/tools/lint.sh" "$SANDBOX/tools/lint.sh"
    chmod +x "$SANDBOX/tools/lint.sh"
    # An EMPTY module list: __tac_module_list must exist and print nothing, or the
    # graph-members pass reads a truncated module (the real list names files this
    # fixture does not carry, and awk's rc 2 would abort the run).
    printf '__tac_module_list() { :; }\n' > "$SANDBOX/scripts/_module-list.sh"
    # _tac_lint_coverage_guard requires every scripts/*.sh to be a member, a
    # via-consumer fragment, or a shebang'd entry point.
    printf '#!/usr/bin/env bash\ntrue\n' > "$SANDBOX/scripts/entry.sh"

    git -C "$SANDBOX" init -q
    _git commit -q --allow-empty -m base
}

teardown() {
    rm -rf "$SANDBOX"
}

_git() {
    git -C "$SANDBOX" -c user.email=t@example.invalid -c user.name=test "$@"
}

# A file bash -n must reject, whatever else the line does.
_broken_shell() {
    printf '#!/usr/bin/env bash\nif [ ; then\n' > "$1"
}

_lint_staged() {
    run "$SANDBOX/tools/lint.sh" --staged
}

@test "a staged extensionless bin script is linted, and a syntax error fails the run" {
    _broken_shell "$SANDBOX/bin/new-tool"
    chmod +x "$SANDBOX/bin/new-tool"
    _git add bin/new-tool

    _lint_staged
    # Catches the 2026-11-05 defect: with a `.sh`-only selection this exits 0 and
    # prints "(no staged .sh files)", so the script lands with no -n and no checker.
    [ "$status" -ne 0 ]
    [[ "$output" == *"FAIL  bin/new-tool  (syntax)"* ]]
}

@test "a valid extensionless bin script passes, so the selection is not failing everything" {
    printf '#!/usr/bin/env bash\nprintf "ok\\n"\n' > "$SANDBOX/bin/good-tool"
    chmod +x "$SANDBOX/bin/good-tool"
    _git add bin/good-tool

    _lint_staged
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS  bin/good-tool"* ]]
}

@test "tactical-console.bashrc is selected like any other shell file" {
    _broken_shell "$SANDBOX/tactical-console.bashrc"
    _git add tactical-console.bashrc

    _lint_staged
    [ "$status" -ne 0 ]
    [[ "$output" == *"FAIL  tactical-console.bashrc  (syntax)"* ]]
}

@test "a staged .py under bin/ is not read as shell" {
    # Valid Python, invalid bash: `x = 1` makes bash -n fail, so a suite that
    # selected it would red the commit for the one tracked Python tool's home.
    printf 'x = 1\n' > "$SANDBOX/bin/tool.py"
    _git add bin/tool.py

    _lint_staged
    [ "$status" -eq 0 ]
    [[ "$output" == *"(no staged shell files)"* ]]
    [[ "$output" != *"tool.py"* ]]
}

@test "a staged .sh outside scripts/ and bin/ is still selected" {
    printf '#!/usr/bin/env bash\ntrue\n' > "$SANDBOX/docs-example.sh"
    printf 'if [ ; then\n' >> "$SANDBOX/docs-example.sh"
    _git add docs-example.sh

    _lint_staged
    [ "$status" -ne 0 ]
    [[ "$output" == *"FAIL  docs-example.sh  (syntax)"* ]]
}

# ── the hook, which must add no selection of its own ─────────────────────────────

# A sandbox hook run: the four neighbouring tools are stubs (the subject is the
# hook's control flow plus lint.sh's selection), and no .venv means the Python step
# announces itself instead of running.
_stub_tool() {
    printf '#!/usr/bin/env bash\nexit 0\n' > "$SANDBOX/tools/$1"
    chmod +x "$SANDBOX/tools/$1"
}

_run_hook() {
    cp "$REPO_ROOT/tools/hooks/pre-commit" "$SANDBOX/tools/hooks/pre-commit"
    chmod +x "$SANDBOX/tools/hooks/pre-commit"
    _stub_tool secret-scan.sh
    _stub_tool check-swallows-staged.sh
    _stub_tool check-module-versions.sh
    _stub_tool check-ruff-pin.sh
    run "$SANDBOX/tools/hooks/pre-commit"
}

@test "the hook lints an extensionless bin script that the commit adds" {
    _broken_shell "$SANDBOX/bin/new-tool"
    chmod +x "$SANDBOX/bin/new-tool"
    _git add bin/new-tool

    _run_hook
    [ "$status" -ne 0 ]
    # The commit-time path, not only a manual lint run: this is the line the
    # 2026-11-05 commit never printed.
    [[ "$output" == *"FAIL  bin/new-tool  (syntax)"* ]]
}

@test "a .py-only commit still reaches the Python step" {
    printf 'x = 1\n' > "$SANDBOX/bin/tool.py"
    _git add bin/tool.py

    _run_hook
    # The old early exit fired on "no staged .sh files" and returned before this
    # step, so a Python-only commit skipped ruff entirely while the message claimed
    # only the shell lint was skipped.
    [[ "$output" != *"no staged .sh files"* ]]
    [[ "$output" == *"pre-commit: .venv/bin/pre-commit not found"* ]]
    [[ "$output" == *"(no staged shell files)"* ]]
}
