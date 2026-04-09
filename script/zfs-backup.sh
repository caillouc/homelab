#!/bin/bash
set -euo pipefail

# ==========================
# CONFIG
# ==========================
SOURCE_POOL="data"
TARGET_IP="raspberrypi.tail.net"
TARGET_DATASET="magenta-backup/data"
SNAP_PREFIX="backup"
LOGFILE="/var/log/zfs-backup/zfs-backup.log"
RETENTION_DAYS=30
KNOWN_HOSTS="/etc/ssh/ssh_known_hosts"
MBUFFER_PORT=9090                   # TCP port for mbuffer over VPN
MBUFFER_MEM="1G"
MBUFFER_BLOCK="128k"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS")
UPTIME_KUMA_PUSH_URL="https://monitor.clsn.fr/api/push/TU1VvNIH14xOdHMIEEp53oEjCOsPPk8t"

DATE="$(date +%F)"
SNAPSHOT="${SOURCE_POOL}@${SNAP_PREFIX}-${DATE}"

START_TIME=$SECONDS

exec >> "$LOGFILE" 2>&1

notify_uptime_kuma() {
    local status="$1"
    local message="$2"
    local elapsed_time="$3"

    if [ -z "$UPTIME_KUMA_PUSH_URL" ]; then
        return 0
    fi

    set +e
    curl -fsS --max-time 10 --retry 2 --retry-delay 2 --get \
        --data-urlencode "status=$status" \
        --data-urlencode "msg=$message" \
        --data-urlencode "ping=$elapsed_time" \
        "$UPTIME_KUMA_PUSH_URL" >/dev/null
    if [ $? -ne 0 ]; then
        echo "WARNING: Failed to notify Uptime Kuma"
    fi
    set -e
}

on_exit() {
    local exit_code=$?
    local elapsed_time=$(( SECONDS - START_TIME ))

    cp "$LOGFILE" /data/shared/logs/zfs-backup.log

    if [ $exit_code -eq 0 ]; then
        notify_uptime_kuma "up" "Backup succeeded" "$elapsed_time"
    else
        notify_uptime_kuma "down" "Backup failed (code $exit_code)" "$elapsed_time"
    fi

    exit $exit_code
}

trap on_exit EXIT

echo "=============================="
echo "$(date) - Backup started"

# ==========================
# VERIFY TARGET HOST REACHABILITY
# ==========================
echo "Verifying target host connectivity via SSH..."

if ! ssh "${SSH_OPTS[@]}" "$TARGET_IP" 'echo 2>&1' >/dev/null; then
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

cleanup_remote_snapshot() {
    local remote_snapshot="${TARGET_DATASET}@${SNAP_PREFIX}-${DATE}"

    echo "Attempting remote cleanup of $remote_snapshot"

    if ssh "${SSH_OPTS[@]}" "$TARGET_IP" "sudo zfs list -t snapshot '$remote_snapshot' >/dev/null 2>&1"; then
        if ssh "${SSH_OPTS[@]}" "$TARGET_IP" "sudo zfs destroy -r '$remote_snapshot'"; then
            echo "Remote snapshot cleanup successful: $remote_snapshot"
        else
            echo "WARNING: Failed to destroy remote snapshot: $remote_snapshot"
        fi
    else
        echo "No remote snapshot to clean up: $remote_snapshot"
    fi
}

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
    echo "ERROR: Snapshot send failed. Cleaning up local and remote snapshots."
    cleanup_remote_snapshot
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
