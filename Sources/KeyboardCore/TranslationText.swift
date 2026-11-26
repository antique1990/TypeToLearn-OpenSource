import Foundation

public enum TranslationText {
    /// Repair a one-letter error in a three-character Chinese name that the
    /// translator has already chosen to romanize. Ordinary translations stay intact.
    public static func correctedRomanization(_ translation: String, for text: String,
                                              sourceID: String, targetID: String) -> String {
        guard sourceID.hasPrefix("zh"), targetID.hasPrefix("en"), text.count == 3 else { return translation }
        let scalars = text.unicodeScalars
        guard scalars.allSatisfy({ (0x3400...0x9FFF).contains($0.value) }) else { return translation }
        let syllables = text.map { character -> String? in
            guard let latin = String(character).applyingTransform(.mandarinToLatin, reverse: false) else { return nil }
            let plain = latin.folding(options: .diacriticInsensitive, locale: Locale(identifier: "zh_CN")).lowercased()
            return plain.allSatisfy { $0.isASCII && $0.isLetter } ? plain : nil
        }
        guard syllables.allSatisfy({ $0 != nil }) else { return translation }
        let pinyin = syllables.compactMap { $0 }
        let words = translation.split(separator: " ").map(String.init)
        guard words.count == 2, words[0].lowercased() == pinyin[0],
              words.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isLetter } }) else { return translation }
        let expected = pinyin.dropFirst().joined()
        let actual = words[1].lowercased()
        guard actual.count == expected.count,
              zip(actual, expected).filter({ $0.0 != $0.1 }).count == 1 else { return translation }
        return "\(words[0]) \(expected.prefix(1).uppercased())\(expected.dropFirst())"
    }
}
