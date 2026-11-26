#!/usr/bin/env python3
"""Fetch only pinned Wanxiang data and notices; verify each Git blob before use."""
import concurrent.futures
import hashlib
import json
from pathlib import Path
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
LOCK = json.loads((ROOT / 'scripts/mac-wanxiang-sources.json').read_text())
SOURCE = ROOT / 'data/wanxiang-source' / LOCK['commit']


def valid(data, entry):
    blob = b'blob ' + str(len(data)).encode() + b'\0' + data
    return len(data) == entry['size'] and hashlib.sha1(blob).hexdigest() == entry['gitBlobSHA1']


def fetch(entry):
    path = SOURCE / entry['path']
    if path.exists() and valid(path.read_bytes(), entry):
        return entry['path']
    url = f"https://raw.githubusercontent.com/amzxyz/rime-wanxiang-data/{LOCK['commit']}/{entry['path']}"
    with urllib.request.urlopen(url, timeout=120) as response:
        data = response.read()
    if not valid(data, entry):
        raise ValueError(f"Upstream checksum mismatch: {entry['path']}")
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix('.download')
    temporary.write_bytes(data)
    temporary.replace(path)
    return entry['path']


if __name__ == '__main__':
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        for name in pool.map(fetch, LOCK['files']):
            print(f'Verified {name}', flush=True)
