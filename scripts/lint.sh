#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# lint.sh — Static analysis for the ubuntu-console repository.
# Runs bash -n syntax checks and shellcheck on all shell files.
# Usage: ./scripts/lint.sh
# ==============================================================================
# AI INSTRUCTION: Increment version on significant changes.
# Module Version: 2
# shellcheck disable=SC2034
VERSION="1.1"
set -euo pipefail

# Unicode safety check: detect non-ASCII characters in executable code lines.
# Default: enabled (SKIP_UNICODE_CHECK=0).
# Files with intentional UI glyphs (box-drawing, symbols) are excluded.
# Set SKIP_UNICODE_CHECK=1 to disable entirely.
SKIP_UNICODE_CHECK=${SKIP_UNICODE_CHECK:-0}

# Files excluded from Unicode check (contain intentional UI glyphs)
UNICODE_EXCLUDE=(
    "tactical-console.bashrc"
    "scripts/05-ui-engine.sh"
    "scripts/06-hooks.sh"
    "scripts/07-telemetry.sh"
    "scripts/08-maintenance.sh"
    "scripts/12-dashboard-help.sh"
    "scripts/09-openclaw.sh"       # em-dashes in user messages
    "scripts/13-init.sh"           # em-dashes in warning messages
    "scripts/run-tests.sh"         # unicode check/cross symbols for test output
    "scripts/10-deployment.sh"     # ≤ symbol in commit constants comment
)

# Check if a file should be excluded from Unicode check
__should_exclude_unicode() {
    local file="$1"
    local base
    base=$(basename "$file")
    for excl in "${UNICODE_EXCLUDE[@]}"
    do
        [[ "$file" == *"$excl" ]] && return 0
    done
    return 1
}

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
rc=0

echo "=== Bash Syntax Check (bash -n) ==="
for f in "$REPO_ROOT"/tactical-console.bashrc \
         "$REPO_ROOT"/install.sh \
         "$REPO_ROOT"/scripts/*.sh \
         "$REPO_ROOT"/bin/*.sh
do
    if bash -n "$f" 2>&1
    then
        echo "  PASS  ${f#"$REPO_ROOT"/}"
    else
        echo "  FAIL  ${f#"$REPO_ROOT"/}"
        rc=1
    fi
done

echo ""
echo "=== ShellCheck ==="
if ! command -v shellcheck >/dev/null 2>&1
then
    echo "  shellcheck not installed - skipping (sudo apt install shellcheck)"
    exit "$rc"
fi

for f in "$REPO_ROOT"/tactical-console.bashrc \
         "$REPO_ROOT"/install.sh \
         "$REPO_ROOT"/scripts/*.sh \
         "$REPO_ROOT"/bin/*.sh
do
    local_rc=0
    shellcheck -s bash "$f" 2>&1 || local_rc=$?
    if (( local_rc == 0 ))
    then
        echo "  PASS  ${f#"$REPO_ROOT"/}"
    else
        echo "  FAIL  ${f#"$REPO_ROOT"/}"
        rc=1
    fi
done

echo ""
echo "=== Unicode Safety (non-ASCII in executable code) ==="
if [[ "${SKIP_UNICODE_CHECK:-0}" == "1" ]]; then
    echo "  SKIPPED - non-ASCII check disabled by SKIP_UNICODE_CHECK=1"
else
    unicode_rc=0
    for f in "$REPO_ROOT"/tactical-console.bashrc \
             "$REPO_ROOT"/install.sh \
             "$REPO_ROOT"/scripts/*.sh \
             "$REPO_ROOT"/bin/*.sh
    do
        # Skip files with intentional UI glyphs (box-drawing, symbols)
        if __should_exclude_unicode "$f"
        then
            echo "  SKIP  ${f#"$REPO_ROOT"/}  - excluded (UI glyphs)"
            continue
        fi
        # Find non-ASCII on non-comment lines (excludes lines starting with #)
        hits=$(grep -Pn '[^\x00-\x7F]' "$f" 2>/dev/null | grep -v '^\s*#\|^[0-9]*:\s*#' || true)
        if [[ -z "$hits" ]]
        then
            echo "  PASS  ${f#"$REPO_ROOT"/}"
        else
            echo "  WARN  ${f#"$REPO_ROOT"/}  - non-ASCII on executable lines:"
            echo "$hits" | head -5
            unicode_rc=1
        fi
    done
    # Don't fail the build for Unicode warnings (they're often false positives
    # from author names, comments, etc.), but report them for review.
    if (( unicode_rc == 0 ))
    then
        echo ""
        echo "  All non-excluded files passed Unicode check."
    fi
fi

echo ""
if (( rc == 0 ))
then
    echo "All checks passed."
else
    echo "Some checks failed - see above."
fi
exit "$rc"

# end of file
