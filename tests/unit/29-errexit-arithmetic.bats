#!/usr/bin/env bats
# ==============================================================================
# Unit — module code must survive errexit: no bare postfix arithmetic command
# ==============================================================================
# Why (measured 2026-09-24): this repo's BATS cases run under ERREXIT, and they
# call module functions DIRECTLY (not under `run`), so module code executes under
# `set -e` even though the interactive shell does not set it.  A bare `((x++))`
# then aborts the whole case the FIRST time the counter is incremented from 0:
# `((x++))` evaluates to x's OLD value, and 0 is a non-zero exit status.
#
# The failure names the wrong line.  Measured: calling `__cleanup_temps` directly
# with a `python-*.exe` present reported
#
#   (from function `__cleanup_temps' in file scripts/08-maintenance.sh, line 48,
#    in test file ..., line 18)  `__cleanup_temps' failed
#
# where line 48 WAS the `((count++))` — but when the failing statement is not the
# last one in the case, bats names the closing brace or `fi` instead, so the line
# it prints can look innocent.
#
# WHY THIS CLASS NEEDS ITS OWN GUARD: the pre-existing case for that same function
# ran it as `result=$(__cleanup_temps)` — a command substitution, and errexit is
# NOT inherited into `$( )` — so it stayed green over code that aborts when called
# the way the rest of the suite calls module functions.  A case that wraps the call
# in a subshell cannot see this class, which is why case 1 calls the function as a
# plain statement.
#
# The fix is the assignment form, `count=$(( count + 1 ))`, which is always status
# 0.  The prefix form `((++count))` is also safe while count >= 0 (it returns the
# NEW value, so 1 or more) and is used throughout 11a/11e/11f, so the scanner
# allows it.
#
# Scope: `scripts/*.sh`.  bin/ and tools/ are deliberately NOT scanned — their
# errexit posture is per-file and documented (bin/tac-exec and tools/run-tests.sh
# each omit `set -e` on purpose), so a counter there is not this defect.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export REPO_ROOT
    TAC_TEST_TMPDIR="$(mktemp -d)"
    export TAC_TEST_TMPDIR
}

teardown() {
    cd /
    rm -rf "$TAC_TEST_TMPDIR"
}

# __errexit_offenders <file> — print every line of <file> that runs a bare postfix
# increment/decrement arithmetic command as a STATEMENT: alone on its line, or as
# the final operand after then/else/do/;/&&/||.  Condition contexts (an if/while
# test, a `for (( ))` header) and the prefix form are deliberately not flagged.
__errexit_offenders() {
    local _stmt='^[[:space:]]*\(\([[:space:]]*[A-Za-z_][A-Za-z0-9_]*(\+\+|--)[[:space:]]*\)\)[[:space:]]*(#.*)?$'
    local _tail='(^|[[:space:]])(then|else|do|;|&&|\|\|)[[:space:]]+\(\([[:space:]]*[A-Za-z_][A-Za-z0-9_]*(\+\+|--)[[:space:]]*\)\)[[:space:]]*(#.*)?$'
    local _line
    while IFS= read -r _line
    do
        if [[ "$_line" =~ $_stmt ]] || [[ "$_line" =~ $_tail ]]
        then
            printf '%s\n' "$_line"
        fi
    done < "$1"
}

@test "errexit: __cleanup_temps completes when called directly, not in a subshell" {
    mkdir -p "$TAC_TEST_TMPDIR/work"
    cd "$TAC_TEST_TMPDIR/work"
    : > python-sample.exe

    # shellcheck source=scripts/08-maintenance.sh
    source "$REPO_ROOT/scripts/08-maintenance.sh"

    # NOT `count=$(__cleanup_temps)`: a substitution does not inherit errexit, so
    # that form passes over an aborting function.  A plain statement does not.
    __cleanup_temps > "$TAC_TEST_TMPDIR/count.txt"

    run cat "$TAC_TEST_TMPDIR/count.txt"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
    [ ! -e python-sample.exe ]
}

@test "errexit: no scripts/*.sh runs a bare postfix increment as a statement" {
    local _f _line _hits=""
    for _f in "$REPO_ROOT"/scripts/*.sh
    do
        while IFS= read -r _line
        do
            _hits+="  $(basename "$_f"):$_line"$'\n'
        done < <(__errexit_offenders "$_f")
    done
    if [[ -n "$_hits" ]]
    then
        printf '%s\n' \
            'A bare ((x++)) returns 1 while x is 0, and that aborts its caller under' \
            'errexit — which every case in this suite sets.  Use  x=$(( x + 1 )).' \
            "$_hits"
        return 1
    fi
}

@test "errexit: the scanner flags the forbidden shape and spares the safe ones" {
    local _fixture="$TAC_TEST_TMPDIR/scanner-fixture.sh"
    printf '%s\n' \
        'x=0' \
        '            ((x++))' \
        '        rm -f f && ((y++))' \
        '    (( cond )) || ((issues++))' \
        '    if (( x++ < 3 )); then :; fi' \
        '    while (( i++ < n )); do :; done' \
        '    for (( i=0; i<n; i++ )); do :; done' \
        '    ((++ok))' \
        > "$_fixture"

    run __errexit_offenders "$_fixture"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 3 ]
    [[ "${lines[0]}" == *'((x++))'* ]]
    [[ "${lines[1]}" == *'((y++))'* ]]
    [[ "${lines[2]}" == *'((issues++))'* ]]
}
