import Foundation
import SQLite3

public enum LexiconError: Error, LocalizedError {
    case unavailable
    public var errorDescription: String? { "输入词库无法打开，请重新安装应用。" }
}

public struct SingleCandidateGroup: Sendable {
    public let label: String
    public let candidates: [Candidate]
    public let isCorrection: Bool

    public init(label: String, candidates: [Candidate], isCorrection: Bool = false) {
        self.label = label
        self.candidates = candidates
        self.isCorrection = isCorrection
    }
}

/// Actor confines SQLite to one executor; the keyboard never queries on its UI thread.
public actor Lexicon {
    private let rimeData: URL
    private let learnedURL: URL?
    private let connection: SQLiteConnection
    private let compactPhraseStorage: Bool
    private var phraseTable: String { compactPhraseStorage ? "pinyin_phrases" : "pinyin" }
    private var handle: OpaquePointer? { connection.handle }
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private lazy var pinyinSyllables = Set(query("""
        SELECT DISTINCT code, code, code FROM pinyin
        WHERE length(code) BETWEEN 1 AND 6 AND length(simplified) = 1 LIMIT ?
        """, values: [], limit: 1024).map(\.0))
    private var desktopSyllables: [PinyinFuzzyOptions: Set<String>] = [:]
    private var fuzzySyllableAliases: [PinyinFuzzyOptions: [String: Set<String>]] = [:]
    private lazy var mobileStrictSyllables = PinyinTolerance.acceptedSyllables(from: pinyinSyllables, fuzzy: false)
    private lazy var mobileFuzzySyllables = PinyinTolerance.acceptedSyllables(from: pinyinSyllables, fuzzy: true)

    public init(url: URL, learnedURL: URL? = nil) throws {
        rimeData = url.deletingLastPathComponent().appendingPathComponent("RimeData")
        self.learnedURL = learnedURL
        let opened = try SQLiteConnection(url: url)
        var statement: OpaquePointer?
        compactPhraseStorage = sqlite3_prepare_v2(opened.handle, "SELECT 1 FROM pinyin_phrases LIMIT 1", -1,
                                                 &statement, nil) == SQLITE_OK
        sqlite3_finalize(statement)
        connection = opened
    }

    public func close() { connection.close() }

    public func hasExactPinyinReading(_ code: String, script: ChineseScript) -> Bool {
        guard handle != nil else { return false }
        let column = script == .simplified ? "simplified" : "traditional"
        let hasReading = !query("SELECT code, code, code FROM pinyin WHERE code = ? AND length(\(column)) > 0 LIMIT ?",
                                values: [code], limit: 1).isEmpty
        return hasReading || (compactPhraseStorage && hasExactPinyinPhrase(code: code, script: script))
    }

    /// Dictionary presence alone is weak English evidence: WordNet also lists
    /// transliterations such as xian. A complete single-character reading wins
    /// unless the English entry has a nonzero usage/ranking hint. This is query
    /// evidence only; callers decide how explicit English mode/case overrides it.
    public func prefersPinyin(overEnglish word: String) -> Bool {
        guard handle != nil, (3...32).contains(word.count),
              word.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.letters.contains($0) }) else { return false }
        let lower = word.lowercased()
        return !query("""
            SELECT code, code, code FROM pinyin
            WHERE code = ? AND (length(simplified) = 1 OR length(traditional) = 1)
              AND NOT EXISTS (SELECT 1 FROM english WHERE word = ? AND weight > 0)
            LIMIT ?
            """, values: [lower, lower], limit: 1).isEmpty
    }

    /// WordNet words supplement UIKit completions without assigning made-up
    /// corpus frequencies to rare dictionary entries.
    public func englishWords(prefix: String, limit: Int = 12) -> (known: Bool, completions: [String]) {
        guard handle != nil, (2...32).contains(prefix.count),
              prefix.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.letters.contains($0) }) else {
            return (false, [])
        }
        let lower = prefix.lowercased()
        var exact: OpaquePointer?
        var known = false
        if sqlite3_prepare_v2(handle, "SELECT 1 FROM english WHERE word = ?", -1, &exact, nil) == SQLITE_OK {
            sqlite3_bind_text(exact, 1, lower, -1, transient)
            known = sqlite3_step(exact) == SQLITE_ROW
        }
        sqlite3_finalize(exact)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT word, weight FROM english WHERE word >= ? AND word < ? ORDER BY weight DESC, word LIMIT ?", -1, &statement, nil) == SQLITE_OK else {
            return (false, [])
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, lower, -1, transient)
        sqlite3_bind_text(statement, 2, lower + "{", -1, transient)
        sqlite3_bind_int(statement, 3, Int32(limit + 1))
        var words: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let word = String(cString: sqlite3_column_text(statement, 0))
            if word != lower && words.count < limit { words.append(word) }
        }
        return (known, words)
    }

    /// Display the most likely letters for a nine-key code while preserving the
    /// numeric code internally for candidate selection.
    public func nineKeyPreedit(for digits: String, preferred text: String?, script: ChineseScript) -> String? {
        guard handle != nil, !digits.isEmpty, digits.allSatisfy({ "23456789".contains($0) }) else { return nil }
        let column = script == .simplified ? "simplified" : "traditional"
        let lower = digits
        let upper = digits + ":"
        var rows: [(String, String, String)] = []
        if let text, !text.isEmpty {
            rows = query("SELECT code, roman, digits FROM pinyin WHERE digits >= ? AND digits < ? AND \(column) = ? ORDER BY weight DESC LIMIT ?",
                         values: [lower, upper, text], limit: 16)
        }
        if rows.isEmpty {
            rows = query("SELECT code, roman, digits FROM pinyin WHERE digits >= ? AND digits < ? ORDER BY weight DESC LIMIT ?",
                         values: [lower, upper], limit: 16)
        }
        guard let code = rows.first(where: { $0.0.count >= digits.count })?.0 else { return nil }
        let display = String(code.prefix(digits.count))
        return KeyCoding.nineKey(display) == digits ? display : nil
    }

    public func candidates(for raw: String, layout: KeyboardLayout, script: ChineseScript, limit: Int? = nil,
                           pinyinPolicy: PinyinQueryPolicy = .legacy) async throws -> [Candidate] {
        guard handle != nil, !raw.isEmpty, raw.count <= Composition.maximumLength,
              (limit ?? 1) > 0 else { return [] }
        let requestedLimit = limit ?? 48
        if layout != .cangjie {
            let firstSegment: String? = if layout != .pinyin {
                nil
            } else if raw.contains("'") {
                raw.split(separator: "'", omittingEmptySubsequences: true).first.map(String.init)
            } else if raw.count >= 2, !hasPinyinSyllable(startingWith: String(raw.prefix(2)), script: script) {
                String(raw.prefix(1))
            } else {
                nil
            }
            let initials = layout == .pinyin && !raw.contains("'") && firstSegment?.count == 1
            let canCorrectPinyin = layout == .pinyin &&
                !hasExactPinyinReading(raw.replacingOccurrences(of: "'", with: ""), script: script)
            let sentenceRepairs: [Candidate]
            if canCorrectPinyin, case .mobile(let fuzzy) = pinyinPolicy {
                sentenceRepairs = try await mobileSentenceRepairs(for: raw, script: script, fuzzy: fuzzy)
            } else {
                sentenceRepairs = []
            }
            // A verified, unambiguous repair is the basis for whole-input
            // candidates. Still offer native prefix and single-character choices.
            let useRepairedFullInput = firstSegment?.count != 1 && Set(sentenceRepairs.map(\.reading)).count == 1
            var base = try await RimeInput.shared.candidates(raw: raw, layout: layout, script: script,
                data: rimeData, limit: initials && limit == nil ? 64 : requestedLimit,
                pinyinPolicy: pinyinPolicy, classifyCoverage: useRepairedFullInput)
            if useRepairedFullInput { base.removeAll { $0.coversFullInput == true } }

            func insertingSentenceRepairs(in candidates: [Candidate]) -> [Candidate] {
                guard !sentenceRepairs.isEmpty else { return candidates }
                // Preserve a native shorthand phrase ahead of speculative repairs.
                let hasShorthandPhrase = initials && (candidates.first?.text.count ?? 0) > 1
                let ambiguous = Set(sentenceRepairs.map(\.reading)).count > 1
                let leading = candidates.prefix(hasShorthandPhrase || ambiguous ? 1 : 0)
                let new = sentenceRepairs.filter { repair in !leading.contains { $0.text == repair.text } }
                let repaired = Set(new.map(\.text))
                return Array(leading) + new + candidates.dropFirst(leading.count).filter { !repaired.contains($0.text) }
            }
            if initials, let firstSegment {
                let learned = learnedURL.map { LearnedWords.load(from: $0).candidates(for: raw, layout: layout,
                    script: script, pinyinPolicy: pinyinPolicy) } ?? []
                let phrases = learned + base.filter { candidate in
                    candidate.text.count > 1 &&
                    !learned.contains { $0.text == candidate.text && $0.consumed == candidate.consumed }
                }
                let singles = try await initialSingles(for: firstSegment, raw: raw, script: script, pinyinPolicy: pinyinPolicy)
                let ordered: [Candidate]
                if case .configured = pinyinPolicy {
                    let complete = phrases.filter { $0.coversFullInput == true }
                    ordered = learned + complete + singles + phrases.filter {
                        $0.coversFullInput != true && !learned.contains($0)
                    }
                } else {
                    ordered = phrases.filter { $0.text.count > 3 } +
                        phrases.filter { $0.text.count == 3 } +
                        phrases.filter { $0.text.count == 2 } + singles +
                        phrases.filter { $0.text.count == 1 }
                }
                let corrected = if canCorrectPinyin {
                    try await desktopCorrections(ordered, raw: raw, script: script,
                        limit: requestedLimit, policy: pinyinPolicy, preserveShorthand: true)
                } else { ordered }
                let repaired = insertingSentenceRepairs(in: corrected)
                return limit.map { Array(repaired.prefix($0)) } ?? repaired
            }
            if layout == .pinyin, raw.count >= 3 || firstSegment != nil {
                // Native coverage distinguishes full-input words from prefix
                // conversions without selecting/committing every candidate.
                let phrases = base.filter { $0.text.count > 1 }
                let singles = base.filter { $0.text.count == 1 }
                let leading: [Candidate]
                let preserveNativeOrder: Bool
                if case .configured = pinyinPolicy {
                    leading = phrases.filter { $0.coversFullInput == true }
                    // A complete single syllable (shi → 是) must not be displaced
                    // by phrase completions that merely consume its short code.
                    preserveNativeOrder = base.first?.text.count == 1 && base.first?.coversFullInput == true
                } else {
                    leading = Array(phrases.prefix(4))
                    preserveNativeOrder = false
                }
                var segmentChoices: [Candidate] = []
                if let prefix = firstSegment, !prefix.isEmpty {
                    let fromPrefix = try await RimeInput.shared.candidates(raw: prefix, layout: layout,
                        script: script, data: rimeData, limit: 20, pinyinPolicy: pinyinPolicy)
                    segmentChoices = fromPrefix.filter { $0.text.count == 1 }.prefix(10).map {
                        Candidate(text: $0.text, reading: raw, consumed: prefix.count)
                    }
                    // Rime's short-code shortlist can omit common characters such
                    // as 个 for `g`; keep the first segment selectable regardless.
                    let textColumn = script == .simplified ? "simplified" : "traditional"
                    let rows = query("SELECT \(textColumn), code, code FROM pinyin WHERE code >= ? AND code < ? AND length(\(textColumn)) = 1 ORDER BY weight DESC LIMIT ?",
                                     values: [prefix, prefix + "{"], limit: 48)
                    var seenText = Set(segmentChoices.map(\.text))
                    for (text, _, _) in rows where segmentChoices.count < 16 {
                        if seenText.insert(text).inserted {
                            segmentChoices.append(Candidate(text: text, reading: raw, consumed: prefix.count))
                        }
                    }
                } else {
                    segmentChoices = Array(singles.prefix(8))
                    if case .configured = pinyinPolicy, segmentChoices.count < 8 {
                        // Phrase completions can fill the ordinary shortlist.
                        // Fetch singles separately, preserving their original
                        // engine indices and resolving only the selected one.
                        segmentChoices = try await RimeInput.shared.candidates(raw: raw, layout: layout,
                            script: script, data: rimeData, limit: 8, pinyinPolicy: pinyinPolicy, singlesOnly: true)
                    }
                }
                let chosenIDs = Set((leading + segmentChoices).map(\.id))
                let segmentTexts = Set(segmentChoices.map(\.text))
                if !preserveNativeOrder {
                    base = Array((leading + segmentChoices + base.filter {
                        !chosenIDs.contains($0.id) && !segmentTexts.contains($0.text)
                    }).prefix(requestedLimit))
                }
                let desktop = if case .configured = pinyinPolicy { true } else { false }
                if canCorrectPinyin, !desktop, raw.count >= 4, raw.count <= 12, !raw.contains("'") {
                    // Native fuzzy settings own phonetic matching. Ordinary
                    // keyboard typos remain useful under an explicit policy,
                    // while existing callers retain every legacy repair.
                    let includePhonetic: Bool
                    if case .legacy = pinyinPolicy { includePhonetic = true }
                    else { includePhonetic = false }
                    let repaired = typoCandidates(for: raw, script: script, includePhonetic: includePhonetic, maximumLength: 12)
                    // A common complete phrase one edit away is more useful than
                    // Rime's longer prefix completions for a misspelled code.
                    let firstRepair = repaired.first
                    let transposed = !includePhonetic && firstRepair.map {
                        PinyinTolerance.isAdjacentTransposition(raw, of: $0.candidate.reading)
                    } == true
                    let promoted = (firstRepair?.weight ?? 0) >= 1_000 || transposed ? firstRepair?.candidate : nil
                    if let promoted { base.removeAll { $0.text == promoted.text } }
                    let baseTexts = Set(base.map(\.text))
                    let remaining = repaired.dropFirst(promoted == nil ? 0 : 1).map(\.candidate)
                        .filter { !baseTexts.contains($0.text) }
                    let placement = min(base.contains { $0.text.count > 1 } ? 10 : 3, base.count)
                    base = Array(((promoted.map { [$0] } ?? []) + Array(base.prefix(placement)) +
                                  remaining + base.dropFirst(placement)).prefix(requestedLimit))
                }
            }
            base = insertingSentenceRepairs(in: base)
            if canCorrectPinyin {
                base = try await desktopCorrections(base, raw: raw, script: script, limit: requestedLimit,
                    policy: pinyinPolicy, preserveShorthand: firstSegment?.count == 1)
            }
            let prefix = learnedURL.map { LearnedWords.load(from: $0).candidates(for: raw, layout: layout,
                script: script, pinyinPolicy: pinyinPolicy) } ?? []
            let seen = Set(prefix.map { "\($0.text)|\($0.consumed)" })
            let learnedTexts = Set(prefix.map(\.text))
            let combined = prefix + base.filter {
                // Unresolved engine results have consumed == 0. Prefer the
                // explicit learned reading instead of displaying the same text twice.
                !(($0.engineIndex != nil && $0.consumed == 0 && learnedTexts.contains($0.text)) ||
                  seen.contains("\($0.text)|\($0.consumed)"))
            }
            if layout == .pinyin, let options = pinyinPolicy.fuzzyOptions {
                let ordered = try await prioritizingExactPinyin(in: combined, raw: raw, script: script,
                                                                options: options, policy: pinyinPolicy)
                return Array(ordered.prefix(requestedLimit))
            }
            return Array(combined.prefix(requestedLimit))
        }
        let input = raw.replacingOccurrences(of: "'", with: "")
        guard !input.isEmpty else { return [] }
        let select = "SELECT text, code, code FROM cangjie"
        var result: [Candidate] = []
        var seen = Set<String>()

        func add(_ rows: [(String, String, String)], consumed: Int) {
            for (text, roman, _) in rows where result.count < requestedLimit {
                let display: String
                if script == .simplified {
                    display = text.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? text
                } else { display = text }
                let key = "\(display)|\(consumed)"
                if seen.insert(key).inserted {
                    result.append(Candidate(text: display, reading: roman, consumed: consumed))
                }
            }
        }

        add(query("\(select) WHERE code = ? ORDER BY weight DESC LIMIT ?", values: [input], limit: requestedLimit), consumed: raw.count)
        if result.count < requestedLimit {
            // ASCII range search uses the index, unlike a default case-insensitive LIKE.
            add(query("\(select) WHERE code > ? AND code < ? ORDER BY weight DESC LIMIT ?",
                      values: [input, input + "{"], limit: requestedLimit - result.count), consumed: raw.count)
        }
        let learned = learnedURL.map { LearnedWords.load(from: $0).candidates(for: raw, layout: layout,
            script: script, pinyinPolicy: pinyinPolicy) } ?? []
        return Array((learned + result.filter { candidate in !learned.contains(where: { $0.text == candidate.text }) }).prefix(requestedLimit))
    }

    /// Character choices for the expanded pinyin browser. The first group uses
    /// the next syllable; later initials are previews until earlier code is used.
    public func singleCandidateGroups(for raw: String, script: ChineseScript,
                                      pinyinPolicy: PinyinQueryPolicy = .legacy) -> [SingleCandidateGroup] {
        guard handle != nil, !raw.isEmpty,
              raw.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "'") }) else { return [] }
        let segment = String(raw.split(separator: "'", omittingEmptySubsequences: true).first ?? "")
        guard !segment.isEmpty else { return [] }
        let column = script == .simplified ? "simplified" : "traditional"
        let maxLength = min(segment.count, 6)
        let exactSyllable = (1...maxLength).reversed().first { length in
            let prefix = String(segment.prefix(length))
            return !query("SELECT \(column), code, code FROM pinyin WHERE code = ? AND length(\(column)) = 1 LIMIT ?",
                          values: [prefix], limit: 1).isEmpty
        }
        let abbreviation = exactSyllable == nil || (segment.count > 2 && exactSyllable == 1)
        let codes: [String]
        if abbreviation {
            codes = segment.map(String.init)
        } else {
            codes = [String(segment.prefix(exactSyllable ?? 1))]
        }
        var groups: [SingleCandidateGroup] = []
        for (index, code) in codes.enumerated() {
            let consumed = abbreviation ? index + 1 : code.count
            let condition = abbreviation ? "code >= ? AND code < ?" : "code = ?"
            let values = abbreviation ? [code, code + "{"] : [code]
            let rows = query("SELECT \(column), code, code FROM pinyin WHERE \(condition) AND length(\(column)) = 1 GROUP BY \(column) ORDER BY MAX(weight) DESC LIMIT ?",
                             values: values, limit: index == 0 && abbreviation ? 1000 : 160)
            var seen = Set<String>()
            let candidates = rows.compactMap { text, _, _ in
                seen.insert(text).inserted ? Candidate(text: text, reading: raw, consumed: consumed) : nil
            }
            groups.append(SingleCandidateGroup(label: code, candidates: candidates))
        }
        if !abbreviation, let code = codes.first {
            for correction in PinyinTolerance.syllableCorrections(for: code, options: pinyinPolicy.fuzzyOptions) {
                let rows = query("SELECT \(column), code, code FROM pinyin WHERE code = ? AND length(\(column)) = 1 GROUP BY \(column) ORDER BY MAX(weight) DESC LIMIT ?",
                                 values: [correction], limit: 160)
                let originals = Set(groups.first?.candidates.map(\.text) ?? [])
                var seen = originals
                let candidates = rows.compactMap { text, _, _ in
                    seen.insert(text).inserted ? Candidate(text: text, reading: raw, consumed: code.count) : nil
                }
                if !candidates.isEmpty {
                    groups.append(SingleCandidateGroup(label: correction, candidates: candidates, isCorrection: true))
                }
            }
        }
        return groups
    }

    public func learn(code: String, text: String, layout: KeyboardLayout, script: ChineseScript,
                      pinyinPolicy: PinyinQueryPolicy = .legacy) async throws {
        guard let learnedURL else { return }
        var learningPolicy = pinyinPolicy
        if layout != .cangjie, let options = pinyinPolicy.fuzzyOptions, !options.isEmpty {
            // Enabling an unrelated fuzzy option must not hide a normal learned
            // phrase later. Inspect standard candidates without selecting them;
            // unrecognized aliases conservatively retain their option scope.
            let standard = try await RimeInput.shared.candidates(raw: code, layout: layout,
                script: script, data: rimeData, limit: 64, pinyinPolicy: .configured([]))
            if standard.contains(where: { $0.text == text }) { learningPolicy = .configured([]) }
        }
        var store = LearnedWords.load(from: learnedURL)
        store.learn(code: code, text: text, layout: layout, script: script, pinyinPolicy: learningPolicy)
        try store.save(to: learnedURL)
    }

    public func resolve(_ candidate: Candidate, for raw: String, layout: KeyboardLayout, script: ChineseScript,
                        pinyinPolicy: PinyinQueryPolicy = .legacy) async -> Candidate? {
        guard handle != nil else { return nil }
        guard candidate.engineIndex != nil else { return candidate }
        return try? await RimeInput.shared.resolve(candidate, raw: raw, layout: layout, script: script,
                                                  data: rimeData, pinyinPolicy: pinyinPolicy)
    }

    private func query(_ sql: String, values: [String], limit: Int) -> [(String, String, String)] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            sqlite3_bind_text(statement, Int32(offset + 1), value, -1, transient)
        }
        sqlite3_bind_int64(statement, Int32(values.count + 1), Int64(limit))
        var rows: [(String, String, String)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func text(_ column: Int32) -> String { String(cString: sqlite3_column_text(statement, column)) }
            rows.append((text(0), text(1), text(2)))
        }
        return rows
    }

    private func desktopCorrections(_ native: [Candidate], raw: String, script: ChineseScript,
                                    limit: Int, policy: PinyinQueryPolicy, preserveShorthand: Bool) async throws -> [Candidate] {
        guard case .configured(let options) = policy else { return native }
        let codes = DesktopPinyinCorrection.variants(for: raw)
        let singleColumn = script == .simplified ? "simplified" : "traditional"
        let placeholders = Array(repeating: "?", count: codes.count).joined(separator: ",")
        let phrase = phraseColumn(script)
        let rows = codes.isEmpty ? [] : query("""
            SELECT text, code, weight FROM (
                SELECT \(phrase) AS text, code, weight FROM \(phraseTable) WHERE code IN (\(placeholders))
                UNION ALL
                SELECT \(singleColumn) AS text, code, weight FROM pinyin
                    WHERE code IN (\(placeholders)) AND length(\(singleColumn)) = 1
            ) ORDER BY weight DESC LIMIT ?
            """, values: codes + codes, limit: 48)
        var seen = Set<String>()
        var repairs = rows.compactMap { text, code, _ -> Candidate? in
            guard seen.insert(text).inserted else { return nil }
            return Candidate(text: text, reading: code, consumed: raw.count)
        }
        // The indexed dictionary is a fast path, not a sentence-length gate.
        // Reuse the shared syllable parser for combinations of keyboard slips.
        let usedSentenceRepair = repairs.isEmpty && raw.count >= 4
        if usedSentenceRepair {
            let syllables: Set<String>
            if let cached = desktopSyllables[options] { syllables = cached }
            else {
                syllables = options.algebra.reduce(into: mobileStrictSyllables) { accepted, rule in
                    let parts = rule.split(separator: "/")
                    guard let regex = try? NSRegularExpression(pattern: String(parts[1])) else { return }
                    let aliases = accepted.map {
                        regex.stringByReplacingMatches(in: $0, range: NSRange($0.startIndex..., in: $0), withTemplate: String(parts[2]))
                    }
                    accepted.formUnion(aliases)
                }
                desktopSyllables[options] = syllables
            }
            repairs = try await sentenceCorrectionCandidates(for: raw, script: script, syllables: syllables, policy: policy)
        }
        let merged = DesktopPinyinCorrection.merge(repairs, into: native, limit: limit,
                                                   useRepairedFullInput: usedSentenceRepair && !preserveShorthand)
        guard !usedSentenceRepair, !preserveShorthand, let correction = merged.first,
              repairs.contains(correction), correction.reading.count == raw.count else { return merged }
        let differences = zip(raw.utf8, correction.reading.utf8).enumerated().compactMap { index, letters in
            letters.0 == letters.1 ? nil : index
        }
        // Preserve the typed reading for competing substitutions with the same
        // syllable count. Boundary-changing repairs have their own ranking.
        guard differences.count == 1, let offset = differences.first,
              let (standard, syllables) = try await standardSentence(for: raw, script: script),
              correction.text.count == syllables.count,
              hasWordCovering(offset, in: standard.text, syllables: syllables, script: script) else { return merged }
        return Array(([standard] + merged.filter { $0.text != standard.text }).prefix(limit))
    }

    private func hasWordCovering(_ offset: Int, in text: String, syllables: [String], script: ChineseScript) -> Bool {
        var end = 0
        guard let index = syllables.firstIndex(where: { syllable in
            end += syllable.utf8.count
            return offset < end
        }) else { return false }
        let characters = Array(text)
        let column = phraseColumn(script)
        for start in 0...index {
            for stop in index..<syllables.count where stop > start {
                let span = start...stop
                let rows = query("SELECT code, code, code FROM \(phraseTable) WHERE code = ? AND \(column) = ? LIMIT ?",
                                 values: [syllables[span].joined(), String(characters[span])], limit: 1)
                if !rows.isEmpty { return true }
            }
        }
        return false
    }

    private func hasExactPinyinPhrase(code: String, script: ChineseScript) -> Bool {
        let column = phraseColumn(script)
        return !query("SELECT \(column), code, code FROM \(phraseTable) WHERE code = ? AND length(\(column)) > 1 ORDER BY weight DESC LIMIT ?",
                      values: [code], limit: 1).isEmpty
    }

    private func prioritizingExactPinyin(in candidates: [Candidate], raw: String,
                                         script: ChineseScript, options: PinyinFuzzyOptions,
                                         policy: PinyinQueryPolicy) async throws -> [Candidate] {
        let code = raw.replacingOccurrences(of: "'", with: "")
        guard code.count >= 2 else { return candidates }

        let column = phraseColumn(script)
        var exactTexts = Set(query("SELECT \(column), code, code FROM \(phraseTable) WHERE code = ? LIMIT ?",
                                   values: [code], limit: -1).map(\.0))
        if compactPhraseStorage {
            let singleColumn = script == .simplified ? "simplified" : "traditional"
            exactTexts.formUnion(query("SELECT \(singleColumn), code, code FROM pinyin WHERE code = ? LIMIT ?",
                                       values: [code], limit: -1).map(\.0))
        }
        if exactTexts.isEmpty {
            let aliases = fuzzyAliases(for: options)
            var ordered = candidates
            if let first = candidates.first, first.engineIndex != nil, first.text.count > 1, first.coversFullInput != false {
                let preferred: Candidate?
                if let canonical = PinyinTolerance.completeSyllables(of: raw, exact: mobileStrictSyllables, aliases: aliases) {
                    if let repaired = try await repairImplicitVowel(raw: raw, code: code, canonical: canonical,
                                                                    candidate: first, script: script, policy: policy) {
                        preferred = repaired
                    } else {
                        preferred = try await RimeInput.shared.completeSyllableConversion(raw: raw, canonical: canonical,
                                                                                        script: script, data: rimeData)
                    }
                } else {
                    preferred = try await repairSplitInitial(raw: raw, candidate: first, script: script, policy: policy)
                }
                if let preferred, preferred.text != first.text {
                    ordered = [preferred] + candidates.filter { $0.text != preferred.text }
                    if preferred.reading != raw { return ordered }
                }
            }
            return try await retainingStandardSentence(in: ordered, raw: raw, script: script, policy: policy, aliases: aliases)
        }

        func isExact(_ candidate: Candidate, in texts: Set<String>) -> Bool {
            texts.contains(candidate.text) && candidate.coversFullInput != false &&
                (candidate.consumed == 0 || candidate.consumed == raw.count)
        }

        let explicitBoundary = raw.contains("'")
        let hasExactFirst = candidates.first.map { isExact($0, in: exactTexts) } ?? false
        var ordered = candidates
        if explicitBoundary || !hasExactFirst {
            // Find the first exact word independently of the fuzzy page size.
            let standard = try await RimeInput.shared.candidates(raw: raw, layout: .pinyin, script: script,
                data: rimeData, limit: 48, classifyCoverage: true)
            if let match = standard.first(where: { $0.coversFullInput == true && exactTexts.contains($0.text) }),
               !hasExactFirst || match.text != candidates.first?.text {
                let first = candidates.first { $0.text == match.text && $0.consumed == raw.count }
                    ?? Candidate(text: match.text, reading: raw, consumed: raw.count)
                ordered = [first] + candidates.filter { $0.text != first.text }
            }
        }
        guard !options.isEmpty, let exact = ordered.first, isExact(exact, in: exactTexts),
              let syllables = PinyinTolerance.completeSyllables(of: raw, exact: mobileStrictSyllables, aliases: [:]) else {
            return ordered
        }
        return try await removingUnsupportedFuzzySentences(from: ordered, standard: exact.text, syllables: syllables,
            raw: raw, script: script, policy: policy, aliases: fuzzyAliases(for: options)).remaining
    }

    private func fuzzyAliases(for options: PinyinFuzzyOptions) -> [String: Set<String>] {
        guard !options.isEmpty else { return [:] }
        if let cached = fuzzySyllableAliases[options] { return cached }
        let aliases = PinyinTolerance.fuzzySyllableAliases(from: mobileStrictSyllables, options: options)
        fuzzySyllableAliases[options] = aliases
        return aliases
    }

    private func retainingStandardSentence(in candidates: [Candidate], raw: String, script: ChineseScript,
                                           policy: PinyinQueryPolicy, aliases: [String: Set<String>]) async throws -> [Candidate] {
        guard !candidates.isEmpty,
              let (standard, syllables) = try await standardSentence(for: raw, script: script) else { return candidates }
        let (remaining, prefersStandard) = try await removingUnsupportedFuzzySentences(from: candidates, standard: standard.text,
            syllables: syllables, raw: raw, script: script, policy: policy, aliases: aliases, standardComposition: true)
        if remaining.first?.text == standard.text { return remaining }
        let distinct = remaining.filter { $0.text != standard.text || $0.coversFullInput == false }
        guard !prefersStandard, let first = distinct.first, first == candidates.first else {
            return [standard] + distinct
        }
        return [first, standard] + distinct.dropFirst()
    }

    private func standardSentence(for raw: String, script: ChineseScript) async throws -> (Candidate, [String])? {
        guard let syllables = PinyinTolerance.completeSyllables(of: raw, exact: mobileStrictSyllables, aliases: [:]) else {
            return nil
        }
        let spelling = syllables.joined(separator: "'")
        guard spelling.count <= Composition.maximumLength else { return nil }
        let found = try await RimeInput.shared.candidates(raw: spelling, layout: .pinyin,
            script: script, data: rimeData, limit: 1, classifyCoverage: true, completeSyllables: true)
        guard let match = found.first, match.coversFullInput == true, match.text.count == syllables.count else { return nil }
        // Candidate indices belong to the schema that produced them. The
        // standard result has verified full coverage and can commit directly.
        var standard = Candidate(text: match.text, reading: raw, consumed: raw.count)
        standard.coversFullInput = true
        return (standard, syllables)
    }

    private func removingUnsupportedFuzzySentences(from candidates: [Candidate], standard: String, syllables: [String],
                                                   raw: String, script: ChineseScript, policy: PinyinQueryPolicy,
                                                   aliases: [String: Set<String>], standardComposition: Bool = false) async throws
        -> (remaining: [Candidate], prefersStandard: Bool) {
        let standardCharacters = Array(standard)
        guard standardCharacters.count == syllables.count else { return (candidates, false) }
        let column = script == .simplified ? "simplified" : "traditional"
        let phrase = phraseColumn(script)
        var readingCache: [String: [Character: [String]]] = [:]
        var exactWordLengths: [Int: Int] = [:]
        var possibleSpans: [Int: [Range<Int>]] = [:]
        func readings(for character: Character, as syllable: String) -> [String] {
            if let cached = readingCache[syllable]?[character] { return cached }
            let allowed = aliases[syllable, default: []].union([syllable]).sorted()
            let bindings = Array(repeating: "?", count: allowed.count).joined(separator: ",")
            let rows = query("SELECT DISTINCT code, code, code FROM pinyin WHERE code IN (\(bindings)) AND \(column) = ? LIMIT ?",
                             values: allowed + [String(character)], limit: -1).map(\.0)
            readingCache[syllable, default: [:]][character] = rows
            return rows
        }
        func hasPhrase(_ text: String, for code: String) -> Bool {
            !query("SELECT code, code, code FROM \(phraseTable) WHERE code = ? AND \(phrase) = ? LIMIT ?",
                   values: [code, text], limit: 1).isEmpty
        }
        func phraseSpans(containing index: Int) -> [Range<Int>] {
            if let cached = possibleSpans[index] { return cached }
            // Bundled phrase codes are limited to 48 letters.
            var spans: [Range<Int>] = []
            for start in stride(from: index, through: max(0, index - 47), by: -1) {
                var length = syllables[start...index].reduce(0) { $0 + $1.count }
                for end in index..<syllables.count {
                    if end > index { length += syllables[end].count }
                    if length > 48 { break }
                    let span = start..<(end + 1)
                    if span.count >= 2 { spans.append(span) }
                }
            }
            let ordered = spans.sorted { $0.count > $1.count }
            possibleSpans[index] = ordered
            return ordered
        }
        func exactWordLength(containing index: Int) -> Int {
            if let cached = exactWordLengths[index] { return cached }
            for span in phraseSpans(containing: index) {
                if hasPhrase(String(standardCharacters[span]), for: syllables[span].joined()) {
                    exactWordLengths[index] = span.count
                    return span.count
                }
            }
            exactWordLengths[index] = 0
            return 0
        }
        func supports(_ characters: [Character], in span: Range<Int>) -> Bool {
            var spellings = [""]
            for index in span {
                let alternatives = readings(for: characters[index], as: syllables[index])
                // Keep the candidate when an alignment is uncertain or there
                // are too many polyphonic combinations to verify interactively.
                guard !alternatives.isEmpty, spellings.count <= 64 / alternatives.count else { return true }
                spellings = spellings.flatMap { prefix in alternatives.map { prefix + $0 } }
            }
            let text = String(characters[span])
            return spellings.contains { hasPhrase(text, for: $0) }
        }

        var remaining: [Candidate] = []
        var prefersStandard = false
        for (offset, candidate) in candidates.enumerated() {
            let characters = Array(candidate.text)
            let expandsCompleteSpelling = standardComposition && characters.count > syllables.count
            guard candidate.engineIndex != nil, candidate.coversFullInput != false,
                  expandsCompleteSpelling || characters.count == syllables.count, candidate.text != standard else {
                remaining.append(candidate)
                continue
            }
            var unsupported = expandsCompleteSpelling
            for index in syllables.indices where !unsupported && standardCharacters[index] != characters[index] {
                let syllable = syllables[index]
                guard aliases[syllable] != nil else { continue }
                let competing = readings(for: characters[index], as: syllable)
                guard !competing.isEmpty, !competing.contains(syllable) else { continue }
                let exactReading = readings(for: standardCharacters[index], as: syllable).contains(syllable)
                if offset == 0, exactReading {
                    prefersStandard = true
                }
                let wordLength = exactWordLength(containing: index)
                if standardComposition, exactReading, wordLength > 0 {
                    unsupported = true
                    break
                }
                // If only a single-character reading supports the standard
                // wording, retain alternatives supported by a real word.
                guard wordLength > 0 || (standardComposition && exactReading) else { continue }
                // A supported fuzzy word can start or end across a different
                // boundary, such as 不 + 帮忙 alongside 补办 + 忙.
                var supported = false
                for span in phraseSpans(containing: index) {
                    if span.count < max(2, wordLength) { break }
                    if supports(characters, in: span) {
                        supported = true
                        break
                    }
                }
                if !supported {
                    unsupported = true
                    break
                }
            }
            if unsupported {
                if candidate.coversFullInput == true { continue }
                if try await RimeInput.shared.coversFullPinyinInput(candidate, raw: raw, script: script, data: rimeData,
                                                                 policy: policy) { continue }
            }
            remaining.append(candidate)
        }
        return (remaining, prefersStandard)
    }

    private func repairSplitInitial(raw: String, candidate: Candidate, script: ChineseScript,
                                    policy: PinyinQueryPolicy) async throws -> Candidate? {
        guard candidate.engineIndex == 0,
              let segments = try await RimeInput.shared.firstPinyinReading(raw: raw, script: script,
                                                                           data: rimeData, policy: policy),
              let repaired = PinyinTolerance.repairSplitInitial(in: raw, segments: segments,
                                                                syllables: mobileStrictSyllables),
              repaired.hasPhraseSupport(lookup: { hasExactPinyinPhrase(code: $0, script: script) }) else { return nil }
        let found = try await RimeInput.shared.candidates(raw: repaired.code, layout: .pinyin, script: script, data: rimeData,
            limit: 1, classifyCoverage: true, completeSyllables: true)
        guard let match = found.first, match.coversFullInput == true else { return nil }
        return Candidate(text: match.text, reading: repaired.code, consumed: raw.count)
    }

    private func repairImplicitVowel(raw: String, code: String, canonical: [String], candidate: Candidate,
                                    script: ChineseScript, policy: PinyinQueryPolicy) async throws -> Candidate? {
        guard candidate.engineIndex == 0, canonical.count >= 3, canonical.joined() == code else { return nil }
        var offset = 0
        var proposals: [Int: (vowel: String, preceding: String, repair: PinyinTolerance.RepairedSpelling)] = [:]
        for index in canonical.indices {
            let syllable = canonical[index]
            defer { offset += syllable.count }
            guard index > 0, syllable.count == 1, "aoe".contains(syllable),
                  let previous = canonical[index - 1].last, "aeiouv".contains(previous),
                  let repair = PinyinTolerance.repairSplitSyllable(in: raw, segments: canonical, at: index,
                                                                   syllables: mobileStrictSyllables) else { continue }
            proposals[offset] = (syllable, canonical[index - 1], repair)
        }
        guard !proposals.isEmpty,
              let native = try await RimeInput.shared.firstPinyinReading(raw: raw, script: script,
                                                                         data: rimeData, policy: policy),
              native.count == candidate.text.count else { return nil }

        // The native path may split other syllables into initials. Compare each
        // possible repair by its typed position, so those extra cuts don't hide it.
        let column = script == .simplified ? "simplified" : "traditional"
        offset = 0
        let original = Array(candidate.text)
        var supported: [(repair: PinyinTolerance.RepairedSpelling, literalVowel: Int?)] = []
        for (index, syllable) in native.enumerated() {
            defer { offset += syllable.count }
            guard let proposal = proposals[offset], syllable == proposal.vowel else { continue }
            let exact = query("SELECT code, code, code FROM pinyin WHERE code = ? AND \(column) = ? LIMIT ?",
                              values: [proposal.vowel, String(original[index])], limit: 1)
            if exact.isEmpty || index > 0 && native[index - 1] == proposal.preceding {
                supported.append((proposal.repair, exact.isEmpty ? nil : index))
            }
        }
        guard supported.count == 1, let (repair, literalVowel) = supported.first else { return nil }
        let found = try await RimeInput.shared.candidates(raw: repair.code, layout: .pinyin, script: script, data: rimeData,
            limit: 1, classifyCoverage: true, completeSyllables: true)
        guard let match = found.first, match.coversFullInput == true else { return nil }
        if let index = literalVowel {
            // A literal particle may be intentional. A sentence assembled by
            // Rime can still support an internal merge when both sides agree.
            let corrected = Array(match.text)
            let before = index - 1
            let after = index + 1
            let preservesContext = before > 0 && after < original.count &&
                corrected.count == original.count - 1 &&
                corrected.prefix(before).elementsEqual(original.prefix(before)) &&
                corrected[index...].elementsEqual(original[after...])
            if !preservesContext {
                let phrase = phraseColumn(script)
                let exact = query("SELECT code, code, code FROM \(phraseTable) WHERE code = ? AND \(phrase) = ? LIMIT ?",
                                  values: [repair.syllables.map(\.code).joined(), match.text], limit: 1)
                guard !exact.isEmpty else { return nil }
            }
        }
        return Candidate(text: match.text, reading: repair.code, consumed: raw.count)
    }

    private func phraseColumn(_ script: ChineseScript) -> String {
        if script == .simplified { return "simplified" }
        return compactPhraseStorage ? "COALESCE(NULLIF(traditional,''),simplified)" : "traditional"
    }

    private func hasPinyinSyllable(startingWith prefix: String, script: ChineseScript) -> Bool {
        guard prefix.count == 2, prefix.allSatisfy({ $0.isASCII && $0.isLetter }) else { return false }
        let column = script == .simplified ? "simplified" : "traditional"
        return !query("SELECT \(column), code, code FROM pinyin WHERE code >= ? AND code < ? AND length(\(column)) = 1 LIMIT ?",
                      values: [prefix, prefix + "{"], limit: 1).isEmpty
    }

    private func mobileSentenceRepairs(for raw: String, script: ChineseScript, fuzzy: Bool) async throws -> [Candidate] {
        let syllables = fuzzy ? mobileFuzzySyllables : mobileStrictSyllables
        return try await sentenceCorrectionCandidates(for: raw, script: script, syllables: syllables,
                                                      policy: .mobile(fuzzy: fuzzy))
    }

    private func sentenceCorrectionCandidates(for raw: String, script: ChineseScript, syllables: Set<String>,
                                              policy: PinyinQueryPolicy) async throws -> [Candidate] {
        try Task.checkCancellation()
        let proposals = PinyinTolerance.sentenceRepairs(of: raw, syllables: syllables)
            .filter { $0.spellings.count <= 4 }
        if proposals.count == 2, let complete = proposals.first, let partial = proposals.last,
           complete.editCount > partial.editCount {
            // An additional edit to the tail needs stronger evidence than
            // preserving the partial input. Compare the existing word weights.
            let completeWords = dictionaryPhrases(for: complete, raw: raw, script: script, syllables: syllables)
            let partialWords = dictionaryPhrases(for: partial, raw: raw, script: script, syllables: syllables)
            if let best = completeWords.first, best.weight > (partialWords.first?.weight ?? Int.min) {
                return completeWords.map(\.candidate)
            }
            if !partialWords.isEmpty { return partialWords.map(\.candidate) }
            return try await candidates(for: partial, raw: raw, script: script, syllables: syllables, policy: policy)
        }
        for proposal in proposals {
            let candidates = try await candidates(for: proposal, raw: raw, script: script, syllables: syllables, policy: policy)
            if !candidates.isEmpty { return candidates }
        }
        return []
    }

    private func candidates(for repairs: PinyinTolerance.SentenceRepairs, raw: String, script: ChineseScript,
                            syllables: Set<String>, policy: PinyinQueryPolicy) async throws -> [Candidate] {
        try Task.checkCancellation()
        var readings = repairs.readings
        let changesUnsupportedInitial = raw.first.map { first in
            !mobileStrictSyllables.contains { $0.first == first }
        } ?? false
        // An input starting outside Pinyin may be English or a name. Repair it
        // only when the entire corrected code has a dictionary conversion.
        if changesUnsupportedInitial {
            return dictionaryPhrases(for: repairs, raw: raw, script: script, syllables: syllables).map(\.candidate)
        }
        if repairs.requiresDictionaryEvidence {
            let words = dictionaryPhrases(for: repairs, raw: raw, script: script, syllables: syllables)
            if !words.isEmpty { return words.map(\.candidate) }

            var evidence: [String: Bool] = [:]
            readings = readings.filter { reading in
                reading.hasPhraseSupport { code in
                    if let cached = evidence[code] { return cached }
                    let exists = hasExactPinyinPhrase(code: code, script: script)
                    evidence[code] = exists
                    return exists
                }
            }
        }
        var seen = Set<String>()
        var candidates: [Candidate] = []
        for reading in readings {
            let spelling = reading.code
            let found = try await RimeInput.shared.candidates(raw: spelling, layout: .pinyin,
                script: script, data: rimeData, limit: repairs.hasUnfinishedTail ? 8 : 1,
                pinyinPolicy: policy, classifyCoverage: true)
            for choice in found where choice.coversFullInput == true && seen.insert(choice.text).inserted {
                candidates.append(Candidate(text: choice.text, reading: spelling, consumed: raw.count))
            }
        }
        return candidates
    }

    private func dictionaryPhrases(for repairs: PinyinTolerance.SentenceRepairs, raw: String,
                                   script: ChineseScript, syllables: Set<String>) -> [(candidate: Candidate, weight: Int)] {
        var readingsByCode: [String: String] = [:]
        for spelling in repairs.spellings {
            if repairs.hasUnfinishedTail, let separator = spelling.lastIndex(of: "'") {
                let prefix = spelling[..<separator].replacingOccurrences(of: "'", with: "")
                let tail = spelling[spelling.index(after: separator)...]
                for syllable in syllables where syllable.hasPrefix(tail) {
                    readingsByCode[prefix + syllable] = spelling
                }
            } else {
                readingsByCode[spelling.replacingOccurrences(of: "'", with: "")] = spelling
            }
        }
        let codes = readingsByCode.keys.sorted()
        guard !codes.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: codes.count).joined(separator: ",")
        let column = phraseColumn(script)
        let rows = query("""
            SELECT \(column), code, weight FROM \(phraseTable)
            WHERE code IN (\(placeholders)) AND length(\(column)) > 1
            ORDER BY weight DESC, code, \(column) LIMIT ?
            """, values: codes, limit: 48)
        var seen = Set<String>()
        return rows.compactMap { text, code, weight in
            guard let reading = readingsByCode[code], seen.insert(text).inserted else { return nil }
            return (Candidate(text: text, reading: reading, consumed: raw.count), Int(weight) ?? 0)
        }
    }

    private func initialSingles(for prefix: String, raw: String, script: ChineseScript,
                                pinyinPolicy: PinyinQueryPolicy) async throws -> [Candidate] {
        let native = try await RimeInput.shared.candidates(raw: prefix, layout: .pinyin,
            script: script, data: rimeData, limit: 64, pinyinPolicy: pinyinPolicy)
        let column = script == .simplified ? "simplified" : "traditional"
        let rows = query("SELECT \(column), \(column), \(column) FROM pinyin WHERE code >= ? AND code < ? AND length(\(column)) = 1 GROUP BY \(column) ORDER BY MAX(weight) DESC LIMIT ?",
                         values: [prefix, prefix + "{"], limit: Int.max)
        var seen = Set<String>()
        return (native.filter { $0.text.count == 1 }.map(\.text) + rows.map(\.0)).compactMap { text in
            seen.insert(text).inserted ? Candidate(text: text, reading: raw, consumed: prefix.count) : nil
        }
    }

    private func typoCandidates(for raw: String, script: ChineseScript,
                                includePhonetic: Bool, maximumLength: Int) -> [(candidate: Candidate, weight: Int)] {
        // rankedVariants merges duplicate paths and retains a phonetic marker
        // even when a generic edit can produce the same code. Filter before SQL
        // ranking so disabled sounds cannot return through typo promotion.
        let variants = PinyinTolerance.rankedVariants(of: raw, maximumLength: maximumLength).filter { includePhonetic || !$0.phonetic }
        guard !variants.isEmpty else { return [] }
        let column = phraseColumn(script)
        let placeholders = Array(repeating: "?", count: variants.count).joined(separator: ",")
        let rows = query("SELECT \(column), code, weight FROM \(phraseTable) WHERE code IN (\(placeholders)) AND length(\(column)) > 1 ORDER BY weight DESC LIMIT ?",
                         values: variants.map(\.code), limit: 48)
        let phonetic = Set(variants.filter(\.phonetic).map(\.code))
        var seen = Set<String>()
        let unique = rows.compactMap { text, code, weight -> (candidate: Candidate, weight: Int, score: Int)? in
            guard seen.insert(text).inserted else { return nil }
            let frequency = Int(weight) ?? 0
            return (Candidate(text: text, reading: code, consumed: raw.count), frequency,
                    frequency * (phonetic.contains(code) ? 10 : 1))
        }
        return unique.sorted { $0.score > $1.score }.map { ($0.candidate, $0.weight) }
    }


}

/// Owned exclusively by Lexicon's actor. ARC also closes it if the extension releases the actor.
private final class SQLiteConnection: @unchecked Sendable {
    private(set) var handle: OpaquePointer?
    init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let handle { sqlite3_close(handle) }
            handle = nil
            throw LexiconError.unavailable
        }
        sqlite3_exec(handle, "PRAGMA query_only=ON; PRAGMA cache_size=-1024; PRAGMA mmap_size=0;", nil, nil, nil)
    }
    func close() {
        if let handle { sqlite3_close(handle) }
        handle = nil
    }
    deinit { close() }
}
