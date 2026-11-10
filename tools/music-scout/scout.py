#!/usr/bin/env python3
"""music-scout — nightly pipeline to surface and acquire new lossless music.

Stages (each a subcommand, idempotent):
  candidates  gather tracks from triple j, new releases, taste LLM
  rank        dedupe, score, variety → queue.json
  acquire     top of queue via mixpool amdl (dry-run unless --go)
  publish     new-music.json for the Glancebar tile
  status      health JSON for morning check
  run         candidates → rank → acquire → publish (locked)

State: ~/.local/state/glancebar-music-scout/
Config: ~/.config/glancebar/music-scout.json (all optional)
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import subprocess
import sys
import time
import unicodedata
import urllib.parse
import urllib.request
from collections import Counter, defaultdict
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable

HOME = Path.home()
DEFAULT_CONFIG = HOME / ".config/glancebar/music-scout.json"
DEFAULT_STATE = HOME / ".local/state/glancebar-music-scout"
METERED_FLAG = HOME / ".local/state/METERED_LINK"
ITUNES_API = "https://itunes.apple.com/search"
ITUNES_LOOKUP = "https://itunes.apple.com/lookup"
MIXPOOL_DIR = Path(__file__).resolve().parent.parent / "mixpool"

DEFAULTS: dict[str, Any] = {
    "tracks_per_week": 20,
    "gb_per_week": 1.5,
    "fresh_days": 14,
    "exploration_share": 0.30,
    "max_per_artist_week": 2,
    "new_release_days": 60,
    "llm_suggestions": 15,
    "avg_track_mb": 75,
    "mb_per_minute": 7,
    "dead_source_nights": 3,
    "triplej_state": str(HOME / ".local/state/selector"),
    "library_export": str(HOME / "Music/Library-export"),
    "music_library_state": str(HOME / ".local/state/glancebar-music-library"),
    "mixpool_state": str(HOME / ".local/state/glancebar-mix"),
    "music_sync_inventory": str(HOME / ".local/state/music-sync/inventory.json"),
    "yt_liked_dir": str(HOME / "Music/YouTube Liked"),
    "hearts_path": str(HOME / ".local/state/selector/hearts.json"),
    "feedback_paths": [
        str(HOME / "Library/Application Support/Glancebar/mix/feedback.jsonl"),
        str(HOME / ".local/state/selector/feedback.jsonl"),
    ],
    "new_music_path": str(DEFAULT_STATE / "new-music.json"),
    "ai_pick_cmd": "ai-pick",
}

_YT_NAME = re.compile(
    r"^(?P<artist>.+?) - (?P<title>.+) \[(?P<vid>[A-Za-z0-9_-]+)\]\.m4a$",
    re.IGNORECASE,
)
_AUDIO = {".m4a", ".mp3", ".flac", ".alac", ".aac", ".wav", ".aiff", ".aif"}
GIB = 1024 ** 3


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def iso_now() -> str:
    return utc_now().strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(value: str) -> datetime | None:
    text = (value or "").strip()
    if not text:
        return None
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        return datetime.fromisoformat(text).astimezone(timezone.utc)
    except ValueError:
        return None


def normal(value: str) -> str:
    return " ".join(unicodedata.normalize("NFC", str(value or "")).casefold().split())


def track_key(artist: str, title: str) -> str:
    return f"{normal(artist)}|{normal(title)}"


def load_config(path: Path | None = None) -> dict[str, Any]:
    cfg = dict(DEFAULTS)
    p = path or DEFAULT_CONFIG
    if p.is_file():
        cfg.update(json.loads(p.read_text(encoding="utf-8")))
    return cfg


def append_jsonl(path: Path, row: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    line = json.dumps(row, ensure_ascii=False) + "\n"
    with path.open("a", encoding="utf-8") as f:
        f.write(line)
        f.flush()
        os.fsync(f.fileno())


def read_jsonl(path: Path) -> tuple[list[dict], str | None]:
    if not path.is_file():
        return [], None
    raw = path.read_text(encoding="utf-8")
    if not raw:
        return [], None
    lines = raw.splitlines()
    torn: str | None = None
    rows: list[dict] = []
    for line in lines[:-1]:
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            torn = line
            break
    last = lines[-1].strip()
    if last:
        try:
            rows.append(json.loads(last))
        except json.JSONDecodeError:
            torn = last
    return rows, torn


def read_jsonl_rows(path: Path) -> list[dict]:
    rows, _ = read_jsonl(path)
    return rows


class Runners:
    """Injectable side effects for tests."""

    def __init__(
        self,
        *,
        itunes_search: Callable[..., list[dict]] | None = None,
        itunes_lookup: Callable[..., list[dict]] | None = None,
        itunes_albums: Callable[..., list[dict]] | None = None,
        itunes_song_best: Callable[..., dict | None] = None,
        ai_pick: Callable[..., tuple[int, str]] | None = None,
        run_amdl: Callable[..., tuple[bool, bool, str]] | None = None,
        is_m5: Callable[[], bool] | None = None,
        is_metered: Callable[[], bool] | None = None,
        on_battery: Callable[[], bool] | None = None,
        clock: Callable[[], str] | None = None,
        sleep: Callable[[float], None] | None = None,
    ):
        self.itunes_search = itunes_search or _default_itunes_search
        self.itunes_lookup = itunes_lookup or _default_itunes_lookup
        self.itunes_albums = itunes_albums or _default_itunes_albums
        self.itunes_song_best = itunes_song_best or _default_itunes_song_best
        self.ai_pick = ai_pick or _default_ai_pick
        self.run_amdl = run_amdl or _default_run_amdl
        self.is_m5 = is_m5 or _default_is_m5
        self.is_metered = is_metered or _default_is_metered
        self.on_battery = on_battery or _default_on_battery
        self.clock = clock or iso_now
        self.sleep = sleep or time.sleep


_ITUNES_LAST = 0.0
_ITUNES_GAP = 0.35


def _itunes_rate_limit(sleep: Callable[[float], None]) -> None:
    global _ITUNES_LAST
    now = time.monotonic()
    wait = _ITUNES_GAP - (now - _ITUNES_LAST)
    if wait > 0:
        sleep(wait)
    _ITUNES_LAST = time.monotonic()


def _default_itunes_search(term: str, entity: str = "song", limit: int = 10, *, sleep=time.sleep) -> list[dict]:
    _itunes_rate_limit(sleep)
    q = urllib.parse.urlencode({"term": term, "entity": entity, "country": "au", "limit": limit})
    with urllib.request.urlopen(f"{ITUNES_API}?{q}", timeout=30) as r:
        return json.load(r).get("results") or []


def _default_itunes_lookup(collection_id: int | str, entity: str = "song", *, sleep=time.sleep) -> list[dict]:
    _itunes_rate_limit(sleep)
    q = urllib.parse.urlencode({"id": str(collection_id), "entity": entity, "country": "au"})
    with urllib.request.urlopen(f"{ITUNES_LOOKUP}?{q}", timeout=30) as r:
        data = json.load(r)
        return [r for r in data.get("results") or [] if r.get("wrapperType") == "track"]


def _default_itunes_albums(artist: str, per_artist: int, *, sleep=time.sleep) -> list[dict]:
    if str(MIXPOOL_DIR) not in sys.path:
        sys.path.insert(0, str(MIXPOOL_DIR))
    import mixpool  # noqa: E402

    _itunes_rate_limit(sleep)
    return mixpool.itunes_albums(artist, per_artist)


def _default_itunes_song_best(artist: str, title: str, album: str = "", *, sleep=time.sleep) -> dict | None:
    if str(MIXPOOL_DIR) not in sys.path:
        sys.path.insert(0, str(MIXPOOL_DIR))
    import mixpool  # noqa: E402

    _itunes_rate_limit(sleep)
    return mixpool.itunes_song_best(artist, title, album)


ENGINE_COMMANDS = {
    # Each takes the prompt on stdin and prints the model's reply. All read-only, no tools.
    "claude": [str(Path.home() / ".local/bin/claude"), "-p", "--tools", "", "--model", "haiku"],
    "codex": ["codex", "exec", "-s", "read-only"],
    "cursor": ["cursor-opinion"],
}


def _default_ai_pick(prompt: str, cmd: str) -> tuple[int, str]:
    """Ask whichever engine has capacity. `ai-pick` only NAMES the engine (exit 75 = defer);
    the prompt is then run through that engine's own read-only command."""
    try:
        pick = subprocess.run([cmd, "--engines", ",".join(ENGINE_COMMANDS), "--min", "20"],
                              capture_output=True, text=True, timeout=60)
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
        return 75, "ai-pick unavailable"
    if pick.returncode != 0:
        return (75 if pick.returncode == 75 else pick.returncode), (pick.stderr or "")
    engine = (pick.stdout or "").strip().splitlines()[-1].strip() if (pick.stdout or "").strip() else ""
    argv = ENGINE_COMMANDS.get(engine)
    if not argv:
        return 75, f"ai-pick named an engine this tool cannot run: {engine!r}"
    try:
        proc = subprocess.run(argv, input=prompt, capture_output=True, text=True, timeout=600,
                              cwd=str(Path(__file__).resolve().parent))
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError) as exc:
        return 1, f"{engine}: {exc}"
    if proc.returncode != 0:
        return proc.returncode, f"{engine}: {(proc.stderr or proc.stdout or '')[-400:]}"
    return 0, proc.stdout or ""


def _default_run_amdl(url: str) -> tuple[bool, bool, str]:
    if str(MIXPOOL_DIR) not in sys.path:
        sys.path.insert(0, str(MIXPOOL_DIR))
    import mixpool  # noqa: E402

    return mixpool._run_amdl(url)


def _default_is_m5() -> bool:
    try:
        proc = subprocess.run(
            ["sysctl", "-n", "machdep.cpu.brand_string"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        return "Apple M5" in (proc.stdout or "")
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
        return False


def _default_is_metered() -> bool:
    return METERED_FLAG.is_file()


def _default_on_battery() -> bool:
    try:
        proc = subprocess.run(["pmset", "-g", "batt"], capture_output=True, text=True, timeout=5)
        return "Battery Power" in (proc.stdout or "")
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
        return False


def song_url(song: dict) -> str:
    slug = str(song.get("trackName", "")).replace(" ", "-").lower()
    return f"https://music.apple.com/au/song/{slug}/{song['trackId']}"


class ScoutPaths:
    def __init__(self, state_dir: Path):
        self.state = state_dir
        self.candidates = state_dir / "candidates.json"
        self.queue = state_dir / "queue.json"
        self.ledger = state_dir / "ledger.jsonl"
        self.last_run = state_dir / "last-run.json"
        self.source_stats = state_dir / "source-stats.json"
        self.lock = state_dir / "scout.lock"


def acquire_defer_reason(runners: Runners) -> str | None:
    if not runners.is_m5():
        return "not Apple M5"
    if runners.is_metered():
        return "metered link"
    if runners.on_battery():
        return "on battery"
    return None


@contextmanager
def run_lock(path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(str(path), os.O_CREAT | os.O_RDWR)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError as exc:
        os.close(fd)
        raise SystemExit(75) from exc
    try:
        yield
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


# --- owned / taste index ---


def load_hearts(path: Path) -> set[str]:
    if not path.is_file():
        return set()
    data = json.loads(path.read_text(encoding="utf-8"))
    tracks = data.get("tracks") or data.get("keys") or []
    return {normal(k) if "|" in str(k) else str(k) for k in tracks}


def load_feedback(paths: list[Path]) -> dict[str, dict]:
    """Last event per track_key from feedback jsonl."""
    out: dict[str, dict] = {}
    for path in paths:
        for row in read_jsonl_rows(path):
            key = row.get("track_key") or track_key(row.get("artist", ""), row.get("title", ""))
            if key:
                out[normal(key)] = row
    return out


def walk_library_export(export_dir: Path) -> set[str]:
    keys: set[str] = set()
    if not export_dir.is_dir():
        return keys
    for p in export_dir.rglob("*"):
        if not p.is_file() or p.suffix.lower() not in _AUDIO:
            continue
        artist = p.parent.parent.name if len(p.parents) >= 2 else ""
        title = p.stem
        if artist:
            keys.add(track_key(artist, title))
    return keys


def yt_liked_keys(yt_dir: Path) -> set[str]:
    keys: set[str] = set()
    if not yt_dir.is_dir():
        return keys
    for p in yt_dir.glob("*.m4a"):
        m = _YT_NAME.match(p.name)
        if m:
            keys.add(track_key(m.group("artist"), m.group("title")))
    return keys


def catalogue_keys(catalogue_path: Path) -> set[str]:
    if not catalogue_path.is_file():
        return set()
    data = json.loads(catalogue_path.read_text(encoding="utf-8"))
    keys: set[str] = set()
    for entry in data.get("entries") or []:
        tags = entry.get("tags") or {}
        keys.add(track_key(tags.get("artist", ""), tags.get("title", "")))
    return keys


def music_sync_owned(inv_path: Path) -> set[str]:
    keys: set[str] = set()
    if not inv_path.is_file():
        return keys
    data = json.loads(inv_path.read_text(encoding="utf-8"))
    for row in data.get("am_fav") or []:
        keys.add(track_key(row.get("artist", ""), row.get("title", "")))
    for row in data.get("yt") or []:
        if row.get("artist") and row.get("title"):
            keys.add(track_key(row.get("artist", ""), row.get("title", "")))
    return keys


def mixpool_owned(mix_state: Path) -> set[str]:
    keys: set[str] = set()
    liked = mix_state / "liked-pulled.json"
    if liked.is_file():
        data = json.loads(liked.read_text(encoding="utf-8"))
        for bucket in ("done", "no_match", "failed"):
            for k in (data.get(bucket) or {}):
                keys.add(normal(k))
    return keys


def ledger_keys(ledger: Path, *, actions: set[str] | None = None) -> set[str]:
    keys: set[str] = set()
    for row in read_jsonl_rows(ledger):
        if actions and row.get("action") not in actions:
            continue
        keys.add(track_key(row.get("artist", ""), row.get("title", "")))
    return keys


def owned_keys(cfg: dict[str, Any], paths: ScoutPaths) -> set[str]:
    keys: set[str] = set()
    keys |= walk_library_export(Path(cfg["library_export"]).expanduser())
    keys |= catalogue_keys(Path(cfg["music_library_state"]).expanduser() / "catalogue.json")
    keys |= mixpool_owned(Path(cfg["mixpool_state"]).expanduser())
    keys |= music_sync_owned(Path(cfg["music_sync_inventory"]).expanduser())
    keys |= yt_liked_keys(Path(cfg["yt_liked_dir"]).expanduser())
    keys |= ledger_keys(paths.ledger)
    return keys


def ownership_sources(cfg: dict[str, Any], paths: ScoutPaths) -> set[str]:
    keys: set[str] = set()
    keys |= walk_library_export(Path(cfg["library_export"]).expanduser())
    keys |= catalogue_keys(Path(cfg["music_library_state"]).expanduser() / "catalogue.json")
    keys |= mixpool_owned(Path(cfg["mixpool_state"]).expanduser())
    keys |= music_sync_owned(Path(cfg["music_sync_inventory"]).expanduser())
    keys |= yt_liked_keys(Path(cfg["yt_liked_dir"]).expanduser())
    keys |= ledger_keys(paths.ledger, actions={"acquired", "no_match"})
    return keys


def liked_artists(cfg: dict[str, Any]) -> list[str]:
    artists: Counter[str] = Counter()
    inv = Path(cfg["music_sync_inventory"]).expanduser()
    if inv.is_file():
        for row in json.loads(inv.read_text(encoding="utf-8")).get("am_fav") or []:
            artists[normal(row.get("artist", ""))] += 3
    hearts = load_hearts(Path(cfg["hearts_path"]).expanduser())
    for key in hearts:
        if "|" in key:
            artists[key.split("|", 1)[0]] += 5
    export = Path(cfg["library_export"]).expanduser()
    if export.is_dir():
        for p in export.rglob("*"):
            if p.is_file() and p.suffix.lower() in _AUDIO and len(p.parents) >= 2:
                artists[normal(p.parent.parent.name)] += 1
    return [a for a, _ in artists.most_common(40) if a]


# --- sources ---


def source_triplej(cfg: dict[str, Any]) -> list[dict]:
    station = Path(cfg["triplej_state"]).expanduser() / "station.json"
    if not station.is_file():
        return []
    data = json.loads(station.read_text(encoding="utf-8"))
    out: list[dict] = []
    for pick in data.get("picks") or []:
        out.append(
            {
                "artist": pick.get("artist") or "",
                "title": pick.get("title") or "",
                "album": pick.get("album") or "",
                "source": "triplej",
                "why": pick.get("reason") or "triple j pick",
                "score_hint": 0.85,
            }
        )
    return out


def source_new_releases(
    cfg: dict[str, Any], runners: Runners, artists: list[str] | None = None
) -> list[dict]:
    days = int(cfg["new_release_days"])
    cutoff = utc_now() - timedelta(days=days)
    artists = artists if artists is not None else liked_artists(cfg)
    out: list[dict] = []
    for artist in artists[:25]:
        try:
            albums = runners.itunes_albums(artist, 4, sleep=runners.sleep)
        except Exception as exc:
            print(f"new-release: skip {artist}: {exc}", file=sys.stderr)
            continue
        for album in albums:
            released = (album.get("releaseDate") or "")[:10]
            if not released:
                continue
            try:
                rd = datetime.strptime(released, "%Y-%m-%d").replace(tzinfo=timezone.utc)
            except ValueError:
                continue
            if rd < cutoff:
                continue
            cid = album.get("collectionId")
            tracks: list[dict] = []
            if cid:
                try:
                    tracks = runners.itunes_lookup(cid, sleep=runners.sleep)
                except Exception:
                    tracks = []
            if not tracks:
                out.append(
                    {
                        "artist": album.get("artistName") or artist,
                        "title": album.get("collectionName") or "unknown",
                        "album": album.get("collectionName") or "",
                        "source": "new-release",
                        "why": f"New album ({released})",
                        "score_hint": 0.75,
                    }
                )
                continue
            for tr in tracks[:8]:
                out.append(
                    {
                        "artist": tr.get("artistName") or artist,
                        "title": tr.get("trackName") or "",
                        "album": tr.get("collectionName") or album.get("collectionName") or "",
                        "source": "new-release",
                        "why": f"New on {released}",
                        "score_hint": 0.78,
                    }
                )
    return out


def _build_taste_prompt(cfg: dict[str, Any], feedback: dict[str, dict], n: int) -> str:
    artists = liked_artists(cfg)
    likes = [k for k, v in feedback.items() if v.get("event") in ("like", "thumbs_up", "👍")]
    skips = [k for k, v in feedback.items() if v.get("event") in ("skip", "dislike")]
    payload = {
        "task": "suggest_tracks",
        "count": n,
        "loved_artists": artists[:20],
        "recent_likes": likes[:30],
        "recent_skips": skips[:30],
        "rules": [
            "Return ONLY a JSON array",
            "Each item: artist, title, why (one short sentence)",
            "Artists must NOT be in loved_artists",
            "Real released tracks only",
        ],
    }
    return json.dumps(payload, indent=2)


def _parse_llm_json(text: str) -> list[dict]:
    text = text.strip()
    start = text.find("[")
    end = text.rfind("]")
    if start < 0 or end < start:
        return []
    try:
        data = json.loads(text[start : end + 1])
    except json.JSONDecodeError:
        return []
    if not isinstance(data, list):
        return []
    return [r for r in data if isinstance(r, dict)]


def source_taste_expansion(
    cfg: dict[str, Any], runners: Runners, feedback: dict[str, dict] | None = None
) -> tuple[list[dict], str | None]:
    feedback = feedback if feedback is not None else load_feedback(
        [Path(p).expanduser() for p in cfg["feedback_paths"]]
    )
    n = int(cfg["llm_suggestions"])
    prompt = _build_taste_prompt(cfg, feedback, n)
    code, text = runners.ai_pick(prompt, str(cfg.get("ai_pick_cmd") or DEFAULTS["ai_pick_cmd"]))
    if code == 75:
        return [], "deferred"
    if code != 0:
        return [], f"ai-pick exit {code}"
    raw = _parse_llm_json(text)
    loved = {normal(a) for a in liked_artists(cfg)}
    out: list[dict] = []
    dropped = 0
    for row in raw:
        artist = str(row.get("artist") or "").strip()
        title = str(row.get("title") or "").strip()
        if not artist or not title:
            continue
        if normal(artist) in loved:
            continue
        hit = runners.itunes_song_best(artist, title, str(row.get("album") or ""), sleep=runners.sleep)
        if not hit:
            dropped += 1
            continue
        out.append(
            {
                "artist": hit.get("artistName") or artist,
                "title": hit.get("trackName") or title,
                "album": hit.get("collectionName") or "",
                "source": "taste-expansion",
                "why": str(row.get("why") or "taste match"),
                "score_hint": 0.65,
                "track_id": hit.get("trackId"),
            }
        )
    if dropped:
        print(f"taste-expansion: dropped {dropped} unconfirmed", file=sys.stderr)
    return out, None


def update_source_stats(
    paths: ScoutPaths, counts: dict[str, int], *, dead_nights: int, clock: str
) -> dict[str, Any]:
    prev: dict[str, Any] = {}
    if paths.source_stats.is_file():
        prev = json.loads(paths.source_stats.read_text(encoding="utf-8"))
    sources = prev.get("sources") or {}
    for name, count in counts.items():
        row = dict(sources.get(name) or {})
        streak = int(row.get("empty_streak") or 0)
        if count == 0:
            streak += 1
        else:
            streak = 0
        row.update(
            {
                "last_count": count,
                "empty_streak": streak,
                "flagged_dead": streak >= dead_nights,
                "last_at": clock,
            }
        )
        sources[name] = row
    doc = {"updated": clock, "sources": sources, "last_counts": counts}
    paths.state.mkdir(parents=True, exist_ok=True)
    paths.source_stats.write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return doc


def cmd_candidates(
    cfg: dict[str, Any], paths: ScoutPaths, runners: Runners
) -> tuple[list[dict], dict[str, int], list[str]]:
    errors: list[str] = []
    by_source: dict[str, list[dict]] = defaultdict(list)

    for name, fn in (
        ("triplej", lambda: source_triplej(cfg)),
        ("new-release", lambda: source_new_releases(cfg, runners)),
    ):
        try:
            rows = fn()
            by_source[name] = rows
        except Exception as exc:
            errors.append(f"{name}: {exc}")
            print(f"candidates: {name} failed: {exc}", file=sys.stderr)

    taste, taste_err = source_taste_expansion(cfg, runners)
    if taste_err == "deferred":
        errors.append("taste-expansion: deferred")
    elif taste_err:
        errors.append(f"taste-expansion: {taste_err}")
    else:
        by_source["taste-expansion"] = taste

    merged: list[dict] = []
    counts: dict[str, int] = {}
    for name, rows in by_source.items():
        counts[name] = len(rows)
        merged.extend(rows)

    doc = {
        "generated": runners.clock(),
        "candidates": merged,
        "counts": counts,
        "errors": errors,
    }
    paths.state.mkdir(parents=True, exist_ok=True)
    paths.candidates.write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    update_source_stats(paths, counts, dead_nights=int(cfg["dead_source_nights"]), clock=runners.clock())
    return merged, counts, errors


def score_candidate(
    c: dict,
    feedback: dict[str, dict],
    artist_affinity: Counter[str],
) -> float:
    base = float(c.get("score_hint") or 0.5)
    key = track_key(c.get("artist", ""), c.get("title", ""))
    ev = feedback.get(normal(key), {})
    event = ev.get("event") or ""
    if event in ("like", "thumbs_up", "👍"):
        base += 0.4
    elif event in ("skip", "dislike"):
        base -= 0.5
    art = normal(c.get("artist", ""))
    if artist_affinity.get(art, 0) > 0:
        base += 0.15
    return base


def cmd_rank(cfg: dict[str, Any], paths: ScoutPaths, runners: Runners) -> list[dict]:
    if not paths.candidates.is_file():
        raise SystemExit("rank: run candidates first")
    data = json.loads(paths.candidates.read_text(encoding="utf-8"))
    candidates = data.get("candidates") or []
    owned = owned_keys(cfg, paths)
    feedback = load_feedback([Path(p).expanduser() for p in cfg["feedback_paths"]])
    hearts = load_hearts(Path(cfg["hearts_path"]).expanduser())
    artist_affinity = Counter()
    for a in liked_artists(cfg):
        artist_affinity[a] += 1

    # recent offers this week (per artist cap)
    week_ago = utc_now() - timedelta(days=7)
    artist_week: Counter[str] = Counter()
    for row in read_jsonl_rows(paths.ledger):
        at = parse_iso(row.get("at") or "")
        if not at or at < week_ago:
            continue
        if row.get("action") in ("offered", "acquired", "queued"):
            artist_week[normal(row.get("artist", ""))] += 1

    max_art = int(cfg["max_per_artist_week"])
    explore_share = float(cfg["exploration_share"])
    seen: set[str] = set()
    ranked: list[dict] = []
    explore_pool: list[dict] = []
    rest_pool: list[dict] = []

    for c in candidates:
        key = track_key(c.get("artist", ""), c.get("title", ""))
        if key in seen:
            continue
        seen.add(key)
        if key in owned or normal(key) in hearts:
            continue
        scored = dict(c)
        scored["score"] = score_candidate(c, feedback, artist_affinity)
        scored["track_key"] = key
        if c.get("source") == "taste-expansion":
            explore_pool.append(scored)
        else:
            rest_pool.append(scored)

    explore_pool.sort(key=lambda r: (-r["score"], r["track_key"]))
    rest_pool.sort(key=lambda r: (-r["score"], r["track_key"]))

    total_slots = len(explore_pool) + len(rest_pool)
    explore_slots = (
        min(len(explore_pool), int(round(total_slots * explore_share))) if total_slots else 0
    )
    rest_slots = total_slots - explore_slots

    def apply_cap(pool: list[dict], limit: int) -> list[dict]:
        chosen: list[dict] = []
        for row in pool:
            if len(chosen) >= limit:
                break
            art = normal(row.get("artist", ""))
            if artist_week.get(art, 0) + sum(1 for x in chosen if normal(x.get("artist", "")) == art) >= max_art:
                continue
            chosen.append(row)
        return chosen

    ranked = apply_cap(explore_pool, explore_slots) + apply_cap(rest_pool, rest_slots)

    queue = {
        "generated": runners.clock(),
        "tracks": ranked,
        "explore_share": explore_share,
        "explore_selected": sum(1 for r in ranked if r.get("source") == "taste-expansion"),
    }
    paths.queue.write_text(json.dumps(queue, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    now = runners.clock()
    for row in ranked:
        append_jsonl(
            paths.ledger,
            {
                "at": now,
                "action": "offered",
                "artist": row.get("artist"),
                "title": row.get("title"),
                "source": row.get("source"),
                "why": row.get("why"),
                "track_key": row.get("track_key"),
            },
        )
    return ranked


def estimate_track_bytes(song: dict, mb_per_minute: float) -> int:
    millis = song.get("trackTimeMillis") or song.get("trackTime")
    try:
        seconds = float(millis) / 1000.0
    except (TypeError, ValueError):
        seconds = 0.0
    if seconds <= 0:
        return 0
    return int(seconds / 60.0 * mb_per_minute * 1024 * 1024)


def weekly_acquired_stats(ledger: Path, now: datetime) -> tuple[int, int]:
    week_ago = now - timedelta(days=7)
    count = 0
    total_bytes = 0
    for row in read_jsonl_rows(ledger):
        if row.get("action") != "acquired":
            continue
        at = parse_iso(row.get("at") or "")
        if not at or at < week_ago:
            continue
        count += 1
        if row.get("size_bytes") is not None:
            total_bytes += int(row["size_bytes"])
        else:
            total_bytes += int(float(row.get("size_mb") or 0) * 1024 * 1024)
    return count, total_bytes


def _amdl_result(result: tuple) -> tuple[bool, bool, str, dict]:
    if len(result) >= 4:
        ok, infra, error, meta = result[0], result[1], result[2], result[3]
        return ok, infra, error, meta if isinstance(meta, dict) else {}
    ok, infra, error = result[0], result[1], result[2] if len(result) > 2 else ""
    return ok, infra, error, {}


def cmd_acquire(
    cfg: dict[str, Any], paths: ScoutPaths, runners: Runners, *, go: bool = False
) -> dict[str, Any]:
    reason = acquire_defer_reason(runners)
    if reason:
        print(f"acquire: defer ({reason})", file=sys.stderr)
        raise SystemExit(75)

    if not paths.queue.is_file():
        raise SystemExit("acquire: run rank first")

    queue = json.loads(paths.queue.read_text(encoding="utf-8")).get("tracks") or []
    now = parse_iso(runners.clock()) or utc_now()
    acquired_count, acquired_bytes = weekly_acquired_stats(paths.ledger, now)
    track_budget = int(cfg["tracks_per_week"])
    gb_budget = float(cfg["gb_per_week"])
    mb_per_min = float(cfg.get("mb_per_minute", DEFAULTS["mb_per_minute"]))

    remaining_tracks = max(0, track_budget - acquired_count)
    remaining_bytes = max(0, int(gb_budget * GIB) - acquired_bytes)

    results: list[dict] = []
    for row in queue:
        if remaining_tracks <= 0 or remaining_bytes <= 0:
            break
        artist = row.get("artist") or ""
        title = row.get("title") or ""
        key = row.get("track_key") or track_key(artist, title)
        if key in ownership_sources(cfg, paths) or normal(key) in load_hearts(Path(cfg["hearts_path"]).expanduser()):
            rec = {"at": runners.clock(), "action": "skipped_owned", "artist": artist, "title": title, "track_key": key}
            results.append(rec)
            continue
        song = None
        if row.get("track_id"):
            song = {"trackId": row["track_id"], "trackName": title, "artistName": artist}
        if not song:
            song = runners.itunes_song_best(artist, title, row.get("album") or "", sleep=runners.sleep)
        if not song:
            rec = {"at": runners.clock(), "action": "no_match", "artist": artist, "title": title, "track_key": key}
            append_jsonl(paths.ledger, rec)
            results.append(rec)
            continue
        est_bytes = estimate_track_bytes(song, mb_per_min)
        if est_bytes <= 0:
            est_bytes = int(float(cfg.get("avg_track_mb", 75)) * 1024 * 1024)
        if est_bytes > remaining_bytes:
            rec = {
                "at": runners.clock(),
                "action": "skipped_budget",
                "artist": artist,
                "title": title,
                "track_key": key,
                "estimate_bytes": est_bytes,
            }
            results.append(rec)
            continue
        url = song_url(song)
        if not go:
            rec = {
                "at": runners.clock(),
                "action": "dry_run",
                "artist": artist,
                "title": title,
                "track_key": key,
                "url": url,
                "estimate_bytes": est_bytes,
            }
            results.append(rec)
            continue
        ok, infra, error, meta = _amdl_result(runners.run_amdl(url))
        size_bytes = int(meta.get("size_bytes") or est_bytes)
        if ok:
            rec = {
                "at": runners.clock(),
                "action": "acquired",
                "artist": artist,
                "title": title,
                "track_key": key,
                "url": url,
                "size_bytes": size_bytes,
                "album": song.get("collectionName") or row.get("album") or "",
                "duration_seconds": (float(song.get("trackTimeMillis") or 0) / 1000.0) or None,
                "local_path": meta.get("local_path"),
                "catalogue_relative_path": meta.get("catalogue_relative_path"),
                "sha256": meta.get("sha256"),
            }
            append_jsonl(paths.ledger, rec)
            remaining_tracks -= 1
            remaining_bytes -= size_bytes
        elif infra:
            rec = {
                "at": runners.clock(),
                "action": "failed",
                "artist": artist,
                "title": title,
                "track_key": key,
                "reason": error,
                "infra": True,
            }
            append_jsonl(paths.ledger, rec)
            results.append(rec)
            raise SystemExit(1)
        else:
            rec = {
                "at": runners.clock(),
                "action": "failed",
                "artist": artist,
                "title": title,
                "track_key": key,
                "reason": error or "unknown",
            }
        append_jsonl(paths.ledger, rec)
        results.append(rec)

    summary = {
        "at": runners.clock(),
        "dry_run": not go,
        "attempted": len(results),
        "acquired_before": acquired_count,
        "results": results,
    }
    return summary


def cmd_publish(cfg: dict[str, Any], paths: ScoutPaths, runners: Runners) -> dict[str, Any]:
    fresh_days = int(cfg["fresh_days"])
    cutoff = utc_now() - timedelta(days=fresh_days)
    hearts = load_hearts(Path(cfg["hearts_path"]).expanduser())
    tracks: list[dict] = []
    for row in read_jsonl_rows(paths.ledger):
        if row.get("action") != "acquired":
            continue
        at = parse_iso(row.get("at") or "")
        if not at or at < cutoff:
            continue
        key = row.get("track_key") or track_key(row.get("artist", ""), row.get("title", ""))
        if normal(key) in hearts:
            continue
        item = {
            "track_key": key,
            "artist": row.get("artist") or "",
            "title": row.get("title") or "",
            "album": row.get("album") or "",
            "duration_seconds": row.get("duration_seconds"),
            "why": row.get("why") or "new acquisition",
            "acquired_at": row.get("at"),
        }
        if row.get("local_path"):
            item["local_path"] = row["local_path"]
        if row.get("catalogue_relative_path") and row.get("sha256"):
            item["catalogue_relative_path"] = row["catalogue_relative_path"]
            item["sha256"] = row["sha256"]
        tracks.append(item)
    tracks.sort(key=lambda r: r.get("acquired_at") or "", reverse=True)
    doc = {
        "schemaVersion": 1,
        "generated": runners.clock(),
        "fresh_days": fresh_days,
        "tracks": tracks,
    }
    out = Path(cfg["new_music_path"]).expanduser()
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return doc


def cmd_status(cfg: dict[str, Any], paths: ScoutPaths, runners: Runners) -> tuple[dict[str, Any], int]:
    last: dict[str, Any] = {}
    if paths.last_run.is_file():
        last = json.loads(paths.last_run.read_text(encoding="utf-8"))
    queue_len = 0
    if paths.queue.is_file():
        queue_len = len(json.loads(paths.queue.read_text(encoding="utf-8")).get("tracks") or [])
    now = parse_iso(runners.clock()) or utc_now()
    acquired_count, acquired_bytes = weekly_acquired_stats(paths.ledger, now)
    _, torn = read_jsonl(paths.ledger)
    failures = sum(1 for r in read_jsonl_rows(paths.ledger) if r.get("action") == "failed")
    last_acquire: datetime | None = None
    for row in read_jsonl_rows(paths.ledger):
        if row.get("action") != "acquired":
            continue
        at = parse_iso(row.get("at") or "")
        if at and (last_acquire is None or at > last_acquire):
            last_acquire = at
    source_doc: dict[str, Any] = {}
    if paths.source_stats.is_file():
        source_doc = json.loads(paths.source_stats.read_text(encoding="utf-8"))

    status = {
        "generated": runners.clock(),
        "last_run": last,
        "source_stats": source_doc,
        "queue_length": queue_len,
        "acquired_this_week": acquired_count,
        "acquired_bytes_this_week": acquired_bytes,
        "acquired_gb_this_week": round(acquired_bytes / GIB, 3),
        "budget_tracks": int(cfg["tracks_per_week"]),
        "budget_gb": float(cfg["gb_per_week"]),
        "failures_total": failures,
        "ledger_torn_line": torn,
        "last_acquired_at": last_acquire.isoformat().replace("+00:00", "Z") if last_acquire else None,
    }
    code = 0
    if torn:
        code = 1
    if last.get("ok") is False:
        code = 1
    if last_acquire is None or (now - last_acquire) > timedelta(days=7):
        code = 1
    return status, code


def record_last_run(paths: ScoutPaths, *, ok: bool, stage: str, detail: dict, clock: str) -> None:
    doc = {"at": clock, "ok": ok, "stage": stage, **detail}
    paths.state.mkdir(parents=True, exist_ok=True)
    paths.last_run.write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def cmd_run(cfg: dict[str, Any], paths: ScoutPaths, runners: Runners, *, go: bool = False) -> int:
    with run_lock(paths.lock):
        try:
            _, counts, errors = cmd_candidates(cfg, paths, runners)
            ranked = cmd_rank(cfg, paths, runners)
            summary = cmd_acquire(cfg, paths, runners, go=go)
            publish = cmd_publish(cfg, paths, runners)
            record_last_run(
                paths,
                ok=not errors,
                stage="run",
                detail={"counts": counts, "queue": len(ranked), "acquire": summary, "publish_tracks": len(publish.get("tracks") or [])},
                clock=runners.clock(),
            )
            return 0
        except SystemExit as exc:
            record_last_run(paths, ok=False, stage="run", detail={"exit": exc.code}, clock=runners.clock())
            raise


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--config", type=Path, default=None)
    ap.add_argument("--state", type=Path, default=None)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("candidates")
    sub.add_parser("rank")
    p_acq = sub.add_parser("acquire")
    p_acq.add_argument("--go", action="store_true", help="really run amdl (default dry-run)")
    sub.add_parser("publish")
    sub.add_parser("status")
    p_run = sub.add_parser("run")
    p_run.add_argument("--go", action="store_true")
    return ap


def main(argv: list[str] | None = None) -> None:
    ap = build_parser()
    args = ap.parse_args(argv)
    cfg = load_config(args.config)
    state = Path(args.state).expanduser() if args.state else DEFAULT_STATE
    paths = ScoutPaths(state)
    runners = Runners()

    if args.cmd == "candidates":
        with run_lock(paths.lock):
            cmd_candidates(cfg, paths, runners)
    elif args.cmd == "rank":
        with run_lock(paths.lock):
            cmd_rank(cfg, paths, runners)
    elif args.cmd == "acquire":
        with run_lock(paths.lock):
            summary = cmd_acquire(cfg, paths, runners, go=args.go)
        print(json.dumps(summary, indent=2))
    elif args.cmd == "publish":
        with run_lock(paths.lock):
            doc = cmd_publish(cfg, paths, runners)
        print(json.dumps({"tracks": len(doc.get("tracks") or [])}))
    elif args.cmd == "status":
        doc, code = cmd_status(cfg, paths, runners)
        print(json.dumps(doc, indent=2))
        raise SystemExit(code)
    elif args.cmd == "run":
        cmd_run(cfg, paths, runners, go=args.go)


if __name__ == "__main__":
    main()
