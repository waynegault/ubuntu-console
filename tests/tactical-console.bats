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
VERSION="1.0"

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
    local _sed_args=(
        -e '/^case \$- in$/,/^esac$/d'
        -e '/^set -E$/d'
        -e "/^trap '__tac_err_handler' ERR$/d"
        -e '/^__tac_preexec_fired=/d'
        -e '/^trap .*custom_prompt_command/,/DEBUG$/d'
        -e 's/^declare -ri //'
    )
    # Patch the loader — rewrite module dir to the patched copy
    sed "${_sed_args[@]}" \
        -e "s|_tac_module_dir=.*|_tac_module_dir=\"$patched_scripts\"|" \
        "$PROFILE_PATH" > "$patched"
    # Patch module files with the same transforms
    mkdir -p "$patched_scripts"
    for _f in "$REPO_ROOT"/scripts/[0-9][0-9]-*.sh; do
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
}

# Source the pre-built patched profile per-test.  The sed work is already
# done (by _build_test_profile in setup_file), so this is just a fast source.
setup() {
    # shellcheck disable=SC1090
    source "$TAC_TEST_TMPDIR/profile_patched.bash" &>/dev/null || true
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
    count=$(grep -rc '@modular-section:' "$PROFILE_PATH" "$REPO_ROOT"/scripts/[0-9][0-9]-*.sh | awk -F: '{s+=$NF} END{print s}')
    [[ "$count" -ge 10 ]]
}

@test "structure: interactive guard exists in file" {
    grep -q 'case \$- in' "$PROFILE_PATH"
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. GLOBAL CONSTANTS & CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────

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

@test "constants: COOLDOWN_WEEKLY is 604800 (7d)" {
    [[ "$COOLDOWN_WEEKLY" -eq 604800 ]]
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

@test "calc: __calc_ctx_size small GPU model (3-4GB) returns MOE_DEFAULT_CTX" {
    # 3GB model, large native ctx
    result=$(__calc_ctx_size $((3 * 1024 * 1024 * 1024)) 32768 "llama")
    [[ "$result" -eq "$MOE_DEFAULT_CTX" ]]
}

@test "calc: __calc_ctx_size tiny model (<3GB) caps at 16384" {
    result=$(__calc_ctx_size $((1 * 1024 * 1024 * 1024)) 32768 "llama")
    [[ "$result" -eq 16384 ]]
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
    [[ "$output" == *"Unknown subcommand"* ]]
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

@test "cross-script: watchdog LLAMA_SERVER_BIN default matches bashrc" {
    local wd_bin
    wd_bin=$(grep -oP 'LLAMA_SERVER_BIN="\$\{LLAMA_SERVER_BIN:-\K[^}]+' "$REPO_ROOT/bin/llama-watchdog.sh")
    [[ "$wd_bin" == "$LLAMA_SERVER_BIN" ]]
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
             "$REPO_ROOT"/scripts/lint.sh \
             "$REPO_ROOT"/scripts/run-tests.sh; do
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

@test "hygiene: no lines exceed 120 characters in core scripts" {
    for f in "$PROFILE_PATH" \
             "$REPO_ROOT"/scripts/[0-9][0-9]-*.sh \
             "$REPO_ROOT"/bin/*.sh \
             "$REPO_ROOT"/install.sh \
             "$REPO_ROOT"/scripts/lint.sh \
             "$REPO_ROOT"/scripts/run-tests.sh; do
        [[ -f "$f" ]] || continue
        local long
        long=$(awk 'length > 120' "$f" | wc -l)
        [[ "$long" -eq 0 ]]
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
    for f in "$REPO_ROOT"/scripts/[0-9][0-9]-*.sh; do
        [[ -f "$f" ]] || continue
        local line1
        line1=$(head -1 "$f")
        [[ "$line1" == "# shellcheck shell=bash" ]]
    done
}

@test "hygiene: all 13 modules have a Module Version comment" {
    local count
    count=$(grep -l '^# Module Version:' \
        "$REPO_ROOT"/scripts/[0-9][0-9]-*.sh \
        | wc -l)
    [[ "$count" -eq 13 ]]
}

@test "hygiene: module versions follow '# Module Version: N' pattern" {
    for f in "$REPO_ROOT"/scripts/[0-9][0-9]-*.sh; do
        [[ -f "$f" ]] || continue
        grep -qP '^# Module Version: \d+' "$f"
    done
}

@test "cross-script: watchdog ACTIVE_LLM_FILE matches bashrc constant" {
    local wd_file
    wd_file=$(grep -oP 'ACTIVE_LLM_FILE="\K[^"]+' \
        "$REPO_ROOT/bin/llama-watchdog.sh")
    [[ "$wd_file" == "$ACTIVE_LLM_FILE" ]]
}
