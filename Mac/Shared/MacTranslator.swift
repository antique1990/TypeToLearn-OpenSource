import Foundation
import KeyboardCore
import DesktopCore
import Translation

@MainActor
protocol MacAppleTranslationService: AnyObject {
    func translate(_ texts: [String], sourceID: String, targetID: String,
                   onTranslation: (@MainActor (String, String) -> Void)?) async throws -> [String: String]
    func cached(_ texts: [String], sourceID: String, targetID: String) -> [String: String]
    func cancel()
    func releaseResources()
}
extension TranslationService: MacAppleTranslationService {}

@MainActor
final class MacTranslator {
    /// Reuse successful translations across host input clients in this process.
    static let shared = MacTranslator()
    private let learnedURL: URL?
    private var appleServices: [LanguagePair: any MacAppleTranslationService] = [:]
    private let appleServiceFactory: @MainActor () -> any MacAppleTranslationService
    private let appleAvailability: @MainActor (String, String) async -> LanguageAvailability.Status
    private let cloud: SiliconFlowClient
    private let keyProvider: @MainActor () throws -> String?
    private var cache = BoundedCache<String, String>(capacity: 384)
    private var context: String?
    private var appleEpoch = UUID()

    init(learnedURL: URL? = DesktopSettingsStore.learnedURL,
         cloud: SiliconFlowClient = SiliconFlowClient(),
         keyProvider: @escaping @MainActor () throws -> String? = { try MacKeychain.load() },
         appleServiceFactory: (@MainActor () -> any MacAppleTranslationService)? = nil,
         appleAvailability: @escaping @MainActor (String, String) async -> LanguageAvailability.Status = { source, target in
             await TranslationService.availability().status(from: Locale.Language(identifier: source), to: Locale.Language(identifier: target))
         }) {
        self.learnedURL = learnedURL
        self.cloud = cloud
        self.keyProvider = keyProvider
        self.appleServiceFactory = appleServiceFactory ?? { TranslationService(learnedURL: learnedURL) }
        self.appleAvailability = appleAvailability
    }

    enum LocalFailure: LocalizedError {
        case languagesRequired
        case unsupported
        case incomplete
        var errorDescription: String? {
            switch self {
            case .languagesRequired:
                "本机翻译语言尚未下载。请打开伴语设置，点击「下载并验证语言」。"
            case .unsupported:
                "Apple 暂不支持这组翻译语言。请在伴语设置中选择其他目标语言。"
            case .incomplete:
                "部分候选未返回译文，请重试。"
            }
        }
    }

    func translate(_ texts: [String], settings: DesktopSettings,
                   onTranslation: (@MainActor (String, String) -> Void)? = nil) async throws -> [String: String] {
        try await translate(texts, settings: settings, onProgress: nil, onTranslation: onTranslation)
    }

    func translate(_ texts: [String], settings: DesktopSettings,
                   onProgress: (@MainActor @Sendable (SiliconFlowProgress) -> Void)?,
                   onLocalRecovery: (@MainActor () -> Void)? = nil,
                   onTranslation: (@MainActor (String, String) -> Void)? = nil) async throws -> [String: String] {
        guard settings.translationEnabled else { return [:] }
        let newContext = cacheContext(settings)
        if newContext != context { reset(); context = newContext }
        let epoch = appleEpoch
        var output: [String: String] = [:]
        var firstFailure: (any Error)?
        for group in groups(texts, settings: settings) {
            try Task.checkCancellation()
            guard context == newContext else { throw CancellationError() }
            if settings.provider == .apple { try checkAppleRequest(context: newContext, epoch: epoch) }
            do {
                let values: [String: String]
                if settings.provider == .apple {
                    let service = appleServices[group.pair] ?? appleServiceFactory()
                    appleServices[group.pair] = service
                    values = try await translateApple(group, service: service, context: newContext, epoch: epoch,
                        onRecovery: onLocalRecovery) { [weak self] text, value in
                            guard let self, !Task.isCancelled, context == newContext else { return }
                            onTranslation?(text, value)
                        }
                } else {
                    values = try await translateCloud(group.texts, pair: group.pair, settings: settings,
                                                      context: newContext, onProgress: onProgress, onTranslation: onTranslation)
                }
                try Task.checkCancellation()
                guard context == newContext else { throw CancellationError() }
                guard group.texts.allSatisfy({ values[$0]?.isEmpty == false }) else { throw LocalFailure.incomplete }
                output.merge(values, uniquingKeysWith: { _, new in new })
            } catch {
                try Task.checkCancellation()
                guard context == newContext else { throw CancellationError() }
                if firstFailure == nil { firstFailure = localError(error) }
            }
        }
        // Successful items have already been published and cached. A later
        // failure must still reach the caller so the missing items can be retried.
        if let firstFailure { throw firstFailure }
        return output
    }

    private func checkAppleRequest(context expected: String, epoch: UUID) throws {
        try Task.checkCancellation()
        guard context == expected, appleEpoch == epoch else { throw CancellationError() }
    }

    private func translateApple(_ group: Group, service: any MacAppleTranslationService,
                                context expected: String, epoch: UUID,
                                onRecovery: (@MainActor () -> Void)?,
                                onTranslation: (@MainActor (String, String) -> Void)?) async throws -> [String: String] {
        var values = service.cached(group.texts, sourceID: group.pair.source, targetID: group.pair.target)
        for attempt in 0...1 {
            try checkAppleRequest(context: expected, epoch: epoch)
            let missing = group.texts.filter { values[$0]?.isEmpty != false }
            if missing.isEmpty { return values }
            do {
                let translated = try await service.translate(missing, sourceID: group.pair.source,
                    targetID: group.pair.target) { [weak self] text, value in
                    guard let self, !Task.isCancelled, context == expected, appleEpoch == epoch,
                          missing.contains(text), !value.isEmpty, values[text] == nil else { return }
                    values[text] = value
                    onTranslation?(text, value)
                }
                try checkAppleRequest(context: expected, epoch: epoch)
                values.merge(translated, uniquingKeysWith: { _, new in new })
                guard group.texts.allSatisfy({ values[$0]?.isEmpty == false }) else { throw LocalFailure.incomplete }
                return values
            } catch {
                try checkAppleRequest(context: expected, epoch: epoch)
                // Unsupported/invalid requests and caller cancellation are not
                // service wake-up failures. Missing languages must be verified.
                guard attempt == 0, !(error is CancellationError), canRecoverApple(error) else { throw error }
                // A transient supported status during daemon startup is not
                // proof that a previously downloaded package was removed.
                // Wait for the inventory, without requesting a download.
                onRecovery?()
                var installed = false
                for _ in 0..<16 {
                    try await Task.sleep(for: .milliseconds(500))
                    try checkAppleRequest(context: expected, epoch: epoch)
                    let state = await appleAvailability(group.pair.source, group.pair.target)
                    try checkAppleRequest(context: expected, epoch: epoch)
                    if state == .installed { installed = true; break }
                    if state == .unsupported { throw LocalFailure.unsupported }
                }
                guard installed else { throw error }
                // cancel() retires the native session but keeps completed
                // translations. The next request creates a fresh session.
                service.cancel()
                try await Task.sleep(for: .milliseconds(100))
                try checkAppleRequest(context: expected, epoch: epoch)
            }
        }
        throw LocalFailure.incomplete
    }

    private func canRecoverApple(_ error: any Error) -> Bool {
        switch error {
        case TranslationService.Failure.unsupported,
             TranslationError.unsupportedSourceLanguage, TranslationError.unsupportedTargetLanguage,
             TranslationError.unsupportedLanguagePairing, TranslationError.unableToIdentifyLanguage,
             TranslationError.nothingToTranslate:
            false
        default: true
        }
    }

    private func translateCloud(_ texts: [String], pair: LanguagePair, settings: DesktopSettings,
                                context newContext: String,
                                onProgress: (@MainActor @Sendable (SiliconFlowProgress) -> Void)?,
                                onTranslation: (@MainActor (String, String) -> Void)?) async throws -> [String: String] {
        guard settings.cloudConsent else { throw CloudTranslationError.consentRequired }
        guard let key = try keyProvider(), !key.isEmpty else { throw CloudTranslationError.missingKey }
        var output: [String: String] = [:]
        var missing: [String] = []
        for text in texts {
            if let value = cache.value(for: pair.key(text)) { output[text] = value; onTranslation?(text, value) }
            else if !missing.contains(text) { missing.append(text) }
        }
        // Publish a short priority request first, then fill the other visible candidates.
        // This avoids waiting for five generated translations before showing any of them.
        let batches = missing.isEmpty ? [] : [Array(missing.prefix(1))] + stride(from: 1, to: missing.count, by: 5).map {
            Array(missing[$0..<min($0 + 5, missing.count)])
        }
        for batch in batches where !batch.isEmpty {
            try Task.checkCancellation()
            let values = try await cloud.translate(batch, source: pair.source,
                                                    target: pair.target,
                                                    model: settings.cloudModel, key: key,
                                                    onProgress: onProgress)
            try Task.checkCancellation()
            guard context == newContext else { throw CancellationError() }
            for (text, value) in values {
                cache.insert(value, for: pair.key(text)); output[text] = value; onTranslation?(text, value)
            }
        }
        return output
    }
    func cached(_ texts: [String], settings: DesktopSettings) -> [String: String] {
        guard settings.translationEnabled else { return [:] }
        let expected = cacheContext(settings)
        guard context == expected else { return [:] }
        guard settings.provider == .apple || settings.cloudConsent else { return [:] }
        var result: [String: String] = [:]
        for group in groups(texts, settings: settings) {
            if settings.provider == .apple {
                let values = appleServices[group.pair]?.cached(group.texts,
                    sourceID: group.pair.source, targetID: group.pair.target) ?? [:]
                result.merge(values, uniquingKeysWith: { _, new in new })
            } else {
                for text in group.texts {
                    if let value = cache.value(for: group.pair.key(text)) { result[text] = value }
                }
            }
        }
        return result
    }

    func translatableTexts(_ texts: [String], settings: DesktopSettings) -> [String] {
        groups(texts, settings: settings).flatMap(\.texts)
    }

    private struct LanguagePair: Hashable {
        let source: String
        let target: String
        func key(_ text: String) -> String { "\(source)>\(target)|\(text)" }
    }
    private struct Group {
        let pair: LanguagePair
        var texts: [String]
    }
    private func groups(_ texts: [String], settings: DesktopSettings) -> [Group] {
        var groups: [Group] = []
        for text in texts {
            let pair: LanguagePair
            if text.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }) {
                pair = LanguagePair(source: settings.script.languageID, target: settings.targetLanguage)
            } else if EnglishLanguageModel.isEnglishText(text) ||
                        (settings.english && text.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) })) {
                // Match the iPhone mixed-input direction: an English candidate in
                // Chinese mode teaches its Chinese meaning, not English→English.
                pair = LanguagePair(source: "en", target: settings.english ? settings.englishTargetLanguage : settings.script.languageID)
            } else { continue } // Emoji, punctuation and digits need no translation.
            if let index = groups.firstIndex(where: { $0.pair == pair }) {
                if !groups[index].texts.contains(text) { groups[index].texts.append(text) }
            } else { groups.append(Group(pair: pair, texts: [text])) }
        }
        return groups
    }
    private func localError(_ error: any Error) -> any Error {
        switch error {
        case TranslationService.Failure.notInstalled, TranslationError.notInstalled:
            return LocalFailure.languagesRequired
        case TranslationService.Failure.unsupported:
            return LocalFailure.unsupported
        default: return error
        }
    }
    private func cacheContext(_ settings: DesktopSettings) -> String {
        "\(settings.revision)|\(settings.provider)|\(settings.english)|\(settings.script.languageID)|\(settings.targetLanguage)|\(settings.englishTargetLanguage)|\(settings.cloudModel.rawValue)"
    }
    func cancelPending() { appleEpoch = UUID(); appleServices.values.forEach { $0.cancel() } }
    func reset() {
        appleEpoch = UUID()
        appleServices.values.forEach { $0.releaseResources() }
        appleServices.removeAll(); cache.removeAll(); context = nil
    }
}
