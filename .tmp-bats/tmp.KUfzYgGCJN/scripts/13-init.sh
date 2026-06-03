# Minimal test stub — keeps Module Version for version-computation tests.
# Module Version: 1
mkdir -p "$OC_ROOT" "$OC_LOGS" "$OC_BACKUPS" "$LLAMA_DRIVE_ROOT/.llm" 2>/dev/null || true
__TAC_BG_PIDS=()
function __tac_exit_cleanup() {
    local pid; for pid in "${__TAC_BG_PIDS[@]}"; do kill "$pid" 2>/dev/null; done
}
