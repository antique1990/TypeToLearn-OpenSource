import XCTest
@testable import KeyboardCore

final class RimeFuzzyTests: XCTestCase, @unchecked Sendable {
    private var data: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/RimeData")
    }
    private func candidates(_ raw: String, options: PinyinFuzzyOptions,
                            script: ChineseScript = .simplified) async throws -> [Candidate] {
        try await RimeInput.shared.candidates(raw: raw, layout: .pinyin, script: script,
            data: data, limit: 64, pinyinPolicy: .configured(options))
    }

    func testFuzzySchemaRecoversWhenTemporaryConfigurationIsRemoved() async throws {
        _ = try await candidates("fasheng", options: .all)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("learnkeyboard-rime-\(ProcessInfo.processInfo.processIdentifier)")
        let name = "learn_pinyin_hans_fuzzy_v2_255.schema.yaml"
        for file in [work.appendingPathComponent(name), work.appendingPathComponent("build/" + name)] {
            try FileManager.default.removeItem(at: file)
        }
        // Selecting another schema forces Rime to load the missing config again.
        _ = try await candidates("nihao", options: [])
        for (raw, target) in [("fasheng", "发生"), ("da", "大")] {
            let found = try await candidates(raw, options: .all)
            XCTAssertTrue(found.contains { $0.text == target }, "Missing after temp cleanup: \(raw), \(found.map(\.text))")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: work.appendingPathComponent("build/" + name).path))
    }

    func testOptionsRoundTripAndUnknownBitsCannotGenerateSchemaRules() throws {
        let options: PinyinFuzzyOptions = [.sSh, .anAng, .nL]
        XCTAssertEqual(try JSONDecoder().decode(PinyinFuzzyOptions.self, from: JSONEncoder().encode(options)), options)
        XCTAssertEqual(PinyinFuzzyOptions(rawValue: 1024), [])
        XCTAssertEqual(PinyinFuzzyOptions(rawValue: 1028), .sSh)
        XCTAssertEqual(PinyinFuzzyOptions.retroflex.rawValue, 7)
        XCTAssertEqual(PinyinFuzzyOptions.all.algebra.count, 16)
    }

    func testEveryPairIsBidirectionalOnAlreadyValidPinyinAndCanBeDisabled() async throws {
        let cases: [(PinyinFuzzyOptions, String, String, String, String)] = [
            (.zZh, "zi", "只", "zhi", "子"), (.cCh, "ci", "吃", "chi", "次"),
            (.sSh, "si", "是", "shi", "四"), (.nL, "ni", "里", "li", "你"),
            (.fH, "fa", "哈", "ha", "法"), (.anAng, "gan", "刚", "gang", "干"),
            (.enEng, "zen", "增", "zeng", "怎"), (.inIng, "jin", "经", "jing", "进")
        ]
        for (options, first, firstTarget, second, secondTarget) in cases {
            for (raw, target) in [(first, firstTarget), (second, secondTarget)] {
                let baseline = try await candidates(raw, options: [])
                _ = try await candidates(raw, options: options)
                let restored = try await candidates(raw, options: [])
                // Compare before any explicit selection: a genuine selection
                // changes the language model's context even without user dicts.
                XCTAssertTrue(restored == baseline, "Disabling fuzzy must restore strict candidates for \(raw)")
                // A strict engine may expose a shorter prefix: gang → 干 can
                // consume gan and leave g. That is not a fuzzy full match.
                if let strictChoice = baseline.first(where: { $0.text == target }) {
                    let strict = try await RimeInput.shared.resolve(strictChoice, raw: raw, layout: .pinyin,
                        script: .simplified, data: data, pinyinPolicy: .configured([]))
                    XCTAssertNotEqual(strict?.consumed, raw.count, "Strict full match \(raw) → \(target)")
                }
                let enabled = try await candidates(raw, options: options)
                let fuzzyChoice = try XCTUnwrap(enabled.first { $0.text == target }, "Enabled mask \(options.rawValue): \(raw) → \(target)")
                let fuzzy = try await RimeInput.shared.resolve(fuzzyChoice, raw: raw, layout: .pinyin,
                    script: .simplified, data: data, pinyinPolicy: .configured(options))
                XCTAssertEqual(fuzzy?.consumed, raw.count, "Fuzzy full match \(raw) → \(target)")
            }
        }
    }

    func testFuzzySelectionConsumesOriginalLettersAndApostropheOnly() async throws {
        let cases: [(String, String, Int, PinyinFuzzyOptions)] = [
            ("sizihao", "狮子", 4, .sSh), ("shizihao", "私自", 5, .sSh),
            ("si'zihao", "狮子", 5, .sSh), ("sanhaihao", "上海", 6, [.sSh, .anAng])
        ]
        for (raw, target, consumed, options) in cases {
            let values = try await candidates(raw, options: options)
            let chosen = try XCTUnwrap(values.first { $0.text == target })
            XCTAssertEqual(chosen.consumed, 0, "Listing must not preselect a native candidate")
            XCTAssertNotNil(chosen.engineIndex)
            let resolved = try await RimeInput.shared.resolve(chosen, raw: raw, layout: .pinyin,
                script: .simplified, data: data, pinyinPolicy: .configured(options))
            XCTAssertEqual(resolved?.consumed, consumed)
            var composition = Composition(); composition.append(raw)
            XCTAssertEqual(composition.commit(try XCTUnwrap(resolved)), target)
            XCTAssertEqual(composition.input, "hao")
        }
    }

    func testAnAngIncludesIAnAndUAnAndTraditionalSchema() async throws {
        let liang = try await candidates("lian", options: .anAng)
        XCTAssertTrue(liang.contains { $0.text == "两" })
        let guang = try await candidates("guan", options: .anAng)
        XCTAssertTrue(guang.contains { $0.text == "光" })
        let traditional = try await candidates("sizi", options: .sSh, script: .traditional)
        XCTAssertTrue(traditional.contains { $0.text == "獅子" })
        let strict = try await candidates("sizi", options: [], script: .traditional)
        XCTAssertFalse(strict.contains { $0.text == "獅子" })
    }

    func testCachedPrismIsNotRewrittenAndLongInputIsBounded() async throws {
        let clock = ContinuousClock()
        let coldDuration = try await clock.measure {
            _ = try await self.candidates("zi", options: [.zZh, .sSh, .inIng])
        }
        _ = try await candidates("si", options: .all)
        let prism = FileManager.default.temporaryDirectory.appendingPathComponent(
            "learnkeyboard-rime-\(ProcessInfo.processInfo.processIdentifier)/build/learn_pinyin_hans_fuzzy_v2_255.prism.bin")
        let before = try FileManager.default.attributesOfItem(atPath: prism.path)
        let duration = try await clock.measure {
            for _ in 0..<10 { _ = try await self.candidates("sizi", options: .all) }
        }
        let after = try FileManager.default.attributesOfItem(atPath: prism.path)
        XCTAssertEqual(before[.modificationDate] as? Date, after[.modificationDate] as? Date)
        XCTAssertEqual(before[.systemFileNumber] as? NSNumber, after[.systemFileNumber] as? NSNumber)
        let long = try await candidates(String(repeating: "si", count: 40), options: .all)
        XCTAssertFalse(long.isEmpty)
        XCTAssertLessThanOrEqual(long.count, 64)
        print("Fuzzy Rime: new mask deploy/query \(coldDuration), 10 cached queries \(duration); all-rules prism \(before[.size] ?? 0) bytes")
    }
}
