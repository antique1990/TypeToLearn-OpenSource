#!/usr/bin/env python3
"""Verify the production Mac translator against installed Apple models on a physical Mac.

Build LearnKeyboardMac Debug first. Exit 2 means language downloads are required;
this script never substitutes a mock, cloud service, simulator, or emulator.
"""
from pathlib import Path
import subprocess
import tempfile
import argparse

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('--products', type=Path, default=ROOT / 'artifacts/mac-debug/Build/Products/Debug')
parser.add_argument('--idle-seconds', type=int, default=0)
args = parser.parse_args()
products = args.products.resolve()
with tempfile.TemporaryDirectory(prefix='learnkeyboard-apple-') as temporary:
    directory = Path(temporary)
    modulemap = directory / 'module.modulemap'
    modulemap.write_text('module CRimeBridge { header "' + str(ROOT / 'Sources/CRimeBridge/include/CRimeBridge.h') + '" export * }')
    executable = directory / 'AppleTranslationChecks'
    sources = [ROOT / 'Mac/Shared/MacTranslator.swift', ROOT / 'Mac/Shared/MacKeychain.swift',
               ROOT / 'Shared/TranslationService.swift', ROOT / 'Tests/MacInputMethodTests/AppleTranslationChecks.swift']
    command = ['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', '-I', str(products),
               '-Xcc', '-fmodule-map-file=' + str(modulemap), *map(str, sources),
               *[str(products / name) for name in ['DesktopCore.o', 'KeyboardCore.o', 'CRimeBridge.o', 'librime.a']],
               '-lsqlite3', '-lc++', '-o', str(executable)]
    subprocess.run(command, check=True, timeout=120)
    result = subprocess.run([str(executable)] + (['--idle-seconds', str(args.idle_seconds)] if args.idle_seconds > 0 else []),
                            timeout=max(90, args.idle_seconds + 120))
    raise SystemExit(result.returncode)
