#!/usr/bin/env python3
"""Tests for mixpool retry-unmatched (no network)."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import mixpool


class RetryUnmatchedTests(unittest.TestCase):
    def test_catalogue_match_reported_dry_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            state_dir = root / "state"
            state_dir.mkdir()
            cat = {
                "schemaVersion": 1,
                "entries": [
                    {
                        "relativePath": "A/Al/song.m4a",
                        "sizeBytes": 10,
                        "sha256": "a" * 64,
                        "tags": {"artist": "J. Cole", "title": "No Role Modelz", "album": "X"},
                    }
                ],
            }
            cat_path = root / "catalogue.json"
            cat_path.write_text(json.dumps(cat), encoding="utf-8")
            liked = {
                "done": {},
                "no_match": {"J Cole|No Role Modelz": {"artist": "J Cole", "title": "No Role Modelz"}},
                "failed": {},
            }
            with mock.patch.object(mixpool, "LIKED_STATE", state_dir / "liked-pulled.json"):
                with mock.patch.object(mixpool, "STATE_DIR", state_dir):
                    (state_dir / "liked-pulled.json").write_text(json.dumps(liked), encoding="utf-8")
                    rc = mixpool.retry_unmatched(catalogue_path=cat_path)
            self.assertEqual(rc, 0)


if __name__ == "__main__":
    unittest.main()
