#!/bin/sh
# NAS Temperature & Health Logger
# Logs CPU temp, disk temps, and uptime every 30 minutes
# Used to diagnose intermittent crash patterns

LOG_FILE="/mnt/HD/HD_a2/butler/scripts/nas-temperature.log"
TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")

# CPU temp from thermal zone (millidegrees Celsius)
CPU_TEMP=""
if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
    CPU_TEMP_RAW=$(cat /sys/class/thermal/thermal_zone0/temp)
    CPU_TEMP=$((CPU_TEMP_RAW / 1000))
fi

# Disk temps from smartctl
SDA_TEMP=""
SDB_TEMP=""
SDA_POH=""
SDB_POH=""

if command -v smartctl >/dev/null 2>&1; then
    SDA_TEMP=$(smartctl -A /dev/sda 2>/dev/null | grep "Temperature_Celsius" | awk "{print \$10}")
    SDB_TEMP=$(smartctl -A /dev/sdb 2>/dev/null | grep "Temperature_Celsius" | awk "{print \$10}")
    SDA_POH=$(smartctl -A /dev/sda 2>/dev/null | grep "Power_On_Hours" | awk "{print \$10}")
    SDB_POH=$(smartctl -A /dev/sdb 2>/dev/null | grep "Power_On_Hours" | awk "{print \$10}")
fi

# Uptime in hours (using awk math)
UPTIME=$(cat /proc/uptime 2>/dev/null | awk "{print int(\$1/3600)}")

# Load average
LOAD=$(cat /proc/loadavg 2>/dev/null | awk "{print \$1\" \"\$2\" \"\$3}")

# Ping check
PING_RESULT=$(ping -c 1 -W 2 192.168.33.1 2>/dev/null | grep "1 packets received" >/dev/null 2>&1 && echo "OK" || echo "FAIL")

echo "$TIMESTAMP | CPU:${CPU_TEMP}C | sda:${SDA_TEMP}C(poh:${SDA_POH}) | sdb:${SDB_TEMP}C(poh:${SDB_POH}) | uptime:${UPTIME}h | load:${LOAD} | gw:${PING_RESULT}" >> "$LOG_FILE"
# Keep log manageable - last 2000 lines
tail -2000 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
