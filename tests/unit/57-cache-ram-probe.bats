#!/usr/bin/env bats
# ==============================================================================
# Unit — the cache-ram probe's argv PREFLIGHT and its ORDER CONTROL
# ==============================================================================
# WHY THIS EXISTS: the probe's whole product is a comparison of two llama-server
# argv that differ by ONE flag, so two things must be true or the numbers mean
# nothing:
#
#   1. THE ARGV IS WHAT THE ARM CLAIMS.  On 2026-10-10 the first run of this
#      measurement silently launched a malformed ARM B: the caller passed the
#      whole "--cache-ram 0" as the *value*, so the argv printed
#      `--cache-ram --cache-ram 0` and llama.cpp read the second flag as the
#      first one's value and refused to load.  ARM A was clean, so the bug was in
#      one arm's construction, not the base builder — a class no human review
#      caught.  assert_argv() now REFUSES such an argv before a server starts.
#
#   2. THE RUN CAN TELL THE ARM FROM THE POSITION.  The two runs showed the COLD
#      decode (R1, which the cache cannot influence) drifting 45-65% across
#      POSITION while the same configuration varied only ~13% between runs.  A
#      single-pass A/B therefore cannot attribute a difference to the flag.  The
#      default order INTERLEAVES the arms so each occupies an early and a late
#      position; a non-interleaved order is refused unless explicitly allowed.
#
# The cases below exercise the SHIPPED functions, extracted verbatim from
# scripts/cache-ram-probe.sh (the 12-gpu-exclusivity idiom), so they are hermetic:
# no env.sh, no server, no GPU, no registry.
#
# FALSIFICATION (2026-10-10): against the pre-promotion harness these cases fail at
# setup — that harness had no parse_order/is_interleaved and defaulted to a
# NON-interleaved order, so the order-control cases could not even be extracted.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export REPO_ROOT
    PROBE="$REPO_ROOT/scripts/cache-ram-probe.sh"
    SANDBOX="$(mktemp -d)"
    export SANDBOX

    # Extract the pure functions VERBATIM so the cases exercise the shipped text,
    # not a paraphrase of it.
    {
        awk '/^is_interleaved\(\)/,/^}/' "$PROBE"
        awk '/^parse_order\(\)/,/^}/' "$PROBE"
        awk '/^assert_argv\(\)/,/^}/' "$PROBE"
    } > "$SANDBOX/fns.sh"
    grep -q 'parse_order' "$SANDBOX/fns.sh" || { echo "FAIL: parse_order not extracted from $PROBE"; return 1; }
    grep -q 'is_interleaved' "$SANDBOX/fns.sh" || { echo "FAIL: is_interleaved not extracted from $PROBE"; return 1; }
    grep -q 'assert_argv' "$SANDBOX/fns.sh" || { echo "FAIL: assert_argv not extracted from $PROBE"; return 1; }
    # ORDER_DEFAULT is a top-level scalar, not inside a function — carry it across.
    ORDER_DEFAULT="$(sed -n 's/^ORDER_DEFAULT="\(.*\)"$/\1/p' "$PROBE")"
    export ORDER_DEFAULT
    [[ -n "$ORDER_DEFAULT" ]] || { echo "FAIL: ORDER_DEFAULT not declared in $PROBE"; return 1; }

    # shellcheck source=/dev/null
    source "$SANDBOX/fns.sh"
}

teardown() {
    cd /
    rm -rf "$SANDBOX"
}

# ── the argv preflight ───────────────────────────────────────────────────────
@test "preflight: arm A's argv carries no --cache-ram and passes" {
    run assert_argv A 0 /stub/llama-server --model /m --ctx-size 24576
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"PREFLIGHT OK (A)"* ]]
    [[ "$output" == *"absent (0 occurrences"* ]]
}

@test "preflight: arm B's argv carries exactly one --cache-ram 0 and passes" {
    run assert_argv B 1 /stub/llama-server --model /m --cache-ram 0
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"PREFLIGHT OK (B)"* ]]
    [[ "$output" == *"exactly 1 time, value '0'"* ]]
}

@test "preflight: the merged flag+value is REFUSED (the 2026-10-10 arm-B bug)" {
    # This is the shape the first run actually launched: a flag and its value
    # merged into ONE argv element, printing as `--cache-ram --cache-ram 0`.
    run assert_argv B 1 /stub/llama-server --cache-ram "--cache-ram 0"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"contains a SPACE"* ]]
}

@test "preflight: a genuine duplicate flag is REFUSED" {
    # A bare flag followed by the intended one — llama.cpp takes the second flag
    # as the first one's value.  Counting occurrences catches what a "contains"
    # check cannot.
    run assert_argv B 1 /stub/llama-server --cache-ram --cache-ram 0
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"appears 2 time(s), expected 1"* ]]
}

@test "preflight: a non-integer value is REFUSED" {
    run assert_argv B 1 /stub/llama-server --cache-ram half
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"is not an integer"* ]]
}

# ── the order control ────────────────────────────────────────────────────────
@test "order: the DEFAULT interleaves the arms (even, alternating, both present)" {
    run parse_order "" 0
    [[ "$status" -eq 0 ]]
    local seq
    seq="$(printf '%s' "$output" | tr -d '\n')"
    (( ${#seq} >= 4 ))            # even n so each arm gets a late AND an early slot
    (( ${#seq} % 2 == 0 ))
    [[ "$seq" == *A* && "$seq" == *B* ]]
    # ...and it alternates, which is what separates arm from position.
    run is_interleaved "$seq"
    [[ "$status" -eq 0 ]]
}

@test "order: a non-interleaved order is REFUSED without the explicit override" {
    run parse_order AB 0
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"REFUSED"* ]]
    [[ "$output" == *"not interleaved"* ]]
    # And it emits NO arms, so a caller cannot run a sequence the tool rejected.
    [[ "$output" != *$'A\nB'* ]]
}

@test "order: the override allows a non-interleaved run AND warns it is confounded" {
    run parse_order AB 1
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"WARNING"* ]]
    [[ "$output" == *"CONFOUNDED"* ]]
    [[ "$(printf '%s' "$output" | tr -d '\n')" == *AB* ]]
}

@test "order: a malformed sequence is REFUSED" {
    run parse_order AX 0
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"only A and B"* ]]
}

@test "order: the tool's own default is an interleaved sequence" {
    run is_interleaved "$ORDER_DEFAULT"
    [[ "$status" -eq 0 ]]
}

# ── the measurement shape ────────────────────────────────────────────────────
@test "measurement: each arm runs cold -> switch -> reuse (the cache signal needs the switch)" {
    # The reuse measurement only means something because R2 introduces a DIFFERENT
    # prefix that evicts the slot's KV; without it R3 is a back-to-back repeat,
    # which the recorded measurement says is UNAFFECTED by --cache-ram, so the tool
    # would report a false null.  Pin the three requests, in order, once per arm.
    local body
    body="$(sed -n '/^run_arm()/,/^}/p' "$PROBE")"
    [[ "$body" == *'measure "$WORKDIR/p1.json" "$out_dir/r1.json"'* ]] || { echo "no cold (R1) request"; return 1; }
    [[ "$body" == *'measure "$WORKDIR/p2.json" "$out_dir/r2.json"'* ]] || { echo "no switch (R2) request"; return 1; }
    [[ "$body" == *'measure "$WORKDIR/p1.json" "$out_dir/r3.json"'* ]] || { echo "no reuse (R3) request"; return 1; }
}
