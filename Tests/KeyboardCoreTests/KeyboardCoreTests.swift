import XCTest
@testable import KeyboardCore

final class KeyboardCoreTests: XCTestCase {
    func testNineKeyMappings() {
        XCTAssertEqual(KeyCoding.nineKey("nihao"), "64426")
        XCTAssertEqual(KeyCoding.nineKey("pingguo"), "7464486")
        XCTAssertEqual(KeyCoding.nineKey("lv"), "58")
        XCTAssertEqual(KeyCoding.nineKeyFallback("644269999"), "niianyyyy")
        XCTAssertEqual(KeyCoding.nineKey(KeyCoding.nineKeyFallback("644269999")), "644269999")
    }

    func testCompositionConsumesOnlySelectedPrefix() {
        var composition = Composition()
        composition.append("nihaoshijie")
        XCTAssertEqual(composition.commit(Candidate(text: "你好", reading: "ni hao", consumed: 5)), "你好")
        XCTAssertEqual(composition.input, "shijie")
    }

    func testApostropheAfterCommittedSegmentIsRemoved() {
        var composition = Composition()
        composition.append("nihao'shijie")
        _ = composition.commit(Candidate(text: "你好", reading: "ni hao", consumed: 5))
        XCTAssertEqual(composition.input, "shijie")
    }

    func testBackspacePreservesHostWhileComposing() {
        var composition = Composition()
        composition.append("ni")
        XCTAssertFalse(composition.backspace())
        XCTAssertEqual(composition.input, "n")
        XCTAssertFalse(composition.backspace())
        XCTAssertTrue(composition.backspace())
    }

    func testCompositionCursorCorrectsMissingPinyinInPlace() async throws {
        var composition = Composition()
        composition.append("niquali")
        composition.moveCursor(by: -3)
        XCTAssertEqual(composition.input, "niquali")
        XCTAssertEqual(composition.cursor, 4)
        XCTAssertTrue(composition.append("n"))
        XCTAssertEqual(composition.input, "niqunali")
        XCTAssertEqual(composition.cursor, 5)
        XCTAssertFalse(composition.backspace())
        XCTAssertEqual(composition.input, "niquali")
        XCTAssertEqual(composition.cursor, 4)
        composition.append("n")
        let lexicon = try Lexicon(url: lexiconURL)
        let found = try await lexicon.candidates(for: composition.input, layout: .pinyin, script: .simplified)
        let candidate = try XCTUnwrap(found.first { $0.text == "你去哪里" })
        let resolved = await lexicon.resolve(candidate, for: composition.input, layout: .pinyin, script: .simplified)
        XCTAssertEqual(composition.commit(try XCTUnwrap(resolved)), "你去哪里")
        XCTAssertEqual(composition.input, "")
        XCTAssertEqual(composition.cursor, 0)
    }

    func testCompositionCursorClampsAndProtectsHostAtBeginning() {
        var composition = Composition()
        composition.append("nihao")
        composition.moveCursor(by: .min)
        XCTAssertEqual(composition.cursor, 0)
        XCTAssertFalse(composition.backspace())
        XCTAssertEqual(composition.input, "nihao")
        XCTAssertFalse(composition.append("'"))
        composition.moveCursor(by: .max)
        XCTAssertEqual(composition.cursor, 5)
        composition.clear()
        XCTAssertEqual(composition.cursor, 0)
        XCTAssertTrue(composition.backspace())
    }

    func testCompositionCursorTracksPartialSelectionAndNineKeyEdits() {
        var composition = Composition()
        composition.append("nihao'shijie")
        composition.moveCursor(by: -3)
        XCTAssertEqual(composition.commit(Candidate(text: "你好", reading: "", consumed: 5)), "你好")
        XCTAssertEqual(composition.input, "shijie")
        XCTAssertEqual(composition.cursor, 3)
        composition.switchLayout(.nineKey)
        composition.append("6446")
        composition.moveCursor(by: -1)
        composition.append("2")
        XCTAssertEqual(composition.input, "64426")
        XCTAssertEqual(composition.cursor, 4)
    }

    func testComposingContextDistinguishesInsideFromOutsideTaps() {
        let context = ComposingTextContext(text: "niqunali", preceding: "你好 ", following: " 后文")
        XCTAssertEqual(context.editingCursor(preceding: "你好 niqu", following: "nali 后文", selected: nil), 4)
        XCTAssertEqual(context.editingCursor(preceding: "你好 ", following: "niqunali 后文", selected: ""), 0)
        XCTAssertNil(context.editingCursor(preceding: "你好 niqunali", following: " 后文", selected: nil))
        XCTAssertNil(context.editingCursor(preceding: "你", following: "好 niqunali 后文", selected: nil))
        XCTAssertNil(context.editingCursor(preceding: "你好 niqunali 后", following: "文", selected: nil))
        XCTAssertNil(context.editingCursor(preceding: nil, following: nil, selected: nil))
        XCTAssertNil(context.editingCursor(preceding: "你好 ni", following: "nali 后文", selected: "qu"))
        XCTAssertNil(context.editingCursor(preceding: "另一个输入框 niqu", following: "nali 后文", selected: nil))
    }

    func testComposingContextHandlesBoundedHostContextAndUpdatedCode() {
        var context = ComposingTextContext(text: "niquali", preceding: "前文", following: "后文")
        context.text = "niqunali"
        XCTAssertNil(context.editingCursor(preceding: "qu", following: "nali", selected: nil), "Never replace a span when the proxy cannot expose all of it")
        XCTAssertEqual(context.editingCursor(preceding: "前文niqun", following: "ali后文", selected: nil), 5)
        XCTAssertNil(context.editingCursor(preceding: "", following: "", selected: nil))
    }

    func testCompositionContextRecognizesEmptyDocumentEdgesAndExplicitEnd() {
        let context = ComposingTextContext(text: "hello", preceding: "", following: "")
        XCTAssertEqual(context.editingCursor(preceding: nil, following: "hello", selected: nil), 0)
        XCTAssertEqual(context.editingCursor(preceding: "he", following: "llo", selected: nil), 2)
        XCTAssertNil(context.editingCursor(preceding: "hello", following: nil, selected: nil))
        XCTAssertEqual(context.editingCursor(preceding: "hello", following: nil, selected: nil, includingEnd: true), 5)
        XCTAssertNil(context.editingCursor(preceding: nil, following: nil, selected: nil, includingEnd: true))
    }

    func testLayoutSwitchClearsCodeAndRejectsInvalidKeys() {
        var composition = Composition()
        composition.append("ni")
        composition.switchLayout(.nineKey)
        XCTAssertEqual(composition.input, "")
        XCTAssertFalse(composition.append("a"))
        XCTAssertFalse(composition.append("1"))
        XCTAssertTrue(composition.append("64426"))
    }

    func testCangjieLimitAndRootLabels() {
        var composition = Composition(layout: .cangjie)
        XCTAssertTrue(composition.append("abcde"))
        XCTAssertFalse(composition.append("f"))
        XCTAssertFalse(composition.append("'"))
        XCTAssertEqual(KeyCoding.display("a", layout: .cangjie), "日")
        XCTAssertEqual(KeyCoding.display("onf", layout: .cangjie), "人 弓 火")
    }

    func testInvalidCandidateCannotConsumeCode() {
        var composition = Composition()
        composition.append("ni")
        XCTAssertNil(composition.commit(Candidate(text: "你好", reading: "", consumed: 5)))
        XCTAssertEqual(composition.input, "ni")
    }

    func testCacheEvictsLeastRecentlyUsedAndNamespacesLanguages() {
        var cache = BoundedCache<String, String>(capacity: 2)
        cache.insert("manzana", for: "es|苹果")
        cache.insert("apple", for: "en|苹果")
        XCTAssertEqual(cache.value(for: "es|苹果"), "manzana")
        cache.insert("hola", for: "es|你好")
        XCTAssertNil(cache.value(for: "en|苹果"))
        XCTAssertEqual(cache.value(for: "es|苹果"), "manzana")
        XCTAssertEqual(cache.count, 2)
    }

    func testLearnedTranslationsPersistByLanguagePairAndFollowWordDeletion() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("learned-translations-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var translations = LearnedTranslations()
        translations.insert("hello", for: "你好", sourceID: "zh-Hans", targetID: "en")
        translations.insert("bonjour", for: "你好", sourceID: "zh-Hans", targetID: "fr")
        translations.insert("goodbye", for: "再见", sourceID: "zh-Hans", targetID: "en")
        try translations.save(to: url)

        var reopened = LearnedTranslations.load(from: url)
        XCTAssertEqual(reopened.value(for: "你好", sourceID: "zh-Hans", targetID: "en"), "hello")
        XCTAssertEqual(reopened.value(for: "你好", sourceID: "zh-Hans", targetID: "fr"), "bonjour")
        XCTAssertNil(reopened.value(for: "你好", sourceID: "zh-Hant", targetID: "en"))
        reopened.retain(texts: ["你好"])
        try reopened.save(to: url)
        XCTAssertNil(LearnedTranslations.load(from: url).value(for: "再见", sourceID: "zh-Hans", targetID: "en"))
    }

    func testNameRomanizationRepairsOnlyClosePinyinErrors() {
        XCTAssertEqual(TranslationText.correctedRomanization("Chen Jiaben", for: "陈佳文",
            sourceID: "zh-Hans", targetID: "en"), "Chen Jiawen")
        XCTAssertEqual(TranslationText.correctedRomanization("Chen Jiawen", for: "陈佳文",
            sourceID: "zh-Hans", targetID: "en"), "Chen Jiawen")
        XCTAssertEqual(TranslationText.correctedRomanization("Sediments", for: "陈家湾",
            sourceID: "zh-Hans", targetID: "en"), "Sediments")
        XCTAssertEqual(TranslationText.correctedRomanization("Chen Family", for: "陈佳文",
            sourceID: "zh-Hans", targetID: "en"), "Chen Family")
        XCTAssertEqual(TranslationText.correctedRomanization("Chen Jiaben", for: "陈佳文",
            sourceID: "zh-Hans", targetID: "fr"), "Chen Jiaben")
    }


    func testClipboardLimitsDuplicatesAndDeletion() throws {
        var clips = SavedClips()
        XCTAssertThrowsError(try clips.save("  \n"))
        XCTAssertThrowsError(try clips.save(String(repeating: "文", count: 2001)))
        try clips.save("  保留格式\n")
        try clips.save("  保留格式\n")
        XCTAssertEqual(clips.items.count, 1)
        XCTAssertEqual(clips.items[0].text, "  保留格式\n")
        for i in 1..<30 { try clips.save("text \(i)") }
        XCTAssertThrowsError(try clips.save("overflow"))
        clips.remove(clips.items[0].id)
        XCTAssertEqual(clips.items.count, 29)
        clips.removeAll()
        XCTAssertTrue(clips.items.isEmpty)
    }

    func testSettingsMigrationKeepsExistingChoices() throws {
        let old = #"{"layout":"nineKey","script":"traditional","targetLanguageID":"en","translationEnabled":true,"revision":"00000000-0000-0000-0000-000000000001"}"#
        let settings = try JSONDecoder().decode(KeyboardSettings.self, from: Data(old.utf8))
        XCTAssertEqual(settings.layout, .nineKey)
        XCTAssertEqual(settings.script, .traditional)
        XCTAssertEqual(settings.targetLanguageID, "en")
        XCTAssertEqual(settings.englishTargetLanguageID, "zh-Hans")
        XCTAssertFalse(settings.wrapCandidateTranslations)
        XCTAssertEqual(settings.audience, .chinese)
        XCTAssertFalse(settings.keySoundEnabled)
        XCTAssertEqual(settings.keySoundStyle, .crisp)
        XCTAssertEqual(settings.keySoundVolume, 0.75)
        XCTAssertFalse(settings.keyHapticsEnabled)
        XCTAssertEqual(settings.keyHapticStrength, .medium)
    }

    func testKeyFeedbackSettingsRoundTrip() throws {
        var settings = KeyboardSettings()
        settings.keySoundEnabled = true
        settings.keySoundStyle = .mechanical
        settings.keySoundVolume = 0.4
        settings.keyHapticsEnabled = true
        settings.keyHapticStrength = .strong
        let restored = try JSONDecoder().decode(KeyboardSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertTrue(restored.keySoundEnabled)
        XCTAssertEqual(restored.keySoundStyle, .mechanical)
        XCTAssertEqual(restored.keySoundVolume, 0.4)
        XCTAssertTrue(restored.keyHapticsEnabled)
        XCTAssertEqual(restored.keyHapticStrength, .strong)
    }

    func testAudienceModeRoundTripPreservesBothLanguageChoicesAndChineseLayout() throws {
        var settings = KeyboardSettings()
        settings.layout = .cangjie
        settings.script = .traditional
        settings.targetLanguageID = "ja"
        settings.englishTargetLanguageID = "th"
        settings.audience = .english
        let english = try JSONDecoder().decode(KeyboardSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertTrue(english.audience.isEnglishOnly)
        XCTAssertEqual(english.layout, .cangjie)
        XCTAssertEqual(english.targetLanguageID, "ja")
        XCTAssertEqual(english.englishTargetLanguageID, "th")
        var restored = english
        restored.audience = .chinese
        let chinese = try JSONDecoder().decode(KeyboardSettings.self, from: JSONEncoder().encode(restored))
        XCTAssertEqual(chinese.script, .traditional)
        XCTAssertEqual(chinese.targetLanguageID, "ja")
        XCTAssertEqual(chinese.englishTargetLanguageID, "th")
        XCTAssertEqual(chinese.audience.text("空格"), "空格")
        XCTAssertEqual(english.audience.text("空格"), "Space")
    }

    func testSelectedPhrasePersistsAndOutranksDictionary() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("learned-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let lexicon = try Lexicon(url: lexiconURL, learnedURL: url)
        try await lexicon.learn(code: "dise", text: "底色", layout: .pinyin, script: .simplified)
        let found = try await lexicon.candidates(for: "dise", layout: .pinyin, script: .simplified)
        XCTAssertEqual(found.first?.text, "底色")
        XCTAssertEqual(found.first?.consumed, 4)
        await lexicon.close()
        let reopened = try Lexicon(url: lexiconURL, learnedURL: url)
        let restartedCandidates = try await reopened.candidates(for: "dise", layout: .pinyin, script: .simplified)
        XCTAssertEqual(restartedCandidates.first?.text, "底色")
        var words = LearnedWords.load(from: url)
        XCTAssertEqual(words.items.count, 1)
        words.remove(words.items[0].id)
        try words.save(to: url)
        XCTAssertTrue(LearnedWords.load(from: url).items.isEmpty)
        await reopened.close()
    }

    func testEnglishSuggestionsStaySelectiveInChineseMode() {
        XCTAssertEqual(EnglishSuggestionPolicy.suggestions(for: "app", knownWord: true,
            completions: ["apple", "application"], englishMode: false), ["app"])
        XCTAssertEqual(EnglishSuggestionPolicy.suggestions(for: "appli", knownWord: false,
            completions: ["application", "applied", "other"], englishMode: false), ["application"])
        XCTAssertTrue(EnglishSuggestionPolicy.suggestions(for: "nihao", knownWord: false,
            completions: [], englishMode: false).isEmpty)
        XCTAssertTrue(EnglishSuggestionPolicy.suggestions(for: "sdh", knownWord: false,
            completions: [], englishMode: false).isEmpty)
        XCTAssertEqual(EnglishSuggestionPolicy.suggestions(for: "i", knownWord: true,
            completions: [], englishMode: false), ["I"])
        XCTAssertEqual(EnglishSuggestionPolicy.suggestions(for: "app", knownWord: true,
            completions: ["apple", "application"], englishMode: true), ["app", "apple", "application"])
    }

    func testPartialCandidateVisibilityForComposedPhrase() async throws {
        let lexicon = try Lexicon(url: lexiconURL)
        let found = try await lexicon.candidates(for: "dise", layout: .pinyin, script: .simplified)
        let bottom = try XCTUnwrap(found.firstIndex { $0.text == "底" })
        XCTAssertLessThan(bottom, 10)
        await lexicon.close()
    }

    func testPinyinPhraseRankingAndApostropheFallback() async throws {
        let lexicon = try Lexicon(url: lexiconURL)
        let phrases = try await lexicon.candidates(for: "shiti", layout: .pinyin, script: .simplified)
        XCTAssertEqual(Set(phrases.prefix(3).map(\.text)), Set(["尸体", "实体", "试题"]))
        let code = "n'z'g's'g"
        let candidates = try await lexicon.candidates(for: code, layout: .pinyin, script: .simplified)
        let first = try XCTUnwrap(candidates.first { $0.text == "你" && $0.consumed == 1 })
        XCTAssertLessThan(candidates.firstIndex(of: first) ?? 100, 10)
        var composition = Composition()
        composition.append(code)
        XCTAssertEqual(composition.commit(first), "你")
        XCTAssertEqual(composition.input, "z'g's'g")
        let second = try await lexicon.candidates(for: composition.input, layout: .pinyin, script: .simplified)
        let this = try XCTUnwrap(second.first { $0.text == "这" && $0.consumed == 1 })
        XCTAssertEqual(composition.commit(this), "这")
        let third = try await lexicon.candidates(for: composition.input, layout: .pinyin, script: .simplified)
        let measure = try XCTUnwrap(third.first { $0.text == "个" && $0.consumed == 1 })
        XCTAssertEqual(composition.commit(measure), "个")
        XCTAssertEqual(composition.input, "s'g")
        let tail = try await lexicon.candidates(for: composition.input, layout: .pinyin, script: .simplified)
        let silly = try XCTUnwrap(tail.first { $0.text == "傻瓜" })
        let resolution = await lexicon.resolve(silly, for: composition.input,
            layout: .pinyin, script: .simplified)
        let resolved = try XCTUnwrap(resolution)
        XCTAssertEqual(composition.commit(resolved), "傻瓜")
        XCTAssertTrue(composition.input.isEmpty)
        await lexicon.close()
    }

    func testUnseparatedInitialsCanBeSelectedOneCharacterAtATime() async throws {
        let lexicon = try Lexicon(url: lexiconURL)
        var composition = Composition()
        XCTAssertTrue(composition.append("cjw"))

        let firstChoices = try await lexicon.candidates(for: composition.input, layout: .pinyin, script: .simplified)
        let phraseChoices = Array(firstChoices.prefix { $0.text.count > 1 })
        let singleChoices = Array(firstChoices.dropFirst(phraseChoices.count))
        XCTAssertTrue(phraseChoices.contains { $0.text.count == 3 })
        XCTAssertTrue(phraseChoices.contains { $0.text.count == 2 })
        XCTAssertFalse(zip(phraseChoices, phraseChoices.dropFirst()).contains { $0.0.text.count < $0.1.text.count })
        XCTAssertGreaterThanOrEqual(Set(singleChoices.map(\.text)).count, 697)
        XCTAssertTrue(singleChoices.allSatisfy { $0.text.count == 1 && $0.consumed == 1 })
        let first = try XCTUnwrap(firstChoices.first { $0.text == "从" && $0.consumed == 1 })
        XCTAssertEqual(composition.commit(first), "从")
        XCTAssertEqual(composition.input, "jw")

        let secondChoices = try await lexicon.candidates(for: composition.input, layout: .pinyin, script: .simplified)
        let second = try XCTUnwrap(secondChoices.first { $0.text == "就" && $0.consumed == 1 })
        let secondIndex = try XCTUnwrap(secondChoices.firstIndex(of: second))
        XCTAssertTrue(secondChoices[..<secondIndex].allSatisfy { $0.text.count > 1 })
        XCTAssertEqual(composition.commit(second), "就")
        XCTAssertEqual(composition.input, "w")

        let lastChoices = try await lexicon.candidates(for: composition.input, layout: .pinyin, script: .simplified)
        let last = try XCTUnwrap(lastChoices.first { $0.text == "我" })
        let resolution = await lexicon.resolve(last, for: composition.input,
            layout: .pinyin, script: .simplified)
        let resolved = try XCTUnwrap(resolution)
        XCTAssertEqual(composition.commit(resolved), "我")
        XCTAssertTrue(composition.input.isEmpty)

        let traditional = try await lexicon.candidates(for: "cjw", layout: .pinyin, script: .traditional)
        XCTAssertGreaterThanOrEqual(Set(traditional.filter { $0.consumed == 1 }.map(\.text)).count, 770)
        let limited = try await lexicon.candidates(for: "cjw", layout: .pinyin, script: .simplified, limit: 1)
        XCTAssertEqual(limited.count, 1)
        await lexicon.close()
    }

    private var lexiconURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/lexicon.sqlite")
    }

    func testRealPinyinLexicon() async throws {
        let lexicon = try Lexicon(url: lexiconURL)
        let candidates = try await lexicon.candidates(for: "nihao", layout: .pinyin, script: .simplified)
        XCTAssertEqual(candidates.first?.text, "你好")
        let apple = try await lexicon.candidates(for: "pingguo", layout: .pinyin, script: .simplified)
        XCTAssertEqual(apple.first?.text, "苹果")
        await lexicon.close()
    }

    func testExpandedSingleGroupsFollowInitialsAndShowNasalCorrection() async throws {
        let lexicon = try Lexicon(url: lexiconURL)
        let initials = await lexicon.singleCandidateGroups(for: "cjw", script: .simplified)
        XCTAssertEqual(initials.map(\.label), ["c", "j", "w"])
        XCTAssertTrue(initials.allSatisfy { !$0.candidates.isEmpty })
        XCTAssertTrue(initials[0].candidates.allSatisfy { $0.consumed == 1 })

        var composition = Composition()
        XCTAssertTrue(composition.append("cjw"))
        XCTAssertNotNil(composition.commit(try XCTUnwrap(initials[0].candidates.first)))
        XCTAssertEqual(composition.input, "jw")
        let next = await lexicon.singleCandidateGroups(for: composition.input, script: .simplified)
        XCTAssertEqual(next.map(\.label), ["j", "w"])

        let nasal = await lexicon.singleCandidateGroups(for: "pin", script: .simplified)
        XCTAssertEqual(nasal.first?.label, "pin")
        XCTAssertTrue(nasal.contains { $0.label == "ping" && $0.isCorrection && !$0.candidates.isEmpty })
        let retroflex = await lexicon.singleCandidateGroups(for: "zi", script: .simplified)
        XCTAssertTrue(retroflex.contains { $0.label == "zhi" && $0.isCorrection && !$0.candidates.isEmpty })
        let nasalInitial = await lexicon.singleCandidateGroups(for: "ni", script: .simplified)
        XCTAssertTrue(nasalInitial.contains { $0.label == "li" && $0.isCorrection && !$0.candidates.isEmpty })
        await lexicon.close()
    }

    func testCompletePinyinWinsOverUnrankedEnglishHomographs() async throws {
        let lexicon = try Lexicon(url: lexiconURL)
        for raw in ["xian", "shan", "yue", "liao", "qing", "xiao", "xiang"] {
            let preferred = await lexicon.prefersPinyin(overEnglish: raw)
            XCTAssertTrue(preferred, "Complete Pinyin was treated as dictionary English: \(raw)")
        }
        for raw in ["can", "man", "fan", "sun", "long", "like", "app", "appli", "nihao", "aardwolf", "i", "xian'"] {
            let preferred = await lexicon.prefersPinyin(overEnglish: raw)
            XCTAssertFalse(preferred, "Genuine English or incomplete/multisyllable input was suppressed: \(raw)")
        }
        await lexicon.close()
    }

    func testCommerciallyLicensedVocabularyAndPinyinRepairs() async throws {
        let lexicon = try Lexicon(url: lexiconURL)
        let medical = try await lexicon.candidates(for: "qingmeisu", layout: .pinyin, script: .traditional)
        XCTAssertTrue(medical.contains { $0.text == "青黴素" })
        let english = await lexicon.englishWords(prefix: "keybo")
        XCTAssertTrue(english.completions.contains("keyboard"))
        let application = await lexicon.englishWords(prefix: "appli")
        XCTAssertTrue(application.completions.contains("application"))
        let placeName = await lexicon.englishWords(prefix: "shenzhen")
        XCTAssertFalse(placeName.known)
        XCTAssertTrue(PinyinTolerance.variants(of: "nihap").contains("nihao"))
        XCTAssertTrue(PinyinTolerance.variants(of: "zhonguo").contains("zhongguo"))
        XCTAssertTrue(PinyinTolerance.variants(of: "senti").contains("shenti"))
        XCTAssertTrue(PinyinTolerance.variants(of: "zongguo").contains("zhongguo"))
        XCTAssertTrue(PinyinTolerance.variants(of: "pinan").contains("pingan"))
        let repaired = try await lexicon.candidates(for: "nihap", layout: .pinyin, script: .simplified)
        XCTAssertEqual(repaired.first?.text, "你好", "Candidates: \(repaired.prefix(12).map(\.text))")
        let resolvedGreeting = await lexicon.resolve(try XCTUnwrap(repaired.first), for: "nihap",
            layout: .pinyin, script: .simplified)
        XCTAssertEqual(resolvedGreeting?.consumed, "nihap".count)
        let fuzzy = try await lexicon.candidates(for: "senti", layout: .pinyin, script: .simplified)
        XCTAssertEqual(fuzzy.first?.text, "身体", "Candidates: \(fuzzy.prefix(12).map(\.text))")
        let missingLetter = try await lexicon.candidates(for: "zhonguo", layout: .pinyin, script: .simplified)
        XCTAssertEqual(missingLetter.first?.text, "中国", "Candidates: \(missingLetter.prefix(12).map(\.text))")
        let resolvedCountry = await lexicon.resolve(try XCTUnwrap(missingLetter.first), for: "zhonguo",
            layout: .pinyin, script: .simplified)
        XCTAssertEqual(resolvedCountry?.consumed, "zhonguo".count)
        let retroflex = try await lexicon.candidates(for: "zongguo", layout: .pinyin, script: .simplified)
        XCTAssertEqual(retroflex.first?.text, "中国", "Candidates: \(retroflex.prefix(12).map(\.text))")
        let nasal = try await lexicon.candidates(for: "pinan", layout: .pinyin, script: .simplified)
        XCTAssertEqual(nasal.first?.text, "平安", "Candidates: \(nasal.prefix(12).map(\.text))")
        await lexicon.close()
    }

    func testAlternatePronunciationsReachCandidatesAndCommit() async throws {
        let lexicon = try Lexicon(url: lexiconURL)
        let examples = [("shui", "谁", "誰"), ("shei", "谁", "誰"),
                        ("shou", "熟", "熟"), ("yao", "钥", "鑰"),
                        ("jue", "嚼", "嚼"), ("zhai", "择", "擇"),
                        ("jiaose", "角色", "角色"), ("moju", "模具", "模具"),
                        ("xielu", "泄露", "泄露")]
        for script in [ChineseScript.simplified, .traditional] {
            for (raw, simplified, traditional) in examples {
                let text = script == .simplified ? simplified : traditional
                let found = try await lexicon.candidates(for: raw, layout: .pinyin, script: script)
                guard let candidate = found.first(where: { $0.text == text }) else {
                    XCTFail("Missing \(raw) → \(text): \(found.map(\.text))")
                    continue
                }
                let resolved = await lexicon.resolve(candidate, for: raw, layout: .pinyin, script: script)
                XCTAssertEqual(resolved?.consumed, raw.count, "\(raw) → \(text)")
                var composition = Composition()
                composition.append(raw)
                XCTAssertEqual(composition.commit(try XCTUnwrap(resolved)), text)
                XCTAssertTrue(composition.input.isEmpty)
            }
            let raw = KeyCoding.nineKey("shui")
            let text = script == .simplified ? "谁" : "誰"
            let found = try await lexicon.candidates(for: raw, layout: .nineKey, script: script)
            if let candidate = found.first(where: { $0.text == text }) {
                let resolved = await lexicon.resolve(candidate, for: raw, layout: .nineKey, script: script)
                XCTAssertEqual(resolved?.consumed, raw.count)
            } else {
                XCTFail("Missing nine-key \(raw) → \(text)")
            }
        }
        await lexicon.close()
    }

    func testRealNineKeyLexicon() async throws {
        let lexicon = try Lexicon(url: lexiconURL)
        let preedit = await lexicon.nineKeyPreedit(for: "64426", preferred: "你好", script: .simplified)
        XCTAssertEqual(preedit, "nihao")
        let partial = await lexicon.nineKeyPreedit(for: "64", preferred: "你", script: .simplified)
        XCTAssertEqual(partial, "ni")
        let invalid = await lexicon.nineKeyPreedit(for: "106", preferred: nil, script: .simplified)
        XCTAssertNil(invalid)
        let candidates = try await lexicon.candidates(for: "64426", layout: .nineKey, script: .simplified)
        let greeting = try XCTUnwrap(candidates.first { $0.text == "你好" })
        let resolved = await lexicon.resolve(greeting, for: "64426", layout: .nineKey, script: .simplified)
        XCTAssertEqual(resolved?.consumed, 5)
        let apple = try await lexicon.candidates(for: "7464486", layout: .nineKey, script: .traditional)
        XCTAssertTrue(apple.contains { $0.text == "蘋果" })
        await lexicon.close()
    }

    func testRealCangjieFiveLexicon() async throws {
        let lexicon = try Lexicon(url: lexiconURL)
        let sun = try await lexicon.candidates(for: "a", layout: .cangjie, script: .traditional)
        XCTAssertTrue(sun.contains { $0.text == "日" })
        let you = try await lexicon.candidates(for: "onf", layout: .cangjie, script: .traditional)
        XCTAssertTrue(you.contains { $0.text == "你" })
        await lexicon.close()
    }

    func testPinyinApostropheDistinguishesXian() async throws {
        let lexicon = try Lexicon(url: lexiconURL)
        let candidates = try await lexicon.candidates(for: "xi'an", layout: .pinyin, script: .simplified)
        XCTAssertTrue(candidates.contains { $0.text == "西安" })
        XCTAssertFalse(candidates.contains { $0.text == "先" })
        await lexicon.close()
    }

    func testLongInputCanBeCommittedInSegments() async throws {
        let lexicon = try Lexicon(url: lexiconURL)
        var composition = Composition()
        composition.append("nihaoshijie")
        let candidates = try await lexicon.candidates(for: composition.input, layout: .pinyin, script: .simplified)
        let greeting = try XCTUnwrap(candidates.first { $0.text == "你好" })
        let resolved = await lexicon.resolve(greeting, for: composition.input, layout: .pinyin, script: .simplified)
        XCTAssertEqual(composition.commit(try XCTUnwrap(resolved)), "你好")
        XCTAssertEqual(composition.input, "shijie")
        let remainder = try await lexicon.candidates(for: composition.input, layout: .pinyin, script: .simplified)
        XCTAssertTrue(remainder.contains { $0.text == "世界" })
        await lexicon.close()
    }

    func testMissingLexiconThrowsAndEmptyInputIsSafe() async throws {
        XCTAssertThrowsError(try Lexicon(url: URL(fileURLWithPath: "/nonexistent/lexicon.sqlite")))
        let lexicon = try Lexicon(url: lexiconURL)
        let empty = try await lexicon.candidates(for: "", layout: .pinyin, script: .simplified)
        XCTAssertTrue(empty.isEmpty)
        await lexicon.close()
    }

    func testMixedAbbreviationAndWholeSentences() async throws {
        let lexicon = try Lexicon(url: lexiconURL)
        for (raw, expected) in [("nhao", "你好"), ("nh", "你好"), ("nihaoshijie", "你好世界"),
                                ("wojintianxiangquchaoshimaipingguo", "我今天想去超市买苹果")] {
            let found = try await lexicon.candidates(for: raw, layout: .pinyin, script: .simplified)
            XCTAssertEqual(found.first?.text, expected, raw)
            let resolved = await lexicon.resolve(try XCTUnwrap(found.first), for: raw, layout: .pinyin, script: .simplified)
            XCTAssertEqual(resolved?.consumed, raw.count, raw)
        }
    }

    func testLongSentenceBeyondOld48LetterLimit() async throws {
        let raw = "wojintianxiangquchaoshimaipingguoranhouhuijiazuofanchifan"
        var composition = Composition()
        XCTAssertGreaterThan(raw.count, 48)
        XCTAssertTrue(composition.append(raw))
        let lexicon = try Lexicon(url: lexiconURL)
        let found = try await lexicon.candidates(for: raw, layout: .pinyin, script: .simplified)
        let first = try XCTUnwrap(found.first)
        XCTAssertEqual(first.text, "我今天想去超市买苹果然后回家做饭吃饭")
        let resolved = await lexicon.resolve(first, for: raw, layout: .pinyin, script: .simplified)
        XCTAssertEqual(resolved?.consumed, raw.count)
        XCTAssertNotNil(composition.commit(try XCTUnwrap(resolved)))
        XCTAssertTrue(composition.input.isEmpty)
        XCTAssertGreaterThan(first.text.count, 15)
    }

    func testMixedAbbreviationPartialSelectionAndStaleCandidate() async throws {
        let lexicon = try Lexicon(url: lexiconURL)
        for raw in ["nhaoshijie", "nhao'shijie", "nihao'shijie"] {
            let found = try await lexicon.candidates(for: raw, layout: .pinyin, script: .simplified)
            let candidate = try XCTUnwrap(found.first { $0.text == "你好" })
            let resolved = await lexicon.resolve(candidate, for: raw, layout: .pinyin, script: .simplified)
            var composition = Composition()
            composition.append(raw)
            XCTAssertEqual(composition.commit(try XCTUnwrap(resolved)), "你好")
            XCTAssertEqual(composition.input, "shijie")
            let stale = Candidate(text: "错误候选", reading: raw, consumed: 0, engineIndex: candidate.engineIndex)
            let rejected = await lexicon.resolve(stale, for: raw, layout: .pinyin, script: .simplified)
            XCTAssertNil(rejected)
        }
    }
}
