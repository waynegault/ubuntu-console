#!/usr/bin/env bats
# ==============================================================================
# Unit Tests — the failure classification carries a DETECTED cause
# ==============================================================================
# The row that OOM'd at ctx 8192 (Llama-3-70B-Q6_K, 38016 MiB model against
# 21683 MiB free) is SIGKILLed.  The child leaves no server log, so
# __autotune_classify_failure is handed an empty file, matches nothing, and the
# ledger records "unclassified" — while /tmp/at-metrics-$$ already says "oom".
# The reason was detected and then discarded at the writer.
#
# WHAT THIS PINS, and why each arm exists:
#   * oom reaches the ledger as resource_exhausted (the fix itself);
#   * load_fail stays UNMAPPED — it is overloaded, because the never-became-healthy
#     check reads "!= load_fail" to tell a stall from a real load failure, so the
#     function has already declined to name an architecture.  Mapping it would
#     manufacture a verdict the log never gave;
#   * a log that DOES name something still wins.  The carried token fills the hole
#     the kill left; it must never override a real signature, or a defaulted "oom"
#     would clobber a log that actually said launch_error;
#   * no producer anywhere writes classification=oom — one vocabulary, no translator;
#   * _fa_cause stays local to _bench_spawn, so bench_ctx cannot claim a cause it
#     never observed.
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/autotune-model.sh"

# Extract the named top-level functions, and nothing that executes at load time.
# A whole-file "source" would RUN the script; a byte-range extract would rot the
# moment a line is added above it.  Termination is any closing brace at the start
# of a line.  Column 0 only: record_failure closes an inner group as
# "    } > /tmp/at-fail-$$", and terminating there would cut the function's own
# closing brace two lines later - a harness with an unexpected EOF, which fails
# every arm for a reason that has nothing to do with the patch.
extract_fns() {
    awk -v want="$1" '
        BEGIN { n = split(want, w, " "); for (i = 1; i <= n; i++) keep[w[i]] = 1 }
        /^[A-Za-z_][A-Za-z0-9_]*\(\)[ ]*\{/ {
            fn = $0; sub(/\(\).*/, "", fn); on = (fn in keep)
        }
        on { print }
        on && /^\}/ { on = 0 }
    ' "$SCRIPT"
}

setup() {
    HARNESS="$BATS_TEST_TMPDIR/fns.sh"
    extract_fns "_bench_log_tail __autotune_classify_failure _bench_class_from_startup _bench_record_failure _autotune_failure_report __autotune_failure_label last_fail_type _last_fail_label _probe_no_mmap_climb probe_no_mmap" > "$HARNESS"
    # A harness that failed to extract would make every arm below vacuous.
    grep -q '^_bench_record_failure() {' "$HARNESS"
    grep -q '^_bench_class_from_startup() {' "$HARNESS"
    grep -q '^_last_fail_label() {' "$HARNESS"
    grep -q '^probe_no_mmap() {' "$HARNESS"
    LOG="$BATS_TEST_TMPDIR/server.log"
    : > "$LOG"
}

# Run _bench_record_failure against $LOG with a carried class, echo the
# classification line.  $$ inside the sourced function is this shell's pid, so the
# side file is ours and is removed here rather than left in /tmp.
classify_with() {
    local carried="$1"
    bash -c '
        source "$1" || exit 90
        _BENCH_LOG="$2"
        _bench_record_failure 8192 512 128 99 "q4_0/q4_0" "$3"
        sed -n "s/^classification=//p" "/tmp/at-fail-$$"
        rm -f "/tmp/at-fail-$$"
    ' _ "$HARNESS" "$LOG" "$carried"
}

@test "a SIGKILLed launch carries resource_exhausted instead of unclassified" {
    : > "$LOG"
    run classify_with "$(bash -c 'source "$1"; _bench_class_from_startup oom' _ "$HARNESS")"
    [ "$status" -eq 0 ]
    [ "$output" = "resource_exhausted" ]
}

@test "without the carried class the same empty log still says unclassified" {
    # The null arm: if this ever reads resource_exhausted, the test above is
    # measuring the fixture rather than the patch.
    : > "$LOG"
    run classify_with ""
    [ "$status" -eq 0 ]
    [ "$output" = "unclassified" ]
}

@test "load_fail carries no token at all (mapping would manufacture a verdict)" {
    run bash -c 'source "$1"; _bench_class_from_startup load_fail' _ "$HARNESS"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "a log that names a launch error is NOT clobbered by the carried class" {
    echo "error while handling argument: --bogus-flag" > "$LOG"
    run classify_with "resource_exhausted"
    [ "$status" -eq 0 ]
    [ "$output" = "launch_error" ]
}

@test "an architecture log still records unsupported_arch (bench_ctx keeps deriving)" {
    echo "llama_model_load: error loading model: unknown model architecture: gpt2" > "$LOG"
    run classify_with ""
    [ "$status" -eq 0 ]
    [ "$output" = "unsupported_arch" ]
}

@test "no producer anywhere writes classification=oom" {
    run grep -n 'classification=oom' "$SCRIPT"
    [ "$status" -ne 0 ]
    run grep -c 'classification=%s' "$SCRIPT"
    [ "$output" -eq 2 ]
}

@test "_fa_cause stays local to _bench_spawn, so bench_ctx cannot claim it" {
    # Arm (a) of the scope check: a later hoist of _fa_cause to a global would let
    # bench_ctx (@1740) stamp a cause it never observed.
    run grep -c 'local _fa_cause _fa_act' "$SCRIPT"
    [ "$output" -eq 1 ]
    run grep -cE '^_fa_cause=' "$SCRIPT"
    [ "$output" -eq 0 ]
    run bash -c 'awk "/^bench_ctx\(\) \{/,/^\}/" "$1" | grep -c _fa_cause || true' _ "$SCRIPT"
    [ "$output" -eq 0 ]
}

# ── the hole that "let re-derivation stand" assumed was closed ────────────────
# Passing nothing for load_fail is only sound if re-derivation can actually read
# the log.  It could not.  _startup_fail_type (:1267) matches
# "failed to load model|error loading model|failed to open|no such file", and NONE
# of those strings appeared in the classifier's three sets - so every
# load-failure row was recorded "unclassified (the launch output matched no known
# signature)" while the log named its cause.  That is the code-100k-Q8_0 case the
# comment at :1286 quotes, and the same discard this file already fixed for OOM,
# one arm over.
#
# Measured 2026-11-04 before the widening: 4 of the 7 _startup_fail_type
# alternatives classified as unclassified.  The widening maps them to
# launch_error, NOT to unsupported_arch, because unsupported_arch marks the
# registry meas_state=unacceptable at :3227 and an unloadable file is not an
# architecture verdict.  Whether it should retire the row is a separate judgement.

@test "every load-failure shape _startup_fail_type matches is re-derivable" {
    local shapes=(
        "llama_model_load: failed to load model from /m/x.gguf"
        "llama_model_load: error loading model: invalid magic"
        "failed to open /home/wayne/models/x.gguf"
        "no such file or directory"
        "check_tensor_dims: tensor blk.0.attn_q.weight has wrong shape; expected 8192, got 4096"
    )
    local s want
    for s in "${shapes[@]}"; do
        printf '%s\n' "$s" > "$LOG"
        # Through the WRITER with no carried token: this is the load_fail arm's
        # claim tested as the claim it is, not as a mapping.
        run classify_with ""
        [ "$status" -eq 0 ] || return 1
        # The class is pinned PER SHAPE, because 2026-11-09 moved one of them.  A tensor
        # the loader names and the file disagrees about is the FILE/LOADER disagreement,
        # not a launch error: _re_vintage in autotune-model.sh now matches
        # `check_tensor_dims|wrong shape`, because launch_error is MODEL-attributable and
        # two such launches would have archived 67 GiB of intact weights over a naming
        # difference (measured on GLM-5.3-Flash-REAP50-IQ3_M.gguf).  What this case exists
        # for is unchanged: every shape is RE-DERIVABLE to a named class, and none of them
        # becomes an architecture verdict.
        case "$s" in
            *check_tensor_dims*) want=loader_vintage ;;
            *)                   want=launch_error ;;
        esac
        [ "$output" = "$want" ] || { echo "not re-derivable: $s -> $output (want $want)"; return 1; }
        [ "$output" != "unsupported_arch" ] || { echo "architecture verdict from a load shape: $s"; return 1; }
    done
}

@test "an unloadable file never reaches the registry-marking token by accident" {
    echo "llama_model_load: failed to load model from /m/x.gguf" > "$LOG"
    run classify_with ""
    [ "$status" -eq 0 ]
    [ "$output" = "launch_error" ]
    [ "$output" != "unsupported_arch" ]
}

@test "an architecture verdict still outranks the load shape printed beside it" {
    echo "llama_model_load: error loading model: unknown model architecture: 'gpt-oss'" > "$LOG"
    run classify_with ""
    [ "$status" -eq 0 ]
    [ "$output" = "unsupported_arch" ]
}

@test "the widening did not eat the null arm" {
    printf '0.00.426.120 I srv  llama_server: initializing ...\n' > "$LOG"
    run classify_with ""
    [ "$status" -eq 0 ]
    [ "$output" = "unclassified" ]
}

# ── the headline must not outrun the class ───────────────────────────────────
# :3220 printed "the model cannot be loaded at any ctx" UNCONDITIONALLY while
# :3257, eighteen lines below, printed "not a verdict on the model" for every
# class except unsupported_arch.  So the report contradicted itself for a rejected
# launch, and it stopped being merely vague once the ledger learned to say
# resource_exhausted: a row that ran out of memory at its largest ctx was being
# introduced to the operator as a model that cannot be loaded at all.
# The run is still not certified either way; what changes is whether the sentence
# blames the MODEL, which only unsupported_arch has evidence for.

report_with() {
    bash -c '
        source "$1" || exit 90
        printf "classification=%s\nconfig=ctx=8192 batch=512\nlog=/tmp/x.log\n" "$2" > "/tmp/at-fail-$$"
        AUTOTUNE_SELFTEST=1 _autotune_failure_report
        rm -f "/tmp/at-fail-$$"
    ' _ "$HARNESS" "$1"
}

@test "a resource failure is not reported as a model that cannot be loaded" {
    run report_with resource_exhausted
    [ "$status" -eq 0 ]
    [[ "$output" == *"ran out of memory"* ]]
    [[ "$output" != *"cannot be loaded at any ctx"* ]]
    # and it must agree with the paragraph that disclaims a model verdict
    [[ "$output" == *"not a verdict on the model"* ]]
}

@test "an architecture verdict keeps the sentence it earned" {
    run report_with unsupported_arch
    [ "$status" -eq 0 ]
    [[ "$output" == *"cannot be loaded at any ctx"* ]]
}

@test "a rejected launch blames the invocation, not the model" {
    run report_with launch_error
    [ "$status" -eq 0 ]
    [[ "$output" == *"rejected its launch"* ]]
    [[ "$output" != *"cannot be loaded at any ctx"* ]]
}

# ------------------------------------------------------------------------------
# 2026-11-06 - the build-vintage gap.  Measured twice in one boot: build 148 could not
# read GLM-5.3's glm5-next.attention.indexer.kpool (missing key) or Qwen3.8-Flash-Next's
# qwen4exp.expert_count (wrong type).  Both texts contained "failed to load model", so the
# old classifier called them launch_error - MODEL-attributable - and three such boots would
# have archived a 67 GiB model that HEAD already supports.  These arms pin the token and the
# veto; the archive arm pins that the veto survives the strike count.
# ------------------------------------------------------------------------------

@test "a missing GGUF metadata key is loader_vintage, not launch_error" {
    printf '%s\n' \
        "0.00.304.129 I srv    load_model: loading model '/m/GLM.gguf'" \
        "0.00.350.553 E llama_model_load: error loading model: error loading model hyperparameters: key not found in model: glm5-next.attention.indexer.kpool" \
        "0.00.350.603 E srv    load_model: failed to load model, '/m/GLM.gguf'" > "$LOG"
    run classify_with ""
    [ "$status" -eq 0 ]
    [ "$output" = "loader_vintage" ]
}

@test "a GGUF metadata TYPE mismatch is loader_vintage too" {
    printf '%s\n' \
        "0.00.421.071 E llama_model_load: error loading model: error loading model hyperparameters: key qwen4exp.expert_count has wrong type arr but expected type u32" \
        "0.00.421.112 E srv    load_model: failed to load model, '/m/Coder.gguf'" > "$LOG"
    run classify_with ""
    [ "$status" -eq 0 ]
    [ "$output" = "loader_vintage" ]
}

@test "a TENSOR the loader names and the file lacks is loader_vintage too" {
    # Measured 2026-11-09 on GLM-5.3-Flash-REAP50-IQ3_M.gguf once its metadata parsed: the
    # file's converter wrote the hc_* tensors without the `.weight` suffix the loader appends,
    # so the load died at `check_tensor_dims` — which matched the launch_error arm and counted
    # as a fault of the MODEL.  Catches: a naming disagreement archiving intact weights.
    printf '%s\n' \
        "0.00.517.106 E llama_model_load: error loading model: check_tensor_dims: tensor 'blk.0.hc_attn_fn.weight' not found" \
        "0.00.517.143 E llama_model_load_from_file_impl: failed to load model" > "$LOG"
    run classify_with ""
    [ "$status" -eq 0 ]
    [ "$output" = "loader_vintage" ]
}

@test "an OOM log is still resource_exhausted, not swallowed by the vintage rule" {
    # The null arm for the new pattern: it must not read memory text as a build gap.
    printf '%s\n' "ggml_backend_cuda_buffer_type_alloc_buffer: allocating 4096 MiB: cuda error: out of memory" > "$LOG"
    run classify_with ""
    [ "$status" -eq 0 ]
    [ "$output" = "resource_exhausted" ]
}

@test "_last_fail_label maps loader_crash_unknown without collapsing it into OOM" {
    run bash -c '
        source "$1" || exit 90
        printf "0|0|load_fail\n" > "/tmp/at-metrics-$$"
        echo "load_fail=$(_last_fail_label)"
        printf "0|0|loader_crash_unknown\n" > "/tmp/at-metrics-$$"
        echo "crash=$(_last_fail_label)"
        printf "0|0|oom\n" > "/tmp/at-metrics-$$"
        echo "oom=$(_last_fail_label)"
        rm -f "/tmp/at-metrics-$$"
    ' _ "$HARNESS"
    [ "$status" -eq 0 ]
    [[ "$output" == *"load_fail=unsupported model"* ]]
    [[ "$output" == *"crash=unclassified crash"* ]]
    [[ "$output" == *"oom=OOM"* ]]
}

@test "probe_no_mmap stops immediately on loader_crash_unknown without descending or labeling OOM" {
    local calls_file="$BATS_TEST_TMPDIR/bench_calls"
    run bash -c '
        source "$1" || exit 90
        COMBOS=("1024:256" "512:128")
        START_CTX=8192
        MIN_CTX=4096
        MAX_CTX=32768
        ANY_OK=false
        MMAP_FALLBACK_USED=0
        CALLS_FILE="$2"
        fmt() { printf "%s" "$1"; }
        record_best() { :; }
        bench_ctx() {
            printf "%s\n" "$1:$2:$3" >> "$CALLS_FILE"
            printf "0|0|loader_crash_unknown\n" > "/tmp/at-metrics-$$"
            return 1
        }
        probe_no_mmap
        rm -f "/tmp/at-metrics-$$"
    ' _ "$HARNESS" "$calls_file"

    [ "$status" -eq 0 ]
    [[ "$output" == *"unclassified crash (stopping descent)"* ]]
    [[ "$output" != *"dropping to"* ]]
    [[ "$output" != *"OOM"* ]]
    [ "$(wc -l < "$calls_file")" -eq 1 ]
}

@test "main combo walk handles loader_crash_unknown without descending to half ctx" {
    run awk '/^    test_num=0; c=\$c0;/,/^done$/' "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *'if [[ "$_lft" == "loader_crash_unknown" ]]; then'* ]]
    [[ "$output" == *'_ABORT_COMBO_WALK=1'* ]]
}

@test "_launch_or_record_failure hands off live AT_WINDOW_S timeout instead of stopping as loader_crash_unknown" {
    run awk '/_launch_or_record_failure\(\)/,/^    if \[\[ \$hw -ge "\$AT_WINDOW_S" \]\]/' "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *'hw >= AT_WINDOW_S'* ]]
    [[ "$output" == *'kill -0 "${_BENCH_PID:-}"'* ]]
}
