#!/usr/bin/env python3
"""Glancebar OtR Connector: serves the local lossless library and Glancebar remote API.

Exposes the OtR Home Server endpoints (/api/login, /api/home, /api/queue,
/api/audio/<sha>, /api/art/<sha>, /api/event) alongside Glancebar Remote
endpoints (/api/glancebar/now, /api/glancebar/cmd) using only Python 3 stdlib.
"""
from __future__ import annotations

import argparse
import hashlib
import hmac
import http.cookies
import http.server
import json
import mimetypes
import os
import re
import secrets
import socketserver
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple

AUDIO_EXTS = {".m4a", ".mp3", ".flac", ".wav", ".aac", ".alac", ".ogg"}

AUDIO_MIME = {
    ".m4a": "audio/mp4",
    ".mp4": "audio/mp4",
    ".m4b": "audio/mp4",
    ".alac": "audio/mp4",
    ".mp3": "audio/mpeg",
    ".flac": "audio/flac",
    ".wav": "audio/wav",
    ".aac": "audio/aac",
    ".ogg": "audio/ogg",
    ".oga": "audio/ogg",
}

IMAGE_MIME = {
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".png": "image/png",
}

KIND_STATIONS = [
    ("dance", "Dance", "#e11d48"),
    ("alt", "Alt", "#6366f1"),
    ("rap", "Rap", "#f59e0b"),
    ("chill", "Chill", "#0ea5e9"),
    ("new", "New music", "#10b981"),
    ("all", "All Lossless", "#475569"),
]

PALETTE = [
    "#e11d48",
    "#6366f1",
    "#f59e0b",
    "#0ea5e9",
    "#10b981",
    "#8b5cf6",
    "#ec4899",
    "#14b8a6",
]

DIRECT_KINDS = {
    "dance": "dance",
    "alt": "alt",
    "rap": "rap",
    "chill": "chill",
    "any": "any",
    "new": "new",
    "show": "show",
    "focus": "chill",
    "energise": "dance",
    "workout": "dance",
    "party": "dance",
}

MOOD_ALIASES = {
    "dance": "dance",
    "energise": "dance",
    "energize": "dance",
    "workout": "dance",
    "party": "dance",
    "alt": "alt",
    "alternative": "alt",
    "drive": "alt",
    "heavy": "alt",
    "rock": "alt",
    "indie": "alt",
    "rap": "rap",
    "hiphop": "rap",
    "hip-hop": "rap",
    "hip hop": "rap",
    "chill": "chill",
    "focus": "chill",
    "ambient": "chill",
    "calm": "chill",
    "new": "new",
    "new music": "new",
    "new-music": "new",
    "triplej": "new",
    "all": "all",
    "all lossless": "all",
    "all-lossless": "all",
    "any": "all",
}

GLANCEBAR_BIN = Path("/Applications/Glancebar.app/Contents/MacOS/Glancebar")
VALID_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
VALID_MOOD_RE = re.compile(r"^[a-zA-Z0-9:_-]+$")
FILENAME_ID_RE = re.compile(r"\s*\[[A-Za-z0-9_-]{6,}\]$")
TRACK_NUM_RE = re.compile(r"^\d{1,3}\.\s+")
ALLOWED_CMDS = {"play", "pause", "toggle", "next", "prev", "like", "dislike"}


def now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def norm_key(artist: Optional[str], title: Optional[str]) -> Optional[str]:
    """Match Glancebar SelectorTrackKey / radio_sync.track_key normalization."""
    def _clean(val: Optional[str]) -> str:
        s = (val or "").replace("\u00a0", " ").lower()
        out: List[str] = []
        word: List[str] = []
        for ch in s:
            if ch.isalnum() or ch == "_":
                word.append(ch)
            elif word:
                out.append("".join(word))
                word = []
        if word:
            out.append("".join(word))
        return " ".join(out)

    a, t = _clean(artist), _clean(title)
    return f"{a}|{t}" if a and t else None


def _load_json(path: Path, default: Any) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return default


def _fallback_from_filename(fname: Optional[str]) -> Tuple[Optional[str], Optional[str]]:
    stem = os.path.splitext(os.path.basename(fname or ""))[0]
    stem = FILENAME_ID_RE.sub("", stem)
    stem = TRACK_NUM_RE.sub("", stem)
    if " - " in stem:
        artist, title = stem.split(" - ", 1)
        return artist.strip() or None, title.strip() or None
    return None, stem.strip() or None


def is_hearted(artist: Optional[str], title: Optional[str], hearts_path: Path) -> bool:
    if not artist or not title or not hearts_path.is_file():
        return False
    try:
        doc = json.loads(hearts_path.read_text(encoding="utf-8"))
        rows = doc.get("tracks") if isinstance(doc, dict) else (doc if isinstance(doc, list) else [])
        want = norm_key(artist, title)
        return any(isinstance(k, str) and k.lower().strip() == want for k in (rows or []))
    except (OSError, ValueError):
        return False


def current_playback(playlog_path: Path) -> Optional[Dict[str, Any]]:
    """Auto-advance fold matching tools/music-remote/music-remote.py."""
    try:
        size = os.path.getsize(playlog_path)
        window = 262144
        with open(playlog_path, "rb") as fh:
            if size > window:
                fh.seek(size - window)
            raw = fh.read().decode(errors="ignore").splitlines()
            lines = raw[1:] if size > window else raw
    except OSError:
        return None
    state: Optional[str] = None
    title: Optional[str] = None
    artist: Optional[str] = None
    cur_file: Optional[str] = None
    epoch = 0.0
    for line in lines:
        try:
            d = json.loads(line)
        except ValueError:
            continue
        if not isinstance(d, dict) or d.get("silentQA"):
            continue
        ev = d.get("event")
        if isinstance(d.get("epoch"), (int, float)):
            epoch = float(d["epoch"])
        if ev == "launch":
            state = title = artist = cur_file = None
        elif ev == "track":
            cur_file = d.get("file") or cur_file
            t = (d.get("title") or "").strip()
            a = (d.get("artist") or "").strip()
            if not t and d.get("file"):
                fb_a, fb_t = _fallback_from_filename(d["file"])
                t = fb_t or ""
                a = a or (fb_a or "")
            title = t or None
            artist = a or None
        elif ev == "meta":
            ev_file = d.get("file")
            if not ev_file or not cur_file or ev_file == cur_file:
                if (d.get("title") or "").strip():
                    title = d["title"].strip()
                if (d.get("artist") or "").strip():
                    artist = d["artist"].strip()
        elif ev == "rate":
            if d.get("state"):
                state = d["state"]
            ev_file = d.get("file")
            if not ev_file or not cur_file or ev_file == cur_file:
                if (d.get("title") or "").strip():
                    title = d["title"].strip()
                if (d.get("artist") or "").strip():
                    artist = d["artist"].strip()
                if ev_file and not cur_file:
                    cur_file = ev_file
    if not state and not title:
        return None
    return {
        "state": state,
        "title": title,
        "artist": artist,
        "file": cur_file,
        "epoch": epoch,
    }


def read_now_state(playlog_path: Path, hearts_path: Path) -> Dict[str, Any]:
    cur = current_playback(playlog_path)
    if not cur:
        return {
            "state": "stopped",
            "title": None,
            "artist": None,
            "liked": False,
            "host": "Mac",
            "epoch": 0.0,
        }
    raw_state = (cur.get("state") or "").lower()
    if raw_state in ("playing", "waiting"):
        state = "playing"
    elif raw_state == "paused":
        state = "paused"
    else:
        state = "stopped"
    title = cur.get("title")
    artist = cur.get("artist")
    return {
        "state": state,
        "title": title,
        "artist": artist,
        "liked": is_hearted(artist, title, hearts_path),
        "host": "Mac",
        "epoch": float(cur.get("epoch") or 0.0),
    }


def default_command_runner(args: List[str], fallback_cmd: str) -> None:
    if GLANCEBAR_BIN.is_file():
        res = subprocess.run([str(GLANCEBAR_BIN), *args], capture_output=True, timeout=10)
        if res.returncode == 0:
            return
    js = (
        'ObjC.import("Foundation");'
        "var d=$.NSDictionary.dictionaryWithObjectForKey($(%s), $('command'));"
        "$.NSDistributedNotificationCenter.defaultCenter."
        "postNotificationNameObjectUserInfoDeliverImmediately("
        "$('com.iantodd.glancebar.control'), $('uid:%d'), d, true);"
    ) % (json.dumps(fallback_cmd), os.getuid())
    subprocess.run(["osascript", "-l", "JavaScript", "-e", js], capture_output=True, timeout=15)


def load_or_create_passphrase(
    cli_pass: Optional[str],
    pass_file: Optional[Path],
    state_dir: Path,
) -> str:
    if cli_pass:
        return cli_pass
    env_pass = os.environ.get("OTR_CONNECTOR_PASS")
    if env_pass:
        return env_pass
    target = pass_file if pass_file is not None else (state_dir / "passphrase")
    if target.is_file():
        try:
            existing = target.read_text(encoding="utf-8").strip()
            if existing:
                return existing
        except OSError:
            pass
    target.parent.mkdir(parents=True, exist_ok=True)
    generated = secrets.token_urlsafe(18)
    fd = os.open(str(target), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(fd, (generated + "\n").encode("utf-8"))
    finally:
        os.close(fd)
    try:
        os.chmod(str(target), 0o600)
    except OSError:
        pass
    return generated


def _track_color(kind: Optional[str], track_id: str) -> str:
    if kind:
        for k_id, _, color in KIND_STATIONS:
            if k_id == kind:
                return color
    idx = int(hashlib.sha256(track_id.encode("utf-8")).hexdigest()[:8], 16) % len(PALETTE)
    return PALETTE[idx]


def _resolve_art_path(
    mix_dir: Path,
    track_path: Path,
    track_id: str,
    sha256: str,
) -> Optional[Path]:
    art_dir = mix_dir / "art"
    if art_dir.is_dir():
        candidates: List[str] = []
        for token in (sha256, track_id):
            if token:
                candidates.extend([token, token.lower(), token.upper()])
        seen_names = set()
        for tok in candidates:
            for ext in (".jpg", ".png", ".jpeg"):
                name = f"{tok}{ext}"
                if name in seen_names:
                    continue
                seen_names.add(name)
                cand = art_dir / name
                if cand.is_file():
                    return cand
    parent = track_path.parent
    if parent.is_dir():
        for name in ("cover.jpg", "cover.jpeg", "cover.png", "folder.jpg", "folder.png"):
            cand = parent / name
            if cand.is_file():
                return cand
    return None


class TrackRecord:
    __slots__ = (
        "s",
        "raw_id",
        "sha256",
        "title",
        "artist",
        "album",
        "year",
        "genre",
        "fav",
        "dislike",
        "dur",
        "kind",
        "kind_score",
        "next_links",
        "x",
        "yy",
        "is_new",
        "plays",
        "color",
        "path",
        "art_path",
        "tkey",
    )

    def __init__(
        self,
        *,
        s: str,
        raw_id: str,
        sha256: str,
        title: str,
        artist: str,
        album: str,
        year: Optional[int],
        genre: Optional[str],
        fav: bool,
        dislike: bool,
        dur: Optional[float],
        kind: Optional[str],
        kind_score: Optional[float],
        next_links: List[Tuple[str, float]],
        x: Optional[float],
        yy: Optional[float],
        is_new: bool,
        plays: int,
        color: str,
        path: Path,
        art_path: Optional[Path],
    ) -> None:
        self.s = s
        self.raw_id = raw_id
        self.sha256 = sha256
        self.title = title
        self.artist = artist
        self.album = album
        self.year = year
        self.genre = genre
        self.fav = fav
        self.dislike = dislike
        self.dur = dur
        self.kind = kind
        self.kind_score = kind_score
        self.next_links = next_links
        self.x = x
        self.yy = yy
        self.is_new = is_new
        self.plays = plays
        self.color = color
        self.path = path
        self.art_path = art_path
        self.tkey = norm_key(artist, title) or ""


class LibraryIndex:
    """Indexes Glancebar's mix metadata and lossless audio files without exposing local paths."""

    def __init__(self, mix_dir: Path, hot_dir: Path) -> None:
        self.mix_dir = mix_dir
        self.hot_dir = hot_dir
        self.lock = threading.RLock()
        self.tracks: List[TrackRecord] = []
        self.by_id: Dict[str, TrackRecord] = {}
        self.aliases: Dict[str, TrackRecord] = {}
        self.kind_neighbours: Dict[str, List[str]] = {}
        self.taste_weights: Dict[str, float] = {}
        self.liked_keys: set = set()
        self.disliked_keys: set = set()
        self.reload()

    def reload(self) -> None:
        lib_doc = _load_json(self.mix_dir / "library.json", {})
        lib_rows = lib_doc.get("tracks") if isinstance(lib_doc, dict) else []
        lib_by_id: Dict[str, Dict[str, Any]] = {}
        lib_by_key: Dict[str, Dict[str, Any]] = {}
        for row in lib_rows or []:
            if not isinstance(row, dict):
                continue
            rid = str(row.get("id") or "").strip()
            if rid:
                lib_by_id[rid] = row
            tkey = norm_key(row.get("artist"), row.get("title"))
            if tkey:
                lib_by_key[tkey] = row

        space_doc = _load_json(self.mix_dir / "music-space.json", {})
        space_tracks = space_doc.get("tracks") if isinstance(space_doc, dict) else {}
        if not isinstance(space_tracks, dict):
            space_tracks = {}
        raw_kn = space_doc.get("kindNeighbours") if isinstance(space_doc, dict) else {}
        kind_neighbours: Dict[str, List[str]] = {}
        if isinstance(raw_kn, dict):
            for k, v in raw_kn.items():
                if isinstance(k, str) and isinstance(v, list):
                    kind_neighbours[k.lower()] = [str(item).lower() for item in v if isinstance(item, str)]

        liked_keys: set = set()
        disliked_keys: set = set()
        taste_weights: Dict[str, float] = {}
        fb_path = self.mix_dir / "feedback.jsonl"
        if fb_path.is_file():
            try:
                for raw_line in fb_path.read_text(encoding="utf-8", errors="ignore").splitlines():
                    if not raw_line.strip():
                        continue
                    try:
                        obj = json.loads(raw_line)
                    except ValueError:
                        continue
                    if not isinstance(obj, dict):
                        continue
                    self._fold_feedback_obj(obj, liked_keys, disliked_keys, taste_weights)
            except OSError:
                pass

        manifest_doc = _load_json(self.mix_dir / "offline-manifest.json", {})
        playlists = manifest_doc.get("playlists") if isinstance(manifest_doc, dict) else []

        records: List[TrackRecord] = []
        by_id: Dict[str, TrackRecord] = {}
        aliases: Dict[str, TrackRecord] = {}
        seen_paths: set = set()

        def _add_record(
            *,
            s: str,
            raw_id: str,
            sha256: str,
            title: str,
            artist: str,
            album: str,
            fpath: Path,
            is_new: bool,
            fallback_kind: Optional[str],
            dur_hint: Optional[float] = None,
        ) -> Optional[TrackRecord]:
            resolved_str = str(fpath.resolve())
            if resolved_str in seen_paths or not fpath.is_file():
                return None
            seen_paths.add(resolved_str)
            tkey = norm_key(artist, title) or ""
            lib = lib_by_id.get(raw_id) or (lib_by_key.get(tkey) if tkey else None) or {}
            space_key = raw_id or str(lib.get("id") or "")
            sp = space_tracks.get(space_key) or space_tracks.get(s) or {}
            if not isinstance(sp, dict):
                sp = {}
            year_val = lib.get("year")
            year = int(year_val) if isinstance(year_val, (int, float)) and year_val else None
            genre = str(lib.get("genre") or "").strip() or None
            fav = bool(lib.get("fav"))
            dislike = bool(lib.get("dislike"))
            plays_val = lib.get("plays")
            plays = int(plays_val) if isinstance(plays_val, (int, float)) else 0
            kind = str(sp.get("kind") or fallback_kind or "").strip().lower() or None
            if not kind and genre:
                kind = self._infer_kind_from_genre(genre)
            ks_raw = sp.get("kindScore")
            kind_score = float(ks_raw) if isinstance(ks_raw, (int, float)) else None
            next_links: List[Tuple[str, float]] = []
            for item in sp.get("next") or []:
                if isinstance(item, (list, tuple)) and len(item) >= 2:
                    nid = str(item[0])
                    try:
                        sim = float(item[1])
                    except (TypeError, ValueError):
                        continue
                    next_links.append((nid, sim))
            x_val = sp.get("x")
            y_val = sp.get("y") if "y" in sp else sp.get("yy")
            x_num = float(x_val) if isinstance(x_val, (int, float)) else None
            y_num = float(y_val) if isinstance(y_val, (int, float)) else None
            dur_raw = dur_hint if dur_hint is not None else lib.get("duration")
            dur = float(dur_raw) if isinstance(dur_raw, (int, float)) and dur_raw > 0 else None
            art_path = _resolve_art_path(self.mix_dir, fpath, raw_id or s, sha256)
            color = _track_color(kind, s)

            rec = TrackRecord(
                s=s,
                raw_id=raw_id or str(lib.get("id") or ""),
                sha256=sha256,
                title=title or fpath.stem,
                artist=artist or "Unknown Artist",
                album=album or str(lib.get("album") or ""),
                year=year,
                genre=genre,
                fav=fav,
                dislike=dislike,
                dur=dur,
                kind=kind,
                kind_score=kind_score,
                next_links=next_links,
                x=x_num,
                yy=y_num,
                is_new=is_new,
                plays=plays,
                color=color,
                path=fpath,
                art_path=art_path,
            )
            records.append(rec)
            by_id[s] = rec
            aliases[s] = rec
            aliases[s.lower()] = rec
            if raw_id:
                aliases.setdefault(raw_id, rec)
                aliases.setdefault(raw_id.lower(), rec)
            if sha256:
                aliases.setdefault(sha256, rec)
                aliases.setdefault(sha256[:16], rec)
            return rec

        for pl in playlists or []:
            if not isinstance(pl, dict):
                continue
            pl_key = str(pl.get("key") or "")
            pl_lower = pl_key.lower()
            is_new_pl = pl_lower in ("station:triplej", "new-music") or "new" in pl_lower
            fb_kind = pl_lower.split(":", 1)[1] if pl_lower.startswith("kind:") else None
            for t in pl.get("tracks") or []:
                if not isinstance(t, dict):
                    continue
                path_str = str(t.get("path") or "").strip()
                if not path_str:
                    continue
                fpath = Path(path_str)
                if not fpath.is_file():
                    continue
                raw_id = str(t.get("id") or "").strip()
                sha256 = str(t.get("sha256") or "").strip().lower()
                if raw_id and VALID_ID_RE.match(raw_id):
                    s = raw_id
                elif sha256 and len(sha256) >= 16:
                    s = sha256[:16]
                else:
                    try:
                        rel = fpath.resolve().relative_to(self.hot_dir.resolve()).as_posix()
                    except ValueError:
                        rel = fpath.name
                    s = hashlib.sha256(rel.encode("utf-8")).hexdigest()[:16]
                if s in by_id:
                    if is_new_pl:
                        by_id[s].is_new = True
                    continue
                _add_record(
                    s=s,
                    raw_id=raw_id,
                    sha256=sha256,
                    title=str(t.get("title") or "").strip(),
                    artist=str(t.get("artist") or "").strip(),
                    album=str(t.get("album") or "").strip(),
                    fpath=fpath,
                    is_new=is_new_pl,
                    fallback_kind=fb_kind,
                    dur_hint=t.get("duration") if isinstance(t.get("duration"), (int, float)) else None,
                )

        if self.hot_dir.is_dir():
            hot_resolved = self.hot_dir.resolve()
            for root, dirs, files in os.walk(hot_resolved):
                dirs[:] = sorted(d for d in dirs if not d.startswith("."))
                for fname in sorted(files):
                    if fname.startswith("."):
                        continue
                    fpath = Path(root) / fname
                    if fpath.suffix.lower() not in AUDIO_EXTS:
                        continue
                    if str(fpath.resolve()) in seen_paths:
                        continue
                    rel_path = fpath.resolve().relative_to(hot_resolved).as_posix()
                    s = hashlib.sha256(rel_path.encode("utf-8")).hexdigest()[:16]
                    while s in by_id:
                        s = hashlib.sha256((s + rel_path).encode("utf-8")).hexdigest()[:16]
                    artist, title, album = self._infer_meta_from_rel(rel_path, fpath.name)
                    _add_record(
                        s=s,
                        raw_id="",
                        sha256="",
                        title=title,
                        artist=artist,
                        album=album,
                        fpath=fpath,
                        is_new=False,
                        fallback_kind=None,
                    )

        with self.lock:
            self.tracks = records
            self.by_id = by_id
            self.aliases = aliases
            self.kind_neighbours = kind_neighbours
            self.taste_weights = taste_weights
            self.liked_keys = liked_keys
            self.disliked_keys = disliked_keys

    @staticmethod
    def _infer_kind_from_genre(genre: str) -> Optional[str]:
        g = genre.lower()
        if any(w in g for w in ("hip-hop", "hip hop", "rap", "trap")):
            return "rap"
        if any(w in g for w in ("dance", "electronic", "house", "techno", "edm", "club")):
            return "dance"
        if any(w in g for w in ("ambient", "chill", "classical", "jazz", "acoustic", "folk", "soul")):
            return "chill"
        if any(w in g for w in ("alt", "indie", "rock", "punk", "metal")):
            return "alt"
        return None

    @staticmethod
    def _infer_meta_from_rel(rel_path: str, fname: str) -> Tuple[str, str, str]:
        fb_artist, fb_title = _fallback_from_filename(fname)
        parts = Path(rel_path).parts
        artist = fb_artist or ""
        title = fb_title or Path(fname).stem
        album = ""
        if not artist:
            if len(parts) >= 3:
                artist = parts[-3]
                album = parts[-2]
            elif len(parts) == 2:
                artist = parts[-2]
        elif len(parts) >= 2 and not album:
            album = parts[-2] if parts[-2] != artist else ""
        return artist, title, album

    @staticmethod
    def _fold_feedback_obj(
        obj: Dict[str, Any],
        liked_keys: set,
        disliked_keys: set,
        taste_weights: Dict[str, float],
    ) -> None:
        tid = str(obj.get("trackID") or "").strip()
        tkey = str(obj.get("track_key") or "").strip()
        if not tkey and obj.get("artist") and obj.get("title"):
            tkey = norm_key(obj.get("artist"), obj.get("title")) or ""
        keys = [k for k in (tid, tkey) if k]
        ev = str(obj.get("event") or "").strip().lower()
        if not ev:
            if obj.get("liked") is True:
                ev = "like"
            elif obj.get("liked") is False:
                ev = "unlike"
        if ev == "like":
            for k in keys:
                liked_keys.add(k)
                disliked_keys.discard(k)
                taste_weights[k] = 1.0
        elif ev == "unlike":
            for k in keys:
                liked_keys.discard(k)
                taste_weights[k] = 0.0
        elif ev == "dislike":
            for k in keys:
                disliked_keys.add(k)
                liked_keys.discard(k)
                taste_weights[k] = -100.0
        elif ev == "undislike":
            for k in keys:
                disliked_keys.discard(k)
                taste_weights[k] = 0.0
        elif ev == "finish":
            for k in keys:
                taste_weights[k] = taste_weights.get(k, 0.0) + 0.25
        elif ev == "skip":
            for k in keys:
                taste_weights[k] = taste_weights.get(k, 0.0) - 0.4

    def record_event(self, track: Optional[TrackRecord], token_id: str, ev: str) -> None:
        with self.lock:
            obj: Dict[str, Any] = {"event": ev}
            if track is not None:
                obj["trackID"] = track.s
                obj["track_key"] = track.tkey
                obj["artist"] = track.artist
                obj["title"] = track.title
            else:
                obj["trackID"] = token_id
            self._fold_feedback_obj(obj, self.liked_keys, self.disliked_keys, self.taste_weights)

    def lookup(self, token: str) -> Optional[TrackRecord]:
        if not token or not VALID_ID_RE.match(token):
            return None
        with self.lock:
            return self.by_id.get(token) or self.aliases.get(token) or self.aliases.get(token.lower())

    def is_disliked(self, rec: TrackRecord) -> bool:
        if rec.s in self.disliked_keys or (rec.raw_id and rec.raw_id in self.disliked_keys):
            return True
        if rec.tkey and rec.tkey in self.disliked_keys:
            return True
        if rec.dislike and rec.s not in self.liked_keys and rec.tkey not in self.liked_keys:
            # Disliked in library.json unless explicitly undisliked/liked in feedback
            return True
        return False

    def is_liked(self, rec: TrackRecord, hearts_path: Optional[Path] = None) -> bool:
        if rec.s in self.liked_keys or (rec.raw_id and rec.raw_id in self.liked_keys):
            return True
        if rec.tkey and rec.tkey in self.liked_keys:
            return True
        if rec.fav:
            return True
        if hearts_path and is_hearted(rec.artist, rec.title, hearts_path):
            return True
        return False

    def station_counts(self, lenses: Optional[List[Dict[str, Any]]] = None) -> Dict[str, int]:
        with self.lock:
            eligible = [t for t in self.tracks if not self.is_disliked(t)]
            counts = {k_id: 0 for k_id, _, _ in KIND_STATIONS}
            counts["all"] = len(eligible)
            for t in eligible:
                if t.kind in ("dance", "alt", "rap", "chill"):
                    counts[t.kind] += 1
                if t.is_new or (t.year and t.year >= 2025):
                    counts["new"] += 1
            for lens in lenses or []:
                lid = str(lens.get("id") or "")
                if lid:
                    counts[lid] = sum(1 for t in eligible if self._lens_score(t, lens) > 0)
            return counts

    @staticmethod
    def _lens_score(rec: TrackRecord, lens: Dict[str, Any]) -> float:
        score = 0.0
        kinds = {str(x).lower() for x in (lens.get("kinds") or []) if isinstance(x, str)}
        genres = {str(x).lower() for x in (lens.get("genres") or []) if isinstance(x, str)}
        tags = {str(x).lower() for x in (lens.get("tags") or []) if isinstance(x, str)}
        if rec.kind and rec.kind in kinds:
            score += 2.0 * (rec.kind_score if rec.kind_score is not None else 0.7)
        if rec.genre:
            g = rec.genre.lower()
            if any(w in g for w in genres | tags):
                score += 1.2
        text_blob = f"{rec.artist} {rec.title} {rec.album}".lower()
        for kw in tags:
            if kw and kw in text_blob:
                score += 0.6
        return score

    def rank_queue(
        self,
        mood: str,
        n: int,
        lenses: Optional[List[Dict[str, Any]]] = None,
        hearts_path: Optional[Path] = None,
    ) -> List[Tuple[TrackRecord, str]]:
        raw = mood.strip()
        if raw.lower().startswith("station:"):
            raw = raw[8:]
        m = raw.lower()
        target_kind = MOOD_ALIASES.get(m, m)

        lens_meta: Optional[Dict[str, Any]] = None
        for lens in lenses or []:
            lid = str(lens.get("id") or "").lower()
            if lid in (m, f"station:{m}"):
                lens_meta = lens
                break

        with self.lock:
            eligible = [t for t in self.tracks if not self.is_disliked(t)]
            if not eligible:
                return []

            neighbours = self.kind_neighbours.get(target_kind, [])

            def _base_score(rec: TrackRecord) -> float:
                score = 0.0
                if lens_meta is not None:
                    score += self._lens_score(rec, lens_meta)
                elif target_kind == "all":
                    score += 0.5 + 0.4 * (rec.kind_score if rec.kind_score is not None else 0.5)
                elif target_kind == "new":
                    if rec.is_new:
                        score += 2.2
                    elif rec.year and rec.year >= 2024:
                        score += 1.0 + 0.1 * (rec.year - 2024)
                    else:
                        score += 0.2
                else:
                    ks = rec.kind_score if rec.kind_score is not None else 0.7
                    if rec.kind == target_kind:
                        score += 2.0 * ks + 0.5
                    elif rec.kind in neighbours:
                        idx = neighbours.index(rec.kind)
                        score += (0.8 / (idx + 1)) * ks
                    elif rec.genre and target_kind in rec.genre.lower():
                        score += 1.0
                    elif self._infer_kind_from_genre(rec.genre or "") == target_kind:
                        score += 0.9

                if rec.fav:
                    score += 0.6
                for key in (rec.s, rec.raw_id, rec.tkey):
                    if key and key in self.taste_weights:
                        score += self.taste_weights[key]
                        break
                if rec.art_path:
                    score += 0.05
                return score

            scored = {rec.s: _base_score(rec) for rec in eligible}
            pool = sorted(eligible, key=lambda r: (-scored[r.s], r.s))
            if not pool:
                return []

            chosen: List[Tuple[TrackRecord, str]] = []
            used = set()
            recent_artists: List[str] = []

            def _tag_for(rec: TrackRecord) -> str:
                parts: List[str] = []
                if lens_meta and lens_meta.get("name"):
                    parts.append(str(lens_meta["name"]))
                elif target_kind == "new" and rec.is_new:
                    parts.append("New music")
                elif rec.kind:
                    parts.append(rec.kind.capitalize())
                else:
                    parts.append("Lossless")
                if self.is_liked(rec, hearts_path):
                    parts.append("Favorite")
                elif rec.genre:
                    parts.append(rec.genre)
                return " · ".join(parts[:2])

            first = pool[0]
            chosen.append((first, _tag_for(first)))
            used.add(first.s)
            recent_artists.append(first.artist.lower())

            limit = max(1, min(n, len(pool)))
            while len(chosen) < limit:
                prev = chosen[-1][0]
                next_map = {nid: sim for nid, sim in prev.next_links}
                best_rec: Optional[TrackRecord] = None
                best_val = -1e9
                for cand in pool:
                    if cand.s in used:
                        continue
                    sim = next_map.get(cand.raw_id, next_map.get(cand.s, 0.0))
                    cand_artist = cand.artist.lower()
                    penalty = 0.0
                    if recent_artists and cand_artist == recent_artists[-1]:
                        penalty = 0.8
                    elif cand_artist in recent_artists[-3:]:
                        penalty = 0.3
                    val = 0.65 * scored[cand.s] + 0.35 * sim - penalty
                    if val > best_val:
                        best_val = val
                        best_rec = cand
                if best_rec is None:
                    break
                chosen.append((best_rec, _tag_for(best_rec)))
                used.add(best_rec.s)
                recent_artists.append(best_rec.artist.lower())

            return chosen


class OtrHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(
        self,
        server_address: Tuple[str, int],
        RequestHandlerClass: Any,
        *,
        server_name: str,
        passphrase: str,
        index: LibraryIndex,
        mix_dir: Path,
        playlog_path: Path,
        hearts_path: Path,
        manifold_hub: str,
        offline: bool,
        command_runner: Callable[[List[str], str], None],
    ) -> None:
        super().__init__(server_address, RequestHandlerClass)
        self.server_name = server_name
        self.passphrase = passphrase
        self.index = index
        self.mix_dir = mix_dir
        self.playlog_path = playlog_path
        self.hearts_path = hearts_path
        self.manifold_hub = manifold_hub.rstrip("/")
        self.offline = offline
        self.command_runner = command_runner

        self.auth_lock = threading.Lock()
        self.sessions: Dict[str, Dict[str, Any]] = {}
        self.pick_lock = threading.Lock()
        self.pick_tokens: Dict[str, Dict[str, Any]] = {}
        self.feedback_lock = threading.Lock()
        self.lens_lock = threading.Lock()
        self._lenses_cache: List[Dict[str, Any]] = []
        self._lenses_fetched_at: float = 0.0

    def get_lenses(self) -> List[Dict[str, Any]]:
        if self.offline or not self.manifold_hub:
            return []
        now = time.time()
        with self.lens_lock:
            if self._lenses_fetched_at and (now - self._lenses_fetched_at) < 900.0:
                return list(self._lenses_cache)
        url = f"{self.manifold_hub}/api/v1/lenses?domain=radio"
        fetched: List[Dict[str, Any]] = []
        try:
            req = urllib.request.Request(
                url,
                headers={"Accept": "application/json", "User-Agent": "glancebar-otr-connector/1.0"},
            )
            with urllib.request.urlopen(req, timeout=3) as resp:
                raw = json.loads(resp.read().decode("utf-8", errors="replace") or "null")
            items = raw.get("lenses") if isinstance(raw, dict) else (raw if isinstance(raw, list) else [])
            for item in items or []:
                if not isinstance(item, dict):
                    continue
                lid = str(item.get("id") or item.get("slug") or "").strip()
                lname = str(item.get("name") or item.get("title") or lid).strip()
                if not lid or not lname:
                    continue
                fetched.append(
                    {
                        "id": lid,
                        "name": lname,
                        "color": str(item.get("color") or "#6366f1"),
                        "kinds": item.get("kinds") or [],
                        "genres": item.get("genres") or [],
                        "tags": item.get("tags") or [],
                    }
                )
        except Exception:
            fetched = []
        with self.lens_lock:
            if fetched or not self._lenses_fetched_at:
                self._lenses_cache = fetched
            self._lenses_fetched_at = now
            return list(self._lenses_cache)


def _parse_range_header(header_val: str, total: int) -> Optional[Tuple[int, int]]:
    if not header_val:
        return None
    m = re.match(r"^\s*bytes\s*=\s*(\d*)\s*-\s*(\d*)\s*$", header_val, re.IGNORECASE)
    if not m:
        return (-1, -1)
    start_s, end_s = m.group(1), m.group(2)
    if not start_s and not end_s:
        return (-1, -1)
    if total <= 0:
        return (-1, -1)
    if not start_s:
        suffix = int(end_s)
        if suffix <= 0:
            return (-1, -1)
        start = max(0, total - suffix)
        end = total - 1
        return (start, end)
    start = int(start_s)
    end = int(end_s) if end_s else (total - 1)
    if start >= total or start > end:
        return (-1, -1)
    end = min(end, total - 1)
    return (start, end)


class OtrHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server: OtrHTTPServer

    def log_message(self, format: str, *args: Any) -> None:
        return

    def _send_json(
        self,
        status: int,
        payload: Any,
        extra_headers: Optional[List[Tuple[str, str]]] = None,
        head_only: bool = False,
    ) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        if extra_headers:
            for k, v in extra_headers:
                self.send_header(k, v)
        self.end_headers()
        if not head_only:
            self.wfile.write(body)

    def _read_json_body(self) -> Optional[Dict[str, Any]]:
        try:
            length = int(self.headers.get("Content-Length") or "0")
        except ValueError:
            return None
        if length <= 0 or length > 1048576:
            return {} if length == 0 else None
        raw = self.rfile.read(length)
        try:
            parsed = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            return None
        return parsed if isinstance(parsed, dict) else None

    def _is_authorized(self) -> bool:
        auth = self.headers.get("Authorization") or ""
        if auth.lower().startswith("bearer "):
            token = auth[7:].strip()
            if token and hmac.compare_digest(token, self.server.passphrase):
                return True
        cookie_hdr = self.headers.get("Cookie") or ""
        if cookie_hdr:
            jar: http.cookies.SimpleCookie = http.cookies.SimpleCookie()
            try:
                jar.load(cookie_hdr)
            except http.cookies.CookieError:
                return False
            morsel = jar.get("otr_session")
            if morsel is not None:
                sess_tok = morsel.value
                with self.server.auth_lock:
                    if sess_tok in self.server.sessions:
                        return True
        return False

    def _require_auth(self) -> bool:
        if self._is_authorized():
            return True
        self._send_json(401, {"error": "unauthorized"}, head_only=(self.command == "HEAD"))
        return False

    def _path_only(self) -> str:
        return urllib.parse.urlsplit(self.path).path

    def do_HEAD(self) -> None:
        self._dispatch(head_only=True)

    def do_GET(self) -> None:
        self._dispatch(head_only=False)

    def do_POST(self) -> None:
        path = self._path_only()
        if path == "/api/login":
            self._handle_login()
            return
        if not self._require_auth():
            return
        if path == "/api/queue":
            self._handle_queue()
        elif path == "/api/event":
            self._handle_event()
        elif path == "/api/glancebar/cmd":
            self._handle_glancebar_cmd()
        else:
            self._send_json(404, {"error": "not_found"})

    def _dispatch(self, head_only: bool) -> None:
        path = self._path_only()
        if not self._require_auth():
            return
        if path == "/api/home" and not head_only:
            self._handle_home()
        elif path == "/api/glancebar/now" and not head_only:
            now_doc = read_now_state(self.server.playlog_path, self.server.hearts_path)
            self._send_json(200, now_doc)
        elif path.startswith("/api/audio/"):
            sha = urllib.parse.unquote(path[len("/api/audio/"):])
            self._handle_audio(sha, head_only=head_only)
        elif path.startswith("/api/art/"):
            sha = urllib.parse.unquote(path[len("/api/art/"):])
            self._handle_art(sha, head_only=head_only)
        else:
            self._send_json(404, {"error": "not_found"}, head_only=head_only)

    def _handle_login(self) -> None:
        body = self._read_json_body()
        if not body or not isinstance(body.get("pass"), str):
            self._send_json(401, {"error": "unauthorized"})
            return
        if not hmac.compare_digest(body["pass"], self.server.passphrase):
            self._send_json(401, {"error": "unauthorized"})
            return
        token = secrets.token_urlsafe(32)
        client_name = str(body.get("name") or "OtR Client")
        with self.server.auth_lock:
            self.server.sessions[token] = {"name": client_name, "created": time.time()}
        cookie = f"otr_session={token}; Path=/; HttpOnly; SameSite=Lax"
        self._send_json(
            200,
            {"name": self.server.server_name, "capabilities": ["library", "glancebar-remote"]},
            extra_headers=[("Set-Cookie", cookie)],
        )

    def _handle_home(self) -> None:
        lenses = self.server.get_lenses()
        counts = self.server.index.station_counts(lenses)
        with self.server.index.lock:
            eligible = [t for t in self.server.index.tracks if not self.server.index.is_disliked(t)]
            eligible.sort(
                key=lambda t: (
                    not self.server.index.is_liked(t, self.server.hearts_path),
                    t.art_path is None,
                    -(t.kind_score or 0.0),
                    -t.plays,
                    t.s,
                )
            )
            song_tiles = []
            for t in eligible[:18]:
                sub = f"{t.artist} · {t.album}" if t.album else t.artist
                song_tiles.append(
                    {
                        "kind": "song",
                        "s": t.s,
                        "title": t.title,
                        "sub": sub,
                        "artist": t.artist,
                        "art": f"/api/art/{t.s}" if t.art_path else None,
                        "color": t.color,
                    }
                )

        station_tiles = []
        for sid, sname, scolor in KIND_STATIONS:
            cnt = counts.get(sid, 0)
            station_tiles.append(
                {
                    "kind": "station",
                    "title": sname,
                    "sub": f"{cnt} track" if cnt == 1 else f"{cnt} tracks",
                    "color": scolor,
                    "station": {
                        "id": sid,
                        "name": sname,
                        "color": scolor,
                        "count": cnt,
                    },
                }
            )
        for lens in lenses:
            lid = lens["id"]
            lname = lens["name"]
            lcolor = lens.get("color") or "#6366f1"
            cnt = counts.get(lid, 0)
            station_tiles.append(
                {
                    "kind": "station",
                    "title": lname,
                    "sub": f"{cnt} track" if cnt == 1 else f"{cnt} tracks",
                    "color": lcolor,
                    "station": {
                        "id": lid,
                        "name": lname,
                        "color": lcolor,
                        "count": cnt,
                    },
                }
            )

        self._send_json(
            200,
            {
                "shelves": [
                    {"id": "library", "title": "Glancebar Lossless", "tiles": song_tiles},
                    {"id": "stations", "title": "Stations", "tiles": station_tiles},
                ]
            },
        )

    def _handle_queue(self) -> None:
        body = self._read_json_body()
        if body is None:
            self._send_json(400, {"error": "invalid_json"})
            return
        mood = str(body.get("mood") or "all")
        raw_n = body.get("n", 18)
        try:
            n = max(1, min(200, int(raw_n)))
        except (TypeError, ValueError):
            n = 18

        lenses = self.server.get_lenses()
        ranked = self.server.index.rank_queue(mood, n, lenses=lenses, hearts_path=self.server.hearts_path)
        picks = []
        for rec, tag in ranked:
            pt = f"{secrets.token_hex(8)}.{rec.s}"
            with self.server.pick_lock:
                self.server.pick_tokens[pt] = {
                    "s": rec.s,
                    "artist": rec.artist,
                    "title": rec.title,
                    "dur": rec.dur,
                    "mood": mood,
                    "created": time.time(),
                }
            item: Dict[str, Any] = {
                "s": rec.s,
                "a": rec.artist,
                "t": rec.title,
                "al": rec.album,
                "y": rec.year,
                "g": rec.genre,
                "e": round(float(rec.kind_score if rec.kind_score is not None else 0.5), 3),
                "h": self.server.index.is_liked(rec, self.server.hearts_path),
                "tag": tag,
                "dur": rec.dur,
                "color": rec.color,
                "art": f"/api/art/{rec.s}" if rec.art_path else None,
                "pt": pt,
            }
            if rec.x is not None:
                item["x"] = rec.x
            if rec.yy is not None:
                item["yy"] = rec.yy
            picks.append(item)
        self._send_json(200, {"picks": picks})

    def _handle_audio(self, sha: str, *, head_only: bool) -> None:
        rec = self.server.index.lookup(sha)
        if rec is None or not rec.path.is_file():
            self._send_json(404, {"error": "not_found"}, head_only=head_only)
            return
        try:
            total = rec.path.stat().st_size
        except OSError:
            self._send_json(404, {"error": "not_found"}, head_only=head_only)
            return
        ext = rec.path.suffix.lower()
        ctype = AUDIO_MIME.get(ext) or mimetypes.guess_type(rec.path.name)[0] or "application/octet-stream"

        range_hdr = self.headers.get("Range")
        if range_hdr:
            parsed = _parse_range_header(range_hdr, total)
            if parsed == (-1, -1):
                self.send_response(416)
                self.send_header("Accept-Ranges", "bytes")
                self.send_header("Content-Range", f"bytes */{total}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            assert parsed is not None
            start, end = parsed
            length = end - start + 1
            self.send_response(206)
            self.send_header("Content-Type", ctype)
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Range", f"bytes {start}-{end}/{total}")
            self.send_header("Content-Length", str(length))
            self.end_headers()
        else:
            start, length = 0, total
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(total))
            self.end_headers()

        if head_only or length == 0:
            return
        try:
            with open(rec.path, "rb") as fh:
                fh.seek(start)
                remaining = length
                while remaining > 0:
                    chunk = fh.read(min(65536, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
        except (BrokenPipeError, ConnectionResetError):
            return

    def _handle_art(self, sha: str, *, head_only: bool) -> None:
        rec = self.server.index.lookup(sha)
        if rec is None or rec.art_path is None or not rec.art_path.is_file():
            self._send_json(404, {"error": "not_found"}, head_only=head_only)
            return
        try:
            data = rec.art_path.read_bytes()
        except OSError:
            self._send_json(404, {"error": "not_found"}, head_only=head_only)
            return
        ctype = IMAGE_MIME.get(rec.art_path.suffix.lower(), "image/jpeg")
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "public, max-age=3600")
        self.end_headers()
        if not head_only:
            self.wfile.write(data)

    def _handle_event(self) -> None:
        body = self._read_json_body()
        if not body or not isinstance(body.get("ev"), str) or not body["ev"].strip():
            self._send_json(400, {"error": "invalid_event"})
            return
        ev = body["ev"].strip().lower()
        pt = str(body.get("pt") or "").strip()
        pos_raw = body.get("pos")
        pos: Optional[float] = float(pos_raw) if isinstance(pos_raw, (int, float)) else None

        meta: Optional[Dict[str, Any]] = None
        if pt:
            with self.server.pick_lock:
                meta = self.server.pick_tokens.get(pt)
        rec: Optional[TrackRecord] = None
        if meta and meta.get("s"):
            rec = self.server.index.lookup(str(meta["s"]))
        elif pt and "." in pt:
            rec = self.server.index.lookup(pt.rsplit(".", 1)[-1])
        elif body.get("s"):
            rec = self.server.index.lookup(str(body["s"]))

        artist = (meta.get("artist") if meta else None) or (rec.artist if rec else "")
        title = (meta.get("title") if meta else None) or (rec.title if rec else "")
        track_id = (rec.s if rec else None) or (meta.get("s") if meta else None) or pt or ""
        tkey = norm_key(artist, title) or (rec.tkey if rec else "")

        record: Dict[str, Any] = {
            "at": now_iso(),
            "source": "otr",
            "event": ev,
            "trackID": track_id,
            "track_key": tkey,
            "artist": artist,
            "title": title,
            "pt": pt,
        }
        if ev == "like":
            record["liked"] = True
        elif ev in ("unlike", "dislike"):
            record["liked"] = False
        if pos is not None:
            record["pos"] = pos
            dur = (meta.get("dur") if meta else None) or (rec.dur if rec else None)
            if isinstance(dur, (int, float)) and dur > 0:
                record["playback"] = {
                    "position_seconds": pos,
                    "duration_seconds": float(dur),
                    "fraction": min(1.0, max(0.0, pos / float(dur))),
                }

        fb_path = self.server.mix_dir / "feedback.jsonl"
        with self.server.feedback_lock:
            fb_path.parent.mkdir(parents=True, exist_ok=True)
            with open(fb_path, "a", encoding="utf-8") as fh:
                fh.write(json.dumps(record, sort_keys=True, ensure_ascii=False) + "\n")

        self.server.index.record_event(rec, track_id, ev)
        self._send_json(200, {"ok": True})

    def _handle_glancebar_cmd(self) -> None:
        body = self._read_json_body()
        if not body or not isinstance(body.get("cmd"), str):
            self._send_json(400, {"error": "invalid_cmd"})
            return
        cmd = body["cmd"].strip()
        args: Optional[List[str]] = None
        fallback: Optional[str] = None

        if cmd in ALLOWED_CMDS:
            action = cmd
            if cmd == "toggle":
                cur_now = read_now_state(self.server.playlog_path, self.server.hearts_path)
                action = "pause" if cur_now["state"] == "playing" else "play"
            args = [f"--{action}"]
            fallback = action
        elif cmd.startswith("mood:"):
            kind = cmd[5:]
            if VALID_MOOD_RE.fullmatch(kind):
                mapped = DIRECT_KINDS.get(kind.lower())
                if mapped:
                    args = ["--play", mapped]
                    fallback = f"play {mapped}"
                else:
                    args = ["--play", f"radio:{kind}"]
                    fallback = f"play radio:{kind}"

        if args is None or fallback is None:
            self._send_json(400, {"error": "invalid_cmd"})
            return

        self.server.command_runner(args, fallback)
        now_doc = read_now_state(self.server.playlog_path, self.server.hearts_path)
        self._send_json(200, {"ok": True, "cmd": cmd, "now": now_doc})


def create_server(
    host: str = "127.0.0.1",
    port: int = 8787,
    name: str = "Glancebar (Mac)",
    mix_dir: Optional[Path] = None,
    hot_dir: Optional[Path] = None,
    playlog_path: Optional[Path] = None,
    hearts_path: Optional[Path] = None,
    state_dir: Optional[Path] = None,
    manifold_hub: str = "https://manifold-chi.vercel.app",
    offline: bool = False,
    passphrase: Optional[str] = None,
    pass_file: Optional[Path] = None,
    command_runner: Optional[Callable[[List[str], str], None]] = None,
) -> OtrHTTPServer:
    resolved_mix = Path(mix_dir or "~/Library/Application Support/Glancebar/mix").expanduser()
    resolved_hot = Path(hot_dir or "~/Music/Glancebar Lossless").expanduser()
    resolved_playlog = Path(playlog_path or "~/Library/Logs/Glancebar/playback.jsonl").expanduser()
    resolved_hearts = Path(hearts_path or "~/.local/state/selector/hearts.json").expanduser()
    resolved_state = Path(state_dir or "~/.local/state/glancebar-otr").expanduser()
    resolved_pass_file = Path(pass_file).expanduser() if pass_file is not None else None

    secret = load_or_create_passphrase(passphrase, resolved_pass_file, resolved_state)
    index = LibraryIndex(resolved_mix, resolved_hot)
    runner = command_runner if command_runner is not None else default_command_runner
    return OtrHTTPServer(
        (host, port),
        OtrHandler,
        server_name=name,
        passphrase=secret,
        index=index,
        mix_dir=resolved_mix,
        playlog_path=resolved_playlog,
        hearts_path=resolved_hearts,
        manifold_hub=manifold_hub,
        offline=offline,
        command_runner=runner,
    )


def parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    ap = argparse.ArgumentParser(description="Glancebar OtR Connector server")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8787)
    ap.add_argument("--name", default="Glancebar (Mac)")
    ap.add_argument("--mix-dir", default="~/Library/Application Support/Glancebar/mix")
    ap.add_argument("--hot-dir", default="~/Music/Glancebar Lossless")
    ap.add_argument("--playlog", default="~/Library/Logs/Glancebar/playback.jsonl")
    ap.add_argument("--hearts", default="~/.local/state/selector/hearts.json")
    ap.add_argument("--state-dir", default="~/.local/state/glancebar-otr")
    ap.add_argument("--manifold-hub", default="https://manifold-chi.vercel.app")
    ap.add_argument("--offline", action="store_true")
    ap.add_argument("--pass", dest="passphrase", default=None)
    ap.add_argument("--pass-file", default=None)
    return ap.parse_args(argv)


def main(argv: Optional[List[str]] = None) -> int:
    args = parse_args(argv)
    srv = create_server(
        host=args.host,
        port=args.port,
        name=args.name,
        mix_dir=Path(args.mix_dir),
        hot_dir=Path(args.hot_dir),
        playlog_path=Path(args.playlog),
        hearts_path=Path(args.hearts),
        state_dir=Path(args.state_dir),
        manifold_hub=args.manifold_hub,
        offline=args.offline,
        passphrase=args.passphrase,
        pass_file=Path(args.pass_file) if args.pass_file else None,
    )
    addr, port = srv.server_address[:2]
    print(f"otr-connector listening on http://{addr}:{port} ({len(srv.index.tracks)} tracks)", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        srv.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
