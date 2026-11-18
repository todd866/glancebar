#!/usr/bin/env python3
"""Resumable CLI: embed Glancebar music-library tracks with gemini-embedding-2 (batch API)."""
from __future__ import annotations

import argparse
import base64
import contextlib
import fcntl
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable, Iterator, Sequence

CLIP_MAX_SEC = 80.0
SHARD_MAX_BYTES = int(1.8 * 1024 * 1024 * 1024)
VECTOR_DIM = 3072
BATCH_PRICE_PER_SEC = 0.00008
STANDARD_PRICE_PER_SEC = 0.00016

DEFAULT_CATALOGUE = Path.home() / ".local/state/glancebar-music-library/catalogue.json"
DEFAULT_ROOT = Path("/Volumes/OTV Mirror/Music/Apple Music")
DEFAULT_FFMPEG_DIR = Path("/opt/homebrew/bin")
DEFAULT_STATE = Path.home() / ".local/state/glancebar-music-embed"
DEFAULT_MODEL = "gemini-embedding-2"
DEFAULT_CAP_USD = 5.0
DEFAULT_REMOTE = "glancebar-music:glancebar-music"
DEFAULT_RCLONE = Path("/opt/homebrew/bin/rclone")
GAPS_REMOTE_PATH = "radio/gaps.json"
# A job in these states may still produce vectors: its songs are not offered for another batch.
INFLIGHT_STATES = ("SUBMITTED", "PENDING", "RUNNING", "SUCCEEDED")


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    part = path.with_suffix(path.suffix + ".part")
    part.write_bytes(data)
    part.replace(path)


def atomic_write_text(path: Path, text: str) -> None:
    atomic_write(path, text.encode("utf-8"))


def read_json(path: Path, default: Any) -> Any:
    if not path.is_file():
        return default
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, obj: Any) -> None:
    atomic_write_text(path, json.dumps(obj, indent=2, sort_keys=True) + "\n")


def clip_key(sha: str, index: int) -> str:
    return f"{sha}:{index}"


def parse_clip_key(key: str) -> tuple[str, int]:
    sha, _, idx = key.partition(":")
    if not sha or not idx.isdigit():
        raise ValueError(f"invalid clip key: {key!r}")
    return sha, int(idx)


def clip_windows(duration_seconds: float) -> list[tuple[float, float]]:
    """Return (start_sec, end_sec) windows for ffmpeg -ss/-t."""
    d = float(duration_seconds)
    if d <= 0:
        return []
    if d <= CLIP_MAX_SEC:
        return [(0.0, d)]
    centres = (0.2 * d, 0.5 * d, 0.8 * d)
    half = CLIP_MAX_SEC / 2.0
    windows: list[tuple[float, float]] = []
    for c in centres:
        start = c - half
        if start < 0:
            start = 0.0
        if start + CLIP_MAX_SEC > d:
            start = max(0.0, d - CLIP_MAX_SEC)
        end = min(d, start + CLIP_MAX_SEC)
        windows.append((start, end - start))
    return windows


def clip_window_duration(window: tuple[float, float]) -> float:
    return float(window[1])


def total_clip_seconds_for_duration(duration_seconds: float) -> float:
    return sum(clip_window_duration(w) for w in clip_windows(duration_seconds))


def embed_request_line(
    key: str,
    audio_b64: str,
    *,
    output_dimensionality: int = VECTOR_DIM,
) -> dict[str, Any]:
    """Single JSONL object for batches.create_embeddings input (mldev camelCase)."""
    return {
        "key": key,
        "request": {
            "content": {
                "parts": [
                    {
                        "inlineData": {
                            "mimeType": "audio/mpeg",
                            "data": audio_b64,
                        }
                    }
                ]
            },
            "outputDimensionality": int(output_dimensionality),
        },
    }


def _values_from_mapping(obj: Any) -> list[float] | None:
    if not isinstance(obj, dict):
        return None
    vals = obj.get("values")
    if isinstance(vals, list) and vals:
        return [float(x) for x in vals]
    return None


def parse_result_line(line: dict[str, Any]) -> tuple[str | None, list[float] | None, Any | None]:
    """Return (key, embedding values, error object). Missing fields are None."""
    if not isinstance(line, dict):
        return None, None, line
    key = line.get("key")
    if key is not None:
        key = str(key)
    err = line.get("error")
    if err is not None:
        return key, None, err

    for path in (
        lambda: _values_from_mapping((line.get("response") or {}).get("embedding")),
        lambda: _values_from_mapping(((line.get("response") or {}).get("embeddings") or [None])[0]),
        lambda: _values_from_mapping(line.get("embedding")),
    ):
        vals = path()
        if vals is not None:
            return key, vals, None
    return key, None, None


def embed_response_values(response: Any) -> list[float]:
    """Extract a single 3072-vector from embed_content() response (SDK object or dict)."""
    if hasattr(response, "model_dump"):
        response = response.model_dump(exclude_none=True)
    elif not isinstance(response, dict):
        response = dict(response) if response is not None else {}
    embs = response.get("embeddings")
    if isinstance(embs, list) and embs:
        first = embs[0]
        # A dict has a .values method too: check for one first.
        if isinstance(first, dict):
            if first.get("values"):
                return [float(x) for x in first["values"]]
        elif isinstance(getattr(first, "values", None), (list, tuple)):
            return [float(x) for x in first.values]
    single = response.get("embedding")
    vals = _values_from_mapping(single)
    if vals is not None:
        return vals
    raise ValueError("no embedding values in embed_content response")


def shard_jsonl_lines(
    encoded_lines: Iterable[tuple[str, bytes]],
    *,
    max_bytes: int = SHARD_MAX_BYTES,
) -> list[list[tuple[str, bytes]]]:
    """Partition newline-terminated JSONL rows into shards under max_bytes."""
    shards: list[list[tuple[str, bytes]]] = []
    current: list[tuple[str, bytes]] = []
    size = 0
    for key, row in encoded_lines:
        row_len = len(row)
        if row_len > max_bytes:
            raise ValueError(f"single line for {key} exceeds shard limit ({row_len} > {max_bytes})")
        if current and size + row_len > max_bytes:
            shards.append(current)
            current = []
            size = 0
        current.append((key, row))
        size += row_len
    if current:
        shards.append(current)
    return shards


def l2_normalize(vec: Sequence[float]) -> list[float]:
    acc = sum(x * x for x in vec)
    if acc <= 0:
        return [0.0] * len(vec)
    scale = acc ** -0.5
    return [float(x) * scale for x in vec]


def mean_vectors(vectors: Sequence[Sequence[float]]) -> list[float]:
    if not vectors:
        return []
    dim = len(vectors[0])
    sums = [0.0] * dim
    for vec in vectors:
        if len(vec) != dim:
            raise ValueError("inconsistent embedding dimension")
        for i, v in enumerate(vec):
            sums[i] += float(v)
    n = float(len(vectors))
    return [s / n for s in sums]


def track_vectors_from_clips(
    clip_index: list[dict[str, Any]],
    clip_vectors: list[list[float]],
) -> tuple[list[dict[str, Any]], list[list[float]]]:
    """Group clip rows by track sha; mean then L2-normalise."""
    by_sha: dict[str, list[list[float]]] = {}
    meta: dict[str, dict[str, Any]] = {}
    for row, vec in zip(clip_index, clip_vectors, strict=True):
        sha = str(row.get("sha") or parse_clip_key(str(row.get("key", "")))[0])
        by_sha.setdefault(sha, []).append(vec)
        if sha not in meta:
            meta[sha] = {
                "id": sha,
                "artist": row.get("artist", ""),
                "title": row.get("title", ""),
                "album": row.get("album", ""),
                "clips": [],
            }
        meta[sha]["clips"].append(row.get("key"))
    track_rows: list[dict[str, Any]] = []
    track_vecs: list[list[float]] = []
    for sha in sorted(by_sha):
        m = meta[sha]
        track_rows.append(m)
        track_vecs.append(l2_normalize(mean_vectors(by_sha[sha])))
    return track_rows, track_vecs


def write_f32_matrix(path: Path, rows: Sequence[Sequence[float]]) -> None:
    buf = bytearray()
    for row in rows:
        for x in row:
            buf.extend(struct.pack("<f", float(x)))
    atomic_write(path, bytes(buf))


def read_f32_matrix(path: Path, *, dim: int) -> list[list[float]]:
    raw = path.read_bytes()
    if len(raw) % (4 * dim) != 0:
        raise ValueError("truncated f32 matrix")
    n = len(raw) // (4 * dim)
    out: list[list[float]] = []
    for i in range(n):
        off = i * dim * 4
        out.append(list(struct.unpack(f"<{dim}f", raw[off : off + dim * 4])))
    return out


def cosine_similarity(a: Sequence[float], b: Sequence[float]) -> float:
    return sum(float(x) * float(y) for x, y in zip(a, b, strict=True))


def neighbours_rank(
    query: str,
    track_index: Sequence[dict[str, Any]],
    track_vectors: Sequence[Sequence[float]],
    *,
    k: int = 5,
) -> list[tuple[float, dict[str, Any]]]:
    q = query.casefold()
    anchors: list[int] = []
    for i, row in enumerate(track_index):
        if q in str(row.get("artist", "")).casefold() or q in str(row.get("title", "")).casefold():
            anchors.append(i)
    if not anchors:
        return []
    if len(anchors) == 1:
        anchor = track_vectors[anchors[0]]
    else:
        anchor = l2_normalize(mean_vectors([track_vectors[i] for i in anchors]))
    scored: list[tuple[float, dict[str, Any]]] = []
    for i, row in enumerate(track_index):
        scored.append((cosine_similarity(anchor, track_vectors[i]), row))
    scored.sort(key=lambda t: t[0], reverse=True)
    return scored[:k]


def cost_estimate(total_clip_seconds: float) -> dict[str, float]:
    return {
        "clipSeconds": float(total_clip_seconds),
        "batchUsd": float(total_clip_seconds) * BATCH_PRICE_PER_SEC,
        "standardUsd": float(total_clip_seconds) * STANDARD_PRICE_PER_SEC,
    }


class Paths:
    def __init__(self, state: Path):
        self.state = state.expanduser()
        self.tracks = self.state / "tracks.jsonl"
        self.missing = self.state / "missing.jsonl"
        self.clips = self.state / "clips"
        self.batches = self.state / "batches"
        self.jobs = self.state / "jobs.json"
        self.errors = self.state / "errors.jsonl"
        self.vectors = self.state / "vectors"
        self.clips_f32 = self.vectors / "clips.f32"
        self.clips_index = self.vectors / "clips-index.jsonl"
        self.tracks_f32 = self.vectors / "tracks.f32"
        self.tracks_index = self.vectors / "tracks-index.jsonl"
        self.venv = self.state / "venv"
        # Incremental (nightly) runs: their own jobs file, shards and results, so the first
        # full run's jobs.json / build / collect never touch them and they never touch it.
        self.inc = self.state / "incremental"
        self.inc_jobs = self.inc / "jobs.json"
        self.inc_batches = self.inc / "batches"
        self.inc_results = self.inc / "results"
        self.inc_prepared = self.inc / "prepared.json"
        self.local_gap = self.inc / "local-gap.json"
        self.vectors_prev = self.vectors / "prev"
        self.vectors_baseline = self.vectors / "baseline"
        self.spend = self.state / "spend.json"
        self.spend_lock = self.state / "spend.lock"
        self.gaps = self.state / "gaps.json"


def ffprobe_duration(ffprobe: Path, audio_file: Path) -> float:
    proc = subprocess.run(
        [
            str(ffprobe),
            "-v",
            "error",
            "-show_entries",
            "format=duration",
            "-of",
            "default=noprint_wrappers=1:nokey=1",
            str(audio_file),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        raise OSError(proc.stderr.strip() or f"ffprobe failed on {audio_file}")
    return float(proc.stdout.strip())


def ffmpeg_clip(
    ffmpeg: Path,
    source: Path,
    dest: Path,
    *,
    start: float,
    duration: float,
) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    part = dest.with_suffix(dest.suffix + ".part")
    cmd = [
        str(ffmpeg),
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-ss",
        f"{start:.6f}",
        "-i",
        str(source),
        "-t",
        f"{duration:.6f}",
        "-ac",
        "1",
        "-ar",
        "32000",
        "-b:a",
        "64k",
        "-f",
        "mp3",
        str(part),
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        if part.is_file():
            part.unlink()
        raise OSError(proc.stderr.strip() or "ffmpeg failed")
    part.replace(dest)


def load_tracks_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.is_file():
        return []
    out: list[dict[str, Any]] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line:
            out.append(json.loads(line))
    return out


def cmd_plan(args: argparse.Namespace) -> int:
    catalogue = json.loads(Path(args.catalogue).expanduser().read_text(encoding="utf-8"))
    root = Path(args.root).expanduser()
    paths = Paths(Path(args.state))
    ffprobe = Path(args.ffmpeg_dir) / "ffprobe"

    if paths.tracks.is_file() and not args.force:
        print(f"tracks already at {paths.tracks} (use --force to rebuild)", file=sys.stderr)
        return 0

    track_lines: list[str] = []
    missing_lines: list[str] = []
    for entry in catalogue.get("entries", []):
        rel = entry.get("relativePath", "")
        sha = entry.get("sha256", "")
        tags = entry.get("tags") or {}
        src = root / rel
        duration = float(entry.get("durationSeconds") or 0)
        if not src.is_file():
            missing_lines.append(
                json.dumps(
                    {"id": sha, "relativePath": rel, "reason": "missing"},
                    sort_keys=True,
                )
            )
            continue
        if duration <= 0:
            try:
                duration = ffprobe_duration(ffprobe, src)
            except OSError as exc:
                missing_lines.append(
                    json.dumps(
                        {"id": sha, "relativePath": rel, "reason": str(exc)},
                        sort_keys=True,
                    )
                )
                continue
        track_lines.append(
            json.dumps(
                {
                    "id": sha,
                    "relativePath": rel,
                    "tags": {
                        "title": tags.get("title", ""),
                        "artist": tags.get("artist", ""),
                        "album": tags.get("album", ""),
                    },
                    "durationSeconds": duration,
                },
                sort_keys=True,
            )
        )

    atomic_write_text(paths.tracks, "\n".join(track_lines) + ("\n" if track_lines else ""))
    atomic_write_text(paths.missing, "\n".join(missing_lines) + ("\n" if missing_lines else ""))
    print(f"planned {len(track_lines)} tracks, {len(missing_lines)} missing")
    return 0


def iter_clip_jobs(tracks: list[dict[str, Any]]) -> Iterator[tuple[dict[str, Any], int, tuple[float, float]]]:
    for track in tracks:
        duration = float(track["durationSeconds"])
        for idx, window in enumerate(clip_windows(duration)):
            yield track, idx, window


def cmd_clips(args: argparse.Namespace) -> int:
    paths = Paths(Path(args.state))
    root = Path(args.root).expanduser()
    ffmpeg = Path(args.ffmpeg_dir) / "ffmpeg"
    tracks = load_tracks_jsonl(paths.tracks)
    if not tracks:
        print("no tracks.jsonl; run plan first", file=sys.stderr)
        return 1

    limit = int(args.limit) if args.limit else None
    made = skipped = 0
    for track, idx, (start, dur) in iter_clip_jobs(tracks):
        if limit is not None and made >= limit:
            break
        sha = track["id"]
        dest = paths.clips / sha / f"{idx}.mp3"
        if dest.is_file() and dest.stat().st_size > 0:
            skipped += 1
            continue
        src = root / track["relativePath"]
        if not src.is_file():
            continue
        ffmpeg_clip(ffmpeg, src, dest, start=start, duration=dur)
        made += 1
    print(f"clips: created {made}, skipped {skipped}")
    return 0


def encode_batch_line(key: str, clip_path: Path) -> bytes:
    b64 = base64.standard_b64encode(clip_path.read_bytes()).decode("ascii")
    line = embed_request_line(key, b64)
    return (json.dumps(line, separators=(",", ":")) + "\n").encode("utf-8")


_SKIP = object()


def cmd_build(args: argparse.Namespace) -> int:
    paths = Paths(Path(args.state))
    paths.batches.mkdir(parents=True, exist_ok=True)

    keys: list[tuple[str, Path]] = []
    if args.only_failed:
        if not paths.errors.is_file():
            print("no errors.jsonl", file=sys.stderr)
            return 1
        for line in paths.errors.read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            rec = json.loads(line)
            key = str(rec.get("key", ""))
            sha, idx = parse_clip_key(key)
            clip = paths.clips / sha / f"{idx}.mp3"
            if clip.is_file() and clip.stat().st_size > 0:
                keys.append((key, clip))
    else:
        for clip_path in sorted(paths.clips.glob("*/*.mp3")):
            sha = clip_path.parent.name
            idx = int(clip_path.stem)
            if clip_path.stat().st_size <= 0:
                continue
            keys.append((clip_key(sha, idx), clip_path))

    # Streamed: one line in memory at a time (the whole set is ~3.7 GB of base64).
    existing = sorted(paths.batches.glob("shard-*.jsonl"))
    idx = len(existing) if args.only_failed else 0
    fh = None
    part = out = None
    size = lines = 0

    def finish() -> None:
        nonlocal fh, part, out, size, lines, idx
        if fh is None:
            return
        if fh is _SKIP:
            print(f"skip existing {out.name}")
        else:
            fh.close()
            part.replace(out)
            print(f"wrote {out.name} ({lines} lines)")
        fh = None
        size = lines = 0
        idx += 1

    for k, p in keys:
        row = encode_batch_line(k, p)
        if len(row) > SHARD_MAX_BYTES:
            raise ValueError(f"single line for {k} exceeds shard limit ({len(row)} > {SHARD_MAX_BYTES})")
        if fh is not None and size + len(row) > SHARD_MAX_BYTES:
            finish()
        if fh is None:
            out = paths.batches / f"shard-{idx:03d}.jsonl"
            part = out.with_suffix(out.suffix + ".part")
            # A shard already written is kept; its lines are still counted so later shards line up.
            fh = _SKIP if (not args.only_failed and out.is_file() and out.stat().st_size > 0) else part.open("wb")
        if fh is not _SKIP:
            fh.write(row)
        size += len(row)
        lines += 1
    finish()
    if not keys:
        print("no clips to batch")
    return 0


def cmd_cost(args: argparse.Namespace) -> int:
    paths = Paths(Path(args.state))
    tracks = load_tracks_jsonl(paths.tracks)
    total = sum(total_clip_seconds_for_duration(float(t["durationSeconds"])) for t in tracks)
    est = cost_estimate(total)
    print(json.dumps(est, indent=2))
    return 0


def get_genai_client():
    key = os.environ.get("GEMINI_API_KEY")
    if not key:
        raise SystemExit("GEMINI_API_KEY is not set")
    from google import genai  # lazy import

    return genai.Client(api_key=key)


def pick_preflight_clips(paths: Paths) -> list[tuple[str, Path]]:
    found: list[tuple[str, Path]] = []
    for clip_path in sorted(paths.clips.glob("*/*.mp3")):
        if clip_path.stat().st_size <= 0:
            continue
        sha = clip_path.parent.name
        idx = int(clip_path.stem)
        found.append((clip_key(sha, idx), clip_path))
        if len(found) >= 2:
            break
    return found


def cmd_preflight(args: argparse.Namespace) -> int:
    from google.genai import types

    paths = Paths(Path(args.state))
    client = get_genai_client()
    model = args.model
    picks = pick_preflight_clips(paths)
    if len(picks) < 2:
        print("need at least two clips on disk for preflight", file=sys.stderr)
        return 1

    sync_lines: list[dict[str, Any]] = []
    for key, clip in picks:
        data = clip.read_bytes()
        resp = client.models.embed_content(
            model=model,
            contents=types.Content(
                parts=[types.Part(inline_data=types.Blob(mime_type="audio/mpeg", data=data))]
            ),
            config={"output_dimensionality": VECTOR_DIM},
        )
        vals = embed_response_values(resp)
        if len(vals) != VECTOR_DIM:
            print(f"sync embed {key}: expected {VECTOR_DIM} dims, got {len(vals)}", file=sys.stderr)
            return 1
        sync_lines.append(embed_request_line(key, base64.standard_b64encode(data).decode("ascii")))

    print("sync embed_content ok (3072 dims x2)")
    print("batch request line format:")
    print(json.dumps(sync_lines[0], indent=2)[:500] + "...")

    batch_path = paths.state / "preflight-batch.jsonl"
    lines = [json.dumps(embed_request_line(k, base64.standard_b64encode(p.read_bytes()).decode("ascii"))) + "\n"
             for k, p in picks]
    atomic_write_text(batch_path, "".join(lines))

    upload = client.files.upload(file=str(batch_path), config={"mime_type": "jsonl"})
    job = client.batches.create_embeddings(
        model=model,
        src={"file_name": upload.name},
        config={"display_name": f"preflight-{utc_now_iso()}"},
    )
    name = job.name
    while True:
        job = client.batches.get(name=name)
        state = normalise_job_state(job.state)
        print(f"preflight job {state}")
        if state == "SUCCEEDED":
            break
        if state in ("FAILED", "CANCELLED", "EXPIRED"):
            print(f"preflight batch failed: {state}", file=sys.stderr)
            return 1
        time.sleep(2.0)

    dest = job.dest.file_name if job.dest else None
    if not dest:
        print("preflight job missing dest.file_name", file=sys.stderr)
        return 1
    raw = client.files.download(file=dest)
    text = raw.decode("utf-8") if isinstance(raw, (bytes, bytearray)) else str(raw)
    ok = 0
    for line in text.splitlines():
        if not line.strip():
            continue
        rec = json.loads(line)
        key, vals, err = parse_result_line(rec)
        if err is not None or vals is None or len(vals) != VECTOR_DIM:
            print(f"preflight parse failed for {key}: err={err} dims={0 if vals is None else len(vals)}", file=sys.stderr)
            return 1
        ok += 1
    if ok != 2:
        print(f"preflight expected 2 batch lines, got {ok}", file=sys.stderr)
        return 1
    print("preflight batch ok (3072 dims x2)")
    return 0


def load_jobs(path: Path) -> list[dict[str, Any]]:
    data = read_json(path, [])
    return data if isinstance(data, list) else []


def save_jobs(path: Path, jobs: list[dict[str, Any]]) -> None:
    write_json(path, jobs)


def shard_name(path: Path) -> str:
    return path.stem  # shard-NNN


def cmd_submit(args: argparse.Namespace) -> int:
    paths = Paths(Path(args.state))
    shards = sorted(paths.batches.glob("shard-*.jsonl"))
    if not shards:
        print("no batch shards; run build first", file=sys.stderr)
        return 1
    jobs = load_jobs(paths.jobs)
    by_shard = {j["shard"]: j for j in jobs}
    client = get_genai_client() if not args.dry_run else None

    for shard_path in shards:
        shard = shard_name(shard_path)
        if shard in by_shard and args.resubmit != shard:
            print(f"skip {shard} (already submitted)")
            continue
        if args.dry_run:
            print(f"would upload {shard_path} and create_embeddings model={args.model}")
            continue
        upload = client.files.upload(file=str(shard_path), config={"mime_type": "jsonl"})
        job = client.batches.create_embeddings(
            model=args.model,
            src={"file_name": upload.name},
            config={"display_name": shard},
        )
        rec = {
            "shard": shard,
            "file_name": upload.name,
            "job_name": job.name,
            "created": utc_now_iso(),
        }
        jobs = [j for j in jobs if j.get("shard") != shard]
        jobs.append(rec)
        save_jobs(paths.jobs, jobs)
        print(f"submitted {shard} -> {job.name}")
    return 0


def normalise_job_state(state: Any) -> str:
    # The SDK's enum prints as "JobState.JOB_STATE_SUCCEEDED"; the REST API says "JOB_STATE_SUCCEEDED".
    s = str(getattr(state, "value", None) or state or "").rsplit(".", 1)[-1]
    for prefix in ("JOB_STATE_",):
        if s.startswith(prefix):
            s = s[len(prefix) :]
    return s.upper()


def cmd_poll(args: argparse.Namespace) -> int:
    paths = Paths(Path(args.state))
    jobs = load_jobs(paths.jobs)
    if not jobs:
        print("no jobs.json entries", file=sys.stderr)
        return 1
    client = get_genai_client()
    for rec in jobs:
        job = client.batches.get(name=rec["job_name"])
        print(f"{rec['shard']}\t{normalise_job_state(job.state)}")
    return 0


def download_job_results(client, job_name: str) -> str:
    job = client.batches.get(name=job_name)
    state = normalise_job_state(job.state)
    if state != "SUCCEEDED":
        raise OSError(f"job {job_name} not succeeded ({state})")
    dest = job.dest.file_name if job.dest else None
    if not dest:
        raise OSError(f"job {job_name} missing dest")
    raw = client.files.download(file=dest)
    return raw.decode("utf-8") if isinstance(raw, (bytes, bytearray)) else str(raw)


def cmd_collect(args: argparse.Namespace) -> int:
    paths = Paths(Path(args.state))
    # collect rebuilds the matrices from the first run's jobs only: after a nightly merge it
    # would drop every song added since.
    if any(j.get("state") == "COLLECTED" for j in load_jobs(paths.inc_jobs)) and not getattr(args, "force", False):
        print("incremental rows are merged into the vectors; collect would drop them (use --force)", file=sys.stderr)
        return 1
    jobs = load_jobs(paths.jobs)
    if not jobs:
        print("no jobs", file=sys.stderr)
        return 1
    client = get_genai_client()
    tracks = {t["id"]: t for t in load_tracks_jsonl(paths.tracks)}

    clip_index: list[dict[str, Any]] = []
    clip_vectors: list[list[float]] = []
    errors: list[dict[str, Any]] = []

    for rec in jobs:
        if normalise_job_state(client.batches.get(name=rec["job_name"]).state) != "SUCCEEDED":
            continue
        text = download_job_results(client, rec["job_name"])
        for line in text.splitlines():
            if not line.strip():
                continue
            obj = json.loads(line)
            key, vals, err = parse_result_line(obj)
            if err is not None or vals is None:
                errors.append({"key": key, "error": err or "no embedding", "shard": rec["shard"]})
                continue
            if len(vals) != VECTOR_DIM:
                errors.append({"key": key, "error": f"dim {len(vals)}", "shard": rec["shard"]})
                continue
            sha, _ = parse_clip_key(str(key))
            tags = (tracks.get(sha) or {}).get("tags") or {}
            clip_index.append(
                {
                    "key": key,
                    "sha": sha,
                    "artist": tags.get("artist", ""),
                    "title": tags.get("title", ""),
                    "album": tags.get("album", ""),
                }
            )
            clip_vectors.append(vals)

    paths.vectors.mkdir(parents=True, exist_ok=True)
    write_f32_matrix(paths.clips_f32, clip_vectors)
    atomic_write_text(
        paths.clips_index,
        "".join(json.dumps(r, sort_keys=True) + "\n" for r in clip_index),
    )
    track_rows, track_vecs = track_vectors_from_clips(clip_index, clip_vectors)
    write_f32_matrix(paths.tracks_f32, track_vecs)
    atomic_write_text(
        paths.tracks_index,
        "".join(json.dumps(r, sort_keys=True) + "\n" for r in track_rows),
    )
    if errors:
        atomic_write_text(
            paths.errors,
            "".join(json.dumps(r, sort_keys=True) + "\n" for r in errors),
        )
        print(f"collect: {len(clip_vectors)} clip vectors, {len(errors)} errors")
    else:
        print(f"collect: {len(clip_vectors)} clip vectors, {len(track_rows)} tracks")
    return 0


_CHILL_GENRE_KEYS = (
    "ambient",
    "downtempo",
    "chill",
    "lo-fi",
    "lofi",
    "new age",
    "classical",
    "jazz",
    "acoustic",
    "singer",
    "easy listening",
)
_DANCE_GENRE_KEYS = (
    "electronic",
    "dance",
    "house",
    "techno",
    "trance",
    "bass",
    "drum",
    "dubstep",
    "garage",
    "electronica",
    "downtempo",
    "ambient",
)
_RAP_GENRE_KEYS = ("hip-hop", "hip hop", "rap", "r&b", "soul", "funk", "grime", "trap")
_ALT_GENRE_KEYS = ("alternative", "rock", "indie", "punk", "metal", "grunge", "emo", "folk", "singer")
_BRACKET_RE = re.compile(r"\[[^\]]*\]|\([^)]*\)")
_REMASTERED_RE = re.compile(r"\s*-\s*remastered.*$", re.IGNORECASE)
_PUNCT_RE = re.compile(r"[^\w\s]")
_SPACE_RE = re.compile(r"\s+")


def _strip_for_match(text: str) -> str:
    text = text or ""
    text = text.lower()
    text = _REMASTERED_RE.sub("", text)
    text = _BRACKET_RE.sub("", text)
    text = _PUNCT_RE.sub(" ", text)
    return _SPACE_RE.sub(" ", text).strip()


def primary_artist(artist: str) -> str:
    text = (artist or "").lower()
    for needle in (",", "&", " feat.", " feat ", " ft.", " ft "):
        idx = text.find(needle)
        if idx >= 0:
            text = text[:idx]
    return _strip_for_match(text)


def normalize_title(title: str) -> str:
    return _strip_for_match(title)


def match_key(artist: str, title: str) -> tuple[str, str]:
    return primary_artist(artist), normalize_title(title)


def genre_family(genre: str | None) -> str:
    g = (genre or "").lower()
    for k in _DANCE_GENRE_KEYS:
        if k in g:
            return "dance"
    for k in _RAP_GENRE_KEYS:
        if k in g:
            return "rap"
    for k in _ALT_GENRE_KEYS:
        if k in g:
            return "alt"
    if "pop" in g:
        return "pop"
    return "other"


def music_kind_for_genre(genre: str | None) -> str:
    g = (genre or "").lower()
    for k in _CHILL_GENRE_KEYS:
        if k in g:
            return "chill"
    family = genre_family(genre)
    if family == "pop":
        return "alt"
    if family in ("dance", "rap", "alt"):
        return family
    return "other"


def load_mix_library(path: Path) -> list[dict[str, Any]]:
    data = json.loads(path.expanduser().read_text(encoding="utf-8"))
    if isinstance(data, list):
        return data
    if isinstance(data, dict):
        tracks = data.get("tracks")
        if isinstance(tracks, list):
            return tracks
    raise ValueError("library must be a list or {\"tracks\": [...]}")


def build_music_space(
    track_vectors: Sequence[Sequence[float]],
    track_index: Sequence[dict[str, Any]],
    library: Sequence[dict[str, Any]],
    *,
    neighbour_k: int = 24,
    progress: bool = True,
) -> dict[str, Any]:
    """Build music-space.json payload from vectors, index rows, and library tracks."""
    kinds = ("dance", "alt", "rap", "chill")

    lib_by_key: dict[tuple[str, str, str], list[dict[str, Any]]] = {}
    lib_all_by_key: dict[tuple[str, str], list[dict[str, Any]]] = {}
    for row in library:
        if not isinstance(row, dict):
            continue
        tid = row.get("id")
        if not tid:
            continue
        ak, tk = match_key(str(row.get("artist", "")), str(row.get("title", "")))
        lib_all_by_key.setdefault((ak, tk), []).append(row)
        album = _strip_for_match(str(row.get("album", "")))
        lib_by_key.setdefault((ak, tk, album), []).append(row)

    vector_row_for_lib: dict[str, int] = {}
    lib_ids_per_vector: dict[int, list[str]] = {}
    matched_vectors = 0
    unmatched = 0

    for vi, meta in enumerate(track_index):
        ak, tk = match_key(str(meta.get("artist", "")), str(meta.get("title", "")))
        album = _strip_for_match(str(meta.get("album", "")))
        matched_libs = lib_by_key.get((ak, tk, album)) or lib_all_by_key.get((ak, tk)) or []
        if not matched_libs:
            unmatched += 1
            continue
        matched_vectors += 1
        ids = [str(t["id"]) for t in matched_libs if t.get("id")]
        lib_ids_per_vector[vi] = ids
        for lid in ids:
            vector_row_for_lib[lid] = vi

    seed_by_kind: dict[str, list[list[float]]] = {k: [] for k in kinds}
    for vi, ids in lib_ids_per_vector.items():
        if not ids:
            continue
        lib_row = next((t for t in library if str(t.get("id")) == ids[0]), None)
        if not lib_row:
            continue
        seed = music_kind_for_genre(str(lib_row.get("genre", "")))
        if seed in seed_by_kind:
            seed_by_kind[seed].append(list(track_vectors[vi]))

    centroids: dict[str, list[float]] = {}
    for k in kinds:
        vecs = seed_by_kind[k]
        if vecs:
            centroids[k] = l2_normalize(mean_vectors(vecs))

    kind_neighbours: dict[str, list[str]] = {}
    if len(centroids) >= 2:
        for k in kinds:
            if k not in centroids:
                continue
            scored = [
                (cosine_similarity(centroids[k], centroids[o]), o)
                for o in kinds
                if o != k and o in centroids
            ]
            scored.sort(key=lambda t: t[0], reverse=True)
            kind_neighbours[k] = [o for _, o in scored]

    tracks_out: dict[str, dict[str, Any]] = {}
    by_kind: dict[str, int] = {k: 0 for k in kinds}
    by_kind["other"] = 0

    assigned_kind: dict[int, str] = {}
    assigned_score: dict[int, float] = {}

    for vi, ids in lib_ids_per_vector.items():
        vec = track_vectors[vi]
        if centroids:
            best_k = kinds[0]
            best_s = -1.0
            for k in kinds:
                if k not in centroids:
                    continue
                s = cosine_similarity(vec, centroids[k])
                if s > best_s:
                    best_s = s
                    best_k = k
            assigned_kind[vi] = best_k
            assigned_score[vi] = best_s
        else:
            lib_row = next((t for t in library if str(t.get("id")) == ids[0]), None)
            sk = music_kind_for_genre(str((lib_row or {}).get("genre", "")))
            assigned_kind[vi] = sk if sk in kinds else "other"
            assigned_score[vi] = 0.0

    for vi, ids in lib_ids_per_vector.items():
        kind = assigned_kind[vi]
        score = round(assigned_score[vi], 3)
        for lid in ids:
            by_kind[kind] = by_kind.get(kind, 0) + 1
            tracks_out[lid] = {"kind": kind, "kindScore": score, "next": []}

    lib_ids = list(vector_row_for_lib.keys())
    n_lib = len(lib_ids)
    if progress and n_lib:
        print(f"neighbours: {n_lib} library ids", flush=True)

    # Similarities are per vector, not per library id (two ids can share a song): one row of
    # cosines per used vector, through numpy when it is there (seconds instead of hours for
    # 1.5k x 3072), else pure Python.
    used = sorted(set(vector_row_for_lib.values()))
    pos = {vi: n for n, vi in enumerate(used)}
    try:
        import numpy as _np  # optional fast path

        mat = _np.asarray([track_vectors[vi] for vi in used], dtype=_np.float32)
        sims = mat @ mat.T

        def sim_row(vi):
            return sims[pos[vi]].tolist()
    except ImportError:
        def sim_row(vi):
            v = track_vectors[vi]
            return [cosine_similarity(v, track_vectors[o]) for o in used]

    lids_by_vector: dict[int, list[str]] = {}
    for lid in lib_ids:
        lids_by_vector.setdefault(vector_row_for_lib[lid], []).append(lid)
    for i, vi in enumerate(used):
        row = sim_row(vi)
        order = sorted(range(len(used)), key=lambda n: row[n], reverse=True)
        nxt: list[list[Any]] = []
        for n in order:
            if used[n] == vi:
                continue
            for other in lids_by_vector.get(used[n], []):
                nxt.append([other, round(float(row[n]), 3)])
            if len(nxt) >= neighbour_k:
                break
        for lid in lids_by_vector.get(vi, []):
            if lid in tracks_out:
                tracks_out[lid]["next"] = nxt[:neighbour_k]
        if progress and ((i + 1) % 250 == 0 or i + 1 == len(used)):
            print(f"  {i + 1}/{len(used)}", flush=True)

    stats = {
        "vectors": len(track_index),
        "matchedVectors": matched_vectors,
        "libraryIds": len(tracks_out),
        "unmatchedVectors": unmatched,
        "byKind": by_kind,
    }
    return {
        "schemaVersion": 1,
        "generatedAt": utc_now_iso(),
        "model": DEFAULT_MODEL,
        "kindNeighbours": kind_neighbours,
        "tracks": tracks_out,
        "stats": stats,
    }


def cmd_export(args: argparse.Namespace) -> int:
    state = Path(args.state)
    vectors_dir = Path(args.vectors).expanduser() if args.vectors else state.expanduser() / "vectors"
    library_path = Path(args.library).expanduser()
    out_path = Path(args.out).expanduser()

    tracks_f32 = vectors_dir / "tracks.f32"
    tracks_index = vectors_dir / "tracks-index.jsonl"
    if not tracks_f32.is_file() or not tracks_index.is_file():
        print("missing tracks.f32 or tracks-index.jsonl", file=sys.stderr)
        return 1

    library = load_mix_library(library_path)
    index = load_tracks_jsonl(tracks_index)
    vectors = read_f32_matrix(tracks_f32, dim=VECTOR_DIM)
    if len(vectors) != len(index):
        print("vector row count mismatch", file=sys.stderr)
        return 1

    payload = build_music_space(vectors, index, library)
    write_json(out_path, payload)
    print(json.dumps(payload["stats"], indent=2))
    return 0


def cmd_neighbours(args: argparse.Namespace) -> int:
    paths = Paths(Path(args.state))
    if not paths.tracks_f32.is_file() or not paths.tracks_index.is_file():
        print("missing track vectors; run collect first", file=sys.stderr)
        return 1
    index = load_tracks_jsonl(paths.tracks_index)
    vectors = read_f32_matrix(paths.tracks_f32, dim=VECTOR_DIM)
    ranked = neighbours_rank(args.query, index, vectors, k=int(args.k))
    for score, row in ranked:
        print(f"{score:.4f}\t{row.get('artist', '')}\t{row.get('title', '')}")
    return 0


# ---------------------------------------------------------------------------------------------
# Incremental runs (the nightly map refresh). Songs in the catalogue and in R2 with no vector are
# fetched, clipped, sent as one Batch API job, and appended to tracks.f32 / tracks-index.jsonl.
# Existing rows are never rewritten. Spend is reserved against a daily cap before any upload.
# ---------------------------------------------------------------------------------------------


class SpendError(RuntimeError):
    """The spend ledger cannot be read or written: nothing is submitted."""


class CapExceeded(RuntimeError):
    def __init__(self, spent: float, want: float, cap: float):
        super().__init__(f"daily cap: ${spent:.2f} spent today + ${want:.2f} > ${cap:.2f}")
        self.spent, self.want, self.cap = spent, want, cap


def ledger_day(now: float | None = None) -> str:
    """The spend ledger's day: the owner's day, Perth date (owner, 18 Nov 2026: one clock for the ledger and
    for dated cap overrides). Australia/Perth has no daylight saving, so UTC+8 is exact."""
    return datetime.fromtimestamp((time.time() if now is None else now) + 8 * 3600, tz=timezone.utc).strftime("%Y-%m-%d")


def utc_day(now: float | None = None) -> str:
    return datetime.fromtimestamp(time.time() if now is None else now, tz=timezone.utc).strftime("%Y-%m-%d")


def song_cost_usd(duration_seconds: float) -> float:
    return total_clip_seconds_for_duration(duration_seconds) * BATCH_PRICE_PER_SEC


def read_spend(path: Path) -> dict[str, Any]:
    """Strict: a missing or malformed ledger is an error, never zero."""
    if not path.is_file():
        raise SpendError(f"spend ledger missing: {path} (create it with `embed.py spend --init`)")
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise SpendError(f"spend ledger unreadable: {exc}") from exc
    days = doc.get("days") if isinstance(doc, dict) else None
    if not isinstance(days, dict) or not all(isinstance(v, (int, float)) and v >= 0 for v in days.values()):
        raise SpendError("spend ledger malformed: expected {\"days\": {\"YYYY-MM-DD\": usd}}")
    return doc


def spend_today(doc: dict[str, Any], day: str) -> float:
    return float(doc["days"].get(day, 0.0))


@contextlib.contextmanager
def spend_locked(paths: Paths, timeout: float = 120.0):
    paths.state.mkdir(parents=True, exist_ok=True)
    fh = open(paths.spend_lock, "a")
    try:
        deadline = time.monotonic() + timeout
        while True:
            try:
                fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() > deadline:
                    raise SpendError("spend ledger is locked by another run")
                time.sleep(0.5)
        yield
    finally:
        fh.close()


def init_spend(paths: Paths) -> bool:
    with spend_locked(paths):
        if paths.spend.exists():
            read_spend(paths.spend)  # an existing ledger must parse; it is never reset
            return False
        write_json(paths.spend, {"days": {}, "log": []})
        return True


def reserve_spend(paths: Paths, usd: float, cap: float, *, note: str = "", now: float | None = None) -> float:
    """Add usd to today's (UTC) total if it stays within cap; return the new total.

    The check and the write happen under one lock, before anything is uploaded, so two runs
    cannot both pass the cap. Raises SpendError (ledger unreadable) or CapExceeded."""
    day = ledger_day(now)
    with spend_locked(paths):
        doc = read_spend(paths.spend)
        spent = spend_today(doc, day)
        if spent + usd > cap + 1e-9:
            raise CapExceeded(spent, usd, cap)
        total = round(spent + usd, 6)
        doc["days"][day] = total
        log = doc.get("log") if isinstance(doc.get("log"), list) else []
        log.append({"at": utc_now_iso(), "day": day, "usd": round(usd, 6), "note": note})
        doc["log"] = log[-500:]
        write_json(paths.spend, doc)
        return total


def select_within_budget(entries: Sequence[dict[str, Any]], remaining_usd: float, *, limit: int | None = None) -> list[dict[str, Any]]:
    """Greedy in the given order: take each song whose cost still fits."""
    out: list[dict[str, Any]] = []
    left = float(remaining_usd)
    for e in entries:
        if limit is not None and len(out) >= limit:
            break
        cost = song_cost_usd(float(e.get("durationSeconds") or 0) or CLIP_MAX_SEC * 3)
        if cost <= left + 1e-9:
            out.append(e)
            left -= cost
    return out


def load_index_rows(paths: Paths) -> list[dict[str, Any]]:
    return load_tracks_jsonl(paths.tracks_index)


def inflight_ids(jobs: Sequence[dict[str, Any]]) -> set[str]:
    out: set[str] = set()
    for j in jobs:
        if j.get("state") in INFLIGHT_STATES:
            out.update(str(i) for i in j.get("ids") or [])
    return out


def pending_entries(
    catalogue_entries: Sequence[dict[str, Any]],
    embedded_ids: set[str],
    r2_paths: set[str] | None,
    exclude_ids: set[str] = frozenset(),
) -> list[dict[str, Any]]:
    """Catalogue songs in R2 with no vector, newest first, one per sha."""
    seen: set[str] = set()
    out: list[dict[str, Any]] = []
    for e in sorted(catalogue_entries, key=lambda e: int(e.get("mtimeNs") or 0), reverse=True):
        sha = str(e.get("sha256") or "")
        rel = str(e.get("relativePath") or "")
        if not sha or not rel.lower().endswith(".m4a"):
            continue
        if r2_paths is not None and rel not in r2_paths:
            continue
        if sha in embedded_ids or sha in exclude_ids or sha in seen:
            continue
        seen.add(sha)
        out.append(e)
    return out


def gap_report(
    catalogue_entries: Sequence[dict[str, Any]],
    index_rows: Sequence[dict[str, Any]],
    r2_paths: set[str],
    *,
    downloaded: list[str] | None,
    spend_usd: float | None,
    cap_usd: float,
    in_flight: int = 0,
    at: str | None = None,
) -> dict[str, Any]:
    in_r2 = [e for e in catalogue_entries if str(e.get("relativePath") or "") in r2_paths and e.get("sha256")]
    in_r2_ids = {str(e["sha256"]) for e in in_r2}
    emb_ids = {str(r.get("id")) for r in index_rows}
    not_embedded: dict[str, dict[str, Any]] = {}
    for e in in_r2:
        sha = str(e["sha256"])
        if sha not in emb_ids and sha not in not_embedded:
            not_embedded[sha] = {"id": sha, "relativePath": e.get("relativePath", "")}
    orphans = [
        {"id": r.get("id"), "artist": r.get("artist", ""), "title": r.get("title", ""), "album": r.get("album", "")}
        for r in index_rows
        if str(r.get("id")) not in in_r2_ids
    ]
    return {
        "at": at or utc_now_iso(),
        "inR2NotEmbedded": len(not_embedded),
        "embeddedNotInR2": len(orphans),
        "downloadedNotInR2": None if downloaded is None else len(downloaded),
        "embedSpendTodayUsd": None if spend_usd is None else round(spend_usd, 4),
        "capUsd": cap_usd,
        "inFlight": in_flight,
        "vectors": len(index_rows),
        "inR2NotEmbeddedSongs": list(not_embedded.values()),
        "embeddedNotInR2Songs": orphans,
        "downloadedNotInR2Songs": downloaded,
    }


def downloaded_not_in_r2(catalogue_rels: set[str], hot_root: Path, pending_root: Path) -> list[str]:
    """Songs downloaded on this Mac that the bucket's catalogue lacks: hot-set files whose path
    is not in it, plus every audio file still waiting in the Apple Music pull folder."""
    out: list[str] = []
    if hot_root.is_dir():
        for p in sorted(hot_root.rglob("*.m4a")):
            rel = str(p.relative_to(hot_root))
            if rel not in catalogue_rels:
                out.append(f"hot:{rel}")
    if pending_root.is_dir():
        for p in sorted(pending_root.rglob("*")):
            if p.is_file() and p.suffix.lower() in (".m4a", ".mp4", ".flac", ".alac"):
                out.append(f"pending:{p.relative_to(pending_root)}")
    return out


def f32_rows(path: Path, dim: int = VECTOR_DIM) -> int:
    size = path.stat().st_size if path.is_file() else 0
    if size % (4 * dim):
        raise ValueError(f"{path.name}: {size} bytes is not a whole number of {dim}-D rows")
    return size // (4 * dim)


def count_lines(path: Path) -> int:
    if not path.is_file():
        return 0
    return sum(1 for line in path.read_text(encoding="utf-8").splitlines() if line.strip())


def check_vector_files(paths: Paths, dim: int = VECTOR_DIM) -> None:
    for f32, idx in ((paths.tracks_f32, paths.tracks_index), (paths.clips_f32, paths.clips_index)):
        rows, lines = f32_rows(f32, dim), count_lines(idx)
        if rows != lines:
            raise ValueError(
                f"{f32.name} has {rows} rows but {idx.name} has {lines} lines; "
                f"the last good pair is in {paths.vectors_prev}"
            )


def _pack_rows(rows: Sequence[Sequence[float]], dim: int) -> bytes:
    buf = bytearray()
    for row in rows:
        if len(row) != dim:
            raise ValueError(f"expected {dim}-D row, got {len(row)}")
        buf.extend(struct.pack(f"<{dim}f", *[float(x) for x in row]))
    return bytes(buf)


def _append_atomic(path: Path, extra: bytes) -> None:
    part = path.with_suffix(path.suffix + ".part")
    with open(part, "wb") as out:
        if path.is_file():
            with open(path, "rb") as src:
                shutil.copyfileobj(src, out, 1 << 20)
        out.write(extra)
    part.replace(path)


def merge_vectors(
    paths: Paths,
    track_rows: Sequence[dict[str, Any]],
    track_vecs: Sequence[Sequence[float]],
    clip_rows: Sequence[dict[str, Any]] = (),
    clip_vecs: Sequence[Sequence[float]] = (),
    *,
    dim: int = VECTOR_DIM,
) -> int:
    """Append rows for ids not yet present. Existing bytes and lines are left as they are.
    Returns the number of tracks added. Idempotent: a second merge of the same rows adds none."""
    paths.vectors.mkdir(parents=True, exist_ok=True)
    check_vector_files(paths, dim)
    have = {str(r.get("id")) for r in load_tracks_jsonl(paths.tracks_index)}
    new_t = [(r, v) for r, v in zip(track_rows, track_vecs, strict=True) if str(r.get("id")) not in have]
    if not new_t:
        return 0
    have_clips = {str(r.get("key")) for r in load_tracks_jsonl(paths.clips_index)}
    new_c = [(r, v) for r, v in zip(clip_rows, clip_vecs, strict=True) if str(r.get("key")) not in have_clips]

    files = (paths.tracks_f32, paths.tracks_index, paths.clips_f32, paths.clips_index)
    # The first full run's matrices, kept once; and the pair from before this merge.
    if not paths.vectors_baseline.exists():
        paths.vectors_baseline.mkdir(parents=True)
        for f in files:
            if f.is_file():
                shutil.copy2(f, paths.vectors_baseline / f.name)
    paths.vectors_prev.mkdir(parents=True, exist_ok=True)
    for f in files:
        if f.is_file():
            tmp = paths.vectors_prev / (f.name + ".part")
            shutil.copy2(f, tmp)
            tmp.replace(paths.vectors_prev / f.name)

    def lines(rows: Iterable[dict[str, Any]]) -> bytes:
        return "".join(json.dumps(r, sort_keys=True) + "\n" for r in rows).encode("utf-8")

    _append_atomic(paths.tracks_f32, _pack_rows([v for _, v in new_t], dim))
    _append_atomic(paths.tracks_index, lines(r for r, _ in new_t))
    if new_c:
        _append_atomic(paths.clips_f32, _pack_rows([v for _, v in new_c], dim))
        _append_atomic(paths.clips_index, lines(r for r, _ in new_c))
    check_vector_files(paths, dim)
    return len(new_t)


def list_r2(rclone: Path, remote: str, runner=subprocess.run) -> set[str]:
    proc = runner(
        [str(rclone), "lsf", "-R", "--files-only", remote],
        capture_output=True, text=True, check=False, timeout=600,
    )
    if proc.returncode != 0:
        raise OSError(f"rclone lsf failed: {(proc.stderr or '').strip()[-300:]}")
    return {line.rstrip("/") for line in proc.stdout.splitlines() if line.strip()}


def fetch_master(
    rel: str,
    dest: Path,
    *,
    root: Path,
    remote: str,
    rclone: Path,
    use_drive: bool,
    size_bytes: int | None = None,
    runner=subprocess.run,
) -> str:
    """Copy one master to dest: from the drive under `disk-slot --nowait` when it is free and
    readable, else from R2. Returns "drive" or "r2"."""
    part = dest.with_suffix(dest.suffix + ".part")

    def good() -> bool:
        return part.is_file() and part.stat().st_size > 0 and (not size_bytes or part.stat().st_size == size_bytes)

    if use_drive:
        cmd = ["disk-slot", "--nowait", str(root), "--", "gtimeout", "900", "cp", str(root / rel), str(part)]
        proc = runner(cmd, capture_output=True, text=True, check=False)
        if proc.returncode == 0 and good():
            part.replace(dest)
            return "drive"
    proc = runner(
        [str(rclone), "copyto", f"{remote}/{rel}", str(part)],
        capture_output=True, text=True, check=False, timeout=1800,
    )
    if proc.returncode != 0 or not good():
        raise OSError(f"fetch {rel}: rclone exit {proc.returncode} {(proc.stderr or '').strip()[-200:]}")
    part.replace(dest)
    return "r2"


def drive_readable(root: Path, runner=subprocess.run) -> bool:
    """One bounded probe: a LaunchAgent can block for ever on an unanswered privacy prompt (W17),
    and a busy disk makes disk-slot --nowait exit 75. Either way the masters come from R2."""
    if not root.is_dir():
        return False
    try:
        proc = runner(
            ["disk-slot", "--nowait", str(root), "--", "gtimeout", "60", "ls", str(root)],
            capture_output=True, text=True, check=False, timeout=120,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    return proc.returncode == 0


def load_catalogue_entries(path: Path) -> list[dict[str, Any]]:
    doc = json.loads(Path(path).expanduser().read_text(encoding="utf-8"))
    entries = doc.get("entries") if isinstance(doc, dict) else None
    if not isinstance(entries, list):
        raise ValueError("catalogue has no entries list")
    return entries


def _prepared(paths: Paths) -> list[dict[str, Any]]:
    data = read_json(paths.inc_prepared, [])
    return data if isinstance(data, list) else []


def _remaining_budget(paths: Paths, cap: float) -> float:
    doc = read_spend(paths.spend)
    return cap - spend_today(doc, ledger_day())


def cmd_inc_prepare(args: argparse.Namespace) -> int:
    """Fetch and clip the songs that tonight's budget covers. Resumable."""
    paths = Paths(Path(args.state))
    entries = load_catalogue_entries(args.catalogue)
    embedded = {str(r.get("id")) for r in load_index_rows(paths)}
    jobs = load_jobs(paths.inc_jobs)
    prepared = _prepared(paths)
    exclude = inflight_ids(jobs) | {p["id"] for p in prepared}
    try:
        r2 = list_r2(args.rclone, args.remote)
    except (OSError, subprocess.TimeoutExpired) as exc:
        print(f"prepare: cannot list R2: {exc}", file=sys.stderr)
        return 1
    todo = pending_entries(entries, embedded, r2, exclude)
    try:
        remaining = _remaining_budget(paths, args.cap_usd) - sum(float(p.get("estUsd") or 0) for p in prepared)
    except SpendError as exc:
        print(f"prepare: {exc}", file=sys.stderr)
        return 2
    pick = select_within_budget(todo, remaining, limit=args.limit)
    print(f"prepare: {len(todo)} songs to embed, {len(prepared)} already prepared, "
          f"${max(remaining, 0):.2f} left today: taking {len(pick)}")
    if not pick:
        return 0

    ffmpeg = Path(args.ffmpeg_dir) / "ffmpeg"
    ffprobe = Path(args.ffmpeg_dir) / "ffprobe"
    root = Path(args.root).expanduser()
    use_drive = drive_readable(root)
    tmp = Path(tempfile.mkdtemp(prefix="music-embed-"))
    failed = 0
    try:
        for e in pick:
            sha, rel = str(e["sha256"]), str(e["relativePath"])
            tags = e.get("tags") or {}
            master = tmp / "master.m4a"
            try:
                src = fetch_master(rel, master, root=root, remote=args.remote, rclone=args.rclone,
                                   use_drive=use_drive, size_bytes=int(e.get("sizeBytes") or 0) or None)
                duration = float(e.get("durationSeconds") or 0) or ffprobe_duration(ffprobe, master)
                keys = []
                for idx, (start, dur) in enumerate(clip_windows(duration)):
                    dest = paths.clips / sha / f"{idx}.mp3"
                    if not (dest.is_file() and dest.stat().st_size > 0):
                        ffmpeg_clip(ffmpeg, master, dest, start=start, duration=dur)
                    keys.append(clip_key(sha, idx))
            except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
                failed += 1
                print(f"  skip {rel}: {exc}", file=sys.stderr)
                continue
            finally:
                if master.exists():
                    master.unlink()  # inside this run's temp dir
            prepared.append({
                "id": sha,
                "relativePath": rel,
                "tags": {"title": tags.get("title", ""), "artist": tags.get("artist", ""), "album": tags.get("album", "")},
                "durationSeconds": duration,
                "clips": keys,
                "estUsd": round(song_cost_usd(duration), 6),
                "source": src,
            })
            write_json(paths.inc_prepared, prepared)
            print(f"  {src}: {rel} ({len(keys)} clips)")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)  # a temp dir made above
    return 1 if failed and failed == len(pick) else 0


def cmd_inc_submit(args: argparse.Namespace) -> int:
    """One Batch API job for the prepared songs, reserved against the daily cap first."""
    paths = Paths(Path(args.state))
    prepared = _prepared(paths)
    if not prepared:
        print("submit: nothing prepared")
        return 0
    jobs = load_jobs(paths.inc_jobs)
    busy = [j for j in jobs if j.get("state") in ("SUBMITTED", "PENDING", "RUNNING")]
    if busy:
        print(f"submit: {busy[0]['shard']} still {busy[0]['state']}; one job at a time (Tier 1 limit)")
        return 0
    embedded = {str(r.get("id")) for r in load_index_rows(paths)} | inflight_ids(jobs)
    prepared = [p for p in prepared if p["id"] not in embedded]
    try:
        remaining = _remaining_budget(paths, args.cap_usd)
    except SpendError as exc:
        print(f"submit: {exc}", file=sys.stderr)
        return 2
    take: list[dict[str, Any]] = []
    left = remaining
    for p in prepared:
        if float(p["estUsd"]) <= left + 1e-9:
            take.append(p)
            left -= float(p["estUsd"])
    if not take:
        print(f"submit: daily cap reached (${args.cap_usd - remaining:.2f} of ${args.cap_usd:.2f} today); "
              f"{len(prepared)} songs wait for tomorrow")
        return 0
    rows: list[tuple[str, Path]] = []
    for p in take:
        for key in p["clips"]:
            sha, idx = parse_clip_key(key)
            clip = paths.clips / sha / f"{idx}.mp3"
            if not (clip.is_file() and clip.stat().st_size > 0):
                print(f"submit: clip missing {clip}; run prepare again", file=sys.stderr)
                return 1
            rows.append((key, clip))
    usd = round(sum(float(p["estUsd"]) for p in take), 6)
    shard = "inc-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    paths.inc_batches.mkdir(parents=True, exist_ok=True)
    shard_path = paths.inc_batches / f"{shard}.jsonl"
    part = shard_path.with_suffix(".jsonl.part")
    with open(part, "wb") as fh:
        for key, clip in rows:
            fh.write(encode_batch_line(key, clip))
    part.replace(shard_path)
    if args.dry_run:
        print(f"submit (dry run): {shard} {len(take)} songs, {len(rows)} clips, ${usd:.2f}")
        return 0
    try:
        total = reserve_spend(paths, usd, args.cap_usd, note=shard)
    except (SpendError, CapExceeded) as exc:
        print(f"submit: {exc}", file=sys.stderr)
        return 2
    print(f"submit: {shard} {len(take)} songs, {len(rows)} clips, ${usd:.2f} reserved; "
          f"today ${total:.2f} of ${args.cap_usd:.2f}")
    rec: dict[str, Any] = {
        "shard": shard,
        "created": utc_now_iso(),
        "ids": [p["id"] for p in take],
        "songs": {p["id"]: p["tags"] for p in take},
        "clips": [k for k, _ in rows],
        "estUsd": usd,
        "state": "SUBMITTING",
    }
    jobs.append(rec)
    save_jobs(paths.inc_jobs, jobs)
    try:
        client = get_genai_client()
        upload = client.files.upload(file=str(shard_path), config={"mime_type": "jsonl"})
        job = client.batches.create_embeddings(
            model=args.model, src={"file_name": upload.name}, config={"display_name": shard},
        )
        rec.update(file_name=upload.name, job_name=job.name, state="SUBMITTED")
    except Exception as exc:  # the reservation stands: a failed upload is not refunded
        rec.update(state="SUBMIT_FAILED", error=str(exc)[:300])
        save_jobs(paths.inc_jobs, jobs)
        print(f"submit: {shard} failed: {str(exc)[:300]}", file=sys.stderr)
        return 1
    save_jobs(paths.inc_jobs, jobs)
    taken = set(rec["ids"])
    write_json(paths.inc_prepared, [p for p in _prepared(paths) if p["id"] not in taken])
    print(f"submitted {shard} -> {rec['job_name']}")
    return 0


def merge_job_results(paths: Paths, rec: dict[str, Any], text: str) -> tuple[int, list[dict[str, Any]]]:
    wanted = set(rec.get("clips") or [])
    songs = rec.get("songs") or {}
    clip_rows: list[dict[str, Any]] = []
    clip_vecs: list[list[float]] = []
    errors: list[dict[str, Any]] = []
    for line in text.splitlines():
        if not line.strip():
            continue
        key, vals, err = parse_result_line(json.loads(line))
        if err is not None or vals is None or len(vals) != VECTOR_DIM:
            errors.append({"key": key, "error": err or f"dims {0 if vals is None else len(vals)}"})
            continue
        if key not in wanted:
            continue
        sha, _ = parse_clip_key(str(key))
        tags = songs.get(sha) or {}
        clip_rows.append({"key": key, "sha": sha, "artist": tags.get("artist", ""),
                          "title": tags.get("title", ""), "album": tags.get("album", "")})
        clip_vecs.append(vals)
    # Keep the clip order stable (key order), whatever order the batch returned.
    order = sorted(range(len(clip_rows)), key=lambda i: (clip_rows[i]["sha"], parse_clip_key(clip_rows[i]["key"])[1]))
    clip_rows = [clip_rows[i] for i in order]
    clip_vecs = [clip_vecs[i] for i in order]
    track_rows, track_vecs = track_vectors_from_clips(clip_rows, clip_vecs)
    added = merge_vectors(paths, track_rows, track_vecs, clip_rows, clip_vecs)
    return added, errors


def cmd_inc_collect(args: argparse.Namespace) -> int:
    """Merge every finished incremental job. Safe to run at any time."""
    paths = Paths(Path(args.state))
    jobs = load_jobs(paths.inc_jobs)
    live = [j for j in jobs if j.get("state") in INFLIGHT_STATES and j.get("job_name")]
    if not live:
        print("collect: no job in flight")
        return 0
    client = get_genai_client()
    rc = 0
    for rec in live:
        results = paths.inc_results / f"{rec['shard']}.jsonl"
        if not results.is_file():
            state = normalise_job_state(client.batches.get(name=rec["job_name"]).state)
            if state in ("PENDING", "RUNNING"):
                rec["state"] = state
                print(f"collect: {rec['shard']} {state}")
                continue
            if state != "SUCCEEDED":
                rec["state"] = state or "UNKNOWN"
                rec["endedAt"] = utc_now_iso()
                print(f"collect: {rec['shard']} ended {state}; its songs are offered again", file=sys.stderr)
                rc = 1
                continue
            rec["state"] = "SUCCEEDED"
            save_jobs(paths.inc_jobs, jobs)
            atomic_write_text(results, download_job_results(client, rec["job_name"]))
        try:
            added, errors = merge_job_results(paths, rec, results.read_text(encoding="utf-8"))
        except ValueError as exc:
            print(f"collect: {rec['shard']}: {exc}", file=sys.stderr)
            rc = 1
            continue
        rec.update(state="COLLECTED", collectedAt=utc_now_iso(), added=added, errors=len(errors))
        if errors:
            rec["errorSample"] = errors[:5]
        print(f"collect: {rec['shard']} merged {added} songs ({len(errors)} clip errors)")
    save_jobs(paths.inc_jobs, jobs)
    return rc


def cmd_inc_wait(args: argparse.Namespace) -> int:
    """Collect until no job is in flight or the timeout passes (the rest is collected next run)."""
    paths = Paths(Path(args.state))
    deadline = time.monotonic() + float(args.timeout)
    while True:
        rc = cmd_inc_collect(args)
        live = [j for j in load_jobs(paths.inc_jobs) if j.get("state") in INFLIGHT_STATES]
        if not live:
            return rc
        if time.monotonic() >= deadline:
            print(f"wait: {live[0]['shard']} still {live[0]['state']}; the next run collects it")
            return 0
        time.sleep(float(args.interval))


def cmd_spend(args: argparse.Namespace) -> int:
    paths = Paths(Path(args.state))
    if args.init:
        made = init_spend(paths)
        print(f"spend ledger {'created' if made else 'already there'}: {paths.spend}")
    try:
        doc = read_spend(paths.spend)
    except SpendError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    day = ledger_day()
    spent = spend_today(doc, day)
    print(json.dumps({"day": day, "spentUsd": round(spent, 4), "capUsd": args.cap_usd,
                      "remainingUsd": round(max(args.cap_usd - spent, 0.0), 4)}))
    return 0


def cmd_local_gap(args: argparse.Namespace) -> int:
    rels = {str(e.get("relativePath") or "") for e in load_catalogue_entries(args.catalogue)}
    missing = downloaded_not_in_r2(rels, Path(args.hot).expanduser(), Path(args.pending).expanduser())
    write_json(Path(args.out).expanduser(), {"at": utc_now_iso(), "songs": missing})
    print(f"local-gap: {len(missing)} downloaded songs not in the bucket's catalogue")
    return 0


def cmd_gaps(args: argparse.Namespace) -> int:
    paths = Paths(Path(args.state))
    entries = load_catalogue_entries(args.catalogue)
    r2 = list_r2(args.rclone, args.remote)
    downloaded = None
    local = read_json(paths.local_gap, None)
    if isinstance(local, dict) and isinstance(local.get("songs"), list):
        try:
            age = time.time() - datetime.fromisoformat(str(local["at"]).replace("Z", "+00:00")).timestamp()
        except (KeyError, ValueError):
            age = float("inf")
        if age < 12 * 3600:
            downloaded = [str(s) for s in local["songs"]]
    spend: float | None
    try:
        spend = spend_today(read_spend(paths.spend), ledger_day())
        spend_err = None
    except SpendError as exc:
        spend, spend_err = None, str(exc)
    jobs = load_jobs(paths.inc_jobs)
    report = gap_report(entries, load_index_rows(paths), r2, downloaded=downloaded, spend_usd=spend,
                        cap_usd=args.cap_usd, in_flight=len(inflight_ids(jobs)))
    if spend_err:
        report["spendError"] = spend_err
    status = read_json(paths.state / "nightly-status.json", None)
    if isinstance(status, dict):
        report["lastRun"] = status
    write_json(paths.gaps, report)
    print(f"gaps: {report['inR2NotEmbedded']} in R2 not embedded, {report['embeddedNotInR2']} embedded not in R2, "
          f"{report['downloadedNotInR2']} downloaded not in R2; spend today "
          f"{'unreadable' if spend is None else f'${spend:.2f}'} of ${args.cap_usd:.2f}")
    if args.upload:
        proc = subprocess.run(
            [str(args.rclone), "copyto", str(paths.gaps), f"{args.remote}/{GAPS_REMOTE_PATH}"],
            capture_output=True, text=True, check=False, timeout=300,
        )
        if proc.returncode != 0:
            print(f"gaps: upload failed: {(proc.stderr or '').strip()[-200:]}", file=sys.stderr)
            return 1
        print(f"gaps: uploaded to {args.remote}/{GAPS_REMOTE_PATH}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--catalogue", type=Path, default=DEFAULT_CATALOGUE)
    p.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    p.add_argument("--ffmpeg-dir", type=Path, default=DEFAULT_FFMPEG_DIR)
    p.add_argument("--state", type=Path, default=DEFAULT_STATE)
    p.add_argument("--model", default=DEFAULT_MODEL)
    sub = p.add_subparsers(dest="cmd", required=True)

    plan = sub.add_parser("plan", help="write tracks.jsonl and missing.jsonl")
    plan.add_argument("--force", action="store_true")
    plan.set_defaults(func=cmd_plan)

    clips = sub.add_parser("clips", help="ffmpeg MP3 clips")
    clips.add_argument("--limit", type=int, default=None)
    clips.set_defaults(func=cmd_clips)

    build = sub.add_parser("build", help="write batch JSONL shards")
    build.add_argument("--only-failed", action="store_true")
    build.set_defaults(func=cmd_build)

    sub.add_parser("cost", help="estimate embedding cost").set_defaults(func=cmd_cost)
    sub.add_parser("preflight", help="live API smoke test").set_defaults(func=cmd_preflight)

    submit = sub.add_parser("submit", help="upload shards and start batch jobs")
    submit.add_argument("--dry-run", action="store_true")
    submit.add_argument("--resubmit", default=None, help="shard name to resubmit")
    submit.set_defaults(func=cmd_submit)

    sub.add_parser("poll", help="print batch job states").set_defaults(func=cmd_poll)
    col = sub.add_parser("collect", help="download vectors and build indexes (first full run only)")
    col.add_argument("--force", action="store_true", help="rebuild even though nightly rows would be lost")
    col.set_defaults(func=cmd_collect)

    def money(sp: argparse.ArgumentParser) -> None:
        sp.add_argument("--cap-usd", type=float, default=float(os.environ.get("MUSIC_EMBED_CAP_USD", DEFAULT_CAP_USD)),
                        help="daily (UTC) embedding spend cap; default $5 or $MUSIC_EMBED_CAP_USD")

    def bucket(sp: argparse.ArgumentParser) -> None:
        sp.add_argument("--remote", default=DEFAULT_REMOTE, help="rclone path of the R2 bucket")
        sp.add_argument("--rclone", type=Path, default=DEFAULT_RCLONE)

    inc = sub.add_parser("increment", help="nightly: embed catalogue songs that have no vector yet")
    inc_sub = inc.add_subparsers(dest="stage", required=True)
    prep = inc_sub.add_parser("prepare", help="fetch masters (drive or R2) and cut clips, within today's budget")
    prep.add_argument("--limit", type=int, default=None)
    money(prep)
    bucket(prep)
    prep.set_defaults(func=cmd_inc_prepare)
    isub = inc_sub.add_parser("submit", help="reserve spend, then start one batch job for the prepared songs")
    isub.add_argument("--dry-run", action="store_true")
    money(isub)
    isub.set_defaults(func=cmd_inc_submit)
    icol = inc_sub.add_parser("collect", help="merge finished jobs into tracks.f32 / tracks-index.jsonl")
    icol.set_defaults(func=cmd_inc_collect)
    iwait = inc_sub.add_parser("wait", help="collect until no job is in flight or --timeout seconds pass")
    iwait.add_argument("--timeout", type=float, default=7200)
    iwait.add_argument("--interval", type=float, default=60)
    iwait.set_defaults(func=cmd_inc_wait)

    sp = sub.add_parser("spend", help="today's embedding spend against the cap")
    sp.add_argument("--init", action="store_true", help="create the ledger if it is missing")
    money(sp)
    sp.set_defaults(func=cmd_spend)

    gp = sub.add_parser("gaps", help="write gaps.json (in R2 not embedded, embedded not in R2, ...)")
    gp.add_argument("--upload", action="store_true", help=f"also copy it to the bucket as {GAPS_REMOTE_PATH}")
    money(gp)
    bucket(gp)
    gp.set_defaults(func=cmd_gaps)

    lg = sub.add_parser("local-gap", help="songs downloaded on this Mac that the catalogue lacks")
    lg.add_argument("--hot", type=Path, default=Path.home() / "Music/Glancebar Lossless")
    lg.add_argument("--pending", type=Path, default=Path.home() / "Music/Apple Music")
    lg.add_argument("--out", type=Path, required=True)
    lg.set_defaults(func=cmd_local_gap)

    nb = sub.add_parser("neighbours", help="cosine neighbours for artist/title substring")
    nb.add_argument("query")
    nb.add_argument("-k", type=int, default=5)
    nb.set_defaults(func=cmd_neighbours)

    ex = sub.add_parser("export", help="build music-space.json from track vectors and library")
    ex.add_argument("--vectors", type=Path, default=None, help="directory with tracks.f32 + tracks-index.jsonl")
    ex.add_argument("--library", type=Path, default=Path.home() / "Library/Application Support/Glancebar/mix/library.json")
    ex.add_argument("--out", type=Path, default=Path.home() / "Library/Application Support/Glancebar/mix/music-space.json")
    ex.set_defaults(func=cmd_export)
    return p


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())