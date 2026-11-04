#!/usr/bin/env bats
# ==============================================================================
# Unit — the VS Code BATS test-runner's spawn timeout, and the patcher that holds it
# ==============================================================================
# WHY THIS EXISTS (measured 2026-11-04 16:05 GMT in ubuntu-console).
#
# `kherring.bats-test-runner` spawns one `bats` per suite with
# `spawn(cmd, args, {shell: "bash", timeout: 1e4, ...})`, so NODE kills the run at
# 10 000 ms.  The kill lands on `bash -c "bats ..."` — which bash has exec'd into `bats`
# — so bats's EXIT trap runs `rm -rf "$BATS_RUN_TMPDIR"` while its `bats-exec-*` children
# keep going.  They recreate that directory with `mkdir -p` (mode 755, where `mktemp -d`
# made 700), `touch` an empty `bats.<pid>.out`, and never rewrite the `bats.<pid>.src`,
# so every remaining case fails at `source "$BATS_TEST_SOURCE"`:
#
#   preprocessing.bash: line 22: /tmp/bats-run-XXXXXX/bats.<pid>.src: No such file
#
# and the Test Explorer reports those cases as FAILURES.  That is how two healthy suites
# (64-fleet-quiesce, 58-gpu-busy-sanctioned-util) came back red with no code defect: 54
# such directories survived the sweep, empty `.out`, no `.src` in any of them, and
# `executeTest error: Error: failed with code null` in the extension's own log.
#
# The patch is one literal, `1e4` -> `36e5` plus a marker comment; the extension update
# that replaces `dist/extension.js` reverts it, which is what `--check` exists for.
#
# HERMETIC: the patcher derives every path from $HOME (`Path("~").expanduser()`), so each
# case points HOME at a fixture tree under BATS_TEST_TMPDIR.  The real extension copy and
# the real ~/.local are never read or written.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    PATCHER="$REPO_ROOT/tools/vscode-bats-timeout/vscode-bats-timeout-patch.py"
    SUITE_TABLE="$REPO_ROOT/tests/bats-suites.tsv"
    FIX="$BATS_TEST_TMPDIR/home"
    EXP="$FIX/.vscode-server/extensions/kherring.bats-test-runner-9.9.9/dist/extension.js"
    mkdir -p "$FIX"
    PY="$(command -v python3 2>/dev/null || true)"
    [[ -n "$PY" ]] || skip "python3 is not on PATH"
    export HOME="$FIX"
}

# write_ext [copies] — a bundle shaped like the real one: the spawnOptions object with
# `shell,` followed by `timeout: 1e4,`, `copies` times.  One copy is the shipped shape;
# two is the drift the patcher must refuse rather than guess between.
write_ext() {
    local copies="${1:-1}" i path="$EXP"
    if [[ "${2:-}" == "desktop" ]]; then
        path="$FIX/.vscode/extensions/kherring.bats-test-runner-9.9.9/dist/extension.js"
    fi
    mkdir -p "$(dirname "$path")"
    {
        printf '%s\n' 'const spawnOptions = {'
        printf '%s\n' '    cwd: workspaceFolder,'
        for ((i = 0; i < copies; i++)); do
            printf '%s\n' '    shell,' '    timeout: 1e4,' '    env: envs'
        done
        printf '%s\n' '};'
    } > "$path"
}

sha_of() { sha256sum "$1" | cut -d' ' -f1; }

@test "bats-timeout patch: no extension copy is rc 2 and writes nothing (not a fault)" {
    # Catches: a tool that reports UNPATCHED (rc 1) on a box that simply has no extension
    # installed — that would make every caller chase a patch with nothing to patch.
    run "$PY" "$PATCHER" --check
    [ "$status" -eq 2 ]
    [[ "$output" == *"nothing to patch"* ]]
    [[ "$output" != *"UNPATCHED"* ]]
    [[ ! -e "$HOME/.local/lib/vscode-bats-timeout" ]]
}

@test "bats-timeout patch: a shipped copy is rc 1 UNPATCHED and --check writes nothing" {
    # Catches: a check that edits the bundle (a "check" with a side effect), and one that
    # calls a 10-second timeout healthy.
    write_ext
    local before
    before="$(sha_of "$EXP")"
    run "$PY" "$PATCHER" --check
    [ "$status" -eq 1 ]
    [[ "$output" == *"UNPATCHED"* ]]
    [[ "$output" == *"run --apply"* ]]
    [ "$(sha_of "$EXP")" = "$before" ]
    [[ ! -e "$HOME/.local/lib/vscode-bats-timeout" ]]
}

@test "bats-timeout patch: --apply replaces the timeout, verifies syntax, and keeps a backup" {
    # Catches: a silent no-op (the file still reads 1e4), a replacement that lands twice,
    # and a patch whose own syntax check never ran.
    write_ext
    local pristine
    pristine="$(sha_of "$EXP")"
    run "$PY" "$PATCHER" --apply
    [ "$status" -eq 0 ]
    [[ "$output" == *"patched"* ]]
    grep -q 'timeout: 36e5,' "$EXP"
    ! grep -q 'timeout: 1e4,' "$EXP"
    grep -q 'LOCALLY PATCHED' "$EXP"
    run "$PY" "$PATCHER" --check
    [ "$status" -eq 0 ]
    [[ "$output" == *"PATCHED"* ]]
    # A backup of the SHIPPED bytes exists, and node accepted the result when node is here.
    [[ "$(sha_of "$HOME"/.local/lib/vscode-bats-timeout/backups/extension.js.*.orig)" = "$pristine" ]]
    if command -v node >/dev/null 2>&1; then
        [[ "$output" != *"syntax NOT verified"* ]]
        node --check "$EXP"
    fi
}

@test "bats-timeout patch: the timeout it writes outlives the longest suite budget" {
    # Catches: a patch that raises 1e4 to another number a real run can still exceed.  The
    # criterion is the largest whole-file budget in tests/bats-suites.tsv (2700 s), not the
    # constant in the script — a suite killed at its own budget is the defect this whole
    # file exists for.
    write_ext
    run "$PY" "$PATCHER" --apply
    [ "$status" -eq 0 ]
    local literal mantissa exponent ms max_budget
    literal="$(grep -oP 'timeout: \K[0-9]+e[0-9]+' "$EXP")"
    [[ -n "$literal" ]] || { echo "no exponent-form timeout after --apply"; return 1; }
    mantissa="${literal%e*}"
    exponent="${literal#*e}"
    ms="$(awk -v m="$mantissa" -v e="$exponent" 'BEGIN { printf "%.0f", m * (10 ^ e) }')"
    max_budget="$(awk -F'\t' '!/^#/ && NF { if ($4 + 0 > m) m = $4 + 0 } END { print m }' "$SUITE_TABLE")"
    [[ -n "$max_budget" && "$max_budget" -gt 0 ]] || { echo "no file budget read from $SUITE_TABLE"; return 1; }
    (( ms / 1000 > max_budget )) || {
        echo "FAIL: patched timeout ${ms}ms is not longer than the largest suite budget ${max_budget}s"
        return 1
    }
}

@test "bats-timeout patch: --apply twice is idempotent (no second edit, no second backup)" {
    # Catches: a patcher that inserts on every run — the bundle grows a copy of the marker
    # each time, which is how a "re-applied by cron" tool corrupts a file.
    write_ext
    run "$PY" "$PATCHER" --apply
    [ "$status" -eq 0 ]
    local after_first
    after_first="$(sha_of "$EXP")"
    run "$PY" "$PATCHER" --apply
    [ "$status" -eq 0 ]
    [[ "$output" == *"already patched"* ]]
    [ "$(sha_of "$EXP")" = "$after_first" ]
    [ "$(grep -c 'LOCALLY PATCHED' "$EXP")" -eq 1 ]
}

@test "bats-timeout patch: a bundle with two spawn timeouts is REFUSED (rc 3) and untouched" {
    # Catches: guessing which of two anchors is the spawn site.  Upstream drift must be a
    # refusal a human reads, not a wrong replacement in a shipped bundle.
    write_ext 2
    local before
    before="$(sha_of "$EXP")"
    run "$PY" "$PATCHER" --apply
    [ "$status" -eq 3 ]
    [[ "$output" == *"REFUSED"* ]]
    [[ "$output" == *"nothing was written"* ]]
    [ "$(sha_of "$EXP")" = "$before" ]
    # And --check reports the same shape rather than claiming the revert.
    run "$PY" "$PATCHER" --check
    [ "$status" -eq 3 ]
    [[ "$output" == *"UNRECOGNISED"* ]]
}

@test "bats-timeout patch: --revert restores the shipped bytes exactly" {
    # Catches: a revert that removes the marker but leaves the replacement, or that reports
    # success while the file differs from what was shipped.
    write_ext
    local pristine
    pristine="$(sha_of "$EXP")"
    run "$PY" "$PATCHER" --apply
    [ "$status" -eq 0 ]
    run "$PY" "$PATCHER" --revert
    [ "$status" -eq 0 ]
    [[ "$output" == *"reverted"* ]]
    [ "$(sha_of "$EXP")" = "$pristine" ]
}

@test "bats-timeout patch: --revert with no backup fails rather than claiming success" {
    # Catches: the success-message-without-a-write shape — "reverted" over a file nobody
    # put back.  A revert that did nothing is reported as rc 1.
    write_ext
    run "$PY" "$PATCHER" --revert
    [ "$status" -eq 1 ]
    [[ "$output" == *"NOT reverted"* ]]
    grep -q 'timeout: 1e4,' "$EXP"
}

@test "bats-timeout patch: a desktop-side copy is patched too, not only the server one" {
    # Catches: the single-glob assumption.  The extension installs under ~/.vscode-server
    # on a WSL/remote session and under ~/.vscode for a desktop session; patching one and
    # reporting success leaves the other run killing suites at 10 s.
    write_ext 1
    write_ext 1 desktop
    local desktop="$FIX/.vscode/extensions/kherring.bats-test-runner-9.9.9/dist/extension.js"
    run "$PY" "$PATCHER" --apply
    [ "$status" -eq 0 ]
    grep -q 'timeout: 36e5,' "$EXP"
    grep -q 'timeout: 36e5,' "$desktop"
    run "$PY" "$PATCHER" --check
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | grep -c 'PATCHED')" -eq 2 ]
}

# end of file
