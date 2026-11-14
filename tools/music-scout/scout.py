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
import shutil
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
_OFFLINE_CACHE = Path(__file__).resolve().parent.parent / "offline-cache"
if str(_OFFLINE_CACHE) not in sys.path:
    sys.path.insert(0, str(_OFFLINE_CACHE))
import offline_cache as oc  # noqa: E402

DEFAULTS: dict[str, Any] = {
    "tracks_per_week": 20,
    "gb_per_week": 1.5,
    "fresh_days": 14,
    "exploration_share": 0.30,
    "owned_artist_share_max": 0.30,
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
    "apple_music_dir": str(HOME / "Music/Apple Music"),
    "hot_dir": str(HOME / "Music/Glancebar Lossless"),
    "ai_pick_cmd": "ai-pick",
    "media_share": str(HOME / ".local/state/mac-sync/media"),
    "shazam_fresh_days": 30,
    "shazam_backlog_per_run": 5,
    "storefront": "au",
    "playback_log": str(HOME / "Library/Logs/Glancebar/playback.jsonl"),
    "reject_skips": 2,
    "station_playlist": "station:triplej",
}

_SHORT_MONTHS = (
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
)

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


def _signal_identity(sig: dict) -> tuple[str, str, str]:
    return (str(sig.get("kind") or ""), str(sig.get("source") or ""), str(sig.get("at") or ""))


def _merge_track_row(base: dict | None, row: dict) -> dict:
    out = dict(base or {})
    for field in ("artist", "title", "album"):
        if not out.get(field) and row.get(field):
            out[field] = row[field]
    ids = dict(out.get("ids") or {})
    for key, value in (row.get("ids") or {}).items():
        if value and not ids.get(key):
            ids[key] = value
    out["ids"] = ids
    signals = list(out.get("signals") or [])
    seen = {_signal_identity(s) for s in signals}
    for sig in row.get("signals") or []:
        ident = _signal_identity(sig)
        if ident in seen:
            continue
        seen.add(ident)
        signals.append(sig)
    out["signals"] = signals
    if row.get("owned"):
        out["owned"] = True
    if not out.get("video") and row.get("video"):
        out["video"] = row["video"]
    return out


def load_universe(share: Path) -> tuple[dict[str, dict], list[str]]:
    """Merged media signals view (see SCHEMA.md). Returns (tracks by key, parse errors)."""
    errors: list[str] = []
    merged: dict[str, dict] = {}
    if not share.is_dir():
        return merged, errors
    for path in sorted(share.glob("signals-*.json")):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            errors.append(f"{path.name}: {exc}")
            continue
        for key, row in (data.get("tracks") or {}).items():
            nkey = normal(key)
            merged[nkey] = _merge_track_row(merged.get(nkey), row)
    return merged, errors


def media_like_keys(universe: dict[str, dict]) -> set[str]:
    keys: set[str] = set()
    for key, row in universe.items():
        for sig in row.get("signals") or []:
            if sig.get("kind") == "like":
                keys.add(key)
                break
    return keys


def format_signal_day(iso_utc: str, now: datetime) -> str:
    dt = parse_iso(iso_utc)
    if not dt:
        return ""
    local = dt.astimezone()
    month = _SHORT_MONTHS[local.month - 1]
    if local.year != now.astimezone().year:
        return f"{local.day} {month} {local.year}"
    return f"{local.day} {month}"


def apple_music_row_fields(ids: dict, storefront: str) -> dict[str, Any]:
    am = str((ids or {}).get("apple_music") or "").strip()
    if not am:
        return {}
    out: dict[str, Any] = {"url": f"https://music.apple.com/{storefront}/song/{am}"}
    if am.isdigit():
        out["track_id"] = int(am)
    return out


def _playback_log_rows(path: Path) -> list[dict]:
    rows: list[dict] = []
    for name in (str(path) + ".1", str(path)):
        p = Path(name)
        if not p.is_file():
            continue
        for line in p.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(row, dict):
                rows.append(row)
    return rows


def _playback_track_key(row: dict) -> str | None:
    artist = row.get("artist") or ""
    title = row.get("title") or ""
    if artist and title:
        return track_key(artist, title)
    file_name = row.get("file") or ""
    if file_name:
        m = _YT_NAME.match(file_name)
        if m:
            return track_key(m.group("artist"), m.group("title"))
    return None


def _scout_acquired_index(ledger: Path) -> dict[str, dict]:
    """Scout-published tracks: key → latest acquired row."""
    index: dict[str, dict] = {}
    for row in read_jsonl_rows(ledger):
        if row.get("action") != "acquired":
            continue
        key = row.get("track_key") or track_key(row.get("artist", ""), row.get("title", ""))
        index[key] = row
    return index


def _path_basename(path_value: str | None) -> str:
    if not path_value:
        return ""
    return Path(path_value).name


def skip_rejected_keys(cfg: dict[str, Any], paths: ScoutPaths) -> set[str]:
    """Scout-published tracks the listener skipped early on separate days.

    The player's log has one `track` line each time a file starts: `file` is the file that
    is starting, `cause` is why it started and `epoch` is when. The line does not say how far
    the previous file played (`elapsed` there is the outgoing position after an automatic
    advance and about zero after a click), so this rule uses the clock alone. The time from
    one start line to the next is the longest the first file can have played: a pause, a
    stall or a sleep only makes that gap longer. So a short gap that ends in `click-next`
    is a real early skip, and a long one is never counted.

    A track is rejected when it was left by `click-next` within 40% of its duration (60 s
    when the duration is unknown) on `reject_skips` separate days, and no automatic advance
    ever followed it (it was never played to the end). Only lines from the New music
    playlist are judged, so a file of the same name elsewhere cannot count.
    """
    acquired = _scout_acquired_index(paths.ledger)
    if not acquired:
        return set()
    reject_n = max(1, int(cfg.get("reject_skips", DEFAULTS["reject_skips"])))
    station = str(cfg.get("station_playlist", DEFAULTS["station_playlist"]))
    rows = _playback_log_rows(Path(cfg["playback_log"]).expanduser())
    if not rows:
        return set()

    basename_to_key: dict[str, str] = {}
    for key, row in acquired.items():
        for field in ("local_path", "catalogue_relative_path"):
            base = _path_basename(row.get(field))
            if base:
                basename_to_key.setdefault(base, key)

    def row_key(row: dict) -> str | None:
        if str(row.get("playlist") or "") != station:
            return None
        base = str(row.get("file") or "")
        if base in basename_to_key:
            return basename_to_key[base]
        key = _playback_track_key(row)
        return key if key in acquired else None

    def limit_for(key: str) -> float:
        try:
            duration = float(acquired[key].get("duration_seconds") or 0)
        except (TypeError, ValueError):
            duration = 0.0
        return 0.4 * duration if duration > 0 else 60.0

    current: str | None = None
    started = 0.0
    completed: set[str] = set()
    skip_days: dict[str, set[str]] = defaultdict(set)

    for row in rows:
        event = str(row.get("event") or "")
        if event == "launch":
            current = None  # the app restarted: the gap across a restart says nothing
            continue
        if event != "track":
            continue
        epoch = row.get("epoch")
        if isinstance(epoch, bool) or not isinstance(epoch, (int, float)):
            current = None
            continue
        cause = str(row.get("cause") or "")
        if current is not None:
            gap = float(epoch) - started
            if cause in ("auto-advance", "crossfade"):
                completed.add(current)
            elif cause == "click-next" and 0 <= gap < limit_for(current):
                day = str(row.get("t") or "")[:10] or datetime.fromtimestamp(float(epoch)).strftime("%Y-%m-%d")
                skip_days[current].add(day)
        current = row_key(row)
        started = float(epoch)

    return {key for key, days in skip_days.items() if len(days) >= reject_n and key not in completed}


def rejected_keys(cfg: dict[str, Any], paths: ScoutPaths) -> set[str]:
    keys: set[str] = set()
    universe, _ = load_universe(Path(cfg["media_share"]).expanduser())
    for key, row in universe.items():
        for sig in row.get("signals") or []:
            if sig.get("kind") == "dislike":
                keys.add(key)
                break
    feedback = load_feedback([Path(p).expanduser() for p in cfg["feedback_paths"]])
    for key, row in feedback.items():
        if (row.get("event") or "") in ("dislike", "less"):
            keys.add(key)
    keys |= ledger_keys(paths.ledger, actions={"rejected"})
    keys |= skip_rejected_keys(cfg, paths)
    return keys


def record_skip_rejections(
    cfg: dict[str, Any],
    paths: ScoutPaths,
    skip_keys: set[str],
    *,
    clock: str,
) -> None:
    acquired = _scout_acquired_index(paths.ledger)
    existing = ledger_keys(paths.ledger, actions={"rejected"})
    for key in skip_keys:
        if key in existing:
            continue
        row = acquired.get(key) or {}
        append_jsonl(
            paths.ledger,
            {
                "action": "rejected",
                "track_key": key,
                "artist": row.get("artist") or "",
                "title": row.get("title") or "",
                "at": clock,
                "reason": "early_skip",
            },
        )


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
        media_collect: Callable[[], str | None] | None = None,
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
        # Refreshes this Mac's part of the shared media record. Off unless the command line
        # turns it on, so a test never writes into the real shared folder.
        self.media_collect = media_collect or (lambda: None)


MEDIA_SYNC = Path(__file__).resolve().parent.parent / "media-sync" / "media_sync.py"


def _default_media_collect() -> str | None:
    """Bring this Mac's Shazams and likes into the shared record before candidates are read,
    so a song Shazamed this evening is offered tonight. Returns what went wrong, or None."""
    if not MEDIA_SYNC.is_file():
        return None
    try:
        res = subprocess.run([sys.executable, str(MEDIA_SYNC), "collect"],
                             capture_output=True, text=True, timeout=180)
    except (OSError, subprocess.SubprocessError) as exc:
        return f"collect: {exc}"
    if res.returncode != 0:
        return f"collect exit {res.returncode}: {(res.stderr or res.stdout).strip()}"
    return None


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


def _tool_env() -> dict[str, str]:
    """Environment for the helper commands. launchd starts the nightly job with
    PATH=/usr/bin:/bin:/usr/sbin:/sbin, which holds none of them: on 11 and 12 Nov 2026 `ai-pick`
    was not found and the taste step silently never ran."""
    env = dict(os.environ)
    home = Path(env.get("HOME") or str(Path.home()))
    extra = [str(home / ".local" / "bin"), "/opt/homebrew/bin", "/usr/local/bin"]
    node_bins = []
    for d in (home / ".nvm" / "versions" / "node").glob("v*/bin"):
        try:
            node_bins.append((tuple(int(x) for x in d.parent.name[1:].split(".")), str(d)))
        except ValueError:
            continue
    if node_bins:
        extra.append(max(node_bins)[1])  # codex is installed under the newest node
    have = [x for x in (env.get("PATH") or "").split(os.pathsep) if x]
    env["PATH"] = os.pathsep.join(have + [x for x in extra if x not in have])
    return env


def _default_ai_pick(prompt: str, cmd: str) -> tuple[int, str]:
    """Ask whichever engine has capacity. `ai-pick` only NAMES the engine (exit 75 = defer);
    the prompt is then run through that engine's own read-only command. Only ai-pick's own
    exit 75 is a deferral: a command that cannot be found or run is an error with its reason."""
    env = _tool_env()
    pick_exe = shutil.which(cmd, path=env["PATH"])
    if not pick_exe:
        return 127, f"{cmd} not found on PATH ({env['PATH']})"
    try:
        pick = subprocess.run([pick_exe, "--engines", ",".join(ENGINE_COMMANDS), "--min", "20"],
                              capture_output=True, text=True, timeout=60, env=env)
    except (subprocess.TimeoutExpired, OSError) as exc:
        return 1, f"{cmd}: {exc}"
    if pick.returncode != 0:
        return pick.returncode, (pick.stderr or pick.stdout or "").strip()[-400:]
    engine = (pick.stdout or "").strip().splitlines()[-1].strip() if (pick.stdout or "").strip() else ""
    argv = ENGINE_COMMANDS.get(engine)
    if not argv:
        return 1, f"{cmd} named an engine this tool cannot run: {engine!r}"
    exe = shutil.which(argv[0], path=env["PATH"])
    if not exe:
        return 127, f"{engine}: {argv[0]} not found on PATH"
    try:
        proc = subprocess.run([exe, *argv[1:]], input=prompt, capture_output=True, text=True, timeout=600,
                              cwd=str(Path(__file__).resolve().parent), env=env)
    except (subprocess.TimeoutExpired, OSError) as exc:
        return 1, f"{engine}: {exc}"
    if proc.returncode != 0:
        return proc.returncode, f"{engine}: {(proc.stderr or proc.stdout or '')[-400:]}"
    return 0, proc.stdout or ""


def _default_run_amdl(url: str) -> tuple:
    if str(MIXPOOL_DIR) not in sys.path:
        sys.path.insert(0, str(MIXPOOL_DIR))
    import mixpool  # noqa: E402

    ok, infra, error, detail = mixpool.run_amdl_detailed(url)
    meta = _meta_from_amdl_detail(detail) if ok else {}
    return ok, infra, error, meta


def _meta_from_amdl_detail(detail: dict) -> dict[str, Any]:
    files = detail.get("files") or []
    if not files:
        size = int(detail.get("size_bytes") or 0)
        return {"size_bytes": size} if size else {}
    primary = max(files, key=lambda f: f.get("size_bytes") or 0)
    return {
        "size_bytes": int(detail.get("size_bytes") or sum(f.get("size_bytes") or 0 for f in files)),
        "files": files,
        "local_path": primary.get("absolute_path"),
        "catalogue_relative_path": primary.get("relative_path"),
        "sha256": primary.get("sha256"),
    }


def copy_file_to_hot(src: Path, apple_music_root: Path, hot_dir: Path) -> Path | None:
    """Copy one acquired file into the hot set (never move). Returns dest or None."""
    src = src.expanduser().resolve()
    root = apple_music_root.expanduser().resolve()
    hot = hot_dir.expanduser().resolve()
    try:
        rel = src.relative_to(root)
    except ValueError:
        return None
    dest = hot / rel
    dest.parent.mkdir(parents=True, exist_ok=True)
    try:
        src_size = src.stat().st_size
    except OSError:
        return None
    if dest.is_file() and dest.stat().st_size == src_size:
        return dest
    shutil.copy2(src, dest)
    try:
        if dest.stat().st_size != src_size:
            dest.unlink(missing_ok=True)
            return None
    except OSError:
        return None
    return dest


def mirror_acquire_to_hot(meta: dict, cfg: dict[str, Any]) -> dict[str, Any]:
    """Copy new audio files to the hot dir so playback works before offload."""
    apple_root = Path(cfg.get("apple_music_dir", DEFAULTS["apple_music_dir"])).expanduser()
    hot_dir = Path(cfg.get("hot_dir", DEFAULTS["hot_dir"])).expanduser()
    out = dict(meta)
    hot_paths: list[str] = []
    for spec in meta.get("files") or []:
        src = Path(spec.get("absolute_path") or "")
        if not src.is_file():
            continue
        dest = copy_file_to_hot(src, apple_root, hot_dir)
        if dest:
            hot_paths.append(str(dest))
    if hot_paths:
        out["local_path"] = hot_paths[0]
        out["hot_paths"] = hot_paths
    elif meta.get("local_path"):
        src = Path(meta["local_path"])
        dest = copy_file_to_hot(src, apple_root, hot_dir)
        if dest:
            out["local_path"] = str(dest)
    return out


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


def heart_history_path(cfg: dict[str, Any]) -> Path:
    return Path(cfg["hearts_path"]).expanduser().parent / "heart-history.jsonl"


def load_ever_hearted(path: Path) -> set[str]:
    """Track keys that were hearted at least once (un-heart does not remove them)."""
    out: set[str] = set()
    for row in read_jsonl_rows(path):
        if row.get("action") != "heart":
            continue
        key = row.get("trackKey") or row.get("track_key") or ""
        if key:
            out.add(normal(key))
    return out


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


def primary_artist_name(artist: str) -> str:
    return normal(oc.split_primary_artist(artist))


def owned_artists(cfg: dict[str, Any], paths: ScoutPaths) -> set[str]:
    artists: set[str] = set()
    for key in owned_keys(cfg, paths):
        if "|" in key:
            artists.add(key.split("|", 1)[0])
    inv = Path(cfg["music_sync_inventory"]).expanduser()
    if inv.is_file():
        for row in json.loads(inv.read_text(encoding="utf-8")).get("am_fav") or []:
            artists.add(primary_artist_name(row.get("artist", "")))
    export = Path(cfg["library_export"]).expanduser()
    if export.is_dir():
        for p in export.rglob("*"):
            if p.is_file() and p.suffix.lower() in _AUDIO and len(p.parents) >= 2:
                artists.add(primary_artist_name(p.parent.parent.name))
    return artists


_REMIX_WORD = re.compile(r"\b(?:remix|rework|edit|flip|bootleg|version)\b", re.IGNORECASE)


def base_title_for_owned_match(title: str) -> str:
    text = oc.strip_match_suffixes(title)
    text = _REMIX_WORD.sub("", text)
    return normal(text)


def is_remix_of_owned(artist: str, title: str, owned_track_keys: set[str]) -> bool:
    if not oc.looks_like_remix(title):
        return False
    base = base_title_for_owned_match(title)
    if not base:
        return False
    for key in owned_track_keys:
        if "|" not in key:
            continue
        _oa, ot = key.split("|", 1)
        if base == ot or (base in ot and len(base) > 4):
            return True
    return False


def novelty_tier(
    candidate: dict,
    owned_artist_set: set[str],
    owned_track_keys: set[str],
) -> int:
    """0 = new artist, 1 = already in library, 2 = remix/alternate of owned recording."""
    art = primary_artist_name(candidate.get("artist", ""))
    if is_remix_of_owned(candidate.get("artist", ""), candidate.get("title", ""), owned_track_keys):
        return 2
    if art in owned_artist_set:
        return 1
    return 0


def enforce_owned_artist_share(
    rows: list[dict],
    share: float,
    owned_artist_set: set[str],
) -> list[dict]:
    if not rows:
        return rows
    cap = max(0, int(round(len(rows) * share)))
    chosen: list[dict] = []
    owned_used = 0
    for row in rows:
        art = primary_artist_name(row.get("artist", ""))
        if art in owned_artist_set and owned_used >= cap:
            continue
        chosen.append(row)
        if art in owned_artist_set:
            owned_used += 1
    return chosen


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
    hearts_path = Path(cfg["hearts_path"]).expanduser()
    hearts = load_hearts(hearts_path)
    ever = load_ever_hearted(heart_history_path(cfg))
    for key in hearts:
        if "|" in key:
            artists[key.split("|", 1)[0]] += 5
    for key in ever - hearts:
        if "|" in key:
            artists[key.split("|", 1)[0]] += 1
    export = Path(cfg["library_export"]).expanduser()
    if export.is_dir():
        for p in export.rglob("*"):
            if p.is_file() and p.suffix.lower() in _AUDIO and len(p.parents) >= 2:
                artists[normal(p.parent.parent.name)] += 1
    return [a for a, _ in artists.most_common(40) if a]


# --- sources ---


def _latest_signal_at(signals: list[dict], kind: str) -> str:
    best = ""
    best_dt: datetime | None = None
    for sig in signals:
        if sig.get("kind") != kind:
            continue
        at = sig.get("at") or ""
        dt = parse_iso(at)
        if dt is None and not at:
            continue
        if dt is None:
            if not best:
                best = at
            continue
        if best_dt is None or dt > best_dt:
            best_dt = dt
            best = at
    return best


def source_shazam(cfg: dict[str, Any], runners: Runners, rejected: set[str]) -> list[dict]:
    universe, _ = load_universe(Path(cfg["media_share"]).expanduser())
    now = parse_iso(runners.clock()) or utc_now()
    fresh_days = int(cfg.get("shazam_fresh_days", DEFAULTS["shazam_fresh_days"]))
    backlog_cap = int(cfg.get("shazam_backlog_per_run", DEFAULTS["shazam_backlog_per_run"]))
    storefront = str(cfg.get("storefront", DEFAULTS["storefront"]))
    fresh_cutoff = now - timedelta(days=fresh_days)

    fresh_rows: list[dict] = []
    backlog: list[tuple[datetime, dict]] = []

    for key, row in universe.items():
        if row.get("owned"):
            continue
        if key in rejected:
            continue
        signals = row.get("signals") or []
        if any(sig.get("kind") == "dislike" for sig in signals):
            continue
        shazam_at = _latest_signal_at(signals, "shazam")
        if not shazam_at:
            continue
        if not (row.get("artist") and row.get("title")):
            continue  # nothing to search for
        shazam_dt = parse_iso(shazam_at) or datetime.min.replace(tzinfo=timezone.utc)
        day = format_signal_day(shazam_at, now)
        cand: dict[str, Any] = {
            "artist": row.get("artist") or "",
            "title": row.get("title") or "",
            "album": row.get("album") or "",
            "source": "shazam",
            "why": f"Shazamed {day}" if day else "Shazamed",
        }
        cand.update(apple_music_row_fields(row.get("ids") or {}, storefront))
        if shazam_dt >= fresh_cutoff:
            cand["score_hint"] = 0.95
            cand["priority"] = True
            fresh_rows.append(cand)
        else:
            cand["score_hint"] = 0.6
            backlog.append((shazam_dt, cand))

    backlog.sort(key=lambda pair: pair[0], reverse=True)
    out = list(fresh_rows)
    out.extend(cand for _, cand in backlog[:backlog_cap])
    return out


def source_tv_likes(cfg: dict[str, Any], runners: Runners, rejected: set[str]) -> list[dict]:
    universe, _ = load_universe(Path(cfg["media_share"]).expanduser())
    now = parse_iso(runners.clock()) or utc_now()
    storefront = str(cfg.get("storefront", DEFAULTS["storefront"]))
    out: list[dict] = []
    for key, row in universe.items():
        if row.get("owned"):
            continue
        if key in rejected:
            continue
        signals = row.get("signals") or []
        if any(sig.get("kind") == "dislike" for sig in signals):
            continue
        tv_likes = [sig for sig in signals if sig.get("kind") == "like" and sig.get("source") == "tv"]
        if not tv_likes or not (row.get("artist") and row.get("title")):
            continue
        like_at = _latest_signal_at(tv_likes, "like")
        day = format_signal_day(like_at, now) if like_at else ""
        why = f"Liked on the TV {day}".strip() if day else "Liked on the TV"
        cand: dict[str, Any] = {
            "artist": row.get("artist") or "",
            "title": row.get("title") or "",
            "album": row.get("album") or "",
            "source": "tv-like",
            "score_hint": 0.9,
            "priority": True,
            "why": why,
        }
        cand.update(apple_music_row_fields(row.get("ids") or {}, storefront))
        out.append(cand)
    return out


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


def _build_taste_prompt(
    cfg: dict[str, Any],
    feedback: dict[str, dict],
    n: int,
    *,
    owned_artist_exclude: list[str] | None = None,
) -> str:
    artists = liked_artists(cfg)
    likes = [k for k, v in feedback.items() if v.get("event") in ("like", "thumbs_up", "👍")]
    skips = [k for k, v in feedback.items() if v.get("event") in ("skip", "dislike")]
    exclude = owned_artist_exclude or []
    payload = {
        "task": "suggest_tracks",
        "count": n,
        "loved_artists": artists[:20],
        "owned_artists_to_exclude": exclude[:1500],
        "recent_likes": likes[:30],
        "recent_skips": skips[:30],
        "rules": [
            "Return ONLY a JSON array",
            "Each item: artist, title, why (one short clause)",
            "Primary artist must NOT appear in owned_artists_to_exclude or loved_artists",
            "Prefer artists the listener does not already have in their library",
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
    cfg: dict[str, Any],
    runners: Runners,
    feedback: dict[str, dict] | None = None,
    *,
    paths: ScoutPaths | None = None,
) -> tuple[list[dict], str | None]:
    feedback = feedback if feedback is not None else load_feedback(
        [Path(p).expanduser() for p in cfg["feedback_paths"]]
    )
    n = int(cfg["llm_suggestions"])
    exclude: list[str] = []
    if paths is not None:
        exclude = sorted(owned_artists(cfg, paths))
    prompt = _build_taste_prompt(cfg, feedback, n, owned_artist_exclude=exclude)
    code, text = runners.ai_pick(prompt, str(cfg.get("ai_pick_cmd") or DEFAULTS["ai_pick_cmd"]))
    reason = " ".join(str(text or "").split())[:300]
    if code == 75:
        return [], "deferred" + (f": {reason}" if reason else "")
    if code != 0:
        return [], f"ai-pick exit {code}" + (f": {reason}" if reason else "")
    raw = _parse_llm_json(text)
    loved = {normal(a) for a in liked_artists(cfg)}
    out: list[dict] = []
    dropped = 0
    for row in raw:
        artist = str(row.get("artist") or "").strip()
        title = str(row.get("title") or "").strip()
        if not artist or not title:
            continue
        if normal(artist) in loved or primary_artist_name(artist) in {
            normal(a) for a in exclude
        }:
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
    collect_error = runners.media_collect()
    if collect_error:
        errors.append(f"media-sync: {collect_error}")
    rejected = rejected_keys(cfg, paths)
    _, universe_errors = load_universe(Path(cfg["media_share"]).expanduser())
    for msg in universe_errors:
        errors.append(f"media-share: {msg}")

    for name, fn in (
        ("triplej", lambda: source_triplej(cfg)),
        ("new-release", lambda: source_new_releases(cfg, runners)),
        ("shazam", lambda: source_shazam(cfg, runners, rejected)),
        ("tv-like", lambda: source_tv_likes(cfg, runners, rejected)),
    ):
        try:
            rows = fn()
            by_source[name] = rows
        except Exception as exc:
            errors.append(f"{name}: {exc}")
            print(f"candidates: {name} failed: {exc}", file=sys.stderr)

    taste, taste_err = source_taste_expansion(cfg, runners, paths=paths)
    if taste_err:
        errors.append(f"taste-expansion: {taste_err}")
    else:
        by_source["taste-expansion"] = taste

    merged: list[dict] = []
    counts: dict[str, int] = {}
    for name, rows in by_source.items():
        counts[name] = len(rows)
        for row in rows:
            key = track_key(row.get("artist", ""), row.get("title", ""))
            if key in rejected:
                continue
            merged.append(row)

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
    *,
    ever_hearted: set[str] | None = None,
    current_hearts: set[str] | None = None,
    media_likes: set[str] | None = None,
) -> float:
    base = float(c.get("score_hint") or 0.5)
    key = track_key(c.get("artist", ""), c.get("title", ""))
    ev = feedback.get(normal(key), {})
    event = ev.get("event") or ""
    like_bonus = 0.0
    if event in ("like", "thumbs_up", "👍"):
        like_bonus = 0.4
    elif event in ("skip", "dislike"):
        base -= 0.5
    nkey = normal(key)
    if nkey in (media_likes or set()):
        like_bonus = max(like_bonus, 0.4)
    base += like_bonus
    hearts_now = current_hearts or set()
    ever = ever_hearted or set()
    if nkey in ever and nkey not in hearts_now:
        base += 0.15
    art = normal(c.get("artist", ""))
    if artist_affinity.get(art, 0) > 0:
        base += 0.15
    return base


def cmd_rank(cfg: dict[str, Any], paths: ScoutPaths, runners: Runners) -> list[dict]:
    if not paths.candidates.is_file():
        raise SystemExit("rank: run candidates first")
    data = json.loads(paths.candidates.read_text(encoding="utf-8"))
    candidates = data.get("candidates") or []
    # The same song can arrive from two sources (a new release he also Shazamed). The first
    # row seen wins the de-duplication below, so his own signal must be seen first.
    candidates = sorted(candidates, key=lambda c: 0 if c.get("priority") else 1)
    owned = owned_keys(cfg, paths)
    really_owned = ownership_sources(cfg, paths)
    owned_artist_set = owned_artists(cfg, paths)
    feedback = load_feedback([Path(p).expanduser() for p in cfg["feedback_paths"]])
    hearts_path = Path(cfg["hearts_path"]).expanduser()
    hearts = load_hearts(hearts_path)
    ever_hearted = load_ever_hearted(heart_history_path(cfg))
    artist_affinity = Counter()
    for a in liked_artists(cfg):
        artist_affinity[a] += 1
    universe, _ = load_universe(Path(cfg["media_share"]).expanduser())
    media_likes = media_like_keys(universe)
    skip_rejected = skip_rejected_keys(cfg, paths)
    record_skip_rejections(cfg, paths, skip_rejected, clock=runners.clock())
    rejected = rejected_keys(cfg, paths)

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
    priority_pool: list[dict] = []
    explore_pool: list[dict] = []
    rest_pool: list[dict] = []

    for c in candidates:
        key = track_key(c.get("artist", ""), c.get("title", ""))
        if key in seen:
            continue
        seen.add(key)
        if key in rejected or normal(key) in hearts:
            continue
        # `owned` also holds everything the scout has ever offered, so it does not repeat
        # itself. A Shazam or a TV like is his own signal: only a real copy (or a search
        # that found nothing) stops it, not a dry-run offer from last week.
        if key in (really_owned if c.get("priority") else owned):
            continue
        scored = dict(c)
        scored["score"] = score_candidate(
            c,
            feedback,
            artist_affinity,
            ever_hearted=ever_hearted,
            current_hearts=hearts,
            media_likes=media_likes,
        )
        scored["track_key"] = key
        if c.get("priority"):
            priority_pool.append(scored)
        elif c.get("source") == "taste-expansion":
            explore_pool.append(scored)
        else:
            rest_pool.append(scored)

    def _rank_key(row: dict) -> tuple:
        tier = novelty_tier(row, owned_artist_set, owned)
        return (tier, -row["score"], row["track_key"])

    priority_pool.sort(key=lambda row: (-row["score"], row["track_key"]))
    explore_pool.sort(key=_rank_key)
    rest_pool.sort(key=_rank_key)

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

    ranked = list(priority_pool) + apply_cap(explore_pool, explore_slots) + apply_cap(rest_pool, rest_slots)
    if priority_pool:
        tail = ranked[len(priority_pool) :]
        tail = enforce_owned_artist_share(
            tail,
            float(cfg.get("owned_artist_share_max", DEFAULTS["owned_artist_share_max"])),
            owned_artist_set,
        )
        ranked = ranked[: len(priority_pool)] + tail
    else:
        ranked = enforce_owned_artist_share(
            ranked,
            float(cfg.get("owned_artist_share_max", DEFAULTS["owned_artist_share_max"])),
            owned_artist_set,
        )

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
    cfg: dict[str, Any],
    paths: ScoutPaths,
    runners: Runners,
    *,
    go: bool = False,
    limit: int | None = None,
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
    considered = 0
    for row in queue:
        if limit is not None and considered >= limit:
            break
        if remaining_tracks <= 0 or remaining_bytes <= 0:
            break
        considered += 1
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
            meta = mirror_acquire_to_hot(meta, cfg)
            size_bytes = int(meta.get("size_bytes") or size_bytes)
            rec = {
                "at": runners.clock(),
                "action": "acquired",
                "artist": artist,
                "title": title,
                "track_key": key,
                "source": row.get("source") or "",
                "why": row.get("why") or "",
                "url": url,
                "size_bytes": size_bytes,
                "album": song.get("collectionName") or row.get("album") or "",
                "duration_seconds": (float(song.get("trackTimeMillis") or 0) / 1000.0) or None,
                "local_path": meta.get("local_path"),
                "catalogue_relative_path": meta.get("catalogue_relative_path"),
                "sha256": meta.get("sha256"),
            }
            if meta.get("files"):
                rec["acquired_files"] = [
                    {
                        "relative_path": f.get("relative_path"),
                        "size_bytes": f.get("size_bytes"),
                        "sha256": f.get("sha256"),
                    }
                    for f in meta["files"]
                ]
            append_jsonl(paths.ledger, rec)
            results.append(rec)
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
        "considered": considered,
        "limit": limit,
        "acquired_before": acquired_count,
        "results": results,
    }
    return summary


def cmd_publish(cfg: dict[str, Any], paths: ScoutPaths, runners: Runners) -> dict[str, Any]:
    fresh_days = int(cfg["fresh_days"])
    cutoff = utc_now() - timedelta(days=fresh_days)
    hearts = load_hearts(Path(cfg["hearts_path"]).expanduser())
    rejected = rejected_keys(cfg, paths)
    tracks: list[dict] = []
    ledger_rows = read_jsonl_rows(paths.ledger)
    # Why it was picked ("Shazamed 14 Nov") is said when it is offered. Rows acquired before
    # the reason was copied onto the acquired row take it from their latest offer.
    offered_why: dict[str, str] = {}
    for row in ledger_rows:
        if row.get("action") in ("offered", "queued") and row.get("why"):
            key = row.get("track_key") or track_key(row.get("artist", ""), row.get("title", ""))
            offered_why[key] = row["why"]
    for row in ledger_rows:
        if row.get("action") != "acquired":
            continue
        at = parse_iso(row.get("at") or "")
        if not at or at < cutoff:
            continue
        key = row.get("track_key") or track_key(row.get("artist", ""), row.get("title", ""))
        if key in rejected or normal(key) in hearts:
            continue
        item = {
            "track_key": key,
            "artist": row.get("artist") or "",
            "title": row.get("title") or "",
            "album": row.get("album") or "",
            "duration_seconds": row.get("duration_seconds"),
            "why": row.get("why") or offered_why.get(key) or "new acquisition",
            "acquired_at": row.get("at"),
        }
        if row.get("local_path"):
            item["local_path"] = row["local_path"]
        if row.get("catalogue_relative_path"):
            item["catalogue_relative_path"] = row["catalogue_relative_path"]
        if row.get("sha256"):
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

    shazam_fresh = 0
    shazam_waiting = 0
    universe, _ = load_universe(Path(cfg["media_share"]).expanduser())
    fresh_cutoff = now - timedelta(days=int(cfg.get("shazam_fresh_days", DEFAULTS["shazam_fresh_days"])))
    ledger_all = ledger_keys(paths.ledger)
    for key, row in universe.items():
        shazam_at = _latest_signal_at(row.get("signals") or [], "shazam")
        shazam_dt = parse_iso(shazam_at or "")
        if not shazam_dt or shazam_dt < fresh_cutoff:
            continue
        if row.get("owned"):
            continue  # already a master: nothing is waiting
        shazam_fresh += 1
        if key not in ledger_all:
            shazam_waiting += 1

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
        "shazam": {"fresh": shazam_fresh, "waiting": shazam_waiting},
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
            summary = cmd_acquire(cfg, paths, runners, go=go, limit=None)
            publish = cmd_publish(cfg, paths, runners)
            record_last_run(
                paths,
                ok=not errors,
                stage="run",
                detail={"counts": counts, "errors": errors, "queue": len(ranked), "acquire": summary,
                        "publish_tracks": len(publish.get("tracks") or [])},
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
    p_acq.add_argument(
        "--limit",
        type=int,
        default=None,
        metavar="N",
        help="consider at most N queue tracks (e.g. 1 for a supervised trial)",
    )
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
    runners = Runners(media_collect=_default_media_collect)

    if args.cmd == "candidates":
        with run_lock(paths.lock):
            cmd_candidates(cfg, paths, runners)
    elif args.cmd == "rank":
        with run_lock(paths.lock):
            cmd_rank(cfg, paths, runners)
    elif args.cmd == "acquire":
        with run_lock(paths.lock):
            summary = cmd_acquire(cfg, paths, runners, go=args.go, limit=args.limit)
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
