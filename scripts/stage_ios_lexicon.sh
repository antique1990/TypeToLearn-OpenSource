#!/bin/sh
set -eu

source="${SRCROOT:?}/Resources"
generated="$SRCROOT/iOS/DictionaryResources"
destination="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}"

if [ -d "$generated" ]; then
    source="$generated"
    test -f "$source/IOS-LEXICON-NOTICE.txt"
    test -f "$source/RIME-ICE-LICENSE.txt"
fi

test -f "$source/lexicon.sqlite"
test -f "$source/lexicon-manifest.json"
test -f "$source/RimeData/manifest.json"
mkdir -p "$destination"

# Replace the generated files together so an incremental build cannot retain
# tables or notices from the other vocabulary pack.
rm -rf "$destination/RimeData"
ditto "$source/RimeData" "$destination/RimeData"
ditto "$source/lexicon.sqlite" "$destination/lexicon.sqlite"
ditto "$source/lexicon-manifest.json" "$destination/lexicon-manifest.json"
for file in IOS-LEXICON-NOTICE.txt RIME-ICE-LICENSE.txt; do
    if [ -f "$source/$file" ]; then
        ditto "$source/$file" "$destination/$file"
    else
        rm -f "$destination/$file"
    fi
done
echo "iPhone dictionary: $source"
