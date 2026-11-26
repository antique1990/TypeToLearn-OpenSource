#!/usr/bin/env python3
"""Native Mac lookup latency/cancellation regression; requires a Mac Debug build."""
from pathlib import Path
import argparse
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('--products', type=Path, default=ROOT / 'artifacts/mac-debug/Build/Products/Debug')
parser.add_argument('--lookup-source', type=Path, default=ROOT / 'Mac/Shared/MacCandidateLookup.swift')
args = parser.parse_args()
products = args.products.resolve()
with tempfile.TemporaryDirectory(prefix='learnkeyboard-latency-') as temporary:
    temp = Path(temporary)
    modulemap = temp / 'module.modulemap'
    modulemap.write_text('module CRimeBridge { header "' + str(ROOT / 'Sources/CRimeBridge/include/CRimeBridge.h') + '" export * }')
    executable = temp / 'LookupLatencyChecks'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-I', str(products),
                    '-Xcc', '-fmodule-map-file=' + str(modulemap), str(args.lookup_source.resolve()),
                    str(ROOT / 'Tests/MacInputMethodTests/LookupLatencyChecks.swift'),
                    *[str(products / name) for name in ['KeyboardCore.o', 'CRimeBridge.o', 'librime.a']],
                    '-lsqlite3', '-lc++', '-o', str(executable)], check=True, timeout=120)
    subprocess.run([str(executable), str(ROOT / 'Mac/DictionaryResources')], check=True, timeout=30)
