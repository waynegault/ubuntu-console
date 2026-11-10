#!/usr/bin/env bash
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 7
#   v7 (2026-11-10, card FLEET-MODEL-SAVED-SLOT-EMPTY-001): the saved slot is written with
#       tools.fsutil.atomic_write_text (fsync + os.replace) and READ BACK before the
#       switch, so a lost write can no longer leave a 0-byte slot that makes the return
#       impossible.  Measured 2026-11-10T00:53Z: the slot was 0 bytes after a sweep,
#       `restore` correctly refused, and the fleet stayed on the paid lane.  A save that
#       cannot be verified now refuses the switch and leaves the primary UNCHANGED.
#       `restore` on an empty slot still refuses (exit 2) and now names the ruled
#       baseline as the recovery command; `status` reports that state as RED with exit 1.
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
# The ruled baseline the fleet must return to (Wayne's policy, heartbeat-policy.md:32;
# pinned by tests/unit/83-fleet-model.bats).  Named HERE so the recovery message a broken
# slot prints cannot drift from the model an operator is told to set.
BASELINE_PRIMARY="cuda-qwen3coder-30b/qwen3-coder-30b-gpu"
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

# _save_primary <model-id> - persist the previous primary atomically, then READ IT BACK.
# Non-zero means "not saved", and the caller must then refuse the switch: the slot is the
# only record of what to restore, so a slot that cannot be written AND verified is worse
# than no switch at all (measured 2026-11-10T00:53Z, a 0-byte slot left the fleet on the
# paid lane).  The write goes through tools/fsutil.py - fsync, then os.replace - so a
# crash mid-write leaves the OLD bytes rather than a truncated file.
_save_primary() {
    local value="$1" readback=""
    if ! PYTHONPATH="$_FLEET_REPO_ROOT" "$FLEET_PYTHON" - "$STATE" "$value" <<'PY'
import sys
from tools.fsutil import atomic_write_text

try:
    atomic_write_text(sys.argv[1], sys.argv[2] + "\n")
except OSError as exc:
    sys.stderr.write(f"cannot write {sys.argv[1]}: {exc}\n")
    raise SystemExit(1)
PY
    then
        return 1
    fi
    # swallow-ok: an unreadable slot IS the answer - the comparison below fails on it
    readback="$(cat -- "$STATE" 2>/dev/null)"
    [[ -n "$readback" && "$readback" == "$value" ]]
}

case "${1:-status}" in
    sweep)
        _cur="$(_current_primary)"
        if [[ -z "$_cur" ]]; then
            die "cannot read the current primary from $CONFIG — refusing to switch blind"
        fi
        if [[ "$_cur" == "$SWEEP_PRIMARY" ]]; then
            echo "fleet-model: primary is already $SWEEP_PRIMARY — nothing to save"
            exit 0
        fi
        # SAVE BEFORE SWITCHING, and only switch on a slot that was read back.  A switch
        # whose return cannot be reconstructed strands the fleet on the paid lane, which
        # is the defect this ordering exists to prevent.
        if ! _save_primary "$_cur"; then
            die "could not save $_cur to $STATE — refusing to switch; the fleet stays on $_cur"
        fi
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
        _saved="$(cat -- "$STATE")"
        if [[ -z "$_saved" ]]; then
            warn "fleet-model: $STATE holds no previous primary — leaving the fleet on the sweep model"
            warn "fleet-model: recover with: openclaw models set $BASELINE_PRIMARY"
            # 2 = refused, nothing changed (the same status every other refusal returns).
            exit 2
        fi
        if ! _set_primary "$_saved"; then
            die "FAILED to restore $_saved — set it by hand: openclaw models set $_saved"
        fi
        rm -f "$STATE"
        echo "fleet-model: fleet primary restored to $_saved"
        ;;
    status)
        _cur="$(_current_primary)"
        _saved=""
        _slot=0
        # swallow-ok: an absent slot IS the answer here - it prints as "none", i.e. no switch is pending
        if _saved="$(cat -- "$STATE" 2>/dev/null)"; then
            _slot=1
        fi
        echo "primary=$_cur"
        if (( _slot == 1 )); then
            echo "saved=$_saved"
        else
            echo "saved=none"
        fi
        # RED when the fleet is ON the sweep model and the slot holds nothing to restore:
        # the return is unrecoverable from state, so it needs a human and the ruled baseline.
        if [[ "$_cur" == "$SWEEP_PRIMARY" ]] \
            && { (( _slot == 0 )) || [[ -z "$_saved" ]]; }
        then
            warn "fleet-model: RED — the fleet is on the sweep model $SWEEP_PRIMARY"
            warn "fleet-model: $STATE holds no previous primary, so nothing can be restored"
            warn "fleet-model: recover with: openclaw models set $BASELINE_PRIMARY"
            # 1 = the fleet is on the wrong lane with no way back, distinct from a refusal (2)
            # and from usage (64).
            exit 1
        fi
        ;;
    *)
        warn "usage: fleet-model.sh sweep|restore|status"
        # 64 = usage (sysexits EX_USAGE), distinct from a refusal's 2.
        exit 64
        ;;
esac
# end of file
