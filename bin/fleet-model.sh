#!/usr/bin/env bash
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 3
# fleet-model.sh — keep the FLEET off a lane that a measurement run is about to deny.
#
# WHY. A clean-room sweep stops llama-cuda-qwen3coder-30b-chat.service to free ~20 GB, and that
# service is the fleet's PRIMARY model (agents.defaults.model.primary).  Measured 2026-11-06
# 23:41-23:42: the gateway then logged ECONNREFUSED for cuda-qwen3coder-30b on every subagent
# run and failover fired each time - a denied lane tried, failed, and only then fell back to
# deepseek/deepseek-flash.  Wayne's ruling 2026-11-07: during a sweep the fleet USES
# deepseek-flash, because the GPU lane will be denied to them.
#
# The switch is a PLATFORM change, not a config poke: it goes through `openclaw models set`
# (docs/cli/models.md), the documented writer for the global default.  The previous primary is
# saved to a state file first, so restore puts back exactly what was there - never a guess, and
# never "the default I remember".
#
# IDEMPOTENT BY DESIGN. `sweep` with the sweep model already primary saves nothing and says so;
# `restore` with no state file is a no-op.  Both properties matter because the EXIT trap of a
# wrapper and the resume supervisor may both call restore, and either may run after a SIGKILL.
set -uo pipefail

STATE_DIR="${TAC_STATE_DIR:-$HOME/.local/state/tactical-console}"
STATE="$STATE_DIR/fleet-model.saved"
SWEEP_PRIMARY="${TAC_SWEEP_PRIMARY:-deepseek/deepseek-flash}"
CONFIG="${OPENCLAW_CONFIG:-$HOME/.openclaw/openclaw.json}"

_current_primary() {
    python3 - "$CONFIG" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    print("")
    raise SystemExit(0)
m = (d.get("agents", {}).get("defaults", {}) or {}).get("model") or {}
print(m.get("primary") or "")
PY
}

_set_primary() {
    # swallow-ok: the failure is reported by the caller on the next line, which names the model
    openclaw models set "$1" >/dev/null 2>&1
}

case "${1:-status}" in
    sweep)
        mkdir -p "$STATE_DIR"
        _cur="$(_current_primary)"
        if [[ -z "$_cur" ]]; then
            echo 'fleet-model: cannot read the current primary from '"$CONFIG"' — refusing to switch blind' >&2
            exit 2
        fi
        if [[ "$_cur" == "$SWEEP_PRIMARY" ]]; then
            echo "fleet-model: primary is already $SWEEP_PRIMARY — nothing to save"
            exit 0
        fi
        printf '%s\n' "$_cur" > "$STATE"
        if ! _set_primary "$SWEEP_PRIMARY"; then
            echo "fleet-model: FAILED to set $SWEEP_PRIMARY — the fleet will keep being denied the lane" >&2
            rm -f "$STATE"
            exit 2
        fi
        echo "fleet-model: fleet primary $_cur -> $SWEEP_PRIMARY (previous saved)"
        ;;
    restore)
        if [[ ! -f "$STATE" ]]; then
            echo 'fleet-model: no saved primary — nothing to restore'
            exit 0
        fi
        _saved="$(cat "$STATE")"
        if [[ -z "$_saved" ]]; then
            echo 'fleet-model: saved primary is empty — leaving the fleet on the sweep model' >&2
            exit 2
        fi
        if ! _set_primary "$_saved"; then
            echo "fleet-model: FAILED to restore $_saved — set it by hand: openclaw models set $_saved" >&2
            exit 2
        fi
        rm -f "$STATE"
        echo "fleet-model: fleet primary restored to $_saved"
        ;;
    status)
        echo "primary=$(_current_primary)"
        # swallow-ok: an absent state file IS the answer here - "none" means no switch is pending
        echo "saved=$(cat "$STATE" 2>/dev/null || echo none)"
        ;;
    *)
        echo "usage: fleet-model.sh sweep|restore|status" >&2
        exit 64
        ;;
esac
# end of file
