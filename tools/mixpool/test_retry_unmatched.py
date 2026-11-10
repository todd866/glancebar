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


class SameSongTests(unittest.TestCase):
    def test_search_rejects_other_songs_by_the_same_artist(self):
        results = [
            {"wrapperType": "track", "trackId": 1, "artistName": "Funkadelic",
             "trackName": "Can You Get To That", "collectionName": "Maggot Brain"},
            {"wrapperType": "track", "trackId": 2, "artistName": "Someone Else",
             "trackName": "Maggot Brain", "collectionName": "Covers"},
        ]
        with mock.patch.object(mixpool, "_itunes_search", return_value=results), \
                mock.patch.object(mixpool, "_itunes_album_tracks", return_value=[]):
            self.assertEqual(mixpool.itunes_song("Funkadelic", "Maggot Brain", "Maggot Brain"), [])
        results.append({"wrapperType": "track", "trackId": 3, "artistName": "Funkadelic",
                        "trackName": "Maggot Brain (Remastered)", "collectionName": "Maggot Brain"})
        with mock.patch.object(mixpool, "_itunes_search", return_value=results), \
                mock.patch.object(mixpool, "_itunes_album_tracks", return_value=[]) as by_album:
            got = mixpool.itunes_song("Funkadelic", "Maggot Brain", "Maggot Brain")
        self.assertEqual([r["trackId"] for r in got], [3])
        by_album.assert_not_called()  # already found on the wanted album

    def test_album_lookup_finds_a_song_the_song_search_leaves_out(self):
        song_search = [{"wrapperType": "track", "trackId": 1, "artistName": "Frank Ocean",
                        "trackName": "White Ferrari", "collectionName": "Blonde"}]
        album_tracks = [{"wrapperType": "track", "trackId": 9, "artistName": "Frank Ocean",
                         "trackName": "Nights", "collectionName": "Blonde"}]
        with mock.patch.object(mixpool, "_itunes_search", return_value=song_search), \
                mock.patch.object(mixpool, "_itunes_album_tracks", return_value=album_tracks) as by_album:
            got = mixpool.itunes_song("Frank Ocean", "Nights", "Blonde")
        self.assertEqual([r["trackId"] for r in got], [9])
        by_album.assert_called_once_with("Frank Ocean", "Blonde", song_search)

    def test_failed_lookup_is_not_no_match(self):
        with mock.patch.object(mixpool, "_itunes_search", return_value=None), \
                mock.patch.object(mixpool, "_itunes_album_tracks", return_value=None):
            with self.assertRaises(mixpool.LookupFailed):
                mixpool.itunes_song("Frank Ocean", "Nights", "Blonde")
            self.assertIsNone(mixpool.itunes_song_best("Frank Ocean", "Nights", "Blonde"))
        self.assertEqual(mixpool._album_core("Blonde (Deluxe Edition) - EP"), "Blonde")

    def test_remix_is_not_the_song(self):
        self.assertFalse(mixpool._title_agrees("Gosh (Someone Remix)", "Gosh"))
        self.assertTrue(mixpool._title_agrees("Slide (feat. Frank Ocean & Migos)", "Slide"))
        self.assertTrue(mixpool._title_agrees("Emerald Rush", "Emerald Rush (Mixed)"))
        self.assertFalse(mixpool._title_agrees("Reviver (TEED Remix)", "Reviver (Mixed)"))

    def test_audit_moves_wrong_rows_only_with_apply(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / "liked-pulled.json"
            state.write_text(json.dumps({"done": {
                "Funkadelic|Maggot Brain": {"track_id": 1, "url": "https://music.apple.com/au/song/can-you-get-to-that/1"},
                "Beat Connection|Think / Feel (feat. Chelsey Scheffe)": {"track_id": 2, "url": "https://music.apple.com/au/song/think-/-feel-(feat.-chelsey-scheffe)/2"},
                "Jamie xx|Gosh": {"track_id": 3, "url": "https://music.apple.com/au/song/gosh/3"},
            }, "failed": {}, "no_match": {}}))
            with mock.patch.object(mixpool, "LIKED_STATE", state):
                mixpool.audit_liked()
                self.assertEqual(len(json.loads(state.read_text())["done"]), 3)
                mixpool.audit_liked(apply=True)
            doc = json.loads(state.read_text())
            self.assertEqual(sorted(doc["done"]), ["Beat Connection|Think / Feel (feat. Chelsey Scheffe)", "Jamie xx|Gosh"])
            self.assertEqual(doc["wrong_song"]["Funkadelic|Maggot Brain"]["downloaded"], "can you get to that")


if __name__ == "__main__":
    unittest.main()
