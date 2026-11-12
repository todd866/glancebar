#!/usr/bin/python3
"""Everything a downloaded track says about itself: tags, identifiers, duration, cover art.

Owner rule (12 Nov 2026): every download keeps its metadata, album art included, and that
record lives with the masters on the M2's external drive.

Pure standard library (the M2 has no ffprobe or mutagen). Reads only the MP4 header atoms,
never the audio.

  trackmeta.py show FILE            print the metadata as JSON
  trackmeta.py check FILE...        exit 1 when a file lacks title, artist, album or cover art
  trackmeta.py cover FILE [DEST]    write the embedded cover beside the file (cover.jpg)
"""
from __future__ import annotations

import hashlib
import json
import struct
import sys
from pathlib import Path

TEXT_ATOMS = {
    b'\xa9nam': 'title', b'\xa9ART': 'artist', b'\xa9alb': 'album', b'aART': 'albumArtist',
    b'\xa9wrt': 'composer', b'\xa9gen': 'genre', b'\xa9day': 'date', b'cprt': 'copyright',
    b'soar': 'sortArtist', b'soal': 'sortAlbum', b'sonm': 'sortTitle', b'\xa9too': 'encoder',
}
FREEFORM = {'ISRC': 'isrc', 'UPC': 'upc', 'RELEASETIME': 'releaseTime', 'PERFORMER': 'performer',
            'LABEL': 'label', 'MusicBrainz Track Id': 'musicbrainzTrackId'}
REQUIRED = ('title', 'artist', 'album')
CONTAINERS = (b'moov', b'udta', b'meta', b'ilst', b'trak', b'mdia')
MAX_TEXT = 64 * 1024          # a tag longer than this is not a tag
MAX_ART = 64 * 1024 * 1024


def _boxes(f, start, end):
    """Yield (kind, body_start, box_end) for each box in [start, end). Stops on a malformed box."""
    pos = start
    while pos + 8 <= end:
        f.seek(pos)
        raw = f.read(8)
        if len(raw) != 8:
            return
        size, kind = struct.unpack('>I4s', raw)
        header = 8
        if size == 1:
            ext = f.read(8)
            if len(ext) != 8:
                return
            size, header = struct.unpack('>Q', ext)[0], 16
        if size == 0:
            size = end - pos
        if size < header or pos + size > end:
            return
        yield kind, pos + header, pos + size
        pos += size


def _data_payload(f, start, end, limit):
    """(type code, bytes) of the first `data` box in an ilst item."""
    for kind, body, box_end in _boxes(f, start, end):
        if kind == b'data' and box_end - body >= 8:
            f.seek(body)
            head = f.read(8)
            length = box_end - body - 8
            if length > limit:
                return struct.unpack('>I', head[:4])[0] & 0xFFFFFF, None
            return struct.unpack('>I', head[:4])[0] & 0xFFFFFF, f.read(length)
    return None, None


def _freeform(f, start, end):
    name = None
    for kind, body, box_end in _boxes(f, start, end):
        if kind == b'name' and 4 < box_end - body <= 260:
            f.seek(body + 4)
            name = f.read(box_end - body - 4).decode('utf-8', 'replace')
    code, payload = _data_payload(f, start, end, MAX_TEXT)
    return name, payload if code in (0, 1) else None


def mp4_duration(f, moov_start, moov_end):
    """Seconds from the movie header (mvhd), else the first track's mdhd."""
    def header_duration(body, box_end):
        f.seek(body)
        head = f.read(32)
        if len(head) < 20:
            return None
        if head[0] == 0:
            timescale, duration = struct.unpack('>II', head[12:20])
        elif head[0] == 1 and len(head) >= 32 and box_end - body >= 32:
            timescale = struct.unpack('>I', head[20:24])[0]
            duration = struct.unpack('>Q', head[24:32])[0]
        else:
            return None
        if not timescale or duration in (0, 0xFFFFFFFF, 0xFFFFFFFFFFFFFFFF):
            return None
        return round(duration / timescale, 3)

    fallback = None
    for kind, body, box_end in _boxes(f, moov_start, moov_end):
        if kind == b'mvhd':
            found = header_duration(body, box_end)
            if found:
                return found
        elif kind == b'trak' and fallback is None:
            for k2, b2, e2 in _boxes(f, body, box_end):
                if k2 == b'mdia':
                    for k3, b3, e3 in _boxes(f, b2, e2):
                        if k3 == b'mdhd':
                            fallback = header_duration(b3, e3)
    return fallback


def read_track_metadata(path, *, with_art_bytes=False):
    """Metadata of an MP4/M4A file. Never raises on a damaged file: returns what it could read,
    with 'error' set."""
    path = Path(path)
    meta: dict = {}
    art = None
    try:
        size = path.stat().st_size
        with path.open('rb') as f:
            for kind, body, box_end in _boxes(f, 0, size):
                if kind != b'moov':
                    continue
                duration = mp4_duration(f, body, box_end)
                if duration:
                    meta['durationSeconds'] = duration
                for k1, b1, e1 in _boxes(f, body, box_end):
                    if k1 != b'udta':
                        continue
                    for k2, b2, e2 in _boxes(f, b1, e1):
                        if k2 != b'meta':
                            continue
                        for k3, b3, e3 in _boxes(f, b2 + 4, e2):
                            if k3 != b'ilst':
                                continue
                            for item, ib, ie in _boxes(f, b3, e3):
                                if item in TEXT_ATOMS:
                                    code, payload = _data_payload(f, ib, ie, MAX_TEXT)
                                    if payload is not None and code in (0, 1):
                                        meta[TEXT_ATOMS[item]] = payload.decode('utf-8', 'replace').strip()
                                elif item in (b'trkn', b'disk'):
                                    _code, payload = _data_payload(f, ib, ie, 64)
                                    if payload and len(payload) >= 6:
                                        number, total = struct.unpack('>HH', payload[2:6])
                                        key = 'track' if item == b'trkn' else 'disc'
                                        if number:
                                            meta[key] = number
                                        if total:
                                            meta[key + 'Total'] = total
                                elif item == b'\xa9lyr':
                                    code, payload = _data_payload(f, ib, ie, 1024 * 1024)
                                    if payload:
                                        meta['lyrics'] = payload.decode('utf-8', 'replace')
                                elif item == b'covr' and art is None:
                                    code, payload = _data_payload(f, ib, ie, MAX_ART)
                                    if payload:
                                        art = (code, payload)
                                elif item == b'----':
                                    name, payload = _freeform(f, ib, ie)
                                    if name in FREEFORM and payload:
                                        meta[FREEFORM[name]] = payload.decode('utf-8', 'replace').strip()
    except (OSError, struct.error, ValueError) as exc:
        meta['error'] = f'{type(exc).__name__}: {exc}'
    if art:
        code, payload = art
        fmt = 'png' if code == 14 or payload[:8] == b'\x89PNG\r\n\x1a\n' else 'jpeg'
        meta['art'] = {'format': fmt, 'bytes': len(payload), 'sha256': hashlib.sha256(payload).hexdigest()}
        if with_art_bytes:
            meta['artBytes'] = payload
    return meta


def metadata_gaps(meta):
    """What a complete download must have and this one lacks."""
    gaps = [key for key in REQUIRED if not str(meta.get(key) or '').strip()]
    if not (meta.get('art') or {}).get('bytes'):
        gaps.append('art')
    if not meta.get('durationSeconds'):
        gaps.append('duration')
    return gaps


def catalogue_metadata(meta):
    """The part of the metadata kept in the catalogue: everything except the lyrics text and
    the picture bytes (the catalogue says whether the file has them)."""
    out = {k: v for k, v in meta.items() if k not in ('lyrics', 'artBytes', 'error', 'durationSeconds')}
    if meta.get('lyrics'):
        out['hasLyrics'] = True
    return out


def ensure_cover_file(path, dest=None):
    """Write the embedded cover next to the track (cover.jpg / cover.png) unless a cover file
    is already there. Returns the cover's path, or None when the track has no embedded art."""
    path = Path(path)
    folder = path.parent
    for name in ('cover.jpg', 'cover.jpeg', 'cover.png'):
        if dest is None and (folder / name).is_file() and (folder / name).stat().st_size > 0:
            return folder / name
    meta = read_track_metadata(path, with_art_bytes=True)
    payload = meta.get('artBytes')
    if not payload:
        return None
    target = Path(dest) if dest else folder / ('cover.png' if meta['art']['format'] == 'png' else 'cover.jpg')
    tmp = target.with_name(target.name + '.part')
    tmp.write_bytes(payload)
    tmp.replace(target)
    return target


def check_download(path):
    """Run after every download: make sure the cover file exists and report what is missing."""
    meta = read_track_metadata(path)
    gaps = metadata_gaps(meta)
    cover = None
    try:
        cover = ensure_cover_file(path)
    except OSError as exc:
        gaps.append(f'cover file: {exc}')
    return {'ok': not gaps, 'gaps': gaps, 'cover': str(cover) if cover else None,
            'isrc': meta.get('isrc'), 'durationSeconds': meta.get('durationSeconds')}


def main(argv):
    if len(argv) < 3 or argv[1] not in ('show', 'check', 'cover'):
        print(__doc__, file=sys.stderr)
        return 64
    if argv[1] == 'show':
        print(json.dumps(read_track_metadata(argv[2]), indent=2, ensure_ascii=False))
        return 0
    if argv[1] == 'cover':
        out = ensure_cover_file(argv[2], argv[3] if len(argv) > 3 else None)
        print(out or 'no embedded cover')
        return 0 if out else 1
    bad = 0
    for name in argv[2:]:
        gaps = metadata_gaps(read_track_metadata(name))
        if gaps:
            bad += 1
            print(f'{name}: missing {", ".join(gaps)}')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
