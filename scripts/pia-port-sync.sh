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
    # Keep transient sync failures inside the loop, not Docker's restart policy.
    if python3 - "$PORT" <<'PYCODE'
import json
import os
import re
import sys
import requests

host = os.getenv("QBIT_HOST")
user = os.getenv("QBIT_USER")
pwd  = os.getenv("QBIT_PASS")
port = sys.argv[1]

try:
    if not re.fullmatch(r"[0-9]{1,5}", port) or not 1 <= int(port) <= 65535:
        raise ValueError("Invalid forwarded port")
    if not host or not host.startswith(("http://", "https://")) or not user or not pwd:
        raise ValueError("Missing or invalid qBittorrent configuration")
    port = int(port)
    with requests.Session() as s:
        s.trust_env = False

        def request(method, path, **kwargs):
            response = s.request(method, f"{host.rstrip('/')}/api/v2/{path}",
                                 timeout=(5, 10), allow_redirects=False, **kwargs)
            if not 200 <= response.status_code < 300:
                raise ValueError(f"qBittorrent HTTP {response.status_code}")
            return response

        login = request("POST", "auth/login", data={"username": user, "password": pwd})
        if login.status_code not in (200, 204) or not any(
                re.fullmatch(r"SID|QBT_SID_[0-9]{1,5}", cookie.name) for cookie in s.cookies):
            raise ValueError("Login did not establish an authenticated session")

        def preferences():
            value = request("GET", "app/preferences").json()
            if not isinstance(value, dict) or type(value.get("listen_port")) is not int:
                raise ValueError("Invalid authenticated preferences response")
            return value

        if preferences()["listen_port"] == port:
            print(f"[PIA-SYNC] Verified qBittorrent port already matches {port}")
        else:
            request("POST", "app/setPreferences", data={"json": json.dumps({"listen_port": port})})
            if preferences()["listen_port"] != port:
                raise ValueError("Listening port read-back did not match")
            print(f"[PIA-SYNC] Verified qBittorrent port updated to {port}")
except (requests.RequestException, ValueError) as error:
    print(f"[PIA-SYNC] Port sync failed ({type(error).__name__}); check API access, credentials and port configuration")
    sys.exit(1)
PYCODE
    then
      :
    else
      echo "[PIA-SYNC] Sync was not verified; retrying after ${SYNC_INTERVAL:-600} seconds"
    fi
  else
    echo "[PIA-SYNC] Port file not found at $PIA_PORT_FILE, retrying..."
  fi
  sleep "${SYNC_INTERVAL:-600}"
done
