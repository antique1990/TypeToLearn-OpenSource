#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p data/sources Resources/Licenses
curl --fail --location --max-time 120 'https://www.mdbg.net/chinese/export/cedict/cedict_1_0_ts_utf-8_mdbg.txt.gz' -o data/sources/cedict.gz
curl --fail --location --max-time 120 'https://raw.githubusercontent.com/rime/rime-cangjie/master/cangjie5.base.dict.yaml' -o data/sources/cangjie5.base.dict.yaml
curl --fail --location --max-time 120 'https://raw.githubusercontent.com/fxsjy/jieba/master/jieba/dict.txt' -o data/sources/jieba-dict.txt
curl --fail --location --max-time 120 'https://raw.githubusercontent.com/fxsjy/jieba/master/LICENSE' -o Resources/Licenses/jieba-MIT.txt
curl --fail --location --max-time 120 'https://raw.githubusercontent.com/rime/rime-cangjie/master/LICENSE' -o Resources/Licenses/rime-cangjie-LICENSE.txt
curl --fail --location --max-time 120 'https://www.gnu.org/licenses/gpl-3.0.txt' -o Resources/Licenses/GPL-3.0.txt
curl --fail --location --max-time 120 'https://creativecommons.org/licenses/by-sa/4.0/legalcode.txt' -o Resources/Licenses/CC-BY-SA-4.0.txt
thuocl_commit=a30ce79d895d01ab5132a5c74c29703ff7efb4cc
mkdir -p data/sources/thuocl data/sources/wordnet
for category in IT animal caijing car chengyu diming food law lishimingren medical poem; do
    curl --fail --location --max-time 120 "https://raw.githubusercontent.com/thunlp/THUOCL/$thuocl_commit/data/THUOCL_$category.txt" -o "data/sources/thuocl/THUOCL_$category.txt"
done
curl --fail --location --max-time 120 "https://raw.githubusercontent.com/thunlp/THUOCL/$thuocl_commit/LICENSE" -o Resources/Licenses/THUOCL-MIT.txt
wordnet_archive=$(mktemp)
trap 'rm -f "$wordnet_archive"' EXIT
curl --fail --location --max-time 120 'https://wordnetcode.princeton.edu/3.0/WNdb-3.0.tar.gz' -o "$wordnet_archive"
printf '%s  %s\n' '658b1ba191f5f98c2e9bae3e25c186013158f30ef779f191d2a44e5d25046dc8' "$wordnet_archive" | shasum -a 256 -c -
tar -xzf "$wordnet_archive" -C data/sources/wordnet dict/index.adj dict/index.adv dict/index.noun dict/index.verb
python3 - <<'PY'
from pathlib import Path
import re
lines = Path('data/sources/wordnet/dict/index.noun').read_text().splitlines()[:29]
Path('Resources/Licenses/WordNet-3.0.txt').write_text('WordNet 3.0 License\n\n' +
    '\n'.join(re.sub(r'^\s*\d+\s', '', line).rstrip() for line in lines) + '\n')
PY
