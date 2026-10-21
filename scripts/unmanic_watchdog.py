#!/usr/bin/env python3
"""Yield Unmanic workers to playback, imports, unpacking and NAS I/O pressure."""

import concurrent.futures
import configparser
import json
import math
import os
from pathlib import Path
import sys
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET


ARR_IO_COMMANDS = {
    "DownloadedEpisodesScan", "DownloadedMoviesScan",
    "RescanSeries", "RescanMovie", "RefreshSeries", "RefreshMovie",
    "RenameFiles", "RenameSeries", "RenameMovie", "RenameMovieFiles",
    "ManualImport", "MoveSeries", "MoveMovie", "RefreshAllSeries", "RefreshAllMovies",
}
SAB_BUSY = {"extracting", "repairing", "verifying", "moving", "running"}


def log(message):
    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {message}", flush=True)


def atomic_json(path, value):
    temp = path.with_suffix(".tmp")
    with temp.open("w") as handle:
        json.dump(value, handle, sort_keys=True)
        handle.flush()
        os.fsync(handle.fileno())
    temp.replace(path)
    directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def request_json(url, *, params=None, headers=None, body=None):
    if params:
        url += "?" + urllib.parse.urlencode(params)
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(
        url, data=data, headers={"Content-Type": "application/json", **(headers or {})}
    )
    with urllib.request.urlopen(request, timeout=10) as response:
        return json.load(response)


def arr_reasons(app, commands):
    if not isinstance(commands, list):
        raise ValueError("Expected Arr command list")
    reasons = []
    for command in commands:
        if not isinstance(command, dict) or not isinstance(command.get("name"), str):
            raise ValueError("Invalid Arr command")
        if command.get("status") in {"started", "running"}:
            if command["name"] in ARR_IO_COMMANDS:
                reasons.append(f"{app}: {command['name']}")
    return reasons


def plex_reasons(data):
    response = data["response"]
    if response["result"] != "success":
        raise ValueError("Tautulli did not report success")
    sessions = response["data"]["sessions"]
    if not isinstance(sessions, list):
        raise ValueError("Expected Plex sessions list")
    reasons = []
    for session in sessions:
        decisions = [
            str(session.get(key, "")).lower()
            for key in ("transcode_decision", "stream_video_decision", "stream_audio_decision")
        ]
        if "transcode" in decisions:
            reasons.append("Plex: active transcode")
    return sorted(set(reasons))


def arr_queue_reasons(app, queue):
    if not isinstance(queue.get("records"), list):
        raise ValueError("Expected Arr queue records")
    return [f"{app}: active import"] if any(
        item.get("trackedDownloadState") == "importing" for item in queue["records"]
    ) else []


def sab_reasons(queue, history):
    queue = queue["queue"]
    history = history["history"]
    if not isinstance(queue.get("slots"), list) or not isinstance(history.get("slots"), list):
        raise ValueError("Expected SAB queue/history slots")
    if not isinstance(queue.get("status"), str):
        raise ValueError("Expected SAB queue status")
    statuses = [queue["status"]]
    statuses.extend(slot["status"] for slot in queue["slots"] + history["slots"])
    return ["SAB: unpack/repair/move"] if any(
        str(status).lower() in SAB_BUSY for status in statuses
    ) else []


def io_pressure(path):
    for line in path.read_text().splitlines():
        if line.startswith("full "):
            fields = dict(item.split("=", 1) for item in line.split()[1:])
            value = float(fields["avg10"])
            if not math.isfinite(value) or not 0 <= value <= 100:
                raise ValueError("Invalid I/O pressure")
            return value
    raise ValueError("Missing full I/O pressure")


class Policy:
    def __init__(self, high=35.0, low=10.0, sustained=15.0, quiet=120.0):
        if not (0 <= low < high <= 100 and sustained >= 0 and quiet > 0):
            raise ValueError("Invalid watchdog thresholds")
        self.high, self.low = high, low
        self.sustained, self.quiet = sustained, quiet
        self.high_since = None
        self.quiet_since = None
        self.io_blocked = False

    def decide(self, now, pressure, reasons):
        reasons = list(reasons)
        if pressure is not None:
            if pressure >= self.high:
                if self.high_since is None:
                    self.high_since = now
                if now - self.high_since >= self.sustained:
                    self.io_blocked = True
            else:
                self.high_since = None
            if self.io_blocked and pressure > self.low:
                reasons.append(f"NAS: full I/O pressure {pressure:.1f}%")
        if reasons:
            self.quiet_since = None
            return reasons, False, 0
        if self.quiet_since is None:
            self.quiet_since = now
        elapsed = now - self.quiet_since
        if elapsed >= self.quiet:
            self.io_blocked = False
        return [], elapsed >= self.quiet, max(0, self.quiet - elapsed)


def worker_token(worker):
    return [worker["start_time"], worker["current_task"]]


class Controller:
    def __init__(self, state_dir, action):
        self.path = state_dir / "ownership.json"
        self.owned = json.loads(self.path.read_text()) if self.path.exists() else {}
        if not isinstance(self.owned, dict) or any(
            not isinstance(key, str) or not isinstance(value, list) or len(value) != 2
            for key, value in self.owned.items()
        ):
            raise ValueError("Invalid ownership state; refusing automatic recovery")
        self.action = action

    def save(self):
        atomic_json(self.path, self.owned)

    def reconcile(self, workers, blocked, may_resume):
        by_id = {}
        for worker in workers:
            if not isinstance(worker.get("id"), str) or not isinstance(worker.get("paused"), bool):
                raise ValueError("Invalid worker status")
            worker_token(worker)
            by_id[worker["id"]] = worker
        for worker_id in list(self.owned):
            worker = by_id.get(worker_id)
            if worker is None or worker_token(worker) != self.owned[worker_id]:
                log(f"[OWNERSHIP] Worker {worker_id} changed; leaving its pause state untouched")
                del self.owned[worker_id]
                self.save()
        for worker_id, worker in by_id.items():
            if blocked and not worker["paused"]:
                # Journal before the API call so a crash cannot lose a pause we requested.
                self.owned[worker_id] = worker_token(worker)
                self.save()
                self.action("pause", worker_id)
                log(f"[ACTION] Paused worker {worker_id}")
            elif may_resume and worker_id in self.owned:
                if worker["paused"]:
                    self.action("resume", worker_id)
                    log(f"[ACTION] Resumed watchdog-owned worker {worker_id}")
                del self.owned[worker_id]
                self.save()


class Monitor:
    def __init__(self):
        self.unmanic = os.environ.get("UNMANIC_URL", "http://unmanic:8888").rstrip("/")
        self.tautulli = os.environ.get("TAUTULLI_URL", "http://tautulli:8181").rstrip("/")
        self.tautulli_key = os.environ["TAUTULLI_API_KEY"]
        if not self.tautulli_key:
            raise ValueError("Missing Tautulli API key")
        self.arr = {}
        for app, port in (("sonarr", 8989), ("radarr", 7878)):
            key = ET.parse(f"/credentials/{app}.xml").findtext("ApiKey")
            if not key:
                raise ValueError(f"Missing {app} API key")
            self.arr[app] = (
                os.environ.get(f"{app.upper()}_URL", f"http://{app}:{port}").rstrip("/"), key
            )
        config = configparser.ConfigParser(interpolation=None, strict=False)
        # SAB's ConfigObj preamble/nested sections are not INI; only parse [misc].
        text = Path("/credentials/sabnzbd.ini").read_text()
        misc = text.split("[misc]\n", 1)[1].split("\n[", 1)[0]
        config.read_string("[misc]\n" + misc)
        self.sab_key = config["misc"]["api_key"].strip('"')
        self.sab = os.environ.get("SAB_URL", "http://sabnzbd:8081").rstrip("/")
        if not self.sab_key:
            raise ValueError("Missing SAB API key")

    def arr_activity(self, app):
        url, key = self.arr[app]
        headers = {"X-Api-Key": key}
        reasons = arr_reasons(app, request_json(url + "/api/v3/command", headers=headers))
        page, count = 1, 0
        while True:
            queue = request_json(
                url + "/api/v3/queue", params={"page": page, "pageSize": 1000}, headers=headers,
            )
            reasons.extend(arr_queue_reasons(app, queue))
            count += len(queue["records"])
            if count >= queue["totalRecords"]:
                break
            if not queue["records"] or page >= 10:
                raise ValueError("Incomplete Arr queue coverage")
            page += 1
        return sorted(set(reasons))

    def plex_activity(self):
        return plex_reasons(request_json(
            self.tautulli + "/api/v2",
            params={"apikey": self.tautulli_key, "cmd": "get_activity"},
        ))

    def sab_activity(self):
        def fetch(mode):
            return request_json(self.sab + "/api", params={
                "apikey": self.sab_key, "output": "json", "mode": mode, "limit": 100,
            })
        return sab_reasons(fetch("queue"), fetch("history"))

    def workers(self):
        workers = request_json(self.unmanic + "/unmanic/api/v2/workers/status")["workers_status"]
        if not isinstance(workers, list) or not workers:
            raise ValueError("Missing Unmanic workers")
        return workers

    def action(self, action, worker_id):
        result = request_json(
            self.unmanic + "/unmanic/api/v2/workers/worker/" + action,
            body={"worker_id": worker_id},
        )
        if result.get("success") is not True:
            raise ValueError("Unmanic did not confirm worker action")
        workers = self.workers()
        worker = next((item for item in workers if item["id"] == worker_id), None)
        if worker is None or worker["paused"] != (action == "pause"):
            raise RuntimeError("Worker action not confirmed by fresh status")


def run(state_dir):
    state_dir.mkdir(parents=True, exist_ok=True)
    monitor = Monitor()
    controller = Controller(state_dir, monitor.action)
    policy = Policy(
        high=float(os.environ.get("IO_HIGH", "35")),
        low=float(os.environ.get("IO_LOW", "10")),
        sustained=float(os.environ.get("IO_SUSTAINED", "15")),
        quiet=float(os.environ.get("QUIET_SECONDS", "120")),
    )
    # After restart, recover conservatively without remembering a possibly stale quiet window.
    policy.io_blocked = bool(controller.owned)
    interval = float(os.environ.get("CHECK_INTERVAL", "5"))
    if not math.isfinite(interval) or interval <= 0:
        raise ValueError("Invalid check interval")
    previous = None
    last_report = 0.0
    log("[START] Native worker API; fail-closed monitoring; waiting for a quiet window")
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        while True:
            reasons, errors = [], []
            checks = {
                "sonarr": lambda: monitor.arr_activity("sonarr"),
                "radarr": lambda: monitor.arr_activity("radarr"),
                "plex": monitor.plex_activity,
                "sab": monitor.sab_activity,
            }
            futures = {name: pool.submit(check) for name, check in checks.items()}
            for name, future in futures.items():
                try:
                    reasons.extend(future.result())
                except Exception as error:
                    # Exception messages/URLs may contain API keys or media paths.
                    errors.append(f"{name}: {type(error).__name__}")
            pressure = None
            try:
                pressure = io_pressure(Path("/host-pressure/io"))
            except (OSError, ValueError, KeyError) as error:
                errors.append(f"io: {type(error).__name__}")
            if (state_dir / "manual-hold").exists():
                reasons.append("Operator: manual hold")
            reasons.extend(f"Monitor unavailable: {error}" for error in errors)
            reasons, may_resume, remaining = policy.decide(time.monotonic(), pressure, reasons)
            workers = []
            try:
                workers = monitor.workers()
                controller.reconcile(workers, bool(reasons), may_resume)
                # Verify actual pause flags, not just success-shaped HTTP responses.
                workers = monitor.workers()
                for worker in workers:
                    if reasons and not worker["paused"]:
                        raise RuntimeError("Worker pause not confirmed")
            except Exception as error:
                errors.append(f"unmanic: {type(error).__name__}")
                policy.quiet_since = None
            status = {
                "updated_at": time.time(),
                "mode": "monitor-error" if errors else (
                    "yielding" if reasons else "quiet-wait" if not may_resume else "available"
                ),
                "reasons": sorted(set(reasons)),
                "errors": errors,
                "io_full_avg10": pressure,
                "quiet_seconds_remaining": round(remaining),
                "watchdog_owned_workers": sorted(controller.owned),
                "workers": [
                    {"id": worker["id"], "paused": worker["paused"]}
                    for worker in workers
                ],
            }
            atomic_json(state_dir / "status.json", status)
            summary = (status["mode"], tuple(status["reasons"]), tuple(errors))
            now = time.monotonic()
            if summary != previous or now - last_report >= 60:
                log("[STATUS] " + json.dumps(status, sort_keys=True))
                previous, last_report = summary, now
            time.sleep(interval)


def cli():
    state_dir = Path(os.environ.get("STATE_DIR", "/state"))
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command in {"--hold", "--release"}:
        path = state_dir / "manual-hold"
        if command == "--hold":
            path.touch()
        else:
            path.unlink(missing_ok=True)
        print("Manual hold enabled" if command == "--hold" else "Manual hold released; quiet window still applies")
    elif command in {"--status", "--health"}:
        status = json.loads((state_dir / "status.json").read_text())
        if command == "--status":
            print(json.dumps(status, indent=2))
        else:
            if not 0 <= time.time() - status["updated_at"] <= 60 or status["errors"]:
                raise SystemExit(1)
    elif command:
        raise SystemExit("Use --status, --health, --hold or --release")
    else:
        run(state_dir)


if __name__ == "__main__":
    cli()
