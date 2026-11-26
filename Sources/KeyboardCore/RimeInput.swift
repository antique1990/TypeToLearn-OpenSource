import Foundation
import CRimeBridge

/// One actor owns librime's process-wide state and native result buffers.
actor RimeInput {
    static let shared = RimeInput()
    private var initialized = false
    private var sourceDirectory: URL?
    private var workDirectory: URL?
    private var deployedSchemas: Set<String> = []

    private func prepare(data: URL) throws {
        guard !initialized else { return }
        guard FileManager.default.fileExists(atPath: data.appendingPathComponent("build/learn_pinyin_hans.schema.yaml").path) else {
            throw LexiconError.unavailable
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("learnkeyboard-rime-\(ProcessInfo.processInfo.processIdentifier)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        guard lk_rime_initialize(data.path, work.path) != 0 else { throw LexiconError.unavailable }
        sourceDirectory = data
        workDirectory = work
        initialized = true
    }

    private func schema(_ layout: KeyboardLayout, _ script: ChineseScript) -> String {
        "learn_\(layout == .nineKey ? "nine" : "pinyin")_\(script == .simplified ? "hans" : "hant")"
    }

    private func querySchema(_ layout: KeyboardLayout, _ script: ChineseScript,
                             policy: PinyinQueryPolicy, completeSyllables: Bool = false) throws -> String {
        let base = schema(layout, script)
        if !completeSyllables, case .mobile(let fuzzy) = policy {
            return fuzzy ? "\(base)_fuzzy" : base
        }
        let options = policy.fuzzyOptions ?? []
        guard layout == .pinyin, completeSyllables || !options.isEmpty else { return base }
        guard let sourceDirectory, let workDirectory else { throw LexiconError.unavailable }
        // The work directory is process-specific; a bundle update starts a new
        // process/cache. Increment the version when changing spelling rules.
        let identifier = completeSyllables ? "\(base)_complete" : "\(base)_fuzzy_v2_\(options.rawValue)"
        if completeSyllables, FileManager.default.fileExists(
            atPath: sourceDirectory.appendingPathComponent("build/\(identifier).schema.yaml").path) { return identifier }
        let built = workDirectory.appendingPathComponent("build/\(identifier).prism.bin")
        let configuration = workDirectory.appendingPathComponent("build/\(identifier).schema.yaml")
        // macOS can clean old temporary YAML while the memory-mapped prism
        // remains. A prism alone is not a usable deployed schema.
        if deployedSchemas.contains(identifier),
           FileManager.default.fileExists(atPath: built.path),
           FileManager.default.fileExists(atPath: configuration.path) { return identifier }
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let url = sourceDirectory.appendingPathComponent("build/\(base).schema.yaml")
        var content = try String(contentsOf: url, encoding: .utf8)
        // Drop build timestamps for the bundled base schema. The deployer writes
        // fresh metadata for this independently named schema.
        content = content.replacingOccurrences(of: "(?m)^__build_info:\\n(?:[ \\t].*\\n)*", with: "", options: .regularExpression)
        func replaceOne(_ pattern: String, with value: String) throws {
            let regex = try NSRegularExpression(pattern: pattern, options: .anchorsMatchLines)
            let range = NSRange(content.startIndex..<content.endIndex, in: content)
            guard regex.numberOfMatches(in: content, range: range) == 1 else { throw LexiconError.unavailable }
            // Literal replacement avoids interpreting the $1 inside Rime rules.
            guard let match = regex.firstMatch(in: content, range: range), let swiftRange = Range(match.range, in: content) else {
                throw LexiconError.unavailable
            }
            content.replaceSubrange(swiftRange, with: value)
        }
        try replaceOne("^  schema_id: \(base)$", with: "  schema_id: \(identifier)")
        try replaceOne("^  prism: \(base)$", with: "  prism: \(identifier)")
        // Preserve the two standard abbreviation rules at the beginning of the
        // bundled algebra. Deriving these after sound aliases would mix lq/nq.
        let abbreviationRules = ["derive/^([a-z]).+$/$1/", "derive/^([zcs]h).+$/$1/"]
        let algebraPrefix = "  algebra:\n" + abbreviationRules.map { "    - \"\($0)\"\n" }.joined()
        let algebra = completeSyllables ? algebraPrefix.replacingOccurrences(of: "derive/", with: "abbrev/")
            : algebraPrefix + options.algebra.map { "    - \"\($0)\"\n" }.joined()
        try replaceOne("^" + NSRegularExpression.escapedPattern(for: algebraPrefix), with: algebra)
        let source = workDirectory.appendingPathComponent("\(identifier).schema.yaml")
        try content.write(to: source, atomically: true, encoding: .utf8)
        guard lk_rime_deploy_schema(source.path) != 0, FileManager.default.fileExists(atPath: built.path),
              FileManager.default.fileExists(atPath: configuration.path) else {
            throw LexiconError.unavailable
        }
        deployedSchemas.insert(identifier)
        return identifier
    }

    func candidates(raw: String, layout: KeyboardLayout, script: ChineseScript, data: URL, limit: Int,
                    pinyinPolicy: PinyinQueryPolicy = .legacy, singlesOnly: Bool = false,
                    classifyCoverage: Bool = false, completeSyllables: Bool = false) throws -> [Candidate] {
        try Task.checkCancellation()
        try prepare(data: data)
        let selectedSchema = try querySchema(layout, script, policy: pinyinPolicy, completeSyllables: completeSyllables)
        try Task.checkCancellation()
        defer { lk_rime_release_results() }
        var output: [Candidate] = []
        var seen = Set<String>()
        var offset: Int32 = 0
        let classify: Bool
        if layout == .pinyin, case .configured = pinyinPolicy { classify = true }
        else { classify = classifyCoverage }
        repeat {
            try Task.checkCancellation()
            let batch = Int32(max(1, min(limit - output.count, 64)))
            let count: Int32
            if singlesOnly { count = lk_rime_query_singles(selectedSchema, raw, batch) }
            else if classify { count = lk_rime_query_ranked_page(selectedSchema, raw, offset, batch) }
            else { count = lk_rime_query_page(selectedSchema, raw, offset, batch) }
            guard count >= 0 else { throw LexiconError.unavailable }
            for item in 0..<count {
                guard let pointer = lk_rime_text(item) else { continue }
                let text = String(cString: pointer)
                guard seen.insert(text).inserted else { continue }
                var candidate = Candidate(text: text, reading: raw, consumed: 0, engineIndex: Int(lk_rime_index(item)))
                let coverage = lk_rime_covers_input(item)
                if coverage >= 0 { candidate.coversFullInput = coverage == 1 }
                output.append(candidate)
            }
            let next = lk_rime_next_index()
            if singlesOnly || next <= offset { break }
            offset = next
        } while output.count < limit
        return output
    }

    func firstPinyinReading(raw: String, script: ChineseScript, data: URL,
                            policy: PinyinQueryPolicy = .legacy) throws -> [Substring]? {
        try Task.checkCancellation()
        try prepare(data: data)
        let selected = try querySchema(.pinyin, script, policy: policy)
        var buffer = [CChar](repeating: 0, count: Composition.maximumLength * 2 + 1)
        guard lk_rime_first_reading(selected, raw, &buffer, Int32(buffer.count)) != 0 else { return nil }
        let reading = String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return reading.split { $0 == " " || $0 == "'" }
    }

    func completeSyllableConversion(raw: String, canonical: [String], script: ChineseScript,
                                    data: URL) throws -> Candidate? {
        // Genuine shorthand and unfinished input have no complete canonical reading.
        guard let native = try firstPinyinReading(raw: raw, script: script, data: data),
              native.count > canonical.count, native.contains(where: PinyinTolerance.isInitial) else { return nil }
        let spelling = canonical.joined(separator: "'")
        let found = try candidates(raw: spelling, layout: .pinyin, script: script, data: data, limit: 1,
                                   classifyCoverage: true, completeSyllables: true)
        guard let match = found.first, match.coversFullInput == true else { return nil }
        return Candidate(text: match.text, reading: raw, consumed: raw.count)
    }

    func coversFullPinyinInput(_ candidate: Candidate, raw: String, script: ChineseScript, data: URL,
                              policy: PinyinQueryPolicy) throws -> Bool {
        try Task.checkCancellation()
        try prepare(data: data)
        guard let index = candidate.engineIndex else { return candidate.consumed == raw.count }
        let selected = try querySchema(.pinyin, script, policy: policy)
        return lk_rime_candidate_covers_input(selected, raw, Int32(index), candidate.text) == 1
    }

    func resolve(_ candidate: Candidate, raw: String, layout: KeyboardLayout, script: ChineseScript, data: URL,
                 pinyinPolicy: PinyinQueryPolicy = .legacy) throws -> Candidate? {
        try Task.checkCancellation()
        try prepare(data: data)
        guard let index = candidate.engineIndex else { return candidate }
        let selectedSchema = try querySchema(layout, script, policy: pinyinPolicy)
        try Task.checkCancellation()
        let consumed = Int(lk_rime_consumed(selectedSchema, raw, Int32(index), candidate.text))
        guard consumed > 0, consumed <= raw.count else { return nil }
        return Candidate(text: candidate.text, reading: candidate.reading, consumed: consumed)
    }
}
