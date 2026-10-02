#!/bin/sh
INFLUX_URL="http://127.0.0.1:8086/write?db=health_metrics"
LOG="/mnt/HD/HD_a2/butler/logs/internet-quality-cron.log"

now() {
  date "+%Y-%m-%d %H:%M:%S"
}

monitor() {
  TARGET=$1
  LABEL=$2

  RESULT=$(/bin/ping -c 5 -W 2 -q "$TARGET" 2>&1)

  LOSS=$(echo "$RESULT" | sed -n "s/.* \([0-9]*\)% packet loss.*/\1/p")
  RTT=$(echo "$RESULT" | sed -n "s/.*round-trip.*= \(.*\)/\1/p")

  if [ -n "$RTT" ]; then
    AVG=$(echo "$RTT" | cut -d/ -f2)
    # Remove ms suffix for InfluxDB (must be float)
    AVGF=$(echo "$AVG" | sed "s/ ms//")
    LINE="internet_quality,target=$LABEL latency_ms=$AVGF,packet_loss=$LOSS"
    # swallow-ok: a failed POST shows as a non-200 code in the log line below (000 = no connect)
    CODE=$(/usr/bin/curl -s -o /dev/null -w "%{http_code}" -X POST "$INFLUX_URL" -d "$LINE" 2>/dev/null)
    echo "$(now) $LABEL HTTP $CODE avg=${AVG} loss=${LOSS}%" >> "$LOG"
  else
    LINE="internet_quality,target=$LABEL latency_ms=0,packet_loss=100"
    # the DOWN branch used to POST with no code captured, so a failed fallback write was
    # invisible; capture and log it exactly as the branch above does
    # swallow-ok: a failed POST shows as the non-200 code now logged on the DOWN line
    CODE=$(/usr/bin/curl -s -o /dev/null -w "%{http_code}" -X POST "$INFLUX_URL" -d "$LINE" 2>/dev/null)
    echo "$(now) $LABEL DOWN HTTP $CODE" >> "$LOG"
  fi
}

monitor 1.1.1.1 cloudflare
monitor 8.8.8.8 google
monitor 192.168.33.1 lan-gateway
