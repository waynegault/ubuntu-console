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
# A single failure, an OOM (resource_exhausted), a loader_vintage gap (the build cannot read the
# model's GGUF metadata) or an unclassified failure NEVER archives.  Only two tokens are
# model-attributable: unsupported_arch and launch_error.
#
# WHAT IT WRITES.  Before the move, and durably:
#   $LLM_STATE_DIR/autotune-archive.log   <ts> TAB <file> TAB <bytes> TAB <class> TAB <reason>
#   $STATE_DIR/autotune-retired.rows      <file>|<reason>   (the resume loop's tombstone)
# The tombstone is what stops the next derivation re-owing the row; the log is the why.
#
# Exit: 0 done/not-eligible, 1 refused, 2 usage.
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 7
#   v7 (2026-11-09): the loader_vintage refusal stopped asserting the cause.  v4 had changed it
#       to "rebuild llama.cpp first, the weights are not the problem" to match a 2026-11-06
#       measurement, while autotune-model.sh's label on the SAME class said "rebuilding does not
#       help" — one run printed both.  Measured 2026-11-09: GLM-5.3-Flash-REAP50-IQ3_M.gguf lacks
#       four keys the installed build requires (kpool and the renamed hyper_connection trio), so
#       the file was the stale side and the earlier rebuild changed nothing.  The refusal now
#       says the two sides disagree, names the check that decides, and keeps the verdict.
# Module Version: 6
#   v6 (2026-11-07): §18.3 debt this file carried from its first cut — a purpose comment
#       above every function (9.5), one `warn` helper instead of five hand-written `>&2`
#       (10.7), the two over-long lines wrapped (8.1.8), the three non-0/1 exit codes
#       annotated (9.7), and a `*)` arm on the mode dispatch (4.2.4).  No behaviour change:
#       the same bytes reach stdout and stderr, and tests/unit/27b passes unchanged.
#   v5 (2026-11-06): hygiene — the ledger's tab separators were LITERAL tab bytes in the
#       source (`-F'<TAB>'`, `IFS=$'<TAB>'`, and a printf format split by a real newline),
#       which the repo's "no tabs in core scripts" rule forbids, and the file carried no
#       `# end of file` marker.  Now `$'\t'` / `\t` escapes; the bytes written to the ledger
#       are identical and tests/unit/27b passes unchanged.
#   v4 (2026-11-06): the loader_vintage refusal said "a rebuild does NOT fix it, the file needs
#       re-converting", contradicting v3's own measurement (build 148 could not read
#       glm5-next.attention.indexer.kpool, and a rebuild was the fix).  tests/unit/27b pins the
#       v3 criterion and failed against the message; the message now says rebuild llama.cpp and
#       keep the weights.  No verdict changes — loader_vintage still never archives.
#   v1 (2026-11-06, Wayne): first cut - assess / record-failure / archive.
#   v3 (2026-11-06): (a) a bare basename resolves against MODEL_DIR - the autotune failure path
#       calls this with the registry's NAME, and v2 refused it with "no such model:
#       GLM-5.3-...gguf" while the file sat in active/, which is a refusal for the wrong reason;
#       (b) class loader_vintage is named in its refusal, because "a recorded class is not a
#       model verdict" understated a build gap: measured 2026-11-06, build 148 could not read
#       glm5-next.attention.indexer.kpool, that reached this tool as launch_error (attributable),
#       and three such boots would have archived a 67 GiB model that only needed a rebuild.
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

# warn - the tool's ONE stderr path, so every refusal and error has the same shape and a
# caller can grep it (10.7).  Nothing here writes to stderr by hand.
warn() { printf '%s\n' "$*" >&2; }
# die - a usage or refusal error: the message through warn, then exit 2 (2 = usage/refusal).
die() { warn "llm-archive-unusable: $*"; exit 2; }
# say - the tool's stdout line: verdicts and records, never diagnostics.
say() { printf '%s\n' "$*"; }

# usage - the three modes and the env knobs, printed on -h and when no mode is given.
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

# mem_total_mib - this box's guest RAM in MiB: the pool a CUDA allocation is drawn from.
mem_total_mib() {
# swallow-ok: an unreadable /proc/meminfo yields empty and assess refuses with unknown-memory
    awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null
}

# size_mib <file> - the file's size in MiB, rounded UP so a file just over a ceiling
# never reads as under it.
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

# total_mib_of_set <file> - the whole shard set's size: llama.cpp loads every part, so
# one shard's size is not the model's.
total_mib_of_set() {
    local t=0 f
    while IFS= read -r f; do t=$(( t + $(size_mib "$f") )); done < <(shards_of "$1")
    printf '%d' "$t"
}

# resolve_model <path-or-name> - a bare basename resolves against MODEL_DIR, because the
# autotune failure path hands us the registry's NAME; a real miss still reads as a miss.
resolve_model() {
    local f="$1"
    if [[ -f "$f" ]]; then printf '%s' "$f"; return 0; fi
    if [[ -f "$MODEL_DIR/$f" ]]; then printf '%s' "$MODEL_DIR/$f"; return 0; fi
    printf '%s' "$f"
}

# assess <file> - the capacity verdict against THIS box's guest RAM, with no side effects.
assess() {
    local f total_mib mem_mib ceiling verdict
    f=$(resolve_model "$1")
    [[ -f "$f" ]] || { echo "verdict=missing"; return 1; }
    total_mib=$(total_mib_of_set "$f")
    mem_mib=$(mem_total_mib)
    [[ "$mem_mib" =~ ^[0-9]+$ ]] && (( mem_mib > 0 )) || { echo "verdict=unknown-memory"; return 1; }
    ceiling=$(( mem_mib - RESERVE_MIB ))
    if (( total_mib > ceiling )); then verdict=too-big; else verdict=fits; fi
    printf 'file=%s\nset_mib=%s\nguest_mib=%s\nreserve_mib=%s\nceiling_mib=%s\nverdict=%s\n' \
        "$(basename "$f")" "$total_mib" "$mem_mib" "$RESERVE_MIB" "$ceiling" "$verdict"
    # 3 = too big for this box (a verdict, not an error); 0 = it fits.
    [[ "$verdict" == "too-big" ]] && return 3 || return 0
}

# resolve_model <path-or-name> - the autotune failure path hands us the registry's NAME
# (basename), not a path, and a bare -f test on that name refused a file that exists.
# Echoes the path it settled on; callers still test -f so a real miss is still a miss.
archive() {
    local f="$1" reason="$2" assume="${3:-no}" set size shard moved=0
    f=$(resolve_model "$f")
    [[ -f "$f" ]] || { warn "refusing: no such model: $1 (tried as given and as $MODEL_DIR/$1)"; return 1; }
    set=$(shards_of "$f")
    [[ -n "$set" ]] || { warn "refusing: no shards resolved for $f"; return 1; }
    size=$(total_mib_of_set "$f")
    if [[ "$AUTO" != "1" && "$assume" != "yes" ]]; then
        warn "refusing: AUTOTUNE_ARCHIVE_AUTO=$AUTO and no --yes (would move ${size} MiB)"
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
            warn "ERROR: could not move $shard — it is still in the active store"; return 1
        fi
    done <<< "$set"
    say "archived ${moved} file(s), ${size} MiB -> $ARCHIVE_DIR"
    say "reason: $reason"
    say "recorded: $ARCHIVE_LOG and $RETIRED"
}

# record_failure <file> <class> - tally one classified failure and archive when the rule
# is met: two model-attributable strikes, and never on a class that is not about the model.
record_failure() {
    local f="$1" cls="$2" base count total=0 attributable=yes _b _c _n _t
    base=$(basename "$f")
    mkdir -p "$LOG_DIR"
    # Tally per class, but COUNT PER MODEL: two different refusals of the same 67 GiB
    # file are two facts about that model, not two classes each holding one vote.
    count=0
    if [[ -r "$FAIL_FILE" ]]; then
        count=$(awk -F$'\t' -v b="$base" -v c="$cls" '$1==b && $2==c {print $3; exit}' "$FAIL_FILE")
        [[ "$count" =~ ^[0-9]+$ ]] || count=0
        awk -F$'\t' -v b="$base" -v c="$cls" '!( $1==b && $2==c )' "$FAIL_FILE" \
            > "$FAIL_FILE.tmp" && mv "$FAIL_FILE.tmp" "$FAIL_FILE"
    fi
    count=$(( count + 1 ))
    printf '%s\t%s\t%s\t%s\n' "$base" "$cls" "$count" "$(date -Iseconds)" >> "$FAIL_FILE"
    # A class that says nothing about the MODEL vetoes the archive however often it
    # repeats: an OOM is this run's sizing, and unclassified is this run's mystery.
    while IFS=$'\t' read -r _b _c _n _t; do
        [[ "$_b" == "$base" ]] || continue
        case "$_c" in
            unsupported_arch|launch_error) ;;
            *) attributable=no ;;
        esac
        [[ "$_n" =~ ^[0-9]+$ ]] && total=$(( total + _n ))
    done < "$FAIL_FILE"
    say "failure recorded: $base class=$cls count=$count; model total=$total (strikes: $STRIKES)"
    if [[ "$attributable" != "yes" ]]; then
        # A missing or unreadable ledger means no vintage row - the same answer as grep
        # finding none, and the alternative is a spurious error on a fresh box.
        # swallow-ok: absent ledger == no vintage row; grep's own stderr is not wanted here
        if grep -q $'^'"$base"$'\tloader_vintage\t' "$FAIL_FILE" 2>/dev/null; then
            say "archive-eligible=no (loader_vintage - the FILE and the LOADER disagree about a" \
                "required GGUF key, so the weights are not at fault.  Which side is stale is not" \
                "knowable from the message: if the installed build knows the key the file is" \
                "incomplete (re-convert or obtain a matching GGUF); if it does not, rebuild" \
                "llama.cpp.  Do not archive.)"
        else
            say "archive-eligible=no (a recorded class is not a model verdict)"
        fi
        return 0
    fi
    if (( total >= STRIKES )); then
        say "archive-eligible=yes ($total model-attributable failures)"
        archive "$f" "$total model-attributable failures; latest $cls x$count (see autotune-failures.tsv)" || return 1
    else
        say "archive-eligible=no ($total of $STRIKES strikes; one refusal is a run, not a fact)"
    fi
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
# 2 = usage: no mode was given, so there is nothing to do.
[[ -n "$MODE" ]] || { usage; exit 2; }
[[ -n "$FILE" ]] || die "a model file is required"

case "$MODE" in
    assess) assess "$FILE" ;;
    record) [[ -n "$CLASS" ]] || die "--record-failure needs --class"
            record_failure "$FILE" "$CLASS" ;;
    archive) [[ -n "$REASON" ]] || die "--archive needs --reason"
             archive "$FILE" "$REASON" "$ASSUME" ;;
    *) die "unhandled mode: $MODE" ;;
esac
# end of file
