import Foundation

/// One policy for verified keyboard slips on Mac, including sentence repairs. Sound aliases
/// belong to Rime's configured fuzzy policy, not to keyboard typo correction.
enum DesktopPinyinCorrection {
    // The bundled compact phrase table stores codes through 13 letters. One
    // extra letter permits duplicate-key recovery; this never limits raw input.
    static let inputLengths = 3...14

    static func variants(for raw: String) -> [String] {
        guard inputLengths.contains(raw.count), !raw.contains("'") else { return [] }
        return PinyinTolerance.rankedVariants(of: raw, maximumLength: inputLengths.upperBound,
            minimumLength: inputLengths.lowerBound, missingLetters: "abcdefghijklmnopqrstuvwxyz", maximumVariants: Int.max)
            .filter { !$0.phonetic }.map(\.code)
    }

    static func merge(_ repairs: [Candidate], into native: [Candidate], limit: Int,
                      useRepairedFullInput: Bool) -> [Candidate] {
        guard !repairs.isEmpty else { return native }
        let readings = Set(repairs.map(\.reading))
        let unambiguous = readings.count == 1
        // Several plausible spellings remain alternatives; frequency of one
        // word alone is not enough to silently decide the intended spelling.
        let leading = Array(native.prefix(unambiguous ? 0 : 1))
        let corrections = repairs.filter { repair in !leading.contains { $0.text == repair.text } }
        let correctedTexts = Set(corrections.map(\.text))
        let maximumCharacters = repairs.map { $0.text.count }.max() ?? 0
        let remaining = native.dropFirst(leading.count).filter {
            !correctedTexts.contains($0.text) &&
            !(unambiguous && $0.engineIndex != nil && $0.coversFullInput == true &&
              (useRepairedFullInput || $0.text.count > maximumCharacters))
        }
        return Array((leading + corrections + remaining).prefix(limit))
    }
}
