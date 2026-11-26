# TypeToLearn

TypeToLearn is an open-source keyboard and language-learning app for iPhone and Mac. It can show a translation alongside an input candidate while you type.

- **iPhone** supports full Pinyin, nine-key Pinyin, Cangjie, English completion and next-word prediction, Simplified and Traditional Chinese, and on-device learning translations.
- **Mac** supports Pinyin and mixed Chinese/English input, an input-method settings app, local learning translations, and optional translation providers configured by the user.

## Requirements

Use Xcode with the iOS 26 and macOS 26 SDKs or later, plus Python 3 and [XcodeGen](https://github.com/yonaskolb/XcodeGen). Apple translation languages and features depend on the OS version and installed language packs.

## Build for iPhone

From the repository root, fetch the pinned Rime engine and language models and compile the bundled baseline lexicon into Rime format:

```sh
python3 scripts/fetch_rime.py
python3 scripts/build_rime_data.py
xcodegen generate
xcodebuild -project LearnKeyboard.xcodeproj -scheme LearnKeyboard \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

For a signed device build, set your Apple Developer team, a unique application bundle identifier and its extension and test identifiers, and a registered App Group in `project.yml`. Run `xcodegen generate` again. In Xcode, run the `LearnKeyboard` scheme on a connected iPhone. On the iPhone, add TypeToLearn in Settings → General → Keyboard → Keyboards. Basic typing works without Full Access. Clipboard access uses the system permission flow.

## Build for Mac

Start with the Rime dependency step above. Install the dictionary conversion dependencies in a virtual environment, build the Mac dictionary, then generate and build the project:

```sh
python3 -m venv .build/lexicon-env
source .build/lexicon-env/bin/activate
python3 -m pip install pypinyin==0.55.0 opencc-python-reimplemented==0.1.7
python3 scripts/build_mac_rime_ice.py
xcodegen generate
xcodebuild -project LearnKeyboard.xcodeproj -scheme LearnKeyboardMac \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/mac build
```

Open `.build/mac/Build/Products/Debug/TypeToLearnMac.app` and use the settings app to install the input method. Add it under System Settings → Keyboard → Text Input. The settings app can prepare Apple Translation language packs. The Mac scheme builds a local development version.

## Dictionaries

The baseline SQLite database, its source snapshots, and the build scripts are included. See [Third-party notices](Resources/THIRD_PARTY_NOTICES.txt) for source and license details. To rebuild the baseline from its source snapshot, extract `Resources/Licenses/input-sources.tar.gz` into `data/sources` and run `python3 scripts/build_lexicon.py` with the dependencies listed above, followed by `python3 scripts/build_rime_data.py`.

The expanded Pinyin dictionaries are built locally from [Rime Ice at the pinned revision](https://github.com/iDvel/rime-ice/tree/927e1cf1d3eeb9bf4be85e3f684dba4dd485b6f6). The scripts import entries with explicit Pinyin from `8105`, `base`, `ext`, and `others`. `base` and `ext` have mixed sources that include Tencent-derived material. The optional [Tatoeba Mandarin export](https://downloads.tatoeba.org/exports/per_language/cmn/) adjusts weights for entries already present in the lexicon.

```sh
python3 scripts/build_mac_rime_ice.py --tatoeba /path/to/cmn_sentences_detailed.tsv.bz2
python3 scripts/build_ios_rime_ice.py --tatoeba /path/to/cmn_sentences_detailed.tsv.bz2
```

Each build records its inputs and checksums. Either script accepts a locally downloaded pinned Rime Ice archive through `--archive`. The iPhone scheme reads the expanded dictionary when present and otherwise uses the baseline. The raw Tatoeba export is kept on the build machine. Preserve upstream notices and check the individual source terms when distributing generated dictionaries.

## Tests

Run `swift test` on a Mac after fetching Rime. Run `python3 scripts/test_build_lexicon.py` for baseline dictionary parsing. The Xcode scheme includes device UI tests for a connected, physical iPhone.

## License

The project's original code and documentation are available under [GPL-3.0-only](LICENSE). Third-party code, datasets, and models retain their own terms. TypeToLearn product names and logos identify the project; the software license grants no trademark rights.
