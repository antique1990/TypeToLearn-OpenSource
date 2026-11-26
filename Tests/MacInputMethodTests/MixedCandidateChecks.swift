import AppKit
import CoreText
import KeyboardCore

struct MixedCandidateFailure: Error { let message: String }

@main struct MixedCandidateChecks {
    @MainActor static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw MixedCandidateFailure(message: message) }
    }
    static func hasMissingGlyph(_ text: String) -> Bool {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text,
            attributes: [.font: NSFont.systemFont(ofSize: 16, weight: .regular)]))
        return (CTLineGetGlyphRuns(line) as! [CTRun]).contains { run in
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let font = attributes[kCTFontAttributeName] as! CTFont
            if CTFontCopyPostScriptName(font) as String == "LastResort" { return true }
            var glyphs = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            return glyphs.contains(0)
        }
    }
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let characterPolicy = try JSONSerialization.jsonObject(with: Data(contentsOf:
            root.appendingPathComponent("scripts/mac-common-character-policy.json"))) as! [String: Any]
        let protectedHan = Set((characterPolicy["protectedCharacters"] as! String).unicodeScalars)
        let hanRanges = characterPolicy["hanRanges"] as! [[UInt32]]
        func hasExcludedAdditiveHan(_ text: String) -> Bool {
            text.unicodeScalars.contains { scalar in
                !protectedHan.contains(scalar) && hanRanges.contains { $0[0] <= scalar.value && scalar.value <= $0[1] }
            }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mixed-candidates-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let resources = CommandLine.arguments.count > 2 ? URL(fileURLWithPath: CommandLine.arguments[2])
            : root.appendingPathComponent("Mac/DictionaryResources")
        let lexicon = try Lexicon(url: resources.appendingPathComponent("lexicon.sqlite"),
                                  learnedURL: directory.appendingPathComponent("learned.json"))
        for script in [ChineseScript.simplified, .traditional] {
            for raw in ["ang", "bai", "dia", "gao", "guan", "hao", "hua", "jiao", "kui", "liao", "luo", "mei",
                        "miao", "pei", "qiang", "qin", "qing", "sen", "shan", "shua", "sou", "xian", "yue", "zhou", "zhuang",
                        "xiao", "xiang"] {
                let base = try await lexicon.candidates(for: raw, layout: .pinyin, script: script,
                    limit: 48, pinyinPolicy: .configured([]))
                try require(!base.isEmpty, "Pinyin collision fixture has no Chinese candidates: \(raw)")
                var initial: [Candidate] = []
                var spellingRequests = 0
                let found = try await MacCandidateLookup.candidates(for: raw, layout: .pinyin, script: script,
                    englishMode: false, lexicon: lexicon, limit: 48, pinyinPolicy: .configured([]),
                    completionProvider: { _ in spellingRequests += 1; return [raw] },
                    onInitial: { initial = $0 })
                try require(initial == base && found == base,
                            "Unranked English homograph displaced Chinese Pinyin: \(script.rawValue) / \(raw) → \(found.prefix(3).map(\.text))")
                try require(spellingRequests == 0, "Pinyin was sent to spelling after deciding it is Chinese: \(raw)")
                if raw == "xian" { try require(found.contains { $0.text == "仙" }, "The Chinese 仙 candidate was lost") }
            }
        }
        for raw in ["can", "man", "fan", "sun", "long", "like", "you", "app", "aardwolf"] {
            let found = try await MacCandidateLookup.candidates(for: raw, layout: .pinyin, script: .simplified,
                englishMode: false, lexicon: lexicon, completionProvider: { _ in nil })
            try require(found.prefix(2).contains { $0.text == raw && $0.engineIndex == nil },
                        "Pinyin collision filtering removed a genuine English word: \(raw)")
        }
        for spelling in ["xian", "Xian", "XIAN"] {
            let english = try await MacCandidateLookup.candidates(for: "xian", layout: .pinyin, script: .simplified,
                englishMode: true, lexicon: lexicon, displayInput: spelling, completionProvider: { _ in [] })
            try require(english.first?.text == spelling && english.first?.consumed == 4,
                        "Explicit English mode must preserve raw spelling: \(spelling)")
            if spelling != "xian" {
                let explicit = try await MacCandidateLookup.candidates(for: "xian", layout: .pinyin, script: .simplified,
                    englishMode: false, lexicon: lexicon, displayInput: spelling, completionProvider: { _ in [] })
                try require(explicit.prefix(2).contains { $0.text == spelling }, "Explicit capitals were discarded")
            }
        }
        print("PASS: 54 Pinyin/English homograph cases, genuine English, capitals and English-mode preservation")
        for script in [ChineseScript.simplified, .traditional] {
            let found = try await MacCandidateLookup.candidates(for: "bushi", layout: .pinyin, script: script,
                englishMode: false, lexicon: lexicon, completionProvider: { _ in ["Bushings"] })
            try require(found.prefix(2).map(\.text) == ["不是", "Bushings"],
                        "English prefix displaced an exact Chinese phrase: \(found.prefix(3).map(\.text))")
        }
        var initialShorthand: [Candidate] = []
        let shorthand = try await MacCandidateLookup.candidates(for: "weism", layout: .pinyin, script: .simplified,
            englishMode: false, lexicon: lexicon, pinyinPolicy: .configured(.all),
            completionProvider: { _ in ["Weismann"] }, onInitial: { initialShorthand = $0 })
        try require(initialShorthand.first?.text == "为什么" && shorthand.first?.text == "为什么",
                    "English prefix displaced the complete Chinese shorthand: \(shorthand.prefix(3).map(\.text))")
        try require(shorthand.dropFirst().first?.text.lowercased() == "weismann",
                    "English prefix was removed from mixed lookup")
        for spelling in ["hello", "swift", "iPhone"] {
            let raw = spelling.lowercased()
            let candidates = try await MacCandidateLookup.candidates(for: raw, layout: .pinyin, script: .simplified,
                englishMode: false, lexicon: lexicon, displayInput: spelling)
            let match = candidates.first { $0.text == spelling }
            try require(match != nil, "English candidate absent in Chinese mode: \(spelling)")
            try require(match?.consumed == raw.count && match?.engineIndex == nil, "English candidate has invalid consumption")
            try require(candidates.prefix(2).contains { $0.text == spelling }, "Mixed English candidate is buried after Chinese")
            print("Chinese-mode English", spelling, "→", candidates.prefix(3).map(\.text))
        }
        let base = try await lexicon.candidates(for: "nihao", layout: .pinyin, script: .simplified)
        let chinese = try await MacCandidateLookup.candidates(for: "nihao", layout: .pinyin, script: .simplified,
            englishMode: false, lexicon: lexicon)
        try require(chinese == base, "Pure Pinyin changed or its Rime identity was lost")
        try require(chinese.first?.text == "你好", "Pinyin lost its first Chinese candidate")
        for unavailable in [true, false] {
            var requests = 0
            let noEvidence = try await MacCandidateLookup.candidates(for: "nihao", layout: .pinyin, script: .simplified,
                englishMode: false, lexicon: lexicon, completionProvider: { _ in
                    requests += 1
                    return unavailable ? nil : []
                })
            try require(noEvidence == base, "Unavailable/empty spelling service treated Pinyin as English")
            try require(requests == 1, "Mixed lookup issued additional spelling probes")
        }
        var knownRequests = 0
        let offlineHello = try await MacCandidateLookup.candidates(for: "hello", layout: .pinyin, script: .simplified,
            englishMode: false, lexicon: lexicon, completionProvider: { _ in knownRequests += 1; return nil })
        try require(offlineHello.contains { $0.text == "hello" }, "Offline English missing when spelling service unavailable")
        try require(knownRequests == 0, "Known offline word unnecessarily queried spelling service")
        let unavailableBrand = try await MacCandidateLookup.candidates(for: "iphone", layout: .pinyin, script: .simplified,
            englishMode: false, lexicon: lexicon, displayInput: "iPhone", completionProvider: { _ in nil })
        try require(unavailableBrand.contains { $0.text == "iPhone" }, "Explicit internal capitals lost during service failure")
        for raw in ["iphone", "ipad"] {
            let found = try await MacCandidateLookup.candidates(for: raw, layout: .pinyin, script: .simplified,
                englishMode: false, lexicon: lexicon, pinyinPolicy: .configured(.all), completionProvider: { _ in nil })
            try require(found.map(\.text) == [raw], "An offline English word reached Pinyin correction: \(raw)")
        }
        let positiveBrand = try await MacCandidateLookup.candidates(for: "iphone", layout: .pinyin, script: .simplified,
            englishMode: false, lexicon: lexicon, completionProvider: { prefix in
                prefix == "iphon" ? ["iPhone", "iPhones"] : nil
            })
        try require(positiveBrand.contains { $0.text == "iphone" }, "Positive completion evidence lost original spelling")
        let combined = try await MacCandidateLookup.candidates(for: "nihaohello", layout: .pinyin, script: .simplified,
            englishMode: false, lexicon: lexicon)
        let combinedUnavailable = try await MacCandidateLookup.candidates(for: "nihaohello", layout: .pinyin, script: .simplified,
            englishMode: false, lexicon: lexicon, completionProvider: { _ in nil })
        try require(combinedUnavailable == combined, "Spelling failure changed mixed Pinyin/English composition candidates")
        guard let prefix = combined.first(where: { $0.text == "你好" }),
              let resolved = await lexicon.resolve(prefix, for: "nihaohello", layout: .pinyin, script: .simplified)
        else { throw MixedCandidateFailure(message: "Chinese prefix missing from mixed Pinyin/English composition") }
        var composition = Composition()
        composition.append("nihaohello")
        try require(composition.commit(resolved) == "你好" && composition.input == "hello",
                    "Chinese prefix selection consumed the pending English suffix")
        let remainder = try await MacCandidateLookup.candidates(for: composition.input, layout: .pinyin, script: .simplified,
            englishMode: false, lexicon: lexicon)
        try require(remainder.contains { $0.text == "hello" && $0.consumed == 5 }, "English suffix not selectable after Chinese")
        let short = try await MacCandidateLookup.candidates(for: "ni", layout: .pinyin, script: .simplified,
            englishMode: false, lexicon: lexicon)
        try require(short.allSatisfy { !$0.text.unicodeScalars.allSatisfy(\.isASCII) }, "Short Pinyin crowded by English")
        var shortRequests = 0
        let shortUnavailable = try await MacCandidateLookup.candidates(for: "ni", layout: .pinyin, script: .simplified,
            englishMode: false, lexicon: lexicon, completionProvider: { _ in shortRequests += 1; return nil })
        try require(shortUnavailable == short && shortRequests == 0, "Short Pinyin used unavailable spelling service")
        let completion = try await MacCandidateLookup.candidates(for: "appli", layout: .pinyin, script: .simplified,
            englishMode: false, lexicon: lexicon)
        try require(completion.prefix(2).contains { $0.text.lowercased().hasPrefix("appli") && $0.text.count > 5 }, "English prefix completion missing")
        try await lexicon.learn(code: "dise", text: "底色", layout: .pinyin, script: .simplified)
        let learned = try await MacCandidateLookup.candidates(for: "dise", layout: .pinyin, script: .simplified,
            englishMode: false, lexicon: lexicon)
        try require(learned.first?.text == "底色", "English completion displaced learned Chinese")
        try require(learned.count >= 2 && learned[1].text.lowercased().hasPrefix("dise"), "Expected English after learned phrase")
        let english = try await MacCandidateLookup.candidates(for: "hello", layout: .pinyin, script: .simplified,
            englishMode: true, lexicon: lexicon, displayInput: "Hello")
        try require(english.first?.text == "Hello", "Explicit English mode lost original spelling")
        let initial = try await MacCandidateLookup.candidates(for: "i", layout: .pinyin, script: .simplified,
            englishMode: false, lexicon: lexicon)
        try require(initial.contains { $0.text == "I" }, "Shared I special-case missing")
        let cangjieBase = try await lexicon.candidates(for: "hello", layout: .cangjie, script: .simplified)
        let cangjie = try await MacCandidateLookup.candidates(for: "hello", layout: .cangjie, script: .simplified,
            englishMode: false, lexicon: lexicon)
        try require(cangjie == cangjieBase, "Pinyin-only mixed policy changed Cangjie")
        for script in [ChineseScript.simplified, .traditional] {
            let words = script == .simplified ? ["尸体", "实体", "试题", "诗体", "事体", "失蹄", "石梯"]
                : ["屍體", "實體", "試題", "詩體", "事體", "失蹄", "石梯"]
            let found = try await MacCandidateLookup.candidates(for: "shiti", layout: .pinyin, script: script,
                englishMode: false, lexicon: lexicon, limit: 128, pinyinPolicy: .configured(.all),
                completionProvider: { _ in nil })
            guard let firstSingle = found.firstIndex(where: { $0.text.count == 1 }) else {
                throw MixedCandidateFailure(message: "Complete words removed partial single-character choices")
            }
            for word in words {
                guard let index = found.firstIndex(where: { $0.text == word }) else {
                    throw MixedCandidateFailure(message: "Complete homophone missing: \(word)")
                }
                try require(index < firstSingle, "Complete homophone \(word) was pushed behind singles")
            }
            let long = try await MacCandidateLookup.candidates(for: "nihaoshijie", layout: .pinyin, script: script,
                englishMode: false, lexicon: lexicon, limit: 48, pinyinPolicy: .configured(.all),
                completionProvider: { _ in nil })
            try require(long.first?.text == "你好世界", "Full sentence lost its leading position")
            try require(long.prefix(12).contains { $0.text == "你" }, "Full sentence buried its single-character fallback")
            guard let prefix = long.first(where: { $0.text == "你好" }),
                  let resolved = await lexicon.resolve(prefix, for: "nihaoshijie", layout: .pinyin,
                                                       script: script, pinyinPolicy: .configured(.all)) else {
                throw MixedCandidateFailure(message: "Partial phrase is no longer selectable")
            }
            try require(resolved.consumed == 5, "Phrase ranking changed partial selection consumption")
            print("Complete-first", script.rawValue, found.prefix(16).map(\.text))
        }
        for script in [ChineseScript.simplified, .traditional] {
            for raw in ["nihaiburuxianxuehuizimeiti", "shi", "ai"] {
                let unfiltered = try await lexicon.candidates(for: raw, layout: .pinyin, script: script,
                    limit: 4096, pinyinPolicy: .configured(.all))
                let expected = unfiltered.filter { !hasMissingGlyph($0.text) }
                try require(!expected.isEmpty, "Glyph fixture has no usable candidates")
                var previous: [Candidate] = []
                for limit in [48, 240, 288, 432, 720, 2048] {
                    let usable = try await MacCandidateLookup.candidates(for: raw, layout: .pinyin, script: script,
                        englishMode: false, lexicon: lexicon, limit: limit, pinyinPolicy: .configured(.all),
                        completionProvider: { _ in nil })
                    try require(!usable.contains { hasMissingGlyph($0.text) },
                                "Deep candidate page contains a missing-glyph question box: \(script) / \(raw) / \(limit)")
                    try require(!usable.contains { hasExcludedAdditiveHan($0.text) },
                                "Full character audit: nonstandard additive Han remains in \(script) / \(raw) / \(limit)")
                    try require(usable == Array(expected.prefix(limit)),
                                "Glyph filtering lost supported choices, engine identity or page continuation: \(raw) / \(limit); first mismatch \(zip(usable, expected).first { $0 != $1 }.map { String(describing: $0) } ?? "count mismatch")")
                    try require(Array(usable.prefix(previous.count)) == previous, "Candidate continuation changed prior pages")
                    previous = usable
                }
                let supplemental = expected.filter { $0.text.unicodeScalars.contains { $0.value > 0xFFFF } }
                try require(supplemental.allSatisfy { previous.contains($0) }, "Supported supplementary Han characters were removed")
                if let afterGap = expected.first(where: { candidate in
                    guard let index = unfiltered.firstIndex(of: candidate) else { return false }
                    return unfiltered.prefix(index).contains { hasMissingGlyph($0.text) }
                }) {
                    let original = await lexicon.resolve(afterGap, for: raw, layout: .pinyin, script: script,
                                                        pinyinPolicy: .configured(.all))
                    guard let displayed = previous.first(where: { $0 == afterGap }) else {
                        throw MixedCandidateFailure(message: "Candidate after missing-glyph gap was not reachable")
                    }
                    let chosen = await lexicon.resolve(displayed, for: raw, layout: .pinyin, script: script,
                                                      pinyinPolicy: .configured(.all))
                    try require(chosen != nil && chosen == original, "Filtering changed selected candidate consumption")
                }
                print("Glyph pages", script.rawValue, raw, unfiltered.count, "→", expected.count)
            }
        }
        let exclusionsURL = root.appendingPathComponent("scripts/mac-candidate-exclusions.json")
        let exclusionProfile = try JSONSerialization.jsonObject(with: Data(contentsOf: exclusionsURL)) as! [String: Any]
        let excluded = Set((exclusionProfile["characters"] as! String).unicodeScalars)
        for script in [ChineseScript.simplified, .traditional] {
            let remaining = try await lexicon.candidates(for: "weism", layout: .pinyin, script: script,
                limit: 4096, pinyinPolicy: .configured(.all))
            try require(!remaining.contains { $0.text.unicodeScalars.contains { excluded.contains($0) } },
                        "User-excluded weism supplementary characters remain in native candidates: \(script.rawValue)")
            try require(!remaining.contains { hasExcludedAdditiveHan($0.text) },
                        "Full character audit: nonstandard additive Han remains in weism / \(script.rawValue)")
            for word in ["微", "伟", "位"] where script == .simplified {
                try require(remaining.contains { $0.text == word }, "Common weism character was removed: \(word)")
            }
            print("Cleaned weism", script.rawValue, remaining.count, "candidates")
        }
        await lexicon.close()
        print("PASS: native AppKit + offline lexicon mixed-input checks")
    }
}
