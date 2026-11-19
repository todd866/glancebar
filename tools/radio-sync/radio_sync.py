#!/usr/bin/env python3
"""Glancebar <-> 6IAN web radio: one taste profile, one library, shared moods and stations.

The radio is the second front end to the same library (docs/music.md, "Glancebar and 6IAN").
This tool is the only bridge; the app calls it, and launchd runs `sync` every 10 minutes.

  radio_sync.py sync              push Glancebar likes/dislikes/early skips/plays to the radio,
                                  pull the radio's likes/dislikes into Glancebar's feedback,
                                  refresh the mood + station list and the hot-set request
  radio_sync.py queue MOOD        a radio queue for MOOD (a mood id or station:<id>) written as
                                  a station file the app plays like New music (lossless, local)
  radio_sync.py about ARTIST TITLE  the radio's sourced facts for a song (JSON, sources named)
  radio_sync.py status            one line: last sync, counts, errors

Config: ~/.config/glancebar/radio.json {url, token} (0600, minted by the radio repo's
tools/device-token.mjs; never in git). State: ~/.local/state/glancebar-radio/.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

HOME = Path.home()
CONFIG = HOME / '.config/glancebar/radio.json'
STATE = Path(os.environ.get('GLANCEBAR_RADIO_STATE', HOME / '.local/state/glancebar-radio'))
MIX = Path(os.environ.get('GLANCEBAR_MIX_DIR', HOME / 'Library/Application Support/Glancebar/mix'))
LIB_CONFIG = HOME / '.config/glancebar/music-library.json'
HEARTS = Path(os.environ.get('GLANCEBAR_HEARTS', HOME / '.local/state/selector/heart-history.jsonl'))
EARLY = 0.4          # a Next before 40% of the song is an early skip (the scout's rule)
SOURCE = '6ian'      # lines this tool writes into Glancebar's feedback carry this, so they never echo back
UA = 'glancebar-radio-sync/1.0'


def music_store():
    """tools/music-store (the alias table and the taste log), or None where it is not installed
    (the app's bundled copy of this file runs without it)."""
    here = Path(__file__).resolve().parent
    for cand in (here, here.parent / 'music-store'):
        if (cand / 'musicstore.py').is_file() and str(cand) not in sys.path:
            sys.path.insert(0, str(cand))
    try:
        import musicstore
        return musicstore
    except Exception:
        return None


def resolve_events(evs, store=None):
    """Name each event's song by its sha through the one alias table (music/ids.json): the library
    id first, then embed.match_key. Unresolved events keep only artist and title, so the radio's
    own exact match is the fallback; the counts go into status.json."""
    store = store if store is not None else music_store()
    ids = store.Ids.load() if store else None
    counts = {'ids': 0, 'fallback': 0}
    for e in evs:
        sha, how = (ids.resolve(persistent=e.get('pid'), artist=e['artist'], title=e['title'])
                    if ids else (None, None))
        if sha:
            e['s'] = sha
            e['how'] = how
            counts['ids'] += 1
        else:
            counts['fallback'] += 1
    return counts


def _fraction(o):
    f = (o.get('playback') or {}).get('fraction')
    return float(f) if isinstance(f, (int, float)) else None


def _rel_from_path(path):
    """A hot-set file's catalogue path (the hot set mirrors the bucket's layout)."""
    cfg = load_json(LIB_CONFIG, {})
    hot = os.path.expanduser(cfg.get('hot_dir', '~/Music/Glancebar Lossless')).rstrip('/') + '/'
    return path[len(hot):] if path and path.startswith(hot) else None


def log_taste(store=None, listener=None):
    """Glancebar's marks into the one taste log (tools/music-store; docs/music-unify.md): likes,
    dislikes, hearts, every Next press (early-skip under 40%), and plays. Read from the files the
    app writes (it does not call the log itself yet), with cursors of their own, so the radio
    bridge above and this log never depend on each other. Lines this tool wrote from the radio
    (source 6ian) are the radio's events, not Glancebar's, and are left out."""
    store = store if store is not None else music_store()
    if not store:
        return {'skipped': 'music-store not installed'}
    cfg = load_json(store.CONFIG, {})
    listener = listener or cfg.get('glancebar_listener') or 'ian'
    ids = store.Ids.load()
    cur = load_json(STATE / 'taste-cursor.json', {})
    n = {'written': 0, 'unresolved': 0}

    def add(kind, o, *, pid=None, rel=None, fraction=None, at=None):
        artist, title = o.get('artist'), o.get('title')
        sha, _how = ids.resolve(persistent=pid, path=rel, artist=artist, title=title)
        alias = None if sha else (f"key:{store.key_text(artist, title)}" if store.key_text(artist, title) else None)
        if not sha and not alias:
            return
        if not sha:
            n['unresolved'] += 1
        ev = store.make_event(listener, 'glancebar', kind, sha=sha, alias=alias, fraction=fraction,
                              at=at or o.get('at'))
        n['written'] += store.append(ev)

    fb, cur['feedback'] = read_lines(MIX / 'feedback.jsonl', cur.get('feedback', 0))
    for o in fb:
        if o.get('source') == SOURCE:
            continue
        ev = o.get('event')
        if ev not in ('dislike', 'undislike'):
            ev = 'like' if o.get('liked') is True else 'unlike' if o.get('liked') is False else None
        if ev:
            add(ev, o, fraction=_fraction(o))
    sk, cur['skips'] = read_lines(MIX / 'skip-history.jsonl', cur.get('skips', 0))
    for o in sk:
        f = _fraction(o)
        add('early-skip' if f is not None and f < EARLY else 'skip', o, rel=_rel_from_path(o.get('path')), fraction=f)
    hh, cur['hearts'] = read_lines(HEARTS, cur.get('hearts', 0))
    for o in hh:
        if o.get('action') in ('heart', 'unheart'):
            add(o['action'], o, fraction=_fraction(o))
    lib = load_json(MIX / 'library.json', {}).get('tracks') or []
    by_id = {t.get('id'): t for t in lib if isinstance(t, dict)}
    last = newest = cur.get('plays', 0)
    for p in recent_plays():
        t = by_id.get(p.get('id'))
        if p.get('at', 0) > last and t:
            add('play', t, pid=p.get('id'), at=store.now_iso(p['at']))
            newest = max(newest, p['at'])
    cur['plays'] = newest
    atomic_write(STATE / 'taste-cursor.json', cur)
    if not store.METERED.exists():
        n['flush'] = store.flush()
        n['pull'] = store.pull()
    return n


def now_iso():
    return time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())


def load_json(p, default):
    try:
        return json.loads(Path(p).read_text())
    except (OSError, ValueError):
        return default


def atomic_write(p, doc):
    p = Path(p)
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(p.suffix + '.tmp')
    tmp.write_text(json.dumps(doc, indent=1, ensure_ascii=False))
    os.replace(tmp, p)


def config():
    c = load_json(CONFIG, None)
    if not c or not c.get('url') or not c.get('token'):
        raise SystemExit(f'radio-sync: no device token in {CONFIG}')
    return c


def api(c, method, path, body=None, timeout=30):
    req = urllib.request.Request(c['url'].rstrip('/') + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={'authorization': f"Bearer {c['token']}", 'content-type': 'application/json', 'user-agent': UA})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read() or b'null')


def track_key(artist, title):
    """Glancebar's SelectorTrackKey: lower case, runs of non-alphanumerics -> one space."""
    def f(v):
        v = (v or '').replace(' ', ' ').lower()
        out, word = [], ''
        for ch in v:
            if ch.isalnum() or ch == '_':
                word += ch
            elif word:
                out.append(word); word = ''
        if word:
            out.append(word)
        return ' '.join(out)
    a, t = f(artist), f(title)
    return f'{a}|{t}' if a and t else None


def read_lines(path, offset):
    """New complete lines after byte offset (a file that shrank was rotated: start again)."""
    try:
        size = path.stat().st_size
    except OSError:
        return [], 0
    if size < offset:
        offset = 0
    with path.open('rb') as fh:
        fh.seek(offset)
        data = fh.read()
    end = data.rfind(b'\n') + 1
    lines = []
    for raw in data[:end].splitlines():
        try:
            o = json.loads(raw)
        except ValueError:
            continue
        if isinstance(o, dict):
            lines.append(o)
    return lines, offset + end


def epoch_ms(iso):
    try:
        return int(time.mktime(time.strptime(iso[:19], '%Y-%m-%dT%H:%M:%S')) * 1000 - time.timezone * 1000)
    except (TypeError, ValueError):
        return None


def glancebar_events(cur):
    """Glancebar's own marks since the last sync, as radio events (never lines this tool wrote)."""
    evs = []
    fb, cur['feedback'] = read_lines(MIX / 'feedback.jsonl', cur.get('feedback', 0))
    for o in fb:
        if o.get('source') == SOURCE or not o.get('artist') or not o.get('title'):
            continue
        ev = o.get('event')
        if ev not in ('dislike', 'undislike'):
            ev = 'like' if o.get('liked') is True else 'unlike' if o.get('liked') is False else None
        if ev:
            evs.append({'ev': ev, 'artist': o['artist'], 'title': o['title'], 'at': epoch_ms(o.get('at'))})
    sk, cur['skips'] = read_lines(MIX / 'skip-history.jsonl', cur.get('skips', 0))
    for o in sk:
        frac = ((o.get('playback') or {}).get('fraction'))
        if o.get('artist') and o.get('title') and isinstance(frac, (int, float)) and frac < EARLY:
            evs.append({'ev': 'skip', 'artist': o['artist'], 'title': o['title'], 'at': epoch_ms(o.get('at'))})
    # Plays: the app's recent-plays list (library ids) mapped through its library copy.
    lib = load_json(MIX / 'library.json', {}).get('tracks') or []
    by_id = {t.get('id'): t for t in lib if isinstance(t, dict)}
    last = cur.get('plays', 0)
    newest = last
    for p in recent_plays():
        at = p.get('at', 0)
        t = by_id.get(p.get('id'))
        if at > last and t and t.get('artist') and t.get('title'):
            evs.append({'ev': 'play', 'artist': t['artist'], 'title': t.get('title'), 'at': int(at * 1000),
                        'pid': p.get('id')})
            newest = max(newest, at)
    cur['plays'] = newest
    return [e for e in evs if e['at'] is None or e['at'] > 0]


def recent_plays():
    import plistlib
    import subprocess
    try:
        out = subprocess.run(['defaults', 'export', 'com.iantodd.glancebar', '-'], capture_output=True, timeout=20).stdout
        rows = plistlib.loads(out).get('musicRecentPlays') or []
    except Exception:
        return []
    res = []
    for r in rows:
        try:
            res.append({'id': r.get('id'), 'at': float(r.get('at'))})
        except (TypeError, ValueError, AttributeError):
            pass
    return res


def apply_radio_taste(taste, applied, own):
    """Radio likes and dislikes into Glancebar's feedback (the app reloads it when it changes).
    `applied` holds only lines this tool wrote; `own` holds Glancebar's own marks, never echoed.
    Only lines this tool wrote are ever undone."""
    lines = []
    for kind in ('likes', 'dislikes'):
        for r in taste.get(kind) or []:
            key = track_key(r.get('artist'), r.get('title'))
            if not key:
                continue
            mark = f'{kind}:{key}'
            if mark in applied or mark in own:
                continue
            applied[mark] = now_iso()
            base = {'artist': r['artist'], 'title': r['title'], 'at': now_iso(), 'trackID': key, 'source': SOURCE}
            if kind == 'likes':
                lines.append({**base, 'liked': True})
            else:
                lines.append({**base, 'track_key': key, 'event': 'dislike', 'liked': False})
    # Marks the radio has since removed: undo them here too, once.
    have = {f"{k}:{track_key(r.get('artist'), r.get('title'))}" for k in ('likes', 'dislikes') for r in taste.get(k) or []}
    for mark in [m for m in applied if m not in have]:
        kind, key = mark.split(':', 1)
        artist, _, title = key.partition('|')
        base = {'artist': artist, 'title': title, 'at': now_iso(), 'trackID': key, 'source': SOURCE}
        lines.append({**base, 'liked': False} if kind == 'likes' else {**base, 'track_key': key, 'event': 'undislike'})
        del applied[mark]
    if lines:
        with (MIX / 'feedback.jsonl').open('a') as fh:  # one write; the app appends whole lines too
            fh.write(''.join(json.dumps(l, sort_keys=True, ensure_ascii=False) + '\n' for l in lines))
    return len(lines)


def hot_requests(taste):
    """The radio's recent likes as an extra hot-set request (musiclib reads it beside the app's)."""
    likes = sorted(taste.get('likes') or [], key=lambda r: r.get('at') or 0, reverse=True)[:60]
    tracks = [{'id': track_key(r['artist'], r['title']) or r['s'], 'title': r['title'], 'artist': r['artist'],
               'album': r.get('album') or '', 'sha256': r['s'], 'catalogue_relative_path': r.get('key') or ''} for r in likes]
    atomic_write(STATE / 'hot-requests.json', {'schemaVersion': 1, 'playlists': [{'key': 'radio:likes', 'title': '6IAN likes', 'tracks': tracks}]})
    return len(tracks)


def cmd_sync():
    c = config()
    cur = load_json(STATE / 'cursor.json', {})
    applied = load_json(STATE / 'applied.json', {})
    out = {'at': now_iso(), 'ok': False}
    try:
        evs = glancebar_events(cur)
        out['resolved'] = resolve_events(evs)
        sent = unmatched = 0
        for i in range(0, len(evs), 400):
            r = api(c, 'POST', '/api/device/signals', {'events': evs[i:i + 400]})
            sent += r.get('applied', 0)
            unmatched += len(r.get('unmatched') or [])
        own = load_json(STATE / 'own.json', {})
        for e in evs:  # Glancebar's own marks: never written back into its feedback by this tool
            key = track_key(e['artist'], e['title'])
            if not key:
                continue
            if e['ev'] in ('like', 'dislike'):
                own[f"{e['ev']}s:{key}"] = now_iso()
            if e['ev'] in ('unlike', 'undislike'):
                own.pop(f"{e['ev'][2:]}s:{key}", None)
        taste = api(c, 'GET', '/api/device/taste')
        written = apply_radio_taste(taste, applied, own)
        hot = hot_requests(taste)
        moods = api(c, 'GET', '/api/device/moods')
        atomic_write(STATE / 'moods.json', {'at': now_iso(), 'moods': moods.get('moods') or [], 'stations': moods.get('stations') or []})
        atomic_write(STATE / 'cursor.json', cur)
        atomic_write(STATE / 'applied.json', applied)
        atomic_write(STATE / 'own.json', own)
        out.update(ok=True, sent=sent, unmatched=unmatched, pulled=written, likes=len(taste.get('likes') or []), dislikes=len(taste.get('dislikes') or []), hot=hot)
    except (urllib.error.URLError, OSError, ValueError) as exc:
        out['error'] = str(exc)[:200]
    try:  # the taste log does not depend on the radio being reachable
        out['taste'] = log_taste()
    except (OSError, ValueError) as exc:
        out['taste'] = {'error': str(exc)[:200]}
    atomic_write(STATE / 'status.json', out)
    print(json.dumps(out))
    return 0 if out['ok'] else 1


def local_rel_exists(rel):
    cfg = load_json(LIB_CONFIG, {})
    hot = Path(os.path.expanduser(cfg.get('hot_dir', '~/Music/Glancebar Lossless')))
    return bool(rel) and (hot / rel).is_file()


def cmd_queue(mood):
    """A queue from the radio's engine, written in the New music station's file format. Songs
    already on this Mac go first so it starts at once; the rest the hot set fetches."""
    c = config()
    r = api(c, 'POST', '/api/queue', {'mood': mood, 'n': 40, 'lossless': True})
    picks = r.get('picks') or []
    rows = []
    for p in picks:
        rel = p.get('key') or ''
        rows.append({'track_key': track_key(p.get('a'), p.get('t')) or p.get('s'), 'title': p.get('t', ''), 'artist': p.get('a', ''),
                     'album': p.get('al', ''), 'duration': p.get('dur'), 'sha256': p.get('s'), 'catalogue_relative_path': rel,
                     'why': ' · '.join(p.get('chips') or []), 'local': local_rel_exists(rel)})
    rows.sort(key=lambda x: not x['local'])
    rows = rows[:20]
    doc = {'at': now_iso(), 'mood': mood, 'label': r.get('mood'), 'rule': (r.get('rule') or {}).get('label'), 'tracks': rows}
    atomic_write(STATE / 'station.json', doc)
    print(json.dumps({'ok': True, 'mood': mood, 'tracks': len(rows), 'local': sum(1 for x in rows if x['local'])}))
    return 0


def cmd_about(artist, title):
    c = config()
    try:
        s = api(c, 'GET', '/api/device/lookup?' + urllib.parse.urlencode({'artist': artist, 'title': title}))['s']
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            print(json.dumps({'ok': False, 'reason': 'not in the radio library'}))
            return 0
        raise
    about = api(c, 'GET', f'/api/info/{s}?kind=about')
    why = api(c, 'GET', f'/api/info/{s}?kind=why')
    print(json.dumps({'ok': True, 's': s, 'facts': about.get('facts') or [], 'artist': about.get('artist'), 'why': why.get('rows') or []}, ensure_ascii=False))
    return 0


def cmd_status():
    print(json.dumps(load_json(STATE / 'status.json', {'ok': False, 'error': 'never synced'})))
    return 0


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    cmd, args = argv[0], argv[1:]
    if cmd == 'sync':
        return cmd_sync()
    if cmd == 'queue' and len(args) == 1:
        return cmd_queue(args[0])
    if cmd == 'about' and len(args) == 2:
        return cmd_about(*args)
    if cmd == 'status':
        return cmd_status()
    print(__doc__)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
