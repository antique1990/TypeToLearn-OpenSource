import XCTest
@testable import KeyboardCore

/// Real macOS librime queries exercise policy isolation and consumption; no
/// simulator or replacement transliterator is involved in these checks.
final class PinyinFuzzyLexiconTests: XCTestCase {
    func testDesktopFuzzyKeepsTypedInitials() async throws {
        let root = lexiconURL.deletingLastPathComponent().deletingLastPathComponent()
        let lexicon = try Lexicon(url: root.appendingPathComponent("Mac/DictionaryResources/lexicon.sqlite"))
        for raw in ["lq", "nq", "fq", "hq", "zhq", "chq", "shq", "lqhao", "nhao"] {
            let strict = try await lexicon.candidates(for: raw, layout: .pinyin, script: .simplified,
                                                       pinyinPolicy: .configured([]))
            let fuzzy = try await lexicon.candidates(for: raw, layout: .pinyin, script: .simplified,
                                                      pinyinPolicy: .configured(.all))
            XCTAssertFalse(strict.isEmpty, raw)
            XCTAssertEqual(fuzzy.prefix(4).map(\.text), strict.prefix(4).map(\.text), raw)
        }
    }

    func testDesktopCombinedSentenceCorrections() async throws {
        let root = lexiconURL.deletingLastPathComponent().deletingLastPathComponent()
        let lexicon = try Lexicon(url: root.appendingPathComponent("Mac/DictionaryResources/lexicon.sqlite"))
        let examples = [("zhomgw", "中文"), ("zhomg'w", "中文"), ("jj'saun'j", "计算机"),
                        ("zhomgwne", "中文"), ("chamgjianh", "长江"), ("jj'saun'ij", "计算机"),
                        ("zhomgwnecihui", "中文词汇"), ("zhomg'wne'cihui", "中文词汇"),
                        ("woxuezhomgwnecihui", "我学中文词汇"),
                        ("woaibeijinhdaxeu", "我爱北京大学"),
                        ("woxuezhomgwnecihyi", "我学中文词汇")]
        for options in [PinyinFuzzyOptions(), .all] {
            let policy = PinyinQueryPolicy.configured(options)
            for (raw, target) in examples {
                for limit in [1, 48] {
                    let values = try await lexicon.candidates(for: raw, layout: .pinyin, script: .simplified, limit: limit, pinyinPolicy: policy)
                    XCTAssertEqual(values.first?.text, target, "\(raw): \(values.prefix(4).map(\.text))")
                    let choice = try XCTUnwrap(values.first)
                    XCTAssertFalse(values.contains { $0.engineIndex != nil && $0.coversFullInput == true }, raw)
                    let selected = await lexicon.resolve(choice, for: raw, layout: .pinyin, script: .simplified, pinyinPolicy: policy)
                    XCTAssertEqual(selected?.consumed, raw.count)
                }
            }
        }
        for raw in ["woxuezhongwencihui", "woxuezhongwenci", "woxuezhongwwncihui"] {
            let values = try await lexicon.candidates(for: raw, layout: .pinyin, script: .simplified,
                limit: 48, pinyinPolicy: .configured([]))
            XCTAssertEqual(values.first?.reading, raw, "Valid, unfinished or ambiguous spelling must keep original first choice")
        }
        await lexicon.close()
    }

    func testDesktopCorrectionFamiliesUseSameLookupAndSelectionPolicy() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let lexicon = try Lexicon(url: root.appendingPathComponent("Mac/DictionaryResources/lexicon.sqlite"))
        let cases = [("wne", "wen", "文"), ("nihap", "nihao", "你好"),
                     ("nihaoo", "nihao", "你好"), ("nhao", "nihao", "你好"),
                     ("zhomgwencihui", "zhongwencihui", "中文词汇"),
                     ("zhongwnecihui", "zhongwencihui", "中文词汇"),
                     ("zhongwenncihui", "zhongwencihui", "中文词汇"),
                     ("zhongwencihi", "zhongwencihui", "中文词汇")]
        for options in [PinyinFuzzyOptions(), .all] {
            let policy = PinyinQueryPolicy.configured(options)
            for (raw, _, target) in cases {
                let values = try await lexicon.candidates(for: raw, layout: .pinyin, script: .simplified, limit: 48, pinyinPolicy: policy)
                let choice = try XCTUnwrap(values.prefix(12).first { $0.text == target }, "Missing correction \(raw): \(values.prefix(12).map(\.text))")
                let selection = await lexicon.resolve(choice, for: raw, layout: .pinyin, script: .simplified, pinyinPolicy: policy)
                let resolved = try XCTUnwrap(selection)
                XCTAssertEqual(resolved.consumed, raw.count)
            }
            for raw in ["nm", "zhongwencihui", "nihao", "nihaop"] {
                let values = try await lexicon.candidates(for: raw, layout: .pinyin, script: .simplified, limit: 48, pinyinPolicy: policy)
                XCTAssertFalse(values.isEmpty, raw)
                if raw == "nm" || raw == "zhongwencihui" || raw == "nihao" { XCTAssertEqual(values.first?.reading, raw) }
            }
        }
        await lexicon.close()
    }

    func testDesktopLongTransposedPhrase() async throws {
        let url = lexiconURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Mac/DictionaryResources/lexicon.sqlite")
        let lexicon = try Lexicon(url: url)
        for script in [ChineseScript.simplified, .traditional] {
            let target = script == .simplified ? "中文词汇" : "中文詞彙"
            for options in [PinyinFuzzyOptions(), .all] {
                let policy = PinyinQueryPolicy.configured(options)
                for raw in ["zhomgwencihui", "zhongwnecihui", "zhongwencihui"] {
                    let found = try await lexicon.candidates(for: raw, layout: .pinyin, script: script,
                        limit: 48, pinyinPolicy: policy)
                    XCTAssertEqual(found.first?.text, target, "Wrong first candidate for \(raw): \(found.prefix(12).map(\.text))")
                    XCTAssertFalse(found.contains { ["中文了词汇", "中文了詞彙", "中文呢词汇", "中文呢詞彙"].contains($0.text) }, "Spurious extra syllable in corrected phrase: \(raw)")
                    let choice = try XCTUnwrap(found.first { $0.text == target })
                    let resolved = await lexicon.resolve(choice, for: raw, layout: .pinyin, script: script, pinyinPolicy: policy)
                    XCTAssertEqual(resolved?.consumed, raw.count)
                }
            }
        }
        await lexicon.close()
    }

    func testDesktopCompletePhrasesStayAheadOfPartialSingles() async throws {
        let lexicon = try Lexicon(url: lexiconURL)
        for script in [ChineseScript.simplified, .traditional] {
            for options in [PinyinFuzzyOptions(), .all] {
                for raw in ["shiti"] {
                    let policy = PinyinQueryPolicy.configured(options)
                    let found = try await lexicon.candidates(for: raw, layout: .pinyin, script: script,
                                                            limit: 64, pinyinPolicy: policy)
                    let singleIndex = try XCTUnwrap(found.firstIndex { $0.text.count == 1 })
                    let words = script == .simplified ? ["尸体", "实体", "试题", "诗体", "事体"]
                        : ["屍體", "實體", "試題", "詩體", "事體"]
                    for word in words {
                        let index = try XCTUnwrap(found.firstIndex { $0.text == word }, "Missing \(word)")
                        XCTAssertLessThan(index, singleIndex, "Complete phrase \(word) was pushed behind partial singles")
                        // Resolving a complete candidate changes Rime's context;
                        // obtain a fresh native identity for each selection.
                        let fresh = try await lexicon.candidates(for: raw, layout: .pinyin, script: script,
                                                               limit: 64, pinyinPolicy: policy)
                        let selected = try XCTUnwrap(fresh.first { $0.text == word })
                        let resolved = await lexicon.resolve(selected, for: raw, layout: .pinyin,
                                                             script: script, pinyinPolicy: policy)
                        XCTAssertEqual(resolved?.text, word)
                        XCTAssertEqual(resolved?.consumed, raw.count)
                    }
                }
            }
        }
        await lexicon.close()
    }

    func testDesktopCandidateReadsContinuePastNativeBatchBoundary() async throws {
        let lexicon = try Lexicon(url: lexiconURL)
        let found = try await lexicon.candidates(for: "shi", layout: .pinyin, script: .simplified,
            limit: 192, pinyinPolicy: .configured([]))
        XCTAssertGreaterThan(found.count, 64)
        XCTAssertEqual(Set(found.map(\.text)).count, found.count)
        let selected = try XCTUnwrap(found.first { ($0.engineIndex ?? 0) >= 64 })
        let resolved = await lexicon.resolve(selected, for: "shi", layout: .pinyin,
            script: .simplified, pinyinPolicy: .configured([]))
        XCTAssertEqual(resolved?.text, selected.text)
        XCTAssertEqual(resolved?.consumed, 3)
    }
    func testDesktopShortlistIncludesSelectableSingleCharacters() async throws {
        let lexicon = try Lexicon(url: lexiconURL)
        for (raw, target, remaining) in [("nihao", "你", "hao"), ("shijie", "是", "jie"), ("nihaoshijie", "你", "haoshijie"), ("zhezhenshirangrengaoxiao", "这", "zhenshirangrengaoxiao")] {
            let found = try await lexicon.candidates(for: raw, layout: .pinyin, script: .simplified,
                                                    limit: 48, pinyinPolicy: .configured(.all))
            XCTAssertGreaterThanOrEqual(found.filter { $0.text.count == 1 }.count, 4, "\(raw): \(found.map(\.text))")
            if raw.count > 8 {
                XCTAssertTrue(found.prefix(12).contains { $0.text == target }, "Long input buried its single-character fallback")
            }
            guard let chosen = found.first(where: { $0.text == target }) else { XCTFail("Missing \(target) for \(raw)"); continue }
            let resolved = await lexicon.resolve(chosen, for: raw, layout: .pinyin, script: .simplified, pinyinPolicy: .configured(.all))
            var composition = Composition(); composition.append(raw)
            _ = composition.commit(try XCTUnwrap(resolved))
            XCTAssertEqual(composition.input, remaining)
        }
    }
    private var lexiconURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/lexicon.sqlite")
    }

    func testDesktopCoverageHighlightDoesNotCommitAndKeepsNativeBoundaries() async throws {
        let data = lexiconURL.deletingLastPathComponent().appendingPathComponent("RimeData")
        for raw in ["shiti", "nihaoshijie", "nihao'shijie", "senti'shijie"] {
            let first = try await RimeInput.shared.candidates(raw: raw, layout: .pinyin, script: .simplified,
                data: data, limit: 64, pinyinPolicy: .configured(.all))
            XCTAssertEqual(first.first?.coversFullInput, true, "Already-highlighted first candidate was misclassified")
            XCTAssertTrue(first.allSatisfy { $0.consumed == 0 && $0.engineIndex != nil }, "Coverage probe committed a selection")
            let repeated = try await RimeInput.shared.candidates(raw: raw, layout: .pinyin, script: .simplified,
                data: data, limit: 64, pinyinPolicy: .configured(.all))
            XCTAssertEqual(first, repeated, "Highlighting changed subsequent native ranking")
            let target = raw.hasPrefix("senti") ? "身体" : "你好"
            if raw != "shiti" {
                let partial = try XCTUnwrap(first.first { $0.text == target })
                XCTAssertEqual(partial.coversFullInput, false)
                let resolved = try await RimeInput.shared.resolve(partial, raw: raw, layout: .pinyin,
                    script: .simplified, data: data, pinyinPolicy: .configured(.all))
                XCTAssertEqual(resolved?.consumed, 5)
            }
        }
        let lexicon = try Lexicon(url: lexiconURL)
        let syllable = try await lexicon.candidates(for: "shi", layout: .pinyin, script: .simplified,
            limit: 48, pinyinPolicy: .configured([]))
        XCTAssertEqual(syllable.first?.text, "是", "Phrase completions displaced a complete single syllable")
        let legacy = try await RimeInput.shared.candidates(raw: "shiti", layout: .pinyin, script: .simplified,
            data: data, limit: 48, pinyinPolicy: .legacy)
        XCTAssertTrue(legacy.allSatisfy { $0.coversFullInput == nil }, "Legacy/iPhone queries unexpectedly enabled desktop metadata")
        await lexicon.close()
    }

    private func query(_ lexicon: Lexicon, _ raw: String, _ options: PinyinFuzzyOptions,
                       script: ChineseScript = .simplified) async throws -> [Candidate] {
        try await lexicon.candidates(for: raw, layout: .pinyin, script: script,
                                     limit: 64, pinyinPolicy: .configured(options))
    }

    func testConfiguredOffDoesNotLeakLegacyPhoneticRepairs() async throws {
        let lexicon = try Lexicon(url: lexiconURL)
        for (raw, target) in [("senti", "身体"), ("zongguo", "中国"),
                              ("lihao", "你好"), ("pinan", "平安"), ("shengti", "身体")] {
            let off = try await query(lexicon, raw, [])
            XCTAssertFalse(off.contains { $0.text == target }, "Disabled fuzzy result leaked into \(raw): \(off.map(\.text))")
        }
        await lexicon.close()
    }

    func testLegacyDefaultsAndOrdinaryKeyboardTyposRemainAvailable() async throws {
        let lexicon = try Lexicon(url: lexiconURL)
        for (raw, target) in [("senti", "身体"), ("zongguo", "中国"), ("pinan", "平安"), ("nihap", "你好")] {
            let defaults = try await lexicon.candidates(for: raw, layout: .pinyin, script: .simplified)
            let legacy = try await lexicon.candidates(for: raw, layout: .pinyin, script: .simplified, pinyinPolicy: .legacy)
            XCTAssertEqual(defaults, legacy, "An omitted policy changed iPhone behavior")
            XCTAssertEqual(defaults.first?.text, target, raw)
        }
        for options in [PinyinFuzzyOptions(), .all] {
            let repaired = try await query(lexicon, "nihap", options)
            let greeting = try XCTUnwrap(repaired.first { $0.text == "你好" })
            let resolved = await lexicon.resolve(greeting, for: "nihap", layout: .pinyin,
                                                 script: .simplified, pinyinPolicy: .configured(options))
            XCTAssertEqual(resolved?.consumed, 5, "Ordinary adjacent-key correction was disabled")
        }
        await lexicon.close()
    }

    func testEachFuzzyPairMatchesBothDirectionsAndKeepsOtherPairsOff() async throws {
        let examples: [(PinyinFuzzyOptions, [(String, String)])] = [
            (.zZh, [("zongguo", "中国"), ("zhongjie", "总结")]),
            (.cCh, [("cifan", "吃饭"), ("changku", "仓库")]),
            (.sSh, [("senti", "身体"), ("shangshi", "丧失")]),
            (.nL, [("lihao", "你好"), ("nianxi", "联系")]),
            (.fH, [("heichang", "非常"), ("fuaer", "花儿")]),
            (.anAng, [("banmang", "帮忙"), ("gangjing", "干净")]),
            (.enEng, [("fentou", "风头"), ("shengti", "身体")]),
            (.inIng, [("beijindaxue", "北京大学"), ("jingtian", "今天")])
        ]
        let lexicon = try Lexicon(url: lexiconURL)
        for (options, pairs) in examples {
            for (raw, target) in pairs {
                // A following syllable disambiguates nasal matching from
                // ordinary end-of-input prefix completion (jin → jing...).
                let off = try await query(lexicon, raw, [])
                XCTAssertFalse(off.contains { $0.text == target }, "Unexpected disabled match \(raw) → \(target)")
                let enabled = try await query(lexicon, raw, options)
                guard let candidate = enabled.first(where: { $0.text == target }) else {
                    XCTFail("Missing enabled match \(raw) → \(target): \(enabled.map(\.text))")
                    continue
                }
                XCTAssertNotNil(candidate.engineIndex, "Configured phonetics bypassed the native engine")
                let resolved = await lexicon.resolve(candidate, for: raw, layout: .pinyin,
                    script: .simplified, pinyinPolicy: .configured(options))
                XCTAssertEqual(resolved?.consumed, raw.count, "Wrong full consumption for \(raw) → \(target)")
            }
            if options != .sSh {
                let unrelated = try await query(lexicon, "senti", options)
                XCTAssertFalse(unrelated.contains { $0.text == "身体" }, "An unrelated option enabled s/sh")
            }
        }
        await lexicon.close()
    }

    func testValidSingleSyllableAndExistingWordsStillGainFuzzyChoices() async throws {
        let lexicon = try Lexicon(url: lexiconURL)
        let off = try await query(lexicon, "si", [])
        XCTAssertFalse(off.contains { $0.text == "是" })
        let on = try await query(lexicon, "si", .sSh)
        XCTAssertTrue(on.contains { $0.text == "是" }, "Valid si was excluded by the old typo-only gate")
        XCTAssertTrue(on.contains { $0.text == "四" }, "Fuzzy matching removed an exact candidate")
        let word = try await query(lexicon, "laosi", .sSh)
        XCTAssertTrue(word.contains { $0.text == "老师" }, "Existing exact phrase blocked a word-internal fuzzy syllable")
        XCTAssertTrue(word.contains { $0.text == "老死" }, "Word-internal fuzzy matching replaced exact words")
        await lexicon.close()
    }

    func testExactWordsLeadConfiguredFuzzyMatches() async throws {
        let root = lexiconURL.deletingLastPathComponent().deletingLastPathComponent()
        let lexicon = try Lexicon(url: root.appendingPathComponent("Mac/DictionaryResources/lexicon.sqlite"))
        for (code, exact, fuzzy, option) in [("zihao", ["自豪", "字号"], "只好", PinyinFuzzyOptions.zZh),
                                             ("zhihao", ["只好"], "自豪", .zZh),
                                             ("nianxi", ["年息"], "联系", .nL)] {
            for limit in [1, 48] {
                let found = try await lexicon.candidates(for: code, layout: .pinyin, script: .simplified,
                                                         limit: limit, pinyinPolicy: .configured(option))
                let first = try XCTUnwrap(found.first)
                XCTAssertTrue(exact.contains(first.text), "\(code) → \(first.text)")
                if limit > 1 { XCTAssertTrue(found.dropFirst().contains { $0.text == fuzzy }, code) }
            }
        }
    }

    func testCompleteSentenceSyllablesWithConfiguredFuzzySearch() async throws {
        let root = lexiconURL.deletingLastPathComponent().deletingLastPathComponent()
        let lexicon = try Lexicon(url: root.appendingPathComponent("Mac/DictionaryResources/lexicon.sqlite"))
        let raw = "zhegexiaofuohenhao"
        let policy = PinyinQueryPolicy.configured(.all)
        let found = try await lexicon.candidates(for: raw, layout: .pinyin, script: .simplified,
                                                 limit: 1, pinyinPolicy: policy)
        let choice = try XCTUnwrap(found.first)
        XCTAssertTrue(choice.text.hasPrefix("这个小") && choice.text.hasSuffix("很好"), choice.text)
        let resolved = await lexicon.resolve(choice, for: raw, layout: .pinyin, script: .simplified,
                                              pinyinPolicy: policy)
        XCTAssertEqual(resolved?.consumed, raw.count)
    }

    func testRepeatedSyllablesLongPhraseAndTraditionalScript() async throws {
        let lexicon = try Lexicon(url: lexiconURL)
        for (raw, target, options, script) in [
            ("lailai", "奶奶", PinyinFuzzyOptions.nL, ChineseScript.simplified),
            ("zongguorenmin", "中国人民", .zZh, .simplified),
            ("zongguo", "中國", .zZh, .traditional),
            ("laosi", "老師", .sSh, .traditional)
        ] {
            let found = try await query(lexicon, raw, options, script: script)
            let candidate = try XCTUnwrap(found.first { $0.text == target }, "Missing \(raw) → \(target)")
            let resolved = await lexicon.resolve(candidate, for: raw, layout: .pinyin,
                script: script, pinyinPolicy: .configured(options))
            XCTAssertEqual(resolved?.consumed, raw.count)
        }
        await lexicon.close()
    }

    func testPartialSelectionsConsumeOriginalSpellingAndApostropheBoundary() async throws {
        let lexicon = try Lexicon(url: lexiconURL)
        for (raw, target, consumed, remainder) in [
            ("sentishijie", "身体", 5, "shijie"),
            ("senti'shijie", "身体", 5, "shijie"),
            ("shangshi'le", "丧失", 8, "le"),
            ("si'jie", "是", 2, "jie")
        ] {
            let found = try await query(lexicon, raw, .sSh)
            let candidate = try XCTUnwrap(found.first { $0.text == target }, "Missing partial \(raw) → \(target)")
            let resolution = await lexicon.resolve(candidate, for: raw, layout: .pinyin,
                script: .simplified, pinyinPolicy: .configured(.sSh))
            let resolved = try XCTUnwrap(resolution)
            XCTAssertEqual(resolved.consumed, consumed, "Consumption used a normalized spelling length")
            var composition = Composition()
            composition.append(raw)
            XCTAssertEqual(composition.commit(resolved), target)
            XCTAssertEqual(composition.input, remainder)
        }
        await lexicon.close()
    }

    func testResolutionRestoresPolicyAfterOtherQueriesUseSharedRimeSession() async throws {
        let lexicon = try Lexicon(url: lexiconURL)
        let found = try await query(lexicon, "senti'shijie", .sSh)
        let body = try XCTUnwrap(found.first { $0.text == "身体" })
        _ = try await query(lexicon, "lihao", .nL)
        _ = try await query(lexicon, "senti'shijie", [])
        let resolved = await lexicon.resolve(body, for: "senti'shijie", layout: .pinyin,
            script: .simplified, pinyinPolicy: .configured(.sSh))
        XCTAssertEqual(resolved?.text, "身体")
        XCTAssertEqual(resolved?.consumed, 5)
        await lexicon.close()
    }

    func testLearnedFuzzyAliasesFollowPolicyAndLegacyWordsRemainVisible() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fuzzy-learning-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lexicon = try Lexicon(url: lexiconURL, learnedURL: directory.appendingPathComponent("learned.json"))
        try await lexicon.learn(code: "senti", text: "模糊学习别名", layout: .pinyin,
            script: .simplified, pinyinPolicy: .configured(.sSh))
        let enabled = try await query(lexicon, "senti", .sSh)
        XCTAssertEqual(enabled.first?.text, "模糊学习别名")
        for options in [PinyinFuzzyOptions(), .nL] {
            let disabled = try await query(lexicon, "senti", options)
            XCTAssertFalse(disabled.contains { $0.text == "模糊学习别名" })
        }
        let combined = try await query(lexicon, "senti", .all)
        XCTAssertEqual(combined.first?.text, "模糊学习别名")
        try await lexicon.learn(code: "nihaoshijie", text: "你好世界", layout: .pinyin,
            script: .simplified, pinyinPolicy: .configured(.sSh))
        let standard = try await query(lexicon, "nihaoshijie", [])
        XCTAssertEqual(standard.first?.text, "你好世界")
        XCTAssertNil(standard.first?.engineIndex, "Ordinary learned phrase was hidden when fuzzy matching was disabled")
        try await lexicon.learn(code: "dise", text: "原有学习词", layout: .pinyin, script: .simplified)
        let legacy = try await query(lexicon, "dise", [])
        XCTAssertEqual(legacy.first?.text, "原有学习词")
        // Initials use an early-return path and must apply the same scope.
        try await lexicon.learn(code: "sl", text: "简称学习别名", layout: .pinyin,
            script: .simplified, pinyinPolicy: .configured(.sSh))
        let initialsOff = try await query(lexicon, "sl", [])
        let initialsOn = try await query(lexicon, "sl", .sSh)
        XCTAssertFalse(initialsOff.contains { $0.text == "简称学习别名" })
        XCTAssertTrue(initialsOn.contains { $0.text == "简称学习别名" })
        await lexicon.close()
    }
}
