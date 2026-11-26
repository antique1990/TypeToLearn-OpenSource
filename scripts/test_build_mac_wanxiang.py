#!/usr/bin/env python3
"""Data-import edge cases that would otherwise change actual keyboard spelling."""
from pathlib import Path
import tempfile
import unittest
import sqlite3
import hashlib

from build_mac_wanxiang import (romanize, rows, compact_database, remove_excluded_entries,
                                apply_candidate_exclusions, apply_common_character_policy)


class ImportTests(unittest.TestCase):
    def test_full_character_policy_preserves_original_standard_names_and_cangjie(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'lexicon.sqlite'
            db = sqlite3.connect(path)
            db.executescript('''CREATE TABLE pinyin(code,digits,roman,simplified,traditional,weight);
                CREATE TABLE english(word,weight); CREATE TABLE cangjie(code,text,weight);
                CREATE TABLE wanxiang_codes(script,source,text,code,weight);''')
            db.executemany('INSERT INTO pinyin VALUES (?,?,?,?,?,?)', [
                ('wei','934','wei','微','微',100), ('foo','366','foo','㐀','㐀',1),
                ('foozi','36694','foo zi','㐀字','㐀字',1), ('fu','38','fu','㕮','㕮',4),
                ('zhi','944','zhi','凪','凪',5), ('he','43','he','𬌗','𬌗',6),
                ('yihao','94426','yi hao','1号·','1號·',7), ('ling','5464','ling','〇','〇',8)])
            db.execute('INSERT INTO cangjie VALUES (?,?,?)',('a','㐀',1))
            db.execute('INSERT INTO english VALUES (?,?)',('application',100))
            db.commit(); db.close()
            result = apply_common_character_policy(path)
            self.assertEqual(result['excludedCharacterCount'], 1)
            self.assertEqual(result['removedRows'], {'pinyin':2})
            db = sqlite3.connect(path)
            self.assertEqual({r[0] for r in db.execute('SELECT simplified FROM pinyin')},
                             {'微','㕮','凪','𬌗','1号·','〇'})
            self.assertEqual(db.execute('SELECT text FROM cangjie').fetchall(), [('㐀',)])
            self.assertEqual(db.execute('SELECT word FROM english').fetchall(), [('application',)])
            db.close()

    def test_font_exclusions_remove_unrenderable_rows_without_banning_all_extended_han(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'lexicon.sqlite'
            db = sqlite3.connect(path)
            db.executescript('''CREATE TABLE pinyin(code,digits,roman,simplified,traditional,weight);
                CREATE TABLE english(word,weight); CREATE TABLE cangjie(code,text,weight);
                CREATE TABLE wanxiang_codes(script,source,text,code,weight);''')
            db.executemany('INSERT INTO pinyin VALUES (?,?,?,?,?,?)', [
                ('ni','64','ni','你','你',100), ('ni','64','ni','𫆏','𫆏',105),
                ('nizi','6494','ni zi','𫆏字','𫆏字',1), ('he','43','he','𬌗','𬌗',4)])
            db.executemany('INSERT INTO cangjie VALUES (?,?,?)', [('a','𫆏',1),('b','你',100)])
            db.executemany('INSERT INTO wanxiang_codes VALUES (?,?,?,?,?)',
                           [('hans','sample','𫆏','ni',1),('hans','sample','你','ni',100)])
            db.execute('INSERT INTO english VALUES (?,?)',('application',100))
            db.commit(); db.close()
            report = remove_excluded_entries(path, {'𫆏'})
            self.assertEqual(report['removedRows'], {'pinyin':2,'cangjie':1,'wanxiang_codes':1})
            db = sqlite3.connect(path)
            self.assertEqual(db.execute('SELECT simplified,weight FROM pinyin ORDER BY weight DESC').fetchall(),
                             [('你',100),('𬌗',4)])
            self.assertEqual(db.execute('SELECT word FROM english').fetchall(), [('application',)])
            db.close()
            self.assertEqual(remove_excluded_entries(path, {'𫆏'})['removedRows'],
                             {'pinyin':0,'cangjie':0,'wanxiang_codes':0})

    def test_user_candidate_profile_removes_requested_characters_and_their_phrases(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'lexicon.sqlite'
            db = sqlite3.connect(path)
            db.executescript('''CREATE TABLE pinyin(code,digits,roman,simplified,traditional,weight);
                CREATE TABLE cangjie(code,text,weight);
                CREATE TABLE wanxiang_codes(script,source,text,code,weight);''')
            db.executemany('INSERT INTO pinyin VALUES (?,?,?,?,?,?)', [
                ('wei','934','wei','微','微',100), ('wei','934','wei','𬀩','𬀩',120),
                ('weizi','93494','wei zi','𬀩字','𬀩字',1), ('ji','54','ji','𠮷','𠮷',4)])
            db.commit(); db.close()
            report = apply_candidate_exclusions(path)
            self.assertEqual(report['excludedCharacterCount'], 40)
            self.assertEqual(report['removedRows'], {'pinyin':2,'cangjie':0,'wanxiang_codes':0})
            db = sqlite3.connect(path)
            self.assertEqual(db.execute('SELECT simplified,weight FROM pinyin ORDER BY weight DESC').fetchall(),
                             [('微',100),('𠮷',4)])
            db.close()

    def test_umlaut_and_tones_keep_the_keyboard_v_code(self):
        self.assertEqual(romanize('nǚ lǜ lüè'), 'nv lv lve')
        self.assertEqual(romanize('xī ān'), 'xi an')

    def test_mixed_reading_keeps_ascii_and_syllable_boundaries(self):
        self.assertEqual(romanize("A'gǔ"), 'a gu')
        self.assertEqual(romanize('GPT-6'), 'gpt-6')

    def test_bad_upstream_weight_preserves_word_and_reports_fallback(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'jichu.dict.yaml'
            path.write_text('---\nname: sample\n...\n复方丹参\tfù fāng dān shēn\t6N\n你好\tnǐ hǎo\t42\n', encoding='utf-8')
            warnings = []
            found = list(rows(path, warnings))
            self.assertEqual(found, [('复方丹参', 'fù fāng dān shēn', 1), ('你好', 'nǐ hǎo', 42)])
            self.assertEqual(warnings[0]['original'], '6N')
            self.assertEqual(warnings[0]['line'], 4)

    def test_abbreviation_without_frequency_is_not_discarded(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'abbrev.dict.yaml'
            path.write_text('# comment\n---\nname: sample\n...\n好吃\thi\n', encoding='utf-8')
            self.assertEqual(list(rows(path)), [('好吃', 'hi', 1)])

    def test_compact_projection_keeps_single_and_every_reachable_typo_length(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'lexicon.sqlite'
            db = sqlite3.connect(path)
            db.executescript('''CREATE TABLE pinyin(code,digits,roman,simplified,traditional,weight);
                CREATE TABLE english(word,weight); CREATE TABLE cangjie(code,text,weight);
                CREATE TABLE wanxiang_codes(script,source,text,code,weight);''')
            db.executemany('INSERT INTO pinyin VALUES (?,?,?,?,?,?)', [
                ('nv','68','nv','女','女',100), ('ab','22','a b','短码','短碼',7),
                ('abc','222','a b c','边界','邊界',9), ('a'*13,'2'*13,'a '*12+'a','共享字','共享字',11),
                ('a'*14,'2'*14,'a '*13+'a','长词语','長詞語',13)])
            db.commit(); db.close()
            counts = compact_database(path)
            self.assertEqual(counts['pinyin'], 1)
            self.assertEqual(counts['pinyin_phrases'], 2)
            db = sqlite3.connect(path)
            self.assertEqual(db.execute('SELECT traditional,weight FROM pinyin_phrases WHERE code=?',('a'*13,)).fetchone(), ('',11))
            self.assertEqual(db.execute('SELECT traditional,weight FROM pinyin_phrases WHERE code=?',('abc',)).fetchone(), ('邊界',9))
            db.close()
            before = hashlib.sha256(path.read_bytes()).hexdigest()
            self.assertEqual(compact_database(path), counts)
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), before)


if __name__ == '__main__':
    unittest.main()
