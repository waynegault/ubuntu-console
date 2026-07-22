# shellcheck shell=bash
# shellcheck disable=SC2034,SC2059,SC2120,SC2154
# --- Module: 11f-llm-runtime ---
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 2
# ==============================================================================
# 11f-llm-runtime
# ==============================================================================

# Idempotent include guard: sub-modules are sourced both by their thin
# loader and directly by the profile/env loaders, so run the body once.
[[ -n "${__TAC_MOD_11F_LLM_RUNTIME_LOADED:-}" ]] && return 0
__TAC_MOD_11F_LLM_RUNTIME_LOADED=1

function serve() {
    # Parse optional --ctx-size override before passing to model use
    local ctx_override=""
    local model_arg=""
    while [[ $# -gt 0 ]]
    do
        case "$1" in
            --ctx-size|--ctx)
                ctx_override="$2"
                shift 2
                ;;
            -*)
                printf '%s\n' "${C_Error}[Unknown option: '$1']${C_Reset}"
                printf '%s\n' "  ${C_Dim}Usage: serve [MODEL_NUM] [--ctx-size N]${C_Reset}"
                return 1
                ;;
            *)
                model_arg="$1"
                shift
                ;;
        esac
    done

    # Export context size override so __model_use can pick it up
    if [[ -n "$ctx_override" ]]
    then
        if [[ ! "$ctx_override" =~ ^[0-9]+$ ]]
        then
            printf '%s\n' "${C_Error}[Not a number: '--ctx-size' = '$ctx_override']${C_Reset}"
            return 1
        fi
        export TAC_CTX_SIZE="$ctx_override"
    fi

    if [[ -n "$model_arg" ]]
    then
        model use "$model_arg"
    else
        # Start the default LLM
        local def_num
        def_num=$(__llm_default_number 2>/dev/null || true)
        if [[ -n "$def_num" ]]
        then
            model use "$def_num"
        else
            local def_file=""
            def_file=$(__llm_default_file 2>/dev/null || true)
            if [[ -n "$def_file" ]]
            then
                __tac_info "Local LLM" "[Default file not found in registry: $def_file]" "$C_Error"
            else
                __tac_info "Local LLM" "[NO DEFAULT SET]" "$C_Error"
                printf '%s\n' "  ${C_Dim}Run 'model default <N>' to configure one.${C_Reset}"
            fi
            return 1
        fi
    fi
}
# halt — Stop the currently running LLM model.
function halt() {
    model stop
}

# mlogs — Open the llama-server log file in VS Code.
# In read mode (TAC_READ_MODE=1): outputs log content instead.
function mlogs() {
    if [[ "${TAC_READ_MODE:-}" == "1" ]]
    then
        if [[ -f "$LLM_LOG_FILE" ]]
        then
            printf '%s\n' "=== $LLM_LOG_FILE ==="
            tail -100 "$LLM_LOG_FILE"
        else
            __tac_info "LLM Log" "[NOT FOUND: $LLM_LOG_FILE]" "$C_Warning"
            printf '%s\n' "  ${C_Dim}LLM may not have started yet.${C_Reset}"
        fi
        return 0
    fi
    __resolve_vscode_bin
    "$VSCODE_BIN" "$LLM_LOG_FILE"
    echo "VS Code opened..."
}

# ---------------------------------------------------------------------------
# burn — Stress test the local LLM with a ~1300 token physics prompt.
# Uses non-streaming request with accurate server-reported completion_tokens.
# Pure bash + curl + jq with nanosecond timing.
# ---------------------------------------------------------------------------
function burn() {
    __require_llm || return 1
    if [[ -z "${__BENCH_MODE:-}" ]]
    then
        __tac_header "HARDWARE BURN-IN STRESS TEST"
    fi

    # Wait for the model to finish loading before sending the completion request.
    # The port may be open (passes __require_llm) but the server returns 503
    # "Loading model" while mmap-ing large files over drvfs (up to 90s for CPU).
    if ! __llm_is_healthy
    then
        local burn_ready_timeout="${LLM_BURN_READY_TIMEOUT:-180}"
        printf '%s' "${C_Dim}Waiting for model to finish loading"
        for (( _bw=0; _bw < burn_ready_timeout; _bw++ ))
        do
            __llm_is_healthy && break
            printf '.'
            sleep 1
        done
        printf '%s\n' "$C_Reset"
        if ! __llm_is_healthy
        then
            __tac_info "Status" "Model failed to become healthy - check: tail $LLM_LOG_FILE" "$C_Error"
            return 1
        fi
    fi

    local bench_tokens="${LLM_BENCH_BURN_TOKENS:-768}"
    [[ "$bench_tokens" =~ ^[0-9]+$ ]] || bench_tokens=768
    (( bench_tokens < 128 )) && bench_tokens=128
    printf '%s\n' "${C_Dim}Testing: ~${bench_tokens} token synthetic physics response...${C_Reset}"
    printf '%s\n' "${C_Highlight}Processing ....${C_Reset}"

    local prompt="Explain the complete theory of special relativity"
    prompt+=" in extreme detail, including the mathematical"
    prompt+=" derivations for time dilation."

    # Non-streaming request — curl + jq, with bash nanosecond timing.
    # Bench mode uses deterministic sampling to make cross-run TPS comparisons
    # less sensitive to random token path variation.
    local payload
    if [[ -n "${__BENCH_MODE:-}" ]]
    then
        payload=$(jq -n \
            --arg p "$prompt" \
            --argjson bench_tokens "$bench_tokens" \
            --argjson bench_temp "${LLM_BENCH_TEMPERATURE:-0}" \
            '{messages: [{role: "user", content: $p}], max_tokens: $bench_tokens, temperature: $bench_temp, top_p: 1.0}')
    else
        payload=$(jq -n --arg p "$prompt" \
            '{messages: [{role: "user", content: $p}], max_tokens: 1500, temperature: 0.7}')
    fi

    local request_timeout=360
    if [[ -f "$ACTIVE_LLM_FILE" && -f "$LLM_REGISTRY" ]]
    then
        local _burn_num _burn_entry _burn_gpu _burn_size
        _burn_num=$(< "$ACTIVE_LLM_FILE")
        _burn_entry=$(awk -F'|' -v n="$_burn_num" '$1 == n {print; exit}' \
            "$LLM_REGISTRY" 2>/dev/null)
        if [[ -n "$_burn_entry" ]]
        then
            IFS='|' read -r _n _name _file _burn_size _arch _quant _layers \
                _burn_gpu _ctx _threads _tps <<< "$_burn_entry"
            request_timeout=$(__llm_burn_request_timeout "${_burn_size:-0G}" "${_burn_gpu:-0}" "${_arch:-}" "${__BENCH_MODE:-}")
        fi
    fi

    local start_ns end_ns response curl_rc
    local transport_history=""
    local transport_recovered=0
    local attempt=1
    local max_attempts="${LLM_BURN_MAX_ATTEMPTS:-}"
    local retry_health_wait="${LLM_BURN_RETRY_HEALTH_WAIT:-30}"
    local retry_settle_sec="${LLM_BURN_RETRY_SETTLE_SEC:-2}"
    if [[ ! "$max_attempts" =~ ^[0-9]+$ ]]
    then
        if [[ -n "${__BENCH_MODE:-}" ]]
        then
            max_attempts=4
        else
            max_attempts=3
        fi
    fi
    (( max_attempts < 1 )) && max_attempts=1
    [[ "$retry_health_wait" =~ ^[0-9]+$ ]] || retry_health_wait=30
    (( retry_health_wait < 1 )) && retry_health_wait=1
    [[ "$retry_settle_sec" =~ ^[0-9]+$ ]] || retry_settle_sec=2
    (( retry_settle_sec < 0 )) && retry_settle_sec=0
    local _burn_recovery_attempt=0
    while true
    do
        start_ns=$(date +%s%N)
        response=$(curl -sS --max-time "$request_timeout" "$LOCAL_LLM_URL" \
            -H "Content-Type: application/json" \
            -d "$payload" 2>/dev/null)
        curl_rc=$?
        end_ns=$(date +%s%N)

        # Retry transient transport issues (e.g. brief server restart/socket
        # reset) to improve benchmark fairness and reduce false negatives.
        if (( curl_rc != 0 && curl_rc != 28 && attempt < max_attempts ))
        then
            [[ -n "$transport_history" ]] && transport_history+=","
            transport_history+="$curl_rc"
            local _retry_msg
            local _next_attempt=$(( attempt + 1 ))
            _retry_msg="${C_Dim}[API Retry]${C_Reset} Transport error (curl ${curl_rc}); "
            _retry_msg+="request ${attempt}/${max_attempts}; waiting up to ${retry_health_wait}s before retry ${_next_attempt}/${max_attempts}..."
            printf '%s\n' \
                "$_retry_msg"
            if [[ -n "${__BENCH_MODE:-}" ]] && [[ "$bench_tokens" =~ ^[0-9]+$ ]] && (( bench_tokens > 128 ))
            then
                local _retry_tokens=$(( bench_tokens / 2 ))
                (( _retry_tokens < 128 )) && _retry_tokens=128
                if (( _retry_tokens < bench_tokens ))
                then
                    bench_tokens=$_retry_tokens
                    payload=$(jq -n \
                        --arg p "$prompt" \
                        --argjson bench_tokens "$bench_tokens" \
                        --argjson bench_temp "${LLM_BENCH_TEMPERATURE:-0}" \
                        '{messages: [{role: "user", content: $p}], max_tokens: $bench_tokens, temperature: $bench_temp, top_p: 1.0}')
                    printf '%s\n' "${C_Dim}[API Retry]${C_Reset} Retrying with ${bench_tokens} tokens after transient failure."
                fi
            fi
            local _rh
            local _healthy=0
            for (( _rh=0; _rh < retry_health_wait; _rh++ ))
            do
                if __llm_is_healthy
                then
                    _healthy=1
                    # Pre-flight a tiny completion to confirm the slot is actually
                    # ready (WSL2: /health can return OK before the model slot can
                    # serve completions).
                    if [[ -n "${__BENCH_MODE:-}" ]]
                    then
                        local _pf_body='{"messages":[{"role":"user","content":"hi"}],"max_tokens":1,"temperature":0}'
                        local _pf_rc
                        _pf_rc=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 \
                            -H 'Content-Type: application/json' \
                            -d "$_pf_body" "http://127.0.0.1:$LLM_PORT/v1/chat/completions" 2>/dev/null || echo 0)
                        if [[ "$_pf_rc" != "200" ]]
                        then
                            # Slot not ready — poll until it responds.
                            for (( _pfr=0; _pfr < 60; _pfr++ ))
                            do
                                sleep 1
                                _pf_rc=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 \
                                    -H 'Content-Type: application/json' \
                                    -d "$_pf_body" "http://127.0.0.1:$LLM_PORT/v1/chat/completions" 2>/dev/null || echo 0)
                                [[ "$_pf_rc" == "200" ]] && break
                            done
                        fi
                    fi
                    if (( retry_settle_sec > 0 ))
                    then
                        sleep "$retry_settle_sec"
                    fi
                    break
                fi
                sleep 1
            done

            # If readiness never recovered during wait, attempt one active-model
            # restart as auto-recovery before consuming remaining retries.
            if (( _healthy == 0 ))
            then
                printf '%s\n' "${C_Dim}[API Retry]${C_Reset} Server still unhealthy after ${retry_health_wait}s."

                if [[ "${LLM_BURN_AUTO_RECOVER:-1}" == "1" ]] \
                    && [[ -n "${_burn_num:-}" && "${_burn_num:-}" =~ ^[0-9]+$ ]]
                then
                    printf '%s\n' "${C_Dim}[API Recover]${C_Reset} Restarting active model #${_burn_num} after transport failure..."
                    # Clear VRAM before reload to remove ghost allocations from the
                    # failed server instance (WSL2 CUDA often holds stale memory).
                    sudo -n /usr/local/bin/clear_vram.sh >/dev/null 2>&1 || true
                    # Step-down ctx on each successive recovery attempt so a broken
                    # autotuned ctx does not cause repeated identical crashes.
                    _burn_recovery_attempt=$(( _burn_recovery_attempt + 1 ))
                    local _burn_saved_ctx="${LLAMA_N_CTX:-${_ctx:-4096}}"
                    if (( _burn_recovery_attempt > 1 )) && [[ -n "${_ctx:-}" ]]
                    then
                        local _burn_reduced_ctx=$(( _ctx / (2 ** (_burn_recovery_attempt - 1)) ))
                        [[ "$_burn_reduced_ctx" -lt 4096 ]] && _burn_reduced_ctx=4096
                        export LLAMA_N_CTX="$_burn_reduced_ctx"
                        printf '%s\n' "${C_Dim}[API Recover]${C_Reset} Step-down ctx: ${_ctx} \xe2\x86\x92 ${_burn_reduced_ctx} (attempt ${_burn_recovery_attempt})"
                    fi
                    if __model_use "$_burn_num" >/tmp/burn_transport_recover_use.log 2>&1
                    then
                        local _rw
                        for (( _rw=0; _rw < retry_health_wait; _rw++ ))
                        do
                            if __llm_is_healthy
                            then
                                transport_recovered=1
                                printf '%s\n' "${C_Dim}[API Recover]${C_Reset} Model recovered; retrying request."
                                break
                            fi
                            sleep 1
                        done
                    fi
                    # Restore original ctx after the recovery attempt so subsequent
                    # health checks and retries use the configured value.
                    export LLAMA_N_CTX="$_burn_saved_ctx"
                fi
            fi

            attempt=$(( attempt + 1 ))
            continue
        fi

        # Retry once if server returned 503 "Loading model" (readiness race:
        # /health reports ok before the model slot is fully ready to serve).
        if (( curl_rc == 0 && attempt < max_attempts ))
        then
            local _loading_msg
            _loading_msg=$(printf '%s' "$response" | jq -r '.error.message // empty' 2>/dev/null)
            if [[ "$_loading_msg" == *[Ll]oading* ]]
            then
                local _loading_retry_msg
                _loading_retry_msg="${C_Dim}[API Retry]${C_Reset} Server still loading "
                _loading_retry_msg+="(\"${_loading_msg}\"); waiting up to 30s..."
                printf '%s\n' \
                    "$_loading_retry_msg"
                local _lw
                for (( _lw=0; _lw < 30; _lw++ ))
                do
                    if __llm_is_healthy; then
                        sleep 3
                        break
                    fi
                    sleep 1
                done
                attempt=$(( attempt + 1 ))
                continue
            fi
        fi

        break
    done

    if (( curl_rc == 28 ))
    then
        printf '%s\n' \
            "${C_Warning}[API Timeout]${C_Reset} No response within ${request_timeout}s "\
    "(model likely still computing, not necessarily crashed)."
        return 1
    fi
    if (( curl_rc != 0 ))
    then
        [[ -n "$transport_history" ]] && transport_history+=","
        [[ -n "${curl_rc:-}" ]] && transport_history+="$curl_rc"
        printf '%s\n' "${C_Error}[API Transport Error]${C_Reset} curl exit ${curl_rc} while calling local server (attempts: ${attempt}/${max_attempts}; rc history: ${transport_history:-$curl_rc})."
        return 1
    fi

    if [[ -z "$response" ]]
    then
        printf '%s\n' "${C_Error}[API Error]${C_Reset} Empty response from local server."
        return 1
    fi

    # Check for HTTP-level error in response body
    local err_msg
    err_msg=$(printf '%s' "$response" | jq -r '.error.message // empty' 2>/dev/null)
    if [[ -n "$err_msg" ]]
    then
        printf '%s\n' "${C_Warning}[API Status]${C_Reset} $err_msg"
        return 1
    fi

    local elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
    local elapsed_s=$(( elapsed_ms / 1000 ))
    local elapsed_dec=$(( (elapsed_ms % 1000) / 100 ))

    # Prefer server-reported completion_tokens; fall back to word count
    local tokens
    tokens=$(printf '%s' "$response" | jq -r '.usage.completion_tokens // 0' 2>/dev/null)
    if (( tokens == 0 ))
    then
        tokens=$(printf '%s' "$response" | jq -r '.choices[0].message.content // ""' 2>/dev/null | wc -w)
    fi

    local tps_int=0 tps_dec=0
    if (( elapsed_ms > 0 && tokens > 0 ))
    then
        local tps_x10=$(( tokens * 10000 / elapsed_ms ))
        tps_int=$(( tps_x10 / 10 ))
        tps_dec=$(( tps_x10 % 10 ))
    fi

    if [[ -z "${__BENCH_MODE:-}" ]]
    then
        printf '%s\n' "${C_Dim}Hint: If inference was slow, first run \"wake\" to lock WDDM state.${C_Reset}"
    fi
    printf '%s\n' \
        "${C_Success}Burn complete: ${tps_int}.${tps_dec} tps" \
        "(${tokens} tokens in ${elapsed_s}.${elapsed_dec}s)${C_Reset}"
    echo "${tps_int}.${tps_dec} tps" > "${LLM_TPS_CACHE}.tmp" && mv "${LLM_TPS_CACHE}.tmp" "$LLM_TPS_CACHE"
    __save_tps "${tps_int}.${tps_dec}"

    [[ -f "$LLM_TPS_CACHE" ]] && LAST_TPS=$(< "$LLM_TPS_CACHE")
    return 0
}

# ---------------------------------------------------------------------------
# explain — Ask the local LLM to explain the last command run in the terminal.
# Uses `fc -ln -2 -2` instead of history parsing for reliability with HISTCONTROL.
# ---------------------------------------------------------------------------
function explain() {
    local last_cmd
    last_cmd=$(fc -ln -2 -2 2>/dev/null | sed 's/^\s*//')
    if [[ -z "$last_cmd" ]]
    then
        __tac_line "Explain" "[NO PREVIOUS COMMAND FOUND]" "$C_Warning"
        return 1
    fi
    __llm_stream "Explain this bash command and diagnose any potential errors:\n$last_cmd"
}

# ---------------------------------------------------------------------------
# wtf_repl — Ask the local LLM to explain a tool or concept (toggle mode).
# Type a topic, get an explanation, then type another. 'end-chat' or Ctrl-C to exit.
# Aliased as 'wtf:' in section 3.
# ---------------------------------------------------------------------------
function wtf_repl() {
    local initial="$*"
    __require_llm || return 1

    # Trap Ctrl-C so it breaks the loop cleanly (exit 0, no error badge)
    trap 'echo; trap - INT; return 0' INT

    # If called with args, handle the first query then enter the loop
    if [[ -n "$initial" ]]
    then
        __llm_stream "Explain how to use the following tool or concept:\n$initial"
    fi
    printf '%s\n' "${C_Dim}wtf: mode - type a topic (or 'end-chat' / Ctrl-C to exit)${C_Reset}"
    while true
    do
        local topic
        read -r -e -p "${C_Highlight}wtf: ${C_Reset}" topic || break
        [[ -z "$topic" ]] && continue
        [[ "$topic" == "end-chat" ]] && break
        __llm_stream "Explain how to use the following tool or concept:\n$topic"
    done

    trap - INT
}

# ---------------------------------------------------------------------------
# __llm_sse_core — Shared SSE streaming engine for all LLM functions.
# Called by __llm_stream (one-shot prompts) and __llm_chat_send (multi-turn).
# Pure bash + curl + jq. Posts payload to llama.cpp OpenAI-compatible API,
# streams SSE delta chunks, computes TPS, caches metrics.
# Sets __LAST_LLM_RESPONSE with the full response text.
# Usage: __llm_sse_core "$json_payload"
# ---------------------------------------------------------------------------
function __llm_sse_core() {
    local payload="$1"
    __LAST_LLM_RESPONSE=""

    local start_ns
    start_ns=$(date +%s%N)
    local chunk_count=0
    local server_tokens=0
    local response_text=""

    while IFS= read -r line
    do
        [[ "$line" != data:* ]] && continue
        local payload_data="${line#data: }"
        [[ "$payload_data" == "[DONE]" ]] && break

        local content
        content=$(printf '%s' "$payload_data" | jq -r '.choices[0].delta.content // empty' 2>/dev/null)
        if [[ -n "$content" ]]
        then
            printf '%s' "$content"
            response_text+="$content"
            ((++chunk_count))
        fi

        local srv_tok
        srv_tok=$(printf '%s' "$payload_data" | jq -r '.usage.completion_tokens // empty' 2>/dev/null)
        [[ -n "$srv_tok" && "$srv_tok" != "null" ]] && server_tokens=$srv_tok
    done < <(curl -s --no-buffer --max-time 300 -X POST "$LOCAL_LLM_URL" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null | tr -d '\r')

    local end_ns
    end_ns=$(date +%s%N)
    local elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
    local tokens=$server_tokens
    if (( tokens == 0 ))
    then
        tokens=$chunk_count
    fi

    if (( tokens > 0 && elapsed_ms > 0 ))
    then
        local tps_x10=$(( tokens * 10000 / elapsed_ms ))
        local tps_int=$(( tps_x10 / 10 ))
        local tps_dec=$(( tps_x10 % 10 ))
        local elapsed_s=$(( elapsed_ms / 1000 ))
        printf '\n%s(%s.%s tps)%s\n' "$C_Dim" "$tps_int" "$tps_dec" "$C_Reset"
        echo "${tps_int}.${tps_dec} tps" > "${LLM_TPS_CACHE}.tmp" && mv "${LLM_TPS_CACHE}.tmp" "$LLM_TPS_CACHE"
        __save_tps "${tps_int}.${tps_dec}"
    else
        echo
    fi

    [[ -f "$LLM_TPS_CACHE" ]] && LAST_TPS=$(< "$LLM_TPS_CACHE")
    __LAST_LLM_RESPONSE="$response_text"
}

# ---------------------------------------------------------------------------
# __llm_stream — SSE streaming helper for explain / wtf / chat.
# Usage: __llm_stream "prompt text" [show_header: 1|0] [messages_json]
#   If messages_json is provided (a valid JSON array), it is sent directly
#   instead of wrapping prompt in a single user message. This enables
#   multi-turn conversation history for local_chat.
# MODULARISATION NOTE: writes LLM_TPS_CACHE, read by tactical_dashboard.
# ---------------------------------------------------------------------------
function __llm_stream() {
    local prompt="$1"
    local show_header="${2:-1}"
    local messages_json="${3:-}"
    __require_llm || return 1

    local payload
    if [[ -n "$messages_json" ]]
    then
        payload=$(jq -n --argjson msgs "$messages_json" '{messages: $msgs, stream: true}')
    else
        payload=$(jq -n --arg p "$prompt" '{messages: [{role: "user", content: $p}], stream: true}')
    fi

    (( show_header == 1 )) && printf '\n%s\n\n' "${C_Highlight}AI Analysis:${C_Reset}"

    __llm_sse_core "$payload"
}

# ---------------------------------------------------------------------------
# __llm_chat_send — Send a message with conversation history to the local LLM.
# Usage: __llm_chat_send "user message" "messages_json_array"
#   Returns: the assistant's response text is captured via __LAST_LLM_RESPONSE.
# ---------------------------------------------------------------------------
function __llm_chat_send() {
    local user_msg="$1"
    local messages_json="$2"
    __require_llm || return 1

    local payload
    payload=$(jq -n --argjson msgs "$messages_json" '{messages: $msgs, stream: true}')

    __llm_sse_core "$payload"
}

# ---------------------------------------------------------------------------
# local_chat — Interactive chat REPL with multi-turn conversation history.
# Accumulates user and assistant messages so the LLM has context of the full
# conversation. First argument (if any) becomes the opening message.
# Type 'end-chat' or press Ctrl-C to return to the shell.
# Aliased as 'chatl' in section 3.
# ---------------------------------------------------------------------------
function local_chat() {
    __require_llm || return 1

    # Trap Ctrl-C: clean up nested function, restore trap, exit cleanly
    trap 'echo; unset -f __send_chat_msg 2>/dev/null; trap - INT; return 0' INT

    # Conversation history as a JSON array string
    local history='[]'

    # __send_chat_msg is a nested (dynamic-scoped) function that captures
    # the 'history' local variable from local_chat's scope. This works because
    # bash uses dynamic scoping — nested functions inherit the caller's locals.
    # It will break if extracted to file scope without passing history by reference.
    function __send_chat_msg() {
        local user_msg="$1"
        # Append user message to history
        history=$(printf '%s' "$history" \
            | jq --arg m "$user_msg" '. + [{role: "user", content: $m}]')
        echo
        __llm_chat_send "$user_msg" "$history"
        # Append assistant response to history
        if [[ -n "$__LAST_LLM_RESPONSE" ]]
        then
            history=$(printf '%s' "$history" \
                | jq --arg m "$__LAST_LLM_RESPONSE" \
                '. + [{role: "assistant", content: $m}]')
        fi
    }

    local initial="$*"
    # If called with an initial prompt, send it first
    if [[ -n "$initial" ]]
    then
        __send_chat_msg "$initial"
    fi
    printf '%s\n' "${C_Dim}chat: mode - type a message (or 'end-chat' / 'save' / Ctrl-C to exit)${C_Reset}"
    while true
    do
        local msg
        echo
        read -r -e -p "${C_Highlight}chat: ${C_Reset}" msg || break
        [[ -z "$msg" ]] && continue
        [[ "$msg" == "end-chat" ]] && break
        if [[ "$msg" == "save" ]]
        then
            local save_file
            save_file="$HOME/chat_$(date +%Y%m%d_%H%M%S).json"
            printf '%s' "$history" | jq '.' > "$save_file" 2>/dev/null \
                && printf '%s\n' "${C_Success}Saved to $save_file${C_Reset}" \
                || printf '%s\n' "${C_Error}Failed to save${C_Reset}"
            continue
        fi
        __send_chat_msg "$msg"
    done

    unset -f __send_chat_msg
    trap - INT
}

# ---------------------------------------------------------------------------
# chat-context — Feed a file as context then ask the local LLM about it.
# Usage: chat-context <file> "question about this file"
# The file content is prepended as context to the user's question.
# ---------------------------------------------------------------------------
function chat-context() {
    if [[ -z "$1" ]]
    then
        printf '%s\n' "${C_Dim}Usage:${C_Reset} chat-context <file> \"question about this file\""
        return 1
    fi
    local file="$1"; shift
    local question="$*"
    if [[ ! -f "$file" ]]
    then
        __tac_info "File" "[NOT FOUND: $file]" "$C_Error"
        return 1
    fi
    __require_llm || return 1
    # Cap file content to stay within context window (configurable via env)
    local max_chars="${CHAT_CONTEXT_MAX:-16000}"
    local content
    content=$(head -c "$max_chars" "$file")
    local prompt="Here is the content of '$file':\n\n\`\`\`\n${content}\n\`\`\`\n\n${question:-Explain this file.}"
    __llm_stream "$prompt"
}

# ---------------------------------------------------------------------------
# chat-pipe — Pipe stdin as context and ask the local LLM about it.
# Usage: cat error.log | chat-pipe "What's wrong here?"
# ---------------------------------------------------------------------------
function chat-pipe() {
    __require_llm || return 1
    local ctx
    ctx=$(cat)
    if [[ -z "$ctx" ]]
    then
        __tac_info "stdin" "[EMPTY - pipe some content]" "$C_Error"
        return 1
    fi
    local question="${*:-Explain this.}"
    __llm_stream "${ctx}\n\n${question}"
}
# end of file






# end of file
