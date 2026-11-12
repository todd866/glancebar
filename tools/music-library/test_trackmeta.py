#!/usr/bin/python3
"""Tests for trackmeta: every download keeps its metadata and cover (owner rule, 12 Nov 2026)."""
import hashlib
import struct
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'offline-cache'))
import musiclib  # noqa: E402
import trackmeta  # noqa: E402

JPEG = b'\xff\xd8\xff\xe0' + b'cover-bytes' * 40


def atom(kind, body):
    return struct.pack('>I4s', len(body) + 8, kind) + body


def text(kind, value):
    return atom(kind, atom(b'data', struct.pack('>II', 1, 0) + value.encode()))


def freeform(name, value):
    return atom(b'----', atom(b'mean', b'\0' * 4 + b'com.apple.iTunes') + atom(b'name', b'\0' * 4 + name.encode())
                + atom(b'data', struct.pack('>II', 1, 0) + value.encode()))


def m4a(title='Song', artist='Artist', album='Album', *, art=JPEG, seconds=252.5, version=0, isrc='AUUM71500300'):
    timescale = 44100
    duration = int(seconds * timescale)
    if version == 0:
        mvhd = struct.pack('>B3xIIII', 0, 0, 0, timescale, duration) + b'\0' * 80
        mdhd = struct.pack('>B3xIIII', 0, 0, 0, timescale, duration) + b'\0' * 4
    else:
        mvhd = struct.pack('>B3xQQIQ', 1, 0, 0, timescale, duration) + b'\0' * 80
        mdhd = struct.pack('>B3xQQIQ', 1, 0, 0, timescale, duration) + b'\0' * 4
    sample = atom(b'alac', b'\0' * 28)
    table = atom(b'stsd', b'\0' * 4 + struct.pack('>I', 1) + sample)
    for parent in (b'stbl', b'minf'):
        table = atom(parent, table)
    trak = atom(b'trak', atom(b'mdia', atom(b'mdhd', mdhd) + table))
    items = b''
    if title:
        items += text(b'\xa9nam', title)
    if artist:
        items += text(b'\xa9ART', artist)
    if album:
        items += text(b'\xa9alb', album)
    items += text(b'aART', 'Album Artist') + text(b'\xa9day', '2015-07-17') + text(b'\xa9gen', 'Alternative')
    items += atom(b'trkn', atom(b'data', struct.pack('>II', 0, 0) + struct.pack('>HHHH', 0, 11, 13, 0)))
    items += text(b'\xa9lyr', 'la la la')
    if isrc:
        items += freeform('ISRC', isrc)
    if art:
        items += atom(b'covr', atom(b'data', struct.pack('>II', 13, 0) + art))
    return (atom(b'ftyp', b'M4A ' + b'\0' * 4)
            + atom(b'moov', atom(b'mvhd', mvhd) + trak + atom(b'udta', atom(b'meta', b'\0' * 4 + atom(b'ilst', items))))
            + atom(b'mdat', b'fake-synthetic-sample-bytes'))


class TrackMetaTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, rel, data):
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def test_reads_tags_identifiers_duration_and_cover(self):
        meta = trackmeta.read_track_metadata(self.write('a.m4a', m4a()))
        self.assertEqual((meta['title'], meta['artist'], meta['album']), ('Song', 'Artist', 'Album'))
        self.assertEqual((meta['albumArtist'], meta['date'], meta['genre']), ('Album Artist', '2015-07-17', 'Alternative'))
        self.assertEqual((meta['track'], meta['trackTotal']), (11, 13))
        self.assertEqual(meta['isrc'], 'AUUM71500300')
        self.assertAlmostEqual(meta['durationSeconds'], 252.5, places=2)
        self.assertEqual(meta['art'], {'format': 'jpeg', 'bytes': len(JPEG), 'sha256': hashlib.sha256(JPEG).hexdigest()})
        self.assertEqual(trackmeta.metadata_gaps(meta), [])

    def test_duration_from_a_64_bit_header(self):
        meta = trackmeta.read_track_metadata(self.write('b.m4a', m4a(seconds=3600.25, version=1)))
        self.assertAlmostEqual(meta['durationSeconds'], 3600.25, places=2)
        # The catalogue's reader used the wrong bytes and said 0.0 for every file (12 Nov 2026).
        self.assertAlmostEqual(musiclib.mp4_duration_seconds(self.write('c.m4a', m4a(seconds=200))), 200.0, places=2)

    def test_gaps_are_named(self):
        meta = trackmeta.read_track_metadata(self.write('d.m4a', m4a(album='', art=None)))
        self.assertEqual(trackmeta.metadata_gaps(meta), ['album', 'art'])

    def test_damaged_file_does_not_raise(self):
        meta = trackmeta.read_track_metadata(self.write('e.m4a', m4a()[:90]))
        self.assertIn('title', trackmeta.metadata_gaps(meta))
        self.assertIn('title', trackmeta.metadata_gaps(trackmeta.read_track_metadata(self.root / 'absent.m4a')))

    def test_cover_file_is_written_once_and_never_replaced(self):
        track = self.write('Artist/Album/01. Song.m4a', m4a())
        result = trackmeta.check_download(track)
        cover = track.parent / 'cover.jpg'
        self.assertTrue(result['ok'])
        self.assertEqual(Path(result['cover']), cover)
        self.assertEqual(cover.read_bytes(), JPEG)
        cover.write_bytes(b'the cover amdl wrote, kept as it is')
        trackmeta.check_download(track)
        self.assertEqual(cover.read_bytes(), b'the cover amdl wrote, kept as it is')

    def test_download_without_art_is_reported(self):
        result = trackmeta.check_download(self.write('x/01.m4a', m4a(art=None)))
        self.assertFalse(result['ok'])
        self.assertEqual(result['gaps'], ['art'])
        self.assertIsNone(result['cover'])

    def test_catalogue_keeps_the_metadata_and_a_copy_beside_the_masters(self):
        masters = self.root / 'masters'
        self.write('masters/AM-Lossless/Artist/Album/11. Song.m4a', m4a())
        state = self.root / 'state'
        doc = musiclib.catalogue_command(masters, 'unused:', state, upload=False)
        entry = doc['entries'][0]
        self.assertEqual(entry['meta']['isrc'], 'AUUM71500300')
        self.assertEqual(entry['meta']['art']['bytes'], len(JPEG))
        self.assertTrue(entry['meta']['hasLyrics'])
        self.assertNotIn('lyrics', entry['meta'])
        self.assertAlmostEqual(entry['durationSeconds'], 252.5, places=2)
        self.assertEqual(entry['tags'], {'title': 'Song', 'artist': 'Artist', 'album': 'Album'})
        import json
        beside = json.loads((masters / '_metadata' / 'library-metadata.json').read_text())
        self.assertEqual(beside['entries'], doc['entries'])
        # The record is not itself a master.
        self.assertEqual(len(musiclib.catalogue_command(masters, 'unused:', state, upload=False)['entries']), 1)

    def test_old_cache_entries_gain_metadata_without_rehashing(self):
        masters = self.root / 'masters'
        track = self.write('masters/a.m4a', m4a())
        state = self.root / 'state'
        st = track.stat()
        musiclib.save_build_cache(musiclib.state_dir(state), {'a.m4a': {
            'stamp': [st.st_size, str(st.st_mtime_ns)],
            'entry': {'relativePath': 'a.m4a', 'sizeBytes': st.st_size, 'mtimeNs': str(st.st_mtime_ns),
                      'sha256': 'hash-from-the-earlier-full-read', 'tags': {}, 'durationSeconds': 0.0}}})
        entry = musiclib.catalogue_command(masters, 'unused:', state, upload=False)['entries'][0]
        self.assertEqual(entry['sha256'], 'hash-from-the-earlier-full-read')
        self.assertEqual(entry['meta']['isrc'], 'AUUM71500300')
        self.assertAlmostEqual(entry['durationSeconds'], 252.5, places=2)

    def test_zero_duration_in_an_old_catalogue_is_unknown_not_a_mismatch(self):
        entries = [{'relativePath': 'a.m4a', 'tags': {'title': 'Song', 'artist': 'Artist'}, 'durationSeconds': 0.0}]
        hits, reason = musiclib.match_track({'artist': 'Artist', 'title': 'Song', 'durationSeconds': 200.0}, entries)
        self.assertEqual(len(hits), 1, reason)


if __name__ == '__main__':
    unittest.main()
