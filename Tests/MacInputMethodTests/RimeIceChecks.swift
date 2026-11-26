import Foundation
import KeyboardCore

private struct RimeIceCheckFailure: Error, CustomStringConvertible {
    let description: String
}

@main struct RimeIceChecks {
    static func main() async throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let lexicon = try Lexicon(url: resources.appendingPathComponent("lexicon.sqlite"))
        let phrases = [
            (code: "buzaoshuo", separated: "bu'zao'shuo", hans: "不早说", hant: "不早說"),
            (code: "huangesaidao", separated: "huan'ge'sai'dao", hans: "换个赛道", hant: "換個賽道"),
        ]
        let policies: [(String, PinyinQueryPolicy)] = [
            ("strict", .configured([])),
            ("retroflex", .configured(.retroflex)),
            ("all fuzzy", .configured(.all)),
        ]

        for script in [ChineseScript.simplified, .traditional] {
            for phrase in phrases {
                let target = script == .simplified ? phrase.hans : phrase.hant
                guard await lexicon.hasExactPinyinReading(phrase.code, script: script) else {
                    throw RimeIceCheckFailure(description: "Exact SQLite reading is missing: \(phrase.code) → \(target)")
                }
                for raw in [phrase.code, phrase.separated] {
                    for (label, policy) in policies {
                        let candidates = try await lexicon.candidates(for: raw, layout: .pinyin, script: script,
                                                                     limit: 48, pinyinPolicy: policy)
                        guard let first = candidates.first, first.text == target else {
                            throw RimeIceCheckFailure(description:
                                "\(label), \(script.rawValue), \(raw): expected \(target) first, got \(candidates.prefix(5).map(\.text))")
                        }
                        let resolved = await lexicon.resolve(first, for: raw, layout: .pinyin, script: script,
                                                             pinyinPolicy: policy)
                        guard resolved?.consumed == raw.count else {
                            throw RimeIceCheckFailure(description: "\(label), \(raw): \(target) did not consume all input")
                        }
                    }
                }
                print("PASS \(script.rawValue): \(phrase.code) → \(target) with full selection in all three policies")
            }
        }

        let sentences = [
            (code: "nibuzaoshuo", separated: "ni'bu'zao'shuo", pronoun: "你"),
            (code: "wobuzaoshuo", separated: "wo'bu'zao'shuo", pronoun: "我"),
        ]
        for script in [ChineseScript.simplified, .traditional] {
            let finalCharacter = script == .simplified ? "说" : "說"
            for sentence in sentences {
                let target = sentence.pronoun + "不早" + finalCharacter
                let unsupported = ["不找", "不着", "不著"].map { sentence.pronoun + $0 + finalCharacter }
                let hasWholeEntry = await lexicon.hasExactPinyinReading(sentence.code, script: script)
                guard !hasWholeEntry else {
                    throw RimeIceCheckFailure(description: "Expected a composed sentence, found an exact entry for \(sentence.code)")
                }
                for raw in [sentence.code, sentence.separated] {
                    for (label, policy) in policies {
                        for limit in [1, 48] {
                            let candidates = try await lexicon.candidates(for: raw, layout: .pinyin, script: script,
                                                                         limit: limit, pinyinPolicy: policy)
                            guard let first = candidates.first, first.text == target,
                                  await lexicon.resolve(first, for: raw, layout: .pinyin, script: script,
                                                        pinyinPolicy: policy)?.consumed == raw.count else {
                                throw RimeIceCheckFailure(description:
                                    "\(label), \(script.rawValue), \(raw), limit \(limit): expected full \(target) first, got \(candidates.prefix(5).map(\.text))")
                            }
                            if limit == 48, policy != .configured([]) {
                                guard !candidates.contains(where: { unsupported.contains($0.text) }) else {
                                    throw RimeIceCheckFailure(description: "Unsupported fuzzy sentence remained for \(raw): \(candidates.prefix(5).map(\.text))")
                                }
                                guard let partial = candidates.first(where: { $0.text == sentence.pronoun }),
                                      let resolved = await lexicon.resolve(partial, for: raw, layout: .pinyin, script: script,
                                                                            pinyinPolicy: policy) else {
                                    throw RimeIceCheckFailure(description: "Missing selectable \(sentence.pronoun) in \(raw)")
                                }
                                var composition = Composition()
                                composition.append(raw)
                                let remaining = raw.contains("'") ? "bu'zao'shuo" : "buzaoshuo"
                                guard composition.commit(resolved) == sentence.pronoun, composition.input == remaining else {
                                    throw RimeIceCheckFailure(description: "Selecting \(sentence.pronoun) consumed the wrong part of \(raw)")
                                }
                            }
                        }
                    }
                }
                print("PASS \(script.rawValue): composed \(sentence.code) → \(target)")
            }
        }

        let soundPairs: [(PinyinFuzzyOptions, String, String, String)] = [
            (.zZh, "ni'bu'zao'shuo", "你不早说", "你不找说"),
            (.cCh, "ceshiliaotian", "测试聊天", "车是聊天"),
            (.sSh, "saodile", "扫地了", "少地了"),
            (.nL, "zhegelanle", "这个烂了", "这个男了"),
            (.fH, "kankanfangxue", "看看放学", "看看行学"),
            (.anAng, "qiangdaoma", "强盗吗", "前到吗"),
            (.enEng, "wo'men'gen'shang", "我们跟上", "我们更上"),
            (.inIng, "bucuxin", "不粗心", "不粗行"),
        ]
        for (options, raw, expected, unsupported) in soundPairs {
            let policy = PinyinQueryPolicy.configured(options)
            let candidates = try await lexicon.candidates(for: raw, layout: .pinyin, script: .simplified,
                                                         limit: 48, pinyinPolicy: policy)
            guard let first = candidates.first, first.text == expected,
                  !candidates.contains(where: { $0.text == unsupported }),
                  await lexicon.resolve(first, for: raw, layout: .pinyin, script: .simplified,
                                        pinyinPolicy: policy)?.consumed == raw.count else {
                throw RimeIceCheckFailure(description:
                    "Fuzzy option \(options.rawValue), \(raw): expected \(expected) without \(unsupported), got \(candidates.prefix(6).map(\.text))")
            }
            print("PASS fuzzy option \(options.rawValue): \(raw) → \(expected)")
        }

        let genuineFuzzy: [(String, String, PinyinQueryPolicy)] = [
            ("senglin", "森林", .configured(.all)),
            ("zongguo", "中国", .configured(.zZh)),
            ("zongguorenmin", "中国人民", .configured(.zZh)),
        ]
        for (raw, text, policy) in genuineFuzzy {
            let candidates = try await lexicon.candidates(for: raw, layout: .pinyin, script: .simplified,
                                                         limit: 48, pinyinPolicy: policy)
            guard let choice = candidates.first(where: { $0.text == text && $0.engineIndex != nil }),
                  await lexicon.resolve(choice, for: raw, layout: .pinyin, script: .simplified,
                                        pinyinPolicy: policy)?.consumed == raw.count else {
                throw RimeIceCheckFailure(description: "The configured fuzzy reading \(raw) no longer selects \(text)")
            }
        }

        let sentence = "nihaoshijie"
        let strict: PinyinQueryPolicy = .configured([])
        let candidates = try await lexicon.candidates(for: sentence, layout: .pinyin, script: .simplified,
                                                       limit: 48, pinyinPolicy: strict)
        guard let partial = candidates.first(where: { $0.text == "你" }),
              let resolved = await lexicon.resolve(partial, for: sentence, layout: .pinyin, script: .simplified,
                                                    pinyinPolicy: strict) else {
            throw RimeIceCheckFailure(description: "No selectable partial 你 in \(sentence)")
        }
        var composition = Composition()
        composition.append(sentence)
        guard composition.commit(resolved) == "你", composition.input == "haoshijie" else {
            throw RimeIceCheckFailure(description: "Partial selection did not preserve the remaining syllables")
        }
        let reading = "woyaofangxing"
        let fuzzy = PinyinQueryPolicy.configured(.all)
        let standardFirst = try await lexicon.candidates(for: reading, layout: .pinyin, script: .simplified,
                                                          limit: 48, pinyinPolicy: fuzzy)
        guard standardFirst.first?.text == "我要放行",
              !standardFirst.contains(where: { $0.text == "我要放心" }) else {
            throw RimeIceCheckFailure(description: "Expected 我要放行 without the competing fuzzy sentence 我要放心")
        }
        for policy in [PinyinQueryPolicy.configured([]), .configured(.all)] {
            let raw = "shoulianle"
            for limit in [1, 48] {
                let found = try await lexicon.candidates(for: raw, layout: .pinyin, script: .simplified,
                                                         limit: limit, pinyinPolicy: policy)
                guard let first = found.first, first.text == "收敛了",
                      await lexicon.resolve(first, for: raw, layout: .pinyin, script: .simplified,
                                            pinyinPolicy: policy)?.consumed == raw.count,
                      limit == 1 || found.dropFirst().contains(where: { $0.text == "受骗了" }) else {
                    throw RimeIceCheckFailure(description: "Expected 收敛了 before the neighbor-key correction: \(found.prefix(4).map(\.text))")
                }
            }
        }
        await lexicon.close()
        print("PASS: standard reading priority, intentional fuzzy match and partial selection")
    }
}
