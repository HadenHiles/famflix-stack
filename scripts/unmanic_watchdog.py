#!/usr/bin/env python3
import asyncio
import os
import time
import aiohttp

TAUTULLI_URL = os.environ.get("TAUTULLI_URL", "http://tautulli:8181").rstrip("/")
TAUTULLI_API_KEY = os.environ.get("TAUTULLI_API_KEY", "")
UNMANIC_HOST = os.environ.get("UNMANIC_HOST", "unmanic")
CHECK_INTERVAL = int(os.environ.get("CHECK_INTERVAL", "5"))
COOLDOWN = int(os.environ.get("COOLDOWN", "60"))
WORKER_IDS = [w.strip() for w in os.environ.get("UNMANIC_WORKERS", "W0").split(",") if w.strip()]

last_action = None
last_change_ts = 0.0


def log(msg: str) -> None:
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{ts}] {msg}", flush=True)


async def tautulli_get_transcodes(session):
    params = {
        "apikey": TAUTULLI_API_KEY,
        "cmd": "get_activity",
    }
    async with session.get(f"{TAUTULLI_URL}/api/v2", params=params, timeout=10) as resp:
        data = await resp.json()

    sessions = data.get("response", {}).get("data", {}).get("sessions", []) or []
    active = []

    for s in sessions:
        mode = s.get("stream_video_decision") or s.get("transcode_decision")
        if mode and mode.lower() != "copy":
            active.append(s)

    return active


async def unmanic_set_worker(session, worker_id, enabled: bool):
    url = f"http://{UNMANIC_HOST}:8888/api/v2/workers/{worker_id}"
    payload = {"enabled": enabled}

    try:
        async with session.put(url, json=payload, timeout=10) as resp:
            return resp.status == 200
    except Exception:
        return False


async def pause_workers(session):
    ok = 0
    for w in WORKER_IDS:
        if await unmanic_set_worker(session, w, False):
            ok += 1
    return ok


async def resume_workers(session):
    ok = 0
    for w in WORKER_IDS:
        if await unmanic_set_worker(session, w, True):
            ok += 1
    return ok


async def main():
    global last_action, last_change_ts

    log(f"Watchdog started. Monitoring workers: {WORKER_IDS}")

    if not TAUTULLI_API_KEY:
        log("[ERROR] Missing TAUTULLI_API_KEY. Exiting.")
        return

    async with aiohttp.ClientSession() as session:
        while True:
            try:
                active = await tautulli_get_transcodes(session)
                any_transcoding = len(active) > 0

                now = time.time()
                since_last = now - last_change_ts

                if any_transcoding:
                    if last_action != "paused" and since_last >= COOLDOWN:
                        log(f"[ACTION] Pausing workers — {len(active)} active transcodes.")
                        await pause_workers(session)
                        last_action = "paused"
                        last_change_ts = now
                else:
                    if last_action != "resumed" and since_last >= COOLDOWN:
                        log("[ACTION] Resuming workers — GPU idle.")
                        await resume_workers(session)
                        last_action = "resumed"
                        last_change_ts = now

            except Exception as e:
                log(f"[ERROR] Loop error: {e}")

            await asyncio.sleep(CHECK_INTERVAL)


if __name__ == "__main__":
    asyncio.run(main())
