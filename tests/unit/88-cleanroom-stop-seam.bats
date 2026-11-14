#!/usr/bin/env bats
# ==============================================================================
# Unit — the clean-room stop seam opens for a STUB, and only for a stub
# ==============================================================================
# WHY THIS EXISTS (2026-11-14).  v27 of bin/_tac-bin-lib.sh refused every clean-room
# stop when TAC_TEST_TMPDIR was set, because a test had taken the CUDA tier down three
# times (18:08, 18:42, 18:50).  That refusal is correct and it cost the only coverage of
# the stop ORDER: every suite sets TAC_TEST_TMPDIR, so case 85's stop assertions could
# never see a stop (red on 75b5d3ad, CI 43630174823).
#
# v28 adds TAC_CLEANROOM_ALLOW_STOPS=1, and the safety argument is NOT "the caller
# promises to stub".  It is `declare -F systemctl`: the seam opens only when systemctl is
# a shell FUNCTION, which is a property of the call site rather than a claim by the
# caller.  Every stop in _tac_cleanroom_enter invokes bare `systemctl` (no sudo, no
# bash -c, no "$SYSTEMCTL"), and a function is inherited by command substitution, so a
# stub covers all of them; an unstubbed systemctl is a binary on PATH and fails the test.
#
# WHAT THESE CASES ASSERT: the three states of that predicate, each by its OUTCOME (a
# recorded stop, or none) rather than by a printed line.
#
# FALSIFICATION: case 3 is the one that matters.  Replace `declare -F systemctl` with
# `true` and case 3 goes red — the seam would then open for a real binary on PATH, which
# is exactly the production outage v27 exists to prevent.  Verified against that edit.
#
# HERMETIC: OPENCLAW_CONFIG points at a path that does not exist, so the fleet-model
# sweep is skipped; nvidia-smi is absent so the drain returns immediately; the only
# systemctl that can run is the one each case installs.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export REPO_ROOT
    SANDBOX="$BATS_TEST_TMPDIR/sandbox"
    mkdir -p "$SANDBOX"
    export SANDBOX
    export TAC_TEST_TMPDIR="$SANDBOX/tac"
    mkdir -p "$TAC_TEST_TMPDIR"
    # No config file -> the fleet-model sweep block is skipped entirely.
    export OPENCLAW_CONFIG="$SANDBOX/absent-openclaw.json"
    export SYS_LOG="$SANDBOX/systemctl.log"
    : > "$SYS_LOG"
    unset TAC_CLEANROOM_ALLOW_STOPS
}

# _enter — source the library and call the clean-room with a lane and a census tenant.
_enter() {
    bash -c '
        source "$1/bin/_tac-bin-lib.sh"
        LLM_AUTOTUNE_CENSUS="llama-cuda-qwen3embedding-embed.service"
        _tac_cleanroom_enter "$1" "llama-cuda-qwen3coder-30b-chat.service" "" --quiet
    ' _ "$REPO_ROOT"
}

@test "seam closed: TAC_TEST_TMPDIR alone refuses every stop" {
    run _enter
    [ "$status" -eq 0 ]
    [ ! -s "$SYS_LOG" ]
}

@test "seam open: a systemctl FUNCTION stub records the stops in order" {
    export TAC_CLEANROOM_ALLOW_STOPS=1
    run bash -c '
        source "$1/bin/_tac-bin-lib.sh"
        systemctl() {
            if [[ "$1" == "--user" && "$2" == "list-unit-files" ]]; then
                printf "actions.runner.test.service enabled\n"; return 0
            fi
            if [[ "$1" == "--user" && "$2" == "is-active" ]]; then return 0; fi
            printf "%s\n" "$*" >> "$SYS_LOG"
            return 0
        }
        LLM_AUTOTUNE_CENSUS="llama-cuda-qwen3embedding-embed.service"
        _tac_cleanroom_enter "$1" "llama-cuda-qwen3coder-30b-chat.service" "" --quiet
    ' _ "$REPO_ROOT"
    [ "$status" -eq 0 ]
    grep -q "stop llama-cuda-qwen3embedding-embed.service" "$SYS_LOG"
    grep -q "stop llama-cuda-qwen3coder-30b-chat.service" "$SYS_LOG"
}

@test "seam open but systemctl is a BINARY on PATH: still refuses (the safety property)" {
    # This is the case that makes the seam a check rather than a promise.  A real
    # systemctl is a file on PATH, so `declare -F systemctl` fails and the guard refuses
    # even though the variable is set.  A production shell cannot reach the stops by
    # exporting TAC_CLEANROOM_ALLOW_STOPS.
    export TAC_CLEANROOM_ALLOW_STOPS=1
    local bin="$SANDBOX/bin"
    mkdir -p "$bin"
    cat > "$bin/systemctl" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SYS_LOG"
exit 0
EOS
    chmod +x "$bin/systemctl"
    run env PATH="$bin:$PATH" bash -c '
        source "$1/bin/_tac-bin-lib.sh"
        LLM_AUTOTUNE_CENSUS="llama-cuda-qwen3embedding-embed.service"
        _tac_cleanroom_enter "$1" "llama-cuda-qwen3coder-30b-chat.service" "" --quiet
    ' _ "$REPO_ROOT"
    [ "$status" -eq 0 ]
    [ ! -s "$SYS_LOG" ]
}

@test "the reap stays refused under TAC_TEST_TMPDIR even with the seam open" {
    # A stop is restorable and recorded in the stopped-list; a kill is neither, and no
    # systemctl stub can cover a `kill`.  So the seam must not reach the reap.
    export TAC_CLEANROOM_ALLOW_STOPS=1
    run bash -c '
        source "$1/bin/_tac-bin-lib.sh"
        systemctl() { return 0; }
        _tac_cleanroom_reap_unsupervised() { printf "REAPED\n"; }
        LLM_AUTOTUNE_CENSUS=""
        _tac_cleanroom_enter "$1" "" "" --quiet
    ' _ "$REPO_ROOT"
    [ "$status" -eq 0 ]
    [[ "$output" != *"REAPED"* ]]
}

# end of file
