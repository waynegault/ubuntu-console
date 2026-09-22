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

# ---------------------------------------------------------------------------
# so: naming the real phase when the health probe fails
#
# A graceful drain KEEPS the listening socket and answers every request 503
# 'Gateway websocket admission closed', so the probe fails exactly as it does for
# a wedged gateway — and 'so' answered both with "RUNNING but UNHEALTHY — run:
# openclaw gateway restart".  That named the action which caused the window:
# measured 2026-09-22, three restarts inside 8 minutes turned one restart into a
# 15.5-minute outage (17:35:53 -> 17:51:20) and every one of them was issued
# after 'so' had said UNHEALTHY.  __so_gateway_phase reads the gateway's own
# lifecycle log instead.  These six pin the classifier; the two below pin the
# messages it drives.
# ---------------------------------------------------------------------------
# The journal lines below are verbatim from the real gateway journal
# (2026-09-22).  Some gateway loggers prefix their own ISO timestamp and others
# let journald supply it, so __so_gateway_phase has to classify either shape.
# Matching only the timestamp-less form is what a first pass got wrong: every
# real 'ready' line carries the timestamp, so the classifier could never return
# 'running'.  Validating the patterns against the real journal is what caught it.
@test "so: __so_gateway_phase reads a drain from the gateway log" {
    journalctl() {
        printf '%s\n' \
            '2026-09-22T17:50:31.773+01:00 [gateway] loading configuration…' \
            '2026-09-22T17:51:16.000+01:00 [gateway] ready' \
            '2026-09-22T17:43:51.000+01:00 [gateway] received SIGTERM; restarting' \
            '2026-09-22T17:43:51.441+01:00 [gateway] draining active work before stop with timeout 315000ms: queueSize=6 embeddedRuns=3'
    }

    run __so_gateway_phase openclaw-gateway.service

    [ "$status" -eq 0 ]
    [ "$output" = "draining" ]
}

@test "so: __so_gateway_phase reads the external-restart drain variant" {
    journalctl() {
        printf '%s\n' \
            '[gateway] received SIGTERM; restarting' \
            '[gateway] still draining active work before external-restart: backgroundExecSessions=1 activeTasks=1'
    }

    run __so_gateway_phase openclaw-gateway.service

    [ "$status" -eq 0 ]
    [ "$output" = "draining" ]
}

@test "so: __so_gateway_phase reads a cold start from the gateway log" {
    journalctl() {
        printf '%s\n' \
            '2026-09-22T17:50:31.773+01:00 [gateway] loading configuration…' \
            '2026-09-22T17:50:39.688+01:00 [gateway] resolving authentication…' \
            '2026-09-22T17:50:39.721+01:00 [gateway] starting...'
    }

    run __so_gateway_phase openclaw-gateway.service

    [ "$status" -eq 0 ]
    [ "$output" = "starting" ]
}

# Ordering is the whole point of tail -n 1: a completed restart ends in 'ready',
# and a 'ready' from before a drain must not mask the drain that followed it.
@test "so: __so_gateway_phase treats a drain finished by 'ready' as running" {
    journalctl() {
        printf '%s\n' \
            '2026-09-22T17:43:51.441+01:00 [gateway] draining active work before stop with timeout 315000ms: queueSize=6' \
            '2026-09-22T17:43:58.000+01:00 [gateway] active-work drain settled; beginning server close' \
            '2026-09-22T17:50:39.721+01:00 [gateway] starting...' \
            '2026-09-22T17:51:16.100+01:00 [gateway] ready'
    }

    run __so_gateway_phase openclaw-gateway.service

    [ "$status" -eq 0 ]
    [ "$output" = "running" ]
}

@test "so: __so_gateway_phase handles a timestamp-less 'ready' line too" {
    journalctl() {
        printf '%s\n' \
            '[gateway] starting...' \
            '[gateway] ready'
    }

    run __so_gateway_phase openclaw-gateway.service

    [ "$status" -eq 0 ]
    [ "$output" = "running" ]
}

@test "so: __so_gateway_phase reports unknown when the log has no lifecycle line" {
    journalctl() { return 0; }

    run __so_gateway_phase openclaw-gateway.service

    [ "$status" -eq 0 ]
    [ "$output" = "unknown" ]
}

# The probe runs as `timeout 5 openclaw ...`, and timeout execs a binary — it
# cannot call a shell function — so the stub has to be a real file on PATH or the
# test would invoke the live CLI and depend on the real gateway's state.
__stub_failing_openclaw() {
    mkdir -p "$TAC_TEST_TMPDIR/bin"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$TAC_TEST_TMPDIR/bin/openclaw"
    chmod +x "$TAC_TEST_TMPDIR/bin/openclaw"
    export PATH="$TAC_TEST_TMPDIR/bin:$PATH"
}

__so_test_prelude() {
    export __TAC_OPENCLAW_OK=1
    mkdir -p "$TAC_TEST_TMPDIR/oc"
    export OC_ROOT="$TAC_TEST_TMPDIR/oc"   # no openclaw.json -> __so_ensure_shell_env is a no-op
    __test_port() { return 0; }            # port answers...
    __stub_failing_openclaw                # ...but the gateway does not
}

@test "so: a draining gateway is reported RESTARTING and is never told to restart" {
    __so_test_prelude
    journalctl() {
        printf '%s\n' \
            '2026-09-22T17:51:16.000+01:00 [gateway] ready' \
            '2026-09-22T17:43:51.000+01:00 [gateway] received SIGTERM; restarting' \
            '2026-09-22T17:48:52.794+01:00 [gateway] still draining active work before stop: queueSize=2 embeddedRuns=1'
    }

    run so

    [ "$status" -eq 1 ]
    [[ "$output" == *"RESTARTING"* ]]
    [[ "$output" == *"do NOT restart"* ]]
    # The remedy that caused the window must be absent from this path.
    [[ "$output" != *"openclaw gateway restart"* ]]
}

@test "so: a bound-but-wedged gateway still gets the restart advice" {
    __so_test_prelude
    # 'ready' with no drain after it: the gateway claims to be serving and is not,
    # which is the case the restart advice exists for.
    journalctl() {
        printf '%s\n' \
            '[gateway] starting...' \
            '[gateway] ready'
    }

    run so

    [ "$status" -eq 1 ]
    [[ "$output" == *"RUNNING but UNHEALTHY"* ]]
    [[ "$output" == *"openclaw gateway restart"* ]]
}

# end of file
