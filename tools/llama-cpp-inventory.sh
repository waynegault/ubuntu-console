#!/usr/bin/env bash
# AI INSTRUCTION: Increment version on significant changes.
# Module Version: 5
#   v5 (2026-10-28): the update is ARCHITECTURE-AWARE.  It used to download
#   `llama-b<tag>-bin-ubuntu-x64.zip` unconditionally, which installs a binary an
#   arm64 machine cannot execute.  The asset is now read from the release's own
#   asset list for the host architecture (x64 | arm64) and its real suffix
#   (upstream moved from .zip to .tar.gz).  Release DISCOVERY also changed:
#   /releases/latest answers with the newest release of any kind, and on
#   2026-10-28 that was v0.8.0, which carries no b-tag and no Linux archives, so
#   every `--update` failed with "latest release has no numeric tag_name".  The
#   releases list is read instead and the newest b<digits> release that actually
#   ships this host's Ubuntu archive is selected; one that does not is named.
#   v4 (2026-10-20): a build tag is read from the binary's own version string or the
#   versioned `<root>/llama.cpp/b<digits>/` layout, never from an arbitrary path segment.
#   A BATS temp dir named `bats-run-SULb7C` made a custom binary report build `b7` and
#   reddened CI while the same suite passed locally.
#   v3 (2026-10-16): added the repo's `# end of file` sentinel, which this file never carried -
#   the nightly's hygiene case ("tools/*.sh scripts end with # end of file marker") only runs
#   nightly, so push CI stayed green while the tip was red there.
#   v2 (2026-10-15): §18.3 shapes fixed at source — named exit codes, one stderr writer
#   (`_say`), a comment above every function, and no non-comment line over 120 chars.

set -euo pipefail

# Named exit codes; the shell's own 0/1 stay literal (§18.3 9.7).
readonly EXIT_USAGE=2
readonly EXIT_TOOL_MISSING=127

_SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd "$(dirname "$_SCRIPT_PATH")/.." && pwd)"
_LLAMA_UPDATE_TMPDIR=""

# _say — the one stderr writer, so no ad-hoc `printf ... >&2` sits at a call site (§18.3 10.7).
_say() {
    printf '%s\n' "$*" >&2
}

# _cleanup_update_tmpdir — drop the --update scratch directory, if one was created.
_cleanup_update_tmpdir() {
    [[ -z "$_LLAMA_UPDATE_TMPDIR" ]] || rm -rf -- "$_LLAMA_UPDATE_TMPDIR"
}

# usage — the help text, and the only place the accepted flags are documented.
usage() {
    cat <<'EOF'
Usage: llama-cpp-inventory.sh [--update]
       llama-cpp-inventory.sh --home-only

Report installed llama-server binaries and their build type. By default this is
read-only. --update explicitly downloads the latest Ubuntu release built for
this host's architecture (x64 or arm64) and repoints ~/.local/bin/llama-server,
preserving the previous link as .bak.
--home-only omits system binary paths for isolated diagnostics.
EOF
}

# _resolve — follow symlinks to the real binary path.
_resolve() {
    readlink -f -- "$1"
}

# _classify — print one `type|path|build|cuda|details` row for a binary.
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
    # A build tag comes from the binary's own version string or the versioned
    # layout `<root>/llama.cpp/b<digits>/`, NEVER from an arbitrary path segment:
    # measured 2026-10-20, a BATS temp dir named `bats-run-SULb7C` made a custom
    # binary report build b7 and reddened CI while the same suite passed locally.
    if [[ -z "$build_tag" && "$resolved" =~ /llama\.cpp/b([0-9]+)/ ]]; then
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

# _inventory — list candidate binaries and classify each one once.
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

# _release_arch — llama.cpp's spelling of this host's architecture in its Ubuntu asset names.
_release_arch() {
    local host_arch
    host_arch="$(tac_host_arch)"
    case "$host_arch" in
        x86_64)  printf 'x64\n' ;;
        aarch64) printf 'arm64\n' ;;
        *)
            # Not reachable through tac_host_arch today; kept so a future third name
            # cannot fall through this case and silently select no archive.
            _say "llama-cpp-inventory: no llama.cpp Ubuntu archive is named for $host_arch"
            return 1
            ;;
    esac
}

# _select_release ARCH — print `<build>\t<asset>\t<url>` for the newest b<digits> release
# that ships ARCH's Ubuntu archive.
# /releases/latest is not usable: it answers with the newest release of ANY kind, and
# a non-build tag carries no Linux archive (measured 2026-10-28: v0.8.0 shipped only
# nightly-tag.txt).  A b-release without this host's archive is REFUSED by name, with
# the assets it does carry, rather than skipped in favour of an older build.
_select_release() {
    local arch="$1" python_bin release_json
    # shellcheck source=tools/python-runtime.sh
    source "$REPO_ROOT/tools/python-runtime.sh"
    python_bin="$(_tac_python_path "$REPO_ROOT")"
    release_json="$(curl --fail --silent --show-error --connect-timeout 5 --max-time 15 \
        "https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=20")"
    "$python_bin" -c '
import json, re, sys
arch = sys.argv[1]
releases = json.load(sys.stdin)
if not isinstance(releases, list):
    raise SystemExit("llama.cpp releases response is not a list")
for release in releases:
    tag = release.get("tag_name") or ""
    match = re.fullmatch(r"b([0-9]+)", tag)
    if not match:
        continue
    wanted = re.compile(r"^llama-b%s-bin-ubuntu-(x64|arm64)\.(tar\.gz|zip)$" % match.group(1))
    names = []
    for asset in release.get("assets") or []:
        name = asset.get("name") or ""
        names.append(name)
        found = wanted.match(name)
        if found and found.group(1) == arch:
            print(match.group(1), name, asset.get("browser_download_url") or "", sep="\t")
            raise SystemExit(0)
    raise SystemExit("release %s has no ubuntu-%s archive (assets: %s)"
                     % (tag, arch, ", ".join(names)))
raise SystemExit("no b-tagged release in the first page")
' "$arch" <<<"$release_json"
}

# _update — fetch the latest Ubuntu release for this host and repoint ~/.local/bin/llama-server.
_update() {
    local latest_tag current_tag="" link dest extract_dir archive server
    local release_arch asset_name asset_url selection
    local link_tmp
    : "${HOME:?HOME must be set to update llama.cpp}"
    command -v curl >/dev/null 2>&1 || {
        _say "llama-cpp-inventory: curl is required for --update"
        return "$EXIT_TOOL_MISSING"
    }

    # shellcheck source=tools/arch.sh
    source "$REPO_ROOT/tools/arch.sh"
    release_arch="$(_release_arch)"
    selection="$(_select_release "$release_arch")"
    IFS=$'\t' read -r latest_tag asset_name asset_url <<<"$selection"

    link="$HOME/.local/bin/llama-server"
    if [[ -e "$link" || -L "$link" ]]; then
        local current_path=""
        # A broken or unresolved current link must not prevent the explicit updater from
        # replacing it.
        current_path="$(_resolve "$link" 2>/dev/null || true)" # swallow-ok: unresolvable link
        if [[ "$current_path" =~ /b([0-9]+)/ ]]; then
            current_tag="${BASH_REMATCH[1]}"
        elif [[ -x "$link" ]]; then
            local current_version=""
            # The legacy binary may be unreadable; then there is no current version to compare.
            current_version="$("$link" --version 2>/dev/null || true)" # swallow-ok: unreadable binary
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
            _say "llama-cpp-inventory: existing release directory has no llama-server: $dest"
            return 1
        }
    else
        mkdir -p "$HOME/.cache"
        _LLAMA_UPDATE_TMPDIR="$(mktemp -d "$HOME/.cache/llama-cpp-update.XXXXXX")"
        trap _cleanup_update_tmpdir EXIT
        archive="$_LLAMA_UPDATE_TMPDIR/$asset_name"
        extract_dir="$_LLAMA_UPDATE_TMPDIR/extracted"
        mkdir -p "$extract_dir"
        curl --fail --location --silent --show-error --max-time 120 \
            --output "$archive" "$asset_url"
        # The release's own suffix decides the extractor: upstream publishes
        # .tar.gz today, older builds are .zip, and neither is assumed.
        case "$asset_name" in
            *.tar.gz)
                command -v tar >/dev/null 2>&1 || {
                    _say "llama-cpp-inventory: tar is required for $asset_name"
                    return "$EXIT_TOOL_MISSING"
                }
                tar -xzf "$archive" -C "$extract_dir"
                ;;
            *.zip)
                command -v unzip >/dev/null 2>&1 || {
                    _say "llama-cpp-inventory: unzip is required for $asset_name"
                    return "$EXIT_TOOL_MISSING"
                }
                unzip -q "$archive" -d "$extract_dir"
                ;;
            *)
                _say "llama-cpp-inventory: unsupported release archive: $asset_name"
                return 1
                ;;
        esac
        server="$(find "$extract_dir" -type f -name llama-server -print -quit)"
        [[ -n "$server" ]] || {
            _say "llama-cpp-inventory: release archive contains no llama-server"
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

# main — dispatch the three modes, and refuse anything else with the usage text.
main() {
    case "${1:-}" in
        "") _inventory ;;
        --home-only) [[ $# -eq 1 ]] || { usage >&2; return "$EXIT_USAGE"; }; _inventory no ;;
        --update) [[ $# -eq 1 ]] || { usage >&2; return "$EXIT_USAGE"; }; _update ;;
        -h|--help) [[ $# -eq 1 ]] || { usage >&2; return "$EXIT_USAGE"; }; usage ;;
        *) usage >&2; return "$EXIT_USAGE" ;;
    esac
}

main "$@"

# end of file
