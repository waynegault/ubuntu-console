#!/usr/bin/env bats
# ==============================================================================
# slots-probe.sh — the slot-count sweep (vLLM lesson: concurrency is the lever)
#
# The lane serves --parallel 4 because Wayne asked for at least four slots; nothing has
# measured whether 8 or 16 earns its KV.  A vLLM recipe on the same silicon runs
# max-num-seqs 16 and reports 65.75 -> 233.63 tok/s from concurrency 1 to 16.
#
# These cases pin the parts that decide the ANSWER without touching the card: the plan
# (which arms, and the argv rewrite that must not duplicate --parallel), the refusals,
# and the summary arithmetic.  The measurement itself needs the GPU and is the probe's
# job, not a unit test's.
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
PROBE="$REPO_ROOT/scripts/slots-probe.sh"

setup() {
    TMP="$(mktemp -d)"
    mkdir -p "$TMP/bin"
    # A stub systemctl: the lane's ExecStart, and a log of every stop/start so a dry run
    # can be proved to have touched nothing.
    cat > "$TMP/bin/systemctl" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
case "$*" in
    *"show"*"ExecStart"*)
        printf '%s\n' '{ path=/home/wayne/.local/bin/llama-cuda-server ; argv[]=/home/wayne/.local/bin/llama-cuda-server -m /models/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf --alias qwen3-coder-30b-gpu --port 18087 --ctx-size 262144 --parallel 4 --kv-unified ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }'
        ;;
esac
exit 0
EOS
    chmod +x "$TMP/bin/systemctl"
    : > "$TMP/systemctl.log"
    export SYSTEMCTL_LOG="$TMP/systemctl.log"
}

teardown() {
    rm -rf "$TMP"
}

@test "slots-probe: the dry run plans every arm and rewrites --parallel, never duplicates it" {
    run env PATH="$TMP/bin:$PATH" SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
        bash "$PROBE" --unit llama-cuda-qwen3coder-30b-chat.service --values 4,8,16 --dry-run
    [ "$status" -eq 0 ]
    # The base argv is the lane's own, with --parallel STRIPPED: a duplicate would be the
    # malformed-arm shape cache-ram-probe.sh records.
    [[ "$output" == *"base:"* ]]
    base_line="$(printf '%s\n' "$output" | grep '  base:')"
    [[ "$base_line" != *"--parallel"* ]]
    # One arm per requested slot count, each carrying its own --parallel.
    [[ "$output" == *"arm 4:"*"--parallel 4"* ]]
    [[ "$output" == *"arm 8:"*"--parallel 8"* ]]
    [[ "$output" == *"arm 16:"*"--parallel 16"* ]]
    # The lane's own settings survive the rewrite; the two flags every arm restates are
    # stripped from the base, because a duplicate is the malformed-arm shape.
    [[ "$base_line" == *"--ctx-size 262144"* ]]
    [[ "$base_line" != *"--kv-unified"* ]]
    [[ "$output" == *"arm 4:"*"--kv-unified"* ]]
}

@test "slots-probe: a dry run stops and starts nothing" {
    run env PATH="$TMP/bin:$PATH" SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
        bash "$PROBE" --unit llama-cuda-qwen3coder-30b-chat.service --dry-run
    [ "$status" -eq 0 ]
    # Catches: a "dry" run that restarts the operator's serving lane.
    ! grep -qE '(^| )stop( |$)|(^| )start( |$)' "$SYSTEMCTL_LOG"
}

@test "slots-probe: a zero or non-numeric slot count is refused, not skipped" {
    # Catches: an arm that silently vanishes, which reads as "measured and equal".
    run env PATH="$TMP/bin:$PATH" SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
        bash "$PROBE" --unit u.service --values 0 --dry-run
    [ "$status" -eq 2 ]
    [[ "$output" == *"not a positive integer"* ]]
    run env PATH="$TMP/bin:$PATH" SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
        bash "$PROBE" --unit u.service --values 4,x --dry-run
    [ "$status" -eq 2 ]
}

@test "slots-probe: an unknown flag is a usage error" {
    run env PATH="$TMP/bin:$PATH" SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
        bash "$PROBE" --unit u.service --nonsense
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown argument"* ]]
}

@test "slots-probe: the restore waits for the port and clears a rate limit before starting" {
    # Measured 2026-11-09 on the first real run: the trap started the lane while 18087 was
    # still bound, llama-server died with "couldn't bind HTTP server socket" six times, systemd
    # rate-limited the unit into `failed`, and the fleet's primary lane stayed DOWN.  Catches:
    # a restore that starts first and waits never.
    cat > "$TMP/bin/ss" <<'EOS'
#!/usr/bin/env bash
n=$(( $(cat "$SS_COUNT" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "$n" > "$SS_COUNT"
printf 'ss %s\n' "$n" >> "$SYSTEMCTL_LOG"
(( n <= 2 )) && printf 'LISTEN 0 128 127.0.0.1:18087 0.0.0.0:*\n'
exit 0
EOS
    chmod +x "$TMP/bin/ss"
    : > "$TMP/ss.count"
    awk '/^_wait_listen_free\(\)/,/^}/' "$PROBE" > "$TMP/restore.sh"
    awk '/^_restore_lane\(\)/,/^}/' "$PROBE" >> "$TMP/restore.sh"
    grep -q '_restore_lane' "$TMP/restore.sh" || { echo "helper not found"; return 1; }
    run env PATH="$TMP/bin:$PATH" SYSTEMCTL_LOG="$SYSTEMCTL_LOG" SS_COUNT="$TMP/ss.count" \
        bash -c 'source "$1"; PORT=18087; UNIT=u.service; LANE_STOPPED=1
                 warn() { printf "%s\n" "$*" >&2; }; _restore_lane' _ "$TMP/restore.sh"
    [ "$status" -eq 0 ]
    # The port was polled until free (two bound polls, then free) before the start.
    [ "$(cat "$TMP/ss.count")" -ge 3 ]
    # reset-failed comes BEFORE start, or the start is refused by the rate limit.
    reset_line="$(grep -n 'reset-failed' "$SYSTEMCTL_LOG" | cut -d: -f1 | head -1)"
    start_line="$(grep -n ' start ' "$SYSTEMCTL_LOG" | cut -d: -f1 | head -1)"
    [ -n "$reset_line" ] && [ -n "$start_line" ] && [ "$reset_line" -lt "$start_line" ]
}

@test "slots-probe: the summary voids an arm whose aggregate cannot be true" {
    # Measured 2026-11-09 on the second real run: arm 4 read aggregate 2.43 against
    # per-stream 4.72.  A group total cannot be below one stream's own median, so that arm is
    # not a slow slot count — it is a voided measurement.  Catches: a rate that cannot exist
    # printed in a table as if it were data.
    mkdir -p "$TMP/void"
    cat > "$TMP/void/arm-4.json" <<'JSON'
{"workloads":[{"summary":{"concurrency_group_decode_tokens_per_second":{"median":2.43},
                          "decode_tokens_per_second":{"median":4.72}},
               "groups":[{"warmup":false,"decode_tokens_per_second":5.52},
                         {"warmup":false,"decode_tokens_per_second":1.96},
                         {"warmup":false,"decode_tokens_per_second":2.43}]}]}
JSON
    awk '/^_summarise\(\)/,/^}/' "$PROBE" > "$TMP/sum2.sh"
    run env TAC_PYTHON="$REPO_ROOT/.venv/bin/python3" \
        bash -c 'source "$1"; _summarise "$2" 262144 4' _ "$TMP/sum2.sh" "$TMP/void"
    [ "$status" -eq 0 ]
    # The row itself must read VOID, never the bogus numbers — those survive only inside the
    # evidence text that names them as impossible.
    ! printf '%s\n' "$output" | grep -qE '^ *4 +2\.43 +4\.72'
    [[ "$output" == *"VOID"* ]]
    [[ "$output" == *"impossible"* ]]
    run grep -c '"suspect"' "$TMP/void/summary.json"
    [ "$output" -eq 1 ]
}

@test "slots-probe: a healthy arm with a tight group spread is NOT voided" {
    # The null arm: the first (load ~3.5) run's arm 16 was [165.25, 163.48, 161.93] — a 2%
    # spread — and must print as data, or the void rule eats good measurements.
    mkdir -p "$TMP/ok"
    cat > "$TMP/ok/arm-16.json" <<'JSON'
{"workloads":[{"summary":{"concurrency_group_decode_tokens_per_second":{"median":163.4763},
                          "decode_tokens_per_second":{"median":13.6332}},
               "groups":[{"warmup":false,"decode_tokens_per_second":165.25},
                         {"warmup":false,"decode_tokens_per_second":163.48},
                         {"warmup":false,"decode_tokens_per_second":161.93}]}]}
JSON
    awk '/^_summarise\(\)/,/^}/' "$PROBE" > "$TMP/sum3.sh"
    run env TAC_PYTHON="$REPO_ROOT/.venv/bin/python3" \
        bash -c 'source "$1"; _summarise "$2" 262144 16' _ "$TMP/sum3.sh" "$TMP/ok"
    [ "$status" -eq 0 ]
    [[ "$output" == *"163.48"* ]]
    [[ "$output" != *"VOID"* ]]
}

@test "slots-probe: the quiet verdict names the term that refuses" {
    # Catches: a probe that measures a busy box and reports the result as clean.  Each term is
    # fed a fixture, so the case decides the answer rather than the host's current load.
    awk '/^_quiet_verdict\(\)/,/^}/' "$PROBE" > "$TMP/quiet.sh"
    grep -q '_quiet_verdict' "$TMP/quiet.sh" || { echo "helper not found"; return 1; }
    cat > "$TMP/bin/nproc" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_CORES:-20}"
EOS
    chmod +x "$TMP/bin/nproc"
    # A box whose pressure is over the threshold refuses, and NAMES that term.  Pressure is
    # overridden as a function so the case decides it, not the live host.
    run env PATH="$TMP/bin:$PATH" FAKE_CORES=4 LLM_AUTOTUNE_PSI_MAX_PCT=0 \
        bash -c 'source "$1"; _cpu_pressure_pct() { printf "42"; }; _quiet_verdict' _ "$TMP/quiet.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"cpu pressure 42%"* ]]
    # An ACTIVE CI runner worker refuses on its own, whatever the load.
    cat > "$TMP/bin/pgrep" <<'EOS'
#!/usr/bin/env bash
printf '2\n'
EOS
    chmod +x "$TMP/bin/pgrep"
    run env PATH="$TMP/bin:$PATH" FAKE_CORES=20 bash -c '
        source "$1"; _cpu_pressure_pct() { printf "0"; }; _quiet_verdict' _ "$TMP/quiet.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"CI runner worker"* ]]
}

@test "slots-probe: the summary reports aggregate and per-stream, and NOT-RUN for a missing arm" {
    # Catches: an arm that never measured being printed as a slot count that measured badly.
    mkdir -p "$TMP/out"
    cat > "$TMP/out/arm-4.json" <<'JSON'
{"workloads":[{"summary":{"concurrency_group_decode_tokens_per_second":{"median":120.5},
                          "decode_tokens_per_second":{"median":30.1}}}]}
JSON
    cat > "$TMP/out/arm-8.json" <<'JSON'
{"workloads":[{"summary":{"concurrency_group_decode_tokens_per_second":{"median":210.25},
                          "decode_tokens_per_second":{"median":26.3}}}]}
JSON
    awk '/^_summarise\(\)/,/^}/' "$PROBE" > "$TMP/summarise.sh"
    grep -q '_summarise' "$TMP/summarise.sh" || { echo "helper not found"; return 1; }
    # Resolve the interpreter the way the script does (slots-probe.sh:53-55).  Sourcing only
    # _summarise leaves that fallback out of scope, so a hardcoded .venv path passed here and
    # failed on the runner, which has no .venv — CI run 42607713123, `not ok 1102`,
    # `[ "$status" -eq 0 ]` failed.
    local py="$REPO_ROOT/.venv/bin/python3"
    [[ -x "$py" ]] || py="$(command -v python3 || true)"
    [ -n "$py" ] || { echo "no python3 to run the summary"; return 1; }
    run env TAC_PYTHON="$py" \
        bash -c 'source "$1"; _summarise "$2" 262144 4,8,16' _ "$TMP/summarise.sh" "$TMP/out"
    [ "$status" -eq 0 ]
    [[ "$output" == *"120.50"* ]]
    [[ "$output" == *"210.25"* ]]
    [[ "$output" == *"30.10"* ]]
    # Catches the mislabel the first real run printed: `ctx / slots / 1024` reported as "MiB".
    # It is neither bytes nor a divided window — every arm passes --kv-unified, so the window
    # is shared.  The table must name the ctx and must NOT invent a per-slot byte figure.
    [[ "$output" == *"ctx=262144 tokens"* ]]
    [[ "$output" == *"shared by all slots"* ]]
    [[ "$output" != *"MiB"* ]]
    # Arm 16 was REQUESTED and produced no artifact: it must be named, not omitted.
    [[ "$output" == *"NOT-RUN"* ]]
    # The JSON is written beside the arms and names all three requested counts.
    [ -f "$TMP/out/summary.json" ]
    run grep -c '"slots"' "$TMP/out/summary.json"
    [ "$output" -eq 3 ]
}
