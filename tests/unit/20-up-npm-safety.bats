#!/usr/bin/env bats
# ==============================================================================
# Unit — `up`'s npm step must not be able to leave the global root empty
# ==============================================================================
# Why: `npm update -g` reifies the WHOLE global root. On 2026-09-22 a failure in
# its staging directory (ENOTEMPTY) removed all ten globally installed packages —
# including the gateway's own install and the openclaw CLI — and the step
# reported [FAILED] and carried on. These cases pin the recovery: the installed
# set is snapshotted before the update and rebuilt if the update removed it.
#
# Hermetic: a stub `npm` on PATH models the failure and records what it was asked
# to do, and HOME points at a temp dir so OC_ROOT/CooldownDB are temp as well.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    TAC_TEST_TMPDIR="$(mktemp -d)"
    export TAC_TEST_TMPDIR
    export HOME="$TAC_TEST_TMPDIR/home"
    export TAC_CACHE_DIR="$TAC_TEST_TMPDIR/cache"
    mkdir -p "$HOME" "$TAC_CACHE_DIR"

    export NPM_STUB_DIR="$TAC_TEST_TMPDIR/stub"
    mkdir -p "$NPM_STUB_DIR"
    cat > "$NPM_STUB_DIR/npm" <<'STUB'
#!/usr/bin/env bash
# Stub npm. State lives in $NPM_STUB_DIR/state.json (what `npm ls -g --json`
# reports) and $NPM_STUB_DIR/calls.log (every invocation).
printf '%s\n' "$*" >> "$NPM_STUB_DIR/calls.log"
case "${1:-}" in
    list|ls)
        # `npm list -g` (plain, what the step's own check greps) and
        # `npm ls -g --json` (what __npm_global_snapshot parses) are the same
        # command in different output modes.
        _json=0
        shift
        for _a in "$@"
        do [[ "$_a" == "--json" ]] && _json=1
        done
        if (( _json ))
        then
            if [[ -f "$NPM_STUB_DIR/state.json" ]]
            then cat "$NPM_STUB_DIR/state.json"
            else printf '{"dependencies":{}}'
            fi
            printf '\n'
        else
            printf '%s\n' "/stub/prefix"
            jq -r '.dependencies // {} | to_entries[] | "├── \(.key)@\(.value.version)"' \
                "$NPM_STUB_DIR/state.json" 2>/dev/null
        fi
        ;;
    outdated)
        # npm exits 1 when anything is outdated, and the step names the packages
        # from this output — with nothing named it skips the update entirely and
        # the failure path below is never reached.
        # Format: <fullpath>:<name@wanted>:<name@installed>:<name@latest>:<dependedby>
        printf '%s\n' "/stub/prefix:gamma@1.1.0:gamma@1.0.0:gamma@1.1.0:"
        exit 1
        ;;
    update)
        # Model the real failure: the reify dies. With NPM_UPDATE_RESULT=wipe
        # (the default) it leaves the global root EMPTY, as it did on 2026-09-22.
        if [[ "${NPM_UPDATE_RESULT:-wipe}" == "wipe" ]]
        then
            printf '{"dependencies":{}}' > "$NPM_STUB_DIR/state.json"
        fi
        exit 1
        ;;
    install)
        shift                       # install
        shift                       # -g
        _deps=""
        for _s in "$@"
        do
            _n="${_s%@*}"; _v="${_s##*@}"
            _deps="${_deps:+$_deps,}\"$_n\":{\"version\":\"$_v\"}"
        done
        printf '{"dependencies":{%s}}' "$_deps" > "$NPM_STUB_DIR/state.json"
        exit 0
        ;;
esac
exit 0
STUB
    chmod 755 "$NPM_STUB_DIR/npm"

    # `systemctl --user is-active -q openclaw-gateway.service` gates the update:
    # a global install reifies openclaw's own tree and breaks a running Gateway.
    # Stub it beside npm so the suite never consults the host's real systemd — on
    # this host the Gateway IS running, which would defer every case below and
    # leave the failure path unexercised. SYSTEMCTL_ACTIVE=1 models it running.
    cat > "$NPM_STUB_DIR/systemctl" <<'SYSTEMCTL_STUB'
#!/usr/bin/env bash
(( ${SYSTEMCTL_ACTIVE:-0} )) && exit 0
exit 3      # systemd's "inactive" exit status
SYSTEMCTL_STUB
    chmod 755 "$NPM_STUB_DIR/systemctl"

    export PATH="$NPM_STUB_DIR:$PATH"

    # shellcheck disable=SC1090  # the repo's library loader
    source "$REPO_ROOT/env.sh"
}

teardown() {
    rm -rf "${TAC_TEST_TMPDIR:-/tmp/bats-noop}"
}

@test "npm safety: a failed update that empties the root is rebuilt from the snapshot" {
    printf '{"dependencies":{"alpha":{"version":"1.0.0"},"@scope/beta":{"version":"2.0.0"}}}' \
        > "$NPM_STUB_DIR/state.json"
    : > "$NPM_STUB_DIR/calls.log"
    unset NPM_UPDATE_RESULT

    errCount=0
    run __up_npm_cargo "$(date +%s)" 1 errCount

    # Both packages vanished with the failed update, so both are rebuilt.
    [[ "$output" == *"[FAILED - RESTORED 2 PKG]"* ]]

    # ...and npm was asked for them at the SNAPSHOTTED versions, scoped names intact.
    run grep 'install -g' "$NPM_STUB_DIR/calls.log"
    [[ "$output" == *"alpha@1.0.0"* ]]
    [[ "$output" == *"@scope/beta@2.0.0"* ]]
}

@test "npm safety: a failed update that lost nothing reports intact and reinstalls nothing" {
    printf '{"dependencies":{"alpha":{"version":"1.0.0"}}}' > "$NPM_STUB_DIR/state.json"
    : > "$NPM_STUB_DIR/calls.log"
    export NPM_UPDATE_RESULT=keep

    errCount=0
    run __up_npm_cargo "$(date +%s)" 1 errCount

    [[ "$output" == *"[FAILED - PACKAGES INTACT]"* ]]
    run grep -c 'install -g' "$NPM_STUB_DIR/calls.log"
    [ "$output" = "0" ]
}

@test "npm safety: the step defers while the Gateway is running" {
    printf '{"dependencies":{"alpha":{"version":"1.0.0"}}}' > "$NPM_STUB_DIR/state.json"
    : > "$NPM_STUB_DIR/calls.log"
    export SYSTEMCTL_ACTIVE=1

    errCount=0
    run __up_npm_cargo "$(date +%s)" 1 errCount

    [[ "$output" == *"[DEFERRED - Gateway is running]"* ]]

    # ...and npm was never asked to update or reinstall anything: a global
    # install reifies openclaw's own tree and would break the running Gateway.
    run grep -cE '^(update|install) -g' "$NPM_STUB_DIR/calls.log"
    [ "$output" = "0" ]
}

# end of file
