#!/usr/bin/env python3
"""Audit all Mac Rime characters and pin a conservative additive-character policy.

Uses verified Unicode 17 Unihan data already cached by the candidate-data builder.
Only --write-policy changes the build policy; raw dictionaries are never edited.
"""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import re
import sqlite3
import zipfile

from opencc import OpenCC
from fetch_mac_wanxiang import ROOT, SOURCE, LOCK, valid
from build_mac_wanxiang import rows


def ranges(values):
    output = []
    for value in sorted(values):
        if output and output[-1][1] + 1 == value:
            output[-1][1] = value
        else:
            output.append([value, value])
    return output


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--write-policy', action='store_true')
    args = parser.parse_args()
    output = ROOT / 'artifacts/mac-full-character-audit'
    output.mkdir(parents=True, exist_ok=True)
    (output / 'UNICODE-3.0.txt').write_bytes((ROOT / 'Resources/Licenses/UNICODE-3.0.txt').read_bytes())
    (output / 'NOTICE.txt').write_text(
        'Character classifications and English definitions derive from Unicode 17.0 Unihan.\n'
        'https://www.unicode.org/Public/17.0.0/ucd/Unihan.zip\n'
        'Copyright Unicode, Inc. Unicode License V3 is included in UNICODE-3.0.txt.\n'
        'Wanxiang data by amzxyz and contributors: https://github.com/amzxyz/rime-wanxiang-data\n'
        'Wanxiang data license: CC BY 4.0. Modifications: single-character audit, retention '
        'classification and native Apple translation results. Original sources are unchanged.\n')
    unihan = ROOT / 'data/sources/mac-candidates/Unihan.zip'
    unicode_hash = hashlib.sha256(unihan.read_bytes()).hexdigest()
    source_manifest = json.loads((ROOT / 'Mac/InputMethod/Resources/candidate-data-sources.json').read_text())
    assert unicode_hash == source_manifest['sources']['Unihan.zip']['sha256']
    standard = set()
    traditional = {}
    definitions = {}
    with zipfile.ZipFile(unihan) as archive:
        han = {int(line.split('\t')[0][2:], 16)
               for line in archive.read('Unihan_IRGSources.txt').decode().splitlines() if line.startswith('U+')}
        for line in archive.read('Unihan_OtherMappings.txt').decode().splitlines():
            if '\tkTGH\t' in line:
                cp, _, value = line.split('\t')
                assert value.startswith('2013:')
                standard.add(chr(int(cp[2:], 16)))
        for line in archive.read('Unihan_Variants.txt').decode().splitlines():
            if '\tkTraditionalVariant\t' in line:
                cp, _, value = line.split('\t')
                traditional[chr(int(cp[2:], 16))] = {chr(int(x, 16)) for x in re.findall(r'U\+([0-9A-F]+)', value)}
        for line in archive.read('Unihan_Readings.txt').decode().splitlines():
            if '\tkDefinition\t' in line:
                cp, _, value = line.split('\t')
                definitions[chr(int(cp[2:], 16))] = value
    assert len(standard) == 8105
    with sqlite3.connect(ROOT / 'Resources/lexicon.sqlite') as db:
        baseline = {c for row in db.execute('SELECT simplified,traditional FROM pinyin') for word in row for c in word}
    s2t, t2s = OpenCC('s2t'), OpenCC('t2s')
    standard_forms = set(standard)
    for c in standard:
        standard_forms.update(s2t.convert(c))
        standard_forms.update(traditional.get(c, set()))
    standard_forms.update(chr(cp) for cp in han if t2s.convert(chr(cp)) in standard)
    names = set()
    name_sources = {}
    for entry in LOCK['files']:
        name = entry['path']
        if not any(name.endswith('/' + kind + '.dict.yaml') for kind in ['diming', 'mingren', 'yiren']):
            continue
        path = SOURCE / name
        data = path.read_bytes()
        assert valid(data, entry), name
        name_sources[name] = hashlib.sha256(data).hexdigest()
        for word, _, _ in rows(path):
            if len(word) > 1:
                names.update(word)
                names.update(s2t.convert(word))
                names.update(t2s.convert(word))
    protected = baseline | standard_forms | names | {'〇'}
    current = set()
    for script in ['hans', 'hant']:
        path = ROOT / f'data/mac-rime-source/learn_{script}.dict.yaml'
        for line in path.open():
            if '\t' in line:
                current.update(line.split('\t', 1)[0])
    current_han = {c for c in current if ord(c) in han or c == '〇'}
    new = current_han - baseline
    excluded = new - protected
    translations_path = output / 'apple-translations.json'
    apple = json.loads(translations_path.read_text()) if translations_path.exists() else {}
    translations = apple.get('translations', {})
    apple_errors = apple.get('characterErrors', {})
    policy = dict(version=1,
                  reason='Keep original Pinyin characters, all 8105 standard characters and their traditional forms, and characters used by the selected place/person-name dictionaries; remove other additive Han from Pinyin only',
                  unicodeVersion='17.0.0', unicodeURL=source_manifest['sources']['Unihan.zip']['url'],
                  unicodeSHA256=unicode_hash, unicodeProperty='kTGH (2013), kTraditionalVariant, Unihan Han code points',
                  standardCharacterCount=len(standard),
                  baseDatabaseSHA256=hashlib.sha256((ROOT / 'Resources/lexicon.sqlite').read_bytes()).hexdigest(),
                  wanxiangCommit=LOCK['commit'], nameSourceSHA256=name_sources,
                  hanRanges=ranges(han), protectedCharacters=''.join(sorted(protected, key=ord)))
    report = dict(currentHanCharacters=len(current_han), additiveHanCharacters=len(new),
                  additiveKept=len(new & protected), additiveRemoved=len(excluded),
                  protectedByStandard=len(new & standard_forms),
                  protectedByNamesOnly=len((new & names) - standard_forms),
                  appleAudited=len(new & (translations.keys() | apple_errors.keys())),
                  appleReturnedSource=sum(translations.get(c) == c for c in new),
                  appleCharacterErrors=len(new & apple_errors.keys()),
                  englishDefinitionPresent=sum(c in definitions for c in new),
                  excludedCharacters=''.join(sorted(excluded, key=ord)),
                  keptAdditiveCharacters=''.join(sorted(new & protected, key=ord)),
                  policy=policy)
    (output / 'classification.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    with (output / 'characters.csv').open('w', newline='') as stream:
        writer = csv.writer(stream)
        writer.writerow(['character', 'codepoint', 'decision', 'reason', 'unihanEnglishDefinition', 'appleEnglish'])
        for c in sorted(current_han, key=ord):
            reason = ('original-pinyin' if c in baseline else 'standard-or-traditional' if c in standard_forms
                      else 'place-or-person-name' if c in names else 'zero-numeral' if c == '〇' else 'nonstandard-additive')
            writer.writerow([c, f'U+{ord(c):04X}', 'remove' if c in excluded else 'keep', reason,
                             definitions.get(c, ''), translations.get(c, apple_errors.get(c, 'not-audited'))])
    if args.write_policy:
        (ROOT / 'scripts/mac-common-character-policy.json').write_text(json.dumps(policy, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({k: v for k, v in report.items() if k not in ['policy', 'excludedCharacters', 'keptAdditiveCharacters']}, ensure_ascii=False))


if __name__ == '__main__':
    main()
