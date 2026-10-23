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

    # `oc purge` requires a SERVING gateway, and on this box that is the LIVE one: a case
    # that let the real helper probe it would reach the real CLI.  The neutral default is
    # "the gateway already serves"; the refusal case below supplies its own stub.
    __oc_purge_ensure_serving() { return 0; }

    # Mock the systemd boundary — the runner has no user session bus
    # (ci-behavioral-bats-red-2026-09-21: a real `systemctl --user` there answers
    # nothing while it answers fine on a workstation, so such a test passes locally and
    # fails in CI).  `__so_gateway_phase` asserts the MANAGED unit is active BEFORE it
    # reads the health paths (09a:798, added 2026-10-14), so with an empty answer the
    # managed-unit branch fired first and the wedged / timed-out verdicts below it were
    # never reached.  Locally this also stops these cases reading this box's live
    # gateway.  Defined AFTER the sources, as this harness requires.
    systemctl() {
        while [[ "${1:-}" == --* ]]; do shift; done
        local _verb="${1:-}"
        shift || true
        case "${_verb} ${1:-}" in
            "is-active openclaw-gateway.service")     echo active ;;
            "is-active openclaw-gateway-guard.timer") echo active ;;
            "is-active "*)                            echo inactive ;;
        esac
    }
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

# __so_gateway_bound_age feeds `oc health`'s POST-BIND measure: the checker can see
# that the listener is bound but not HOW LONG it has been bound, and the whole
# difference between a start that is coming up and one that is stalled is that
# interval.  The journal carries it only as a timestamp, so the helper reads
# `--output=short-unix` and differences the newest bind line against now.
#
# The stub below emits the real short-unix shape — `<epoch>.<micros> <host> <id>:
# <message>` — with the two lines in journal order (oldest first), so `tail -n 1`
# picking the NEWEST is what the case proves: the older line carries a much smaller
# epoch, and an implementation reading `head -n 1` would report the wrong age.
@test "so: __so_gateway_bound_age ages the NEWEST listener-bind line" {
    local _now _old
    _now="$(date +%s)"
    _old=$(( _now - 9000 ))
    journalctl() {
        printf '%s.000000 host unit[1]: 2026-10-07T05:33:08.000+01:00 [gateway] http server listening (15 plugins: x; 145.7s)\n' "$_old"
        printf '%s.167487 host unit[1]: 2026-10-07T05:51:40.167+01:00 [gateway] http server listening (15 plugins: x; 145.7s)\n' "$(( _now - 258 ))"
    }

    run __so_gateway_bound_age openclaw-gateway.service

    [ "$status" -eq 0 ]
    # A second of slack: the helper calls `date` itself, after the stub line was built.
    [ "$output" -ge 257 ]
    [ "$output" -le 259 ]
}

@test "so: __so_gateway_bound_age prints nothing when the window has no bind line" {
    # A pre-bind start, or a journal that has aged the line out: NO output is the
    # contract (the checker reads empty as "no post-bind evidence" and falls back to
    # the elapsed bound).  Printing 0 here would report a start as just-bound forever.
    journalctl() {
        printf '%s\n' \
            '2026-10-07T05:50:39.721+01:00 [gateway] starting...' \
            '2026-10-07T05:50:31.773+01:00 [gateway] loading configuration…'
    }

    run __so_gateway_bound_age openclaw-gateway.service

    [ "$status" -eq 0 ]
    [ -z "$output" ]
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

@test "so: a drain outranks a liveness warning logged during it" {
    # A draining gateway still COMPLETES the requests admitted before the SIGTERM, so a
    # completion line restores the serving witness, and a loaded box keeps warning while
    # it drains: the newest warning can post-date the SIGTERM.  Without the precedence
    # guard the classifier answered `degraded` here — the restart window reported under
    # the wrong cause, which is the one verdict the drain handling exists to get right.
    # The completion line is real-shaped with a '~' standing in for the two glyphs.
    journalctl() {
        printf '%s\n' \
            '2026-09-30T10:30:00.000+01:00 [gateway] received SIGTERM; restarting' \
            '2026-09-30T10:30:01.000+01:00 [gateway] draining active work before stop with timeout 315000ms: queueSize=2' \
            '2026-09-30T10:30:02.000+01:00 [ws] ~ res ok sessions.list 412ms conn=abc123 id=7' \
            '2026-09-30T10:30:03.000+01:00 [diagnostic] liveness warning: reasons=cpu interval=2s degradedFor=95s eventLoopDelayP99Ms=707.3'
    }

    run __so_gateway_phase openclaw-gateway.service

    [ "$status" -eq 0 ]
    [ "$output" = "draining" ]
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
        case "$*" in
            *"show -p ActiveState"*) printf 'inactive\n' ;;
            *"list-jobs"*) : ;;        # no job: the stop has completed
            *is-active*) return 0 ;;   # xo's pre-stop probe: it WAS running
        esac
        return 0
    }
    __oc_safe_gateway_shutdown() { return 0; }
    __llm_server_running() { return 1; }

    run xo
    [ "$status" -eq 0 ]
    [[ "$output" == *"TERMINATED"* ]]

    # ...and the witness itself must not read a STOP as a return, nor a drain as gone.
    # Measured 2026-10-23: `oc purge` refused because Job=52372 was 'stop running' while
    # is-active printed 'deactivating' and exited 3.  A stop job is the stop we asked for;
    # only a start/restart job, or a still-deactivating unit, keeps the gateway not-gone.
    _oc_state=""
    _oc_job=""
    systemctl() {
        case "$*" in
            *"show -p ActiveState"*) printf '%s\n' "$_oc_state" ;;
            *"list-jobs"*) [[ -n "$_oc_job" ]] && printf '1 openclaw-gateway.service %s running\n' "$_oc_job" ;;
        esac
        return 0
    }
    _oc_state=deactivating
    _oc_job=stop
    run __oc_gateway_gone
    [ "$status" -eq 1 ] || { echo "a deactivating unit must not read as gone"; return 1; }

    _oc_state=inactive
    _oc_job=start
    run __oc_gateway_gone
    [ "$status" -eq 1 ] || { echo "a queued start must block the gone claim"; return 1; }

    _oc_state=inactive
    _oc_job=stop
    __test_port() { return 1; }   # port released
    run __oc_gateway_gone
    [ "$status" -eq 0 ] || { echo "a stop job with the port released IS gone"; return 1; }
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

@test "oc purge: --dry-run names what it would prune and deletes nothing, and the real run prunes exactly those orphan files" {
    # The MUTATION half.  The refusal node above proves "unserving deletes nothing"; this
    # proves the other one — that a purge which DOES land removes exactly the session files
    # no store row names, and that --dry-run removes none.  Both halves are read back from
    # the FILESYSTEM, not from the summary: `[WOULD PRUNE]` and a pruned count are claims,
    # an absent file is the fact.  The fixture stores carry both archive tables and name
    # nothing, so every file here IS an orphan — and the directories themselves survive,
    # because a purge empties sessions/ of unreferenced archives rather than removing it.
    #
    # Hermetic: OC_AGENTS and TAC_CACHE_DIR are fixtures under TAC_TEST_TMPDIR (OC_AGENTS
    # from this test, TAC_CACHE_DIR from setup()), so the path passes the command's own
    # `^(/home|/dev/shm|/tmp)` guard rather than dodging it, and nothing real is touched.
    export __TAC_OPENCLAW_OK=1
    export OC_AGENTS="$TAC_TEST_TMPDIR/agents"
    mkdir -p "$OC_AGENTS/alpha/agent" "$OC_AGENTS/beta/agent" \
        "$OC_AGENTS/alpha/sessions" "$OC_AGENTS/beta/sessions"
    : > "$OC_AGENTS/alpha/sessions/a.jsonl.deleted.1.abcd.zst"
    : > "$OC_AGENTS/beta/sessions/b.jsonl.deleted.1.abcd.zst"
    for _agent in alpha beta
    do
        sqlite3 "$OC_AGENTS/$_agent/agent/openclaw-agent.sqlite" \
            "create table session_transcript_archives(archive_name text);" \
            "create table session_transcript_cold_archives(archive_name text);"
    done
    __oc_safe_gateway_shutdown() { : > "$TAC_TEST_TMPDIR/stopped"; }
    # A PATH stub, not a shell function: the command calls it as `timeout 60 openclaw`,
    # and `timeout` execs a binary, so a function stub would be invisible and the REAL
    # CLI would answer (measured: that is what made this case hang on first run).
    mkdir -p "$TAC_TEST_TMPDIR/bin"
    cat > "$TAC_TEST_TMPDIR/bin/openclaw" <<MOCK
#!/usr/bin/env bash
case "\$1 \${2:-}" in
    "sessions --all-agents")
        if [[ -f "$TAC_TEST_TMPDIR/deleted" ]]; then
            printf '%s\n' '{"count":1,"sessions":[{"key":"agent:alpha:main"}]}'
        else
            printf '%s\n' '{"count":2,"sessions":[{"key":"agent:alpha:scratch"},{"key":"agent:alpha:main"}]}'
        fi ;;
    "sessions delete")
        : > "$TAC_TEST_TMPDIR/deleted"
        printf '%s\n' "\$*" >> "$TAC_TEST_TMPDIR/delete-argv"
        printf '%s\n' '{"ok":true}' ;;
    "gateway call") printf '%s\n' '{"ok":true}' ;;
esac
MOCK
    chmod +x "$TAC_TEST_TMPDIR/bin/openclaw"
    export PATH="$TAC_TEST_TMPDIR/bin:$PATH"

    # 1. --dry-run names both directories and the keys it would delete, deletes NEITHER,
    #    and never stops the gateway: the old code stopped it before deciding it was a
    #    dry run, a side effect the name denies.
    run oc-purge --dry-run

    [ "$status" -eq 0 ]
    [[ "$output" == *"[WOULD PRUNE] $OC_AGENTS/alpha/sessions (files no store row names)"* ]]
    [[ "$output" == *"[WOULD PRUNE] $OC_AGENTS/beta/sessions (files no store row names)"* ]]
    [[ "$output" == *"agent:alpha:main"* ]]
    [[ "$output" == *"[DRY RUN - nothing deleted, gateway untouched]"* ]]
    [ -f "$OC_AGENTS/alpha/sessions/a.jsonl.deleted.1.abcd.zst" ]
    [ -f "$OC_AGENTS/beta/sessions/b.jsonl.deleted.1.abcd.zst" ]
    [ ! -e "$TAC_TEST_TMPDIR/stopped" ]

    # 2. The real run: both unreferenced files are pruned, the store delete is issued, and
    #    the gateway is neither stopped nor started.
    run oc-purge

    [ "$status" -eq 0 ]
    [[ "$output" == *"[2 orphan session file(s) pruned]"* ]]
    [[ "$output" == *"[1 session key(s) deleted]"* ]]
    [[ "$output" == *"[1 main session(s) KEPT"* ]]
    [[ "$output" == *"[store reset, 2 orphan(s) pruned]"* ]]
    # The CLI refuses to delete a main, and one refused key fails the whole batch, so a
    # main must never be SENT: scratch goes, main stays, and the argv proves both.
    grep -qF 'agent:alpha:scratch' "$TAC_TEST_TMPDIR/delete-argv"
    ! grep -qF 'agent:alpha:main' "$TAC_TEST_TMPDIR/delete-argv"
    [ ! -e "$TAC_TEST_TMPDIR/stopped" ]
    [ ! -e "$OC_AGENTS/alpha/sessions/a.jsonl.deleted.1.abcd.zst" ]
    [ ! -e "$OC_AGENTS/beta/sessions/b.jsonl.deleted.1.abcd.zst" ]
    # ...and it did not reach past what it pruned: the session dirs and the agents that
    # own them stay.
    [ -d "$OC_AGENTS/alpha/sessions" ]
    [ -d "$OC_AGENTS/beta/sessions" ]
    [ -d "$OC_AGENTS/alpha" ]
    [ -d "$OC_AGENTS/beta" ]
}

@test "oc purge: a tombstoned session absent from the roster is still deleted" {
    # Measured 2026-10-18: Hal's WhatsApp session was 'failed' in session_windows and
    # appeared in NO `sessions --all-agents` row, so a roster-only purge would leave its
    # poison retry loop running.  This drives the real command and reads the DELETE ARGV
    # back, so it catches a helper that enumerates correctly but is never wired in.
    export __TAC_OPENCLAW_OK=1
    export OC_AGENTS="$TAC_TEST_TMPDIR/agents"
    mkdir -p "$OC_AGENTS/hal/agent" "$OC_AGENTS/hal/sessions"
    sqlite3 "$OC_AGENTS/hal/agent/openclaw-agent.sqlite" \
        "create table session_windows(session_key text);" \
        "insert into session_windows values('agent:hal:whatsapp:direct:+447720061019');"
    __oc_safe_gateway_shutdown() { return 0; }
    __oc_gateway_gone() { return 0; }
    __so_start_gateway() { return 0; }
    mkdir -p "$TAC_TEST_TMPDIR/bin"
    cat > "$TAC_TEST_TMPDIR/bin/openclaw" <<MOCK
#!/usr/bin/env bash
case "\$1 \${2:-}" in
    "sessions --all-agents") printf '%s\n' '{"count":0,"sessions":[]}' ;;
    "sessions delete") printf '%s\n' "\$*" >> "$TAC_TEST_TMPDIR/delete-argv" ;;
    "gateway call") printf '%s\n' '{"ok":true}' ;;
esac
MOCK
    chmod +x "$TAC_TEST_TMPDIR/bin/openclaw"
    export PATH="$TAC_TEST_TMPDIR/bin:$PATH"

    run oc-purge

    [ "$status" -eq 0 ]
    grep -qF 'agent:hal:whatsapp:direct:+447720061019' "$TAC_TEST_TMPDIR/delete-argv"
}

@test "oc purge: a failed step is a NON-ZERO exit, not a zero with a FAILED row" {
    # Measured live 2026-10-19: the purge printed "2 FAILED" and exited 0, so the caller
    # (and the background task's rc) read it as success.  The failure here is the CLI's
    # own non-zero delete; the command must propagate it.
    export __TAC_OPENCLAW_OK=1
    export OC_AGENTS="$TAC_TEST_TMPDIR/agents"
    mkdir -p "$OC_AGENTS/hal/sessions"
    __oc_safe_gateway_shutdown() { return 0; }
    __oc_gateway_gone() { return 0; }
    __so_start_gateway() { return 0; }
    mkdir -p "$TAC_TEST_TMPDIR/bin"
    cat > "$TAC_TEST_TMPDIR/bin/openclaw" <<'MOCK'
#!/usr/bin/env bash
case "$1 ${2:-}" in
    "sessions --all-agents") printf '%s\n' '{"count":0,"sessions":[{"key":"agent:hal:scratch"}]}' ;;
    "sessions delete") printf '%s\n' '{"ok":false}' >&2; exit 1 ;;
    "gateway call") printf '%s\n' '{"ok":true}' ;;
esac
MOCK
    chmod +x "$TAC_TEST_TMPDIR/bin/openclaw"
    export PATH="$TAC_TEST_TMPDIR/bin:$PATH"

    run oc-purge

    [ "$status" -eq 1 ]
    [[ "$output" == *"FAILED to delete store rows"* ]]
}

@test "oc purge: cron sessions are KEPT and the configured main is RESET, not deleted" {
    # Owner's call 2026-10-23: cron is automation state, so its session rows survive a
    # purge; and the one main that must come back empty is reset through the gateway
    # (sessions.patch then sessions.reset), because `sessions delete` refuses a main.
    # The read-back must ignore the cron row it deliberately kept, or a correct purge
    # reports failure.  Assertions are the DELETE argv and the RPC argv (what was asked),
    # plus the store state the mock's reset leaves.
    export __TAC_OPENCLAW_OK=1
    export OC_PURGE_RESET_MAIN=hal
    export OC_AGENTS="$TAC_TEST_TMPDIR/agents"
    mkdir -p "$OC_AGENTS/hal/sessions" "$OC_AGENTS/hal/agent"
    sqlite3 "$OC_AGENTS/hal/agent/openclaw-agent.sqlite" \
        "create table session_nodes(session_key text, current_session_id text, entry_json text);" \
        "create table session_windows(session_key text, session_id text);" \
        "insert into session_nodes values('agent:hal:main','sid-1','{\"sessionId\":\"sid-1\"}');" \
        "insert into session_windows values('agent:hal:main','sid-1');"
    __oc_safe_gateway_shutdown() { return 0; }
    __oc_gateway_gone() { return 0; }
    __so_start_gateway() { return 0; }
    mkdir -p "$TAC_TEST_TMPDIR/bin"
    cat > "$TAC_TEST_TMPDIR/bin/openclaw" <<MOCK
#!/usr/bin/env bash
case "\$1 \${2:-}" in
    "sessions --all-agents")
        if [[ -f "$TAC_TEST_TMPDIR/deleted" ]]; then
            printf '%s\n' '{"count":2,"sessions":[{"key":"agent:hal:main"},{"key":"agent:hal:cron:abc"}]}'
        else
            printf '%s\n' '{"count":3,"sessions":[{"key":"agent:hal:scratch"},{"key":"agent:hal:main"},{"key":"agent:hal:cron:abc"}]}'
        fi ;;
    "sessions delete")
        : > "$TAC_TEST_TMPDIR/deleted"
        printf '%s\n' "\$*" >> "$TAC_TEST_TMPDIR/delete-argv"
        printf '%s\n' '{"ok":true}' ;;
    "gateway call")
        printf '%s\n' "\$*" >> "$TAC_TEST_TMPDIR/rpc-argv"
        # Enforce the RPC's own schema, not a permissive one: measured live 2026-10-23,
        # sessions.reset rejects {"sessionKey":...} with "must have required property
        # 'key'".  A double that accepts any shape cannot fail on a wrong param name.
        if [[ "\${3:-}" == sessions.reset || "\${3:-}" == sessions.patch ]]
        then
            jq -e 'has("key") and (has("sessionKey")|not) and has("expectedSessionId")' \
                <<<"\${5:-}" >/dev/null 2>&1 \
                || { printf '%s\n' '{"ok":false,"error":{"message":"invalid params"}}'; exit 1; }
        fi
        sqlite3 "$OC_AGENTS/hal/agent/openclaw-agent.sqlite" \
            "update session_nodes set entry_json='{\"sessionId\":\"sid-2\"}' where session_key='agent:hal:main';"
        printf '%s\n' '{"ok":true}' ;;
esac
MOCK
    chmod +x "$TAC_TEST_TMPDIR/bin/openclaw"
    export PATH="$TAC_TEST_TMPDIR/bin:$PATH"

    run oc-purge

    [ "$status" -eq 0 ]
    grep -qF 'agent:hal:scratch' "$TAC_TEST_TMPDIR/delete-argv"
    ! grep -qF 'agent:hal:cron:abc' "$TAC_TEST_TMPDIR/delete-argv"
    ! grep -qF 'agent:hal:main' "$TAC_TEST_TMPDIR/delete-argv"
    grep -qF 'sessions.reset' "$TAC_TEST_TMPDIR/rpc-argv"
    grep -qF 'agent:hal:main' "$TAC_TEST_TMPDIR/rpc-argv"
    # The RPC's own contract, not ours: measured live 2026-10-23, sessions.reset rejected
    # {"sessionKey":...} with "must have required property 'key'".  A mock that accepts any
    # shape cannot catch that, so the param NAME is asserted here.
    grep -qF '"key":"agent:hal:main"' "$TAC_TEST_TMPDIR/rpc-argv" \
        || { echo "sessions.reset needs the param named 'key'"; return 1; }
    ! grep -qF 'sessionKey' "$TAC_TEST_TMPDIR/rpc-argv" \
        || { echo "sessions.reset rejects 'sessionKey'"; return 1; }
    [[ "$output" == *"[1 cron session(s) KEPT"* ]]
    [[ "$output" == *"[agent:hal:main reset"* ]]
}

@test "oc purge: a main whose tombstone names a missing successor is REPAIRED" {
    # The delete above can create this shape: a rollover successor is an ordinary
    # non-main key, so purging it leaves the main's tombstone pointing at nothing, and
    # recovery then refuses ("Session recovery state is incomplete").  The repair is the
    # documented patch+reset pair; archivedAt forces the patch arm.
    export __TAC_OPENCLAW_OK=1
    export OC_PURGE_RESET_MAIN=""
    export OC_AGENTS="$TAC_TEST_TMPDIR/agents"
    mkdir -p "$OC_AGENTS/finn/sessions" "$OC_AGENTS/finn/agent"
    sqlite3 "$OC_AGENTS/finn/agent/openclaw-agent.sqlite" \
        "create table session_nodes(session_key text, current_session_id text, entry_json text);" \
        "create table session_windows(session_key text, session_id text);" \
        "insert into session_nodes values('agent:finn:main','sid-1','{\"sessionId\":\"sid-1\",\"archivedAt\":1792745580110,\"mainRestartRecovery\":{\"tombstone\":{\"recoveredSessionKey\":\"agent:finn:dashboard:dead\",\"recoveredSessionId\":\"dead-id\"}}}');" \
        "insert into session_windows values('agent:finn:main','sid-1');"
    __oc_safe_gateway_shutdown() { return 0; }
    __oc_gateway_gone() { return 0; }
    __so_start_gateway() { return 0; }
    mkdir -p "$TAC_TEST_TMPDIR/bin"
    cat > "$TAC_TEST_TMPDIR/bin/openclaw" <<MOCK
#!/usr/bin/env bash
case "\$1 \${2:-}" in
    "sessions --all-agents") printf '%s\n' '{"count":1,"sessions":[{"key":"agent:finn:main"}]}' ;;
    "gateway call")
        printf '%s\n' "\$*" >> "$TAC_TEST_TMPDIR/rpc-argv"
        # Same schema check as the cron/reset double: the repair pair must send `key`.
        if [[ "\${3:-}" == sessions.reset || "\${3:-}" == sessions.patch ]]
        then
            jq -e 'has("key") and (has("sessionKey")|not) and has("expectedSessionId")' \
                <<<"\${5:-}" >/dev/null 2>&1 \
                || { printf '%s\n' '{"ok":false,"error":{"message":"invalid params"}}'; exit 1; }
        fi
        case "\${3:-}" in
            sessions.patch|sessions.reset)
                sqlite3 "$OC_AGENTS/finn/agent/openclaw-agent.sqlite" \
                    "update session_nodes set entry_json='{\"sessionId\":\"sid-2\"}' where session_key='agent:finn:main';" ;;
        esac
        printf '%s\n' '{"ok":true}' ;;
esac
MOCK
    chmod +x "$TAC_TEST_TMPDIR/bin/openclaw"
    export PATH="$TAC_TEST_TMPDIR/bin:$PATH"

    run oc-purge

    [ "$status" -eq 0 ]
    grep -qF 'sessions.patch' "$TAC_TEST_TMPDIR/rpc-argv"
    grep -qF '"archived":false' "$TAC_TEST_TMPDIR/rpc-argv"
    grep -qF 'sessions.reset' "$TAC_TEST_TMPDIR/rpc-argv"
    [[ "$output" == *"repaired - tombstone pointed at missing agent:finn:dashboard:dead"* ]]
    [[ "$output" == *"1 tombstone(s) repaired"* ]]
}

@test "oc purge: ONLINE on the port is not proof the RPC answers — nothing is deleted" {
    # A purge deletes state and the delete runs over RPC, so an unserving gateway must
    # REFUSE rather than delete into a store nothing answers for.  `ensure_serving` is the
    # seam: the refusal is taken before any store read, so `sessions delete` must never be
    # reached.  (That the port alone is not the serving witness is pinned by the two
    # ensure_serving cases below.)
    export __TAC_OPENCLAW_OK=1
    export OC_AGENTS="$TAC_TEST_TMPDIR/agents"
    mkdir -p "$OC_AGENTS/alpha/sessions"
    : > "$OC_AGENTS/alpha/sessions/a.json"
    __oc_purge_ensure_serving() { return 1; }
    mkdir -p "$TAC_TEST_TMPDIR/bin"
    cat > "$TAC_TEST_TMPDIR/bin/openclaw" <<'MOCK'
#!/usr/bin/env bash
case "$1 ${2:-}" in
    "sessions --all-agents") printf '%s\n' '{"count":1,"sessions":[{"key":"agent:alpha:scratch"}]}' ;;
    "sessions delete") : > "$TAC_TEST_TMPDIR/delete-asked"; printf '%s\n' '{"ok":true}' ;;
    "gateway call") printf '%s\n' '{"ok":true}' ;;
esac
MOCK
    chmod +x "$TAC_TEST_TMPDIR/bin/openclaw"
    export PATH="$TAC_TEST_TMPDIR/bin:$PATH"

    run oc-purge

    [ "$status" -eq 1 ]
    [[ "$output" == *"REFUSED - the gateway is not serving"* ]]
    [ ! -e "$TAC_TEST_TMPDIR/delete-asked" ] \
        || { echo "a gateway that is not serving must not reach sessions delete"; return 1; }
}

@test "xo: a gateway stop that ignores TERM is KILLED, not waited out" {
    # Measured 2026-10-18: `openclaw gateway stop` ignores SIGTERM, so `timeout 30` sent
    # TERM, was ignored, and waited forever — the live purge hung inside it until the
    # child was killed by hand.  The wrapper now escalates with `-k`; this pins the
    # escalation through the budget seam, with a stub that traps TERM.
    export OC_GATEWAY_STOP_BUDGET_S=1
    export OC_ROOT="$TAC_TEST_TMPDIR/oc"
    mkdir -p "$OC_ROOT" "$TAC_TEST_TMPDIR/bin"
    cat > "$TAC_TEST_TMPDIR/bin/openclaw" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "openclaw \$*" >> "$TAC_TEST_TMPDIR/order"
trap '' TERM
exec sleep 60
MOCK
    chmod +x "$TAC_TEST_TMPDIR/bin/openclaw"
    # `systemctl` must be a PATH stub too: the function calls it as `timeout 60
    # systemctl …`, and `timeout` execs a binary — a shell-function stub is invisible
    # there, so the first version of this case ran the REAL stop against the live gateway.
    # It answers `show -p ActiveState` with `active`, which is what makes the CLI stop a
    # FALLBACK rather than the first move (systemd owns the stop in the normal path).
    cat > "$TAC_TEST_TMPDIR/bin/systemctl" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "systemctl \$*" >> "$TAC_TEST_TMPDIR/order"
case "\$*" in
    *"show -p ActiveState"*) printf 'active\n' ;;
esac
exit 0
MOCK
    chmod +x "$TAC_TEST_TMPDIR/bin/systemctl"
    export PATH="$TAC_TEST_TMPDIR/bin:$PATH"
    __oc_gateway_databases_closed() { return 0; }

    local _t0 _elapsed
    _t0=$(date +%s)
    run __oc_safe_gateway_shutdown
    _elapsed=$(( $(date +%s) - _t0 ))

    (( _elapsed < 20 )) || { echo "waited ${_elapsed}s past a TERM-ignoring stop"; return 1; }
    [[ "$output" == *"past its 1s budget"* ]]
    # Order matters: systemd is asked first, because an explicit systemd stop is what
    # suppresses Restart=always.  A CLI-first stop kills the process outside a stop job
    # and the unit comes straight back (measured 2026-10-23).
    head -1 "$TAC_TEST_TMPDIR/order" | grep -qF 'systemctl --user stop'
}

# ---------------------------------------------------------------------------
# so: the daemon guard patch row (card SELFHEAL-GUARD-DELIVERY-001)
#
# Every IDE-companion update replaces the guard chunk and reverts the local patch, and
# on 2026-09-27 the cron self-heal detected exactly that for fifteen hours without
# repairing it — its report went to a log nobody reads, on a box with no mail transport
# at all. So the state also goes on `so`, the command the operator runs to ask "is this
# box up?". The acceptance is two-sided: with the patch reverted `so` shows it, and with
# it applied `so` stays quiet — an [APPLIED] row on every healthy start would be noise,
# and a silent reversion is precisely the "quiet unless stale" case.
#
# Hermetic: the patcher is a stub in a sandbox HOME, so the real
# ~/.local/bin/qwen-guard-patch.sh is never executed.
# ---------------------------------------------------------------------------
__stub_guard_patcher() {   # $1 = the --check exit code
    export HOME="$TAC_TEST_TMPDIR/home"
    mkdir -p "$HOME/.local/bin"
    cat > "$HOME/.local/bin/qwen-guard-patch.sh" <<MOCK
#!/usr/bin/env bash
echo "  ok       daemon-git-worktree-guard-STUB.js"
exit $1
MOCK
    chmod +x "$HOME/.local/bin/qwen-guard-patch.sh"
}

# The already-running, all-green path: the port answers, the gateway is healthy and the
# LLM is up, so `so` prints its success rows and returns. That early return is where the
# operator sees nothing wrong — the whole point of adding the row there.
__so_healthy_prelude() {
    export __TAC_OPENCLAW_OK=1
    mkdir -p "$TAC_TEST_TMPDIR/oc"
    export OC_ROOT="$TAC_TEST_TMPDIR/oc"
    __test_port() { return 0; }
    __llm_server_running() { return 0; }
    __so_health_gate() { return 0; }
    __so_ensure_shell_env() { return 0; }
}

@test "so: a reverted daemon guard patch is shown on the status output" {
    __so_healthy_prelude
    __stub_guard_patcher 1     # --check fails: the patch is missing/reverted

    run so

    [ "$status" -eq 0 ]
    [[ "$output" == *"Local LLM"* ]]
    [[ "$output" == *"Daemon guard patch"* ]]
    [[ "$output" == *"[NOT APPLIED]"* ]]
}

@test "so: a healthy daemon guard patch stays off the status output" {
    __so_healthy_prelude
    __stub_guard_patcher 0     # --check passes: the patch is applied

    run so

    [ "$status" -eq 0 ]
    [[ "$output" == *"Local LLM"* ]]
    # Quiet when there is nothing to act on — the row must not become noise.
    [[ "$output" != *"Daemon guard patch"* ]]
}

@test "so: a box with no local guard patcher stays quiet too" {
    __so_healthy_prelude
    export HOME="$TAC_TEST_TMPDIR/home"   # sandbox HOME, with no patcher in it
    mkdir -p "$HOME"

    run so

    [ "$status" -eq 0 ]
    [[ "$output" == *"Local LLM"* ]]
    [[ "$output" != *"Daemon guard patch"* ]]
}

@test "so: a start refused by the state-DB guard is named at once, not spun out" {
    # Measured 2026-10-18 (20:52-22:13 BST): openclaw.sqlite was sealed in offline
    # maintenance by an interrupted drain, and seven starts were refused over 31
    # minutes.  `so` discarded the CLI's own refusal text (> /dev/null 2>&1) — the only
    # place the cause is named — then waited its full 300 s budget and printed FAILED.
    # Catches: spending the budget on a refusal, and reporting it without the cause.
    openclaw() {
        local _refusal="OpenClaw state at /tmp/openclaw.sqlite is undergoing"
        _refusal+=" offline maintenance; retry when it finishes."
        printf '%s\n' "$_refusal" >&2
        return 1
    }
    __test_port() { return 1; }

    local _t0 _elapsed _status=0
    _t0=$(date +%s)
    __so_start_gateway openclaw-gateway.service > "$TAC_TEST_TMPDIR/refusal.out" 2>&1 \
        || _status=$?
    _elapsed=$(( $(date +%s) - _t0 ))

    [ "$_status" -eq 1 ] || { echo "a refused start must fail"; return 1; }
    (( _elapsed < 10 )) || { echo "waited ${_elapsed}s through a refusal"; return 1; }
    grep -q "REFUSED" "$TAC_TEST_TMPDIR/refusal.out"
    grep -q "Do not re-run 'so'" "$TAC_TEST_TMPDIR/refusal.out"
}

@test "so: a unit refused in the journal stops the wait even when the CLI returned 0" {
    # The other half: `openclaw gateway start` succeeds (or says nothing) and the UNIT
    # refuses at admission.  The watch must read THIS attempt's window, so a marker
    # left by an earlier boot cannot decide a healthy start.
    openclaw() { return 0; }
    # The read this attempt makes must carry the refusal; every other journalctl
    # call in the module must stay empty, so the window is matched explicitly.
    journalctl() {
        case " $* " in
            *" --since @"*)
                local _refusal="[openclaw] Reason: OpenClaw state is undergoing"
                _refusal+=" offline maintenance; retry when it finishes."
                printf '%s\n' "$_refusal" ;;
        esac
        return 0
    }
    __test_port() { return 1; }

    local _t0 _elapsed _status=0
    _t0=$(date +%s)
    __so_start_gateway openclaw-gateway.service > "$TAC_TEST_TMPDIR/journal.out" 2>&1 \
        || _status=$?
    _elapsed=$(( $(date +%s) - _t0 ))

    [ "$_status" -eq 1 ] || { echo "a journal refusal must fail the start"; return 1; }
    (( _elapsed < 30 )) || { echo "waited ${_elapsed}s past a journal refusal"; return 1; }
    grep -q "REFUSED" "$TAC_TEST_TMPDIR/journal.out"
}

@test "oc purge: a serving gateway is never stopped or restarted" {
    # The whole point of option (a): the delete and the reset run over RPC through a
    # SERVING gateway, and the old stop/start bought nothing but an outage.  A gateway
    # that already answers must be left alone — asserted by the absence of BOTH calls,
    # because a stop followed by a start would also end "serving".
    export __TAC_OPENCLAW_OK=1
    export OC_AGENTS="$TAC_TEST_TMPDIR/agents"
    mkdir -p "$OC_AGENTS/alpha/sessions"
    __oc_purge_ensure_serving() { return 0; }      # it already serves
    __oc_safe_gateway_shutdown() { : > "$TAC_TEST_TMPDIR/stopped"; }
    __so_start_gateway() { : > "$TAC_TEST_TMPDIR/started"; return 0; }
    mkdir -p "$TAC_TEST_TMPDIR/bin"
    cat > "$TAC_TEST_TMPDIR/bin/openclaw" <<'MOCK'
#!/usr/bin/env bash
case "$1 ${2:-}" in
    "sessions --all-agents") printf '%s\n' '{"count":0,"sessions":[]}' ;;
    "gateway call") printf '%s\n' '{"ok":true}' ;;
esac
MOCK
    chmod +x "$TAC_TEST_TMPDIR/bin/openclaw"
    export PATH="$TAC_TEST_TMPDIR/bin:$PATH"

    run oc-purge

    [ "$status" -eq 0 ]
    [ ! -e "$TAC_TEST_TMPDIR/stopped" ] || { echo "a serving gateway must never be stopped"; return 1; }
    [ ! -e "$TAC_TEST_TMPDIR/started" ] || { echo "a serving gateway must never be restarted"; return 1; }
    [[ "$output" == *"[store reset, 0 orphan(s) pruned]"* ]]
}

@test "oc purge: a gateway that is not serving is STARTED, never stopped" {
    # The other side of the same rule: when the short probe gets no answer, the purge
    # STARTS the unit (the delete runs over RPC) and must not stop it first.  The wait is
    # stateful on purpose — call 1 is the probe, call 2 is the post-start wait — so a
    # helper that ignores the start and reuses its own failure is caught.
    #
    # This case is about the REAL helper, which setup() replaces with a "serving" stub, so
    # both halves of that stub have to be cleared — the function AND 09c's include guard,
    # without which re-sourcing is a no-op that leaves the stub in place.
    unset -f __oc_purge_ensure_serving
    unset __TAC_MOD_09C_OC_CORE_LOADED
    source "$REPO_ROOT/scripts/09c-oc-core.sh"
    __oc_safe_gateway_shutdown() { : > "$TAC_TEST_TMPDIR/stopped"; }
    __so_start_gateway() { : > "$TAC_TEST_TMPDIR/started"; return 0; }
    local _probes=0
    __oc_purge_wait_rpc() {
        _probes=$(( _probes + 1 ))
        (( _probes >= 2 ))
    }

    run __oc_purge_ensure_serving

    [ "$status" -eq 0 ]
    [ -e "$TAC_TEST_TMPDIR/started" ] || { echo "an unserving gateway must be started"; return 1; }
    [ ! -e "$TAC_TEST_TMPDIR/stopped" ] || { echo "an unserving gateway must never be stopped"; return 1; }
    [[ "$output" == *"STARTING - the store delete runs over RPC"* ]]
}

@test "oc purge: only session files no store row names are pruned" {
    # sessions/ holds the archives `sessions delete` wrote, and each is named by an
    # archive_name row in the agent's own store.  A blanket clear ORPHANS those rows
    # (measured 2026-10-23: `del` had one row and no file), so the prune must keep every
    # file a row names — and never walk cold/, whose rows are why that directory exists.
    export OC_AGENTS="$TAC_TEST_TMPDIR/agents"
    mkdir -p "$OC_AGENTS/alpha/agent" "$OC_AGENTS/alpha/sessions/cold"
    : > "$OC_AGENTS/alpha/agent/openclaw-agent.sqlite"
    : > "$OC_AGENTS/alpha/sessions/kept.zst"
    : > "$OC_AGENTS/alpha/sessions/orphan.zst"
    : > "$OC_AGENTS/alpha/sessions/cold/deep.zst"
    __oc_purge_store_read() {
        case "$2" in
            *"archive_name='kept.zst'"*) printf 'kept.zst\n' ;;
            *) : ;;
        esac
    }

    run __oc_purge_prune_orphans

    [ "$status" -eq 0 ]
    [ "$output" = "1" ] || { echo "expected exactly one prune, got: $output"; return 1; }
    [ -f "$OC_AGENTS/alpha/sessions/kept.zst" ] \
        || { echo "a file a store row names must survive"; return 1; }
    [ ! -e "$OC_AGENTS/alpha/sessions/orphan.zst" ] \
        || { echo "a file no store row names must be pruned"; return 1; }
    [ -f "$OC_AGENTS/alpha/sessions/cold/deep.zst" ] \
        || { echo "cold/ must never be walked"; return 1; }
}

@test "oc purge: a gateway that answers RPC only after a cold start is WAITED for, not refused" {
    # Measured live 2026-10-23: a restart took 38.1 s to log `http server listening`, while
    # one probe with the CLI's 10 s default refused a healthy-but-starting gateway.  One
    # sample is not a wait: the serving witness must poll until `ok:true`, say that it is
    # waiting, and succeed on the ANSWER rather than on the first attempt.
    export OC_PURGE_HEALTH_S=30
    export OC_PURGE_HEALTH_STEP_S=1
    export OC_PURGE_PROGRESS_S=1
    mkdir -p "$TAC_TEST_TMPDIR/bin"
    cat > "$TAC_TEST_TMPDIR/bin/openclaw" <<'MOCK'
#!/usr/bin/env bash
case "$1 ${2:-}" in
    "gateway call")
        n=$(cat "$TAC_TEST_TMPDIR/health-calls" 2>/dev/null || echo 0)
        n=$(( n + 1 )); printf '%s\n' "$n" > "$TAC_TEST_TMPDIR/health-calls"
        if (( n < 3 )); then printf '%s\n' '{"ok":false,"error":{"message":"gateway timeout after 10000ms"}}'
        else printf '%s\n' '{"ok":true}'; fi
        exit 0 ;;
esac
MOCK
    chmod +x "$TAC_TEST_TMPDIR/bin/openclaw"
    export PATH="$TAC_TEST_TMPDIR/bin:$PATH"

    run __oc_purge_wait_rpc

    [ "$status" -eq 0 ] || { echo "a gateway that answers late must not be refused"; return 1; }
    [ "$(cat "$TAC_TEST_TMPDIR/health-calls")" -ge 3 ] \
        || { echo "health must be polled, not sampled once"; return 1; }
    [[ "$output" == *"not answering RPC yet"* ]] \
        || { echo "the wait must say it is waiting"; return 1; }
}

# end of file
