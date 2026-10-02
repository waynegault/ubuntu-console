#!/usr/bin/env bash
set -u

COLLECTOR="${MI_SCALE_COLLECTOR:-/mnt/HD/HD_a2/butler/mi-scale-2-collector.py}"
PYTHON_BIN="${MI_SCALE_PYTHON_BIN:-$(command -v python3 2>/dev/null || echo /usr/bin/python3)}"
TARGET_MAC="${MI_SCALE_TARGET_MAC:-D8:E7:2F:08:7C:5D}"
RUNTIME="${MI_SCALE_RUNTIME:-auto}"
SLEEP_SECONDS="${MI_SCALE_SLEEP_SECONDS:-15}"
LOG_FILE="${MI_SCALE_LOG_FILE:-/mnt/HD/HD_a2/butler/mi-scale-autocollect.log}"
LOCK_DIR="/tmp/openclaw-mi-scale-autocollect.lock"

mkdir -p "$(dirname "$LOG_FILE")"

acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "$$" > "$LOCK_DIR/pid"
    return 0
  fi

  if [[ -f "$LOCK_DIR/pid" ]]; then
    existing_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
      return 1
    fi
    rm -rf "$LOCK_DIR"
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      echo "$$" > "$LOCK_DIR/pid"
      return 0
    fi
  fi

  return 1
}

release_lock() {
  rm -rf "$LOCK_DIR"
}

log() {
  printf '%s %s\n' "$(date -Iseconds)" "$*" >> "$LOG_FILE"
}

if [[ ! -x "$PYTHON_BIN" ]]; then
  log "python binary not executable: $PYTHON_BIN"
  exit 1
fi

if [[ ! -f "$COLLECTOR" ]]; then
  log "collector script missing: $COLLECTOR"
  exit 1
fi

if [[ "${MI_SCALE_ENABLE_SCAN:-0}" != "1" ]]; then
  log "scan disabled (MI_SCALE_ENABLE_SCAN!=1); exiting safely"
  exit 0
fi

if ! acquire_lock; then
  log "another autocollect instance already running; exiting"
  exit 0
fi

trap release_lock EXIT INT TERM

log "autocollect starting target=$TARGET_MAC runtime=$RUNTIME"

while true; do
  scan_out="$($PYTHON_BIN "$COLLECTOR" --scan --runtime "$RUNTIME" 2>&1)"

  if printf '%s\n' "$scan_out" | grep -qi "$TARGET_MAC"; then
    log "target detected, attempting collection"
    collect_out="$($PYTHON_BIN "$COLLECTOR" --target "$TARGET_MAC" --runtime "$RUNTIME" 2>&1)"
    rc=$?
    if [[ $rc -eq 0 ]]; then
      log "collection success"
    else
      log "collection failed rc=$rc"
      log "$collect_out"
    fi
  fi

  sleep "$SLEEP_SECONDS"
done
