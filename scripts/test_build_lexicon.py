"""Regression tests for CC-CEDICT alternate readings (no downloads required)."""
import unittest

from build_lexicon import cedict_pronunciations


class AlternatePronunciationTests(unittest.TestCase):
    def test_common_alternate_readings(self):
        for primary, alternate, expected in [
            ('shei2', 'shui2', 'shui'), ('shu2', 'shou2', 'shou'),
            ('yue4', 'yao4', 'yao'), ('jiao2', 'jue2', 'jue'),
            ('ze2', 'zhai2', 'zhai'),
        ]:
            with self.subTest(primary=primary):
                self.assertIn(expected, cedict_pronunciations(primary, f'/also pr. [{alternate}]/'))

    def test_compact_syllables_hyphens_and_umlaut(self):
        self.assertEqual(cedict_pronunciations('jue2 se4', '/role/also pr. [jiao3se4]/'),
                         ['jue se', 'jiao se'])
        self.assertEqual(cedict_pronunciations('yi1 mu2 yi1 yang4', '/also pr. [yi1mo2-yi1yang4]/'),
                         ['yi mu yi yang', 'yi mo yi yang'])
        self.assertEqual(cedict_pronunciations('Lu4 lin2', '/also pr. [Lu:4 lin2]/'),
                         ['lu lin', 'lv lin'])

    def test_multiple_alternates_and_tone_only_duplicates(self):
        self.assertEqual(cedict_pronunciations('shei2', '/also pr. [shui2] or [shui3], [shei3]/'),
                         ['shei', 'shui'])
        self.assertEqual(cedict_pronunciations('dai1 hui4 r5', '/also pr. [dai1 hui3 r5] or [dai1 hui5 r5]/'),
                         ['dai hui r'])

    def test_definition_references_and_qualified_readings_are_not_alternates(self):
        self.assertEqual(cedict_pronunciations('shen4',
                         '/used in 桑葚[sang1 shen4]/also pr. [ren4]/see 任[ren4]/'),
                         ['shen', 'ren'])
        self.assertEqual(cedict_pronunciations('shi1',
                         '/old pr. [shai1]/Taiwan pr. [si1]/dialect pr. [xi1]/'), ['shi'])

    def test_malformed_or_wrong_length_alternates_are_rejected(self):
        for alternate in ['shui', 'shui2!', 'shui0', 'shui2 ren2', 'CP']:
            with self.subTest(alternate=alternate):
                self.assertEqual(cedict_pronunciations('shei2', f'/also pr. [{alternate}]/'), ['shei'])


if __name__ == '__main__':
    unittest.main()
