import Foundation

public enum OnboardingLocale: String, Codable, CaseIterable, Sendable {
    case simplified = "zh-Hans", traditional = "zh-Hant", english = "en"

    public init(preferredLanguages: [String]) {
        let language = Locale.Language(identifier: preferredLanguages.first ?? "en")
        if language.languageCode?.identifier == "zh" {
            self = language.script?.identifier == "Hant" ? .traditional : .simplified
        } else { self = .english }
    }

    public func resolved(for audience: KeyboardAudience?) -> OnboardingLocale {
        audience == .english ? .english : self
    }

    public func text(_ simplified: String, _ traditional: String, _ english: String) -> String {
        switch self {
        case .simplified: simplified
        case .traditional: traditional
        case .english: english
        }
    }
}

public struct OnboardingState: Codable, Equatable, Sendable {
    public enum Step: Int, Codable, CaseIterable, Sendable { case audience, language, enable }
    public var step: Step = .audience
    public var audience: KeyboardAudience?
    public var targetLanguageID: String?
    public var script: ChineseScript = .simplified
    public var requestedPairs: Set<String> = []
    public var completed = false
    public init() {}

    public var sourceID: String { audience == .english ? "en" : script.languageID }
    public var pair: String? { targetLanguageID.map { "\(sourceID)>\($0)" } }
    public var hasRequestedSelectedPair: Bool { pair.map { requestedPairs.contains($0) } ?? false }

    public mutating func chooseAudience(_ value: KeyboardAudience) {
        if audience != value { targetLanguageID = nil }
        audience = value
    }

    public func applying(to settings: KeyboardSettings) -> KeyboardSettings {
        var copy = settings
        guard let audience else { return copy }
        copy.audience = audience
        if audience == .english {
            if let targetLanguageID { copy.englishTargetLanguageID = targetLanguageID }
        } else {
            copy.script = script
            if let targetLanguageID { copy.targetLanguageID = targetLanguageID }
        }
        return copy
    }
}

/// Compatibility entry point for the first curated demonstration.
public enum OnboardingSample {
    public static func translation(for identifier: String) -> String? {
        KeyboardDemo.translation(0, language: identifier)
    }
}
