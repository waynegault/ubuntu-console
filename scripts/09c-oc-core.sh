# shellcheck shell=bash
# --- Module: 09c-oc-core ---
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
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

    if (( _was_running ))
    then
        # The stop is claimed only after it is read back: the unit is no longer
        # active and the port is released (__oc_gateway_gone, 09a).  Without this the
        # line was a claim about a process nobody had re-checked.
        if __oc_gateway_gone; then
            __tac_info "Gateway Processes" "[TERMINATED]" "$C_Error"
        else
            __tac_info "Gateway Processes" "[STILL RUNNING — the stop did not take]" "$C_Error"
            return 1
        fi
    else
        __tac_info "Gateway" "[NOT RUNNING]" "$C_Dim"
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
        printf '  %-20s %s\n' "purge"        "Reset every agent: delete all sessions and restart"
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
# oc-purge — Reset every agent: delete every stored session (including each agent's
# `main`), clear the session directories, and restart the gateway.
# Usage: oc purge [--dry-run]
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
# ORDER, and why.  The stop comes FIRST and a stop that does not land is a REFUSAL with
# nothing deleted (the property the original command had): everything after it deletes
# state.  The delete itself must run while the gateway serves, so the unit is started
# again after the directories are cleared, and the command ends on that serving gateway.
# A start the state-DB guard refuses is named by __so_start_gateway (09a v31), never
# retried here.
# ---------------------------------------------------------------------------
# __oc_purge_wait_gone — 0 when the gateway is GONE within the bound, 1 otherwise.
# Bounded on purpose: `oc purge` is destructive, so a gateway that will not stop is a
# refusal, not a licence to delete under it.  OC_PURGE_WAIT_S keeps a test from sleeping.
function __oc_purge_wait_gone() {
    local _bound="${OC_PURGE_WAIT_S:-120}" _waited=0
    while (( _waited < _bound ))
    do
        __oc_gateway_gone && return 0
        sleep 1
        _waited=$(( _waited + 1 ))
    done
    __oc_gateway_gone
}

# __oc_purge_session_keys — every session key the stores hold, one per line.
# The roster omits FAILED sessions, so each agent's store is read as well (measured
# 2026-10-18: Hal's tombstoned WhatsApp session was in session_windows with status
# 'failed' and in no `sessions --all-agents` row).  Reads only; the delete goes through
# the CLI so the gateway, not this script, owns the mutation.
function __oc_purge_session_keys() {
    local _db
    {
        timeout 60 openclaw sessions --all-agents --json \
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
    local _key _out="" _mains=0
    while IFS= read -r _key
    do
        [[ -n "$_key" ]] || continue
        # The CLI REFUSES to delete a main session ("Cannot delete the main session"),
        # and one refused key fails the whole batch.  So mains are counted and reported
        # rather than sent: the supported reset for a main is /reset in that chat.
        if [[ "$_key" == *":main" ]]
        then
            _mains=$(( _mains + 1 ))
            continue
        fi
        _keys+=("$_key")
    done < <(__oc_purge_session_keys)

    printf '%s %s\n' "${#_keys[@]}" "$_mains"
    (( ${#_keys[@]} > 0 )) || return 0

    if ! _out=$(timeout 300 openclaw sessions delete "${_keys[@]}" --yes --json 2>&1)
    then
        printf '%s\n' "$_out" >&2
        return 1
    fi
    return 0
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
        __tac_info "Sessions" "[WOULD DELETE every stored session, main included]" "$C_Dim"
        __oc_purge_session_keys | sed 's/^/    /'
        local _agent_dir
        for _agent_dir in "$OC_AGENTS"/*/
        do
            [[ -d "${_agent_dir%/}/sessions" ]] \
                && __tac_info "Session" "[WOULD PURGE] ${_agent_dir%/}/sessions" "$C_Dim"
        done
        __tac_info "Purge Complete" "[DRY RUN - nothing deleted, gateway untouched]" "$C_Dim"
        return 0
    fi

    local _purge_count=0 _failed=0 _deleted=0 _mains=0 _purge_left="" _counts=""

    # 1. Stop the gateway with DB-safe sequencing, then WAIT for it to be gone.  A stop
    #    that does not land is a refusal: everything below deletes state.
    __tac_info "Gateway" "[STOPPING]" "$C_Warning"
    __oc_safe_gateway_shutdown
    if ! __oc_purge_wait_gone
    then
        __tac_info "Purge" "[REFUSED - the gateway is still up; nothing was deleted]" "$C_Error"
        printf '%s\n' "  ${C_Dim}Waited ${OC_PURGE_WAIT_S:-120}s for it to stop. Watch it with 'le',${C_Reset}"
        printf '%s\n' "  ${C_Dim}then re-run 'oc purge'. Deleting under a live gateway is the${C_Reset}"
        printf '%s\n' "  ${C_Dim}failure this wait exists to prevent.${C_Reset}"
        return 1
    fi

    # 2. Clear all agent session directories
    if [[ -d "$OC_AGENTS" ]]
    then
        for _agent_dir in "$OC_AGENTS"/*/
        do
            if [[ -d "$_agent_dir" ]]
            then
                local _session_dir="${_agent_dir%/}/sessions"
                if [[ -d "$_session_dir" ]]
                then
                    # Keep cold/ : the store holds a session_transcript_cold_archives row
                    # per file, so removing the FILE while the row survives is exactly the
                    # orphan that breaks the usage-cost refresh (measured 2026-10-18: 110
                    # rows pointing at absent files).  The rows are deleted through the
                    # CLI; the files they name must outlive this pass.  With no cold/ there
                    # is nothing to preserve, so the directory itself goes.
                    local _kept=""
                    if [[ -d "$_session_dir/cold" ]]
                    then
                        _kept=" (cold/ kept)"
                        find "$_session_dir" -mindepth 1 -maxdepth 1 ! -name cold \
                            -exec rm -rf {} + || _failed=$(( _failed + 1 ))
                    else
                        rm -rf "$_session_dir" || _failed=$(( _failed + 1 ))
                    fi
                    if (( _failed == 0 ))
                    then
                        _purge_count=$(( _purge_count + 1 ))
                        __tac_info "Session" "[PURGED] $_session_dir${_kept}" "$C_Dim"
                    else
                        # A delete that did not land is NOT a purge: reported, and not
                        # counted, so the summary cannot claim a directory that is there.
                        __tac_info "Session" "[FAILED to purge] $_session_dir" "$C_Error"
                    fi
                fi
            fi
        done
    fi

    # 3. Clear session state caches
    rm -f "$TAC_CACHE_DIR/oc_sessions.json" 2>/dev/null
    rm -f "$TAC_CACHE_DIR/oc_agents.json" 2>/dev/null
    rm -f "$TAC_CACHE_DIR/oc_agent_use.txt" 2>/dev/null
    rm -f "$TAC_CACHE_DIR/oc_agent_stats.tsv" 2>/dev/null

    # 4. Start the gateway: `sessions delete` runs through it, and the command must end
    #    on a serving gateway (the reset is not a stop).
    if ! __so_start_gateway "openclaw-gateway.service"
    then
        __tac_info "Purge" "[sessions dirs cleared; the gateway did NOT start - store rows remain]" "$C_Error"
        return 1
    fi

    # 5. Delete every stored session EXCEPT each agent's main.  The CLI refuses to
    #    delete a main ("Cannot delete the main session", measured 2026-10-18), and one
    #    refused key fails the whole batch — so mains are counted, named, and left to
    #    /reset in their chat instead of failing the purge.
    if ! _counts=$(__oc_purge_delete_sessions)
    then
        __tac_info "Sessions" "[FAILED to delete store rows - reported, not claimed]" "$C_Error"
        _failed=$(( _failed + 1 ))
    else
        _deleted="${_counts%% *}"
        _mains="${_counts##* }"
        __tac_info "Sessions" "[$_deleted session key(s) deleted]" "$C_Dim"
        if (( _mains > 0 ))
        then
            __tac_info "Sessions" "[$_mains main session(s) KEPT - the CLI refuses to delete main; use /reset in that chat]" "$C_Dim"
        fi
    fi

    # 6. Read the NON-MAIN roster back.  Mains are kept by design, so counting them would
    #    turn every correct purge into a failure.  "Purge complete" is a claim about the
    #    store, so it is made from a fresh read, never from the delete's return code.
    if ! _purge_left=$(timeout 60 openclaw sessions --all-agents --json \
        | jq -r '[.sessions[].key | select(endswith(":main")|not)] | length')
    then
        _failed=$(( _failed + 1 ))
        __tac_info "Sessions" "[could not read the roster back after delete]" "$C_Error"
    elif [[ -n "$_purge_left" && "$_purge_left" != "0" ]]
    then
        _failed=$(( _failed + 1 ))
        __tac_info "Sessions" "[$_purge_left non-main session(s) STILL STORED after delete]" "$C_Error"
    fi

    # Report result
    if (( _failed > 0 ))
    then
        __tac_info "Purge Complete" "[$_purge_count agent dir(s) cleared, $_failed FAILED]" "$C_Error"
        # A summary that says FAILED must not exit 0.  Measured live 2026-10-19: the run
        # printed "2 FAILED" and returned 0, so a caller (and the background task's
        # rc=0) read it as success — the exit code is what a caller actually sees.
        return 1
    elif (( _purge_count > 0 ))
    then
        __tac_info "Purge Complete" "[$_purge_count agent dir(s) cleared, store reset]" "$C_Success"
    else
        __tac_info "Purge Complete" "[No session dirs found, store reset]" "$C_Dim"
    fi
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
