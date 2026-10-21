#!/usr/bin/env bats
# ==============================================================================
# Unit — the lane prompt-cache sampler
# ==============================================================================
# WHY THIS EXISTS (SWITCH-CONSOLE-METRICS-001 item 3): the card that added
# `--metrics` also asked for a week of per-lane readings before any floor.  The
# counters are cumulative and reset on restart, and `model lanes` samples only
# when a human runs it — so the series needs a collector.  These cases pin the
# collector's three failure modes, all of which are silent:
#
#   1. AN UNREADABLE LANE RECORDED AS 0.  That is the "nothing breaks" shape the
#      metrics card exists to prevent: a 0 reads as a cold cache, so a lane that
#      lost `--metrics` would look healthy and flat.
#   2. A ROW WITHOUT ITS WINDOW.  The counters restart with the process, so a
#      figure with no start time cannot be compared with any other figure.
#   3. A PRUNE THAT DROPS THE HEADER OR KEEPS THE ANCIENT ROWS.  The reader keys
#      on column 1 and the retention bound is days, so a prune that mismatches
#      the writer's format either grows forever or empties the file.
#
# Hermetic: the script takes its lane list, output path, clock and retention
# from env seams, and curl/systemctl are PATH stubs.  No env.sh, no lane, no
# network — the same idiom tests/unit/57 uses for the probe.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    SCRIPT="$REPO_ROOT/bin/llm-lane-cache-sample.sh"
    SANDBOX="$BATS_TEST_TMPDIR/sandbox"
    MOCK_BIN="$SANDBOX/bin"
    STATE="$SANDBOX/state"
    mkdir -p "$MOCK_BIN" "$STATE"

    export TAC_STATE_DIR="$STATE"
    export LLM_LANE_CACHE_FILE="$STATE/llm-lane-cache.tsv"
    export LLM_LANE_CACHE_SPECS=$'unit-a.service|18111\nunit-b.service|18112\nunit-c.service|18113'
    export LLM_LANE_CACHE_NOW=1792597096
    export LLM_LANE_CACHE_RETENTION_DAYS=30
    export PATH="$MOCK_BIN:$PATH"

    cat > "$MOCK_BIN/systemctl" <<'MOCK'
#!/usr/bin/env bash
unit=""
for a in "$@"
do
    case "$a" in *.service) unit="$a" ;; esac
done
case " $* " in
    *" is-active "*)
        case "$unit" in
            unit-b.service) printf 'inactive\n'; exit 3 ;;
            *)              printf 'active\n';   exit 0 ;;
        esac ;;
    *" ActiveEnterTimestamp "*)
        printf 'Mon 2026-10-21 10:00:00 BST\n'
        exit 0 ;;
esac
exit 0
MOCK

    cat > "$MOCK_BIN/curl" <<'MOCK'
#!/usr/bin/env bash
port=""
for a in "$@"
do
    case "$a" in
        http://127.0.0.1:*) port="${a##*:}"; port="${port%%/*}" ;;
    esac
done
case "$port" in
    18111)
        printf 'llamacpp:prompt_tokens_total 300\n'
        printf 'llamacpp:prompt_tokens_cached_total 700\n'
        exit 0 ;;
    18113)
        # A 200 whose body carries neither counter: not a cold cache.
        printf '# HELP llamacpp:requests_processing Requests\n'
        printf 'llamacpp:requests_processing 0\n'
        exit 0 ;;
    *)
        exit 7 ;;
esac
MOCK

    chmod +x "$MOCK_BIN/systemctl" "$MOCK_BIN/curl"
}

@test "sampler: a readable lane records cached, processed and the rate" {
    run bash "$SCRIPT"
    [[ "$status" -eq 0 ]] || { echo "sampler failed: $output"; return 1; }
    local row
    row=$(awk -F'\t' '$3 == "unit-a.service"' "$LLM_LANE_CACHE_FILE")
    [[ -n "$row" ]] || { echo "no row for unit-a"; cat "$LLM_LANE_CACHE_FILE"; return 1; }
    [[ "$(cut -f5 <<< "$row")" == "ok" ]]
    [[ "$(cut -f6 <<< "$row")" == "700" ]]
    [[ "$(cut -f7 <<< "$row")" == "300" ]]
    # 700 / (700 + 300); prompt_tokens_total EXCLUDES cached tokens.
    [[ "$(cut -f8 <<< "$row")" == "70" ]]
    [[ "$(cut -f9 <<< "$row")" == "Mon 2026-10-21 10:00:00 BST" ]]
}

@test "sampler: an inactive lane is named, and its numbers are dashes not zero" {
    run bash "$SCRIPT"
    [[ "$status" -eq 0 ]]
    local row
    row=$(awk -F'\t' '$3 == "unit-b.service"' "$LLM_LANE_CACHE_FILE")
    [[ "$(cut -f5 <<< "$row")" == "inactive" ]]
    [[ "$(cut -f6 <<< "$row")" == "-" ]]
    [[ "$(cut -f7 <<< "$row")" == "-" ]]
    [[ "$(cut -f8 <<< "$row")" == "-" ]]
}

@test "sampler: an unreadable active lane is not-measured, never 0" {
    run bash "$SCRIPT"
    [[ "$status" -eq 0 ]]
    local row
    row=$(awk -F'\t' '$3 == "unit-c.service"' "$LLM_LANE_CACHE_FILE")
    [[ "$(cut -f5 <<< "$row")" == "no-endpoint" ]]
    [[ "$(cut -f6 <<< "$row")" == "-" ]]
    [[ "$row" != *$'\t0\t0\t'* ]] || { echo "an unreadable lane was recorded as 0"; return 1; }
}

@test "sampler: the file is a TSV with one header, not repeated per run" {
    run bash "$SCRIPT"
    run bash "$SCRIPT"
    [[ "$(grep -c '^epoch' "$LLM_LANE_CACHE_FILE")" -eq 1 ]] \
        || { echo "header repeated or missing"; cat "$LLM_LANE_CACHE_FILE"; return 1; }
    [[ "$(awk -F'\t' 'NR > 1 {n++} END {print n+0}' "$LLM_LANE_CACHE_FILE")" -eq 6 ]] \
        || { echo "expected 3 rows per run over 2 runs"; cat "$LLM_LANE_CACHE_FILE"; return 1; }
}

@test "sampler: the prune drops rows past retention and keeps the header and recent rows" {
    local old=$(( LLM_LANE_CACHE_NOW - 31 * 86400 ))
    local recent=$(( LLM_LANE_CACHE_NOW - 86400 ))
    printf 'epoch\tiso\tunit\tport\tstatus\tcached\tprocessed\trate_pct\twindow\n' > "$LLM_LANE_CACHE_FILE"
    printf '%s\t2026-09-20T00:00:00+0100\told.service\t19999\tok\t1\t1\t50\t-\n' "$old" >> "$LLM_LANE_CACHE_FILE"
    printf '%s\t2026-10-20T00:00:00+0100\tkeep.service\t19998\tok\t2\t2\t50\t-\n' "$recent" >> "$LLM_LANE_CACHE_FILE"

    run bash "$SCRIPT"
    [[ "$status" -eq 0 ]]
    grep -q '^epoch' "$LLM_LANE_CACHE_FILE" || { echo "prune dropped the header"; return 1; }
    ! grep -q 'old.service' "$LLM_LANE_CACHE_FILE" || { echo "prune kept a 31-day-old row"; return 1; }
    grep -q 'keep.service' "$LLM_LANE_CACHE_FILE" || { echo "prune dropped a 1-day-old row"; return 1; }
}

@test "sampler: --print reports to stdout and writes no file" {
    run bash "$SCRIPT" --print
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"unit-a.service"* ]]
    [[ ! -e "$LLM_LANE_CACHE_FILE" ]] || { echo "--print created $LLM_LANE_CACHE_FILE"; return 1; }
}

@test "sampler: the hourly timer and its oneshot exist and the timer owns the install" {
    local timer="$REPO_ROOT/systemd/llm-lane-cache-sample.timer"
    local service="$REPO_ROOT/systemd/llm-lane-cache-sample.service"
    [[ -f "$timer" ]] || { echo "missing $timer"; return 1; }
    [[ -f "$service" ]] || { echo "missing $service"; return 1; }
    grep -q '^OnUnitActiveSec=1h' "$timer" || { echo "timer is not hourly"; return 1; }
    grep -q '^WantedBy=timers.target' "$timer" || { echo "timer does not install itself"; return 1; }
    grep -q '^ExecStart=%h/.local/bin/llm-lane-cache-sample.sh' "$service" \
        || { echo "service does not run the sampler"; return 1; }
    # The unit must not start or stop a lane: it is a read.
    ! grep -qE 'systemctl|llama-server' "$service" || { echo "service mutates lanes"; return 1; }
}
