#!/usr/bin/env python3
"""Verify a packaged or staged Mac Rime Ice dictionary using native macOS."""

import argparse
import hashlib
import json
import sqlite3
import subprocess
import tempfile
from contextlib import closing
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


def verify_manifest(resources):
    manifest = json.loads((resources / 'rime-ice-manifest.json').read_text())
    database = resources / 'lexicon.sqlite'
    with database.open('rb') as stream:
        digest = hashlib.sha256()
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    if digest.hexdigest() != manifest['databaseSHA256']:
        raise ValueError('SQLite checksum differs from the Rime Ice manifest')

    with closing(sqlite3.connect(f'{database.as_uri()}?mode=ro', uri=True)) as db:
        if db.execute('PRAGMA integrity_check').fetchall() != [('ok',)]:
            raise ValueError('Rime Ice SQLite integrity check failed')
        for table in ('pinyin', 'pinyin_phrases', 'english', 'cangjie'):
            actual = db.execute(f'SELECT count(*) FROM {table}').fetchone()[0]
            if actual != manifest['counts'][table]:
                raise ValueError(f'{table} has {actual} rows, expected {manifest["counts"][table]}')
    print('PASS: Rime Ice SQLite checksum, integrity and table counts', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--products', type=Path, default=ROOT / 'artifacts/mac-debug/Build/Products/Debug')
    parser.add_argument('--resources', type=Path, help='Use a staged resource directory instead of the built bundle')
    args = parser.parse_args()
    products = args.products.resolve()
    resources = (args.resources or products / 'TypeToLearnInputMethod.app/Contents/Resources/DictionaryResources').resolve()
    verify_manifest(resources)

    with tempfile.TemporaryDirectory(prefix='mac-rime-ice-checks-') as directory:
        temporary = Path(directory)
        modulemap = temporary / 'module.modulemap'
        header = ROOT / 'Sources/CRimeBridge/include/CRimeBridge.h'
        modulemap.write_text(f'module CRimeBridge {{ header "{header}" export * }}')
        executable = temporary / 'RimeIceChecks'
        subprocess.run([
            'xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-I', str(products),
            '-module-cache-path', str(temporary / 'module-cache'),
            '-Xcc', f'-fmodule-map-file={modulemap}',
            str(ROOT / 'Tests/MacInputMethodTests/RimeIceChecks.swift'),
            *[str(products / filename) for filename in ('KeyboardCore.o', 'CRimeBridge.o', 'librime.a')],
            '-lsqlite3', '-lc++', '-o', str(executable),
        ], check=True, timeout=120)
        subprocess.run([str(executable), str(resources)], check=True, timeout=90)


if __name__ == '__main__':
    main()
