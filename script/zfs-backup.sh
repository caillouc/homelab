#!/bin/bash
set -euo pipefail

# ==========================
# CONFIG
# ==========================
SOURCE_POOL="data"
TARGET_HOST="pierre@192.168.1.30"
TARGET_DATASET="magenta-backup/data"
SNAP_PREFIX="backup"
LOGFILE="/tmp/zfs-backup.log"
RETENTION_DAYS=30

DATE="$(date +%F)"
SNAPSHOT="${SOURCE_POOL}@${SNAP_PREFIX}-${DATE}"

START_TIME=$SECONDS

exec >> "$LOGFILE" 2>&1

trap 'cp "$LOGFILE" /data/shared/logs/zfs-backup.log' EXIT

echo "=============================="
echo "$(date) - Backup started"

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

if [ -n "$PREV_SNAPSHOT" ]; then
    echo "Incremental from $PREV_SNAPSHOT to $SNAPSHOT"
    sudo zfs send -R -v -i "$PREV_SNAPSHOT" "$SNAPSHOT" | \
    mbuffer -q -Q -m 1G -s 128k | \
    ssh "$TARGET_HOST" "mbuffer -q -Q -m 1G -s 128k | sudo zfs receive -u $TARGET_DATASET"

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


else
    echo "No previous snapshot, doing full send"
    sudo zfs send -R -v "$SNAPSHOT" | \
    mbuffer -q -Q -m 1G -s 128k | \
    ssh "$TARGET_HOST" "mbuffer -q -Q -m 1G -s 128k | sudo zfs receive -u $TARGET_DATASET"
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
