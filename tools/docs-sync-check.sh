#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# docs-sync-check.sh — Verify README.md matches current repo facts.
# ==============================================================================
# Computes ground-truth values from the repo (module count, loader version,
# BATS/Python test totals) and greps README.md for the matching phrases.
# Exits 0 when README is in sync, 1 when drift is detected.
#
# Single source of truth for the readme-sync guardrail. Used by:
#   - CI (fails the build on README drift)
#   - `up` step 18 / `docs-sync` command (via 08-maintenance.sh)
#
# Usage: tools/docs-sync-check.sh
# ==============================================================================
# AI INSTRUCTION: On ANY change to this file, increment the Module Version.
# Module Version: 3
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
    if [[ "$(basename "$f")" == "tactical-console.bats" ]]; then
        bats_full=$n
    fi
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
    check_phrase "tests/$_dir breakdown ($_sum tests: $_counts)" \
        "${_dir} tests (${_sum} tests: ${_counts})"
done

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
    echo "README.md is in sync with repo facts."
    exit 0
fi
echo "README.md DRIFT DETECTED — update README.md to match the repo."
exit 1

# end of file
