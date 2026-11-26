#!/usr/bin/env python3
"""Build a reproducible SQLite lexicon from attributed upstream data.

Usage: python3 scripts/build_lexicon.py --sources data/sources
Sources are downloaded by scripts/download_sources.sh, never at app runtime.
"""
import argparse
import gzip
import hashlib
import json
import math
import re
import sqlite3
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DIGITS = str.maketrans({c: str(n) for n, chars in enumerate(
    ["abc", "def", "ghi", "jkl", "mno", "pqrs", "tuv", "wxyz"], 2) for c in chars})

def cedict_pronunciations(primary, definitions):
    # Preserve the existing primary reading. Only explicit "also pr." clauses
    # describe alternate readings of this entry; other brackets may reference
    # unrelated words, classifiers, or separately qualified regional/old readings.
    roman = re.sub(r'[1-5]', '', primary.lower().replace('u:', 'v'))
    readings = [re.sub(r'\s+', ' ', roman).strip()]
    seen = {readings[0].replace(' ', '')}
    for clause in re.finditer(r'\balso pr\.\s*(\[[^\]]+\](?:\s*(?:,|or|and)\s*\[[^\]]+\])*)', definitions):
        for pronunciation in re.findall(r'\[([^\]]+)\]', clause.group(1)):
            pronunciation = pronunciation.lower().replace('u:', 'v').replace('ü', 'v').strip()
            if not re.fullmatch(r'(?:[a-z]+[1-5][\s-]*)+', pronunciation):
                continue
            # Tone numbers delimit syllables even in compact forms like jiao3se4.
            syllables = re.findall(r'([a-z]+)[1-5]', pronunciation)
            if len(syllables) != len(readings[0].split()):
                continue
            code = ''.join(syllables)
            if code not in seen:
                readings.append(' '.join(syllables))
                seen.add(code)
    return readings


def main():
    from pypinyin import lazy_pinyin, Style
    from opencc import OpenCC

    parser = argparse.ArgumentParser()
    parser.add_argument('--sources', type=Path, default=ROOT / 'data/sources')
    args = parser.parse_args()
    source = args.sources
    frequencies = {}
    for line in (source / 'jieba-dict.txt').read_text().splitlines():
        fields = line.split()
        if len(fields) >= 2:
            frequencies[fields[0]] = int(fields[1])
    entries = {}
    with gzip.open(source / 'cedict.gz', 'rt') as f:
        for line in f:
            match = re.match(r'^(\S+) (\S+) \[([^\]]+)\](.*)', line)
            if not match:
                continue
            traditional, simplified, pronunciation, definitions = match.groups()
            if not all('\u3400' <= c <= '\u9fff' for c in simplified + traditional):
                continue
            for roman in cedict_pronunciations(pronunciation, definitions):
                code = roman.replace(' ', '')
                if not re.fullmatch('[a-zv]+', code) or len(code) > 48:
                    continue
                weight = frequencies.get(simplified, 2)
                key = (code, simplified, traditional)
                entries[key] = (code, code.translate(DIGITS), roman, simplified, traditional, weight)
    # Original first-party prioritisation of common conversational expressions.
    boosts = {'你好': 250000, '谢谢': 220000, '再见': 180000, '我们': 240000,
              '苹果': 120000, '中国': 200000, '学习': 150000, '输入法': 100000,
              '西班牙语': 80000, '中文': 100000, '可以': 200000}
    converter = OpenCC('s2t')
    thuocl_count = 0
    for path in sorted((source / 'thuocl').glob('THUOCL_*.txt')):
        # The place-name file uses CR rather than LF. splitlines handles both.
        for line in path.read_text(encoding='utf-8-sig').splitlines():
            fields = line.split('\t')
            if len(fields) != 2:
                continue
            simplified, count = fields
            if not 2 <= len(simplified) <= 12 or not all('\u3400' <= c <= '\u9fff' for c in simplified):
                continue
            try:
                frequency = int(count)
            except ValueError:
                continue
            syllables = lazy_pinyin(simplified, style=Style.NORMAL, errors='default')
            roman = ' '.join(syllables).lower().replace('ü', 'v')
            code = roman.replace(' ', '')
            if not re.fullmatch('[a-zv]+', code) or len(code) > 48:
                continue
            traditional = converter.convert(simplified)
            # DF values come from unlike corpora and are not comparable to jieba
            # token counts. Keep domain-only words below established common words.
            weight = max(frequencies.get(simplified, 2), min(120, int(math.log1p(frequency) * 12)))
            key = (code, simplified, traditional)
            old = entries.get(key)
            entries[key] = (code, code.translate(DIGITS), roman, simplified,
                            traditional, max(weight, old[-1] if old else 0))
            thuocl_count += 1
    # Original project entry for a common spoken phrase absent from the source dictionaries.
    simplified, traditional, roman = '不早说', '不早說', 'bu zao shuo'
    code = roman.replace(' ', '')
    entries.setdefault((code, simplified, traditional),
                       (code, code.translate(DIGITS), roman, simplified, traditional, 120))
    entries = [row[:-1] + (max(row[-1], boosts.get(row[3], 0)),) for row in entries.values()]
    english = {}
    for part in ('adj', 'adv', 'noun', 'verb'):
        for line in (source / 'wordnet/dict' / f'index.{part}').read_text().splitlines():
            if line.startswith(' ') or not line.strip():
                continue
            fields = line.split()
            word = fields[0].lower()
            if not re.fullmatch('[a-z]{2,32}', word):
                continue
            # WordNet index tag counts are a modest ranking hint, not corpus frequency.
            pointer_count = int(fields[3])
            tag_count = int(fields[4 + pointer_count + 1])
            english[word] = max(english.get(word, 0), tag_count)
    cangjie = []
    for line in (source / 'cangjie5.base.dict.yaml').read_text().splitlines():
        fields = line.split('\t')
        if len(fields) >= 2 and re.fullmatch('[a-z]{1,5}', fields[1]):
            word, code = fields[:2]
            if len(word) == 1:
                cangjie.append((code, word, frequencies.get(word, 2)))
    assert len(entries) > 80000, f'Unexpected pinyin source size: {len(entries)}'
    assert len(cangjie) > 10000, f'Unexpected Cangjie source size: {len(cangjie)}'
    output = ROOT / 'Resources/lexicon.sqlite'
    output.parent.mkdir(parents=True, exist_ok=True)
    output.unlink(missing_ok=True)
    db = sqlite3.connect(output)
    db.executescript('''
        PRAGMA page_size=4096;
        CREATE TABLE pinyin(code TEXT NOT NULL, digits TEXT NOT NULL, roman TEXT NOT NULL,
          simplified TEXT NOT NULL, traditional TEXT NOT NULL, weight INTEGER NOT NULL);
        CREATE TABLE cangjie(code TEXT NOT NULL, text TEXT NOT NULL, weight INTEGER NOT NULL);
        CREATE TABLE english(word TEXT PRIMARY KEY, weight INTEGER NOT NULL);
    ''')
    db.executemany('INSERT INTO pinyin VALUES (?,?,?,?,?,?)', sorted(entries))
    db.executemany('INSERT INTO cangjie VALUES (?,?,?)', sorted(cangjie))
    db.executemany('INSERT INTO english VALUES (?,?)', sorted(english.items()))
    db.executescript('''
        CREATE INDEX pinyin_code ON pinyin(code, weight DESC);
        CREATE INDEX pinyin_digits ON pinyin(digits, weight DESC);
        CREATE INDEX cangjie_code ON cangjie(code, weight DESC);
        PRAGMA user_version=2;
    ''')
    db.commit()
    assert db.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
    db.execute('VACUUM')
    db.close()
    manifest = {'pinyinEntries': len(entries), 'thuoclAcceptedRows': thuocl_count,
                'englishEntries': len(english), 'cangjieEntries': len(cangjie),
                'databaseSHA256': hashlib.sha256(output.read_bytes()).hexdigest(),
                'sources': {str(p.relative_to(source)): hashlib.sha256(p.read_bytes()).hexdigest()
                            for p in sorted(source.rglob('*')) if p.is_file()}}
    (ROOT / 'Resources/lexicon-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps(manifest, indent=2))

if __name__ == '__main__':
    main()
