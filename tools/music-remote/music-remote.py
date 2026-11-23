#!/opt/homebrew/bin/python3
"""music-remote: the phone (6IAN) is the remote, this Mac's Glancebar is the player.

Owner, 21 Nov 2026: music plays from the laptop to the Bose so Instagram on the phone can't stop it, and
"I wanna be able to control the music from my phone via 6ian". Every 2 s this polls the radio's command
queue (GET /api/device/remote, device token from ~/.config/glancebar/radio.json) and drives Glancebar
through its native CLI / control notification; every 8 s it heartbeats what Glancebar is playing to the
now-playing bus (surface "mac") so the phone shows it. Commands: play, pause, toggle, next, prev, like,
dislike, mood:<6IAN mood or station>.
"""
import calendar, json, os, re, subprocess, time, urllib.request
from pathlib import Path

CRED = Path.home() / '.config/glancebar/radio.json'
STATE = Path.home() / '.local/state/music-remote'
SEQ = STATE / 'seq'
LOG = STATE / 'remote.log'
PLAYLOG = Path.home() / 'Library/Logs/Glancebar/playback.jsonl'
HEARTS = Path.home() / '.local/state/selector/hearts.json'
GLANCEBAR_BIN = Path('/Applications/Glancebar.app/Contents/MacOS/Glancebar')
HOST = 'macbook'  # the phone shows 'Playing on macbook'
# Direct local Glancebar kinds start in <50 ms; other 6IAN moods/stations use Glancebar --play radio:<mood>.
DIRECT_KINDS = {'dance': 'dance', 'alt': 'alt', 'rap': 'rap', 'chill': 'chill', 'any': 'any', 'new': 'new', 'show': 'show',
                'focus': 'chill', 'energise': 'dance', 'workout': 'dance', 'party': 'dance'}


def log(*a):
    with open(LOG, 'a') as f:
        f.write(time.strftime('%Y-%m-%dT%H:%M:%SZ ', time.gmtime()) + ' '.join(map(str, a)) + '\n')


def api(cred, method, path, body=None):
    req = urllib.request.Request(cred['url'].rstrip('/') + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={'Authorization': 'Bearer ' + cred['token'], 'content-type': 'application/json'})
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.loads(r.read() or b'{}')


def glancebar_cli(args, fallback_cmd):
    if GLANCEBAR_BIN.is_file():
        r = subprocess.run([str(GLANCEBAR_BIN), *args], capture_output=True, timeout=10)
        if r.returncode == 0:
            return
    js = ('ObjC.import("Foundation"); var d=$.NSDictionary.dictionaryWithObjectForKey($(%s), $("command"));'
          '$.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately('
          '$("com.iantodd.glancebar.control"), $("uid:%d"), d, true);') % (json.dumps(fallback_cmd), os.getuid())
    subprocess.run(['osascript', '-l', 'JavaScript', '-e', js], capture_output=True, timeout=15)


def norm_key(artist, title):
    s = f'{artist or ""}|{title or ""}'.lower()
    return re.sub(r'\s+', ' ', s).strip()


def is_hearted(artist, title):
    if not artist or not title or not HEARTS.is_file():
        return False
    try:
        doc = json.loads(HEARTS.read_text())
        rows = doc.get('tracks') if isinstance(doc, dict) else (doc if isinstance(doc, list) else [])
        want = norm_key(artist, title)
        return any(isinstance(k, str) and k.lower().strip() == want for k in (rows or []))
    except Exception:
        return False


def _fallback_from_filename(fname):
    stem = os.path.splitext(os.path.basename(fname or ''))[0]
    stem = re.sub(r'\s*\[[A-Za-z0-9_-]{6,}\]$', '', stem)
    stem = re.sub(r'^\d{1,3}\.\s+', '', stem)
    if ' - ' in stem:
        a, t = stem.split(' - ', 1)
        return a.strip() or None, t.strip() or None
    return None, stem.strip() or None


def current_playback(playlog_path=PLAYLOG):
    try:
        size = os.path.getsize(playlog_path)
        window = 262144
        with open(playlog_path, 'rb') as f:
            if size > window:
                f.seek(size - window)
            raw = f.read().decode(errors='ignore').splitlines()
            lines = raw[1:] if size > window else raw
    except OSError:
        return None
    state = title = artist = cur_file = None
    epoch = 0.0
    for l in lines:
        try:
            d = json.loads(l)
        except ValueError:
            continue
        if not isinstance(d, dict) or d.get('silentQA'):
            continue
        ev = d.get('event')
        if isinstance(d.get('epoch'), (int, float)):
            epoch = float(d['epoch'])
        if ev == 'launch':
            state = title = artist = cur_file = None
        elif ev == 'track':
            cur_file = d.get('file') or cur_file
            t = (d.get('title') or '').strip()
            a = (d.get('artist') or '').strip()
            if not t and d.get('file'):
                fb_a, fb_t = _fallback_from_filename(d['file'])
                t = fb_t or ''
                a = a or (fb_a or '')
            title = t or None
            artist = a or None
        elif ev == 'meta':
            ev_file = d.get('file')
            if not ev_file or not cur_file or ev_file == cur_file:
                if (d.get('title') or '').strip():
                    title = d['title'].strip()
                if (d.get('artist') or '').strip():
                    artist = d['artist'].strip()
        elif ev == 'rate':
            if d.get('state'):
                state = d['state']
            ev_file = d.get('file')
            if not ev_file or not cur_file or ev_file == cur_file:
                if (d.get('title') or '').strip():
                    title = d['title'].strip()
                if (d.get('artist') or '').strip():
                    artist = d['artist'].strip()
                if ev_file and not cur_file:
                    cur_file = ev_file
    if not state and not title:
        return None
    return {'state': state, 'title': title, 'artist': artist, 'file': cur_file, 'epoch': epoch}


def last_rate():
    return current_playback(PLAYLOG)


def run(cred, cmd):
    r = current_playback()
    playing = bool(r and r.get('state') in ('playing', 'waiting'))
    if cmd == 'toggle':
        cmd = 'pause' if playing else 'play'
    if cmd in ('play', 'pause', 'next', 'prev', 'like', 'dislike'):
        glancebar_cli([f'--{cmd}'], cmd)
    elif cmd.startswith('mood:'):
        mood = cmd[5:]
        if mood in DIRECT_KINDS:
            kind = DIRECT_KINDS[mood]
            glancebar_cli(['--play', kind], f'play {kind}')
        else:
            glancebar_cli(['--play', f'radio:{mood}'], f'play radio:{mood}')
    log('ran', cmd)


def publish_now(cred):
    r = current_playback()
    age = time.time() - (r or {}).get('epoch', 0)
    if r and r.get('title') and (r.get('state') in ('playing', 'waiting') or age < 1800):
        api(cred, 'PUT', '/api/device/now', {
            'surface': 'mac', 'host': HOST, 'title': r.get('title'), 'artist': r.get('artist') or None,
            'state': 'playing' if r.get('state') in ('playing', 'waiting') else 'paused',
            'liked': is_hearted(r.get('artist'), r.get('title')),
            'at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())})


def main():
    STATE.mkdir(parents=True, exist_ok=True)
    cred = json.loads(CRED.read_text())
    seq = int(SEQ.read_text()) if SEQ.exists() else None
    last_beat = 0
    while True:
        try:
            j = api(cred, 'GET', f'/api/device/remote?after={seq or 0}')
            ran_any = False
            if seq is None:  # first start: don't replay old commands
                seq = j.get('last', 0)
            else:
                for c in j.get('cmds', []):
                    if time.time() - calendar.timegm(time.strptime(c['at'][:19], '%Y-%m-%dT%H:%M:%S')) < 600:  # stale commands are dropped
                        run(cred, c['cmd'])
                        ran_any = True
                    seq = c['seq']
            SEQ.write_text(str(seq))
            if ran_any:
                time.sleep(0.35)
                publish_now(cred)
                last_beat = time.time()
            elif time.time() - last_beat > 8:
                publish_now(cred)
                last_beat = time.time()
        except Exception as e:
            log('error', repr(e))
            time.sleep(5)
        time.sleep(2)


if __name__ == '__main__':
    main()
