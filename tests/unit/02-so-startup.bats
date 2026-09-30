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
# It also records that it ran: the journal is read BEFORE the probe, so a row that
# came from the log must not have paid the probe's seconds, and a row that came from
# the probe must have.  Without the marker both orderings pass these cases.
__stub_failing_openclaw() {
    mkdir -p "$TAC_TEST_TMPDIR/bin"
    printf '#!/usr/bin/env bash\n: > "%s"\nexit 1\n' "$TAC_TEST_TMPDIR/probe-ran" > "$TAC_TEST_TMPDIR/bin/openclaw"
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
    # And it cost no probe: the drain was named from the log alone.
    [ ! -e "$TAC_TEST_TMPDIR/probe-ran" ]
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
    # 'running' leaves the serving question open, so this row DID pay the probe.
    [ -e "$TAC_TEST_TMPDIR/probe-ran" ]
}

@test "so: a serving but CPU-degraded gateway is reported DEGRADED, never told to restart" {
    # Measured on this box 2026-09-30: the gateway's own health RPC COMPLETED
    # (journal: '[ws] ⇄ res ✓ health 32764ms'), so it was serving; the CLI's 10 s
    # transport timeout expired first, and `so` answered "RUNNING but UNHEALTHY — run:
    # openclaw gateway restart" — restart advice for CPU contention that a restart
    # cannot fix.  The discriminator is the gateway's own liveness warning, logged
    # AFTER the 'ready' that proves it is serving.  The warning line is verbatim.
    __so_test_prelude
    journalctl() {
        printf '%s\n' \
            '2026-09-30T09:44:11.000+01:00 [gateway] ready' \
            '2026-09-30T09:46:46.030+01:00 [diagnostic] liveness warning: reasons=cpu interval=2s degradedFor=223s eventLoopDelayP99Ms=707.3 cpuCoreRatio=1.851 active=0 waiting=0 queued=0'
    }

    run so

    [ "$status" -eq 1 ]
    [[ "$output" == *"CPU-DEGRADED"* ]]
    [[ "$output" == *"do NOT restart"* ]]
    [[ "$output" == *"degradedFor=223s"* ]]
    [[ "$output" == *"eventLoopDelayP99Ms=707.3"* ]]
    # Not the unable-to-answer row, and not the remedy a restart spiral starts with.
    [[ "$output" != *"UNHEALTHY"* ]]
    [[ "$output" != *"openclaw gateway restart"* ]]
    # The whole point of reading the log first: this row cost no probe at all.
    [ ! -e "$TAC_TEST_TMPDIR/probe-ran" ]
}

@test "so: a liveness warning outside the short window is not read as degraded" {
    # The classifier's window is 15 min, so without a recency bound a warning from
    # 14 min ago would keep reporting a gateway that has since recovered as degraded
    # for the rest of that window.  The stub answers by argument: the classification
    # sees 'ready' plus an old warning, the recency read sees no warning at all.
    __so_test_prelude
    journalctl() {
        case "$*" in
            *"-3 min"*) return 0 ;;
            *) printf '%s\n' \
                '2026-09-30T09:32:11.000+01:00 [gateway] ready' \
                '2026-09-30T09:33:46.030+01:00 [diagnostic] liveness warning: reasons=cpu interval=2s degradedFor=223s eventLoopDelayP99Ms=707.3' ;;
        esac
    }

    run so

    [ "$status" -eq 1 ]
    [[ "$output" == *"RUNNING but UNHEALTHY"* ]]
    [ -e "$TAC_TEST_TMPDIR/probe-ran" ]     # the probe had to answer it
}

@test "so: a degraded gateway that booted long ago is still read as degraded" {
    # The window is 15 min, so a gateway up for hours has no 'ready' line left inside
    # it.  Requiring "serving" on that line alone would make this verdict fire only
    # shortly after a boot — the opposite of the case that matters, since a box under
    # batch load stays degraded for hours.  The witness is a completed client request
    # instead: the real line carries the gateway's two glyph markers between '[ws]' and
    # 'res', which the pattern skips with a one-character wildcard, so the stub stands a
    # '~' in for them.
    __so_test_prelude
    journalctl() {
        printf '%s\n' \
            '2026-09-30T10:20:11.000+01:00 [ws] ~ res ok projects.list 33017ms conn=abc123 id=15' \
            '2026-09-30T10:20:46.030+01:00 [diagnostic] liveness warning: reasons=cpu interval=2s degradedFor=612s eventLoopDelayP99Ms=707.3 active=0 waiting=0 queued=0'
    }

    run so

    [ "$status" -eq 1 ]
    [[ "$output" == *"CPU-DEGRADED"* ]]
    [[ "$output" != *"openclaw gateway restart"* ]]
    [ ! -e "$TAC_TEST_TMPDIR/probe-ran" ]
}

@test "xo: a gateway still active after the stop is not reported TERMINATED" {
    # THE INJECTED-FAILURE CASE for xo's read-back (docs/contracts/command-contracts.yaml,
    # entry `xo`): the unit is queried and still active, so the stop did not take.  Pre-fix
    # this printed "[TERMINATED]" and exited 0 — a success message with no read-back behind
    # it.  __oc_safe_gateway_shutdown is stubbed so nothing here can touch the live gateway.
    export __TAC_OPENCLAW_OK=1
    systemctl() { return 0; }
    __oc_safe_gateway_shutdown() { return 0; }
    __llm_server_running() { return 1; }

    run xo
    [ "$status" -eq 1 ]
    [[ "$output" == *"STILL RUNNING"* ]]
    [[ "$output" != *"TERMINATED"* ]]
}

@test "xo: TERMINATED is printed only once the unit and the port are both gone" {
    # The other half, so the case above cannot pass by always reporting failure.  The
    # first systemctl call is xo's own "is anything running?" probe (active), the second
    # is the witness (gone), and __test_port is stubbed free by setup() — so the stop is
    # genuinely read back as taken.
    export __TAC_OPENCLAW_OK=1
    systemctl() {
        if [[ -f "$TAC_TEST_TMPDIR/witness-asked" ]]; then
            return 1
        fi
        : > "$TAC_TEST_TMPDIR/witness-asked"
        return 0
    }
    __oc_safe_gateway_shutdown() { return 0; }
    __llm_server_running() { return 1; }

    run xo
    [ "$status" -eq 0 ]
    [[ "$output" == *"TERMINATED"* ]]
}

@test "so: __oc_gateway_started needs BOTH the unit active and the port answering" {
    # The witness for `so`'s start claim (docs/contracts/command-contracts.yaml, entry
    # `so`).  Catches: a half-claim — `systemctl start` returning 0 is a statement about
    # the request, not the service, and a port bound by something else is not our unit.
    local _status
    systemctl() { return 1; }      # unit never became active
    __test_port() { return 0; }    # ...but the port answers
    _status=0
    __oc_gateway_started || _status=$?
    [ "$_status" -ne 0 ] || { echo "an inactive unit must fail the read-back"; return 1; }

    systemctl() { return 0; }      # unit active
    __test_port() { return 1; }    # ...but nothing is serving
    _status=0
    __oc_gateway_started || _status=$?
    [ "$_status" -ne 0 ] || { echo "a closed port must fail the read-back"; return 1; }

    systemctl() { return 0; }
    __test_port() { return 0; }
    _status=0
    __oc_gateway_started || _status=$?
    [ "$_status" -eq 0 ] || { echo "an active unit with an answering port must pass"; return 1; }
}

@test "so: a start that does not leave the gateway serving is FAILURE, not success" {
    # THE INJECTED-FAILURE CASE for that witness: the gateway is not yet bound, so `so`
    # runs its full startup, `__so_start_gateway` "succeeds", and the read-back finds the
    # unit inactive — the pre-fix behaviour was to return 0 having claimed the start.
    export __TAC_OPENCLAW_OK=1
    mkdir -p "$TAC_TEST_TMPDIR/oc"
    export OC_ROOT="$TAC_TEST_TMPDIR/oc"
    oc() { :; }
    __test_port() { return 1; }              # not bound -> the full startup path
    __so_clear_wslrelay() { :; }
    __so_check_stale_hold() { :; }
    __so_clear_stale_state() { :; }
    __so_free_port() { return 0; }
    __so_cycle_tailscale_serve() { :; }
    __so_push_api_keys() { :; }
    __so_ensure_llm_running() { return 0; }
    __so_start_gateway() { return 0; }       # the start "succeeds"...
    __so_ensure_default_agent_session() { :; }
    systemctl() { return 1; }                # ...but the unit is not active

    run so
    [ "$status" -eq 1 ]
    [[ "$output" == *"STARTED but not serving"* ]]
}

@test "so: a health probe that TIMES OUT is not reported as unhealthy, and names no restart" {
    # A budget that expires says "too slow to answer", NOT "unhealthy": measured
    # 2026-09-30, `openclaw gateway health` takes 3.0-4.6 s against a HEALTHY gateway
    # here, so the old 5 s window expired on a working gateway and `so` then named
    # `openclaw gateway restart` — the action that re-enters the drain window.  This
    # drives the REAL `so` (not a helper): that row is what the operator acts on.
    export __TAC_OPENCLAW_OK=1
    export SO_HEALTH_TIMEOUT=1
    __test_port() { return 0; }        # the port answers: the already-running branch
    __so_ensure_shell_env() { return 0; }
    # Prints NOTHING on purpose.  The journal is read BEFORE the probe now, so a real
    # journalctl here would decide the row and this case would assert the probe path
    # while never reaching it — green on a box with a running gateway, differently
    # branched without one.  That divergence is what this case was fixed for once.
    journalctl() { return 0; }
    # An EXECUTABLE stub, NOT a shell function: `timeout` execs its argument, so a
    # function is never reached.  That is why this case was green here and RED in CI —
    # locally the probe hit the REAL `openclaw` (3.0-4.6 s) and timed out at 1 s, while
    # CI has no `openclaw` at all, so it exited 127 and took a different branch.  The
    # stub also outlasts the pre-change 5 s budget, so the case can fail against it.
    mkdir -p "$TAC_TEST_TMPDIR/bin"
    printf '#!/usr/bin/env bash\nsleep 6\n' > "$TAC_TEST_TMPDIR/bin/openclaw"
    chmod +x "$TAC_TEST_TMPDIR/bin/openclaw"
    export PATH="$TAC_TEST_TMPDIR/bin:$PATH"

    run so

    [ "$status" -eq 1 ]
    [[ "$output" == *"HEALTH PROBE TIMED OUT after 1s"* ]]
    [[ "$output" == *"NOT a health verdict"* ]]
    [[ "$output" != *"UNHEALTHY"* ]]
    [[ "$output" != *"gateway restart"* ]]
}

@test "xo: a pending start job means the gateway is coming BACK, not gone" {
    # The witness samples one instant, so a unit that is down NOW but has a start job
    # QUEUED must not read as gone — `openclaw gateway restart` and `xo` both stop for
    # minutes before starting, and on 2026-09-30 xo printed TERMINATED while the
    # journal shows the gateway coming back (SIGTERM 23:59:50 -> ready 00:07:23).
    # Mechanism verified on a probe unit: `show -p Job` returns the live job id while
    # a start job runs (`Job=[43187]`, `activating/start-pre`).
    systemctl() {
        case "$*" in
            *"show -p Job"*) printf '%s\n' 43187; return 0 ;;   # a start is queued
            *) return 1 ;;                                      # and it is not active now
        esac
    }
    # the suite's setup already pins __test_port to "free", so the other two checks pass

    run __oc_gateway_gone

    [ "$status" -eq 1 ]
}

@test "oc purge: a gateway that is not gone is a REFUSAL, and nothing is deleted" {
    # `oc purge` deletes state, so a stop that does not land must REFUSE rather than
    # delete under a live gateway.  __oc_safe_gateway_shutdown is fire-and-forget (its
    # last statement is an `rm`, so its status says nothing) and the unit's stop budget
    # is 330s — measured 2026-09-30, the old code purged 0.5s after asking it to stop.
    export __TAC_OPENCLAW_OK=1
    export OC_PURGE_WAIT_S=0                 # do not sleep; __oc_gateway_gone decides
    export OC_AGENTS="$TAC_TEST_TMPDIR/agents"
    mkdir -p "$OC_AGENTS/alpha/sessions"
    : > "$OC_AGENTS/alpha/sessions/s.json"
    __oc_safe_gateway_shutdown() { return 0; }
    __oc_gateway_gone() { return 1; }        # still up

    run oc-purge

    [ "$status" -eq 1 ]
    [[ "$output" == *"REFUSED - the gateway is still up"* ]]
    [ -f "$OC_AGENTS/alpha/sessions/s.json" ]  # the point: nothing was deleted
}

# end of file
