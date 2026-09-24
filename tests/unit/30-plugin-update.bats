#!/usr/bin/env bats
# ==============================================================================
# Unit — the [7/20] OpenClaw plugin update step: its OUTCOMES, pinned
# ==============================================================================
# WHY THIS EXISTS (2026-09-24): `__update_plugin` is defined INSIDE
# `__up_oc_plugins` and torn down with `unset -f` at the end of that call, so it
# cannot be called directly.  These cases drive the REAL outer function — the same
# boundary the unattended `up` path uses — which is also why the step needs a net
# before the de-duplication with 09e's `update_plugin` (same three plugins,
# different missing-directory policy) can be attempted safely.
#
# These assertions are the CURRENT behaviour, deliberately: a safety net for the
# refactor, not a spec to argue with.  One outcome is worth knowing about rather
# than trusting — when a plugin is simply MISSING the step still ends with
# `[ALREADY UP TO DATE]`, because the summary counts "updated", not "present"
# (case 1 pins it).
#
# HERMETIC: HOME is a temp dir, and each plugin is a real clone of a local BARE
# repo whose path contains the remote pattern the module expects, so the update
# path runs with no network.  git identity comes from GIT_* and GIT_CONFIG_GLOBAL
# points at /dev/null so the developer's own global config cannot leak in.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export REPO_ROOT
    SANDBOX="$(mktemp -d)"
    export SANDBOX
    export HOME="$SANDBOX/home"
    export TAC_TEST_TMPDIR="$SANDBOX/tac"
    export TAC_CACHE_DIR="$SANDBOX/cache"
    mkdir -p "$HOME/.openclaw/extensions" "$HOME/.openclaw/vendor" \
             "$TAC_TEST_TMPDIR" "$TAC_CACHE_DIR" "$SANDBOX/remotes" "$SANDBOX/src"

    # A global config that is NOT /dev/null: it rewrites GitHub URLs to the local
    # fixture remotes, so a checkout can carry a real https origin — which is what
    # the COMMAND matches on (09e passes a full URL as the remote pattern, where 08
    # passes a bare owner/repo slug) — while fetch/pull/clone still run offline.
    export GIT_CONFIG_SYSTEM=/dev/null
    export GIT_CONFIG_GLOBAL="$SANDBOX/gitconfig"
    git config --file "$SANDBOX/gitconfig" \
        "url.$SANDBOX/remotes/.insteadOf" "https://github.com/"
    export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
    export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

    # shellcheck source=env.sh
    source "$REPO_ROOT/env.sh"

    # Stubs go AFTER the source: a loader re-defines the real functions on top of
    # anything stubbed earlier.  __check_cooldown returns 0 ("expired") so the
    # update body actually runs; __tac_line is flattened so the assertions can match
    # on the status words without colour codes.
    __tac_line() { printf 'LINE %s\n' "$*"; }
    __tac_info() { printf 'INFO %s\n' "$*"; }
    __tac_header() { printf 'HEADER %s\n' "$*"; }
    __check_cooldown() { return 0; }
    __set_cooldown() { :; }
}

teardown() {
    cd /
    rm -rf "$SANDBOX"
}

# _make_remote <pattern-path> <plugin-id> — a bare remote at a path that CONTAINS
# the remote pattern the module matches on, plus a source clone of it with one
# commit pushed.  The bare's HEAD is set explicitly so `origin/HEAD` resolves the
# same way for any git version and any default branch name.
_make_remote() {
    local _pattern_path="$1" _id="$2"
    local _bare="$SANDBOX/remotes/$_pattern_path.git" _src="$SANDBOX/src/$_id"
    rm -rf "$_src"
    mkdir -p "$(dirname "$_bare")" "$_src"
    git init -q --bare "$_bare"
    git -C "$_bare" symbolic-ref HEAD refs/heads/main
    git -C "$_src" init -q
    git -C "$_src" checkout -q -b main
    printf 'v1\n' > "$_src/file.txt"
    git -C "$_src" add file.txt
    git -C "$_src" commit -qm init
    git -C "$_src" remote add origin "$_bare"
    git -C "$_src" push -q origin main
}

# _clone_from <pattern-path> <target-dir> — clone that fixture remote into place and
# give the checkout the URL form as its origin.  The set-url is required, not tidiness:
# when url.*.insteadOf applies, git records the REWRITTEN url as origin (measured — a
# clone of the https url stored the local path, and both command cases then reported
# "[SKIP - custom remote]" because the URL the command matches on was nowhere in it).
_clone_from() {
    local _pattern_path="$1" _target="$2"
    rm -rf "$_target"
    git clone -q "$SANDBOX/remotes/$_pattern_path.git" "$_target"
    git -C "$_target" remote set-url origin "https://github.com/$_pattern_path.git"
}

# _clone_plugin <plugin-id> <target-dir> — clone the plugin's own fixture remote.
_clone_plugin() {
    _clone_from "$(_remote_path "$1")" "$2"
}

# _remote_path <plugin-id> — the pattern path used for that plugin's fixture, which
# matches what scripts/08-maintenance.sh matches the remote URL against.
_remote_path() {
    case "$1" in
        gigabrain)     printf '%s' 'legendaryvibecoder/gigabrain' ;;
        lossless-claw) printf '%s' 'Martian-Engineering/lossless-claw' ;;
        openstinger)   printf '%s' 'srikanthbellary/openstinger' ;;
    esac
}

# _advance_remote <plugin-id> — a second commit pushed, so any clone is BEHIND.
_advance_remote() {
    local _src="$SANDBOX/src/$1"
    printf 'v2\n' > "$_src/file.txt"
    git -C "$_src" commit -qam second
    git -C "$_src" push -q origin main
}

# _scaffold_all — all three plugins present as clean clones, level with their
# remotes, so a single case can mutate just the one it is about.
_scaffold_all() {
    local _pair
    for _pair in "gigabrain:$HOME/.openclaw/extensions/gigabrain" \
                 "lossless-claw:$HOME/.openclaw/extensions/lossless-claw" \
                 "openstinger:$HOME/.openclaw/vendor/openstinger"
    do
        _make_remote "$(_remote_path "${_pair%%:*}")" "${_pair%%:*}"
        _clone_plugin "${_pair%%:*}" "${_pair##*:}"
    done
}

# _run_plugins — call the real step.  NOT under `run` and NOT in a subshell: this
# suite runs under errexit, and the step's own errexit-safety is part of what is
# being pinned.  Output is written to a file and read back, the idiom
# tests/unit/26-docker-prune.bats uses for the same reason.
#
# stdin comes from /dev/null ON PURPOSE.  The step's local-changes branch keys on
# `[[ -t 0 ]]`: bats hands the test the invoking terminal, so WITHOUT this
# redirection a case that has local changes blocks on `read -r _choice` waiting for
# a menu selection — measured 2026-09-24, it hung past 90s and only the outer
# `timeout` ended it.  Redirecting also states the intent plainly: these cases are
# about the NON-interactive path, which is the one `up` takes from a service or any
# non-terminal caller.  The interactive branch itself is not reachable from a
# non-tty harness, so it is not characterised here.
_run_plugins() {
    local err=0
    __up_oc_plugins "$(date +%s)" 1 err > "$SANDBOX/out.txt" 2>&1 < /dev/null
}

@test "plugins: a missing plugin reports NOT INSTALLED, and the summary still claims UP TO DATE" {
    _run_plugins
    run cat "$SANDBOX/out.txt"
    [ "$status" -eq 0 ]
    [[ "$output" == *"LINE [7/20] Gigabrain Plugin [NOT INSTALLED]"* ]]
    [[ "$output" == *"LINE [8/20] Lossless-Claw Plugin [NOT INSTALLED]"* ]]
    [[ "$output" == *"LINE [9/20] OpenStinger [NOT INSTALLED]"* ]]
    # Pinned, and misleading: nothing was installed and nothing was updated, yet the
    # step ends in the SUCCESS colour claiming "ALREADY UP TO DATE".  A future
    # refactor should decide which of those two words is true.
    [[ "$output" == *"LINE [10/20] OpenClaw Plugins [ALREADY UP TO DATE]"* ]]
}

@test "plugins: a directory that is not a git checkout is reported as local, not updated" {
    _scaffold_all
    rm -rf "$HOME/.openclaw/extensions/gigabrain/.git"

    _run_plugins
    run cat "$SANDBOX/out.txt"
    [[ "$output" == *"LINE [7/20] Gigabrain Plugin [INSTALLED (local)]"* ]]
    [[ "$output" == *"LINE [10/20] OpenClaw Plugins [ALREADY UP TO DATE]"* ]]
}

@test "plugins: a checkout of a foreign remote is skipped, not pulled" {
    _scaffold_all
    _make_remote other-org/other-plugin foreign
    _clone_from other-org/other-plugin "$HOME/.openclaw/extensions/gigabrain"

    _run_plugins
    run cat "$SANDBOX/out.txt"
    [[ "$output" == *"LINE [7/20] Gigabrain Plugin [SKIP - custom remote]"* ]]
}

@test "plugins: a checkout behind its remote is updated, and the step reports UPDATED" {
    _scaffold_all
    _advance_remote gigabrain

    _run_plugins
    run cat "$SANDBOX/out.txt"
    [[ "$output" == *"LINE [7/20] Gigabrain Plugin [UPDATED]"* ]]
    [[ "$output" == *"LINE [10/20] OpenClaw Plugins [PLUGINS UPDATED]"* ]]
    # The pull really happened: the clone is level with the remote again.
    run git -C "$HOME/.openclaw/extensions/gigabrain" rev-list --count HEAD..origin/HEAD
    [ "$output" = "0" ]
}

@test "plugins: a checkout level with its remote is left alone" {
    _scaffold_all

    _run_plugins
    run cat "$SANDBOX/out.txt"
    [[ "$output" == *"LINE [7/20] Gigabrain Plugin [ALREADY UP TO DATE]"* ]]
    [[ "$output" == *"LINE [10/20] OpenClaw Plugins [ALREADY UP TO DATE]"* ]]
}

@test "plugins: local changes with no terminal are skipped, never discarded" {
    _scaffold_all
    printf 'local edit\n' >> "$HOME/.openclaw/extensions/gigabrain/file.txt"

    _run_plugins
    run cat "$SANDBOX/out.txt"
    [[ "$output" == *"LINE [7/20] Gigabrain Plugin [SKIP - has local changes]"* ]]
    # Skipping must not have touched the working tree.
    run cat "$HOME/.openclaw/extensions/gigabrain/file.txt"
    [[ "$output" == *"local edit"* ]]
}

@test "plugins: the helper's exit contract is 0 changed, 1 benign no-op, 2 failed" {
    # The helper is module scope, so its exit code can be asserted directly — and it
    # MUST be, because 1 and 2 are the distinction the two callers depend on: both
    # count updates from rc 0, and only 2 is an error to surface.  Each call is
    # written `... || rc=$?` on purpose: capturing a non-zero rc means the call must
    # sit in a `||` list, where errexit does not abort the case.
    _scaffold_all
    local rc

    # 0 — a checkout behind its remote is updated
    _advance_remote gigabrain
    rc=0
    __update_plugin "$HOME/.openclaw/extensions/gigabrain" \
        "legendaryvibecoder/gigabrain" "gigabrain" 0 > /dev/null 2>&1 || rc=$?
    [ "$rc" -eq 0 ]
    run git -C "$HOME/.openclaw/extensions/gigabrain" rev-list --count HEAD..origin/HEAD
    [ "$output" = "0" ]

    # 1 — benign: level with the remote, and a plugin that is not installed at all
    rc=0
    __update_plugin "$HOME/.openclaw/extensions/gigabrain" \
        "legendaryvibecoder/gigabrain" "gigabrain" 0 > /dev/null 2>&1 || rc=$?
    [ "$rc" -eq 1 ]
    rc=0
    __update_plugin "$SANDBOX/not-installed" \
        "legendaryvibecoder/gigabrain" "gigabrain" 0 > /dev/null 2>&1 || rc=$?
    [ "$rc" -eq 1 ]

    # 2 — the remote cannot be read at all, and the reason is printed, not swallowed.
    # The new URL must still CONTAIN the expected pattern, or the remote check fails
    # first and returns the benign 1 without ever reaching the fetch.
    git -C "$HOME/.openclaw/extensions/lossless-claw" \
        remote set-url origin "$SANDBOX/absent/Martian-Engineering/lossless-claw.git"
    rc=0
    __update_plugin "$HOME/.openclaw/extensions/lossless-claw" \
        "Martian-Engineering/lossless-claw" "lossless-claw" 0 \
        > "$SANDBOX/out.txt" 2>&1 || rc=$?
    [ "$rc" -eq 2 ]
    run cat "$SANDBOX/out.txt"
    [[ "$output" == *"[CHECK FAILED - fetch]"* ]]
    [[ "$output" == *"absent/Martian-Engineering"* ]]
}

# ── The COMMAND, not just the helper ───────────────────────────────────────────
# Everything above pins the step through __up_oc_plugins.  These run the real
# `oc-plugin-update` the way a user does, because the delegation in 09e is exactly
# the wiring a helper-only test cannot see: proving __update_plugin behaves says
# nothing about whether the command calls it correctly, nor about the count and the
# exit code it derives from the reply.
#
# The positive cases call the command as a PLAIN STATEMENT on purpose — this suite
# runs under errexit, so surviving the call IS the assertion that it exited 0.
# Only the failure case wraps it, because there the non-zero code is the thing
# under test.

@test "oc-plugin-update: a fleet that is already current reports NO UPDATES and exits 0" {
    # The counting bug at the boundary a user sees: 09e returned 0 for "up to date"
    # in its own copy, so all three were counted and this run claimed
    # "3 plugin(s) processed" while changing nothing.
    _scaffold_all

    oc-plugin-update --all > "$SANDBOX/out.txt" 2>&1 < /dev/null

    run cat "$SANDBOX/out.txt"
    [ "$status" -eq 0 ]
    [[ "$output" == *"LINE Update Status [NO UPDATES]"* ]]
}

@test "oc-plugin-update: the command renders the SHARED helper's vocabulary" {
    # This is the delegation itself, and it is assertable hermetically: 09e's own copy
    # of this logic said "[SKIP - different remote]"; only the shared helper says
    # "[SKIP - custom remote]", and it also prints the Current/Expected pair that used
    # to live only in 09e.  Seeing those on the command's output is proof the command
    # routed through the helper rather than keeping a private copy.
    _scaffold_all

    oc-plugin-update --all > "$SANDBOX/out.txt" 2>&1 < /dev/null

    run cat "$SANDBOX/out.txt"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[SKIP - custom remote]"* ]]
    [[ "$output" != *"[SKIP - different remote]"* ]]
    [[ "$output" == *"INFO   Expected https://github.com/legendaryvibecoder/gigabrain.git"* ]]
}

@test "plugins: an update whose dependency install fails is reported as failed" {
    # A plugin that may not load is not "updated".  All four dep-install sites warned
    # and then returned 0, so a broken plugin read as a clean update; the exit code now
    # agrees with the warning.
    _scaffold_all
    _advance_remote gigabrain
    # package.json has to arrive THROUGH the pull: an untracked one would make the
    # checkout dirty, and the helper would skip it for local changes instead.
    printf '{"name":"gigabrain"}\n' > "$SANDBOX/src/gigabrain/package.json"
    git -C "$SANDBOX/src/gigabrain" add package.json
    git -C "$SANDBOX/src/gigabrain" commit -qm deps
    git -C "$SANDBOX/src/gigabrain" push -q origin main
    mkdir -p "$SANDBOX/stub"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX/stub/npm"
    chmod +x "$SANDBOX/stub/npm"
    export PATH="$SANDBOX/stub:$PATH"

    local rc=0
    __update_plugin "$HOME/.openclaw/extensions/gigabrain" \
        "legendaryvibecoder/gigabrain" "gigabrain" 0 > "$SANDBOX/out.txt" 2>&1 || rc=$?

    [ "$rc" -eq 2 ]
    run cat "$SANDBOX/out.txt"
    [[ "$output" == *"[DEP INSTALL FAILED - plugin may not load]"* ]]
    # The update itself did land, and that is still reported — the rc is what changed.
    [[ "$output" == *"[UPDATED]"* ]]
}

# LIMIT, stated rather than left implied: the command path's UPDATE and FAILURE
# branches are not exercised here, and cannot be hermetically.  09e passes a full
# `https://github.com/...` URL as the remote pattern, so a checkout only matches it
# when `git remote get-url origin` returns that URL — and the only way to serve one
# locally is `url.*.insteadOf`, which git applies when READING the url as well, so the
# checkout always reports the rewritten local path (measured 2026-09-24: both attempts
# landed on "[SKIP - custom remote]" instead of the fetch).  Those branches are
# therefore pinned one level down, by the helper's own cases above (0/1/2, including a
# remote that cannot be read).  Covering them at the command level needs a real remote.
