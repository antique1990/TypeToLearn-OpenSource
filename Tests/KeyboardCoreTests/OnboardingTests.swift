import XCTest
@testable import KeyboardCore

final class OnboardingTests: XCTestCase {
    func testNineKeyPreviewShowsPinyinAtEveryKeystrokeAndPreservesSelectedWords() {
        for sample in 0..<KeyboardDemo.count {
            let digits = KeyboardDemo.input(sample, english: false, layout: .nineKey)
            let pinyin = KeyboardDemo.input(sample, english: false, layout: .pinyin)
            for length in 0...digits.count {
                let display = KeyboardDemo.displayInput(String(digits.prefix(length)), sample: sample, english: false, layout: .nineKey)
                XCTAssertEqual(display, String(pinyin.prefix(length)))
                XCTAssertFalse(display.contains(where: { $0.isNumber }))
            }
        }
        XCTAssertEqual(KeyboardDemo.displayInput("谢谢", sample: 0, english: false, layout: .nineKey), "谢谢")
        XCTAssertEqual(KeyboardDemo.displayInput("hello", sample: 0, english: true, layout: .nineKey), "hello")
        XCTAssertEqual(KeyboardDemo.displayInput("a", sample: 0, english: false, layout: .cangjie), "日")
    }

    func testEnglishAudienceOverridesSystemLocaleAndSurvivesRestoration() throws {
        for system in OnboardingLocale.allCases {
            var state = OnboardingState()
            XCTAssertEqual(system.resolved(for: state.audience), system)
            state.chooseAudience(.english)
            XCTAssertEqual(system.resolved(for: state.audience), .english)
            let restored = try JSONDecoder().decode(OnboardingState.self, from: JSONEncoder().encode(state))
            XCTAssertEqual(system.resolved(for: restored.audience), .english)
            state.chooseAudience(.chinese)
            XCTAssertEqual(system.resolved(for: state.audience), system)
        }
    }

    func testSystemLanguageChoosesChineseScriptAndEnglishFallback() {
        for id in ["zh", "zh-CN", "zh-SG", "zh-Hans-US"] {
            XCTAssertEqual(OnboardingLocale(preferredLanguages: [id]), .simplified, id)
        }
        for id in ["zh-TW", "zh-HK", "zh-MO", "zh-Hant-CN"] {
            XCTAssertEqual(OnboardingLocale(preferredLanguages: [id]), .traditional, id)
        }
        XCTAssertEqual(OnboardingLocale(preferredLanguages: ["en-GB"]), .english)
        XCTAssertEqual(OnboardingLocale(preferredLanguages: ["fr-FR", "zh-Hans"]), .english)
        XCTAssertEqual(OnboardingLocale(preferredLanguages: []), .english)
    }

    func testProgressResumesWithoutTreatingDownloadRequestAsCompletion() throws {
        var state = OnboardingState()
        state.chooseAudience(.english)
        state.targetLanguageID = "th"
        state.step = .enable
        state.requestedPairs.insert("en>th")
        let restored = try JSONDecoder().decode(OnboardingState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored, state)
        XCTAssertTrue(restored.hasRequestedSelectedPair)
        XCTAssertFalse(restored.completed)
        state.targetLanguageID = "ja"
        XCTAssertFalse(state.hasRequestedSelectedPair)
        state.chooseAudience(.chinese)
        XCTAssertNil(state.targetLanguageID)
        state.targetLanguageID = "th"
        XCTAssertFalse(state.hasRequestedSelectedPair, "English downloads cannot complete a Chinese language pairing")
    }

    func testApplyingChoicePreservesOtherInputSettings() {
        var settings = KeyboardSettings()
        settings.layout = .cangjie
        settings.script = .traditional
        settings.targetLanguageID = "ja"
        settings.englishTargetLanguageID = "th"
        var state = OnboardingState()
        state.chooseAudience(.english)
        state.targetLanguageID = "fr"
        var updated = state.applying(to: settings)
        XCTAssertEqual(updated.audience, .english)
        XCTAssertEqual(updated.englishTargetLanguageID, "fr")
        XCTAssertEqual(updated.targetLanguageID, "ja")
        XCTAssertEqual(updated.layout, .cangjie)
        XCTAssertEqual(updated.script, .traditional)
        state.chooseAudience(.chinese)
        state.script = .traditional
        state.targetLanguageID = "en"
        updated = state.applying(to: updated)
        XCTAssertEqual(updated.targetLanguageID, "en")
        XCTAssertEqual(updated.englishTargetLanguageID, "fr")
        XCTAssertEqual(updated.layout, .cangjie)
    }

    func testExamplesFollowLanguageAndScriptWithoutFabricatingUnknownTranslations() {
        XCTAssertEqual(OnboardingSample.translation(for: "en-US"), "How are you?")
        XCTAssertEqual(OnboardingSample.translation(for: "zh-TW"), "你好嗎？")
        XCTAssertEqual(OnboardingSample.translation(for: "zh-CN"), "你好吗？")
        XCTAssertEqual(OnboardingSample.translation(for: "th"), "คุณสบายดีไหม")
        XCTAssertNil(OnboardingSample.translation(for: "xx"))
    }
    func testEveryPreviewLanguageHasFivePhraseAndCangjieExamples() {
        XCTAssertGreaterThanOrEqual(KeyboardDemo.supportedLanguageIDs.count, 30)
        for language in KeyboardDemo.supportedLanguageIDs {
            for index in 0..<KeyboardDemo.count {
                for cangjie in [false, true] {
                    XCTAssertFalse(KeyboardDemo.translation(index, language: language, cangjie: cangjie)?.isEmpty ?? true, "\(language) / \(index)")
                }
            }
        }
        XCTAssertEqual(KeyboardDemo.translation(4, language: "zh-TW"), "再見")
        XCTAssertEqual(KeyboardDemo.translation(1, language: "nb-NO"), "Hei")
        XCTAssertNil(KeyboardDemo.translation(0, language: "xx"))
        XCTAssertNil(KeyboardDemo.translation(5, language: "en"))
    }

    func testDemoSourcesMatchLayoutsAndOmitRawJoinedEnglishCandidate() {
        for index in 0..<KeyboardDemo.count {
            let pinyin = KeyboardDemo.input(index, english: false, layout: .pinyin)
            XCTAssertEqual(KeyboardDemo.input(index, english: false, layout: .nineKey), KeyCoding.nineKey(pinyin))
            let code = KeyboardDemo.input(index, english: false, layout: .cangjie)
            XCTAssertEqual(String(KeyCoding.cangjieRoots[code.first!]!), KeyboardDemo.source(index, english: false, script: .traditional, cangjie: true))
            let joined = KeyboardDemo.input(index, english: true, layout: .nineKey)
            let candidates = KeyboardDemo.candidates(index, english: true, script: .simplified)
            if joined != candidates.first { XCTAssertFalse(candidates.contains(joined)) }
            XCTAssertGreaterThan(candidates.count, 1)
        }
    }

}
