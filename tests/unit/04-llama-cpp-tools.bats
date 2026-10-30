#!/usr/bin/env bats
# ==============================================================================
# Unit — llama.cpp inventory and explicit release update
# ==============================================================================
# HOME and PATH are sandboxed. The update cases serve a local release archive
# through a curl stub; no test contacts GitHub or changes a user's installation.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export HOME="$BATS_TEST_TMPDIR/home"
    export TAC_CACHE_DIR="$BATS_TEST_TMPDIR/cache"
    mkdir -p "$HOME/llama.cpp/build/bin" "$HOME/llama.cpp/build/lib" \
        "$HOME/.local/opt/llama.cpp/b9371" "$HOME/.local/bin" \
        "$TAC_CACHE_DIR"

    export LLAMA_SERVER_BIN="$HOME/llama.cpp/build/bin/llama-server"
    printf '#!/usr/bin/env bash\nprintf "custom build\\n"\n' > "$LLAMA_SERVER_BIN"
    printf '#!/usr/bin/env bash\nprintf "version (build 9371)\\n"\n' \
        > "$HOME/.local/opt/llama.cpp/b9371/llama-server"
    chmod +x "$LLAMA_SERVER_BIN" "$HOME/.local/opt/llama.cpp/b9371/llama-server"
    printf 'GGML_CUDA:BOOL=ON\n' > "$HOME/llama.cpp/build/CMakeCache.txt"
    : > "$HOME/llama.cpp/build/lib/libggml-cuda.so"
    ln -s "$HOME/.local/opt/llama.cpp/b9371/llama-server" \
        "$HOME/.local/bin/llama-server"
    ln -s "$LLAMA_SERVER_BIN" "$HOME/.local/bin/llama-server-cuda"

    # shellcheck source=env.sh
    source "$REPO_ROOT/env.sh"
    export TAC_CACHE_DIR="$BATS_TEST_TMPDIR/cache"

    MOCK_BIN_DIR="$BATS_TEST_TMPDIR/mocks"
    mkdir -p "$MOCK_BIN_DIR"
    export LLAMA_RELEASE_FIXTURE="$BATS_TEST_TMPDIR/release.zip"
    export CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
    export PATH="$MOCK_BIN_DIR:$PATH"
    cat > "$MOCK_BIN_DIR/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
url=""
output=""
while (($#)); do
    case "$1" in
        --output|-o) output="$2"; shift 2 ;;
        https://*) url="$1"; shift ;;
        *) shift ;;
    esac
done
printf '%s\n' "$url" >> "$CURL_LOG"
if [[ "$url" == *api.github.com* ]]; then
    if [[ "${CURL_API_FAIL:-0}" == 1 ]]; then
        printf '%s\n' "curl: simulated API failure" >&2
        exit 22
    fi
    # The updater reads the RELEASES LIST, not /releases/latest: the newest
    # release of any kind may be a non-build tag (upstream's v0.8.0 carries only
    # nightly-tag.txt), so the selector looks for a b-tagged release carrying
    # this host's Ubuntu archive.
    tag="${CURL_LATEST_TAG:-99999}"
    printf '[{"tag_name":"v0.8.0","assets":[{"name":"nightly-tag.txt","browser_download_url":"https://example.invalid/nightly-tag.txt"}]},'
    assets=()
    # .tar.gz for BOTH arches: upstream moved off .zip at b11969 (see this file's
    # header), and a fixture that only produces a tarball then cannot be the archive a
    # zip-named asset would deliver — measured 2026-10-30, where the arm64 box
    # downloaded a ".tar.gz" and the fixture at that path was a zip, so tar failed.
    if [[ "${CURL_ARM64_ONLY:-0}" != "1" ]]; then
        assets+=("{\"name\":\"llama-b${tag}-bin-ubuntu-x64.tar.gz\",\"browser_download_url\":\"https://example.invalid/llama-b${tag}-bin-ubuntu-x64.tar.gz\"}")
    fi
    if [[ "${CURL_X64_ONLY:-0}" != "1" ]]; then
        assets+=("{\"name\":\"llama-b${tag}-bin-ubuntu-arm64.tar.gz\",\"browser_download_url\":\"https://example.invalid/llama-b${tag}-bin-ubuntu-arm64.tar.gz\"}")
    fi
    printf '{"tag_name":"b%s","assets":[' "$tag"
    printf '%s' "${assets[0]:-}"
    [[ "${#assets[@]}" -le 1 ]] || printf ',%s' "${assets[@]:1}"
    printf ']}]\n'
elif [[ -n "$output" ]]; then
    if [[ "${CURL_ARCHIVE_FAIL:-0}" == 1 ]]; then
        printf '%s\n' "curl: simulated archive failure" >&2
        exit 22
    fi
    cp -- "$LLAMA_RELEASE_FIXTURE" "$output"
else
    exit 22
fi
CURL
    chmod +x "$MOCK_BIN_DIR/curl"
}

@test "inventory classifies sandboxed custom and prebuilt binaries" {
    run "$REPO_ROOT/tools/llama-cpp-inventory.sh" --home-only
    [ "$status" -eq 0 ]
    [[ "$output" == *"custom-tuned|$LLAMA_SERVER_BIN||yes|CUDA build from source"* ]]
    [[ "$output" == *"generic|$HOME/.local/bin/llama-server|b9371|no|prebuilt release"* ]]
    [ "$(grep -cF "$HOME/.local/bin/llama-server" <<<"$output")" -eq 1 ]
}

@test "inventory reports unknown builds when binary version lookup fails" {
    local unknown="$HOME/.local/opt/llama.cpp/unknown/llama-server"
    mkdir -p "$(dirname "$unknown")"
    printf '#!/usr/bin/env bash\nexit 9\n' > "$unknown"
    chmod +x "$unknown"

    export LLAMA_SERVER_BIN="$unknown"
    run "$REPO_ROOT/tools/llama-cpp-inventory.sh" --home-only
    [ "$status" -eq 0 ]
    [[ "$output" == *"unknown|$unknown||no|no build markers found"* ]]
}

@test "explicit update installs from a stubbed release and preserves the old link" {
    # Interpreter from the repo's SHARED resolver, never a hard-coded venv path: a CI
    # checkout has NO .venv, so both `$REPO_ROOT/.venv/bin/python` and `.../python3` die
    # with status 127 there (measured 2026-10-15, runs 38762999750 and 38804176354 -- the
    # first fix only swapped which missing name was used).  _tac_python_path prefers the
    # repository venv and falls back to PATH python3; this case only needs stdlib zipfile.
    # shellcheck source=tools/python-runtime.sh
    source "$REPO_ROOT/tools/python-runtime.sh"
    local _py
    _py="$(_tac_python_path "$REPO_ROOT")"
    local src="$BATS_TEST_TMPDIR/release39"
    mkdir -p "$src/bin" "$src/lib"
    printf '#!/bin/sh\nprintf "version (build 99999)\\n"\n' > "$src/bin/llama-server"
    chmod +x "$src/bin/llama-server"
    : > "$src/lib/libggml-cuda.so"
    tar -czf "$LLAMA_RELEASE_FIXTURE" -C "$src" .

    run "$REPO_ROOT/tools/llama-cpp-inventory.sh" --update
    [ "$status" -eq 0 ]
    [[ "$output" == *"Installed b99999"* ]]
    [ -x "$HOME/.local/opt/llama.cpp/b99999/bin/llama-server" ]
    [ "$(readlink "$HOME/.local/bin/llama-server")" = \
        "$HOME/.local/opt/llama.cpp/b99999/bin/llama-server" ]
    [ "$(readlink "$HOME/.local/bin/llama-server.bak")" = \
        "$HOME/.local/opt/llama.cpp/b9371/llama-server" ]
    [ -z "$(find "$HOME/.cache" -maxdepth 1 -name 'llama-cpp-update.*' -print -quit)" ]
    # Criterion (tools/llama-cpp-inventory.sh v5): the archive fetched is the one
    # built for THIS host.  Catches: the x86_64 archive being installed on arm64.
    #
    # Host-derived, and .tar.gz: it used to grep for the literal x64 .zip, so on the
    # arm64 box (which correctly fetches ubuntu-arm64.tar.gz) the case could only ever
    # pass by fetching the wrong archive — the assertion enforced the bug it names.
    case "$(uname -m)" in
        aarch64|arm64) host_asset="llama-b99999-bin-ubuntu-arm64.tar.gz"; foreign=ubuntu-x64 ;;
        x86_64|amd64)  host_asset="llama-b99999-bin-ubuntu-x64.tar.gz";   foreign=ubuntu-arm64 ;;
        *) echo "FAIL: unsupported arch $(uname -m)"; return 1 ;;
    esac
    grep -qF "$host_asset" "$CURL_LOG"
    ! grep -qF "$foreign" "$CURL_LOG"
}

@test "an arm64 host downloads the arm64 tar.gz, not the x64 archive" {
    # Criterion: upstream publishes both arches, so the host decides.  The tar.gz
    # suffix is the one upstream ships today (measured 2026-10-28, b11969).
    mkdir -p "$BATS_TEST_TMPDIR/release/bin"
    printf '#!/bin/sh\nprintf "version (build 99999)\\n"\n' \
        > "$BATS_TEST_TMPDIR/release/bin/llama-server"
    chmod +x "$BATS_TEST_TMPDIR/release/bin/llama-server"
    tar -czf "$LLAMA_RELEASE_FIXTURE" -C "$BATS_TEST_TMPDIR/release" .

    mkdir -p "$MOCK_BIN_DIR/arm"
    printf '#!/usr/bin/env bash\nprintf "aarch64\\n"\n' > "$MOCK_BIN_DIR/arm/uname"
    chmod +x "$MOCK_BIN_DIR/arm/uname"
    export PATH="$MOCK_BIN_DIR/arm:$PATH"

    run "$REPO_ROOT/tools/llama-cpp-inventory.sh" --update
    [ "$status" -eq 0 ]
    [[ "$output" == *"Installed b99999"* ]]
    [ -x "$HOME/.local/opt/llama.cpp/b99999/bin/llama-server" ]
    grep -qF "llama-b99999-bin-ubuntu-arm64.tar.gz" "$CURL_LOG"
    ! grep -qF "ubuntu-x64" "$CURL_LOG"
}

@test "a b-release without this host's archive is refused by name" {
    # Criterion (fail closed): if the newest b-tagged release ships no archive for
    # this host, the updater says so and installs NOTHING.  Catches: silently
    # falling back to an older build, or downloading a foreign-arch binary.
    # Hide THIS host's archive.  The knob used to be a fixed `CURL_ARM64_ONLY=1`, which
    # means "the release lists only the arm64 build" — and on an arm64 host that is the
    # archive the host wants, so the updater downloaded it and the case failed for the
    # wrong reason (measured 2026-10-30).  Which knob is right depends on the host.
    # The knobs omit an asset: CURL_ARM64_ONLY=1 drops the x64 asset, CURL_X64_ONLY=1
    # drops the arm64 one.  So hiding the host's archive means asking for the OTHER
    # one, which is the opposite knob on each box.
    case "$(uname -m)" in
        aarch64|arm64) export CURL_X64_ONLY=1 ;;    # release lists x64 only -> no arm64 archive
        x86_64|amd64)  export CURL_ARM64_ONLY=1 ;;  # release lists arm64 only -> no x64 archive
        *) echo "FAIL: unsupported arch $(uname -m)"; return 1 ;;
    esac
    local before
    before="$(readlink "$HOME/.local/bin/llama-server")"

    run "$REPO_ROOT/tools/llama-cpp-inventory.sh" --update
    [ "$status" -ne 0 ]
    # The refusal names THIS host's archive, so the expectation has to ask for the host's
    # architecture rather than assume x86_64: the arm64 box was told "no ubuntu-arm64
    # archive" and the case called the correct message a failure (measured 2026-10-30).
    local host_arch
    case "$(uname -m)" in
        x86_64|amd64)   host_arch=ubuntu-x64 ;;
        aarch64|arm64)  host_arch=ubuntu-arm64 ;;
        *) echo "FAIL: unsupported arch $(uname -m)"; return 1 ;;
    esac
    [[ "$output" == *"release b99999 has no ${host_arch} archive"* ]]
    [ "$(readlink "$HOME/.local/bin/llama-server")" = "$before" ]
    [ ! -e "$HOME/.local/opt/llama.cpp/b99999" ]
}

@test "update is idempotent when the current build matches latest" {
    export CURL_LATEST_TAG=9371
    local before
    before="$(readlink "$HOME/.local/bin/llama-server")"

    run "$REPO_ROOT/tools/llama-cpp-inventory.sh" --update
    [ "$status" -eq 0 ]
    [[ "$output" == *"Already current: b9371"* ]]
    [ "$(wc -l < "$CURL_LOG")" -eq 1 ]
    [ "$(readlink "$HOME/.local/bin/llama-server")" = "$before" ]
    [ ! -e "$HOME/.local/bin/llama-server.bak" ]
}

@test "failed release lookup leaves the existing installation unchanged" {
    export CURL_API_FAIL=1
    local before
    before="$(readlink "$HOME/.local/bin/llama-server")"

    run "$REPO_ROOT/tools/llama-cpp-inventory.sh" --update
    [ "$status" -ne 0 ]
    [[ "$output" == *"curl: simulated API failure"* ]]
    [ "$(readlink "$HOME/.local/bin/llama-server")" = "$before" ]
    [ ! -e "$HOME/.local/bin/llama-server.bak" ]
}

@test "failed archive download cleans its temporary files and preserves the link" {
    export CURL_ARCHIVE_FAIL=1
    local before
    before="$(readlink "$HOME/.local/bin/llama-server")"

    run "$REPO_ROOT/tools/llama-cpp-inventory.sh" --update
    [ "$status" -ne 0 ]
    [[ "$output" == *"curl: simulated archive failure"* ]]
    [ "$(readlink "$HOME/.local/bin/llama-server")" = "$before" ]
    [ ! -e "$HOME/.local/bin/llama-server.bak" ]
    [ -z "$(find "$HOME/.cache" -maxdepth 1 -name 'llama-cpp-update.*' -print -quit)" ]
    [ ! -e "$HOME/.local/opt/llama.cpp/b99999" ]
}

@test "llm-build is defined and retains the required CUDA configuration" {
    local src want_arch='DCMAKE_CUDA_ARCHITECTURES=${cuda_arch}'
    src="$(declare -f llm-build)"
    [[ "$src" == *"GGML_CUDA=ON"* ]]
    # Criterion (scripts/11e-llm-model.sh v72): the compute architecture comes from
    # the driver, with 86 as the stated fallback.  Catches: the old hard-coded
    # sm_86 reaching an arm64 CUDA card that needs 121 or 87.
    [[ "$src" == *"$want_arch"* ]]
    [[ "$src" == *"compute_cap"* ]]
    [[ "$src" == *'local cuda_arch="86"'* ]]
    [[ "$src" == *"GGML_CUDA_FA=ON"* ]]
    [[ "$src" != *"GGML_CUDA_FA_ALL_QUANTS"* ]]
    [[ "$src" == *'GGML_CUDA_FA_QUANTS="q4_0-q4_0;q8_0-q8_0;f16-f16;bf16-bf16"'* ]]
    [[ "$src" == *"GGML_NATIVE=ON"* ]]
    [[ "$src" == *"--quick"* ]]
    [[ "$src" == *"--no-pull"* ]]
}

# A runner's BATS temp dir can contain a `b<digits>` fragment — measured
# 2026-10-20: `bats-run-SULb7C` made a custom binary report build `b7` and
# reddened CI while the same suite passed locally. The build tag must come from
# the binary's own version or the versioned `llama.cpp/b<digits>/` layout.
@test "inventory ignores a b<digits> fragment outside the versioned layout" {
    local decoy="$HOME/llama.cpp/build/b7/bin/llama-server"
    mkdir -p "$(dirname "$decoy")"
    printf '#!/usr/bin/env bash\nprintf "custom build\\n"\n' > "$decoy"
    chmod +x "$decoy"
    export LLAMA_SERVER_BIN="$decoy"

    run "$REPO_ROOT/tools/llama-cpp-inventory.sh" --home-only
    [ "$status" -eq 0 ]
    # The build field is empty: `b7` is an ancestor segment, not a build tag.
    [[ "$output" == *"custom-tuned|$decoy||"* ]]
}
