#!/bin/sh
# CPAP collection wrapper for NAS
# Extracts OTP via Graph API and immediately runs collection

OTP_FILE=/mnt/HD/HD_a2/butler/cron/myair-email-otp.txt
FETCH_SCRIPT=/mnt/HD/HD_a2/butler/scripts/cpap-myair-fetch.py
COLLECT_SCRIPT=/mnt/HD/HD_a2/butler/scripts/cpap-myair-collector.py
OTP_SCRIPT=/mnt/HD/HD_a2/butler/scripts/nas-graph-otp.py
LOG=/mnt/HD/HD_a2/butler/logs/cpap-collect.log

# Export myAir credentials
export CPAP_MYAIR_USERNAME="REDACTED-CREDENTIAL"
export CPAP_MYAIR_PASSWORD="REDACTED-CREDENTIAL"
export CPAP_REGION="EU"

# Fetch fresh OTP via Graph API (extracts and deletes email in one shot)
otp=$(/opt/bin/python3 $OTP_SCRIPT 2>>$LOG)
if [ -n "$otp" ]; then
    echo "$otp" > $OTP_FILE
    chmod 600 $OTP_FILE
    echo "$(date +%Y-%m-%d\ %H:%M:%S) OTP fetched via Graph API: $otp" >> $LOG
else
    echo "$(date +%Y-%m-%d\ %H:%M:%S) Graph API OTP fetch failed, using stale OTP if available" >> $LOG
fi

# Run collection immediately with OTP
export CPAP_MYAIR_EMAIL_OTP_COMMAND="/mnt/HD/HD_a2/butler/scripts/read-myair-otp.sh"
/opt/bin/python3 $FETCH_SCRIPT 2>>$LOG > /tmp/cpap-payload.json
# swallow-ok: the file is tested with -s first, so grep has nothing to report on stderr
if [ -s /tmp/cpap-payload.json ] && grep -q "device" /tmp/cpap-payload.json 2>/dev/null; then
    /opt/bin/python3 $COLLECT_SCRIPT collect-once --adapter file --input-file /tmp/cpap-payload.json 2>>$LOG
    echo "$(date +%Y-%m-%d\ %H:%M:%S) CPAP collection completed" >> $LOG
else
    echo "$(date +%Y-%m-%d\ %H:%M:%S) CPAP fetch failed or empty payload: $(cat /tmp/cpap-payload.json | head -1)" >> $LOG
fi
