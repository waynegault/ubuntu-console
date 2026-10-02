#!/bin/sh
# OpenClaw NAS IoT startup snippet (source this from fun_plug)

export PATH="/opt/bin:/opt/sbin:$PATH"

# Start Mosquitto if available and not running.
if command -v mosquitto >/dev/null 2>&1; then
  pgrep -f mosquitto >/dev/null 2>&1 || nohup mosquitto -d >/dev/null 2>&1
fi

# Start Telegraf if available and config exists.
if command -v telegraf >/dev/null 2>&1; then
  if [ -f /opt/etc/telegraf.conf ]; then
    pgrep -f telegraf >/dev/null 2>&1 || nohup telegraf --config /opt/etc/telegraf.conf >/dev/null 2>&1
  fi
fi
