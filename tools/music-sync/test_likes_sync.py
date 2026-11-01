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


def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def make_jwt(alg: str, exp: int, kid: str = "TESTKEY1") -> str:
    header = {"alg": alg}
    if kid:
        header["kid"] = kid
    payload = {"exp": exp}
    parts = [
        b64url(json.dumps(header, separators=(",", ":")).encode()),
        b64url(json.dumps(payload, separators=(",", ":")).encode()),
        b64url(b"signature-bytes"),
    ]
    return ".".join(parts)


# Public fixture. The ES256 token is the one the bundle snippet carries; the HS256 one is a decoy.
APPLE_DEV_EXP = 2_000_000_000
APPLE_DEV_EXP_TEXT = "2033-05-18T03:33:20Z"
APPLE_DEV_TOKEN = (
    "eyJhbGciOiJFUzI1NiIsImtpZCI6IlRFU1RLRVkxIn0"
    ".eyJleHAiOjIwMDAwMDAwMDB9"
    ".c2lnbmF0dXJlLWJ5dGVz"
)
APPLE_HS256_TOKEN = "eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjIwMDAwMDAwMDB9.c2lnbmF0dXJlLWJ5dGVz"
APPLE_HOME_HTML = """<!DOCTYPE html>
<html><head>
<script src="/assets/vendor-aaa.js"></script>
<script type="module" crossorigin src="/assets/index~abc123.js"></script>
</head></html>
"""
APPLE_BUNDLE_JS = (
    "/* apple music web player */\n"
    'var config = {"developerToken":"' + APPLE_DEV_TOKEN + '"};\n'
    'var ignored = "' + APPLE_HS256_TOKEN + '";\n'
)
VENDOR_JS = 'var vendor = "' + APPLE_HS256_TOKEN + '";\n'


def apple_pages(html: str = APPLE_HOME_HTML, bundle: str = APPLE_BUNDLE_JS, vendor: str = VENDOR_JS) -> dict:
    pages = {
        "https://music.apple.com/": html,
        "https://music.apple.com/au/home": html,
    }
    for url in likes_sync.apple_bundle_urls(html):
        pages[url] = vendor if "vendor" in url else bundle
    return pages


def mapped_fetch(pages: dict, seen: list | None = None):
    urls = seen if seen is not None else []

    def fetch(url: str) -> str:
        urls.append(url)
        if url not in pages:
            raise RuntimeError("unexpected url " + url)
        body = pages[url]
        if isinstance(body, Exception):
            raise body
        return body

    return fetch, urls


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
        if "javascript" in source and "execute" in source:
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
        if "ms-auth-am" in source:
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
    fetch, fetched = mapped_fetch(apple_pages())
    runners = likes_sync.Runners(
        osascript=osa,
        mdls=lambda _path: "",
        ffprobe=lambda _path: "",
        which=lambda _name: None,
        sleep=bucket.append,
        clock=lambda: "2026-11-01T00:00:00Z",
        rng=rng,
        fetch=fetch,
    )
    runners.fetched = fetched
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


def _yt(video_id: str, artist: str, title: str, **extra) -> dict:
    row = {"videoId": video_id, "artist": artist, "title": title}
    row.update(extra)
    return row


def _am(pid: str, artist: str, title: str, album: str = "") -> dict:
    return {"pid": pid, "artist": artist, "title": title, "album": album}


class RealLibraryMatchTests(unittest.TestCase):
    """Fixtures from likes that the old normaliser left one-sided."""

    def _ids(self, plan):
        return {row["yt"]["videoId"]: row["am"]["pid"] for row in plan["matched"]}

    def test_channel_upload_uses_the_artist_inside_the_title(self):
        fixtures = [
            (
                "delete",
                "triple j",
                "DMA'S - 'Delete' (Splendour In The Grass 2018)",
                "DMA'S",
                "Delete",
            ),
            (
                "delete-en",
                "triple j",
                "DMA'S – 'Delete'",
                "DMA'S",
                "Delete",
            ),
            (
                "delete-em",
                "triple j",
                'DMA\'S — "Delete"',
                "DMA'S",
                "Delete",
            ),
            (
                "sunshine",
                "Jungle4eva",
                "Jungle - Sunshine (Official Video)",
                "Jungle",
                "Sunshine",
            ),
            (
                "another",
                "triple j",
                "Winston Surfshirt - 'Of Another Kind' Ft. Jerome Farah",
                "Winston Surfshirt",
                "Of Another Kind",
            ),
            (
                "another-live",
                "triple j",
                "Winston Surfshirt - 'Of Another Kind' Ft. Jerome Farah & Milan Ring (live for Like A Version)",
                "Winston Surfshirt",
                "Of Another Kind (feat. Milan Ring & Jerome Farah)",
            ),
            ("audio", "Ch", "Artist - Song (Official Audio)", "Artist", "Song"),
            ("lyric", "Ch", "Artist - Lyric Song (Lyric Video)", "Artist", "Lyric Song"),
            ("visual", "Ch", "Artist - Visual Song (Visualizer)", "Artist", "Visual Song"),
            ("hd", "Ch", "Artist - HD Song [HD]", "Artist", "HD Song"),
            ("liveat", "Ch", "Artist - Live Song (Live at the Enmore)", "Artist", "Live Song"),
            ("year", "Ch", "Artist - Fest Song (Falls Festival 2019)", "Artist", "Fest Song"),
            ("topic", "Band - Topic", "Real Artist - Topic Song", "Real Artist", "Topic Song"),
        ]
        youtube = [_yt(video_id, artist, title) for video_id, artist, title, _am_artist, _am_title in fixtures]
        apple = [_am(video_id, am_artist, am_title) for video_id, _artist, _title, am_artist, am_title in fixtures]
        plan = likes_sync.build_plan(youtube, apple)
        self.assertEqual(self._ids(plan), {video_id: video_id for video_id, *_rest in fixtures})
        self.assertTrue(all(row["how"] == "exact" and row["ratio"] == 1.0 for row in plan["matched"]))
        self.assertEqual(plan["yt_only"], [])
        self.assertEqual(plan["am_only"], [])
        self.assertEqual(plan["skip"], [])
        # A bare year in brackets is not a festival tag.
        self.assertEqual(
            likes_sync.normalise("Artist", "Song (2016)"),
            ("artist", "song 2016"),
        )

    def test_original_names_stay_when_the_title_split_matches_nothing(self):
        # The split reads this as artist "We Will Rock You". Nothing in the library
        # is that song, so the original Queen credit is the match.
        plan = likes_sync.build_plan(
            [_yt("q", "Queen", "We Will Rock You - Live Cut")],
            [
                _am("decoy", "We Will Rock You", "Different Title"),
                _am("real", "Queen", "We Will Rock You - Live Cut"),
            ],
        )
        self.assertEqual(self._ids(plan), {"q": "real"})
        self.assertEqual(plan["matched"][0]["how"], "exact")
        self.assertEqual([row["pid"] for row in plan["am_only"]], ["decoy"])

    def test_primary_artist_and_featured_title(self):
        fixtures = [
            (
                "rock",
                "De La Soul, MF DOOM",
                "Rock Co.Kane Flow (feat. MF DOOM)",
                "De La Soul",
                "Rock Co.Kane Flow (feat. MF DOOM)",
            ),
            (
                "stingray",
                "King Stingray, Roy Kellaway,",
                "Get Me Out",
                "King Stingray",
                "Get Me Out",
            ),
            ("fred", "Fred again . .", "glow", "Fred again..", "glow"),
            ("ex", "Fred again.. x Duskus", "ex song", "Fred again..", "ex song"),
            ("amp", "King Stingray & Roy Kellaway", "amp song", "King Stingray", "amp song"),
            ("and", "De La Soul and MF DOOM", "and song", "De La Soul", "and song"),
            ("comma", "De La Soul, MF DOOM", "comma song", "De La Soul", "comma song"),
        ]
        youtube = [_yt(video_id, artist, title) for video_id, artist, title, _a, _t in fixtures]
        apple = [_am(video_id, am_artist, am_title) for video_id, _a, _t, am_artist, am_title in fixtures]
        plan = likes_sync.build_plan(youtube, apple)
        self.assertEqual(self._ids(plan), {video_id: video_id for video_id, *_rest in fixtures})
        self.assertTrue(all(row["how"] == "exact" and row["ratio"] == 1.0 for row in plan["matched"]))
        # The featured name only has to come off the title. It does not have to be on both artists.
        bare = likes_sync.build_plan(
            [_yt("bare", "De La Soul, MF DOOM", "Rock Co.Kane Flow")],
            [_am("bare", "De La Soul", "Rock Co.Kane Flow (feat. MF DOOM)")],
        )
        self.assertEqual(self._ids(bare), {"bare": "bare"})
        self.assertEqual(bare["matched"][0]["how"], "exact")

    def test_not_songs_are_skipped_and_not_applied(self):
        rows = [
            (_yt("mixes", "Someone", "Lane 8 Summer Mixes"), "mix"),
            (_yt("mixtape", "Someone", "RJD2 Long Mixtape"), "mixtape"),
            (_yt("full-mix", "Someone", "Your Face or Your Kneecap (full mixtape)"), "full mixtape"),
            (_yt("album", "Ninja Tune", "Floating Points - 'Crush' (Full Album)"), "full album"),
            (_yt("dj", "AlphaClam", "The Avalanches — A Party For Melbourne (DJ Set)"), "dj set"),
            (_yt("boiler", "Boiler Room", "Fred again.. | Boiler Room: London"), "boiler room"),
            (_yt("tiny", "NPR Music", "Waxahatchee: Tiny Desk Concert"), "tiny desk"),
            (_yt("npr", "NPR Music", "Beirut Full Concert | NPR MUSIC FRONT ROW"), "npr music"),
            (_yt("glasto", "BBC Music", "KNEECAP - Fine Art | Glastonbury 2025"), "glastonbury"),
            (_yt("liveset", "Someone", "Saturday live set"), "live set"),
            (_yt("remixed", "The Hood Internet", "75 Songs From 2003 Remixed Into 4 Minutes"), "songs remixed"),
            (_yt("long", "Band", "A Real Song", duration=13 * 60), "longer than 12 minutes"),
            (_yt("clock", "Band", "Another Song", duration="0:12:01"), "longer than 12 minutes"),
            (_am("am-tiny", "Edward Sharpe & The Magnetic Zeros", "40 Day Dream (Live at NPR Music’s Tiny Desk Concert)"), "tiny desk"),
        ]
        kept = [
            _yt("song", "Band", "Since I Left You (Prince Paul Remix)"),
            _yt("edge", "Band", "Alter Ego (2020 Mix)", duration=likes_sync.LONG_VIDEO_SECONDS),
            _yt("archive", "The Mixtape Archive", "Kid Koala - Scratchcratchratchatch"),
        ]
        plan = likes_sync.build_plan(
            [row for row, _reason in rows if "videoId" in row] + kept,
            [row for row, _reason in rows if "pid" in row]
            + [
                _am("song", "Band", "Since I Left You (Prince Paul Remix)"),
                _am("koala", "Kid Koala", "Scratchcratchratchatch"),
            ],
        )
        self.assertEqual(
            [(row.get("videoId") or row.get("pid"), row["reason"]) for row in plan["skip"]],
            [((row.get("videoId") or row.get("pid")), reason) for row, reason in rows],
        )
        self.assertEqual(self._ids(plan), {"song": "song", "archive": "koala"})
        skipped_ids = {row.get("videoId") or row.get("pid") for row in plan["skip"]}
        for bucket in (plan["yt_only"], plan["am_only"]):
            for row in bucket:
                self.assertNotIn(row.get("videoId") or row.get("pid"), skipped_ids)
        for row in plan["matched"]:
            self.assertNotIn(row["yt"]["videoId"], skipped_ids)
            self.assertNotIn(row["am"]["pid"], skipped_ids)
        self.assertEqual([row["videoId"] for row in plan["yt_only"]], ["edge"])
        self.assertEqual(plan["am_only"], [])

    def test_like_a_version_cover_matches_the_apple_title(self):
        plan = likes_sync.build_plan(
            [
                _yt(
                    "dash",
                    "triple j",
                    "Winston Surfshirt - Kiss Me More (Like A Version)",
                ),
                _yt(
                    "cover",
                    "triple j",
                    "Winston Surfshirt cover Doja Cat 'Kiss Me More' for Like A Version Ft. Jerome Farah & Milan Ring",
                ),
                _yt(
                    "yellow",
                    "triple j",
                    "King Stingray cover Coldplay 'Yellow' for Like A Version",
                ),
                _yt(
                    "adam",
                    "triple j",
                    "Nick Ward covers blink-182 'Adam's Song' Ft. E^ST for Like A Version",
                ),
            ],
            [
                _am(
                    "dash",
                    "Winston Surfshirt",
                    "Kiss Me More (triple j Like A Version) [feat. Jerome Farah & Milan Ring]",
                ),
                _am("yellow", "King Stingray", "Yellow (triple j Like A Version)"),
                _am("adam", "Nick Ward", "Adam's Song (triple j Like A Version)"),
                _am("doja", "Doja Cat", "Kiss Me More (feat. SZA)"),
            ],
        )
        # Two uploads of the same cover: one favourite, the other stays one-sided.
        # The original Doja Cat recording is not that cover.
        self.assertEqual(plan["matched"][0]["yt"]["videoId"], "dash")
        self.assertEqual(plan["matched"][0]["am"]["pid"], "dash")
        self.assertEqual(plan["matched"][0]["how"], "exact")
        # The cover sentence is the same favourite. One Apple row can only be used once.
        self.assertEqual(
            likes_sync.pair_score(
                {
                    "artist": "triple j",
                    "title": "Winston Surfshirt cover Doja Cat 'Kiss Me More' for Like A Version Ft. Jerome Farah & Milan Ring",
                },
                {
                    "artist": "Winston Surfshirt",
                    "title": "Kiss Me More (triple j Like A Version) [feat. Jerome Farah & Milan Ring]",
                },
            ),
            1.0,
        )
        self.assertEqual(self._ids(plan), {"dash": "dash", "yellow": "yellow", "adam": "adam"})
        self.assertEqual([row["videoId"] for row in plan["yt_only"]], ["cover"])
        self.assertEqual([row["pid"] for row in plan["am_only"]], ["doja"])


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
        self.assertIn("https://amp-api.music.apple.com", love)
        self.assertIn("Media-User-Token", love)
        self.assertIn("value: 1", love)
        self.assertNotIn("value: -1", love)
        self.assertNotIn("dislike", love.lower())
        like = likes_sync.yt_like_js("dQw4w9WgXcQ")
        self.assertIn("/like/like", like)
        self.assertIn("dQw4w9WgXcQ", like)
        self.assertIn("SAPISID", like)
        self.assertIn("textContent", like)
        self.assertNotIn("removelike", like)
        search = likes_sync.yt_search_js("a{b}")
        self.assertIn("EgWKAQIIAWoKEAkQBRAKEAMQBA==", search)
        self.assertIn('"a{b}"', search)
        self.assertIn("INNERTUBE_CONTEXT", search)
        self.assertIn("textContent", search)
        catalog = likes_sync.catalog_search_js("query")
        self.assertIn("/v1/catalog/au/search", catalog)
        self.assertIn("https://amp-api.music.apple.com", catalog)
        self.assertIn("Media-User-Token", catalog)
        self.assertIn("media-user-token", catalog)
        self.assertNotIn("JSON.stringify(r)", catalog)
        self.assertNotIn("ms-auth-am", catalog)
        auth = likes_sync.auth_js()
        self.assertIn("ms-auth-am", auth)
        self.assertIn("media-user-token", auth)
        self.assertNotIn("amp-api.music.apple.com", auth)
        probe = likes_sync.am_probe_js()
        self.assertIn("ms-probe-am", probe)
        self.assertIn("mask4", probe)
        self.assertNotIn("JSON.stringify(picked)", probe)
        self.assertNotIn("JSON.stringify(user)", probe)
        self.assertNotIn("JSON.stringify(read)", probe)
        store = likes_sync.storefront_js()
        self.assertIn("/v1/me/storefront", store)
        self.assertIn("media-user-token", store)
        self.assertIn("Media-User-Token", store)
        self.assertIn('{method: "GET"}', store)
        self.assertNotIn("POST", store)
        self.assertNotIn("PUT", store)
        self.assertIsNone(likes_sync._JWT_RE.search(catalog))
        self.assertIsNone(likes_sync._JWT_RE.search(probe))
        self.assertIsNone(likes_sync._JWT_RE.search(auth))
        self.assertIsNone(likes_sync._JWT_RE.search(store))
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
        self.assertEqual(runners.fetched, [])

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
        _code, stdout, stderr = silence(
            likes_sync.apply_apple,
            [{"videoId": "v", "title": "Song (feat. Pal)", "artist": "Band"}],
            runners,
            None,
            25,
            set(),
        )
        outcomes, stopped = _code
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
        decoded = [
            decode_js(script)
            for script in osa.scripts
            if "javascript" in script and "execute" in script
        ]
        self.assertTrue(any(APPLE_DEV_TOKEN in script and "ms-auth-am" in script for script in decoded))
        self.assertTrue(any(APPLE_DEV_TOKEN in script and "/v1/catalog/" in script for script in decoded))
        self.assertIn(APPLE_DEV_TOKEN, osa.loved[0])
        self.assertIn("media-user-token", osa.loved[0])
        self.assertNotIn(APPLE_DEV_TOKEN, stdout)
        self.assertNotIn(APPLE_DEV_TOKEN, stderr)
        self.assertTrue(all(url.startswith("https://music.apple.com/") for url in runners.fetched))

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
        self.assertTrue(any("EgWKAQIIAWoKEAkQBRAKEAMQBA==" in decode_js(script) for script in osa.scripts if "javascript" in script))
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
        self.assertEqual(set(plan.keys()), {"yt_only", "am_only", "matched", "skip"})
        self.assertEqual(plan["skip"], [])

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

        tool_runners = likes_sync.Runners(osascript=boom, mdls=boom, ffprobe=boom, sleep=boom, fetch=boom)
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
                likes_sync.Runners(osascript=boom, fetch=boom),
            )
        self.assertIn("archive not found", str(caught.exception))


def chrome_probe(payload, storefront_job=None):
    """Fake Chrome plus a fixture Apple web bundle. No network."""
    ticks = {"n": 0}

    def monotonic():
        ticks["n"] += 1
        return float(ticks["n"])

    class OSA:
        def __init__(self):
            self.closed = 0
            self.scripts = []
            self.storefront = ""

        def __call__(self, source):
            if "make new tab" in source:
                self.scripts.append(source)
                return "15,27\n"
            if "\nclose t\n" in source:
                self.closed += 1
                return "closed\n"
            if "loading of t" in source:
                return "ready\n"
            if "javascript" in source and "execute" in source:
                decoded = decode_js(source)
                if "ms-probe-am" in decoded:
                    return json.dumps(payload)
                if "/v1/me/storefront" in decoded:
                    if storefront_job is None:
                        raise AssertionError("storefront was called")
                    self.storefront = decoded
                    return "started"
                if "JSON.stringify(r)" in decoded:
                    if storefront_job is None:
                        raise AssertionError("polled without a storefront call")
                    return json.dumps(storefront_job)
                if "readyState" in decoded:
                    return "yes"
                raise AssertionError(decoded[:240])
            raise AssertionError(source[:240])

    osa = OSA()
    fetch, fetched = mapped_fetch(apple_pages())
    runners = likes_sync.Runners(
        osascript=osa,
        sleep=lambda _seconds: None,
        monotonic=monotonic,
        fetch=fetch,
    )
    runners.fetched = fetched
    return osa, runners


class DeveloperTokenTests(unittest.TestCase):
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

    def test_fixture_bundle_snippet_is_es256(self):
        self.assertEqual(APPLE_DEV_TOKEN, make_jwt("ES256", APPLE_DEV_EXP))
        self.assertTrue(APPLE_DEV_TOKEN.startswith("eyJhbGciOiJFUzI1NiIs"))
        info = likes_sync.extract_developer_token(APPLE_BUNDLE_JS, now=1_700_000_000)
        self.assertEqual(info["token"], APPLE_DEV_TOKEN)
        self.assertEqual(info["exp"], APPLE_DEV_EXP)
        self.assertIsNone(likes_sync.describe_developer_jwt(APPLE_HS256_TOKEN))
        self.assertIsNone(likes_sync.describe_developer_jwt("eyJhbGciOiJub25lIn0.eyJleHAiOjF9.c2ln"))
        self.assertIn('{"developerToken":"' + APPLE_DEV_TOKEN + '"}', APPLE_BUNDLE_JS)

    def test_latest_unexpired_es256_wins(self):
        earlier = make_jwt("ES256", 1_800_000_000, kid="A")
        later = make_jwt("ES256", 2_100_000_000, kid="B")
        script = 'var a="' + earlier + '";var b="' + later + '";var c="' + APPLE_HS256_TOKEN + '";'
        info = likes_sync.extract_developer_token(script, now=1_700_000_000)
        self.assertEqual(info["token"], later)
        self.assertEqual(info["exp"], 2_100_000_000)
        self.assertIsNone(likes_sync.extract_developer_token('var t="' + earlier + '";', now=1_800_000_000))

    def test_bundle_urls_prefer_index_tilde_and_stay_on_apple(self):
        html = """
        <script src="https://evil.example/assets/index~nope.js"></script>
        <script src="/assets/vendor-aaa.js"></script>
        <link rel="modulepreload" href="/assets/index-zzz.js">
        <script type="module" src="/assets/index~abc123.js"></script>
        """
        self.assertEqual(
            likes_sync.apple_bundle_urls(html),
            [
                "https://music.apple.com/assets/index~nope.js",
                "https://music.apple.com/assets/index~abc123.js",
                "https://music.apple.com/assets/index-zzz.js",
                "https://music.apple.com/assets/vendor-aaa.js",
            ],
        )

    def test_cache_skips_fetch_until_the_claim_expires(self):
        fetch, seen = mapped_fetch(apple_pages())
        runners = likes_sync.Runners(fetch=fetch)
        now = 1_700_000_000
        first = likes_sync.load_developer_token(runners, now=now)
        self.assertEqual(first["token"], APPLE_DEV_TOKEN)
        self.assertEqual(first["exp"], APPLE_DEV_EXP)
        self.assertEqual(
            seen,
            [
                "https://music.apple.com/",
                "https://music.apple.com/assets/index~abc123.js",
            ],
        )
        path = Path(self.tmp.name) / likes_sync.DEVELOPER_CACHE
        saved = json.loads(path.read_text(encoding="utf-8"))
        self.assertEqual(saved, {"token": APPLE_DEV_TOKEN, "exp": APPLE_DEV_EXP})
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        seen.clear()
        second = likes_sync.load_developer_token(runners, now=now)
        self.assertEqual(second, first)
        self.assertEqual(seen, [])

        expired = make_jwt("ES256", 100)
        path.write_text(json.dumps({"token": expired, "exp": 9_999_999_999}), encoding="utf-8")
        refreshed = likes_sync.load_developer_token(runners, now=now)
        self.assertEqual(refreshed["token"], APPLE_DEV_TOKEN)
        self.assertEqual(
            seen,
            [
                "https://music.apple.com/",
                "https://music.apple.com/assets/index~abc123.js",
            ],
        )

    def test_index_tilde_beats_an_inline_jwt_and_other_bundles(self):
        decoy = make_jwt("ES256", 1_900_000_000, kid="INLINE")
        other = make_jwt("ES256", 1_950_000_000, kid="OTHER")
        html = (
            "<!DOCTYPE html><html><head>"
            '<link rel="modulepreload" href="/assets/index-legacy.js">'
            '<script>var inline = "' + decoy + '";</script>'
            '<script type="module" src="/assets/index~abc123.js"></script>'
            '<script src="/assets/other.js"></script>'
            "</head></html>"
        )
        pages = {
            "https://music.apple.com/": html,
            "https://music.apple.com/au/home": html,
            "https://music.apple.com/assets/index-legacy.js": 'var t="' + APPLE_HS256_TOKEN + '";',
            "https://music.apple.com/assets/index~abc123.js": APPLE_BUNDLE_JS,
            "https://music.apple.com/assets/other.js": 'var t="' + other + '";',
        }
        fetch, seen = mapped_fetch(pages)
        info = likes_sync.load_developer_token(likes_sync.Runners(fetch=fetch), now=1_700_000_000)
        self.assertEqual(info["token"], APPLE_DEV_TOKEN)
        self.assertEqual(
            seen,
            [
                "https://music.apple.com/",
                "https://music.apple.com/assets/index~abc123.js",
            ],
        )
        self.assertNotIn(decoy, json.dumps(info))

    def test_falls_back_to_asset_scripts_and_ignores_other_hosts(self):
        html = """<!DOCTYPE html><html><head>
<script src="https://evil.example/assets/sneaky.js"></script>
<script src="/static/app.js"></script>
<script src="/assets/vendor.js"></script>
<script type="module" src="/assets/web-player.js"></script>
</head></html>"""
        pages = {
            "https://music.apple.com/": html,
            "https://music.apple.com/au/home": html,
            "https://music.apple.com/assets/vendor.js": VENDOR_JS,
            "https://music.apple.com/assets/web-player.js": APPLE_BUNDLE_JS,
        }
        fetch, seen = mapped_fetch(pages)
        info = likes_sync.load_developer_token(likes_sync.Runners(fetch=fetch), now=1_700_000_000)
        self.assertEqual(info["token"], APPLE_DEV_TOKEN)
        self.assertEqual(
            seen,
            [
                "https://music.apple.com/",
                "https://music.apple.com/assets/vendor.js",
                "https://music.apple.com/assets/web-player.js",
            ],
        )
        self.assertFalse(any("evil.example" in url for url in seen))

    def test_au_home_is_used_when_the_root_page_has_no_bundle(self):
        pages = {
            "https://music.apple.com/": "<html><head></head></html>",
            "https://music.apple.com/au/home": APPLE_HOME_HTML,
        }
        for url in likes_sync.apple_bundle_urls(APPLE_HOME_HTML):
            pages[url] = VENDOR_JS if "vendor" in url else APPLE_BUNDLE_JS
        fetch, seen = mapped_fetch(pages)
        info = likes_sync.load_developer_token(likes_sync.Runners(fetch=fetch), now=1_700_000_000)
        self.assertEqual(info["exp"], APPLE_DEV_EXP)
        self.assertEqual(seen[0], "https://music.apple.com/")
        self.assertEqual(seen[1], "https://music.apple.com/au/home")
        self.assertIn("https://music.apple.com/assets/index~abc123.js", seen)

    def test_next_script_is_tried_when_a_bundle_fetch_fails(self):
        html = """<!DOCTYPE html><html><head>
<script src="/assets/vendor.js"></script>
<script src="/assets/web-player.js"></script>
</head></html>"""
        pages = {
            "https://music.apple.com/": html,
            "https://music.apple.com/au/home": html,
            "https://music.apple.com/assets/vendor.js": RuntimeError("Apple Music fetch failed (404) for /assets/vendor.js"),
            "https://music.apple.com/assets/web-player.js": APPLE_BUNDLE_JS,
        }
        fetch, seen = mapped_fetch(pages)
        info = likes_sync.load_developer_token(likes_sync.Runners(fetch=fetch), now=1_700_000_000)
        self.assertEqual(info["token"], APPLE_DEV_TOKEN)
        self.assertIn("https://music.apple.com/assets/web-player.js", seen)

    def test_hs256_and_expired_tokens_are_not_cached(self):
        html = '<script src="/assets/index~abc123.js"></script>'
        pages = {
            "https://music.apple.com/": html,
            "https://music.apple.com/au/home": "<html></html>",
            "https://music.apple.com/assets/index~abc123.js": 'var t="' + APPLE_HS256_TOKEN + '";',
        }
        fetch, _seen = mapped_fetch(pages)
        with self.assertRaises(RuntimeError) as caught:
            likes_sync.load_developer_token(likes_sync.Runners(fetch=fetch), now=1_700_000_000)
        self.assertIn("not in the web player bundle", str(caught.exception))
        self.assertNotIn(APPLE_HS256_TOKEN, str(caught.exception))
        self.assertNotIn("eyJ", str(caught.exception))
        self.assertFalse((Path(self.tmp.name) / likes_sync.DEVELOPER_CACHE).exists())

        expired = make_jwt("ES256", 50)
        pages["https://music.apple.com/assets/index~abc123.js"] = 'var t="' + expired + '";'
        fetch, _seen = mapped_fetch(pages)
        with self.assertRaises(RuntimeError) as caught:
            likes_sync.load_developer_token(likes_sync.Runners(fetch=fetch), now=1_700_000_000)
        self.assertIn("expired", str(caught.exception))
        self.assertNotIn(expired, str(caught.exception))
        self.assertFalse((Path(self.tmp.name) / likes_sync.DEVELOPER_CACHE).exists())

    def test_calls_receive_the_developer_token_and_still_read_the_cookie(self):
        scripts = [
            likes_sync.catalog_search_js("query", APPLE_DEV_TOKEN),
            likes_sync.catalog_love_js("123", APPLE_DEV_TOKEN),
            likes_sync.auth_js(APPLE_DEV_TOKEN),
            likes_sync.storefront_js(APPLE_DEV_TOKEN),
        ]
        for script in scripts:
            self.assertIn(APPLE_DEV_TOKEN, script)
            self.assertIn("media-user-token", script)
            self.assertIn("cookieValue", script)
            self.assertNotIn("user-secret-token", script)
        self.assertNotIn(APPLE_DEV_TOKEN, likes_sync.am_probe_js())
        store = likes_sync.storefront_js(APPLE_DEV_TOKEN)
        self.assertIn("/v1/me/storefront", store)
        self.assertIn('{method: "GET"}', store)
        self.assertNotIn("POST", store)
        self.assertNotIn("PUT", store)

    def test_default_fetch_uses_a_browser_ua_and_drops_offsite_bodies(self):
        seen = {}

        class Headers:
            def get_content_charset(self):
                return "utf-8"

        class Response:
            def __init__(self, body: bytes, url: str):
                self._body = body
                self._url = url
                self.headers = Headers()

            def read(self, _limit):
                return self._body

            def geturl(self):
                return self._url

            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return False

        def urlopen(request, timeout=0):
            seen["ua"] = request.get_header("User-agent")
            seen["timeout"] = timeout
            return Response(b"<html>ok</html>", "https://music.apple.com/")

        body = likes_sync.default_fetch("https://music.apple.com/", urlopen=urlopen)
        self.assertEqual(body, "<html>ok</html>")
        self.assertEqual(seen["ua"], likes_sync.BROWSER_UA)
        self.assertEqual(seen["timeout"], 20)
        self.assertNotIn("python-urllib", seen["ua"].lower())

        def redirected(_request, timeout=0):
            return Response(b"eyJhbGciOiJFUzI1NiIsSECRET", "https://evil.example/steal")

        with self.assertRaises(RuntimeError) as caught:
            likes_sync.default_fetch("https://music.apple.com/", urlopen=redirected)
        self.assertIn("redirected", str(caught.exception))
        self.assertNotIn("SECRET", str(caught.exception))
        self.assertNotIn("eyJ", str(caught.exception))


class ProbeTests(unittest.TestCase):
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

    def test_report_masks_tokens_and_says_when_signed_out(self):
        leaked = "eyJhbGciOiJFUzI1NiJ9.payloadbody.signaturepart"
        text = likes_sync.format_am_probe(
            {
                "url": "https://music.apple.com/au/home?token=" + leaked,
                "readyState": "complete",
                "musickit": "absent",
                "developer": {
                    "source": "meta web-experience-app/config/environment",
                    "label": "MEDIA_API.token",
                    "mask": leaked,
                    "length": 320,
                },
                "user": None,
                "cookieNames": ["itua", leaked],
                "storageKeys": [],
                "metaNames": ["web-experience-app/config/environment"],
                "scriptHints": ["application/json"],
                "mainWorld": {"attempted": True, "blocked": True, "error": "script did not run " + leaked},
            }
        )
        self.assertIn("signed-in: no", text)
        self.assertIn("not in this Chrome profile", text)
        self.assertIn("musickit: absent", text)
        self.assertIn("mask=eyJh", text)
        self.assertIn("main-world: blocked", text)
        self.assertIn("web-experience-app/config/environment", text)
        self.assertNotIn(leaked, text)
        self.assertNotIn("payloadbody", text)
        self.assertNotIn("signaturepart", text)

    def test_report_signed_in_from_cookie(self):
        text = likes_sync.format_am_probe(
            {
                "url": "https://music.apple.com/au/home",
                "readyState": "complete",
                "musickit": "absent",
                "developer": {
                    "source": "meta config",
                    "label": "MEDIA_API.token",
                    "mask": "eyJh",
                    "length": 280,
                },
                "user": {"source": "cookie media-user-token", "label": "media-user-token", "mask": "Abcd", "length": 180},
                "cookieNames": ["media-user-token"],
                "mainWorld": None,
            }
        )
        self.assertIn("signed-in: yes", text)
        self.assertIn("cookie media-user-token", text)
        self.assertIn("mask=Abcd", text)
        self.assertNotIn("main-world:", text)
        self.assertNotIn("not in this Chrome profile", text)

    def test_report_names_the_bundle_token_by_exp_and_the_storefront_id(self):
        text = likes_sync.format_am_probe(
            {
                "url": "https://music.apple.com/au/home",
                "readyState": "complete",
                "musickit": "absent",
                "developer": {
                    "source": "meta config",
                    "label": "MEDIA_API.token",
                    "mask": APPLE_DEV_TOKEN,
                    "length": len(APPLE_DEV_TOKEN),
                },
                "user": {
                    "source": "cookie media-user-token",
                    "label": "media-user-token",
                    "mask": "Abcd",
                    "length": 246,
                },
                "cookieNames": ["media-user-token"],
                "mainWorld": None,
            },
            developer={"token": APPLE_DEV_TOKEN, "exp": APPLE_DEV_EXP},
            storefront="au",
        )
        self.assertIn("developer: found (exp " + APPLE_DEV_EXP_TEXT + ")", text)
        self.assertIn("storefront: au", text)
        self.assertIn("mask=Abcd", text)
        self.assertIn("len=246", text)
        self.assertNotIn(APPLE_DEV_TOKEN, text)
        self.assertNotIn("eyJh", text)
        self.assertNotIn("eyJleHAi", text)
        self.assertNotIn("c2lnbmF0", text)
        leaked = likes_sync.format_am_probe(
            {"url": "https://music.apple.com/au/home", "readyState": "complete", "musickit": "absent"},
            developer_error="bundle " + APPLE_DEV_TOKEN,
            storefront_error="amp 401 " + APPLE_DEV_TOKEN,
        )
        self.assertNotIn(APPLE_DEV_TOKEN, leaked)
        self.assertNotIn("eyJleHAi", leaked)
        self.assertIn("developer: missing", leaked)
        self.assertIn("storefront:", leaked)

    def test_probe_command_prints_the_report_and_closes_the_tab(self):
        payload = {
            "url": "https://music.apple.com/au/home",
            "readyState": "complete",
            "musickit": "absent",
            "developer": None,
            "user": None,
            "cookieNames": [],
            "storageKeys": [],
            "metaNames": [],
            "scriptHints": [],
            "mainWorld": {"attempted": True, "blocked": False, "error": "", "auth": "no"},
        }
        osa, runners = chrome_probe(payload)
        code, stdout, stderr = silence(likes_sync.main, ["probe-am"], runners)
        self.assertEqual(code, 0, stderr)
        self.assertIn("signed-in: no", stdout)
        self.assertIn("developer: found (exp " + APPLE_DEV_EXP_TEXT + ")", stdout)
        self.assertIn("main-world: ran auth=no", stdout)
        self.assertNotIn("storefront:", stdout)
        self.assertNotIn(APPLE_DEV_TOKEN, stdout)
        self.assertNotIn(APPLE_DEV_TOKEN, stderr)
        self.assertNotIn("eyJh", stdout)
        self.assertEqual(osa.closed, 1)
        self.assertEqual(osa.storefront, "")
        self.assertIn("https://music.apple.com/au/home", osa.scripts[0])
        self.assertNotIn("--apply", " ".join(osa.scripts))
        self.assertEqual(
            runners.fetched,
            [
                "https://music.apple.com/",
                "https://music.apple.com/assets/index~abc123.js",
            ],
        )

    def test_probe_command_prints_only_the_storefront_id(self):
        payload = {
            "url": "https://music.apple.com/au/home",
            "readyState": "complete",
            "musickit": "absent",
            "developer": None,
            "user": {
                "source": "cookie media-user-token",
                "label": "media-user-token",
                "mask": "Abcd",
                "length": 246,
            },
            "cookieNames": ["media-user-token"],
            "storageKeys": [],
            "metaNames": [],
            "scriptHints": [],
            "mainWorld": None,
        }
        job = {
            "done": True,
            "ok": True,
            "storefront": "au",
            "attributes": {"name": "Australia"},
            "token": APPLE_DEV_TOKEN,
            "data": [{"id": "au", "attributes": {"name": "Australia"}}],
        }
        osa, runners = chrome_probe(payload, storefront_job=job)
        code, stdout, stderr = silence(likes_sync.main, ["probe-am"], runners)
        self.assertEqual(code, 0, stderr)
        self.assertIn("signed-in: yes", stdout)
        self.assertIn("cookie media-user-token", stdout)
        self.assertIn("len=246", stdout)
        self.assertIn("mask=Abcd", stdout)
        self.assertIn("developer: found (exp " + APPLE_DEV_EXP_TEXT + ")", stdout)
        self.assertIn("storefront: au", stdout)
        self.assertNotIn("Australia", stdout)
        self.assertNotIn(APPLE_DEV_TOKEN, stdout)
        self.assertNotIn(APPLE_DEV_TOKEN, stderr)
        self.assertNotIn("eyJh", stdout)
        self.assertNotIn("eyJleHAi", stdout)
        self.assertIn(APPLE_DEV_TOKEN, osa.storefront)
        self.assertIn("media-user-token", osa.storefront)
        self.assertIn("/v1/me/storefront", osa.storefront)
        self.assertNotIn("user-secret-token", osa.storefront)
        self.assertEqual(osa.closed, 1)
        self.assertNotIn("--apply", " ".join(osa.scripts))

    def test_probe_storefront_failure_is_redacted(self):
        payload = {
            "url": "https://music.apple.com/au/home",
            "readyState": "complete",
            "musickit": "absent",
            "user": {"source": "cookie media-user-token", "label": "media-user-token", "mask": "Abcd", "length": 246},
        }
        job = {"done": True, "ok": False, "error": "amp 401 " + APPLE_DEV_TOKEN}
        osa, runners = chrome_probe(payload, storefront_job=job)
        code, stdout, stderr = silence(likes_sync.main, ["probe-am"], runners)
        self.assertEqual(code, 1, stdout)
        self.assertIn("storefront:", stdout)
        self.assertNotIn(APPLE_DEV_TOKEN, stdout)
        self.assertNotIn(APPLE_DEV_TOKEN, stderr)
        self.assertNotIn("eyJleHAi", stdout)
        self.assertEqual(osa.closed, 1)

    def test_probe_still_reports_the_page_when_the_bundle_fetch_fails(self):
        payload = {
            "url": "https://music.apple.com/au/home",
            "readyState": "complete",
            "musickit": "absent",
            "user": {"source": "cookie media-user-token", "label": "media-user-token", "mask": "Abcd", "length": 20},
            "mainWorld": None,
        }

        def fetch(_url):
            raise RuntimeError("Apple Music fetch failed (404) for / " + APPLE_DEV_TOKEN)

        ticks = {"n": 0}

        def monotonic():
            ticks["n"] += 1
            return float(ticks["n"])

        osa, runners = chrome_probe(payload)
        runners.fetch = fetch
        runners.monotonic = monotonic
        code, stdout, stderr = silence(likes_sync.main, ["probe-am"], runners)
        self.assertEqual(code, 1, stdout)
        self.assertIn("developer: missing", stdout)
        self.assertIn("signed-in: yes", stdout)
        self.assertIn("mask=Abcd", stdout)
        self.assertNotIn("storefront:", stdout)
        self.assertNotIn(APPLE_DEV_TOKEN, stdout)
        self.assertNotIn(APPLE_DEV_TOKEN, stderr)
        self.assertNotIn("eyJleHAi", stdout)
        self.assertEqual(osa.closed, 1)
        self.assertEqual(osa.storefront, "")

    def test_chrome_timeout_names_automation(self):
        text = likes_sync.explain_osascript_failure(
            "Google Chrome got an error: AppleEvent timed out. (-1712)"
        )
        self.assertIn("Automation", text)
        self.assertIsNone(likes_sync._JWT_RE.search(text))


if __name__ == "__main__":
    unittest.main()
