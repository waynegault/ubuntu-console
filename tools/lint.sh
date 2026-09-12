#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# lint.sh — Static analysis for the ubuntu-console repository.
# Runs bash -n syntax checks and shellcheck on all shell files.
# Usage: ./tools/lint.sh
# ==============================================================================
# AI INSTRUCTION: Increment version on significant changes.
# Module Version: 3
# @modular-section: lint
# @depends: none (standalone CI helper)
# @exports: (none — standalone script, not sourced)
# shellcheck disable=SC2034
VERSION="1.1"
set -euo pipefail

# Unicode safety check: detect non-ASCII characters in executable code lines.
# Default: enabled (SKIP_UNICODE_CHECK=0).
# Files with intentional UI glyphs (box-drawing, symbols) are excluded.
# Set SKIP_UNICODE_CHECK=1 to disable entirely.
SKIP_UNICODE_CHECK=${SKIP_UNICODE_CHECK:-0}

# Allowed non-ASCII codepoint ranges for the Unicode safety check.
# Characters matching these ranges are intentional UI glyphs and are permitted
# in any file.  Anything outside ASCII + this allowlist triggers a WARN.
#
#  \x{00A0}-\x{00FF}  Latin-1 Supplement  (degree, squared, multiply, section)
#  \x{2014}           Em dash
#  \x{2026}           Horizontal ellipsis
#  \x{2192}           Right arrow
#  \x{2264}           Less-than-or-equal
#  \x{2500}-\x{2570}  Box Drawing  (─ ═ ║ ╔ ╗ ╚ ╝ ╟ ╠ ╢ ╣ …)
#  \x{25CB}-\x{25CF}  Geometric Shapes subset  (○ ●)
#  \x{26A0}           Warning sign  (⚠)
#  \x{2713}           Check mark  (✓)
#  \x{2717}           Ballot X  (✗)
#  \x{2800}-\x{28FF}  Braille Patterns  (spinner glyphs)
_UNICODE_ALLOWED='\x{00A0}-\x{00FF}\x{2014}\x{2026}\x{2192}\x{2264}\x{2500}-\x{2570}\x{25CB}-\x{25CF}\x{26A0}\x{2713}\x{2717}\x{2800}-\x{28FF}'

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
rc=0

echo "=== Bash Syntax Check (bash -n) ==="
for f in "$REPO_ROOT"/tactical-console.bashrc \
         "$REPO_ROOT"/install.sh \
         "$REPO_ROOT"/scripts/*.sh \
         "$REPO_ROOT"/tools/*.sh \
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
    echo "  FAIL  shellcheck not installed - cannot run static analysis" >&2
    echo "        Install it (sudo apt install shellcheck) and retry." >&2
    exit 2
fi

for f in "$REPO_ROOT"/tactical-console.bashrc \
         "$REPO_ROOT"/install.sh \
         "$REPO_ROOT"/scripts/*.sh \
         "$REPO_ROOT"/tools/*.sh \
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
echo "=== Unicode Safety ==="
# Always-on FAIL: invisible codepoints that can hide code or forge identifiers —
# a BOM, zero-width characters, and bidirectional controls (Trojan Source).
# These are never legitimate here, so any hit fails the build.
dangerous_rc=0
for f in "$REPO_ROOT"/tactical-console.bashrc \
         "$REPO_ROOT"/install.sh \
         "$REPO_ROOT"/scripts/*.sh \
         "$REPO_ROOT"/tools/*.sh \
         "$REPO_ROOT"/bin/*.sh
do
    hits=$(grep -Pn '[\x{200B}-\x{200F}\x{202A}-\x{202E}\x{2060}-\x{2064}\x{2066}-\x{2069}\x{FEFF}]' "$f" 2>/dev/null || true)
    if [[ -n "$hits" ]]
    then
        echo "  FAIL  ${f#"$REPO_ROOT"/}  - invisible/dangerous Unicode:"
        echo "$hits" | head -5
        dangerous_rc=1
    fi
done
if (( dangerous_rc == 0 ))
then
    echo "  PASS  no BOM / zero-width / bidi control characters"
else
    echo "  FAIL  BOM / zero-width / bidi control characters are never allowed"
    rc=1
fi

# Advisory WARN: other non-ASCII on executable lines (often false positives from
# author names and display glyphs), reported for review but non-fatal.
if [[ "${SKIP_UNICODE_CHECK:-0}" == "1" ]]; then
    echo "  (advisory non-ASCII check skipped: SKIP_UNICODE_CHECK=1)"
else
    unicode_rc=0
    for f in "$REPO_ROOT"/tactical-console.bashrc \
             "$REPO_ROOT"/install.sh \
             "$REPO_ROOT"/scripts/*.sh \
             "$REPO_ROOT"/tools/*.sh \
             "$REPO_ROOT"/bin/*.sh
    do
        # Find non-ASCII outside the approved glyph allowlist.
        # Comment lines (# ...) are always excluded from the check.
        hits=$(grep -Pn "[^\x00-\x7F${_UNICODE_ALLOWED}]" "$f" 2>/dev/null \
             | grep -v '^[0-9]*:[[:space:]]*#' || true)
        if [[ -z "$hits" ]]
        then
            echo "  PASS  ${f#"$REPO_ROOT"/}"
        else
            echo "  WARN  ${f#"$REPO_ROOT"/}  - non-ASCII on executable lines:"
            echo "$hits" | head -5
            unicode_rc=1
        fi
    done
    # Advisory only: non-ASCII here is often a false positive, so it is reported
    # (WARN) but never fails the build.
    if (( unicode_rc == 0 ))
    then
        echo ""
        echo "  All files passed the advisory non-ASCII check."
    fi
fi

echo ""
echo "=== Repository Boundary Guard ==="
if "$REPO_ROOT/tools/check-repo-boundaries.sh"
then
    echo "  PASS  repository boundary guard"
else
    echo "  FAIL  repository boundary guard"
    rc=1
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

# end of file marker
