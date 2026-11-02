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
# Usage: tools/docs-sync-check.sh          (report; exit 1 on drift)
#        tools/docs-sync-check.sh --fix    (rewrite the phrases it derives, then re-check)
# ==============================================================================
# AI INSTRUCTION: On ANY change to this file, increment the Module Version.
# Module Version: 10
#   v10 (2026-11-02): `--fix`. The gate already printed the exact expected literal for
#   every drifting phrase, and the repair was being done by hand — three times on
#   2026-11-01/02, once with a hand-written mapper that mis-matched the Total row. --fix
#   rewrites each drifting phrase in its own file (README.md or pytest.ini) from the
#   value the checks just computed, then re-execs itself so the verdict and the exit
#   status come from a clean pass, not from the repairing one. It REFUSES to invent: a
#   phrase that cannot be located is reported UNFIXED and still exits 1, because a
#   fabricated count is worse than a red gate. Locators are the expected string with
#   its digit runs generalised, except the per-directory breakdowns, whose element
#   COUNT changes with a new suite file and so cannot be matched by that rule.
# Module Version: 9
#   v9 (2026-10-31): force LC_ALL=C so the per-file breakdown globs in ONE order on
#   every box.  The bash glob's sort order follows LC_COLLATE, and the two boxes
#   disagree: C.UTF-8 puts 58-gpu-busy before 58b-gpu-watch ("-" < "b") while a
#   locale that ignores punctuation puts 58b first — the same tree read as drift on
#   the other box.  C collation is the canonical order, so the README pins it.
#   v8 (2026-10-03, card 43e4800a): guard the README "CI Status" bullets.  They
#   restated three test counts that nothing computed and had drifted — fast said
#   62 (actual 65), "Unit suites (227 tests in CI)" against 428, and integration
#   142 against 143.  The fast/full/integration figures reuse the counts computed
#   above; the CI-unit figure is derived from the unit files ci.yml actually names,
#   so "in CI" is a fact about the workflow rather than a remembered range (the old
#   prose enumerated `01, 02, 09-11, 13-30`, which was itself stale).
#   v7 (2026-09-22): guard the README "Test Counts" table (all 7 rows) — its own
#   header claimed it was enforced, but 4 of the 7 numbers were unguarded and had
#   drifted (Unit 135 vs 177, Python 363 vs 415, Total 1092 vs 1186).
# ==============================================================================
set -u
# The per-file breakdown below depends on bash's glob order, which follows
# LC_COLLATE and differs per box (see the v9 note).  Pin the C collation so the
# canonical order is the same on every host.
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
README="$REPO_ROOT/README.md"
LOADER="$REPO_ROOT/tactical-console.bashrc"

drift=0
FIX=0
fixed_count=0
case "${1:-}" in
    "")    ;;
    --fix) FIX=1 ;;
    *)     printf 'usage: %s [--fix]\n' "${0##*/}"; exit 2 ;;
esac

# fix_phrase <file> <desc> <expected> [locator]
# Rewrite the ONE phrase this check derives. The locator defaults to the expected text
# with every digit run widened to `\d+`, so a changed COUNT is found while the wording
# around it still has to match exactly; a caller whose shape changes (the breakdowns,
# where a new suite file adds a term) passes its own. Prints 1 on a rewrite, 0 when
# nothing matched — and writes NOTHING in that case, because inventing a figure is the
# failure mode this gate exists to catch.
fix_phrase() {
    local file="$1" desc="$2" expected="$3" locator="${4:-}" n=""
    n=$("${TAC_PYTHON:-python3}" - "$file" "$locator" "$expected" <<'PY'
import re, sys
path, locator, expected = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(path, encoding="utf-8").read()
if not locator:
    locator = "".join(r"\d+" if part.isdigit() else re.escape(part)
                      for part in re.split(r"(\d+)", expected) if part)
new, n = re.subn(locator, lambda _m: expected, src, count=1, flags=re.M)
if n:
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(new)
print(n)
PY
)
    if [[ "$n" == "1" ]]
    then
        echo "  FIXED: $desc — wrote '$expected' to ${file#"$REPO_ROOT"/}"
        fixed_count=$((fixed_count + 1))
    else
        # Say WHICH pattern failed: an empty locator means the default was derived inside
        # the python above, and `matched ''` read as though nothing had been tried.
        local _tried="${locator:-the expected text with its numbers widened}"
        echo "  UNFIXED: $desc — nothing in ${file#"$REPO_ROOT"/} matched $_tried"
        drift=1
    fi
}

check_phrase() { # <description> <grep -F pattern> [locator]
    local desc="$1" pattern="$2" locator="${3:-}"
    if grep -qF "$pattern" "$README"; then
        echo "  OK: $desc"
    else
        echo "  DRIFT: $desc — expected '$pattern' in README.md"
        drift=1
        if (( FIX == 1 ))
        then
            fix_phrase "$README" "$desc" "$pattern" "$locator"
        fi
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
bats_funcavail=0
bats_total=0
for f in "$REPO_ROOT"/tests/unit/*.bats \
         "$REPO_ROOT"/tests/tactical-console.bats \
         "$REPO_ROOT"/tests/tactical-console-fast.bats \
         "$REPO_ROOT"/tests/tactical-console-function-availability.bats \
         "$REPO_ROOT"/tests/integration/*.bats
do
    [[ -f "$f" ]] || continue
    n=$(grep -c '^@test ' "$f")
    bats_total=$((bats_total + n))
    case "${f##*/}" in
        tactical-console.bats)      bats_full=$n ;;
        tactical-console-fast.bats) bats_fast=$n ;;
        tactical-console-function-availability.bats) bats_funcavail=$n ;;
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
        n=$(grep -c '^@test ' "$f")
        _sum=$((_sum + n))
        _counts="${_counts:+$_counts+}$n"
    done
    # Named, because 3c checks the same sums in another file.
    case "$_dir" in
        unit)        unit_sum=$_sum ;;
        integration) integration_sum=$_sum ;;
    esac
    # This one needs its OWN locator: a new suite file adds a term, so the expected
    # string's digit-run generalisation would demand the old term count and never match.
    check_phrase "tests/$_dir breakdown ($_sum tests: $_counts)" \
        "${_dir} tests (${_sum} tests: ${_counts})" \
        "${_dir} tests \\([0-9]+ tests: [0-9+]+\\)"
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
check_in_file() { # <file> <description> <grep -F pattern> [locator]
    local file="$1" desc="$2" pattern="$3" locator="${4:-}"
    if grep -qF "$pattern" "$file"; then
        echo "  OK: $desc"
    else
        echo "  DRIFT: $desc — expected '$pattern' in ${file#"$REPO_ROOT"/}"
        drift=1
        if (( FIX == 1 ))
        then
            fix_phrase "$file" "$desc" "$pattern" "$locator"
        fi
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

# ── 3d. The README "Test Counts" table ──────────────────────────────────────
# The table's own header claims "Counts are enforced by tools/docs-sync-check.sh",
# and that was FALSE for four of its seven rows: only the full-behavioural and
# fast-suite figures were grepped (through the "N BATS unit tests" / "Fast subset
# (N tests" phrases).  Measured 2026-09-22, the unguarded rows had drifted a long
# way — Unit said 135 against an actual 177 and Python said 363 against 415, so
# the stated **Total** was 1092 against an actual 1186.  A table that says it is
# guarded while a third of its numbers are free to drift is the same trap §3c
# records for docs/architecture.md, so each row is now checked against the count
# computed above.  Row order and cells are matched literally: the table is a
# three-place statement of one fact, and a reformat is a change to the check.
check_in_file "$MAIN" "README counts table: full behavioural" \
    "| Full behavioural | \`tactical-console.bats\` | ${bats_full} |"
check_in_file "$MAIN" "README counts table: fast static analysis" \
    "| Fast static analysis | \`tactical-console-fast.bats\` | ${bats_fast} |"
check_in_file "$MAIN" "README counts table: function availability" \
    "| Function availability | \`tactical-console-function-availability.bats\` | ${bats_funcavail} |"
check_in_file "$MAIN" "README counts table: unit" \
    "| Unit | \`tests/unit/*.bats\` | ${unit_sum} |"
check_in_file "$MAIN" "README counts table: integration" \
    "| Integration | \`tests/integration/*.bats\` | ${integration_sum} |"
check_in_file "$MAIN" "README counts table: python" \
    "| Python | \`tests/test_*.py\` | ${python_total} |"
check_in_file "$MAIN" "README counts table: total" \
    "| **Total** | | **${grand_total}** | | |"

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

# ── 6. README "CI Status" bullets (card 43e4800a) ───────────────────────────
# This block restated the fast/unit/integration counts and nothing computed them,
# so they drifted (fast 62, "in CI" 227, integration 142).  The fast, full and
# integration figures reuse the counts computed above; the CI-unit figure is
# derived from the unit files ci.yml actually names, so "in CI" describes the
# workflow rather than a remembered range (the old prose enumerated
# `01, 02, 09-11, 13-30`, which was itself stale).
ci_unit_total=0
ci_unit_files=0
while IFS= read -r _rel
do
    [[ -n "$_rel" ]] || continue
    _f="$REPO_ROOT/$_rel"
    [[ -f "$_f" ]] || continue
    ci_unit_files=$((ci_unit_files + 1))
    ci_unit_total=$((ci_unit_total + $(grep -c '^@test ' "$_f")))
done < <(grep -oE 'tests/unit/[0-9][0-9a-z-]*\.bats' "$REPO_ROOT/.github/workflows/ci.yml" | sort -u)
if (( ci_unit_files == 0 )); then
    echo "  ERROR: ci.yml names no unit suite — the CI-unit count cannot be derived"
    drift=1
fi

check_phrase "CI Status: fast tests count" \
    "tactical-console-fast.bats\` (${bats_fast} tests)"
check_phrase "CI Status: full tests count" \
    "tactical-console.bats\` (${bats_full} BATS unit tests)"
check_phrase "CI Status: unit suites (in CI)" \
    "**Unit suites (${ci_unit_total} tests in CI):**"
check_phrase "CI Status: integration suites" \
    "**Integration suites (${integration_sum} tests overall):**"

# --fix re-runs ITSELF so the verdict and the exit status come from a clean pass; the
# repairing pass would otherwise report the drift it just removed. When nothing could be
# rewritten the fall-through below reports it and exits 1, as a bare run would.
if (( FIX == 1 && fixed_count > 0 ))
then
    echo ""
    echo "docs-sync-check --fix: $fixed_count phrase(s) rewritten — re-checking"
    exec bash "$REPO_ROOT/tools/docs-sync-check.sh"
fi

echo ""
if (( drift == 0 )); then
    echo "Docs are in sync with repo facts."
    exit 0
fi
echo "DOCS DRIFT DETECTED — update the file named above to match the repo."
exit 1

# end of file
