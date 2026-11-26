import AppKit
import Carbon
import SwiftUI
import Translation
import DesktopCore
import KeyboardCore

struct MacLanguage: Identifiable, Sendable {
    let id: String
    let name: String
    let installed: Bool
}

@MainActor
final class MacAppModel: ObservableObject {
    @Published var settings = DesktopSettingsStore.load()
    @Published var languages: [MacLanguage] = []
    @Published var status = "选择翻译来源，再检查语言或连接。"
    @Published var error: String?
    @Published var busy = false
    @Published var loadingLanguages = false
    @Published var apiKey = ""
    @Published var hasKey = false
    @Published var sample = "你好，很高兴认识你。"
    @Published var translation = ""
    @Published var configuration: TranslationSession.Configuration?
    @Published var installed = FileManager.default.fileExists(atPath: MacKeychain.inputMethodURL.path)
    @Published var testText = ""
    private let translator = MacTranslator()
    private var catalogToken = UUID()
    private var operation = UUID()
    private var preparationSettings: DesktopSettings?
    private var preparationText = ""
    // Keep an invalidatable configuration across resets: assigning nil and then
    // an equal configuration in one run loop does not restart translationTask.
    private var lastLocalConfiguration: TranslationSession.Configuration?
    private var testTask: Task<Void, Never>?

    var selectedLanguage: String {
        get { settings.destinationLanguage }
        set {
            if settings.english { settings.englishTargetLanguage = newValue }
            else { settings.targetLanguage = newValue }
        }
    }
    var localLanguageStatus: String {
        if loadingLanguages { return "正在检查本机语言资源…" }
        guard let language = languages.first(where: { $0.id == selectedLanguage }) else {
            return "系统暂不支持这组语言。"
        }
        return language.installed ? "源语言和目标语言已下载，可在本机翻译。" : "语言资源尚未下载；测试时会请求下载，下载完成后才能显示译文。"
    }
    func refreshKeyStatus() { hasKey = (try? MacKeychain.load()) != nil }
    func save() {
        operation = UUID(); testTask?.cancel(); translator.reset()
        configuration = nil; preparationSettings = nil; busy = false
        translation = ""
        do {
            try DesktopSettingsStore.save(settings)
            settings = DesktopSettingsStore.load()
            error = nil
            status = "设置已保存，输入法将在下一段输入时使用新设置。"
        } catch { self.error = error.localizedDescription }
    }
    func saveKey() {
        do { try MacKeychain.save(apiKey); apiKey = ""; refreshKeyStatus(); save(); status = "API Key 已保存到系统钥匙串。" }
        catch { self.error = error.localizedDescription }
    }
    func removeKey() {
        do { try MacKeychain.remove(); hasKey = false; apiKey = ""; save(); status = "API Key 已从钥匙串删除。" }
        catch { self.error = error.localizedDescription }
    }
    func loadLanguages() async {
        let token = UUID(); catalogToken = token; loadingLanguages = true
        if settings.provider == .siliconFlow {
            // Qwen's language set is independent of Apple's downloaded-language list.
            let ids = ["en", "zh-Hans", "zh-Hant", "es", "fr", "de", "it", "pt", "ja", "ko", "ru", "ar", "th", "vi", "id", "hi", "tr", "nl", "pl", "uk"]
            languages = ids.filter { $0 != settings.sourceLanguage }.map {
                MacLanguage(id: $0, name: Locale(identifier: "zh-Hans").localizedString(forIdentifier: $0) ?? $0, installed: false)
            }
            loadingLanguages = false
            return
        }
        let output = await Self.catalog(sourceID: settings.sourceLanguage)
        guard token == catalogToken, !Task.isCancelled else { return }
        languages = output
        loadingLanguages = false
    }
    nonisolated private static func catalog(sourceID: String) async -> [MacLanguage] {
        let availability = TranslationService.availability()
        let values = await availability.supportedLanguages
        let source = Locale.Language(identifier: sourceID)
        var output: [MacLanguage] = []
        for language in values {
            let pair = await availability.status(from: source, to: language)
            if Task.isCancelled { return [] }
            if pair != .unsupported {
                let raw = language.minimalIdentifier
                let id = raw == "zh" ? "zh-Hans" : raw == "zh-TW" ? "zh-Hant" : raw
                output.append(MacLanguage(id: id,
                    name: Locale(identifier: "zh-Hans").localizedString(forIdentifier: id) ?? id,
                    installed: pair == .installed))
            }
        }
        return output.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func prepareLanguages() {
        save()
        guard error == nil else { return }
        startLocalTranslation(settings.english ? "Hello" : "你好")
    }
    private func startLocalTranslation(_ text: String) {
        busy = true
        preparationSettings = settings
        preparationText = text
        status = "正在准备本机翻译；如需语言资源，请在系统提示中允许下载。"
        let source = Locale.Language(identifier: settings.sourceLanguage)
        let target = Locale.Language(identifier: settings.destinationLanguage)
        var next: TranslationSession.Configuration
        if var previous = lastLocalConfiguration {
            previous.source = source; previous.target = target
            previous.invalidate()
            next = previous
        } else if #available(macOS 26.4, *) {
            next = .init(source: source, target: target, preferredStrategy: .lowLatency)
        } else { next = .init(source: source, target: target) }
        lastLocalConfiguration = next
        configuration = next
    }
    nonisolated func prepare(using session: TranslationSession) async {
        let (snapshot, token, text) = await MainActor.run { (preparationSettings, operation, preparationText) }
        guard let snapshot else { return }
        do {
            try await session.prepareTranslation()
            // prepareTranslation may return while the download is still in
            // progress. A real translation waits for usable models.
            let response = try await session.translate(text)
            guard !response.targetText.isEmpty else { throw TranslationService.Failure.emptyResponse }
            try Task.checkCancellation()
            await MainActor.run {
                guard token == operation else { return }
                translation = response.targetText
                status = "设置窗口已返回译文，正在验证输入法的本机翻译会话…"
            }
            let independent = await TranslationService()
            let result = try await independent.translate([text], sourceID: snapshot.sourceLanguage, targetID: snapshot.destinationLanguage)
            await independent.releaseResources()
            guard let result = result[text], !result.isEmpty else { throw TranslationService.Failure.emptyResponse }
            await MainActor.run {
                guard token == operation else { return }
                translation = result
                status = "本机翻译已验证，输入法可使用这些语言资源。"
                error = nil
                busy = false
            }
        } catch {
            let message = error.localizedDescription
            await MainActor.run {
                guard token == operation else { return }
                self.error = "本机翻译尚未就绪：\(message) 如下载未完成，请在「系统语言设置」中完成源语言和目标语言的下载后重试。"
                busy = false
            }
        }
        await loadLanguages()
    }
    func testTranslation() {
        save()
        guard error == nil else { return }
        let text = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 256 else { error = "请输入 1–256 个字符。"; return }
        if settings.provider == .apple {
            startLocalTranslation(text)
            return
        }
        let snapshot = settings; let token = operation
        busy = true; status = "正在翻译…"
        testTask = Task {
            do {
                var enabled = snapshot; enabled.translationEnabled = true
                let result = try await translator.translate([text], settings: enabled, onProgress: { [weak self] progress in
                    guard let self, token == operation, !Task.isCancelled else { return }
                    switch progress {
                    case .requesting: status = "正在翻译…"
                    case .retrying: status = "请求暂时失败，正在自动重试（1/1）…"
                    }
                })
                guard token == operation, !Task.isCancelled else { return }
                translation = result[text] ?? ""
                status = "\(snapshot.provider.title)已返回译文。"
            } catch {
                guard token == operation, !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            if token == operation { busy = false }
        }
    }
    func installInputMethod() {
        guard let source = Bundle.main.resourceURL?.appendingPathComponent("InputMethods/TypeToLearnInputMethod.app"),
              FileManager.default.fileExists(atPath: source.path) else { error = "构建中缺少输入法组件，请重新构建 Mac Scheme。"; return }
        do {
            let destination = MacKeychain.inputMethodURL
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                // Keep the prior development build recoverable; don't kill an active input session.
                let backups = DesktopSettingsStore.directory.appendingPathComponent("PreviousBuilds")
                try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: destination, to: backups.appendingPathComponent("\(UUID()).app"))
            }
            try FileManager.default.copyItem(at: source, to: destination)
            let registration = TISRegisterInputSource(destination as CFURL)
            guard registration == noErr else { error = "组件已复制，但系统注册返回 \(registration)。请注销并重新登录后检查输入法列表。"; return }
            installed = true
            status = "输入法已安装。请在系统设置的输入法列表中添加「伴语」。首次安装可能需要注销后重新登录。"
        } catch { self.error = error.localizedDescription }
    }
    func openKeyboardSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }
    func openLanguageSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!)
    }
}
