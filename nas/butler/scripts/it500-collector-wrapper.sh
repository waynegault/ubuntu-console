#!/bin/sh
# Wrapper for it500-influx-collector — sets only needed vars
mkdir -p /mnt/HD/HD_a2/butler/openclaw-data/thermostat
THERMOSTAT_INFLUX_URL="http://127.0.0.1:8086/write?db=sensor_data" \
/opt/bin/python3 /mnt/HD/HD_a2/butler/scripts/it500-influx-collector.py 2>&1
