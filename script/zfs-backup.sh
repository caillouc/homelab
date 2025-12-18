#!/bin/bash
set -euo pipefail

# ==========================
# CONFIG
# ==========================
SOURCE_POOL="data"
TARGET_IP="10.8.0.30"
TARGET_DATASET="magenta-backup/data"
SNAP_PREFIX="backup"
LOGFILE="/tmp/zfs-backup.log"
RETENTION_DAYS=30
MBUFFER_PORT=9090                   # TCP port for mbuffer over VPN
MBUFFER_MEM="1G"
MBUFFER_BLOCK="128k"

DATE="$(date +%F)"
SNAPSHOT="${SOURCE_POOL}@${SNAP_PREFIX}-${DATE}"

START_TIME=$SECONDS

exec >> "$LOGFILE" 2>&1

trap 'cp "$LOGFILE" /data/shared/logs/zfs-backup.log' EXIT

echo "Target host reachable. Proceeding with mbuffer transfer..."

echo "=============================="
echo "$(date) - Backup started"

# ==========================
# VERIFY TARGET HOST REACHABILITY
# ==========================
echo "Verifying target host connectivity via SSH..."

if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$TARGET_IP" 'echo 2>&1' >/dev/null; then
    echo "ERROR: Cannot connect to $TARGET_IP via SSH. Aborting transfer."
    exit 1
fi

# ==========================
# CREATE SNAPSHOT
# ==========================
if zfs list -t snapshot "$SNAPSHOT" >/dev/null 2>&1; then
    echo "Snapshot already exists: $SNAPSHOT"
else
    echo "Creating snapshot: $SNAPSHOT"
    sudo zfs snapshot -r "$SNAPSHOT"
fi

# ==========================
# FIND PREVIOUS SNAPSHOT
# ==========================
PREV_SNAPSHOT=$(zfs list -t snapshot -o name -s creation | \
    grep "^${SOURCE_POOL}@${SNAP_PREFIX}-" | \
    tail -2 | head -1 || true)

# ==========================
# SEND SNAPSHOT
# ==========================
echo "Sending snapshot..."

send_snapshot() {
    if [ -n "$PREV_SNAPSHOT" ]; then
        echo "Incremental from $PREV_SNAPSHOT to $SNAPSHOT"

        # Safe since connection done thanks to the vpn
        sudo zfs send -R -v -i "$PREV_SNAPSHOT" "$SNAPSHOT" | \
        mbuffer -q -Q -m "$MBUFFER_MEM" -s "$MBUFFER_BLOCK" -O "$TARGET_IP:$MBUFFER_PORT"
    else
        echo "No previous snapshot, doing full send"
        sudo zfs send -R -v "$SNAPSHOT" | \
        mbuffer -q -Q -m "$MBUFFER_MEM" -s "$MBUFFER_BLOCK" -O "$TARGET_IP:$MBUFFER_PORT"
    fi
}

if send_snapshot; then
    echo "Snapshot $SNAPSHOT successfully sent."
else
    echo "ERROR: Snapshot send failed. Destroying incomplete snapshot."
    sudo zfs destroy -r "$SNAPSHOT"
    exit 1
fi

if [ -n "$PREV_SNAPSHOT" ]; then
    echo "Files changed:"

    # Loop over all datasets recursively
    zfs list -H -o name -r "$SOURCE_POOL" | while read -r dataset; do
        # Find previous snapshot
        PREV_SNAPSHOT=$(zfs list -t snapshot -o name -s creation "$dataset" 2>/dev/null | \
            grep "^${dataset}@${SNAP_PREFIX}-" | tail -2 | head -1 || true)

        # Current snapshot
        CUR_SNAPSHOT="${dataset}@${SNAP_PREFIX}-${DATE}"

        # Only run diff if previous snapshot exists
        if [ -n "$PREV_SNAPSHOT" ]; then
            echo "Diff for $dataset ($PREV_SNAPSHOT -> $CUR_SNAPSHOT):"
            sudo zfs diff -FH "$PREV_SNAPSHOT" "$CUR_SNAPSHOT"
        fi
    done
fi


echo "Snapshot sent successfully"

# ==========================
# SNAPSHOT RETENTION
# ==========================
echo "Applying retention policy (keep $RETENTION_DAYS days)"

zfs list -t snapshot -o name -s creation | \
grep "^${SOURCE_POOL}@${SNAP_PREFIX}-" | \
head -n "-$RETENTION_DAYS" | \
while read -r oldsnap; do
    echo "Destroying old snapshot: $oldsnap"
    sudo zfs destroy -r "$oldsnap"
done

ELAPSED_TIME=$(( SECONDS - START_TIME ))

echo "$(date) - Backup completed successfully in $ELAPSED_TIME seconds"

cp $LOGFILE /data/shared/logs/zfs-backup.log
