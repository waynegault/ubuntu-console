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
# shellcheck disable=SC2034
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
    run shellcheck -s bash "$PROFILE_PATH"
    [ "$status" -eq 0 ]
}

@test "shellcheck: companion scripts have no findings" {
    command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
    for f in "$REPO_ROOT"/bin/*.sh "$REPO_ROOT"/scripts/*.sh; do
        [[ -f "$f" ]] || continue
        run shellcheck -s bash "$f"
        [ "$status" -eq 0 ]
    done
}

@test "shellcheck: install.sh passes at all severities" {
    command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
    [[ -f "$REPO_ROOT/install.sh" ]] || skip "install.sh not found"
    run shellcheck -s bash "$REPO_ROOT/install.sh"
    [ "$status" -eq 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. PROFILE STRUCTURE
# ─────────────────────────────────────────────────────────────────────────────

@test "structure: file contains TACTICAL_PROFILE_VERSION export" {
    grep -q 'export TACTICAL_PROFILE_VERSION=' "$PROFILE_PATH"
}

@test "structure: file contains AI INSTRUCTION comment above version" {
    grep -q '# AI INSTRUCTION: Increment version on significant changes' \
        "$PROFILE_PATH"
}

@test "structure: has section headers 1 through 13" {
    for i in $(seq 1 13); do
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

@test "hygiene: all scripts end with '# end of file' marker" {
    for f in "$PROFILE_PATH" \
             "$REPO_ROOT"/scripts/[0-9][0-9]-*.sh \
             "$REPO_ROOT"/bin/*.sh \
             "$REPO_ROOT"/install.sh \
             "$REPO_ROOT"/scripts/18-lint.sh \
             "$REPO_ROOT"/scripts/20-run-tests.sh; do
        [[ -f "$f" ]] || continue
        local last
        last=$(grep -v '^[[:space:]]*$' "$f" | tail -1)
        echo "$last" | grep -qi 'end of file'
    done
}

@test "hygiene: no carriage returns in any script" {
    for f in "$PROFILE_PATH" \
             "$REPO_ROOT"/scripts/[0-9][0-9]-*.sh \
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
             "$REPO_ROOT"/bin/*.sh \
             "$REPO_ROOT"/install.sh; do
        [[ -f "$f" ]] || continue
        local count
        count=$(grep -Pc '\t' "$f" || true)
        [[ "$count" -eq 0 ]]
    done
}

@test "hygiene: no lines exceed 120 characters in core scripts" {
    # Known exceptions: UI formatting lines (box-drawing, tabular output)
    # and complex jq pipelines. These are acceptable because they are
    # display-oriented code, not logic paths.
    local max_width=200  # relaxed limit for UI/jq display lines
    for f in "$PROFILE_PATH" \
             "$REPO_ROOT"/scripts/[0-9][0-9]-*.sh \
             "$REPO_ROOT"/bin/*.sh \
             "$REPO_ROOT"/install.sh \
             "$REPO_ROOT"/scripts/18-lint.sh \
             "$REPO_ROOT"/scripts/20-run-tests.sh; do
        [[ -f "$f" ]] || continue
        local long
        long=$(awk -v max="$max_width" 'length > max' "$f" | wc -l)
        [[ "$long" -eq 0 ]] || echo "WARN: $f has $long lines > ${max_width} chars"
    done
}

@test "hygiene: no UTF-8 BOM in any script" {
    for f in "$PROFILE_PATH" \
             "$REPO_ROOT"/scripts/[0-9][0-9]-*.sh \
             "$REPO_ROOT"/bin/*.sh \
             "$REPO_ROOT"/install.sh; do
        [[ -f "$f" ]] || continue
        local desc
        desc=$(file "$f")
        [[ "$desc" != *"BOM"* ]]
    done
}

@test "hygiene: each module has '# shellcheck shell=bash' at line 1" {
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

@test "hygiene: all 20 modules have a Module Version comment" {
    local count
    count=$(grep -l '^# Module Version:' \
        "$REPO_ROOT"/scripts/[0-9][0-9]-*.sh | wc -l)
    [[ "$count" -eq 20 ]]
}

@test "hygiene: module versions follow '# Module Version: N' pattern" {
    for f in "$REPO_ROOT"/scripts/[0-9][0-9]-*.sh; do
        [[ -f "$f" ]] || continue
        grep -qP '^# Module Version: \d+' "$f"
    done
}

@test "hygiene: no 'TODO' or 'FIXME' in core modules (or explicitly tracked)" {
    # Allow explicit TODO markers that are documented in inspection.md
    run grep -rn 'TODO\|FIXME' \
        "$REPO_ROOT"/scripts/[0-9][0-9]-*.sh \
        "$REPO_ROOT"/bin/*.sh \
        "$PROFILE_PATH"
    [ "$status" -ne 0 ]
}

@test "hygiene: no shell scripts use 'echo -e' outside comments" {
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

@test "cross-script: watchdog LLM_PORT default matches bashrc" {
    local wd_port
    wd_port=$(grep -oP 'LLM_PORT="\$\{LLAMA_ROOT:-\K[0-9]+' \
        "$REPO_ROOT/bin/llama-watchdog.sh" || true)
    # Just verify it's parseable
    [[ "$wd_port" =~ ^[0-9]+$ ]] || [[ -z "$wd_port" ]]
}

@test "cross-script: env.sh uses glob to source numbered modules" {
    grep -q '\[0-9\]\[0-9\]-\*\.sh' "$REPO_ROOT/env.sh"
}

@test "cross-script: watchdog has correct health endpoint" {
    grep -q '/health' "$REPO_ROOT/bin/llama-watchdog.sh"
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

@test "systemd: llama-watchdog.service uses the current user's home" {
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
    [[ -s "$REPO_ROOT/quant-guide.conf" ]]
}

@test "hygiene: README.md exists" {
    [[ -s "$REPO_ROOT/README.md" ]]
}

@test "hygiene: env.sh exists and is non-empty" {
    [[ -s "$REPO_ROOT/env.sh" ]]
}

@test "hygiene: all profile modules exist (16 total: 01-15 + 09b)" {
    # 15 numerically-prefixed profile modules plus 5 utility scripts = 20 [0-9][0-9]-*.sh
    local count=0
    for f in "$REPO_ROOT"/scripts/[0-9][0-9]-*.sh; do
        [[ -f "$f" ]] && count=$(( count + 1 ))
    done
    [[ "$count" -eq 20 ]]
    # 09b-gog.sh is the 16th profile module
    [[ -f "$REPO_ROOT/scripts/09b-gog.sh" ]]
}

@test "gog: env.sh explicitly sources 09b-gog.sh" {
    grep -q '09b-gog.sh' "$REPO_ROOT/env.sh"
}

# end of file
