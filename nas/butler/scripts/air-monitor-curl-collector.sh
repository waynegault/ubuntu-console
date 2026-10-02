#!/bin/sh
SENSOR_URL="http://192.168.33.57/data.json"
INFLUX_URL="http://127.0.0.1:8086/write?db=sensor_data"
LOG="/mnt/HD/HD_a2/butler/logs/air-monitor-nas-cron.log"

# swallow-ok: an unreachable sensor is reported by the "No data from sensor" ERROR line below
DATA=$(/usr/bin/curl -s --max-time 10 "$SENSOR_URL" 2>/dev/null)
if [ -z "$DATA" ]; then
  echo "$(date "+%Y-%m-%d %H:%M:%S") ERROR: No data from sensor" >> "$LOG"
  exit 1
fi

PM10=$(echo "$DATA" | sed "s/.*\"SDS_P1\",\"value\":\"\([^\"]*\)\".*/\1/")
PM25=$(echo "$DATA" | sed "s/.*\"SDS_P2\",\"value\":\"\([^\"]*\)\".*/\1/")
TEMP=$(echo "$DATA" | sed "s/.*\"BME280_temperature\",\"value\":\"\([^\"]*\)\".*/\1/")
HUM=$(echo "$DATA" | sed "s/.*\"BME280_humidity\",\"value\":\"\([^\"]*\)\".*/\1/")
PRESS=$(echo "$DATA" | sed "s/.*\"BME280_pressure\",\"value\":\"\([^\"]*\)\".*/\1/")

LINE="air_quality,source=purpleair,sensor=outdoor pm25=$PM25,pm10=$PM10,temperature=$TEMP,humidity=$HUM,pressure=$PRESS"
# swallow-ok: a failed POST shows as a non-200 code in the log line below (000 when curl cannot connect)
CODE=$(/usr/bin/curl -s -o /dev/null -w "%{http_code}" -X POST "$INFLUX_URL" -d "$LINE" 2>/dev/null)
echo "$(date "+%Y-%m-%d %H:%M:%S") HTTP $CODE pm25=$PM25 pm10=$PM10 temp=$TEMP hum=$HUM" >> "$LOG"
