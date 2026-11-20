#!/usr/bin/env bats
# ==============================================================================
# Unit — an INCOMPLETE split GGUF is a download fault, not an unsupported model
# ==============================================================================
# WHY THIS EXISTS (AUTOTUNE-SHARD-001, measured 2026-11-02 05:47): three of eight rows
# on disk were shard 1 of N with the rest absent.  The batch walked the whole ctx ladder,
# retried with --flash-attn off (a quant/attention hypothesis that cannot help a file
# that is not there), printed
#
#   Test 1: ctx 131072 - unsupported model - model cannot be loaded at any ctx
#
# and left the reader concluding the 70B NVFP4 QUANT was broken on this card.  The size
# column made it worse: it reported shard 1's bytes as the model's size.
#
# THE DEFECT IS A WORDING DEFECT WITH A LEDGER CONSEQUENCE.  `unsupported_arch` is one of
# the two model-attributable classes bin/llm-archive-unusable.sh will archive on, so an
# unfinished download that repeats twice MOVES 40-70 GiB of weights out of the store.
#
# WHAT THESE CASES PIN
#   1. the shard-set predicate: complete, missing tail, missing HEAD (the live shape on
#      this box 2026-11-10: Qwen3.8-Flash-Next-AD holds 00002/00003 and no 00001), single
#      file, and a nested set resolved beside the file rather than in the store root;
#   2. the refusal sentence names the files to fetch, and counts present-vs-expected;
#   3. the class is incomplete_download, and its label never says "unsupported";
#   4. the classifier's backstop: a missing-shard log line is incomplete_download, while
#      an OOM on a SPLIT model — whose log also names a shard — is still resource_exhausted;
#   5. the archive tool never archives an incomplete_download, however often it repeats;
#   6. the CONTROL: a complete 2-shard set refuses nothing and sums its shards.
#
# FALSIFICATION: with the gate and the classifier arm reverted, cases 2-4 fail (the
# refusal prints nothing and the missing-shard log reads launch_error).  Verified against
# the pre-change file in this worktree.
#
# No GPU, no server, no registry write: every case is a pure function or a file fixture.
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
export REPO_ROOT

setup() {
    SANDBOX="$(mktemp -d)"
    export SANDBOX
    # 11b carries the shard-set predicate; 11a/01-constants are its normal load context.
    source "$REPO_ROOT/scripts/01-constants.sh"
    source "$REPO_ROOT/scripts/11b-llm-autotune.sh"
}

teardown() { rm -rf "$SANDBOX"; }

# __shard <dir> <name> [bytes] — a fixture shard, sparse (no real bytes are read).
__shard() {
    local dir="$1" name="$2" bytes="${3:-1024}"
    mkdir -p "$dir"
    head -c "$bytes" /dev/zero > "$dir/$name"
}

# ── 1. the shard-set predicate ───────────────────────────────────────────────

@test "split: a COMPLETE set reports nothing missing (the control)" {
    # The assertion below is `-z`, which a MISSING function also satisfies (command not found
    # yields empty).  Name the dependency first, so this control cannot pass on a tree that
    # never had the fix — the green-because-out-of-scope shape, applied to this file.
    declare -F __autotune_split_shards_missing >/dev/null \
        || { echo "__autotune_split_shards_missing is not defined"; return 1; }
    __shard "$SANDBOX/a" "Model-00001-of-00002.gguf"
    __shard "$SANDBOX/a" "Model-00002-of-00002.gguf"
    local out
    out=$(__autotune_split_shards_missing "$SANDBOX/a/Model-00001-of-00002.gguf")
    [[ -z "$out" ]] || { echo "a complete set was called incomplete: '$out'"; return 1; }
}

@test "split: a missing TAIL is named, one file per line, in order" {
    __shard "$SANDBOX/b" "Big-00001-of-00005.gguf"
    __shard "$SANDBOX/b" "Big-00002-of-00005.gguf"
    local out
    out=$(__autotune_split_shards_missing "$SANDBOX/b/Big-00001-of-00005.gguf")
    [[ "$out" == "Big-00003-of-00005.gguf
Big-00004-of-00005.gguf
Big-00005-of-00005.gguf" ]] || { echo "got: '$out'"; return 1; }
}

@test "split: a missing HEAD is named (the shape on disk now: 00002/00003, no 00001)" {
    # Measured 2026-11-10: /home/wayne/models/active holds Qwen3.8-Flash-Next-AD-…-00002
    # and -00003 of 00003 and no -00001.  A tail-only check would call that set complete,
    # which is why the predicate walks 1..N rather than "everything after this one".
    __shard "$SANDBOX/c" "AD-00002-of-00003.gguf"
    __shard "$SANDBOX/c" "AD-00003-of-00003.gguf"
    local out
    out=$(__autotune_split_shards_missing "$SANDBOX/c/AD-00002-of-00003.gguf")
    [[ "$out" == "AD-00001-of-00003.gguf" ]] || { echo "got: '$out'"; return 1; }
}

@test "split: a single file and a non-split name both report nothing" {
    declare -F __autotune_split_shards_missing >/dev/null \
        || { echo "__autotune_split_shards_missing is not defined"; return 1; }
    __shard "$SANDBOX/d" "Single.gguf"
    [[ -z "$(__autotune_split_shards_missing "$SANDBOX/d/Single.gguf")" ]]
    # A name that carries digits but is not a -NNNNN-of-NNNNN declaration.
    __shard "$SANDBOX/d" "Model-2024-Q4.gguf"
    [[ -z "$(__autotune_split_shards_missing "$SANDBOX/d/Model-2024-Q4.gguf")" ]]
    # And an absent path says nothing rather than inventing a set.
    [[ -z "$(__autotune_split_shards_missing "$SANDBOX/d/nope.gguf")" ]]
}

@test "split: siblings are looked for BESIDE the file, never in the store root" {
    __shard "$SANDBOX/e/active" "Nested-00001-of-00002.gguf"
    __shard "$SANDBOX/e/active" "Nested-00002-of-00002.gguf"
    # The root holds a decoy with the same name; it must not satisfy the set.
    __shard "$SANDBOX/e" "Nested-00002-of-00002.gguf"
    [[ -z "$(__autotune_split_shards_missing "$SANDBOX/e/active/Nested-00001-of-00002.gguf")" ]]
    # Now remove the sibling and leave only the root decoy: the set IS incomplete.
    rm -f "$SANDBOX/e/active/Nested-00002-of-00002.gguf"
    local out
    out=$(__autotune_split_shards_missing "$SANDBOX/e/active/Nested-00001-of-00002.gguf")
    [[ "$out" == "Nested-00002-of-00002.gguf" ]] || { echo "root decoy satisfied the set: '$out'"; return 1; }
}

# ── 2. the refusal sentence ──────────────────────────────────────────────────

@test "split: the refusal counts present-vs-expected and names the files to fetch" {
    eval "$(sed -n '/^function __autotune_split_refusal()/,/^}/p' "$REPO_ROOT/scripts/autotune-model.sh")"
    __shard "$SANDBOX/f" "AD-00002-of-00003.gguf"
    __shard "$SANDBOX/f" "AD-00003-of-00003.gguf"
    local out
    out=$(__autotune_split_refusal "$SANDBOX/f/AD-00002-of-00003.gguf")
    [[ "$out" == "shard 2 of 3 present — expecting AD-00001-of-00003.gguf" ]] \
        || { echo "got: '$out'"; return 1; }
    # A complete set says NOTHING — the control for the same function.
    __shard "$SANDBOX/f" "AD-00001-of-00003.gguf"
    [[ -z "$(__autotune_split_refusal "$SANDBOX/f/AD-00002-of-00003.gguf")" ]] \
        || { echo "a complete set was still refused"; return 1; }
    # A single file is never refused.
    __shard "$SANDBOX/f" "Whole.gguf"
    [[ -z "$(__autotune_split_refusal "$SANDBOX/f/Whole.gguf")" ]]
}

# ── 3. the class and its label ───────────────────────────────────────────────

@test "split: the class is incomplete_download and its label never says unsupported" {
    eval "$(sed -n '/^__autotune_failure_label()/,/^}/p' "$REPO_ROOT/scripts/autotune-model.sh")"
    local label
    label=$(__autotune_failure_label incomplete_download)
    [[ "$label" == *"incomplete split GGUF"* ]] || { echo "label: '$label'"; return 1; }
    [[ "$label" == *"not unsupported"* ]] || { echo "label does not separate the two: '$label'"; return 1; }
    [[ "$label" == *"row unchanged"* ]] || { echo "label does not state the ledger effect: '$label'"; return 1; }
    # The unsupported label is untouched — this change adds a class, it does not rewrite one.
    [[ "$(__autotune_failure_label unsupported_arch)" == "unsupported architecture / no matching backend" ]]
}

# ── 4. the classifier's backstop, and the discrimination control ─────────────

@test "split: a missing-shard log is incomplete_download, an OOM on the SAME set is still an OOM" {
    eval "$(sed -n '/^__autotune_classify_failure()/,/^}/p' "$REPO_ROOT/scripts/autotune-model.sh")"
    local log="$BATS_TEST_TMPDIR/split.log"

    # llama.cpp's own wording when a later shard is absent.
    printf "llama_model_load: error loading model: failed to open '/models/AD-00002-of-00003.gguf' for reading: No such file or directory\n" > "$log"
    [[ "$(__autotune_classify_failure "$log")" == "incomplete_download" ]] \
        || { echo "got: $(__autotune_classify_failure "$log")"; return 1; }

    # The path can contain any character, including 'n' — a character class that tried to
    # exclude a newline would silently stop matching 'nested/models/…'.
    printf "llama_model_load: error loading model: failed to open '/home/wayne/models/nested/AD-00002-of-00003.gguf' for reading: No such file or directory\n" > "$log"
    [[ "$(__autotune_classify_failure "$log")" == "incomplete_download" ]] \
        || { echo "a path containing 'n' defeated the pattern: $(__autotune_classify_failure "$log")"; return 1; }

    # The verb AFTER the filename is the other order llama.cpp can print.
    printf "cannot open model file '/models/AD-00003-of-00005.gguf': not found\n" > "$log"
    [[ "$(__autotune_classify_failure "$log")" == "incomplete_download" ]] \
        || { echo "reverse order: $(__autotune_classify_failure "$log")"; return 1; }

    # DISCRIMINATION CONTROL: an OOM log on a SPLIT model also names a shard file.  Matching
    # the filename alone would reclassify every OOM on a split set, which is the defect this
    # arm is ordered to avoid.  resource_exhausted must win.
    printf "llama_model_load: loading model from '/models/AD-00001-of-00003.gguf'\n" > "$log"
    printf 'ggml_backend_cuda_buffer_type_alloc_buffer: allocating 61440.00 MiB: cudaMalloc failed: out of memory\n' >> "$log"
    [[ "$(__autotune_classify_failure "$log")" == "resource_exhausted" ]] \
        || { echo "an OOM on a split model was misclassified: $(__autotune_classify_failure "$log")"; return 1; }

    # And a genuine architecture verdict is unchanged.
    printf "llama_model_load: error loading model: unknown model architecture: 'gpt-oss'\n" > "$log"
    [[ "$(__autotune_classify_failure "$log")" == "unsupported_arch" ]]
}

# ── 5. the archive tool never retires a download ────────────────────────────

@test "split: incomplete_download never archives, however often it repeats" {
    local tool="$REPO_ROOT/bin/llm-archive-unusable.sh"
    mkdir -p "$SANDBOX/active" "$SANDBOX/state"
    export LLAMA_MODEL_DIR="$SANDBOX/active"
    export LLM_ARCHIVE_DIR="$SANDBOX/archived"
    export TAC_STATE_DIR="$SANDBOX/state"
    export LLM_STATE_DIR="$SANDBOX/state/.llm"
    export AUTOTUNE_ARCHIVE_AUTO=1
    head -c 2000 /dev/zero > "$SANDBOX/active/AD-00001-of-00003.gguf"
    local i
    for i in 1 2 3; do
        run "$tool" --record-failure "$SANDBOX/active/AD-00001-of-00003.gguf" --class incomplete_download
        [[ "$status" -eq 0 ]]
        [[ "$output" == *"archive-eligible=no"* ]] || { echo "run $i: $output"; return 1; }
    done
    [[ -f "$SANDBOX/active/AD-00001-of-00003.gguf" ]] || { echo "a download fault archived the model"; return 1; }
    [[ ! -d "$SANDBOX/archived" || -z "$(ls -A "$SANDBOX/archived" 2>/dev/null)" ]]
}

@test "split: the retry ladder never answers a missing shard with --flash-attn off" {
    # A FA-off retry is a quant/attention hypothesis.  For an absent file it can only fail
    # again — and the class it then records (load_fail) is model-attributable, so two runs
    # would archive 40-70 GiB over an unfinished download.
    eval "$(sed -n '/^function __autotune_fa_retry()/,/^}/p' "$REPO_ROOT/scripts/11b-llm-autotune.sh")"
    [[ "$(__autotune_fa_retry incomplete_download on f16)" == "incomplete_download" ]] \
        || { echo "got: $(__autotune_fa_retry incomplete_download on f16)"; return 1; }
    # ...and it is not the OOM/unknown arms answering instead.
    [[ "$(__autotune_fa_retry oom on f16)" == "descend" ]]
    [[ "$(__autotune_fa_retry loader_crash_unknown on f16)" == "stop" ]]
    # A plain load failure keeps the one legitimate FA-off retry (unchanged behaviour).
    [[ "$(__autotune_fa_retry load_fail on f16)" == "retry" ]]
}

@test "split: a smaller ctx is never walked for either unloadable class" {
    eval "$(sed -n '/^last_fail_type()/,/^}/p' "$REPO_ROOT/scripts/autotune-model.sh")"
    eval "$(sed -n '/^_gguf_unrunnable()/,/^}/p' "$REPO_ROOT/scripts/autotune-model.sh")"
    eval "$(sed -n '/^_fail_label_for_unrunnable()/,/^}/p' "$REPO_ROOT/scripts/autotune-model.sh")"
    local f="/tmp/at-metrics-$$"
    printf '0|0|load_fail\n' > "$f"
    _gguf_unrunnable || { echo "load_fail must stop the ladder"; rm -f "$f"; return 1; }
    [[ "$(_fail_label_for_unrunnable)" == "unsupported model" ]]
    printf '0|0|incomplete_download\n' > "$f"
    _gguf_unrunnable || { echo "incomplete_download must stop the ladder"; rm -f "$f"; return 1; }
    [[ "$(_fail_label_for_unrunnable)" == "incomplete download (shard missing)" ]] \
        || { echo "label: '$(_fail_label_for_unrunnable)'"; rm -f "$f"; return 1; }
    # An OOM still descends: shrinking ctx is exactly the remedy for it.
    printf '0|0|oom\n' > "$f"
    ! _gguf_unrunnable || { echo "an OOM must still descend"; rm -f "$f"; return 1; }
    printf '0|0|\n' > "$f"
    ! _gguf_unrunnable
    rm -f "$f"
}

@test "split: no call site compares last_fail_type to a literal any more" {
    # The population is DERIVED, not listed: every `== "load_fail"` spelling is gone, so a
    # future class cannot be added to one site and forgotten at the other ten.
    ! grep -q 'last_fail_type) == "load_fail"' "$REPO_ROOT/scripts/autotune-model.sh" \
        || { echo "a literal comparison survived; use _gguf_unrunnable"; return 1; }
    # And the predicate is actually used more than once (a helper nobody calls is not a fix).
    [[ "$(grep -c '_gguf_unrunnable' "$REPO_ROOT/scripts/autotune-model.sh")" -ge 5 ]] \
        || { echo "the predicate is barely wired"; return 1; }
}

# ── 6. the wiring, and the size control ─────────────────────────────────────

@test "split: the script refuses with this class BEFORE the lane stand-down" {
    local src="$REPO_ROOT/scripts/autotune-model.sh"
    # The call exists, and it is the refusal class this card asks for.
    grep -qF '__autotune_split_refusal "$MODEL_PATH"' "$src" \
        || { echo "the gate does not call the predicate"; return 1; }
    grep -qF '_preflight_refuse incomplete_download 1' "$src" \
        || { echo "the gate does not refuse as incomplete_download"; return 1; }
    # ORDERING IS THE FIX: a refusal must not stop a serving lane.  Both line numbers are
    # read from the file, so a later edit that moves the gate below the stand-down fails here.
    local gate_line stand_down_line
    gate_line=$(grep -n '^    _incomplete_detail=\$(__autotune_split_refusal' "$src" | cut -d: -f1)
    stand_down_line=$(grep -n '^    __llm_stand_down_cuda_lanes || true' "$src" | cut -d: -f1)
    [[ -n "$gate_line" && -n "$stand_down_line" ]] || { echo "anchor missing: gate=$gate_line stand=$stand_down_line"; return 1; }
    (( gate_line < stand_down_line )) \
        || { echo "the gate (line $gate_line) runs AFTER the stand-down (line $stand_down_line)"; return 1; }
}

@test "split: a COMPLETE set still sums its shards (the size control)" {
    # __autotune_model_bytes must keep summing a whole set: the gate above refuses a PARTIAL
    # one, and if it ever refused a complete one the size fix it depends on would be dead.
    __shard "$SANDBOX/g" "Two-00001-of-00002.gguf" 1000
    __shard "$SANDBOX/g" "Two-00002-of-00002.gguf" 2000
    [[ "$(__autotune_model_bytes "$SANDBOX/g/Two-00001-of-00002.gguf")" == "3000" ]]
    [[ -z "$(__autotune_split_shards_missing "$SANDBOX/g/Two-00001-of-00002.gguf")" ]]
}

# ── 7. end to end: the gate refuses, and only the incomplete set ────────────

# _gate_run <sandbox> <shard-names…> — run the REAL script against a sandboxed store with
# every outward-facing command stubbed.  Nothing touches the card, systemd or the registry:
# the same isolation tests/unit/08 uses for its selftest cases.
_gate_run() {
    local sb="$1"; shift
    mkdir -p "$sb/home" "$sb/drive/active"
    local paths reg mdir
    paths=$(env -u VIRTUAL_ENV HOME="$sb/home" LLAMA_DRIVE_ROOT="$sb/drive" \
        bash -c 'source "$1/scripts/01-constants.sh" >/dev/null 2>&1; printf "%s|%s" "${LLM_REGISTRY:-}" "${LLAMA_MODEL_DIR:-}"' \
        _ "$REPO_ROOT" 2>/dev/null)
    reg="${paths%%|*}"; mdir="${paths#*|}"
    # SOURCING THE CONSTANTS IS NOT A SANDBOX FOR THE REGISTRY.  LLAMA_MODEL_DIR derives from
    # HOME, so it lands in $sb — but the asus host profile names LLM_REGISTRY with an ABSOLUTE
    # path (the registry sits beside the models, not in the state dir), and that overrides
    # HOME=$sb/home.  Measured 2026-11-20: reg resolved to /home/wayne/models/active/models.conf
    # and this harness wrote its fixture row straight over the PRODUCTION registry, which then
    # reddened tests/unit/98-lane-certification.bats (the certified coder row was gone).
    # Pin both inside the run, and refuse to write at all if a future profile escapes.
    [[ "$reg" == "$sb"/* ]] || reg="$sb/home/models/active/models.conf"
    [[ "$mdir" == "$sb"/* ]] || mdir="$sb/home/models/active"
    case "$reg" in
        "$sb"/*) ;;
        *) echo "harness refuses to write a registry outside the sandbox: $reg"; return 1 ;;
    esac
    mkdir -p "$mdir" "$(dirname "$reg")"
    printf '%s' "$reg" > "$sb/regpath"
    local name
    for name in "$@"; do head -c 2000 /dev/zero > "$mdir/$name"; done
    local first="$1"
    { printf '%s\n' "#|name|file|size_gb|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|fit_target_mb|backend|mmap_mode|flash_attn|tps|autotuned|is_default|in_vram"
      printf '1|AD|%s|0.1G|Q4_K_M/q8_0|qwen4exp|0|4096|4|1024|256|1|256|native|auto|on|0|no|no|no\n' "$first"
    } > "$reg"
    # shellcheck disable=SC2317  # invoked by the child bash through the exported environment
    nvidia-smi() {
        case "$*" in
            *memory.free*|*memory.total*) printf '81920\n' ;;
            *memory.used*) printf '0\n' ;;
            *pstate*) printf 'P0\n' ;;
            *clocks_throttle_reasons.active*) printf '0x0\n' ;;
            *temperature.gpu*) printf '45, 1500\n' ;;
            *) printf '0\n' ;;
        esac
    }
    pkill() { return 0; }
    pgrep() { return 1; }
    systemctl() { return 1; }
    sleep() { :; }
    export -f nvidia-smi pkill pgrep systemctl sleep
    env HOME="$sb/home" LLAMA_DRIVE_ROOT="$sb/drive" LLM_REGISTRY="$reg" LLAMA_MODEL_DIR="$mdir" \
        HEAVY_JOB_LOCK="$sb/heavy-job.lock" CUDA_CYCLE_FILE="$sb/cycles" CUDA_STALL_FILE="$sb/stalls" \
        LLM_AUTOTUNE_BASELINE_GAP_MAX=999999 AUTOTUNE_SELFTEST=1 \
        LLAMA_WATCHDOG_CUDA_SUSPEND_FILE="$sb/susp" LLM_AUTOTUNE_RESULT_FILE="$sb/result" \
        bash "$REPO_ROOT/scripts/autotune-model.sh" 1 --workload chat 2>&1
}

@test "split: end to end, the gate refuses BEFORE any launch and records the class" {
    local sb="$BATS_TEST_TMPDIR/e2e-incomplete"
    run _gate_run "$sb" "AD-00002-of-00003.gguf" "AD-00003-of-00003.gguf"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"incomplete split GGUF: shard 2 of 3 present — expecting AD-00001-of-00003.gguf"* ]] \
        || { echo "output: $output"; return 1; }
    [[ "$output" == *"DOWNLOAD fault, not an unsupported model"* ]]
    # No launch happened: none of the bench's own lines are present.
    [[ "$output" != *"Test 1:"* ]] || { echo "a server was launched: $output"; return 1; }
    [[ "$output" != *"retrying once with --flash-attn off"* ]] || { echo "the FA-off retry ran"; return 1; }
    # The machine-readable verdict, and the row left alone.
    grep -qx 'stage=preflight' "$sb/result"
    grep -qx 'classification=incomplete_download' "$sb/result"
    grep -qx 'outcome=not_certified' "$sb/result"
    # The row this run read is named by the harness, not guessed: a search that found
    # nothing would make the assertion below vacuous.
    local reg; reg=$(cat "$sb/regpath")
    [[ -f "$reg" ]] || { echo "the harness did not record a registry path"; return 1; }
    [[ "$(awk -F'|' '$1=="1"{print $44}' "$reg")" == "" ]] \
        || { echo "the row was marked: col44=[$(awk -F'|' '$1=="1"{print $44}' "$reg")]"; return 1; }
}

@test "split: end to end CONTROL — a complete set is NOT refused by this gate" {
    local sb="$BATS_TEST_TMPDIR/e2e-complete"
    run _gate_run "$sb" "AD-00001-of-00002.gguf" "AD-00002-of-00002.gguf"
    # Whatever else this stubbed box does with a 2 KB fake GGUF, the SHARD gate must not fire:
    # a guard that refused a complete set would pass the case above and break every real run.
    # Positive half first: the run must have STARTED the row (otherwise "no refusal" is a
    # statement about an empty output rather than about the gate).
    [[ "$output" == *"[1] AD"* ]] || { echo "the run never started: $output"; return 1; }
    [[ "$output" != *"incomplete split GGUF"* ]] || { echo "a complete set was refused: $output"; return 1; }
}
