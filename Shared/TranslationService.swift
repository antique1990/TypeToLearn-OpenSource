import KeyboardCore
import Foundation
import Translation

@MainActor
final class TranslationService {
    private var cache = BoundedCache<String, String>(capacity: 384)
    private let learnedURL: URL?
    private var learnedTranslations = LearnedTranslations()
    private var session: TranslationSession?
    private var sessionKey: String?

    init(learnedURL: URL? = nil) {
        self.learnedURL = learnedURL
        if let learnedURL {
            learnedTranslations = LearnedTranslations.load(from: Self.translationsURL(for: learnedURL))
        }
    }

    private static func translationsURL(for learnedURL: URL) -> URL {
        learnedURL.deletingLastPathComponent().appendingPathComponent("learned-translations.json")
    }

    enum Failure: LocalizedError, Equatable {
        case notInstalled, unsupported, emptyResponse
        var errorDescription: String? {
            switch self {
            case .notInstalled: "请先在伴语 App 下载所选语言。"
            case .unsupported: "系统暂不支持这组语言，中文输入不受影响。"
            case .emptyResponse: "系统未返回译文，请重试。"
            }
        }
    }

    nonisolated static func availability() -> LanguageAvailability {
        if #available(iOS 26.4, macOS 26.4, *) {
            return LanguageAvailability(preferredStrategy: .lowLatency)
        }
        return LanguageAvailability()
    }

    /// Publishes each newly translated item without waiting for the rest of the batch.
    func translate(_ texts: [String], sourceID: String, targetID: String,
                   onTranslation: (@MainActor (String, String) -> Void)? = nil) async throws -> [String: String] {
        let pair = "\(sourceID)>\(targetID)"
        var result = cached(texts, sourceID: sourceID, targetID: targetID)
        var missing: [String] = []
        for text in texts where result[text] == nil && !missing.contains(text) {
            missing.append(text)
        }
        guard !missing.isEmpty else { return result }
        try Task.checkCancellation()
        let active = try await activeSession(sourceID: sourceID, targetID: targetID)
        let requests = missing.map { TranslationSession.Request(sourceText: $0, clientIdentifier: $0) }
        let learnedTexts = learnedURL.map { Set(LearnedWords.load(from: $0).items.map(\.text)) } ?? []
        var batchError: (any Error)?
        do {
            for try await response in active.translate(batch: requests) {
                try Task.checkCancellation()
                guard let text = response.clientIdentifier, missing.contains(text), !response.targetText.isEmpty else { continue }
                let value = TranslationText.correctedRomanization(response.targetText, for: text,
                    sourceID: sourceID, targetID: targetID)
                result[text] = value
                cache.insert(value, for: "\(pair)|\(text)")
                onTranslation?(text, value)
                rememberLearned(value, for: text, sourceID: sourceID,
                                targetID: targetID, learnedTexts: learnedTexts)
            }
        } catch {
            try Task.checkCancellation()
            batchError = error
        }
        try Task.checkCancellation()
        // Keep published results if the stream fails partway through. KeyboardModel
        // retries only missing items, leaving completed translations visible.
        guard missing.contains(where: { result[$0] != nil }) else { throw batchError ?? Failure.emptyResponse }
        return result
    }

    private func activeSession(sourceID: String, targetID: String) async throws -> TranslationSession {
        let pair = "\(sourceID)>\(targetID)"
        if let session, sessionKey == pair { return session }
        let source = Locale.Language(identifier: sourceID)
        let target = Locale.Language(identifier: targetID)
        let status = await Self.availability().status(from: source, to: target)
        try Task.checkCancellation()
        switch status {
        case .installed: break
        case .supported: throw Failure.notInstalled
        case .unsupported: throw Failure.unsupported
        @unknown default: throw Failure.unsupported
        }
        let active: TranslationSession
        if #available(iOS 26.4, macOS 26.4, *) {
            active = TranslationSession(installedSource: source, target: target,
                                        preferredStrategy: .lowLatency)
        } else {
            active = TranslationSession(installedSource: source, target: target)
        }
        session = active
        sessionKey = pair
        return active
    }

    func cached(_ texts: [String], sourceID: String, targetID: String) -> [String: String] {
        var result: [String: String] = [:]
        let learnedTexts: Set<String>
        if let learnedURL {
            learnedTexts = Set(LearnedWords.load(from: learnedURL).items.map(\.text))
            learnedTranslations = LearnedTranslations.load(from: Self.translationsURL(for: learnedURL))
        } else {
            learnedTexts = []
        }
        for text in texts {
            let key = "\(sourceID)>\(targetID)|\(text)"
            if let value = cache.value(for: key) {
                let corrected = TranslationText.correctedRomanization(value, for: text,
                    sourceID: sourceID, targetID: targetID)
                if corrected != value { cache.insert(corrected, for: key) }
                result[text] = corrected
            } else if let learnedURL, learnedTexts.contains(text),
                      let value = learnedTranslations.value(for: text, sourceID: sourceID, targetID: targetID) {
                let corrected = TranslationText.correctedRomanization(value, for: text,
                    sourceID: sourceID, targetID: targetID)
                if corrected != value {
                    learnedTranslations.insert(corrected, for: text, sourceID: sourceID, targetID: targetID)
                    try? learnedTranslations.save(to: Self.translationsURL(for: learnedURL))
                }
                cache.insert(corrected, for: key)
                result[text] = corrected
            }
        }
        return result
    }

    private func rememberLearned(_ translation: String, for text: String, sourceID: String,
                                 targetID: String, learnedTexts: Set<String>) {
        guard learnedTexts.contains(text), let learnedURL,
              LearnedWords.load(from: learnedURL).items.contains(where: { $0.text == text }) else { return }
        learnedTranslations.insert(translation, for: text, sourceID: sourceID, targetID: targetID)
        try? learnedTranslations.save(to: Self.translationsURL(for: learnedURL))
    }

    func cancel() {
        session?.cancel()
        session = nil
        sessionKey = nil
    }

    func releaseResources() { cancel(); cache.removeAll() }
}
