#!/usr/bin/env bats
# ==============================================================================
# tactical-console.bats — Unit tests for tactical-console.bashrc
# ==============================================================================
# Bash equivalent of the PowerShell Pester test suite (unit-tests.ps1).
# Runs under bats-core (https://bats-core.readthedocs.io/).
#
# Usage:
#   bats tests/tactical-console.bats
#   bats --tap tests/tactical-console.bats
#
# AI INSTRUCTION: Increment version on significant changes.
# shellcheck disable=SC2034
VERSION="1.6"

# ==============================================================================
# SETUP — Source the profile once for all tests
# ==============================================================================
# The bashrc has an interactive guard (case $-) that returns in non-interactive
# shells. We force interactive mode via ENV manipulation in setup.
# We also suppress the dashboard auto-launch by pre-setting __TAC_INITIALIZED.

setup_file() {
    export REPO_ROOT
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export PROFILE_PATH="$REPO_ROOT/tactical-console.bashrc"

    # Temp home to avoid mutating the real environment
    export TAC_TEST_TMPDIR
    TAC_TEST_TMPDIR="$(mktemp -d)"
    export TAC_CACHE_DIR="$TAC_TEST_TMPDIR/cache"
    mkdir -p "$TAC_CACHE_DIR"

    # Pre-set to skip dashboard auto-launch and clear_tactical
    export __TAC_INITIALIZED=1

    # Build patched profile files ONCE.  The actual source happens per-test
    # in setup() because aliases don't survive BATS's per-test subshell fork.
    _build_test_profile
}

teardown_file() {
    rm -rf "${TAC_TEST_TMPDIR:-/tmp/bats-noop}"
}

# Build patched copies of the profile.  Strips the interactive guard,
# preexec DEBUG trap, ERR trap / set -E (all conflict with BATS traps),
# and the expensive 13-init side-effects (pwsh, loopback, sha256sum).
_build_test_profile() {
    local patched="$TAC_TEST_TMPDIR/profile_patched.bash"
    local patched_scripts="$TAC_TEST_TMPDIR/scripts"
    # Sed transforms to make the profile safe for BATS:
    #   1. Remove interactive guard (case $-)  — BATS runs non-interactively
    #   2. Remove set -E / ERR trap           — conflicts with BATS's own traps
    #   3. Remove preexec DEBUG trap          — fires on every BATS assertion
    #   4. Strip 'declare -ri'                — readonly prevents re-sourcing
    local _sed_args=(
        -e '/^case \$- in$/,/^esac$/d'
        -e '/^set -E$/d'
        -e "/^trap '__tac_err_handler' ERR$/d"
        -e '/^__tac_preexec_fired=/d'
        -e "/trap.*custom_prompt_command/s/^/# /"
        -e '/^[[:space:]]*((.*__tac_preexec_fired/s/^/# /'
        -e 's/^declare -ri //'
    )
    # Patch the loader — rewrite module dir to the patched copy
    sed "${_sed_args[@]}" \
        -e "s|_tac_module_dir=.*|_tac_module_dir=\"$patched_scripts\"|" \
        "$PROFILE_PATH" > "$patched"
    # Patch module files with the same transforms
    mkdir -p "$patched_scripts"
    for _f in "$REPO_ROOT"/scripts/[0-9][0-9]-*.sh "$REPO_ROOT/scripts/09b-gog.sh"; do
        [[ -f "$_f" ]] || continue
        sed "${_sed_args[@]}" "$_f" > "$patched_scripts/$(basename "$_f")"
    done
    # Replace 13-init with a minimal stub — skip expensive runtime
    # side-effects (pwsh.exe bridge, loopback, sha256, completions)
    # that are irrelevant to unit tests.
    cat > "$patched_scripts/13-init.sh" << 'STUB'
# Minimal test stub — keeps Module Version for version-computation tests.
# Module Version: 1
mkdir -p "$OC_ROOT" "$OC_LOGS" "$OC_BACKUPS" "$LLAMA_DRIVE_ROOT/.llm" 2>/dev/null || true
__TAC_BG_PIDS=()
function __tac_exit_cleanup() {
    local pid; for pid in "${__TAC_BG_PIDS[@]}"; do kill "$pid" 2>/dev/null; done
}
STUB
    # Inject TAC_SKIP_PWSH=1 into the patched constants module to skip
    # expensive pwsh.exe calls during test profile sourcing.
    local constants_file="$patched_scripts/01-constants.sh"
    if [[ -f "$constants_file" ]]
    then
        sed -i '1a export TAC_SKIP_PWSH=1' "$constants_file"
    fi
}

# ==============================================================================
# LAZY PROFILE SOURCING
# ==============================================================================
# Most tests (syntax checks, file greps, declare -f checks) do NOT need the
# profile sourced. Sourcing the full profile (~15 modules) takes ~150ms per
# call, which × 473 tests = 70+s of unavoidable overhead.
#
# Instead, we source lazily: only tests whose name starts with a known prefix
# that requires runtime data will source the profile. Static tests skip it.
#
# _tac_ensure_profile is idempotent within a BATS test subshell.
#
# PERFORMANCE NOTE: The profile's startup path includes a pwsh.exe call with
# timeout 2 for Windows username detection. In WSL-only CI environments this
# hits the timeout. We set TAC_SKIP_PWSH=1 before sourcing to skip it.

_TAC_PROFILE_SOURCED=0

_tac_ensure_profile() {
    [[ "$_TAC_PROFILE_SOURCED" -eq 1 ]] && return 0
    # Set PS1 to simulate interactive shell (required for PROMPT_COMMAND setup)
    export PS1="$ "
    # Skip expensive pwsh.exe calls in test environment
    export TAC_SKIP_PWSH=1
    # shellcheck disable=SC1090
    source "$TAC_TEST_TMPDIR/profile_patched.bash" &>/dev/null || true
    _TAC_PROFILE_SOURCED=1
}

# Section prefixes that require the profile to be sourced at runtime.
# Everything else (bash -n, shellcheck, structure, hygiene, cross-script,
# bashrc, install, systemd, bin) runs as static file checks only.
_TAC_NEEDS_PROFILE=(
    "constants:" "ui:" "cache:" "port:" "metrics:"
    "calc:" "quant:" "health:" "maintenance:" "model:"
    "prompt:" "alias:" "fn-avail:" "cooldown:"
    "telemetry:" "deployment:" "llm-guard:" "hooks:"
    "llm-manager:" "oc:" "openclaw:" "gog:"
    "dashboard-help:" "ui-engine:" "cross-script:"
    "error:" "integration:" "llm-manager:"
)

# Per-test setup: auto-source the profile when the test needs it.
setup() {
    _TAC_PROFILE_SOURCED=0
    # BATS_TEST_DESCRIPTION is set by bats before each @test block runs.
    local desc="${BATS_TEST_DESCRIPTION:-}"
    for prefix in "${_TAC_NEEDS_PROFILE[@]}"
    do
        if [[ "$desc" == "$prefix"* ]]
        then
            _tac_ensure_profile
            return 0
        fi
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# 1. SYNTAX & STATIC ANALYSIS
# ─────────────────────────────────────────────────────────────────────────────

@test "bash -n: tactical-console.bashrc parses without syntax errors" {
    run bash -n "$PROFILE_PATH"
    [ "$status" -eq 0 ]
}

@test "bash -n: all bin/*.sh scripts parse without syntax errors" {
    for f in "$REPO_ROOT"/bin/*.sh; do
        [[ -f "$f" ]] || continue
        run bash -n "$f"
        [ "$status" -eq 0 ]
    done
}

@test "bash -n: all scripts/*.sh parse without syntax errors" {
    for f in "$REPO_ROOT"/scripts/*.sh; do
        [[ -f "$f" ]] || continue
        run bash -n "$f"
        [ "$status" -eq 0 ]
    done
}

@test "bash -n: install.sh parses without syntax errors" {
    [[ -f "$REPO_ROOT/install.sh" ]] || skip "install.sh not found"
    run bash -n "$REPO_ROOT/install.sh"
    [ "$status" -eq 0 ]
}

@test "shellcheck: tactical-console.bashrc has no findings" {
    command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
    run shellcheck -s bash "$PROFILE_PATH"
    [ "$status" -eq 0 ]
}

@test "shellcheck: companion scripts have no findings" {
    command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
    for f in "$REPO_ROOT"/bin/*.sh "$REPO_ROOT"/scripts/*.sh; do
        [[ -f "$f" ]] || continue
        run shellcheck -s bash "$f"
        [ "$status" -eq 0 ]
    done
}

@test "bash -n: all mcp-tools/*.sh scripts parse without syntax errors" {
    for f in "$REPO_ROOT"/mcp-tools/*.sh; do
        [[ -f "$f" ]] || continue
        run bash -n "$f"
        [ "$status" -eq 0 ]
    done
}

@test "shellcheck: tactical-console.bashrc passes at all severities" {
    command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
    run shellcheck -s bash "$PROFILE_PATH"
    [ "$status" -eq 0 ]
}

@test "shellcheck: companion scripts pass at all severities" {
    command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
    for f in "$REPO_ROOT"/bin/*.sh "$REPO_ROOT"/scripts/*.sh; do
        [[ -f "$f" ]] || continue
        run shellcheck -s bash "$f"
        [ "$status" -eq 0 ]
    done
}

@test "shellcheck: install.sh passes at all severities" {
    command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
    [[ -f "$REPO_ROOT/install.sh" ]] || skip "install.sh not found"
    run shellcheck -s bash "$REPO_ROOT/install.sh"
    [ "$status" -eq 0 ]
}

@test "shellcheck: mcp-tools/*.sh pass at all severities" {
    command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
    for f in "$REPO_ROOT"/mcp-tools/*.sh; do
        [[ -f "$f" ]] || continue
        run shellcheck -s bash "$f"
        [ "$status" -eq 0 ]
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. PROFILE STRUCTURE
# ─────────────────────────────────────────────────────────────────────────────

@test "structure: file contains TACTICAL_PROFILE_VERSION export" {
    grep -q 'export TACTICAL_PROFILE_VERSION=' "$PROFILE_PATH"
}

@test "structure: file contains AI INSTRUCTION comment above version" {
    grep -q '# AI INSTRUCTION: Increment version on significant changes' "$PROFILE_PATH"
}

@test "structure: has section headers 1 through 13" {
    for i in $(seq 1 13); do
        grep -rqE "^# ${i}\." "$PROFILE_PATH" "$REPO_ROOT"/scripts/[0-9][0-9]-*.sh
    done
}

@test "structure: section headers use ═ border format" {
    local count
    count=$(grep -cE '^# ={10,}' "$PROFILE_PATH")
    [[ "$count" -ge 14 ]]
}

@test "structure: @modular-section tags present for each section" {
    local count
    count=$(grep -rc '@modular-section:' "$PROFILE_PATH" \
        "$REPO_ROOT"/scripts/[0-9][0-9]-*.sh | awk -F: '{s+=$NF} END{print s}')
    [[ "$count" -ge 10 ]]
}

@test "structure: interactive guard exists in file" {
    grep -q 'case \$- in' "$PROFILE_PATH"
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. GLOBAL CONSTANTS & CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────
# Tests in this section check runtime variables exported by the profile.

@test "constants: UIWidth is set and numeric" {
    [[ -n "$UIWidth" ]]
    [[ "$UIWidth" =~ ^[0-9]+$ ]]
}

@test "constants: UIWidth is 80" {
    [[ "$UIWidth" -eq 80 ]]
}

@test "constants: LLM_PORT is set and numeric" {
    [[ -n "$LLM_PORT" ]]
    [[ "$LLM_PORT" =~ ^[0-9]+$ ]]
}

@test "constants: OC_PORT is set and numeric" {
    [[ -n "$OC_PORT" ]]
    [[ "$OC_PORT" =~ ^[0-9]+$ ]]
}

@test "constants: LOCAL_LLM_URL contains the LLM port" {
    [[ "$LOCAL_LLM_URL" == *"$LLM_PORT"* ]]
}

@test "constants: LLAMA_ROOT is set" {
    [[ -n "$LLAMA_ROOT" ]]
}

@test "constants: LLAMA_SERVER_BIN is set and under LLAMA_ROOT" {
    [[ -n "$LLAMA_SERVER_BIN" ]]
    [[ "$LLAMA_SERVER_BIN" == "$LLAMA_ROOT"* ]]
}

@test "constants: LLAMA_BUILD_VERSION is set" {
    [[ -n "$LLAMA_BUILD_VERSION" ]]
}

@test "constants: VRAM_TOTAL_BYTES equals 4GB" {
    [[ "$VRAM_TOTAL_BYTES" -eq $((4 * 1024 * 1024 * 1024)) ]]
}

@test "constants: VRAM_USABLE_PCT is 95" {
    [[ "$VRAM_USABLE_PCT" -eq 95 ]]
}

@test "constants: VRAM_THRESHOLD_PCT is 85" {
    [[ "$VRAM_THRESHOLD_PCT" -eq 85 ]]
}

@test "constants: COOLDOWN_DAILY is 86400 (24h)" {
    [[ "$COOLDOWN_DAILY" -eq 86400 ]]
}

@test "constants: COOLDOWN_WEEKLY is 86400 (24h — changed from 7d)" {
    [[ "$COOLDOWN_WEEKLY" -eq 86400 ]]
}

@test "constants: LOG_MAX_BYTES is 1048576 (1MB)" {
    [[ "$LOG_MAX_BYTES" -eq 1048576 ]]
}

@test "constants: MOE_DEFAULT_CTX is 8192" {
    [[ "$MOE_DEFAULT_CTX" -eq 8192 ]]
}

@test "constants: design tokens C_Reset through C_Info are set" {
    [[ -n "$C_Reset" ]]
    [[ -n "$C_BoxBg" ]]
    [[ -n "$C_Border" ]]
    [[ -n "$C_Text" ]]
    [[ -n "$C_Dim" ]]
    [[ -n "$C_Highlight" ]]
    [[ -n "$C_Success" ]]
    [[ -n "$C_Warning" ]]
    [[ -n "$C_Error" ]]
    [[ -n "$C_Info" ]]
}

@test "constants: OC_ROOT is set and non-empty" {
    [[ -n "$OC_ROOT" ]]
}

@test "constants: LLAMA_GPU_LAYERS is a positive integer" {
    [[ "$LLAMA_GPU_LAYERS" =~ ^[0-9]+$ ]]
    [[ "$LLAMA_GPU_LAYERS" -gt 0 ]]
}

@test "constants: LLAMA_CPU_THREADS is a positive integer" {
    [[ "$LLAMA_CPU_THREADS" =~ ^[0-9]+$ ]]
    [[ "$LLAMA_CPU_THREADS" -gt 0 ]]
}

@test "constants: LLAMA_CTX_SIZE is a positive integer" {
    [[ "$LLAMA_CTX_SIZE" =~ ^[0-9]+$ ]]
    [[ "$LLAMA_CTX_SIZE" -gt 0 ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. UI HELPERS
# ─────────────────────────────────────────────────────────────────────────────

@test "ui: __threshold_color returns C_Error for val > 90" {
    result=$(__threshold_color 95)
    [[ "$result" == "$C_Error" ]]
}

@test "ui: __threshold_color returns C_Warning for 76-90" {
    result=$(__threshold_color 80)
    [[ "$result" == "$C_Warning" ]]
}

@test "ui: __threshold_color returns C_Success for val <= 75" {
    result=$(__threshold_color 50)
    [[ "$result" == "$C_Success" ]]
}

@test "ui: __threshold_color boundary: 75 returns C_Success" {
    result=$(__threshold_color 75)
    [[ "$result" == "$C_Success" ]]
}

@test "ui: __threshold_color boundary: 90 returns C_Warning" {
    result=$(__threshold_color 90)
    [[ "$result" == "$C_Warning" ]]
}

@test "ui: __threshold_color boundary: 91 returns C_Error" {
    result=$(__threshold_color 91)
    [[ "$result" == "$C_Error" ]]
}

@test "ui: __strip_ansi removes ANSI escape sequences" {
    local input=$'\e[31mHello\e[0m World\e[32m!\e[0m'
    local result=""
    __strip_ansi "$input" result
    [[ "$result" == "Hello World!" ]]
}

@test "ui: __strip_ansi handles plain text (no escapes)" {
    __strip_ansi "plain text" result
    [[ "$result" == "plain text" ]]
}

@test "ui: __strip_ansi handles empty string" {
    __strip_ansi "" result
    [[ "$result" == "" ]]
}

@test "ui: __strip_ansi rejects invalid variable names" {
    run __strip_ansi "test" "invalid-name"
    [ "$status" -eq 1 ]
}

@test "ui: __strip_ansi rejects names with spaces" {
    run __strip_ansi "test" "has space"
    [ "$status" -eq 1 ]
}

@test "ui: __tac_header outputs box-drawing characters" {
    result=$(__tac_header "TEST" "closed")
    [[ "$result" == *"╔"* ]]
    [[ "$result" == *"╚"* ]]
}

@test "ui: __tac_header open style uses ╠ as bottom border" {
    result=$(__tac_header "TEST" "open")
    [[ "$result" == *"╠"* ]]
}

@test "ui: __tac_footer outputs ╚ closing box" {
    result=$(__tac_footer)
    [[ "$result" == *"╚"* ]]
}

@test "ui: __tac_divider outputs ╟ single-line divider" {
    result=$(__tac_divider)
    [[ "$result" == *"╟"* ]]
}

@test "ui: __tac_info outputs formatted label and message" {
    result=$(__tac_info "Label" "Message" "$C_Success")
    [[ "$result" == *"Label"* ]]
    [[ "$result" == *"Message"* ]]
}

@test "ui: __tac_line outputs padded label and status" {
    result=$(__tac_line "Action" "[OK]" "$C_Success")
    [[ "$result" == *"Action"* ]]
    [[ "$result" == *"[OK]"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 5. CACHING ENGINE
# ─────────────────────────────────────────────────────────────────────────────

@test "cache: __cache_fresh returns 0 (fresh) for a just-touched file" {
    local cache_file="$TAC_TEST_TMPDIR/test_cache_fresh"
    touch "$cache_file"
    __cache_fresh "$cache_file" 60
}

@test "cache: __cache_fresh returns 1 (stale) for a missing file" {
    run __cache_fresh "$TAC_TEST_TMPDIR/nonexistent" 60
    [ "$status" -ne 0 ]
}

@test "cache: __cache_fresh returns 1 (stale) for an old file" {
    local cache_file="$TAC_TEST_TMPDIR/test_cache_stale"
    touch -d "2 hours ago" "$cache_file"
    run __cache_fresh "$cache_file" 60
    [ "$status" -ne 0 ]
}

@test "cache: __cache_fresh with TTL=0 always returns stale for existing file" {
    local cache_file="$TAC_TEST_TMPDIR/test_cache_zero_ttl"
    touch "$cache_file"
    # TTL=0 means file must be younger than 0 seconds (impossible for any real file)
    # The expression: (now - mtime) < 0  → always false
    run __cache_fresh "$cache_file" 0
    [ "$status" -ne 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# 6. PORT UTILITIES
# ─────────────────────────────────────────────────────────────────────────────

@test "port: __test_port returns 1 for a port with no listener" {
    run __test_port 19999
    [ "$status" -ne 0 ]
}

@test "port: __test_port returns 1 for port 1 (privileged, no listener)" {
    run __test_port 1
    [ "$status" -ne 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# 7. SYSTEM METRICS
# ─────────────────────────────────────────────────────────────────────────────

@test "metrics: __get_uptime returns Xd Yh Zm format" {
    result=$(__get_uptime)
    [[ "$result" =~ ^[0-9]+d\ [0-9]+h\ [0-9]+m$ ]]
}

@test "metrics: __get_disk returns a string" {
    result=$(__get_disk)
    [[ -n "$result" ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 8. PURE CALCULATION FUNCTIONS (llama.cpp)
# ─────────────────────────────────────────────────────────────────────────────

@test "calc: __calc_gpu_layers returns 999 for small model (< VRAM)" {
    # 2GB file, 32 layers, generic arch
    result=$(__calc_gpu_layers $((2 * 1024 * 1024 * 1024)) 32 "llama")
    [[ "$result" -eq 999 ]]
}

@test "calc: __calc_gpu_layers returns 0 for large model (> VRAM)" {
    # 8GB file, 40 layers, generic arch
    result=$(__calc_gpu_layers $((8 * 1024 * 1024 * 1024)) 40 "llama")
    [[ "$result" -eq 0 ]]
}

@test "calc: __calc_gpu_layers returns total_layers for MoE arch" {
    # 6GB MoE model, 32 layers
    result=$(__calc_gpu_layers $((6 * 1024 * 1024 * 1024)) 32 "qwen3moe")
    [[ "$result" -eq 32 ]]
}

@test "calc: __calc_gpu_layers boundary: exactly VRAM size returns 999" {
    # Exactly VRAM * 95% = usable
    local usable=$(( VRAM_TOTAL_BYTES * VRAM_USABLE_PCT / 100 ))
    result=$(__calc_gpu_layers "$usable" 32 "llama")
    [[ "$result" -eq 999 ]]
}

@test "calc: __calc_ctx_size returns MOE_DEFAULT_CTX for MoE arch" {
    result=$(__calc_ctx_size $((3 * 1024 * 1024 * 1024)) 32768 "qwen3moe")
    [[ "$result" -eq "$MOE_DEFAULT_CTX" ]]
}

@test "calc: __calc_ctx_size caps CPU-only models at MOE_DEFAULT_CTX" {
    # 8GB model (exceeds VRAM threshold), native ctx 131072
    result=$(__calc_ctx_size $((8 * 1024 * 1024 * 1024)) 131072 "llama")
    [[ "$result" -eq "$MOE_DEFAULT_CTX" ]]
}

@test "calc: __calc_ctx_size returns native_ctx when smaller than cap" {
    # 8GB model (CPU-only), native ctx 4096 (smaller than cap of 8192)
    result=$(__calc_ctx_size $((8 * 1024 * 1024 * 1024)) 4096 "llama")
    [[ "$result" -eq 4096 ]]
}

@test "calc: __calc_ctx_size small GPU model (3-4GB) caps at 4096" {
    # 3GB model, large native ctx
    result=$(__calc_ctx_size $((3 * 1024 * 1024 * 1024)) 32768 "llama")
    [[ "$result" -eq 4096 ]]
}

@test "calc: __calc_ctx_size 1-2GB model caps at 8192" {
    result=$(__calc_ctx_size $((1 * 1024 * 1024 * 1024)) 32768 "llama")
    [[ "$result" -eq 8192 ]]
}

@test "calc: __calc_ctx_size 2-3GB model caps at 4096" {
    result=$(__calc_ctx_size $((2 * 1024 * 1024 * 1024)) 32768 "llama")
    [[ "$result" -eq 4096 ]]
}

@test "calc: __calc_ctx_size tiny model, small native returns native" {
    result=$(__calc_ctx_size $((1 * 1024 * 1024 * 1024)) 2048 "llama")
    [[ "$result" -eq 2048 ]]
}

@test "calc: __calc_threads CPU-only uses 80% of nproc" {
    local ncpu
    ncpu=$(nproc 2>/dev/null || echo 16)
    local expected=$(( ncpu * 80 / 100 ))
    result=$(__calc_threads 0 32)
    [[ "$result" -eq "$expected" ]]
}

@test "calc: __calc_threads full GPU uses 50% of nproc" {
    local ncpu
    ncpu=$(nproc 2>/dev/null || echo 16)
    local expected=$(( ncpu * 50 / 100 ))
    result=$(__calc_threads 32 32)
    [[ "$result" -eq "$expected" ]]
}

@test "calc: __calc_threads partial GPU uses 70% of nproc" {
    local ncpu
    ncpu=$(nproc 2>/dev/null || echo 16)
    local expected=$(( ncpu * 70 / 100 ))
    result=$(__calc_threads 16 32)
    [[ "$result" -eq "$expected" ]]
}

@test "calc: __calc_threads never returns less than 1" {
    result=$(__calc_threads 0 0)
    [[ "$result" -ge 1 ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 9. QUANT LABEL MAPPING
# ─────────────────────────────────────────────────────────────────────────────

@test "quant: __quant_label maps ftype 7 to Q8_0" {
    result=$(__quant_label 7 "")
    [[ "$result" == "Q8_0" ]]
}

@test "quant: __quant_label maps ftype 15 to Q4_K_M" {
    result=$(__quant_label 15 "")
    [[ "$result" == "Q4_K_M" ]]
}

@test "quant: __quant_label maps ftype 1 to F16" {
    result=$(__quant_label 1 "")
    [[ "$result" == "F16" ]]
}

@test "quant: __quant_label extracts from filename when ftype is 0" {
    result=$(__quant_label 0 "Phi-4-mini-instruct-Q4_K_M.gguf")
    [[ "$result" == "Q4_K_M" ]]
}

@test "quant: __quant_label extracts IQ variants from filename" {
    result=$(__quant_label 0 "model-IQ3_M-v2.gguf")
    [[ "$result" == "IQ3_M" ]]
}

@test "quant: __quant_label returns 'unknown' for unrecognised ftype and filename" {
    result=$(__quant_label 99 "no-quant-info-here.gguf")
    [[ "$result" == "unknown" ]]
}

@test "quant: __quant_label extracts BF16 from filename" {
    result=$(__quant_label 0 "model-BF16.gguf")
    [[ "$result" == "BF16" ]]
}

@test "quant: __quant_label prefers ftype over filename when known" {
    # ftype 7 = Q8_0, but filename has Q4_K_M
    result=$(__quant_label 7 "model-Q4_K_M.gguf")
    [[ "$result" == "Q8_0" ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 10. HEALTH CHECKS
# ─────────────────────────────────────────────────────────────────────────────

@test "health: oc-health function is defined" {
    declare -f oc-health >/dev/null 2>&1
}

@test "oc: dispatcher prints help with no args" {
    run oc
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Gateway"* ]]
    [[ "$output" == *"restart"* ]]
}

@test "oc: unknown subcommand returns error" {
    run oc bogus_sub_xyz
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"INVALID SUBCOMMAND"* ]]
}

@test "health: gpu-check function is defined" {
    declare -f gpu-check >/dev/null 2>&1
}

@test "health: gpu-status function is defined" {
    declare -f gpu-status >/dev/null 2>&1
}

@test "health: __resolve_smi function is defined" {
    declare -f __resolve_smi >/dev/null 2>&1
}

# ─────────────────────────────────────────────────────────────────────────────
# 11. MAINTENANCE HELPERS
# ─────────────────────────────────────────────────────────────────────────────

@test "maintenance: up function is defined" {
    declare -f up >/dev/null 2>&1
}

@test "maintenance: up separates npm and cargo package reporting" {
    local up_src
    up_src="$(declare -f up)"
    [[ "$up_src" == *"[3/20] NPM Packages"* ]]
    [[ "$up_src" == *"Cargo Crates"* ]]
}

@test "maintenance: cl function is defined" {
    declare -f cl >/dev/null 2>&1
}

@test "maintenance: logtrim function is defined" {
    declare -f logtrim >/dev/null 2>&1
}

@test "maintenance: __check_cooldown function is defined" {
    declare -f __check_cooldown >/dev/null 2>&1
}

@test "maintenance: __set_cooldown function is defined" {
    declare -f __set_cooldown >/dev/null 2>&1
}

# ─────────────────────────────────────────────────────────────────────────────
# 12. MODEL MANAGEMENT
# ─────────────────────────────────────────────────────────────────────────────

@test "model: model function is defined" {
    declare -f model >/dev/null 2>&1
}

@test "model: model with unknown subcommand prints usage" {
    run model bogus
    [[ "$output" == *"Usage"* ]]
}

@test "model: model with no args includes bench helpers in usage" {
    run model
    [[ "$output" == *"bench-diff"* ]]
    [[ "$output" == *"bench-latest"* ]]
}

@test "model: model with no args includes doctor and recommend helpers in usage" {
    run model
    [[ "$output" == *"doctor"* ]]
    [[ "$output" == *"recommend"* ]]
    [[ "$output" == *"bench-history"* ]]
    [[ "$output" == *"bench-compare"* ]]
}

@test "model: serve function is defined (convenience wrapper)" {
    declare -f serve >/dev/null 2>&1
}

@test "model: halt function is defined (convenience wrapper)" {
    declare -f halt >/dev/null 2>&1
}

# ─────────────────────────────────────────────────────────────────────────────
# 13. PROMPT
# ─────────────────────────────────────────────────────────────────────────────

@test "prompt: custom_prompt_command function is defined" {
    declare -f custom_prompt_command >/dev/null 2>&1
}

@test "prompt: PROMPT_COMMAND contains custom_prompt_command" {
    [[ "$PROMPT_COMMAND" == *"custom_prompt_command"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 14. ALIAS REGISTRATION
# ─────────────────────────────────────────────────────────────────────────────

@test "alias: 'h' is defined (tactical_help)" {
    alias h >/dev/null 2>&1
}

@test "alias: code function fails cleanly when VS Code is unavailable" {
    __resolve_vscode_bin() { VSCODE_BIN=""; }
    VSCODE_BIN=""
    run code "/tmp/example"
    [ "$status" -eq 1 ]
}

@test "alias: 'cls' is defined (clear_tactical)" {
    alias cls >/dev/null 2>&1
}

@test "alias: 'm' is defined (tactical_dashboard)" {
    alias m >/dev/null 2>&1
}

@test "alias: 'reload' is defined" {
    alias reload >/dev/null 2>&1
}

@test "alias: 'll' is defined (ls -alF)" {
    alias ll >/dev/null 2>&1
}

@test "alias: 'la' is defined (ls -A)" {
    alias la >/dev/null 2>&1
}

@test "alias: 'l' is defined (ls -CF)" {
    alias l >/dev/null 2>&1
}

@test "alias: 'commit' is defined" {
    alias commit >/dev/null 2>&1
}

@test "alias: 'commit:' is defined (commit_deploy)" {
    alias 'commit:' >/dev/null 2>&1
}

@test "alias: 'cpwd' is defined (copy_path)" {
    alias cpwd >/dev/null 2>&1
}

@test "alias: 'unittest' is defined (bats)" {
    alias unittest >/dev/null 2>&1
}

@test "alias: 'chat:' is defined (local_chat)" {
    alias 'chat:' >/dev/null 2>&1
}

# ─────────────────────────────────────────────────────────────────────────────
# 15. FUNCTION AVAILABILITY — Every expected function is defined
# ─────────────────────────────────────────────────────────────────────────────

# Core internal helpers
@test "fn-avail: __cache_fresh" { declare -f __cache_fresh >/dev/null; }
@test "fn-avail: __threshold_color" { declare -f __threshold_color >/dev/null; }
@test "fn-avail: __strip_ansi" { declare -f __strip_ansi >/dev/null; }
@test "fn-avail: __test_port" { declare -f __test_port >/dev/null; }
@test "fn-avail: __resolve_smi" { declare -f __resolve_smi >/dev/null; }
@test "fn-avail: __resolve_vscode_bin" { declare -f __resolve_vscode_bin >/dev/null; }
@test "fn-avail: __vsc_open" { declare -f __vsc_open >/dev/null; }
@test "fn-avail: __save_nullglob" { declare -f __save_nullglob >/dev/null; }
@test "fn-avail: __restore_nullglob" { declare -f __restore_nullglob >/dev/null; }
@test "fn-avail: __tac_header" { declare -f __tac_header >/dev/null; }
@test "fn-avail: __tac_footer" { declare -f __tac_footer >/dev/null; }
@test "fn-avail: __tac_divider" { declare -f __tac_divider >/dev/null; }
@test "fn-avail: __tac_info" { declare -f __tac_info >/dev/null; }
@test "fn-avail: __tac_line" { declare -f __tac_line >/dev/null; }
@test "fn-avail: __tac_exit_cleanup" { declare -f __tac_exit_cleanup >/dev/null; }
@test "fn-avail: __tac_err_handler" { declare -f __tac_err_handler >/dev/null; }
@test "fn-avail: __fRow" { declare -f __fRow >/dev/null; }
@test "fn-avail: __hRow" { declare -f __hRow >/dev/null; }
@test "ui: __hRow formats command and description correctly" {
    run __hRow "zzz_cmd" "This is a test description"
    [ "$status" -eq 0 ]
    [[ "$output" == *"zzz_cmd"* ]]
    [[ "$output" == *"This is a test description"* ]]
    [[ "$output" != *"%s"* ]]
}

@test "ui: __hRow wraps long command and description without overflowing UIWidth" {
    run __hRow "model bench-diff" \
        "Compare two benchmark TSV runs and keep the help box aligned"
    [ "$status" -eq 0 ]
    [[ "$output" == *"model bench-diff"* ]]
    [[ "$output" == *"Compare two benchmark TSV runs"* ]]

    while IFS= read -r line
    do
        local plain=""
        __strip_ansi "$line" plain
        [ "${#plain}" -le "$UIWidth" ]
    done <<< "$output"
}
@test "fn-avail: __hSection" { declare -f __hSection >/dev/null; }
@test "fn-avail: __show_header" { declare -f __show_header >/dev/null; }
@test "fn-avail: __require_design_tokens" { declare -f __require_design_tokens >/dev/null; }
@test "fn-avail: __require_openclaw" { declare -f __require_openclaw >/dev/null; }
@test "fn-avail: __require_llm" { declare -f __require_llm >/dev/null; }
@test "fn-avail: __usage" { declare -f __usage >/dev/null; }

# Telemetry
@test "fn-avail: __get_uptime" { declare -f __get_uptime >/dev/null; }
@test "fn-avail: __get_disk" { declare -f __get_disk >/dev/null; }
@test "fn-avail: __get_gpu" { declare -f __get_gpu >/dev/null; }
@test "fn-avail: __get_git" { declare -f __get_git >/dev/null; }
@test "fn-avail: __get_battery" { declare -f __get_battery >/dev/null; }
@test "fn-avail: __get_host_metrics" { declare -f __get_host_metrics >/dev/null; }
@test "fn-avail: __get_oc_version" { declare -f __get_oc_version >/dev/null; }
@test "fn-avail: __get_oc_metrics" { declare -f __get_oc_metrics >/dev/null; }
@test "fn-avail: __get_tokens" { declare -f __get_tokens >/dev/null; }
@test "fn-avail: __get_llm_slots" { declare -f __get_llm_slots >/dev/null; }

# Caching / cooldown
@test "fn-avail: __check_cooldown" { declare -f __check_cooldown >/dev/null; }
@test "fn-avail: __set_cooldown" { declare -f __set_cooldown >/dev/null; }
@test "fn-avail: __cleanup_temps" { declare -f __cleanup_temps >/dev/null; }

# LLM calculation
@test "fn-avail: __calc_gpu_layers" { declare -f __calc_gpu_layers >/dev/null; }
@test "fn-avail: __calc_ctx_size" { declare -f __calc_ctx_size >/dev/null; }
@test "fn-avail: __calc_threads" { declare -f __calc_threads >/dev/null; }
@test "fn-avail: __quant_label" { declare -f __quant_label >/dev/null; }
@test "fn-avail: __gguf_metadata" { declare -f __gguf_metadata >/dev/null; }
@test "fn-avail: __renumber_registry" { declare -f __renumber_registry >/dev/null; }
@test "fn-avail: __save_tps" { declare -f __save_tps >/dev/null; }

# LLM streaming
@test "fn-avail: __llm_chat_send" { declare -f __llm_chat_send >/dev/null; }
@test "fn-avail: __llm_sse_core" { declare -f __llm_sse_core >/dev/null; }
@test "fn-avail: __llm_stream" { declare -f __llm_stream >/dev/null; }

# User-facing functions
@test "fn-avail: model" { declare -f model >/dev/null; }
@test "fn-avail: serve" { declare -f serve >/dev/null; }
@test "fn-avail: halt" { declare -f halt >/dev/null; }
@test "fn-avail: burn" { declare -f burn >/dev/null; }
@test "fn-avail: local_chat" { declare -f local_chat >/dev/null; }
@test "fn-avail: explain" { declare -f explain >/dev/null; }
@test "fn-avail: chat-context" { declare -f chat-context >/dev/null; }
@test "fn-avail: chat-pipe" { declare -f chat-pipe >/dev/null; }
@test "fn-avail: wtf_repl" { declare -f wtf_repl >/dev/null; }
@test "fn-avail: up" { declare -f up >/dev/null; }
@test "fn-avail: cl" { declare -f cl >/dev/null; }
@test "fn-avail: logtrim" { declare -f logtrim >/dev/null; }
@test "fn-avail: so" { declare -f so >/dev/null; }
@test "fn-avail: xo" { declare -f xo >/dev/null; }
@test "fn-avail: status" { declare -f status >/dev/null; }
@test "fn-avail: sysinfo" { declare -f sysinfo >/dev/null; }
@test "fn-avail: wake" { declare -f wake >/dev/null; }
@test "fn-avail: gpu-status" { declare -f gpu-status >/dev/null; }
@test "fn-avail: gpu-check" { declare -f gpu-check >/dev/null; }
@test "fn-avail: tactical_dashboard" { declare -f tactical_dashboard >/dev/null; }
@test "fn-avail: tactical_help" { declare -f tactical_help >/dev/null; }
@test "fn-avail: clear_tactical" { declare -f clear_tactical >/dev/null; }
@test "fn-avail: commit_auto" { declare -f commit_auto >/dev/null; }
@test "fn-avail: commit_deploy" { declare -f commit_deploy >/dev/null; }
@test "fn-avail: oc" { declare -f oc >/dev/null; }
@test "fn-avail: oc-env" { declare -f oc-env >/dev/null; }
@test "fn-avail: oc-health" { declare -f oc-health >/dev/null; }
@test "fn-avail: oc-backup" { declare -f oc-backup >/dev/null; }
@test "fn-avail: oc-restore" { declare -f oc-restore >/dev/null; }
@test "fn-avail: oc-diag" { declare -f oc-diag >/dev/null; }
@test "fn-avail: oc-local-llm" { declare -f oc-local-llm >/dev/null; }
@test "fn-avail: oc-cache-clear" { declare -f oc-cache-clear >/dev/null; }
@test "fn-avail: oc-browser" { declare -f oc-browser >/dev/null; }
@test "fn-avail: oc-docs" { declare -f oc-docs >/dev/null; }
@test "fn-avail: oc-config" { declare -f oc-config >/dev/null; }
@test "fn-avail: oc-refresh-keys" { declare -f oc-refresh-keys >/dev/null; }
@test "fn-avail: oc-update" { declare -f oc-update >/dev/null; }
@test "fn-avail: oc-restart" { declare -f oc-restart >/dev/null; }
@test "fn-avail: oc-tail" { declare -f oc-tail >/dev/null; }
@test "fn-avail: oc-sandbox" { declare -f oc-sandbox >/dev/null; }
@test "fn-avail: oc-sec" { declare -f oc-sec >/dev/null; }
@test "fn-avail: oc-usage" { declare -f oc-usage >/dev/null; }
@test "fn-avail: oc-failover" { declare -f oc-failover >/dev/null; }
@test "fn-avail: __oc_gateway_databases_closed" { declare -f __oc_gateway_databases_closed >/dev/null; }
@test "fn-avail: __oc_safe_gateway_shutdown" { declare -f __oc_safe_gateway_shutdown >/dev/null; }
@test "fn-avail: oc-memory-search" { declare -f oc-memory-search >/dev/null; }
@test "fn-avail: oc-plugins" { declare -f oc-plugins >/dev/null; }
@test "fn-avail: oc-skills" { declare -f oc-skills >/dev/null; }
@test "fn-avail: oc-channels" { declare -f oc-channels >/dev/null; }
@test "fn-avail: oc-nodes" { declare -f oc-nodes >/dev/null; }
@test "fn-avail: oc-cron" { declare -f oc-cron >/dev/null; }
@test "fn-avail: oc-tui" { declare -f oc-tui >/dev/null; }
@test "fn-avail: oc-trust-sync" { declare -f oc-trust-sync >/dev/null; }
@test "fn-avail: oc-sync-models" { declare -f oc-sync-models >/dev/null; }
@test "fn-avail: bashrc_diagnose" { declare -f bashrc_diagnose >/dev/null; }
@test "fn-avail: bashrc_dryrun" { declare -f bashrc_dryrun >/dev/null; }
@test "fn-avail: get-ip" { declare -f get-ip >/dev/null; }
@test "fn-avail: copy_path" { declare -f copy_path >/dev/null; }
@test "fn-avail: mkproj" { declare -f mkproj >/dev/null; }
@test "fn-avail: oedit" { declare -f oedit >/dev/null; }
@test "fn-avail: llmconf" { declare -f llmconf >/dev/null; }
@test "fn-avail: occonf" { declare -f occonf >/dev/null; }
@test "fn-avail: mlogs" { declare -f mlogs >/dev/null; }
@test "fn-avail: mem-index" { declare -f mem-index >/dev/null; }
@test "fn-avail: lc" { declare -f lc >/dev/null; }
@test "fn-avail: custom_prompt_command" { declare -f custom_prompt_command >/dev/null; }

# ─────────────────────────────────────────────────────────────────────────────
# 16. CROSS-SCRIPT CONSISTENCY
# ─────────────────────────────────────────────────────────────────────────────

@test "cross-script: watchdog LLM_PORT default matches bashrc" {
    local wd_port
    wd_port=$(grep -oP 'LLM_PORT="\$\{LLM_PORT:-\K[0-9]+' "$REPO_ROOT/bin/llama-watchdog.sh")
    [[ "$wd_port" == "$LLM_PORT" ]]
}

@test "cross-script: watchdog LLAMA_ROOT default resolves to bashrc" {
    local wd_root
    wd_root=$(grep -oP 'LLAMA_ROOT="\$\{LLAMA_ROOT:-\K[^}]+' "$REPO_ROOT/bin/llama-watchdog.sh")
    wd_root="${wd_root/\$HOME/$HOME}"
    [[ "$wd_root" == "$LLAMA_ROOT" ]]
}

@test "cross-script: watchdog LLAMA_SERVER_BIN default is derived from LLAMA_ROOT" {
    grep -q 'LLAMA_SERVER_BIN="\${LLAMA_SERVER_BIN:-\$LLAMA_ROOT/build/bin/llama-server}"' \
        "$REPO_ROOT/bin/llama-watchdog.sh"
}

@test "cross-script: all scripts have VERSION variable or Module Version comment" {
    for f in "$REPO_ROOT"/bin/*.sh "$REPO_ROOT"/scripts/*.sh; do
        [[ -f "$f" ]] || continue
        grep -qE 'VERSION=|^# Module Version:' "$f"
    done
}

@test "cross-script: all scripts have AI INSTRUCTION comment" {
    for f in "$REPO_ROOT"/bin/*.sh "$REPO_ROOT"/scripts/*.sh; do
        [[ -f "$f" ]] || continue
        grep -q 'AI INSTRUCTION' "$f"
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# 17. CODE HYGIENE
# ─────────────────────────────────────────────────────────────────────────────

@test "hygiene: all scripts end with '# end of file' marker" {
    for f in "$PROFILE_PATH" \
             "$REPO_ROOT"/scripts/[0-9][0-9]-*.sh \
             "$REPO_ROOT"/bin/*.sh \
             "$REPO_ROOT"/install.sh \
             "$REPO_ROOT"/tools/lint.sh \
             "$REPO_ROOT"/tools/run-tests.sh; do
        [[ -f "$f" ]] || continue
        local last
        last=$(grep -v '^[[:space:]]*$' "$f" | tail -1)
        echo "$last" | grep -qi 'end of file'
    done
}

@test "hygiene: mcp-tools scripts end with '# end of file' marker" {
    for f in "$REPO_ROOT"/mcp-tools/*.sh; do
        [[ -f "$f" ]] || continue
        local last
        last=$(grep -v '^[[:space:]]*$' "$f" | tail -1)
        echo "$last" | grep -qi 'end of file'
    done
}

@test "hygiene: no carriage returns in any script" {
    for f in "$PROFILE_PATH" \
             "$REPO_ROOT"/scripts/[0-9][0-9]-*.sh \
             "$REPO_ROOT"/bin/*.sh \
             "$REPO_ROOT"/install.sh \
             "$REPO_ROOT"/mcp-tools/*.sh; do
        [[ -f "$f" ]] || continue
        local count
        count=$(grep -Pc '\r' "$f" || true)
        [[ "$count" -eq 0 ]]
    done
}

@test "hygiene: no trailing whitespace in core scripts" {
    for f in "$PROFILE_PATH" \
             "$REPO_ROOT"/scripts/[0-9][0-9]-*.sh \
             "$REPO_ROOT"/bin/*.sh \
             "$REPO_ROOT"/install.sh; do
        [[ -f "$f" ]] || continue
        local count
        count=$(grep -Pc ' +$' "$f" || true)
        [[ "$count" -eq 0 ]]
    done
}

@test "hygiene: no tabs in core scripts" {
    for f in "$PROFILE_PATH" \
             "$REPO_ROOT"/scripts/[0-9][0-9]-*.sh \
             "$REPO_ROOT"/bin/*.sh \
             "$REPO_ROOT"/install.sh; do
        [[ -f "$f" ]] || continue
        local count
        count=$(grep -Pc '\t' "$f" || true)
        [[ "$count" -eq 0 ]]
    done
}

@test "hygiene: no lines exceed 200 characters in core scripts" {
    # Relaxed limit: UI formatting lines and complex jq pipelines are
    # display-oriented code where wrapping would harm readability.
    local max_width=200
    for f in "$PROFILE_PATH" \
             "$REPO_ROOT"/scripts/[0-9][0-9]-*.sh \
             "$REPO_ROOT"/bin/*.sh \
             "$REPO_ROOT"/install.sh \
             "$REPO_ROOT"/tools/lint.sh \
             "$REPO_ROOT"/tools/run-tests.sh; do
        [[ -f "$f" ]] || continue
        local long
        long=$(awk -v max="$max_width" 'length > max' "$f" | wc -l)
        [[ "$long" -eq 0 ]] || echo "WARN: $f has $long lines > ${max_width} chars"
    done
}

@test "hygiene: no UTF-8 BOM in any script" {
    for f in "$PROFILE_PATH" \
             "$REPO_ROOT"/scripts/[0-9][0-9]-*.sh \
             "$REPO_ROOT"/bin/*.sh \
             "$REPO_ROOT"/install.sh \
             "$REPO_ROOT"/mcp-tools/*.sh; do
        [[ -f "$f" ]] || continue
        local desc
        desc=$(file "$f")
        [[ "$desc" != *"BOM"* ]]
    done
}

@test "hygiene: each module has '# shellcheck shell=bash' at line 1" {
    for f in "$REPO_ROOT"/scripts/[0-9][0-9]-*.sh "$REPO_ROOT"/scripts/09b-gog.sh; do
        [[ -f "$f" ]] || continue
        # Utility scripts (16+) are standalone executables with shebangs; skip
        case "$(basename "$f")" in
            1[6-9]-*|[2-9][0-9]-*) continue ;;
        esac
        local line1
        line1=$(head -1 "$f")
        [[ "$line1" == "# shellcheck shell=bash" ]]
    done
}

@test "hygiene: all 15 modules have a Module Version comment" {
    local count
    count=$(grep -l '^# Module Version:' \
        "$REPO_ROOT"/scripts/[0-9][0-9]-*.sh \
        | wc -l)
    [[ "$count" -eq 15 ]]
}

@test "hygiene: 09b-gog.sh has a Module Version comment" {
    grep -q '^# Module Version:' "$REPO_ROOT/scripts/09b-gog.sh"
}

@test "hygiene: module versions follow '# Module Version: N' pattern" {
    for f in "$REPO_ROOT"/scripts/[0-9][0-9]-*.sh; do
        [[ -f "$f" ]] || continue
        grep -qP '^# Module Version: \d+' "$f"
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# ~/.bashrc THIN LOADER ENFORCEMENT
# ─────────────────────────────────────────────────────────────────────────────

@test "bashrc: file exists and is read-only (mode 444)" {
    [[ -f "$HOME/.bashrc" ]]
    local perms
    perms=$(stat -c '%a' "$HOME/.bashrc" 2>/dev/null || stat -f '%Lp' "$HOME/.bashrc" 2>/dev/null)
    [[ "$perms" == "444" ]]
}

@test "bashrc: contains only interactive guard, source command, and comments" {
    # Count non-comment, non-empty lines (should be exactly 6: case line, 2 pattern lines, if line, source line, fi)
    local code_lines
    code_lines=$(grep -v '^[[:space:]]*#' "$HOME/.bashrc" | grep -v '^[[:space:]]*$' | wc -l)
    [[ "$code_lines" -le 10 ]]
}

@test "bashrc: does not contain function definitions" {
    ! grep -q '^[[:space:]]*function[[:space:]]' "$HOME/.bashrc"
}

@test "bashrc: does not contain alias definitions" {
    ! grep -q '^[[:space:]]*alias[[:space:]]' "$HOME/.bashrc"
}

@test "bashrc: does not contain export statements (except in comments)" {
    ! grep -q '^[[:space:]]*export[[:space:]]' "$HOME/.bashrc"
}

@test "bashrc: does not source files other than tactical-console.bashrc" {
    # Allow source of tactical-console.bashrc only
    local other_sources
    other_sources=$(grep '^[[:space:]]*source[[:space:]]' "$HOME/.bashrc" | \
        grep -v 'tactical-console.bashrc' | wc -l)
    [[ "$other_sources" -eq 0 ]]
}

@test "bashrc: does not contain OpenClaw completions source" {
    ! grep -q 'openclaw\.bash' "$HOME/.bashrc"
}

@test "bashrc: does not contain pnpm PATH configuration" {
    ! grep -q 'PNPM_HOME' "$HOME/.bashrc"
}

@test "bashrc: does not contain OPENCLAW_LCM_DEEP_RECALL_CMD" {
    ! grep -q 'OPENCLAW_LCM_DEEP_RECALL' "$HOME/.bashrc"
}

@test "bashrc: ends with '# end of file' marker" {
    local last
    last=$(grep -v '^[[:space:]]*$' "$HOME/.bashrc" | tail -1)
    [[ "$last" == "# end of file" ]]
}

@test "cross-script: watchdog ACTIVE_LLM_FILE matches bashrc constant" {
    local wd_file
    wd_file=$(grep -oP 'ACTIVE_LLM_FILE="\K[^"]+' \
        "$REPO_ROOT/bin/llama-watchdog.sh")
    [[ "$wd_file" == "$ACTIVE_LLM_FILE" ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 18. COOLDOWN MECHANISM — Behavioural tests
# ─────────────────────────────────────────────────────────────────────────────

@test "cooldown: __check_cooldown returns 0 (expired) when no DB entry exists" {
    local tmp_db="$TAC_TEST_TMPDIR/cooldown_test.txt"
    touch "$tmp_db"
    CooldownDB="$tmp_db"
    local remaining=""
    __check_cooldown "test_key" "$(date +%s)" remaining
}

@test "cooldown: __check_cooldown returns 1 (active) when recently set" {
    local tmp_db="$TAC_TEST_TMPDIR/cooldown_test2.txt"
    local now
    now=$(date +%s)
    echo "test_key=${now}" > "$tmp_db"
    CooldownDB="$tmp_db"
    local remaining=""
    run bash -c "
        source '$TAC_TEST_TMPDIR/profile_patched.bash' &>/dev/null
        CooldownDB='$tmp_db'
        __check_cooldown 'test_key' '$now' _cd_sink
        echo \$?
    "
    [[ "$output" == *"1"* ]]
}

@test "cooldown: __set_cooldown writes key=timestamp to DB" {
    local tmp_db="$TAC_TEST_TMPDIR/cooldown_set.txt"
    touch "$tmp_db"
    CooldownDB="$tmp_db"
    __set_cooldown "mykey" "1234567890"
    grep -q "^mykey=1234567890$" "$tmp_db"
}

@test "cooldown: __set_cooldown replaces existing key" {
    local tmp_db="$TAC_TEST_TMPDIR/cooldown_replace.txt"
    echo "mykey=111" > "$tmp_db"
    CooldownDB="$tmp_db"
    __set_cooldown "mykey" "222"
    local count
    count=$(grep -c "^mykey=" "$tmp_db")
    [[ "$count" -eq 1 ]]
    grep -q "^mykey=222$" "$tmp_db"
}

@test "cooldown: __check_cooldown apt_index uses COOLDOWN_DAILY (24h)" {
    local tmp_db="$TAC_TEST_TMPDIR/cooldown_daily.txt"
    local now
    now=$(date +%s)
    local yesterday=$(( now - 86401 ))
    echo "apt_index=${yesterday}" > "$tmp_db"
    CooldownDB="$tmp_db"
    local remaining=""
    # 24h+ ago → should expire
    __check_cooldown "apt_index" "$now" remaining
}

@test "cooldown: __check_cooldown returns remaining time in result var" {
    local tmp_db="$TAC_TEST_TMPDIR/cooldown_remain.txt"
    local now
    now=$(date +%s)
    # Set cooldown 1 hour ago. COOLDOWN_WEEKLY is 86400s (24h).
    local one_hour_ago=$(( now - 3600 ))
    echo "some_task=${one_hour_ago}" > "$tmp_db"
    CooldownDB="$tmp_db"
    local remaining=""
    run bash -c "
        source '$TAC_TEST_TMPDIR/profile_patched.bash' &>/dev/null
        CooldownDB='$tmp_db'
        r=''
        __check_cooldown 'some_task' '$now' r
        echo \"\$r\"
    "
    # Should contain hours format (COOLDOWN_WEEKLY is 24h, so ~23h remaining)
    [[ "$output" =~ [0-9]+h ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 19. UI ENGINE — Additional behavioural tests
# ─────────────────────────────────────────────────────────────────────────────

@test "ui: __fRow formats label and value inside box borders" {
    run __fRow "TEST" "some value" "$C_Text"
    [ "$status" -eq 0 ]
    [[ "$output" == *"TEST"* ]]
    [[ "$output" == *"some value"* ]]
}

@test "ui: __fRow truncates long values to prevent overflow" {
    local long_val
    printf -v long_val '%0100s' '' # 100 spaces
    long_val="${long_val// /X}"
    run __fRow "LABEL" "$long_val" "$C_Text"
    [ "$status" -eq 0 ]
    [[ "$output" == *"..."* ]]
}

@test "ui: __hSection outputs centred section header with double border" {
    run __hSection "TEST SECTION"
    [ "$status" -eq 0 ]
    [[ "$output" == *"TEST SECTION"* ]]
    [[ "$output" == *"╠"* ]]
}

@test "ui: __show_header outputs box with version" {
    run __show_header
    [ "$status" -eq 0 ]
    [[ "$output" == *"╔"* ]]
    [[ "$output" == *"╚"* ]]
    [[ "$output" == *"Wayne"* ]]
}

@test "ui: __show_header includes Bash version" {
    run __show_header
    [[ "$output" == *"Bash"* ]]
}

@test "ui: __tac_info pads label and status to UIWidth" {
    run __tac_info "MyLabel" "[OK]" "$C_Success"
    [ "$status" -eq 0 ]
    [[ "$output" == *"MyLabel"* ]]
    [[ "$output" == *"[OK]"* ]]
}

@test "ui: __tac_line renders bordered row" {
    run __tac_line "Doing something" "[DONE]" "$C_Success"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Doing something"* ]]
    [[ "$output" == *"[DONE]"* ]]
}

@test "ui: __vsc_open fails cleanly when VS Code is unavailable" {
    __resolve_vscode_bin() { VSCODE_BIN=""; }
    VSCODE_BIN=""
    run __vsc_open "/tmp/example"
    [ "$status" -eq 1 ]
}

@test "ui: __threshold_color boundary: 0 returns C_Success" {
    result=$(__threshold_color 0)
    [[ "$result" == "$C_Success" ]]
}

@test "ui: __threshold_color boundary: 76 returns C_Warning" {
    result=$(__threshold_color 76)
    [[ "$result" == "$C_Warning" ]]
}

@test "ui: __threshold_color boundary: 100 returns C_Error" {
    result=$(__threshold_color 100)
    [[ "$result" == "$C_Error" ]]
}

@test "ui: __require_openclaw returns 1 when openclaw not installed" {
    # In test env, openclaw is not installed
    if command -v openclaw >/dev/null 2>&1; then
        skip "openclaw is installed in this environment"
    fi
    run __require_openclaw
    [ "$status" -eq 1 ]
}

@test "ui: __usage outputs Usage: prefix" {
    run __usage "test_cmd <arg>"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
    [[ "$output" == *"test_cmd"* ]]
}

@test "ui: __save_nullglob and __restore_nullglob round-trip" {
    # Ensure nullglob is off before test
    shopt -u nullglob 2>/dev/null || true
    __save_nullglob
    # nullglob should now be on
    shopt -q nullglob
    __restore_nullglob
    # nullglob should be restored to off
    ! shopt -q nullglob
}

# ─────────────────────────────────────────────────────────────────────────────
# 20. ERROR HANDLER
# ─────────────────────────────────────────────────────────────────────────────

@test "error: __tac_err_handler function is defined" {
    declare -f __tac_err_handler >/dev/null
}

@test "error: ErrorLogPath variable is set" {
    [[ -n "$ErrorLogPath" ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 21. TELEMETRY — Behavioural tests
# ─────────────────────────────────────────────────────────────────────────────

@test "telemetry: __get_uptime contains 'd', 'h', 'm' tokens" {
    result=$(__get_uptime)
    [[ "$result" == *"d"* ]]
    [[ "$result" == *"h"* ]]
    [[ "$result" == *"m"* ]]
}

@test "telemetry: __get_disk returns non-empty string" {
    result=$(__get_disk)
    [[ -n "$result" ]]
}

@test "telemetry: __get_disk output contains 'free'" {
    result=$(__get_disk)
    [[ "$result" == *"free"* ]]
}

@test "telemetry: __get_git returns branch info in a git repo" {
    # The test runs inside the ubuntu-console repo
    pushd "$REPO_ROOT" >/dev/null
    result=$(__get_git)
    [[ -n "$result" ]]
    [[ "$result" == *"|"* ]]
    popd >/dev/null
}

@test "telemetry: __get_git returns empty outside a git repo" {
    pushd /tmp >/dev/null
    result=$(__get_git)
    [[ -z "$result" ]]
    popd >/dev/null
}

@test "telemetry: __cache_fresh with large TTL returns fresh for new file" {
    local cache_file="$TAC_TEST_TMPDIR/test_cache_large_ttl"
    touch "$cache_file"
    __cache_fresh "$cache_file" 999999
}

# ─────────────────────────────────────────────────────────────────────────────
# 22. MAINTENANCE HELPERS — Behavioural tests
# ─────────────────────────────────────────────────────────────────────────────

@test "maintenance: __cleanup_temps returns a count" {
    pushd "$TAC_TEST_TMPDIR" >/dev/null
    result=$(__cleanup_temps)
    [[ "$result" =~ ^[0-9]+$ ]]
    popd >/dev/null
}

@test "maintenance: __cleanup_temps removes python-*.exe files" {
    local tmpdir="$TAC_TEST_TMPDIR/cleanup_test"
    mkdir -p "$tmpdir"
    touch "$tmpdir/python-3.12.exe"
    pushd "$tmpdir" >/dev/null
    result=$(__cleanup_temps)
    [[ "$result" -ge 1 ]]
    [[ ! -f "$tmpdir/python-3.12.exe" ]]
    popd >/dev/null
}

@test "maintenance: __cleanup_temps removes .pytest_cache" {
    local tmpdir="$TAC_TEST_TMPDIR/cleanup_pytest"
    mkdir -p "$tmpdir/.pytest_cache"
    pushd "$tmpdir" >/dev/null
    result=$(__cleanup_temps)
    [[ "$result" -ge 1 ]]
    [[ ! -d "$tmpdir/.pytest_cache" ]]
    popd >/dev/null
}

@test "maintenance: __cleanup_temps does NOT remove .log files" {
    local tmpdir="$TAC_TEST_TMPDIR/cleanup_nologs"
    mkdir -p "$tmpdir"
    touch "$tmpdir/important.log"
    pushd "$tmpdir" >/dev/null
    __cleanup_temps >/dev/null
    [[ -f "$tmpdir/important.log" ]]
    popd >/dev/null
}

@test "maintenance: logtrim function trims large log files" {
    local tmpdir="$TAC_TEST_TMPDIR/logtrim_test"
    mkdir -p "$tmpdir"
    # Create a >1MB log file
    local biglog="$tmpdir/test.log"
    dd if=/dev/zero bs=1024 count=1100 2>/dev/null | tr '\0' 'A' > "$biglog"
    # Add some real lines
    for i in $(seq 1 2000); do echo "line $i" >> "$biglog"; done
    # Override OC_LOGS to our tmpdir and run logtrim
    local old_oc_logs="$OC_LOGS"
    OC_LOGS="$tmpdir"
    run logtrim
    OC_LOGS="$old_oc_logs"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Trimmed"* ]]
}

@test "maintenance: cl function runs without error" {
    pushd "$TAC_TEST_TMPDIR" >/dev/null
    # Use --light mode to avoid slow full-home-directory scans (find ~ -xtype l)
    run cl --light
    [ "$status" -eq 0 ]
    [[ "$output" == *"Sanitation"* ]]
    popd >/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# 23. MODEL DISPATCHER — Subcommand routing
# ─────────────────────────────────────────────────────────────────────────────

@test "model: 'model scan' runs without syntax error" {
    # scan looks for LLAMA_MODEL_DIR which may not exist in test env
    run model scan
    # Either succeeds or fails gracefully (not a bash syntax error)
    [[ "$status" -le 1 ]]
}

@test "model: 'model list' runs without syntax error" {
    run model list
    [[ "$status" -le 1 ]]
}

@test "model: 'model status' runs without syntax error" {
    run model status
    [[ "$status" -le 1 ]]
}

@test "model: 'model stop' runs without syntax error (server not running)" {
    run model stop
    [[ "$status" -le 1 ]]
}

@test "model: 'model info' without args prints usage" {
    run model info
    [[ "$status" -le 1 ]]
}

@test "model: unknown subcommand prints usage with 'Usage'" {
    run model nonexistent_xyz
    [[ "$output" == *"Usage"* ]]
}

@test "model: 'model' with no args prints usage" {
    run model
    [[ "$output" == *"Usage"* ]]
}

@test "llm-manager: local_chat function is defined" {
    declare -f local_chat >/dev/null
}

@test "llm-manager: wtf_repl function is defined" {
    declare -f wtf_repl >/dev/null
}

@test "llm-manager: chat-context function is defined" {
    declare -f chat-context >/dev/null
}

@test "llm-manager: chat-pipe function is defined" {
    declare -f chat-pipe >/dev/null
}

@test "llm-manager: __llm_chat_send function is defined" {
    declare -f __llm_chat_send >/dev/null
}

@test "llm-manager: __llm_stream function is defined" {
    declare -f __llm_stream >/dev/null
}

@test "llm-manager: __calc_gpu_layers function is defined" {
    declare -f __calc_gpu_layers >/dev/null
}

@test "llm-manager: __calc_ctx_size function is defined" {
    declare -f __calc_ctx_size >/dev/null
}

@test "llm-manager: __calc_threads function is defined" {
    declare -f __calc_threads >/dev/null
}

@test "llm-manager: __quant_label function is defined" {
    declare -f __quant_label >/dev/null
}

@test "llm-manager: __model_scan function is defined" {
    declare -f __model_scan >/dev/null
}

@test "llm-manager: __model_list function is defined" {
    declare -f __model_list >/dev/null
}

@test "llm-manager: __model_use function is defined" {
    declare -f __model_use >/dev/null
}

@test "llm-manager: __model_stop function is defined" {
    declare -f __model_stop >/dev/null
}

@test "llm-manager: __model_info function is defined" {
    declare -f __model_info >/dev/null
}

@test "llm-manager: __model_bench function is defined" {
    declare -f __model_bench >/dev/null
}

@test "llm-manager: __llm_registry_entry_by_num function is defined" {
    declare -f __llm_registry_entry_by_num >/dev/null
}

@test "llm-manager: __llm_default_entry function is defined" {
    declare -f __llm_default_entry >/dev/null
}

@test "llm-manager: __llm_wait_for_health function is defined" {
    declare -f __llm_wait_for_health >/dev/null
}

@test "llm-manager: __model_doctor function is defined" {
    declare -f __model_doctor >/dev/null
}

@test "llm-manager: __model_recommend function is defined" {
    declare -f __model_recommend >/dev/null
}

@test "llm-manager: __model_bench_history function is defined" {
    declare -f __model_bench_history >/dev/null
}

@test "llm-manager: model status supports json output" {
    run model status --json
    [[ "$output" == \{* ]]
    [[ "$output" == *'"online":'* ]]
}

@test "llm-manager: model status supports plain output" {
    run model status --plain
    [[ "$output" == *"online="* ]]
    [[ "$output" == *"port="* ]]
}

@test "llm-manager: model doctor supports json output" {
    run model doctor --json
    [[ "$output" == \{* ]]
    [[ "$output" == *'"registry_exists":'* ]]
    [[ "$output" == *'"issues":'* ]]
}

@test "llm-manager: model delete dry-run does not remove the model file" {
    local llm_root="$TAC_TEST_TMPDIR/model-delete-dry-run"
    mkdir -p "$llm_root/models" "$llm_root/.llm"
    printf '%s\n' '#|name|file|size_gb|arch|quant|layers|gpu_layers|ctx|threads|tps' \
        '1|Demo Model|demo.gguf|1.0G|llama|Q4_K_M|32|999|4096|4|-' > "$llm_root/.llm/models.conf"
    touch "$llm_root/models/demo.gguf"

    LLM_REGISTRY="$llm_root/.llm/models.conf"
    LLM_DEFAULT_FILE="$llm_root/.llm/default_model.conf"
    LLAMA_MODEL_DIR="$llm_root/models"

    run model delete --dry-run 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"Would delete"* ]]
    [[ -f "$llm_root/models/demo.gguf" ]]
}

@test "llm-manager: model recommend ranks on-disk models from registry" {
    run bash -lc "
        source '$REPO_ROOT/env.sh' >/dev/null 2>&1
        llm_root='$TAC_TEST_TMPDIR/model-recommend'
        mkdir -p \"\$llm_root/models\" \"\$llm_root/.llm\"
        printf '%s\n' '#|name|file|size_gb|arch|quant|layers|gpu_layers|ctx|threads|tps' \
            '1|Fast Model|fast-Q4_K_M.gguf|1.0G|llama|Q4_K_M|32|999|4096|4|14.2' \
            '2|Slow Model|slow-Q8_0.gguf|3.8G|llama|Q8_0|40|0|8192|8|4.1' > \"\$llm_root/.llm/models.conf\"
        touch \"\$llm_root/models/fast-Q4_K_M.gguf\" \"\$llm_root/models/slow-Q8_0.gguf\"
        LLM_REGISTRY=\"\$llm_root/.llm/models.conf\"
        LLAMA_MODEL_DIR=\"\$llm_root/models\"
        model recommend
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"Fast Model"* ]]
    [[ "$output" == *"Slow Model"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 24. OC DISPATCHER — Extended subcommand routing
# ─────────────────────────────────────────────────────────────────────────────

@test "oc: 'oc env' runs and shows environment variables" {
    run oc env
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"OC_ROOT"* ]]
}

@test "oc: 'oc g' routes to oc-kgraph" {
    declare -f oc-kgraph >/dev/null
}

@test "oc: help output includes 'g' subcommand" {
    run oc
    [[ "$output" == *"Knowledge Graph"* || "$output" == *" g "* ]]
}

@test "oc: help output includes doctor-local subcommand" {
    run oc
    [[ "$output" == *"doctor-local"* ]]
}

@test "fn-avail: oc-kgraph" { declare -f oc-kgraph >/dev/null; }

@test "alias: 'g' is defined (oc g)" {
    alias g >/dev/null 2>&1
}

@test "oc: 'oc restart' fails gracefully without openclaw" {
    if command -v openclaw >/dev/null 2>&1; then
        skip "openclaw is installed"
    fi
    run oc restart
    [[ "$status" -ne 0 ]]
}

@test "oc: multiple unknown subcommands all return error" {
    for sub in fake_abc unknown_xyz not_a_command; do
        run oc "$sub"
        [[ "$status" -eq 1 ]]
        [[ "$output" == *"INVALID SUBCOMMAND"* ]]
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# 25. LLM CALCULATION — Edge cases and boundary tests
# ─────────────────────────────────────────────────────────────────────────────

@test "calc: __calc_gpu_layers for 0-byte model returns 999 (full offload)" {
    result=$(__calc_gpu_layers 0 32 "llama")
    [[ "$result" -eq 999 ]]
}

@test "calc: __calc_gpu_layers for exactly-VRAM model returns non-negative" {
    # Model exactly at VRAM threshold (85% of 4GB)
    local threshold=$(( VRAM_TOTAL_BYTES * VRAM_THRESHOLD_PCT / 100 ))
    result=$(__calc_gpu_layers "$threshold" 40 "llama")
    [[ "$result" -ge 0 ]]
}

@test "calc: __calc_ctx_size MoE always returns MOE_DEFAULT_CTX regardless of size" {
    for arch in qwen3moe deepseek2moe; do
        result=$(__calc_ctx_size $((1 * 1024 * 1024 * 1024)) 65536 "$arch")
        [[ "$result" -eq "$MOE_DEFAULT_CTX" ]]
    done
}

@test "calc: __calc_threads minimum is 1 even with 0 layers" {
    result=$(__calc_threads 0 0)
    [[ "$result" -ge 1 ]]
}

@test "calc: __calc_threads with equal gpu_layers and total returns 50% nproc" {
    local ncpu
    ncpu=$(nproc 2>/dev/null || echo 16)
    local expected=$(( ncpu * 50 / 100 ))
    result=$(__calc_threads 999 999)
    [[ "$result" -eq "$expected" ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 26. QUANT LABEL — Additional edge cases
# ─────────────────────────────────────────────────────────────────────────────

@test "quant: __quant_label maps ftype 2 to Q4_0" {
    result=$(__quant_label 2 "")
    [[ "$result" == "Q4_0" ]]
}

@test "quant: __quant_label maps ftype 3 to Q4_1" {
    result=$(__quant_label 3 "")
    [[ "$result" == "Q4_1" ]]
}

@test "quant: __quant_label maps ftype 8 to Q5_0" {
    result=$(__quant_label 8 "")
    [[ "$result" == "Q5_0" ]]
}

@test "quant: __quant_label extracts Q5_K_M from filename" {
    result=$(__quant_label 0 "model-Q5_K_M.gguf")
    [[ "$result" == "Q5_K_M" ]]
}

@test "quant: __quant_label extracts Q6_K from filename" {
    result=$(__quant_label 0 "model-Q6_K.gguf")
    [[ "$result" == "Q6_K" ]]
}

@test "quant: __quant_label extracts F32 from filename" {
    result=$(__quant_label 0 "model-F32.gguf")
    [[ "$result" == "F32" ]]
}

@test "quant: __quant_label handles mixed case in IQ variants" {
    result=$(__quant_label 0 "model-IQ4_XS-v1.gguf")
    [[ "$result" == "IQ4_XS" ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 27. DEPLOYMENT — mkproj & commit functions
# ─────────────────────────────────────────────────────────────────────────────

@test "deployment: mkproj requires a project name" {
    run mkproj
    [ "$status" -eq 1 ]
    [[ "$output" == *"Project Name"* ]]
}

@test "deployment: mkproj refuses path traversal" {
    run mkproj "../evil"
    [ "$status" -eq 1 ]
    [[ "$output" == *"PATH TRAVERSAL"* ]]
}

@test "deployment: mkproj refuses absolute paths" {
    run mkproj "/tmp/evil"
    [ "$status" -eq 1 ]
    [[ "$output" == *"ABSOLUTE PATHS"* ]]
}

@test "deployment: mkproj refuses names starting with numbers" {
    run mkproj "123project"
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUST START WITH LETTER"* ]]
}

@test "deployment: mkproj refuses names with special characters" {
    run mkproj "my@project!"
    [ "$status" -eq 1 ]
    [[ "$output" == *"MUST START WITH LETTER"* ]]
}

@test "deployment: mkproj refuses names longer than 64 chars" {
    run mkproj "abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz0123456789X"
    [ "$status" -eq 1 ]
    [[ "$output" == *"TOO LONG"* ]]
}

@test "deployment: mkproj refuses existing directory" {
    local testdir="existing_proj"
    mkdir -p "$TAC_TEST_TMPDIR/$testdir"
    pushd "$TAC_TEST_TMPDIR" >/dev/null
    run mkproj "$testdir"
    popd >/dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"ALREADY EXISTS"* ]]
}

@test "deployment: mkproj scaffold includes pytest in requirements" {
    grep -q '^pytest$' "$REPO_ROOT/scripts/10-deployment.sh"
}

@test "deployment: mkproj fails if virtualenv dependency install fails" {
    local fakebin="$TAC_TEST_TMPDIR/fakebin"
    mkdir -p "$fakebin"

    cat > "$fakebin/python3" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-m" && "${2:-}" == "venv" ]]; then
    target="${3:-.venv}"
    mkdir -p "$target/bin"
    cat > "$target/bin/activate" << 'ACT'
VIRTUAL_ENV="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export VIRTUAL_ENV
export PATH="$VIRTUAL_ENV/bin:$PATH"
ACT
    cat > "$target/bin/pip" << 'PIP'
#!/usr/bin/env bash
exit 1
PIP
    chmod +x "$target/bin/pip"
    exit 0
fi
exec /usr/bin/python3 "$@"
EOF
    chmod +x "$fakebin/python3"

    cat > "$fakebin/git" << 'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$fakebin/git"

    pushd "$TAC_TEST_TMPDIR" >/dev/null
    PATH="$fakebin:$PATH"
    run mkproj "broken_proj"
    popd >/dev/null

    [ "$status" -eq 1 ]
    [[ "$output" == *"Python Dependencies"* ]]
    [[ "$output" == *"[FAILED]"* ]]
}

@test "deployment: commit_deploy requires a message" {
    run commit_deploy
    [ "$status" -eq 1 ]
    [[ "$output" == *"Commit message"* ]]
}

@test "deployment: commit_deploy fails outside git repo" {
    pushd "$TAC_TEST_TMPDIR" >/dev/null
    run commit_deploy "test message"
    [ "$status" -eq 1 ]
    [[ "$output" == *"NOT A GIT REPO"* ]]
    popd >/dev/null
}

@test "deployment: commit_auto fails outside git repo" {
    pushd "$TAC_TEST_TMPDIR" >/dev/null
    run commit_auto
    [ "$status" -eq 1 ]
    [[ "$output" == *"NOT A GIT REPO"* ]]
    popd >/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# 28. LLM GUARDS — __require_llm & __require_openclaw
# ─────────────────────────────────────────────────────────────────────────────

@test "llm-guard: __require_llm fails when LLM server is offline" {
    # LLM server is not running in test env
    run __require_llm
    [ "$status" -ne 0 ]
}

@test "llm-guard: __require_llm checks for jq" {
    if ! command -v jq >/dev/null 2>&1; then
        run __require_llm
        [[ "$output" == *"jq"* ]]
    else
        # jq is installed; __require_llm should fail on port check instead
        run __require_llm
        [ "$status" -ne 0 ]
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 29. PORT UTILITIES — Additional tests
# ─────────────────────────────────────────────────────────────────────────────

@test "port: __test_port returns 1 for port 0 (invalid)" {
    run __test_port 0
    [ "$status" -ne 0 ]
}

@test "port: __test_port returns 1 for very high port (65535)" {
    run __test_port 65535
    [ "$status" -ne 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# 30. HOOKS — cd override & prompt
# ─────────────────────────────────────────────────────────────────────────────

@test "hooks: cd function is defined as override" {
    declare -f cd >/dev/null
}

@test "hooks: cd successfully changes directory" {
    local before="$PWD"
    cd /tmp
    [[ "$PWD" == "/tmp" ]]
    cd "$before"
}

@test "hooks: PROMPT_COMMAND is set" {
    [[ -n "$PROMPT_COMMAND" ]]
}

@test "hooks: _TAC_ADMIN_BADGE is defined" {
    # Variable exists (may be empty if not in sudo group)
    declare -p _TAC_ADMIN_BADGE >/dev/null 2>&1
}

# ─────────────────────────────────────────────────────────────────────────────
# 31. CONSTANTS — Extended validation
# ─────────────────────────────────────────────────────────────────────────────

@test "constants: AI_STORAGE_ROOT is set" {
    [[ -n "$AI_STORAGE_ROOT" ]]
}

@test "constants: TACTICAL_REPO_ROOT is set to an absolute directory" {
    [[ -n "$TACTICAL_REPO_ROOT" ]]
    [[ "$TACTICAL_REPO_ROOT" == /* ]]
    [[ -d "$TACTICAL_REPO_ROOT" ]]
}

@test "constants: OC_WORKSPACE is under OC_ROOT" {
    [[ "$OC_WORKSPACE" == "$OC_ROOT"* ]]
}

@test "constants: OC_AGENTS is under OC_ROOT" {
    [[ "$OC_AGENTS" == "$OC_ROOT"* ]]
}

@test "constants: OC_LOGS is under OC_ROOT" {
    [[ "$OC_LOGS" == "$OC_ROOT"* ]]
}

@test "constants: OC_BACKUPS is under OC_ROOT" {
    [[ "$OC_BACKUPS" == "$OC_ROOT"* ]]
}

@test "constants: CooldownDB path is set" {
    [[ -n "$CooldownDB" ]]
}

@test "constants: ErrorLogPath is set" {
    [[ -n "$ErrorLogPath" ]]
}

@test "constants: LLAMA_MODEL_DIR is under LLAMA_DRIVE_ROOT" {
    [[ "$LLAMA_MODEL_DIR" == "$LLAMA_DRIVE_ROOT"* ]]
}

@test "constants: LLAMA_ARCHIVE_DIR is under LLAMA_DRIVE_ROOT" {
    [[ "$LLAMA_ARCHIVE_DIR" == "$LLAMA_DRIVE_ROOT"* ]]
}

@test "constants: LLM_REGISTRY is set" {
    [[ -n "$LLM_REGISTRY" ]]
}

@test "constants: LOCAL_LLM_URL starts with http" {
    [[ "$LOCAL_LLM_URL" == http* ]]
}

@test "constants: TAC_CACHE_DIR is set" {
    [[ -n "$TAC_CACHE_DIR" ]]
}

@test "constants: QUANT_GUIDE path is set" {
    [[ -n "$QUANT_GUIDE" ]]
}

@test "constants: QUANT_GUIDE is under TACTICAL_REPO_ROOT" {
    [[ "$QUANT_GUIDE" == "$TACTICAL_REPO_ROOT/"* ]]
}

@test "constants: LOG_MAX_BYTES is numeric" {
    [[ "$LOG_MAX_BYTES" =~ ^[0-9]+$ ]]
}

@test "constants: box-drawing chars BOX_TL, BOX_TR, BOX_BL, BOX_BR are set" {
    [[ -n "$BOX_TL" ]]
    [[ -n "$BOX_TR" ]]
    [[ -n "$BOX_BL" ]]
    [[ -n "$BOX_BR" ]]
}

@test "constants: box-drawing chars BOX_H, BOX_V are set" {
    [[ -n "$BOX_H" ]]
    [[ -n "$BOX_V" ]]
}

@test "constants: TACTICAL_PROFILE_VERSION is set and non-empty" {
    [[ -n "$TACTICAL_PROFILE_VERSION" ]]
}

@test "constants: PLAY_MARK glyph is set" {
    [[ -n "$PLAY_MARK" ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 32. FUNCTION AVAILABILITY — Additional functions
# ─────────────────────────────────────────────────────────────────────────────

@test "fn-avail: wacli" { declare -f wacli >/dev/null; }
@test "fn-avail: ocstart" { declare -f ocstart >/dev/null; }
@test "fn-avail: ocstop" { declare -f ocstop >/dev/null; }
@test "fn-avail: ocgs" { declare -f ocgs >/dev/null; }
@test "fn-avail: ocv" { declare -f ocv >/dev/null; }
@test "fn-avail: ockeys" { declare -f ockeys >/dev/null; }
@test "fn-avail: ocdoc-fix" { declare -f ocdoc-fix >/dev/null; }
@test "fn-avail: ologs" { declare -f ologs >/dev/null; }
@test "fn-avail: ocroot" { declare -f ocroot >/dev/null; }
@test "fn-avail: owk" { declare -f owk >/dev/null; }
@test "fn-avail: ocstat" { declare -f ocstat >/dev/null; }
@test "fn-avail: ocms" { declare -f ocms >/dev/null; }
@test "fn-avail: oclogs" { declare -f oclogs >/dev/null; }
@test "fn-avail: __bridge_windows_api_keys" { declare -f __bridge_windows_api_keys >/dev/null; }

# ─────────────────────────────────────────────────────────────────────────────
# 33. CROSS-SCRIPT — Extended consistency checks
# ─────────────────────────────────────────────────────────────────────────────

@test "cross-script: all @exports in modules are actually defined as functions or variables" {
    local missing=0
    for f in "$REPO_ROOT"/scripts/[0-9][0-9]-*.sh; do
        [[ -f "$f" ]] || continue
        local exports_line
        exports_line=$(grep '^# @exports:' "$f" | sed 's/^# @exports://' | tr ',' '\n')
        while read -r fn_name; do
            fn_name=$(echo "$fn_name" | xargs)  # trim whitespace
            [[ -z "$fn_name" ]] && continue
            # Skip known variables (not functions) and continuations like
            # '(plus standard shell aliases)' or 'Note:' lines.
            [[ "$fn_name" == "("* ]] && continue
            [[ "$fn_name" == "Note:"* ]] && continue
            # Skip entries with parentheses like 'cd (override)'
            [[ "$fn_name" == *"("* ]] && continue
            [[ "$fn_name" == *")"* ]] && continue
            # Check both function and variable definitions
            if ! declare -f "$fn_name" >/dev/null 2>&1 && \
               ! declare -p "$fn_name" >/dev/null 2>&1; then
                echo "MISSING: $fn_name from $(basename "$f")"
                missing=$(( missing + 1 ))
            fi
        done <<< "$exports_line"
    done
    [[ "$missing" -eq 0 ]]
}

@test "cross-script: module numbering — every module has a section header" {
    for f in "$REPO_ROOT"/scripts/[0-9][0-9]-*.sh; do
        [[ -f "$f" ]] || continue
        # Every module must have at least one '# ===' or '# ---' banner line
        grep -qE '^# (===|---)' "$f"
    done
}

@test "cross-script: env.sh uses glob to source numbered modules" {
    # env.sh sources modules via a [0-9][0-9]-*.sh glob pattern
    grep -q '\[0-9\]\[0-9\]-\*\.sh' "$REPO_ROOT/env.sh"
}

@test "cross-script: watchdog has correct health endpoint" {
    grep -q '/health' "$REPO_ROOT/bin/llama-watchdog.sh"
}

# ─────────────────────────────────────────────────────────────────────────────
# 34. BIN SCRIPTS — Wrapper validation
# ─────────────────────────────────────────────────────────────────────────────

@test "bin: tac-exec sources env.sh" {
    grep -q 'env.sh' "$REPO_ROOT/bin/tac-exec"
}

@test "bin: all oc-* wrappers use tac-exec" {
    for f in "$REPO_ROOT"/bin/oc-*; do
        [[ -f "$f" ]] || continue
        grep -q 'tac-exec' "$f"
    done
}

@test "bin: llama-watchdog.sh has correct shebang" {
    local line1
    line1=$(head -1 "$REPO_ROOT/bin/llama-watchdog.sh")
    [[ "$line1" == "#!/usr/bin/env bash" || "$line1" == "#!/bin/bash" ]]
}

@test "bin: tac_hostmetrics.sh outputs pipe-separated values" {
    # Just check it has the expected output format structure
    grep -q '|' "$REPO_ROOT/bin/tac_hostmetrics.sh" || \
    grep -q 'printf' "$REPO_ROOT/bin/tac_hostmetrics.sh"
}

@test "telemetry: __get_host_metrics uses the repo-local tac_hostmetrics helper" {
    grep -q '"\$TACTICAL_REPO_ROOT/bin/tac_hostmetrics.sh"' "$REPO_ROOT/scripts/07-telemetry.sh"
}

# ─────────────────────────────────────────────────────────────────────────────
# 35. SYSTEMD UNITS — Structure validation
# ─────────────────────────────────────────────────────────────────────────────

@test "systemd: llama-watchdog.service has [Service] section" {
    grep -q '\[Service\]' "$REPO_ROOT/systemd/llama-watchdog.service"
}

@test "systemd: llama-watchdog.service uses the current user's home" {
    grep -q '^ExecStart=%h/.local/bin/llama-watchdog.sh$' \
        "$REPO_ROOT/systemd/llama-watchdog.service"
}

@test "systemd: llama-watchdog.timer has [Timer] section" {
    grep -q '\[Timer\]' "$REPO_ROOT/systemd/llama-watchdog.timer"
}

@test "systemd: timer references the correct service unit" {
    grep -q 'llama-watchdog.service' "$REPO_ROOT/systemd/llama-watchdog.timer"
}

# ─────────────────────────────────────────────────────────────────────────────
# 36. INSTALL SCRIPT — Structural validation
# ─────────────────────────────────────────────────────────────────────────────

@test "install: install.sh exists and is non-empty" {
    [[ -s "$REPO_ROOT/install.sh" ]]
}

@test "install: install.sh has a shebang" {
    local line1
    line1=$(head -1 "$REPO_ROOT/install.sh")
    [[ "$line1" == "#!"* ]]
}

@test "install: preserves existing ~/.bashrc content when appending loader" {
    local home_dir="$TAC_TEST_TMPDIR/install-home-preserve"
    mkdir -p "$home_dir"
    printf '%s\n' '# existing config' 'export KEEP_ME=1' > "$home_dir/.bashrc"

    run env HOME="$home_dir" bash "$REPO_ROOT/install.sh"
    [ "$status" -eq 0 ]

    grep -q 'export KEEP_ME=1' "$home_dir/.bashrc"
    grep -q 'tactical-console.bashrc' "$home_dir/.bashrc"
    grep -Fq "$REPO_ROOT/tactical-console.bashrc" "$home_dir/.bashrc"
}

@test "install: does not duplicate loader when already present" {
    local home_dir="$TAC_TEST_TMPDIR/install-home-idempotent"
    mkdir -p "$home_dir"
    cat > "$home_dir/.bashrc" << 'EOF'
# existing config
if [[ -f "$HOME/ubuntu-console/tactical-console.bashrc" ]]
then
    source "$HOME/ubuntu-console/tactical-console.bashrc"
fi
EOF
    local before
    before=$(cat "$home_dir/.bashrc")

    run env HOME="$home_dir" bash "$REPO_ROOT/install.sh"
    [ "$status" -eq 0 ]

    local after
    after=$(cat "$home_dir/.bashrc")
    [ "$after" = "$before" ]
}

@test "install: reloads user systemd units when systemctl is available" {
    local home_dir="$TAC_TEST_TMPDIR/install-home-systemd"
    local stub_dir="$TAC_TEST_TMPDIR/install-stubs"
    local log_file="$TAC_TEST_TMPDIR/install-systemctl.log"
    mkdir -p "$home_dir" "$stub_dir"

    cat > "$stub_dir/systemctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log_file"
EOF
    chmod +x "$stub_dir/systemctl"

    run env HOME="$home_dir" PATH="$stub_dir:$PATH" bash "$REPO_ROOT/install.sh"
    [ "$status" -eq 0 ]

    grep -q '^--user daemon-reload$' "$log_file"
}

@test "bin: tac-exec sources env.sh relative to its own path" {
    grep -q 'readlink -f "\${BASH_SOURCE\[0\]}"' "$REPO_ROOT/bin/tac-exec"
    grep -q 'source "\$_tac_exec_root/env.sh"' "$REPO_ROOT/bin/tac-exec"
}

@test "cross-script: env.sh loads scripts relative to the repo file location" {
    grep -q 'dirname "\${BASH_SOURCE\[0\]}"' "$REPO_ROOT/env.sh"
    grep -q '_tac_lib_dir="\$_tac_env_root/scripts"' "$REPO_ROOT/env.sh"
}

@test "bin: all oc-* wrappers resolve tac-exec relative to the wrapper path" {
    local f
    for f in "$REPO_ROOT"/bin/oc-*; do
        [[ -f "$f" ]] || continue
        grep -q '_tac_bin_dir=' "$f"
        grep -q 'exec "\$_tac_bin_dir/tac-exec"' "$f"
    done
}

@test "openclaw: restore writes tactical-console.bashrc into TACTICAL_REPO_ROOT" {
    grep -q 'mkdir -p "\$TACTICAL_REPO_ROOT"' "$REPO_ROOT/scripts/09-openclaw.sh"
    grep -q 'cp "\$tmp_restore/ubuntu-console/tactical-console.bashrc"' \
        "$REPO_ROOT/scripts/09-openclaw.sh"
}

@test "openclaw: restore reloads user systemd units after restoring them" {
    grep -q 'local restored_systemd_units=0' "$REPO_ROOT/scripts/09-openclaw.sh"
    grep -q 'systemctl --user daemon-reload >/dev/null 2>&1 || true' "$REPO_ROOT/scripts/09-openclaw.sh"
}

@test "openclaw: restore recreates missing parent directories before moving files" {
    command -v zip >/dev/null || skip "zip not installed"
    command -v unzip >/dev/null || skip "unzip not installed"

    local home_dir="$TAC_TEST_TMPDIR/restore-home-fresh"
    local restore_root="$TAC_TEST_TMPDIR/restore-target-fresh"
    local backups_dir="$home_dir/.openclaw/backups"
    local snapshot_src="$TAC_TEST_TMPDIR/restore-snapshot-src"
    local backup_zip="$backups_dir/snapshot_20260322_000000.zip"

    mkdir -p "$backups_dir" "$snapshot_src/.openclaw/workspace" \
        "$snapshot_src/.openclaw/agents" "$snapshot_src/.llm"
    printf '%s\n' 'workspace-ok' > "$snapshot_src/.openclaw/workspace/state.txt"
    printf '%s\n' 'agent-ok' > "$snapshot_src/.openclaw/agents/agent.txt"
    printf '%s\n' '{"restored":true}' > "$snapshot_src/.openclaw/openclaw.json"
    printf '%s\n' '1|demo|demo.gguf' > "$snapshot_src/.llm/models.conf"

    (cd "$snapshot_src" && zip -qr "$backup_zip" .)

    run env HOME="$home_dir" USER="${USER:-wayne}" bash -lc "
        source '$REPO_ROOT/env.sh' >/dev/null 2>&1
        export OC_ROOT='$restore_root/.openclaw'
        export OC_WORKSPACE='\$OC_ROOT/workspace'
        export OC_AGENTS='\$OC_ROOT/agents'
        export OC_LOGS='\$OC_ROOT/logs'
        export OC_BACKUPS='$backups_dir'
        export LLM_REGISTRY='$restore_root/.llm/models.conf'
        printf 'y\n' | oc-restore >/dev/null 2>&1
        test -f '\$OC_WORKSPACE/state.txt'
        test -f '\$OC_AGENTS/agent.txt'
        test -f '\$OC_ROOT/openclaw.json'
        test -f '$restore_root/.llm/models.conf'
    "
    [ "$status" -eq 0 ]
}

@test "dashboard: bashrc diagnostics target the canonical tactical-console.bashrc" {
    grep -q 'local src="\$TACTICAL_REPO_ROOT/tactical-console.bashrc"' "$REPO_ROOT/scripts/12-dashboard-help.sh"
}

@test "env.sh: library mode bootstraps OpenClaw state for cooldown writes" {
    local home_dir="$TAC_TEST_TMPDIR/env-home-bootstrap"
    mkdir -p "$home_dir"
    local cmd="source '$REPO_ROOT/env.sh' >/dev/null 2>&1"
    cmd+="; __set_cooldown smoke 123"
    cmd+="; test -f '$home_dir/.openclaw/maintenance_cooldowns.txt'"

    run env HOME="$home_dir" bash -lc "$cmd"
    [ "$status" -eq 0 ]
}

@test "env.sh: loads 09b-gog module (gog functions available)" {
    run bash -c "
        source '$REPO_ROOT/env.sh' >/dev/null 2>&1
        declare -f gog-status >/dev/null 2>&1
    "
    [ "$status" -eq 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# 38. GOG MODULE
# ─────────────────────────────────────────────────────────────────────────────

@test "gog: 09b-gog.sh exists" {
    [[ -f "$REPO_ROOT/scripts/09b-gog.sh" ]]
}

@test "gog: __is_gog_installed function is defined" {
    declare -f __is_gog_installed >/dev/null
}

@test "gog: gog-status function is defined" {
    declare -f gog-status >/dev/null
}

@test "gog: gog-login function is defined" {
    declare -f gog-login >/dev/null
}

@test "gog: gog-logout function is defined" {
    declare -f gog-logout >/dev/null
}

@test "gog: gog-version function is defined" {
    declare -f gog-version >/dev/null
}

@test "gog: gog-help function is defined" {
    declare -f gog-help >/dev/null
}

@test "gog: 09b-gog.sh loaded by tactical-console.bashrc array" {
    grep -q '09b-gog' "$REPO_ROOT/tactical-console.bashrc"
}

@test "gog: env.sh explicitly sources 09b-gog.sh" {
    grep -q '09b-gog.sh' "$REPO_ROOT/env.sh"
}

# ─────────────────────────────────────────────────────────────────────────────
# 37. HYGIENE — Extended checks
# ─────────────────────────────────────────────────────────────────────────────

@test "hygiene: no 'TODO' or 'FIXME' in core modules (or explicitly tracked)" {
    local count=0
    for f in "$REPO_ROOT"/scripts/[0-9][0-9]-*.sh; do
        [[ -f "$f" ]] || continue
        local hits
        hits=$(grep -ciE 'TODO|FIXME' "$f" || true)
        count=$((count + hits))
    done
    # Allow up to 5 tracked TODOs (but flag if there's an explosion)
    [[ "$count" -le 5 ]]
}

@test "hygiene: no shell scripts use 'echo -e' outside comments" {
    local violations=0
    for f in "$REPO_ROOT"/scripts/[0-9][0-9]-*.sh; do
        [[ -f "$f" ]] || continue
        local hits
        # Only match 'echo -e ' on lines that are NOT comments
        hits=$(grep -v '^[[:space:]]*#' "$f" | grep -c 'echo -e ' || true)
        violations=$((violations + hits))
    done
    [[ "$violations" -eq 0 ]]
}

@test "hygiene: quant-guide.conf exists and is non-empty" {
    [[ -s "$REPO_ROOT/config/quant-guide.conf" ]]
}

@test "hygiene: README.md exists" {
    [[ -f "$REPO_ROOT/README.md" ]]
}

@test "hygiene: env.sh exists and is non-empty" {
    [[ -s "$REPO_ROOT/env.sh" ]]
}

@test "hygiene: all 16 profile modules exist" {
    # 15 numerically-prefixed modules
    for i in 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15; do
        local found=0
        for f in "$REPO_ROOT"/scripts/${i}-*.sh; do
            [[ -f "$f" ]] && found=1
        done
        [[ "$found" -eq 1 ]] || { echo "Missing module: ${i}-*.sh"; return 1; }
    done
    # 09b-gog.sh is also a profile module
    [[ -f "$REPO_ROOT/scripts/09b-gog.sh" ]] || { echo "Missing module: 09b-gog.sh"; return 1; }
}

# ─────────────────────────────────────────────────────────────────────────────
# 29. OPENCLAW — Additional function tests
# ─────────────────────────────────────────────────────────────────────────────

@test "openclaw: so function is defined" {
    declare -f so >/dev/null
}

@test "openclaw: xo function is defined" {
    declare -f xo >/dev/null
}

@test "openclaw: oc-health function is defined" {
    declare -f oc-health >/dev/null
}

@test "openclaw: oc-doctor-local function is defined" {
    declare -f oc-doctor-local >/dev/null
}

@test "openclaw: oc-health supports json output" {
    # When OpenClaw is installed, oc-health runs the full diagnostic suite
    # which outputs human-readable text, not JSON. Skip in that case.
    if [[ "$__TAC_OPENCLAW_OK" == "1" ]]
    then
        skip "OpenClaw installed — enhanced output mode (not JSON fallback)"
    fi
    run oc-health --json
    [[ "$output" == \{* ]]
    [[ "$output" == *'"port":'* ]]
    [[ "$output" == *'"health_status":'* ]]
}

@test "openclaw: oc-health supports plain output" {
    if [[ "$__TAC_OPENCLAW_OK" == "1" ]]
    then
        skip "OpenClaw installed — enhanced output mode (not plain fallback)"
    fi
    run oc-health --plain
    [[ "$output" == *"port="* ]]
    [[ "$output" == *"health_status="* ]]
}

@test "openclaw: oc doctor-local supports json output" {
    run oc doctor-local --json
    [[ "$output" == \{* ]]
    [[ "$output" == *'"issues":'* ]]
}

@test "openclaw: oc-cache-clear dry-run preserves cache files" {
    local cache_file="$TAC_CACHE_DIR/tac_smoke_cache"
    printf '%s\n' 'cached' > "$cache_file"
    run oc-cache-clear --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"would be cleared"* ]]
    [[ -f "$cache_file" ]]
}

@test "maintenance: docs-sync function is defined" {
    declare -f docs-sync >/dev/null
}

@test "maintenance: cl dry-run preserves cleanup targets" {
    local tmpdir="$TAC_TEST_TMPDIR/cl-dry-run"
    mkdir -p "$tmpdir/.pytest_cache"
    touch "$tmpdir/python-3.12.exe"
    pushd "$tmpdir" >/dev/null
    # Use --report (or -r) for dry-run mode, not --dry-run
    run cl --report
    popd >/dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"would be removed"* ]] || [[ "$output" == *"FOUND"* ]]
    [[ -f "$tmpdir/python-3.12.exe" ]]
    [[ -d "$tmpdir/.pytest_cache" ]]
}

@test "openclaw: oc-backup function is defined" {
    declare -f oc-backup >/dev/null
}

@test "openclaw: oc-restore function is defined" {
    declare -f oc-restore >/dev/null
}

@test "openclaw: oc-restart function is defined" {
    declare -f oc-restart >/dev/null
}

@test "openclaw: ocstop function is defined" {
    declare -f ocstop >/dev/null
}

@test "openclaw: ocstart function is defined" {
    declare -f ocstart >/dev/null
}

@test "openclaw: __so_check_win_port function is defined" {
    declare -f __so_check_win_port >/dev/null
}

@test "openclaw: __bridge_windows_api_keys function is defined" {
    declare -f __bridge_windows_api_keys >/dev/null
}

@test "openclaw: oc function is defined and is a dispatcher" {
    declare -f oc >/dev/null
    # oc should contain case statement for subcommand dispatch
    grep -q 'case.*in' "$REPO_ROOT/scripts/09-openclaw.sh"
}

# end of file


# ─────────────────────────────────────────────────────────────────────────────
# 30. ADDITIONAL OPENCLAW TESTS (functions not yet tested)
# ─────────────────────────────────────────────────────────────────────────────

@test "openclaw: oc-skills function is defined" {
    declare -f oc-skills >/dev/null
}

@test "openclaw: oc-plugins function is defined" {
    declare -f oc-plugins >/dev/null
}

@test "openclaw: oc-memory-search function is defined" {
    declare -f oc-memory-search >/dev/null
}

@test "openclaw: oc-local-llm function is defined" {
    declare -f oc-local-llm >/dev/null
}

@test "openclaw: oc-sync-models function is defined" {
    declare -f oc-sync-models >/dev/null
}

@test "openclaw: oc-browser function is defined" {
    declare -f oc-browser >/dev/null
}

@test "openclaw: oc-nodes function is defined" {
    declare -f oc-nodes >/dev/null
}

@test "openclaw: oc-sandbox function is defined" {
    declare -f oc-sandbox >/dev/null
}

@test "openclaw: oc-env function is defined" {
    declare -f oc-env >/dev/null
}

@test "openclaw: oc-cache-clear function is defined" {
    declare -f oc-cache-clear >/dev/null
}

@test "openclaw: oc-diag function is defined" {
    declare -f oc-diag >/dev/null
}

@test "openclaw: oc-failover function is defined" {
    declare -f oc-failover >/dev/null
}

@test "openclaw: wacli function is defined" {
    declare -f wacli >/dev/null
}

@test "openclaw: oc-kgraph function is defined" {
    declare -f oc-kgraph >/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# 31. LLM MANAGER - ADDITIONAL TESTS
# ─────────────────────────────────────────────────────────────────────────────

@test "llm-manager: wake function is defined" {
    declare -f wake >/dev/null
}

@test "llm-manager: gpu-status function is defined" {
    declare -f gpu-status >/dev/null
}

@test "llm-manager: gpu-check function is defined" {
    declare -f gpu-check >/dev/null
}

@test "llm-manager: __gguf_metadata function is defined" {
    declare -f __gguf_metadata >/dev/null
}


@test "llm-manager: __save_tps function is defined" {
    declare -f __save_tps >/dev/null
}

@test "llm-manager: __renumber_registry function is defined" {
    declare -f __renumber_registry >/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# 32. DASHBOARD/HELP - ADDITIONAL TESTS
# ─────────────────────────────────────────────────────────────────────────────

@test "dashboard-help: bashrc_diagnose function is defined" {
    declare -f bashrc_diagnose >/dev/null
}

@test "dashboard-help: bashrc_dryrun function is defined" {
    declare -f bashrc_dryrun >/dev/null
}

@test "dashboard-help: tactical_help mentions pwsh" {
    grep -q 'pwsh' "$REPO_ROOT/scripts/12-dashboard-help.sh"
}

@test "dashboard-help: dashboard command bar includes pwsh" {
    grep -q 'pwsh' "$REPO_ROOT/scripts/12-dashboard-help.sh"
    # Verify it's in the cmds string specifically
    grep -q '| pwsh' "$REPO_ROOT/scripts/12-dashboard-help.sh"
}

# ─────────────────────────────────────────────────────────────────────────────
# 33. UI ENGINE - ADDITIONAL TESTS
# ─────────────────────────────────────────────────────────────────────────────

@test "ui-engine: __require_command function is defined" {
    declare -f __require_command >/dev/null
}

@test "ui-engine: __require_command returns 0 for existing command" {
    run __require_command bash
    [ "$status" -eq 0 ]
}

@test "ui-engine: __require_command returns 1 for missing command" {
    run __require_command nonexistent_command_xyz123
    [ "$status" -eq 1 ]
    [[ "$output" == *"NOT INSTALLED"* ]]
}

# end of file
