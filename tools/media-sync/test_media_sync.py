#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import sqlite3
import tempfile
import time
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

import media_sync as ms


class MediaSyncTestBase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.share = self.root / "share"
        self.state = self.root / "state"
        self.share.mkdir()
        self.state.mkdir()
        self.t0 = 1_700_000_000.0
        ms.set_clock(lambda: self.t0)
        self.cfg = {
            "host": "testhost",
            "share_dir": str(self.share),
            "state_dir": str(self.state),
            "shazam_db": str(self.root / "shazam.sqlite"),
            "hearts_path": str(self.root / "hearts.json"),
            "heart_history": str(self.root / "heart-history.jsonl"),
            "glancebar_feedback": str(self.root / "feedback.jsonl"),
            "liked_pulled": str(self.root / "liked-pulled.json"),
            "yt_liked_dir": str(self.root / "yt"),
            "music_sync_inventory": str(self.root / "inventory.json"),
            "catalogue": str(self.root / "catalogue.json"),
            "tv_storage": str(self.root / "tv-storage.json"),
            "tv_music_videos": str(self.root / "videos"),
            "mixpool_state": str(self.root / "mixpool"),
            "apple_music_dir": str(self.root / "apple"),
            "music_library_state": str(self.root / "mlib"),
            "scout_state": str(self.root / "scout"),
            "selector_state": str(self.root / "selector"),
            "tv_video_log": "",
            "check": dict(ms.DEFAULTS["check"]),
        }
        for d in (self.root / "mixpool/logs", self.root / "apple", self.root / "mlib",
                  self.root / "scout", self.root / "selector", self.root / "videos" / "A"):
            d.mkdir(parents=True, exist_ok=True)

    def tearDown(self):
        ms.set_clock(time.time)
        self.tmp.cleanup()

    def write_shazam_db(self):
        conn = sqlite3.connect(self.cfg["shazam_db"])
        conn.execute(
            "CREATE TABLE ZSHTRACKMO ("
            "ZDATE REAL, ZTITLE TEXT, ZSUBTITLE TEXT, ZALBUMNAME TEXT, "
            "ZAPPLEMUSICID TEXT, ZISRC TEXT, ZLATITUDE REAL, ZLONGITUDE REAL, ZRAWSONGRESPONSE BLOB)"
        )
        conn.execute(
            "INSERT INTO ZSHTRACKMO VALUES (?,?,?,?,?,?,?,?,?)",
            (700000.0, "Example Song", "Example Artist", "Album", "111", "ISRC1", -33.0, 151.0, b"secret"),
        )
        conn.commit()
        conn.close()

class CollectTests(MediaSyncTestBase):
    def test_shazam_privacy_and_collect(self):
        self.write_shazam_db()
        self.assertEqual(ms.cmd_collect(self.cfg), 0)
        out = self.share / "signals-testhost.json"
        text = out.read_text(encoding="utf-8")
        self.assertNotIn("latitude", text.lower())
        self.assertNotIn("longitude", text.lower())
        self.assertNotIn("secret", text)
        doc = json.loads(text)
        key = ms.track_key("Example Artist", "Example Song")
        self.assertIn(key, doc["tracks"])
        self.assertEqual(doc["sources"]["shazam"]["ok"], True)

    def test_missing_source_not_fatal(self):
        self.assertEqual(ms.cmd_collect(self.cfg), 0)
        doc = json.loads((self.share / "signals-testhost.json").read_text(encoding="utf-8"))
        self.assertFalse(doc["sources"]["shazam"]["ok"])
        self.assertEqual(doc["sources"]["shazam"]["error"], "missing")

    def test_hearts_and_unheart(self):
        key = ms.track_key("Hearted", "Song")
        Path(self.cfg["hearts_path"]).write_text(
            json.dumps({"tracks": [key]}), encoding="utf-8"
        )
        Path(self.cfg["heart_history"]).write_text(
            json.dumps({"action": "heart", "artist": "Hearted", "title": "Song", "at": self.t0, "trackKey": key})
            + "\n"
            + json.dumps({"action": "unheart", "artist": "Hearted", "title": "Song", "at": self.t0 + 1, "trackKey": key})
            + "\n",
            encoding="utf-8",
        )
        ms.cmd_collect(self.cfg)
        doc = json.loads((self.share / "signals-testhost.json").read_text(encoding="utf-8"))
        self.assertTrue(ms.has_like(doc["tracks"][key]))
        Path(self.cfg["hearts_path"]).write_text(json.dumps({"tracks": []}), encoding="utf-8")
        ms.cmd_collect(self.cfg)
        doc2 = json.loads((self.share / "signals-testhost.json").read_text(encoding="utf-8"))
        self.assertNotIn(key, doc2["tracks"])

    def test_feedback_dislike_and_thumbs(self):
        key = ms.track_key("Faux Pilot", "Wing Song")
        Path(self.cfg["hearts_path"]).write_text(json.dumps({"tracks": []}), encoding="utf-8")
        lines = [
            json.dumps(
                {
                    "artist": "Faux Pilot",
                    "title": "Wing Song",
                    "trackID": "W1",
                    "track_key": key,
                    "event": "dislike",
                    "liked": False,
                    "at": "2026-11-14T08:00:00Z",
                },
                sort_keys=True,
            ),
        ]
        Path(self.cfg["glancebar_feedback"]).write_text("\n".join(lines) + "\n", encoding="utf-8")
        _st, tr = ms.collect_hearts(self.cfg)
        self.assertTrue(ms.has_dislike(tr[key]))
        self.assertFalse(ms.has_like(tr[key]))
        lines.append(
            json.dumps(
                {
                    "artist": "Faux Pilot",
                    "title": "Wing Song",
                    "trackID": "W1",
                    "track_key": key,
                    "event": "undislike",
                    "at": "2026-11-14T09:00:00Z",
                },
                sort_keys=True,
            )
        )
        Path(self.cfg["glancebar_feedback"]).write_text("\n".join(lines) + "\n", encoding="utf-8")
        _st2, tr2 = ms.collect_hearts(self.cfg)
        self.assertNotIn(key, tr2)
        lines.append(
            json.dumps(
                {
                    "artist": "Faux Pilot",
                    "title": "Wing Song",
                    "trackID": "W1",
                    "track_key": key,
                    "event": "dislike",
                    "liked": False,
                    "at": "2026-11-14T10:00:00Z",
                },
                sort_keys=True,
            )
        )
        lines.append(
            json.dumps(
                {
                    "artist": "Faux Pilot",
                    "title": "Wing Song",
                    "trackID": "W1",
                    "track_key": key,
                    "liked": True,
                    "at": "2026-11-14T11:00:00Z",
                },
                sort_keys=True,
            )
        )
        Path(self.cfg["glancebar_feedback"]).write_text("\n".join(lines) + "\n", encoding="utf-8")
        _st3, tr3 = ms.collect_hearts(self.cfg)
        self.assertFalse(ms.has_dislike(tr3.get(key, {})))
        self.assertTrue(ms.has_like(tr3[key]))

    def test_export_likes_skips_disliked(self):
        key = ms.track_key("Skip Me", "Disliked Tune")
        Path(self.cfg["hearts_path"]).write_text(json.dumps({"tracks": [key]}), encoding="utf-8")
        Path(self.cfg["glancebar_feedback"]).write_text(
            json.dumps(
                {
                    "artist": "Skip Me",
                    "title": "Disliked Tune",
                    "track_key": key,
                    "event": "dislike",
                    "liked": False,
                    "at": "2026-11-14T10:00:00Z",
                },
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )
        ms.cmd_collect(self.cfg)
        doc = json.loads((self.share / "signals-testhost.json").read_text(encoding="utf-8"))
        self.assertTrue(ms.has_dislike(doc["tracks"][key]))
        out = self.root / "likes.json"
        out.write_text("[]", encoding="utf-8")
        rc = ms.cmd_export_likes(self.cfg, argparse_namespace(out=str(out), force=True))
        self.assertEqual(rc, 0)
        self.assertEqual(json.loads(out.read_text(encoding="utf-8")), [])

    def test_wrong_song_like_without_apple_id(self):
        Path(self.cfg["liked_pulled"]).write_text(
            json.dumps(
                {
                    "done": {"A|B": {"track_id": "99"}},
                    "wrong_song": {"C|D": {"track_id": "wrong"}},
                }
            ),
            encoding="utf-8",
        )
        ms.cmd_collect(self.cfg)
        doc = json.loads((self.share / "signals-testhost.json").read_text(encoding="utf-8"))
        self.assertEqual(doc["tracks"][ms.track_key("C", "D")]["ids"]["apple_music"], "")
        self.assertEqual(doc["tracks"][ms.track_key("A", "B")]["ids"]["apple_music"], "99")

    def test_tv_filename_parsing(self):
        cases = [
            ("Artist Alpha - Song One (Official Video) [vid1]", ("Artist Alpha", "Song One", "vid1")),
            ("Artist Beta - Song Two (Remix) [vid2]", ("Artist Beta", "Song Two (Remix)", "vid2")),
            ("Solo Title (Official Audio) [vid3]", ("", "Solo Title", "vid3")),
        ]
        for name, expected in cases:
            self.assertEqual(ms.parse_bracketed_name(name), expected)

    def test_tv_likes_and_video(self):
        vid_root = Path(self.cfg["tv_music_videos"])
        inner = vid_root / "Artist Alpha"
        inner.mkdir(parents=True, exist_ok=True)
        (inner / "Artist Alpha - Song One (Official Video) [vid1].mp4").write_bytes(b"x")
        storage = {
            "onto.tv.likes": json.dumps(
                {str(inner / "f.mp4"): {"at": self.t0, "key": "aud1", "was": True}}
            )
        }
        Path(self.cfg["tv_storage"]).write_text(json.dumps(storage), encoding="utf-8")
        ms.cmd_collect(self.cfg)
        doc = json.loads((self.share / "signals-testhost.json").read_text(encoding="utf-8"))
        key = ms.track_key("Artist Alpha", "Song One")
        self.assertIn(key, doc["tracks"])
        self.assertEqual(doc["tracks"][key]["video"], "vid1")

    def test_youtube_and_inventory_fallback(self):
        yt = Path(self.cfg["yt_liked_dir"])
        yt.mkdir(parents=True, exist_ok=True)
        (yt / "Yt Art - Yt Song [abc123].m4a").write_bytes(b"x")
        ms.cmd_collect(self.cfg)
        doc = json.loads((self.share / "signals-testhost.json").read_text(encoding="utf-8"))
        key = ms.track_key("Yt Art", "Yt Song")
        self.assertEqual(doc["tracks"][key]["ids"]["youtube"], "abc123")

    def test_inventory_when_yt_dir_missing(self):
        inv = Path(self.cfg["music_sync_inventory"])
        inv.write_text(
            json.dumps({"yt": [{"artist": "Inv", "title": "Song", "videoId": "zz"}]}),
            encoding="utf-8",
        )
        ms.cmd_collect(self.cfg)
        doc = json.loads((self.share / "signals-testhost.json").read_text(encoding="utf-8"))
        key = ms.track_key("Inv", "Song")
        self.assertEqual(doc["tracks"][key]["ids"]["youtube"], "zz")

    def test_tv_at_milliseconds(self):
        self.assertEqual(
            ms.epoch_to_iso(self.t0 * 1000.0).endswith("Z"),
            True,
        )

    def test_export_empty_aborts(self):
        self.assertEqual(
            ms.cmd_export_likes(
                self.cfg,
                argparse_namespace(out=str(self.root / "out.json"), force=False),
            ),
            3,
        )

    def test_owned_catalogue_match(self):
        Path(self.cfg["catalogue"]).write_text(
            json.dumps(
                {
                    "entries": [
                        {"tags": {"artist": "Cat Artist", "title": "Cat Title", "album": ""}},
                    ]
                }
            ),
            encoding="utf-8",
        )
        Path(self.cfg["hearts_path"]).write_text(
            json.dumps({"tracks": [ms.track_key("Cat Artist", "Cat Title")]}),
            encoding="utf-8",
        )
        ms.cmd_collect(self.cfg)
        doc = json.loads((self.share / "signals-testhost.json").read_text(encoding="utf-8"))
        key = ms.track_key("Cat Artist", "Cat Title")
        self.assertTrue(doc["tracks"][key]["owned"])

    def test_merge_two_hosts(self):
        doc_a = {
            "version": 1,
            "host": "a",
            "generated": ms.iso_now(),
            "sources": {},
            "tracks": {
                ms.track_key("A", "T"): {
                    **ms.empty_track("A", "T"),
                    "ids": {"apple_music": "1", "isrc": "", "youtube": ""},
                    "signals": [{"kind": "like", "source": "glancebar", "at": ""}],
                    "owned": False,
                }
            },
        }
        doc_b = {
            "version": 1,
            "host": "b",
            "generated": ms.iso_now(),
            "sources": {},
            "tracks": {
                ms.track_key("A", "T"): {
                    **ms.empty_track("A", "T"),
                    "ids": {"apple_music": "", "isrc": "", "youtube": "yt9"},
                    "signals": [{"kind": "shazam", "source": "shazam", "at": "2026-01-01T00:00:00Z"}],
                    "owned": True,
                    "video": "vidz",
                }
            },
        }
        (self.share / "signals-a.json").write_text(json.dumps(doc_a), encoding="utf-8")
        (self.share / "signals-b.json").write_text(json.dumps(doc_b), encoding="utf-8")
        merged = ms.merge_share_including_host(self.share)
        tr = merged[ms.track_key("A", "T")]
        self.assertTrue(tr["owned"])
        self.assertEqual(tr["ids"]["youtube"], "yt9")
        self.assertEqual(len(tr["signals"]), 2)

    def test_export_likes_order_and_guard(self):
        key = ms.track_key("L", "Song")
        doc = {
            "version": 1,
            "host": "testhost",
            "generated": ms.iso_now(),
            "sources": {},
            "tracks": {
                key: {
                    **ms.empty_track("L", "Song"),
                    "signals": [{"kind": "like", "source": "youtube", "at": ""}],
                    "ids": {"apple_music": "", "isrc": "", "youtube": "v1"},
                },
                ms.track_key("Only", "Shazam"): {
                    **ms.empty_track("Only", "Shazam"),
                    "signals": [{"kind": "shazam", "source": "shazam", "at": ""}],
                },
            },
        }
        (self.share / "signals-testhost.json").write_text(json.dumps(doc), encoding="utf-8")
        out = self.root / "likes.json"
        old = [{"videoId": f"id{i}", "title": f"t{i}", "artist": f"a{i}"} for i in range(10)]
        out.write_text(json.dumps(old), encoding="utf-8")
        rc = ms.cmd_export_likes(self.cfg, argparse_namespace(out=str(out), force=False))
        self.assertEqual(rc, 3)
        self.assertEqual(len(json.loads(out.read_text(encoding="utf-8"))), 10)
        rc = ms.cmd_export_likes(self.cfg, argparse_namespace(out=str(out), force=True))
        self.assertEqual(rc, 0)
        rows = json.loads(out.read_text(encoding="utf-8"))
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["videoId"], "v1")


def argparse_namespace(**kwargs):
    class NS:
        pass

    ns = NS()
    for k, v in kwargs.items():
        setattr(ns, k, v)
    return ns


class CheckRowsTest(MediaSyncTestBase):
    def write_ledger(self, age_h: float = 0):
        path = self.share / "signals-testhost.json"
        doc = {
            "version": 1,
            "host": "testhost",
            "generated": ms.iso_now(),
            "sources": {"shazam": {"ok": False, "count": 0, "error": "missing"}},
            "tracks": {ms.track_key("A", "B"): {**ms.empty_track("A", "B"), "signals": [{"kind": "like", "source": "glancebar", "at": ""}]}},
        }
        path.write_text(json.dumps(doc), encoding="utf-8")
        ts = self.t0 - age_h * 3600
        os.utime(path, (ts, ts))

    def run_check(self, strict=False):
        return ms.cmd_check(self.cfg, argparse_namespace(json=False, strict=strict))

    def test_ledger_warn_and_fail_thresholds(self):
        self.write_ledger(age_h=40)
        self.run_check()
        doc = json.loads((self.state / "check.json").read_text(encoding="utf-8"))
        ledger = [r for r in doc["rows"] if r["name"] == "ledger"][0]
        self.assertEqual(ledger["status"], "warn")
        self.write_ledger(age_h=80)
        self.run_check()
        doc = json.loads((self.state / "check.json").read_text(encoding="utf-8"))
        ledger = [r for r in doc["rows"] if r["name"] == "ledger"][0]
        self.assertEqual(ledger["status"], "fail")

    def tv_row(self):
        self.run_check()
        doc = json.loads((self.state / "check.json").read_text(encoding="utf-8"))
        return [r for r in doc["rows"] if r["name"] == "tv videos"][0]

    def test_tv_videos_row_needs_a_finished_pass_and_reads_its_time(self):
        log = self.root / "drive.log"
        self.cfg["tv_video_log"] = str(log)
        self.write_ledger()
        # No log at all: a job that never ran is not a pass.
        self.assertEqual(self.tv_row()["status"], "warn")
        def stamp(hours_ago):
            return ms.datetime.fromtimestamp(self.t0 - hours_ago * 3600, tz=ms.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        log.write_text(f"{stamp(100)} pass done\n{stamp(35)} pass done\n{stamp(1)} no drive\n", encoding="utf-8")
        row = self.tv_row()
        self.assertEqual(row["status"], "pass")
        self.assertIn("35 h", row["value"] + row["detail"])
        log.write_text(f"{stamp(37)} pass done\n", encoding="utf-8")
        self.assertEqual(self.tv_row()["status"], "warn")
        log.write_text(f"{stamp(97)} pass done\n", encoding="utf-8")
        self.assertEqual(self.tv_row()["status"], "fail")
        # Only refusals in the log: nothing finished.
        log.write_text(f"{stamp(1)} no drive\n", encoding="utf-8")
        self.assertEqual(self.tv_row()["status"], "warn")
        # The older line format has no readable time: the file's own time is used.
        log.write_text("Sat Nov 14 02:30:03 AWST 2026 pass done\n", encoding="utf-8")
        os.utime(log, (self.t0 - 2 * 3600, self.t0 - 2 * 3600))
        self.assertEqual(self.tv_row()["status"], "pass")
        os.utime(log, (self.t0 - 40 * 3600, self.t0 - 40 * 3600))
        self.assertEqual(self.tv_row()["status"], "warn")

    def test_a_mac_answers_only_for_its_own_sources_and_rows(self):
        # Leftovers on a Mac that only serves the TV: an old likes file and its stale log.
        (self.root / "liked-pulled.json").write_text(json.dumps({"done": {"Old|Test": {"track_id": 1}}}), encoding="utf-8")
        log = self.root / "mixpool/logs/pull-liked.log"
        log.write_text("x", encoding="utf-8")
        os.utime(log, (self.t0 - 9 * 86400, self.t0 - 9 * 86400))
        (self.root / "tv-storage.json").write_text(json.dumps({"onto.tv.likes": "{}"}), encoding="utf-8")
        self.cfg["sources"] = ["tv", "video"]
        self.assertEqual(ms.cmd_collect(self.cfg), 0)
        doc = json.loads((self.share / "signals-testhost.json").read_text(encoding="utf-8"))
        self.assertEqual(doc["sources"]["apple-music"], {"ok": False, "count": 0, "error": "off"})
        self.assertNotIn(ms.track_key("Old", "Test"), doc["tracks"])
        self.run_check()
        names = [r["name"] for r in json.loads((self.state / "check.json").read_text(encoding="utf-8"))["rows"]]
        self.assertIn("favourites", names)   # unfiltered: the leftover shows (and fails)
        self.cfg["check"]["rows"] = ["ledger", "tv likes"]
        self.run_check()
        doc = json.loads((self.state / "check.json").read_text(encoding="utf-8"))
        self.assertEqual(sorted(r["name"] for r in doc["rows"]), ["ledger", "tv likes"])
        self.assertEqual(doc["status"], "pass")   # 'off' sources are not a ledger warning

    def test_rows_from_another_mac_carry_its_name(self):
        self.write_ledger()
        peer = {"version": 1, "host": "other", "generated": int(self.t0), "status": "fail",
                "rows": [{"key": "media:upload", "status": "fail", "name": "upload", "host": "other",
                          "value": "failed", "datum": "", "detail": "failed 2 h ago"}]}
        (self.share / "check-other.json").write_text(json.dumps(peer), encoding="utf-8")
        os.utime(self.share / "check-other.json", (self.t0, self.t0))
        self.run_check()
        doc = json.loads((self.state / "check.json").read_text(encoding="utf-8"))
        row = [r for r in doc["rows"] if r["host"] == "other"][0]
        self.assertEqual((row["name"], row["key"], row["status"]), ("other upload", "media:other:upload", "fail"))
        self.assertEqual(doc["datum"], "other upload")
        # What this Mac publishes for the others holds only its own rows.
        mine = json.loads((self.share / "check-testhost.json").read_text(encoding="utf-8"))
        self.assertFalse([r for r in mine["rows"] if r.get("host") == "other"])

    def test_shazam_waiting_warn(self):
        self.write_shazam_db()
        ms.cmd_collect(self.cfg)
        merged_key = ms.track_key("Example Artist", "Example Song")
        self.share / "signals-testhost.json"
        self.run_check()
        fresh_cutoff = datetime.fromtimestamp(self.t0, tz=timezone.utc) - timedelta(days=5)
        at = fresh_cutoff.strftime("%Y-%m-%dT%H:%M:%SZ")
        doc = json.loads((self.share / "signals-testhost.json").read_text(encoding="utf-8"))
        doc["tracks"][merged_key]["signals"][0]["at"] = at
        (self.share / "signals-testhost.json").write_text(json.dumps(doc), encoding="utf-8")
        self.run_check()
        out = json.loads((self.state / "check.json").read_text(encoding="utf-8"))
        shazam_rows = [r for r in out["rows"] if r["name"] == "shazam"]
        self.assertTrue(shazam_rows)
        self.assertEqual(shazam_rows[0]["status"], "warn")

    def test_favourites_share_warn(self):
        Path(self.cfg["liked_pulled"]).write_text(
            json.dumps({"done": {"a|b": {}}, "failed": {f"k{i}|t": {} for i in range(20)}}),
            encoding="utf-8",
        )
        (Path(self.cfg["mixpool_state"]) / "logs/pull-liked.log").write_text("ok\n", encoding="utf-8")
        self.write_ledger(age_h=0)
        self.run_check()
        doc = json.loads((self.state / "check.json").read_text(encoding="utf-8"))
        fav = [r for r in doc["rows"] if r["name"] == "favourites"][0]
        self.assertEqual(fav["status"], "warn")

    def test_peer_stale_and_strict_exit(self):
        self.write_ledger(age_h=0)
        peer = self.share / "check-peer.json"
        peer.write_text(json.dumps({"version": 1, "host": "peer", "rows": [ms.make_row("upload", "pass", "ok", "peer")]}), encoding="utf-8")
        old = self.t0 - 60 * 3600
        os.utime(peer, (old, old))
        self.run_check()
        doc = json.loads((self.state / "check.json").read_text(encoding="utf-8"))
        self.assertTrue(any("stale" in r.get("value", "") for r in doc["rows"]))
        push = self.root / "mlib/push-status.json"
        push.write_text(json.dumps({"ok": False, "error": "disk full", "epoch": self.t0}), encoding="utf-8")
        rc = self.run_check(strict=True)
        self.assertEqual(rc, 1)
        rc = self.run_check(strict=False)
        self.assertEqual(rc, 0)


class MalformedTest(MediaSyncTestBase):
    def test_malformed_hearts(self):
        Path(self.cfg["hearts_path"]).write_text("{not json", encoding="utf-8")
        st, _ = ms.collect_hearts(self.cfg)
        self.assertFalse(st["ok"])


if __name__ == "__main__":
    unittest.main()