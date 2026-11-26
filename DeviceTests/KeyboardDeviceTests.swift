import XCTest
import UIKit

final class KeyboardDeviceTests: XCTestCase {
    @MainActor
    func testMembershipPageReflectsVerifiedAccessOnPhysicalIPhone() throws {
        let app = launchApp()
        let entry = app.buttons["membership.open"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.tap()

        let plans = app.buttons["membership.plan.yearly"]
        let active = app.descendants(matching: .any)["membership.active"].firstMatch
        let checking = app.descendants(matching: .any)["membership.checking"].firstMatch
        let purchase = app.buttons["membership.purchase"]
        if checking.exists {
            XCTAssertFalse(purchase.exists, "Membership verification must finish before offering a purchase")
        }
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            active.exists || plans.exists
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 30), .completed)
        if active.exists {
            XCTAssertFalse(plans.exists)
            XCTAssertFalse(purchase.exists)
            XCTAssertTrue(app.buttons["membership.continue"].exists)
            print("Membership check: StoreKit returned active access")
        } else {
            XCTAssertTrue(purchase.exists)
            XCTAssertFalse(app.buttons["membership.continue"].exists)
            print("Membership check: StoreKit returned no active access")
        }
        XCTAssertTrue(app.buttons["membership.restore"].exists)
    }

    @MainActor
    func testFuzzyPinyinAndNeighborTyposOnPhysicalIPhone() throws {
        try checkFuzzyPinyinOnPhysicalIPhone()
    }

    @MainActor
    func testStandardSentencesWithFuzzyPinyinOnPhysicalIPhone() throws {
        try checkFuzzyPinyinOnPhysicalIPhone(sentences: [
            ("nibuzaoshuo", "你不早说"), ("wobuzaoshuo", "我不早说"), ("buzaoshuo", "不早说"),
        ])
    }

    @MainActor
    func testStandardReadingRanksFirstOnPhysicalIPhone() throws {
        try checkFuzzyPinyinOnPhysicalIPhone(sentences: [("nijinwanyaozijiquchi", "你今晚要自己去吃")])
    }

    @MainActor
    func testExpandedVocabularyOnPhysicalIPhone() throws {
        try checkFuzzyPinyinOnPhysicalIPhone(sentences: [
            ("huangesaidao", "换个赛道"), ("nijinwanyaozijiquchi", "你今晚要自己去吃"),
        ], excludedCandidates: ["你敬我爱你要自己去吃", "你今晚要自己去次"])
    }

    @MainActor
    private func checkFuzzyPinyinOnPhysicalIPhone(sentences: [(input: String, text: String)]? = nil,
                                                 excludedCandidates: [String] = []) throws {
        let app = launchApp()
        let screen = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let fuzzy = app.switches["settings.fuzzyPinyin"].firstMatch
        func revealSetting() {
            for _ in 0..<8 {
                if fuzzy.exists, fuzzy.isHittable, fuzzy.frame.minY > 140,
                   fuzzy.frame.maxY < app.frame.height - 80 { return }
                let down = fuzzy.exists && fuzzy.frame.minY < 140
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: down ? 0.40 : 0.73))
                    .press(forDuration: 0.05, thenDragTo:
                        app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: down ? 0.73 : 0.40)))
            }
            XCTAssertTrue(fuzzy.isHittable)
        }
        func setFuzzy(_ enabled: Bool) {
            revealSetting()
            let value = enabled ? "1" : "0"
            for _ in 0..<2 {
                if (fuzzy.value as? String) != value {
                    fuzzy.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
                }
                let state = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: fuzzy)
                if XCTWaiter.wait(for: [state], timeout: 4) == .completed { return }
            }
            XCTAssertEqual(fuzzy.value as? String, value)
        }
        func reopenApp() {
            app.terminate()
            app.launch()
        }
        func openEditor() throws -> XCUIElement {
            app.activate()
            let editor = app.textViews["keyboard.test.editor"]
            for _ in 0..<10 {
                if editor.isHittable, editor.frame.minY > 125, editor.frame.minY < app.frame.height - 100 { break }
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.75))
                    .press(forDuration: 0.05, thenDragTo:
                        app.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.27)))
            }
            if !editor.isHittable { attachState(app, name: "Test editor unavailable") }
            XCTAssertTrue(editor.isHittable)
            editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
            try selectPinyinKeyboard(in: app)
            if app.buttons["切换大小写"].exists { tapKeyboardElement(app.buttons["切换中英文"]) }
            XCTAssertFalse(app.buttons["切换大小写"].exists)
            return editor
        }
        func tapKeyboardElement(_ element: XCUIElement, verticalFraction: CGFloat = 0.5) {
            let frame = element.frame
            let keyboard = app.otherElements["inputView"].firstMatch.frame
            let origin = frame.maxY <= keyboard.height ? keyboard.origin : .zero
            screen.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: frame.midX + origin.x, dy: frame.minY + frame.height * verticalFraction + origin.y))
                .tap()
        }
        func type(_ input: String) {
            for letter in input { tapKeyboardElement(app.buttons.matching(identifier: "key.\(letter)").firstMatch) }
        }
        func commitFirst(_ expected: String, in editor: XCUIElement) {
            let candidate = app.buttons["candidate.\(expected)"].firstMatch
            XCTAssertTrue(candidate.waitForExistence(timeout: 10), "Expected candidate: \(expected)")
            for other in excludedCandidates {
                XCTAssertFalse(app.buttons["candidate.\(other)"].exists, "Unexpected extra sentence: \(other)")
            }
            XCTAssertLessThan(candidate.frame.minX, 16, "Expected leftmost candidate: \(expected)")
            // Tap the word below the translation or membership control.
            tapKeyboardElement(candidate, verticalFraction: 0.8)
            let typed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value ENDSWITH %@", expected), object: editor)
            let result = XCTWaiter.wait(for: [typed], timeout: 5)
            if result != .completed { attachState(app, name: "Candidate commit failed for \(expected)") }
            XCTAssertEqual(result, .completed)
        }

        revealSetting()
        let original = fuzzy.value as? String == "1"
        defer {
            reopenApp()
            setFuzzy(original)
        }
        if let sentences {
            setFuzzy(true)
            reopenApp()
            let editor = try openEditor()
            for sentence in sentences {
                type(sentence.input)
                commitFirst(sentence.text, in: editor)
            }
            XCTAssertEqual(editor.value as? String, sentences.map(\.text).joined())
            attachState(app, name: "Standard sentences committed with fuzzy pinyin")
            return
        }
        setFuzzy(false)
        let strictEditor = try openEditor()
        type("zongguo")
        let candidates = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'candidate.'"))
        XCTAssertTrue(candidates.firstMatch.waitForExistence(timeout: 10))
        let strictInput = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value ENDSWITH 'zongguo'"), object: strictEditor)
        XCTAssertEqual(XCTWaiter.wait(for: [strictInput], timeout: 5), .completed)
        XCTAssertFalse(app.buttons["candidate.中国"].exists)
        attachState(app, name: "Fuzzy pinyin off")

        reopenApp()
        setFuzzy(true)
        let editor = try openEditor()
        type("lq")
        commitFirst("录取", in: editor)
        type("nq")
        commitFirst("年轻", in: editor)
        type("zihao")
        let exact = app.buttons.matching(NSPredicate(format: "identifier IN %@", ["candidate.自豪", "candidate.字号"]))
        let firstExact = exact.firstMatch
        XCTAssertTrue(firstExact.waitForExistence(timeout: 10))
        let zihao = String(firstExact.identifier.dropFirst("candidate.".count))
        commitFirst(zihao, in: editor)
        type("zhihao")
        commitFirst("只好", in: editor)
        type("zongguo")
        commitFirst("中国", in: editor)
        type("zhomgw")
        commitFirst("中文", in: editor)
        type("zhomgwnecih")
        commitFirst("中文词汇", in: editor)
        type("bushi")
        commitFirst("不是", in: editor)
        type("zhegexiaofuohenhao")
        commitFirst("这个小伙很好", in: editor)
        type("woxuezhomgwnecihyi")
        commitFirst("我学中文词汇", in: editor)
        XCTAssertEqual(editor.value as? String, "录取年轻\(zihao)只好中国中文中文词汇不是这个小伙很好我学中文词汇")
        attachState(app, name: "Fuzzy pinyin and neighbor corrections committed")
    }

    @MainActor
    func testMixedInputRepairsOnPhysicalIPhone() throws {
        let app = launchApp()
        let editor = revealKeyboardTestEditor(in: app)
        try selectPinyinKeyboard(in: app)
        let screen = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        func tap(_ element: XCUIElement) {
            let frame = element.frame
            let keyboard = app.otherElements["inputView"].firstMatch.frame
            let origin = frame.maxY <= keyboard.height ? keyboard.origin : .zero
            screen.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: frame.midX + origin.x, dy: frame.midY + origin.y)).tap()
        }
        if app.buttons["切换大小写"].exists { tap(app.buttons["切换中英文"]) }
        func typeWord() {
            for letter in "iphone" { tap(app.buttons["key.\(letter)"].firstMatch) }
        }
        typeWord()
        let word = app.buttons.matching(NSPredicate(format: "identifier ==[c] 'candidate.iphone'")).firstMatch
        XCTAssertTrue(word.waitForExistence(timeout: 10))
        XCTAssertLessThan(word.frame.minX, 16)
        XCTAssertFalse(app.buttons["candidate.皮佛了"].exists)
        tap(app.buttons["key.选定"].firstMatch)
        XCTAssertTrue(app.buttons["key.空格"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, "iphone")

        typeWord()
        tap(app.buttons["逗号，长按句号"].firstMatch)
        let inserted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'iphoneiphone，'"), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [inserted], timeout: 5), .completed)

        for letter in "jiandanlaishio" { tap(app.buttons["key.\(letter)"].firstMatch) }
        let corrected = app.buttons["candidate.简单来说"].firstMatch
        XCTAssertTrue(corrected.waitForExistence(timeout: 10))
        XCTAssertLessThan(corrected.frame.minX, 16)
        tap(app.buttons["key.选定"].firstMatch)
        let sentence = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'iphoneiphone，简单来说'"), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [sentence], timeout: 5), .completed)
    }

    @MainActor
    func testPinyinSplitVowelsOnPhysicalIPhone() throws {
        let app = launchApp()
        let editor = revealKeyboardTestEditor(in: app)
        try selectPinyinKeyboard(in: app)
        let screen = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        func tap(_ element: XCUIElement) {
            let frame = element.frame
            let keyboard = app.otherElements["inputView"].firstMatch.frame
            let origin = frame.maxY <= keyboard.height ? keyboard.origin : .zero
            screen.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: frame.midX + origin.x, dy: frame.midY + origin.y)).tap()
        }
        if app.buttons["切换大小写"].exists { tap(app.buttons["切换中英文"]) }
        var expected = ""
        for (input, correction) in [("shioba", "说吧"), ("nishioba", "你说吧"), ("jiandanlaishio", "简单来说")] {
            for letter in input { tap(app.buttons["key.\(letter)"].firstMatch) }
            let first = app.buttons["candidate.\(correction)"].firstMatch
            XCTAssertTrue(first.waitForExistence(timeout: 10), input)
            XCTAssertLessThan(first.frame.minX, 16, input)
            tap(app.buttons["key.选定"].firstMatch)
            expected += correction
            let committed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: editor)
            XCTAssertEqual(XCTWaiter.wait(for: [committed], timeout: 5), .completed, input)
        }
    }

    @MainActor
    func testPinyinSentenceAndTranslationOnPhysicalIPhone() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--physical-device-ui-test"]
        app.launch()
        defer { attachState(app, name: "Pinyin sentence regression final state") }
        dismissPastePrompt()
        let editor = revealKeyboardTestEditor(in: app)
        try selectCompanionKeyboard(in: app)
        guard app.buttons["切换中英文"].exists else { throw XCTSkip("Chinese audience required") }
        if app.buttons["切换大小写"].exists { app.buttons["切换中英文"].tap() }
        let screen = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        func type(_ input: String) {
            for letter in input {
                let frame = app.buttons.matching(identifier: "key.\(letter)").firstMatch.frame
                let keyboard = app.otherElements["inputView"].firstMatch.frame
                let origin = frame.maxY <= keyboard.height ? keyboard.origin : .zero
                screen.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: frame.midX + origin.x, dy: frame.midY + origin.y)).tap()
            }
        }
        type("nanidexianbazimeitizuoqilai")
        let available = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'candidate.'"))
        XCTAssertTrue(available.firstMatch.waitForExistence(timeout: 10))
        // Verify raw-input handling and commit behavior without prescribing a sentence ranking.
        let candidate = try XCTUnwrap(available.allElementsBoundByIndex.min { $0.frame.minX < $1.frame.minX })
        let expected = String(candidate.identifier.dropFirst("candidate.".count))
        XCTAssertTrue(expected.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) })
        XCTAssertLessThan(candidate.frame.minX, 16)
        XCTAssertFalse(app.buttons["candidate.nanidexianbazimeitizuoqilai"].exists,
                       "Raw Pinyin must not be offered as a recognized English word")
        let translated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS[c] 'media'"), object: candidate)
        let translationResult = XCTWaiter.wait(for: [translated], timeout: 20)
        attachState(app, name: "Self media sentence actual candidate and translation")
        XCTAssertEqual(translationResult, .completed, "Verify the actual English translation for the selected Chinese sentence")
        candidate.tap()
        XCTAssertTrue((editor.value as? String)?.hasSuffix(expected) == true)
        type("uu")
        let fallback = app.buttons["candidate.uu"]
        XCTAssertTrue(fallback.waitForExistence(timeout: 10))
        XCTAssertEqual(fallback.label, "uu", "Unknown raw text remains selectable without a fabricated translation")
        fallback.tap()
        XCTAssertTrue((editor.value as? String)?.hasSuffix(expected + "uu") == true)
    }

    @MainActor
    func testPrivacyClipboardSettingsEntryOnPhysicalIPhone() throws {
        let app = launchApp()
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")

        func audienceButton(english: Bool) -> XCUIElement {
            let labels = english ? ["英文用户", "English users"] : ["中文用户", "Chinese users"]
            return app.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
        }
        func reveal(_ element: XCUIElement) {
            // A partially clipped segmented control can be reported as hittable.
            // Keep taps away from the navigation bar and the home indicator.
            for _ in 0..<10 {
                if element.exists, element.isHittable,
                   element.frame.minY > 150, element.frame.maxY < app.frame.height - 180 { return }
                let scrollDown = element.exists && element.frame.minY < 150
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: scrollDown ? 0.4 : 0.75))
                    .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: scrollDown ? 0.75 : 0.4)))
            }
            XCTAssertTrue(element.isHittable)
        }
        func chooseAudience(english: Bool) {
            let choice = audienceButton(english: english)
            // Returning from Privacy preserves the form's scroll position.
            // Scroll toward the earlier audience cell until it is instantiated.
            for _ in 0..<8 where !choice.exists {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.4))
                    .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.75)))
            }
            reveal(choice)
            if !choice.isSelected { choice.tap() }
            XCTAssertTrue(choice.isSelected)
        }

        let englishChoice = audienceButton(english: true)
        reveal(englishChoice)
        let originallyEnglish = englishChoice.isSelected
        defer {
            app.activate()
            if app.buttons["privacy.openSettings"].exists { app.navigationBars.buttons.firstMatch.tap() }
            chooseAudience(english: originallyEnglish)
        }

        for english in [false, true] {
            chooseAudience(english: english)
            let privacy = app.buttons["settings.privacy"]
            reveal(privacy)
            XCTAssertTrue(privacy.waitForExistence(timeout: 5))
            privacy.tap()
            let openSettings = app.buttons["privacy.openSettings"]
            XCTAssertTrue(openSettings.waitForExistence(timeout: 5))
            XCTAssertTrue(openSettings.isHittable)
            let permission = app.staticTexts["privacy.pastePermission"]
            XCTAssertTrue(permission.label.contains(english ? "Allow" : "允许"))
            XCTAssertTrue(app.staticTexts["privacy.fullAccess"].label.contains(english ? "Full Access" : "完全访问"))
            XCTAssertTrue(app.staticTexts["privacy.permissionHint"].exists)
            attachState(app, name: english ? "Concise clipboard privacy English" : "Concise clipboard privacy Chinese")
            openSettings.tap()
            XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 10))
            let appSettings = settings.navigationBars.matching(NSPredicate(format: "identifier CONTAINS '伴语' OR identifier CONTAINS 'TypeToLearn'")).firstMatch
            XCTAssertTrue(appSettings.waitForExistence(timeout: 10), "The shortcut must open this app's Settings page")
            attachState(settings, name: "Clipboard permission app Settings destination")
            app.activate()
            XCTAssertTrue(openSettings.waitForExistence(timeout: 5))
            app.navigationBars.buttons.firstMatch.tap()
        }
    }

    @MainActor
    func testEnglishAudienceOnboardingOverridesChineseSystemOnPhysicalIPhone() throws {
        let app = XCUIApplication()
        for (system, title) in [("zh-Hans", "中文键盘用户"), ("zh-Hant", "中文鍵盤使用者")] {
            app.launchArguments = ["--physical-device-ui-test", "--onboarding-test-store", "--reset-onboarding", "-AppleLanguages", "(\(system))"]
            app.launch()
            let chinese = app.buttons["onboarding.audience.chinese"]
            let english = app.buttons["onboarding.audience.english"]
            XCTAssertTrue(chinese.waitForExistence(timeout: 10))
            XCTAssertTrue(chinese.label.contains(title))
            english.tap()
            XCTAssertTrue(english.label.contains("English keyboard user"))
            XCTAssertEqual(app.buttons["onboarding.next"].label, "Continue")
            chinese.tap()
            XCTAssertTrue(chinese.label.contains(title))
            english.tap()
            app.buttons["onboarding.next"].tap()
            let search = app.textFields["onboarding.language.search"]
            XCTAssertTrue(search.waitForExistence(timeout: 10))
            XCTAssertEqual(search.placeholderValue, "Search languages")
            let japanese = app.buttons["onboarding.language.ja"]
            for _ in 0..<6 where !japanese.isHittable { app.swipeUp() }
            XCTAssertTrue(japanese.label.contains("Japanese"))
            japanese.tap()
            XCTAssertEqual(app.staticTexts["onboarding.preview.language"].label, "Japanese")
            attachState(app, name: "English onboarding with \(system) system language")
            app.terminate()
            app.launchArguments.removeAll { $0 == "--reset-onboarding" }
            app.launch()
            XCTAssertTrue(search.waitForExistence(timeout: 10))
            XCTAssertEqual(search.placeholderValue, "Search languages")
            app.buttons["onboarding.back"].tap()
            XCTAssertTrue(english.label.contains("English keyboard user"))
            app.terminate()
        }
    }

    @MainActor
    func testMembershipEntryAndLegalOnPhysicalIPhone() throws {
        let app = launchApp()
        app.buttons["membership.open"].tap()
        let monthly = app.buttons["membership.plan.monthly"]
        XCTAssertTrue(monthly.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["membership.plan.yearly"].exists)
        let lifetime = app.buttons["membership.plan.lifetime"]
        for _ in 0..<3 where !lifetime.isHittable { app.swipeUp() }
        XCTAssertTrue(lifetime.exists)
        attachState(app, name: "Membership monthly yearly lifetime plans")
        lifetime.tap()
        XCTAssertTrue(lifetime.isSelected)
        for identifier in ["membership.privacy", "membership.support", "membership.terms"] {
            let link = app.links[identifier]
            XCTAssertTrue(link.exists)
            XCTAssertTrue(link.isHittable)
            XCTAssertGreaterThanOrEqual(link.frame.minY, app.buttons["membership.purchase"].frame.maxY)
            link.tap()
            XCTAssertTrue(XCUIApplication(bundleIdentifier: "com.apple.mobilesafari").wait(for: .runningForeground, timeout: 10))
            app.activate()
            XCTAssertTrue(app.buttons["membership.purchase"].waitForExistence(timeout: 5))
        }
        attachState(app, name: "Membership browser links below purchase button")
        XCTAssertTrue(app.buttons["membership.restore"].exists)
        app.buttons["membership.close"].tap()
        XCTAssertTrue(app.buttons["membership.open"].exists)
    }

    @MainActor
    func testOnboardingRandomLanguagesSelectionAndMembershipOnPhysicalIPhone() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--physical-device-ui-test", "--onboarding-test-store", "--reset-onboarding", "-AppleLanguages", "(en)"]
        app.launch()
        dismissPastePrompt()
        app.buttons["onboarding.audience.english"].tap()
        app.buttons["onboarding.next"].tap()
        let language = app.staticTexts["onboarding.preview.language"]
        XCTAssertTrue(language.waitForExistence(timeout: 15))
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != 'Choose a language to preview' AND label != ''"), object: language)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 15), .completed)
        let initial = language.label
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", initial), object: language)], timeout: 12), .completed)
        let japanese = app.buttons["onboarding.language.ja"]
        for _ in 0..<6 where !japanese.isHittable { app.swipeUp() }
        japanese.tap()
        app.buttons["onboarding.preview.replay"].tap()
        XCTAssertEqual(language.label, "Japanese")
        XCTAssertFalse(app.buttons["onboarding.preview.ja"].exists)
        for index in 0..<10 {
            let candidate = app.buttons["onboarding.preview.candidate.\(index)"]
            XCTAssertTrue(candidate.label.contains(", "), "Every candidate needs its own learning translation: \(candidate.label)")
        }
        attachState(app, name: "All preview candidates translated into selected Japanese")
        let download = app.buttons["onboarding.download.ja"]
        for _ in 0..<6 where !download.isHittable { app.swipeUp() }
        XCTAssertTrue(japanese.isSelected)
        attachState(app, name: "Selected language row without preview button")
        download.tap()
        let permission = app.buttons.matching(NSPredicate(format: "label IN %@ AND NOT (identifier BEGINSWITH 'onboarding.')", ["Download", "下载", "下載"])).firstMatch
        if permission.waitForExistence(timeout: 3) { permission.tap() }
        let next = app.buttons["onboarding.next"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: next)], timeout: 30), .completed)
        next.tap()
        XCTAssertTrue(app.buttons["membership.plan.monthly"].waitForExistence(timeout: 10))
        attachState(app, name: "Onboarding membership after language preview")
        app.buttons["membership.skip"].tap()
        XCTAssertTrue(app.buttons["onboarding.openSettings"].waitForExistence(timeout: 5))
        app.terminate()
    }

    @MainActor
    func testNonmemberCrownPreservesTypingOnPhysicalIPhone() throws {
        let app = launchApp()
        let editor = app.textViews["keyboard.test.editor"]
        for _ in 0..<6 where !editor.isHittable { app.swipeUp() }
        XCTAssertTrue(editor.exists)
        editor.tap()
        if !app.buttons["key.n"].waitForExistence(timeout: 5) { try selectPinyinKeyboard(in: app) }
        let english = app.buttons["emoji.bottom"].exists
        let input = english ? "howareyou" : "nihao"
        for key in input { app.buttons["key.\(key)"].tap() }
        let word = english ? "how are you" : "你好"
        let candidate = app.buttons["candidate.\(word)"]
        XCTAssertTrue(candidate.waitForExistence(timeout: 10))
        XCTAssertEqual(candidate.value as? String, english ? "Learning locked" : "学习译文未解锁")
        attachState(app, name: "Keyboard learning crown for nonmember")
        candidate.press(forDuration: 0.7)
        XCTAssertTrue(app.otherElements["keyboard.membership"].waitForExistence(timeout: 5))
        attachState(app, name: "Keyboard unlock learning instructions")
        tapKeyboardChrome(app.buttons[english ? "Back to keyboard" : "返回键盘"])
        candidate.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).tap()
        XCTAssertTrue((editor.value as? String)?.contains(word) == true)
    }

    @MainActor
    func testSharedPreviewLoopAndCompactLanguagesOnPhysicalIPhone() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--physical-device-ui-test", "--onboarding-test-store", "--reset-onboarding", "-AppleLanguages", "(en)"]
        app.launch()
        dismissPastePrompt()
        app.buttons["onboarding.audience.english"].tap()
        app.buttons["onboarding.next"].tap()
        let japanese = app.buttons["onboarding.language.ja"]
        attachState(app, name: "Initial compact language list")
        for _ in 0..<8 where !japanese.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(japanese.isHittable)
        XCTAssertLessThanOrEqual(japanese.frame.height, 48)
        XCTAssertLessThanOrEqual(app.buttons["onboarding.download.ja"].frame.height, 48)
        attachState(app, name: "Compact learning language rows")
        japanese.tap()
        let first = app.buttons["onboarding.preview.candidate.0"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(first.label.contains("元気ですか？"), first.label)
        app.buttons["onboarding.preview.replay"].tap()
        XCTAssertTrue(app.buttons["onboarding.preview.candidate.1"].exists)
        XCTAssertFalse(app.buttons["onboarding.preview.candidate.1"].label == "howareyou")
        attachState(app, name: "Full English preview with candidate strip")
        app.buttons["onboarding.preview.next"].tap()
        XCTAssertTrue(first.label.contains("こんにちは"), first.label)
        XCTAssertTrue(first.label.contains("hello"), first.label)
        // Resuming must advance without a manual Next tap.
        app.buttons["onboarding.preview.replay"].tap()
        let position = app.staticTexts["onboarding.preview.position"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == '3/5'"), object: position)], timeout: 10), .completed)
        let thai = app.buttons["onboarding.language.th"]
        for _ in 0..<10 where !thai.isHittable { app.swipeUp() }
        thai.tap()
        XCTAssertTrue(first.label.contains("คุณสบายดีไหม"), first.label)
        attachState(app, name: "Full English preview learning Thai")
        app.terminate()
    }

    @MainActor
    func testHomePreviewFollowsSavedLayoutsOnPhysicalIPhone() throws {
        let app = launchApp()
        func top() { for _ in 0..<4 { app.swipeDown() } }
        func audience(_ english: Bool) {
            let labels = english ? ["英文用户", "English users"] : ["中文用户", "Chinese users"]
            let choice = app.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
            for _ in 0..<6 where !choice.isHittable { app.swipeUp() }
            choice.tap()
            top()
        }
        audience(true)
        XCTAssertTrue(app.buttons["home.preview.candidate.0"].exists)
        XCTAssertFalse(app.buttons["home.preview.mode"].exists)
        XCTAssertFalse(app.staticTexts["照常打字，\n多懂一种语言。"].exists)
        attachState(app, name: "Home English keyboard preview")
        audience(false)
        for (label, capture) in [("九宫格拼音", "Home nine key preview"), ("仓颉五代", "Home Cangjie preview"), ("26 键拼音", "Home pinyin preview")] {
            let picker = app.buttons["settings.chineseLayout"]
            for _ in 0..<6 where !picker.isHittable { app.swipeUp() }
            picker.tap()
            app.buttons[label].tap()
            top()
            XCTAssertTrue(app.buttons["home.preview.mode"].exists)
            XCTAssertTrue(app.buttons["home.preview.candidate.1"].exists)
            attachState(app, name: capture)
        }
        app.buttons["home.preview.mode"].tap()
        XCTAssertTrue(app.buttons["home.preview.candidate.0"].label.contains("how are you"))
        attachState(app, name: "Home Chinese audience English preview")
        app.buttons["home.preview.mode"].tap()
    }

    @MainActor
    func testOnboardingLanguageSwitchAndBackgroundDownloadOnPhysicalIPhone() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--physical-device-ui-test", "--onboarding-test-store", "--reset-onboarding", "-AppleLanguages", "(en)"]
        app.launch()
        dismissPastePrompt()
        app.buttons["onboarding.audience.english"].tap()
        app.buttons["onboarding.next"].tap()
        func reveal(_ button: XCUIElement) {
            for _ in 0..<7 where !button.isHittable { app.swipeUp() }
            XCTAssertTrue(button.exists)
        }
        let japanese = app.buttons["onboarding.language.ja"]
        reveal(japanese)
        japanese.tap()
        let translation = app.buttons["onboarding.preview.candidate.0"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS '元気ですか？'"), object: translation)], timeout: 8), .completed)
        let italian = app.buttons["onboarding.language.it"]
        reveal(italian)
        italian.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'Come stai?'"), object: translation)], timeout: 8), .completed)
        let download = app.buttons["onboarding.download.it"]
        reveal(download)
        download.tap()
        let permission = app.buttons.matching(NSPredicate(format: "label IN %@ AND NOT (identifier BEGINSWITH 'onboarding.')", ["Download", "下载", "下載"])).firstMatch
        if permission.waitForExistence(timeout: 8) { permission.tap() }
        attachState(app, name: "Onboarding system language download request")
        let next = app.buttons["onboarding.next"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: next)], timeout: 30), .completed)
        next.tap()
        XCTAssertTrue(app.buttons["membership.skip"].waitForExistence(timeout: 10))
        app.buttons["membership.skip"].tap()
        let openSettings = app.buttons["onboarding.openSettings"]
        reveal(openSettings)
        attachState(app, name: "Onboarding continue while language downloads")
        openSettings.tap()
        XCTAssertTrue(XCUIApplication(bundleIdentifier: "com.apple.Preferences").wait(for: .runningForeground, timeout: 10))
        Thread.sleep(forTimeInterval: 3)
        app.activate()
        app.swipeDown()
        app.swipeDown()
        let status = app.staticTexts["onboarding.download.status"]
        for _ in 0..<4 where !status.isHittable { app.swipeDown() }
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'Ready'"), object: status)
        let readiness = XCTWaiter.wait(for: [ready], timeout: 30)
        attachState(app, name: "Onboarding background language download ready")
        XCTAssertEqual(readiness, .completed)
        // Restore the Chinese learning target used by the earlier English-mode test.
        app.buttons["onboarding.back"].tap()
        let chinese = app.buttons.matching(NSPredicate(format: "identifier IN %@", ["onboarding.language.zh", "onboarding.language.zh-Hans"])).firstMatch
        reveal(chinese)
        chinese.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: next)], timeout: 10), .completed)
        next.tap()
        next.tap()
        app.terminate()
    }

    @MainActor
    func testMutedClipboardOnPhysicalIPhone() throws {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["允许粘贴", "允許貼上", "Allow Paste"])).firstMatch
        if allow.exists { allow.tap() }
        let app = launchApp()
        let editor = app.textViews["keyboard.test.editor"]
        for _ in 0..<6 where !editor.isHittable { app.swipeUp() }
        editor.tap()
        let clipboard = app.buttons.matching(NSPredicate(format: "label IN %@", ["Open clipboard", "打开剪贴板"])).firstMatch
        if !clipboard.waitForExistence(timeout: 5) {
            app.buttons.matching(NSPredicate(format: "label IN %@", ["Next keyboard", "下一个键盘", "下一個鍵盤"])).firstMatch.press(forDuration: 1.2)
            app.cells.matching(NSPredicate(format: "label CONTAINS '伴语输入法' OR label CONTAINS 'TypeToLearn'")).firstMatch.tap()
        }
        XCTAssertTrue(clipboard.waitForExistence(timeout: 5))
        attachState(app, name: "Keyboard muted gray clipboard icon")
        clipboard.tap()
        if allow.waitForExistence(timeout: 3) {
            allow.tap()
            editor.tap()
            XCTAssertTrue(clipboard.waitForExistence(timeout: 5))
            clipboard.tap()
        }
        let back = app.buttons.matching(NSPredicate(format: "label IN %@", ["Back to keyboard", "返回键盘"])).firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        tapKeyboardChrome(back)
        XCTAssertTrue(clipboard.waitForExistence(timeout: 5))
    }

    @MainActor
    func testOnboardingPreviewDownloadAndSettingsOnPhysicalIPhone() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--physical-device-ui-test", "--onboarding-test-store", "--reset-onboarding", "-AppleLanguages", "(en)"]
        app.launch()
        XCTAssertTrue(app.buttons["onboarding.audience.chinese"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["onboarding.next"].isEnabled)
        app.buttons["onboarding.audience.english"].tap()
        attachState(app, name: "Onboarding English audience choice")
        app.buttons["onboarding.next"].tap()
        let preview = app.buttons.matching(NSPredicate(format: "identifier IN %@", ["onboarding.language.zh-Hans", "onboarding.language.zh"])).firstMatch
        for _ in 0..<5 where !preview.isHittable { app.swipeUp() }
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        let downloadID = preview.identifier.replacingOccurrences(of: "onboarding.language.", with: "onboarding.download.")
        preview.tap()
        let translation = app.buttons["onboarding.preview.candidate.0"]
        let translated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS '你好吗？'"), object: translation)
        XCTAssertEqual(XCTWaiter.wait(for: [translated], timeout: 8), .completed)
        XCTAssertTrue(app.buttons["onboarding.preview.candidate.0"].label.contains("how are you"))
        attachState(app, name: "Onboarding live English to Chinese example")

        // Continue from the saved page after a process restart, without resetting it.
        app.terminate()
        app.launchArguments.removeAll { $0 == "--reset-onboarding" }
        app.launch()
        XCTAssertTrue(app.textFields["onboarding.language.search"].waitForExistence(timeout: 10))
        let download = app.buttons[downloadID]
        for _ in 0..<5 where !download.isHittable { app.swipeUp() }
        XCTAssertTrue(download.exists)
        download.tap()
        // This iPhone already has English / Chinese resources; verify against the real system.
        let next = app.buttons["onboarding.next"]
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: next)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 30), .completed)
        next.tap()
        // Existing members have a close button but no basic-keyboard skip action.
        let closeMembership = app.buttons["membership.close"]
        XCTAssertTrue(closeMembership.waitForExistence(timeout: 10))
        closeMembership.tap()
        XCTAssertTrue(app.buttons["onboarding.openSettings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["onboarding.download.status"].exists)
        let permission = app.staticTexts["setup.fullAccess.requirement"]
        for _ in 0..<4 where !permission.isHittable { app.swipeUp() }
        XCTAssertTrue(permission.label.contains("real-time translation"))
        attachState(app, name: "Onboarding full access step")
        let openSettings = app.buttons["onboarding.openSettings"]
        for _ in 0..<4 where !openSettings.isHittable { app.swipeUp() }
        openSettings.tap()
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 10))
        app.activate()
        XCTAssertTrue(app.buttons["onboarding.next"].waitForExistence(timeout: 10))
        app.buttons["onboarding.next"].tap()
        XCTAssertTrue(app.navigationBars["TypeToLearn"].waitForExistence(timeout: 10))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.navigationBars["TypeToLearn"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["onboarding.audience.english"].exists)
        let setup = app.buttons["Enable TypeToLearn"]
        for _ in 0..<8 where !setup.isHittable { app.swipeUp() }
        XCTAssertTrue(setup.isHittable)
        setup.tap()
        XCTAssertTrue(app.staticTexts["setup.fullAccess.requirement"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["setup.fullAccess.requirement"].label.contains("real-time translation"))
        attachState(app, name: "Home keyboard setup full access step")
        app.navigationBars.buttons.firstMatch.tap()
    }

    @MainActor
    func testOnboardingChineseLocalizationsOnPhysicalIPhone() throws {
        let app = XCUIApplication()
        for (locale, title, sample) in [("zh-Hans", "中文键盘用户", "你好吗"), ("zh-Hant", "中文鍵盤使用者", "你好嗎")] {
            app.launchArguments = ["--physical-device-ui-test", "--onboarding-test-store", "--reset-onboarding", "-AppleLanguages", "(\(locale))"]
            app.launch()
            let choice = app.buttons["onboarding.audience.chinese"]
            XCTAssertTrue(choice.waitForExistence(timeout: 10))
            XCTAssertTrue(choice.label.contains(title), choice.label)
            choice.tap()
            attachState(app, name: "Onboarding \(locale) audience")
            app.buttons["onboarding.next"].tap()
            let preview = app.buttons["onboarding.language.en"]
            for _ in 0..<5 where !preview.isHittable { app.swipeUp() }
            XCTAssertTrue(preview.waitForExistence(timeout: 15))
            preview.tap()
            app.buttons["onboarding.preview.replay"].tap()
            let first = app.buttons["onboarding.preview.candidate.0"]
            XCTAssertTrue(first.label.contains("How are you?"), first.label)
            first.tap()
            XCTAssertEqual(app.staticTexts["onboarding.preview.input"].label, sample)
            let strip = app.scrollViews["onboarding.preview.candidates"]
            let originalX = first.frame.minX
            strip.swipeLeft(velocity: .slow)
            XCTAssertLessThan(first.frame.minX, originalX - 15, "Chinese preview must reveal its later candidates")
            strip.swipeRight(velocity: .slow)
            attachState(app, name: "Onboarding \(locale) language preview")
            app.terminate()
        }
        let home = launchApp()
        XCTAssertTrue(home.buttons["home.preview.candidate.0"].waitForExistence(timeout: 5))
        home.buttons["home.preview.replay"].tap()
        attachState(home, name: "Home shared preview final")
    }

    @MainActor
    func testChineseAndEnglishAudienceModesOnPhysicalIPhone() throws {
        let app = launchApp()

        func chooseAudience(english: Bool) {
            if app.buttons["Hide keyboard"].exists { app.buttons["Hide keyboard"].tap() }
            if app.buttons["收起键盘"].exists { app.buttons["收起键盘"].tap() }
            for _ in 0..<3 { app.swipeDown() }
            let labels = english ? ["英文用户", "English users"] : ["中文用户", "Chinese users"]
            let choice = app.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
            for _ in 0..<4 where !choice.isHittable { app.swipeUp() }
            XCTAssertTrue(choice.waitForExistence(timeout: 5))
            choice.tap()
        }

        func reveal(_ element: XCUIElement) {
            for _ in 0..<5 where !element.isHittable { app.swipeUp() }
            XCTAssertTrue(element.waitForExistence(timeout: 5))
        }

        chooseAudience(english: false)
        reveal(app.buttons["settings.chineseLayout"])
        reveal(app.buttons["settings.englishLearningLanguage"])
        reveal(app.buttons["english.language.prepare"])
        let phrases = app.buttons["settings.learnedWords"]
        for _ in 0..<3 where !phrases.isHittable { app.swipeUp() }
        XCTAssertTrue(phrases.exists)
        attachState(app, name: "Chinese audience input settings")

        chooseAudience(english: true)
        XCTAssertTrue(app.navigationBars["TypeToLearn"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["settings.chineseLayout"].exists)
        XCTAssertFalse(app.buttons["settings.englishLearningLanguage"].exists)
        XCTAssertFalse(app.buttons["english.language.prepare"].exists)
        XCTAssertFalse(app.buttons["settings.learnedWords"].exists)
        for _ in 0..<3 { app.swipeDown() }
        let learning = app.buttons["settings.learningLanguage"]
        XCTAssertTrue(learning.waitForExistence(timeout: 5))
        XCTAssertTrue(learning.label.contains("Translate into"))
        attachState(app, name: "English audience single learning language")
        learning.tap()
        XCTAssertTrue(app.navigationBars["Learning language"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.searchFields["Search languages"].exists)
        app.navigationBars.buttons.firstMatch.tap()

        // The choice must survive a fresh app/keyboard session.
        app.terminate()
        app.launch()
        XCTAssertTrue(app.navigationBars["TypeToLearn"].waitForExistence(timeout: 5))
        let editor = app.textViews["keyboard.test.editor"]
        for _ in 0..<6 where !editor.isHittable { app.swipeUp() }
        editor.tap()
        if !app.buttons["emoji.bottom"].waitForExistence(timeout: 5) {
            attachState(app, name: "Keyboard before selecting English audience extension")
            let next = app.buttons["Next keyboard"]
            XCTAssertTrue(next.waitForExistence(timeout: 5))
            next.press(forDuration: 1.2)
            let companion = app.cells.matching(NSPredicate(format: "label CONTAINS '伴语输入法' OR label CONTAINS 'TypeToLearn'")).firstMatch
            XCTAssertTrue(companion.waitForExistence(timeout: 5))
            companion.tap()
        }
        XCTAssertTrue(app.buttons["emoji.bottom"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["emoji.toolbar"].exists)
        XCTAssertFalse(app.buttons["切换中英文"].exists)
        XCTAssertFalse(app.buttons["切换中文输入方式"].exists)
        XCTAssertTrue(app.buttons["key.Space"].exists)
        XCTAssertTrue(app.buttons["key.Return"].exists)
        attachState(app, name: "English only keyboard with bottom emoji")
        for letter in "howareyou" {
            app.buttons["key.\(letter)"].tap()
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(app.buttons["candidate.how are you"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["candidate.howareyou"].exists)
        app.buttons["candidate.how are you"].tap()
        XCTAssertEqual(editor.value as? String, "how are you")
        app.buttons["emoji.bottom"].tap()
        XCTAssertTrue(app.buttons["Back to letters"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["emoji.category.smileys"].label.contains("Smileys"))
        attachState(app, name: "English emoji interface")
        app.buttons["Back to letters"].tap()
        XCTAssertTrue(app.buttons["emoji.bottom"].exists)
        XCTAssertFalse(app.buttons["切换中英文"].exists)
        app.buttons["key.123"].tap()
        XCTAssertTrue(app.buttons["key.back"].exists)
        app.buttons["key.back"].tap()
        XCTAssertTrue(app.buttons["emoji.bottom"].exists)
        app.buttons["Hide keyboard"].tap()

        chooseAudience(english: false)
        XCTAssertTrue(app.navigationBars["伴语输入法"].waitForExistence(timeout: 5))
        reveal(app.buttons["settings.chineseLayout"])
        reveal(app.buttons["settings.englishLearningLanguage"])
        for _ in 0..<6 where !editor.isHittable { app.swipeUp() }
        editor.tap()
        try selectPinyinKeyboard(in: app)
        XCTAssertTrue(app.buttons["emoji.toolbar"].exists)
        XCTAssertFalse(app.buttons["emoji.bottom"].exists)
        XCTAssertTrue(app.buttons["切换中英文"].exists)
        for letter in "nihao" { app.buttons["key.\(letter)"].tap() }
        XCTAssertTrue(app.buttons["candidate.你好"].waitForExistence(timeout: 5))
        app.buttons["candidate.你好"].tap()
        // Retapping the editor may place the caret before the earlier English text.
        let chineseCommit = XCTNSPredicateExpectation(predicate: NSPredicate(
            format: "value CONTAINS '你好' AND value CONTAINS 'how are you' AND NOT (value CONTAINS 'nihao')"), object: editor)
        let committed = XCTWaiter.wait(for: [chineseCommit], timeout: 5)
        attachState(app, name: "Restored Chinese keyboard after audience switch")
        XCTAssertEqual(committed, .completed, "Actual input: \(editor.value as? String ?? "nil")")
    }

    @MainActor
    func testEnglishSpacingAndPredictionOnPhysicalIPhone() throws {
        let app = launchApp()
        let editor = app.textViews["键盘测试输入框"]
        for _ in 0..<5 where !editor.isHittable { app.swipeUp() }
        editor.tap()
        try selectPinyinKeyboard(in: app)
        app.buttons["切换中英文"].tap()

        func type(_ text: String) {
            for letter in text {
                app.buttons["key.\(letter)"].tap()
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        type("youare")
        let phrase = app.buttons["candidate.you are"]
        XCTAssertTrue(phrase.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["candidate.youare"].exists, "A spacing repair replaces the redundant raw candidate")
        attachState(app, name: "English missing-space phrase")
        app.buttons["key.选定"].tap()
        XCTAssertTrue((editor.value as? String)?.hasSuffix("you are ") == true)
        app.buttons["key.换行"].tap()

        type("you")
        app.buttons["candidate.you"].tap()
        let are = app.buttons["candidate.are"]
        XCTAssertTrue(are.waitForExistence(timeout: 5), "Offer the next word after selecting you")
        XCTAssertTrue(app.buttons["表情符号"].exists, "Predictions must preserve toolbar actions")
        are.tap()
        XCTAssertTrue((editor.value as? String)?.hasSuffix("you are") == true,
                      "Selecting the next word inserts exactly one separator")
        type("ready")
        app.buttons["candidate.ready"].tap()
        XCTAssertTrue((editor.value as? String)?.hasSuffix("you are ready") == true)
        attachState(app, name: "English context predictions")

        app.buttons["英文逗号，长按句号"].tap()
        XCTAssertTrue((editor.value as? String)?.hasSuffix("ready,") == true)
        XCTAssertFalse(app.buttons["candidate.for"].exists, "Punctuation resets phrase context")
        type("youare")
        XCTAssertTrue(app.buttons["candidate.you are"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["candidate.youare"].exists)
        app.buttons["key.确认"].tap()
        XCTAssertTrue((editor.value as? String)?.hasSuffix("ready,youare") == true,
                      "Return commits the original spelling without repair")
    }

    @MainActor
    func testEnglishPhraseTranslationOnPhysicalIPhone() throws {
        let app = launchApp()
        let editor = app.textViews["键盘测试输入框"]
        for _ in 0..<5 where !editor.isHittable { app.swipeUp() }
        editor.tap()
        try selectPinyinKeyboard(in: app)
        app.buttons["切换中英文"].tap()
        for letter in "howareyou" {
            app.buttons["key.\(letter)"].tap()
            Thread.sleep(forTimeInterval: 0.1)
        }
        let phrase = app.buttons["candidate.how are you"]
        XCTAssertTrue(phrase.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["candidate.howareyou"].exists)
        let translated = XCTNSPredicateExpectation(predicate: NSPredicate(
            format: "label BEGINSWITH 'how are you，' AND label != 'how are you，…' AND label != 'how are you，待下载' AND label != 'how are you，暂不可用'"), object: phrase)
        XCTAssertEqual(XCTWaiter.wait(for: [translated], timeout: 30), .completed,
                       "Requires the configured English target language to be installed on this iPhone")
        let translation = phrase.label.components(separatedBy: "，").dropFirst().joined(separator: "，")
        XCTAssertFalse(translation.isEmpty)
        attachState(app, name: "English phrase with real system translation")
        pressKeyboardChrome(phrase, duration: 0.75)
        XCTAssertTrue((editor.value as? String)?.hasSuffix(translation) == true)
    }

    override func setUpWithError() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical devices only")
        #endif
        continueAfterFailure = false
    }

    @MainActor
    private func dismissPastePrompt() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deny = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["不允许粘贴", "不允許貼上", "Don’t Allow Paste", "Don't Allow Paste"])).firstMatch
        if deny.exists { deny.tap() }
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--physical-device-ui-test"]
        app.launch()
        dismissPastePrompt()
        return app
    }

    @MainActor
    private func composeGreeting(in app: XCUIApplication) throws -> XCUIElement {
        let editor = app.textViews["键盘测试输入框"]
        for _ in 0..<5 where !editor.isHittable { app.swipeUp() }
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        // The user enables 伴语输入法 beforehand; select it from the system globe list if needed.
        if !app.buttons["key.n"].waitForExistence(timeout: 5) { try selectPinyinKeyboard(in: app) }
        for key in ["n", "i", "h", "a", "o"] { app.buttons["key.\(key)"].tap() }
        let candidate = app.buttons["candidate.你好"]
        XCTAssertTrue(candidate.waitForExistence(timeout: 10))
        return candidate
    }

    @MainActor
    private func attachState(_ app: XCUIApplication, name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
        let state = XCTAttachment(string: app.debugDescription)
        state.name = "\(name) accessibility"
        state.lifetime = .keepAlways
        add(state)
    }

    @MainActor
    private func selectPinyinKeyboard(in app: XCUIApplication) throws {
        if findPinyinLayout(in: app) { return }
        let nextKeyboard = app.buttons.matching(NSPredicate(format: "label IN %@", ["Next keyboard", "下一个键盘", "下一個鍵盤"])).firstMatch
        if nextKeyboard.exists && !app.buttons["切换中文输入方式"].exists {
            pressKeyboardChrome(nextKeyboard, duration: 1.2)
            let companion = app.cells.matching(NSPredicate(format: "label CONTAINS '伴语输入法'")).firstMatch
            if companion.exists {
                companion.tap()
                if findPinyinLayout(in: app) { return }
            }
        }
        for _ in 0..<12 {
            if findPinyinLayout(in: app) { return }
            let next = nextKeyboard
            guard next.exists else { break }
            tapKeyboardChrome(next)
            dismissPastePrompt()
        }
        throw XCTSkip("Select the enabled 伴语输入法 keyboard on the physical iPhone")
    }

    @MainActor
    private func findPinyinLayout(in app: XCUIApplication) -> Bool {
        if app.buttons["返回键盘"].exists { tapKeyboardChrome(app.buttons["返回键盘"]) }
        if app.buttons["返回字母键盘"].exists { tapKeyboardChrome(app.buttons["返回字母键盘"]) }
        if app.buttons["key.返回"].exists { app.buttons["key.返回"].tap() }
        for _ in 0..<3 {
            if app.buttons["key.n"].exists && app.buttons["切换中英文"].exists { return true }
            let layout = app.buttons["切换中文输入方式"]
            guard layout.exists else { break }
            tapKeyboardChrome(layout)
        }
        return app.buttons["key.n"].exists && app.buttons["切换中英文"].exists
    }

    @MainActor
    private func tapKeyboardChrome(_ element: XCUIElement) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: element.frame.midX, dy: element.frame.midY)).tap()
    }

    @MainActor
    private func pressKeyboardChrome(_ element: XCUIElement, duration: TimeInterval) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: element.frame.midX, dy: element.frame.midY))
            .press(forDuration: duration)
    }

    @MainActor
    func testCompactKeyboardOnPhysicalIPhone() throws {
        let app = launchApp()
        let candidate = try composeGreeting(in: app)
        XCTAssertGreaterThanOrEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'candidate.'")).count, 5)
        let strip = app.scrollViews["candidate.strip"]
        XCTAssertTrue(strip.exists)
        let second = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'candidate.'")).element(boundBy: 1)
        let originalX = second.frame.minX
        let start = strip.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
        let end = strip.coordinate(withNormalizedOffset: CGVector(dx: 0.58, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertLessThan(second.frame.minX, originalX - 15, "Candidate strip must follow a short horizontal drag")
        XCTAssertGreaterThan(second.frame.minX, originalX - 90, "A short drag must not jump to another page")
        attachState(app, name: "Continuous candidate scroll between words")
        strip.swipeRight(velocity: .slow)
        XCTAssertLessThan(app.buttons["key.确认"].frame.maxY - candidate.frame.minY, 285)
        XCTAssertFalse(app.buttons["切换到下一个系统键盘"].exists, "The test iPhone provides its own globe")
        attachState(app, name: "Compact keyboard on physical iPhone")
        candidate.tap()
        XCTAssertTrue((app.textViews["键盘测试输入框"].value as? String)?.contains("你好") == true)
    }

    @MainActor
    func testDownloadedEnglishTranslationOnPhysicalIPhone() throws {
        let app = launchApp()
        app.swipeDown()
        app.swipeDown()
        guard app.buttons.matching(NSPredicate(format: "label BEGINSWITH '翻译成, 英语'")).firstMatch.exists else {
            throw XCTSkip("Choose English in 伴语输入法 before this test")
        }
        let prepare = app.buttons["language.prepare"]
        XCTAssertTrue(prepare.waitForExistence(timeout: 10))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: prepare)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 20), .completed)
        if prepare.frame.minY < 180 { app.swipeDown() }
        prepare.tap()
        let preparation = app.staticTexts["language.preparation.status"]
        XCTAssertTrue(preparation.waitForExistence(timeout: 5))
        let verified = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH '离线翻译已验证'"), object: preparation)
        let prepared = XCTWaiter.wait(for: [verified], timeout: 90)
        attachState(app, name: "Language preparation")
        XCTAssertEqual(prepared, .completed, "System language resources must finish downloading")
        let candidate = try composeGreeting(in: app)
        let translated = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS[c] 'hello' OR label CONTAINS[c] 'hi'"), object: candidate)
        let result = XCTWaiter.wait(for: [translated], timeout: 20)
        attachState(app, name: "Chinese and English candidates")
        XCTAssertEqual(result, .completed, "Actual Apple translation must appear: \(candidate.label)")
    }

    @MainActor
    func testMixedPinyinAndLongSentenceOnPhysicalIPhone() throws {
        let app = launchApp()
        let editor = app.textViews["键盘测试输入框"]
        for _ in 0..<5 where !editor.isHittable { app.swipeUp() }
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        try selectPinyinKeyboard(in: app)
        for letter in "nhao" { app.buttons["key.\(letter)"].tap() }
        let greeting = app.buttons["candidate.你好"]
        XCTAssertTrue(greeting.waitForExistence(timeout: 10))
        let translated = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS[c] 'hello' OR label CONTAINS[c] 'hi'"), object: greeting)
        XCTAssertEqual(XCTWaiter.wait(for: [translated], timeout: 20), .completed)
        attachState(app, name: "Mixed pinyin nhao with English translation")
        greeting.tap()
        let greetingInserted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS '你好'"), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [greetingInserted], timeout: 5), .completed)

        let raw = "wojintianxiangquchaoshimaipingguoranhouhuijiazuofanchifan"
        let sentence = "我今天想去超市买苹果然后回家做饭吃饭"
        for letter in raw {
            let key = app.buttons["key.\(letter)"]
            XCTAssertTrue(key.exists)
            let frame = key.frame
            let input = app.otherElements["inputView"].frame
            let offset = frame.maxY <= input.height ? input.origin : .zero
            // XCTest's automatic scroll-to-visible can dismiss a remote keyboard.
            // Use the key's actual screen location, as for candidate buttons.
            XCUIApplication(bundleIdentifier: "com.apple.springboard")
                .coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: frame.midX + offset.x, dy: frame.midY + offset.y)).tap()
        }
        let whole = app.buttons["candidate.\(sentence)"]
        XCTAssertTrue(whole.waitForExistence(timeout: 10), "A sentence beyond 48 letters must remain a single selectable candidate")
        attachState(app, name: "Whole sentence candidate on physical iPhone")
        whole.tap()
        let inserted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", sentence), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [inserted], timeout: 5), .completed)
        XCTAssertTrue(app.buttons["key.n"].exists, "Keyboard must stay alive after sentence conversion and translation")
        attachState(app, name: "Whole sentence inserted")

        app.buttons["切换中文输入方式"].tap()
        XCTAssertTrue(app.buttons["key.mno"].waitForExistence(timeout: 5))
        for key in ["mno", "ghi", "ghi", "abc", "mno"] { app.buttons["key.\(key)"].tap() }
        XCTAssertTrue(greeting.waitForExistence(timeout: 10))
        greeting.tap()
        XCTAssertTrue(app.buttons["切换中文输入方式"].waitForExistence(timeout: 5))
        app.buttons["切换中文输入方式"].tap()
        XCTAssertTrue(app.buttons["key.日"].waitForExistence(timeout: 5))
        app.buttons["key.日"].tap()
        let sun = app.buttons["candidate.日"]
        XCTAssertTrue(sun.waitForExistence(timeout: 10))
        sun.tap()
        let cangjieInserted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value ENDSWITH '你好日'"), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [cangjieInserted], timeout: 5), .completed)
        app.buttons["切换中文输入方式"].tap()
        XCTAssertTrue(app.buttons["key.n"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testHostCaretEditingAndOutsidePinyinOnPhysicalIPhone() throws {
        let app = launchApp()
        let editor = app.textViews["键盘测试输入框"]
        for _ in 0..<5 where !editor.isHittable { app.swipeUp() }
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        try selectPinyinKeyboard(in: app)
        attachState(app, name: "Narrow single-fold paste icon in keyboard toolbar")
        for letter in "niqunali" { app.buttons["key.\(letter)"].tap() }
        let font = UIFont.preferredFont(forTextStyle: .body)
        let prefixWidth = ("niqu" as NSString).size(withAttributes: [.font: font]).width
        let point = editor.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 5 + prefixWidth, dy: 8 + font.lineHeight / 2))
        // UIKit may snap a single tap in a Latin word to its end. Drag its native
        // caret to test the actual interior position, without changing the host editor.
        let endWidth = ("niqunali" as NSString).size(withAttributes: [.font: font]).width
        editor.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 5 + endWidth, dy: 8 + font.lineHeight / 2))
            .press(forDuration: 0.65, thenDragTo: point)
        attachState(app, name: "Caret moved within pinyin in host editor")
        XCTAssertTrue(app.buttons["key.选定"].exists, "Moving the host caret within pinyin must preserve composition")
        app.buttons["key.x"].tap()
        attachState(app, name: "Tap inside pinyin and insert at host caret")
        XCTAssertEqual(editor.value as? String, "niquxnali")
        app.buttons["退格"].tap()
        XCTAssertEqual(editor.value as? String, "niqunali")
        editor.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: editor.frame.width - 16, dy: 8 + font.lineHeight / 2)).tap()
        XCTAssertTrue(app.buttons["key.空格"].waitForExistence(timeout: 5),
                      "Tapping blank space must commit the raw code")
        XCTAssertEqual(editor.value as? String, "niqunali", "No deletion or duplicate insertion")
        for letter in "nihao" { app.buttons["key.\(letter)"].tap() }
        let greeting = app.buttons["candidate.你好"]
        XCTAssertTrue(greeting.waitForExistence(timeout: 10))
        let input = app.otherElements["inputView"].frame
        let frame = greeting.frame
        let offset = frame.maxY <= input.height ? input.origin : .zero
        XCUIApplication(bundleIdentifier: "com.apple.springboard")
            .coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX + offset.x, dy: frame.midY + offset.y)).tap()
        let inserted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'niqunali你好'"), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [inserted], timeout: 5), .completed)
        attachState(app, name: "Outside tap commits raw pinyin before next composition")
        for letter in "uu" { app.buttons["key.\(letter)"].tap() }
        editor.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: editor.frame.width - 16, dy: 8 + font.lineHeight / 2)).tap()
        XCTAssertTrue(app.buttons["key.空格"].waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, "niqunali你好uu", "Blank tap also commits when the caret was already at the end")
    }

    @MainActor
    func testEnglishCompositionCursorOnPhysicalIPhone() throws {
        let app = launchApp()
        let editor = app.textViews["键盘测试输入框"]
        for _ in 0..<5 where !editor.isHittable { app.swipeUp() }
        editor.tap()
        try selectPinyinKeyboard(in: app)
        if !app.buttons["英文逗号，长按句号"].exists { tapKeyboardChrome(app.buttons["切换中英文"]) }
        defer { if app.buttons["英文逗号，长按句号"].exists { tapKeyboardChrome(app.buttons["切换中英文"]) } }
        for letter in "helo" { app.buttons["key.\(letter)"].tap() }
        let space = app.buttons["key.选定"]
        XCTAssertTrue(space.waitForExistence(timeout: 5))
        let input = app.otherElements["inputView"].frame
        let frame = space.frame
        let offset = frame.maxY <= input.height ? input.origin : .zero
        let start = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            .coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX + offset.x, dy: frame.midY + offset.y))
        start.press(forDuration: 0.65, thenDragTo: start.withOffset(CGVector(dx: -13, dy: 0)))
        XCTAssertTrue(space.exists)
        app.buttons["key.l"].tap()
        XCTAssertEqual((editor.value as? String)?.lowercased(), "hello")
        start.press(forDuration: 0.65, thenDragTo: start.withOffset(CGVector(dx: 13, dy: 0)))
        XCTAssertTrue(space.exists, "Returning to the end via space drag must keep candidates")
        start.press(forDuration: 0.65, thenDragTo: start.withOffset(CGVector(dx: -13, dy: 0)))
        XCTAssertTrue(space.exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'candidate.'")).firstMatch.exists)
        let font = UIFont.preferredFont(forTextStyle: .body)
        let prefix = String((editor.value as? String ?? "").prefix(2))
        let width = (prefix as NSString).size(withAttributes: [.font: font]).width
        let endWidth = (String((editor.value as? String ?? "").prefix(4)) as NSString).size(withAttributes: [.font: font]).width
        editor.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 5 + endWidth, dy: 8 + font.lineHeight / 2))
            .press(forDuration: 0.65, thenDragTo: editor.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: 5 + width, dy: 8 + font.lineHeight / 2)))
        app.buttons["key.x"].tap()
        XCTAssertEqual((editor.value as? String)?.lowercased(), "hexllo")
        app.buttons["退格"].tap()
        XCTAssertEqual((editor.value as? String)?.lowercased(), "hello")
        editor.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: editor.frame.width - 16, dy: 8 + font.lineHeight / 2)).tap()
        XCTAssertTrue(app.buttons["key.空格"].waitForExistence(timeout: 5))
        XCTAssertEqual((editor.value as? String)?.lowercased(), "hello")
        attachState(app, name: "English cursor editing and blank tap commit")
    }

    @MainActor
    func testEditingPinyinAndRawFallbackOnPhysicalIPhone() throws {
        let app = launchApp()
        let editor = app.textViews["键盘测试输入框"]
        for _ in 0..<5 where !editor.isHittable { app.swipeUp() }
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        try selectPinyinKeyboard(in: app)
        for letter in "niquali" { app.buttons["key.\(letter)"].tap() }
        let space = app.buttons["key.选定"]
        XCTAssertTrue(space.waitForExistence(timeout: 5))
        let strip = app.scrollViews["candidate.strip"]
        XCTAssertTrue(strip.waitForExistence(timeout: 5))
        let input = app.otherElements["inputView"].frame
        let frame = space.frame
        let offset = frame.maxY <= input.height ? input.origin : .zero
        let start = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            .coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX + offset.x, dy: frame.midY + offset.y))
        // Three 12pt steps: niqu|ali. Long press must keep this code marked.
        start.press(forDuration: 0.65, thenDragTo: start.withOffset(CGVector(dx: -39, dy: 0)))
        XCTAssertTrue(space.exists, "Dragging within composition must not end candidate selection")
        XCTAssertTrue(strip.exists)
        app.buttons["key.n"].tap()
        XCTAssertTrue((editor.value as? String)?.hasSuffix("niqunali") == true,
                      "Insert the missing n at the marked-text cursor")
        let corrected = app.buttons["candidate.你去哪里"]
        XCTAssertTrue(corrected.waitForExistence(timeout: 10))
        attachState(app, name: "Pinyin corrected in place with candidates still active")
        let candidateFrame = corrected.frame
        let candidateOffset = candidateFrame.maxY <= input.height ? input.origin : .zero
        XCUIApplication(bundleIdentifier: "com.apple.springboard")
            .coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: candidateFrame.midX + candidateOffset.x,
                                 dy: candidateFrame.midY + candidateOffset.y)).tap()
        let inserted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value ENDSWITH '你去哪里'"), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [inserted], timeout: 5), .completed)
        for _ in 0..<2 { app.buttons["key.u"].tap() }
        let raw = app.buttons["candidate.uu"]
        XCTAssertTrue(raw.waitForExistence(timeout: 10), "No-match input must offer its original text")
        XCTAssertFalse(strip.staticTexts["…"].exists)
        attachState(app, name: "Unmatched uu offered as a raw candidate")
        let rawFrame = raw.frame
        let rawOffset = rawFrame.maxY <= input.height ? input.origin : .zero
        XCUIApplication(bundleIdentifier: "com.apple.springboard")
            .coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: rawFrame.midX + rawOffset.x, dy: rawFrame.midY + rawOffset.y)).tap()
        XCTAssertEqual(editor.value as? String, "你去哪里uu")
        XCTAssertTrue(app.buttons["key.空格"].exists, "Selecting raw input must finish composition")
    }

    @MainActor
    func testTypingIndicatorAndTranslationOnPhysicalIPhone() throws {
        let app = launchApp()
        let first = try composeGreeting(in: app)
        let strip = app.scrollViews["candidate.strip"]
        XCTAssertTrue(strip.waitForExistence(timeout: 5))
        let pending = strip.buttons.matching(NSPredicate(format: "value IN %@", ["正在翻译", "Translating"]))
        XCTAssertLessThanOrEqual(pending.count, 1, "Only one candidate may show the loading indicator")
        XCTAssertEqual(strip.buttons.matching(NSPredicate(format: "label CONTAINS '…'")).count, 0)
        let frameBeforeTranslation = first.frame
        let translated = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label BEGINSWITH '你好，' AND label != '你好，待下载'"), object: first)
        XCTAssertEqual(XCTWaiter.wait(for: [translated], timeout: 25), .completed,
                       "Requires active learning access and the selected language pack on this iPhone")
        XCTAssertFalse(["正在翻译", "Translating"].contains(first.value as? String ?? ""))
        XCTAssertEqual(pending.count, 0, "The first translation ends the shared loading indicator")
        XCTAssertEqual(first.frame, frameBeforeTranslation, "Translation must not move the candidate")
        attachState(app, name: "Typing indicator replaced by first translation")
        tapKeyboardChrome(first)
        let editor = app.textViews["键盘测试输入框"]
        let inserted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS '你好'"), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [inserted], timeout: 5), .completed)
    }

    @MainActor
    func testAlternatePronunciationsOnPhysicalIPhone() throws {
        let app = launchApp()
        let editor = app.textViews["键盘测试输入框"]
        for _ in 0..<5 where !editor.isHittable { app.swipeUp() }
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        try selectPinyinKeyboard(in: app)
        for (raw, expected) in [("shui", "谁"), ("shei", "谁"), ("shou", "熟"),
                                ("yao", "钥"), ("jue", "嚼"), ("zhai", "择"),
                                ("jiaose", "角色"), ("moju", "模具")] {
            for letter in raw { app.buttons["key.\(letter)"].tap() }
            let candidate = app.buttons["candidate.\(expected)"]
            let strip = app.scrollViews["candidate.strip"]
            XCTAssertTrue(strip.waitForExistence(timeout: 10))
            _ = candidate.waitForExistence(timeout: 2)
            // iOS can expose extension frames in inputView-local coordinates.
            // Clip to the visible strip and use screen coordinates: XCTest's
            // isHittable can throw for a partially clipped remote-view button.
            func coordinate(_ point: CGPoint) -> XCUICoordinate {
                let input = app.otherElements["inputView"].frame
                let offset = strip.frame.maxY <= input.height ? input.origin : .zero
                return XCUIApplication(bundleIdentifier: "com.apple.springboard")
                    .coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: point.x + offset.x, dy: point.y + offset.y))
            }
            // LazyHStack creates later candidates only after scrolling to them.
            for _ in 0..<24 {
                if candidate.exists {
                    let visible = candidate.frame.intersection(strip.frame)
                    if !visible.isNull && visible.width >= 30 { break }
                }
                let frame = strip.frame
                coordinate(CGPoint(x: frame.minX + frame.width * 0.8, y: frame.midY))
                    .press(forDuration: 0.05, thenDragTo:
                        coordinate(CGPoint(x: frame.minX + frame.width * 0.2, y: frame.midY)))
            }
            XCTAssertTrue(candidate.exists, "Missing \(raw) → \(expected)")
            let visible = candidate.frame.intersection(strip.frame)
            XCTAssertFalse(visible.isNull, "Candidate should be visible for \(raw)")
            XCTAssertGreaterThanOrEqual(visible.width, 30)
            coordinate(CGPoint(x: visible.midX, y: visible.midY)).tap()
            let inserted = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value ENDSWITH %@", expected), object: editor)
            XCTAssertEqual(XCTWaiter.wait(for: [inserted], timeout: 5), .completed)
        }
        attachState(app, name: "Alternate pronunciations committed on physical iPhone")
    }

    @MainActor
    func testInlinePinyinCompositionOnPhysicalIPhone() throws {
        let app = launchApp()
        let editor = app.textViews["键盘测试输入框"]
        for _ in 0..<5 where !editor.isHittable { app.swipeUp() }
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        try selectPinyinKeyboard(in: app)
        for key in "nhao" { app.buttons["key.\(key)"].tap() }
        attachState(app, name: "Inline composition after nhao")
        let marked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value ENDSWITH 'nhao'"), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [marked], timeout: 5), .completed,
                       "Unconfirmed pinyin should appear at the host cursor")
        attachState(app, name: "Unconfirmed pinyin inside input field")
        app.buttons["退格"].tap()
        let shortened = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value ENDSWITH 'nha'"), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [shortened], timeout: 5), .completed,
                       "Backspace should edit the marked pinyin")
        app.buttons["key.o"].tap()
        let greeting = app.buttons["candidate.你好"]
        XCTAssertTrue(greeting.waitForExistence(timeout: 10))
        greeting.tap()
        let converted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value ENDSWITH '你好'"), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [converted], timeout: 5), .completed,
                       "Choosing a word must replace marked pinyin without duplication")

        for key in "nihaoshijie" { app.buttons["key.\(key)"].tap() }
        let longer = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value ENDSWITH 'nihaoshijie'"), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [longer], timeout: 5), .completed)
        XCTAssertTrue(greeting.waitForExistence(timeout: 10))
        greeting.tap()
        let remaining = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value ENDSWITH '你好shijie'"), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [remaining], timeout: 5), .completed,
                       "Partial selection must keep the remaining code marked in the same field")
        attachState(app, name: "Partial selection leaves marked pinyin in input field")
        let globe = app.buttons["下一个键盘"].exists ? app.buttons["下一个键盘"] : app.buttons["Next keyboard"]
        XCTAssertTrue(globe.waitForExistence(timeout: 5))
        globe.tap()
        let preserved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value ENDSWITH '你好shijie'"), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [preserved], timeout: 5), .completed,
                       "Switching keyboards preserves visible raw code instead of deleting user input")
    }

    @MainActor
    func testPersonalPhraseMixedEnglishAndSymbolsOnPhysicalIPhone() throws {
        let app = launchApp()
        let editor = app.textViews["键盘测试输入框"]
        for _ in 0..<5 where !editor.isHittable { app.swipeUp() }
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        try selectPinyinKeyboard(in: app)
        for letter in "dise" { app.buttons["key.\(letter)"].tap() }
        let bottom = app.buttons["candidate.底"]
        for _ in 0..<4 where !bottom.exists { app.scrollViews["candidate.strip"].swipeLeft(velocity: .slow) }
        XCTAssertTrue(bottom.waitForExistence(timeout: 10))
        bottom.tap()
        let color = app.buttons["candidate.色"]
        XCTAssertTrue(color.waitForExistence(timeout: 10))
        color.tap()
        let learnedCommit = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value ENDSWITH '底色'"), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [learnedCommit], timeout: 5), .completed,
                       "Wait until the selected segments and learned phrase are committed")
        for letter in "dise" { app.buttons["key.\(letter)"].tap() }
        let learned = app.buttons["candidate.底色"]
        XCTAssertTrue(learned.waitForExistence(timeout: 10))
        attachState(app, name: "Learned phrase candidate order")
        XCTAssertLessThanOrEqual(learned.frame.minX, 50, "Learned phrase should be first")
        learned.tap()
        for letter in "app" {
            app.buttons["key.\(letter)"].tap()
            Thread.sleep(forTimeInterval: 0.12)
        }
        XCTAssertTrue((editor.value as? String)?.hasSuffix("app") == true)
        attachState(app, name: "Mixed English app candidate state")
        XCTAssertTrue(app.buttons["candidate.app"].waitForExistence(timeout: 10))
        app.buttons["candidate.app"].press(forDuration: 0.55)
        let originalEnglish = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS '底色底色app'"), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [originalEnglish], timeout: 5), .completed)

        app.buttons["切换中英文"].tap()
        app.buttons["key.123"].tap()
        XCTAssertTrue(app.buttons["key.#+="].exists)
        XCTAssertTrue(app.buttons["key.."].exists)
        app.buttons["key.#+="].tap()
        XCTAssertTrue(app.buttons["key.123"].exists)
        attachState(app, name: "English alternate symbol page")
        app.buttons["key.返回"].tap()
        let punctuation = app.buttons["英文逗号，长按句号"]
        XCTAssertTrue(punctuation.exists)
        punctuation.tap()
        let comma = editor.value as? String
        XCTAssertTrue(comma?.hasSuffix("app,") == true)
        punctuation.press(forDuration: 0.55)
        XCTAssertEqual(editor.value as? String, comma.map { $0 + "." },
                       "Long press should insert one period without also inserting a comma")

        tapKeyboardChrome(app.buttons["收起键盘"])
        let phrases = app.buttons["settings.learnedWords"]
        for _ in 0..<5 where !phrases.isHittable { app.swipeDown() }
        phrases.tap()
        let savedPhrase = app.staticTexts["底色"].firstMatch
        XCTAssertTrue(savedPhrase.waitForExistence(timeout: 5))
        let deleteCount = app.buttons.matching(NSPredicate(format: "label == '删除底色'")).count
        savedPhrase.tap()
        XCTAssertTrue(savedPhrase.exists, "Tapping phrase text must not trigger the row's delete button")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == '删除底色'")).count, deleteCount)
        attachState(app, name: "Personal phrase survives tapping its text")
    }

    @MainActor
    func testClipboardPanelOpensInOneTapOnPhysicalIPhone() throws {
        let app = launchApp()
        let editor = app.textViews["键盘测试输入框"]
        for _ in 0..<5 where !editor.isHittable { app.swipeUp() }
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        try selectPinyinKeyboard(in: app)
        let paste = app.buttons["打开剪贴板"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        paste.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons.matching(NSPredicate(format: "label CONTAINS '允许粘贴' OR label CONTAINS[c] 'Allow Paste'")).firstMatch
        if allow.waitForExistence(timeout: 3) {
            allow.tap()
            // iOS dismisses the keyboard while presenting the first paste alert.
            // Return to the field and retry after the user has granted access.
            if !app.buttons["key.n"].waitForExistence(timeout: 3) {
                editor.tap()
                try selectPinyinKeyboard(in: app)
            }
            app.buttons["打开剪贴板"].tap()
        }
        XCTAssertTrue(app.buttons["返回键盘"].waitForExistence(timeout: 10),
                      "One tap on the clipboard icon should open the current-content and saved-items panel")
        let current = app.buttons.matching(NSPredicate(format: "label CONTAINS '当前复制内容'")).firstMatch
        let empty = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '当前剪贴板没有可用文字'")).firstMatch
        XCTAssertTrue(current.waitForExistence(timeout: 3) || empty.exists,
                      "The panel should show the current clipboard preview or explain that no text is available")
        XCTAssertFalse(app.buttons["打开剪贴板"].exists, "Clipboard panel must not repeat the paste icon")
        app.buttons["返回键盘"].tap()
    }

    @MainActor
    func testSelectiveEnglishSuggestionsAndStableKeyboardHeightOnPhysicalIPhone() throws {
        let app = launchApp()
        let editor = app.textViews["键盘测试输入框"]
        for _ in 0..<5 where !editor.isHittable { app.swipeUp() }
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        try selectPinyinKeyboard(in: app)
        XCTAssertTrue(app.buttons["收起键盘"].exists)
        XCTAssertTrue(app.buttons["表情符号"].exists)
        let emptyKeyFrame = app.buttons["key.q"].frame
        let emptyDeleteFrame = app.buttons["退格"].frame
        for letter in "nihao" { app.buttons["key.\(letter)"].tap() }
        XCTAssertTrue(app.buttons["candidate.你好"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["candidate.nihao"].exists)
        XCTAssertFalse(app.buttons["重试翻译"].exists)
        XCTAssertFalse(app.buttons["打开剪贴板"].exists)
        XCTAssertFalse(app.buttons["切换中文输入方式"].exists)
        XCTAssertEqual(app.buttons["key.q"].frame.minY, emptyKeyFrame.minY, accuracy: 2,
                       "Candidate row must not shift the letter keys when composition starts")
        XCTAssertEqual(app.buttons["退格"].frame.height, emptyDeleteFrame.height, accuracy: 2)
        attachState(app, name: "Stable keyboard height while composing")
        app.buttons["candidate.你好"].tap()

        for letter in "appli" {
            app.buttons["key.\(letter)"].tap()
            Thread.sleep(forTimeInterval: 0.12)
        }
        XCTAssertTrue((editor.value as? String)?.hasSuffix("appli") == true)
        let application = app.buttons["candidate.application"]
        XCTAssertTrue(application.waitForExistence(timeout: 10), "Only a close English completion should appear in Chinese mode")
        XCTAssertLessThanOrEqual(application.frame.minX, 10, "The close English completion should be first")
        let englishCandidates = app.buttons.matching(NSPredicate(format: "identifier MATCHES 'candidate[.][A-Za-z]+'"))
        XCTAssertEqual(englishCandidates.count, 1)
        application.tap()
        for letter in "sdh" { app.buttons["key.\(letter)"].tap() }
        XCTAssertFalse(app.buttons["candidate.sdh"].exists)
        XCTAssertEqual(englishCandidates.count, 0, "Unrelated spellings should not crowd Chinese candidates")
        app.buttons["key.确认"].tap()

        app.buttons["切换中英文"].tap()
        for letter in "appli" {
            app.buttons["key.\(letter)"].tap()
            Thread.sleep(forTimeInterval: 0.12)
        }
        XCTAssertTrue(app.buttons["candidate.appli"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["candidate.application"].waitForExistence(timeout: 10),
                      "English mode should offer completions above the keyboard")
        attachState(app, name: "English mode completion candidates")
        app.buttons["candidate.application"].tap()
        XCTAssertTrue((editor.value as? String)?.contains("application") == true)

        app.buttons["表情符号"].tap()
        XCTAssertTrue(app.buttons["输入表情 😀"].firstMatch.waitForExistence(timeout: 5))
        let smile = try XCTUnwrap(app.buttons.matching(identifier: "输入表情 😀")
            .allElementsBoundByIndex.first(where: \.isHittable))
        smile.tap()
        XCTAssertTrue((editor.value as? String)?.contains("😀") == true)
        app.buttons["返回字母键盘"].tap()
        XCTAssertTrue(app.buttons["key.q"].exists)
        app.buttons["收起键盘"].tap()
        XCTAssertFalse(app.buttons["key.q"].waitForExistence(timeout: 2), "Collapse control should dismiss the keyboard")
    }

    @MainActor
    func testLetterKeyFaceHitAreasOnPhysicalIPhone() throws {
        let app = launchApp()
        let editor = app.textViews["keyboard.test.editor"]
        for _ in 0..<5 where !editor.isHittable { app.swipeUp() }
        editor.tap()
        try selectPinyinKeyboard(in: app)
        if app.buttons["切换大小写"].exists { app.buttons["切换中英文"].tap() }
        let screen = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        var expected = ""
        for letter in ["q", "a", "z"] {
            // The remote keyboard window precedes the noninteractive in-app preview.
            let key = app.buttons.matching(identifier: "key.\(letter)").firstMatch
            XCTAssertTrue(key.waitForExistence(timeout: 5))
            let hitFrame = key.frame
            let frame = hitFrame.inset(by: UIEdgeInsets(top: 2.5, left: letter == "a" ? 10 : (letter == "z" ? 6 : 3), bottom: 2.5, right: 3))
            let input = app.otherElements["inputView"].firstMatch.frame
            let offset = frame.maxY <= input.height ? input.origin : .zero
            XCTAssertEqual(frame.height, 46, accuracy: 1)
            let points = [
                CGPoint(x: frame.midX, y: frame.midY),
                CGPoint(x: frame.minX + 2, y: frame.midY),
                CGPoint(x: frame.maxX - 2, y: frame.midY),
                CGPoint(x: frame.midX, y: frame.minY + 2),
                CGPoint(x: frame.midX, y: frame.maxY - 2),
                CGPoint(x: frame.minX + 3, y: frame.minY + 3),
                CGPoint(x: frame.maxX - 3, y: frame.minY + 3),
                CGPoint(x: frame.minX + 3, y: frame.maxY - 3),
                CGPoint(x: frame.maxX - 3, y: frame.maxY - 3)
            ]
            for (index, point) in points.enumerated() {
                screen.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: point.x + offset.x, dy: point.y + offset.y)).tap()
                expected += letter
                let typed = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "value ENDSWITH %@", expected), object: editor)
                XCTAssertEqual(XCTWaiter.wait(for: [typed], timeout: 3), .completed,
                               "The entire \(letter) key face must type, including test point \(index): \(point)")
            }
        }
        attachState(app, name: "Letter key centers edges and corners")
    }

    @MainActor
    func testLetterKeyGapHitAreasOnPhysicalIPhone() throws {
        let app = launchApp()
        let editor = app.textViews["keyboard.test.editor"]
        for _ in 0..<5 where !editor.isHittable { app.swipeUp() }
        editor.tap()
        try selectPinyinKeyboard(in: app)
        if app.buttons["切换大小写"].exists { app.buttons["切换中英文"].tap() }
        let screen = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        var expected = ""
        func tap(_ point: CGPoint, offset: CGPoint, expecting letter: String) {
            screen.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: point.x + offset.x, dy: point.y + offset.y)).tap()
            expected += letter
            let typed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value ENDSWITH %@", expected), object: editor)
            XCTAssertEqual(XCTWaiter.wait(for: [typed], timeout: 3), .completed,
                           "Gap touches must type the nearest letter, once: \(expected)")
        }
        for (letter, neighbor) in [("q", "w"), ("a", "s"), ("z", "x")] {
            let frame = app.buttons.matching(identifier: "key.\(letter)").firstMatch.frame.inset(by: UIEdgeInsets(
                top: 5.5, left: letter == "a" ? 10 : (letter == "z" ? 6 : 3), bottom: 5.5, right: 3))
            let input = app.otherElements["inputView"].firstMatch.frame
            let offset = frame.maxY <= input.height ? input.origin : .zero
            tap(CGPoint(x: frame.maxX + 1, y: frame.midY), offset: offset, expecting: letter)
            tap(CGPoint(x: frame.maxX + 5, y: frame.midY), offset: offset, expecting: neighbor)
        }
        for (letter, below) in [("w", "s"), ("s", "z")] {
            let frame = app.buttons.matching(identifier: "key.\(letter)").firstMatch.frame.insetBy(dx: 3, dy: 5.5)
            let input = app.otherElements["inputView"].firstMatch.frame
            let offset = frame.maxY <= input.height ? input.origin : .zero
            tap(CGPoint(x: frame.maxX - 2, y: frame.maxY + 1), offset: offset, expecting: letter)
            tap(CGPoint(x: frame.maxX - 2, y: frame.maxY + 8), offset: offset, expecting: below)
        }
        attachState(app, name: "Horizontal and vertical letter gap input")
    }

    @MainActor
    func testLetterOuterAndModifierGapHitAreasOnPhysicalIPhone() throws {
        let app = launchApp()
        let editor = app.textViews["keyboard.test.editor"]
        for _ in 0..<5 where !editor.isHittable { app.swipeUp() }
        editor.tap()
        try selectPinyinKeyboard(in: app)
        if app.buttons["切换大小写"].exists { app.buttons["切换中英文"].tap() }
        let input = app.otherElements["inputView"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        let screen = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        func key(_ identifier: String) -> XCUIElement { app.buttons.matching(identifier: identifier).firstMatch }
        func face(_ identifier: String, left: CGFloat = 3, right: CGFloat = 3) -> CGRect {
            let frame = key(identifier).frame
            let origin = frame.maxY <= input.frame.height ? input.frame.origin : .zero
            return frame.offsetBy(dx: origin.x, dy: origin.y)
                .inset(by: UIEdgeInsets(top: 5.5, left: left, bottom: 5.5, right: right))
        }
        func tap(_ point: CGPoint) {
            screen.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: point.x, dy: point.y)).tap()
        }
        func expect(_ suffix: String) {
            let typed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value ENDSWITH %@", suffix), object: editor)
            XCTAssertEqual(XCTWaiter.wait(for: [typed], timeout: 3), .completed)
        }
        let a = face("key.a", left: 10)
        let l = face("key.l", right: 10)
        XCTAssertEqual(a.minX, 20, accuracy: 1)
        XCTAssertEqual(l.maxX, app.frame.width - 20, accuracy: 1)
        tap(CGPoint(x: a.minX - 9, y: a.midY))
        expect("a")
        tap(CGPoint(x: l.maxX + 9, y: l.midY))
        expect("al")
        // Outside the midpoint toward the keyboard edge stays unassigned.
        tap(CGPoint(x: a.minX - 11, y: a.midY))
        tap(CGPoint(x: l.maxX + 11, y: l.midY))
        XCTAssertEqual(editor.value as? String, "al")

        let separator = face("key.'", right: 6)
        let z = face("key.z", left: 6)
        XCTAssertEqual(z.minX - separator.maxX, 12, accuracy: 1)
        tap(CGPoint(x: separator.maxX + 5, y: separator.midY))
        expect("al'")
        tap(CGPoint(x: separator.maxX + 7, y: separator.midY))
        expect("al'z")
        let m = face("key.m", right: 6)
        let delete = face("退格", left: 6)
        XCTAssertEqual(delete.minX - m.maxX, 12, accuracy: 1)
        tap(CGPoint(x: m.maxX + 5, y: m.midY))
        expect("al'zm")
        tap(CGPoint(x: m.maxX + 7, y: m.midY))
        expect("al'z")
        attachState(app, name: "Outer A L and separator delete gap input")

        app.buttons["切换中英文"].tap()
        if key("key.z").label == "Z" { app.buttons["切换大小写"].tap() }
        let shift = face("切换大小写", right: 6)
        tap(CGPoint(x: shift.maxX + 5, y: shift.midY))
        XCTAssertEqual(key("key.z").label, "Z")
        tap(CGPoint(x: shift.maxX + 7, y: shift.midY))
        expect("al'zZ")
        tap(CGPoint(x: shift.maxX + 5, y: shift.midY))
        XCTAssertEqual(key("key.z").label, "z")
        tap(CGPoint(x: shift.maxX + 7, y: shift.midY))
        expect("al'zZz")
        let englishM = face("key.m", right: 6)
        tap(CGPoint(x: englishM.maxX + 7, y: englishM.midY))
        expect("al'zZ")
        tap(CGPoint(x: englishM.maxX + 5, y: englishM.midY))
        expect("al'zZm")
        attachState(app, name: "English shift Z and M delete gap input")
        app.buttons["切换中英文"].tap()
    }

    @MainActor
    private func revealKeyboardTestEditor(in app: XCUIApplication) -> XCUIElement {
        let editor = app.textViews["keyboard.test.editor"]
        let screen = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let keyboard = app.otherElements["inputView"].firstMatch
        let collapse = app.buttons.matching(NSPredicate(format: "label IN %@", ["收起键盘", "Hide keyboard"])).firstMatch
        if keyboard.exists, keyboard.frame.minY < app.frame.height, collapse.exists {
            let frame = collapse.frame
            let origin = frame.maxY <= keyboard.frame.height ? keyboard.frame.origin : .zero
            screen.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: frame.midX + origin.x, dy: frame.midY + origin.y)).tap()
        }
        // AX can report a clipped TextEditor as hittable below the keyboard.
        // Scroll above the keyboard and tap only a visibly exposed editor point.
        for _ in 0..<12 {
            if editor.exists, editor.frame.minY > 130, editor.frame.maxY < app.frame.height - 80 { break }
            let downward = editor.exists && editor.frame.minY < 130
            let start = screen.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: app.frame.width * 0.94, dy: downward ? 190 : 490))
            let end = screen.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: app.frame.width * 0.94, dy: downward ? 490 : 190))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(editor.exists)
        XCTAssertGreaterThan(editor.frame.minY, 130)
        XCTAssertLessThan(editor.frame.maxY, app.frame.height - 80)
        screen.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: editor.frame.midX, dy: editor.frame.minY + 20)).tap()
        return editor
    }

    @MainActor
    private func selectCompanionKeyboard(in app: XCUIApplication) throws {
        let next = app.buttons.matching(NSPredicate(format: "label IN %@", ["Next keyboard", "下一个键盘", "下一個鍵盤"])).firstMatch
        if next.waitForExistence(timeout: 5) {
            pressKeyboardChrome(next, duration: 1.2)
            let companion = app.cells.matching(NSPredicate(format: "label CONTAINS '伴语输入法' OR label CONTAINS 'TypeToLearn'")).firstMatch
            XCTAssertTrue(companion.waitForExistence(timeout: 5))
            companion.tap()
        }
        let back = app.buttons.matching(NSPredicate(format: "identifier IN %@", ["key.返回", "key.back"])).firstMatch
        if back.exists { back.tap() }
        XCTAssertTrue(app.buttons.matching(identifier: "key.q").firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["emoji.bottom"].exists || app.buttons["切换中英文"].exists,
                      "Select the actual companion keyboard in either audience mode")
    }

    @MainActor
    func testLetterRowSpacingOnPhysicalIPhone() throws {
        let app = launchApp()
        _ = revealKeyboardTestEditor(in: app)
        try selectCompanionKeyboard(in: app)
        let mode = app.buttons["切换中英文"]
        if mode.exists && !app.buttons["切换大小写"].exists { tapKeyboardChrome(mode) }
        XCTAssertTrue(app.buttons["切换大小写"].exists || app.buttons["emoji.bottom"].exists)
        let companionCenters = ["q", "a", "z"].map { app.buttons["key.\($0)"].frame.midY }
        attachState(app, name: "TypeToLearn letter rows")

        let next = app.buttons.matching(NSPredicate(format: "label IN %@", ["Next keyboard", "下一个键盘", "下一個鍵盤"])).firstMatch
        XCTAssertTrue(next.exists)
        pressKeyboardChrome(next, duration: 1.2)
        let english = app.cells.matching(NSPredicate(format: "label CONTAINS[c] 'English' OR label CONTAINS '英语' OR label CONTAINS '英文'")).firstMatch
        if english.waitForExistence(timeout: 3) {
            english.tap()
        } else {
            attachState(app, name: "Available system keyboards")
            XCTFail("Enable the iPhone’s built-in English keyboard to capture the comparison")
            return
        }
        let nativeLetters = ["q", "a", "z"].map { letter in
            app.keys.matching(NSPredicate(format: "label ==[c] %@", letter)).firstMatch
        }
        XCTAssertTrue(nativeLetters[0].waitForExistence(timeout: 5))
        let nativeCenters = nativeLetters.map { $0.frame.midY }
        for index in 0..<2 {
            XCTAssertEqual(companionCenters[index + 1] - companionCenters[index],
                           nativeCenters[index + 1] - nativeCenters[index], accuracy: 1)
        }
        attachState(app, name: "iOS English letter rows")
    }

    @MainActor
    func testDeleteIconAlignmentOnPhysicalIPhone() throws {
        let app = launchApp()
        defer { attachState(app, name: "Delete alignment final keyboard state") }
        _ = revealKeyboardTestEditor(in: app)
        try selectCompanionKeyboard(in: app)
        XCTAssertTrue(app.otherElements["inputView"].firstMatch.waitForExistence(timeout: 5))
        attachState(app, name: "Centered delete icon letter keyboard")
        app.buttons.matching(identifier: "key.123").firstMatch.tap()
        XCTAssertTrue(app.buttons.matching(identifier: "key.1").firstMatch.waitForExistence(timeout: 5))
        attachState(app, name: "Centered delete icon main symbols")
        app.buttons.matching(identifier: "key.#+=").firstMatch.tap()
        XCTAssertTrue(app.buttons.matching(identifier: "key.【").firstMatch.waitForExistence(timeout: 5))
        attachState(app, name: "Centered delete icon alternate symbols")
        let symbol = UIImage(systemName: "delete.left")!
        let metadata = XCTAttachment(string: "Delete symbol size: \(symbol.size), alignment: \(symbol.alignmentRectInsets)")
        metadata.lifetime = .keepAlways
        add(metadata)
    }

    @MainActor
    func testSymbolPageGapHitAreasOnPhysicalIPhone() throws {
        try verifySymbolPageGapHitAreas(english: false)
    }

    @MainActor
    func testEnglishSymbolPageGapHitAreasOnPhysicalIPhone() throws {
        try verifySymbolPageGapHitAreas(english: true)
    }

    @MainActor
    private func verifySymbolPageGapHitAreas(english: Bool) throws {
        let app = launchApp()
        let editor = revealKeyboardTestEditor(in: app)
        try selectCompanionKeyboard(in: app)
        let englishOnly = app.buttons["emoji.bottom"].exists
        if englishOnly && !english { throw XCTSkip("Chinese audience required for Chinese symbol fixtures") }
        if app.buttons["切换大小写"].exists { app.buttons["切换中英文"].tap() }
        let screen = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        var expected = ""
        func frame(_ identifier: String) -> CGRect {
            let result = app.buttons.matching(identifier: identifier).firstMatch.frame
            let input = app.otherElements["inputView"].firstMatch.frame
            return result.maxY <= input.height ? result.offsetBy(dx: input.minX, dy: input.minY) : result
        }
        func face(_ title: String) -> CGRect { frame("key.\(title)").insetBy(dx: 3, dy: 5.5) }
        func tap(_ point: CGPoint) {
            screen.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: point.x, dy: point.y)).tap()
        }
        func verify() {
            let typed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: editor)
            XCTAssertEqual(XCTWaiter.wait(for: [typed], timeout: 3), .completed)
        }
        func type(_ text: String, at point: CGPoint) {
            tap(point)
            expected += text
            verify()
        }
        do {
            if english && !englishOnly { app.buttons["切换中英文"].tap() }
            tap(CGPoint(x: frame("key.123").midX, y: frame("key.123").midY))
            for alternate in [false, true] {
                let first = alternate ? "【" : "1"
                let second = alternate ? "】" : "2"
                XCTAssertTrue(app.buttons.matching(identifier: "key.\(first)").firstMatch.waitForExistence(timeout: 5))
                let top = face(first)
                XCTAssertEqual(top.height, 45, accuracy: 1)
                type(first, at: CGPoint(x: top.maxX + 1, y: top.midY))
                type(second, at: CGPoint(x: top.maxX + 5, y: top.midY))
                type(first, at: CGPoint(x: top.midX, y: top.maxY + 3))
                type(alternate ? "_" : "@", at: CGPoint(x: top.midX, y: top.maxY + 8))

                let last = alternate ? ">" : (english ? "," : "’")
                let lastFace = face(last)
                let delete = frame(englishOnly ? "Delete" : "退格").insetBy(dx: 3, dy: 5.5)
                XCTAssertEqual(delete.minX - lastFace.maxX, 6, accuracy: 1)
                type(last, at: CGPoint(x: lastFace.maxX + 1, y: lastFace.midY))
                tap(CGPoint(x: lastFace.maxX + 5, y: lastFace.midY))
                expected.removeLast()
                verify()

                let lower = alternate ? "!" : (english ? ";" : "：")
                let lowerFace = face(lower)
                type(lower, at: CGPoint(x: lowerFace.midX, y: lowerFace.maxY + 3))
                type(" ", at: CGPoint(x: lowerFace.midX, y: lowerFace.maxY + 8))
                let toggle = face(alternate ? "123" : "#+=")
                type(" ", at: CGPoint(x: toggle.maxX + 5, y: toggle.midY))
                attachState(app, name: "Symbol gap input \(english ? "English" : "Chinese") \(alternate ? "alternate" : "main")")
                tap(CGPoint(x: toggle.maxX + 1, y: toggle.midY))
                verify()
            }
            let space = face(englishOnly ? "Space" : "空格")
            type(" ", at: CGPoint(x: space.maxX + 1, y: space.midY))
            type("\n", at: CGPoint(x: space.maxX + 5, y: space.midY))
            let back = face(englishOnly ? "back" : "返回")
            tap(CGPoint(x: back.maxX + 5, y: back.midY))
            XCTAssertTrue(app.buttons.matching(identifier: "key.【").firstMatch.waitForExistence(timeout: 5))
            tap(CGPoint(x: back.maxX + 1, y: back.midY))
            XCTAssertTrue(app.buttons.matching(identifier: "key.q").firstMatch.waitForExistence(timeout: 5))
            attachState(app, name: "Delete icon visible on \(english ? "English" : "Chinese") letter keyboard")
        }
        if english && !englishOnly { app.buttons["切换中英文"].tap() }
    }

    @MainActor
    func testRapidRepeatedLettersOnPhysicalIPhone() throws {
        let app = launchApp()
        let editor = app.textViews["键盘测试输入框"]
        for _ in 0..<5 where !editor.isHittable { app.swipeUp() }
        editor.tap()
        try selectPinyinKeyboard(in: app)
        for letter in "appli" { app.buttons.matching(identifier: "key.\(letter)").firstMatch.tap() }
        XCTAssertTrue((editor.value as? String)?.hasSuffix("appli") == true,
                      "Two rapid taps on the same letter must both reach the composing word")
        app.buttons["candidate.application"].tap()
        XCTAssertTrue((editor.value as? String)?.contains("application") == true)
    }

    @MainActor
    func testBuild7ToolbarEmojiSymbolsAndRepeatDeleteOnPhysicalIPhone() throws {
        let app = launchApp()
        let editor = app.textViews["键盘测试输入框"]
        for _ in 0..<5 where !editor.isHittable { app.swipeUp() }
        editor.tap()
        try selectPinyinKeyboard(in: app)
        let emoji = app.buttons["表情符号"]
        let clipboard = app.buttons["打开剪贴板"]
        let layout = app.buttons["切换中文输入方式"]
        let collapse = app.buttons["收起键盘"]
        XCTAssertTrue(emoji.exists && clipboard.exists && layout.exists && collapse.exists)
        XCTAssertLessThan(emoji.frame.minX, clipboard.frame.minX)
        XCTAssertLessThan(clipboard.frame.minX, layout.frame.minX)
        XCTAssertLessThan(layout.frame.minX, collapse.frame.minX)
        attachState(app, name: "Build 7 empty keyboard toolbar")

        emoji.tap()
        XCTAssertTrue(app.buttons["emoji.category.flags"].exists)
        app.buttons["emoji.category.food"].tap()
        XCTAssertTrue(app.buttons["输入表情 🍇"].waitForExistence(timeout: 5))
        attachState(app, name: "Build 7 categorized emoji keyboard")
        app.buttons["输入表情 🍇"].tap()
        app.buttons["emoji.category.component"].tap()
        XCTAssertTrue(app.buttons["输入表情 🏻"].waitForExistence(timeout: 5),
                      "Skin-tone components from the Unicode catalog should be available")
        app.buttons["emoji.category.recent"].tap()
        XCTAssertTrue(app.buttons["输入表情 🍇"].exists)
        app.buttons["返回字母键盘"].tap()

        let standardSpaceWidth = app.buttons["key.空格"].frame.width
        app.buttons["key.123"].tap()
        XCTAssertTrue(app.buttons["key.返回"].exists)
        XCTAssertFalse(app.buttons["切换中英文"].exists)
        XCTAssertGreaterThan(app.buttons["key.空格"].frame.width, standardSpaceWidth)
        attachState(app, name: "Build 7 symbols with wide space")
        app.buttons["key.返回"].tap()

        layout.tap()
        XCTAssertTrue(app.buttons["key.mno"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["九宫格拼音"].exists, "Tap-to-cycle should not open a layout menu")
        layout.tap()
        XCTAssertTrue(app.buttons["key.日"].waitForExistence(timeout: 5))
        layout.tap()
        XCTAssertTrue(app.buttons["key.a"].waitForExistence(timeout: 5))

        app.buttons["切换中英文"].tap()
        for letter in "keyboard" { app.buttons["key.\(letter)"].tap() }
        app.buttons["key.选定"].tap()
        let before = (editor.value as? String)?.count ?? 0
        app.buttons["退格"].press(forDuration: 1.2)
        let after = (editor.value as? String)?.count ?? 0
        XCTAssertGreaterThanOrEqual(before - after, 4, "Holding delete should remove several characters")
    }

    @MainActor
    func testChinesePersonalNameKeepsCorrectPinyinOnPhysicalIPhone() throws {
        let app = launchApp()
        let editor = app.textViews["键盘测试输入框"]
        for _ in 0..<5 where !editor.isHittable { app.swipeUp() }
        editor.tap()
        try selectPinyinKeyboard(in: app)
        for letter in "cjw" { app.buttons["key.\(letter)"].tap() }
        let name = app.buttons["candidate.陈佳文"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        let translated = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label BEGINSWITH '陈佳文，' AND label != '陈佳文，…'"), object: name)
        XCTAssertEqual(XCTWaiter.wait(for: [translated], timeout: 25), .completed)
        attachState(app, name: "Chinese personal name translation")
        XCTAssertTrue(name.label.lowercased().contains("chen jiawen"), name.label)
    }

    @MainActor
    func testExpandedChineseCandidateBrowserOnPhysicalIPhone() throws {
        let app = launchApp()
        let editor = app.textViews["键盘测试输入框"]
        for _ in 0..<5 where !editor.isHittable { app.swipeUp() }
        editor.tap()
        try selectPinyinKeyboard(in: app)

        for letter in "cjw" { app.buttons["key.\(letter)"].tap() }
        let expand = app.buttons["candidate.expand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 10))
        let compactTop = app.scrollViews["candidate.strip"].frame.minY
        attachState(app, name: "Compact candidate down arrow")
        expand.tap()
        let collapse = app.buttons["candidate.collapse"]
        XCTAssertTrue(collapse.waitForExistence(timeout: 5))
        let expandedList = app.scrollViews["candidate.expanded.list"]
        XCTAssertEqual(expandedList.frame.minY, compactTop, accuracy: 2,
                       "Expanding candidates must keep the keyboard at its original height")
        collapse.tap()
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        XCTAssertEqual(app.scrollViews["candidate.strip"].frame.minY, compactTop, accuracy: 2)
        expand.tap()
        XCTAssertTrue(collapse.waitForExistence(timeout: 5))
        for index in 0...2 { XCTAssertTrue(app.buttons["candidate.category.\(index)"].exists) }
        let firstTab = app.buttons["candidate.category.0"].frame
        let lastTab = app.buttons["candidate.category.2"].frame
        XCTAssertLessThanOrEqual(firstTab.height, 44.5, "Expanded tabs should use a compact row")
        let tabFraction = (lastTab.maxX - firstTab.minX) / (collapse.frame.maxX - firstTab.minX)
        XCTAssertGreaterThan(tabFraction, 0.72)
        XCTAssertLessThan(tabFraction, 0.82, "The three tabs should occupy the left part of the row")
        attachState(app, name: "Compact expanded candidate tabs")
        let list = app.scrollViews["candidate.expanded.list"]
        let fixedArrowTop = collapse.frame.minY
        list.swipeUp()
        XCTAssertLessThan(app.buttons["candidate.category.0"].frame.minY, firstTab.minY - 20,
                          "The category tabs should scroll with the candidate list")
        XCTAssertEqual(collapse.frame.minY, fixedArrowTop, accuracy: 2,
                       "The collapse arrow should stay fixed while candidates scroll")
        XCTAssertTrue(collapse.isHittable)
        for _ in 0..<4 where !app.buttons["candidate.category.1"].isHittable { list.swipeDown() }
        XCTAssertTrue(app.buttons["candidate.category.1"].isHittable)
        app.buttons["candidate.category.1"].tap()
        for index in 0...2 { XCTAssertTrue(app.buttons["candidate.single.group.\(index)"].waitForExistence(timeout: 5)) }
        attachState(app, name: "Expanded c j w single-character categories")

        for (word, remainingGroups) in [("从", 2), ("就", 1), ("我", 0)] {
            let candidate = app.buttons["candidate.\(word)"]
            XCTAssertTrue(candidate.waitForExistence(timeout: 10))
            if word != "从" {
                let translated = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "label BEGINSWITH %@ AND label != %@",
                        "\(word)，", "\(word)，…"), object: candidate)
                XCTAssertEqual(XCTWaiter.wait(for: [translated], timeout: 15), .completed,
                               "The next initial must show a translation for \(word)")
            }
            candidate.tap()
            if remainingGroups > 1 {
                XCTAssertTrue(app.buttons["candidate.single.group.\(remainingGroups - 1)"].waitForExistence(timeout: 10))
            }
        }
        XCTAssertTrue((editor.value as? String)?.contains("从就我") == true)

        for letter in "pin" { app.buttons["key.\(letter)"].tap() }
        app.buttons["candidate.expand"].tap()
        app.buttons["candidate.category.1"].tap()
        let nasal = app.buttons["candidate.single.group.1"]
        XCTAssertTrue(nasal.waitForExistence(timeout: 10))
        XCTAssertEqual(nasal.label, "ping")
        nasal.tap()
        let ping = app.buttons["candidate.平"]
        XCTAssertTrue(ping.waitForExistence(timeout: 10))
        ping.tap()
        XCTAssertTrue((editor.value as? String)?.contains("从就我平") == true)
        attachState(app, name: "Expanded nasal-correction single character")
    }

    @MainActor
    func testEnglishCandidateShowsDefaultChineseTranslationOnPhysicalIPhone() throws {
        let app = launchApp()
        let editor = app.textViews["键盘测试输入框"]
        for _ in 0..<5 where !editor.isHittable { app.swipeUp() }
        editor.tap()
        try selectPinyinKeyboard(in: app)
        app.buttons["切换中英文"].tap()
        for letter in "hello" { app.buttons["key.\(letter)"].tap() }
        let hello = app.buttons["candidate.hello"]
        XCTAssertTrue(hello.waitForExistence(timeout: 10))
        let translated = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS '你好' OR label CONTAINS '您好'"), object: hello)
        let result = XCTWaiter.wait(for: [translated], timeout: 25)
        attachState(app, name: "English candidate with default Chinese translation")
        XCTAssertEqual(result, .completed, "The English candidate should show its Chinese translation above it")
        for _ in 0..<5 { app.buttons["退格"].tap() }
        let hide = app.buttons["收起键盘"]
        XCTAssertTrue(hide.waitForExistence(timeout: 5))
        tapKeyboardChrome(hide)
        XCTAssertFalse(app.buttons["key.h"].exists)
        editor.tap()
        XCTAssertTrue(app.buttons["key.h"].waitForExistence(timeout: 5))
        for letter in "hello" { app.buttons["key.\(letter)"].tap() }
        XCTAssertTrue(hello.waitForExistence(timeout: 5))
        XCTAssertTrue(hello.label.contains("你好") || hello.label.contains("您好"),
                      "Reopened keyboard should show the recent cached translation with its candidate")
        // Repeated viewport updates must leave the current translation intact.
        let strip = app.scrollViews["candidate.strip"]
        strip.swipeLeft()
        strip.swipeRight()
        XCTAssertTrue(hello.waitForExistence(timeout: 5))
        XCTAssertTrue(hello.label.contains("你好") || hello.label.contains("您好"))
        attachState(app, name: "Recent translation after keyboard reopen and candidate scrolling")
    }

    @MainActor
    func testFirstLetterTranslationInSafariAfterHostExitOnPhysicalIPhone() throws {
        let app = launchApp()
        app.terminate()
        Thread.sleep(forTimeInterval: 10)
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.activate()
        defer { safari.terminate() }
        let address = safari.textFields.firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 10), safari.debugDescription)
        address.tap()
        try selectPinyinKeyboard(in: safari)
        safari.buttons["切换中英文"].tap()

        safari.buttons["key.h"].tap()
        Thread.sleep(forTimeInterval: 5)
        let falseStatus = safari.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'candidate.' AND (label CONTAINS '待下载' OR label CONTAINS '暂不可用')"))
        XCTAssertEqual(falseStatus.count, 0, "A cold first key should not show a false translation failure")
        for letter in "ello" { safari.buttons["key.\(letter)"].tap() }
        let candidate = safari.buttons["candidate.hello"]
        XCTAssertTrue(candidate.waitForExistence(timeout: 10))
        let translated = XCTNSPredicateExpectation(predicate: NSPredicate(
            format: "label CONTAINS '你好' OR label CONTAINS '您好'"), object: candidate)
        let result = XCTWaiter.wait(for: [translated], timeout: 25)
        attachState(safari, name: "First-letter translation in Safari after host exit")
        XCTAssertEqual(result, .completed, "Translation should recover on the first word after restart: \(candidate.label)")
    }

    @MainActor
    func testShenzhenKeepsEnglishAndChineseCandidatesOnPhysicalIPhone() throws {
        let app = launchApp()
        let editor = app.textViews["键盘测试输入框"]
        for _ in 0..<5 where !editor.isHittable { app.swipeUp() }
        editor.tap()
        try selectPinyinKeyboard(in: app)
        for letter in "shenzhen" { app.buttons["key.\(letter)"].tap() }
        let chinese = app.buttons["candidate.深圳"]
        XCTAssertTrue(chinese.waitForExistence(timeout: 10))
        let english = app.buttons["candidate.shenzhen"]
        XCTAssertTrue(english.waitForExistence(timeout: 10))
        XCTAssertEqual(english.label.components(separatedBy: "，").first, "shenzhen")
        XCTAssertTrue(chinese.exists)
        attachState(app, name: "Shenzhen English and Chinese candidates")
    }

    @MainActor
    func testPinyinTypoAndFuzzyCandidatesOnPhysicalIPhone() throws {
        let app = launchApp()
        let editor = app.textViews["键盘测试输入框"]
        for _ in 0..<5 where !editor.isHittable { app.swipeUp() }
        editor.tap()
        try selectPinyinKeyboard(in: app)
        var committed = ""
        for (input, expected) in [("nihap", "你好"), ("zhonguo", "中国"),
                                  ("senti", "身体"), ("zongguo", "中国"), ("pinan", "平安")] {
            for letter in input { app.buttons["key.\(letter)"].tap() }
            let candidate = app.buttons["candidate.\(expected)"]
            XCTAssertTrue(candidate.waitForExistence(timeout: 10), "Missing correction for \(input)")
            XCTAssertLessThanOrEqual(candidate.frame.minX, 10, "Correction should be first for \(input)")
            candidate.tap()
            committed += expected
            XCTAssertTrue((editor.value as? String)?.hasSuffix(committed) == true,
                          "Selecting \(expected) should consume all of \(input)")
        }
        attachState(app, name: "Pinyin typo and fuzzy corrections")
    }

    @MainActor
    func testSingleLetterChineseCandidateStillTranslatesOnPhysicalIPhone() throws {
        let app = launchApp()
        app.swipeDown()
        app.swipeDown()
        let prepare = app.buttons["language.prepare"]
        XCTAssertTrue(prepare.waitForExistence(timeout: 10))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: prepare)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 20), .completed)
        if prepare.frame.minY < 180 { app.swipeDown() }
        prepare.tap()
        let preparation = app.staticTexts["language.preparation.status"]
        XCTAssertTrue(preparation.waitForExistence(timeout: 5))
        let verified = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH '离线翻译已验证'"), object: preparation)
        XCTAssertEqual(XCTWaiter.wait(for: [verified], timeout: 90), .completed)
        let editor = app.textViews["键盘测试输入框"]
        for _ in 0..<5 where !editor.isHittable { app.swipeUp() }
        editor.tap()
        try selectPinyinKeyboard(in: app)
        app.buttons["key.s"].tap()
        let candidate = app.buttons["candidate.是"]
        XCTAssertTrue(candidate.waitForExistence(timeout: 10))
        let translated = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label BEGINSWITH '是，' AND label != '是，…' AND label != '是，待下载' AND label != '是，暂不可用'"), object: candidate)
        XCTAssertEqual(XCTWaiter.wait(for: [translated], timeout: 25), .completed)
        attachState(app, name: "Single-letter candidate translated")
    }

    @MainActor
    func testNumberSymbolAndPunctuationPressesOnPhysicalIPhone() throws {
        let app = launchApp()
        let editor = app.textViews["键盘测试输入框"]
        for _ in 0..<5 where !editor.isHittable { app.swipeUp() }
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        try selectPinyinKeyboard(in: app)
        if app.buttons["英文逗号，长按句号"].exists { app.buttons["切换中英文"].tap() }
        var expected = editor.value as? String ?? ""

        func pressCharacters(_ characters: [String]) {
            for character in characters {
                let key = app.buttons["key.\(character)"]
                XCTAssertTrue(key.waitForExistence(timeout: 5))
                key.press(forDuration: 0.55)
                expected += character
                XCTAssertEqual(editor.value as? String, expected,
                               "Holding a character preview must commit exactly one \(character)")
            }
        }

        app.buttons["key.123"].tap()
        pressCharacters(["1", "0", "@", "，"])
        let cancelledKey = app.buttons["key.2"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        cancelledKey.press(forDuration: 0.15, thenDragTo: cancelledKey.withOffset(CGVector(dx: 0, dy: -100)))
        XCTAssertEqual(editor.value as? String, expected, "Releasing outside a preview key must cancel its input")
        app.buttons["key.#+="].tap()
        pressCharacters(["【", "¥", "\\"])
        app.buttons["key.返回"].tap()
        XCTAssertEqual(editor.value as? String, expected, "Layout controls must not insert their labels")

        let chinesePunctuation = app.buttons["逗号，长按句号"]
        chinesePunctuation.tap()
        expected += "，"
        XCTAssertEqual(editor.value as? String, expected)
        chinesePunctuation.press(forDuration: 0.6)
        expected += "。"
        XCTAssertEqual(editor.value as? String, expected, "Long press changes the preview to a single period")

        app.buttons["切换中英文"].tap()
        let englishPunctuation = app.buttons["英文逗号，长按句号"]
        englishPunctuation.tap()
        expected += ","
        englishPunctuation.press(forDuration: 0.6)
        expected += "."
        XCTAssertEqual(editor.value as? String, expected)
        app.buttons["key.123"].tap()
        pressCharacters(["7", "?", "'"])
        app.buttons["key.返回"].tap()
        app.buttons["切换中英文"].tap()

        tapKeyboardChrome(app.buttons["切换中文输入方式"])
        XCTAssertTrue(app.buttons["key.mno"].waitForExistence(timeout: 5))
        pressCharacters(["？"])
        app.buttons["key.123"].tap()
        pressCharacters(["5", "0", "#", "/"])
        app.buttons["key.返回"].tap()
        XCTAssertEqual(editor.value as? String, expected)
        attachState(app, name: "Number symbol and punctuation key press regression")
    }

    @MainActor
    func testBuild9CompactLayoutEmojiPagingAndNineKeyNumbersOnPhysicalIPhone() throws {
        let app = launchApp()
        let editor = app.textViews["键盘测试输入框"]
        for _ in 0..<5 where !editor.isHittable { app.swipeUp() }
        editor.tap()
        try selectPinyinKeyboard(in: app)
        XCTAssertFalse(app.buttons["键盘设置"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '当前翻译方向'")).firstMatch.exists)
        let letterHeight = app.buttons["key.n"].frame.height
        attachState(app, name: "Build 9 compact toolbar")

        tapKeyboardChrome(app.buttons["切换中文输入方式"])
        let nine = app.buttons["key.mno"]
        XCTAssertTrue(nine.waitForExistence(timeout: 5))
        XCTAssertEqual(nine.frame.height, letterHeight, accuracy: 2)
        XCTAssertFalse(nine.label.contains("6"), "The nine-key letter faces should not show digit hints")
        attachState(app, name: "Build 9 compact nine-key layout")

        app.buttons["key.123"].tap()
        XCTAssertTrue(app.buttons["key.5"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["key.0"].exists)
        XCTAssertFalse(app.buttons["key.q"].exists)
        app.buttons["key.5"].tap()
        XCTAssertTrue((editor.value as? String)?.contains("5") == true)
        attachState(app, name: "Build 9 nine-key number pad")
        app.buttons["key.返回"].tap()

        app.buttons["表情符号"].tap()
        app.buttons["emoji.category.food"].tap()
        let grape = app.buttons["输入表情 🍇"]
        XCTAssertTrue(grape.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(app.buttons["emoji.category.food"].frame.minY, grape.frame.minY,
                             "Emoji categories belong below the emoji grid")
        XCTAssertLessThan(app.buttons["返回字母键盘"].frame.maxX,
                          app.buttons["emoji.category.recent"].frame.minX)
        XCTAssertFalse(app.buttons["key.空格"].exists)
        app.scrollViews["emoji.pages"].swipeLeft()
        XCTAssertFalse(grape.isHittable, "Emoji pages should move horizontally")
        attachState(app, name: "Build 9 horizontal emoji pages")
        app.buttons["返回字母键盘"].tap()
        app.buttons["key.符号"].tap()
        app.buttons["key.#+="].tap()
        XCTAssertTrue(app.buttons["key.【"].exists)
        XCTAssertTrue(app.buttons["key.¥"].exists)
        XCTAssertFalse(app.buttons["key.©"].exists)
        attachState(app, name: "Build 9 practical alternate symbols")
    }

    @MainActor
    func testBuild10NineKeyPreeditAndSystemBackgroundOnPhysicalIPhone() throws {
        let app = launchApp()
        let editor = app.textViews["键盘测试输入框"]
        for _ in 0..<5 where !editor.isHittable { app.swipeUp() }
        editor.tap()
        try selectPinyinKeyboard(in: app)
        attachState(app, name: "Build 10 clear system keyboard background")

        tapKeyboardChrome(app.buttons["切换中文输入方式"])
        for key in ["mno", "ghi", "ghi", "abc", "mno"] {
            app.buttons["key.\(key)"].tap()
        }
        let phonetic = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value ENDSWITH 'nihao'"), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [phonetic], timeout: 20), .completed,
                       "Nine-key composition should show pinyin letters in the host field")
        XCTAssertFalse((editor.value as? String)?.contains("64426") == true)
        XCTAssertFalse(app.staticTexts["暂无候选"].exists)
        XCTAssertTrue(app.buttons["candidate.你好"].waitForExistence(timeout: 5))
        attachState(app, name: "Build 10 nine-key letters in host field")
    }

    @MainActor
    func testBuild11EmojiCategoryPagingRawReturnAndLongNineKeyOnPhysicalIPhone() throws {
        let app = launchApp()
        let editor = app.textViews["键盘测试输入框"]
        for _ in 0..<5 where !editor.isHittable { app.swipeUp() }
        editor.tap()
        try selectPinyinKeyboard(in: app)

        tapKeyboardChrome(app.buttons["表情符号"])
        XCTAssertTrue(app.buttons["emoji.category.component"].waitForExistence(timeout: 5))
        app.buttons["emoji.category.component"].tap()
        XCTAssertEqual(app.buttons["emoji.category.component"].value as? String, "已选中")
        app.scrollViews["emoji.pages"].swipeLeft()
        XCTAssertEqual(app.buttons["emoji.category.nature"].value as? String, "已选中",
                       "Swiping past the last page of a category should enter the next category")
        attachState(app, name: "Build 11 continuous emoji categories")
        app.buttons["返回字母键盘"].tap()

        for letter in "ok" { app.buttons["key.\(letter)"].tap() }
        XCTAssertTrue(app.scrollViews["candidate.strip"].waitForExistence(timeout: 8))
        app.buttons["key.确认"].tap()
        attachState(app, name: "Build 11 raw return")
        XCTAssertTrue((editor.value as? String)?.hasSuffix("ok") == true,
                      "The first Return should commit the raw code only; actual: \(String(describing: editor.value))")
        XCTAssertFalse((editor.value as? String)?.contains("\n") == true)
        XCTAssertFalse((editor.value as? String)?.contains("欧坤") == true)
        app.buttons["key.换行"].tap()
        XCTAssertTrue((editor.value as? String)?.contains("ok\n") == true,
                      "The second Return should insert a newline; actual: \(String(describing: editor.value))")

        tapKeyboardChrome(app.buttons["切换中文输入方式"])
        for digit in "64426999999999999" {
            let keys = ["2": "abc", "3": "def", "4": "ghi", "5": "jkl",
                        "6": "mno", "7": "pqrs", "8": "tuv", "9": "wxyz"]
            app.buttons["key.\(keys[String(digit)]!)"].tap()
        }
        let value = editor.value as? String ?? ""
        XCTAssertFalse(value.contains("…"), "Long nine-key input must never leave a placeholder in the host field")
        XCTAssertFalse(value.hasSuffix("64426999999999999"), "Long nine-key input should be readable letters")
        attachState(app, name: "Build 11 long nine-key preedit")
    }

    @MainActor
    func testBuild9ChineseFallbackAndEnglishTranslationOnPhysicalIPhone() throws {
        let app = launchApp()
        let editor = app.textViews["键盘测试输入框"]
        for _ in 0..<5 where !editor.isHittable { app.swipeUp() }
        editor.tap()
        try selectPinyinKeyboard(in: app)
        app.buttons["key.i"].tap()
        XCTAssertTrue(app.buttons["candidate.I"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["暂无候选"].exists)
        app.buttons["退格"].tap()
        for char in "appli" { app.buttons["key.\(char)"].tap() }
        let application = app.buttons["candidate.application"]
        XCTAssertTrue(application.waitForExistence(timeout: 10))
        let translated = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label BEGINSWITH 'application，' AND label != 'application，…' AND label != 'application，暂不可用'"), object: application)
        let translationResult = XCTWaiter.wait(for: [translated], timeout: 25)
        attachState(app, name: "Build 9 application translation result")
        XCTAssertEqual(translationResult, .completed,
                       "English completions in Chinese mode should show English above a real Chinese translation; actual: \(application.label)")
        XCTAssertTrue(app.buttons["candidate.凹朴皮里"].exists || app.buttons["candidate.凹朴皮"].exists,
                      "The English suggestion should not remove Chinese candidates")
        attachState(app, name: "Build 9 English suggestion with Chinese translation")
        let chinese = application.label.components(separatedBy: "，").dropFirst().first ?? ""
        XCTAssertTrue(chinese.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) })
        application.tap()
        XCTAssertTrue((editor.value as? String)?.contains("application") == true)
        for char in "appli" { app.buttons["key.\(char)"].tap() }
        XCTAssertTrue(application.waitForExistence(timeout: 10))
        pressKeyboardChrome(application, duration: 0.75)
        XCTAssertTrue((editor.value as? String)?.contains(chinese) == true,
                      "Long pressing the English candidate should insert its Chinese translation")
    }

    @MainActor
    func testBuild8DirectTranslationAndSpaceCursorOnPhysicalIPhone() throws {
        let app = launchApp()
        let editor = app.textViews["键盘测试输入框"]
        for _ in 0..<5 where !editor.isHittable { app.swipeUp() }
        editor.tap()
        try selectPinyinKeyboard(in: app)
        app.buttons["切换中英文"].tap()
        for letter in "hello" { app.buttons["key.\(letter)"].tap() }
        let candidate = app.buttons["candidate.hello"]
        XCTAssertTrue(candidate.waitForExistence(timeout: 5))
        let translated = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label BEGINSWITH 'hello，' AND label != 'hello，…' AND label != 'hello，待下载' AND label != 'hello，暂不可用'"), object: candidate)
        XCTAssertEqual(XCTWaiter.wait(for: [translated], timeout: 25), .completed)
        let translation = candidate.label.components(separatedBy: "，").dropFirst().joined(separator: "，")
        XCTAssertFalse(translation.isEmpty)
        pressKeyboardChrome(candidate, duration: 0.75)
        XCTAssertTrue((editor.value as? String)?.contains(translation) == true,
                      "Long-pressing a translated candidate should insert the translation directly")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH '输入译文：'")).firstMatch.exists)

        for letter in "abcd" { app.buttons["key.\(letter)"].tap() }
        app.buttons["key.确认"].tap()
        let before = editor.value as? String ?? ""
        XCTAssertTrue(before.hasSuffix("abcd"))
        let space = app.buttons["key.空格"]
        let start = space.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = start.withOffset(CGVector(dx: -60, dy: 0))
        start.press(forDuration: 0.65, thenDragTo: end)
        app.buttons["key.x"].tap()
        app.buttons["key.确认"].tap()
        let after = editor.value as? String ?? ""
        attachState(app, name: "Build 8 cursor movement after long-press space")
        XCTAssertTrue(after.unicodeScalars.contains(where: { $0.value == 120 }) && after.hasSuffix("abcd") &&
                      after.unicodeScalars.count == before.unicodeScalars.count + 1,
                      "Dragging from a held space key should move the insertion point before typing. Before: \(before), after: \(after)")
        attachState(app, name: "Build 8 direct translation and space cursor")
    }
}
