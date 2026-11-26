import AppKit
import CoreText

// Native physical-Mac probe. Input is a JSON array of dictionary characters;
// output is a pinned build-time exclusion profile, not a runtime font dependency.
let characters = try JSONDecoder().decode([String].self, from: Data(contentsOf:
    URL(fileURLWithPath: CommandLine.arguments[1])))
let font = NSFont.systemFont(ofSize: 16, weight: .regular)
var excluded: [String] = []
for character in characters {
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: character, attributes: [.font: font]))
    let missing = (CTLineGetGlyphRuns(line) as! [CTRun]).contains { run in
        let attributes = CTRunGetAttributes(run) as NSDictionary
        let fallback = attributes[kCTFontAttributeName] as! CTFont
        if CTFontCopyPostScriptName(fallback) as String == "LastResort" { return true }
        var glyphs = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
        CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
        return glyphs.contains(0)
    }
    if missing { excluded.append(character) }
}
let report: [String: Any] = [
    "version": 1,
    "platform": ProcessInfo.processInfo.operatingSystemVersionString,
    "font": "system 16pt regular with native CoreText fallback",
    "criterion": "LastResort font or glyph zero",
    "scannedCharacterCount": characters.count,
    "excludedCharacterCount": excluded.count,
    "characters": excluded.joined()
]
try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    .write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
print("Scanned \(characters.count) characters; excluded \(excluded.count) without a usable system glyph")
