# shellcheck shell=bash
# --- Module: 09c-oc-core ---
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 55
#   v55 (2026-11-26): classify ten swallow sites v54 left unclassified. The §18.3 gate read
#       10 against a baseline of 8 and refused the push. Four of the ten already carried a
#       `# swallow-ok:` line — but above the FIRST line of a two-line construct, while the
#       redirection sits on the continuation, and a marker attaches only to the line
#       directly below it; those moved inline. The other six are real classifications: two
#       jq reads whose non-numeric result is coerced on the next line, a source whose
#       failure the next arm reports, an rc deliberately ignored because the BODY decides,
#       and two cgroup reads whose `|| return 1` IS the handling. Comments only.
#   v54 (2026-11-26): D6 — the reset phase must not be able to kill its own driver. The 14:47
#       real run reset exactly the five alphabetically-first mains (aris, chief, del, finn,
#       hal) and then stopped: it was launched from hal's main, and resetting that main ended
#       the agent turn that owned the exec running the loop (holderSignalAborted=true on a
#       57.6-minute holder). Phase 2 never opened — nine mains kept pre-run ids, zero
#       `memory.promote` calls, gateway up since 12:17. The reset phase now DERIVES the agent
#       that owns this shell (`__oc_purge_self_agent`, declared by OC_PURGE_SELF_AGENT or from
#       the gateway's own running-session view) and SKIPS that main, naming it in the summary
#       and in the exit code's accounting. The default is refusal-to-self-kill, not
#       completeness: `OC_PURGE_ALLOW_SELF_RESET=1` opts back in for a detached driver that
#       genuinely wants all fourteen. Detection that cannot name exactly one caller is
#       reported as undetermined rather than guessed — a wrong skip is a lane left un-purged,
#       which the summary says out loud, while a wrong reset is the whole run dying.
#       ALSO D7, same class through phase 2: `openclaw-gateway.service` is KillMode=mixed and an
#       agent's tool shell runs INSIDE that service's cgroup (measured /proc/self/cgroup == the
#       unit's ControlGroup), so phase 2's `systemctl --user stop` would SIGKILL the purge that
#       requested it. `__oc_purge_owns_cgroup` detects co-location from /proc and skips phase 2
#       with a reason; MEMORY.md is then left unchanged rather than half-written.
#   v53 (2026-11-26): the SC1090 suppression above the env-file source is now a
#       `source=/dev/null` directive. v51 added it and took the §18.3 11.5 suppression count to
#       17 against a baseline of 16, and the fast suite refuses a rise. A directive names the
#       runtime target so the diagnostic resolves, rather than muting it — the form the
#       ratchet's own comment asks for. Count is back at 16; shellcheck reports no SC1090.
#       (Deliberately not spelled with the `disabl` prefix here: the ratchet greps for that
#       literal, so writing it in prose would count as a suppression of its own.)
#   v52 (2026-11-26): no behaviour change. Two lines v51 added ran past 120 columns and took
#       the §18.3 8.1.8 count over its baseline; wrapped them rather than re-baselining, for
#       the same reason v49 gave -- a re-baseline hides the next one.
#   v51 (2026-11-26): the first REAL purge run since v50, and it still failed. Six defects, each
#       measured; the first two are why it could never have gone green.
#       (1) THE READ-BACK COUNTED THE SAME ROWS TWICE WITH OPPOSITE VERDICTS. 31 delete
#       candidates; 21 were `:run:` rows whose session_nodes entry is `{}` with
#       `entry_valid = -1`. The gateway cannot describe them (`sessions.describe` ->
#       `{"session":null}`), the roster lists none of them, and `sessions delete` answers
#       `not_found` for every one -- so the delete arm counted them INVISIBLE and the read-back
#       then counted them as surviving sessions and reported N FAILED on every run. They are a
#       different population: an OpenClaw repair gap, not something this command can delete.
#       The read-back now asks `sessions.describe` per leftover key and splits the verdict into
#       SURVIVORS (visible, fails) and INVISIBLE (not visible, named, does not fail), with
#       OC_PURGE_INVISIBLE_IS_FAILURE=1 for a sweep that must prove the stores are empty.
#       (2) A SILENT CLI WAS CALLED A REFUSAL. A delete that exited 0 with no body made a
#       correct purge report 1 FAILED for healthy agents. Silence is the `not_found` shape, so
#       a zero-exit silent body is now resolved against the STORE (still stored -> invisible,
#       gone -> deleted); a NON-ZERO exit is still a refusal whatever it printed.
#       (3) `case "$(fn)"` CANNOT SEE THE STATUS. An empty substitution matches `*)`, so a
#       helper returning 0 with no output fell into the failure arm. Measured, and fixed by
#       capturing the code first.
#       (4) THE BANNER DROPPED EVERY MEMORY CLAUSE. `local _extra=""` was declared BELOW the
#       block that appends to it, so the appends hit the global and the `local` then discarded
#       them: a run that flushed and promoted said only "1 main(s) reset".
#       (5) THE ROSTER READ-BACK COULD NOT FAIL. `if ! x=$(openclaw ... | jq ...)` takes jq's
#       status, so a dead CLI was hidden by jq exiting 0 on empty input. The CLI's rc is taken
#       on its own line and an unparseable body is a failure, not a zero.
#       (6) "FAILED to delete store rows" claimed the whole delete failed while one agent's
#       batch had been refused and the rest landed. Reworded to what the exit means.
#   v50 (2026-11-26): THE FLUSH GATE HAD THE SAME DEFECT v48 FIXED IN THE PROMOTE GATE, and a real
#       purge run found it the same night. `memory session-backfill --apply --json` ALSO emits no
#       `ok` field on success (keys: agentId, workspaceDir, applied, rem, days, candidateCount,
#       stagedEntries, ...); `ok` appears only on the ERROR path. So v46's `.ok == true` was false
#       on every HEALTHY lane and the real run refused all 14 resets -- "memory flush not proven"
#       14 times, 16 FAILED, 0 resets, rc 1. The success spelling is now `has("applied") and
#       .error == null`. Verified after the fix: aris and sarah both return 2 (nothing to
#       distil), which phase 3 correctly treats as reset-eligible.
#       LESSON, and it is the third instance: `jq -e '.ok == true'` is not a universal success
#       check in this CLI. RPC methods emit `ok`; these two CLI commands do not. Assert the
#       spelling the command actually uses, and prove it against a real run before shipping.
#   v49 (2026-11-26): no behaviour change. Three v48 lines ran past 120 columns and took the
#       §18.3 8.1.8 count 287 -> 290; wrapped them rather than re-baselining, because a
#       re-baseline would hide the next one.
#   v48 (2026-11-26): TWO GATES IN v46 THAT COULD NEVER PASS, both found by opening a real
#       offline window instead of reasoning about one. (1) `memory promote --json` emits NO `ok`
#       field -- keys are workspaceDir, storePath, lockPath, audit, candidates[, apply] -- so
#       `.ok == true` was false on every SUCCESSFUL run and would have reported 14 of 14 lanes
#       FAILED while MEMORY.md was being written correctly. (2) A working offline promote still
#       prints `gateway secrets.resolve unavailable ...; resolved command secrets locally`, and
#       the probe refused on the first half, so the window never opened. The success spelling
#       is now the second half. The write is proven by MEMORY.md's sha, and "nothing qualified"
#       is reported apart from FAILED because it is a threshold, not a fault: measured this day,
#       every lane's best candidate scores below the 0.75 default.
#   v47 (2026-11-26): three fixes found by running v46's own new suite.
#     (a) __oc_purge_stderr printed a bare newline for an EMPTY body, so a refusal whose
#         CLI said nothing prepended a blank line to the delete report and the report's
#         own regression test failed on noise rather than on a count. An empty body now
#         reports nothing.
#     (b) The v46 swallow markers were written at explanatory length and took the §18.3
#         8.1.8 count 287 -> 294 (markers are code lines for that counter). Shortened to
#         classify the same sites inside 120 columns; 8.1.8 is back at its baseline.
#     (c) tests/unit/09c-purge-scope.bats stubbed `openclaw()` while every call is wrapped
#         in `timeout`, which is an EXTERNAL binary and resolves `openclaw` via PATH, so
#         the stub was never consulted and three cases ran the real CLI. The suite now
#         stubs `timeout` in the cases that need it; 26/26 pass, and through the pytest
#         bridge too (was 3 failed).
#   v45 (2026-11-25): memory-first purge.  The reset used to empty every agent main before
#     any memory had been promoted, so a purge could destroy the only copy of what an agent
#     had learned.  Order is now: (i) online per-agent `session-backfill --apply`, verified
#     durable, which gates whether that agent may be reset at all (the gate skips the agent,
#     not the run, so one bad lane cannot leave the fleet half-purged); (ii) ONE offline
#     window running `memory promote --apply` for the whole fleet, which is the only context
#     in which promote is admitted; (iii) the resets, which need the Gateway back because
#     they are RPC.  The window restores the Gateway on a trap and verifies at the predicate
#     (`openclaw health`), never at systemd's `active` word.
#   v46 (2026-11-26): the 2026-11-25T23:20Z run was measured against its own intent and five
#     defects were found, each with a command behind it (reports/2026-11-26-oc-purge-plan.md).
#     (1) ORDER, and promote cannot run at all on this box: online `memory.cli` refuses
#     "requires exclusive offline state ownership"; offline it cannot resolve its secret
#     ("gateway secrets.resolve unavailable (ECONNREFUSED)", 14/14 lanes).  Promote ran FIRST,
#     before any backfill, and promoted nothing -- MEMORY.md untouched in all 14.  The window
#     now runs AFTER the flush pass and exports the unit EnvironmentFile so the secret can
#     resolve locally; if it still cannot, the run says "promote DID NOT RUN" and counts it.
#     (2) THE GATE COULD NOT FAIL: a parse failure yielded candidateCount 0, and "0 candidates"
#     returned 0 (pass) -- 13 of 14 lanes passed on that arm.  It now asserts `.ok == true`
#     FIRST, reads `stagedEntries`, and treats an unparsed or error body as a FAILURE.
#     (3) RESET AND DELETE POPULATIONS: the reset loop walked roster UNION stores; the delete
#     handed the CLI only roster keys, so 21 `:run:` rows were reset-pending and undeletable.
#     (4) ONE REFUSED KEY FAILED THE FLEET: the delete was a single `sessions delete` over 21
#     keys; the CLI refused one, the batch failed, and every cron-run transcript stayed.  Now
#     per agent, so a refusal is that agent's failure and the rest still land.
#     (5) THE VERIFY ARM READ THE ROSTER, which omits exactly the rows in question -- it read 0
#     while 21 `:run:` rows sat in the stores.  The read-back now counts the STORES too.
#   v44 (2026-11-11): one canonical version line; the historical entries below
#     are changelog only, so the loader sums this file once (inspection 13.4.3).
#   v43 (2026-11-01): the dispatcher's help lines for `ms` and `sync-models` describe what
#   those commands now do — `oc ms` lists provider endpoints (no OpenRouter scan), and
#   `oc sync-models` refreshes the hosted model catalog.
#   v42 (2026-11-01): comment-only.  Every `return N` the `oc token` resolver emits now
#   names its meaning at the line, because the §18.3 9.7 counter counted all seven as
#   unexplained and the committed baseline was seven below the tree.
#   v41 (2026-11-01): new `oc token` — prints the gateway token and copies it to the
#   Windows clipboard.  It RESOLVES `gateway.auth.token` rather than reading it as a
#   string: since 2026-11-01 12:12 the value is a SecretRef ({source:"store", id:
#   OPENCLAW_GATEWAY_TOKEN}), so the old `node -e require(...).gateway.auth.token`
#   one-liner would print an object.  Handles a plaintext string and env/store refs.
#   v40 (2026-11-01): the no-arg `oc` reference now names `export-keys-nas`
#   (the case statement already routed it — the printed reference never did).
#   v39 (2026-10-30): three §18.3 counters rose with v37/v38 and nothing re-baselined them,
#   so the pre-push ratchet refused every push from this checkout — a gate doing its job on a
#   style debt, not on the fix. Fixed the three rather than re-baselining: two __tac_info calls
#   wrapped under 120 columns, a comment directly above `xo` (the definition had a blank line,
#   which the counter reads as unattributed), and `return 4` in the tombstone path named, since
#   a code other than 0/1 with no comment on the line is unreadable to the next editor.
#   v38 (2026-10-29): corrects v37's third point, which claimed a tombstoned main simply
#   cannot be reset.  Measured on a live gateway the same day: `sessions.reset` IS allowed
#   when `allowRestartTombstoneReplacement === true && !entry.providerReview`
#   (session-work-start, 2026.10.10-beta.4), and the reset service passes that flag only
#   when `entry.archivedAt === undefined`.  So the deadlock is exactly the entry that is
#   BOTH archived and tombstoned: it can never satisfy the condition, while the error's own
#   advice ("Use /new or /reset") fails the same way.  `sessions.patch {archived:false}`
#   THEN `sessions.reset`, in that order, cleared four wedged mains (doctor 4 -> 0) — the
#   ordering __oc_purge_reset_main already performs, now pinned by a test.  `sessions.recover`
#   remains the fallback when reset is still refused; it starts a successor and leaves the
#   tombstone set (rc 4, reported as such, never as a repair).
#   v37 (2026-10-29): `oc purge` names three things it used to get wrong.  (1) The dry run
#   read ${OC_PURGE_RESET_MAIN-hal} while the real run read ${OC_PURGE_RESET_MAIN-all}, so
#   with the variable UNSET the preview named one main and the run reset all fourteen; both
#   arms now call `__oc_purge_reset_scope`, and the dry run lists every key it would reset.
#   (2) Nothing counted unreadable stores, so a run that could not read them printed
#   "Purge Complete" over its own errors — measured 2026-10-29 with sqlite3 absent, 14
#   unreadable stores, rc 0.  `__oc_purge_store_census` now refuses BEFORE previewing or
#   deleting, because a key list built on an unreadable store understates the blast radius.
#   (3) A main left TOMBSTONED by a restart had no route out of purge.  The refusal it hits
#   is narrower than first recorded — v38 below supersedes this paragraph.
#   v36 (2026-10-24): `xo` WAITS for the stop instead of sampling it once — measured live,
#   it read the unit as `activating` while its own stop sat queued behind an auto-restart,
#   printed "the stop did not take" and exited 1, and the unit was `inactive` 30 s later.
#   `__oc_wait_gateway_gone` (09a) is bounded by the unit's own TimeoutStopUSec and prints
#   its progress; the [NOT RUNNING] row is now a read-back too, not an echo of the pre-stop
#   probe (a start job can land between the two).
#   v35 (2026-10-24): the purge resets EVERY agent's main, not only the configured one
#   (owner's call: "both"), and it narrates its three slow phases — enumeration+delete,
#   reset, prune — because ~2-3 minutes of silence read as a freeze.  `OC_PURGE_RESET_MAIN`
#   still narrows the reset to one agent when set; unset/`all` means every main.
#   v34 (2026-10-23): `xo` names the fleet lanes still running after it stops the owned LLM.
#   `model stop` protects lanes by design, so "[STOPPED]" was true of one server and read as
#   the whole box; the lanes are now reported, never stopped here.
#   v33 (2026-10-23): `oc purge` NEVER stops or restarts the gateway.  Its sessions/ holds
#   only the archives `sessions delete` wrote, each named by an `archive_name` row, so the
#   blanket clear ORPHANED those rows — measured: hal/finn/juno each held one file matching
#   one row, while `del` held zero files and one row.  The stop/start is gone (the delete
#   and the reset run over RPC), a SERVING gateway is required before anything is deleted
#   and started only when it does not answer, and the clear is an ORPHAN-ONLY prune that
#   keeps cold/ and keeps any file whose store cannot be read.
#   v32 (2026-10-23): the purge WAITS for the restarted gateway to answer RPC instead of
#   sampling it once.  Measured live: a restart took 38.1 s to log `http server listening`,
#   but step 4b probed once with the CLI's 10 s default and refused a gateway that was
#   still starting ("gateway timeout after 10000ms") — after the session dirs had already
#   been cleared.  The wait is bounded (OC_PURGE_HEALTH_S, default 300 s, polled every
#   OC_PURGE_HEALTH_STEP_S) and prints progress; its refusal names the partial state.
#   v32 (2026-10-23): the purge REFUSES before it stops a gateway whose own last shutdown
#   did not complete.  Read from the journal: every one of today's four stops settled its
#   work drain in <=20 s and then sat in `shutdown.gateway-close` past TimeoutStopUSec with
#   close steps still pending, so systemd SIGKILLed it, the state DB stayed in offline
#   maintenance and the next start was refused — a purge would have left the gateway DOWN
#   with the session dirs already cleared (step 2 runs before the start).  The self-kill
#   bound is also derived from the unit's TimeoutStopUSec (+10 s), not a flat 120 s, which
#   fired 210 s INSIDE the budget the unit was given for a drain doing real work.
#   v30 (2026-10-23): a shutdown that overruns is KILLED and held down instead of being
#   fought poll-by-poll: live, the drain hung ~5 min, systemd SIGKILLed it, Restart=always
#   brought it back, and the loop spent the rest of the bound replacing starts.  The
#   replacement line is also throttled — unthrottled it printed every second and buried the
#   progress rows.
#   v29 (2026-10-23): the reset/patch params use `key`, not `sessionKey`.  Measured live:
#   sessions.reset rejected {"sessionKey":...} with "must have required property 'key'".
#   The witness asserts the param NAME, because a mock that accepts any shape proves nothing.
#   v28 (2026-10-23): the restart replacement uses `systemctl stop --no-block`, not
#   `--job-mode=replace`.  Measured: the latter blocked 30 s (rc=124) behind the pending
#   auto-restart and changed nothing, so every poll stalled and the purge looked frozen.
#   v27 (2026-10-23): the replacement prints systemctl's OWN refusal.  Live, the loop
#   printed only "refused" every poll, which is undiagnosable; a discarded diagnostic
#   stream is the defect, so the helper captures it and the caller no longer prints a
#   second generic line.
#   v26 (2026-10-23): the gone-wait prints its state and time left every 15 s.  A live run
#   sat silent for minutes and read as "frozen"; silence is not progress.  The interval is
#   a seam (OC_PURGE_PROGRESS_S) so the witness does not sleep.
#   v25 (2026-10-23): the purge's wait now REPLACES a queued restart while it waits.  The
#   loop used to only observe, so a `Restart=always` start (queued when systemd SIGKILLs a
#   unit that overran TimeoutStopUSec) always won and the purge always refused.  The
#   refusal message also names the real bound (it still said 120 after the bound became 360).
#   v24 (2026-10-23): purge proves the gateway ANSWERS RPC before touching the store.
#   Measured live: __so_start_gateway printed ONLINE (port 18789) and every openclaw call
#   then timed out at 30 s, so `sessions delete` could not land and the purge reported a
#   FAILED store with the rows still there.  A port is not a server.
#   v23 (2026-10-23): the purge's gone-wait bound is 360 s, not 120 — the unit's own
#   TimeoutStopUSec is 5min 30s, and a normal drain (queueSize=6, agentRuns=3) was
#   refused at 120 s.  `__oc_gateway_gone` no longer reads our own stop job as a return.
#   v22 (2026-10-23): `oc purge` now names the three things it used to overstate.  CRON
#   sessions are KEPT (Wayne, 2026-10-23) and counted, so the roster read-back ignores them
#   or every purge would fail over rows it deliberately kept.  Each agent's MAIN is kept, and
#   every agent main (OC_PURGE_RESET_MAIN; unset = all) is RESET through the gateway RPC
#   (`sessions.patch {archived:false}` then `sessions.reset`, both with expectedSessionId) so
#   it comes back empty — `sessions delete` refuses a main.  A main whose recovery tombstone
#   points at a successor the store no longer holds is REPAIRED the same way; purge deletes
#   that successor class, so without this it would manufacture the tombstone it leaves behind.
#   Read-backs are from the store (archivedAt and mainRestartRecovery gone), never the RPC's
#   own ok.  Bounded CLI calls carry `-k` because the CLI ignores SIGTERM.
#   v21 (2026-10-18): the purge's `timeout … openclaw` calls carry `-k` (10 s for a read,
#   15 s for the delete).  The CLI ignores SIGTERM — measured on `gateway stop` — so a
#   plain timeout could wait forever on a hung CLI.
#   v20 (2026-10-18): a purge with any failed step exits NON-ZERO.  The live run printed
#   "2 FAILED" and returned 0, so the caller could not tell that it had failed.
#   v19 (2026-10-18): a sessions dir with NO cold/ is still removed whole.  The cold/
#   guard must not leave an empty sessions/ behind, which would make the directory purge
#   a no-op on every agent that has no cold archive.
#   v18 (2026-10-18): the session-dir purge KEEPS `cold/`, because the store holds a row
#   per cold archive.  Measured: 110 rows pointed at files already removed by earlier
#   purges, and the usage-cost refresh failed on every one.  Rows are deleted through
#   the CLI; the files they name must outlive the pass that clears the directories.
#   v17 (2026-10-18): `oc purge` never sends a MAIN session to `sessions delete`.
#   Measured live: the CLI refuses it ("Cannot delete the main session"), and one
#   refused key fails the whole batch — so the first live purge deleted the non-main
#   sessions but reported the store delete as FAILED.  Mains are now counted and
#   reported as KEPT ("use /reset in that chat"), the batch carries only non-main keys,
#   and the roster read-back counts non-main rows so a correct purge is not a failure.
#   v16 (2026-10-18): `oc purge` resets the session STORES, not just the directories.
#   Measured: 47 sessions across 14 agents lived in agent/openclaw-agent.sqlite while the
#   deleted dirs held two archives; a tombstoned WhatsApp session ('failed', absent from
#   the roster) kept a poison retry loop, and a missing cold archive broke the usage-cost
#   refresh on every pass.  It now deletes every stored session (main included) through
#   `sessions delete`, restarts the gateway, and reads the roster back; --dry-run no
#   longer stops the gateway.
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
: "${C_Warning:=}"

# Idempotent include guard: sub-modules are sourced both by their thin
# loader and directly by the profile/env loaders, so run the body once.
[[ -n "${__TAC_MOD_09C_OC_CORE_LOADED:-}" ]] && return 0
__TAC_MOD_09C_OC_CORE_LOADED=1

# `xo` — stop every OpenClaw process this box owns, then report what is still running.
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
    # swallow-ok: an unloaded unit reads inactive; __test_port is the second opinion
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
        # swallow-ok: failure IS the branch condition; the next line reports it
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
            # Token source is a three-rung fallback: urandom, then openssl, then a timestamp
            # digest. Each rung's failure IS the reason for the next, so none is a silent
            # failure; the third cannot fail. Markers are inline because the scanner attaches
            # a marker only to the line directly below it, and each redirection is on a
            # continued line of its own.
            # swallow-ok: rung 1 of 3; its failure selects rung 2
            OPENCLAW_TOKEN=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || \
                             openssl rand -hex 16 2>/dev/null || \  # swallow-ok: rung 2 of 3; rung 3 cannot fail
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
        printf '  %-20s %s\n' "token"        "Print the gateway token and copy it to the clipboard"
        printf '  %-20s %s\n' "env"          "Dump all OC and LLM env variables"
        printf '  %-20s %s\n' "keys"         "List Windows API keys bridged to WSL"
        printf '  %-20s %s\n' "ms"           "List provider endpoints and keys"
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
        printf '  %-20s %s\n' "export-keys-nas" "Export bridged API keys to the NAS"
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
        printf '  %-20s %s\n' "sync-models"  "Refresh OpenClaw's hosted model catalog"
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
        token)         oc-token "$@" ;;
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
# oc-token — Print the gateway token and copy it to the Windows clipboard.
# `gateway.auth.token` is resolved, not read raw: it is a plaintext string in older
# configs, and a SecretRef since 2026-11-01 12:12 ({source:"store", id:
# OPENCLAW_GATEWAY_TOKEN}), for which `openclaw config get` redacts the value and
# `openclaw secrets store get` refuses (secret-kind entries are write-only).  The env
# branch reads the gateway's own EnvironmentFile; the store branch reads the team-scoped
# row out of the state DB read-only.  Exit 1 on an unresolvable token or a refused copy.
# ---------------------------------------------------------------------------
function oc-token() {
    local cfg="${OPENCLAW_CONFIG_PATH:-$HOME/.openclaw/openclaw.json}"
    local token rc=0
    token=$("${TAC_PYTHON:-python3}" - "$cfg" <<'PY'
import json
import os
import sqlite3
import sys


def main() -> int:
    cfg_path = sys.argv[1]
    try:
        with open(cfg_path, encoding="utf-8") as fh:
            cfg = json.load(fh)
    except OSError:
        return 2   # 2 = the gateway config could not be read
    except ValueError:
        return 3   # 3 = the gateway config is not valid JSON
    ref = ((cfg.get("gateway") or {}).get("auth") or {}).get("token")
    if isinstance(ref, str):
        sys.stdout.write(ref)
        return 0
    if not isinstance(ref, dict):
        return 4   # 4 = gateway.auth.token is neither a resolved string nor a reference object
    source, name = ref.get("source"), ref.get("id")
    if source == "env" and name:
        value = os.environ.get(name)
        if value is None:
            for filename in ("gateway.systemd.env", ".env"):
                full = os.path.join(os.path.expanduser("~/.openclaw"), filename)
                try:
                    with open(full, encoding="utf-8") as fh:
                        for line in fh:
                            if line.startswith(name + "="):
                                value = line.rstrip("\n").split("=", 1)[1]
                                break
                except OSError:
                    continue
                if value is not None:
                    break
        if value:
            sys.stdout.write(value)
            return 0
        return 5   # 5 = the referenced env var is unset and absent from the fallback env files
    if source == "store" and name:
        db = os.environ.get("OPENCLAW_STATE_DB") or os.path.expanduser(
            "~/.openclaw/state/openclaw.sqlite"
        )
        try:
            con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=2.0)
            row = con.execute(
                "select value from secret_store_entries "
                "where scope_kind='team' and name=? and deleted_at_ms is null "
                "order by updated_at_ms desc limit 1",
                (name,),
            ).fetchone()
            con.close()
        except sqlite3.Error:
            return 6   # 6 = the state DB could not be opened or queried
        if row and row[0]:
            value = row[0].decode("utf-8", "replace") if isinstance(row[0], bytes) else row[0]
            sys.stdout.write(value)
            return 0
        return 7   # 7 = the store holds no live entry for that name
    return 8   # 8 = the ref's source is neither "env" nor "store"


sys.exit(main())
PY
) || rc=$?
    if [[ $rc -ne 0 || -z "$token" ]]
    then
        __tac_info "Token" "[could not resolve gateway.auth.token (rc=$rc)]" "$C_Error"
        return 1
    fi
    printf '%s\n' "$token"
    local clip=""
    if command -v clip.exe >/dev/null
    then
        clip="clip.exe"
    elif [[ -x /mnt/c/Windows/System32/clip.exe ]]
    then
        clip="/mnt/c/Windows/System32/clip.exe"
    fi
    if [[ -n "$clip" ]] && printf '%s' "$token" | "$clip"
    then
        __tac_info "Clipboard" "[gateway token copied]" "$C_Success"
        return 0
    fi
    __tac_info "Clipboard" "[COPY FAILED - clip.exe unavailable or refused]" "$C_Error"
    return 1
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

# __oc_purge_classify_key — ONE classifier, so the preview, the reset scope and the delete
# batch cannot disagree about what a key is.  Echoes exactly one of:
#   main   / cronjob / cronrun / subagent / ephemeral
#
# WHY THIS EXISTS (2026-11-25, Wayne: "i don't think it works properly").  The delete filter
# was `grep -vE '(:main$|:cron:)'`, a substring test on the WHOLE key.  A cron RUN session is
# `agent:<a>:cron:<job>:run:<id>`; it contains `:cron:` and so was KEPT -- permanently, because
# nothing else ever reaches it.  Measured on this box the same day: 21 cron-run sessions across
# 14 agents, of which sarah alone held 12.  Those are the rows that make a "fresh start" not
# fresh, and they accumulate one per failed or slow automation run forever.
#
# The distinction the substring test cannot make is exactly the one that matters:
#   cronjob  = agent:<a>:cron:<job-id>            the automation's OWN session. KEPT (owner's
#                                                  call 2026-10-23: cron is automation state).
#   cronrun  = agent:<a>:cron:<job-id>:run:<id>   one execution. DELETED -- the run is over and
#                                                  its transcript is history, not state.
# Sub-agent sessions are DELETED too (Wayne's requirement 2026-11-25).  None exist on this box
# at the time of writing, so the arm is written from the shape rather than observed -- and it is
# ordered BEFORE the cron arms because a sub-agent spawned by a cron job is both, and the
# narrower meaning wins.
function __oc_purge_classify_key() {
    local _k="${1:-}"
    [[ -n "$_k" ]] || { printf 'ephemeral\n'; return 0; }
    # A sub-agent/spawn key, whether or not a cron job parented it.
    if [[ "$_k" =~ :(subagent|sub|spawn|child)(:|$) ]] || [[ "$_k" == *":sub:"* ]]
    then
        printf 'subagent\n'; return 0
    fi
    # Cron RUN: a trailing `:run:<uuid>` under a cron job id. Anchored to the end so the job's
    # own session (which has no `:run:`) is not caught.
    if [[ "$_k" =~ ^agent:[^:]+:cron:[^:]+:run:[^:]+$ ]]
    then
        printf 'cronrun\n'; return 0
    fi
    if [[ "$_k" == *":main" ]]
    then
        printf 'main\n'; return 0
    fi
    if [[ "$_k" == *":cron:"* ]]
    then
        printf 'cronjob\n'; return 0
    fi
    printf 'ephemeral\n'
}

# __oc_purge_delete_keys — the keys this command will DELETE, derived ONCE from the union of
# the CLI roster and every agent store.  Preview and batch both call this, so the dry run
# cannot list a set the real run does not perform (the defect its own v37 notes claim fixed
# for the reset scope only).
function __oc_purge_delete_keys() {
    local _key
    while IFS= read -r _key
    do
        [[ -n "$_key" ]] || continue
        case "$(__oc_purge_classify_key "$_key")" in
            main|cronjob) : ;;                 # kept; main is reset instead
            *)            printf '%s\n' "$_key" ;;
        esac
    done < <(__oc_purge_session_keys)
}

# __oc_purge_memory_flush — distill an agent's session history into durable memory BEFORE its
# main is reset, and PROVE something survived that outlives the transcript.  Returns 0 on a
# verified flush, 1 on failure.
#
# WHY THIS EXISTS (Wayne, 2026-11-25): "this should save key facts to memory, completely clear
# agent main sessions so nothing is in them".  Measured the same day, the purge had NO memory
# step at all -- grep -icE 'memory|distill|flush|persist' over oc-purge and its four helpers
# returned 0.  It reset mains to empty and relied on the agent having already written things
# down, which is a hope, not a control: anything said in a main and not yet written was
# destroyed.  A purge that cannot show it preserved context must not clear it.
#
# NO NEW EXTRACTION IS INVENTED HERE; the two existing commands do different jobs and only one
# of them can run while the gateway serves:
#   openclaw memory session-backfill --apply   ONLINE.  Distils retained transcript history into
#       staged candidates in the agent store's memory_index_* tables and writes DREAMS.md diary
#       entries.  Those live OUTSIDE the session tables, so they survive sessions.reset and are
#       the durable artefact this gate verifies.
#   openclaw memory promote --apply            OFFLINE-ONLY.  It refuses while the Gateway owns
#       the state root ("requires exclusive offline state ownership"), and oc-purge NEVER stops
#       the gateway by design (v33).  So promotion into MEMORY.md cannot happen here; it is
#       DEFERRED to the next offline maintenance window and SAID SO, rather than papered over.
#       Measured 2026-11-25: the refusal is a clean cli_error, not a corruption.
#
# THE PROOF IS A COUNT AND A HASH, NOT AN EXIT CODE (rule: "a success code is not a success").
# memory_index_sources rows and the DREAMS.md hash are read before and after.  The flush passes
# when the backfill ran AND at least one of: the index grew, DREAMS.md changed, or the backfill
# reported zero candidates (history already distilled -- backfill is idempotent, measured: a
# second --apply over processed days returns days:[] candidateCount 0).  Anything else refuses.
function __oc_purge_memory_flush() {
    local _agent="${1:?__oc_purge_memory_flush needs an agent id}"
    local _ws="$HOME/.openclaw/workspace-$_agent"
    local _db="$OC_AGENTS/$_agent/agent/openclaw-agent.sqlite"
    if [[ ! -d "$_ws" ]]
    then
        __tac_info "Memory" "[$_agent: NO WORKSPACE at $_ws - cannot verify a flush, refusing its RESET]" "$C_Error"
        return 1
    fi

    local _idx_before=0 _idx_after=0 _dreams_before="" _dreams_after=""
    _idx_before=$(__oc_purge_memory_index_rows "$_db")
    [[ -f "$_ws/DREAMS.md" ]] && _dreams_before=$(sha256sum "$_ws/DREAMS.md" | cut -d' ' -f1)

    local _bf="" _cands=0 _staged=0
    if ! _bf=$(timeout -k 10 900 openclaw memory session-backfill --agent "$_agent" --apply --json 2>&1)
    then
        __tac_info "Memory" "[$_agent: session-backfill FAILED - refusing its RESET]" "$C_Error"
        __oc_purge_stderr "$_bf"
        return 1
    fi

    # ASSERT THE BODY IS A SUCCESS BEFORE READING ANY COUNT (v46), BUT ASSERT THE SPELLING THE
    # COMMAND ACTUALLY USES (v50).  Measured 2026-11-26 in a real purge run: a SUCCESSFUL
    # `session-backfill --apply --json` body is
    #   {agentId, workspaceDir, applied, rem, days, candidateCount, stagedEntries,
    #    writtenDiaryEntries, replacedDiaryEntries, batchCount, batches}
    # -- IT HAS NO `ok` FIELD EITHER.  So v46's `.ok == true` was FALSE on every HEALTHY lane and
    # the run refused all 14 resets with "memory flush not proven".  The defect is one level up
    # from where v46 fixed it: RC says nothing, and `ok` is emitted only on the ERROR path.
    #   error body   -> {"ok":false,"error":{...}}      (printed by the CLI's own error handler)
    #   success body -> no `ok` key at all
    # The success spelling is therefore `applied` present and `error` absent.  Both are required:
    # a body with neither is unreadable and REFUSES.
    # THE BODY IS NOT THE WHOLE CAPTURE (v50).  `2>&1` merges the CLI's `[secrets]` chatter into
    # the same variable, so `jq` on the raw capture fails to PARSE and every test below reads as
    # "not a success".  Measured 2026-11-26: this is what made a real purge skip all 14 resets
    # even after the `.ok` defect was fixed -- a direct call filtered the chatter and returned 2,
    # while the same call inside the run returned 1.  The JSON starts at the first line that
    # begins with `{`.  Same extraction as the promote gate, for the same reason.
    local _bj
    _bj=$(printf '%s\n' "$_bf" | sed -n '/^{/,$p')
    if printf '%s' "$_bj" | jq -e '.error != null' >/dev/null 2>&1 \
        || ! printf '%s' "$_bj" | jq -e 'has("applied")' >/dev/null 2>&1
    then
        __tac_info "Memory" "[$_agent: session-backfill body is not a success - refusing its RESET]" "$C_Error"
        __oc_purge_stderr "$_bf"
        return 1
    fi
    # swallow-ok: a failed jq parse reads -1 on the next line, which the gate refuses
    _cands=$(printf '%s' "$_bj" | jq -r '.candidateCount // ([.days[]?.candidateCount // 0] | add) // 0' 2>/dev/null)
    # swallow-ok: as above; coerced to 0 on the next line
    _staged=$(printf '%s' "$_bj" | jq -r '.stagedEntries // 0' 2>/dev/null)
    [[ "$_cands" =~ ^[0-9]+$ ]] || _cands=-1
    [[ "$_staged" =~ ^[0-9]+$ ]] || _staged=0
    if (( _cands < 0 ))
    then
        __tac_info "Memory" "[$_agent: ok:true but candidateCount unreadable - refusing its RESET]" "$C_Error"
        __oc_purge_stderr "$_bf"
        return 1
    fi

    _idx_after=$(__oc_purge_memory_index_rows "$_db")
    [[ -f "$_ws/DREAMS.md" ]] && _dreams_after=$(sha256sum "$_ws/DREAMS.md" | cut -d' ' -f1)

    # Promotion into MEMORY.md is OFFLINE-ONLY, so it is NOT attempted here: this function runs
    # while the Gateway serves and is called per agent.  __oc_purge_memory_promote_all does the
    # whole fleet inside ONE offline window -- stopping the Gateway once per agent would be
    # fourteen restarts for no gain.  The verdict below says which arm carried the proof.
    local _promote_state="pending offline pass"

    # THE GATE.  0 = a durable artefact was proven, 2 = ok:true and nothing to do, 1 = REFUSE.
    # The three are kept apart because the caller must act differently on 2 (nothing was
    # staged, so a promote has nothing to carry) and on 1 (refuse the reset).
    if (( _idx_after > _idx_before ))
    then
        local _msg="[$_agent: $_idx_before -> $_idx_after indexed source(s), ${_cands} candidate(s),"
        _msg+=" ${_staged} staged; MEMORY.md promote $_promote_state]"
        __tac_info "Memory" "$_msg" "$C_Dim"
        return 0
    fi
    if [[ -n "$_dreams_after" && "$_dreams_after" != "$_dreams_before" ]]
    then
        local _msg="[$_agent: DREAMS.md updated, ${_cands} candidate(s), ${_staged} staged;"
        _msg+=" MEMORY.md promote $_promote_state]"
        __tac_info "Memory" "$_msg" "$C_Dim"
        return 0
    fi
    # Zero candidates is "nothing to do" ONLY because the body said ok:true two checks above --
    # never as a fallback for a body that could not be read.
    if (( _cands == 0 ))
    then
        __tac_info "Memory" \
            "[$_agent: body applied, 0 candidates (history already processed); promote $_promote_state]" "$C_Dim"
        return 2   # 2 = nothing to do (ok:true, no candidates); NOT a refusal, NOT a pass
    fi
    __tac_info "Memory" \
        "[$_agent: $_cands candidate(s) reported but NOTHING durable changed - refusing its RESET]" "$C_Error"
    return 1
}

# __oc_purge_memory_promote_all — run the offline-only `memory promote --apply` for every agent
# that will be reset, inside ONE offline window (one stop, one guaranteed restart).
#
# This is the step that makes backfill's staged candidates DURABLE in MEMORY.md.  Without it a
# purge leaves them staged in the agent store and the promise "still able to access their
# memories" is met only by tables the agent cannot read as prose.  Wayne authorised the stop on
# 2026-11-25T19:06Z: "i dont mind purge closing the gateway as long as it starts again."
#
# THE RESET DOES NOT WAIT ON THIS.  The gate that decides whether an agent may be reset is
# __oc_purge_memory_flush, which runs online and has already proven durable staging.  Promotion
# is an UPGRADE of the same facts into prose, not the only place they exist -- so a promote that
# fails is reported and counted, and it does not license a refusal to reset an agent whose
# staging landed.  Saying that plainly matters: it is the difference between "memory preserved"
# and "memory preserved in a form the next session reads first".
function __oc_purge_memory_promote_all() {
    local -a _agents=("$@")
    local _key _a
    if [[ ${#_agents[@]} -eq 0 ]]
    then
        while IFS= read -r _key
        do
            [[ "$_key" == *:main ]] || continue
            _a="${_key#agent:}"; _a="${_a%%:*}"
            _agents+=("$_a")
        done < <(__oc_purge_session_keys)
    fi
    if [[ ${#_agents[@]} -eq 0 ]]
    then
        __tac_info "Memory" "[no agents to promote]" "$C_Dim"
        return 0
    fi

    # WHY THIS SETS THE ENVIRONMENT (v46).  `openclaw memory promote` is admitted only with
    # exclusive offline state ownership, and the WHOLE `memory` family routes through
    # `memory.cli`, which the CLI will not admit while a Gateway lives -- measured 2026-11-26:
    # `openclaw memory status --json` with the Gateway serving answers "Cannot admit memory.cli
    # ... requires exclusive offline state ownership".  Meanwhile its secret targets (the
    # embedding provider apiKey, a SecretRef of source "env") are resolved through the Gateway
    # when one is up.  The two admission rules are mutually exclusive on this box, which is why
    # the 2026-11-25 run promoted nothing: 14/14 lanes logged
    #   [secrets] memory promote: gateway secrets.resolve unavailable (ECONNREFUSED)
    # The one lever this command has is to make the CLI's LOCAL resolution path work.  The unit
    # loads $HOME/.openclaw/gateway.systemd.env through EnvironmentFile=, but a CLI process does
    # not read that file, so OPENCLAW_EMBEDDING_API_KEY is simply absent to it.  Sourcing the
    # same file into the window's environment gives loadMemoryCommandConfig what it needs to
    # resolve locally instead of calling the Gateway.  This changes HOW the window invokes the
    # command; it does not change OpenClaw's admission rules.
    local _envfile="${OPENCLAW_ENV_FILE:-$HOME/.openclaw/gateway.systemd.env}"
    if [[ -f "$_envfile" ]]
    then
        set -a
        # The target is a RUNTIME path (`$_envfile`), so shellcheck cannot follow it; the
        # `source=` directive names that fact instead of muting the diagnostic, which is the
        # form this repo's suppression ratchet asks for (tests/tactical-console-fast.bats,
        # "shellcheck suppressions ratchet DOWN"). A `disable=SC1090` here would have been the
        # 17th suppression against a baseline of 16 — i.e. it would have raised a number the
        # ratchet exists to lower.
        # shellcheck source=/dev/null
        # swallow-ok: a failed source is reported by the arm on the same construct
        . "$_envfile" 2>/dev/null \
            || __oc_purge_stderr "(could not source $_envfile; promote may not resolve its secret)"
        set +a
    fi

    # The command the offline window runs: one `memory promote --apply` per agent, counting
    # a body that says ok:false as a failure even when the CLI exited 0.
    _oc_promote_pass() {
        local _ag _out _json _ok=0 _none=0 _bad=0
        local _mem _sha_before _sha_after
        for _ag in "${_agents[@]}"
        do
            _mem="$HOME/.openclaw/workspace-$_ag/MEMORY.md"
            _sha_before=""
            [[ -f "$_mem" ]] && _sha_before=$(sha256sum "$_mem" | cut -d' ' -f1)
            if ! _out=$(timeout -k 10 300 openclaw memory promote --agent "$_ag" --apply --json 2>&1)
            then
                _bad=$(( _bad + 1 ))
                __oc_purge_stderr "$_out"
                continue
            fi
            # A SUCCESS CODE IS NOT A SUCCESS (v46), AND NEITHER IS A FIELD I ASSUMED (v48).
            # Measured 2026-11-26 in a real offline window: `memory promote --json` DOES NOT
            # EMIT AN `ok` FIELD AT ALL.  Its keys are
            #   workspaceDir, storePath, lockPath, audit, candidates[, apply]
            # so v46's `.ok == true` was FALSE ON EVERY SUCCESSFUL RUN -- a gate that cannot
            # pass, which is the same class of defect it was written to repair.  The success
            # spelling here is the presence of the body's own structure plus a measured write.
            # `[secrets]` chatter goes to stderr and is merged by 2>&1, so the JSON starts at
            # the first line beginning with '{'.
            _json=$(printf '%s\n' "$_out" | sed -n '/^{/,$p')
            if ! printf '%s' "$_json" \
                | jq -e 'has("workspaceDir") and has("audit") and has("candidates")' >/dev/null 2>&1
            then
                _bad=$(( _bad + 1 ))
                __oc_purge_stderr "$_out"
                continue
            fi
            # A BODY THAT NAMES AN ERROR IS A FAILURE EVEN WITH THE STRUCTURE PRESENT.
            if printf '%s' "$_json" | jq -e '.error != null' >/dev/null 2>&1
            then
                _bad=$(( _bad + 1 ))
                __oc_purge_stderr "$_out"
                continue
            fi
            _sha_after=""
            [[ -f "$_mem" ]] && _sha_after=$(sha256sum "$_mem" | cut -d' ' -f1)
            # THE WRITE IS THE PROOF, NOT THE COUNT.  `.apply.applied` counts candidates the
            # scorer accepted; MEMORY.md growing is the only thing a next session can read.
            if [[ -n "$_sha_after" && "$_sha_after" != "$_sha_before" ]]
            then
                _ok=$(( _ok + 1 ))
            else
                # NOT A FAILURE, AND NOT SILENT.  Measured 2026-11-26: every lane's candidates
                # score BELOW the 0.75 default (hal tops at 0.486, finn 0.695, sarah 0.512) and
                # `uniqueQueries` reads 0 for all of them, so the diversity component is
                # structurally zero.  The honest wording for that is "nothing qualified", and
                # reporting it as FAILED would make the fleet look broken when it is the
                # promotion threshold that is unreachable.
                _none=$(( _none + 1 ))
            fi
        done
        if (( _bad > 0 ))
        then
            __tac_info "Memory" \
                "[MEMORY.md promote: $_ok written, $_none nothing qualified," \
                " $_bad FAILED of ${#_agents[@]} - body+sha]" \
                "$C_Error"
            return 1
        fi
        if (( _none > 0 ))
        then
            __tac_info "Memory" \
                "[MEMORY.md promote: $_ok written, $_none nothing qualified" \
                " of ${#_agents[@]} - below threshold, not an error]" \
                "$C_Warning"
            return 0
        fi
        __tac_info "Memory" \
            "[MEMORY.md promote: $_ok written of ${#_agents[@]} - MEMORY.md sha changed, not rc]" "$C_Success"
        return 0
    }

    # ASK WHETHER PROMOTE CAN BE ADMITTED AT ALL before opening the window on a guess.
    if ! __oc_purge_promote_possible "${_agents[0]}"
    then
        __tac_info "Memory" \
            "[promote DID NOT RUN - memory.cli is offline-only, its secret cannot resolve" \
            " offline; MEMORY.md unchanged]" "$C_Error"
        return 1
    fi

    __oc_purge_offline_window _oc_promote_pass
    local _rc=$?
    if (( _rc != 0 ))
    then
        __tac_info "Memory" "[promote pass INCOMPLETE - memory is staged but the prose was not written]" "$C_Error"
    fi
    return $_rc
}

# __oc_purge_promote_possible — 0 when `memory promote` can be admitted at all on this box.
# The probe asks OpenClaw and classifies its own answer, rather than predicting it: the refusal
# text names which admission rule refused, and an unreadable answer is NOT taken as an
# admission (a window that did not open must not be reported as one).
# It is called from INSIDE the offline window, where "not admitted" can only mean the secret
# still could not resolve -- so the two refusals are reported separately, because their fixes
# are different.
function __oc_purge_promote_possible() {
    local _out=""
    # swallow-ok: the rc is not the verdict here; the body is matched on the next line
    _out=$(timeout -k 10 120 openclaw memory promote --agent "$1" --json 2>&1) || true
    if [[ "$_out" == *"requires exclusive offline state ownership"* ]]
    then
        __tac_info "Memory" "[promote probe: still not admitted - a Gateway still owns the state root]" "$C_Error"
        return 1
    fi
    # RECOGNISE THE SUCCESS SPELLING (v48, rule 27).  A WORKING offline promote STILL PRINTS
    # the phrase this probe used to reject on: measured 2026-11-26, the successful body's stderr
    # carries
    #   [secrets] memory promote: gateway secrets.resolve unavailable (ECONNREFUSED ...
    #   ); resolved command secrets locally.
    # The old arm matched on the first half and refused a promote that had already worked, so
    # the window never ran.  The distinguishing clause is the SECOND half: "resolved command
    # secrets locally" is the success spelling, and its absence is the failure.
    if [[ "$_out" == *"secrets.resolve unavailable"* && "$_out" != *"resolved command secrets locally"* ]]
    then
        __tac_info "Memory" \
            "[promote probe: offline, but the secret still cannot resolve - MEMORY.md cannot be written]" "$C_Error"
        return 1
    fi
    # The success shape is the body's own structure; `ok` is not among its fields.
    local _pjson
    _pjson=$(printf '%s\n' "$_out" | sed -n '/^{/,$p')
    if printf '%s' "$_pjson" | jq -e 'has("workspaceDir") and has("candidates")' >/dev/null 2>&1 \
        && ! printf '%s' "$_pjson" | jq -e '.error != null' >/dev/null 2>&1
    then
        return 0
    fi
    __oc_purge_stderr "$_out"
    return 1
}

# __oc_purge_offline_window — stop the Gateway so the offline-only memory writes can run, run
# the caller's command, then GUARANTEE the Gateway comes back.  Returns 1 if it could not
# restart, and says so loudly: a purge that leaves the fleet dark is worse than a purge that
# never ran.
#
# Wayne, 2026-11-25T19:06Z: "i dont mind purge closing the gateway as long as it starts again."
# That is a change of owner position.  v33 recorded "oc-purge NEVER stops or restarts the
# gateway" as a deliberate rule, and that rule was right for the reason it was written: the old
# version stopped the gateway to clear sessions/, which bought nothing.  This stop is different
# in kind -- `openclaw memory promote --apply` REFUSES while the Gateway owns the state root
# ("requires exclusive offline state ownership", measured 2026-11-25), so without an offline
# window the promote step can never run and the memory gate can only ever defer.
#
# The restart is a trap, not a following line: if the agent function dies, is interrupted, or
# the shell is told to exit, the Gateway still comes back.  A signal is not a bound unless the
# handler can land (rule 15), so the stop is bounded and the start is VERIFIED by asking
# `openclaw health`, not by `systemctl is-active` alone -- a unit can read active while the
# gateway is still binding its port.
function __oc_purge_offline_window() {
    local _svc="openclaw-gateway.service"
    local _cmd=("$@")
    if [[ ${#_cmd[@]} -eq 0 ]]
    then
        __tac_info "Offline" "[offline window: no command supplied]" "$C_Error"
        return 1
    fi
    # swallow-ok: an inactive or absent unit IS the "already offline" answer; the caller then runs the command and the promote refusal reports itself
    if ! systemctl --user is-active -q "$_svc" 2>/dev/null
    then
        # Already offline (a maintenance window, or a stopped box): just run the command.
        "${_cmd[@]}"
        return $?
    fi

    local _restarted=0 _rc=0
    # The trap target: start the Gateway and wait for the PREDICATE (`openclaw health`), not
    # for systemd's `active` word, which reads active while the port is still binding.
    __oc_purge_gateway_restore() {
        (( _restarted == 1 )) && return 0
        _restarted=1
        systemctl --user start "$_svc" >/dev/null 2>&1
        # Verify at the predicate: the unit can read active before the port answers.
        local _i
        for (( _i = 1; _i <= 60; _i++ ))
        do
            # swallow-ok: a health probe that fails IS the retry condition; the loop's exhaustion is what reports the failure, loudly
            if timeout 10 openclaw health >/dev/null 2>&1
            then
                __tac_info "Offline" "[Gateway restarted and ANSWERING]" "$C_Success"
                return 0
            fi
            sleep 3
        done
        __tac_info "Offline" "[GATEWAY DID NOT COME BACK - start it by hand: systemctl --user start $_svc]" "$C_Error"
        return 1
    }
    trap '__oc_purge_gateway_restore; trap - EXIT INT TERM' EXIT INT TERM

    __tac_info "Offline" "[stopping $_svc for the memory promote]" "$C_Dim"
    # swallow-ok: the exit status IS the decision (rc 0 = stopped, non-zero = still up); systemd's error text is not read here, the branch below reports the outcome
    if ! timeout -k 30 180 systemctl --user stop "$_svc" 2>/dev/null
    then
        # The stop did not land, so the Gateway is STILL UP.  Run the command online (promote
        # will refuse and defer, which is honest) and do NOT run the restore arm -- nothing was
        # stopped, so "restarting" would be a false report of a window that never opened.
        trap - EXIT INT TERM
        __tac_info "Offline" "[could not stop the Gateway - continuing online, promote will defer]" "$C_Warning"
        "${_cmd[@]}"
        return $?
    fi

    __tac_info "Offline" "[Gateway stopped - offline window open]" "$C_Dim"
    "${_cmd[@]}"
    _rc=$?
    __oc_purge_gateway_restore || return 1
    trap - EXIT INT TERM
    return $_rc
}

# __oc_purge_memory_index_rows — count the durable memory rows for a store, 0 when unreadable.
# Used only as a before/after reading, so an unreadable store reads 0 on both sides and the
# gate falls through to the candidate/DREAMS arms rather than passing on a phantom increase.
function __oc_purge_memory_index_rows() {
    local _db="${1:-}"
    [[ -f "$_db" ]] || { printf '0\n'; return 0; }
    local _n
    # The store read is a before/after witness only: an unreadable or absent store reads 0
    # on BOTH sides, so the gate falls through to the candidate/DREAMS arms rather than
    # passing on a phantom increase. The marker is inline because the scanner attaches a
    # marker only to the line directly below it, and the redirection is on the continued line.
    _n=$(timeout 30 sqlite3 "file:$_db?mode=ro" \
        "select count(*) from memory_index_sources;" 2>/dev/null) || _n=0  # swallow-ok: unreadable reads 0 both sides
    [[ "$_n" =~ ^[0-9]+$ ]] || _n=0
    printf '%s\n' "$_n"
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
    local _key _out="" _mains=0 _cron=0 _runs=0 _cls
    local -a _all=()
    # The KEPT classes are counted here for the report; the DELETE SET comes from
    # __oc_purge_delete_keys, the same function the dry run calls, so the preview cannot list a
    # set this batch does not perform.  Counting and selecting are deliberately separate: the
    # counts describe what was scanned, the batch acts on one derivation.
    while IFS= read -r _key
    do
        [[ -n "$_key" ]] || continue
        _all+=("$_key")
        _cls=$(__oc_purge_classify_key "$_key")
        # Counts describe what was SCANNED; the delete set comes from __oc_purge_delete_keys
        # below.
        case "$_cls" in
            # No `*` arm on purpose: a class this block does not name is simply not counted,
            # and a catch-all would make an unrecognised key look like a known one.
            main)    _mains=$(( _mains + 1 )) ;;   # CLI refuses mains; reset instead
            cronjob) _cron=$(( _cron + 1 ))   ;;   # automation state, kept (2026-10-23)
            cronrun) _runs=$(( _runs + 1 )) ;;     # one execution: deleted
        esac
    done < <(__oc_purge_session_keys)

    # ONE derivation of what is deleted.
    local -a _keys=()
    while IFS= read -r _key
    do
        [[ -n "$_key" ]] || continue
        _keys+=("$_key")
    done < <(__oc_purge_delete_keys)

    # THE BATCH IS PER AGENT (v46).  Measured 2026-11-25: one `sessions delete` over 21 keys, of
    # which the CLI refused a single `:run:` key it did not list, failed the WHOLE batch -- the
    # run printed "1 FAILED" and every cron-run transcript stayed in its store.  A fleet-wide
    # batch makes one unlisted key everyone's problem; per agent, a refusal is that agent's
    # failure and the other thirteen still land.  A refusal counts as a failure, never a skip.
    local _deleted=0 _dfail=0 _invisible=0 _agent _batch
    local -a _batch_keys=()
    local -A _seen=()
    for _key in "${_keys[@]}"
    do
        _agent="${_key#agent:}"; _agent="${_agent%%:*}"
        _seen["$_agent"]=1
    done
    for _agent in $(printf '%s\n' "${!_seen[@]}" | sort)
    do
        _batch_keys=()
        for _key in "${_keys[@]}"
        do
            [[ "${_key#agent:}" == "$_agent:"* ]] || continue
            _batch_keys+=("$_key")
        done
        (( ${#_batch_keys[@]} > 0 )) || continue
        local _ok_body=1 _exited_zero=1
        if ! _out=$(timeout -k 15 300 openclaw sessions delete "${_batch_keys[@]}" --yes --json 2>&1)
        then
            _ok_body=0
            _exited_zero=0
        elif ! printf '%s' "$_out" | jq -e '.ok != false' >/dev/null 2>&1
        then
            _ok_body=0
        fi
        if (( _ok_body == 1 ))
        then
            _deleted=$(( _deleted + ${#_batch_keys[@]} ))
        else
            # `not_found` IS NOT A REFUSAL (v50).  Measured 2026-11-26 in a real purge: 21 keys
            # answered `"status":"not_found"` while the store still held a `session_windows` row
            # for each, status `done`.  The CLI's delete reads a roster those rows are absent
            # from, so it cannot see them -- and `sessions cleanup --fix-missing` (which removes
            # store entries whose transcript files are gone) does not see them either, on the
            # same store.  The desired END STATE for a `:run:` key is "absent", and a key the CLI
            # reports not_found is already in that state from the CLI's point of view. Two very
            # different things share that answer, so they are counted apart:
            #   * EVERY key in the batch is not_found  -> the CLI could not see the batch at all.
            #     Not a failure it caused, and not a deletion: counted as INVISIBLE and reported
            #     with the store count that proves the rows still exist.
            #   * mixed / other errors                 -> a real refusal, counted as FAILED.
            # Closer to the socket than this would need the CLI to name why it cannot see a row
            # its own store holds; until then the honest report is "N invisible", with the
            # store row count as the witness.
            local _nf
            # swallow-ok: a failed parse reads 0 on the next line (nothing was invisible)
            _nf=$(printf '%s' "$_out" | jq -r '[.results[]? | select(.status=="not_found")] | length' 2>/dev/null)
            [[ "$_nf" =~ ^[0-9]+$ ]] || _nf=0
            # AN UNPARSEABLE BODY IS NOT EVIDENCE OF A REFUSAL (v51).  The batch is only sent
            # for keys the store holds AND the classifier did not keep, so the CLI's `not_found`
            # answer is the shape a key it cannot describe takes.  When the body says nothing at
            # all, that answer is indistinguishable from `not_found` -- and the honest thing is
            # to ask the STORE, which is the witness the read-back already uses, rather than to
            # call 14 healthy agent stores "REFUSED" because their CLI prints no JSON.  Measured
            # 2026-11-26: a delete mock with no body made a correct purge report 1 FAILED.
            #   empty or unparsed body -> the keys still sit in the store, so they are counted
            #                             INVISIBLE (reported with the store count) unless the
            #                             store no longer holds them, in which case they are
            #                             counted DELETED.
            # A NON-ZERO EXIT IS A REFUSAL (v51).  The silent-body arm is for a CLI that exited
            # 0 and said nothing -- the shape a `not_found` batch takes when its report is
            # empty.  A CLI that exited non-zero HAS refused, whatever it printed, and asking
            # the store then would relabel the refusal as "invisible".  Measured 2026-11-26: the
            # mixed-batch case (one agent refused, one landed) read 2 refusals instead of 1.
            if (( _exited_zero == 1 )) && ! printf '%s' "$_out" | jq -e '.' >/dev/null 2>&1
            then
                local _gone=0
                for _key in "${_batch_keys[@]}"
                do
                    # `case "$(fn)"` CANNOT SEE THE STATUS (measured: an empty substitution
                    # matches `*)`, so a 0 that prints nothing fell through to the failure arm).
                    # Capture first, then branch on the code.
                    __oc_purge_store_still_holds "$_key"
                    # 0 = still stored -> invisible; 1 = gone -> deleted; 2 = unreadable
                    # -> a failure.  The codes are the helper's interface, named here.
                    case "$?" in
                        0) : ;;
                        1) _gone=$(( _gone + 1 )) ;;
                        *) _dfail=$(( _dfail + 1 ))
                           __tac_info "Sessions" \
                               "[$_agent: cannot read the store back for $_key]" "$C_Error" ;;
                    esac
                done
                _deleted=$(( _deleted + _gone ))
                _invisible=$(( _invisible + ${#_batch_keys[@]} - _gone - _dfail ))
                continue
            fi
            if (( _nf == ${#_batch_keys[@]} ))
            then
                _invisible=$(( _invisible + _nf ))
            else
                _dfail=$(( _dfail + 1 ))
                __tac_info "Sessions" \
                    "[$_agent: delete REFUSED for ${#_batch_keys[@]} key(s) - reported, not claimed]" "$C_Error"
                __oc_purge_stderr "$_out"
            fi
        fi
    done

    printf '%s %s %s %s %s %s\n' "$_deleted" "$_mains" "$_cron" "$_runs" "$_dfail" "$_invisible"
    (( ${#_keys[@]} == 0 )) && return 0
    (( _dfail == 0 )) || return 1
    return 0
}

# __oc_purge_stderr — the one place this command writes a diagnostic to stderr, so a
# scan whose stdout is the RESULT list cannot be corrupted by its own warnings.
function __oc_purge_stderr() {
    # An EMPTY body has nothing to report.  Callers pass the CLI's captured output even
    # when the CLI printed none — a refusal with a silent body leaves it "" — and
    # `printf '%s\n' ""` then writes a bare newline.  Measured 2026-11-26: that phantom
    # line prepended an empty first line to the delete report, so its own regression test
    # (which pins the report line exactly) failed on noise rather than on a count.
    [[ -n "${1:-}" ]] || return 0
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

# __oc_purge_store_left_count — print how many session_windows rows across ALL agent stores
# are neither a main nor a cron JOB (i.e. the class this command claims to have removed).
# Exit 1 when a store cannot be read, so "could not tell" is never reported as 0 -- the same
# rule the orphan prune follows, for the same reason.
#
# WHY A SECOND COUNT EXISTS (v46).  The CLI roster omits rows the stores still hold, so a
# verify that reads only the roster can be green while the defect is present.  Measured
# 2026-11-25: roster said 0 non-main sessions, stores held 21 `:run:` rows.
function __oc_purge_store_left_count() {
    local _db _n _total=0 _bad=0
    for _db in "$OC_AGENTS"/*/agent/openclaw-agent.sqlite
    do
        [[ -f "$_db" ]] || continue
        if ! _n=$(timeout -k 10 30 sqlite3 "file:$_db?mode=ro" \
            "select count(distinct session_key) from session_windows;")
        then
            _bad=$(( _bad + 1 )); continue
        fi
        [[ "$_n" =~ ^[0-9]+$ ]] || { _bad=$(( _bad + 1 )); continue; }
        # Count the class here rather than in SQL: the classifier is ONE shell function, and a
        # second implementation in SQL is exactly the drift this file has already paid for.
        while IFS= read -r _key
        do
            [[ -n "$_key" ]] || continue
            case "$(__oc_purge_classify_key "$_key")" in
                main|cronjob) : ;;
                *) _total=$(( _total + 1 )) ;;
            esac
        done < <(timeout -k 10 30 sqlite3 "file:$_db?mode=ro" \
            "select distinct session_key from session_windows;")
    done
    printf '%s\n' "$_total"
    (( _bad == 0 ))
}

# __oc_purge_store_left_keys — the population __oc_purge_store_left_count counts, as KEYS (one
# per line, de-duplicated across stores).  A count cannot answer the question the read-back now
# asks -- "of these leftovers, which can the gateway actually see?" -- so the keys have to
# travel.  The classifier is the same shell function the delete uses; there is no second
# implementation.
# __oc_purge_store_still_holds — 0 = the key still has a row in its store, 1 = it does not,
# 2 = the store could not be read.  The three are kept apart for the same reason the census
# keeps them apart: "could not tell" must never be reported as either answer.  Used by the
# delete arm when the CLI returns no parseable body, so a silent CLI is resolved against the
# STORE rather than against a guess about what it meant.
function __oc_purge_store_still_holds() {
    local _key="$1"
    local _db _n
    _db=$(__oc_purge_agent_store "$_key")
    # 2 = the store could not be read; never reported as either answer
    [[ -n "$_db" && -f "$_db" ]] || return 2
    # swallow-ok: an unreadable store is code 2 below, never "gone" or "still stored"
    _n=$(timeout -k 10 30 sqlite3 "file:$_db?mode=ro" \
        "select count(*) from session_windows where session_key='$_key';" 2>/dev/null)  # swallow-ok: rc below
    # 2 = the read failed (the assignment carries sqlite3's status)
    [[ $? -eq 0 ]] || return 2
    # 2 = the store answered with something that is not a count
    [[ "$_n" =~ ^[0-9]+$ ]] || return 2
    (( _n > 0 )) && return 0
    return 1
}

# __oc_purge_store_left_keys — the leftover keys themselves.
function __oc_purge_store_left_keys() {
    local _db _key
    for _db in "$OC_AGENTS"/*/agent/openclaw-agent.sqlite
    do
        [[ -f "$_db" ]] || continue
        # swallow-ok: an unreadable store contributes no keys; the census refuses such a run
        timeout -k 10 30 sqlite3 "file:$_db?mode=ro" \
            "select distinct session_key from session_windows;" 2>/dev/null  # swallow-ok: unreadable -> no keys
    done | sed '/^[[:space:]]*$/d' | sort -u | while IFS= read -r _key
    do
        case "$(__oc_purge_classify_key "$_key")" in
            main|cronjob) : ;;
            *) printf '%s\n' "$_key" ;;
        esac
    done
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

# __oc_purge_rpc_capture — as __oc_purge_rpc, but leaves the body in __OC_PURGE_RPC_OUT so a
# caller can tell WHICH refusal it got.  The tombstone refusal is not a generic failure: it
# has its own supported path, and treating it as "failed" hides the only remedy there is.
function __oc_purge_rpc_capture() {
    local _method="$1"
    local _params="$2"
    __OC_PURGE_RPC_OUT=""
    if ! __OC_PURGE_RPC_OUT=$(timeout -k 15 120 openclaw gateway call "$_method" \
        --params "$_params" --json 2>&1)
    then
        __oc_purge_stderr "$__OC_PURGE_RPC_OUT"
        return 1
    fi
    if ! printf '%s\n' "$__OC_PURGE_RPC_OUT" | jq -e '.ok == true' >/dev/null 2>&1
    then
        __oc_purge_stderr "$__OC_PURGE_RPC_OUT"
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
    if ! __oc_purge_rpc_capture "sessions.reset" "$_params"
    then
        # A build that TOMBSTONES a main (restart recovery) refuses this reset with
        # "ended during restart recovery. Use /new or /reset" — the reset is refused BY the
        # tombstone, so retrying it is the one thing that cannot work.  `sessions.recover` is
        # the supported replacement path: it starts a continuation in a NEW session.
        # Measured 2026-10-29 on 2026.10.10-beta.4: recover returns ok and creates that
        # successor, and the tombstone row REMAINS (the lane still reads `failed`, and the
        # doctor's wedged count is unchanged).  So this returns 4 — successor started,
        # tombstone still set — and NEVER reports a repair.
        if [[ "$__OC_PURGE_RPC_OUT" == *"ended during restart recovery"* ]]
        then
            local _rec_params
            _rec_params=$(jq -cn --arg k "$_key" '{key:$k}') || return 1
            if __oc_purge_rpc "sessions.recover" "$_rec_params"
            then
                return 4   # 4 = successor started, tombstone left set
            fi
            return 1
        fi
        return 1
    fi
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
# __oc_purge_reset_scope — the reset scope, derived in ONE place so the preview and the real
# run cannot disagree.  Measured defect (2026-10-29): the dry run read
# ${OC_PURGE_RESET_MAIN-hal} while the real run read ${OC_PURGE_RESET_MAIN-all}, so with the
# variable UNSET the preview named one main and the run reset all fourteen.
#   unset -> "all" (every main) · explicit empty -> "" (reset disabled) · "all" -> "all"
#   any other value -> that agent's name
function __oc_purge_reset_scope() {
    printf '%s\n' "${OC_PURGE_RESET_MAIN-all}"
}

# __oc_purge_self_agent — the agent whose main session owns THIS shell, or nothing.
#
# WHY (measured 2026-11-26, D6 in workspace-hal/reports/2026-11-26-oc-purge-plan.md). The
# reset loop walks `__oc_purge_session_keys | grep -E ':main$' | sort -u`, i.e. alphabetical:
# aris, chief, del, finn, hal, jarvis, ...  The 14:47 run was launched from hal's own main, so
# the FIFTH reset (hal, 14:51:34) terminated the agent turn that owned the exec running the
# loop -- holderSignalAborted=true on a 57.6-minute holder -- and the run stopped there. Five
# of fourteen mains were reset; nine kept their pre-run ids; phase 2 never opened because the
# process that would have stopped the gateway was gone. A destructive command must not be
# able to kill its own driver, so purge REFUSES to reset the main it is itself running in.
#
# Detection has to work from inside a tool shell. Measured 2026-11-26, in that order:
#   - the environment carries no agent id: the gateway's own environ has OPENCLAW_SERVICE_*
#     but no OPENCLAW_AGENT_ID, and the tool shell inherits exactly that;
#   - the ancestry carries none either: /proc walk upward is exec-tool bash -> spawn-broker
#     worker.js -> service-child-group-anchor.js -> openclaw-gateway -> systemd --user, and no
#     link names a lane;
#   - `openclaw sessions --all-agents --json` exposes no run state (sessionStartedAt, totals,
#     participants -- no `state`, no holder), so it cannot say which main is executing.
# A control that must GUESS which lane it is about to destroy is the defect, not the fix.
# So the caller declares itself, and the run REFUSES rather than guessing when it is
# unset — the same shape as promote's offline gate: no unambiguous identity, no destructive
# phase. Leaving the whole reset phase to a human `OC_PURGE_SELF_AGENT=` is loud and safe;
# resetting the wrong lane during an unattended nightly sweep is silent, and this command's
# own history is fourteen mains emptied in alphabetical order up to the point the driver died.
#
#   OC_PURGE_SELF_AGENT=<id>   the lane whose main is THIS shell's driver: it is skipped
#   OC_PURGE_SELF_AGENT=""     declares "no driver lane" (a human at a terminal, a detached unit)
#   unset                      the caller did not say, so the reset phase REFUSES and names it
#
# OC_PURGE_ALLOW_SELF_RESET=1 overrides the skip for a detached driver that genuinely wants all
# fourteen; it is the only way the invoking lane's main is emptied while it is still live.
function __oc_purge_self_agent() {
    if [[ -n "${OC_PURGE_SELF_AGENT+set}" ]]
    then
        printf '%s\n' "${OC_PURGE_SELF_AGENT}"
        return 0
    fi
    return 1
}

# __oc_purge_owns_cgroup — is this shell INSIDE the gateway's own service cgroup?
#
# WHY (measured 2026-11-26, D7). `openclaw-gateway.service` is `KillMode=mixed`, and a tool
# shell spawned by an agent turn runs in that service's cgroup: measured /proc/self/cgroup on
# this very exec returned exactly the unit's ControlGroup. A `systemctl --user stop` therefore
# SIGKILLs the whole cgroup, so phase 2's offline window ends the purge in the middle of the
# run — the same defect as D6 through a different mechanism (D6 was one RPC; D7 is the stop
# that phase 2 exists to perform). Co-location is a FACT, not a guess, so this is measurable
# without the caller declaring anything: read /proc/self/cgroup and compare it to the unit.
#
# This does NOT refuse. A run that cannot open the window simply does not promote, and says so:
# promote is the one phase that needs the gateway down, and skipping it leaves MEMORY.md
# unchanged rather than half-written.
function __oc_purge_owns_cgroup() {
    local _mine="" _unit=""
    # swallow-ok: an unreadable cgroup file is a refusal, handled by the || return 1
    _mine=$(sed -n 's/^0:://p' /proc/self/cgroup 2>/dev/null | head -n 1) || return 1
    # swallow-ok: as above; the same || return 1 handles it
    _unit=$(systemctl --user show openclaw-gateway.service -p ControlGroup --value 2>/dev/null) \
        || return 1
    [[ -n "$_mine" && -n "$_unit" && "$_mine" == "$_unit" ]]
}

# __oc_purge_store_census — count readable agent stores, and FAIL when the census is
# incomplete.  Every key list here starts from a store read, so an unreadable store makes the
# delete list shorter and the dry run LESS alarming than the truth — the failure is silent in
# the one direction that matters.  Measured 2026-10-29: with sqlite3 absent the dry run
# printed 14 unreadable tombstones and still ended "Purge Complete", because nothing counted
# the failures.  A banner is not evidence; this is the check that can refuse.
function __oc_purge_store_census() {
    local _db _total=0 _bad=0 _out=""
    if ! command -v sqlite3 >/dev/null 2>&1
    then
        __tac_info "Stores" "[sqlite3 NOT FOUND - the store census cannot be read]" "$C_Error"
        return 1
    fi
    for _db in "$OC_AGENTS"/*/agent/openclaw-agent.sqlite
    do
        [[ -f "$_db" ]] || continue
        _total=$(( _total + 1 ))
        if ! _out=$(timeout -k 10 30 sqlite3 "file:$_db?mode=ro" \
            "select count(*) from sqlite_master;" 2>&1)
        then
            _bad=$(( _bad + 1 ))
            __tac_info "Stores" "[unreadable] $_db" "$C_Error"
            __oc_purge_stderr "$_out"
        fi
    done
    __tac_info "Stores" "[$(( _total - _bad ))/$_total readable]" "$C_Dim"
    (( _bad == 0 ))
}

function oc-purge() {
    if [[ "$__TAC_OPENCLAW_OK" != "1" ]]; then
        # DEFECT E (2026-11-25): __TAC_OPENCLAW_OK is probed once at source time and cached in
        # /dev/shm for 300 s, so ONE transient failure makes purge refuse with "[NOT INSTALLED]"
        # for up to five minutes.  Measured: in a clean cache dir purge refused while
        # `openclaw --version` printed 2026.11.10 and returned 0 in the same shell.  A
        # housekeeping command that refuses for minutes after a blip is indistinguishable from
        # a broken one.  So RE-PROBE before refusing, bypassing the cache, and say which check
        # answered -- the cache was never the authority, only a shortcut.
        if command -v openclaw >/dev/null 2>&1 && timeout -k 5 30 openclaw --version >/dev/null 2>&1
        then
            __tac_info "OpenClaw" "[cached probe said NOT INSTALLED; live re-probe OK - continuing]" "$C_Warning"
            __TAC_OPENCLAW_OK=1
        else
            __tac_info "OpenClaw" "[NOT INSTALLED - cannot purge sessions]" "$C_Error"
            __tac_info "OpenClaw" "[re-probed live: openclaw --version also failed - the refusal is real]" "$C_Dim"
            return 1
        fi
    fi

    # Validate OC_AGENTS path — prevent catastrophic rm -rf
    if [[ -z "$OC_AGENTS" || "$OC_AGENTS" == "/" || ! "$OC_AGENTS" =~ ^(/home|/dev/shm|/tmp) ]]; then
        __tac_info "Purge" "[REFUSED - unsafe OC_AGENTS path: ${OC_AGENTS:-(empty)}]" "$C_Error"
        return 1
    fi

    local _dry_run=0
    [[ "${1:-}" == "--dry-run" ]] && _dry_run=1

    # A key list built on an unreadable store understates what this command deletes, and the
    # dry run is where that matters most: its job is to let the owner see the blast radius.
    if ! __oc_purge_store_census
    then
        __tac_info "Purge" \
            "[REFUSED - an agent store could not be read, so this run's blast radius would be UNDERSTATED]" \
            "$C_Error"
        return 1
    fi

    # --dry-run reads only: it names the session KEYS and the directories, and it does
    # not touch the gateway.  The old code stopped the gateway before deciding it was a
    # dry run, which is a side effect the name denies.
    if (( _dry_run == 1 ))
    then
        local _agent_dir _key _tb_recovered _reset_scope _dry_key
        # The destructive arm lists every KEY it would delete.  Its old form printed one summary
        # line while every other arm listed keys -- so the one irreversible action was the one
        # with no preview (Wayne, 2026-11-25: "i don't think it works properly").  Derived from
        # the same __oc_purge_delete_keys the real run uses, so a preview cannot diverge from it.
        local _dcount=0
        while IFS= read -r _key
        do
            [[ -n "$_key" ]] || continue
            _dcount=$(( _dcount + 1 ))
            __tac_info "Session" "[WOULD DELETE] $_key" "$C_Dim"
        done < <(__oc_purge_delete_keys)
        if (( _dcount == 0 ))
        then
            __tac_info "Sessions" "[WOULD DELETE nothing - no deletable sessions]" "$C_Dim"
        else
            __tac_info "Sessions" "[WOULD DELETE $_dcount session(s) listed above]" "$C_Dim"
        fi
        while IFS= read -r _key
        do
            case "$(__oc_purge_classify_key "$_key")" in
                main)           __tac_info "Session" "[WOULD KEEP - agent main] $_key" "$C_Dim" ;;
                cronjob)        __tac_info "Session" "[WOULD KEEP - cron job] $_key" "$C_Dim" ;;
                *)              : ;;
            esac
        done < <(__oc_purge_session_keys)
        _reset_scope=$(__oc_purge_reset_scope)
        # The driver's own main is SKIPPED, and the preview must say so too: a dry run that
        # promises fourteen resets and a real run that performs thirteen is the same
        # preview/run disagreement the single-derivation rule above exists to prevent. An
        # UNDECLARED caller does not suppress the list -- it is listed as WOULD RESET and the
        # phase is flagged REFUSED above it, because a preview's job is to show what the run
        # would do if admitted, and the refusal is what the run actually does.
        local _self="" _self_rc=0
        if [[ "${OC_PURGE_ALLOW_SELF_RESET:-0}" == "1" ]]
        then
            _self=""
        else
            _self=$(__oc_purge_self_agent)
            _self_rc=$?
        fi
        if (( _self_rc != 0 ))
        then
            __tac_info "Sessions" \
                "[WOULD REFUSE the reset phase - OC_PURGE_SELF_AGENT is unset; name the driving lane]" \
                "$C_Error"
        elif [[ -n "$_self" ]]
        then
            __tac_info "Sessions" \
                "[WOULD KEEP - agent:$_self:main is this run's own driver]" "$C_Warning"
        fi
        if [[ -n "$_reset_scope" ]]
        then
            if [[ "$_reset_scope" == "all" ]]
            then
                __tac_info "Sessions" "[WOULD RESET every agent main to empty]" "$C_Dim"
            else
                __tac_info "Sessions" "[WOULD RESET - main left empty] agent:$_reset_scope:main" "$C_Dim"
            fi
            while IFS= read -r _dry_key
            do
                [[ "$_dry_key" == *:main ]] || continue
                if [[ "$_reset_scope" != "all" && "$_dry_key" != "agent:$_reset_scope:main" ]]
                then
                    continue
                fi
                [[ -n "$_self" && "$_dry_key" == "agent:$_self:main" ]] && continue
                __tac_info "Session" "[WOULD RESET] $_dry_key" "$C_Dim"
            done < <(__oc_purge_session_keys | grep -E ':main$' | sort -u)
        else
            __tac_info "Sessions" "[reset DISABLED - OC_PURGE_RESET_MAIN is set and empty]" "$C_Dim"
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

    local _pruned=0 _failed=0 _deleted=0 _mains=0 _cron=0 _resets=0 _repairs=0 _tombstoned=0
    # v54: the driving lane's own main, kept by design. Declared here because this function is
    # the one that increments it, and an undeclared counter is a shell error under `set -u`.
    local _self_skipped=0
    local _counts=""

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
    # swallow-ok: removing a cache file that may not exist is the intended state, not a failure — these are rebuilt on next read
    rm -f "$TAC_CACHE_DIR/oc_sessions.json" 2>/dev/null
    # swallow-ok: as above — an absent cache file is already the desired end state
    rm -f "$TAC_CACHE_DIR/oc_agents.json" 2>/dev/null
    # swallow-ok: as above — an absent cache file is already the desired end state
    rm -f "$TAC_CACHE_DIR/oc_agent_use.txt" 2>/dev/null
    # swallow-ok: as above — an absent cache file is already the desired end state
    rm -f "$TAC_CACHE_DIR/oc_agent_stats.tsv" 2>/dev/null

    # 3. Delete every stored session EXCEPT each agent's main and cron sessions.  The CLI
    #    refuses to delete a main ("Cannot delete the main session", measured 2026-10-18),
    #    and one refused key fails the whole batch; cron is automation state this command
    #    keeps (owner's call 2026-10-23), so neither may reach the batch.
    __tac_info "Sessions" "[reading keys and deleting non-main, non-cron sessions]" "$C_Dim"
    if ! _counts=$(__oc_purge_delete_sessions)
    then
        # A REFUSAL IS NOT THE ONLY REASON THIS ARM CAN RUN (v51).  The helper exits non-zero
        # when ONE agent's batch was refused, and it has already printed which agent and why.
        # The old wording claimed the whole delete failed, which it does not: the other thirteen
        # batches landed.  Say what the exit means and let the per-agent lines above name who.
        __tac_info "Sessions" \
            "[at least one agent's delete batch was REFUSED - see the line above naming it]" "$C_Error"
        _failed=$(( _failed + 1 ))
    else
        # FIVE FIELDS, NOT FOUR (v48).  __oc_purge_delete_sessions prints
        # "<deleted> <mains> <cron> <runs> <dfail>"; this read listed four names, so the LAST
        # variable absorbed the remainder and read "0 0".  `(( _runs > 0 ))` then became
        # `(( 0 0 > 0 ))` and bash printed "arithmetic syntax error in expression (error token
        # is \"0\")" into the middle of the purge report.  Measured 2026-11-26 in the 02 suite.
        # SIX FIELDS, AND THE COUNT MUST MATCH THE printf (v50).  v48 fixed the four-into-five
        # read; the report then gained a sixth field, so this line has to move with it or the
        # same arithmetic error comes back through the other door.
        local _runs=0 _dfail=0 _deleted=0 _mains=0 _cron=0
        read -r _deleted _mains _cron _runs _dfail _invisible <<< "$_counts"
        __tac_info "Sessions" "[$_deleted session key(s) deleted]" "$C_Dim"
        if (( _invisible > 0 ))
        then
            __tac_info "Sessions" \
                "[$_invisible run row(s) INVISIBLE to sessions delete - still in the stores]" "$C_Warning"
        fi
        # NOT "of those": `_runs` counts the cron-run keys that were SENT, and `_invisible`
        # counts the ones the CLI could not see.  Stacking the two readings is true only when
        # every run row was invisible, which is exactly the case that hid the arithmetic bug
        # v48 fixed.  State the two populations apart.
        if (( _runs > 0 ))
        then
            __tac_info "Sessions" "[$_runs cron RUN transcript(s) were in the delete set]" "$C_Dim"
        fi
        if (( _mains > 0 ))
        then
            __tac_info "Sessions" "[$_mains main session(s) KEPT - the CLI refuses to delete main]" "$C_Dim"
        fi
        if (( _cron > 0 ))
        then
            __tac_info "Sessions" "[$_cron cron JOB session(s) KEPT - automation state is not purge's]" "$C_Dim"
        fi
    fi

    # 3b-0. MEMORY FIRST, THEN CLEAR (Wayne, 2026-11-25), in the order the owner stated and the
    # code had inverted (v46).  The 2026-11-25T23:20Z run measured the inversion: promote ran
    # FIRST and offline, before a single backfill, and promoted nothing -- MEMORY.md was
    # untouched in all 14 workspaces.
    #   PHASE 1  ONLINE per-agent flush: `session-backfill --apply`, verified durable.  This is
    #            what decides whether an agent may be reset at all.
    #   PHASE 2  ONE offline window: `memory promote --apply` for every agent whose flush
    #            proved something, so the staged candidates become prose in MEMORY.md.
    #   PHASE 3  the resets, which need the Gateway back because they are RPC.
    # Phase 1 runs first because a promote before a flush has nothing to carry, and because the
    # resets must not happen until both have been given their chance.
    local -a _flush_ok=() _flush_skip=()
    local _flush_rc=0
    # THE SCOPE MUST EXIST BEFORE PHASE 1 READS IT (v50).  `_reset_scope` used to be assigned
    # further down, next to the reset loop, so at THIS line it was still empty -- and phase 1's
    # own filter `[[ "$_reset_scope" != "all" && "$_reset_key" != "agent::main" ]]` was true for
    # every key.  The loop therefore iterated ZERO times, `_flush_ok` stayed empty, and every
    # reset was skipped with "memory flush not proven" while the same function called by hand
    # returned 2 for all 14 agents.  Measured 2026-11-26 on three consecutive real runs; the
    # function was right and its caller's variable was not.
    local _reset_scope=""
    _reset_scope=$(__oc_purge_reset_scope)
    # THE DRIVER'S OWN MAIN IS EXCLUDED, AND AN UNDECLARED CALLER ABORTS THE DESTRUCTIVE PHASES
    # (v54, D6). Measured 2026-11-26 14:47-14:51: the run reset the five alphabetically-first
    # mains and then stopped, because the fifth was the main whose turn owned the exec running
    # the loop. A destructive run must not be able to kill its driver, and it must not guess
    # which lane that is: detection is impossible from inside a tool shell (no
    # OPENCLAW_AGENT_ID in the environment, no lane name in the /proc ancestry, no run state in
    # `sessions list`), so OC_PURGE_SELF_AGENT declares it and an unset value REFUSES. The
    # refusal happens BEFORE phase 1, so a mistyped run costs no flushes and no deletes.
    local _self="" _self_rc=0
    local _self_out=""
    if [[ "${OC_PURGE_ALLOW_SELF_RESET:-0}" != "1" ]]
    then
        # The status must be read from the substitution's own line: wrapping the call in an
        # `if` makes a non-zero return the BRANCH condition, and a `return 1` inside a braced
        # group there ends the whole command -- measured in the suite, where the refusal's
        # `return 1` propagated out of oc-purge and bats reported a function failure at this
        # line instead of a clean exit status.
        _self_out=$(__oc_purge_self_agent)
        _self_rc=$?
        _self="$_self_out"
        if (( _self_rc != 0 ))
        then
            __tac_info "Purge" \
                "[REFUSED - OC_PURGE_SELF_AGENT is unset: this run cannot tell whether it would reset its own driver]" \
                "$C_Error"
            __tac_info "Purge" \
                "[name the lane: OC_PURGE_SELF_AGENT=hal. EMPTY for a terminal/detached run." \
                "$C_Dim"
            return 1
        fi
    fi
    if [[ -n "$_self" && "$_reset_scope" == "all" ]]
    then
        __tac_info "Sessions" \
            "[agent:$_self:main is this run's driver and will be SKIPPED]" "$C_Warning"
    fi
    if [[ -n "$_reset_scope" ]] && (( ! _dry_run ))
    then
        __tac_info "Memory" "[phase 1/3: distilling session history per agent, online]" "$C_Dim"
        while IFS= read -r _reset_key
        do
            [[ "$_reset_key" == *:main ]] || continue
            if [[ "$_reset_scope" != "all" && "$_reset_key" != "agent:$_reset_scope:main" ]]
            then
                continue
            fi
            # The driving lane is not reset, so there is nothing to carry and nothing to
            # promote for it: flushing it would spend an offline window's worth of time on a
            # lane whose main is about to be reset by someone else, and its session is still
            # live so the flush's own read-back is meaningless.
            [[ -n "$_self" && "$_reset_key" == "agent:$_self:main" ]] && continue
            local _flush_agent="${_reset_key#agent:}"
            _flush_agent="${_flush_agent%%:*}"
            __oc_purge_memory_flush "$_flush_agent"
            _flush_rc=$?
            case "$_flush_rc" in
                0) _flush_ok+=("$_flush_agent") ;;
                2) _flush_ok+=("$_flush_agent") ;;
                *) _flush_skip+=("$_flush_agent") ;;
            esac
        done < <(__oc_purge_session_keys | grep -E ':main$' | sort -u)
        if (( ${#_flush_skip[@]} > 0 ))
        then
            __tac_info "Memory" \
                "[${#_flush_skip[@]} agent(s) cannot show a durable flush: ${_flush_skip[*]}]" "$C_Error"
        fi
    fi

    # 3b-0ii. PHASE 2: the one offline window.  It runs AFTER phase 1 and BEFORE the resets.
    local _promote_ok=1
    if (( ${#_flush_ok[@]} > 0 )) && (( ! _dry_run ))
    then
        # D7.  THE OFFLINE WINDOW WOULD KILL THIS RUN IF IT RUNS IN THE GATEWAY'S CGROUP.
        # Measured 2026-11-26: this exec's /proc/self/cgroup IS the unit's ControlGroup, and the
        # unit is KillMode=mixed, so `systemctl --user stop` SIGKILLs every process left in it —
        # including this one.  The window is the whole point of phase 2, so the run does not open
        # it from inside the cgroup; it says why and leaves MEMORY.md alone, which is the honest
        # half of the operation rather than a half-written one.
        if __oc_purge_owns_cgroup
        then
            _promote_ok=0
            __tac_info "Memory" \
                "[phase 2 SKIPPED - this run is inside the gateway's cgroup; stopping it would kill the run]" \
                "$C_Warning"
            __tac_info "Memory" \
                "[run the purge from a detached unit to get an offline promote: systemd-run --user --collect ...]" \
                "$C_Dim"
        else
            __tac_info "Memory" "[phase 2/3: promote into MEMORY.md inside one offline window]" "$C_Dim"
            __oc_purge_memory_promote_all "${_flush_ok[@]}" || _promote_ok=0
        fi
        # THE GATEWAY MUST BE SERVING BEFORE THE RESETS: they are RPC, and phase 2 owns a stop.
        if ! __oc_purge_ensure_serving
        then
            __tac_info "Purge" \
                "[REFUSED - the gateway did not come back from the offline window; no main was reset]" "$C_Error"
            return 1
        fi
    fi

    # 3b. Reset EVERY agent's main so each comes back EMPTY (owner's call 2026-10-24).
    #     `sessions delete` refuses a main, so the supported path is patch (only when
    #     archived) then reset, each bounded by the store's current session id and read
    #     back from the STORE.  `OC_PURGE_RESET_MAIN` narrows the scope to one agent when
    #     it names one; unset or `all` means every main.
    local _reset_key="" _tb_key="" _tb_recovered=""
    # _reset_scope is computed ABOVE, before phase 1 reads it; do not re-assign it here.
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
            # 3b-0. THE DRIVER IS NOT A CANDIDATE (v54, D6). Resetting this main ends the turn
            # that owns the shell running this loop, so the run stops wherever the driver sorts
            # in the key order -- measured as five of fourteen on 2026-11-26. It is a SKIP, not
            # a failure: nothing went wrong, the lane was deliberately kept, and the summary
            # says so.
            if [[ -n "$_self" && "$_reset_key" == "agent:$_self:main" ]]
            then
                _self_skipped=1
                __tac_info "Sessions" \
                    "[$_reset_key KEPT - this run's own driver; not reset]" "$C_Warning"
                continue
            fi
            # 3b-i. THE GATE'S VERDICT, from phase 1.  A flush that returned 1 refuses THIS
            # agent's reset; skipping the agent -- rather than aborting the run -- is deliberate:
            # a purge that dies on the first bad lane leaves the fleet half-purged.
            local _reset_agent="${_reset_key#agent:}"
            _reset_agent="${_reset_agent%%:*}"
            local _proven=0 _a
            for _a in "${_flush_ok[@]}"
            do
                [[ "$_a" == "$_reset_agent" ]] && _proven=1
            done
            if (( _proven == 0 ))
            then
                _failed=$(( _failed + 1 ))
                __tac_info "Sessions" "[$_reset_key reset SKIPPED - memory flush not proven]" "$C_Error"
                continue
            fi
            __oc_purge_reset_main "$_reset_key"
            _rc=$?
            case "$_rc" in
                0) _resets=$(( _resets + 1 ))
                   __tac_info "Sessions" "[$_reset_key reset - main kept, transcript empty]" "$C_Dim" ;;
                3) : ;;
                4) _tombstoned=$(( _tombstoned + 1 ))
                   __tac_info "Sessions" \
                       "[$_reset_key TOMBSTONED - successor started, tombstone REMAINS]" "$C_Warning" ;;
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
            4) _tombstoned=$(( _tombstoned + 1 ))
               __tac_info "Sessions" "[$_tb_key TOMBSTONED - successor started, tombstone REMAINS]" "$C_Warning" ;;
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

    # 5. Read the store back TWO ways (v46).  The 2026-11-25 run's verify arm read ONLY the CLI
    #    roster, which omits exactly the rows in question: it reported 0 "non-main, non-cron"
    #    sessions while 21 cron-RUN rows sat in the agent stores -- a green about a population
    #    that excludes the defect.  The roster is still read (it is the CLI's own view), and the
    #    STORES are counted too, because that is where a surviving row actually lives.  "Purge
    #    complete" is a claim about both, made from a fresh read, never from the delete's rc.
    local _roster_left="" _store_left=0 _roster_raw=""
    # PIPELINE STATUS IS jq's, NOT THE CLI's (v51).  The old form was
    # `if ! x=$(openclaw … | jq …)`: a substitution's status is the LAST element's, so a CLI that
    # died was hidden by a jq that exited 0 on empty stdin, and the "could not read the roster"
    # arm was unreachable for the half it names.  The CLI's own rc is taken on its own line now,
    # and a body that does not parse is a FAILURE rather than a silent zero.
    if ! _roster_raw=$(timeout -k 10 60 openclaw sessions --all-agents --json)
    then
        _failed=$(( _failed + 1 ))
        __tac_info "Sessions" "[could not read the roster back after delete]" "$C_Error"
    else
        _roster_left=$(printf '%s\n' "$_roster_raw" \
            | jq -r '[.sessions[]? | .key
                      | select((endswith(":main") or contains(":cron:"))|not)] | length' \
                2>/dev/null)  # swallow-ok: an unparseable body fails the numeric check below
        if [[ ! "$_roster_left" =~ ^[0-9]+$ ]]
        then
            _roster_left=""
            _failed=$(( _failed + 1 ))
            __tac_info "Sessions" "[the roster body could not be parsed as a session list]" "$C_Error"
        fi
    fi
    # The helper's rc does survive the assignment (measured: `x=$(f)` takes f's exit status), so
    # this arm reads the verdict directly.
    # The helper's rc survives the assignment (measured: `x=$(f)` takes f's status), so this
    # arm reads the verdict directly.
    _store_left=$(__oc_purge_store_left_count)
    local _store_rc=$?
    if (( _store_rc != 0 ))
    then
        _failed=$(( _failed + 1 ))
        __tac_info "Sessions" "[could not read the STORES back after delete]" "$C_Error"
    fi
    if [[ -n "$_roster_left" && "$_roster_left" != "0" ]]
    then
        _failed=$(( _failed + 1 ))
        __tac_info "Sessions" "[$_roster_left non-main session(s) still in the CLI ROSTER after delete]" "$C_Error"
    fi
    # A STORE ROW THE CLI CANNOT SEE IS NOT A SURVIVING SESSION (v51).
    # Measured 2026-11-26 on a real run and re-measured by hand the same day: 21 of the 31
    # delete candidates are `:run:` rows whose session_nodes entry is `{}` with
    # `entry_valid = -1`.  The gateway cannot describe them (`sessions.describe` returns
    # `{"session":null}`), the roster lists none of them, and `sessions delete` answers
    # `not_found` for every one -- so the delete arm above counted them INVISIBLE, and this
    # read-back then counted the same rows as EVIDENCE OF FAILURE.  The command deleted what
    # it could see, reported "N FAILED" for what it could not, and exited non-zero: an
    # unfixable red on every run, which is worse than no check.
    # They are a DIFFERENT population and get a different verdict:
    #   roster leftover > 0                     -> FAILED.  The CLI's own view says a session
    #                                              survived; that is this command's job.
    #   store rows the CLI could not see only   -> INVISIBLE, named, NOT counted as failed.
    #                                              Set OC_PURGE_INVISIBLE_IS_FAILURE=1 to make
    #                                              it fail for a scripted sweep that must prove
    #                                              the stores are empty.
    # The count is derived by asking the gateway, never by assuming: every leftover key that
    # `sessions.describe` cannot answer for is invisible, and any it CAN answer for is a
    # genuine survivor that fails the run.
    local _survivors=0 _invisible_left=0
    if [[ "$_store_left" =~ ^[0-9]+$ ]] && (( _store_left > 0 ))
    then
        local _lk _desc
        while IFS= read -r _lk
        do
            [[ -n "$_lk" ]] || continue
            # A kept key is not a leftover this check answers for: the classifier is the one
            # definition of "kept", and the `*` arm is its stated complement.
            case "$(__oc_purge_classify_key "$_lk")" in
                main|cronjob) continue ;;
                *) : ;;   # every other class is exactly what this loop is asking about
            esac
            # swallow-ok: a describe that fails is read as "not visible", the conservative arm
            _desc=$(timeout -k 10 30 openclaw gateway call sessions.describe \
                --params "$(jq -cn --arg k "$_lk" '{key:$k}')" --json 2>/dev/null)  # swallow-ok: read as not visible
            if printf '%s' "$_desc" | jq -e '.session != null' >/dev/null 2>&1
            then
                _survivors=$(( _survivors + 1 ))
                __tac_info "Sessions" "[STORED and visible - delete did not land] $_lk" "$C_Error"
            else
                _invisible_left=$(( _invisible_left + 1 ))
            fi
        done < <(__oc_purge_store_left_keys)
        if (( _survivors > 0 ))
        then
            _failed=$(( _failed + 1 ))
            __tac_info "Sessions" \
                "[$_survivors stored, gateway-visible session(s) survived the delete]" "$C_Error"
        fi
        if (( _invisible_left > 0 ))
        then
            if [[ "${OC_PURGE_INVISIBLE_IS_FAILURE:-0}" == "1" ]]
            then
                _failed=$(( _failed + 1 ))
                __tac_info "Sessions" \
                    "[$_invisible_left orphan store row(s) the CLI cannot see - failing as requested]" \
                    "$C_Error"
            else
                __tac_info "Sessions" \
                    "[$_invisible_left orphan store row(s) the CLI cannot see - NOT deleted, NOT a purge failure]" \
                    "$C_Warning"
                __tac_info "Sessions" \
                    "[their session_nodes entry is '{}' with entry_valid=-1]" "$C_Dim"
                __tac_info "Sessions" \
                    "[only a schema-level or Doctor repair removes them]" "$C_Dim"
            fi
        fi
    fi

    # THE BANNER'S OWN ACCUMULATOR MUST EXIST BEFORE IT IS APPENDED TO (v51).  `local _extra=""`
    # sat BELOW this block, so the memory clauses below appended to the GLOBAL `_extra` (whatever
    # the calling shell last left there), and the successful-looking line `[store reset, N
    # orphan(s) pruned, 1 main(s) reset]` -- measured live -- silently dropped every memory clause
    # to the `[Purge Complete]` CANCEL.  `local` at function scope discards the global's value, so
    # a leaked string could never be printed, only lost.  Declared here, before the first use.
    local _extra=""
    # MEMORY OUTCOME, said in the banner rather than buried (v46).  Last night's summary line was
    # "store reset, 0 orphan(s) pruned, 1 FAILED", which is true and says nothing about the thing
    # the command exists for.
    if (( ${#_flush_ok[@]} > 0 )) && (( _resets > 0 ))
    then
        if (( _promote_ok == 1 ))
        then
            _extra+=", memory: ${#_flush_ok[@]} flushed and promoted"
        else
            _extra+=", memory: ${#_flush_ok[@]} flushed, PROMOTE DID NOT RUN"
        fi
    fi
    if (( ${#_flush_skip[@]} > 0 ))
    then
        _extra+=", ${#_flush_skip[@]} reset(s) skipped (no durable flush)"
    fi
    # Report result.  `_extra` is declared at the top of this block; do not re-declare it here,
    # or every memory clause appended above is thrown away again.
    if (( _resets > 0 ))
    then
        _extra+=", $_resets main(s) reset"
    fi
    if (( _repairs > 0 ))
    then
        _extra+=", $_repairs tombstone(s) repaired"
    fi
    if (( _tombstoned > 0 ))
    then
        _extra+=", $_tombstoned main(s) TOMBSTONED (successor started, not reset)"
    fi
    # The kept driver is not a failure and not a tombstone: it is the one main this run was
    # forbidden to empty, and a banner that omits it would read as fourteen-of-fourteen.
    if (( _self_skipped > 0 ))
    then
        _extra+=", the driving lane's own main KEPT (not reset by design)"
    fi
    # The orphan population is said in the banner too, in words that distinguish it from a
    # failure: a run that deleted everything it could and left 21 invisible rows must not read
    # the same as a run that failed.
    if (( ${_invisible_left:-0} > 0 ))
    then
        _extra+=", $_invisible_left orphan store row(s) left (invisible to the CLI)"
    fi
    if (( _failed > 0 ))
    then
        __tac_info "Purge Complete" "[store reset, $_pruned orphan(s) pruned, $_failed FAILED]" "$C_Error"
        # A summary that says FAILED must not exit 0.  Measured live 2026-10-19: the run
        # printed "2 FAILED" and returned 0, so a caller (and the background task's
        # rc=0) read it as success — the exit code is what a caller actually sees.
        return 1
    fi
    # A tombstone is not a store failure — the delete and the prune landed — but it IS an
    # unresolved lane, so the banner may not be the plain success colour.
    if (( _tombstoned > 0 ))
    then
        __tac_info "Purge Complete" "[store reset, $_pruned orphan(s) pruned${_extra}]" "$C_Warning"
        return 0
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
