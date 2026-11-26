import Foundation
import KeyboardCore

public enum DesktopCandidateCategory: String, CaseIterable, Sendable, Identifiable {
    case frequency, radical, strokes, decomposition, emoji
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .frequency: "词频"
        case .radical: "部首"
        case .strokes: "笔画"
        case .decomposition: "拆字"
        case .emoji: "表情"
        }
    }
}

public struct DesktopEmojiCategory: Decodable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let icon: String
    public let emojis: [String]
}

/// Mac-only presentation metadata. Sorting retains the original Rime candidate
/// object, including the engine index and how much input it consumes.
public struct DesktopCandidateCatalog: Sendable {
    private struct CharacterInfo: Decodable, Sendable {
        let radical: String?
        let radicalNumber: Int?
        let strokes: Int?
        let decomposition: String?
    }
    private struct EmojiIndex: Decodable, Sendable {
        let names: [String: String]
        let keywords: [String: [String]]
    }
    private let characters: [String: CharacterInfo]
    private let emojiIndex: EmojiIndex
    private let structuralPinyin: [String: [String]]
    private let allEmoji: [String]
    private let emojiSet: Set<String>
    public let emojiCategories: [DesktopEmojiCategory]

    public init(metadataURL: URL? = Bundle.main.url(forResource: "character-metadata", withExtension: "json"),
                emojiURL: URL? = Bundle.main.url(forResource: "emoji-catalog", withExtension: "json"),
                emojiIndexURL: URL? = Bundle.main.url(forResource: "emoji-keywords", withExtension: "json"),
                structuralURL: URL? = Bundle.main.url(forResource: "structural-pinyin", withExtension: "json")) {
        func decode<T: Decodable>(_ type: T.Type, from url: URL?) -> T? {
            guard let url, let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(type, from: data)
        }
        characters = decode([String: CharacterInfo].self, from: metadataURL) ?? [:]
        emojiCategories = decode([DesktopEmojiCategory].self, from: emojiURL) ?? []
        emojiIndex = decode(EmojiIndex.self, from: emojiIndexURL) ?? EmojiIndex(names: [:], keywords: [:])
        structuralPinyin = decode([String: [String]].self, from: structuralURL) ?? [:]
        var seen = Set<String>()
        allEmoji = emojiCategories.flatMap(\.emojis).filter { seen.insert($0).inserted }
        emojiSet = seen
    }

    public func isEmoji(_ text: String) -> Bool { emojiSet.contains(text) }
    public func emojiName(for text: String) -> String? { emojiIndex.names[text] }

    /// Exact keyword/pinyin matches. Short prefixes do not flood ordinary Pinyin
    /// candidates with unrelated emoji; the 表情 category always offers browsing.
    public func emojiSuggestions(for input: String) -> [String] {
        emojiIndex.keywords[Self.normalized(input)] ?? []
    }

    public func candidates(from base: [Candidate], input: String, category: DesktopCandidateCategory) -> [Candidate] {
        let suggestions = emojiSuggestions(for: input)
        if category == .emoji {
            return (suggestions.isEmpty ? allEmoji : suggestions).map {
                Candidate(text: $0, reading: input, consumed: input.count)
            }
        }
        if category == .decomposition {
            return (structuralPinyin[Self.normalized(input)] ?? []).map {
                Candidate(text: $0, reading: input, consumed: input.count)
            }
        }
        if category == .frequency {
            let existing = Set(base.map(\.text))
            let extra = suggestions.filter { !existing.contains($0) }.prefix(5).map {
                Candidate(text: $0, reading: input, consumed: input.count)
            }
            // Keep the first three Rime choices and every original relative order.
            let split = min(3, base.count)
            return Array(base.prefix(split)) + extra + base.dropFirst(split)
        }
        return base.enumerated().sorted { a, b in
            switch category {
            case .radical:
                let x = firstInfo(a.element.text)?.radicalNumber ?? Int.max
                let y = firstInfo(b.element.text)?.radicalNumber ?? Int.max
                if x != y { return x < y }
            case .strokes:
                let x = totalStrokes(a.element.text) ?? Int.max
                let y = totalStrokes(b.element.text) ?? Int.max
                if x != y { return x < y }
            default: break
            }
            return a.offset < b.offset
        }.map(\.element)
    }

    public func annotation(for text: String, category: DesktopCandidateCategory) -> String? {
        switch category {
        case .frequency: return isEmoji(text) ? emojiName(for: text) : nil
        case .emoji: return emojiName(for: text)
        case .radical: return firstInfo(text)?.radical.map { "\($0)部" }
        case .strokes: return totalStrokes(text).map { "\($0)画" }
        case .decomposition:
            guard let first = text.first, let value = firstInfo(text)?.decomposition else { return nil }
            return text.count == 1 ? value : "\(first)：\(value)"
        }
    }

    private func firstInfo(_ text: String) -> CharacterInfo? {
        text.first.flatMap { characters[String($0)] }
    }
    private func totalStrokes(_ text: String) -> Int? {
        guard !text.isEmpty else { return nil }
        var count = 0
        for character in text {
            guard let value = characters[String(character)]?.strokes else { return nil }
            count += value
        }
        return count
    }
    private static func normalized(_ input: String) -> String {
        input.lowercased().replacingOccurrences(of: "'", with: "")
            .filter { !$0.isWhitespace }
    }
}
