import XCTest
@testable import KeyboardCore

final class MobilePinyinTests: XCTestCase {
    private var lexiconURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/lexicon.sqlite")
    }

    func testFuzzySettingDefaultsOnForNewAndExistingUsers() throws {
        XCTAssertTrue(KeyboardSettings().fuzzyPinyinEnabled)
        let stored = Data(#"{"layout":"nineKey","script":"traditional","translationEnabled":false}"#.utf8)
        var settings = try JSONDecoder().decode(KeyboardSettings.self, from: stored)
        XCTAssertTrue(settings.fuzzyPinyinEnabled)
        XCTAssertEqual(settings.layout, .nineKey)
        XCTAssertEqual(settings.script, .traditional)
        XCTAssertFalse(settings.translationEnabled)
        settings.fuzzyPinyinEnabled = false
        let saved = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(KeyboardSettings.self, from: saved), settings)
    }

    func testMobileFuzzyMatchesBothDirectionsAndCanBeDisabled() async throws {
        let lexicon = try Lexicon(url: lexiconURL)
        let examples = [
            ("zongguo", "中国"), ("zhongjie", "总结"), ("cifan", "吃饭"), ("changku", "仓库"),
            ("senti", "身体"), ("shangshi", "丧失"), ("lihao", "你好"), ("nianxi", "联系"),
            ("heichang", "非常"), ("fuaer", "花儿"), ("banmang", "帮忙"), ("gangjing", "干净"),
            ("fentou", "风头"), ("shengti", "身体"), ("beijindaxue", "北京大学"), ("jingtian", "今天"),
            ("lianan", "两岸"), ("liangxi", "联系"), ("guanhua", "光滑"), ("guangbi", "关闭")
        ]
        for (raw, target) in examples {
            let off = try await lexicon.candidates(for: raw, layout: .pinyin, script: .simplified,
                                                   pinyinPolicy: .mobile(fuzzy: false))
            XCTAssertFalse(off.contains { $0.text == target }, "\(raw) → \(target)")
            try await checkSelection(lexicon, input: raw, target: target)
        }
        try await checkSelection(lexicon, input: "senti", target: "身體", script: .traditional)
        let original = try await lexicon.candidates(for: "zhongguo", layout: .pinyin, script: .simplified,
                                                    limit: 1, pinyinPolicy: .mobile(fuzzy: true))
        XCTAssertEqual(original.first?.text, "中国")
        try await checkSelection(lexicon, input: "nh", target: "你好")

        let strictGroups = await lexicon.singleCandidateGroups(for: "fa", script: .simplified,
                                                               pinyinPolicy: .mobile(fuzzy: false))
        XCTAssertFalse(strictGroups.contains { $0.isCorrection })
        let fuzzyGroups = await lexicon.singleCandidateGroups(for: "fa", script: .simplified,
                                                              pinyinPolicy: .mobile(fuzzy: true))
        XCTAssertTrue(fuzzyGroups.contains { $0.label == "ha" && $0.candidates.contains { $0.text == "哈" } })
    }

    func testNineKeyUsesTheSameFuzzySetting() async throws {
        let lexicon = try Lexicon(url: lexiconURL)
        let raw = KeyCoding.nineKey("zongguo")
        for (script, target) in [(ChineseScript.simplified, "中国"), (.traditional, "中國")] {
            let off = try await lexicon.candidates(for: raw, layout: .nineKey, script: script,
                                                   pinyinPolicy: .mobile(fuzzy: false))
            XCTAssertFalse(off.contains { $0.text == target })
            try await checkSelection(lexicon, input: raw, target: target, layout: .nineKey, script: script)
        }
    }

    func testCompletePinyinPrecedesFuzzyWords() async throws {
        let lexicon = try Lexicon(url: lexiconURL)
        for script in [ChineseScript.simplified, .traditional] {
            let zihao = ["自豪", script == .simplified ? "字号" : "字號"]
            let examples = [("zihao", zihao, "只好"), ("zi'hao", zihao, "只好"),
                            ("zhihao", ["只好"], "自豪"), ("lihao", ["利好"], "你好"),
                            ("nianxi", ["年息"], script == .simplified ? "联系" : "聯繫"),
                            ("heichang", [script == .simplified ? "黑肠" : "黑腸"], "非常")]
            for (raw, exact, fuzzy) in examples {
                for limit in [1, 48] {
                    let found = try await lexicon.candidates(for: raw, layout: .pinyin, script: script,
                        limit: limit, pinyinPolicy: .mobile(fuzzy: true))
                    let choice = try XCTUnwrap(found.first)
                    XCTAssertTrue(exact.contains(choice.text), "\(raw) → \(choice.text)")
                    if limit > 1 { XCTAssertTrue(found.dropFirst().contains { $0.text == fuzzy }, raw) }
                    let selected = await lexicon.resolve(choice, for: raw, layout: .pinyin, script: script,
                                                         pinyinPolicy: .mobile(fuzzy: true))
                    XCTAssertEqual(selected?.consumed, raw.count, raw)
                }
            }
            let strict = try await lexicon.candidates(for: "zihao", layout: .pinyin, script: script,
                                                     pinyinPolicy: .mobile(fuzzy: false))
            XCTAssertTrue(zihao.contains(try XCTUnwrap(strict.first).text))
            XCTAssertFalse(strict.contains { $0.text == "只好" })
        }
    }

    func testSupportedStandardSentencesExcludeUnsupportedFuzzySentences() async throws {
        let lexicon = try Lexicon(url: lexiconURL)
        let policy = PinyinQueryPolicy.mobile(fuzzy: true)
        let sentences = [
            (code: "buzaoshuo", separated: "bu'zao'shuo", pronoun: ""),
            (code: "nibuzaoshuo", separated: "ni'bu'zao'shuo", pronoun: "你"),
            (code: "wobuzaoshuo", separated: "wo'bu'zao'shuo", pronoun: "我"),
        ]
        for script in [ChineseScript.simplified, .traditional] {
            let finalCharacter = script == .simplified ? "说" : "說"
            for sentence in sentences {
                let expected = sentence.pronoun + "不早" + finalCharacter
                let unsupported = ["不找", "不着", "不著"].map { sentence.pronoun + $0 + finalCharacter }
                let hasWholeEntry = await lexicon.hasExactPinyinReading(sentence.code, script: script)
                XCTAssertEqual(hasWholeEntry, sentence.pronoun.isEmpty, sentence.code)
                for raw in [sentence.code, sentence.separated] {
                    for limit in [1, 48] {
                        let found = try await lexicon.candidates(for: raw, layout: .pinyin, script: script,
                                                                limit: limit, pinyinPolicy: policy)
                        let first = try XCTUnwrap(found.first, raw)
                        XCTAssertEqual(first.text, expected, raw)
                        let resolved = await lexicon.resolve(first, for: raw, layout: .pinyin, script: script,
                                                             pinyinPolicy: policy)
                        XCTAssertEqual(resolved?.consumed, raw.count, raw)
                        if limit > 1 {
                            XCTAssertFalse(found.contains { unsupported.contains($0.text) }, raw)
                            let component = sentence.pronoun.isEmpty ? "不" : sentence.pronoun
                            let partial = try XCTUnwrap(found.first { $0.text == component }, raw)
                            let selected = await lexicon.resolve(partial, for: raw, layout: .pinyin, script: script,
                                                                 pinyinPolicy: policy)
                            var composition = Composition()
                            composition.append(raw)
                            XCTAssertEqual(composition.commit(try XCTUnwrap(selected, raw)), component, raw)
                            let remaining = String(raw.dropFirst(2)).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
                            XCTAssertEqual(composition.input, remaining, raw)
                        }
                    }
                }
            }
        }
    }

    func testWordSupportedFuzzyCompositionsStaySelectable() async throws {
        let lexicon = try Lexicon(url: lexiconURL)
        let hasWholeChinesePeople = await lexicon.hasExactPinyinReading("zhongguorenmin", script: .simplified)
        XCTAssertFalse(hasWholeChinesePeople)
        try await checkSelection(lexicon, input: "zongguorenmin", target: "中国人民")
        try await checkSelection(lexicon, input: "senglin", target: "森林")

        try await checkSelection(lexicon, input: "fangxin", target: "放心")
    }

    func testVerifiedStandardSentencesHideCompetingFuzzySentences() async throws {
        let lexicon = try Lexicon(url: lexiconURL)
        let policy = PinyinQueryPolicy.mobile(fuzzy: true)
        let examples = [
            (["nijinwanyaozijiquchi", "ni'jin'wan'yao'zi'ji'qu'chi"], "你今晚要自己去吃", "你今晚要自己去次"),
            (["woyaofangxing"], "我要放行", "我要放心"),
        ]
        for (inputs, exact, fuzzy) in examples {
            for raw in inputs {
                for limit in [1, 48] {
                    let found = try await lexicon.candidates(for: raw, layout: .pinyin, script: .simplified,
                                                             limit: limit, pinyinPolicy: policy)
                    let first = try XCTUnwrap(found.first, raw)
                    XCTAssertEqual(first.text, exact, raw)
                    let resolved = await lexicon.resolve(first, for: raw, layout: .pinyin, script: .simplified,
                                                         pinyinPolicy: policy)
                    XCTAssertEqual(resolved?.consumed, raw.count, raw)
                    if limit > 1 {
                        XCTAssertFalse(found.contains { $0.text == fuzzy }, raw)
                        XCTAssertTrue(found.contains { $0.text.count == 1 }, raw)
                    }
                }
            }
        }
    }

    func testOtherSoundPairsExcludeUnsupportedFuzzySentences() async throws {
        let lexicon = try Lexicon(url: lexiconURL)
        let policy = PinyinQueryPolicy.mobile(fuzzy: true)
        let examples = [
            (inputs: ["ceshizhege", "ce'shi'zhe'ge"], expected: "测试这个", removed: "车是这个", partial: "测试"),
            (inputs: ["buyaosaodi", "bu'yao'sao'di"], expected: "不要扫地", removed: "不要少的", partial: "不要"),
        ]
        for example in examples {
            for raw in example.inputs {
                let found = try await lexicon.candidates(for: raw, layout: .pinyin, script: .simplified,
                                                         limit: 48, pinyinPolicy: policy)
                let first = try XCTUnwrap(found.first, raw)
                XCTAssertEqual(first.text, example.expected, raw)
                XCTAssertFalse(found.contains { $0.text == example.removed }, raw)
                XCTAssertTrue(found.contains { $0.text == example.partial }, raw)
                let resolved = await lexicon.resolve(first, for: raw, layout: .pinyin, script: .simplified,
                                                     pinyinPolicy: policy)
                XCTAssertEqual(resolved?.consumed, raw.count, raw)
            }
        }
    }

    func testLearnedFuzzyWordStaysBehindExactPinyin() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("fuzzy-order-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let lexicon = try Lexicon(url: lexiconURL, learnedURL: file)
        let policy = PinyinQueryPolicy.mobile(fuzzy: true)
        try await lexicon.learn(code: "zihao", text: "只好", layout: .pinyin, script: .simplified, pinyinPolicy: policy)
        let found = try await lexicon.candidates(for: "zihao", layout: .pinyin, script: .simplified, pinyinPolicy: policy)
        XCTAssertTrue(["自豪", "字号"].contains(try XCTUnwrap(found.first).text))
        XCTAssertEqual(found.filter { $0.text == "只好" }.count, 1)
    }

    func testCompleteSyllablesPrecedeShorthandInsideSentences() async throws {
        let lexicon = try Lexicon(url: lexiconURL)
        for fuzzy in [false, true] {
            let policy = PinyinQueryPolicy.mobile(fuzzy: fuzzy)
            let examples = [("henhao", "很好"), ("hen'hao", "很好"),
                            ("zhegexiaofuhenhao", "这个小腹很好"),
                            ("zhegexiaofuohenhao", fuzzy ? "这个小伙很好" : "这个小腹哦很好")]
            for (raw, expected) in examples {
                let found = try await lexicon.candidates(for: raw, layout: .pinyin, script: .simplified,
                                                         limit: 1, pinyinPolicy: policy)
                let choice = try XCTUnwrap(found.first, raw)
                XCTAssertEqual(choice.text, expected, raw)
                let resolved = await lexicon.resolve(choice, for: raw, layout: .pinyin, script: .simplified,
                                                      pinyinPolicy: policy)
                XCTAssertEqual(resolved?.consumed, raw.count, raw)
            }
        }
    }

    func testUnrecognizedPinyinInitialNeedsPhraseEvidenceBeforeRepair() async throws {
        let lexicon = try Lexicon(url: lexiconURL)
        for fuzzy in [false, true] {
            let policy = PinyinQueryPolicy.mobile(fuzzy: fuzzy)
            for input in ["iphone", "iphome"] {
                let found = try await lexicon.candidates(for: input, layout: .pinyin, script: .simplified,
                                                         pinyinPolicy: policy)
                XCTAssertTrue(found.isEmpty, "\(input) → \(found.map(\.text))")
            }
            let typo = try await lexicon.candidates(for: "inhao", layout: .pinyin, script: .simplified,
                                                    pinyinPolicy: policy)
            XCTAssertEqual(typo.first?.text, "你好")
        }
    }

    func testPinyinRepairsWithImplicitStandaloneVowels() async throws {
        let lexicon = try Lexicon(url: lexiconURL)
        for fuzzy in [false, true] {
            let policy = PinyinQueryPolicy.mobile(fuzzy: fuzzy)
            for (input, expected) in [("shioba", "说吧"), ("nishioba", "你说吧"),
                                      ("youdiogaoxing", "有多高兴"), ("youdiohaokan", "有多好看"),
                                      ("niciole", "你错了"), ("wotioyifu", "我脱衣服"),
                                      ("jiandanlaishio", "简单来说"), ("yibanlaishio", "一般来说"),
                                      ("nihaoa", "你好啊"), ("nihaoaqushui", "你好啊取水")] {
                for limit in [1, 48] {
                    let found = try await lexicon.candidates(for: input, layout: .pinyin, script: .simplified,
                                                             limit: limit, pinyinPolicy: policy)
                    let first = try XCTUnwrap(found.first)
                    XCTAssertEqual(first.text, expected, input)
                    let resolved = await lexicon.resolve(first, for: input, layout: .pinyin, script: .simplified,
                                                          pinyinPolicy: policy)
                    XCTAssertEqual(resolved?.consumed, input.count, input)
                }
            }
            for (input, corrected) in [("shi'o'ba", "说吧"), ("ni'shi'o'ba", "你说吧"),
                                      ("you'di'o'gao'xing", "有多高兴"),
                                      ("jiandanlaishi'o", "简单来说")] {
                let explicit = try await lexicon.candidates(for: input, layout: .pinyin, script: .simplified,
                                                             pinyinPolicy: policy)
                XCTAssertFalse(explicit.contains { $0.text == corrected }, input)
            }
        }
    }

    func testPinyinRepairsAnInternalInitialWhenTheJoinedSyllableHasPhraseSupport() async throws {
        let lexicon = try Lexicon(url: lexiconURL)
        for fuzzy in [false, true] {
            let policy = PinyinQueryPolicy.mobile(fuzzy: fuzzy)
            for (input, expected) in [("qingchulimshiwenjian", "清楚临时文件"),
                                      ("shanchulimshiwenjian", "删除临时文件"),
                                      ("qing'chu'lim'shi'wen'jian", "清楚临时文件")] {
                for limit in [1, 48] {
                    let found = try await lexicon.candidates(for: input, layout: .pinyin, script: .simplified,
                                                             limit: limit, pinyinPolicy: policy)
                    let first = try XCTUnwrap(found.first, input)
                    XCTAssertEqual(first.text, expected, input)
                    let resolved = await lexicon.resolve(first, for: input, layout: .pinyin, script: .simplified,
                                                          pinyinPolicy: policy)
                    XCTAssertEqual(resolved?.consumed, input.count, input)
                }
            }
            let explicit = try await lexicon.candidates(for: "qing'chu'li'm'shi'wen'jian", layout: .pinyin,
                                                         script: .simplified, pinyinPolicy: policy)
            XCTAssertFalse(explicit.contains { $0.text == "清楚临时文件" })
        }
    }

    func testFuzzyMatchingDoesNotRewriteTypedInitials() async throws {
        let lexicon = try Lexicon(url: lexiconURL)
        for script in [ChineseScript.simplified, .traditional] {
            for raw in ["lq", "nq", "fq", "hq", "zhq", "chq", "shq", "lqhao", "nhao"] {
                let strict = try await lexicon.candidates(for: raw, layout: .pinyin, script: script,
                                                           pinyinPolicy: .mobile(fuzzy: false))
                let fuzzy = try await lexicon.candidates(for: raw, layout: .pinyin, script: script,
                                                          pinyinPolicy: .mobile(fuzzy: true))
                XCTAssertFalse(strict.isEmpty, raw)
                // Mixed input can still use a fuzzy match for a fully typed syllable.
                let comparableCount = raw.hasSuffix("hao") ? 1 : 4
                XCTAssertEqual(fuzzy.prefix(comparableCount).map(\.text),
                               strict.prefix(comparableCount).map(\.text), raw)
                XCTAssertEqual(fuzzy.first?.reading, raw, raw)
                let best = try await lexicon.candidates(for: raw, layout: .pinyin, script: script,
                                                         limit: 1, pinyinPolicy: .mobile(fuzzy: true))
                XCTAssertEqual(best.first?.text, strict.first?.text, raw)
            }
        }
    }

    func testSentenceTyposRankFirstWithOrWithoutFuzzySounds() async throws {
        let lexicon = try Lexicon(url: lexiconURL)
        let examples = [("zhomgw", "中文"), ("zhomg'w", "中文"), ("woxuezhomgw", "我学中文"),
                        ("jj'saun'j", "计算机"), ("zhomgwne", "中文"), ("zhomg'wne", "中文"),
                        ("chamgjianh", "长江"), ("jj'saun'ij", "计算机"),
                        ("zhomgwnecih", "中文词汇"), ("zhomg'wne'ci'h", "中文词汇"),
                        ("jj'saun'ij'd", "计算机的"),
                        ("zhomgwencihui", "中文词汇"), ("woxuezhomgwencihui", "我学中文词汇"),
                        ("zhomg'wen'cihui", "中文词汇"),
                        ("chamgjiang", "长江"), ("zhongwencihui", "中文词汇"),
                        ("woaibeijinhdaxue", "我爱北京大学"), ("woxuezhongwencihyi", "我学中文词汇"),
                        ("woxihuanhechz", "我喜欢喝茶"), ("woxihuanhecga", "我喜欢喝茶"),
                        ("zhongwnecihui", "中文词汇"), ("zhomgwnecihui", "中文词汇"),
                        ("zhomg'wne'cihui", "中文词汇"), ("woaibeijinhdaxeu", "我爱北京大学"),
                        ("woxuezhomgwnecihyi", "我学中文词汇"),
                        ("woxuezhomgwnecihyiwoxihuanhecga", "我学中文词汇我喜欢喝茶")]
        for enabled in [false, true] {
            let policy = PinyinQueryPolicy.mobile(fuzzy: enabled)
            for (input, target) in examples {
                let full = try await lexicon.candidates(for: input, layout: .pinyin, script: .simplified,
                                                        pinyinPolicy: policy)
                XCTAssertEqual(full.first?.text, target, input)
                let best = try await lexicon.candidates(for: input, layout: .pinyin, script: .simplified,
                                                        limit: 1, pinyinPolicy: policy)
                XCTAssertEqual(best.first?.text, target, input)
                let choice = try XCTUnwrap(best.first)
                let selected = await lexicon.resolve(choice, for: input, layout: .pinyin,
                                                      script: .simplified, pinyinPolicy: policy)
                var composition = Composition()
                composition.append(input)
                XCTAssertEqual(composition.commit(try XCTUnwrap(selected)), target)
                XCTAssertTrue(composition.input.isEmpty)
            }
        }
    }

    func testAmbiguousRepairKeepsNativeFirstWhileShowingCorrectedAlternative() async throws {
        let lexicon = try Lexicon(url: lexiconURL)
        let input = "woxuezhongwwncihui"
        let candidates = try await lexicon.candidates(for: input, layout: .pinyin, script: .simplified,
                                                       pinyinPolicy: .mobile(fuzzy: false))
        XCTAssertEqual(candidates.first?.reading, input)
        let corrected = try XCTUnwrap(candidates.first { $0.text == "我学中文词汇" })
        XCTAssertEqual(corrected.consumed, input.count)
    }

    func testVerifiedRepairKeepsPrefixChoicesAndRemovesRawWholeInputGuesses() async throws {
        let lexicon = try Lexicon(url: lexiconURL)
        let policy = PinyinQueryPolicy.mobile(fuzzy: true)
        for (input, expected) in [("zhomgwne", "中文"), ("zhomgw", "中文"),
                                  ("zhomgwnecih", "中文词汇"), ("woaibeijinhdaxeu", "我爱北京大学")] {
            let candidates = try await lexicon.candidates(for: input, layout: .pinyin, script: .simplified,
                                                           pinyinPolicy: policy)
            XCTAssertEqual(candidates.first?.text, expected, input)
            XCTAssertFalse(candidates.contains { $0.engineIndex != nil && $0.coversFullInput == true }, input)
            let prefix = try XCTUnwrap(candidates.first { $0.engineIndex != nil && $0.text.count == 1 }, input)
            let resolved = await lexicon.resolve(prefix, for: input, layout: .pinyin,
                                                 script: .simplified, pinyinPolicy: policy)
            let consumed = try XCTUnwrap(resolved?.consumed)
            XCTAssertGreaterThan(consumed, 0)
            XCTAssertLessThan(consumed, input.count)
        }
    }

    func testSentenceRepairLeavesValidOrUnfinishedSpellingAlone() {
        let syllables: Set<String> = ["ni", "hao", "pa", "o", "shi", "jie"]
        XCTAssertTrue(PinyinTolerance.sentenceRepairs(of: "nihaoshijie", syllables: syllables).isEmpty)
        XCTAssertTrue(PinyinTolerance.sentenceRepairs(of: "nihaop", syllables: syllables).isEmpty)
    }

    func testSentenceRepairPreservesTheUnfinishedSyllable() throws {
        let syllables: Set<String> = ["zhong", "wen", "wei", "wo", "xue"]
        XCTAssertTrue(PinyinTolerance.sentenceRepairs(of: "zhongw", syllables: syllables).isEmpty)
        for (raw, corrected) in [("zhomgw", "zhong'w"), ("zhomg'we", "zhong'we"),
                                 ("woxuezhomgw", "woxuezhong'w")] {
            let repaired = try XCTUnwrap(PinyinTolerance.sentenceRepairs(of: raw, syllables: syllables)
                .first { $0.hasUnfinishedTail })
            XCTAssertEqual(repaired.spellings, [corrected])
            XCTAssertTrue(repaired.hasUnfinishedTail)
        }
    }

    func testRepairsWithoutIntactSyllablesNeedDictionaryEvidence() async throws {
        let lexicon = try Lexicon(url: lexiconURL)
        let policy = PinyinQueryPolicy.mobile(fuzzy: false)
        let ambiguous = try await lexicon.candidates(for: "sihjje", layout: .pinyin, script: .simplified,
                                                       pinyinPolicy: policy)
        XCTAssertEqual(ambiguous.first?.reading, "sihjje")
        XCTAssertTrue(ambiguous.contains { $0.text == "世界" && $0.reading == "shijie" })
        XCTAssertTrue(ambiguous.contains { $0.text == "视觉" && $0.reading == "shijue" })

        let input = "zzzzzzzz"
        let noisy = try await lexicon.candidates(for: input, layout: .pinyin, script: .simplified,
                                                  pinyinPolicy: policy)
        XCTAssertTrue(noisy.allSatisfy { $0.reading == input })
    }

    func testSeparateDictionaryPhrasesCanSupportRepairsBeforeAnUnfinishedSyllable() throws {
        let syllables: Set<String> = ["bei", "jing", "da", "xue", "xia", "kan"]
        let repairs = PinyinTolerance.sentenceRepairs(of: "bejjinhdaxeu'k", syllables: syllables)
        let partial = try XCTUnwrap(repairs.first { $0.hasUnfinishedTail })
        let reading = try XCTUnwrap(partial.readings.first { $0.code == "beijingdaxue'k" })
        XCTAssertTrue(partial.requiresDictionaryEvidence)
        XCTAssertEqual(reading.syllables.filter(\.wasEdited).map(\.code), ["bei", "jing", "xue"])
        XCTAssertTrue(reading.hasPhraseSupport { ["beijing", "daxue"].contains($0) })
        XCTAssertFalse(reading.hasPhraseSupport { $0 == "beijing" })
        XCTAssertFalse(reading.hasPhraseSupport { $0 == "jingdaxuek" })
    }

    private func checkSelection(_ lexicon: Lexicon, input: String, target: String,
                                layout: KeyboardLayout = .pinyin, script: ChineseScript = .simplified) async throws {
        let policy = PinyinQueryPolicy.mobile(fuzzy: true)
        let found = try await lexicon.candidates(for: input, layout: layout, script: script, pinyinPolicy: policy)
        let choice = try XCTUnwrap(found.first { $0.text == target }, "\(input) → \(target)")
        let resolved = await lexicon.resolve(choice, for: input, layout: layout, script: script, pinyinPolicy: policy)
        XCTAssertEqual(resolved?.consumed, input.count, "\(input) → \(target)")
    }
}
