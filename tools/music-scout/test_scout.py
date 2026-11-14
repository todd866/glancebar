#!/usr/bin/env python3
"""Unit tests for music-scout. No network, no real subprocesses."""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from collections import Counter
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import scout


def _media_signals(share: Path, host: str, tracks: dict) -> None:
    share.mkdir(parents=True, exist_ok=True)
    (share / f"signals-{host}.json").write_text(
        json.dumps(
            {
                "version": 1,
                "host": host,
                "generated": "2026-11-14T10:00:00Z",
                "sources": {},
                "tracks": tracks,
            }
        ),
        encoding="utf-8",
    )


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


class MediaShareTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.share = self.root / "media"
        self.state = self.root / "state"
        self.state.mkdir()
        self.paths = scout.ScoutPaths(self.state)
        self.cfg = _cfg(self.root, media_share=str(self.share), playback_log=str(self.root / "playback.jsonl"))

    def tearDown(self):
        self.tmp.cleanup()

    def test_load_universe_merge_and_broken_file(self):
        key = scout.track_key("Merge Act", "Alpha Song")
        _media_signals(
            self.share,
            "m5",
            {
                key: {
                    "artist": "Merge Act",
                    "title": "Alpha Song",
                    "ids": {"apple_music": "111", "isrc": "", "youtube": ""},
                    "signals": [{"kind": "shazam", "source": "shazam", "at": "2026-11-14T09:00:00Z"}],
                    "owned": False,
                }
            },
        )
        _media_signals(
            self.share,
            "m2",
            {
                key: {
                    "artist": "Merge Act",
                    "title": "Alpha Song",
                    "ids": {"apple_music": "", "isrc": "AU123", "youtube": ""},
                    "signals": [{"kind": "like", "source": "glancebar", "at": "2026-11-13T09:00:00Z"}],
                    "owned": True,
                }
            },
        )
        (self.share / "signals-broken.json").write_text("{ not json", encoding="utf-8")
        merged, errors = scout.load_universe(self.share)
        self.assertEqual(len(errors), 1)
        self.assertIn("broken", errors[0])
        self.assertTrue(merged[key]["owned"])
        self.assertEqual(merged[key]["ids"]["apple_music"], "111")
        self.assertEqual(merged[key]["ids"]["isrc"], "AU123")
        self.assertEqual(len(merged[key]["signals"]), 2)

    def test_fresh_shazam_priority_and_url(self):
        key = scout.track_key("Shazam Act", "Fresh Tune")
        _media_signals(
            self.share,
            "m5",
            {
                key: {
                    "artist": "Shazam Act",
                    "title": "Fresh Tune",
                    "ids": {"apple_music": "424242", "isrc": "", "youtube": ""},
                    "signals": [{"kind": "shazam", "source": "shazam", "at": "2026-11-14T10:05:00Z"}],
                    "owned": False,
                }
            },
        )
        runners = scout.Runners(clock=lambda: "2026-11-14T12:00:00Z")
        rows = scout.source_shazam(self.cfg, runners, set())
        self.assertEqual(len(rows), 1)
        self.assertTrue(rows[0]["priority"])
        self.assertEqual(rows[0]["why"], "Shazamed 14 Nov")
        self.assertEqual(rows[0]["track_id"], 424242)
        self.assertEqual(rows[0]["url"], "https://music.apple.com/au/song/424242")

    def test_shazam_earlier_year_in_why(self):
        key = scout.track_key("Old Shazam", "Past Hit")
        _media_signals(
            self.share,
            "m5",
            {
                key: {
                    "artist": "Old Shazam",
                    "title": "Past Hit",
                    "signals": [{"kind": "shazam", "source": "shazam", "at": "2024-03-03T10:00:00Z"}],
                    "owned": False,
                }
            },
        )
        runners = scout.Runners(clock=lambda: "2026-11-14T12:00:00Z")
        rows = scout.source_shazam(self.cfg, runners, set())
        self.assertEqual(rows[0]["why"], "Shazamed 3 Mar 2024")
        self.assertNotIn("priority", rows[0])

    def test_shazam_backlog_cap_newest_first(self):
        tracks = {}
        for i, day in enumerate((5, 1, 3, 2, 4)):
            key = scout.track_key("Backlog Band", f"Song {i}")
            tracks[key] = {
                "artist": "Backlog Band",
                "title": f"Song {i}",
                "signals": [{"kind": "shazam", "source": "shazam", "at": f"2026-10-{day:02d}T10:00:00Z"}],
                "owned": False,
            }
        _media_signals(self.share, "m5", tracks)
        cfg = dict(self.cfg, shazam_backlog_per_run=2)
        runners = scout.Runners(clock=lambda: "2026-11-14T12:00:00Z")
        rows = scout.source_shazam(cfg, runners, set())
        titles = [r["title"] for r in rows]
        self.assertEqual(titles, ["Song 0", "Song 4"])

    def test_shazam_skips_owned_and_disliked(self):
        owned_k = scout.track_key("Skip Band", "Owned One")
        hate_k = scout.track_key("Skip Band", "Hated One")
        _media_signals(
            self.share,
            "m5",
            {
                owned_k: {
                    "artist": "Skip Band",
                    "title": "Owned One",
                    "owned": True,
                    "signals": [{"kind": "shazam", "source": "shazam", "at": "2026-11-14T10:00:00Z"}],
                },
                hate_k: {
                    "artist": "Skip Band",
                    "title": "Hated One",
                    "owned": False,
                    "signals": [
                        {"kind": "shazam", "source": "shazam", "at": "2026-11-14T10:00:00Z"},
                        {"kind": "dislike", "source": "glancebar", "at": "2026-11-14T11:00:00Z"},
                    ],
                },
            },
        )
        rows = scout.source_shazam(self.cfg, scout.Runners(clock=lambda: "2026-11-14T12:00:00Z"), set())
        self.assertEqual(rows, [])

    def test_tv_like_candidate(self):
        key = scout.track_key("Tv Act", "Living Room")
        _media_signals(
            self.share,
            "m5",
            {
                key: {
                    "artist": "Tv Act",
                    "title": "Living Room",
                    "ids": {"apple_music": "999", "isrc": "", "youtube": ""},
                    "signals": [{"kind": "like", "source": "tv", "at": "2026-11-12T18:00:00Z", "audience": "x"}],
                    "owned": False,
                }
            },
        )
        rows = scout.source_tv_likes(self.cfg, scout.Runners(clock=lambda: "2026-11-14T12:00:00Z"), set())
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["why"], "Liked on the TV 13 Nov")
        self.assertTrue(rows[0]["priority"])

    def test_priority_beats_higher_scored_and_artist_cap(self):
        for i in range(3):
            scout.append_jsonl(
                self.paths.ledger,
                {
                    "at": "2026-11-13T12:00:00Z",
                    "action": "offered",
                    "artist": "Cap Artist",
                    "title": f"Old {i}",
                },
            )
        candidates = [
            {
                "artist": "Cap Artist",
                "title": "Shazam Pick",
                "source": "shazam",
                "why": "Shazamed",
                "score_hint": 0.5,
                "priority": True,
            },
            {
                "artist": "Cap Artist",
                "title": "Radio Pick",
                "source": "triplej",
                "why": "pick",
                "score_hint": 1.0,
            },
        ]
        self.paths.candidates.write_text(json.dumps({"candidates": candidates}), encoding="utf-8")
        ranked = scout.cmd_rank(self.cfg, self.paths, scout.Runners(clock=lambda: "2026-11-14T12:00:00Z"))
        self.assertEqual(ranked[0]["title"], "Shazam Pick")

    def test_rejected_dislike_feedback_and_ledger(self):
        key = scout.track_key("Reject Band", "Angry Song")
        _media_signals(
            self.share,
            "m5",
            {
                key: {
                    "artist": "Reject Band",
                    "title": "Angry Song",
                    "signals": [{"kind": "dislike", "source": "glancebar", "at": "2026-11-14T10:00:00Z"}],
                }
            },
        )
        self.assertIn(key, scout.rejected_keys(self.cfg, self.paths))
        fb = self.root / "feedback.jsonl"
        fb.write_text(
            json.dumps(
                {"artist": "Feedback", "title": "Nope", "event": "dislike", "track_key": scout.track_key("Feedback", "Nope")}
            )
            + "\n",
            encoding="utf-8",
        )
        self.assertIn(scout.track_key("Feedback", "Nope"), scout.rejected_keys(self.cfg, self.paths))
        ledger_key = scout.track_key("Reject Band", "Ledger Song")
        scout.append_jsonl(
            self.paths.ledger,
            {
                "at": "2026-11-14T10:00:00Z",
                "action": "rejected",
                "track_key": ledger_key,
                "artist": "Reject Band",
                "title": "Ledger Song",
            },
        )
        self.assertIn(ledger_key, scout.rejected_keys(self.cfg, self.paths))

    def _acquired(self, artist, title, **extra):
        key = scout.track_key(artist, title)
        row = {
            "at": "2026-11-10T10:00:00Z",
            "action": "acquired",
            "artist": artist,
            "title": title,
            "track_key": key,
            "duration_seconds": extra.get("duration_seconds", 200.0),
            "local_path": extra.get("local_path", f"/tmp/{title.replace(' ', '_')}.m4a"),
        }
        scout.append_jsonl(self.paths.ledger, row)
        return key

    def _playback(self, events):
        path = Path(self.cfg["playback_log"])
        path.write_text("\n".join(json.dumps(e) for e in events) + "\n", encoding="utf-8")

    # Lines shaped like the player's real log: a `track` line names the FILE that is starting
    # (title and artist are empty), with an epoch; nothing says how far the last file played.
    def _start(self, file_name, cause, day, clock, playlist="station:triplej"):
        hour, minute, second = (int(part) for part in clock.split(":"))
        epoch = datetime(2026, 11, int(day), hour, minute, second, tzinfo=timezone.utc).timestamp()
        return {"event": "track", "cause": cause, "file": file_name, "title": "", "artist": "",
                "playlist": playlist, "epoch": epoch, "elapsed": 0.0,
                "t": f"2026-11-{int(day):02d} {clock}.000"}

    def _skip_day(self, day, seconds, file_name="01. Early Leave.m4a", playlist="station:triplej"):
        return [
            self._start(file_name, "playlist", day, "10:00:00", playlist),
            self._start("02. Next.m4a", "click-next", day, f"10:{seconds // 60:02d}:{seconds % 60:02d}", playlist),
        ]

    def test_skip_rejection_two_days_not_one(self):
        key = self._acquired("Skip Act", "Early Leave", duration_seconds=200.0,
                             local_path="/music/AM-Lossless/Skip Act/EP/01. Early Leave.m4a")
        self._playback(self._skip_day(1, 20))
        self.assertNotIn(key, scout.skip_rejected_keys(self.cfg, self.paths))
        # A second early skip the same day is still one day.
        self._playback(self._skip_day(1, 20) + [
            self._start("01. Early Leave.m4a", "click", 1, "11:00:00"),
            self._start("02. Next.m4a", "click-next", 1, "11:00:30"),
        ])
        self.assertNotIn(key, scout.skip_rejected_keys(self.cfg, self.paths))
        self._playback(self._skip_day(1, 20) + self._skip_day(2, 79))
        self.assertIn(key, scout.skip_rejected_keys(self.cfg, self.paths))
        self.assertIn(key, scout.rejected_keys(self.cfg, self.paths))

    def test_skip_not_rejected_late_or_completed(self):
        key = self._acquired("Late Act", "Long Play", duration_seconds=200.0,
                             local_path="/music/AM-Lossless/Late Act/LP/01. Early Leave.m4a")
        # 80 s is 40% of 200 s: on the line is not early.
        self._playback(self._skip_day(1, 80) + self._skip_day(2, 80))
        self.assertNotIn(key, scout.skip_rejected_keys(self.cfg, self.paths))
        # Played to the end once (an automatic advance followed it): two early skips do not reject it.
        self._playback([
            self._start("01. Early Leave.m4a", "playlist", 1, "09:00:00"),
            self._start("02. Next.m4a", "auto-advance", 1, "09:03:20"),
        ] + self._skip_day(2, 10) + self._skip_day(3, 10))
        self.assertNotIn(key, scout.skip_rejected_keys(self.cfg, self.paths))
        # A crossfade at the end is also played to the end.
        self._playback([
            self._start("01. Early Leave.m4a", "playlist", 1, "09:00:00"),
            self._start("02. Next.m4a", "crossfade", 1, "09:03:15"),
        ] + self._skip_day(2, 10) + self._skip_day(3, 10))
        self.assertNotIn(key, scout.skip_rejected_keys(self.cfg, self.paths))

    def test_skip_ignores_other_playlists_restarts_and_other_ways_of_leaving(self):
        key = self._acquired("Same Name", "Early Leave", duration_seconds=200.0,
                             local_path="/music/AM-Lossless/Same Name/EP/01. Early Leave.m4a")
        # The same file name in another playlist is another song.
        self._playback(self._skip_day(1, 10, playlist="song:ABC") + self._skip_day(2, 10, playlist="song:ABC"))
        self.assertNotIn(key, scout.skip_rejected_keys(self.cfg, self.paths))
        # Choosing another tile or track is not a skip.
        self._playback([
            self._start("01. Early Leave.m4a", "playlist", 1, "10:00:00"),
            self._start("02. Next.m4a", "playlist", 1, "10:00:10"),
            self._start("01. Early Leave.m4a", "playlist", 2, "10:00:00"),
            self._start("02. Next.m4a", "click", 2, "10:00:10"),
        ])
        self.assertNotIn(key, scout.skip_rejected_keys(self.cfg, self.paths))
        # A restart between the two lines: the gap says nothing.
        relaunch = {"event": "launch", "epoch": 0, "t": "2026-11-02 10:00:05.000"}
        day2 = self._skip_day(2, 10)
        self._playback(self._skip_day(1, 10) + [day2[0], relaunch, day2[1]])
        self.assertNotIn(key, scout.skip_rejected_keys(self.cfg, self.paths))
        # Unknown duration: 60 s is the line.
        other = self._acquired("No Length", "Short", duration_seconds=None,
                               local_path="/music/AM-Lossless/No Length/EP/07. Short.m4a")
        self._playback(self._skip_day(1, 59, "07. Short.m4a") + self._skip_day(2, 60, "07. Short.m4a"))
        self.assertNotIn(other, scout.skip_rejected_keys(self.cfg, self.paths))
        self._playback(self._skip_day(1, 59, "07. Short.m4a") + self._skip_day(2, 59, "07. Short.m4a"))
        self.assertIn(other, scout.skip_rejected_keys(self.cfg, self.paths))
        # A line with no clock is not guessed at.
        broken = self._skip_day(1, 10, "07. Short.m4a")
        broken[1]["epoch"] = None
        self._playback(broken + self._skip_day(2, 10, "07. Short.m4a"))
        self.assertNotIn(other, scout.skip_rejected_keys(self.cfg, self.paths))

    def test_candidates_refresh_the_shared_record_first_and_keep_going_when_that_fails(self):
        calls = []

        def collect_ok():
            calls.append("collect")
            return None

        runners = scout.Runners(media_collect=collect_ok, ai_pick=lambda *a, **k: (75, ""),
                                itunes_albums=lambda *a, **k: [], clock=lambda: "2026-11-14T12:00:00Z")
        _, _, errors = scout.cmd_candidates(self.cfg, self.paths, runners)
        self.assertEqual(calls, ["collect"])
        self.assertFalse([e for e in errors if e.startswith("media-sync")])
        failing = scout.Runners(media_collect=lambda: "collect exit 1: no sources", ai_pick=lambda *a, **k: (75, ""),
                                itunes_albums=lambda *a, **k: [], clock=lambda: "2026-11-14T12:00:00Z")
        rows, counts, errors = scout.cmd_candidates(self.cfg, self.paths, failing)
        self.assertIn("media-sync: collect exit 1: no sources", errors)
        self.assertIn("shazam", counts)
        # A test's runners never run the real collector.
        self.assertIsNone(scout.Runners().media_collect())

    def test_a_shazam_outranks_an_earlier_dry_run_offer_but_not_a_real_copy(self):
        def offered_and_candidates(action):
            self.paths.ledger.write_text("", encoding="utf-8")
            scout.append_jsonl(self.paths.ledger, {"at": "2026-11-10T04:00:00Z", "action": action,
                                                   "artist": "Heard Act", "title": "Radio Song",
                                                   "track_key": scout.track_key("Heard Act", "Radio Song")})
            cands = [
                {"artist": "Heard Act", "title": "Radio Song", "source": "shazam", "priority": True,
                 "score_hint": 0.95, "why": "Shazamed 14 Nov"},
                {"artist": "Heard Act", "title": "Radio Song", "source": "new-release", "score_hint": 0.8},
            ]
            self.paths.candidates.write_text(json.dumps({"candidates": cands}), encoding="utf-8")
            runners = scout.Runners(clock=lambda: "2026-11-14T12:00:00Z")
            return [r["track_key"] for r in scout.cmd_rank(self.cfg, self.paths, runners)]

        key = scout.track_key("Heard Act", "Radio Song")
        self.assertIn(key, offered_and_candidates("offered"))
        self.assertNotIn(key, offered_and_candidates("acquired"))
        self.assertNotIn(key, offered_and_candidates("no_match"))
        # Without his signal, an earlier offer still stops a repeat.
        self.paths.ledger.write_text("", encoding="utf-8")
        scout.append_jsonl(self.paths.ledger, {"at": "2026-11-10T04:00:00Z", "action": "offered",
                                               "artist": "Plain Act", "title": "Song",
                                               "track_key": scout.track_key("Plain Act", "Song")})
        self.paths.candidates.write_text(json.dumps({"candidates": [
            {"artist": "Plain Act", "title": "Song", "source": "new-release", "score_hint": 0.8}]}), encoding="utf-8")
        ranked = scout.cmd_rank(self.cfg, self.paths, scout.Runners(clock=lambda: "2026-11-14T12:00:00Z"))
        self.assertNotIn(scout.track_key("Plain Act", "Song"), [r["track_key"] for r in ranked])

    def test_publish_omits_rejected(self):
        key = scout.track_key("Pub Reject", "Song")
        scout.append_jsonl(
            self.paths.ledger,
            {
                "at": "2026-11-13T12:00:00Z",
                "action": "acquired",
                "artist": "Pub Reject",
                "title": "Song",
                "track_key": key,
            },
        )
        scout.append_jsonl(
            self.paths.ledger,
            {"at": "2026-11-14T10:00:00Z", "action": "rejected", "track_key": key, "artist": "Pub Reject", "title": "Song"},
        )
        doc = scout.cmd_publish(self.cfg, self.paths, scout.Runners(clock=lambda: "2026-11-14T12:00:00Z"))
        self.assertEqual(doc["tracks"], [])

    def test_media_like_bonus_capped(self):
        key = scout.track_key("Like Act", "Bonus Track")
        fb = {scout.normal(key): {"event": "like"}}
        media = {key}
        score = scout.score_candidate(
            {"artist": "Like Act", "title": "Bonus Track", "score_hint": 0.5},
            fb,
            Counter(),
            media_likes=media,
        )
        self.assertEqual(score, 0.9)

    def test_shazam_acquire_uses_track_id_without_search(self):
        searches = []

        def fake_best(*args, **kwargs):
            searches.append(args)
            return {"trackId": 1}

        self.paths.queue.write_text(
            json.dumps(
                {
                    "tracks": [
                        {
                            "artist": "Am Act",
                            "title": "Known",
                            "track_key": scout.track_key("Am Act", "Known"),
                            "track_id": 555,
                            "url": "https://music.apple.com/au/song/555",
                        }
                    ]
                }
            ),
            encoding="utf-8",
        )
        runners = scout.Runners(
            clock=lambda: "2026-11-14T12:00:00Z",
            is_m5=lambda: True,
            is_metered=lambda: False,
            on_battery=lambda: False,
            itunes_song_best=fake_best,
        )
        scout.cmd_acquire(self.cfg, self.paths, runners, go=False)
        self.assertEqual(searches, [])

    def test_priority_still_respects_weekly_budget(self):
        now = scout.parse_iso("2026-11-10T12:00:00Z")
        for i in range(20):
            scout.append_jsonl(
                self.paths.ledger,
                {
                    "at": "2026-11-09T12:00:00Z",
                    "action": "acquired",
                    "artist": "Full",
                    "title": f"t{i}",
                    "size_mb": 10,
                },
            )
        self.paths.queue.write_text(
            json.dumps(
                {
                    "tracks": [
                        {
                            "artist": "Priority",
                            "title": "Extra",
                            "track_key": scout.track_key("Priority", "Extra"),
                            "track_id": 77,
                            "priority": True,
                            "source": "shazam",
                        }
                    ]
                }
            ),
            encoding="utf-8",
        )
        cfg = dict(self.cfg, tracks_per_week=20, gb_per_week=10.0)
        runners = scout.Runners(
            clock=lambda: "2026-11-10T12:00:00Z",
            is_m5=lambda: True,
            is_metered=lambda: False,
            on_battery=lambda: False,
            itunes_song_best=lambda *a, **k: {"trackId": 77, "trackTimeMillis": 180_000},
        )
        summary = scout.cmd_acquire(cfg, self.paths, runners, go=False)
        self.assertEqual(summary["attempted"], 0)

    def test_status_shazam_counts(self):
        key_fresh = scout.track_key("Stat Band", "Fresh Shazam")
        key_old = scout.track_key("Stat Band", "Old Shazam")
        _media_signals(
            self.share,
            "m5",
            {
                key_fresh: {
                    "artist": "Stat Band",
                    "title": "Fresh Shazam",
                    "signals": [{"kind": "shazam", "source": "shazam", "at": "2026-11-10T10:00:00Z"}],
                },
                key_old: {
                    "artist": "Stat Band",
                    "title": "Old Shazam",
                    "signals": [{"kind": "shazam", "source": "shazam", "at": "2026-09-01T10:00:00Z"}],
                },
            },
        )
        scout.append_jsonl(
            self.paths.ledger,
            {"at": "2026-11-09T10:00:00Z", "action": "offered", "artist": "Stat Band", "title": "Fresh Shazam"},
        )
        doc, _ = scout.cmd_status(self.cfg, self.paths, scout.Runners(clock=lambda: "2026-11-14T12:00:00Z"))
        self.assertEqual(doc["shazam"]["fresh"], 1)
        self.assertEqual(doc["shazam"]["waiting"], 0)


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

    def test_novelty_ordering_prefers_new_artists(self):
        owned_key = scout.track_key("Owned Band", "Core Song")
        (self.root / "export" / "Owned Band").mkdir()
        (self.root / "export" / "Owned Band" / "Al").mkdir(parents=True)
        (self.root / "export" / "Owned Band" / "Al" / "Core Song.m4a").write_bytes(b"x")
        candidates = [
            {"artist": "Owned Band", "title": "New Track", "source": "triplej", "why": "w", "score_hint": 1.0},
            {"artist": "Fresh Act", "title": "Debut", "source": "triplej", "why": "w", "score_hint": 0.7},
        ]
        self.paths.candidates.write_text(json.dumps({"candidates": candidates}), encoding="utf-8")
        runners = scout.Runners(clock=lambda: "2026-11-10T00:00:00Z")
        ranked = scout.cmd_rank(self.cfg, self.paths, runners)
        self.assertEqual(ranked[0]["artist"], "Fresh Act")

    def test_remix_of_owned_demoted(self):
        owned_key = scout.track_key("Jamie xx", "Gosh")
        (self.root / "yt" / f"Jamie xx - Gosh [abc123def45].m4a").write_bytes(b"x")
        candidates = [
            {"artist": "Jamie xx", "title": "Gosh (Four Tet Remix)", "source": "triplej", "why": "w", "score_hint": 1.0},
            {"artist": "Newcomer", "title": "First Light", "source": "triplej", "why": "w", "score_hint": 0.6},
        ]
        self.paths.candidates.write_text(json.dumps({"candidates": candidates}), encoding="utf-8")
        runners = scout.Runners(clock=lambda: "2026-11-10T00:00:00Z")
        ranked = scout.cmd_rank(self.cfg, self.paths, runners)
        self.assertEqual(ranked[0]["artist"], "Newcomer")

    def test_owned_artist_share_cap(self):
        owned_set = {"heavy rotation"}
        rows = [{"artist": f"Outsider {i}", "title": "Song"} for i in range(5)]
        rows += [{"artist": "Heavy Rotation", "title": f"n{i}"} for i in range(5)]
        capped = scout.enforce_owned_artist_share(rows, 0.30, owned_set)
        owned_n = sum(1 for r in capped if scout.primary_artist_name(r["artist"]) == "heavy rotation")
        self.assertLessEqual(owned_n, 3)
        self.assertEqual(len(capped), 8)

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
        count, total_bytes = scout.weekly_acquired_stats(self.paths.ledger, now)
        self.assertEqual(count, 18)
        self.assertEqual(total_bytes, 18 * 80 * 1024 * 1024)

        queue = {
            "tracks": [
                {"artist": "N1", "title": "s1", "track_key": "n1|s1", "track_id": 9},
                {"artist": "N2", "title": "s2", "track_key": "n2|s2", "track_id": 10},
            ]
        }
        self.paths.queue.write_text(json.dumps(queue), encoding="utf-8")
        cfg = dict(self.cfg, tracks_per_week=20, gb_per_week=2.0, avg_track_mb=75)
        runners = scout.Runners(
            clock=lambda: "2026-11-10T12:00:00Z",
            run_amdl=lambda url: (True, False, "", {"size_bytes": 80 * 1024 * 1024}),
            is_m5=lambda: True,
            is_metered=lambda: False,
            on_battery=lambda: False,
            itunes_song_best=lambda *a, **k: {"trackId": 9, "trackTimeMillis": 600_000},
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

    def test_unhearted_ever_hearted_is_weak_positive_not_penalty(self):
        key = scout.track_key("Band", "Song")
        base = scout.score_candidate(
            {"artist": "Band", "title": "Song"},
            {scout.normal(key): {"event": "skip"}},
            scout.Counter(),
        )
        with_ever = scout.score_candidate(
            {"artist": "Band", "title": "Song"},
            {scout.normal(key): {"event": "skip"}},
            scout.Counter(),
            ever_hearted={scout.normal(key)},
            current_hearts=set(),
        )
        self.assertLess(base, 0.5)
        self.assertGreater(with_ever, base)

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
        self.assertFalse(any(line.get("action") == "acquired" for line in scout.read_jsonl_rows(self.paths.ledger)))


    def test_budget_skips_track_larger_than_remaining(self):
        self.paths.queue.write_text(
            json.dumps({
                "tracks": [{
                    "artist": "Big",
                    "title": "Song",
                    "track_key": "big|song",
                    "track_id": 1,
                }]
            }),
            encoding="utf-8",
        )
        cfg = dict(self.cfg, gb_per_week=0.001, mb_per_minute=7)
        runners = scout.Runners(
            clock=lambda: "2026-11-10T12:00:00Z",
            is_m5=lambda: True,
            is_metered=lambda: False,
            on_battery=lambda: False,
            itunes_song_best=lambda *a, **k: {
                "trackId": 1,
                "trackName": "Song",
                "artistName": "Big",
                "trackTimeMillis": 600_000,
            },
        )
        summary = scout.cmd_acquire(cfg, self.paths, runners, go=False)
        self.assertEqual(summary["results"][0]["action"], "skipped_budget")

    def test_acquire_limit_stops_after_n_queue_rows(self):
        self.paths.queue.write_text(
            json.dumps(
                {
                    "tracks": [
                        {"artist": "A", "title": "one", "track_key": "a|one", "track_id": 1},
                        {"artist": "B", "title": "two", "track_key": "b|two", "track_id": 2},
                    ]
                }
            ),
            encoding="utf-8",
        )
        runners = scout.Runners(
            clock=lambda: "2026-11-10T12:00:00Z",
            is_m5=lambda: True,
            is_metered=lambda: False,
            on_battery=lambda: False,
            itunes_song_best=lambda *a, **k: {"trackId": 1, "trackName": "one", "artistName": "A", "trackTimeMillis": 180_000},
        )
        summary = scout.cmd_acquire(self.cfg, self.paths, runners, go=False, limit=1)
        self.assertEqual(summary["considered"], 1)
        self.assertEqual(len(summary["results"]), 1)

    def test_mirror_acquire_to_hot_copies_and_verifies(self):
        apple = self.root / "Apple Music"
        hot = self.root / "hot"
        apple.mkdir()
        hot.mkdir()
        rel = Path("Band/Al/track.m4a")
        src = apple / rel
        src.parent.mkdir(parents=True)
        body = b"lossless-bytes" * 50
        src.write_bytes(body)
        cfg = dict(self.cfg, apple_music_dir=str(apple), hot_dir=str(hot))
        meta = {
            "size_bytes": len(body),
            "files": [
                {
                    "relative_path": str(rel),
                    "absolute_path": str(src),
                    "size_bytes": len(body),
                    "sha256": "a" * 64,
                }
            ],
            "local_path": str(src),
            "catalogue_relative_path": str(rel),
            "sha256": "a" * 64,
        }
        out = scout.mirror_acquire_to_hot(meta, cfg)
        dest = hot / rel
        self.assertTrue(dest.is_file())
        self.assertEqual(dest.read_bytes(), body)
        self.assertEqual(Path(out["local_path"]).resolve(), dest.resolve())
        self.assertTrue(src.is_file())

    def test_acquire_records_real_bytes(self):
        self.paths.queue.write_text(
            json.dumps({"tracks": [{"artist": "A", "title": "B", "track_key": "a|b", "track_id": 1}]}),
            encoding="utf-8",
        )
        runners = scout.Runners(
            clock=lambda: "2026-11-10T12:00:00Z",
            is_m5=lambda: True,
            is_metered=lambda: False,
            on_battery=lambda: False,
            itunes_song_best=lambda *a, **k: {"trackId": 1, "trackName": "B", "artistName": "A", "trackTimeMillis": 180_000},
            run_amdl=lambda url: (True, False, "", {"size_bytes": 12_345_678}),
        )
        scout.cmd_acquire(self.cfg, self.paths, runners, go=True)
        rows = scout.read_jsonl_rows(self.paths.ledger)
        acquired = [r for r in rows if r.get("action") == "acquired"][-1]
        self.assertEqual(acquired["size_bytes"], 12_345_678)

    def test_music_sync_inventory_owned(self):
        inv = self.root / "inventory.json"
        inv.write_text(json.dumps({"am_fav": [{"artist": "Sync", "title": "Track"}]}))
        owned = scout.owned_keys(self.cfg, self.paths)
        self.assertIn(scout.track_key("Sync", "Track"), owned)

    def test_stale_queue_skips_newly_owned(self):
        track_dir = self.root / "export" / "Band" / "Al"
        track_dir.mkdir(parents=True)
        (track_dir / "Owned.m4a").write_bytes(b"x")
        self.paths.queue.write_text(
            json.dumps({"tracks": [{"artist": "Band", "title": "Owned", "track_key": "band|owned", "track_id": 1}]}),
            encoding="utf-8",
        )
        runners = scout.Runners(
            clock=lambda: "2026-11-10T12:00:00Z",
            is_m5=lambda: True,
            is_metered=lambda: False,
            on_battery=lambda: False,
        )
        summary = scout.cmd_acquire(self.cfg, self.paths, runners, go=False)
        self.assertEqual(summary["results"][0]["action"], "skipped_owned")

    def test_publish_includes_offline_identity(self):
        scout.append_jsonl(
            self.paths.ledger,
            {
                "at": "2026-11-10T00:00:00Z",
                "action": "acquired",
                "artist": "Pub",
                "title": "Lish",
                "track_key": "pub|lish",
                "album": "Al",
                "duration_seconds": 200.0,
                "catalogue_relative_path": "Pub/Al/track.m4a",
                "sha256": "a" * 64,
            },
        )
        runners = scout.Runners(clock=lambda: "2026-11-11T00:00:00Z")
        doc = scout.cmd_publish(self.cfg, self.paths, runners)
        row = doc["tracks"][0]
        self.assertEqual(row["album"], "Al")
        self.assertEqual(row["duration_seconds"], 200.0)
        self.assertEqual(row["catalogue_relative_path"], "Pub/Al/track.m4a")

    def test_status_reports_torn_ledger(self):
        self.paths.ledger.write_text('{"action":"acquired"}\n{broken\n', encoding="utf-8")
        doc, code = scout.cmd_status(self.cfg, self.paths, scout.Runners(clock=lambda: "2026-11-10T12:00:00Z"))
        self.assertEqual(code, 1)
        self.assertIn("broken", doc["ledger_torn_line"])


class ScheduledEnvironmentTests(unittest.TestCase):
    """The 03:10 job runs under launchd with PATH=/usr/bin:/bin:/usr/sbin:/sbin. On 11 and 12 Nov
    2026 the taste step never ran because `ai-pick` (in ~/.local/bin) was not found, and that was
    recorded as a quiet "deferred" with the reason thrown away."""

    def _home(self, tmp: str) -> Path:
        home = Path(tmp)
        bindir = home / ".local" / "bin"
        bindir.mkdir(parents=True)
        for name, body in (("ai-pick", "#!/bin/sh\necho fake\n"), ("fake-engine", "#!/bin/sh\ncat\n")):
            f = bindir / name
            f.write_text(body, encoding="utf-8")
            f.chmod(0o755)
        return home

    def test_ai_pick_found_under_launchd_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = self._home(tmp)
            old_env, old_cmds = dict(os.environ), dict(scout.ENGINE_COMMANDS)
            try:
                os.environ.clear()
                os.environ.update({"HOME": str(home), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"})
                scout.ENGINE_COMMANDS.clear()
                scout.ENGINE_COMMANDS["fake"] = ["fake-engine"]
                code, text = scout._default_ai_pick("hello scout", "ai-pick")
            finally:
                os.environ.clear()
                os.environ.update(old_env)
                scout.ENGINE_COMMANDS.clear()
                scout.ENGINE_COMMANDS.update(old_cmds)
            self.assertEqual((code, text), (0, "hello scout"))

    def test_missing_ai_pick_is_an_error_not_a_deferral(self):
        with tempfile.TemporaryDirectory() as tmp:
            old_env = dict(os.environ)
            try:
                os.environ.clear()
                os.environ.update({"HOME": tmp, "PATH": "/usr/bin:/bin"})
                code, text = scout._default_ai_pick("x", "ai-pick-that-does-not-exist")
            finally:
                os.environ.clear()
                os.environ.update(old_env)
            self.assertNotEqual(code, 75)
            self.assertNotEqual(code, 0)
            self.assertIn("not found", text)

    def test_taste_error_keeps_its_reason(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg = _cfg(Path(tmp))
            runners = scout.Runners(ai_pick=lambda prompt, cmd: (127, "ai-pick not found on PATH"))
            rows, err = scout.source_taste_expansion(cfg, runners, {})
            self.assertEqual(rows, [])
            self.assertIn("not found", err)
            runners = scout.Runners(ai_pick=lambda prompt, cmd: (75, "all pools below 20%"))
            rows, err = scout.source_taste_expansion(cfg, runners, {})
            self.assertTrue(err.startswith("deferred"))
            self.assertIn("below 20%", err)

    def test_run_record_keeps_the_errors(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            cfg = _cfg(root)
            paths = scout.ScoutPaths(root / "state")
            orig = (scout.cmd_candidates, scout.cmd_rank, scout.cmd_acquire, scout.cmd_publish)
            try:
                scout.cmd_candidates = lambda *a, **k: ([], {"triplej": 0}, ["taste-expansion: ai-pick not found on PATH"])
                scout.cmd_rank = lambda *a, **k: []
                scout.cmd_acquire = lambda *a, **k: {"attempted": 0}
                scout.cmd_publish = lambda *a, **k: {"tracks": []}
                scout.cmd_run(cfg, paths, scout.Runners(clock=lambda: "2026-11-12T00:00:00Z"), go=False)
            finally:
                scout.cmd_candidates, scout.cmd_rank, scout.cmd_acquire, scout.cmd_publish = orig
            doc = json.loads(paths.last_run.read_text(encoding="utf-8"))
            self.assertFalse(doc["ok"])
            self.assertEqual(doc["errors"], ["taste-expansion: ai-pick not found on PATH"])


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
