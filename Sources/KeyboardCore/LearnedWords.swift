import Foundation

public struct LearnedWord: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var code: String
    public var text: String
    public var layout: KeyboardLayout
    public var script: ChineseScript
    public var useCount: Int
    public var updatedAt: Date
    // Older/custom entries have no restriction. Aliases learned with fuzzy
    // input must not make a disabled rule silently continue matching.
    public var requiredFuzzyOptions: PinyinFuzzyOptions?
}

/// A small, explicit user dictionary. Only selected Chinese segments are learned.
public struct LearnedWords: Codable, Sendable {
    public private(set) var items: [LearnedWord] = []
    public init() {}

    public mutating func learn(code: String, text: String, layout: KeyboardLayout, script: ChineseScript,
                               pinyinPolicy: PinyinQueryPolicy = .legacy) {
        guard code.count >= 2, code.count <= Composition.maximumLength,
              !text.isEmpty, text.count <= 128,
              text.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) })
        else { return }
        let code = code.lowercased()
        let required: PinyinFuzzyOptions?
        if layout != .cangjie, let options = pinyinPolicy.fuzzyOptions, !options.isEmpty {
            required = options.intersection(.all)
        } else { required = nil }
        if let index = items.firstIndex(where: {
            $0.code == code && $0.text == text && $0.layout == layout && $0.script == script &&
            $0.requiredFuzzyOptions == required
        }) {
            var word = items.remove(at: index)
            word.useCount += 1
            word.updatedAt = Date()
            items.insert(word, at: 0)
        } else {
            items.insert(LearnedWord(id: UUID(), code: code, text: text, layout: layout,
                                     script: script, useCount: 1, updatedAt: Date(), requiredFuzzyOptions: required), at: 0)
        }
        if items.count > 3000 { items.removeLast(items.count - 3000) }
    }

    public mutating func remove(_ id: UUID) { items.removeAll { $0.id == id } }
    public mutating func removeAll() { items.removeAll() }

    public func candidates(for code: String, layout: KeyboardLayout, script: ChineseScript,
                           pinyinPolicy: PinyinQueryPolicy = .legacy) -> [Candidate] {
        var seen = Set<String>()
        return items.filter { word in
            guard word.code == code, word.layout == layout, word.script == script else { return false }
            if let required = word.requiredFuzzyOptions, !required.isEmpty {
                guard let enabled = pinyinPolicy.fuzzyOptions, enabled.isSuperset(of: required) else { return false }
            }
            return seen.insert(word.text).inserted
        }.map { Candidate(text: $0.text, reading: $0.code, consumed: code.count) }
    }

    public static func load(from url: URL) -> LearnedWords {
        guard let data = try? Data(contentsOf: url),
              let words = try? JSONDecoder().decode(LearnedWords.self, from: data) else { return LearnedWords() }
        return words
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// Translations for explicitly learned words, kept separately from their input codes.
public struct LearnedTranslations: Codable, Sendable {
    private struct Entry: Codable, Sendable {
        let text: String
        let sourceID: String
        let targetID: String
        let translation: String
    }

    private var entries: [Entry] = []
    public init() {}

    public func value(for text: String, sourceID: String, targetID: String) -> String? {
        entries.last {
            $0.text == text && $0.sourceID == sourceID && $0.targetID == targetID
        }?.translation
    }

    public mutating func insert(_ translation: String, for text: String, sourceID: String, targetID: String) {
        guard !text.isEmpty, !translation.isEmpty else { return }
        entries.removeAll { $0.text == text && $0.sourceID == sourceID && $0.targetID == targetID }
        entries.append(Entry(text: text, sourceID: sourceID, targetID: targetID, translation: translation))
        if entries.count > 384 { entries.removeFirst(entries.count - 384) }
    }

    public mutating func retain(texts: Set<String>) {
        entries.removeAll { !texts.contains($0.text) }
    }

    public static func load(from url: URL) -> LearnedTranslations {
        guard let data = try? Data(contentsOf: url),
              let translations = try? JSONDecoder().decode(LearnedTranslations.self, from: data)
        else { return LearnedTranslations() }
        return translations
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
