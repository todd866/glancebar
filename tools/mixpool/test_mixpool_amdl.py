#!/usr/bin/env python3
"""Tests for mixpool amdl helpers. No network, no real amdl."""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import mixpool


class RunAmdlDetailedTests(unittest.TestCase):
    def test_snapshots_new_audio_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "Apple Music"
            root.mkdir()
            (root / "Artist" / "Al").mkdir(parents=True)
            existing = root / "Artist" / "Al" / "old.m4a"
            existing.write_bytes(b"old" * 100)

            def fake_run(url: str) -> tuple[bool, bool, str]:
                self.assertEqual(url, "https://example.test/song")
                (root / "Artist" / "Al" / "new.m4a").write_bytes(b"NEW" * 200)
                return True, False, ""

            ok, infra, err, detail = mixpool.run_amdl_detailed(
                "https://example.test/song", music_root=root, run=fake_run
            )
            self.assertTrue(ok)
            self.assertFalse(infra)
            self.assertEqual(err, "")
            self.assertEqual(len(detail["files"]), 1)
            self.assertEqual(detail["files"][0]["relative_path"], "Artist/Al/new.m4a")
            self.assertEqual(detail["files"][0]["size_bytes"], 600)
            self.assertEqual(detail["size_bytes"], 600)
            self.assertEqual(len(detail["files"][0]["sha256"]), 64)

    def test_failure_skips_snapshot_diff(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "Apple Music"
            root.mkdir()

            def fake_run(url: str) -> tuple[bool, bool, str]:
                return False, False, "not found"

            ok, infra, err, detail = mixpool.run_amdl_detailed(
                "https://example.test/song", music_root=root, run=fake_run
            )
            self.assertFalse(ok)
            self.assertNotIn("files", detail)


if __name__ == "__main__":
    unittest.main()
