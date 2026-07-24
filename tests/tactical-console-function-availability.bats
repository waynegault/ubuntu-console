#!/usr/bin/env bats
# ==============================================================================
# Consolidated function-availability + gap tests
# ==============================================================================
# Replaces ~95 individual "function is defined" tests in tactical-console.bats
# with a single batch check.  Also covers commands that previously had no
# dedicated test (explain).
# ==============================================================================

setup_file() {
    export REPO_ROOT
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export PROFILE_PATH="$REPO_ROOT/tactical-console.bashrc"
    export TAC_TEST_TMPDIR
    TAC_TEST_TMPDIR="$(mktemp -d)"
    export TAC_CACHE_DIR="$TAC_TEST_TMPDIR/cache"
    mkdir -p "$TAC_CACHE_DIR"
    export __TAC_INITIALIZED=1
}

teardown_file() {
    rm -rf "${TAC_TEST_TMPDIR:-/tmp/bats-noop}"
}

# Source the profile so all functions are available.
setup() {
    # shellcheck disable=SC1090
    source "$REPO_ROOT/env.sh" >/dev/null 2>&1 || true
}

# ── All expected functions (consolidated from 95 individual tests) ────────

@test "fn-avail: all expected functions and aliases are defined" {
    local missing=0
    local -a expected=(
        # Health
        oc-health gpu-check gpu-status __resolve_smi
        # Maintenance
        up cl logtrim __check_cooldown __set_cooldown docs-sync
        # Model management
        model serve halt
        # Prompt / UI
        custom_prompt_command __require_command
        # Error handler
        __tac_err_handler
        # LLM manager internals
        local_chat wtf_repl chat-context chat-pipe
        __llm_chat_send __llm_stream
        __calc_gpu_layers __calc_ctx_size __calc_threads
        __quant_label __model_scan __model_list __model_use __model_stop
        __model_info __model_bench __model_doctor __model_recommend
        __llm_registry_entry_by_num __llm_default_entry
        __llm_wait_for_health __model_bench_history
        __gguf_metadata __save_tps __renumber_registry
        __save_model_ctx
        # OpenClaw
        oc so xo oc-doctor-local
        oc-backup oc-restore oc-restart ocstop ocstart
        oc-skills oc-plugins oc-memory-search oc-local-llm oc-sync-models
        oc-browser oc-nodes oc-sandbox oc-env oc-cache-clear
        oc-diag oc-failover oc-kgraph
        __so_check_win_port __bridge_windows_api_keys
        wacli
        # GOG
        __is_gog_installed gog-status gog-login gog-logout gog-version gog-help
        # LLM management
        wake gpu-status gpu-check
        # Dashboard / diagnostics
        bashrc_diagnose bashrc_dryrun
        # Deployment
        mkproj commit_auto
        # System info
        sysinfo get-ip
    )
    for fn in "${expected[@]}"; do
        if ! declare -f "$fn" >/dev/null 2>&1; then
            echo "  MISSING: $fn" >&3
            ((missing++))
        fi
    done

    # Aliases that must exist
    local -a alias_list=(
        h cls m reload ll la l commit cpwd
    )
    for a in "${alias_list[@]}"; do
        if ! alias "$a" >/dev/null 2>&1; then
            echo "  MISSING ALIAS: $a" >&3
            ((missing++))
        fi
    done

    [[ "$missing" -eq 0 ]]
}

# ── explain — graceful failure when no LLM is running ────────────────────

@test "explain: returns error when no previous command (non-interactive shell)" {
    run explain
    # In a non-interactive shell, 'fc' will fail, so explain returns 1
    # with a descriptive message.
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"NO PREVIOUS COMMAND"* ]]
}
