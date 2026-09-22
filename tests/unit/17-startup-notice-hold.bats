#!/usr/bin/env bats
# ==============================================================================
# Unit — the loader's startup-notice hold (tactical-console.bashrc)
# ==============================================================================
# Why: the banner is drawn LAST, so it can carry the final
# TACTICAL_PROFILE_VERSION, but `clear` emits ESC[3J — which erases the
# SCROLLBACK as well as the screen.  A notice printed while the modules load was
# therefore destroyed milliseconds after it was written and could not be
# scrolled back to either: measured 2026-09-22, 13-init's loopback0 warning
# flashed before the header and was unrecoverable.
#
# These cases pin the fix.  The assertion is ORDER, not presence: the notice
# must be written after the clear, or the clear will erase it again.
#
# Hermetic: the REAL loader from the repo is exercised, against a throwaway
# module set under $BATS_TEST_TMPDIR, so nothing here reads or mutates this
# machine's console state.  The stub `clear_tactical` prints the marker CLEAR
# instead of clearing the screen — that is what makes the order observable.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    LOADER="$REPO_ROOT/tactical-console.bashrc"
    FAKE_REPO="$BATS_TEST_TMPDIR/repo"
    FAKE_HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$FAKE_REPO/scripts" "$FAKE_HOME"

    # Module 13's stand-in: print the notice, then ask for the banner.  That is
    # the real order — 13-init notices at source time, unconditionally, while the
    # banner is guarded by __TAC_INITIALIZED and deferred to the loader so the
    # header shows the version computed from every module.
    # Both streams are exercised: the hold is at the fd level and must catch both.
    cat > "$FAKE_REPO/scripts/13-init.sh" <<'MOD'
# Module Version: 1
printf '%s\n' "notice-on-stdout"
printf '%s\n' "notice-on-stderr" >&2
if [[ -z "${__TAC_INITIALIZED:-}" ]]
then
    __TAC_DISPLAY_BANNER=1
    __TAC_INITIALIZED=1
fi
MOD

    # Module 5's stand-in: the banner, without a screen clear.
    cat > "$FAKE_REPO/scripts/05-ui-engine.sh" <<'MOD'
# Module Version: 1
function clear_tactical() {
    printf '%s\n' "CLEAR"
    __show_header
}
function __show_header() {
    printf '%s\n' "HEADER"
}
MOD

    cat > "$FAKE_REPO/scripts/01-constants.sh" <<'MOD'
# Module Version: 1
C_Warning=$'\e[33m'
C_Reset=$'\e[0m'
MOD

    _set_module_list 01-constants 05-ui-engine 13-init
}

# _set_module_list <name...> — write the list the loader reads with mapfile.
_set_module_list() {
    {
        printf 'function __tac_module_list() {\n'
        printf '    printf "%%s\\n"'
        printf ' %s' "$@"
        printf '\n}\n'
    } > "$FAKE_REPO/scripts/_module-list.sh"
}

# _run_loader [NAME=VALUE...] — run the REAL loader in a child interactive shell.
# Extra assignments are added to the child's environment.  Both streams are
# merged: bash writes each printf directly, so the captured order is the real
# write order.
_run_loader() {
    env -u __TAC_INITIALIZED -u __TAC_DISPLAY_BANNER \
        HOME="$FAKE_HOME" PS1= TERM=dumb \
        TACTICAL_REPO_ROOT="$FAKE_REPO" "$@" \
        bash --noprofile --norc -i -c "source '$LOADER'" 2>&1
}

# _line_of <line> — 1-based number of the first exact match, or empty.
_line_of() {
    grep -n "^$1\$" | head -1 | cut -d: -f1
}

@test "startup notice: a stdout notice lands BELOW the banner, not before the clear" {
    run _run_loader
    [ "$status" -eq 0 ]

    local clear_line header_line notice_line
    clear_line=$(printf '%s\n' "$output" | _line_of "CLEAR")
    header_line=$(printf '%s\n' "$output" | _line_of "HEADER")
    notice_line=$(printf '%s\n' "$output" | _line_of "notice-on-stdout")

    [ -n "$clear_line" ]
    [ -n "$header_line" ]
    [ -n "$notice_line" ]
    # This is the whole fix: after the clear, so the ESC[3J cannot reach it.
    [ "$notice_line" -gt "$clear_line" ]
    [ "$notice_line" -gt "$header_line" ]
}

@test "startup notice: a stderr notice is held too" {
    run _run_loader
    [ "$status" -eq 0 ]

    local header_line notice_line
    header_line=$(printf '%s\n' "$output" | _line_of "HEADER")
    notice_line=$(printf '%s\n' "$output" | _line_of "notice-on-stderr")

    [ -n "$notice_line" ]
    [ "$notice_line" -gt "$header_line" ]
}

@test "startup notice: no banner (already initialized) still reports the notice" {
    run _run_loader __TAC_INITIALIZED=1
    [ "$status" -eq 0 ]

    # Without a banner there is no clear to hide behind, but the notices must
    # still reach the terminal — the hold must not swallow them.
    [[ "$output" == *"notice-on-stdout"* ]]
    [[ "$output" != *"HEADER"* ]]
}

@test "startup notice: the loader's own short-module-count report is held too" {
    # 15-model-recommender is listed but has no file, so the loader prints
    # "Expected N modules, found M" — its own warning, emitted after the module
    # loop and therefore before the banner.
    _set_module_list 01-constants 05-ui-engine 13-init 15-model-recommender

    run _run_loader
    [ "$status" -eq 0 ]

    local header_line warn_line
    header_line=$(printf '%s\n' "$output" | _line_of "HEADER")
    warn_line=$(printf '%s\n' "$output" | grep -n 'Expected 4 modules' | head -1 | cut -d: -f1)

    [ -n "$warn_line" ]
    [ "$warn_line" -gt "$header_line" ]
}

@test "startup notice: an unwritable TMPDIR degrades loudly, after the banner" {
    run _run_loader "TMPDIR=$BATS_TEST_TMPDIR/does-not-exist"
    [ "$status" -eq 0 ]

    local header_line fail_line
    header_line=$(printf '%s\n' "$output" | _line_of "HEADER")
    fail_line=$(printf '%s\n' "$output" | grep -n 'no writable temp file' | head -1 | cut -d: -f1)

    # The degradation must be visible: reported from the place where it can be
    # read (after the banner), never silently — and the notices still get out.
    [ -n "$fail_line" ]
    [ "$fail_line" -gt "$header_line" ]
    [[ "$output" == *"notice-on-stdout"* ]]
}

# end of file
