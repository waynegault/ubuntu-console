#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# normalize-fixture.sh
# ==============================================================================
# Purpose: Strip dynamic/environment-specific values from golden fixture files
#          so Bash vs PowerShell outputs can be diffed on semantics only.
#
# What is stripped:
#   - ANSI / VT100 escape sequences
#   - Timestamps: HH:MM, dates in common formats, epoch integers
#   - Cache-age markers ("cached Ns ago")
#   - Hostname / machine-specific values
#   - Specific RAM / disk / temperature / percentage values
#   - Build hashes (short git SHAs)
#   - Drive letters and WSL-specific paths (kept as placeholders)
#   - Version strings (kept as {{VERSION}})
#
# Usage:
#   # Normalize stdin to stdout
#   tools/normalize-fixture.sh < tests/fixtures/golden/dashboard_m.txt
#
#   # Normalize all .txt fixtures in place (non-destructive: writes .norm files)
#   tools/normalize-fixture.sh --all
#
#   # Diff two normalized fixtures
#   tools/normalize-fixture.sh --diff tests/fixtures/golden/dashboard_m.txt other.txt
# ==============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE_DIR="$REPO_ROOT/tests/fixtures/golden"

usage() {
    cat <<'HELP'
Usage:
  normalize-fixture.sh                    Normalize stdin to stdout
  normalize-fixture.sh <file>             Normalize a file to stdout
  normalize-fixture.sh --all              Normalize all *.txt fixtures to *.norm
  normalize-fixture.sh --diff <a> <b>     Diff two files after normalization

HELP
    exit 0
}

# Core normalizer — accepts a filename or "-" for stdin
normalize() {
    local input="${1:--}"
    cat "$input" \
    | sed \
        \
        -e 's/\x1b\[[0-9;]*[mKHJsu]//g' \
        -e 's/\x1b\[[0-9]*[A-Z]//g' \
        -e 's/\r//g' \
        \
        -e 's/[0-9]\{2\}:[0-9]\{2\}/{{TIME}}/g' \
        -e 's/[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}T[0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}Z/{{ISO_DATETIME}}/g' \
        -e 's/[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}/{{DATE}}/g' \
        -e 's/[0-9]\{1,2\}\/[0-9]\{2\}\/[0-9]\{4\}/{{DATE}}/g' \
        -e 's/Monday\|Tuesday\|Wednesday\|Thursday\|Friday\|Saturday\|Sunday/{{DAY}}/g' \
        \
        -e 's/cached [0-9][0-9]*s ago/cached {{AGE}}s ago/g' \
        -e 's/cached [0-9][0-9]*m [0-9][0-9]*s ago/cached {{AGE}} ago/g' \
        \
        -e 's/[0-9][0-9]*\.[0-9][0-9]* \/ [0-9][0-9]*\.[0-9][0-9]* Gb/{{MEM_USED}} \/ {{MEM_TOTAL}} Gb/g' \
        -e 's/C: [0-9][0-9]* Gb free/C: {{C_FREE}} Gb free/g' \
        -e 's/WSL: [0-9][0-9]* Gb free/WSL: {{WSL_FREE}} Gb free/g' \
        -e 's/[0-9][0-9]*G free of [0-9][0-9]*G/{{DRIVE_FREE}} free of {{DRIVE_TOTAL}}/g' \
        \
        -e 's/CPU [0-9][0-9]*%/CPU {{CPU_PCT}}%/g' \
        -e 's/iGPU [0-9][0-9]*%/iGPU {{IGPU_PCT}}%/g' \
        -e 's/CUDA [0-9][0-9]*%/CUDA {{CUDA_PCT}}%/g' \
        -e 's/[0-9][0-9]*% Load/{{GPU_LOAD}}% Load/g' \
        -e 's/[0-9][0-9]*°C/{{TEMP}}°C/g' \
        -e 's/[0-9][0-9]* \/ [0-9][0-9]* Mb/{{VRAM_USED}} \/ {{VRAM_TOTAL}} Mb/g' \
        \
        -e 's/[0-9][0-9]*\.[0-9]* t\/s/{{TPS}} t\/s/g' \
        -e 's/[0-9][0-9]*\.[0-9]* tps/{{TPS}} tps/g' \
        -e 's/[0-9][0-9]*d [0-9][0-9]*h [0-9][0-9]*m/{{UPTIME}}/g' \
        \
        -e 's/v[0-9][0-9]*\.[0-9][0-9]*/{{VERSION}}/g' \
        -e 's/build=[0-9a-f]\{7,12\}/build={{GIT_SHA}}/g' \
        -e 's/[0-9a-f]\{7,12\}-microsoft-standard/{{KERNEL}}-microsoft-standard/g' \
        \
        -e 's/[0-9][0-9]* Active/{{SESS_COUNT}} Active/g' \
        \
        -e 's/port=[0-9][0-9]*/port={{PORT}}/g' \
        \
        -e 's/Ubuntu-[0-9][0-9]*\.[0-9][0-9]*/Ubuntu-{{UBUNTU_VERSION}}/g' \
        -e 's/Bash v[0-9][0-9]*\.[0-9][0-9]*/Bash {{VERSION}}/g' \
    | tr -s ' '
}

case "${1:---}" in
    -h|--help)  usage ;;
    --all)
        count=0
        for f in "$FIXTURE_DIR"/*.txt
        do
            [[ -f "$f" ]] || continue
            local_out="${f%.txt}.norm"
            normalize "$f" > "$local_out"
            echo "normalized: $(basename "$local_out")"
            count=$(( count + 1 ))
        done
        echo "Done: $count fixtures normalized."
        ;;
    --diff)
        a="${2:-}"
        b="${3:-}"
        if [[ -z "$a" || -z "$b" ]]
        then
            echo "Usage: normalize-fixture.sh --diff <file_a> <file_b>" >&2
            exit 1
        fi
        tmp_a=$(mktemp)
        tmp_b=$(mktemp)
        normalize "$a" > "$tmp_a"
        normalize "$b" > "$tmp_b"
        diff --color=always -u "$tmp_a" "$tmp_b" || true
        rm -f "$tmp_a" "$tmp_b"
        ;;
    -)
        normalize -
        ;;
    *)
        normalize "$1"
        ;;
esac

# end of file
