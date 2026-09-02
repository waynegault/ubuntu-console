# ==============================================================================
# OpenClaw bash completions — GENERATED FILE, do not edit by hand.
# Regenerate with: tools/sync-openclaw-completion.sh
# Source: `openclaw completion --shell bash`
# ==============================================================================

_openclaw_completion() {
    local cur opts command_path candidate_path value_options word flag i
    local choice_flag choice_prefix choice_completion_prefix short_group short_flag short_index
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    opts="acp agent agents approvals exec-approvals attach audit backup browser channels clawbot completion config configure connect cron automations daemon dashboard database devices directory dns docs doctor exec-policy file-transfer fleet gateway health hooks infer capability logs mcp memory message migrate models node nodes onboard pairing plugins promos proxy qr reset resume sandbox secrets security sessions setup skills status system tasks telemetry transcripts triage tui terminal chat uninstall update users webhooks workboard worker worktrees -V --version --container --dev --profile --log-level --no-color"
    value_options="--container --profile --log-level"
    command_path=""

    for ((i = 1; i < COMP_CWORD; i++)); do
        word="${COMP_WORDS[i]}"
        if [[ ${word} == -* ]]; then
            flag="${word%%=*}"
            if [[ ${word} != *=* && " ${value_options} " == *" ${flag} "* ]]; then
                i=$((i + 1))
            fi
            continue
        fi

        if [[ -n "${command_path}" ]]; then
            candidate_path="${command_path} ${word}"
        else
            candidate_path="${word}"
        fi

        case "${candidate_path}" in
          "completion"|"setup"|"crestodian"|"onboard"|"onboard recommendations"|"onboard recommendations acknowledge"|"onboard recommendations refresh"|"configure"|"config"|"config get"|"config set"|"config patch"|"config unset"|"config file"|"config schema"|"config validate"|"backup"|"backup create"|"backup verify"|"backup restore"|"backup sqlite"|"backup sqlite create"|"backup sqlite list"|"backup sqlite verify"|"backup sqlite restore"|"backup git"|"backup git init"|"backup git create"|"backup git log"|"backup git verify"|"backup git restore"|"backup enable"|"backup disable"|"database"|"database preflight"|"database ownership"|"database ownership status"|"database ownership claim"|"migrate"|"migrate list"|"migrate plan"|"migrate apply"|"doctor"|"triage"|"dashboard"|"reset"|"uninstall"|"message"|"message send"|"message broadcast"|"message poll"|"message react"|"message reactions"|"message read"|"message edit"|"message delete"|"message pin"|"message unpin"|"message pins"|"message permissions"|"message search"|"message thread"|"message thread create"|"message thread list"|"message thread reply"|"message emoji"|"message emoji list"|"message emoji upload"|"message sticker"|"message sticker send"|"message sticker upload"|"message role"|"message role info"|"message role add"|"message role remove"|"message channel"|"message channel info"|"message channel list"|"message member"|"message member info"|"message voice"|"message voice status"|"message event"|"message event list"|"message event create"|"message timeout"|"message kick"|"message ban"|"mcp"|"mcp serve"|"mcp list"|"mcp show"|"mcp status"|"mcp probe"|"mcp doctor"|"mcp add"|"mcp set"|"mcp tools"|"mcp configure"|"mcp login"|"mcp logout"|"mcp reload"|"mcp unset"|"transcripts"|"transcripts list"|"transcripts show"|"transcripts path"|"agent"|"agent exec"|"agents"|"agents list"|"agents bindings"|"agents bind"|"agents unbind"|"agents add"|"agents set-identity"|"agents delete"|"audit"|"status"|"health"|"sessions"|"sessions list"|"sessions cleanup"|"sessions tail"|"sessions export-trajectory"|"sessions archive"|"sessions delete"|"sessions compact"|"tasks"|"tasks list"|"tasks audit"|"tasks maintenance"|"tasks show"|"tasks notify"|"tasks cancel"|"tasks retry"|"tasks dismiss"|"tasks flow"|"tasks flow list"|"tasks flow show"|"tasks flow cancel"|"acp"|"acp client"|"gateway"|"gateway run"|"gateway status"|"gateway install"|"gateway uninstall"|"gateway start"|"gateway stop"|"gateway restart"|"gateway restart-handoff"|"gateway restart-handoff capabilities"|"gateway restart-handoff consume"|"gateway auth-token"|"gateway call"|"gateway suspend"|"gateway resume"|"gateway usage-cost"|"gateway health"|"gateway stability"|"gateway diagnostics"|"gateway diagnostics export"|"gateway probe"|"gateway discover"|"daemon"|"daemon status"|"daemon install"|"daemon uninstall"|"daemon start"|"daemon stop"|"daemon restart"|"logs"|"system"|"system event"|"system heartbeat"|"system heartbeat last"|"system heartbeat enable"|"system heartbeat disable"|"system presence"|"models"|"models list"|"models status"|"models refresh"|"models set"|"models set-image"|"models aliases"|"models aliases list"|"models aliases add"|"models aliases remove"|"models fallbacks"|"models fallbacks list"|"models fallbacks add"|"models fallbacks remove"|"models fallbacks clear"|"models image-fallbacks"|"models image-fallbacks list"|"models image-fallbacks add"|"models image-fallbacks remove"|"models image-fallbacks clear"|"models scan"|"models auth"|"models auth list"|"models auth add"|"models auth logout"|"models auth login"|"models auth setup-token"|"models auth paste-token"|"models auth paste-api-key"|"models auth login-github-copilot"|"models auth order"|"models auth order get"|"models auth order set"|"models auth order clear"|"promos"|"promos list"|"promos claim"|"telemetry"|"telemetry show"|"telemetry on"|"telemetry off"|"infer"|"capability"|"infer list"|"capability list"|"infer inspect"|"capability inspect"|"infer model"|"capability model"|"infer model run"|"capability model run"|"infer model list"|"capability model list"|"infer model inspect"|"capability model inspect"|"infer model providers"|"capability model providers"|"infer model auth"|"capability model auth"|"infer model auth login"|"capability model auth login"|"infer model auth logout"|"capability model auth logout"|"infer model auth status"|"capability model auth status"|"infer image"|"capability image"|"infer image generate"|"capability image generate"|"infer image edit"|"capability image edit"|"infer image describe"|"capability image describe"|"infer image describe-many"|"capability image describe-many"|"infer image providers"|"capability image providers"|"infer audio"|"capability audio"|"infer audio transcribe"|"capability audio transcribe"|"infer audio providers"|"capability audio providers"|"infer tts"|"capability tts"|"infer tts convert"|"capability tts convert"|"infer tts voices"|"capability tts voices"|"infer tts providers"|"capability tts providers"|"infer tts personas"|"capability tts personas"|"infer tts status"|"capability tts status"|"infer tts enable"|"capability tts enable"|"infer tts disable"|"capability tts disable"|"infer tts set-provider"|"capability tts set-provider"|"infer tts set-persona"|"capability tts set-persona"|"infer video"|"capability video"|"infer video generate"|"capability video generate"|"infer video describe"|"capability video describe"|"infer video providers"|"capability video providers"|"infer web"|"capability web"|"infer web search"|"capability web search"|"infer web fetch"|"capability web fetch"|"infer web providers"|"capability web providers"|"infer embedding"|"capability embedding"|"infer embedding create"|"capability embedding create"|"infer embedding providers"|"capability embedding providers"|"approvals"|"exec-approvals"|"approvals pending"|"exec-approvals pending"|"approvals resolve"|"exec-approvals resolve"|"approvals grants"|"exec-approvals grants"|"approvals grants list"|"exec-approvals grants list"|"approvals grants revoke"|"exec-approvals grants revoke"|"approvals get"|"exec-approvals get"|"approvals set"|"exec-approvals set"|"approvals allowlist"|"exec-approvals allowlist"|"approvals allowlist add"|"exec-approvals allowlist add"|"approvals allowlist remove"|"exec-approvals allowlist remove"|"exec-policy"|"exec-policy show"|"exec-policy preset"|"exec-policy set"|"nodes"|"nodes status"|"nodes describe"|"nodes list"|"nodes pending"|"nodes approve"|"nodes reject"|"nodes remove"|"nodes rename"|"nodes invoke"|"nodes notify"|"nodes push"|"nodes camera"|"nodes camera list"|"nodes camera snap"|"nodes camera clip"|"nodes screen"|"nodes screen record"|"nodes location"|"nodes location get"|"devices"|"devices list"|"devices join-code"|"devices remove"|"devices clear"|"devices approve"|"devices reject"|"devices rename"|"devices rotate"|"devices revoke"|"users"|"users list"|"users link-email"|"node"|"node worker"|"node run"|"node status"|"node identity"|"node install"|"node uninstall"|"node stop"|"node start"|"node restart"|"connect"|"worker"|"sandbox"|"sandbox list"|"sandbox recreate"|"sandbox explain"|"fleet"|"fleet create"|"fleet backup"|"fleet restore"|"fleet doctor"|"fleet list"|"fleet ls"|"fleet status"|"fleet logs"|"fleet start"|"fleet stop"|"fleet restart"|"fleet upgrade"|"fleet rm"|"worktrees"|"worktrees list"|"worktrees create"|"worktrees remove"|"worktrees restore"|"worktrees gc"|"attach"|"resume"|"tui"|"terminal"|"chat"|"cron"|"automations"|"cron status"|"automations status"|"cron list"|"automations list"|"cron add"|"cron create"|"automations add"|"automations create"|"cron rm"|"cron remove"|"cron delete"|"automations rm"|"automations remove"|"automations delete"|"cron enable"|"automations enable"|"cron disable"|"automations disable"|"cron get"|"automations get"|"cron show"|"automations show"|"cron runs"|"automations runs"|"cron run"|"automations run"|"cron scratch"|"automations scratch"|"cron edit"|"automations edit"|"dns"|"dns setup"|"docs"|"proxy"|"proxy start"|"proxy run"|"proxy validate"|"proxy coverage"|"proxy sessions"|"proxy query"|"proxy blob"|"proxy purge"|"hooks"|"hooks list"|"hooks info"|"hooks check"|"hooks enable"|"hooks disable"|"hooks relay"|"hooks install"|"hooks update"|"webhooks"|"webhooks gmail"|"webhooks gmail setup"|"webhooks gmail run"|"qr"|"clawbot"|"clawbot qr"|"pairing"|"pairing list"|"pairing approve"|"plugins"|"plugins list"|"plugins search"|"plugins inspect"|"plugins info"|"plugins enable"|"plugins disable"|"plugins uninstall"|"plugins install"|"plugins update"|"plugins registry"|"plugins doctor"|"plugins build"|"plugins validate"|"plugins init"|"plugins marketplace"|"plugins marketplace entries"|"plugins marketplace refresh"|"plugins marketplace list"|"channels"|"channels list"|"channels status"|"channels capabilities"|"channels resolve"|"channels logs"|"channels dead-letters"|"channels dead-letters list"|"channels dead-letters resubmit"|"channels add"|"channels remove"|"channels login"|"channels logout"|"directory"|"directory self"|"directory peers"|"directory peers list"|"directory groups"|"directory groups list"|"directory groups members"|"security"|"security audit"|"secrets"|"secrets store"|"secrets store list"|"secrets store set"|"secrets store get"|"secrets store rm"|"secrets store import"|"secrets reload"|"secrets audit"|"secrets configure"|"secrets apply"|"skills"|"skills search"|"skills install"|"skills update"|"skills verify"|"skills curator"|"skills curator status"|"skills curator pin"|"skills curator unpin"|"skills curator restore"|"skills workshop"|"skills workshop list"|"skills workshop inspect"|"skills workshop propose-create"|"skills workshop propose-update"|"skills workshop revise"|"skills workshop evaluate"|"skills workshop apply"|"skills workshop reject"|"skills workshop quarantine"|"skills list"|"skills info"|"skills check"|"update"|"update cleanup"|"update repair"|"update finalize"|"update wizard"|"update status"|"browser"|"browser status"|"browser start"|"browser stop"|"browser reset-profile"|"browser tabs"|"browser tab"|"browser open"|"browser focus"|"browser close"|"browser profiles"|"browser system-profiles"|"browser import-profile"|"browser create-profile"|"browser delete-profile"|"browser doctor"|"browser cookie-sync"|"browser screenshot"|"browser snapshot"|"browser navigate"|"browser resize"|"browser click"|"browser click-coords"|"browser type"|"browser press"|"browser hover"|"browser scrollintoview"|"browser drag"|"browser select"|"browser upload"|"browser waitfordownload"|"browser download"|"browser dialog"|"browser fill"|"browser wait"|"browser evaluate"|"browser batch"|"browser console"|"browser pdf"|"browser responsebody"|"browser highlight"|"browser errors"|"browser requests"|"browser trace"|"browser cookies"|"browser storage"|"browser set"|"browser extension"|"file-transfer"|"file-transfer approvals"|"file-transfer approvals migrate"|"memory"|"memory status"|"memory index"|"memory search"|"memory forget"|"memory promote"|"memory promote-explain"|"memory rem-harness"|"memory rem-backfill"|"memory session-backfill"|"workboard"|"workboard list"|"workboard create"|"workboard show"|"workboard move"|"workboard dispatch")
            command_path="${candidate_path}"
            case "${command_path}" in
              "completion")
                opts="-s --shell -i --install --write-state -y --yes"
                value_options="--container --profile --log-level -s --shell"
                ;;
              "setup")
                opts="--workspace --agent-name --wizard --baseline --reset --reset-scope --non-interactive --classic --tui --accept-risk --flow --mode --auth-choice --token-provider --token --token-profile-id --token-expires-in --secret-input-mode --cloudflare-ai-gateway-account-id --cloudflare-ai-gateway-gateway-id --alibaba-model-studio-api-key --anthropic-api-key --clawrouter-api-key --fal-api-key --github-copilot-token --gemini-api-key --huggingface-api-key --litellm-api-key --lmstudio-api-key --minimax-api-key --nvidia-api-key --ollama-cloud-api-key --openai-api-key --opencode-go-api-key --openrouter-api-key --runway-api-key --together-api-key --xai-api-key --deepseek-api-key --fireworks-api-key --groq-api-key --llama-server-api-key --moonshot-api-key --modelstudio-standard-api-key-cn --modelstudio-standard-api-key --modelstudio-api-key-cn --modelstudio-api-key --qwen-oauth-token --arceeai-api-key --baseten-api-key --byteplus-api-key --cerebras-api-key --chutes-api-key --cohere-api-key --cloudflare-ai-gateway-api-key --comfy-api-key --deepinfra-api-key --featherless-api-key --gmi-api-key --longcat-api-key --meta-api-key --mistral-api-key --novita-api-key --opencode-zen-api-key --kilocode-api-key --kimi-code-api-key --pixverse-api-key --qianfan-api-key --qwen-token-plan-api-key --qwen-token-plan-api-key-cn --tokenhub-api-key --tokenplan-api-key --venice-api-key --ai-gateway-api-key --vydra-api-key --xiaomi-api-key --xiaomi-token-plan-api-key --zai-api-key --synthetic-api-key --volcengine-api-key --stepfun-api-key --custom-base-url --custom-api-key --custom-model-id --custom-provider-id --custom-compatibility --custom-image-input --custom-text-input --gateway-port --gateway-bind --gateway-auth --gateway-token --gateway-token-ref-env --gateway-password --tailscale --install-daemon --no-install-daemon --skip-daemon --daemon-runtime --skip-channels --skip-skills --skip-bootstrap --skip-search --skip-health --skip-ui --suppress-gateway-token-output --skip-hooks --node-manager --import-from --import-source --import-secrets --remote-url --remote-token --remote-password -m --message --yes --json"
                value_options="--container --profile --log-level --workspace --agent-name --reset-scope --flow --mode --auth-choice --token-provider --token --token-profile-id --token-expires-in --secret-input-mode --cloudflare-ai-gateway-account-id --cloudflare-ai-gateway-gateway-id --alibaba-model-studio-api-key --anthropic-api-key --clawrouter-api-key --fal-api-key --github-copilot-token --gemini-api-key --huggingface-api-key --litellm-api-key --lmstudio-api-key --minimax-api-key --nvidia-api-key --ollama-cloud-api-key --openai-api-key --opencode-go-api-key --openrouter-api-key --runway-api-key --together-api-key --xai-api-key --deepseek-api-key --fireworks-api-key --groq-api-key --llama-server-api-key --moonshot-api-key --modelstudio-standard-api-key-cn --modelstudio-standard-api-key --modelstudio-api-key-cn --modelstudio-api-key --qwen-oauth-token --arceeai-api-key --baseten-api-key --byteplus-api-key --cerebras-api-key --chutes-api-key --cohere-api-key --cloudflare-ai-gateway-api-key --comfy-api-key --deepinfra-api-key --featherless-api-key --gmi-api-key --longcat-api-key --meta-api-key --mistral-api-key --novita-api-key --opencode-zen-api-key --kilocode-api-key --kimi-code-api-key --pixverse-api-key --qianfan-api-key --qwen-token-plan-api-key --qwen-token-plan-api-key-cn --tokenhub-api-key --tokenplan-api-key --venice-api-key --ai-gateway-api-key --vydra-api-key --xiaomi-api-key --xiaomi-token-plan-api-key --zai-api-key --synthetic-api-key --volcengine-api-key --stepfun-api-key --custom-base-url --custom-api-key --custom-model-id --custom-provider-id --custom-compatibility --gateway-port --gateway-bind --gateway-auth --gateway-token --gateway-token-ref-env --gateway-password --tailscale --daemon-runtime --node-manager --import-from --import-source --remote-url --remote-token --remote-password -m --message"
                ;;
              "crestodian")
                opts="-m --message --yes --json"
                value_options="--container --profile --log-level -m --message"
                ;;
              "onboard")
                opts="recommendations --workspace --agent-name --reset --reset-scope --non-interactive --modern --classic --tui --accept-risk --flow --mode --auth-choice --token-provider --token --token-profile-id --token-expires-in --secret-input-mode --cloudflare-ai-gateway-account-id --cloudflare-ai-gateway-gateway-id --alibaba-model-studio-api-key --anthropic-api-key --clawrouter-api-key --fal-api-key --github-copilot-token --gemini-api-key --huggingface-api-key --litellm-api-key --lmstudio-api-key --minimax-api-key --nvidia-api-key --ollama-cloud-api-key --openai-api-key --opencode-go-api-key --openrouter-api-key --runway-api-key --together-api-key --xai-api-key --deepseek-api-key --fireworks-api-key --groq-api-key --llama-server-api-key --moonshot-api-key --modelstudio-standard-api-key-cn --modelstudio-standard-api-key --modelstudio-api-key-cn --modelstudio-api-key --qwen-oauth-token --arceeai-api-key --baseten-api-key --byteplus-api-key --cerebras-api-key --chutes-api-key --cohere-api-key --cloudflare-ai-gateway-api-key --comfy-api-key --deepinfra-api-key --featherless-api-key --gmi-api-key --longcat-api-key --meta-api-key --mistral-api-key --novita-api-key --opencode-zen-api-key --kilocode-api-key --kimi-code-api-key --pixverse-api-key --qianfan-api-key --qwen-token-plan-api-key --qwen-token-plan-api-key-cn --tokenhub-api-key --tokenplan-api-key --venice-api-key --ai-gateway-api-key --vydra-api-key --xiaomi-api-key --xiaomi-token-plan-api-key --zai-api-key --synthetic-api-key --volcengine-api-key --stepfun-api-key --custom-base-url --custom-api-key --custom-model-id --custom-provider-id --custom-compatibility --custom-image-input --custom-text-input --gateway-port --gateway-bind --gateway-auth --gateway-token --gateway-token-ref-env --gateway-password --remote-url --remote-token --remote-password --tailscale --install-daemon --no-install-daemon --skip-daemon --daemon-runtime --skip-channels --skip-skills --skip-bootstrap --skip-search --skip-health --skip-ui --suppress-gateway-token-output --skip-hooks --node-manager --import-from --import-source --import-secrets --json"
                value_options="--container --profile --log-level --workspace --agent-name --reset-scope --flow --mode --auth-choice --token-provider --token --token-profile-id --token-expires-in --secret-input-mode --cloudflare-ai-gateway-account-id --cloudflare-ai-gateway-gateway-id --alibaba-model-studio-api-key --anthropic-api-key --clawrouter-api-key --fal-api-key --github-copilot-token --gemini-api-key --huggingface-api-key --litellm-api-key --lmstudio-api-key --minimax-api-key --nvidia-api-key --ollama-cloud-api-key --openai-api-key --opencode-go-api-key --openrouter-api-key --runway-api-key --together-api-key --xai-api-key --deepseek-api-key --fireworks-api-key --groq-api-key --llama-server-api-key --moonshot-api-key --modelstudio-standard-api-key-cn --modelstudio-standard-api-key --modelstudio-api-key-cn --modelstudio-api-key --qwen-oauth-token --arceeai-api-key --baseten-api-key --byteplus-api-key --cerebras-api-key --chutes-api-key --cohere-api-key --cloudflare-ai-gateway-api-key --comfy-api-key --deepinfra-api-key --featherless-api-key --gmi-api-key --longcat-api-key --meta-api-key --mistral-api-key --novita-api-key --opencode-zen-api-key --kilocode-api-key --kimi-code-api-key --pixverse-api-key --qianfan-api-key --qwen-token-plan-api-key --qwen-token-plan-api-key-cn --tokenhub-api-key --tokenplan-api-key --venice-api-key --ai-gateway-api-key --vydra-api-key --xiaomi-api-key --xiaomi-token-plan-api-key --zai-api-key --synthetic-api-key --volcengine-api-key --stepfun-api-key --custom-base-url --custom-api-key --custom-model-id --custom-provider-id --custom-compatibility --gateway-port --gateway-bind --gateway-auth --gateway-token --gateway-token-ref-env --gateway-password --remote-url --remote-token --remote-password --tailscale --daemon-runtime --node-manager --import-from --import-source"
                ;;
              "onboard recommendations")
                opts="acknowledge refresh --json"
                value_options="--container --profile --log-level --workspace --agent-name --reset-scope --flow --mode --auth-choice --token-provider --token --token-profile-id --token-expires-in --secret-input-mode --cloudflare-ai-gateway-account-id --cloudflare-ai-gateway-gateway-id --alibaba-model-studio-api-key --anthropic-api-key --clawrouter-api-key --fal-api-key --github-copilot-token --gemini-api-key --huggingface-api-key --litellm-api-key --lmstudio-api-key --minimax-api-key --nvidia-api-key --ollama-cloud-api-key --openai-api-key --opencode-go-api-key --openrouter-api-key --runway-api-key --together-api-key --xai-api-key --deepseek-api-key --fireworks-api-key --groq-api-key --llama-server-api-key --moonshot-api-key --modelstudio-standard-api-key-cn --modelstudio-standard-api-key --modelstudio-api-key-cn --modelstudio-api-key --qwen-oauth-token --arceeai-api-key --baseten-api-key --byteplus-api-key --cerebras-api-key --chutes-api-key --cohere-api-key --cloudflare-ai-gateway-api-key --comfy-api-key --deepinfra-api-key --featherless-api-key --gmi-api-key --longcat-api-key --meta-api-key --mistral-api-key --novita-api-key --opencode-zen-api-key --kilocode-api-key --kimi-code-api-key --pixverse-api-key --qianfan-api-key --qwen-token-plan-api-key --qwen-token-plan-api-key-cn --tokenhub-api-key --tokenplan-api-key --venice-api-key --ai-gateway-api-key --vydra-api-key --xiaomi-api-key --xiaomi-token-plan-api-key --zai-api-key --synthetic-api-key --volcengine-api-key --stepfun-api-key --custom-base-url --custom-api-key --custom-model-id --custom-provider-id --custom-compatibility --gateway-port --gateway-bind --gateway-auth --gateway-token --gateway-token-ref-env --gateway-password --remote-url --remote-token --remote-password --tailscale --daemon-runtime --node-manager --import-from --import-source"
                ;;
              "onboard recommendations acknowledge")
                opts="--retry"
                value_options="--container --profile --log-level --workspace --agent-name --reset-scope --flow --mode --auth-choice --token-provider --token --token-profile-id --token-expires-in --secret-input-mode --cloudflare-ai-gateway-account-id --cloudflare-ai-gateway-gateway-id --alibaba-model-studio-api-key --anthropic-api-key --clawrouter-api-key --fal-api-key --github-copilot-token --gemini-api-key --huggingface-api-key --litellm-api-key --lmstudio-api-key --minimax-api-key --nvidia-api-key --ollama-cloud-api-key --openai-api-key --opencode-go-api-key --openrouter-api-key --runway-api-key --together-api-key --xai-api-key --deepseek-api-key --fireworks-api-key --groq-api-key --llama-server-api-key --moonshot-api-key --modelstudio-standard-api-key-cn --modelstudio-standard-api-key --modelstudio-api-key-cn --modelstudio-api-key --qwen-oauth-token --arceeai-api-key --baseten-api-key --byteplus-api-key --cerebras-api-key --chutes-api-key --cohere-api-key --cloudflare-ai-gateway-api-key --comfy-api-key --deepinfra-api-key --featherless-api-key --gmi-api-key --longcat-api-key --meta-api-key --mistral-api-key --novita-api-key --opencode-zen-api-key --kilocode-api-key --kimi-code-api-key --pixverse-api-key --qianfan-api-key --qwen-token-plan-api-key --qwen-token-plan-api-key-cn --tokenhub-api-key --tokenplan-api-key --venice-api-key --ai-gateway-api-key --vydra-api-key --xiaomi-api-key --xiaomi-token-plan-api-key --zai-api-key --synthetic-api-key --volcengine-api-key --stepfun-api-key --custom-base-url --custom-api-key --custom-model-id --custom-provider-id --custom-compatibility --gateway-port --gateway-bind --gateway-auth --gateway-token --gateway-token-ref-env --gateway-password --remote-url --remote-token --remote-password --tailscale --daemon-runtime --node-manager --import-from --import-source --retry"
                ;;
              "onboard recommendations refresh")
                opts=""
                value_options="--container --profile --log-level --workspace --agent-name --reset-scope --flow --mode --auth-choice --token-provider --token --token-profile-id --token-expires-in --secret-input-mode --cloudflare-ai-gateway-account-id --cloudflare-ai-gateway-gateway-id --alibaba-model-studio-api-key --anthropic-api-key --clawrouter-api-key --fal-api-key --github-copilot-token --gemini-api-key --huggingface-api-key --litellm-api-key --lmstudio-api-key --minimax-api-key --nvidia-api-key --ollama-cloud-api-key --openai-api-key --opencode-go-api-key --openrouter-api-key --runway-api-key --together-api-key --xai-api-key --deepseek-api-key --fireworks-api-key --groq-api-key --llama-server-api-key --moonshot-api-key --modelstudio-standard-api-key-cn --modelstudio-standard-api-key --modelstudio-api-key-cn --modelstudio-api-key --qwen-oauth-token --arceeai-api-key --baseten-api-key --byteplus-api-key --cerebras-api-key --chutes-api-key --cohere-api-key --cloudflare-ai-gateway-api-key --comfy-api-key --deepinfra-api-key --featherless-api-key --gmi-api-key --longcat-api-key --meta-api-key --mistral-api-key --novita-api-key --opencode-zen-api-key --kilocode-api-key --kimi-code-api-key --pixverse-api-key --qianfan-api-key --qwen-token-plan-api-key --qwen-token-plan-api-key-cn --tokenhub-api-key --tokenplan-api-key --venice-api-key --ai-gateway-api-key --vydra-api-key --xiaomi-api-key --xiaomi-token-plan-api-key --zai-api-key --synthetic-api-key --volcengine-api-key --stepfun-api-key --custom-base-url --custom-api-key --custom-model-id --custom-provider-id --custom-compatibility --gateway-port --gateway-bind --gateway-auth --gateway-token --gateway-token-ref-env --gateway-password --remote-url --remote-token --remote-password --tailscale --daemon-runtime --node-manager --import-from --import-source"
                ;;
              "configure")
                opts="--section"
                value_options="--container --profile --log-level --section"
                ;;
              "config")
                opts="file get patch schema set unset validate --section"
                value_options="--container --profile --log-level --section"
                ;;
              "config get")
                opts="--json"
                value_options="--container --profile --log-level --section"
                ;;
              "config set")
                opts="--strict-json --json --dry-run --allow-exec --merge --replace --ref-provider --ref-source --ref-id --provider-source --provider-allowlist --provider-path --provider-mode --provider-timeout-ms --provider-max-bytes --provider-command --provider-arg --provider-no-output-timeout-ms --provider-max-output-bytes --provider-json-only --provider-env --provider-pass-env --provider-trusted-dir --batch-json --batch-file"
                value_options="--container --profile --log-level --section --ref-provider --ref-source --ref-id --provider-source --provider-allowlist --provider-path --provider-mode --provider-timeout-ms --provider-max-bytes --provider-command --provider-arg --provider-no-output-timeout-ms --provider-max-output-bytes --provider-env --provider-pass-env --provider-trusted-dir --batch-json --batch-file"
                ;;
              "config patch")
                opts="--file --stdin --dry-run --allow-exec --json --replace-path"
                value_options="--container --profile --log-level --section --file --replace-path"
                ;;
              "config unset")
                opts="--dry-run --allow-exec --json"
                value_options="--container --profile --log-level --section"
                ;;
              "config file")
                opts="--json"
                value_options="--container --profile --log-level --section"
                ;;
              "config schema")
                opts="--json"
                value_options="--container --profile --log-level --section"
                ;;
              "config validate")
                opts="--json"
                value_options="--container --profile --log-level --section"
                ;;
              "backup")
                opts="create disable enable git restore sqlite verify"
                value_options="--container --profile --log-level"
                ;;
              "backup create")
                opts="--output --json --dry-run --verify --only-config --no-include-workspace"
                value_options="--container --profile --log-level --output"
                ;;
              "backup verify")
                opts="--json"
                value_options="--container --profile --log-level"
                ;;
              "backup restore")
                opts="--target --json"
                value_options="--container --profile --log-level --target"
                ;;
              "backup sqlite")
                opts="create list restore verify"
                value_options="--container --profile --log-level"
                ;;
              "backup sqlite create")
                opts="--global --agent --repository --json"
                value_options="--container --profile --log-level --agent --repository"
                ;;
              "backup sqlite list")
                opts="--repository --json"
                value_options="--container --profile --log-level --repository"
                ;;
              "backup sqlite verify")
                opts="--scratch --json"
                value_options="--container --profile --log-level --scratch"
                ;;
              "backup sqlite restore")
                opts="--target --json"
                value_options="--container --profile --log-level --target"
                ;;
              "backup git")
                opts="create init log restore verify"
                value_options="--container --profile --log-level"
                ;;
              "backup git init")
                opts="--repository --remote --json"
                value_options="--container --profile --log-level --repository --remote"
                ;;
              "backup git create")
                opts="--repository --all --global --agent --push --exclude-secrets --json"
                value_options="--container --profile --log-level --repository --agent"
                ;;
              "backup git log")
                opts="--repository --limit --json"
                value_options="--container --profile --log-level --repository --limit"
                ;;
              "backup git verify")
                opts="--repository --ref --global --agent --json"
                value_options="--container --profile --log-level --repository --ref --agent"
                ;;
              "backup git restore")
                opts="--repository --target --ref --global --agent --json"
                value_options="--container --profile --log-level --repository --target --ref --agent"
                ;;
              "backup enable")
                opts="--repository --every --push --exclude-secrets --include-secrets --global-only --agent --url --port --token --password --timeout --expect-final"
                value_options="--container --profile --log-level --repository --every --agent --url --port --token --password --timeout"
                ;;
              "backup disable")
                opts="--url --port --token --password --timeout --expect-final"
                value_options="--container --profile --log-level --url --port --token --password --timeout"
                ;;
              "database")
                opts="ownership preflight"
                value_options="--container --profile --log-level"
                ;;
              "database preflight")
                opts="--json"
                value_options="--container --profile --log-level"
                ;;
              "database ownership")
                opts="claim status"
                value_options="--container --profile --log-level"
                ;;
              "database ownership status")
                opts="--json"
                value_options="--container --profile --log-level"
                ;;
              "database ownership claim")
                opts="--manager --json"
                value_options="--container --profile --log-level --manager"
                ;;
              "migrate")
                opts="apply list plan --from --agent --include-secrets --no-auth-credentials --overwrite --dry-run --yes --skill --plugin --item --backup-output --no-backup --force --json --verify-plugin-apps"
                value_options="--container --profile --log-level --from --agent --skill --plugin --item --backup-output"
                ;;
              "migrate list")
                opts="--json"
                value_options="--container --profile --log-level --from --agent --skill --plugin --item --backup-output"
                ;;
              "migrate plan")
                opts="--from --agent --include-secrets --no-auth-credentials --overwrite --json --skill --plugin --item --verify-plugin-apps"
                value_options="--container --profile --log-level --from --agent --skill --plugin --item --backup-output"
                ;;
              "migrate apply")
                opts="--from --agent --include-secrets --no-auth-credentials --overwrite --json --skill --plugin --item --verify-plugin-apps --yes --backup-output --no-backup --force"
                value_options="--container --profile --log-level --from --agent --skill --plugin --item --backup-output"
                ;;
              "doctor")
                opts="--no-workspace-suggestions --yes --repair --fix --force --non-interactive --generate-gateway-token --allow-exec --deep --lint --post-upgrade --session-sqlite --state-sqlite --session-sqlite-store --session-sqlite-agent --session-sqlite-all-agents --github-issue --json --severity-min --all --skip --only"
                value_options="--container --profile --log-level --session-sqlite --state-sqlite --session-sqlite-store --session-sqlite-agent --severity-min --skip --only"
                ;;
              "triage")
                opts="--json --no-export --run"
                value_options="--container --profile --log-level"
                ;;
              "dashboard")
                opts="--no-open --json --yes"
                value_options="--container --profile --log-level"
                ;;
              "reset")
                opts="--scope --yes --non-interactive --dry-run"
                value_options="--container --profile --log-level --scope"
                ;;
              "uninstall")
                opts="--service --state --workspace --app --all --yes --non-interactive --dry-run"
                value_options="--container --profile --log-level"
                ;;
              "message")
                opts="ban broadcast channel delete edit emoji event kick member permissions pin pins poll react reactions read role search send sticker thread timeout unpin voice"
                value_options="--container --profile --log-level"
                ;;
              "message send")
                opts="-m --message -t --target --media --presentation --delivery --pin --reply-to --thread-id --gif-playback --force-document --silent --channel --account --json --dry-run --verbose"
                value_options="--container --profile --log-level -m --message -t --target --media --presentation --delivery --reply-to --thread-id --channel --account"
                ;;
              "message broadcast")
                opts="--channel --account --json --dry-run --verbose --targets --message --media"
                value_options="--container --profile --log-level --channel --account --targets --message --media"
                ;;
              "message poll")
                opts="-t --target --channel --account --json --dry-run --verbose --poll-question --poll-option --poll-multi --poll-duration-hours --poll-duration-seconds --poll-anonymous --poll-public -m --message --silent --thread-id"
                value_options="--container --profile --log-level -t --target --channel --account --poll-question --poll-option --poll-duration-hours --poll-duration-seconds -m --message --thread-id"
                ;;
              "message react")
                opts="-t --target --channel --account --json --dry-run --verbose --message-id --emoji --remove --participant --from-me --target-author --target-author-uuid"
                value_options="--container --profile --log-level -t --target --channel --account --message-id --emoji --participant --target-author --target-author-uuid"
                ;;
              "message reactions")
                opts="-t --target --channel --account --json --dry-run --verbose --message-id --limit"
                value_options="--container --profile --log-level -t --target --channel --account --message-id --limit"
                ;;
              "message read")
                opts="-t --target --channel --account --json --dry-run --verbose --limit --message-id --before --after --around --thread-id"
                value_options="--container --profile --log-level -t --target --channel --account --limit --message-id --before --after --around --thread-id"
                ;;
              "message edit")
                opts="--message-id -m --message -t --target --channel --account --json --dry-run --verbose --thread-id"
                value_options="--container --profile --log-level --message-id -m --message -t --target --channel --account --thread-id"
                ;;
              "message delete")
                opts="--message-id -t --target --channel --account --json --dry-run --verbose"
                value_options="--container --profile --log-level --message-id -t --target --channel --account"
                ;;
              "message pin")
                opts="-t --target --channel --account --json --dry-run --verbose --message-id"
                value_options="--container --profile --log-level -t --target --channel --account --message-id"
                ;;
              "message unpin")
                opts="-t --target --channel --account --json --dry-run --verbose --message-id --pinned-message-id"
                value_options="--container --profile --log-level -t --target --channel --account --message-id --pinned-message-id"
                ;;
              "message pins")
                opts="-t --target --channel --account --json --dry-run --verbose --limit"
                value_options="--container --profile --log-level -t --target --channel --account --limit"
                ;;
              "message permissions")
                opts="-t --target --channel --account --json --dry-run --verbose"
                value_options="--container --profile --log-level -t --target --channel --account"
                ;;
              "message search")
                opts="--channel --account --json --dry-run --verbose --guild-id --query --channel-id --channel-ids --author-id --author-ids --limit"
                value_options="--container --profile --log-level --channel --account --guild-id --query --channel-id --channel-ids --author-id --author-ids --limit"
                ;;
              "message thread")
                opts="create list reply"
                value_options="--container --profile --log-level"
                ;;
              "message thread create")
                opts="--thread-name -t --target --channel --account --json --dry-run --verbose --message-id -m --message --auto-archive-min"
                value_options="--container --profile --log-level --thread-name -t --target --channel --account --message-id -m --message --auto-archive-min"
                ;;
              "message thread list")
                opts="--guild-id --channel --account --json --dry-run --verbose --channel-id --include-archived --before --limit"
                value_options="--container --profile --log-level --guild-id --channel --account --channel-id --before --limit"
                ;;
              "message thread reply")
                opts="-m --message -t --target --channel --account --json --dry-run --verbose --media --reply-to"
                value_options="--container --profile --log-level -m --message -t --target --channel --account --media --reply-to"
                ;;
              "message emoji")
                opts="list upload"
                value_options="--container --profile --log-level"
                ;;
              "message emoji list")
                opts="--channel --account --json --dry-run --verbose --guild-id"
                value_options="--container --profile --log-level --channel --account --guild-id"
                ;;
              "message emoji upload")
                opts="--guild-id --channel --account --json --dry-run --verbose --emoji-name --media --role-ids"
                value_options="--container --profile --log-level --guild-id --channel --account --emoji-name --media --role-ids"
                ;;
              "message sticker")
                opts="send upload"
                value_options="--container --profile --log-level"
                ;;
              "message sticker send")
                opts="-t --target --channel --account --json --dry-run --verbose --sticker-id -m --message"
                value_options="--container --profile --log-level -t --target --channel --account --sticker-id -m --message"
                ;;
              "message sticker upload")
                opts="--guild-id --channel --account --json --dry-run --verbose --sticker-name --sticker-desc --sticker-tags --media"
                value_options="--container --profile --log-level --guild-id --channel --account --sticker-name --sticker-desc --sticker-tags --media"
                ;;
              "message role")
                opts="add info remove"
                value_options="--container --profile --log-level"
                ;;
              "message role info")
                opts="--guild-id --channel --account --json --dry-run --verbose"
                value_options="--container --profile --log-level --guild-id --channel --account"
                ;;
              "message role add")
                opts="--guild-id --user-id --role-id --channel --account --json --dry-run --verbose"
                value_options="--container --profile --log-level --guild-id --user-id --role-id --channel --account"
                ;;
              "message role remove")
                opts="--guild-id --user-id --role-id --channel --account --json --dry-run --verbose"
                value_options="--container --profile --log-level --guild-id --user-id --role-id --channel --account"
                ;;
              "message channel")
                opts="info list"
                value_options="--container --profile --log-level"
                ;;
              "message channel info")
                opts="-t --target --channel --account --json --dry-run --verbose"
                value_options="--container --profile --log-level -t --target --channel --account"
                ;;
              "message channel list")
                opts="--guild-id --channel --account --json --dry-run --verbose"
                value_options="--container --profile --log-level --guild-id --channel --account"
                ;;
              "message member")
                opts="info"
                value_options="--container --profile --log-level"
                ;;
              "message member info")
                opts="--user-id --channel --account --json --dry-run --verbose --guild-id"
                value_options="--container --profile --log-level --user-id --channel --account --guild-id"
                ;;
              "message voice")
                opts="status"
                value_options="--container --profile --log-level"
                ;;
              "message voice status")
                opts="--guild-id --user-id --channel --account --json --dry-run --verbose"
                value_options="--container --profile --log-level --guild-id --user-id --channel --account"
                ;;
              "message event")
                opts="create list"
                value_options="--container --profile --log-level"
                ;;
              "message event list")
                opts="--guild-id --channel --account --json --dry-run --verbose"
                value_options="--container --profile --log-level --guild-id --channel --account"
                ;;
              "message event create")
                opts="--guild-id --event-name --start-time --channel --account --json --dry-run --verbose --end-time --desc --channel-id --location --event-type --image"
                value_options="--container --profile --log-level --guild-id --event-name --start-time --channel --account --end-time --desc --channel-id --location --event-type --image"
                ;;
              "message timeout")
                opts="--guild-id --user-id --channel --account --json --dry-run --verbose --duration-min --until --reason"
                value_options="--container --profile --log-level --guild-id --user-id --channel --account --duration-min --until --reason"
                ;;
              "message kick")
                opts="--guild-id --user-id --channel --account --json --dry-run --verbose --reason"
                value_options="--container --profile --log-level --guild-id --user-id --channel --account --reason"
                ;;
              "message ban")
                opts="--guild-id --user-id --channel --account --json --dry-run --verbose --reason --delete-days"
                value_options="--container --profile --log-level --guild-id --user-id --channel --account --reason --delete-days"
                ;;
              "mcp")
                opts="add configure doctor list login logout probe reload serve set show status tools unset"
                value_options="--container --profile --log-level"
                ;;
              "mcp serve")
                opts="--url --token --token-file --password --password-file --claude-channel-mode -v --verbose"
                value_options="--container --profile --log-level --url --token --token-file --password --password-file --claude-channel-mode"
                ;;
              "mcp list")
                opts="--json"
                value_options="--container --profile --log-level"
                ;;
              "mcp show")
                opts="--json"
                value_options="--container --profile --log-level"
                ;;
              "mcp status")
                opts="-v --verbose --json"
                value_options="--container --profile --log-level"
                ;;
              "mcp probe")
                opts="--json"
                value_options="--container --profile --log-level"
                ;;
              "mcp doctor")
                opts="--probe --json"
                value_options="--container --profile --log-level"
                ;;
              "mcp add")
                opts="--command --arg --env --cwd --url --transport --header --auth --oauth-scope --oauth-redirect-url --oauth-client-metadata-url --include --exclude --timeout --connect-timeout --parallel --approval --disabled --ssl-verify --client-cert --client-key --no-probe"
                value_options="--container --profile --log-level --command --arg --env --cwd --url --transport --header --auth --oauth-scope --oauth-redirect-url --oauth-client-metadata-url --include --exclude --timeout --connect-timeout --approval --ssl-verify --client-cert --client-key"
                ;;
              "mcp set")
                opts=""
                value_options="--container --profile --log-level"
                ;;
              "mcp tools")
                opts="--include --exclude --clear"
                value_options="--container --profile --log-level --include --exclude"
                ;;
              "mcp configure")
                opts="--enable --disable --include --exclude --clear-tools --timeout --connect-timeout --clear-timeouts --parallel --no-parallel --approval --auth --clear-auth --oauth-scope --oauth-redirect-url --oauth-client-metadata-url --ssl-verify --client-cert --client-key --clear-tls --probe"
                value_options="--container --profile --log-level --include --exclude --timeout --connect-timeout --approval --auth --oauth-scope --oauth-redirect-url --oauth-client-metadata-url --ssl-verify --client-cert --client-key"
                ;;
              "mcp login")
                opts="--code"
                value_options="--container --profile --log-level --code"
                ;;
              "mcp logout")
                opts=""
                value_options="--container --profile --log-level"
                ;;
              "mcp reload")
                opts=""
                value_options="--container --profile --log-level"
                ;;
              "mcp unset")
                opts=""
                value_options="--container --profile --log-level"
                ;;
              "transcripts")
                opts="list path show"
                value_options="--container --profile --log-level"
                ;;
              "transcripts list")
                opts="--json"
                value_options="--container --profile --log-level"
                ;;
              "transcripts show")
                opts="--json"
                value_options="--container --profile --log-level"
                ;;
              "transcripts path")
                opts="--dir --metadata --transcript --json"
                value_options="--container --profile --log-level"
                ;;
              "agent")
                opts="exec -m --message --message-file -t --to --session-key --session-id --agent --model --thinking --verbose --channel --reply-to --reply-channel --reply-account --local --deliver --json --timeout"
                value_options="--container --profile --log-level -m --message --message-file -t --to --session-key --session-id --agent --model --thinking --verbose --channel --reply-to --reply-channel --reply-account --timeout"
                ;;
              "agent exec")
                opts="--message-file --cwd --state-dir --config --isolated --model --code-mode --local-model-lean --thinking --fallback --auth-env-only --no-auth-env-only --timeout --json"
                value_options="--container --profile --log-level -m --message --message-file -t --to --session-key --session-id --agent --model --thinking --verbose --channel --reply-to --reply-channel --reply-account --timeout --cwd --state-dir --config --code-mode --fallback"
                ;;
              "agents")
                opts="add bind bindings delete list set-identity unbind"
                value_options="--container --profile --log-level"
                ;;
              "agents list")
                opts="--json --bindings --tree"
                value_options="--container --profile --log-level"
                ;;
              "agents bindings")
                opts="--agent --json"
                value_options="--container --profile --log-level --agent"
                ;;
              "agents bind")
                opts="--agent --bind --json"
                value_options="--container --profile --log-level --agent --bind"
                ;;
              "agents unbind")
                opts="--agent --bind --all --json"
                value_options="--container --profile --log-level --agent --bind"
                ;;
              "agents add")
                opts="--workspace --model --agent-dir --bind --non-interactive --json"
                value_options="--container --profile --log-level --workspace --model --agent-dir --bind"
                ;;
              "agents set-identity")
                opts="--agent --workspace --identity-file --from-identity --name --theme --emoji --avatar --json"
                value_options="--container --profile --log-level --agent --workspace --identity-file --name --theme --emoji --avatar"
                ;;
              "agents delete")
                opts="--force --json"
                value_options="--container --profile --log-level"
                ;;
              "audit")
                opts="--agent --session --run --execution --kind --status --direction --channel --after --before --cursor --limit --explain --json"
                value_options="--container --profile --log-level --agent --session --run --execution --kind --status --direction --channel --after --before --cursor --limit"
                ;;
              "status")
                opts="--json --all --usage --agent --deep --timeout --verbose --debug"
                value_options="--container --profile --log-level --agent --timeout"
                ;;
              "health")
                opts="--json --timeout --verbose --debug"
                value_options="--container --profile --log-level --timeout"
                ;;
              "sessions")
                opts="archive cleanup compact delete export-trajectory list tail --json --verbose --store --agent --all-agents --active --limit"
                value_options="--container --profile --log-level --store --agent --active --limit"
                ;;
              "sessions list")
                opts="--json --verbose --store --agent --all-agents --active --limit"
                value_options="--container --profile --log-level --store --agent --active --limit"
                ;;
              "sessions cleanup")
                opts="--store --agent --all-agents --dry-run --enforce --fix-missing --fix-dm-scope --active-key --json"
                value_options="--container --profile --log-level --store --agent --active --limit --active-key"
                ;;
              "sessions tail")
                opts="--session-key --tail --follow --store --agent --all-agents"
                value_options="--container --profile --log-level --store --agent --active --limit --session-key --tail"
                ;;
              "sessions export-trajectory")
                opts="--session-key --output --workspace --store --agent --request-json-base64 --json"
                value_options="--container --profile --log-level --store --agent --active --limit --session-key --output --workspace --request-json-base64"
                ;;
              "sessions archive")
                opts="--dry-run --agent --url --token --password --timeout --json"
                value_options="--container --profile --log-level --store --agent --active --limit --url --token --password --timeout"
                ;;
              "sessions delete")
                opts="--dry-run --yes --agent --url --token --password --timeout --json"
                value_options="--container --profile --log-level --store --agent --active --limit --url --token --password --timeout"
                ;;
              "sessions compact")
                opts="--agent --url --token --password --timeout --json --max-lines"
                value_options="--container --profile --log-level --store --agent --active --limit --url --token --password --timeout --max-lines"
                ;;
              "tasks")
                opts="audit cancel dismiss flow list maintenance notify retry show --json --runtime --status"
                value_options="--container --profile --log-level --runtime --status"
                ;;
              "tasks list")
                opts="--json --runtime --status"
                value_options="--container --profile --log-level --runtime --status"
                ;;
              "tasks audit")
                opts="--json --severity --code --limit"
                value_options="--container --profile --log-level --runtime --status --severity --code --limit"
                ;;
              "tasks maintenance")
                opts="--json --apply"
                value_options="--container --profile --log-level --runtime --status"
                ;;
              "tasks show")
                opts="--json"
                value_options="--container --profile --log-level --runtime --status"
                ;;
              "tasks notify")
                opts=""
                value_options="--container --profile --log-level --runtime --status"
                ;;
              "tasks cancel")
                opts=""
                value_options="--container --profile --log-level --runtime --status"
                ;;
              "tasks retry")
                opts=""
                value_options="--container --profile --log-level --runtime --status"
                ;;
              "tasks dismiss")
                opts=""
                value_options="--container --profile --log-level --runtime --status"
                ;;
              "tasks flow")
                opts="cancel list show --json"
                value_options="--container --profile --log-level --runtime --status"
                ;;
              "tasks flow list")
                opts="--json --status"
                value_options="--container --profile --log-level --runtime --status"
                ;;
              "tasks flow show")
                opts="--json"
                value_options="--container --profile --log-level --runtime --status"
                ;;
              "tasks flow cancel")
                opts=""
                value_options="--container --profile --log-level --runtime --status"
                ;;
              "acp")
                opts="client --url --token --token-file --password --password-file --session --session-label --require-existing --reset-session --no-prefix-cwd --provenance -v --verbose"
                value_options="--container --profile --log-level --url --token --token-file --password --password-file --session --session-label --provenance"
                ;;
              "acp client")
                opts="--cwd --server --server-args --server-verbose -v --verbose"
                value_options="--container --profile --log-level --url --token --token-file --password --password-file --session --session-label --provenance --cwd --server --server-args"
                ;;
              "gateway")
                opts="auth-token call diagnostics discover health install probe restart resume run stability start status stop suspend uninstall usage-cost --port --bind --token --auth --password --password-file --tailscale --allow-unconfigured --dev --ambient-channels --dev-ambient-channels --reset --force --verbose --cli-backend-logs --claude-cli-logs --ws-log --compact --raw-stream --raw-stream-path"
                value_options="--container --profile --log-level --port --bind --token --auth --password --password-file --tailscale --ws-log --raw-stream-path"
                ;;
              "gateway run")
                opts="--port --bind --token --auth --password --password-file --tailscale --allow-unconfigured --dev --ambient-channels --dev-ambient-channels --reset --force --verbose --cli-backend-logs --claude-cli-logs --ws-log --compact --raw-stream --raw-stream-path"
                value_options="--container --profile --log-level --port --bind --token --auth --password --password-file --tailscale --ws-log --raw-stream-path"
                ;;
              "gateway status")
                opts="--url --port --token --password --timeout --no-probe --require-rpc --deep --json"
                value_options="--container --profile --log-level --port --bind --token --auth --password --password-file --tailscale --ws-log --raw-stream-path --url --timeout"
                ;;
              "gateway install")
                opts="--port --runtime --token --wrapper --force --json"
                value_options="--container --profile --log-level --port --bind --token --auth --password --password-file --tailscale --ws-log --raw-stream-path --runtime --wrapper"
                ;;
              "gateway uninstall")
                opts="--json"
                value_options="--container --profile --log-level --port --bind --token --auth --password --password-file --tailscale --ws-log --raw-stream-path"
                ;;
              "gateway start")
                opts="--json"
                value_options="--container --profile --log-level --port --bind --token --auth --password --password-file --tailscale --ws-log --raw-stream-path"
                ;;
              "gateway stop")
                opts="--force --json --disable"
                value_options="--container --profile --log-level --port --bind --token --auth --password --password-file --tailscale --ws-log --raw-stream-path"
                ;;
              "gateway restart")
                opts="--preserve-definition --force --safe --skip-deferral --wait --json"
                value_options="--container --profile --log-level --port --bind --token --auth --password --password-file --tailscale --ws-log --raw-stream-path --wait"
                ;;
              "gateway restart-handoff")
                opts="capabilities consume"
                value_options="--container --profile --log-level --port --bind --token --auth --password --password-file --tailscale --ws-log --raw-stream-path"
                ;;
              "gateway restart-handoff capabilities")
                opts="--json"
                value_options="--container --profile --log-level --port --bind --token --auth --password --password-file --tailscale --ws-log --raw-stream-path"
                ;;
              "gateway restart-handoff consume")
                opts="--expected-pid --json"
                value_options="--container --profile --log-level --port --bind --token --auth --password --password-file --tailscale --ws-log --raw-stream-path --expected-pid"
                ;;
              "gateway auth-token")
                opts="--show"
                value_options="--container --profile --log-level --port --bind --token --auth --password --password-file --tailscale --ws-log --raw-stream-path"
                ;;
              "gateway call")
                opts="--params --url --port --token --password --timeout --expect-final --json"
                value_options="--container --profile --log-level --port --bind --token --auth --password --password-file --tailscale --ws-log --raw-stream-path --params --url --timeout"
                ;;
              "gateway suspend")
                opts="--request-id --wait --url --port --token --password --timeout --expect-final --json"
                value_options="--container --profile --log-level --port --bind --token --auth --password --password-file --tailscale --ws-log --raw-stream-path --request-id --wait --url --timeout"
                ;;
              "gateway resume")
                opts="--url --port --token --password --timeout --expect-final --json"
                value_options="--container --profile --log-level --port --bind --token --auth --password --password-file --tailscale --ws-log --raw-stream-path --url --timeout"
                ;;
              "gateway usage-cost")
                opts="--days --agent --all-agents --url --port --token --password --timeout --expect-final --json"
                value_options="--container --profile --log-level --port --bind --token --auth --password --password-file --tailscale --ws-log --raw-stream-path --days --agent --url --timeout"
                ;;
              "gateway health")
                opts="--url --port --token --password --timeout --expect-final --json"
                value_options="--container --profile --log-level --port --bind --token --auth --password --password-file --tailscale --ws-log --raw-stream-path --url --timeout"
                ;;
              "gateway stability")
                opts="--limit --type --since-seq --bundle --export --output --url --port --token --password --timeout --expect-final --json"
                value_options="--container --profile --log-level --port --bind --token --auth --password --password-file --tailscale --ws-log --raw-stream-path --limit --type --since-seq --bundle --output --url --timeout"
                ;;
              "gateway diagnostics")
                opts="export"
                value_options="--container --profile --log-level --port --bind --token --auth --password --password-file --tailscale --ws-log --raw-stream-path"
                ;;
              "gateway diagnostics export")
                opts="--output --log-lines --log-bytes --url --token --password --timeout --no-stability-bundle --json"
                value_options="--container --profile --log-level --port --bind --token --auth --password --password-file --tailscale --ws-log --raw-stream-path --output --log-lines --log-bytes --url --timeout"
                ;;
              "gateway probe")
                opts="--url --port --ssh --ssh-identity --ssh-auto --token --password --timeout --json"
                value_options="--container --profile --log-level --port --bind --token --auth --password --password-file --tailscale --ws-log --raw-stream-path --url --ssh --ssh-identity --timeout"
                ;;
              "gateway discover")
                opts="--timeout --json"
                value_options="--container --profile --log-level --port --bind --token --auth --password --password-file --tailscale --ws-log --raw-stream-path --timeout"
                ;;
              "daemon")
                opts="install restart start status stop uninstall --json"
                value_options="--container --profile --log-level"
                ;;
              "daemon status")
                opts="--url --port --token --password --timeout --no-probe --require-rpc --deep --json"
                value_options="--container --profile --log-level --url --port --token --password --timeout"
                ;;
              "daemon install")
                opts="--port --runtime --token --wrapper --force --json"
                value_options="--container --profile --log-level --port --runtime --token --wrapper"
                ;;
              "daemon uninstall")
                opts="--json"
                value_options="--container --profile --log-level"
                ;;
              "daemon start")
                opts="--json"
                value_options="--container --profile --log-level"
                ;;
              "daemon stop")
                opts="--force --json --disable"
                value_options="--container --profile --log-level"
                ;;
              "daemon restart")
                opts="--preserve-definition --force --safe --skip-deferral --wait --json"
                value_options="--container --profile --log-level --wait"
                ;;
              "logs")
                opts="--limit --max-bytes --follow --interval --json --plain --no-color --local-time --utc --url --port --token --password --timeout --expect-final"
                value_options="--container --profile --log-level --limit --max-bytes --interval --url --port --token --password --timeout"
                ;;
              "system")
                opts="event heartbeat presence"
                value_options="--container --profile --log-level"
                ;;
              "system event")
                opts="--text --mode --session-key --json --url --port --token --password --timeout --expect-final"
                value_options="--container --profile --log-level --text --mode --session-key --url --port --token --password --timeout"
                ;;
              "system heartbeat")
                opts="disable enable last"
                value_options="--container --profile --log-level"
                ;;
              "system heartbeat last")
                opts="--json --url --port --token --password --timeout --expect-final"
                value_options="--container --profile --log-level --url --port --token --password --timeout"
                ;;
              "system heartbeat enable")
                opts="--json --url --port --token --password --timeout --expect-final"
                value_options="--container --profile --log-level --url --port --token --password --timeout"
                ;;
              "system heartbeat disable")
                opts="--json --url --port --token --password --timeout --expect-final"
                value_options="--container --profile --log-level --url --port --token --password --timeout"
                ;;
              "system presence")
                opts="--json --url --port --token --password --timeout --expect-final"
                value_options="--container --profile --log-level --url --port --token --password --timeout"
                ;;
              "models")
                opts="aliases auth fallbacks image-fallbacks list refresh scan set set-image status --json --status-json --status-plain --agent"
                value_options="--container --profile --log-level --agent"
                ;;
              "models list")
                opts="--all --local --provider --agent --json --plain"
                value_options="--container --profile --log-level --agent --provider"
                ;;
              "models status")
                opts="--json --plain --check --probe --probe-provider --probe-profile --probe-timeout --probe-concurrency --probe-max-tokens --agent"
                value_options="--container --profile --log-level --agent --probe-provider --probe-profile --probe-timeout --probe-concurrency --probe-max-tokens"
                ;;
              "models refresh")
                opts="--json"
                value_options="--container --profile --log-level --agent"
                ;;
              "models set")
                opts=""
                value_options="--container --profile --log-level --agent"
                ;;
              "models set-image")
                opts=""
                value_options="--container --profile --log-level --agent"
                ;;
              "models aliases")
                opts="add list remove"
                value_options="--container --profile --log-level --agent"
                ;;
              "models aliases list")
                opts="--json --plain"
                value_options="--container --profile --log-level --agent"
                ;;
              "models aliases add")
                opts=""
                value_options="--container --profile --log-level --agent"
                ;;
              "models aliases remove")
                opts=""
                value_options="--container --profile --log-level --agent"
                ;;
              "models fallbacks")
                opts="add clear list remove"
                value_options="--container --profile --log-level --agent"
                ;;
              "models fallbacks list")
                opts="--json --plain"
                value_options="--container --profile --log-level --agent"
                ;;
              "models fallbacks add")
                opts=""
                value_options="--container --profile --log-level --agent"
                ;;
              "models fallbacks remove")
                opts=""
                value_options="--container --profile --log-level --agent"
                ;;
              "models fallbacks clear")
                opts=""
                value_options="--container --profile --log-level --agent"
                ;;
              "models image-fallbacks")
                opts="add clear list remove"
                value_options="--container --profile --log-level --agent"
                ;;
              "models image-fallbacks list")
                opts="--json --plain"
                value_options="--container --profile --log-level --agent"
                ;;
              "models image-fallbacks add")
                opts=""
                value_options="--container --profile --log-level --agent"
                ;;
              "models image-fallbacks remove")
                opts=""
                value_options="--container --profile --log-level --agent"
                ;;
              "models image-fallbacks clear")
                opts=""
                value_options="--container --profile --log-level --agent"
                ;;
              "models scan")
                opts="--min-params --max-age-days --provider --max-candidates --timeout --concurrency --no-probe --yes --no-input --set-default --set-image --json"
                value_options="--container --profile --log-level --agent --min-params --max-age-days --provider --max-candidates --timeout --concurrency"
                ;;
              "models auth")
                opts="add list login login-github-copilot logout order paste-api-key paste-token setup-token --agent"
                value_options="--container --profile --log-level --agent"
                ;;
              "models auth list")
                opts="--provider --agent --json"
                value_options="--container --profile --log-level --agent --provider"
                ;;
              "models auth add")
                opts="--agent"
                value_options="--container --profile --log-level --agent"
                ;;
              "models auth logout")
                opts="--agent --yes"
                value_options="--container --profile --log-level --agent"
                ;;
              "models auth login")
                opts="--agent --provider --method --device-code --profile-id --set-default --force"
                value_options="--container --profile --log-level --agent --provider --method --profile-id"
                ;;
              "models auth setup-token")
                opts="--agent --provider --yes"
                value_options="--container --profile --log-level --agent --provider"
                ;;
              "models auth paste-token")
                opts="--agent --provider --profile-id --expires-in"
                value_options="--container --profile --log-level --agent --provider --profile-id --expires-in"
                ;;
              "models auth paste-api-key")
                opts="--agent --provider --profile-id"
                value_options="--container --profile --log-level --agent --provider --profile-id"
                ;;
              "models auth login-github-copilot")
                opts="--agent --yes"
                value_options="--container --profile --log-level --agent"
                ;;
              "models auth order")
                opts="clear get set"
                value_options="--container --profile --log-level --agent"
                ;;
              "models auth order get")
                opts="--provider --agent --json"
                value_options="--container --profile --log-level --agent --provider"
                ;;
              "models auth order set")
                opts="--provider --agent"
                value_options="--container --profile --log-level --agent --provider"
                ;;
              "models auth order clear")
                opts="--provider --agent"
                value_options="--container --profile --log-level --agent --provider"
                ;;
              "promos")
                opts="claim list"
                value_options="--container --profile --log-level"
                ;;
              "promos list")
                opts="--json"
                value_options="--container --profile --log-level"
                ;;
              "promos claim")
                opts="--api-key --set-default"
                value_options="--container --profile --log-level --api-key"
                ;;
              "telemetry")
                opts="off on show"
                value_options="--container --profile --log-level"
                ;;
              "telemetry show")
                opts="--json"
                value_options="--container --profile --log-level"
                ;;
              "telemetry on")
                opts=""
                value_options="--container --profile --log-level"
                ;;
              "telemetry off")
                opts=""
                value_options="--container --profile --log-level"
                ;;
              "infer"|"capability")
                opts="audio embedding image inspect list model tts video web"
                value_options="--container --profile --log-level"
                ;;
              "infer list"|"capability list")
                opts="--json"
                value_options="--container --profile --log-level"
                ;;
              "infer inspect"|"capability inspect")
                opts="--name --json"
                value_options="--container --profile --log-level --name"
                ;;
              "infer model"|"capability model")
                opts="auth inspect list providers run --agent"
                value_options="--container --profile --log-level --agent"
                ;;
              "infer model run"|"capability model run")
                opts="--prompt --file --model --thinking --local --gateway --agent --json"
                value_options="--container --profile --log-level --agent --prompt --file --model --thinking"
                ;;
              "infer model list"|"capability model list")
                opts="--json"
                value_options="--container --profile --log-level --agent"
                ;;
              "infer model inspect"|"capability model inspect")
                opts="--model --json"
                value_options="--container --profile --log-level --agent --model"
                ;;
              "infer model providers"|"capability model providers")
                opts="--agent --json"
                value_options="--container --profile --log-level --agent"
                ;;
              "infer model auth"|"capability model auth")
                opts="login logout status --agent"
                value_options="--container --profile --log-level --agent"
                ;;
              "infer model auth login"|"capability model auth login")
                opts="--provider --method --agent"
                value_options="--container --profile --log-level --agent --provider --method"
                ;;
              "infer model auth logout"|"capability model auth logout")
                opts="--provider --agent --json"
                value_options="--container --profile --log-level --agent --provider"
                ;;
              "infer model auth status"|"capability model auth status")
                opts="--agent --json"
                value_options="--container --profile --log-level --agent"
                ;;
              "infer image"|"capability image")
                opts="describe describe-many edit generate providers --agent"
                value_options="--container --profile --log-level --agent"
                ;;
              "infer image generate"|"capability image generate")
                opts="--prompt --model --count --size --aspect-ratio --resolution --output-format --background --openai-background --openai-moderation --quality --timeout-ms --output --agent --json"
                value_options="--container --profile --log-level --agent --prompt --model --count --size --aspect-ratio --resolution --output-format --background --openai-background --openai-moderation --quality --timeout-ms --output"
                ;;
              "infer image edit"|"capability image edit")
                opts="--file --prompt --model --count --size --aspect-ratio --resolution --output-format --background --openai-background --openai-moderation --quality --timeout-ms --output --agent --json"
                value_options="--container --profile --log-level --agent --file --prompt --model --count --size --aspect-ratio --resolution --output-format --background --openai-background --openai-moderation --quality --timeout-ms --output"
                ;;
              "infer image describe"|"capability image describe")
                opts="--file --prompt --model --timeout-ms --agent --json"
                value_options="--container --profile --log-level --agent --file --prompt --model --timeout-ms"
                ;;
              "infer image describe-many"|"capability image describe-many")
                opts="--file --prompt --model --timeout-ms --agent --json"
                value_options="--container --profile --log-level --agent --file --prompt --model --timeout-ms"
                ;;
              "infer image providers"|"capability image providers")
                opts="--agent --json"
                value_options="--container --profile --log-level --agent"
                ;;
              "infer audio"|"capability audio")
                opts="providers transcribe --agent"
                value_options="--container --profile --log-level --agent"
                ;;
              "infer audio transcribe"|"capability audio transcribe")
                opts="--file --agent --language --prompt --model --json"
                value_options="--container --profile --log-level --agent --file --language --prompt --model"
                ;;
              "infer audio providers"|"capability audio providers")
                opts="--agent --json"
                value_options="--container --profile --log-level --agent"
                ;;
              "infer tts"|"capability tts")
                opts="convert disable enable personas providers set-persona set-provider status voices"
                value_options="--container --profile --log-level"
                ;;
              "infer tts convert"|"capability tts convert")
                opts="--text --channel --voice --provider --model --output --local --gateway --json"
                value_options="--container --profile --log-level --text --channel --voice --provider --model --output"
                ;;
              "infer tts voices"|"capability tts voices")
                opts="--provider --json"
                value_options="--container --profile --log-level --provider"
                ;;
              "infer tts providers"|"capability tts providers")
                opts="--agent --local --gateway --json"
                value_options="--container --profile --log-level --agent"
                ;;
              "infer tts personas"|"capability tts personas")
                opts="--local --gateway --json"
                value_options="--container --profile --log-level"
                ;;
              "infer tts status"|"capability tts status")
                opts="--gateway --json"
                value_options="--container --profile --log-level"
                ;;
              "infer tts enable"|"capability tts enable")
                opts="--local --gateway --json"
                value_options="--container --profile --log-level"
                ;;
              "infer tts disable"|"capability tts disable")
                opts="--local --gateway --json"
                value_options="--container --profile --log-level"
                ;;
              "infer tts set-provider"|"capability tts set-provider")
                opts="--provider --local --gateway --json"
                value_options="--container --profile --log-level --provider"
                ;;
              "infer tts set-persona"|"capability tts set-persona")
                opts="--persona --off --local --gateway --json"
                value_options="--container --profile --log-level --persona"
                ;;
              "infer video"|"capability video")
                opts="describe generate providers --agent"
                value_options="--container --profile --log-level --agent"
                ;;
              "infer video generate"|"capability video generate")
                opts="--prompt --model --size --aspect-ratio --resolution --duration --audio --watermark --timeout-ms --output --agent --json"
                value_options="--container --profile --log-level --agent --prompt --model --size --aspect-ratio --resolution --duration --timeout-ms --output"
                ;;
              "infer video describe"|"capability video describe")
                opts="--file --agent --model --json"
                value_options="--container --profile --log-level --agent --file --model"
                ;;
              "infer video providers"|"capability video providers")
                opts="--agent --json"
                value_options="--container --profile --log-level --agent"
                ;;
              "infer web"|"capability web")
                opts="fetch providers search"
                value_options="--container --profile --log-level"
                ;;
              "infer web search"|"capability web search")
                opts="--query --provider --limit --json"
                value_options="--container --profile --log-level --query --provider --limit"
                ;;
              "infer web fetch"|"capability web fetch")
                opts="--url --provider --format --json"
                value_options="--container --profile --log-level --url --provider --format"
                ;;
              "infer web providers"|"capability web providers")
                opts="--agent --json"
                value_options="--container --profile --log-level --agent"
                ;;
              "infer embedding"|"capability embedding")
                opts="create providers --agent"
                value_options="--container --profile --log-level --agent"
                ;;
              "infer embedding create"|"capability embedding create")
                opts="--text --provider --model --agent --json"
                value_options="--container --profile --log-level --agent --text --provider --model"
                ;;
              "infer embedding providers"|"capability embedding providers")
                opts="--agent --json"
                value_options="--container --profile --log-level --agent"
                ;;
              "approvals"|"exec-approvals")
                opts="allowlist get grants pending resolve set"
                value_options="--container --profile --log-level"
                ;;
              "approvals pending"|"exec-approvals pending")
                opts="--url --token --timeout --json"
                value_options="--container --profile --log-level --url --token --timeout"
                ;;
              "approvals resolve"|"exec-approvals resolve")
                opts="--reason --expires-in-days --url --token --timeout --json"
                value_options="--container --profile --log-level --reason --expires-in-days --url --token --timeout"
                ;;
              "approvals grants"|"exec-approvals grants")
                opts="list revoke"
                value_options="--container --profile --log-level"
                ;;
              "approvals grants list"|"exec-approvals grants list")
                opts="--limit --url --token --timeout --json"
                value_options="--container --profile --log-level --limit --url --token --timeout"
                ;;
              "approvals grants revoke"|"exec-approvals grants revoke")
                opts="--url --token --timeout --json"
                value_options="--container --profile --log-level --url --token --timeout"
                ;;
              "approvals get"|"exec-approvals get")
                opts="--node --gateway --url --token --timeout --json"
                value_options="--container --profile --log-level --node --url --token --timeout"
                ;;
              "approvals set"|"exec-approvals set")
                opts="--node --gateway --file --stdin --url --token --timeout --json"
                value_options="--container --profile --log-level --node --file --url --token --timeout"
                ;;
              "approvals allowlist"|"exec-approvals allowlist")
                opts="add remove"
                value_options="--container --profile --log-level"
                ;;
              "approvals allowlist add"|"exec-approvals allowlist add")
                opts="--node --gateway --agent --url --token --timeout --json"
                value_options="--container --profile --log-level --node --agent --url --token --timeout"
                ;;
              "approvals allowlist remove"|"exec-approvals allowlist remove")
                opts="--node --gateway --agent --url --token --timeout --json"
                value_options="--container --profile --log-level --node --agent --url --token --timeout"
                ;;
              "exec-policy")
                opts="preset set show"
                value_options="--container --profile --log-level"
                ;;
              "exec-policy show")
                opts="--json"
                value_options="--container --profile --log-level"
                ;;
              "exec-policy preset")
                opts="--json"
                value_options="--container --profile --log-level"
                ;;
              "exec-policy set")
                opts="--host --security --ask --ask-fallback --json"
                value_options="--container --profile --log-level --host --security --ask --ask-fallback"
                ;;
              "nodes")
                opts="approve camera describe invoke list location notify pending push reject remove rename screen status"
                value_options="--container --profile --log-level"
                ;;
              "nodes status")
                opts="--connected --last-connected --url --token --timeout --json"
                value_options="--container --profile --log-level --last-connected --url --token --timeout"
                ;;
              "nodes describe")
                opts="--node --url --token --timeout --json"
                value_options="--container --profile --log-level --node --url --token --timeout"
                ;;
              "nodes list")
                opts="--connected --last-connected --url --token --timeout --json"
                value_options="--container --profile --log-level --last-connected --url --token --timeout"
                ;;
              "nodes pending")
                opts="--url --token --timeout --json"
                value_options="--container --profile --log-level --url --token --timeout"
                ;;
              "nodes approve")
                opts="--url --token --timeout --json"
                value_options="--container --profile --log-level --url --token --timeout"
                ;;
              "nodes reject")
                opts="--url --token --timeout --json"
                value_options="--container --profile --log-level --url --token --timeout"
                ;;
              "nodes remove")
                opts="--node --url --token --timeout --json"
                value_options="--container --profile --log-level --node --url --token --timeout"
                ;;
              "nodes rename")
                opts="--node --name --url --token --timeout --json"
                value_options="--container --profile --log-level --node --name --url --token --timeout"
                ;;
              "nodes invoke")
                opts="--node --command --params --invoke-timeout --idempotency-key --url --token --timeout --json"
                value_options="--container --profile --log-level --node --command --params --invoke-timeout --idempotency-key --url --token --timeout"
                ;;
              "nodes notify")
                opts="--node --title --body --sound --priority --delivery --invoke-timeout --url --token --timeout --json"
                value_options="--container --profile --log-level --node --title --body --sound --priority --delivery --invoke-timeout --url --token --timeout"
                ;;
              "nodes push")
                opts="--node --title --body --environment --url --token --timeout --json"
                value_options="--container --profile --log-level --node --title --body --environment --url --token --timeout"
                ;;
              "nodes camera")
                opts="clip list snap"
                value_options="--container --profile --log-level"
                ;;
              "nodes camera list")
                opts="--node --url --token --timeout --json"
                value_options="--container --profile --log-level --node --url --token --timeout"
                ;;
              "nodes camera snap")
                opts="--node --facing --device-id --max-width --quality --delay-ms --invoke-timeout --url --token --timeout --json"
                value_options="--container --profile --log-level --node --facing --device-id --max-width --quality --delay-ms --invoke-timeout --url --token --timeout"
                ;;
              "nodes camera clip")
                opts="--node --facing --device-id --duration --no-audio --invoke-timeout --url --token --timeout --json"
                value_options="--container --profile --log-level --node --facing --device-id --duration --invoke-timeout --url --token --timeout"
                ;;
              "nodes screen")
                opts="record"
                value_options="--container --profile --log-level"
                ;;
              "nodes screen record")
                opts="--node --screen --duration --fps --no-audio --out --invoke-timeout --url --token --timeout --json"
                value_options="--container --profile --log-level --node --screen --duration --fps --out --invoke-timeout --url --token --timeout"
                ;;
              "nodes location")
                opts="get"
                value_options="--container --profile --log-level"
                ;;
              "nodes location get")
                opts="--node --max-age --accuracy --location-timeout --invoke-timeout --url --token --timeout --json"
                value_options="--container --profile --log-level --node --max-age --accuracy --location-timeout --invoke-timeout --url --token --timeout"
                ;;
              "devices")
                opts="approve clear join-code list reject remove rename revoke rotate"
                value_options="--container --profile --log-level"
                ;;
              "devices list")
                opts="--url --token --password --timeout --json"
                value_options="--container --profile --log-level --url --token --password --timeout"
                ;;
              "devices join-code")
                opts="--url --token --password --timeout --json"
                value_options="--container --profile --log-level --url --token --password --timeout"
                ;;
              "devices remove")
                opts="--url --token --password --timeout --json"
                value_options="--container --profile --log-level --url --token --password --timeout"
                ;;
              "devices clear")
                opts="--pending --yes --url --token --password --timeout --json"
                value_options="--container --profile --log-level --url --token --password --timeout"
                ;;
              "devices approve")
                opts="--latest --url --token --password --timeout --json"
                value_options="--container --profile --log-level --url --token --password --timeout"
                ;;
              "devices reject")
                opts="--url --token --password --timeout --json"
                value_options="--container --profile --log-level --url --token --password --timeout"
                ;;
              "devices rename")
                opts="--device --name --url --token --password --timeout --json"
                value_options="--container --profile --log-level --device --name --url --token --password --timeout"
                ;;
              "devices rotate")
                opts="--device --role --scope --url --token --password --timeout --json"
                value_options="--container --profile --log-level --device --role --scope --url --token --password --timeout"
                ;;
              "devices revoke")
                opts="--device --role --url --token --password --timeout --json"
                value_options="--container --profile --log-level --device --role --url --token --password --timeout"
                ;;
              "users")
                opts="link-email list"
                value_options="--container --profile --log-level"
                ;;
              "users list")
                opts="--url --token --timeout --json"
                value_options="--container --profile --log-level --url --token --timeout"
                ;;
              "users link-email")
                opts="--to --url --token --timeout --json"
                value_options="--container --profile --log-level --to --url --token --timeout"
                ;;
              "node")
                opts="identity install restart run start status stop uninstall"
                value_options="--container --profile --log-level"
                ;;
              "node worker")
                opts=""
                value_options="--container --profile --log-level"
                ;;
              "node run")
                opts="--pair --host --port --context-path --tls --no-tls --tls-fingerprint --node-id --display-name --share-installed-apps --no-share-installed-apps"
                value_options="--container --profile --log-level --pair --host --port --context-path --tls-fingerprint --node-id --display-name"
                ;;
              "node status")
                opts="--json"
                value_options="--container --profile --log-level"
                ;;
              "node identity")
                opts="--json"
                value_options="--container --profile --log-level"
                ;;
              "node install")
                opts="--host --port --context-path --tls --no-tls --tls-fingerprint --node-id --display-name --share-installed-apps --no-share-installed-apps --runtime --force --json"
                value_options="--container --profile --log-level --host --port --context-path --tls-fingerprint --node-id --display-name --runtime"
                ;;
              "node uninstall")
                opts="--json"
                value_options="--container --profile --log-level"
                ;;
              "node stop")
                opts="--json"
                value_options="--container --profile --log-level"
                ;;
              "node start")
                opts="--json"
                value_options="--container --profile --log-level"
                ;;
              "node restart")
                opts="--json"
                value_options="--container --profile --log-level"
                ;;
              "connect")
                opts="--service --ephemeral --session-host --target-file --display-name"
                value_options="--container --profile --log-level --target-file --display-name"
                ;;
              "worker")
                opts=""
                value_options="--container --profile --log-level"
                ;;
              "sandbox")
                opts="explain list recreate"
                value_options="--container --profile --log-level"
                ;;
              "sandbox list")
                opts="--json --browser"
                value_options="--container --profile --log-level"
                ;;
              "sandbox recreate")
                opts="--all --session --agent --browser --force"
                value_options="--container --profile --log-level --session --agent"
                ;;
              "sandbox explain")
                opts="--session --agent --json"
                value_options="--container --profile --log-level --session --agent"
                ;;
              "fleet")
                opts="backup create doctor list ls logs restart restore rm start status stop upgrade"
                value_options="--container --profile --log-level"
                ;;
              "fleet create")
                opts="--image --runtime --port --memory --cpus --disk --network --pids-limit --env --gateway-token --no-start --json"
                value_options="--container --profile --log-level --image --runtime --port --memory --cpus --disk --network --pids-limit --env --gateway-token"
                ;;
              "fleet backup")
                opts="--out --max-bytes --json"
                value_options="--container --profile --log-level --out --max-bytes"
                ;;
              "fleet restore")
                opts="--from --force --max-bytes --json"
                value_options="--container --profile --log-level --from --max-bytes"
                ;;
              "fleet doctor")
                opts="--json"
                value_options="--container --profile --log-level"
                ;;
              "fleet list"|"fleet ls")
                opts="--json"
                value_options="--container --profile --log-level"
                ;;
              "fleet status")
                opts="--json"
                value_options="--container --profile --log-level"
                ;;
              "fleet logs")
                opts="--follow --tail --since"
                value_options="--container --profile --log-level --tail --since"
                ;;
              "fleet start")
                opts=""
                value_options="--container --profile --log-level"
                ;;
              "fleet stop")
                opts=""
                value_options="--container --profile --log-level"
                ;;
              "fleet restart")
                opts=""
                value_options="--container --profile --log-level"
                ;;
              "fleet upgrade")
                opts="--image"
                value_options="--container --profile --log-level --image"
                ;;
              "fleet rm")
                opts="--purge-data --force"
                value_options="--container --profile --log-level"
                ;;
              "worktrees")
                opts="create gc list remove restore"
                value_options="--container --profile --log-level"
                ;;
              "worktrees list")
                opts="--json"
                value_options="--container --profile --log-level"
                ;;
              "worktrees create")
                opts="--name --base-ref --json"
                value_options="--container --profile --log-level --name --base-ref"
                ;;
              "worktrees remove")
                opts="--force --json"
                value_options="--container --profile --log-level"
                ;;
              "worktrees restore")
                opts="--json"
                value_options="--container --profile --log-level"
                ;;
              "worktrees gc")
                opts="--json"
                value_options="--container --profile --log-level"
                ;;
              "attach")
                opts="--session --url --token --password --tls-fingerprint --ttl --bin --print-config"
                value_options="--container --profile --log-level --session --url --token --password --tls-fingerprint --ttl --bin"
                ;;
              "resume")
                opts="--handoff --url --token --password --tls-fingerprint"
                value_options="--container --profile --log-level --handoff --url --token --password --tls-fingerprint"
                ;;
              "tui"|"terminal"|"chat")
                opts="--local --url --token --password --tls-fingerprint --session --deliver --thinking --message --timeout-ms --history-limit"
                value_options="--container --profile --log-level --url --token --password --tls-fingerprint --session --thinking --message --timeout-ms --history-limit"
                ;;
              "cron"|"automations")
                opts="add create disable edit enable get list rm remove delete run runs scratch show status --url --port --token --password --timeout --expect-final"
                value_options="--container --profile --log-level --url --port --token --password --timeout"
                ;;
              "cron status"|"automations status")
                opts="--json --url --port --token --password --timeout --expect-final"
                value_options="--container --profile --log-level --url --port --token --password --timeout"
                ;;
              "cron list"|"automations list")
                opts="--all --agent --json --url --port --token --password --timeout --expect-final"
                value_options="--container --profile --log-level --url --port --token --password --timeout --agent"
                ;;
              "cron add"|"cron create"|"automations add"|"automations create")
                opts="--json --name --display-name --description --delete-after-run --keep-after-run --agent --session --session-key --wake --at --every --pacing-min --pacing-max --cron --on-exit --on-exit-cwd --stream-command --stream-cwd --stream-mode --stream-match --stream-batch-ms --stream-max-batch-bytes --tz --stagger --exact --trigger-script --trigger-once --system-event --message --script --script-timeout-seconds --script-tool-budget --command --command-argv --command-cwd --command-env --command-input --thinking --model --fallbacks --timeout-seconds --no-output-timeout-seconds --output-max-bytes --light-context --tools --announce --deliver --no-deliver --webhook --channel --to --thread-id --account --best-effort-deliver --declaration-key --disabled --url --port --token --password --timeout --expect-final"
                value_options="--container --profile --log-level --url --port --token --password --timeout --name --display-name --description --agent --session --session-key --wake --at --every --pacing-min --pacing-max --cron --on-exit --on-exit-cwd --stream-command --stream-cwd --stream-mode --stream-match --stream-batch-ms --stream-max-batch-bytes --tz --stagger --trigger-script --system-event --message --script --script-timeout-seconds --script-tool-budget --command --command-argv --command-cwd --command-env --command-input --thinking --model --fallbacks --timeout-seconds --no-output-timeout-seconds --output-max-bytes --tools --webhook --channel --to --thread-id --account --declaration-key"
                ;;
              "cron rm"|"cron remove"|"cron delete"|"automations rm"|"automations remove"|"automations delete")
                opts="--json --url --port --token --password --timeout --expect-final"
                value_options="--container --profile --log-level --url --port --token --password --timeout"
                ;;
              "cron enable"|"automations enable")
                opts="--json --url --port --token --password --timeout --expect-final"
                value_options="--container --profile --log-level --url --port --token --password --timeout"
                ;;
              "cron disable"|"automations disable")
                opts="--json --url --port --token --password --timeout --expect-final"
                value_options="--container --profile --log-level --url --port --token --password --timeout"
                ;;
              "cron get"|"automations get")
                opts="--json --url --port --token --password --timeout --expect-final"
                value_options="--container --profile --log-level --url --port --token --password --timeout"
                ;;
              "cron show"|"automations show")
                opts="--json --url --port --token --password --timeout --expect-final"
                value_options="--container --profile --log-level --url --port --token --password --timeout"
                ;;
              "cron runs"|"automations runs")
                opts="--json --id --run-id --limit --url --port --token --password --timeout --expect-final"
                value_options="--container --profile --log-level --url --port --token --password --timeout --id --run-id --limit"
                ;;
              "cron run"|"automations run")
                opts="--json --due --wait --wait-timeout --poll-interval --url --port --token --password --timeout --expect-final"
                value_options="--container --profile --log-level --url --port --token --password --timeout --wait-timeout --poll-interval"
                ;;
              "cron scratch"|"automations scratch")
                opts="--json --set --file --unset --expected-revision --url --port --token --password --timeout --expect-final"
                value_options="--container --profile --log-level --url --port --token --password --timeout --set --file --expected-revision"
                ;;
              "cron edit"|"automations edit")
                opts="--json --name --display-name --description --delete-after-run --keep-after-run --agent --session --session-key --wake --at --every --pacing-min --pacing-max --cron --on-exit --on-exit-cwd --stream-command --stream-cwd --stream-mode --stream-match --stream-batch-ms --stream-max-batch-bytes --tz --stagger --exact --trigger-script --trigger-once --system-event --message --script --script-timeout-seconds --script-tool-budget --command --command-argv --command-cwd --command-env --command-input --thinking --model --fallbacks --timeout-seconds --no-output-timeout-seconds --output-max-bytes --light-context --tools --announce --deliver --no-deliver --webhook --channel --to --thread-id --account --best-effort-deliver --clear-display-name --enable --disable --clear-agent --clear-session-key --clear-pacing --clear-trigger --clear-thinking --clear-fallbacks --clear-model --no-light-context --clear-tools --clear-channel --clear-to --clear-thread-id --clear-account --no-best-effort-deliver --failure-alert --no-failure-alert --failure-alert-after --failure-alert-channel --failure-alert-to --failure-alert-cooldown --failure-alert-include-skipped --failure-alert-exclude-skipped --failure-alert-mode --failure-alert-account-id --url --port --token --password --timeout --expect-final"
                value_options="--container --profile --log-level --url --port --token --password --timeout --name --display-name --description --agent --session --session-key --wake --at --every --pacing-min --pacing-max --cron --on-exit --on-exit-cwd --stream-command --stream-cwd --stream-mode --stream-match --stream-batch-ms --stream-max-batch-bytes --tz --stagger --trigger-script --system-event --message --script --script-timeout-seconds --script-tool-budget --command --command-argv --command-cwd --command-env --command-input --thinking --model --fallbacks --timeout-seconds --no-output-timeout-seconds --output-max-bytes --tools --webhook --channel --to --thread-id --account --failure-alert-after --failure-alert-channel --failure-alert-to --failure-alert-cooldown --failure-alert-mode --failure-alert-account-id"
                ;;
              "dns")
                opts="setup"
                value_options="--container --profile --log-level"
                ;;
              "dns setup")
                opts="--domain --apply"
                value_options="--container --profile --log-level --domain"
                ;;
              "docs")
                opts="--json"
                value_options="--container --profile --log-level"
                ;;
              "proxy")
                opts="blob coverage purge query run sessions start validate"
                value_options="--container --profile --log-level"
                ;;
              "proxy start")
                opts="--host --port"
                value_options="--container --profile --log-level --host --port"
                ;;
              "proxy run")
                opts="--host --port"
                value_options="--container --profile --log-level --host --port"
                ;;
              "proxy validate")
                opts="--json --proxy-url --proxy-ca-file --allowed-url --denied-url --apns-reachable --apns-authority --timeout-ms"
                value_options="--container --profile --log-level --proxy-url --proxy-ca-file --allowed-url --denied-url --apns-authority --timeout-ms"
                ;;
              "proxy coverage")
                opts="--json"
                value_options="--container --profile --log-level"
                ;;
              "proxy sessions")
                opts="--json --limit"
                value_options="--container --profile --log-level --limit"
                ;;
              "proxy query")
                opts="--preset --json --session"
                value_options="--container --profile --log-level --preset --session"
                ;;
              "proxy blob")
                opts="--id"
                value_options="--container --profile --log-level --id"
                ;;
              "proxy purge")
                opts=""
                value_options="--container --profile --log-level"
                ;;
              "hooks")
                opts="check disable enable info install list update --agent --json"
                value_options="--container --profile --log-level --agent"
                ;;
              "hooks list")
                opts="--agent --eligible --json -v --verbose"
                value_options="--container --profile --log-level --agent"
                ;;
              "hooks info")
                opts="--agent --json"
                value_options="--container --profile --log-level --agent"
                ;;
              "hooks check")
                opts="--agent --json"
                value_options="--container --profile --log-level --agent"
                ;;
              "hooks enable")
                opts="--agent"
                value_options="--container --profile --log-level --agent"
                ;;
              "hooks disable")
                opts="--agent"
                value_options="--container --profile --log-level --agent"
                ;;
              "hooks relay")
                opts="--provider --relay-id --state-db --generation --event --pre-tool-use-unavailable --timeout"
                value_options="--container --profile --log-level --agent --provider --relay-id --state-db --generation --event --pre-tool-use-unavailable --timeout"
                ;;
              "hooks install")
                opts="-l --link --pin --force --acknowledge-install-policy-warning"
                value_options="--container --profile --log-level --agent"
                ;;
              "hooks update")
                opts="--all --dry-run --acknowledge-install-policy-warning"
                value_options="--container --profile --log-level --agent"
                ;;
              "webhooks")
                opts="gmail"
                value_options="--container --profile --log-level"
                ;;
              "webhooks gmail")
                opts="run setup"
                value_options="--container --profile --log-level"
                ;;
              "webhooks gmail setup")
                opts="--account --project --topic --subscription --label --hook-url --hook-token --push-token --bind --port --path --include-body --max-bytes --renew-minutes --tailscale --tailscale-path --tailscale-target --push-endpoint --json"
                value_options="--container --profile --log-level --account --project --topic --subscription --label --hook-url --hook-token --push-token --bind --port --path --max-bytes --renew-minutes --tailscale --tailscale-path --tailscale-target --push-endpoint"
                ;;
              "webhooks gmail run")
                opts="--account --topic --subscription --label --hook-url --hook-token --push-token --bind --port --path --include-body --max-bytes --renew-minutes --tailscale --tailscale-path --tailscale-target"
                value_options="--container --profile --log-level --account --topic --subscription --label --hook-url --hook-token --push-token --bind --port --path --max-bytes --renew-minutes --tailscale --tailscale-path --tailscale-target"
                ;;
              "qr")
                opts="--remote --url --public-url --token --password --limited --voice-node --setup-code-only --no-ascii --json"
                value_options="--container --profile --log-level --url --public-url --token --password"
                ;;
              "clawbot")
                opts="qr"
                value_options="--container --profile --log-level"
                ;;
              "clawbot qr")
                opts="--remote --url --public-url --token --password --limited --voice-node --setup-code-only --no-ascii --json"
                value_options="--container --profile --log-level --url --public-url --token --password"
                ;;
              "pairing")
                opts="approve list"
                value_options="--container --profile --log-level"
                ;;
              "pairing list")
                opts="--channel --account --json"
                value_options="--container --profile --log-level --channel --account"
                ;;
              "pairing approve")
                opts="--channel --account --notify"
                value_options="--container --profile --log-level --channel --account"
                ;;
              "plugins")
                opts="build disable doctor enable init inspect info install list marketplace registry search uninstall update validate"
                value_options="--container --profile --log-level"
                ;;
              "plugins list")
                opts="--json --enabled --verbose"
                value_options="--container --profile --log-level"
                ;;
              "plugins search")
                opts="--limit --json"
                value_options="--container --profile --log-level --limit"
                ;;
              "plugins inspect"|"plugins info")
                opts="--all --runtime --json"
                value_options="--container --profile --log-level"
                ;;
              "plugins enable")
                opts="--accept-capabilities"
                value_options="--container --profile --log-level"
                ;;
              "plugins disable")
                opts=""
                value_options="--container --profile --log-level"
                ;;
              "plugins uninstall")
                opts="--keep-files --keep-config --force --dry-run"
                value_options="--container --profile --log-level"
                ;;
              "plugins install")
                opts="-l --link --force --pin --accept-capabilities --dangerously-force-unsafe-install --acknowledge-install-policy-warning --marketplace"
                value_options="--container --profile --log-level --marketplace"
                ;;
              "plugins update")
                opts="--all --dry-run --accept-capabilities --dangerously-force-unsafe-install --acknowledge-install-policy-warning"
                value_options="--container --profile --log-level"
                ;;
              "plugins registry")
                opts="--json --refresh"
                value_options="--container --profile --log-level"
                ;;
              "plugins doctor")
                opts="--json"
                value_options="--container --profile --log-level"
                ;;
              "plugins build")
                opts="--root --entry --check"
                value_options="--container --profile --log-level --root --entry"
                ;;
              "plugins validate")
                opts="--root --entry --json"
                value_options="--container --profile --log-level --root --entry"
                ;;
              "plugins init")
                opts="--directory --name --type --force"
                value_options="--container --profile --log-level --directory --name --type"
                ;;
              "plugins marketplace")
                opts="entries list refresh"
                value_options="--container --profile --log-level"
                ;;
              "plugins marketplace entries")
                opts="--feed-profile --feed-url --offline --json"
                value_options="--container --profile --log-level --feed-profile --feed-url"
                ;;
              "plugins marketplace refresh")
                opts="--feed-profile --feed-url --expected-sha256 --json"
                value_options="--container --profile --log-level --feed-profile --feed-url --expected-sha256"
                ;;
              "plugins marketplace list")
                opts="--json"
                value_options="--container --profile --log-level"
                ;;
              "channels")
                opts="add capabilities dead-letters list login logout logs remove resolve status --agent"
                value_options="--container --profile --log-level --agent"
                ;;
              "channels list")
                opts="--all --json"
                value_options="--container --profile --log-level --agent"
                ;;
              "channels status")
                opts="--channel --probe --timeout --json"
                value_options="--container --profile --log-level --agent --channel --timeout"
                ;;
              "channels capabilities")
                opts="--channel --account --target --timeout --json"
                value_options="--container --profile --log-level --agent --channel --account --target --timeout"
                ;;
              "channels resolve")
                opts="--channel --account --agent --kind --json"
                value_options="--container --profile --log-level --agent --channel --account --kind"
                ;;
              "channels logs")
                opts="--channel --lines --json"
                value_options="--container --profile --log-level --agent --channel --lines"
                ;;
              "channels dead-letters")
                opts="list resubmit"
                value_options="--container --profile --log-level --agent"
                ;;
              "channels dead-letters list")
                opts="--channel --account --limit --json"
                value_options="--container --profile --log-level --agent --channel --account --limit"
                ;;
              "channels dead-letters resubmit")
                opts="--channel --account --json"
                value_options="--container --profile --log-level --agent --channel --account"
                ;;
              "channels add")
                opts="--channel --account --name --advertised-url --peer-name --peer-token --token --token-file --use-env --audience-type --audience --webhook-path --webhook-url --private-key --relay-urls --relay-url --bot-token --http-url --base-url --url --secret --password --secret-file --homeserver --user-id --access-token --device-name --avatar-url --initial-sync-limit --proxy --dangerously-allow-private-network --profile --channel-access-token --channel-secret --code --workspace --default-to --allow-from --agent-activity --account-sid --auth-token --from-number --messaging-service-sid --public-webhook-url --dm-policy --ship --group-channels --dm-allowlist --auto-discover-channels --no-auto-discover-channels --owner-ship --cli-path --db-path --service --region --host --port --tls --nick --username --realname --channels --signal-number --signal-transport --http-host --http-port --app-token --user-token --signing-secret --identity --mode --auth-dir"
                value_options="--container --profile --log-level --agent --channel --account --name --advertised-url --peer-name --peer-token --token --token-file --audience-type --audience --webhook-path --webhook-url --private-key --relay-urls --relay-url --bot-token --http-url --base-url --url --secret --password --secret-file --homeserver --user-id --access-token --device-name --avatar-url --initial-sync-limit --proxy --channel-access-token --channel-secret --code --workspace --default-to --allow-from --account-sid --auth-token --from-number --messaging-service-sid --public-webhook-url --dm-policy --ship --group-channels --dm-allowlist --owner-ship --cli-path --db-path --service --region --host --port --nick --username --realname --channels --signal-number --signal-transport --http-host --http-port --app-token --user-token --signing-secret --identity --mode --auth-dir"
                ;;
              "channels remove")
                opts="--channel --account --delete"
                value_options="--container --profile --log-level --agent --channel --account"
                ;;
              "channels login")
                opts="--channel --account --verbose"
                value_options="--container --profile --log-level --agent --channel --account"
                ;;
              "channels logout")
                opts="--channel --account"
                value_options="--container --profile --log-level --agent --channel --account"
                ;;
              "directory")
                opts="groups peers self"
                value_options="--container --profile --log-level"
                ;;
              "directory self")
                opts="--channel --account --json"
                value_options="--container --profile --log-level --channel --account"
                ;;
              "directory peers")
                opts="list"
                value_options="--container --profile --log-level"
                ;;
              "directory peers list")
                opts="--channel --account --json --query --limit"
                value_options="--container --profile --log-level --channel --account --query --limit"
                ;;
              "directory groups")
                opts="list members"
                value_options="--container --profile --log-level"
                ;;
              "directory groups list")
                opts="--channel --account --json --query --limit"
                value_options="--container --profile --log-level --channel --account --query --limit"
                ;;
              "directory groups members")
                opts="--group-id --channel --account --json --limit"
                value_options="--container --profile --log-level --group-id --channel --account --limit"
                ;;
              "security")
                opts="audit"
                value_options="--container --profile --log-level"
                ;;
              "security audit")
                opts="--deep --auth --token --password --fix --json"
                value_options="--container --profile --log-level --auth --token --password"
                ;;
              "secrets")
                opts="apply audit configure reload store"
                value_options="--container --profile --log-level"
                ;;
              "secrets store")
                opts="get import list rm set"
                value_options="--container --profile --log-level"
                ;;
              "secrets store list")
                opts="--scope --json --plain"
                value_options="--container --profile --log-level --scope"
                ;;
              "secrets store set")
                opts="--value --value-file --kind --allow-host --clear-allowed-hosts --scope --dry-run"
                value_options="--container --profile --log-level --value --value-file --kind --allow-host --scope"
                ;;
              "secrets store get")
                opts="--scope --json --plain"
                value_options="--container --profile --log-level --scope"
                ;;
              "secrets store rm")
                opts="--scope --dry-run --yes"
                value_options="--container --profile --log-level --scope"
                ;;
              "secrets store import")
                opts="--from --kind --scope --dry-run --yes"
                value_options="--container --profile --log-level --from --kind --scope"
                ;;
              "secrets reload")
                opts="--json --url --port --token --password --timeout --expect-final"
                value_options="--container --profile --log-level --url --port --token --password --timeout"
                ;;
              "secrets audit")
                opts="--check --allow-exec --json"
                value_options="--container --profile --log-level"
                ;;
              "secrets configure")
                opts="--apply --yes --providers-only --skip-provider-setup --agent --allow-exec --plan-out --json"
                value_options="--container --profile --log-level --agent --plan-out"
                ;;
              "secrets apply")
                opts="--from --dry-run --allow-exec --json"
                value_options="--container --profile --log-level --from"
                ;;
              "skills")
                opts="check curator info install list search update verify workshop --agent --json"
                value_options="--container --profile --log-level --agent"
                ;;
              "skills search")
                opts="--limit --json"
                value_options="--container --profile --log-level --agent --limit"
                ;;
              "skills install")
                opts="--version --force --force-install --acknowledge-install-policy-warning --global --agent --as"
                value_options="--container --profile --log-level --agent --version --as"
                ;;
              "skills update")
                opts="--all --force --force-install --acknowledge-install-policy-warning --global --agent"
                value_options="--container --profile --log-level --agent"
                ;;
              "skills verify")
                opts="--version --tag --card --json --global --agent"
                value_options="--container --profile --log-level --agent --version --tag"
                ;;
              "skills curator")
                opts="pin restore status unpin --json"
                value_options="--container --profile --log-level --agent"
                ;;
              "skills curator status")
                opts="--json"
                value_options="--container --profile --log-level --agent"
                ;;
              "skills curator pin")
                opts="--json"
                value_options="--container --profile --log-level --agent"
                ;;
              "skills curator unpin")
                opts="--json"
                value_options="--container --profile --log-level --agent"
                ;;
              "skills curator restore")
                opts="--json"
                value_options="--container --profile --log-level --agent"
                ;;
              "skills workshop")
                opts="apply evaluate inspect list propose-create propose-update quarantine reject revise --agent"
                value_options="--container --profile --log-level --agent"
                ;;
              "skills workshop list")
                opts="--json --agent"
                value_options="--container --profile --log-level --agent"
                ;;
              "skills workshop inspect")
                opts="--json --agent"
                value_options="--container --profile --log-level --agent"
                ;;
              "skills workshop propose-create")
                opts="--name --description --proposal --proposal-dir --goal --evidence --json --agent"
                value_options="--container --profile --log-level --agent --name --description --proposal --proposal-dir --goal --evidence"
                ;;
              "skills workshop propose-update")
                opts="--proposal --proposal-dir --description --goal --evidence --json --agent"
                value_options="--container --profile --log-level --agent --proposal --proposal-dir --description --goal --evidence"
                ;;
              "skills workshop revise")
                opts="--proposal --proposal-dir --description --goal --evidence --json --agent"
                value_options="--container --profile --log-level --agent --proposal --proposal-dir --description --goal --evidence"
                ;;
              "skills workshop evaluate")
                opts="--correlation-id --json --agent"
                value_options="--container --profile --log-level --agent --correlation-id"
                ;;
              "skills workshop apply")
                opts="--json --agent"
                value_options="--container --profile --log-level --agent"
                ;;
              "skills workshop reject")
                opts="--reason --json --agent"
                value_options="--container --profile --log-level --agent --reason"
                ;;
              "skills workshop quarantine")
                opts="--reason --json --agent"
                value_options="--container --profile --log-level --agent --reason"
                ;;
              "skills list")
                opts="--json --eligible -v --verbose --agent"
                value_options="--container --profile --log-level --agent"
                ;;
              "skills info")
                opts="--json --agent"
                value_options="--container --profile --log-level --agent"
                ;;
              "skills check")
                opts="--agent --json"
                value_options="--container --profile --log-level --agent"
                ;;
              "update")
                opts="cleanup repair status wizard --json --no-restart --dry-run --channel --tag --timeout --yes --accept-capabilities"
                value_options="--container --profile --log-level --channel --tag --timeout"
                ;;
              "update cleanup")
                opts="--dry-run --json --yes"
                value_options="--container --profile --log-level --channel --tag --timeout"
                ;;
              "update repair")
                opts="--json --channel --timeout --yes --accept-capabilities --no-restart"
                value_options="--container --profile --log-level --channel --tag --timeout"
                ;;
              "update finalize")
                opts="--json --channel --timeout --yes --accept-capabilities --no-restart"
                value_options="--container --profile --log-level --channel --tag --timeout"
                ;;
              "update wizard")
                opts="--accept-capabilities --timeout"
                value_options="--container --profile --log-level --channel --tag --timeout"
                ;;
              "update status")
                opts="--json --timeout"
                value_options="--container --profile --log-level --channel --tag --timeout"
                ;;
              "browser")
                opts="batch click click-coords close console cookie-sync cookies create-profile delete-profile dialog doctor download drag errors evaluate extension fill focus highlight hover import-profile navigate open pdf press profiles requests reset-profile resize responsebody screenshot scrollintoview select set snapshot start status stop storage system-profiles tab tabs trace type upload wait waitfordownload --browser-profile --json --url --port --token --password --timeout --expect-final"
                value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
                ;;
              "browser status")
                opts=""
                value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
                ;;
              "browser start")
                opts=""
                value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
                ;;
              "browser stop")
                opts=""
                value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
                ;;
              "browser reset-profile")
                opts=""
                value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
                ;;
              "browser tabs")
                opts=""
                value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
                ;;
              "browser tab")
                opts=""
                value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
                ;;
              "browser open")
                opts=""
                value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
                ;;
              "browser focus")
                opts=""
                value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
                ;;
              "browser close")
                opts=""
                value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
                ;;
              "browser profiles")
                opts=""
                value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
                ;;
              "browser system-profiles")
                opts=""
                value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
                ;;
              "browser import-profile")
                opts=""
                value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
                ;;
              "browser create-profile")
                opts=""
                value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
                ;;
              "browser delete-profile")
                opts=""
                value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
                ;;
              "browser doctor")
                opts="--deep"
                value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
                ;;
              "browser cookie-sync")
                opts=""
                value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
                ;;
              "browser screenshot")
                opts=""
                value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
                ;;
              "browser snapshot")
                opts=""
                value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
                ;;
              "browser navigate")
                opts=""
                value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
                ;;
              "browser resize")
                opts=""
                value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
                ;;
              "browser click")
                opts=""
                value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
                ;;
              "browser click-coords")
                opts=""
                value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
                ;;
              "browser type")
                opts=""
                value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
                ;;
              "browser press")
                opts=""
                value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
                ;;
              "browser hover")
                opts=""
                value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
                ;;
              "browser scrollintoview")
                opts=""
                value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
                ;;
              "browser drag")
                opts=""
                value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
                ;;
              "browser select")
                opts=""
                value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
                ;;
              "browser upload")
                opts=""
                value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
                ;;
              "browser waitfordownload")
                opts=""
                value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
                ;;
              "browser download")
                opts=""
                value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
                ;;
              "browser dialog")
                opts=""
                value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
                ;;
              "browser fill")
                opts=""
                value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
                ;;
              "browser wait")
                opts=""
                value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
                ;;
              "browser evaluate")
                opts=""
                value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
                ;;
              "browser batch")
                opts=""
                value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
                ;;
              "browser console")
                opts=""
                value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
                ;;
              "browser pdf")
                opts=""
                value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
                ;;
              "browser responsebody")
                opts=""
                value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
                ;;
              "browser highlight")
                opts=""
                value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
                ;;
              "browser errors")
                opts=""
                value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
                ;;
              "browser requests")
                opts=""
                value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
                ;;
              "browser trace")
                opts=""
                value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
                ;;
              "browser cookies")
                opts=""
                value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
                ;;
              "browser storage")
                opts=""
                value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
                ;;
              "browser set")
                opts=""
                value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
                ;;
              "browser extension")
                opts=""
                value_options="--container --profile --log-level --browser-profile --url --port --token --password --timeout"
                ;;
              "file-transfer")
                opts="approvals"
                value_options="--container --profile --log-level"
                ;;
              "file-transfer approvals")
                opts="migrate"
                value_options="--container --profile --log-level"
                ;;
              "file-transfer approvals migrate")
                opts="--dry-run --json"
                value_options="--container --profile --log-level"
                ;;
              "memory")
                opts="forget index promote promote-explain rem-backfill rem-harness search session-backfill status"
                value_options="--container --profile --log-level"
                ;;
              "memory status")
                opts="--agent --json --deep --index --fix --verbose"
                value_options="--container --profile --log-level --agent"
                ;;
              "memory index")
                opts="--agent --force --verbose"
                value_options="--container --profile --log-level --agent"
                ;;
              "memory search")
                opts="--query --agent --max-results --min-score --json"
                value_options="--container --profile --log-level --query --agent --max-results --min-score"
                ;;
              "memory forget")
                opts="--agent --session --hook-source --participant --since --dry-run --json"
                value_options="--container --profile --log-level --agent --session --hook-source --participant --since"
                ;;
              "memory promote")
                opts="--agent --limit --min-score --min-recall-count --min-unique-queries --apply --include-promoted --json"
                value_options="--container --profile --log-level --agent --limit --min-score --min-recall-count --min-unique-queries"
                ;;
              "memory promote-explain")
                opts="--agent --include-promoted --json"
                value_options="--container --profile --log-level --agent"
                ;;
              "memory rem-harness")
                opts="--agent --path --grounded --include-promoted --json"
                value_options="--container --profile --log-level --agent --path"
                ;;
              "memory rem-backfill")
                opts="--agent --path --rollback --stage-short-term --rollback-short-term --json"
                value_options="--container --profile --log-level --agent --path"
                ;;
              "memory session-backfill")
                opts="--agent --from --to --limit-days --rem --apply --rollback --archive-files --json"
                value_options="--container --profile --log-level --agent --from --to --limit-days --archive-files"
                ;;
              "workboard")
                opts="create dispatch list move show"
                value_options="--container --profile --log-level"
                ;;
              "workboard list")
                opts="--board --status --include-archived --json"
                value_options="--container --profile --log-level --board --status"
                ;;
              "workboard create")
                opts="--notes --status --priority --agent --board --labels --json"
                value_options="--container --profile --log-level --notes --status --priority --agent --board --labels"
                ;;
              "workboard show")
                opts="--json"
                value_options="--container --profile --log-level"
                ;;
              "workboard move")
                opts="--status --json"
                value_options="--container --profile --log-level --status"
                ;;
              "workboard dispatch")
                opts="--board --max-starts --admin --json --url --port --token --password --timeout --expect-final"
                value_options="--container --profile --log-level --board --max-starts --url --port --token --password --timeout"
                ;;
            esac
            ;;
        esac
    done

    choice_flag="${COMP_WORDS[COMP_CWORD-1]}"
    choice_prefix="${cur}"
    choice_completion_prefix=""
    if [[ "${cur}" == -*=* ]]; then
        choice_flag="${cur%%=*}"
        choice_prefix="${cur#*=}"
        choice_completion_prefix="${choice_flag}="
    elif [[ "${choice_flag}" == "=" ]]; then
        choice_flag="${COMP_WORDS[COMP_CWORD-2]}"
    fi
    if [[ "${choice_flag}" == -??* && "${choice_flag}" != --* ]]; then
        short_group="${choice_flag#-}"
        for ((short_index = 0; short_index < ${#short_group}; short_index++)); do
            short_flag="-${short_group:short_index:1}"
            if [[ " ${value_options} " == *" ${short_flag} "* ]]; then
                if ((short_index == ${#short_group} - 1)); then
                    choice_flag="${short_flag}"
                fi
                break
            fi
        done
    fi
    if [[ "${cur}" == -??* && "${cur}" != --* && "${cur}" != *=* ]]; then
        short_group="${cur#-}"
        for ((short_index = 0; short_index < ${#short_group}; short_index++)); do
            short_flag="-${short_group:short_index:1}"
            if [[ " ${value_options} " == *" ${short_flag} "* ]]; then
                choice_flag="${short_flag}"
                choice_prefix="${short_group:short_index+1}"
                choice_completion_prefix="-${short_group:0:short_index+1}"
                break
            fi
        done
    fi

    case "${command_path}" in
        "completion")
            case "${choice_flag}" in
            "-s"|"--shell")
                local -a choice_values=(zsh bash powershell fish)
                local choice
                for choice in "${choice_values[@]}"; do
                    if [[ "${choice}" == "${choice_prefix}"* ]]; then
                        COMPREPLY+=("${choice_completion_prefix}${choice}")
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
                local choice
                for choice in "${choice_values[@]}"; do
                    if [[ "${choice}" == "${choice_prefix}"* ]]; then
                        COMPREPLY+=("${choice_completion_prefix}${choice}")
                    fi
                done
                if true; then
                    return
                fi
                ;;
            "--delivery")
                local -a choice_values=(system overlay auto)
                local choice
                for choice in "${choice_values[@]}"; do
                    if [[ "${choice}" == "${choice_prefix}"* ]]; then
                        COMPREPLY+=("${choice_completion_prefix}${choice}")
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
                local choice
                for choice in "${choice_values[@]}"; do
                    if [[ "${choice}" == "${choice_prefix}"* ]]; then
                        COMPREPLY+=("${choice_completion_prefix}${choice}")
                    fi
                done
                if true; then
                    return
                fi
                ;;
            esac
            ;;
    esac

    COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
}

complete -F _openclaw_completion openclaw

