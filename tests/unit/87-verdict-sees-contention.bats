#!/usr/bin/env bats
# ==============================================================================
# Unit — the certification verdict sees MORE than the load average
# ==============================================================================
# WHY THIS EXISTS (2026-11-08).  `load <= cores` certified two runs that were not quiet,
# and each number then read as a property of the model:
#   2026-11-07 22:14Z  load 3.48 / 8 cores, llama-server 111%, two runners 92%/75%
#   2026-11-08 12:52Z  load 5.12 / 8 cores, 2 CI workers + 1 vitest live
# A run-queue average cannot see a box whose load rides on a FEW saturated threads.
#
# THE NEAR-MISS, PINNED AS CASE 5.  My first design compared /proc/pressure/cpu's window
# average (some avg10) against a ceiling after the bench.  Calibration on this box killed it:
# idle read 1.45 while load sat at 6.95, and a controlled 8-spinner load on 8 cores measured
# 17.31 — but 8 threads on 8 cores is exactly what a LEGITIMATE autotune run looks like
# while it measures.  A window threshold would have refused every honest run.  Hence the
# pressure is sampled BEFORE the server launches, and case 5 fails if anyone moves the read
# back across the launch.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export REPO_ROOT
    eval "$(sed -n '/^__autotune_measurement_verdict()/,/^}/p' "$REPO_ROOT/scripts/autotune-model.sh")"
    eval "$(sed -n '/^__autotune_cpu_pressure_pct()/,/^}/p' "$REPO_ROOT/scripts/autotune-model.sh")"
    export __AUTOTUNE_VERDICT_REASON=""
}

@test "the predicates loaded (a silent eval failure would pass every case)" {
    declare -f __autotune_measurement_verdict >/dev/null
    declare -f __autotune_cpu_pressure_pct >/dev/null
}

@test "THE TWO MEASURED CASES: load under cores no longer certifies beside CI" {
    # 2026-11-07 22:14Z — load 3.48 on 8 cores certified, 8 CI workers were live.
    [ "$(__autotune_measurement_verdict 3.48 8 0 0 "" 8)" = "refuse" ]
    # 2026-11-08 12:52Z — load 5.12 on 8 cores, 2 CI workers + 1 vitest.
    [ "$(__autotune_measurement_verdict 5.12 8 0 0 "" 2)" = "refuse" ]
    # The same readings with NO CI: load alone still certifies.  Without this the cases
    # above would pass for a function that refuses everything.
    [ "$(__autotune_measurement_verdict 3.48 8 0 0 "" 0)" = "certified" ]
    [ "$(__autotune_measurement_verdict 5.12 8 0 0 "" 0)" = "certified" ]
}

@test "start-of-run CPU pressure refuses a box whose load term is silent" {
    # busy but served — this box's real idle-with-load reading, must NOT refuse
    [ "$(__autotune_measurement_verdict 6.95 8 0 0 "1.45" 0)" = "certified" ]
    # genuine saturation, sampled before launch
    [ "$(__autotune_measurement_verdict 5.12 8 0 0 "17.31" 0)" = "refuse" ]
    # the threshold is a real boundary, not a vibe
    [ "$(__autotune_measurement_verdict 1.0 8 0 0 "10.0" 0)" = "certified" ]
    [ "$(__autotune_measurement_verdict 1.0 8 0 0 "10.1" 0)" = "refuse" ]
}

@test "a missing pressure instrument is NO EVIDENCE, not a refusal" {
    # Some kernels/hosts have no CONFIG_PSI.  Failing closed here would break autotune
    # on a box that never had the instrument, which is not the same as a contended box.
    [ "$(__autotune_measurement_verdict 1.0 8 0 0 "" 0)" = "certified" ]
    [ "$(__autotune_measurement_verdict 1.0 8 0 0 "nonsense" 0)" = "certified" ]
    [ "$(__autotune_measurement_verdict "1.0" 8 0 0 "0" 0)" = "certified" ]
}

@test "the new terms can only ever make it STRICTER" {
    local load cores allow force psi ci
    # A load term that already refuses must refuse whatever else is passed.
    load=20.0; cores=8; allow=0; force=0
    for psi in "" 0.00 1.45 17.31; do
        for ci in 0 1 8; do
            [ "$(__autotune_measurement_verdict "$load" "$cores" "$allow" "$force" "$psi" "$ci")" = "refuse" ]
        done
    done
    # ...and --allow-contended still turns any refusal into indicative, never certified.
    for psi in "" 1.45 17.31; do
        for ci in 0 8; do
            [ "$(__autotune_measurement_verdict "$load" "$cores" 1 0 "$psi" "$ci")" = "indicative" ]
        done
    done
    # The strict-only property must be asserted on a base that CERTIFIES, or "stricter than
    # a refusal" is trivially true and the case cannot fail.  (It did not: removing both new
    # terms left this case green until the base was moved under the core count.)
    [ "$(__autotune_measurement_verdict 1.0 8 0 0 "" 0)" = "certified" ]
    [ "$(__autotune_measurement_verdict 1.0 8 0 0 "" 1)" = "refuse" ]
    [ "$(__autotune_measurement_verdict 1.0 8 0 0 "17.31" 0)" = "refuse" ]
    # ...and the two terms never disagree with each other into a pass.
    [ "$(__autotune_measurement_verdict 1.0 8 0 0 "17.31" 8)" = "refuse" ]
}

@test "the pressure read happens BEFORE the server launches, not after the bench" {
    # The pin against my own first design.  If the sample moves to the verdict's call site
    # (after the bench), the run measures its own llama-server at CPU_COUNT threads and
    # every honest run reads as contended.
    local psi_line launch_line start_epoch_line
    psi_line=$(grep -n '^START_PSI_PCT=\$(__autotune_cpu_pressure_pct)' \
                   "$REPO_ROOT/scripts/autotune-model.sh" | head -1 | cut -d: -f1)
    [ -n "$psi_line" ] || { echo "START_PSI_PCT is no longer sampled at run start"; return 1; }
    start_epoch_line=$(grep -n '^START_EPOCH=\$(date +%s)' \
                   "$REPO_ROOT/scripts/autotune-model.sh" | head -1 | cut -d: -f1)
    # The anchor is the actual `"$LLAMA_BIN" --model` invocation inside _bench_spawn, not the
    # first line merely CONTAINING "llama-server" — that matched a comment and made this
    # case pass on line numbers that had nothing to do with a spawn.
    launch_line=$(grep -n '"$LLAMA_BIN" --model "$MODEL_PATH"' "$REPO_ROOT/scripts/autotune-model.sh" \
                   | head -1 | cut -d: -f1)
    [ -n "$launch_line" ] || { echo "could not locate the "\$LLAMA_BIN" launch"; return 1; }
    (( psi_line > start_epoch_line )) && (( psi_line < launch_line )) || {
        echo "START_PSI_PCT (line $psi_line) must sit between START_EPOCH" \
             "($start_epoch_line) and the launch ($launch_line)"
        return 1
    }
    # Position alone is not the property — the READ must also be the one asserting it.  With
    # the call site demoted to `_START_PSI_PCT=x`, this line still exists and the line-number
    # ordering above stays true, so assert the assignment shape too.
    grep -q '^START_PSI_PCT=\$(__autotune_cpu_pressure_pct)$' "$REPO_ROOT/scripts/autotune-model.sh" \
        || { echo "the run-start sample is not an assignment to START_PSI_PCT"; return 1; }
    # And the verdict must actually receive it.
    local joined
    joined=$(sed -e ':a' -e '/\\$/{N;s/\\\n//;ba' -e '}' "$REPO_ROOT/scripts/autotune-model.sh" \
        | tr -s '[:space:]' ' ')
    [[ "$joined" == *'"${START_PSI_PCT:-}" "$_row_ci"'* ]] \
        || { echo "the verdict call does not pass START_PSI_PCT and the CI count"; return 1; }
}

@test "the refusal message names the term that refused, not always the load" {
    # The reason is SCRIPT-SCOPE state, so the call must not run in a subshell: my first two
    # attempts wrapped it in $(...) and read an empty global back every time.
    local out
    __autotune_measurement_verdict 5.12 8 0 0 "" 2 >/dev/null
    [[ "$__AUTOTUNE_VERDICT_REASON" == "2 CI runner worker(s) active" ]] \
        || { echo "CI case: reason='$__AUTOTUNE_VERDICT_REASON'"; return 1; }

    out=""
    __autotune_measurement_verdict 5.12 8 0 0 "17.31" 0 >/dev/null
    [[ "$__AUTOTUNE_VERDICT_REASON" == *"cpu pressure 17.31%"* ]] \
        || { echo "pressure case: reason='$__AUTOTUNE_VERDICT_REASON'"; return 1; }

    __autotune_measurement_verdict 20.0 8 0 0 "" 0 >/dev/null
    [[ "$__AUTOTUNE_VERDICT_REASON" == "load 20.0 on 8 cores" ]] \
        || { echo "load case: reason='$__AUTOTUNE_VERDICT_REASON'"; return 1; }

    # A certified run must NOT leave a stale reason behind for the caller to print.
    __autotune_measurement_verdict 1.0 8 0 0 "" 0 >/dev/null
    [[ -z "$__AUTOTUNE_VERDICT_REASON" ]] \
        || { echo "certified run left reason='$__AUTOTUNE_VERDICT_REASON'"; return 1; }
}

@test "the CALL SITE reads the verdict in its own shell, so the term survives" {
    # Measured 2026-11-09 21:48 — row 3 measured 70.53 tps, was refused, and printed
    # "load 3.14 on 20 cores": a figure its own bound (load > cores) had already cleared,
    # because the call site wrapped the helper in $(...) and the reason never came back.
    # The case above proves the HELPER keeps its reason; this one proves the CALL takes it.
    local src="$REPO_ROOT/scripts/autotune-model.sh"
    # (a) the call site itself: not captured, and the word read from the global.
    grep -qE '^ *__autotune_measurement_verdict "\$_row_load"' "$src" \
        || { echo "the verdict call is missing or reformatted"; return 1; }
    ! grep -qE '_meas_state=\$\(__autotune_measurement_verdict' "$src" \
        || { echo "the verdict is captured in a subshell again — its reason is lost"; return 1; }
    grep -qE '^ *_meas_state="\$__AUTOTUNE_VERDICT"$' "$src" \
        || { echo "the call site does not read the word from the global"; return 1; }
    # (b) the mechanism, in the caller's own shape: run it and read BOTH globals.
    local _meas_state="" sentence
    __autotune_measurement_verdict 3.14 20 0 0 "55.0" 0 >/dev/null
    _meas_state="$__AUTOTUNE_VERDICT"
    [ "$_meas_state" = "refuse" ]
    sentence="REFUSING to write: ${__AUTOTUNE_VERDICT_REASON:-the gate named no term}"
    # The term that fired is the pressure one; the load sentence must not appear, because
    # 3.14 on 20 cores is UNDER the bound and asserting it is a lie the reader cannot catch.
    [[ "$sentence" == *"cpu pressure 55"* ]] \
        || { echo "pressure case printed: $sentence"; return 1; }
    [[ "$sentence" != *"load 3.14 on 20 cores"* ]] \
        || { echo "a load claim appeared for a load under the bound: $sentence"; return 1; }
}

# end of file
