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
    extract_fns "_bench_log_tail __autotune_classify_failure _bench_class_from_startup _bench_record_failure" > "$HARNESS"
    # A harness that failed to extract would make every arm below vacuous.
    grep -q '^_bench_record_failure() {' "$HARNESS"
    grep -q '^_bench_class_from_startup() {' "$HARNESS"
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
    local s
    for s in "${shapes[@]}"; do
        printf '%s\n' "$s" > "$LOG"
        # Through the WRITER with no carried token: this is the load_fail arm's
        # claim tested as the claim it is, not as a mapping.
        run classify_with ""
        [ "$status" -eq 0 ] || return 1
        [ "$output" = "launch_error" ] || { echo "not re-derivable: $s -> $output"; return 1; }
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
