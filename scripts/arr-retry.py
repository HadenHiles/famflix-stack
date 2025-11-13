#!/usr/bin/env python3
import json
import os
import time
from datetime import datetime, timedelta, timezone
from urllib import request, parse, error

# -------------------------------------------------------------------
# CONFIG
# -------------------------------------------------------------------
STATE_DIR = "/state"
STATE_FILE = os.path.join(STATE_DIR, "state.json")

SONARR_URL = os.environ.get("SONARR_URL", "http://sonarr:8989")
RADARR_URL = os.environ.get("RADARR_URL", "http://radarr:7878")
SONARR_API_KEY = os.environ.get("SONARR_API_KEY", "")
RADARR_API_KEY = os.environ.get("RADARR_API_KEY", "")
LOOP_INTERVAL = int(os.environ.get("LOOP_INTERVAL", "900"))
LOOKBACK_HOURS = int(os.environ.get("LOOKBACK_HOURS", "24"))

# -------------------------------------------------------------------
# STATE HELPERS
# -------------------------------------------------------------------
def load_state():
    os.makedirs(STATE_DIR, exist_ok=True)
    if not os.path.exists(STATE_FILE):
        return {"sonarr_processed": [], "radarr_processed": []}
    try:
        with open(STATE_FILE, "r") as f:
            return json.load(f)
    except Exception:
        return {"sonarr_processed": [], "radarr_processed": []}


def save_state(state):
    with open(STATE_FILE, "w") as f:
        json.dump(state, f)

# -------------------------------------------------------------------
# API HELPERS
# -------------------------------------------------------------------
def api_get(base_url, api_key, path, params=None):
    if params is None:
        params = {}
    qs = parse.urlencode(params)
    url = f"{base_url}/api/v3{path}"
    if qs:
        url += f"?{qs}"

    headers = {"X-Api-Key": api_key}
    req = request.Request(url, headers=headers)
    with request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def api_post(base_url, api_key, path, payload=None):
    data = b"" if payload is None else json.dumps(payload).encode("utf-8")
    url = f"{base_url}/api/v3{path}"

    headers = {
        "X-Api-Key": api_key,
        "Content-Type": "application/json",
    }

    req = request.Request(url, data=data, headers=headers, method="POST")
    with request.urlopen(req, timeout=30) as resp:
        body = resp.read()
        if not body:
            return None
        try:
            return json.loads(body.decode("utf-8"))
        except:
            return None

# -------------------------------------------------------------------
# PARSING HELPERS
# -------------------------------------------------------------------
def iso_to_dt(s: str) -> datetime:
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def is_sonarr_failure(rec):
    """
    Sonarr failure conditions:
    - eventType == downloadFailed
    - OR data contains failure/exception keys
    """

    event = rec.get("eventType", "")
    data = rec.get("data", {})

    # Primary failure condition
    if event == "downloadFailed":
        return True

    # Secondary failure signals
    secondary_keys = (
        "failureMessage",
        "errorMessage",
        "downloadClientErrorMessage",
        "statusMessages",
    )

    if any(k in data for k in secondary_keys):
        return True

    return False


def is_radarr_failure(rec):
    """
    Radarr failure conditions:
    - eventType == downloadFailed
    - OR data contains failure markers
    """

    event = rec.get("eventType", "")
    data = rec.get("data", {})

    if event == "downloadFailed":
        return True

    secondary_keys = (
        "failureMessage",
        "errorMessage",
        "downloadClientErrorMessage",
        "statusMessages",
    )

    if any(k in data for k in secondary_keys):
        return True

    return False

# -------------------------------------------------------------------
# SONARR HANDLER
# -------------------------------------------------------------------
def handle_sonarr_failures(state):
    if not SONARR_API_KEY:
        print("[Sonarr] Missing API key")
        return

    since = datetime.now(timezone.utc) - timedelta(hours=LOOKBACK_HOURS)

    try:
        history = api_get(
            SONARR_URL,
            SONARR_API_KEY,
            "/history",
            {
                "pageSize": 200,
                "sortKey": "date",
                "sortDir": "desc",
            },
        )
    except Exception as e:
        print(f"[Sonarr] Fetch error: {e}")
        return

    records = history.get("records", [])

    print(f"[Sonarr] Retrieved {len(records)} history records")

    processed = set(state.get("sonarr_processed", []))
    new_processed = list(processed)

    for rec in records:
        rec_id = rec.get("id")
        if not rec_id or rec_id in processed:
            continue

        # Only consider real failures
        if not is_sonarr_failure(rec):
            continue

        # Time window filter
        date_str = rec.get("date")
        if not date_str:
            continue

        if iso_to_dt(date_str) < since:
            continue

        episode_id = rec.get("episodeId")
        if not episode_id:
            continue

        print(f"[Sonarr] Triggering EpisodeSearch for ep {episode_id}")

        try:
            api_post(
                SONARR_URL,
                SONARR_API_KEY,
                "/command",
                {"name": "EpisodeSearch", "episodeIds": [episode_id]},
            )
        except Exception as e:
            print(f"[Sonarr] EpisodeSearch error: {e}")

        new_processed.append(rec_id)

    state["sonarr_processed"] = new_processed[-500:]

# -------------------------------------------------------------------
# RADARR HANDLER
# -------------------------------------------------------------------
def handle_radarr_failures(state):
    if not RADARR_API_KEY:
        print("[Radarr] Missing API key")
        return

    since = datetime.now(timezone.utc) - timedelta(hours=LOOKBACK_HOURS)

    try:
        history = api_get(
            RADARR_URL,
            RADARR_API_KEY,
            "/history",
            {
                "pageSize": 200,
                "sortKey": "date",
                "sortDir": "desc",
            },
        )
    except Exception as e:
        print(f"[Radarr] Fetch error: {e}")
        return

    records = history.get("records", [])

    print(f"[Radarr] Retrieved {len(records)} history records")

    processed = set(state.get("radarr_processed", []))
    new_processed = list(processed)

    for rec in records:
        rec_id = rec.get("id")
        if not rec_id or rec_id in processed:
            continue

        # Only treat true failures
        if not is_radarr_failure(rec):
            continue

        # Time window filter
        date_str = rec.get("date")
        if not date_str:
            continue

        if iso_to_dt(date_str) < since:
            continue

        movie_id = rec.get("movieId")
        if not movie_id:
            continue

        print(f"[Radarr] Triggering MoviesSearch for movie {movie_id}")

        try:
            api_post(
                RADARR_URL,
                RADARR_API_KEY,
                "/command",
                {"name": "MoviesSearch", "movieIds": [movie_id]},
            )
        except Exception as e:
            print(f"[Radarr] MoviesSearch error: {e}")

        new_processed.append(rec_id)

    state["radarr_processed"] = new_processed[-500:]

# -------------------------------------------------------------------
# MAIN LOOP
# -------------------------------------------------------------------
def main_loop():
    state = load_state()
    print("arr-retry started; watching for failed downloads...")
    print(f"Loop interval: {LOOP_INTERVAL}s, lookback: {LOOKBACK_HOURS}h")

    while True:
        try:
            handle_sonarr_failures(state)
            handle_radarr_failures(state)
            save_state(state)
        except Exception as e:
            print(f"[Main] Unexpected error: {e}")

        time.sleep(LOOP_INTERVAL)


if __name__ == "__main__":
    main_loop()