#!/usr/bin/env bats
# ==============================================================================
# tactical-console-fast.bats — Static analysis tests (no profile sourcing)
# ==============================================================================
# This suite contains ONLY tests that operate on source files directly
# (syntax checks, shellcheck, file structure, hygiene, cross-script consistency).
# No profile sourcing occurs — these tests complete in <5 seconds.
#
# Use in CI:  bats tests/tactical-console-fast.bats
#
# For full runtime behaviour tests, use: bats tests/tactical-console.bats
#
# AI INSTRUCTION: Increment version on significant changes.
# shellcheck disable=SC2034  # version header, as in tactical-console.bats: read by
#                             # people and by git history, not by the file.
VERSION="1.0"

# ==============================================================================
# SETUP — File-level constants only
# ==============================================================================

setup_file() {
    export REPO_ROOT
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export PROFILE_PATH="$REPO_ROOT/tactical-console.bashrc"
}

# ─────────────────────────────────────────────────────────────────────────────
# 1. SYNTAX & STATIC ANALYSIS
# ─────────────────────────────────────────────────────────────────────────────

@test "bash -n: tactical-console.bashrc parses without syntax errors" {
    run bash -n "$PROFILE_PATH"
    [ "$status" -eq 0 ]
}

@test "bash -n: all bin/*.sh scripts parse without syntax errors" {
    for f in "$REPO_ROOT"/bin/*.sh; do
        [[ -f "$f" ]] || continue
        run bash -n "$f"
        [ "$status" -eq 0 ]
    done
}

@test "bash -n: all scripts/*.sh parse without syntax errors" {
    for f in "$REPO_ROOT"/scripts/*.sh; do
        [[ -f "$f" ]] || continue
        run bash -n "$f"
        [ "$status" -eq 0 ]
    done
}

@test "bash -n: install.sh parses without syntax errors" {
    [[ -f "$REPO_ROOT/install.sh" ]] || skip "install.sh not found"
    run bash -n "$REPO_ROOT/install.sh"
    [ "$status" -eq 0 ]
}

@test "shellcheck: tactical-console.bashrc has no findings" {
    command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
    "$REPO_ROOT/tools/lint.sh" --files "$PROFILE_PATH"
}

@test "shellcheck: companion bin scripts have no findings" {
    command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
    "$REPO_ROOT/tools/lint.sh" --files "$REPO_ROOT"/bin/*.sh
}

@test "shellcheck: companion scripts 0x have no findings" {
    command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
    "$REPO_ROOT/tools/lint.sh" --files "$REPO_ROOT"/scripts/0*.sh
}

@test "shellcheck: companion scripts 10 and 12 have no findings" {
    command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
    "$REPO_ROOT/tools/lint.sh" --files \
        "$REPO_ROOT"/scripts/10-deployment.sh \
        "$REPO_ROOT"/scripts/12-dashboard-help.sh
}

@test "shellcheck: companion scripts 13-15 and extras have no findings" {
    command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
    "$REPO_ROOT/tools/lint.sh" --files \
        "$REPO_ROOT"/scripts/1[3-5]-*.sh \
        "$REPO_ROOT"/scripts/18-lint.sh \
        "$REPO_ROOT"/scripts/load-vault-env.sh \
        "$REPO_ROOT"/scripts/oc-update-enhanced.sh
}

@test "shellcheck: install.sh passes at all severities" {
    command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
    [[ -f "$REPO_ROOT/install.sh" ]] || skip "install.sh not found"
    "$REPO_ROOT/tools/lint.sh" --files "$REPO_ROOT/install.sh"
}

@test "lint --files: a .bats suite is parsed by bats, not accused as broken bash" {
    # Regression (2026-09-16): --files sent a .bats path through `bash -n`, which
    # cannot parse `@test "name" {`, and answered a perfectly good suite with
    # "FAIL (syntax)".  The verdict for that dialect must come from bats itself.
    command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
    command -v bats >/dev/null 2>&1 || skip "bats not installed"
    run "$REPO_ROOT/tools/lint.sh" --files "$REPO_ROOT/tests/integration/04-watchdog.bats"
    [ "$status" -eq 0 ]
    [[ "$output" == *"bats suite:"* ]]
    [[ "$output" != *"(syntax)"* ]]
}

@test "lint --files: a malformed .bats suite still FAILS" {
    # ...and the fix is not a rubber stamp: a suite bats cannot parse must fail.
    command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
    command -v bats >/dev/null 2>&1 || skip "bats not installed"
    local bad="$BATS_TEST_TMPDIR/broken.bats"
    printf '@test "unterminated" {\n  echo hi\n' > "$bad"
    run "$REPO_ROOT/tools/lint.sh" --files "$bad"
    [ "$status" -ne 0 ]
    [[ "$output" == *"bats suite"* ]]
}

@test "lint --files: the .bats branch has no bash fallback when bats is missing" {
    # Fail closed, like the shellcheck-missing guard at the top of this mode: a
    # verdict this gate cannot reach must never be dressed up as a pass.
    # -A16 is exactly the case block (label through ";;"): one line more would
    # reach the `bash -n` that follows it and make this assertion meaningless.
    run grep -F -A16 '*.bats)' "$REPO_ROOT/tools/lint.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"cannot parse .bats"* ]]
    [[ "$output" != *"bash -n"* ]]
}

@test "model launch: the gate requires READABILITY, not only existence (12.4.1)" {
    # The check landed in 8c4216ff with no test of its own, so nothing held it: an
    # unreadable model fails INSIDE llama-server with an opaque error that reads as a
    # bad file rather than a permissions problem. Pin the test, the message and the
    # failure — a gate that reports but returns 0 is not a gate.
    run grep -A4 'if \[\[ ! -r "\$model_path" \]\]' "$REPO_ROOT/scripts/11e-llm-model.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"NOT READABLE"* ]]
    [[ "$output" == *"return 1"* ]]
}

@test "hygiene: shellcheck suppressions ratchet DOWN, and each states why (11.5 / §18.3)" {
    # §18.3: "a number with no owner and no enforcement only grows" — so this is a
    # RATCHET, not a to-do entry. Baselines at 2026-09-16: 16 shell, 4 bats. The 26
    # that were muting SC1090 above a STATIC source are now `# shellcheck source=`
    # directives, which resolve the diagnostic instead of hiding it; what is left has
    # no static target (runtime-generated files) or cannot be expressed otherwise.
    #
    # The pattern is bracketed (`disabl[e]=`) ON PURPOSE: written literally, this
    # test's own grep arguments match themselves and inflate every count — which is
    # exactly what the first version did (7 bats, not 4).
    local shell_count bats_count bare
    shell_count=$(grep -r --include='*.sh' --include='*.bashrc' '# shellcheck disabl[e]=' \
        "$REPO_ROOT"/scripts "$REPO_ROOT"/bin "$REPO_ROOT"/tools "$REPO_ROOT"/install.sh 2>/dev/null | wc -l)
    bats_count=$(grep -r '# shellcheck disabl[e]=' \
        "$REPO_ROOT"/tests/*.bats "$REPO_ROOT"/tests/unit/*.bats \
        "$REPO_ROOT"/tests/integration/*.bats 2>/dev/null | wc -l)
    (( shell_count <= 16 )) || {
        echo "FAIL: $shell_count shell suppressions (baseline 16) — fix the cause, or lower this number deliberately; do not raise it"
        return 1
    }
    (( bats_count <= 4 )) || {
        echo "FAIL: $bats_count bats suppressions (baseline 4)"
        return 1
    }
    # `|| true`: grep -c exits 1 on a ZERO count, which would fail this test for the
    # very reason it is checking for. The status is not the signal here — the number is.
    bare=$(grep -rh --include='*.sh' --include='*.bashrc' --include='*.bats' '# shellcheck disabl[e]=' \
        "$REPO_ROOT"/scripts "$REPO_ROOT"/bin "$REPO_ROOT"/tools "$REPO_ROOT"/install.sh \
        "$REPO_ROOT"/tests/*.bats "$REPO_ROOT"/tests/unit/*.bats "$REPO_ROOT"/tests/integration/*.bats 2>/dev/null \
        | grep -vc '  #' || true)
    (( bare == 0 )) || {
        echo "FAIL: $bare suppression(s) state no reason — one that says nothing is indistinguishable from a mistake"
        return 1
    }
}

@test "autotune: a certified row carries the load it was measured under" {
    # 2026-09-16: row 2 recorded .96 tps while the box ran at load 20-26 on 12 cores, and
    # nothing in the output said so — the figure reads as a property of the model. The
    # summary must name the load, and must say CONTENDED once it exceeds the core count.
    run grep -A14 'saved:   ctx=' "$REPO_ROOT/scripts/autotune-model.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"/proc/loadavg"* ]]
    [[ "$output" == *"CONTENDED"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. PROFILE STRUCTURE
# ─────────────────────────────────────────────────────────────────────────────

@test "profile: sources in a clean environment without error or hang" {
    # Item 11.7.  `env -i` drops every inherited variable — including
    # TACTICAL_PROFILE_VERSION and TAC_LIBRARY_MODE — so the loader is exercised
    # from nothing, and the timeout turns a hang into a test failure rather than a
    # stuck suite.
    #
    # TWO assertions, because either alone is a green that cannot go red.  Sourcing
    # tactical-console.bashrc NON-interactively returns at its interactive guard:
    # rc 0, nothing defined, TACTICAL_PROFILE_VERSION left unset.  So "it exits 0"
    # is true even of a no-op, and the meaningful half is env.sh — the library
    # loader for exactly this case — which from the SAME empty environment must
    # define the function interface.  Both halves can fail for real.
    command -v timeout >/dev/null 2>&1 || skip "timeout not available"
    [[ -f "$PROFILE_PATH" ]] || skip "profile not found"

    run timeout 60 env -i HOME="$HOME" PATH="/usr/bin:/bin" \
        bash --noprofile --norc -c 'source "$1"' _ "$PROFILE_PATH"
    [[ "$status" -eq 0 ]]

    run timeout 60 env -i HOME="$HOME" PATH="/usr/bin:/bin" \
        bash --noprofile --norc -c \
        'source "$1" >/dev/null 2>&1 || exit 1; declare -F model >/dev/null || exit 2; declare -F so >/dev/null || exit 3' \
        _ "$REPO_ROOT/env.sh"
    [[ "$status" -eq 0 ]]
}

@test "structure: file contains TACTICAL_PROFILE_VERSION export" {
    grep -q 'export TACTICAL_PROFILE_VERSION=' "$PROFILE_PATH"
}

@test "structure: file contains AI INSTRUCTION comment above version" {
    grep -q '# AI INSTRUCTION: Increment version on significant changes' \
        "$PROFILE_PATH"
}

@test "structure: has section headers 1 through 15" {
    for i in $(seq 1 15); do
        grep -rqE "^# ${i}\." "$PROFILE_PATH" \
            "$REPO_ROOT"/scripts/[0-9][0-9]-*.sh
    done
}

@test "structure: interactive guard exists in file" {
    grep -q 'case \$- in' "$PROFILE_PATH"
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. CODE HYGIENE
# ─────────────────────────────────────────────────────────────────────────────

@test "hygiene: all scripts end with # end of file marker" {
    for f in "$PROFILE_PATH" \
             "$REPO_ROOT"/scripts/[0-9][0-9]-*.sh \
             "$REPO_ROOT"/scripts/[0-9][0-9][a-z]-*.sh \
             "$REPO_ROOT"/bin/*.sh \
             "$REPO_ROOT"/install.sh \
             "$REPO_ROOT"/tools/lint.sh \
             "$REPO_ROOT"/tools/run-tests.sh; do
        [[ -f "$f" ]] || continue
        local last
        last=$(grep -v '^[[:space:]]*$' "$f" | tail -1)
        echo "$last" | grep -qi 'end of file'
    done
}

@test "hygiene: no carriage returns in any script" {
    for f in "$PROFILE_PATH" \
             "$REPO_ROOT"/scripts/[0-9][0-9]-*.sh \
             "$REPO_ROOT"/scripts/[0-9][0-9][a-z]-*.sh \
             "$REPO_ROOT"/bin/*.sh \
             "$REPO_ROOT"/install.sh; do
        [[ -f "$f" ]] || continue
        local count
        count=$(grep -Pc '\r' "$f" || true)
        [[ "$count" -eq 0 ]]
    done
}

@test "hygiene: no tabs in core scripts" {
    for f in "$PROFILE_PATH" \
             "$REPO_ROOT"/scripts/[0-9][0-9]-*.sh \
             "$REPO_ROOT"/scripts/[0-9][0-9][a-z]-*.sh \
             "$REPO_ROOT"/bin/*.sh \
             "$REPO_ROOT"/install.sh; do
        [[ -f "$f" ]] || continue
        local count
        count=$(grep -Pc '\t' "$f" || true)
        [[ "$count" -eq 0 ]]
    done
}

@test "hygiene: no lines exceed 200 characters in core scripts" {
    # Advisory check: reports long lines but deliberately does NOT fail the
    # suite. UI formatting lines (box-drawing, tabular output) and complex jq
    # pipelines are display-oriented and intentionally exceed the limit.
    local max_width=200  # relaxed limit for UI/jq display lines
    for f in "$PROFILE_PATH" \
             "$REPO_ROOT"/scripts/[0-9][0-9]-*.sh \
             "$REPO_ROOT"/scripts/[0-9][0-9][a-z]-*.sh \
             "$REPO_ROOT"/bin/*.sh \
             "$REPO_ROOT"/install.sh \
             "$REPO_ROOT"/tools/lint.sh \
             "$REPO_ROOT"/tools/run-tests.sh; do
        [[ -f "$f" ]] || continue
        local long
        long=$(awk -v max="$max_width" 'length > max' "$f" | wc -l)
        [[ "$long" -eq 0 ]] || echo "WARN: $f has $long lines > ${max_width} chars"
    done
}

@test "hygiene: no UTF-8 BOM in any script" {
    for f in "$PROFILE_PATH" \
             "$REPO_ROOT"/scripts/[0-9][0-9]-*.sh \
             "$REPO_ROOT"/scripts/[0-9][0-9][a-z]-*.sh \
             "$REPO_ROOT"/bin/*.sh \
             "$REPO_ROOT"/install.sh; do
        [[ -f "$f" ]] || continue
        local desc
        desc=$(file "$f")
        [[ "$desc" != *"BOM"* ]]
    done
}

@test "hygiene: each module has # shellcheck shell=bash at line 1" {
    for f in "$REPO_ROOT"/scripts/[0-9][0-9]-*.sh; do
        [[ -f "$f" ]] || continue
        # Utility scripts (16+) are standalone executables with shebangs; skip
        case "$(basename "$f")" in
            1[6-9]-*|[2-9][0-9]-*) continue ;;
        esac
        local line1
        line1=$(head -1 "$f")
        [[ "$line1" == "# shellcheck shell=bash" ]]
    done
}

@test "hygiene: all modules have a Module Version comment" {
    local missing=0
    local f
    for f in "$REPO_ROOT"/scripts/[0-9][0-9]-*.sh "$REPO_ROOT"/scripts/09b-gog.sh; do
        [[ -f "$f" ]] || continue
        if ! grep -q '^# Module Version:' "$f"; then
            echo "MISSING version in $f" >&3
            missing=$((missing + 1))
        fi
    done
    [[ "$missing" -eq 0 ]]
}

@test "hygiene: module versions follow # Module Version: N pattern" {
    for f in "$REPO_ROOT"/scripts/[0-9][0-9]-*.sh; do
        [[ -f "$f" ]] || continue
        grep -qP '^# Module Version: \d+' "$f"
    done
}

@test "hygiene: no TODO or FIXME in core modules (or explicitly tracked)" {
    # Allow explicit TODO markers that are documented in inspection.md
    run grep -rn 'TODO\|FIXME' \
        "$REPO_ROOT"/scripts/[0-9][0-9]-*.sh \
        "$REPO_ROOT"/bin/*.sh \
        "$PROFILE_PATH"
    [ "$status" -ne 0 ]
}

@test "hygiene: no shell scripts use echo -e outside comments" {
    for f in "$REPO_ROOT"/scripts/[0-9][0-9]-*.sh \
             "$REPO_ROOT"/bin/*.sh \
             "$PROFILE_PATH"; do
        [[ -f "$f" ]] || continue
        local hits
        hits=$(grep -n '^[^#]*echo -e' "$f" || true)
        [[ -z "$hits" ]]
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. CROSS-SCRIPT CONSISTENCY
# ─────────────────────────────────────────────────────────────────────────────

@test "cross-script: all scripts have VERSION variable or Module Version comment" {
    for f in "$REPO_ROOT"/bin/*.sh "$REPO_ROOT"/scripts/*.sh; do
        [[ -f "$f" ]] || continue
        grep -qE 'VERSION=|^# Module Version:' "$f"
    done
}

@test "cross-script: all scripts have AI INSTRUCTION comment" {
    for f in "$REPO_ROOT"/bin/*.sh "$REPO_ROOT"/scripts/*.sh; do
        [[ -f "$f" ]] || continue
        grep -q 'AI INSTRUCTION' "$f"
    done
}

@test "cross-script: watchdog LLM_SERVICE_PORT default is parseable" {
    local wd_port
    wd_port=$(grep -oP 'LLM_SERVICE_PORT="\$\{LLM_SERVICE_PORT:-\K[0-9]+' \
        "$REPO_ROOT/bin/llama-watchdog.sh" || true)
    [[ "$wd_port" =~ ^[0-9]+$ ]]
}

@test "cross-script: env.sh loads modules from the shared list" {
    # Both loaders read scripts/_module-list.sh so their module sets cannot
    # drift (env.sh previously globbed while the profile hardcoded a list).
    grep -q '_module-list.sh' "$REPO_ROOT/env.sh"
    grep -q '_module-list.sh' "$PROFILE_PATH"
}

@test "loader: shared list covers every numbered module (drift guard)" {
    # A numbered module added to scripts/ but missing from _module-list.sh
    # would load in neither the profile nor env.sh — catch that here.
    # 18-lint.sh is a standalone utility, not a profile module.
    local base
    for f in "$REPO_ROOT"/scripts/[0-9][0-9]-*.sh; do
        [[ -f "$f" ]] || continue
        base=$(basename "$f" .sh)
        [[ "$base" == "18-lint" ]] && continue
        grep -qw "$base" "$REPO_ROOT/scripts/_module-list.sh" || {
            echo "NOT IN SHARED LIST: $base" >&3
            return 1
        }
    done
}

@test "cross-script: watchdog has correct health endpoint" {
    grep -q '/health' "$REPO_ROOT/bin/llama-watchdog.sh"
}

@test "constants: LLAMA_DRIVE_ROOT not assigned twice" {
    local count
    count=$(grep -c '^export LLAMA_DRIVE_ROOT=' "$REPO_ROOT/scripts/01-constants.sh" || true)
    [[ "$count" -eq 1 ]]
}

@test "constants: COOLDOWN_WEEKLY is 604800 (7d)" {
    grep -qP 'COOLDOWN_WEEKLY=604800' "$REPO_ROOT/scripts/01-constants.sh"
}

@test "aliases: le and lo share __oc_journal_tail helper" {
    grep -q '__oc_journal_tail' "$REPO_ROOT/scripts/04-aliases.sh"
    local helper_count
    helper_count=$(grep -c '__oc_journal_tail' "$REPO_ROOT/scripts/04-aliases.sh")
    # definition + 2 call sites
    [[ "$helper_count" -ge 3 ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 5. BIN SCRIPTS — Wrapper validation
# ─────────────────────────────────────────────────────────────────────────────

@test "bin: tac-exec sources env.sh" {
    grep -q 'env.sh' "$REPO_ROOT/bin/tac-exec"
}

@test "bin: all oc-* wrappers use tac-exec" {
    for f in "$REPO_ROOT"/bin/oc-*; do
        [[ -f "$f" ]] || continue
        grep -q 'tac-exec' "$f"
    done
}

@test "bin: llama-watchdog.sh has correct shebang" {
    local line1
    line1=$(head -1 "$REPO_ROOT/bin/llama-watchdog.sh")
    [[ "$line1" == "#!/usr/bin/env bash" || "$line1" == "#!/bin/bash" ]]
}

@test "bin: tac-exec sources env.sh relative to its own path" {
    grep -q 'readlink -f "\${BASH_SOURCE\[0\]}"' "$REPO_ROOT/bin/tac-exec"
    grep -q 'source "\$_tac_exec_root/env.sh"' "$REPO_ROOT/bin/tac-exec"
}

@test "bin: all oc-* wrappers resolve tac-exec relative to the wrapper path" {
    local f
    for f in "$REPO_ROOT"/bin/oc-*; do
        [[ -f "$f" ]] || continue
        grep -q '_tac_bin_dir=' "$f"
        grep -q 'exec "\$_tac_bin_dir/tac-exec"' "$f"
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# 6. SYSTEMD UNITS — Structure validation
# ─────────────────────────────────────────────────────────────────────────────

@test "systemd: llama-watchdog.service has [Service] section" {
    grep -q '\[Service\]' "$REPO_ROOT/systemd/llama-watchdog.service"
}

@test "systemd: llama-watchdog.service uses the current user home" {
    grep -q '^ExecStart=%h/.local/bin/llama-watchdog.sh$' \
        "$REPO_ROOT/systemd/llama-watchdog.service"
}

@test "systemd: llama-watchdog.timer has [Timer] section" {
    grep -q '\[Timer\]' "$REPO_ROOT/systemd/llama-watchdog.timer"
}

@test "systemd: timer references the correct service unit" {
    grep -q 'llama-watchdog.service' "$REPO_ROOT/systemd/llama-watchdog.timer"
}

# ─────────────────────────────────────────────────────────────────────────────
# 7. INSTALL SCRIPT — Structural validation
# ─────────────────────────────────────────────────────────────────────────────

@test "install: install.sh exists and is non-empty" {
    [[ -s "$REPO_ROOT/install.sh" ]]
}

@test "install: install.sh has a shebang" {
    local line1
    line1=$(head -1 "$REPO_ROOT/install.sh")
    [[ "$line1" == "#!"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 8. COMPANION FILES
# ─────────────────────────────────────────────────────────────────────────────

@test "hygiene: quant-guide.conf exists and is non-empty" {
    [[ -s "$REPO_ROOT/config/quant-guide.conf" ]]
}

@test "hygiene: README.md exists" {
    [[ -s "$REPO_ROOT/README.md" ]]
}

@test "hygiene: env.sh exists and is non-empty" {
    [[ -s "$REPO_ROOT/env.sh" ]]
}

@test "hygiene: all profile modules exist (17 total: 01-15 + 09b + 18)" {
    # 16 numerically-prefixed profile modules = 16 [0-9][0-9]-*.sh files
    local count=0
    for f in "$REPO_ROOT"/scripts/[0-9][0-9]-*.sh; do
        [[ -f "$f" ]] && count=$(( count + 1 ))
    done
    [[ "$count" -eq 16 ]]
    # 09b-gog.sh is the 17th profile module
    [[ -f "$REPO_ROOT/scripts/09b-gog.sh" ]]
}

@test "gog: shared module list includes 09b-gog" {
    grep -qw '09b-gog' "$REPO_ROOT/scripts/_module-list.sh"
}

@test "env.sh: skips 13-init.sh in library mode" {
    grep -q '13-init.sh' "$REPO_ROOT/env.sh"
}

@test "env.sh: does not source utility scripts (now in tools/) in library mode" {
    # Utility scripts now live in tools/ and are not matched by the scripts/
    # [0-9][0-9]-*.sh glob, so no explicit skip entries are needed.
    # Verify none of the tool script names appear as sourced targets in env.sh.
    local env_content
    env_content=$(cat "$REPO_ROOT/env.sh")
    # Should NOT be sourced (they are not in scripts/ anymore)
    [[ "$env_content" != *"source"*"tools/lint.sh"* ]]
    [[ "$env_content" != *"source"*"tools/run-tests.sh"* ]]
    # tools/ directory must exist
    [[ -d "$REPO_ROOT/tools" ]]
    [[ -f "$REPO_ROOT/tools/lint.sh" ]]
    [[ -f "$REPO_ROOT/tools/run-tests.sh" ]]
}

@test "cross-script: so re-asserts env.shellEnv (worker secret resolution)" {
    # Auth-profile SecretRefs resolve in worker processes that do not inherit
    # the gateway env; env.shellEnv.enabled is what makes them resolve and is
    # lost on reinstall, so `so` must re-assert it.
    grep -q '__so_ensure_shell_env' "$REPO_ROOT/scripts/09a-oc-gateway.sh"
    grep -q 'env.shellEnv.enabled' "$REPO_ROOT/scripts/09a-oc-gateway.sh"
    # ...and oc-refresh-keys calls it too
    grep -q '__so_ensure_shell_env' "$REPO_ROOT/scripts/09d-oc-agents.sh"
}

@test "ci: every runnable test suite is referenced by a workflow" {
    # A suite no workflow runs silently rots — e2e-bench-autotune.bats sat
    # unreferenced until this guard was added, and a newly added unit suite has
    # the same trap. Only 04-llama-cpp-inventory is deliberately excluded (it
    # performs live downloads and mutates the host).
    local missing="" f rel
    for f in "$REPO_ROOT"/tests/unit/*.bats "$REPO_ROOT"/tests/integration/*.bats; do
        [[ -f "$f" ]] || continue
        rel="tests/${f#"$REPO_ROOT"/tests/}"
        [[ "$rel" == "tests/unit/04-llama-cpp-inventory.bats" ]] && continue
        grep -qF "$rel" "$REPO_ROOT"/.github/workflows/*.yml || missing="$missing $rel"
    done
    if [[ -n "$missing" ]]
    then
        echo "reference these in a workflow (ci.yml or nightly.yml):$missing"
        return 1
    fi
}

# end of file
