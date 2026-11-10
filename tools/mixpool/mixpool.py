#!/usr/bin/env python3
"""mixpool — DJ mix mode track-pool manager.

Keeps the three local sources (YouTube Liked, Glancebar Radio, Apple Music ALAC)
stocked. Pulls Apple Music catalog albums as tagged lossless via the isolated
`amdl` black box (~/Projects/abliteration/apple-music-dl, see its README).

Subcommands:
  inventory                     list pool sizes per source
  plan --artists "A,B" [--per-artist N]     resolve artists to AU-catalog album
        URLs via the public iTunes Search API, skipping already-pulled albums
  pull --artists "A,B" [--per-artist N]     plan, then pull each album with amdl
  pull --urls URL [URL...]                  pull explicit Apple Music URLs
  pull-liked [--retry-failed]               acquire each Apple Music favourite
  retry-unmatched [--go]                    re-resolve no_match/failed favourites

State: ~/.local/state/glancebar-mix/pulled.json (album id -> metadata).
Liked pulls: ~/.local/state/glancebar-mix/liked-pulled.json
  done / no_match / failed. Failed tracks are skipped until --retry-failed.
Never un-likes or deletes anything; amdl is skipped for albums already pulled.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import queue
import re
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Callable

SOURCES = {
    "youtube-liked": Path.home() / "Music/YouTube Liked",
    "glancebar-radio": Path.home() / "Music/Glancebar Radio",
    "apple-music": Path.home() / "Music/Apple Music",
}
STATE_DIR = Path.home() / ".local/state/glancebar-mix"
STATE_FILE = STATE_DIR / "pulled.json"
AMDL = Path.home() / ".local/bin/amdl"
AMDL_TIMEOUT = 600
LIKED_CANDIDATES = 3
INFRA_STREAK_LIMIT = 5
ITUNES_API = "https://itunes.apple.com/search"
_AMDL_PROMPT = "press Enter to try again"
_COMPILATION_NAME = re.compile(
    r"\b(?:compilations?|hits|best of|now that['’]?s|now\s+\d{1,3}|various artists)\b",
    re.I,
)
_YEAR = re.compile(r"\b(?:(?:19|20)\d{2}s?|[1-9]0s)\b", re.I)
_ANTHOLOGY = re.compile(
    r"\b(?:hits|anthems|classics|anthology|collection|annual|best|now)\b",
    re.I,
)
_AUDIO_EXTS = {".m4a", ".mp3", ".flac", ".alac", ".aac", ".wav", ".aiff", ".aif"}


def load_state() -> dict:
    if STATE_FILE.exists():
        return json.loads(STATE_FILE.read_text())
    return {}


def save_state(state: dict) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(json.dumps(state, indent=2, sort_keys=True))


def inventory() -> None:
    total = 0
    for name, path in SOURCES.items():
        n = sum(1 for p in path.rglob("*.m4a") if p.is_file()) if path.exists() else 0
        total += n
        print(f"{name:16} {n:5}  {path}")
    print(f"{'total':16} {total:5}")


def itunes_albums(artist: str, per_artist: int) -> list[dict]:
    """Album results from the public iTunes Search API (metadata only, no auth)."""
    q = urllib.parse.urlencode(
        {"term": artist, "entity": "album", "country": "au", "limit": 25}
    )
    with urllib.request.urlopen(f"{ITUNES_API}?{q}", timeout=30) as r:
        results = json.load(r)["results"]
    albums: dict[str, dict] = {}
    for res in results:
        if res.get("wrapperType") != "collection":
            continue
        if res.get("artistName", "").lower() != artist.lower():
            continue
        albums.setdefault(str(res["collectionId"]), res)
    # full albums first (a DJ pool wants the core records, not singles/remixes),
    # newest within each group
    def is_album(a: dict) -> bool:
        return a.get("trackCount", 0) >= 6

    ordered = sorted(
        [a for a in albums.values() if is_album(a)],
        key=lambda a: a.get("releaseDate", ""),
        reverse=True,
    ) + sorted(
        [a for a in albums.values() if not is_album(a)],
        key=lambda a: a.get("releaseDate", ""),
        reverse=True,
    )
    return ordered[:per_artist]


def plan_albums(artists: list[str], per_artist: int, state: dict) -> list[dict]:
    plan: list[dict] = []
    for artist in artists:
        for album in itunes_albums(artist, per_artist):
            album_id = str(album["collectionId"])
            if album_id in state:
                print(f"skip (pulled)    {artist} — {album['collectionName']}")
                continue
            url = (
                f"https://music.apple.com/au/album/"
                f"{album.get('collectionName', '').replace(' ', '-').lower()}/{album_id}"
            )
            plan.append(
                {
                    "album_id": album_id,
                    "artist": album["artistName"],
                    "album": album["collectionName"],
                    "url": url,
                    "tracks": album.get("trackCount", 0),
                    "released": album.get("releaseDate", "")[:10],
                }
            )
    return plan


def pull_urls(plan: list[dict], state: dict) -> int:
    if not plan:
        print("nothing to pull")
        return 0
    tracks = sum(p["tracks"] for p in plan)
    print(f"pulling {len(plan)} albums ({tracks} tracks est.)")
    failures = 0
    for item in plan:
        print(f"\n=== {item['artist']} — {item['album']} ({item['released']})")
        for attempt in (1, 2):
            try:
                proc = subprocess.run(
                    [str(AMDL), item["url"]], check=True, timeout=3600
                )
                state[item["album_id"]] = item | {
                    "pulled_at": time.strftime("%Y-%m-%d %H:%M")
                }
                save_state(state)
                break
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as e:
                failures += 1
                print(f"  attempt {attempt} failed: {e}", file=sys.stderr)
                if attempt == 2:
                    print(f"  giving up on {item['album']}", file=sys.stderr)
    return failures


LIKED_STATE = STATE_DIR / "liked-pulled.json"


def _norm(s: str) -> str:
    return " ".join(s.lower().split())


def _song_score(res: dict, artist: str, title: str, album: str) -> float:
    score = 0.0
    if _norm(res.get("artistName", "")) == _norm(artist):
        score += 0.5
    if _norm(res.get("trackName", "")) == _norm(title):
        score += 0.5
    if album:
        wanted, got = _norm(album), _norm(res.get("collectionName", ""))
        if wanted and got and (wanted in got or got in wanted):
            score += 0.3
    if res.get("collectionArtistName"):
        score -= 0.25  # prefer the original album over compilations
    return score


def _year_anthology(name: str) -> bool:
    years = list(_YEAR.finditer(name))
    kinds = list(_ANTHOLOGY.finditer(name))
    for year in years:
        for kind in kinds:
            gap = max(year.start(), kind.start()) - min(year.end(), kind.end())
            if gap <= 40:
                return True
    return False


def _compilation_title(name: str) -> bool:
    return bool(_COMPILATION_NAME.search(name)) or _year_anthology(name)


def _is_compilation(res: dict) -> bool:
    """True for Various Artists and compilation / Hits / Now That's / year-anthology titles."""
    if _norm(str(res.get("collectionArtistName") or "")) == "various artists":
        return True
    return _compilation_title(str(res.get("collectionName") or ""))


def _itunes_search(artist: str, title: str) -> list[dict] | None:
    q = urllib.parse.urlencode(
        {"term": f"{artist} {title}", "entity": "song", "country": "au", "limit": 10}
    )
    try:
        with urllib.request.urlopen(f"{ITUNES_API}?{q}", timeout=30) as r:
            return json.load(r)["results"]
    except Exception as e:
        print(f"  lookup failed: {e}", file=sys.stderr, flush=True)
        return None


def itunes_song(artist: str, title: str, album: str = "") -> list[dict]:
    """Ranked AU-catalog matches, best first.

    Original albums and singles outrank compilations. A Various Artists
    credit, or a title that looks like a compilation, Hits, Now That's, or a
    year-anthology, is dropped when any other match clears the bar.
    """
    results = _itunes_search(artist, title)
    if not results:
        return []
    scored: list[tuple[float, int, dict]] = []
    for i, res in enumerate(results):
        if res.get("wrapperType") != "track":
            continue
        score = _song_score(res, artist, title, album)
        if score >= 0.5:
            scored.append((score, i, res))
    originals = [row for row in scored if not _is_compilation(row[2])]
    pool = originals if originals else scored
    pool.sort(key=lambda row: (-row[0], row[1]))
    seen: set = set()
    ranked: list[dict] = []
    for _, _, res in pool:
        track_id = res.get("trackId")
        if track_id in seen:
            continue
        seen.add(track_id)
        ranked.append(res)
    return ranked


def itunes_song_best(artist: str, title: str, album: str = "") -> dict | None:
    """Single best match, for callers that want one song."""
    found = itunes_song(artist, title, album)
    return found[0] if found else None


def _song_url(song: dict) -> str:
    slug = str(song.get("trackName", "")).replace(" ", "-").lower()
    return f"https://music.apple.com/au/song/{slug}/{song['trackId']}"


def _content_error(text: str) -> str | None:
    """Per-track failure, including a zero exit that still reported an error."""
    if _AMDL_PROMPT in text:
        return _AMDL_PROMPT
    if "webplayback not available" in text:
        return "webplayback not available"
    if re.search(r"Unavailable.*Failed to dl aac-lc", text, re.I | re.S):
        return "Unavailable; aac-lc fallback failed"
    if "Error detected" in text:
        return "Error detected"
    if re.search(r"Errors:\s*1\b", text):
        return "Errors: 1"
    return None


def _infra_error(text: str) -> str | None:
    """Downloader outage, not a bad catalogue row."""
    low = text.lower()
    if "connection refused" in low:
        return "connection refused"
    if "guest failed to come up" in low or "lite-server unreachable" in low:
        return "lite-server unreachable"
    return None


def _kill_amdl(proc: subprocess.Popen) -> None:
    if proc.poll() is None:
        try:
            proc.kill()
        except OSError:
            pass
    out = getattr(proc, "stdout", None)
    if out is not None:
        try:
            out.close()
        except Exception:
            pass


def _wait_amdl(proc: subprocess.Popen) -> int:
    try:
        rc = proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        _kill_amdl(proc)
        rc = proc.wait(timeout=5)
    return rc if isinstance(rc, int) else 1


def _run_amdl(url: str) -> tuple[bool, bool, str]:
    """One amdl attempt. Returns (ok, infrastructure_failure, error).

    stdin is closed so a failed track cannot sit on "press Enter". If that
    prompt is printed anyway, the process is killed on the line. Stdout and
    stderr are captured and echoed so the log stays useful.
    """
    try:
        proc = subprocess.Popen(
            [str(AMDL), url],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            errors="replace",
            bufsize=1,
        )
    except FileNotFoundError:
        return False, True, "amdl missing"
    except OSError as e:
        return False, True, f"amdl failed to start: {e}"

    lines: list[str] = []
    q: queue.Queue = queue.Queue()

    def reader() -> None:
        try:
            assert proc.stdout is not None
            for line in proc.stdout:
                q.put(line)
                if _AMDL_PROMPT in line:
                    return
            q.put(None)
        except Exception as exc:
            q.put(exc)

    thread = threading.Thread(target=reader, daemon=True)
    thread.start()
    deadline = time.monotonic() + AMDL_TIMEOUT
    prompted = False
    timed_out = False
    read_error: BaseException | None = None
    tail = ""

    def take(item: str | BaseException | None) -> bool:
        """Record one queued item. True means the caller should stop reading."""
        nonlocal prompted, read_error, tail
        if item is None:
            return True
        if isinstance(item, BaseException):
            read_error = item
            return True
        sys.stdout.write(item)
        sys.stdout.flush()
        lines.append(item)
        tail = (tail + item)[-200:]
        if _AMDL_PROMPT in tail:
            prompted = True
            return True
        return False

    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            timed_out = True
            break
        try:
            item = q.get(timeout=min(0.25, remaining))
        except queue.Empty:
            if proc.poll() is not None and not thread.is_alive() and q.empty():
                break
            continue
        if take(item):
            break

    if prompted or timed_out:
        _kill_amdl(proc)
    thread.join(timeout=2)
    while True:
        try:
            item = q.get_nowait()
        except queue.Empty:
            break
        if take(item):
            break
    rc = _wait_amdl(proc)
    output = "".join(lines)
    content = _content_error(output)
    infra = _infra_error(output)
    if prompted or content:
        return False, False, content or _AMDL_PROMPT
    if timed_out:
        if infra:
            return False, True, infra
        return False, False, "timeout"
    if infra and rc != 0:
        return False, True, infra
    if rc != 0:
        return False, False, f"exit {rc}"
    if read_error is not None and not output:
        return False, True, "amdl read failed"
    return True, False, ""


def _apple_music_audio_snapshot(root: Path) -> dict[str, int]:
    """Relative paths under *root* → file size in bytes (audio only)."""
    out: dict[str, int] = {}
    if not root.is_dir():
        return out
    root = root.resolve()
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        name = path.name
        if name.startswith("._") or name == ".DS_Store" or name == "OFFLOADED.txt":
            continue
        if path.suffix.lower() not in _AUDIO_EXTS:
            continue
        rel = str(path.relative_to(root))
        try:
            out[rel] = path.stat().st_size
        except OSError:
            continue
    return out


def sha256_file(path: Path, chunk: int = 1024 * 1024) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            block = handle.read(chunk)
            if not block:
                break
            digest.update(block)
    return digest.hexdigest()


def run_amdl_detailed(
    url: str,
    *,
    music_root: Path | None = None,
    run: Callable[[str], tuple[bool, bool, str]] | None = None,
) -> tuple[bool, bool, str, dict]:
    """Run amdl once and return any new audio files under the Apple Music folder.

    Non-breaking helper for scouts and metrics: ``pull-liked`` keeps calling
    ``_run_amdl`` directly. On success, *detail* contains ``files`` (list of
    dicts with relative_path, absolute_path, size_bytes, sha256) and
    ``size_bytes`` (sum of new files).
    """
    root = (music_root or SOURCES["apple-music"]).expanduser().resolve()
    before = _apple_music_audio_snapshot(root)
    runner = run or _run_amdl
    ok, infra, error = runner(url)
    detail: dict = {"music_root": str(root)}
    if not ok:
        return ok, infra, error, detail
    after = _apple_music_audio_snapshot(root)
    new_rels = sorted(set(after) - set(before))
    files: list[dict] = []
    for rel in new_rels:
        path = root / rel
        try:
            size = path.stat().st_size
        except OSError:
            continue
        if after.get(rel) != size:
            size = after[rel]
        files.append(
            {
                "relative_path": rel,
                "absolute_path": str(path),
                "size_bytes": size,
                "sha256": sha256_file(path),
            }
        )
    detail["files"] = files
    detail["size_bytes"] = sum(f["size_bytes"] for f in files)
    return ok, infra, error, detail


def _liked_summary(state: dict) -> None:
    print(
        f"done {len(state['done'])} / failed {len(state['failed'])} / "
        f"no-match {len(state['no_match'])}",
        flush=True,
    )


def _load_liked() -> dict:
    if LIKED_STATE.exists():
        state = json.loads(LIKED_STATE.read_text())
    else:
        state = {}
    state.setdefault("done", {})
    state.setdefault("no_match", {})
    state.setdefault("failed", {})
    return state


def pull_liked(inventory_path: Path | None, retry_failed: bool = False) -> int:
    """Acquire every Apple Music favourite as lossless via amdl (resumable).

    Each candidate is attempted once. Content failures are stored in
    state["failed"] and skipped on later runs unless retry_failed is set.
    Five infrastructure failures in a row (lite-server down, connection
    refused, amdl missing) stop the run with exit 1.
    """
    inv_path = inventory_path or Path.home() / ".local/state/music-sync/inventory.json"
    am_fav = json.loads(Path(inv_path).read_text())["am_fav"]
    state = _load_liked()
    todo = []
    for t in am_fav:
        key = f"{t['artist']}|{t['title']}"
        if key in state["done"] or key in state["no_match"]:
            continue
        if key in state["failed"] and not retry_failed:
            continue
        todo.append(t)
    print(
        f"{len(am_fav)} favourites: {len(state['done'])} done, "
        f"{len(state['failed'])} failed, {len(state['no_match'])} no-match, "
        f"{len(todo)} to pull",
        flush=True,
    )

    infra_streak = 0
    for i, t in enumerate(todo, 1):
        key = f"{t['artist']}|{t['title']}"
        songs = itunes_song(t["artist"], t["title"], t.get("album", ""))[:LIKED_CANDIDATES]
        if not songs:
            state["no_match"][key] = t
            state["failed"].pop(key, None)
            _save_liked(state)
            print(f"[{i}/{len(todo)}] no-match   {t['artist']} — {t['title']}", flush=True)
            infra_streak = 0
            continue
        print(
            f"[{i}/{len(todo)}] {songs[0]['artistName']} — {songs[0]['trackName']}",
            flush=True,
        )
        tried: list = []
        last_error = ""
        outcome = "fail"
        for song in songs:
            tried.append(song.get("trackId"))
            ok, infra, error = _run_amdl(_song_url(song))
            if ok:
                state["done"][key] = {
                    "track_id": song["trackId"],
                    "url": _song_url(song),
                }
                state["failed"].pop(key, None)
                outcome = "ok"
                break
            last_error = error
            print(
                f"  candidate {song.get('trackId')} failed: {error}",
                file=sys.stderr,
                flush=True,
            )
            if infra:
                outcome = "infra"
                break
        if outcome == "ok":
            infra_streak = 0
            _save_liked(state)
            continue
        if outcome == "infra":
            infra_streak += 1
            if infra_streak >= INFRA_STREAK_LIMIT:
                print(
                    "5 in a row failed — stopping (rerun to resume)",
                    file=sys.stderr,
                    flush=True,
                )
                _liked_summary(state)
                return 1
            continue
        state["failed"][key] = {
            "tried": tried,
            "last_error": last_error,
            "at": time.strftime("%Y-%m-%d %H:%M"),
        }
        infra_streak = 0
        _save_liked(state)

    _liked_summary(state)
    return 0


def _save_liked(state: dict) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    LIKED_STATE.write_text(json.dumps(state, indent=2, sort_keys=True))


_MUSICLIB = Path(__file__).resolve().parent.parent / "music-library"
_OFFLINE_CACHE = Path(__file__).resolve().parent.parent / "offline-cache"
for _p in (_MUSICLIB, _OFFLINE_CACHE):
    if str(_p) not in sys.path:
        sys.path.insert(0, str(_p))


def _load_catalogue_entries() -> list[dict]:
    import musiclib as ml  # noqa: WPS433

    cache = Path.home() / ".local/state/glancebar-music-library/catalogue.json"
    if not cache.is_file():
        return []
    doc = json.loads(cache.read_text(encoding="utf-8"))
    return ml.index_catalogue(doc)


def _track_from_liked_key(key: str, meta: object) -> dict:
    artist, title = key.split("|", 1)
    track = {"artist": artist, "title": title}
    if isinstance(meta, dict):
        if meta.get("album"):
            track["album"] = meta["album"]
    return track


def _retry_search_variants(track: dict) -> list[tuple[str, str, str]]:
    import offline_cache as oc  # noqa: WPS433

    artist = track.get("artist", "")
    title = track.get("title", "")
    album = str(track.get("album") or "")
    variants: list[tuple[str, str, str]] = []
    seen: set[tuple[str, str, str]] = set()

    def add(a: str, t: str, al: str) -> None:
        row = (a, t, al)
        if row not in seen and a and t:
            seen.add(row)
            variants.append(row)

    add(artist, title, album)
    add(artist, title, "")
    add(oc.split_primary_artist(artist), oc.strip_match_suffixes(title), "")
    add(oc.split_primary_artist(artist), title, "")
    for _a, t in oc.match_key_pairs(artist, title):
        add(_a, t, album)
        add(_a, t, "")
    return variants


def retry_unmatched(*, go: bool = False, catalogue_path: Path | None = None) -> int:
    """Re-try puller no_match/failed rows with improved catalogue match and iTunes variants."""
    import musiclib as ml  # noqa: WPS433

    state = _load_liked()
    targets: list[tuple[str, dict, str]] = []
    for bucket in ("no_match", "failed"):
        for key, meta in (state.get(bucket) or {}).items():
            if "|" not in key:
                continue
            track = _track_from_liked_key(key, meta)
            if isinstance(meta, dict):
                track.update({k: meta[k] for k in ("album",) if meta.get(k)})
            targets.append((key, track, bucket))

    cache = catalogue_path or Path.home() / ".local/state/glancebar-music-library/catalogue.json"
    entries = []
    if cache.is_file():
        doc = json.loads(cache.read_text(encoding="utf-8"))
        entries = ml.index_catalogue(doc)
    print(
        f"retry-unmatched: {len(targets)} targets "
        f"({'GO' if go else 'dry-run'})",
        flush=True,
    )
    planned = 0
    for key, track, bucket in targets:
        hits, reason = ml.match_track(track, entries)
        if hits:
            rel = hits[0].get("relativePath")
            print(f"catalogue-match  {key}  →  {rel}", flush=True)
            planned += 1
            continue
        song = None
        for a, t, al in _retry_search_variants(track):
            ranked = itunes_song(a, t, al)
            if ranked:
                song = ranked[0]
                break
        if not song:
            print(f"still-unmatched  {key}  ({bucket})", flush=True)
            continue
        url = _song_url(song)
        planned += 1
        print(
            f"would-acquire      {key}  "
            f"{song.get('artistName')} — {song.get('trackName')}  {url}",
            flush=True,
        )
        if go:
            print("  (skipped: --go not implemented in worker; lead runs amdl)", flush=True)
    print(f"retry-unmatched: {planned} resolvable", flush=True)
    return 0


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("inventory")
    p_plan = sub.add_parser("plan")
    p_plan.add_argument("--artists", required=True)
    p_plan.add_argument("--per-artist", type=int, default=2)
    p_pull = sub.add_parser("pull")
    p_pull.add_argument("--artists")
    p_pull.add_argument("--per-artist", type=int, default=2)
    p_pull.add_argument("--urls", nargs="*")
    p_liked = sub.add_parser("pull-liked", help="acquire all Apple Music favourites")
    p_liked.add_argument("--inventory", type=Path)
    p_liked.add_argument(
        "--retry-failed",
        action="store_true",
        help="retry tracks recorded as failed",
    )
    p_retry = sub.add_parser(
        "retry-unmatched",
        help="re-resolve liked puller no_match/failed rows (dry-run by default)",
    )
    p_retry.add_argument(
        "--go",
        action="store_true",
        help="actually acquire (default: print would-acquire lines only)",
    )
    p_retry.add_argument(
        "--catalogue",
        type=Path,
        default=None,
        help="catalogue.json path (default: glancebar-music-library cache)",
    )
    args = ap.parse_args()

    state = load_state()
    if args.cmd == "inventory":
        inventory()
    elif args.cmd == "plan":
        for item in plan_albums(
            [a.strip() for a in args.artists.split(",")], args.per_artist, state
        ):
            print(f"{item['tracks']:3} tr  {item['artist']} — {item['album']}  {item['url']}")
    elif args.cmd == "pull-liked":
        sys.exit(pull_liked(
            getattr(args, "inventory", None),
            retry_failed=getattr(args, "retry_failed", False),
        ))
    elif args.cmd == "retry-unmatched":
        sys.exit(
            retry_unmatched(
                go=bool(getattr(args, "go", False)),
                catalogue_path=getattr(args, "catalogue", None),
            )
        )
    elif args.cmd == "pull":
        if args.urls:
            plan = [
                {"album_id": u.rstrip("/").split("/")[-1], "artist": "?",
                 "album": u, "url": u, "tracks": 0, "released": ""}
                for u in args.urls
            ]
        else:
            if not args.artists:
                ap.error("pull needs --artists or --urls")
            plan = plan_albums(
                [a.strip() for a in args.artists.split(",")], args.per_artist, state
            )
        sys.exit(1 if pull_urls(plan, state) else 0)


if __name__ == "__main__":
    main()
