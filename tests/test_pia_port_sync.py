import json
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "pia-port-sync.sh"
SOURCE = SCRIPT.read_text().split("<<'PYCODE'\n", 1)[1].split("\nPYCODE", 1)[0]


class PortSyncTests(unittest.TestCase):
    def run_sync(self, *, status=204, cookie="QBT_SID_8082", before=1234,
                 after=57599, write_status=200, port="57599", timeout=False):
        calls = []

        class RequestException(Exception):
            pass

        class Session:
            def __init__(self):
                self.cookies = [types.SimpleNamespace(name=cookie)] if cookie else []

            def __enter__(self):
                return self

            def __exit__(self, *args):
                pass

            def request(self, method, url, **kwargs):
                calls.append((method, url, kwargs))
                if timeout:
                    raise RequestException("sensitive network detail")
                if url.endswith("/auth/login"):
                    code, value = status, None
                elif url.endswith("/setPreferences"):
                    code, value = write_status, None
                else:
                    reads = sum(call[1].endswith("/app/preferences") for call in calls)
                    code, value = 200, {"listen_port": before if reads == 1 else after}
                return types.SimpleNamespace(status_code=code, json=lambda: value)

        requests = types.SimpleNamespace(Session=Session, RequestException=RequestException)
        exit_code = 0
        with patch.dict(sys.modules, {"requests": requests}), patch.dict(
                "os.environ", {"QBIT_HOST": "http://test:8082", "QBIT_USER": "test", "QBIT_PASS": "secret"}), \
                patch.object(sys, "argv", ["-", port]):
            try:
                exec(compile(SOURCE, str(SCRIPT), "exec"), {})
            except SystemExit as error:
                exit_code = error.code
        return exit_code, calls

    def test_legacy_and_current_logins_update_once_and_read_back(self):
        for status, cookie in [(200, "SID"), (204, "QBT_SID_8082")]:
            with self.subTest(status=status):
                code, calls = self.run_sync(status=status, cookie=cookie)
                self.assertEqual(code, 0)
                writes = [call for call in calls if call[1].endswith("/setPreferences")]
                self.assertEqual(len(writes), 1)
                self.assertEqual(json.loads(writes[0][2]["data"]["json"]), {"listen_port": 57599})
                self.assertEqual(len([call for call in calls if call[1].endswith("/app/preferences")]), 2)
                self.assertTrue(all(call[2]["timeout"] == (5, 10) and not call[2]["allow_redirects"] for call in calls))

    def test_already_matching_port_never_writes(self):
        code, calls = self.run_sync(before=57599)
        self.assertEqual(code, 0)
        self.assertFalse(any(call[1].endswith("/setPreferences") for call in calls))

    def test_failed_login_missing_cookie_and_timeout_never_write(self):
        for options in [{"status": 403}, {"cookie": None}, {"cookie": "unrelated"}, {"timeout": True}]:
            code, calls = self.run_sync(**options)
            self.assertEqual(code, 1)
            self.assertFalse(any(call[1].endswith("/setPreferences") for call in calls))

    def test_failed_write_or_mismatched_read_back_is_not_success(self):
        for options in [{"write_status": 403}, {"after": 1234}]:
            code, calls = self.run_sync(**options)
            self.assertEqual(code, 1)
            self.assertEqual(len([call for call in calls if call[1].endswith("/setPreferences")]), 1)

    def test_invalid_port_never_makes_request(self):
        for port in ["", "0", "65536", "-1", "80;bad", "123456"]:
            code, calls = self.run_sync(port=port)
            self.assertEqual(code, 1)
            self.assertEqual(calls, [])

    def test_shell_keeps_running_after_a_failed_sync(self):
        shell = SCRIPT.read_text().replace("sleep 10", ":").replace(
            'sleep "${SYNC_INTERVAL:-600}"', "echo LOOP_REACHED; exit 0")
        with tempfile.TemporaryDirectory(prefix="pia-sync-test-") as directory:
            python = Path(directory) / "python3"
            python.write_text('#!/bin/sh\nif [ "$1" = "-c" ]; then exit 0; fi\nexit 1\n')
            python.chmod(0o700)
            result = subprocess.run(["sh", "-s"], input=shell, text=True, capture_output=True,
                                    env={"PATH": directory + ":/usr/bin:/bin", "PIA_PORT_FILE": str(SCRIPT)}, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("LOOP_REACHED", result.stdout)
        self.assertIn("Sync was not verified", result.stdout)


if __name__ == "__main__":
    unittest.main()
