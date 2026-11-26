import XCTest
@testable import KeyboardCore

final class EnglishLanguageModelTests: XCTestCase {
    private let model = EnglishLanguageModel.shared

    private func suggest(_ input: String, known: Bool = false) -> EnglishSuggestions {
        model.suggestions(for: input, knownWord: known, completions: [], corrections: [])
    }

    func testMissingSpacesReplaceRedundantRawCandidate() {
        for (input, expected) in [("youare", "you are"), ("iloveyou", "I love you"),
                                  ("howareyou", "how are you"), ("thankyou", "thank you"),
                                  ("goodmorning", "good morning"), ("seeyoutomorrow", "see you tomorrow")] {
            let result = suggest(input)
            XCTAssertEqual(result.words.first, expected, input)
            XCTAssertFalse(result.words.contains(input), input)
            XCTAssertEqual(result.automaticReplacement, expected, input)
        }
    }

    func testCapitalizationAndNames() {
        XCTAssertEqual(suggest("Youare").words.first, "You are")
        XCTAssertEqual(suggest("YOUARE").words.first, "YOU ARE")
        XCTAssertEqual(suggest("youAre").words, ["youAre"])
        XCTAssertNil(suggest("something", known: true).automaticReplacement)
        XCTAssertEqual(suggest("today", known: true).words.first, "today")
        XCTAssertEqual(suggest("therapist", known: true).words, ["therapist"])
    }

    func testUnsupportedAndAmbiguousInputIsNeverAutomaticallyRewritten() {
        for input in ["xyzq", "a1b2", "hello@example.com", "你好", String(repeating: "a", count: 33)] {
            XCTAssertEqual(suggest(input).words, [input])
            XCTAssertNil(suggest(input).automaticReplacement)
        }
        // Both are words, but this is not a known phrase: candidate only.
        XCTAssertNil(suggest("waterphone").automaticReplacement)
    }

    func testSystemCorrectionsAndCompletionsRemainAvailable() {
        let result = model.suggestions(for: "appli", knownWord: false,
            completions: ["application", "application", "applied"], corrections: ["apply"])
        XCTAssertTrue(result.words.contains("application"))
        XCTAssertTrue(result.words.contains("apply"))
        XCTAssertTrue(result.words.contains("appli"))
        XCTAssertEqual(result.words.filter { $0 == "application" }.count, 1)
        XCTAssertNil(result.automaticReplacement)
        let spacing = model.suggestions(for: "alot", knownWord: false, completions: [], corrections: ["a lot"])
        XCTAssertTrue(spacing.words.contains("a lot"))
        XCTAssertFalse(spacing.words.contains("alot"))
    }

    func testNextWordsAndContextBoundaries() {
        XCTAssertTrue(model.predictions(after: "you ").contains("are"))
        XCTAssertTrue(model.predictions(after: "I love ").contains("you"))
        XCTAssertTrue(model.predictions(after: "thank ").contains("you"))
        XCTAssertTrue(model.predictions(after: "you are ").contains("ready"))
        let matching = model.predictions(after: "you ", prefix: "ar")
        XCTAssertEqual(matching.first, "are")
        XCTAssertTrue(matching.allSatisfy { $0.hasPrefix("ar") })
        for context in ["", "you. ", "you\n", "you!", "你好"] {
            XCTAssertTrue(model.predictions(after: context).isEmpty, context)
        }
        let result = model.suggestions(for: "ar", context: "you ", knownWord: false,
            completions: ["arm"], corrections: [])
        XCTAssertTrue(result.words.contains("are"))
    }

    func testPhraseTranslationEligibility() {
        for text in ["you are", "I love you", "don't worry", "I'm ready", "it’s fine", "hello"] {
            XCTAssertTrue(EnglishLanguageModel.isEnglishText(text), text)
        }
        for text in ["", " you", "you  are", "you ", "hello@example.com", "abc123", "你好", "a\nb"] {
            XCTAssertFalse(EnglishLanguageModel.isEnglishText(text), text)
        }
    }
}
