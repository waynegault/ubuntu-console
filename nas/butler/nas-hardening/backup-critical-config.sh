#!/bin/sh
# Backup critical NAS config to persistent storage
# Run this after any config change

BACKUP_DIR=/mnt/HD/HD_a2/butler/nas-hardening
DATE=$(date +%Y%m%d_%H%M%S)

mkdir -p $BACKUP_DIR/ssh $BACKUP_DIR/samba $BACKUP_DIR/init $BACKUP_DIR/bt-bridge

cp /etc/samba/smb.conf $BACKUP_DIR/samba/smb.conf.$DATE
cp /etc/samba/smbpasswd $BACKUP_DIR/samba/smbpasswd.$DATE
cp /home/root/.ssh/authorized_keys $BACKUP_DIR/ssh/authorized_keys.$DATE 2>/dev/null || true
cp /etc/init.d/S91samba $BACKUP_DIR/init/S91samba.$DATE 2>/dev/null || true
cp /etc/init.d/S92nas-health $BACKUP_DIR/init/S92nas-health.$DATE 2>/dev/null || true
cp /mnt/HD/HD_a2/butler/bt-bridge/S35bt-mqtt-bridge $BACKUP_DIR/bt-bridge/S35bt-mqtt-bridge.$DATE 2>/dev/null || true
cp /mnt/HD/HD_a2/butler/bt-bridge/nas-bt-mqtt-bridge.py $BACKUP_DIR/bt-bridge/nas-bt-mqtt-bridge.py.$DATE 2>/dev/null || true

# Keep only last 10 backups
for DIR in $BACKUP_DIR/samba $BACKUP_DIR/ssh $BACKUP_DIR/init $BACKUP_DIR/bt-bridge; do
    ls -t $DIR/*.* 2>/dev/null | tail -n +11 | xargs rm -f 2>/dev/null || true
done

echo "Backed up to $BACKUP_DIR at $DATE"
