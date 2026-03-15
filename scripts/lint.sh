#!/usr/bin/env bash
# ==============================================================================
# lint.sh — Static analysis for the ubuntu-console repository.
# Runs bash -n syntax checks and shellcheck on all shell files.
# Usage: ./scripts/lint.sh
# ==============================================================================
# AI INSTRUCTION: Increment version on significant changes.
# shellcheck disable=SC2034
VERSION="1.0"
set -euo pipefail

# Set to '1' to skip the Unicode safety check (non-ASCII in executable lines).
# Many scripts intentionally include box-drawing and glyphs for TUI output.
SKIP_UNICODE_CHECK=${SKIP_UNICODE_CHECK:-1}

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
    echo "  shellcheck not installed — skipping (sudo apt install shellcheck)"
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
    echo "  SKIPPED — non-ASCII check disabled (intentional UI glyphs)"
else
    for f in "$REPO_ROOT"/tactical-console.bashrc \
             "$REPO_ROOT"/install.sh \
             "$REPO_ROOT"/scripts/*.sh \
             "$REPO_ROOT"/bin/*.sh
    do
        # Find non-ASCII on non-comment lines (excludes lines starting with #)
        hits=$(grep -Pn '[^\x00-\x7F]' "$f" 2>/dev/null | grep -v '^\s*#\|^[0-9]*:\s*#' || true)
        if [[ -z "$hits" ]]
        then
            echo "  PASS  ${f#"$REPO_ROOT"/}"
        else
            echo "  WARN  ${f#"$REPO_ROOT"/}  — non-ASCII on executable lines:"
            echo "$hits" | head -5
        fi
    done
fi

echo ""
if (( rc == 0 ))
then
    echo "All checks passed."
else
    echo "Some checks failed — see above."
fi
exit "$rc"

# end of file
