import Foundation

/// Keyboard and phonetic spelling repairs for pinyin input.
public enum PinyinTolerance {
    private static let neighbors: [Character: String] = [
        "q": "wa", "w": "qase", "e": "wsdr", "r": "edft", "t": "rfgy", "y": "tghu",
        "u": "yhji", "i": "ujko", "o": "iklp", "p": "ol", "a": "qwsz", "s": "awedxz",
        "d": "serfcx", "f": "drtgcv", "g": "ftyhbv", "h": "gyujbn", "j": "huiknm",
        "k": "jiolm", "l": "kop", "z": "asx", "x": "zsdc", "c": "xdfv", "v": "cfgb",
        "b": "vghn", "n": "bhjm", "m": "njk"
    ]

    struct Variant {
        let code: String
        var phonetic: Bool
    }

    public static func variants(of raw: String) -> [String] {
        rankedVariants(of: raw).map(\.code)
    }

    static func syllableCorrections(for code: String, options: PinyinFuzzyOptions? = nil) -> [String] {
        guard !code.isEmpty, code.allSatisfy({ $0.isASCII && $0.isLetter }) else { return [] }
        if let options {
            return options.algebra.compactMap { rule in
                let parts = rule.split(separator: "/")
                let alias = code.replacingOccurrences(of: String(parts[1]), with: String(parts[2]),
                                                      options: .regularExpression)
                return alias == code ? nil : alias
            }
        }
        var result: [String] = []
        if code.hasSuffix("ng") { result.append(String(code.dropLast())) }
        else if code.hasSuffix("n") { result.append(code + "g") }
        for (long, short) in [("zh", "z"), ("ch", "c"), ("sh", "s")] {
            if code.hasPrefix(long) {
                result.append(short + code.dropFirst(long.count))
            } else if code.hasPrefix(short) {
                result.append(long + code.dropFirst(short.count))
            }
        }
        if code.hasPrefix("n") { result.append("l" + code.dropFirst()) }
        else if code.hasPrefix("l") { result.append("n" + code.dropFirst()) }
        return result.filter { $0 != code }
    }

    static func isAdjacentTransposition(_ raw: String, of corrected: String) -> Bool {
        let a = Array(raw), b = Array(corrected)
        guard a.count == b.count else { return false }
        let changed = a.indices.filter { a[$0] != b[$0] }
        guard changed.count == 2, changed[1] == changed[0] + 1 else { return false }
        return a[changed[0]] == b[changed[1]] && a[changed[1]] == b[changed[0]]
    }

    static func acceptedSyllables(from syllables: Set<String>, fuzzy: Bool) -> Set<String> {
        let keyboardSpellings = ["derive/([nl])ve$/$1ue/", "derive/([jqxy])u/$1v/", "derive/([aeiou])ng$/$1gn/"]
        let rules = (fuzzy ? PinyinFuzzyOptions.all.algebra : []) + keyboardSpellings
        return rules.reduce(into: syllables) { accepted, rule in
            let fields = rule.split(separator: "/")
            guard let regex = try? NSRegularExpression(pattern: String(fields[1])) else { return }
            let template = String(fields[2])
            let aliases = accepted.map {
                regex.stringByReplacingMatches(in: $0, range: NSRange($0.startIndex..., in: $0), withTemplate: template)
            }
            accepted.formUnion(aliases)
        }
    }

    static func isInitial(_ spelling: Substring) -> Bool {
        if spelling.count == 1, let letter = spelling.first {
            return "bpmfdtnlgkhjqxrzcswyv".contains(letter)
        }
        return ["zh", "ch", "sh"].contains(spelling)
    }

    static func fuzzySyllableAliases(from syllables: Set<String>, options: PinyinFuzzyOptions) -> [String: Set<String>] {
        var readings = Dictionary(uniqueKeysWithValues: syllables.map { ($0, Set([$0])) })
        for rule in options.algebra {
            let parts = rule.split(separator: "/")
            guard let regex = try? NSRegularExpression(pattern: String(parts[1])) else { continue }
            for (code, originals) in readings {
                let alias = regex.stringByReplacingMatches(in: code, range: NSRange(code.startIndex..., in: code),
                                                           withTemplate: String(parts[2]))
                if alias != code { readings[alias, default: []].formUnion(originals) }
            }
        }
        return readings.filter { spelling, originals in
            !syllables.contains(spelling) || originals.count > 1
        }
    }

    static func completeSyllables(of raw: String, exact: Set<String>, aliases: [String: Set<String>]) -> [String]? {
        guard raw.count >= 4, raw.utf8.allSatisfy({ (97...122).contains($0) || $0 == 39 }) else { return nil }
        struct Path {
            let syllables: [String]
            let fuzzyCount: Int
            var ambiguous = false
            var cost: (Int, Int) { (syllables.count, fuzzyCount) }
        }
        let letters = Array(raw)
        var paths = Array<Path?>(repeating: nil, count: letters.count + 1)
        paths[letters.count] = Path(syllables: [], fuzzyCount: 0)
        for start in letters.indices.reversed() {
            if letters[start] == "'" {
                paths[start] = paths[start + 1]
                continue
            }
            for stop in (start + 1)...min(start + 6, letters.count) {
                if letters[stop - 1] == "'" { break }
                guard let tail = paths[stop] else { continue }
                let code = String(letters[start..<stop])
                guard !isInitial(code[...]) else { continue }
                let typed = exact.contains(code)
                for syllable in typed ? [code] : aliases[code, default: []].sorted() {
                    let path = Path(syllables: [syllable] + tail.syllables,
                                    fuzzyCount: tail.fuzzyCount + (typed ? 0 : 1), ambiguous: tail.ambiguous)
                    if let best = paths[start] {
                        if path.cost == best.cost, path.syllables != best.syllables { paths[start]?.ambiguous = true }
                        guard path.cost < best.cost else { continue }
                    }
                    paths[start] = path
                }
            }
        }
        guard let best = paths[0], !best.ambiguous, best.syllables.count >= 2 else { return nil }
        return best.syllables
    }

    private struct RepairPaths {
        var cost = (edits: Int.max, syllables: Int.max, transpositions: Int.max)
        var spellings: [String: [RepairedSyllable]] = [:]

        var readings: [RepairedSpelling] {
            spellings.map { RepairedSpelling(code: $0.key, syllables: $0.value) }
                .sorted { $0.code < $1.code }
        }

        mutating func prepend(_ spelling: String, to suffix: Self,
                              syllables: Int = 1, edits: Int = 0, transpositions: Int = 0) {
            guard !suffix.spellings.isEmpty else { return }
            let total = (suffix.cost.edits + edits, suffix.cost.syllables + syllables,
                         suffix.cost.transpositions + transpositions)
            guard total <= cost else { return }
            if total < cost {
                spellings.removeAll()
                cost = total
            }
            // Five distinct readings already make this too ambiguous to query.
            let prefix = syllables == 0 ? [] : [RepairedSyllable(code: spelling, wasEdited: edits > 0)]
            for (tail, following) in suffix.spellings {
                guard spellings.count < 5 else { break }
                let code = spelling + tail
                if spellings[code] == nil { spellings[code] = prefix + following }
            }
        }
    }

    struct RepairedSyllable {
        let code: String
        let wasEdited: Bool
    }

    struct RepairedSpelling {
        let code: String
        let syllables: [RepairedSyllable]

        func hasPhraseSupport(lookup: (String) -> Bool) -> Bool {
            // Partition the complete syllables into dictionary phrases and intact syllables.
            var reachable = Array(repeating: false, count: syllables.count + 1)
            reachable[0] = true
            for start in syllables.indices where reachable[start] {
                if !syllables[start].wasEdited { reachable[start + 1] = true }
                var phrase = ""
                var hasEdit = false
                for end in start..<syllables.count {
                    phrase += syllables[end].code
                    hasEdit = hasEdit || syllables[end].wasEdited
                    if end > start, hasEdit, !reachable[end + 1], lookup(phrase) {
                        reachable[end + 1] = true
                    }
                }
                if reachable[syllables.count] { return true }
            }
            return false
        }
    }

    struct SentenceRepairs {
        let readings: [RepairedSpelling]
        var spellings: [String] { readings.map(\.code) }
        let editCount: Int
        let requiresDictionaryEvidence: Bool
        let hasUnfinishedTail: Bool
    }

    static func sentenceRepairs(of raw: String, syllables: Set<String>) -> [SentenceRepairs] {
        guard raw.count >= 4, raw.utf8.allSatisfy({ (97...122).contains($0) || $0 == 39 }) else { return [] }
        let letters = Array(raw)
        let end = letters.count
        var prefix = Array(repeating: false, count: end + 1)
        prefix[0] = true
        for start in letters.indices where prefix[start] {
            if letters[start] == "'" {
                prefix[start + 1] = true
                continue
            }
            for stop in (start + 1)...min(start + 6, end) where syllables.contains(String(letters[start..<stop])) {
                prefix[stop] = true
            }
        }
        guard !prefix[end] else { return [] }
        // Keep a valid final prefix untouched and check whether the earlier
        // syllables need repair. Correct input with such a prefix keeps native ranking.
        var unfinishedTails: [Int: String] = [:]
        for start in max(1, end - 5)..<end {
            let trailing = String(letters[start...])
            guard !syllables.contains(trailing),
                  syllables.contains(where: { $0.hasPrefix(trailing) }) else { continue }
            if prefix[start] { return [] }
            unfinishedTails[start] = letters[start - 1] == "'" ? trailing : "'" + trailing
        }

        let complete = bestRepairPaths(in: letters, syllables: syllables, endings: [end: ""])
        let partial = unfinishedTails.isEmpty ? nil :
            bestRepairPaths(in: letters, syllables: syllables, endings: unfinishedTails)
        var proposals: [SentenceRepairs] = []
        if let complete {
            // A known word can support a repair when few syllables are intact.
            let needsEvidence = complete.cost.edits > max(1, complete.cost.syllables / 2)
            proposals.append(SentenceRepairs(readings: complete.readings,
                                             editCount: complete.cost.edits,
                                             requiresDictionaryEvidence: needsEvidence, hasUnfinishedTail: false))
        }
        if let partial {
            let needsEvidence = partial.cost.edits > max(1, partial.cost.syllables / 2)
            proposals.append(SentenceRepairs(readings: partial.readings,
                                             editCount: partial.cost.edits,
                                             requiresDictionaryEvidence: needsEvidence, hasUnfinishedTail: true))
        }
        return proposals
    }

    private static func bestRepairPaths(in letters: [Character], syllables: Set<String>,
                                        endings: [Int: String]) -> RepairPaths? {
        let end = letters.count
        var paths = Array(repeating: RepairPaths(), count: end + 1)
        if let ending = endings[end] {
            paths[end] = RepairPaths(cost: (0, 0, 0), spellings: [ending: []])
        }
        for start in letters.indices.reversed() {
            var current = RepairPaths()
            if let ending = endings[start] {
                current = RepairPaths(cost: (0, 0, 0), spellings: [ending: []])
            }
            if letters[start] == "'" {
                current.prepend("'", to: paths[start + 1], syllables: 0)
            } else {
                for stop in (start + 1)...min(start + 6, end) {
                    let range = letters[start..<stop]
                    if range.last == "'" { break }
                    let suffix = paths[stop]
                    guard !suffix.spellings.isEmpty else { continue }
                    let spelling = String(range)
                    if syllables.contains(spelling) {
                        current.prepend(spelling, to: suffix)
                    } else if suffix.cost.edits < current.cost.edits {
                        for (repair, transpositions) in repairedSyllables(Array(range), accepted: syllables) {
                            current.prepend(repair, to: suffix, edits: 1, transpositions: transpositions)
                        }
                    }
                }
            }
            paths[start] = current
        }
        let best = paths[0]
        return best.spellings.isEmpty ? nil : best
    }

    private static func repairedSyllables(_ letters: [Character], accepted: Set<String>) -> [String: Int] {
        var variants: [String: Int] = [:]
        var edited = letters
        for index in letters.indices {
            for replacement in neighbors[letters[index]] ?? "" {
                edited[index] = replacement
                let spelling = String(edited)
                if accepted.contains(spelling) { variants[spelling] = 0 }
            }
            edited[index] = letters[index]
            if index > 0, letters[index - 1] != letters[index] {
                edited.swapAt(index - 1, index)
                let spelling = String(edited)
                if accepted.contains(spelling) { variants[spelling] = 1 }
                edited.swapAt(index - 1, index)
            }
        }
        return variants
    }

    static func repairJoinedSyllable(_ code: String, syllables: Set<String>) -> String? {
        guard (3...6).contains(code.count), !syllables.contains(code) else { return nil }
        let repairs = repairedSyllables(Array(code), accepted: syllables)
        return repairs.count == 1 ? repairs.keys.first : nil
    }

    static func repairSplitInitial(in raw: String, segments: [Substring], syllables: Set<String>) -> RepairedSpelling? {
        let initials = segments.indices.filter { isInitial(segments[$0]) }
        guard initials.count == 1, let index = initials.first, index > 0, index < segments.count - 1,
              segments.enumerated().allSatisfy({ $0.offset == index || syllables.contains(String($0.element)) }) else { return nil }
        return repairSplitSyllable(in: raw, segments: segments.map(String.init), at: index, syllables: syllables)
    }

    static func repairSplitSyllable(in raw: String, segments: [String], at index: Int,
                                    syllables: Set<String>) -> RepairedSpelling? {
        guard index > 0, segments.indices.contains(index),
              let joined = repairJoinedSyllable(segments[index - 1] + segments[index], syllables: syllables) else { return nil }

        let offset = segments[..<index].reduce(0) { $0 + $1.count }
        let letters = Array(raw)
        let typedOffsets = letters.indices.filter { letters[$0] != "'" }
        guard offset > 0, typedOffsets.indices.contains(offset), letters[typedOffsets[offset] - 1] != "'" else { return nil }

        var corrected = segments.map { RepairedSyllable(code: $0, wasEdited: false) }
        corrected.replaceSubrange((index - 1)...index, with: [RepairedSyllable(code: joined, wasEdited: true)])
        return RepairedSpelling(code: corrected.map(\.code).joined(separator: "'"), syllables: corrected)
    }

    static func isNeighborReplacement(_ raw: String, of corrected: String) -> Bool {
        let a = Array(raw), b = Array(corrected)
        guard a.count == b.count else { return false }
        let changed = a.indices.filter { a[$0] != b[$0] }
        guard changed.count == 1, let index = changed.first else { return false }
        return neighbors[a[index]]?.contains(b[index]) == true
    }

    static func rankedVariants(of raw: String, maximumLength: Int = 12, minimumLength: Int = 4,
                               missingLetters: String = "aeiougnhr", maximumVariants: Int = 200) -> [Variant] {
        guard (minimumLength...maximumLength).contains(raw.count), raw.allSatisfy({ $0.isASCII && $0.isLetter }) else { return [] }
        let letters = Array(raw.lowercased())
        var result: [Variant] = []
        var indices: [String: Int] = [:]
        func append(_ chars: [Character], phonetic: Bool = false) {
            let value = String(chars)
            guard value != raw.lowercased() else { return }
            if let index = indices[value] {
                if phonetic { result[index].phonetic = true }
            } else {
                indices[value] = result.count
                result.append(Variant(code: value, phonetic: phonetic))
            }
        }
        for i in letters.indices where i + 1 < letters.count {
            if letters[i] != letters[i + 1] {
                var copy = letters
                copy.swapAt(i, i + 1)
                append(copy)
            }
            if letters[i] == letters[i + 1] {
                var copy = letters
                copy.remove(at: i)
                append(copy)
            }
            if letters[i] == "n", letters[i + 1] == "g" {
                var copy = letters
                copy.remove(at: i + 1)
                append(copy, phonetic: true)
            }
            if "zcs".contains(letters[i]), letters[i + 1] == "h" {
                var copy = letters
                copy.remove(at: i + 1)
                append(copy, phonetic: true)
            }
        }
        for i in letters.indices where letters[i] == "n" || letters[i] == "l" {
            var copy = letters
            copy[i] = letters[i] == "n" ? "l" : "n"
            append(copy, phonetic: true)
        }
        for i in letters.indices {
            for replacement in neighbors[letters[i]] ?? "" {
                var copy = letters
                copy[i] = replacement
                append(copy)
            }
        }
        for i in 0...letters.count {
            for missing in missingLetters {
                var copy = letters
                copy.insert(missing, at: i)
                let phonetic = i > 0 && ((missing == "h" && "zcs".contains(letters[i - 1])) ||
                                         (missing == "g" && letters[i - 1] == "n"))
                append(copy, phonetic: phonetic)
            }
        }
        return Array(result.prefix(maximumVariants))
    }
}
