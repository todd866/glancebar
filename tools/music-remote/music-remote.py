#!/opt/homebrew/bin/python3
"""music-remote: the phone (6IAN) is the remote, this Mac's Glancebar is the player.

Owner, 21 Nov 2026: music plays from the laptop to the Bose so Instagram on the phone can't stop it, and
"I wanna be able to control the music from my phone via 6ian". Every 2 s this polls the radio's command
queue (GET /api/device/remote, device token from ~/.config/glancebar/radio.json) and drives Glancebar
through its control notification; every 8 s it heartbeats what Glancebar is playing to the now-playing
bus (surface "mac") so the phone shows it. Commands: play, pause, toggle, next, mood:<6IAN mood>.
"""
import calendar, json, os, socket, subprocess, time, urllib.request
from pathlib import Path

CRED = Path.home() / '.config/glancebar/radio.json'
STATE = Path.home() / '.local/state/music-remote'
SEQ = STATE / 'seq'
LOG = STATE / 'remote.log'
PLAYLOG = Path.home() / 'Library/Logs/Glancebar/playback.jsonl'
HOST = 'macbook'  # the phone shows 'Playing on macbook'
# 6IAN moods -> Glancebar's local mixes (they play at once from this Mac's library).
MOOD_KIND = {'chill': 'chill', 'focus': 'chill', 'energise': 'dance', 'workout': 'dance', 'party': 'dance', 'hiphop': 'rap'}


def log(*a):
    with open(LOG, 'a') as f:
        f.write(time.strftime('%Y-%m-%dT%H:%M:%SZ ', time.gmtime()) + ' '.join(map(str, a)) + '\n')


def api(cred, method, path, body=None):
    req = urllib.request.Request(cred['url'].rstrip('/') + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={'Authorization': 'Bearer ' + cred['token'], 'content-type': 'application/json'})
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.loads(r.read() or b'{}')


def glancebar(command):
    js = ('ObjC.import("Foundation"); var d=$.NSDictionary.dictionaryWithObjectForKey($(%s), $("command"));'
          '$.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately('
          '$("com.iantodd.glancebar.control"), $("uid:%d"), d, true);') % (json.dumps(command), os.getuid())
    subprocess.run(['osascript', '-l', 'JavaScript', '-e', js], capture_output=True, timeout=15)


def last_rate():
    try:
        with open(PLAYLOG, 'rb') as f:
            f.seek(max(0, os.path.getsize(PLAYLOG) - 30000))
            lines = f.read().decode(errors='ignore').splitlines()[1:]
    except OSError:
        return None
    for l in reversed(lines):
        try:
            d = json.loads(l)
        except ValueError:
            continue
        if d.get('event') == 'rate' and d.get('title'):
            return d
    return None


def run(cred, cmd):
    r = last_rate()
    playing = bool(r and r.get('state') in ('playing', 'waiting'))
    if cmd == 'toggle':
        cmd = 'pause' if playing else 'play'
    if cmd in ('play', 'pause', 'next'):
        glancebar(cmd)
    elif cmd.startswith('mood:'):
        mood = cmd[5:]
        glancebar('play ' + MOOD_KIND.get(mood, 'any'))
    log('ran', cmd)


def main():
    STATE.mkdir(parents=True, exist_ok=True)
    cred = json.loads(CRED.read_text())
    seq = int(SEQ.read_text()) if SEQ.exists() else None
    last_beat = 0
    while True:
        try:
            j = api(cred, 'GET', f'/api/device/remote?after={seq or 0}')
            if seq is None:  # first start: don't replay old commands
                seq = j.get('last', 0)
            else:
                for c in j.get('cmds', []):
                    if time.time() - calendar.timegm(time.strptime(c['at'][:19], '%Y-%m-%dT%H:%M:%S')) < 600:  # stale commands are dropped
                        run(cred, c['cmd'])
                    seq = c['seq']
            SEQ.write_text(str(seq))
            if time.time() - last_beat > 8:
                r = last_rate()
                age = time.time() - (r or {}).get('epoch', 0)
                if r and (r.get('state') in ('playing', 'waiting') or age < 1800):
                    api(cred, 'PUT', '/api/device/now', {
                        'surface': 'mac', 'host': HOST, 'title': r.get('title'), 'artist': r.get('artist') or None,
                        'state': 'playing' if r.get('state') in ('playing', 'waiting') else 'paused',
                        'at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())})
                last_beat = time.time()
        except Exception as e:
            log('error', repr(e))
            time.sleep(5)
        time.sleep(2)


if __name__ == '__main__':
    main()
