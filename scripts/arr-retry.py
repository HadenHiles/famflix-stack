#!/usr/bin/env python3
import json
import math
import os
import time
from datetime import datetime, timedelta, timezone
from urllib import parse, request

# -------------------------------------------------------------------
# CONFIG
# -------------------------------------------------------------------
STATE_DIR = "/state"
STATE_FILE = os.path.join(STATE_DIR, "state.json")

SONARR_URL = os.environ.get("SONARR_URL", "http://sonarr:8989")
RADARR_URL = os.environ.get("RADARR_URL", "http://radarr:7878")
SAB_URL = os.environ.get("SAB_URL", "http://sabnzbd:8081")
SONARR_API_KEY = os.environ.get("SONARR_API_KEY", "")
RADARR_API_KEY = os.environ.get("RADARR_API_KEY", "")
SAB_API_KEY = os.environ.get("SAB_API_KEY", "").strip()
SAB_API_KEY_FILE = os.environ.get("SAB_API_KEY_FILE", "/sabnzbd.ini")
LOOP_INTERVAL = int(os.environ.get("LOOP_INTERVAL", "120"))
LOOKBACK_HOURS = int(os.environ.get("LOOKBACK_HOURS", "24"))
MISSING_MIN_INTERVAL = int(os.environ.get("MISSING_MIN_INTERVAL", "120"))
MISSING_IDLE_RECHECK_INTERVAL = int(os.environ.get("MISSING_IDLE_RECHECK_INTERVAL", "300"))
MISSING_MAX_BATCH = int(os.environ.get("MISSING_MAX_BATCH", "6"))
MISSING_DEFAULT_BATCH = int(os.environ.get("MISSING_DEFAULT_BATCH", "2"))
SAB_MIN_QUEUE_ITEMS = int(os.environ.get("SAB_MIN_QUEUE_ITEMS", "8"))
SAB_MIN_QUEUE_MB = int(os.environ.get("SAB_MIN_QUEUE_MB", "30000"))
SAB_ESTIMATED_MB_PER_GRAB = int(os.environ.get("SAB_ESTIMATED_MB_PER_GRAB", "8000"))
SONARR_MISSING_WEIGHT = int(os.environ.get("SONARR_MISSING_WEIGHT", "2"))
RADARR_MISSING_WEIGHT = int(os.environ.get("RADARR_MISSING_WEIGHT", "1"))


def load_sab_api_key_from_file(path):
    try:
        if not path or not os.path.exists(path):
            return ""
        with open(path, "r") as f:
            for line in f:
                if line.lower().startswith("api_key"):
                    _, _, value = line.partition("=")
                    return value.strip()
    except Exception:
        pass
    return ""


if not SAB_API_KEY:
    SAB_API_KEY = load_sab_api_key_from_file(SAB_API_KEY_FILE)

# -------------------------------------------------------------------
# STATE HELPERS
# -------------------------------------------------------------------
def load_state():
    os.makedirs(STATE_DIR, exist_ok=True)
    if not os.path.exists(STATE_FILE):
        return {
            "sonarr_processed": [],
            "radarr_processed": [],
            "sonarr_missing_processed": [],
            "radarr_missing_processed": [],
            "sonarr_missing_next_search": 0,
            "radarr_missing_next_search": 0,
            "missing_backfill_next_search": 0,
        }
    try:
        with open(STATE_FILE, "r") as f:
            return json.load(f)
    except Exception:
        return {
            "sonarr_processed": [],
            "radarr_processed": [],
            "sonarr_missing_processed": [],
            "radarr_missing_processed": [],
            "sonarr_missing_next_search": 0,
            "radarr_missing_next_search": 0,
            "missing_backfill_next_search": 0,
        }


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


def sab_api_get(mode, extra_params=None):
    if not SAB_API_KEY:
        return None

    params = {"mode": mode, "output": "json", "apikey": SAB_API_KEY}
    if extra_params:
        params.update(extra_params)

    qs = parse.urlencode(params)
    url = f"{SAB_URL}/api?{qs}"
    req = request.Request(url)
    with request.urlopen(req, timeout=20) as resp:
        return json.load(resp)

# -------------------------------------------------------------------
# PARSING HELPERS
# -------------------------------------------------------------------
def iso_to_dt(s: str) -> datetime:
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def parse_float(value, fallback=0.0):
    try:
        if value is None:
            return fallback
        if isinstance(value, (int, float)):
            return float(value)
        cleaned = "".join(ch for ch in str(value) if ch.isdigit() or ch in ".-")
        return float(cleaned) if cleaned else fallback
    except Exception:
        return fallback


def is_duplicate_nzb_failure(data):
    return data.get("message", "").strip().lower() == "duplicate nzb"


def is_sonarr_failure(rec):
    """
    Sonarr failure conditions:
    - eventType == downloadFailed
    - OR data contains failure/exception keys
    """

    event = rec.get("eventType", "")
    data = rec.get("data", {})

    if is_duplicate_nzb_failure(data):
        return False

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

    if is_duplicate_nzb_failure(data):
        return False

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
# WANTED-MISSING BACKFILL HANDLERS
# -------------------------------------------------------------------
def fetch_wanted_missing_records(base_url, api_key, endpoint):
    page_size = 1000
    first_page = api_get(
        base_url,
        api_key,
        endpoint,
        {
            "page": 1,
            "pageSize": page_size,
            "sortKey": "airDateUtc",
            "sortDirection": "ascending",
        },
    )

    records = first_page.get("records", [])
    page_count = (first_page.get("totalRecords", 0) + page_size - 1) // page_size

    for page in range(2, page_count + 1):
        next_page = api_get(
            base_url,
            api_key,
            endpoint,
            {
                "page": page,
                "pageSize": page_size,
                "sortKey": "airDateUtc",
                "sortDirection": "ascending",
            },
        )
        records.extend(next_page.get("records", []))

    return records


def trigger_wanted_missing_batch(state, name, base_url, api_key, endpoint,
                                 command_name, item_key, processed_key, max_searches):
    if not api_key or max_searches <= 0:
        return 0

    try:
        records = fetch_wanted_missing_records(base_url, api_key, endpoint)
    except Exception as e:
        print(f"[{name}] Wanted-missing fetch error: {e}")
        return 0

    if not records:
        print(f"[{name}] No wanted-missing items")
        state[processed_key] = []
        return 0

    processed = set(state.get(processed_key, []))
    pending = [record for record in records if record.get("id") not in processed]

    if not pending:
        print(f"[{name}] Wanted-missing list exhausted, cycling back through list")
        processed = set()
        pending = records

    triggered = 0
    for record in pending:
        item_id = record.get("id")
        if not item_id:
            continue

        print(f"[{name}] Triggering {command_name} for wanted-missing item {item_id}")
        try:
            api_post(base_url, api_key, "/command", {"name": command_name, item_key: [item_id]})
        except Exception as e:
            print(f"[{name}] Wanted-missing search error for {item_id}: {e}")
            continue

        processed.add(item_id)
        triggered += 1
        if triggered >= max_searches:
            break

    state[processed_key] = list(processed)[-2000:]
    return triggered


def get_sab_queue_snapshot():
    if not SAB_API_KEY:
        return None

    try:
        queue = (sab_api_get("queue") or {}).get("queue", {})
    except Exception as e:
        print(f"[Backfill] SAB queue fetch error: {e}")
        return None

    slots = queue.get("slots", []) or []
    return {
        "item_count": len(slots),
        "mbleft": parse_float(queue.get("mbleft"), 0.0),
    }


def calculate_missing_backfill_budget(state):
    now = time.time()
    if now < state.get("missing_backfill_next_search", 0):
        return 0

    snapshot = get_sab_queue_snapshot()

    if snapshot is None:
        budget = max(0, min(MISSING_MAX_BATCH, MISSING_DEFAULT_BATCH))
        state["missing_backfill_next_search"] = now + MISSING_MIN_INTERVAL
        print(
            "[Backfill] SAB queue visibility unavailable, "
            f"triggering fallback batch size={budget}"
        )
        return budget

    queue_items = snapshot["item_count"]
    queue_mb = snapshot["mbleft"]

    items_needed = max(0, SAB_MIN_QUEUE_ITEMS - queue_items)
    mb_needed = max(0.0, float(SAB_MIN_QUEUE_MB) - queue_mb)
    grabs_needed_by_size = int(math.ceil(mb_needed / max(1, SAB_ESTIMATED_MB_PER_GRAB)))

    budget = max(items_needed, grabs_needed_by_size)
    budget = max(0, min(MISSING_MAX_BATCH, budget))

    next_check = MISSING_MIN_INTERVAL if budget > 0 else MISSING_IDLE_RECHECK_INTERVAL
    state["missing_backfill_next_search"] = now + next_check

    print(
        f"[Backfill] SAB queue: items={queue_items}, mbleft={queue_mb:.0f}, "
        f"budget={budget}, next_check={next_check}s"
    )
    return budget


def split_backfill_budget(total_budget):
    if total_budget <= 0:
        return 0, 0

    sonarr_enabled = bool(SONARR_API_KEY)
    radarr_enabled = bool(RADARR_API_KEY)

    if sonarr_enabled and not radarr_enabled:
        return total_budget, 0
    if radarr_enabled and not sonarr_enabled:
        return 0, total_budget
    if not sonarr_enabled and not radarr_enabled:
        return 0, 0

    total_weight = max(1, SONARR_MISSING_WEIGHT + RADARR_MISSING_WEIGHT)
    sonarr_budget = int(round(total_budget * SONARR_MISSING_WEIGHT / total_weight))
    sonarr_budget = max(1 if SONARR_MISSING_WEIGHT > 0 else 0, sonarr_budget)
    sonarr_budget = min(total_budget, sonarr_budget)
    radarr_budget = total_budget - sonarr_budget

    if RADARR_MISSING_WEIGHT > 0 and radarr_budget == 0 and total_budget > 1:
        radarr_budget = 1
        sonarr_budget = total_budget - 1

    return sonarr_budget, radarr_budget


def handle_missing_backfill(state):
    budget = calculate_missing_backfill_budget(state)
    if budget <= 0:
        return

    sonarr_budget, radarr_budget = split_backfill_budget(budget)

    sonarr_triggered = trigger_wanted_missing_batch(
        state,
        "Sonarr",
        SONARR_URL,
        SONARR_API_KEY,
        "/wanted/missing",
        "EpisodeSearch",
        "episodeIds",
        "sonarr_missing_processed",
        sonarr_budget,
    )

    radarr_triggered = trigger_wanted_missing_batch(
        state,
        "Radarr",
        RADARR_URL,
        RADARR_API_KEY,
        "/wanted/missing",
        "MoviesSearch",
        "movieIds",
        "radarr_missing_processed",
        radarr_budget,
    )

    remaining = budget - sonarr_triggered - radarr_triggered
    if remaining > 0:
        # Reuse leftover budget with whichever service still has candidates.
        sonarr_triggered += trigger_wanted_missing_batch(
            state,
            "Sonarr",
            SONARR_URL,
            SONARR_API_KEY,
            "/wanted/missing",
            "EpisodeSearch",
            "episodeIds",
            "sonarr_missing_processed",
            remaining,
        )
        remaining = budget - sonarr_triggered - radarr_triggered

    if remaining > 0:
        radarr_triggered += trigger_wanted_missing_batch(
            state,
            "Radarr",
            RADARR_URL,
            RADARR_API_KEY,
            "/wanted/missing",
            "MoviesSearch",
            "movieIds",
            "radarr_missing_processed",
            remaining,
        )

    print(
        f"[Backfill] Triggered searches: sonarr={sonarr_triggered}, "
        f"radarr={radarr_triggered}, total={sonarr_triggered + radarr_triggered}"
    )

# -------------------------------------------------------------------
# MAIN LOOP
# -------------------------------------------------------------------
def main_loop():
    state = load_state()
    print("arr-retry started; watching for failed downloads...")
    print(
        f"Loop interval: {LOOP_INTERVAL}s, lookback: {LOOKBACK_HOURS}h, "
        f"missing min interval: {MISSING_MIN_INTERVAL}s, "
        f"missing max batch: {MISSING_MAX_BATCH}"
    )

    while True:
        try:
            handle_sonarr_failures(state)
            handle_radarr_failures(state)
            handle_missing_backfill(state)
            save_state(state)
        except Exception as e:
            print(f"[Main] Unexpected error: {e}")

        time.sleep(LOOP_INTERVAL)


if __name__ == "__main__":
    main_loop()