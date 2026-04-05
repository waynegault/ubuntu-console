#!/usr/bin/env bats
# ==============================================================================
# Integration Tests — Maintenance Pipeline (up command)
# ==============================================================================
# Tests the up function structure (static analysis - fast and reliable)
# Run: bats tests/integration/01-maintenance.bats
# ==============================================================================

setup_file() {
    export REPO_ROOT
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export PROFILE_PATH="$REPO_ROOT/tactical-console.bashrc"
    export TAC_TEST_TMPDIR
    TAC_TEST_TMPDIR="$(mktemp -d)"
    export TAC_CACHE_DIR="$TAC_TEST_TMPDIR/cache"
    mkdir -p "$TAC_CACHE_DIR"
    export __TAC_INITIALIZED=1
    export TAC_SKIP_PWSH=1

    # Build patched scripts directory (same as main test suite)
    local patched_scripts="$TAC_TEST_TMPDIR/scripts"
    mkdir -p "$patched_scripts"
    local _sed_args=(
        -e '/^case \$- in$/,/^esac$/d'
        -e '/^set -E$/d'
        -e "/^trap '__tac_err_handler' ERR$/d"
        -e '/^__tac_preexec_fired=/d'
        -e "/trap.*custom_prompt_command/s/^/# /"
        -e '/^[[:space:]]*((.*__tac_preexec_fired/s/^/# /'
        -e 's/^declare -ri //'
    )
    for _f in "$REPO_ROOT"/scripts/[0-9][0-9]-*.sh; do
        [[ -f "$_f" ]] || continue
        sed "${_sed_args[@]}" "$_f" > "$patched_scripts/$(basename "$_f")"
    done
    # Replace 13-init with minimal stub
    cat > "$patched_scripts/13-init.sh" << 'STUB'
# Minimal test stub
# Module Version: 1
mkdir -p "$OC_ROOT" "$OC_LOGS" "$OC_BACKUPS" "$LLAMA_DRIVE_ROOT/.llm" 2>/dev/null || true
__TAC_BG_PIDS=()
function __tac_exit_cleanup() {
    local pid; for pid in "${__TAC_BG_PIDS[@]}"; do kill "$pid" 2>/dev/null; done
}
STUB
    # Inject TAC_SKIP_PWSH
    sed -i '1a export TAC_SKIP_PWSH=1' "$patched_scripts/01-constants.sh" 2>/dev/null || true

    # Patch and save the loader
    local patched_loader="$TAC_TEST_TMPDIR/profile_patched.bash"
    sed "${_sed_args[@]}" \
        -e "s|_tac_module_dir=.*|_tac_module_dir=\"$patched_scripts\"|" \
        "$PROFILE_PATH" > "$patched_loader"
}

teardown_file() {
    rm -rf "${TAC_TEST_TMPDIR:-/tmp/bats-noop}"
}

setup() {
    export PS1="$ "
    # shellcheck disable=SC1090
    source "$TAC_TEST_TMPDIR/profile_patched.bash" &>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# Tests — Static analysis of function structure (fast, reliable)
# ─────────────────────────────────────────────────────────────────────────────

@test "integration: up function exists" {
    declare -f up >/dev/null 2>&1
}

@test "integration: up shows all 20 steps" {
    local up_src
    up_src=$(declare -f up 2>/dev/null)

    # The up pipeline has 20 steps — verify key milestones exist
    [[ "$up_src" == *"[1/"* ]]  # Internet connectivity
    [[ "$up_src" == *"[2/"* ]]  # APT index
    [[ "$up_src" == *"[3/20] NPM Packages"* ]]
    [[ "$up_src" == *"Cargo Crates"* ]]
    [[ "$up_src" == *"[20/20]"* ]]  # Final step
}

@test "integration: up has --force flag support" {
    local up_src
    up_src=$(declare -f up 2>/dev/null)
    [[ "$up_src" == *"--force"* ]] || [[ "$up_src" == *"force_mode"* ]]
}

@test "integration: up checks connectivity" {
    local up_src
    up_src=$(declare -f up 2>/dev/null)
    [[ "$up_src" == *"Internet"* ]] || [[ "$up_src" == *"Connectivity"* ]]
}

@test "integration: up runs APT update" {
    local up_src
    up_src=$(declare -f up 2>/dev/null)
    # Step label is "Linux Update" (covers both apt index + upgrade)
    [[ "$up_src" == *"Linux Update"* ]] || [[ "$up_src" == *"apt"* ]]
}

@test "integration: up checks NPM" {
    local up_src
    up_src=$(declare -f up 2>/dev/null)
    [[ "$up_src" == *"NPM"* ]] || [[ "$up_src" == *"npm"* ]]
}

@test "integration: up checks R packages" {
    local up_src
    up_src=$(declare -f up 2>/dev/null)
    [[ "$up_src" == *"R Packages"* ]] || [[ "$up_src" == *"Rscript"* ]]
}

@test "integration: up checks OpenClaw" {
    local up_src
    up_src=$(declare -f up 2>/dev/null)
    [[ "$up_src" == *"OpenClaw"* ]] || [[ "$up_src" == *"openclaw doctor"* ]]
}

@test "integration: up checks Python fleet" {
    local up_src
    up_src=$(declare -f up 2>/dev/null)
    [[ "$up_src" == *"Python Fleet"* ]] || [[ "$up_src" == *"python3"* ]]
}

@test "integration: up checks GPU" {
    local up_src
    up_src=$(declare -f up 2>/dev/null)
    [[ "$up_src" == *"GPU"* ]] || [[ "$up_src" == *"nvidia"* ]]
}

@test "integration: up checks disk space" {
    local up_src
    up_src=$(declare -f up 2>/dev/null)
    [[ "$up_src" == *"Disk Space"* ]] || [[ "$up_src" == *"disk"* ]]
}

@test "integration: up has cooldown support" {
    local up_src
    up_src=$(declare -f up 2>/dev/null)
    [[ "$up_src" == *"cooldown"* ]] || [[ "$up_src" == *"__check_cooldown"* ]]
}

@test "integration: up creates cooldown database" {
    local up_src
    up_src=$(declare -f up 2>/dev/null)
    [[ "$up_src" == *"CooldownDB"* ]] || [[ "$up_src" == *"maintenance_cooldowns"* ]]
}

@test "integration: up has help support" {
    local up_src
    up_src=$(declare -f up 2>/dev/null)
    [[ "$up_src" == *"--help"* ]] || [[ "$up_src" == *"Usage"* ]] || [[ "$up_src" == *"usage"* ]]
}

# end of file
