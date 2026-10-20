#!/usr/bin/env bats
# ==============================================================================
# Unit — bench resume: a sweep survives a restart
# ==============================================================================
# bench-rows.sh writes its planned rows to a resume plan before measuring and
# clears it only on success; bench-resume.sh --run claims that plan after a
# boot.  These cases pin the plan contract with a stubbed bench command, so no
# GPU is touched and no real sweep runs.  A plan kept on failure is the point:
# the next boot retries it instead of losing the run.
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
SCRIPT="$REPO_ROOT/bin/bench-resume.sh"

setup() {
    export BENCH_RESUME_PLAN="$BATS_TEST_TMPDIR/bench-resume.rows"
    export BENCH_RESUME_CMD=/bin/true
}

@test "bench-resume: --plan writes the rows and --status reads them" {
    run "$SCRIPT" --plan 4 6 8
    [ "$status" -eq 0 ]
    [ "$(cat "$BENCH_RESUME_PLAN")" = $'4\n6\n8' ]
    run "$SCRIPT" --status
    [ "$status" -eq 0 ]
    [[ "$output" == *"(3 row(s))"* ]]
}

@test "bench-resume: --run clears the plan on success" {
    "$SCRIPT" --plan 28
    run "$SCRIPT" --run
    [ "$status" -eq 0 ]
    [ ! -e "$BENCH_RESUME_PLAN" ]
}

@test "bench-resume: --run keeps the plan when the bench fails" {
    "$SCRIPT" --plan 28
    export BENCH_RESUME_CMD=/bin/false
    run "$SCRIPT" --run
    [ "$status" -eq 1 ]
    [ -s "$BENCH_RESUME_PLAN" ]
}

@test "bench-resume: --run with no plan is a no-op" {
    run "$SCRIPT" --run
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing to resume"* ]]
}

@test "bench-rows: the plan is written before measuring and cleared on success" {
    local src
    src=$(< "$REPO_ROOT/bin/bench-rows.sh")
    [[ "$src" == *'BENCH_RESUME_PLAN'* ]] || {
        echo "bench-rows must name the resume plan"
        return 1
    }
    [[ "$src" == *'rm -f "$BENCH_RESUME_PLAN"'* ]] || {
        echo "bench-rows must clear the plan on success"
        return 1
    }
}
