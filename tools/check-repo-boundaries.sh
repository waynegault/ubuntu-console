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
for pattern in "${FORBIDDEN_PATTERNS[@]}"; do
    if rg -n -S --glob '!tools/check-repo-boundaries.sh' "$pattern" "${SEARCH_PATHS[@]}" >/tmp/ubuntu-console-boundary-hit.txt 2>/dev/null; then
        echo "Boundary violation in ubuntu-console: pattern '$pattern' is present in source files:"
        cat /tmp/ubuntu-console-boundary-hit.txt
        echo
        status=1
    fi
done
rm -f /tmp/ubuntu-console-boundary-hit.txt

if (( status == 0 )); then
    echo "Boundary check passed (ubuntu-console)."
fi

exit "$status"
