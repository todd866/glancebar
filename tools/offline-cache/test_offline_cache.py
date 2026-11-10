import fcntl
import subprocess
import sys
import json
import os
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch
import offline_cache as c


def atom(kind, body):
    return struct.pack('>I4s', len(body) + 8, kind) + body


def audio(title='Song', artist='Artist', album='Album'):
    tags = b''.join(atom(k, atom(b'data', b'\0\0\0\1\0\0\0\0' + v.encode()))
                    for k, v in [(b'\xa9nam', title), (b'\xa9ART', artist), (b'\xa9alb', album)])
    sample = atom(b'mp4a', b'\0'*28)
    table = atom(b'stsd', b'\0'*4 + struct.pack('>I', 1) + sample)
    for parent in (b'stbl', b'minf', b'mdia', b'trak'):
        table = atom(parent, table)
    return (atom(b'ftyp', b'M4A ' + b'\0'*4)
            + atom(b'moov', table + atom(b'udta', atom(b'meta', b'\0'*4 + atom(b'ilst', tags))))
            + atom(b'mdat', b'fake-synthetic-sample-bytes'))


class CacheTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=str(Path.home()))
        self.root = Path(self.tmp.name)
        self.path = self.root / 'song.m4a'
        self.path.write_bytes(audio())
        self.track = dict(id='123', title='Song', artist='Artist', album='Album')
        self.request = {'schemaVersion': 1, 'playlists': [{'key': 'mix', 'title': 'Mix', 'tracks': [self.track]}]}
        self.source = dict(self.track, path=str(self.path))

    def tearDown(self):
        self.tmp.cleanup()

    def test_catalogue_match_keys_normalisation(self):
        keys = c.catalogue_match_keys('Khruangbin & Friends', 'So We Won\'t Forget (Remastered)')
        self.assertIn(c.match_fold('Khruangbin'), {k[0] for k in keys})
        self.assertIn(c.match_fold('So We Won\'t Forget'), {k[1] for k in keys})
        self.assertTrue(c.looks_like_remix('Breathing (The Remixes)'))

    def test_tag_scan_and_exact_audit(self):
        rows = c.inventory([self.root])
        result = c.audit(self.request, rows)['playlists'][0]
        self.assertTrue(result['ready'])
        self.assertEqual(result['requestedTrackIDs'], ['123'])
        self.assertEqual(result['tracks'][0]['sizeBytes'], len(audio()))
        self.assertEqual(len(result['tracks'][0]['sha256']), 64)

    def test_no_title_only_or_wrong_version(self):
        for changes in [{'artist': 'Other'}, {'album': 'Other'}, {'album': ''}, {'title': 'Song (Live)'}]:
            row = dict(self.source, **changes)
            row.pop('id')
            self.assertFalse(c.audit(self.request, [row])['playlists'][0]['ready'])

    def test_explicit_id_still_rejects_conflicting_metadata(self):
        self.assertFalse(c.audit(self.request, [dict(self.source, album='Other')])['playlists'][0]['ready'])

    def test_ambiguity_is_gap(self):
        second = self.root / 'other.m4a'
        second.write_bytes(audio() + atom(b'free', b'different bytes'))
        result = c.audit(self.request, [self.source, dict(self.source, path=str(second))])['playlists'][0]
        self.assertEqual(result['missing'][0]['reason'], 'ambiguous exact match')

    def test_missing_empty_symlink_and_remote_are_gaps(self):
        for path in [self.root / 'missing.m4a', self.root / 'empty.m4a', self.root / 'link.m4a', Path('/Volumes/remote.m4a')]:
            if path.name == 'empty.m4a':
                path.touch()
            if path.name == 'link.m4a':
                path.symlink_to(self.path)
            self.assertFalse(c.audit(self.request, [dict(self.source, path=str(path))])['playlists'][0]['ready'])

    def test_order_and_duplicates_preserved(self):
        other = dict(self.track, id='456')
        self.request['playlists'][0]['tracks'] = [other, self.track, other]
        result = c.audit(self.request, [self.source])['playlists'][0]
        self.assertEqual([t['id'] for t in result['tracks']], ['456', '123', '456'])

    def test_floor_blocks_without_creating_cache_or_touching_source(self):
        cache = self.root / 'cache'
        with patch.object(c, 'physical_free', return_value=60_000_000_000):
            result = c.audit(self.request, [self.source], copy=True, cache=cache)['playlists'][0]
        self.assertFalse(result['ready'])
        self.assertIn('storage floor', result['missing'][0]['reason'])
        self.assertFalse(cache.exists())
        self.assertEqual(self.path.read_bytes(), audio())

    def test_copy_integrity_and_repeat_no_extra_bytes(self):
        cache = self.root / 'cache'
        with patch.object(c, 'physical_free', return_value=c.FLOOR + 10000):
            first = c.audit(self.request, [self.source], copy=True, cache=cache)
            second = c.audit(self.request, [self.source], copy=True, cache=cache)
        row = first['playlists'][0]['tracks'][0]
        self.assertEqual(Path(row['path']).read_bytes(), self.path.read_bytes())
        self.assertEqual(first['playlists'], second['playlists'])
        self.assertEqual(len(list(cache.iterdir())), 1)

    def test_copy_then_fresh_prepare_finds_cache_with_and_without_original(self):
        cache = self.root / 'cache'
        with patch.object(c, 'physical_free', return_value=c.FLOOR + 10000):
            result = c.audit(self.request, [self.source], copy=True, cache=cache)
        self.assertTrue(result['playlists'][0]['ready'])
        # Fixture root contains both exact byte copies. Fresh CLI must collapse
        # these, then still find the copied file after ONLY the fixture is removed.
        self.assertEqual(self.cli('prepare').returncode, 0)
        self.path.unlink()
        self.assertEqual(self.cli('prepare').returncode, 0)
        report = json.loads((self.root / 'manifest.json').read_text())
        self.assertTrue(report['playlists'][0]['ready'])
        self.assertTrue(Path(report['playlists'][0]['tracks'][0]['path']).is_relative_to(cache))

    def test_copy_aborts_if_floor_changes_and_cleans_only_own_temp(self):
        cache = self.root / 'cache'
        with patch.object(c, 'physical_free', side_effect=[c.FLOOR + 10000, 0]):
            result = c.audit(self.request, [self.source], copy=True, cache=cache)
        self.assertFalse(result['playlists'][0]['ready'])
        self.assertEqual(list(cache.iterdir()), [])
        self.assertEqual(self.path.read_bytes(), audio())

    def test_corrupt_existing_cache_never_overwritten(self):
        cache = self.root / 'cache'
        cache.mkdir()
        info = c.verified(self.path)
        target = cache / (info['sha256'] + '.m4a')
        target.write_bytes(b'corruption')
        result = c.audit(self.request, [self.source], copy=True, cache=cache)
        self.assertFalse(result['playlists'][0]['ready'])
        self.assertEqual(target.read_bytes(), b'corruption')

    def test_cache_metadata_reuses_unchanged_tags(self):
        cached = {}
        c.inventory([self.root], cached=cached)
        with patch.object(c, 'mp4_tags', side_effect=AssertionError('reparse')):
            self.assertEqual(len(c.inventory([self.root], cached=cached)), 1)

    def test_empty_playlist_never_ready(self):
        self.request['playlists'][0]['tracks'] = []
        self.assertFalse(c.audit(self.request, [])['playlists'][0]['ready'])

    def test_publish_atomic_document(self):
        target = self.root / 'manifest.json'
        c.publish({'schemaVersion': 1}, target)
        self.assertEqual(json.loads(target.read_text()), {'schemaVersion': 1})
        self.assertFalse(list(self.root.glob('.manifest-*')))

    def cli(self, command):
        requests = self.root / 'requests.json'
        requests.write_text(json.dumps(self.request))
        return subprocess.run([sys.executable, str(Path(c.__file__)), command,
                               '--requests', str(requests), '--root', str(self.root),
                               '--manifest', str(self.root / 'manifest.json')],
                              text=True, capture_output=True, timeout=10)

    def test_cli_audit_does_not_publish_or_cache(self):
        result = self.cli('audit')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / 'manifest.json').exists())
        self.assertFalse((self.root / 'manifest.metadata.json').exists())
        self.assertFalse((self.root / 'manifest.lock').exists())

    def test_cli_prepare_gap_publishes_exit_two(self):
        self.request['playlists'][0]['tracks'][0]['album'] = 'Another'
        result = self.cli('prepare')
        self.assertEqual(result.returncode, 2, result.stderr)
        report = json.loads((self.root / 'manifest.json').read_text())
        self.assertFalse(report['playlists'][0]['ready'])
        self.assertEqual(self.path.read_bytes(), audio())

    def test_cli_single_writer_busy(self):
        with (self.root / 'manifest.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.cli('prepare')
        self.assertEqual(result.returncode, 75, result.stderr)
        self.assertFalse((self.root / 'manifest.json').exists())

    def test_manifest_freshness_and_full_request_identity(self):
        result = c.audit(self.request, [self.source])['playlists'][0]
        self.assertEqual(result['requestedTracks'], [self.track])
        info = result['tracks'][0]
        self.assertEqual(info['mtimeNs'], str(self.path.stat().st_mtime_ns))
        self.assertEqual(info['inode'], str(self.path.stat().st_ino))

    def test_protected_sample_entries_rejected_even_explicit_id(self):
        for codec in (b'drms', b'enca', b'encv'):
            table = atom(b'stsd', b'\0'*4 + struct.pack('>I', 1) + atom(codec, b'\0'*28))
            for parent in (b'stbl', b'minf', b'mdia', b'trak', b'moov'):
                table = atom(parent, table)
            self.path.write_bytes(audio() + table)
            with self.assertRaisesRegex(ValueError, 'protected'):
                c.verified(self.path)
            self.assertFalse(c.audit(self.request, [self.source])['playlists'][0]['ready'])
            self.assertEqual(c.inventory([self.root]), [])

    def test_verification_cache_avoids_repeat_hash_and_invalidates_rewrites(self):
        cached = {}
        first = c.verified(self.path, cached)
        with patch.object(c.hashlib, 'sha256', side_effect=AssertionError('rehash')):
            self.assertEqual(c.verified(self.path, cached), first)
        previous = self.path.stat()
        self.path.write_bytes(audio(title='Sang'))  # Same size, restored mtime.
        os.utime(self.path, ns=(previous.st_atime_ns, previous.st_mtime_ns))
        second = c.verified(self.path, cached)
        self.assertNotEqual(first['sha256'], second['sha256'])

    def test_prepare_persists_versioned_metadata_and_verified_cache(self):
        self.assertEqual(self.cli('prepare').returncode, 0)
        saved = json.loads((self.root / 'manifest.metadata.json').read_text())
        self.assertEqual(saved['schemaVersion'], 3)
        self.assertIn(str(self.path), saved['metadata'])
        self.assertIn(str(self.path), saved['verified'])
        self.assertEqual(saved['verified'][str(self.path)]['stamp'], c.fingerprint(self.path.stat()))
        self.assertEqual(self.cli('prepare').returncode, 0)

    def test_metadata_only_and_truncated_files_never_ready(self):
        invalid = [atom(b'ftyp', b'M4A ' + b'\0'*4) + atom(b'moov', b''),
                   audio()[:-1], audio() + b'bad',
                   audio().replace(b'mdat', b'free'),
                   audio().replace(b'mp4a', b'avc1')]
        for data in invalid:
            self.path.write_bytes(data)
            self.assertFalse(c.audit(self.request, [self.source])['playlists'][0]['ready'])

    def test_index_cannot_override_embedded_recording_identity(self):
        for field in ('title', 'artist', 'album'):
            self.path.write_bytes(audio(**{field: 'Another recording'}))
            result = c.audit(self.request, [self.source])['playlists'][0]
            self.assertFalse(result['ready'])
            self.assertIn('contradicts', result['missing'][0]['reason'])
            with patch.object(c, 'copy_verified', side_effect=AssertionError('must not copy')):
                self.assertFalse(c.audit(self.request, [self.source], copy=True)['playlists'][0]['ready'])

    def test_old_verification_cache_cannot_bypass_structure_check(self):
        self.path.write_bytes(atom(b'ftyp', b'M4A ' + b'\0'*4))
        cached = {str(self.path): {'stamp': c.fingerprint(self.path.stat()), 'info': {
            'path': str(self.path), 'sizeBytes': self.path.stat().st_size,
            'mtimeNs': str(self.path.stat().st_mtime_ns), 'inode': str(self.path.stat().st_ino),
            'sha256': '0'*64}}}
        with self.assertRaisesRegex(ValueError, 'requires'):
            c.verified(self.path, cached)

    def test_malformed_atoms_bounded(self):
        self.path.write_bytes(struct.pack('>I4s', 2, b'moov'))
        with self.assertRaisesRegex(ValueError, 'malformed'):
            c.mp4_tags(self.path)

    def test_hot_lossless_preferred_over_lossy_ambiguity(self):
        hot = self.root / 'hot'
        hot.mkdir()
        lossy = self.root / 'lossy.m4a'
        lossy.write_bytes(audio())
        hot_file = hot / 'song.m4a'
        hot_file.write_bytes(audio() + atom(b'free', b'lossless extra'))
        sources = [
            dict(self.track, path=str(lossy)),
            dict(self.track, path=str(hot_file)),
        ]
        picked, reason = c.select(self.track, sources, hot_dir=hot)
        self.assertIsNone(reason)
        self.assertEqual(picked['path'], str(hot_file))

    def test_trusted_binding_without_metadata_match(self):
        hot = self.root / 'hot'
        hot.mkdir()
        hot_file = hot / 'bound.m4a'
        hot_file.write_bytes(audio(title='Different', artist='Names', album='X'))
        info = c.verified(hot_file)
        track = dict(self.track, album='Album', catalogue_relative_path='bound.m4a', sha256=info['sha256'])
        picked, reason = c.select(track, [], hot_dir=hot, verification_cache={})
        self.assertIsNone(reason)
        self.assertEqual(picked['sha256'], info['sha256'])


if __name__ == '__main__':
    unittest.main()
