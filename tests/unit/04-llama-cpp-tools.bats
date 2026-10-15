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
    printf '{"tag_name":"b%s"}\n' "${CURL_LATEST_TAG:-99999}"
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
    "$REPO_ROOT/.venv/bin/python" -c '
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as archive:
    archive.writestr("bin/llama-server", "#!/bin/sh\nprintf \"version (build 99999)\\n\"\n")
    archive.writestr("lib/libggml-cuda.so", "")
' "$LLAMA_RELEASE_FIXTURE"

    run "$REPO_ROOT/tools/llama-cpp-inventory.sh" --update
    [ "$status" -eq 0 ]
    [[ "$output" == *"Installed b99999"* ]]
    [ -x "$HOME/.local/opt/llama.cpp/b99999/bin/llama-server" ]
    [ "$(readlink "$HOME/.local/bin/llama-server")" = \
        "$HOME/.local/opt/llama.cpp/b99999/bin/llama-server" ]
    [ "$(readlink "$HOME/.local/bin/llama-server.bak")" = \
        "$HOME/.local/opt/llama.cpp/b9371/llama-server" ]
    [ -z "$(find "$HOME/.cache" -maxdepth 1 -name 'llama-cpp-update.*' -print -quit)" ]
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
    local src
    src="$(declare -f llm-build)"
    [[ "$src" == *"GGML_CUDA=ON"* ]]
    [[ "$src" == *"CMAKE_CUDA_ARCHITECTURES=86"* ]]
    [[ "$src" == *"GGML_CUDA_FA=ON"* ]]
    [[ "$src" != *"GGML_CUDA_FA_ALL_QUANTS"* ]]
    [[ "$src" == *'GGML_CUDA_FA_QUANTS="q4_0-q4_0;q8_0-q8_0;f16-f16;bf16-bf16"'* ]]
    [[ "$src" == *"GGML_NATIVE=ON"* ]]
    [[ "$src" == *"--quick"* ]]
    [[ "$src" == *"--no-pull"* ]]
}
