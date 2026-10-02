#!/bin/sh
# Backup critical NAS config to persistent storage
# Run this after any config change
#
# Every step is REPORTED: a file this firmware does not have is named as skipped rather than
# silently absent, and a copy that fails is named too.  The older version carried a redirect
# plus an always-succeed on five of these copies, so a backup that quietly did not happen
# looked exactly like one that did.

BACKUP_DIR=/mnt/HD/HD_a2/butler/nas-hardening
DATE=$(date +%Y%m%d_%H%M%S)
KEEP=10

mkdir -p "$BACKUP_DIR/ssh" "$BACKUP_DIR/samba" "$BACKUP_DIR/init" "$BACKUP_DIR/bt-bridge"

# backup_one <source> <destination> — copy, and name what happened either way
backup_one() {
    if cp "$1" "$2"; then
        echo "backed up: $2"
    else
        echo "SKIPPED (copy failed): $1"
    fi
    return 0
}

backup_one /etc/samba/smb.conf "$BACKUP_DIR/samba/smb.conf.$DATE"
backup_one /etc/samba/smbpasswd "$BACKUP_DIR/samba/smbpasswd.$DATE"
backup_one /home/root/.ssh/authorized_keys "$BACKUP_DIR/ssh/authorized_keys.$DATE"
backup_one /etc/init.d/S91samba "$BACKUP_DIR/init/S91samba.$DATE"
backup_one /etc/init.d/S92nas-health "$BACKUP_DIR/init/S92nas-health.$DATE"
backup_one /mnt/HD/HD_a2/butler/bt-bridge/S35bt-mqtt-bridge "$BACKUP_DIR/bt-bridge/S35bt-mqtt-bridge.$DATE"
backup_one /mnt/HD/HD_a2/butler/bt-bridge/nas-bt-mqtt-bridge.py "$BACKUP_DIR/bt-bridge/nas-bt-mqtt-bridge.py.$DATE"

# Keep only the newest KEEP per directory, over the DATED backups this script writes
# (<name>.YYYYMMDD_HHMMSS).  The stamp is part of the pattern, not a `*.*` wildcard: a plain
# dot-glob would match any name containing a dot and delete a file this script never wrote.
#
# `set --` supplies the match count WITHOUT a redirect — an unmatched glob leaves $# at 1, so
# the prune is skipped and no listing error is produced; a real listing failure then stays
# visible.  The count is tested with `case` rather than a `[ ]` test (§18.3 item 6.7).
for DIR in "$BACKUP_DIR/samba" "$BACKUP_DIR/ssh" "$BACKUP_DIR/init" "$BACKUP_DIR/bt-bridge"; do
    set -- "$DIR"/*.[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9]
    case "$#" in
        1|2|3|4|5|6|7|8|9|10) continue ;;
        *) ;;   # more than KEEP dated backups: fall through to the prune below
    esac
    ls -t "$DIR"/*.[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9] \
        | tail -n +$((KEEP + 1)) | xargs rm -f
done

echo "Backed up to $BACKUP_DIR at $DATE"
