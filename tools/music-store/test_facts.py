"""facts.py: the year rules ported from the radio's years.py, seeds first, budget, sourced records."""
import unittest

import facts

A, B = 'a' * 64, 'b' * 64


def fake(responses, log):
    def transport(url):
        log.append(url)
        for frag, value in responses.items():
            if frag in url:
                return value
        return None
    return transport


class FactsTest(unittest.TestCase):
    def entries(self):
        return [{'sha256': A, 'mtimeNs': '2', 'durationSeconds': 211.0, 'meta': {'isrc': 'X1'},
                 'tags': {'artist': 'Beastie Boys', 'title': 'Sure Shot', 'album': 'Ill Communication'}},
                {'sha256': B, 'mtimeNs': '1', 'tags': {'artist': 'Zed feat. Q', 'title': 'Other', 'album': ''}}]

    def test_year_from_earliest_matching_recording_not_reissue(self):
        log = []
        mb = {'recordings': [
            {'score': 100, 'title': 'Sure Shot', 'first-release-date': '2005-01-01', 'artist-credit': [{'name': 'Beastie Boys'}]},
            {'score': 100, 'title': 'Sure Shot', 'first-release-date': '1994-05-31', 'artist-credit': [{'name': 'Beastie Boys'}]},
            {'score': 100, 'title': 'Sure Shot', 'first-release-date': '1990', 'artist-credit': [{'name': 'Someone Else'}]}]}
        net = facts.Net(10, transport=fake({'musicbrainz.org/ws/2/recording': mb}, log), sleep=lambda s: None)
        self.assertEqual(facts.mb_year(net, 'Beastie Boys', 'Sure Shot', 'Ill Communication'), (1994, 'MusicBrainz recording'))

    def test_build_uses_seeds_records_sources_and_stops_at_budget(self):
        log = []
        wiki = {'type': 'standard', 'title': 'Beastie Boys', 'description': 'American hip hop group',
                'extract': '...', 'content_urls': {'desktop': {'page': 'https://en.wikipedia.org/wiki/Beastie_Boys'}}}
        net = facts.Net(2, transport=fake({'lrclib.net': {'id': 7, 'syncedLyrics': '[00:01] x'},
                                           'wikipedia.org': wiki}, log), sleep=lambda s: None)
        cache = {}
        doc = facts.build(self.entries(), cache, net, seeds={A: 1994}, art={A})
        a = doc['songs'][A]
        self.assertEqual((a['year'], a['yearSource']), (1994, 'MusicBrainz (6IAN years.py)'))
        self.assertEqual(a['lyrics']['id'], 7)
        self.assertTrue(a['lyrics']['synced'])
        self.assertEqual(a['bio']['url'], 'https://en.wikipedia.org/wiki/Beastie_Boys')
        self.assertEqual(a['cover']['art'], f'radio/art/{A}.jpg')
        self.assertTrue(doc['counts']['budgetHit'])              # B waits for the next run
        self.assertNotIn('year', doc['songs'][B])
        self.assertFalse(any('musicbrainz' in u for u in log))   # the seed answered the year
        net2 = facts.Net(10, transport=fake({}, log), sleep=lambda s: None)
        doc2 = facts.build(self.entries(), cache, net2, seeds={B: None})
        self.assertEqual(doc2['songs'][B]['yearSource'], 'MusicBrainz: no match')
        self.assertEqual(doc2['counts']['complete'], 2)

    def test_non_musician_page_is_not_a_bio(self):
        net = facts.Net(5, transport=lambda url: {'type': 'standard', 'description': 'a city in France', 'extract': 'Paris'},
                        sleep=lambda s: None)
        self.assertIsNone(facts.wikipedia(net, 'Paris'))


if __name__ == '__main__':
    unittest.main()
