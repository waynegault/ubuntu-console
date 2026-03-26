# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154
# ─── Module: 15-model-recommender ───────────────────────────────────────────────────────
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# TACTICAL_PROFILE_VERSION auto-computes from the sum of all module versions.
# Module Version: 1
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

    # Calculate available VRAM in GB (fallback to 4GB if unavailable)
    local vram_gb=4
    if [[ -n "${VRAM_TOTAL_BYTES:-}" ]]
    then
        vram_gb=$(( VRAM_TOTAL_BYTES / 1024 / 1024 / 1024 ))
    elif command -v nvidia-smi >/dev/null 2>&1
    then
        local vram_mb
        vram_mb=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
        if [[ "$vram_mb" =~ ^[0-9]+$ ]]
        then
            vram_gb=$(( vram_mb / 1024 ))
        fi
    fi

    __tac_header "MODEL RECOMMENDATIONS" "open"
    __tac_info "VRAM Available" "${vram_gb}GB" "$C_Highlight"
    __tac_info "Use Case" "${use_case}" "$C_Highlight"
    __tac_divider

    local found_any=0

    # Score and rank models
    # Scoring:
    #   +3 for use case match (coding → coder models, etc.)
    #   +2 for architecture match (qwen/llama for reasoning)
    #   +1 for high TPS (>30)
    # Only show models that fit within 80% of VRAM
    while IFS='|' read -r num name file size arch quant layers gpu_layers ctx threads tps
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

        # Use case matching
        case "$use_case" in
            coding)
                if [[ "${name,,}" == *"coder"* || "${name,,}" == *"code"* ]]
                then
                    ((score+=3))
                    reason="coding-optimized"
                fi
                ;;
            reasoning)
                if [[ "${name,,}" == *"qwen"* || "${name,,}" == *"llama"* ]]
                then
                    ((score+=2))
                    reason="strong-reasoning"
                fi
                ;;
            creative)
                if [[ "${name,,}" == *"mistral"* || "${name,,}" == *"phi"* ]]
                then
                    ((score+=2))
                    reason="creative-writing"
                fi
                ;;
        esac

        # TPS bonus for performance
        local tps_num="${tps% tps}"
        if [[ "$tps_num" =~ ^[0-9]+$ ]] && (( tps_num > 30 ))
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
        __tac_info "No recommendations" "[Try 'general' use case or check VRAM]" "$C_Warning"
    fi

    __tac_footer
}

# end of file
