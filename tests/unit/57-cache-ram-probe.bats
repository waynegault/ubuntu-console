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
    # gate 4's READING is the shared helper now (bin/_tac-bin-lib.sh v6): the shipped
    # gate_ok CALLS it, so the definition has to travel with the extraction — and it is
    # extracted from the shipped library, not paraphrased, so these cases still pin the
    # code that runs.  The `nvidia-smi` function each case defines intercepts its query.
    BIN_LIB="$REPO_ROOT/bin/_tac-bin-lib.sh"
    export BIN_LIB
    awk '/^_tac_gpu_used_mib\(\)/,/^}/' "$BIN_LIB" >> "$SANDBOX/fns.sh"
    grep -q '_tac_gpu_used_mib' "$SANDBOX/fns.sh" \
        || { echo "FAIL: _tac_gpu_used_mib not extracted from $BIN_LIB"; return 1; }
    LOAD_MAX="$(sed -n 's/^LOAD_MAX=\([0-9][0-9]*\).*$/\1/p' "$WATCH")"
    LEDGER_MAX="$(sed -n 's/^LEDGER_MAX=\([0-9][0-9]*\).*$/\1/p' "$WATCH")"
    VRAM_MAX="$(sed -n 's/^VRAM_MAX=\([0-9][0-9]*\).*$/\1/p' "$WATCH")"
    export LOAD_MAX LEDGER_MAX VRAM_MAX
    [[ -n "$LOAD_MAX" && -n "$LEDGER_MAX" && -n "$VRAM_MAX" ]] \
        || { echo "FAIL: a gate bound is not declared in $WATCH"; return 1; }
    # Gate 2 runs "$HEAVY" --status.  Point it at a stub that reads free, so the
    # cases at the end vary ONLY gate 4.  The two extra stubs drive gate 2's OWN
    # failure branch: one exits non-zero, one exits 0 with an unparseable line.
    mkdir -p "$SANDBOX/bin"
    printf '#!/usr/bin/env bash\nprintf "heavy-job: free (last holder: none)\\n"\n' \
        > "$SANDBOX/bin/heavy-job"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$SANDBOX/bin/heavy-bad"
    printf '%s\n' '#!/usr/bin/env bash' 'printf "heavy-job: maybe\n"' > "$SANDBOX/bin/heavy-garbage"
    chmod +x "$SANDBOX/bin/heavy-job" "$SANDBOX/bin/heavy-bad" "$SANDBOX/bin/heavy-garbage"
    export HEAVY="$SANDBOX/bin/heavy-job"
    # The interpreter the scratch layouts serve as their own .venv python.
    W_PY="$REPO_ROOT/.venv/bin/python3"
    [[ -x "$W_PY" ]] || W_PY="$(command -v python3)"
    export W_PY

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

# ── the watcher's CALLER: the wait loop, its abort, and the heavy-job launch ──
#
# gate_ok is covered above; this covers what the shipped script DOES with it.
# The bug that motivated it: the first watcher had no abort on exhaustion and
# LAUNCHED the probe into a 3.6 GiB card — the abort is the only thing standing
# between this script and a repeat.
#
# HERMETIC: the script resolves HEAVY="$REPO/bin/heavy-job" from its OWN location,
# so no env var can redirect it and the script is NOT edited.  Instead the
# UNMODIFIED shipped text runs from a scratch repo layout (<scratch>/scripts/…)
# whose <scratch>/bin/heavy-job is a recording stub, and the four gate inputs are
# controlled on PATH: gate 4 via an nvidia-smi stub whose output the case picks,
# gate 1 via a cut stub (this box is BUSY — real /proc/loadavg would close gate 1
# and the open-gate control would pass only on a quiet box), gate 3 via a cat stub
# (/dev/shm ledger files exist here and are host state).  No GPU, no lock, no
# /dev/shm, and the stub never execs its argv, so the real probe cannot run.

# watch_layout — build the scratch repo layout and the controlling stubs.
# Sets W_SCRIPT (the copy to run), W_OUT, W_STUBBIN, W_LAUNCHES.
watch_layout() {
    W_ROOT="$SANDBOX/watch-root"
    W_OUT="$SANDBOX/watch-out"
    W_STUBBIN="$SANDBOX/watch-stubbin"
    W_LAUNCHES="$SANDBOX/watch-launches.log"
    mkdir -p "$W_ROOT/scripts" "$W_ROOT/bin" "$W_OUT" "$W_STUBBIN"
    # The shipped script, byte for byte.  $SELF_DIR is its own directory, so it
    # resolves REPO to $W_ROOT and HEAVY to $W_ROOT/bin/heavy-job.  The shared library
    # it sources (bin/_tac-bin-lib.sh — gate 4's reading) must travel with it, or the
    # source fails and gate 4 reads empty (fail-closed, so the open-gate case would
    # fail rather than the gate silently opening).
    cp "$WATCH" "$W_ROOT/scripts/cache-ram-probe-watch.sh"
    cp "$REPO_ROOT/bin/_tac-bin-lib.sh" "$W_ROOT/bin/_tac-bin-lib.sh"
    W_SCRIPT="$W_ROOT/scripts/cache-ram-probe-watch.sh"
    export W_SCRIPT
    : > "$W_LAUNCHES"
    export W_LAUNCHES
    # --status is gate 2's probe: prints free, records NOTHING.  Every other
    # invocation IS the launch: recorded, and never exec'd.
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'if [[ "${1:-}" == "--status" ]]; then printf "heavy-job: free (last holder: none)\n"; exit 0; fi' \
        'printf "%s\n" "$*" >> "${W_LAUNCHES:?}"' \
        'printf "heavy-job: free (last holder: none)\n"' \
        > "$W_ROOT/bin/heavy-job"
    chmod +x "$W_ROOT/bin/heavy-job"
    printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "${W_VRAM_OUT:-}"' > "$W_STUBBIN/nvidia-smi"
    printf '%s\n' '#!/usr/bin/env bash' 'printf "0.10\n"' > "$W_STUBBIN/cut"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$W_STUBBIN/cat"
    chmod +x "$W_STUBBIN/nvidia-smi" "$W_STUBBIN/cut" "$W_STUBBIN/cat"
}

# watch_run <nvidia-smi-output-MiB> — run the copy with a 1s poll and a 0s budget.
watch_run() {
    run env PATH="$W_STUBBIN:$PATH" W_VRAM_OUT="$1" W_LAUNCHES="$W_LAUNCHES" \
        bash "$W_SCRIPT" --poll 1 --max-wait 0 --out "$W_OUT"
}

@test "watch caller: the wait loop ABORTS when the window never opens (busy card)" {
    # Catches: a fall-through that LAUNCHES the probe when the window never opened
    # — the first watcher's bug, which put the probe onto a 3.6 GiB card.  3293 MiB
    # is over VRAM_MAX, so gate 4 cannot open on any iteration.
    watch_layout
    watch_run 3293
    [[ "$status" -eq 1 ]]
    local wlog
    wlog="$(ls "$W_OUT"/watch-*.log)"
    grep -q 'waiting (' "$wlog"                        # the wait actually happened...
    grep -q 'reached without a quiet window' "$wlog"   # ...and exhaustion aborted
    [[ ! -s "$W_LAUNCHES" ]]                           # heavy-job was never launched
    [[ -z "$(ls "$W_OUT"/probe-*.log 2>/dev/null)" ]]  # no probe transcript either
}

@test "watch caller: an open window LAUNCHES the probe once, through heavy-job" {
    # Catches: a gate that can never open (no launch at all) AND a launch that
    # bypasses the lock — the probe must be launched via heavy-job, carrying the
    # probe's own argv, and the transcript must open.
    watch_layout
    watch_run 100
    [[ "$status" -eq 0 ]]
    [[ "$(wc -l < "$W_LAUNCHES")" -eq 1 ]]
    grep -q -- 'bash -c' "$W_LAUNCHES"
    grep -q -- '--row 21' "$W_LAUNCHES"
    grep -q -- "--out $W_OUT" "$W_LAUNCHES"
    grep -q -- 'cache-ram-probe.sh' "$W_LAUNCHES"
    [[ -n "$(ls "$W_OUT"/probe-*.log 2>/dev/null)" ]]
}

# ── gate 2's own failure branch (the warn fallback, v3 of the watcher) ────────
#
# PREFIX CAVEAT: gate_ok is extracted from cache-ram-probe-WATCH.sh, but the `warn`
# it calls comes from the PROBE's extraction earlier in fns.sh, so the emitted line
# reads "cache-ram-probe: …" where the watcher's own helper would say
# "cache-ram-probe-watch: …".  The two helpers share the message body, so these
# cases assert the CONTENT (the prefix is the only difference and asserting it
# would pin the harness rather than the behaviour).

@test "vram gate: an unreadable heavy-job --status FAILS CLOSED and says why" {
    # Catches: gate 2 OPENING when the lock cannot be read (the CLI exited non-zero)
    # — hj_ok must stay 0, the box must be treated as NOT free, and the reason must
    # be emitted: a silent version of this is how a run starts beside another job.
    gate_stubs
    nvidia-smi() { printf '100\n'; }
    export HEAVY="$SANDBOX/bin/heavy-bad"
    run gate_ok
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"hj_ok=0"* ]]
    [[ "$output" == *"WARNING: heavy-job --status rc=1"* ]]
    [[ "$output" == *"treating the box as NOT free"* ]]
    [[ "$output" == *"vram=100MiB vram_ok=1"* ]]   # gate 4 was fine; gate 2 closed it
}

@test "vram gate: an unparseable heavy-job --status line FAILS CLOSED" {
    # Catches: a garbage status line (rc 0) matching the "heavy-job: free" PREFIX
    # test — the prefix match must not fire, so hj_ok stays 0 with no warn (the warn
    # is for an unreadable exit, not a readable-but-wrong line).
    gate_stubs
    nvidia-smi() { printf '100\n'; }
    export HEAVY="$SANDBOX/bin/heavy-garbage"
    run gate_ok
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"hj_ok=0"* ]]
    [[ "$output" == *"vram=100MiB vram_ok=1"* ]]
}

# ── the watcher's post-launch RESULT READ-BACK ───────────────────────────────
#
# The launch path was covered above with no result file, so the run ended in the
# "wrote nothing" branch.  These two cases put a result JSON in the out dir and
# drive the read-back itself: the reader that prints row/order/drift and the
# per-position lines, and the missing-interpreter guard beside it.

# probe_result_fixture <path> — a minimal well-formed result, one complete position
# (which the reader formats) and one incomplete (which it labels INCOMPLETE).
probe_result_fixture() {
    printf '%s' \
        '{"row":21,"order":"BABA","interleaved":true,"drift_pct":12.5,' \
        '"drift_warn_pct":25,"positions":[' \
        '{"pos":1,"arm":"A","r1":{"server_decode_tps":20.5,"ttft_ms":900,"server_prompt_ms":100},' \
        '"r3":{"server_decode_tps":21.0,"ttft_ms":150,"server_prompt_ms":20}},' \
        '{"pos":2,"arm":"B","r1":null,"r3":null}],' \
        '"delta":{"decode_cold":1.0,"decode_reuse":0.5,"ttft_reuse":-10}}' \
        > "$1"
}

@test "watch caller: the post-launch read-back parses the probe's result JSON" {
    # Catches: the read-back being skipped or mis-wired — the watcher would report a
    # run whose figures it never read, or claim "the probe wrote nothing" while a
    # result file sits in the out dir.
    watch_layout
    probe_result_fixture "$W_OUT/result-STUB.json"
    # $PY is "$REPO/.venv/bin/python": give the scratch layout one that really runs.
    mkdir -p "$W_ROOT/.venv/bin"
    printf '%s\n' '#!/usr/bin/env bash' "exec $W_PY \"\$@\"" > "$W_ROOT/.venv/bin/python"
    chmod +x "$W_ROOT/.venv/bin/python"
    watch_run 100
    [[ "$status" -eq 0 ]]
    local wlog
    wlog="$(ls "$W_OUT"/watch-*.log)"
    grep -q 'result read back from' "$wlog"
    grep -q 'row=21 order=BABA interleaved=True drift_pct=12.5 bound=25' "$wlog"
    grep -q 'pos1 ARM A: decode_cold=20.50 decode_reuse=21.00 ttft_reuse=150 ms' "$wlog"
    grep -q 'pos2 ARM B: INCOMPLETE' "$wlog"
    grep -q 'delta={' "$wlog"
    [[ "$output" != *"wrote nothing"* ]]
}

@test "watch caller: a missing .venv python makes the read-back FAIL LOUDLY" {
    # Catches: a missing interpreter silently ending the run — the guard must log
    # FATAL and exit 1 rather than report a clean finish over an unread result.
    watch_layout
    probe_result_fixture "$W_OUT/result-STUB.json"
    # no $W_ROOT/.venv/bin/python in this layout
    watch_run 100
    [[ "$status" -eq 1 ]]
    local wlog
    wlog="$(ls "$W_OUT"/watch-*.log)"
    grep -q 'FATAL: .*missing' "$wlog"
    grep -q 'install the venv' "$wlog"
    grep -q 'watcher done (rc=1)' "$wlog"
    [[ "$output" != *"wrote nothing"* ]]
}

# ── the PROBE's post-suspend free-VRAM wait (v4: the SHARED helper) ──────────
#
# The watcher gates the LAUNCH; this is the probe's own wait AFTER it has taken the
# suspend hold — and its hand-rolled predecessor ENDED after 45 polls and started the
# measurement on whatever free VRAM it found.  That is the fall-through that launched a
# run onto a card holding 3.6 GiB (2026-10-11).  Since v4 the wait is the shared
# `_tac_gpu_wait_used_below` (bin/_tac-bin-lib.sh); the helper's own cases — the
# foreign-holder test, exhaustion, the unreadable card and the multi-GPU reading — live
# in tests/unit/08-autotune-workload.bats.  What is pinned HERE is the PROBE's use of
# it: the bound is 800 MiB USED, and a non-zero return must refuse the run.
#
# HERMETIC: the shipped cache-ram-probe.sh and the shipped bin/_tac-bin-lib.sh run
# UNMODIFIED from a scratch repo layout; only their collaborators are supplied — a
# stub env.sh (the three names the probe reads from it), a sandbox registry with one
# row, a dummy model file, and PATH stubs.  nvidia-smi decides the reading (the
# case picks it), systemctl is a no-op, and sleep is a no-op so the 45 x 2s wait does
# not cost 90 s.  The server binary the probe would spawn is a RECORDER that exits
# at once, so "a server was started" is observable and no real server, GPU, lock,
# /dev/shm ledger or registry is touched.

# probe_layout — build the scratch repo layout.  Sets P_SCRIPT, P_OUT, P_REGISTRY,
# P_MODELS, P_SERVER_LOG, P_SUSPEND, P_STUB, P_WRAPPER (the served python path).
probe_layout() {
    P_ROOT="$SANDBOX/probe-root"
    P_OUT="$SANDBOX/probe-out"
    P_STUB="$SANDBOX/probe-stubbin"
    P_TMP="$SANDBOX/probe-tmp"
    P_LOGS="$SANDBOX/probe-logs"
    P_SCRIPT="$P_ROOT/scripts/cache-ram-probe.sh"
    P_REGISTRY="$P_ROOT/models.conf"
    P_MODELS="$P_ROOT/models"
    P_SERVER_LOG="$P_LOGS/server-launches.log"
    P_SERVER_BIN="$P_ROOT/bin/llama-server-recorder"
    P_SUSPEND="$P_ROOT/llama-watchdog-cuda.suspend"
    P_WRAPPER="$P_ROOT/.venv/bin/python"
    mkdir -p "$P_ROOT/scripts" "$P_ROOT/bin" "$P_MODELS" "$P_OUT" "$P_STUB" "$P_TMP" "$P_LOGS"
    # The shipped script and the shipped suspend/free-VRAM library, byte for byte.
    cp "$PROBE" "$P_SCRIPT"
    cp "$REPO_ROOT/bin/_tac-bin-lib.sh" "$P_ROOT/bin/_tac-bin-lib.sh"
    : > "$P_SERVER_LOG"
    touch "$P_MODELS/dummy.gguf"
    # A 39-field row (the probe indexes up to F[38]).  Only the columns it reads
    # carry values: name, file, quant_cache, ngl, ctx, threads, batch, ubatch,
    # parallel, flash_attn — the rest stay empty so no spec args are appended.
    {
        printf '%s' '21|probe-test|dummy.gguf||q8_0/q8_0||99|4096|8|2048|512|1||||on'
        local _pad
        for (( _pad = 16; _pad < 39; _pad++ )); do printf '%s' '|'; done
        printf '\n'
    } > "$P_REGISTRY"
    # nvidia-smi prints whatever W_GPU holds — a USED reading in MiB, one line per card
    # (empty by default => nothing readable at all, which must fail CLOSED).
    printf '%s\n' '#!/usr/bin/env bash' '[[ -n "${W_GPU:-}" ]] && printf "%s\n" "$W_GPU"' \
        'exit 0' > "$P_STUB/nvidia-smi"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$P_STUB/systemctl"
    # swallow-free no-op: the wait's 45 x 2 s must not cost 90 s of test time.
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$P_STUB/sleep"
    chmod +x "$P_STUB/nvidia-smi" "$P_STUB/systemctl" "$P_STUB/sleep"
    # The server the probe would spawn: records its argv, exits at once.
    printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "${W_SERVER_LOG:?}"' \
        'exit 0' > "$P_SERVER_BIN"
    chmod +x "$P_SERVER_BIN"
    # A stub env.sh: only the three names the probe reads from it.
    printf '%s\n' '#!/usr/bin/env bash' \
        'LLM_REGISTRY="$PROBE_REGISTRY"' \
        'LLAMA_MODEL_DIR="$PROBE_MODELS"' \
        "TAC_PYTHON='$W_PY'" > "$P_ROOT/env.sh"
}

# probe_run <nvidia-smi USED reading in MiB, e.g. "3900" or "" for unreadable>
probe_run() {
    run env PATH="$P_STUB:$PATH" TMPDIR="$P_TMP" \
        W_GPU="$1" W_SERVER_LOG="$P_SERVER_LOG" \
        PROBE_REGISTRY="$P_REGISTRY" PROBE_MODELS="$P_MODELS" \
        LLAMA_SERVER_BIN="$P_SERVER_BIN" \
        LLAMA_WATCHDOG_CUDA_SUSPEND_FILE="$P_SUSPEND" \
        LLAMA_CUDA_LANE_UNIT=probe-test-lane.service \
        bash "$P_SCRIPT" --row 21 --port 18099 --out "$P_OUT"
}

@test "probe free-VRAM wait: a card that never frees ABORTS before starting a server" {
    # Catches: the probe PROCEEDING when its wait cannot get a free card.  The
    # hand-rolled predecessor ended the wait after 45 polls and started the measurement
    # on whatever free VRAM it found — the shape that launched a run onto a card holding
    # 3.6 GiB.  3900 MiB used is never under the 800 MiB bound.
    probe_layout
    probe_run "3900"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"card did NOT free within 90s"* ]]
    [[ "$output" == *"last: 3900 MiB used, need < 800"* ]]
    [[ "$output" == *"refusing to start"* ]]
    [[ ! -s "$P_SERVER_LOG" ]]                        # no server was ever started
    [[ "$output" != *"arm sequence this run"* ]]      # never reached the arm loop
    [[ -z "$(ls "$P_OUT"/result-*.json 2>/dev/null)" ]]
}

@test "probe free-VRAM wait: an unreadable reading ABORTS too (fail closed)" {
    # Catches: an empty nvidia-smi reading being treated as "free enough" — the old
    # `|| break` left the loop at once with an unknown card and started the run.  The
    # shared helper fails CLOSED on "cannot tell"; this pins that the probe turns that
    # non-zero return into a refusal.
    probe_layout
    probe_run ""
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"cannot read used VRAM"* ]]
    [[ "$output" == *"<empty>"* ]]
    [[ "$output" == *"refusing to start"* ]]
    [[ ! -s "$P_SERVER_LOG" ]]
    [[ "$output" != *"arm sequence this run"* ]]
}

# ── _free_mib (bin/_tac-bin-lib.sh) — the reading the wait above consumes ─────
#
# The wait's fail-closed branch depends on THIS contract: an nvidia-smi that cannot
# be read must yield EMPTY, not 0 and not a stale number — a 0 would read as "no
# card free" (refuse) but a stale/normal number would read as "free" and let the
# probe start.  tactical-console-fast.bats asserts _free_mib is DEFINED in one
# place; nothing asserted what it RETURNS on failure.

@test "free VRAM: _free_mib yields EMPTY when nvidia-smi cannot be read" {
    # Catches: a fallback in the parser (`|| echo 0`, a cached last value), which
    # would make the wait's "cannot tell" indistinguishable from a real reading.
    mkdir -p "$SANDBOX/fm-bad" "$SANDBOX/fm-ok"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$SANDBOX/fm-bad/nvidia-smi"
    printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "4000, 3900"' > "$SANDBOX/fm-ok/nvidia-smi"
    chmod +x "$SANDBOX/fm-bad/nvidia-smi" "$SANDBOX/fm-ok/nvidia-smi"
    local lib="$REPO_ROOT/bin/_tac-bin-lib.sh"
    run env PATH="$SANDBOX/fm-bad:$PATH" bash -c "source '$lib'; _free_mib"
    [[ -z "$output" ]]                 # EMPTY — the contract the wait branches on
    # Control: a normal reading still parses to total - used, so the case above is
    # not passing because the helper is broken outright.
    run env PATH="$SANDBOX/fm-ok:$PATH" bash -c "source '$lib'; _free_mib"
    [[ "$output" == "100" ]]
}

# ── the probe's SUSPEND contract (the interleaving with systemd) ──────────────
#
# The helper's own protocol is covered by tests/unit/08-autotune-workload.bats;
# what nothing covered is the PROBE's use of it.  Asserted here as a CONTRACT —
# the call, and the abort on its failure — with the helper stubbed in the scratch
# lib (the shipped probe text is untouched).  That is hermetic; the real
# interleaving with systemd is a manual check (see the module's `up` path).

@test "probe: a suspend hold that cannot be acquired ABORTS before anything starts" {
    # Catches: the probe starting a server WITHOUT the watchdog held off — the lane
    # would be restarted underneath the measurement.
    probe_layout
    printf '%s\n' '_tac_suspend_acquire() { return 1; }' >> "$P_ROOT/bin/_tac-bin-lib.sh"
    probe_run "3900"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"could not acquire the CUDA suspend hold"* ]]
    [[ ! -s "$P_SERVER_LOG" ]]
    [[ "$output" != *"card did NOT free"* ]]   # stopped AT the gate, not later
}

@test "probe: control — an acquired hold lets the run reach the VRAM wait" {
    # The other half: without it, a probe that aborted unconditionally would pass the
    # case above.  The real helper is used here (sandbox suspend file), so this proves
    # the abort above came from the stub and not from the harness.
    probe_layout
    probe_run "3900"
    [[ "$status" -eq 1 ]]
    [[ "$output" != *"could not acquire the CUDA suspend hold"* ]]
    [[ "$output" == *"card did NOT free"* ]]
}

# ── the re-bench RUNNER (scripts/rebench-rows.sh) ────────────────────────────
#
# WHY: on 2026-10-12 the re-bench was driven from a hand-rolled wrapper that failed
# three ways, and the runner exists to make each impossible: (1) it HELD the CUDA
# suspend and then ran a probe that acquires its OWN — the helper is owner-checked
# and NOT re-entrant, so all five rows died in ~1 s each with "FATAL: could not
# acquire the CUDA suspend hold"; (2) it exited 0 anyway, because a `for` loop's
# status is its LAST command's, so a job whose every row failed read GREEN; and
# (3) it repeated that identical failure four more times.
#
# HERMETIC: the shipped runner runs UNMODIFIED from a scratch repo layout
# (<root>/scripts/rebench-rows.sh), so its $SELF_DIR/$REPO resolve into the sandbox
# and BOTH collaborators it launches — the probe and heavy-job — are stubs there.
# The pre-row GPU gate is the shared _tac_gpu_wait_foreign_clear with TAC_GPU_BUSY_SH
# pointed at a stub, and the suspend marker at a sandbox path: no card, no lock, no
# /dev/shm.  Nothing here can take the GPU.

# rebench_layout — build the scratch repo layout and the controlling stubs.
# Sets R_ROOT, R_OUT, R_PROBE_LOG, R_STUB, R_SUSPEND.
rebench_layout() {
    R_ROOT="$SANDBOX/rebench-root"
    R_OUT="$SANDBOX/rebench-out"
    R_PROBE_LOG="$SANDBOX/rebench-probe.log"
    R_STUB="$SANDBOX/rebench-stubbin"
    R_SUSPEND="$SANDBOX/rebench.suspend"
    mkdir -p "$R_ROOT/scripts" "$R_ROOT/bin" "$R_STUB"
    # The shipped runner and the shipped lib, byte for byte.
    cp "$REPO_ROOT/scripts/rebench-rows.sh" "$R_ROOT/scripts/rebench-rows.sh"
    cp "$REPO_ROOT/bin/_tac-bin-lib.sh" "$R_ROOT/bin/_tac-bin-lib.sh"
    # heavy-job: exec what it is given (the real one takes the lock then execs).
    printf '%s\n' '#!/usr/bin/env bash' 'exec "$@"' > "$R_ROOT/bin/heavy-job"
    chmod +x "$R_ROOT/bin/heavy-job"
    # The probe: records its argv, prints a registry snapshot, and exits with the rc
    # the case chose for that row (R_FAIL_ROW; empty => every row passes).
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'printf "%s\n" "$*" >> "${R_PROBE_LOG:?}"' \
        'printf "  registry line (READ ONLY, snapshot): 26|stub|dummy.gguf\n"' \
        'row=""' \
        'while (( $# > 0 )); do case "$1" in --row) row="$2"; shift 2 ;; *) shift ;; esac; done' \
        '[[ "$row" == "${R_FAIL_ROW:-}" ]] && exit 1' \
        'exit 0' > "$R_ROOT/scripts/cache-ram-probe.sh"
    chmod +x "$R_ROOT/scripts/cache-ram-probe.sh"
    # The GPU detector: no foreign holder, so the pre-row gate opens at once.
    printf '%s\n' '#!/usr/bin/env bash' 'printf "{\"busy\":false,\"reasons\":[]}\n"' 'exit 0' \
        > "$R_STUB/gpu-busy.sh"
    chmod +x "$R_STUB/gpu-busy.sh"
    : > "$R_PROBE_LOG"
    export R_ROOT R_OUT R_PROBE_LOG R_STUB R_SUSPEND
}

# rebench_run <runner args...> — run the shipped runner with its collaborators stubbed.
rebench_run() {
    run env TAC_GPU_BUSY_SH="$R_STUB/gpu-busy.sh" R_PROBE_LOG="$R_PROBE_LOG" \
        R_FAIL_ROW="${R_FAIL_ROW:-}" \
        LLAMA_WATCHDOG_CUDA_SUSPEND_FILE="$R_SUSPEND" \
        bash "$R_ROOT/scripts/rebench-rows.sh" "$@"
}

@test "rebench runner: a failing row STOPS the run after ONE row and exits non-zero" {
    # Catches BOTH defects at once: the wrapper that repeated an identical failure
    # five times, and the wrapper that exited 0 with every row failed (a `for` loop's
    # status is its last command's).  Row 26 is FIRST and fails, so fail-fast must
    # stop there: one invocation, non-zero status, and the row/rc named.
    rebench_layout
    export R_FAIL_ROW=26
    rebench_run --rows 26,10,14 --out "$R_OUT"
    [[ "$status" -eq 1 ]]
    [[ "$(wc -l < "$R_PROBE_LOG")" -eq 1 ]]      # only the FIRST row was attempted
    grep -q -- '--row 26' "$R_PROBE_LOG"
    local rlog
    rlog="$(ls "$R_OUT"/rebench-*.log)"
    grep -q 'FAIL-FAST: stopping at row 26' "$rlog"
    grep -q 'row 26: rc=1' "$rlog"
    grep -q 'registry line (READ ONLY, snapshot)' "$rlog"   # the snapshot was kept
    [[ "$output" == *"at least one FAILED; exit 1"* ]]
}

@test "rebench runner: control — every row passing runs them ALL and exits 0" {
    # The control that makes the case above discriminating: without it, a runner that
    # stopped after one row unconditionally (or exited non-zero unconditionally) would
    # pass it.  Every row must be attempted and the status must be 0.
    rebench_layout
    R_FAIL_ROW=""
    rebench_run --rows 26,10,14 --out "$R_OUT"
    [[ "$status" -eq 0 ]]
    [[ "$(wc -l < "$R_PROBE_LOG")" -eq 3 ]]
    grep -q -- '--row 26' "$R_PROBE_LOG"
    grep -q -- '--row 10' "$R_PROBE_LOG"
    grep -q -- '--row 14' "$R_PROBE_LOG"
    [[ "$output" == *"all 3 row(s) exited 0"* ]]
    [[ "$output" != *"FAIL-FAST"* ]]
}

@test "rebench runner: a suspend marker held by its OWN tree REFUSES before any row" {
    # Catches the first, measured defect: a wrapper of OURS holding the CUDA suspend
    # while the probe acquires its own.  The runner is launched as a CHILD of the shell
    # that stamps the marker, so the recorded pid is an ANCESTOR — exactly the
    # hand-rolled wrapper's shape — and it must refuse (exit 2) rather than run rows
    # that would each die in ~1 s.  Rows 26,10 would both be attempted if it did not.
    rebench_layout
    run env TAC_GPU_BUSY_SH="$R_STUB/gpu-busy.sh" R_PROBE_LOG="$R_PROBE_LOG" \
        R_SUSPEND="$R_SUSPEND" R_ROOT="$R_ROOT" R_OUT="$R_OUT" \
        LLAMA_WATCHDOG_CUDA_SUSPEND_FILE="$R_SUSPEND" \
        bash -c 'printf "%s\n" "$$" > "$R_SUSPEND"; bash "$R_ROOT/scripts/rebench-rows.sh" --rows 26,10 --out "$R_OUT"'
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"held by THIS script's own process tree"* ]]
    [[ ! -s "$R_PROBE_LOG" ]]                    # NO probe was ever launched
    [[ "$output" != *"gpu gate"* ]]              # it stopped before the card was even asked
}

# ── the EXIT path (v14, 2026-10-22) ──────────────────────────────────────────
# The measured defect: SIGTERMing a run left its child llama-server holding the lane
# port (so the unit failed to bind) and left the lane DOWN.  These pin the restore.

_probe_cleanup_harness() {
    local active="$1"
    awk '/^term_server\(\) \{/,/^}/' "$PROBE" > "$SANDBOX/cleanup.sh"
    awk '/^__probe_exit_cleanup\(\) \{/,/^}/' "$PROBE" >> "$SANDBOX/cleanup.sh"
    grep -q '__probe_exit_cleanup' "$SANDBOX/cleanup.sh" \
        || { echo "FAIL: cleanup not extracted from $PROBE"; return 1; }
    cat > "$SANDBOX/run.sh" <<EOS
set -uo pipefail
source "$SANDBOX/cleanup.sh"
SYSTEMCTL_LOG="$SANDBOX/calls"
systemctl() { printf '%s\n' "\$*" >> "\$SYSTEMCTL_LOG"; return 0; }
term_server() { printf 'TERM %s\n' "\$1" >> "\$SYSTEMCTL_LOG"; }
NEEDS_CUDA_CARD=0
LANE="llama-test.service"
_PROBE_CLEANED=0
_PROBE_LANE_WAS_ACTIVE=$active
_PROBE_ARM_PID=999999
__probe_exit_cleanup
EOS
    run bash "$SANDBOX/run.sh"
}

@test "probe exit: an ACTIVE lane is restarted and this run's server is killed" {
    # Catches the measured failure: a killed run left the arm's server on the port and
    # the lane down, so the unit then failed to bind and a human had to restore it.
    _probe_cleanup_harness 1
    [[ "$status" -eq 0 ]]
    grep -q '^TERM 999999$' "$SANDBOX/calls" \
        || { echo "FAIL: the arm server was not terminated:"; cat "$SANDBOX/calls"; return 1; }
    grep -q '^--user reset-failed llama-test.service$' "$SANDBOX/calls" \
        || { echo "FAIL: the restart counter was not cleared:"; cat "$SANDBOX/calls"; return 1; }
    grep -q '^--user start llama-test.service$' "$SANDBOX/calls" \
        || { echo "FAIL: the lane it stopped was not restarted:"; cat "$SANDBOX/calls"; return 1; }
}

@test "probe exit: a lane that was already DOWN is left down (control)" {
    # The restore returns what it FOUND: a lane taken down on purpose stays down, so a
    # probe cannot turn into an unrequested lane activation.
    _probe_cleanup_harness 0
    [[ "$status" -eq 0 ]]
    grep -q '^TERM 999999$' "$SANDBOX/calls" \
        || { echo "FAIL: the arm server was not terminated:"; cat "$SANDBOX/calls"; return 1; }
    if grep -q 'start llama-test.service' "$SANDBOX/calls"; then
        echo "FAIL: a lane that was already down was STARTED:"; cat "$SANDBOX/calls"; return 1
    fi
}

@test "probe exit: INT and TERM are trapped, so the EXIT cleanup runs on a kill" {
    # A SIGTERM otherwise ends the shell WITHOUT the EXIT trap — that is the mechanism
    # behind the orphaned server, and `timeout` sends exactly that.
    grep -q "trap '__probe_exit_cleanup' EXIT" "$PROBE"
    grep -q "trap 'exit 130' INT" "$PROBE"
    grep -q "trap 'exit 143' TERM" "$PROBE"
}
