#!/usr/bin/env python3
"""radio_sync: key parity with the app, what is pushed, and that nothing echoes or is wrongly undone."""
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import radio_sync as rs


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.mix = root / 'mix'; self.mix.mkdir()
        self.state = root / 'state'; self.state.mkdir()
        self.p = [mock.patch.object(rs, 'MIX', self.mix), mock.patch.object(rs, 'STATE', self.state),
                  mock.patch.object(rs, 'recent_plays', lambda: [])]
        for x in self.p:
            x.start()

    def tearDown(self):
        for x in self.p:
            x.stop()
        self.tmp.cleanup()

    def write(self, name, rows):
        with (self.mix / name).open('a') as fh:
            for r in rows:
                fh.write(json.dumps(r) + '\n')

    def feedback(self):
        return [json.loads(l) for l in (self.mix / 'feedback.jsonl').read_text().splitlines() if l]


class Keys(Base):
    def test_matches_the_apps_selector_key(self):
        self.assertEqual(rs.track_key('Chance the Rapper', 'Sun Come Down'), 'chance the rapper|sun come down')
        self.assertEqual(rs.track_key('Cage the Elephant', "Ain't No Rest for the Wicked"), 'cage the elephant|ain t no rest for the wicked')
        self.assertEqual(rs.track_key('A$AP Rocky', 'HIGHJACK (feat. Jessica Pratt)'), 'a ap rocky|highjack feat jessica pratt')
        self.assertIsNone(rs.track_key('', 'x'))


class Push(Base):
    def test_likes_dislikes_and_only_early_skips(self):
        self.write('feedback.jsonl', [
            {'artist': 'A', 'title': 'One', 'at': '2026-11-17T08:46:55Z', 'liked': True, 'trackID': 'a|one'},
            {'artist': 'B', 'title': 'Two', 'at': '2026-11-17T08:47:00Z', 'event': 'dislike', 'liked': False},
            {'artist': 'C', 'title': 'Three', 'at': '2026-11-17T08:48:00Z', 'liked': True, 'source': '6ian'},  # written by us
        ])
        self.write('skip-history.jsonl', [
            {'artist': 'D', 'title': 'Early', 'at': '2026-11-17T09:00:00Z', 'playback': {'fraction': 0.1}},
            {'artist': 'E', 'title': 'Late', 'at': '2026-11-17T09:01:00Z', 'playback': {'fraction': 0.97}},
        ])
        cur = {}
        evs = rs.glancebar_events(cur)
        self.assertEqual([(e['ev'], e['title']) for e in evs], [('like', 'One'), ('dislike', 'Two'), ('skip', 'Early')])
        self.assertEqual(rs.glancebar_events(cur), [])  # the cursor moved: nothing twice


class Pull(Base):
    def taste(self, likes=(), dislikes=()):
        row = lambda a, t: {'s': 'x' * 64, 'artist': a, 'title': t, 'album': '', 'key': ''}
        return {'likes': [row(*x) for x in likes], 'dislikes': [row(*x) for x in dislikes]}

    def test_radio_marks_land_once_and_tagged(self):
        applied = {}
        (self.mix / 'feedback.jsonl').write_text('')
        self.assertEqual(rs.apply_radio_taste(self.taste(likes=[('A', 'One')], dislikes=[('B', 'Two')]), applied, {}), 2)
        self.assertEqual(rs.apply_radio_taste(self.taste(likes=[('A', 'One')], dislikes=[('B', 'Two')]), applied, {}), 0)
        fb = self.feedback()
        self.assertTrue(all(l['source'] == '6ian' for l in fb))
        self.assertEqual({(l['trackID'], l.get('event'), l['liked']) for l in fb}, {('a|one', None, True), ('b|two', 'dislike', False)})

    def test_glancebars_own_marks_are_never_echoed(self):
        (self.mix / 'feedback.jsonl').write_text('')
        self.assertEqual(rs.apply_radio_taste(self.taste(likes=[('A', 'One')]), {}, {'likes:a|one': 'x'}), 0)

    def test_only_lines_we_wrote_are_undone(self):
        (self.mix / 'feedback.jsonl').write_text('')
        applied = {}
        rs.apply_radio_taste(self.taste(likes=[('A', 'One')]), applied, {})
        own = {'likes:z|unmatched': 'x'}  # a Glancebar like the radio could not match
        n = rs.apply_radio_taste(self.taste(), applied, own)  # the radio unliked One
        self.assertEqual(n, 1)
        last = self.feedback()[-1]
        self.assertEqual((last['trackID'], last['liked']), ('a|one', False))
        self.assertFalse(any(l['trackID'] == 'z|unmatched' for l in self.feedback()))


class AliasLookup(unittest.TestCase):
    """Events are named by sha through music/ids.json; unresolved ones fall back to artist+title."""
    def test_resolve_by_library_id_then_key(self):
        store = rs.music_store()
        ids = store.Ids({'persistent': {'PID1': 'a' * 64}, 'key': {'zed|other': 'c' * 64}})
        fake = mock.Mock(Ids=mock.Mock(load=lambda: ids))
        evs = [{'ev': 'play', 'artist': 'X', 'title': 'Y', 'pid': 'PID1'},
               {'ev': 'like', 'artist': 'Zed', 'title': 'Other (Remastered)'},
               {'ev': 'skip', 'artist': 'No', 'title': 'Match'}]
        self.assertEqual(rs.resolve_events(evs, fake), {'ids': 2, 'fallback': 1})
        self.assertEqual([e.get('s') for e in evs], ['a' * 64, 'c' * 64, None])
        self.assertEqual(evs[0]['how'], 'persistent')


class TasteLog(Base):
    """Glancebar's marks go into the one taste log once each; radio-sourced lines do not."""
    def test_log_taste(self):
        store = rs.music_store()
        root = Path(self.tmp.name)
        flag = root / 'METERED'; flag.write_text('')
        hearts = root / 'hearts.jsonl'
        hearts.write_text(json.dumps({'action': 'heart', 'artist': 'Zed', 'title': 'Other', 'at': '2026-11-17T09:00:00Z',
                                      'playback': {'fraction': 0.3}}) + '\n')
        ids = {'key': {'zed|other': 'c' * 64}, 'path': {'AM-Lossless/Z/Z/1.m4a': 'd' * 64}}
        (root / 'store').mkdir()
        (root / 'store/ids.json').write_text(json.dumps(ids))
        self.write('feedback.jsonl', [{'artist': 'Zed', 'title': 'Other', 'liked': True, 'at': '2026-11-17T09:01:00Z'},
                                      {'artist': 'Rad', 'title': 'Io', 'liked': True, 'source': '6ian', 'at': '2026-11-17T09:02:00Z'}])
        self.write('skip-history.jsonl', [{'artist': 'Q', 'title': 'R', 'at': '2026-11-17T09:03:00Z',
                                           'path': str(Path.home() / 'Music/Glancebar Lossless/AM-Lossless/Z/Z/1.m4a'),
                                           'playback': {'fraction': 0.1}}])
        with mock.patch.object(store, 'STATE', root / 'store'), mock.patch.object(store, 'METERED', flag), \
                mock.patch.object(store, 'CONFIG', root / 'none.json'), mock.patch.object(rs, 'HEARTS', hearts), \
                mock.patch.object(rs, 'LIB_CONFIG', root / 'none.json'):
            out = rs.log_taste(store)
            again = rs.log_taste(store)
            evs = store.read_events(root / 'store/taste')
        self.assertEqual(out['written'], 3)
        self.assertEqual(again['written'], 0)
        self.assertEqual(sorted((e['kind'], e.get('sha', '')[:1]) for e in evs),
                         [('early-skip', 'd'), ('heart', 'c'), ('like', 'c')])
        self.assertTrue(all(e['listener'] == 'ian' and e['app'] == 'glancebar' for e in evs))


class OtrFallbackTests(Base):
    def test_config_respects_legacy_and_otr_backend(self):
        cfg = Path(self.tmp.name) / 'radio.json'
        with mock.patch.object(rs, 'CONFIG', cfg):
            self.assertIsNone(rs._remote_config())
            with self.assertRaises(SystemExit):
                rs.config()

            cfg.write_text(json.dumps({'url': 'https://example.com', 'token': 'tok'}))
            self.assertEqual(rs.config()['token'], 'tok')

            cfg.write_text(json.dumps({'url': 'https://example.com', 'token': 'tok', 'backend': 'otr'}))
            self.assertIsNone(rs._remote_config())
            with self.assertRaises(SystemExit):
                rs.config()

    def test_otr_moods_and_sync_without_radio_json(self):
        cfg = Path(self.tmp.name) / 'missing-radio.json'
        fake_resp = mock.MagicMock()
        fake_resp.__enter__.return_value = fake_resp
        fake_resp.read.return_value = json.dumps({
            'lenses': [{'id': 'late-night', 'name': 'Late Night', 'kinds': ['chill']}]
        }).encode()
        with mock.patch.object(rs, 'CONFIG', cfg), \
                mock.patch.object(rs, 'log_taste', return_value={'written': 0}), \
                mock.patch('urllib.request.urlopen', return_value=fake_resp):
            rc = rs.cmd_sync()
        self.assertEqual(rc, 0)
        moods_doc = json.loads((self.state / 'moods.json').read_text())
        self.assertEqual([m['id'] for m in moods_doc['moods']], ['dance', 'alt', 'rap', 'chill', 'new', 'all'])
        self.assertEqual(moods_doc['stations'][0]['id'], 'station:late-night')
        status_doc = json.loads((self.state / 'status.json').read_text())
        self.assertTrue(status_doc['ok'])
        self.assertEqual(status_doc['mode'], 'otr')

    def test_local_otr_queue_and_cmd_queue(self):
        root = Path(self.tmp.name)
        hot = root / 'hot'
        f1 = hot / 'AM-Lossless' / 'Artist A' / 'Album A' / '01. Song A.m4a'
        f1.parent.mkdir(parents=True)
        f1.write_bytes(b'audio')
        f2 = hot / 'AM-Lossless' / 'Artist B' / 'Album B' / '02. Song B.m4a'
        f2.parent.mkdir(parents=True)
        f2.write_bytes(b'audio')

        (self.mix / 'offline-manifest.json').write_text(json.dumps({
            'playlists': [{
                'key': 'kind:dance',
                'tracks': [
                    {'id': 'aaa1', 'sha256': 'a' * 64, 'title': 'Song A', 'artist': 'Artist A', 'album': 'Album A', 'path': str(f1)},
                    {'id': 'bbb2', 'sha256': 'b' * 64, 'title': 'Song B', 'artist': 'Artist B', 'album': 'Album B', 'path': str(f2)},
                    {'id': 'ccc3', 'sha256': 'c' * 64, 'title': 'Bad Song', 'artist': 'Artist C', 'album': 'Album C', 'path': str(hot / 'missing.m4a')},
                ],
            }]
        }))
        (self.mix / 'library.json').write_text(json.dumps({
            'tracks': [
                {'id': 'aaa1', 'artist': 'Artist A', 'title': 'Song A', 'fav': 0, 'dislike': 0, 'genre': 'Alt'},
                {'id': 'bbb2', 'artist': 'Artist B', 'title': 'Song B', 'fav': 1, 'dislike': 0, 'genre': 'Dance'},
                {'id': 'ccc3', 'artist': 'Artist C', 'title': 'Bad Song', 'fav': 0, 'dislike': 1, 'genre': 'Dance'},
            ]
        }))
        (self.mix / 'music-space.json').write_text(json.dumps({
            'kindNeighbours': {'dance': ['alt', 'rap', 'chill']},
            'tracks': {
                'aaa1': {'kind': 'alt', 'kindScore': 0.8, 'next': []},
                'bbb2': {'kind': 'dance', 'kindScore': 0.95, 'next': [['aaa1', 0.9]]},
            }
        }))

        cfg = root / 'missing-radio.json'
        lib_cfg = root / 'lib-cfg.json'
        lib_cfg.write_text(json.dumps({'hot_dir': str(hot)}))
        with mock.patch.object(rs, 'CONFIG', cfg), mock.patch.object(rs, 'LIB_CONFIG', lib_cfg):
            rc = rs.cmd_queue('dance')
        self.assertEqual(rc, 0)
        station = json.loads((self.state / 'station.json').read_text())
        self.assertEqual(station['source'], 'otr-local')
        self.assertEqual(station['mood'], 'dance')
        tracks = station['tracks']
        self.assertEqual([t['title'] for t in tracks], ['Song B', 'Song A'])
        self.assertTrue(all(t['local'] for t in tracks))
        self.assertEqual(tracks[0]['catalogue_relative_path'], 'AM-Lossless/Artist B/Album B/02. Song B.m4a')


if __name__ == '__main__':
    unittest.main()
