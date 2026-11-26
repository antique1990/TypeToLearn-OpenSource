import XCTest
import KeyboardCore
@testable import DesktopCore

final class DesktopCandidateCatalogTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private var catalog: DesktopCandidateCatalog {
        let resources = root.appendingPathComponent("Mac/InputMethod/Resources")
        return DesktopCandidateCatalog(metadataURL: resources.appendingPathComponent("character-metadata.json"),
            emojiURL: root.appendingPathComponent("Resources/emoji-catalog.json"),
            emojiIndexURL: resources.appendingPathComponent("emoji-keywords.json"),
            structuralURL: resources.appendingPathComponent("structural-pinyin.json"))
    }

    func testRadicalAndStrokeOrderingRetainsOriginalEngineCandidates() {
        let values = ["你", "的", "一", "好"].enumerated().map {
            Candidate(text: $0.element, reading: "test", consumed: 0, engineIndex: $0.offset)
        }
        let radicals = catalog.candidates(from: values, input: "test", category: .radical)
        XCTAssertEqual(radicals.map(\.text), ["一", "你", "好", "的"])
        let strokes = catalog.candidates(from: values, input: "test", category: .strokes)
        XCTAssertEqual(strokes.map(\.text), ["一", "好", "你", "的"])
        for candidate in radicals + strokes {
            XCTAssertEqual(candidate, values.first { $0.text == candidate.text })
        }
        XCTAssertEqual(catalog.annotation(for: "你", category: .radical), "人部")
        XCTAssertEqual(catalog.annotation(for: "你好", category: .strokes), "13画")
        XCTAssertNil(catalog.annotation(for: "not a character", category: .strokes))
    }

    func testDecompositionUsesRealPrintableComponents() {
        XCTAssertEqual(catalog.annotation(for: "你", category: .decomposition), "亻 + 尔")
        XCTAssertEqual(catalog.annotation(for: "好", category: .decomposition), "女 + 子")
        XCTAssertEqual(catalog.annotation(for: "的", category: .decomposition), "白 + 勺")
        XCTAssertNil(catalog.annotation(for: "一", category: .decomposition))
        XCTAssertEqual(catalog.annotation(for: "喆", category: .decomposition), "吉 + 吉")
        for (input, expected) in [("jiji", "喆"), ("riyue", "明"), ("mumu", "林"), ("mumumu", "森")] {
            let output = catalog.candidates(from: [], input: input, category: .decomposition)
            XCTAssertTrue(output.contains { $0.text == expected }, input)
            XCTAssertTrue(output.allSatisfy { $0.consumed == input.count && $0.engineIndex == nil })
        }
        let ordinary = [Candidate(text: "吉吉", reading: "jiji", consumed: 4)]
        XCTAssertFalse(catalog.candidates(from: ordinary, input: "jiji", category: .decomposition).contains { $0.text == "吉吉" })
        XCTAssertTrue(catalog.candidates(from: ordinary, input: "unmatched", category: .decomposition).isEmpty)
    }

    func testEmojiKeywordsAndFullCatalogAreActuallyAvailable() {
        XCTAssertGreaterThan(catalog.emojiCategories.count, 5)
        XCTAssertGreaterThan(catalog.emojiCategories.flatMap(\.emojis).count, 3500)
        XCTAssertTrue(catalog.emojiSuggestions(for: "kai'xin").contains("😄"))
        XCTAssertTrue(catalog.emojiSuggestions(for: "shengri").contains("🎂"))
        XCTAssertEqual(catalog.emojiSuggestions(for: "nihao"), ["👋"])
        XCTAssertTrue(catalog.emojiSuggestions(for: "unmatched-query").isEmpty)
        XCTAssertEqual(catalog.emojiName(for: "👋"), "挥手")
        XCTAssertTrue(catalog.isEmoji("👋"))
        XCTAssertFalse(catalog.isEmoji("你好"))
        let all = catalog.candidates(from: [], input: "unmatched-query", category: .emoji)
        XCTAssertGreaterThan(all.count, 3500)
        let matches = catalog.candidates(from: [], input: "shengri", category: .emoji)
        XCTAssertTrue(matches.contains { $0.text == "🎂" })
        XCTAssertTrue(matches.allSatisfy { $0.consumed == 7 && $0.engineIndex == nil })
    }

    func testFrequencyKeepsChineseOrderAndEmojiConsumesWholePinyin() {
        let base = ["你好", "你号", "泥好", "你", "拟"].enumerated().map {
            Candidate(text: $0.element, reading: "nihao", consumed: 0, engineIndex: $0.offset)
        }
        let output = catalog.candidates(from: base, input: "nihao", category: .frequency)
        XCTAssertEqual(output.prefix(3).map(\.text), Array(base.prefix(3)).map(\.text))
        XCTAssertEqual(output.filter { !catalog.isEmoji($0.text) }, base)
        XCTAssertEqual(output[3].text, "👋")
        var state = DesktopComposition()
        state.append("nihao")
        state.publish(output, generation: state.generation)
        XCTAssertEqual(state.commit(index: 3), "👋")
        XCTAssertTrue(state.input.isEmpty)
    }

    func testMissingMetadataDoesNotFabricateOrDiscardCandidates() {
        let empty = DesktopCandidateCatalog(metadataURL: nil, emojiURL: nil, emojiIndexURL: nil)
        let values = ["你", "好"].map { Candidate(text: $0, reading: "n", consumed: 1) }
        for category in DesktopCandidateCategory.allCases where category != .emoji && category != .decomposition {
            XCTAssertEqual(empty.candidates(from: values, input: "n", category: category), values)
            XCTAssertNil(empty.annotation(for: "你", category: category))
        }
        XCTAssertTrue(empty.emojiSuggestions(for: "nihao").isEmpty)
    }
}
