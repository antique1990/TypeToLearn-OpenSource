import KeyboardCore
import SwiftUI
import Translation

@MainActor
final class OnboardingModel: ObservableObject {
    enum DownloadStatus: Equatable { case idle, checking, requesting, downloading, ready, failed }

    @Published var state: OnboardingState { didSet { persist() } }
    @Published var isPresented = false
    @Published private(set) var languages: [LearningLanguage] = []
    @Published private(set) var loading = false
    @Published private(set) var languageLoadFailed = false
    @Published private(set) var downloadStatus: DownloadStatus = .idle
    @Published var configuration: TranslationSession.Configuration?
    @Published var message: String?
    @Published var previewRevision = 0
    private let systemLocale: OnboardingLocale
    var locale: OnboardingLocale { systemLocale.resolved(for: state.audience) }
    private let storage: UserDefaults
    private let storageKey: String
    private var catalogRevision = UUID()
    private var selectionRevision = UUID()
    private var requestPair: String?
    private var refreshing = false

    init() {
        storage = .standard
        let arguments = ProcessInfo.processInfo.arguments
        var testStore = false
        #if DEBUG
        testStore = arguments.contains("--onboarding-test-store")
        #endif
        storageKey = testStore ? "onboarding.test.v1" : "onboarding.v1"
        systemLocale = OnboardingLocale(preferredLanguages: Locale.preferredLanguages)
        #if DEBUG
        if testStore && arguments.contains("--reset-onboarding") { storage.removeObject(forKey: storageKey) }
        #endif
        if let data = storage.data(forKey: storageKey),
           let restored = try? JSONDecoder().decode(OnboardingState.self, from: data) {
            state = restored
        } else {
            var initial = OnboardingState()
            initial.script = systemLocale == .traditional ? .traditional : .simplified
            // Existing installs already have shared settings; onboarding stays replayable.
            if !testStore, let url = SharedSettings.container?.appendingPathComponent("settings.json"),
               FileManager.default.fileExists(atPath: url.path) { initial.completed = true }
            state = initial
        }
        isPresented = !state.completed
        persist()
    }

    var selectedLanguage: LearningLanguage? { languages.first { $0.id == state.targetLanguageID } }
    var canContinue: Bool { downloadStatus == .ready || state.hasRequestedSelectedPair }
    var isRequesting: Bool { downloadStatus == .requesting }
    var hasPendingDownload: Bool { state.hasRequestedSelectedPair && downloadStatus != .ready }

    func t(_ simplified: String, _ traditional: String, _ english: String) -> String {
        locale.text(simplified, traditional, english)
    }

    func languageName(_ id: String) -> String {
        Locale(identifier: locale.rawValue).localizedString(forIdentifier: id) ?? id
    }

    func chooseAudience(_ audience: KeyboardAudience) {
        guard !isRequesting else { return }
        state.chooseAudience(audience)
        invalidateSelection()
    }

    func selectLanguage(_ language: LearningLanguage) {
        guard !isRequesting else { return }
        if state.targetLanguageID != language.id {
            state.targetLanguageID = language.id
            invalidateSelection()
        }
        previewRevision += 1
        Task { await refreshSelectedStatus() }
    }

    private func invalidateSelection() {
        selectionRevision = UUID()
        downloadStatus = .idle
        message = nil
    }

    func restart(settings: KeyboardSettings) {
        var fresh = OnboardingState()
        fresh.audience = settings.audience
        fresh.script = settings.script
        fresh.requestedPairs = state.requestedPairs
        state = fresh
        invalidateSelection()
        isPresented = true
    }

    func saveSelection(to app: AppModel) -> Bool {
        let settings = state.applying(to: app.settings)
        do {
            try SharedSettings.save(settings)
            app.settings = settings
            return true
        } catch {
            message = t("设置保存失败，请重试。", "設定儲存失敗，請重試。", "Could not save your settings. Please try again.")
            return false
        }
    }

    func finish(app: AppModel) {
        guard saveSelection(to: app) else { return }
        state.completed = true
        isPresented = false
    }

    func loadLanguages() async {
        guard state.audience != nil else { return }
        let revision = UUID()
        catalogRevision = revision
        let sourceID = state.sourceID
        let localeID = locale.rawValue
        loading = true
        languageLoadFailed = false
        let result = await AppModel.catalog(sourceID: sourceID, localeID: localeID)
        guard !Task.isCancelled, revision == catalogRevision, sourceID == state.sourceID, localeID == locale.rawValue else { return }
        let preferred = state.audience == .english ? ["zh-Hans", "ja", "es", "th"] : ["en", "ja", "ko", "th"]
        languages = result.sorted {
            let first = preferred.firstIndex(of: $0.id) ?? Int.max
            let second = preferred.firstIndex(of: $1.id) ?? Int.max
            return first == second ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : first < second
        }
        loading = false
        languageLoadFailed = result.isEmpty
        await refreshSelectedStatus()
    }

    func requestDownload(_ language: LearningLanguage) {
        guard !isRequesting else { return }
        selectLanguage(language)
        selectionRevision = UUID()
        guard let pair = state.pair else { return }
        requestPair = pair
        downloadStatus = .requesting
        message = nil
        let source = Locale.Language(identifier: state.sourceID)
        let target = Locale.Language(identifier: language.id)
        if var existing = configuration, existing.source == source, existing.target == target {
            existing.invalidate()
            configuration = existing
        } else { configuration = .init(source: source, target: target) }
    }

    nonisolated func prepare(using session: TranslationSession) async {
        let pair = await MainActor.run { requestPair }
        guard let pair else { return }
        do {
            try await session.prepareTranslation()
            try Task.checkCancellation()
            await MainActor.run {
                state.requestedPairs.insert(pair)
                if pair == state.pair { downloadStatus = .downloading }
            }
            await refreshSelectedStatus()
        } catch {
            await MainActor.run {
                guard pair == state.pair else { return }
                downloadStatus = .failed
                message = t("下载尚未完成。请检查网络，点击下载重试。", "下載尚未完成。請檢查網路，點擊下載重試。", "Download is not complete. Check your connection and tap Download to retry.")
            }
        }
    }

    func refreshSelectedStatus() async {
        guard let target = state.targetLanguageID, state.audience != nil,
              !isRequesting, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let source = state.sourceID
        let revision = selectionRevision
        if downloadStatus == .idle { downloadStatus = .checking }
        let status = await TranslationService.availability().status(
            from: Locale.Language(identifier: source), to: Locale.Language(identifier: target))
        guard !Task.isCancelled, revision == selectionRevision else { return }
        if let index = languages.firstIndex(where: { $0.id == target }) {
            languages[index].installed = status == .installed
        }
        switch status {
        case .installed:
            do {
                let sample = state.audience == .english ? "How are you?" : (state.script == .traditional ? "你好嗎？" : "你好吗？")
                _ = try await TranslationService().translate([sample], sourceID: source, targetID: target)
                guard !Task.isCancelled, revision == selectionRevision else { return }
                downloadStatus = .ready
                message = nil
            } catch {
                guard !Task.isCancelled, revision == selectionRevision else { return }
                downloadStatus = .failed
                message = t("语言包还未就绪，请点击下载重新检查。", "語言包尚未就緒，請點擊下載重新檢查。", "The language pack is not ready. Tap Download to check again.")
            }
        case .supported:
            if downloadStatus != .failed {
                downloadStatus = state.hasRequestedSelectedPair ? .downloading : .idle
            }
        case .unsupported:
            downloadStatus = .failed
            message = t("系统暂不支持这组语言，请选择其他学习语言。", "系統暫不支援這組語言，請選擇其他學習語言。", "This language pair is unavailable. Choose another learning language.")
        @unknown default: downloadStatus = .failed
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(state) { storage.set(data, forKey: storageKey) }
    }
}
