#!/usr/bin/env python3
"""radio — public playlists of respected stations, as candidates for the music scout.

Each station is read from its own public playlist API or page (see STATIONS). Every
request goes through one Fetcher: a generic User-Agent, at most one request per
`min_gap` seconds per host, a per-run request budget, and an on-disk response cache.
Parsed plays are kept per station in `radio-cache/plays/<station>.json`, one "unit"
(an episode, a playlist, a KEXP day) at a time: a unit that is final is never fetched
again, so each night only reads what is new. Plays older than the look-back window are
dropped.

`collect()` returns every play in the window; `select_candidates()` turns them into a
few scout candidates, multi-station tracks first. Nothing here downloads audio: the
scout's normal acquire step is the only way a candidate becomes a file.

Station not covered: FBi (Sydney). Its tracklists are only served by the site's own
GraphQL backend (/payload-api, disallowed in robots.txt) or embedded in each episode
page's framework payload, with no public list of recent episodes.
"""

from __future__ import annotations

import gzip
import hashlib
import html
import json
import re
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable
from zoneinfo import ZoneInfo

_OFFLINE_CACHE = Path(__file__).resolve().parent.parent / "offline-cache"
if str(_OFFLINE_CACHE) not in sys.path:
    sys.path.insert(0, str(_OFFLINE_CACHE))
import offline_cache as oc  # noqa: E402

USER_AGENT = "community-radio-playlist-reader/1.0 (public playlists only; one request per 2 s per host)"

# name: display name, kind: reader, tz: where the station's local times are
STATIONS: dict[str, dict[str, Any]] = {
    "kexp": {"name": "KEXP", "kind": "kexp"},
    "nts": {"name": "NTS", "kind": "nts"},
    "bbc6": {"name": "BBC 6 Music", "kind": "bbc", "service": "bbc_6music"},
    "wfmu": {"name": "WFMU", "kind": "wfmu"},
    "rrr": {"name": "RRR", "kind": "rrr", "tz": "Australia/Melbourne"},
    "pbs": {"name": "PBS", "kind": "airnet_guide", "call": "3pbs", "guide": "fm", "tz": "Australia/Melbourne"},
    "4zzz": {"name": "4ZZZ", "kind": "airnet_guide", "call": "4zzz", "guide": "fm", "tz": "Australia/Brisbane"},
    "rtr": {"name": "RTR FM", "kind": "airnet_programs", "call": "6rtr", "tz": "Australia/Perth"},
    # Read from the selector's own log (~/.local/state/selector/plays.jsonl); never fetched here.
    "triplej": {"name": "triple j", "kind": "local"},
}
DEFAULT_STATIONS = ["kexp", "nts", "bbc6", "wfmu", "rrr", "pbs", "4zzz", "rtr"]

KEXP_API = "https://api.kexp.org/v2/plays/"
NTS_RECENT = "https://www.nts.live/api/v2/collections/recently-added"
NTS_BASE = "https://www.nts.live/api/v2"
BBC_RMS = "https://rms.api.bbc.co.uk/v2/experience/inline"
WFMU_FEED = "https://wfmu.org/playlistfeed.xml"
WFMU_PLAYLIST = "https://wfmu.org/playlists/shows/{id}"
RRR_BASE = "https://www.rrr.org.au"
AIRNET = "https://airnet.org.au/rest/stations"

HOUR = 3600.0
DAY = 86400.0


class FetchStop(Exception):
    """The run budget, the deadline or a host's back-off stops further requests."""


def utc(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_time(value: str) -> datetime | None:
    text = str(value or "").strip()
    if not text:
        return None
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(text)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


# --- fetching ---------------------------------------------------------------------------


def urllib_transport(url: str, data: bytes | None, headers: dict[str, str]) -> tuple[int, str]:
    req = urllib.request.Request(url, data=data, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            charset = resp.headers.get_content_charset() or "utf-8"
            return resp.status, resp.read().decode(charset, errors="replace")
    except urllib.error.HTTPError as exc:
        try:
            body = exc.read().decode("utf-8", errors="replace")
        except Exception:
            body = ""
        return exc.code, body


class Fetcher:
    """Polite GET with a disk cache. One lock per host keeps requests to a host apart by
    `min_gap` seconds even when several stations on that host are read in parallel."""

    def __init__(
        self,
        cache_dir: Path,
        *,
        transport: Callable[[str, bytes | None, dict[str, str]], tuple[int, str]] | None = None,
        sleep: Callable[[float], None] = time.sleep,
        monotonic: Callable[[], float] = time.monotonic,
        wall: Callable[[], float] = time.time,
        min_gap: float = 2.0,
        budget: int = 700,
        deadline_seconds: float | None = None,
    ):
        self.cache_dir = cache_dir
        self.transport = transport or urllib_transport
        self.sleep = sleep
        self.monotonic = monotonic
        self.wall = wall
        self.min_gap = float(min_gap)
        self.budget = int(budget)
        self.deadline = monotonic() + deadline_seconds if deadline_seconds else None
        self.requests = 0
        self.by_host: Counter[str] = Counter()
        self.by_station: Counter[str] = Counter()
        self.local = threading.local()  # .station: who is asking, for the per-station count
        self.cache_hits = 0
        self.blocked: dict[str, str] = {}
        self._host_locks: dict[str, threading.Lock] = defaultdict(threading.Lock)
        self._host_last: dict[str, float] = {}
        self._lock = threading.Lock()

    def _cache_path(self, url: str, data: bytes | None) -> Path:
        digest = hashlib.sha1(url.encode() + b"\0" + (data or b"")).hexdigest()
        host = urllib.parse.urlsplit(url).hostname or "unknown"
        return self.cache_dir / "http" / host / f"{digest}.gz"

    def get(self, url: str, *, ttl: float | None = 6 * HOUR, data: bytes | None = None,
            headers: dict[str, str] | None = None) -> str | None:
        """Body of a 200 response, or None for a 4xx (not there). A cached body younger than
        `ttl` seconds is returned without a request. Raises FetchStop when the run may not
        send more, and on 429/5xx (that host is then left alone for the rest of the run)."""
        path = self._cache_path(url, data)
        if ttl is not None and path.is_file() and self.wall() - path.stat().st_mtime < ttl:
            try:
                body = gzip.decompress(path.read_bytes()).decode("utf-8")
                with self._lock:
                    self.cache_hits += 1
                return body
            except (OSError, EOFError, UnicodeDecodeError):
                pass
        host = urllib.parse.urlsplit(url).hostname or "unknown"
        with self._host_locks[host]:
            with self._lock:
                if host in self.blocked:
                    raise FetchStop(f"{host} backed off: {self.blocked[host]}")
                if self.requests >= self.budget:
                    raise FetchStop("request budget used")
                if self.deadline is not None and self.monotonic() > self.deadline:
                    raise FetchStop("time limit reached")
                self.requests += 1
                self.by_host[host] += 1
                self.by_station[getattr(self.local, "station", "")] += 1
            last = self._host_last.get(host)
            if last is not None:
                wait = self.min_gap - (self.monotonic() - last)
                if wait > 0:
                    self.sleep(wait)
            hdrs = {"User-Agent": USER_AGENT, "Accept": "application/json, text/html, application/xml;q=0.9"}
            hdrs.update(headers or {})
            try:
                status, body = self.transport(url, data, hdrs)
            except Exception as exc:  # network trouble: this host is done for tonight
                self._host_last[host] = self.monotonic()
                with self._lock:
                    self.blocked[host] = f"{type(exc).__name__}: {exc}"
                raise FetchStop(f"{host}: {exc}") from exc
            self._host_last[host] = self.monotonic()
        if status == 429 or status >= 500:
            with self._lock:
                self.blocked[host] = f"HTTP {status}"
            raise FetchStop(f"{host} answered HTTP {status}")
        if status != 200:
            return None
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".tmp")
        tmp.write_bytes(gzip.compress(body.encode("utf-8")))
        tmp.replace(path)
        return body

    def prune(self, older_than_days: float) -> int:
        """Forget cached responses older than the window (they are re-fetchable copies)."""
        root = self.cache_dir / "http"
        if not root.is_dir():
            return 0
        cutoff = self.wall() - older_than_days * DAY
        n = 0
        for p in root.glob("*/*.gz"):
            try:
                if p.stat().st_mtime < cutoff:
                    p.unlink()
                    n += 1
            except OSError:
                continue
        return n


# --- parsers (pure; each has a fixture test) -----------------------------------------------


def _strip_tags(text: str) -> str:
    return " ".join(html.unescape(re.sub(r"<[^>]+>", " ", text or "")).split())


def _clean(text: str | None) -> str:
    """One line, without the stray separators some playlist tools leave ("mj lenderman |")."""
    return " ".join(str(text or "").split()).strip(" |-–—/")


def play(artist: str, title: str, at: datetime | str | None, *, album: str = "", show: str = "") -> dict:
    when = at if isinstance(at, str) else (utc(at) if at else "")
    return {"artist": _clean(artist), "title": _clean(title), "album": _clean(album), "at": when, "show": show or ""}


def parse_kexp_plays(text: str) -> tuple[list[dict], str | None]:
    """api.kexp.org/v2/plays page → (track plays, next page URL). Air breaks are dropped."""
    doc = json.loads(text)
    out = []
    for row in doc.get("results") or []:
        if row.get("play_type") != "trackplay":
            continue
        at = parse_time(row.get("airdate") or "")
        out.append(play(row.get("artist"), row.get("song"), at, album=row.get("album") or ""))
    # The API offers a next page even past the end of a filtered range: an empty page is the end.
    return out, (doc.get("next") if doc.get("results") else None)


def parse_nts_recent(text: str) -> list[dict]:
    """NTS recently-added collection page → episodes {id, at, show, path}."""
    doc = json.loads(text)
    out = []
    for row in doc.get("results") or []:
        show, ep = row.get("show_alias"), row.get("episode_alias")
        at = parse_time(row.get("broadcast") or "")
        if not show or not ep or not at:
            continue
        genres = [g.get("value") for g in row.get("genres") or [] if g.get("value")]
        out.append({"id": f"{show}/{ep}", "at": utc(at), "show": row.get("name") or show,
                    "genres": genres, "path": f"/shows/{show}/episodes/{ep}"})
    return out


def parse_nts_tracklist(text: str) -> list[tuple[str, str]]:
    doc = json.loads(text)
    return [(r.get("artist") or "", r.get("title") or "") for r in doc.get("results") or []]


def parse_bbc_schedule(text: str) -> list[dict]:
    """rms.api.bbc.co.uk inline schedule for one day → broadcasts {id (episode pid), at, end, show}."""
    doc = json.loads(text)
    out = []
    for module in doc.get("data") or []:
        for item in module.get("data") or []:
            urn = str(item.get("urn") or "")
            if ":episode:" not in urn:
                continue
            start, end = parse_time(item.get("start") or ""), parse_time(item.get("end") or "")
            if not start:
                continue
            out.append({"id": urn.rsplit(":", 1)[-1], "at": utc(start), "end": utc(end) if end else utc(start),
                        "show": (item.get("titles") or {}).get("primary") or ""})
    return out


def parse_bbc_play(text: str) -> list[tuple[str, str]]:
    """rms inline play page for an episode → music segments (artist, title)."""
    doc = json.loads(text)
    out = []
    for module in doc.get("data") or []:
        if module.get("id") != "aod_tracks":
            continue
        for seg in module.get("data") or []:
            if seg.get("segment_type") not in (None, "music"):
                continue
            titles = seg.get("titles") or {}
            out.append((titles.get("primary") or "", titles.get("secondary") or ""))
    return out


_WFMU_ITEM = re.compile(r"<item>(.*?)</item>", re.S)
_WFMU_TITLE = re.compile(r"WFMU Playlist:\s*(.*?)\s+from\s+\w+ \d+, \d{4}\s*$")


def parse_wfmu_feed(text: str) -> list[dict]:
    """WFMU recent-playlists RSS → playlists {id, at, show}."""
    out = []
    for block in _WFMU_ITEM.findall(text):
        link = re.search(r"<link>\s*([^<]+?)\s*</link>", block)
        pub = re.search(r"<pubDate>\s*([^<]+?)\s*</pubDate>", block)
        title = re.search(r"<title>\s*([^<]+?)\s*</title>", block)
        m = re.search(r"/playlists/shows/(\d+)", link.group(1) if link else "")
        if not m or not pub:
            continue
        try:
            at = datetime.strptime(pub.group(1), "%a, %d %b %Y %H:%M:%S %z")
        except ValueError:
            continue
        show = html.unescape(title.group(1)) if title else ""
        tm = _WFMU_TITLE.search(show)
        out.append({"id": m.group(1), "at": utc(at), "show": tm.group(1) if tm else show})
    return out


_WFMU_ROW = re.compile(r'<tr id="drop_\d+"[^>]*>(.*?)</tr>', re.S)


def _wfmu_cell(row: str, col: str) -> str:
    m = re.search(rf'<td[^>]*class="song {col}"[^>]*>(.*?)</td>', row, re.S)
    if not m:
        return ""
    cell = re.sub(r"<span class=\"KDBFavIcon.*", "", m.group(1), flags=re.S)  # drop comment/fav widgets
    return _strip_tags(cell)


def parse_wfmu_playlist(text: str) -> list[dict]:
    out = []
    for row in _WFMU_ROW.findall(text):
        artist = _wfmu_cell(row, "col_artist")
        title = _wfmu_cell(row, "col_song_title")
        if artist.lower().startswith("music behind dj"):
            continue
        out.append({"artist": artist, "title": title, "album": _wfmu_cell(row, "col_album_title")})
    return out


_RRR_EP_LINK = re.compile(r'href="(/explore/programs/[a-z0-9-]+/episodes/\d+-[a-z0-9-]+)"')
_RRR_TRACK = re.compile(
    r'<span class="audio-summary__track-title">(.*?)</span>\s*<span class="audio-summary__track-artist">(.*?)</span>',
    re.S,
)
_RRR_FROM_ALBUM = re.compile(r"\s*\(From album ([^)]*)\)\s*$", re.IGNORECASE)


def parse_rrr_schedule(text: str) -> list[str]:
    """RRR schedule page for a date → episode page paths (unique, in page order)."""
    seen, out = set(), []
    for path in _RRR_EP_LINK.findall(text):
        if path not in seen:
            seen.add(path)
            out.append(path)
    return out


def parse_rrr_episode(text: str) -> dict:
    """RRR episode page → {start, end, show, tracks[]}. The title's "(From album X)" is the album."""
    start = end = None
    m = re.search(r'data-view-on-air-toggle="([^"]+)"', text)
    if m:
        try:
            times = json.loads(html.unescape(m.group(1)))
            start, end = parse_time(times.get("startTime") or ""), parse_time(times.get("endTime") or "")
        except (json.JSONDecodeError, AttributeError):
            pass
    heading = re.search(r'<h1 class="page-banner__heading">(.*?)</h1>', text, re.S)
    show = _strip_tags(heading.group(1)).split(" – ")[0] if heading else ""
    tracks = []
    for raw_title, raw_artist in _RRR_TRACK.findall(text):
        title = _strip_tags(raw_title)
        album = ""
        am = _RRR_FROM_ALBUM.search(title)
        if am:
            album = am.group(1).strip()
            title = title[: am.start()].strip()
        tracks.append({"artist": _strip_tags(raw_artist), "title": title, "album": album})
    return {"start": utc(start) if start else "", "end": utc(end) if end else "", "show": show, "tracks": tracks}


def parse_airnet_guide(text: str) -> list[dict]:
    """Airnet weekly grid → slots {slug, day (ISO weekday, 1 = Monday), start "HH:MM:SS", duration, name}."""
    out = []
    for row in json.loads(text) or []:
        if not row.get("slug") or not row.get("start"):
            continue
        out.append({"slug": row["slug"], "day": int(row.get("day") or 0), "start": row["start"],
                    "duration": int(row.get("duration") or 0),
                    "name": html.unescape(row.get("name") or row["slug"])})
    return out


def parse_airnet_programs(text: str) -> list[dict]:
    return [{"slug": p["slug"], "name": html.unescape(p.get("name") or p["slug"])}
            for p in json.loads(text) or [] if p.get("slug") and not p.get("archived")]


def parse_airnet_episodes(text: str) -> list[dict]:
    """A program's episode list → {start (local "YYYY-MM-DD HH:MM:SS"), duration}."""
    out = []
    for row in json.loads(text) or []:
        if row.get("start"):
            out.append({"start": row["start"], "duration": int(row.get("duration") or 0)})
    return out


def parse_airnet_playlist(text: str) -> list[dict]:
    doc = json.loads(text)
    if not isinstance(doc, list):
        return []
    out = []
    for row in doc:
        if row.get("type") != "track":
            continue
        release = str(row.get("release") or "").split(" | ")[0]
        out.append({"artist": row.get("artist") or "", "title": row.get("title") or row.get("track") or "",
                    "album": release})
    return out


def local_slot(local_start: str, tz: ZoneInfo) -> datetime | None:
    try:
        return datetime.strptime(local_start, "%Y-%m-%d %H:%M:%S").replace(tzinfo=tz).astimezone(timezone.utc)
    except ValueError:
        return None


# --- the play store -----------------------------------------------------------------------


class Store:
    """Parsed plays of one station: units (episode, playlist, day) → {at, final, plays}."""

    def __init__(self, path: Path):
        self.path = path
        self.units: dict[str, dict] = {}
        if path.is_file():
            try:
                self.units = json.loads(path.read_text(encoding="utf-8")).get("units") or {}
            except (OSError, json.JSONDecodeError):
                self.units = {}

    def done(self, unit: str) -> bool:
        return bool((self.units.get(unit) or {}).get("final"))

    def put(self, unit: str, at: str, plays: list[dict], *, final: bool, end: str = "") -> None:
        self.units[unit] = {"at": at, "end": end or at, "final": final, "plays": plays}

    def prune(self, since: datetime) -> None:
        """Forget units that ended before the window (a KEXP day half inside it stays)."""
        cutoff = utc(since)
        self.units = {k: v for k, v in self.units.items() if (v.get("end") or v.get("at") or "") >= cutoff}

    def plays(self, since: datetime) -> list[dict]:
        cutoff = utc(since)
        return [p for v in self.units.values() for p in v.get("plays") or [] if (p.get("at") or "") >= cutoff]

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps({"units": self.units}, ensure_ascii=False), encoding="utf-8")
        tmp.replace(self.path)


def _final(end: datetime, now: datetime, n: int, *, settle_hours: float = 6, empty_days: float = 3) -> bool:
    """A unit is final once it ended `settle_hours` ago and has tracks, or `empty_days` ago with none
    (presenters often enter a playlist the day after)."""
    age = (now - end).total_seconds()
    return age >= (settle_hours * HOUR if n else empty_days * DAY)


# --- station readers ----------------------------------------------------------------------


def read_kexp(f: Fetcher, store: Store, since: datetime, now: datetime, st: dict) -> None:
    day = since.date()
    while day <= now.date():
        unit = day.isoformat()
        start = datetime.combine(day, datetime.min.time(), tzinfo=timezone.utc)
        end = start + timedelta(days=1)
        if not store.done(unit):
            q = urllib.parse.urlencode({"airdate_after": utc(start), "airdate_before": utc(min(end, now)),
                                        "ordering": "airdate", "limit": 200})
            url: str | None = f"{KEXP_API}?{q}"
            plays: list[dict] = []
            pages = 0
            while url and pages < 10:
                body = f.get(url, ttl=2 * HOUR)
                if body is None:
                    break
                rows, url = parse_kexp_plays(body)
                plays.extend(rows)
                pages += 1
            store.put(unit, utc(start), [p for p in plays if p["at"] >= utc(since)],
                      final=_final(end, now, len(plays), settle_hours=2), end=utc(end))
        day += timedelta(days=1)


def read_nts(f: Fetcher, store: Store, since: datetime, now: datetime, st: dict) -> None:
    episodes: list[dict] = []
    for page in range(int(st.get("max_pages", 25))):
        body = f.get(f"{NTS_RECENT}?offset={page * 12}&limit=12", ttl=3 * HOUR)
        if body is None:
            break
        rows = parse_nts_recent(body)
        if not rows:
            break
        episodes.extend(rows)
        if max(r["at"] for r in rows) < utc(since):  # the whole page is older than the window
            break
    for ep in episodes:
        if ep["at"] < utc(since) or store.done(ep["id"]):
            continue
        body = f.get(f"{NTS_BASE}{ep['path']}/tracklist", ttl=6 * HOUR)
        tracks = parse_nts_tracklist(body) if body else []
        show = ep["show"] + (f" ({', '.join(ep['genres'][:2])})" if ep.get("genres") else "")
        plays = [play(a, t, ep["at"], show=show) for a, t in tracks]
        store.put(ep["id"], ep["at"], plays, final=_final(parse_time(ep["at"]) or now, now, len(plays)))


def read_bbc(f: Fetcher, store: Store, since: datetime, now: datetime, st: dict) -> None:
    service = st.get("service", "bbc_6music")
    day = since.date()
    while day <= now.date():
        past = day < now.date() - timedelta(days=1)
        body = f.get(f"{BBC_RMS}/schedules/{service}/{day.isoformat()}", ttl=7 * DAY if past else 3 * HOUR)
        day += timedelta(days=1)
        if body is None:
            continue
        for b in parse_bbc_schedule(body):
            end = parse_time(b["end"]) or now
            if b["at"] < utc(since) or end > now or store.done(b["id"]):
                continue
            page = f.get(f"{BBC_RMS}/play/{b['id']}", ttl=6 * HOUR)
            tracks = parse_bbc_play(page) if page else []
            plays = [play(a, t, b["at"], show=b["show"]) for a, t in tracks]
            store.put(b["id"], b["at"], plays, final=_final(end, now, len(plays), settle_hours=3))


def read_wfmu(f: Fetcher, store: Store, since: datetime, now: datetime, st: dict) -> None:
    body = f.get(WFMU_FEED, ttl=3 * HOUR)
    for pl in parse_wfmu_feed(body or ""):
        if pl["at"] < utc(since) or store.done(pl["id"]):
            continue
        page = f.get(WFMU_PLAYLIST.format(id=pl["id"]), ttl=6 * HOUR)
        tracks = parse_wfmu_playlist(page) if page else []
        plays = [play(t["artist"], t["title"], pl["at"], album=t["album"], show=pl["show"]) for t in tracks]
        # The feed time is when the DJ published; DJs keep editing for a while.
        store.put(pl["id"], pl["at"], plays, final=_final(parse_time(pl["at"]) or now, now, len(plays), settle_hours=24))


def read_rrr(f: Fetcher, store: Store, since: datetime, now: datetime, st: dict) -> None:
    tz = ZoneInfo(st["tz"])
    local_now = now.astimezone(tz)
    day = since.astimezone(tz).date()
    while day <= local_now.date():
        past = day < local_now.date() - timedelta(days=1)
        body = f.get(f"{RRR_BASE}/explore/schedule?date={day.isoformat()}", ttl=7 * DAY if past else 3 * HOUR)
        day += timedelta(days=1)
        for path in parse_rrr_schedule(body or ""):
            unit = path.rsplit("/", 1)[-1].split("-", 1)[0]  # numeric episode id
            if store.done(unit):
                continue
            page = f.get(f"{RRR_BASE}{path}", ttl=6 * HOUR)
            if not page:
                continue
            ep = parse_rrr_episode(page)
            start, end = parse_time(ep["start"]), parse_time(ep["end"])
            if not start or start < since or (end and end > now):
                continue
            plays = [play(t["artist"], t["title"], start, album=t["album"], show=ep["show"]) for t in ep["tracks"]]
            store.put(unit, utc(start), plays, final=_final(end or start, now, len(plays)))


def _airnet_episode(f: Fetcher, store: Store, call: str, slug: str, local_start: str, duration: int,
                    tz: ZoneInfo, since: datetime, now: datetime, show: str) -> None:
    start = local_slot(local_start, tz)
    if not start:
        return
    end = start + timedelta(seconds=duration or 3600)
    unit = f"{slug}@{local_start}"
    if start < since or end > now or store.done(unit):
        return
    ep = urllib.parse.quote(local_start)
    body = f.get(f"{AIRNET}/{call}/programs/{slug}/episodes/{ep}/playlists", ttl=6 * HOUR)
    tracks = parse_airnet_playlist(body) if body else []  # None = "No such episode" (HTTP 400)
    plays = [play(t["artist"], t["title"], start, album=t["album"], show=show) for t in tracks]
    store.put(unit, utc(start), plays, final=_final(end, now, len(plays)))


def read_airnet_guide(f: Fetcher, store: Store, since: datetime, now: datetime, st: dict) -> None:
    """Stations whose weekly grid is current on Airnet: each slot of each past day is an episode."""
    tz = ZoneInfo(st["tz"])
    body = f.get(f"{AIRNET}/{st['call']}/guides/{st.get('guide', 'fm')}", ttl=3 * DAY)
    slots = parse_airnet_guide(body or "")
    day = since.astimezone(tz).date()
    while day <= now.astimezone(tz).date():
        for s in slots:
            if s["day"] == day.isoweekday():
                _airnet_episode(f, store, st["call"], s["slug"], f"{day.isoformat()} {s['start']}",
                                s["duration"], tz, since, now, s["name"])
        day += timedelta(days=1)


def read_airnet_programs(f: Fetcher, store: Store, since: datetime, now: datetime, st: dict) -> None:
    """Stations with no grid on Airnet (RTR): read each current program's episode list."""
    tz = ZoneInfo(st["tz"])
    body = f.get(f"{AIRNET}/{st['call']}/programs", ttl=7 * DAY)
    for prog in parse_airnet_programs(body or ""):
        eps = f.get(f"{AIRNET}/{st['call']}/programs/{prog['slug']}/episodes", ttl=20 * HOUR)
        for ep in parse_airnet_episodes(eps or "[]"):
            _airnet_episode(f, store, st["call"], prog["slug"], ep["start"], ep["duration"], tz, since, now,
                            prog["name"])


READERS: dict[str, Callable[..., None]] = {
    "kexp": read_kexp,
    "nts": read_nts,
    "bbc": read_bbc,
    "wfmu": read_wfmu,
    "rrr": read_rrr,
    "airnet_guide": read_airnet_guide,
    "airnet_programs": read_airnet_programs,
}


def _host_group(st: dict) -> str:
    return {"airnet_guide": "airnet", "airnet_programs": "airnet"}.get(st["kind"], st["kind"])


def triplej_plays(path: Path, since: datetime) -> list[dict]:
    out = []
    if not path.is_file():
        return out
    cutoff = utc(since)
    for line in path.read_text(encoding="utf-8").splitlines():
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        at = parse_time(row.get("played_time") or "")
        if at and utc(at) >= cutoff:
            out.append(play(row.get("artist"), row.get("title"), at))
    return out


def collect(
    stations: list[str],
    cache_dir: Path,
    fetcher: Fetcher,
    *,
    now: datetime,
    days: float,
    triplej_log: Path | None = None,
) -> tuple[dict[str, list[dict]], dict[str, dict]]:
    """Read every station (stations on one host one after another, hosts in parallel).
    Returns (plays in the window by station, a report per station)."""
    since = now - timedelta(days=days)
    report: dict[str, dict] = {}
    plays: dict[str, list[dict]] = {}
    groups: dict[str, list[str]] = defaultdict(list)
    for code in stations:
        st = STATIONS.get(code)
        if not st or st["kind"] == "local":
            continue
        groups[_host_group(st)].append(code)

    def run_group(codes: list[str]) -> None:
        for code in codes:
            st = STATIONS[code]
            store = Store(cache_dir / "plays" / f"{code}.json")
            fetcher.local.station = code
            error = None
            try:
                READERS[st["kind"]](fetcher, store, since, now, st)
            except FetchStop as exc:
                error = str(exc)
            except Exception as exc:  # a changed page must not stop the other stations
                error = f"{type(exc).__name__}: {exc}"
            store.prune(since)
            store.save()
            got = store.plays(since)
            plays[code] = got
            report[code] = {"plays": len(got), "units": len(store.units),
                            "requests": fetcher.by_station[code], "error": error}

    with ThreadPoolExecutor(max_workers=max(1, len(groups))) as pool:
        list(pool.map(run_group, groups.values()))

    if "triplej" in stations and triplej_log is not None:
        plays["triplej"] = triplej_plays(triplej_log, since)
        report["triplej"] = {"plays": len(plays["triplej"]), "requests": 0, "error": None}
    return plays, report


# --- ranking ------------------------------------------------------------------------------

_JUNK = {"", "id", "unknown", "unknown artist", "various", "various artists", "untitled", "tba", "tbc", "?"}


def match_key(artist: str, title: str) -> str:
    """Loose identity across stations: primary artist without "The", title without feat./remaster."""
    a = oc.match_fold(oc.split_primary_artist(artist))
    if a.startswith("the "):
        a = a[4:]
    t = oc.match_fold(oc.strip_match_suffixes(oc._MATCH_FEAT_IN_TITLE.sub("", str(title or ""))))
    return f"{a}|{t}"


def is_junk(artist: str, title: str) -> bool:
    a, t = oc.match_fold(artist), oc.match_fold(title)
    return a in _JUNK or t in _JUNK or len(a) > 120 or len(t) > 160


def aggregate(plays: dict[str, list[dict]]) -> dict[str, dict]:
    """(artist, title) across stations → {artist, title, album, stations: {code: {plays, last, show}}}."""
    out: dict[str, dict] = {}
    for code, rows in plays.items():
        for p in rows:
            p = dict(p, artist=_clean(p["artist"]), title=_clean(p["title"]))
            if is_junk(p["artist"], p["title"]):
                continue
            key = match_key(p["artist"], p["title"])
            row = out.setdefault(key, {"artist": p["artist"], "title": p["title"], "album": p.get("album") or "",
                                       "stations": {}, "_spellings": Counter()})
            if not row["album"] and p.get("album"):
                row["album"] = p["album"]
            row["_spellings"][(p["artist"], p["title"])] += 1
            s = row["stations"].setdefault(code, {"plays": 0, "last": "", "show": ""})
            s["plays"] += 1
            if p["at"] >= s["last"]:
                s["last"], s["show"] = p["at"], p.get("show") or s["show"]
    for row in out.values():
        # The spelling most plays used (then the shortest: "Artist feat. X" loses to "Artist").
        spellings = row.pop("_spellings")
        row["artist"], row["title"] = max(spellings, key=lambda k: (spellings[k], -len(k[0]) - len(k[1]), k))
    return out


def _day_label(iso: str) -> str:
    dt = parse_time(iso)
    return f"{dt.day} {dt.strftime('%b')}" if dt else ""


def _names(codes: list[str]) -> str:
    names = [STATIONS.get(c, {}).get("name", c) for c in codes]
    return names[0] if len(names) == 1 else ", ".join(names[:-1]) + " and " + names[-1]


def radio_score(row: dict, liked: set[str]) -> float:
    """Distinct stations first; repeat plays count a little (at most 3 per station); a liked artist
    adds the same weight as one more play."""
    stations = row["stations"]
    capped = sum(min(s["plays"], 3) for s in stations.values())
    bonus = 0.3 if oc.match_fold(oc.split_primary_artist(row["artist"])) in liked else 0.0
    return len(stations) + 0.1 * min(capped, 8) + bonus


def primary_station(row: dict) -> str:
    """The station that played it most (then most recently): the one a breadth cap counts against."""
    return max(row["stations"].items(), key=lambda kv: (kv[1]["plays"] if kv[0] != "triplej" else 0, kv[1]["last"]))[0]


def select_candidates(
    agg: dict[str, dict],
    *,
    exclude: Callable[[str, str], bool],
    liked_artists: set[str],
    max_total: int,
    max_single: int,
    station_step: float = 0.35,
) -> list[dict]:
    """Pick tonight's radio candidates.

    Tracks heard on two or more stations come first, best radio_score first, with each
    further pick from the same primary station costing `station_step` so no station fills
    the top. One-offs then fill up to `max_single` slots, one station at a time in turn.
    A track only triple j played is left to the triple j source. One per artist.
    """
    pool = []
    for row in agg.values():
        codes = list(row["stations"])
        if codes == ["triplej"] or exclude(row["artist"], row["title"]):
            continue
        pool.append(dict(row, score=radio_score(row, liked_artists), primary=primary_station(row)))
    multi = [r for r in pool if len(r["stations"]) >= 2]
    single = [r for r in pool if len(r["stations"]) == 1]

    chosen: list[dict] = []
    artists: set[str] = set()
    per_station: Counter[str] = Counter()

    def artist_of(r: dict) -> str:
        return oc.match_fold(oc.split_primary_artist(r["artist"]))

    while multi and len(chosen) < max_total:
        best = max(multi, key=lambda r: (r["score"] - station_step * per_station[r["primary"]], r["artist"]))
        multi.remove(best)
        if artist_of(best) in artists:
            continue
        chosen.append(best)
        artists.add(artist_of(best))
        per_station[best["primary"]] += 1

    by_station: dict[str, list[dict]] = defaultdict(list)
    for r in sorted(single, key=lambda r: (-r["score"], -r["stations"][r["primary"]]["plays"], r["artist"])):
        by_station[r["primary"]].append(r)
    order = sorted(by_station, key=lambda c: (per_station[c], -by_station[c][0]["score"], c))
    singles = 0
    while order and singles < max_single and len(chosen) < max_total:
        for code in list(order):
            if singles >= max_single or len(chosen) >= max_total:
                break
            queue = by_station[code]
            while queue and artist_of(queue[0]) in artists:
                queue.pop(0)
            if not queue:
                order.remove(code)
                continue
            r = queue.pop(0)
            chosen.append(r)
            artists.add(artist_of(r))
            singles += 1

    return [to_candidate(r, rank=i) for i, r in enumerate(chosen)]


def to_candidate(r: dict, *, rank: int) -> dict:
    stations = sorted(r["stations"], key=lambda c: (-r["stations"][c]["plays"], c))
    last = max(s["last"] for s in r["stations"].values())
    n = len(stations)
    if n >= 2:
        why = f"Heard on {_names(stations)}, latest {_day_label(last)}"
        hint = min(0.92, 0.80 + 0.04 * (n - 2))
    else:
        why = f"Heard on {_names(stations)} {_day_label(last)}"
        hint = 0.70
    hint = round(hint - 0.002 * rank, 4)  # keep the breadth order inside a tier
    return {
        "artist": r["artist"],
        "title": r["title"],
        "album": r.get("album") or "",
        "source": f"radio:{r['primary']}",
        "why": why,
        "score_hint": hint,
        "stations": stations,
        "plays": sum(s["plays"] for s in r["stations"].values()),
        "heard": [
            {"station": c, "name": STATIONS.get(c, {}).get("name", c), "plays": r["stations"][c]["plays"],
             "last": r["stations"][c]["last"], "show": r["stations"][c]["show"]}
            for c in stations
        ],
        "radio_score": round(r["score"], 3),
    }
