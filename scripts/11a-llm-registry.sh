# shellcheck shell=bash
# --- Module: 11a-llm-registry ---
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 20
#   v20 (2026-10-02): the registry header and column count come from ONE source,
#   LLM_REGISTRY_HEADER (01-constants): __llm_registry_sync_state emits it and
#   derives ncols from it (no literal 1..39 field list), and __renumber_registry
#   echoes it.  The remap call is no longer `|| true` — a failure is retried once
#   and then NAMED (card e0579318).
#   v16 (2026-09-27): provenance helpers for a trained artifact (card UBC-GRPO-004) —
#   __llm_provenance_dir/_path/_write/_read. A trained model still lands as an ordinary
#   registry row; the benchmark, held-out set and prompt-contract revision it was made
#   under live in a sidecar beside the registry, keyed by the model FILE name so a
#   rescan cannot move provenance onto a different model.
# ==============================================================================
# 11a-llm-registry — Registry CRUD, sync, renumber
# ==============================================================================
# @modular-section: llm-manager
# @depends: constants, design-tokens, ui-engine, hooks
# @uses: llm-server, llm-autotune
# @exports: __save_model_ctx, __llm_registry_set_field, __require_llm,
#   __llm_json_escape,
#   __llm_registry_entry_by_num, __llm_registry_entry_by_file,
#   __llm_default_file, __llm_default_entry, __llm_default_number,
#   __llm_registry_sync_state, __renumber_registry,
#   __llm_provenance_dir, __llm_provenance_path, __llm_provenance_write,
#   __llm_provenance_read

# Idempotent include guard: sub-modules are sourced both by their thin
# loader and directly by the profile/env loaders, so run the body once.
[[ -n "${__TAC_MOD_11A_LLM_REGISTRY_LOADED:-}" ]] && return 0
__TAC_MOD_11A_LLM_REGISTRY_LOADED=1

# ---------------------------------------------------------------------------
# __llm_registry_set_field <row_num|model_file> <field_index> <value> — Rewrite one
# field of one registry row, atomically.  Used by __save_model_ctx (field 8).  Its
# field-17 twin (__save_tps) was deleted on 2026-09-16: the runtime's burn path called
# it after EVERY request, so it overwrote the autotune's certification with whatever
# the last chat or bench had just measured — which is how a validation came to
# compare a measured number against itself.
#
# The model FILE name is the row's identity, so it is the preferred key; a row NUMBER is
# accepted and resolved, but the rewrite is matched on the FILE — a `model scan` between
# the call and the write then cannot land the value on a different model.
#
# A failed or empty awk run must never truncate the registry, so the rewrite
# lands in <registry>.tmp and is moved into place only when it is non-empty AND
# still carries the header plus at least one data row (>= 2 lines).
# @returns 0 on commit, 1 when the row/field were unusable or the rewrite was
#   refused.  Callers keep their historical best-effort contract and do not
#   distinguish the two.
# ---------------------------------------------------------------------------
function __llm_registry_set_field() {
    local row_ref="$1" field_index="$2" value="$3"
    [[ -n "$row_ref" && "$field_index" =~ ^[0-9]+$ && -f "$LLM_REGISTRY" ]] || return 1

    local row_file="" _row=""
    if [[ "$row_ref" =~ ^[0-9]+$ ]]; then
        _row="$row_ref"
        row_file="$(__llm_registry_file_for_row "$row_ref")"
    else
        row_file="$row_ref"
        _row="$(__llm_registry_row_for_file "$row_ref")"
    fi
    [[ -n "$row_file" && -n "$_row" ]] || return 1

    awk -F'|' -v f="$row_file" -v i="$field_index" -v v="$value" \
        'BEGIN{OFS="|"} $3 == f {$i = v} {print}' \
        "$LLM_REGISTRY" > "${LLM_REGISTRY}.tmp"
    if [[ -s "${LLM_REGISTRY}.tmp" ]] && [[ "$(wc -l < "${LLM_REGISTRY}.tmp")" -ge 2 ]]
    then
        mv "${LLM_REGISTRY}.tmp" "$LLM_REGISTRY"
    else
        rm -f "${LLM_REGISTRY}.tmp"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# __save_model_ctx — Persist autotune winner ctx to registry.
# Writes the value verbatim: there is no floor clamp here (autotune's own
# search decides the winner, and a small ctx is a legitimate outcome on a
# VRAM-limited card).
# ---------------------------------------------------------------------------
function __save_model_ctx() {
    local model_ref="$1"
    local ctx_val="$2"
    # The model may be named by row NUMBER or by FILE name; __llm_registry_set_field
    # resolves either and matches the row by file (the row's identity).
    [[ -n "$model_ref" && "$ctx_val" =~ ^[0-9]+$ && -f "$LLM_REGISTRY" ]] || return
    __llm_registry_sync_state >/dev/null 2>&1 || true
    __llm_registry_set_field "$model_ref" 8 "$ctx_val" || true
}

# ---------------------------------------------------------------------------
# __require_llm — Verify jq is installed and the local LLM is listening.
# Deduplicates the repeated jq + port checks across LLM functions.
# ---------------------------------------------------------------------------
function __require_llm() {
    if ! command -v jq >/dev/null 2>&1
    then
        printf '%s\n' "${C_Error}[jq missing]${C_Reset} Install: sudo apt install -y jq"
        return 1
    fi
    if ! __test_port "$LLM_PORT" >/dev/null 2>&1
    then
        __tac_info "Llama Server" "[OFFLINE]" "$C_Error"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# __tac_cleanup_stale_locks — Kill orphaned bench/autotune lock files and orphan
# stdin-keeper processes left behind by aborted runs (SIGKILL, WSL crash, etc.).
# Safe to call at any time — only removes files with no active holder.
# @returns 0 always.
# ---------------------------------------------------------------------------
function __llm_json_escape() {
    local raw="${1:-}"
    raw="${raw//\\/\\\\}"
    raw="${raw//\"/\\\"}"
    raw="${raw//$'\n'/\\n}"
    raw="${raw//$'\r'/\\r}"
    raw="${raw//$'\t'/\\t}"
    printf '%s' "$raw"
}

# ---------------------------------------------------------------------------
# __llm_registry_entry_by_num — Resolve a registry entry by model number.
# Validates that target is numeric before querying.
# @returns 0 on success, 1 if the registry or requested entry is unavailable.
# ---------------------------------------------------------------------------
function __llm_registry_entry_by_num() {
    local target="${1:-}"
    # Validate target is numeric
    [[ ! "$target" =~ ^[0-9]+$ ]] && return 1
    [[ -n "$target" && -f "$LLM_REGISTRY" ]] || return 1
    awk -F'|' -v n="$target" '$1 == n {print; exit}' "$LLM_REGISTRY" 2>/dev/null
}

# ---------------------------------------------------------------------------
# __llm_registry_entry_by_file — Resolve a registry entry by GGUF filename.
# @returns 0 on success, 1 if the registry or requested entry is unavailable.
# ---------------------------------------------------------------------------
function __llm_registry_entry_by_file() {
    local target_file="${1:-}"
    [[ -n "$target_file" && -f "$LLM_REGISTRY" ]] || return 1
    awk -F'|' -v f="$target_file" '$3 == f {print; exit}' "$LLM_REGISTRY" 2>/dev/null
}

# ---------------------------------------------------------------------------
# __llm_registry_field <model_file> <column> — the value of a NAMED registry column
# for the row whose `file` column is <model_file>, or empty.
#
# WHY A NAME LOOKUP EXISTS AT ALL (2026-09-28): the launch paths read this file
# POSITIONALLY, and a positional reader cannot see a column the header has grown.  A
# setting that the serve path and the bench/autotune path must AGREE on is therefore
# asked for by name here, so neither side can be silently off by one field.
#
# CONTRACT — empty means "the registry says nothing about this", which every caller
# turns into "emit no flag" (llama.cpp's own default).  An absent column, an absent
# row and a blank cell are deliberately the same answer; no value is invented here.
# An unreadable registry is warned about rather than reported as "not configured",
# because those are different facts and only one of them is silent.
# ---------------------------------------------------------------------------
function __llm_registry_field() {
    local _file="${1:-}" _col="${2:-}" _val=""
    [[ -n "$_file" && -n "$_col" && -f "$LLM_REGISTRY" ]] || return 0
    if ! _val=$(awk -F'|' -v col="$_col" -v want="$_file" '
        NR == 1 { for (i = 1; i <= NF; i++) if ($i == col) idx = i; next }
        idx == 0 { next }
        $3 == want { print $idx; exit }
    ' "$LLM_REGISTRY")
    then
        __tac_info "Warning" "[could not read $LLM_REGISTRY for column \'$_col\' - emitting no flag]" "$C_Warning"
        return 0
    fi
    printf '%s\n' "$_val"
}

# ---------------------------------------------------------------------------
# __llm_registry_file_for_row / __llm_registry_row_for_file — the two DIRECTIONS
# between a row NUMBER and a model FILE name, built on the entry lookups above.
#
# The FILE name (field 3) is the row's definitive identity.  Row numbers are assigned by
# `model scan` and shift whenever a model is added or removed — on 2026-09-16
# registering one new model moved every model after it down a row (26 became 27), which
# silently invalidated a queued list of row numbers, and a number captured before a scan
# points at a different model afterwards.  So anything that must survive a rescan — a
# save target, a queued row, a stored selection — keys on the file name and resolves to
# a number only for display.  These wrappers exist so callers do not each re-invent the
# awk (and cannot pick the wrong field).
#   stdout: the value, or empty when the row/file is not in the registry.
# ---------------------------------------------------------------------------
function __llm_registry_file_for_row() {
    local entry
    entry=$(__llm_registry_entry_by_num "${1:-}") || return 0
    printf '%s\n' "$(printf '%s' "$entry" | cut -d'|' -f3)"
}

function __llm_registry_row_for_file() {
    local entry
    entry=$(__llm_registry_entry_by_file "${1:-}") || return 0
    printf '%s\n' "$(printf '%s' "$entry" | cut -d'|' -f1)"
}

# ---------------------------------------------------------------------------
# Provenance for a TRAINED artifact (card UBC-GRPO-004).
#
# A trained model has to be droppable as an ordinary registry ROW — the launchers, the
# autotuner and the units all read the same 37 fields and must keep doing so — but a row
# cannot say WHY the artifact exists: which benchmark scored it, which held-out set it
# was measured on, and which revision of the served prompt contract it was trained
# under. Those live in a sidecar beside the registry. The row stays the record every
# other tool reads; the sidecar is the artifact's provenance.
#
# Keyed by the model FILE name, this file's own identity rule (see the resolvers above):
# a `model scan` that renumbers rows then cannot move provenance onto another model.
#
# The directory sits BESIDE the registry, so a test that sandboxes LLM_REGISTRY
# sandboxes its provenance too — and so the two travel together in a backup.
#
# REF: "How GRPO Trains Small Language Models with Verifiable Rewards"
#      (Benjamin Nweke, TDS, 2026-09-23) — §4, the prompt-template rule.
#      https://towardsdatascience.com/how-grpo-trains-small-language-models-with-verifiable-rewards/
# ---------------------------------------------------------------------------
function __llm_provenance_dir() {
    printf '%s/provenance\n' "$(dirname "${LLM_REGISTRY:-$HOME/.llm/models.conf}")"
}

# __llm_provenance_path <model_file> — the sidecar's path. Prints nothing useful for an
# empty name, and refuses it, so a caller cannot write provenance keyed on nothing.
function __llm_provenance_path() {
    local model_file="${1:-}"
    [[ -n "$model_file" ]] || return 1
    printf '%s/%s.json\n' "$(__llm_provenance_dir)" "${model_file##*/}"
}

# __llm_provenance_write <model_file> <benchmark> <held_out> <prompt_set_rev> <sha256> [notes]
# Atomic in the same way __llm_registry_set_field is: built in a temp file and moved in,
# so an interrupted write cannot leave a half-record behind.
function __llm_provenance_write() {
    local model_file="${1:-}" benchmark="${2:-}" held_out="${3:-}" prompt_set="${4:-}"
    local digest="${5:-}" notes="${6:-}"
    local path tmp
    path="$(__llm_provenance_path "$model_file")" || return 1
    mkdir -p "$(__llm_provenance_dir)" || return 1
    tmp="${path}.tmp.$$"
    {
        printf '{\n'
        printf '  "model_file": "%s",\n' "$(__llm_json_escape "$model_file")"
        printf '  "sha256": "%s",\n' "$(__llm_json_escape "$digest")"
        printf '  "benchmark": "%s",\n' "$(__llm_json_escape "$benchmark")"
        printf '  "held_out": "%s",\n' "$(__llm_json_escape "$held_out")"
        printf '  "prompt_set": "%s",\n' "$(__llm_json_escape "$prompt_set")"
        printf '  "registered_at": "%s",\n' "$(date -Iseconds)"
        printf '  "notes": "%s"\n' "$(__llm_json_escape "$notes")"
        printf '}\n'
    } > "$tmp" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$path" || { rm -f "$tmp"; return 1; }
    printf '%s\n' "$path"
}

# __llm_provenance_read <model_file> — the sidecar, verbatim; rc 1 when absent.
function __llm_provenance_read() {
    local path
    path="$(__llm_provenance_path "${1:-}")" || return 1
    [[ -f "$path" ]] || return 1
    cat "$path"
}

# ---------------------------------------------------------------------------
# __llm_default_file — Read the configured default GGUF filename.
# @returns 0 on success, 1 if no default model is configured.
# ---------------------------------------------------------------------------
function __llm_default_file() {
    [[ -f "$LLM_DEFAULT_FILE" ]] || return 1
    local default_file
    default_file=$(< "$LLM_DEFAULT_FILE")
    [[ -n "$default_file" ]] || return 1
    printf '%s\n' "$default_file"
}

# ---------------------------------------------------------------------------
# __llm_default_entry — Resolve the configured default model to a registry row.
# @returns 0 on success, 1 if no default is configured or it is missing from the registry.
# ---------------------------------------------------------------------------
function __llm_default_entry() {
    local default_file
    default_file=$(__llm_default_file) || return 1
    __llm_registry_entry_by_file "$default_file"
}

# ---------------------------------------------------------------------------
# __llm_default_number — Resolve the configured default model number.
# @returns 0 on success, 1 if no default is configured or it is missing from the registry.
# ---------------------------------------------------------------------------
function __llm_default_number() {
    local entry
    entry=$(__llm_default_entry) || return 1
    printf '%s\n' "${entry%%|*}"
}

# ---------------------------------------------------------------------------
# __llm_registry_sync_state — Persist default and active flags into registry.
# Keeps models.conf as canonical state for default selection and in-VRAM model.
# @returns 0 on success or when registry is unavailable.
# ---------------------------------------------------------------------------
function __llm_registry_sync_state() {
    [[ -f "$LLM_REGISTRY" ]] || return 0

    local default_file=""
    local active_file=""
    local running=0

    default_file=$(__llm_default_file 2>/dev/null || true)
    if __llm_server_running && __test_port "$LLM_PORT"
    then
        running=1
    fi

    # The pointer holds the model FILE name — the row's identity — so the default/in-VRAM
    # flags below land on the right row whatever the numbering does.  It used to hold a row
    # NUMBER, which `model scan` reassigns: a value captured before a rescan silently
    # flagged a DIFFERENT filename as the default/in-VRAM.
    if [[ -f "$ACTIVE_LLM_FILE" ]]
    then
        active_file=$(< "$ACTIVE_LLM_FILE")
    fi

    awk -F'|' -v def="$default_file" -v af="$active_file" -v run="$running" \
        -v header="$LLM_REGISTRY_HEADER" 'BEGIN {
            OFS="|"
            # Always emit the canonical header first, even if the input
            # registry has lost its header line (e.g. after an interrupted
            # model-scan renumbering pass).  This prevents a headerless
            # registry from self-perpetuating across every sync_state call.
            # The header AND the column count come from the ONE definition in
            # 01-constants (LLM_REGISTRY_HEADER), never a literal here, so this
            # writer cannot drift from the schema the way the remap did.
            print header
            ncols = split(header, _hdr, "|")
        }
        $1 == "#" { next }
        # Preserve rows of unexpected width verbatim rather than dropping
        # them: a stray pipe character in a value (or a partially-written
        # row) must not make a model silently vanish from the registry.
        (NF != 20 && NF != 26 && NF != 32 && NF != 37 && NF != ncols) { print; next }
        {
            d = ($3 == def ? "yes" : "no")
            a = (run == 1 && af != "" && $3 == af ? "yes" : "no")
            $19=d; $20=a
            if ($15 == "") $15="auto"
            if ($16 == "") $16="on"
            # Pad legacy 20/26/32/37-column rows to the CURRENT schema so the registry
            # converges on the extended header (AUTOTUNE-001/003/005, then the
            # BENCH-SAMPLER-001 sampler columns).  The width list above must name every
            # width this pads FROM and the width it pads TO: a width that is neither is
            # passed through verbatim, which is how 39-column rows silently stopped
            # receiving the $19/$20/$15/$16 normalisation just above once the sampler
            # columns were added.  (No apostrophes in this string: it is inside an awk
            # single-quoted program, where one would close the quote and break the file.)
            if (NF >= 20 && NF < ncols) { for (i = NF + 1; i <= ncols; i++) $i = "" }
            # Emit exactly ncols fields, where ncols came from the header above —
            # a literal 1..39 list here is what would silently truncate a row the
            # day a column is added.
            _row = $1
            for (i = 2; i <= ncols; i++) _row = _row OFS $i
            print _row
        }
    ' "$LLM_REGISTRY" > "${LLM_REGISTRY}.tmp" || return 1

    # Safety: never replace the registry with an empty or truncated file.
    # A failed awk run can produce 0 lines, wiping all model data.
    # Require header + at least 1 data row (≥ 2 lines) so a header-only
    # output cannot overwrite a populated registry.
    if [[ -s "${LLM_REGISTRY}.tmp" ]] && [[ "$(wc -l < "${LLM_REGISTRY}.tmp")" -ge 2 ]]
    then
        mv "${LLM_REGISTRY}.tmp" "$LLM_REGISTRY" || return 1
    else
        rm -f "${LLM_REGISTRY}.tmp"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# __renumber_registry — Remove a model entry by number and renumber the rest.
# Usage: __renumber_registry <model_number>
# This is the single definition: 11d-llm-gpu.sh carried a verbatim copy of it
# until 2026-09-16 (docs/inspection.md 10.1). The block that used to sit here
# described __llm_autotune_profiles_file, which lives in 11b-llm-autotune.sh.
# ---------------------------------------------------------------------------
function __renumber_registry() {
    local target="$1"
    local old_registry_snapshot
    old_registry_snapshot=$(mktemp "${LLM_REGISTRY}.old.XXXXXX") || return 1
    cp "$LLM_REGISTRY" "$old_registry_snapshot" 2>/dev/null || {
        rm -f "$old_registry_snapshot"
        return 1
    }

    awk -F'|' -v n="$target" '$1 != n && $1 != "#"' "$LLM_REGISTRY" > "${LLM_REGISTRY}.tmp"
    local newnum=0
    {
        # The ONE header definition (01-constants), not another literal copy.
        echo "$LLM_REGISTRY_HEADER"
        while IFS='|' read -r _num rest
        do
            ((++newnum))
            echo "${newnum}|${rest}"
        done < "${LLM_REGISTRY}.tmp"
    } > "${LLM_REGISTRY}.tmp2"
    rm -f "${LLM_REGISTRY}.tmp"
    # Safety: refuse to replace registry with header-only output.
    if [[ -s "${LLM_REGISTRY}.tmp2" ]] && [[ "$(wc -l < "${LLM_REGISTRY}.tmp2")" -ge 2 ]]
    then
        mv "${LLM_REGISTRY}.tmp2" "$LLM_REGISTRY"
    else
        __tac_info "Registry" "[Refusing to overwrite — would leave $(wc -l < "${LLM_REGISTRY}.tmp2") lines]" "$C_Error"
        rm -f "${LLM_REGISTRY}.tmp2"
        rm -f "$old_registry_snapshot"
        return 1
    fi
    # Carry the tuning columns onto the renumbered rows.  `|| true` used to hide a
    # failure here, which is how a stale-schema remap could blank every row's tuning
    # with nobody knowing (card e0579318).  Retry once, then NAME the failure: the
    # registry is already written, so aborting the renumber now would discard it —
    # the honest outcome is a loud, specific warning.  (if/then, not `&& break`:
    # a false test in `A && B` returns non-zero and errexit reads it as a failure.)
    local _remap_rc=0 _remap_try
    for _remap_try in 1 2; do
        _remap_rc=0
        __llm_autotune_profiles_remap_by_registry "$old_registry_snapshot" "$LLM_REGISTRY" >/dev/null 2>&1 || _remap_rc=$?
        if (( _remap_rc == 0 )); then break; fi
    done
    if (( _remap_rc != 0 )); then
        __tac_info "Registry" "[tuning-column remap failed after 2 attempts (rc=${_remap_rc}) — the renumbered rows keep the scan's values, not the previous tuning]" "$C_Warning"
    fi
    rm -f "$old_registry_snapshot"
    rm -f "$ACTIVE_LLM_FILE"
    __llm_registry_sync_state >/dev/null 2>&1 || true
    echo "$newnum"
}

# ---------------------------------------------------------------------------
# __model_scan
# @description Scan GGUF files, regenerate the registry, and archive discouraged quants.
# @returns 0 on success, 1 if the model drive is unavailable or no models are found.
# ---------------------------------------------------------------------------
# end of file

# end of file
