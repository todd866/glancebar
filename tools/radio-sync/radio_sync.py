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
MANIFOLD_HUB = os.environ.get('MANIFOLD_HUB', 'https://manifold-chi.vercel.app')
OTR_MOODS = [
    {'id': 'dance', 'label': 'Dance'},
    {'id': 'alt', 'label': 'Alt'},
    {'id': 'rap', 'label': 'Rap'},
    {'id': 'chill', 'label': 'Chill'},
    {'id': 'new', 'label': 'New music'},
    {'id': 'all', 'label': 'All Lossless'},
]
OTR_MOOD_ALIASES = {
    'dance': 'dance', 'energise': 'dance', 'energize': 'dance', 'workout': 'dance', 'party': 'dance',
    'alt': 'alt', 'alternative': 'alt', 'drive': 'alt', 'heavy': 'alt', 'rock': 'alt', 'indie': 'alt',
    'rap': 'rap', 'hiphop': 'rap', 'hip-hop': 'rap', 'hip hop': 'rap',
    'chill': 'chill', 'focus': 'chill', 'ambient': 'chill', 'calm': 'chill',
    'new': 'new', 'new music': 'new', 'new-music': 'new', 'triplej': 'new',
    'all': 'all', 'all lossless': 'all', 'all-lossless': 'all', 'any': 'all',
}


def music_store():
    """music-core/store (the alias table and the taste log), or None where it is not installed
    (the app's bundled copy of this file runs without it)."""
    here = Path(__file__).resolve().parent
    for cand in (HOME / 'Projects/music-core/store', here, here.parent / 'music-store'):
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
    if not ids and not store.METERED.exists():
        store.pull()
        ids = store.Ids.load()
    if not ids:  # wait for the alias table, so the backlog is logged by sha, not by name
        return {'skipped': 'no ids.json yet'}
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


def _remote_config():
    c = load_json(CONFIG, None)
    if not isinstance(c, dict) or c.get('backend') == 'otr':
        return None
    if c.get('url') and c.get('token'):
        return c
    return None


def config():
    c = _remote_config()
    if not c:
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


def _otr_moods(hub_url=None, offline=False):
    """Glancebar kinds plus best-effort Manifold radio lenses."""
    cfg = load_json(CONFIG, {})
    if not isinstance(cfg, dict):
        cfg = {}
    hub = (hub_url or cfg.get('manifold_hub') or MANIFOLD_HUB or '').rstrip('/')
    stations = []
    if not offline and hub:
        try:
            req = urllib.request.Request(
                f'{hub}/api/v1/lenses?domain=radio',
                headers={'accept': 'application/json', 'user-agent': UA},
            )
            with urllib.request.urlopen(req, timeout=5) as resp:
                raw = json.loads(resp.read().decode('utf-8', errors='replace') or 'null')
            items = raw.get('lenses') if isinstance(raw, dict) else (raw if isinstance(raw, list) else [])
            for item in items or []:
                if not isinstance(item, dict):
                    continue
                lid = str(item.get('id') or item.get('slug') or '').strip()
                label = str(item.get('name') or item.get('title') or lid).strip()
                if not lid or not label:
                    continue
                sid = lid if lid.startswith('station:') else f'station:{lid}'
                entry = {'id': sid, 'label': label}
                for key in ('kinds', 'genres', 'tags'):
                    if isinstance(item.get(key), list):
                        entry[key] = [str(v) for v in item[key] if isinstance(v, str)]
                stations.append(entry)
        except (urllib.error.URLError, OSError, ValueError):
            stations = []
    return {'moods': list(OTR_MOODS), 'stations': stations}


def cmd_sync():
    c = _remote_config()
    cur = load_json(STATE / 'cursor.json', {})
    applied = load_json(STATE / 'applied.json', {})
    out = {'at': now_iso(), 'ok': False}
    if c is None:
        try:
            cfg = load_json(CONFIG, {})
            offline = bool(cfg.get('offline')) if isinstance(cfg, dict) else False
            moods = _otr_moods(offline=offline)
            atomic_write(STATE / 'moods.json', {'at': now_iso(), 'moods': moods.get('moods') or [], 'stations': moods.get('stations') or []})
            out.update(ok=True, mode='otr', moods=len(moods.get('moods') or []), stations=len(moods.get('stations') or []))
        except (OSError, ValueError) as exc:
            out['error'] = str(exc)[:200]
    else:
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


def _find_node():
    import shutil
    nvm = sorted((HOME / '.nvm/versions/node').glob('v*/bin/node'))
    if nvm:
        return str(nvm[-1])
    return shutil.which('node') or '/opt/homebrew/bin/node'


def _local_playable_shas():
    """Shas of tracks currently present on disk in the local lossless hot set."""
    cfg = load_json(LIB_CONFIG, {})
    hot = Path(os.path.expanduser(cfg.get('hot_dir', '~/Music/Glancebar Lossless')))
    cat = load_json(HOME / '.local/state/glancebar-music-library/catalogue.json', {})
    shas = []
    for entry in (cat.get('tracks') or cat.get('entries') or []):
        rel = entry.get('relativePath') or entry.get('path') or ''
        sha = entry.get('sha256') or ''
        if sha and rel and (hot / rel).is_file():
            shas.append(sha)
    return shas


def local_queue(mood, *, n=40, space_dir=None, store_dir=None, listener=None, cli_path=None):
    """Run the shared music-core/engine/cli.mjs locally (works 100% offline on a plane)."""
    import subprocess
    import tempfile
    cli = Path(cli_path) if cli_path else (HOME / 'Projects/music-core/engine/cli.mjs')
    sdir = Path(space_dir) if space_dir else (HOME / 'Projects/music-radio/data')
    stdir = Path(store_dir) if store_dir else (HOME / '.local/state/music-store')
    if not cli.is_file() or not (sdir / 'space.json').is_file():
        return None
    node = _find_node()
    if not node or not Path(node).is_file():
        return None
    l_name = listener or load_json(HOME / '.config/glancebar/music-store.json', {}).get('glancebar_listener') or 'ian'
    snap = stdir / 'taste-all' / l_name / 'snapshot.json'
    if not snap.is_file():
        return None
    playable_shas = _local_playable_shas()
    with tempfile.NamedTemporaryFile('w', suffix='.json', delete=False) as tf:
        json.dump({'shas': playable_shas}, tf)
        pf = Path(tf.name)
    try:
        argv = [node, '--experimental-strip-types', str(cli), 'queue',
                '--mood', mood, '--n', str(n), '--space', str(sdir), '--profile', str(snap)]
        if playable_shas:
            argv += ['--playable', str(pf)]
        proc = subprocess.run(argv, capture_output=True, text=True, timeout=30)
        if proc.returncode != 0 or not proc.stdout.strip():
            return None
        res = json.loads(proc.stdout)
        # Hydrate raw engine picks ({s, ...}) from local space.json + catalogue.json so offline
        # station.json carries full title/artist/album/duration/relativePath just like /api/queue.
        sp_tracks = {t['s']: t for t in (load_json(sdir / 'space.json', {}).get('tracks') or []) if isinstance(t, dict) and t.get('s')}
        cat_by_sha = {e['sha256']: e for e in (load_json(HOME / '.local/state/glancebar-music-library/catalogue.json', {}).get('entries') or []) if isinstance(e, dict) and e.get('sha256')}
        hydrated = []
        for p in res.get('picks') or []:
            sha = p.get('s') or ''
            t = sp_tracks.get(sha) or {}
            ce = cat_by_sha.get(sha) or {}
            rel = p.get('key') or t.get('key') or ce.get('relativePath') or ''
            meta = ce.get('meta') or {}
            hydrated.append({
                **p,
                'a': p.get('a') or t.get('a') or meta.get('artist') or '',
                't': p.get('t') or t.get('t') or meta.get('title') or '',
                'al': p.get('al') or t.get('al') or meta.get('album') or '',
                'dur': p.get('dur') or t.get('d') or ce.get('durationSeconds'),
                'key': rel,
                'chips': p.get('chips') or ([p['reason']] if p.get('reason') else []),
            })
        res['picks'] = hydrated
        return res
    except Exception:
        return None
    finally:
        pf.unlink(missing_ok=True)


def _local_otr_queue(mood, *, n=40, mix_dir=None, hot_dir=None):
    """Build a ranked local queue directly from offline-manifest.json and music-space.json."""
    mix = Path(mix_dir) if mix_dir else MIX
    manifest = load_json(mix / 'offline-manifest.json', {})
    playlists = manifest.get('playlists') if isinstance(manifest, dict) else []
    if not playlists:
        return None
    if hot_dir is not None:
        hot_root = Path(hot_dir)
    else:
        cfg = load_json(LIB_CONFIG, {})
        hot_root = Path(os.path.expanduser((cfg or {}).get('hot_dir', '~/Music/Glancebar Lossless')))
    hot_prefix = str(hot_root).rstrip('/') + '/'
    try:
        hot_resolved_prefix = str(hot_root.resolve()).rstrip('/') + '/'
    except OSError:
        hot_resolved_prefix = hot_prefix

    lib_rows = load_json(mix / 'library.json', {}).get('tracks') or []
    lib_by_id = {r.get('id'): r for r in lib_rows if isinstance(r, dict) and r.get('id')}
    lib_by_key = {track_key(r.get('artist'), r.get('title')): r for r in lib_rows
                  if isinstance(r, dict) and track_key(r.get('artist'), r.get('title'))}

    space = load_json(mix / 'music-space.json', {})
    sp_tracks = space.get('tracks') if isinstance(space, dict) else {}
    if not isinstance(sp_tracks, dict):
        sp_tracks = {}
    kind_neighbours = space.get('kindNeighbours') if isinstance(space, dict) else {}
    if not isinstance(kind_neighbours, dict):
        kind_neighbours = {}

    liked_ids, disliked_ids = set(), set()
    fb_path = mix / 'feedback.jsonl'
    if fb_path.is_file():
        lines, _ = read_lines(fb_path, 0)
        for o in lines:
            tid = str(o.get('trackID') or '').strip()
            tkey = str(o.get('track_key') or track_key(o.get('artist'), o.get('title')) or '').strip()
            ev = str(o.get('event') or '').strip().lower()
            if not ev:
                ev = 'like' if o.get('liked') is True else ('unlike' if o.get('liked') is False else '')
            for k in (x for x in (tid, tkey) if x):
                if ev == 'like':
                    liked_ids.add(k); disliked_ids.discard(k)
                elif ev == 'unlike':
                    liked_ids.discard(k)
                elif ev == 'dislike':
                    disliked_ids.add(k); liked_ids.discard(k)
                elif ev == 'undislike':
                    disliked_ids.discard(k)

    raw_mood = (mood or 'all').strip()
    mood_key = raw_mood[8:] if raw_mood.lower().startswith('station:') else raw_mood
    target_kind = OTR_MOOD_ALIASES.get(mood_key.lower(), mood_key.lower())

    lens_meta = None
    cached_moods = load_json(STATE / 'moods.json', {})
    for st in (cached_moods.get('stations') or []):
        if isinstance(st, dict) and st.get('id') in (raw_mood, f'station:{mood_key}'):
            lens_meta = st
            break

    candidates = {}
    for pl in playlists:
        if not isinstance(pl, dict):
            continue
        pl_key = str(pl.get('key') or '').lower()
        is_new_pl = pl_key in ('station:triplej', 'new-music') or 'new' in pl_key
        fb_kind = pl_key.split(':', 1)[1] if pl_key.startswith('kind:') else None
        for t in pl.get('tracks') or []:
            if not isinstance(t, dict):
                continue
            tid = str(t.get('id') or '').strip()
            sha = str(t.get('sha256') or '').strip()
            artist = str(t.get('artist') or '').strip()
            title = str(t.get('title') or '').strip()
            tkey = track_key(artist, title) or ''
            dedup = tid or sha or tkey
            if not dedup:
                continue
            if dedup in candidates:
                if is_new_pl:
                    candidates[dedup]['is_new'] = True
                continue
            path_str = str(t.get('path') or '').strip()
            rel = ''
            if path_str.startswith(hot_prefix):
                rel = path_str[len(hot_prefix):]
            elif path_str.startswith(hot_resolved_prefix):
                rel = path_str[len(hot_resolved_prefix):]
            local = bool((path_str and Path(path_str).is_file()) or (rel and (hot_root / rel).is_file()))
            lib = lib_by_id.get(tid) or (lib_by_key.get(tkey) if tkey else None) or {}
            sp = sp_tracks.get(tid) or {}
            if not isinstance(sp, dict):
                sp = {}
            if tid in disliked_ids or tkey in disliked_ids or (lib.get('dislike') and tid not in liked_ids and tkey not in liked_ids):
                continue
            candidates[dedup] = {
                'dedup': dedup, 'tid': tid, 'sha': sha, 'tkey': tkey,
                'artist': artist, 'title': title, 'album': str(t.get('album') or lib.get('album') or ''),
                'dur': t.get('duration') or lib.get('duration'),
                'rel': rel, 'local': local,
                'fav': bool(lib.get('fav') or tid in liked_ids or tkey in liked_ids),
                'genre': str(lib.get('genre') or ''),
                'year': lib.get('year'),
                'kind': str(sp.get('kind') or fb_kind or '').lower(),
                'kind_score': float(sp['kindScore']) if isinstance(sp.get('kindScore'), (int, float)) else 0.6,
                'next': {str(x[0]): float(x[1]) for x in (sp.get('next') or []) if isinstance(x, (list, tuple)) and len(x) >= 2},
                'is_new': is_new_pl,
            }

    if not candidates:
        return None

    neighbours = [str(k).lower() for k in (kind_neighbours.get(target_kind) or [])]

    def _score(c):
        sc = 0.0
        if lens_meta:
            lk = {str(x).lower() for x in (lens_meta.get('kinds') or [])}
            lg = {str(x).lower() for x in (lens_meta.get('genres') or [])}
            lt = {str(x).lower() for x in (lens_meta.get('tags') or [])}
            if c['kind'] and c['kind'] in lk:
                sc += 2.0 * c['kind_score']
            if c['genre'] and any(w in c['genre'].lower() for w in (lg | lt)):
                sc += 1.2
        elif target_kind == 'all':
            sc += 0.5 + 0.4 * c['kind_score']
        elif target_kind == 'new':
            sc += 2.2 if c['is_new'] else (1.0 if isinstance(c['year'], (int, float)) and c['year'] >= 2024 else 0.2)
        else:
            if c['kind'] == target_kind:
                sc += 2.0 * c['kind_score'] + 0.5
            elif c['kind'] in neighbours:
                sc += (0.8 / (neighbours.index(c['kind']) + 1)) * c['kind_score']
            elif c['genre'] and target_kind in c['genre'].lower():
                sc += 1.0
        if c['fav']:
            sc += 0.6
        if c['local']:
            sc += 0.25
        return sc

    pool = list(candidates.values())
    for c in pool:
        c['score'] = _score(c)
    pool.sort(key=lambda c: (-c['score'], c['dedup']))

    chosen = [pool[0]]
    used = {pool[0]['dedup']}
    recent_artists = [pool[0]['artist'].lower()]
    limit = max(1, min(n, len(pool)))
    while len(chosen) < limit:
        prev = chosen[-1]
        best = None
        best_val = -1e9
        for cand in pool:
            if cand['dedup'] in used:
                continue
            sim = prev['next'].get(cand['tid'], 0.0)
            a = cand['artist'].lower()
            pen = 0.8 if recent_artists and a == recent_artists[-1] else (0.3 if a in recent_artists[-3:] else 0.0)
            val = 0.65 * cand['score'] + 0.35 * sim - pen
            if val > best_val:
                best_val = val
                best = cand
        if best is None:
            break
        chosen.append(best)
        used.add(best['dedup'])
        recent_artists.append(best['artist'].lower())

    picks = []
    for c in chosen:
        chips = [c['kind'].capitalize() if c['kind'] else 'Lossless']
        if c['fav']:
            chips.append('Favorite')
        elif c['genre']:
            chips.append(c['genre'])
        picks.append({
            's': c['sha'] or c['tid'],
            'a': c['artist'],
            't': c['title'],
            'al': c['album'],
            'dur': c['dur'],
            'key': c['rel'],
            'local': c['local'],
            'chips': chips,
        })
    return {'mood': mood, 'rule': {'label': 'OtR'}, 'source': 'otr-local', 'picks': picks}


def cmd_queue(mood, offline=False):
    """A queue from the shared engine, written in the New music station's file format. Songs
    already on this Mac go first so it starts at once; falls back to local OtR manifest/space
    or the local music-core engine CLI automatically when offline or without 6IAN."""
    r = None
    source = 'remote'
    c = None if offline else _remote_config()
    if c is not None:
        try:
            r = api(c, 'POST', '/api/queue', {'mood': mood, 'n': 40, 'lossless': True})
        except (urllib.error.URLError, OSError, ValueError):
            r = None
    if r is None and c is not None:
        r = local_queue(mood, n=40)
        source = 'local-engine'
    if r is None:
        r = _local_otr_queue(mood, n=40)
        source = 'otr-local'
    if r is None and c is None:
        r = local_queue(mood, n=40)
        source = 'local-engine'
    if r is None:
        raise RuntimeError('queue unavailable: no remote radio, local OtR manifest, or music-core engine inputs')
    picks = r.get('picks') or []
    rows = []
    for p in picks:
        rel = p.get('key') or ''
        is_local = p['local'] if 'local' in p else local_rel_exists(rel)
        rows.append({'track_key': track_key(p.get('a'), p.get('t')) or p.get('s'), 'title': p.get('t', ''), 'artist': p.get('a', ''),
                     'album': p.get('al', ''), 'duration': p.get('dur'), 'sha256': p.get('s'), 'catalogue_relative_path': rel,
                     'why': ' · '.join(p.get('chips') or []), 'local': is_local})
    rows.sort(key=lambda x: not x['local'])
    rows = rows[:20]
    doc = {'at': now_iso(), 'mood': mood, 'label': r.get('mood'), 'rule': (r.get('rule') or {}).get('label'), 'source': source, 'tracks': rows}
    atomic_write(STATE / 'station.json', doc)
    print(json.dumps({'ok': True, 'mood': mood, 'source': source, 'tracks': len(rows), 'local': sum(1 for x in rows if x['local'])}))
    return 0


def store_facts(artist, title):
    """The shared facts record (music/facts.json, pulled by sync) for a song, or None."""
    store = music_store()
    if not store:
        return None
    sha, _how = store.Ids.load().resolve(artist=artist, title=title)
    songs = store.load_json(store.STATE / 'facts.json', {}).get('songs') or {}
    return dict(songs[sha], sha=sha) if sha in songs else None


def cmd_about(artist, title):
    shared = store_facts(artist, title)
    c = _remote_config()
    if c is None:
        if shared:
            print(json.dumps({'ok': True, 's': shared['sha'], 'store': shared}, ensure_ascii=False))
        else:
            print(json.dumps({'ok': False, 'reason': 'no remote radio configured'}, ensure_ascii=False))
        return 0
    try:
        s = api(c, 'GET', '/api/device/lookup?' + urllib.parse.urlencode({'artist': artist, 'title': title}))['s']
        about = api(c, 'GET', f'/api/info/{s}?kind=about')
        why = api(c, 'GET', f'/api/info/{s}?kind=why')
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            print(json.dumps({'ok': False, 'reason': 'not in the radio library', **({'store': shared} if shared else {})}, ensure_ascii=False))
            return 0
        if shared:
            print(json.dumps({'ok': True, 's': shared['sha'], 'offline': True, 'store': shared}, ensure_ascii=False))
            return 0
        raise
    except (urllib.error.URLError, OSError):
        if shared:
            print(json.dumps({'ok': True, 's': shared['sha'], 'offline': True, 'store': shared}, ensure_ascii=False))
            return 0
        raise
    print(json.dumps({'ok': True, 's': s, 'facts': about.get('facts') or [], 'artist': about.get('artist'), 'why': why.get('rows') or [],
                      **({'store': shared} if shared else {})}, ensure_ascii=False))
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
    if cmd == 'queue' and len(args) in (1, 2):
        offline = '--offline' in args
        mood = [a for a in args if a != '--offline'][0]
        return cmd_queue(mood, offline=offline)
    if cmd == 'about' and len(args) == 2:
        return cmd_about(*args)
    if cmd == 'status':
        return cmd_status()
    print(__doc__)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
