#!/usr/bin/env bash
# llama-watchdog-guard.sh — supervision-of-the-supervisor. DRAFT for review, not installed.
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

set -euo pipefail

TIMER="llama-watchdog.timer"
LOCK="/home/wayne/investigator/production/runtime/gpu.lock"
PAUSE="/dev/shm/llama-watchdog-guard.pause"
STRIKES="/dev/shm/llama-watchdog-guard.strikes"
ALERT="/home/wayne/.openclaw/life/alerts/supervision-stall.json"
NEED=2

log() { printf '%s [watchdog-guard] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

if [ -e "$PAUSE" ]; then
  exit 0
fi

# 1. Is supervision up?  Anything other than the literal "active" counts.
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
