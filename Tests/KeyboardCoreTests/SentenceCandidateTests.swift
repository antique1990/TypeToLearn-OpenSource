import XCTest
@testable import KeyboardCore

final class SentenceCandidateTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testPinyinDoesNotBecomeEnglishWithoutWordEvidence() {
        for raw in ["nanixiandebazimeitizuoqilau", "nanidexianbazimeitizuoqilai", "uu", "nihao"] {
            let known = EnglishSuggestionPolicy.hasWordEvidence(for: raw, dictionaryKnown: false, completions: [])
            XCTAssertFalse(known)
            XCTAssertTrue(EnglishSuggestionPolicy.suggestions(for: raw, knownWord: known,
                completions: [], englishMode: false).isEmpty)
        }
        XCTAssertTrue(EnglishSuggestionPolicy.hasWordEvidence(for: "app", dictionaryKnown: true, completions: []))
        XCTAssertTrue(EnglishSuggestionPolicy.hasWordEvidence(for: "iPhone", dictionaryKnown: false, completions: ["iphone"]))
        XCTAssertFalse(EnglishSuggestionPolicy.hasWordEvidence(for: "appli", dictionaryKnown: false, completions: ["application"]))
        XCTAssertEqual(EnglishSuggestionPolicy.suggestions(for: "uu", knownWord: false, completions: [], englishMode: true), ["uu"])
    }

    func testExactPinyinPrecedesLongerEnglishCompletions() async throws {
        let lexicon = try Lexicon(url: root.appendingPathComponent("Resources/lexicon.sqlite"))
        for script in [ChineseScript.simplified, .traditional] {
            for (code, completion) in [("bushi", "Bushings"), ("cang", "cangue")] {
                let pinyin = try await lexicon.candidates(for: code, layout: .pinyin, script: script)
                let first = try XCTUnwrap(pinyin.first)
                if code == "bushi" { XCTAssertEqual(first.text, "不是") }
                let exact = await lexicon.hasExactPinyinReading(code, script: script)
                XCTAssertTrue(exact, code)
                let result = EnglishSuggestionPolicy.mergingMixedSuggestion(completion, for: code,
                    into: pinyin, hasExactPinyinReading: exact)
                XCTAssertEqual(result.prefix(2).map(\.text), [first.text, completion])
            }
        }
        for (code, english, matchesPinyin) in [("like", "like", true), ("appli", "application", false)] {
            let pinyin = try await lexicon.candidates(for: code, layout: .pinyin, script: .simplified)
            let exact = await lexicon.hasExactPinyinReading(code, script: .simplified)
            XCTAssertEqual(exact, matchesPinyin)
            let result = EnglishSuggestionPolicy.mergingMixedSuggestion(english, for: code,
                into: pinyin, hasExactPinyinReading: exact)
            XCTAssertEqual(result.first?.text, english)
        }
    }

    func testExactEnglishEvidenceSuppressesGuessedPinyin() {
        let repair = Candidate(text: "皮佛了", reading: "pihone", consumed: 6)
        let found = EnglishSuggestionPolicy.mergingMixedSuggestion("iphone", for: "iphone", into: [repair],
                                                                   hasExactPinyinReading: false)
        XCTAssertEqual(found, [Candidate(text: "iphone", reading: "iphone", consumed: 6)])
    }

    func testSentenceCandidatesResolveWithoutForcedRanking() async throws {
        let lexicon = try Lexicon(url: root.appendingPathComponent("Resources/lexicon.sqlite"))
        for raw in ["nanidexianbazimeitizuoqilai", "nanideixianbazimeitizuoqilai", "wozuozimeiti"] {
            let found = try await lexicon.candidates(for: raw, layout: .pinyin, script: .simplified)
            let selected = try XCTUnwrap(found.first)
            XCTAssertTrue(selected.text.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) })
            let resolution = await lexicon.resolve(selected, for: raw, layout: .pinyin, script: .simplified)
            let resolved = try XCTUnwrap(resolution)
            XCTAssertEqual(resolved.consumed, raw.count)
            var composition = Composition()
            composition.append(raw)
            XCTAssertEqual(composition.commit(resolved), selected.text)
            XCTAssertTrue(composition.input.isEmpty)
        }
        await lexicon.close()
    }

    func testSelfMediaAcrossScriptsAndLayouts() async throws {
        let lexicon = try Lexicon(url: root.appendingPathComponent("Resources/lexicon.sqlite"))
        for script in [ChineseScript.simplified, .traditional] {
            for layout in [KeyboardLayout.pinyin, .nineKey] {
                let raw = layout == .pinyin ? "zimeiti" : KeyCoding.nineKey("zimeiti")
                let found = try await lexicon.candidates(for: raw, layout: layout, script: script)
                XCTAssertTrue(found.contains { $0.text == (script == .simplified ? "自媒体" : "自媒體") })
            }
        }
        await lexicon.close()
    }

    func testLearnedSentenceDoesNotDuplicateEngineCandidate() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sentence-learned-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let lexicon = try Lexicon(url: root.appendingPathComponent("Resources/lexicon.sqlite"), learnedURL: file)
        let raw = "nihao"
        let sentence = "你好"
        try await lexicon.learn(code: raw, text: sentence, layout: .pinyin, script: .simplified)
        let candidates = try await lexicon.candidates(for: raw, layout: .pinyin, script: .simplified)
        XCTAssertEqual(candidates.filter { $0.text == sentence }.count, 1)
        XCTAssertEqual(candidates.first?.text, sentence)
        XCTAssertEqual(candidates.first?.consumed, raw.count)
        await lexicon.close()
    }
}
