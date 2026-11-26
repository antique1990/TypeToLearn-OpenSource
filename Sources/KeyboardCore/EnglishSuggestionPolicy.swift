import Foundation

/// Keeps English suggestions useful without crowding Chinese conversions.
public enum EnglishSuggestionPolicy {
    public static func mergingMixedSuggestion(_ word: String, for input: String, into pinyin: [Candidate],
                                               hasExactPinyinReading: Bool, limit: Int? = nil) -> [Candidate] {
        let candidate = Candidate(text: word, reading: input, consumed: input.count)
        let isCompletion = word.lowercased() != input.lowercased()
        let candidates = isCompletion ? pinyin : pinyin.filter { $0.reading == input }
        guard !candidates.contains(where: { $0.text == word }) else { return candidates }
        let merged: [Candidate]
        if let first = candidates.first, first.engineIndex == nil || (isCompletion && hasExactPinyinReading) {
            merged = [first, candidate] + candidates.dropFirst()
        } else {
            merged = [candidate] + candidates
        }
        return Array(merged.prefix(limit ?? max(48, pinyin.count + 1)))
    }

    /// Spell checkers can ignore unknown tokens without reporting a misspelling.
    /// Only a dictionary hit or an exact completion establishes word evidence.
    public static func hasWordEvidence(for input: String, dictionaryKnown: Bool, completions: [String]) -> Bool {
        guard !input.isEmpty, input.count <= 32,
              input.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.letters.contains($0) }) else { return false }
        return dictionaryKnown || completions.contains { $0.lowercased() == input.lowercased() }
    }

    public static func suggestions(
        for input: String,
        knownWord: Bool,
        completions: [String],
        englishMode: Bool
    ) -> [String] {
        guard !input.isEmpty, input.count <= 32,
              input.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) && $0.isASCII })
        else { return englishMode && !input.isEmpty ? [input] : [] }

        let lower = input.lowercased()
        if !englishMode && lower == "i" { return ["I"] }
        var seen = Set<String>()
        let matches = completions.filter { word in
            let normalized = word.lowercased()
            return word.count <= 32 && normalized.count > lower.count &&
                normalized.hasPrefix(lower) &&
                word.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) && $0.isASCII }) &&
                seen.insert(normalized).inserted
        }
        if englishMode { return [input] + matches.prefix(3) }
        guard input.count >= 3 else { return [] }
        if knownWord { return [input] }
        guard input.count >= 4, let best = matches.first else { return [] }
        return [best]
    }
}
