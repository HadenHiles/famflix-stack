#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Load Secrets
# ------------------------------------------------------------
if [ -f "/home/haden/famflix-stack/famflix-secrets.sh" ]; then
    # shellcheck source=/dev/null
    source "/home/haden/famflix-stack/famflix-secrets.sh"
else
    echo "ERROR: famflix-secrets.sh not found!"
    exit 1
fi

# ------------------------------------------------------------
# Helper: Safe mount wrapper
# ------------------------------------------------------------
safe_mount() {
    local source="$1"
    local target="$2"
    local options="$3"

    mkdir -p "$target"

    # Already mounted?
    if mount | grep -q " $target "; then
        return
    fi

    sudo mount $options "$source" "$target" 2>/dev/null || true
}

# ------------------------------------------------------------
# Mount NAS (NFS) for media + downloads → /mnt/nas
# ------------------------------------------------------------
mount_nas_nfs() {
    safe_mount \
        "${NAS_SERVER}:${NAS_SHARE}" \
        "${MOUNT_NAS}" \
        "-t nfs -o nfsvers=4"
}

# ------------------------------------------------------------
# Mount NAS USB SSD (SMB from UGREEN) → /mnt/nas-usb
# ------------------------------------------------------------
mount_usb_drive() {
    # NOTE: UGREEN auto-share name may include spaces ("no name")
    local usb_share="//${NAS_SERVER}/no name"

    safe_mount \
        "$usb_share" \
        "${MOUNT_NAS_USB}" \
        "-t cifs -o username=${NAS_USB_USER},password=${NAS_USB_PASS},vers=3.0,dir_mode=0777,file_mode=0777"
}

# ------------------------------------------------------------
# Docker Stack Controls
# ------------------------------------------------------------
start_stack() {
    mount_nas_nfs
    mount_usb_drive

    docker compose -f "$STACK_PATH/docker-compose.yml" -p "$PROJECT_NAME" up -d
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

stop_stack() {
    docker compose -f "$STACK_PATH/docker-compose.yml" -p "$PROJECT_NAME" down
}

restart_stack() {
    stop_stack
    mount_nas_nfs
    mount_usb_drive
    start_stack
}

status_stack() {
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

# ------------------------------------------------------------
# Command Dispatcher
# ------------------------------------------------------------
case "${1:-}" in
    start)      start_stack ;;
    stop)       stop_stack ;;
    restart)    restart_stack ;;
    status)     status_stack ;;
    *)
        echo "Usage: $0 {start|stop|restart|status}"
        exit 1
        ;;
esac