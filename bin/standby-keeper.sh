#!/usr/bin/env bash
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 1
# standby-keeper.sh — keep this box OUT of Windows Modern Standby (S0ix) while a run is in progress.
#   v1 (2026-11-04). INSTALLED and LIVE; reached through this repo's bin/ symlink.
#
# WHY THIS EXISTS. S0ix clamps the dGPU to 663-942 MHz / ~4 W with no error anywhere. Measured
# 2026-11-04: identical binary, model and flags gave 3.3x at c=1 and 2.3x at c=16 depending only on
# the clock state (rows A3 vs A3R, same par16/ctx32768/b4096/ub1024 config). Two wrong explanations
# were written before the clocks were read, because a damped row looks exactly like a bad config.
#   A3  (standby) single 10.85  c=4 25.10  c=16 39.91
#   A3R (awake)   single 39.27  c=4 62.75  c=16 90.02
#
# WHY INJECTED INPUT AND NOT A POWER SETTING. VIDEOIDLE and STANDBYIDLE are BOTH 0 on this machine
# (verified with powercfg /query SCHEME_CURRENT) and the box still entered Modern Standby 3m47s later
# with Reason: Idle Timeout. The display timer is not the governing timer, so the only intervention
# with a measurement behind it is a synthetic input event. The keeper also samples pstate / SM clock /
# power / utilisation every 30 s, so no benchmark row can be quoted without knowing the card was awake.
#
# LIFECYCLE (Wayne, 2026-11-04: "standby-keeper.service should only operate during runs"). This unit
# has NO [Install] section and is deliberately STATIC: `systemctl --user enable` fails, so it cannot
# silently go back to waking the box 24/7. standby-awake.timer starts it when a run is in progress
# and stops it when none is; see bin/standby-awake.sh for the signals.
set -u
export PATH="${PATH:-/usr/local/bin:/usr/bin:/bin}:/home/wayne/.local/bin:/usr/lib/wsl/lib"
LOG=${STANDBY_KEEPER_LOG:-/home/wayne/logs/campaign/clocks.log}
NUDGE=${STANDBY_KEEPER_NUDGE_LOG:-/home/wayne/logs/campaign/nudge.log}
PS=${STANDBY_KEEPER_POWERSHELL:-/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe}
NUDGE_PS=${STANDBY_KEEPER_NUDGE_PS:-C:\\models\\nudge.ps1}
INTERVAL=${STANDBY_KEEPER_INTERVAL:-30}
# Creating the log directory is best-effort by design — on failure the appends below fail loudly in
# the journal, where a keeper that cannot record is worth reading about.
# swallow-ok: a directory that cannot be created must not stop the defender before its first sample.
mkdir -p "$(dirname "$LOG")" "$(dirname "$NUDGE")" 2>/dev/null || true
while true; do
  TS=$(date -u +%FT%TZ)
  # A PowerShell failure must not kill the keeper — the nudge log records the rc on the next line, so
  # the failure is visible there, and the loop's job is to keep trying.
  "$PS" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$NUDGE_PS" >/dev/null 2>&1
  echo "$TS nudge rc=$?" >> "$NUDGE"
  # A failed probe writes an EMPTY sample rather than aborting, so the missing clock shows as a blank
  # column in clocks.log — the absence stays legible instead of killing the defender.
  # swallow-ok: an unreadable GPU state must not kill the process that is keeping the GPU awake.
  S=$(nvidia-smi --query-gpu=clocks.sm,power.draw,utilization.gpu,pstate --format=csv,noheader 2>/dev/null | tr -d " ")
  echo "$TS,$S" >> "$LOG"
  sleep "$INTERVAL"
done

# end of file
