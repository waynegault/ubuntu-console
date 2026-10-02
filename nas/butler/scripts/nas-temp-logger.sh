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

# smart_field <device> <attribute> — one SMART value, or empty when smartctl cannot answer.
# The empty field in the log line below IS this probe's report, so its stderr is suppressed
# here and nowhere else; the four call sites no longer carry a redirect of their own.
smart_field() {
    # swallow-ok: an unanswered probe shows as an empty field in the log line
    smartctl -A "$1" 2>/dev/null | grep "$2" | awk '{print $10}'
}

if command -v smartctl >/dev/null 2>&1; then
    SDA_TEMP=$(smart_field /dev/sda Temperature_Celsius)
    SDB_TEMP=$(smart_field /dev/sdb Temperature_Celsius)
    SDA_POH=$(smart_field /dev/sda Power_On_Hours)
    SDB_POH=$(smart_field /dev/sdb Power_On_Hours)
fi

# Uptime in hours (awk reads the file directly — no redirect, so nothing is swallowed)
UPTIME=$(awk '{print int($1/3600)}' /proc/uptime)

# Load average
LOAD=$(awk '{print $1" "$2" "$3}' /proc/loadavg)

# Ping check — ping's own stderr is deliberately left VISIBLE: it names why the gateway is
# unreachable, which is the whole point of the check
PING_RESULT=$(ping -c 1 -W 2 192.168.33.1 | grep -q "1 packets received" && echo "OK" || echo "FAIL")

echo "$TIMESTAMP | CPU:${CPU_TEMP}C | sda:${SDA_TEMP}C(poh:${SDA_POH}) | sdb:${SDB_TEMP}C(poh:${SDB_POH}) | uptime:${UPTIME}h | load:${LOAD} | gw:${PING_RESULT}" >> "$LOG_FILE"
# Keep log manageable - last 2000 lines
tail -2000 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
