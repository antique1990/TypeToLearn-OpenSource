#!/usr/bin/env python3
"""Compare the compact Mac database against its full baseline, in real Rime processes."""
import argparse
import hashlib
import json
from pathlib import Path
import sqlite3
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('--before', type=Path, required=True)
parser.add_argument('--products', type=Path, default=ROOT / 'artifacts/mac-debug/Build/Products/Debug')
args = parser.parse_args()
products = args.products.resolve()
after = products / 'TypeToLearnInputMethod.app/Contents/Resources/DictionaryResources'
before = args.before.resolve()
db = sqlite3.connect(f'file:{after}/lexicon.sqlite?mode=ro', uri=True)
db.execute('ATTACH DATABASE ? AS baseline', (str(before / 'lexicon.sqlite'),))
for table in ['english', 'cangjie', 'wanxiang_codes']:
    assert db.execute(f'SELECT count(*) FROM {table}').fetchone() == db.execute(f'SELECT count(*) FROM baseline.{table}').fetchone()
    assert db.execute(f'SELECT * FROM {table} EXCEPT SELECT * FROM baseline.{table} LIMIT 1').fetchone() is None, table
assert db.execute('''SELECT code,simplified,traditional,weight FROM baseline.pinyin
    WHERE length(code) BETWEEN 3 AND 13 AND (length(simplified)>1 OR length(traditional)>1)
    EXCEPT SELECT code,simplified,COALESCE(NULLIF(traditional,''),simplified),weight FROM pinyin_phrases LIMIT 1''').fetchone() is None
assert db.execute('''SELECT * FROM baseline.pinyin WHERE length(simplified)=1 OR length(traditional)=1
    EXCEPT SELECT * FROM pinyin LIMIT 1''').fetchone() is None
db.close()
saved_hashes = before / 'rime-before-hashes.json'
hashes = json.loads(saved_hashes.read_text()) if saved_hashes.exists() else {
    str(path.relative_to(before)): hashlib.sha256(path.read_bytes()).hexdigest()
    for path in (before / 'RimeData').rglob('*') if path.is_file()}
for name, expected in hashes.items():
    assert hashlib.sha256((after / name).read_bytes()).hexdigest() == expected, name
with tempfile.TemporaryDirectory(prefix='mac-lexicon-parity-') as directory:
    directory = Path(directory)
    modulemap = directory / 'module.modulemap'
    modulemap.write_text('module CRimeBridge { header "' + str(ROOT / 'Sources/CRimeBridge/include/CRimeBridge.h') + '" export * }')
    executable = directory / 'LexiconStorageChecks'
    subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-I',str(products),
                    '-Xcc','-fmodule-map-file=' + str(modulemap),
                    str(ROOT / 'Tests/MacInputMethodTests/LexiconStorageChecks.swift'),
                    *[str(products / name) for name in ['KeyboardCore.o','CRimeBridge.o','librime.a']],
                    '-lsqlite3','-lc++','-o',str(executable)], check=True, timeout=120)
    for name, resources in [('before', before), ('after', after)]:
        subprocess.run([str(executable), str(resources), str(directory / f'{name}.json')], check=True, timeout=120)
    original = json.loads((directory / 'before.json').read_text())
    compact = json.loads((directory / 'after.json').read_text())
    different = [key for key in original if original[key] != compact.get(key)]
    if different:
        for key in different[:6]:
            print('DIFFERENCE', key, json.dumps({'before':original[key],'after':compact.get(key)},ensure_ascii=False)[:2500])
        raise AssertionError(f'{len(different)} lookup/selection snapshots changed')
    print(f'PASS: {len(original)} native results unchanged; SQL projections and all Rime resources verified')
