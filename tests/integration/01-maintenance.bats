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
    local step_src
    step_src="$(declare -f __up_npm_cargo 2>/dev/null || true)$(declare -f __up_apt_update 2>/dev/null || true)"

    # The up pipeline has 20 steps — verify orchestrator calls helpers
    [[ "$up_src" == *"__up_connectivity"* ]]
    [[ "$up_src" == *"__up_apt_update"* ]]
    [[ "$step_src" == *"[3/20] NPM Packages"* ]]
    [[ "$step_src" == *"Cargo Crates"* ]]
    [[ "$up_src" == *"__up_npm_cache"* ]]  # Final step
}

@test "integration: up has --force flag support" {
    local up_src
    up_src=$(declare -f up 2>/dev/null)
    local step_src
    step_src="$(declare -f __up_connectivity 2>/dev/null || true)$(declare -f __up_apt_update 2>/dev/null || true)"
    [[ "$up_src" == *"--force"* ]] || [[ "$step_src" == *"force_mode"* ]]
}

@test "integration: up checks connectivity" {
    local up_src
    up_src=$(declare -f up 2>/dev/null)
    local step_src
    step_src="$(declare -f __up_connectivity 2>/dev/null || true)"
    # Check that up() delegates to the connectivity helper
    [[ "$up_src" == *"__up_connectivity"* ]] || [[ "$step_src" == *"ping"* ]]
}

@test "integration: up runs APT update" {
    local up_src
    up_src=$(declare -f up 2>/dev/null)
    local step_src
    step_src="$(declare -f __up_apt_update 2>/dev/null || true)"
    [[ "$up_src" == *"__up_apt_update"* ]] || [[ "$step_src" == *"apt"* ]]
}

@test "integration: up checks NPM" {
    local up_src
    up_src=$(declare -f up 2>/dev/null)
    local step_src
    step_src="$(declare -f __up_npm_cargo 2>/dev/null || true)"
    [[ "$up_src" == *"__up_npm_cargo"* ]] || [[ "$step_src" == *"NPM"* ]]
}

@test "integration: up checks R packages" {
    local up_src
    up_src=$(declare -f up 2>/dev/null)
    local step_src
    step_src="$(declare -f __up_r_packages 2>/dev/null || true)"
    [[ "$up_src" == *"__up_r_packages"* ]] || [[ "$step_src" == *"Rscript"* ]]
}

@test "integration: up checks OpenClaw" {
    local up_src
    up_src=$(declare -f up 2>/dev/null)
    local step_src
    step_src="$(declare -f __up_openclaw_doctor 2>/dev/null || true)"
    [[ "$up_src" == *"__up_openclaw_doctor"* ]] || [[ "$step_src" == *"openclaw doctor"* ]]
}

@test "integration: up checks Python fleet" {
    local up_src
    up_src=$(declare -f up 2>/dev/null)
    local step_src
    step_src="$(declare -f __up_python_fleet 2>/dev/null || true)"
    [[ "$up_src" == *"__up_python_fleet"* ]] || [[ "$step_src" == *"python3"* ]]
}

@test "integration: up checks GPU" {
    local up_src
    up_src=$(declare -f up 2>/dev/null)
    local step_src
    step_src="$(declare -f __up_gpu_status 2>/dev/null || true)"
    [[ "$up_src" == *"__up_gpu_status"* ]] || [[ "$step_src" == *"nvidia"* ]]
}

@test "integration: up checks disk space" {
    local up_src
    up_src=$(declare -f up 2>/dev/null)
    local step_src
    step_src="$(declare -f __up_disk_audit 2>/dev/null || true)"
    [[ "$up_src" == *"__up_disk_audit"* ]] || [[ "$step_src" == *"disk"* ]]
}

@test "integration: up has cooldown support" {
    local up_src
    up_src=$(declare -f up 2>/dev/null)
    local step_src
    step_src="$(declare -f __up_apt_update 2>/dev/null || true)"
    [[ "$step_src" == *"cooldown"* ]] || [[ "$step_src" == *"__check_cooldown"* ]]
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
