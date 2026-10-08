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

# __fast_member_shellcheck — the ONE graph pass every member-listing case asserts.
#
# `tools/lint.sh --files` analyses the 29-member module graph as one set whenever any
# listed file IS a member, and scripts/0*, 10, 12 and 13-15 all are. That single pass
# dominates this suite's wall clock — measured 2026-09-30 at ~132 s on a loaded box
# against 5 s for the companion-only part — and each of the three cases below was paying
# for it again, which is how two of them crossed their per-case cap and reported a
# timeout-shaped failure with no code defect behind it.
#
# The graph verdict is GLOBAL, so it is computed once here and the cases assert the
# union: strictly stronger than each case's own subset, and a failure still names the
# offending file in lint.sh's own output, which the caller prints.
#
# Lazy on purpose, and memoised in BATS_FILE_TMPDIR rather than a variable: bats runs
# each test in its own subshell, so state cannot live in the parent, and the cheap cases
# (bashrc, bin/*, a single filtered case) must not pay for a graph they do not need.
__fast_member_shellcheck() {
    local out="$BATS_FILE_TMPDIR/member-shellcheck.out"
    local rc_file="$BATS_FILE_TMPDIR/member-shellcheck.rc"
    if [[ ! -f "$rc_file" ]]
    then
        local rc=0
        "$REPO_ROOT/tools/lint.sh" --files \
            "$REPO_ROOT"/scripts/0*.sh \
            "$REPO_ROOT"/scripts/1[0-5]-*.sh \
            "$REPO_ROOT"/scripts/18-lint.sh \
            "$REPO_ROOT"/scripts/load-vault-env.sh \
            "$REPO_ROOT"/scripts/oc-update-enhanced.sh > "$out" 2>&1 || rc=$?
        printf '%s\n' "$rc" > "$rc_file"
    fi
    cat "$out"
    return "$(cat "$rc_file")"
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
    # One shared graph pass serves the three member-listing cases; see
    # __fast_member_shellcheck. Each still asserts (a superset of) its own scope, and a
    # failure prints lint.sh's own output, which names the offending file.
    run __fast_member_shellcheck
    [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "shellcheck: companion scripts 10 and 12 have no findings" {
    command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
    run __fast_member_shellcheck
    [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "shellcheck: companion scripts 13-15 and extras have no findings" {
    command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
    run __fast_member_shellcheck
    [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "shellcheck: prompt-sets.sh is judged through its consumers, not through their imports" {
    # prompt-sets.sh is neither a module nor an entry point, so it is linted inside the
    # scripts that source it — and those source 01-constants.sh, whose VENV_DIR and
    # LAST_TPS readers (06-hooks.sh, 12-dashboard-help.sh) are absent from that file
    # set. Judged there, two LIVE globals were reported as unused (SC2034), failing
    # every commit that touched prompt-sets.sh (measured 2026-09-27); the module-graph
    # pass analyses every member together, so that is where they are judged. This case
    # pins the standalone verdict.
    command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
    "$REPO_ROOT/tools/lint.sh" --files "$REPO_ROOT/scripts/prompt-sets.sh"
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

@test "11e model scan: a split GGUF becomes ONE row, sized by the whole group" {
    # A 2-shard model used to become TWO rows, and the fragment — whose header lives in
    # shard 1 — scanned as arch=unknown with a guessed ctx and size, then failed every
    # launch. On 2026-09-16 that was registry row 19, and one autotune row spent 12 CUDA
    # cycles discovering it. The helper is pure, so extract and eval its body rather than
    # sourcing the console: this exercises the real implementation, not a copy of it.
    local src="$REPO_ROOT/scripts/11e-llm-model.sh"
    eval "$(sed -n '/^function __model_scan_row_bytes()/,/^}/p' "$src")"
    declare -F __model_scan_row_bytes >/dev/null || { echo "helper not extracted from $src"; return 1; }

    local dir="$BATS_TEST_TMPDIR/fake-shards"
    mkdir -p "$dir"
    dd if=/dev/zero of="$dir/m-00001-of-00002.gguf" bs=1M count=3 status=none
    dd if=/dev/zero of="$dir/m-00002-of-00002.gguf" bs=1M count=1 status=none
    dd if=/dev/zero of="$dir/solo.gguf" bs=1M count=2 status=none

    # The first shard is a row, sized as the SUM of the group (3 + 1 MiB).
    [[ "$(__model_scan_row_bytes "$dir" "m-00001-of-00002.gguf")" -eq $((4 * 1024 * 1024)) ]]
    # A later shard is not a row of its own.
    [[ -z "$(__model_scan_row_bytes "$dir" "m-00002-of-00002.gguf")" ]]
    # An ordinary single-file model is unchanged.
    [[ "$(__model_scan_row_bytes "$dir" "solo.gguf")" -eq $((2 * 1024 * 1024)) ]]
    # A file that does not exist yields nothing rather than an error.
    [[ -z "$(__model_scan_row_bytes "$dir" "absent.gguf")" ]]
}

@test "11e bench: bench mode can measure the CERTIFIED configuration (--fit off)" {
    # Bench mode fits by default so an exploratory model still loads on the 4 GB card —
    # but --fit changes WHAT is measured. On 2026-09-16 the control row benched at 9.9 tps
    # against the autotune's 29.13 because BOTH branches of the launch passed `--fit on`,
    # and the served window was fitted down to 2048 while 8192 was advertised. The
    # override restores comparability for a validation; the default must stay `on` so a
    # bench of an oversized model still fits rather than failing to load.
    run grep -A12 'if \[\[ -n "${__BENCH_MODE:-}" \]\]' "$REPO_ROOT/scripts/11e-llm-model.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"TAC_BENCH_FIT"* ]]
    [[ "$output" == *'"--fit" "off"'* ]]
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
    # Grep, not executed: bin/llama-watchdog.sh runs its whole body at top level
    # (no source guard — it ends in `exit 0`), so calling health() would run the
    # watchdog itself. The /health URL is the only static observable of the
    # endpoint; reaching it by execution needs a live llama-server.
    grep -q '127.0.0.1:${port}/health' "$REPO_ROOT/bin/llama-watchdog.sh"
}

@test "constants: LLAMA_DRIVE_ROOT resolves and is assigned once" {
    # EXECUTED value: source the leaf module in a child shell (the suite stays
    # static — one module, ~8ms, not the profile). The one-assignment half stays a
    # grep because execution cannot observe it: two `export`s yield one value.
    run bash -c 'source "$1/scripts/01-constants.sh" >/dev/null 2>&1; printf "%s" "$LLAMA_DRIVE_ROOT"' _ "$REPO_ROOT"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    local count
    count=$(grep -c '^export LLAMA_DRIVE_ROOT=' "$REPO_ROOT/scripts/01-constants.sh" || true)
    [[ "$count" -eq 1 ]]
}

@test "constants: COOLDOWN_WEEKLY is 604800 (7d)" {
    # EXECUTED: read the variable from the sourced leaf module in a child, so the
    # suite stays static while the value under test is the one the module exports.
    run bash -c 'source "$1/scripts/01-constants.sh" >/dev/null 2>&1; printf "%s" "$COOLDOWN_WEEKLY"' _ "$REPO_ROOT"
    [ "$status" -eq 0 ]
    [ "$output" = "604800" ]
}

@test "aliases: le and lo call the shared __oc_journal_tail helper" {
    # EXECUTED: source the two leaf modules in a child and inspect the DEFINED
    # functions, so this asserts the wiring (le/lo actually call the helper) rather
    # than that a string appears in the file.
    run bash -c '
        source "$1/scripts/01-constants.sh" >/dev/null 2>&1
        source "$1/scripts/04-aliases.sh" >/dev/null 2>&1
        declare -f __oc_journal_tail >/dev/null || exit 3
        declare -f le | grep -q __oc_journal_tail || exit 4
        declare -f lo | grep -q __oc_journal_tail || exit 5
        printf OK
    ' _ "$REPO_ROOT"
    [ "$status" -eq 0 ]
    [ "$output" = "OK" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# 5. BIN SCRIPTS — Wrapper validation
# ─────────────────────────────────────────────────────────────────────────────

@test "bin: tac-exec sources env.sh" {
    # Grep, not executed: tac-exec `source`s env.sh in-process and then execs "$@";
    # the profile functions are NOT exported to the child, so a run cannot observe
    # them. The source line is the only observable of this wiring.
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

@test "bin: the shared helpers are defined ONCE, in bin/_tac-bin-lib.sh" {
    # Card a1076d6f: log() was defined in FIVE bin/ scripts, _free_mib in two and
    # _inv_gpu_lock_path in two. Each now has ONE definition, in the shared
    # library the others source. This pins that, so a copy cannot creep back —
    # and it is a grep because the property is "one definition in the tree",
    # which running a script cannot show.
    local _h _files
    for _h in 'log' '_free_mib' '_inv_gpu_lock_path'; do
        _files=$(grep -lE "^${_h}\(\) \{" "$REPO_ROOT"/bin/* 2>/dev/null || true)
        [[ "$_files" == "$REPO_ROOT/bin/_tac-bin-lib.sh" ]] || {
            echo "helper '${_h}' defined in: ${_files:-<none>}"
            echo "expected exactly: $REPO_ROOT/bin/_tac-bin-lib.sh"
            return 1
        }
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

@test "install: legacy unit aliases are created AFTER the unit links (first install)" {
    # Card 5c20ae57: the alias loop used to run BEFORE the loop that links
    # systemd/* into ~/.config/systemd/user/, so on a FIRST install the alias
    # target did not exist yet and the -e guard skipped EVERY alias (a re-run
    # happened to work, hiding it). install.sh cannot be run end-to-end here, so
    # this pins the ORDER; the runtime half (a skipped alias is NAMED) is the
    # else-branch asserted below.
    local link_ln alias_ln
    link_ln=$(grep -n 'link "systemd/\$_bn" "\$HOME/.config/systemd/user/\$_bn"' "$REPO_ROOT/install.sh" | cut -d: -f1)
    alias_ln=$(grep -n 'for _pair in llama-server.service:' "$REPO_ROOT/install.sh" | cut -d: -f1)
    [[ -n "$link_ln" && -n "$alias_ln" ]]
    (( link_ln < alias_ln )) || { echo "unit links at line $link_ln, alias loop at line $alias_ln"; return 1; }
    # A missing target is REPORTED, not skipped silently.
    grep -q 'alias \$_old skipped' "$REPO_ROOT/install.sh"
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

    # Presence as TEXT is not presence as a live ARGUMENT. The grep above passes when a
    # suite path sits on its own line — but if the line ABOVE it lost its trailing
    # backslash, that path becomes a separate command and the job dies with
    # "Permission denied" (exit 126) AFTER most cases have passed. Measured 2026-10-08:
    # the tip went red exactly this way — suite 55 was appended to ci.yml's bats list and
    # the `\` on the suite-54 line was dropped (4f71a6c7), and no local gate saw it.
    # bats argument lists here are literal (`|`) blocks whose lines are backslash-
    # continued; a folded (`>-`) block joins its lines instead, so the scan tracks the
    # block style and applies the rule only inside a `|` block.
    local scan='
        function ind(s) { return (match(s, /^ */) ? RLENGTH : 0) }
        {
            if (inblk && $0 !~ /^[[:space:]]*$/ && ind($0) <= keyind) { inblk = 0 }
            if (!inblk && $0 ~ /^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]/) {
                rest = $0; sub(/^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]*/, "", rest)
                keyind = ind($0)
                if (rest ~ /^\|/)     { inblk = 1; lit = 1 }
                else if (rest ~ /^>/) { inblk = 1; lit = 0 }
                else                  { inblk = 0 }
                prev = $0; next
            }
            if (inblk && lit && $0 ~ /^[[:space:]]*tests\/[^[:space:]]*\.bats/) {
                if (prev !~ /\\[[:space:]]*$/) print FILENAME ":" NR ": " $0
            }
            prev = $0
        }
    '
    local orphans
    orphans="$(awk "$scan" "$REPO_ROOT"/.github/workflows/*.yml)"
    if [[ -n "$orphans" ]]
    then
        echo "a suite path in a workflow is not a live argument — the line above it lost its trailing backslash:"
        printf '%s\n' "$orphans"
        return 1
    fi

    # Teeth: the same scan must flag a dropped continuation...
    local tmp="$BATS_TEST_TMPDIR/dropped.yml"
    cat > "$tmp" <<'YAML'
jobs:
  x:
    steps:
      - run: |
          bats a \
               tests/unit/01-a.bats
               tests/unit/02-b.bats
YAML
    run awk "$scan" "$tmp"
    [ "$status" -eq 0 ]
    [[ "$output" == *"tests/unit/02-b.bats"* ]]

    # ...and must NOT flag a folded (`>-`) block, whose lines carry no backslash.
    cat > "$tmp" <<'YAML'
jobs:
  x:
    steps:
      - run: >-
          bats
          tests/unit/01-a.bats
          tests/unit/02-b.bats
YAML
    run awk "$scan" "$tmp"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "ci: every job names a self-hosted runner (no billing)" {
    # Wayne's standing rule (2026-09-16): no workflow may run on a GitHub-HOSTED
    # runner — hosted minutes are metered, and once the allowance ran out every
    # hosted job was refused, which left CI dark for six days (2026-09-10). The rule
    # used to be enforced by tests/scripts/test_ci_workflow_honesty.py, but that file
    # (and tests/scripts/) no longer exists and NOTHING else referenced `runs-on:` —
    # so a hosted runner could be added silently. It lives here, beside the other
    # workflow gate, because this is where the repo checks its workflows.
    run bash -c "grep -rh 'runs-on:' '$REPO_ROOT'/.github/workflows/*.yml | grep -v self-hosted"
    [ "$output" = "" ]

    # Teeth: the same filter must catch a hosted runner if one appears, or this
    # check is vacuous.
    run bash -c "printf '%s\n' '    runs-on: ubuntu-latest' | grep -v self-hosted"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ubuntu-latest"* ]]

    # ...and the workflows really do carry self-hosted jobs, so a rename that made
    # the filter match nothing could not pass this by accident.
    grep -rq 'runs-on: \[self-hosted' "$REPO_ROOT"/.github/workflows/*.yml
}

@test "ci: the Python tool pins live in ONE requirements file both workflows install" {
    # Card 49ab1c89: nightly.yml installed ruff/pytest/pytest-timeout UNPINNED while
    # ci.yml pinned them, so the nightly lane could pass or fail on a version no other
    # lane used. The pins now live once in .github/ci-requirements.txt, installed by
    # every workflow that runs Python. This catches a re-float: a bare `pip install
    # ruff`, a pin dropped from the file, or a workflow that stops installing it.
    local req="$REPO_ROOT/.github/ci-requirements.txt"
    [ -f "$req" ]
    # Every tool the CI lane must agree on is stated with `==` in the one file.
    local tool
    for tool in ruff pytest pytest-timeout mypy; do
        grep -qE "^${tool}==" "$req"
    done
    # Both Python-running workflows install that file...
    local rel
    for rel in ci.yml nightly.yml; do
        grep -qF 'ci-requirements.txt' "$REPO_ROOT/.github/workflows/$rel"
    done
    # ...and NO workflow installs one of those tools by bare name (an unpinned install).
    run grep -rnE 'pip install (ruff|pytest|pytest-timeout|mypy)([^=]|$)' \
        "$REPO_ROOT"/.github/workflows/
    [ "$status" -ne 0 ]

    # Teeth: the same filter must match a bare unpinned install if one appears.
    run bash -c "printf '%s\n' '          pip install ruff pytest' | grep -E 'pip install (ruff|pytest)([^=]|\$)'"
    [ "$status" -eq 0 ]
}

# end of file
