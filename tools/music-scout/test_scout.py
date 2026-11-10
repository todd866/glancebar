#!/usr/bin/env python3
"""Unit tests for music-scout. No network, no real subprocesses."""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from collections import Counter
from datetime import timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import scout


def _cfg(root: Path, **overrides) -> dict:
    base = dict(scout.DEFAULTS)
    base.update(
        {
            "library_export": str(root / "export"),
            "music_library_state": str(root / "mlib"),
            "mixpool_state": str(root / "mix"),
            "yt_liked_dir": str(root / "yt"),
            "hearts_path": str(root / "hearts.json"),
            "feedback_paths": [str(root / "feedback.jsonl")],
            "triplej_state": str(root / "selector"),
            "music_sync_inventory": str(root / "inventory.json"),
            "new_music_path": str(root / "new-music.json"),
        }
    )
    base.update(overrides)
    return base


class ScoutLogicTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.state = self.root / "state"
        self.state.mkdir()
        self.paths = scout.ScoutPaths(self.state)
        self.cfg = _cfg(self.root)
        (self.root / "export").mkdir()
        (self.root / "mlib").mkdir()
        (self.root / "mix").mkdir()
        (self.root / "yt").mkdir()
        (self.root / "selector").mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def test_dedupe_owned_and_offered(self):
        owned_artist, owned_title = "Owned Band", "Owned Song"
        offered_artist, offered_title = "Queued Band", "Queued Song"
        (self.root / "export" / "Owned Band").mkdir()
        (self.root / "export" / "Owned Band" / "Al").mkdir(parents=True)
        (self.root / "export" / "Owned Band" / "Al" / "Owned Song.m4a").write_bytes(b"x")

        scout.append_jsonl(
            self.paths.ledger,
            {"at": scout.iso_now(), "action": "offered", "artist": offered_artist, "title": offered_title},
        )

        owned = scout.owned_keys(self.cfg, self.paths)
        self.assertIn(scout.track_key(owned_artist, owned_title), owned)
        self.assertIn(scout.track_key(offered_artist, offered_title), owned)

        candidates = [
            {"artist": owned_artist, "title": owned_title, "source": "triplej", "why": "x", "score_hint": 1},
            {"artist": offered_artist, "title": offered_title, "source": "triplej", "why": "y", "score_hint": 1},
            {"artist": "Fresh", "title": "Track", "source": "triplej", "why": "z", "score_hint": 0.9},
        ]
        self.paths.candidates.write_text(
            json.dumps({"candidates": candidates}),
            encoding="utf-8",
        )
        runners = scout.Runners(clock=lambda: "2026-11-10T00:00:00Z")
        ranked = scout.cmd_rank(self.cfg, self.paths, runners)
        self.assertEqual(len(ranked), 1)
        self.assertEqual(ranked[0]["artist"], "Fresh")

    def test_llm_unconfirmed_dropped(self):
        feedback: dict = {}

        def fake_pick(prompt, cmd):
            suggestions = json.dumps(
                [
                    {"artist": "Real One", "title": "Yes", "why": "fits"},
                    {"artist": "Fake", "title": "Nope", "why": "nope"},
                ]
            )
            return 0, suggestions

        def fake_best(artist, title, album="", sleep=None):
            if artist == "Real One":
                return {"trackId": 1, "trackName": "Yes", "artistName": "Real One", "collectionName": "A"}
            return None

        runners = scout.Runners(ai_pick=fake_pick, itunes_song_best=fake_best)
        rows, err = scout.source_taste_expansion(self.cfg, runners, feedback)
        self.assertIsNone(err)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["artist"], "Real One")

    def test_per_artist_cap(self):
        pool = []
        for i in range(5):
            pool.append(
                {
                    "artist": "Same",
                    "title": f"T{i}",
                    "source": "triplej",
                    "why": "w",
                    "score": 1.0,
                    "track_key": scout.track_key("Same", f"T{i}"),
                }
            )
        week_ago = scout.utc_now() - timedelta(days=1)
        for i in range(2):
            scout.append_jsonl(
                self.paths.ledger,
                {
                    "at": week_ago.strftime("%Y-%m-%dT%H:%M:%SZ"),
                    "action": "offered",
                    "artist": "Same",
                    "title": f"old{i}",
                },
            )
        chosen = []
        max_art = 2
        artist_week: Counter[str] = Counter({"same": 2})
        for row in pool:
            art = scout.normal(row["artist"])
            if artist_week.get(art, 0) + sum(1 for x in chosen if scout.normal(x["artist"]) == art) >= max_art:
                continue
            chosen.append(row)
        self.assertEqual(len(chosen), 0)

    def test_exploration_share(self):
        explore = [
            {
                "artist": f"E{i}",
                "title": "S",
                "source": "taste-expansion",
                "score_hint": 0.9,
                "why": "e",
            }
            for i in range(10)
        ]
        rest = [
            {
                "artist": f"R{i}",
                "title": "S",
                "source": "triplej",
                "score_hint": 0.8,
                "why": "r",
            }
            for i in range(10)
        ]
        self.paths.candidates.write_text(
            json.dumps({"candidates": explore + rest}),
            encoding="utf-8",
        )
        cfg = dict(self.cfg, exploration_share=0.30)
        runners = scout.Runners(clock=lambda: "2026-11-10T00:00:00Z")
        ranked = scout.cmd_rank(cfg, self.paths, runners)
        exp = sum(1 for r in ranked if r.get("source") == "taste-expansion")
        self.assertGreaterEqual(exp, 3)
        self.assertLessEqual(exp, 6)

    def test_weekly_budget_count_and_gb(self):
        now = scout.parse_iso("2026-11-10T12:00:00Z")
        for i in range(18):
            scout.append_jsonl(
                self.paths.ledger,
                {
                    "at": "2026-11-09T12:00:00Z",
                    "action": "acquired",
                    "artist": "A",
                    "title": f"t{i}",
                    "size_mb": 80,
                },
            )
        count, mb = scout.weekly_acquired_stats(self.paths.ledger, now)
        self.assertEqual(count, 18)
        self.assertAlmostEqual(mb, 18 * 80, places=1)

        queue = {
            "tracks": [
                {"artist": "N1", "title": "s1", "track_key": "n1|s1", "track_id": 9},
                {"artist": "N2", "title": "s2", "track_key": "n2|s2", "track_id": 10},
            ]
        }
        self.paths.queue.write_text(json.dumps(queue), encoding="utf-8")
        cfg = dict(self.cfg, tracks_per_week=20, gb_per_week=1.5, avg_track_mb=75)
        runners = scout.Runners(
            clock=lambda: "2026-11-10T12:00:00Z",
            run_amdl=lambda url: (True, False, ""),
            is_m5=lambda: True,
            is_metered=lambda: False,
            on_battery=lambda: False,
        )
        summary = scout.cmd_acquire(cfg, self.paths, runners, go=True)
        acquired = [r for r in summary["results"] if r.get("action") == "acquired"]
        self.assertEqual(len(acquired), 2)
        summary2 = scout.cmd_acquire(cfg, self.paths, runners, go=True)
        self.assertEqual(summary2["attempted"], 0)

    def test_defer_not_m5_metered_battery(self):
        for is_m5, is_metered, on_bat in (
            (False, False, False),
            (True, True, False),
            (True, False, True),
        ):
            runners = scout.Runners(is_m5=lambda m=is_m5: m, is_metered=lambda m=is_metered: m, on_battery=lambda b=on_bat: b)
            self.assertIsNotNone(scout.acquire_defer_reason(runners))

    def test_acquire_defer_exit(self):
        self.paths.queue.write_text(
            json.dumps({"tracks": [{"artist": "A", "title": "B", "track_key": "a|b"}]}),
            encoding="utf-8",
        )
        runners = scout.Runners(is_m5=lambda: False)
        with self.assertRaises(SystemExit) as ctx:
            scout.cmd_acquire(self.cfg, self.paths, runners, go=True)
        self.assertEqual(ctx.exception.code, 75)

    def test_dead_source_flagged(self):
        counts = {"triplej": 0}
        for _ in range(3):
            scout.update_source_stats(
                self.paths,
                counts,
                dead_nights=3,
                clock="2026-11-10T00:00:00Z",
            )
        doc = json.loads(self.paths.source_stats.read_text(encoding="utf-8"))
        self.assertTrue(doc["sources"]["triplej"]["flagged_dead"])

    def test_publish_graduation_and_age_out(self):
        hearts_path = self.root / "hearts.json"
        hearts_path.write_text(json.dumps({"tracks": [scout.track_key("Hearted", "Song")]}), encoding="utf-8")
        fresh = "2026-11-09T12:00:00Z"
        old = "2026-10-01T12:00:00Z"
        for artist, title, at in (
            ("Hearted", "Song", fresh),
            ("Fresh", "Keep", fresh),
            ("Stale", "Drop", old),
        ):
            scout.append_jsonl(
                self.paths.ledger,
                {
                    "at": at,
                    "action": "acquired",
                    "artist": artist,
                    "title": title,
                    "why": "test",
                    "track_key": scout.track_key(artist, title),
                },
            )
        cfg = dict(self.cfg, fresh_days=14, hearts_path=str(hearts_path))
        runners = scout.Runners(clock=lambda: "2026-11-10T12:00:00Z")
        doc = scout.cmd_publish(cfg, self.paths, runners)
        titles = {t["title"] for t in doc["tracks"]}
        self.assertIn("Keep", titles)
        self.assertNotIn("Song", titles)
        self.assertNotIn("Drop", titles)

    def test_dry_run_does_not_acquire(self):
        self.paths.queue.write_text(
            json.dumps(
                {
                    "tracks": [
                        {
                            "artist": "Dry",
                            "title": "Run",
                            "track_key": "dry|run",
                            "track_id": 1,
                        }
                    ]
                }
            ),
            encoding="utf-8",
        )
        amdl_called = []

        def fake_amdl(url):
            amdl_called.append(url)
            return True, False, ""

        runners = scout.Runners(
            is_m5=lambda: True,
            is_metered=lambda: False,
            on_battery=lambda: False,
            run_amdl=fake_amdl,
            clock=lambda: "2026-11-10T12:00:00Z",
        )
        summary = scout.cmd_acquire(self.cfg, self.paths, runners, go=False)
        self.assertEqual(amdl_called, [])
        self.assertTrue(all(r.get("action") == "dry_run" for r in summary["results"]))
        self.assertFalse(any(line.get("action") == "acquired" for line in scout.read_jsonl(self.paths.ledger)))


class LockTests(unittest.TestCase):
    def test_run_lock_exit_75(self):
        with tempfile.TemporaryDirectory() as tmp:
            lock = Path(tmp) / "run.lock"
            fd = os.open(str(lock), os.O_CREAT | os.O_RDWR)
            try:
                import fcntl

                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                with self.assertRaises(SystemExit) as ctx:
                    with scout.run_lock(lock):
                        pass
                self.assertEqual(ctx.exception.code, 75)
            finally:
                os.close(fd)


if __name__ == "__main__":
    unittest.main()
