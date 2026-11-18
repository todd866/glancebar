#!/usr/bin/env python3
"""backcatalogue — older records (1960s to 2010s) as candidates for the music scout.

Three places older music comes from, each a quality signal of its own:

1. **Radio deep catalogue.** The station plays radio.py already keeps (KEXP, WFMU, NTS, 6 Music
   and the rest) include a lot of old records. A play is dated by the year the station gives
   (KEXP's release date, WFMU's year column), else by the earliest release of that song on the
   iTunes Search API, looked up within a per-night budget and remembered in `years.json`.
2. **Editorial canon.** Critics' lists and prizes, read from their Wikipedia pages (CANON_LISTS):
   the Grammy Hall of Fame, the Village Voice Pazz & Jop number ones, Rolling Stone's 500 top tens,
   and the Mercury, Polaris and Australian Music Prize winners and shortlists. The publishers' own
   list pages were not used; NOT_READ says why for each.
3. **Taste, older.** The scout's LLM step asked for older records near the artists he likes
   (scout.py builds that prompt and runs it through the same capacity guard).

Every page goes through radio.Fetcher (generic User-Agent, one request per 2 s per host, a disk
cache) and is read only when robots.txt allows it for every user agent this code could fairly be
taken for: `*`, our own token, and Anthropic's agents (ClaudeBot, Claude-User, anthropic-ai),
since the code was written by one. A list is fetched again after `refresh_days`.

Nothing here downloads audio: the scout's normal acquire step is the only way a candidate
becomes a file.
"""

from __future__ import annotations

import html
import json
import re
import urllib.parse
import urllib.robotparser
from collections import Counter, defaultdict
from datetime import datetime
from pathlib import Path
from typing import Any, Callable

import radio

oc = radio.oc

USER_AGENT = "music-list-reader/1.0 (public list pages only; one request per 2 s per host)"
UA_TOKEN = "music-list-reader"
# A site that turns these away has said it does not want this kind of reader.
AI_AGENTS = ("ClaudeBot", "Claude-User", "anthropic-ai")

WIKI = "https://en.wikipedia.org/wiki/"
DEFAULT_DECADES = ["1960s", "1970s", "1980s", "1990s", "2000s", "2010s"]

# id: name shown in `why`, page under WIKI, parser kind.
CANON_LISTS: dict[str, dict[str, str]] = {
    "grammy-hof-a-d": {"name": "Grammy Hall of Fame", "page": "List_of_Grammy_Hall_of_Fame_Award_recipients_(A–D)", "kind": "grammy_hof"},
    "grammy-hof-e-i": {"name": "Grammy Hall of Fame", "page": "List_of_Grammy_Hall_of_Fame_Award_recipients_(E–I)", "kind": "grammy_hof"},
    "grammy-hof-j-p": {"name": "Grammy Hall of Fame", "page": "List_of_Grammy_Hall_of_Fame_Award_recipients_(J–P)", "kind": "grammy_hof"},
    "grammy-hof-q-z": {"name": "Grammy Hall of Fame", "page": "List_of_Grammy_Hall_of_Fame_Award_recipients_(Q–Z)", "kind": "grammy_hof"},
    "pazz-jop": {"name": "Pazz & Jop", "page": "Pazz_&_Jop", "kind": "pazz_jop"},
    "rolling-stone-500": {"name": "Rolling Stone 500", "page": "Rolling_Stone's_500_Greatest_Songs_of_All_Time", "kind": "rs500"},
    "mercury": {"name": "Mercury Prize", "page": "Mercury_Prize", "kind": "prize"},
    "polaris": {"name": "Polaris Prize", "page": "Polaris_Music_Prize", "kind": "prize"},
    "amp": {"name": "Australian Music Prize", "page": "Australian_Music_Prize", "kind": "prize"},
}

# Checked 18 Nov 2026. Reported with every run so the gap is visible.
NOT_READ: dict[str, str] = {
    "pitchfork.com": "robots.txt disallows Claude-User and ClaudeBot",
    "rollingstone.com": "robots.txt disallows ClaudeBot and anthropic-ai (its top tens are read from Wikipedia)",
    "nme.com": "robots.txt disallows ClaudeBot and anthropic-ai",
    "theguardian.com": "robots.txt disallows Claude-User, ClaudeBot and anthropic-ai",
    "acclaimedmusic.net": "robots.txt disallows ClaudeBot and anthropic-ai",
    "allmusic.com": "answers 403 (Cloudflare challenge) to a plain request",
}

YEAR_TTL_DAYS = 30  # an undated lookup is tried again after this
WEEK = 7 * 86400.0


# --- small helpers --------------------------------------------------------------------------


def decade_of(year: int | None) -> str:
    return f"{int(year) // 10 * 10}s" if year else ""


def year_of(value: Any) -> int | None:
    """First plausible four-digit year in a value ("1992 (1st)", "2026-04-21T…", 1967)."""
    m = re.search(r"\b(19[0-9]{2}|20[0-9]{2})\b", str(value or ""))
    return int(m.group(1)) if m else None


def reconcile_year(listed: int | None, found: int | None, *, slack: int = 2) -> int | None:
    """A list's year is authoritative; the catalogue's is often a remaster or reissue. An earlier
    catalogue year within `slack` corrects a prize year (a 1995 prize for a 1994 album)."""
    if listed and found:
        return found if listed - slack <= found < listed else listed
    return listed or found


def artist_fold(artist: str) -> str:
    a = oc.match_fold(oc.split_primary_artist(artist or ""))
    return a[4:] if a.startswith("the ") else a


_ALBUM_TAIL = re.compile(r"\s*-\s*(?:single|ep)\s*$|\s*[\(\[][^\)\]]*[\)\]]\s*$", re.IGNORECASE)


def album_core(name: str) -> str:
    text = str(name or "")
    while True:
        cut = _ALBUM_TAIL.sub("", text).strip()
        if cut == text or not cut:
            return oc.match_fold(text.strip())
        text = cut


def album_key(artist: str, album: str) -> str:
    return f"{artist_fold(artist)}|{album_core(album)}"


# Kids, karaoke, covers and tributes, live and re-recorded versions. Checked on the list row and
# again on the catalogue hit (its track, album, artist and genre).
_EXCLUDE_ANYWHERE = re.compile(
    r"karaoke|tribute|made famous|originally performed|in the style of|as made popular|cover version"
    r"|kidz bop|for kids|kids' songs|nursery rhyme|rockabye baby|lullaby renditions|re-?recorded|sing-along",
    re.IGNORECASE,
)
_LIVE_TAG = re.compile(r"[\(\[]\s*live\b|\s-\s*live\b|\blive version\b|\bunplugged\b", re.IGNORECASE)
_LIVE_ALBUM = re.compile(r"^\s*live\s+(at|from|in|on)\b|\blive at\b|\blive from\b", re.IGNORECASE)
EXCLUDED_GENRES = {
    "children's music", "children's", "kids", "karaoke", "classical", "opera", "comedy", "spoken word",
    "musical show", "musical theatre", "musicals", "cast recording", "holiday", "christmas", "fitness & workout",
}


def excluded(*, artist: str = "", title: str = "", album: str = "", genre: str = "") -> str | None:
    """Why a row is not wanted (kids, karaoke, cover, tribute, live), or None."""
    g = str(genre or "").strip().lower()
    if g in EXCLUDED_GENRES or g.startswith("children"):
        return f"genre {genre}"
    for text in (artist, title, album):
        if text and _EXCLUDE_ANYWHERE.search(text):
            return f"excluded word in {text!r}"
    if _LIVE_TAG.search(title or "") or _LIVE_TAG.search(album or "") or _LIVE_ALBUM.search(album or ""):
        return "live version"
    return None


def hit_excluded(hit: dict) -> str | None:
    return excluded(
        artist=str(hit.get("artistName") or ""),
        title=str(hit.get("trackName") or ""),
        album=str(hit.get("collectionName") or ""),
        genre=str(hit.get("primaryGenreName") or ""),
    )


# --- robots.txt -----------------------------------------------------------------------------


class Robots:
    """robots.txt per host, fetched through the Fetcher (cached a week). A missing file allows."""

    def __init__(self, fetcher: radio.Fetcher, agents: tuple[str, ...] = (UA_TOKEN, "*") + AI_AGENTS):
        self.fetcher = fetcher
        self.agents = agents
        self._parsers: dict[str, urllib.robotparser.RobotFileParser | None] = {}

    def allowed(self, url: str) -> tuple[bool, str]:
        parts = urllib.parse.urlsplit(url)
        host = parts.netloc
        if host not in self._parsers:
            body = self.fetcher.get(f"{parts.scheme}://{host}/robots.txt", ttl=WEEK)
            if body is None:
                self._parsers[host] = None
            else:
                rp = urllib.robotparser.RobotFileParser()
                rp.parse(body.splitlines())
                self._parsers[host] = rp
        rp = self._parsers[host]
        if rp is None:
            return True, ""
        refused = [a for a in self.agents if not rp.can_fetch(a, url)]
        if refused:
            return False, f"robots.txt disallows {', '.join(refused)}"
        return True, ""


# --- Wikipedia tables (pure; each list has a fixture test) ----------------------------------

_HEADING = re.compile(r"<h([23])\b[^>]*>(.*?)</h\1>", re.S)
_TABLE = re.compile(r'<table\b[^>]*class="[^"]*wikitable[^"]*"[^>]*>(.*?)</table>', re.S)
_ROW = re.compile(r"<tr\b[^>]*>(.*?)</tr>", re.S)
_CELL = re.compile(r"<(th|td)\b([^>]*)>(.*?)</\1>", re.S)
_ITEM_SPLIT = re.compile(r"<li\b[^>]*>|<br\s*/?>", re.S)


def _text(fragment: str) -> str:
    fragment = re.sub(r"<sup\b.*?</sup>", "", fragment or "", flags=re.S)
    fragment = re.sub(r"<style\b.*?</style>", "", fragment, flags=re.S)
    return " ".join(html.unescape(re.sub(r"<[^>]+>", " ", fragment)).split())


def _tight(text: str) -> str:
    """Wikipedia's markup leaves spaces inside quotes and before commas: '" Respect "' → '"Respect"'."""
    text = re.sub(r'"\s+([^"]*?)\s+"', r'"\1"', text)
    return re.sub(r"\s+([,;:)])", r"\1", text).strip()


def wiki_tables(text: str) -> list[dict]:
    """Every wikitable on a page: {heading (nearest h2/h3 above), header [lower-case], rows}. A row
    is a list of cells {text, html}; rowspans are carried down into the rows they cover."""
    marks = [(m.start(), "h", m) for m in _HEADING.finditer(text)] + [(m.start(), "t", m) for m in _TABLE.finditer(text)]
    heading = ""
    out = []
    for _, kind, m in sorted(marks, key=lambda x: x[0]):
        if kind == "h":
            heading = _text(re.sub(r'<span class="mw-editsection.*', "", m.group(2), flags=re.S))
            continue
        header: list[str] = []
        rows: list[list[dict]] = []
        carry: dict[int, list] = {}  # column → [rows left, cell]
        for rm in _ROW.finditer(m.group(1)):
            cells = []
            for cm in _CELL.finditer(rm.group(1)):
                span = re.search(r'rowspan="?(\d+)', cm.group(2))
                cols = re.search(r'colspan="?(\d+)', cm.group(2))
                cells.append({"tag": cm.group(1), "html": cm.group(3), "text": _tight(_text(cm.group(3))),
                              "rowspan": int(span.group(1)) if span else 1, "colspan": int(cols.group(1)) if cols else 1})
            if not header and cells and all(c["tag"] == "th" for c in cells):
                header = [c["text"].lower() for c in cells]
                continue
            row: list[dict] = []
            col = 0
            pending = list(cells)
            while pending or any(k >= col for k in carry):
                if col in carry:
                    left, cell = carry[col]
                    row.append(cell)
                    if left <= 1:
                        del carry[col]
                    else:
                        carry[col][0] = left - 1
                    col += 1
                    continue
                if not pending:
                    col += 1
                    continue
                cell = pending.pop(0)
                for _ in range(cell["colspan"]):
                    row.append(cell)
                    if cell["rowspan"] > 1:
                        carry[col] = [cell["rowspan"] - 1, cell]
                    col += 1
            if row:
                rows.append(row)
        out.append({"heading": heading, "header": header, "rows": rows})
    return out


def _col(header: list[str], *names: str) -> int | None:
    for i, h in enumerate(header):
        if any(h == n or h.startswith(n) for n in names):
            return i
    return None


def _cell(row: list[dict], i: int | None) -> dict:
    return row[i] if i is not None and i < len(row) else {"text": "", "html": ""}


def _first_quoted(text: str) -> str:
    m = re.search(r'"([^"]+)"', text or "")
    return (m.group(1) if m else text or "").strip()


def entry(artist: str, title: str, year: int | None, *, kind: str, label: str, genre: str = "") -> dict:
    """One canon row: kind "song" (title is the song) or "album" (title is the album)."""
    return {"artist": radio._clean(artist), "title": radio._clean(title), "year": year, "kind": kind,
            "label": label, "genre": genre}


def parse_grammy_hof(text: str, name: str = "Grammy Hall of Fame") -> list[dict]:
    out = []
    for t in wiki_tables(text):
        h = t["header"]
        ti, ai, yi = _col(h, "title"), _col(h, "artist"), _col(h, "year of release", "year")
        gi, fi = _col(h, "genre"), _col(h, "format")
        if None in (ti, ai, yi):
            continue
        for row in t["rows"]:
            fmt = _cell(row, fi)["text"].lower()
            kind = "album" if "album" in fmt else "song"
            year = year_of(_cell(row, yi)["text"])
            title = _first_quoted(_cell(row, ti)["text"]) if kind == "song" else _cell(row, ti)["text"]
            label = f"{name} ({'album' if kind == 'album' else 'single'}, inducted {year_of(row[-1]['text']) or '?'})"
            out.append(entry(_cell(row, ai)["text"], title, year, kind=kind, label=label,
                             genre=_cell(row, gi)["text"]))
    return out


def parse_pazz_jop(text: str, name: str = "Pazz & Jop") -> list[dict]:
    """Only the two number-one tables ("Albums voted number one", "Singles voted number one")."""
    out = []
    for t in wiki_tables(text):
        head = t["heading"].lower()
        if "number one" not in head or not ("album" in head or "single" in head):
            continue
        kind = "song" if "single" in head else "album"
        h = t["header"]
        yi, ai = _col(h, "year"), _col(h, "artist")
        wi = _col(h, "single", "song") if kind == "song" else _col(h, "album")
        for row in t["rows"]:
            year = year_of(_cell(row, yi)["text"])
            what = _cell(row, wi)["text"]
            title = _first_quoted(what) if kind == "song" else what
            out.append(entry(_cell(row, ai)["text"], title, year, kind=kind,
                             label=f"{name} no. 1 {'single' if kind == 'song' else 'album'} {year}"))
    return out


def parse_rs500(text: str, name: str = "Rolling Stone 500") -> list[dict]:
    out = []
    for t in wiki_tables(text):
        h = t["header"]
        ri, ai, si, yi = _col(h, "rank"), _col(h, "artist"), _col(h, "song"), _col(h, "year")
        if None in (ai, si, yi):
            continue
        edition = year_of(t["heading"])
        for row in t["rows"]:
            rank = _cell(row, ri)["text"]
            label = f"{name} top ten" + (f" ({edition})" if edition else "") + (f", no. {rank}" if rank else "")
            out.append(entry(_cell(row, ai)["text"], _first_quoted(_cell(row, si)["text"]),
                             year_of(_cell(row, yi)["text"]), kind="song", label=label))
    return out


_PAIR_DASH = re.compile(r"\s+[–—-]\s+")


def _prize_pair(fragment: str) -> tuple[str, str] | None:
    """"Artist – <i>Album</i>" or 'Artist, "Album"' → (artist, album)."""
    text = _tight(_text(fragment))
    if not text:
        return None
    parts = _PAIR_DASH.split(text, maxsplit=1)
    if len(parts) == 2:
        return parts[0].strip(), parts[1].strip(' "')
    m = re.match(r'(.+?),\s*"([^"]+)"', text)
    if m:
        return m.group(1).strip(), m.group(2).strip()
    return None


def parse_prize(text: str, name: str) -> list[dict]:
    """A prize's results table: Year | Winner | Shortlisted… Tables without a shortlist (Polaris
    Heritage, which names a period and not a release year) are left out."""
    out = []
    for t in wiki_tables(text):
        h = t["header"]
        yi, wi, si = _col(h, "year"), _col(h, "winner"), _col(h, "shortlist")
        if None in (yi, wi, si):
            continue
        for row in t["rows"]:
            year = year_of(_cell(row, yi)["text"])
            for col, role in ((wi, "winner"), (si, "shortlist")):
                for frag in _ITEM_SPLIT.split(_cell(row, col)["html"]):
                    pair = _prize_pair(frag)
                    if pair:
                        out.append(entry(pair[0], pair[1], year, kind="album", label=f"{name} {role} {year}"))
    return out


PARSERS: dict[str, Callable[[str, str], list[dict]]] = {
    "grammy_hof": parse_grammy_hof,
    "pazz_jop": parse_pazz_jop,
    "rs500": parse_rs500,
    "prize": parse_prize,
}


def list_url(spec: dict) -> str:
    return WIKI + urllib.parse.quote(spec["page"], safe="()',&_")


def load_canon(
    fetcher: radio.Fetcher,
    cache_dir: Path,
    *,
    lists: list[str],
    now: datetime,
    refresh_days: float,
) -> tuple[list[dict], dict[str, dict]]:
    """Every canon entry from the lists named. A list parsed within `refresh_days` is read from
    `cache_dir/lists/<id>.json`; a list that cannot be read tonight falls back to its last copy."""
    robots = Robots(fetcher)
    entries: list[dict] = []
    report: dict[str, dict] = {}
    for lid in lists:
        spec = CANON_LISTS.get(lid)
        if not spec:
            report[lid] = {"entries": 0, "error": "unknown list"}
            continue
        path = cache_dir / "lists" / f"{lid}.json"
        cached: dict = {}
        if path.is_file():
            try:
                cached = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                cached = {}
        fetched_at = radio.parse_time(cached.get("fetched") or "")
        fresh = fetched_at and (now - fetched_at).total_seconds() < refresh_days * 86400
        rows = list(cached.get("entries") or [])
        error = None
        if not fresh:
            url = list_url(spec)
            try:
                ok, why = robots.allowed(url)
                if not ok:
                    error = why
                else:
                    body = fetcher.get(url, ttl=refresh_days * 86400)
                    if body is None:
                        error = "page not found"
                    else:
                        parsed = PARSERS[spec["kind"]](body, spec["name"])
                        if parsed:
                            rows = parsed
                            path.parent.mkdir(parents=True, exist_ok=True)
                            tmp = path.with_suffix(".tmp")
                            tmp.write_text(json.dumps({"fetched": radio.utc(now), "url": url, "entries": rows},
                                                      ensure_ascii=False), encoding="utf-8")
                            tmp.replace(path)
                        else:
                            error = "no entries parsed (page layout changed?)"
            except radio.FetchStop as exc:
                error = str(exc)
        for r in rows:
            entries.append(dict(r, list=lid))
        report[lid] = {"entries": len(rows), "error": error, **({"cached": True} if fresh else {})}
    return entries, report


# --- radio deep catalogue -------------------------------------------------------------------


def radio_plays(cache_dir: Path, stations: list[str], since: datetime) -> dict[str, list[dict]]:
    """The plays radio.py has already stored, by station (nothing is fetched here)."""
    out = {}
    for code in stations:
        st = radio.STATIONS.get(code)
        if not st or st["kind"] == "local":
            continue
        out[code] = radio.Store(cache_dir / "plays" / f"{code}.json").plays(since)
    return out


def station_years(plays: dict[str, list[dict]]) -> dict[str, int]:
    """Earliest year a station gave for each track (match_key)."""
    years: dict[str, int] = {}
    for rows in plays.values():
        for p in rows:
            y = p.get("year")
            if not y:
                continue
            k = radio.match_key(p.get("artist") or "", p.get("title") or "")
            years[k] = min(years.get(k, 9999), int(y))
    return years


class YearCache:
    """match_key → {year, at, track_id?}. An undated answer is kept YEAR_TTL_DAYS, then retried."""

    def __init__(self, path: Path):
        self.path = path
        self.rows: dict[str, dict] = {}
        if path.is_file():
            try:
                self.rows = json.loads(path.read_text(encoding="utf-8")) or {}
            except (OSError, json.JSONDecodeError):
                self.rows = {}

    def get(self, key: str, now: datetime) -> dict | None:
        row = self.rows.get(key)
        if not row:
            return None
        if row.get("year") is None:
            at = radio.parse_time(row.get("at") or "")
            if not at or (now - at).total_seconds() > YEAR_TTL_DAYS * 86400:
                return None
        return row

    def put(self, key: str, now: datetime, year: int | None, **extra: Any) -> None:
        self.rows[key] = {"year": year, "at": radio.utc(now), **{k: v for k, v in extra.items() if v is not None}}

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.rows, ensure_ascii=False), encoding="utf-8")
        tmp.replace(self.path)


_COMPILATION = re.compile(r"soundtrack|motion picture|greatest hits|best of|\bhits\b|collection|anthology"
                          r"|\bessential|compilation|retrospective|\bgold\b", re.IGNORECASE)
_REISSUE = re.compile(r"remaster|deluxe|anniversary|expanded|reissue|legacy edition|bonus track", re.IGNORECASE)


def is_compilation(hit: dict) -> bool:
    return (str(hit.get("collectionArtistName") or "").lower() == "various artists"
            or bool(_COMPILATION.search(str(hit.get("collectionName") or ""))))


def is_original(hit: dict) -> bool:
    """Not a compilation or soundtrack, not a remaster or anniversary edition: its date is the record's."""
    return not is_compilation(hit) and not _REISSUE.search(f"{hit.get('collectionName') or ''} {hit.get('trackName') or ''}")


def earliest_year(hits: list[dict]) -> int | None:
    """The record's year from the catalogue: the earliest ORIGINAL release. A compilation's or a
    reissue's date says nothing about the record (a soundtrack dated 1980 holds a 1984 song), so
    without an original the year is unknown."""
    years = [year_of(h.get("releaseDate")) for h in hits if is_original(h) and not hit_excluded(h)]
    years = [y for y in years if y]
    return min(years) if years else None


def best_hit(hits: list[dict]) -> dict | None:
    """The release to acquire: not excluded; an original first, then a reissue, then a compilation;
    the earliest of those."""
    ok = [h for h in hits if not hit_excluded(h)]
    if not ok:
        return None
    pool = [h for h in ok if is_original(h)] or [h for h in ok if not is_compilation(h)] or ok
    return min(pool, key=lambda h: (year_of(h.get("releaseDate")) or 9999, str(h.get("trackId") or "")))


# --- pool, allocation and selection ---------------------------------------------------------


def build_pool(
    *,
    canon: list[dict],
    radio_rows: dict[str, dict],
    radio_years: dict[str, int],
    llm_rows: list[dict],
    liked: set[str],
) -> dict[str, dict]:
    """Every older-music candidate keyed by match_key, its support merged: canon labels (a radio
    play from a canon album counts), stations that played it, and the LLM's reason."""
    pool: dict[str, dict] = {}
    canon_albums: dict[str, list[dict]] = defaultdict(list)

    def slot(artist: str, title: str, **base: Any) -> dict:
        key = radio.match_key(artist, title)
        row = pool.get(key)
        if row is None:
            row = pool[key] = {"key": key, "artist": artist, "title": title, "album": "", "kind": "song",
                               "year": None, "genre": "", "canon": [], "stations": {}, "llm": "", "track_id": None}
        for k, v in base.items():
            if v and not row.get(k):
                row[k] = v
        return row

    for e in canon:
        if e["kind"] == "album":
            canon_albums[album_key(e["artist"], e["title"])].append(e)
            row = slot(e["artist"], f"album:{e['title']}", album=e["title"], kind="album", year=e.get("year"),
                       genre=e.get("genre"))
        else:
            row = slot(e["artist"], e["title"], year=e.get("year"), genre=e.get("genre"))
        if e.get("year") and row.get("year") and e["year"] < row["year"]:
            row["year"] = e["year"]
        if e["label"] not in row["canon"]:
            row["canon"].append(e["label"])

    for key, r in radio_rows.items():
        row = slot(r["artist"], r["title"], album=r.get("album"))
        row["stations"] = {c: s["plays"] for c, s in r["stations"].items()}
        row["last_heard"] = max(s["last"] for s in r["stations"].values())
        y = radio_years.get(key)
        if y:
            row["year"] = min(row["year"] or 9999, y)
        if r.get("album"):
            for e in canon_albums.get(album_key(r["artist"], r["album"]), []):
                if e["label"] not in row["canon"]:
                    row["canon"].append(e["label"])
                row["year"] = row["year"] or e.get("year")

    for r in llm_rows:
        row = slot(r["artist"], r["title"], album=r.get("album"), track_id=r.get("track_id"))
        row["llm"] = r.get("why") or "taste match"
        row["year"] = row["year"] or r.get("year")
        if r.get("track_id"):
            row["track_id"] = r["track_id"]
        for e in canon_albums.get(album_key(r["artist"], r.get("album") or ""), []):
            if e["label"] not in row["canon"]:
                row["canon"].append(e["label"])

    for row in pool.values():
        row["decade"] = decade_of(row["year"])
        row["score"] = back_score(row, liked)
    return pool


def back_score(row: dict, liked: set[str]) -> float:
    """Canon lists, stations and the LLM each count; agreement between them counts most."""
    plays = sum(row["stations"].values())
    score = 1.0 * min(len(row["canon"]), 3) + 0.8 * min(len(row["stations"]), 3) + 0.05 * min(plays, 6)
    if row["llm"]:
        score += 0.7
    if artist_fold(row["artist"]) in liked:
        score += 0.3
    return round(score, 3)


def primary_kind(row: dict) -> str:
    if row["canon"]:
        return "canon"
    if row["stations"]:
        return "radio"
    return "llm"


def allocate(n: int, decades: list[str], deficits: dict[str, int], supply: dict[str, int]) -> dict[str, int]:
    """Split n slots over the decades in proportion to what each still needs this week, never
    more than a decade can supply; slots a thin decade cannot use go to the others."""
    slots = {d: 0 for d in decades}
    need = {d: max(0, int(deficits.get(d, 0))) for d in decades}
    left = n
    while left > 0:
        open_ = [d for d in decades if supply.get(d, 0) > slots[d] and need[d] > slots[d]]
        if not open_:
            open_ = [d for d in decades if supply.get(d, 0) > slots[d]]
            if not open_:
                break
        # The decade furthest behind (relative to what it needs) takes the next slot.
        best = max(open_, key=lambda d: (need[d] - slots[d], -decades.index(d)))
        slots[best] += 1
        left -= 1
    return slots


def order_decade(rows: list[dict]) -> list[dict]:
    """Best first, taking canon, radio and LLM rows in turn so one kind does not fill a decade."""
    by_kind: dict[str, list[dict]] = defaultdict(list)
    for r in sorted(rows, key=lambda r: (-r["score"], r["key"])):
        by_kind[primary_kind(r)].append(r)
    kinds = sorted(by_kind, key=lambda k: -by_kind[k][0]["score"])
    out = []
    while any(by_kind.values()):
        for k in kinds:
            if by_kind[k]:
                out.append(by_kind[k].pop(0))
    return out


def describe(row: dict) -> str:
    parts = []
    if row["canon"]:
        parts.append("; ".join(row["canon"][:2]))
    if row["stations"]:
        codes = sorted(row["stations"], key=lambda c: (-row["stations"][c], c))
        last = radio._day_label(row.get("last_heard") or "")
        parts.append(f"heard on {radio._names(codes)}" + (f", latest {last}" if last else ""))
    if row["llm"]:
        parts.append(row["llm"])
    year = f"{row['year']}" if row.get("year") else ""
    return (f"{year}: " if year else "") + "; ".join(parts)


def to_candidate(row: dict, hit: dict | None, *, rank: int) -> dict:
    year = row["year"]
    if hit is not None:
        found = year_of(hit.get("releaseDate"))
        year = reconcile_year(year, found) if row["canon"] else min(y for y in (year, found) if y) if (year or found) else None
    kind = primary_kind(row)
    title = hit.get("trackName") if hit else row["title"]
    out = {
        "artist": (hit or {}).get("artistName") or row["artist"],
        "title": title or row["title"],
        "album": (hit or {}).get("collectionName") or row.get("album") or "",
        "source": f"back:{kind}",
        "why": describe(dict(row, year=year)),
        "score_hint": round(min(0.9, 0.66 + 0.06 * row["score"]) - 0.002 * rank, 4),
        "year": year,
        "decade": decade_of(year),
        "era": "back",
        "back_score": row["score"],
    }
    if hit and hit.get("trackId"):
        out["track_id"] = hit["trackId"]
    elif row.get("track_id"):
        out["track_id"] = row["track_id"]
    if row["canon"]:
        out["canon"] = list(row["canon"])
    if row["stations"]:
        out["stations"] = sorted(row["stations"], key=lambda c: (-row["stations"][c], c))
        out["heard"] = [{"station": c, "name": radio.STATIONS.get(c, {}).get("name", c), "plays": row["stations"][c]}
                        for c in out["stations"]]
    return out
