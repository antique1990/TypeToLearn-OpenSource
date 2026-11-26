#!/usr/bin/env python3
"""Build an optional, self-contained iPhone vocabulary pack on macOS."""

import argparse
from contextlib import closing
import hashlib
import json
from pathlib import Path
import shutil
import sqlite3
import tempfile

from opencc import OpenCC

from build_mac_rime_ice import FILES, REPOSITORY, REVISION, ROOT, extract_sources, import_dictionary
from build_mac_wanxiang import compile_rime
from tatoeba_weights import TATOEBA_NOTICE, apply_tatoeba_weights


OUTPUT = ROOT / 'iOS/DictionaryResources'
BASE = ROOT / 'Resources/lexicon.sqlite'
NOTICE = 'IOS-LEXICON-NOTICE.txt'


def digest(path):
    with path.open('rb') as source:
        value = hashlib.sha256()
        for block in iter(lambda: source.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def merge_vocabulary(database, sources, tatoeba_archive):
    shutil.copyfile(BASE, database)
    reports = {}
    with closing(sqlite3.connect(database)) as db:
        db.executescript('''
            PRAGMA journal_mode=OFF;
            PRAGMA synchronous=OFF;
            CREATE TABLE ice_pinyin(code TEXT NOT NULL, digits TEXT NOT NULL, roman TEXT NOT NULL,
                simplified TEXT NOT NULL, traditional TEXT NOT NULL, weight INTEGER NOT NULL,
                PRIMARY KEY(code,simplified,traditional)) WITHOUT ROWID;
        ''')
        to_traditional = OpenCC('s2t')
        for name, sha256 in FILES.items():
            if name.endswith('.dict.yaml'):
                reports[name] = import_dictionary(db, sources / name, to_traditional) | {'sha256': sha256}
                print(f'{name}: {reports[name]["imported"]} imported', flush=True)

        # The app's existing weights and the upstream corpus counts use
        # different scales. Add new words at the usual supplement weight.
        added = db.execute('''
            INSERT INTO pinyin
                SELECT code,digits,roman,simplified,traditional,MIN(weight,120)
                FROM ice_pinyin AS ice WHERE NOT EXISTS (
                    SELECT 1 FROM pinyin AS base WHERE base.code=ice.code
                    AND base.simplified=ice.simplified AND base.traditional=ice.traditional
                )
        ''').rowcount
        db.execute('DROP TABLE ice_pinyin')
        tatoeba = apply_tatoeba_weights(db, tatoeba_archive)
        db.commit()
        db.execute('VACUUM')
        if db.execute('PRAGMA integrity_check').fetchone() != ('ok',):
            raise ValueError('The merged SQLite dictionary failed its integrity check')
        counts = {table: db.execute(f'SELECT count(*) FROM {table}').fetchone()[0]
                  for table in ('pinyin', 'english', 'cangjie')}
    return reports, added, tatoeba, counts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path, help='Local archive of the pinned Rime Ice revision')
    parser.add_argument('--tatoeba', type=Path, required=True, help='Official cmn_sentences_detailed.tsv.bz2 export')
    parser.add_argument('--output', type=Path, default=OUTPUT)
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists() and not (output / NOTICE).is_file():
        parser.error(f'Output is not a generated iPhone dictionary: {output}')
    output.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix='ios-lexicon-', dir=output.parent) as directory:
        work = Path(directory)
        sources = work / 'sources'
        sources.mkdir()
        extract_sources(args.archive, sources)
        built = work / 'built'
        built.mkdir()
        database = built / 'lexicon.sqlite'
        files, added, tatoeba, counts = merge_vocabulary(database, sources, args.tatoeba)
        print(f'{added} new Pinyin entries, {tatoeba["adjustedRows"]} rows adjusted with Tatoeba frequency evidence', flush=True)
        compile_rime(database, built / 'RimeData', staging=work / 'rime-source',
                     dictionary_version=f'ios-ice-{REVISION[:12]}', config_version='ios-ice-1', include_fuzzy=True)
        shutil.copyfile(sources / 'LICENSE', built / 'RIME-ICE-LICENSE.txt')
        (built / NOTICE).write_text(
            f'雾凇拼音 / Rime Ice · iDvel and contributors\n{REPOSITORY}/tree/{REVISION}\n'
            'GPL-3.0-only. See RIME-ICE-LICENSE.txt and upstream dictionary headers for third-party notices.\n'
            'Modified by LearnKeyboard: imported 8105, base, ext and others with explicit Pinyin, '
            'converted traditional forms, merged existing vocabulary, and compiled separate iPhone schemas.\n\n'
            + TATOEBA_NOTICE,
            encoding='utf-8')
        manifest = dict(databaseSHA256=digest(database), baselineSHA256=digest(BASE), counts=counts,
                        rimeIce=dict(repository=REPOSITORY, commit=REVISION, files=files, addedRows=added),
                        tatoeba=tatoeba)
        (built / 'lexicon-manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n',
                                                   encoding='utf-8')
        backup = work / 'previous'
        if output.exists():
            output.rename(backup)
        try:
            built.rename(output)
        except OSError:
            if backup.exists():
                backup.rename(output)
            raise
    print(output)


if __name__ == '__main__':
    main()
