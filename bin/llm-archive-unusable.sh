#!/usr/bin/env bash
# llm-archive-unusable.sh - move a model that provably cannot run on THIS box out of
# the active store, and record why.  Wayne, 2026-11-06: "if it is clear that an llm
# wont work on our config, archive it but record why."
#
# WHY A TOOL AND NOT A LINE IN THE BATCH.  Archiving is a 60+ GiB move and a durable
# claim about a model.  It needs one implementation, one evidence rule and one record,
# callable by the autotune failure path, by hand, and by a test.
#
# WHAT COUNTS AS CLEAR.  Two things, and nothing else:
#   1. CAPACITY  - the weights cannot be backed by this box's guest RAM, which is what
#                  CUDA memory is drawn from here (measured 2026-11-06: a 60 GiB
#                  allocation succeeded at 94 GiB guest and failed below ~30 GiB).
#                  Necessary condition, not sufficient: a model that fits can still
#                  fail to load, and that is NOT a capacity verdict.
#   2. REPEATED LOAD FAILURE of class unsupported_arch - the loader refused it at every
#                  ctx on N separate runs (default 2).  One refusal is a run, not a fact:
#                  a broken binary or a bad flag fails the same way.
# A single failure, an OOM (resource_exhausted) or a launch_error NEVER archives.
#
# WHAT IT WRITES.  Before the move, and durably:
#   $LLM_STATE_DIR/autotune-archive.log   <ts> TAB <file> TAB <bytes> TAB <class> TAB <reason>
#   $STATE_DIR/autotune-retired.rows      <file>|<reason>   (the resume loop's tombstone)
# The tombstone is what stops the next derivation re-owing the row; the log is the why.
#
# Exit: 0 done/not-eligible, 1 refused, 2 usage.
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 1
#   v1 (2026-11-06, Wayne): first cut - assess / record-failure / archive.
set -uo pipefail

MODEL_DIR="${LLAMA_MODEL_DIR:-$HOME/models/active}"
ARCHIVE_DIR="${LLM_ARCHIVE_DIR:-$(dirname "$MODEL_DIR")/archived}"
STATE_DIR="${TAC_STATE_DIR:-$HOME/.local/state/tactical-console}"
RETIRED="${TAC_RESUME_RETIRED:-$STATE_DIR/autotune-retired.rows}"
LOG_DIR="${LLM_STATE_DIR:-$(dirname "$MODEL_DIR")/.llm}"
ARCHIVE_LOG="$LOG_DIR/autotune-archive.log"
FAIL_FILE="$LOG_DIR/autotune-failures.tsv"
STRIKES="${AUTOTUNE_ARCHIVE_STRIKES:-2}"
# Reserve held back from guest RAM: kernel, page cache, KV and the serving lane.
RESERVE_MIB="${AUTOTUNE_ARCHIVE_RESERVE_MIB:-8192}"
AUTO="${AUTOTUNE_ARCHIVE_AUTO:-1}"

die() { echo "llm-archive-unusable: $*" >&2; exit 2; }
say() { printf '%s\n' "$*"; }

usage() {
    cat <<'EOF'
Usage:
  llm-archive-unusable.sh --assess <file>
  llm-archive-unusable.sh --record-failure <file> --class <class>
  llm-archive-unusable.sh --archive <file> --reason <text> [--yes]

  --assess          capacity verdict against THIS box (guest RAM), no side effects
  --record-failure  tally one classified failure; archives when the rule is met
  --archive         move the model (and every shard of it) to the archive store

Env: AUTOTUNE_ARCHIVE_AUTO=0 requires --yes; AUTOTUNE_ARCHIVE_STRIKES=2;
     AUTOTUNE_ARCHIVE_RESERVE_MIB=8192; LLAMA_MODEL_DIR; TAC_STATE_DIR.
EOF
}

mem_total_mib() {
# swallow-ok: an unreadable /proc/meminfo yields empty and assess refuses with unknown-memory
    awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null
}

size_mib() {
    local f="$1" b
# swallow-ok: an unreadable file yields 0 MiB and the caller refuses on it
    b=$(stat -c %s "$f" 2>/dev/null) || { echo 0; return; }
    # Ceil, not floor: a file just over a ceiling must never read as under it.
    printf '%d' $(( (b + 1048575) / 1048576 ))
}

# Every shard of a split GGUF moves with its first: a lone -00001-of-00003 is a
# broken model, not an archived one.
shards_of() {
    local f="$1" base
    base=$(basename "$f")
    if [[ "$base" =~ ^(.*)-0000([0-9])-of-0000([0-9])\.gguf$ ]]; then
        local pre="${BASH_REMATCH[1]}" total="${BASH_REMATCH[3]}" i
        for (( i=1; i<=total; i++ )); do
            local cand
            cand=$(printf '%s/%s-0000%d-of-0000%s.gguf' "$MODEL_DIR" "$pre" "$i" "$total")
            [[ -f "$cand" ]] && printf '%s\n' "$cand"
        done
    else
        [[ -f "$f" ]] && printf '%s\n' "$f"
    fi
}

total_mib_of_set() {
    local t=0 f
    while IFS= read -r f; do t=$(( t + $(size_mib "$f") )); done < <(shards_of "$1")
    printf '%d' "$t"
}

assess() {
    local f="$1" total_mib mem_mib ceiling verdict
    [[ -f "$f" ]] || { echo "verdict=missing"; return 1; }
    total_mib=$(total_mib_of_set "$f")
    mem_mib=$(mem_total_mib)
    [[ "$mem_mib" =~ ^[0-9]+$ ]] && (( mem_mib > 0 )) || { echo "verdict=unknown-memory"; return 1; }
    ceiling=$(( mem_mib - RESERVE_MIB ))
    if (( total_mib > ceiling )); then verdict=too-big; else verdict=fits; fi
    printf 'file=%s\nset_mib=%s\nguest_mib=%s\nreserve_mib=%s\nceiling_mib=%s\nverdict=%s\n' \
        "$(basename "$f")" "$total_mib" "$mem_mib" "$RESERVE_MIB" "$ceiling" "$verdict"
    [[ "$verdict" == "too-big" ]] && return 3 || return 0
}

archive() {
    local f="$1" reason="$2" assume="${3:-no}" set size shard moved=0
    [[ -f "$f" ]] || { echo "refusing: no such model: $f" >&2; return 1; }
    set=$(shards_of "$f")
    [[ -n "$set" ]] || { echo "refusing: no shards resolved for $f" >&2; return 1; }
    size=$(total_mib_of_set "$f")
    if [[ "$AUTO" != "1" && "$assume" != "yes" ]]; then
        echo "refusing: AUTOTUNE_ARCHIVE_AUTO=$AUTO and no --yes (would move ${size} MiB)" >&2
        return 1
    fi
    # Record FIRST: a record that depends on the move succeeding is not a record.
    mkdir -p "$LOG_DIR" "$ARCHIVE_DIR" "$STATE_DIR"
    printf '%s\t%s\t%s\t%s\t%s\n' "$(date -Iseconds)" "$(basename "$f")" "$size" "$reason" \
        "$(total_mib_of_set "$f") MiB set; guest $(mem_total_mib) MiB" >> "$ARCHIVE_LOG"
# swallow-ok: an absent tombstone legitimately holds no row
    if ! grep -qxF "$(basename "$f")|$reason" "$RETIRED" 2>/dev/null; then
        printf '%s|%s\n' "$(basename "$f")" "$reason" >> "$RETIRED"
    fi
    while IFS= read -r shard; do
        [[ -f "$shard" ]] || continue
        if mv -n "$shard" "$ARCHIVE_DIR/"; then moved=$(( moved + 1 )); else
            echo "ERROR: could not move $shard — it is still in the active store" >&2; return 1
        fi
    done <<< "$set"
    say "archived ${moved} file(s), ${size} MiB -> $ARCHIVE_DIR"
    say "reason: $reason"
    say "recorded: $ARCHIVE_LOG and $RETIRED"
}

record_failure() {
    local f="$1" cls="$2" base count=0 line
    base=$(basename "$f")
    mkdir -p "$LOG_DIR"
    if [[ -r "$FAIL_FILE" ]]; then
        line=$(awk -F'\t' -v b="$base" -v c="$cls" '$1==b && $2==c {print $3; exit}' "$FAIL_FILE")
        [[ "$line" =~ ^[0-9]+$ ]] && count=$line
    fi
    count=$(( count + 1 ))
    # Replace that class's row for this model, leave every other row alone.
    if [[ -r "$FAIL_FILE" ]]; then
        awk -F'\t' -v b="$base" -v c="$cls" '!( $1==b && $2==c )' "$FAIL_FILE" > "$FAIL_FILE.tmp" \
            && mv "$FAIL_FILE.tmp" "$FAIL_FILE"
    fi
    printf '%s\t%s\t%s\t%s\n' "$base" "$cls" "$count" "$(date -Iseconds)" >> "$FAIL_FILE"
    say "failure recorded: $base class=$cls count=$count (archive strikes: $STRIKES)"
    case "$cls" in
        unsupported_arch)
            if (( count >= STRIKES )); then
                say "archive-eligible=yes (repeated unsupported_arch)"
                archive "$f" "unsupported_arch x$count: the loader refused it at every ctx on $count separate runs" || return 1
            else
                say "archive-eligible=no (one refusal is a run, not a fact)"
            fi
            ;;
        *)
            say "archive-eligible=no (class $cls is not a model verdict)"
            ;;
    esac
}

MODE="" FILE="" REASON="" CLASS="" ASSUME="no"
while (( $# )); do
    case "$1" in
        --assess) MODE=assess; shift ;;
        --record-failure) MODE=record; shift ;;
        --archive) MODE=archive; shift ;;
        --class) CLASS="${2:-}"; shift 2 ;;
        --reason) REASON="${2:-}"; shift 2 ;;
        --yes) ASSUME=yes; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) die "unknown option: $1" ;;
        *) FILE="$1"; shift ;;
    esac
done
[[ -n "$MODE" ]] || { usage; exit 2; }
[[ -n "$FILE" ]] || die "a model file is required"

case "$MODE" in
    assess) assess "$FILE" ;;
    record) [[ -n "$CLASS" ]] || die "--record-failure needs --class"
            record_failure "$FILE" "$CLASS" ;;
    archive) [[ -n "$REASON" ]] || die "--archive needs --reason"
             archive "$FILE" "$REASON" "$ASSUME" ;;
esac
