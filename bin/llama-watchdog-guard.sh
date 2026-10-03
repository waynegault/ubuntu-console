#!/usr/bin/env bash
# llama-watchdog-guard.sh — supervision-of-the-supervisor. INSTALLED and LIVE.
#
# STATUS (installed 2026-09-21 09:13 BST): run every ~5 min by systemd —
#   systemd/llama-watchdog-guard.service (ExecStart=%h/.local/bin/llama-watchdog-guard.sh,
#   reached through this repo's bin/ symlink) on systemd/llama-watchdog-guard.timer
#   (OnBootSec=3min, OnUnitActiveSec=5min).  Opt out with
#   `touch /dev/shm/llama-watchdog-guard.pause` (see OPT-OUT below); install layout:
#   systemd/llama-watchdog-guard.README.md.  A stale "DRAFT for review, not installed"
#   banner stood here until 2026-10-02 (card 3289360a).
#
# WHY (evidence, 2026-09-20):
#   The model-selection bench (investigator/scripts/bench_shared/msb, via
#   pipeline/gpu/_exclusive.py:GpuExclusivityClaim) stops llama-watchdog.timer
#   plus the CUDA lanes while it owns the GPU flock, and restores them in
#   release() — on normal exit AND on SIGINT/SIGTERM (handlers installed
#   2026-09-17 for exactly this), with a 15 s defender thread.
#
#   Not covered: a hard kill — SIGKILL, OOM, `wsl --shutdown`, crash — skips
#   release() entirely.  The kernel drops the flock with the process, so
#   afterwards the box is left with: timer stopped, no claim held, and NO alert.
#   Observed unsupervised windows: 2026-09-19 ~4 h (10:49-14:48) and ~7.5 h
#   (14:50-22:17).
#
#   More restore code cannot catch an uncatchable signal.  The missing layer is
#   a detector, which is this script.
#
# WHAT: every 5 min — if the watchdog timer is NOT active AND no process holds
#   the GPU flock, count a strike; at 2 consecutive strikes re-arm the timer and
#   append a supervision_stall alert.  A held flock means the stop was the
#   bench's, so the guard stands down: it cannot fight the bench.
#
# OPT-OUT: `touch /dev/shm/llama-watchdog-guard.pause` suspends the guard for a
#   deliberate, non-bench stop.  `rm` the file to resume.
#
# AI INSTRUCTION: Increment version on significant changes.
# Module Version: 4

set -euo pipefail

# log lives in the shared bin library (one definition, every bin/ caller).
# Sourced by realpath so the ~/.local/bin symlink and the repo path both resolve.
TAC_LOG_TAG="watchdog-guard"
export TAC_LOG_TAG
# shellcheck source=_tac-bin-lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/_tac-bin-lib.sh"

TIMER="llama-watchdog.timer"
# The investigator GPU lock path comes from the shared helper (same precedence
# as the module side); this was a hardcoded literal that ignored
# INVESTIGATOR_GPU_LOCK, a drift waiting to happen.
LOCK="$(_inv_gpu_lock_path)"
PAUSE="/dev/shm/llama-watchdog-guard.pause"
STRIKES="/dev/shm/llama-watchdog-guard.strikes"
ALERT="/home/wayne/.openclaw/life/alerts/supervision-stall.json"
NEED=2

if [ -e "$PAUSE" ]; then
  exit 0
fi

# 1. Is supervision up?  Anything other than the literal "active" counts.
# A failed is-active is treated as "not active", which is the fail-safe direction:
# a supervisor we cannot read is a supervisor we must not assume is running.
# swallow-ok: the read IS the answer, and its failure falls to the safe branch
if [ "$(systemctl --user is-active "$TIMER" 2>/dev/null || true)" = "active" ]; then
  if [ -e "$STRIKES" ]; then
    rm -f "$STRIKES"
    log "supervision restored — strike counter cleared"
  fi
  exit 0
fi

# 2. Is the GPU under a live bench claim?  A held flock means yes.
held=false
if [ -e "$LOCK" ]; then
  # swallow-ok: the probe's exit status is exactly the question being asked
  if flock -n "$LOCK" -c true 2>/dev/null; then
    held=false
  else
    held=true
  fi
fi
if [ "$held" = true ]; then
  log "$TIMER inactive but a bench holds $(basename "$LOCK") — deliberate stop, standing down"
  exit 0
fi

# 3. Two consecutive ticks before acting, so a one-cycle blip is not a flap.
# An unreadable counter reads as 0 — which re-arms the guard rather than silencing
# it, and for a supervisor that is the safe direction.
# swallow-ok: the default (0) is the fail-safe value, not a hidden failure
n=$(( $(cat "$STRIKES" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "$n" > "$STRIKES"
if [ "$n" -lt "$NEED" ]; then
  log "$TIMER inactive with no GPU claim (strike ${n}/${NEED})"
  exit 0
fi

# 4. Re-arm, then record it where a human will see it.
log "$TIMER inactive for ${n} ticks with NO GPU claim — re-arming"
if ! systemctl --user start "$TIMER"; then
  log "re-arm FAILED — needs a hand: systemctl --user start $TIMER"
fi

ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
mkdir -p "$(dirname "$ALERT")"
python3 - "$ALERT" "$ts" "$n" <<'PY'
import json, os, sys
path, ts, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
rows = []
if os.path.exists(path):
    try:
        rows = json.load(open(path))
    except Exception:
        rows = []
rows.append({
    "kind": "supervision_stall",
    "detected_utc": ts,
    "consecutive_ticks": n,
    "unit": "llama-watchdog.timer",
    "gpu_claim_held": False,
    "action": "re-armed",
    "detail": ("llama-watchdog.timer was inactive with no GPU-exclusivity claim held; "
               "a hard kill (SIGKILL/OOM/shutdown) skips GpuExclusivityClaim.release()."),
})
with open(path, "w") as fh:
    json.dump(rows, fh, indent=2)
PY
rm -f "$STRIKES"
exit 0

# end of file
