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


if __name__ == '__main__':
    unittest.main()


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
