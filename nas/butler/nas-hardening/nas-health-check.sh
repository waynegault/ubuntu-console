#!/bin/sh
# NAS health check and auto-repair
# Run from cron every 5 minutes

LOG=/mnt/HD/HD_a2/butler/nas-hardening/health-check.log
REPAIR_LOG=/mnt/HD/HD_a2/butler/nas-hardening/repair.log
BACKUP_DIR=/mnt/HD/HD_a2/butler/nas-hardening
DATE=$(date '+%Y-%m-%d %H:%M:%S')

log() {
    echo "$DATE $1" >> $LOG
}

repair() {
    echo "$DATE REPAIR: $1" >> $REPAIR_LOG
    echo "$DATE REPAIR: $1" >> $LOG
}

# Check Samba running
if ! pgrep -x smbd >/dev/null 2>&1; then
    repair "smbd not running, restarting"
    mkdir -p /var/log/samba/cores /var/cache/samba /var/run/samba /var/lock/subsys
    chmod 700 /var/log/samba/cores
    /usr/bin/smbd -D
    /usr/bin/nmbd -D
fi

# Check SSH authorized_keys
if [ ! -s /home/root/.ssh/authorized_keys ]; then
    repair "SSH authorized_keys missing, restoring from backup"
    # swallow-ok: an absent backup is a real state; the caller tests its result and skips the restore
    LATEST=$(ls -t $BACKUP_DIR/ssh/authorized_keys.* 2>/dev/null | head -1)
    if [ -n "$LATEST" ]; then
        mkdir -p /home/root/.ssh /root/.ssh
        chmod 700 /home/root/.ssh /root/.ssh
        cp "$LATEST" /home/root/.ssh/authorized_keys
        chmod 600 /home/root/.ssh/authorized_keys
        # a redundant SECOND copy of the same keys, into /root/.ssh, which this firmware may
        # not have; the restore that matters is the unchecked copy just above
        # swallow-ok: best-effort second copy; the primary restore is unchecked but visible
        cp /home/root/.ssh/authorized_keys /root/.ssh/authorized_keys 2>/dev/null || true
    fi
fi

# Check Samba config
if [ ! -f /etc/samba/smb.conf ]; then
    repair "smb.conf missing, restoring from backup"
    # swallow-ok: an absent backup is a real state; the caller tests its result and skips the restore
    LATEST=$(ls -t $BACKUP_DIR/samba/smb.conf.* 2>/dev/null | head -1)
    if [ -n "$LATEST" ]; then
        cp "$LATEST" /etc/samba/smb.conf
    fi
fi

# Check init script
if [ ! -f /etc/init.d/S91samba ]; then
    repair "S91samba init script missing, restoring from backup"
    # swallow-ok: an absent backup is a real state; the caller tests its result and skips the restore
    LATEST=$(ls -t $BACKUP_DIR/init/S91samba.* 2>/dev/null | head -1)
    if [ -n "$LATEST" ]; then
        cp "$LATEST" /etc/init.d/S91samba
        chmod +x /etc/init.d/S91samba
    fi
fi

# Check BT-MQTT bridge running
if [ -f /mnt/HD/HD_a2/butler/bt-bridge/S35bt-mqtt-bridge ]; then
    if ! /mnt/HD/HD_a2/butler/bt-bridge/S35bt-mqtt-bridge status >/dev/null 2>&1; then
        repair "BT-MQTT bridge not running, restarting"
        /mnt/HD/HD_a2/butler/bt-bridge/S35bt-mqtt-bridge start >/dev/null 2>&1
    fi
fi

# Check mosquitto running
if ! pgrep -x mosquitto >/dev/null 2>&1; then
    repair "mosquitto not running, attempting restart"
    if ! /opt/etc/init.d/S80mosquitto start >/dev/null 2>&1
    then
        log "REPAIR FAILED: mosquitto did not restart - MQTT ingestion is down"
    fi
fi

# Check air monitor collector in crontab
# swallow-ok: a non-match is the SIGNAL here: the repair above re-adds the crontab line
if ! grep -q 'air-monitor-influx-collector' /etc/crontab 2>/dev/null; then
    repair "Air monitor collector missing from crontab, re-adding"
    echo '*/2 * * * * /opt/bin/python3 /mnt/HD/HD_a2/butler/scripts/air-monitor-influx-collector.py >> /mnt/HD/HD_a2/butler/logs/air-monitor-collector.log 2>&1' >> /etc/crontab
    # swallow-ok: killall is best-effort; crond is started unconditionally on the next line
    killall crond 2>/dev/null
    crond
fi

# Check CPAP collector in crontab
# swallow-ok: a non-match is the SIGNAL here: the repair above re-adds the crontab line
if ! grep -q 'cpap-collect' /etc/crontab 2>/dev/null; then
    repair "CPAP collector missing from crontab, re-adding"
    echo '0 8 * * * /mnt/HD/HD_a2/butler/scripts/cpap-collect-with-otp.sh >> /mnt/HD/HD_a2/butler/logs/cpap-collect.log 2>&1' >> /etc/crontab
    # swallow-ok: killall is best-effort; crond is started unconditionally on the next line
    killall crond 2>/dev/null
    crond
fi

# Check OTP file freshness
OTP_FILE=/mnt/HD/HD_a2/butler/cron/myair-email-otp.txt
if [ -f $OTP_FILE ]; then
    now=$(date +%s)
    # swallow-ok: a stat failure yields 0, which the staleness warning below reports
    otp_epoch=$(stat -c %Y $OTP_FILE 2>/dev/null || echo 0)
    if [ $((now - otp_epoch)) -gt 900 ]; then
        log "WARNING: myAir OTP file is stale (>15 min)"
    fi
else
    log "WARNING: myAir OTP file missing"
fi

# Check Microsoft password file exists
if [ ! -f /mnt/HD/HD_a2/butler/cron/microsoft-env.sh ]; then
    log "WARNING: Microsoft password file missing - CPAP IMAP will fail"
fi

# Rotate logs if too big
# swallow-ok: a stat failure yields 0; rotate-logs.sh now caps this log hourly
if [ -f "$LOG" ] && [ "$(stat -c%s "$LOG" 2>/dev/null || echo 0)" -gt 1048576 ]; then
    mv "$LOG" "$LOG.old"
fi

# Check admin password hash
# swallow-ok: the match drives the repair, which is reported to the repair log
if grep -q "^admin::\|\$HASH" /etc/shadow 2>/dev/null; then
    repair "admin password hash missing or corrupt, restoring from backup"
    if ! cp /mnt/HD/HD_a2/butler/nas-hardening/shadow.admin_backup /etc/shadow
    then
        log "REPAIR FAILED: could not restore /etc/shadow from backup - admin login may still be broken"
    fi
fi
