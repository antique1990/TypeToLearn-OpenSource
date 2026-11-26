#!/usr/bin/env python3
"""Native Mac recovery tests with the captured Apple error and controlled resources."""
from pathlib import Path
import argparse
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('--products', type=Path, default=ROOT / 'artifacts/mac-debug/Build/Products/Debug')
parser.add_argument('--translator-source', type=Path, default=ROOT / 'Mac/Shared/MacTranslator.swift')
args = parser.parse_args()
products = args.products.resolve()
with tempfile.TemporaryDirectory(prefix='learnkeyboard-local-recovery-') as temporary:
    temp = Path(temporary)
    modulemap = temp / 'module.modulemap'
    modulemap.write_text('module CRimeBridge { header "' + str(ROOT / 'Sources/CRimeBridge/include/CRimeBridge.h') + '" export * }')
    executable = temp / 'LocalTranslationRecoveryChecks'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', '-I', str(products),
                    '-Xcc', '-fmodule-map-file=' + str(modulemap), str(args.translator_source.resolve()),
                    str(ROOT / 'Shared/TranslationService.swift'),
                    str(ROOT / 'Tests/MacInputMethodTests/LocalTranslationRecoveryChecks.swift'),
                    *[str(products / name) for name in ['DesktopCore.o', 'KeyboardCore.o', 'CRimeBridge.o', 'librime.a']],
                    '-lsqlite3', '-lc++', '-o', str(executable)], check=True, timeout=120)
    subprocess.run([str(executable)], check=True, timeout=30)
