#!/usr/bin/env python3
"""One music store for Glancebar, Onto the TV and the 6IAN radio (decided 19 Nov 2026).

Every store has exactly one writer; the apps only read it (docs/music-unify.md).

  ids.json     music/ids.json in the bucket: sha256 of the master (the song's id) by Apple id,
               persistent id, YouTube id, ISRC, path and embed.match_key. Written only by the
               catalogue builder (musiclib.py catalogue --from-remote calls build_ids).
  taste log    music/taste/<listener>/<YYYY-MM>/<app>-<host>.jsonl: append-only events, one
               object per writer (the host that appends through this tool). Local spool first,
               so an append never waits on the network; `flush` copies changed shards up.
  facts        music/facts.json (tools/music-store/facts.py is its only writer).

  musicstore.py append --listener L --app A --kind K [--sha S | --artist A --title T] [--fraction F]
  musicstore.py flush             copy this host's changed taste shards to the bucket
  musicstore.py pull              fetch ids.json and facts.json into the local state folder
  musicstore.py taste-pull        fetch every listener's shards (read side)
  musicstore.py taste-counts      events per listener and kind, from the pulled shards
  musicstore.py import-radio      derive the 6IAN radio's own events (radio/profiles) into the log
  musicstore.py resolve [--apple ID|--persistent ID|--youtube ID|--isrc X|--artist A --title T]
  musicstore.py claims --youtube-dir DIR | --apple-ledger F | --liked-pulled F | --library F --out F
  musicstore.py sync              flush + pull (+ import-radio where the config says so)

Config ~/.config/glancebar/music-store.json (per Mac, never in git):
  {"remote": "...", "host": "m5", "listeners": [...], "radio_accounts": {"<account>": "<listener>"},
   "import_radio": true}
State ~/.local/state/music-store/ (MUSIC_STORE_STATE overrides). Python 3.9+, stdlib and rclone.
"""
from __future__ import annotations

import argparse
import fcntl
import glob
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HOME = Path.home()
HERE = Path(__file__).resolve().parent
for _cand in (HERE, HERE.parent / 'music-embed'):
    if (_cand / 'embed.py').is_file() and str(_cand) not in sys.path:
        sys.path.insert(0, str(_cand))
from embed import match_key  # noqa: E402  (the one song key; the TV mirrors it in JS)

IDS_KEY = 'music/ids.json'
FACTS_KEY = 'music/facts.json'
TASTE_PREFIX = 'music/taste'
CONFIG = Path(os.environ.get('MUSIC_STORE_CONFIG', HOME / '.config/glancebar/music-store.json'))
LIB_CONFIG = HOME / '.config/glancebar/music-library.json'
STATE = Path(os.environ.get('MUSIC_STORE_STATE', HOME / '.local/state/music-store'))
METERED = HOME / '.local/state/METERED_LINK'
KINDS = ('play', 'finish', 'skip', 'early-skip', 'like', 'unlike', 'dislike', 'undislike',
         'heart', 'unheart', 'more', 'less')
NAME_RE = re.compile(r'^[a-z0-9][a-z0-9._-]{0,47}$')
SHA_RE = re.compile(r'^[0-9a-f]{64}$')
YT_RE = re.compile(r'\[([A-Za-z0-9_-]{11})\](?=\.[A-Za-z0-9]{2,4}$)')
VIDEO_SUFFIXES = {'.mp4', '.mkv', '.webm', '.m4v', '.mov', '.m4a'}
YT_NOISE = re.compile(r'\b(official\s+(music\s+)?video|official\s+audio|lyric\s+video|visuali[sz]er|'
                      r'music\s+video|hd|hq|4k)\b', re.I)


# --- small helpers ------------------------------------------------------------------------------

def load_json(path, default):
    try:
        return json.loads(Path(path).read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return default


def write_json(path, doc):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=f'.{path.name}-', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as fh:
            json.dump(doc, fh, ensure_ascii=False, separators=(',', ':'), sort_keys=True)
            fh.write('\n')
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def now_iso(t=None):
    return time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(time.time() if t is None else t))


def config():
    c = load_json(CONFIG, {})
    if not c.get('remote'):
        c['remote'] = (load_json(LIB_CONFIG, {}).get('remote') or '').rstrip('/')
    return c


def host_name(cfg=None):
    h = (cfg or config()).get('host') or os.uname().nodename.split('.')[0]
    return re.sub(r'[^a-z0-9-]+', '-', h.lower()).strip('-') or 'host'


def rclone(argv, timeout=600):
    exe = shutil.which('rclone') or '/opt/homebrew/bin/rclone'
    return subprocess.run([exe, *argv], capture_output=True, text=True, timeout=timeout)


def key_text(artist, title):
    """embed.match_key as one string, 'artist|title'; None when either half is empty."""
    a, t = match_key(artist or '', title or '')
    return f'{a}|{t}' if a and t else None


# --- the alias table (written by the catalogue builder only) ------------------------------------

def read_claims(paths):
    """Alias claims, one JSON object a line: {kind, id, sha|relativePath|artist+title, source}."""
    out = []
    for pattern in paths or []:
        for name in sorted(glob.glob(os.path.expanduser(pattern))):
            try:
                text = Path(name).read_text(encoding='utf-8')
            except OSError:
                continue
            for line in text.splitlines():
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if isinstance(row, dict) and row.get('kind') and row.get('id'):
                    out.append(row)
    return out


def _canonical(shas, entry_by_sha, previous):
    """One sha for a key several masters share: the one chosen before, else the earliest added."""
    if previous in shas:
        return previous
    return min(shas, key=lambda s: (int(entry_by_sha[s].get('mtimeNs') or 0), s))


def build_ids(entries, claims=(), previous=None):
    previous = previous or {}
    prev_key = previous.get('key') or {}
    entry_by_sha, by_path, by_key, by_isrc = {}, {}, {}, {}
    for e in entries:
        sha, rel = e.get('sha256'), e.get('relativePath')
        if not sha or not rel:
            continue
        entry_by_sha.setdefault(sha, e)
        by_path[rel] = sha
        tags = e.get('tags') or {}
        k = key_text(tags.get('artist'), tags.get('title'))
        if k:
            by_key.setdefault(k, set()).add(sha)
        isrc = ((e.get('meta') or {}).get('isrc') or '').strip().upper()
        if isrc:
            by_isrc.setdefault(isrc, set()).add(sha)
    key_map, collisions = {}, {}
    for k, shas in by_key.items():
        key_map[k] = _canonical(shas, entry_by_sha, prev_key.get(k))
        if len(shas) > 1:
            collisions[k] = sorted(shas)
    isrc_map = {i: _canonical(s, entry_by_sha, (previous.get('isrc') or {}).get(i)) for i, s in by_isrc.items()}
    aliases = {'apple': {}, 'persistent': {}, 'youtube': {}}
    how = {'apple': {}, 'persistent': {}, 'youtube': {}}
    unresolved = {k: 0 for k in aliases}
    for c in claims:
        kind = c.get('kind')
        if kind not in aliases:
            continue
        cid = str(c['id'])
        sha, via = None, None
        if c.get('sha') in entry_by_sha:
            sha, via = c['sha'], 'sha'
        elif c.get('relativePath') in by_path:
            sha, via = by_path[c['relativePath']], 'path'
        elif c.get('isrc') and str(c['isrc']).upper() in isrc_map:
            sha, via = isrc_map[str(c['isrc']).upper()], 'isrc'
        else:
            k = key_text(c.get('artist'), c.get('title'))
            if k and k in key_map:
                sha, via = key_map[k], 'key'
        if not sha:
            unresolved[kind] += 1
            continue
        # A direct claim (sha or path) beats one resolved by name.
        if cid in aliases[kind] and how[kind][cid] in ('sha', 'path') and via == 'key':
            continue
        aliases[kind][cid] = sha
        how[kind][cid] = via
    # Carry forward an alias whose song is still catalogued but whose claim was not offered this
    # run (a drive that could not be read tonight must not drop the TV's YouTube ids).
    for kind in aliases:
        for cid, sha in (previous.get(kind) or {}).items():
            if cid not in aliases[kind] and sha in entry_by_sha:
                aliases[kind][cid] = sha
                how[kind][cid] = (previous.get('how') or {}).get(kind, {}).get(cid, 'carried')
    counts = {'songs': len(entry_by_sha), 'key': len(key_map), 'collisions': len(collisions),
              'isrc': len(isrc_map), 'path': len(by_path),
              **{k: len(v) for k, v in aliases.items()}, 'unresolved': unresolved}
    return {'schemaVersion': 1, 'generatedAt': int(time.time()), 'key': key_map, 'isrc': isrc_map,
            'path': by_path, **aliases, 'how': how, 'collisions': collisions, 'counts': counts}


class Ids:
    """Read side of the alias table. resolve() answers (sha, how) or (None, None)."""

    def __init__(self, doc):
        self.doc = doc or {}

    @classmethod
    def load(cls, path=None):
        return cls(load_json(path or STATE / 'ids.json', {}))

    def __bool__(self):
        return bool(self.doc.get('key'))

    def resolve(self, *, apple=None, persistent=None, youtube=None, isrc=None, path=None,
                artist=None, title=None):
        d = self.doc
        for kind, value in (('persistent', persistent), ('apple', apple), ('youtube', youtube),
                            ('path', path)):
            if value and str(value) in (d.get(kind) or {}):
                return d[kind][str(value)], kind
        if isrc and str(isrc).upper() in (d.get('isrc') or {}):
            return d['isrc'][str(isrc).upper()], 'isrc'
        k = key_text(artist, title)
        if k and k in (d.get('key') or {}):
            return d['key'][k], 'key'
        return None, None


# --- alias claims (inputs to the builder; written on the Mac that has the source) ---------------

def youtube_claims(root):
    """Video files named '... [VIDEOID].ext' under root, with the artist and title they name."""
    out = []
    root = Path(root)
    for folder, _dirs, names in os.walk(root):
        for name in names:
            m = YT_RE.search(name)
            if not m or Path(name).suffix.lower() not in VIDEO_SUFFIXES:
                continue
            stem = re.sub(r'\s*\[[A-Za-z0-9_-]{11}\]\s*$', '', Path(name).stem).strip()
            stem = re.sub(r'\s*[｜|]\s*.*$', '', stem)  # "Song | A COLORS SHOW"
            parent = Path(folder).name
            if ' - ' in stem:
                artist, title = stem.split(' - ', 1)
            else:
                artist, title = parent, stem
            title = re.sub(r'\s*[\(\[]\s*[\)\]]', '', YT_NOISE.sub('', title)).strip(' -')
            out.append({'kind': 'youtube', 'id': m.group(1), 'artist': artist.strip(), 'title': title,
                        'source': 'video-file'})
    return out


def apple_claims_from_ledger(path):
    """The scout's acquisitions: Apple song id (from the url) and the master's sha."""
    out = []
    try:
        lines = Path(path).read_text(encoding='utf-8').splitlines()
    except OSError:
        return out
    for line in lines:
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if not isinstance(r, dict) or r.get('action') != 'acquired':
            continue
        m = re.search(r'/(\d{6,})(?:\?|$)', r.get('url') or '')
        if m:
            out.append({'kind': 'apple', 'id': m.group(1), 'sha': r.get('sha256'),
                        'relativePath': r.get('catalogue_relative_path'), 'artist': r.get('artist'),
                        'title': r.get('title'), 'source': 'scout-ledger'})
    return out


def apple_claims_from_liked(path):
    doc = load_json(path, {})
    out = []
    for key, row in (doc.get('done') or {}).items():
        if not isinstance(row, dict) or not row.get('track_id'):
            continue
        artist, _, title = key.partition('|')
        out.append({'kind': 'apple', 'id': str(row['track_id']), 'artist': artist, 'title': title,
                    'source': 'liked-pulled'})
    return out


def persistent_claims_from_library(path):
    doc = load_json(path, {})
    out = []
    for t in (doc.get('tracks') if isinstance(doc, dict) else None) or []:
        if isinstance(t, dict) and t.get('id') and t.get('artist') and t.get('title'):
            out.append({'kind': 'persistent', 'id': str(t['id']), 'artist': t['artist'], 'title': t['title'],
                        'source': 'music-library'})
    return out


# --- the taste log --------------------------------------------------------------------------------

def event_id(ev):
    basis = '|'.join(str(ev.get(k) or '') for k in ('listener', 'app', 'host', 'at', 'sha', 'alias', 'kind'))
    return hashlib.sha1(basis.encode('utf-8')).hexdigest()[:20]


def make_event(listener, app, kind, *, sha=None, alias=None, fraction=None, at=None, host=None, extra=None):
    if not NAME_RE.match(listener or ''):
        raise ValueError(f'bad listener name: {listener!r}')
    if not NAME_RE.match(app or ''):
        raise ValueError(f'bad app name: {app!r}')
    if kind not in KINDS:
        raise ValueError(f'unknown kind {kind!r} (one of {", ".join(KINDS)})')
    if sha is not None and not SHA_RE.match(sha):
        raise ValueError('sha must be 64 hex characters')
    if not sha and not alias:
        raise ValueError('an event names its song: sha, or an alias such as key:artist|title')
    ev = {'at': at or now_iso(), 'listener': listener, 'app': app, 'host': host or host_name(), 'kind': kind}
    if sha:
        ev['sha'] = sha
    if alias:
        ev['alias'] = alias
    if fraction is not None:
        ev['fraction'] = round(max(0.0, min(1.0, float(fraction))), 4)
    if extra:
        ev.update({k: v for k, v in extra.items() if k not in ev})
    ev['id'] = event_id(ev)
    return ev


def shard_path(state, ev):
    month = ev['at'][:7]
    return Path(state) / 'taste' / ev['listener'] / month / f"{ev['app']}-{ev['host']}.jsonl"


def append(ev, state=None):
    """Append one event to this host's spool; an event already there (same id) is not added twice.
    Returns True when written. Never touches the network."""
    path = shard_path(state or STATE, ev)
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, 'a+', encoding='utf-8') as fh:
        fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
        fh.seek(0)
        if any(f'"id":"{ev["id"]}"' in line for line in fh):
            return False
        fh.seek(0, os.SEEK_END)
        fh.write(json.dumps(ev, ensure_ascii=False, separators=(',', ':'), sort_keys=True) + '\n')
        fh.flush()
        os.fsync(fh.fileno())
    return True


def flush(state=None, cfg=None, runner=None):
    """Copy this host's changed shards to the bucket. Each shard is named <app>-<host>.jsonl and
    only that host's spool holds it, so each object has one writer."""
    state = Path(state or STATE)
    cfg = cfg or config()
    marks_path = state / 'taste-flushed.json'
    marks = load_json(marks_path, {})
    sent = failed = 0
    for path in sorted((state / 'taste').glob('*/*/*.jsonl')):
        rel = str(path.relative_to(state / 'taste'))
        st = path.stat()
        stamp = f'{st.st_size}:{st.st_mtime_ns}'
        if marks.get(rel) == stamp:
            continue
        proc = (runner or rclone)(['copyto', str(path), f"{cfg['remote']}/{TASTE_PREFIX}/{rel}"])
        if proc.returncode == 0:
            marks[rel] = stamp
            sent += 1
        else:
            failed += 1
    write_json(marks_path, marks)
    return {'sent': sent, 'failed': failed}


def taste_pull(state=None, cfg=None, runner=None):
    """Every listener's shards from the bucket into state/taste-all/ (the read side)."""
    state = Path(state or STATE)
    cfg = cfg or config()
    proc = (runner or rclone)(['copy', f"{cfg['remote']}/{TASTE_PREFIX}", str(state / 'taste-all'), '--fast-list'])
    return proc.returncode == 0


def read_events(root, listener=None):
    """Merged, de-duplicated events under root (taste-all/ or the spool), oldest first."""
    seen, out = set(), []
    pattern = f'{listener or "*"}/*/*.jsonl'
    for path in sorted(Path(root).glob(pattern)):
        for line in path.read_text(encoding='utf-8').splitlines():
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            if isinstance(ev, dict) and ev.get('id') not in seen:
                seen.add(ev.get('id'))
                out.append(ev)
    out.sort(key=lambda e: e.get('at') or '')
    return out


RADIO_KINDS = {'play': 'play', 'finish': 'finish', 'skip': 'skip', 'like': 'like', 'unlike': 'unlike',
               'dislike': 'dislike', 'undislike': 'undislike', 'more': 'more', 'less': 'less'}


def radio_events(profile, listener, host=None):
    """The radio's own events from a profile (radio/profiles/<account>.json) as taste events.
    Events that came in from another app (via a device token, e.g. Glancebar) are left out: that
    app logs them itself."""
    out = []
    for e in profile.get('events') or []:
        via = str(e.get('via') or 'session')
        if via not in ('session', 'voice') or e.get('ev') not in RADIO_KINDS or not SHA_RE.match(str(e.get('s') or '')):
            continue
        try:
            at = now_iso(float(e['ts']) / 1000.0)
        except (KeyError, TypeError, ValueError):
            continue
        extra = {k: e[k] for k in ('src', 'm') if e.get(k) is not None}
        out.append(make_event(listener, '6ian', RADIO_KINDS[e['ev']], sha=e['s'], at=at, host=host or host_name(),
                              extra=extra or None))
    return out


def import_radio(state=None, cfg=None, runner=None):
    """Derive the radio's events into the log (until 6IAN appends through this tool itself)."""
    state = Path(state or STATE)
    cfg = cfg or config()
    accounts = cfg.get('radio_accounts') or {}
    added = {}
    for account, listener in accounts.items():
        if account.endswith('-qa'):
            continue
        proc = (runner or rclone)(['cat', f"{cfg['remote']}/radio/profiles/{account}.json"], timeout=120)
        if proc.returncode != 0:
            continue
        try:
            profile = json.loads(proc.stdout)
        except ValueError:
            continue
        n = 0
        for ev in radio_events(profile, listener, host_name(cfg)):
            n += append(ev, state)
        added[listener] = added.get(listener, 0) + n
    return added


def pull(state=None, cfg=None, runner=None):
    """ids.json and facts.json into the state folder (readers use the local copy)."""
    state = Path(state or STATE)
    cfg = cfg or config()
    got = {}
    for key in (IDS_KEY, FACTS_KEY):
        dest = state / Path(key).name
        part = dest.with_name(dest.name + '.part')
        state.mkdir(parents=True, exist_ok=True)
        proc = (runner or rclone)(['copyto', f"{cfg['remote']}/{key}", str(part)])
        if proc.returncode == 0 and part.is_file() and load_json(part, None) is not None:
            os.replace(part, dest)
            got[Path(key).name] = True
        else:
            if part.exists():
                part.unlink()
            got[Path(key).name] = False
    return got


# --- command line ---------------------------------------------------------------------------------

def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest='cmd', required=True)
    a = sub.add_parser('append')
    a.add_argument('--listener', required=True)
    a.add_argument('--app', required=True)
    a.add_argument('--kind', required=True)
    a.add_argument('--sha')
    a.add_argument('--alias', help='kind:value, e.g. youtube:VIDEOID or key:artist|title')
    a.add_argument('--artist')
    a.add_argument('--title')
    a.add_argument('--youtube')
    a.add_argument('--fraction', type=float)
    a.add_argument('--at')
    a.add_argument('--flush', action='store_true')
    sub.add_parser('flush')
    sub.add_parser('pull')
    sub.add_parser('taste-pull')
    tc = sub.add_parser('taste-counts')
    tc.add_argument('--spool', action='store_true', help="count this host's spool, not the pulled copy")
    sub.add_parser('import-radio')
    sub.add_parser('sync')
    r = sub.add_parser('resolve')
    for name in ('apple', 'persistent', 'youtube', 'isrc', 'path', 'artist', 'title'):
        r.add_argument(f'--{name}')
    c = sub.add_parser('claims')
    c.add_argument('--youtube-dir', action='append', default=[])
    c.add_argument('--apple-ledger')
    c.add_argument('--liked-pulled')
    c.add_argument('--library')
    c.add_argument('--out', required=True)
    args = p.parse_args(argv)
    cfg = config()

    if args.cmd == 'append':
        ids = Ids.load()
        sha, alias = args.sha, args.alias
        if not sha:
            sha, _how = ids.resolve(youtube=args.youtube, artist=args.artist, title=args.title)
        if not sha and not alias:
            if args.youtube:
                alias = f'youtube:{args.youtube}'
            elif key_text(args.artist, args.title):
                alias = f'key:{key_text(args.artist, args.title)}'
        ev = make_event(args.listener, args.app, args.kind, sha=sha, alias=alias, fraction=args.fraction,
                        at=args.at, host=host_name(cfg))
        wrote = append(ev)
        out = {'ok': True, 'written': wrote, 'id': ev['id'], 'sha': sha}
        if args.flush and not METERED.exists():
            out['flush'] = flush(cfg=cfg)
        print(json.dumps(out))
        return 0
    if args.cmd == 'flush':
        print(json.dumps(flush(cfg=cfg)))
        return 0
    if args.cmd == 'pull':
        print(json.dumps(pull(cfg=cfg)))
        return 0
    if args.cmd == 'taste-pull':
        print(json.dumps({'ok': taste_pull(cfg=cfg)}))
        return 0
    if args.cmd == 'taste-counts':
        root = STATE / ('taste' if args.spool else 'taste-all')
        counts = {}
        for ev in read_events(root):
            row = counts.setdefault(ev.get('listener'), {})
            row[ev.get('kind')] = row.get(ev.get('kind'), 0) + 1
        print(json.dumps(counts, sort_keys=True))
        return 0
    if args.cmd == 'import-radio':
        print(json.dumps(import_radio(cfg=cfg)))
        return 0
    if args.cmd == 'sync':
        out = {'at': now_iso()}
        if METERED.exists():
            out['skipped'] = 'metered link'
        else:
            if cfg.get('import_radio'):
                out['radio'] = import_radio(cfg=cfg)
            out['flush'] = flush(cfg=cfg)
            out['pull'] = pull(cfg=cfg)
        write_json(STATE / 'sync-status.json', out)
        print(json.dumps(out))
        return 0 if not (out.get('flush') or {}).get('failed') else 1
    if args.cmd == 'resolve':
        sha, how = Ids.load().resolve(apple=args.apple, persistent=args.persistent, youtube=args.youtube,
                                      isrc=args.isrc, path=args.path, artist=args.artist, title=args.title)
        print(json.dumps({'sha': sha, 'how': how}))
        return 0 if sha else 1
    if args.cmd == 'claims':
        rows = []
        for d in args.youtube_dir:
            rows += youtube_claims(d)
        if args.apple_ledger:
            rows += apple_claims_from_ledger(args.apple_ledger)
        if args.liked_pulled:
            rows += apple_claims_from_liked(args.liked_pulled)
        if args.library:
            rows += persistent_claims_from_library(args.library)
        out = Path(args.out).expanduser()
        out.parent.mkdir(parents=True, exist_ok=True)
        tmp = out.with_name(out.name + '.part')
        tmp.write_text(''.join(json.dumps(r, ensure_ascii=False, sort_keys=True) + '\n' for r in rows), encoding='utf-8')
        os.replace(tmp, out)
        print(json.dumps({'claims': len(rows), 'out': str(out)}))
        return 0
    return 2


if __name__ == '__main__':
    sys.exit(main())
