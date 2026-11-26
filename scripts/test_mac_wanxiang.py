#!/usr/bin/env python3
"""Validate the actual packaged Mac dictionaries with native librime on this Mac."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sqlite3
import subprocess
import tempfile
from opencc import OpenCC

from build_mac_wanxiang import (ROOT, SOURCE, rows, romanize, FONT_EXCLUSIONS, CANDIDATE_EXCLUSIONS,
                                COMMON_CHARACTER_POLICY, unprotected_han_predicate)

parser = argparse.ArgumentParser()
parser.add_argument('--products', type=Path, default=ROOT / 'artifacts/mac-debug/Build/Products/Debug')
parser.add_argument('--before-glyph-cleanup', type=Path)
args = parser.parse_args()
products = args.products.resolve()
resources = products / 'TypeToLearnInputMethod.app/Contents/Resources/DictionaryResources'
db = sqlite3.connect(f'file:{resources}/lexicon.sqlite?mode=ro', uri=True)
manifest = json.loads((resources / 'wanxiang-manifest.json').read_text())
assert len(manifest['files']) == (16 if manifest.get('preset') == 'core' else 36)
assert db.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
for table, expected in manifest['counts'].items():
    assert db.execute(f'SELECT count(*) FROM {table}').fetchone()[0] == expected
if 'rareCharacterFilter' in manifest:
    data = COMMON_CHARACTER_POLICY.read_bytes()
    assert hashlib.sha256(data).hexdigest() == manifest['rareCharacterFilter']['profileSHA256']
    reject = unprotected_han_predicate(json.loads(data))
    db.create_function('has_unprotected_han', 1, reject)
    for table in ['pinyin', 'pinyin_phrases']:
        assert db.execute(f'SELECT count(*) FROM {table} WHERE has_unprotected_han(simplified) OR has_unprotected_han(traditional)').fetchone()[0] == 0
if 'glyphFilter' in manifest:
    profile = FONT_EXCLUSIONS.read_bytes()
    assert hashlib.sha256(profile).hexdigest() == manifest['glyphFilter']['profileSHA256']
    excluded = set(json.loads(profile)['characters'])
    if 'candidateFilter' in manifest:
        candidate_profile = CANDIDATE_EXCLUSIONS.read_bytes()
        assert hashlib.sha256(candidate_profile).hexdigest() == manifest['candidateFilter']['profileSHA256']
        excluded.update(json.loads(candidate_profile)['characters'])
    db.create_function('has_excluded_glyph', 1, lambda text: any(c in excluded for c in text))
    for table, columns in [('pinyin',['simplified','traditional']), ('pinyin_phrases',['simplified','traditional']),
                           ('cangjie',['text']), ('wanxiang_codes',['text'])]:
        condition = ' OR '.join(f'has_excluded_glyph({column})' for column in columns)
        assert db.execute(f'SELECT count(*) FROM {table} WHERE {condition}').fetchone()[0] == 0, table
    if args.before_glyph_cleanup:
        db.execute('ATTACH DATABASE ? AS before_cleanup', (str(args.before_glyph_cleanup / 'lexicon.sqlite'),))
        for table, columns in [('pinyin',['simplified','traditional']), ('pinyin_phrases',['simplified','traditional']),
                               ('cangjie',['text']), ('wanxiang_codes',['text']), ('english',['word'])]:
            condition = ' OR '.join(f'has_excluded_glyph({column})' for column in columns)
            if table in ['pinyin', 'pinyin_phrases'] and 'rareCharacterFilter' in manifest:
                condition += ' OR ' + ' OR '.join(f'has_unprotected_han({column})' for column in columns)
            expected = f'SELECT * FROM before_cleanup.{table} WHERE NOT ({condition})'
            actual = f'SELECT * FROM {table}'
            assert db.execute(f'{expected} EXCEPT {actual} LIMIT 1').fetchone() is None, table
            assert db.execute(f'{actual} EXCEPT {expected} LIMIT 1').fetchone() is None, table
        for path in (resources / 'RimeData').glob('*.gram'):
            assert hashlib.sha256(path.read_bytes()).digest() == hashlib.sha256(
                (args.before_glyph_cleanup / 'RimeData' / path.name).read_bytes()).digest()
        print('PASS: cleanup removed only excluded-glyph rows; supported vocabulary, weights and grammar unchanged', flush=True)
probes = []
to_traditional = OpenCC('s2t')
for category in ['zi', 'jichu', 'diming', 'duoyin', 'cuoyin', 'fangyan', 'huaxue', 'mingren', 'mixed',
                 'shici', 'taifeng', 'wuzhong', 'yaopin', 'yiren', 'yixue']:
    if f'dicts/{category}.dict.yaml' not in manifest['files']:
        continue
    available = []
    for word, reading, weight in rows(SOURCE / 'dicts' / f'{category}.dict.yaml'):
        roman = romanize(reading)
        code = roman.replace(' ', '')
        if (1 if category == 'zi' else 2) <= len(word) <= 8 and len(code) <= 36 and re.fullmatch('[a-z]+(?: [a-z]+)*', roman):
            available.append((weight, code, word))
    if not available:
        raise AssertionError(f'No eligible probe for {category}')
    _, code, word = max(available)
    probes.append(dict(code=code, simplified=word, traditional=to_traditional.convert(word), source=category))
for word, code in [('松弛感','songchigan'), ('显眼包','xianyanbao'), ('破防','pofang'),
                   ('多加冰','duojiabing'), ('煎个鸡蛋','jiangejidan'),
                   ('新能源汽车','xinnengyuanqiche'), ('北京师范大学','beijingshifandaxue')]:
    probes.append(dict(code=code, simplified=word, traditional=to_traditional.convert(word), source='modern-expression'))
if 'rareCharacterFilter' in manifest:
    for word in ['㕮', '凪', '㵲', '𬌗']:
        row = db.execute('SELECT code,traditional FROM pinyin WHERE simplified=? ORDER BY weight DESC LIMIT 1', (word,)).fetchone()
        assert row is not None, f'Protected standard/name character lost: {word}'
        probes.append(dict(code=row[0], simplified=word, traditional=row[1], source='protected-character'))
if manifest.get('storageFormat') == 'mac-auxiliary-v4':
    assert db.execute('SELECT count(*) FROM pinyin WHERE length(simplified)<>1 AND length(traditional)<>1').fetchone()[0] == 0
    assert db.execute('SELECT count(*) FROM pinyin_phrases WHERE length(code)<3 OR length(code)>13').fetchone()[0] == 0
db.close()
with tempfile.TemporaryDirectory(prefix='mac-wanxiang-tests-') as temp:
    temp = Path(temp)
    (temp / 'probes.json').write_text(json.dumps(probes, ensure_ascii=False))
    modulemap = temp / 'module.modulemap'
    modulemap.write_text('module CRimeBridge { header "' + str(ROOT / 'Sources/CRimeBridge/include/CRimeBridge.h') + '" export * }')
    executable = temp / 'WanxiangChecks'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-I', str(products),
                    '-Xcc', '-fmodule-map-file=' + str(modulemap),
                    str(ROOT / 'Tests/MacInputMethodTests/WanxiangChecks.swift'),
                    *[str(products / name) for name in ['KeyboardCore.o', 'CRimeBridge.o', 'librime.a']],
                    '-lsqlite3', '-lc++', '-o', str(executable)], check=True, timeout=120)
    subprocess.run(['/usr/bin/time', '-l', str(executable), str(resources), str(temp / 'probes.json')],
                   check=True, timeout=120)
