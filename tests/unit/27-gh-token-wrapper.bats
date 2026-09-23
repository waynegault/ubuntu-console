#!/usr/bin/env bats
# ==============================================================================
# Unit — bin/gh (GitHub CLI token shim)
# ==============================================================================
# The shim exists because a `gh` call whose environment carries no GH_TOKEN falls
# through to the system credential store, and that fall-through is what activates
# org.freedesktop.secrets — which, with no default keyring present, creates one
# behind a password prompt (measured 2026-09-23; the caller was the ChatGPT/Codex
# VS Code extension's GitHub-media path, which runs `gh auth token --hostname
# github.com` from an environment that has no token).
#
# These cases pin the shim's contract: an explicit token is NEVER overridden, the
# bridged token is injected only into an environment that has none, an unusable
# bridge cache is reported rather than silently ignored, and the shim refuses to
# exec itself.
#
# Hermetic: the "real gh" is a fixture that records the token it was handed, and
# TAC_CACHE_DIR points into the test sandbox — /dev/shm is never read, and the
# real gh is never executed.
# ==============================================================================

# The "refuses to exec itself" case declares its expected exit code with `run -127`
# (bats BW01: a bare 127 normally means the test's own command was not found).
# Flags on `run` need bats >= 1.5, so say so — this fails loudly on an older bats
# instead of silently ignoring the flag.
bats_require_minimum_version 1.5.0

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    SHIM_DIR="$BATS_TEST_TMPDIR/shim"
    REAL_DIR="$BATS_TEST_TMPDIR/real"
    CACHE_DIR="$BATS_TEST_TMPDIR/cache"
    SEEN="$BATS_TEST_TMPDIR/seen_token"
    mkdir -p "$SHIM_DIR" "$REAL_DIR" "$CACHE_DIR"

    # The installed shape: install.sh links bin/gh into ~/.local/bin, so the shim
    # is reached through a symlink. Reproduce that rather than copying the file.
    ln -s "$REPO_ROOT/bin/gh" "$SHIM_DIR/gh"

    cat > "$REAL_DIR/gh" <<'FAKE_GH'
#!/usr/bin/env bash
printf '%s' "${GH_TOKEN:-<unset>}" > "$SEEN"
printf 'argv: %s\n' "$*"
FAKE_GH
    chmod +x "$REAL_DIR/gh"

    # A PATH with no real gh in it, so the fixture is the only candidate: the shim
    # resolves the real gh itself and a linuxbrew gh must not leak into a test.
    TEST_PATH="$SHIM_DIR:$REAL_DIR:/usr/bin:/bin"
}

# Invoke the shim with the caller's own GH_TOKEN/GITHUB_TOKEN removed, whatever
# the surrounding shell happens to carry.
run_shim() {
    run env -u GH_TOKEN -u GITHUB_TOKEN PATH="$TEST_PATH" TAC_CACHE_DIR="$CACHE_DIR" \
        SEEN="$SEEN" "$SHIM_DIR/gh" "$@"
}

@test "gh shim: injects the bridged token when the caller has none" {
    printf 'export GH_TOKEN=%s\n' "'bridged-token-abc'" > "$CACHE_DIR/tac_win_api_keys"
    chmod 600 "$CACHE_DIR/tac_win_api_keys"

    run_shim auth token --hostname github.com
    [ "$status" -eq 0 ]
    [ "$(cat "$SEEN")" = "bridged-token-abc" ]
    # Arguments reach the real gh untouched.
    [[ "$output" == *"argv: auth token --hostname github.com"* ]]
}

@test "gh shim: never overrides a token the caller already has" {
    printf 'export GH_TOKEN=%s\n' "'bridged-token-abc'" > "$CACHE_DIR/tac_win_api_keys"
    chmod 600 "$CACHE_DIR/tac_win_api_keys"

    run env -u GITHUB_TOKEN PATH="$TEST_PATH" TAC_CACHE_DIR="$CACHE_DIR" SEEN="$SEEN" \
        GH_TOKEN=caller-token "$SHIM_DIR/gh" auth token
    [ "$status" -eq 0 ]
    [ "$(cat "$SEEN")" = "caller-token" ]
}

@test "gh shim: GITHUB_TOKEN counts as the caller having a token" {
    printf 'export GH_TOKEN=%s\n' "'bridged-token-abc'" > "$CACHE_DIR/tac_win_api_keys"
    chmod 600 "$CACHE_DIR/tac_win_api_keys"

    run env -u GH_TOKEN PATH="$TEST_PATH" TAC_CACHE_DIR="$CACHE_DIR" SEEN="$SEEN" \
        GITHUB_TOKEN=caller-token "$SHIM_DIR/gh" auth token
    [ "$status" -eq 0 ]
    [ "$(cat "$SEEN")" = "<unset>" ]
}

@test "gh shim: with no bridge cache gh runs unchanged, and says nothing" {
    run_shim auth token
    [ "$status" -eq 0 ]
    [ "$(cat "$SEEN")" = "<unset>" ]
    # No cache is the un-bridged case (CI): no decision was taken, so no noise —
    # the real gh's own stdout is the entire output.
    [ "$output" = "argv: auth token" ]
}

@test "gh shim: refuses a bridge cache that is not mode 600, and says so" {
    printf 'export GH_TOKEN=%s\n' "'bridged-token-abc'" > "$CACHE_DIR/tac_win_api_keys"
    chmod 644 "$CACHE_DIR/tac_win_api_keys"

    run_shim auth token
    [ "$status" -eq 0 ]
    [ "$(cat "$SEEN")" = "<unset>" ]
    [[ "$output" == *"refusing bridge cache"* ]]
    [[ "$output" == *"mode 644"* ]]
}

@test "gh shim: reports a cache that carries no GitHub token" {
    printf 'export OTHER_API_KEY=%s\n' "'not-a-gh-token'" > "$CACHE_DIR/tac_win_api_keys"
    chmod 600 "$CACHE_DIR/tac_win_api_keys"

    run_shim auth token
    [ "$status" -eq 0 ]
    [ "$(cat "$SEEN")" = "<unset>" ]
    [[ "$output" == *"carries no GH_TOKEN/GITHUB_TOKEN"* ]]
}

@test "gh shim: refuses to exec itself when no other gh is on PATH" {
    # `run -127` declares the expectation: bats warns (BW01) that a bare 127
    # normally means the test's OWN command was not found, and here it is the
    # shim's answer — "there is no gh to run" — that is under test.
    run -127 env -u GH_TOKEN -u GITHUB_TOKEN PATH="$SHIM_DIR:/usr/bin:/bin" SEEN="$SEEN" \
        "$SHIM_DIR/gh" auth token
    [ "$status" -eq 127 ]
    [[ "$output" == *"refusing to exec itself"* ]]
}

@test "gh shim: install.sh links it to ~/.local/bin/gh" {
    local home_dir="$BATS_TEST_TMPDIR/install-home"
    local stub_dir="$BATS_TEST_TMPDIR/install-stubs"
    mkdir -p "$home_dir" "$stub_dir"
    # The installer reloads the user manager when systemctl is present; stub it so
    # this case never touches the session's live systemd.
    printf '#!/usr/bin/env bash\nexit 0\n' > "$stub_dir/systemctl"
    chmod +x "$stub_dir/systemctl"

    run env HOME="$home_dir" PATH="$stub_dir:$PATH" bash "$REPO_ROOT/install.sh"
    [ "$status" -eq 0 ]
    [ -L "$home_dir/.local/bin/gh" ]
    [ "$(readlink -f "$home_dir/.local/bin/gh")" = "$REPO_ROOT/bin/gh" ]
}
