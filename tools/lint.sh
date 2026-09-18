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
# Module Version: 13
# @modular-section: lint
# @depends: none (standalone CI helper)
# @exports: (none — standalone script, not sourced)
VERSION="1.5"
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

# ── Module-graph analysis ───────────────────────────────────────────────────
# This runs shellcheck once per file, and for a SOURCED module that is the
# wrong unit of analysis.  A module's interface is consumed by other modules, so
# linted alone every constant it defines looks unused (SC2034) and every variable
# it reads from an earlier-loaded module looks unset (SC2154/SC2153).  Those were
# papered over with file-wide directives, which this repo forbids precisely
# because a suppression also hides the next, real finding.
#
# The honest fix is to analyse the graph: the modules are sourced, so shellcheck
# can see the whole set in one pass and both classes resolve for real, with the
# finding still attributed to the file it is in.
#
# The graph is NOT reachable by linting env.sh: its module loop is
# `source "$_tac_lib_f"`, a non-constant path shellcheck will not follow, so
# env.sh alone analyses nothing but env.sh itself.  The entry is therefore
# GENERATED from the same canonical list the loaders use (_module-list.sh), plus
# each thin loader's own sub-module names — which are literal ARGUMENTS to
# __tac_source_submodules, not `source` statements, so shellcheck cannot find
# them unaided either.
#
# Coverage is CHECKED, not assumed: _tac_lint_coverage_guard fails if any
# scripts/*.sh is neither a member, nor a documented via-consumer fragment, nor a
# shebang'd entry point.  A new file cannot quietly escape analysis.
_tac_graph_members_raw() {
    local _m
    # The two shared fragments load before the modules; modules rely on what they set.
    printf 'scripts/%s\n' "_module-list.sh" "_startup-env.sh"
    # __tac_module_list is pure printf, so sourcing the list has no side effects.
    while IFS= read -r _m
    do
        [[ -n "$_m" ]] || continue
        printf 'scripts/%s.sh\n' "$_m"
        # A thin loader names its sub-modules as literal arguments, one per
        # continued line, in dependency order.
        awk '
            /__tac_source_submodules/ { in_call = 1; next }
            in_call {
                for (i = 1; i <= NF; i++)
                    if ($i ~ /^[0-9][0-9][a-z]?-[a-z0-9-]+$/) print "scripts/" $i ".sh"
                if ($0 !~ /\\$/) in_call = 0
            }
        ' "$REPO_ROOT/scripts/$_m.sh" 2>/dev/null
    done < <(source "$REPO_ROOT/scripts/_module-list.sh"; __tac_module_list)
}

# Computed once: a subshell cannot cache into a variable, so this is assigned at
# load time rather than lazily inside _tac_graph_members.
_TAC_GRAPH_MEMBER_LIST="$(_tac_graph_members_raw)"
_tac_graph_members() { printf '%s\n' "$_TAC_GRAPH_MEMBER_LIST"; }

_tac_is_graph_member() {
    local _rel="${1#"$REPO_ROOT"/}"
    grep -Fqx -- "$_rel" <<< "$_TAC_GRAPH_MEMBER_LIST"
}

# Must this file be kept OUT of the per-file pass?  Yes for graph members (they
# are analysed as one set below) and for fragments covered through a consumer.
_tac_is_via_consumer() {
    [[ "${1#"$REPO_ROOT"/}" == "$_TAC_VIA_CONSUMER" ]]
}

_tac_skip_perfile() {
    _tac_is_via_consumer "$1" && return 0
    _tac_is_graph_member "$1"
}

# A via-consumer fragment is only ever analysed inside something that sources
# it, so when IT is the file being linted, lint its consumers instead — otherwise
# staging only that file would analyse nothing at all.
_tac_lint_via_consumer() {
    local _c
    while IFS= read -r _c
    do
        [[ -n "$_c" ]] || continue
        if shellcheck -s bash -x --source-path="$REPO_ROOT" "$_c" 2>&1
        then
            echo "  PASS  ${_c#"$REPO_ROOT"/}  (analyses $_TAC_VIA_CONSUMER)"
        else
            echo "  FAIL  ${_c#"$REPO_ROOT"/}  (shellcheck, includes $_TAC_VIA_CONSUMER)" >&2
            return 1
        fi
    done < <(grep -ls 'prompt-sets\.sh' "$REPO_ROOT"/scripts/*.sh 2>/dev/null \
        | grep -v "/prompt-sets\.sh$")
    return 0
}

# Fragments that carry no `source` statement of their own.  They are covered
# because an entry point that IS linted sources them by a constant path, which
# gets followed — verified: linting scripts/autotune-model.sh reports nothing
# about scripts/prompt-sets.sh, while linting prompt-sets.sh alone reports its
# SC2034.
_TAC_VIA_CONSUMER="scripts/prompt-sets.sh"

_tac_lint_coverage_guard() {
    local _f _rel _rc=0 _consumers
    for _f in "$REPO_ROOT"/scripts/*.sh
    do
        _rel="${_f#"$REPO_ROOT"/}"
        if _tac_is_graph_member "$_rel"
        then
            continue
        fi
        if [[ "$_rel" == "$_TAC_VIA_CONSUMER" ]]
        then
            # Covered only while something still sources it, so check that
            # rather than trusting the label.
            _consumers="$(grep -ls 'prompt-sets\.sh' "$REPO_ROOT"/scripts/*.sh 2>/dev/null \
                | grep -v "/prompt-sets\.sh$" || true)"
            if [[ -z "$_consumers" ]]
            then
                echo "  FAIL  $_rel is marked as covered via a consumer, but nothing" >&2
                echo "        sources it — so no analysis includes it." >&2
                _rc=1
            fi
            continue
        fi
        # Anything with a shebang is an entry point and is linted on its own.
        if head -1 "$_f" | grep -q '^#!'
        then
            continue
        fi
        echo "  FAIL  $_rel is neither a graph member nor an entry point, so no" >&2
        echo "        pass would analyse it.  Put it in scripts/_module-list.sh," >&2
        echo "        name it from a thin loader, or add it to _TAC_VIA_CONSUMER." >&2
        _rc=1
    done
    return "$_rc"
}

_tac_lint_graph() {
    local _entry _out _n
    _entry="$(mktemp)" || return 1
    _tac_graph_members | while IFS= read -r _rel
    do
        printf 'source "%s"\n' "$_rel"
    done > "$_entry"
    _n="$(wc -l < "$_entry")"
    if _out="$(shellcheck -s bash -x --source-path="$REPO_ROOT" "$_entry" 2>&1)"
    then
        echo "  PASS  module graph ($_n members, analysed as one set)"
        rm -f "$_entry"
        return 0
    fi
    # Findings stay attributed to the file they are in, because the relative
    # sources below resolve against --source-path.
    printf '%s\n' "$_out"
    echo "  FAIL  module graph ($_n members)"
    rm -f "$_entry"
    return 1
}

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
    _staged_graph=0
    while IFS= read -r f
    do
        [[ -z "$f" ]] && continue
        if ! bash -n "$REPO_ROOT/$f" 2>&1
        then
            echo "  FAIL  $f  (syntax)"
            rc=1
            continue
        fi
        # A staged module is analysed with its graph below, not on its own.
        if _tac_skip_perfile "$f"
        then
            if _tac_is_graph_member "$f"; then _staged_graph=1; fi
            if _tac_is_via_consumer "$f"; then _tac_lint_via_consumer || rc=1; fi
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
    if (( _staged_graph == 1 ))
    then
        _tac_lint_graph || rc=1
    fi
    _tac_lint_coverage_guard || rc=1
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
    _files_graph=0
    for f in "$@"
    do
        if [[ ! -f "$f" ]]
        then
            echo "  FAIL  $f  (not a file)"
            rc=1
            continue
        fi
        # A .bats suite is NOT bash: `@test "name" {` has no bash equivalent, so
        # `bash -n` and shellcheck both report a syntax error on a perfectly valid
        # suite — this branch used to answer a BATS_TEST_FILENAME-style call with
        # "FAIL (syntax)" and accuse a healthy file.  The correct parser for that
        # dialect is bats itself: `bats --count` gathers the tests and diagnoses a
        # malformed suite with file:line.  When bats is absent, refuse — never fall
        # back to a bash verdict, which would be a lie about the file.
        case "$f" in
            *.bats)
                if command -v bats >/dev/null 2>&1
                then
                    if _bats_n=$(bats --count "$f" 2>&1)
                    then
                        echo "  PASS  ${f#"$REPO_ROOT"/}  (bats suite: ${_bats_n} tests)"
                    else
                        echo "  FAIL  ${f#"$REPO_ROOT"/}  (bats suite)" >&2
                        printf '%s\n' "$_bats_n" >&2
                        rc=1
                    fi
                else
                    echo "  FAIL  ${f#"$REPO_ROOT"/}  (bats suite, and bats is not installed — this gate cannot parse .bats)" >&2
                    rc=1
                fi
                continue
                ;;
        esac
        if ! bash -n "$f" 2>&1
        then
            echo "  FAIL  ${f#"$REPO_ROOT"/}  (syntax)"
            rc=1
            continue
        fi
        # A listed module is analysed with its graph below, not on its own: its
        # interface is only meaningful alongside the modules that consume it.
        if _tac_skip_perfile "$f"
        then
            if _tac_is_graph_member "$f"; then _files_graph=1; fi
            if _tac_is_via_consumer "$f"; then _tac_lint_via_consumer || rc=1; fi
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
    if (( _files_graph == 1 ))
    then
        _tac_lint_graph || rc=1
    fi
    _tac_lint_coverage_guard || rc=1
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
         "$REPO_ROOT"/env.sh \
         "$REPO_ROOT"/scripts/*.sh \
         "$REPO_ROOT"/tools/*.sh \
         "$REPO_ROOT"/tools/hooks/* \
         "$REPO_ROOT"/bin/*
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
         "$REPO_ROOT"/env.sh \
         "$REPO_ROOT"/scripts/*.sh \
         "$REPO_ROOT"/tools/*.sh \
         "$REPO_ROOT"/tools/hooks/* \
         "$REPO_ROOT"/bin/*
do
    local_rc=0
    # Graph members are analysed once, as a set, below — see the note above.
    if _tac_skip_perfile "$f"
    then
        continue
    fi
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
_tac_lint_graph || rc=1
_tac_lint_coverage_guard || rc=1

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
             "$REPO_ROOT"/bin/*
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
             "$REPO_ROOT"/bin/*
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
