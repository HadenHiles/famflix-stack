#!/usr/bin/env bash
# ------------------------------------------------------------
# FamFlix WSL Controller (secure edition)
# ------------------------------------------------------------
# Usage: ./famflix.sh start|stop|restart|status
# ------------------------------------------------------------

set -euo pipefail

# --- Load secrets ---
SECRET_FILE="$(dirname "$0")/famflix-secrets.sh"
if [[ -f "$SECRET_FILE" ]]; then
  source "$SECRET_FILE"
else
  echo "[ERROR] Missing secrets file: $SECRET_FILE"
  exit 1
fi

# --- COLORS ---
RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[1;33m"; CYAN="\033[0;36m"; NC="\033[0m"

log()   { echo -e "${2:-$NC}$1${NC}"; }
error() { log "[ERROR] $1" "$RED"; exit 1; }
warn()  { log "[WARN] $1" "$YELLOW"; }
info()  { log "[INFO] $1" "$CYAN"; }
ok()    { log "[OK] $1" "$GREEN"; }

# --- Docker Check ---
check_docker() {
  info "Checking Docker Engine..."
  if ! docker info >/dev/null 2>&1; then
    error "Docker Engine not running in WSL."
  fi
  ok "Docker Engine is available."
}

# --- Retry Mount Helper ---
attempt_mount() {
  local label="$1"; shift
  local mount_cmd="$1"; shift
  local verify_path="$1"
  
  for ((i=1; i<=MAX_ATTEMPTS; i++)); do
    info "Attempting to mount $label (try $i/$MAX_ATTEMPTS)..."
    eval "$mount_cmd" >/dev/null 2>&1 || true
    sleep 1
    if mountpoint -q "$verify_path"; then
      ok "$label mounted successfully at $verify_path"
      return 0
    fi
    warn "$label mount failed, retrying in $RETRY_DELAY seconds..."
    sleep "$RETRY_DELAY"
  done
  error "Failed to mount $label after $MAX_ATTEMPTS attempts."
}

# --- Mounts ---
mount_volumes() {
  info "Mounting NAS + External drives..."
  check_docker

  # NAS
  sudo mkdir -p "$MOUNT_NAS"
  attempt_mount "NAS" \
    "sudo mount -t cifs //$NAS_SERVER/famflix $MOUNT_NAS -o username=$NAS_USER,password=$NAS_PASS,uid=0,gid=0,file_mode=0777,dir_mode=0777,vers=3.0" \
    "$MOUNT_NAS"

  # EXT
  sudo mkdir -p "$MOUNT_EXT"
  attempt_mount "External Drive (F:)" \
    "sudo mount --bind $MOUNT_SRC_EXT $MOUNT_EXT" \
    "$MOUNT_EXT"

  ok "Mount verification complete."
  info "Listing top entries for verification:"
  ls -1 "$MOUNT_NAS" | head -5 || true
  ls -1 "$MOUNT_EXT" | head -5 || true
}

unmount_volumes() {
  info "Unmounting NAS + External drives..."
  sudo umount -f "$MOUNT_NAS" 2>/dev/null || true
  sudo umount -f "$MOUNT_EXT" 2>/dev/null || true
  ok "Unmount complete."
}

# --- Stack Controls ---
start_stack() {
  info "Starting Docker stack..."
  docker compose -f "$STACK_PATH/docker-compose.yml" -p "$PROJECT_NAME" up -d
  ok "Stack started."
}

stop_stack() {
  info "Stopping Docker stack..."
  docker compose -f "$STACK_PATH/docker-compose.yml" -p "$PROJECT_NAME" down
  ok "Stack stopped."
}

show_status() {
  info "Active containers:"
  docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

# --- Main ---
case "${1:-}" in
  start)
    mount_volumes
    start_stack
    show_status
    ;;
  stop)
    stop_stack
    unmount_volumes
    ;;
  restart)
    stop_stack
    unmount_volumes
    mount_volumes
    start_stack
    show_status
    ;;
  status)
    show_status
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|status}"
    exit 1
    ;;
esac