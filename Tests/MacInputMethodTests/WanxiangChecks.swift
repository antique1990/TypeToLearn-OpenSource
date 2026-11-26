import Foundation
import KeyboardCore

private struct Probe: Decodable {
    let code: String
    let simplified: String
    let traditional: String
    let source: String
}
private struct Failure: Error { let message: String }

@main struct WanxiangChecks {
    static func main() async throws {
        let data = URL(fileURLWithPath: CommandLine.arguments[1])
        let probes = try JSONDecoder().decode([Probe].self, from: Data(contentsOf:
            URL(fileURLWithPath: CommandLine.arguments[2])))
        let learned = FileManager.default.temporaryDirectory.appendingPathComponent("wanxiang-learned-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: learned) }
        let lexicon = try Lexicon(url: data.appendingPathComponent("lexicon.sqlite"), learnedURL: learned)
        for script in [ChineseScript.simplified, .traditional] {
            for probe in probes {
                let target = script == .simplified ? probe.simplified : probe.traditional
                let result = try await lexicon.candidates(for: probe.code, layout: .pinyin, script: script,
                    limit: probe.source == "protected-character" ? 2048 : 128, pinyinPolicy: .configured([]))
                guard let candidate = result.first(where: { $0.text == target }) else {
                    throw Failure(message: "\(probe.source): missing \(probe.code) → \(target); \(result.prefix(8).map(\.text))")
                }
                let resolved = await lexicon.resolve(candidate, for: probe.code, layout: .pinyin, script: script,
                                                      pinyinPolicy: .configured([]))
                guard resolved?.consumed == probe.code.count else {
                    throw Failure(message: "Incorrect consumption for \(target)")
                }
                print("PASS \(script.rawValue) \(probe.source): \(probe.code) → \(target)")
            }
        }
        for word in ["algorithm", "application", "hello"] {
            guard await lexicon.englishWords(prefix: word).known else {
                throw Failure(message: "Offline English word missing: \(word)")
            }
        }
        let fuzzy = try await lexicon.candidates(for: "senglin", layout: .pinyin, script: .simplified,
            limit: 128, pinyinPolicy: .configured(.all))
        guard fuzzy.contains(where: { $0.text == "森林" }) else { throw Failure(message: "Fuzzy deployment failed") }
        let base = try await lexicon.candidates(for: "nihaoshijie", layout: .pinyin, script: .simplified,
            limit: 128, pinyinPolicy: .configured([]))
        guard let single = base.first(where: { $0.text == "你" }),
              let resolved = await lexicon.resolve(single, for: "nihaoshijie", layout: .pinyin, script: .simplified,
                                                  pinyinPolicy: .configured([])), resolved.consumed == 2 else {
            throw Failure(message: "Single-character partial selection lost")
        }
        try await lexicon.learn(code: "wxciku", text: "万象词库", layout: .pinyin, script: .simplified)
        let learnedResult = try await lexicon.candidates(for: "wxciku", layout: .pinyin, script: .simplified)
        guard learnedResult.first?.text == "万象词库" else { throw Failure(message: "Personal dictionary lost") }
        let start = ContinuousClock.now
        for code in ["nihao", "songchigan", "xianyanbao", "rengongzhineng", "nihaoshijie"] {
            _ = try await lexicon.candidates(for: code, layout: .pinyin, script: .simplified,
                pinyinPolicy: .configured(.all))
        }
        print("Five warm queries: \(start.duration(to: .now))")
        await lexicon.close()
        print("PASS: Mac Wanxiang real Rime queries, selection, fuzzy rules, English and learning")
    }
}
