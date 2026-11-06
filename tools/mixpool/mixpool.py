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

State: ~/.local/state/glancebar-mix/pulled.json (album id -> metadata).
Never un-likes or deletes anything; amdl is skipped for albums already pulled.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

SOURCES = {
    "youtube-liked": Path.home() / "Music/YouTube Liked",
    "glancebar-radio": Path.home() / "Music/Glancebar Radio",
    "apple-music": Path.home() / "Music/Apple Music",
}
STATE_DIR = Path.home() / ".local/state/glancebar-mix"
STATE_FILE = STATE_DIR / "pulled.json"
AMDL = Path.home() / ".local/bin/amdl"
ITUNES_API = "https://itunes.apple.com/search"


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


def itunes_song(artist: str, title: str, album: str = "") -> dict | None:
    """Best AU-catalog song match for artist+title, or None."""
    q = urllib.parse.urlencode(
        {"term": f"{artist} {title}", "entity": "song", "country": "au", "limit": 10}
    )
    try:
        with urllib.request.urlopen(f"{ITUNES_API}?{q}", timeout=30) as r:
            results = json.load(r)["results"]
    except Exception as e:
        print(f"  lookup failed: {e}", file=sys.stderr)
        return None
    best, best_score = None, 0.0
    for res in results:
        if res.get("wrapperType") != "track":
            continue
        score = 0.0
        if _norm(res.get("artistName", "")) == _norm(artist):
            score += 0.5
        if _norm(res.get("trackName", "")) == _norm(title):
            score += 0.5
        if album:
            a, c = _norm(album), _norm(res.get("collectionName", ""))
            if a and c and (a in c or c in a):
                score += 0.3
        if res.get("collectionArtistName"):
            score -= 0.25  # prefer the original album over compilations
        if score > best_score:
            best, best_score = res, score
    return best if best_score >= 0.5 else None


def pull_liked(inventory_path: Path | None) -> int:
    """Acquire every Apple Music favourite as lossless via amdl (resumable)."""
    inv_path = inventory_path or Path.home() / ".local/state/music-sync/inventory.json"
    am_fav = json.loads(inv_path.read_text())["am_fav"]
    if LIKED_STATE.exists():
        state = json.loads(LIKED_STATE.read_text())
    else:
        state = {"done": {}, "no_match": {}}
    todo = [
        t for t in am_fav
        if f"{t['artist']}|{t['title']}" not in state["done"]
        and f"{t['artist']}|{t['title']}" not in state["no_match"]
    ]
    print(f"{len(am_fav)} favourites: {len(state['done'])} done, "
          f"{len(state['no_match'])} no-match, {len(todo)} to pull")
    failures = 0
    for i, t in enumerate(todo, 1):
        key = f"{t['artist']}|{t['title']}"
        song = itunes_song(t["artist"], t["title"], t.get("album", ""))
        if not song:
            state["no_match"][key] = t
            _save_liked(state)
            print(f"[{i}/{len(todo)}] no-match   {t['artist']} — {t['title']}")
            continue
        url = (f"https://music.apple.com/au/song/"
               f"{song['trackName'].replace(' ', '-').lower()}/{song['trackId']}")
        print(f"[{i}/{len(todo)}] {song['artistName']} — {song['trackName']}")
        ok = False
        for attempt in (1, 2):
            try:
                subprocess.run([str(AMDL), url], check=True, timeout=600)
                ok = True
                break
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as e:
                print(f"  attempt {attempt} failed: {e}", file=sys.stderr)
        if ok:
            state["done"][key] = {"track_id": song["trackId"], "url": url}
            failures = 0
        else:
            failures += 1
        _save_liked(state)
        if failures >= 5:
            print("5 in a row failed — stopping (rerun to resume)", file=sys.stderr)
            return 1
    print(f"done: {len(state['done'])} pulled, {len(state['no_match'])} no-match")
    return 0


def _save_liked(state: dict) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    LIKED_STATE.write_text(json.dumps(state, indent=2, sort_keys=True))


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
        sys.exit(pull_liked(getattr(args, "inventory", None)))
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
