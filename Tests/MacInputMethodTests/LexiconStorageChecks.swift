import Foundation
import KeyboardCore

@main struct LexiconStorageChecks {
    static func record(_ candidate: Candidate) -> [String: Any] {
        ["text": candidate.text, "reading": candidate.reading,
         "consumed": candidate.consumed, "engineIndex": candidate.engineIndex.map { $0 as Any } ?? NSNull()]
    }

    static func main() async throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let lexicon = try Lexicon(url: resources.appendingPathComponent("lexicon.sqlite"))
        var snapshot: [String: Any] = [:]
        let policies: [(String, PinyinQueryPolicy)] = [("legacy", .legacy), ("off", .configured([])), ("all", .configured(.all))]
        let codes = ["n", "ni", "nihao", "nh", "nhao", "nihap", "nihaoo", "shijie", "shi", "shiti",
                     "dise", "n'z'g's'g", "nihaoshijie", "zhezhenshirangninanguoya",
                     "senti", "senglin", "yinghang", "gangjing", "songchigan", "xianyanbao",
                     "pofang", "jiangejidan", "xinnengyuanqiche", "beijingshifandaxue", "pingoug", "zhonggou",
                     "ayii", "rengonzhineng"]
        for script in [ChineseScript.simplified, .traditional] {
            for (label, policy) in policies {
                for code in codes {
                    let found = try await lexicon.candidates(for: code, layout: .pinyin, script: script,
                                                            limit: 128, pinyinPolicy: policy)
                    snapshot["\(script.rawValue)|\(label)|\(code)"] = found.map(record)
                    var resolved: [[String: Any]] = []
                    for candidate in found.prefix(3) {
                        if let choice = await lexicon.resolve(candidate, for: code, layout: .pinyin,
                                                             script: script, pinyinPolicy: policy) {
                            resolved.append(record(choice))
                        }
                    }
                    snapshot["resolve|\(script.rawValue)|\(label)|\(code)"] = resolved
                }
            }
            for code in ["nihao", "n'z'g's'g", "shi", "zhezhenshirangrengaoxiao"] {
                snapshot["singles|\(script.rawValue)|\(code)"] = await lexicon.singleCandidateGroups(for: code, script: script).map {
                    ["label": $0.label, "correction": $0.isCorrection, "candidates": $0.candidates.map(record)] as [String: Any]
                }
            }
            for code in ["a", "onf", "zzzzz"] {
                snapshot["cangjie|\(script.rawValue)|\(code)"] = try await lexicon.candidates(for: code, layout: .cangjie, script: script).map(record)
            }
        }
        for code in ["app", "appli", "hello", "swift", "algorithm", "nihao"] {
            let words = await lexicon.englishWords(prefix: code)
            snapshot["english|\(code)"] = ["known": words.known, "completions": words.completions]
        }
        await lexicon.close()
        let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        print("Recorded \(snapshot.count) native lookup/selection results")
    }
}
