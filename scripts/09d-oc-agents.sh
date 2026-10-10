# shellcheck shell=bash
# No file-level disables any more.  This module is analysed as part of the module
# graph (tools/lint.sh), so the constants it exports for other modules and the
# variables it reads from an earlier-loaded one both resolve honestly, and its
# sources are followed.  SC2016 is NOT disabled at file level — it is scoped to
# the three embedded-script sites below, so a genuinely mis-quoted expansion
# anywhere else in this file still gets flagged.
# --- Module: 09d-oc-agents ---
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
#   v54 (2026-10-10): the ollama bridge is RETIRED (register item OLLAMA-AUTH-BRIDGE-DEGRADED,
#   disposition option (a)). Both seeding rows are removed: `models.providers.ollama.apiKey` from
#   the config env-ref table, and the `("ollama","ollama","api_key","OLLAMA_API_KEY")` tuple from
#   auth_map. Nothing on this host consumed ollama (`plugins.entries.ollama` was `enabled:false`,
#   `models.providers.ollama.models` was `[]`, no agent model chain named it), yet the auth_map
#   upserted an `ollama:default` profile into all 14 agent stores on EVERY run
#   (openclaw-refresh-keys.service), so every `secrets reload` logged
#   `[SECRETS_PROVIDER_DEGRADED] provider:ollama ... secret provider failed`.
#   Removing the tuple stops the re-seed. Companion live steps (jarvis, same change):
#   `models auth logout --agent <id> ollama --yes` on all 14 agents (verified 0 via `models auth
#   list`) and removal of the retired `models.providers.ollama` block via `openclaw config patch`.
#   `plugins.entries.ollama` is LEFT in place as `enabled:false` — it is not in `plugins.allow`, so
#   the plugin never loads; removing it is optional and out of this item's scope. v44's ollama
#   claim below is superseded.
#   v53 (2026-10-09): the Qwen Token Plan row's RATIONALE is corrected, not the code (the row
#   itself has been in the table since v46 and is covered by tests/unit/01-refresh-keys.bats).
#   v45's paragraph — "QWEN_TOKEN_PLAN_API_KEY deliberately gets no row … NOTHING on this host
#   consumes it … the fix for it is dropping it from that env surface" — is now wrong on both
#   counts, and the reader who takes it at face value would delete a row a live provider needs.
#   Wayne (2026-10-09) intends to USE the provider, and `models.providers.qwen-token-plan` IS
#   declared in openclaw.json (written by an `openclaw config patch` on 2026-10-01 23:41 BST).
#   Measured 2026-10-09: `openclaw models list --provider qwen-token-plan` resolves 15 models
#   with `Auth: yes`, i.e. the env SecretRef resolves and the sweep preserves the key.  The
#   paragraph below is kept as read-only history with a SUPERSEDED marker rather than rewritten,
#   because the version note is the record of what was believed when.  Comments only.
#   v52 (2026-10-09): the NAS mirror marker MOVES OFF TMPFS. It was written under
#   TAC_CACHE_DIR (/dev/shm), so a restart wiped it: `oc status` then reported the mirror
#   "behind" until the next export, and a scheduled export re-uploaded an unchanged set once
#   per boot. It is state, not cache — it now lives under TAC_STATE_DIR (persistent), and the
#   export mkdir -p's that directory before writing. Register NAS-MIRROR-UNSCHEDULED.
#   v51 (2026-10-09): the NAS SSH route is resolved by the new __oc_nas_resolve_host helper
#   instead of inline in oc export-keys-nas — the same run-time route, with that function
#   back under the §18.3 100-line bound and the probe's ssh stderr recorded as a decision
#   (`# swallow-ok:`).  No behaviour change.
#   v50 (2026-10-08): the NAS route is resolved at RUN TIME (OC_NAS_HOST wins, else probe LAN
#   192.168.33.20 then tailnet 100.83.76.103, else fall back to LAN), replacing the hardcoded
#   stale Tailscale default 100.106.225.96; and this file's freshness checks reject a NEGATIVE
#   age (a future mtime), so a clock step cannot read as fresh.
#   v49 (2026-10-03): the embedded JSON-parse helpers now invoke "${TAC_PYTHON:-python3}"
#   instead of bare `python3`, so they use the project venv resolver 01-constants exports
#   (TAC_PYTHON) when it exists and fall back to PATH python3 when it does not (card
#   117e3303).  Behaviour is unchanged where TAC_PYTHON is unset — the fallback is the
#   previous bare `python3`.
#   v48 (2026-10-02): oc export-keys-nas is narrowed to the names the NAS actually reads
#   (__oc_nas_export_names records which name, which NAS file reads it, and how it was
#   measured) instead of shipping all 48 bridged names, and it now enforces mode 600 with a
#   READ-BACK — the file it wrote was 644, 48 credentials world-readable, against this box's
#   0600 cache. Both were measured on the NAS over SSH. The upload marker now hashes the
#   CONTENT uploaded rather than the cache, so a change to the selection cannot be silently
#   skipped by a matching cache hash. `oc export-keys-nas --dry-run` prints the names and
#   their value fingerprints (never values) and touches nothing.
#   v47 (2026-10-01): the shadowing report now compares EVERY env surface against the
#   canonical bridge value — Wayne's ruling (2026-10-01) is that the Windows user
#   environment is the source and every other surface is a derived copy that nobody
#   hand-edits.  It therefore reads the systemd USER MANAGER env as well as the
#   environment.d drop-in: the manager env is the surface the Gateway itself inherits
#   and the previous version could not see.  A name is reported together with the
#   surface that diverged from the canonical value, and a surface that exists but cannot
#   be read is NAMED ("NOT COMPARED: …") rather than treated as agreeing.  The status
#   length budget is now DERIVED from the message actually built (__oc_fit_list) instead
#   of the hardcoded fixed cost the longer status had silently invalidated — measured
#   2026-10-01, the line reached 108 characters and unaligned the report while both
#   budget tests still asserted the old constant.
#   v46 (2026-10-01): the SecretRef table gains three rows the Gateway's startup sweep was
#   deleting, and the refresh NAMES the bridged keys placed on NO surface instead of only
#   counting them.  Rows added, each validated against the live schema the way
#   tests/unit/15-secret-ref-paths.bats does: `gateway.auth.token` (OPENCLAW_GATEWAY_TOKEN —
#   auth.mode stays "password", so naming the token preserves it without flipping the mode),
#   `talk.providers.elevenlabs.apiKey` (the plugin's schema is additionalProperties:false with
#   no declared properties, so this is its only field), and
#   `models.providers.qwen-token-plan.apiKey` (the provider id the bundled catalog declares;
#   nothing selects it yet, so the row only stops the sweep deleting the key and lets the
#   manager-env push carry it — superseding v45's "no row" note for that key).  The new
#   unplaced report distinguishes "waiting for a consumer" from "placed nowhere": a key on no
#   config ref, no unit EnvironmentFile, no environment.d drop-in and not in the manager env
#   is named on every refresh, because a credential on no surface at all is readable by
#   nothing.  Carried from another lane's change-set; the shell module is otherwise unchanged.
#   v45 (2026-10-01): the SecretRef table gains GH_TOKEN, at `gateway.controlUi.github.token`.
#   The startup sweep deletes every managed key the CONFIG does not name, and this host supplies
#   GH_TOKEN from the user-manager environment, so it was deleted (measured with
#   workspace/scripts/managed-env-sweep-check.py: "SWEPT - nothing can restore it"; with this ref
#   in the config the same check prints "PRESERVED by config env-SecretRef").  The consumers are
#   measured, not assumed: dist/github-tool-identity-*.mjs reads GH_TOKEN then GITHUB_TOKEN from
#   the Gateway process env for the native `gh` identity, and the schema text for the field this
#   row writes names the same process-env fallback ("Omit it to retain the GH_TOKEN/GITHUB_TOKEN
#   fallback from the shared Gateway process environment" -- docs/gateway/config-gateway.md).
#   The row was validated against the live schema with `openclaw config patch --stdin --dry-run`
#   ("Dry run successful: 1 update(s) validated"), so it cannot abort the batched write.
#   GITHUB_TOKEN deliberately gets NO row: it is the second name in that one precedence chain
#   (GH_TOKEN wins wherever both are read) and a single config path cannot carry two ids.
#   QWEN_TOKEN_PLAN_API_KEY deliberately gets no row either: it is supplied by the Gateway unit
#   env file, and NOTHING on this host consumes it -- the sole declarer is the qwen plugin's
#   `qwen-token-plan` provider (scripts/lib/official-external-provider-catalog.json), which no
#   `models.providers` block, model ref or auth profile selects (measured; no auth-profile store
#   carries a qwen ref -- see the auth-profile pass below).  It is swept and unused, so the fix
#   for it is dropping it from that env surface, not a ref here.
#   [SUPERSEDED 2026-10-09 -- see v53.  Kept as read-only history; it is wrong on two counts
#   today.  v46 DID add the row it says is absent (the table below carries
#   `models.providers.qwen-token-plan.apiKey`), and the provider IS declared in openclaw.json
#   and is intended for use, so "NOTHING on this host consumes it" no longer holds.  Do not act
#   on this paragraph: deleting the row would strip a live provider's credential.]
#   v44 (2026-10-01): deepseek and ollama now get CONFIG env-refs too
#   (`models.providers.<id>.apiKey`). The table below excluded deepseek on the belief that an
#   auth-profile entry served it; that belief is provably wrong — measured, a store ref is NOT
#   a sufficient channel for a key the runtime resolves: the store refs matched the working
#   config refs byte-for-byte and the gateway still logged, for all 15 agent owners,
#   `SECRETS_DEGRADED ... reason="secret reference was not found"`, with `secrets reload`
#   leaving its 19-warning baseline. The config env-ref is the only shape observed to resolve.
#   Both providers are BUNDLED (the bundle ships docs/providers/deepseek.md and ollama.md), so
#   the apiKey-only overlay is schema-legal; a CUSTOM provider would be refused. The
#   auth-profile store entries stay, as a second channel. Card OC-REFRESH-KEYS-AUTHPROFILE-001.
#   [SUPERSEDED 2026-10-10 -- see v54: the ollama half of this paragraph no longer applies.
#   ollama is retired; its config env-ref row and its auth_map tuple are both gone. The
#   deepseek half still holds.]
# Module Version: 54
#   v43 (2026-10-01): the auth-profile keyRef COMMENTS are corrected, not the code.  Wayne ruled
#   that the "<provider>:default" twin KEEPS provider=<real id>: measured 2026-10-01, both values
#   give the same `secret reference was not found` for every agent, so neither is provably better
#   and the asymmetry is deliberate.  The header comment claimed the keyRef provider "must stay
#   the literal default", which misdescribed the twin and invited a future reader to "reconcile"
#   the two sites on the false assumption that one of them resolves.
#   v42 (2026-10-01): `ocdoc-fix` STREAMS the delegated window's output while still capturing it
#   (`tee`) instead of redirecting it into the log and printing nothing until the end.  Measured
#   2026-10-01 01:51->02:18: doctor archived hal's historical transcripts for 27 minutes and the
#   command looked hung throughout — the caller saw only its own three header lines and no
#   progress.  stdin stays /dev/null (the window must not see a TTY) and `rc` is the WINDOW's
#   status via PIPESTATUS[0], not tee's (and the pipeline is wrapped in `if` so a failing window
#   cannot abort an errexit caller).
#   ALSO in v42: the auth-profile keyRef writes the literal provider "default" again.  v41 put the
#   REAL provider id there on a diagnosis that was WRONG — with it the gateway reported, for every
#   agent, `[SECRETS_OWNER_UNAVAILABLE] Secret owner account:[<agent db>,"deepseek"] is
#   configured-unavailable … reason: secret reference was not found` (measured 2026-10-01).  The
#   same complaint appears with "default", for BOTH the bare and the ":default" ids, so this pass
#   is not where the deepseek resolution fault lives — the card says so and has been reopened.  The
#   live stores were reverted to this shape the same night.
#   v41 (2026-09-30): the auth-profile pass now writes what the CONFIG declares.  Two defects
#   made a present, valid key resolve as missing (measured 2026-09-30, on Wayne's report):
#   the keyRef carried the literal provider "default" instead of the real provider id, and
#   the store wrote only a bare `deepseek` profile while `auth.profiles` declares
#   `deepseek:default` — the id the DEFAULT agent (agents.defaults.systemAgent.agentId = hal)
#   resolves, so hal's turns were refused "configured but unavailable (secret reference was
#   not found)", the deepseek candidate failed and the fallback died on "Context overflow".
#   The "<provider>:default" entry goes ONLY into the default agent's store (adding it to
#   every store raised the secrets-reload warning count 19 -> 46, measured); if the config
#   cannot be read the pass REPORTS that instead of silently writing nothing.
#   Also carried in this commit, the other console session's work: __ocdoc_fix_contain now
#   parses the audit's `plaintext=` count instead of keying on its exit code, which had
#   reported `plaintext=0, unresolved=45` as a plaintext leak and reverted the operator's
#   config on that basis.
#   v40 (2026-09-30): the delegation and the ratchet hygiene land TOGETHER.  The delegation
#   was written against v38; the hygiene edit had already landed on main as v39, so this
#   commit carries both and the number moves past it.  `ocdoc-fix` DELEGATES the Gateway
#   window to the versioned
#   bin/openclaw-doctor-fix-window.sh (armed hold -> verified stop -> doctor --fix ->
#   restore), so there is ONE implementation of the window rather than two; it runs detached
#   (stdin from /dev/null, output to a log) because an interactive run takes doctor's
#   service-config step and writes gateway.auth.token into openclaw.json as PLAINTEXT; and it
#   reports the window's own exit codes (0 completed · 1 nothing repaired · 2 doctor non-zero
#   · 3 repaired, doctor's readiness budget expired).  The containment check moves into
#   __ocdoc_fix_contain, which keeps this function inside §18.3's 100-line bound (10.4).
#   The delegation body is the other ubuntu-console session's work, committed by this lane on
#   Wayne's instruction (2026-09-30).
#   v37 (2026-09-27): __oc_inject_manager_env no longer records a manager-env push it
#   could not make. The hash/set markers are what make the next refresh a no-op, so
#   writing them after a failed `systemctl --user set-environment` silently ended the
#   injection for good — every later run, interactive ones included, compared equal and
#   skipped the push with nothing reported. Measured: without a user bus that call
#   fails rc=1 ("Failed to connect to bus: No medium found"), the agent/CI-shell case.
#   The failure is now counted, named, and the markers left unwritten so the run retries.
#   v36 (2026-09-27): oc-refresh-keys' gateway-convergence wait gives up at 120s, not 60.
#   The unit is Type=simple, so `is-active` says "active" while the gateway is still
#   opening every agent database, and the only early exit is a `running` phase from
#   the gateway's own log. Measured here: 13:30:17 unit start -> 13:31:36 "http server
#   listening" -> 13:31:43 "ready", i.e. ~79-86s. A 60s bound was shorter than the
#   start it waits for, so "restarted and serving" was unreachable on a cold start and
#   every refresh reported "still starting" instead. The wait now announces itself, so
#   the longer pause is not read as a hang.
#   v35 (2026-09-24): every cache in this file writes to a PER-PROCESS temp name.
#   The API-key bridge was fixed for the user-visible case (a bare `mv: cannot stat`
#   under the banner); the agent, session and stats caches had the identical race
#   with the failure suppressed, so a collision there silently lost a refresh.
#   v34 (2026-09-24): __bridge_windows_api_keys writes to a PER-PROCESS temp name and
#   reports a failed create/install in the error log.  Two shells refreshing at once
#   used to collide on a shared "${cache}.tmp" and print a bare
#   "mv: cannot stat '.../tac_win_api_keys.tmp'" under the banner at shell start.
# ==============================================================================
# 09d-oc-agents
# ==============================================================================
# @modular-section: openclaw
# @depends: constants, design-tokens, ui-engine
# @uses: oc-gateway
# @exports: oc-agent-use, ockeys, ocdoc-fix, oc-refresh-keys,
#   oc-rotate-exposed-secrets

# Idempotent include guard: sub-modules are sourced both by their thin
# loader and directly by the profile/env loaders, so run the body once.
[[ -n "${__TAC_MOD_09D_OC_AGENTS_LOADED:-}" ]] && return 0
__TAC_MOD_09D_OC_AGENTS_LOADED=1

function oc-agent-use() {
    local cache="/dev/shm/oc_agent_use.txt"
    local ttl=5

    # Serve cached rendering when fresh
    _ca=$(( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || echo 0) ))
    # A negative age means a future mtime (clock step / writer backdate): not fresh.
    if [[ -f "$cache" ]] && (( _ca >= 0 && _ca < ttl )); then
        cat "$cache"; return 0
    fi

    # Use async JSON caches for agents and sessions (fast, non-blocking)
    local agent_cache="$TAC_CACHE_DIR/oc_agents.json"
    local session_cache="$TAC_CACHE_DIR/oc_sessions.json"

    # Refresh agents cache when stale (3s TTL).
    # Prefer not to block rendering: refresh agents list in background when possible.
    local now mtime
    now=$(date +%s)
    if [[ -f "$agent_cache" ]]; then
        mtime=$(stat -c %Y "$agent_cache" 2>/dev/null || echo 0)
    else
        mtime=0
    fi
    if (( now - mtime < 0 || now - mtime > 3 )); then
        if [[ "$__TAC_OPENCLAW_OK" == "1" ]]; then
            if [[ -t 1 ]]; then
                ( openclaw agents list --json > "${agent_cache}.tmp.$$" 2>/dev/null \
                  || openclaw agents --json > "${agent_cache}.tmp.$$" 2>/dev/null ) \
                  && mv "${agent_cache}.tmp.$$" "$agent_cache" 2>/dev/null || true
            else
                ( openclaw agents list --json > "${agent_cache}.tmp.$$" 2>/dev/null \
                  || openclaw agents --json > "${agent_cache}.tmp.$$" 2>/dev/null ) \
                  && mv "${agent_cache}.tmp.$$" "$agent_cache" 2>/dev/null || true &
            fi
        fi
    fi

    # Refresh sessions cache when stale (5s TTL) — keep synchronous so session
    # counts remain snappy and consistent for the dashboard.
    if [[ -f "$session_cache" ]]; then
        mtime=$(stat -c %Y "$session_cache" 2>/dev/null || echo 0)
    else
        mtime=0
    fi
    if (( now - mtime < 0 || now - mtime > 5 )); then
        if [[ "$__TAC_OPENCLAW_OK" == "1" ]]; then
                ( openclaw sessions --all-agents --json > "${session_cache}.tmp.$$" 2>/dev/null \
                    || openclaw sessions --json > "${session_cache}.tmp.$$" 2>/dev/null ) \
                    && mv "${session_cache}.tmp.$$" "$session_cache" 2>/dev/null || true
        fi
    fi

    # Read cached JSON (may be stale on first run)
    local agents_json sessions_json
    [[ -f "$agent_cache" ]] && agents_json=$(cat "$agent_cache") || agents_json=""
    [[ -f "$session_cache" ]] && sessions_json=$(cat "$session_cache") || sessions_json=""

    # Fallback to immediate CLI if no cache exists yet (first-run)
    if [[ -z "$agents_json" && "$__TAC_OPENCLAW_OK" == "1" ]]; then
        agents_json=$(openclaw agents list --json 2>/dev/null \
            || openclaw agents --json 2>/dev/null || true)
    fi
    if [[ -z "$sessions_json" && "$__TAC_OPENCLAW_OK" == "1" ]]; then
        sessions_json=$(openclaw sessions --all-agents --json 2>/dev/null \
            || openclaw sessions --json 2>/dev/null || true)
    fi

    local tmp_agents
    tmp_agents=$(mktemp) || tmp_agents="/tmp/oc_agents.$$"

    # Extract agent id -> name mapping (best-effort)
    printf '%s' "$agents_json" | jq -r '
            (if type=="array" then . elif (.agents? or .items?) then (.agents // .items) else . end)
            | map(
                { id: ( .id // .agent_id // .slug // .key // .name ),
                  name: ( .identityName // .identity_name // .name // .display_name // .id ) }
              )
            | unique_by(.id)
            | .[]? | "\(.id)\t\(.name)"' 2>/dev/null > "$tmp_agents" || true

    # Build per-agent token aggregates (input, output, total, cap).
    # Produces a TSV with one row per agent: id \t input \t output \t total \t cap.
    # Uses a small TSV cache for instant reads during rendering.
    local stats_cache="$TAC_CACHE_DIR/oc_agent_stats.tsv"
    local stats_ttl=5

    # If the aggregated stats cache is stale, recompute from sessions_json
    if [[ -f "$stats_cache" ]]; then
        mtime=$(stat -c %Y "$stats_cache" 2>/dev/null || echo 0)
    else
        mtime=0
    fi
    if (( now - mtime < 0 || now - mtime > stats_ttl )); then
        # Aggregate sessions_json → per-agent token sums.
        # jq pipeline: normalise agent ID field name (many JSON shapes),
        # extract token counts, group by agent, sum input/output/total
        # and take max cap (context window) per agent. Output as TSV.
        ( printf '%s' "$sessions_json" \
            | jq -r '
                def aid: .agentId // .agent_id // .agent // .agentName // .agent_name;
                (.sessions // .items // . // [])
                | (if type=="array" then . else [] end)
                | map({
                    agent: aid,
                    input: (.inputTokens // 0),
                    output: (.outputTokens // 0),
                    total: (.totalTokens // 0),
                    cap: (.contextTokens // 0)
                  })
                | group_by(.agent)
                | map({
                    id: .[0].agent,
                    input: (map(.input) | add),
                    output: (map(.output) | add),
                    total: (map(.total) | add),
                    cap: (map(.cap) | max)
                  })[]
                | "\(.id)\t\(.input)\t\(.output)\t\(.total)\t\(.cap)"' \
            > "${stats_cache}.tmp.$$" 2>/dev/null ) \
            && mv "${stats_cache}.tmp.$$" "$stats_cache" 2>/dev/null || true
    fi

    local tmp_stats
    tmp_stats=$(mktemp) || tmp_stats="/tmp/oc_stats.$$"
    # Read precomputed aggregated stats and flatten into tab-separated lines.
    # Avoid blocking: if stats cache is missing or stale, start recompute
    # in the background and render a fast fallback immediately.
    if [[ -f "$stats_cache" ]]; then
        # stats cache is already TSV — copy directly for fastest reads
        cat "$stats_cache" > "$tmp_stats" 2>/dev/null || true
    else
        # kick off background recompute from the authoritative session cache file
        if [[ -f "$session_cache" && -s "$session_cache" ]]; then
            if [[ -t 1 ]]; then
                ( jq -r '
                    def aid: .agentId // .agent_id // .agent // .agentName // .agent_name;
                    (.sessions // .items // . // [])
                    | (if type=="array" then . else [] end)
                    | map({ agent: aid,
                        input: (.inputTokens // 0),
                        output: (.outputTokens // 0),
                        total: (.totalTokens // 0),
                        cap: (.contextTokens // 0) })
                    | group_by(.agent)
                    | map({ id: .[0].agent,
                        input: (map(.input) | add),
                        output: (map(.output) | add),
                        total: (map(.total) | add),
                        cap: (map(.cap) | max) })[]
                    | "\(.id)\t\(.input)\t\(.output)\t\(.total)\t\(.cap)"' "$session_cache" 2>/dev/null \
                    > "${stats_cache}.tmp.$$" && mv "${stats_cache}.tmp.$$" "$stats_cache" 2>/dev/null )
            else
                ( jq -r '
                    def aid: .agentId // .agent_id // .agent // .agentName // .agent_name;
                    (.sessions // .items // . // [])
                    | (if type=="array" then . else [] end)
                    | map({ agent: aid,
                        input: (.inputTokens // 0),
                        output: (.outputTokens // 0),
                        total: (.totalTokens // 0),
                        cap: (.contextTokens // 0) })
                    | group_by(.agent)
                    | map({ id: .[0].agent,
                        input: (map(.input) | add),
                        output: (map(.output) | add),
                        total: (map(.total) | add),
                        cap: (map(.cap) | max) })[]
                    | "\(.id)\t\(.input)\t\(.output)\t\(.total)\t\(.cap)"' "$session_cache" 2>/dev/null \
                    > "${stats_cache}.tmp.$$" && mv "${stats_cache}.tmp.$$" "$stats_cache" 2>/dev/null ) &
            fi
        fi
        # fast fallback: list known agents with zeroed stats so rendering is immediate
        if [[ -f "$tmp_agents" ]]; then
            while IFS=$'\t' read -r id name; do
                [[ -z "$id" ]] && continue
                printf '%s\t0\t0\t0\t0\n' "$id" >> "$tmp_stats"
            done < "$tmp_agents"
        else
            # no agent list either; create empty tmp_stats so downstream code
            # will render the session_count header and return quickly
            : > "$tmp_stats"
        fi
    fi

    # Merge agent names (from agents list) and per-agent token stats (from
    # sessions aggregation) into associative arrays for rendering.
    declare -A amap input_sum output_sum total_sum cap_val
    if [[ -f "$tmp_agents" ]]; then
        while IFS=$'\t' read -r id name; do
            [[ -z "$id" ]] && continue
            amap["$id"]="$name"
        done < "$tmp_agents"
    fi
    local total_agents=0 total_active=0
    if [[ -f "$tmp_stats" ]]; then
        while IFS=$'\t' read -r id inp out tot cap; do
            [[ -z "$id" ]] && continue
            input_sum["$id"]=${inp:-0}
            output_sum["$id"]=${out:-0}
            total_sum["$id"]=${tot:-0}
            cap_val["$id"]=${cap:-0}
            # ensure name exists
            [[ -z "${amap[$id]:-}" ]] && amap["$id"]="$id"
            total_active=$(( total_active + ${tot:-0} ))
        done < "$tmp_stats"
    fi

    # total_agents should reflect number of registered agents (from agents list)
    if [[ -f "$tmp_agents" ]]; then
        total_agents=$(wc -l < "$tmp_agents" 2>/dev/null || echo 0)
    else
        total_agents=${#amap[@]}
    fi

    # session_count: number of active sessions (prefer .count from sessions JSON)
    local session_count
    session_count=$(printf '%s' "$sessions_json" | jq -r '.count // (.sessions|length) // 0' 2>/dev/null || echo 0)
    total_active=$((session_count))

    # If agents list existed but no sessions, ensure amap entries present
    if (( total_agents == 0 )); then
        for id in "${!amap[@]}"; do
            input_sum["$id"]=${input_sum[$id]:-0}
            output_sum["$id"]=${output_sum[$id]:-0}
            total_sum["$id"]=${total_sum[$id]:-0}
            cap_val["$id"]=${cap_val[$id]:-0}
            total_agents=$(( total_agents + 1 ))
        done
    fi

    # Helper: humanize token counts to k/m-unit strings (e.g. 1500 → "1.5k")
    _human() {
        local n=$1
        if (( n >= 1000000 )); then
            awk -v v="$n" 'BEGIN{printf "%.1fm", v/1000000}'
        elif (( n >= 1000 )); then
            awk -v v="$n" 'BEGIN{printf "%.1fk", v/1000}'
        else
            echo "$n"
        fi
    }
    # Nested helpers — capture $_human (main formatting function) from parent scope
    _human_one() { _human "$1"; }
    _human_cap_k() {
        local n=$1
        if (( n >= 1000 )); then
            awk -v v="$n" 'BEGIN{printf "%dk", int((v+500)/1000)}'
        else
            echo "$n"
        fi
    }

    # Assemble sorted list by percent (desc)
    local lines_file
    lines_file=$(mktemp) || lines_file="/tmp/oc_lines.$$"
    for id in "${!amap[@]}"; do
        local in_s=${input_sum[$id]:-0}
        local out_s=${output_sum[$id]:-0}
        local reported_tot=${total_sum[$id]:-0}
        local cap=${cap_val[$id]:-0}
        # Compute total: prefer reported total, but if it's smaller than
        # the observed sum(input+output), use the larger value so numbers
        # reconcile (some OpenClaw shapes report context-only totals).
        local tot
        local sum_io=$(( in_s + out_s ))
        if (( reported_tot > 0 )); then
            if (( sum_io > reported_tot )); then
                tot=$sum_io
            else
                tot=$reported_tot
            fi
        else
            tot=$sum_io
        fi
        # persist computed total so downstream logic sees reconciled value
        total_sum["$id"]=$tot
        # default cap when missing
        if (( cap == 0 )); then
            cap=131072
        fi
        # percent (rounded)
        local pct
        if (( cap > 0 )); then
            pct=$(( (tot * 100 + cap/2) / cap ))
        else
            pct=0
        fi
        printf '%d\t%s\t%s\t%s\t%s\n' "$pct" "$id" "$tot" "$cap" "$in_s" >> "$lines_file"
    done

    # Per-process, like the other caches in this file: a shared name lets one shell
    # move the file another is still writing.
    local outtmp="${cache}.tmp.$$"
    {
        # Prepare labelled lines and compute max label width for alignment
        local labels_tmp
        labels_tmp=$(mktemp) || labels_tmp="/tmp/oc_labels.$$"
        while IFS=$'\t' read -r pct id tot cap inpt; do
            # Include agents that appear in the sessions-derived stats even if
            # their total token count is zero. Only skip agents that have no
            # session-derived entry and zero tokens.
            if [[ "${tot:-0}" -eq 0 && -z "${total_sum[$id]+set}" ]]; then
                continue
            fi
            local display label
            display=${amap[$id]:-$id}
            label="${display}"
            # store label plus the rest
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$label" "$pct" "$id" "$tot" "$cap" "$inpt" >> "$labels_tmp"
        done < <(sort -rn "$lines_file")

        # compute printable agent count and max label width
        local raw_max capw label_max printable_count
        printable_count=$(awk -F"\t" '$4 > 0 {c++} END {print (c+0)}' "$labels_tmp")
        # compute raw max label length
        raw_max=$(awk -F"\t" '{ if (length($1) > m) m=length($1) } END { print (m==""?0:m) }' "$labels_tmp")
        if [[ -n "${UIWidth:-}" && ${UIWidth} -gt 60 ]]; then
            local cap_candidate=$(( UIWidth - 48 ))
            if (( cap_candidate > 14 )); then
                capw=14
            else
                capw=$cap_candidate
            fi
        else
            capw=14
        fi
        label_max=$raw_max
        if (( label_max > capw )); then
            label_max=$capw
        fi
        if (( printable_count > 0 )); then
            printf 'ACTIVE AGENT CONTEXT USE (%d/%d active)\n\n' "$total_active" "$total_agents"
        fi
        # Print formatted lines with aligned labels (skip agents with zero total)
        while IFS=$'\t' read -r label pct id tot cap inpt; do
            # hide agents that have zero total tokens
            if [[ -z "${tot:-}" || ${tot:-0} -eq 0 ]]; then
                continue
            fi
            local label_display tot_h in_h out_h cap_h color in_col out_col
            # Build base label (without trailing colon), truncate to label_max
            local label_base
            label_base="$label"
            if (( ${#label_base} > label_max )); then
                label_base="${label_base:0:$((label_max-3))}..."
            fi
            # We'll print the name padded to label_max, then a single ': ' separator
            label_display="$label_base"
            tot_h=$(_human_one "$tot")
            in_h=$(_human_one "$inpt")
            out_h=$(_human_one "${output_sum[$id]:-0}")
            cap_h=$(_human_cap_k "$cap")
            # Do not embed colour codes in the cache; render plain percent
            # and let the dashboard apply colouring when displaying.
            in_col="${in_h}"
            out_col="${out_h}"
            local pct_display
            pct_display="${pct}%"
            printf "  %s: %s (%s of %s) \u2B06 %s \u2B07 %s\n" \
                "$label_display" "$pct_display" "$tot_h" "$cap_h" "$in_col" "$out_col"
        done < "$labels_tmp"
        rm -f "$labels_tmp"
    } > "$outtmp"

    mv "$outtmp" "$cache" 2>/dev/null || cp "$outtmp" "$cache" 2>/dev/null
    cat "$cache"
    rm -f "$tmp_agents" "$tmp_stats" "$lines_file" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# ockeys — Show Windows environment API keys and their WSL visibility.
# Wraps the pwsh call in timeout to prevent hangs after sleep/hibernate.
# ---------------------------------------------------------------------------
function ockeys() {
    printf '%s\n' "${C_Highlight}API Keys & Tokens (Windows Environment → WSL):${C_Reset}"
    local found=0
    # SC2016: the `-Command` payload inside this loop is PowerShell, not bash —
    # `$($_.Key)` must reach pwsh unexpanded, so the single quoting is correct.
    # shellcheck disable=SC2016
    while IFS='=' read -r name val
    do
        [[ -z "$name" ]] && continue
        local upper; upper=${name^^}
        if [[ "$upper" == *API_KEY* || "$upper" == *API-KEY* || "$upper" == *TOKEN* || "$upper" == *APIKEY* ]]
        then
            local masked="${val:0:4}...${val: -4}"
            [[ ${#val} -lt 10 ]] && masked="(too short)"
            local oc_visible=""
            if printenv "$name" >/dev/null 2>&1
            then
                oc_visible="${C_Success}WSL ✓${C_Reset}"
            else
                oc_visible="${C_Error}WSL ✗${C_Reset}"
            fi
            printf '%s\n' "  ${C_Dim}$name${C_Reset}  $masked  $oc_visible"
            found=$(( found + 1 ))
        fi
    done < <(timeout 20 pwsh.exe -NoProfile -Command '
        [Environment]::GetEnvironmentVariables("User").GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }
    ' 2>/dev/null | tr -d '\r')
    if (( found == 0 ))
    then
        __tac_info "Windows User Env" "[NO API-KEY / TOKEN VARS FOUND]" "$C_Warning"
    else
        printf '%s\n' "  ${C_Dim}$found key(s) found in Windows User environment${C_Reset}"
    fi
}

# ---------------------------------------------------------------------------
# ocdoc-fix — Run openclaw doctor --fix inside a REAL window, and undo what it writes.
# ---------------------------------------------------------------------------
# WHY A WINDOW (measured 2026-09-30).  `openclaw doctor --fix` cannot enter maintenance
# while the Gateway owns state/openclaw.sqlite (GatewayStateOwnerContentionError), so the
# Gateway must be STOPPED first.  A bare `systemctl --user stop` is NOT enough on this
# host: an unclean drain exits 1, which trips OnFailure=openclaw-gateway-guard.service and
# revives the Gateway in ~60 ms (measured — it flapped ~9x during the 2026.9.7 window), so
# the guard's own dead-man switch ~/.openclaw/.gateway-hold is armed FIRST and the stop
# goes through the console's canonical wrapper so it is VERIFIED, not assumed.
#
# WHY IT UNDOES THINGS (measured 2026-09-30 — the reason this function is not just a call).
# With a window, doctor's "update gateway service config to the recommended defaults?"
# step answers YES by itself (no TTY needed) and:
#   * REPLACES the managed unit (backing it up to openclaw-gateway.service.bak), reordering
#     it and SHORTENING OPENCLAW_SERVICE_MANAGED_ENV_KEYS;
#   * writes gateway.auth.token into openclaw.json IN PLAINTEXT — and that file is TRACKED,
#     so the next fleet sync would commit and push the secret;
#   * can still end in "Doctor could not complete maintenance" + a
#     GatewayServiceUpdateOwnershipError.
# So the unit and the config are snapshotted first and restored after if doctor changed
# them, and the plaintext-secret case is caught with doctor's own audit.
#
# HOW THE WINDOW RUNS (2026-09-30, Wayne's call): this function no longer runs doctor
# itself — it DELEGATES to the versioned ~/ubuntu-console/bin/openclaw-doctor-fix-window.sh
# (arm hold -> safe-stop-gateway.py -> doctor --fix -> restore), so there is ONE
# implementation of the window rather than two. The delegated window runs DETACHED: it must
# not inherit this shell's TTY, or doctor takes its interactive service-config step and
# rewrites the unit (see above). The snapshot/revert contract below still applies, because
# the delegated window carries no containment of its own.
function ocdoc-fix() {
    local cfg="$OC_ROOT/openclaw.json"
    local bak="${cfg}.pre-doctor"
    local unit="$HOME/.config/systemd/user/openclaw-gateway.service"
    local hold="$OC_ROOT/.gateway-hold"
    local snapdir="$OC_ROOT/state/pre-doctor-snapshot"
    local unit_before="" rc=0

    printf '\n%soc doc-fix%s - running %sopenclaw doctor --fix%s in a Gateway window\n' \
        "$C_Highlight" "$C_Reset" "$C_Text" "$C_Reset"
    printf '%s\n' "${C_Dim}  doctor needs the state DB to itself, so the Gateway stops for the duration."
    printf '%s\n' "  The unit and the config are snapshotted first, and anything doctor rewrites is put"
    printf '%s\n' "  back afterwards.${C_Reset}"

    # 1. snapshot — doctor rewrites BOTH of these.
    mkdir -p "$snapdir"
    if [[ -f "$cfg" ]]
    then
        cp "$cfg" "$bak"
        cp "$cfg" "$snapdir/openclaw.json"
        printf '  %sConfig backed up%s -> %s\n' "$C_Text" "$C_Reset" "${bak/#$HOME/~}"
    fi
    if [[ -f "$unit" ]]
    then
        cp "$unit" "$snapdir/openclaw-gateway.service"
        unit_before="$(sha256sum "$unit" | cut -d' ' -f1)"
    fi

    # 2+3. the window — DELEGATED to the versioned, gated script (one implementation of the
    # window, not two). It arms the guard hold, stops through safe-stop-gateway.py (which
    # REFUSES on a red pre-flight — safe-stop's DO NOT STOP has no override flag), runs
    # doctor --fix, and restores.
    #
    # DETACHED FROM THE TTY, deliberately: the window must not inherit this shell's tty. Measured
    # 2026-09-30 — an INTERACTIVE `doctor --fix` takes its "update gateway service config to the
    # recommended defaults now?" step (the prompt defaults to Yes), which rewrites the managed unit
    # and writes gateway.auth.token into openclaw.json IN PLAINTEXT. A non-tty run skips that step
    # and completes; that is the shape that reached rc=0 at 14:04. Redirecting stdin from /dev/null
    # and output to a log is all the detachment needed — the window stops the *gateway* unit, and
    # this shell is not in that cgroup, so the stop cannot take it down.
    #
    # RUN_UPDATE_REPAIR is deliberately NOT passed by default. Measured 2026-09-30: with the
    # Gateway stopped, `update repair` proceeds INTO finalize:doctor, and in the 17:50 window
    # it was SIGTERM'd ~4 min in (rc=143) — leaving the state DB marked "undergoing offline
    # maintenance" so the Gateway could not start until the orphaned tree exited, plus an
    # orphan update_runs row in requested/running that then blocks plugin convergence
    # ("Package convergence must wait until the updating parent releases its install
    # records"). With the Gateway UP the same command skips doctor and completes rc=0, so do
    # `openclaw update repair` by hand that way. Set OCDOC_FIX_UPDATE_REPAIR=1 to opt in.
    local window="$HOME/ubuntu-console/bin/openclaw-doctor-fix-window.sh"
    local wlog
    wlog="$OC_ROOT/logs/oc-doc-fix-window-$(date +%Y%m%d-%H%M%S).log"
    if [[ ! -x "$window" ]]
    then
        printf '  %sCannot delegate%s - %s is not executable; nothing was stopped.\n' \
            "$C_Error" "$C_Reset" "${window/#$HOME/~}"
        return 1
    fi

    printf '  %sRunning the window%s (%s) - doctor needs the state DB to itself, so the\n' \
        "$C_Text" "$C_Reset" "${window/#$HOME/~}"
    printf '  Gateway stops for the duration. This can take several minutes; the output\n'
    printf '  STREAMS below as it goes, and is kept at %s\n' "${wlog/#$HOME/~}"
    # STREAM as well as capture. The window must still not see a TTY (an interactive doctor
    # takes its service-config step and rewrites the unit), so stdin stays /dev/null and its
    # stdout is a pipe — but redirecting to the log ALONE made a 27-minute run look like a dead
    # command: measured 2026-10-01, doctor archived hal's transcripts (25 s SQLite transactions)
    # for 27 min and the caller printed nothing until it finished.  `rc` is the WINDOW's status,
    # not tee's, hence PIPESTATUS[0].
    if RUN_UPDATE_REPAIR="${OCDOC_FIX_UPDATE_REPAIR:-0}" "$window" </dev/null 2>&1 | tee "$wlog"
    then
        rc=0
    else
        rc=${PIPESTATUS[0]}   # the WINDOW's status, not tee's — and errexit-safe
    fi


    # 4. undo what doctor wrote, then VERIFY the undo actually holds — the containment is
    #    this function's OWN contract, so it is proved rather than assumed.  The check is
    #    __ocdoc_fix_contain (below); it prints its own CONTAINMENT FAILED lines and returns
    #    non-zero when containment did not hold.  The split is what keeps this function
    #    inside §18.3's 100-line bound (10.4), and moves the code rather than changing it.
    local contained=1
    __ocdoc_fix_contain "$unit" "$unit_before" "$cfg" "$bak" "$snapdir" || contained=0

    # 5. make sure we leave the window. The delegated script restores on its own (it clears
    #    the hold and starts the Gateway), so these are idempotent safety nets for the case
    #    where it was killed mid-way.
    rm -f "$hold"
    systemctl --user unset-environment OPENCLAW_GUARD_HOLD_MAX_AGE
    systemctl --user start openclaw-gateway.service
    if (( contained == 0 ))
    then
        printf '  %sGateway restarted%s - but the window did NOT contain doctor; see the lines above.\n\n' \
            "$C_Error" "$C_Reset"
        return 1
    fi
    # The exit code reports THIS function's contract: the Gateway was stopped, the window ran,
    # and whatever doctor wrote was put back and verified — so containment decides the return,
    # not doctor's own rc. These are the delegated script's documented codes (v3): 0 completed ·
    # 1 the stop was refused or the Gateway would not stop, nothing repaired · 2 doctor --fix
    # non-zero · 3 doctor repaired state and only its own 61 s readiness budget expired.
    if (( rc == 0 ))
    then
        printf '  %sGateway restarted%s - the window completed cleanly; run %soc gs%s to re-check.\n\n' \
            "$C_Success" "$C_Reset" "$C_Text" "$C_Reset"
    elif (( rc == 3 ))
    then
        printf '  %sGateway restarted%s - doctor reported a SUCCESSFUL repair; only its own Gateway\n' \
            "$C_Success" "$C_Reset"
        printf '  readiness budget (61s) expired first — this host needs ~100s under load. The window\n'
        printf '  waited for the Gateway itself and it is up. Confirm with %soc gs%s.\n\n' \
            "$C_Text" "$C_Reset"
    elif (( rc == 1 ))
    then
        printf '  %sNothing was repaired%s - the window never reached doctor: the stop was refused, or\n' \
            "$C_Warning" "$C_Reset"
        printf '  the Gateway would not stop. Its pre-flight output is above and in %s.\n\n' \
            "${wlog/#$HOME/~}"
    else
        printf '  %sGateway restarted%s - the window ran but doctor --fix exited %s%d%s; read %s.\n\n' \
            "$C_Warning" "$C_Reset" "$C_Text" "$rc" "$C_Reset" "${wlog/#$HOME/~}"
    fi
    return 0
}

# __ocdoc_fix_contain <unit> <unit_before> <cfg> <bak> <snapdir> — put back whatever doctor
# rewrote during the window and VERIFY the undo actually holds.  It prints its own
# CONTAINMENT FAILED lines and returns 0 when containment held, 1 when it did not.
#
# Split out of `ocdoc-fix` so that function stays inside §18.3's 100-line bound (10.4).  The
# body is the same code moved, and it is handed what it needs rather than reading the
# caller's locals.
function __ocdoc_fix_contain() {
    local unit="$1" unit_before="$2" cfg="$3" bak="$4" snapdir="$5"
    local contained=1
    if [[ -n "$unit_before" && -f "$unit" ]]
    then
        if [[ "$(sha256sum "$unit" | cut -d' ' -f1)" != "$unit_before" ]]
        then
            cp "$snapdir/openclaw-gateway.service" "$unit"
            systemctl --user daemon-reload
            printf '  %sPut the gateway unit back%s - doctor had replaced it\n' "$C_Warning" "$C_Reset"
        fi
        if [[ "$(sha256sum "$unit" | cut -d' ' -f1)" != "$unit_before" ]]
        then
            contained=0
            printf '  %sCONTAINMENT FAILED%s - the gateway unit still differs; snapshot is at %s\n' \
                "$C_Error" "$C_Reset" "$snapdir"
        fi
    fi
    # The audit reports several classes (plaintext, unresolved, shadowed, storeResidue,
    # legacy); only `plaintext` is THIS function's contract. Keying on the command's exit
    # code made an unrelated finding read as a plaintext secret — measured 2026-09-30:
    # `plaintext=0, unresolved=45` printed "CONTAINMENT FAILED - a plaintext secret is still
    # in the config", and the config-changed branch below REVERTED the operator's config on
    # that basis. Parse the count.
    local audit_out audit_plaintext=""
    audit_out="$(openclaw secrets audit 2>&1)"
    audit_plaintext="$(printf '%s' "$audit_out" | sed -n 's/.*plaintext=\([0-9][0-9]*\).*/\1/p' | head -1)"
    if [[ -z "$audit_plaintext" ]]
    then
        contained=0
        printf '  %sCONTAINMENT FAILED%s - the secrets audit reported no plaintext= count:\n' \
            "$C_Error" "$C_Reset"
        printf '%s\n' "$audit_out" | tail -5
    fi
    if [[ -f "$cfg" && -f "$bak" ]] && ! diff -q "$bak" "$cfg"
    then
        if [[ -n "$audit_plaintext" && "$audit_plaintext" != 0 ]]
        then
            cp "$bak" "$cfg"
            printf '  %sReverted the config%s - doctor had written a plaintext secret into openclaw.json\n' \
                "$C_Warning" "$C_Reset"
        else
            printf '  %sThe config changed%s - no plaintext secret (plaintext=%s); worth a look: %s\n' \
                "$C_Warning" "$C_Reset" "${audit_plaintext:-unknown}" "${bak/#$HOME/~}"
        fi
    fi
    if [[ -n "$audit_plaintext" && "$audit_plaintext" != 0 ]]
    then
        contained=0
        printf '  %sCONTAINMENT FAILED%s - the config carries a plaintext secret (plaintext=%s)\n' \
            "$C_Error" "$C_Reset" "$audit_plaintext"
    fi
    if (( contained == 0 ))
    then
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# __bridge_windows_api_keys — Import Windows User environment variables
# containing API_KEY or TOKEN into the WSL environment.
# Uses a /dev/shm cache (TTL 3600s = 1h) to avoid a slow pwsh call on
# every shell start. Run 'oc-refresh-keys' to force a re-import.
# Security: cache is chmod 600 and lives in tmpfs (RAM only, no disk).
# ---------------------------------------------------------------------------
function __bridge_windows_api_keys() {
    local cache="$TAC_CACHE_DIR/tac_win_api_keys"
    local ttl=3600
    # Honor TAC_CACHE_DIR so a sandboxed shell (tests) never touches the real
    # /dev/shm flag; production TAC_CACHE_DIR is /dev/shm, so behaviour is the same.
    local _warn_once_file="${TAC_CACHE_DIR:-/dev/shm}/tac_pwsh_bridge_warned"

    # Session-level guard: if pwsh.exe was previously unavailable or timed
    # out, skip retrying for the rest of this session. The warning file is
    # cleared on success so a working bridge is retried.
    # This avoids a ~20s hang on every shell init when pwsh.exe exists on
    # PATH but WSL interop is broken (common with WSL mirrored networking).
    if [[ -f "$_warn_once_file" ]]
    then
        # Source stale cache if it exists (from a prior session that worked).
        # $cache is generated at runtime from the Windows user environment, so
        # there is nothing here for shellcheck to follow.  The directive names
        # that — it is SC1090's own suggested remedy, not a disabled check.
        # shellcheck source=/dev/null
        [[ -f "$cache" ]] && source "$cache" 2>/dev/null
        return 0
    fi

    # Stateful downgrade: if pwsh.exe is unavailable, warn once per session.
    if ! command -v pwsh.exe >/dev/null 2>&1
    then
        printf '%s\n' "$(date +%s)" > "$_warn_once_file" 2>/dev/null || true
        echo "$(date +"%Y-%m-%d %H:%M:%S") [WARN] __bridge_windows_api_keys: pwsh.exe unavailable; bridge downgraded for this session." >> "$ErrorLogPath" 2>/dev/null
        return 0
    fi

    # Use cached exports if fresh enough
    _ca=$(( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || echo 0) ))
    if [[ -f "$cache" ]] && (( _ca >= 0 && _ca < ttl ))
    then
        # shellcheck source=/dev/null
        source "$cache" 2>/dev/null
        return
    fi

    # Fetch matching vars from Windows User environment via PowerShell.
    # Match any variable whose name is credential-shaped: TOKEN, API_KEY /
    # API-KEY, PASSWORD, a *_KEY / *_SECRET suffix, *_CLIENT_ID, or a bare
    # *_API (case-insensitive). Covers GEMINI_API_KEY, OPENAI_API_KEY,
    # OPENCLAW_GATEWAY_TOKEN, OPENCLAW_GATEWAY_PASSWORD, plus the names the
    # earlier narrower pattern silently missed: OPENCLAW_WEB_SEARCH_KEY,
    # MICROSOFT_CLIENT_ID, HERE_NOW_API. Non-credential vars (Path, TEMP,
    # TMP, NODE_OPTIONS, OneDrive*, Chocolatey*, *DIR, *HOME) stay excluded.
    local raw
    # 20s, not 5s: a cold pwsh.exe start plus the User-env enumeration has been
    # measured at 3-10s over WSL interop, and a 5s cap silently returned a
    # truncated variable set (partial cache) instead of failing cleanly.
    # SC2016: PowerShell payload (see the ockeys loop above) — `$($_.Key)` must
    # not be expanded by bash.
    # shellcheck disable=SC2016
    raw=$(timeout 20 pwsh.exe -NoProfile -NonInteractive -Command '
        [Environment]::GetEnvironmentVariables("User").GetEnumerator() |
        Where-Object { $_.Key -match "(?i)(TOKEN|API(_|-)?KEY|PASSWORD|_KEY$|_SECRET|_CLIENT_ID$|_API$)" } |
        ForEach-Object { "$($_.Key)=$($_.Value)" }
    ' 2>/dev/null | tr -d '\r')

    if [[ -z "$raw" ]]
    then
        if [[ ! -f "$_warn_once_file" ]]
        then
            printf '%s\n' "$(date +%s)" > "$_warn_once_file" 2>/dev/null || true
            echo "$(date +"%Y-%m-%d %H:%M:%S") [WARN] __bridge_windows_api_keys: pwsh.exe returned no data; bridge downgraded for this session." >> "$ErrorLogPath" 2>/dev/null
        fi
        return 0
    fi

    # Build a sourceable cache file, skipping vars with invalid names.
    # A PER-PROCESS temp name: two shells starting together (VS Code plus a terminal, or
    # two terminals) both refresh this cache, and with a shared "${cache}.tmp" one of them
    # moves a file the other is still writing — the loser's mv then dies with
    # "mv: cannot stat '/dev/shm/tac_win_api_keys.tmp'" printed under the banner at shell
    # start (Wayne's terminal, 2026-09-24).  A unique name also means neither can truncate
    # the file the other is about to install.
    local tmpfile="${cache}.tmp.$$"
    # swallow-ok: the status is checked here and a failure is logged below; bash's redirect message would print under the banner
    if ! ( umask 077; : > "$tmpfile" ) 2>/dev/null
    then
        # swallow-ok: the error-log write is the last resort — best effort by definition, and the shell must still start
        echo "$(date +"%Y-%m-%d %H:%M:%S") [WARN] bridge: cannot write $tmpfile" >> "$ErrorLogPath" 2>/dev/null
        return 0
    fi
    while IFS='=' read -r name val
    do
        [[ -z "$name" || ! "$name" =~ ^[a-zA-Z0-9_]+$ ]] && continue
        [[ -z "$val" ]] && continue
        # Reject values with embedded newlines (could inject extra commands)
        [[ "$val" == *$'\n'* ]] && continue
        printf 'export %s=%q\n' "$name" "$val" >> "$tmpfile"
    done <<< "$raw"
    if ! mv "$tmpfile" "$cache"
    then
        # Reported, never leaked as a bare mv error under the banner: the previous cache
        # (if any) is still in place and still usable, and the next shell retries.
        rm -f "$tmpfile"
        # swallow-ok: the error-log write is the last resort — best effort by definition, and the shell must still start
        echo "$(date +"%Y-%m-%d %H:%M:%S") [WARN] bridge: could not install $tmpfile" >> "$ErrorLogPath" 2>/dev/null
        return 0
    fi
    chmod 600 "$cache"
    # shellcheck source=/dev/null
    source "$cache" 2>/dev/null
    rm -f "$_warn_once_file" 2>/dev/null || true
}

# (Removed 2026-09-20: __oc_upsert_env_kv — unreferenced repo-wide; env-file writes
# go through __oc_sync_gateway_env_file.)

# (oc-sync-keys-to-bridge removed; behavior merged into oc-refresh-keys)

# ---------------------------------------------------------------------------
# __oc_apply_secret_refs — Map imported env credentials to OpenClaw SecretRefs.
#
# Mirrors what `openclaw secrets configure` writes for env-backed credentials:
# each supported config field becomes
#   { "source": "env", "provider": "default", "id": "<ENV_VAR>" }
# via `openclaw config set <path> --ref-provider default --ref-source env
# --ref-id <ENV_VAR>` (the canonical SecretRef builder). The secret itself stays
# in the env credential store refreshed by oc-refresh-keys; only the plaintext
# copy in openclaw.json is replaced by a reference.
#
# Safety:
#   - Applies a ref only when its env var is present and non-empty in the
#     current environment (sourced from the bridge cache), so an unresolved
#     ref is never created.
#   - `openclaw config set` runs SecretRef preflight and writes atomically, so
#     a field is left untouched if the ref would not resolve.
#   - Idempotent: re-running re-asserts the same refs.
#
# Mapping table: "<config dot-path>::<ENV_VAR_NAME>". Extend here when a new
# env-backed credential is confirmed to match a supported SecretRef field
# (see: openclaw docs reference/secretref-credential-surface).
# ---------------------------------------------------------------------------
function __oc_apply_secret_refs() {
    if ! command -v openclaw >/dev/null 2>&1
    then
        __tac_info "Syncing OpenClaw SecretRefs" "[openclaw not found — skipped]" "$C_Warning"
        return 0
    fi

    # Batch all env-backed SecretRefs into ONE `openclaw config patch` (single
    # validated write) — and skip the patch entirely when nothing changed, so a
    # no-op refresh performs no config writes at all.
    local _patch_info _patch _applied=0 _skipped=0 _failed=0
    _patch_info=$("${TAC_PYTHON:-python3}" - <<'PYEOF'
import json, os, subprocess, sys
entries = [
    # Web Search Plugin API Keys
    ("plugins.entries.google.config.webSearch.apiKey", "GEMINI_API_KEY"),
    ("plugins.entries.brave.config.webSearch.apiKey", "BRAVE_API_KEY"),
    ("plugins.entries.tavily.config.webSearch.apiKey", "TAVILY_API_KEY"),
    ("plugins.entries.perplexity.config.webSearch.apiKey", "PERPLEXITY_API_KEY"),
    ("plugins.entries.xai.config.webSearch.apiKey", "XAI_API_KEY"),
    ("plugins.entries.moonshot.config.webSearch.apiKey", "MOONSHOT_API_KEY"),
    ("plugins.entries.firecrawl.config.webSearch.apiKey", "FIRECRAWL_API_KEY"),
    # Model Provider API Keys. EVERY provider a model is selected from needs an env-backed
    # ref here: the auth-profile store below is a second channel, not a sufficient one
    # (measured 2026-10-01: deepseek's store ref had the same shape as these and the gateway
    # still reported `secret reference was not found` for every agent, so the key could not
    # survive the sweep). deepseek is the default agent's model, so it goes first.
    ("models.providers.deepseek.apiKey", "DEEPSEEK_API_KEY"),
    ("models.providers.openai.apiKey", "OPENAI_API_KEY"),
    ("models.providers.anthropic.apiKey", "ANTHROPIC_API_KEY"),
    ("models.providers.groq.apiKey", "GROQ_API_KEY"),
    ("models.providers.moonshot.apiKey", "MOONSHOT_API_KEY"),
    ("models.providers.openrouter.apiKey", "OPENROUTER_API_KEY"),
    ("models.providers.xai.apiKey", "XAI_API_KEY"),
    ("models.providers.qwen.apiKey", "QWEN_API_KEY"),
    ("models.providers.nvidia.apiKey", "NVIDIA_API_KEY"),
    ("models.providers.fireworks.apiKey", "FIREWORKS_API_KEY"),
    ("models.providers.huggingface.apiKey", "HUGGINGFACE_TOKEN"),
    # NOT mapped, deliberately: models.providers.inception.apiKey. `inception` is a
    # CUSTOM provider, and the schema refuses a patch that creates one without
    # baseUrl + models ("custom model providers must declare baseUrl"; a provider
    # overlay without them is only supported for BUNDLED providers). The refs go
    # out in ONE validated batch, so a row that validates only while the provider
    # block happens to exist can abort every other ref update the day it does not.
    # tests/unit/15-secret-ref-paths.bats catches exactly that, against an empty
    # base config. INCEPTION_API_KEY therefore stays store-backed, and the
    # refresh's own report names it so the gap stays visible (2026-09-22).
    # Tool / Platform API Keys
    # `tools.web.fetch.firecrawl.*` is a LEGACY shape the current schema rejects
    # ("tools.web.fetch: Unrecognized key: firecrawl"); openclaw doctor --fix
    # migrates it to the plugin entry below (docs/tools/web-fetch.md: "Legacy
    # tools.web.fetch.firecrawl.* config auto-migrates to
    # plugins.entries.firecrawl.config.webFetch").  A row the schema rejects is
    # worse than inert: `config patch` validates, so one bad row aborts the
    # whole batched SecretRef write (2026-09-22).
    ("plugins.entries.firecrawl.config.webFetch.apiKey", "FIRECRAWL_API_KEY"),
    ("tools.web.search.serp.apiKey", "SERP_API_KEY"),
    # GH_TOKEN feeds the native `gh` identity (dist/github-tool-identity-*.mjs reads GH_TOKEN
    # then GITHUB_TOKEN out of the Gateway process env) for the same process-env fallback this
    # schema field documents, so naming it here is what keeps the sweep from deleting it.
    ("gateway.controlUi.github.token", "GH_TOKEN"),
    # Skill credentials -- installed skills live under skills.entries, NOT
    # plugins.entries: a row pointing at a non-existent path writes a leaf
    # nothing reads and the real ref is left un-injected (TYPESAFE_API_KEY,
    # 2026-09-22). Confirm the field against the real config before adding a row.
    ("skills.entries.typesafe-ai.apiKey", "TYPESAFE_API_KEY"),
    # Both of these were store-backed, so the key was bridged from Windows and
    # declared in the config yet never reached the gateway by name; mapping them
    # makes the env the single maintained channel (2026-09-22).
    ("skills.entries.agentmail-cli.apiKey", "AGENTMAIL_API_KEY"),
    # 2026-10-01 (Wayne): keys the Gateway's startup sweep deletes, which only the login-shell
    # import was putting back. Each field below was validated against the real schema with
    # `openclaw config patch --dry-run` on a throwaway empty config — the same oracle
    # tests/unit/15-secret-ref-paths.bats runs, so a row that drifts from the schema fails there:
    #   gateway.auth.token      the Gateway's own token. Its auth.mode is explicitly "password"
    #                           (and stays that way: finalizeResolvedGatewayAuth takes
    #                           authConfig.mode before any token), so naming the token here does
    #                           not flip the auth mode — it makes the sweep preserve it.
    #   talk.providers.elevenlabs.apiKey
    #                           elevenlabs is a talk/speech provider (docs/nodes/talk*.md:
    #                           "the matching talk.providers.<provider> configuration"); the
    #                           plugin's own configSchema (dist/extensions/elevenlabs) is
    #                           additionalProperties:false with NO properties, so this is the
    #                           only field its key can be named on.
    #   models.providers.qwen-token-plan.apiKey
    #                           the provider id the bundled catalog declares for
    #                           QWEN_TOKEN_PLAN_API_KEY (dist/official-external-provider-catalog).
    #                           The provider IS declared in openclaw.json and is intended for use
    #                           (Wayne, 2026-10-09), but no model ref selects it yet, so no agent
    #                           runs on it until one does.  This row is what keeps the key alive:
    #                           the sweep stops deleting it and the manager-env push carries it.
    #                           Measured 2026-10-09: `openclaw models list --provider
    #                           qwen-token-plan` resolves 15 models, Auth yes.
    ("gateway.auth.token", "OPENCLAW_GATEWAY_TOKEN"),
    ("talk.providers.elevenlabs.apiKey", "ELEVENLABS_API_KEY"),
    ("models.providers.qwen-token-plan.apiKey", "QWEN_TOKEN_PLAN_API_KEY"),
]

def set_path(node, path, value):
    parts = path.split(".")
    for p in parts[:-1]:
        node = node.setdefault(p, {})
    node[parts[-1]] = value

def get_path(node, path):
    for p in path.split("."):
        if not isinstance(node, dict) or p not in node:
            return None
        node = node[p]
    return node

cfg = {}
try:
    with open(os.path.expanduser("~/.openclaw/openclaw.json")) as f:
        cfg = json.load(f)
except Exception as exc:
    print(f"[tac] warning: could not read openclaw.json ({exc}); patching from an empty config", file=sys.stderr)

patch, changed, skipped = {}, 0, 0
for path, var in entries:
    if not os.environ.get(var):
        skipped += 1
        continue
    ref = {"source": "env", "provider": "default", "id": var}
    if get_path(cfg, path) == ref:
        continue  # already correct — no write needed
    set_path(patch, path, ref)
    changed += 1

# 2026-09-22: name the credentials the config REFERENCES but this table does not
# map. A ref that is not env-backed (source "store", or an older shape) reaches no
# env var, so oc-refresh-keys cannot inject it and the key reads as "imported from
# Windows but missing" — the TYPESAFE_API_KEY confusion, where the key sat in the
# bridge and was declared in the config and still never reached the gateway.
# Report the exact path and env var so the fix is the one-line table edit above.
# Never rewrite the ref here: a store-backed ref may be deliberate.
# 2026-09-22 (Pass C): ONE report for the three states a bridged key can be in,
# replacing two separate ones — the env sync listed every un-consumed key by name,
# and this walk named every non-env ref. Only the THIRD state is actionable, so
# only it is named; the second is a count, because a key with no consumer yet is
# not an error (RESMED_PASSWORD is waiting for one and otherwise reads as one of
# 27 failures).
#   injected        an env-backed ref exists, or this run is writing one
#   waiting         nothing in the config references it yet
#   NOT injectable  the config references it from a NON-env source (store), which
#                   no env var can ever fill — needs a mapping row or a decision
refs_env, refs_other = set(), []
def _collect(node, prefix=""):
    if isinstance(node, dict):
        if isinstance(node.get("id"), str) and "source" in node:
            if node.get("source") == "env":
                refs_env.add(node["id"])
            else:
                refs_other.append((node["id"], prefix, node.get("source")))
        for key, value in node.items():
            _collect(value, "{}.{}".format(prefix, key) if prefix else key)
    elif isinstance(node, list):
        for i, value in enumerate(node):
            _collect(value, "{}[{}]".format(prefix, i))

_collect(cfg)
# The table is about to make these env-backed, so count them as injected rather
# than reporting the pre-patch state (the staleness fixed in the reorder earlier).
refs_env |= {var for _, var in entries if os.environ.get(var)}
bridged = set()
_cache_file = os.path.join(os.environ.get("TAC_CACHE_DIR", "/dev/shm"), "tac_win_api_keys")
try:
    with open(_cache_file, encoding="utf-8") as _fh:
        for _line in _fh:
            if _line.startswith("export "):
                _nm = _line[7:].split("=", 1)[0]
                if _nm and _nm == _nm.upper() and _nm.replace("_", "").isalnum():
                    bridged.add(_nm)
except OSError as _exc:
    print("[tac] gateway env: cannot read the bridge cache ({})".format(_exc), file=sys.stderr)
if bridged:
    _injected = len(bridged & refs_env)
    _gaps = sorted({(v, p, s) for (v, p, s) in refs_other if v in bridged})
    _waiting = len(bridged - refs_env - {v for v, _p, _s in refs_other})
    _msg = "[tac] gateway env: {} injected, {} waiting for a consumer".format(_injected, _waiting)
    if _gaps:
        _msg += " -- NOT injectable (config refs with a NON-env source): " + ", ".join(
            "{}@{} (source {})".format(v, p, s) for v, p, s in _gaps
        )

    # 2026-10-01 (Wayne): NAME the credentials placed on NO surface, rather than counting them.
    # "waiting for a consumer" and "placed nowhere" are different states: a key no config ref
    # names can still be carried by the unit's EnvironmentFile or the environment.d drop-in
    # (GITHUB_TOKEN, TAILSCALE_API_KEY are), and a consumer can read it there. A key on no
    # surface at all is readable by nothing, however long it sits in the bridge -- the
    # "imported from Windows but missing" class, which is expensive to rediscover.
    #
    # Surfaces counted: an env-backed config ref (the durable, sweep-proof place), a config ref
    # with any other source, the unit's EnvironmentFile, the environment.d drop-in, and the
    # systemd user-manager env. The manager env is this script's own push target; when it cannot
    # be read (no user bus -- the agent/CI shell case) the recorded pushed set stands in and the
    # message says which was used, so a bus-less refresh cannot report every un-referenced key
    # as unplaced.  Measured 2026-10-01: no bridged key is carried by the manager env ALONE, so
    # counting it or not changes nothing today; it is read anyway because Wayne's surface list
    # includes it.
    def _surface_names(_path):
        _found = set()
        try:
            with open(os.path.expanduser(_path), encoding="utf-8") as _handle:
                for _raw in _handle:
                    _raw = _raw.strip()
                    if not _raw or _raw.startswith("#") or "=" not in _raw:
                        continue
                    _key = (_raw[7:] if _raw.startswith("export ") else _raw).split("=", 1)[0].strip()
                    if _key:
                        _found.add(_key)
        except FileNotFoundError:
            pass  # absent file: this surface places nothing (the expected case on a bare host)
        except OSError as _exc:
            print("[tac] gateway env: cannot read {} ({}); counting it as placing nothing".format(_path, _exc),
                  file=sys.stderr)
        return _found

    _manager_names, _manager_surface = set(), "the user-manager env"
    try:
        _manager_names = {
            _line.split("=", 1)[0]
            for _line in subprocess.run(["systemctl", "--user", "show-environment"],
                                        capture_output=True, text=True, timeout=20, check=False).stdout.splitlines()
            if "=" in _line
        }
    except (OSError, subprocess.SubprocessError) as _exc:
        _manager_surface = "the recorded push set (user-manager env unreadable: {})".format(_exc)
        try:
            with open(os.path.join(os.environ.get("TAC_CACHE_DIR", "/dev/shm"), "tac_win_api_keys.resolved"),
                      encoding="utf-8") as _handle:
                _manager_names = {_line.strip() for _line in _handle if _line.strip()}
        except OSError as _exc2:
            _manager_surface = "no surface at all (user-manager env AND the recorded push set are unreadable: {})".format(_exc2)
            _manager_names = set()

    _placed_surfaces = (refs_env
                        | {v for v, _p, _s in refs_other}
                        | _surface_names("~/.openclaw/gateway.systemd.env")
                        | _surface_names("~/.config/environment.d/90-openclaw.conf")
                        | _manager_names)
    _unplaced = sorted(bridged - _placed_surfaces)
    if _unplaced:
        _msg += (" -- ON NO SURFACE (bridged, but named by no config ref and present on neither the unit "
                 "EnvironmentFile, the environment.d drop-in, nor {}): {}".format(_manager_surface, ", ".join(_unplaced)))
    print(_msg, file=sys.stderr)
print(json.dumps({"patch": patch, "changed": changed, "skipped": skipped}))
PYEOF
)
    _patch=$(printf '%s' "$_patch_info" | "${TAC_PYTHON:-python3}" -c "import json,sys; print(json.dumps(json.load(sys.stdin)['patch']))" 2>/dev/null)
    _applied=$(printf '%s' "$_patch_info" | "${TAC_PYTHON:-python3}" -c "import json,sys; print(json.load(sys.stdin)['changed'])" 2>/dev/null)
    _skipped=$(printf '%s' "$_patch_info" | "${TAC_PYTHON:-python3}" -c "import json,sys; print(json.load(sys.stdin)['skipped'])" 2>/dev/null)
    if (( _applied > 0 )) && ! printf '%s' "$_patch" | openclaw config patch --stdin >/dev/null 2>&1; then
        _failed=$_applied
        _applied=0
    fi

    # ================================================================
    # Auth Profile SecretRef sync (SQLite credential stores)
    #
    # A SECOND channel for this key — the models.providers env-ref written above is
    # what actually resolves (measured 2026-10-01; a store ref alone is not sufficient):
    #   DEEPSEEK_API_KEY  →  deepseek:default.keyRef  (+ models.providers.deepseek.apiKey)
    #
    # These live in per-agent `openclaw-agent.sqlite` tables.
    #
    # Format: <profile-id>:<provider>::<cred-type>::<env-var>
    # NOTE: the profile's OWN `provider` field must equal the real provider id —
    # the auth resolver matches profiles via cred.provider === providerId
    # (listProfilesForProvider).  The `provider` inside the keyRef is a DIFFERENT
    # field, and its VALUE does not change resolution: measured 2026-10-01, "default"
    # and the real provider id both yield `secret reference was not found` for every
    # agent.  The bare entry below writes "default" (the shape the config's own refs
    # use, restored in d94687b1); the "<provider>:default" twin keeps the real id by
    # Wayne's rule of 2026-10-01.  Do not "reconcile" them on the assumption that
    # either one resolves -- neither is the fault (card OC-REFRESH-KEYS-AUTHPROFILE-001,
    # closed with that verdict).
    # ================================================================
    local _agents_root="${OC_AGENTS:-$HOME/.openclaw/agents}"
    # One python process for ALL agents x profiles (was one subprocess per
    # agent per profile — 45 spawns). Merges into each store's 'primary' row.
    local _auth_info _auth_applied=0 _auth_skipped=0 _auth_failed=0 _auth_config_error="" _auth_msg=""
    _auth_info=$("${TAC_PYTHON:-python3}" - "$_agents_root" <<'PYEOF' 2>/dev/null
import json, os, sqlite3, sys, time
agents_root = sys.argv[1]
# Format: (profile_id, provider, cred_type, env_var)
auth_map = [
    ("deepseek", "deepseek", "api_key", "DEEPSEEK_API_KEY"),
]
# Which agent is the DEFAULT one? The runtime resolves the CONFIG's auth.profiles for it, and
# its store must carry those ids too (see the "<provider>:default" write below).
default_agent = ""
config_error = ""
try:
    with open(os.path.join(os.environ.get("HOME", ""), ".openclaw", "openclaw.json"), encoding="utf-8") as _fh:
        default_agent = str(
            ((((json.load(_fh).get("agents") or {}).get("defaults") or {}).get("systemAgent") or {})
             .get("agentId")) or ""
        )
except Exception as exc:
    # Reported in the JSON below, never swallowed: without the id the config's
    # "<provider>:default" profile cannot be written and auth keeps failing.
    config_error = f"{type(exc).__name__}: {exc}"

changed = unchanged = skipped = 0
for name in sorted(os.listdir(agents_root)):
    db = os.path.join(agents_root, name, "agent", "openclaw-agent.sqlite")
    if not os.path.isfile(db):
        continue
    con = sqlite3.connect(db, timeout=8.0)
    row = con.execute("SELECT store_json FROM auth_profile_store WHERE store_key='primary'").fetchone()
    store = json.loads(row[0]) if row else {"version": 1, "profiles": {}}
    for pid, provider, ctype, var in auth_map:
        if not os.environ.get(var):
            skipped += 1
            continue
        # "default" is the shape an auth-profile ref MUST have.  A diagnosis said the resolver
        # matches cred.provider against the provider id, so "default" would hide the ref — that
        # was WRONG and is reverted here: with the real provider id written instead, the gateway
        # reported, for every agent, `[SECRETS_OWNER_UNAVAILABLE] Secret owner account:[<db>,
        # "deepseek"] … reason: secret reference was not found` (measured 2026-10-01).  The
        # config's own refs use "default" for the same reason.  The gateway reports the same
        # "not found" for the bare and the ":default" ids — so this pass is NOT where the
        # deepseek resolution fault lives; see card OC-REFRESH-KEYS-AUTHPROFILE-001.
        ref = {"source": "env", "provider": "default", "id": var}
        profile = {"type": ctype, "provider": provider}
        if ctype == "api_key":
            profile["keyRef"] = ref
        else:
            profile["tokenRef"] = ref
        store.setdefault("profiles", {})[pid] = profile
    # Its keyRef deliberately keeps the REAL provider id while the bare entry above writes
    # "default": both were measured to resolve identically, so the two sites are allowed to
    # differ (Wayne, 2026-10-01) -- see the header comment block above.
    # The CONFIG declares auth.profiles["<provider>:default"] and the runtime resolves THAT id
    # for the default agent, so a bare "<provider>" entry leaves it with no store entry
    # ("... is configured but unavailable (secret reference was not found)").  Scoped to the
    # default agent only: adding it to every agent's store raised the secrets-reload warning
    # count 19 -> 46 (measured 2026-09-30).
    if default_agent and name == default_agent:
        for _pid, provider, ctype, var in auth_map:
            if not os.environ.get(var):
                continue
            _ref = {"source": "env", "provider": provider, "id": var}
            _extra = {"type": ctype, "provider": provider}
            _extra["keyRef" if ctype == "api_key" else "tokenRef"] = _ref
            store.setdefault("profiles", {})[f"{provider}:default"] = _extra
    # Write only when the merged store actually differs — no-op refreshes
    # perform zero sqlite writes. Compare parsed dicts (order-insensitive).
    new_json = json.dumps(store, sort_keys=True)
    if row and json.loads(row[0]) == store:
        unchanged += 1
        con.close()
        continue
    con.execute(
        "INSERT OR REPLACE INTO auth_profile_store (store_key, store_json, updated_at) VALUES ('primary', ?, ?)",
        (new_json, int(time.time() * 1000)),
    )
    con.commit()
    con.close()
    changed += 1
print(json.dumps({
    "stores_written": changed,
    "stores_unchanged": unchanged,
    "skipped": skipped,
    "default_agent": default_agent,
    "config_error": config_error,
}))
PYEOF
)
    _auth_applied=$(printf '%s' "$_auth_info" | "${TAC_PYTHON:-python3}" -c "import json,sys; print(json.load(sys.stdin)['stores_written'])" 2>/dev/null)
    _auth_unchanged=$(printf '%s' "$_auth_info" | "${TAC_PYTHON:-python3}" -c "import json,sys; print(json.load(sys.stdin)['stores_unchanged'])" 2>/dev/null)
    # Visible, never silent: without the config's default-agent id the "<provider>:default"
    # profile the runtime resolves is NOT written, and auth keeps failing.  No stderr
    # redirect here on purpose — a result this cannot parse is itself reported below.
    if ! _auth_config_error=$(printf '%s' "$_auth_info" \
        | "${TAC_PYTHON:-python3}" -c "import json,sys; print(json.load(sys.stdin).get('config_error',''))")
    then
        _auth_config_error="<the auth-sync result could not be parsed>"
    fi
    if [[ -n "$_auth_config_error" ]]
    then
        _auth_msg="[could NOT read agents.defaults.systemAgent from openclaw.json: $_auth_config_error"
        _auth_msg+=" — the config's '<provider>:default' auth profile was NOT written]"
        __tac_info "Syncing Auth Profile SecretRefs" "$_auth_msg" "$C_Warning"
    fi

    if (( _auth_applied > 0 ))
    then
        __tac_info "Syncing Auth Profile SecretRefs" "[$_auth_applied store(s) written, $_auth_unchanged unchanged]" "$C_Success"
    else
        __tac_info "Syncing Auth Profile SecretRefs" "[no stores changed ($_auth_unchanged verified)]" "$C_Dim"
    fi

    # Combined summary — report config refs and auth-profile writes separately
    # so the counts are not conflated with the number of imported env vars.
    if (( _failed > 0 ))
    then
        __tac_info "Syncing OpenClaw SecretRefs" "[config refs: $_applied applied, $_skipped skipped, $_failed failed | auth profiles: $_auth_applied writes]" "$C_Warning"
    elif (( _applied > 0 || _auth_applied > 0 ))
    then
        __tac_info "Syncing OpenClaw SecretRefs" "[config refs: $_applied applied, $_skipped skipped | auth profiles: $_auth_applied writes]" "$C_Success"
    else
        __tac_info "Syncing OpenClaw SecretRefs" "[nothing to update — all refs current]" "$C_Dim"
    fi
}

# ---------------------------------------------------------------------------
# __oc_gateway_resolved_env_names — print the env var names the OpenClaw gateway
# actually resolves as secrets, one per line, sorted and unique:
#   * env-backed SecretRefs in openclaw.json   ({"source":"env",...,"id":NAME})
#   * env-backed refs in every agent's auth-profile store (auth_profile_store)
#
# 2026-09-13: so()/oc-refresh-keys used to push EVERY bridged Windows var into the
# systemd user manager environment, so every user unit (dbus, pipewire, the llama
# servers, ...) inherited ~45 secrets it never reads — readable by any same-user
# process via /proc/<pid>/environ. Injection is now narrowed to this set. Prints
# nothing if the set cannot be computed (callers warn and fall back).
# ---------------------------------------------------------------------------
function __oc_gateway_resolved_env_names() {
    local _cfg="${OPENCLAW_CONFIG_PATH:-$HOME/.openclaw/openclaw.json}"
    local _state="${OPENCLAW_STATE_DIR:-$HOME/.openclaw}"
    "${TAC_PYTHON:-python3}" - "$_cfg" "$_state" <<'PY' 2>/dev/null
import glob, json, os, re, shutil, sqlite3, sys, tempfile

cfg_path, state = sys.argv[1], sys.argv[2]
names = set()

raw = None
if os.path.exists(cfg_path):
    with open(cfg_path, encoding='utf-8') as fh:
        raw = fh.read()
if raw is not None:
    doc = None
    try:
        doc = json.loads(raw)
    except Exception:
        # openclaw.json is JSON5 (comments + trailing commas allowed)
        try:
            stripped = re.sub(r'^\s*//.*$', '', raw, flags=re.M)
            doc = json.loads(re.sub(r',(\s*[}\]])', r'\1', stripped))
        except Exception:
            doc = None
    if doc is not None:
        stack = [doc]
        while stack:
            node = stack.pop()
            if isinstance(node, dict):
                if node.get('source') == 'env' and isinstance(node.get('id'), str):
                    names.add(node['id'])
                stack.extend(node.values())
            elif isinstance(node, list):
                stack.extend(node)

for db in glob.glob(os.path.join(state, 'agents', '*', 'agent', 'openclaw-agent.sqlite')):
    tmp = os.path.join(tempfile.mkdtemp(), 'store.sqlite')
    try:
        shutil.copy(db, tmp)
        conn = sqlite3.connect(f'file:{tmp}?mode=ro', uri=True)
        for (blob,) in conn.execute('select store_json from auth_profile_store'):
            for hit in re.finditer(r'"id"\s*:\s*"([A-Z_][A-Z0-9_]*)"', blob or ''):
                names.add(hit.group(1))
        conn.close()
    except Exception:
        continue

print('\n'.join(sorted(names)))
PY
}

# ---------------------------------------------------------------------------
# __oc_sync_gateway_env_file — Push bridged env vars into the systemd user manager
# environment (the secrets channel), which the gateway (a user service) inherits.
# It deliberately does NOT rewrite the unit or gateway.systemd.env — see step 2 for
# why, and reconcile a drifted managed-key list with `openclaw gateway install
# --force`. Restart is signalled only when the bridged
# values actually changed (content-hash comparison — comparing against
# `systemctl --user show-environment` is unreliable because it ANSI-quotes
# values that contain special characters). It also NAMES the bridged vars it
# does not inject, so the narrowing is visible instead of silent (2026-09-21).
# ---------------------------------------------------------------------------
function __oc_sync_gateway_env_file() {
    local _cache="$1"
    [[ -f "$_cache" ]] || return 0

    # Collect all var names from the cache that the gateway may need.
    local _var_names=()
    local _line _name
    while IFS= read -r _line; do
        [[ "$_line" =~ ^export[[:space:]]+ ]] || continue
        _name="${_line#export }"; _name="${_name%%=*}"
        [[ "$_name" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
        _var_names+=("$_name")
    done < "$_cache"

    mapfile -t _var_names < <(printf '%s\n' "${_var_names[@]}" | sort -u)
    ((${#_var_names[@]})) || return 0

    # 2026-09-13: narrow the manager-env push to the vars the gateway actually
    # resolves (see __oc_gateway_resolved_env_names). Fail-open with a warning if
    # the set cannot be computed — a config/DB hiccup must not silently starve
    # the gateway of a key it needs.
    local _resolved _kept=() _n
    _resolved="$(__oc_gateway_resolved_env_names)"
    if [[ -n "$_resolved" ]]; then
        # Iterate the array directly. This used to read it back through
        # `done < <(printf '%s\n' "${_var_names[@]}")`, which forks a printf and
        # a subshell to hand an already-in-memory array to `read` one line at a
        # time — item 6.4's shape without the file it was written for.
        for _n in "${_var_names[@]}"; do
            [[ -n "$_n" ]] || continue
            grep -qxF "$_n" <<< "$_resolved" && _kept+=("$_n")
        done
        _var_names=("${_kept[@]}")
    else
        __tac_info "Security" "[WARN: resolved-env set unavailable — pushing the full bridged set]" "$C_Warning"
    fi

    ((${#_var_names[@]})) || return 0

    # 1. Inject the resolved set, gated on BOTH the bridged values and the
    #    injected names — see __oc_inject_manager_env for why the name set is a
    #    trigger in its own right (2026-09-22).
    __oc_inject_manager_env "$_cache" "${_var_names[@]}"

    # 2. Do NOT rewrite the systemd unit. OpenClaw fingerprints its own unit
    #    definition (path + bytes + manager uid) before it stops the service
    #    for an update/repair, then re-validates it afterwards; an in-place
    #    edit of the Environment= line changes that fingerprint and the repair
    #    aborts with "Gateway service ownership or manager identity changed"
    #    (observed 2026-09-13: `openclaw doctor --fix` could not complete
    #    maintenance after this script rewrote the line at 10:50). The list is
    #    read from the process environment
    #    (readManagedServiceEnvKeysFromEnvironment), so it does not need to
    #    live in the unit at all. Values already reach the gateway through
    #    step 1 (`systemctl --user set-environment`) and the unit's
    #    `EnvironmentFile=-…/gateway.systemd.env`; this list only tunes
    #    hot-reload bookkeeping, and oc-refresh-keys restarts the gateway on
    #    any real value change (steps 5–7) — so nothing is lost by leaving
    #    OpenClaw's own list alone. Reconcile a drifted list by letting
    #    OpenClaw re-author the unit (`openclaw gateway install --force`,
    #    owner action), never by editing it here.

}

# ---------------------------------------------------------------------------
# __oc_inject_manager_env — push the resolved names into the systemd user manager
# environment (the secrets channel the gateway inherits), but only when something
# that affects the injection actually changed: the bridged VALUES (a content hash
# of the cache) or the injected NAME set.
#
# 2026-09-22 — the name set is its own trigger. Consuming a key as an env-backed
# SecretRef changes WHICH names are injected without changing any key VALUE, so a
# hash-only trigger left a newly-declared key out of the manager env for good and
# read exactly like a failed import (TYPESAFE_API_KEY: bridged from Windows and
# declared in openclaw.json, and still never injected, because no bridged value
# had changed since the hash was recorded). Recording the set that was pushed also
# means removing a SecretRef stops re-injecting that name rather than leaving it
# in the manager env forever.
#
# Usage: __oc_inject_manager_env <cache-file> <name>...
# Sets _OC_GW_ENV_CHANGED=1 when it injected, so the caller signals a restart.
# ---------------------------------------------------------------------------
function __oc_inject_manager_env() {
    local _cache="$1"
    shift
    local _hash_file="$TAC_CACHE_DIR/tac_win_api_keys.hash"
    local _set_file="$TAC_CACHE_DIR/tac_win_api_keys.resolved"
    local _hash _prev_hash _now_set _prev_set _name
    _hash=$(grep '^export ' "$_cache" | sort | sha256sum | awk '{print $1}')
    _prev_hash=$(cat "$_hash_file" 2>/dev/null || echo none)
    _now_set=$(printf '%s\n' "$@" | sort -u)
    _prev_set=$(cat "$_set_file" 2>/dev/null || echo none)
    local _failed=()
    if [[ "$_hash" != "$_prev_hash" || "$_now_set" != "$_prev_set" ]]; then
        for _name in "$@"; do
            # swallow-ok: a refresh also runs where there is no user bus (the agent/CI
            # shell case) — a failure is counted below, keeps the markers unwritten and
            # is reported, rather than being swallowed here
            systemctl --user set-environment "$_name=${!_name:-}" 2>/dev/null || _failed+=("$_name")
        done
        _OC_GW_ENV_CHANGED=1
    fi
    # A push that did not happen must not be RECORDED as one. These two markers are
    # the only thing that stops the next refresh from pushing — they are what makes
    # the name-set trigger a no-op when nothing changed — so writing them after a
    # failed push ends the injection for good: every later run, an interactive one
    # included, compares equal, decides "no change", and skips the push in silence.
    # Measured 2026-09-27: with no user bus `systemctl --user set-environment` fails
    # with "Failed to connect to bus: No medium found" (rc=1), which is exactly the
    # agent-shell case this file already handles elsewhere. Leave both markers alone
    # and let the next run retry (set-environment is idempotent).
    if (( ${#_failed[@]} > 0 ))
    then
        __tac_info "Gateway" "[${#_failed[@]} of $# key(s) NOT pushed to the manager env — will retry]" "$C_Warning"
        return 0
    fi
    # Record BOTH halves of the trigger, so a refresh that changed either one is
    # detected next time and a refresh that changed neither stays a no-op. The
    # set that was pushed is the set that is recorded.
    printf '%s\n' "$_hash" > "$_hash_file"
    printf '%s\n' "$_now_set" > "$_set_file"
}

# ---------------------------------------------------------------------------
# oc-refresh-keys — Force re-import of Windows API keys into WSL, persist to
# systemd env, and sync OpenClaw SecretRefs to the refreshed env credentials.
# The Windows User environment is the canonical source; local copies (.env,
# gateway.systemd.env, auth profiles) reference it rather than holding their
# own plaintext values.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# __oc_nas_export_names — the bridged names the NAS actually CONSUMES.
#
# Derived from the NAS side, not from the bridge: every script the NAS's own
# crontab runs was read over SSH (measured 2026-10-02, /mnt/HD/HD_a2/butler):
#
#   glowmarkt-collector.py   (cron */30)   GLOWMARKT_PASSWORD
#       `_load_creds()` takes each field from the environment first and the
#       secrets file second, and its own docstring says GLOWMARKT_PASSWORD "is
#       imported from the Windows environment by oc-refresh-keys". It also reads
#       GLOWMARKT_USERNAME / _TOKEN_FILE / _DATA_DIR from the environment, but the
#       bridge never carries those — nothing in them matches its TOKEN/KEY/
#       PASSWORD/CLIENT_ID/API pattern — so selecting from the cache excludes them
#       without a rule of their own.
#   cpap-myair-collector.py / cpap-myair-fetch.py   (cron 20 7)   RESMED_PASSWORD
#       After the 2026-10-02 consolidation in workspace-jarvis the fetch resolves
#       the password by CANONICAL name (RESMED_PASSWORD, with CPAP_MYAIR_PASSWORD
#       as its documented fallback), and the bridge carries that name. The CPAP_*
#       settings the NAS job needs (CPAP_COLLECT_COMMAND, CPAP_INFLUX_*) are NOT
#       bridged, so this export was never that job's only channel anyway. If the
#       NAS CPAP job is retired, delete this line: nothing else changes.
#   air-monitor-curl-collector.sh, it500-influx-collector.py,
#   nas_health_collector.py, internet-quality-monitor.sh, bt-bridge, and
#   glowmarkt's INFLUXDB_* overrides: no bridged name at all.
#
# Adding a NAS consumer means adding its names HERE, with the file that reads
# them — never by widening the export back to the whole cache.
#
# Prints one name per line.
# ---------------------------------------------------------------------------
function __oc_nas_export_names() {
    cat <<'NAMES'
GLOWMARKT_PASSWORD
RESMED_PASSWORD
NAMES
}

# ---------------------------------------------------------------------------
# __oc_nas_export_render <cache> — print the FILE that would be uploaded.
#
# The caller has SOURCED the cache, so values are read from the environment and the
# cache is iterated for names only (see oc-export-keys-nas for why that ordering is
# a correctness requirement). Only names __oc_nas_export_names selects are printed,
# under a header that records what the file is and which names were selected.
#
# %q alone is the correct escaping: it yields a shell word that round-trips to the
# exact value. Wrapping it in double quotes double-escapes (e.g. a "!" password
# becomes GlowforHomes\!…), which the NAS collector would read back wrong.
#
# The header carries a TIMESTAMP, so it must never enter the upload marker's hash;
# the caller hashes only the `export ` lines.
# ---------------------------------------------------------------------------
function __oc_nas_export_render() {
    local _cache="$1" _want _l _k _v
    local -A _wanted=()
    while IFS= read -r _want
    do
        if [[ -n "$_want" ]]; then _wanted["$_want"]=1; fi
    done < <(__oc_nas_export_names)
    printf '# regenerated by oc export-keys-nas %s\n' "$(date -Iseconds)"
    printf '# selected names (%s); the rest of the bridge is not exported\n' \
        "$(__oc_nas_export_names | tr '\n' ' ')"
    while IFS= read -r _l
    do
        [[ "$_l" =~ ^export[[:space:]]+ ]] || continue
        _k="${_l#export }"; _k="${_k%%=*}"
        [[ "$_k" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
        [[ -n "${_wanted[$_k]:-}" ]] || continue
        _v="${!_k:-}"
        [[ -n "$_v" ]] || continue
        printf 'export %s=%q\n' "$_k" "$_v"
    done < "$_cache"
}

# ---------------------------------------------------------------------------
# __oc_nas_preflight_reason <ssh-key-path> — why no SSH transport was built.
#
# The three causes need different repairs (install a client / install the key /
# investigate a key that exists but did not work), so they are told apart rather
# than collapsed into one "failed". Prints the clause the report shows.
# ---------------------------------------------------------------------------
function __oc_nas_preflight_reason() {
    local _key="$1"
    if ! command -v ssh >/dev/null 2>&1
    then
        printf '%s' "ssh missing"
    elif [[ ! -f "$_key" ]]
    then
        printf 'SSH key missing (%s)' "$_key"
    else
        printf '%s' "preflight failed"
    fi
}

# ---------------------------------------------------------------------------
# __oc_nas_upload_cmd <target-path> — the remote command that installs the file.
#
# It creates the temporary file under `umask 077`, chmods it, moves it into place
# atomically, chmods the result, and PRINTS THE RESULTING MODE. The mode matters
# because the file carries credentials: the previous version left it 644 — 48
# credentials world-readable on the NAS, measured 2026-10-02 — and never looked.
# Printing it makes the caller's check a read-back instead of an assumption.
# ---------------------------------------------------------------------------
function __oc_nas_upload_cmd() {
    local _t="$1"
    printf 'umask 077'
    printf ' && cat > "%s.tmp"' "$_t"
    printf ' && chmod 600 "%s.tmp"' "$_t"
    printf ' && mv -f "%s.tmp" "%s"' "$_t" "$_t"
    printf ' && chmod 600 "%s"' "$_t"
    printf ' && stat -c %%a "%s"' "$_t"
}

# ---------------------------------------------------------------------------
# __oc_nas_export_show <built-file> — the dry-run table.
#
# One line per selected name with the value's LENGTH and sha256[:12] — never the
# value. This is the review step: the exported set is inspectable before it reaches
# the NAS.
# ---------------------------------------------------------------------------
function __oc_nas_export_show() {
    local _f="$1" _l _k _v _fp
    while IFS= read -r _l
    do
        [[ "$_l" == export\ * ]] || continue
        _k="${_l#export }"; _k="${_k%%=*}"
        _v="${!_k:-}"
        _fp=$(printf '%s' "$_v" | sha256sum | cut -c1-12)
        printf '  %-24s len=%-4s sha256=%s\n' "$_k" "${#_v}" "$_fp"
    done < "$_f"
}

# ---------------------------------------------------------------------------
# __oc_nas_resolve_host <ssh-key-path> <ssh-user> <dry-run:0|1> — the NAS SSH
# route, resolved AT RUN TIME.
#
# The old default was a hardcoded Tailscale IP (100.106.225.96), with a comment
# claiming LAN SSH "times out from WSL". Both are false now (measured 2026-10-08):
# that address is not in `tailscale status` at all (the node is 100.83.76.103),
# while LAN 192.168.33.20 answers from this host (uid=0) — so a changed cache
# silently took the "[failed -- SSH sync error]" branch and the mirror stopped
# updating. OC_NAS_HOST still wins if set; otherwise probe the LAN address, then
# the current tailnet one, so the export works on- and off-LAN.
# ---------------------------------------------------------------------------
function __oc_nas_resolve_host() {
    local _key="$1" _user="$2" _dry_run="$3"
    if [[ -n "${OC_NAS_HOST:-}" ]]
    then
        printf '%s\n' "$OC_NAS_HOST"
        return 0
    fi
    if [[ "$_dry_run" != "1" && -f "$_key" ]] && command -v ssh >/dev/null 2>&1
    then
        local _cand _ssh_opts=(-i "$_key" -o BatchMode=yes -o ConnectTimeout=4 -o StrictHostKeyChecking=no)
        for _cand in 192.168.33.20 100.83.76.103
        do
            # swallow-ok: a failed probe's ssh connection error IS the reachability signal
            if ssh "${_ssh_opts[@]}" "${_user}@${_cand}" true 2>/dev/null
            then
                printf '%s\n' "$_cand"
                return 0
            fi
        done
    fi
    printf '%s\n' "192.168.33.20"
}

# ---------------------------------------------------------------------------
# oc-export-keys-nas — mirror the bridged key cache to the NAS.
#
# Extracted from oc-refresh-keys (2026-09-22): a backup job does not belong inside
# a key refresh. It keeps its own SSH preflight, one connection per run, and a
# marker recording the hash of the CONTENT it last uploaded — so "is the mirror
# behind?" is an exact question. The marker is written only after a successful
# upload, so a failed sync is retried on the next run. Run it standalone
# (`oc export-keys-nas`), from a timer, or with `--dry-run` to review the set.
#
# TWO DEFECTS FIXED 2026-10-02 (both measured on the NAS over SSH):
#   1. The file it wrote was mode 644 — 48 credentials world-readable, against
#      this box's own bridge cache at 600. It is now created under `umask 077`,
#      chmod-ed 600, and the mode is READ BACK: an upload whose mode is not 600
#      is reported as a failure instead of a success.
#   2. It shipped every bridged name. The NAS's own code reads TWO of them
#      (__oc_nas_export_names records which, and from where). The rest reached a
#      readable file on a host that never read them.
# ---------------------------------------------------------------------------
function oc-export-keys-nas() {
    local cache="$TAC_CACHE_DIR/tac_win_api_keys"
    local _nas_collectors_env="/mnt/HD/HD_a2/butler/cron/openclaw-collectors.env"
    local _nas_user="${OC_NAS_USER:-sshd}"
    # --dry-run reports what WOULD be written (names + value fingerprints, never
    # values) and touches nothing, so the exported set can be reviewed before it
    # reaches the NAS.
    local _dry_run=0
    if [[ "${1:-}" == "--dry-run" ]]
    then
        _dry_run=1
    fi
    local _nas_key="${OC_NAS_KEY_PATH:-$HOME/.ssh/jarvis_sshd_key}"
    # The SSH route is resolved at run time (__oc_nas_resolve_host): the LAN
    # address first, then the current tailnet one, so it works on and off LAN.
    local _nas_host
    _nas_host="$(__oc_nas_resolve_host "$_nas_key" "$_nas_user" "$_dry_run")"
    if [[ ! -f "$cache" ]]
    then
        __tac_info "Exporting to NAS" "[no bridge cache — run 'oc refresh-keys' first]" "$C_Warning"
        return 1
    fi
    # Source the cache. This command iterates the cache for NAMES but reads the
    # VALUES from the environment, so a standalone run (a timer, or right after a
    # reboot) would otherwise export a file containing only its header and then
    # mark that as synced — silent data loss. Sourcing here is a correctness
    # requirement, not a convenience.
    # shellcheck source=/dev/null
    if ! source "$cache" 2>/dev/null
    then
        __tac_info "Exporting to NAS" "[cache unreadable — run 'oc refresh-keys' first]" "$C_Warning"
        return 1
    fi
    local _cache_hash
    # The marker hashes the CONTENT this command would upload — the selected
    # names and their values — not the whole cache. Keying it on the cache made a
    # change to the SELECTION invisible (the hash still matched, so the upload was
    # skipped and the new set never landed). The timestamped header is excluded, or
    # every run would look like a change.
    local _nas_names _nas_tmp _n_written _n_selected _n_absent
    _nas_names="$(__oc_nas_export_names)"
    _nas_tmp="$(mktemp)"
    __oc_nas_export_render "$cache" > "$_nas_tmp"
    _cache_hash=$(awk '/^export /' "$_nas_tmp" | sort | sha256sum | awk '{print $1}')
    # The counts come from the rendered file itself, so they cannot drift from what
    # is actually uploaded.
    _n_written=$(awk '/^export / { n++ } END { print n + 0 }' "$_nas_tmp")
    _n_selected=$(awk 'END { print NR + 0 }' <<< "$_nas_names")
    _n_absent=$(( _n_selected - _n_written ))
    if (( _dry_run == 1 ))
    then
        printf '%s\n' "oc export-keys-nas --dry-run — what would be written to:"
        printf '  %s\n' "$_nas_collectors_env"
        __oc_nas_export_show "$_nas_tmp"
        rm -f "$_nas_tmp"
        __tac_info "Exporting to NAS" "[dry run — $_n_written name(s), nothing uploaded]" "$C_Dim"
        return 0
    fi
    local _prev_nas_hash
    _prev_nas_hash=$(cat "$TAC_STATE_DIR/tac_win_api_keys.nas_hash" 2>/dev/null || echo none)
    local _nas_ssh=()
    if [[ -f "$_nas_key" ]] && command -v ssh >/dev/null 2>&1
    then
        _nas_ssh=(ssh -i "$_nas_key" -o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=no "${_nas_user}@${_nas_host}")
    elif command -v sshpass >/dev/null 2>&1 && [[ -n "${SSH_PASSWORD:-}" ]]
    then
        _nas_ssh=(sshpass -p "$SSH_PASSWORD" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=6 "${_nas_user}@${_nas_host}")
    fi
    if ((${#_nas_ssh[@]}))
    then
        local _synced_nas=0 _nas_skipped=0
        local _mode_ok=1 _remote_out=""
        if [[ "$_cache_hash" == "$_prev_nas_hash" ]]
        then
            _nas_skipped=1
        elif _remote_out=$("${_nas_ssh[@]}" "$(__oc_nas_upload_cmd "$_nas_collectors_env")" < "$_nas_tmp" 2>&1)
        then
            # The mode is a read-back, not an assumption: the file carries
            # credentials, and the previous version left it 644 (world-readable).
            if [[ "$_remote_out" == "600" ]]
            then
                _synced_nas=1
                mkdir -p "$TAC_STATE_DIR"
                printf '%s\n' "$_cache_hash" > "$TAC_STATE_DIR/tac_win_api_keys.nas_hash"
            else
                _mode_ok=0
            fi
        fi
        rm -f "$_nas_tmp"
        if (( _synced_nas == 1 ))
        then
            __tac_info "Exporting to NAS" "[$_n_written name(s) -> $_nas_collectors_env]" "$C_Success"
        elif (( _mode_ok == 0 ))
        then
            __tac_info "Exporting to NAS" "[uploaded but mode ${_remote_out:-unknown}, not 600]" "$C_Warning"
        elif (( _nas_skipped == 1 ))
        then
            __tac_info "Exporting to NAS" "[no changes — skipped]" "$C_Dim"
        else
            __tac_info "Exporting to NAS" "[failed — SSH sync error (auth or connectivity)]" "$C_Warning"
        fi
        # A SELECTED name with no value in the cache is not a quiet skip: the NAS
        # consumer that reads it gets nothing, and the upload above may still have
        # succeeded — so it is reported whatever the outcome was.
        if (( _n_absent > 0 ))
        then
            __tac_info "Exporting to NAS" "[$_n_absent selected name(s) absent from the cache]" "$C_Warning"
        fi
    else
        local _reason
        _reason="$(__oc_nas_preflight_reason "$_nas_key")"
        __tac_info "Exporting to NAS" "[skipped — ${_reason}]" "$C_Warning"
    fi
}

# ---------------------------------------------------------------------------
# __oc_report_gh_credential_surface — state where `gh` gets its token, and
# whether a `gh` call carrying none would reach the system keyring.
#
# `gh` prefers GH_TOKEN/GITHUB_TOKEN over any stored credential, and that
# precedence is absolute: with the token present, `gh auth token --hostname
# github.com` never contacts org.freedesktop.secrets; with it absent, the same
# call ACTIVATES the Secret Service, which creates the default keyring behind a
# password prompt when there is none. Measured 2026-09-23, reproducing the
# 10:52:57 prompt (the ChatGPT/Codex VS Code extension's GitHub-media path runs
# `gh auth token --hostname github.com` from an environment carrying no token).
# Nothing here reported the state that made it possible, which is why this
# witness exists. It reads files and the manager env, never runs `gh`, so it
# cannot prompt. Full record: README "GitHub CLI credentials", docs/openclaw.md.
# Related: bin/gh (installed as ~/.local/bin/gh) closes the PATH gap.
# ---------------------------------------------------------------------------
function __oc_report_gh_credential_surface() {
    local _cache="$1"
    local _cfg_dir="${GH_CONFIG_DIR:-$HOME/.config/gh}"
    local _env_dropin="$HOME/.config/environment.d/90-openclaw.conf"
    local _surfaces=""

    if grep -q '^export GH_TOKEN=' "$_cache"
    then
        _surfaces="bridge cache"
    fi
    # A refresh also runs where there is no user manager at all (agent and CI
    # shells), so a failing systemctl is the honest read here: "no manager env in
    # this context" is a fact this report states, not a defect to hide.
    # swallow-ok: systemctl is absent in agent/CI shells, and the surface set is reported either way
    if systemctl --user show-environment 2>/dev/null | grep -q '^GH_TOKEN='
    then
        _surfaces="${_surfaces:+$_surfaces + }systemd user env"
    fi
    if [[ -f "$_env_dropin" ]] && grep -q '^GH_TOKEN=' "$_env_dropin"
    then
        _surfaces="${_surfaces:+$_surfaces + }environment.d"
    fi

    # gh's own config: hosts.yml recording a user with NO plaintext oauth_token
    # means the credential is not in the FILE, so a gh invoked with no token in
    # its environment has to ASK the credential store — and that ask is what
    # activates gnome-keyring. Do not read more into this than the file shows:
    # measured 2026-09-23 on this box, the Default keyring holds ZERO items, so
    # gh has no stored credential to find; the call activates the service and
    # then fails with "no oauth token found for github.com".
    local _no_plaintext_token="no"
    if [[ -f "$_cfg_dir/hosts.yml" ]] \
        && grep -q '^[[:space:]]*user:' "$_cfg_dir/hosts.yml" \
        && ! grep -q '^[[:space:]]*oauth_token:' "$_cfg_dir/hosts.yml"
    then
        _no_plaintext_token="yes"
    fi

    # LENGTH BUDGET: `__tac_info` pads the label out to UIWidth (80) and drops the
    # padding to a single space when label+status overflows, which silently unaligns
    # the whole report — measured 2026-09-23 on an early version of these lines, whose
    # 150- and 122-character statuses broke the column in Wayne's own output. Every
    # status below therefore keeps len(label) + len(status) <= 79. Detail that does
    # not change a decision lives in README "GitHub CLI credentials" / docs/openclaw.md.
    local _msg _colour
    if [[ -z "$_surfaces" ]]
    then
        _msg="GH_TOKEN on no env surface — gh reaches the credential store"
        _colour="$C_Warning"
    else
        _msg="GH_TOKEN on: $_surfaces"
        _colour="$C_Success"
    fi
    __tac_info "GitHub CLI" "[$_msg]" "$_colour"
}

# ---------------------------------------------------------------------------
# __oc_report_gh_path_shim — say whether the gh shim is installed AND still wins.
#
# The PATH shim is the only thing that covers a caller inheriting NONE of the
# surfaces `__oc_report_gh_credential_surface` reports, and it is a symlink in
# ~/.local/bin — so a missing or outranked one silently restores the fall-through
# that whole change exists to stop. Split out of that report rather than left
# inside it: with three concerns in one function it had grown past 100 lines.
# ---------------------------------------------------------------------------
function __oc_report_gh_path_shim() {
    local _shim="$HOME/.local/bin/gh" _gh_resolved="" _state _colour
    local _shim_ok=1
    # `command -v` writes nothing to stderr for a missing command, so the exit code
    # is the whole signal and is handled here rather than hidden behind a redirect.
    if ! _gh_resolved="$(command -v gh)"; then
        _gh_resolved=""
    fi
    if [[ ! -e "$_shim" ]]
    then
        _state="MISSING — install.sh links bin/gh to ~/.local/bin"
        _colour="$C_Warning"
        _shim_ok=0
    elif [[ "$_gh_resolved" != "$_shim" ]]
    then
        _state="not first on PATH: ${_gh_resolved:-nothing}"
        _colour="$C_Warning"
        _shim_ok=0
    else
        _state="installed and first on PATH"
        _colour="$C_Success"
    fi
    __tac_info "GitHub CLI shim" "[$_state]" "$_colour"

    # The credential FILE only decides something when the shim is not covering
    # callers, and then it is the whole consequence: a gh carrying no token asks the
    # credential store, and with no plaintext token in hosts.yml there is nothing
    # there to find — the ask is what activates gnome-keyring. Measured 2026-09-23:
    # with no default keyring present, the ask CREATED one behind a password prompt.
    # Kept off the healthy output because the residual it warns about (a caller
    # bypassing PATH entirely) is not something this line can see.
    if (( _shim_ok == 0 ))
    then
        local _cfg_dir="${GH_CONFIG_DIR:-$HOME/.config/gh}"
        if [[ -f "$_cfg_dir/hosts.yml" ]] \
            && grep -q '^[[:space:]]*user:' "$_cfg_dir/hosts.yml" \
            && ! grep -q '^[[:space:]]*oauth_token:' "$_cfg_dir/hosts.yml"
        then
            __tac_info "GitHub CLI store" \
                "[no plaintext token: a token-less gh activates gnome-keyring]" "$C_Warning"
        fi
    fi
}

# ---------------------------------------------------------------------------
# __oc_fit_list — the longest "; "-joined prefix of a list that fits a length budget.
#
# Prints "<fitted>|<count>": the joined items that fit and how many of them there were.
# The reports in this file end in a __tac_info STATUS, and __tac_info keeps its column
# only while len(status) fits the width left after the label — an over-long status takes
# the padding down to a single space and unaligns the WHOLE report (measured 2026-09-23).
# Re-deriving "what fits" by hand is how that recurs: measured 2026-10-01, a wording
# change made a hardcoded fixed cost silently wrong and the line went past UIWidth with
# every test still naming the old constant. So a report hands this function the budget it
# actually has and names what fits, then a count of what did not.
# Usage: _fit=$( __oc_fit_list <budget> "${_items[@]}" )
# ---------------------------------------------------------------------------
function __oc_fit_list() {
    local _budget="$1"
    shift
    local _out="" _item _cand _n=0
    for _item in "$@"
    do
        _cand="${_out:+$_out; }$_item"
        (( ${#_cand} <= _budget )) || break
        _out="$_cand"
        _n=$(( _n + 1 ))
    done
    printf '%s|%s\n' "$_out" "$_n"
}

# ---------------------------------------------------------------------------
# __oc_shadowing_line — render the "Key shadowing" line for two name lists.
#
# __oc_shadowing_line <label> <differs: newline-separated> <unreadable: newline-separated>
#
# The lists carry NAMES and surfaces only — never a value — and the label is an argument
# so the width budget is derived from the same string __tac_info pads, which is the only
# way the two can agree (the failure this replaces was a budget assumed rather than
# measured). Split out of __oc_report_key_shadowing to keep that function bounded.
#
# LENGTH BUDGET (see __oc_report_gh_credential_surface). __tac_info pads the label out to
# UIWidth and keeps its column only while the whole label + 1 + status fits, so the status
# may not exceed UIWidth - len(label) - 1. Every constant here is DERIVED from the message
# actually being built: the fixed cost this used to assume was 20, and it went stale the
# moment the status grew a phrase and a per-name surface (measured 2026-10-01 — the line
# reached 108 characters and unaligned the report while both budget tests still asserted
# the old constant). The " +NN" reserve uses the TOTAL count as an upper bound on the
# remainder's digits, so a truncated list cannot grow past the budget it was fitted to.
# ---------------------------------------------------------------------------
function __oc_shadowing_line() {
    local _label="$1" _differs_in="$2" _unreadable_in="$3"
    local -a _differs=() _unreadable=()
    local _l
    while IFS= read -r _l
    do
        if [[ -n "$_l" ]]; then _differs+=("$_l"); fi
    done <<< "$_differs_in"
    while IFS= read -r _l
    do
        if [[ -n "$_l" ]]; then _unreadable+=("$_l"); fi
    done <<< "$_unreadable_in"
    local _max_status=$(( UIWidth - ${#_label} - 1 ))
    local _count_part
    if (( ${#_differs[@]} > 0 ))
    then
        _count_part="${#_differs[@]} differ from the bridge"
    else
        # Nothing seen to differ — which is only a statement about the surfaces that
        # COULD be read, and the clause below names which ones those were not.
        _count_part="no differences seen"
    fi
    # A surface that could not be read is reported EVERY time: an unreadable copy is
    # exactly where a divergence would hide, so silence would read as agreement — and it
    # is an alarm in its own right, not detail to drop when the names want the room.
    local _unread_clause=""
    if (( ${#_unreadable[@]} > 0 ))
    then
        local _uprefix="; NOT COMPARED: "
        local _ufit _ushown _un
        local _uroom=$(( _max_status - 1 - ${#_count_part} - 1 - ${#_uprefix} - 2 - ${#_unreadable[@]} ))
        _ufit=$( __oc_fit_list "$_uroom" "${_unreadable[@]}" )
        _ushown="${_ufit%|*}"
        _un="${_ufit##*|}"
        if (( _un == 0 ))
        then
            # Even one surface label cannot fit: the count alone still says the check could
            # not be completed, which is the part that must not be lost.
            _unread_clause="${_uprefix}${#_unreadable[@]} surfaces"
        else
            _unread_clause="${_uprefix}${_ushown}"
            if (( ${#_unreadable[@]} > _un ))
            then
                _unread_clause="${_unread_clause} +$(( ${#_unreadable[@]} - _un ))"
            fi
        fi
    fi
    # What is left goes to the names, each of which carries its own surface: which copy
    # diverged is the whole finding, so a name is never printed without it.
    local _names_part=""
    local _names_budget=$(( _max_status - 1 - ${#_count_part} - 2 - ${#_unread_clause} - 1 - 2 - ${#_differs[@]} ))
    if (( ${#_differs[@]} > 0 )) && (( _names_budget > 0 ))
    then
        local _fit _shown _ns
        _fit=$( __oc_fit_list "$_names_budget" "${_differs[@]}" )
        _shown="${_fit%|*}"
        _ns="${_fit##*|}"
        if (( _ns > 0 ))
        then
            _names_part=": $_shown"
            if (( ${#_differs[@]} > _ns ))
            then
                _names_part="${_names_part} +$(( ${#_differs[@]} - _ns ))"
            fi
        fi
    fi
    __tac_info "$_label" "[${_count_part}${_names_part}${_unread_clause}]" "$C_Warning"
}

# ---------------------------------------------------------------------------
# __oc_report_key_shadowing — compare every env surface against the CANONICAL value.
#
# Wayne's ruling (2026-10-01): the Windows user environment is canonical. The bridge cache
# is this box's copy of it and every other surface is DERIVED, so a name whose value
# differs on a derived surface is a copy that has diverged — and what matters is the name
# plus WHICH surface. A process gets whichever surface it inherits, so a diverged copy is a
# silent-shadowing machine, and nothing else on this box compares them.
#
# Surfaces compared: the environment.d drop-in (a static file) and the systemd USER MANAGER
# environment — the one the Gateway itself inherits, which the earlier version of this
# report could not see. A surface that exists but cannot be read is NAMED as unreadable,
# never treated as agreeing: that is exactly the case where a divergence would hide.
#
# NAMES are printed; values are compared and dropped, never reported. Each surface is read
# in a subshell and DECODED — both files store %q-escaped values and systemd quotes its own
# output — because the decoded value is what a consumer sees. Comparing a decoded value
# against raw text reported 4 correct values as differences on 2026-10-01.
# ---------------------------------------------------------------------------
function __oc_report_key_shadowing() {
    local _cache="$1"
    local _envd="$HOME/.config/environment.d/90-openclaw.conf"
    local _kv _envd_kv _mgr_raw _n _v _l
    local -A _canon=()
    # shellcheck source=/dev/null
    # swallow-ok: a corrupt cache must not abort the refresh; the map is then empty and no difference is claimed
    _kv=$( source "$_cache" 2>/dev/null
           while IFS= read -r _l
           do
               [[ "$_l" =~ ^export[[:space:]]+([A-Z_][A-Z0-9_]*)= ]] || continue
               _n="${BASH_REMATCH[1]}"
               printf '%s=%s\n' "$_n" "${!_n:-}"
           done < "$_cache" )
    while IFS='=' read -r _n _v
    do
        [[ -n "$_n" ]] && _canon["$_n"]="$_v"
    done <<< "$_kv"
    local -a _differs=() _unreadable=()
    # --- surface 1: the environment.d drop-in ---------------------------------
    if [[ ! -f "$_envd" ]]
    then
        _unreadable+=("environment.d (absent)")
    else
        # shellcheck source=/dev/null
        # The read's own diagnostic is deliberately NOT silenced: this probe exists to tell
        # "readable and agreeing" from "could not be read", and the status below names the
        # surface as unreadable as well.
        if ! _envd_kv=$( source "$_envd" || exit 1
                         while IFS= read -r _l
                         do
                             [[ "$_l" =~ ^(export[[:space:]]+)?([A-Z_][A-Z0-9_]*)= ]] || continue
                             _n="${BASH_REMATCH[2]}"
                             printf '%s=%s\n' "$_n" "${!_n:-}"
                         done < "$_envd" )
        then
            _unreadable+=("environment.d (unreadable)")
        else
            while IFS='=' read -r _n _v
            do
                [[ -n "${_canon[$_n]+set}" ]] || continue
                [[ "$_v" == "${_canon[$_n]}" ]] && continue
                _differs+=("environment.d: $_n")
            done <<< "$_envd_kv"
        fi
    fi
    # --- surface 2: the systemd user-manager env (what the Gateway inherits) ----
    if ! _mgr_raw=$(systemctl --user show-environment 2>/dev/null)  # swallow-ok: no user bus; named unreadable below
    then
        _unreadable+=("user-manager env (unreadable)")
    else
        while IFS= read -r _l
        do
            [[ "$_l" == *=* ]] || continue
            _n="${_l%%=*}"
            _v="${_l#*=}"
            [[ -n "${_canon[$_n]+set}" ]] || continue
            case "$_v" in
                # systemd renders a value it had to escape in ANSI-C form ($'…') and a plain
                # one as-is; `%b` turns those escapes back into the bytes a consumer sees.
                # Decoding only the double-quoted form reported five CORRECT passwords as
                # diverged on 2026-10-01 — the same decoded-versus-raw mistake as before,
                # one quoting form further on. A `*)` arm would be wrong for both shapes.
                \$*\'*) _v=$(printf '%b' "${_v:2:${#_v}-3}") ;;
                \"*\")  _v=$(printf '%b' "${_v:1:${#_v}-2}") ;;
            esac
            [[ "$_v" == "${_canon[$_n]}" ]] && continue
            _differs+=("user-manager env: $_n")
        done <<< "$_mgr_raw"
    fi
    if (( ${#_differs[@]} > 0 )) || (( ${#_unreadable[@]} > 0 ))
    then
        # The line is assembled (and fitted to the column width) by __oc_shadowing_line;
        # this function's job is the comparison, and it passes NAMES and surfaces only.
        __oc_shadowing_line "Key shadowing" \
            "$(printf '%s\n' "${_differs[@]}")" \
            "$(printf '%s\n' "${_unreadable[@]}")"
    fi
}

# ---------------------------------------------------------------------------
function oc-refresh-keys() {
    local cache="$TAC_CACHE_DIR/tac_win_api_keys"
    local count=0

    local _canonical_names="$TAC_CACHE_DIR/tac_win_api_key_names"
    local _prev_cache="$TAC_CACHE_DIR/tac_win_api_keys.prev"

    # 1. Pull matching vars from Windows User environment.
    #    Preserve last-good values so a pwsh.exe outage can't change the var set.
    [[ -f "$cache" ]] && cp "$cache" "$_prev_cache" 2>/dev/null || true
    if command -v pwsh.exe >/dev/null 2>&1; then
        rm -f "$cache" "${TAC_CACHE_DIR:-/dev/shm}/tac_pwsh_bridge_warned"
        __bridge_windows_api_keys
        if [[ -f "$cache" ]]; then
            count=$(grep -c '^export ' "$cache" || true)
            __tac_info "Reading Windows User environment" "[$count variable(s) imported]" "$C_Success"
        fi
    fi

    # 2a. pwsh.exe succeeded — merge Linux-side vars and persist the canonical
    #     key-name set (used to keep the fallback var set identical).
    if [[ -f "$cache" ]]; then
        for _lk in CONTEXT7_API_KEY DEVIN_API_KEY OPENCLAW_GATEWAY_TOKEN; do
            [[ -n "${!_lk:-}" ]] || continue
            grep -q "^export ${_lk}=" "$cache" 2>/dev/null && continue
            printf 'export %s=%q\n' "$_lk" "${!_lk}" >> "$cache"
        done
        # shellcheck source=/dev/null
        source "$cache" 2>/dev/null
        count=$(grep -c '^export ' "$cache" || true)
        grep -oE '^export [A-Z0-9_]+' "$cache" | sed 's/^export //' | sort -u > "$_canonical_names"

    # 2b. Fallback (pwsh.exe unavailable): rebuild the cache using ONLY the
    #     canonical key names — values from the Linux env, falling back to the
    #     last-good values. Keeps the variable set identical across runs (no
    #     pwsh up/down flip-flop), so the gateway restart gate stays quiet.
    elif [[ -f "$_canonical_names" ]]; then
        : > "$cache"
        chmod 600 "$cache" 2>/dev/null || true
        while IFS= read -r _lk; do
            [[ -n "$_lk" ]] || continue
            _lv="${!_lk:-}"
            if [[ -z "$_lv" && -f "$_prev_cache" ]]; then
                _lv=$(sed -n "s/^export ${_lk}=//p" "$_prev_cache" | head -1)
            fi
            [[ -n "$_lv" ]] && printf 'export %s=%q\n' "$_lk" "$_lv"
        done < "$_canonical_names" > "$cache"
        # shellcheck source=/dev/null
        source "$cache" 2>/dev/null
        count=$(grep -c '^export ' "$cache" || true)
        __tac_info "Reading Windows User environment" "[pwsh.exe unavailable — using last-good env ($count vars)]" "$C_Warning"

    else
        # No canonical list yet (first run) — scan the Linux env with the
        # same patterns the Windows bridge uses.
        : > "$cache" 2>/dev/null
        chmod 600 "$cache" 2>/dev/null || true
        while IFS='=' read -r _lk _lv; do
            [[ -z "$_lk" || -z "$_lv" ]] && continue
            [[ "$_lk" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
            [[ "$_lk" =~ [Tt][Oo][Kk][Ee][Nn] ]] || \
                [[ "$_lk" =~ [Aa][Pp][Ii][_-]?[Kk][Ee][Yy] ]] || \
                [[ "$_lk" =~ [Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd] ]] || \
                [[ "$_lk" =~ [Ss][Ee][Cc][Rr][Ee][Tt] ]] || \
                [[ "$_lk" =~ [Cc][Ll][Ii][Ee][Nn][Tt]_[Ii][Dd]$ ]] || \
                [[ "$_lk" =~ [Aa][Pp][Ii]$ ]] || \
                [[ "$_lk" =~ _[Kk][Ee][Yy]$ ]] || continue
            printf 'export %s=%q\n' "$_lk" "$_lv" >> "$cache"
            count=$((count + 1))
        done < <(env | sort -u)
        if [[ "$count" -gt 0 ]]; then
            # shellcheck source=/dev/null
            source "$cache" 2>/dev/null
            grep -oE '^export [A-Z0-9_]+' "$cache" | sed 's/^export //' | sort -u > "$_canonical_names"
            __tac_info "Reading Windows User environment" "[pwsh.exe unavailable — using Linux env vars ($count exported)]" "$C_Warning"
        else
            __tac_info "Reading Windows User environment" "[no vars found — pwsh.exe unavailable and no Linux fallback vars set]" "$C_Warning"
            return 1
        fi
    fi

    # Also re-assert env.shellEnv (worker-side secret resolution) — see
    # __so_ensure_shell_env. Both reports below describe the post-patch config.
    local _OC_GW_ENV_CHANGED=0
    if type -t __so_ensure_shell_env >/dev/null 2>&1; then __so_ensure_shell_env; fi

    # 3. Sync OpenClaw SecretRefs to the refreshed env credentials FIRST, so the
    #    resolved-name set computed in step 4 sees any ref this run has just
    #    converted to env-backed.
    #
    #    2026-09-22: with the order reversed, a newly-mapped key was written as an
    #    env-backed SecretRef and the SAME run still listed it as "reach no
    #    SecretRef" / "not injected", because the resolution had already been
    #    computed against the pre-patch config. The key then only entered the
    #    manager env on the NEXT refresh (measured: AGENTMAIL_API_KEY). Applying
    #    the refs first makes mapping and injection converge in one pass, and it
    #    makes both of this run's reports describe the same post-patch state.
    __oc_apply_secret_refs

    # 4. Push the gateway-resolved bridged vars into the systemd user manager
    #    environment so the running gateway can resolve env-backed SecretRefs
    #    referenced by auth profiles in agent sqlite databases. The unit and
    #    gateway.systemd.env are left alone (see __oc_sync_gateway_env_file,
    #    step 2 — OpenClaw fingerprints its own unit).
    #    Without this, `openclaw doctor` reports "secret reference was not
    #    found" because the gateway process lacks the env vars.
    __oc_sync_gateway_env_file "$cache"

    # 4b. Report the credential surface, the PATH shim that covers a caller
    #     inheriting none of it, and any key the two env surfaces disagree on. These
    #     are reports, not fixes: the first names the state that produced the
    #     2026-09-23 10:52:57 keyring prompt, the second says whether the protection
    #     is still installed and winning, the third names a silent-shadowing pair.
    __oc_report_gh_credential_surface "$cache"
    __oc_report_gh_path_shim
    __oc_report_key_shadowing "$cache"

    # 5. Decide whether the gateway needs a restart (its env changed). The
    #    restart is DEFERRED to step 7, after the NAS mirror: a gateway-hosted
    #    run (automation or agent-spawned exec) lives inside THIS service's
    #    cgroup, so restarting the gateway kills this script mid-flight and
    #    silently drops every later step (observed 2026-09-13: the NAS mirror
    #    never ran because the helper died at the restart).
    local _gw_restart_needed=0
    if (( _OC_GW_ENV_CHANGED == 1 )) && command -v openclaw >/dev/null 2>&1 && systemctl --user is-active -q openclaw-gateway.service 2>/dev/null
    then
        _gw_restart_needed=1
    fi

    # 6. The NAS mirror is its own command now (`oc export-keys-nas`): a backup job
    #    — one SSH connection, its own connect timeout, its own retry and marker —
    #    had no business inside a key refresh. It must not go stale unseen, so say
    #    when it is BEHIND rather than silently doing nothing. The marker records the
    #    CACHE hash, the same one compared here, so this is an exact question.
    local _cache_hash _mirror_hash
    _cache_hash=$(grep '^export ' "$cache" | sort | sha256sum | awk '{print $1}')
    _mirror_hash=$(cat "$TAC_STATE_DIR/tac_win_api_keys.nas_hash" 2>/dev/null || echo none)
    if [[ "$_cache_hash" != "$_mirror_hash" ]]
    then
        __tac_info "NAS mirror" "[behind — run 'oc export-keys-nas' to sync it]" "$C_Warning"
    fi

    # 6. Restart the gateway LAST, once every durable side effect (manager env,
    #    SecretRefs) is committed — see the block below for why this is now a
    #    plain systemctl restart.
    if (( _gw_restart_needed == 1 ))
    then
        # 2026-09-22 (simplification): this block used to run `openclaw gateway
        # restart` inside an embedded bash body, from either a detached unit or a
        # scope, and classify SIX outcomes. Two of those outcomes were the same
        # fact: the CLI's own 45 s readiness probe cannot pass on a box whose cold
        # start runs to minutes (measured: ~2 min 51 s). Worse, the CLI's restart
        # raced the state-lifecycle lock — the stability bundles record it in order
        # (restart_shutdown_timeout → startup_failed → systemd's Restart= recovering
        # it). systemd's own restart is serial: the stop completes before the start,
        # so that overlap cannot arise, and --no-block keeps a slow cold start from
        # hanging the caller. This is the last step, so a gateway-hosted run that
        # dies here loses only its own final log line.
        # 2026-09-23, both rules from the crash loop this block contributed to:
        #
        #  1. NEVER STACK A RESTART. If systemd is already moving the unit — a previous
        #     restart still draining, or a start in flight — another restart lands on
        #     top of it. That is the collision whose log line is "another OpenClaw
        #     process owns state-lifecycle", and each cycle took minutes to fail before
        #     anyone could see it (measured six times between 14:00 and 14:34).
        #  2. WAIT FOR CONVERGENCE, not for `is-active`. The unit reports "active" the
        #     moment the process is spawned, while the gateway then spends minutes
        #     opening every agent database; the old text ("it finishes coming up on its
        #     own") read as healthy during exactly that window. The gateway's own log is
        #     the authority on serving (__so_gateway_phase), so a fresh `running` is what
        #     convergence means here — and every other outcome is named.
        local _pre_state _gw_state="" _phase="" _i
        # CONVERGENCE BOUND — 120 iterations, and the number is measured, not chosen.
        # The unit is Type=simple, so `is-active` reports "active" the moment the
        # process is spawned while the gateway's own log still says "starting": the
        # ONLY way this loop ends early is a fresh `running` phase, i.e. an
        # "http server listening" / "[gateway] ready" lifecycle line. Measured on this
        # box 2026-09-27: unit start 13:30:17 -> "starting HTTP server" 13:31:28 ->
        # "http server listening" 13:31:36 -> "[gateway] ready" 13:31:43, i.e. ~79-86s
        # to ready. The previous bound of 60 was therefore SHORTER THAN THE START IT
        # WAITS FOR, so a cold start could never be seen to converge: the loop ran out
        # and every restart was reported as "still starting", leaving the success row
        # unreachable in exactly the situation it describes. 120 covers the measured
        # start with headroom; each iteration is a `sleep 1`, and a log probe when the
        # unit is active adds to that, so the wall time is 120s plus at most the
        # probes. A start that still exceeds it is reported honestly by the `*)` row.
        local _gw_wait=120
        # swallow-ok: no user manager in an agent/CI shell; the pre-state is then empty and no restart is stacked
        _pre_state=$(systemctl --user is-active openclaw-gateway.service 2>/dev/null)
        if [[ "$_pre_state" == "activating" || "$_pre_state" == "deactivating" ]]
        then
            __tac_info "Gateway" "[already $_pre_state — not stacking a restart; env is applied]" "$C_Warning"
        elif systemctl --user restart --no-block openclaw-gateway.service 2>/dev/null
        then
            # Announce the wait before taking it: it can last two minutes now, and a
            # silent two-minute pause after the env has been applied reads as a hang.
            __tac_info "Gateway" "[restart issued — waiting up to ${_gw_wait}s for it to serve]" "$C_Dim"
            for (( _i = 0; _i < _gw_wait; _i++ ))
            do
                _gw_state=$(systemctl --user is-active openclaw-gateway.service 2>/dev/null)
                [[ "$_gw_state" == "failed" ]] && break
                if [[ "$_gw_state" == "active" ]]
                then
                    # A failed read must leave the phase empty (= unknown) rather than
                    # abort the report; the reader's own journalctl is already redirected.
                    # swallow-ok: the phase reader is a log parser, and an empty read means "phase unknown"
                    _phase=$(__so_gateway_phase openclaw-gateway.service 2>/dev/null)
                    [[ "$_phase" == "running" ]] && break
                fi
                sleep 1
            done
            case "$_gw_state:$_phase" in
                failed:*)
                    __tac_info "Gateway" "[restart FAILED — env applied; check systemctl --user status]" "$C_Error" ;;
                active:running)
                    __tac_info "Gateway" "[restarted and serving]" "$C_Success" ;;
                active:starting)
                    __tac_info "Gateway" "[restarted — still starting (a cold start here runs 2-4 min)]" "$C_Warning" ;;
                active:*)
                    __tac_info "Gateway" "[restarted — active, gateway phase ${_phase:-unknown}]" "$C_Warning" ;;
                *)
                    __tac_info "Gateway" "[restart issued; unit is $_gw_state — not waiting further]" "$C_Warning" ;;
            esac
        else
            __tac_info "Gateway" "[restart NOT issued — env is applied; re-run it yourself]" "$C_Warning"
        fi
    fi
}

# ---------------------------------------------------------------------------
# oc-rotate-exposed-secrets — Exposure response helper for bash-errors.log.
# Usage:
#   oc rotate-secrets
#   oc rotate-secrets --sanitize-log
# ---------------------------------------------------------------------------
function oc-rotate-exposed-secrets() {
    local _log="$ErrorLogPath"
    local _sanitize=0
    [[ "${1:-}" == "--sanitize-log" ]] && _sanitize=1

    if [[ ! -f "$_log" ]]
    then
        __tac_info "Secrets Exposure" "[no log file found: $_log]" "$C_Warning"
        return 0
    fi

    local _count
    _count=$(rg -n "OPENCLAW_GATEWAY_PASSWORD|authkey=|tskey-|(^|[[:space:]])-a[[:space:]]+[A-Za-z0-9._-]{8,}|SSHPASS=|Bearer[[:space:]]+[A-Za-z0-9._=-]+|password=|token=" "$_log" 2>/dev/null | wc -l)

    printf '%s\n' "${C_Highlight}Exposure Response Checklist${C_Reset}"
    printf '%s\n' "  1) Rotate OpenClaw gateway auth credentials"
    printf '%s\n' "  2) Rotate Tailscale auth keys if they appeared in command history/logs"
    printf '%s\n' "  3) Rotate Redis/other CLI password args used with '-a'"
    printf '%s\n' "  4) Re-run: oc rotate-secrets --sanitize-log"
    printf '%s\n' "  5) Validate: rg -n 'authkey=|tskey-|OPENCLAW_GATEWAY_PASSWORD| -a ' $_log"
    __tac_info "Secrets Exposure" "[${_count} potential match(es) detected]" "$C_Warning"

    if (( _sanitize == 0 ))
    then
        return 0
    fi

    local _backup
    _backup="${_log}.pre-sanitize.$(date +%Y%m%d_%H%M%S)"
    cp "$_log" "$_backup" || return 1

    sed -E \
        -e 's/(OPENCLAW_GATEWAY_PASSWORD=)[^[:space:]]+/\1<redacted>/g' \
        -e 's/(--authkey=)tskey-[^[:space:]">]+/\1<redacted>/g' \
        -e 's/([?&]authkey=)[^[:space:]"&]+/\1<redacted>/g' \
        -e 's/(SSHPASS=)[^[:space:]]+/\1<redacted>/g' \
        -e 's/([Bb]earer[[:space:]]+)[A-Za-z0-9._=-]+/\1<redacted>/g' \
        -e 's/([[:space:]]-a[[:space:]]+)[^[:space:]]+/\1<redacted>/g' \
        -e 's/((password|token|api[_-]?key)=)[^[:space:]"]+/\1<redacted>/Ig' \
        "$_backup" > "$_log"

    __tac_info "Secrets Exposure" "[sanitized log in place; backup: $_backup]" "$C_Success"
}

# end of file

# end of file
