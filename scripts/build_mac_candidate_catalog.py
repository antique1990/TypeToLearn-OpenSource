#!/usr/bin/env python3
"""Generate Mac-only metadata from pinned, checksummed public data.

Download into ignored data/sources/mac-candidates with --download. Subsequent
runs are offline. Output remains editable JSON; no proprietary system database.
"""
from pathlib import Path
import argparse
import hashlib
import itertools
import json
import re
import shutil
import sqlite3
import subprocess
import tempfile
import urllib.request
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / 'data/sources/mac-candidates'
OUTPUT = ROOT / 'Mac/InputMethod/Resources'
CJK_REVISION = 'c29b391fd6267e7a3541387e03a3dd60b1cd34d1'
CLDR_REVISION = 'acd6d88ae493633240e19a87a721076a8a75c310'
URLS = {
    'Unihan.zip': 'https://www.unicode.org/Public/17.0.0/ucd/Unihan.zip',
    'CJKRadicals.txt': 'https://www.unicode.org/Public/17.0.0/ucd/CJKRadicals.txt',
    **{name: f'https://raw.githubusercontent.com/amake/cjk-decomp/{CJK_REVISION}/{remote}'
       for name, remote in [('cjk-decomp.txt', 'cjk-decomp.txt'), ('cjk-LICENSE', 'LICENSE'), ('cjk-README.md', 'README.md')]},
    **{f'{lang}.xml': f'https://raw.githubusercontent.com/unicode-org/cldr/{CLDR_REVISION}/common/annotations/{lang}.xml'
       for lang in ['zh', 'en']},
}


def dump(name, data):
    (OUTPUT / name).write_text(json.dumps(data, ensure_ascii=False, separators=(',', ':'), sort_keys=True) + '\n')


def metadata():
    connection = sqlite3.connect(ROOT / 'Resources/lexicon.sqlite')
    used = set()
    for query in ['SELECT simplified, traditional FROM pinyin', 'SELECT text FROM cangjie']:
        for row in connection.execute(query):
            for word in row:
                used.update(word)
    radicals = {}
    for line in (SOURCE / 'CJKRadicals.txt').read_text().splitlines():
        if not line or line.startswith('#'):
            continue
        number, radical, unified = map(str.strip, line.split(';'))
        radicals[number] = chr(int(unified, 16))
    output = {}
    with zipfile.ZipFile(SOURCE / 'Unihan.zip') as archive:
        for line in archive.read('Unihan_IRGSources.txt').decode().splitlines():
            if not line or line.startswith('#'):
                continue
            code, field, value = line.split('\t')
            char = chr(int(code[2:], 16))
            if char not in used or field not in ('kRSUnicode', 'kTotalStrokes'):
                continue
            row = output.setdefault(char, {})
            if field == 'kTotalStrokes':
                row['strokes'] = int(value.split()[0])
            else:
                number = value.split()[0].split('.')[0]
                row['radicalNumber'] = int(number.rstrip("'"))
                row['radical'] = radicals.get(number, radicals.get(number.rstrip("'")))
    decompositions = {}
    for line in (SOURCE / 'cjk-decomp.txt').read_text().splitlines():
        match = re.fullmatch(r'([^:]+):([^()]+)\(([^()]*)\)', line)
        if match:
            char, kind, parts = match.groups()
            parts = parts.split(',') if parts else []
            # Explicit repeat operators in the upstream format describe real
            # repeated components, e.g. 喆:ra(吉), 森:r3tr(木).
            repeat = {'ra': 2, 'rd': 2, 'r3a': 3, 'r3d': 3, 'r3tr': 3, 'r4sq': 4}.get(kind.split('/')[0])
            if len(parts) == 1 and repeat:
                parts *= repeat
            decompositions[char] = (kind, parts)

    def components(token, ancestors=frozenset()):
        if not token.isascii() or not token.isdigit():
            return token
        if token in ancestors or token not in decompositions:
            return None
        kind, parts = decompositions[token]
        # Modified forms and unencoded primitives have no exact printable glyph.
        if len(parts) < 2:
            return None
        values = [components(part, ancestors | {token}) for part in parts]
        return '(' + ' + '.join(values) + ')' if all(values) else None

    for char, row in output.items():
        kind, parts = decompositions.get(char, ('', []))
        if len(parts) < 2:
            continue
        values = [components(part) for part in parts]
        if all(values):
            row['decomposition'] = ' + '.join(values)
    dump('character-metadata.json', output)
    print('Character metadata:', len(output), 'decompositions:', sum('decomposition' in value for value in output.values()))
    readings = {}
    for code, simplified, traditional in connection.execute(
            'SELECT code, simplified, traditional FROM pinyin WHERE length(simplified) = 1 OR length(traditional) = 1 ORDER BY weight DESC'):
        if not re.fullmatch('[a-z]{1,6}', code):
            continue
        for char in {simplified, traditional}:
            if len(char) == 1 and code not in readings.setdefault(char, []):
                readings[char].append(code)
    # Named side forms have the reading of their corresponding standalone
    # component. These aliases are explicit, not guessed from codepoint order.
    aliases = {'亻': '人', '氵': '水', '扌': '手', '忄': '心', '犭': '犬', '讠': '言',
               '钅': '金', '纟': '丝', '礻': '示', '衤': '衣', '饣': '食', '刂': '刀', '艹': '草'}
    for form, character in aliases.items():
        readings.setdefault(form, readings.get(character, []))
    structural = {}
    for char, row in output.items():
        description = row.get('decomposition')
        if not description:
            continue
        parts = re.findall(r'[^\s()+]+', description)
        if not 2 <= len(parts) <= 6 or not all(readings.get(part) for part in parts):
            continue
        for pronunciations in itertools.product(*(readings[part] for part in parts)):
            key = ''.join(pronunciations)
            if char not in structural.setdefault(key, []):
                structural[key].append(char)
    dump('structural-pinyin.json', structural)
    print('Structural pinyin keys:', len(structural))


def emoji_keywords():
    categories = json.loads((ROOT / 'Resources/emoji-catalog.json').read_text())
    emojis = [text for category in categories for text in category['emojis']]
    # CLDR sometimes omits the presentation-selector used in fully-qualified emoji.
    canonical = {emoji.replace('\ufe0f', ''): emoji for emoji in emojis}
    names = {}
    keywords = {}
    def add(key, emoji):
        normalized = ''.join(key.lower().split()).replace("'", '')
        if normalized and emoji not in keywords.setdefault(normalized, []):
            keywords[normalized].append(emoji)
    for lang in ['en', 'zh']:
        for element in ET.parse(SOURCE / f'{lang}.xml').iter('annotation'):
            emoji = canonical.get(element.get('cp', '').replace('\ufe0f', ''))
            if not emoji or not element.text:
                continue
            if element.get('type') == 'tts':
                names[emoji] = element.text
            for key in element.text.split('|'):
                add(key, emoji)
    # Everyday input aliases supplement CLDR's descriptive keywords.
    aliases = {'你好': ['👋'], '再见': ['👋'], '谢谢': ['🙏'], '开心': ['😄', '😊'], '笑': ['😄', '😂'],
               '哭': ['😭', '😢'], '哈哈': ['😂', '😆'], '爱你': ['❤️', '😘'], '生气': ['😠', '😡'],
               '生日': ['🎂', '🎉'], '蛋糕': ['🎂'], '加油': ['💪'], '好的': ['👌', '👍'], '赞': ['👍'],
               '晚安': ['🌙', '😴'], '早安': ['☀️'], '祝贺': ['🎉', '🎊'], '红包': ['🧧'], '拥抱': ['🤗']}
    for key, values in aliases.items():
        for value in values:
            if value in emojis:
                add(key, value)
    chinese = [key for key in keywords if any('\u3400' <= char <= '\u9fff' for char in key)]
    # Foundation's public Mandarin transliteration avoids maintaining a second
    # reading dictionary and runs only at generation time, never on each keystroke.
    swift = '''import Foundation
let words = try JSONDecoder().decode([String].self, from: FileHandle.standardInput.readDataToEndOfFile())
let values = words.map { word in (word.applyingTransform(.toLatin, reverse: false) ?? word)
    .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    .filter { !$0.isWhitespace } }
FileHandle.standardOutput.write(try JSONEncoder().encode(values))
'''
    with tempfile.TemporaryDirectory(prefix='mac-emoji-pinyin-') as temp:
        source = Path(temp) / 'main.swift'
        source.write_text(swift)
        result = subprocess.run(['xcrun', 'swift', '-module-cache-path', temp + '/cache', str(source)],
                                input=json.dumps(chinese).encode(), stdout=subprocess.PIPE, check=True)
    for key, pinyin in zip(chinese, json.loads(result.stdout)):
        for emoji in list(keywords[key]):
            add(pinyin, emoji)
    dump('emoji-keywords.json', {'names': names, 'keywords': keywords})
    print('Emoji names:', len(names), 'keyword/pinyin keys:', len(keywords))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--download', action='store_true')
    args = parser.parse_args()
    SOURCE.mkdir(parents=True, exist_ok=True)
    OUTPUT.mkdir(parents=True, exist_ok=True)
    if args.download:
        for name, url in URLS.items():
            (SOURCE / name).write_bytes(urllib.request.urlopen(url, timeout=90).read())
    manifest_file = OUTPUT / 'candidate-data-sources.json'
    files = {name: {'url': url, 'sha256': hashlib.sha256((SOURCE / name).read_bytes()).hexdigest()} for name, url in URLS.items()}
    if manifest_file.exists():
        previous = json.loads(manifest_file.read_text())
        if previous['sources'] != files:
            raise ValueError('Pinned source checksum mismatch; review upstream changes before regeneration.')
    metadata()
    emoji_keywords()
    dump('candidate-data-sources.json', {'generatedOn': '2026-10-29', 'unicodeVersion': '17.0.0', 'cldrVersion': '48',
                                      'cjkRevision': CJK_REVISION, 'sources': files})
    shutil.copyfile(SOURCE / 'cjk-LICENSE', OUTPUT / 'cjk-decomp-APACHE-2.0.txt')
    shutil.copyfile(ROOT / 'Resources/Licenses/UNICODE-3.0.txt', OUTPUT / 'candidate-UNICODE-3.0.txt')


if __name__ == '__main__':
    main()
