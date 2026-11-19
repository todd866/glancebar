"""musicstore: the alias table, the taste log and the radio import (docs/music-unify.md)."""
import json
import os
import tempfile
import unittest
from pathlib import Path

import musicstore as ms

A, B, C = 'a' * 64, 'b' * 64, 'c' * 64


def entry(sha, rel, artist, title, mtime=1, isrc=None):
    e = {'sha256': sha, 'relativePath': rel, 'mtimeNs': str(mtime), 'tags': {'artist': artist, 'title': title}}
    if isrc:
        e['meta'] = {'isrc': isrc}
    return e


class Proc:
    def __init__(self, rc=0, out=''):
        self.returncode, self.stdout, self.stderr = rc, out, ''


class IdsTest(unittest.TestCase):
    def setUp(self):
        self.entries = [
            entry(A, 'AM-Lossless/X/One/1.m4a', 'The X feat. Y', 'Song (Remastered 2011)', mtime=5, isrc='usx1'),
            entry(B, 'AM-Lossless/X/Best Of/4.m4a', 'The X', 'Song', mtime=9),
            entry(C, 'AM-Lossless/Z/Z/1.m4a', 'Zed', 'Other'),
        ]

    def test_key_isrc_path_and_collisions(self):
        ids = ms.build_ids(self.entries)
        self.assertEqual(ids['key']['the x|song'], A)            # earliest added wins a shared key
        self.assertEqual(ids['collisions']['the x|song'], [A, B])
        self.assertEqual(ids['isrc']['USX1'], A)
        self.assertEqual(ids['path']['AM-Lossless/Z/Z/1.m4a'], C)

    def test_canonical_is_stable_across_builds(self):
        prev = {'key': {'the x|song': B}}
        self.assertEqual(ms.build_ids(self.entries, previous=prev)['key']['the x|song'], B)

    def test_claims_resolve_by_sha_path_then_key(self):
        claims = [
            {'kind': 'apple', 'id': '111', 'sha': C},
            {'kind': 'apple', 'id': '222', 'relativePath': 'AM-Lossless/X/Best Of/4.m4a'},
            {'kind': 'youtube', 'id': 'abcdefghijk', 'artist': 'Zed', 'title': 'Other (Official Video)'},
            {'kind': 'persistent', 'id': 'FFFF', 'artist': 'Nobody', 'title': 'Nothing'},
        ]
        ids = ms.build_ids(self.entries, claims=claims)
        self.assertEqual(ids['apple'], {'111': C, '222': B})
        self.assertEqual(ids['youtube']['abcdefghijk'], C)
        self.assertEqual(ids['how']['youtube']['abcdefghijk'], 'key')
        self.assertEqual(ids['counts']['unresolved']['persistent'], 1)

    def test_previous_aliases_carry_while_the_song_is_catalogued(self):
        prev = {'youtube': {'vvvvvvvvvvv': C, 'ggggggggggg': 'f' * 64}}
        ids = ms.build_ids(self.entries, previous=prev)
        self.assertEqual(ids['youtube'], {'vvvvvvvvvvv': C})

    def test_resolve_order_and_fallback(self):
        r = ms.Ids(ms.build_ids(self.entries, claims=[{'kind': 'persistent', 'id': 'P1', 'sha': B}]))
        self.assertEqual(r.resolve(persistent='P1', artist='Zed', title='Other'), (B, 'persistent'))
        self.assertEqual(r.resolve(artist='Zed', title='Other'), (C, 'key'))
        self.assertEqual(r.resolve(artist='Nobody', title='x'), (None, None))

    def test_youtube_claims_from_file_names(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / 'music' / 'Phantogram'
            p.mkdir(parents=True)
            (p / 'Phantogram - Fall In Love [RsQjC5zVnt8].mp4').write_bytes(b'')
            (p / 'Mouthful of Diamonds (Official Video) [AAAAAAAAAAA].mkv').write_bytes(b'')
            (p / 'notes.txt').write_bytes(b'')
            rows = sorted(ms.youtube_claims(d), key=lambda r: r['id'])
        self.assertEqual([(r['id'], r['artist'], r['title']) for r in rows],
                         [('AAAAAAAAAAA', 'Phantogram', 'Mouthful of Diamonds'),
                          ('RsQjC5zVnt8', 'Phantogram', 'Fall In Love')])
        self.assertEqual(ms.key_text(rows[0]['artist'], rows[0]['title']), 'phantogram|mouthful of diamonds')

    def test_apple_claims_from_scout_ledger(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / 'ledger.jsonl'
            p.write_text(json.dumps({'action': 'acquired', 'url': 'https://music.apple.com/au/song/x/1515525399',
                                     'sha256': A, 'artist': 'X', 'title': 'Song'}) + '\n'
                         + json.dumps({'action': 'no_match'}) + '\n')
            rows = ms.apple_claims_from_ledger(p)
        self.assertEqual([(r['id'], r['sha']) for r in rows], [('1515525399', A)])


class MatchKeyParityTest(unittest.TestCase):
    """The TV mirrors embed.match_key in JS (src/music-pick.js embedMatchKey); both suites read
    the same fixture, so a change on one side fails the other's tests."""

    def test_fixture(self):
        rows = json.loads((Path(__file__).parent / 'match-key-fixture.json').read_text(encoding='utf-8'))
        for row in rows:
            self.assertEqual(ms.key_text(row['artist'], row['title']), row['key'], row)


class TasteTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.state = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_append_is_idempotent_and_sharded_by_writer(self):
        ev = ms.make_event('ian', 'glancebar', 'early-skip', sha=A, fraction=0.12, at='2026-11-19T01:00:00Z', host='m5')
        self.assertTrue(ms.append(ev, self.state))
        self.assertFalse(ms.append(ev, self.state))
        path = self.state / 'taste/ian/2026-11/glancebar-m5.jsonl'
        self.assertEqual(len(path.read_text().splitlines()), 1)
        self.assertEqual(json.loads(path.read_text())['fraction'], 0.12)

    def test_bad_events_refused(self):
        with self.assertRaises(ValueError):
            ms.make_event('Ian Todd', 'glancebar', 'like', sha=A)
        with self.assertRaises(ValueError):
            ms.make_event('ian', 'glancebar', 'love', sha=A)
        with self.assertRaises(ValueError):
            ms.make_event('ian', 'glancebar', 'like')

    def test_flush_copies_only_changed_shards(self):
        ms.append(ms.make_event('ian', 'glancebar', 'like', sha=A, host='m5'), self.state)
        calls = []
        runner = lambda argv, timeout=600: calls.append(argv) or Proc()
        cfg = {'remote': 'r:bucket', 'host': 'm5'}
        self.assertEqual(ms.flush(self.state, cfg, runner)['sent'], 1)
        self.assertEqual(ms.flush(self.state, cfg, runner)['sent'], 0)
        self.assertTrue(calls[0][2].startswith('r:bucket/music/taste/ian/'))
        self.assertTrue(calls[0][2].endswith('/glancebar-m5.jsonl'))

    def test_read_events_dedupes_and_sorts(self):
        e1 = ms.make_event('ian', 'tv', 'like', sha=A, at='2026-11-19T02:00:00Z', host='m2')
        e2 = ms.make_event('ian', 'glancebar', 'play', sha=B, at='2026-11-18T02:00:00Z', host='m5')
        ms.append(e1, self.state)
        ms.append(e2, self.state)
        copy = self.state / 'taste/ian/2026-11/tv-m2-copy.jsonl'
        copy.write_text(json.dumps(e1) + '\n')
        self.assertEqual([e['kind'] for e in ms.read_events(self.state / 'taste', 'ian')], ['play', 'like'])

    def test_radio_import_skips_device_events_and_qa(self):
        profile = {'events': [
            {'ts': 1795000000000, 's': A, 'ev': 'like', 'via': 'session'},
            {'ts': 1795000001000, 's': B, 'ev': 'play', 'via': 'glancebar-m5'},
            {'ts': 1795000002000, 's': C, 'ev': 'more'},
        ]}
        cfg = {'remote': 'r:bucket', 'host': 'm2', 'radio_accounts': {'ian': 'ian', 'ian-qa': 'ian'}}
        asked = []

        def runner(argv, timeout=600):
            asked.append(argv[1])
            return Proc(0, json.dumps(profile))
        added = ms.import_radio(self.state, cfg, runner)
        self.assertEqual(added, {'ian': 2})
        self.assertEqual(asked, ['r:bucket/radio/profiles/ian.json'])
        self.assertEqual(ms.import_radio(self.state, cfg, runner), {'ian': 0})  # idempotent
        kinds = sorted(e['kind'] for e in ms.read_events(self.state / 'taste'))
        self.assertEqual(kinds, ['like', 'more'])


if __name__ == '__main__':
    unittest.main()
