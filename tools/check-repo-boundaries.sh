#!/usr/bin/env bash
set -euo pipefail

# Guardrail: ubuntu-console should not contain investigator implementation code.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

if ! command -v rg >/dev/null 2>&1; then
    echo "ERROR: rg (ripgrep) is required for boundary checks."
    exit 2
fi

declare -a SEARCH_PATHS=("scripts" "tools" "bin" "tests")

declare -a FORBIDDEN_PATTERNS=(
    "pipeline/model_benchmark.py"
    "\\bBenchmarkCase\\b"
    "\\bBenchmarkResult\\b"
    "\\b_CONFIDENCE_SCORE\\b"
    "\\b_CONFIDENCE_ALIASES\\b"
    "\\b_normalize_confidence_label\\b"
    "counter-allegation taxonomy classification"
)

status=0
hit_file=$(mktemp)
for pattern in "${FORBIDDEN_PATTERNS[@]}"; do
    rg_rc=0
    rg -n -S --glob '!tools/check-repo-boundaries.sh' "$pattern" "${SEARCH_PATHS[@]}" >"$hit_file" 2>/dev/null || rg_rc=$?
    if (( rg_rc == 0 )); then
        echo "Boundary violation in ubuntu-console: pattern '$pattern' is present in source files:"
        cat "$hit_file"
        echo
        status=1
    elif (( rg_rc > 1 )); then
        # rc 2 = ripgrep error (bad pattern, unreadable target): fail closed
        # rather than reporting "clean" when the scan could not run.
        echo "ERROR: ripgrep failed (rc=$rg_rc) scanning pattern '$pattern'" >&2
        rm -f "$hit_file"
        exit 2
    fi
done
rm -f "$hit_file"

if (( status == 0 )); then
    echo "Boundary check passed (ubuntu-console)."
fi

exit "$status"
# end of file
