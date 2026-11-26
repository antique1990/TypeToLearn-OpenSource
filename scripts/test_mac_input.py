#!/usr/bin/env python3
"""Native controller checks: real Rime, isolated IMKTextInput test client, no simulator.

Build LearnKeyboardMac Debug first. This is controller integration coverage;
actual host application interaction still requires physical-Mac validation.
"""
from pathlib import Path
import subprocess
import tempfile
import plistlib
import argparse

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('--products', type=Path, default=ROOT / 'artifacts/mac-debug/Build/Products/Debug')
parser.add_argument('--visual-output', type=Path)
args = parser.parse_args()
products = args.products.resolve()
with tempfile.TemporaryDirectory(prefix='learnkeyboard-controller-') as temp:
    app = Path(temp) / 'ControllerChecks.app/Contents'
    (app / 'MacOS').mkdir(parents=True)
    (app / 'Resources').mkdir()
    info = {'CFBundleIdentifier': 'com.learnkeyboard.controllerchecks', 'CFBundleExecutable': 'ControllerChecks', 'CFBundlePackageType': 'APPL', 'InputMethodServerControllerClass': 'TypeToLearnInputController', 'InputMethodConnectionName': 'com.learnkeyboard.controllerchecks_Connection', 'LSBackgroundOnly': True}
    (app / 'Info.plist').write_bytes(plistlib.dumps(info))
    modulemap = Path(temp) / 'module.modulemap'
    modulemap.write_text('module CRimeBridge { header "' + str(ROOT / 'Sources/CRimeBridge/include/CRimeBridge.h') + '" export * }')
    (app / 'Resources/DictionaryResources').symlink_to(ROOT / 'Mac/DictionaryResources')
    for resource in ['emoji-catalog.json']:
        (app / 'Resources' / resource).symlink_to(ROOT / 'Resources' / resource)
    for resource in (ROOT / 'Mac/InputMethod/Resources').glob('*.json'):
        (app / 'Resources' / resource.name).symlink_to(resource)
    sources = [*sorted(path for path in (ROOT / 'Mac/InputMethod').glob('*.swift') if path.name != 'main.swift'),
               *sorted((ROOT / 'Mac/Shared').glob('*.swift')), ROOT / 'Shared/TranslationService.swift',
               ROOT / ('Tests/MacInputMethodTests/VisualChecks.swift' if args.visual_output else 'Tests/MacInputMethodTests/ControllerChecks.swift')]
    command = ['xcrun', 'swiftc', '-swift-version', '5', '-DDEBUG', '-parse-as-library', '-I', str(products),
               '-Xcc', '-fmodule-map-file=' + str(modulemap), '-module-name', 'ControllerChecks',
               *map(str, sources), *[str(products / name) for name in ['DesktopCore.o', 'KeyboardCore.o', 'CRimeBridge.o', 'librime.a']],
               '-lsqlite3', '-lc++', '-o', str(app / 'MacOS/ControllerChecks')]
    subprocess.run(command, check=True, timeout=120)
    subprocess.run([str(app / 'MacOS/ControllerChecks')] + ([str(args.visual_output.resolve())] if args.visual_output else []), check=True, timeout=45)
