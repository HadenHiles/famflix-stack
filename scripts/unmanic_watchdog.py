#!/usr/bin/env python3
import asyncio
import os
import time
import docker
import subprocess
import aiohttp


TAUTULLI_URL = os.environ.get("TAUTULLI_URL", "http://tautulli:8181")
TAUTULLI_API_KEY = os.environ.get("TAUTULLI_API_KEY", "")
CHECK_INTERVAL = int(os.environ.get("CHECK_INTERVAL", "5"))
COOLDOWN = int(os.environ.get("COOLDOWN", "30"))

last_action = None
last_change_ts = 0.0


def log(msg):
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{ts}] {msg}", flush=True)


# Connect to host Docker via socket
docker_client = docker.DockerClient(base_url="unix://var/run/docker.sock")


def get_unmanic_ffmpeg_pids():
    """Return list of ffmpeg PIDs running inside unmanic container."""
    try:
        container = docker_client.containers.get("unmanic")
        exec_result = container.exec_run("pgrep -f ffmpeg")
        output = exec_result.output.decode().strip()

        if not output:
            return []

        return [int(pid) for pid in output.split("\n") if pid.strip().isdigit()]

    except Exception:
        return []


def send_signal_to_unmanic(pid: int, signal: str):
    try:
        container = docker_client.containers.get("unmanic")
        container.exec_run(f"kill -{signal} {pid}")
    except Exception as e:
        log(f"[ERROR] Failed sending {signal} to {pid}: {e}")


async def tautulli_get_transcodes(session):
    """Returns True if Plex has active transcodes."""
    params = {
        "apikey": TAUTULLI_API_KEY,
        "cmd": "get_activity",
    }

    try:
        async with session.get(f"{TAUTULLI_URL}/api/v2", params=params) as resp:
            data = await resp.json()
    except Exception:
        return False

    sessions = data.get("response", {}).get("data", {}).get("sessions", []) or []

    for s in sessions:
        decision = s.get("transcode_decision") or s.get("stream_video_decision")
        if decision and decision.lower() != "copy":
            return True

    return False


async def main():
    global last_action, last_change_ts

    log("Watchdog started (Docker-socket mode).")

    if not TAUTULLI_API_KEY:
        log("[ERROR] TAUTULLI_API_KEY missing")
        return

    async with aiohttp.ClientSession() as session:
        while True:
            try:
                transcodes = await tautulli_get_transcodes(session)
                pids = get_unmanic_ffmpeg_pids()
                now = time.time()

                if transcodes:
                    if pids and last_action != "paused" and now - last_change_ts >= COOLDOWN:
                        log(f"[ACTION] Pausing {len(pids)} ffmpeg processes")
                        for pid in pids:
                            send_signal_to_unmanic(pid, "STOP")

                        last_action = "paused"
                        last_change_ts = now

                else:
                    if pids and last_action != "resumed" and now - last_change_ts >= COOLDOWN:
                        log(f"[ACTION] Resuming {len(pids)} ffmpeg processes")
                        for pid in pids:
                            send_signal_to_unmanic(pid, "CONT")

                        last_action = "resumed"
                        last_change_ts = now

            except Exception as e:
                log(f"[ERROR] Loop error: {e}")

            await asyncio.sleep(CHECK_INTERVAL)


if __name__ == "__main__":
    asyncio.run(main())
