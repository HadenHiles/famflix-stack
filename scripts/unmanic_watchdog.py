#!/usr/bin/env python3
import asyncio
import os
import time
import subprocess
import aiohttp

TAUTULLI_URL = os.environ.get("TAUTULLI_URL", "http://tautulli:8181")
TAUTULLI_API_KEY = os.environ.get("TAUTULLI_API_KEY", "")
CHECK_INTERVAL = int(os.environ.get("CHECK_INTERVAL", "5"))
COOLDOWN = int(os.environ.get("COOLDOWN", "30"))  # seconds

last_action = None
last_change_ts = 0.0


def log(msg):
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{ts}] {msg}", flush=True)


def get_unmanic_ffmpeg_pids():
    """Return list of ffmpeg PIDs running inside unmanic container."""
    try:
        out = subprocess.check_output(
            ["docker", "exec", "unmanic", "pgrep", "-f", "ffmpeg"],
            stderr=subprocess.DEVNULL
        ).decode().strip()

        if not out:
            return []

        return [int(x) for x in out.split("\n") if x.strip().isdigit()]

    except subprocess.CalledProcessError:
        return []


def kill_stop(pid):
    subprocess.call(["docker", "exec", "unmanic", "kill", "-STOP", str(pid)])


def kill_cont(pid):
    subprocess.call(["docker", "exec", "unmanic", "kill", "-CONT", str(pid)])


async def tautulli_get_transcodes(session):
    """Return True if Plex is actively transcoding."""
    params = {
        "apikey": TAUTULLI_API_KEY,
        "cmd": "get_activity",
    }

    try:
        async with session.get(f"{TAUTULLI_URL}/api/v2", params=params, timeout=10) as resp:
            data = await resp.json()
    except Exception:
        return False

    sessions = data.get("response", {}).get("data", {}).get("sessions", []) or []

    for s in sessions:
        decision = s.get("stream_video_decision") or s.get("transcode_decision")
        if decision and decision.lower() != "copy":
            return True

    return False


async def main():
    global last_action, last_change_ts

    log("Watchdog started (PID-based).")

    if not TAUTULLI_API_KEY:
        log("[ERROR] TAUTULLI_API_KEY missing")
        return

    async with aiohttp.ClientSession() as session:
        while True:
            try:
                transcodes_active = await tautulli_get_transcodes(session)
                pids = get_unmanic_ffmpeg_pids()
                now = time.time()

                if transcodes_active:
                    if pids and last_action != "paused" and now - last_change_ts >= COOLDOWN:
                        log(f"[ACTION] Pausing {len(pids)} Unmanic ffmpeg processes")
                        for pid in pids:
                            kill_stop(pid)

                        last_action = "paused"
                        last_change_ts = now

                else:
                    if pids and last_action != "resumed" and now - last_change_ts >= COOLDOWN:
                        log(f"[ACTION] Resuming {len(pids)} Unmanic ffmpeg processes")
                        for pid in pids:
                            kill_cont(pid)

                        last_action = "resumed"
                        last_change_ts = now

            except Exception as e:
                log(f"[ERROR] Loop error: {e}")

            await asyncio.sleep(CHECK_INTERVAL)


if __name__ == "__main__":
    asyncio.run(main())
