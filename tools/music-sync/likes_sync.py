#!/usr/bin/env python3
"""Two-way sync of YouTube Music likes and Apple Music favourites.

Reads a local yt-dlp archive plus Music's library, writes a plan, and
optionally copies missing likes across. Nothing is ever un-liked or
un-favourited. Account writes run only with --apply; the default is a dry run.
"""

from __future__ import annotations

import argparse
import base64
import difflib
import json
import os
import random
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

FUZZY_MIN = 0.9
DEFAULT_LIMIT = 25
PAUSE_MIN = 2.0
PAUSE_MAX = 4.0
STOREFRONT = "au"
SONG_SEARCH_PARAMS = "EgWKAQIIAWoKEAkQBRAKEAMQBA=="

US = "\x1f"
RS = "\x1e"

JS_DENIED_MESSAGE = (
    "Chrome refused JavaScript from Apple Events. "
    "In Google Chrome turn on View > Developer > Allow JavaScript from Apple Events, then run again."
)
MUSIC_AUTH_MESSAGE = (
    "Apple Music in Chrome is not signed in (MusicKit isAuthorized stayed false). "
    "Open https://music.apple.com in Chrome's Default profile, sign in, then run again."
)
YOUTUBE_LOAD_MESSAGE = (
    "YouTube Music did not finish loading in Chrome. "
    "Open https://music.youtube.com while signed in, then run again."
)

# Decorations that mean the same recording. Stripped before punctuation so the
# brackets are still there to match. feat\.? must not eat the start of "feather".
_FEAT_PAREN = re.compile(
    r"(?i)\s*[\(\[]\s*(?:featuring|feat\.?|ft\.?)(?!\w)[^)\]]*[\)\]]"
)
_FEAT_TAIL = re.compile(r"(?i)\s+(?:featuring|feat\.?|ft\.?)(?!\w).*$")
_REMASTER_PAREN = re.compile(r"(?i)\s*[\(\[][^)\]]*\bremaster(?:ed)?\b[^)\]]*[\)\]]")
_REMASTER_DASH = re.compile(r"(?i)\s+-\s+[^\n]*\bremaster(?:ed)?\b.*$")
_OFFICIAL_PAREN = re.compile(r"(?i)\s*[\(\[]\s*official\b[^)\]]*[\)\]]")
_OFFICIAL_DASH = re.compile(r"(?i)\s+-\s+official\b.*$")
_LYRIC_VISUALIZER = re.compile(r"(?i)\s*[\(\[]\s*(?:lyric\s+video|visuali[sz]er)\s*[\)\]]")
_HD = re.compile(r"(?i)\s*[\[\(]\s*hd\s*[\]\)]")
_LIVE_AT = re.compile(r"(?i)\s*[\(\[]\s*live\s+at\b[^)\]]*[\)\]]")
# Festival tags such as "(Splendour In The Grass 2018)". A bare "(2016)" stays,
# so a year by itself can still tell two releases apart.
_YEAR_TAG = re.compile(
    r"(?i)\s*[\(\[](?=[^)\]]*[\w])[^)\]]*[A-Za-z][^)\]]*\b(?:19|20)\d{2}\b[^)\]]*[\)\]]"
)
_LAV = re.compile(r"(?i)\s*[\(\[][^)\]]*\blike\s+a\s+version\b[^)\]]*[\)\]]")
_LAV_FOR = re.compile(r"(?i)\s+for\s+like\s+a\s+version\b")
_TOPIC = re.compile(r"(?i)\s+-\s+topic\s*$")
_FILENAME = re.compile(
    r"^(?P<artist>.+?) - (?P<title>.+) \[(?P<video_id>[A-Za-z0-9_-]+)\]\.m4a$",
    re.IGNORECASE,
)
_QUOTES = "\"'“”‘’"
# Whole right-hand side of a split that is a tag, not a song title.
_DECORATION_ONLY = re.compile(
    r"(?:"
    r"official(?:\s+\w+)*|"
    r"lyric video|visuali[sz]er|hd|"
    r"(?:\d{4}\s+)?remaster(?:ed)?(?:\s+\d{4})?|"
    r"live(?:\s+at\b.*)?"
    r")"
)
# Joins between credited artists. "&", "and", and "x" need spaces so "R&B" and
# "band" stay one name. A comma does not.
_ARTIST_JOIN = re.compile(r"(?i)\s*(?:,|\s&\s|\s\band\b\s|\s\bx\b\s)\s*")
_COVER_LAV = re.compile(
    r"(?i)^(?P<artist>.+?)\s+covers?\s+.+?\s+"
    r"[\"“‘'](?P<title>.+?)[\"”’']"
    r"(?:\s+(?:featuring|feat\.?|ft\.?)(?!\w).+?)?"
    r"\s+for\s+like\s+a\s+version\b"
)
_PARENS = re.compile(r"[\(\[][^)\]]*[\)\]]")
# Phrase checks see brackets. "mix"/"mixes" does not, so "(Remix)" and
# "(2020 Mix)" stay songs. "mixtape" is a separate phrase.
_SKIP_PHRASES = (
    ("full mixtape", re.compile(r"(?i)\bfull\s+mixtapes?\b")),
    ("full album", re.compile(r"(?i)\bfull\s+albums?\b")),
    ("mixtape", re.compile(r"(?i)\bmix\s*tapes?\b")),
    ("dj set", re.compile(r"(?i)\bdj\s+sets?\b")),
    ("mix", re.compile(r"(?i)\bdj\s+mix(?:es)?\b")),
    ("boiler room", re.compile(r"(?i)\bboiler\s+room\b")),
    ("tiny desk", re.compile(r"(?i)\btiny\s+desk\b")),
    ("npr music", re.compile(r"(?i)\bnpr\s+music\b")),
    ("glastonbury", re.compile(r"(?i)\bglastonbury\b")),
    ("live set", re.compile(r"(?i)\blive\s+sets?\b")),
    ("songs remixed", re.compile(r"(?i)\b\d+\s+songs\b.*\bremixed\b")),
)
_MIX_WORD = re.compile(r"(?i)(?<![a-z])mix(?:es)?\b")
LONG_VIDEO_SECONDS = 12 * 60


def javascript_events_denied(text: str) -> bool:
    """Chrome's AppleScript error when View > Developer > Allow JavaScript from Apple Events is off."""
    low = (text or "").lower()
    return (
        "allow javascript from apple events" in low
        or "javascript through applescript" in low
        or "access not allowed" in low
        or "(-1723)" in low
    )


def explain_osascript_failure(text: str) -> str:
    if javascript_events_denied(text):
        return JS_DENIED_MESSAGE
    low = (text or "").lower()
    if "not authorized to send apple events" in low or "(-1743)" in low:
        return (
            "macOS blocked Apple Events. Allow this terminal to control Music and "
            "Google Chrome in System Settings > Privacy & Security > Automation, then run again."
        )
    cleaned = (text or "").strip()
    return cleaned or "osascript failed"


class Runners:
    """Side effects. Tests pass fakes; the defaults shell out to osascript, mdls, and ffprobe."""

    def __init__(
        self,
        osascript=None,
        mdls=None,
        ffprobe=None,
        which=None,
        sleep=None,
        clock=None,
        rng=None,
        monotonic=None,
    ):
        self.osascript = osascript or default_osascript
        self.mdls = mdls or default_mdls
        self.ffprobe = ffprobe or default_ffprobe
        self.which = which or shutil.which
        self.sleep = sleep or time.sleep
        self.clock = clock or now_iso
        self.rng = rng or random.Random()
        self.monotonic = monotonic or time.monotonic


def now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def state_dir() -> Path:
    raw = os.environ.get("MUSIC_SYNC_STATE")
    path = Path(raw).expanduser() if raw else Path.home() / ".local/state/music-sync"
    path.mkdir(parents=True, exist_ok=True)
    return path


def default_archive() -> Path:
    raw = os.environ.get("MUSIC_SYNC_ARCHIVE", str(Path.home() / "Projects/liked-music/archive.txt"))
    return Path(raw).expanduser()


def default_yt_dir() -> Path:
    raw = os.environ.get("MUSIC_SYNC_YT_DIR", str(Path.home() / "Music/YouTube Liked"))
    return Path(raw).expanduser()


def default_osascript(source: str) -> str:
    proc = subprocess.run(
        ["/usr/bin/osascript", "-"],
        input=source,
        text=True,
        capture_output=True,
        check=False,
    )
    combined = f"{proc.stderr or ''}\n{proc.stdout or ''}"
    if proc.returncode != 0:
        message = explain_osascript_failure(combined)
        if message == JS_DENIED_MESSAGE:
            raise SystemExit(message)
        raise RuntimeError(message)
    if javascript_events_denied(combined):
        raise SystemExit(JS_DENIED_MESSAGE)
    return proc.stdout or ""


def default_mdls(path: str) -> str:
    proc = subprocess.run(
        ["/usr/bin/mdls", "-name", "kMDItemTitle", "-name", "kMDItemAuthors", path],
        text=True,
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        return ""
    return proc.stdout or ""


def default_ffprobe(path: str) -> str:
    proc = subprocess.run(
        [
            "ffprobe",
            "-v",
            "quiet",
            "-print_format",
            "json",
            "-show_entries",
            "format_tags:stream_tags",
            path,
        ],
        text=True,
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        return ""
    return proc.stdout or ""


def collapse_spaced_dots(text: str) -> str:
    """'Fred again . .' and 'Fred again..' are the same name."""
    return re.sub(r"(?:\s*\.){2,}", lambda match: "." * match.group(0).count("."), text or "")


def normalise_field(value: str) -> str:
    text = collapse_spaced_dots(value or "").replace("\xa0", " ").lower().strip()
    text = (
        text.replace("\u2010", "-")
        .replace("\u2011", "-")
        .replace("\u2013", "-")
        .replace("\u2014", "-")
    )
    previous = None
    while previous != text:
        previous = text
        text = _FEAT_PAREN.sub("", text)
        text = _FEAT_TAIL.sub("", text)
        text = _REMASTER_PAREN.sub("", text)
        text = _REMASTER_DASH.sub("", text)
        text = _OFFICIAL_PAREN.sub("", text)
        text = _OFFICIAL_DASH.sub("", text)
        text = _LYRIC_VISUALIZER.sub("", text)
        text = _HD.sub("", text)
        text = _LIVE_AT.sub("", text)
        text = _YEAR_TAG.sub("", text)
        text = _LAV.sub("", text)
        text = _LAV_FOR.sub("", text)
        text = _TOPIC.sub("", text)
    text = text.replace("'", "").replace("\u2019", "").replace("\u2018", "")
    text = re.sub(r"[^\w\s]+", " ", text, flags=re.UNICODE)
    return re.sub(r"\s+", " ", text).strip()


def normalise(artist: str, title: str) -> tuple[str, str]:
    return normalise_field(artist), normalise_field(title)


def strip_wrapping_quotes(text: str) -> str:
    value = (text or "").strip()
    while len(value) >= 2 and value[0] in _QUOTES and value[-1] in _QUOTES:
        value = value[1:-1].strip()
    return value


def _decoration_only(text: str) -> bool:
    cleaned = normalise_field(text)
    if not cleaned:
        return True
    return _DECORATION_ONLY.fullmatch(cleaned) is not None


def split_artist_title(title: str) -> tuple[str, str] | None:
    """First top-level 'Artist - Title' in a video title.

    A hyphen needs spaces, so 'blink-182' stays intact. En and em dashes count
    with or without spaces. The right-hand side has to still be a title after
    tags are removed: 'Song - Remastered 2011' is not an artist credit.
    """
    text = (title or "").replace("\xa0", " ")
    depth = 0
    for index, char in enumerate(text):
        if char in "([{":
            depth += 1
            continue
        if char in ")]}":
            depth = max(0, depth - 1)
            continue
        if depth != 0 or char not in "-–—":
            continue
        if char == "-" and not (
            index > 0
            and text[index - 1].isspace()
            and index + 1 < len(text)
            and text[index + 1].isspace()
        ):
            continue
        left = text[:index].strip()
        right = strip_wrapping_quotes(text[index + 1 :].strip())
        if not left or _decoration_only(right):
            continue
        if not normalise_field(left) or not normalise_field(right):
            continue
        return left, right
    return None


def parse_lav_cover(title: str) -> tuple[str, str] | None:
    """'Artist cover Someone \\'Title\\' for Like A Version' -> (Artist, Title)."""
    text = (title or "").replace("\xa0", " ")
    if "like a version" not in text.lower():
        return None
    match = _COVER_LAV.search(text)
    if not match:
        return None
    artist = match.group("artist").strip()
    song = match.group("title").strip()
    if not artist or not song:
        return None
    return artist, song


def primary_artist(artist: str) -> str:
    """First credited name. 'De La Soul, MF DOOM' and a trailing comma both yield De La Soul."""
    text = collapse_spaced_dots(artist or "").strip().strip(",")
    if not text:
        return ""
    parts = [part.strip(" ,") for part in _ARTIST_JOIN.split(text)]
    parts = [part for part in parts if part]
    return parts[0] if parts else ""


def forms_for(track: dict) -> list[tuple[str, str]]:
    """Normalised (artist, title) readings. The original pair stays in the list as the fallback."""
    artist = track.get("artist") or ""
    title = track.get("title") or ""
    raws = [(artist, title)]
    embedded = split_artist_title(title)
    if embedded is not None:
        raws.append(embedded)
    cover = parse_lav_cover(title)
    if cover is not None:
        raws.append(cover)
    found: list[tuple[str, str]] = []
    seen: set[tuple[str, str]] = set()
    for raw_artist, raw_title in raws:
        names = [raw_artist]
        primary = primary_artist(raw_artist)
        if primary and primary != raw_artist:
            names.append(primary)
        for name in names:
            form = normalise(name, raw_title)
            if form[0] and form[1] and form not in seen:
                seen.add(form)
                found.append(form)
    return found


def _pair_score_prepared(
    left_forms: set[tuple[str, str]],
    right_forms: set[tuple[str, str]],
    left_norm: tuple[str, str],
    right_norm: tuple[str, str],
) -> float:
    if left_forms and right_forms and left_forms & right_forms:
        return 1.0
    left_artist, left_title = left_norm
    right_artist, right_title = right_norm
    if not left_artist or not left_title or not right_artist or not right_title:
        return 0.0
    if (left_artist, left_title) == (right_artist, right_title):
        return 1.0
    return difflib.SequenceMatcher(
        None, f"{left_artist} {left_title}", f"{right_artist} {right_title}"
    ).ratio()


def pair_score(left: dict, right: dict) -> float:
    """1.0 when any reading matches, else difflib on the original 'artist title'."""
    return _pair_score_prepared(
        set(forms_for(left)),
        set(forms_for(right)),
        normalise(left.get("artist") or "", left.get("title") or ""),
        normalise(right.get("artist") or "", right.get("title") or ""),
    )


def _phrase_reason(text: str) -> str | None:
    for reason, pattern in _SKIP_PHRASES:
        if pattern.search(text or ""):
            return reason
    outside = _PARENS.sub(" ", text or "")
    if _MIX_WORD.search(outside):
        return "mix"
    return None


def duration_seconds(raw) -> float | None:
    """Seconds when a length is known. Numbers are seconds; 'm:ss' and 'h:mm:ss' parse too."""
    if raw is None or raw is False:
        return None
    if isinstance(raw, (int, float)):
        if raw < 0:
            return None
        return float(raw)
    text = str(raw).strip()
    if not text:
        return None
    if re.fullmatch(r"\d+(?:\.\d+)?", text):
        return float(text)
    parts = text.split(":")
    if 2 <= len(parts) <= 3 and all(re.fullmatch(r"\d+(?:\.\d+)?", part) for part in parts):
        nums = [float(part) for part in parts]
        if len(nums) == 2:
            return nums[0] * 60 + nums[1]
        return nums[0] * 3600 + nums[1] * 60 + nums[2]
    return None


def skip_reason(track: dict) -> str | None:
    """Why this row is not a song. None means it stays in the match."""
    title = track.get("title") or ""
    artist = track.get("artist") or ""
    title_reason = _phrase_reason(title)
    if title_reason:
        return title_reason
    artist_reason = _phrase_reason(artist)
    # A channel named "The Mixtape Archive" can still upload one song.
    if artist_reason and not (artist_reason in {"mix", "mixtape"} and split_artist_title(title)):
        return artist_reason
    seconds = duration_seconds(track.get("duration"))
    if seconds is not None and seconds > LONG_VIDEO_SECONDS:
        return "longer than 12 minutes"
    return None


def _partition(tracks: list[dict], side: str) -> tuple[list[dict], list[dict]]:
    kept = []
    skipped = []
    for track in tracks:
        reason = skip_reason(track)
        if not reason:
            kept.append(track)
            continue
        row = public_yt(track) if side == "yt" else public_am(track)
        row["side"] = side
        row["reason"] = reason
        skipped.append(row)
    return kept, skipped


def build_plan(yt: list[dict], am_fav: list[dict]) -> dict:
    """Pair likes with favourites. Exact readings win, then the best fuzzy score >= 0.9.

    Readings are the original names, an Artist - Title pulled out of a channel
    upload, a Like A Version cover, and the primary artist when several names
    are joined. Mixes, sets, and videos longer than 12 minutes (when a duration
    is known) go to `skip` and are never applied. Each other track is used once.
    """
    yt_kept, yt_skip = _partition(yt, "yt")
    am_kept, am_skip = _partition(am_fav, "am")
    yt_forms = [set(forms_for(track)) for track in yt_kept]
    am_forms = [set(forms_for(track)) for track in am_kept]
    yt_norm = [normalise(track.get("artist") or "", track.get("title") or "") for track in yt_kept]
    am_norm = [normalise(track.get("artist") or "", track.get("title") or "") for track in am_kept]
    pairs = []
    for i, left_forms in enumerate(yt_forms):
        for j, right_forms in enumerate(am_forms):
            score = _pair_score_prepared(left_forms, right_forms, yt_norm[i], am_norm[j])
            if score >= FUZZY_MIN:
                pairs.append((score, i, j))
    pairs.sort(key=lambda item: (-item[0], item[1], item[2]))
    used_yt: set[int] = set()
    used_am: set[int] = set()
    matched = []
    for score, i, j in pairs:
        if i in used_yt or j in used_am:
            continue
        used_yt.add(i)
        used_am.add(j)
        matched.append(
            {
                "yt": public_yt(yt_kept[i]),
                "am": public_am(am_kept[j]),
                "how": "exact" if score == 1.0 else "fuzzy",
                "ratio": round(score, 4),
                "_i": i,
            }
        )
    matched.sort(key=lambda row: row["_i"])
    for row in matched:
        del row["_i"]
    return {
        "yt_only": [public_yt(yt_kept[i]) for i in range(len(yt_kept)) if i not in used_yt],
        "am_only": [public_am(am_kept[j]) for j in range(len(am_kept)) if j not in used_am],
        "matched": matched,
        "skip": yt_skip + am_skip,
    }


def public_yt(track: dict) -> dict:
    return {
        "videoId": track.get("videoId") or "",
        "title": track.get("title") or "",
        "artist": track.get("artist") or "",
    }


def public_am(track: dict) -> dict:
    return {
        "pid": track.get("pid") or "",
        "title": track.get("title") or "",
        "artist": track.get("artist") or "",
        "album": track.get("album") or "",
    }


def has_names(artist: str, title: str) -> bool:
    artist_name, title_name = normalise(artist, title)
    return bool(artist_name and title_name)


def pick_hit(artist: str, title: str, candidates: list[dict]) -> dict | None:
    """Choose a library or catalog row to write.

    The artist has to match after normalisation. A search hit from another artist
    is a no-match, not a guess. Title still has to clear the same 0.9 bar.
    """
    wanted = {"artist": artist, "title": title}
    want_artist, want_title = normalise(artist, title)
    if not want_artist or not want_title:
        return None
    best = None
    best_score = 0.0
    for candidate in candidates:
        got_artist, _got_title = normalise(candidate.get("artist") or "", candidate.get("title") or "")
        if got_artist != want_artist:
            continue
        score = pair_score(wanted, candidate)
        if score >= FUZZY_MIN and score > best_score:
            best = candidate
            best_score = score
    return best


def parse_archive(text: str) -> list[str]:
    """yt-dlp --download-archive lines: 'youtube <videoId>'."""
    ids = []
    for line in text.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[0].lower() == "youtube" and parts[1]:
            ids.append(parts[1])
    return ids


def parse_filename(name: str) -> dict:
    base = Path(name).name
    match = _FILENAME.match(base)
    if not match:
        return {"artist": "", "title": "", "videoId": ""}
    return {
        "artist": match.group("artist"),
        "title": match.group("title"),
        "videoId": match.group("video_id"),
    }


def _mdls_scalar(raw: str) -> str:
    text = (raw or "").strip()
    if not text or text in {"(null)", "(none)"}:
        return ""
    if text.startswith("("):
        return ""
    if len(text) >= 2 and text[0] == '"' and text[-1] == '"':
        return text[1:-1]
    return text


def parse_mdls(text: str) -> tuple[str, str]:
    """Spotlight's kMDItemTitle and the first kMDItemAuthors entry."""
    title = ""
    artist = ""
    title_match = re.search(r"^kMDItemTitle\s*=\s*(.*)$", text or "", re.MULTILINE)
    if title_match:
        title = _mdls_scalar(title_match.group(1))
    author_match = re.search(r"^kMDItemAuthors\s*=\s*(.*)$", text or "", re.MULTILINE)
    if not author_match:
        return title, artist
    raw = author_match.group(1).strip()
    if raw in {"(null)", "(none)"}:
        return title, ""
    if raw.startswith("("):
        block = []
        for line in (text or "").splitlines():
            if line.strip().startswith("kMDItemAuthors"):
                block.append(line)
                continue
            if block:
                block.append(line)
                if ")" in line:
                    break
        quoted = re.findall(r'"([^"]*)"', "\n".join(block))
        artist = quoted[0] if quoted else ""
        return title, artist
    return title, _mdls_scalar(raw)


def parse_ffprobe(text: str) -> tuple[str, str]:
    if not (text or "").strip():
        return "", ""
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        return "", ""
    tags: dict[str, str] = {}
    for key, value in ((data.get("format") or {}).get("tags") or {}).items():
        if isinstance(value, str):
            tags.setdefault(key.lower(), value)
    for stream in data.get("streams") or []:
        for key, value in (stream.get("tags") or {}).items():
            if isinstance(value, str):
                tags.setdefault(key.lower(), value)
    title = tags.get("title") or ""
    artist = tags.get("artist") or tags.get("album_artist") or ""
    return title, artist


def parse_library(text: str) -> list[dict]:
    """Bulk Music read: pid, name, artist, album, favorited, split on ASCII 31 / 30."""
    tracks = []
    raw = (text or "").strip()
    if not raw:
        return tracks
    for record in raw.split(RS):
        if not record.strip():
            continue
        parts = record.split(US)
        if len(parts) < 5 or not parts[0].strip():
            continue
        tracks.append(
            {
                "pid": parts[0].strip(),
                "title": parts[1].strip(),
                "artist": parts[2].strip(),
                "album": parts[3].strip(),
                "favorited": parts[4].strip().lower() == "true",
            }
        )
    return tracks


def favourites(tracks: list[dict]) -> list[dict]:
    return [public_am(track) for track in tracks if track.get("favorited")]


LIBRARY_SCRIPT = """on field(v)
  try
    if v is missing value then return ""
    return v as text
  on error
    return ""
  end try
end field
tell application "Music"
  set lib to library playlist 1
  set ids to persistent ID of every track of lib
  set ns to name of every track of lib
  set ars to artist of every track of lib
  set als to album of every track of lib
  set fs to favorited of every track of lib
end tell
set us to character id 31
set out to {}
repeat with i from 1 to count of ids
  set end of out to my field(item i of ids) & us & my field(item i of ns) & us & my field(item i of ars) & us & my field(item i of als) & us & my field(item i of fs)
end repeat
set AppleScript's text item delimiters to (character id 30)
return out as text
"""


def apple_quote(text: str) -> str:
    escaped = (text or "").replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def favorite_script(pid: str) -> str:
    # Only ever sets true. This sync does not un-favourite.
    quoted = apple_quote(pid)
    return (
        'tell application "Music"\n'
        f"set favorited of (first track of library playlist 1 whose persistent ID is {quoted}) to true\n"
        "end tell\n"
        'return "ok"\n'
    )


def collect_youtube(archive_path: Path, yt_dir: Path, runners: Runners) -> list[dict]:
    ids = parse_archive(archive_path.read_text(encoding="utf-8", errors="replace"))
    by_id: dict[str, dict] = {}
    if yt_dir.is_dir():
        use_ffprobe = bool(runners.which("ffprobe"))
        for path in sorted(yt_dir.iterdir()):
            if path.name.startswith(".") or path.suffix.lower() != ".m4a":
                continue
            parsed = parse_filename(path.name)
            video_id = parsed["videoId"]
            if not video_id:
                continue
            title, artist = "", ""
            if use_ffprobe:
                try:
                    title, artist = parse_ffprobe(runners.ffprobe(str(path)))
                except Exception:
                    title, artist = "", ""
            if not title or not artist:
                try:
                    mdls_title, mdls_artist = parse_mdls(runners.mdls(str(path)))
                except Exception:
                    mdls_title, mdls_artist = "", ""
                title = title or mdls_title
                artist = artist or mdls_artist
            # Tags win. The filename is the fallback Glancebar already understands.
            title = title or parsed["title"]
            artist = artist or parsed["artist"]
            by_id[video_id] = {"videoId": video_id, "title": title, "artist": artist}
    else:
        print(f"YouTube Liked folder not found: {yt_dir}", file=sys.stderr)
    seen = set()
    rows = []
    for video_id in ids:
        if video_id in seen:
            continue
        seen.add(video_id)
        rows.append(by_id.get(video_id) or {"videoId": video_id, "title": "", "artist": ""})
    return rows


def collect_library(runners: Runners) -> list[dict]:
    return parse_library(runners.osascript(LIBRARY_SCRIPT))


def write_json(path: Path, payload: dict) -> None:
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def load_applied_ok(path: Path) -> set[tuple[str, str]]:
    """Keys with any ok line. Errors stay eligible; a later success is enough to skip."""
    found: set[tuple[str, str]] = set()
    if not path.exists():
        return found
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        if record.get("result") == "ok" and record.get("side") and record.get("key"):
            found.add((str(record["side"]), str(record["key"])))
    return found


def append_applied(path: Path, record: dict) -> None:
    ordered = {key: record[key] for key in ("at", "side", "key", "action", "result", "ids")}
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(ordered, ensure_ascii=False) + "\n")


def track_key(side: str, item: dict) -> str:
    if side == "am":
        return str(item.get("videoId") or "")
    if side == "yt":
        return str(item.get("pid") or "")
    raise ValueError(f"unknown side {side}")


def pending_items(items: list[dict], side: str, applied_ok: set[tuple[str, str]], limit: int) -> list[dict]:
    chosen = []
    for item in items:
        key = track_key(side, item)
        if not key or (side, key) in applied_ok:
            continue
        chosen.append(item)
        if len(chosen) >= limit:
            break
    return chosen


def format_dry(side: str, item: dict) -> str:
    artist = item.get("artist") or ""
    title = item.get("title") or ""
    if side == "am":
        return (
            f"dry-run am {item.get('videoId') or ''} {artist} — {title}: "
            "favourite in Apple Music"
        )
    return f"dry-run yt {item.get('pid') or ''} {artist} — {title}: like on YouTube Music"


def run_apply(
    items: list[dict],
    *,
    side: str,
    limit: int,
    applied_ok: set[tuple[str, str]],
    perform,
    runners: Runners,
    record,
    dry_run: bool,
) -> tuple[list[dict], bool]:
    """Run one side. Skips keys already ok. Stops after three errors in a row.

    The pause is between writes, so a dry run and the last attempt do not sleep.
    """
    pending = pending_items(items, side, applied_ok, limit)
    if dry_run:
        for item in pending:
            print(format_dry(side, item))
        if not pending:
            print("nothing to do")
        else:
            print(f"dry-run {len(pending)} {side}; pass --apply to write")
        return [], False

    outcomes = []
    streak = 0
    stopped = False
    for index, item in enumerate(pending):
        key = track_key(side, item)
        try:
            raw = perform(item) or {}
        except SystemExit:
            raise
        except Exception as exc:
            raw = {"action": "write", "result": "error", "ids": {}}
            detail = f"{exc.__class__.__name__}: {exc}"
            print(f"{side} {key} failed: {detail[:300]}", file=sys.stderr)
        result = str(raw.get("result") or "error")
        if result not in {"ok", "no-match", "error"}:
            result = "error"
        ids = raw.get("ids") if isinstance(raw.get("ids"), dict) else {}
        row = {
            "at": runners.clock(),
            "side": side,
            "key": key,
            "action": str(raw.get("action") or "write"),
            "result": result,
            "ids": ids,
        }
        outcomes.append(row)
        if record:
            record(row)
        print(f"{row['side']} {row['key']} {row['action']} {row['result']}")
        if row["result"] == "error":
            streak += 1
        else:
            streak = 0
        if streak >= 3:
            stopped = True
            print("stopped after 3 consecutive errors", file=sys.stderr)
            break
        if index + 1 < len(pending):
            runners.sleep(runners.rng.uniform(PAUSE_MIN, PAUSE_MAX))
    if not outcomes:
        print("nothing to do")
    return outcomes, stopped


def js_wrapper(source: str) -> str:
    """Base64 so the AppleScript string does not have to escape the JavaScript.

    atob yields bytes; TextDecoder turns those back into the original source,
    including non-ASCII titles.
    """
    encoded = base64.b64encode(source.encode("utf-8")).decode("ascii")
    return (
        "eval(new TextDecoder().decode(Uint8Array.from(atob('"
        + encoded
        + "'),function(c){return c.charCodeAt(0);})))"
    )


def _js_call(wid: str, tid: str, source: str) -> str:
    # Chrome's verb is `execute <tab> javascript ...`. The `execute javascript ... in <tab>` form is
    # rejected with "Access not allowed" (-1723) even with Apple Events JavaScript on (1 Nov 2026).
    wrapper = js_wrapper(source)
    return (
        'tell application "Google Chrome"\n'
        f"set w to first window whose id is {wid}\n"
        f"set t to first tab of w whose id is {tid}\n"
        f'return execute t javascript "{wrapper}"\n'
        "end tell\n"
    )


def open_tab_script(url: str) -> str:
    # Reset the active tab so the new one stays in the background.
    return (
        'tell application "Google Chrome"\n'
        "if (count of windows) is 0 then make new window\n"
        "set w to window 1\n"
        "set wid to id of w\n"
        "set previousTab to active tab index of w\n"
        f'set t to make new tab at end of tabs of w with properties {{URL:"{url}"}}\n'
        "set tid to id of t\n"
        "try\n"
        "set active tab index of w to previousTab\n"
        "end try\n"
        'return (wid as text) & "," & (tid as text)\n'
        "end tell\n"
    )


def close_tab_script(wid: str, tid: str) -> str:
    return (
        'tell application "Google Chrome"\n'
        f"set w to first window whose id is {wid}\n"
        f"set t to first tab of w whose id is {tid}\n"
        "close t\n"
        'return "closed"\n'
        "end tell\n"
    )


def loading_script(wid: str, tid: str) -> str:
    return (
        'tell application "Google Chrome"\n'
        f"set w to first window whose id is {wid}\n"
        f"set t to first tab of w whose id is {tid}\n"
        'if loading of t then return "loading"\n'
        'return "ready"\n'
        "end tell\n"
    )


AUTH_JS = """(function(){
  try {
    if (!window.MusicKit || !MusicKit.getInstance) return "missing";
    var mk = MusicKit.getInstance();
    if (mk && mk.isAuthorized) return "yes";
    return "no";
  } catch (e) {
    return "missing";
  }
})()"""

YT_READY_JS = """(function(){
  if (document.querySelector("ytmusic-app")) return "yes";
  if (window.ytcfg) return "yes";
  return "no";
})()"""

POLL_JS = "(function(){var r=window.__ms;return r&&r.done?JSON.stringify(r):'';})()"


def catalog_search_js(term: str) -> str:
    quoted = json.dumps(term)
    return f"""(function(){{
  window.__ms = {{done:false}};
  var term = {quoted};
  var mk;
  try {{ mk = MusicKit.getInstance(); }}
  catch (e) {{ window.__ms = {{done:true, ok:false, error:String(e)}}; return "started"; }}
  var pending;
  try {{
    pending = mk.api.music("/v1/catalog/{STOREFRONT}/search", {{term: term, types: "songs", limit: 5}});
  }} catch (e2) {{ window.__ms = {{done:true, ok:false, error:String(e2)}}; return "started"; }}
  pending.then(function(res){{
    var list = [];
    try {{ list = res.results.songs.data; }} catch (e) {{}}
    if (!list || !list.length) {{
      try {{ list = res.data.results.songs.data; }} catch (e2) {{}}
    }}
    list = list || [];
    var songs = [];
    for (var i = 0; i < list.length; i++) {{
      var row = list[i] || {{}};
      var attrs = row.attributes || {{}};
      songs.push({{id: String(row.id || ""), title: attrs.name || "", artist: attrs.artistName || "", album: attrs.albumName || ""}});
    }}
    window.__ms = {{done:true, ok:true, songs: songs}};
  }}, function(err){{
    window.__ms = {{done:true, ok:false, error:String(err && err.message || err)}};
  }});
  return "started";
}})()"""


def catalog_love_js(song_id: str) -> str:
    quoted = json.dumps(song_id)
    # value 1 is love. There is no dislike and no library delete.
    return f"""(function(){{
  window.__ms = {{done:false}};
  var id = {quoted};
  var mk;
  try {{ mk = MusicKit.getInstance(); }}
  catch (e) {{ window.__ms = {{done:true, ok:false, error:String(e)}}; return "started"; }}
  var libraryPath = "/v1/me/library?ids[songs]=" + encodeURIComponent(id);
  var ratingPath = "/v1/me/ratings/songs/" + encodeURIComponent(id);
  var pending;
  try {{
    pending = mk.api.music(libraryPath, {{}}, {{fetchOptions: {{method: "POST"}}}});
  }} catch (e2) {{ window.__ms = {{done:true, ok:false, error:String(e2)}}; return "started"; }}
  pending.then(function(){{
    return mk.api.music(ratingPath, {{}}, {{fetchOptions: {{
      method: "PUT",
      headers: {{"Content-Type": "application/json"}},
      body: JSON.stringify({{type: "rating", attributes: {{value: 1}}}})
    }}}});
  }}).then(function(){{
    window.__ms = {{done:true, ok:true, id: id}};
  }}, function(err){{
    window.__ms = {{done:true, ok:false, error:String(err && err.message || err)}};
  }});
  return "started";
}})()"""


def _youtube_helpers_js() -> str:
    # Shared by search and like. SAPISIDHASH is the fallback when networkManager is missing.
    return r"""
  function cookieValue(name) {
    var parts = ("; " + document.cookie).split("; " + name + "=");
    if (parts.length < 2) return "";
    return decodeURIComponent(parts.pop().split(";").shift() || "");
  }
  function ytValue(key) {
    try {
      if (window.ytcfg && typeof ytcfg.get === "function") {
        var value = ytcfg.get(key);
        if (value) return value;
      }
    } catch (e) {}
    var data = window.ytcfg && ytcfg.data_;
    return data ? data[key] : null;
  }
  function sha1Hex(text) {
    return crypto.subtle.digest("SHA-1", new TextEncoder().encode(text)).then(function(buf) {
      var bytes = new Uint8Array(buf);
      var hex = "";
      for (var i = 0; i < bytes.length; i++) {
        var piece = bytes[i].toString(16);
        hex += piece.length === 1 ? "0" + piece : piece;
      }
      return hex;
    });
  }
  function sapisidHeader() {
    var sid = cookieValue("SAPISID");
    if (!sid) return Promise.reject(new Error("SAPISID cookie missing"));
    var stamp = Math.floor(Date.now() / 1000);
    var origin = "https://music.youtube.com";
    return sha1Hex(stamp + " " + sid + " " + origin).then(function(hex) {
      return "SAPISIDHASH " + stamp + "_" + hex;
    });
  }
  function innertube(path, payload) {
    var key = ytValue("INNERTUBE_API_KEY");
    var ctx = ytValue("INNERTUBE_CONTEXT");
    if (!key || !ctx) return Promise.reject(new Error("ytcfg missing"));
    return sapisidHeader().then(function(auth) {
      var body = {context: ctx};
      var names = Object.keys(payload || {});
      for (var i = 0; i < names.length; i++) body[names[i]] = payload[names[i]];
      var clientVersion = (ctx.client && ctx.client.clientVersion) || "";
      return fetch("/youtubei/v1" + path + "?prettyPrint=false&key=" + encodeURIComponent(key), {
        method: "POST",
        credentials: "include",
        headers: {
          "Content-Type": "application/json",
          "Authorization": auth,
          "X-Origin": "https://music.youtube.com",
          "X-Goog-AuthUser": "0",
          "X-YouTube-Client-Name": "67",
          "X-YouTube-Client-Version": clientVersion
        },
        body: JSON.stringify(body)
      }).then(function(res) {
        return res.text().then(function(text) {
          if (!res.ok) throw new Error("innertube " + res.status);
          try { return JSON.parse(text); } catch (e) { return {raw: text}; }
        });
      });
    });
  }
  function textOf(node) {
    if (!node) return "";
    if (typeof node === "string") return node;
    if (node.simpleText) return node.simpleText;
    if (node.runs) {
      var parts = [];
      for (var i = 0; i < node.runs.length; i++) parts.push(node.runs[i].text || "");
      return parts.join("");
    }
    if (node.text) return textOf(node.text);
    return "";
  }
  function extractSongs(root) {
    var data = root;
    if (typeof data === "string") {
      try { data = JSON.parse(data); } catch (e) { data = {}; }
    }
    var songs = [];
    var seen = {};
    var budget = 0;
    function walk(node, depth) {
      if (!node || typeof node !== "object" || depth > 18 || songs.length >= 5 || budget > 8000) return;
      budget++;
      var item = node.musicResponsiveListItemRenderer;
      if (item) {
        var videoId = "";
        try { videoId = item.playlistItemData.videoId || ""; } catch (e) {}
        if (!videoId) {
          try {
            videoId = item.overlay.musicItemThumbnailOverlayRenderer.content.musicPlayButtonRenderer.playNavigationEndpoint.watchEndpoint.videoId || "";
          } catch (e2) {}
        }
        if (!videoId) {
          try { videoId = item.navigationEndpoint.watchEndpoint.videoId || ""; } catch (e3) {}
        }
        var title = "";
        var artist = "";
        try {
          var cols = item.flexColumns || [];
          title = textOf(cols[0].musicResponsiveListItemFlexColumnRenderer.text);
          var second = textOf(cols[1].musicResponsiveListItemFlexColumnRenderer.text);
          artist = (second.split("\u2022")[0] || "").trim();
        } catch (e4) {}
        if (videoId && !seen[videoId]) {
          seen[videoId] = 1;
          songs.push({videoId: videoId, title: title, artist: artist});
        }
      }
      var keys = Object.keys(node);
      for (var k = 0; k < keys.length; k++) walk(node[keys[k]], depth + 1);
    }
    walk(data, 0);
    return songs;
  }
"""


def yt_search_js(query: str) -> str:
    quoted = json.dumps(query)
    params = json.dumps(SONG_SEARCH_PARAMS)
    helpers = _youtube_helpers_js()
    return f"""(function(){{
  window.__ms = {{done:false}};
  var query = {quoted};
  var params = {params};
  {helpers}
  function finish(songs) {{
    window.__ms = {{done:true, ok:true, songs: songs || []}};
  }}
  function fail(err) {{
    window.__ms = {{done:true, ok:false, error:String(err && err.message || err)}};
  }}
  var app = document.querySelector("ytmusic-app");
  function fromManager() {{
    if (!(app && app.networkManager && app.networkManager.fetch)) return Promise.reject(new Error("no networkManager"));
    return Promise.resolve(app.networkManager.fetch("/search", {{query: query, params: params}}));
  }}
  var started;
  try {{ started = fromManager(); }}
  catch (e) {{ started = Promise.reject(e); }}
  started.then(function(res) {{
    var songs = extractSongs(res);
    if (songs.length) return finish(songs);
    return innertube("/search", {{query: query, params: params}}).then(function(body) {{ finish(extractSongs(body)); }}, fail);
  }}, function() {{
    innertube("/search", {{query: query, params: params}}).then(function(body) {{ finish(extractSongs(body)); }}, fail);
  }});
  return "started";
}})()"""


def yt_like_js(video_id: str) -> str:
    quoted = json.dumps(video_id)
    helpers = _youtube_helpers_js()
    # /like/like only. removelike would undo a like, which this sync never does.
    return f"""(function(){{
  window.__ms = {{done:false}};
  var videoId = {quoted};
  {helpers}
  function ok() {{ window.__ms = {{done:true, ok:true, videoId: videoId}}; }}
  function fail(err) {{ window.__ms = {{done:true, ok:false, error:String(err && err.message || err)}}; }}
  var app = document.querySelector("ytmusic-app");
  var liked = null;
  try {{
    if (app && app.networkManager && app.networkManager.fetch) {{
      liked = Promise.resolve(app.networkManager.fetch("/like/like", {{target: {{videoId: videoId}}}}));
    }}
  }} catch (e) {{ liked = null; }}
  if (liked) {{
    liked.then(ok, function() {{
      innertube("/like/like", {{target: {{videoId: videoId}}}}).then(ok, fail);
    }});
  }} else {{
    innertube("/like/like", {{target: {{videoId: videoId}}}}).then(ok, fail);
  }}
  return "started";
}})()"""


def js_scalar(raw: str) -> str:
    text = (raw or "").strip()
    if len(text) >= 2 and text[0] == '"' and text[-1] == '"':
        try:
            loaded = json.loads(text)
        except json.JSONDecodeError:
            loaded = text
        if isinstance(loaded, str):
            text = loaded.strip()
    return text


def parse_js_json(raw: str) -> dict | None:
    text = js_scalar(raw)
    if not text or text == "missing value":
        return None
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        return None
    return data if isinstance(data, dict) else None


class ChromeSession:
    """One background tab. close() runs from the caller's finally, including on failure."""

    def __init__(self, runners: Runners):
        self.runners = runners
        self.wid = ""
        self.tid = ""

    def open(self, url: str) -> None:
        raw = self.runners.osascript(open_tab_script(url))
        parts = [part.strip() for part in (raw or "").strip().split(",")]
        if len(parts) < 2 or not re.fullmatch(r"\d+", parts[0]) or not re.fullmatch(r"\d+", parts[1]):
            raise RuntimeError(f"Chrome did not open a tab ({(raw or '').strip()[:200]})")
        self.wid, self.tid = parts[0], parts[1]

    def close(self) -> None:
        if not self.tid:
            return
        wid, tid = self.wid, self.tid
        self.tid = ""
        try:
            self.runners.osascript(close_tab_script(wid, tid))
        except Exception as exc:
            print(f"could not close Chrome tab: {exc}", file=sys.stderr)

    def exec_js(self, source: str) -> str:
        if not self.tid:
            raise RuntimeError("Chrome tab is not open")
        try:
            out = self.runners.osascript(_js_call(self.wid, self.tid, source))
        except SystemExit:
            raise
        except Exception as exc:
            if javascript_events_denied(str(exc)):
                raise SystemExit(JS_DENIED_MESSAGE) from exc
            raise
        if javascript_events_denied(out):
            raise SystemExit(JS_DENIED_MESSAGE)
        return out or ""

    def wait_until(self, probe, want: str, timeout: float, message: str) -> None:
        deadline = self.runners.monotonic() + timeout
        while True:
            try:
                raw = js_scalar(probe())
            except SystemExit:
                raise
            except Exception as exc:
                # A permission failure will not start working if we keep polling.
                text = str(exc)
                if javascript_events_denied(text) or "(-1743)" in text or "not authorized to send apple events" in text.lower():
                    raise SystemExit(explain_osascript_failure(text)) from exc
                raw = ""
            if raw == want:
                return
            if self.runners.monotonic() >= deadline:
                raise SystemExit(message)
            self.runners.sleep(0.4)

    def wait_loaded(self, timeout: float = 20.0) -> None:
        def probe():
            return self.runners.osascript(loading_script(self.wid, self.tid))

        self.wait_until(probe, "ready", timeout, "Chrome tab did not finish loading.")

    def wait_flag(self, source: str, timeout: float, message: str) -> None:
        self.wait_until(lambda: self.exec_js(source), "yes", timeout, message)

    def poll_job(self, timeout: float = 15.0) -> dict:
        deadline = self.runners.monotonic() + timeout
        while True:
            data = parse_js_json(self.exec_js(POLL_JS))
            if data is not None:
                return data
            if self.runners.monotonic() >= deadline:
                return {"done": True, "ok": False, "error": "timeout"}
            self.runners.sleep(0.4)


def _search_term(artist: str, title: str) -> str:
    return f"{artist or ''} {title or ''}".strip()[:240]


def apply_apple(items, runners: Runners, record, limit: int, applied_ok) -> tuple[list[dict], bool]:
    # Nothing queued: don't open Music. The read is the slow part, and it can launch the app.
    if not pending_items(items, "am", applied_ok, limit):
        return run_apply(
            items,
            side="am",
            limit=limit,
            applied_ok=applied_ok,
            perform=lambda _item: None,
            runners=runners,
            record=record,
            dry_run=False,
        )
    library = collect_library(runners)
    session: ChromeSession | None = None

    def ensure_session() -> ChromeSession:
        nonlocal session
        if session is None:
            session = ChromeSession(runners)
            session.open("https://music.apple.com")
            session.wait_loaded()
            # isAuthorized is polled after load, about 10s, not a tight loop inside the page.
            session.wait_flag(AUTH_JS, 10.0, MUSIC_AUTH_MESSAGE)
        return session

    def perform(item: dict) -> dict:
        video_id = item.get("videoId") or ""
        artist = item.get("artist") or ""
        title = item.get("title") or ""
        ids = {"videoId": video_id}
        if not has_names(artist, title):
            return {"action": "catalog-search", "result": "no-match", "ids": ids}
        library_hit = pick_hit(artist, title, library)
        if library_hit and library_hit.get("pid"):
            runners.osascript(favorite_script(library_hit["pid"]))
            return {
                "action": "set-favorited",
                "result": "ok",
                "ids": {"videoId": video_id, "pid": library_hit["pid"]},
            }
        songs = ensure_session().catalog_search_songs(_search_term(artist, title))
        chosen = pick_hit(artist, title, songs)
        if not chosen or not chosen.get("id"):
            return {"action": "catalog-search", "result": "no-match", "ids": ids}
        ensure_session().add_and_love(chosen["id"])
        return {
            "action": "catalog-add-love",
            "result": "ok",
            "ids": {"videoId": video_id, "catalogId": chosen["id"]},
        }

    try:
        return run_apply(
            items,
            side="am",
            limit=limit,
            applied_ok=applied_ok,
            perform=perform,
            runners=runners,
            record=record,
            dry_run=False,
        )
    finally:
        if session:
            session.close()


def apply_youtube(items, runners: Runners, record, limit: int, applied_ok) -> tuple[list[dict], bool]:
    session: ChromeSession | None = None

    def perform(item: dict) -> dict:
        nonlocal session
        pid = item.get("pid") or ""
        artist = item.get("artist") or ""
        title = item.get("title") or ""
        ids = {"pid": pid}
        if not has_names(artist, title):
            return {"action": "yt-search", "result": "no-match", "ids": ids}
        if session is None:
            session = ChromeSession(runners)
            session.open("https://music.youtube.com/")
            session.wait_loaded()
            session.wait_flag(YT_READY_JS, 15.0, YOUTUBE_LOAD_MESSAGE)
        songs = session.youtube_search(_search_term(artist, title))
        chosen = pick_hit(artist, title, songs)
        if not chosen or not chosen.get("videoId"):
            return {"action": "yt-search", "result": "no-match", "ids": ids}
        session.youtube_like(chosen["videoId"])
        return {
            "action": "yt-like",
            "result": "ok",
            "ids": {"pid": pid, "videoId": chosen["videoId"]},
        }

    try:
        return run_apply(
            items,
            side="yt",
            limit=limit,
            applied_ok=applied_ok,
            perform=perform,
            runners=runners,
            record=record,
            dry_run=False,
        )
    finally:
        if session:
            session.close()


def _songs_from(data: dict) -> list[dict]:
    songs = data.get("songs") if isinstance(data, dict) else None
    if not isinstance(songs, list):
        return []
    return [song for song in songs if isinstance(song, dict)]


def ChromeSession_catalog_search_songs(self, term: str) -> list[dict]:
    self.exec_js(catalog_search_js(term))
    data = self.poll_job()
    if not data.get("ok"):
        raise RuntimeError(data.get("error") or "catalog search failed")
    return _songs_from(data)


def ChromeSession_add_and_love(self, song_id: str) -> None:
    self.exec_js(catalog_love_js(song_id))
    data = self.poll_job()
    if not data.get("ok"):
        raise RuntimeError(data.get("error") or "catalog love failed")


def ChromeSession_youtube_search(self, query: str) -> list[dict]:
    self.exec_js(yt_search_js(query))
    data = self.poll_job()
    if not data.get("ok"):
        raise RuntimeError(data.get("error") or "youtube search failed")
    return _songs_from(data)


def ChromeSession_youtube_like(self, video_id: str) -> None:
    self.exec_js(yt_like_js(video_id))
    data = self.poll_job()
    if not data.get("ok"):
        raise RuntimeError(data.get("error") or "youtube like failed")


# Bound after the page scripts so a tab call can see those builders.
ChromeSession.catalog_search_songs = ChromeSession_catalog_search_songs
ChromeSession.add_and_love = ChromeSession_add_and_love
ChromeSession.youtube_search = ChromeSession_youtube_search
ChromeSession.youtube_like = ChromeSession_youtube_like


def cmd_inventory(args, runners: Runners) -> int:
    archive = Path(args.archive).expanduser() if args.archive else default_archive()
    yt_dir = Path(args.yt_dir).expanduser() if args.yt_dir else default_yt_dir()
    if not archive.is_file():
        raise SystemExit(f"YouTube archive not found: {archive}")
    youtube = collect_youtube(archive, yt_dir, runners)
    apple = favourites(collect_library(runners))
    payload = {"yt": youtube, "am_fav": apple}
    path = state_dir() / "inventory.json"
    write_json(path, payload)
    print(f"inventory yt {len(youtube)} am_fav {len(apple)} -> {path}")
    return 0


def cmd_plan(_args, _runners: Runners) -> int:
    path = state_dir() / "inventory.json"
    if not path.is_file():
        raise SystemExit(f"No inventory at {path}. Run inventory first.")
    inventory = json.loads(path.read_text(encoding="utf-8"))
    plan = build_plan(inventory.get("yt") or [], inventory.get("am_fav") or [])
    out = state_dir() / "plan.json"
    write_json(out, plan)
    print(
        f"plan matched {len(plan['matched'])} yt_only {len(plan['yt_only'])} "
        f"am_only {len(plan['am_only'])} skip {len(plan['skip'])} -> {out}"
    )
    return 0


def _load_plan() -> dict:
    path = state_dir() / "plan.json"
    if not path.is_file():
        raise SystemExit(f"No plan at {path}. Run plan first.")
    plan = json.loads(path.read_text(encoding="utf-8"))
    for key in ("yt_only", "am_only", "matched"):
        if key not in plan:
            raise SystemExit(f"plan is missing {key}")
    return plan


def cmd_apply(args, runners: Runners) -> int:
    if args.limit < 1:
        raise SystemExit("--limit must be at least 1")
    plan = _load_plan()
    side = args.side
    items = plan["yt_only"] if side == "am" else plan["am_only"]
    applied_path = state_dir() / "applied.jsonl"
    applied_ok = load_applied_ok(applied_path)
    if not args.apply:
        run_apply(
            items,
            side=side,
            limit=args.limit,
            applied_ok=applied_ok,
            perform=None,
            runners=runners,
            record=None,
            dry_run=True,
        )
        return 0

    def record(row: dict) -> None:
        append_applied(applied_path, row)

    if side == "am":
        _outcomes, stopped = apply_apple(items, runners, record, args.limit, applied_ok)
    else:
        _outcomes, stopped = apply_youtube(items, runners, record, args.limit, applied_ok)
    return 1 if stopped else 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Sync YouTube Music likes with Apple Music favourites. Dry-run unless --apply."
    )
    sub = parser.add_subparsers(dest="command", required=True)

    inventory = sub.add_parser("inventory", help="write state/inventory.json from the archive and Music")
    inventory.add_argument("--archive", help="yt-dlp archive.txt (default ~/Projects/liked-music/archive.txt)")
    inventory.add_argument("--yt-dir", help="m4a folder (default ~/Music/YouTube Liked)")
    inventory.set_defaults(func=cmd_inventory)

    plan = sub.add_parser("plan", help="write state/plan.json")
    plan.set_defaults(func=cmd_plan)

    apply = sub.add_parser("apply", help="favourite or like one side of the plan")
    apply.add_argument("--side", required=True, choices=("am", "yt"))
    apply.add_argument("--limit", type=int, default=DEFAULT_LIMIT, help="writes per run (default 25)")
    apply.add_argument(
        "--apply",
        action="store_true",
        help="perform account writes; without this flag, print the dry run",
    )
    apply.set_defaults(func=cmd_apply)
    return parser


def main(argv: list[str] | None = None, runners: Runners | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return args.func(args, runners or Runners())
    except RuntimeError as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BrokenPipeError:
        raise SystemExit(0)
