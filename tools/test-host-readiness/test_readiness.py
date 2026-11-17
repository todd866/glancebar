#!/usr/bin/env python3
import io
import subprocess
import unittest
from unittest import mock

from readiness import DEFER, check, focus_guard_bin, load_defer_reason, probe_focus_guard


class LoadTest(unittest.TestCase):
    @mock.patch("readiness.os.getloadavg", return_value=(2.0, 1.0, 0.5))
    @mock.patch("readiness.os.cpu_count", return_value=4)
    def test_load_below_cpus_permits(self, *_):
        self.assertIsNone(load_defer_reason())

    @mock.patch("readiness.os.getloadavg", return_value=(4.1, 3.0, 2.0))
    @mock.patch("readiness.os.cpu_count", return_value=4)
    def test_load_above_cpus_defers(self, *_):
        self.assertIn("exceeds 4 logical", load_defer_reason() or "")

    @mock.patch("readiness.focus_guard_bin", return_value=None)
    @mock.patch("readiness.load_defer_reason", return_value=None)
    def test_missing_focus_guard_ok(self, *_):
        self.assertEqual(check(stderr=io.StringIO()), 0)


class FocusGuardTest(unittest.TestCase):
    def test_probe_owner_active_defers(self):
        proc = subprocess.CompletedProcess(args=[], returncode=0, stdout="keyboard idle 12s", stderr="")
        with mock.patch("readiness.subprocess.run", return_value=proc):
            err = io.StringIO()
            self.assertEqual(probe_focus_guard("/bin/focus-guard", err), DEFER)
            self.assertIn("owner active", err.getvalue())

    def test_probe_owner_away_ok(self):
        proc = subprocess.CompletedProcess(args=[], returncode=1, stdout="", stderr="")
        with mock.patch("readiness.subprocess.run", return_value=proc):
            self.assertEqual(probe_focus_guard("/bin/focus-guard", io.StringIO()), 0)

    def test_probe_error_explicit(self):
        proc = subprocess.CompletedProcess(args=[], returncode=3, stdout="", stderr="broken")
        with mock.patch("readiness.subprocess.run", return_value=proc):
            err = io.StringIO()
            self.assertEqual(probe_focus_guard("/bin/focus-guard", err), 2)
            self.assertIn("probe error", err.getvalue())


class CheckIntegration(unittest.TestCase):
    @mock.patch("readiness.probe_focus_guard", return_value=0)
    @mock.patch("readiness.focus_guard_bin", return_value="/bin/fg")
    @mock.patch("readiness.load_defer_reason", return_value="busy")
    def test_load_checked_before_focus_guard(self, *_):
        err = io.StringIO()
        self.assertEqual(check(stderr=err), DEFER)
        self.assertIn("busy", err.getvalue())

    @mock.patch("readiness.os.getloadavg", side_effect=OSError("unavailable"))
    def test_load_probe_failure_is_not_green(self, _):
        err = io.StringIO()
        self.assertEqual(check(stderr=err), 2)
        self.assertIn("cannot read system load", err.getvalue())

    @mock.patch("readiness.os.getloadavg", return_value=(float("nan"), 0, 0))
    def test_invalid_load_is_not_green(self, _):
        self.assertEqual(check(stderr=io.StringIO()), 2)

    def test_unexpected_focus_guard_75_is_error_not_deferral(self):
        proc = subprocess.CompletedProcess(args=[], returncode=75, stdout="", stderr="probe unavailable")
        with mock.patch("readiness.subprocess.run", return_value=proc):
            self.assertEqual(probe_focus_guard("/bin/focus-guard", io.StringIO()), 2)

    @mock.patch("readiness.os.path.isfile", return_value=False)
    @mock.patch("readiness.shutil.which", return_value=None)
    def test_focus_guard_absent(self, *_):
        self.assertIsNone(focus_guard_bin())


if __name__ == "__main__":
    unittest.main()