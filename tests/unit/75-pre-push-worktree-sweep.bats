#!/usr/bin/env bats
# ==============================================================================
# Unit — tools/hooks/pre-push: the START-OF-PUSH sweep must not remove a
# worktree another push is still reading.
# ==============================================================================
# WHY THIS EXISTS.  Measured 2026-11-01 14:01 GMT in the shared ubuntu-console
# tree: two lanes pushed within a minute of each other, the second push's
# `sweep_stale_worktrees` saw the first push's worktree (same WT_PREFIX),
# treated it as a killed hook's leftovers, and removed it with
# `worktree remove --force` + `rm -rf` on the parent.  The first push's gates
# then failed reading files that plainly exist at HEAD —
#
#   /tmp/…/wt/tools/lint.sh: line 770: …/wt/tools/count-ratchet.sh: No such file or directory
#   python3: can't open file '…/wt/scripts/check_ci_status.py': No such file or directory
#   …/wt/tools/docs-sync-check.sh: No such file or directory
#   pre-push: fatal: '/tmp/…/wt' is not a working tree
#
# — which reads as "the COMMITTED content failed a gate" and is not one.
#
# CONTRACT (tools/hooks/pre-push header, CONCURRENT PUSHES): each push writes
# its PID to <parent>/.pre-push-owner BEFORE the worktree exists, and the sweep
# removes a prefixed worktree only when that PID is dead or the marker is
# absent.  Three arms, because a fix that simply stopped sweeping would trade
# this bug for a leaked worktree per killed push:
#
#   live owner      -> KEPT   (a push is running there now)
#   dead owner      -> REMOVED (a hook killed mid-push)
#   no marker       -> REMOVED (a killed pre-marker hook's leftovers)
#
# FALSIFICATION.  Against the hook before 2026-11-01 the "live owner is kept"
# assertion fails: the sweep removed all three.  Nothing here asserts the
# removal ORDER or the log wording beyond the one live line.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export REPO_ROOT
    SB="$(mktemp -d)"
    export SB
    # The hook materialises under ${TMPDIR:-/tmp}; point it INSIDE the sandbox so a worktree this case
    # creates can never collide with a real push on this box.
    export TMPDIR="$SB/tmp"
    mkdir -p "$TMPDIR"

    REPO="$SB/repo"
    git init -q "$REPO"
    git -C "$REPO" config user.email "test@example.invalid"
    git -C "$REPO" config user.name "test"
    mkdir -p "$REPO/tools/hooks"
    cp "$REPO_ROOT/tools/hooks/pre-push" "$REPO/tools/hooks/pre-push"
    # Gate stubs: this case is about the SWEEP, so the gates must be cheap and green, or a refusal would
    # be indistinguishable from the sweep's damage.
    printf '#!/usr/bin/env bash\necho "stub lint"\nexit 0\n' > "$REPO/tools/lint.sh"
    printf '#!/usr/bin/env bash\necho "stub docs-sync"\nexit 0\n' > "$REPO/tools/docs-sync-check.sh"
    chmod +x "$REPO/tools/lint.sh" "$REPO/tools/docs-sync-check.sh"
    printf 'tracked\n' > "$REPO/file.txt"
    git -C "$REPO" add -A
    git -C "$REPO" commit -qm "fixture"
    # Gate C must fail so the hook takes the worktree path: one untracked file is enough.
    printf 'dirty\n' > "$REPO/untracked.txt"
}

teardown() {
    [[ -n "${SB:-}" ]] && rm -rf "$SB"
}

# _peer_worktree <name> — register a prefixed worktree in the fixture and print its path.
_peer_worktree() {
    local _name="$1"
    local _root="$SB/${WT_PREFIX_T}$_name"
    mkdir -p "$_root"
    # `git worktree add` writes progress to stdout even with -q, so the path is NOT taken from its output:
    # the directory is the contract, and a failed add must say so rather than yield a multi-line "path".
    git -C "$REPO" worktree add -q --detach "$_root/wt" HEAD >/dev/null 2>&1
    [ -d "$_root/wt" ] || { echo "fixture: worktree add failed for $_name" >&2; return 1; }
    printf '%s\n' "$_root/wt"
}

@test "pre-push sweep keeps a LIVE push's worktree and removes dead or unmarked leftovers (2026-11-01)" {
    # The prefix the hook matches on. Kept in a variable so the fixture cannot drift from it silently:
    # if the hook renames the prefix, this case's worktrees stop matching and every assertion below
    # would pass for the wrong reason — so the pattern is asserted against the hook's own source first.
    run grep -F 'WT_PREFIX="ubuntu-console-pre-push."' "$REPO/tools/hooks/pre-push"
    [ "$status" -eq 0 ]
    WT_PREFIX_T="ubuntu-console-pre-push."

    local live dead none dead_pid pid_max
    live="$(_peer_worktree live)"
    dead="$(_peer_worktree dead)"
    none="$(_peer_worktree none)"

    # live: this test process's PID, which is alive for the whole case.
    printf '%s\n' "$$" > "$(dirname "$live")/.pre-push-owner"
    # dead: a PID that CANNOT exist (above the kernel's pid_max), so `kill -0` is guaranteed to fail with
    # ESRCH. A real short-lived child was the first shape here and it hung the suite: when `kill` did not
    # reach the child, `wait` blocked for that child's full lifetime instead of the test's.
    pid_max="$(cat /proc/sys/kernel/pid_max)"
    dead_pid=$(( pid_max + 1000 ))
    printf '%s\n' "$dead_pid" > "$(dirname "$dead")/.pre-push-owner"
    # none: no marker at all, the shape a killed pre-marker hook leaves.

    run bash "$REPO/tools/hooks/pre-push" < /dev/null
    [ "$status" -eq 0 ]

    # The live push's tree is untouched...
    [ -d "$live" ]
    [ -f "$live/tools/lint.sh" ]
    [[ "$output" == *"keeping a worktree owned by the live push"* ]]
    # ...and the leftovers are gone, so a killed hook still cannot leak one per push.
    [ ! -d "$dead" ]
    [ ! -d "$none" ]
    [[ "$output" == *"removing a worktree left by an interrupted hook"* ]]
}
