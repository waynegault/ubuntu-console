# ==============================================================================
# OpenClaw bash completions — GENERATED FILE, do not edit by hand.
# Regenerate with: tools/sync-openclaw-completion.sh
# Source: `openclaw completion --shell bash`
# ==============================================================================

_openclaw_completion() {
    local cur opts command_path candidate_path value_options word flag i j cword remaining_line word_prefix
    local character next_character quote
    local choice_flag choice_prefix choice_completion_prefix short_group short_flag short_index
    local required_value_options options_ended=0 literal_opts=""
    local -a words=()
    # Before Bash 4.3, COMP_POINT is a byte offset; string spans must use the same units.
    if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3))); then
        local LC_ALL=C
    fi
    COMPREPLY=()
    remaining_line="${COMP_LINE}"
    # Rejoin '=' and ':' wordbreaks, preserving redirections and whitespace boundaries.
    # Bash versions split '=' differently; $2 remains the fragment Readline will replace.
    for ((i = 0; i <= COMP_CWORD; i++)); do
        word="${COMP_WORDS[i]}"
        if ((i > 0)) && [[ -n "${word}" && "${remaining_line}" == "${word}"* &&
            ( "${word}" =~ ^[=:]+$ || "${COMP_WORDS[i-1]}" =~ ^[=:]+$ ) ]]; then
            words[${#words[@]}-1]+="${word}"
        else
            words+=("${word}")
        fi
        remaining_line="${remaining_line#*"${word}"}"
    done
    cword=$((${#words[@]} - 1))
    cur="${words[cword]}"
    # COMP_WORDS includes text after the cursor; only the prefix participates in completion.
    cur="${cur:0:${#cur} + COMP_POINT - ${#COMP_LINE} + ${#remaining_line}}"
    word_prefix="${cur%"$2"}"
    # Normalize words and the replacement prefix together: Readline keeps quoting
    # in COMP_WORDS, while its replacement span can start inside that quoted word.
    words[cword]="${cur}"
    words+=("${word_prefix}")
    for ((i = 0; i < ${#words[@]}; i++)); do
        word="${words[i]}"
        words[i]=""
        quote=""
        for ((j = 0; j < ${#word}; j++)); do
            character="${word:j:1}"
            if [[ $character == \\ && $quote != "'" ]]; then
                next_character="${word:j+1:1}"
                if [[ -z $quote || $next_character == [\\\$\"\`] || $next_character == $'\n' ]]; then
                    j=$((j + 1))
                    [[ $next_character == $'\n' ]] || words[i]+="$next_character"
                    continue
                fi
            elif [[ $character == "$quote" ]]; then
                quote=""
                continue
            elif [[ -z $quote && $character == [\'\"] ]]; then
                quote="$character"
                continue
            fi
            words[i]+="$character"
        done
    done
    cur="${words[cword]}"
    word_prefix="${words[cword+1]}"
    opts="acp agent agentmail agents approvals exec-approvals attach audit backup browser channels clawbot completion config configure connect cron automations daemon dashboard database devices directory dns docs doctor exec-policy file-transfer fleet gateway health hooks infer capability logs mcp memory message migrate models node nodes onboard pairing plugins policy promos proxy qr reset resume sandbox secrets security sessions setup skills status storage system telemetry transcripts triage tui terminal chat uninstall update users webhooks workboard worker worktrees -V --version --container --dev --profile --log-level --no-color"
    value_options="--container --profile --log-level"
    required_value_options="--container --profile --log-level"
    command_path=""

    for ((i = 1; i < cword; i++)); do
        word="${words[i]}"
        if [[ ${word} == -- ]]; then
            options_ended=1
            continue
        fi
        if (( ! options_ended )) && [[ ${word} == -* ]]; then
            flag="${word%%=*}"
            if [[ ${word} == -??* && ${word} != --* ]]; then
                for ((short_index = 1; short_index < ${#word}; short_index++)); do
                    short_flag="-${word:short_index:1}"
                    if [[ " ${value_options} " == *" ${short_flag} "* ]]; then
                        flag=""
                        ((short_index == ${#word} - 1)) && flag="${short_flag}"
                        break
                    fi
                done
            fi
            if [[ ${word} != *=* && -n ${flag} && " ${value_options} " == *" ${flag} "* &&
                ( ${words[i+1]} != -?* || " ${required_value_options} " == *" ${flag} "* ) ]]; then
                i=$((i + 1))
            fi
            continue
        fi

        candidate_path="${command_path:+${command_path} }${word}"
        case "${candidate_path}" in
          "completion")
            command_path="${candidate_path}"
            opts="-s --shell -i --install --write-state -y --yes"
            value_options="--container --profile --log-level -s --shell"
            required_value_options="--container --profile --log-level -s --shell"
            ;;
          "setup")
            command_path="${candidate_path}"
            opts="--workspace --agent-name --team --wizard --baseline --reset --reset-scope --non-interactive --classic --tui --accept-risk --flow --mode --auth-choice --token-provider --token --token-profile-id --token-expires-in --secret-input-mode --cloudflare-ai-gateway-account-id --cloudflare-ai-gateway-gateway-id --alibaba-model-studio-api-key --anthropic-api-key --clawrouter-api-key --fal-api-key --github-copilot-token --gemini-api-key --huggingface-api-key --kie-api-key --litellm-api-key --lmstudio-api-key --minimax-api-key --nvidia-api-key --ollama-cloud-api-key --openai-api-key --opencode-go-api-key --openrouter-api-key --runway-api-key --together-api-key --xai-api-key --deepseek-api-key --fireworks-api-key --groq-api-key --llama-server-api-key --moonshot-api-key --modelstudio-standard-api-key-cn --modelstudio-standard-api-key --modelstudio-api-key-cn --modelstudio-api-key --qwen-token-plan-api-key --qwen-token-plan-api-key-cn --arceeai-api-key --baseten-api-key --byteplus-api-key --cerebras-api-key --chutes-api-key --cohere-api-key --cloudflare-ai-gateway-api-key --comfy-api-key --deepinfra-api-key --featherless-api-key --gmi-api-key --longcat-api-key --meta-api-key --mistral-api-key --novita-api-key --opencode-zen-api-key --kilocode-api-key --kimi-code-api-key --pixverse-api-key --qianfan-api-key --radius-api-key --tokenhub-api-key --tokenplan-api-key --telnyx-api-key --venice-api-key --ai-gateway-api-key --vydra-api-key --xiaomi-api-key --xiaomi-token-plan-api-key --zai-api-key --synthetic-api-key --volcengine-api-key --stepfun-api-key --custom-base-url --custom-api-key --custom-model-id --custom-provider-id --custom-compatibility --custom-image-input --custom-text-input --gateway-port --gateway-bind --gateway-auth --gateway-token --gateway-token-ref-env --gateway-password --tailscale --install-daemon --no-install-daemon --skip-daemon --daemon-runtime --skip-channels --skip-skills --skip-bootstrap --skip-search --skip-health --skip-ui --suppress-gateway-token-output --skip-hooks --node-manager --import-from --import-source --import-secrets --remote-url --remote-token --remote-password -m --message --yes --json"
            value_options="--container --profile --log-level --workspace --agent-name --reset-scope --flow --mode --auth-choice --token-provider --token --token-profile-id --token-expires-in --secret-input-mode --cloudflare-ai-gateway-account-id --cloudflare-ai-gateway-gateway-id --alibaba-model-studio-api-key --anthropic-api-key --clawrouter-api-key --fal-api-key --github-copilot-token --gemini-api-key --huggingface-api-key --kie-api-key --litellm-api-key --lmstudio-api-key --minimax-api-key --nvidia-api-key --ollama-cloud-api-key --openai-api-key --opencode-go-api-key --openrouter-api-key --runway-api-key --together-api-key --xai-api-key --deepseek-api-key --fireworks-api-key --groq-api-key --llama-server-api-key --moonshot-api-key --modelstudio-standard-api-key-cn --modelstudio-standard-api-key --modelstudio-api-key-cn --modelstudio-api-key --qwen-token-plan-api-key --qwen-token-plan-api-key-cn --arceeai-api-key --baseten-api-key --byteplus-api-key --cerebras-api-key --chutes-api-key --cohere-api-key --cloudflare-ai-gateway-api-key --comfy-api-key --deepinfra-api-key --featherless-api-key --gmi-api-key --longcat-api-key --meta-api-key --mistral-api-key --novita-api-key --opencode-zen-api-key --kilocode-api-key --kimi-code-api-key --pixverse-api-key --qianfan-api-key --radius-api-key --tokenhub-api-key --tokenplan-api-key --telnyx-api-key --venice-api-key --ai-gateway-api-key --vydra-api-key --xiaomi-api-key --xiaomi-token-plan-api-key --zai-api-key --synthetic-api-key --volcengine-api-key --stepfun-api-key --custom-base-url --custom-api-key --custom-model-id --custom-provider-id --custom-compatibility --gateway-port --gateway-bind --gateway-auth --gateway-token --gateway-token-ref-env --gateway-password --tailscale --daemon-runtime --node-manager --import-from --import-source --remote-url --remote-token --remote-password -m --message"
            required_value_options="--container --profile --log-level --workspace --agent-name --reset-scope --flow --mode --auth-choice --token-provider --token --token-profile-id --token-expires-in --secret-input-mode --cloudflare-ai-gateway-account-id --cloudflare-ai-gateway-gateway-id --alibaba-model-studio-api-key --anthropic-api-key --clawrouter-api-key --fal-api-key --github-copilot-token --gemini-api-key --huggingface-api-key --kie-api-key --litellm-api-key --lmstudio-api-key --minimax-api-key --nvidia-api-key --ollama-cloud-api-key --openai-api-key --opencode-go-api-key --openrouter-api-key --runway-api-key --together-api-key --xai-api-key --deepseek-api-key --fireworks-api-key --groq-api-key --llama-server-api-key --moonshot-api-key --modelstudio-standard-api-key-cn --modelstudio-standard-api-key --modelstudio-api-key-cn --modelstudio-api-key --qwen-token-plan-api-key --qwen-token-plan-api-key-cn --arceeai-api-key --baseten-api-key --byteplus-api-key --cerebras-api-key --chutes-api-key --cohere-api-key --cloudflare-ai-gateway-api-key --comfy-api-key --deepinfra-api-key --featherless-api-key --gmi-api-key --longcat-api-key --meta-api-key --mistral-api-key --novita-api-key --opencode-zen-api-key --kilocode-api-key --kimi-code-api-key --pixverse-api-key --qianfan-api-key --radius-api-key --tokenhub-api-key --tokenplan-api-key --telnyx-api-key --venice-api-key --ai-gateway-api-key --vydra-api-key --xiaomi-api-key --xiaomi-token-plan-api-key --zai-api-key --synthetic-api-key --volcengine-api-key --stepfun-api-key --custom-base-url --custom-api-key --custom-model-id --custom-provider-id --custom-compatibility --gateway-port --gateway-bind --gateway-auth --gateway-token --gateway-token-ref-env --gateway-password --tailscale --daemon-runtime --node-manager --import-from --import-source --remote-url --remote-token --remote-password -m --message"
            ;;
          "crestodian")
            command_path="${candidate_path}"
            opts="-m --message --yes --json"
            value_options="--container --profile --log-level -m --message"
            required_value_options="--container --profile --log-level -m --message"
            ;;
          "onboard")
            command_path="${candidate_path}"
            opts="recommendations --workspace --agent-name --team --reset --reset-scope --non-interactive --modern --classic --tui --accept-risk --flow --mode --auth-choice --token-provider --token --token-profile-id --token-expires-in --secret-input-mode --cloudflare-ai-gateway-account-id --cloudflare-ai-gateway-gateway-id --alibaba-model-studio-api-key --anthropic-api-key --clawrouter-api-key --fal-api-key --github-copilot-token --gemini-api-key --huggingface-api-key --kie-api-key --litellm-api-key --lmstudio-api-key --minimax-api-key --nvidia-api-key --ollama-cloud-api-key --openai-api-key --opencode-go-api-key --openrouter-api-key --runway-api-key --together-api-key --xai-api-key --deepseek-api-key --fireworks-api-key --groq-api-key --llama-server-api-key --moonshot-api-key --modelstudio-standard-api-key-cn --modelstudio-standard-api-key --modelstudio-api-key-cn --modelstudio-api-key --qwen-token-plan-api-key --qwen-token-plan-api-key-cn --arceeai-api-key --baseten-api-key --byteplus-api-key --cerebras-api-key --chutes-api-key --cohere-api-key --cloudflare-ai-gateway-api-key --comfy-api-key --deepinfra-api-key --featherless-api-key --gmi-api-key --longcat-api-key --meta-api-key --mistral-api-key --novita-api-key --opencode-zen-api-key --kilocode-api-key --kimi-code-api-key --pixverse-api-key --qianfan-api-key --radius-api-key --tokenhub-api-key --tokenplan-api-key --telnyx-api-key --venice-api-key --ai-gateway-api-key --vydra-api-key --xiaomi-api-key --xiaomi-token-plan-api-key --zai-api-key --synthetic-api-key --volcengine-api-key --stepfun-api-key --custom-base-url --custom-api-key --custom-model-id --custom-provider-id --custom-compatibility --custom-image-input --custom-text-input --gateway-port --gateway-bind --gateway-auth --gateway-token --gateway-token-ref-env --gateway-password --remote-url --remote-token --remote-password --tailscale --install-daemon --no-install-daemon --skip-daemon --daemon-runtime --skip-channels --skip-skills --skip-bootstrap --skip-search --skip-health --skip-ui --suppress-gateway-token-output --skip-hooks --node-manager --import-from --import-source --import-secrets --json"
            value_options="--container --profile --log-level --workspace --agent-name --reset-scope --flow --mode --auth-choice --token-provider --token --token-profile-id --token-expires-in --secret-input-mode --cloudflare-ai-gateway-account-id --cloudflare-ai-gateway-gateway-id --alibaba-model-studio-api-key --anthropic-api-key --clawrouter-api-key --fal-api-key --github-copilot-token --gemini-api-key --huggingface-api-key --kie-api-key --litellm-api-key --lmstudio-api-key --minimax-api-key --nvidia-api-key --ollama-cloud-api-key --openai-api-key --opencode-go-api-key --openrouter-api-key --runway-api-key --together-api-key --xai-api-key --deepseek-api-key --fireworks-api-key --groq-api-key --llama-server-api-key --moonshot-api-key --modelstudio-standard-api-key-cn --modelstudio-standard-api-key --modelstudio-api-key-cn --modelstudio-api-key --qwen-token-plan-api-key --qwen-token-plan-api-key-cn --arceeai-api-key --baseten-api-key --byteplus-api-key --cerebras-api-key --chutes-api-key --cohere-api-key --cloudflare-ai-gateway-api-key --comfy-api-key --deepinfra-api-key --featherless-api-key --gmi-api-key --longcat-api-key --meta-api-key --mistral-api-key --novita-api-key --opencode-zen-api-key --kilocode-api-key --kimi-code-api-key --pixverse-api-key --qianfan-api-key --radius-api-key --tokenhub-api-key --tokenplan-api-key --telnyx-api-key --venice-api-key --ai-gateway-api-key --vydra-api-key --xiaomi-api-key --xiaomi-token-plan-api-key --zai-api-key --synthetic-api-key --volcengine-api-key --stepfun-api-key --custom-base-url --custom-api-key --custom-model-id --custom-provider-id --custom-compatibility --gateway-port --gateway-bind --gateway-auth --gateway-token --gateway-token-ref-env --gateway-password --remote-url --remote-token --remote-password --tailscale --daemon-runtime --node-manager --import-from --import-source"
            required_value_options="--container --profile --log-level --workspace --agent-name --reset-scope --flow --mode --auth-choice --token-provider --token --token-profile-id --token-expires-in --secret-input-mode --cloudflare-ai-gateway-account-id --cloudflare-ai-gateway-gateway-id --alibaba-model-studio-api-key --anthropic-api-key --clawrouter-api-key --fal-api-key --github-copilot-token --gemini-api-key --huggingface-api-key --kie-api-key --litellm-api-key --lmstudio-api-key --minimax-api-key --nvidia-api-key --ollama-cloud-api-key --openai-api-key --opencode-go-api-key --openrouter-api-key --runway-api-key --together-api-key --xai-api-key --deepseek-api-key --fireworks-api-key --groq-api-key --llama-server-api-key --moonshot-api-key --modelstudio-standard-api-key-cn --modelstudio-standard-api-key --modelstudio-api-key-cn --modelstudio-api-key --qwen-token-plan-api-key --qwen-token-plan-api-key-cn --arceeai-api-key --baseten-api-key --byteplus-api-key --cerebras-api-key --chutes-api-key --cohere-api-key --cloudflare-ai-gateway-api-key --comfy-api-key --deepinfra-api-key --featherless-api-key --gmi-api-key --longcat-api-key --meta-api-key --mistral-api-key --novita-api-key --opencode-zen-api-key --kilocode-api-key --kimi-code-api-key --pixverse-api-key --qianfan-api-key --radius-api-key --tokenhub-api-key --tokenplan-api-key --telnyx-api-key --venice-api-key --ai-gateway-api-key --vydra-api-key --xiaomi-api-key --xiaomi-token-plan-api-key --zai-api-key --synthetic-api-key --volcengine-api-key --stepfun-api-key --custom-base-url --custom-api-key --custom-model-id --custom-provider-id --custom-compatibility --gateway-port --gateway-bind --gateway-auth --gateway-token --gateway-token-ref-env --gateway-password --remote-url --remote-token --remote-password --tailscale --daemon-runtime --node-manager --import-from --import-source"
            ;;
          "onboard recommendations")
            command_path="${candidate_path}"
            opts="acknowledge refresh --agent --json"
            value_options="--container --profile --log-level --workspace --agent-name --reset-scope --flow --mode --auth-choice --token-provider --token --token-profile-id --token-expires-in --secret-input-mode --cloudflare-ai-gateway-account-id --cloudflare-ai-gateway-gateway-id --alibaba-model-studio-api-key --anthropic-api-key --clawrouter-api-key --fal-api-key --github-copilot-token --gemini-api-key --huggingface-api-key --kie-api-key --litellm-api-key --lmstudio-api-key --minimax-api-key --nvidia-api-key --ollama-cloud-api-key --openai-api-key --opencode-go-api-key --openrouter-api-key --runway-api-key --together-api-key --xai-api-key --deepseek-api-key --fireworks-api-key --groq-api-key --llama-server-api-key --moonshot-api-key --modelstudio-standard-api-key-cn --modelstudio-standard-api-key --modelstudio-api-key-cn --modelstudio-api-key --qwen-token-plan-api-key --qwen-token-plan-api-key-cn --arceeai-api-key --baseten-api-key --byteplus-api-key --cerebras-api-key --chutes-api-key --cohere-api-key --cloudflare-ai-gateway-api-key --comfy-api-key --deepinfra-api-key --featherless-api-key --gmi-api-key --longcat-api-key --meta-api-key --mistral-api-key --novita-api-key --opencode-zen-api-key --kilocode-api-key --kimi-code-api-key --pixverse-api-key --qianfan-api-key --radius-api-key --tokenhub-api-key --tokenplan-api-key --telnyx-api-key --venice-api-key --ai-gateway-api-key --vydra-api-key --xiaomi-api-key --xiaomi-token-plan-api-key --zai-api-key --synthetic-api-key --volcengine-api-key --stepfun-api-key --custom-base-url --custom-api-key --custom-model-id --custom-provider-id --custom-compatibility --gateway-port --gateway-bind --gateway-auth --gateway-token --gateway-token-ref-env --gateway-password --remote-url --remote-token --remote-password --tailscale --daemon-runtime --node-manager --import-from --import-source --agent"
            required_value_options="--container --profile --log-level --workspace --agent-name --reset-scope --flow --mode --auth-choice --token-provider --token --token-profile-id --token-expires-in --secret-input-mode --cloudflare-ai-gateway-account-id --cloudflare-ai-gateway-gateway-id --alibaba-model-studio-api-key --anthropic-api-key --clawrouter-api-key --fal-api-key --github-copilot-token --gemini-api-key --huggingface-api-key --kie-api-key --litellm-api-key --lmstudio-api-key --minimax-api-key --nvidia-api-key --ollama-cloud-api-key --openai-api-key --opencode-go-api-key --openrouter-api-key --runway-api-key --together-api-key --xai-api-key --deepseek-api-key --fireworks-api-key --groq-api-key --llama-server-api-key --moonshot-api-key --modelstudio-standard-api-key-cn --modelstudio-standard-api-key --modelstudio-api-key-cn --modelstudio-api-key --qwen-token-plan-api-key --qwen-token-plan-api-key-cn --arceeai-api-key --baseten-api-key --byteplus-api-key --cerebras-api-key --chutes-api-key --cohere-api-key --cloudflare-ai-gateway-api-key --comfy-api-key --deepinfra-api-key --featherless-api-key --gmi-api-key --longcat-api-key --meta-api-key --mistral-api-key --novita-api-key --opencode-zen-api-key --kilocode-api-key --kimi-code-api-key --pixverse-api-key --qianfan-api-key --radius-api-key --tokenhub-api-key --tokenplan-api-key --telnyx-api-key --venice-api-key --ai-gateway-api-key --vydra-api-key --xiaomi-api-key --xiaomi-token-plan-api-key --zai-api-key --synthetic-api-key --volcengine-api-key --stepfun-api-key --custom-base-url --custom-api-key --custom-model-id --custom-provider-id --custom-compatibility --gateway-port --gateway-bind --gateway-auth --gateway-token --gateway-token-ref-env --gateway-password --remote-url --remote-token --remote-password --tailscale --daemon-runtime --node-manager --import-from --import-source --agent"
            ;;
          "onboard recommendations acknowledge")
            command_path="${candidate_path}"
            opts="--agent --retry"
            value_options="--container --profile --log-level --workspace --agent-name --reset-scope --flow --mode --auth-choice --token-provider --token --token-profile-id --token-expires-in --secret-input-mode --cloudflare-ai-gateway-account-id --cloudflare-ai-gateway-gateway-id --alibaba-model-studio-api-key --anthropic-api-key --clawrouter-api-key --fal-api-key --github-copilot-token --gemini-api-key --huggingface-api-key --kie-api-key --litellm-api-key --lmstudio-api-key --minimax-api-key --nvidia-api-key --ollama-cloud-api-key --openai-api-key --opencode-go-api-key --openrouter-api-key --runway-api-key --together-api-key --xai-api-key --deepseek-api-key --fireworks-api-key --groq-api-key --llama-server-api-key --moonshot-api-key --modelstudio-standard-api-key-cn --modelstudio-standard-api-key --modelstudio-api-key-cn --modelstudio-api-key --qwen-token-plan-api-key --qwen-token-plan-api-key-cn --arceeai-api-key --baseten-api-key --byteplus-api-key --cerebras-api-key --chutes-api-key --cohere-api-key --cloudflare-ai-gateway-api-key --comfy-api-key --deepinfra-api-key --featherless-api-key --gmi-api-key --longcat-api-key --meta-api-key --mistral-api-key --novita-api-key --opencode-zen-api-key --kilocode-api-key --kimi-code-api-key --pixverse-api-key --qianfan-api-key --radius-api-key --tokenhub-api-key --tokenplan-api-key --telnyx-api-key --venice-api-key --ai-gateway-api-key --vydra-api-key --xiaomi-api-key --xiaomi-token-plan-api-key --zai-api-key --synthetic-api-key --volcengine-api-key --stepfun-api-key --custom-base-url --custom-api-key --custom-model-id --custom-provider-id --custom-compatibility --gateway-port --gateway-bind --gateway-auth --gateway-token --gateway-token-ref-env --gateway-password --remote-url --remote-token --remote-password --tailscale --daemon-runtime --node-manager --import-from --import-source --agent --retry"
            required_value_options="--container --profile --log-level --workspace --agent-name --reset-scope --flow --mode --auth-choice --token-provider --token --token-profile-id --token-expires-in --secret-input-mode --cloudflare-ai-gateway-account-id --cloudflare-ai-gateway-gateway-id --alibaba-model-studio-api-key --anthropic-api-key --clawrouter-api-key --fal-api-key --github-copilot-token --gemini-api-key --huggingface-api-key --kie-api-key --litellm-api-key --lmstudio-api-key --minimax-api-key --nvidia-api-key --ollama-cloud-api-key --openai-api-key --opencode-go-api-key --openrouter-api-key --runway-api-key --together-api-key --xai-api-key --deepseek-api-key --fireworks-api-key --groq-api-key --llama-server-api-key --moonshot-api-key --modelstudio-standard-api-key-cn --modelstudio-standard-api-key --modelstudio-api-key-cn --modelstudio-api-key --qwen-token-plan-api-key --qwen-token-plan-api-key-cn --arceeai-api-key --baseten-api-key --byteplus-api-key --cerebras-api-key --chutes-api-key --cohere-api-key --cloudflare-ai-gateway-api-key --comfy-api-key --deepinfra-api-key --featherless-api-key --gmi-api-key --longcat-api-key --meta-api-key --mistral-api-key --novita-api-key --opencode-zen-api-key --kilocode-api-key --kimi-code-api-key --pixverse-api-key --qianfan-api-key --radius-api-key --tokenhub-api-key --tokenplan-api-key --telnyx-api-key --venice-api-key --ai-gateway-api-key --vydra-api-key --xiaomi-api-key --xiaomi-token-plan-api-key --zai-api-key --synthetic-api-key --volcengine-api-key --stepfun-api-key --custom-base-url --custom-api-key --custom-model-id --custom-provider-id --custom-compatibility --gateway-port --gateway-bind --gateway-auth --gateway-token --gateway-token-ref-env --gateway-password --remote-url --remote-token --remote-password --tailscale --daemon-runtime --node-manager --import-from --import-source --agent --retry"
            ;;
          "onboard recommendations refresh")
            command_path="${candidate_path}"
            opts="--agent"
            value_options="--container --profile --log-level --workspace --agent-name --reset-scope --flow --mode --auth-choice --token-provider --token --token-profile-id --token-expires-in --secret-input-mode --cloudflare-ai-gateway-account-id --cloudflare-ai-gateway-gateway-id --alibaba-model-studio-api-key --anthropic-api-key --clawrouter-api-key --fal-api-key --github-copilot-token --gemini-api-key --huggingface-api-key --kie-api-key --litellm-api-key --lmstudio-api-key --minimax-api-key --nvidia-api-key --ollama-cloud-api-key --openai-api-key --opencode-go-api-key --openrouter-api-key --runway-api-key --together-api-key --xai-api-key --deepseek-api-key --fireworks-api-key --groq-api-key --llama-server-api-key --moonshot-api-key --modelstudio-standard-api-key-cn --modelstudio-standard-api-key --modelstudio-api-key-cn --modelstudio-api-key --qwen-token-plan-api-key --qwen-token-plan-api-key-cn --arceeai-api-key --baseten-api-key --byteplus-api-key --cerebras-api-key --chutes-api-key --cohere-api-key --cloudflare-ai-gateway-api-key --comfy-api-key --deepinfra-api-key --featherless-api-key --gmi-api-key --longcat-api-key --meta-api-key --mistral-api-key --novita-api-key --opencode-zen-api-key --kilocode-api-key --kimi-code-api-key --pixverse-api-key --qianfan-api-key --radius-api-key --tokenhub-api-key --tokenplan-api-key --telnyx-api-key --venice-api-key --ai-gateway-api-key --vydra-api-key --xiaomi-api-key --xiaomi-token-plan-api-key --zai-api-key --synthetic-api-key --volcengine-api-key --stepfun-api-key --custom-base-url --custom-api-key --custom-model-id --custom-provider-id --custom-compatibility --gateway-port --gateway-bind --gateway-auth --gateway-token --gateway-token-ref-env --gateway-password --remote-url --remote-token --remote-password --tailscale --daemon-runtime --node-manager --import-from --import-source --agent"
            required_value_options="--container --profile --log-level --workspace --agent-name --reset-scope --flow --mode --auth-choice --token-provider --token --token-profile-id --token-expires-in --secret-input-mode --cloudflare-ai-gateway-account-id --cloudflare-ai-gateway-gateway-id --alibaba-model-studio-api-key --anthropic-api-key --clawrouter-api-key --fal-api-key --github-copilot-token --gemini-api-key --huggingface-api-key --kie-api-key --litellm-api-key --lmstudio-api-key --minimax-api-key --nvidia-api-key --ollama-cloud-api-key --openai-api-key --opencode-go-api-key --openrouter-api-key --runway-api-key --together-api-key --xai-api-key --deepseek-api-key --fireworks-api-key --groq-api-key --llama-server-api-key --moonshot-api-key --modelstudio-standard-api-key-cn --modelstudio-standard-api-key --modelstudio-api-key-cn --modelstudio-api-key --qwen-token-plan-api-key --qwen-token-plan-api-key-cn --arceeai-api-key --baseten-api-key --byteplus-api-key --cerebras-api-key --chutes-api-key --cohere-api-key --cloudflare-ai-gateway-api-key --comfy-api-key --deepinfra-api-key --featherless-api-key --gmi-api-key --longcat-api-key --meta-api-key --mistral-api-key --novita-api-key --opencode-zen-api-key --kilocode-api-key --kimi-code-api-key --pixverse-api-key --qianfan-api-key --radius-api-key --tokenhub-api-key --tokenplan-api-key --telnyx-api-key --venice-api-key --ai-gateway-api-key --vydra-api-key --xiaomi-api-key --xiaomi-token-plan-api-key --zai-api-key --synthetic-api-key --volcengine-api-key --stepfun-api-key --custom-base-url --custom-api-key --custom-model-id --custom-provider-id --custom-compatibility --gateway-port --gateway-bind --gateway-auth --gateway-token --gateway-token-ref-env --gateway-password --remote-url --remote-token --remote-password --tailscale --daemon-runtime --node-manager --import-from --import-source --agent"
            ;;
          "configure")
            command_path="${candidate_path}"
            opts="--section"
            value_options="--container --profile --log-level --section"
            required_value_options="--container --profile --log-level --section"
            ;;
          "config")
            command_path="${candidate_path}"
            opts="file get patch schema set unset validate --section"
            value_options="--container --profile --log-level --section"
            required_value_options="--container --profile --log-level --section"
            ;;
          "config get")
            command_path="${candidate_path}"
            opts="--json"
            value_options="--container --profile --log-level --section"
            required_value_options="--container --profile --log-level --section"
            ;;
          "config set")
            command_path="${candidate_path}"
            opts="--strict-json --json --expect-current-absent --expect-current-json --dry-run --allow-exec --merge --replace --ref-provider --ref-source --ref-id --provider-source --provider-allowlist --provider-path --provider-mode --provider-timeout-ms --provider-max-bytes --provider-command --provider-arg --provider-no-output-timeout-ms --provider-max-output-bytes --provider-json-only --provider-env --provider-pass-env --provider-trusted-dir --batch-json --batch-file"
            value_options="--container --profile --log-level --section --expect-current-json --ref-provider --ref-source --ref-id --provider-source --provider-allowlist --provider-path --provider-mode --provider-timeout-ms --provider-max-bytes --provider-command --provider-arg --provider-no-output-timeout-ms --provider-max-output-bytes --provider-env --provider-pass-env --provider-trusted-dir --batch-json --batch-file"
            required_value_options="--container --profile --log-level --section --expect-current-json --ref-provider --ref-source --ref-id --provider-source --provider-allowlist --provider-path --provider-mode --provider-timeout-ms --provider-max-bytes --provider-command --provider-arg --provider-no-output-timeout-ms --provider-max-output-bytes --provider-env --provider-pass-env --provider-trusted-dir --batch-json --batch-file"
            ;;
          "config patch")
            command_path="${candidate_path}"
            opts="--file --stdin --dry-run --allow-exec --json --replace-path"
            value_options="--container --profile --log-level --section --file --replace-path"
            required_value_options="--container --profile --log-level --section --file --replace-path"
            ;;
          "config unset")
            command_path="${candidate_path}"
            opts="--dry-run --allow-exec --json"
            value_options="--container --profile --log-level --section"
            required_value_options="--container --profile --log-level --section"
            ;;
          "config file")
            command_path="${candidate_path}"
            opts="--json"
            value_options="--container --profile --log-level --section"
            required_value_options="--container --profile --log-level --section"
            ;;
          "config schema")
            command_path="${candidate_path}"
            opts="--json"
            value_options="--container --profile --log-level --section"
            required_value_options="--container --profile --log-level --section"
            ;;
          "config validate")
            command_path="${candidate_path}"
            opts="--json"
            value_options="--container --profile --log-level --section"
            required_value_options="--container --profile --log-level --section"
            ;;
          "backup")
            command_path="${candidate_path}"
            opts="create disable enable git list record restore sqlite verify"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "backup create")
            command_path="${candidate_path}"
            opts="--output --to --claim-namespace --namespace --keep-daily --keep-weekly --keep-monthly --json --dry-run --verify --only-config --no-include-workspace"
            value_options="--container --profile --log-level --output --to --namespace --keep-daily --keep-weekly --keep-monthly"
            required_value_options="--container --profile --log-level --output --to --namespace --keep-daily --keep-weekly --keep-monthly"
            ;;
          "backup verify")
            command_path="${candidate_path}"
            opts="--from --namespace --json"
            value_options="--container --profile --log-level --from --namespace"
            required_value_options="--container --profile --log-level --from --namespace"
            ;;
          "backup restore")
            command_path="${candidate_path}"
            opts="--from --namespace --target --json"
            value_options="--container --profile --log-level --from --namespace --target"
            required_value_options="--container --profile --log-level --from --namespace --target"
            ;;
          "backup list")
            command_path="${candidate_path}"
            opts="--from --namespace --json"
            value_options="--container --profile --log-level --from --namespace"
            required_value_options="--container --profile --log-level --from --namespace"
            ;;
          "backup record")
            command_path="${candidate_path}"
            opts="--status --target --bytes --error --json"
            value_options="--container --profile --log-level --status --target --bytes --error"
            required_value_options="--container --profile --log-level --status --target --bytes --error"
            ;;
          "backup sqlite")
            command_path="${candidate_path}"
            opts="create list restore verify"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "backup sqlite create")
            command_path="${candidate_path}"
            opts="--global --agent --repository --json"
            value_options="--container --profile --log-level --agent --repository"
            required_value_options="--container --profile --log-level --agent --repository"
            ;;
          "backup sqlite list")
            command_path="${candidate_path}"
            opts="--repository --json"
            value_options="--container --profile --log-level --repository"
            required_value_options="--container --profile --log-level --repository"
            ;;
          "backup sqlite verify")
            command_path="${candidate_path}"
            opts="--scratch --json"
            value_options="--container --profile --log-level --scratch"
            required_value_options="--container --profile --log-level --scratch"
            ;;
          "backup sqlite restore")
            command_path="${candidate_path}"
            opts="--target --json"
            value_options="--container --profile --log-level --target"
            required_value_options="--container --profile --log-level --target"
            ;;
          "backup git")
            command_path="${candidate_path}"
            opts="create init log restore verify"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "backup git init")
            command_path="${candidate_path}"
            opts="--repository --remote --json"
            value_options="--container --profile --log-level --repository --remote"
            required_value_options="--container --profile --log-level --repository --remote"
            ;;
          "backup git create")
            command_path="${candidate_path}"
            opts="--repository --all --global --agent --push --exclude-secrets --json"
            value_options="--container --profile --log-level --repository --agent"
            required_value_options="--container --profile --log-level --repository --agent"
            ;;
          "backup git log")
            command_path="${candidate_path}"
            opts="--repository --limit --json"
            value_options="--container --profile --log-level --repository --limit"
            required_value_options="--container --profile --log-level --repository --limit"
            ;;
          "backup git verify")
            command_path="${candidate_path}"
            opts="--repository --ref --global --agent --json"
            value_options="--container --profile --log-level --repository --ref --agent"
            required_value_options="--container --profile --log-level --repository --ref --agent"
            ;;
          "backup git restore")
            command_path="${candidate_path}"
            opts="--repository --target --ref --global --agent --json"
            value_options="--container --profile --log-level --repository --target --ref --agent"
            required_value_options="--container --profile --log-level --repository --target --ref --agent"
            ;;
          "backup enable")
            command_path="${candidate_path}"
            opts="--repository --to --claim-namespace --namespace --no-include-workspace --keep-daily --keep-weekly --keep-monthly --every --push --exclude-secrets --include-secrets --global-only --agent --url --port --token --password --timeout --expect-final"
            value_options="--container --profile --log-level --repository --to --namespace --keep-daily --keep-weekly --keep-monthly --every --agent --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --repository --to --namespace --keep-daily --keep-weekly --keep-monthly --every --agent --url --port --token --password --timeout"
            ;;
          "backup disable")
            command_path="${candidate_path}"
            opts="--offsite --git --url --port --token --password --timeout --expect-final"
            value_options="--container --profile --log-level --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --url --port --token --password --timeout"
            ;;
          "database")
            command_path="${candidate_path}"
            opts="ownership preflight preflight-agent"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "database preflight")
            command_path="${candidate_path}"
            opts="--json"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "database preflight-agent")
            command_path="${candidate_path}"
            opts="--agent-id --json"
            value_options="--container --profile --log-level --agent-id"
            required_value_options="--container --profile --log-level --agent-id"
            ;;
          "database ownership")
            command_path="${candidate_path}"
            opts="claim status"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "database ownership status")
            command_path="${candidate_path}"
            opts="--json"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "database ownership claim")
            command_path="${candidate_path}"
            opts="--manager --json"
            value_options="--container --profile --log-level --manager"
            required_value_options="--container --profile --log-level --manager"
            ;;
          "migrate")
            command_path="${candidate_path}"
            opts="apply list plan --from --agent --include-secrets --no-auth-credentials --overwrite --dry-run --yes --skill --plugin --item --backup-output --no-backup --force --json --verify-plugin-apps"
            value_options="--container --profile --log-level --from --agent --skill --plugin --item --backup-output"
            required_value_options="--container --profile --log-level --from --agent --skill --plugin --item --backup-output"
            ;;
          "migrate list")
            command_path="${candidate_path}"
            opts="--json"
            value_options="--container --profile --log-level --from --agent --skill --plugin --item --backup-output"
            required_value_options="--container --profile --log-level --from --agent --skill --plugin --item --backup-output"
            ;;
          "migrate plan")
            command_path="${candidate_path}"
            opts="--from --agent --include-secrets --no-auth-credentials --overwrite --json --skill --plugin --item --verify-plugin-apps"
            value_options="--container --profile --log-level --backup-output --from --agent --skill --plugin --item"
            required_value_options="--container --profile --log-level --backup-output --from --agent --skill --plugin --item"
            ;;
          "migrate apply")
            command_path="${candidate_path}"
            opts="--from --agent --include-secrets --no-auth-credentials --overwrite --json --skill --plugin --item --verify-plugin-apps --yes --backup-output --no-backup --force"
            value_options="--container --profile --log-level --from --agent --skill --plugin --item --backup-output"
            required_value_options="--container --profile --log-level --from --agent --skill --plugin --item --backup-output"
            ;;
          "storage")
            command_path="${candidate_path}"
            opts="init list test --json"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "storage list")
            command_path="${candidate_path}"
            opts="--json"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "storage init")
            command_path="${candidate_path}"
            opts="--json"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "storage test")
            command_path="${candidate_path}"
            opts="--json"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "doctor")
            command_path="${candidate_path}"
            opts="--no-workspace-suggestions --yes --repair --fix --force --non-interactive --generate-gateway-token --allow-exec --deep --lint --post-upgrade --session-sqlite --state-sqlite --session-sqlite-store --session-sqlite-agent --session-sqlite-all-agents --github-issue --json --severity-min --all --skip --only"
            value_options="--container --profile --log-level --session-sqlite --state-sqlite --session-sqlite-store --session-sqlite-agent --severity-min --skip --only"
            required_value_options="--container --profile --log-level --session-sqlite --state-sqlite --session-sqlite-store --session-sqlite-agent --severity-min --skip --only"
            ;;
          "triage")
            command_path="${candidate_path}"
            opts="--json --no-export --agent --run --non-interactive --update-result"
            value_options="--container --profile --log-level --agent --update-result"
            required_value_options="--container --profile --log-level --agent --update-result"
            ;;
          "dashboard")
            command_path="${candidate_path}"
            opts="--no-open --json --yes"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "reset")
            command_path="${candidate_path}"
            opts="--scope --yes --non-interactive --dry-run"
            value_options="--container --profile --log-level --scope"
            required_value_options="--container --profile --log-level --scope"
            ;;
          "uninstall")
            command_path="${candidate_path}"
            opts="--service --state --workspace --app --all --yes --non-interactive --dry-run"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "message")
            command_path="${candidate_path}"
            opts="ban broadcast channel delete edit emoji event kick member permissions pin pins poll react reactions read role search send sticker thread timeout unpin voice"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "message send")
            command_path="${candidate_path}"
            opts="-m --message -t --target --media --presentation --delivery --pin --reply-to --thread-id --gif-playback --force-document --silent --channel --account --json --dry-run --verbose"
            value_options="--container --profile --log-level -m --message -t --target --media --presentation --delivery --reply-to --thread-id --channel --account"
            required_value_options="--container --profile --log-level -m --message -t --target --media --presentation --delivery --reply-to --thread-id --channel --account"
            ;;
          "message broadcast")
            command_path="${candidate_path}"
            opts="--channel --account --json --dry-run --verbose --targets --message --media"
            value_options="--container --profile --log-level --channel --account --targets --message --media"
            required_value_options="--container --profile --log-level --channel --account --targets --message --media"
            ;;
          "message poll")
            command_path="${candidate_path}"
            opts="-t --target --channel --account --json --dry-run --verbose --poll-question --poll-option --poll-multi --poll-duration-hours --poll-duration-seconds --poll-anonymous --poll-public -m --message --silent --thread-id"
            value_options="--container --profile --log-level -t --target --channel --account --poll-question --poll-option --poll-duration-hours --poll-duration-seconds -m --message --thread-id"
            required_value_options="--container --profile --log-level -t --target --channel --account --poll-question --poll-option --poll-duration-hours --poll-duration-seconds -m --message --thread-id"
            ;;
          "message react")
            command_path="${candidate_path}"
            opts="-t --target --channel --account --json --dry-run --verbose --message-id --emoji --remove --participant --from-me --target-author --target-author-uuid"
            value_options="--container --profile --log-level -t --target --channel --account --message-id --emoji --participant --target-author --target-author-uuid"
            required_value_options="--container --profile --log-level -t --target --channel --account --message-id --emoji --participant --target-author --target-author-uuid"
            ;;
          "message reactions")
            command_path="${candidate_path}"
            opts="-t --target --channel --account --json --dry-run --verbose --message-id --limit"
            value_options="--container --profile --log-level -t --target --channel --account --message-id --limit"
            required_value_options="--container --profile --log-level -t --target --channel --account --message-id --limit"
            ;;
          "message read")
            command_path="${candidate_path}"
            opts="-t --target --channel --account --json --dry-run --verbose --limit --message-id --before --after --around --thread-id"
            value_options="--container --profile --log-level -t --target --channel --account --limit --message-id --before --after --around --thread-id"
            required_value_options="--container --profile --log-level -t --target --channel --account --limit --message-id --before --after --around --thread-id"
            ;;
          "message edit")
            command_path="${candidate_path}"
            opts="--message-id -m --message -t --target --channel --account --json --dry-run --verbose --thread-id"
            value_options="--container --profile --log-level --message-id -m --message -t --target --channel --account --thread-id"
            required_value_options="--container --profile --log-level --message-id -m --message -t --target --channel --account --thread-id"
            ;;
          "message delete")
            command_path="${candidate_path}"
            opts="--message-id -t --target --channel --account --json --dry-run --verbose"
            value_options="--container --profile --log-level --message-id -t --target --channel --account"
            required_value_options="--container --profile --log-level --message-id -t --target --channel --account"
            ;;
          "message pin")
            command_path="${candidate_path}"
            opts="-t --target --channel --account --json --dry-run --verbose --message-id"
            value_options="--container --profile --log-level -t --target --channel --account --message-id"
            required_value_options="--container --profile --log-level -t --target --channel --account --message-id"
            ;;
          "message unpin")
            command_path="${candidate_path}"
            opts="-t --target --channel --account --json --dry-run --verbose --message-id --pinned-message-id"
            value_options="--container --profile --log-level -t --target --channel --account --message-id --pinned-message-id"
            required_value_options="--container --profile --log-level -t --target --channel --account --message-id --pinned-message-id"
            ;;
          "message pins")
            command_path="${candidate_path}"
            opts="-t --target --channel --account --json --dry-run --verbose --limit"
            value_options="--container --profile --log-level -t --target --channel --account --limit"
            required_value_options="--container --profile --log-level -t --target --channel --account --limit"
            ;;
          "message permissions")
            command_path="${candidate_path}"
            opts="-t --target --channel --account --json --dry-run --verbose"
            value_options="--container --profile --log-level -t --target --channel --account"
            required_value_options="--container --profile --log-level -t --target --channel --account"
            ;;
          "message search")
            command_path="${candidate_path}"
            opts="--channel --account --json --dry-run --verbose --query --guild-id --channel-id --channel-ids --author-id --author-ids --limit"
            value_options="--container --profile --log-level --channel --account --query --guild-id --channel-id --channel-ids --author-id --author-ids --limit"
            required_value_options="--container --profile --log-level --channel --account --query --guild-id --channel-id --channel-ids --author-id --author-ids --limit"
            ;;
          "message thread")
            command_path="${candidate_path}"
            opts="create list reply"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "message thread create")
            command_path="${candidate_path}"
            opts="--thread-name -t --target --channel --account --json --dry-run --verbose --message-id -m --message --auto-archive-min"
            value_options="--container --profile --log-level --thread-name -t --target --channel --account --message-id -m --message --auto-archive-min"
            required_value_options="--container --profile --log-level --thread-name -t --target --channel --account --message-id -m --message --auto-archive-min"
            ;;
          "message thread list")
            command_path="${candidate_path}"
            opts="--guild-id --channel --account --json --dry-run --verbose --channel-id --include-archived --before --limit"
            value_options="--container --profile --log-level --guild-id --channel --account --channel-id --before --limit"
            required_value_options="--container --profile --log-level --guild-id --channel --account --channel-id --before --limit"
            ;;
          "message thread reply")
            command_path="${candidate_path}"
            opts="-m --message -t --target --channel --account --json --dry-run --verbose --media --reply-to"
            value_options="--container --profile --log-level -m --message -t --target --channel --account --media --reply-to"
            required_value_options="--container --profile --log-level -m --message -t --target --channel --account --media --reply-to"
            ;;
          "message emoji")
            command_path="${candidate_path}"
            opts="list upload"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "message emoji list")
            command_path="${candidate_path}"
            opts="--channel --account --json --dry-run --verbose --guild-id"
            value_options="--container --profile --log-level --channel --account --guild-id"
            required_value_options="--container --profile --log-level --channel --account --guild-id"
            ;;
          "message emoji upload")
            command_path="${candidate_path}"
            opts="--guild-id --channel --account --json --dry-run --verbose --emoji-name --media --role-ids"
            value_options="--container --profile --log-level --guild-id --channel --account --emoji-name --media --role-ids"
            required_value_options="--container --profile --log-level --guild-id --channel --account --emoji-name --media --role-ids"
            ;;
          "message sticker")
            command_path="${candidate_path}"
            opts="send upload"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "message sticker send")
            command_path="${candidate_path}"
            opts="-t --target --channel --account --json --dry-run --verbose --sticker-id -m --message"
            value_options="--container --profile --log-level -t --target --channel --account --sticker-id -m --message"
            required_value_options="--container --profile --log-level -t --target --channel --account --sticker-id -m --message"
            ;;
          "message sticker upload")
            command_path="${candidate_path}"
            opts="--guild-id --channel --account --json --dry-run --verbose --sticker-name --sticker-desc --sticker-tags --media"
            value_options="--container --profile --log-level --guild-id --channel --account --sticker-name --sticker-desc --sticker-tags --media"
            required_value_options="--container --profile --log-level --guild-id --channel --account --sticker-name --sticker-desc --sticker-tags --media"
            ;;
          "message role")
            command_path="${candidate_path}"
            opts="add info remove"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "message role info")
            command_path="${candidate_path}"
            opts="--guild-id --channel --account --json --dry-run --verbose"
            value_options="--container --profile --log-level --guild-id --channel --account"
            required_value_options="--container --profile --log-level --guild-id --channel --account"
            ;;
          "message role add")
            command_path="${candidate_path}"
            opts="--guild-id --user-id --role-id --channel --account --json --dry-run --verbose"
            value_options="--container --profile --log-level --guild-id --user-id --role-id --channel --account"
            required_value_options="--container --profile --log-level --guild-id --user-id --role-id --channel --account"
            ;;
          "message role remove")
            command_path="${candidate_path}"
            opts="--guild-id --user-id --role-id --channel --account --json --dry-run --verbose"
            value_options="--container --profile --log-level --guild-id --user-id --role-id --channel --account"
            required_value_options="--container --profile --log-level --guild-id --user-id --role-id --channel --account"
            ;;
          "message channel")
            command_path="${candidate_path}"
            opts="info list"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "message channel info")
            command_path="${candidate_path}"
            opts="-t --target --channel --account --json --dry-run --verbose"
            value_options="--container --profile --log-level -t --target --channel --account"
            required_value_options="--container --profile --log-level -t --target --channel --account"
            ;;
          "message channel list")
            command_path="${candidate_path}"
            opts="--guild-id --channel --account --json --dry-run --verbose"
            value_options="--container --profile --log-level --guild-id --channel --account"
            required_value_options="--container --profile --log-level --guild-id --channel --account"
            ;;
          "message member")
            command_path="${candidate_path}"
            opts="info"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "message member info")
            command_path="${candidate_path}"
            opts="--user-id --channel --account --json --dry-run --verbose --guild-id --channel-id"
            value_options="--container --profile --log-level --user-id --channel --account --guild-id --channel-id"
            required_value_options="--container --profile --log-level --user-id --channel --account --guild-id --channel-id"
            ;;
          "message voice")
            command_path="${candidate_path}"
            opts="status"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "message voice status")
            command_path="${candidate_path}"
            opts="--guild-id --user-id --channel --account --json --dry-run --verbose"
            value_options="--container --profile --log-level --guild-id --user-id --channel --account"
            required_value_options="--container --profile --log-level --guild-id --user-id --channel --account"
            ;;
          "message event")
            command_path="${candidate_path}"
            opts="create list"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "message event list")
            command_path="${candidate_path}"
            opts="--guild-id --channel --account --json --dry-run --verbose"
            value_options="--container --profile --log-level --guild-id --channel --account"
            required_value_options="--container --profile --log-level --guild-id --channel --account"
            ;;
          "message event create")
            command_path="${candidate_path}"
            opts="--guild-id --event-name --start-time --channel --account --json --dry-run --verbose --end-time --desc --channel-id --location --event-type --image"
            value_options="--container --profile --log-level --guild-id --event-name --start-time --channel --account --end-time --desc --channel-id --location --event-type --image"
            required_value_options="--container --profile --log-level --guild-id --event-name --start-time --channel --account --end-time --desc --channel-id --location --event-type --image"
            ;;
          "message timeout")
            command_path="${candidate_path}"
            opts="--guild-id --user-id --channel --account --json --dry-run --verbose --duration-min --until --reason"
            value_options="--container --profile --log-level --guild-id --user-id --channel --account --duration-min --until --reason"
            required_value_options="--container --profile --log-level --guild-id --user-id --channel --account --duration-min --until --reason"
            ;;
          "message kick")
            command_path="${candidate_path}"
            opts="--guild-id --user-id --channel --account --json --dry-run --verbose --reason"
            value_options="--container --profile --log-level --guild-id --user-id --channel --account --reason"
            required_value_options="--container --profile --log-level --guild-id --user-id --channel --account --reason"
            ;;
          "message ban")
            command_path="${candidate_path}"
            opts="--guild-id --user-id --channel --account --json --dry-run --verbose --reason --delete-days"
            value_options="--container --profile --log-level --guild-id --user-id --channel --account --reason --delete-days"
            required_value_options="--container --profile --log-level --guild-id --user-id --channel --account --reason --delete-days"
            ;;
          "mcp")
            command_path="${candidate_path}"
            opts="add configure doctor list login logout probe reload serve set show status tools unset"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "mcp serve")
            command_path="${candidate_path}"
            opts="--url --token --token-file --password --password-file --claude-channel-mode -v --verbose"
            value_options="--container --profile --log-level --url --token --token-file --password --password-file --claude-channel-mode"
            required_value_options="--container --profile --log-level --url --token --token-file --password --password-file --claude-channel-mode"
            ;;
          "mcp list")
            command_path="${candidate_path}"
            opts="--json"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "mcp show")
            command_path="${candidate_path}"
            opts="--json"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "mcp status")
            command_path="${candidate_path}"
            opts="-v --verbose --json"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "mcp probe")
            command_path="${candidate_path}"
            opts="--json"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "mcp doctor")
            command_path="${candidate_path}"
            opts="--probe --json"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "mcp add")
            command_path="${candidate_path}"
            opts="--command --arg --env --cwd --url --transport --header --auth --oauth-scope --oauth-redirect-url --oauth-client-metadata-url --include --exclude --timeout --connect-timeout --parallel --approval --disabled --ssl-verify --client-cert --client-key --no-probe"
            value_options="--container --profile --log-level --command --arg --env --cwd --url --transport --header --auth --oauth-scope --oauth-redirect-url --oauth-client-metadata-url --include --exclude --timeout --connect-timeout --approval --ssl-verify --client-cert --client-key"
            required_value_options="--container --profile --log-level --command --arg --env --cwd --url --transport --header --auth --oauth-scope --oauth-redirect-url --oauth-client-metadata-url --include --exclude --timeout --connect-timeout --approval --ssl-verify --client-cert --client-key"
            ;;
          "mcp set")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "mcp tools")
            command_path="${candidate_path}"
            opts="--include --exclude --clear"
            value_options="--container --profile --log-level --include --exclude"
            required_value_options="--container --profile --log-level --include --exclude"
            ;;
          "mcp configure")
            command_path="${candidate_path}"
            opts="--enable --disable --include --exclude --clear-tools --timeout --connect-timeout --clear-timeouts --parallel --no-parallel --approval --auth --clear-auth --oauth-scope --oauth-redirect-url --oauth-client-metadata-url --ssl-verify --client-cert --client-key --clear-tls --probe"
            value_options="--container --profile --log-level --include --exclude --timeout --connect-timeout --approval --auth --oauth-scope --oauth-redirect-url --oauth-client-metadata-url --ssl-verify --client-cert --client-key"
            required_value_options="--container --profile --log-level --include --exclude --timeout --connect-timeout --approval --auth --oauth-scope --oauth-redirect-url --oauth-client-metadata-url --ssl-verify --client-cert --client-key"
            ;;
          "mcp login")
            command_path="${candidate_path}"
            opts="--code"
            value_options="--container --profile --log-level --code"
            required_value_options="--container --profile --log-level --code"
            ;;
          "mcp logout")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "mcp reload")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "mcp unset")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "transcripts")
            command_path="${candidate_path}"
            opts="list path show"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "transcripts list")
            command_path="${candidate_path}"
            opts="--json"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "transcripts show")
            command_path="${candidate_path}"
            opts="--json"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "transcripts path")
            command_path="${candidate_path}"
            opts="--dir --metadata --transcript --json"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "agent")
            command_path="${candidate_path}"
            opts="exec -m --message --message-file -t --to --session-key --session-id --agent --model --thinking --verbose --channel --reply-to --reply-channel --reply-account --local --deliver --json --timeout"
            value_options="--container --profile --log-level -m --message --message-file -t --to --session-key --session-id --agent --model --thinking --verbose --channel --reply-to --reply-channel --reply-account --timeout"
            required_value_options="--container --profile --log-level -m --message --message-file -t --to --session-key --session-id --agent --model --thinking --verbose --channel --reply-to --reply-channel --reply-account --timeout"
            ;;
          "agent exec")
            command_path="${candidate_path}"
            opts="--message-file --cwd --state-dir --config --isolated --model --code-mode --local-model-lean --thinking --fallback --auth-env-only --no-auth-env-only --timeout --json"
            value_options="--container --profile --log-level -m --message -t --to --session-key --session-id --agent --verbose --channel --reply-to --reply-channel --reply-account --message-file --cwd --state-dir --config --model --code-mode --thinking --fallback --timeout"
            required_value_options="--container --profile --log-level -m --message -t --to --session-key --session-id --agent --verbose --channel --reply-to --reply-channel --reply-account --message-file --cwd --state-dir --config --model --code-mode --thinking --fallback --timeout"
            ;;
          "agents")
            command_path="${candidate_path}"
            opts="add bind bindings delete list set-identity team unbind"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "agents list")
            command_path="${candidate_path}"
            opts="--json --bindings --tree"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "agents bindings")
            command_path="${candidate_path}"
            opts="--agent --json"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "agents bind")
            command_path="${candidate_path}"
            opts="--agent --bind --json"
            value_options="--container --profile --log-level --agent --bind"
            required_value_options="--container --profile --log-level --agent --bind"
            ;;
          "agents unbind")
            command_path="${candidate_path}"
            opts="--agent --bind --all --json"
            value_options="--container --profile --log-level --agent --bind"
            required_value_options="--container --profile --log-level --agent --bind"
            ;;
          "agents add")
            command_path="${candidate_path}"
            opts="--workspace --role --model --agent-dir --bind --non-interactive --json"
            value_options="--container --profile --log-level --workspace --role --model --agent-dir --bind"
            required_value_options="--container --profile --log-level --workspace --role --model --agent-dir --bind"
            ;;
          "agents team")
            command_path="${candidate_path}"
            opts="create"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "agents team create")
            command_path="${candidate_path}"
            opts="--preset --coordinator --prefix --workspace-root --non-interactive --json"
            value_options="--container --profile --log-level --preset --coordinator --prefix --workspace-root"
            required_value_options="--container --profile --log-level --preset --coordinator --prefix --workspace-root"
            ;;
          "agents set-identity")
            command_path="${candidate_path}"
            opts="--agent --workspace --identity-file --from-identity --name --theme --emoji --avatar --json"
            value_options="--container --profile --log-level --agent --workspace --identity-file --name --theme --emoji --avatar"
            required_value_options="--container --profile --log-level --agent --workspace --identity-file --name --theme --emoji --avatar"
            ;;
          "agents delete")
            command_path="${candidate_path}"
            opts="--force --json"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "audit")
            command_path="${candidate_path}"
            opts="--agent --session --run --execution --kind --status --direction --channel --after --before --cursor --limit --explain --json"
            value_options="--container --profile --log-level --agent --session --run --execution --kind --status --direction --channel --after --before --cursor --limit"
            required_value_options="--container --profile --log-level --agent --session --run --execution --kind --status --direction --channel --after --before --cursor --limit"
            ;;
          "status")
            command_path="${candidate_path}"
            opts="--json --all --usage --agent --deep --timeout --verbose --debug"
            value_options="--container --profile --log-level --agent --timeout"
            required_value_options="--container --profile --log-level --agent --timeout"
            ;;
          "health")
            command_path="${candidate_path}"
            opts="--json --timeout --verbose --debug"
            value_options="--container --profile --log-level --timeout"
            required_value_options="--container --profile --log-level --timeout"
            ;;
          "sessions")
            command_path="${candidate_path}"
            opts="archive cleanup compact delete export-trajectory import list tail --json --verbose --store --agent --all-agents --active --limit"
            value_options="--container --profile --log-level --store --agent --active --limit"
            required_value_options="--container --profile --log-level --store --agent --active --limit"
            ;;
          "sessions list")
            command_path="${candidate_path}"
            opts="--json --verbose --store --agent --all-agents --active --limit"
            value_options="--container --profile --log-level --store --agent --active --limit"
            required_value_options="--container --profile --log-level --store --agent --active --limit"
            ;;
          "sessions cleanup")
            command_path="${candidate_path}"
            opts="--store --agent --all-agents --dry-run --enforce --fix-missing --fix-dm-scope --active-key --json"
            value_options="--container --profile --log-level --active --limit --store --agent --active-key"
            required_value_options="--container --profile --log-level --active --limit --store --agent --active-key"
            ;;
          "sessions tail")
            command_path="${candidate_path}"
            opts="--session-key --tail --follow --store --agent --all-agents"
            value_options="--container --profile --log-level --active --limit --session-key --tail --store --agent"
            required_value_options="--container --profile --log-level --active --limit --session-key --tail --store --agent"
            ;;
          "sessions export-trajectory")
            command_path="${candidate_path}"
            opts="--session-key --output --workspace --store --agent --request-json-base64 --json"
            value_options="--container --profile --log-level --active --limit --session-key --output --workspace --store --agent --request-json-base64"
            required_value_options="--container --profile --log-level --active --limit --session-key --output --workspace --store --agent --request-json-base64"
            ;;
          "sessions archive")
            command_path="${candidate_path}"
            opts="--dry-run --agent --url --token --password --timeout --json"
            value_options="--container --profile --log-level --store --active --limit --agent --url --token --password --timeout"
            required_value_options="--container --profile --log-level --store --active --limit --agent --url --token --password --timeout"
            ;;
          "sessions delete")
            command_path="${candidate_path}"
            opts="--dry-run --yes --agent --url --token --password --timeout --json"
            value_options="--container --profile --log-level --store --active --limit --agent --url --token --password --timeout"
            required_value_options="--container --profile --log-level --store --active --limit --agent --url --token --password --timeout"
            ;;
          "sessions import")
            command_path="${candidate_path}"
            opts="--agent --url --token --password --timeout --json --all --catalog --host --source-home --limit --dry-run"
            value_options="--container --profile --log-level --store --active --agent --url --token --password --timeout --catalog --host --source-home --limit"
            required_value_options="--container --profile --log-level --store --active --agent --url --token --password --timeout --catalog --host --source-home --limit"
            ;;
          "sessions compact")
            command_path="${candidate_path}"
            opts="--agent --url --token --password --timeout --json --max-lines"
            value_options="--container --profile --log-level --store --active --limit --agent --url --token --password --timeout --max-lines"
            required_value_options="--container --profile --log-level --store --active --limit --agent --url --token --password --timeout --max-lines"
            ;;
          "acp")
            command_path="${candidate_path}"
            opts="client --url --token --token-file --password --password-file --session --session-label --require-existing --reset-session --no-prefix-cwd --provenance -v --verbose"
            value_options="--container --profile --log-level --url --token --token-file --password --password-file --session --session-label --provenance"
            required_value_options="--container --profile --log-level --url --token --token-file --password --password-file --session --session-label --provenance"
            ;;
          "acp client")
            command_path="${candidate_path}"
            opts="--cwd --server --server-args --server-verbose -v --verbose"
            value_options="--container --profile --log-level --url --token --token-file --password --password-file --session --session-label --provenance --cwd --server --server-args"
            required_value_options="--container --profile --log-level --url --token --token-file --password --password-file --session --session-label --provenance --cwd --server --server-args"
            ;;
          "gateway")
            command_path="${candidate_path}"
            opts="auth-token call diagnostics discover health install probe restart resume run stability start status stop suspend uninstall usage-cost --port --bind --token --auth --password --password-file --tailscale --allow-unconfigured --dev --ambient-channels --dev-ambient-channels --reset --force --verbose --cli-backend-logs --claude-cli-logs --ws-log --compact --raw-stream --raw-stream-path"
            value_options="--container --profile --log-level --port --bind --token --auth --password --password-file --tailscale --task-supervisor-child --ws-log --raw-stream-path"
            required_value_options="--container --profile --log-level --port --bind --token --auth --password --password-file --tailscale --task-supervisor-child --ws-log --raw-stream-path"
            ;;
          "gateway run")
            command_path="${candidate_path}"
            opts="--port --bind --token --auth --password --password-file --tailscale --allow-unconfigured --dev --ambient-channels --dev-ambient-channels --reset --force --verbose --cli-backend-logs --claude-cli-logs --ws-log --compact --raw-stream --raw-stream-path"
            value_options="--container --profile --log-level --port --bind --token --auth --password --password-file --tailscale --task-supervisor-child --ws-log --raw-stream-path"
            required_value_options="--container --profile --log-level --port --bind --token --auth --password --password-file --tailscale --task-supervisor-child --ws-log --raw-stream-path"
            ;;
          "gateway status")
            command_path="${candidate_path}"
            opts="--url --port --token --password --timeout --no-probe --require-rpc --deep --json"
            value_options="--container --profile --log-level --bind --auth --password-file --tailscale --task-supervisor-child --ws-log --raw-stream-path --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --bind --auth --password-file --tailscale --task-supervisor-child --ws-log --raw-stream-path --url --port --token --password --timeout"
            ;;
          "gateway install")
            command_path="${candidate_path}"
            opts="--port --runtime --runtime-path --token --wrapper --allow-unconfigured --force --json"
            value_options="--container --profile --log-level --bind --auth --password --password-file --tailscale --task-supervisor-child --ws-log --raw-stream-path --port --runtime --runtime-path --expected-runtime-pin --token --wrapper --update-executor"
            required_value_options="--container --profile --log-level --bind --auth --password --password-file --tailscale --task-supervisor-child --ws-log --raw-stream-path --port --runtime --runtime-path --expected-runtime-pin --token --wrapper --update-executor"
            ;;
          "gateway uninstall")
            command_path="${candidate_path}"
            opts="--json"
            value_options="--container --profile --log-level --port --bind --token --auth --password --password-file --tailscale --task-supervisor-child --ws-log --raw-stream-path"
            required_value_options="--container --profile --log-level --port --bind --token --auth --password --password-file --tailscale --task-supervisor-child --ws-log --raw-stream-path"
            ;;
          "gateway start")
            command_path="${candidate_path}"
            opts="--json"
            value_options="--container --profile --log-level --port --bind --token --auth --password --password-file --tailscale --task-supervisor-child --ws-log --raw-stream-path"
            required_value_options="--container --profile --log-level --port --bind --token --auth --password --password-file --tailscale --task-supervisor-child --ws-log --raw-stream-path"
            ;;
          "gateway stop")
            command_path="${candidate_path}"
            opts="--force --json --disable"
            value_options="--container --profile --log-level --port --bind --token --auth --password --password-file --tailscale --task-supervisor-child --ws-log --raw-stream-path --update-executor"
            required_value_options="--container --profile --log-level --port --bind --token --auth --password --password-file --tailscale --task-supervisor-child --ws-log --raw-stream-path --update-executor"
            ;;
          "gateway restart")
            command_path="${candidate_path}"
            opts="--preserve-definition --force --safe --skip-deferral --wait --json"
            value_options="--container --profile --log-level --port --bind --token --auth --password --password-file --tailscale --task-supervisor-child --ws-log --raw-stream-path --update-executor --wait"
            required_value_options="--container --profile --log-level --port --bind --token --auth --password --password-file --tailscale --task-supervisor-child --ws-log --raw-stream-path --update-executor --wait"
            ;;
          "gateway restart-handoff")
            command_path="${candidate_path}"
            opts="capabilities consume"
            value_options="--container --profile --log-level --port --bind --token --auth --password --password-file --tailscale --task-supervisor-child --ws-log --raw-stream-path"
            required_value_options="--container --profile --log-level --port --bind --token --auth --password --password-file --tailscale --task-supervisor-child --ws-log --raw-stream-path"
            ;;
          "gateway restart-handoff capabilities")
            command_path="${candidate_path}"
            opts="--json"
            value_options="--container --profile --log-level --port --bind --token --auth --password --password-file --tailscale --task-supervisor-child --ws-log --raw-stream-path"
            required_value_options="--container --profile --log-level --port --bind --token --auth --password --password-file --tailscale --task-supervisor-child --ws-log --raw-stream-path"
            ;;
          "gateway restart-handoff consume")
            command_path="${candidate_path}"
            opts="--expected-pid --json"
            value_options="--container --profile --log-level --port --bind --token --auth --password --password-file --tailscale --task-supervisor-child --ws-log --raw-stream-path --expected-pid"
            required_value_options="--container --profile --log-level --port --bind --token --auth --password --password-file --tailscale --task-supervisor-child --ws-log --raw-stream-path"
            ;;
          "gateway auth-token")
            command_path="${candidate_path}"
            opts="--show"
            value_options="--container --profile --log-level --port --bind --token --auth --password --password-file --tailscale --task-supervisor-child --ws-log --raw-stream-path"
            required_value_options="--container --profile --log-level --port --bind --token --auth --password --password-file --tailscale --task-supervisor-child --ws-log --raw-stream-path"
            ;;
          "gateway call")
            command_path="${candidate_path}"
            opts="--expect-url --params --url --port --token --password --timeout --expect-final --json"
            value_options="--container --profile --log-level --bind --auth --password-file --tailscale --task-supervisor-child --ws-log --raw-stream-path --expect-url --params --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --bind --auth --password-file --tailscale --task-supervisor-child --ws-log --raw-stream-path --expect-url --params --url --port --token --password --timeout"
            ;;
          "gateway suspend")
            command_path="${candidate_path}"
            opts="--request-id --wait --url --port --token --password --timeout --expect-final --json"
            value_options="--container --profile --log-level --bind --auth --password-file --tailscale --task-supervisor-child --ws-log --raw-stream-path --request-id --wait --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --bind --auth --password-file --tailscale --task-supervisor-child --ws-log --raw-stream-path --request-id --wait --url --port --token --password --timeout"
            ;;
          "gateway resume")
            command_path="${candidate_path}"
            opts="--url --port --token --password --timeout --expect-final --json"
            value_options="--container --profile --log-level --bind --auth --password-file --tailscale --task-supervisor-child --ws-log --raw-stream-path --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --bind --auth --password-file --tailscale --task-supervisor-child --ws-log --raw-stream-path --url --port --token --password --timeout"
            ;;
          "gateway usage-cost")
            command_path="${candidate_path}"
            opts="--days --agent --all-agents --url --port --token --password --timeout --expect-final --json"
            value_options="--container --profile --log-level --bind --auth --password-file --tailscale --task-supervisor-child --ws-log --raw-stream-path --days --agent --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --bind --auth --password-file --tailscale --task-supervisor-child --ws-log --raw-stream-path --days --agent --url --port --token --password --timeout"
            ;;
          "gateway health")
            command_path="${candidate_path}"
            opts="--url --port --token --password --timeout --expect-final --json"
            value_options="--container --profile --log-level --bind --auth --password-file --tailscale --task-supervisor-child --ws-log --raw-stream-path --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --bind --auth --password-file --tailscale --task-supervisor-child --ws-log --raw-stream-path --url --port --token --password --timeout"
            ;;
          "gateway stability")
            command_path="${candidate_path}"
            opts="--limit --type --since-seq --bundle --export --output --url --port --token --password --timeout --expect-final --json"
            value_options="--container --profile --log-level --bind --auth --password-file --tailscale --task-supervisor-child --ws-log --raw-stream-path --limit --type --since-seq --bundle --output --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --bind --auth --password-file --tailscale --task-supervisor-child --ws-log --raw-stream-path --limit --type --since-seq --output --url --port --token --password --timeout"
            ;;
          "gateway diagnostics")
            command_path="${candidate_path}"
            opts="export"
            value_options="--container --profile --log-level --port --bind --token --auth --password --password-file --tailscale --task-supervisor-child --ws-log --raw-stream-path"
            required_value_options="--container --profile --log-level --port --bind --token --auth --password --password-file --tailscale --task-supervisor-child --ws-log --raw-stream-path"
            ;;
          "gateway diagnostics export")
            command_path="${candidate_path}"
            opts="--output --log-lines --log-bytes --url --token --password --timeout --no-stability-bundle --json"
            value_options="--container --profile --log-level --port --bind --auth --password-file --tailscale --task-supervisor-child --ws-log --raw-stream-path --output --log-lines --log-bytes --url --token --password --timeout"
            required_value_options="--container --profile --log-level --port --bind --auth --password-file --tailscale --task-supervisor-child --ws-log --raw-stream-path --output --log-lines --log-bytes --url --token --password --timeout"
            ;;
          "gateway probe")
            command_path="${candidate_path}"
            opts="--url --port --ssh --ssh-identity --ssh-auto --token --password --timeout --json"
            value_options="--container --profile --log-level --bind --auth --password-file --tailscale --task-supervisor-child --ws-log --raw-stream-path --url --port --ssh --ssh-identity --token --password --timeout"
            required_value_options="--container --profile --log-level --bind --auth --password-file --tailscale --task-supervisor-child --ws-log --raw-stream-path --url --port --ssh --ssh-identity --token --password --timeout"
            ;;
          "gateway discover")
            command_path="${candidate_path}"
            opts="--timeout --json"
            value_options="--container --profile --log-level --port --bind --token --auth --password --password-file --tailscale --task-supervisor-child --ws-log --raw-stream-path --timeout"
            required_value_options="--container --profile --log-level --port --bind --token --auth --password --password-file --tailscale --task-supervisor-child --ws-log --raw-stream-path --timeout"
            ;;
          "daemon")
            command_path="${candidate_path}"
            opts="install restart start status stop uninstall --json"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "daemon status")
            command_path="${candidate_path}"
            opts="--url --port --token --password --timeout --no-probe --require-rpc --deep --json"
            value_options="--container --profile --log-level --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --url --port --token --password --timeout"
            ;;
          "daemon install")
            command_path="${candidate_path}"
            opts="--port --runtime --runtime-path --token --wrapper --allow-unconfigured --force --json"
            value_options="--container --profile --log-level --port --runtime --runtime-path --expected-runtime-pin --token --wrapper --update-executor"
            required_value_options="--container --profile --log-level --port --runtime --runtime-path --expected-runtime-pin --token --wrapper --update-executor"
            ;;
          "daemon uninstall")
            command_path="${candidate_path}"
            opts="--json"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "daemon start")
            command_path="${candidate_path}"
            opts="--json"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "daemon stop")
            command_path="${candidate_path}"
            opts="--force --json --disable"
            value_options="--container --profile --log-level --update-executor"
            required_value_options="--container --profile --log-level --update-executor"
            ;;
          "daemon restart")
            command_path="${candidate_path}"
            opts="--preserve-definition --force --safe --skip-deferral --wait --json"
            value_options="--container --profile --log-level --update-executor --wait"
            required_value_options="--container --profile --log-level --update-executor --wait"
            ;;
          "logs")
            command_path="${candidate_path}"
            opts="--limit --max-bytes --follow --interval --json --plain --no-color --local-time --utc --url --port --token --password --timeout --expect-final"
            value_options="--container --profile --log-level --limit --max-bytes --interval --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --limit --max-bytes --interval --url --port --token --password --timeout"
            ;;
          "system")
            command_path="${candidate_path}"
            opts="event heartbeat presence"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "system event")
            command_path="${candidate_path}"
            opts="--text --mode --session-key --json --url --port --token --password --timeout --expect-final"
            value_options="--container --profile --log-level --text --mode --session-key --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --text --mode --session-key --url --port --token --password --timeout"
            ;;
          "system heartbeat")
            command_path="${candidate_path}"
            opts="disable enable last"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "system heartbeat last")
            command_path="${candidate_path}"
            opts="--json --url --port --token --password --timeout --expect-final"
            value_options="--container --profile --log-level --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --url --port --token --password --timeout"
            ;;
          "system heartbeat enable")
            command_path="${candidate_path}"
            opts="--json --url --port --token --password --timeout --expect-final"
            value_options="--container --profile --log-level --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --url --port --token --password --timeout"
            ;;
          "system heartbeat disable")
            command_path="${candidate_path}"
            opts="--json --url --port --token --password --timeout --expect-final"
            value_options="--container --profile --log-level --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --url --port --token --password --timeout"
            ;;
          "system presence")
            command_path="${candidate_path}"
            opts="--json --url --port --token --password --timeout --expect-final"
            value_options="--container --profile --log-level --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --url --port --token --password --timeout"
            ;;
          "models")
            command_path="${candidate_path}"
            opts="accounts aliases auth fallbacks image-fallbacks list refresh scan set set-image status --json --status-json --status-plain --agent"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "models accounts")
            command_path="${candidate_path}"
            opts="clear-default list login use --url --port --token-file --password-file --timeout --json"
            value_options="--container --profile --log-level --agent --url --port --token-file --password-file --timeout"
            required_value_options="--container --profile --log-level --agent --url --port --token-file --password-file --timeout"
            ;;
          "models accounts list")
            command_path="${candidate_path}"
            opts="--url --port --token-file --password-file --timeout --json --cursor"
            value_options="--container --profile --log-level --agent --url --port --token-file --password-file --timeout --cursor"
            required_value_options="--container --profile --log-level --agent --url --port --token-file --password-file --timeout --cursor"
            ;;
          "models accounts login")
            command_path="${candidate_path}"
            opts="--url --port --token-file --password-file --timeout --json --method"
            value_options="--container --profile --log-level --agent --url --port --token-file --password-file --timeout --method"
            required_value_options="--container --profile --log-level --agent --url --port --token-file --password-file --timeout --method"
            ;;
          "models accounts use")
            command_path="${candidate_path}"
            opts="--url --port --token-file --password-file --timeout --json"
            value_options="--container --profile --log-level --agent --url --port --token-file --password-file --timeout"
            required_value_options="--container --profile --log-level --agent --url --port --token-file --password-file --timeout"
            ;;
          "models accounts clear-default")
            command_path="${candidate_path}"
            opts="--url --port --token-file --password-file --timeout --json"
            value_options="--container --profile --log-level --agent --url --port --token-file --password-file --timeout"
            required_value_options="--container --profile --log-level --agent --url --port --token-file --password-file --timeout"
            ;;
          "models list")
            command_path="${candidate_path}"
            opts="--refresh --all --local --provider --agent --json --plain"
            value_options="--container --profile --log-level --provider --agent"
            required_value_options="--container --profile --log-level --provider --agent"
            ;;
          "models status")
            command_path="${candidate_path}"
            opts="--json --plain --check --probe --probe-provider --probe-profile --probe-timeout --probe-concurrency --probe-max-tokens --agent"
            value_options="--container --profile --log-level --probe-provider --probe-profile --probe-timeout --probe-concurrency --probe-max-tokens --agent"
            required_value_options="--container --profile --log-level --probe-provider --probe-profile --probe-timeout --probe-concurrency --probe-max-tokens --agent"
            ;;
          "models refresh")
            command_path="${candidate_path}"
            opts="--json"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "models set")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "models set-image")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "models aliases")
            command_path="${candidate_path}"
            opts="add list remove"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "models aliases list")
            command_path="${candidate_path}"
            opts="--json --plain"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "models aliases add")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "models aliases remove")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "models fallbacks")
            command_path="${candidate_path}"
            opts="add clear list remove"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "models fallbacks list")
            command_path="${candidate_path}"
            opts="--json --plain"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "models fallbacks add")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "models fallbacks remove")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "models fallbacks clear")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "models image-fallbacks")
            command_path="${candidate_path}"
            opts="add clear list remove"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "models image-fallbacks list")
            command_path="${candidate_path}"
            opts="--json --plain"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "models image-fallbacks add")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "models image-fallbacks remove")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "models image-fallbacks clear")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "models scan")
            command_path="${candidate_path}"
            opts="--min-params --max-age-days --provider --max-candidates --timeout --concurrency --no-probe --yes --no-input --set-default --set-image --json"
            value_options="--container --profile --log-level --agent --min-params --max-age-days --provider --max-candidates --timeout --concurrency"
            required_value_options="--container --profile --log-level --agent --min-params --max-age-days --provider --max-candidates --timeout --concurrency"
            ;;
          "models auth")
            command_path="${candidate_path}"
            opts="activate add list login login-github-copilot logout order paste-api-key paste-token setup-token --agent"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "models auth list")
            command_path="${candidate_path}"
            opts="--provider --agent --json"
            value_options="--container --profile --log-level --provider --agent"
            required_value_options="--container --profile --log-level --provider --agent"
            ;;
          "models auth add")
            command_path="${candidate_path}"
            opts="--agent"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "models auth activate")
            command_path="${candidate_path}"
            opts="--agent"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "models auth logout")
            command_path="${candidate_path}"
            opts="--agent --yes"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "models auth login")
            command_path="${candidate_path}"
            opts="--agent --provider --method --device-code --profile-id --set-default --force"
            value_options="--container --profile --log-level --agent --provider --method --profile-id"
            required_value_options="--container --profile --log-level --agent --provider --method --profile-id"
            ;;
          "models auth setup-token")
            command_path="${candidate_path}"
            opts="--agent --provider --yes"
            value_options="--container --profile --log-level --agent --provider"
            required_value_options="--container --profile --log-level --agent --provider"
            ;;
          "models auth paste-token")
            command_path="${candidate_path}"
            opts="--agent --provider --profile-id --expires-in"
            value_options="--container --profile --log-level --agent --provider --profile-id --expires-in"
            required_value_options="--container --profile --log-level --agent --provider --profile-id --expires-in"
            ;;
          "models auth paste-api-key")
            command_path="${candidate_path}"
            opts="--agent --provider --profile-id"
            value_options="--container --profile --log-level --agent --provider --profile-id"
            required_value_options="--container --profile --log-level --agent --provider --profile-id"
            ;;
          "models auth login-github-copilot")
            command_path="${candidate_path}"
            opts="--agent --yes"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "models auth order")
            command_path="${candidate_path}"
            opts="clear get set"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "models auth order get")
            command_path="${candidate_path}"
            opts="--provider --agent --json"
            value_options="--container --profile --log-level --provider --agent"
            required_value_options="--container --profile --log-level --provider --agent"
            ;;
          "models auth order set")
            command_path="${candidate_path}"
            opts="--provider --agent"
            value_options="--container --profile --log-level --provider --agent"
            required_value_options="--container --profile --log-level --provider --agent"
            ;;
          "models auth order clear")
            command_path="${candidate_path}"
            opts="--provider --agent"
            value_options="--container --profile --log-level --provider --agent"
            required_value_options="--container --profile --log-level --provider --agent"
            ;;
          "promos")
            command_path="${candidate_path}"
            opts="claim list"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "promos list")
            command_path="${candidate_path}"
            opts="--json"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "promos claim")
            command_path="${candidate_path}"
            opts="--api-key --set-default"
            value_options="--container --profile --log-level --api-key"
            required_value_options="--container --profile --log-level --api-key"
            ;;
          "telemetry")
            command_path="${candidate_path}"
            opts="off on show"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "telemetry show")
            command_path="${candidate_path}"
            opts="--json"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "telemetry on")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "telemetry off")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "infer"|"capability")
            command_path="${candidate_path}"
            opts="audio embedding image inspect list model tts video web"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "infer list"|"capability list")
            command_path="${candidate_path}"
            opts="--json"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "infer inspect"|"capability inspect")
            command_path="${candidate_path}"
            opts="--name --json"
            value_options="--container --profile --log-level --name"
            required_value_options="--container --profile --log-level --name"
            ;;
          "infer model"|"capability model")
            command_path="${candidate_path}"
            opts="auth inspect list providers run --agent"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "infer model run"|"capability model run")
            command_path="${candidate_path}"
            opts="--prompt --file --model --thinking --local --gateway --agent --json"
            value_options="--container --profile --log-level --prompt --file --model --thinking --agent"
            required_value_options="--container --profile --log-level --prompt --file --model --thinking --agent"
            ;;
          "infer model list"|"capability model list")
            command_path="${candidate_path}"
            opts="--json"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "infer model inspect"|"capability model inspect")
            command_path="${candidate_path}"
            opts="--model --json"
            value_options="--container --profile --log-level --agent --model"
            required_value_options="--container --profile --log-level --agent --model"
            ;;
          "infer model providers"|"capability model providers")
            command_path="${candidate_path}"
            opts="--agent --json"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "infer model auth"|"capability model auth")
            command_path="${candidate_path}"
            opts="login logout status --agent"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "infer model auth login"|"capability model auth login")
            command_path="${candidate_path}"
            opts="--provider --method --agent"
            value_options="--container --profile --log-level --provider --method --agent"
            required_value_options="--container --profile --log-level --provider --method --agent"
            ;;
          "infer model auth logout"|"capability model auth logout")
            command_path="${candidate_path}"
            opts="--provider --agent --json"
            value_options="--container --profile --log-level --provider --agent"
            required_value_options="--container --profile --log-level --provider --agent"
            ;;
          "infer model auth status"|"capability model auth status")
            command_path="${candidate_path}"
            opts="--agent --json"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "infer image"|"capability image")
            command_path="${candidate_path}"
            opts="describe describe-many edit generate providers --agent"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "infer image generate"|"capability image generate")
            command_path="${candidate_path}"
            opts="--prompt --model --count --size --aspect-ratio --resolution --output-format --background --openai-background --openai-moderation --quality --timeout-ms --output --agent --json"
            value_options="--container --profile --log-level --prompt --model --count --size --aspect-ratio --resolution --output-format --background --openai-background --openai-moderation --quality --timeout-ms --output --agent"
            required_value_options="--container --profile --log-level --prompt --model --count --size --aspect-ratio --resolution --output-format --background --openai-background --openai-moderation --quality --timeout-ms --output --agent"
            ;;
          "infer image edit"|"capability image edit")
            command_path="${candidate_path}"
            opts="--file --prompt --model --count --size --aspect-ratio --resolution --output-format --background --openai-background --openai-moderation --quality --timeout-ms --output --agent --json"
            value_options="--container --profile --log-level --file --prompt --model --count --size --aspect-ratio --resolution --output-format --background --openai-background --openai-moderation --quality --timeout-ms --output --agent"
            required_value_options="--container --profile --log-level --file --prompt --model --count --size --aspect-ratio --resolution --output-format --background --openai-background --openai-moderation --quality --timeout-ms --output --agent"
            ;;
          "infer image describe"|"capability image describe")
            command_path="${candidate_path}"
            opts="--file --prompt --model --timeout-ms --agent --json"
            value_options="--container --profile --log-level --file --prompt --model --timeout-ms --agent"
            required_value_options="--container --profile --log-level --file --prompt --model --timeout-ms --agent"
            ;;
          "infer image describe-many"|"capability image describe-many")
            command_path="${candidate_path}"
            opts="--file --prompt --model --timeout-ms --agent --json"
            value_options="--container --profile --log-level --file --prompt --model --timeout-ms --agent"
            required_value_options="--container --profile --log-level --file --prompt --model --timeout-ms --agent"
            ;;
          "infer image providers"|"capability image providers")
            command_path="${candidate_path}"
            opts="--agent --json"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "infer audio"|"capability audio")
            command_path="${candidate_path}"
            opts="providers transcribe --agent"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "infer audio transcribe"|"capability audio transcribe")
            command_path="${candidate_path}"
            opts="--file --agent --language --prompt --model --json"
            value_options="--container --profile --log-level --file --agent --language --prompt --model"
            required_value_options="--container --profile --log-level --file --agent --language --prompt --model"
            ;;
          "infer audio providers"|"capability audio providers")
            command_path="${candidate_path}"
            opts="--agent --json"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "infer tts"|"capability tts")
            command_path="${candidate_path}"
            opts="convert disable enable personas providers set-persona set-provider status voices"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "infer tts convert"|"capability tts convert")
            command_path="${candidate_path}"
            opts="--text --channel --voice --provider --model --output --local --gateway --json"
            value_options="--container --profile --log-level --text --channel --voice --provider --model --output"
            required_value_options="--container --profile --log-level --text --channel --voice --provider --model --output"
            ;;
          "infer tts voices"|"capability tts voices")
            command_path="${candidate_path}"
            opts="--provider --json"
            value_options="--container --profile --log-level --provider"
            required_value_options="--container --profile --log-level --provider"
            ;;
          "infer tts providers"|"capability tts providers")
            command_path="${candidate_path}"
            opts="--agent --local --gateway --json"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "infer tts personas"|"capability tts personas")
            command_path="${candidate_path}"
            opts="--local --gateway --json"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "infer tts status"|"capability tts status")
            command_path="${candidate_path}"
            opts="--gateway --json"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "infer tts enable"|"capability tts enable")
            command_path="${candidate_path}"
            opts="--local --gateway --json"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "infer tts disable"|"capability tts disable")
            command_path="${candidate_path}"
            opts="--local --gateway --json"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "infer tts set-provider"|"capability tts set-provider")
            command_path="${candidate_path}"
            opts="--provider --local --gateway --json"
            value_options="--container --profile --log-level --provider"
            required_value_options="--container --profile --log-level --provider"
            ;;
          "infer tts set-persona"|"capability tts set-persona")
            command_path="${candidate_path}"
            opts="--persona --off --local --gateway --json"
            value_options="--container --profile --log-level --persona"
            required_value_options="--container --profile --log-level --persona"
            ;;
          "infer video"|"capability video")
            command_path="${candidate_path}"
            opts="describe generate providers --agent"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "infer video generate"|"capability video generate")
            command_path="${candidate_path}"
            opts="--prompt --model --size --aspect-ratio --resolution --duration --audio --watermark --timeout-ms --output --agent --json"
            value_options="--container --profile --log-level --prompt --model --size --aspect-ratio --resolution --duration --timeout-ms --output --agent"
            required_value_options="--container --profile --log-level --prompt --model --size --aspect-ratio --resolution --duration --timeout-ms --output --agent"
            ;;
          "infer video describe"|"capability video describe")
            command_path="${candidate_path}"
            opts="--file --agent --model --json"
            value_options="--container --profile --log-level --file --agent --model"
            required_value_options="--container --profile --log-level --file --agent --model"
            ;;
          "infer video providers"|"capability video providers")
            command_path="${candidate_path}"
            opts="--agent --json"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "infer web"|"capability web")
            command_path="${candidate_path}"
            opts="fetch providers search"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "infer web search"|"capability web search")
            command_path="${candidate_path}"
            opts="--query --provider --limit --json"
            value_options="--container --profile --log-level --query --provider --limit"
            required_value_options="--container --profile --log-level --query --provider --limit"
            ;;
          "infer web fetch"|"capability web fetch")
            command_path="${candidate_path}"
            opts="--url --provider --format --json"
            value_options="--container --profile --log-level --url --provider --format"
            required_value_options="--container --profile --log-level --url --provider --format"
            ;;
          "infer web providers"|"capability web providers")
            command_path="${candidate_path}"
            opts="--agent --json"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "infer embedding"|"capability embedding")
            command_path="${candidate_path}"
            opts="create providers --agent"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "infer embedding create"|"capability embedding create")
            command_path="${candidate_path}"
            opts="--text --provider --model --agent --json"
            value_options="--container --profile --log-level --text --provider --model --agent"
            required_value_options="--container --profile --log-level --text --provider --model --agent"
            ;;
          "infer embedding providers"|"capability embedding providers")
            command_path="${candidate_path}"
            opts="--agent --json"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "approvals"|"exec-approvals")
            command_path="${candidate_path}"
            opts="allowlist get grants pending resolve set"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "approvals pending"|"exec-approvals pending")
            command_path="${candidate_path}"
            opts="--url --token --timeout --json"
            value_options="--container --profile --log-level --url --token --timeout"
            required_value_options="--container --profile --log-level --url --token --timeout"
            ;;
          "approvals resolve"|"exec-approvals resolve")
            command_path="${candidate_path}"
            opts="--reason --expires-in-days --url --token --timeout --json"
            value_options="--container --profile --log-level --reason --expires-in-days --url --token --timeout"
            required_value_options="--container --profile --log-level --reason --expires-in-days --url --token --timeout"
            ;;
          "approvals grants"|"exec-approvals grants")
            command_path="${candidate_path}"
            opts="list revoke"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "approvals grants list"|"exec-approvals grants list")
            command_path="${candidate_path}"
            opts="--limit --url --token --timeout --json"
            value_options="--container --profile --log-level --limit --url --token --timeout"
            required_value_options="--container --profile --log-level --limit --url --token --timeout"
            ;;
          "approvals grants revoke"|"exec-approvals grants revoke")
            command_path="${candidate_path}"
            opts="--url --token --timeout --json"
            value_options="--container --profile --log-level --url --token --timeout"
            required_value_options="--container --profile --log-level --url --token --timeout"
            ;;
          "approvals get"|"exec-approvals get")
            command_path="${candidate_path}"
            opts="--node --gateway --url --token --timeout --json"
            value_options="--container --profile --log-level --node --url --token --timeout"
            required_value_options="--container --profile --log-level --node --url --token --timeout"
            ;;
          "approvals set"|"exec-approvals set")
            command_path="${candidate_path}"
            opts="--node --gateway --file --stdin --url --token --timeout --json"
            value_options="--container --profile --log-level --node --file --url --token --timeout"
            required_value_options="--container --profile --log-level --node --file --url --token --timeout"
            ;;
          "approvals allowlist"|"exec-approvals allowlist")
            command_path="${candidate_path}"
            opts="add remove"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "approvals allowlist add"|"exec-approvals allowlist add")
            command_path="${candidate_path}"
            opts="--node --gateway --agent --url --token --timeout --json"
            value_options="--container --profile --log-level --node --agent --url --token --timeout"
            required_value_options="--container --profile --log-level --node --agent --url --token --timeout"
            ;;
          "approvals allowlist remove"|"exec-approvals allowlist remove")
            command_path="${candidate_path}"
            opts="--node --gateway --agent --url --token --timeout --json"
            value_options="--container --profile --log-level --node --agent --url --token --timeout"
            required_value_options="--container --profile --log-level --node --agent --url --token --timeout"
            ;;
          "exec-policy")
            command_path="${candidate_path}"
            opts="preset set show"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "exec-policy show")
            command_path="${candidate_path}"
            opts="--agent --session --verbose --json --url --port --token --password --timeout --expect-final"
            value_options="--container --profile --log-level --agent --session --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --agent --session --url --port --token --password --timeout"
            ;;
          "exec-policy preset")
            command_path="${candidate_path}"
            opts="--json"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "exec-policy set")
            command_path="${candidate_path}"
            opts="--host --security --ask --ask-fallback --json"
            value_options="--container --profile --log-level --host --security --ask --ask-fallback"
            required_value_options="--container --profile --log-level --host --security --ask --ask-fallback"
            ;;
          "nodes")
            command_path="${candidate_path}"
            opts="approve camera describe invoke list location notify pending push reject remove rename screen status"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "nodes status")
            command_path="${candidate_path}"
            opts="--connected --last-connected --url --token --timeout --json"
            value_options="--container --profile --log-level --last-connected --url --token --timeout"
            required_value_options="--container --profile --log-level --last-connected --url --token --timeout"
            ;;
          "nodes describe")
            command_path="${candidate_path}"
            opts="--node --url --token --timeout --json"
            value_options="--container --profile --log-level --node --url --token --timeout"
            required_value_options="--container --profile --log-level --node --url --token --timeout"
            ;;
          "nodes list")
            command_path="${candidate_path}"
            opts="--connected --last-connected --url --token --timeout --json"
            value_options="--container --profile --log-level --last-connected --url --token --timeout"
            required_value_options="--container --profile --log-level --last-connected --url --token --timeout"
            ;;
          "nodes pending")
            command_path="${candidate_path}"
            opts="--url --token --timeout --json"
            value_options="--container --profile --log-level --url --token --timeout"
            required_value_options="--container --profile --log-level --url --token --timeout"
            ;;
          "nodes approve")
            command_path="${candidate_path}"
            opts="--url --token --timeout --json"
            value_options="--container --profile --log-level --url --token --timeout"
            required_value_options="--container --profile --log-level --url --token --timeout"
            ;;
          "nodes reject")
            command_path="${candidate_path}"
            opts="--url --token --timeout --json"
            value_options="--container --profile --log-level --url --token --timeout"
            required_value_options="--container --profile --log-level --url --token --timeout"
            ;;
          "nodes remove")
            command_path="${candidate_path}"
            opts="--node --url --token --timeout --json"
            value_options="--container --profile --log-level --node --url --token --timeout"
            required_value_options="--container --profile --log-level --node --url --token --timeout"
            ;;
          "nodes rename")
            command_path="${candidate_path}"
            opts="--node --name --url --token --timeout --json"
            value_options="--container --profile --log-level --node --name --url --token --timeout"
            required_value_options="--container --profile --log-level --node --name --url --token --timeout"
            ;;
          "nodes invoke")
            command_path="${candidate_path}"
            opts="--node --command --params --invoke-timeout --idempotency-key --url --token --timeout --json"
            value_options="--container --profile --log-level --node --command --params --invoke-timeout --idempotency-key --url --token --timeout"
            required_value_options="--container --profile --log-level --node --command --params --invoke-timeout --idempotency-key --url --token --timeout"
            ;;
          "nodes notify")
            command_path="${candidate_path}"
            opts="--node --title --body --sound --priority --delivery --invoke-timeout --url --token --timeout --json"
            value_options="--container --profile --log-level --node --title --body --sound --priority --delivery --invoke-timeout --url --token --timeout"
            required_value_options="--container --profile --log-level --node --title --body --sound --priority --delivery --invoke-timeout --url --token --timeout"
            ;;
          "nodes push")
            command_path="${candidate_path}"
            opts="--node --title --body --environment --url --token --timeout --json"
            value_options="--container --profile --log-level --node --title --body --environment --url --token --timeout"
            required_value_options="--container --profile --log-level --node --title --body --environment --url --token --timeout"
            ;;
          "nodes camera")
            command_path="${candidate_path}"
            opts="clip list snap"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "nodes camera list")
            command_path="${candidate_path}"
            opts="--node --url --token --timeout --json"
            value_options="--container --profile --log-level --node --url --token --timeout"
            required_value_options="--container --profile --log-level --node --url --token --timeout"
            ;;
          "nodes camera snap")
            command_path="${candidate_path}"
            opts="--node --facing --device-id --max-width --quality --delay-ms --invoke-timeout --url --token --timeout --json"
            value_options="--container --profile --log-level --node --facing --device-id --max-width --quality --delay-ms --invoke-timeout --url --token --timeout"
            required_value_options="--container --profile --log-level --node --facing --device-id --max-width --quality --delay-ms --invoke-timeout --url --token --timeout"
            ;;
          "nodes camera clip")
            command_path="${candidate_path}"
            opts="--node --facing --device-id --duration --no-audio --invoke-timeout --url --token --timeout --json"
            value_options="--container --profile --log-level --node --facing --device-id --duration --invoke-timeout --url --token --timeout"
            required_value_options="--container --profile --log-level --node --facing --device-id --duration --invoke-timeout --url --token --timeout"
            ;;
          "nodes screen")
            command_path="${candidate_path}"
            opts="record"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "nodes screen record")
            command_path="${candidate_path}"
            opts="--node --screen --duration --fps --no-audio --out --invoke-timeout --url --token --timeout --json"
            value_options="--container --profile --log-level --node --screen --duration --fps --out --invoke-timeout --url --token --timeout"
            required_value_options="--container --profile --log-level --node --screen --duration --fps --out --invoke-timeout --url --token --timeout"
            ;;
          "nodes location")
            command_path="${candidate_path}"
            opts="get"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "nodes location get")
            command_path="${candidate_path}"
            opts="--node --max-age --accuracy --location-timeout --invoke-timeout --url --token --timeout --json"
            value_options="--container --profile --log-level --node --max-age --accuracy --location-timeout --invoke-timeout --url --token --timeout"
            required_value_options="--container --profile --log-level --node --max-age --accuracy --location-timeout --invoke-timeout --url --token --timeout"
            ;;
          "devices")
            command_path="${candidate_path}"
            opts="approve clear join-code list reject remove rename revoke rotate"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "devices list")
            command_path="${candidate_path}"
            opts="--url --token --password --timeout --json"
            value_options="--container --profile --log-level --url --token --password --timeout"
            required_value_options="--container --profile --log-level --url --token --password --timeout"
            ;;
          "devices join-code")
            command_path="${candidate_path}"
            opts="--url --token --password --timeout --json"
            value_options="--container --profile --log-level --url --token --password --timeout"
            required_value_options="--container --profile --log-level --url --token --password --timeout"
            ;;
          "devices remove")
            command_path="${candidate_path}"
            opts="--url --token --password --timeout --json"
            value_options="--container --profile --log-level --url --token --password --timeout"
            required_value_options="--container --profile --log-level --url --token --password --timeout"
            ;;
          "devices clear")
            command_path="${candidate_path}"
            opts="--pending --yes --url --token --password --timeout --json"
            value_options="--container --profile --log-level --url --token --password --timeout"
            required_value_options="--container --profile --log-level --url --token --password --timeout"
            ;;
          "devices approve")
            command_path="${candidate_path}"
            opts="--latest --url --token --password --timeout --json"
            value_options="--container --profile --log-level --url --token --password --timeout"
            required_value_options="--container --profile --log-level --url --token --password --timeout"
            ;;
          "devices reject")
            command_path="${candidate_path}"
            opts="--url --token --password --timeout --json"
            value_options="--container --profile --log-level --url --token --password --timeout"
            required_value_options="--container --profile --log-level --url --token --password --timeout"
            ;;
          "devices rename")
            command_path="${candidate_path}"
            opts="--device --name --url --token --password --timeout --json"
            value_options="--container --profile --log-level --device --name --url --token --password --timeout"
            required_value_options="--container --profile --log-level --device --name --url --token --password --timeout"
            ;;
          "devices rotate")
            command_path="${candidate_path}"
            opts="--device --role --scope --no-scopes --url --token --password --timeout --json"
            value_options="--container --profile --log-level --device --role --scope --url --token --password --timeout"
            required_value_options="--container --profile --log-level --device --role --scope --url --token --password --timeout"
            ;;
          "devices revoke")
            command_path="${candidate_path}"
            opts="--device --role --url --token --password --timeout --json"
            value_options="--container --profile --log-level --device --role --url --token --password --timeout"
            required_value_options="--container --profile --log-level --device --role --url --token --password --timeout"
            ;;
          "users")
            command_path="${candidate_path}"
            opts="link-email list merge"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "users list")
            command_path="${candidate_path}"
            opts="--url --token --timeout --json"
            value_options="--container --profile --log-level --url --token --timeout"
            required_value_options="--container --profile --log-level --url --token --timeout"
            ;;
          "users link-email")
            command_path="${candidate_path}"
            opts="--to --url --token --timeout --json"
            value_options="--container --profile --log-level --to --url --token --timeout"
            required_value_options="--container --profile --log-level --to --url --token --timeout"
            ;;
          "users merge")
            command_path="${candidate_path}"
            opts="--into --url --token --timeout --json"
            value_options="--container --profile --log-level --into --url --token --timeout"
            required_value_options="--container --profile --log-level --into --url --token --timeout"
            ;;
          "node")
            command_path="${candidate_path}"
            opts="identity install restart run start status stop uninstall --commands --all-commands"
            value_options="--container --profile --log-level --commands"
            required_value_options="--container --profile --log-level --commands"
            ;;
          "node worker")
            command_path="${candidate_path}"
            opts="--desktop-sharing --no-desktop-sharing"
            value_options="--container --profile --log-level --commands"
            required_value_options="--container --profile --log-level --commands"
            ;;
          "node run")
            command_path="${candidate_path}"
            opts="--commands --all-commands --pair --pair-if-needed --host --port --context-path --tls --no-tls --tls-fingerprint --node-id --display-name --session-host --share-installed-apps --no-share-installed-apps"
            value_options="--container --profile --log-level --commands --pair --pair-if-needed --host --port --context-path --tls-fingerprint --node-id --display-name"
            required_value_options="--container --profile --log-level --commands --pair --pair-if-needed --host --port --context-path --tls-fingerprint --node-id --display-name"
            ;;
          "node status")
            command_path="${candidate_path}"
            opts="--json"
            value_options="--container --profile --log-level --commands"
            required_value_options="--container --profile --log-level --commands"
            ;;
          "node identity")
            command_path="${candidate_path}"
            opts="--json"
            value_options="--container --profile --log-level --commands"
            required_value_options="--container --profile --log-level --commands"
            ;;
          "node install")
            command_path="${candidate_path}"
            opts="--commands --all-commands --host --port --context-path --tls --no-tls --tls-fingerprint --node-id --display-name --share-installed-apps --no-share-installed-apps --runtime --runtime-path --force --json"
            value_options="--container --profile --log-level --commands --host --port --context-path --tls-fingerprint --node-id --display-name --runtime --runtime-path"
            required_value_options="--container --profile --log-level --commands --host --port --context-path --tls-fingerprint --node-id --display-name --runtime --runtime-path"
            ;;
          "node uninstall")
            command_path="${candidate_path}"
            opts="--json"
            value_options="--container --profile --log-level --commands"
            required_value_options="--container --profile --log-level --commands"
            ;;
          "node stop")
            command_path="${candidate_path}"
            opts="--json"
            value_options="--container --profile --log-level --commands"
            required_value_options="--container --profile --log-level --commands"
            ;;
          "node start")
            command_path="${candidate_path}"
            opts="--json"
            value_options="--container --profile --log-level --commands"
            required_value_options="--container --profile --log-level --commands"
            ;;
          "node restart")
            command_path="${candidate_path}"
            opts="--json"
            value_options="--container --profile --log-level --commands"
            required_value_options="--container --profile --log-level --commands"
            ;;
          "connect")
            command_path="${candidate_path}"
            opts="--commands --all-commands --service --ephemeral --session-host --target-file --display-name"
            value_options="--container --profile --log-level --commands --target-file --display-name"
            required_value_options="--container --profile --log-level --commands --target-file --display-name"
            ;;
          "worker")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "sandbox")
            command_path="${candidate_path}"
            opts="explain list recreate"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "sandbox list")
            command_path="${candidate_path}"
            opts="--json --browser"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "sandbox recreate")
            command_path="${candidate_path}"
            opts="--all --session --agent --browser --force"
            value_options="--container --profile --log-level --session --agent"
            required_value_options="--container --profile --log-level --session --agent"
            ;;
          "sandbox explain")
            command_path="${candidate_path}"
            opts="--session --agent --json"
            value_options="--container --profile --log-level --session --agent"
            required_value_options="--container --profile --log-level --session --agent"
            ;;
          "fleet")
            command_path="${candidate_path}"
            opts="backup create doctor list ls logs restart restore rm start status stop upgrade"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "fleet create")
            command_path="${candidate_path}"
            opts="--image --runtime --port --memory --cpus --disk --network --pids-limit --env --gateway-token --no-start --json"
            value_options="--container --profile --log-level --image --runtime --port --memory --cpus --disk --network --pids-limit --env --gateway-token"
            required_value_options="--container --profile --log-level --image --runtime --port --memory --cpus --disk --network --pids-limit --env --gateway-token"
            ;;
          "fleet backup")
            command_path="${candidate_path}"
            opts="--out --max-bytes --json"
            value_options="--container --profile --log-level --out --max-bytes"
            required_value_options="--container --profile --log-level --out --max-bytes"
            ;;
          "fleet restore")
            command_path="${candidate_path}"
            opts="--from --force --max-bytes --json"
            value_options="--container --profile --log-level --from --max-bytes"
            required_value_options="--container --profile --log-level --from --max-bytes"
            ;;
          "fleet doctor")
            command_path="${candidate_path}"
            opts="--json"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "fleet list"|"fleet ls")
            command_path="${candidate_path}"
            opts="--json"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "fleet status")
            command_path="${candidate_path}"
            opts="--json"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "fleet logs")
            command_path="${candidate_path}"
            opts="--follow --timestamps --tail --since"
            value_options="--container --profile --log-level --tail --since"
            required_value_options="--container --profile --log-level --tail --since"
            ;;
          "fleet start")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "fleet stop")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "fleet restart")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "fleet upgrade")
            command_path="${candidate_path}"
            opts="--image"
            value_options="--container --profile --log-level --image"
            required_value_options="--container --profile --log-level --image"
            ;;
          "fleet rm")
            command_path="${candidate_path}"
            opts="--purge-data --force"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "worktrees")
            command_path="${candidate_path}"
            opts="create gc list recover-removal remove restore retire-snapshot"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "worktrees list")
            command_path="${candidate_path}"
            opts="--json"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "worktrees create")
            command_path="${candidate_path}"
            opts="--name --base-ref --source-profile --json"
            value_options="--container --profile --log-level --name --base-ref --source-profile"
            required_value_options="--container --profile --log-level --name --base-ref --source-profile"
            ;;
          "worktrees remove")
            command_path="${candidate_path}"
            opts="--force --if-lossless --exact-state --json"
            value_options="--container --profile --log-level --exact-state"
            required_value_options="--container --profile --log-level --exact-state"
            ;;
          "worktrees retire-snapshot")
            command_path="${candidate_path}"
            opts="--expected-ref --expected-oid --removed-at --retained-ref --retained-oid --json"
            value_options="--container --profile --log-level --expected-ref --expected-oid --removed-at --retained-ref --retained-oid"
            required_value_options="--container --profile --log-level --expected-ref --expected-oid --removed-at --retained-ref --retained-oid"
            ;;
          "worktrees recover-removal")
            command_path="${candidate_path}"
            opts="--snapshot --json"
            value_options="--container --profile --log-level --snapshot"
            required_value_options="--container --profile --log-level --snapshot"
            ;;
          "worktrees restore")
            command_path="${candidate_path}"
            opts="--recover-exact-state --json"
            value_options="--container --profile --log-level --recover-exact-state"
            required_value_options="--container --profile --log-level --recover-exact-state"
            ;;
          "worktrees gc")
            command_path="${candidate_path}"
            opts="--json"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "attach")
            command_path="${candidate_path}"
            opts="--session --url --token --password --tls-fingerprint --ttl --bin --print-config"
            value_options="--container --profile --log-level --session --url --token --password --tls-fingerprint --ttl --bin"
            required_value_options="--container --profile --log-level --session --url --token --password --tls-fingerprint --ttl --bin"
            ;;
          "resume")
            command_path="${candidate_path}"
            opts="--handoff --url --token --password --tls-fingerprint"
            value_options="--container --profile --log-level --handoff --url --token --password --tls-fingerprint"
            required_value_options="--container --profile --log-level --handoff --url --token --password --tls-fingerprint"
            ;;
          "tui"|"terminal"|"chat")
            command_path="${candidate_path}"
            opts="--local --url --token --password --tls-fingerprint --session --deliver --thinking --message --timeout-ms --history-limit"
            value_options="--container --profile --log-level --url --token --password --tls-fingerprint --session --thinking --message --timeout-ms --history-limit"
            required_value_options="--container --profile --log-level --url --token --password --tls-fingerprint --session --thinking --message --timeout-ms --history-limit"
            ;;
          "cron"|"automations")
            command_path="${candidate_path}"
            opts="add create disable edit enable get list rm remove delete run runs scratch show status --url --port --token --password --timeout --expect-final"
            value_options="--container --profile --log-level --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --url --port --token --password --timeout"
            ;;
          "cron status"|"automations status")
            command_path="${candidate_path}"
            opts="--json --url --port --token --password --timeout --expect-final"
            value_options="--container --profile --log-level --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --url --port --token --password --timeout"
            ;;
          "cron list"|"automations list")
            command_path="${candidate_path}"
            opts="--all --agent --query --json --url --port --token --password --timeout --expect-final"
            value_options="--container --profile --log-level --agent --query --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --agent --query --url --port --token --password --timeout"
            ;;
          "cron add"|"cron create"|"automations add"|"automations create")
            command_path="${candidate_path}"
            opts="--json --name --display-name --description --delete-after-run --keep-after-run --agent --session --session-key --wake --at --every --pacing-min --pacing-max --cron --on-exit --on-exit-cwd --stream-command --stream-cwd --stream-mode --stream-match --stream-batch-ms --stream-max-batch-bytes --tz --stagger --exact --trigger-script --trigger-once --system-event --message --script --script-timeout-seconds --script-tool-budget --command --command-argv --command-cwd --command-env --command-input --thinking --model --fallbacks --timeout-seconds --no-output-timeout-seconds --output-max-bytes --light-context --tools --announce --deliver --no-deliver --webhook --channel --to --thread-id --account --best-effort-deliver --declaration-key --disabled --url --port --token --password --timeout --expect-final"
            value_options="--container --profile --log-level --name --display-name --description --agent --session --session-key --wake --at --every --pacing-min --pacing-max --cron --on-exit --on-exit-cwd --stream-command --stream-cwd --stream-mode --stream-match --stream-batch-ms --stream-max-batch-bytes --tz --stagger --trigger-script --system-event --message --script --script-timeout-seconds --script-tool-budget --command --command-argv --command-cwd --command-env --command-input --thinking --model --fallbacks --timeout-seconds --no-output-timeout-seconds --output-max-bytes --tools --webhook --channel --to --thread-id --account --declaration-key --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --name --display-name --description --agent --session --session-key --wake --at --every --pacing-min --pacing-max --cron --on-exit --on-exit-cwd --stream-command --stream-cwd --stream-mode --stream-match --stream-batch-ms --stream-max-batch-bytes --tz --stagger --trigger-script --system-event --message --script --script-timeout-seconds --script-tool-budget --command --command-argv --command-cwd --command-env --command-input --thinking --model --fallbacks --timeout-seconds --no-output-timeout-seconds --output-max-bytes --tools --webhook --channel --to --thread-id --account --declaration-key --url --port --token --password --timeout"
            ;;
          "cron rm"|"cron remove"|"cron delete"|"automations rm"|"automations remove"|"automations delete")
            command_path="${candidate_path}"
            opts="--json --url --port --token --password --timeout --expect-final"
            value_options="--container --profile --log-level --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --url --port --token --password --timeout"
            ;;
          "cron enable"|"automations enable")
            command_path="${candidate_path}"
            opts="--json --url --port --token --password --timeout --expect-final"
            value_options="--container --profile --log-level --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --url --port --token --password --timeout"
            ;;
          "cron disable"|"automations disable")
            command_path="${candidate_path}"
            opts="--json --url --port --token --password --timeout --expect-final"
            value_options="--container --profile --log-level --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --url --port --token --password --timeout"
            ;;
          "cron get"|"automations get")
            command_path="${candidate_path}"
            opts="--json --url --port --token --password --timeout --expect-final"
            value_options="--container --profile --log-level --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --url --port --token --password --timeout"
            ;;
          "cron show"|"automations show")
            command_path="${candidate_path}"
            opts="--json --url --port --token --password --timeout --expect-final"
            value_options="--container --profile --log-level --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --url --port --token --password --timeout"
            ;;
          "cron runs"|"automations runs")
            command_path="${candidate_path}"
            opts="--json --id --all --run-id --status --delivery-status --query --offset --sort --limit --url --port --token --password --timeout --expect-final"
            value_options="--container --profile --log-level --id --run-id --status --delivery-status --query --offset --sort --limit --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --id --run-id --status --delivery-status --query --offset --sort --limit --url --port --token --password --timeout"
            ;;
          "cron run"|"automations run")
            command_path="${candidate_path}"
            opts="--json --due --wait --wait-timeout --poll-interval --url --port --token --password --timeout --expect-final"
            value_options="--container --profile --log-level --wait-timeout --poll-interval --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --wait-timeout --poll-interval --url --port --token --password --timeout"
            ;;
          "cron scratch"|"automations scratch")
            command_path="${candidate_path}"
            opts="--json --set --file --unset --expected-revision --url --port --token --password --timeout --expect-final"
            value_options="--container --profile --log-level --set --file --expected-revision --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --set --file --expected-revision --url --port --token --password --timeout"
            ;;
          "cron edit"|"automations edit")
            command_path="${candidate_path}"
            opts="--json --name --display-name --description --delete-after-run --keep-after-run --agent --session --session-key --wake --at --every --pacing-min --pacing-max --cron --on-exit --on-exit-cwd --stream-command --stream-cwd --stream-mode --stream-match --stream-batch-ms --stream-max-batch-bytes --tz --stagger --exact --trigger-script --trigger-once --system-event --message --script --script-timeout-seconds --script-tool-budget --command --command-argv --command-cwd --command-env --command-input --thinking --model --fallbacks --timeout-seconds --no-output-timeout-seconds --output-max-bytes --light-context --tools --announce --deliver --no-deliver --webhook --channel --to --thread-id --account --best-effort-deliver --clear-display-name --enable --disable --clear-agent --clear-session-key --clear-pacing --clear-trigger --clear-thinking --clear-fallbacks --clear-model --no-light-context --clear-tools --clear-channel --clear-to --clear-thread-id --clear-account --no-best-effort-deliver --failure-alert --no-failure-alert --failure-alert-after --failure-alert-channel --failure-alert-to --failure-alert-cooldown --failure-alert-include-skipped --failure-alert-exclude-skipped --failure-alert-mode --failure-alert-account-id --url --port --token --password --timeout --expect-final"
            value_options="--container --profile --log-level --name --display-name --description --agent --session --session-key --wake --at --every --pacing-min --pacing-max --cron --on-exit --on-exit-cwd --stream-command --stream-cwd --stream-mode --stream-match --stream-batch-ms --stream-max-batch-bytes --tz --stagger --trigger-script --system-event --message --script --script-timeout-seconds --script-tool-budget --command --command-argv --command-cwd --command-env --command-input --thinking --model --fallbacks --timeout-seconds --no-output-timeout-seconds --output-max-bytes --tools --webhook --channel --to --thread-id --account --failure-alert-after --failure-alert-channel --failure-alert-to --failure-alert-cooldown --failure-alert-mode --failure-alert-account-id --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --name --display-name --description --agent --session --session-key --wake --at --every --pacing-min --pacing-max --cron --on-exit --on-exit-cwd --stream-command --stream-cwd --stream-mode --stream-match --stream-batch-ms --stream-max-batch-bytes --tz --stagger --trigger-script --system-event --message --script --script-timeout-seconds --script-tool-budget --command --command-argv --command-cwd --command-env --command-input --thinking --model --fallbacks --timeout-seconds --no-output-timeout-seconds --output-max-bytes --tools --webhook --channel --to --thread-id --account --failure-alert-after --failure-alert-channel --failure-alert-to --failure-alert-cooldown --failure-alert-mode --failure-alert-account-id --url --port --token --password --timeout"
            ;;
          "dns")
            command_path="${candidate_path}"
            opts="setup"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "dns setup")
            command_path="${candidate_path}"
            opts="--domain --apply"
            value_options="--container --profile --log-level --domain"
            required_value_options="--container --profile --log-level --domain"
            ;;
          "docs")
            command_path="${candidate_path}"
            opts="--json --limit"
            value_options="--container --profile --log-level --limit"
            required_value_options="--container --profile --log-level --limit"
            ;;
          "proxy")
            command_path="${candidate_path}"
            opts="blob coverage purge query run sessions start validate"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "proxy start")
            command_path="${candidate_path}"
            opts="--host --port"
            value_options="--container --profile --log-level --host --port"
            required_value_options="--container --profile --log-level --host --port"
            ;;
          "proxy run")
            command_path="${candidate_path}"
            opts="--host --port"
            value_options="--container --profile --log-level --host --port"
            required_value_options="--container --profile --log-level --host --port"
            ;;
          "proxy validate")
            command_path="${candidate_path}"
            opts="--json --proxy-url --proxy-ca-file --allowed-url --denied-url --apns-reachable --apns-authority --timeout-ms"
            value_options="--container --profile --log-level --proxy-url --proxy-ca-file --allowed-url --denied-url --apns-authority --timeout-ms"
            required_value_options="--container --profile --log-level --proxy-url --proxy-ca-file --allowed-url --denied-url --apns-authority --timeout-ms"
            ;;
          "proxy coverage")
            command_path="${candidate_path}"
            opts="--json"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "proxy sessions")
            command_path="${candidate_path}"
            opts="--json --limit"
            value_options="--container --profile --log-level --limit"
            required_value_options="--container --profile --log-level --limit"
            ;;
          "proxy query")
            command_path="${candidate_path}"
            opts="--preset --json --session"
            value_options="--container --profile --log-level --preset --session"
            required_value_options="--container --profile --log-level --preset --session"
            ;;
          "proxy blob")
            command_path="${candidate_path}"
            opts="--id"
            value_options="--container --profile --log-level --id"
            required_value_options="--container --profile --log-level --id"
            ;;
          "proxy purge")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "hooks")
            command_path="${candidate_path}"
            opts="check disable enable info install list update --agent --json"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "hooks list")
            command_path="${candidate_path}"
            opts="--agent --eligible --json -v --verbose"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "hooks info")
            command_path="${candidate_path}"
            opts="--agent --json"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "hooks check")
            command_path="${candidate_path}"
            opts="--agent --json"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "hooks enable")
            command_path="${candidate_path}"
            opts="--agent"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "hooks disable")
            command_path="${candidate_path}"
            opts="--agent"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "hooks relay")
            command_path="${candidate_path}"
            opts="--provider --relay-id --state-db --generation --event --pre-tool-use-unavailable --timeout"
            value_options="--container --profile --log-level --agent --provider --relay-id --state-db --generation --event --pre-tool-use-unavailable --timeout"
            required_value_options="--container --profile --log-level --agent --provider --relay-id --state-db --generation --event --pre-tool-use-unavailable --timeout"
            ;;
          "hooks install")
            command_path="${candidate_path}"
            opts="-l --link --pin --force --acknowledge-install-policy-warning"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "hooks update")
            command_path="${candidate_path}"
            opts="--all --dry-run --acknowledge-install-policy-warning"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "webhooks")
            command_path="${candidate_path}"
            opts="gmail"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "webhooks gmail")
            command_path="${candidate_path}"
            opts="run setup"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "webhooks gmail setup")
            command_path="${candidate_path}"
            opts="--account --project --topic --subscription --label --hook-url --hook-token --push-token --bind --port --path --include-body --max-bytes --renew-minutes --tailscale --tailscale-path --tailscale-target --push-endpoint --json"
            value_options="--container --profile --log-level --account --project --topic --subscription --label --hook-url --hook-token --push-token --bind --port --path --max-bytes --renew-minutes --tailscale --tailscale-path --tailscale-target --push-endpoint"
            required_value_options="--container --profile --log-level --account --project --topic --subscription --label --hook-url --hook-token --push-token --bind --port --path --max-bytes --renew-minutes --tailscale --tailscale-path --tailscale-target --push-endpoint"
            ;;
          "webhooks gmail run")
            command_path="${candidate_path}"
            opts="--account --topic --subscription --label --hook-url --hook-token --push-token --bind --port --path --include-body --max-bytes --renew-minutes --tailscale --tailscale-path --tailscale-target"
            value_options="--container --profile --log-level --account --topic --subscription --label --hook-url --hook-token --push-token --bind --port --path --max-bytes --renew-minutes --tailscale --tailscale-path --tailscale-target"
            required_value_options="--container --profile --log-level --account --topic --subscription --label --hook-url --hook-token --push-token --bind --port --path --max-bytes --renew-minutes --tailscale --tailscale-path --tailscale-target"
            ;;
          "qr")
            command_path="${candidate_path}"
            opts="--remote --url --public-url --token --password --limited --voice-node --setup-code-only --no-ascii --json"
            value_options="--container --profile --log-level --url --public-url --token --password"
            required_value_options="--container --profile --log-level --url --public-url --token --password"
            ;;
          "clawbot")
            command_path="${candidate_path}"
            opts="qr"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "clawbot qr")
            command_path="${candidate_path}"
            opts="--remote --url --public-url --token --password --limited --voice-node --setup-code-only --no-ascii --json"
            value_options="--container --profile --log-level --url --public-url --token --password"
            required_value_options="--container --profile --log-level --url --public-url --token --password"
            ;;
          "pairing")
            command_path="${candidate_path}"
            opts="approve list"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "pairing list")
            command_path="${candidate_path}"
            opts="--channel --account --json"
            value_options="--container --profile --log-level --channel --account"
            required_value_options="--container --profile --log-level --channel --account"
            ;;
          "pairing approve")
            command_path="${candidate_path}"
            opts="--channel --account --notify"
            value_options="--container --profile --log-level --channel --account"
            required_value_options="--container --profile --log-level --channel --account"
            ;;
          "plugins")
            command_path="${candidate_path}"
            opts="build disable doctor enable init inspect info install list marketplace pack registry reload search uninstall update validate"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "plugins list")
            command_path="${candidate_path}"
            opts="--json --enabled --verbose"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "plugins search")
            command_path="${candidate_path}"
            opts="--limit --json"
            value_options="--container --profile --log-level --limit"
            required_value_options="--container --profile --log-level --limit"
            ;;
          "plugins inspect"|"plugins info")
            command_path="${candidate_path}"
            opts="--all --runtime --json"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "plugins enable")
            command_path="${candidate_path}"
            opts="--accept-capabilities"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "plugins disable")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "plugins reload")
            command_path="${candidate_path}"
            opts="--accept-capabilities --wait --json"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "plugins uninstall")
            command_path="${candidate_path}"
            opts="--keep-files --keep-config --force --dry-run"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "plugins install")
            command_path="${candidate_path}"
            opts="-l --link --force --pin --no-enable --accept-capabilities --dangerously-force-unsafe-install --acknowledge-install-policy-warning --marketplace"
            value_options="--container --profile --log-level --marketplace"
            required_value_options="--container --profile --log-level --marketplace"
            ;;
          "plugins update")
            command_path="${candidate_path}"
            opts="--all --dry-run --accept-capabilities --dangerously-force-unsafe-install --acknowledge-install-policy-warning"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "plugins registry")
            command_path="${candidate_path}"
            opts="--json --refresh"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "plugins doctor")
            command_path="${candidate_path}"
            opts="--json"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "plugins build")
            command_path="${candidate_path}"
            opts="--root --entry --check"
            value_options="--container --profile --log-level --root --entry"
            required_value_options="--container --profile --log-level --root --entry"
            ;;
          "plugins validate")
            command_path="${candidate_path}"
            opts="--root --entry --json"
            value_options="--container --profile --log-level --root --entry"
            required_value_options="--container --profile --log-level --root --entry"
            ;;
          "plugins pack")
            command_path="${candidate_path}"
            opts="--root --out --json"
            value_options="--container --profile --log-level --root --out"
            required_value_options="--container --profile --log-level --root --out"
            ;;
          "plugins init")
            command_path="${candidate_path}"
            opts="--directory --name --type --force"
            value_options="--container --profile --log-level --directory --name --type"
            required_value_options="--container --profile --log-level --directory --name --type"
            ;;
          "plugins marketplace")
            command_path="${candidate_path}"
            opts="entries list refresh"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "plugins marketplace entries")
            command_path="${candidate_path}"
            opts="--feed-profile --feed-url --offline --json"
            value_options="--container --profile --log-level --feed-profile --feed-url"
            required_value_options="--container --profile --log-level --feed-profile --feed-url"
            ;;
          "plugins marketplace refresh")
            command_path="${candidate_path}"
            opts="--feed-profile --feed-url --expected-sha256 --json"
            value_options="--container --profile --log-level --feed-profile --feed-url --expected-sha256"
            required_value_options="--container --profile --log-level --feed-profile --feed-url --expected-sha256"
            ;;
          "plugins marketplace list")
            command_path="${candidate_path}"
            opts="--json"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "channels")
            command_path="${candidate_path}"
            opts="add capabilities dead-letters list login logout logs remove resolve status --agent"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "channels list")
            command_path="${candidate_path}"
            opts="--all --json"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "channels status")
            command_path="${candidate_path}"
            opts="--channel --probe --timeout --json"
            value_options="--container --profile --log-level --agent --channel --timeout"
            required_value_options="--container --profile --log-level --agent --channel --timeout"
            ;;
          "channels capabilities")
            command_path="${candidate_path}"
            opts="--agent --channel --account --target --timeout --json"
            value_options="--container --profile --log-level --agent --channel --account --target --timeout"
            required_value_options="--container --profile --log-level --agent --channel --account --target --timeout"
            ;;
          "channels resolve")
            command_path="${candidate_path}"
            opts="--channel --account --agent --kind --json"
            value_options="--container --profile --log-level --channel --account --agent --kind"
            required_value_options="--container --profile --log-level --channel --account --agent --kind"
            ;;
          "channels logs")
            command_path="${candidate_path}"
            opts="--channel --lines --json"
            value_options="--container --profile --log-level --agent --channel --lines"
            required_value_options="--container --profile --log-level --agent --channel --lines"
            ;;
          "channels dead-letters")
            command_path="${candidate_path}"
            opts="list resubmit --account"
            value_options="--container --profile --log-level --agent --account"
            required_value_options="--container --profile --log-level --agent --account"
            ;;
          "channels dead-letters list")
            command_path="${candidate_path}"
            opts="--channel --account --limit --json"
            value_options="--container --profile --log-level --agent --channel --account --limit"
            required_value_options="--container --profile --log-level --agent --channel --account --limit"
            ;;
          "channels dead-letters resubmit")
            command_path="${candidate_path}"
            opts="--channel --account --json"
            value_options="--container --profile --log-level --agent --channel --account"
            required_value_options="--container --profile --log-level --agent --channel --account"
            ;;
          "channels add")
            command_path="${candidate_path}"
            opts="--channel --agent --account --name --advertised-url --peer-name --peer-token --token --token-file --use-env --audience-type --audience --webhook-path --webhook-url --private-key --relay-urls --relay-url --bot-token --http-url --base-url --url --secret --password --secret-file --homeserver --user-id --access-token --device-name --avatar-url --initial-sync-limit --proxy --dangerously-allow-private-network --profile --channel-access-token --channel-secret --code --workspace --default-to --allow-from --agent-activity --account-sid --auth-token --from-number --messaging-service-sid --public-webhook-url --dm-policy --ship --group-channels --dm-allowlist --auto-discover-channels --no-auto-discover-channels --owner-ship --cli-path --db-path --service --region --host --port --tls --nick --username --realname --channels --signal-number --signal-transport --http-host --http-port --app-token --user-token --signing-secret --identity --mode --auth-dir"
            value_options="--container --log-level --channel --agent --account --name --advertised-url --peer-name --peer-token --token --token-file --audience-type --audience --webhook-path --webhook-url --private-key --relay-urls --relay-url --bot-token --http-url --base-url --url --secret --password --secret-file --homeserver --user-id --access-token --device-name --avatar-url --initial-sync-limit --proxy --profile --channel-access-token --channel-secret --code --workspace --default-to --allow-from --account-sid --auth-token --from-number --messaging-service-sid --public-webhook-url --dm-policy --ship --group-channels --dm-allowlist --owner-ship --cli-path --db-path --service --region --host --port --nick --username --realname --channels --signal-number --signal-transport --http-host --http-port --app-token --user-token --signing-secret --identity --mode --auth-dir"
            required_value_options="--container --log-level --channel --agent --account --name --advertised-url --peer-name --peer-token --token --token-file --audience-type --audience --webhook-path --webhook-url --private-key --relay-urls --relay-url --bot-token --http-url --base-url --url --secret --password --secret-file --homeserver --user-id --access-token --device-name --avatar-url --initial-sync-limit --proxy --profile --channel-access-token --channel-secret --code --workspace --default-to --allow-from --account-sid --auth-token --from-number --messaging-service-sid --public-webhook-url --dm-policy --ship --group-channels --dm-allowlist --owner-ship --cli-path --db-path --service --region --host --port --nick --username --realname --channels --signal-number --signal-transport --http-host --http-port --app-token --user-token --signing-secret --identity --mode --auth-dir"
            ;;
          "channels remove")
            command_path="${candidate_path}"
            opts="--agent --channel --account --delete"
            value_options="--container --profile --log-level --agent --channel --account"
            required_value_options="--container --profile --log-level --agent --channel --account"
            ;;
          "channels login")
            command_path="${candidate_path}"
            opts="--agent --channel --account --verbose"
            value_options="--container --profile --log-level --agent --channel --account"
            required_value_options="--container --profile --log-level --agent --channel --account"
            ;;
          "channels logout")
            command_path="${candidate_path}"
            opts="--agent --channel --account"
            value_options="--container --profile --log-level --agent --channel --account"
            required_value_options="--container --profile --log-level --agent --channel --account"
            ;;
          "directory")
            command_path="${candidate_path}"
            opts="groups peers self"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "directory self")
            command_path="${candidate_path}"
            opts="--channel --account --json"
            value_options="--container --profile --log-level --channel --account"
            required_value_options="--container --profile --log-level --channel --account"
            ;;
          "directory peers")
            command_path="${candidate_path}"
            opts="list"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "directory peers list")
            command_path="${candidate_path}"
            opts="--channel --account --json --query --limit"
            value_options="--container --profile --log-level --channel --account --query --limit"
            required_value_options="--container --profile --log-level --channel --account --query --limit"
            ;;
          "directory groups")
            command_path="${candidate_path}"
            opts="list members"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "directory groups list")
            command_path="${candidate_path}"
            opts="--channel --account --json --query --limit"
            value_options="--container --profile --log-level --channel --account --query --limit"
            required_value_options="--container --profile --log-level --channel --account --query --limit"
            ;;
          "directory groups members")
            command_path="${candidate_path}"
            opts="--group-id --channel --account --json --limit"
            value_options="--container --profile --log-level --group-id --channel --account --limit"
            required_value_options="--container --profile --log-level --group-id --channel --account --limit"
            ;;
          "security")
            command_path="${candidate_path}"
            opts="audit"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "security audit")
            command_path="${candidate_path}"
            opts="--deep --auth --token --password --fix --json"
            value_options="--container --profile --log-level --auth --token --password"
            required_value_options="--container --profile --log-level --auth --token --password"
            ;;
          "secrets")
            command_path="${candidate_path}"
            opts="apply audit configure reload store"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "secrets store")
            command_path="${candidate_path}"
            opts="get import list rm set"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "secrets store list")
            command_path="${candidate_path}"
            opts="--scope --json --plain"
            value_options="--container --profile --log-level --scope"
            required_value_options="--container --profile --log-level --scope"
            ;;
          "secrets store set")
            command_path="${candidate_path}"
            opts="--value --value-file --kind --allow-host --clear-allowed-hosts --scope --dry-run"
            value_options="--container --profile --log-level --value --value-file --kind --allow-host --scope"
            required_value_options="--container --profile --log-level --value --value-file --kind --allow-host --scope"
            ;;
          "secrets store get")
            command_path="${candidate_path}"
            opts="--scope --json --plain"
            value_options="--container --profile --log-level --scope"
            required_value_options="--container --profile --log-level --scope"
            ;;
          "secrets store rm")
            command_path="${candidate_path}"
            opts="--scope --dry-run --yes"
            value_options="--container --profile --log-level --scope"
            required_value_options="--container --profile --log-level --scope"
            ;;
          "secrets store import")
            command_path="${candidate_path}"
            opts="--from --kind --scope --dry-run --yes"
            value_options="--container --profile --log-level --from --kind --scope"
            required_value_options="--container --profile --log-level --from --kind --scope"
            ;;
          "secrets reload")
            command_path="${candidate_path}"
            opts="--json --url --port --token --password --timeout --expect-final"
            value_options="--container --profile --log-level --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --url --port --token --password --timeout"
            ;;
          "secrets audit")
            command_path="${candidate_path}"
            opts="--check --allow-exec --json"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "secrets configure")
            command_path="${candidate_path}"
            opts="--apply --yes --providers-only --skip-provider-setup --agent --allow-exec --plan-out --json"
            value_options="--container --profile --log-level --agent --plan-out"
            required_value_options="--container --profile --log-level --agent --plan-out"
            ;;
          "secrets apply")
            command_path="${candidate_path}"
            opts="--from --dry-run --allow-exec --json"
            value_options="--container --profile --log-level --from"
            required_value_options="--container --profile --log-level --from"
            ;;
          "skills")
            command_path="${candidate_path}"
            opts="check curator info install library list search update verify workshop --agent --json"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "skills library")
            command_path="${candidate_path}"
            opts="attach create detach disable enable import list read refresh remove rollback share transfer unshare update --url --port --token --password --timeout --expect-final --json"
            value_options="--container --profile --log-level --agent --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --agent --url --port --token --password --timeout"
            ;;
          "skills library list")
            command_path="${candidate_path}"
            opts="--url --port --token --password --timeout --expect-final --json --scope --session"
            value_options="--container --profile --log-level --agent --url --port --token --password --timeout --scope --session"
            required_value_options="--container --profile --log-level --agent --url --port --token --password --timeout --scope --session"
            ;;
          "skills library read")
            command_path="${candidate_path}"
            opts="--url --port --token --password --timeout --expect-final --json --revision --session"
            value_options="--container --profile --log-level --agent --url --port --token --password --timeout --revision --session"
            required_value_options="--container --profile --log-level --agent --url --port --token --password --timeout --revision --session"
            ;;
          "skills library create")
            command_path="${candidate_path}"
            opts="--url --port --token --password --timeout --expect-final --json --slug"
            value_options="--container --profile --log-level --agent --url --port --token --password --timeout --slug"
            required_value_options="--container --profile --log-level --agent --url --port --token --password --timeout --slug"
            ;;
          "skills library update")
            command_path="${candidate_path}"
            opts="--url --port --token --password --timeout --expect-final --json --expected-revision --slug --delete-file"
            value_options="--container --profile --log-level --agent --url --port --token --password --timeout --expected-revision --slug --delete-file"
            required_value_options="--container --profile --log-level --agent --url --port --token --password --timeout --expected-revision --slug --delete-file"
            ;;
          "skills library import")
            command_path="${candidate_path}"
            opts="--url --port --token --password --timeout --expect-final --json --slug --clawhub --version"
            value_options="--container --profile --log-level --agent --url --port --token --password --timeout --slug --version"
            required_value_options="--container --profile --log-level --agent --url --port --token --password --timeout --slug --version"
            ;;
          "skills library remove")
            command_path="${candidate_path}"
            opts="--url --port --token --password --timeout --expect-final --json --expected-revision"
            value_options="--container --profile --log-level --agent --url --port --token --password --timeout --expected-revision"
            required_value_options="--container --profile --log-level --agent --url --port --token --password --timeout --expected-revision"
            ;;
          "skills library share")
            command_path="${candidate_path}"
            opts="--url --port --token --password --timeout --expect-final --json --expected-revision"
            value_options="--container --profile --log-level --agent --url --port --token --password --timeout --expected-revision"
            required_value_options="--container --profile --log-level --agent --url --port --token --password --timeout --expected-revision"
            ;;
          "skills library unshare")
            command_path="${candidate_path}"
            opts="--url --port --token --password --timeout --expect-final --json --expected-revision"
            value_options="--container --profile --log-level --agent --url --port --token --password --timeout --expected-revision"
            required_value_options="--container --profile --log-level --agent --url --port --token --password --timeout --expected-revision"
            ;;
          "skills library transfer")
            command_path="${candidate_path}"
            opts="--url --port --token --password --timeout --expect-final --json --expected-revision"
            value_options="--container --profile --log-level --agent --url --port --token --password --timeout --expected-revision"
            required_value_options="--container --profile --log-level --agent --url --port --token --password --timeout --expected-revision"
            ;;
          "skills library enable")
            command_path="${candidate_path}"
            opts="--url --port --token --password --timeout --expect-final --json --expected-revision"
            value_options="--container --profile --log-level --agent --url --port --token --password --timeout --expected-revision"
            required_value_options="--container --profile --log-level --agent --url --port --token --password --timeout --expected-revision"
            ;;
          "skills library disable")
            command_path="${candidate_path}"
            opts="--url --port --token --password --timeout --expect-final --json --expected-revision"
            value_options="--container --profile --log-level --agent --url --port --token --password --timeout --expected-revision"
            required_value_options="--container --profile --log-level --agent --url --port --token --password --timeout --expected-revision"
            ;;
          "skills library rollback")
            command_path="${candidate_path}"
            opts="--url --port --token --password --timeout --expect-final --json --expected-revision --revision"
            value_options="--container --profile --log-level --agent --url --port --token --password --timeout --expected-revision --revision"
            required_value_options="--container --profile --log-level --agent --url --port --token --password --timeout --expected-revision --revision"
            ;;
          "skills library attach")
            command_path="${candidate_path}"
            opts="--url --port --token --password --timeout --expect-final --json --session --skill-id --revision"
            value_options="--container --profile --log-level --agent --url --port --token --password --timeout --session --skill-id --revision"
            required_value_options="--container --profile --log-level --agent --url --port --token --password --timeout --session --skill-id --revision"
            ;;
          "skills library detach")
            command_path="${candidate_path}"
            opts="--url --port --token --password --timeout --expect-final --json --session --skill-id"
            value_options="--container --profile --log-level --agent --url --port --token --password --timeout --session --skill-id"
            required_value_options="--container --profile --log-level --agent --url --port --token --password --timeout --session --skill-id"
            ;;
          "skills library refresh")
            command_path="${candidate_path}"
            opts="--url --port --token --password --timeout --expect-final --json --session --skill-id"
            value_options="--container --profile --log-level --agent --url --port --token --password --timeout --session --skill-id"
            required_value_options="--container --profile --log-level --agent --url --port --token --password --timeout --session --skill-id"
            ;;
          "skills search")
            command_path="${candidate_path}"
            opts="--limit --json"
            value_options="--container --profile --log-level --agent --limit"
            required_value_options="--container --profile --log-level --agent --limit"
            ;;
          "skills install")
            command_path="${candidate_path}"
            opts="--version --force --force-install --acknowledge-install-policy-warning --global --agent --as"
            value_options="--container --profile --log-level --version --agent --as"
            required_value_options="--container --profile --log-level --version --agent --as"
            ;;
          "skills update")
            command_path="${candidate_path}"
            opts="--all --force --force-install --acknowledge-install-policy-warning --global --agent"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "skills verify")
            command_path="${candidate_path}"
            opts="--version --tag --card --json --global --agent"
            value_options="--container --profile --log-level --version --tag --agent"
            required_value_options="--container --profile --log-level --version --tag --agent"
            ;;
          "skills curator")
            command_path="${candidate_path}"
            opts="pin restore status unpin --json"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "skills curator status")
            command_path="${candidate_path}"
            opts="--json"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "skills curator pin")
            command_path="${candidate_path}"
            opts="--json"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "skills curator unpin")
            command_path="${candidate_path}"
            opts="--json"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "skills curator restore")
            command_path="${candidate_path}"
            opts="--json"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "skills workshop")
            command_path="${candidate_path}"
            opts="apply evaluate inspect list propose-create propose-update quarantine reject revise --agent"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "skills workshop list")
            command_path="${candidate_path}"
            opts="--json --agent"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "skills workshop inspect")
            command_path="${candidate_path}"
            opts="--json --agent"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "skills workshop propose-create")
            command_path="${candidate_path}"
            opts="--name --description --proposal --proposal-dir --goal --evidence --json --agent"
            value_options="--container --profile --log-level --name --description --proposal --proposal-dir --goal --evidence --agent"
            required_value_options="--container --profile --log-level --name --description --proposal --proposal-dir --goal --evidence --agent"
            ;;
          "skills workshop propose-update")
            command_path="${candidate_path}"
            opts="--proposal --proposal-dir --description --goal --evidence --json --agent"
            value_options="--container --profile --log-level --proposal --proposal-dir --description --goal --evidence --agent"
            required_value_options="--container --profile --log-level --proposal --proposal-dir --description --goal --evidence --agent"
            ;;
          "skills workshop revise")
            command_path="${candidate_path}"
            opts="--proposal --proposal-dir --description --goal --evidence --json --agent"
            value_options="--container --profile --log-level --proposal --proposal-dir --description --goal --evidence --agent"
            required_value_options="--container --profile --log-level --proposal --proposal-dir --description --goal --evidence --agent"
            ;;
          "skills workshop evaluate")
            command_path="${candidate_path}"
            opts="--correlation-id --json --agent"
            value_options="--container --profile --log-level --correlation-id --agent"
            required_value_options="--container --profile --log-level --correlation-id --agent"
            ;;
          "skills workshop apply")
            command_path="${candidate_path}"
            opts="--json --agent"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "skills workshop reject")
            command_path="${candidate_path}"
            opts="--reason --json --agent"
            value_options="--container --profile --log-level --reason --agent"
            required_value_options="--container --profile --log-level --reason --agent"
            ;;
          "skills workshop quarantine")
            command_path="${candidate_path}"
            opts="--reason --json --agent"
            value_options="--container --profile --log-level --reason --agent"
            required_value_options="--container --profile --log-level --reason --agent"
            ;;
          "skills list")
            command_path="${candidate_path}"
            opts="--json --eligible -v --verbose --agent"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "skills info")
            command_path="${candidate_path}"
            opts="--json --agent"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "skills check")
            command_path="${candidate_path}"
            opts="--agent --json"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "update")
            command_path="${candidate_path}"
            opts="adopt-immutable cleanup recover repair status wizard --json --no-restart --dry-run --admission --channel --tag --timeout --drain-timeout --sha --yes --reapply-local-overrides --accept-capabilities"
            value_options="--container --profile --log-level --admission --channel --tag --timeout --drain-timeout --sha"
            required_value_options="--container --profile --log-level --admission --channel --tag --timeout --drain-timeout --sha"
            ;;
          "update adopt-immutable")
            command_path="${candidate_path}"
            opts="--root --service --account --state-dir --config --runtime --profile --enable-activation --previous-updater-stopped --json"
            value_options="--container --log-level --admission --channel --tag --timeout --drain-timeout --sha --root --service --account --state-dir --config --runtime --profile"
            required_value_options="--container --log-level --admission --channel --tag --timeout --drain-timeout --sha --root --service --account --state-dir --config --runtime --profile"
            ;;
          "update recover")
            command_path="${candidate_path}"
            opts="--root --timeout --drain-timeout --json"
            value_options="--container --profile --log-level --admission --channel --tag --sha --root --timeout --drain-timeout"
            required_value_options="--container --profile --log-level --admission --channel --tag --sha --root --timeout --drain-timeout"
            ;;
          "update admit")
            command_path="${candidate_path}"
            opts="--context"
            value_options="--container --profile --log-level --admission --channel --tag --timeout --drain-timeout --sha --context"
            required_value_options="--container --profile --log-level --admission --channel --tag --timeout --drain-timeout --sha --context"
            ;;
          "update cleanup")
            command_path="${candidate_path}"
            opts="--dry-run --json --yes"
            value_options="--container --profile --log-level --admission --channel --tag --timeout --drain-timeout --sha"
            required_value_options="--container --profile --log-level --admission --channel --tag --timeout --drain-timeout --sha"
            ;;
          "update repair")
            command_path="${candidate_path}"
            opts="--json --channel --timeout --yes --accept-capabilities --no-restart"
            value_options="--container --profile --log-level --admission --tag --drain-timeout --sha --channel --timeout"
            required_value_options="--container --profile --log-level --admission --tag --drain-timeout --sha --channel --timeout"
            ;;
          "update finalize")
            command_path="${candidate_path}"
            opts="--json --channel --timeout --yes --accept-capabilities --no-restart"
            value_options="--container --profile --log-level --admission --tag --drain-timeout --sha --channel --timeout"
            required_value_options="--container --profile --log-level --admission --tag --drain-timeout --sha --channel --timeout"
            ;;
          "update migration-plan")
            command_path="${candidate_path}"
            opts="--snapshot-home --snapshot-config --snapshot-state --dry-run --json"
            value_options="--container --profile --log-level --admission --channel --tag --timeout --drain-timeout --sha --snapshot-home --snapshot-config --snapshot-state"
            required_value_options="--container --profile --log-level --admission --channel --tag --timeout --drain-timeout --sha --snapshot-home --snapshot-config --snapshot-state"
            ;;
          "update wizard")
            command_path="${candidate_path}"
            opts="--accept-capabilities --timeout"
            value_options="--container --profile --log-level --admission --channel --tag --drain-timeout --sha --timeout"
            required_value_options="--container --profile --log-level --admission --channel --tag --drain-timeout --sha --timeout"
            ;;
          "update status")
            command_path="${candidate_path}"
            opts="--json --timeout"
            value_options="--container --profile --log-level --admission --channel --tag --drain-timeout --sha --timeout"
            required_value_options="--container --profile --log-level --admission --channel --tag --drain-timeout --sha --timeout"
            ;;
          "browser")
            command_path="${candidate_path}"
            opts="batch click click-coords close console cookie-sync cookies create-profile delete-profile dialog doctor download drag errors evaluate extension fill focus highlight hover import-profile navigate open pdf press profiles requests reset-profile resize responsebody screenshot scrollintoview select set snapshot start status stop storage system-profiles tab tabs trace type upload wait waitfordownload --browser-profile --json --url --port --token --password --timeout --expect-final"
            value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            ;;
          "browser status")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            ;;
          "browser start")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            ;;
          "browser stop")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            ;;
          "browser reset-profile")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            ;;
          "browser tabs")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            ;;
          "browser tab")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            ;;
          "browser open")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            ;;
          "browser focus")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            ;;
          "browser close")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            ;;
          "browser profiles")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            ;;
          "browser system-profiles")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            ;;
          "browser import-profile")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            ;;
          "browser create-profile")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            ;;
          "browser delete-profile")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            ;;
          "browser doctor")
            command_path="${candidate_path}"
            opts="--deep"
            value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            ;;
          "browser cookie-sync")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            ;;
          "browser screenshot")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            ;;
          "browser snapshot")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            ;;
          "browser navigate")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            ;;
          "browser resize")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            ;;
          "browser click")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            ;;
          "browser click-coords")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            ;;
          "browser type")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            ;;
          "browser press")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            ;;
          "browser hover")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            ;;
          "browser scrollintoview")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            ;;
          "browser drag")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            ;;
          "browser select")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            ;;
          "browser upload")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            ;;
          "browser waitfordownload")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            ;;
          "browser download")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            ;;
          "browser dialog")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            ;;
          "browser fill")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            ;;
          "browser wait")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            ;;
          "browser evaluate")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            ;;
          "browser batch")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            ;;
          "browser console")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            ;;
          "browser pdf")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            ;;
          "browser responsebody")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            ;;
          "browser highlight")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            ;;
          "browser errors")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            ;;
          "browser requests")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            ;;
          "browser trace")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            ;;
          "browser cookies")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            ;;
          "browser storage")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            ;;
          "browser set")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            ;;
          "browser extension")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
            ;;
          "file-transfer")
            command_path="${candidate_path}"
            opts="approvals"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "file-transfer approvals")
            command_path="${candidate_path}"
            opts="migrate"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "file-transfer approvals migrate")
            command_path="${candidate_path}"
            opts="--dry-run --json"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "memory")
            command_path="${candidate_path}"
            opts="forget index promote promote-explain rem-backfill rem-harness reset search session-backfill status"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "memory status")
            command_path="${candidate_path}"
            opts="--agent --json --deep --index --fix --verbose"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "memory index")
            command_path="${candidate_path}"
            opts="--agent --force --verbose"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "memory reset")
            command_path="${candidate_path}"
            opts="--agent --yes"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "memory search")
            command_path="${candidate_path}"
            opts="--query --agent --max-results --min-score --json"
            value_options="--container --profile --log-level --query --agent --max-results --min-score"
            required_value_options="--container --profile --log-level --query --agent --max-results --min-score"
            ;;
          "memory forget")
            command_path="${candidate_path}"
            opts="--agent --session --hook-source --participant --since --dry-run --json"
            value_options="--container --profile --log-level --agent --session --hook-source --participant --since"
            required_value_options="--container --profile --log-level --agent --session --hook-source --participant --since"
            ;;
          "memory promote")
            command_path="${candidate_path}"
            opts="--agent --limit --min-score --min-recall-count --min-unique-queries --apply --include-promoted --json"
            value_options="--container --profile --log-level --agent --limit --min-score --min-recall-count --min-unique-queries"
            required_value_options="--container --profile --log-level --agent --limit --min-score --min-recall-count --min-unique-queries"
            ;;
          "memory promote-explain")
            command_path="${candidate_path}"
            opts="--agent --include-promoted --json"
            value_options="--container --profile --log-level --agent"
            required_value_options="--container --profile --log-level --agent"
            ;;
          "memory rem-harness")
            command_path="${candidate_path}"
            opts="--agent --path --grounded --include-promoted --json"
            value_options="--container --profile --log-level --agent --path"
            required_value_options="--container --profile --log-level --agent --path"
            ;;
          "memory rem-backfill")
            command_path="${candidate_path}"
            opts="--agent --path --rollback --stage-short-term --rollback-short-term --json"
            value_options="--container --profile --log-level --agent --path"
            required_value_options="--container --profile --log-level --agent --path"
            ;;
          "memory session-backfill")
            command_path="${candidate_path}"
            opts="--agent --from --to --limit-days --rem --apply --rollback --archive-files --json"
            value_options="--container --profile --log-level --agent --from --to --limit-days --archive-files"
            required_value_options="--container --profile --log-level --agent --from --to --limit-days --archive-files"
            ;;
          "policy")
            command_path="${candidate_path}"
            opts="check compare watch"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "policy compare")
            command_path="${candidate_path}"
            opts="--baseline --policy --agent --json"
            value_options="--container --profile --log-level --baseline --policy --agent"
            required_value_options="--container --profile --log-level --baseline --policy --agent"
            ;;
          "policy check")
            command_path="${candidate_path}"
            opts="--agent --json --severity-min"
            value_options="--container --profile --log-level --agent --severity-min"
            required_value_options="--container --profile --log-level --agent --severity-min"
            ;;
          "policy watch")
            command_path="${candidate_path}"
            opts="--agent --json --severity-min --interval-ms --once"
            value_options="--container --profile --log-level --agent --severity-min --interval-ms"
            required_value_options="--container --profile --log-level --agent --severity-min --interval-ms"
            ;;
          "workboard")
            command_path="${candidate_path}"
            opts="create dispatch list move show"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "workboard list")
            command_path="${candidate_path}"
            opts="--board --status --include-archived --json"
            value_options="--container --profile --log-level --board --status"
            required_value_options="--container --profile --log-level --board --status"
            ;;
          "workboard create")
            command_path="${candidate_path}"
            opts="--notes --status --priority --agent --board --labels --json"
            value_options="--container --profile --log-level --notes --status --priority --agent --board --labels"
            required_value_options="--container --profile --log-level --notes --status --priority --agent --board --labels"
            ;;
          "workboard show")
            command_path="${candidate_path}"
            opts="--json"
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
          "workboard move")
            command_path="${candidate_path}"
            opts="--status --json"
            value_options="--container --profile --log-level --status"
            required_value_options="--container --profile --log-level --status"
            ;;
          "workboard dispatch")
            command_path="${candidate_path}"
            opts="--board --max-starts --admin --json --url --port --token --password --timeout --expect-final"
            value_options="--container --profile --log-level --board --max-starts --url --port --token --password --timeout"
            required_value_options="--container --profile --log-level --board --max-starts --url --port --token --password --timeout"
            ;;
          "agentmail")
            command_path="${candidate_path}"
            opts=""
            value_options="--container --profile --log-level"
            required_value_options="--container --profile --log-level"
            ;;
        esac
    done

    if (( options_ended )); then
        for word in ${opts}; do
            [[ ${word} == -* ]] || literal_opts+=" ${word}"
        done
        opts="${literal_opts}"
    else

        choice_flag="${words[cword-1]}"
        choice_prefix="${cur}"
        choice_completion_prefix=""
        if [[ "${cur}" == --*=* ]]; then
            choice_flag="${cur%%=*}"
            choice_prefix="${cur#*=}"
            choice_completion_prefix="${choice_flag}="
        fi
        for short_group in "${choice_flag}" "${cur}"; do
            [[ "${short_group}" == -??* && "${short_group}" != --* ]] || continue
            short_group="${short_group#-}"
            for ((short_index = 0; short_index < ${#short_group}; short_index++)); do
                short_flag="-${short_group:short_index:1}"
                if [[ " ${value_options} " == *" ${short_flag} "* ]]; then
                    if [[ "${cur}" == "-${short_group}" ]]; then
                        choice_flag="${short_flag}"
                        choice_prefix="${short_group:short_index+1}"
                        choice_completion_prefix="-${short_group:0:short_index+1}"
                    elif ((short_index == ${#short_group} - 1)); then
                        choice_flag="${short_flag}"
                    fi
                    break
                fi
            done
        done

    case "${command_path}" in
        "completion")
            case "${choice_flag}" in
            "-s"|"--shell")
                local -a choice_values=(zsh bash powershell fish)
                local choice completion
                for choice in "${choice_values[@]}"; do
                    if [[ "${choice}" == "${choice_prefix}"* ]]; then
                        completion="${choice_completion_prefix}${choice}"
                        COMPREPLY+=("${completion#"${word_prefix}"}")
                    fi
                done
                if true; then
                    return
                fi
                ;;
            esac
            ;;
        "gateway install")
            case "${choice_flag}" in
            "--update-executor")
                local -a choice_values=(check run)
                local choice completion
                for choice in "${choice_values[@]}"; do
                    if [[ "${choice}" == "${choice_prefix}"* ]]; then
                        completion="${choice_completion_prefix}${choice}"
                        COMPREPLY+=("${completion#"${word_prefix}"}")
                    fi
                done
                if true; then
                    return
                fi
                ;;
            esac
            ;;
        "gateway stop")
            case "${choice_flag}" in
            "--update-executor")
                local -a choice_values=(check run)
                local choice completion
                for choice in "${choice_values[@]}"; do
                    if [[ "${choice}" == "${choice_prefix}"* ]]; then
                        completion="${choice_completion_prefix}${choice}"
                        COMPREPLY+=("${completion#"${word_prefix}"}")
                    fi
                done
                if true; then
                    return
                fi
                ;;
            esac
            ;;
        "gateway restart")
            case "${choice_flag}" in
            "--update-executor")
                local -a choice_values=(check run)
                local choice completion
                for choice in "${choice_values[@]}"; do
                    if [[ "${choice}" == "${choice_prefix}"* ]]; then
                        completion="${choice_completion_prefix}${choice}"
                        COMPREPLY+=("${completion#"${word_prefix}"}")
                    fi
                done
                if true; then
                    return
                fi
                ;;
            esac
            ;;
        "daemon install")
            case "${choice_flag}" in
            "--update-executor")
                local -a choice_values=(check run)
                local choice completion
                for choice in "${choice_values[@]}"; do
                    if [[ "${choice}" == "${choice_prefix}"* ]]; then
                        completion="${choice_completion_prefix}${choice}"
                        COMPREPLY+=("${completion#"${word_prefix}"}")
                    fi
                done
                if true; then
                    return
                fi
                ;;
            esac
            ;;
        "daemon stop")
            case "${choice_flag}" in
            "--update-executor")
                local -a choice_values=(check run)
                local choice completion
                for choice in "${choice_values[@]}"; do
                    if [[ "${choice}" == "${choice_prefix}"* ]]; then
                        completion="${choice_completion_prefix}${choice}"
                        COMPREPLY+=("${completion#"${word_prefix}"}")
                    fi
                done
                if true; then
                    return
                fi
                ;;
            esac
            ;;
        "daemon restart")
            case "${choice_flag}" in
            "--update-executor")
                local -a choice_values=(check run)
                local choice completion
                for choice in "${choice_values[@]}"; do
                    if [[ "${choice}" == "${choice_prefix}"* ]]; then
                        completion="${choice_completion_prefix}${choice}"
                        COMPREPLY+=("${completion#"${word_prefix}"}")
                    fi
                done
                if true; then
                    return
                fi
                ;;
            esac
            ;;
        "nodes notify")
            case "${choice_flag}" in
            "--priority")
                local -a choice_values=(passive active timeSensitive)
                local choice completion
                for choice in "${choice_values[@]}"; do
                    if [[ "${choice}" == "${choice_prefix}"* ]]; then
                        completion="${choice_completion_prefix}${choice}"
                        COMPREPLY+=("${completion#"${word_prefix}"}")
                    fi
                done
                if true; then
                    return
                fi
                ;;
            "--delivery")
                local -a choice_values=(system overlay auto)
                local choice completion
                for choice in "${choice_values[@]}"; do
                    if [[ "${choice}" == "${choice_prefix}"* ]]; then
                        completion="${choice_completion_prefix}${choice}"
                        COMPREPLY+=("${completion#"${word_prefix}"}")
                    fi
                done
                if true; then
                    return
                fi
                ;;
            esac
            ;;
        "cron runs"|"automations runs")
            case "${choice_flag}" in
            "--status")
                local -a choice_values=(all ok error skipped)
                local choice completion
                for choice in "${choice_values[@]}"; do
                    if [[ "${choice}" == "${choice_prefix}"* ]]; then
                        completion="${choice_completion_prefix}${choice}"
                        COMPREPLY+=("${completion#"${word_prefix}"}")
                    fi
                done
                if true; then
                    return
                fi
                ;;
            "--delivery-status")
                local -a choice_values=(delivered not-delivered unknown not-requested)
                local choice completion
                for choice in "${choice_values[@]}"; do
                    if [[ "${choice}" == "${choice_prefix}"* ]]; then
                        completion="${choice_completion_prefix}${choice}"
                        COMPREPLY+=("${completion#"${word_prefix}"}")
                    fi
                done
                if true; then
                    return
                fi
                ;;
            "--sort")
                local -a choice_values=(asc desc)
                local choice completion
                for choice in "${choice_values[@]}"; do
                    if [[ "${choice}" == "${choice_prefix}"* ]]; then
                        completion="${choice_completion_prefix}${choice}"
                        COMPREPLY+=("${completion#"${word_prefix}"}")
                    fi
                done
                if true; then
                    return
                fi
                ;;
            esac
            ;;
        "channels resolve")
            case "${choice_flag}" in
            "--kind")
                local -a choice_values=(auto user group channel)
                local choice completion
                for choice in "${choice_values[@]}"; do
                    if [[ "${choice}" == "${choice_prefix}"* ]]; then
                        completion="${choice_completion_prefix}${choice}"
                        COMPREPLY+=("${completion#"${word_prefix}"}")
                    fi
                done
                if true; then
                    return
                fi
                ;;
            esac
            ;;
        "skills library list")
            case "${choice_flag}" in
            "--scope")
                local -a choice_values=(mine team all)
                local choice completion
                for choice in "${choice_values[@]}"; do
                    if [[ "${choice}" == "${choice_prefix}"* ]]; then
                        completion="${choice_completion_prefix}${choice}"
                        COMPREPLY+=("${completion#"${word_prefix}"}")
                    fi
                done
                if true; then
                    return
                fi
                ;;
            esac
            ;;
    esac

    fi
    COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
    COMPREPLY=("${COMPREPLY[@]#"${word_prefix}"}")
}

complete -F _openclaw_completion openclaw

