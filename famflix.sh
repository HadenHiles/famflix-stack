#!/usr/bin/env bash
# ------------------------------------------------------------
# FamFlix WSL Controller (secure edition, NAS subfolder support)
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

# --- Secure Sudo Wrapper ---
if [[ -z "${SUDO_PASS:-}" ]]; then
  echo "[ERROR] SUDO_PASS not defined in secrets file."
  exit 1
fi

sudo_exec() {
  echo "$SUDO_PASS" | sudo -S "$@"
}

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

  sudo_exec mkdir -p "$MOUNT_NAS" /mnt/nas/tmpremote "$MOUNT_EXT"

  # --- Mount NAS parent share ---
  info "Mounting NAS share //$NAS_SERVER/$NAS_SHARE ..."
  sudo_exec umount -f /mnt/nas/tmpremote 2>/dev/null || true
  attempt_mount "NAS" \
    "sudo_exec mount -t cifs //$NAS_SERVER/$NAS_SHARE /mnt/nas/tmpremote -o username=$NAS_USER,password=$NAS_PASS,uid=0,gid=0,file_mode=0777,dir_mode=0777,cache=none,nounix,noserverino,mfsymlinks,vers=3.0" \
    "/mnt/nas/tmpremote"

  # --- Bind famflix root (canonical layout) ---
  local src_root="/mnt/nas/tmpremote/famflix"
  if [[ -d "$src_root/media/movies" && -d "$src_root/media/tv" ]]; then
    info "Binding canonical FamFlix directory..."
    sudo_exec mount --bind "$src_root" "$MOUNT_NAS"
    ok "Bound /mnt/nas/tmpremote/famflix → /mnt/nas/famflix"
  else
    error "FamFlix root layout not found at $src_root (expected media/movies + media/tv)"
  fi

  # --- Clean ghost .smbdelete files ---
  info "Cleaning stale Samba ghost files..."
  sudo_exec find "$MOUNT_NAS" -type f -name ".smbdelete*" -delete 2>/dev/null || true
  ok "Ghost file cleanup complete."

  # --- Verify movie/tv directories exist ---
  if [[ ! -d "$MOUNT_NAS/media/movies" || ! -d "$MOUNT_NAS/media/tv" ]]; then
    warn "Movies or TV subfolder missing — check your NAS directory layout."
  fi

  # --- Mount External Drive (F:) ---
  info "Checking external F: drive availability..."
  sudo_exec umount -f "$MOUNT_EXT" 2>/dev/null || true
  sudo_exec mkdir -p "$MOUNT_EXT"

  # Wait for /mnt/f to become accessible
  for i in {1..10}; do
    if [ -d "$MOUNT_SRC_EXT" ] && [ "$(ls -A "$MOUNT_SRC_EXT" 2>/dev/null)" ]; then
      ok "External F: drive detected at $MOUNT_SRC_EXT."
      break
    fi
    warn "F: drive not detected yet (try $i/10)..."
    sleep 3
  done

  if [ ! -d "$MOUNT_SRC_EXT" ] || [ ! "$(ls -A "$MOUNT_SRC_EXT" 2>/dev/null)" ]; then
    warn "F: drive not found or empty — skipping external mount this session."
    return 0
  fi

  attempt_mount "External Drive (F:)" \
    "sudo_exec mount --bind $MOUNT_SRC_EXT $MOUNT_EXT" \
    "$MOUNT_EXT"

  ok "External drive successfully bound."

  ok "Mount verification complete."
}

unmount_volumes() {
  info "Unmounting NAS + External drives..."
  sudo_exec umount -f "$MOUNT_EXT" 2>/dev/null || true
  sudo_exec umount -f "$MOUNT_NAS" 2>/dev/null || true
  sudo_exec umount -f /mnt/nas/tmpremote 2>/dev/null || true
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

# --- Verification Helper ---
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

# --- Main ---
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