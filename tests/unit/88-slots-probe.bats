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
    run env TAC_PYTHON="$REPO_ROOT/.venv/bin/python3" \
        bash -c 'source "$1"; _summarise "$2" 262144 4,8,16' _ "$TMP/summarise.sh" "$TMP/out"
    [ "$status" -eq 0 ]
    [[ "$output" == *"120.50"* ]]
    [[ "$output" == *"210.25"* ]]
    [[ "$output" == *"30.10"* ]]
    # 262144 ctx over 4 slots is 64 MiB per slot; over 8 it is 32 MiB.
    [[ "$output" == *"64 MiB"* ]]
    [[ "$output" == *"32 MiB"* ]]
    # Arm 16 was REQUESTED and produced no artifact: it must be named, not omitted.
    [[ "$output" == *"NOT-RUN"* ]]
    # The JSON is written beside the arms and names all three requested counts.
    [ -f "$TMP/out/summary.json" ]
    run grep -c '"slots"' "$TMP/out/summary.json"
    [ "$output" -eq 3 ]
}
