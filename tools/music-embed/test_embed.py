#!/usr/bin/env python3
"""Unit tests for music embed CLI. No network, no real ffmpeg, no google-genai import."""
from __future__ import annotations

import json
import struct
import subprocess
import sys
import tempfile
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


class F32RoundTrip(unittest.TestCase):
    def test_write_read(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "m.f32"
            rows = [[1.0, 2.0], [3.0, 4.0]]
            embed.write_f32_matrix(path, rows)
            back = embed.read_f32_matrix(path, dim=2)
            self.assertEqual(back, rows)


if __name__ == "__main__":
    unittest.main()