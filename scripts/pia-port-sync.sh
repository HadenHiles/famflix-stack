#!/bin/sh
set -e

pip install requests >/dev/null 2>&1

while true; do
  if [ -f "$PIA_PORT_FILE" ]; then
    PORT=$(cat "$PIA_PORT_FILE" | tr -d '\r\n')
    echo "Updating qBittorrent to port $PORT..."
    python3 - <<'PYCODE'
import os, requests
host=os.getenv('QBIT_HOST')
user=os.getenv('QBIT_USER')
pwd=os.getenv('QBIT_PASS')
portfile=os.getenv('PIA_PORT_FILE')
session=requests.Session()
session.post(f'{host}/api/v2/auth/login', data={'username':user,'password':pwd})
port=open(portfile).read().strip()
session.post(f'{host}/api/v2/app/setPreferences', data={'json':f'{{"listen_port":{port}}}'})
print(f'✓ Synced qBittorrent port to {port}')
PYCODE
  else
    echo "Port file not found at $PIA_PORT_FILE, retrying..."
  fi
  sleep ${SYNC_INTERVAL:-600}
done
