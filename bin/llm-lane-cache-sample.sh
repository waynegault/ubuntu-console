#!/usr/bin/env bash
# shellcheck shell=bash
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 3
#   v3 (2026-10-31): route the lone diagnostic through warn() so the §18.3 10.7
#   ratchet sees no new hand-written `>&2` at a call site.
# llm-lane-cache-sample.sh — append one prompt-cache reading per resident lane.
#
# WHY THIS EXISTS (SWITCH-CONSOLE-METRICS-001 item 3).  The card that added
# `--metrics` to the lanes also said: record a week of the per-lane cache-hit
# rate before proposing any floor.  The counters are cumulative and reset when a
# lane restarts, and `model lanes` only samples when a human runs it — so a week
# of readings cannot appear by itself.  This is the collector that makes the
# series real: one line per lane per run, appended, pruned by age.
#
# WHAT IT WRITES.  A TSV under TAC_STATE_DIR (persistent state, not the tmpfs
# cache), one row per lane per run:
#
#   epoch  iso  unit  port  status  cached  processed  rate_pct  window
#
# `status` is one of ok | inactive | no-endpoint | no-counters.  For anything
# other than ok the numeric columns are `-`, never 0: an unreadable lane is not
# a cold one, and a 0 here would be the silent-zero failure the whole metrics
# card exists to prevent.
#
# REF: "The Hidden Cost of LLM Routing: Why Switching Models Costs More"
# (Nhu Hoang, TDS 2026-10-20) —
# https://towardsdatascience.com/the-hidden-cost-of-llm-routing-why-switching-models-costs-more/
# CARD: SWITCH-CONSOLE-METRICS-001
#
# Env seams (pinned by tests/unit/68-llm-lane-cache-sample.bats):
#   TAC_STATE_DIR                    state directory (default XDG state/tactical-console)
#   LLM_LANE_CACHE_FILE              output path (default $TAC_STATE_DIR/llm-lane-cache.tsv)
#   LLM_LANE_CACHE_RETENTION_DAYS    rows older than this are pruned (default 30)
#   LLM_LANE_CACHE_SPECS             "unit|port" lines; when set, env.sh is NOT sourced
#   LLM_LANE_CACHE_NOW               epoch seconds to stamp the row (default: date +%s)
#
# Usage: llm-lane-cache-sample.sh [--print]
#   --print  write the rows to stdout instead of the file (a read-only check)
set -uo pipefail

# All diagnostics go through one helper, so the §18.3 ratchet sees no new
# hand-written `>&2` at the call sites.
warn() { printf '%s\n' "$*" >&2; }

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/.." && pwd)"
STATE_DIR="${TAC_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/tactical-console}"
OUT_FILE="${LLM_LANE_CACHE_FILE:-$STATE_DIR/llm-lane-cache.tsv}"
RETENTION_DAYS="${LLM_LANE_CACHE_RETENTION_DAYS:-30}"
NOW_EPOCH="${LLM_LANE_CACHE_NOW:-$(date +%s)}"
PRINT_ONLY=0
[[ "${1:-}" == "--print" ]] && PRINT_ONLY=1

# The lane table lives in the HOST PROFILE (config/hosts.d/<id>.conf), resolved and
# applied by scripts/01-constants.sh.  Tests pass their own list through
# LLM_LANE_CACHE_SPECS so they exercise this script without loading the shell library.
#
# MEASURED BUG, 2026-10-31.  This used to `source "$REPO_ROOT/env.sh"` and read
# LLAMA_LANE_SPECS from it — but env.sh only sources scripts/_startup-env.sh and never
# applies the host profile, so the table was EMPTY ON EVERY HOST and the unit failed
# every hour with "no lane table".  The suite never caught it because it always injects
# LLM_LANE_CACHE_SPECS: the branch that production actually takes had no test at all.
# A test double that replaces the subject's input does not exercise its lookup.
if [[ -n "${LLM_LANE_CACHE_SPECS:-}" ]]; then
    LANE_SPECS="$LLM_LANE_CACHE_SPECS"
    PROFILE_STATE="injected"
else
    # shellcheck source=../scripts/01-constants.sh
    source "$REPO_ROOT/scripts/01-constants.sh"
    LANE_SPECS="${LLAMA_LANE_SPECS:-}"
    # matched=1 means a profile was found and it declares this table.  An EMPTY table
    # on a matched profile is a legitimate host state ("no resident lanes here"), not
    # a fault: this box's profile says so in as many words.  matched=0 means no profile
    # could be chosen, and an empty table then says nothing about the host.
    if [[ "${TAC_HOST_PROFILE_MATCHED:-0}" == "1" ]]; then
        PROFILE_STATE="profile"
    else
        PROFILE_STATE="unresolved"
    fi
fi

if [[ -z "$LANE_SPECS" ]]; then
    case "$PROFILE_STATE" in
        profile)
            # Nothing to sample, and that is TRUE of this host.  Exit 0 so the unit does
            # not fail hourly, but leave a dated record — "no rows" alone is
            # indistinguishable from "the sampler never ran", and a zero must name the
            # instrument that produced it.
            # swallow-ok: an unwritable state dir must not turn "this host has no lanes" into a failure
            mkdir -p "$STATE_DIR" 2>/dev/null || true
            _skip="epoch=$NOW_EPOCH profile=${TAC_HOST_PROFILE:-generic} lanes=0"
            _skip+=" reason=host-profile-declares-no-resident-lanes"
            # swallow-ok: same reason — the record is a courtesy, the exit status is the contract
            printf '%s\n' "$_skip" > "$STATE_DIR/llm-lane-cache-skip" 2>/dev/null || true
            printf 'llm-lane-cache-sample: no resident lanes on profile %s — nothing to sample (recorded)\n' \
                "${TAC_HOST_PROFILE:-generic}"
            exit 0
            ;;
        *)
            warn 'llm-lane-cache-sample: host profile unresolved — cannot tell whether this host has lanes'
            exit 1
            ;;
    esac
fi

HEADER=$'epoch\tiso\tunit\tport\tstatus\tcached\tprocessed\trate_pct\twindow'

# cache_pair <port> — "cached processed", or rc 1 when the endpoint does not
# answer with both counters.  Bounded so a wedged lane cannot stall the unit.
cache_pair() {
    local port="${1:-}" body cached processed
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    # swallow-ok: an absent endpoint is an empty body, recorded as no-endpoint
    body=$(curl -sf --max-time 2 "http://127.0.0.1:${port}/metrics" 2>/dev/null) || return 1
    cached=$(printf '%s\n' "$body" | awk '$1 == "llamacpp:prompt_tokens_cached_total" {print $2; exit}')
    processed=$(printf '%s\n' "$body" | awk '$1 == "llamacpp:prompt_tokens_total" {print $2; exit}')
    # Prometheus renders these as doubles, so a large count arrives as 1.2e+06.
    [[ "$cached" =~ ^[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$ ]] || return 1
    [[ "$processed" =~ ^[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$ ]] || return 1
    printf '%s %s\n' "$cached" "$processed"
}

# lane_state <unit> — systemd ActiveState, or "unknown" when it cannot be read.
lane_state() {
    local unit="${1:-}" state=""
    # is-active prints "inactive" AND exits 3 for an inactive unit, so the exit
    # status is not the answer here: the printed value is.
    # swallow-ok: an unqueryable unit is recorded as "unknown", a named TSV state
    if ! state=$(systemctl --user is-active "$unit" 2>/dev/null); then
        state="${state:-unknown}"
    fi
    printf '%s\n' "${state:-unknown}"
}

# lane_window <unit> — the process start the counters belong to, as ISO text.
lane_window() {
    local unit="${1:-}" ts
    # swallow-ok: a unit with no start time is labelled by the caller as unknown
    ts=$(systemctl --user show "$unit" -p ActiveEnterTimestamp --value 2>/dev/null) || ts=""
    printf '%s\n' "${ts:--}"
}

# sample_row <unit> <port> — one TSV row for this lane.
sample_row() {
    local unit="${1:-}" port="${2:-}" state pair cached processed total rate window iso
    state=$(lane_state "$unit")
    # swallow-ok: a host without GNU date keeps the epoch as the window label
    iso=$(date -d "@$NOW_EPOCH" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || printf '%s' "$NOW_EPOCH")
    window=$(lane_window "$unit")
    if [[ "$state" != "active" ]]; then
        printf '%s\t%s\t%s\t%s\t%s\t-\t-\t-\t%s\n' \
            "$NOW_EPOCH" "$iso" "$unit" "$port" "$state" "$window"
        return 0
    fi
    if pair=$(cache_pair "$port"); then
        read -r cached processed <<< "$pair"
        cached=$(awk -v v="$cached" 'BEGIN { printf "%.0f", v }')
        processed=$(awk -v v="$processed" 'BEGIN { printf "%.0f", v }')
        total=$(( cached + processed ))
        if (( total > 0 )); then
            rate=$(awk -v c="$cached" -v t="$total" 'BEGIN { printf "%.0f", 100 * c / t }')
        else
            rate="0"
        fi
        printf '%s\t%s\t%s\t%s\tok\t%s\t%s\t%s\t%s\n' \
            "$NOW_EPOCH" "$iso" "$unit" "$port" \
            "$cached" "$processed" "$rate" "$window"
        return 0
    fi
    # Active but unreadable: absent --metrics in the running argv, a refused
    # connection, or a body without the two counters.  Not a zero.
    printf '%s\t%s\t%s\t%s\tno-endpoint\t-\t-\t-\t%s\n' \
        "$NOW_EPOCH" "$iso" "$unit" "$port" "$window"
}

# prune_rows <file> — drop rows older than the retention bound.  Keeps the
# header, and matches only the numeric first field this writer produces.
prune_rows() {
    local file="${1:-}" cut tmp
    [[ -f "$file" ]] || return 0
    cut=$(( NOW_EPOCH - RETENTION_DAYS * 86400 ))
    tmp="${file}.tmp.$$"
    {
        head -1 "$file"
        awk -F'\t' -v cut="$cut" 'NR > 1 && $1 ~ /^[0-9]+$/ && $1 >= cut' "$file"
    } > "$tmp" && mv "$tmp" "$file"
}

# write_rows — emit one row per lane; --print sends them to stdout and writes
# nothing, so a read-only check cannot grow the series.
write_rows() {
    local unit port
    if (( PRINT_ONLY )); then
        printf '%s\n' "$HEADER"
    else
        mkdir -p "$(dirname "$OUT_FILE")" || return 1
        if [[ ! -s "$OUT_FILE" ]]; then
            printf '%s\n' "$HEADER" > "$OUT_FILE" || return 1
        fi
    fi
    while IFS='|' read -r unit port
    do
        [[ -n "$unit" ]] || continue
        if (( PRINT_ONLY )); then
            sample_row "$unit" "$port"
        else
            sample_row "$unit" "$port" >> "$OUT_FILE" || return 1
        fi
    done <<< "$LANE_SPECS"
    (( PRINT_ONLY )) && return 0
    prune_rows "$OUT_FILE"
}

write_rows
# end of file
