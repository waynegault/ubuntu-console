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
# /health unreachable (exit 22) unless the marker exists; /props empty.  The lanes
# under test are either activating (skipped) or the CUDA lane on a busy GPU, whose
# branch never consults health — so this mock only has to be non-zero.
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
# LLAMA_CACHE_RAM_MB the harness exports before building the argv.
_build_argv() {
    local _cache_ram="${1:-}"
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
unset __BENCH_MODE
__model_use_build_command || { echo "FAIL: builder returned non-zero"; exit 1; }
printf '%s\n' "${cmd[@]}"
EOS
    bash "$SANDBOX/harness.sh" "$SANDBOX/builder.sh" "$_cache_ram"
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
    unset SELFCHECK_RC
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

    # Running but stopped: the last run is far beyond twice the schedule period.
    _selfcheck_json ok true "$(( now_ms - 5000000 ))" "$(( now_ms - 4000000 ))"
    run "$SELFCHECK"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"schedule has stopped firing"* ]]

    # The bound follows the automation's own period (2 x everyMs), so a 15-minute
    # schedule is not called stale at 20 minutes.
    _selfcheck_json ok true "$(( now_ms - 1200000 ))" "$(( now_ms + 300000 ))"
    run "$SELFCHECK" --json
    [[ "$status" -eq 0 ]]
    [[ "$output" == *'"max_age_s":1800'* ]]
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

# end of file
