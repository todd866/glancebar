import json
import os
import shutil
import struct
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

import musiclib as m


def atom(kind, body):
    return struct.pack('>I4s', len(body) + 8, kind) + body


def audio_bytes(title='Song', artist='Artist', album='Album', extra=b''):
    tags = b''.join(atom(k, atom(b'data', b'\0\0\0\1\0\0\0\0' + v.encode()))
                    for k, v in [(b'\xa9nam', title), (b'\xa9ART', artist), (b'\xa9alb', album)])
    sample = atom(b'mp4a', b'\0' * 28)
    table = atom(b'stsd', b'\0' * 4 + struct.pack('>I', 1) + sample)
    for parent in (b'stbl', b'minf', b'mdia', b'trak'):
        table = atom(parent, table)
    return (atom(b'ftyp', b'M4A ' + b'\0' * 4)
            + atom(b'moov', table + atom(b'udta', atom(b'meta', b'\0' * 4 + atom(b'ilst', tags))))
            + atom(b'mdat', b'fake-synthetic-sample-bytes' + extra))


class MusicLibLogicTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.state = self.root / 'state'
        self.hot = self.root / 'hot'
        self.hot.mkdir()
        self.masters = self.root / 'masters'
        self.masters.mkdir()
        self.remote = self.root / 'remote'
        self.remote.mkdir()
        self.config = self.root / 'config.json'
        self.config.write_text(json.dumps({
            'remote': str(self.remote),
            'hot_dir': str(self.hot),
            'cap_gb': 0.001,  # ~1 MB
            'keep_days': 14,
        }))
        body = audio_bytes()
        self.rel = 'Artist/Album/song.m4a'
        self.file_path = self.masters / self.rel
        self.file_path.parent.mkdir(parents=True)
        self.file_path.write_bytes(body)
        self.sha = m.sha256_file(self.file_path)
        self.catalogue = {
            'schemaVersion': 1,
            'entries': [{
                'relativePath': self.rel,
                'sizeBytes': len(body),
                'sha256': self.sha,
                'tags': {'title': 'Song', 'artist': 'Artist', 'album': 'Album'},
                'durationSeconds': 200.0,
            }],
        }
        self.requests = {
            'schemaVersion': 1,
            'playlists': [{
                'key': 'seed:1',
                'title': 'Mix',
                'tracks': [{'id': 't1', 'title': 'Song', 'artist': 'Artist', 'album': 'Album'}],
            }],
        }

    def tearDown(self):
        self.tmp.cleanup()

    def test_unmatched_and_ambiguous(self):
        entries = self.catalogue['entries']
        ok, reason = m.match_track(self.requests['playlists'][0]['tracks'][0], entries)
        self.assertIsNone(reason)
        self.assertEqual(len(ok), 1)
        dup = dict(entries[0], relativePath='other.m4a')
        _, reason = m.match_track(self.requests['playlists'][0]['tracks'][0], entries + [dup])
        self.assertEqual(reason, 'ambiguous catalogue match')
        _, reason = m.match_track({'title': 'Nope', 'artist': 'Nobody'}, entries)
        self.assertEqual(reason, 'no catalogue match')

    def test_catalogue_paths_cannot_escape_hot_dir(self):
        for bad in ('../x.m4a', '/etc/x.m4a', 'a/../../x.m4a', 'a//x.m4a', './x.m4a', 'a\\x.m4a',
                    'a/x.txt', '', None, 'a/\x00.m4a'):
            self.assertFalse(m.safe_relpath(bad), bad)
        self.assertTrue(m.safe_relpath('Artist/Album/01 Song.m4a'))
        entries = m.index_catalogue({'entries': [{'relativePath': '../evil.m4a'},
                                                 {'relativePath': 'Artist/ok.m4a'}, 'junk']})
        self.assertEqual([e['relativePath'] for e in entries], ['Artist/ok.m4a'])
        with tempfile.TemporaryDirectory() as tmp:
            hot = Path(tmp) / 'hot'
            hot.mkdir()
            os.symlink(tmp, hot / 'link')
            self.assertIsNone(m.inside(hot, 'link/x.m4a'))
            self.assertIsNotNone(m.inside(hot, 'Artist/x.m4a'))

    def test_loose_match_never_binds_a_different_recording(self):
        entries = [
            {'relativePath': 'A/B/01 Song (Someone Remix).m4a', 'sizeBytes': 1, 'sha256': 'd' * 64,
             'tags': {'title': 'Song (Someone Remix)', 'artist': 'Artist'}, 'durationSeconds': 200.0},
            {'relativePath': 'A/B/02 Other (Live).m4a', 'sizeBytes': 1, 'sha256': 'e' * 64,
             'tags': {'title': 'Other (Live)', 'artist': 'Artist'}, 'durationSeconds': 200.0},
            {'relativePath': 'A/B/03 Third.m4a', 'sizeBytes': 1, 'sha256': 'f' * 64,
             'tags': {'title': 'Third (Remastered 2011)', 'artist': 'Artist'}},
        ]
        for track in (
            {'artist': 'Artist', 'title': 'Song', 'durationSeconds': 200.0},
            {'artist': 'Artist', 'title': 'Other', 'durationSeconds': 200.0},
            # loose match with no duration on the catalogue side: not trusted
            {'artist': 'Artist', 'title': 'Third', 'durationSeconds': 180.0},
        ):
            hits, reason = m.match_track(track, entries)
            self.assertEqual(hits, [], track)
            self.assertEqual(reason, 'no catalogue match')

    def test_matching_a_large_library_is_fast(self):
        import time
        entries = [{'relativePath': f'A/{i}.m4a', 'sizeBytes': 1, 'sha256': 'a' * 64,
                    'tags': {'title': f'Song {i} (Remastered)', 'artist': f'Artist {i % 97} & Friends'}}
                   for i in range(1500)]
        tracks = [{'artist': f'Artist {i % 97} & Friends', 'title': f'Song {i} (Remastered)'} for i in range(1500)]
        start = time.monotonic()
        found = sum(1 for t in tracks if m.match_track(t, entries)[0])
        self.assertEqual(found, 1500)
        self.assertLess(time.monotonic() - start, 2.0)

    def test_match_normalisation_rules(self):
        entries = [
            {
                'relativePath': 'J Cole/2014 Forest Hills Drive/06 No Role Modelz.m4a',
                'sizeBytes': 100,
                'sha256': 'a' * 64,
                'tags': {'title': 'No Role Modelz', 'artist': 'J. Cole', 'album': '2014 Forest Hills Drive'},
                'durationSeconds': 291.0,
            },
            {
                'relativePath': 'Khruangbin/Mordechai/01 So We Wont Forget.m4a',
                'sizeBytes': 100,
                'sha256': 'b' * 64,
                'tags': {'title': 'So We Won\'t Forget', 'artist': 'Khruangbin & Friends', 'album': 'Mordechai'},
                'durationSeconds': 240.0,
            },
            {
                'relativePath': 'Radiohead/OK Computer/02 Paranoid Android.m4a',
                'sizeBytes': 100,
                'sha256': 'c' * 64,
                'tags': {'title': 'Paranoid Android (Remastered)', 'artist': 'Radiohead', 'album': 'OK Computer'},
                'durationSeconds': 383.0,
            },
        ]
        cases = [
            ({'artist': 'J Cole', 'title': 'No Role Modelz', 'durationSeconds': 291.5}, 1),
            ({'artist': 'Khruangbin', 'title': 'So We Won\'t Forget', 'durationSeconds': 240.0}, 1),
            ({'artist': 'The Radiohead', 'title': 'Paranoid Android', 'durationSeconds': 383.0}, 1),
        ]
        for track, want in cases:
            hits, reason = m.match_track(track, entries)
            self.assertIsNone(reason, track)
            self.assertEqual(len(hits), want, track)

    def test_duration_tolerance(self):
        track = dict(self.requests['playlists'][0]['tracks'][0], durationSeconds=201.5)
        ok, reason = m.match_track(track, self.catalogue['entries'])
        self.assertIsNone(reason)
        track['durationSeconds'] = 210
        ok, reason = m.match_track(track, self.catalogue['entries'])
        self.assertEqual(reason, 'no catalogue match')

    def test_plan_local_and_fetch(self):
        plan = m.compute_plan(
            self.requests, self.catalogue, self.hot, {}, {}, {self.rel}, 5_000_000, 14)
        self.assertEqual(plan['wantedCount'], 1)
        self.assertEqual(len(plan['toFetch']), 1)
        self.assertFalse(plan['unmatched'])
        (self.hot / self.rel).parent.mkdir(parents=True)
        (self.hot / self.rel).write_bytes(audio_bytes())
        plan2 = m.compute_plan(
            self.requests, self.catalogue, self.hot, {}, {}, {self.rel}, 5_000_000, 14)
        self.assertEqual(len(plan2['local']), 1)
        self.assertEqual(len(plan2['toFetch']), 0)

    def test_eviction_skips_wanted_recent_and_absent_remote(self):
        filler = 'filler/old.m4a'
        (self.hot / filler).parent.mkdir(parents=True)
        data = audio_bytes('Old', 'A', 'B')
        (self.hot / filler).write_bytes(data)
        now = time.time()
        wanted_rels = {self.rel}
        hot_map = m.hot_file_state(self.hot)
        remote_rels = set()  # filler absent from remote
        ev = m.evictable_files(hot_map, wanted_rels, {}, {}, remote_rels, 14, now)
        self.assertEqual(ev, [])
        remote_rels = {filler}
        played = {filler: now}
        ev = m.evictable_files(hot_map, wanted_rels, played, {}, remote_rels, 14, now)
        self.assertEqual(ev, [])
        old_play = now - 20 * 86400
        os.utime(self.hot / filler, (old_play, old_play))
        hot_map = m.hot_file_state(self.hot)
        ev = m.evictable_files(hot_map, wanted_rels, {}, {filler: old_play}, remote_rels, 14, now)
        self.assertEqual(len(ev), 1)
        self.assertEqual(ev[0]['relativePath'], filler)

    def test_cap_overflow_flag(self):
        big = self.catalogue['entries'][0]
        big = dict(big, sizeBytes=9_000_000)
        cat = dict(self.catalogue, entries=[big])
        plan = m.compute_plan(self.requests, cat, self.hot, {}, {}, {self.rel}, 5_000_000, 14)
        self.assertTrue(plan['overflow'])

    def test_metered_guard(self):
        flag = self.root / 'metered'
        flag.write_text('1')
        plan = m.compute_plan(self.requests, self.catalogue, self.hot, {}, {}, {self.rel}, 5_000_000, 14)
        plan['toFetch'] = []
        plan['overflow'] = False
        cfg = m.load_config(self.config)
        with self.assertRaises(ValueError):
            m.sync_execute(plan, cfg, self.state, {self.rel}, metered_flag=flag)
        m.sync_execute(plan, cfg, self.state, {self.rel}, allow_metered=True, metered_flag=flag)

    def test_hash_mismatch_discards_part(self):
        bad = self.root / 'bad.part'
        bad.write_bytes(b'not the file')
        dest = self.hot / self.rel
        with self.assertRaises(ValueError):
            m.verify_and_install(bad, dest, self.sha, len(audio_bytes()))
        self.assertFalse(bad.exists())

    def test_sync_fetch_hash_mismatch(self):
        plan = m.compute_plan(
            self.requests, self.catalogue, self.hot, {}, {}, {self.rel}, 5_000_000, 14)
        cfg = m.load_config(self.config)

        def bad_fetch(remote, relpath, dest_part):
            Path(dest_part).write_bytes(b'corrupt')

        with mock.patch.object(m, 'remote_fetch_file', side_effect=bad_fetch):
            with self.assertRaises(ValueError):
                m.sync_execute(plan, cfg, self.state, {self.rel}, metered_flag=self.root / 'absent')
        self.assertFalse(any(self.hot.rglob('*.part')))

    def test_verify_and_install_good(self):
        part = self.hot / 'song.m4a.part'
        part.parent.mkdir(parents=True, exist_ok=True)
        body = audio_bytes()
        part.write_bytes(body)
        dest = self.hot / self.rel
        m.verify_and_install(part, dest, self.sha, len(body))
        self.assertTrue(dest.is_file())
        self.assertFalse(part.exists())

    def test_status_exit_health(self):
        cfg = m.load_config(self.config)
        st = m.build_status(self.requests, self.catalogue, cfg, self.state, {})
        self.assertFalse(st['healthy'])
        (self.hot / self.rel).parent.mkdir(parents=True)
        (self.hot / self.rel).write_bytes(audio_bytes())
        st2 = m.build_status(self.requests, self.catalogue, cfg, self.state, {'lastError': None})
        self.assertTrue(st2['healthy'])

    def test_eviction_skipped_when_remote_unconfirmed(self):
        old = 'stale/track.m4a'
        (self.hot / old).parent.mkdir(parents=True)
        (self.hot / old).write_bytes(audio_bytes('Stale', 'A', 'B'))
        cfg = m.load_config(self.config)
        sha = m.sha256_file(self.hot / old)
        plan = {
            'overflow': False,
            'toFetch': [],
            'capBytes': m.cap_bytes_from_config(cfg),
            'evict': [{
                'relativePath': old,
                'sizeBytes': (self.hot / old).stat().st_size,
                'catalogue': {'relativePath': old, 'sizeBytes': 999, 'sha256': sha},
            }],
        }
        status = m.sync_execute(plan, cfg, self.state, {old}, remote_meta=lambda *_: None)
        self.assertTrue((self.hot / old).is_file())
        self.assertEqual(len(status['evictionSkipped']), 1)

    def test_part_bytes_count_toward_cap(self):
        part = self.hot / (self.rel + '.part')
        part.parent.mkdir(parents=True, exist_ok=True)
        part.write_bytes(b'x' * 500_000)
        hot_map = m.hot_file_state(self.hot)
        self.assertGreater(m.hot_byte_usage(self.hot, hot_map), m.bytes_in_hot(hot_map))

    def test_sweep_stale_parts_at_sync(self):
        part = self.hot / 'orphan.m4a.part'
        part.write_bytes(b'partial')
        plan = m.compute_plan(
            self.requests, self.catalogue, self.hot, {}, {}, {self.rel}, 5_000_000, 14)
        plan['toFetch'] = []
        plan['overflow'] = False
        cfg = m.load_config(self.config)
        m.sync_execute(plan, cfg, self.state, {self.rel})
        self.assertFalse(part.exists())

    def test_bad_hot_file_refetched(self):
        path = self.hot / self.rel
        path.parent.mkdir(parents=True)
        path.write_bytes(b'corrupt')
        verified = {}
        trash = self.root / 'trash2'
        trash.write_text('#!/bin/sh\nexit 0\n')
        os.chmod(trash, 0o755)
        local, refetch = m.reconcile_wanted_hot(
            self.hot,
            m.wanted_entries_from_requests(self.requests, self.catalogue)[1],
            verified,
            trash_cmd=trash,
        )
        self.assertEqual(len(refetch), 1)
        self.assertEqual(len(local), 0)
        plan = m.compute_plan(
            self.requests, self.catalogue, self.hot, {}, {}, {self.rel}, 5_000_000, 14,
            verified_state=verified, trash_cmd=trash)
        self.assertEqual(len(plan['toFetch']), 1)

    def test_playlist_fetch_priority(self):
        other_rel = 'Band/LP/other.m4a'
        other_path = self.masters / other_rel
        other_path.parent.mkdir(parents=True)
        other_body = audio_bytes('Other', 'Band', 'LP')
        other_path.write_bytes(other_body)
        req = {
            'schemaVersion': 1,
            'playlists': [
                {'key': 'b', 'title': 'B', 'tracks': [{'id': '2', 'title': 'Song', 'artist': 'Artist', 'album': 'Album'}]},
                {'key': 'a', 'title': 'A', 'tracks': [{'id': '1', 'title': 'Other', 'artist': 'Band', 'album': 'LP'}]},
            ],
        }
        cat = {
            'schemaVersion': 1,
            'entries': [
                self.catalogue['entries'][0],
                {
                    'relativePath': other_rel,
                    'sizeBytes': len(other_body),
                    'sha256': m.sha256_file(other_path),
                    'tags': {'title': 'Other', 'artist': 'Band', 'album': 'LP'},
                    'durationSeconds': 200.0,
                },
            ],
        }
        plan = m.compute_plan(req, cat, self.hot, {}, {}, {self.rel, other_rel}, 50_000_000, 14, playlist_first='a')
        order = [row['playlistKey'] for row in plan['toFetch']]
        self.assertEqual(order[0], 'a')

    def test_metered_plan_uses_cache_only(self):
        self.state.mkdir(parents=True, exist_ok=True)
        (self.state / 'catalogue.json').write_text(json.dumps(self.catalogue))
        plan = m.compute_plan(
            self.requests, self.catalogue, self.hot, {}, {}, {self.rel},
            m.cap_bytes_from_config(m.load_config(self.config)), 14)
        self.assertEqual(len(plan['toFetch']), 1)

    def test_oversized_playlist_library_while_small_syncs(self):
        big = [{'id': f'id{i}', 'title': 'Song', 'artist': 'Artist', 'album': 'Album'} for i in range(150)]
        req = {
            'schemaVersion': 1,
            'playlists': [
                {'key': 'big', 'title': 'YouTube Import', 'tracks': big},
                {'key': 'seed', 'title': 'Mix', 'tracks': self.requests['playlists'][0]['tracks']},
            ],
        }
        plan = m.compute_plan(req, self.catalogue, self.hot, {}, {}, {self.rel}, 50_000_000, 14, max_tracks=120)
        self.assertEqual(len(plan['library']), 1)
        self.assertEqual(plan['library'][0]['key'], 'big')
        self.assertEqual(len(plan['toFetch']), 1)

    def test_sync_skips_playlist_that_does_not_fit(self):
        other_rel = 'Band/LP/other.m4a'
        other_path = self.masters / other_rel
        other_path.parent.mkdir(parents=True)
        other_body = audio_bytes('Other', 'Band', 'LP', extra=b'x' * 2000)
        other_path.write_bytes(other_body)
        other_sha = m.sha256_file(other_path)
        cat = {
            'schemaVersion': 1,
            'entries': [
                self.catalogue['entries'][0],
                {
                    'relativePath': other_rel,
                    'sizeBytes': len(other_body),
                    'sha256': other_sha,
                    'tags': {'title': 'Other', 'artist': 'Band', 'album': 'LP'},
                    'durationSeconds': 200.0,
                },
            ],
        }
        req = {
            'schemaVersion': 1,
            'playlists': [
                {'key': 'first', 'title': 'First', 'tracks': self.requests['playlists'][0]['tracks']},
                {'key': 'second', 'title': 'Second',
                 'tracks': [{'id': '2', 'title': 'Other', 'artist': 'Band', 'album': 'LP'}]},
            ],
        }
        body = self.file_path.read_bytes()
        cap = len(body) + 500
        plan = m.compute_plan(req, cat, self.hot, {}, {}, {self.rel, other_rel}, cap, 14)
        cfg = m.load_config(self.config)
        cfg = dict(cfg)
        cfg['remote'] = str(self.remote)

        def fake_fetch(remote, relpath, dest_part):
            src = Path(remote) / relpath
            if relpath == self.rel:
                src = self.file_path
            elif relpath == other_rel:
                src = other_path
            shutil.copy(src, dest_part)

        with mock.patch.object(m, 'remote_fetch_file', side_effect=fake_fetch):
            status = m.sync_execute(plan, cfg, self.state, {self.rel, other_rel})
        self.assertIsNone(status.get('lastError'))
        self.assertEqual(status.get('fetched'), 1)
        self.assertEqual(len(status.get('skipped') or []), 1)

    def test_status_healthy_with_library_playlist(self):
        big = [{'id': f'id{i}', 'title': 'Song', 'artist': 'Artist', 'album': 'Album'} for i in range(200)]
        req = {
            'schemaVersion': 1,
            'playlists': [
                {'key': 'big', 'title': 'Library', 'tracks': big},
                {'key': 'seed', 'title': 'Mix', 'tracks': self.requests['playlists'][0]['tracks']},
            ],
        }
        path = self.hot / self.rel
        path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(self.file_path, path)
        cfg = m.load_config(self.config)
        st = m.build_status(req, self.catalogue, cfg, self.state, {'lastError': None, 'library': [
            {'key': 'big', 'title': 'Library', 'wanted': 200, 'library': True},
        ]})
        self.assertTrue(st['healthy'])
        self.assertTrue(any(p.get('library') for p in st['playlists']))


@unittest.skipUnless(m.rclone_bin(), 'rclone not installed')
class MusicLibRcloneTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.state = self.root / 'state'
        self.masters = self.root / 'masters'
        self.remote = self.root / 'remote'
        self.hot = self.root / 'hot'
        for p in (self.masters, self.remote, self.hot, self.state):
            p.mkdir(parents=True)
        self.config = self.root / 'config.json'
        self.config.write_text(json.dumps({
            'remote': str(self.remote),
            'hot_dir': str(self.hot),
            'cap_gb': 1,
            'keep_days': 14,
        }))
        body = audio_bytes('Remote', 'Band', 'LP')
        rel = 'Band/LP/track.m4a'
        path = self.masters / rel
        path.parent.mkdir(parents=True)
        path.write_bytes(body)

    def tearDown(self):
        self.tmp.cleanup()

    def test_catalogue_push_and_fetch(self):
        doc = m.catalogue_command(self.masters, str(self.remote), self.state, upload=True)
        self.assertEqual(len(doc['entries']), 1)
        self.assertTrue((self.remote / 'catalogue.json').is_file())
        m.push_command(self.masters, str(self.remote))
        rel = 'Band/LP/track.m4a'
        self.assertTrue((self.remote / rel).is_file())
        part = Path(str(self.hot / rel) + '.part')
        part.parent.mkdir(parents=True, exist_ok=True)
        m.remote_fetch_file(str(self.remote), rel, part)
        entry = doc['entries'][0]
        m.verify_and_install(part, self.hot / rel, entry['sha256'], entry['sizeBytes'])
        self.assertTrue((self.hot / rel).is_file())
        self.assertFalse(part.exists())
        self.assertEqual(m.sha256_file(self.hot / rel), entry['sha256'])


class FakeTrash(unittest.TestCase):
    def test_sync_evict_calls_trash(self):
        tmp = tempfile.TemporaryDirectory()
        root = Path(tmp.name)
        try:
            hot = root / 'hot'
            state = root / 'state'
            hot.mkdir()
            cfg = {
                'remote': str(root / 'remote'),
                'hot_dir': hot,
                'cap_gb': 0.000001,
                'keep_days': 1,
            }
            old = 'old/track.m4a'
            (hot / old).parent.mkdir(parents=True)
            (hot / old).write_bytes(audio_bytes('x', 'y', 'z'))
            trash_log = root / 'trash.log'
            script = root / 'trash'
            script.write_text('#!/bin/sh\necho "$@" >> "' + str(trash_log) + '"\n')
            os.chmod(script, 0o755)
            body = audio_bytes('x', 'y', 'z')
            sha = m.sha256_file(hot / old)
            plan = {
                'overflow': False,
                'toFetch': [],
                'capBytes': 10_000_000,
                'evict': [{
                    'relativePath': old,
                    'sizeBytes': len(body),
                    'catalogue': {'relativePath': old, 'sizeBytes': len(body), 'sha256': sha},
                }],
            }
            meta = {'sizeBytes': len(body), 'sha256': sha}
            m.sync_execute(plan, cfg, state, {old}, trash_cmd=script, now=time.time(),
                           remote_meta=lambda remote, rel: meta)
            self.assertIn(old, trash_log.read_text())
        finally:
            tmp.cleanup()


if __name__ == '__main__':
    unittest.main()
