import Foundation

/// Chinese-mode punctuation; URL/number entry can keep ASCII punctuation explicitly.
public struct DesktopPunctuation: Sendable {
    private var doubleQuoteOpen = true
    private var singleQuoteOpen = true
    public init() {}
    public mutating func reset() { doubleQuoteOpen = true; singleQuoteOpen = true }
    public mutating func convert(_ key: String, ascii: Bool = false) -> String? {
        guard !ascii else { return nil }
        if key == "\"" {
            defer { doubleQuoteOpen.toggle() }
            return doubleQuoteOpen ? "“" : "”"
        }
        if key == "'" {
            defer { singleQuoteOpen.toggle() }
            return singleQuoteOpen ? "‘" : "’"
        }
        return [",": "，", ".": "。", "?": "？", "!": "！", ":": "：", ";": "；",
                "(": "（", ")": "）", "<": "《", ">": "》", "[": "【", "]": "】",
                "\\": "、", "^": "……", "_": "——", "`": "·", "~": "～"][key]
    }
}
