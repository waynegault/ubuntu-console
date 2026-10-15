#!/usr/bin/env bats
# ==============================================================================
# Unit — bin/autotune-resume.sh: the boot re-arm for the autotune remainder.
# ==============================================================================
# WHY THIS EXISTS.  Measured 2026-10-15: a running chunk is a child of the Qwen
# session's cli.js pair, which is a child of the VS Code window's extension host - so
# a restart ends it, and NOTHING re-armed it.  A restart therefore stopped the tuner
# until a person noticed.  The expected values here come from that job, not from the
# script's current output:
#
#   * with no plan, a boot does nothing and SAYS so (exit 0, a named line);
#   * `--plan` derives Wayne's ruled scope (uncertified + flagged family + the two
#     ruled new quants, by model file name) from the registry;
#   * the plan is CLAIMED once, so a boot loop cannot re-tune rows it already has;
#   * a row whose model file is gone is DROPPED, and if nothing is runnable the unit
#     fails, keeps the plan, and names the count.
#
# FALSIFICATION.  Case 2 fails against any derivation that hardcodes row NUMBERS
# instead of reading the registry (a row number is reassigned by every `model scan`).
# Case 5 fails against a claim-first-then-check implementation, which would leave the
# operator's plan consumed by a run that never happened.
#
# No env.sh: the script is standalone and is driven here as a subprocess through its
# documented TAC_RESUME_* seams, so nothing from the module tree is sourced.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export REPO_ROOT
    SCRIPT="$REPO_ROOT/bin/autotune-resume.sh"
    export SCRIPT

    SANDBOX="$(mktemp -d)"
    export SANDBOX
    export TAC_RESUME_REGISTRY="$SANDBOX/models.conf"
    export TAC_RESUME_MODEL_DIR="$SANDBOX/models"
    export TAC_RESUME_STATE_DIR="$SANDBOX/state"
    export TAC_RESUME_LOGDIR="$SANDBOX/logs"
    export TAC_RESUME_ENTRY="$SANDBOX/entry.sh"
    export TAC_RESUME_PLAN="$SANDBOX/state/autotune-resume.rows"
    ARGV_LOG="$SANDBOX/entry.argv"
    export ARGV_LOG

    mkdir -p "$TAC_RESUME_MODEL_DIR" "$TAC_RESUME_STATE_DIR" "$TAC_RESUME_LOGDIR"

    # A stub entry point: records the rows it was handed, so the case can assert what
    # the resume actually asked for.
    cat > "$TAC_RESUME_ENTRY" <<'ENTRY_EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$ARGV_LOG"
exit 0
ENTRY_EOF
    chmod +x "$TAC_RESUME_ENTRY"

    # Registry rows carry the real column layout: 3 = model file, 17 = tps,
    # 18 = certified (yes/no), 25 = p2_tps.  Built by position so the field count
    # cannot drift with a hand-typed pipe run.
    _row() {
        local n="$1" f="$2" tps="$3" cert="$4" p2="$5" i out=""
        out="$n|m|$f"
        for i in 4 5 6 7 8 9 10 11 12 13 14 15 16; do out+="|0"; done
        out+="|$tps|$cert"
        for i in 19 20 21 22 23 24; do out+="|0"; done
        out+="|$p2"
        printf '%s\n' "$out"
    }
    {
        _row 1 uncertified.gguf 2.00 no  0.00
        _row 2 flagged.gguf     1.00 yes 5.00
        _row 3 certified.gguf   3.00 yes 1.00
        _row 4 law-chat-Q2_K.gguf 4.00 yes 0.00
    } > "$TAC_RESUME_REGISTRY"

    : > "$TAC_RESUME_MODEL_DIR/uncertified.gguf"
    : > "$TAC_RESUME_MODEL_DIR/flagged.gguf"
    : > "$TAC_RESUME_MODEL_DIR/certified.gguf"
    : > "$TAC_RESUME_MODEL_DIR/law-chat-Q2_K.gguf"
}

teardown() {
    [[ -n "${SANDBOX:-}" ]] && rm -rf "$SANDBOX"
}

@test "autotune-resume: with no plan a boot does nothing, says so, and calls nothing" {
    run "$SCRIPT" 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"no plan at"* ]]
    [[ "$output" == *"nothing to resume"* ]]
    [ ! -e "$ARGV_LOG" ]
}

@test "autotune-resume: --plan derives the ruled scope from the registry, by file name" {
    run "$SCRIPT" --plan 2>&1
    [ "$status" -eq 0 ]
    [ -f "$TAC_RESUME_PLAN" ]

    # Included: the uncertified row, the flagged family, and the ruled new quants.
    grep -q '^uncertified.gguf$' "$TAC_RESUME_PLAN"
    grep -q '^flagged.gguf$' "$TAC_RESUME_PLAN"
    grep -q '^law-chat-Q2_K.gguf$' "$TAC_RESUME_PLAN"
    # Excluded: certified and unflagged.
    ! grep -q '^certified.gguf$' "$TAC_RESUME_PLAN"
    # Named by FILE, never by row number.
    ! grep -qE '^[0-9]+$' "$TAC_RESUME_PLAN"
}

@test "autotune-resume: a plan is executed through the entry point and CLAIMED once" {
    printf 'uncertified.gguf\nflagged.gguf\n' > "$TAC_RESUME_PLAN"
    run "$SCRIPT" 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"resuming 2 row(s)"* ]]

    # The entry point got exactly those rows, once.
    [ "$(wc -l < "$ARGV_LOG")" -eq 2 ]
    grep -q '^uncertified.gguf$' "$ARGV_LOG"
    grep -q '^flagged.gguf$' "$ARGV_LOG"

    # Claimed: no plan left at the path a boot looks at, a copy in the log home, and
    # the claim kept aside rather than destroyed.
    [ ! -e "$TAC_RESUME_PLAN" ]
    [ "$(ls -1 "$TAC_RESUME_LOGDIR" | grep -c '\.rows$')" -eq 1 ]
    [ "$(ls -1 "$TAC_RESUME_STATE_DIR" | grep -c '\.claimed-')" -eq 1 ]

    # And a second boot finds nothing and says so, rather than re-tuning the rows.
    run "$SCRIPT" 2>&1
    [[ "$output" == *"no plan at"* ]]
    [ "$(wc -l < "$ARGV_LOG")" -eq 2 ]
}

@test "autotune-resume: a row whose model file is gone is dropped and the rest still run" {
    rm -f "$TAC_RESUME_MODEL_DIR/flagged.gguf"
    printf 'uncertified.gguf\nflagged.gguf\n' > "$TAC_RESUME_PLAN"
    run "$SCRIPT" 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"dropping flagged.gguf"* ]]
    [[ "$output" == *"resuming 1 row(s)"* ]]
    [ "$(wc -l < "$ARGV_LOG")" -eq 1 ]
    grep -q '^uncertified.gguf$' "$ARGV_LOG"
}

@test "autotune-resume: nothing runnable fails, names the count, and KEEPS the plan" {
    rm -f "$TAC_RESUME_MODEL_DIR/uncertified.gguf" "$TAC_RESUME_MODEL_DIR/flagged.gguf"
    printf 'uncertified.gguf\nflagged.gguf\n' > "$TAC_RESUME_PLAN"
    run "$SCRIPT" 2>&1
    [ "$status" -eq 1 ]
    [[ "$output" == *"nothing runnable"* ]]
    [[ "$output" == *"2 row(s) dropped"* ]]
    # The plan survives, so the operator can fix it; nothing was called.
    [ -f "$TAC_RESUME_PLAN" ]
    [ ! -e "$ARGV_LOG" ]
}

# end of file
