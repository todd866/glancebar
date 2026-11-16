#!/usr/bin/env python3
"""Resumable CLI: embed Glancebar music-library tracks with gemini-embedding-2 (batch API)."""
from __future__ import annotations

import argparse
import base64
import json
import os
import struct
import subprocess
import sys
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
        if hasattr(first, "values"):
            return [float(x) for x in first.values]
        if isinstance(first, dict) and first.get("values"):
            return [float(x) for x in first["values"]]
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
        state = str(job.state or "")
        print(f"preflight job {state}")
        if state in ("JOB_STATE_SUCCEEDED", "SUCCEEDED"):
            break
        if state in ("JOB_STATE_FAILED", "FAILED", "JOB_STATE_CANCELLED", "CANCELLED", "JOB_STATE_EXPIRED", "EXPIRED"):
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
    s = str(state or "")
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
    sub.add_parser("collect", help="download vectors and build indexes").set_defaults(func=cmd_collect)

    nb = sub.add_parser("neighbours", help="cosine neighbours for artist/title substring")
    nb.add_argument("query")
    nb.add_argument("-k", type=int, default=5)
    nb.set_defaults(func=cmd_neighbours)
    return p


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())