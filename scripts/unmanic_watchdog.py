#!/usr/bin/env python3
import asyncio
import os
import time
from typing import List

import aiohttp

TAUTULLI_URL = os.environ.get("TAUTULLI_URL", "http://tautulli:8181").rstrip("/")
TAUTULLI_API_KEY = os.environ.get("TAUTULLI_API_KEY", "")
UNMANIC_HOST = os.environ.get("UNMANIC_HOST", "unmanic")
CHECK_INTERVAL = int(os.environ.get("CHECK_INTERVAL", "5"))
COOLDOWN = int(os.environ.get("COOLDOWN", "60"))
WORKER_IDS = [w.strip() for w in os.environ.get("UNMANIC_WORKERS", "W0,W1").split(",") if w.strip()]

# Notifications
TAUTULLI_NOTIFY_AGENT_ID = os.environ.get("TAUTULLI_NOTIFY_AGENT_ID", "1")
TAUTULLI_NOTIFY_SUBJECT = os.environ.get("TAUTULLI_NOTIFY_SUBJECT", "Unmanic Watchdog")
TAUTULLI_NOTIFY_BODY_PREFIX = os.environ.get("TAUTULLI_NOTIFY_BODY_PREFIX", "[Unmanic]")

# State memory
last_action = None
last_change_ts = 0.0


def log(msg: str):
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{ts}] {msg}", flush=True)


async def tautulli_get_sessions(session: aiohttp.ClientSession):
    params = {
        "apikey": TAUTULLI_API_KEY,
        "cmd": "get_activity",
    }
    async with session.get(f"{TAUTULLI_URL}/api/v2", params=params, timeout=10) as resp:
        data = await resp.json()

    sessions = data.get("response", {}).get("data", {}).get("sessions", []) or []
    interesting = []

    for s in sessions:
        decision = s.get("stream_video_decision") or s.get("transcode_decision")
        if (decision and decision.lower() != "copy") or s.get("transcode_decoding"):
            interesting.append(s)

    return interesting


async def tautulli_notify(session: aiohttp.ClientSession, message: str):
    params = {
        "apikey": TAUTULLI_API_KEY,
        "cmd"
