#!/usr/bin/env bash
# rotate-logs.sh — size-cap the butler logs, keeping ONE previous copy per log.
#
# WHY: nothing rotated these.  bridge.log reached 28 MB while every collector appends to
# butler/logs/ unboundedly.  nas-health-check.sh rotates only its OWN $LOG, so the rest grew
# without limit on a NAS whose disk the collectors share.
#
# ONE .old per log, NOT a date series: a date series is what leaves a prune-one-day-too-late
# state to reason about.  (CORRECTION, 2026-10-02: an earlier version of this comment claimed
# backup-critical-config.sh has no retention — it does, 10 dated copies per target via
# `ls -t … | tail -n +11`; the litter that accumulated under nas-hardening/ was that retained
# history plus one-off manual `.bak-*` files, which nothing prunes.)  One generation is enough
# to inspect a runaway log.
#
# The rotation is COPY + TRUNCATE, never `mv`.  bridge.log is held open by the long-running
# bt-bridge process, so a rename would strand that writer on the renamed inode — it would keep
# writing into the .old file and the fresh log would stay empty.  Truncating in place keeps the
# writer's file descriptor valid (measured 2026-10-02: after a rotation the fresh bridge.log
# grew while .old stayed frozen).
#
# Runs hourly from the OpenClaw collector crontab (which nas-cron-guard.sh reinstalls after WD
# firmware wipes it).  Reports every run, so silence means it did not run.
set -u

LOG_DIR="${BUTLER_LOG_DIR:-/mnt/HD/HD_a2/butler/logs}"
MAX_BYTES="${BUTLER_LOG_MAX_BYTES:-5242880}"
EXTRA_LOG="${BUTLER_EXTRA_LOG:-/mnt/HD/HD_a2/butler/bt-bridge/bridge.log}"

# report one line, with the date, to the rotation's own log
log() { printf '%s %s\n' "$(date -Iseconds)" "$*" >> "$LOG_DIR/rotate-logs.log"; }

mkdir -p "$LOG_DIR"

_rotated=0
for _f in "$LOG_DIR"/*.log "$EXTRA_LOG"; do
    [[ -f "$_f" ]] || continue
    # Never rotate the log this run is writing to.
    [[ "$_f" == "$LOG_DIR/rotate-logs.log" ]] && continue
    _size=$(stat -c%s "$_f") || { log "cannot stat $_f"; continue; }
    if [[ "$_size" -gt "$MAX_BYTES" ]]; then
        cp "$_f" "$_f.old"
        : > "$_f"
        log "rotated $_f ($_size bytes)"
        _rotated=$(( _rotated + 1 ))
    fi
done

log "done rotated=$_rotated cap=$MAX_BYTES"
