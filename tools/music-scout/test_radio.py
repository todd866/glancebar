#!/usr/bin/env python3
"""Unit tests for radio.py (station playlist readers). No network: saved fixtures and a fake transport."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import radio
import scout

FIX = Path(__file__).resolve().parent / "fixtures" / "radio"


def fixture(name: str) -> str:
    return (FIX / name).read_text(encoding="utf-8")


def kexp_last_page() -> str:
    doc = json.loads(fixture("kexp_plays.json"))
    doc["next"] = None
    return json.dumps(doc)


class FakeTransport:
    """Answers by URL pattern; records every request."""

    def __init__(self, routes: list[tuple[str, tuple[int, str]]]):
        self.routes = routes
        self.calls: list[str] = []
        self.headers: list[dict] = []

    def __call__(self, url, data, headers):
        self.calls.append(url)
        self.headers.append(headers)
        for pattern, answer in self.routes:
            if pattern in url:
                return answer
        return 404, ""


class FakeClock:
    def __init__(self):
        self.t = 1000.0
        self.slept: list[float] = []

    def monotonic(self):
        return self.t

    def sleep(self, s):
        self.slept.append(s)
        self.t += s


class ParserTests(unittest.TestCase):
    def test_kexp_drops_air_breaks_and_keeps_next(self):
        plays, nxt = radio.parse_kexp_plays(fixture("kexp_plays.json"))
        self.assertEqual(len(plays), 6)
        self.assertEqual(plays[1]["artist"], "Bonobo")
        self.assertEqual(plays[1]["title"], "Vakata")
        self.assertEqual(plays[0]["at"], "2026-11-17T02:02:01Z")  # -08:00 converted to UTC
        self.assertIn("offset=6", nxt)
        _, nxt = radio.parse_kexp_plays('{"next": "https://api.kexp.org/v2/plays/?offset=2000", "results": []}')
        self.assertIsNone(nxt)

    def test_nts_recent_and_tracklist(self):
        eps = radio.parse_nts_recent(fixture("nts_recent.json"))
        self.assertEqual(len(eps), 3)
        self.assertEqual(eps[0]["path"], "/shows/the-breakfast-show-flo/episodes/the-breakfast-show-flo-17th-november-2026")
        self.assertEqual(eps[0]["at"], "2026-11-17T09:00:00Z")
        self.assertIn("Pop", eps[0]["genres"])
        self.assertEqual(radio.parse_nts_tracklist(fixture("nts_tracklist.json"))[0], ("Al Wilson", "Be Concerned"))

    def test_bbc_schedule_and_play(self):
        sched = radio.parse_bbc_schedule(fixture("bbc_schedule.json"))
        self.assertEqual([b["id"] for b in sched], ["m0033zsm", "m0033zs3", "m0033zst"])
        self.assertEqual(sched[1]["show"], "Guy Garvey's Finest Hour")
        tracks = radio.parse_bbc_play(fixture("bbc_play.json"))
        self.assertEqual(tracks[0], ("Fred Neil", "Faretheewell (Fred's Tune)"))
        self.assertEqual(len(tracks), 3)

    def test_wfmu_feed_and_playlist(self):
        feed = radio.parse_wfmu_feed(fixture("wfmu_feed.xml"))
        self.assertEqual(feed[0], {"id": "170688", "at": "2026-11-18T02:02:49Z", "show": "The Wiggle Room"})
        rows = radio.parse_wfmu_playlist(fixture("wfmu_playlist.html"))
        self.assertEqual([(r["artist"], r["title"]) for r in rows],
                         [("Lee Shot Williams", "Hello Baby"), ("James Brown", "I'll Go Crazy")])  # header and "Music behind DJ" dropped
        self.assertEqual(rows[0]["album"], "The Big Push: Fast Fingering On Polished Frets")

    def test_rrr_schedule_and_episode(self):
        paths = radio.parse_rrr_schedule(fixture("rrr_schedule.html"))
        self.assertEqual(len(paths), 3)  # the #episode-playlist duplicate is not a new episode
        ep = radio.parse_rrr_episode(fixture("rrr_episode.html"))
        self.assertEqual(ep["start"], "2026-11-16T02:00:00Z")  # 13:00 +11:00
        self.assertEqual(ep["show"], "Zero G")
        self.assertEqual(ep["tracks"][1], {"artist": "John Denver", "title": "Calypso",
                                           "album": "The Very Best Of John Denver"})

    def test_airnet_guide_programs_episodes_playlist(self):
        guide = radio.parse_airnet_guide(fixture("airnet_guide.json"))
        self.assertIn({"slug": "mystic-brew", "day": 2, "start": "09:00:00", "duration": 7200, "name": "Mystic Brew"}, guide)
        progs = radio.parse_airnet_programs(fixture("airnet_programs.json"))
        self.assertEqual(progs, [{"slug": "blackandblue", "name": "Black & Blue"}])  # archived and slug-less dropped
        eps = radio.parse_airnet_episodes(fixture("airnet_episodes.json"))
        self.assertEqual(eps[-1]["start"], "2026-11-14 00:00:00")
        tracks = radio.parse_airnet_playlist(fixture("airnet_playlist.json"))
        self.assertEqual([t["artist"] for t in tracks], ["Mr Jukes", "The J.B's", "Jill Scott"])  # comment dropped
        self.assertEqual(radio.parse_airnet_playlist('{"message":"No such episode"}'), [])

    def test_airnet_local_time_to_utc(self):
        tz = radio.ZoneInfo("Australia/Perth")
        self.assertEqual(radio.utc(radio.local_slot("2026-11-13 21:00:00", tz)), "2026-11-13T13:00:00Z")


class FetcherTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.cache = Path(self.tmp.name)
        self.clock = FakeClock()

    def tearDown(self):
        self.tmp.cleanup()

    def fetcher(self, transport, **kw):
        return radio.Fetcher(self.cache, transport=transport, sleep=self.clock.sleep,
                             monotonic=self.clock.monotonic, **kw)

    def test_two_seconds_between_requests_to_one_host_and_generic_agent(self):
        t = FakeTransport([("", (200, "{}"))])
        f = self.fetcher(t)
        f.get("https://a.example/1", ttl=None)
        f.get("https://a.example/2", ttl=None)
        f.get("https://b.example/1", ttl=None)  # another host does not wait
        self.assertEqual(self.clock.slept, [2.0])
        ua = t.headers[0]["User-Agent"]
        self.assertNotIn("@", ua)
        self.assertNotIn("Ian", ua)
        self.assertNotIn("glancebar", ua.lower())

    def test_cache_hit_sends_nothing(self):
        t = FakeTransport([("", (200, "hello"))])
        f = self.fetcher(t)
        self.assertEqual(f.get("https://a.example/x", ttl=3600), "hello")
        self.assertEqual(f.get("https://a.example/x", ttl=3600), "hello")
        self.assertEqual(len(t.calls), 1)
        self.assertEqual(f.cache_hits, 1)

    def test_not_found_is_none_and_429_stops_the_host(self):
        t = FakeTransport([("missing", (400, '{"message":"No such episode"}')), ("busy", (429, "")), ("", (200, "ok"))])
        f = self.fetcher(t)
        self.assertIsNone(f.get("https://a.example/missing"))
        with self.assertRaises(radio.FetchStop):
            f.get("https://a.example/busy")
        with self.assertRaises(radio.FetchStop):
            f.get("https://a.example/fine")  # host left alone for the rest of the run
        self.assertEqual(f.get("https://b.example/fine"), "ok")

    def test_budget(self):
        f = self.fetcher(FakeTransport([("", (200, "ok"))]), budget=2)
        f.get("https://a.example/1", ttl=None)
        f.get("https://a.example/2", ttl=None)
        with self.assertRaises(radio.FetchStop):
            f.get("https://a.example/3", ttl=None)


class CollectTests(unittest.TestCase):
    NOW = datetime(2026, 11, 18, 12, 0, tzinfo=timezone.utc)

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.cache = Path(self.tmp.name)
        self.clock = FakeClock()

    def tearDown(self):
        self.tmp.cleanup()

    def run_collect(self, transport, stations, days=2.0):
        f = radio.Fetcher(self.cache, transport=transport, sleep=self.clock.sleep, monotonic=self.clock.monotonic)
        return radio.collect(stations, self.cache, f, now=self.NOW, days=days)

    def test_kexp_days_are_incremental(self):
        t = FakeTransport([("api.kexp.org", (200, kexp_last_page()))])
        plays, report = self.run_collect(t, ["kexp"])
        first = len(t.calls)
        self.assertEqual(first, 3)  # 16, 17 and 18 Nov (UTC)
        self.assertEqual(report["kexp"]["error"], None)
        self.assertTrue(plays["kexp"])
        # The next run (cache ignored: new fetcher, same store) only asks for the day still open.
        for p in (self.cache / "http").glob("*/*.gz"):
            p.unlink()
        self.run_collect(t, ["kexp"])
        self.assertEqual(len(t.calls) - first, 1)
        self.assertIn("airdate_after=2026-11-18", t.calls[-1])

    def test_airnet_guide_episode_urls_in_station_time(self):
        t = FakeTransport([("/guides/fm", (200, fixture("airnet_guide.json"))),
                           ("mystic-brew/episodes/2026-11-17%2009%3A00%3A00/playlists", (200, fixture("airnet_playlist.json"))),
                           ("/playlists", (400, '{"message":"No such episode"}'))])
        plays, report = self.run_collect(t, ["pbs"])
        self.assertEqual(len(plays["pbs"]), 3)
        self.assertEqual(plays["pbs"][0]["at"], "2026-11-16T22:00:00Z")  # 09:00 Melbourne, UTC+11
        self.assertEqual(plays["pbs"][0]["show"], "Mystic Brew")

    def test_one_station_failing_leaves_the_others(self):
        t = FakeTransport([("wfmu.org/playlistfeed", (503, "")), ("api.kexp.org", (200, kexp_last_page()))])
        plays, report = self.run_collect(t, ["kexp", "wfmu"])
        self.assertIn("503", report["wfmu"]["error"])
        self.assertIsNone(report["kexp"]["error"])
        self.assertTrue(plays["kexp"])


def _p(artist, title, at="2026-11-16T10:00:00Z"):
    return radio.play(artist, title, at)


class RankingTests(unittest.TestCase):
    def test_match_key_is_loose_on_feat_and_the(self):
        self.assertEqual(radio.match_key("The Avalanches feat. Someone", "Song (feat. X)"),
                         radio.match_key("Avalanches", "song"))
        self.assertNotEqual(radio.match_key("A", "Song (Remix)"), radio.match_key("A", "Song"))

    def test_two_stations_outrank_a_heavy_one_off_and_keep_station_and_date(self):
        plays = {
            "kexp": [_p("Solo Act", "Heavy", f"2026-11-1{d}T10:00:00Z") for d in range(1, 8)] + [_p("Pair Act", "Shared")],
            "pbs": [_p("Pair Act", "Shared", "2026-11-17T01:00:00Z")],
        }
        cands = radio.select_candidates(radio.aggregate(plays), exclude=lambda a, t: False, liked_artists=set(),
                                        max_total=5, max_single=5)
        self.assertEqual(cands[0]["artist"], "Pair Act")
        self.assertEqual(cands[0]["stations"], ["kexp", "pbs"])
        self.assertEqual(cands[0]["plays"], 2)
        self.assertEqual(cands[0]["why"], "Heard on KEXP and PBS, latest 17 Nov")
        self.assertTrue(cands[0]["source"].startswith("radio:"))
        self.assertEqual({h["station"]: h["last"] for h in cands[0]["heard"]},
                         {"kexp": "2026-11-16T10:00:00Z", "pbs": "2026-11-17T01:00:00Z"})
        self.assertGreater(cands[0]["score_hint"], cands[1]["score_hint"])
        self.assertEqual(cands[1]["why"], "Heard on KEXP 17 Nov")

    def test_breadth_no_station_fills_the_top(self):
        plays = {"kexp": [], "nts": [], "pbs": []}
        for i in range(4):  # four KEXP+NTS tracks, slightly stronger
            plays["kexp"] += [_p(f"K{i}", "t"), _p(f"K{i}", "t")]
            plays["nts"].append(_p(f"K{i}", "t"))
        plays["pbs"] += [_p("P0", "t"), _p("P1", "t")]
        plays["nts"] += [_p("P0", "t"), _p("P1", "t")]
        cands = radio.select_candidates(radio.aggregate(plays), exclude=lambda a, t: False, liked_artists=set(),
                                        max_total=4, max_single=0)
        top = [c["source"] for c in cands[:4]]
        self.assertLessEqual(top.count("radio:kexp"), 2)
        self.assertGreaterEqual(sum(1 for s in top if s != "radio:kexp"), 2)

    def test_triple_j_only_left_to_its_own_source_owned_excluded_one_per_artist(self):
        plays = {
            "triplej": [_p("JJJ Only", "Song"), _p("Both", "Song")],
            "kexp": [_p("Both", "Song"), _p("Owned", "Song"), _p("Both", "Other song")],
        }
        cands = radio.select_candidates(radio.aggregate(plays), exclude=lambda a, t: a == "Owned",
                                        liked_artists=set(), max_total=10, max_single=10)
        self.assertEqual([(c["artist"], c["title"]) for c in cands], [("Both", "Song")])
        self.assertEqual(cands[0]["source"], "radio:kexp")  # triple j rotation does not make it primary
        self.assertIn("triplej", cands[0]["stations"])

    def test_liked_artist_lifts_a_one_off(self):
        plays = {"kexp": [_p("Stranger", "a"), _p("Friend", "b")]}
        cands = radio.select_candidates(radio.aggregate(plays), exclude=lambda a, t: False,
                                        liked_artists={"friend"}, max_total=1, max_single=1)
        self.assertEqual(cands[0]["artist"], "Friend")

    def test_stray_separators_trimmed_and_common_spelling_shown(self):
        agg = radio.aggregate({"pbs": [_p("mj lenderman |", "- separate ways |")],
                               "kexp": [_p("MJ Lenderman", "Separate Ways"), _p("MJ Lenderman", "Separate Ways")]})
        (row,) = agg.values()
        self.assertEqual((row["artist"], row["title"]), ("MJ Lenderman", "Separate Ways"))
        self.assertEqual(sorted(row["stations"]), ["kexp", "pbs"])

    def test_junk_rows_dropped(self):
        agg = radio.aggregate({"nts": [_p("Unknown", "x"), _p("A", "ID"), _p("A", "Real")]})
        self.assertEqual([r["title"] for r in agg.values()], ["Real"])


class ScoutWiringTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.state = root / "state"
        self.paths = scout.ScoutPaths(self.state)
        base = dict(scout.DEFAULTS)
        for k in ("library_export", "music_library_state", "mixpool_state", "yt_liked_dir", "triplej_state"):
            base[k] = str(root / k)
        base.update({
            "hearts_path": str(root / "hearts.json"),
            "feedback_paths": [str(root / "feedback.jsonl")],
            "music_sync_inventory": str(root / "inventory.json"),
            "media_share": str(root / "media"),
            "playback_log": str(root / "playback.jsonl"),
            "triplej_plays": str(root / "plays.jsonl"),
            "new_music_path": str(root / "new-music.json"),
        })
        (root / "plays.jsonl").write_text(json.dumps({"played_time": "2026-11-17T05:00:00+00:00",
                                                      "artist": "Bonobo", "title": "Vakata"}) + "\n")
        self.cfg = base
        self.transport = FakeTransport([("api.kexp.org", (200, kexp_last_page()))])
        self.runners = scout.Runners(
            ai_pick=lambda prompt, cmd: (75, ""),
            itunes_albums=lambda *a, **k: [],
            clock=lambda: "2026-11-18T12:00:00Z",
            radio_transport=self.transport,
            radio_sleep=lambda s: None,
        )

    def tearDown(self):
        self.tmp.cleanup()

    def test_off_by_default(self):
        _, counts, _ = scout.cmd_candidates(self.cfg, self.paths, self.runners)
        self.assertNotIn("radio", counts)
        self.assertEqual(self.transport.calls, [])

    def test_on_switch_adds_radio_candidates_to_the_pool(self):
        self.cfg.update(radio_enabled=True, radio_stations=["kexp", "triplej"], radio_days=2)
        merged, counts, errors = scout.cmd_candidates(self.cfg, self.paths, self.runners)
        radio_rows = [c for c in merged if c["source"].startswith("radio:")]
        self.assertTrue(radio_rows)
        self.assertEqual(radio_rows[0]["artist"], "Bonobo")  # KEXP + triple j beats KEXP one-offs
        self.assertEqual(radio_rows[0]["stations"], ["kexp", "triplej"])
        self.assertGreater(counts["radio:kexp"], 0)
        self.assertEqual(counts["radio:triplej"], 1)
        doc = json.loads(self.paths.candidates.read_text())
        self.assertIn("kexp", doc["radio"]["stations"])
        self.assertTrue((self.state / "radio-cache" / "plays" / "kexp.json").is_file())
        self.assertFalse([e for e in errors if e.startswith("radio")])
        # rank keeps the fields, so acquire and publish can say where it was heard
        ranked = scout.cmd_rank(self.cfg, self.paths, self.runners)
        row = next(r for r in ranked if r["artist"] == "Bonobo")
        self.assertEqual(row["heard"][0]["name"], "KEXP")

    def test_offered_under_another_spelling_is_not_offered_again(self):
        self.cfg.update(radio_enabled=True, radio_stations=["kexp", "triplej"], radio_days=2)
        scout.append_jsonl(self.paths.ledger, {"at": "2026-11-10T00:00:00Z", "action": "offered",
                                               "artist": "Bonobo feat. Someone", "title": "Vakata (Remastered)"})
        merged, _, _ = scout.cmd_candidates(self.cfg, self.paths, self.runners)
        self.assertFalse([c for c in merged if c["artist"] == "Bonobo"])

    def test_no_radio_rows_when_the_week_is_full_and_no_dead_source_streak(self):
        self.cfg.update(radio_enabled=True, radio_stations=["kexp"], radio_days=2, tracks_per_week=1)
        now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        scout.append_jsonl(self.paths.ledger, {"at": now, "action": "acquired", "artist": "X", "title": "Y",
                                               "size_bytes": 1})
        merged, counts, _ = scout.cmd_candidates(self.cfg, self.paths, self.runners)
        self.assertFalse([c for c in merged if c["source"].startswith("radio:")])
        self.assertNotIn("radio", counts)
        self.assertGreater(counts["radio:kexp"], 0)  # still read, so the store stays current
        doc = json.loads(self.paths.candidates.read_text())
        self.assertIn("held_back", doc["radio"])

    def test_one_failing_station_is_a_warning_not_a_failed_run(self):
        self.cfg.update(radio_enabled=True, radio_stations=["kexp", "wfmu"], radio_days=2)
        self.transport.routes.insert(0, ("wfmu.org", (503, "")))
        _, _, errors = scout.cmd_candidates(self.cfg, self.paths, self.runners)
        self.assertFalse([e for e in errors if e.startswith("radio")])
        doc = json.loads(self.paths.candidates.read_text())
        self.assertTrue(any(w.startswith("radio:wfmu") for w in doc["warnings"]))


if __name__ == "__main__":
    unittest.main()
