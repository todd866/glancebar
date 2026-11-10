import json
import os
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
