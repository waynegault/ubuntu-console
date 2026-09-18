#!/usr/bin/env bats
# Unit tests for OpenClaw startup path when Local LLM default is unset.

setup() {
    export REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export TAC_TEST_TMPDIR="$(mktemp -d)"
    export TAC_CACHE_DIR="$TAC_TEST_TMPDIR/cache"
    mkdir -p "$TAC_CACHE_DIR"

    # Source scripts FIRST so 01-constants.sh sets LLM_REGISTRY to the
    # real path, THEN override with a test-local path so no code writes
    # to the real ~/.llm/models.conf during tests.
    # shellcheck source=scripts/01-constants.sh
    source "$REPO_ROOT/scripts/01-constants.sh"
    # shellcheck source=scripts/03-design-tokens.sh
    source "$REPO_ROOT/scripts/03-design-tokens.sh"
    # shellcheck source=scripts/05-ui-engine.sh
    source "$REPO_ROOT/scripts/05-ui-engine.sh"
    # shellcheck source=scripts/_startup-env.sh
    source "$REPO_ROOT/scripts/_startup-env.sh"   # provides __tac_source_submodules
    # shellcheck source=scripts/09-openclaw.sh
    source "$REPO_ROOT/scripts/09-openclaw.sh"

    # Override paths AFTER sourcing so we don't touch the real registry.
    export LLM_REGISTRY="$TAC_TEST_TMPDIR/models.conf"
    export ACTIVE_LLM_FILE="$TAC_TEST_TMPDIR/active_llm"
    export LLM_PORT=8081
    export OC_PORT=18789

    # Bypass the systemd llama-xe-minicpm5-1b-chat.service management branch in
    # __so_ensure_llm_running (see 09a-oc-gateway.sh): unit tests exercise
    # the legacy registry-based fallback, not live systemd + a real model.
    export TAC_SKIP_SERVICE_LLM=1

    # Keep test output deterministic.
    __llm_default_file() { echo ""; }
    __llm_registry_entry_by_file() { return 1; }
    __test_port() { return 1; }
    pgrep() { return 1; }
    wake() { return 0; }
}

teardown() {
    rm -rf "$TAC_TEST_TMPDIR"
}

@test "so: __so_ensure_llm_running uses first registry model number when no default is set" {
    cat > "$LLM_REGISTRY" <<'EOF'
#|name|file|size_gb|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|fit_target_mb|backend|mmap_mode|flash_attn|tps|autotuned|is_default|in_vram
1|Model One|model-one.gguf|1.0G|Q4_K_M/q8_0|qwen2|24|4096|6|1024|256|1|1024|llama_server|auto|on|0|no|no|no
2|Model Two|model-two.gguf|1.1G|Q4_K_M/q8_0|qwen2|24|4096|6|1024|256|1|1024|llama_server|auto|on|0|no|no|no
EOF

    serve() {
        printf '%s\n' "$*" > "$TAC_TEST_TMPDIR/serve_args.txt"
        return 0
    }

    run __so_ensure_llm_running
    [ "$status" -eq 0 ]
    run cat "$TAC_TEST_TMPDIR/serve_args.txt"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}

@test "so: __so_ensure_llm_running fails with clear message when registry has no models" {
    cat > "$LLM_REGISTRY" <<'EOF'
#|name|file|size_gb|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|fit_target_mb|backend|mmap_mode|flash_attn|tps|autotuned|is_default|in_vram
EOF

    serve() { return 0; }

    run __so_ensure_llm_running
    [ "$status" -eq 1 ]
    [[ "$output" == *"Local LLM offline and no models available"* ]]
}

# A hold disables gateway-guard.sh's recovery, so an orphaned one leaves the
# gateway down with nothing to bring it back — and nothing logs it.  `so` clears
# one, but ONLY past the guard's own age limit: a younger hold belongs to a
# maintenance/compaction script that is mid-flight, and the guard is honouring it
# deliberately.  The threshold is the guard's variable so there is one policy.
@test "so: a fresh gateway hold is left alone (a maintenance script may own it)" {
    mkdir -p "$TAC_TEST_TMPDIR/oc"
    export OC_ROOT="$TAC_TEST_TMPDIR/oc"
    touch "$OC_ROOT/.gateway-hold"

    run __so_check_stale_hold

    [ "$status" -eq 1 ]
    [[ "$output" == *"recovery guard deliberately paused"* ]]
    [ -e "$OC_ROOT/.gateway-hold" ]
}

@test "so: a stale gateway hold is cleared (the guard cannot recover while it exists)" {
    mkdir -p "$TAC_TEST_TMPDIR/oc"
    export OC_ROOT="$TAC_TEST_TMPDIR/oc"
    export OPENCLAW_GUARD_HOLD_MAX_AGE=600
    touch -d '700 seconds ago' "$OC_ROOT/.gateway-hold"

    run __so_check_stale_hold

    [ "$status" -eq 0 ]
    [[ "$output" == *"STALE HOLD"* ]]
    [ ! -e "$OC_ROOT/.gateway-hold" ]
}

# end of file
