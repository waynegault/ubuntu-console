# shellcheck shell=bash
# --- Module: 09c-oc-core ---
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 36
#   v36 (2026-10-24): `xo` WAITS for the stop instead of sampling it once — measured live,
#   it read the unit as `activating` while its own stop sat queued behind an auto-restart,
#   printed "the stop did not take" and exited 1, and the unit was `inactive` 30 s later.
#   `__oc_wait_gateway_gone` (09a) is bounded by the unit's own TimeoutStopUSec and prints
#   its progress; the [NOT RUNNING] row is now a read-back too, not an echo of the pre-stop
#   probe (a start job can land between the two).
# Module Version: 35
#   v35 (2026-10-24): the purge resets EVERY agent's main, not only the configured one
#   (owner's call: "both"), and it narrates its three slow phases — enumeration+delete,
#   reset, prune — because ~2-3 minutes of silence read as a freeze.  `OC_PURGE_RESET_MAIN`
#   still narrows the reset to one agent when set; unset/`all` means every main.
# Module Version: 34
#   v34 (2026-10-23): `xo` names the fleet lanes still running after it stops the owned LLM.
#   `model stop` protects lanes by design, so "[STOPPED]" was true of one server and read as
#   the whole box; the lanes are now reported, never stopped here.
# Module Version: 33
#   v33 (2026-10-23): `oc purge` NEVER stops or restarts the gateway.  Its sessions/ holds
#   only the archives `sessions delete` wrote, each named by an `archive_name` row, so the
#   blanket clear ORPHANED those rows — measured: hal/finn/juno each held one file matching
#   one row, while `del` held zero files and one row.  The stop/start is gone (the delete
#   and the reset run over RPC), a SERVING gateway is required before anything is deleted
#   and started only when it does not answer, and the clear is an ORPHAN-ONLY prune that
#   keeps cold/ and keeps any file whose store cannot be read.
# Module Version: 32
#   v32 (2026-10-23): the purge WAITS for the restarted gateway to answer RPC instead of
#   sampling it once.  Measured live: a restart took 38.1 s to log `http server listening`,
#   but step 4b probed once with the CLI's 10 s default and refused a gateway that was
#   still starting ("gateway timeout after 10000ms") — after the session dirs had already
#   been cleared.  The wait is bounded (OC_PURGE_HEALTH_S, default 300 s, polled every
#   OC_PURGE_HEALTH_STEP_S) and prints progress; its refusal names the partial state.
# Module Version: 31
#   v32 (2026-10-23): the purge REFUSES before it stops a gateway whose own last shutdown
#   did not complete.  Read from the journal: every one of today's four stops settled its
#   work drain in <=20 s and then sat in `shutdown.gateway-close` past TimeoutStopUSec with
#   close steps still pending, so systemd SIGKILLed it, the state DB stayed in offline
#   maintenance and the next start was refused — a purge would have left the gateway DOWN
#   with the session dirs already cleared (step 2 runs before the start).  The self-kill
#   bound is also derived from the unit's TimeoutStopUSec (+10 s), not a flat 120 s, which
#   fired 210 s INSIDE the budget the unit was given for a drain doing real work.
# Module Version: 30
#   v30 (2026-10-23): a shutdown that overruns is KILLED and held down instead of being
#   fought poll-by-poll: live, the drain hung ~5 min, systemd SIGKILLed it, Restart=always
#   brought it back, and the loop spent the rest of the bound replacing starts.  The
#   replacement line is also throttled — unthrottled it printed every second and buried the
#   progress rows.
# Module Version: 29
#   v29 (2026-10-23): the reset/patch params use `key`, not `sessionKey`.  Measured live:
#   sessions.reset rejected {"sessionKey":...} with "must have required property 'key'".
#   The witness asserts the param NAME, because a mock that accepts any shape proves nothing.
# Module Version: 28
#   v28 (2026-10-23): the restart replacement uses `systemctl stop --no-block`, not
#   `--job-mode=replace`.  Measured: the latter blocked 30 s (rc=124) behind the pending
#   auto-restart and changed nothing, so every poll stalled and the purge looked frozen.
# Module Version: 27
#   v27 (2026-10-23): the replacement prints systemctl's OWN refusal.  Live, the loop
#   printed only "refused" every poll, which is undiagnosable; a discarded diagnostic
#   stream is the defect, so the helper captures it and the caller no longer prints a
#   second generic line.
# Module Version: 26
#   v26 (2026-10-23): the gone-wait prints its state and time left every 15 s.  A live run
#   sat silent for minutes and read as "frozen"; silence is not progress.  The interval is
#   a seam (OC_PURGE_PROGRESS_S) so the witness does not sleep.
# Module Version: 25
#   v25 (2026-10-23): the purge's wait now REPLACES a queued restart while it waits.  The
#   loop used to only observe, so a `Restart=always` start (queued when systemd SIGKILLs a
#   unit that overran TimeoutStopUSec) always won and the purge always refused.  The
#   refusal message also names the real bound (it still said 120 after the bound became 360).
# Module Version: 24
#   v24 (2026-10-23): purge proves the gateway ANSWERS RPC before touching the store.
#   Measured live: __so_start_gateway printed ONLINE (port 18789) and every openclaw call
#   then timed out at 30 s, so `sessions delete` could not land and the purge reported a
#   FAILED store with the rows still there.  A port is not a server.
# Module Version: 23
#   v23 (2026-10-23): the purge's gone-wait bound is 360 s, not 120 — the unit's own
#   TimeoutStopUSec is 5min 30s, and a normal drain (queueSize=6, agentRuns=3) was
#   refused at 120 s.  `__oc_gateway_gone` no longer reads our own stop job as a return.
# Module Version: 22
#   v22 (2026-10-23): `oc purge` now names the three things it used to overstate.  CRON
#   sessions are KEPT (Wayne, 2026-10-23) and counted, so the roster read-back ignores them
#   or every purge would fail over rows it deliberately kept.  Each agent's MAIN is kept, and
#   the configured one (OC_PURGE_RESET_MAIN, default hal) is RESET through the gateway RPC
#   (`sessions.patch {archived:false}` then `sessions.reset`, both with expectedSessionId) so
#   it comes back empty — `sessions delete` refuses a main.  A main whose recovery tombstone
#   points at a successor the store no longer holds is REPAIRED the same way; purge deletes
#   that successor class, so without this it would manufacture the tombstone it leaves behind.
#   Read-backs are from the store (archivedAt and mainRestartRecovery gone), never the RPC's
#   own ok.  Bounded CLI calls carry `-k` because the CLI ignores SIGTERM.
# Module Version: 21
#   v21 (2026-10-18): the purge's `timeout … openclaw` calls carry `-k` (10 s for a read,
#   15 s for the delete).  The CLI ignores SIGTERM — measured on `gateway stop` — so a
#   plain timeout could wait forever on a hung CLI.
# Module Version: 20
#   v20 (2026-10-18): a purge with any failed step exits NON-ZERO.  The live run printed
#   "2 FAILED" and returned 0, so the caller could not tell that it had failed.
# Module Version: 19
#   v19 (2026-10-18): a sessions dir with NO cold/ is still removed whole.  The cold/
#   guard must not leave an empty sessions/ behind, which would make the directory purge
#   a no-op on every agent that has no cold archive.
# Module Version: 18
#   v18 (2026-10-18): the session-dir purge KEEPS `cold/`, because the store holds a row
#   per cold archive.  Measured: 110 rows pointed at files already removed by earlier
#   purges, and the usage-cost refresh failed on every one.  Rows are deleted through
#   the CLI; the files they name must outlive the pass that clears the directories.
# Module Version: 17
#   v17 (2026-10-18): `oc purge` never sends a MAIN session to `sessions delete`.
#   Measured live: the CLI refuses it ("Cannot delete the main session"), and one
#   refused key fails the whole batch — so the first live purge deleted the non-main
#   sessions but reported the store delete as FAILED.  Mains are now counted and
#   reported as KEPT ("use /reset in that chat"), the batch carries only non-main keys,
#   and the roster read-back counts non-main rows so a correct purge is not a failure.
# Module Version: 16
#   v16 (2026-10-18): `oc purge` resets the session STORES, not just the directories.
#   Measured: 47 sessions across 14 agents lived in agent/openclaw-agent.sqlite while the
#   deleted dirs held two archives; a tombstoned WhatsApp session ('failed', absent from
#   the roster) kept a poison retry loop, and a missing cold archive broke the usage-cost
#   refresh on every pass.  It now deletes every stored session (main included) through
#   `sessions delete`, restarts the gateway, and reads the roster back; --dry-run no
#   longer stops the gateway.
# Module Version: 15
# ==============================================================================
# 09c-oc-core
# ==============================================================================
# @modular-section: openclaw
# @depends: constants, design-tokens, ui-engine, hooks, oc-gateway
# @uses: llm-runtime
# @exports: xo, oc, oc-restart, ocstart, ocstop, oc-purge

# Globals assigned by sibling modules at source time, named here instead of
# relying on a file-wide `disable=SC2154` (removed 2026-09-15): shellcheck lints
# each module in isolation and cannot see an assignment made elsewhere, so the
# module declares what it consumes.
#   colours — 03-design-tokens.sh (as `readonly`)
# `:=` assigns ONLY when the variable is unset, so this is a runtime no-op and is
# safe against the `readonly` in 03 (a plain C_Dim="$C_Dim" would abort).
: "${C_Reset:=}"
: "${C_Dim:=}"
: "${C_Error:=}"
: "${C_Success:=}"
: "${C_Highlight:=}"

# Idempotent include guard: sub-modules are sourced both by their thin
# loader and directly by the profile/env loaders, so run the body once.
[[ -n "${__TAC_MOD_09C_OC_CORE_LOADED:-}" ]] && return 0
__TAC_MOD_09C_OC_CORE_LOADED=1

function xo() {
    if [[ "$__TAC_OPENCLAW_OK" != "1" ]]; then
        __tac_info "OpenClaw" "[NOT INSTALLED - cannot stop gateway]" "$C_Error"
        return 1
    fi
    local _svc="openclaw-gateway.service"
    local _was_running=0

    # Hint for AI agents: xo stops but does not restart.
    if [[ -n "${OPENCLAW_AGENT_ID:-}" || -n "${AGENT_MODE:-}" ]]; then
        printf '%s\n' "${C_Warning:-}⚠ xo only stops the gateway. To restart, run: openclaw gateway restart${C_Reset}"
    fi

    # Check if anything is actually running before we try to stop
    if systemctl --user is-active --quiet "$_svc" 2>/dev/null \
        || __test_port "$OC_PORT"
    then
        _was_running=1
    fi

    __oc_safe_gateway_shutdown

    # Also stop the LLM server if running — it holds GPU VRAM and doesn't
    # auto-die with the gateway. Otherwise a subsequent process (e.g.
    # investigator ingest) finds only ~150 MB free and fails to load its
    # embedder.
    if __llm_server_running; then
        printf '%s\n' "${C_Dim}Stopping LLM server ...${C_Reset}"
        if ! halt 2>/dev/null; then
            printf '%s\n' "${C_Dim}LLM stop did not land; it may still hold VRAM${C_Reset}"
        fi
    fi

    # The fleet lanes are PROTECTED from `model stop` by design (the watchdog owns them), so
    # name the ones still serving: otherwise "Llama Server [STOPPED]" reads as a whole-box
    # stop while four lanes keep their ports.  Reporting only; stopping them needs the
    # suspend marker and is the operator's call.
    local _lane _lane_state _lanes_up=0
    while read -r _lane _lane_state
    do
        [[ -n "$_lane" ]] || continue
        _lanes_up=$(( _lanes_up + 1 ))
        __tac_info "Llama lane" "[RUNNING — $_lane ($_lane_state)]" "$C_Warning"
    done < <(__llm_lane_rows)
    if (( _lanes_up == 0 ))
    then
        __tac_info "Llama lane" "[none running]" "$C_Dim"
    fi

    if (( _was_running ))
    then
        # The stop is claimed only after it is read back — and the read-back is WAITED for,
        # not sampled once: the stop is queued with --no-block and the unit's own drain
        # budget is TimeoutStopUSec, so a single early read calls an ordinary stop a failure
        # (measured 2026-10-24 19:05 BST: "[STILL RUNNING — the stop did not take]" while the
        # stop sat queued behind an auto-restart; the unit was `inactive` 30 s later and the
        # next run found nothing running).  __oc_wait_gateway_gone is in 09a.
        local _settle=""
        # Nothing was up when xo started, so there is no drain to wait out — only the stop
        # just signalled needs to settle.  A port held by an UNMANAGED process is never
        # going to clear, so it must not cost the drain-sized bound.
        (( _was_running )) || _settle="${OC_XO_SETTLE_S:-30}"
        if __oc_wait_gateway_gone "$_settle"
        then
            __tac_info "Gateway Processes" "[TERMINATED]" "$C_Error"
        else
            __tac_info "Gateway Processes" "[STILL RUNNING — the stop did not take]" "$C_Error"
            return 1
        fi
    else
        # The [NOT RUNNING] row is a READ-BACK too, not an echo of the probe above: a start
        # job can land between that probe and the stop (measured 2026-10-24 19:06:57 BST,
        # openclaw-gateway-guard started the unit a moment after xo's own probe), and the
        # shutdown then signals it — so what is true afterwards is what must be printed.
        if __oc_wait_gateway_gone "${OC_XO_SETTLE_S:-30}"
        then
            __tac_info "Gateway" "[NOT RUNNING]" "$C_Dim"
        else
            __tac_info "Gateway Processes" "[STILL RUNNING — the stop did not take]" "$C_Error"
            return 1
        fi
    fi
}

# ---------------------------------------------------------------------------
# oc — Unified OpenClaw command dispatcher.
# Usage: oc <subcommand> [args...]
# With no arguments, prints available subcommands.
# ---------------------------------------------------------------------------
function oc() {
    local sub="${1:-}"

    # Ensure gateway token is available for CLI commands.
    # Generate a per-install random token on first use if not already
    # configured via OPENCLAW_TOKEN env or ~/.openclaw/secrets.env.
    # This avoids a hardcoded default that would be in source control.
    if [[ -z "${OPENCLAW_TOKEN:-}" ]]
    then
        local _token_file="$HOME/.openclaw/.gateway_token"
        if [[ -f "$_token_file" ]]
        then
            OPENCLAW_TOKEN=$(< "$_token_file")
        else
            mkdir -p "$HOME/.openclaw"
            OPENCLAW_TOKEN=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || \
                             openssl rand -hex 16 2>/dev/null || \
                             date +%s%N | sha256sum | head -c 32)
            printf '%s' "$OPENCLAW_TOKEN" > "$_token_file"
            chmod 600 "$_token_file"
        fi
    fi
    export OPENCLAW_TOKEN

    # Show help if no subcommand provided
    if [[ -z "$sub" ]]
    then
        printf '%s\n' "${C_Highlight}oc — OpenClaw Command Reference${C_Reset}"
        printf '%s\n' ""
        printf '%s\n' "${C_Highlight}Gateway${C_Reset}"
        printf '  %-20s %s\n' "restart"      "Full gateway restart: stop, wait, start"
        printf '  %-20s %s\n' "gs"           "Gateway deep health probe"
        printf '  %-20s %s\n' "status"       "Show detailed status (--all)"
        printf '  %-20s %s\n' "health"       "Ping gateway HTTP /api/health"
        printf '  %-20s %s\n' "tail"         "Live-tail gateway logs (Ctrl-C to stop)"
        printf '  %-20s %s\n' "v"            "Print OpenClaw CLI version"
        printf '  %-20s %s\n' "update"       "Update OpenClaw CLI to latest"
        printf '  %-20s %s\n' "tui"          "Launch the interactive terminal UI"
        printf '%s\n' ""
        printf '%s\n' "${C_Highlight}Agents & Sessions${C_Reset}"
        printf '  %-20s %s\n' "start"        "Dispatch an agent turn (-m '<msg>')"
        printf '  %-20s %s\n' "stop"         "Delete an agent by ID (--agent <id>)"
        printf '  %-20s %s\n' "agent-turn"   "Alias for start"
        printf '  %-20s %s\n' "mem-index"    "Rebuild OpenClaw vector memory index"
        printf '  %-20s %s\n' "memory-search" "Semantic search over stored memories"
        printf '  %-20s %s\n' "purge"        "Reset sessions (mains/cron kept); empty hal main"
        printf '%s\n' ""
        printf '%s\n' "${C_Highlight}Config & Logs${C_Reset}"
        printf '  %-20s %s\n' "conf"         "Open openclaw.json in VS Code"
        printf '  %-20s %s\n' "config"       "Get/set config keys (get|set|unset)"
        printf '  %-20s %s\n' "env"          "Dump all OC and LLM env variables"
        printf '  %-20s %s\n' "keys"         "List Windows API keys bridged to WSL"
        printf '  %-20s %s\n' "ms"           "Probe model provider endpoints"
        printf '  %-20s %s\n' "doc-fix"      "Run doctor --fix in a Gateway window"
        printf '  %-20s %s\n' "log-dir"      "cd to the OpenClaw logs folder"
        printf '  %-20s %s\n' "logs"         "Open runtime log in VS Code"
        printf '  %-20s %s\n' "sec"          "Deep security audit"
        printf '  %-20s %s\n' "docs"         "Search OpenClaw documentation"
        printf '  %-20s %s\n' "cache-clear"  "Wipe /dev/shm telemetry caches"
        printf '  %-20s %s\n' "diag"         "5-point check: doctor, gw, models, env, logs"
        printf '  %-20s %s\n' "doctor-local" "Validate local gateway + llama.cpp path end-to-end"
        printf '  %-20s %s\n' "restart-check" "Can WSL restart now? Names what would be interrupted"
        printf '  %-20s %s\n' "failover"     "Cloud LLM fallback (on|off|status)"
        printf '  %-20s %s\n' "refresh-keys" "Re-import Windows API keys; sync SecretRefs"
        printf '  %-20s %s\n' "rotate-secrets" "Rotate checklist + optional bash log sanitization"
        # 'trust-sync' command removed
        printf '%s\n' ""
        printf '%s\n' "${C_Highlight}Data & Extensions${C_Reset}"
        printf '  %-20s %s\n' "wk"           "cd to OpenClaw workspace directory"
        printf '  %-20s %s\n' "root"         "cd to OpenClaw root directory"
        printf '  %-20s %s\n' "backup"       "Snapshot workspace + agents to ZIP"
        printf '  %-20s %s\n' "restore"      "Restore from most recent backup ZIP"
        printf '  %-20s %s\n' "cron"         "Scheduled tasks (list|add|runs)"
        printf '  %-20s %s\n' "skills"       "List installed/eligible skill modules"
        printf '  %-20s %s\n' "plugins"      "Manage plugins (list|doctor|enable|disable)"
        printf '  %-20s %s\n' "usage"        "Token and cost usage stats (default: 7d)"
        printf '  %-20s %s\n' "channels"     "Messaging channels (list|status|logs)"
        printf '  %-20s %s\n' "browser"      "Browser automation (status|start|stop)"
        printf '  %-20s %s\n' "nodes"        "Compute nodes (status|list|describe)"
        printf '  %-20s %s\n' "sandbox"      "Code sandboxes (list|recreate|explain)"
        printf '%s\n' ""
        printf '%s\n' "${C_Highlight}LLM Integration${C_Reset}"
        printf '  %-20s %s\n' "local-llm"    "Register local llama.cpp as provider"
        printf '  %-20s %s\n' "sync-models"  "Sync models.conf with OC provider scan"
        printf '%s\n' ""
        printf '%s\n' "${C_Highlight}Tools${C_Reset}"
        printf '  %-20s %s\n' "unittest"     "Run OpenClaw structural + protocol unit tests"
        printf '  %-20s %s\n' "g"            "Launch knowledge graph server in browser"
        return 0
    fi
    shift

    # Security: Use whitelist approach for subcommand validation
    # Only allow known subcommands matching pattern: lowercase letters, digits, hyphens
    if [[ ! "$sub" =~ ^[a-z][-a-z0-9]*$ ]]
    then
        __tac_info "SECURITY" "[INVALID SUBCOMMAND: $sub]" "$C_Error"
        return 1
    fi

    case "$sub" in
        # Gateway
        restart)       oc-restart "$@" ;;
        gs)            ocgs "$@" ;;
        status)        oc-status "$@" ;;
        stat)          oc-status "$@" ;;  # Legacy alias
        health)        oc-health "$@" ;;
        tail)          oc-tail "$@" ;;
        v)             ocv "$@" ;;
        update)        oc-update "$@" ;;
        tui)           oc-tui "$@" ;;
        # Agents & Sessions
        start)         ocstart "$@" ;;
        stop)          ocstop "$@" ;;
        agent-turn)    ocstart "$@" ;;
        agent-use)     oc-agent-use "$@" ;;
        agent-usage)   oc-agent-use "$@" ;;
        mem-index)     mem-index "$@" ;;
        memory-search) oc-memory-search "$@" ;;
        purge)         oc-purge "$@" ;;
        # Config & Logs
        conf)          occonf "$@" ;;
        config)        oc-config "$@" ;;
        env)           oc-env "$@" ;;
        keys)          ockeys "$@" ;;
        ms)            ocms "$@" ;;
        doc-fix)       ocdoc-fix "$@" ;;
        log-dir)       ologs "$@" ;;
        logs)          oclogs "$@" ;;
        sec)           oc-sec "$@" ;;
        docs)          oc-docs "$@" ;;
        cache-clear)   oc-cache-clear "$@" ;;
        diag)          oc-diag "$@" ;;
        restart-check) oc-restart-check "$@" ;;
        doctor-local)  oc-doctor-local "$@" ;;
        failover)      oc-failover "$@" ;;
        refresh-keys)  oc-refresh-keys "$@" ;;
        export-keys-nas) oc-export-keys-nas "$@" ;;
        rotate-secrets) oc-rotate-exposed-secrets "$@" ;;
        # trust-sync removed
        # Data & Extensions
        wk)            owk "$@" ;;
        root)          ocroot "$@" ;;
        backup)        oc-backup "$@" ;;
        restore)       oc-restore "$@" ;;
        cron)          oc-cron "$@" ;;
        skills)        oc-skills "$@" ;;
        plugins)       oc-plugins "$@" ;;
        usage)         oc-usage "$@" ;;
        channels)      oc-channels "$@" ;;
        browser)       oc-browser "$@" ;;
        nodes)         oc-nodes "$@" ;;
        sandbox)       oc-sandbox "$@" ;;
        # LLM Integration
        local-llm)     oc-local-llm "$@" ;;
        sync-models)   oc-sync-models "$@" ;;
        # Tools
        unittest)      "$HOME/.openclaw/workspace/unit-test/run-all-tests.sh" ;;
        g)             oc-kgraph "$@" ;;
        *)
            printf '%s\n' "${C_Error}Unknown subcommand:${C_Reset} $sub"
            printf '%s\n' "${C_Dim}Run 'oc' with no arguments for a list of commands.${C_Reset}"
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# oc-restart — Restart the OpenClaw gateway (systemd-managed service).
# Now uses the native OpenClaw CLI restart for reliability.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# oc-restart-check — "can I restart WSL now?", and what would be interrupted.
#
# Thin wrapper: the probe is Python (it reads /proc and nvidia-smi and needs no shell), and
# its EXIT CODE is the answer — 0 safe, 1 not safe, 2 could not measure.  The status is
# passed through deliberately, and never polished into a zero: `oc restart-check && sudo
# shutdown` has to be safe to type, so an unreadable card must not read as a free one.
# ---------------------------------------------------------------------------
function oc-restart-check() {
    local _py="${TAC_PYTHON:-python3}"
    "$_py" "$TACTICAL_REPO_ROOT/scripts/oc-restart-check.py" "$@"
}

# oc-restart — restart the OpenClaw gateway (systemd-managed service).  Its rationale block
# is the comment above oc-restart-check, which was inserted between that block and this
# definition - so this line keeps every function here with a comment directly above it.
function oc-restart() {
    if [[ "$__TAC_OPENCLAW_OK" != "1" ]]; then
        __tac_info "OpenClaw" "[NOT INSTALLED - cannot restart gateway]" "$C_Error"
        return 1
    fi
    __oc_safe_gateway_shutdown
    openclaw gateway start "$@"
}

# ---------------------------------------------------------------------------
# ocstart — Send an agent turn to OpenClaw.
# Usage: ocstart --message "<message>" [--to <E.164>] [--agent <id>]
# ---------------------------------------------------------------------------
function ocstart() {
    if [[ -z "$*" ]]
    then
        printf '%s\n' "${C_Dim}Usage:${C_Reset} oc start --message \"<message>\" [--to <E.164>] [--agent <id>]"
        printf '%s\n' "${C_Dim}  --message     Message body for the agent (required)${C_Reset}"
        printf '%s\n' "${C_Dim}  --to          Recipient number in E.164 format${C_Reset}"
        printf '%s\n' "${C_Dim}  --agent       Agent ID to target${C_Reset}"
        printf '%s\n' "${C_Dim}  --session-id  Explicit session ID${C_Reset}"
        printf '%s\n' "${C_Dim}  --thinking    Thinking level (off|minimal|low|medium|high|xhigh)${C_Reset}"
        return 1
    fi
    openclaw agent "$@"
}

# ---------------------------------------------------------------------------
# ocstop — Delete / stop an agent.
# Usage: ocstop --agent <id>
# ---------------------------------------------------------------------------
function ocstop() {
    if [[ -z "$*" ]]
    then
        printf '%s\n' "${C_Dim}Usage:${C_Reset} oc stop --agent <id>"
        printf '%s\n' "${C_Dim}  --agent  Agent ID to stop (required)${C_Reset}"
        printf '%s\n' "${C_Dim}  Tip: run 'oa' to list agents${C_Reset}"
        return 1
    fi
    openclaw agents delete "$@"
}

# ---------------------------------------------------------------------------
# oc-purge — Reset every agent: delete every stored non-main, non-cron session, reset the
# configured main to empty, repair any tombstoned main, prune the session files no store
# row names, and read the roster back.  Agent mains and cron sessions are KEPT and
# reported.
# Usage: oc purge [--dry-run]
#
# NEVER STOPS OR RESTARTS THE GATEWAY.  The store delete and the main reset run over RPC,
# so a SERVING gateway is the precondition: it is started only when it does not already
# answer, and a gateway that answers is left alone.  The outage the old version took
# bought nothing — its only purpose was clearing sessions/, and that clear was the defect.
#
# WHY THIS IS NOT "DELETE FILES" (measured 2026-10-18).  The gateway's sessions live in
# each agent's agent/openclaw-agent.sqlite, not in sessions/: the roster read 47 sessions
# across 14 agents on this box while the directories held two archives.  Deleting
# directories alone leaves every session, every tombstone and every cold-archive
# reference in place.  Two live failures proved it the same day: Hal's WhatsApp session
# was in a SessionRestartRecoveryTombstoneError retry loop (status 'failed' in
# session_windows, absent from the roster), and a cold archive missing under
# sessions/cold/ failed the usage-cost refresh on every pass.  The reset therefore goes
# through the CLI's own `sessions delete`, which removes the store rows and their live
# artifacts, and the roster is read back afterwards.
#
# WHAT sessions/ HOLDS (measured 2026-10-23).  Only `<uuid>.jsonl.deleted.<ts>.<hash>.zst`
# archives written by `sessions delete`; the live transcripts are `transcript_events` in
# the store.  Each file is named by an `archive_name` row in `session_transcript_archives`
# (and, for cold archives, `session_transcript_cold_archives`), so a blanket
# `rm -rf sessions/` ORPHANS those rows — measured: hal, finn and juno each held one file
# matching one row, while `del` held zero files and one row.  The prune is ORPHAN-ONLY: a
# file goes only when neither table names it, `cold/` is never walked, and a file whose
# store cannot be read is KEPT.
#
# ORDER: ensure serving -> delete store rows -> reset main -> repair tombstone -> prune
# orphans -> read the roster back.  Nothing here stops the gateway, so a gateway that is
# not serving is STARTED, never restarted, and a refusal names that nothing was deleted.
# ---------------------------------------------------------------------------
# __oc_purge_wait_rpc — 0 once the gateway answers `health` with ok:true, 1 at the bound.
#
# A PORT IS NOT A SERVER (measured 2026-10-23) and ONE SAMPLE IS NOT A WAIT (measured the
# same day): a restart took 38.1 s to log `http server listening` while the old step probed
# once with the CLI's own 10 s default and refused a gateway that was still starting.  So
# this waits, bounded by OC_PURGE_HEALTH_S (default 300 s), polling every
# OC_PURGE_HEALTH_STEP_S (default 5 s), and prints its state and the time left on the same
# cadence.  [$1] overrides the bound (a short probe asks "is it serving NOW?") and [$2] = 1
# silences the final probe dump, for a caller that only needs the yes/no.
function __oc_purge_wait_rpc() {
    local _bound="${1:-${OC_PURGE_HEALTH_S:-300}}" _quiet="${2:-0}"
    local _step="${OC_PURGE_HEALTH_STEP_S:-5}"
    local _progress="${OC_PURGE_PROGRESS_S:-15}"
    local _unit="openclaw-gateway.service"
    local _waited=0 _probe="" _state=""
    (( _step > 0 )) || _step=1
    while (( _waited < _bound ))
    do
        if _probe=$(timeout -k 10 45 openclaw gateway call health --json 2>&1) \
            && printf '%s\n' "$_probe" | jq -e '.ok == true' >/dev/null 2>&1
        then
            return 0
        fi
        sleep "$_step"
        _waited=$(( _waited + _step ))
        if (( _progress > 0 && _waited % _progress == 0 && _waited < _bound ))
        then
            # swallow-ok: an unreadable unit state is named unknown and does not decide
            _state=$(systemctl --user show -p ActiveState --value "$_unit" 2>/dev/null | tr -d ' \n')
            __tac_info "Gateway" \
                "[up, not answering RPC yet — ${_state:-unknown}, $(( _bound - _waited ))s left]" "$C_Dim"
        fi
    done
    (( _quiet )) || __oc_purge_stderr "$_probe"
    return 1
}

# __oc_purge_ensure_serving — 0 once the gateway is SERVING; START it only when it is not.
#
# The store delete and the reset run over RPC, so a serving gateway is the precondition.
# A gateway that already answers is never touched: no stop, no restart.  The short probe
# asks "is it serving now?" without spending the full cold-start budget on it.
function __oc_purge_ensure_serving() {
    __oc_purge_wait_rpc "${OC_PURGE_PROBE_S:-5}" 1 && return 0
    __tac_info "Gateway" "[STARTING - the store delete runs over RPC]" "$C_Warning"
    __so_start_gateway "openclaw-gateway.service" || return 1
    __oc_purge_wait_rpc
}

# __oc_purge_session_keys — every session key the stores hold, one per line.
# The roster omits FAILED sessions, so each agent's store is read as well (measured
# 2026-10-18: Hal's tombstoned WhatsApp session was in session_windows with status
# 'failed' and in no `sessions --all-agents` row).  Reads only; the delete goes through
# the CLI so the gateway, not this script, owns the mutation.
function __oc_purge_session_keys() {
    local _db
    {
        timeout -k 10 60 openclaw sessions --all-agents --json \
            | jq -r '.sessions[].key'
        for _db in "$OC_AGENTS"/*/agent/openclaw-agent.sqlite
        do
            [[ -f "$_db" ]] || continue
            timeout 30 sqlite3 "file:$_db?mode=ro" \
                "select distinct session_key from session_windows;"
        done
    } | sed '/^[[:space:]]*$/d' | sort -u
}

# __oc_purge_delete_sessions — delete every stored session through the serving gateway.
# Prints the number of keys it asked to delete.  Returns 1 when the delete did not land,
# with the CLI's own output on stderr rather than discarded.
function __oc_purge_delete_sessions() {
    local -a _keys=()
    local _key _out="" _mains=0 _cron=0
    while IFS= read -r _key
    do
        [[ -n "$_key" ]] || continue
        # The CLI REFUSES to delete a main session ("Cannot delete the main session"),
        # and one refused key fails the whole batch.  So mains are counted and reported
        # rather than sent; the configured one is reset instead (see oc-purge step 5b).
        if [[ "$_key" == *":main" ]]
        then
            _mains=$(( _mains + 1 ))
            continue
        fi
        # Cron sessions are automation state and are KEPT (owner's call 2026-10-23);
        # deleting them here would also make the roster read-back fail over rows this
        # command deliberately left.
        if [[ "$_key" == *":cron:"* ]]
        then
            _cron=$(( _cron + 1 ))
            continue
        fi
        _keys+=("$_key")
    done < <(__oc_purge_session_keys)

    printf '%s %s %s\n' "${#_keys[@]}" "$_mains" "$_cron"
    (( ${#_keys[@]} > 0 )) || return 0

    if ! _out=$(timeout -k 15 300 openclaw sessions delete "${_keys[@]}" --yes --json 2>&1)
    then
        __oc_purge_stderr "$_out"
        return 1
    fi
    return 0
}

# __oc_purge_stderr — the one place this command writes a diagnostic to stderr, so a
# scan whose stdout is the RESULT list cannot be corrupted by its own warnings.
function __oc_purge_stderr() {
    printf '%s\n' "$1" >&2
}

# __oc_purge_agent_store — the store path owning a session key; empty when the key is not
# agent-qualified (nothing to read) or the store is absent.
function __oc_purge_agent_store() {
    local _key="$1"
    local _agent
    [[ "$_key" == agent:*:* ]] || return 0
    _agent="${_key#agent:}"
    _agent="${_agent%%:*}"
    printf '%s\n' "$OC_AGENTS/$_agent/agent/openclaw-agent.sqlite"
}

# __oc_purge_store_read — one value from an agent store, read-only.
function __oc_purge_store_read() {
    local _db="$1"
    local _sql="$2"
    [[ -f "$_db" ]] || return 1
    timeout -k 10 30 sqlite3 "file:$_db?mode=ro" "$_sql"
}

# __oc_purge_prune_orphans — delete only the session files NO store row names.
#
# sessions/ holds `<uuid>.jsonl.deleted.<ts>.<hash>.zst` archives, and each one is named by
# an `archive_name` row in the same agent's store (`session_transcript_archives`, or
# `session_transcript_cold_archives` for cold/).  A blanket clear ORPHANS those rows
# (measured 2026-10-23: `del` held zero files and one row), so a file goes only when
# neither table names it.  `cold/` is never walked — its rows are the reason the directory
# is kept — and a file whose store cannot be READ is kept too: "could not tell" is not
# "unreferenced".  Prints the number pruned.
function __oc_purge_prune_orphans() {
    local _db _dir _file _base _named _cold _cold_sql
    local _pruned=0
    for _db in "$OC_AGENTS"/*/agent/openclaw-agent.sqlite
    do
        [[ -f "$_db" ]] || continue
        _dir="$(dirname "$(dirname "$_db")")/sessions"
        [[ -d "$_dir" ]] || continue
        while IFS= read -r _file
        do
            _base=$(basename "$_file")
            _base=${_base//\'/\'\'}
            _named=$(__oc_purge_store_read "$_db" \
                "select archive_name from session_transcript_archives where archive_name='$_base';") \
                || continue   # an unreadable store keeps the file
            [[ -z "$_named" ]] || continue
            _cold_sql="select archive_name from session_transcript_cold_archives where archive_name='$_base';"
            # swallow-ok: a store without the cold table names no file, so the file is kept
            _cold=$(__oc_purge_store_read "$_db" "$_cold_sql" 2>/dev/null) || _cold=""
            [[ -z "$_cold" ]] || continue
            if rm -f "$_file"
            then
                _pruned=$(( _pruned + 1 ))
            else
                __oc_purge_stderr "(could not prune $_file)"
            fi
        done < <(find "$_dir" -mindepth 1 -maxdepth 1 -type f)
    done
    printf '%s\n' "$_pruned"
}

# __oc_purge_store_has_nodes — 0 when the store carries session_nodes, 2 when it does not
# (an older fixture or an agent that never stored a session), 1 when the store cannot be
# read at all.  The three are kept apart so an unreadable store is a FAILURE, not a skip.
function __oc_purge_store_has_nodes() {
    local _db="$1"
    local _n
    _n=$(__oc_purge_store_read "$_db" \
        "select count(*) from sqlite_master where type='table' and name='session_nodes';") || return 1
    [[ "$_n" == "1" ]] || return 2   # 2 = store has no session_nodes
    return 0
}

# __oc_purge_rpc — one gateway method call, bounded.  A JSON body with ok != true is a
# failure even when the CLI exits 0 (measured: sessions delete --dry-run did exactly that).
function __oc_purge_rpc() {
    local _method="$1"
    local _params="$2"
    local _out
    if ! _out=$(timeout -k 15 120 openclaw gateway call "$_method" \
        --params "$_params" --json 2>&1)
    then
        __oc_purge_stderr "$_out"
        return 1
    fi
    if ! printf '%s\n' "$_out" | jq -e '.ok == true' >/dev/null 2>&1
    then
        __oc_purge_stderr "$_out"
        return 1
    fi
    return 0
}

# __oc_purge_reset_main — reset one main session in place.  0 = reset and read back clean,
# 3 = nothing to reset, 1 = failed.  `sessions delete` refuses a main, so the supported
# path is patch (only when archived) then reset, each bounded by the store's session id.
# The read-back is the STORE: archivedAt and mainRestartRecovery both gone.
function __oc_purge_reset_main() {
    local _key="$1"
    local _db
    local _sid
    local _archived
    local _state
    local _agent
    local _params
    _db=$(__oc_purge_agent_store "$_key")
    [[ -n "$_db" ]] || return 3   # 3 = nothing to reset
    [[ -f "$_db" ]] || return 3   # 3 = nothing to reset
    __oc_purge_store_has_nodes "$_db"
    case $? in
        0) ;;
        2) return 3 ;;   # 3 = nothing to reset
        *) return 1 ;;
    esac
    _sid=$(__oc_purge_store_read "$_db" \
        "select current_session_id from session_nodes where session_key='$_key';") || return 1
    [[ -n "$_sid" ]] || return 3   # 3 = nothing to reset
    _agent="${_key#agent:}"
    _agent="${_agent%%:*}"
    _archived=$(__oc_purge_store_read "$_db" "
        select coalesce(json_extract(entry_json,'\$.archivedAt'),'')
        from session_nodes where session_key='$_key';") || return 1
    if [[ -n "$_archived" ]]
    then
        _params=$(jq -cn --arg k "$_key" --arg a "$_agent" --arg s "$_sid" \
            '{key:$k,agentId:$a,expectedSessionId:$s,archived:false}') || return 1
        __oc_purge_rpc "sessions.patch" "$_params" || return 1
        _sid=$(__oc_purge_store_read "$_db" \
            "select current_session_id from session_nodes where session_key='$_key';") || return 1
        [[ -n "$_sid" ]] || return 1
    fi
    _params=$(jq -cn --arg k "$_key" --arg a "$_agent" --arg s "$_sid" \
        '{key:$k,agentId:$a,expectedSessionId:$s}') || return 1
    __oc_purge_rpc "sessions.reset" "$_params" || return 1
    _state=$(__oc_purge_store_read "$_db" "
        select case when json_extract(entry_json,'\$.mainRestartRecovery') is null
            and json_extract(entry_json,'\$.archivedAt') is null
            then 'clean' else 'dirty' end
        from session_nodes where session_key='$_key';") || return 1
    [[ "$_state" == "clean" ]]
}

# __oc_purge_broken_tombstones — "<key>\t<missing successor>" for every main whose recovery
# tombstone names a successor the store no longer holds.  That is the shape that refuses
# recovery; a tombstone whose successor IS present is left to the gateway's own recovery.
function __oc_purge_broken_tombstones() {
    local _db
    local _key
    local _recovered
    local _exists
    for _db in "$OC_AGENTS"/*/agent/openclaw-agent.sqlite
    do
        [[ -f "$_db" ]] || continue
        __oc_purge_store_has_nodes "$_db"
        case $? in
            0) ;;
            2) continue ;;
            *) __oc_purge_stderr "(unreadable tombstone state: $_db)"; continue ;;
        esac
        while IFS='|' read -r _key _recovered
        do
            [[ -n "$_key" && -n "$_recovered" ]] || continue
            _exists=$(__oc_purge_store_read "$_db" "
                select (select count(*) from session_nodes where session_key='$_recovered')
                     + (select count(*) from session_windows where session_key='$_recovered');") \
                || { __oc_purge_stderr "(unreadable successor state: $_db)"; continue; }
            if [[ "$_exists" == "0" ]]
            then
                printf '%s\t%s\n' "$_key" "$_recovered"
            fi
        done < <(__oc_purge_store_read "$_db" "
            select session_key,
                   json_extract(entry_json,'\$.mainRestartRecovery.tombstone.recoveredSessionKey')
            from session_nodes
            where session_key like '%:main'
              and json_extract(entry_json,'\$.mainRestartRecovery.tombstone') is not null;")
    done
}

# oc-purge — see the header above for the order and what is no longer out of scope.
function oc-purge() {
    if [[ "$__TAC_OPENCLAW_OK" != "1" ]]; then
        __tac_info "OpenClaw" "[NOT INSTALLED - cannot purge sessions]" "$C_Error"
        return 1
    fi

    # Validate OC_AGENTS path — prevent catastrophic rm -rf
    if [[ -z "$OC_AGENTS" || "$OC_AGENTS" == "/" || ! "$OC_AGENTS" =~ ^(/home|/dev/shm|/tmp) ]]; then
        __tac_info "Purge" "[REFUSED - unsafe OC_AGENTS path: ${OC_AGENTS:-(empty)}]" "$C_Error"
        return 1
    fi

    local _dry_run=0
    [[ "${1:-}" == "--dry-run" ]] && _dry_run=1

    # --dry-run reads only: it names the session KEYS and the directories, and it does
    # not touch the gateway.  The old code stopped the gateway before deciding it was a
    # dry run, which is a side effect the name denies.
    if (( _dry_run == 1 ))
    then
        local _agent_dir _key _tb_recovered
        __tac_info "Sessions" "[WOULD DELETE every stored session except agent mains and cron]" "$C_Dim"
        __oc_purge_session_keys | grep -vE '(:main$|:cron:)' | sed 's/^/    /'
        while IFS= read -r _key
        do
            case "$_key" in
                *:main)     __tac_info "Session" "[WOULD KEEP - agent main] $_key" "$C_Dim" ;;
                *":cron:"*) __tac_info "Session" "[WOULD KEEP - cron] $_key" "$C_Dim" ;;
                *)          : ;;
            esac
        done < <(__oc_purge_session_keys)
        if [[ -n "${OC_PURGE_RESET_MAIN-hal}" ]]
        then
            __tac_info "Sessions" "[WOULD RESET - main left empty] agent:${OC_PURGE_RESET_MAIN-hal}:main" "$C_Dim"
        fi
        while IFS=$'\t' read -r _key _tb_recovered
        do
            [[ -n "$_key" ]] || continue
            __tac_info "Sessions" "[WOULD REPAIR - tombstoned main] $_key -> $_tb_recovered (missing)" "$C_Dim"
        done < <(__oc_purge_broken_tombstones)
        for _agent_dir in "$OC_AGENTS"/*/
        do
            [[ -d "${_agent_dir%/}/sessions" ]] \
                && __tac_info "Session" "[WOULD PRUNE] ${_agent_dir%/}/sessions (files no store row names)" "$C_Dim"
        done
        __tac_info "Purge Complete" "[DRY RUN - nothing deleted, gateway untouched]" "$C_Dim"
        return 0
    fi

    local _pruned=0 _failed=0 _deleted=0 _mains=0 _cron=0 _resets=0 _repairs=0
    local _purge_left="" _counts=""

    # 1. A SERVING gateway is the precondition, not a stop.  The delete and the reset run
    #    over RPC, so the gateway is STARTED only when it does not already answer: a
    #    serving gateway is never stopped or restarted, and nothing below deletes state
    #    under one that is down.
    if ! __oc_purge_ensure_serving
    then
        __tac_info "Purge" "[REFUSED - the gateway is not serving; nothing was deleted]" "$C_Error"
        printf '%s\n' "  ${C_Dim}The gateway was stopped and nothing was deleted. Check 'so' and 'le'.${C_Reset}"
        return 1
    fi

    # 2. Clear session state caches
    rm -f "$TAC_CACHE_DIR/oc_sessions.json" 2>/dev/null
    rm -f "$TAC_CACHE_DIR/oc_agents.json" 2>/dev/null
    rm -f "$TAC_CACHE_DIR/oc_agent_use.txt" 2>/dev/null
    rm -f "$TAC_CACHE_DIR/oc_agent_stats.tsv" 2>/dev/null

    # 3. Delete every stored session EXCEPT each agent's main and cron sessions.  The CLI
    #    refuses to delete a main ("Cannot delete the main session", measured 2026-10-18),
    #    and one refused key fails the whole batch; cron is automation state this command
    #    keeps (owner's call 2026-10-23), so neither may reach the batch.
    __tac_info "Sessions" "[reading keys and deleting non-main, non-cron sessions]" "$C_Dim"
    if ! _counts=$(__oc_purge_delete_sessions)
    then
        __tac_info "Sessions" "[FAILED to delete store rows - reported, not claimed]" "$C_Error"
        _failed=$(( _failed + 1 ))
    else
        read -r _deleted _mains _cron <<< "$_counts"
        __tac_info "Sessions" "[$_deleted session key(s) deleted]" "$C_Dim"
        if (( _mains > 0 ))
        then
            __tac_info "Sessions" "[$_mains main session(s) KEPT - the CLI refuses to delete main]" "$C_Dim"
        fi
        if (( _cron > 0 ))
        then
            __tac_info "Sessions" "[$_cron cron session(s) KEPT - automation state is not purge's]" "$C_Dim"
        fi
    fi

    # 3b. Reset EVERY agent's main so each comes back EMPTY (owner's call 2026-10-24).
    #     `sessions delete` refuses a main, so the supported path is patch (only when
    #     archived) then reset, each bounded by the store's current session id and read
    #     back from the STORE.  `OC_PURGE_RESET_MAIN` narrows the scope to one agent when
    #     it names one; unset or `all` means every main.
    local _reset_scope="${OC_PURGE_RESET_MAIN-all}" _reset_key="" _tb_key="" _tb_recovered=""
    local _rc=0
    # Unset = every main; an explicit EMPTY value disables the reset (the repair case uses
    # that to exercise the tombstone arm alone); any other value names one agent.
    if [[ -n "$_reset_scope" ]]
    then
        __tac_info "Sessions" "[resetting every agent main to empty]" "$C_Dim"
        while IFS= read -r _reset_key
        do
            [[ "$_reset_key" == *:main ]] || continue
            if [[ "$_reset_scope" != "all" && "$_reset_key" != "agent:$_reset_scope:main" ]]
            then
                continue
            fi
            __oc_purge_reset_main "$_reset_key"
            _rc=$?
            case "$_rc" in
                0) _resets=$(( _resets + 1 ))
                   __tac_info "Sessions" "[$_reset_key reset - main kept, transcript empty]" "$C_Dim" ;;
                3) : ;;
                *) _failed=$(( _failed + 1 ))
                   __tac_info "Sessions" "[FAILED to reset $_reset_key]" "$C_Error" ;;
            esac
        done < <(__oc_purge_session_keys | grep -E ':main$' | sort -u)
    fi

    # 3c. Repair a main whose recovery tombstone names a successor the store no longer
    #     holds.  The delete above can create exactly that row, because a rollover
    #     successor is an ordinary non-main key.
    while IFS=$'\t' read -r _tb_key _tb_recovered
    do
        [[ -n "$_tb_key" ]] || continue
        __oc_purge_reset_main "$_tb_key"
        _rc=$?
        case "$_rc" in
            0) _repairs=$(( _repairs + 1 ))
               __tac_info "Sessions" "[$_tb_key repaired - tombstone pointed at missing $_tb_recovered]" "$C_Dim" ;;
            3) : ;;
            *) _failed=$(( _failed + 1 ))
               __tac_info "Sessions" "[FAILED to repair $_tb_key]" "$C_Error" ;;
        esac
    done < <(__oc_purge_broken_tombstones)

    # 4. Prune ONLY the session files no store row names.  sessions/ holds the deleted
    #    transcripts themselves, each named by an archive_name row, so the old blanket
    #    clear orphaned rows (measured 2026-10-23: `del` had one row and no file).  A
    #    file is removed only when neither archive table names it; cold/ is never walked;
    #    a file whose store cannot be read is kept.
    __tac_info "Sessions" "[pruning session files no store row names]" "$C_Dim"
    if ! _pruned=$(__oc_purge_prune_orphans)
    then
        _failed=$(( _failed + 1 ))
        __tac_info "Sessions" "[FAILED to prune orphan session files]" "$C_Error"
    elif (( _pruned > 0 ))
    then
        __tac_info "Sessions" "[$_pruned orphan session file(s) pruned]" "$C_Dim"
    fi

    # 5. Read the NON-MAIN roster back, excluding the cron rows kept above: counting either
    #    class would turn every correct purge into a failure.  "Purge complete" is a claim
    #    about the store, so it is made from a fresh read, never from the delete's rc.
    if ! _purge_left=$(timeout -k 10 60 openclaw sessions --all-agents --json \
        | jq -r '[.sessions[].key | select((endswith(":main") or contains(":cron:"))|not)] | length')
    then
        _failed=$(( _failed + 1 ))
        __tac_info "Sessions" "[could not read the roster back after delete]" "$C_Error"
    elif [[ -n "$_purge_left" && "$_purge_left" != "0" ]]
    then
        _failed=$(( _failed + 1 ))
        __tac_info "Sessions" "[$_purge_left non-main session(s) STILL STORED after delete]" "$C_Error"
    fi

    # Report result
    local _extra=""
    if (( _resets > 0 ))
    then
        _extra+=", $_resets main(s) reset"
    fi
    if (( _repairs > 0 ))
    then
        _extra+=", $_repairs tombstone(s) repaired"
    fi
    if (( _failed > 0 ))
    then
        __tac_info "Purge Complete" "[store reset, $_pruned orphan(s) pruned, $_failed FAILED]" "$C_Error"
        # A summary that says FAILED must not exit 0.  Measured live 2026-10-19: the run
        # printed "2 FAILED" and returned 0, so a caller (and the background task's
        # rc=0) read it as success — the exit code is what a caller actually sees.
        return 1
    fi
    __tac_info "Purge Complete" "[store reset, $_pruned orphan(s) pruned${_extra}]" "$C_Success"
}

# ---------------------------------------------------------------------------
# oc-agent-use — Show per-agent active session counts (simple, cached).
#
# Data flow:
#   1. Read oc_agents.json and oc_sessions.json from /dev/shm cache
#   2. If caches are stale, refresh from `openclaw agents list --json` /
#      `openclaw sessions --all-agents --json` (background for agents, sync for sessions)
#   3. Build per-agent stats via jq grouping pipeline → oc_agent_stats.tsv
#   4. Render a formatted table with token usage, cap%, and colored bars
#   5. Cache the rendered text to /dev/shm/oc_agent_use.txt (5s TTL)
# ---------------------------------------------------------------------------
# end of file

# end of file
