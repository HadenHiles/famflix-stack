# Unmanic I/O watchdog

The watchdog yields background conversion to Plex transcodes, Sonarr/Radarr
imports and file scans/renames, SAB unpack/repair/move work, and sustained NAS
I/O pressure. It uses Unmanic's native per-worker pause/resume API, not raw PID
signals. It needs no Docker socket, third-party Python packages or startup
package installation.

## Policy

- Check every 5 seconds (plus bounded HTTP request time).
- Pause immediately for active imports, file operations, SAB postprocessing
  or Plex audio/video transcodes. Arr queue entries must be `importing`;
  merely queued, pending, blocked or failed downloads do not block.
  Routine RSS/download-monitor commands and Plex direct play/stream do not block.
- Pause when host `/proc/pressure/io` **full avg10 >= 35% for 15 seconds**.
  This is stalled-task time, not disk utilization.
- After an I/O-triggered pause, require **full avg10 <= 10%** throughout the
  quiet window. After any competing work, require **120 continuous seconds**
  without blockers before resuming.
- Missing/malformed telemetry fails closed: pause available workers, retain
  existing pauses, reset the quiet window and mark the container unhealthy.
  Recovery still requires the quiet window; failures are logged explicitly.
- Only resume workers paused by this watchdog. Ownership is journaled and
  fsynced before requesting pause, survives watchdog/container recreation,
  and is discarded if the worker's task/start identity changes. Changed or
  pre-existing manual pauses are left untouched. After restart, owned pauses
  conservatively require the low-I/O quiet window again.

Unmanic cannot distinguish a second manual pause applied while an already
watchdog-paused worker is paused. **Use the persistent manual hold below for
that case**, not just the dashboard Pause button. Manual resume during an
active blocker is overridden on the next check. A hold also survives restarts.

Worker pause suspends active worker subprocesses and prevents new worker jobs;
it is not a whole-container freeze. Scanning, postprocessing/final copies and
other applications may continue producing I/O. This does not change recipes,
notifiers, media mounts, download behavior or delete files.

## Status and manual control

```sh
docker exec unmanic-watchdog python /scripts/unmanic_watchdog.py --status
docker logs --since 10m --tail 50 unmanic-watchdog
docker inspect unmanic-watchdog --format '{{.State.Health.Status}}'

# Keep conversion paused until explicitly released:
docker exec unmanic-watchdog python /scripts/unmanic_watchdog.py --hold
docker exec unmanic-watchdog python /scripts/unmanic_watchdog.py --release
```

Status includes pause reasons, errors, pressure, quiet-window countdown,
worker pause flags and ownership IDs, but no titles, paths, commands or keys.
Logs record transitions and at least one heartbeat per minute. Health checks
reject telemetry errors or a status snapshot older than 60 seconds.
This does not send a separate Discord notification; the bot can inspect status
and logs through its existing approval-gated NAS shell.

Settings live in the Compose service: `CHECK_INTERVAL`, `IO_HIGH`, `IO_LOW`,
`IO_SUSTAINED`, `QUIET_SECONDS`, and internal app URLs.
API keys are read from read-only application config-file mounts and Tautulli's
existing environment setting. Recreate the watchdog after API-key rotation or
configuration-file replacement. State is under `unmanic-watchdog-state` in the
stack directory; do not delete ownership while workers are watchdog-paused.

## Validation and deployment

```sh
docker run --rm -e PYTHONDONTWRITEBYTECODE=1 \
  -v "$PWD/scripts:/scripts:ro" -w /scripts \
  python:3.11-alpine python -m unittest -v test_unmanic_watchdog
docker compose config --quiet
docker compose up -d --no-deps unmanic-watchdog
```

Before replacing the old signal-based watchdog, ensure no ffmpeg process was
left SIGSTOPed by it. Test pause/resume and monitoring recovery against native
worker flags after deployment. Retain the prior script and Compose definition
for rollback. Before disabling or reverting the new watchdog, stop it and
explicitly release only its recorded worker pauses through the native API;
do not blindly resume all workers or discard its ownership journal.
