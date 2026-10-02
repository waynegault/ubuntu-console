#!/bin/sh
# Wrapper for air-monitor-influx-collector — sets only needed vars
AIRMON_SENSOR_URL="http://192.168.33.14/data.json" \
AIRMON_INFLUX_URL="http://127.0.0.1:8086/write?db=sensor_data" \
/opt/bin/python3 /mnt/HD/HD_a2/butler/scripts/air-monitor-influx-collector.py --once 2>&1
