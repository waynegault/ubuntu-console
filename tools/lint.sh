#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# lint.sh — Static analysis for the ubuntu-console repository.
# Runs bash -n syntax checks and shellcheck on all shell files.
# Usage: ./tools/lint.sh            (whole repo)
#        ./tools/lint.sh --staged   (only .sh files staged for commit)
#        ./tools/lint.sh --files F  (an explicit list of files)
# ==============================================================================
# AI INSTRUCTION: Increment version on significant changes.
# Module Version: 9
# @modular-section: lint
# @depends: none (standalone CI helper)
# @exports: (none — standalone script, not sourced)
VERSION="1.2"
set -euo pipefail

# --version (diagnostic; also keeps VERSION referenced, so no SC2034 suppression).
if [[ "${1:-}" == "--version" || "${1:-}" == "-V" ]]; then
    echo "lint.sh $VERSION"
    exit 0
fi

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
#  \x{2298}           Circled division slash  (⊘ — the skip marker in run-tests.sh)
#  \x{2500}-\x{2570}  Box Drawing  (─ ═ ║ ╔ ╗ ╚ ╝ ╟ ╠ ╢ ╣ …)
#  \x{25CB}-\x{25CF}  Geometric Shapes subset  (○ ●)
#  \x{26A0}           Warning sign  (⚠)
#  \x{2713}           Check mark  (✓)
#  \x{2717}           Ballot X  (✗)
#  \x{2800}-\x{28FF}  Braille Patterns  (spinner glyphs)
_UNICODE_ALLOWED='\x{00A0}-\x{00FF}\x{2014}\x{2026}\x{2192}\x{2264}\x{2298}\x{2500}-\x{2570}\x{25CB}-\x{25CF}\x{26A0}\x{2713}\x{2717}\x{2800}-\x{28FF}'

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
rc=0

# --staged: bash -n + shellcheck on ONLY the .sh files staged for commit — what
# the pre-commit hook needs, and nothing else.
#
# This mode exists because the hook used to inline that loop.  The hook is not
# version-controlled, so the shellcheck flags then lived in two places and
# drifted the first time one of them changed (2026-09-15: -x was added here and
# the hook went on rejecting the very files this mode had just cleared).  The
# module-version check already delegates to tools/check-module-versions.sh for
# exactly this reason; the persistent check belongs in a tracked, tested tool.
if [[ "${1:-}" == "--staged" ]]
then
    staged=$(git -C "$REPO_ROOT" diff --cached --name-only --diff-filter=ACM 2>/dev/null | grep '\.sh$' || true)
    if [[ -z "$staged" ]]
    then
        echo "  (no staged .sh files)"
        exit 0
    fi
    if ! command -v shellcheck >/dev/null 2>&1
    then
        echo "  FAIL  shellcheck not installed - cannot run static analysis" >&2
        echo "        Install it (sudo apt install shellcheck) and retry." >&2
        exit 2
    fi
    echo "=== ShellCheck (staged) ==="
    while IFS= read -r f
    do
        [[ -z "$f" ]] && continue
        if ! bash -n "$REPO_ROOT/$f" 2>&1
        then
            echo "  FAIL  $f  (syntax)"
            rc=1
            continue
        fi
        if shellcheck -s bash -x --source-path="$REPO_ROOT" "$REPO_ROOT/$f" 2>&1
        then
            echo "  PASS  $f"
        else
            echo "  FAIL  $f  (shellcheck)"
            rc=1
        fi
    done <<< "$staged"
    if (( rc == 0 ))
    then
        echo "  All staged .sh files passed."
    else
        echo "  Some staged .sh files failed." >&2
    fi
    exit "$rc"
fi

# --files <path>...: lint an explicit set of shell files with the canonical
# flags, for callers that used to invoke shellcheck themselves.  The bats suites
# replicated `shellcheck -s bash` at ~12 sites, which drifted from this file the
# same way the pre-commit hook did (2026-09-15): the flags existed in two places
# and only one of them was updated.  Tests call this instead.
if [[ "${1:-}" == "--files" ]]
then
    shift
    if [[ $# -eq 0 ]]
    then
        echo "usage: $0 --files <path>..." >&2
        exit 2
    fi
    if ! command -v shellcheck >/dev/null 2>&1
    then
        echo "  FAIL  shellcheck not installed - cannot run static analysis" >&2
        exit 2
    fi
    echo "=== ShellCheck (explicit files) ==="
    for f in "$@"
    do
        if [[ ! -f "$f" ]]
        then
            echo "  FAIL  $f  (not a file)"
            rc=1
            continue
        fi
        if ! bash -n "$f" 2>&1
        then
            echo "  FAIL  ${f#"$REPO_ROOT"/}  (syntax)"
            rc=1
            continue
        fi
        if shellcheck -s bash -x --source-path="$REPO_ROOT" "$f" 2>&1
        then
            echo "  PASS  ${f#"$REPO_ROOT"/}"
        else
            echo "  FAIL  ${f#"$REPO_ROOT"/}  (shellcheck)"
            rc=1
        fi
    done
    if (( rc == 0 ))
    then
        echo "  All listed files passed."
    else
        echo "  Some listed files failed." >&2
    fi
    exit "$rc"
fi

echo "=== Bash Syntax Check (bash -n) ==="
for f in "$REPO_ROOT"/tactical-console.bashrc \
         "$REPO_ROOT"/install.sh \
         "$REPO_ROOT"/scripts/*.sh \
         "$REPO_ROOT"/tools/*.sh \
         "$REPO_ROOT"/tools/hooks/* \
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
         "$REPO_ROOT"/tools/hooks/* \
         "$REPO_ROOT"/bin/*.sh
do
    local_rc=0
    # -x with --source-path: let shellcheck actually FOLLOW the repo's own
    # sources, so the SC1090/SC1091 class ("Not following: env.sh was not
    # specified as input") is RESOLVED rather than hidden behind a
    # `disable=SC1091` directive. Sourced modules carry no shebang, so -s bash
    # sets the dialect too.
    shellcheck -s bash -x --source-path="$REPO_ROOT" "$f" 2>&1 || local_rc=$?
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
# a BOM, zero-width characters, and bidirectional controls (Trojan Source:
# U+061C ALM plus the LRE/RLE/PDF/LRO/RLO and isolate ranges). These are never
# legitimate here, so any hit fails the build.
dangerous_rc=0
pcre_ok=1
# The guard needs PCRE (`grep -P`). Without that engine `hits` would be empty for
# every file and the check would silently pass, so treat a missing engine as a
# failure of the check itself rather than a green result.
if ! printf 'x\n' | grep -P 'x' >/dev/null 2>&1
then
    pcre_ok=0
    dangerous_rc=1
    echo "  FAIL  grep -P (PCRE) is unavailable — the dangerous-codepoint guard cannot run"
fi
if (( pcre_ok == 1 ))
then
    for f in "$REPO_ROOT"/tactical-console.bashrc \
             "$REPO_ROOT"/install.sh \
             "$REPO_ROOT"/scripts/*.sh \
             "$REPO_ROOT"/tools/*.sh \
             "$REPO_ROOT"/bin/*.sh
    do
        hits=$(grep -Pn '[\x{061C}\x{200B}-\x{200F}\x{202A}-\x{202E}\x{2060}-\x{2064}\x{2066}-\x{2069}\x{FEFF}]' "$f" 2>/dev/null || true)
        if [[ -n "$hits" ]]
        then
            echo "  FAIL  ${f#"$REPO_ROOT"/}  - invisible/dangerous Unicode:"
            echo "$hits" | head -5
            dangerous_rc=1
        fi
    done
fi
if (( dangerous_rc == 0 ))
then
    echo "  PASS  no BOM / zero-width / bidi control characters"
else
    if (( pcre_ok == 1 ))
    then
        echo "  FAIL  BOM / zero-width / bidi control characters are never allowed"
    fi
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
