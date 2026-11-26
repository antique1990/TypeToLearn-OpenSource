import Foundation

public enum KeyboardLayout: String, Codable, CaseIterable, Sendable, Identifiable {
    case pinyin, nineKey, cangjie
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .pinyin: "26 键拼音"
        case .nineKey: "九宫格拼音"
        case .cangjie: "仓颉五代"
        }
    }
    public var shortTitle: String {
        switch self {
        case .pinyin: "全拼"
        case .nineKey: "九宫格"
        case .cangjie: "仓颉"
        }
    }
}

public enum ChineseScript: String, Codable, CaseIterable, Sendable, Identifiable {
    case simplified, traditional
    public var id: String { rawValue }
    public var title: String { self == .simplified ? "简体中文" : "繁體中文" }
    public var languageID: String { self == .simplified ? "zh-Hans" : "zh-Hant" }
}

public enum KeyboardAudience: String, Codable, CaseIterable, Sendable, Identifiable {
    case chinese, english
    public var id: String { rawValue }
    public var isEnglishOnly: Bool { self == .english }
    public var interfaceLocale: String { isEnglishOnly ? "en" : "zh-Hans" }
    public var title: String { isEnglishOnly ? "英文用户" : "中文用户" }
}

public enum KeyboardHapticStrength: String, Codable, CaseIterable, Sendable, Identifiable {
    case light, medium, strong
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .light: "轻"
        case .medium: "中"
        case .strong: "强"
        }
    }
}

public enum KeyboardSoundStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    case system, crisp, soft, mechanical
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .system: "仿系统"
        case .crisp: "清脆"
        case .soft: "轻柔"
        case .mechanical: "机械"
        }
    }
}

public struct KeyboardSettings: Codable, Equatable, Sendable {
    public var audience: KeyboardAudience = .chinese
    public var layout: KeyboardLayout = .pinyin
    public var script: ChineseScript = .simplified
    public var fuzzyPinyinEnabled = true
    public var targetLanguageID: String = "es"
    public var englishTargetLanguageID: String = "zh-Hans"
    public var translationEnabled = true
    public var wrapCandidateTranslations = false
    public var keySoundEnabled = false
    public var keySoundStyle: KeyboardSoundStyle = .crisp
    public var keySoundVolume = 0.75
    public var keyHapticsEnabled = false
    public var keyHapticStrength: KeyboardHapticStrength = .medium
    public var revision = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case audience, layout, script, fuzzyPinyinEnabled, targetLanguageID, englishTargetLanguageID
        case translationEnabled, wrapCandidateTranslations
        case keySoundEnabled, keySoundStyle, keySoundVolume, keyHapticsEnabled, keyHapticStrength, revision
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        audience = try values.decodeIfPresent(KeyboardAudience.self, forKey: .audience) ?? .chinese
        layout = try values.decodeIfPresent(KeyboardLayout.self, forKey: .layout) ?? .pinyin
        script = try values.decodeIfPresent(ChineseScript.self, forKey: .script) ?? .simplified
        fuzzyPinyinEnabled = try values.decodeIfPresent(Bool.self, forKey: .fuzzyPinyinEnabled) ?? true
        targetLanguageID = try values.decodeIfPresent(String.self, forKey: .targetLanguageID) ?? "es"
        englishTargetLanguageID = try values.decodeIfPresent(String.self, forKey: .englishTargetLanguageID) ?? "zh-Hans"
        translationEnabled = try values.decodeIfPresent(Bool.self, forKey: .translationEnabled) ?? true
        wrapCandidateTranslations = try values.decodeIfPresent(Bool.self, forKey: .wrapCandidateTranslations) ?? false
        keySoundEnabled = try values.decodeIfPresent(Bool.self, forKey: .keySoundEnabled) ?? false
        keySoundStyle = try values.decodeIfPresent(KeyboardSoundStyle.self, forKey: .keySoundStyle) ?? .crisp
        keySoundVolume = min(max(try values.decodeIfPresent(Double.self, forKey: .keySoundVolume) ?? 0.75, 0), 1)
        keyHapticsEnabled = try values.decodeIfPresent(Bool.self, forKey: .keyHapticsEnabled) ?? false
        keyHapticStrength = try values.decodeIfPresent(KeyboardHapticStrength.self, forKey: .keyHapticStrength) ?? .medium
        revision = try values.decodeIfPresent(UUID.self, forKey: .revision) ?? Self().revision
    }
}

public struct Candidate: Identifiable, Equatable, Sendable {
    public let text: String
    public let reading: String
    public let consumed: Int
    public let engineIndex: Int?
    // Query-only metadata. Actual selection still resolves native consumption.
    public internal(set) var coversFullInput: Bool? = nil
    public var id: String { "\(text)|\(consumed)|\(reading)" }
    public init(text: String, reading: String, consumed: Int, engineIndex: Int? = nil) {
        self.text = text
        self.reading = reading
        self.consumed = consumed
        self.engineIndex = engineIndex
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        // Optional query metadata does not change a selectable candidate's identity.
        lhs.text == rhs.text && lhs.reading == rhs.reading && lhs.consumed == rhs.consumed &&
            lhs.engineIndex == rhs.engineIndex
    }
}

public enum KeyCoding {
    public static let cangjieRoots = Dictionary(uniqueKeysWithValues:
        zip(Array("abcdefghijklmnopqrstuvwxyz"), Array("日月金木水火土竹戈十大中一弓人心手口尸廿山女田難卜重")))

    public static func nineKey(_ letters: String) -> String {
        let groups = ["abc", "def", "ghi", "jkl", "mno", "pqrs", "tuv", "wxyz"]
        return letters.lowercased().compactMap { letter in
            groups.firstIndex(where: { $0.contains(letter) }).map { String($0 + 2) }
        }.joined()
    }

    /// A readable provisional preedit while the nine-key lexicon is resolving.
    /// Never expose numeric codes or a placeholder in the host text field.
    public static func nineKeyFallback(_ digits: String) -> String {
        let letters: [Character: Character] = ["2": "a", "3": "e", "4": "i", "5": "l",
                                              "6": "n", "7": "s", "8": "t", "9": "y"]
        return String(digits.compactMap { letters[$0] })
    }

    public static func display(_ input: String, layout: KeyboardLayout) -> String {
        layout == .cangjie ? input.map { String(cangjieRoots[$0] ?? $0) }.joined(separator: " ") : input
    }
}
