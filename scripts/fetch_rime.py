#!/usr/bin/env python3
"""Fetch pinned engine/model assets, checking SHA-256 before writing each file."""
import hashlib
import io
import json
from pathlib import Path
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parent.parent
manifest = json.loads((ROOT / 'scripts/rime-dependencies.json').read_text())


def verified(asset):
    with urllib.request.urlopen(asset['url'], timeout=120) as response:
        data = response.read()
    if hashlib.sha256(data).hexdigest() != asset['sha256']:
        raise ValueError(f"Checksum mismatch: {asset['url']}")
    return data


for asset in manifest['files']:
    output = ROOT / asset['path']
    if output.exists() and hashlib.sha256(output.read_bytes()).hexdigest() == asset['sha256']:
        continue
    data = verified(asset)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(data)
    print(f"Verified {output.name}")

vendor = ROOT / 'Vendor'
if not (vendor / 'librime-static.xcframework/Info.plist').exists():
    data = verified(manifest['binary'])
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        for name in archive.namelist():
            path = Path(name)
            if path.is_absolute() or '..' in path.parts:
                raise ValueError('Unsafe archive path')
        archive.extractall(vendor)
    print(f"Verified Rime {manifest['version']}")
