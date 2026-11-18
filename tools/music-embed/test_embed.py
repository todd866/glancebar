#!/usr/bin/env python3
"""Unit tests for music embed CLI. No network, no real ffmpeg, no google-genai import."""
from __future__ import annotations

import json
import struct
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import embed


class JobStateTests(unittest.TestCase):
    def test_sdk_enum_and_rest_strings(self):
        import enum

        class JobState(enum.Enum):
            JOB_STATE_SUCCEEDED = "JOB_STATE_SUCCEEDED"

        for raw in ("JobState.JOB_STATE_SUCCEEDED", "JOB_STATE_SUCCEEDED", "SUCCEEDED", JobState.JOB_STATE_SUCCEEDED):
            self.assertEqual(embed.normalise_job_state(raw), "SUCCEEDED")


class ClipWindowTests(unittest.TestCase):
    def test_short_track_one_clip(self):
        self.assertEqual(embed.clip_windows(30.0), [(0.0, 30.0)])

    def test_exactly_eighty_one_clip(self):
        self.assertEqual(embed.clip_windows(80.0), [(0.0, 80.0)])

    def test_long_track_three_windows(self):
        wins = embed.clip_windows(200.0)
        self.assertEqual(len(wins), 3)
        self.assertEqual(wins[0], (0.0, 80.0))
        self.assertAlmostEqual(wins[1][0], 60.0)
        self.assertAlmostEqual(wins[1][1], 80.0)
        self.assertAlmostEqual(wins[2][0], 120.0)
        self.assertAlmostEqual(wins[2][1], 80.0)


class KeyTests(unittest.TestCase):
    def test_round_trip(self):
        key = embed.clip_key("abc" * 10 + "ab", 2)
        sha, idx = embed.parse_clip_key(key)
        self.assertEqual(idx, 2)
        self.assertEqual(sha, "abc" * 10 + "ab")


class ShardTests(unittest.TestCase):
    def test_split_by_size(self):
        rows = [
            ("a", b"x" * 50 + b"\n"),
            ("b", b"y" * 50 + b"\n"),
            ("c", b"z" * 50 + b"\n"),
        ]
        shards = embed.shard_jsonl_lines(rows, max_bytes=120)
        self.assertEqual(len(shards), 2)
        self.assertEqual(len(shards[0]), 2)
        self.assertEqual(len(shards[1]), 1)


class ParseResultTests(unittest.TestCase):
    def test_response_embedding_values(self):
        line = {"key": "k1", "response": {"embedding": {"values": [1.0, 2.0]}}}
        key, vals, err = embed.parse_result_line(line)
        self.assertEqual(key, "k1")
        self.assertEqual(vals, [1.0, 2.0])
        self.assertIsNone(err)

    def test_response_embeddings_array(self):
        line = {"key": "k2", "response": {"embeddings": [{"values": [3.0]}]}}
        _, vals, _ = embed.parse_result_line(line)
        self.assertEqual(vals, [3.0])

    def test_top_level_embedding(self):
        _, vals, _ = embed.parse_result_line({"embedding": {"values": [4.0]}})
        self.assertEqual(vals, [4.0])

    def test_error_object(self):
        key, vals, err = embed.parse_result_line({"key": "k", "error": {"code": 1}})
        self.assertEqual(err, {"code": 1})
        self.assertIsNone(vals)


class TrackVectorTests(unittest.TestCase):
    def test_mean_and_l2_normalise(self):
        clip_index = [
            {"key": "s1:0", "sha": "s1", "artist": "A", "title": "T1", "album": "Al"},
            {"key": "s1:1", "sha": "s1", "artist": "A", "title": "T1", "album": "Al"},
        ]
        clip_vectors = [[1.0, 0.0], [3.0, 0.0]]
        rows, vecs = embed.track_vectors_from_clips(clip_index, clip_vectors)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["clips"], ["s1:0", "s1:1"])
        normed = vecs[0]
        mag = sum(x * x for x in normed) ** 0.5
        self.assertAlmostEqual(mag, 1.0, places=5)
        self.assertAlmostEqual(normed[0], 1.0, places=5)


class NeighbourTests(unittest.TestCase):
    def test_ranking(self):
        index = [
            {"artist": "Alpha", "title": "One"},
            {"artist": "Beta", "title": "Two"},
            {"artist": "Gamma", "title": "Three"},
        ]
        vectors = [
            [1.0, 0.0, 0.0],
            [0.9, 0.1, 0.0],
            [0.0, 1.0, 0.0],
        ]
        ranked = embed.neighbours_rank("Alpha", index, vectors, k=2)
        self.assertEqual(len(ranked), 2)
        self.assertEqual(ranked[0][1]["artist"], "Alpha")
        self.assertEqual(ranked[1][1]["artist"], "Beta")


class CostTests(unittest.TestCase):
    def test_arithmetic(self):
        est = embed.cost_estimate(1000.0)
        self.assertAlmostEqual(est["batchUsd"], 0.08)
        self.assertAlmostEqual(est["standardUsd"], 0.16)


class EmbedRequestLineTests(unittest.TestCase):
    def test_format(self):
        line = embed.embed_request_line("sha:0", "YQ==")
        self.assertEqual(line["key"], "sha:0")
        self.assertEqual(line["request"]["outputDimensionality"], 3072)
        part = line["request"]["content"]["parts"][0]["inlineData"]
        self.assertEqual(part["mimeType"], "audio/mpeg")


class ResumeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.state = self.root / "state"
        self.state.mkdir()
        paths = embed.Paths(self.state)
        paths.clips.mkdir(parents=True)
        sha = "deadbeef"
        (paths.clips / sha).mkdir()
        (paths.clips / sha / "0.mp3").write_bytes(b"mp3")
        track = {
            "id": sha,
            "relativePath": "x.m4a",
            "durationSeconds": 30.0,
            "tags": {"title": "t", "artist": "a", "album": "b"},
        }
        paths.tracks.write_text(json.dumps(track) + "\n", encoding="utf-8")
        src = self.root / "x.m4a"
        src.write_bytes(b"fake")
        self.paths = paths
        self.src = src

    def tearDown(self):
        self.tmp.cleanup()

    def test_clips_skip_existing(self):
        calls: list[list[str]] = []

        def fake_run(cmd, **kwargs):
            calls.append(cmd)
            return subprocess.CompletedProcess(cmd, 0, "", "")

        args = mock.Mock(
            state=self.state,
            root=self.root,
            ffmpeg_dir=Path("/usr/bin"),
            limit=None,
        )
        with mock.patch.object(embed, "ffmpeg_clip") as fc:
            embed.cmd_clips(args)
            fc.assert_not_called()

    def test_submit_skips_submitted_shard(self):
        paths = self.paths
        shard = paths.batches / "shard-000.jsonl"
        paths.batches.mkdir(parents=True)
        shard.write_text('{"key":"a:0"}\n', encoding="utf-8")
        paths.jobs.write_text(
            json.dumps(
                [
                    {
                        "shard": "shard-000",
                        "file_name": "files/x",
                        "job_name": "batches/1",
                        "created": "t",
                    }
                ]
            ),
            encoding="utf-8",
        )
        args = mock.Mock(state=self.state, model=embed.DEFAULT_MODEL, dry_run=True, resubmit=None)
        with mock.patch.object(embed, "get_genai_client") as gc:
            embed.cmd_submit(args)
            gc.assert_not_called()


class BuildResumeTests(unittest.TestCase):
    def test_build_skips_existing_shard(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)
            paths = embed.Paths(state)
            paths.batches.mkdir(parents=True)
            (paths.batches / "shard-000.jsonl").write_bytes(b"keep\n")
            sha = "aa"
            (paths.clips / sha).mkdir(parents=True)
            (paths.clips / sha / "0.mp3").write_bytes(b"x" * 10)
            args = mock.Mock(state=state, only_failed=False)
            embed.cmd_build(args)
            self.assertEqual((paths.batches / "shard-000.jsonl").read_bytes(), b"keep\n")


class GenreKindTests(unittest.TestCase):
    def test_genre_family_and_kind(self):
        self.assertEqual(embed.genre_family("Electronic"), "dance")
        self.assertEqual(embed.genre_family("Hip-Hop/Rap"), "rap")
        self.assertEqual(embed.genre_family("Pop"), "pop")
        self.assertEqual(embed.music_kind_for_genre("Electronic/Downtempo"), "chill")
        self.assertEqual(embed.music_kind_for_genre("Electronic"), "dance")
        self.assertEqual(embed.music_kind_for_genre("Pop"), "alt")
        self.assertEqual(embed.music_kind_for_genre(""), "other")


class MatchKeyTests(unittest.TestCase):
    def test_feat_and_brackets(self):
        a, t = embed.match_key("Fred again.., Bea", "Delilah (feat. Bea)")
        self.assertEqual(a, "fred again")
        self.assertEqual(t, "delilah")
        self.assertEqual(embed.normalize_title("Song - Remastered 2020"), "song")


class ExportSpaceTests(unittest.TestCase):
    def test_toy_space(self):
        index = [
            {"id": "v1", "artist": "A", "title": "One", "album": "LP"},
            {"id": "v2", "artist": "A", "title": "Two", "album": "LP"},
            {"id": "v3", "artist": "B", "title": "Rap", "album": ""},
        ]
        vectors = [
            [1.0, 0.0, 0.0],
            [0.99, 0.1, 0.0],
            [0.0, 1.0, 0.0],
        ]
        library = [
            {"id": "L1", "artist": "A", "title": "One", "album": "LP", "genre": "House"},
            {"id": "L2", "artist": "A", "title": "Two", "album": "LP", "genre": "House"},
            {"id": "L3", "artist": "B", "title": "Rap", "album": "", "genre": "Hip-Hop/Rap"},
        ]
        payload = embed.build_music_space(vectors, index, library, progress=False)
        self.assertEqual(payload["schemaVersion"], 1)
        self.assertEqual(payload["stats"]["matchedVectors"], 3)
        self.assertEqual(payload["tracks"]["L1"]["kind"], "dance")
        self.assertIn("L2", [p[0] for p in payload["tracks"]["L1"]["next"]])
        self.assertNotIn("L1", [p[0] for p in payload["tracks"]["L1"]["next"]])
        self.assertEqual(len(payload["tracks"]["L1"]["next"]), 2)


class F32RoundTrip(unittest.TestCase):
    def test_write_read(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "m.f32"
            rows = [[1.0, 2.0], [3.0, 4.0]]
            embed.write_f32_matrix(path, rows)
            back = embed.read_f32_matrix(path, dim=2)
            self.assertEqual(back, rows)


DIM = embed.VECTOR_DIM


def unit(i: int) -> list[float]:
    v = [0.0] * DIM
    v[i % DIM] = 1.0
    return v


def cat_entry(sha: str, rel: str, *, mtime: int = 0, duration: float = 200.0) -> dict:
    return {"sha256": sha, "relativePath": rel, "mtimeNs": str(mtime), "durationSeconds": duration,
            "sizeBytes": 4, "tags": {"title": f"T{sha}", "artist": f"A{sha}", "album": ""}}


class IncrementalBase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.state = Path(self.tmp.name) / "state"
        self.paths = embed.Paths(self.state)
        self.paths.vectors.mkdir(parents=True)
        # Two songs from the first full run.
        embed.write_f32_matrix(self.paths.tracks_f32, [unit(0), unit(1)])
        self.paths.tracks_index.write_text(
            "".join(json.dumps({"id": i, "artist": "x", "title": i, "album": "", "clips": [f"{i}:0"]}, sort_keys=True) + "\n"
                    for i in ("old1", "old2")),
            encoding="utf-8",
        )
        embed.write_f32_matrix(self.paths.clips_f32, [unit(0), unit(1)])
        self.paths.clips_index.write_text(
            "".join(json.dumps({"key": f"{i}:0", "sha": i}, sort_keys=True) + "\n" for i in ("old1", "old2")),
            encoding="utf-8",
        )
        self.catalogue = Path(self.tmp.name) / "catalogue.json"

    def tearDown(self):
        self.tmp.cleanup()

    def write_catalogue(self, entries):
        self.catalogue.write_text(json.dumps({"entries": entries}), encoding="utf-8")


class SpendTests(IncrementalBase):
    def test_missing_ledger_fails_closed(self):
        with self.assertRaises(embed.SpendError):
            embed.reserve_spend(self.paths, 0.01, 5.0)
        self.assertFalse(self.paths.spend.exists())

    def test_corrupt_ledger_fails_closed_and_is_kept(self):
        self.paths.spend.write_text("{not json", encoding="utf-8")
        with self.assertRaises(embed.SpendError):
            embed.reserve_spend(self.paths, 0.01, 5.0)
        with self.assertRaises(embed.SpendError):
            embed.init_spend(self.paths)  # never resets a ledger it cannot read
        self.assertEqual(self.paths.spend.read_text(encoding="utf-8"), "{not json")

    def test_reserve_within_cap_then_refuse(self):
        self.assertTrue(embed.init_spend(self.paths))
        now = 1_800_000_000.0
        self.assertAlmostEqual(embed.reserve_spend(self.paths, 3.0, 5.0, now=now), 3.0)
        self.assertAlmostEqual(embed.reserve_spend(self.paths, 2.0, 5.0, now=now), 5.0)
        before = self.paths.spend.read_text(encoding="utf-8")
        with self.assertRaises(embed.CapExceeded):
            embed.reserve_spend(self.paths, 0.01, 5.0, now=now)
        self.assertEqual(self.paths.spend.read_text(encoding="utf-8"), before)
        # A new UTC day starts at zero.
        self.assertAlmostEqual(embed.reserve_spend(self.paths, 1.0, 5.0, now=now + 86400), 1.0)

    def test_select_within_budget_is_greedy_in_order(self):
        songs = [{"durationSeconds": 200.0}, {"durationSeconds": 2000.0}, {"durationSeconds": 60.0}]
        cost = [embed.song_cost_usd(s["durationSeconds"]) for s in songs]
        pick = embed.select_within_budget(songs, cost[0] + cost[2] + 0.0001)
        self.assertEqual(pick, [songs[0], songs[2]])
        self.assertEqual(embed.select_within_budget(songs, 100.0, limit=1), [songs[0]])


class PendingAndGapTests(IncrementalBase):
    def test_pending_excludes_embedded_inflight_and_absent_from_r2(self):
        entries = [
            cat_entry("old1", "a.m4a", mtime=1),
            cat_entry("new1", "b.m4a", mtime=2),
            cat_entry("new2", "c.m4a", mtime=3),
            cat_entry("new3", "d.m4a", mtime=4),  # not in R2
            cat_entry("vid", "v.mp4", mtime=5),
            cat_entry("new1", "b-copy.m4a", mtime=6),  # same sha twice
            cat_entry("busy", "e.m4a", mtime=7),
        ]
        r2 = {"a.m4a", "b.m4a", "c.m4a", "v.mp4", "b-copy.m4a", "e.m4a"}
        got = embed.pending_entries(entries, {"old1"}, r2, {"busy"})
        self.assertEqual([e["sha256"] for e in got], ["new1", "new2"])
        self.assertEqual(got[0]["relativePath"], "b-copy.m4a")  # newest copy kept

    def test_inflight_ids(self):
        jobs = [{"state": "RUNNING", "ids": ["a"]}, {"state": "COLLECTED", "ids": ["b"]},
                {"state": "FAILED", "ids": ["c"]}, {"state": "SUCCEEDED", "ids": ["d"]}]
        self.assertEqual(embed.inflight_ids(jobs), {"a", "d"})

    def test_gap_report_counts(self):
        entries = [cat_entry("old1", "a.m4a"), cat_entry("new1", "b.m4a"), cat_entry("gone", "x.mp4")]
        index = [{"id": "old1"}, {"id": "old2", "artist": "Orphan", "title": "Song"}, {"id": "gone"}]
        rep = embed.gap_report(entries, index, {"a.m4a", "b.m4a"}, downloaded=["hot:z.m4a"],
                               spend_usd=0.25, cap_usd=5.0, at="t")
        self.assertEqual(rep["inR2NotEmbedded"], 1)
        self.assertEqual(rep["embeddedNotInR2"], 2)
        self.assertEqual({s["id"] for s in rep["embeddedNotInR2Songs"]}, {"old2", "gone"})
        self.assertEqual(rep["downloadedNotInR2"], 1)
        self.assertEqual(rep["embedSpendTodayUsd"], 0.25)
        self.assertEqual(rep["capUsd"], 5.0)
        rep = embed.gap_report(entries, index, set(), downloaded=None, spend_usd=None, cap_usd=5.0)
        self.assertIsNone(rep["downloadedNotInR2"])
        self.assertIsNone(rep["embedSpendTodayUsd"])

    def test_downloaded_not_in_r2(self):
        hot = Path(self.tmp.name) / "hot"
        pending = Path(self.tmp.name) / "am"
        (hot / "AM-Lossless/A").mkdir(parents=True)
        (hot / "AM-Lossless/A/1.m4a").write_bytes(b"x")
        (hot / "AM-Lossless/A/2.m4a").write_bytes(b"x")
        pending.mkdir()
        (pending / "OFFLOADED.txt").write_text("log", encoding="utf-8")
        (pending / "new.m4a").write_bytes(b"x")
        got = embed.downloaded_not_in_r2({"AM-Lossless/A/1.m4a"}, hot, pending)
        self.assertEqual(got, ["hot:AM-Lossless/A/2.m4a", "pending:new.m4a"])


class MergeTests(IncrementalBase):
    def test_append_only_and_idempotent(self):
        before_f32 = self.paths.tracks_f32.read_bytes()
        before_idx = self.paths.tracks_index.read_text(encoding="utf-8")
        rows = [{"id": "new1", "artist": "a", "title": "t", "album": "", "clips": ["new1:0"]},
                {"id": "old1", "artist": "x", "title": "dup", "album": "", "clips": []}]
        crow = [{"key": "new1:0", "sha": "new1"}]
        added = embed.merge_vectors(self.paths, rows, [unit(5), unit(9)], crow, [unit(5)])
        self.assertEqual(added, 1)
        after = self.paths.tracks_f32.read_bytes()
        self.assertEqual(after[: len(before_f32)], before_f32)
        self.assertEqual(len(after), 3 * DIM * 4)
        self.assertTrue(self.paths.tracks_index.read_text(encoding="utf-8").startswith(before_idx))
        self.assertEqual(embed.read_f32_matrix(self.paths.tracks_f32, dim=DIM)[2], unit(5))
        self.assertEqual(embed.count_lines(self.paths.clips_index), 3)
        # The pair from before the merge is kept.
        self.assertEqual((self.paths.vectors_prev / "tracks.f32").read_bytes(), before_f32)
        self.assertEqual((self.paths.vectors_baseline / "tracks.f32").read_bytes(), before_f32)
        # Again: nothing added, nothing changed.
        self.assertEqual(embed.merge_vectors(self.paths, rows, [unit(5), unit(9)], crow, [unit(5)]), 0)
        self.assertEqual(self.paths.tracks_f32.read_bytes(), after)
        self.assertEqual(embed.count_lines(self.paths.tracks_index), 3)

    def test_mismatched_pair_refuses(self):
        with open(self.paths.tracks_f32, "ab") as fh:
            fh.write(struct.pack(f"<{DIM}f", *unit(3)))
        with self.assertRaises(ValueError):
            embed.merge_vectors(self.paths, [{"id": "n"}], [unit(4)])
        self.assertEqual(embed.count_lines(self.paths.tracks_index), 2)


class FakeClient:
    def __init__(self, state="JOB_STATE_SUCCEEDED", results=""):
        self.state, self.results = state, results
        self.uploads, self.created = [], []
        client = self

        class Files:
            def upload(self, file, config):
                client.uploads.append(file)
                return types.SimpleNamespace(name="files/up")

            def download(self, file):
                return client.results.encode("utf-8")

        class Batches:
            def create_embeddings(self, model, src, config):
                client.created.append(config["display_name"])
                return types.SimpleNamespace(name="batches/1")

            def get(self, name):
                return types.SimpleNamespace(state=client.state, dest=types.SimpleNamespace(file_name="files/out"))

        self.files, self.batches = Files(), Batches()


def result_line(key: str, vec: list[float]) -> str:
    return json.dumps({"key": key, "response": {"embedding": {"values": vec}}}) + "\n"


class SubmitCollectTests(IncrementalBase):
    def setUp(self):
        super().setUp()
        for sha in ("new1", "new2"):
            (self.paths.clips / sha).mkdir(parents=True)
            (self.paths.clips / sha / "0.mp3").write_bytes(b"mp3")
        prepared = [
            {"id": "new1", "relativePath": "b.m4a", "tags": {"artist": "A", "title": "One", "album": ""},
             "durationSeconds": 60.0, "clips": ["new1:0"], "estUsd": 1.0},
            {"id": "new2", "relativePath": "c.m4a", "tags": {"artist": "B", "title": "Two", "album": ""},
             "durationSeconds": 60.0, "clips": ["new2:0"], "estUsd": 1.0},
        ]
        embed.write_json(self.paths.inc_prepared, prepared)

    def args(self, **kw):
        base = dict(state=self.state, cap_usd=5.0, dry_run=False, model=embed.DEFAULT_MODEL, timeout=0, interval=0)
        base.update(kw)
        return mock.Mock(**base)

    def test_missing_ledger_submits_nothing(self):
        with mock.patch.object(embed, "get_genai_client") as gc:
            self.assertEqual(embed.cmd_inc_submit(self.args()), 2)
            gc.assert_not_called()
        self.assertEqual(embed.load_jobs(self.paths.inc_jobs), [])

    def test_cap_trims_then_refuses(self):
        embed.init_spend(self.paths)
        embed.reserve_spend(self.paths, 3.5, 5.0)
        client = FakeClient()
        with mock.patch.object(embed, "get_genai_client", return_value=client):
            self.assertEqual(embed.cmd_inc_submit(self.args()), 0)
        jobs = embed.load_jobs(self.paths.inc_jobs)
        self.assertEqual([j["ids"] for j in jobs], [["new1"]])  # $1.50 left covers one song
        self.assertEqual(jobs[0]["state"], "SUBMITTED")
        self.assertAlmostEqual(embed.spend_today(embed.read_spend(self.paths.spend), embed.utc_day()), 4.5)
        self.assertEqual([p["id"] for p in embed._prepared(self.paths)], ["new2"])
        # The job is in flight: no second job.
        with mock.patch.object(embed, "get_genai_client") as gc:
            embed.cmd_inc_submit(self.args())
            gc.assert_not_called()
        # Once collected, the remaining $0.50 does not cover new2.
        jobs[0]["state"] = "COLLECTED"
        embed.save_jobs(self.paths.inc_jobs, jobs)
        with mock.patch.object(embed, "get_genai_client") as gc:
            self.assertEqual(embed.cmd_inc_submit(self.args()), 0)
            gc.assert_not_called()

    def test_submit_then_collect_merges_once(self):
        embed.init_spend(self.paths)
        client = FakeClient(results=result_line("new2:0", unit(7)) + result_line("new1:0", unit(6)))
        with mock.patch.object(embed, "get_genai_client", return_value=client):
            self.assertEqual(embed.cmd_inc_submit(self.args()), 0)
            self.assertEqual(len(client.created), 1)
            self.assertEqual(embed.cmd_inc_wait(self.args()), 0)
            self.assertEqual(embed.cmd_inc_collect(self.args()), 0)
        index = embed.load_tracks_jsonl(self.paths.tracks_index)
        self.assertEqual([r["id"] for r in index], ["old1", "old2", "new1", "new2"])
        vecs = embed.read_f32_matrix(self.paths.tracks_f32, dim=DIM)
        self.assertEqual(vecs[2], unit(6))
        self.assertEqual(vecs[3], unit(7))
        self.assertEqual(index[2]["title"], "One")
        self.assertEqual(embed.load_jobs(self.paths.inc_jobs)[0]["state"], "COLLECTED")
        # The full-run collect now refuses, since it would drop these rows.
        self.assertEqual(embed.cmd_collect(mock.Mock(state=self.state, force=False)), 1)

    def test_failed_job_releases_its_songs(self):
        embed.init_spend(self.paths)
        client = FakeClient(state="JOB_STATE_FAILED")
        with mock.patch.object(embed, "get_genai_client", return_value=client):
            embed.cmd_inc_submit(self.args())
            self.assertEqual(embed.cmd_inc_collect(self.args()), 1)
        self.assertEqual(embed.inflight_ids(embed.load_jobs(self.paths.inc_jobs)), set())
        self.assertEqual(embed.count_lines(self.paths.tracks_index), 2)


class PrepareTests(IncrementalBase):
    def test_prepare_fetches_from_r2_and_cuts_clips(self):
        embed.init_spend(self.paths)
        self.write_catalogue([cat_entry("old1", "a.m4a"), cat_entry("new1", "b.m4a", duration=60.0),
                              cat_entry("new2", "c.m4a", duration=0.0)])
        fetched = []

        def fake_fetch(rel, dest, **kw):
            fetched.append((rel, kw["use_drive"]))
            dest.write_bytes(b"m4a!")
            return "r2"

        def fake_clip(ffmpeg, source, dest, *, start, duration):
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(b"mp3")

        args = mock.Mock(state=self.state, catalogue=self.catalogue, rclone=Path("/x/rclone"), remote="r:b",
                         cap_usd=5.0, limit=None, ffmpeg_dir=Path("/x"), root=Path(self.tmp.name) / "nodrive")
        with mock.patch.object(embed, "list_r2", return_value={"a.m4a", "b.m4a", "c.m4a"}), \
             mock.patch.object(embed, "fetch_master", side_effect=fake_fetch), \
             mock.patch.object(embed, "ffprobe_duration", return_value=200.0), \
             mock.patch.object(embed, "ffmpeg_clip", side_effect=fake_clip):
            self.assertEqual(embed.cmd_inc_prepare(args), 0)
            prepared = embed._prepared(self.paths)
            self.assertEqual(sorted(p["id"] for p in prepared), ["new1", "new2"])
            by = {p["id"]: p for p in prepared}
            self.assertEqual(len(by["new1"]["clips"]), 1)
            self.assertEqual(len(by["new2"]["clips"]), 3)  # duration from ffprobe
            self.assertFalse(any(use for _, use in fetched))  # no drive: R2 only
            # Prepared songs are not fetched again.
            fetched.clear()
            embed.cmd_inc_prepare(args)
            self.assertEqual(fetched, [])


if __name__ == "__main__":
    unittest.main()