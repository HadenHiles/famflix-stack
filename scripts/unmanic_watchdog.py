#!/usr/bin/env python3
"""
Unmanic watchdog for FamFlix

Logic:
- Poll Tautulli get_activity every CHECK_INTERVAL seconds.
- If any active session has transcode_decision == "transcode":
    -> pause all configured Unmanic workers.
- If no transcodes for COOLDOWN seconds:
    -> resume those workers.

Env vars:
- TAUTULLI_URL       (default: http://tautulli:8181)
- TAUTULLI_API_KEY   (required)
- UNMANIC_HOST       (default: unmanic)
- CHECK_INTERVAL     (default: 5 seconds)
- COOLDOWN           (default: 60 seconds)
- UNMANIC_WORKERS    (default: W0,W1)
"""

import asyncio
import logging
import os
import time
from typing import List

import aiohttp
from unmanic_api import Unmanic  # pip install unmanic-api


TAUTULLI_URL = os.getenv("TAUTULLI_URL", "http://tautulli:8181")
TAUTULLI_API_KEY = os.getenv("TAUTULLI_API_KEY")
UNMANIC_HOST = os.getenv("UNMANIC_HOST", "unmanic")
CHECK_INTERVAL = int(os.getenv("CHECK_INTERVAL", "5"))
COOLDOWN = int(os.getenv("COOLDOWN", "60"))

# Comma-separated list of worker IDs, e.g. "W0,W1"
WORKERS_RAW = os.getenv("UNMANIC_WORKERS", "W0,W1")
UNMANIC_WORKERS: List[str] = [w.strip() for w in WORKERS_RAW.split(",") if w.strip()]


if not TAUTULLI_API_KEY:
    raise SystemExit("TAUTULLI_API_KEY is required")


async def tautulli_is_transcoding(session: aiohttp.ClientSession) -> bool:
    """
    Return True if Tautulli reports any active Plex stream with
    transcode_decision == 'transcode'.
    """
    params = {
        "apikey": TAUTULLI_API_KEY,
        "cmd": "get_activity",
    }
    url = f"{TAUTULLI_URL}/api/v2"

    try:
        async with session.get(url, params=params, timeout=10) as resp:
            resp.raise_for_status()
            payload = await resp.json()
    except Exception as e:
        logging.error("Error calling Tautulli get_activity: %s", e)
        # Fail safe: assume a transcode is happening so we don't hammer the box
        return True

    data = payload.get("response", {}).get("data", {})
    sessions = data.get("sessions", []) or []

    for s in sessions:
        # Tautulli exposes 'transcode_decision' in activity data
        # e.g. 'transcode', 'copy', 'direct play'
        decision = (s.get("transcode_decision") or s.get("video_decision") or "").lower()
        state = (s.get("state") or "").lower()  # 'playing', 'paused', etc.

        if decision == "transcode" and state != "paused":
            return True

    return False


async def set_unmanic_paused(unmanic: Unmanic, paused: bool) -> None:
    """
    Pause or resume all configured Unmanic workers.
    """
    action = "pausing" if paused else "resuming"
    for worker_id in UNMANIC_WORKERS:
        try:
            if paused:
                logging.info("Pausing Unmanic worker %s", worker_id)
                await unmanic.pause_worker(worker_id)
            else:
                logging.info("Resuming Unmanic worker %s", worker_id)
                await unmanic.resume_worker(worker_id)
        except Exception as e:
            logging.warning("Error %s worker %s: %s", action, worker_id, e)


async def main_loop() -> None:
    last_transcode_time = 0.0
    unmanic_paused = False

    async with aiohttp.ClientSession() as http_session:
        # Unmanic-API client (uses /unmanic/api/v2 under the hood)
        async with Unmanic(UNMANIC_HOST) as unmanic:
            logging.info(
                "Started Unmanic watchdog. Tautulli=%s, Unmanic host=%s, workers=%s",
                TAUTULLI_URL,
                UNMANIC_HOST,
                ", ".join(UNMANIC_WORKERS),
            )

            while True:
                start = time.time()
                try:
                    transcoding = await tautulli_is_transcoding(http_session)
                except Exception as e:
                    logging.error("Error checking Tautulli: %s", e)
                    transcoding = True  # fail safe

                now = time.time()

                if transcoding:
                    last_transcode_time = now
                    if not unmanic_paused:
                        logging.info("Detected active transcode(s) — pausing Unmanic workers.")
                        await set_unmanic_paused(unmanic, paused=True)
                        unmanic_paused = True
                else:
                    # No transcodes currently
                    if unmanic_paused and (now - last_transcode_time) >= COOLDOWN:
                        logging.info(
                            "No transcodes for %s seconds — resuming Unmanic workers.",
                            COOLDOWN,
                        )
                        await set_unmanic_paused(unmanic, paused=False)
                        unmanic_paused = False

                elapsed = time.time() - start
                sleep_for = max(1.0, CHECK_INTERVAL - elapsed)
                await asyncio.sleep(sleep_for)


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="[%(asctime)s] [%(levelname)s] %(message)s",
    )
    try:
        asyncio.run(main_loop())
    except KeyboardInterrupt:
        logging.info("Unmanic watchdog shutting down.")


if __name__ == "__main__":
    main()
