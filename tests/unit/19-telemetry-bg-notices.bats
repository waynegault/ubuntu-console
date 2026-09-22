#!/usr/bin/env bats
# ==============================================================================
# Unit — background refresh jobs must not print job-control notices
# ==============================================================================
# Why: bash reports a tracked job at the next command boundary as
# "[n] Done <command>", and <command> is the job's ENTIRE body — for the
# multi-line telemetry refreshes that is dozens of lines of source, dumped over
# the dashboard render right where the next prompt appears (measured
# 2026-09-22: after `m` returned, the whole GPU-refresh text followed the box).
#
# Every spawn is therefore routed through __tac_track_bg_job (§7), which keeps
# the PID in __TAC_BG_PIDS for the EXIT trap's `kill` AND disowns the job so no
# notice is printed.  These cases pin that wiring: a new spawn that registers
# __TAC_BG_PIDS directly, or one that is never tracked, silently reintroduces
# the noise — and nothing else in the suite would notice.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export TELEMETRY="$REPO_ROOT/scripts/07-telemetry.sh"
    export DASHBOARD="$REPO_ROOT/scripts/12-dashboard-help.sh"
}

@test "bg jobs: __TAC_BG_PIDS is registered in exactly one place" {
    # One occurrence across the whole scripts tree, and it is the tracker itself.
    # A second one means a spawn bypasses the disown and will leak into the UI.
    run grep -rn '__TAC_BG_PIDS+=(' "$REPO_ROOT/scripts"

    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 1 ]
    [[ "${lines[0]}" == *"07-telemetry.sh"* ]]
    [[ "${lines[0]}" == *'__TAC_BG_PIDS+=("$1")'* ]]
}

@test "bg jobs: every refresh spawn in sections 7 and 12 is tracked" {
    # A spawn is a line ending in `&>/dev/null &`; the very next line has to be
    # the tracker.  Checking adjacency, not just counts, is what catches a spawn
    # added without one.
    run awk '/&>\/dev\/null &$/ { n = NR + 1
                                  if ((getline nxt) > 0 && nxt !~ /__tac_track_bg_job/)
                                      print FILENAME ":" n ": untracked spawn" }' \
        "$TELEMETRY" "$DASHBOARD"
    [ "$output" = "" ]
}

# end of file
