#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="/home/haden/famflix-stack"
PROJECT="famflix"

# ------------------------------------------------------------
# Optional: ensure F: drive (Windows external) is mounted
# ------------------------------------------------------------
mount_f_drive() {
    mkdir -p /mnt/f

    if ! mount | grep -q "/mnt/f type drvfs"; then
        sudo mount -t drvfs F: /mnt/f 2>/dev/null || true
    fi
}

# ------------------------------------------------------------
# Docker Stack Controls
# ------------------------------------------------------------
start_stack() {
    mount_f_drive
    docker compose -f "$STACK_DIR/docker-compose.yml" -p "$PROJECT" up -d
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

stop_stack() {
    docker compose -f "$STACK_DIR/docker-compose.yml" -p "$PROJECT" down
}

restart_stack() {
    stop_stack
    mount_f_drive
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