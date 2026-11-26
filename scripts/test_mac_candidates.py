#!/usr/bin/env python3
"""Native Mac mixed-candidate lookup checks, with real NSSpellChecker and Rime.

Requires an existing LearnKeyboardMac Debug build. Never runs a simulator.
"""
from pathlib import Path
import argparse
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('--products', type=Path, default=ROOT / 'artifacts/mac-debug/Build/Products/Debug')
parser.add_argument('--resources', type=Path, default=ROOT / 'Mac/DictionaryResources')
parser.add_argument('--lookup-source', type=Path, default=ROOT / 'Mac/Shared/MacCandidateLookup.swift')
args = parser.parse_args()
products = args.products.resolve()
with tempfile.TemporaryDirectory(prefix='learnkeyboard-mixed-') as temp:
    modulemap = Path(temp) / 'module.modulemap'
    modulemap.write_text('module CRimeBridge { header "' + str(ROOT / 'Sources/CRimeBridge/include/CRimeBridge.h') + '" export * }')
    executable = Path(temp) / 'MixedCandidateChecks'
    command = ['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-I', str(products),
               '-Xcc', '-fmodule-map-file=' + str(modulemap), '-module-name', 'MixedCandidateChecks',
               str(args.lookup_source.resolve()), str(ROOT / 'Tests/MacInputMethodTests/MixedCandidateChecks.swift'),
               *[str(products / name) for name in ['KeyboardCore.o', 'CRimeBridge.o', 'librime.a']],
               '-lsqlite3', '-lc++', '-o', str(executable)]
    subprocess.run(command, check=True, timeout=120)
    subprocess.run([str(executable), str(ROOT), str(args.resources.resolve())], check=True, timeout=90)
