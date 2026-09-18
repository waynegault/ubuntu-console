#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# docs-sync-check.sh — Verify the docs match current repo facts.
# ==============================================================================
# Computes ground-truth values from the repo (module count, loader version,
# BATS/Python test totals, per-directory breakdowns) and greps for the matching
# phrases in every file that states them: README.md and pytest.ini's marker
# descriptions.  (docs/architecture.md stated them too until it was consolidated
# into README on 2026-09-15.)
# Exits 0 when every guarded file is in sync, 1 when drift is detected.
#
# Single source of truth for the docs-sync guardrail. Used by:
#   - CI (fails the build on drift)
#   - `up` step 18 / `docs-sync` command (via 08-maintenance.sh)
#
# Usage: tools/docs-sync-check.sh
# ==============================================================================
# AI INSTRUCTION: On ANY change to this file, increment the Module Version.
# Module Version: 6
# ==============================================================================
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
README="$REPO_ROOT/README.md"
LOADER="$REPO_ROOT/tactical-console.bashrc"

drift=0

check_phrase() { # <description> <grep -F pattern>
    local desc="$1" pattern="$2"
    if grep -qF "$pattern" "$README"; then
        echo "  OK: $desc"
    else
        echo "  DRIFT: $desc — expected '$pattern' in README.md"
        drift=1
    fi
}

# ── 1. Module count: entries in the shared module list ─────────────────────
modules_file="$REPO_ROOT/scripts/_module-list.sh"
module_count=$(awk '
    /^function __tac_module_list/ { f=1; next }
    f && /^}/ { f=0 }
    f && /printf/ { next }
    f { gsub(/\\/, ""); print }
' "$modules_file" | wc -w | tr -d ' ')
check_phrase "module count ($module_count)" "${module_count} profile modules"

# ── 2. Loader version ──────────────────────────────────────────────────────
loader_version=$(sed -n 's/^_TAC_LOADER_VERSION="\([0-9][0-9]*\)"/\1/p' "$LOADER")
if [[ -n "$loader_version" ]]; then
    check_phrase "loader version (v$loader_version)" "currently v${loader_version}"
else
    echo "  ERROR: could not parse _TAC_LOADER_VERSION from $LOADER"
    drift=1
fi

# ── 3. Test totals: every suite the BATS bridge discovers ─────────────────
bats_full=0
bats_fast=0
bats_total=0
for f in "$REPO_ROOT"/tests/unit/*.bats \
         "$REPO_ROOT"/tests/tactical-console.bats \
         "$REPO_ROOT"/tests/tactical-console-fast.bats \
         "$REPO_ROOT"/tests/tactical-console-function-availability.bats \
         "$REPO_ROOT"/tests/integration/*.bats
do
    [[ -f "$f" ]] || continue
    n=$(grep -c '^@test ' "$f" || true)
    bats_total=$((bats_total + n))
    case "${f##*/}" in
        tactical-console.bats)      bats_full=$n ;;
        tactical-console-fast.bats) bats_fast=$n ;;
    esac
done
python_total=$(grep -hcE '^\s*def test_' "$REPO_ROOT"/tests/test_*.py | awk '{s+=$1} END {print s+0}')
grand_total=$((bats_total + python_total))

check_phrase "total tests ($grand_total)" "${grand_total} total tests: ${bats_total} BATS + ${python_total} Python"
check_phrase "full BATS suite count ($bats_full)" "${bats_full} BATS unit tests"

# ── 3b. Per-directory test breakdown ───────────────────────────────────────
# The totals above were guarded; the per-directory breakdown in the README tree
# was not, and it had drifted by 20 tests before anyone noticed (2026-09-15).
# Same counts, same filename order, so the parenthetical can be written from the
# repo instead of from memory.
for _dir in unit integration
do
    _counts=""
    _sum=0
    for f in "$REPO_ROOT"/tests/"$_dir"/*.bats
    do
        [[ -f "$f" ]] || continue
        n=$(grep -c '^@test ' "$f" || true)
        _sum=$((_sum + n))
        _counts="${_counts:+$_counts+}$n"
    done
    # Named, because 3c checks the same sums in another file.
    case "$_dir" in
        unit)        unit_sum=$_sum ;;
        integration) integration_sum=$_sum ;;
    esac
    check_phrase "tests/$_dir breakdown ($_sum tests: $_counts)" \
        "${_dir} tests (${_sum} tests: ${_counts})"
done

# ── 3c. The same facts, stated anywhere else ───────────────────────────────
# Up to 2026-09-15 only README.md was guarded, and the other file stating the same
# numbers had drifted a long way behind them (docs/architecture.md claimed 39 unit
# tests against 94, 383 full-suite tests against 386 and 109 integration against
# 119, while pytest.ini's `bats_full` marker description also said 383).  A count
# asserted in three places and checked in one is wrong in the other two eventually,
# so each place is checked against the same computed value.
#
# docs/architecture.md was CONSOLIDATED INTO README on 2026-09-15 (12 docs -> 6):
# its counts now live in the README tree, so the checks below point there.  Keep
# this list in step with wherever the same fact is next asserted.
check_in_file() { # <file> <description> <grep -F pattern>
    local file="$1" desc="$2" pattern="$3"
    if grep -qF "$pattern" "$file"; then
        echo "  OK: $desc"
    else
        echo "  DRIFT: $desc — expected '$pattern' in ${file#"$REPO_ROOT"/}"
        drift=1
    fi
}

MAIN="$REPO_ROOT/README.md"
# The README annotates these counts ("(386 tests, ~5-15 min)"), so the patterns stop
# at "tests" rather than demanding a closing paren the README does not use.
check_in_file "$MAIN" "README full-suite count" "BATS full suite (${bats_full} tests"
check_in_file "$MAIN" "README fast-suite count" "Fast subset (${bats_fast} tests"
check_in_file "$MAIN" "README unit count" "BATS unit tests (${unit_sum} tests"
check_in_file "$MAIN" "README integration count" "BATS integration tests (${integration_sum} tests"
check_in_file "$MAIN" "README kgraph module count" \
    "Knowledge graph Python package ($(find "$REPO_ROOT/scripts/kgraph" -name '*.py' | wc -l | tr -d ' ') modules)"
check_in_file "$REPO_ROOT/pytest.ini" "pytest.ini bats_full marker" "behavioural BATS suite (${bats_full} tests)"

# ── 4. env.sh library-loader phrase (unchanged from the old inline check) ──
check_phrase "env.sh library-loader description" "Non-interactive library loader (all modules except 13-init.sh)"

# ── 5. Shared module list (both loaders must read it) ──────────────────────
if grep -q '_module-list\.sh' "$REPO_ROOT/env.sh" \
   && grep -q '_module-list\.sh' "$LOADER"; then
    echo "  OK: loaders share scripts/_module-list.sh"
else
    echo "  DRIFT: loaders do not both source scripts/_module-list.sh"
    drift=1
fi

echo ""
if (( drift == 0 )); then
    echo "Docs are in sync with repo facts."
    exit 0
fi
echo "DOCS DRIFT DETECTED — update the file named above to match the repo."
exit 1

# end of file
