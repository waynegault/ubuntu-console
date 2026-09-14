#!/usr/bin/env bats
# ==============================================================================
# Unit — tools/check-module-versions.sh (Module Version discipline guard)
# ==============================================================================
# Hermetic: every case builds a throwaway git repository under $BATS_TEST_TMPDIR
# and points the guard at it with --repo, so this repo's index — which another
# session may share — is never staged or committed against.
#
# The guard exists because TACTICAL_PROFILE_VERSION is the SUM of every module's
# `# Module Version: N`: a forgotten bump mislabels every version derived from
# it, while the module still loads and its tests still pass.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export GUARD="$REPO_ROOT/tools/check-module-versions.sh"
    export TMPREPO
    TMPREPO="$(mktemp -d)"

    ( cd "$TMPREPO" \
        && git init -q . \
        && git config user.email t@example.com \
        && git config user.name t \
        && mkdir -p scripts \
        && printf '#!/usr/bin/env bash\n# Module Version: 5\necho hi\n' > scripts/x.sh \
        && git add -A \
        && git commit -qm init )
    mkdir -p "$TMPREPO/.git/info"
}

teardown() {
    rm -rf "${TMPREPO:-/tmp/bats-noop}"
}

@test "module-versions: a changed module that kept its version fails (staged)" {
    printf '#!/usr/bin/env bash\n# Module Version: 5\necho hi\necho more\n' > "$TMPREPO/scripts/x.sh"
    ( cd "$TMPREPO" && git add -A )
    run "$GUARD" --staged --repo "$TMPREPO"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"unchanged on a modified file"* ]]
}

@test "module-versions: a changed module with a bumped version passes (staged)" {
    printf '#!/usr/bin/env bash\n# Module Version: 6\necho hi\necho more\n' > "$TMPREPO/scripts/x.sh"
    ( cd "$TMPREPO" && git add -A )
    run "$GUARD" --staged --repo "$TMPREPO"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"all versions bumped"* ]]
}

@test "module-versions: a changed .sh without the marker is ignored" {
    printf '#!/usr/bin/env bash\necho no-marker\n' > "$TMPREPO/scripts/nomarker.sh"
    ( cd "$TMPREPO" && git add -A )
    run "$GUARD" --staged --repo "$TMPREPO"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"no changed module versions to check"* ]]
}

@test "module-versions: a brand-new module file is skipped (no previous version)" {
    printf '#!/usr/bin/env bash\n# Module Version: 1\necho new\n' > "$TMPREPO/scripts/new.sh"
    ( cd "$TMPREPO" && git add -A )
    run "$GUARD" --staged --repo "$TMPREPO"
    [[ "$status" -eq 0 ]]
}

@test "module-versions: --worktree compares against the given base" {
    printf '#!/usr/bin/env bash\n# Module Version: 5\necho hi\necho more\n' > "$TMPREPO/scripts/x.sh"
    run "$GUARD" --worktree --repo "$TMPREPO"
    [[ "$status" -eq 1 ]]

    printf '#!/usr/bin/env bash\n# Module Version: 7\necho hi\necho more\n' > "$TMPREPO/scripts/x.sh"
    run "$GUARD" --worktree --repo "$TMPREPO"
    [[ "$status" -eq 0 ]]
}

@test "module-versions: refuses with a clear error outside a git repository" {
    local nogit
    nogit="$(mktemp -d)"
    run "$GUARD" --staged --repo "$nogit"
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"not a git repository"* ]]
    rm -rf "$nogit"
}

@test "module-versions: --version prints its version" {
    run "$GUARD" --version
    [[ "$status" -eq 0 ]]
    [[ "$output" == "check-module-versions 1" ]]
}

# end of file
