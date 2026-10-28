# shellcheck shell=bash
# ─── Module: 15-model-recommender ───────────────────────────────────────────────────────
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# TACTICAL_PROFILE_VERSION auto-computes from the sum of all module versions.
# Module Version: 10
#   v10 (2026-10-28): the VRAM figure comes from the CARD first.  Testing the
#   4 GiB VRAM_TOTAL_BYTES constant before nvidia-smi made the driver branch dead
#   code, so a 24 GB card and a cardless host both reported 4 GB.  The constant
#   is now the fallback.
#   v9 (2026-10-18): replace a bare postfix increment with the errexit-safe assignment
#   form.  Under errexit `((shown++))` returns 1 while the value is 0, and
#   tests/unit/29-errexit-arithmetic.bats:100 flags it (pre-existing CI red; no
#   behaviour change at any non-zero value).
#   v8 (2026-10-18): the fixed `read -r` row list binds ctx_policy (col 45) as a trailing,
#   unread position holder so the new 45th field cannot be glued onto meas_state by bash's
#   last-variable-gets-the-rest rule (CTXBUDGET-003; no scoring or output change).
#   v7 (2026-10-17): the use-case score reads the MEASURED workload, not the model's NAME.
#   v6 left "use case match" as a substring test on the name ("coder"/"code", "qwen"/"llama",
#   "mistral"/"phi"), so a model certified on `chat` could win a `coding` request and a name was
#   worth +3 with no reading behind it.  The registry row already carries the workload its reading
#   was taken on (col 33) and the row's `meas_state` (col 44); the read-list BOUND `_workload` and
#   never used it.  Now: eligibility requires a CERTIFIED reading of a workload in the requested
#   use case's affinity set, throughput only refines an already-eligible row, and a row that cannot
#   show one is listed under "unranked" with the reason instead of being silently credited or
#   silently hidden.  jd: docs/llm.md "Model recommender — measured workload, not the name".
#   Behaviour change to a scorer, made under workboard card JEV-OPEN-102 (Wayne: "continue"),
#   whose terms are exactly these: measurement wins, absent/indicative readings buy no rank.
#   v6 (2026-10-16): the TPS bonus requires a CERTIFIED reading.  This scorer read the registry only
#   to column 26, so `meas_state` never bound, and it awarded +1 for `tps > 30` on ANY row - including
#   the INDICATIVE ones (a reading that drifted past the 25 % position bound) and rows with no
#   provenance at all.  Wayne's call from the menu, 2026-10-16: "drop the tps bonus for non-certified
#   rows" - so the bonus now needs `meas_state == certified` and the read-list runs to column 44.  He
#   did NOT take "drop it entirely", so a certified row keeps the signal; a contended one cannot buy a
#   rank with it.  (This is a behaviour change to a scorer, which is why it was put to him first.)
# ==============================================================================
# 15. MODEL RECOMMENDER
# ==============================================================================
# @modular-section: model-recommender
# @depends: constants, design-tokens, ui-engine, hooks, llm-manager
# @exports: model-recommend
#
# Recommends optimal models based on available VRAM and intended use case.
# Scans the registry and scores models based on:
#   - VRAM fit (must fit within 80% of available VRAM)
#   - Use case match (coding, reasoning, creative, general)
#   - Performance (TPS bonus for high-throughput models)

# ---------------------------------------------------------------------------
# __recommender_workloads_for — the AFFINITY POLICY: which measured workloads count.
# @description Map a requested use case to the autotune workloads that measure it.
# @param $1 Use case: general|coding|reasoning|creative
# @returns 0 always; echoes a space-separated workload list.
#
# This is a POLICY, not a fact, and it is printed on every run so it can be argued
# with.  The autotune vocabulary is chat|legal|agentic|mix — there is no `reasoning`
# or `creative` workload on this box, so those use cases can only be served by their
# closest MEASURED proxy.  What the mapping must never do is fall back to the model's
# name: a proxy that was actually measured is evidence, and "qwen" is not.
# REF: "Jev Your Engines: Seven Open Decision Models vs. a Generative LLM"
#      (Lambert Leong, TDS, 2026-10-15) —
#      https://towardsdatascience.com/jev-your-engines-seven-open-decision-models-vs-a-generative-llm/
#      "Accepting a new candidate list and choosing well from it are separate
#      abilities" — a candidate's FIT is a measured property, not a property of its
#      name or its interface.  If autotune ever gains a `reasoning` or `creative`
#      workload, this table shrinks to a one-to-one match and that is the goal.
# ---------------------------------------------------------------------------
function __recommender_workloads_for() {
    case "${1:-general}" in
        general)   printf 'chat mix' ;;
        coding)    printf 'agentic mix' ;;
        reasoning) printf 'legal agentic mix' ;;
        creative)  printf 'chat mix' ;;
        *)         printf '' ;;
    esac
}

# ---------------------------------------------------------------------------
# model-recommend — Suggest models based on VRAM and use case.
# Usage: model-recommend [general|coding|reasoning|creative]
# ---------------------------------------------------------------------------
function model-recommend() {
    local use_case="${1:-general}"

    # Validate use case
    case "$use_case" in
        general|coding|reasoning|creative) ;;
        *)
            __tac_info "Invalid use case" "[Use: general|coding|reasoning|creative]" "$C_Error"
            return 1
            ;;
    esac

    # Check prerequisites
    if [[ ! -f "$LLM_REGISTRY" ]]
    then
        __tac_info "Registry" "[NOT FOUND - Run 'model scan' first]" "$C_Error"
        return 1
    fi

    # Ask the CARD first.  VRAM_TOTAL_BYTES is the 4 GiB value tuned for the RTX
    # 3050 Ti, and testing it first made the nvidia-smi branch below dead code:
    # every larger card — including a CUDA arm64 box — was reported as 4 GB, and
    # so was a host with no card at all.  The constant is the FALLBACK, not the
    # answer.
    local vram_gb vram_mb=""
    if command -v nvidia-smi >/dev/null 2>&1
    then
        # swallow-ok: an unreadable card falls through to the constant below, which is the stated fallback
        vram_mb=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null)
        vram_mb="${vram_mb%%$'\n'*}"
        vram_mb="${vram_mb// /}"
    fi
    if [[ "$vram_mb" =~ ^[0-9]+$ ]]
    then
        # Round to the nearest GB: 4095 MB is a 4 GB card, not 3.
        vram_gb=$(( (vram_mb + 512) / 1024 ))
    elif [[ -n "${VRAM_TOTAL_BYTES:-}" ]]
    then
        vram_gb=$(( VRAM_TOTAL_BYTES / 1024 / 1024 / 1024 ))
    else
        vram_gb=4
    fi

    __tac_header "MODEL RECOMMENDATIONS" "open"
    __tac_info "VRAM Available" "${vram_gb}GB" "$C_Highlight"
    __tac_info "Use Case" "${use_case}" "$C_Highlight"
    local affinity
    affinity="$(__recommender_workloads_for "$use_case")"
    __tac_info "Policy" "[certified reading of: ${affinity}]" "$C_Text"
    __tac_divider

    local found_any=0
    local flagged=0
    local -a flagged_rows=()

    # Score and rank models
    # Scoring:
    #   +3 for use case match (coding → coder models, etc.)
    #   +2 for architecture match (qwen/llama for reasoning)
    #   +1 for high TPS (>30) on a CERTIFIED row (v6)
    # Only show models that fit within 80% of VRAM
    while IFS='|' read -r num name file size quant_cache arch gpu_layers ctx threads batch ubatch parallel fit_target_mb backend mmap_mode flash_attn tps autotuned is_default in_vram prefill_tps p2_ctx p2_batch p2_ubatch p2_tps p2_prefill _spec_type _spec_draft_model _spec_draft_n_max _spec_draft_ngl _spec_draft_device _spec_accept_len _workload _ttft_ms _bench_ctx _bench_max_chunks _bench_avg_prompt_tokens _repeat_penalty _repeat_last_n _meas_load _meas_n _meas_spread _meas_drift meas_state _ctx_policy
    do
        # Skip comments and empty lines
        [[ -z "$num" || "$num" == "#"* ]] && continue

        # Parse size (remove 'G' suffix)
        local size_num="${size%G}"
        if ! [[ "$size_num" =~ ^[0-9]+\.?[0-9]*$ ]]
        then
            continue
        fi

        # Check VRAM fit (80% rule) — use bc if available, otherwise pure bash integer math
        local fits_vram=0
        if command -v bc >/dev/null 2>&1 && [[ "$size_num" == *"."* ]]
        then
            # Has decimal and bc available: use bc for accurate comparison
            if (( $(echo "$size_num <= $vram_gb * 0.8" | bc) ))
            then
                fits_vram=1
            fi
        else
            # Integer-only comparison (works without bc)
            # Multiply by 10 to handle one decimal place: size*10 <= vram*8
            local size_x10=${size_num%.*}
            local size_frac=${size_num#*.}
            if [[ "$size_num" == *"."* && -n "$size_frac" ]]
            then
                # Has decimal: approximate (e.g., 2.5 -> 25)
                size_x10=$(( size_x10 * 10 + ${size_frac:0:1} ))
            else
                size_x10=$(( size_num * 10 ))
            fi
            if (( size_x10 <= vram_gb * 8 ))
            then
                fits_vram=1
            fi
        fi

        if (( fits_vram == 0 ))
        then
            continue  # Model too large
        fi

        # Calculate score
        local score=0
        local reason=""

        # Use-case ELIGIBILITY from the MEASURED workload (v7) — never from the name.
        # The row records the workload its reading was taken on (col 33) and how that
        # reading stands (col 44).  Both must support the request before the row can
        # rank at all: an indicative reading drifted past the 25 % position bound, and
        # a row with no workload recorded has no evidence of fit.  The name is kept
        # only to SHOW a disagreement — it can never earn a point.
        local measured_wk="${_workload// /}"
        local eligible=0
        local why=""
        if [[ -z "$measured_wk" || "$measured_wk" == "-" ]]
        then
            why="no workload reading recorded"
        elif [[ "${meas_state:-}" != "certified" ]]
        then
            why="reading is '${meas_state:-none}', not certified"
        elif [[ " $affinity " == *" ${measured_wk} "* ]]
        then
            eligible=1
            ((score+=3))
            reason="measured-${measured_wk}"
        else
            why="measured ${measured_wk}, which is not a ${use_case} reading"
        fi

        # Name heuristic kept as a CONFLICT NOTE only.  When the name suggests the
        # requested use case and the measurement disagrees, the measurement wins and
        # the disagreement is printed: that is the article's documented-vs-measured
        # error made visible instead of paid for.
        local name_hint=""
        local lname="${name,,}"
        case "$use_case" in
            coding)    [[ "$lname" == *"coder"* || "$lname" == *"code"* ]] && name_hint="coding" ;;
            reasoning) [[ "$lname" == *"qwen"* || "$lname" == *"llama"* ]] && name_hint="reasoning" ;;
            creative)  [[ "$lname" == *"mistral"* || "$lname" == *"phi"* ]] && name_hint="creative" ;;
            *) ;;
        esac
        if [[ -n "$name_hint" && "$eligible" -eq 0 ]]
        then
            why="${why} (the name suggests ${name_hint}; the measurement wins)"
        fi

        if [[ "$eligible" -eq 0 ]]
        then
            # Visible, not ranked: a row that cannot show a certified reading of a
            # requested workload is listed with its reason rather than hidden.  A
            # silent absence reads as "no models fit", which is a different finding.
            ((flagged+=1))
            flagged_rows+=("#$num ${name} — ${why}")
            continue
        fi

        # TPS bonus for performance - CERTIFIED readings only (v6).  An indicative row drifted past
        # the 25 % position bound and a row with no provenance has no defensible figure at all, so
        # neither may buy rank here (Wayne, 2026-10-16: "drop the tps bonus for non-certified rows").
        # v7 note: throughput REFINES a row that already qualified on measured workload; it can
        # never establish eligibility, or "the fastest model wins" is back through the side door.
        local tps_num="${tps% tps}"
        if [[ "${meas_state:-}" == "certified" ]] \
           && [[ "$tps_num" =~ ^[0-9]+([.][0-9]+)?$ ]] && awk -v v="$tps_num" 'BEGIN { exit !(v > 30) }'
        then
            ((score+=1))
            reason="${reason}${reason:+, }high-tps"
        fi

        # VRAM efficiency bonus (smaller models with good performance)
        # Use integer comparison: size < 3 is equivalent to size * 10 < 30
        local is_small=0
        if [[ "$size_num" != *"."* ]] && (( size_num < 3 ))
        then
            is_small=1
        elif [[ "$size_num" == *"."* ]]
        then
            if command -v bc >/dev/null 2>&1
            then
                (( $(echo "$size_num < 3" | bc) )) && is_small=1
            else
                # Fallback without bc: check integer part only
                [[ "${size_num%%.*}" -lt 3 ]] && is_small=1
            fi
        fi
        if (( is_small == 1 && score > 0 ))
        then
            ((score+=1))
            reason="${reason}${reason:+, }vram-efficient"
        fi

        # Only show models with positive score
        if (( score > 0 ))
        then
            found_any=1
            local color="$C_Text"
            (( score >= 4 )) && color="$C_Success"
            (( score == 3 )) && color="$C_Highlight"

            __tac_info "#$num ${name}" "[Score: $score] ${reason}" "$color"
        fi
    done < "$LLM_REGISTRY"

    if (( found_any == 0 ))
    then
        __tac_info "No ranked recommendations" \
            "[no model holds a certified ${use_case} reading]" "$C_Warning"
    fi

    # The unranked list is the point of v7 as much as the ranked one: "no certified
    # coding reading on this box" is an actionable finding ("run model autotune N
    # --workload agentic"), while an empty screen reads as "nothing fits".
    if (( flagged > 0 ))
    then
        __tac_divider
        __tac_info "Unranked" "[${flagged} model(s) fit VRAM but show no certified ${use_case} reading]" \
            "$C_Warning"
        # Capped: the list exists to show the reason, not to be exhaustive.  A full
        # 28-row dump pushes the ranked answer off the screen, which is how a reader
        # ends up choosing by position instead of by evidence.
        local line shown=0
        for line in "${flagged_rows[@]}"
        do
            ((shown >= 10)) && break
            printf '  %s%s%s\n' "${C_Dim:-}" "$line" "${C_Reset:-}"
            shown=$(( shown + 1 ))
        done
        if (( flagged > shown ))
        then
            printf '  %s... and %d more%s\n' "${C_Dim:-}" "$((flagged - shown))" "${C_Reset:-}"
        fi
        __tac_info "To rank one" \
            "[(re)certify a ${use_case} reading: model autotune N --workload <chat|legal|agentic|mix>]" \
            "$C_Text"
    fi

    # Quality axis.  A recommendation is a claim about fitness, so it is measured like
    # any other: tools/llm_outcome_cases.py scores held-out right answers and
    # tools/llm_selection_report.py prints throughput, contract failures and
    # correctness TOGETHER, including whether the model recommended here was the one
    # with the best measured outcome.  No correctness figure is invented here.
    __tac_divider
    local _outcomes="${LLM_OUTCOME_ARTEFACT:-$HOME/.llm/outcomes/latest.json}"
    if [[ -f "$_outcomes" ]]
    then
        __tac_info "Quality" \
            "[measured: python3 tools/llm_selection_report.py --recommended <N> --outcomes $_outcomes]" \
            "$C_Text"
    else
        __tac_info "Quality" \
            "[no correctness observation - run: python3 tools/llm_outcome_cases.py --run --write $_outcomes]" \
            "$C_Warning"
    fi

    __tac_footer
}

# end of file

# end of file marker
