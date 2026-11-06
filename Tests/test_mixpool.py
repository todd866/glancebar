"""mixpool pull-liked: ranking, amdl failures, and resume. No network."""

from __future__ import annotations

import io
import json
import sys
import tempfile
import threading
import time
import unittest
import urllib.parse
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools" / "mixpool"))
import mixpool


def track(artist, title, collection, track_id, collection_artist=None, wrapper="track"):
    row = {
        "wrapperType": wrapper,
        "artistName": artist,
        "trackName": title,
        "collectionName": collection,
        "trackId": track_id,
    }
    if collection_artist is not None:
        row["collectionArtistName"] = collection_artist
    return row


class _Body:
    def __init__(self, payload: dict):
        self._data = json.dumps(payload).encode()

    def read(self, _n=-1):
        data, self._data = self._data, b""
        return data

    def __enter__(self):
        return self

    def __exit__(self, *_exc):
        return False


def _results(rows):
    return _Body({"results": rows})


class FakeProc:
    """amdl stand-in. Blocks after its scripted lines until kill()."""

    def __init__(self, lines, returncode=0, block_after=False):
        self._lines = list(lines)
        self._i = 0
        self._release = threading.Event()
        self.block_after = block_after
        self.killed = False
        self.returncode = None
        self._rc = returncode
        self.stdout = self
        self.args: list = []
        self.kwargs: dict = {}

    def __iter__(self):
        return self

    def __next__(self):
        if self._i < len(self._lines):
            line = self._lines[self._i]
            self._i += 1
            return line
        if self.block_after and not self.killed:
            self._release.wait(5)
            if not self.killed:
                raise AssertionError("amdl was not killed while blocked")
        raise StopIteration

    def kill(self):
        self.killed = True
        self.returncode = -9
        self._release.set()

    def poll(self):
        return self.returncode

    def wait(self, timeout=None):
        if self.returncode is None:
            self.returncode = self._rc
        return self.returncode

    def close(self):
        self._release.set()


def _term(url: str) -> str:
    return urllib.parse.parse_qs(urllib.parse.urlparse(url).query)["term"][0]


class RankingTests(unittest.TestCase):
    ROWS = [
        track("Air", "Sexy Boy", "Moon Safari", 10, "Various Artists"),
        track("Air", "Sexy Boy", "Greatest Hits", 2),
        track("Air", "Sexy Boy", "Now That's What I Call Music 90", 1, "Various Artists"),
        track("Air", "Sexy Boy", "Best of 2019", 3),
        track("Air", "Sexy Boy", "The Annual 1999", 4),
        track("Air", "Sexy Boy", "Live 2014", 5),
        track("Air", "Sexy Boy", "Moon Safari", 6),
        track("Air", "Sexy Boy", "Sexy Boy - Single", 7),
        track("Someone Else", "Other", "Other Album", 9),
        track("Air", "Sexy Boy", "Moon Safari", 8, wrapper="collection"),
    ]

    def _search(self, *_args, **_kwargs):
        return _results(self.ROWS)

    def test_compilation_skipped_when_original_matches(self):
        with patch.object(mixpool.urllib.request, "urlopen", side_effect=self._search):
            by_album = [
                row["trackId"] for row in mixpool.itunes_song("Air", "Sexy Boy", "Moon Safari")
            ]
            hits_outranks = [
                row["trackId"] for row in mixpool.itunes_song("Air", "Sexy Boy", "Greatest Hits")
            ]
            best = mixpool.itunes_song_best("Air", "Sexy Boy", "Moon Safari")
        # Moon Safari scores above the other originals. Hits would score higher
        # when the favourite names that album, and is still dropped.
        self.assertEqual(by_album, [6, 5, 7])
        self.assertEqual(hits_outranks, [5, 6, 7])
        self.assertEqual(best["trackId"], 6)
        for skipped in (10, 2, 1, 3, 4, 9, 8):
            self.assertNotIn(skipped, by_album)
            self.assertNotIn(skipped, hits_outranks)

    def test_compilation_kept_when_nothing_else_matches(self):
        only = [track("Air", "Sexy Boy", "Greatest Hits", 2, "Various Artists")]
        with patch.object(mixpool.urllib.request, "urlopen", return_value=_results(only)):
            ranked = mixpool.itunes_song("Air", "Sexy Boy", "Moon Safari")
        self.assertEqual([row["trackId"] for row in ranked], [2])


class PullTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.inv = root / "inventory.json"
        self.state_path = root / "liked-pulled.json"
        self._old_state = mixpool.LIKED_STATE
        self._old_dir = mixpool.STATE_DIR
        self._old_timeout = mixpool.AMDL_TIMEOUT
        mixpool.LIKED_STATE = self.state_path
        mixpool.STATE_DIR = root
        self.addCleanup(self._restore)

    def _restore(self):
        mixpool.LIKED_STATE = self._old_state
        mixpool.STATE_DIR = self._old_dir
        mixpool.AMDL_TIMEOUT = self._old_timeout

    def _inventory(self, favs):
        self.inv.write_text(json.dumps({"am_fav": favs}))

    def _run(self, popen, urlopen):
        out, err = io.StringIO(), io.StringIO()
        with (
            patch.object(mixpool.subprocess, "Popen", side_effect=popen),
            patch.object(mixpool.urllib.request, "urlopen", side_effect=urlopen),
            redirect_stdout(out),
            redirect_stderr(err),
        ):
            rc = mixpool.pull_liked(self.inv, retry_failed=getattr(self, "retry", False))
        return rc, out.getvalue(), err.getvalue()

    def test_falls_back_to_second_candidate(self):
        self._inventory([{"artist": "Air", "title": "Sexy Boy", "album": "Moon Safari"}])
        rows = [
            track("Air", "Sexy Boy", "Now That's What I Call Music 90", 1, "Various Artists"),
            track("Air", "Sexy Boy", "Moon Safari", 6),
            track("Air", "Sexy Boy", "Sexy Boy - Single", 7),
        ]
        procs = []

        def urlopen(*_a, **_k):
            return _results(rows)

        def popen(args, **kwargs):
            n = len(procs)
            if n == 0:
                proc = FakeProc(
                    [
                        "ALAC Unavailable\n",
                        "Failed to dl aac-lc via lite-server: webplayback not available\n",
                    ],
                    returncode=0,
                )
            else:
                proc = FakeProc(["saved\n"], returncode=0)
            proc.args = list(args)
            proc.kwargs = kwargs
            procs.append(proc)
            return proc

        rc, out, err = self._run(popen, urlopen)
        self.assertEqual(rc, 0)
        self.assertEqual(len(procs), 2)
        self.assertTrue(procs[0].args[-1].endswith("/6"))
        self.assertTrue(procs[1].args[-1].endswith("/7"))
        self.assertFalse(any(args_end_with(p, "/1") for p in procs))
        self.assertFalse(procs[0].killed)
        self.assertEqual(procs[0].returncode, 0)
        state = json.loads(self.state_path.read_text())
        self.assertEqual(state["done"]["Air|Sexy Boy"]["track_id"], 7)
        self.assertNotIn("Air|Sexy Boy", state["failed"])
        self.assertIn("webplayback not available", err)
        self.assertIn("done 1 / failed 0 / no-match 0", out)

    def test_press_enter_kills_process(self):
        self._inventory([{"artist": "Air", "title": "Sexy Boy", "album": "Moon Safari"}])
        procs = []

        def urlopen(*_a, **_k):
            return _results([track("Air", "Sexy Boy", "Moon Safari", 6)])

        def popen(args, **kwargs):
            proc = FakeProc(
                [
                    "Track 1\n",
                    "Error detected, press Enter to try again...\n",
                    "should not be read\n",
                ],
                returncode=0,
                block_after=True,
            )
            proc.args = list(args)
            proc.kwargs = kwargs
            procs.append(proc)
            return proc

        started = time.monotonic()
        rc, out, err = self._run(popen, urlopen)
        self.assertLess(time.monotonic() - started, 3)
        self.assertEqual(rc, 0)
        self.assertEqual(len(procs), 1)
        proc = procs[0]
        self.assertTrue(proc.killed)
        self.assertEqual(proc._i, 2)
        self.assertIs(proc.kwargs["stdin"], __import__("subprocess").DEVNULL)
        self.assertIs(proc.kwargs["stdout"], __import__("subprocess").PIPE)
        self.assertIs(proc.kwargs["stderr"], __import__("subprocess").STDOUT)
        self.assertTrue(proc.kwargs["text"])
        self.assertIn("Track 1", out)
        self.assertIn("press Enter to try again", out)
        self.assertNotIn("should not be read", out)
        state = json.loads(self.state_path.read_text())
        self.assertEqual(state["failed"]["Air|Sexy Boy"]["tried"], [6])
        self.assertEqual(state["failed"]["Air|Sexy Boy"]["last_error"], "press Enter to try again")
        self.assertNotIn("Air|Sexy Boy", state["done"])
        self.assertIn("candidate 6 failed: press Enter to try again", err)
        self.assertIn("done 0 / failed 1 / no-match 0", out)

    def test_zero_exit_unavailable_without_aac_failure_is_success(self):
        self._inventory([{"artist": "Air", "title": "Sexy Boy", "album": "Moon Safari"}])

        def urlopen(*_a, **_k):
            return _results([track("Air", "Sexy Boy", "Moon Safari", 6)])

        def popen(args, **kwargs):
            return FakeProc(["codec ALAC: Unavailable\n", "saved aac-lc\n"], returncode=0)

        rc, out, _err = self._run(popen, urlopen)
        self.assertEqual(rc, 0)
        state = json.loads(self.state_path.read_text())
        self.assertIn("Air|Sexy Boy", state["done"])
        self.assertEqual(state["failed"], {})
        self.assertIn("done 1 / failed 0 / no-match 0", out)

    def test_failed_skipped_on_rerun(self):
        self._inventory([{"artist": "Air", "title": "Sexy Boy", "album": "Moon Safari"}])
        rows = [track("Air", "Sexy Boy", f"Album {i}", 100 + i) for i in range(1, 5)]
        rows.append(track("Air", "Sexy Boy", "Greatest Hits", 201, "Various Artists"))
        mode = {"fail": True}
        procs = []

        def urlopen(*_a, **_k):
            return _results(rows)

        def popen(args, **kwargs):
            if mode["fail"]:
                proc = FakeProc(["Errors: 1\n"], returncode=0)
            else:
                proc = FakeProc(["saved\n"], returncode=0)
            proc.args = list(args)
            proc.kwargs = kwargs
            procs.append(proc)
            return proc

        rc, out, _err = self._run(popen, urlopen)
        self.assertEqual(rc, 0)
        self.assertEqual(len(procs), 3)
        self.assertTrue(all(p.returncode == 0 and not p.killed for p in procs))
        self.assertEqual([p.args[-1].rsplit("/", 1)[-1] for p in procs], ["101", "102", "103"])
        state = json.loads(self.state_path.read_text())
        failed = state["failed"]["Air|Sexy Boy"]
        self.assertEqual(failed["tried"], [101, 102, 103])
        self.assertEqual(failed["last_error"], "Errors: 1")
        self.assertRegex(failed["at"], r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$")
        self.assertNotIn("Air|Sexy Boy", state["done"])
        self.assertIn("done 0 / failed 1 / no-match 0", out)

        rc, out, _err = self._run(popen, urlopen)
        self.assertEqual(rc, 0)
        self.assertEqual(len(procs), 3)
        self.assertIn("1 failed", out)
        self.assertIn("0 to pull", out)

        mode["fail"] = False
        self.retry = True
        rc, out, _err = self._run(popen, urlopen)
        self.retry = False
        self.assertEqual(rc, 0)
        self.assertEqual(len(procs), 4)
        self.assertTrue(procs[3].args[-1].endswith("/101"))
        state = json.loads(self.state_path.read_text())
        self.assertEqual(state["done"]["Air|Sexy Boy"]["track_id"], 101)
        self.assertNotIn("Air|Sexy Boy", state["failed"])
        self.assertIn("done 1 / failed 0 / no-match 0", out)

    def test_timeout_kills(self):
        mixpool.AMDL_TIMEOUT = 0.5
        self._inventory([{"artist": "Air", "title": "Sexy Boy", "album": "Moon Safari"}])
        procs = []

        def urlopen(*_a, **_k):
            return _results([track("Air", "Sexy Boy", "Moon Safari", 6)])

        def popen(args, **kwargs):
            proc = FakeProc([], block_after=True)
            proc.args = list(args)
            proc.kwargs = kwargs
            procs.append(proc)
            return proc

        started = time.monotonic()
        rc, _out, err = self._run(popen, urlopen)
        self.assertLess(time.monotonic() - started, 4)
        self.assertEqual(rc, 0)
        self.assertTrue(procs[0].killed)
        state = json.loads(self.state_path.read_text())
        self.assertEqual(state["failed"]["Air|Sexy Boy"]["last_error"], "timeout")
        self.assertNotIn("5 in a row failed", err)

    def test_infra_streak_stops_without_marking_failed(self):
        favs = [{"artist": f"A{i}", "title": f"T{i}", "album": "Album"} for i in range(6)]
        self._inventory(favs)
        procs = []

        def urlopen(url, timeout=30):
            artist, title = _term(url).split(" ", 1)
            return _results([track(artist, title, "Album", 1000 + len(procs))])

        def popen(args, **kwargs):
            msg = (
                "guest failed to come up\n"
                if len(procs) % 2 == 0
                else "dial tcp: connection refused\n"
            )
            proc = FakeProc([msg], returncode=1)
            proc.args = list(args)
            procs.append(proc)
            return proc

        rc, out, err = self._run(popen, urlopen)
        self.assertEqual(rc, 1)
        self.assertEqual(len(procs), 5)
        self.assertFalse(self.state_path.exists())
        self.assertIn("5 in a row failed — stopping (rerun to resume)", err)
        self.assertIn("done 0 / failed 0 / no-match 0", out)

    def test_content_errors_do_not_abort(self):
        favs = [{"artist": f"A{i}", "title": f"T{i}", "album": "Album"} for i in range(6)]
        self._inventory(favs)
        calls = {"n": 0}

        def urlopen(url, timeout=30):
            artist, title = _term(url).split(" ", 1)
            calls["n"] += 1
            return _results([track(artist, title, "Album", calls["n"])])

        def popen(args, **kwargs):
            return FakeProc(["Error detected\n"], returncode=1)

        rc, out, err = self._run(popen, urlopen)
        self.assertEqual(rc, 0)
        self.assertEqual(calls["n"], 6)
        state = json.loads(self.state_path.read_text())
        self.assertEqual(len(state["failed"]), 6)
        self.assertEqual(state["done"], {})
        self.assertNotIn("5 in a row failed", err)
        self.assertIn("done 0 / failed 6 / no-match 0", out)


def args_end_with(proc: FakeProc, suffix: str) -> bool:
    return bool(proc.args) and str(proc.args[-1]).endswith(suffix)


if __name__ == "__main__":
    unittest.main()
