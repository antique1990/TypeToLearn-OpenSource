import XCTest
import KeyboardCore
@testable import DesktopCore

final class DesktopCoreTests: XCTestCase {
    func testMixedCaseSpellingAndCursorEditsStayAlignedWithPinyinCode() {
        var state = DesktopComposition()
        state.append("iPhoe")
        state.moveCursor(-1)
        state.append("n")
        XCTAssertEqual(state.input, "iphone")
        XCTAssertEqual(state.displayInput, "iPhone")
        state.moveCursor(-2)
        state.deleteForward()
        XCTAssertEqual(state.displayInput, "iPhne")
        state.backspace()
        XCTAssertEqual(state.displayInput, "iPne")
        XCTAssertEqual(state.input, state.displayInput.lowercased())
        state.configure(layout: .pinyin, english: true)
        state.append("Helo")
        state.moveCursor(-1)
        state.append("l")
        XCTAssertEqual(state.displayInput, "Hello")
        state.moveCursor(Int.min)
        state.deleteForward()
        XCTAssertEqual(state.displayInput, "ello")
        state.backspace()
        XCTAssertEqual(state.displayInput, "ello")
    }
    func testStandaloneEmojiDoesNotInventMarkedTextOrConsumeSpelling() {
        var state = DesktopComposition()
        state.presentSymbols(["👨‍👩‍👧‍👦", "😊", "👍🏽", "❤️", "🎉", "🍎"])
        XCTAssertTrue(state.isActive)
        XCTAssertTrue(state.input.isEmpty)
        XCTAssertEqual(state.commit(index: 0), "👨‍👩‍👧‍👦")
        XCTAssertFalse(state.isActive)
        state.presentSymbols(["😊"])
        state.append("ni")
        XCTAssertFalse(state.browsingSymbols)
        XCTAssertEqual(state.input, "ni")
        XCTAssertTrue(state.candidates.isEmpty)
    }
    func testUnresolvedRimeCandidateIsVisibleButCannotConsumeCodeUntilChosen() {
        var state = DesktopComposition()
        state.append("nihao")
        let token = state.generation
        state.publish([Candidate(text: "你好", reading: "nihao", consumed: 0, engineIndex: 0)], generation: token)
        XCTAssertEqual(state.visible.first?.text, "你好")
        XCTAssertNil(state.commit(index: 0))
        XCTAssertEqual(state.input, "nihao")
        XCTAssertTrue(state.resolveCandidate(Candidate(text: "你好", reading: "nihao", consumed: 5), at: 0, generation: token))
        XCTAssertEqual(state.commit(index: 0), "你好")
        XCTAssertTrue(state.input.isEmpty)
        XCTAssertFalse(state.resolveCandidate(Candidate(text: "你好", reading: "nihao", consumed: 5), at: 0, generation: token))
    }
    func testWideTranslationsPaginateWithoutLosingCandidatesOrSelection() {
        var state = DesktopComposition()
        state.append("nihao")
        let values = (0..<13).map { Candidate(text: "候选\($0)", reading: "", consumed: 5) }
        state.publish(values, generation: state.generation)
        state.paginate(widths: [180, 180, 350, 250, 200, 480, 100, 100, 100, 100, 100, 100, 100], availableWidth: 500)
        var visited: [String] = []
        repeat {
            visited += state.visible.map(\.text)
            if !state.canPageForward { break }
            state.movePage(1)
        } while true
        XCTAssertEqual(visited, values.map(\.text))
        state.moveSelection(-4)
        let selected = state.candidates[state.selected].text
        state.paginate(widths: Array(repeating: 480, count: values.count), availableWidth: 500)
        XCTAssertEqual(state.candidates[state.selected].text, selected)
        XCTAssertEqual(state.visible.count, 1)
    }
    func testChinesePunctuationPairsAndAsciiOverride() {
        var punctuation = DesktopPunctuation()
        XCTAssertEqual(punctuation.convert(","), "，")
        XCTAssertEqual(punctuation.convert("."), "。")
        XCTAssertEqual(punctuation.convert("\""), "“")
        XCTAssertEqual(punctuation.convert("\""), "”")
        XCTAssertEqual(punctuation.convert("'"), "‘")
        XCTAssertEqual(punctuation.convert("'"), "’")
        XCTAssertEqual(punctuation.convert("^"), "……")
        XCTAssertNil(punctuation.convert(".", ascii: true))
    }
    func testForwardDeleteEditsOnlyUncommittedPinyin() {
        var state = DesktopComposition()
        state.append("nihao")
        state.moveCursor(-3)
        state.deleteForward()
        XCTAssertEqual(state.input, "niao")
        XCTAssertEqual(state.cursor, 2)
        state.moveCursor(Int.max)
        state.deleteForward()
        XCTAssertEqual(state.input, "niao")
        state.moveCursor(Int.min)
        state.backspace()
        XCTAssertEqual(state.input, "niao")
    }
    func testPagingSelectsFirstItemAndStopsAtEnds() {
        var state = DesktopComposition()
        state.append("nihao")
        state.publish((0..<12).map { Candidate(text: "候选\($0)", reading: "", consumed: 5) }, generation: state.generation)
        state.moveSelection(3)
        state.movePage(1)
        XCTAssertEqual(state.selected, 5)
        XCTAssertEqual(state.visible.count, 5)
        state.movePage(1)
        XCTAssertEqual(state.selected, 10)
        XCTAssertEqual(state.visible.count, 2)
        XCTAssertFalse(state.canPageForward)
        state.movePage(1)
        XCTAssertEqual(state.selected, 10)
        state.movePage(-1)
        XCTAssertEqual(state.selected, 5)
        state.movePage(-1)
        state.movePage(-1)
        XCTAssertEqual(state.selected, 0)
        XCTAssertFalse(state.canPageBackward)
        state.clear()
        state.movePage(1)
        XCTAssertTrue(state.visible.isEmpty)
    }
    func testOldSettingsKeepProviderAndConsentWhenCandidateStyleIsMissing() throws {
        var original = DesktopSettings()
        original.provider = .siliconFlow
        original.cloudConsent = true
        original.targetLanguage = "ja"
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json.removeValue(forKey: "candidateStyle")
        let decoded = try JSONDecoder().decode(DesktopSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.candidateLayout, .horizontal)
        XCTAssertEqual(decoded.provider, .siliconFlow)
        XCTAssertTrue(decoded.cloudConsent)
        XCTAssertEqual(decoded.targetLanguage, "ja")
        var changed = decoded
        changed.candidateLayout = .vertical
        let restored = try JSONDecoder().decode(DesktopSettings.self, from: JSONEncoder().encode(changed))
        XCTAssertEqual(restored.candidateLayout, .vertical)
    }
    func testLateLookupCannotReplaceNewComposition() {
        var state = DesktopComposition()
        state.append("ni")
        let old = state.generation
        state.append("hao")
        XCTAssertFalse(state.publish([Candidate(text: "你", reading: "ni", consumed: 2)], generation: old))
        XCTAssertTrue(state.candidates.isEmpty)
        XCTAssertEqual(state.input, "nihao")
    }
    func testPartialCommitKeepsRemainingCodeAndInvalidatesResults() {
        var state = DesktopComposition()
        state.append("nihaoshijie")
        let token = state.generation
        state.publish([Candidate(text: "你好", reading: "", consumed: 5)], generation: token)
        XCTAssertEqual(state.commit(index: 0), "你好")
        XCTAssertEqual(state.input, "shijie")
        XCTAssertNotEqual(state.generation, token)
        XCTAssertTrue(state.candidates.isEmpty)
    }
    func testClearAndEnglishSwitchDiscardPreviousResults() {
        var state = DesktopComposition()
        state.append("nihao")
        let token = state.generation
        state.configure(layout: .pinyin, english: true)
        state.append("Hello")
        XCTAssertFalse(state.publish([Candidate(text: "你好", reading: "", consumed: 5)], generation: token))
        XCTAssertEqual(state.input, "Hello")
        state.backspace()
        XCTAssertEqual(state.input, "Hell")
    }
    func testInvalidCandidateCannotConsumeOutsideComposition() {
        var state = DesktopComposition()
        state.append("ni")
        state.publish([Candidate(text: "坏", reading: "", consumed: 8)], generation: state.generation)
        XCTAssertNil(state.commit(index: 0))
        XCTAssertEqual(state.input, "ni")
    }
    func testCloudKeyRequiredBeforeNetwork() async {
        do {
            _ = try await SiliconFlowClient().translate(["你好"], source: "zh-Hans", target: "en", key: "")
            XCTFail("Missing key must not send a request")
        } catch { XCTAssertEqual(error as? CloudTranslationError, .missingKey) }
    }
    func testCloudBatchBoundedBeforeNetwork() async {
        do {
            _ = try await SiliconFlowClient().translate(Array(repeating: "你好", count: 6), source: "zh-Hans", target: "en", key: "test-placeholder")
            XCTFail("Oversized request must be rejected locally")
        } catch { XCTAssertEqual(error as? CloudTranslationError, .invalidResponse) }
    }
}
