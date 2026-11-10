#!/usr/bin/env bash
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 6
#   v6 (2026-11-09): inline JSON parsing uses the repository-venv resolver
#       (tools/python-runtime.sh), not bare `python3`.  AUD-008 routed five callers
#       through it; this script regressed the rule when it was added.
#   v5 (2026-11-08): Wayne's ruling — the sweep model is cheaper-inference's
#       deepseek-v4.1-flash-1017, not the direct deepseek/deepseek-flash lane.
#       Only the default moved; TAC_SWEEP_PRIMARY still overrides.
#   v4 (2026-11-07): §18.3 debt — a purpose comment above each function (9.5), one
#       `warn`/`die` pair instead of five hand-written `>&2` (10.7), and the usage code
#       annotated (9.7).  No behaviour change: the same text reaches stderr, and a refusal
#       still exits 2 while usage still exits 64.
# fleet-model.sh — keep the FLEET off a lane that a measurement run is about to deny.
#
# WHY. A clean-room sweep stops llama-cuda-qwen3coder-30b-chat.service to free ~20 GB, and that
# service is the fleet's PRIMARY model (agents.defaults.model.primary).  Measured 2026-11-06
# 23:41-23:42: the gateway then logged ECONNREFUSED for cuda-qwen3coder-30b on every subagent
# run and failover fired each time - a denied lane tried, failed, and only then fell back to
# the hosted API.  Wayne's ruling 2026-11-07: during a sweep the fleet USES a hosted
# deepseek lane, because the GPU lane will be denied to them.  Refined 2026-11-08: that
# lane is cheaper-inference/deepseek-v4.1-flash-1017.
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

_FLEET_REPO_ROOT="$(cd "$(dirname "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source=tools/python-runtime.sh
source "$_FLEET_REPO_ROOT/tools/python-runtime.sh"
FLEET_PYTHON="$(_tac_python_path "$_FLEET_REPO_ROOT")"

STATE_DIR="${TAC_STATE_DIR:-$HOME/.local/state/tactical-console}"
STATE="$STATE_DIR/fleet-model.saved"
SWEEP_PRIMARY="${TAC_SWEEP_PRIMARY:-cheaper-inference/deepseek-v4.1-flash-1017}"
CONFIG="${OPENCLAW_CONFIG:-$HOME/.openclaw/openclaw.json}"

# warn - the tool's ONE stderr path, so every refusal has the same shape (10.7).
warn() { printf '%s\n' "$*" >&2; }
# die - a refusal: the message through warn, then exit 2 (2 = refused, nothing changed).
die() { warn "fleet-model: $*"; exit 2; }

# _current_primary - the fleet's primary model id as the config holds it, or empty when
# the config cannot be read (the caller refuses rather than switching blind).
_current_primary() {
    "$FLEET_PYTHON" - "$CONFIG" <<'PY'
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

# _set_primary <model-id> - write the global default through the documented writer; the
# caller reports the failure, so this stays quiet and returns the writer's status.
_set_primary() {
    # swallow-ok: the failure is reported by the caller on the next line, which names the model
    openclaw models set "$1" >/dev/null 2>&1
}

case "${1:-status}" in
    sweep)
        mkdir -p "$STATE_DIR"
        _cur="$(_current_primary)"
        if [[ -z "$_cur" ]]; then
            die "cannot read the current primary from $CONFIG — refusing to switch blind"
        fi
        if [[ "$_cur" == "$SWEEP_PRIMARY" ]]; then
            echo "fleet-model: primary is already $SWEEP_PRIMARY — nothing to save"
            exit 0
        fi
        printf '%s\n' "$_cur" > "$STATE"
        if ! _set_primary "$SWEEP_PRIMARY"; then
            rm -f "$STATE"
            die "FAILED to set $SWEEP_PRIMARY — the fleet will keep being denied the lane"
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
            die "saved primary is empty — leaving the fleet on the sweep model"
        fi
        if ! _set_primary "$_saved"; then
            die "FAILED to restore $_saved — set it by hand: openclaw models set $_saved"
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
        warn "usage: fleet-model.sh sweep|restore|status"
        # 64 = usage (sysexits EX_USAGE), distinct from a refusal's 2.
        exit 64
        ;;
esac
# end of file
