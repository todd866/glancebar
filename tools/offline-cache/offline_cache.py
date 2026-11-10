#!/usr/bin/env python3
"""Exact, bounded offline playlist audit/preparation. No network or player calls."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import stat
import struct
import tempfile
import time
import unicodedata

HOME = Path.home()
BASE = HOME / 'Library/Application Support/Glancebar/mix'
CACHE = HOME / 'Music/Glancebar Offline'
MUSIC_LIBRARY_CONFIG = HOME / '.config/glancebar/music-library.json'
DEFAULT_HOT_DIR = HOME / 'Music/Glancebar Lossless'
FLOOR = 150_000_000_000  # M5 placement.toml floor_gb, decimal GB; never lower.
AUDIO = {'.m4a', '.mp3', '.flac', '.wav', '.aiff', '.aif', '.aac', '.alac', '.mp4'}


def music_library_hot_dir(config=MUSIC_LIBRARY_CONFIG):
    try:
        doc = json.loads(config.expanduser().read_text())
        raw = doc.get('hot_dir') or DEFAULT_HOT_DIR
        hot = Path(str(raw)).expanduser()
        return hot if hot.is_absolute() else DEFAULT_HOT_DIR
    except (OSError, ValueError, TypeError, json.JSONDecodeError):
        return DEFAULT_HOT_DIR


def default_audio_roots():
    hot = music_library_hot_dir()
    roots = [hot, HOME / 'Music/YouTube Liked', HOME / 'Music/Glancebar Radio', CACHE]
    out = []
    seen = set()
    for root in roots:
        key = str(root.expanduser())
        if key not in seen:
            seen.add(key)
            out.append(root)
    return out


def normal(value):
    # Do not remove punctuation, live/remaster/version qualifiers or collaborators.
    return ' '.join(unicodedata.normalize('NFC', str(value or '')).casefold().split())


def identity(row):
    return tuple(normal(row.get(k)) for k in ('artist', 'title', 'album'))


def local_file(path):
    p = Path(path).expanduser()
    # Refuse cloud placeholders, remote mounts and symlink redirects, including parents.
    if not p.is_absolute() or any(x.is_symlink() for x in (p, *p.parents)):
        raise ValueError('not a direct absolute local file')
    if str(p).startswith(('/Volumes/', '/Network/', '/net/')) or any(x in p.parts for x in ('Mobile Documents', 'CloudStorage')):
        raise ValueError('remote, removable or evictable location')
    s = p.stat()
    if not stat.S_ISREG(s.st_mode) or s.st_size <= 0 or p.suffix.lower() not in AUDIO:
        raise ValueError('missing, empty or unsupported audio file')
    if getattr(s, 'st_flags', 0) & 0x40000000:  # SF_DATALESS, Darwin
        raise ValueError('dataless placeholder')
    return p, s


def fingerprint(s):
    # ctime also invalidates cache when bytes are rewritten then mtime restored.
    return [str(s.st_dev), str(s.st_ino), s.st_size, str(s.st_mtime_ns), str(s.st_ctime_ns)]


def verified(path, verification_cache=None):
    p, before = local_file(path)
    stamp = fingerprint(before)
    previous = (verification_cache or {}).get(str(p), {})
    info = previous.get('info', {})
    if (previous.get('validationVersion') == 3 and previous.get('stamp') == stamp and isinstance(info.get('sha256'), str)
            and len(info['sha256']) == 64 and info.get('path') == str(p)
            and info.get('sizeBytes') == before.st_size
            and info.get('mtimeNs') == str(before.st_mtime_ns)
            and info.get('inode') == str(before.st_ino)
            and isinstance(info.get('embeddedTags'), dict)):
        return dict(info)
    embedded = {}
    if p.suffix.lower() in ('.m4a', '.mp4'):
        embedded = mp4_tags(p)  # Check protected sample entries even for explicit ID mappings.
    h = hashlib.sha256()
    with p.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    after = p.stat()
    if stamp != fingerprint(after):
        raise ValueError('source changed during verification')
    info = {'path': str(p), 'sizeBytes': after.st_size, 'sha256': h.hexdigest(),
            'mtimeNs': str(after.st_mtime_ns), 'inode': str(after.st_ino), 'embeddedTags': embedded}
    if verification_cache is not None:
        verification_cache[str(p)] = {'validationVersion': 3, 'stamp': stamp, 'info': info}
    return info


def mp4_tags(path):
    """Read bounded standard iTunes text atoms, skipping media bytes entirely."""
    tags = {}
    structure = {'ftyp': False, 'audio': False, 'mdat': False}
    audio_codecs = {b'mp4a', b'alac', b'fLaC', b'Opus', b'ac-3', b'ec-3', b'sowt', b'twos', b'lpcm'}
    names = {b'\xa9nam': 'title', b'\xa9ART': 'artist', b'\xa9alb': 'album'}
    with path.open('rb') as f:
        def walk(start, end, depth=0, parents=()):
            if depth > 8 or start > end:
                raise ValueError('malformed MP4 container')
            pos = start
            while pos + 8 <= end:
                f.seek(pos)
                raw = f.read(8)
                if len(raw) != 8:
                    raise ValueError('truncated MP4 box')
                size, kind = struct.unpack('>I4s', raw)
                header = 8
                if size == 1:
                    ext = f.read(8)
                    if len(ext) != 8:
                        raise ValueError('truncated extended MP4 box')
                    size, header = struct.unpack('>Q', ext)[0], 16
                if size == 0:
                    size = end - pos
                if size < header or pos + size > end:
                    raise ValueError('malformed MP4 box size')
                body = pos + header
                if not parents and kind == b'ftyp':
                    if size - header < 8:
                        raise ValueError('malformed MP4 file type')
                    structure['ftyp'] = True
                if not parents and kind == b'mdat' and size > header:
                    structure['mdat'] = True
                if kind in (b'moov', b'udta', b'ilst', b'meta', b'trak', b'mdia', b'minf', b'stbl'):
                    walk(body + (4 if kind == b'meta' else 0), pos + size, depth + 1, parents + (kind,))
                elif kind == b'stsd':
                    f.seek(body)
                    prefix = f.read(8)
                    if len(prefix) != 8 or body + 8 > pos + size:
                        raise ValueError('malformed sample description')
                    count = struct.unpack('>I', prefix[4:])[0]
                    entry = body + 8
                    for _ in range(count):
                        if entry + 8 > pos + size:
                            raise ValueError('malformed sample description')
                        f.seek(entry)
                        length, codec = struct.unpack('>I4s', f.read(8))
                        if length < 8 or entry + length > pos + size:
                            raise ValueError('malformed sample description')
                        if codec in (b'drms', b'enca', b'encv'):
                            raise ValueError('protected media sample entry')
                        if codec in audio_codecs:
                            if length < 36:
                                raise ValueError('truncated audio sample entry')
                            if parents == (b'moov', b'trak', b'mdia', b'minf', b'stbl'):
                                structure['audio'] = True
                        entry += length
                    if entry != pos + size:
                        raise ValueError('malformed sample description trailing bytes')
                elif kind in names and size <= 65536:
                    f.seek(body)
                    data = f.read(size - header)
                    if len(data) >= 16 and data[4:8] == b'data':
                        tags[names[kind]] = data[16:].decode('utf-8', errors='strict').rstrip('\0')
                pos += size
            if pos != end:
                raise ValueError('truncated MP4 box header')
        walk(0, path.stat().st_size)
    if not all(structure.values()):
        raise ValueError('MP4 requires file type, audio sample description and nonempty media data')
    return tags


def inventory(roots, index=None, cached=None):
    cached = cached if cached is not None else {}
    fresh = {}
    result = []
    if index:
        document = json.loads(Path(index).read_text())
        result.extend(document['tracks'])
    for root in roots:
        root = Path(root).expanduser()
        if not root.is_dir() or root.is_symlink():
            continue
        for p in sorted(root.rglob('*')):
            if p.suffix.lower() not in ('.m4a', '.mp4'):
                continue
            try:
                local_file(p)
                stamp = fingerprint(p.stat())
                old = cached.get(str(p), {})
                row = old['tags'] if old.get('stamp') == stamp else mp4_tags(p)
                fresh[str(p)] = {'stamp': stamp, 'tags': row}
                if all(identity(row)):
                    result.append(dict(row, path=str(p)))
            except (OSError, ValueError, UnicodeError):
                pass
    cached.clear()
    cached.update(fresh)
    return result


def select(track, sources, verification_cache=None, hot_dir=None):
    hot_dir = Path(hot_dir).expanduser().resolve() if hot_dir else music_library_hot_dir().resolve()
    candidates = []
    for row in sources:
        # Explicit persistent-ID binding, with no contradictory supplied metadata.
        exact_id = bool(row.get('id')) and row['id'] == track['id']
        mismatch = any(normal(row.get(k)) and normal(track.get(k)) and normal(row[k]) != normal(track[k])
                       for k in ('artist', 'title', 'album'))
        exact_tags = all(identity(track)) and identity(track) == identity(row)
        if (exact_id and not mismatch) or exact_tags:
            candidates.append(row)
    paths = {str(row.get('path', '')) for row in candidates}
    if len(paths) > 1:
        # Only byte-identical, independently validated files can collapse. Never
        # pick among different recordings merely because their text tags match.
        try:
            checks = [verified(path, verification_cache) for path in sorted(paths)]
        except (OSError, ValueError):
            return None, 'ambiguous exact match'
        if len({(row['sha256'], row['sizeBytes']) for row in checks}) != 1:
            return None, 'ambiguous exact match'
        def rank(path):
            p = Path(path)
            try:
                under_hot = p.resolve().is_relative_to(hot_dir)
            except (OSError, ValueError):
                under_hot = False
            return (not under_hot, p.is_relative_to(CACHE), path)

        preferred = sorted(paths, key=rank)[0]
        return next(row for row in candidates if row.get('path') == preferred), None
    if not paths:
        return None, 'no exact recording match'
    return candidates[0], None


def physical_free(path):
    p = Path(path)
    while not p.exists():
        p = p.parent
    s = os.statvfs(p)
    # statvfs free blocks, not Foundation's purgeable-inclusive "important usage".
    return min(s.f_bavail, s.f_bfree) * s.f_frsize


def policy_floor(path=HOME / '.config/fleet/placement.toml'):
    # Python >=3.11 reads the live policy. Older system Python fails closed for copy.
    import tomllib
    policy = tomllib.loads(Path(path).read_text())
    host = next(h for h in policy['host'] if h['id'] == 'm5')
    return max(FLOOR, int(float(host['floor_gb']) * 1_000_000_000))


def copy_verified(info, cache, floor):
    cache = Path(cache).expanduser()
    if not cache.is_absolute() or any(p.is_symlink() for p in (cache, *cache.parents)):
        raise ValueError('unsafe cache directory')
    target = cache / (info['sha256'] + Path(info['path']).suffix.lower())
    if target.exists():
        existing = verified(target)
        if existing['sha256'] != info['sha256']:
            raise ValueError('cache collision or corruption; existing bytes preserved')
        return existing
    if physical_free(cache) - info['sizeBytes'] < floor:
        raise ValueError('storage floor blocks copy')
    cache.mkdir(parents=True, exist_ok=True)
    temp = None
    try:
        with tempfile.NamedTemporaryFile(dir=cache, prefix='.copy-', delete=False) as out:
            temp = Path(out.name)
            with open(info['path'], 'rb') as source:
                while True:
                    block = source.read(1024 * 1024)
                    if not block:
                        break
                    if physical_free(cache) - len(block) < floor:
                        raise ValueError('storage floor blocks copy')
                    out.write(block)
                out.flush()
                os.fsync(out.fileno())
        h = hashlib.sha256()
        with temp.open('rb') as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b''):
                h.update(block)
        if temp.stat().st_size != info['sizeBytes'] or h.hexdigest() != info['sha256']:
            raise ValueError('copy integrity failure')
        # Atomic no-clobber publication. Never overwrite or delete originals/cache files.
        os.link(temp, target)
        return verified(target)
    finally:
        if temp is not None:
            temp.unlink(missing_ok=True)  # Only this command's unpublished temporary file.


def audit(requests, sources, copy=False, cache=CACHE, floor=FLOOR, verification_cache=None, hot_dir=None):
    hot_dir = hot_dir if hot_dir is not None else music_library_hot_dir()
    if requests.get('schemaVersion') != 1 or not isinstance(requests.get('playlists'), list):
        raise ValueError('unsupported request schema')
    output = {'schemaVersion': 1, 'generatedAt': int(time.time()), 'playlists': []}
    memo = {}
    keys = set()
    for playlist in requests['playlists']:
        key = playlist['key']
        if not isinstance(key, str) or not key or key in keys:
            raise ValueError('playlist keys must be unique nonempty strings')
        keys.add(key)
        tracks = playlist['tracks']
        result = {'key': key, 'title': playlist.get('title', ''), 'requestedTrackIDs': [], 'requestedTracks': [], 'tracks': [], 'missing': []}
        for track in tracks:
            if not isinstance(track.get('id'), str) or not track['id']:
                raise ValueError('every requested track requires a persistent string ID')
            item = {k: track.get(k, '') for k in ('id', 'title', 'artist', 'album')}
            result['requestedTrackIDs'].append(track['id'])
            result['requestedTracks'].append(dict(item))
            source, reason = select(track, sources, verification_cache, hot_dir=hot_dir)
            if source:
                try:
                    path = source['path']
                    if path not in memo:
                        info = verified(path, verification_cache)
                        embedded = info.get('embeddedTags', {})
                        if any(normal(embedded.get(k)) and normal(track.get(k)) and normal(embedded[k]) != normal(track[k])
                               for k in ('title', 'artist', 'album')):
                            raise ValueError('embedded recording metadata contradicts request')
                        memo[path] = copy_verified(info, cache, floor) if copy else info
                    embedded = memo[path].get('embeddedTags', {})
                    if any(normal(embedded.get(k)) and normal(track.get(k)) and normal(embedded[k]) != normal(track[k])
                           for k in ('title', 'artist', 'album')):
                        raise ValueError('embedded recording metadata contradicts request')
                    item.update(memo[path])
                    result['tracks'].append(item)
                    continue
                except (OSError, ValueError) as exc:
                    reason = str(exc)
            result['missing'].append(dict(item, reason=reason))
        result.update(ready=bool(tracks) and not result['missing'], readyCount=len(result['tracks']), totalCount=len(tracks))
        output['playlists'].append(result)
    return output


def publish(document, destination):
    destination = Path(destination).expanduser()
    destination.parent.mkdir(parents=True, exist_ok=True)
    temp = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', dir=destination.parent, prefix='.manifest-', delete=False) as stream:
            temp = Path(stream.name)
            json.dump(document, stream, indent=2, ensure_ascii=False)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, destination)
    finally:
        if temp:
            temp.unlink(missing_ok=True)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('command', choices=['audit', 'prepare'])
    p.add_argument('--requests', type=Path, default=BASE / 'offline-requests.json')
    p.add_argument('--manifest', type=Path, default=BASE / 'offline-manifest.json')
    p.add_argument('--index', type=Path, help='Optional trusted exact ID/path or full metadata source index {tracks:[...]}')
    p.add_argument('--root', type=Path, action='append', help='Local pinned audio pool, repeatable')
    p.add_argument('--copy', action='store_true', help='Prepare only: copy exact selected audio, respecting live M5 floor')
    p.add_argument('--cache', type=Path, default=CACHE)
    args = p.parse_args()
    if args.copy and args.command != 'prepare':
        p.error('--copy requires prepare; audit is read-only')
    try:
        floor = policy_floor() if args.copy else FLOOR
        lock = None
        scan_cache = {}
        verification_cache = {}
        cache_file = args.manifest.with_suffix('.metadata.json')
        if args.command == 'prepare':
            args.manifest.parent.mkdir(parents=True, exist_ok=True)
            lock = open(args.manifest.with_suffix('.lock'), 'a')
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                p.exit(75, 'offline-cache: another preparation is active\n')
            try:
                saved = json.loads(cache_file.read_text())
                if saved.get('schemaVersion') == 3:
                    scan_cache = saved.get('metadata', {})
                    verification_cache = saved.get('verified', {})
            except (OSError, ValueError):
                pass
        hot = music_library_hot_dir()
        roots = args.root if args.root is not None else default_audio_roots()
        sources = inventory(roots, args.index, scan_cache)
        result = audit(json.loads(args.requests.read_text()), sources, args.copy, args.cache, floor,
                       verification_cache, hot_dir=hot)
        result['storage'] = {'physicalFreeBytes': physical_free(args.cache), 'floorBytes': floor}
        if args.command == 'prepare':
            publish(result, args.manifest)
            publish({'schemaVersion': 3, 'metadata': scan_cache, 'verified': verification_cache}, cache_file)
        print(json.dumps(result, indent=2, ensure_ascii=False))
        return 0 if all(x['ready'] for x in result['playlists']) else 2
    except (OSError, ValueError, KeyError, TypeError, ImportError, StopIteration) as exc:
        p.exit(1, 'offline-cache: ' + str(exc) + '\n')


if __name__ == '__main__':
    raise SystemExit(main())
