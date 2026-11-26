import SwiftUI
import Translation
import KeyboardCore

struct LearningLanguage: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let nativeName: String
    var installed: Bool
}

@MainActor
final class AppModel: ObservableObject {
    @Published var settings = SharedSettings.load()
    @Published var languages: [LearningLanguage] = []
    @Published var englishLanguages: [LearningLanguage] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var languageError: String?
    @Published var preparationStatus: String?
    @Published var englishPreparationStatus: String?
    @Published var preparing = false
    @Published var preparation: TranslationSession.Configuration?
    @Published var learnedWords = LearnedWords()
    private var loadingRevision = UUID()
    private var preparingSourceID: String?
    private var preparingTargetID: String?
    private var preparingSample = "你好"
    private var preparingEnglish = false

    func text(_ value: String) -> String { settings.audience.text(value) }

    var selectedLanguage: LearningLanguage? { languages.first { $0.id == settings.targetLanguageID } }
    var selectedEnglishLanguage: LearningLanguage? { englishLanguages.first { $0.id == settings.englishTargetLanguageID } }
    private var learnedURL: URL? { SharedSettings.container?.appendingPathComponent("learned-words.json") }

    func loadLearnedWords() {
        if let learnedURL { learnedWords = LearnedWords.load(from: learnedURL) }
    }

    func deleteLearnedWord(_ id: UUID) {
        guard let learnedURL else { return }
        var updated = learnedWords
        updated.remove(id)
        do { try updated.save(to: learnedURL); learnedWords = updated }
        catch { self.error = "删除词组失败：\(error.localizedDescription)"; return }
        let translationsURL = learnedURL.deletingLastPathComponent().appendingPathComponent("learned-translations.json")
        var translations = LearnedTranslations.load(from: translationsURL)
        translations.retain(texts: Set(updated.items.map(\.text)))
        do { try translations.save(to: translationsURL) }
        catch {
            try? FileManager.default.removeItem(at: translationsURL)
            if FileManager.default.fileExists(atPath: translationsURL.path) {
                self.error = "词组已删除，但译文缓存清理失败：\(error.localizedDescription)"
            }
        }
    }

    func save() {
        do { try SharedSettings.save(settings); error = nil }
        catch { self.error = text(error.localizedDescription) }
    }

    func loadLanguages() async {
        let revision = UUID()
        loadingRevision = revision
        isLoading = true
        languageError = nil
        let localeID = settings.audience.interfaceLocale
        async let chineseOutput = Self.catalog(sourceID: settings.audience.isEnglishOnly ? nil : settings.script.languageID, localeID: localeID)
        async let englishOutput = Self.catalog(sourceID: "en", localeID: localeID)
        let (output, english) = await (chineseOutput, englishOutput)
        guard revision == loadingRevision, !Task.isCancelled else { return }
        languages = output.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        englishLanguages = english.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        isLoading = false
        if !preparing, selectedLanguage?.installed != true,
           preparationStatus?.hasPrefix(self.text("离线翻译已验证")) == true {
            preparationStatus = self.text("系统语言资源已变化，请重新下载并检查。")
        }
        if !preparing, selectedEnglishLanguage?.installed != true,
           englishPreparationStatus?.hasPrefix(self.text("离线翻译已验证")) == true {
            englishPreparationStatus = self.text("系统语言资源已变化，请重新下载并检查。")
        }
        if (settings.audience.isEnglishOnly ? english.isEmpty : output.isEmpty) { languageError = self.text("系统未返回可用语言。请确认设备支持翻译，稍后重新读取。") }
    }

    nonisolated static func catalog(sourceID: String?, localeID: String) async -> [LearningLanguage] {
        guard let sourceID else { return [] }
        let source = Locale.Language(identifier: sourceID)
        let availability = TranslationService.availability()
        let supported = await availability.supportedLanguages
        var output: [LearningLanguage] = []
        for language in supported {
            if Task.isCancelled { return [] }
            let status = await availability.status(from: source, to: language)
            guard status != .unsupported else { continue }
            let id = language.minimalIdentifier
            let name = Locale(identifier: localeID).localizedString(forIdentifier: id) ?? id
            let native = Locale(identifier: id).localizedString(forIdentifier: id) ?? id
            output.append(LearningLanguage(id: id, name: name, nativeName: native, installed: status == .installed))
        }
        return output
    }

    func prepareLanguage() {
        beginPreparation(sourceID: settings.script.languageID, targetID: settings.targetLanguageID,
                         sample: "你好", english: false)
    }

    func prepareEnglishLanguage() {
        beginPreparation(sourceID: "en", targetID: settings.englishTargetLanguageID,
                         sample: "Hello", english: true)
    }

    private func beginPreparation(sourceID: String, targetID: String, sample: String, english: Bool) {
        if english { englishPreparationStatus = self.text("正在准备语言资源…") }
        else { preparationStatus = self.text("正在准备语言资源…") }
        preparingSourceID = sourceID
        preparingTargetID = targetID
        preparingSample = sample
        preparingEnglish = english
        preparing = true
        let source = Locale.Language(identifier: sourceID)
        let target = Locale.Language(identifier: targetID)
        if var existing = preparation, existing.source == source, existing.target == target {
            existing.invalidate()
            preparation = existing
        } else {
            if #available(iOS 26.4, *) {
                preparation = TranslationSession.Configuration(source: source, target: target,
                                                               preferredStrategy: .lowLatency)
            } else {
                preparation = TranslationSession.Configuration(source: source, target: target)
            }
        }
    }

    nonisolated func prepare(using session: TranslationSession) async {
        let (sourceID, targetID, sample, english) = await MainActor.run {
            (preparingSourceID ?? settings.script.languageID, preparingTargetID ?? settings.targetLanguageID,
             preparingSample, preparingEnglish)
        }
        do {
            try await session.prepareTranslation()
            // prepareTranslation may return while models are still downloading.
            // Require a real translation and an independent installed-model session.
            await MainActor.run {
                if english { englishPreparationStatus = self.text("正在下载并验证离线翻译，请保持 App 打开…") }
                else { preparationStatus = self.text("正在下载并验证离线翻译，请保持 App 打开…") }
            }
            _ = try await session.translate(sample)
            try Task.checkCancellation()
            let check = await TranslationService()
            let result = try await check.translate([sample], sourceID: sourceID, targetID: targetID)
            guard let translated = result[sample], !translated.isEmpty else { throw TranslationService.Failure.emptyResponse }
            await MainActor.run {
                if english { englishPreparationStatus = "\(text("离线翻译已验证")): \(sample) → \(translated)" }
                else { preparationStatus = "\(text("离线翻译已验证")): \(sample) → \(translated)" }
                preparing = false
            }
            await loadLanguages()
        } catch {
            guard !Task.isCancelled else {
                await MainActor.run {
                    preparing = false
                    if english { englishPreparationStatus = self.text("验证已中断，请重新检查语言资源。") }
                    else { preparationStatus = self.text("验证已中断，请重新检查语言资源。") }
                }
                return
            }
            TranslationDiagnostics.record(error: error, source: sourceID, target: targetID)
            await MainActor.run {
                let message = (error as? TranslationService.Failure)?.localizedDescription
                    ?? self.text("语言资源尚未就绪，请完成系统下载后重试。")
                if english { englishPreparationStatus = text(message) }
                else { preparationStatus = text(message) }
                preparing = false
            }
            await loadLanguages()
        }
    }
}
