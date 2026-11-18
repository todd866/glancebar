#!/usr/bin/env python3
"""Unit tests for backcatalogue.py and the scout's back-catalogue half. No network: trimmed list
pages in fixtures/canon/, a fake transport, and stubbed catalogue and LLM calls."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import backcatalogue as bc
import radio
import scout
from test_scout import _cfg

FIX = Path(__file__).resolve().parent / "fixtures" / "canon"
RADIO_FIX = Path(__file__).resolve().parent / "fixtures" / "radio"
NOW = "2026-11-18T19:10:00Z"


def fixture(name: str) -> str:
    return (FIX / name).read_text(encoding="utf-8")


class FakeTransport:
    """Answers by URL substring; records every request and its headers."""

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


ALLOW_ALL = (200, "User-agent: *\nAllow: /\n")


def canon_routes(robots=ALLOW_ALL) -> list[tuple[str, tuple[int, str]]]:
    return [
        ("/robots.txt", robots),
        ("Grammy_Hall_of_Fame_Award_recipients_(A", (200, fixture("grammy_hof.html"))),
        ("Pazz_&_Jop", (200, fixture("pazz_jop.html"))),
        ("Rolling_Stone", (200, fixture("rs500.html"))),
        ("Mercury_Prize", (200, fixture("mercury.html"))),
        ("Polaris_Music_Prize", (200, fixture("polaris.html"))),
        ("Australian_Music_Prize", (200, fixture("amp.html"))),
    ]


class ParserTests(unittest.TestCase):
    def test_grammy_hall_of_fame_rows(self):
        rows = bc.parse_grammy_hof(fixture("grammy_hof.html"))
        self.assertGreaterEqual(len(rows), 14)
        big_star = next(r for r in rows if r["artist"] == "Big Star")
        self.assertEqual((big_star["title"], big_star["year"], big_star["kind"]), ("#1 Record", 1972, "album"))
        self.assertIn("Grammy Hall of Fame (album, inducted 2025)", big_star["label"])
        single = next(r for r in rows if r["kind"] == "song")
        self.assertFalse(single["title"].startswith('"'))  # quotes stripped from a song title
        classical = [r for r in rows if r["genre"] == "Classical"]
        self.assertTrue(classical)
        self.assertTrue(bc.excluded(artist=classical[0]["artist"], title=classical[0]["title"], genre="Classical"))

    def test_pazz_jop_number_ones_and_a_shared_year(self):
        rows = bc.parse_pazz_jop(fixture("pazz_jop.html"))
        albums = [r for r in rows if r["kind"] == "album"]
        singles = [r for r in rows if r["kind"] == "song"]
        self.assertEqual(albums[0]["artist"], "The Who")
        self.assertEqual(albums[0]["title"], "Who's Next")
        self.assertEqual(albums[0]["year"], 1971)
        # 1981 had two number-one singles; the year cell spans both rows.
        y1981 = [(r["artist"], r["title"], r["year"]) for r in singles if r["year"] == 1981]
        self.assertIn(("Laurie Anderson", "O Superman", 1981), y1981)
        self.assertIn(("The Rolling Stones", "Start Me Up", 1981), y1981)
        # Defunct categories (dance, compilations, videos) are not read.
        self.assertFalse(any("Macro Dub" in r["title"] for r in rows))

    def test_rolling_stone_top_tens(self):
        rows = bc.parse_rs500(fixture("rs500.html"))
        first = rows[0]
        self.assertEqual((first["artist"], first["title"], first["year"]), ("Bob Dylan", "Like a Rolling Stone", 1965))
        self.assertTrue(all(r["kind"] == "song" for r in rows))
        self.assertIn("Respect", [r["title"] for r in rows])

    def test_prize_winners_and_shortlists(self):
        rows = bc.parse_prize(fixture("mercury.html"), "Mercury Prize")
        self.assertIn(("Primal Scream", "Screamadelica", 1992, "Mercury Prize winner 1992"),
                      [(r["artist"], r["title"], r["year"], r["label"]) for r in rows])
        self.assertIn(("Barry Adamson", "Soul Murder"), [(r["artist"], r["title"]) for r in rows])
        self.assertTrue(all(r["kind"] == "album" for r in rows))
        polaris = bc.parse_prize(fixture("polaris.html"), "Polaris Prize")
        self.assertIn(("Final Fantasy", "He Poos Clouds", 2006), [(r["artist"], r["title"], r["year"]) for r in polaris])
        # The 2025+ table writes 'Artist, "Album"'.
        self.assertIn(("Mustafa", "Gaza Is Calling", 2025), [(r["artist"], r["title"], r["year"]) for r in polaris])
        # The Heritage table names a period, not a release year: not read.
        self.assertNotIn("Blue", [r["title"] for r in polaris])
        amp = bc.parse_prize(fixture("amp.html"), "Australian Music Prize")
        self.assertEqual(amp[0]["artist"], "The Drones")
        self.assertEqual(amp[0]["year"], 2005)

    def test_rowspan_and_colspan_are_carried(self):
        page = """<h2>Results</h2><table class="wikitable"><tr><th>Year</th><th>Artist</th><th>Song</th></tr>
        <tr><td rowspan="2">1969</td><td>A</td><td>"One"</td></tr><tr><td>B</td><td>"Two"</td></tr>
        <tr><td>1970</td><td colspan="2">none</td></tr></table>"""
        t = bc.wiki_tables(page)[0]
        self.assertEqual(t["heading"], "Results")
        self.assertEqual([[c["text"] for c in r] for r in t["rows"]],
                         [["1969", "A", '"One"'], ["1969", "B", '"Two"'], ["1970", "none", "none"]])


class HelperTests(unittest.TestCase):
    def test_years_and_decades(self):
        self.assertEqual(bc.year_of("1992 (1st)"), 1992)
        self.assertEqual(bc.year_of("2026-04-21T00:00:00Z"), 2026)
        self.assertIsNone(bc.year_of("n/a"))
        self.assertEqual(bc.decade_of(1969), "1960s")
        self.assertEqual(bc.decade_of(None), "")
        # A remaster year never replaces the list's year; a slightly earlier one corrects a prize year.
        self.assertEqual(bc.reconcile_year(1967, 2011), 1967)
        self.assertEqual(bc.reconcile_year(1995, 1994), 1994)
        self.assertEqual(bc.reconcile_year(1995, 1971), 1995)
        self.assertEqual(bc.reconcile_year(None, 1980), 1980)

    def test_exclusions(self):
        self.assertTrue(bc.excluded(artist="Karaoke Stars", title="Hey Jude"))
        self.assertTrue(bc.excluded(title="Hey Jude (Live at the Hollywood Bowl)"))
        self.assertTrue(bc.excluded(title="Hey Jude", album="Live at Leeds"))
        self.assertTrue(bc.excluded(title="Song", album="MTV Unplugged in New York"))
        self.assertTrue(bc.excluded(title="Wheels on the Bus", genre="Children's Music"))
        self.assertTrue(bc.excluded(artist="Rockabye Baby!", title="Lullaby Renditions of Radiohead"))
        self.assertTrue(bc.excluded(title="A Tribute to the Beatles"))
        self.assertTrue(bc.excluded(title="Shake It Off (Taylor's Version)", album="1989 (Re-recorded)"))
        # Real titles that only look like the above.
        self.assertIsNone(bc.excluded(artist="Oasis", title="Live Forever"))
        self.assertIsNone(bc.excluded(artist="MGMT", title="Kids"))
        self.assertIsNone(bc.excluded(artist="The Strokes", title="Under Cover of Darkness"))
        self.assertIsNone(bc.excluded(artist="The Cure", title="Lullaby"))

    def test_best_hit_prefers_the_original_and_skips_excluded(self):
        hits = [
            {"trackId": 3, "collectionName": "Greatest Hits", "releaseDate": "1990-01-01"},
            {"trackId": 1, "collectionName": "Album (2011 Remaster)", "releaseDate": "2011-01-01"},
            {"trackId": 2, "collectionName": "Album", "releaseDate": "1969-01-01"},
            {"trackId": 4, "trackName": "Song (Live)", "collectionName": "Live", "releaseDate": "1965-01-01"},
        ]
        self.assertEqual(bc.best_hit(hits)["trackId"], 2)
        self.assertEqual(bc.earliest_year(hits), 1969)  # the live one is excluded, the others reissues
        self.assertIsNone(bc.best_hit([hits[3]]))
        # Found 18 Nov 2026: a soundtrack dated 1980-01-01 held a 1984 song. Only compilations and
        # reissues on the catalogue: the year is unknown, and the station's or the model's is used.
        cocteau = [{"trackId": 7, "collectionName": "Stars and Topsoil: A Collection (1982-1990)", "releaseDate": "2000-10-16"},
                   {"trackId": 8, "collectionName": "The Perks of Being a Wallflower (Original Motion Picture Soundtrack)",
                    "releaseDate": "1980-01-01"}]
        self.assertIsNone(bc.earliest_year(cocteau))
        self.assertTrue(bc.best_hit(cocteau))

    def test_order_decade_takes_kinds_in_turn(self):
        def row(key, score, canon=(), stations=None, llm=""):
            return {"key": key, "score": score, "canon": list(canon), "stations": stations or {}, "llm": llm}
        rows = [row("c1", 3.0, canon=["x"]), row("c2", 2.9, canon=["y"]), row("c3", 2.8, canon=["z"]),
                row("r1", 1.0, stations={"wfmu": 1}), row("l1", 0.7, llm="near")]
        self.assertEqual([r["key"] for r in bc.order_decade(rows)], ["c1", "r1", "l1", "c2", "c3"])

    def test_allocate_follows_deficits_and_gives_thin_decades_slots_away(self):
        decades = ["1960s", "1970s", "1980s"]
        self.assertEqual(bc.allocate(6, decades, {"1960s": 2, "1970s": 2, "1980s": 2}, {"1960s": 9, "1970s": 9, "1980s": 9}),
                         {"1960s": 2, "1970s": 2, "1980s": 2})
        # The 1960s already has its share this week: the others take the slots.
        self.assertEqual(bc.allocate(4, decades, {"1960s": 0, "1970s": 2, "1980s": 2}, {"1960s": 9, "1970s": 9, "1980s": 9}),
                         {"1960s": 0, "1970s": 2, "1980s": 2})
        # The 1980s has one record: the rest of its need goes to decades that can fill it.
        got = bc.allocate(6, decades, {"1960s": 2, "1970s": 2, "1980s": 2}, {"1960s": 9, "1970s": 9, "1980s": 1})
        self.assertEqual(got["1980s"], 1)
        self.assertEqual(sum(got.values()), 6)

    def test_pool_merges_support_and_a_canon_album_backs_a_radio_play(self):
        canon = [bc.entry("Portishead", "Dummy", 1995, kind="album", label="Mercury Prize winner 1995")]
        radio_rows = {
            radio.match_key("Portishead", "Roads"): {
                "artist": "Portishead", "title": "Roads", "album": "Dummy",
                "stations": {"wfmu": {"plays": 1, "last": "2026-11-14T03:00:00Z", "show": ""},
                             "nts": {"plays": 2, "last": "2026-11-15T03:00:00Z", "show": ""}}},
            radio.match_key("Nobody", "Song"): {
                "artist": "Nobody", "title": "Song", "album": "",
                "stations": {"kexp": {"plays": 1, "last": "2026-11-14T03:00:00Z", "show": ""}}},
        }
        years = {radio.match_key("Portishead", "Roads"): 1994, radio.match_key("Nobody", "Song"): 1999}
        llm = [{"artist": "Tricky", "title": "Overcome", "year": 1995, "why": "Bristol, next to Portishead", "track_id": 9}]
        pool = bc.build_pool(canon=canon, radio_rows=radio_rows, radio_years=years, llm_rows=llm, liked=set())
        roads = pool[radio.match_key("Portishead", "Roads")]
        self.assertEqual(roads["canon"], ["Mercury Prize winner 1995"])
        self.assertEqual(roads["decade"], "1990s")
        self.assertGreater(roads["score"], pool[radio.match_key("Nobody", "Song")]["score"])
        cand = bc.to_candidate(roads, {"trackId": 5, "artistName": "Portishead", "trackName": "Roads",
                                       "collectionName": "Dummy", "releaseDate": "1994"}, rank=0)
        self.assertEqual((cand["year"], cand["decade"], cand["era"], cand["source"]), (1994, "1990s", "back", "back:canon"))
        self.assertIn("Mercury Prize winner 1995", cand["why"])
        self.assertIn("heard on NTS and WFMU", cand["why"])
        self.assertEqual(cand["track_id"], 5)


class RobotsAndCanonTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.now = datetime(2026, 11, 18, 19, 10, tzinfo=timezone.utc)

    def tearDown(self):
        self.tmp.cleanup()

    def fetcher(self, transport, http="http"):
        return radio.Fetcher(self.dir / http, transport=transport, sleep=lambda s: None, user_agent=bc.USER_AGENT)

    def test_a_site_that_refuses_claude_agents_is_not_read(self):
        robots = (200, "User-agent: *\nAllow: /\n\nUser-agent: ClaudeBot\nDisallow: /\n")
        t = FakeTransport(canon_routes(robots))
        entries, report = bc.load_canon(self.fetcher(t), self.dir, lists=["mercury"], now=self.now, refresh_days=30)
        self.assertEqual(entries, [])
        self.assertIn("ClaudeBot", report["mercury"]["error"])
        self.assertEqual([u for u in t.calls if "robots" not in u], [])

    def test_lists_are_read_politely_and_cached(self):
        t = FakeTransport(canon_routes())
        f = self.fetcher(t)
        entries, report = bc.load_canon(f, self.dir, lists=["mercury", "pazz-jop"], now=self.now, refresh_days=30)
        self.assertTrue(report["mercury"]["entries"] and report["pazz-jop"]["entries"])
        self.assertIsNone(report["mercury"]["error"])
        self.assertTrue(all(h["User-Agent"] == bc.USER_AGENT for h in t.headers))
        self.assertEqual(sum(1 for u in t.calls if "robots" in u), 1)  # one robots.txt per host
        self.assertEqual({e["list"] for e in entries}, {"mercury", "pazz-jop"})
        # Next night: the parsed copy is used, nothing is fetched.
        t2 = FakeTransport(canon_routes())
        again, report2 = bc.load_canon(self.fetcher(t2), self.dir, lists=["mercury", "pazz-jop"],
                                       now=self.now + timedelta(days=1), refresh_days=30)
        self.assertEqual(t2.calls, [])
        self.assertEqual(len(again), len(entries))
        self.assertTrue(report2["mercury"]["cached"])

    def test_a_missing_robots_file_allows_and_a_broken_page_keeps_the_last_copy(self):
        t = FakeTransport([("/robots.txt", (404, "")), ("Mercury_Prize", (200, fixture("mercury.html")))])
        entries, _ = bc.load_canon(self.fetcher(t), self.dir, lists=["mercury"], now=self.now, refresh_days=30)
        self.assertTrue(entries)
        later = self.now + timedelta(days=40)
        t2 = FakeTransport([("/robots.txt", (404, "")), ("Mercury_Prize", (200, "<html>changed</html>"))])
        kept, report = bc.load_canon(self.fetcher(t2, "http2"), self.dir, lists=["mercury"], now=later, refresh_days=30)
        self.assertEqual(len(kept), len(entries))
        self.assertIn("no entries parsed", report["mercury"]["error"])


class RadioYearTests(unittest.TestCase):
    def test_kexp_and_wfmu_plays_carry_a_year(self):
        plays, _ = radio.parse_kexp_plays((RADIO_FIX / "kexp_plays.json").read_text(encoding="utf-8"))
        self.assertTrue(any(p.get("year") for p in plays))
        self.assertTrue(all(isinstance(p["year"], int) for p in plays if "year" in p))
        wfmu = radio.parse_wfmu_playlist((RADIO_FIX / "wfmu_playlist.html").read_text(encoding="utf-8"))
        self.assertTrue(all(isinstance(r["year"], int) for r in wfmu if "year" in r))
        self.assertEqual(radio.play("A", "B", "2026-11-14T00:00:00Z", year="")["artist"], "A")
        self.assertNotIn("year", radio.play("A", "B", "2026-11-14T00:00:00Z", year=""))

    def test_station_years_take_the_earliest(self):
        plays = {"kexp": [radio.play("Can", "Vitamin C", "2026-11-14T00:00:00Z", year="2020-01-01")],
                 "wfmu": [radio.play("Can", "Vitamin C", "2026-11-15T00:00:00Z", year=1972)]}
        self.assertEqual(bc.station_years(plays)[radio.match_key("Can", "Vitamin C")], 1972)


# --- the scout's back-catalogue half -------------------------------------------------------

CATALOGUE = {
    # artist|title (folded) → (release years, genre)
    "can|vitamin c": ([1972, 2011], "Rock"),
    "the stooges|1969": ([1969], "Rock"),
    "talking heads|once in a lifetime": ([1980], "Rock"),
    "slint|good morning, captain": ([1991], "Alternative"),
    "broadcast|papercuts": ([2003], "Electronic"),
    "new band|fresh one": ([2026], "Alternative"),
    "laurie anderson|o superman": ([1981], "Pop"),
    "the rolling stones|start me up": ([1981], "Rock"),
    "bob dylan|like a rolling stone": ([1965], "Rock"),
    "aretha franklin|respect": ([1967], "R&B"),
    "kidsband|wheels": ([1999], "Children's Music"),
    "alice coltrane|journey in satchidananda": ([1971], "Jazz"),
}


def fake_matches(calls):
    def matches(artist, title, *, sleep=None):
        calls.append((artist, title))
        key = f"{scout.normal(artist)}|{scout.normal(title)}"
        if key not in CATALOGUE:
            return []
        years, genre = CATALOGUE[key]
        return [{"wrapperType": "track", "trackId": abs(hash((key, y))) % 10**9, "artistName": artist,
                 "trackName": title, "collectionName": f"{title} LP", "releaseDate": f"{y}-01-01T00:00:00Z",
                 "primaryGenreName": genre, "trackTimeMillis": 200000} for y in years]
    return matches


def fake_album_songs(artist, album, *, sleep=None):
    return [{"wrapperType": "track", "trackId": abs(hash((artist, album))) % 10**9, "artistName": artist,
             "trackName": f"Best of {album}", "collectionName": album, "releaseDate": "1994-08-22T00:00:00Z",
             "primaryGenreName": "Alternative", "trackTimeMillis": 240000}]


class BackSourceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.state = self.root / "state"
        self.state.mkdir()
        self.paths = scout.ScoutPaths(self.state)
        self.cfg = _cfg(self.root, backcatalogue_enabled=True, radio_stations=["kexp", "wfmu", "nts"],
                        backcatalogue_lists=["pazz-jop", "rolling-stone-500", "mercury"],
                        tracks_per_week=24, backcatalogue_max_candidates=12, backcatalogue_llm_suggestions=4,
                        media_share=str(self.root / "media"), playback_log=str(self.root / "pb.jsonl"))
        self.now = datetime(2026, 11, 18, 19, 10, tzinfo=timezone.utc)
        when = "2026-11-15T03:00:00Z"
        stores = {
            "wfmu": [radio.play("Can", "Vitamin C", when, year=1972), radio.play("The Stooges", "1969", when),
                     radio.play("Slint", "Good Morning, Captain", when), radio.play("KidsBand", "Wheels", when)],
            "nts": [radio.play("Can", "Vitamin C", when), radio.play("Broadcast", "Papercuts", when),
                    radio.play("Talking Heads", "Once in a Lifetime", when)],
            "kexp": [radio.play("New Band", "Fresh One", when, year="2026-10-01")],
        }
        for code, rows in stores.items():
            st = radio.Store(self.state / "radio-cache" / "plays" / f"{code}.json")
            st.put("u1", when, rows, final=True)
            st.save()
        self.lookups: list = []
        self.picks: list = []

    def tearDown(self):
        self.tmp.cleanup()

    def runners(self, llm_reply=None, transport=None):
        reply = llm_reply if llm_reply is not None else json.dumps([
            {"artist": "Alice Coltrane", "title": "Journey in Satchidananda", "year": 1971, "why": "spiritual jazz"},
            {"artist": "Nobody Real", "title": "Made Up", "year": 1985, "why": "invented"},
        ])

        def ai_pick(prompt, cmd):
            self.picks.append(json.loads(prompt))
            return 0, reply

        return scout.Runners(clock=lambda: NOW, ai_pick=ai_pick, itunes_song_matches=fake_matches(self.lookups),
                             itunes_album_songs=fake_album_songs, canon_transport=transport or FakeTransport(canon_routes()),
                             canon_sleep=lambda s: None, sleep=lambda s: None)

    def test_older_records_from_radio_canon_and_llm_spread_over_decades(self):
        rows, doc = scout.source_backcatalogue(self.cfg, self.paths, self.runners(), set())
        self.assertTrue(rows)
        self.assertLessEqual(len(rows), 12)
        for r in rows:
            self.assertEqual(r["era"], "back")
            self.assertIn(r["decade"], self.cfg["decades"])
            self.assertEqual(r["decade"], bc.decade_of(r["year"]))
            self.assertTrue(r["source"].startswith("back:"))
            self.assertTrue(r.get("track_id"))
        names = {(r["artist"], r["title"]) for r in rows}
        self.assertNotIn(("New Band", "Fresh One"), names)  # 2026: new music, not back catalogue
        self.assertFalse(any(a == "KidsBand" for a, _ in names))  # children's genre on the catalogue
        self.assertFalse(any(a == "Nobody Real" for a, _ in names))  # not on the catalogue: dropped
        self.assertEqual({r["source"] for r in rows}, {"back:radio", "back:canon", "back:llm"})
        can = next(r for r in rows if r["artist"] == "Can")
        self.assertEqual(can["year"], 1972)  # the station's year beats the 2011 remaster
        self.assertEqual(len({r["decade"] for r in rows}), len(doc["offered_by_decade"]))
        self.assertGreaterEqual(len(doc["offered_by_decade"]), 4)
        # Decades are taken in turn in the output.
        self.assertNotEqual(rows[0]["decade"], rows[1]["decade"])
        self.assertEqual(len({bc.artist_fold(r["artist"]) for r in rows}), len(rows))  # one per artist
        self.assertEqual(self.picks[0]["task"], "suggest_older_tracks")
        self.assertEqual(self.picks[0]["decades"], self.cfg["decades"])
        self.assertIn("pitchfork.com", doc["not_read"])

    def test_years_are_remembered_so_the_next_night_asks_less(self):
        scout.source_backcatalogue(self.cfg, self.paths, self.runners(llm_reply="[]"), set())
        first = len(self.lookups)
        self.lookups.clear()
        scout.source_backcatalogue(self.cfg, self.paths, self.runners(llm_reply="[]"), set())
        self.assertLess(len(self.lookups), first)
        cache = json.loads((self.state / "backcatalogue" / "years.json").read_text())
        self.assertEqual(cache[radio.match_key("Slint", "Good Morning, Captain")]["year"], 1991)

    def test_owned_and_offered_tracks_are_skipped(self):
        scout.append_jsonl(self.paths.ledger, {"at": NOW, "action": "offered", "artist": "Can", "title": "Vitamin C",
                                               "track_key": scout.track_key("Can", "Vitamin C")})
        rows, _ = scout.source_backcatalogue(self.cfg, self.paths, self.runners(llm_reply="[]"), set())
        self.assertNotIn("Can", [r["artist"] for r in rows])

    def test_a_track_another_source_offers_tonight_is_left_to_it(self):
        rows, _ = scout.source_backcatalogue(self.cfg, self.paths, self.runners(llm_reply="[]"), set(),
                                             tonight=[{"artist": "Can", "title": "Vitamin C", "source": "radio:nts"}])
        self.assertNotIn("Can", [r["artist"] for r in rows])

    def test_nothing_offered_once_the_back_half_of_the_week_is_full(self):
        for i in range(12):
            scout.append_jsonl(self.paths.ledger, {"at": NOW, "action": "acquired", "artist": f"A{i}", "title": "T",
                                                   "year": 1975, "decade": "1970s", "era": "back", "size_bytes": 1})
        rows, doc = scout.source_backcatalogue(self.cfg, self.paths, self.runners(), set())
        self.assertEqual(rows, [])
        self.assertIn("held_back", doc)
        self.assertEqual(self.picks, [])  # no LLM call, no lookups
        self.assertEqual(self.lookups, [])

    def test_a_decade_already_full_this_week_gets_no_more(self):
        for i in range(2):
            scout.append_jsonl(self.paths.ledger, {"at": NOW, "action": "acquired", "artist": f"B{i}", "title": "T",
                                                   "year": 1972, "decade": "1970s", "era": "back", "size_bytes": 1})
        # Four slots tonight, and four decades that still need records: the full one waits. (Slots a
        # thin decade cannot fill do go to the others, a full one included; see allocate.)
        cfg = dict(self.cfg, backcatalogue_max_candidates=4)
        rows, doc = scout.source_backcatalogue(cfg, self.paths, self.runners(), set())
        self.assertEqual(doc["deficits"]["1970s"], 0)
        self.assertEqual(len(rows), 4)
        self.assertNotIn("1970s", [r["decade"] for r in rows])

    def test_candidates_carry_years_and_the_report(self):
        cfg = dict(self.cfg, radio_enabled=False)
        merged, counts, errors = scout.cmd_candidates(cfg, self.paths, self.runners(llm_reply="[]"))
        self.assertGreater(counts["backcatalogue"], 0)
        doc = json.loads(self.paths.candidates.read_text())
        self.assertIn("backcatalogue", doc)
        back = [r for r in merged if r.get("source", "").startswith("back:")]
        self.assertTrue(all(r["era"] == "back" and r["decade"] for r in back))


class EraQuotaTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.state = self.root / "state"
        self.state.mkdir()
        self.paths = scout.ScoutPaths(self.state)
        self.cfg = _cfg(self.root, backcatalogue_enabled=True, tracks_per_week=10, backcatalogue_share=0.5,
                        max_per_artist_week=5, exploration_share=0.0,
                        media_share=str(self.root / "media"), playback_log=str(self.root / "pb.jsonl"))

    def tearDown(self):
        self.tmp.cleanup()

    def write_candidates(self, rows):
        self.paths.candidates.write_text(json.dumps({"candidates": rows}), encoding="utf-8")

    def test_back_and_new_alternate_within_each_half_of_the_week(self):
        new = [{"artist": f"New {i}", "title": "Song", "source": "radio:kexp", "score_hint": 0.9, "era": "new"} for i in range(8)]
        back = [{"artist": f"Old {i}", "title": "Song", "source": "back:canon", "score_hint": 0.7, "era": "back",
                 "year": 1960 + 10 * (i % 3), "decade": f"{1960 + 10 * (i % 3)}s"} for i in range(8)]
        self.write_candidates(new + back)
        runners = scout.Runners(clock=lambda: NOW)
        ranked = scout.cmd_rank(self.cfg, self.paths, runners)
        eras = [r.get("era") for r in ranked]
        self.assertEqual(eras.count("back"), 5)
        self.assertEqual(eras.count("new"), 5)
        self.assertEqual(eras[:4], ["back", "new", "back", "new"])
        self.assertNotEqual(ranked[0]["decade"], ranked[2]["decade"])  # decades in turn
        # Only what was queued is recorded as offered: the rest is still there tomorrow.
        offered = [r for r in scout.read_jsonl_rows(self.paths.ledger) if r["action"] == "offered"]
        self.assertEqual(len(offered), 10)
        queue = json.loads(self.paths.queue.read_text())
        self.assertEqual(queue["era"]["held"], {"back": 3, "new": 3})

    def test_priority_rows_go_first_and_count_toward_their_half(self):
        rows = [{"artist": "Shazam Act", "title": "Mine", "source": "shazam", "priority": True, "score_hint": 2.0}]
        rows += [{"artist": f"New {i}", "title": "Song", "source": "radio:kexp", "score_hint": 0.9} for i in range(8)]
        self.write_candidates(rows)
        ranked = scout.cmd_rank(self.cfg, self.paths, scout.Runners(clock=lambda: NOW))
        self.assertEqual(ranked[0]["source"], "shazam")
        self.assertEqual(len(ranked), 5)  # the Shazam and four more new: the new half is five

    def test_a_disabled_back_catalogue_leaves_rank_alone(self):
        cfg = dict(self.cfg, backcatalogue_enabled=False)
        rows = [{"artist": f"New {i}", "title": "Song", "source": "radio:kexp", "score_hint": 0.9} for i in range(8)]
        self.write_candidates(rows)
        ranked = scout.cmd_rank(cfg, self.paths, scout.Runners(clock=lambda: NOW))
        self.assertEqual(len(ranked), 8)
        self.assertNotIn("era", json.loads(self.paths.queue.read_text()))


class AcquireAndStatusTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.state = self.root / "state"
        self.state.mkdir()
        self.paths = scout.ScoutPaths(self.state)
        self.cfg = _cfg(self.root, backcatalogue_enabled=True, hot_dir=str(self.root / "hot"),
                        apple_music_dir=str(self.root / "am"),
                        media_share=str(self.root / "media"), playback_log=str(self.root / "pb.jsonl"))
        self.paths.queue.write_text(json.dumps({"tracks": [
            {"artist": "Can", "title": "Vitamin C", "track_id": 11, "source": "back:radio", "year": 1972,
             "decade": "1970s", "era": "back", "canon": ["x"]},
            {"artist": "New Band", "title": "Fresh One", "source": "radio:kexp"},
        ]}), encoding="utf-8")
        self.uploads: list[Path] = []

    def tearDown(self):
        self.tmp.cleanup()

    def runners(self, publish=None):
        def song_best(artist, title, album="", *, sleep=None):
            return {"trackId": 22, "trackName": title, "artistName": artist, "releaseDate": "2026-09-01T00:00:00Z",
                    "trackTimeMillis": 180000}

        def publisher(path):
            self.uploads.append(path)
            return None

        return scout.Runners(clock=lambda: NOW, is_m5=lambda: True, is_metered=lambda: False, on_battery=lambda: False,
                             itunes_song_best=song_best, run_amdl=lambda url: (True, False, "", {"size_bytes": 1000}),
                             publish_status=publish or publisher)

    def test_acquired_rows_carry_year_decade_and_era(self):
        dry = scout.cmd_acquire(self.cfg, self.paths, self.runners(), go=False)
        self.assertEqual((dry["results"][0]["decade"], dry["results"][0]["source"]), ("1970s", "back:radio"))
        summary = scout.cmd_acquire(self.cfg, self.paths, self.runners(), go=True)
        got = {r["artist"]: r for r in summary["results"]}
        self.assertEqual((got["Can"]["year"], got["Can"]["decade"], got["Can"]["era"]), (1972, "1970s", "back"))
        self.assertEqual(got["Can"]["canon"], ["x"])
        # A new row is dated from the catalogue release found for it.
        self.assertEqual((got["New Band"]["year"], got["New Band"]["era"]), (2026, "new"))

    def test_old_radio_and_taste_picks_count_in_the_new_half(self):
        rows = [{"artist": "Radio Act", "title": "Old One", "source": "radio:kexp", "year": 2015},
                {"artist": "Back Act", "title": "Older", "source": "back:canon", "era": "back", "year": 1969}]
        tagged = [scout.tag_era(dict(r), self.cfg["decades"]) for r in rows]
        self.assertEqual([(r["era"], r["decade"]) for r in tagged], [("new", "2010s"), ("back", "1960s")])

    def test_status_document_counts_the_week_and_holds_no_paths(self):
        scout.cmd_acquire(self.cfg, self.paths, self.runners(), go=True)
        scout.record_last_run(self.paths, ok=True, stage="run", clock=NOW,
                              detail={"counts": {"backcatalogue": 3, "radio:kexp": 400}, "errors": ["x at /Users/a"],
                                      "queue": 2, "acquire": {"dry_run": False, "results": [
                                          {"action": "acquired", "local_path": "/Users/a/b.m4a"}, {"action": "no_match"}]}})
        doc = scout.build_scout_status(dict(self.cfg, tracks_per_week=200, gb_per_week=10), self.paths, self.runners())
        self.assertEqual(doc["acquiredThisWeek"], 2)
        self.assertEqual((doc["budgetTracks"], doc["budgetGb"], doc["backcatalogueShare"]), (200, 10.0, 0.5))
        self.assertEqual(doc["byDecadeThisWeek"]["1970s"], 1)
        self.assertEqual(doc["byDecadeThisWeek"]["1960s"], 0)
        self.assertEqual(doc["byDecadeThisWeek"]["2020s"], 1)
        self.assertEqual(doc["newVsBack"], {"new": 1, "back": 1})
        self.assertEqual(doc["lastRun"]["acquired"], 1)
        self.assertEqual(doc["lastRun"]["noMatch"], 1)
        self.assertEqual(doc["lastRun"]["candidates"], {"backcatalogue": 3})
        self.assertNotIn("/Users", json.dumps(doc))

    def test_publish_writes_the_file_and_a_failed_upload_does_not_raise(self):
        self.assertIsNone(scout.publish_scout_status(self.cfg, self.paths, self.runners()))
        self.assertEqual(self.uploads, [self.state / "scout-status.json"])
        self.assertEqual(json.loads(self.uploads[0].read_text())["schemaVersion"], 1)
        err = scout.publish_scout_status(self.cfg, self.paths, self.runners(publish=lambda p: "rclone exit 5: denied"))
        self.assertIn("rclone exit 5", err)

        def boom(path):
            raise OSError("disk")
        self.assertIn("OSError", scout.publish_scout_status(self.cfg, self.paths, self.runners(publish=boom)))

    def test_the_run_publishes_status_even_when_it_defers(self):
        runners = self.runners()
        runners.is_m5 = lambda: False
        runners.ai_pick = lambda *a, **k: (75, "")
        cfg = dict(self.cfg, backcatalogue_enabled=False)
        with self.assertRaises(SystemExit):
            scout.cmd_run(cfg, self.paths, runners, go=True)
        self.assertEqual(len(self.uploads), 1)
        self.assertFalse(json.loads(self.uploads[0].read_text())["lastRun"]["ok"])

    def test_rclone_publisher_copies_to_the_status_path(self):
        calls = []

        class Proc:
            returncode = 0
            stdout = stderr = ""

        rclone = self.root / "rclone"
        rclone.write_text("#!/bin/sh\n")
        cfg = dict(self.cfg, rclone=str(rclone))
        orig = scout.subprocess.run
        scout.subprocess.run = lambda argv, **kw: (calls.append(argv), Proc())[1]
        try:
            self.assertIsNone(scout.rclone_publisher(cfg)(self.root / "s.json"))
        finally:
            scout.subprocess.run = orig
        self.assertEqual(calls[0], [str(rclone), "copyto", str(self.root / "s.json"),
                                    "glancebar-music:glancebar-music/radio/scout-status.json"])


if __name__ == "__main__":
    unittest.main()
