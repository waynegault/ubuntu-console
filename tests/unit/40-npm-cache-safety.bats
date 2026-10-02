#!/usr/bin/env bats
# ==============================================================================
# Unit — [20/20] NPM Cache Clean: a FAILED verify is not a [VERIFIED] success
# ==============================================================================
# WHY THIS EXISTS (AUDIT-2026-10-02, card f7d203cc): __up_npm_cache read its own
# verdict from a PIPELINE —
#
#     npm_cache_result=$(npm cache verify 2>&1 | grep -E "Cache cleaned|Cache size" || echo "")
#
# — so the status it observed was grep's (or echo's), never npm's.  A FAILED
# `npm cache verify` prints neither of the two patterns, so the pipeline produced
# an empty string and the `else` branch printed "[VERIFIED]" in the SUCCESS
# colour.  The step then called __set_cooldown, so the failure was not retried for
# the whole cooldown period.  Feedback without a check, on the highest-numbered
# step of `up`.
#
# The property these cases assert is the VERDICT and the COOLDOWN, not the row's
# wording: on failure the cooldown must stay UNSET (so the next run retries), and
# the three real outcomes must remain distinct.
#
# FALSIFICATION (2026-10-02): run against the pre-fix file (commit at the time),
# the failure case fails with `LINE [20/20] NPM Cache Clean [VERIFIED]` and a
# cooldown written — the exact defect.  The other three pass on both trees, i.e.
# they are regression guards, not change-detectors.
#
# HERMETIC: HOME, OC_ROOT and the cooldown DB are sandboxed, and npm is a stub on
# PATH.  No case runs a real npm.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export REPO_ROOT
    SANDBOX="$(mktemp -d)"
    export SANDBOX
    export HOME="$SANDBOX/home"
    export TAC_TEST_TMPDIR="$SANDBOX/tac"
    export TAC_CACHE_DIR="$SANDBOX/cache"
    mkdir -p "$HOME" "$TAC_TEST_TMPDIR" "$TAC_CACHE_DIR" "$SANDBOX/bin"

    # shellcheck source=env.sh
    source "$REPO_ROOT/env.sh"

    # Flattened rows: assertions match the status words without colour codes.
    __tac_line() { printf 'LINE %s\n' "$*"; }
    __tac_info() { printf 'INFO %s\n' "$*"; }

    # Sandbox the paths the step touches, AFTER the source so 01-constants.sh
    # cannot win.
    export OC_ROOT="$SANDBOX/oc"
    export CooldownDB="$SANDBOX/cooldowns.txt"
    mkdir -p "$OC_ROOT"
}

teardown() {
    cd /
    rm -rf "$SANDBOX"
}

# _stub_npm <rc> <message> — the only npm these cases ever run.
_stub_npm() {
    local rc="$1" msg="$2"
    cat > "$SANDBOX/bin/npm" <<STUB
#!/usr/bin/env bash
printf '%s\n' "$msg"
exit $rc
STUB
    chmod +x "$SANDBOX/bin/npm"
    export PATH="$SANDBOX/bin:$PATH"
}

# _run_npm — call the real step with force mode so no cooldown gate is involved.
# Direct (not `run`): the errCount nameref is set inside the function's own shell,
# and a command substitution would drop it.  Leaves _err and out.txt for asserts.
_run_npm() {
    _err=0
    __up_npm_cache "$(date +%s)" 1 _err > "$SANDBOX/out.txt" 2>&1
}

@test "npm cache: a FAILED verify reports FAILED, counts it, and sets NO cooldown" {
    _stub_npm 1 "npm ERR! EACCES: cache verify failed"
    # Seed an unrelated cooldown so the assertion is exact: the failure must leave
    # the DB byte-identical, not merely absent.
    printf 'apt_index=123\n' > "$CooldownDB"

    _run_npm

    run cat "$SANDBOX/out.txt"
    [[ "$output" == *"[20/20] NPM Cache Clean [FAILED (rc=1): npm ERR! EACCES: cache verify failed]"* ]]
    # The old bug's exact signature: a failure presented as success.
    [[ "$output" != *"[VERIFIED]"* ]]
    [[ "$output" != *"[ALREADY UP TO DATE]"* ]]
    # Counted into the run's issue total.
    [ "$_err" -eq 1 ]
    # The property that makes the failure recoverable: no cooldown, so the next
    # `up` retries instead of waiting out the period.
    run cat "$CooldownDB"
    [ "$output" = "apt_index=123" ]
    [[ "$output" != *"npm_cache="* ]]
}

@test "npm cache: a successful verify still reports ALREADY UP TO DATE and records the cooldown" {
    # The other direction: a guard that broke the healthy path would be its own bug.
    _stub_npm 0 "Cache size: ~0 MB (0 B)"
    local now
    now=$(date +%s)

    _err=0
    __up_npm_cache "$now" 1 _err > "$SANDBOX/out.txt" 2>&1

    run cat "$SANDBOX/out.txt"
    [[ "$output" == *"[20/20] NPM Cache Clean [ALREADY UP TO DATE]"* ]]
    [ "$_err" -eq 0 ]
    run grep "^npm_cache=" "$CooldownDB"
    [ "$output" = "npm_cache=$now" ]
}

@test "npm cache: a cleaned cache reports FREED with npm's own size" {
    _stub_npm 0 "Cache cleaned: 12.3MB freed"

    _err=0
    __up_npm_cache "$(date +%s)" 1 _err > "$SANDBOX/out.txt" 2>&1

    run cat "$SANDBOX/out.txt"
    [[ "$output" == *"[20/20] NPM Cache Clean [FREED 12.3MB]"* ]]
    [ "$_err" -eq 0 ]
    run grep -c "^npm_cache=" "$CooldownDB"
    [ "$output" = "1" ]
}

@test "npm cache: [VERIFIED] is reserved for an rc=0 run whose text matches neither pattern" {
    # A non-zero run must never reach this row; an rc=0 run with unfamiliar output
    # is a genuine success and keeps it.
    _stub_npm 0 "npm cache verify: done"

    _err=0
    __up_npm_cache "$(date +%s)" 1 _err > "$SANDBOX/out.txt" 2>&1

    run cat "$SANDBOX/out.txt"
    [[ "$output" == *"[20/20] NPM Cache Clean [VERIFIED]"* ]]
    [ "$_err" -eq 0 ]
    run grep -c "^npm_cache=" "$CooldownDB"
    [ "$output" = "1" ]
}

# end of file
