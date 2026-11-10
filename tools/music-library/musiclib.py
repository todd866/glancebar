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
import sys
import tempfile
import time
import unicodedata
from pathlib import Path

TOOLS = Path(__file__).resolve().parent.parent
if str(TOOLS / 'offline-cache') not in sys.path:
    sys.path.insert(0, str(TOOLS / 'offline-cache'))
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
        'config_path': p,
    }


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
    for path in sorted(masters.rglob('*')):
        if path.suffix.lower() not in AUDIO_SUFFIXES or not path.is_file():
            continue
        try:
            oc.local_file(path)
        except ValueError:
            continue
        entry, cache = catalogue_entry_for_file(path, masters, cache)
        entries.append(entry)
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


def match_track(track, catalogue_entries):
    """Return (matches, reason). matches is a list of entries; reason set when empty."""
    key = match_key(track.get('artist', ''), track.get('title', ''))
    if not key[0] or not key[1]:
        return [], 'missing title or artist'
    req_dur = track_duration_seconds(track)
    hits = []
    for entry in catalogue_entries:
        tags = entry.get('tags') or {}
        ekey = match_key(tags.get('artist', ''), tags.get('title', ''))
        if ekey != key:
            continue
        if not duration_ok(req_dur, entry.get('durationSeconds')):
            continue
        hits.append(entry)
    if not hits:
        return [], 'no catalogue match'
    if len(hits) > 1:
        paths = {h['relativePath'] for h in hits}
        if len(paths) > 1:
            return [], 'ambiguous catalogue match'
    return hits, None


def index_catalogue(catalogue):
    return list(catalogue.get('entries') or [])


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


def wanted_entries_from_requests(requests_doc, catalogue):
    entries = index_catalogue(catalogue)
    playlists = []
    unmatched = []
    wanted_by_rel = {}
    for playlist in requests_doc['playlists']:
        key = playlist.get('key', '')
        title = playlist.get('title', key)
        pl_wanted = []
        for track in playlist.get('tracks') or []:
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
    return playlists, list(wanted_by_rel.values()), unmatched


def bytes_in_hot(hot_map):
    return sum(row['sizeBytes'] for row in hot_map.values())


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


def plan_evictions(hot_map, wanted_rels, played, fetched, remote_rels, cap_bytes, keep_days, now,
                   extra_fetch_bytes=0):
    hot_bytes = bytes_in_hot(hot_map)
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


def compute_plan(requests_doc, catalogue, hot_dir, played, fetched, remote_rels, cap_bytes, keep_days, now=None):
    now = now if now is not None else time.time()
    playlists, wanted_entries, unmatched = wanted_entries_from_requests(requests_doc, catalogue)
    wanted_rels = {e['catalogue']['relativePath'] for e in wanted_entries}
    hot_map = hot_file_state(hot_dir)
    local = []
    to_fetch = []
    for entry in wanted_entries:
        rel = entry['catalogue']['relativePath']
        if rel in hot_map:
            local.append(dict(entry, path=hot_map[rel]['path']))
        else:
            to_fetch.append(entry)
    fetch_bytes = sum(e['catalogue']['sizeBytes'] for e in to_fetch)
    evict = plan_evictions(hot_map, wanted_rels, played, fetched, remote_rels, cap_bytes, keep_days, now,
                            extra_fetch_bytes=fetch_bytes)
    after_evict = bytes_in_hot(hot_map) - sum(r['sizeBytes'] for r in evict) + fetch_bytes
    overflow = after_evict > cap_bytes
    return {
        'schemaVersion': PLAN_SCHEMA,
        'generatedAt': int(now),
        'playlists': playlists,
        'wantedCount': len(wanted_entries),
        'local': local,
        'toFetch': to_fetch,
        'unmatched': unmatched,
        'evict': [{'relativePath': r['relativePath'], 'sizeBytes': r['sizeBytes']} for r in evict],
        'hotBytes': bytes_in_hot(hot_map),
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


def sync_execute(plan, cfg, state, remote_rels, allow_metered=False, metered_flag=None, trash_cmd=None, now=None):
    now = now if now is not None else time.time()
    state_p = state_dir(state)
    if metered_active(metered_flag) and not allow_metered:
        raise ValueError('metered link; refuse fetch (use --allow-metered)')
    if plan['overflow']:
        missing_fit = [pl['title'] for pl in plan['playlists']
                       if any(t['catalogue']['relativePath'] not in {x['catalogue']['relativePath'] for x in plan['local']}
                              for t in pl['tracks'])]
        raise ValueError(f'cap exceeded after eviction; playlists may not fit: {", ".join(missing_fit) or "unknown"}')
    hot_dir = Path(cfg['hot_dir']).expanduser().resolve()
    fetched = load_fetched(state)
    played = load_played(state)
    hot_map = hot_file_state(hot_dir)
    for item in plan['toFetch']:
        entry = item['catalogue']
        rel = entry['relativePath']
        dest = hot_dir / rel
        part = dest.with_suffix(dest.suffix + '.part')
        part.parent.mkdir(parents=True, exist_ok=True)
        remote_fetch_file(cfg['remote'], rel, part)
        verify_and_install(part, dest, entry['sha256'], entry['sizeBytes'])
        fetched[rel] = now
    save_fetched(state, fetched)
    for ev in plan['evict']:
        row = hot_map.get(ev['relativePath'])
        if not row:
            continue
        path = Path(row['path']).resolve()
        if not path.is_relative_to(hot_dir):
            raise ValueError(f'refuse evict outside hot_dir: {path}')
        trash_path(path, trash_cmd=trash_cmd)
        fetched.pop(ev['relativePath'], None)
    status = {
        'lastSyncAt': int(now),
        'lastError': None,
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
    _, wanted_entries, _ = wanted_entries_from_requests(requests_doc, catalogue)
    wanted_rels = {e['catalogue']['relativePath'] for e in wanted_entries}
    hot_map = hot_file_state(cfg['hot_dir'])
    local_rels = set(hot_map) & wanted_rels
    per_playlist = []
    any_missing = False
    for playlist in requests_doc['playlists']:
        key = playlist.get('key', '')
        title = playlist.get('title', key)
        tracks = playlist.get('tracks') or []
        wanted = len(tracks)
        local_count = 0
        entries = index_catalogue(catalogue)
        for track in tracks:
            matches, _ = match_track(track, entries)
            if matches and matches[0]['relativePath'] in hot_map:
                local_count += 1
        missing = wanted - local_count
        if wanted and local_count < wanted:
            any_missing = True
        per_playlist.append({
            'name': title,
            'key': key,
            'wanted': wanted,
            'local': local_count,
            'missing': max(0, missing),
        })
    last_err = None
    last_sync = None
    if isinstance(last_status, dict):
        last_err = last_status.get('lastError')
        last_sync = last_status.get('lastSyncAt')
    failed = bool(last_err)
    return {
        'schemaVersion': STATUS_SCHEMA,
        'playlists': per_playlist,
        'hotBytes': bytes_in_hot(hot_map),
        'capBytes': int(cfg['cap_gb'] * 1_000_000_000),
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
        cap_bytes = int(cfg['cap_gb'] * 1_000_000_000)
        requests_doc = load_requests(args.requests)

        if args.command in ('plan', 'sync', 'status'):
            if getattr(args, 'refresh_catalogue', False) or load_cached_catalogue(state) is None:
                if not rclone_bin():
                    raise RuntimeError('rclone required to refresh catalogue')
                catalogue = refresh_catalogue_cache(cfg['remote'], state)
            else:
                catalogue = load_cached_catalogue(state)

        if args.command == 'plan':
            remote_rels = remote_list_files(cfg['remote']) if rclone_bin() else set(e['relativePath'] for e in index_catalogue(catalogue))
            plan = compute_plan(requests_doc, catalogue, cfg['hot_dir'], load_played(state), load_fetched(state),
                                remote_rels, cap_bytes, cfg['keep_days'])
            print(json.dumps(plan, indent=2, ensure_ascii=False))
            return 2 if plan['unmatched'] or plan['overflow'] else 0

        if args.command == 'status':
            last_status = {}
            try:
                last_status = json.loads((state_dir(state) / 'last-status.json').read_text())
            except (OSError, ValueError, json.JSONDecodeError):
                pass
            doc = build_status(requests_doc, catalogue, cfg, state, last_status)
            print(json.dumps(doc, indent=2, ensure_ascii=False))
            return 0 if doc['healthy'] else 1

        if args.command == 'sync':
            lock = None
            try:
                lock, _ = acquire_lock(state)
                if getattr(args, 'refresh_catalogue', False) or load_cached_catalogue(state) is None:
                    catalogue = refresh_catalogue_cache(cfg['remote'], state)
                else:
                    catalogue = load_cached_catalogue(state)
                remote_rels = remote_list_files(cfg['remote'])
                plan = compute_plan(requests_doc, catalogue, cfg['hot_dir'], load_played(state), load_fetched(state),
                                    remote_rels, cap_bytes, cfg['keep_days'])
                sync_execute(plan, cfg, state, remote_rels, allow_metered=args.allow_metered)
                print(json.dumps({'synced': True, 'fetched': len(plan['toFetch']), 'evicted': len(plan['evict'])}, indent=2))
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
