#!/usr/bin/env bats
# ==============================================================================
# Unit — the health-wait budget follows the checkpoint, not the tier below it
# ==============================================================================
# The failure this file exists for: every model of 3 GB or more was given the same
# 180 s.  On 2026-11-10 a 50.9 GiB BF16 checkpoint became healthy in 171 s with the
# weights warm, and was still loading after 7 minutes beside a CI suite — the wait
# then killed the lane mid-load and reported "FAILED OR TIMEOUT", which reads as a
# broken model rather than a budget that was too small.
#
# What has to stay true:
#   1. A very large checkpoint gets a budget derived from its size, never the flat
#      figure that a 3B model needs.
#   2. The tiers BELOW it are unchanged — this is not a blanket increase.
#   3. The cap is a knob, so a slow disk can be given more headroom without a code
#      change, and an unreadable cap value falls back rather than removing the bound.
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
    # shellcheck source=scripts/11c-llm-server.sh
    source "$REPO_ROOT/scripts/11c-llm-server.sh"
}

@test "health timeout: a 50.9 GiB checkpoint gets a load-sized budget, not 180 s" {
    # 12 s per GiB: a 50 GiB file reads and places far past three minutes.
    run __llm_health_timeout 50.9G 999 "Qwen3.8-27B"
    [ "$status" -eq 0 ]
    [ "$output" = "600" ] || { echo "got '$output' — the 50.9 GiB load kept a small-model budget"; return 1; }
}

@test "health timeout: the tiers below the very-large one are unchanged" {
    # Control: without these, a function that returned 600 for everything would pass.
    run __llm_health_timeout 7.9G 999 "Some 8B"
    [ "$output" = "180" ]
    run __llm_health_timeout 3.5G 999 "Some 3B"
    [ "$output" = "180" ]
    run __llm_health_timeout 0.5G 99 "tiny"
    [ "$output" = "90" ]
    run __llm_health_timeout 1.0G "$_GPU_OFFLOAD_DISABLED" "Some Model"
    [ "$output" = "180" ]
}

@test "health timeout: the very-large tier has a floor and an adjustable cap" {
    # Floor: 15 GiB would be 180 s by the per-GiB rule, which is the figure being fixed.
    run __llm_health_timeout 15.0G 999 "Fifteen"
    [ "$output" = "300" ] || { echo "got '$output' — the tier removed its own floor"; return 1; }
    # Cap: a deliberate ceiling, honoured when set...
    run env LLM_HEALTH_TIMEOUT_MAX=420 bash -c '
        source "$1/scripts/11c-llm-server.sh"
        __llm_health_timeout 50.9G 999 "Qwen3.8-27B"
    ' _ "$REPO_ROOT"
    [ "$output" = "420" ]
    # ...and an unreadable one falls back to the default bound rather than to none.
    run env LLM_HEALTH_TIMEOUT_MAX=soon bash -c '
        source "$1/scripts/11c-llm-server.sh"
        __llm_health_timeout 300.0G 999 "Huge"
    ' _ "$REPO_ROOT"
    [ "$output" = "900" ] || { echo "got '$output' — an unreadable cap removed the bound"; return 1; }
}

@test "health timeout: LLM_HEALTH_TIMEOUT names the budget when the derived one is too small" {
    # The cap can only LOWER the derived figure, so a box whose disk is slower than 12 s/GiB
    # needs an explicit budget.  Fails if: the knob is ignored, or a cap silently outranks it.
    run env LLM_HEALTH_TIMEOUT=1800 bash -c '
        source "$1/scripts/11c-llm-server.sh"
        __llm_health_timeout 50.9G 999 "Qwen3.8-27B"
    ' _ "$REPO_ROOT"
    [ "$output" = "1800" ] || { echo "got '$output' — the explicit budget was ignored"; return 1; }
    # A non-numeric value falls through to the derived budget, not to 0 or an error.
    run env LLM_HEALTH_TIMEOUT=soon bash -c '
        source "$1/scripts/11c-llm-server.sh"
        __llm_health_timeout 50.9G 999 "Qwen3.8-27B"
    ' _ "$REPO_ROOT"
    [ "$output" = "600" ] || { echo "got '$output' — a bad override did not fall through"; return 1; }
}
