#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# check-ctx-profile.sh — flag registry rows whose certified context window does
# not match the investigator-observed input profile.
#
# WHY THIS EXISTS (CTXBUDGET-003).  The registry certifies the HIGHEST ctx that
# holds LLM_MIN_TPS at a filled cache (v6 semantics; D1(a)/D2(b)).  That is a
# VRAM-ceiling + TPS-floor answer, not an answer about what the caller actually
# sends: a row can hold 32K while the observed prompt is 1.2K, or hold 2K while
# the observed prompt already needs 5K.  This check reports that relationship
# from bench_avg_prompt_tokens (col 37) plus LLM_CTX_OUTPUT_RESERVE of generation
# room, rounded up to a 1024-token boundary.  It NEVER changes a certification.
#
# THE ONE FORMULA LIVES IN __autotune_window_policy (11b-llm-autotune.sh), so
# this checker and the autotune's saved ctx_policy (col 45) cannot disagree.
#
# profile-missing IS NOT A PASS.  At HEAD all 28 rows have cols 35-37 empty; a
# run where NO row has a measurable profile exits 2 unless --allow-unmeasured is
# given, so "nothing was measured" cannot read as success.
#
# REF: "Your local LLM is quietly wasting RAM on context you never use, and one
# setting gives it back" (Anurag Singh, XDA, 2026-10-05) —
# https://www.xda-developers.com/local-llm-wasting-ram-context-never-use-one-setting-gives-back/
# Insight ids: TDS-ollama-context-window-ram#2, TDS-ollama-context-window-ram#5.
#
# Usage:
#   scripts/check-ctx-profile.sh [--registry PATH] [--reserve N]
#                                [--fail-over] [--allow-unmeasured]
#
# Exit codes:
#   0  every measurable row fits or is over-reserved (or over with no --fail-over)
#   1  any row is profile-under, or any is profile-over with --fail-over
#   2  no row has a measurable profile (without --allow-unmeasured), an unreadable
#      registry, or a usage error
# ==============================================================================
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 2
# ==============================================================================

set -uo pipefail

# Capture the caller's environment BEFORE sourcing 01-constants, which assigns
# LLM_REGISTRY unconditionally; an explicit LLM_REGISTRY must still be honoured.
_registry="${LLM_REGISTRY:-$HOME/.llm/models.conf}"
_reserve="${LLM_CTX_OUTPUT_RESERVE:-4096}"

_repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=01-constants.sh
if ! source "$_repo_root/scripts/01-constants.sh"; then
    echo "ERROR: cannot load scripts/01-constants.sh" >&2
    exit 2
fi
# shellcheck source=11b-llm-autotune.sh
if ! source "$_repo_root/scripts/11b-llm-autotune.sh"; then
    echo "ERROR: cannot load scripts/11b-llm-autotune.sh" >&2
    exit 2
fi

usage() {
    cat <<'USAGE'
Usage: check-ctx-profile.sh [--registry PATH] [--reserve N] [--fail-over] [--allow-unmeasured]

  --registry PATH      registry to read (default ${LLM_REGISTRY:-$HOME/.llm/models.conf})
  --reserve N          generation room added to the observed prompt (default 4096)
  --fail-over          exit 1 when a row is profile-over as well as profile-under
  --allow-unmeasured   do not exit 2 when no row carries a measurable profile
USAGE
}

_fail_over=0
_allow_unmeasured=0

while (( $# > 0 )); do
    case "${1:-}" in
        --registry)
            if (( $# < 2 )); then
                echo "ERROR: --registry needs a path" >&2
                exit 2
            fi
            _registry="$2"
            shift 2
            ;;
        --reserve)
            if (( $# < 2 )); then
                echo "ERROR: --reserve needs a value" >&2
                exit 2
            fi
            _reserve="$2"
            shift 2
            ;;
        --fail-over)
            _fail_over=1
            shift
            ;;
        --allow-unmeasured)
            _allow_unmeasured=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument '${1:-}'" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if ! [[ "$_reserve" =~ ^[0-9]+$ ]]; then
    echo "ERROR: reserve '$_reserve' is not a non-negative integer" >&2
    exit 2
fi

if [[ ! -f "$_registry" || ! -r "$_registry" ]]; then
    echo "ERROR: registry '$_registry' is not readable" >&2
    exit 2
fi

_header=""
if ! IFS= read -r _header < "$_registry"; then
    echo "ERROR: registry '$_registry' has no header" >&2
    exit 2
fi

# Resolve the columns BY NAME: the schema has grown repeatedly and a positional
# reader is exactly how the 32-column-header bug (card e0579318) happened.
declare -A _col=()
_index=0
IFS='|' read -r -a _fields <<< "$_header"
for _field in "${_fields[@]}"; do
    _col["$_field"]="$_index"
    _index=$(( _index + 1 ))
done

for _need in name file ctx bench_avg_prompt_tokens; do
    if [[ -z "${_col[$_need]+set}" ]]; then
        echo "ERROR: registry header has no '$_need' column" >&2
        exit 2
    fi
done
# ctx_policy is OPTIONAL for reading: a legacy 44-column header still has a
# usable profile check, it simply has no recorded verdict to compare against.
_ctx_col="${_col[ctx_policy]:-}"

_total=0
_missing=0
_fits=0
_over=0
_under=0

while IFS= read -r _line; do
    [[ -z "$_line" ]] && continue
    [[ "$_line" == "#"* ]] && continue
    _total=$(( _total + 1 ))

    IFS='|' read -r -a _row <<< "$_line"
    _file="${_row[${_col[file]}]:-}"
    _ctx="${_row[${_col[ctx]}]:-}"
    _avg="${_row[${_col[bench_avg_prompt_tokens]}]:-}"
    _recorded=""
    if [[ -n "$_ctx_col" ]]; then
        _recorded="${_row[$_ctx_col]:-}"
    fi

    _verdict=$(__autotune_window_policy "$_ctx" "$_avg" "$_reserve")
    _avg_disp="${_avg:-missing}"

    case "$_verdict" in
        profile-missing) _missing=$(( _missing + 1 )) ;;
        profile-fits:*) _fits=$(( _fits + 1 )) ;;
        profile-over:*) _over=$(( _over + 1 )) ;;
        profile-under:*) _under=$(( _under + 1 )) ;;
    esac

    _note=""
    if [[ -n "$_recorded" && "$_recorded" != "$_verdict" ]]; then
        _note=" (recorded ${_recorded})"
    fi
    printf '%-44s ctx=%-8s avg=%-8s %s%s\n' \
        "$_file" "$_ctx" "$_avg_disp" "$_verdict" "$_note"
done < "$_registry"

_measurable=$(( _fits + _over + _under ))
printf 'Summary: %d row(s): %d fits, %d over, %d under, %d profile-missing (reserve=%s)\n' \
    "$_total" "$_fits" "$_over" "$_under" "$_missing" "$_reserve"

if (( _measurable == 0 )) && (( _allow_unmeasured == 0 )); then
    echo "ERROR: no row carries a measurable input profile (bench_avg_prompt_tokens)" >&2
    exit 2
fi
if (( _under > 0 )); then
    exit 1
fi
if (( _over > 0 && _fail_over == 1 )); then
    exit 1
fi
exit 0

# end of file
