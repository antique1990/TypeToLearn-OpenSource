import AppKit
import KeyboardCore

/// Uses the same mixed-input policy as the iPhone keyboard, with AppKit spelling
/// evidence in place of UITextChecker. Pinyin candidates are never pre-resolved.
@MainActor
enum MacCandidateLookup {
    private static var spellingCache = BoundedCache<String, [String]>(capacity: 256)
    private static var spellingRequests: [String: Task<[String], Never>] = [:]
    private static let spellingWarmup = Task { @MainActor in _ = await completions(for: "he") }
    static func prepareEnglishService() { _ = spellingWarmup }

    /// AppKit submits this request on the main thread and generates candidates
    /// in the background. Never call synchronous completions on the input path.
    private static func completions(for prefix: String) async -> [String] {
        if let cached = spellingCache.value(for: prefix) { return cached }
        if let pending = spellingRequests[prefix] { return await pending.value }
        let request = Task { @MainActor in
            await withCheckedContinuation { continuation in
                let reply = SpellingReply(continuation)
                reply.timeout = Task { @MainActor in
                    do { try await Task.sleep(for: .seconds(1)) }
                    catch { return }
                    reply.finish([])
                }
                NSSpellChecker.shared.requestCandidates(
                    forSelectedRange: NSRange(location: prefix.utf16.count, length: 0),
                    in: prefix, types: NSTextCheckingAllSystemTypes,
                    options: [.orthography: NSOrthography(dominantScript: "Latn", languageMap: ["Latn": ["en_US"]])],
                    inSpellDocumentWithTag: 0) { _, results in
                    let words = results.compactMap(\.replacementString).map {
                        $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    }.filter { !$0.isEmpty && $0.lowercased() != prefix.lowercased() }
                    Task { @MainActor in reply.finish(words) }
                }
            }
        }
        spellingRequests[prefix] = request
        let words = await request.value
        spellingRequests[prefix] = nil
        if !words.isEmpty { spellingCache.insert(words, for: prefix) }
        return words
    }

    @MainActor private final class SpellingReply {
        private var continuation: CheckedContinuation<[String], Never>?
        var timeout: Task<Void, Never>?
        init(_ continuation: CheckedContinuation<[String], Never>) { self.continuation = continuation }
        func finish(_ words: [String]) {
            guard let continuation else { return }
            self.continuation = nil
            timeout?.cancel(); timeout = nil
            continuation.resume(returning: words)
        }
    }
    static func candidates(for raw: String, layout: KeyboardLayout, script: ChineseScript,
                           englishMode: Bool, lexicon: Lexicon?, displayInput: String? = nil,
                           limit: Int? = nil,
                           pinyinPolicy: PinyinQueryPolicy = .legacy,
                           completionProvider: ((String) async -> [String]?)? = nil,
                           onInitial: (([Candidate]) -> Void)? = nil) async throws -> [Candidate] {
        guard !raw.isEmpty, (limit ?? 1) > 0 else { return [] }
        try Task.checkCancellation()
        let spelling = displayInput.flatMap { $0.lowercased() == raw.lowercased() ? $0 : nil } ?? raw
        let mixedPinyin = !englishMode && layout == .pinyin
        let offline = if englishMode || mixedPinyin {
            await lexicon?.englishWords(prefix: raw) ?? (known: false, completions: [])
        } else { (known: false, completions: [String]()) }
        let lower = spelling.lowercased()
        let regularCase = spelling == lower || spelling == spelling.uppercased() ||
            spelling == lower.prefix(1).uppercased() + lower.dropFirst()
        // Preserve explicit internal capitals (iPhone/MacBook) without waiting for spelling services.
        let knownWord = EnglishSuggestionPolicy.hasWordEvidence(for: spelling,
            dictionaryKnown: offline.known || !regularCase, completions: [])
        let exactPinyin = if mixedPinyin, spelling.count >= 3, let lexicon {
            await lexicon.hasExactPinyinReading(raw, script: script)
        } else { false }
        try Task.checkCancellation()
        if mixedPinyin, knownWord, !exactPinyin, spelling.count >= 3 {
            let candidates = [Candidate(text: spelling, reading: raw, consumed: raw.count)]
            onInitial?(candidates)
            return candidates
        }

        let found = if !englishMode, let lexicon {
            try await lexicon.candidates(for: raw, layout: layout, script: script, limit: limit, pinyinPolicy: pinyinPolicy)
        } else { [Candidate]() }
        try Task.checkCancellation()
        guard englishMode || mixedPinyin else { onInitial?(found); return found }
        if mixedPinyin, spelling == lower, let lexicon, await lexicon.prefersPinyin(overEnglish: lower) {
            try Task.checkCancellation()
            // Keep both initial and late results Chinese. A spelling-service
            // echo/name must not reintroduce the rejected Pinyin homograph.
            onInitial?(found)
            return found
        }
        try Task.checkCancellation()
        // A complete native phrase can also come from mixed full and initial spellings.
        // Keep it ahead of English completions while preserving exact English matches.
        let completeNativePhrase = found.first.map {
            $0.engineIndex != nil && $0.coversFullInput == true && $0.text.count > 1
        } ?? false
        func merged(_ completions: [String]) -> [Candidate] {
            let words = EnglishSuggestionPolicy.suggestions(for: spelling,
                knownWord: knownWord || completions.contains { $0.lowercased() == spelling.lowercased() },
                completions: completions + offline.completions, englishMode: englishMode)
            if englishMode { return words.map { Candidate(text: $0, reading: raw, consumed: raw.count) } }
            guard let word = words.first else { return found }
            return EnglishSuggestionPolicy.mergingMixedSuggestion(word, for: raw,
                into: found, hasExactPinyinReading: exactPinyin || completeNativePhrase, limit: limit)
        }
        let prefix = englishMode ? spelling : String(spelling.dropLast())
        let cached = completionProvider == nil ? spellingCache.value(for: prefix) : nil
        let eligible = spelling.count <= 32 && spelling.unicodeScalars.allSatisfy {
            $0.isASCII && CharacterSet.letters.contains($0)
        }
        let needsSpelling = eligible && (englishMode || (!knownWord && spelling.count >= 3))
        let initial = merged(cached ?? [])
        // An empty provisional result is still loading, not evidence that no
        // candidates exist. Avoid flashing an empty state before a brand arrives.
        if !initial.isEmpty || !needsSpelling || cached != nil { onInitial?(initial) }
        try Task.checkCancellation()
        if needsSpelling {
            // NSNotFound from checkSpelling also occurs after NSSpellServer
            // failure, so it cannot establish that arbitrary Pinyin is English.
            // A single shorter-prefix request can supply positive exact-word
            // and completion evidence. Nil/empty means no evidence.
            let words: [String]
            if let completionProvider { words = await completionProvider(prefix) ?? [] }
            else if let cached { words = cached }
            else {
                // The local candidates are already usable. Skip requests for
                // intermediate spellings that rapid typing immediately cancels.
                try await Task.sleep(for: .milliseconds(25))
                words = await completions(for: prefix)
            }
            try Task.checkCancellation()
            return merged(words)
        }
        return merged([])
    }
}
