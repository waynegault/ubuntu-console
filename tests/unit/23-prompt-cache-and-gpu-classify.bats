#!/usr/bin/env bats
# ==============================================================================
# Unit — prompt-cache budget (KVCACHE-CONSOLE-PROMPT-CACHE-001) + watchdog
#        driver-level classification (card a1d2591a) + the repo-owned
#        gpu-watch-selfcheck.
# ==============================================================================
# Three things have to stay true, and each was previously only a claim:
#
#   1. Every lane launches with an EXPLICIT `--cache-ram`.  llama.cpp's default is
#      8192 MiB of host RAM per server and nothing budgeted it; the value lives in
#      scripts/01-constants.sh (LLAMA_CACHE_RAM_MB) and is repeated as a literal in
#      the lane units, so this file pins those copies to each other.  The
#      `--slot-save-path` decision (never write slot KV to disk) is pinned as an
#      ABSENCE, because an omitted flag is the silent-default shape this repo bans.
#   2. The autotune KV-quant sweep cannot select a type that has not passed the
#      long-context retrieval probe, and it says so in its output instead of
#      silently narrowing the candidate list.
#   3. When gpu-busy.sh fails CLOSED for a driver-level reason, the watchdog
#      classifies that reason once (with gpu-passthrough-check.sh --json) and logs
#      which of the two situations it is — and does not re-probe a broken GPU on
#      every tick.
#   4. Every resident lane passes `--metrics` (SWITCH-CONSOLE-METRICS-001), the
#      serve arm emits it while the bench arm does not, and the reader reports
#      `not-measured` for an absent endpoint or a body without the counters —
#      never a 0 that would read as a cold cache.  `prompt_tokens_total` EXCLUDES
#      cached tokens, so the queried total is the sum of the two counters.
#
# Hermetic: nothing here touches the live box.  The launcher test extracts the
# argv-assembly function and runs it against a stub helper; the watchdog tests run
# the real script with a sandboxed HOME, mocked systemctl/curl and mocked probes;
# the self-check tests drive it with a fixture `openclaw`.
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
LAUNCHER="$REPO_ROOT/scripts/11e-llm-model.sh"
AUTOTUNE="$REPO_ROOT/scripts/autotune-model.sh"
CONSTANTS="$REPO_ROOT/scripts/01-constants.sh"
TELEMETRY="$REPO_ROOT/scripts/07-telemetry.sh"
ENV_SH="$REPO_ROOT/env.sh"
UNIT_DIR="$REPO_ROOT/systemd"
WATCHDOG="$REPO_ROOT/bin/llama-watchdog.sh"
SELFCHECK="$REPO_ROOT/bin/gpu-watch-selfcheck.sh"

setup_file() {
    export SANDBOX
    SANDBOX="$(mktemp -d)"
    export MOCK_STATE="$SANDBOX/state"
    export MOCK_BIN="$SANDBOX/mockbin"
    mkdir -p "$MOCK_STATE" "$MOCK_BIN" "$SANDBOX/home/.local/bin"

    # The watchdog resolves its probes as $HOME/.local/bin/<probe>, so a sandboxed
    # HOME is what keeps the real gpu-busy.sh and gpu-passthrough-check.sh — and the
    # real nvidia-smi behind them — out of these tests.
    export HOME="$SANDBOX/home"

    cat > "$HOME/.local/bin/gpu-busy.sh" <<'MOCK'
#!/usr/bin/env bash
# Mirrors the real contract: exit 0 = FREE, exit 1 = BUSY (JSON on stdout).
if [[ -f "$MOCK_STATE/busy" ]]
then
    printf '{"busy":true,"reasons":["%s"]}\n' "$(cat "$MOCK_STATE/gpu_reason" 2>/dev/null)"
    exit 1
fi
echo '{"busy":false,"reasons":[]}'
exit 0
MOCK
    chmod +x "$HOME/.local/bin/gpu-busy.sh"

    # The classifier counts its own invocations, so "was it probed again?" is a
    # fact about a file rather than an inference from the log text.
    cat > "$HOME/.local/bin/gpu-passthrough-check.sh" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "probe" >> "$MOCK_STATE/classify-calls"
cat "$MOCK_STATE/gpu_check.json" 2>/dev/null
exit 0
MOCK
    chmod +x "$HOME/.local/bin/gpu-passthrough-check.sh"

    cat > "$MOCK_BIN/systemctl" <<'MOCK'
#!/usr/bin/env bash
set -uo pipefail
[[ "${1:-}" == "--user" ]] && shift
op="${1:-}"; shift || true
case "$op" in
    show)
        # ActiveEnterTimestamp is the metric reader's window label; the watchdog
        # cases only ask for state, so the fixture is opt-in.
        if [[ "$*" == *"ActiveEnterTimestamp"* ]]
        then
            cat "$MOCK_STATE/active_enter" 2>/dev/null || echo ""
            exit 0
        fi
        unit="${1:-}"
        case "$unit" in
            *cuda*)      cat "$MOCK_STATE/cuda_state" 2>/dev/null || echo "inactive" ;;
            *cpu*)       cat "$MOCK_STATE/cpu_state"  2>/dev/null || echo "activating" ;;
            *qwen25-3b*) cat "$MOCK_STATE/xe3b_state" 2>/dev/null || echo "activating" ;;
            *)           cat "$MOCK_STATE/xe_state"   2>/dev/null || echo "activating" ;;
        esac
        ;;
    stop|start|restart|reset-failed)
        printf '%s %s\n' "$op" "$*" >> "$MOCK_STATE/systemctl.log"
        ;;
    *) ;;
esac
MOCK
    chmod +x "$MOCK_BIN/systemctl"

    cat > "$MOCK_BIN/curl" <<'MOCK'
#!/usr/bin/env bash
# /metrics serves the fixture body when one exists; absent means "endpoint not
# there" (exit 7), which the reader must render as not-measured.  /props empty and
# /health unreachable: the lanes under test are either activating (skipped) or the
# CUDA lane on a busy GPU, whose branch never consults health.
if [[ "$*" == *"/metrics"* ]]
then
    [[ -f "$MOCK_STATE/metrics_body" ]] || exit 7
    cat "$MOCK_STATE/metrics_body"
    exit 0
fi
if [[ "$*" == *"/props"* ]]
then
    echo '{}'
    exit 0
fi
exit 22
MOCK
    chmod +x "$MOCK_BIN/curl"
}

teardown_file() {
    rm -rf "${SANDBOX:-/tmp/bats-noop}"
}

setup() {
    export PATH="$MOCK_BIN:$PATH"
    rm -f "$MOCK_STATE"/*
    rm -f "$SANDBOX/wd.lock" "$SANDBOX/llm-bench.lock" "$SANDBOX/cuda.suspend" \
          "$SANDBOX/cuda.gpustop" "$SANDBOX/cuda.gpuclassify" 2>/dev/null || true
    # Every lane but CUDA parks in `activating` (the script's own "systemd is already
    # on it" state), so the lane under test is the only one that can act.
    echo "activating" > "$MOCK_STATE/xe_state"
    echo "activating" > "$MOCK_STATE/cpu_state"
    echo "activating" > "$MOCK_STATE/xe3b_state"
    echo "active" > "$MOCK_STATE/cuda_state"

    export LLAMA_WATCHDOG_LOCK_FILE="$SANDBOX/wd.lock"
    export LLAMA_WATCHDOG_STRIKE_DIR="$SANDBOX"
    export LLM_BENCH_LOCK_FILE="$SANDBOX/llm-bench.lock"
    export LLAMA_WATCHDOG_CUDA_SUSPEND_FILE="$SANDBOX/cuda.suspend"
    export LLAMA_WATCHDOG_CUDA_GPUSTOP_FILE="$SANDBOX/cuda.gpustop"
    export LLAMA_WATCHDOG_GPU_CLASSIFY_FILE="$SANDBOX/cuda.gpuclassify"
    # The classifier override is per-case (the "missing classifier" case sets it).
    unset LLAMA_WATCHDOG_GPU_CHECK
    # The hold WINDOW is deliberately left unset: the default must be the file's
    # existing cooling-off window (FLAP_HOLD_S), and one case asserts that.
    unset LLAMA_WATCHDOG_GPU_CLASSIFY_WINDOW_S
}

# ── the launcher's argv, built by its real function ──────────────────────────
# __model_use_build_command is extracted VERBATIM (the 12-gpu-exclusivity idiom)
# and run against the globals it consumes, so this exercises the shipped text
# rather than a paraphrase of it.  __spec_launch_flags and __tac_info are stubs:
# the first belongs to another module, the second is UI.  Optional arg 1 is the
# LLAMA_CACHE_RAM_MB the harness exports before building the argv; optional arg 2
# ("bench") sets __BENCH_MODE=1, so the bench-mode argv can be compared with the
# autotune's in the "bench-mode build omits --cache-ram" case below.
_build_argv() {
    local _cache_ram="${1:-}" _bench="${2:-}"
    awk '/^function __model_use_build_command\(\)/,/^}/' "$LAUNCHER" > "$SANDBOX/builder.sh"
    grep -q -- '--cache-ram' "$SANDBOX/builder.sh" \
        || { echo "FAIL: builder not extracted"; return 1; }

    cat > "$SANDBOX/harness.sh" <<'EOS'
set -uo pipefail
__spec_launch_flags() { :; }
__tac_info() { printf '%s\n' "$2"; }
source "$1"
[[ -n "${2:-}" ]] && export LLAMA_CACHE_RAM_MB="$2"
llm_backend="native"
LLAMA_SERVER_BIN="/stub/llama-server"
model_path="/stub/model.gguf"
LLM_PORT=18083
ctx=8192
batch_size=512
ubatch_size=256
threads=4
gpu_layers=99
fit_target_mb=1024
parallel_slots=1
row_flash_attn=true
row_kv_k=q8_0
row_kv_v=q8_0
row_mmap_mode=auto
arch="qwen2"
free_vram_mb=3000
model_bytes=1000000
C_Warning=""
if [[ -n "${3:-}" ]]; then export __BENCH_MODE=1; else unset __BENCH_MODE; fi
__model_use_build_command || { echo "FAIL: builder returned non-zero"; exit 1; }
printf '%s\n' "${cmd[@]}"
EOS
    bash "$SANDBOX/harness.sh" "$SANDBOX/builder.sh" "$_cache_ram" "$_bench"
}

# ── the prompt-cache reader ──────────────────────────────────────────────────
# The three reader functions are extracted VERBATIM from the telemetry module and
# run behind the suite's curl/systemctl stubs, so the assertions are about shipped
# text, not a paraphrase.  Arg 1 is the port; arg 2 is the unit whose
# ActiveEnterTimestamp names the window (omit it to get the "unavailable" label).
_cached_rate() {
    local port="$1" unit="${2:-}"
    {
        awk '/^function __llm_prompt_cache_read\(\)/,/^}/' "$TELEMETRY"
        awk '/^function __llm_lane_since\(\)/,/^}/' "$TELEMETRY"
        awk '/^function __llm_prompt_cache_rate\(\)/,/^}/' "$TELEMETRY"
    } > "$SANDBOX/cache-reader.sh"
    grep -q '__llm_prompt_cache_rate' "$SANDBOX/cache-reader.sh" \
        || { echo "FAIL: cache reader not extracted"; return 1; }

    cat > "$SANDBOX/cache-harness.sh" <<'EOS'
set -uo pipefail
source "$1"
__llm_prompt_cache_rate "$2" "${3:-}"
EOS
    bash "$SANDBOX/cache-harness.sh" "$SANDBOX/cache-reader.sh" "$port" "$unit"
}

@test "prompt-cache: the launcher emits --cache-ram, and never --slot-save-path" {
    run _build_argv
    [[ "$status" -eq 0 ]]
    # Paired adjacency, not "contains": a --cache-ram with no value (or with the
    # wrong neighbour) would satisfy a substring check and launch the 8192 default.
    [[ "$output" == *$'--cache-ram\n0'* ]] \
        || { echo "expected '--cache-ram 0' in argv, got:"; printf '%s\n' "$output"; return 1; }
    # The recorded --slot-save-path decision is an ABSENCE, so the absence is what
    # gets pinned: nothing may start writing slot KV state to disk unnoticed.
    [[ "$output" != *"--slot-save-path"* ]]
}

@test "prompt-cache: LLAMA_CACHE_RAM_MB overrides the emitted value" {
    run _build_argv 4096
    [[ "$status" -eq 0 ]]
    [[ "$output" == *$'--cache-ram\n4096'* ]]
}

@test "prompt-cache: a bad LLAMA_CACHE_RAM_MB warns and falls back to 0, never to 8192" {
    run _build_argv half
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"not an integer"* ]] || { echo "the fallback was silent: $output"; return 1; }
    [[ "$output" == *$'--cache-ram\n0'* ]]
}

@test "prompt-cache: the cache flag changes nothing else in the argv (window inputs held)" {
    run _build_argv
    [[ "$status" -eq 0 ]]
    printf '%s\n' "$output" > "$SANDBOX/argv-default"
    # --ctx-size and --parallel are the inputs the window invariant is asserted on
    # (advertised ctx == /props n_ctx_slot), so they are pinned here too.
    [[ "$(printf '%s\n' "$output" | grep -c -- '--ctx-size')" -eq 1 ]]
    [[ "$(printf '%s\n' "$output" | grep -A1 -x -- '--ctx-size')" == *$'8192'* ]]

    run _build_argv 4096
    [[ "$status" -eq 0 ]]
    printf '%s\n' "$output" > "$SANDBOX/argv-override"

    # Normalise the one thing that may differ — the value after --cache-ram — so a
    # difference ANYWHERE else fails: "the cache flag cannot disturb the window" is
    # checked, not assumed.
    awk '/^--cache-ram$/{print; getline; print "CACHE"; next} {print}' \
        "$SANDBOX/argv-default" > "$SANDBOX/a1"
    awk '/^--cache-ram$/{print; getline; print "CACHE"; next} {print}' \
        "$SANDBOX/argv-override" > "$SANDBOX/a2"
    diff "$SANDBOX/a1" "$SANDBOX/a2" || { echo "the argv changed beyond the cache value"; return 1; }
}

@test "prompt-cache: a bench-mode build omits --cache-ram, agreeing with the autotune spawn" {
    # The bench exists to REPRODUCE the certified configuration — bench-rows.sh:80
    # ("off = measure the CERTIFIED configuration") — and the recorded decision is that
    # the benches deliberately omit --cache-ram, because changing what a bench server
    # caches "would change what the certified number means" (01-constants.sh:380-383).
    # `model bench` shares __model_use_build_command with the serve path, so before this
    # case a bench argv carried `--cache-ram 0` while the autotune's spawn carried none:
    # the bench did NOT reproduce what it validates.  This case fails on that builder.
    #
    # The CERTIFIED side: the autotune's spawn must still pass NO --cache-ram.  If that
    # ever changes, this case's whole premise is gone, so it is asserted, not assumed.
    awk '/^_bench_spawn\(\)/,/^}/' "$AUTOTUNE" > "$SANDBOX/at-spawn.sh"
    grep -q 'LLAMA_BIN' "$SANDBOX/at-spawn.sh" \
        || { echo "FAIL: _bench_spawn not extracted from $AUTOTUNE"; return 1; }
    if grep -q -- '--cache-ram' "$SANDBOX/at-spawn.sh"; then
        echo "FAIL: the autotune spawn now passes --cache-ram; the certified argv moved:"
        grep -n -- '--cache-ram' "$SANDBOX/at-spawn.sh"
        return 1
    fi

    # The MEASURING side: a bench-mode build of the same row must omit it too.
    run _build_argv "" bench
    [[ "$status" -eq 0 ]]
    if [[ "$output" == *"--cache-ram"* ]]; then
        echo "FAIL: bench-mode build still passes --cache-ram; it does not reproduce the certified argv:"
        printf '%s\n' "$output"
        return 1
    fi

    # ...and the omission is BENCH-ONLY: the serve build of that same row still emits it.
    run _build_argv
    [[ "$status" -eq 0 ]]
    [[ "$output" == *$'--cache-ram\n0'* ]] \
        || { echo "FAIL: the serve build no longer emits '--cache-ram 0':"; printf '%s\n' "$output"; return 1; }
}

@test "prompt-cache: every repo lane unit passes the same --cache-ram literal as 01-constants" {
    local expected
    expected=$(sed -nE 's/.*export LLAMA_CACHE_RAM_MB="\$\{LLAMA_CACHE_RAM_MB:-([-0-9]+)\}".*/\1/p' "$CONSTANTS")
    [[ -n "$expected" ]] || { echo "FAIL: 01-constants declares no LLAMA_CACHE_RAM_MB default"; return 1; }

    local u exec_line status=0
    for u in "$UNIT_DIR"/llama-*.service
    do
        [[ -f "$u" ]] || continue
        # A lane is a unit that serves a port; the watchdog units do not.  The
        # assertion is on the ExecStart LINE, not the file: the explanatory comment
        # above each lane names the flags it sets AND the one it deliberately omits,
        # so a file-wide grep answers a question nobody asked.
        exec_line=$(sed -nE 's/^ExecStart=//p' "$u")
        [[ -n "$exec_line" ]] || continue
        [[ "$exec_line" == *"--port"* ]] || continue
        [[ "$exec_line" == *"--cache-ram ${expected}"* ]] \
            || { echo "FAIL: ${u##*/} does not pass '--cache-ram ${expected}'"; status=1; }
        [[ "$exec_line" == *"--slot-save-path"* ]] \
            && { echo "FAIL: ${u##*/} sets --slot-save-path (the decision is never)"; status=1; }
    done
    [[ "$status" -eq 0 ]] || return 1
}

# ── --metrics and the prompt-cache reader (SWITCH-CONSOLE-METRICS-001) ───────
# The five resident lanes are a literal here on purpose: the card names them,
# and the constants table is asserted to AGREE with this list, so neither side
# can drift silently.  The counters are the serving stack's own evidence that a
# prefix-cache regression happened; a reader that printed 0 for an unreadable
# endpoint would hide exactly that.
_LANE_SPECS='llama-xe-minicpm5-1b-chat.service|18081
llama-xe-embeddinggemma-embed.service|18080
llama-xe-qwen25-3b-chat.service|18085
llama-cuda-llama32-3b-chat.service|18083
llama-cpu-qwen25-3b-chat.service|18084'

@test "metrics: every resident lane unit passes --metrics on its loopback listener" {
    local spec unit port u exec_line count status=0
    while IFS= read -r spec
    do
        unit="${spec%%|*}"; port="${spec##*|}"
        u="$UNIT_DIR/$unit"
        if [[ ! -f "$u" ]]; then echo "FAIL: $u is missing"; status=1; continue; fi
        exec_line=$(sed -nE 's/^ExecStart=//p' "$u")
        # Exactly one: a duplicated flag is a load-time failure, not a harmless copy.
        count=$(grep -o -- '--metrics' <<< "$exec_line" | wc -l | tr -d ' ')
        [[ "$count" -eq 1 ]] \
            || { echo "FAIL: ${unit} carries --metrics ${count} times"; status=1; }
        [[ "$exec_line" == *"--port ${port}"* ]] \
            || { echo "FAIL: ${unit} no longer serves :${port}"; status=1; }
        [[ "$exec_line" == *"--host 127.0.0.1"* ]] \
            || { echo "FAIL: ${unit} is not loopback-bound"; status=1; }
        grep -q 'SWITCH-CONSOLE-METRICS-001' "$u" \
            || { echo "FAIL: ${unit} lacks the card comment"; status=1; }
        grep -q 'REF: "The Hidden Cost of LLM Routing' "$u" \
            || { echo "FAIL: ${unit} lacks the source reference"; status=1; }
    done <<< "$_LANE_SPECS"
    [[ "$status" -eq 0 ]] || return 1
}

@test "metrics: the constants lane table is the same five units and ports as the units" {
    # `model lanes` iterates LLAMA_LANE_SPECS.  If it drifted it would either drop
    # a lane from the report or query a port nobody serves — both silent.
    local table
    table=$(awk '/^export LLAMA_LANE_SPECS="/ { f=1; sub(/^export LLAMA_LANE_SPECS="/, "") }
                 f { if (sub(/"$/, "")) { print; exit } print }' "$CONSTANTS")
    [[ -n "$table" ]] || { echo "FAIL: 01-constants declares no LLAMA_LANE_SPECS"; return 1; }
    [[ "$(printf '%s\n' "$table" | sort)" == "$(printf '%s\n' "$_LANE_SPECS" | sort)" ]] \
        || { echo "the lane table and the units disagree:"; diff \
             <(printf '%s\n' "$_LANE_SPECS" | sort) <(printf '%s\n' "$table" | sort); return 1; }
}

@test "metrics: the serve arm emits --metrics and the bench arm does not" {
    run _build_argv
    [[ "$status" -eq 0 ]]
    [[ "$(printf '%s\n' "$output" | grep -c -x -- '--metrics')" -eq 1 ]] \
        || { echo "FAIL: the serve argv does not carry exactly one --metrics:"; printf '%s\n' "$output"; return 1; }

    # The bench argv is a certified measurement contract; it must keep reproducing
    # the argv the autotune certifies, which has no --metrics.
    run _build_argv "" bench
    [[ "$status" -eq 0 ]]
    [[ "$output" != *"--metrics"* ]] \
        || { echo "FAIL: the bench argv gained --metrics; the certified argv moved"; return 1; }
}

@test "metrics: the reader parses an exposition body into cached/total prompt tokens" {
    cat > "$MOCK_STATE/metrics_body" <<'METRICS'
# HELP llamacpp:prompt_tokens_total Number of prompt tokens processed, excluding cached tokens
# TYPE llamacpp:prompt_tokens_total counter
llamacpp:prompt_tokens_total 300
# HELP llamacpp:prompt_tokens_cached_total Number of prompt tokens reused from the cache
# TYPE llamacpp:prompt_tokens_cached_total counter
llamacpp:prompt_tokens_cached_total 700
METRICS
    printf '%s\n' "Wed 2026-10-21 10:00:00 BST" > "$MOCK_STATE/active_enter"

    run _cached_rate 18081 llama-xe-minicpm5-1b-chat.service
    [[ "$status" -eq 0 ]]
    # prompt_tokens_total EXCLUDES cached tokens (its own HELP line says so), so the
    # queried total is 700 + 300, and the rate is 70% — not 233%.
    [[ "$output" == "700/1000 prompt tokens (70%) since 2026-10-21 10:00 BST (server start)" ]] \
        || { echo "FAIL: unexpected reading: $output"; return 1; }
}

@test "metrics: a counter rendered in scientific notation is still measured" {
    # Prometheus renders these as doubles, so a six-figure count arrives as 1.2e+06.
    printf 'llamacpp:prompt_tokens_total 1.2e+06\nllamacpp:prompt_tokens_cached_total 3e+05\n' \
        > "$MOCK_STATE/metrics_body"

    run _cached_rate 18081
    [[ "$status" -eq 0 ]]
    [[ "$output" == "300000/1500000 prompt tokens (20%) since server start (start time unavailable)" ]] \
        || { echo "FAIL: scientific-notation counters misread: $output"; return 1; }
}

@test "metrics: an absent endpoint is not-measured, never 0" {
    rm -f "$MOCK_STATE/metrics_body"

    run _cached_rate 18081
    [[ "$status" -eq 0 ]]
    [[ "$output" == "not-measured" ]]
    [[ "$output" != *"0/"* ]]
}

@test "metrics: a body without the counters is not-measured, never 0" {
    # A 200 from a build without --metrics, or any other body: the absence of both
    # counters is not evidence of a cold cache.
    printf '# HELP llamacpp:requests_processing Requests processing\nllamacpp:requests_processing 0\n' \
        > "$MOCK_STATE/metrics_body"

    run _cached_rate 18081
    [[ "$status" -eq 0 ]]
    [[ "$output" == "not-measured" ]]
}

@test "metrics: a measured 0/0 is a different state from not-measured" {
    printf 'llamacpp:prompt_tokens_total 0\nllamacpp:prompt_tokens_cached_total 0\n' \
        > "$MOCK_STATE/metrics_body"

    run _cached_rate 18081
    [[ "$status" -eq 0 ]]
    [[ "$output" == "0/0 prompt tokens (no requests yet)"* ]] \
        || { echo "FAIL: a measured zero was not reported as such: $output"; return 1; }
    [[ "$output" != "not-measured" ]]
}

# ── the KV-quant eligibility gate ────────────────────────────────────────────
# The gate is a function, so the decision itself is exercised; the SWEEP's use of
# it is pinned separately (it lives in a loop that needs a GPU to run).
@test "kv-quant: the gate certifies q8_0 and refuses an uncertified pair with a reason" {
    awk '/^KV_CERTIFIED_PAIRS=/,/^}/' "$AUTOTUNE" > "$SANDBOX/kvgate.sh"
    grep -q 'kv_pair_status' "$SANDBOX/kvgate.sh" || { echo "FAIL: gate not extracted"; return 1; }

    cat > "$SANDBOX/gate-run.sh" <<'EOS'
set -uo pipefail
source "$1"
kv_pair_status "$2" "$3"
EOS
    run bash "$SANDBOX/gate-run.sh" "$SANDBOX/kvgate.sh" q8_0 q8_0
    [[ "$status" -eq 0 ]]
    [[ "$output" == "certified" ]]

    run bash "$SANDBOX/gate-run.sh" "$SANDBOX/kvgate.sh" q4_0 q4_0
    [[ "$status" -eq 0 ]]
    [[ "$output" != "certified" ]]
    [[ "$output" == *"not eligible"* ]]
    [[ "$output" == *"no long-context retrieval validation"* ]]

    # A MIXED pair is not certified either: certification is per pair, not per type.
    run bash "$SANDBOX/gate-run.sh" "$SANDBOX/kvgate.sh" q4_0 q8_0
    [[ "$output" != "certified" ]]
}

@test "kv-quant: the sweep prints a refusal for a refused pair instead of dropping it" {
    # The region between the candidate loop's header and its `done`, which is where
    # the narrowing happens.  Both the gate call and the reason text must be inside
    # it: a pair removed from the list with no line saying why is indistinguishable
    # from a pair nobody configured — the silent failure this gate exists to stop.
    awk '/^    for _pair in \$KV_QUANTS; do/,/^    done$/' "$AUTOTUNE" > "$SANDBOX/sweeploop.sh"
    grep -q 'kv_pair_status' "$SANDBOX/sweeploop.sh" \
        || { echo "FAIL: the sweep does not consult the eligibility gate"; return 1; }
    grep -q 'NOT TESTED' "$SANDBOX/sweeploop.sh" \
        || { echo "FAIL: a refused pair is dropped without a printed reason"; return 1; }
    grep -q '\$_kv_status' "$SANDBOX/sweeploop.sh" \
        || { echo "FAIL: the refusal does not print the gate's reason"; return 1; }
}

@test "kv-quant: q4_0 stays a configured candidate, so the refusal path stays reachable" {
    # If q4_0 were removed from the candidate list the gate would never fire and the
    # "why" line would never print; the list is intent, the gate is the evidence.
    grep -q 'LLM_AUTOTUNE_KV_QUANTS:-q8_0/q8_0 q4_0/q4_0' "$ENV_SH"
}

# ── the watchdog's driver-level classification ───────────────────────────────
_classify_probe_count() {
    if [[ -f "$MOCK_STATE/classify-calls" ]]; then
        wc -l < "$MOCK_STATE/classify-calls" | tr -d ' '
    else
        echo 0
    fi
}

@test "gpu-classify: a driver-level fail-closed is classified and named in the log" {
    rm -f "$MOCK_STATE/classify-calls"
    touch "$MOCK_STATE/busy"
    printf '%s\n' "nvidia-smi-unavailable" > "$MOCK_STATE/gpu_reason"
    cat > "$MOCK_STATE/gpu_check.json" <<'JSON'
{"state":"unavailable","reason":"NVML: GPU access blocked by the operating system (rc=255)","smi_rc":255,"devices":0,"window_min":30,"dxg_failures":3,"wsl_crashes":2}
JSON

    run "$WATCHDOG"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"classified UNAVAILABLE"* ]] \
        || { echo "the driver fault was not named: $output"; return 1; }
    [[ "$output" == *"GPU access blocked by the operating system"* ]]
    [[ "$output" == *"dxg=3 crash=2"* ]]
    # The busy line is still there, and the stop still happened: the classification
    # is an addition to the record, not a change of behaviour.
    [[ "$output" == *"GPU busy — stopping llama-cuda-llama32-3b-chat"* ]]
    grep -q 'stop llama-cuda-llama32-3b-chat.service' "$MOCK_STATE/systemctl.log"
    # And it never actuates: the classifier's run adds no systemctl verb of its own.
    [[ "$(grep -c 'stop ' "$MOCK_STATE/systemctl.log")" -eq 1 ]]
}

@test "gpu-classify: the verdict says the card is in use when the driver still answers" {
    rm -f "$MOCK_STATE/classify-calls"
    touch "$MOCK_STATE/busy"
    printf '%s\n' "nvidia-smi-unavailable" > "$MOCK_STATE/gpu_reason"
    cat > "$MOCK_STATE/gpu_check.json" <<'JSON'
{"state":"ok","reason":"nvidia-smi ok (1 device(s))","smi_rc":0,"devices":1,"window_min":30,"dxg_failures":0,"wsl_crashes":0}
JSON

    run "$WATCHDOG"

    [[ "$output" == *"classified OK"* ]]
    [[ "$output" != *"classified UNAVAILABLE"* ]]
}

@test "gpu-classify: a busy card with a working driver is never sent to the classifier" {
    rm -f "$MOCK_STATE/classify-calls"
    touch "$MOCK_STATE/busy"
    # The reason a genuinely busy card produces: the driver answered.
    printf '%s\n' "util=90%>=15%" > "$MOCK_STATE/gpu_reason"

    run "$WATCHDOG"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"GPU busy — stopping llama-cuda-llama32-3b-chat"* ]]
    [[ "$output" != *"driver-level"* ]]
    [[ "$(_classify_probe_count)" -eq 0 ]] \
        || { echo "a busy card was probed as if its driver were broken"; return 1; }
}

@test "gpu-classify: a broken GPU is probed at most once per hold window" {
    rm -f "$MOCK_STATE/classify-calls"
    touch "$MOCK_STATE/busy"
    printf '%s\n' "nvidia-smi-unavailable" > "$MOCK_STATE/gpu_reason"
    cat > "$MOCK_STATE/gpu_check.json" <<'JSON'
{"state":"unavailable","reason":"nvidia-smi crashed (SIGSEGV, rc=139)","smi_rc":139,"devices":0,"window_min":30,"dxg_failures":1,"wsl_crashes":1}
JSON
    local now until window

    run "$WATCHDOG"
    [[ "$output" == *"classified UNAVAILABLE"* ]]
    [[ "$(_classify_probe_count)" -eq 1 ]]

    # The hold is written, and its window is the file's existing cooling-off window
    # (FLAP_HOLD_S) rather than a second, invented one — so a broken GPU costs one
    # crashing probe per window, not one per 5-minute tick.
    [[ -f "$LLAMA_WATCHDOG_GPU_CLASSIFY_FILE" ]]
    grep -q 'GPU_CLASSIFY_WINDOW_S="${LLAMA_WATCHDOG_GPU_CLASSIFY_WINDOW_S:-$FLAP_HOLD_S}"' "$WATCHDOG"
    now=$(date +%s)
    until=$(cat "$LLAMA_WATCHDOG_GPU_CLASSIFY_FILE")
    [[ "$until" =~ ^[0-9]+$ ]]
    window=$(( until - now ))
    (( window > 60 && window <= 1800 )) \
        || { echo "hold window out of range: ${window}s"; return 1; }

    # Second tick inside the window: the lane is still held down, and the probe is not
    # repeated (it is a crashing nvidia-smi that WSL captures as a core dump).
    run "$WATCHDOG"
    [[ "$output" == *"GPU busy — stopping llama-cuda-llama32-3b-chat"* ]]
    [[ "$output" != *"classified"* ]]
    [[ "$(_classify_probe_count)" -eq 1 ]] \
        || { echo "the classifier was re-probed inside the hold window"; return 1; }

    # Past the window (the hold is what suppresses the probe, so lifting it must let
    # the next tick classify again).
    rm -f "$LLAMA_WATCHDOG_GPU_CLASSIFY_FILE"
    run "$WATCHDOG"
    [[ "$(_classify_probe_count)" -eq 2 ]]
}

@test "gpu-classify: a missing classifier warns, and never blocks or silences the lane" {
    rm -f "$MOCK_STATE/classify-calls"
    touch "$MOCK_STATE/busy"
    printf '%s\n' "nvidia-smi-unavailable" > "$MOCK_STATE/gpu_reason"
    # A box without the classifier (or with an unreadable one) cannot classify the
    # reason — and that must be SAID.  The failure mode this pins: a classifier that
    # cannot run leaving the reader with the bare "GPU busy" the card is about, i.e.
    # silence where the answer was "we do not know".
    export LLAMA_WATCHDOG_GPU_CHECK="$SANDBOX/no-such-classifier.sh"

    run "$WATCHDOG"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"could not decide"* ]] \
        || { echo "a missing classifier was silent: $output"; return 1; }
    [[ "$output" == *"UNCONFIRMED"* ]]
    # The lane decision is untouched by the classification: same stop, one verb.
    [[ "$output" == *"GPU busy — stopping llama-cuda-llama32-3b-chat"* ]]
    grep -q 'stop llama-cuda-llama32-3b-chat.service' "$MOCK_STATE/systemctl.log"
    # ...and the hold is still stamped, so a broken classifier does not mean a
    # failed exec on every tick.
    [[ -f "$LLAMA_WATCHDOG_GPU_CLASSIFY_FILE" ]]
    unset LLAMA_WATCHDOG_GPU_CHECK
}

# ── the repo-owned GPU-watch self-check ──────────────────────────────────────
# The check reads an automation's state, so the fixture is the automation JSON and
# the `openclaw` in front of it.  Keys deliberately mirror the real shape, including
# the keys that appear TWICE (inside `state` and at the top level) — reading those
# without head -1 is what made the first version of the script report a healthy
# automation as never-run.
_selfcheck_fixture() {
    local _file="$SANDBOX/openclaw-mock"
    cat > "$_file" <<'MOCK'
#!/usr/bin/env bash
[[ -n "${SELFCHECK_RC:-}" ]] && exit "$SELFCHECK_RC"
cat "$SELFCHECK_FIXTURE"
MOCK
    chmod +x "$_file"
    printf '%s\n' "$_file"
}

# _selfcheck_json <lastRunStatus> <enabled> <lastRunAtMs> <nextRunAtMs> — the
# automation JSON, in the shape the live one has (including the duplicate keys).
_selfcheck_json() {
    local _status="$1" _enabled="$2" _last_ms="$3" _next_ms="$4"
    cat > "$SELFCHECK_FIXTURE" <<JSON
{
  "id": "6a1b0ada-eae2-48e9-905a-78a74ba98549",
  "name": "GPU Passthrough Watch",
  "enabled": ${_enabled},
  "schedule": { "kind": "every", "everyMs": 900000 },
  "state": {
    "nextRunAtMs": ${_next_ms},
    "lastRunAtMs": ${_last_ms},
    "lastRunStatus": "${_status}",
    "lastStatus": "${_status}"
  },
  "nextRunAtMs": ${_next_ms},
  "lastRunAtMs": ${_last_ms},
  "lastRunStatus": "${_status}"
}
JSON
}

setup_selfcheck() {
    export SELFCHECK_FIXTURE="$SANDBOX/automation.json"
    GPU_WATCH_SELFCHECK_OPENCLAW="$(_selfcheck_fixture)"
    export GPU_WATCH_SELFCHECK_OPENCLAW
    # The transition state lives in the sandbox, not the developer's ~/.cache: a case
    # that read the real file would pass or fail depending on what ran before it.
    #
    # Removed here rather than merely pointed at the sandbox: this suite builds ONE
    # SANDBOX for the whole file (setup_file/teardown_file), so without this a case
    # inherits the state the previous case announced and sees a transition that never
    # happened — measured 2026-09-24, which is what made the second --announce case
    # report a spurious "RECOVERED".
    export GPU_WATCH_SELFCHECK_STATE_FILE="$SANDBOX/selfcheck.state"
    rm -f "$GPU_WATCH_SELFCHECK_STATE_FILE"
    unset SELFCHECK_RC
    # Same reason as the state file: a case that set the readiness wait must not leak it into
    # the next one (the automation and a human run leave it unset, so that is the default here).
    unset GPU_WATCH_SELFCHECK_READY_WAIT_S GPU_WATCH_SELFCHECK_READY_INTERVAL_S SELFCHECK_COUNTER
}

@test "gpu-watch-selfcheck: a healthy automation is silent and exits 0" {
    setup_selfcheck
    local now_ms
    now_ms=$(( $(date +%s) * 1000 ))
    _selfcheck_json ok true "$(( now_ms - 60000 ))" "$(( now_ms + 840000 ))"

    run "$SELFCHECK"
    [[ "$status" -eq 0 ]]
    # Silence is the healthy answer: this is an automation announce payload, and a
    # routine "fine" line every 15 minutes is what hides the real alarm.
    [[ -z "$output" ]]

    # ...and the machine-readable verdict says so explicitly.
    run "$SELFCHECK" --json
    [[ "$status" -eq 0 ]]
    [[ "$output" == *'"state":"ok"'* ]]
}

@test "gpu-watch-selfcheck: a never-run and a stale automation both alarm" {
    setup_selfcheck
    local now_ms
    now_ms=$(( $(date +%s) * 1000 ))

    # Configured, nothing has ever run: the case this check exists for.
    _selfcheck_json ok true 0 "$(( now_ms + 900000 ))"
    run "$SELFCHECK"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"no run is recorded at all"* ]]

    # Running but stopped: the last run is far beyond the staleness bound.
    _selfcheck_json ok true "$(( now_ms - 9000000 ))" "$(( now_ms - 8000000 ))"
    run "$SELFCHECK"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"schedule has stopped firing"* ]]

    # The bound is max(2 x everyMs, the 7200 s maintenance-window FLOOR), so a 15-minute
    # schedule gets 7200 s — not 1800 s.
    _selfcheck_json ok true "$(( now_ms - 1200000 ))" "$(( now_ms + 300000 ))"
    run "$SELFCHECK" --json
    [[ "$status" -eq 0 ]]
    [[ "$output" == *'"max_age_s":7200'* ]]

    # The regression this floor exists for (2026-09-30): a planned Gateway outage left a
    # 45-minute run gap (2700 s), which the old 1800 s bound reported as "stale" — a
    # planned outage announced as a fault.  It must NOT alarm.
    _selfcheck_json ok true "$(( now_ms - 2700000 ))" "$(( now_ms + 300000 ))"
    run "$SELFCHECK" --json
    [[ "$status" -eq 0 ]]
    [[ "$output" == *'"state":"ok"'* ]]
}

@test "gpu-watch-selfcheck: a failed, disabled or unreadable automation is not a green answer" {
    setup_selfcheck
    local now_ms
    now_ms=$(( $(date +%s) * 1000 ))

    _selfcheck_json error true "$(( now_ms - 60000 ))" "$(( now_ms + 840000 ))"
    run "$SELFCHECK"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"lastRunStatus=error"* ]]

    # Disabled is an alarm, and the message names the cause rather than sending the
    # reader after a fault: it is as blind as a broken one.
    _selfcheck_json ok false "$(( now_ms - 60000 ))" "$(( now_ms + 840000 ))"
    run "$SELFCHECK"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"DISABLED"* ]]

    # The check itself failing must never read as "the watcher is fine".
    unset SELFCHECK_FIXTURE
    export SELFCHECK_RC=7
    run "$SELFCHECK"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"cannot see the watcher"* ]]
}

@test "gpu-watch-selfcheck --announce: a standing alarm is announced once, not every tick" {
    # The automation runs every 6h and delivers stdout, so repeating an unchanged
    # alarm is a message every 6h for one condition — the noise that teaches a reader
    # to ignore the channel.  A TRANSITION is what gets delivered.
    setup_selfcheck
    local now_ms
    now_ms=$(( $(date +%s) * 1000 ))
    _selfcheck_json ok true 0 "$(( now_ms + 900000 ))"          # never-run: an alarm

    run "$SELFCHECK" --announce
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"no run is recorded at all"* ]]

    # The same state again: nothing is DELIVERED, but the verdict is unchanged.  The two
    # are independent on purpose (Wayne's call, 2026-09-24): the channel carries one
    # message per transition, while the run's status says whether the watcher is healthy.
    run "$SELFCHECK" --announce
    [[ "$status" -eq 1 ]]
    [[ -z "$output" ]]

    # A DIFFERENT alarm is a transition, so it is delivered — and it is still an error.
    _selfcheck_json ok false "$(( now_ms - 60000 ))" "$(( now_ms + 840000 ))"
    run "$SELFCHECK" --announce
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"DISABLED"* ]]
}

@test "gpu-watch-selfcheck --announce: a recovery is announced, a healthy first run is not" {
    setup_selfcheck
    local now_ms
    now_ms=$(( $(date +%s) * 1000 ))

    # No recorded state and nothing wrong: an "all fine" line here would open the
    # channel with noise, which is what the check is supposed to avoid.
    _selfcheck_json ok true "$(( now_ms - 60000 ))" "$(( now_ms + 840000 ))"
    run "$SELFCHECK" --announce
    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]]

    # Alarm (delivered) -> same alarm (silent) -> healthy: the last one is a transition
    # too, or the channel reports a fault and never reports that it cleared.
    _selfcheck_json ok true 0 "$(( now_ms + 900000 ))"
    run "$SELFCHECK" --announce
    [[ "$output" == *"no run is recorded at all"* ]]
    run "$SELFCHECK" --announce
    [[ -z "$output" ]]
    _selfcheck_json ok true "$(( now_ms - 60000 ))" "$(( now_ms + 840000 ))"
    run "$SELFCHECK" --announce
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"RECOVERED"* ]]
}

@test "gpu-watch-selfcheck --announce: an unreadable automation is announced, and exits 2" {
    # The same verdict mapping as every other mode: a check that cannot see the watcher
    # must not report a healthy RUN either — that is the whole difference between "the
    # command ran" and "the watcher is fine", and Wayne asked for the status to carry the
    # second (2026-09-24).
    setup_selfcheck
    unset SELFCHECK_FIXTURE
    export SELFCHECK_RC=7

    run "$SELFCHECK" --announce
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"cannot see the watcher"* ]]
}

@test "gpu-watch-selfcheck: the readiness wait rides out a Gateway that is not serving yet" {
    # A boot, or a Gateway restart, leaves the control plane unreachable for minutes.  The
    # systemd unit sets a bounded readiness wait so that window is not reported as an unreadable
    # WATCHER — measured 2026-10-11, the unit reddened on 6/6 boots.  Here the fixture fails the
    # first two reads, then serves: the check must retry and end HEALTHY, not alarm.
    setup_selfcheck
    export SELFCHECK_COUNTER="$SANDBOX/ready.counter"
    rm -f "$SELFCHECK_COUNTER"
    cat > "$SANDBOX/openclaw-ready" <<'MOCK'
#!/usr/bin/env bash
n=$(cat "$SELFCHECK_COUNTER" 2>/dev/null || echo 0)
if (( n < 2 )); then printf '%s\n' "$(( n + 1 ))" > "$SELFCHECK_COUNTER"; exit 3; fi
cat "$SELFCHECK_FIXTURE"
MOCK
    chmod +x "$SANDBOX/openclaw-ready"
    export GPU_WATCH_SELFCHECK_OPENCLAW="$SANDBOX/openclaw-ready"
    export GPU_WATCH_SELFCHECK_READY_WAIT_S=10
    export GPU_WATCH_SELFCHECK_READY_INTERVAL_S=1

    local now_ms
    now_ms=$(( $(date +%s) * 1000 ))
    _selfcheck_json ok true "$(( now_ms - 60000 ))" "$(( now_ms + 840000 ))"

    run "$SELFCHECK"
    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]]
    # It really did retry rather than pass on the first look: the counter advanced past both
    # failing reads before the fixture was served.
    [[ "$(cat "$SELFCHECK_COUNTER")" -ge 2 ]]
}

@test "gpu-watch-selfcheck: with no readiness wait set an unreadable read is immediate" {
    # No wait is the DEFAULT — the automation runs every tick and must not stall, and a human
    # running the script must not sit for minutes.  A broken read returns at once.
    setup_selfcheck
    unset SELFCHECK_FIXTURE
    export SELFCHECK_RC=7

    local start elapsed
    start=$(date +%s)
    run "$SELFCHECK"
    elapsed=$(( $(date +%s) - start ))
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"cannot see the watcher"* ]]
    [[ "$elapsed" -lt 5 ]]
}

@test "gpu-watch-selfcheck: the readiness wait is bounded, so a still-dead Gateway still reports" {
    # The wait must END.  A Gateway that never serves must still produce the unreadable verdict
    # (exit 2), or the unit would hang instead of reporting a fault.  wait=3s, interval=1s.
    setup_selfcheck
    unset SELFCHECK_FIXTURE
    export SELFCHECK_RC=7
    export GPU_WATCH_SELFCHECK_READY_WAIT_S=3
    export GPU_WATCH_SELFCHECK_READY_INTERVAL_S=1

    local start elapsed
    start=$(date +%s)
    run "$SELFCHECK"
    elapsed=$(( $(date +%s) - start ))
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"cannot see the watcher"* ]]
    [[ "$elapsed" -ge 2 ]]   # it waited...
    [[ "$elapsed" -le 8 ]]   # ...but gave up at the deadline
}

@test "gpu-watch-selfcheck: --version reports its own module-version marker" {
    # The two had drifted: the script printed "4" while its marker said 5.  --version reads the
    # marker now, so a check-module-versions.sh bump and the reported version cannot disagree.
    local marker
    marker=$(sed -n 's/^# Module Version: //p' "$SELFCHECK" | head -1)
    [[ -n "$marker" ]]
    run "$SELFCHECK" --version
    [[ "$status" -eq 0 ]]
    [[ "$output" == "gpu-watch-selfcheck $marker" ]]
}

# end of file
