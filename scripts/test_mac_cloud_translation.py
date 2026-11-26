#!/usr/bin/env python3
"""Offline MacTranslator integration checks using URLProtocol, never a real key.

Compile the current DesktopCore in a temporary directory, so no main-app build
is necessary after a client change. --legacy-source injects dependencies into a
saved pre-fix translator without changing its error handling, for red evidence.
"""
from pathlib import Path
import argparse
import hashlib
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('--products', type=Path, default=ROOT / 'artifacts/mac-debug/Build/Products/Debug')
parser.add_argument('--legacy-source', type=Path)
args = parser.parse_args()
products = args.products.resolve()
with tempfile.TemporaryDirectory(prefix='learnkeyboard-cloud-') as temp:
    directory = Path(temp)
    modulemap = directory / 'module.modulemap'
    modulemap.write_text('module CRimeBridge { header "' + str(ROOT / 'Sources/CRimeBridge/include/CRimeBridge.h') + '" export * }')
    common = ['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-module-cache-path', str(directory / 'cache'),
              '-I', str(products), '-Xcc', '-fmodule-map-file=' + str(modulemap)]
    subprocess.run(common + ['-whole-module-optimization', '-emit-object', '-emit-module', '-module-name', 'DesktopCore',
        '-emit-module-path', str(directory / 'DesktopCore.swiftmodule'),
        *map(str, sorted((ROOT / 'Sources/DesktopCore').glob('*.swift'))), '-o', str(directory / 'DesktopCore.o')],
        check=True, timeout=120)
    translator = ROOT / 'Mac/Shared/MacTranslator.swift'
    defines = []
    if args.legacy_source:
        original = args.legacy_source.read_text()
        print('Legacy translator SHA-256:', hashlib.sha256(original.encode()).hexdigest(), flush=True)
        replacements = [
            ('private let cloud = SiliconFlowClient()', 'private let cloud: SiliconFlowClient\n    private let keyProvider: @MainActor () throws -> String?'),
            ('init(learnedURL: URL? = DesktopSettingsStore.learnedURL) {\n        self.learnedURL = learnedURL\n    }',
             'init(learnedURL: URL? = DesktopSettingsStore.learnedURL, cloud: SiliconFlowClient = SiliconFlowClient(), keyProvider: @escaping @MainActor () throws -> String? = { try MacKeychain.load() }) {\n        self.learnedURL = learnedURL\n        self.cloud = cloud\n        self.keyProvider = keyProvider\n    }'),
            ('try MacKeychain.load(),', 'try keyProvider(),'),
        ]
        for before, after in replacements:
            if original.count(before) != 1:
                raise ValueError('Legacy source does not match the expected pre-fix dependency seam')
            original = original.replace(before, after)
        translator = directory / 'LegacyMacTranslator.swift'
        translator.write_text(original)
        defines = ['-DLEGACY_TRANSLATOR']
    executable = directory / 'CloudTranslationChecks'
    command = common[:]
    # Prefer the freshly compiled DesktopCore interface over prior app products.
    command[command.index('-I') + 1:command.index('-I') + 1] = [str(directory), '-I']
    command += defines + ['-module-name', 'CloudTranslationChecks', str(translator), str(ROOT / 'Shared/TranslationService.swift'),
        str(ROOT / 'Tests/MacInputMethodTests/CloudTranslationChecks.swift'), str(directory / 'DesktopCore.o'),
        *[str(products / name) for name in ['KeyboardCore.o', 'CRimeBridge.o', 'librime.a']], '-lsqlite3', '-lc++', '-o', str(executable)]
    subprocess.run(command, check=True, timeout=120)
    subprocess.run([str(executable)], check=True, timeout=45)
