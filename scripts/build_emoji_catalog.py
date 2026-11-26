#!/usr/bin/env python3
"""Turn Unicode Emoji 17.0 keyboard test data into a compact offline catalog."""

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "data/unicode/emoji-test-17.txt"
DESTINATION = ROOT / "Resources/emoji-catalog.json"

GROUPS = {
    "Smileys & Emotion": ("smileys", "表情与情感", "😀"),
    "People & Body": ("people", "人物与身体", "👋"),
    "Component": ("component", "肤色与发型", "🎨"),
    "Animals & Nature": ("nature", "动物与自然", "🐻"),
    "Food & Drink": ("food", "食物与饮品", "🍎"),
    "Travel & Places": ("travel", "旅行与地点", "🚗"),
    "Activities": ("activities", "活动", "⚽️"),
    "Objects": ("objects", "物品", "💡"),
    "Symbols": ("symbols", "符号", "❤️"),
    "Flags": ("flags", "旗帜", "🏳️"),
}


def main() -> None:
    categories = []
    current = None
    for line in SOURCE.read_text(encoding="utf-8").splitlines():
        if line.startswith("# group: "):
            group = line.removeprefix("# group: ")
            identifier, title, icon = GROUPS[group]
            current = {"id": identifier, "title": title, "icon": icon, "emojis": []}
            categories.append(current)
            continue
        if current is None or line.startswith("#") or not (
            "; fully-qualified" in line or "; component" in line
        ):
            continue
        codepoints = line.split(";", 1)[0].strip().split()
        current["emojis"].append("".join(chr(int(point, 16)) for point in codepoints))

    assert len(categories) == len(GROUPS)
    count = sum(len(group["emojis"]) for group in categories)
    assert count == 3953
    assert all(group["emojis"] for group in categories)
    DESTINATION.write_text(json.dumps(categories, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")
    print(f"Wrote {DESTINATION}: {len(categories)} categories, {count} emoji")


if __name__ == "__main__":
    main()
