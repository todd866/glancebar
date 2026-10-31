#!/usr/bin/env python3
"""Local tests for likes sync. No network and no osascript; runners are fakes."""

from __future__ import annotations

import base64
import io
import json
import os
import re
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import likes_sync


def silence(func, *args, **kwargs):
    out = io.StringIO()
    err = io.StringIO()
    with redirect_stdout(out), redirect_stderr(err):
        result = func(*args, **kwargs)
    return result, out.getvalue(), err.getvalue()


def library_text(rows: list[tuple[str, str, str, str, str]]) -> str:
    return likes_sync.RS.join(likes_sync.US.join(row) for row in rows)


def decode_js(script: str) -> str:
    match = re.search(r"atob\('([A-Za-z0-9+/=]+)'\)", script)
    if not match:
        raise AssertionError("osascript did not carry a JavaScript payload")
    return base64.b64decode(match.group(1)).decode()


class Rng:
    def __init__(self):
        self.calls = []

    def uniform(self, low, high):
        self.calls.append((low, high))
        return 2.5


class ScriptedOSA:
    """Answers the AppleScript this tool sends, including JavaScript carried in the tab."""

    def __init__(self, library: str = "", songs: list | None = None, fail: str = ""):
        self.library = library
        self.search_payload = {"done": True, "ok": True, "songs": songs or []}
        self.love_payload = {"done": True, "ok": True, "id": "1"}
        self.like_payload = {"done": True, "ok": True, "videoId": "v"}
        self.fail = fail
        self.scripts: list[str] = []
        self.phase = ""
        self.closed = 0
        self.loved: list[str] = []
        self.liked: list[str] = []
        self.favorited: list[str] = []

    def __call__(self, source: str) -> str:
        self.scripts.append(source)
        if "persistent ID of every track" in source:
            return self.library
        if "set favorited" in source:
            self.favorited.append(source)
            return "ok\n"
        if "make new tab" in source:
            return "15,27\n"
        if "\nclose t\n" in source:
            self.closed += 1
            return "closed\n"
        if "loading of t" in source:
            return "ready\n"
        if "execute javascript" in source:
            if self.fail == "javascript":
                raise RuntimeError(
                    "Executing JavaScript through AppleScript is turned off. "
                    "Allow JavaScript from Apple Events"
                )
            return self._js(decode_js(source))
        raise AssertionError("unexpected osascript:\n" + source[:400])

    def _js(self, source: str) -> str:
        if "JSON.stringify(r)" in source:
            return self._poll()
        if "isAuthorized" in source:
            return "yes"
        if "/like/like" in source:
            self.phase = "like"
            self.liked.append(source)
            return "started"
        if "EgWKAQIIAWoKEAkQBRAKEAMQBA==" in source:
            self.phase = "yt-search"
            return "started"
        if "/v1/catalog/" in source and "search" in source:
            self.phase = "am-search"
            return "started"
        if "/v1/me/library" in source:
            self.phase = "love"
            self.loved.append(source)
            return "started"
        if 'return "yes"' in source:
            return "yes"
        raise AssertionError("unexpected javascript:\n" + source[:400])

    def _poll(self) -> str:
        payload = {
            "am-search": self.search_payload,
            "love": self.love_payload,
            "yt-search": self.search_payload,
            "like": self.like_payload,
        }.get(self.phase)
        if payload is None:
            raise AssertionError(f"polled before a request started ({self.phase})")
        return json.dumps(payload)


def runners_for(osa: ScriptedOSA, sleeps: list | None = None):
    rng = Rng()
    bucket = sleeps if sleeps is not None else []
    runners = likes_sync.Runners(
        osascript=osa,
        mdls=lambda _path: "",
        ffprobe=lambda _path: "",
        which=lambda _name: None,
        sleep=bucket.append,
        clock=lambda: "2026-11-01T00:00:00Z",
        rng=rng,
    )
    return runners, rng


class NormaliseTests(unittest.TestCase):
    def test_feat_remaster_official_topic_and_punctuation(self):
        self.assertEqual(
            likes_sync.normalise("AC/DC", "Don't Stop (feat. Someone) - Remastered 2011"),
            ("ac dc", "dont stop"),
        )
        self.assertEqual(
            likes_sync.normalise("Queen", "Don't Stop Me Now (Official Video)"),
            ("queen", "dont stop me now"),
        )
        self.assertEqual(likes_sync.normalise("Band - Topic", "Song"), ("band", "song"))
        self.assertEqual(likes_sync.normalise("Band \u2013 Topic", "Song (Official Music Video)"), ("band", "song"))
        self.assertEqual(likes_sync.normalise("Band", "Song (2011 Remaster)"), ("band", "song"))
        self.assertEqual(likes_sync.normalise("Band", "Song - 2011 Remaster"), ("band", "song"))
        self.assertEqual(likes_sync.normalise("Band", "Song (featuring Pal)"), ("band", "song"))
        self.assertEqual(
            likes_sync.normalise("Tyler Childers", "Feathered Indians"),
            ("tyler childers", "feathered indians"),
        )

    def test_empty_stays_empty(self):
        self.assertEqual(likes_sync.normalise("", "   "), ("", ""))
        self.assertFalse(likes_sync.has_names(" - Topic", "(Official Video)"))


class MatchTests(unittest.TestCase):
    def test_decoration_variants_match_exactly(self):
        plan = likes_sync.build_plan(
            [
                {"videoId": "1", "artist": "Band - Topic", "title": "Song (feat. Pal)"},
                {"videoId": "2", "artist": "Queen", "title": "Don't Stop Me Now (Official Video)"},
                {"videoId": "3", "artist": "Solo", "title": "Only Here"},
            ],
            [
                {"pid": "b", "artist": "Band", "title": "Song - Remastered 2011", "album": "LP"},
                {"pid": "q", "artist": "Queen", "title": "Don't Stop Me Now", "album": "Jazz"},
                {"pid": "o", "artist": "Other", "title": "Apple Only", "album": ""},
            ],
        )
        self.assertEqual([row["yt"]["videoId"] for row in plan["matched"]], ["1", "2"])
        self.assertTrue(all(row["how"] == "exact" and row["ratio"] == 1.0 for row in plan["matched"]))
        self.assertEqual(plan["yt_only"], [{"videoId": "3", "title": "Only Here", "artist": "Solo"}])
        self.assertEqual(plan["am_only"], [{"pid": "o", "title": "Apple Only", "artist": "Other", "album": ""}])
        self.assertEqual(plan["matched"][0]["am"]["album"], "LP")

    def test_fuzzy_threshold(self):
        above = likes_sync.pair_score(
            {"artist": "Radiohead", "title": "Creep"},
            {"artist": "Radiohead", "title": "Crep"},
        )
        below = likes_sync.pair_score(
            {"artist": "Artist", "title": "Title"},
            {"artist": "Artist", "title": "Tt"},
        )
        self.assertGreaterEqual(above, likes_sync.FUZZY_MIN)
        self.assertLess(below, likes_sync.FUZZY_MIN)
        plan = likes_sync.build_plan(
            [
                {"videoId": "y1", "artist": "Radiohead", "title": "Crep"},
                {"videoId": "y2", "artist": "Artist", "title": "Title"},
            ],
            [
                {"pid": "a1", "artist": "Radiohead", "title": "Creep", "album": "Pablo Honey"},
                {"pid": "a2", "artist": "Artist", "title": "Tt", "album": ""},
            ],
        )
        self.assertEqual([row["yt"]["videoId"] for row in plan["matched"]], ["y1"])
        self.assertEqual(plan["matched"][0]["how"], "fuzzy")
        self.assertGreaterEqual(plan["matched"][0]["ratio"], likes_sync.FUZZY_MIN)
        self.assertEqual([row["videoId"] for row in plan["yt_only"]], ["y2"])
        self.assertEqual([row["pid"] for row in plan["am_only"]], ["a2"])

    def test_one_favourite_matches_once(self):
        plan = likes_sync.build_plan(
            [
                {"videoId": "1", "artist": "Band", "title": "Song (feat. A)"},
                {"videoId": "2", "artist": "Band - Topic", "title": "Song"},
            ],
            [{"pid": "b", "artist": "Band", "title": "Song", "album": ""}],
        )
        self.assertEqual([row["yt"]["videoId"] for row in plan["matched"]], ["1"])
        self.assertEqual([row["videoId"] for row in plan["yt_only"]], ["2"])
        self.assertEqual(plan["am_only"], [])

    def test_catalog_hit_requires_the_same_artist(self):
        songs = [
            {"id": "wrong", "title": "Song", "artist": "Someone Else"},
            {"id": "right", "title": "Song - Remastered", "artist": "Band - Topic"},
        ]
        chosen = likes_sync.pick_hit("Band", "Song (feat. Pal)", songs)
        self.assertEqual(chosen["id"], "right")
        self.assertIsNone(likes_sync.pick_hit("Band", "Song", [songs[0]]))
        self.assertIsNone(likes_sync.pick_hit("Artist", "Title", [{"id": "x", "artist": "Artist", "title": "Tt"}]))
        typo = likes_sync.pick_hit(
            "Radiohead",
            "Creep",
            [{"id": "c", "artist": "Radiohead", "title": "Crep"}],
        )
        self.assertEqual(typo["id"], "c")


class ArchiveAndLibraryTests(unittest.TestCase):
    def test_archive_filenames_mdls_and_ffprobe(self):
        self.assertEqual(likes_sync.parse_archive("youtube AbC_def-123\n\nSoundCloud nope\n"), ["AbC_def-123"])
        parsed = likes_sync.parse_filename("Artist - Title [abc_1].m4a")
        self.assertEqual(parsed, {"artist": "Artist", "title": "Title", "videoId": "abc_1"})
        loose = likes_sync.parse_filename("/Music/YouTube Liked/Loose name.m4a")
        self.assertEqual(loose["videoId"], "")
        self.assertEqual(loose["title"], "")
        upper = likes_sync.parse_filename("Other - Song [Zz9].M4A")
        self.assertEqual(upper["videoId"], "Zz9")
        mdls = "kMDItemTitle = \"Hello\"\nkMDItemAuthors = (\n    \"Adele\"\n)\n"
        self.assertEqual(likes_sync.parse_mdls(mdls), ("Hello", "Adele"))
        self.assertEqual(likes_sync.parse_mdls('kMDItemTitle = (null)\nkMDItemAuthors = (null)\n'), ("", ""))
        self.assertEqual(likes_sync.parse_mdls('kMDItemAuthors = "Solo"\n'), ("", "Solo"))
        probed = json.dumps(
            {
                "format": {"tags": {"title": "From Format", "artist": "Format Artist"}},
                "streams": [{"tags": {"TITLE": "From Stream", "ARTIST": "Stream Artist"}}],
            }
        )
        self.assertEqual(likes_sync.parse_ffprobe(probed), ("From Format", "Format Artist"))
        streams_only = json.dumps({"streams": [{"tags": {"TITLE": "Stream Title", "ARTIST": "Stream Artist"}}]})
        self.assertEqual(likes_sync.parse_ffprobe(streams_only), ("Stream Title", "Stream Artist"))

    def test_library_separators_and_favourites_only(self):
        text = library_text(
            [
                ("PID1", "Name, with comma", "Artist", "Album", "true"),
                ("PID2", "Other", "Someone", "Alb", "false"),
            ]
        )
        tracks = likes_sync.parse_library(text + "\n")
        self.assertEqual(len(tracks), 2)
        self.assertTrue(tracks[0]["favorited"])
        self.assertFalse(tracks[1]["favorited"])
        self.assertEqual(likes_sync.favourites(tracks), [
            {"pid": "PID1", "title": "Name, with comma", "artist": "Artist", "album": "Album"},
        ])
        script = likes_sync.LIBRARY_SCRIPT
        for phrase in (
            "library playlist 1",
            "persistent ID of every track",
            "name of every track",
            "artist of every track",
            "album of every track",
            "favorited of every track",
        ):
            self.assertIn(phrase, script)

    def test_writes_never_remove_a_like(self):
        favourite = likes_sync.favorite_script("PID")
        self.assertIn("to true", favourite)
        self.assertNotIn("false", favourite)
        love = likes_sync.catalog_love_js("123")
        self.assertIn("/v1/me/library?ids[songs]=", love)
        self.assertIn("/v1/me/ratings/songs/", love)
        self.assertIn("value: 1", love)
        self.assertNotIn("value: -1", love)
        self.assertNotIn("dislike", love.lower())
        like = likes_sync.yt_like_js("dQw4w9WgXcQ")
        self.assertIn("/like/like", like)
        self.assertIn("dQw4w9WgXcQ", like)
        self.assertIn("SAPISID", like)
        self.assertNotIn("removelike", like)
        search = likes_sync.yt_search_js("query")
        self.assertIn("EgWKAQIIAWoKEAkQBRAKEAMQBA==", search)
        self.assertIn("/v1/catalog/au/search", likes_sync.catalog_search_js("query"))
        wrapped = likes_sync.js_wrapper("return \"yes\"")
        self.assertNotIn('"', wrapped)


class ApplyBookkeepingTests(unittest.TestCase):
    def test_jsonl_skips_only_ok(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "applied.jsonl"
            path.write_text("\nnot json\n", encoding="utf-8")
            likes_sync.append_applied(
                path,
                {"at": "t", "side": "yt", "key": "a", "action": "yt-like", "result": "ok", "ids": {"videoId": "v"}},
            )
            likes_sync.append_applied(
                path,
                {"at": "t", "side": "yt", "key": "b", "action": "yt-like", "result": "error", "ids": {}},
            )
            likes_sync.append_applied(
                path,
                {"at": "t", "side": "yt", "key": "a", "action": "yt-like", "result": "error", "ids": {}},
            )
            likes_sync.append_applied(
                path,
                {"at": "t", "side": "am", "key": "c", "action": "catalog-search", "result": "no-match", "ids": {}},
            )
            self.assertEqual(likes_sync.load_applied_ok(path), {("yt", "a")})
            line = [json.loads(item) for item in path.read_text(encoding="utf-8").splitlines() if item.startswith("{")][0]
            self.assertEqual(list(line.keys()), ["at", "side", "key", "action", "result", "ids"])

    def _run(self, results, items, applied_ok=None, limit=25):
        cursor = {"n": 0}
        calls = []
        sleeps = []
        recorded = []

        def perform(item):
            calls.append(likes_sync.track_key("yt", item))
            result = results[cursor["n"]]
            cursor["n"] += 1
            return {"action": "yt-like", "result": result, "ids": {"videoId": "v"}}

        runners, rng = runners_for(ScriptedOSA(), sleeps)
        outcomes, stopped = silence(
            likes_sync.run_apply,
            items,
            side="yt",
            limit=limit,
            applied_ok=applied_ok or set(),
            perform=perform,
            runners=runners,
            record=recorded.append,
            dry_run=False,
        )[0]
        return calls, outcomes, stopped, sleeps, recorded, rng

    def test_skips_successful_keys_and_limit(self):
        items = [{"pid": str(i), "title": "T", "artist": "A", "album": ""} for i in range(5)]
        calls, outcomes, stopped, sleeps, _recorded, rng = self._run(
            ["ok", "ok"],
            items,
            applied_ok={("yt", "0")},
            limit=2,
        )
        self.assertEqual(calls, ["1", "2"])
        self.assertFalse(stopped)
        self.assertEqual(len(outcomes), 2)
        self.assertEqual(sleeps, [2.5])
        self.assertEqual(rng.calls, [(likes_sync.PAUSE_MIN, likes_sync.PAUSE_MAX)])

    def test_three_errors_stop_and_a_success_resets_the_streak(self):
        items = [{"pid": str(i), "title": "T", "artist": "A", "album": ""} for i in range(8)]
        calls, outcomes, stopped, sleeps, recorded, _rng = self._run(
            ["error", "error", "ok", "error", "error", "error", "ok"],
            items,
        )
        self.assertEqual(calls, ["0", "1", "2", "3", "4", "5"])
        self.assertTrue(stopped)
        self.assertEqual([row["result"] for row in outcomes], ["error", "error", "ok", "error", "error", "error"])
        self.assertEqual(len(recorded), 6)
        self.assertEqual(len(sleeps), 5)
        self.assertEqual(outcomes[0]["at"], "2026-11-01T00:00:00Z")

        reset_calls, reset_outcomes, reset_stopped, _sleeps, _recorded, _rng = self._run(
            ["error", "error", "no-match", "error", "error", "ok"],
            items[:6],
        )
        self.assertEqual(reset_calls, ["0", "1", "2", "3", "4", "5"])
        self.assertFalse(reset_stopped)
        self.assertEqual(reset_outcomes[2]["result"], "no-match")

    def test_dry_run_prints_and_does_not_write(self):
        items = [
            {"pid": "1", "title": "Song", "artist": "Band", "album": ""},
            {"pid": "2", "title": "Other", "artist": "Band", "album": ""},
        ]
        sleeps = []
        runners, _rng = runners_for(ScriptedOSA(), sleeps)
        called = []
        recorded = []
        _result, stdout, _stderr = silence(
            likes_sync.run_apply,
            items,
            side="yt",
            limit=25,
            applied_ok={("yt", "1")},
            perform=lambda item: called.append(item),
            runners=runners,
            record=recorded.append,
            dry_run=True,
        )
        self.assertEqual(called, [])
        self.assertEqual(recorded, [])
        self.assertEqual(sleeps, [])
        self.assertIn("dry-run yt 2 Band — Other: like on YouTube Music", stdout)
        self.assertNotIn("pid 1", stdout)
        self.assertIn("pass --apply", stdout)


class AccountApplyTests(unittest.TestCase):
    def test_library_hit_favourites_without_opening_chrome(self):
        osa = ScriptedOSA(
            library=library_text([("P123", "Song - Remastered 2011", "Band", "LP", "false")])
        )
        runners, _rng = runners_for(osa)
        recorded = []
        outcomes, stopped = silence(
            likes_sync.apply_apple,
            [{"videoId": "v", "title": "Song (feat. Pal)", "artist": "Band - Topic"}],
            runners,
            recorded.append,
            25,
            set(),
        )[0]
        self.assertFalse(stopped)
        self.assertEqual(outcomes[0]["action"], "set-favorited")
        self.assertEqual(outcomes[0]["result"], "ok")
        self.assertEqual(outcomes[0]["ids"], {"videoId": "v", "pid": "P123"})
        self.assertEqual(osa.closed, 0)
        self.assertFalse(any("make new tab" in script for script in osa.scripts))
        self.assertIn("P123", osa.favorited[0])
        self.assertIn("to true", osa.favorited[0])

    def test_catalog_artist_mismatch_is_no_match(self):
        osa = ScriptedOSA(songs=[{"id": "999", "title": "Song", "artist": "Someone Else"}])
        runners, _rng = runners_for(osa)
        recorded = []
        outcomes, stopped = silence(
            likes_sync.apply_apple,
            [{"videoId": "v", "title": "Song", "artist": "Band"}],
            runners,
            recorded.append,
            25,
            set(),
        )[0]
        self.assertFalse(stopped)
        self.assertEqual(outcomes[0]["result"], "no-match")
        self.assertEqual(outcomes[0]["action"], "catalog-search")
        self.assertEqual(osa.loved, [])
        self.assertEqual(osa.favorited, [])
        self.assertEqual(osa.closed, 1)

    def test_catalog_match_adds_and_loves(self):
        osa = ScriptedOSA(
            songs=[{"id": "999", "title": "Song - Remastered 2011", "artist": "Band - Topic"}]
        )
        runners, _rng = runners_for(osa)
        outcomes, stopped = silence(
            likes_sync.apply_apple,
            [{"videoId": "v", "title": "Song (feat. Pal)", "artist": "Band"}],
            runners,
            None,
            25,
            set(),
        )[0]
        self.assertFalse(stopped)
        self.assertEqual(outcomes[0]["action"], "catalog-add-love")
        self.assertEqual(outcomes[0]["ids"]["catalogId"], "999")
        self.assertEqual(len(osa.loved), 1)
        self.assertIn("/v1/me/library?ids[songs]=", osa.loved[0])
        self.assertIn("999", osa.loved[0])
        self.assertIn("value: 1", osa.loved[0])
        self.assertNotIn("removelike", osa.loved[0])
        self.assertEqual(osa.closed, 1)
        self.assertIn("https://music.apple.com", osa.scripts[1])

    def test_youtube_like_and_artist_mismatch(self):
        osa = ScriptedOSA(songs=[{"videoId": "abc_1", "title": "Song", "artist": "Band"}])
        runners, _rng = runners_for(osa)
        outcomes, _stopped = silence(
            likes_sync.apply_youtube,
            [{"pid": "P1", "title": "Song (Official Video)", "artist": "Band - Topic", "album": ""}],
            runners,
            None,
            25,
            set(),
        )[0]
        self.assertEqual(outcomes[0]["action"], "yt-like")
        self.assertEqual(outcomes[0]["ids"], {"pid": "P1", "videoId": "abc_1"})
        self.assertEqual(len(osa.liked), 1)
        self.assertIn("/like/like", osa.liked[0])
        self.assertIn("abc_1", osa.liked[0])
        self.assertNotIn("removelike", osa.liked[0])
        self.assertTrue(any("EgWKAQIIAWoKEAkQBRAKEAMQBA==" in decode_js(script) for script in osa.scripts if "execute javascript" in script))
        self.assertEqual(osa.closed, 1)

        mismatch = ScriptedOSA(songs=[{"videoId": "abc_1", "title": "Song", "artist": "Someone Else"}])
        mismatch_runners, _rng = runners_for(mismatch)
        missed, _stopped = silence(
            likes_sync.apply_youtube,
            [{"pid": "P2", "title": "Song", "artist": "Band", "album": ""}],
            mismatch_runners,
            None,
            25,
            set(),
        )[0]
        self.assertEqual(missed[0]["result"], "no-match")
        self.assertEqual(mismatch.liked, [])
        self.assertEqual(mismatch.closed, 1)

    def test_javascript_permission_closes_the_tab(self):
        osa = ScriptedOSA(fail="javascript")
        runners, _rng = runners_for(osa)
        with self.assertRaises(SystemExit) as caught:
            silence(
                likes_sync.apply_apple,
                [{"videoId": "v", "title": "Song", "artist": "Band"}],
                runners,
                None,
                25,
                set(),
            )
        self.assertIn("Allow JavaScript from Apple Events", str(caught.exception))
        self.assertEqual(osa.closed, 1)

    def test_three_search_errors_stop(self):
        osa = ScriptedOSA()
        osa.search_payload = {"done": True, "ok": False, "error": "down"}
        sleeps = []
        runners, rng = runners_for(osa, sleeps)
        items = [{"videoId": str(i), "title": "Song", "artist": "Band"} for i in range(4)]
        recorded = []
        outcomes, stopped = silence(
            likes_sync.apply_apple,
            items,
            runners,
            recorded.append,
            25,
            set(),
        )[0]
        self.assertTrue(stopped)
        self.assertEqual([row["key"] for row in outcomes], ["0", "1", "2"])
        self.assertTrue(all(row["result"] == "error" for row in outcomes))
        self.assertEqual(len(recorded), 3)
        self.assertEqual(osa.loved, [])
        self.assertEqual(osa.closed, 1)
        self.assertEqual(sleeps, [2.5, 2.5])
        self.assertEqual(rng.calls, [(2.0, 4.0), (2.0, 4.0)])

    def test_already_applied_does_not_open_music(self):
        osa = ScriptedOSA()
        runners, _rng = runners_for(osa)
        outcomes, stopped = silence(
            likes_sync.apply_apple,
            [{"videoId": "v", "title": "Song", "artist": "Band"}],
            runners,
            None,
            25,
            {("am", "v")},
        )[0]
        self.assertEqual(outcomes, [])
        self.assertFalse(stopped)
        self.assertEqual(osa.scripts, [])

    def test_blank_names_do_not_search(self):
        osa = ScriptedOSA()
        runners, _rng = runners_for(osa)
        outcomes, _stopped = silence(
            likes_sync.apply_youtube,
            [{"pid": "P", "title": "", "artist": "", "album": ""}],
            runners,
            None,
            25,
            set(),
        )[0]
        self.assertEqual(outcomes[0]["result"], "no-match")
        self.assertEqual(osa.scripts, [])
        self.assertEqual(osa.closed, 0)


class CommandTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.previous = os.environ.get("MUSIC_SYNC_STATE")
        os.environ["MUSIC_SYNC_STATE"] = self.tmp.name

    def tearDown(self):
        if self.previous is None:
            os.environ.pop("MUSIC_SYNC_STATE", None)
        else:
            os.environ["MUSIC_SYNC_STATE"] = self.previous
        self.tmp.cleanup()

    def test_inventory_joins_archive_tags_and_favourites(self):
        root = Path(self.tmp.name)
        archive = root / "archive.txt"
        archive.write_text("youtube vid11111111\nyoutube vid11111111\nyoutube vid22222222\nSoundCloud skip\n", encoding="utf-8")
        yt_dir = root / "liked"
        yt_dir.mkdir()
        (yt_dir / "Wrong - Name [vid11111111].m4a").write_bytes(b"")
        (yt_dir / "File Artist - File Title [vid22222222].m4a").write_bytes(b"")
        (yt_dir / "note.txt").write_text("nope", encoding="utf-8")
        (yt_dir / ".hidden [vid33333333].m4a").write_bytes(b"")
        (yt_dir / "Not In Archive - Song [vid44444444].m4a").write_bytes(b"")

        def mdls(path):
            if "vid11111111" in path:
                return 'kMDItemTitle = "Tagged Title"\nkMDItemAuthors = (\n    "Tagged Artist"\n)\n'
            if not path.endswith(".m4a"):
                raise AssertionError(path)
            return "kMDItemTitle = (null)\nkMDItemAuthors = (null)\n"

        def ffprobe(_path):
            raise AssertionError("ffprobe should not run when it is absent")

        osa = ScriptedOSA(
            library=library_text(
                [
                    ("PID1", "Loved", "Artist", "Album", "true"),
                    ("PID2", "Nope", "Artist", "Album", "false"),
                ]
            )
        )
        tool_runners = likes_sync.Runners(osascript=osa, mdls=mdls, ffprobe=ffprobe, which=lambda _name: None)
        code, stdout, _stderr = silence(
            likes_sync.main,
            ["inventory", "--archive", str(archive), "--yt-dir", str(yt_dir)],
            tool_runners,
        )
        self.assertEqual(code, 0)
        self.assertIn("inventory", stdout)
        data = json.loads((root / "inventory.json").read_text(encoding="utf-8"))
        self.assertEqual(list(data.keys()), ["yt", "am_fav"])
        self.assertEqual(
            data["yt"],
            [
                {"videoId": "vid11111111", "title": "Tagged Title", "artist": "Tagged Artist"},
                {"videoId": "vid22222222", "title": "File Title", "artist": "File Artist"},
            ],
        )
        self.assertEqual(data["am_fav"], [{"pid": "PID1", "title": "Loved", "artist": "Artist", "album": "Album"}])
        self.assertIn("favorited of every track", osa.scripts[0])

        code, _stdout, _stderr = silence(likes_sync.main, ["plan"], tool_runners)
        self.assertEqual(code, 0)
        plan = json.loads((root / "plan.json").read_text(encoding="utf-8"))
        self.assertEqual(set(plan.keys()), {"yt_only", "am_only", "matched"})

    def test_ffprobe_tags_win_when_present(self):
        root = Path(self.tmp.name)
        yt_dir = root / "liked"
        yt_dir.mkdir()
        (yt_dir / "File Artist - File Title [vid11111111].m4a").write_bytes(b"")
        archive = root / "archive.txt"
        archive.write_text("youtube vid11111111\n", encoding="utf-8")

        def ffprobe(_path):
            return json.dumps({"format": {"tags": {"title": "Probe Title", "artist": "Probe Artist"}}})

        def mdls(_path):
            raise AssertionError("mdls is the fallback when ffprobe already has both tags")

        runners = likes_sync.Runners(
            osascript=lambda _source: "",
            mdls=mdls,
            ffprobe=ffprobe,
            which=lambda name: "/usr/bin/ffprobe" if name == "ffprobe" else None,
        )
        rows = likes_sync.collect_youtube(archive, yt_dir, runners)
        self.assertEqual(rows, [{"videoId": "vid11111111", "title": "Probe Title", "artist": "Probe Artist"}])

    def test_apply_dry_run_does_not_touch_accounts(self):
        root = Path(self.tmp.name)
        plan = {
            "yt_only": [{"videoId": "v1", "title": "Song", "artist": "Band"}],
            "am_only": [{"pid": "P1", "title": "Other", "artist": "Band", "album": ""}],
            "matched": [],
        }
        (root / "plan.json").write_text(json.dumps(plan), encoding="utf-8")
        likes_sync.append_applied(
            root / "applied.jsonl",
            {"at": "t", "side": "am", "key": "v1", "action": "set-favorited", "result": "ok", "ids": {}},
        )

        def boom(*_args, **_kwargs):
            raise AssertionError("dry-run touched an account runner")

        tool_runners = likes_sync.Runners(osascript=boom, mdls=boom, ffprobe=boom, sleep=boom)
        args = likes_sync.build_parser().parse_args(["apply", "--side", "am"])
        self.assertEqual(args.limit, 25)
        self.assertFalse(args.apply)
        code, stdout, _stderr = silence(likes_sync.main, ["apply", "--side", "am", "--limit", "25"], tool_runners)
        self.assertEqual(code, 0)
        self.assertIn("nothing to do", stdout)
        code, stdout, _stderr = silence(likes_sync.main, ["apply", "--side", "yt"], tool_runners)
        self.assertEqual(code, 0)
        self.assertIn("dry-run yt P1 Band — Other: like on YouTube Music", stdout)
        applied = (root / "applied.jsonl").read_text(encoding="utf-8")
        self.assertNotIn("yt-like", applied)
        self.assertEqual(applied.count("\n"), 1)

    def test_missing_archive_does_not_open_music(self):
        def boom(_source):
            raise AssertionError("Music was opened")

        with self.assertRaises(SystemExit) as caught:
            silence(
                likes_sync.main,
                ["inventory", "--archive", str(Path(self.tmp.name) / "missing.txt")],
                likes_sync.Runners(osascript=boom),
            )
        self.assertIn("archive not found", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
