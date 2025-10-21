#!/usr/bin/env python3
"""
Sonarr Rolling Window (Multi-User Buffer)
-----------------------------------------
Maintains a rolling 3–4 episode buffer for each Plex/Tautulli user.
If multiple users are watching the same show, each gets their own "buffer window"
and episodes are only unmonitored after 120 days of inactivity (since last watch).
Does NOT delete files — Maintainerr handles cleanup after 120 days unmonitored.

Environment variables (set in docker-compose):
----------------------------------------------
SONARR_URL=http://sonarr:8989
SONARR_API_KEY=xxxxx
TAUTULLI_URL=http://tautulli:8181
TAUTULLI_API_KEY=yyyyy
FUTURE_WINDOW=4             # how many eps ahead to keep monitored
RETAIN_DAYS=120             # keep watched eps monitored this many days after last watch
ROLLING_INTERVAL_HOURS=6    # how often to recheck (if run continuously)
"""
import os, time, datetime, requests
from collections import defaultdict

SONARR_URL = os.getenv("SONARR_URL", "http://sonarr:8989")
SONARR_API_KEY = os.getenv("SONARR_API_KEY")
TAUTULLI_URL = os.getenv("TAUTULLI_URL", "http://tautulli:8181")
TAUTULLI_API_KEY = os.getenv("TAUTULLI_API_KEY")
FUTURE_WINDOW = int(os.getenv("FUTURE_WINDOW", "4"))
RETAIN_DAYS = int(os.getenv("RETAIN_DAYS", "120"))
ROLLING_INTERVAL_HOURS = int(os.getenv("ROLLING_INTERVAL_HOURS", "6"))

if not SONARR_API_KEY or not TAUTULLI_API_KEY:
    raise SystemExit("❌ Please set SONARR_API_KEY and TAUTULLI_API_KEY")

def sonarr_get(path, **params):
    r = requests.get(f"{SONARR_URL}/api/v3{path}", headers={"X-Api-Key": SONARR_API_KEY}, params=params, timeout=30)
    r.raise_for_status()
    return r.json()

def sonarr_put(path, data):
    r = requests.put(f"{SONARR_URL}/api/v3{path}", headers={"X-Api-Key": SONARR_API_KEY}, json=data, timeout=30)
    r.raise_for_status()
    return r.json() if r.text else {}

def tautulli(cmd, **params):
    params.update({"apikey": TAUTULLI_API_KEY, "cmd": cmd})
    r = requests.get(f"{TAUTULLI_URL}/api/v2", params=params, timeout=30)
    r.raise_for_status()
    data = r.json().get("response", {}).get("data", {})
    return data

def get_recent_history(days_back=RETAIN_DAYS):
    """Fetch all plays in last X days."""
    records, start, page, per_page = [], 0, 1, 100
    cutoff = datetime.datetime.utcnow() - datetime.timedelta(days=days_back)
    while True:
        data = tautulli("get_history", length=per_page, page=page)
        if not data or "records" not in data:
            break
        batch = data["records"]
        for r in batch:
            if not r.get("grandparent_title"):
                continue
            dt = datetime.datetime.utcfromtimestamp(r["date"])
            if dt >= cutoff:
                records.append(r)
        if len(batch) < per_page:
            break
        page += 1
    return records

def build_user_progress(history):
    """Return {show_title: {user: last_ep_number, last_watch_date}}."""
    progress = defaultdict(lambda: defaultdict(lambda: {"ep": 0, "last": None}))
    for rec in history:
        show = rec.get("grandparent_title")
        epnum = rec.get("episode_index") or rec.get("episode_number") or 0
        user = rec.get("user", "unknown")
        dt = datetime.datetime.utcfromtimestamp(rec["date"])
        if epnum > progress[show][user]["ep"]:
            progress[show][user] = {"ep": epnum, "last": dt}
    return progress

def rolling_update():
    print(f"🚀 Starting rolling-window check at {datetime.datetime.now().isoformat()}")
    history = get_recent_history(RETAIN_DAYS)
    progress = build_user_progress(history)
    shows = {s["title"]: s for s in sonarr_get("/series")}

    for title, users in progress.items():
        if title not in shows:
            continue
        series = shows[title]
        sid = series["id"]
        eps = sonarr_get("/episode", seriesId=sid)
        # Compute global "keep until" date
        latest_any = max(u["last"] for u in users.values() if u["last"])
        keep_cutoff = latest_any - datetime.timedelta(days=RETAIN_DAYS)
        # Mark next N episodes for each user
        to_monitor = set()
        for user, meta in users.items():
            for ep in eps:
                if ep.get("episodeNumber") and meta["ep"] < ep["episodeNumber"] <= meta["ep"] + FUTURE_WINDOW:
                    to_monitor.add(ep["id"])
        if to_monitor:
            sonarr_put("/episode/monitor", {"episodeIds": list(to_monitor), "monitored": True})
            print(f"✅ {title}: monitored {len(to_monitor)} eps ahead for active users.")
        # Unmonitor older episodes no one has watched in RETAIN_DAYS
        for ep in eps:
            air = ep.get("airDateUtc")
            if not air or not ep.get("hasFile"):
                continue
            if ep["monitored"] and datetime.datetime.fromisoformat(air.replace("Z", "")) < keep_cutoff:
                sonarr_put(f"/episode/{ep['id']}", {"id": ep["id"], "monitored": False})
        time.sleep(0.2)
    print("✅ Rolling-window update complete.\n")

if __name__ == "__main__":
    while True:
        rolling_update()
        print(f"Sleeping {ROLLING_INTERVAL_HOURS}h…")
        time.sleep(ROLLING_INTERVAL_HOURS * 3600)
