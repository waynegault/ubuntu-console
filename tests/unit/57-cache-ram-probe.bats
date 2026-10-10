#!/usr/bin/env bats
# ==============================================================================
# Unit — the cache-ram probe's argv PREFLIGHT and ORDER CONTROL, and the
# probe watcher's VRAM GATE
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
#   3. THE WATCHER MUST NOT LAUNCH INTO AN OCCUPIED CARD — AND MUST BE ABLE TO
#      LAUNCH AT ALL.  The probe watcher's gate 4 was wrong twice on 2026-10-10.
#      v3 read nvidia-smi's VRAM and could never OPEN on a multi-GPU box, because
#      the query prints ONE LINE PER GPU and a bare numeric test on a multi-line
#      value never matches — fail-safe, but unusable.  The shapes that matter are
#      both directions: an unreadable card must read BUSY (fail closed), and the
#      reading must be the MOST-used card, not the first.  The cases at the end
#      pin those, with the exclusive bound and a free-card control.
#
# The cases below exercise the SHIPPED functions, extracted verbatim from
# scripts/cache-ram-probe.sh and scripts/cache-ram-probe-watch.sh (the
# 12-gpu-exclusivity idiom), so they are hermetic: no env.sh, no server, no GPU,
# no registry.
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
        awk '/^warn\(\)/,/^}/' "$PROBE"
        awk '/^is_interleaved\(\)/,/^}/' "$PROBE"
        awk '/^parse_order\(\)/,/^}/' "$PROBE"
        awk '/^assert_argv\(\)/,/^}/' "$PROBE"
    } > "$SANDBOX/fns.sh"
    grep -q 'warn' "$SANDBOX/fns.sh" || { echo "FAIL: warn not extracted from $PROBE"; return 1; }
    grep -q 'parse_order' "$SANDBOX/fns.sh" || { echo "FAIL: parse_order not extracted from $PROBE"; return 1; }
    grep -q 'is_interleaved' "$SANDBOX/fns.sh" || { echo "FAIL: is_interleaved not extracted from $PROBE"; return 1; }
    grep -q 'assert_argv' "$SANDBOX/fns.sh" || { echo "FAIL: assert_argv not extracted from $PROBE"; return 1; }
    # ORDER_DEFAULT is a top-level scalar, not inside a function — carry it across.
    ORDER_DEFAULT="$(sed -n 's/^ORDER_DEFAULT="\(.*\)"$/\1/p' "$PROBE")"
    export ORDER_DEFAULT
    [[ -n "$ORDER_DEFAULT" ]] || { echo "FAIL: ORDER_DEFAULT not declared in $PROBE"; return 1; }

    # gate_ok lives in the WATCHER, not the probe — extract it verbatim too and
    # carry its three top-level bounds across the same way (they are scalars
    # beside the function, so extraction alone leaves them undefined).
    WATCH="$REPO_ROOT/scripts/cache-ram-probe-watch.sh"
    export WATCH
    awk '/^gate_ok\(\)/,/^}/' "$WATCH" >> "$SANDBOX/fns.sh"
    grep -q 'gate_ok' "$SANDBOX/fns.sh" || { echo "FAIL: gate_ok not extracted from $WATCH"; return 1; }
    LOAD_MAX="$(sed -n 's/^LOAD_MAX=\([0-9][0-9]*\).*$/\1/p' "$WATCH")"
    LEDGER_MAX="$(sed -n 's/^LEDGER_MAX=\([0-9][0-9]*\).*$/\1/p' "$WATCH")"
    VRAM_MAX="$(sed -n 's/^VRAM_MAX=\([0-9][0-9]*\).*$/\1/p' "$WATCH")"
    export LOAD_MAX LEDGER_MAX VRAM_MAX
    [[ -n "$LOAD_MAX" && -n "$LEDGER_MAX" && -n "$VRAM_MAX" ]] \
        || { echo "FAIL: a gate bound is not declared in $WATCH"; return 1; }
    # Gate 2 runs "$HEAVY" --status.  Point it at a stub that reads free, so the
    # cases at the end vary ONLY gate 4.
    mkdir -p "$SANDBOX/bin"
    printf '#!/usr/bin/env bash\nprintf "heavy-job: free (last holder: none)\\n"\n' \
        > "$SANDBOX/bin/heavy-job"
    chmod +x "$SANDBOX/bin/heavy-job"
    export HEAVY="$SANDBOX/bin/heavy-job"

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

# ── the probe watcher's VRAM gate (gate_ok, scripts/cache-ram-probe-watch.sh) ─
#
# Gate 4 decides whether the probe may launch at all.  Every case also asserts
# gates 1-3 were OPEN (load_ok=1, hj_ok=1, cyc_ok=1), so a non-zero status is
# gate 4's doing and not a stubbed input's — and each states the wrong outcome it
# catches, so it can disagree with the code rather than confirm it.

# gate_stubs — isolate gate_ok's remaining inputs.  The cut and cat stubs
# intercept ONLY the /proc/loadavg read and the cycle-ledger glob, and delegate
# everything else to the real command, so no other case in this file is affected.
gate_stubs() {
    cut() {
        # The read is `cut -d' ' -f1 /proc/loadavg`: match on the FILE, not on a
        # positional index — `-d' '` is ONE word ("-d "), so the path is argv[3].
        local _a
        for _a in "$@"; do
            if [[ "$_a" == "/proc/loadavg" ]]; then
                printf '0.10\n'
                return 0
            fi
        done
        command cut "$@"
    }
    cat() {
        case "${1:-}" in
            /dev/shm/autotune-cuda-cycles-*)
                return 0 ;;                 # gate 3: no ledger content this boot
            *)
                command cat "$@" ;;
        esac
    }
}

@test "vram gate: a card that cannot be read FAILS CLOSED" {
    # Catches: gate 4 OPENING when nvidia-smi dies (no output, rc 1) — the one
    # direction that must never happen for a GPU probe, and the shape that
    # launched into a full card before gate 4 existed.
    gate_stubs
    nvidia-smi() { return 1; }
    run gate_ok
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"load1=0.10 load_ok=1"* && "$output" == *"hj_ok=1"* && "$output" == *"cyc_ok=1"* ]]
    [[ "$output" == *"vram=MiB vram_ok=0"* ]]
}

@test "vram gate: rc 0 with EMPTY output still FAILS CLOSED" {
    # Catches: the same hole when the CLI succeeds but prints nothing — an exit
    # status is not a reading.
    gate_stubs
    nvidia-smi() { :; }
    run gate_ok
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"load1=0.10 load_ok=1"* && "$output" == *"hj_ok=1"* && "$output" == *"cyc_ok=1"* ]]
    [[ "$output" == *"vram=MiB vram_ok=0"* ]]
}

@test "vram gate: a multi-GPU reading with both cards under the bound OPENS the gate" {
    # Catches the v3 regression: nvidia-smi prints ONE LINE PER GPU, and v3's bare
    # numeric test on that multi-line value never matched, so the gate could NEVER
    # open on a multi-GPU box.  Both cards are free, so the gate must OPEN.
    gate_stubs
    nvidia-smi() { printf '100\n50\n'; }
    run gate_ok
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"load1=0.10 load_ok=1"* && "$output" == *"hj_ok=1"* && "$output" == *"cyc_ok=1"* ]]
    [[ "$output" == *"vram=100MiB vram_ok=1"* ]]
}

@test "vram gate: a multi-GPU reading with ONE card over the bound is BUSY" {
    # Catches: taking the FIRST line instead of the MOST-used card — the gate
    # would open on the free card while the second is nearly full, which is the
    # launch-into-a-full-card failure again, one card over.
    gate_stubs
    nvidia-smi() { printf '50\n9999\n'; }
    run gate_ok
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"load1=0.10 load_ok=1"* && "$output" == *"hj_ok=1"* && "$output" == *"cyc_ok=1"* ]]
    [[ "$output" == *"vram=9999MiB vram_ok=0"* ]]
}

@test "vram gate: the bound is EXCLUSIVE (exactly VRAM_MAX reads BUSY)" {
    # Catches: an off-by-one that admits a card sitting exactly on the bound,
    # which the gate's own comment defines as occupied.
    gate_stubs
    nvidia-smi() { printf '%s\n' "$VRAM_MAX"; }
    run gate_ok
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"load1=0.10 load_ok=1"* && "$output" == *"hj_ok=1"* && "$output" == *"cyc_ok=1"* ]]
    [[ "$output" == *"vram=${VRAM_MAX}MiB vram_ok=0"* ]]
}

@test "vram gate: control — a genuinely free card OPENS the gate" {
    # The control: without it, a gate that simply ALWAYS said BUSY would pass
    # every fail-closed case above, and the two fail-closed cases would prove
    # nothing about the reading.
    gate_stubs
    nvidia-smi() { printf '100\n'; }
    run gate_ok
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"load1=0.10 load_ok=1"* && "$output" == *"hj_ok=1"* && "$output" == *"cyc_ok=1"* ]]
    [[ "$output" == *"vram=100MiB vram_ok=1"* ]]
}
