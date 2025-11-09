#!/usr/bin/env bash
# ------------------------------------------------------------
# FamFlix WSL Controller (NAS + External Drive + Docker)
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

# --- Sudo wrapper ---
sudo_exec() { echo "$SUDO_PASS" | sudo -S "$@"; }

# --- Colors + Logging ---
RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[1;33m"; CYAN="\033[0;36m"; NC="\033[0m"
log()   { echo -e "${2:-$NC}$1${NC}"; }
ok()    { log "[OK] $1" "$GREEN"; }
warn()  { log "[WARN] $1" "$YELLOW"; }
info()  { log "[INFO] $1" "$CYAN"; }
error() { log "[ERROR] $1" "$RED"; exit 1; }

# --- Retry Settings ---
MAX_ATTEMPTS=3
RETRY_DELAY=2

# --- Ensure Docker is running ---
check_docker() {
  info "Checking Docker Engine..."
  if ! docker info >/dev/null 2>&1; then
    error "Docker Engine not running."
  fi
  ok "Docker Engine ready."
}

# --- Attempt mount with retries ---
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

# ------------------------------------------------------------
# Mount NAS + External F: Drive
# ------------------------------------------------------------
mount_volumes() {
  info "Mounting NAS + external volumes..."
  check_docker

  sudo_exec mkdir -p "$MOUNT_NAS" "$MOUNT_EXT"

  # --- Mount NAS (NFS) ---
  info "Mounting NFS share ${NAS_SERVER}:${NAS_SHARE}..."
  sudo_exec umount -f "$MOUNT_NAS" 2>/dev/null || true
  attempt_mount "NAS (NFS)" \
    "sudo_exec mount -t nfs ${NAS_SERVER}:${NAS_SHARE} $MOUNT_NAS" \
    "$MOUNT_NAS"

  # --- Verify NAS structure ---
  if [[ ! -d "$MOUNT_NAS/media/movies" ]]; then
    warn "Expected movies/tv directories not found under $MOUNT_NAS/media"
  else
    ok "NAS structure verified."
  fi

    # --- Mount External Drive (Windows F:) ---
  EXT_PATH="/mnt/f"
  WIN_DRIVE="F:"
  MAX_WAIT=20  # seconds

  sudo_exec mkdir -p "$EXT_PATH"

  # Quick check if already mounted and accessible
  if ls "$EXT_PATH" >/dev/null 2>&1; then
    ok "External drive already accessible at $EXT_PATH"
    return 0
  fi

  info "Attempting to mount Windows drive $WIN_DRIVE..."
  attempt=0
  while (( attempt < MAX_WAIT )); do
    sudo_exec mount -t drvfs "$WIN_DRIVE" "$EXT_PATH" >/dev/null 2>&1 && break
    ((attempt++))
    sleep 1
  done

  if ls "$EXT_PATH" >/dev/null 2>&1; then
    ok "External drive mounted at $EXT_PATH"
  else
    warn "External drive $WIN_DRIVE not detected after $MAX_WAIT s — skipping."
  fi

  # Mount only if not already mounted
  if ! mount | grep -q "on $EXT_PATH type drvfs"; then
    info "Attempting to mount Windows drive $WIN_DRIVE..."
    sudo_exec mkdir -p "$EXT_PATH"
    sudo_exec mount -t drvfs "$WIN_DRIVE" "$EXT_PATH" 2>/dev/null || true
    sleep 1
  fi

  # Final verification
  if mount | grep -q "on $EXT_PATH type drvfs"; then
    ok "External drive mounted at $EXT_PATH"
  else
    warn "External drive $WIN_DRIVE not detected after $MAX_WAIT s — skipping."
  fi
}

# ------------------------------------------------------------
# Unmount + Docker Controls
# ------------------------------------------------------------
unmount_volumes() {
  info "Unmounting NAS..."
  # Only unmount the NAS (NFS)
  sudo_exec umount -f "$MOUNT_NAS" 2>/dev/null || true
  ok "NAS unmounted."

  # Never forcibly unmount the Windows F: drive; just check its state
  if mount | grep -q "on /mnt/f type drvfs"; then
    info "Leaving /mnt/f mounted (Windows drive)."
  else
    warn "External drive not currently mounted — nothing to unmount."
  fi
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

# ------------------------------------------------------------
# Command Dispatcher
# ------------------------------------------------------------
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
    sleep 2
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