#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# test-count.sh — the accurate test count for this repo, in one command
# ==============================================================================
# Why this exists (measured 2026-11-05): the VS Code Testing view's headline
# number is NOT a count of tests.  It sums every registered test provider, and
# this workspace has two — ms-python.python (pytest) and kherring.bats-test-runner,
# which lists every .bats file and every @test a SECOND time beside the pytest
# bridge that already exposes each case.  The view read 4,3xx while pytest
# collected 2,577, and moved whenever either half changed; the BATS half of its
# total is also parsed by regex, so it even invents cases from @test text inside
# comments and printf strings.
#
# pytest is the count of record because tests/test_bats_bridge.py makes every
# BATS @test a pytest item, so pytest reports each test exactly once.
#
# Usage:
#   tools/test-count.sh
# ==============================================================================
# Module Version: 1
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="$ROOT/.venv/bin/python3"

if [[ ! -x "$PY" ]]; then
    echo "test-count: no interpreter at $PY — create the venv (README: Development)" >&2
    exit 1
fi

# collected <pytest args...> — prints pytest's own collected total.
# Nothing is discarded: a failing collection is reported whole, because a
# suppressed stderr would turn "could not collect" into an empty number.
collected() {
    local out rc=0 total
    out="$("$PY" -m pytest --collect-only -q "$@" 2>&1)" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        echo "test-count: 'pytest --collect-only $*' failed (rc=$rc):" >&2
        printf '%s\n' "$out" >&2
        return 1
    fi
    total="$(printf '%s\n' "$out" | sed -n 's/^\([0-9][0-9]*\) tests\? collected.*/\1/p' | tail -1)"
    if [[ -z "$total" ]]; then
        echo "test-count: could not read a collected total from pytest output:" >&2
        printf '%s\n' "$out" >&2
        return 1
    fi
    printf '%s' "$total"
}

tests_total="$(collected tests)" || exit 1
python_total="$(collected tests --ignore=tests/test_bats_bridge.py)" || exit 1
full_total="$(collected)" || exit 1

# BATS cases, counted over the same directories tests/bats-suites.tsv names.
# grep -c exits 1 on a zero count, which is the number this wants, not a fault.
bats_total=0
for f in "$ROOT"/tests/*.bats "$ROOT"/tests/unit/*.bats "$ROOT"/tests/integration/*.bats; do
    [[ -f "$f" ]] || continue
    rc=0
    n="$(grep -c '^@test ' "$f")" || rc=$?
    if [[ "$rc" -gt 1 ]]; then
        echo "test-count: cannot read $f (grep rc=$rc)" >&2
        exit 1
    fi
    bats_total=$((bats_total + n))
done

bridge_total=$((tests_total - python_total))
meta_total=$((bridge_total - bats_total))
if [[ "$meta_total" -lt 0 ]]; then
    echo "test-count: the bridge holds $bridge_total items but $bats_total @test cases" >&2
    echo "  were counted — the case globs here and in tests/bats-suites.tsv disagree." >&2
    exit 1
fi

printf 'ubuntu-console test count\n\n'
printf '  BATS @test cases                    %6s\n' "$bats_total"
printf '  pytest items in tests/              %6s   (what VS Code runs)\n' "$tests_total"
printf '    via the BATS bridge               %6s   (%s cases + %s meta-cases)\n' \
    "$bridge_total" "$bats_total" "$meta_total"
printf '    plain Python items                %6s\n' "$python_total"
printf '  full suite (pytest.ini + nas/)      %6s\n' "$full_total"
printf '\n'
printf 'The VS Code Testing view total is not one of these numbers: BATS Test\n'
printf 'Runner lists every .bats file and @test beside the pytest bridge, so it\n'
printf 'counts the BATS half twice.\n'

# end of file
