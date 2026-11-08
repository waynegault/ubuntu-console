#!/usr/bin/env bats
# ==============================================================================
# Unit Tests — utilisation must not accuse the CUDA lane of being foreign to itself
# ==============================================================================
# THE REGRESSION (2026-10-23 02:34:06):
#
#   [watchdog] GPU busy — stopping llama-cuda-llama32-3b-chat (freeing VRAM;
#              Xe lane serves) [probe: util=74%>=15%]
#
# The card's only compute-app resident at that moment was the sanctioned CUDA
# lane, generating tokens for an investigator bench case. A serving llama-server
# pins utilisation far past UTIL_THRESHOLD (15%), and `busy()` asked util FIRST
# in a short-circuiting OR chain — so the probe answered BUSY about our own
# lane's work, the lock/owner/foreign signals that would have said "ours" were
# never consulted, and the watchdog stopped a healthy lane mid-request.
#
# The fix has two halves, both pinned here:
#   1. sanctioned_residents_only() — when EVERY compute-app resident is one of
#      the two sanctioned server binaries, utilisation is our own lane working
#      and must not count.
#   2. busy() asks definitive ownership evidence first and the utilisation
#      heuristic last, because only the first answer is recorded as the reason.
#
# The fail-closed direction is preserved and pinned too: an unsanctioned
# resident, or a card busy with NO compute-app listing at all, still reports
# BUSY. A false FREE would leave the lane running while a stranger holds the
# card; a false BUSY is what took the lane down.
#
# NOTE: these tests never execute bin/gpu-busy.sh's main body. They extract the
# function definitions verbatim and drive them with a stubbed nvidia-smi, so no
# real GPU state, lane or server is touched.
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
SRC="$REPO_ROOT/bin/gpu-busy.sh"

setup() {
    TAC_TEST_TMPDIR="$(mktemp -d)"
    export TAC_TEST_TMPDIR
    # Keep the two real locks out of the picture: a stale /tmp/llm-bench.lock or a
    # live investigator gpu.lock on the host would make these tests pass or fail
    # for reasons that have nothing to do with the assertions.
    export LLM_BENCH_LOCK_FILE="$TAC_TEST_TMPDIR/bench.lock"
    export INVESTIGATOR_GPU_LOCK="$TAC_TEST_TMPDIR/nonexistent-gpu.lock"
    unset INVESTIGATOR_PRODUCTION_OUTPUT
    unset LLAMA_XE_SERVER_BIN

    mkdir -p "$TAC_TEST_TMPDIR/bin"
    cat > "$TAC_TEST_TMPDIR/bin/nvidia-smi" <<'EOS'
#!/usr/bin/env bash
# Stub: answers only the queries gpu-busy.sh makes, from the test environment.
case "$*" in
    *--query-compute-apps=pid*)  printf '%s\n' "${STUB_PIDS:-}" ;;
    *--query-gpu=utilization.gpu*) printf '%s\n' "${STUB_UTIL:-0}" ;;
    *--query-gpu=memory.used*)   printf '%s\n' "${STUB_VRAM:-0}" ;;
    *) exit 0 ;;
esac
EOS
    chmod +x "$TAC_TEST_TMPDIR/bin/nvidia-smi"
    # The process table is LIVE state on this shared box: declared_workload_busy() runs
    # `pgrep -f model_selection_bench.py` (and `pgrep -x llama-bench`), so a bench running
    # while the suite executes makes it answer BUSY and flips the free-card cases.
    # Measured 2026-10-23 in CI: `reasons=declared:model_selection_bench` on cases that
    # assert "free".  Pin the probe, as the nvidia-smi stub already pins the device.
    cat > "$TAC_TEST_TMPDIR/bin/pgrep" <<'EOS'
#!/usr/bin/env bash
# Stub: no process matches in this sandbox, whatever the pattern.
exit 1
EOS
    chmod +x "$TAC_TEST_TMPDIR/bin/pgrep"
    # The lane set is LIVE state too: v1.12.0 derives each lane's port from its running
    # unit, and this box has two (:18087 chat, :18080 embedding). A suite that read them
    # would pass or fail on what is serving at that moment. Default: no units, which is
    # also the fallback path (the configured port alone).
    cat > "$TAC_TEST_TMPDIR/bin/systemctl" <<'EOS'
#!/usr/bin/env bash
# Stub: STUB_LLAMA_UNITS is "<unit> <port>" per line — the CUDA lane set as TEST state.
case "$*" in
    *list-units*)
        [ -n "${STUB_LLAMA_UNITS:-}" ] || exit 0
        awk '{print $1}' <<<"$STUB_LLAMA_UNITS"
        ;;
    *show*--value*)
        _u="${*: -1}"
        _p=$(awk -v u="$_u" '$1 == u {print $2}' <<<"${STUB_LLAMA_UNITS:-}")
        [ -n "$_p" ] || exit 1
        printf '{ path=/usr/bin/llama-cuda-server ; argv[]=/usr/bin/llama-cuda-server --port %s ; }\n' "$_p"
        ;;
    *) exit 0 ;;
esac
EOS
    chmod +x "$TAC_TEST_TMPDIR/bin/systemctl"
    # The lane-metrics probe is a live HTTP read (sanctioned_lane_serving). Pin it: a real
    # lane serving on the box while the suite runs would otherwise flip these cases, and
    # the default answers "no metric" so fail-closed is what is tested. Per-port bodies,
    # because v1.12.0 asks EVERY lane: a case makes one serve while another is idle.
    cat > "$TAC_TEST_TMPDIR/bin/curl" <<'EOS'
#!/usr/bin/env bash
_url="${*: -1}"; _port="${_url##*:}"; _port="${_port%%/*}"
_var="STUB_METRICS_${_port}"
_body="${!_var:-${STUB_METRICS:-}}"
[ -n "$_body" ] || exit 7
printf '%s\n' "$_body"
EOS
    chmod +x "$TAC_TEST_TMPDIR/bin/curl"
    export LLAMA_CUDA_LANE_PORT=18087
    unset STUB_METRICS STUB_LLAMA_UNITS
    export PATH="$TAC_TEST_TMPDIR/bin:$PATH"

    # Extract the real definitions, stopping before the script's own main block.
    # _tac-bin-lib.sh is copied beside the extract: the script sources it by a path
    # relative to its own location, and without it _self_chain/_process_executes are
    # undefined — which silently weakens the declared-workload signal AND writes a
    # "No such file" line to stderr, which BATS merges into $output.
    cp "$REPO_ROOT/bin/_tac-bin-lib.sh" "$TAC_TEST_TMPDIR/_tac-bin-lib.sh"
    local last
    last=$(grep -n '^if busy; then$' "$SRC" | tail -1 | cut -d: -f1)
    [ -n "$last" ] || { echo "could not locate the main block in $SRC" >&2; return 1; }
    head -n "$((last - 2))" "$SRC" > "$TAC_TEST_TMPDIR/probe.sh"
    cat >> "$TAC_TEST_TMPDIR/probe.sh" <<'EOS'
REASONS=()
if busy; then
    printf 'busy reasons=%s\n' "${REASONS[*]}"
else
    # v1.9.1: a FREE answer carries its own audit line, so the assertions below can
    # tell "quiet card" (reasons=none) from "free because the lane was serving its own
    # prefill" — the state that used to be indistinguishable from idle.
    printf 'free reasons=%s\n' "${REASONS[*]:-none}"
fi
EOS
}

teardown() {
    [ -n "${RESIDENT_PID:-}" ] && kill "$RESIDENT_PID" 2>/dev/null
    rm -rf "$TAC_TEST_TMPDIR"
}

# A live process whose /proc/PID/exe resolves to a path we control the sanction
# list for, so "sanctioned" is decided by the same code path the probe uses in
# production (resolved exe, never the name).
start_resident() {
    sleep 60 &
    RESIDENT_PID=$!
    # let /proc settle
    for _ in $(seq 1 20); do
        [ -e "/proc/$RESIDENT_PID/exe" ] && break
        sleep 0.1
    done
}

run_probe() {
    bash "$TAC_TEST_TMPDIR/probe.sh"
}

@test "sanctioned resident at high utilisation is NOT busy (the 02:34 regression)" {
    start_resident
    export LLAMA_CUDA_SERVER_BIN="$(readlink -f /bin/sleep)"
    export STUB_PIDS="$RESIDENT_PID"
    export STUB_UTIL=95

    run run_probe
    [ "$status" -eq 0 ]
    # Sanctioned residents at 95% util: suppressed, and the audit line says why.
    [[ "$output" == free\ reasons=*"util-suppressed:95%"* ]]
    [[ "$output" != *"cannot-attribute"* ]]
    [[ "$output" != *"busy"* ]]
}

@test "unsanctioned resident at high utilisation is busy, and named" {
    start_resident
    export LLAMA_CUDA_SERVER_BIN="$(readlink -f /usr/bin/true)"
    export STUB_PIDS="$RESIDENT_PID"
    export STUB_UTIL=95

    run run_probe
    [ "$status" -eq 0 ]
    [[ "$output" == *"foreign-app pid=$RESIDENT_PID"* ]]
    # The utilisation reason must NOT be the one recorded: ownership explains it.
    [[ "$output" != *"util="* ]]
}

@test "high utilisation with no compute-app listing still fails closed" {
    # No metric either: the lane is not serving, so an unattributable util is BUSY.
    export STUB_PIDS=""
    export STUB_UTIL=95

    run run_probe
    [ "$status" -eq 0 ]
    [[ "$output" == *"util=95%"* ]]
}

@test "no compute-app listing while the lane serves its own request is NOT busy (00:13:53)" {
    # The measured fault, pinned end to end: empty residency read + high utilisation.
    # `requests_processing 1` is the server saying the utilisation is its own prefill,
    # and stopping on that is stopping the lane for being busy with itself.
    export STUB_PIDS=""
    export STUB_UTIL=90
    export STUB_METRICS='# TYPE llamacpp:requests_processing gauge
llamacpp:requests_processing 1'

    run run_probe
    [ "$status" -eq 0 ]
    # The 00:13:53 shape, now with its record: free BECAUSE the lane was serving, and
    # the residency read could not attribute the utilisation to a named resident.
    [[ "$output" == *"cannot-attribute:residency-empty"* ]]
    [[ "$output" == *"lane-serving"* ]]
    [[ "$output" == *"util-suppressed:90%"* ]]
    [[ "$output" != *"busy"* ]]
}

@test "an idle lane plus an empty residency listing is still busy on utilisation" {
    # The other side of the same arm: requests_processing 0 is not an excuse.
    export STUB_PIDS=""
    export STUB_UTIL=90
    export STUB_METRICS='llamacpp:requests_processing 0'

    run run_probe
    [ "$status" -eq 0 ]
    [[ "$output" == *"util=90%"* ]]
}

@test "an unparseable metric body does not excuse utilisation" {
    export STUB_PIDS=""
    export STUB_UTIL=90
    export STUB_METRICS='<html>not metrics</html>'

    run run_probe
    [ "$status" -eq 0 ]
    [[ "$output" == *"util=90%"* ]]
}

@test "the bench lock beats a sanctioned-only card" {
    start_resident
    export LLAMA_CUDA_SERVER_BIN="$(readlink -f /bin/sleep)"
    export STUB_PIDS="$RESIDENT_PID"
    export STUB_UTIL=95
    echo "$RESIDENT_PID" > "$LLM_BENCH_LOCK_FILE"

    run run_probe
    [ "$status" -eq 0 ]
    [[ "$output" == *"lock:$LLM_BENCH_LOCK_FILE"* ]]
}

@test "idle sanctioned-only card is free" {
    start_resident
    export LLAMA_CUDA_SERVER_BIN="$(readlink -f /bin/sleep)"
    export STUB_PIDS="$RESIDENT_PID"
    export STUB_UTIL=0

    run run_probe
    [ "$status" -eq 0 ]
    # Quiet card: nothing to attribute, so no annotation. An annotation here would be
    # noise on every idle poll and would make the 00:13:53 shape ordinary.
    [ "$output" = "free reasons=none" ]
}

@test "a sanctioned-only card at high utilisation records the suppressed reading" {
    start_resident
    export LLAMA_CUDA_SERVER_BIN="$(readlink -f /bin/sleep)"
    export STUB_PIDS="$RESIDENT_PID"
    export STUB_UTIL=95

    run run_probe
    [ "$status" -eq 0 ]
    [[ "$output" == *"util-suppressed:95%"* ]]
    # A listed, sanctioned resident is attributable: the card was NOT unreadable.
    [[ "$output" != *"cannot-attribute"* ]]
}

@test "a serving lane with no residency listing is free and says both reasons" {
    export STUB_PIDS=""
    export STUB_UTIL=90
    export STUB_METRICS='llamacpp:requests_processing 1'

    run run_probe
    [ "$status" -eq 0 ]
    [[ "$output" == *"cannot-attribute:residency-empty"* ]]
    [[ "$output" == *"lane-serving"* ]]
}

@test "a serving lane on a quiet card records nothing" {
    # Suppression without a threshold breach is not an event: no annotation, because
    # a reading below UTIL_THRESHOLD was never a candidate for a stop.
    export STUB_PIDS=""
    export STUB_UTIL=3
    export STUB_METRICS='llamacpp:requests_processing 1'

    run run_probe
    [ "$status" -eq 0 ]
    [ "$output" = "free reasons=none" ]
}

# ---------------------------------------------------------------------------------
# v1.12.0 (card 62fbc8cb) — the serving check covers EVERY CUDA lane on the card.
#
# 2026-11-08 03:23:27: the watchdog stopped llama-cuda-qwen3coder-30b-chat on
# `[probe: util=91%>=15%]` while the chat lane had ZERO requests in flight and the
# EMBEDDING lane on the same card (:18080) was working — 10 slot events in the half
# minute before. Arm 2 asked :18087 only, so it answered "not serving" and utilisation
# alone decided. The narrative call riding on the stopped lane died with it.
#
# The port set is DERIVED from each running `llama-cuda-*` unit's ExecStart, so these
# cases state the property that matters: a lane the probe has never heard of is covered
# without editing a list.
# ---------------------------------------------------------------------------------

@test "the card's embedding lane serving suppresses utilisation while the CHAT port is idle (03:23:27)" {
    _units=$'llama-cuda-qwen3coder-30b-chat.service 18087\n'
    _units+=$'llama-cuda-qwen3embedding-embed.service 18080'
    export STUB_LLAMA_UNITS="$_units"
    export STUB_METRICS_18087='llamacpp:requests_processing 0'
    export STUB_METRICS_18080='llamacpp:requests_processing 1'
    export STUB_UTIL=91
    # No compute-app listing: the state the incident was in, where the residency arm
    # cannot answer and utilisation is the last word.
    export STUB_PIDS=""

    run run_probe
    [ "$status" -eq 0 ]
    [[ "$output" == free\ reasons=*"lane-serving:18080"* ]]
    [[ "$output" == *"util-suppressed:91%"* ]]
    [[ "$output" != *"busy reasons"* ]]
}

@test "a lane the probe has never heard of is covered, because the port comes from its unit" {
    # The property, not the instance: a new lane at a new port needs no edit here or
    # in the probe — only a running unit that names its own port.
    export STUB_LLAMA_UNITS=$'llama-cuda-qwen3coder-30b-chat.service 18087\nllama-cuda-newlane-chat.service 18099'
    export STUB_METRICS_18087='llamacpp:requests_processing 0'
    export STUB_METRICS_18099='llamacpp:requests_processing 3'
    export STUB_UTIL=91
    export STUB_PIDS=""

    run run_probe
    [ "$status" -eq 0 ]
    [[ "$output" == free\ reasons=*"lane-serving:18099"* ]]
}

@test "a foreign resident still stops the lane even while a sanctioned lane reports a request" {
    # The falsifier the card names. foreign_apps_busy() runs BEFORE the utilisation arm
    # and is not suppressed by a serving lane, so widening the serving check can only
    # ever remove a util-driven stop — never shield a stranger holding the card.
    start_resident
    export LLAMA_CUDA_SERVER_BIN="$(readlink -f /usr/bin/true)"
    export STUB_PIDS="$RESIDENT_PID"
    export STUB_UTIL=91
    export STUB_LLAMA_UNITS='llama-cuda-qwen3embedding-embed.service 18080'
    export STUB_METRICS_18080='llamacpp:requests_processing 1'

    run run_probe
    [ "$status" -eq 0 ]
    [[ "$output" == *"foreign-app pid=$RESIDENT_PID"* ]]
    [[ "$output" != *"lane-serving"* ]]
}

@test "no unit listing degrades to the configured port alone (the 1.11.0 behaviour)" {
    # Fail-closed direction: an unreadable unit set contributes nothing, and the
    # configured port is still asked — so the worst case is the single-port probe
    # this replaces, never a silent FREE.
    export STUB_LLAMA_UNITS=""
    export STUB_METRICS_18087='llamacpp:requests_processing 0'
    export STUB_UTIL=91

    run run_probe
    [ "$status" -eq 0 ]
    [[ "$output" == *"busy reasons=util=91%"* ]]
    [[ "$output" != *"lane-serving"* ]]
}

@test "a unit whose ExecStart names no port contributes nothing" {
    # Ports are parsed, never assumed: a lane started without --port must not make the
    # probe ask a guessed port, where an unrelated listener could answer for us.
    export STUB_LLAMA_UNITS='llama-cuda-noport-chat.service noport'
    export STUB_METRICS_18087='llamacpp:requests_processing 0'
    export STUB_UTIL=91

    run run_probe
    [ "$status" -eq 0 ]
    [[ "$output" == *"busy reasons=util=91%"* ]]
    [[ "$output" != *"lane-serving"* ]]
}
