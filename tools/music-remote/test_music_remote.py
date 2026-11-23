import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location('music_remote', Path(__file__).with_name('music-remote.py'))
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)


class MusicRemotePlaybackTests(unittest.TestCase):
    def _write_log(self, rows):
        tmp = tempfile.NamedTemporaryFile('w', suffix='.jsonl', delete=False)
        for r in rows:
            tmp.write(json.dumps(r) + '\n')
        tmp.close()
        self.addCleanup(lambda: Path(tmp.name).unlink(missing_ok=True))
        return Path(tmp.name)

    def test_auto_advance_track_and_meta_without_new_rate(self):
        p = self._write_log([
            {'event': 'launch', 'epoch': 100.0},
            {'event': 'track', 'file': 'Artist Alpha - Track One [SYNTH0001].m4a', 'title': 'Track One', 'artist': 'Artist Alpha', 'epoch': 101.0},
            {'event': 'rate', 'state': 'playing', 'file': 'Artist Alpha - Track One [SYNTH0001].m4a', 'title': 'Track One', 'artist': 'Artist Alpha', 'epoch': 101.1},
            {'event': 'track', 'file': '07. Track Two.m4a', 'title': 'Track Two', 'artist': '', 'epoch': 200.0},
            {'event': 'meta', 'file': '07. Track Two.m4a', 'title': 'Track Two', 'artist': 'Artist Beta', 'epoch': 200.2},
        ])
        cur = MOD.current_playback(p)
        self.assertEqual(cur['state'], 'playing')
        self.assertEqual(cur['title'], 'Track Two')
        self.assertEqual(cur['artist'], 'Artist Beta')
        self.assertEqual(cur['file'], '07. Track Two.m4a')

    def test_legacy_blank_title_track_uses_filename_fallback_and_ignores_silent_qa(self):
        p = self._write_log([
            {'event': 'rate', 'state': 'playing', 'file': 'Artist Alpha - Track One [SYNTH0001].m4a', 'title': 'Track One', 'artist': 'Artist Alpha', 'epoch': 101.0},
            {'event': 'track', 'file': '10. Track Three.m4a', 'title': '', 'artist': '', 'epoch': 250.0},
            {'event': 'track', 'file': 'dislike-a.m4a', 'title': 'Wing One', 'artist': 'Faux Pilot', 'silentQA': True, 'epoch': 260.0},
        ])
        cur = MOD.current_playback(p)
        self.assertEqual(cur['state'], 'playing')
        self.assertEqual(cur['title'], 'Track Three')
        self.assertIsNone(cur['artist'])
        self.assertEqual(cur['file'], '10. Track Three.m4a')

    def test_pause_and_launch_reset(self):
        p = self._write_log([
            {'event': 'track', 'file': 'Artist Gamma - Track Four [SYNTH0004].m4a', 'title': 'Track Four', 'artist': 'Artist Gamma', 'epoch': 300.0},
            {'event': 'rate', 'state': 'paused', 'epoch': 310.0},
        ])
        cur = MOD.current_playback(p)
        self.assertEqual(cur['state'], 'paused')
        self.assertEqual(cur['title'], 'Track Four')
        self.assertEqual(cur['artist'], 'Artist Gamma')

        p2 = self._write_log([
            {'event': 'track', 'file': '10. Track Three.m4a', 'title': 'Track Three', 'artist': 'Artist Delta', 'epoch': 300.0},
            {'event': 'rate', 'state': 'playing', 'epoch': 301.0},
            {'event': 'launch', 'epoch': 400.0},
        ])
        self.assertIsNone(MOD.current_playback(p2))


if __name__ == '__main__':
    unittest.main()
