#!/usr/bin/env bash
# AI INSTRUCTION: Increment version on significant changes.
# Module Version: 1

set -euo pipefail

_SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd "$(dirname "$_SCRIPT_PATH")/.." && pwd)"
_LLAMA_UPDATE_TMPDIR=""

_cleanup_update_tmpdir() {
    [[ -z "$_LLAMA_UPDATE_TMPDIR" ]] || rm -rf -- "$_LLAMA_UPDATE_TMPDIR"
}

usage() {
    cat <<'EOF'
Usage: llama-cpp-inventory.sh [--update]
       llama-cpp-inventory.sh --home-only

Report installed llama-server binaries and their build type. By default this is
read-only. --update explicitly downloads the latest Ubuntu x64 release and
repoints ~/.local/bin/llama-server, preserving the previous link as .bak.
--home-only omits system binary paths for isolated diagnostics.
EOF
}

_resolve() {
    readlink -f -- "$1"
}

_classify() {
    local binary="$1" resolved dir version="" build_tag="" cmake_cache=""
    local has_cuda=no type=unknown notes

    [[ -f "$binary" && -x "$binary" ]] || return 1
    resolved="$(_resolve "$binary")"
    dir="$(dirname "$resolved")"
    if version="$("$resolved" --version 2>&1)"; then
        if [[ "$version" =~ \(build[[:space:]]+([0-9]+)\) ]]; then
            build_tag="b${BASH_REMATCH[1]}"
        fi
    else
        version=""
    fi
    if [[ -z "$build_tag" && "$resolved" =~ b([0-9]+) ]]; then
        build_tag="b${BASH_REMATCH[1]}"
    fi

    for cmake_cache in "$dir/../CMakeCache.txt" "$dir/../../CMakeCache.txt"; do
        [[ -f "$cmake_cache" ]] && break
        cmake_cache=""
    done

    if [[ -f "$dir/libggml-cuda.so" \
        || -f "$dir/../libggml-cuda.so" \
        || -f "$dir/../lib/libggml-cuda.so" ]]; then
        has_cuda=yes
    fi

    if [[ -n "$cmake_cache" ]]; then
        type=custom-tuned
        if grep -q '^GGML_CUDA:BOOL=ON$' "$cmake_cache"; then
            notes="CUDA build from source"
        else
            notes="custom build without CUDA"
        fi
    elif [[ "$has_cuda" == yes ]]; then
        type=custom-tuned
        notes="CUDA library present without CMakeCache"
    elif [[ -n "$build_tag" ]]; then
        type=generic
        notes="prebuilt release"
    else
        notes="no build markers found"
    fi

    printf '%s|%s|%s|%s|%s\n' "$type" "$binary" "$build_tag" "$has_cuda" "$notes"
}

_inventory() {
    local path resolved include_system="${1:-yes}"
    local -a candidates=()
    local -A seen=()

    [[ -n "${LLAMA_SERVER_BIN:-}" ]] && candidates+=("$LLAMA_SERVER_BIN")
    for path in \
        "$HOME/llama.cpp/build/bin/llama-server" \
        "$HOME/.local/bin/llama-server" \
        "$HOME/.local/bin/llama-server-cuda" \
        "$HOME/.local/opt/llama.cpp/"*"/llama-server"
    do
        [[ -f "$path" || -L "$path" ]] && candidates+=("$path")
    done
    if [[ "$include_system" == yes ]]; then
        for path in /usr/local/bin/llama-server /usr/bin/llama-server; do
            [[ -f "$path" || -L "$path" ]] && candidates+=("$path")
        done
    fi

    printf '%s\n' "llama.cpp inventory"
    printf '%s\n' "type|path|build|cuda|details"
    for path in "${candidates[@]}"; do
        [[ -f "$path" && -x "$path" ]] || continue
        resolved="$(_resolve "$path")"
        [[ -z "${seen[$resolved]:-}" ]] || continue
        seen["$resolved"]=1
        _classify "$path"
    done
}

_update() {
    local python_bin release_json latest_tag current_tag="" link dest extract_dir archive server
    local link_tmp
    : "${HOME:?HOME must be set to update llama.cpp}"
    command -v curl >/dev/null 2>&1 || {
        printf '%s\n' "llama-cpp-inventory: curl is required for --update" >&2
        return 127
    }
    command -v unzip >/dev/null 2>&1 || {
        printf '%s\n' "llama-cpp-inventory: unzip is required for --update" >&2
        return 127
    }

    # shellcheck source=tools/python-runtime.sh
    source "$REPO_ROOT/tools/python-runtime.sh"
    python_bin="$(_tac_python_path "$REPO_ROOT")"
    release_json="$(curl --fail --silent --show-error --connect-timeout 5 --max-time 15 \
        "https://api.github.com/repos/ggml-org/llama.cpp/releases/latest")"
    latest_tag="$("$python_bin" -c '
import json, re, sys
tag = json.load(sys.stdin).get("tag_name")
match = re.fullmatch(r"b?([0-9]+)", tag or "")
if not match:
    raise SystemExit("latest release has no numeric tag_name")
print(match.group(1))
' <<<"$release_json")"

    link="$HOME/.local/bin/llama-server"
    if [[ -e "$link" || -L "$link" ]]; then
        local current_path=""
        current_path="$(_resolve "$link" 2>/dev/null || true)" # swallow-ok: a broken or unresolved current link must not prevent the explicit updater from replacing it
        if [[ "$current_path" =~ /b([0-9]+)/ ]]; then
            current_tag="${BASH_REMATCH[1]}"
        elif [[ -x "$link" ]]; then
            local current_version=""
            current_version="$("$link" --version 2>/dev/null || true)" # swallow-ok: an unreadable legacy binary has no current version to compare, so the explicit update continues
            if [[ "$current_version" =~ \(build[[:space:]]+([0-9]+)\) ]]; then
                current_tag="${BASH_REMATCH[1]}"
            fi
        fi
    fi
    if [[ "$current_tag" =~ ^[0-9]+$ ]] \
        && (( 10#$current_tag >= 10#$latest_tag )); then
        printf 'Already current: b%s (latest b%s)\n' "$current_tag" "$latest_tag"
        return 0
    fi

    dest="$HOME/.local/opt/llama.cpp/b${latest_tag}"
    if [[ -d "$dest" ]]; then
        server="$(find "$dest" -type f -name llama-server -print -quit)"
        [[ -n "$server" ]] || {
            printf 'llama-cpp-inventory: existing release directory has no llama-server: %s\n' \
                "$dest" >&2
            return 1
        }
    else
        mkdir -p "$HOME/.cache"
        _LLAMA_UPDATE_TMPDIR="$(mktemp -d "$HOME/.cache/llama-cpp-update.XXXXXX")"
        trap _cleanup_update_tmpdir EXIT
        archive="$_LLAMA_UPDATE_TMPDIR/release.zip"
        extract_dir="$_LLAMA_UPDATE_TMPDIR/extracted"
        mkdir -p "$extract_dir"
        curl --fail --location --silent --show-error --max-time 120 \
            "https://github.com/ggml-org/llama.cpp/releases/download/b${latest_tag}/llama-b${latest_tag}-bin-ubuntu-x64.zip" \
            --output "$archive"
        unzip -q "$archive" -d "$extract_dir"
        server="$(find "$extract_dir" -type f -name llama-server -print -quit)"
        [[ -n "$server" ]] || {
            printf '%s\n' "llama-cpp-inventory: release archive contains no llama-server" >&2
            return 1
        }
        mkdir -p "$(dirname "$dest")"
        mv -- "$extract_dir" "$dest"
        server="${server/"$extract_dir"/"$dest"}"
    fi

    chmod +x -- "$server"
    mkdir -p "$(dirname "$link")"
    if [[ -e "$link" || -L "$link" ]]; then
        cp -P -- "$link" "${link}.bak"
    fi
    link_tmp="${link}.tmp.$$"
    ln -s -- "$server" "$link_tmp"
    mv -Tf -- "$link_tmp" "$link"
    printf 'Installed b%s: %s\n' "$latest_tag" "$server"
    printf 'Symlink: %s -> %s\n' "$link" "$server"
}

main() {
    case "${1:-}" in
        "") _inventory ;;
        --home-only) [[ $# -eq 1 ]] || { usage >&2; return 2; }; _inventory no ;;
        --update) [[ $# -eq 1 ]] || { usage >&2; return 2; }; _update ;;
        -h|--help) [[ $# -eq 1 ]] || { usage >&2; return 2; }; usage ;;
        *) usage >&2; return 2 ;;
    esac
}

main "$@"
