import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import unmanic_watchdog as watchdog


def worker(paused=False, task=123, start="100"):
    return {"id": "W0", "paused": paused, "current_task": task, "start_time": start}


class PolicyTests(unittest.TestCase):
    def test_pressure_requires_sustained_threshold_then_continuous_low_window(self):
        policy = watchdog.Policy()
        self.assertEqual(policy.decide(0, 50, [])[0], [])
        self.assertEqual(policy.decide(14, 50, [])[0], [])
        self.assertTrue(policy.decide(15, 50, [])[0])
        self.assertFalse(policy.decide(20, 5, [])[1])
        self.assertTrue(policy.decide(100, 20, [])[0])
        self.assertFalse(policy.decide(110, 5, [])[1])
        self.assertFalse(policy.decide(229, 5, [])[1])
        self.assertTrue(policy.decide(230, 5, [])[1])

    def test_brief_spike_does_not_pause(self):
        policy = watchdog.Policy()
        policy.decide(0, 50, [])
        policy.decide(10, 5, [])
        self.assertFalse(policy.decide(20, 50, [])[0])

    def test_competing_work_and_failures_reset_quiet_period(self):
        policy = watchdog.Policy()
        self.assertFalse(policy.decide(0, 0, [])[1])
        self.assertTrue(policy.decide(120, 0, [])[1])
        self.assertFalse(policy.decide(121, 0, ["Sonarr import"])[1])
        self.assertFalse(policy.decide(122, None, ["Monitor unavailable"])[1])
        self.assertFalse(policy.decide(123, 0, [])[1])
        self.assertTrue(policy.decide(243, 0, [])[1])

    def test_invalid_thresholds(self):
        for kwargs in ({"low": 40}, {"high": float("nan")}, {"quiet": 0}):
            with self.assertRaises(ValueError):
                watchdog.Policy(**kwargs)


class TelemetryTests(unittest.TestCase):
    def test_only_running_io_commands_block(self):
        commands = [
            {"name": "RenameFiles", "status": "queued"},
            {"name": "RssSync", "status": "started"},
            {"name": "ProcessMonitoredDownloads", "status": "started"},
            {"name": "RescanSeries", "status": "completed"},
        ]
        self.assertEqual(watchdog.arr_reasons("sonarr", commands), [])
        commands.append({"name": "DownloadedEpisodesScan", "status": "started"})
        self.assertEqual(watchdog.arr_reasons("sonarr", commands),
                         ["sonarr: DownloadedEpisodesScan"])

    def test_only_importing_queue_records_block(self):
        queue = {"records": [
            {"trackedDownloadState": "downloading"},
            {"trackedDownloadState": "importPending"},
            {"trackedDownloadState": "importBlocked"},
        ]}
        self.assertEqual(watchdog.arr_queue_reasons("sonarr", queue), [])
        queue["records"].append({"trackedDownloadState": "importing"})
        self.assertEqual(watchdog.arr_queue_reasons("sonarr", queue), ["sonarr: active import"])

    def test_direct_play_and_copy_are_not_transcodes(self):
        def response(session):
            return {"response": {"result": "success", "data": {"sessions": [session]}}}
        self.assertEqual(watchdog.plex_reasons(response({
            "transcode_decision": "direct play", "stream_video_decision": "copy",
        })), [])
        self.assertTrue(watchdog.plex_reasons(response({
            "transcode_decision": "copy", "stream_audio_decision": "transcode",
        })))

    def test_sab_history_postprocessing_blocks_but_download_queue_does_not(self):
        queue = {"queue": {"status": "Downloading", "slots": [{"status": "Downloading"}]}}
        history = {"history": {"slots": [{"status": "Completed"}]}}
        self.assertEqual(watchdog.sab_reasons(queue, history), [])
        for status in ("Extracting", "Repairing", "Verifying", "Moving", "Running"):
            history["history"]["slots"] = [{"status": status}]
            self.assertTrue(watchdog.sab_reasons(queue, history))

    def test_invalid_telemetry_is_not_empty_success(self):
        with self.assertRaises(ValueError):
            watchdog.arr_reasons("sonarr", {})
        with self.assertRaises(ValueError):
            watchdog.plex_reasons({"response": {"result": "error"}})
        with self.assertRaises(KeyError):
            watchdog.sab_reasons({"error": "unauthorized"}, {})

    def test_io_pressure_validates_shape_and_range(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "io"
            path.write_text("some avg10=99\nfull avg10=35.25 avg60=20 total=1\n")
            self.assertEqual(watchdog.io_pressure(path), 35.25)
            for text in ("some avg10=4\n", "full avg10=nan\n", "full avg10=101\n"):
                path.write_text(text)
                with self.assertRaises(ValueError):
                    watchdog.io_pressure(path)


class OwnershipTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.actions = []
        self.controller = watchdog.Controller(self.directory, self.action)

    def action(self, action, worker_id):
        self.actions.append((action, worker_id))

    def test_manual_pause_never_resumed(self):
        self.controller.reconcile([worker(True)], True, False)
        self.controller.reconcile([worker(True)], False, True)
        self.assertEqual(self.actions, [])

    def test_pause_survives_restart_and_resumes_only_owned_worker(self):
        self.controller.reconcile([worker()], True, False)
        restored = watchdog.Controller(self.directory, self.action)
        restored.reconcile([worker(True)], False, True)
        self.assertEqual(self.actions, [("pause", "W0"), ("resume", "W0")])
        self.assertEqual(json.loads(restored.path.read_text()), {})

    def test_changed_worker_is_not_resumed(self):
        self.controller.reconcile([worker()], True, False)
        self.controller.reconcile([worker(True, start="200")], False, True)
        self.assertEqual(self.actions, [("pause", "W0")])
        self.assertEqual(self.controller.owned, {})

    def test_new_workers_pause_while_blocked(self):
        self.controller.reconcile([worker()], True, False)
        second = {**worker(), "id": "W1"}
        self.controller.reconcile([worker(True), second], True, False)
        self.assertEqual(self.actions, [("pause", "W0"), ("pause", "W1")])

    def test_failed_action_retains_journal_and_retries(self):
        def fail(action, worker_id):
            self.assertIn(worker_id, json.loads(self.controller.path.read_text()))
            raise RuntimeError("failed action")
        self.controller.action = fail
        with self.assertRaises(RuntimeError):
            self.controller.reconcile([worker()], True, False)
        self.controller.action = self.action
        self.controller.reconcile([worker(True)], False, True)
        self.assertEqual(self.actions, [("resume", "W0")])

    def test_failed_resume_retains_ownership(self):
        self.controller.reconcile([worker()], True, False)
        def fail(action, worker_id):
            raise RuntimeError("resume failed")
        self.controller.action = fail
        with self.assertRaises(RuntimeError):
            self.controller.reconcile([worker(True)], False, True)
        self.assertIn("W0", json.loads(self.controller.path.read_text()))

    def test_corrupt_journal_refuses_to_reset(self):
        self.controller.path.write_text("[]")
        with self.assertRaises(ValueError):
            watchdog.Controller(self.directory, self.action)


class ActionTests(unittest.TestCase):
    def test_api_success_without_pause_change_is_failure(self):
        monitor = watchdog.Monitor.__new__(watchdog.Monitor)
        monitor.unmanic = "http://unmanic:8888"
        with patch.object(watchdog, "request_json", side_effect=[
            {"success": True}, {"workers_status": [worker(False)]},
        ]):
            with self.assertRaises(RuntimeError):
                monitor.action("pause", "W0")

    def test_fresh_status_confirms_resume(self):
        monitor = watchdog.Monitor.__new__(watchdog.Monitor)
        monitor.unmanic = "http://unmanic:8888"
        with patch.object(watchdog, "request_json", side_effect=[
            {"success": True}, {"workers_status": [worker(False)]},
        ]):
            monitor.action("resume", "W0")


class LoopTests(unittest.TestCase):
    def test_monitor_failure_pauses_then_recovers_only_after_full_quiet_window(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            clock = [0]
            active_worker = worker()
            snapshots = []
            monitor = unittest.mock.Mock()
            monitor.arr_activity.return_value = []
            monitor.plex_activity.return_value = []
            monitor.sab_activity.side_effect = [TimeoutError("secret URL"), [], [], []]
            monitor.workers.side_effect = lambda: [active_worker.copy()]
            def action(operation, worker_id):
                active_worker["paused"] = operation == "pause"
            monitor.action.side_effect = action
            times = iter([5, 124, 125])
            def sleep(interval):
                snapshots.append(json.loads((state / "status.json").read_text()))
                clock[0] = next(times)
            with patch.object(watchdog, "Monitor", return_value=monitor), \
                    patch.object(watchdog, "io_pressure", return_value=5), \
                    patch.object(watchdog.time, "monotonic", side_effect=lambda: clock[0]), \
                    patch.object(watchdog.time, "sleep", side_effect=sleep):
                with self.assertRaises(StopIteration):
                    watchdog.run(state)
            self.assertEqual([item["mode"] for item in snapshots],
                             ["monitor-error", "quiet-wait", "quiet-wait", "available"])
            self.assertEqual([item["workers"][0]["paused"] for item in snapshots],
                             [True, True, True, False])
            self.assertEqual(snapshots[0]["errors"], ["sab: TimeoutError"])
            self.assertNotIn("secret URL", json.dumps(snapshots))

    def test_manual_hold_pauses_and_is_visible(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            (state / "manual-hold").touch()
            monitor = unittest.mock.Mock()
            monitor.arr_activity.return_value = []
            monitor.plex_activity.return_value = []
            monitor.sab_activity.return_value = []
            monitor.workers.side_effect = [[worker()], [worker(True)]]
            with patch.object(watchdog, "Monitor", return_value=monitor), \
                    patch.object(watchdog, "io_pressure", return_value=5), \
                    patch.object(watchdog.time, "sleep", side_effect=StopIteration):
                with self.assertRaises(StopIteration):
                    watchdog.run(state)
            snapshot = json.loads((state / "status.json").read_text())
            self.assertIn("Operator: manual hold", snapshot["reasons"])
            self.assertEqual(snapshot["watchdog_owned_workers"], ["W0"])


class HealthTests(unittest.TestCase):
    def test_stale_status_and_monitor_errors_fail_health(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            with patch.dict(watchdog.os.environ, {"STATE_DIR": directory}), \
                    patch.object(watchdog.sys, "argv", ["watchdog", "--health"]), \
                    patch.object(watchdog.time, "time", return_value=100):
                for value in (
                    {"updated_at": 39, "errors": []},
                    {"updated_at": 100, "errors": ["sonarr: TimeoutError"]},
                ):
                    watchdog.atomic_json(state / "status.json", value)
                    with self.assertRaises(SystemExit):
                        watchdog.cli()
                watchdog.atomic_json(state / "status.json", {"updated_at": 100, "errors": []})
                watchdog.cli()

    def test_manual_hold_cli_is_persistent_and_release_is_idempotent(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            with patch.dict(watchdog.os.environ, {"STATE_DIR": directory}):
                with patch.object(watchdog.sys, "argv", ["watchdog", "--hold"]):
                    watchdog.cli()
                    self.assertTrue((state / "manual-hold").exists())
                with patch.object(watchdog.sys, "argv", ["watchdog", "--release"]):
                    watchdog.cli()
                    watchdog.cli()
                    self.assertFalse((state / "manual-hold").exists())


if __name__ == "__main__":
    unittest.main()
