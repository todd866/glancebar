#!/usr/bin/env python3
"""media-sync — one shared record of music signals and health checks."""

from __future__ import annotations

import argparse
import json
import os
import re
import socket
import subprocess
import sqlite3
import sys
import time
import unicodedata
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Set, Tuple

HOME = Path.home()
_TOOL_DIR = Path(__file__).resolve().parent
_REPO_ROOT = _TOOL_DIR.parent
_SCOUT_DIR = _REPO_ROOT / "music-scout"
_OFFLINE_CACHE = _REPO_ROOT / "offline-cache"
for _p in (_SCOUT_DIR, _OFFLINE_CACHE):
    if str(_p) not in sys.path:
        sys.path.insert(0, str(_p))

import offline_cache as oc  # noqa: E402
import scout  # noqa: E402

track_key = scout.track_key
normal = scout.normal

def _default_host() -> str:
    """This Mac's short name. `gethostname` can return an address on some networks (a file
    was once written as signals-192.json), so ask macOS for the local host name first."""
    try:
        out = subprocess.run(["/usr/sbin/scutil", "--get", "LocalHostName"],
                             capture_output=True, text=True, timeout=5)
        name = out.stdout.strip().lower()
        if out.returncode == 0 and name:
            return name
    except (OSError, subprocess.SubprocessError):
        pass
    name = socket.gethostname().split(".")[0].lower()
    return name if name and not name.isdigit() else "this-mac"


DEFAULT_HOST = _default_host()

DEFAULTS: Dict[str, Any] = {
    "host": DEFAULT_HOST,
    "share_dir": str(HOME / ".local/state/mac-sync/media"),
    "state_dir": str(HOME / ".local/state/media-sync"),
    "shazam_db": str(HOME / "Library/Application Support/com.apple.shazamd/ShazamLibrary.sqlite"),
    "hearts_path": str(HOME / ".local/state/selector/hearts.json"),
    "heart_history": str(HOME / ".local/state/selector/heart-history.jsonl"),
    "glancebar_feedback": str(HOME / "Library/Application Support/Glancebar/mix/feedback.jsonl"),
    "liked_pulled": str(HOME / ".local/state/glancebar-mix/liked-pulled.json"),
    "yt_liked_dir": str(HOME / "Music/YouTube Liked"),
    "music_sync_inventory": str(HOME / ".local/state/music-sync/inventory.json"),
    "catalogue": str(HOME / ".local/state/glancebar-music-library/catalogue.json"),
    "tv_storage": "",
    "tv_music_videos": "",
    "storefront": "au",
    "mixpool_state": str(HOME / ".local/state/glancebar-mix"),
    "apple_music_dir": str(HOME / "Music/Apple Music"),
    "music_library_state": str(HOME / ".local/state/glancebar-music-library"),
    "scout_state": str(HOME / ".local/state/glancebar-music-scout"),
    "selector_state": str(HOME / ".local/state/selector"),
    "tv_video_log": "",
    "rotations": [
        {"station": "triplej", "scores": str(HOME / ".local/state/selector/scores.json")},
    ],
    "picks_min_score": 2.0,
    "picks_max": 300,
    "tv_channel_scores": "",
    "tv_src_prefix": "music",
    "check": {
        "ledger_warn_h": 30,
        "ledger_fail_h": 72,
        "shazam_fresh_days": 30,
        "shazam_wait_d": 3,
        "favourites_min_share": 0.90,
        "favourites_warn_h": 14,
        "favourites_fail_h": 48,
        "offload_warn_h": 24,
        "offload_fail_h": 96,
        "upload_warn_h": 36,
        "upload_fail_h": 72,
        "scout_warn_h": 30,
        "scout_fail_h": 72,
        "hotset_warn_h": 30,
        "hotset_fail_h": 96,
        "triplej_warn_h": 30,
        "triplej_fail_h": 72,
        "tv_videos_warn_h": 36,
        "tv_videos_fail_h": 96,
        "tv_channel_warn_h": 36,
        "tv_channel_fail_h": 96,
        "peer_stale_h": 50,
    },
}

APPLE_EPOCH = datetime(2001, 1, 1, tzinfo=timezone.utc)

_AUDIO = {".m4a", ".mp3", ".flac", ".alac", ".aac", ".wav", ".aiff", ".aif"}
_VIDEO = {".mp4", ".m4v", ".mov", ".webm", ".mkv"}

_YT_NAME = re.compile(
    r"^(?P<artist>.+?) - (?P<title>.+) \[(?P<vid>[A-Za-z0-9_-]+)\]\.m4a$",
    re.IGNORECASE,
)
_VID_TAIL = re.compile(r" \[([A-Za-z0-9_-]+)\]$")
_MATCH_FEAT_TRAIL = re.compile(
    r"\s+(?:feat\.?|ft\.?|featuring)\s+.+$", re.IGNORECASE
)
_STRIP_DECOR = re.compile(
    r"\s*[\(\[]"
    r"(?:Official Video|Official Music Video|Official Audio|Visualiser|"
    r"Lyric Video|4K Remaster)"
    r"[\)\]]\s*",
    re.IGNORECASE,
)

_clock_fn: Callable[[], float] = time.time


def set_clock(fn: Callable[[], float]) -> None:
    global _clock_fn
    _clock_fn = fn


def now_epoch() -> int:
    return int(_clock_fn())


def utc_now() -> datetime:
    return datetime.fromtimestamp(_clock_fn(), tz=timezone.utc)


def iso_now() -> str:
    return utc_now().strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(value: str) -> Optional[datetime]:
    text = (value or "").strip()
    if not text:
        return None
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        return datetime.fromisoformat(text).astimezone(timezone.utc)
    except ValueError:
        return None


def load_config(path: Optional[Path] = None) -> Dict[str, Any]:
    cfg = json.loads(json.dumps(DEFAULTS))
    p = path or (HOME / ".config/glancebar/media-sync.json")
    if p.is_file():
        raw = json.loads(p.read_text(encoding="utf-8"))
        for key, val in raw.items():
            if key == "check" and isinstance(val, dict):
                cfg["check"].update(val)
            else:
                cfg[key] = val
    return cfg


def expand(path: str) -> Path:
    return Path(path).expanduser()


def atomic_write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, path)


def atomic_write_json(path: Path, doc: Any) -> None:
    atomic_write_text(path, json.dumps(doc, indent=2, ensure_ascii=False) + "\n")


def age_fact(seconds: float) -> str:
    hours = seconds / 3600.0
    if hours < 48:
        return f"{int(round(hours))} h"
    days = hours / 24.0
    return f"{int(round(days))} d"


def source_status(ok: bool, count: int = 0, error: str = "") -> Dict[str, Any]:
    return {"ok": ok, "count": count, "error": error}


def read_json_file(path: Path) -> Tuple[Optional[Any], str]:
    if not path.is_file():
        return None, "missing"
    try:
        return json.loads(path.read_text(encoding="utf-8")), ""
    except (OSError, json.JSONDecodeError) as exc:
        return None, str(exc)[:120]


def empty_track(artist: str, title: str) -> Dict[str, Any]:
    return {
        "artist": artist,
        "title": title,
        "album": "",
        "ids": {"apple_music": "", "isrc": "", "youtube": ""},
        "signals": [],
        "owned": False,
        "video": "",
    }


def signal_key(sig: Dict[str, Any]) -> Tuple[str, str, str]:
    return (sig.get("kind") or "", sig.get("source") or "", sig.get("at") or "")


def add_signal(track: Dict[str, Any], sig: Dict[str, Any]) -> None:
    sk = signal_key(sig)
    for existing in track.get("signals") or []:
        if signal_key(existing) == sk:
            return
    track.setdefault("signals", []).append(sig)


def merge_track(base: Dict[str, Any], other: Dict[str, Any]) -> Dict[str, Any]:
    out = dict(base)
    for field in ("artist", "title", "album"):
        if not out.get(field) and other.get(field):
            out[field] = other[field]
    ids = dict(out.get("ids") or {})
    for key, val in (other.get("ids") or {}).items():
        if val and not ids.get(key):
            ids[key] = val
    out["ids"] = ids
    if other.get("owned"):
        out["owned"] = True
    if other.get("video") and not out.get("video"):
        out["video"] = other["video"]
    for sig in other.get("signals") or []:
        add_signal(out, sig)
    return out


def strip_tv_decorations(title: str) -> str:
    prev = None
    text = title
    while prev != text:
        prev = text
        text = _STRIP_DECOR.sub(" ", text).strip()
    return " ".join(text.split())


def parse_bracketed_name(name: str) -> Tuple[str, str, str]:
    """Return artist, title, video id from a file base name (no extension)."""
    vid = ""
    m = _VID_TAIL.search(name)
    if m:
        vid = m.group(1)
        name = name[: m.start()].strip()
    if " - " in name:
        artist, title = name.split(" - ", 1)
        artist = artist.strip()
        title = strip_tv_decorations(title.strip())
    else:
        artist = ""
        title = strip_tv_decorations(name.strip())
    return artist, title, vid


def epoch_to_iso(value: Any) -> str:
    if value is None or value == "":
        return ""
    try:
        num = float(value)
    except (TypeError, ValueError):
        return ""
    if num > 1e12:
        num /= 1000.0
    return datetime.fromtimestamp(num, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def shazam_seconds_to_iso(zdate: Any) -> str:
    try:
        secs = float(zdate)
    except (TypeError, ValueError):
        return ""
    when = APPLE_EPOCH + timedelta(seconds=secs)
    return when.strftime("%Y-%m-%dT%H:%M:%SZ")


def collect_shazam(db_path: Path) -> Tuple[Dict[str, Any], Dict[str, Dict[str, Any]]]:
    tracks: Dict[str, Dict[str, Any]] = {}
    if not db_path.is_file():
        return source_status(False, 0, "missing"), tracks
    try:
        uri = f"file:{db_path}?mode=ro"
        conn = sqlite3.connect(uri, uri=True)
        cur = conn.execute(
            "SELECT ZDATE, ZTITLE, ZSUBTITLE, ZALBUMNAME, ZAPPLEMUSICID, ZISRC "
            "FROM ZSHTRACKMO"
        )
        count = 0
        for zdate, title, artist, album, am_id, isrc in cur:
            artist = str(artist or "").strip()
            title = str(title or "").strip()
            if not artist and not title:
                continue
            key = track_key(artist, title)
            tr = tracks.setdefault(key, empty_track(artist, title))
            tr["album"] = str(album or "") or tr.get("album") or ""
            if am_id:
                tr["ids"]["apple_music"] = str(am_id)
            if isrc:
                tr["ids"]["isrc"] = str(isrc)
            add_signal(
                tr,
                {
                    "kind": "shazam",
                    "source": "shazam",
                    "at": shazam_seconds_to_iso(zdate),
                },
            )
            count += 1
        conn.close()
        return source_status(True, count), tracks
    except (sqlite3.Error, OSError) as exc:
        return source_status(False, 0, str(exc)[:120]), tracks


def read_jsonl(path: Path) -> List[Dict[str, Any]]:
    if not path.is_file():
        return []
    rows: List[Dict[str, Any]] = []
    try:
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line:
                continue
            rows.append(json.loads(line))
    except (OSError, json.JSONDecodeError):
        return []
    return rows


def collect_hearts(cfg: Dict[str, Any]) -> Tuple[Dict[str, Any], Dict[str, Dict[str, Any]]]:
    tracks: Dict[str, Dict[str, Any]] = {}
    hearts_path = expand(cfg["hearts_path"])
    doc, err = read_json_file(hearts_path)
    if doc is None:
        return source_status(False, 0, err), tracks
    heart_keys = list((doc.get("tracks") or []))
    latest_heart: Dict[str, str] = {}
    for row in read_jsonl(expand(cfg["heart_history"])):
        if row.get("action") != "heart":
            continue
        key = row.get("trackKey") or track_key(row.get("artist", ""), row.get("title", ""))
        at = row.get("at")
        if isinstance(at, (int, float)):
            at_iso = epoch_to_iso(at)
        else:
            at_iso = str(at or "")
        if key:
            latest_heart[key] = at_iso
    count = 0
    for key in heart_keys:
        if "|" not in key:
            continue
        artist, title = key.split("|", 1)
        tr = tracks.setdefault(key, empty_track(artist, title))
        add_signal(
            tr,
            {
                "kind": "like",
                "source": "glancebar",
                "at": latest_heart.get(key, ""),
            },
        )
        count += 1
    fb_path = expand(cfg["glancebar_feedback"])
    disliked: Dict[str, str] = {}
    for row in read_jsonl(fb_path):
        key = row.get("track_key") or track_key(row.get("artist", ""), row.get("title", ""))
        if not key:
            continue
        event = row.get("event")
        at = row.get("at")
        at_iso = epoch_to_iso(at) if not isinstance(at, str) else str(at or "")
        if event == "dislike":
            disliked[key] = at_iso
        elif event == "undislike":
            disliked.pop(key, None)
        elif row.get("liked"):
            disliked.pop(key, None)
    for key, at_iso in disliked.items():
        if "|" not in key:
            continue
        artist, title = key.split("|", 1)
        tr = tracks.setdefault(key, empty_track(artist, title))
        add_signal(tr, {"kind": "dislike", "source": "glancebar", "at": at_iso})
        count += 1
    for row in read_jsonl(fb_path):
        if not row.get("liked"):
            continue
        artist = str(row.get("artist") or "")
        title = str(row.get("title") or "")
        key = row.get("track_key") or track_key(artist, title)
        if key in disliked:
            continue
        tr = tracks.setdefault(key, empty_track(artist, title))
        add_signal(
            tr,
            {
                "kind": "like",
                "source": "glancebar",
                "at": epoch_to_iso(row.get("at")) if not isinstance(row.get("at"), str) else row.get("at", ""),
            },
        )
        count += 1
    return source_status(True, count), tracks


def collect_apple_music(cfg: Dict[str, Any]) -> Tuple[Dict[str, Any], Dict[str, Dict[str, Any]]]:
    tracks: Dict[str, Dict[str, Any]] = {}
    path = expand(cfg["liked_pulled"])
    doc, err = read_json_file(path)
    if doc is None:
        return source_status(False, 0, err), tracks
    count = 0
    for bucket in ("done", "failed", "no_match", "wrong_song"):
        items = doc.get(bucket) or {}
        if not isinstance(items, dict):
            continue
        for composite, meta in items.items():
            if "|" not in composite:
                continue
            artist, title = composite.split("|", 1)
            key = track_key(artist, title)
            tr = tracks.setdefault(key, empty_track(artist, title))
            add_signal(tr, {"kind": "like", "source": "apple-music", "at": ""})
            if bucket == "done" and isinstance(meta, dict) and meta.get("track_id"):
                tr["ids"]["apple_music"] = str(meta["track_id"])
            count += 1
    return source_status(True, count), tracks


def collect_youtube(cfg: Dict[str, Any]) -> Tuple[Dict[str, Any], Dict[str, Dict[str, Any]]]:
    tracks: Dict[str, Dict[str, Any]] = {}
    yt_dir = expand(cfg["yt_liked_dir"])
    count = 0
    used_inventory = False
    if yt_dir.is_dir():
        try:
            names = [p.name for p in yt_dir.iterdir() if p.is_file()]
        except OSError as exc:
            return source_status(False, 0, str(exc)[:120]), tracks
        if names:
            for name in names:
                m = _YT_NAME.match(name)
                if not m:
                    continue
                artist = m.group("artist").strip()
                title = m.group("title").strip()
                vid = m.group("vid")
                key = track_key(artist, title)
                tr = tracks.setdefault(key, empty_track(artist, title))
                tr["ids"]["youtube"] = vid
                add_signal(tr, {"kind": "like", "source": "youtube", "at": ""})
                count += 1
            return source_status(True, count), tracks
    inv_path = expand(cfg["music_sync_inventory"])
    doc, err = read_json_file(inv_path)
    if doc is None:
        if not yt_dir.is_dir():
            return source_status(False, 0, "missing"), tracks
        return source_status(True, 0), tracks
    used_inventory = True
    for item in doc.get("yt") or []:
        if not isinstance(item, dict):
            continue
        artist = str(item.get("artist") or "")
        title = str(item.get("title") or "")
        vid = str(item.get("videoId") or "")
        key = track_key(artist, title)
        tr = tracks.setdefault(key, empty_track(artist, title))
        if vid:
            tr["ids"]["youtube"] = vid
        add_signal(tr, {"kind": "like", "source": "youtube", "at": ""})
        count += 1
    st = source_status(True, count)
    if used_inventory and count == 0 and err:
        st = source_status(False, 0, err)
    return st, tracks


def collect_tv_likes(cfg: Dict[str, Any]) -> Tuple[Dict[str, Any], Dict[str, Dict[str, Any]]]:
    tracks: Dict[str, Dict[str, Any]] = {}
    storage = (cfg.get("tv_storage") or "").strip()
    videos_root = (cfg.get("tv_music_videos") or "").strip()
    if not storage:
        return source_status(False, 0, "missing"), tracks
    stor_path = expand(storage)
    doc, err = read_json_file(stor_path)
    if doc is None:
        return source_status(False, 0, err or "missing"), tracks
    raw = doc.get("onto.tv.likes")
    if raw is None:
        return source_status(False, 0, "no tv likes key"), tracks
    if isinstance(raw, str):
        try:
            likes = json.loads(raw)
        except json.JSONDecodeError as exc:
            return source_status(False, 0, str(exc)[:120]), tracks
    else:
        likes = raw
    if not isinstance(likes, dict):
        return source_status(False, 0, "bad likes shape"), tracks
    vroot = expand(videos_root) if videos_root else None
    count = 0
    for src, entry in likes.items():
        if not isinstance(entry, dict):
            continue
        if vroot and not str(src).startswith(str(vroot)):
            continue
        base = Path(str(src)).stem
        artist, title, _vid = parse_bracketed_name(base)
        key = track_key(artist, title)
        tr = tracks.setdefault(key, empty_track(artist, title))
        sig = {
            "kind": "like",
            "source": "tv",
            "at": epoch_to_iso(entry.get("at")),
            "audience": str(entry.get("key") or ""),
        }
        add_signal(tr, sig)
        count += 1
    return source_status(True, count), tracks


def iter_music_videos(root: Path):
    """Yield artist_folder, parsed artist, title, video_id, relative path under root."""
    with os.scandir(root) as artists:
        for artist_ent in artists:
            if not artist_ent.is_dir(follow_symlinks=False):
                continue
            folder = artist_ent.name
            with os.scandir(artist_ent.path) as files:
                for fent in files:
                    if not fent.is_file(follow_symlinks=False):
                        continue
                    if Path(fent.name).suffix.lower() not in _VIDEO:
                        continue
                    artist, title, vid = parse_bracketed_name(Path(fent.name).stem)
                    rel = f"{folder}/{fent.name}"
                    yield folder, artist, title, vid, rel


def collect_videos(cfg: Dict[str, Any]) -> Tuple[Dict[str, Any], Dict[str, Dict[str, Any]]]:
    tracks: Dict[str, Dict[str, Any]] = {}
    root_s = (cfg.get("tv_music_videos") or "").strip()
    if not root_s:
        return source_status(False, 0, "missing"), tracks
    root = expand(root_s)
    if not root.is_dir():
        return source_status(False, 0, "missing"), tracks
    count = 0
    try:
        for _folder, artist, title, vid, _rel in iter_music_videos(root):
            key = track_key(artist, title)
            tr = tracks.setdefault(key, empty_track(artist, title))
            if vid:
                tr["video"] = vid
            count += 1
    except OSError as exc:
        return source_status(False, 0, str(exc)[:120]), tracks
    return source_status(True, count), tracks


def rank_pick_score(index: int, total: int) -> float:
    if total <= 1:
        return 1.0
    return 1.0 - index * 0.75 / (total - 1)


def _catalogue_keys(artist: str, title: str) -> Set[Tuple[str, str]]:
    keys: Set[Tuple[str, str]] = set(oc.catalogue_match_keys(artist, title))
    stripped = _MATCH_FEAT_TRAIL.sub("", str(title or "")).strip()
    if stripped and stripped != title:
        keys |= oc.catalogue_match_keys(artist, stripped)
    return keys


def catalogue_keys_intersect(
    artist_a: str, title_a: str, artist_b: str, title_b: str
) -> bool:
    return bool(_catalogue_keys(artist_a, title_a) & _catalogue_keys(artist_b, title_b))


def picks_from_scores(
    scores_path: Path,
    merged: Dict[str, Dict[str, Any]],
    min_score: float,
    max_n: int,
) -> List[Dict[str, Any]]:
    doc, err = read_json_file(scores_path)
    if doc is None:
        return []
    rows: List[Dict[str, Any]] = []
    for tr in doc.get("tracks") or []:
        if not isinstance(tr, dict):
            continue
        raw = tr.get("score")
        try:
            raw_f = float(raw)
        except (TypeError, ValueError):
            continue
        if raw_f < min_score:
            continue
        artist = str(tr.get("artist") or "")
        title = str(tr.get("title") or "")
        key = track_key(artist, title)
        mtr = merged.get(key) or {}
        if has_dislike(mtr):
            continue
        rows.append(
            {
                "artist": artist,
                "title": title,
                "raw": raw_f,
                "why": str(tr.get("reason") or ""),
                "plays": int(tr.get("play_count") or 0),
            }
        )
    rows.sort(key=lambda r: r["raw"], reverse=True)
    rows = rows[:max_n]
    out: List[Dict[str, Any]] = []
    total = len(rows)
    for i, row in enumerate(rows):
        key = track_key(row["artist"], row["title"])
        out.append(
            {
                "key": key,
                "artist": row["artist"],
                "title": row["title"],
                "score": round(rank_pick_score(i, total), 6),
                "raw": row["raw"],
                "why": row["why"],
                "plays": row["plays"],
            }
        )
    return out


def write_host_picks(cfg: Dict[str, Any], stations: Dict[str, List[Dict[str, Any]]]) -> None:
    if not stations:
        return
    host = cfg.get("host") or DEFAULT_HOST
    doc = {
        "version": 1,
        "host": host,
        "generated": iso_now(),
        "stations": stations,
    }
    share = expand(cfg["share_dir"])
    atomic_write_json(share / f"picks-{host}.json", doc)


def load_picks_from_share(
    share_dir: Path,
) -> Tuple[Dict[str, List[Dict[str, Any]]], Dict[str, int], List[str]]:
    """Merged station picks, pick counts per station, warnings."""
    merged: Dict[str, List[Dict[str, Any]]] = {}
    pick_counts: Dict[str, int] = {}
    station_age: Dict[str, Tuple[str, int]] = {}
    warnings: List[str] = []
    any_ok = False
    if not share_dir.is_dir():
        return merged, pick_counts, warnings
    for path in sorted(share_dir.glob("picks-*.json")):
        doc, err = read_json_file(path)
        if doc is None:
            warnings.append(f"{path.name}: {err}")
            continue
        any_ok = True
        gen = parse_iso(doc.get("generated") or "")
        gen_epoch = int(gen.timestamp()) if gen else 0
        for station, picks in (doc.get("stations") or {}).items():
            if not isinstance(picks, list):
                continue
            pick_counts[station] = pick_counts.get(station, 0) + len(picks)
            prev = station_age.get(station)
            if prev is None or gen_epoch >= prev[1]:
                station_age[station] = (path.name, gen_epoch)
                merged[station] = picks
    if not any_ok:
        warnings.append("no readable picks files")
    return merged, pick_counts, warnings


def tv_catalogue_src(prefix: str, rel_path: str) -> str:
    p = (prefix or "music").strip().strip("/")
    return f"{p}/{rel_path}".replace("\\", "/")


def list_walked_videos(cfg: Dict[str, Any]) -> List[Tuple[str, str, str, str, str]]:
    root_s = (cfg.get("tv_music_videos") or "").strip()
    if not root_s:
        return []
    root = expand(root_s)
    if not root.is_dir():
        return []
    try:
        return list(iter_music_videos(root))
    except OSError:
        return []


def index_videos_by_key(
    videos: List[Tuple[str, str, str, str, str]]
) -> Dict[Tuple[str, str], List[Tuple[str, str, str, str, str]]]:
    """Match key -> the videos that carry it. Each video's keys are worked out once.

    Comparing every pick with every video recomputed both sides' keys each time: 300 picks
    against 1,100 videos ran for more than ten minutes on the Mac that serves the TV."""
    index: Dict[Tuple[str, str], List[Tuple[str, str, str, str, str]]] = {}
    for video in videos:
        for key in _catalogue_keys(video[1], video[2]):
            index.setdefault(key, []).append(video)
    return index


def track_has_local_video(
    artist: str, title: str,
    video_index: Dict[Tuple[str, str], List[Tuple[str, str, str, str, str]]],
) -> bool:
    return any(key in video_index for key in _catalogue_keys(artist, title))


def build_tv_channel_scores(
    cfg: Dict[str, Any],
    station_picks: Dict[str, List[Dict[str, Any]]],
) -> Tuple[Dict[str, Any], Dict[str, int], Dict[str, int]]:
    """Return doc, videos matched per station, pick counts per station."""
    prefix = (cfg.get("tv_src_prefix") or "music").strip() or "music"
    videos = list_walked_videos(cfg)
    channels: Dict[str, Dict[str, Any]] = {}
    matched_n: Dict[str, int] = {}
    pick_n: Dict[str, int] = {}
    video_index = index_videos_by_key(videos)
    for station, picks in station_picks.items():
        pick_n[station] = len(picks)
        items: Dict[str, Dict[str, Any]] = {}
        # Picks come best first; a video that matches two picks keeps the better score.
        for pick in picks:
            for key in _catalogue_keys(pick.get("artist", ""), pick.get("title", "")):
                for video in video_index.get(key, ()):
                    src = tv_catalogue_src(prefix, video[4])
                    if src not in items:
                        items[src] = {
                            "score": pick.get("score", 0.0),
                            "why": pick.get("why") or "",
                        }
        if station == "triplej":
            lav = re.compile(r"like a version", re.IGNORECASE)
            for folder, va, vt, _vid, rel in videos:
                src = tv_catalogue_src(prefix, rel)
                if src in items:
                    continue
                if lav.search(folder) or lav.search(vt) or lav.search(va):
                    items[src] = {"score": 0.6, "why": "Like A Version"}
        channels[station] = {"items": items}
        matched_n[station] = len(items)
    for station in station_picks:
        channels.setdefault(station, {"items": {}})
    return (
        {"version": 1, "generated": iso_now(), "channels": channels},
        matched_n,
        pick_n,
    )


def channel_score_item_count(doc: Dict[str, Any]) -> int:
    total = 0
    for ch in (doc.get("channels") or {}).values():
        if isinstance(ch, dict):
            items = ch.get("items") or {}
            if isinstance(items, dict):
                total += len(items)
    return total


def build_catalogue_owned_index(catalogue_path: Path) -> Set[Tuple[str, str]]:
    doc, _ = read_json_file(catalogue_path)
    if not doc:
        return set()
    index: Set[Tuple[str, str]] = set()
    for entry in doc.get("entries") or []:
        tags = (entry or {}).get("tags") or {}
        for pair in oc.catalogue_match_keys(tags.get("artist", ""), tags.get("title", "")):
            index.add(pair)
    return index


def apply_owned(tracks: Dict[str, Dict[str, Any]], catalogue_path: Path) -> None:
    if not catalogue_path.is_file():
        return
    index = build_catalogue_owned_index(catalogue_path)
    if not index:
        return
    for tr in tracks.values():
        keys = oc.catalogue_match_keys(tr.get("artist", ""), tr.get("title", ""))
        if any(k in index for k in keys):
            tr["owned"] = True


def merge_track_dicts(parts: List[Dict[str, Dict[str, Any]]]) -> Dict[str, Dict[str, Any]]:
    merged: Dict[str, Dict[str, Any]] = {}
    for part in parts:
        for key, tr in part.items():
            if key in merged:
                merged[key] = merge_track(merged[key], tr)
            else:
                merged[key] = json.loads(json.dumps(tr))
    return merged


def load_signals_file(path: Path) -> Tuple[Optional[Dict[str, Any]], str]:
    doc, err = read_json_file(path)
    if doc is None:
        return None, err
    if not isinstance(doc.get("tracks"), dict):
        return None, "bad tracks"
    return doc, ""


def merge_all_signals(share_dir: Path, host: Optional[str] = None) -> Tuple[Dict[str, Dict[str, Any]], List[str]]:
    warnings: List[str] = []
    merged: Dict[str, Dict[str, Any]] = {}
    if not share_dir.is_dir():
        return merged, warnings
    for path in sorted(share_dir.glob("signals-*.json")):
        if host and path.stem == f"signals-{host}":
            continue
        doc, err = load_signals_file(path)
        if doc is None:
            warnings.append(f"{path.name}: {err}")
            continue
        for key, tr in (doc.get("tracks") or {}).items():
            if key in merged:
                merged[key] = merge_track(merged[key], tr)
            else:
                merged[key] = json.loads(json.dumps(tr))
    return merged, warnings


def merge_share_including_host(share_dir: Path) -> Dict[str, Dict[str, Any]]:
    merged: Dict[str, Dict[str, Any]] = {}
    if not share_dir.is_dir():
        return merged
    for path in sorted(share_dir.glob("signals-*.json")):
        doc, err = load_signals_file(path)
        if doc is None:
            continue
        for key, tr in (doc.get("tracks") or {}).items():
            if key in merged:
                merged[key] = merge_track(merged[key], tr)
            else:
                merged[key] = json.loads(json.dumps(tr))
    return merged


def has_like(track: Dict[str, Any]) -> bool:
    for sig in track.get("signals") or []:
        if sig.get("kind") == "like":
            return True
    return False


def has_dislike(track: Dict[str, Any]) -> bool:
    for sig in track.get("signals") or []:
        if sig.get("kind") == "dislike":
            return True
    return False


def liked_export_rows(merged: Dict[str, Dict[str, Any]]) -> List[Dict[str, str]]:
    rows: List[Dict[str, str]] = []
    for key in sorted(merged.keys()):
        tr = merged[key]
        if not has_like(tr) or has_dislike(tr):
            continue
        vid = (tr.get("ids") or {}).get("youtube") or ""
        if not vid:
            vid = f"key:{key}"
        rows.append(
            {
                "videoId": vid,
                "title": tr.get("title") or "",
                "artist": tr.get("artist") or "",
            }
        )
    return rows


def cmd_collect(cfg: Dict[str, Any]) -> int:
    parts: List[Dict[str, Dict[str, Any]]] = []
    sources: Dict[str, Dict[str, Any]] = {}

    # `sources` in the config names the ones this Mac may speak for; the default is all.
    # A Mac that only holds the TV's data must not publish stray likes from an old test run.
    enabled = cfg.get("sources") or None
    collectors = (
        ("shazam", lambda: collect_shazam(expand(cfg["shazam_db"]))),
        ("glancebar", lambda: collect_hearts(cfg)),
        ("apple-music", lambda: collect_apple_music(cfg)),
        ("youtube", lambda: collect_youtube(cfg)),
        ("tv", lambda: collect_tv_likes(cfg)),
        ("video", lambda: collect_videos(cfg)),
    )
    for name, fn in collectors:
        if enabled and name not in enabled:
            sources[name] = source_status(False, 0, "off")
            print(f"{name} off")
            continue
        st, tr = fn()
        sources[name] = st
        parts.append(tr)
        print(f"{name} {st['count']} {st['ok']}")

    tracks = merge_track_dicts(parts)
    apply_owned(tracks, expand(cfg["catalogue"]))

    any_ok = any(s.get("ok") for s in sources.values())
    if not any_ok and not tracks:
        return 1

    host = cfg.get("host") or DEFAULT_HOST
    doc = {
        "version": 1,
        "host": host,
        "generated": iso_now(),
        "sources": sources,
        "tracks": tracks,
    }
    share = expand(cfg["share_dir"])
    out = share / f"signals-{host}.json"
    try:
        atomic_write_json(out, doc)
    except OSError:
        return 1
    state = expand(cfg["state_dir"])
    stamp = state / "last-collect.json"
    try:
        atomic_write_json(stamp, {"at": now_epoch(), "host": host, "sources": sources})
    except OSError:
        pass

    picks_on = not enabled or "picks" in enabled
    if picks_on:
        merged = merge_share_including_host(share)
        min_score = float(cfg.get("picks_min_score", 2.0))
        max_n = int(cfg.get("picks_max", 300))
        station_picks: Dict[str, List[Dict[str, Any]]] = {}
        rots = cfg["rotations"] if "rotations" in cfg else DEFAULTS["rotations"]
        for rot in rots:
            if not isinstance(rot, dict):
                continue
            station = str(rot.get("station") or "").strip()
            scores_s = str(rot.get("scores") or "").strip()
            if not station or not scores_s:
                continue
            picks = picks_from_scores(expand(scores_s), merged, min_score, max_n)
            if picks:
                station_picks[station] = picks
                print(f"picks {station} {len(picks)}")
        if station_picks:
            try:
                write_host_picks(cfg, station_picks)
            except OSError:
                return 1
    return 0


def cmd_show(cfg: Dict[str, Any], args: argparse.Namespace) -> int:
    merged = merge_share_including_host(expand(cfg["share_dir"]))
    since_dt: Optional[datetime] = None
    if args.since is not None:
        since_dt = utc_now() - timedelta(days=float(args.since))
    for key in sorted(merged.keys()):
        if args.key and key != args.key:
            continue
        tr = merged[key]
        kinds: Set[str] = set()
        newest: Optional[datetime] = None
        for sig in tr.get("signals") or []:
            kinds.add(sig.get("kind") or "")
            if args.kind and sig.get("kind") != args.kind:
                continue
            at = parse_iso(sig.get("at") or "")
            if at and (newest is None or at > newest):
                newest = at
        if args.kind and args.kind not in kinds:
            continue
        if since_dt and (newest is None or newest < since_dt):
            continue
        date_s = newest.strftime("%Y-%m-%d") if newest else "----"
        kind_s = ",".join(sorted(k for k in kinds if k))
        flags = []
        if tr.get("owned"):
            flags.append("owned")
        if tr.get("video"):
            flags.append("video")
        flag_s = ",".join(flags) if flags else "-"
        artist = tr.get("artist") or ""
        title = tr.get("title") or ""
        print(f"{date_s} {kind_s:12} {flag_s:10} {artist} — {title}")
    return 0


def export_pick_rows(
    cfg: Dict[str, Any],
    merged: Dict[str, Dict[str, Any]],
    existing_ids: Set[str],
    per_station: int,
) -> List[Dict[str, str]]:
    if per_station <= 0:
        return []
    share = expand(cfg["share_dir"])
    station_picks, _, _ = load_picks_from_share(share)
    videos = list_walked_videos(cfg)
    video_index = index_videos_by_key(videos)
    extra: List[Dict[str, str]] = []
    for station in sorted(station_picks.keys()):
        added = 0
        for pick in station_picks.get(station) or []:
            if added >= per_station:
                break
            key = pick.get("key") or track_key(
                pick.get("artist", ""), pick.get("title", "")
            )
            vid_id = f"pick:{station}:{key}"
            if vid_id in existing_ids:
                continue
            artist = pick.get("artist") or ""
            title = pick.get("title") or ""
            mtr = merged.get(key) or {}
            if (mtr.get("video") or "").strip():
                continue
            if videos and track_has_local_video(artist, title, video_index):
                continue
            extra.append(
                {
                    "videoId": vid_id,
                    "title": title,
                    "artist": artist,
                }
            )
            existing_ids.add(vid_id)
            added += 1
    return extra


def cmd_export_likes(cfg: Dict[str, Any], args: argparse.Namespace) -> int:
    merged = merge_share_including_host(expand(cfg["share_dir"]))
    rows = liked_export_rows(merged)
    picks_n = int(getattr(args, "picks", 0) or 0)
    out = Path(args.out).expanduser()
    old_count = 0
    if out.is_file():
        try:
            old = json.loads(out.read_text(encoding="utf-8"))
            if isinstance(old, list):
                old_count = sum(
                    1
                    for r in old
                    if isinstance(r, dict)
                    and not str(r.get("videoId") or "").startswith("pick:")
                )
        except (OSError, json.JSONDecodeError):
            old_count = 0
    if not rows and not args.force and picks_n <= 0:
        print("export aborted: merged view has no liked tracks")
        return 3
    if old_count and len(rows) < old_count * 0.8 and not args.force:
        print(
            f"export aborted: new list {len(rows)} rows is below 80% of existing {old_count}"
        )
        return 3
    existing_ids = {r["videoId"] for r in rows}
    if picks_n > 0:
        rows = rows + export_pick_rows(cfg, merged, existing_ids, picks_n)
    try:
        atomic_write_json(out, rows)
    except OSError as exc:
        print(f"export failed: {exc}")
        return 1
    return 0


def cmd_tv_scores(cfg: Dict[str, Any], args: argparse.Namespace) -> int:
    out_s = (cfg.get("tv_channel_scores") or "").strip()
    if not out_s:
        print("off")
        return 0
    out = Path(args.out).expanduser() if getattr(args, "out", None) else expand(out_s)
    share = expand(cfg["share_dir"])
    station_picks, _counts, warnings = load_picks_from_share(share)
    for w in warnings:
        print(w)
    readable = False
    if share.is_dir():
        for path in share.glob("picks-*.json"):
            doc, _err = read_json_file(path)
            if doc is not None:
                readable = True
                break
    new_doc, matched_n, pick_n = build_tv_channel_scores(cfg, station_picks)
    new_total = channel_score_item_count(new_doc)
    old_total = 0
    if out.is_file():
        old_doc, _ = read_json_file(out)
        if isinstance(old_doc, dict):
            old_total = channel_score_item_count(old_doc)
    if not readable and not args.force:
        print("tv-scores aborted: no picks file could be read")
        return 3
    if out.is_file() and old_total and new_total < old_total * 0.5 and not args.force:
        print(
            f"tv-scores aborted: new file {new_total} items is below half of existing {old_total}"
        )
        return 3
    try:
        atomic_write_json(out, new_doc)
    except OSError as exc:
        print(f"tv-scores failed: {exc}")
        return 1
    for station in sorted(station_picks.keys()):
        print(f"{station} {matched_n.get(station, 0)} videos of {pick_n.get(station, 0)} picks")
    return 0


CheckRow = Dict[str, Any]


def make_row(
    name: str,
    status: str,
    fact: str,
    host: str,
    detail: str = "",
) -> CheckRow:
    datum = fact.split()[0] if fact else ""
    return {
        "key": f"media:{name}",
        "status": status,
        "name": name,
        "host": host,
        "value": fact,
        "datum": datum,
        "detail": detail or fact,
    }


def worst_status(rows: List[CheckRow]) -> str:
    if any(r["status"] == "fail" for r in rows):
        return "fail"
    if any(r["status"] == "warn" for r in rows):
        return "warn"
    return "pass"


def summarise_check(rows: List[CheckRow]) -> Dict[str, Any]:
    counts = {"pass": 0, "warn": 0, "fail": 0}
    for r in rows:
        counts[r["status"]] = counts.get(r["status"], 0) + 1
    status = worst_status(rows)
    if status == "pass":
        value = "ok"
        datum = "media"
        detail = ""
    else:
        # Only what is wrong: "2 warn", not "0 fail 2 warn".
        value = " ".join(f"{counts[k]} {k}" for k in ("fail", "warn") if counts[k])
        fails = [r for r in rows if r["status"] == "fail"]
        warns = [r for r in rows if r["status"] == "warn"]
        head = fails[0] if fails else warns[0]
        datum = head["name"]
        parts = [f"{r['name']}: {r['detail']}" for r in fails + warns]
        detail = "; ".join(parts)
    return {
        "status": status,
        "value": value,
        "datum": datum,
        "detail": detail,
        "counts": counts,
    }


def print_check_line(row: CheckRow) -> None:
    tag = row["status"].upper()
    if tag == "PASS":
        print(f"PASS {row['name']}: {row['value']}")
    elif tag == "WARN":
        print(f"WARN {row['name']}: {row['value']}")
    else:
        print(f"FAIL {row['name']}: {row['value']}")


def read_ledger_keys(scout_state: Path) -> Dict[str, Set[str]]:
    ledger = scout_state / "ledger.jsonl"
    out: Dict[str, Set[str]] = {}
    for row in read_jsonl(ledger):
        key = row.get("track_key") or ""
        action = row.get("action") or ""
        if not key or not action:
            continue
        out.setdefault(key, set()).add(action)
    return out


def cmd_check(cfg: Dict[str, Any], args: argparse.Namespace) -> int:
    host = cfg.get("host") or DEFAULT_HOST
    chk = cfg.get("check") or {}
    now = _clock_fn()
    share = expand(cfg["share_dir"])
    state_dir = expand(cfg["state_dir"])
    rows: List[CheckRow] = []

    # ledger
    ledger_path = share / f"signals-{host}.json"
    if ledger_path.is_file():
        doc, err = load_signals_file(ledger_path)
        st = "pass"
        fact = ""
        detail = ledger_path.name
        if doc is None:
            st = "fail"
            fact = f"unreadable: {err}"
        else:
            tracks = doc.get("tracks") or {}
            likes = sum(1 for t in tracks.values() if has_like(t))
            shazams = sum(
                1
                for t in tracks.values()
                for s in t.get("signals") or []
                if s.get("kind") == "shazam"
            )
            fact = f"{len(tracks)} tracks, {likes} likes, {shazams} shazams"
            try:
                age_h = (now - ledger_path.stat().st_mtime) / 3600.0
            except OSError:
                age_h = 0
            if age_h > float(chk.get("ledger_fail_h", 72)):
                st = "fail"
                fact = f"{fact}; stale {age_fact(age_h * 3600)}"
            elif age_h > float(chk.get("ledger_warn_h", 30)):
                st = "warn"
                fact = f"{fact}; age {age_fact(age_h * 3600)}"
            for name, src in (doc.get("sources") or {}).items():
                if not src.get("ok") and src.get("error") not in ("", "missing", "off", None):
                    st = "warn" if st == "pass" else st
                    fact = f"{fact}; {name}: {src.get('error')}"
        rows.append(make_row("ledger", st, fact, host, detail))

    # shazam handling
    shazam_db = expand(cfg["shazam_db"])
    if shazam_db.is_file():
        merged = merge_share_including_host(share)
        ledger = read_ledger_keys(expand(cfg["scout_state"]))
        fresh_days = float(chk.get("shazam_fresh_days", 30))
        wait_d = float(chk.get("shazam_wait_d", 3))
        cutoff = utc_now() - timedelta(days=fresh_days)
        fresh: List[Tuple[str, datetime]] = []
        for key, tr in merged.items():
            if tr.get("owned") or has_dislike(tr):
                continue
            for sig in tr.get("signals") or []:
                if sig.get("kind") != "shazam":
                    continue
                at = parse_iso(sig.get("at") or "")
                if at and at >= cutoff:
                    fresh.append((key, at))
        waiting = []
        for key, at in fresh:
            actions = ledger.get(key) or set()
            handled = actions & {"acquired", "queued", "offered", "failed"}
            if handled:
                continue
            age_d = (utc_now() - at).total_seconds() / 86400.0
            if age_d > wait_d:
                waiting.append((key, age_d))
        if waiting:
            oldest = max(w[1] for w in waiting)
            fact = f"{len(waiting)} waiting, oldest {int(round(oldest))} d"
            rows.append(make_row("shazam", "warn", fact, host))
        else:
            fact = f"{len(fresh)} in {int(fresh_days)} d, all handled"
            rows.append(make_row("shazam", "pass", fact, host))

    # favourites
    liked_path = expand(cfg["liked_pulled"])
    pull_log = expand(cfg["mixpool_state"]) / "logs/pull-liked.log"
    if liked_path.is_file():
        doc, err = read_json_file(liked_path)
        st = "pass"
        fact = "0 of 0 lossless"
        if doc is None:
            st = "fail"
            fact = err
        else:
            done = doc.get("done") or {}
            total = 0
            for bucket in ("done", "failed", "no_match", "wrong_song"):
                items = doc.get(bucket) or {}
                if isinstance(items, dict):
                    total += len(items)
            fact = f"{len(done)} of {total} lossless"
            share_ratio = (len(done) / total) if total else 1.0
            if share_ratio < float(chk.get("favourites_min_share", 0.90)):
                st = "warn"
            if pull_log.is_file():
                try:
                    log_age = (now - pull_log.stat().st_mtime) / 3600.0
                except OSError:
                    log_age = 0
                if log_age > float(chk.get("favourites_fail_h", 48)):
                    st = "fail"
                    fact = f"{fact}; log {age_fact(log_age * 3600)} old"
                elif log_age > float(chk.get("favourites_warn_h", 14)):
                    if st == "pass":
                        st = "warn"
                    fact = f"{fact}; log {age_fact(log_age * 3600)} old"
        rows.append(make_row("favourites", st, fact, host))

    # offload
    am_dir = expand(cfg["apple_music_dir"])
    if am_dir.is_dir():
        files: List[float] = []
        try:
            for root, _dirs, names in os.walk(am_dir):
                for name in names:
                    p = Path(root) / name
                    if p.suffix.lower() not in _AUDIO:
                        continue
                    try:
                        files.append(p.stat().st_mtime)
                    except OSError:
                        continue
        except OSError:
            files = []
        st = "pass"
        if not files:
            fact = "empty"
        else:
            oldest = min(files)
            age_h = (now - oldest) / 3600.0
            fact = f"{len(files)} files waiting"
            if age_h > float(chk.get("offload_fail_h", 96)):
                st = "fail"
                fact = f"{len(files)} files, oldest {age_fact(age_h * 3600)}"
            elif age_h > float(chk.get("offload_warn_h", 24)):
                st = "warn"
                fact = f"{len(files)} files, oldest {age_fact(age_h * 3600)}"
        rows.append(make_row("offload", st, fact, host))

    # upload
    push_status = expand(cfg["music_library_state"]) / "push-status.json"
    if push_status.is_file():
        doc, err = read_json_file(push_status)
        st = "pass"
        fact = "ok"
        if doc is None:
            st = "fail"
            fact = err
        else:
            if doc.get("ok") is False:
                st = "fail"
                err_s = str(doc.get("error") or "failed")
                epoch = doc.get("epoch")
                if isinstance(epoch, (int, float)):
                    age_s = now - float(epoch)
                else:
                    age_s = now - push_status.stat().st_mtime
                fact = f"{err_s} ({age_fact(age_s)} ago)"
            else:
                epoch = doc.get("epoch")
                if isinstance(epoch, (int, float)):
                    age_h = (now - float(epoch)) / 3600.0
                else:
                    age_h = (now - push_status.stat().st_mtime) / 3600.0
                fact = f"ok, {age_fact(age_h * 3600)} ago"
                if age_h > float(chk.get("upload_fail_h", 72)):
                    st = "fail"
                elif age_h > float(chk.get("upload_warn_h", 36)):
                    st = "warn"
        rows.append(make_row("upload", st, fact, host))

    # scout
    last_run = expand(cfg["scout_state"]) / "last-run.json"
    if last_run.is_file():
        doc, err = read_json_file(last_run)
        st = "pass"
        fact = "ok"
        if doc is None:
            st = "fail"
            fact = err
        else:
            if doc.get("ok") is False:
                st = "warn"
                errs = doc.get("errors") or []
                fact = str(errs[0]) if errs else "run failed"
            at = parse_iso(doc.get("at") or "")
            if at:
                age_h = (utc_now() - at).total_seconds() / 3600.0
                if age_h > float(chk.get("scout_fail_h", 72)):
                    st = "fail"
                    fact = f"{fact}; {age_fact(age_h * 3600)} old"
                elif age_h > float(chk.get("scout_warn_h", 30)) and st == "pass":
                    st = "warn"
                    fact = f"{fact}; {age_fact(age_h * 3600)} old"
        rows.append(make_row("scout", st, fact, host))

    # hot set
    last_status = expand(cfg["music_library_state"]) / "last-status.json"
    if last_status.is_file():
        doc, err = read_json_file(last_status)
        st = "pass"
        fact = "ok"
        if doc is None:
            st = "fail"
            fact = err
        else:
            if doc.get("lastError"):
                st = "warn"
                fact = str(doc["lastError"])
            sync_at = doc.get("lastSyncAt")
            if isinstance(sync_at, (int, float)):
                age_h = (now - float(sync_at)) / 3600.0
                if age_h > float(chk.get("hotset_fail_h", 96)):
                    st = "fail"
                    fact = f"{fact}; {age_fact(age_h * 3600)} old"
                elif age_h > float(chk.get("hotset_warn_h", 30)) and st == "pass":
                    st = "warn"
                    fact = f"{age_fact(age_h * 3600)} old"
        rows.append(make_row("hot set", st, fact, host))

    # triple j
    station = expand(cfg["selector_state"]) / "station.json"
    if station.is_file():
        try:
            age_h = (now - station.stat().st_mtime) / 3600.0
        except OSError:
            age_h = 0
        st = "pass"
        fact = f"{age_fact(age_h * 3600)} old"
        if age_h > float(chk.get("triplej_fail_h", 72)):
            st = "fail"
        elif age_h > float(chk.get("triplej_warn_h", 30)):
            st = "warn"
        rows.append(make_row("triple j", st, fact, host))

    # tv videos
    tv_log = (cfg.get("tv_video_log") or "").strip()
    if tv_log:
        log_path = expand(tv_log)
        merged = merge_share_including_host(share)
        liked_with_video = sum(1 for t in merged.values() if has_like(t) and t.get("video"))
        st = "pass"
        fact = f"{liked_with_video} liked with video"
        # The job writes `<ISO time>Z pass done` when a pass finishes. A job that stopped must
        # not pass: no log, or no finished pass in it, is a warn.
        last_done: Optional[float] = None
        lines: List[str] = []
        try:
            if log_path.is_file():
                lines = [ln for ln in log_path.read_text(encoding="utf-8", errors="replace").splitlines()
                         if ln.strip()]
                for line in lines:
                    if "pass done" not in line:
                        continue
                    stamp = parse_iso(line.split()[0])
                    if stamp:
                        last_done = stamp.timestamp()
                if last_done is None and lines and "pass done" in lines[-1]:
                    # An older line format with no readable time: the file's own time.
                    last_done = log_path.stat().st_mtime
        except OSError:
            last_done = None
        if last_done is None:
            st = "warn"
            fact = f"{liked_with_video} liked with video; no finished pass recorded"
        else:
            age_h = max(0.0, (now - last_done) / 3600.0)
            if age_h > float(chk.get("tv_videos_fail_h", 96)):
                st = "fail"
            elif age_h > float(chk.get("tv_videos_warn_h", 36)):
                st = "warn"
            fact = f"{liked_with_video} liked with video; pass {age_fact(age_h * 3600)} ago"
        rows.append(make_row("tv videos", st, fact, host))

    # tv likes
    tv_storage = (cfg.get("tv_storage") or "").strip()
    if tv_storage:
        path = expand(tv_storage)
        st = "pass"
        if not path.is_file():
            st = "warn"
            fact = "missing"
        else:
            doc, err = read_json_file(path)
            if doc is None:
                st = "warn"
                fact = f"unreadable: {err}"
            else:
                merged = merge_share_including_host(share)
                n = sum(
                    1
                    for t in merged.values()
                    for s in t.get("signals") or []
                    if s.get("source") == "tv" and s.get("kind") == "like"
                )
                fact = f"{n} music likes"
        rows.append(make_row("tv likes", st, fact, host))

    tv_channel_path_s = (cfg.get("tv_channel_scores") or "").strip()
    if tv_channel_path_s:
        path = expand(tv_channel_path_s)
        st = "pass"
        fact = ""
        warn_h = float(chk.get("tv_channel_warn_h", 36))
        fail_h = float(chk.get("tv_channel_fail_h", 96))
        if not path.is_file():
            st = "warn"
            fact = "missing"
        else:
            doc, err = read_json_file(path)
            if doc is None:
                st = "warn"
                fact = f"unreadable: {err}"
            else:
                try:
                    age_h = (now - path.stat().st_mtime) / 3600.0
                except OSError:
                    age_h = 0
                parts: List[str] = []
                all_zero = True
                for station in sorted((doc.get("channels") or {}).keys()):
                    ch = (doc.get("channels") or {}).get(station) or {}
                    items = ch.get("items") or {}
                    n = len(items) if isinstance(items, dict) else 0
                    if n:
                        all_zero = False
                    parts.append(f"{station} {n}")
                fact = ", ".join(parts) if parts else "no stations"
                if age_h > fail_h:
                    st = "fail"
                    fact = f"{fact}; stale {age_fact(age_h * 3600)}"
                elif age_h > warn_h:
                    st = "warn"
                    fact = f"{fact}; age {age_fact(age_h * 3600)}"
                elif all_zero and parts:
                    st = "warn"
        rows.append(make_row("tv channel", st, fact, host))

    # `check.rows` names the rows this Mac answers for; the default is every row whose input
    # exists here. (A Mac can hold a leftover file that belongs to another Mac's job.)
    wanted = chk.get("rows") or None
    if wanted:
        rows = [r for r in rows if r.get("name") in wanted]
    local_rows = list(rows)
    peer_stale_h = float(chk.get("peer_stale_h", 50))
    if share.is_dir():
        for path in sorted(share.glob("check-*.json")):
            peer_host = path.stem.replace("check-", "", 1)
            if peer_host == host:
                continue
            try:
                age_h = (now - path.stat().st_mtime) / 3600.0
            except OSError:
                age_h = peer_stale_h + 1
            if age_h > peer_stale_h:
                stale_date = datetime.fromtimestamp(path.stat().st_mtime, tz=timezone.utc).strftime(
                    "%Y-%m-%d"
                )
                rows.append(
                    make_row(
                        f"{peer_host} check",
                        "warn",
                        f"stale since {stale_date}",
                        peer_host,
                    )
                )
                continue
            doc, err = read_json_file(path)
            if doc is None:
                rows.append(
                    make_row(f"{peer_host} check", "warn", f"unreadable: {err}", peer_host)
                )
                continue
            for pr in doc.get("rows") or []:
                if isinstance(pr, dict):
                    # Say whose row it is: two Macs both have a `ledger` row.
                    named = dict(pr)
                    named["name"] = f"{peer_host} {pr.get('name') or 'check'}"
                    named["key"] = f"media:{peer_host}:{pr.get('name') or 'check'}"
                    named["host"] = peer_host
                    rows.append(named)

    summary = summarise_check(rows)
    doc_out = {
        "version": 1,
        "host": host,
        "generated": now_epoch(),
        "status": summary["status"],
        "value": summary["value"],
        "datum": summary["datum"],
        "detail": summary["detail"],
        "counts": summary["counts"],
        "rows": rows,
    }
    share_out = {
        **doc_out,
        "rows": local_rows,
    }
    try:
        atomic_write_json(state_dir / "check.json", doc_out)
        atomic_write_json(share / f"check-{host}.json", share_out)
    except OSError:
        pass

    for row in local_rows:
        print_check_line(row)
    for row in rows:
        if row not in local_rows:
            print_check_line(row)

    if args.json:
        print(json.dumps(doc_out, indent=2))
    if args.strict and summary["status"] == "fail":
        return 1
    return 0


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Media signal sync and checks")
    parser.add_argument("--config", type=Path, default=None, help="Config JSON path")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_collect = sub.add_parser("collect", help="Collect local sources into shared signals file")
    p_collect.set_defaults(func=lambda a, c: cmd_collect(c))

    p_show = sub.add_parser("show", help="Show merged track view")
    p_show.add_argument("--key", default=None)
    p_show.add_argument("--since", type=float, default=None)
    p_show.add_argument("--kind", choices=("shazam", "like", "dislike"), default=None)
    p_show.set_defaults(func=lambda a, c: cmd_show(c, a))

    p_export = sub.add_parser("export-likes", help="Export liked tracks for TV video finder")
    p_export.add_argument("--out", required=True)
    p_export.add_argument("--picks", type=int, default=0)
    p_export.add_argument("--force", action="store_true")
    p_export.set_defaults(func=lambda a, c: cmd_export_likes(c, a))

    p_tv = sub.add_parser("tv-scores", help="Build TV channel score file from picks and videos")
    p_tv.add_argument("--out", default=None)
    p_tv.add_argument("--force", action="store_true")
    p_tv.set_defaults(func=lambda a, c: cmd_tv_scores(c, a))

    p_check = sub.add_parser("check", help="Health checks for music pipeline")
    p_check.add_argument("--json", action="store_true")
    p_check.add_argument("--strict", action="store_true")
    p_check.set_defaults(func=lambda a, c: cmd_check(c, a))

    args = parser.parse_args(argv)
    cfg = load_config(args.config)
    return int(args.func(args, cfg))


if __name__ == "__main__":
    raise SystemExit(main())