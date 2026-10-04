"""Offline regression cases for source extraction and fail-closed catalog updates."""
import unittest

from update_catalog import CatalogError, DIFFICULTIES, build_catalog, match_key, parse_songs


def pages(count=78):
    result = {name: [] for name in ('appmedia', 'gamerch', 'wikiwiki', 'wikilist')}
    for i in range(count):
        title = f'曲{i}'
        levels = [5, 10, 18, 25]
        result['appmedia'].append(f'<tr data-name="{title}" data-band="MyGO!!!!!"><td><a href="/bang-dream-on/{i}">{title}</a></td><td>オリジナル</td><td>' + ''.join(f'<div>{d.title()}</div><div>{n}</div>' for d, n in zip(DIFFICULTIES, levels)) + '</td></tr>')
        result['gamerch'].append(f'<tr><td><a href="/bang-dream-on/{i}">{title}</a></td><td>' + '/'.join(f'{d}：{n}' for d, n in zip(DIFFICULTIES, levels)) + '</td></tr>')
        result['wikiwiki'].append(f'<tr><td>{i+1}</td><td>{i+1}</td><td>image</td><td><a href="/on_database/page-{i}"><ruby>{title}<rp>(</rp><rt>よみがな</rt><rp>)</rp></ruby></a></td><td>紅赤</td></tr>')
        result['wikilist'].append(f'<tr><td><a href="/on_database/page-{i}">{title}</a></td><td>オリジナル</td><td>MG</td><td>紅赤</td>' + ''.join(f'<td>{n}</td>' for n in levels) + '<td>2026/09/24</td></tr>')
    result = {name: '<table>' + ''.join(rows) + '</table>' for name, rows in result.items()}
    result['schedule'] = '<h2>楽曲追加予定まとめ</h2><table><tr data-id="999"><td>予定曲</td><td>band</td><td>2026年10月3日</td></tr></table><h2>楽曲追加履歴一覧</h2><table>' + ''.join(f'<tr data-id="{i}"><td>曲{i}</td><td>band</td><td>2026年9月24日</td></tr>' for i in range(6)) + '</table>'
    return result


class UpdateCatalogTests(unittest.TestCase):
    def build(self, source=None, previous=None):
        return build_catalog(source or pages(), previous, {'songs': []}, '2026-10-02')

    def test_all_difficulties_entities_and_reading_markup(self):
        result = self.build()
        self.assertEqual(len(result['songs']), 78)
        self.assertEqual(len({c['id'] for s in result['songs'] for c in s['charts']}), 312)
        self.assertEqual(result['songs'][0]['title'], '曲0')
        self.assertEqual(result['songs'][0]['charts'][0]['level'], 5)
        self.assertEqual(match_key('Symbol Ⅱ：🜁'), match_key('Symbol II : △'))
        self.assertNotEqual(match_key('春日影'), match_key('春日影(MyGO!!!!! ver.)'))

    def test_stable_ids_revision_and_noop(self):
        original = self.build()
        self.assertEqual(self.build(previous=original), original)
        source = {k: v.replace('曲0', '変更後の曲名') for k, v in pages().items()}
        updated = self.build(source, original)
        self.assertEqual(updated['revision'], 2)
        self.assertEqual(updated['songs'][0]['id'], original['songs'][0]['id'])
        self.assertEqual(updated['songs'][0]['charts'], original['songs'][0]['charts'])

    def test_linkless_appmedia_rows_keep_distinct_persistent_identity(self):
        source = pages()
        for i in (0, 1):
            source['appmedia'] = source['appmedia'].replace(
                f'data-name="曲{i}"', f'data-id="{i}" data-name="曲{i}"').replace(
                f'<a href="/bang-dream-on/{i}">曲{i}</a>', f'曲{i}')
        original = self.build(source)
        self.assertEqual(original['songs'][0]['observations']['appmedia']['rowID'], '0')
        self.assertEqual(original['songs'][1]['observations']['appmedia']['rowID'], '1')
        self.assertEqual(self.build(source, original), original)

    def test_linkless_appmedia_row_without_stable_id_aborts(self):
        source = pages()
        source['appmedia'] = source['appmedia'].replace('<a href="/bang-dream-on/0">曲0</a>', '曲0')
        with self.assertRaises(CatalogError):
            self.build(source)

    def test_unknown_song_membership_and_source_failure_abort(self):
        source = pages()
        source['appmedia'] = source['appmedia'].replace('曲0', '別の未確認曲')
        with self.assertRaises(CatalogError):
            self.build(source)
        with self.assertRaises(CatalogError):
            parse_songs('gamerch', '<html>temporary error</html>')

    def test_two_sites_resolve_a_conflict_but_ties_abort(self):
        source = pages()
        source['gamerch'] = source['gamerch'].replace('EASY：5', 'EASY：7')
        result = self.build(source)
        self.assertEqual(result['songs'][0]['charts'][0]['level'], 5)
        self.assertEqual(len(result['verification']['levelConflicts']), 78)
        source['wikilist'] = source['wikilist'].replace('<td>5</td>', '<td>6</td>')
        with self.assertRaises(CatalogError):
            self.build(source)

    def test_missing_difficulty_duplicate_rows_and_truncated_lists_abort(self):
        source = pages()
        source['appmedia'] = source['appmedia'].replace('<div>Expert</div><div>25</div>', '')
        with self.assertRaises(CatalogError):
            self.build(source)
        source = pages()
        source['appmedia'] += source['appmedia']
        with self.assertRaises(CatalogError):
            self.build(source)
        with self.assertRaises(CatalogError):
            self.build(pages(77))

    def test_old_ids_cannot_disappear_and_unreleased_song_is_not_added(self):
        original = self.build(pages(79))
        with self.assertRaises(CatalogError):
            self.build(pages(), original)
        source = pages()
        source['gamerch'] += '<table><tr><td><a href="/bang-dream-on/999">予定曲</a></td><td>EASY：5/NORMAL：10/HARD：18/EXPERT：25</td></tr></table>'
        result = self.build(source)
        self.assertEqual(len(result['songs']), 78)
        self.assertFalse(any(s['title'] == '予定曲' for s in result['songs']))


if __name__ == '__main__':
    unittest.main()
