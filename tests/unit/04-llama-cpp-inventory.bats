#!/usr/bin/env bats
# ==============================================================================
# Inventory: llama.cpp installs — identify generic vs custom-tuned builds
#
# Scans all known llama-server binaries on this system and classifies each as:
#
#   generic     — prebuilt release binary (e.g. downloaded from GitHub),
#                 typically CPU-only or minimal backend. Identified by a
#                 release tag (b<N>) in the path and absence of CUDA shared
#                 libraries in the same directory.
#
#   custom-tuned — built from source via CMake with CUDA (or other GPU
#                  backend) enabled. Identified by the presence of CUDA
#                  shared libraries (libggml-cuda.so), a local git repo
#                  for ~/llama.cpp, and custom CMake flags.
#
#   unknown     — exists but doesn't match either pattern above.
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
    # Source project constants to capture LLAMA_SERVER_BIN and LLAMA_ROOT
    source "$REPO_ROOT/env.sh" >/dev/null 2>&1 || true
    source "$REPO_ROOT/scripts/01-constants.sh" >/dev/null 2>&1 || true
}

# ── Helper: resolve a binary path through symlinks ────────────────────────

_resolve() {
    readlink -f "$1" 2>/dev/null || echo "$1"
}

# ── Helper: classify a llama-server binary ────────────────────────────────
# Prints one line: "type|binary_path|resolved_path|build_tag|has_cuda|notes"

_classify() {
    local binary="$1"
    [[ -f "$binary" || -L "$binary" ]] || { echo "missing|$binary||||binary not found"; return 0; }
    [[ -x "$binary" ]] || { echo "not-executable|$binary||||not executable"; return 0; }

    # Resolve symlinks FIRST so all checks operate on the real binary.
    local resolved; resolved="$(_resolve "$binary")"
    local dir; dir="$(dirname "$resolved")"
    local build_tag="" has_cuda="no" type="unknown" notes=""

    # Check for CUDA shared libraries near the resolved binary.
    if [[ -f "$dir/libggml-cuda.so" ]]; then
        has_cuda="yes"
    elif [[ -f "$(dirname "$dir")/libggml-cuda.so" ]]; then
        has_cuda="yes"
    elif [[ -f "$dir/../lib/libggml-cuda.so" ]]; then
        has_cuda="yes"
    fi

    # Build tag: check RESOLVED path for b<N> (generic prebuilt releases).
    if [[ "$resolved" =~ b([0-9]+) ]]; then
        build_tag="b${BASH_REMATCH[1]}"
    fi

    # Find CMakeCache.txt in the build tree (resolved binary's parent chain).
    local cmake_cache
    cmake_cache="$(find "$dir/.." -maxdepth 1 -name CMakeCache.txt 2>/dev/null | head -1)"
    if [[ -z "$cmake_cache" ]]; then
        cmake_cache="$(find "$dir/../.." -maxdepth 1 -name CMakeCache.txt 2>/dev/null | head -1)"
    fi

    local llama_git=""
    [[ -d "$HOME/llama.cpp/.git" ]] && llama_git="$HOME/llama.cpp"

    if [[ -n "$cmake_cache" ]] && grep -q 'GGML_CUDA:BOOL=ON' "$cmake_cache" 2>/dev/null; then
        type="custom-tuned"
        notes="CUDA build from source"
        if [[ -n "$llama_git" ]]; then
            local commit; commit="$(git -C "$llama_git" rev-parse --short HEAD 2>/dev/null || true)"
            notes+=" (commit $commit)"
        fi
    elif [[ -n "$cmake_cache" ]]; then
        type="custom-tuned"
        notes="custom build (no CUDA)"
        if [[ -n "$llama_git" ]]; then
            local commit; commit="$(git -C "$llama_git" rev-parse --short HEAD 2>/dev/null || true)"
            notes+=" (commit $commit)"
        fi
    elif [[ -n "$build_tag" ]]; then
        type="generic"
        notes="prebuilt release $build_tag"
    elif [[ "$has_cuda" == "yes" ]]; then
        type="custom-tuned"
        notes="CUDA build (libggml-cuda.so present, no CMakeCache)"
    else
        type="unknown"
        notes="no classification markers found"
    fi

    echo "${type}|${binary}|${resolved}|${build_tag}|${has_cuda}|${notes}"
}

# ── Test: Inventory all discovered llama-server binaries ──────────────────

@test "inventory: discover all llama-server binaries on the system" {
    local -a discovered=()

    # 1) LLAMA_SERVER_BIN from project env
    if [[ -n "${LLAMA_SERVER_BIN:-}" ]]; then
        discovered+=("$LLAMA_SERVER_BIN")
    fi

    # 2) Standard locations
    for loc in \
        "$HOME/llama.cpp/build/bin/llama-server" \
        "$HOME/.local/bin/llama-server" \
        "$HOME/.local/bin/llama-server-cuda" \
        "$HOME/.local/opt/llama.cpp/"*"/llama-server" \
        "/usr/local/bin/llama-server" \
        "/usr/bin/llama-server"; do
        # Only add if the glob expanded to real files
        for f in $loc; do
            if [[ -f "$f" ]]; then
                discovered+=("$f")
            fi
        done
    done

    # 3) Deduplicate by resolved path
    local -A seen
    local -a unique=()
    for bin in "${discovered[@]}"; do
        local resolved; resolved="$(_resolve "$bin")"
        if [[ -z "${seen[$resolved]:-}" ]]; then
            seen[$resolved]="$bin"
            unique+=("$bin")
        fi
    done

    # Must find at least one llama-server binary
    [[ ${#unique[@]} -ge 1 ]] || {
        skip "No llama-server binaries found on this system"
        return 0
    }

    # Print inventory header
    echo ""
    echo "llama.cpp inventory"
    echo "===================="
    echo ""

    for bin in "${unique[@]}"; do
        _classify "$bin"
    done

    # Verify that LLAMA_SERVER_BIN points to a valid executable
    if [[ -n "${LLAMA_SERVER_BIN:-}" ]]; then
        echo ""
        echo "Project default: LLAMA_SERVER_BIN=${LLAMA_SERVER_BIN}"
        if [[ -x "$LLAMA_SERVER_BIN" ]]; then
            echo "  -> valid executable"
        else
            echo "  -> WARNING: not found or not executable"
        fi
    fi
}

# ── Test: Verify the custom-tuned CUDA build ─────────────────────────────

@test "inventory: custom-tuned build (llama.cpp/build) has CUDA support" {
    local build_bin="$HOME/llama.cpp/build/bin/llama-server"
    [[ -x "$build_bin" ]] || skip "Custom build not found at $build_bin"

    run _classify "$build_bin"
    echo "$output"

    # Should be classified as custom-tuned
    [[ "$output" == *"custom-tuned"* ]] || {
        echo "WARNING: build binary not classified as custom-tuned"
        echo "  -> $output"
    }

    # Should have CUDA shared libs nearby
    local dir; dir="$(dirname "$build_bin")"
    if [[ -f "$dir/../libggml-cuda.so" ]]; then
        echo "  CUDA backend: libggml-cuda.so present in build tree"
    elif ls "$dir/../lib/libggml-cuda.so" 2>/dev/null; then
        echo "  CUDA backend: libggml-cuda.so present in build tree"
    else
        echo "  WARNING: libggml-cuda.so not found — CUDA may be statically linked"
        echo "  (check with: ldd $build_bin | grep cuda)"
    fi

    # Should have a CMakeCache with CUDA enabled
    local cmake_cache; cmake_cache="$(find "$dir/.." -maxdepth 1 -name CMakeCache.txt 2>/dev/null | head -1)"
    if [[ -f "$cmake_cache" ]]; then
        local cuda_flag; cuda_flag=$(grep 'GGML_CUDA:BOOL' "$cmake_cache" 2>/dev/null | head -1)
        echo "  Build flag: $cuda_flag"
    fi
}

# ── Test: Verify the generic/prebuilt binary ──────────────────────────────

@test "inventory: generic prebuilt (b<N>) has no CUDA" {
    # Scan typical prebuilt locations
    local prebuilt=""
    for f in "$HOME/.local/opt/llama.cpp/"*"/llama-server"; do
        if [[ -f "$f" ]]; then
            prebuilt="$f"
            break
        fi
    done
    [[ -n "$prebuilt" ]] || skip "No prebuilt llama-server found"

    run _classify "$prebuilt"
    echo "$output"

    # Should be classified as generic
    [[ "$output" == *"generic"* ]] || {
        echo "WARNING: prebuilt binary not classified as generic"
    }

    # Should NOT have CUDA shared libs in its directory
    local dir; dir="$(dirname "$prebuilt")"
    if [[ -f "$dir/libggml-cuda.so" ]]; then
        echo "  NOTE: libggml-cuda.so found alongside prebuilt (unusual)"
    else
        echo "  No CUDA shared libs in prebuilt directory (expected)"
    fi
}

# ── Test: Symlink consistency ────────────────────────────────────────────

@test "inventory: symlinks resolve to real binaries" {
    # ~/.local/bin/llama-server → prebuilt
    if [[ -L "$HOME/.local/bin/llama-server" ]]; then
        local target; target="$(readlink "$HOME/.local/bin/llama-server")"
        local resolved; resolved="$(_resolve "$HOME/.local/bin/llama-server")"
        echo "  ~/.local/bin/llama-server -> $target"
        echo "  resolves to: $resolved"
        [[ -f "$resolved" ]] || echo "  WARNING: symlink target missing"
        [[ -x "$resolved" ]] || echo "  WARNING: symlink target not executable"
    fi

    # ~/.local/bin/llama-server-cuda → custom-tuned build
    if [[ -L "$HOME/.local/bin/llama-server-cuda" ]]; then
        local target; target="$(readlink "$HOME/.local/bin/llama-server-cuda")"
        local resolved; resolved="$(_resolve "$HOME/.local/bin/llama-server-cuda")"
        echo "  ~/.local/bin/llama-server-cuda -> $target"
        echo "  resolves to: $resolved"
        [[ "$resolved" == "$HOME/llama.cpp/build/bin/llama-server" ]] || \
            echo "  NOTE: cuda symlink points to: $resolved"
    fi
}

# ── Test: LLAMA_SERVER_BIN resolves correctly ────────────────────────────

@test "inventory: LLAMA_SERVER_BIN points to valid binary" {
    [[ -n "${LLAMA_SERVER_BIN:-}" ]] || skip "LLAMA_SERVER_BIN not set"

    echo "  LLAMA_SERVER_BIN=$LLAMA_SERVER_BIN"
    [[ -f "$LLAMA_SERVER_BIN" ]] || {
        echo "  WARNING: file not found"
        return 0
    }
    [[ -x "$LLAMA_SERVER_BIN" ]] || {
        echo "  WARNING: not executable"
        return 0
    }

    local resolved; resolved="$(_resolve "$LLAMA_SERVER_BIN")"
    echo "  resolved: $resolved"

    run _classify "$resolved"
    echo "  classification: $output"
}

# ── Test: Print human-readable inventory summary ─────────────────────────

@test "inventory: summary report" {
    # BATS connects FD3 to the test runner's stdout so diagnostics are visible
    # even on passing tests.  The inventory is the primary deliverable — it must
    # always print.

    >&3 echo ""
    >&3 echo "llama.cpp installs on this system"
    >&3 echo "=================================="
    >&3 echo ""

    # 1) Project config
    >&3 echo "[project config]"
    >&3 echo "  LLAMA_SERVER_BIN = ${LLAMA_SERVER_BIN:-<not set>}"
    local root="${LLAMA_ROOT:-$HOME/llama.cpp}"
    >&3 echo "  LLAMA_ROOT       = $root"
    if [[ -d "$root/.git" ]]; then
        local commit; commit=$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo "unknown")
        local branch; branch=$(git -C "$root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
        >&3 echo "  git commit       = $commit"
        >&3 echo "  git branch       = $branch"
    else
        >&3 echo "  git repo         = not found"
    fi
    >&3 echo ""

    # 2) All binaries
    >&3 echo "[binaries]"
    local -A reported
    for path in \
        "$HOME/llama.cpp/build/bin/llama-server" \
        "$HOME/.local/bin/llama-server" \
        "$HOME/.local/bin/llama-server-cuda" \
        "$HOME/.local/opt/llama.cpp/"*"/llama-server"; do
        for f in $path; do
            [[ -f "$f" ]] || continue
            local resolved; resolved="$(_resolve "$f")"
            [[ -z "${reported[$resolved]:-}" ]] || continue
            reported[$resolved]=1

            local ftype="binary"
            [[ -L "$f" ]] && ftype="symlink"
            local size; size=$(ls -lh "$resolved" 2>/dev/null | awk '{print $5}')
            >&3 echo "  $ftype: $f"
            >&3 echo "    resolved: $resolved"
            >&3 echo "    size: $size"

            run _classify "$f"
            local type; type=$(echo "$output" | cut -d'|' -f1)
            local build_tag; build_tag=$(echo "$output" | cut -d'|' -f4)
            local has_cuda; has_cuda=$(echo "$output" | cut -d'|' -f5)
            local notes; notes=$(echo "$output" | cut -d'|' -f6)
            >&3 echo "    type: $type"
            [[ -z "$build_tag" ]] || >&3 echo "    build: $build_tag"
            >&3 echo "    CUDA: $has_cuda"
            >&3 echo "    notes: $notes"
            >&3 echo ""
        done
    done

    # 3) Build config summary
    if [[ -d "$root/build" ]]; then
        >&3 echo "[build config]"
        local cmake_cache="$root/build/CMakeCache.txt"
        if [[ -f "$cmake_cache" ]]; then
            for flag in GGML_CUDA:BOOL CMAKE_BUILD_TYPE:STRING GGML_CUDA_FA:BOOL GGML_CUDA_GRAPHS:BOOL; do
                local val; val=$(grep "^${flag}=" "$cmake_cache" 2>/dev/null | cut -d= -f2 || echo "<not set>")
                >&3 echo "  ${flag%=*} = $val"
            done
        else
            >&3 echo "  (no CMakeCache.txt)"
        fi
        >&3 echo ""
    fi
}

# ── Helper: fetch the latest GitHub release tag ──────────────────────────
# Returns the tag name (e.g. 9371) or empty on failure. Quick timeout so
# this doesn't block the test suite when offline.

_latest_github_release() {
    local repo="${1:-ggml-org/llama.cpp}"
    local tag
    tag=$(curl -sS --connect-timeout 5 --max-time 15 \
          "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null \
          | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": "\([^"]*\)".*/\1/') || true
    # Strip leading 'b' for numeric comparison
    echo "$tag" | sed 's/^b//'
}

# ── Helper: quick connectivity check ─────────────────────────────────────
# Returns 0 when GitHub is reachable, 1 otherwise.

_github_reachable() {
    curl -sS --connect-timeout 3 --max-time 5 -o /dev/null \
         "https://github.com" 2>/dev/null
}

# ── Helper: download and install a generic release ───────────────────────
# Downloads the latest prebuilt release from GitHub and installs it into
# ~/.local/opt/llama.cpp/b<N>/ with the canonical symlink at
# ~/.local/bin/llama-server (backed up before replacement).
# Requires: curl, unzip, find (for library relocation).

_install_generic_release() {
    local release_tag="$1" # numeric, e.g. 9371
    local repo="${2:-ggml-org/llama.cpp}"
    local dest_dir="$HOME/.local/opt/llama.cpp/b${release_tag}"
    local zip_url="https://github.com/${repo}/releases/download/b${release_tag}/llama-b${release_tag}-bin-ubuntu-x64.zip"

    >&3 echo "  Downloading b${release_tag} from ${repo}..."
    mkdir -p "$dest_dir"

    local tmp_zip; tmp_zip=$(mktemp /tmp/llama-b${release_tag}.XXXXXX.zip)
    if ! curl -sSfL --max-time 120 "$zip_url" -o "$tmp_zip" 2>/dev/null; then
        >&3 echo "  Download failed — release archive may use a different naming pattern."
        >&3 echo "  Check: https://github.com/${repo}/releases/tag/b${release_tag}"
        rm -f "$tmp_zip"
        return 1
    fi

    >&3 echo "  Extracting..."
    unzip -qo "$tmp_zip" -d "$dest_dir" 2>/dev/null || {
        >&3 echo "  Extraction failed"
        rm -f "$tmp_zip"
        return 1
    }
    rm -f "$tmp_zip"

    # Make binaries executable
    chmod +x "$dest_dir"/llama-server "$dest_dir"/llama-cli "$dest_dir"/llama-bench 2>/dev/null || true

    # Relocate shared libraries next to the binary if extracted into a subdirectory
    if [[ -d "$dest_dir/bin" ]]; then
        mv "$dest_dir"/bin/* "$dest_dir"/ 2>/dev/null || true
        rmdir "$dest_dir/bin" 2>/dev/null || true
    fi
    # Relocate lib/
    if [[ -d "$dest_dir/lib" ]]; then
        mv "$dest_dir"/lib/* "$dest_dir"/ 2>/dev/null || true
        rmdir "$dest_dir/lib" 2>/dev/null || true
    fi

    # Update the canonical symlink (back up the current one first)
    local link_path="$HOME/.local/bin/llama-server"
    if [[ -L "$link_path" || -f "$link_path" ]]; then
        cp -P "$link_path" "${link_path}.bak" 2>/dev/null || true
    fi
    ln -sf "$dest_dir/llama-server" "$link_path"

    >&3 echo "  Installed: b${release_tag} → ${dest_dir}/llama-server"
    >&3 echo "  Symlink:   ${link_path} → ${dest_dir}/llama-server"
    return 0
}

# ── Test: Update generic prebuilt to latest GitHub release ───────────────

@test "inventory: update generic prebuilt llama-server from GitHub" {
    # Quick connectivity check so we fail fast when offline.
    if ! _github_reachable; then
        >&3 echo "  (skipping — no network)"
        return 0
    fi

    # Locate the current generic prebuilt
    local generic_bin="" generic_dir="" current_tag=""
    for f in "$HOME/.local/opt/llama.cpp/"*"/llama-server"; do
        if [[ -f "$f" ]] && ! ls "$(dirname "$f")/libggml-cuda.so" >/dev/null 2>&1; then
            generic_bin="$f"
            generic_dir="$(dirname "$f")"
            # Extract build tag from resolved path
            local resolved; resolved="$(_resolve "$f")"
            if [[ "$resolved" =~ b([0-9]+) ]]; then
                current_tag="${BASH_REMATCH[1]}"
            fi
            break
        fi
    done

    if [[ -z "$generic_bin" ]]; then
        >&3 echo "  No generic (prebuilt) llama-server found — installing fresh"
    else
        >&3 echo "  Current generic: $generic_bin"
        >&3 echo "  Current build:   b${current_tag:-?}"
    fi

    # Fetch latest release tag from GitHub
    >&3 echo ""
    >&3 echo "  Checking GitHub releases for ggml-org/llama.cpp..."
    local latest_tag
    latest_tag="$(_latest_github_release)" || true

    if [[ -z "$latest_tag" || ! "$latest_tag" =~ ^[0-9]+$ ]]; then
        >&3 echo "  Could not determine latest release tag (no network or API rate limit)."
        >&3 echo "  Check manually: https://github.com/ggml-org/llama.cpp/releases"
        >&3 echo "  (skipping — no network)"
        return 0
    fi

    >&3 echo "  Latest release:  b${latest_tag}"

    # Compare versions (numeric)
    if [[ -n "$current_tag" ]] && [[ "$current_tag" =~ ^[0-9]+$ ]]; then
        if [[ "$current_tag" -ge "$latest_tag" ]]; then
            >&3 echo "  Already up to date (b${current_tag} ≥ b${latest_tag})"
            return 0
        fi
    fi

    # Download and install the latest
    >&3 echo ""
    >&3 echo "  Updating b${current_tag:-?} → b${latest_tag}..."
    if _install_generic_release "$latest_tag"; then
        >&3 echo ""
        >&3 echo "  Update complete. Run the inventory tests to verify."
    else
        >&3 echo ""
        >&3 echo "  Update failed — release may use a different archive name."
        >&3 echo "  Manual download: https://github.com/ggml-org/llama.cpp/releases/tag/b${latest_tag}"
    fi
}
