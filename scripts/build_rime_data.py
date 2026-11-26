#!/usr/bin/env python3
"""Compile attributed SQLite vocabulary to Rime data on this physical Mac."""
import hashlib, json, sqlite3, subprocess, tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / 'Resources/RimeData'
STAGING = ROOT / 'data/rime-source'
STAGING.mkdir(parents=True, exist_ok=True)
db = sqlite3.connect(ROOT / 'Resources/lexicon.sqlite')

def fuzzy_algebra(*, has_abbreviations):
    rules = []
    next_letter = '(?=.)' if has_abbreviations else ''
    for initial in ('z', 'c', 's'):
        rules += [f'derive/^{initial}h{next_letter}/{initial}/', f'derive/^{initial}([^h])/{initial}h$1/']
    for first, second in (('n', 'l'), ('f', 'h')):
        rules += [f'derive/^{first}{next_letter}/{second}/', f'derive/^{second}{next_letter}/{first}/']
    for final in ('an', 'en', 'in'):
        rules += [f'derive/{final}$/{final}g/', f'derive/{final}g$/{final}/']
    return rules

schemas = []
for script, column in [('hans', 'simplified'), ('hant', 'traditional')]:
    dictionary = f'learn_{script}'
    with (STAGING / f'{dictionary}.dict.yaml').open('w') as f:
        f.write(f'---\nname: {dictionary}\nversion: "1"\nsort: by_weight\nuse_preset_vocabulary: false\n...\n')
        for text, roman, weight in db.execute(f'SELECT {column}, roman, MAX(weight) FROM pinyin GROUP BY {column}, roman'):
            f.write(f'{text}\t{roman}\t{weight}\n')
    for mode, variant in (('pinyin', ''), ('nine', ''), ('pinyin', '_fuzzy'), ('nine', '_fuzzy'), ('pinyin', '_complete')):
        schema = f'learn_{mode}_{script}{variant}'
        fuzzy = variant == '_fuzzy'
        if mode == 'pinyin':
            # Compute abbreviations from original spellings before adding the
            # aliases for whole syllables.
            abbreviation = 'abbrev' if variant == '_complete' else 'derive'
            algebra = [f'{abbreviation}/^([a-z]).+$/$1/', f'{abbreviation}/^([zcs]h).+$/$1/']
            if fuzzy:
                algebra += fuzzy_algebra(has_abbreviations=True)
            algebra += ['derive/([nl])ve$/$1ue/', 'derive/([jqxy])u/$1v/', 'derive/([aeiou])ng$/$1gn/']
        else:
            algebra = fuzzy_algebra(has_abbreviations=False) if fuzzy else []
            algebra += ['xlit/abcdefghijklmnopqrstuvwxyz/22233344455566677778889999/']
        config = STAGING / f'{schema}.schema.yaml'
        schemas.append(config)
        config.write_text(f'''schema:
  schema_id: {schema}
  name: 伴语{mode}
  version: "1"
menu:
  page_size: 9
engine:
  processors: [speller, selector, navigator, express_editor]
  segmentors: [abc_segmentor, fallback_segmentor]
  translators: [script_translator]
speller:
  alphabet: {'abcdefghijklmnopqrstuvwxyz' if mode == 'pinyin' else '23456789'}
  delimiter: " '"
  max_code_length: 256
  algebra:
''' + ''.join(f'    - {a}\n' for a in algebra) + f'''translator:
  dictionary: {dictionary}
  prism: {schema}
  enable_user_dict: false
  enable_completion: true
  contextual_suggestions: true
  max_homophones: 7
  max_homographs: 7
grammar:
  language: zh-{script}-t-essay-bgw
''')
(STAGING / 'default.yaml').write_text('config_version: "1"\nschema_list:\n  - schema: learn_pinyin_hans\nmenu:\n  page_size: 9\n')
# Only dictionary compilation runs here; no iOS emulation is involved.
source = r'''
#include "rime_api.h"
#include <stdio.h>
int main(int argc, char **argv) {
 if (argc < 4) return 2;
 RimeApi *api=rime_get_api(); RIME_STRUCT(RimeTraits,t);
 t.shared_data_dir=argv[1];t.user_data_dir=argv[2];t.log_dir="";t.min_log_level=3;
 api->setup(&t);api->initialize(&t);api->deployer_initialize(&t);
 if (!api->deploy_config_file("default.yaml", "config_version")) return 3;
 for (int i = 3; i < argc; i++) if (!api->deploy_schema(argv[i])) return 4;
 api->finalize();return 0;
}
'''
with tempfile.TemporaryDirectory(prefix='learnkeyboard-rime-build-') as temp:
    temp=Path(temp); (temp/'build.c').write_text(source)
    lib=ROOT/'Vendor/librime-static.xcframework/macos-arm64_x86_64'
    subprocess.run(['xcrun','clang',str(temp/'build.c'),'-I',str(lib/'Headers'),str(lib/'librime.a'),'-lc++','-o',str(temp/'builder')],check=True)
    subprocess.run([str(temp/'builder'), str(STAGING), str(OUTPUT), *map(str, schemas)],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
manifest = {str(p.relative_to(OUTPUT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(OUTPUT.rglob('*')) if p.is_file() and p.name != 'manifest.json'}
(OUTPUT/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print(f'Compiled {len(manifest)} Rime resources')
