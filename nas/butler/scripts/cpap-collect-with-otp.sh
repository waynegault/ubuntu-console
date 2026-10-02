#!/bin/sh
# CPAP collection wrapper for NAS
# Extracts OTP via Graph API and immediately runs collection

OTP_FILE=/mnt/HD/HD_a2/butler/cron/myair-email-otp.txt
FETCH_SCRIPT=/mnt/HD/HD_a2/butler/scripts/cpap-myair-fetch.py
COLLECT_SCRIPT=/mnt/HD/HD_a2/butler/scripts/cpap-myair-collector.py
OTP_SCRIPT=/mnt/HD/HD_a2/butler/scripts/nas-graph-otp.py
LOG=/mnt/HD/HD_a2/butler/logs/cpap-collect.log

# myAir credentials come from the gitignored NAS env files -- never hardcoded here.
# Self-sourced so the 08:00 cron entry needs no env wiring of its own.
for _envf in \
    /mnt/HD/HD_a2/butler/cron/openclaw-collectors.env \
    /mnt/HD/HD_a2/butler/cron/cpap-collector.env
do
    # shellcheck disable=SC1090  # runtime path, deliberately not followed statically
    . "$_envf" 2>/dev/null || :  # swallow-ok: missing env file is non-fatal; guard fails closed
done
unset _envf
# RESMED_PASSWORD (bridged export) is the canonical myAir password name.
: "${CPAP_MYAIR_PASSWORD:=${RESMED_PASSWORD:-}}"
: "${CPAP_MYAIR_USERNAME:?CPAP_MYAIR_USERNAME is not set - source cron/cpap-collector.env}"
: "${CPAP_MYAIR_PASSWORD:?CPAP_MYAIR_PASSWORD is not set - source cron/cpap-collector.env}"
export CPAP_MYAIR_USERNAME CPAP_MYAIR_PASSWORD
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
