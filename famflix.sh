#!/usr/bin/env bash
set -euo pipefail

SECRET_FILE="$(dirname "$0")/famflix-secrets.sh"
if [[ -f "$SECRET_FILE" ]]; then
  source "$SECRET_FILE"
else
  echo "[ERROR] Missing secrets file: $SECRET_FILE"
  exit 1
fi

sudo_exec() { echo "$SUDO_PASS" | sudo -S "$@"; }

RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[1;33m"; CYAN="\033[0;36m"; NC="\033[0m"
log()   { echo -e "${2:-$NC}$1${NC}"; }
ok()    { log "[OK] $1" "$GREEN"; }
warn()  { log "[WARN] $1" "$YELLOW"; }
info()  { log "[INFO] $1" "$CYAN"; }
error() { log "[ERROR] $1" "$RED"; exit 1; }

check_docker() {
  info "Checking Docker Engine..."
  if ! docker info >/dev/null 2>&1; then
    error "Docker Engine not running."
  fi
  ok "Docker Engine ready."
}

attempt_mount() {
  local label="$1"; shift
  local mount_cmd="$1"; shift
  local verify_path="$1"
  for ((i=1; i<=MAX_ATTEMPTS; i++)); do
    info "Mounting $label (try $i/$MAX_ATTEMPTS)..."
    eval "$mount_cmd" >/dev/null 2>&1 || true
    sleep 1
    if mountpoint -q "$verify_path"; then
      ok "$label mounted at $verify_path"
      return 0
    fi
    warn "$label not yet mounted, retrying in $RETRY_DELAY s..."
    sleep "$RETRY_DELAY"
  done
  error "Failed to mount $label after $MAX_ATTEMPTS tries."
}

mount_volumes() {
  info "Mounting NAS + external volumes..."
  check_docker

  sudo_exec mkdir -p "$MOUNT_NAS" "$MOUNT_EXT"

  # --- Mount NFS NAS directly ---
  info "Mounting NFS share ${NAS_SERVER}:${NAS_SHARE}..."
  sudo_exec umount -f "$MOUNT_NAS" 2>/dev/null || true
  attempt_mount "NAS (NFS)" \
    "sudo_exec mount -t nfs ${NAS_SERVER}:${NAS_SHARE} $MOUNT_NAS" \
    "$MOUNT_NAS"

  # --- Verify media layout ---
  if [[ ! -d "$MOUNT_NAS/media/movies" ]]; then
    warn "Expected movies/tv directories not found under $MOUNT_NAS/media"
  else
    ok "NAS structure verified."
  fi

  # --- Bind external drive ---
  if [[ -d "$MOUNT_SRC_EXT" ]]; then
    info "Binding external drive..."
    sudo_exec umount -f "$MOUNT_EXT" 2>/dev/null || true
    sudo_exec mkdir -p "$MOUNT_EXT"
    sudo_exec mount --bind "$MOUNT_SRC_EXT" "$MOUNT_EXT"
    ok "External drive bound $MOUNT_SRC_EXT → $MOUNT_EXT"
  else
    warn "External F: drive not found, skipping."
  fi
}

unmount_volumes() {
  info "Unmounting NAS + external..."
  sudo_exec umount -f "$MOUNT_EXT" 2>/dev/null || true
  sudo_exec umount -f "$MOUNT_NAS" 2>/dev/null || true
  ok "Unmount complete."
}

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

verify_mounts() {
  echo
  info "🔍 Quick Mount Verification"
  echo "------------------------------------------------------"
  echo -e "📦 NAS Top Entries ($MOUNT_NAS):"
  ls -lh "$MOUNT_NAS" | awk '{print "  " $9}' | head -10
  echo
  echo -e "💾 External Drive ($MOUNT_EXT):"
  ls -lh "$MOUNT_EXT" | awk '{print "  " $9}' | head -10
  echo "------------------------------------------------------"
}

case "${1:-}" in
  start)
    mount_volumes
    start_stack
    show_status
    verify_mounts
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
    verify_mounts
    ;;
  status)
    show_status
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|status}"
    exit 1
    ;;
esac