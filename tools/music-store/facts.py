#!/usr/bin/env python3
"""One facts record per song (sha), written once to music/facts.json. This tool is its only writer;
Glancebar, Onto the TV and the 6IAN radio read it (docs/music-unify.md, step 5).

A record holds sourced facts only, each with where it came from; nothing is written by a model:
  year    original release year from MusicBrainz: the earliest first-release-date of a recording
          whose artist and title match, else the album's release group (never a compilation).
          Ported from the 6IAN radio's tools/years.py, whose answers (data/years.json, sha -> year)
          seed this so nothing is asked twice.
  cover   the radio's cover and thumbnail in the bucket (radio/art/<sha>.jpg, radio/thumb/<sha>.webp)
  lyrics  whether LRCLIB has lyrics (synced or plain) and its record id; the text stays at LRCLIB
  bio     the artist's Wikipedia page (title, url, its own short description)

  facts.py build [--budget N] [--no-upload]   nightly on the hub (utc-daily), resumable
  facts.py show SHA                             one record from the local copy

Network: a generic User-Agent, one request a second per host, at most --budget requests a run
(default 1500); answers are cached in ~/.local/state/music-store/facts-cache.json, so each night
continues where the last stopped. Python 3.9+, stdlib and rclone.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import musicstore as ms  # noqa: E402

UA = 'music-facts/1.0 (personal library; one request a second)'
CATALOGUE = Path.home() / '.local/state/glancebar-music-library/catalogue.json'
DEFAULT_SEEDS = [Path.home() / 'Projects/music-radio/data/years.json']
COMP = re.compile(r'essential|greatest|best of|hits|collection|anthology|gold|definitive|playlist|now that', re.I)
MUSICIAN = re.compile(r'\b(band|singer|rapper|musician|songwriter|producer|dj|duo|group|composer|'
                      r'record producer|hip hop|electronic|vocalist|guitarist|artist|ensemble|trio)\b', re.I)


class Budget(Exception):
    pass


class Net:
    """Polite GETs: one a second per host, a run budget, JSON or None (404 -> None)."""

    def __init__(self, budget=600, transport=None, sleep=time.sleep, clock=time.monotonic):
        self.left, self.transport, self.sleep, self.clock = budget, transport, sleep, clock
        self.last = {}
        self.used = 0

    def get(self, url):
        if self.left <= 0:
            raise Budget()
        host = urllib.parse.urlsplit(url).netloc
        wait = 1.1 - (self.clock() - self.last.get(host, -10.0))
        if wait > 0:
            self.sleep(wait)
        self.last[host] = self.clock()
        self.left -= 1
        self.used += 1
        if self.transport:
            return self.transport(url)
        req = urllib.request.Request(url, headers={'user-agent': UA, 'accept': 'application/json'})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.loads(r.read() or b'null')
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                return None
            raise


# --- year: a port of music-radio tools/years.py (same rules, same answers) -----------------------

def primary(artist):
    return re.split(r',| & | feat\.? | x ', artist or '', flags=re.I)[0].strip()


def clean(title):
    t = re.sub(r'\s*[\(\[](feat|with|ft)\.?[^\)\]]*[\)\]]', '', title or '', flags=re.I)
    t = re.sub(r'\s*[\(\[][^\)\]]*remaster[^\)\]]*[\)\]]|\s+-\s+.*remaster.*$', '', t, flags=re.I)
    return t.strip()


def esc(s):
    return re.sub(r'([+\-&|!(){}\[\]^"~*?:\\/])', r'\\\1', s)


def mb_year(net, artist, title, album):
    a0 = ms.match_key(primary(artist), '')[0]
    t0 = ms.match_key('', clean(title))[1]
    q = urllib.parse.urlencode({'query': f'recording:"{esc(clean(title))}" AND artist:"{esc(primary(artist))}"',
                                'limit': 50, 'fmt': 'json'})
    r = net.get(f'https://musicbrainz.org/ws/2/recording?{q}')
    ys = []
    for rec in (r or {}).get('recordings', []):
        if rec.get('score', 0) < 70 or ms.match_key('', rec.get('title', ''))[1] != t0:
            continue
        names = ' '.join(ms.match_key(ac.get('name', ''), '')[0] for ac in rec.get('artist-credit', []) if isinstance(ac, dict))
        if a0 not in names:
            continue
        d = (rec.get('first-release-date') or '')[:4]
        if d.isdigit() and int(d) >= 1900:
            ys.append(int(d))
    if ys:
        return min(ys), 'MusicBrainz recording'
    if album and not COMP.search(album):
        q = urllib.parse.urlencode({'query': f'releasegroup:"{esc(clean(album))}" AND artist:"{esc(primary(artist))}"',
                                    'limit': 5, 'fmt': 'json'})
        r = net.get(f'https://musicbrainz.org/ws/2/release-group?{q}')
        for g in (r or {}).get('release-groups', []):
            names = ' '.join(ms.match_key(ac.get('name', ''), '')[0] for ac in g.get('artist-credit', []) if isinstance(ac, dict))
            if (g.get('score', 0) >= 90 and a0 in names
                    and ms.match_key('', g.get('title', ''))[1] == ms.match_key('', clean(album))[1]):
                d = (g.get('first-release-date') or '')[:4]
                if d.isdigit():
                    return int(d), 'MusicBrainz release group'
    return None, 'MusicBrainz: no match'


def lrclib(net, artist, title, album, duration):
    q = {'artist_name': primary(artist), 'track_name': clean(title)}
    if album:
        q['album_name'] = album
    if duration:
        q['duration'] = int(round(duration))
    r = net.get('https://lrclib.net/api/get?' + urllib.parse.urlencode(q))
    if not r or not isinstance(r, dict) or not r.get('id'):
        return None
    return {'source': 'LRCLIB', 'id': r['id'], 'url': f"https://lrclib.net/api/get/{r['id']}",
            'synced': bool(r.get('syncedLyrics')), 'plain': bool(r.get('plainLyrics')),
            'instrumental': bool(r.get('instrumental'))}


def wikipedia(net, artist):
    name = primary(artist)
    if not name:
        return None
    r = net.get('https://en.wikipedia.org/api/rest_v1/page/summary/' + urllib.parse.quote(name.replace(' ', '_')))
    if not r or r.get('type') != 'standard':
        return None
    text = f"{r.get('description') or ''} {r.get('extract') or ''}"
    if not MUSICIAN.search(text[:400]):
        return None
    return {'source': 'Wikipedia', 'title': r.get('title'),
            'url': ((r.get('content_urls') or {}).get('desktop') or {}).get('page'),
            'description': (r.get('description') or '')[:160]}


# --- the builder ----------------------------------------------------------------------------------

def load_seeds(paths):
    years = {}
    for p in paths:
        doc = ms.load_json(p, {})
        if isinstance(doc, dict):
            for sha, y in doc.items():
                if ms.SHA_RE.match(sha) and (y is None or isinstance(y, int)):
                    years.setdefault(sha, y)
    return years


def build(entries, cache, net, *, seeds=None, art=frozenset(), thumbs=frozenset()):
    """Fill cache['songs'] (by sha) and cache['artists'] (bio by artist key) within net's budget.
    Returns the facts document. Stops looking things up when the budget runs out."""
    seeds = seeds or {}
    songs = cache.setdefault('songs', {})
    artists = cache.setdefault('artists', {})
    stopped = False
    # Newest masters first: they are the ones nobody has looked up.
    for e in sorted(entries, key=lambda e: int(e.get('mtimeNs') or 0), reverse=True):
        sha = e.get('sha256')
        if not sha:
            continue
        tags = e.get('tags') or {}
        artist, title, album = tags.get('artist', ''), tags.get('title', ''), tags.get('album', '')
        rec = songs.setdefault(sha, {})
        rec.update({'artist': artist, 'title': title, 'album': album})
        if (e.get('meta') or {}).get('isrc'):
            rec['isrc'] = e['meta']['isrc']
        rec['cover'] = ({'source': '6IAN radio', 'art': f'radio/art/{sha}.jpg' if sha in art else None,
                         'thumb': f'radio/thumb/{sha}.webp' if sha in thumbs else None}
                        if sha in art or sha in thumbs else None)
        if stopped:
            continue
        try:
            if 'year' not in rec:
                if sha in seeds:
                    rec['year'] = seeds[sha]
                    rec['yearSource'] = 'MusicBrainz (6IAN years.py)' if seeds[sha] else 'MusicBrainz: no match'
                else:
                    rec['year'], rec['yearSource'] = mb_year(net, artist, title, album)
            if 'lyrics' not in rec:
                rec['lyrics'] = lrclib(net, artist, title, album, e.get('durationSeconds'))
            akey = ms.match_key(primary(artist), '')[0]
            if akey and akey not in artists:
                artists[akey] = wikipedia(net, artist)
            rec['bio'] = artists.get(akey)
        except Budget:
            stopped = True
        except (urllib.error.URLError, OSError, ValueError) as exc:
            print(f'facts: {artist} - {title}: {exc}', file=sys.stderr)
    live = {e.get('sha256') for e in entries}
    out = {sha: r for sha, r in songs.items() if sha in live}
    done = sum(1 for r in out.values() if 'year' in r and 'lyrics' in r and 'bio' in r)
    return {'schemaVersion': 1, 'generatedAt': int(time.time()), 'songs': out,
            'counts': {'songs': len(out), 'complete': done, 'withYear': sum(1 for r in out.values() if r.get('year')),
                       'withLyrics': sum(1 for r in out.values() if r.get('lyrics')),
                       'withBio': sum(1 for r in out.values() if r.get('bio')),
                       'withCover': sum(1 for r in out.values() if r.get('cover')),
                       'requests': net.used, 'budgetHit': stopped}}


def r2_names(cfg, prefix, suffix):
    proc = ms.rclone(['lsf', '--files-only', '--fast-list', f"{cfg['remote']}/{prefix}"])
    if proc.returncode != 0:
        return frozenset()
    return frozenset(n[:-len(suffix)] for n in proc.stdout.split() if n.endswith(suffix))


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest='cmd', required=True)
    b = sub.add_parser('build')
    b.add_argument('--budget', type=int, default=1500)
    b.add_argument('--catalogue', type=Path, default=CATALOGUE)
    b.add_argument('--no-upload', action='store_true')
    s = sub.add_parser('show')
    s.add_argument('sha')
    args = p.parse_args(argv)
    cfg = ms.config()
    if args.cmd == 'show':
        rec = (ms.load_json(ms.STATE / 'facts.json', {}).get('songs') or {}).get(args.sha)
        print(json.dumps(rec, indent=1, ensure_ascii=False))
        return 0 if rec else 1
    if ms.METERED.exists():
        print('facts: metered link, not looking anything up')
        return 0
    entries = (ms.load_json(args.catalogue, {}) or {}).get('entries') or []
    if not entries:
        print(f'facts: no catalogue at {args.catalogue}', file=sys.stderr)
        return 1
    cache_path = ms.STATE / 'facts-cache.json'
    cache = ms.load_json(cache_path, {})
    seeds = load_seeds([Path(x).expanduser() for x in cfg.get('facts_year_seeds') or DEFAULT_SEEDS])
    net = Net(args.budget)
    doc = build(entries, cache, net, seeds=seeds, art=r2_names(cfg, 'radio/art', '.jpg'),
                thumbs=r2_names(cfg, 'radio/thumb', '.webp'))
    ms.write_json(cache_path, cache)
    out = ms.STATE / 'facts.json'
    ms.write_json(out, doc)
    if not args.no_upload:
        proc = ms.rclone(['copyto', str(out), f"{cfg['remote']}/{ms.FACTS_KEY}"])
        if proc.returncode != 0:
            print(f'facts: upload failed: {proc.stderr.strip()[-200:]}', file=sys.stderr)
            return 1
    print(json.dumps(doc['counts']))
    return 0


if __name__ == '__main__':
    sys.exit(main())
