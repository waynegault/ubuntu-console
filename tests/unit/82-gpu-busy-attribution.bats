#!/usr/bin/env bats
# ==============================================================================
# Unit Tests — the busy line attributes the match, not just its class
# ==============================================================================
# THE GAP (2026-11-04T12:35:56Z, card 18aa740e):
#
#   [watchdog] GPU busy — stopping llama-cuda-qwen3coder-30b-chat ... [probe: declared:autotune]
#
# The verdict was CORRECT — a real autotune script was executing — and it was still
# unattributable afterwards. The line named the probe CLASS and nothing else, the
# process had exited by the time anyone looked, and "no autotune process existed" was
# recorded as a refutation when it was only a LATER reading. A class cannot separate a
# real run from a test or lint invocation that NAMES the same script.
#
# What these tests pin: a stop on declared:autotune now carries the pid, the rule that
# matched, and the argv it matched on — in the SAME journal line. They also pin the
# control, which matters as much: a process that merely names the artefact produces NO
# attribution, so the string is evidence of a match rather than decoration that any
# busy line would carry.
#
# NOTE: these tests never execute bin/gpu-busy.sh's main body. They extract the whole
# script above its main block verbatim and drive it with stubbed nvidia-smi/pgrep, so
# no real GPU state, lane or server is touched.
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
SRC="$REPO_ROOT/bin/gpu-busy.sh"

setup() {
    TAC_TEST_TMPDIR="$(mktemp -d)"
    export TAC_TEST_TMPDIR
    export LLM_BENCH_LOCK_FILE="$TAC_TEST_TMPDIR/bench.lock"
    export INVESTIGATOR_GPU_LOCK="$TAC_TEST_TMPDIR/nonexistent-gpu.lock"
    unset INVESTIGATOR_PRODUCTION_OUTPUT
    unset LLAMA_XE_SERVER_BIN
    HARNESS_PIDS=()
    DETACHED_PID=""
    mkdir -p "$TAC_TEST_TMPDIR/bin"
    cat > "$TAC_TEST_TMPDIR/bin/nvidia-smi" <<'EOS'
#!/usr/bin/env bash
case "$*" in
    *--query-compute-apps=pid*)  exit 0 ;;
    *--query-gpu=utilization.gpu*) printf '0\n' ;;
    *--query-gpu=memory.used*)   printf '0\n' ;;
    *) exit 0 ;;
esac
EOS
    chmod +x "$TAC_TEST_TMPDIR/bin/nvidia-smi"
    # pgrep hands the probe exactly the pid this test started: the live process table
    # must not decide the answer, or a real campaign running beside the suite flips it.
    cat > "$TAC_TEST_TMPDIR/bin/pgrep" <<'EOS'
#!/usr/bin/env bash
[ "$1" = "-x" ] && exit 1
[ -n "${STUB_PIDS:-}" ] || exit 1
printf '%s\n' "${STUB_PIDS}"
exit 0
EOS
    chmod +x "$TAC_TEST_TMPDIR/bin/pgrep"
    cat > "$TAC_TEST_TMPDIR/bin/curl" <<'EOS'
#!/usr/bin/env bash
exit 7
EOS
    chmod +x "$TAC_TEST_TMPDIR/bin/curl"
    export LLAMA_CUDA_LANE_PORT=18087
    export PATH="$TAC_TEST_TMPDIR/bin:$PATH"

    cp "$REPO_ROOT/bin/_tac-bin-lib.sh" "$TAC_TEST_TMPDIR/_tac-bin-lib.sh"
    _build_probe
    printf '#!/usr/bin/env bash\nwhile :; do sleep 1; done\n' > "$TAC_TEST_TMPDIR/autotune-model.sh"
    chmod +x "$TAC_TEST_TMPDIR/autotune-model.sh"
}

teardown() {
    local p
    for p in "${HARNESS_PIDS[@]}"; do kill "$p" 2>/dev/null; done
    [ -n "${DETACHED_PID:-}" ] && kill "$DETACHED_PID" 2>/dev/null
    rm -rf "$TAC_TEST_TMPDIR"
}

# _build_probe — every function in the script plus a verdict epilogue. Everything, not
# just the matcher, because the attribution is produced by _any_executing_process
# calling _attr_argv and the caller printing it; a partial extraction would test a
# probe that cannot exist in production.
_build_probe() {
    local last
    last=$(grep -n '^if busy; then$' "$SRC" | tail -1 | cut -d: -f1)
    [ -n "$last" ] || { echo "could not locate the main block in $SRC" >&2; return 1; }
    head -n "$((last - 2))" "$SRC" > "$TAC_TEST_TMPDIR/probe.sh"
    cat >> "$TAC_TEST_TMPDIR/probe.sh" <<'EOS'
REASONS=()
if busy; then
    printf 'busy reasons=%s\n' "${REASONS[*]}"
else
    printf 'free reasons=%s\n' "${REASONS[*]:-none}"
fi
EOS
}

# _build_probe_with_arms — same extraction, epilogue also prints the two attribution
# fields this file's criterion-(b) tests read. Separate from _build_probe so the older
# arms keep their exact-output assertions (58 pins `free reasons=none` byte-for-byte).
_build_probe_with_arms() {
    local last
    last=$(grep -n '^if busy; then$' "$SRC" | tail -1 | cut -d: -f1)
    [ -n "$last" ] || { echo "could not locate the main block in $SRC" >&2; return 1; }
    head -n "$((last - 2))" "$SRC" > "$TAC_TEST_TMPDIR/probe-arms.sh"
    cat >> "$TAC_TEST_TMPDIR/probe-arms.sh" <<'EOS'
REASONS=()
if busy; then
    printf 'busy reasons=%s arm=%s checked=%s\n' "${REASONS[*]}" "${ARM:-none}" "${ARMS_RUN[*]:-none}"
else
    printf 'free reasons=%s arm=%s checked=%s\n' "${REASONS[*]:-none}" "${ARM:-none}" "${ARMS_RUN[*]:-none}"
fi
EOS
}

# start_detached [argv...] — run the fake autotune with extra argv, OUTSIDE this test's
# ancestry. It must not descend from bats or 1.10.0's harness suppression hides it and
# every arm would prove nothing.
start_detached() {
    local q="" a
    for a in "$@"; do q+=" $(printf '%q' "$a")"; done
    setsid bash -c "bash '$TAC_TEST_TMPDIR/autotune-model.sh'$q >/dev/null 2>&1 & echo \$! > '$TAC_TEST_TMPDIR/detached.pid'" </dev/null >/dev/null 2>&1
    local _
    for _ in $(seq 1 40); do
        DETACHED_PID=$(cat "$TAC_TEST_TMPDIR/detached.pid" 2>/dev/null || true)
        if [ -n "$DETACHED_PID" ] && [ -e "/proc/$DETACHED_PID/cmdline" ]; then
            STUB_PIDS="$DETACHED_PID"
            export STUB_PIDS
            return 0
        fi
        sleep 0.1
    done
    echo "the detached fake autotune never started" >&2
    return 1
}

@test "attribution: the busy line names the pid, the rule and the argv it matched" {
    start_detached
    run bash "$TAC_TEST_TMPDIR/probe.sh"
    [[ "$output" == busy* ]] || { echo "expected busy, got: $output"; return 1; }
    [[ "$output" == *"declared:autotune pid=$DETACHED_PID rule=argv-after:bash argv=bash $TAC_TEST_TMPDIR/autotune-model.sh"* ]] \
        || { echo "the busy line must attribute the match: $output"; return 1; }
}

@test "attribution: a process that merely NAMES the artefact produces none" {
    # The 2026-09-21 shape: a reader holding the file open. pgrep selects it by command
    # line, so this arm fails if attribution is written before the gate decides.
    tail -f "$TAC_TEST_TMPDIR/autotune-model.sh" >/dev/null 2>&1 &
    local reader=$!
    HARNESS_PIDS+=("$reader")
    sleep 0.4
    STUB_PIDS="$reader"
    export STUB_PIDS
    run bash "$TAC_TEST_TMPDIR/probe.sh"
    [[ "$output" == free* ]] || { echo "a reader must not answer busy, got: $output"; return 1; }
    [[ "$output" != *"declared:"* ]] || { echo "no class may be claimed: $output"; return 1; }
    [[ "$output" != *"argv="* ]] || { echo "no attribution may be produced: $output"; return 1; }
}

@test "attribution: the argv is sanitised to one bounded line" {
    local longarg
    longarg=$(printf 'y%.0s' $(seq 1 400))
    start_detached 'xx"yy]zz' "$longarg"
    run bash "$TAC_TEST_TMPDIR/probe.sh"
    # " -> ' and ] -> ), so the reasons JSON and the [probe: ...] bracket survive.
    [[ "$output" == *"argv=bash $TAC_TEST_TMPDIR/autotune-model.sh xx'yy)zz"* ]] \
        || { echo "quote/bracket must be REPLACED, not dropped: $output"; return 1; }
    [[ "$output" == *"..."* ]] || { echo "a long argv must be truncated: $output"; return 1; }
    [[ "$output" != *'"'* ]] || { echo "a quote would break the reasons JSON: $output"; return 1; }
    [[ "$output" != *']'* ]] || { echo "a bracket would end the probe bracket early: $output"; return 1; }
    (( ${#output} < 400 )) || { echo "the line is unbounded: ${#output} chars"; return 1; }
}

# ---------------------------------------------------------------------------------
# Criterion (b) as Wayne ruled it (2026-11-09): a busy stop must say which arm fired and
# which arms were consulted. It cannot say "a declared workload was positively ruled out"
# because the chain is a short-circuiting OR and declared_workload_busy is arm 5 of 6 —
# once utilisation_arm runs, "no declared workload" is true by construction. So the
# requirement is met by RECORD, and these three arms pin that record.
# ---------------------------------------------------------------------------------

@test "arms: a free card says every arm ran and none fired" {
    _build_probe_with_arms
    run bash "$TAC_TEST_TMPDIR/probe-arms.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == free* ]] || { echo "expected free, got: $output"; return 1; }
    [[ "$output" == *"arm=none"* ]] || { echo "a free verdict must not name a firing arm: $output"; return 1; }
    [[ "$output" == *"checked=training-tenant bench-lock cuda-owner foreign-app declared-workload utilisation"* ]] \
        || { echo "every arm must be recorded as consulted: $output"; return 1; }
}

@test "arms: a declared workload names ITSELF and the arms that ran before it" {
    _build_probe_with_arms
    start_detached
    run bash "$TAC_TEST_TMPDIR/probe-arms.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == busy* ]] || { echo "expected busy, got: $output"; return 1; }
    [[ "$output" == *"arm=declared-workload"* ]] || { echo "the firing arm must be named: $output"; return 1; }
    # Short-circuit visible: declared-workload is 5th, so utilisation never ran.
    [[ "$output" == *"checked=training-tenant bench-lock cuda-owner foreign-app declared-workload"* ]] \
        || { echo "the consulted arms must stop where the OR stopped: $output"; return 1; }
    [[ "$output" != *"utilisation"* ]] || { echo "an arm after the answer cannot have run: $output"; return 1; }
}

@test "arms: the 03:23:27 shape names utilisation AND proves the declared arm was consulted" {
    # The incident: no compute-app listing, no lane answering, utilisation high. The stop
    # was correct and unreadable — a reader could not tell whether a declared workload had
    # been looked for at all. This is the arm that says it was.
    _build_probe_with_arms
    cat > "$TAC_TEST_TMPDIR/bin/nvidia-smi" <<'EOS'
#!/usr/bin/env bash
case "$*" in
    *--query-compute-apps=pid*)  exit 0 ;;
    *--query-gpu=utilization.gpu*) printf '92\n' ;;
    *--query-gpu=memory.used*)   printf '0\n' ;;
    *) exit 0 ;;
esac
EOS
    chmod +x "$TAC_TEST_TMPDIR/bin/nvidia-smi"
    run bash "$TAC_TEST_TMPDIR/probe-arms.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == busy* ]] || { echo "expected busy, got: $output"; return 1; }
    [[ "$output" == *"arm=utilisation"* ]] || { echo "utilisation must be named as the arm: $output"; return 1; }
    [[ "$output" == *"declared-workload"* ]] \
        || { echo "the record must prove the declared arm ran: $output"; return 1; }
}

@test "attribution: a suppressed test-harness match carries its argv too" {
    bash "$TAC_TEST_TMPDIR/autotune-model.sh" &
    local child=$!
    HARNESS_PIDS+=("$child")
    sleep 0.3
    STUB_PIDS="$child"
    export STUB_PIDS
    run bash "$TAC_TEST_TMPDIR/probe.sh"
    [[ "$output" == *"suppressed:test-harness pid=$child"* ]] \
        || { echo "the suppression must name the pid: $output"; return 1; }
    [[ "$output" == *"argv=bash $TAC_TEST_TMPDIR/autotune-model.sh"* ]] \
        || { echo "the suppression must name the argv: $output"; return 1; }
    [[ "$output" != *"declared:autotune"* ]] \
        || { echo "a suppressed harness is not a declared workload: $output"; return 1; }
}
