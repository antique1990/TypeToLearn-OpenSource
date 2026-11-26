"""Apply the same bounded Tatoeba word-frequency adjustments to both platforms."""

import bz2
from collections import Counter
import hashlib
import re

from opencc import OpenCC


TATOEBA_SOURCE = 'https://downloads.tatoeba.org/exports/per_language/cmn/cmn_sentences_detailed.tsv.bz2'
HAN = re.compile(r'[\u3400-\u4dbf\u4e00-\u9fff]+')
TATOEBA_NOTICE = (
    f'Tatoeba Mandarin sentences · Tatoeba contributors\n{TATOEBA_SOURCE}\n'
    'CC BY 2.0 FR · https://creativecommons.org/licenses/by/2.0/fr/\n'
    'The detailed export records the contributors per sentence. LearnKeyboard normalizes and '
    'deduplicates text and uses repeated character combinations to adjust existing word weights.\n'
)


def apply_tatoeba_weights(db, archive):
    to_simplified = OpenCC('t2s')
    sentences = set()
    source_count = 0
    with bz2.open(archive, 'rt', encoding='utf-8') as source:
        for line in source:
            fields = line.rstrip('\r\n').split('\t')
            if len(fields) == 6 and fields[0].isdigit() and fields[1] == 'cmn':
                source_count += 1
                sentences.add(to_simplified.convert(fields[2]))
    if not sentences:
        raise ValueError('Tatoeba input is not a detailed Mandarin export')

    counts = Counter()
    for sentence in sentences:
        chunks = set()
        for section in HAN.findall(sentence):
            for size in (2, 3):
                chunks.update(section[start:start + size] for start in range(len(section) - size + 1))
        counts.update(chunks)
    frequencies = {text: count for text, count in counts.items() if count >= 3}
    # Only repeated combinations can affect the weights of already known
    # words. Raw sentences and the working count table stay off-device.
    db.execute('CREATE TEMP TABLE context_boost(text TEXT PRIMARY KEY, boost INTEGER NOT NULL) WITHOUT ROWID')
    db.executemany('INSERT INTO context_boost VALUES (?,?)',
                   ((text, min(12, count.bit_length() - 1)) for text, count in sorted(frequencies.items())))
    adjusted = db.execute('''
        UPDATE pinyin SET weight = weight + MIN((weight + 9) / 10, context_boost.boost)
        FROM context_boost WHERE pinyin.simplified = context_boost.text
    ''').rowcount
    db.execute('DROP TABLE context_boost')
    return dict(url=TATOEBA_SOURCE, sha256=hashlib.sha256(archive.read_bytes()).hexdigest(), license='CC-BY-2.0-FR',
                sourceSentences=source_count, distinctSentences=len(sentences),
                repeatedCombinations=len(frequencies), adjustedRows=adjusted)
