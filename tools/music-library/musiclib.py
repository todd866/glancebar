#!/usr/bin/env python3
"""Glancebar lossless hot-set sync via rclone. Stdlib only; credentials live in rclone config."""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import shutil
import struct
import subprocess
import stat
import sys
import tempfile
import time
import unicodedata
from pathlib import Path

_HERE = Path(__file__).resolve().parent
_bundle = _HERE / 'offline_cache.py'
_dev = _HERE.parent / 'offline-cache'
if _bundle.is_file():
    if str(_HERE) not in sys.path:
        sys.path.insert(0, str(_HERE))
elif _dev.is_dir() and str(_dev) not in sys.path:
    sys.path.insert(0, str(_dev))
import offline_cache as oc  # noqa: E402

HOME = Path.home()
DEFAULT_CONFIG = HOME / '.config/glancebar/music-library.json'
DEFAULT_STATE = HOME / '.local/state/glancebar-music-library'
DEFAULT_REQUESTS = HOME / 'Library/Application Support/Glancebar/mix/offline-requests.json'
METERED_FLAG = HOME / '.local/state/METERED_LINK'
TRASH = Path('/usr/bin/trash')
AUDIO_SUFFIXES = {'.m4a', '.mp4', '.alac'}

CATALOGUE_SCHEMA = 1
PLAN_SCHEMA = 1
STATUS_SCHEMA = 1
GIB = 1024 ** 3


def normal(value):
    return oc.normal(value)


def match_key(artist, title):
    return (normal(artist), normal(title))


def config_path(override=None):
    return Path(override).expanduser() if override else DEFAULT_CONFIG


def load_config(path=None):
    p = config_path(path)
    try:
        raw = json.loads(p.read_text())
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        raise ValueError(f'music-library config unreadable: {p}: {exc}') from exc
    for key in ('remote', 'hot_dir', 'cap_gb', 'keep_days'):
        if key not in raw:
            raise ValueError(f'music-library config missing {key!r}')
    return {
        'remote': str(raw['remote']).rstrip('/'),
        'hot_dir': Path(raw['hot_dir']).expanduser(),
        'cap_gb': float(raw['cap_gb']),
        'keep_days': int(raw['keep_days']),
        'min_free_gb': float(raw.get('min_free_gb', 20)),
        'max_playlist_tracks': int(raw.get('max_playlist_tracks', 120)),
        'config_path': p,
    }


def max_playlist_tracks(cfg):
    return int(cfg.get('max_playlist_tracks', 120))


def cap_bytes_from_config(cfg):
    return int(cfg['cap_gb'] * GIB)


def min_free_bytes_from_config(cfg):
    return int(cfg.get('min_free_gb', 20) * GIB)


def physical_free_bytes(path):
    p = Path(path).expanduser()
    while not p.exists():
        p = p.parent
    s = os.statvfs(p)
    return min(s.f_bavail, s.f_bfree) * s.f_frsize


def state_dir(override=None):
    return Path(override).expanduser() if override else DEFAULT_STATE


def sha256_file(path, chunk=1024 * 1024):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(chunk), b''):
            h.update(block)
    return h.hexdigest()


def mp4_duration_seconds(path):
    """Read track duration from the first mdhd atom under moov/trak."""
    duration = None
    timescale = None
    with Path(path).open('rb') as f:
        def walk(start, end, depth=0, parents=()):
            nonlocal duration, timescale
            if depth > 10 or start > end:
                return
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
                body = pos + header
                if kind == b'mdhd' and parents == (b'moov', b'trak', b'mdia') and size - header >= 20:
                    f.seek(body)
                    version = f.read(1)[0]
                    if version == 0 and size - header >= 20:
                        data = f.read(19)
                        if len(data) == 19:
                            timescale = struct.unpack('>I', data[7:11])[0]
                            duration = struct.unpack('>I', data[11:15])[0]
                    elif version == 1 and size - header >= 32:
                        data = f.read(31)
                        if len(data) == 31:
                            timescale = struct.unpack('>I', data[15:19])[0]
                            duration = struct.unpack('>Q', data[19:27])[0]
                elif kind in (b'moov', b'trak', b'mdia', b'minf', b'stbl', b'udta', b'meta', b'ilst'):
                    walk(body + (4 if kind == b'meta' else 0), pos + size, depth + 1, parents + (kind,))
                pos += size

        try:
            walk(0, Path(path).stat().st_size)
        except (OSError, struct.error):
            return None
    if duration is not None and timescale and timescale > 0:
        return round(duration / timescale, 3)
    return None


def rclone_bin():
    return shutil.which('rclone')


def rclone_run(argv, check=True):
    exe = rclone_bin()
    if not exe:
        raise RuntimeError('rclone not installed')
    proc = subprocess.run([exe, *argv], capture_output=True, text=True)
    if check and proc.returncode != 0:
        msg = (proc.stderr or proc.stdout or '').strip() or f'rclone exit {proc.returncode}'
        raise RuntimeError(msg)
    return proc


def remote_catalogue_path(remote):
    return f'{remote}/catalogue.json'


def fetch_remote_json(remote, name, dest):
    """Download remote `name` to local path dest via rclone copyto."""
    dest = Path(dest)
    dest.parent.mkdir(parents=True, exist_ok=True)
    part = dest.with_suffix(dest.suffix + '.part')
    try:
        rclone_run(['copyto', f'{remote}/{name}', str(part)])
        part.replace(dest)
    except RuntimeError:
        part.unlink(missing_ok=True)
        raise


def upload_local_json(local_path, remote, name):
    rclone_run(['copyto', str(local_path), f'{remote}/{name}'])


def remote_list_files(remote):
    """Return set of relative paths under remote (excluding catalogue.json at root)."""
    proc = rclone_run(['lsf', remote, '--files-only', '-R'], check=True)
    rows = {line.strip() for line in proc.stdout.splitlines() if line.strip()}
    return rows


def remote_fetch_file(remote, relpath, dest_part):
    rclone_run(['copyto', f'{remote}/{relpath}', str(dest_part)])


def remote_object_meta(remote, relpath):
    """Return rclone lsjson metadata for one remote object, or None when absent."""
    proc = rclone_run(['lsjson', f'{remote}/{relpath}', '--hash'], check=False)
    if proc.returncode != 0:
        return None
    try:
        rows = json.loads(proc.stdout or '[]')
    except json.JSONDecodeError:
        return None
    if not rows or not isinstance(rows[0], dict):
        return None
    row = rows[0]
    hashes = row.get('Hashes') or {}
    sha = hashes.get('sha256') or hashes.get('SHA256') or row.get('sha256')
    return {'sizeBytes': int(row.get('Size') or row.get('size') or 0), 'sha256': sha}


def remote_confirms_catalogue(remote, relpath, entry, meta=None):
    """True when the remote object matches catalogue size and hash when reported."""
    meta = meta if meta is not None else remote_object_meta(remote, relpath)
    if not meta:
        return False, 'remote object missing'
    expected_size = int(entry.get('sizeBytes') or 0)
    if meta.get('sizeBytes') != expected_size:
        return False, 'remote size mismatch'
    remote_hash = meta.get('sha256')
    catalogue_hash = entry.get('sha256')
    if remote_hash and catalogue_hash and str(remote_hash).lower() != str(catalogue_hash).lower():
        return False, 'remote hash mismatch'
    return True, None


def load_build_cache(state):
    p = state / 'catalogue-build-cache.json'
    try:
        return json.loads(p.read_text())
    except (OSError, ValueError, json.JSONDecodeError):
        return {}


def save_build_cache(state, cache):
    p = state / 'catalogue-build-cache.json'
    p.parent.mkdir(parents=True, exist_ok=True)
    atomic_write_json(p, cache)


def catalogue_entry_for_file(path, masters_root, cache):
    rel = str(path.relative_to(masters_root))
    st = path.stat()
    stamp = [st.st_size, str(st.st_mtime_ns)]
    prev = cache.get(rel, {})
    if prev.get('stamp') == stamp and prev.get('entry'):
        return prev['entry'], cache
    tags = {}
    duration = None
    if path.suffix.lower() in ('.m4a', '.mp4'):
        try:
            tags = oc.mp4_tags(path)
        except (OSError, ValueError, UnicodeError):
            tags = {}
        duration = mp4_duration_seconds(path)
    entry = {
        'relativePath': rel,
        'sizeBytes': st.st_size,
        'mtimeNs': str(st.st_mtime_ns),
        'sha256': sha256_file(path),
        'tags': {k: tags.get(k, '') for k in ('title', 'artist', 'album')},
    }
    if duration is not None:
        entry['durationSeconds'] = duration
    cache[rel] = {'stamp': stamp, 'entry': entry}
    return entry, cache


def build_catalogue(masters_dir, state):
    masters = Path(masters_dir).expanduser().resolve()
    if not masters.is_dir():
        raise ValueError(f'masters directory missing: {masters}')
    cache = load_build_cache(state)
    entries = []
    skipped = []
    def walk_error(exc):
        skipped.append(f'{getattr(exc, "filename", "?")}: {exc.strerror or exc}')

    found = []
    # os.walk with onerror: one unreadable or vanished directory must not abort the catalogue.
    for folder, _dirs, names in os.walk(masters, onerror=walk_error):
        found.extend(Path(folder) / name for name in names)
    for path in sorted(found):
        if path.suffix.lower() not in AUDIO_SUFFIXES:
            continue
        # Masters usually live on an external drive, so the laptop's "playable local file"
        # rule (offline_cache.local_file refuses /Volumes) does not apply here. A master is
        # any regular, non-empty, non-symlink audio file. Anything else is reported.
        try:
            st = path.lstat()
        except OSError as exc:
            skipped.append(f'{path}: {exc}')
            continue
        if not stat.S_ISREG(st.st_mode) or st.st_size <= 0:
            skipped.append(f'{path}: not a regular non-empty file')
            continue
        entry, cache = catalogue_entry_for_file(path, masters, cache)
        entries.append(entry)
    if skipped:
        print(f'catalogue: skipped {len(skipped)} file(s), first: {skipped[0]}', file=sys.stderr)
    if not entries:
        raise ValueError(f'no audio masters found under {masters}')
    save_build_cache(state, cache)
    return {
        'schemaVersion': CATALOGUE_SCHEMA,
        'generatedAt': int(time.time()),
        'entries': entries,
    }


def atomic_write_json(path, document):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', dir=path.parent, prefix=f'.{path.name}-', delete=False) as stream:
            temp = Path(stream.name)
            json.dump(document, stream, indent=2, ensure_ascii=False)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, path)
    finally:
        if temp:
            temp.unlink(missing_ok=True)


def catalogue_command(masters_dir, remote, state, upload=True):
    state = state_dir(state)
    doc = build_catalogue(masters_dir, state)
    local_out = state / 'catalogue.json'
    atomic_write_json(local_out, doc)
    if upload:
        upload_local_json(local_out, remote, 'catalogue.json')
    return doc


def push_command(masters_dir, remote):
    masters = Path(masters_dir).expanduser().resolve()
    rclone_run(['copy', str(masters), remote, '--checksum'])


def load_requests(path):
    path = Path(path).expanduser()
    doc = json.loads(path.read_text())
    if doc.get('schemaVersion') != 1 or not isinstance(doc.get('playlists'), list):
        raise ValueError('unsupported offline-requests schema')
    return doc


def track_duration_seconds(track):
    for key in ('durationSeconds', 'duration'):
        val = track.get(key)
        if val is None or val == '':
            continue
        try:
            return float(val)
        except (TypeError, ValueError):
            pass
    return None


def duration_ok(request_dur, entry_dur, tolerance=2.0):
    if request_dur is None or entry_dur is None:
        return True
    return abs(request_dur - entry_dur) <= tolerance


_MATCH_INDEX = {}


def catalogue_match_index(catalogue_entries):
    """Match key -> catalogue entries, built once per entries list.

    Without it every track recomputed the keys of every catalogue entry: a status read over
    1,500 tracks and 1,300 entries took 17 s of CPU (11 Nov 2026), and the app asks for one
    every 30 s.
    """
    cached = _MATCH_INDEX.get(id(catalogue_entries))
    if cached and cached[0] is catalogue_entries and cached[1] == len(catalogue_entries):
        return cached[2]
    index = {}
    for position, entry in enumerate(catalogue_entries):
        tags = entry.get('tags') or {}
        for key in oc.catalogue_match_keys(tags.get('artist', ''), tags.get('title', '')):
            index.setdefault(key, []).append((position, entry))
    _MATCH_INDEX.clear()
    _MATCH_INDEX[id(catalogue_entries)] = (catalogue_entries, len(catalogue_entries), index)
    return index


def match_track(track, catalogue_entries):
    """Return (matches, reason). matches is a list of entries; reason set when empty."""
    req_keys = oc.catalogue_match_keys(track.get('artist', ''), track.get('title', ''))
    if not req_keys:
        return [], 'missing title or artist'
    req_dur = track_duration_seconds(track)
    exact_key = match_key(track.get('artist', ''), track.get('title', ''))
    index = catalogue_match_index(catalogue_entries)
    candidates = {}
    for key in req_keys:
        for position, entry in index.get(key, ()):
            candidates[position] = entry
    hits = []
    for position in sorted(candidates):
        entry = candidates[position]
        tags = entry.get('tags') or {}
        entry_dur = entry.get('durationSeconds')
        if not duration_ok(req_dur, entry_dur):
            continue
        exact = match_key(tags.get('artist', ''), tags.get('title', '')) == exact_key
        if not exact and (req_dur is None or entry_dur is None):
            # A loose match (suffix, "feat.", primary artist) is only trusted when the
            # durations confirm it is the same recording.
            continue
        hits.append(entry)
    if not hits:
        return [], 'no catalogue match'
    if len(hits) > 1:
        paths = {h['relativePath'] for h in hits}
        if len(paths) > 1:
            return [], 'ambiguous catalogue match'
    return hits, None


def safe_relpath(rel):
    """A catalogue path is trusted only as a relative audio path with no '..' parts.

    The catalogue is fetched from the remote, so a bad or tampered entry must never be able
    to name a file outside hot_dir.
    """
    if not isinstance(rel, str) or not rel or '\x00' in rel or '\\' in rel:
        return False
    parts = rel.split('/')
    if rel.startswith('/') or any(part in ('', '.', '..') for part in parts):
        return False
    return os.path.splitext(rel)[1].lower() in AUDIO_SUFFIXES


def inside(root, rel):
    """The destination for rel, or None when it would resolve outside root (e.g. via a symlink)."""
    root = Path(root).resolve()
    dest = (root / rel).resolve()
    return dest if root in dest.parents else None


def index_catalogue(catalogue):
    return [entry for entry in (catalogue.get('entries') or [])
            if isinstance(entry, dict) and safe_relpath(entry.get('relativePath'))]


def hot_file_state(hot_dir):
    hot = Path(hot_dir).expanduser()
    rows = {}
    if not hot.is_dir():
        return rows
    for path in hot.rglob('*'):
        if path.suffix.lower() not in AUDIO_SUFFIXES or not path.is_file():
            continue
        rel = str(path.relative_to(hot))
        try:
            st = path.stat()
        except OSError:
            continue
        rows[rel] = {
            'relativePath': rel,
            'path': str(path),
            'sizeBytes': st.st_size,
            'mtime': st.st_mtime,
        }
    return rows


def load_played(state):
    p = state_dir(state) / 'played.json'
    try:
        doc = json.loads(p.read_text())
        return doc if isinstance(doc, dict) else {}
    except (OSError, ValueError, json.JSONDecodeError):
        return {}


def load_fetched(state):
    p = state_dir(state) / 'fetched.json'
    try:
        doc = json.loads(p.read_text())
        return doc if isinstance(doc, dict) else {}
    except (OSError, ValueError, json.JSONDecodeError):
        return {}


def save_fetched(state, fetched):
    atomic_write_json(state_dir(state) / 'fetched.json', fetched)


def load_cached_catalogue(state):
    p = state_dir(state) / 'catalogue.json'
    try:
        return json.loads(p.read_text())
    except (OSError, ValueError, json.JSONDecodeError):
        return None


def refresh_catalogue_cache(remote, state):
    dest = state_dir(state) / 'catalogue.json'
    fetch_remote_json(remote, 'catalogue.json', dest)
    return json.loads(dest.read_text())


def wanted_entries_from_requests(requests_doc, catalogue, max_tracks=120):
    entries = index_catalogue(catalogue)
    playlists = []
    library_playlists = []
    unmatched = []
    wanted_by_rel = {}
    for playlist in requests_doc['playlists']:
        key = playlist.get('key', '')
        title = playlist.get('title', key)
        track_rows = playlist.get('tracks') or []
        if len(track_rows) > max_tracks:
            library_playlists.append({
                'key': key,
                'title': title,
                'wanted': len(track_rows),
                'library': True,
            })
            continue
        pl_wanted = []
        for track in track_rows:
            matches, reason = match_track(track, entries)
            item = {
                'playlistKey': key,
                'playlistTitle': title,
                'track': {k: track.get(k, '') for k in ('id', 'title', 'artist', 'album')},
            }
            if not matches:
                unmatched.append(dict(item, reason=reason))
                continue
            entry = matches[0]
            row = dict(item, catalogue=entry)
            pl_wanted.append(row)
            wanted_by_rel[entry['relativePath']] = row
        playlists.append({'key': key, 'title': title, 'tracks': pl_wanted})
    return playlists, list(wanted_by_rel.values()), unmatched, library_playlists


def playlist_fetch_order(to_fetch, playlist_first=None):
    order = []
    seen = set()
    if playlist_first:
        order.append(playlist_first)
        seen.add(playlist_first)
    for row in to_fetch:
        key = row.get('playlistKey')
        if key and key not in seen:
            order.append(key)
            seen.add(key)
    return order


def group_to_fetch_by_playlist(to_fetch):
    grouped = {}
    for row in to_fetch:
        grouped.setdefault(row.get('playlistKey'), []).append(row)
    return grouped


def bytes_in_hot(hot_map):
    return sum(row['sizeBytes'] for row in hot_map.values())


def part_bytes_in_hot(hot_dir):
    hot = Path(hot_dir).expanduser()
    total = 0
    if not hot.is_dir():
        return total
    for path in hot.rglob('*.part'):
        if path.is_file():
            try:
                total += path.stat().st_size
            except OSError:
                pass
    return total


def hot_byte_usage(hot_dir, hot_map=None):
    hot_map = hot_map if hot_map is not None else hot_file_state(hot_dir)
    return bytes_in_hot(hot_map) + part_bytes_in_hot(hot_dir)


def sweep_stale_parts(hot_dir):
    removed = []
    hot = Path(hot_dir).expanduser()
    if not hot.is_dir():
        return removed
    for path in hot.rglob('*.part'):
        if path.is_file():
            try:
                path.unlink()
                removed.append(str(path))
            except OSError:
                pass
    return removed


def load_verified_hot(state):
    p = state_dir(state) / 'verified-hot.json'
    try:
        doc = json.loads(p.read_text())
        return doc if isinstance(doc, dict) else {}
    except (OSError, ValueError, json.JSONDecodeError):
        return {}


def save_verified_hot(state, verified):
    atomic_write_json(state_dir(state) / 'verified-hot.json', verified)


def verify_hot_track(path, entry, verified_state, rel):
    """Return (ok, digest). Cheap when size+mtime match the last verified record."""
    p = Path(path)
    st = p.stat()
    expected_size = int(entry['sizeBytes'])
    if st.st_size != expected_size:
        return False, None
    stamp = [st.st_size, str(st.st_mtime_ns)]
    prev = verified_state.get(rel, {})
    if prev.get('stamp') == stamp and prev.get('sha256') == entry.get('sha256'):
        return True, prev['sha256']
    digest = sha256_file(p)
    if digest != entry.get('sha256'):
        return False, digest
    verified_state[rel] = {'stamp': stamp, 'sha256': digest}
    return True, digest


def reconcile_wanted_hot(hot_dir, wanted_entries, verified_state, trash_cmd=None):
    """Trash corrupt hot files; return (local_ok, refetch)."""
    hot_map = hot_file_state(hot_dir)
    local = []
    refetch = []
    hot_dir = Path(hot_dir).expanduser().resolve()
    for item in wanted_entries:
        rel = item['catalogue']['relativePath']
        if rel not in hot_map:
            refetch.append(item)
            continue
        row = hot_map[rel]
        path = Path(row['path']).resolve()
        if not path.is_relative_to(hot_dir):
            refetch.append(item)
            continue
        ok, _ = verify_hot_track(path, item['catalogue'], verified_state, rel)
        if ok:
            local.append(dict(item, path=str(path)))
            continue
        trash_path(path, trash_cmd=trash_cmd)
        verified_state.pop(rel, None)
        refetch.append(item)
    return local, refetch


def prioritize_to_fetch(to_fetch, playlist_key=None):
    if not playlist_key:
        return list(to_fetch)
    first = [row for row in to_fetch if row.get('playlistKey') == playlist_key]
    rest = [row for row in to_fetch if row.get('playlistKey') != playlist_key]
    return first + rest


def catalogue_index(catalogue):
    return {e['relativePath']: e for e in index_catalogue(catalogue)}


def activity_timestamp(rel, played, fetched, hot_row, now):
    ts = [hot_row.get('mtime', 0)]
    if rel in played:
        ts.append(float(played[rel]))
    if rel in fetched:
        ts.append(float(fetched[rel]))
    return max(ts)


def evictable_files(hot_map, wanted_rels, played, fetched, remote_rels, keep_days, now):
    cutoff = now - keep_days * 86400
    candidates = []
    for rel, row in hot_map.items():
        if rel in wanted_rels:
            continue
        act = activity_timestamp(rel, played, fetched, row, now)
        if act >= cutoff:
            continue
        if rel not in remote_rels:
            continue
        candidates.append({
            'relativePath': rel,
            'sizeBytes': row['sizeBytes'],
            'path': row['path'],
            'lastActivity': act,
        })
    candidates.sort(key=lambda r: r['lastActivity'])
    return candidates


def plan_evictions(hot_dir, hot_map, wanted_rels, played, fetched, remote_rels, cap_bytes, keep_days, now,
                   extra_fetch_bytes=0):
    hot_bytes = hot_byte_usage(hot_dir, hot_map)
    target = hot_bytes + extra_fetch_bytes - cap_bytes
    evict = []
    if target <= 0:
        return evict
    for row in evictable_files(hot_map, wanted_rels, played, fetched, remote_rels, keep_days, now):
        evict.append(row)
        target -= row['sizeBytes']
        if target <= 0:
            break
    return evict


def compute_plan(requests_doc, catalogue, hot_dir, played, fetched, remote_rels, cap_bytes, keep_days,
                 now=None, verified_state=None, trash_cmd=None, playlist_first=None, max_tracks=120):
    now = now if now is not None else time.time()
    playlists, wanted_entries, unmatched, library_playlists = wanted_entries_from_requests(
        requests_doc, catalogue, max_tracks=max_tracks)
    wanted_rels = {e['catalogue']['relativePath'] for e in wanted_entries}
    hot_map = hot_file_state(hot_dir)
    verified_state = verified_state if verified_state is not None else {}
    local, to_fetch = reconcile_wanted_hot(hot_dir, wanted_entries, verified_state, trash_cmd=trash_cmd)
    to_fetch = prioritize_to_fetch(to_fetch, playlist_first)
    fetch_bytes = sum(e['catalogue']['sizeBytes'] for e in to_fetch)
    evict = plan_evictions(hot_dir, hot_map, wanted_rels, played, fetched, remote_rels, cap_bytes, keep_days, now,
                            extra_fetch_bytes=fetch_bytes)
    hot_bytes = hot_byte_usage(hot_dir, hot_map)
    after_evict = hot_bytes - sum(r['sizeBytes'] for r in evict) + fetch_bytes
    overflow = after_evict > cap_bytes
    evict_rows = []
    for row in evict:
        entry = catalogue_index(catalogue).get(row['relativePath'], {})
        evict_rows.append({
            'relativePath': row['relativePath'],
            'sizeBytes': row['sizeBytes'],
            'catalogue': {k: entry.get(k) for k in ('relativePath', 'sizeBytes', 'sha256')},
        })
    return {
        'schemaVersion': PLAN_SCHEMA,
        'generatedAt': int(now),
        'playlists': playlists,
        'library': library_playlists,
        'wantedCount': len(wanted_entries),
        'local': local,
        'toFetch': to_fetch,
        'unmatched': unmatched,
        'evict': evict_rows,
        'hotBytes': hot_bytes,
        'capBytes': cap_bytes,
        'afterSyncBytes': after_evict,
        'overflow': overflow,
    }


def metered_active(flag_path=None):
    p = Path(flag_path) if flag_path else METERED_FLAG
    return p.exists()


def acquire_lock(state):
    state = state_dir(state)
    state.mkdir(parents=True, exist_ok=True)
    lock_path = state / 'sync.lock'
    handle = lock_path.open('a')
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        handle.close()
        raise BlockingIOError('another music-library sync is active')
    return handle, lock_path


def verify_and_install(part_path, final_path, expected_sha256, expected_size):
    part = Path(part_path)
    st = part.stat()
    if st.st_size != expected_size:
        part.unlink(missing_ok=True)
        raise ValueError(f'size mismatch for {final_path.name}')
    digest = sha256_file(part)
    if digest != expected_sha256:
        part.unlink(missing_ok=True)
        raise ValueError(f'sha256 mismatch for {final_path.name}')
    final = Path(final_path)
    final.parent.mkdir(parents=True, exist_ok=True)
    part.replace(final)


def trash_path(path, trash_cmd=None):
    cmd = Path(trash_cmd) if trash_cmd else TRASH
    if not cmd.is_file():
        raise RuntimeError(f'trash helper missing: {cmd}')
    subprocess.run([str(cmd), str(path)], check=True)


def sync_execute(plan, cfg, state, remote_rels, allow_metered=False, metered_flag=None, trash_cmd=None, now=None,
                 remote_meta=None, playlist_first=None):
    now = now if now is not None else time.time()
    state_p = state_dir(state)
    if metered_active(metered_flag) and not allow_metered:
        raise ValueError('metered link; refuse fetch (use --allow-metered)')
    hot_dir = Path(cfg['hot_dir']).expanduser().resolve()
    cap_bytes = int(plan['capBytes'])
    min_free = min_free_bytes_from_config(cfg)
    meta_lookup = remote_meta if remote_meta is not None else remote_object_meta
    fetched = load_fetched(state)
    verified_hot = load_verified_hot(state)
    sweep_stale_parts(hot_dir)
    hot_map = hot_file_state(hot_dir)
    hot_bytes = hot_byte_usage(hot_dir, hot_map)
    eviction_skipped = []
    for ev in plan['evict']:
        rel = ev['relativePath']
        row = hot_map.get(rel)
        if not row:
            continue
        path = Path(row['path']).resolve()
        if not path.is_relative_to(hot_dir):
            raise ValueError(f'refuse evict outside hot_dir: {path}')
        entry = ev.get('catalogue') or {}
        if not entry.get('sha256'):
            eviction_skipped.append({'relativePath': rel, 'reason': 'missing catalogue entry'})
            continue
        ok, reason = remote_confirms_catalogue(cfg['remote'], rel, entry, meta=meta_lookup(cfg['remote'], rel))
        if not ok:
            eviction_skipped.append({'relativePath': rel, 'reason': reason})
            continue
        trash_path(path, trash_cmd=trash_cmd)
        fetched.pop(rel, None)
        verified_hot.pop(rel, None)
        hot_map.pop(rel, None)
        hot_bytes -= row['sizeBytes']
    to_fetch = prioritize_to_fetch(plan['toFetch'], playlist_first)
    by_playlist = group_to_fetch_by_playlist(to_fetch)
    skipped_playlists = []
    fetched_count = 0
    for key in playlist_fetch_order(to_fetch, playlist_first):
        items = by_playlist.get(key, [])
        if not items:
            continue
        need_bytes = sum(int(item['catalogue']['sizeBytes']) for item in items)
        title = items[0].get('playlistTitle', key)
        if hot_bytes + need_bytes > cap_bytes:
            skipped_playlists.append({'key': key, 'title': title, 'reason': 'cap', 'needBytes': need_bytes})
            continue
        for item in items:
            entry = item['catalogue']
            rel = entry['relativePath']
            size = int(entry['sizeBytes'])
            if hot_bytes + size > cap_bytes:
                skipped_playlists.append({'key': key, 'title': title, 'reason': 'cap', 'needBytes': need_bytes})
                break
            free_disk = physical_free_bytes(hot_dir)
            if free_disk - size < min_free:
                raise ValueError(f'free disk would fall below min_free_gb fetching {rel!r}')
            dest = inside(hot_dir, rel) if safe_relpath(rel) else None
            if dest is None:
                raise ValueError('refusing to fetch outside the hot directory: %r' % (rel,))
            part = dest.with_suffix(dest.suffix + '.part')
            part.parent.mkdir(parents=True, exist_ok=True)
            try:
                remote_fetch_file(cfg['remote'], rel, part)
                verify_and_install(part, dest, entry['sha256'], entry['sizeBytes'])
            except (OSError, ValueError, RuntimeError):
                part.unlink(missing_ok=True)
                raise
            fetched[rel] = now
            st = dest.stat()
            verified_hot[rel] = {'stamp': [st.st_size, str(st.st_mtime_ns)], 'sha256': entry['sha256']}
            hot_bytes += size
            fetched_count += 1
    save_fetched(state, fetched)
    save_verified_hot(state, verified_hot)
    status = {
        'lastSyncAt': int(now),
        'lastError': None,
        'fetched': fetched_count,
        'evictionSkipped': eviction_skipped,
        'skipped': skipped_playlists,
        'library': plan.get('library') or [],
        'plan': {k: plan.get(k) for k in ('wantedCount', 'hotBytes', 'capBytes', 'afterSyncBytes')},
    }
    atomic_write_json(state_p / 'last-status.json', status)
    return status


def touch_played(path, state, config=None, now=None):
    now = now if now is not None else time.time()
    path = Path(path).expanduser()
    cfg = load_config(config)
    hot = cfg['hot_dir'].resolve()
    path_resolved = path.resolve()
    if not path_resolved.is_file():
        raise ValueError('touch path is not a file')
    try:
        rel = str(path_resolved.relative_to(hot))
    except ValueError:
        rel = str(path)
    played = load_played(state)
    played[rel] = now
    atomic_write_json(state_dir(state) / 'played.json', played)
    return rel, now


def build_status(requests_doc, catalogue, cfg, state, last_status):
    limit = max_playlist_tracks(cfg)
    _, wanted_entries, _, library_from_requests = wanted_entries_from_requests(
        requests_doc, catalogue, max_tracks=limit)
    wanted_rels = {e['catalogue']['relativePath'] for e in wanted_entries}
    hot_map = hot_file_state(cfg['hot_dir'])
    local_rels = set(hot_map) & wanted_rels
    skipped = []
    library = []
    if isinstance(last_status, dict):
        skipped = last_status.get('skipped') or []
        library = last_status.get('library') or []
    skipped_keys = {row.get('key') for row in skipped if isinstance(row, dict) and row.get('key')}
    library_keys = {row.get('key') for row in library_from_requests if isinstance(row, dict) and row.get('key')}
    for row in library:
        if isinstance(row, dict) and row.get('key'):
            library_keys.add(row['key'])
    per_playlist = []
    any_missing = False
    entries = index_catalogue(catalogue)

    def playlist_counts(tracks):
        wanted = len(tracks)
        local_count = 0
        unmatched = 0
        for track in tracks:
            matches, reason = match_track(track, entries)
            if not matches:
                if reason:
                    unmatched += 1
                continue
            if matches[0]['relativePath'] in hot_map:
                local_count += 1
        missing = wanted - local_count - unmatched
        return wanted, local_count, max(0, missing), unmatched

    for playlist in requests_doc['playlists']:
        key = playlist.get('key', '')
        title = playlist.get('title', key)
        tracks = playlist.get('tracks') or []
        is_library = key in library_keys or len(tracks) > limit
        wanted, local_count, missing, unmatched = playlist_counts(tracks)
        row = {
            'name': title,
            'key': key,
            'wanted': wanted,
            'local': local_count,
            'missing': missing,
            'unmatched': unmatched,
            'library': is_library,
        }
        per_playlist.append(row)
        if is_library or key in skipped_keys:
            continue
        if missing > 0:
            any_missing = True
    last_err = None
    last_sync = None
    if isinstance(last_status, dict):
        last_err = last_status.get('lastError')
        last_sync = last_status.get('lastSyncAt')
    failed = bool(last_err)
    library_rows = list(library_from_requests)
    for row in library:
        if isinstance(row, dict) and row not in library_rows:
            library_rows.append(row)
    return {
        'schemaVersion': STATUS_SCHEMA,
        'playlists': per_playlist,
        'library': library_rows,
        'skipped': skipped,
        'hotBytes': bytes_in_hot(hot_map),
        'capBytes': cap_bytes_from_config(cfg),
        'wantedLocal': len(local_rels),
        'wantedTotal': len(wanted_rels),
        'lastSyncAt': last_sync,
        'lastError': last_err,
        'healthy': not any_missing and not failed,
    }


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest='command', required=True)

    c_cat = sub.add_parser('catalogue', help='walk masters and publish catalogue.json')
    c_cat.add_argument('--masters', type=Path, required=True)
    c_cat.add_argument('--config', type=Path)
    c_cat.add_argument('--state', type=Path)
    c_cat.add_argument('--no-upload', action='store_true')

    c_push = sub.add_parser('push', help='rclone copy masters to remote (no deletes)')
    c_push.add_argument('--masters', type=Path, required=True)
    c_push.add_argument('--config', type=Path)

    c_plan = sub.add_parser('plan', help='compute hot-set plan JSON')
    c_plan.add_argument('--requests', type=Path, default=DEFAULT_REQUESTS)
    c_plan.add_argument('--config', type=Path)
    c_plan.add_argument('--state', type=Path)
    c_plan.add_argument('--refresh-catalogue', action='store_true')

    c_sync = sub.add_parser('sync', help='execute plan (fetch + evict)')
    c_sync.add_argument('--requests', type=Path, default=DEFAULT_REQUESTS)
    c_sync.add_argument('--config', type=Path)
    c_sync.add_argument('--state', type=Path)
    c_sync.add_argument('--allow-metered', action='store_true')
    c_sync.add_argument('--refresh-catalogue', action='store_true')
    c_sync.add_argument('--playlist', dest='playlist_key', metavar='KEY', help='fetch this playlist first')

    c_status = sub.add_parser('status', help='JSON status for morning check')
    c_status.add_argument('--requests', type=Path, default=DEFAULT_REQUESTS)
    c_status.add_argument('--config', type=Path)
    c_status.add_argument('--state', type=Path)

    c_touch = sub.add_parser('touch', help='record play time for eviction')
    c_touch.add_argument('path', type=Path)
    c_touch.add_argument('--config', type=Path)
    c_touch.add_argument('--state', type=Path)

    args = p.parse_args(argv)
    try:
        if args.command == 'catalogue':
            cfg = load_config(args.config)
            doc = catalogue_command(args.masters, cfg['remote'], args.state, upload=not args.no_upload)
            print(json.dumps({'entries': len(doc['entries']), 'remote': cfg['remote']}, indent=2))
            return 0
        if args.command == 'push':
            cfg = load_config(args.config)
            push_command(args.masters, cfg['remote'])
            return 0
        if args.command == 'touch':
            rel, ts = touch_played(args.path, args.state, config=args.config)
            print(json.dumps({'relativePath': rel, 'playedAt': ts}))
            return 0

        cfg = load_config(getattr(args, 'config', None))
        state = args.state if hasattr(args, 'state') else None
        cap_bytes = cap_bytes_from_config(cfg)
        requests_doc = load_requests(args.requests)
        metered = metered_active()
        allow_metered = getattr(args, 'allow_metered', False)
        cached_catalogue_note = False

        if args.command == 'sync' and metered and not allow_metered:
            raise ValueError('metered link; refuse sync before remote calls (use --allow-metered)')

        if args.command in ('plan', 'sync', 'status'):
            if metered and not allow_metered:
                catalogue = load_cached_catalogue(state)
                if catalogue is None:
                    raise ValueError('metered link; no cached catalogue')
                cached_catalogue_note = True
            elif getattr(args, 'refresh_catalogue', False) or load_cached_catalogue(state) is None:
                if not rclone_bin():
                    raise RuntimeError('rclone required to refresh catalogue')
                catalogue = refresh_catalogue_cache(cfg['remote'], state)
            else:
                catalogue = load_cached_catalogue(state)

        if args.command == 'plan':
            if metered and not allow_metered:
                remote_rels = {e['relativePath'] for e in index_catalogue(catalogue)}
            elif rclone_bin():
                remote_rels = remote_list_files(cfg['remote'])
            else:
                remote_rels = {e['relativePath'] for e in index_catalogue(catalogue)}
            verified = load_verified_hot(state)
            plan = compute_plan(requests_doc, catalogue, cfg['hot_dir'], load_played(state), load_fetched(state),
                                remote_rels, cap_bytes, cfg['keep_days'], verified_state=verified,
                                playlist_first=getattr(args, 'playlist_key', None),
                                max_tracks=max_playlist_tracks(cfg))
            if cached_catalogue_note:
                plan['catalogueSource'] = 'cache'
                plan['metered'] = True
            print(json.dumps(plan, indent=2, ensure_ascii=False))
            return 2 if plan['unmatched'] or plan['overflow'] else 0

        if args.command == 'status':
            last_status = {}
            try:
                last_status = json.loads((state_dir(state) / 'last-status.json').read_text())
            except (OSError, ValueError, json.JSONDecodeError):
                pass
            doc = build_status(requests_doc, catalogue, cfg, state, last_status)
            if cached_catalogue_note:
                doc['catalogueSource'] = 'cache'
                doc['metered'] = True
            print(json.dumps(doc, indent=2, ensure_ascii=False))
            return 0 if doc['healthy'] else 1

        if args.command == 'sync':
            lock = None
            try:
                lock, _ = acquire_lock(state)
                if metered and not allow_metered:
                    raise ValueError('metered link; refuse sync before remote calls (use --allow-metered)')
                if getattr(args, 'refresh_catalogue', False) or load_cached_catalogue(state) is None:
                    catalogue = refresh_catalogue_cache(cfg['remote'], state)
                else:
                    catalogue = load_cached_catalogue(state)
                remote_rels = remote_list_files(cfg['remote'])
                verified = load_verified_hot(state)
                plan = compute_plan(requests_doc, catalogue, cfg['hot_dir'], load_played(state), load_fetched(state),
                                    remote_rels, cap_bytes, cfg['keep_days'], verified_state=verified,
                                    playlist_first=getattr(args, 'playlist_key', None),
                                    max_tracks=max_playlist_tracks(cfg))
                status = sync_execute(plan, cfg, state, remote_rels, allow_metered=allow_metered,
                                      playlist_first=getattr(args, 'playlist_key', None))
                print(json.dumps({
                    'synced': True,
                    'fetched': status.get('fetched', len(plan['toFetch'])),
                    'evicted': len(plan['evict']) - len(status.get('evictionSkipped') or []),
                    'evictionSkipped': status.get('evictionSkipped') or [],
                }, indent=2))
                return 0
            except BlockingIOError as exc:
                p.exit(75, str(exc) + '\n')
            finally:
                if lock:
                    lock.close()
        return 0
    except (OSError, ValueError, RuntimeError, json.JSONDecodeError, subprocess.CalledProcessError) as exc:
        state_p = state_dir(getattr(args, 'state', None))
        try:
            atomic_write_json(state_p / 'last-status.json', {
                'lastSyncAt': None,
                'lastError': str(exc),
            })
        except OSError:
            pass
        p.exit(1, 'music-library: ' + str(exc) + '\n')


if __name__ == '__main__':
    raise SystemExit(main())
