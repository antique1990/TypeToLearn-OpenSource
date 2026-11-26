#!/usr/bin/env python3
"""Compile the pinned Rime Ice Pinyin data for the Mac input method."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import sqlite3
import tarfile
import tempfile
import urllib.request

from opencc import OpenCC

from build_mac_wanxiang import (
    DIGITS, apply_candidate_exclusions, apply_common_character_policy,
    apply_font_exclusions, compact_database, compile_rime, romanize, rows,
)
from fetch_mac_wanxiang import LOCK as WANXIANG_LOCK, ROOT, SOURCE as WANXIANG_SOURCE, fetch, valid
from tatoeba_weights import TATOEBA_NOTICE, apply_tatoeba_weights


REPOSITORY = 'https://github.com/iDvel/rime-ice'
REVISION = '927e1cf1d3eeb9bf4be85e3f684dba4dd485b6f6'
FILES = {
    'cn_dicts/8105.dict.yaml': '1f9a42b91dea6982baee2551981780271aeffd78876662b9c9f324e56b37b120',
    'cn_dicts/base.dict.yaml': 'c1f07daa4680a437a04169211e4a80b19923fd61cff322753d3ee98a7e1bffc8',
    'cn_dicts/ext.dict.yaml': 'f713d82f5a3c38bf955fef631353c6bd08c3e1ae6674d7db0c4f286480d760a1',
    'cn_dicts/others.dict.yaml': 'c7475d773e619f61b88d47fa8ec789aba02aa0d1c98edaed309e53487b048b32',
    'LICENSE': '3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986',
}
ENGLISH_FILES = ('dicts/en.dict.yaml', 'LICENSE', 'LICENSE-SCOPE.md', 'NOTICE.md')
OUTPUT = ROOT / 'Mac/DictionaryResources'
BASE = ROOT / 'Resources/lexicon.sqlite'
MANIFEST = 'rime-ice-manifest.json'
PINYIN = re.compile(r'[a-z]+(?: [a-z]+)*')
# Keep explicit dictionary evidence for previously supported Mac corrections.
MAC_PHRASES = (
    ('中文词汇', '中文詞彙', 'zhong wen ci hui'),
    ('简单来说', '簡單來說', 'jian dan lai shuo'),
)


def extract_sources(archive, sources):
    if archive is None:
        archive = sources / 'source.tar.gz'
        url = f'https://codeload.github.com/iDvel/rime-ice/tar.gz/{REVISION}'
        with urllib.request.urlopen(url, timeout=120) as response, archive.open('wb') as stream:
            shutil.copyfileobj(response, stream)
    with tarfile.open(archive, 'r:gz') as tar:
        for member in tar:
            name = member.name.partition('/')[2]
            if name not in FILES or not member.isfile():
                continue
            with tar.extractfile(member) as stream:
                data = stream.read()
            if hashlib.sha256(data).hexdigest() != FILES[name]:
                raise ValueError(f'Checksum mismatch for Rime Ice {name}')
            path = sources / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
    missing = [name for name in FILES if not (sources / name).is_file()]
    if missing:
        raise ValueError(f'Rime Ice source archive is missing {", ".join(missing)}')


def import_dictionary(db, source, to_traditional):
    stats = dict(imported=0, skippedUnannotated=0, skippedUnsupported=0)
    batch = []
    with source.open(encoding='utf-8-sig') as stream:
        for line in stream:
            if line.strip() == '...':
                break
        for line in stream:
            if not line.strip() or line.lstrip().startswith('#'):
                continue
            fields = line.rstrip('\r\n').split('\t')
            if len(fields) < 2 or not fields[1].strip():
                stats['skippedUnannotated'] += 1
                continue
            text, reading = fields[:2]
            roman = romanize(reading)
            code = roman.replace(' ', '')
            if not text or len(code) > 256 or not PINYIN.fullmatch(roman):
                stats['skippedUnsupported'] += 1
                continue
            weight = fields[2].split('#')[0].strip() if len(fields) > 2 else ''
            batch.append((code, code.translate(DIGITS), roman, text, to_traditional.convert(text),
                          max(1, int(weight)) if weight else 1))
            stats['imported'] += 1
            if len(batch) >= 5000:
                db.executemany('INSERT OR IGNORE INTO ice_pinyin VALUES (?,?,?,?,?,?)', batch)
                batch.clear()
    db.executemany('INSERT OR IGNORE INTO ice_pinyin VALUES (?,?,?,?,?,?)', batch)
    db.commit()
    return stats


def build_database(destination, sources):
    shutil.copy2(BASE, destination)
    for name in ENGLISH_FILES:
        entry = next(file for file in WANXIANG_LOCK['files'] if file['path'] == name)
        path = WANXIANG_SOURCE / name
        if not path.exists() or not valid(path.read_bytes(), entry):
            fetch(entry)
    stats = {}
    with sqlite3.connect(destination) as db:
        db.executescript('''
            PRAGMA journal_mode=OFF;
            PRAGMA synchronous=OFF;
            CREATE TABLE ice_pinyin(code TEXT NOT NULL, digits TEXT NOT NULL, roman TEXT NOT NULL,
                simplified TEXT NOT NULL, traditional TEXT NOT NULL, weight INTEGER NOT NULL,
                PRIMARY KEY(code,simplified,traditional)) WITHOUT ROWID;
        ''')
        converter = OpenCC('s2t')
        for name, sha256 in FILES.items():
            if name.endswith('.dict.yaml'):
                stats[name] = import_dictionary(db, sources / name, converter) | {'sha256': sha256}
                print(f'Imported {name}: {stats[name]}', flush=True)
        fallback = db.execute('''
            INSERT OR IGNORE INTO ice_pinyin
                SELECT code,digits,roman,simplified,traditional,1 FROM pinyin
        ''').rowcount
        for simplified, traditional, roman in MAC_PHRASES:
            code = roman.replace(' ', '')
            db.execute('INSERT OR IGNORE INTO ice_pinyin VALUES (?,?,?,?,?,?)',
                       (code, code.translate(DIGITS), roman, simplified, traditional, 120))
        db.execute('DELETE FROM pinyin')
        db.execute('INSERT INTO pinyin SELECT * FROM ice_pinyin')
        db.execute('DROP TABLE ice_pinyin')
        db.execute('CREATE INDEX IF NOT EXISTS pinyin_single_hans ON pinyin(code,weight DESC) WHERE length(simplified)=1')
        db.execute('CREATE INDEX IF NOT EXISTS pinyin_single_hant ON pinyin(code,weight DESC) WHERE length(traditional)=1')
        db.executemany('''
            INSERT INTO english VALUES (?,?)
                ON CONFLICT(word) DO UPDATE SET weight=MAX(weight,excluded.weight)
        ''', ((text.lower(), weight) for text, _, weight in rows(WANXIANG_SOURCE / ENGLISH_FILES[0])
              if re.fullmatch('[a-z]{2,32}', text.lower())))
    return stats, fallback


def build_resources(sources, built, staging, tatoeba_archive=None):
    built.mkdir()
    database = built / 'lexicon.sqlite'
    stats, fallback = build_database(database, sources)
    filters = dict(glyphFilter=apply_font_exclusions(database, pinyin_only=True),
                   candidateFilter=apply_candidate_exclusions(database, pinyin_only=True),
                   rareCharacterFilter=apply_common_character_policy(database))
    with sqlite3.connect(database) as db:
        compiled_count = db.execute('SELECT count(*) FROM pinyin').fetchone()[0]
        tatoeba = apply_tatoeba_weights(db, tatoeba_archive) if tatoeba_archive else None
    dictionary_version = f'rime-ice-{REVISION[:12]}'
    if tatoeba:
        dictionary_version += f'-tatoeba-{tatoeba["sha256"][:8]}'
        (built / 'TATOEBA-NOTICE.txt').write_text(TATOEBA_NOTICE, encoding='utf-8')
        print(f'{tatoeba["adjustedRows"]} rows adjusted with Tatoeba frequency evidence', flush=True)
    print('Compiling native Mac Rime dictionaries...', flush=True)
    compile_rime(database, built / 'RimeData', staging=staging,
                 dictionary_version=dictionary_version, config_version='rime-ice-1')
    with sqlite3.connect(database) as db:
        long_phrases = [row for simplified, _, roman in MAC_PHRASES if len(roman.replace(' ', '')) > 13
                        for row in db.execute('SELECT code,simplified,traditional,weight FROM pinyin WHERE roman=? AND simplified=?',
                                              (roman, simplified))]
    counts = compact_database(database, auxiliary_tables=())
    with sqlite3.connect(database) as db:
        db.executemany('INSERT INTO pinyin_phrases VALUES (?,?,?,?)', long_phrases)
        counts['pinyin_phrases'] += len(long_phrases)
    shutil.copy2(sources / 'LICENSE', built / 'rime-ice-LICENSE')
    for name in ENGLISH_FILES[1:]:
        shutil.copy2(WANXIANG_SOURCE / name, built / f'wanxiang-english-{name}')
    shutil.copy2(ROOT / 'Resources/Licenses/UNICODE-3.0.txt', built / 'character-policy-UNICODE-3.0.txt')
    (built / 'RIME-ICE-NOTICE.txt').write_text(
        f'雾凇拼音 / Rime Ice by iDvel and contributors\n{REPOSITORY}\n'
        f'Pinned revision: {REVISION}\n'
        f'Upstream license: GPL-3.0-only. See rime-ice-LICENSE and the pinned source file headers.\n'
        'Modified by LearnKeyboard: extracted explicit Pinyin entries from 8105, base, ext and others, '
        'paired simplified and traditional forms with OpenCC, removed excluded glyphs and applied '
        'the Mac character retention policy, deduplicated entries, indexed short codes and compiled '
        'with the app’s existing Rime schemas. The original supplemental vocabulary retains its '
        'source notices. English supplements: Wanxiang data by amzxyz and contributors (CC BY 4.0). '
        'See wanxiang-english-LICENSE and companion notices. Character retention data: Unicode '
        'Unihan 17.0, distributed under Unicode License V3.\n', encoding='utf-8')
    report = dict(repository=REPOSITORY, commit=REVISION, license='GPL-3.0-only',
                  files=stats, baselineFallbackRows=fallback, compiledPinyinRows=compiled_count,
                  macSupplementalPhrases=[word for word, _, _ in MAC_PHRASES],
                  omittedTables=['cn_dicts/tencent.dict.yaml', 'cn_dicts/41448.dict.yaml'],
                  englishSupplementCommit=WANXIANG_LOCK['commit'],
                  storageFormat='mac-auxiliary-v4', counts=counts,
                  databaseSHA256=hashlib.sha256(database.read_bytes()).hexdigest(), **filters)
    if tatoeba:
        report['tatoeba'] = tatoeba
    (built / MANIFEST).write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n',
                                encoding='utf-8')
    print(json.dumps(counts), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path, help='Use a local archive of the pinned revision')
    parser.add_argument('--tatoeba', type=Path, help='Use the Mandarin export shared with the iPhone build')
    parser.add_argument('--output', type=Path, default=OUTPUT, help='Output resource directory')
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists() and not any((output / name).is_file() for name in (MANIFEST, 'wanxiang-manifest.json')):
        parser.error(f'Existing output is not a generated Mac dictionary: {output}')
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='rime-ice-build-', dir=output.parent) as tmp:
        work = Path(tmp)
        sources = work / 'upstream'
        sources.mkdir()
        extract_sources(args.archive, sources)
        built = work / 'resources'
        build_resources(sources, built, work / 'rime', args.tatoeba)
        backup = work / 'previous'
        if output.exists():
            output.rename(backup)
        try:
            built.rename(output)
        except OSError:
            if backup.exists():
                backup.rename(output)
            raise


if __name__ == '__main__':
    main()
