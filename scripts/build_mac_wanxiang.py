#!/usr/bin/env python3
"""Build Mac-only Wanxiang lexicon/indexes using our own importer and Rime compiler.

Prerequisite: fetch_mac_wanxiang.py; OpenCC-Python-Reimplemented==0.1.7.
Never writes the shared iPhone Resources directory.
"""
import functools
import argparse
import bisect
import hashlib
import json
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import tempfile
import unicodedata

from opencc import OpenCC
from fetch_mac_wanxiang import LOCK, ROOT, SOURCE, valid

OUTPUT = ROOT / 'Mac/DictionaryResources'
STAGING = ROOT / 'data/mac-rime-source'
DIGITS = str.maketrans({c: str(n) for n, chars in enumerate(
    ['abc', 'def', 'ghi', 'jkl', 'mno', 'pqrs', 'tuv', 'wxyz'], 2) for c in chars})


def romanize(reading):
    reading = reading.lower().replace('ü', 'v').replace('u:', 'v')
    # NFD separates diaeresis from toned ü (ǚ, ǜ, ...), before removing tones.
    reading = unicodedata.normalize('NFD', reading).replace('u\u0308', 'v')
    reading = ''.join(c for c in reading if not unicodedata.combining(c))
    return ' '.join(reading.replace("'", ' ').split())


def rows(path, warnings=None):
    body = False
    with path.open(encoding='utf-8-sig') as stream:
        for number, line in enumerate(stream, 1):
            if not body:
                if line.strip() == '...':
                    body = True
                continue
            if not line.strip() or line.startswith('#'):
                continue
            fields = line.rstrip('\r\n').split('\t')
            if len(fields) < 2:
                raise ValueError(f'Malformed entry {path.name}:{number}')
            weight = fields[2].split('#')[0].strip() if len(fields) > 2 else ''
            try:
                number_weight = int(weight) if weight else 1
            except ValueError:
                # Preserve the vocabulary, but don't guess a corpus frequency
                # from an upstream typo such as "6N".
                number_weight = 1
                if warnings is not None:
                    location = str(path.relative_to(SOURCE)) if SOURCE in path.parents else path.name
                    warnings.append(dict(file=location, line=number,
                                         field='weight', original=weight, replacement=1))
            yield fields[0], fields[1], number_weight


CORE = {'zi', 'jichu', 'duoyin', 'cuoyin', 'diming', 'yiren', 'mingren', 'en'}
FONT_EXCLUSIONS = ROOT / 'scripts/mac-font-exclusions.json'
CANDIDATE_EXCLUSIONS = ROOT / 'scripts/mac-candidate-exclusions.json'
COMMON_CHARACTER_POLICY = ROOT / 'scripts/mac-common-character-policy.json'


def remove_excluded_entries(database, excluded, *, pinyin_only=False):
    """Remove full entries containing excluded characters before Rime compilation.

    The paired script row is removed as a unit. Source YAML and the shared iOS
    database stay untouched; characters outside the supplied set are retained.
    """
    db = sqlite3.connect(database)
    db.create_function('has_excluded_glyph', 1,
                       lambda text: any(character in excluded for character in text), deterministic=True)
    removed = {}
    tables = [('pinyin', ['simplified', 'traditional'])]
    if not pinyin_only:
        tables += [('cangjie', ['text']), ('wanxiang_codes', ['text'])]
    for table, columns in tables:
        condition = ' OR '.join(f'has_excluded_glyph({column})' for column in columns)
        removed[table] = db.execute(f'DELETE FROM {table} WHERE {condition}').rowcount
    db.commit()
    assert db.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
    db.close()
    return dict(removedRows=removed)


def apply_font_exclusions(database, *, pinyin_only=False):
    data = FONT_EXCLUSIONS.read_bytes()
    profile = json.loads(data)
    excluded = set(profile['characters'])
    assert profile['version'] == 1 and len(excluded) == profile['excludedCharacterCount']
    result = remove_excluded_entries(database, excluded, pinyin_only=pinyin_only)
    result.update(profile=FONT_EXCLUSIONS.name, profileSHA256=hashlib.sha256(data).hexdigest(),
                  platform=profile['platform'], excludedCharacterCount=len(excluded),
                  policy='Drop paired rows containing a character without a usable system glyph; preserve supported extended Han')
    print('Removed unrenderable dictionary entries:', result['removedRows'], flush=True)
    return result


def apply_candidate_exclusions(database, *, pinyin_only=False):
    data = CANDIDATE_EXCLUSIONS.read_bytes()
    profile = json.loads(data)
    excluded = set(profile['characters'])
    assert profile['version'] == 1 and len(excluded) == profile['excludedCharacterCount']
    result = remove_excluded_entries(database, excluded, pinyin_only=pinyin_only)
    result.update(profile=CANDIDATE_EXCLUSIONS.name, profileSHA256=hashlib.sha256(data).hexdigest(),
                  excludedCharacterCount=len(excluded), policy=profile['reason'])
    print('Removed user-excluded dictionary entries:', result['removedRows'], flush=True)
    return result


def unprotected_han_predicate(policy):
    protected = set(policy['protectedCharacters'])
    intervals = policy['hanRanges']
    starts = [interval[0] for interval in intervals]
    def contains_unprotected(text):
        for character in text:
            if character in protected:
                continue
            value = ord(character)
            index = bisect.bisect_right(starts, value) - 1
            if index >= 0 and value <= intervals[index][1]:
                return True
        return False
    return contains_unprotected


def apply_common_character_policy(database):
    data = COMMON_CHARACTER_POLICY.read_bytes()
    policy = json.loads(data)
    assert policy['version'] == 1 and policy['standardCharacterCount'] == 8105
    assert policy['wanxiangCommit'] == LOCK['commit']
    assert policy['baseDatabaseSHA256'] == hashlib.sha256((ROOT / 'Resources/lexicon.sqlite').read_bytes()).hexdigest()
    protected = set(policy['protectedCharacters'])
    with sqlite3.connect(ROOT / 'Resources/lexicon.sqlite') as db:
        original = {c for row in db.execute('SELECT simplified,traditional FROM pinyin') for word in row for c in word}
    assert original <= protected, 'Original Pinyin characters must remain protected'
    reject = unprotected_han_predicate(policy)
    with sqlite3.connect(database) as db:
        characters = {c for row in db.execute('SELECT simplified,traditional FROM pinyin') for word in row for c in word}
    excluded = {c for c in characters if reject(c)}
    result = remove_excluded_entries(database, excluded, pinyin_only=True)
    result.update(profile=COMMON_CHARACTER_POLICY.name, profileSHA256=hashlib.sha256(data).hexdigest(),
                  excludedCharacterCount=len(excluded), protectedCharacterCount=len(protected),
                  policy=policy['reason'], scope='Pinyin only; original Cangjie, English and auxiliary codes retained')
    print('Removed nonstandard additive Pinyin characters:', result['excludedCharacterCount'], result['removedRows'], flush=True)
    return result


def build_database(destination, preset):
    shutil.copy2(ROOT / 'Resources/lexicon.sqlite', destination)
    db = sqlite3.connect(destination)
    db.executescript('''
        PRAGMA journal_mode=OFF;
        PRAGMA synchronous=OFF;
        CREATE TABLE wanxiang_pinyin(code TEXT NOT NULL, digits TEXT NOT NULL, roman TEXT NOT NULL,
            simplified TEXT NOT NULL, traditional TEXT NOT NULL, weight INTEGER NOT NULL,
            PRIMARY KEY(code,simplified,traditional)) WITHOUT ROWID;
        CREATE TABLE wanxiang_codes(script TEXT NOT NULL, source TEXT NOT NULL,
            text TEXT NOT NULL, code TEXT NOT NULL, weight INTEGER NOT NULL);
    ''')
    converters = {name: OpenCC(name) for name in ('s2t', 't2s')}
    @functools.lru_cache(maxsize=100000)
    def convert(text, direction):
        return converters[direction].convert(text)
    upsert = '''INSERT INTO wanxiang_pinyin VALUES (?,?,?,?,?,?) ON CONFLICT(code,simplified,traditional)
                DO UPDATE SET weight=MAX(weight,excluded.weight)'''
    stats = {}
    warnings = []
    for entry in LOCK['files']:
        name = entry['path']
        if not name.endswith('.dict.yaml'):
            continue
        source = SOURCE / name
        if not valid(source.read_bytes(), entry):
            raise ValueError(f'Unverified input {name}')
        script = 'hant' if name.startswith('dicts_hant/') else 'hans'
        kind = source.name.removesuffix('.dict.yaml')
        if preset == 'core' and kind not in CORE:
            continue
        total = pinyin = english = auxiliary = 0
        batch = []
        for text, reading, weight in rows(source, warnings):
            total += 1
            if total % 250000 == 0:
                print(f'Importing {name}: {total:,} rows', flush=True)
            if kind == 'en':
                word = text.lower()
                if re.fullmatch('[a-z]{2,32}', word):
                    db.execute('INSERT INTO english VALUES (?,?) ON CONFLICT(word) DO UPDATE SET weight=MAX(weight,excluded.weight)',
                               (word, weight))
                    english += 1
                else:
                    db.execute('INSERT INTO wanxiang_codes VALUES (?,?,?,?,?)', (script, kind, text, reading, weight))
                    auxiliary += 1
                continue
            roman = romanize(reading)
            code = roman.replace(' ', '')
            if kind in ('abbrev', 't9_abbrev') or len(code) > 256 or not re.fullmatch('[a-z]+(?: [a-z]+)*', roman):
                # Double-pinyin shortcuts and symbol/digit codes are not full
                # syllable readings. Keep them intact, never poison full-pinyin.
                db.execute('INSERT INTO wanxiang_codes VALUES (?,?,?,?,?)', (script, kind, text, reading, weight))
                auxiliary += 1
                continue
            simplified = text if script == 'hans' else convert(text, 't2s')
            traditional = text if script == 'hant' else convert(text, 's2t')
            batch.append((code, code.translate(DIGITS), roman, simplified, traditional, max(1, weight)))
            pinyin += 1
            if len(batch) >= 5000:
                db.executemany(upsert, batch)
                batch.clear()
        db.executemany(upsert, batch)
        stats[name] = dict(rows=total, pinyin=pinyin, english=english, auxiliary=auxiliary,
                           sha256=hashlib.sha256(source.read_bytes()).hexdigest())
        db.commit()
        print(f'Imported {name}: {stats[name]}', flush=True)
    # Keep existing rare readings and first-party terms only as low-weight
    # fallback. Existing corpus frequencies are not comparable to Wanxiang.
    before = db.total_changes
    db.execute('INSERT OR IGNORE INTO wanxiang_pinyin SELECT code,digits,roman,simplified,traditional,1 FROM pinyin')
    fallback = db.total_changes - before
    # Add vocabulary without replacing the established model's frequency scale.
    # Unrelated corpus counts cannot be compared directly. Preserve baseline
    # weights for existing entries; bound new-only entries on the same domain
    # supplement scale already used by the project's THUOCL importer.
    db.execute('''UPDATE wanxiang_pinyin SET weight=COALESCE(
        (SELECT MAX(base.weight) FROM pinyin AS base
         WHERE base.code=wanxiang_pinyin.code AND base.simplified=wanxiang_pinyin.simplified
           AND base.traditional=wanxiang_pinyin.traditional), MIN(weight,120))''')
    db.executescript('''
        DROP TABLE pinyin;
        CREATE TABLE pinyin(code TEXT NOT NULL, digits TEXT NOT NULL, roman TEXT NOT NULL,
            simplified TEXT NOT NULL, traditional TEXT NOT NULL, weight INTEGER NOT NULL);
        INSERT INTO pinyin SELECT * FROM wanxiang_pinyin;
        DROP TABLE wanxiang_pinyin;
        CREATE INDEX pinyin_code ON pinyin(code,weight DESC);
        CREATE INDEX pinyin_digits ON pinyin(digits,weight DESC);
        CREATE INDEX pinyin_single_hans ON pinyin(code,weight DESC) WHERE length(simplified)=1;
        CREATE INDEX pinyin_single_hant ON pinyin(code,weight DESC) WHERE length(traditional)=1;
        CREATE INDEX wanxiang_codes_lookup ON wanxiang_codes(script,source,code);
        PRAGMA user_version=3;
    ''')
    counts = {table: db.execute(f'SELECT count(*) FROM {table}').fetchone()[0]
              for table in ('pinyin', 'english', 'cangjie', 'wanxiang_codes')}
    assert len(stats) == (16 if preset == 'core' else 36) and counts['pinyin'] > 1000000, counts
    assert db.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
    db.commit()
    db.execute('VACUUM')
    db.close()
    return dict(files=stats, counts=counts, fallbackRows=fallback, importWarnings=warnings)


def compile_rime(database, output, *, staging=STAGING,
                 dictionary_version=f'wanxiang-{LOCK["commit"][:12]}', config_version='wanxiang-1',
                 include_fuzzy=False):
    staging.mkdir(parents=True, exist_ok=True)
    output.mkdir()
    # Retain the already attributed grammar models; this task adds vocabulary,
    # not an unrelated downloaded language model.
    for model in (ROOT / 'Resources/RimeData').glob('*.gram'):
        shutil.copy2(model, output / model.name)
    db = sqlite3.connect(database)
    schemas = []
    for script, column in [('hans', 'simplified'), ('hant', 'traditional')]:
        dictionary = f'learn_{script}'
        with (staging / f'{dictionary}.dict.yaml').open('w') as stream:
            stream.write(f'---\nname: {dictionary}\nversion: "{dictionary_version}"\nsort: by_weight\nuse_preset_vocabulary: false\n...\n')
            for text, roman, weight in db.execute(f'SELECT {column},roman,MAX(weight) FROM pinyin GROUP BY {column},roman'):
                stream.write(f'{text}\t{roman}\t{weight}\n')
        scheme_names = [f'learn_pinyin_{script}', f'learn_nine_{script}', f'learn_pinyin_{script}_complete']
        if include_fuzzy:
            scheme_names.extend([f'learn_pinyin_{script}_fuzzy', f'learn_nine_{script}_fuzzy'])
        for schema in scheme_names:
            previous = ROOT / f'Resources/RimeData/build/{schema}.schema.yaml'
            content = previous.read_text()
            content = re.sub(r'(?m)^__build_info:\n(?:[ \t].*\n)*', '', content)
            config = staging / f'{schema}.schema.yaml'
            config.write_text(content)
            schemas.append(str(config))
    db.close()
    (staging / 'default.yaml').write_text(f'config_version: "{config_version}"\nschema_list:\n  - schema: learn_pinyin_hans\nmenu:\n  page_size: 9\n')
    code = r'''
#include "rime_api.h"
#include <stdio.h>
int main(int argc, char **argv) {
 if(argc < 4) return 2;
 RimeApi *api=rime_get_api(); RIME_STRUCT(RimeTraits,t);
 t.shared_data_dir=argv[1]; t.user_data_dir=argv[2]; t.log_dir="";t.min_log_level=3;
 api->setup(&t);api->initialize(&t);api->deployer_initialize(&t);
 if(!api->deploy_config_file("default.yaml","config_version"))return 3;
 for(int i=3;i<argc;i++) if(!api->deploy_schema(argv[i])) return 4;
 api->finalize();return 0;
}
'''
    with tempfile.TemporaryDirectory(prefix='mac-wanxiang-compiler-') as temp:
        temp = Path(temp)
        (temp / 'build.c').write_text(code)
        lib = ROOT / 'Vendor/librime-static.xcframework/macos-arm64_x86_64'
        subprocess.run(['xcrun', 'clang', str(temp / 'build.c'), '-I', str(lib / 'Headers'),
                        str(lib / 'librime.a'), '-lc++', '-o', str(temp / 'builder')], check=True)
        log_path = staging / 'compile.log'
        with log_path.open('w') as log:
            result = subprocess.run([str(temp / 'builder'), str(staging), str(output), *schemas],
                                    stdout=log, stderr=log)
        if result.returncode:
            raise RuntimeError(f'Rime compilation failed ({result.returncode}):\n{log_path.read_text()[-6000:]}')
    (output / 'manifest.json').write_text(json.dumps({
        str(p.relative_to(output)): hashlib.sha256(p.read_bytes()).hexdigest()
        for p in sorted(output.rglob('*')) if p.is_file()}, indent=2) + '\n')


def compact_database(database, *, auxiliary_tables=('wanxiang_codes',)):
    """Lossless projection of the SQL fields/ranges the Mac actually queries.

    Complete phrase data remains in Rime. SQL typo probes are bounded to input
    lengths 4...12 and one-edit variants (lengths 3...13); exact phrase checks
    are only used within that range. Single-character queries remain intact.
    """
    db = sqlite3.connect(database)
    if not db.execute("SELECT 1 FROM sqlite_master WHERE name='pinyin_phrases'").fetchone():
        db.executescript('''
            CREATE TABLE pinyin_phrases(code TEXT NOT NULL, simplified TEXT NOT NULL,
                traditional TEXT NOT NULL, weight INTEGER NOT NULL,
                PRIMARY KEY(code,simplified,traditional)) WITHOUT ROWID;
            INSERT INTO pinyin_phrases
                SELECT code,simplified,CASE WHEN traditional=simplified THEN '' ELSE traditional END,weight
                FROM pinyin WHERE length(code) BETWEEN 3 AND 13
                    AND (length(simplified)>1 OR length(traditional)>1);
            DELETE FROM pinyin WHERE length(simplified)<>1 AND length(traditional)<>1;
            PRAGMA user_version=4;
        ''')
        db.commit()
        db.execute('VACUUM')
    counts = {table: db.execute(f'SELECT count(*) FROM {table}').fetchone()[0]
              for table in ('pinyin', 'pinyin_phrases', 'english', 'cangjie', *auxiliary_tables)}
    assert db.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
    db.close()
    return counts


def compact_resources(directory):
    manifest = directory / 'wanxiang-manifest.json'
    report = json.loads(manifest.read_text())
    if 'compiledVocabularyCounts' not in report:
        report['compiledVocabularyCounts'] = report['counts']
    report['counts'] = compact_database(directory / 'lexicon.sqlite')
    report['storageFormat'] = 'mac-auxiliary-v4'
    report['databaseSHA256'] = hashlib.sha256((directory / 'lexicon.sqlite').read_bytes()).hexdigest()
    change = 'SQLite retains single characters and lossless short-code typo projections (code lengths 3...13); complete phrase data remains in Rime'
    if change not in report['transformations']:
        report['transformations'].append(change)
    manifest.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    return report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--preset', choices=['core', 'full'], default='core')
    parser.add_argument('--compact-existing', action='store_true',
                        help='Compact already-compiled Mac resources without changing Rime files')
    args = parser.parse_args()
    if args.compact_existing:
        print(json.dumps(compact_resources(OUTPUT)['counts']), flush=True)
        return
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='wanxiang-resources-', dir=OUTPUT.parent) as temp:
        built = Path(temp)
        report = build_database(built / 'lexicon.sqlite', args.preset)
        report['beforeGlyphFilterCounts'] = report['counts']
        report['glyphFilter'] = apply_font_exclusions(built / 'lexicon.sqlite')
        report['candidateFilter'] = apply_candidate_exclusions(built / 'lexicon.sqlite')
        report['rareCharacterFilter'] = apply_common_character_policy(built / 'lexicon.sqlite')
        with sqlite3.connect(built / 'lexicon.sqlite') as db:
            report['counts'] = {table: db.execute(f'SELECT count(*) FROM {table}').fetchone()[0]
                                for table in ('pinyin', 'english', 'cangjie', 'wanxiang_codes')}
        print('Compiling native Mac Rime dictionaries...', flush=True)
        compile_rime(built / 'lexicon.sqlite', built / 'RimeData')
        for name in ['LICENSE', 'LICENSE-SCOPE.md', 'NOTICE.md']:
            shutil.copy2(SOURCE / name, built / ('wanxiang-' + name))
        shutil.copy2(ROOT / 'Resources/Licenses/UNICODE-3.0.txt', built / 'character-policy-UNICODE-3.0.txt')
        (built / 'CHARACTER-POLICY-NOTICE.txt').write_text(
            'Mac Pinyin character retention policy uses Unicode 17.0 Unihan kTGH (2013), '
            'kTraditionalVariant and Han code point mappings.\n'
            'https://www.unicode.org/Public/17.0.0/ucd/Unihan.zip\n'
            'Copyright Unicode, Inc. Distributed under Unicode License V3; see character-policy-UNICODE-3.0.txt.\n'
            'Modified: derive protected standard/traditional character sets, combine with original Pinyin '
            'and selected place/person-name characters, and filter other additive Han from Mac Pinyin only.\n')
        report.update(repository=LOCK['repository'], commit=LOCK['commit'], committedAt=LOCK['committedAt'], preset=args.preset,
                      license='Wanxiang data: CC-BY-4.0; baseline data retain their original notices in Licenses and THIRD_PARTY_NOTICES.txt',
                      databaseSHA256=hashlib.sha256((built / 'lexicon.sqlite').read_bytes()).hexdigest(),
                      baseDatabaseSHA256=hashlib.sha256((ROOT / 'Resources/lexicon.sqlite').read_bytes()).hexdigest(),
                      transformations=['Tone marks removed; ü normalized to v; OpenCC 0.1.7 pairs simplified/traditional',
                                       'Duplicate pronunciation/text entries merged by maximum weight',
                                       'Existing lexicon frequencies retained; new-only entries capped at 120 on the domain-supplement scale',
                                       'English words merged into the offline English index',
                                       'Double-pinyin/T9 shortcuts and non-letter codes preserved in wanxiang_codes; not treated as full-pinyin readings',
                                       'Entries containing native Mac font coverage exclusions removed before Rime compilation; raw upstream data unchanged',
                                       'Entries containing the user-selected weism supplementary characters removed from Mac resources',
                                       'Other additive Han outside original Pinyin, standard/traditional forms and place/person-name coverage removed from Pinyin only'])
        (built / 'wanxiang-manifest.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
        (built / 'WANXIANG-NOTICE.txt').write_text(
            f'万象词库 / Wanxiang dictionaries by amzxyz and contributors\n{LOCK["repository"]}\n'
            f'Pinned revision: {LOCK["commit"]} ({LOCK["committedAt"]})\n'
            'Dictionary data: Creative Commons Attribution 4.0 International (CC BY 4.0)\n'
            'https://creativecommons.org/licenses/by/4.0/\n'
            'Modified by LearnKeyboard: tone removal, simplified/traditional pairing, deduplication, '
            'SQLite indexing, Rime compilation, unsupported Mac glyph exclusions, user-selected candidate exclusions '
            'and conservative additive Pinyin character filtering; '
            'supplemental vocabulary retains its original notices.\n'
            'The upstream program tools are not included. See wanxiang-LICENSE, wanxiang-LICENSE-SCOPE.md '
            'and wanxiang-NOTICE.md.\n')
        report = compact_resources(built)
        OUTPUT.mkdir(exist_ok=True)
        for path in built.iterdir():
            target = OUTPUT / path.name
            if target.is_dir():
                shutil.rmtree(target)
            elif target.exists():
                target.unlink()
            shutil.move(str(path), target)
        print(json.dumps(report['counts']), flush=True)


if __name__ == '__main__':
    main()
