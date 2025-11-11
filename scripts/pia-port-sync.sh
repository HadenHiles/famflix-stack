#!/bin/sh
set -e

echo "[PIA-SYNC] Waiting 10 seconds for qBittorrent and PIA to initialize..."
sleep 10

# Ensure requests is installed only once per container lifetime
if ! python3 -c "import requests" >/dev/null 2>&1; then
  echo "[PIA-SYNC] Installing requests..."
  pip install -q requests
fi

while true; do
  if [ -f "$PIA_PORT_FILE" ]; then
    PORT=$(tr -d '\r\n' < "$PIA_PORT_FILE")
    echo "[PIA-SYNC] Updating qBittorrent to port $PORT..."
    python3 - "$PORT" <<'PYCODE'
import os, sys, requests

host = os.getenv("QBIT_HOST")
user = os.getenv("QBIT_USER")
pwd  = os.getenv("QBIT_PASS")
port = sys.argv[1]

try:
    s = requests.Session()
    r = s.post(f"{host}/api/v2/auth/login", data={"username": user, "password": pwd})
    if r.status_code != 200 or "Ok." not in r.text:
        print(f"[PIA-SYNC] Login failed: {r.status_code} {r.text}")
        sys.exit(1)
    s.post(f"{host}/api/v2/app/setPreferences", data={"json": f'{{"listen_port":{port}}}'})
    print(f"[PIA-SYNC] ✓ Synced qBittorrent port to {port}")
except Exception as e:
    print(f"[PIA-SYNC] Error syncing port: {e}")
PYCODE
  else
    echo "[PIA-SYNC] Port file not found at $PIA_PORT_FILE, retrying..."
  fi
  sleep "${SYNC_INTERVAL:-600}"
done

