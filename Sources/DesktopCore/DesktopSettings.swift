import Foundation
import KeyboardCore

public enum DesktopTranslationProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    case apple, siliconFlow
    public var id: String { rawValue }
    public var title: String { self == .apple ? "Apple 本机翻译" : "硅基流动" }
}

public enum DesktopCandidateStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    case horizontal, vertical
    public var id: String { rawValue }
    public var title: String { self == .horizontal ? "紧凑横条" : "展开列表" }
}

public struct DesktopSettings: Codable, Equatable, Sendable {
    public var layout: KeyboardLayout = .pinyin
    public var script: ChineseScript = .simplified
    public var english = false
    public var targetLanguage = "en"
    public var englishTargetLanguage = "zh-Hans"
    public var translationEnabled = true
    public var provider: DesktopTranslationProvider = .apple
    public var cloudConsent = false
    public var cloudModelPreference: SiliconFlowModel?
    public var cloudModel: SiliconFlowModel {
        get { cloudModelPreference ?? .qwen25_32B }
        set { cloudModelPreference = newValue }
    }
    // Optional backing storage keeps existing settings readable after this upgrade.
    public var candidateStyle: DesktopCandidateStyle?
    public var candidateLayout: DesktopCandidateStyle {
        get { candidateStyle ?? .horizontal }
        set { candidateStyle = newValue }
    }
    public var fuzzyPinyinPreference: PinyinFuzzyOptions?
    public var fuzzyPinyinOptions: PinyinFuzzyOptions {
        get { fuzzyPinyinPreference ?? .retroflex }
        set { fuzzyPinyinPreference = newValue }
    }
    public var revision = UUID()
    public init() {}
    public var sourceLanguage: String { english ? "en" : script.languageID }
    public var destinationLanguage: String { english ? englishTargetLanguage : targetLanguage }
}

/// Only the Mac targets depend on this store; iPhone's App Group is unchanged.
public enum DesktopSettingsStore {
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TypeToLearnMacDebug", isDirectory: true)
    }
    public static var learnedURL: URL { directory.appendingPathComponent("learned-words.json") }
    public static func load() -> DesktopSettings {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("settings.json")),
              let settings = try? JSONDecoder().decode(DesktopSettings.self, from: data) else {
            return DesktopSettings()
        }
        return settings
    }
    public static func save(_ settings: DesktopSettings) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var copy = settings
        copy.revision = UUID()
        try JSONEncoder().encode(copy).write(to: directory.appendingPathComponent("settings.json"), options: .atomic)
    }
}
