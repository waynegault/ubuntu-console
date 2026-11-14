#!/usr/bin/env bats
# ==============================================================================
# Unit — the monthly llama.cpp rebuild: STEP ORDER, not just outcomes
# ==============================================================================
# WHY THIS FILE EXISTS.  The 2026-11-14 rebuild built fine and then lost both lanes.  Nothing was
# wrong with any single step: every step did its own job.  The defect was in the ORDER - the tree
# was moved aside while the lanes were still executing from it, so
#
#   * their /proc/PID/exe read .../build-cuda.prev-<commit>/bin/llama-server, which gpu-busy.sh
#     called foreign, and the watchdog stopped both lanes 22 s into the compile; and
#   * the unit's ExecStart names build-cuda/, which does not exist during a compile, so every
#     restart in that window failed with "CUDA build not executable" until the unit latched.
#
# A test that asserts each step RAN cannot see any of that.  These cases assert what each step was
# handed at the moment it ran, which is the only surface on which ordering is observable.
#
# The subject is the script ITSELF (jarvis's llm-rebuild-monthly.sh), driven through the seams
# added for it - LLAMA_ROOT, CONSOLE, STATE, LANES, SYSTEMCTL - with a fake systemctl and a fake
# llm-build.  Nothing here touches a real lane, a real card or the real checkout.
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
SUBJECT="${LLM_REBUILD_SCRIPT:-$HOME/.openclaw/workspace-jarvis/scripts/llm-rebuild-monthly.sh}"

setup() {
    [ -r "$SUBJECT" ] || skip "the monthly rebuild subject is not readable: $SUBJECT"

    SANDBOX="$BATS_TEST_TMPDIR/sb"
    mkdir -p "$SANDBOX/bin" "$SANDBOX/llama/build-cuda/bin" "$SANDBOX/state"
    # A tree that looks like a serving tree: the script refuses to run without a binary to move.
    printf '#!/usr/bin/env bash\nprintf "version: test (build 1, commit %s)\\n" "$STUB_COMMIT"\n' \
        > "$SANDBOX/llama/build-cuda/bin/llama-server"
    chmod +x "$SANDBOX/llama/build-cuda/bin/llama-server"
    # A git checkout the script can date: no remote work needed, everything is "already current".
    git -C "$SANDBOX/llama" init -q
    git -C "$SANDBOX/llama" -c user.email=t@example.com -c user.name=t \
        commit -q --allow-empty -m fixture
    STUB_COMMIT="$(git -C "$SANDBOX/llama" rev-parse --short HEAD)"
    export STUB_COMMIT

    # The ORDER LOG.  Every fake appends one line as it is called, so the test reads the sequence
    # the script actually drove rather than what it reported afterwards.
    ORDER="$BATS_TEST_TMPDIR/order.log"
    : > "$ORDER"
    export ORDER

    # A fake systemctl.  Records the verb and the units, and answers the queries the script makes.
    cat > "$SANDBOX/bin/systemctl" <<'SC'
#!/usr/bin/env bash
verb=""; args=()
for a in "$@"; do
    case "$a" in
        --user|-p|--value) ;;
        *)
            if [ -z "$verb" ]; then verb="$a"; else args+=("$a"); fi
            ;;
    esac
done
printf 'systemctl %s %s\n' "$verb" "${args[*]}" >> "$ORDER"
case "$verb" in
    cat) exit "${STUB_UNIT_MISSING:-0}" ;;
    show) printf '%s\n' "${STUB_MAINPID:-4242}"; exit 0 ;;
    *) exit 0 ;;
esac
SC
    chmod +x "$SANDBOX/bin/systemctl"

    # A fake heavy-job: this suite is about ordering, and a real lock would couple it to the box.
    cat > "$SANDBOX/bin/heavy-job" <<'HJ'
#!/usr/bin/env bash
printf 'heavy-job %s\n' "$*" >> "$ORDER"
case "${1:-}" in
    --status) printf 'heavy-job: free\n' ;;
esac
exit 0
HJ
    chmod +x "$SANDBOX/bin/heavy-job"

    # A CONSOLE whose env.sh defines llm-build as a fake that records WHEN it ran and what the
    # tree looked like at that moment - that pairing is what the ordering cases assert.
    # heavy-job is copied from $SANDBOX/bin: the script resolves it through "$CONSOLE/bin", so a
    # fake on PATH is never consulted (a mistake this harness made once and the first case caught).
    mkdir -p "$SANDBOX/console/bin"
    cp "$SANDBOX/bin/heavy-job" "$SANDBOX/console/bin/heavy-job"
    chmod +x "$SANDBOX/console/bin/heavy-job"
    cat > "$SANDBOX/console/env.sh" <<ENVS
llm-build() {
    printf 'llm-build tree-exists=%s\n' "\$([ -d $SANDBOX/llama/build-cuda ] && echo yes || echo no)" >> "$ORDER"
    mkdir -p "$SANDBOX/llama/build-cuda/bin"
    printf '#!/usr/bin/env bash\nprintf "version: test (build 2, commit %s)\\\\n" "\$(git -C $SANDBOX/llama rev-parse --short HEAD)"\n' \
        > "$SANDBOX/llama/build-cuda/bin/llama-server"
    chmod +x "$SANDBOX/llama/build-cuda/bin/llama-server"
    return "\${STUB_BUILD_RC:-0}"
}
ENVS

    # A curl that answers health without a network: 200 only when the lane's tree has a binary,
    # which is how the suite models "the tree was there when the lane answered".
    cat > "$SANDBOX/bin/curl" <<'CU'
#!/usr/bin/env bash
for a in "$@"; do
    case "$a" in
        http*) printf '%s' "${STUB_HEALTH:-200}"; exit 0 ;;
    esac
done
printf '000'
exit 0
CU
    chmod +x "$SANDBOX/bin/curl"

    export PATH="$SANDBOX/bin:$PATH"
    export SYSTEMCTL="$SANDBOX/bin/systemctl"
}

teardown() {
    [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"
}

# _run — drive the real script against the sandbox.  Every path is a seam the script honours.
_run() {
    run env \
        LLAMA_ROOT="$SANDBOX/llama" \
        CONSOLE="$SANDBOX/console" \
        STATE="$SANDBOX/state" \
        LANES="lane-a.service lane-b.service" \
        SYSTEMCTL="$SANDBOX/bin/systemctl" \
        CHAT_PORT=18087 EMBED_PORT=18080 \
        STUB_BUILD_RC="${STUB_BUILD_RC:-0}" \
        bash "$SUBJECT" "$@"
}

# _order_grep — positive assertion helper.  Never `! grep`: errexit is suppressed for negated
# commands, so a `!` assertion can never fail the case (a defect this repo has hit before).
_order_grep() {
    grep -c -- "$1" "$ORDER" | grep -qv '^0$'
}

@test "the lanes are STOPPED before the tree is moved aside (the 2026-11-14 defect)" {
    # Catches: moving build-cuda -> build-cuda.prev-<commit> while both lanes still execute from it.
    # The proof is positional: the stop must appear before the move, and the move is observable as
    # the moment the serving tree path no longer exists.
    _run
    local stop_line move_line
    stop_line=$(grep -n 'systemctl stop' "$ORDER" | head -1 | cut -d: -f1)
    move_line=$(grep -n 'llm-build tree-exists=no' "$ORDER" | head -1 | cut -d: -f1)
    [ -n "$stop_line" ]
    [ -n "$move_line" ]
    [ "$stop_line" -lt "$move_line" ]
}

@test "the lanes are stopped, and the units named, before llm-build is invoked" {
    # The unit names are what a typo would break, and a typo here silently restarts nothing while
    # /health still answers from the process that was already up.  Both names must be in the stop.
    _run
    local stop
    stop=$(grep -m1 'systemctl stop' "$ORDER")
    [[ "$stop" == *lane-a.service* ]]
    [[ "$stop" == *lane-b.service* ]]
}

@test "a FAILED stop refuses the build rather than moving the tree (fail closed)" {
    # Catches: ignoring the stop's status and moving the tree anyway - which is the original bug
    # with an extra step.  The fake must answer cat/show like a healthy unit and fail ONLY stop,
    # or the script exits at its earlier lane-resolution check and this case passes for the wrong
    # reason (it did, until the message assertion below forced the paths apart).
    cat > "$SANDBOX/bin/systemctl-stop-fails" <<'SF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "$ORDER"
case "$*" in
    *" stop"*) exit 1 ;;
    *" cat "*|*" show "*) exit 0 ;;
    *) exit 0 ;;
esac
SF
    chmod +x "$SANDBOX/bin/systemctl-stop-fails"
    run env LLAMA_ROOT="$SANDBOX/llama" CONSOLE="$SANDBOX/console" STATE="$SANDBOX/state" \
        LANES="lane-a.service" SYSTEMCTL="$SANDBOX/bin/systemctl-stop-fails" \
        bash "$SUBJECT"
    [ "$status" -ne 0 ]
    # The stop was actually attempted, the tree is still the serving tree, and the build never ran.
    _order_grep "stop lane-a.service"
    [ -d "$SANDBOX/llama/build-cuda" ]
    [ "$(grep -c 'llm-build' "$ORDER")" -eq 0 ]
    grep -q 'refusing to move the tree' "$SANDBOX/state/rebuild.log"
}

@test "a FAILED build restores the tree and clears a latched unit before restarting" {
    # Catches: restore() calling `restart` on a unit that latched "start request repeated too
    # quickly" - which is not cleared by restart, so the rollback reports done over a dead lane
    # (measured 2026-11-14: the rollback's own restart failed for exactly this reason).
    STUB_BUILD_RC=1 _run
    [ "$status" -ne 0 ]
    local reset_line restart_line
    reset_line=$(grep -n 'systemctl reset-failed' "$ORDER" | head -1 | cut -d: -f1)
    restart_line=$(grep -n 'systemctl restart' "$ORDER" | tail -1 | cut -d: -f1)
    [ -n "$reset_line" ]
    [ -n "$restart_line" ]
    [ "$reset_line" -lt "$restart_line" ]
    [ -d "$SANDBOX/llama/build-cuda" ]
}

@test "a lane unit that does not resolve refuses BEFORE the tree is touched" {
    # Catches: a bad LANES name failing after the move, with the tree already gone.
    run env LLAMA_ROOT="$SANDBOX/llama" CONSOLE="$SANDBOX/console" STATE="$SANDBOX/state" \
        LANES="typo.service" SYSTEMCTL="$SANDBOX/bin/systemctl" STUB_UNIT_MISSING=1 \
        bash "$SUBJECT"
    [ "$status" -ne 0 ]
    [ -d "$SANDBOX/llama/build-cuda" ]
    grep -q 'lane unit does not exist' "$SANDBOX/state/rebuild.log"
}

@test "a BUSY box SKIPs without moving anything (the quiet gate)" {
    # The monthly timer must not fight a bench: a busy SKIP is a logged no-op, and the tree must be
    # exactly where it was.
    printf '#!/usr/bin/env bash\nprintf "heavy-job BUSY\\n" >> "$ORDER"\nprintf "heavy-job: BUSY — pid=1 bench\\n"\nexit 0\n' \
        > "$SANDBOX/bin/heavy-job-busy"
    chmod +x "$SANDBOX/bin/heavy-job-busy"
    cp "$SANDBOX/bin/heavy-job-busy" "$SANDBOX/console/bin/heavy-job"
    _run
    [ "$status" -eq 0 ]
    [ -d "$SANDBOX/llama/build-cuda" ]
    grep -q 'SKIP: box busy' "$SANDBOX/state/rebuild.log"
}

@test "a DRY RUN plans and moves nothing (the timer's rehearsal)" {
    _run --dry-run
    [ "$status" -eq 0 ]
    [ -d "$SANDBOX/llama/build-cuda" ]
    # Positive counts, not `! grep`: errexit is suppressed for a negated command, so the negated
    # form of either assertion below could never fail this case.
    [ "$(grep -c 'llm-build' "$ORDER")" -eq 0 ]
    grep -q 'PLAN: rebuild from' "$SANDBOX/state/rebuild.log"
}
