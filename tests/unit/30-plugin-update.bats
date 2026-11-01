#!/usr/bin/env bats
# ==============================================================================
# Unit — the retired OpenClaw path-installed plugin update step
# ==============================================================================
# WHY THIS EXISTS: OpenStinger, Gigabrain and Lossless-Claw were all retired, so
# `up`'s [10/20] step and `oc-plugin-update` no longer pull anything.  This suite
# pins the two honest reports (the step's "retired" row and the command's
# "no path-installed plugins" row), and keeps the `__update_plugin` helper's exit
# contract — the helper stays module scope so a future path-installed plugin can
# reuse it, and these cases are what a new caller can rely on.
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
    esac
}

# _advance_remote <plugin-id> — a second commit pushed, so any clone is BEHIND.
_advance_remote() {
    local _src="$SANDBOX/src/$1"
    printf 'v2\n' > "$_src/file.txt"
    git -C "$_src" commit -qam second
    git -C "$_src" push -q origin main
}

# _scaffold_all — both plugin fixtures present as clean clones, level with their
# remotes, so a single case can mutate just the one it is about.
_scaffold_all() {
    local _pair
    for _pair in "gigabrain:$HOME/.openclaw/extensions/gigabrain" \
                 "lossless-claw:$HOME/.openclaw/extensions/lossless-claw"
    do
        _make_remote "$(_remote_path "${_pair%%:*}")" "${_pair%%:*}"
        _clone_plugin "${_pair%%:*}" "${_pair##*:}"
    done
}

# ── The retired step ─────────────────────────────────────────────────────────
# `__up_oc_plugins` no longer pulls anything, so it must report that honestly and
# must NOT colour the run as an issue — a clean fleet is a clean run.

@test "plugins: the step reports retired and adds no issue" {
    local err=0
    __up_oc_plugins "$(date +%s)" 1 err > "$SANDBOX/out.txt" 2>&1 < /dev/null

    [ "$err" -eq 0 ]
    run cat "$SANDBOX/out.txt"
    [[ "$output" == *"LINE [10/20] OpenClaw Plugins [NONE - path-installed plugins retired]"* ]]
    # The per-plugin rows are gone with the plugins; nothing may re-add them.
    [[ "$output" != *"LINE [7/20]"* ]]
    [[ "$output" != *"LINE [8/20]"* ]]
}

@test "oc-plugin-update: reports no path-installed plugins and exits 0" {
    oc-plugin-update --all > "$SANDBOX/out.txt" 2>&1 < /dev/null

    run cat "$SANDBOX/out.txt"
    [ "$status" -eq 0 ]
    [[ "$output" == *"LINE Update Status [NO PATH-INSTALLED PLUGINS - all retired]"* ]]
}

# ── The helper's contract, kept for a future path-installed plugin ──────────

@test "plugins: the helper's exit contract is 0 changed, 1 current, 2 failed, 3 not updated" {
    # The helper is module scope, so its exit code can be asserted directly — and it
    # MUST be, because these are the distinctions any future caller will depend on.
    # Each call is written `... || rc=$?` on purpose: capturing a non-zero rc means
    # the call must sit in a `||` list, where errexit does not abort the case.
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

    # 1 — benign, and CURRENT: level with the remote.  This is the only case that may be
    # reported as "already up to date", which is why nothing else shares its code.
    rc=0
    __update_plugin "$HOME/.openclaw/extensions/gigabrain" \
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

    # 3 — not updated, and NOT because it is current: a missing path, a directory that
    # is not a checkout, and the user's own local changes are all not ours to move.
    rc=0
    __update_plugin "$SANDBOX/not-installed" \
        "legendaryvibecoder/gigabrain" "gigabrain" 0 > /dev/null 2>&1 || rc=$?
    [ "$rc" -eq 3 ]

    rc=0
    __update_plugin "$HOME/.openclaw/extensions" \
        "legendaryvibecoder/gigabrain" "gigabrain" 0 > /dev/null 2>&1 || rc=$?
    [ "$rc" -eq 3 ]   # present, but not a checkout

    printf 'local edit\n' >> "$HOME/.openclaw/extensions/gigabrain/file.txt"
    rc=0
    __update_plugin "$HOME/.openclaw/extensions/gigabrain" \
        "legendaryvibecoder/gigabrain" "gigabrain" 0 > /dev/null 2>&1 || rc=$?
    [ "$rc" -eq 3 ]   # the user's local changes are not ours to discard
    run cat "$HOME/.openclaw/extensions/gigabrain/file.txt"
    [[ "$output" == *"local edit"* ]]
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

# end of file
