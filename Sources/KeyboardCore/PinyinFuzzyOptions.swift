import Foundation

/// Explicit sound-pair preferences. Unknown bits are discarded before they can
/// affect a schema name or generated spelling rules.
public struct PinyinFuzzyOptions: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue & 255 }
    public static let zZh = Self(rawValue: 1)
    public static let cCh = Self(rawValue: 2)
    public static let sSh = Self(rawValue: 4)
    public static let nL = Self(rawValue: 8)
    public static let fH = Self(rawValue: 16)
    public static let anAng = Self(rawValue: 32)
    public static let enEng = Self(rawValue: 64)
    public static let inIng = Self(rawValue: 128)
    public static let retroflex: Self = [.zZh, .cCh, .sSh]
    public static let all = Self(rawValue: 255)

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(Int.self))
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    // These operate on whole syllables after Rime has generated strict
    // abbreviations. An alias must never rewrite one of those abbreviations.
    var algebra: [String] {
        var rules: [String] = []
        for (option, short) in [(Self.zZh, "z"), (.cCh, "c"), (.sSh, "s")] where contains(option) {
            rules += ["derive/^\(short)h(?=.)/\(short)/", "derive/^\(short)([^h])/\(short)h$1/"]
        }
        for (option, first, second) in [(Self.nL, "n", "l"), (.fH, "f", "h")] where contains(option) {
            rules += ["derive/^\(first)(?=.)/\(second)/", "derive/^\(second)(?=.)/\(first)/"]
        }
        // an/ang includes the ian/iang and uan/uang finals naturally.
        for (option, short) in [(Self.anAng, "an"), (.enEng, "en"), (.inIng, "in")] where contains(option) {
            rules += ["derive/\(short)$/\(short)g/", "derive/\(short)g$/\(short)/"]
        }
        return rules
    }
}

public enum PinyinQueryPolicy: Hashable, Sendable {
    /// Preserve the existing behavior for callers that do not opt in.
    case legacy
    case configured(PinyinFuzzyOptions)
    /// iPhone loads one of the two bundled schemas without runtime deployment.
    case mobile(fuzzy: Bool)

    var fuzzyOptions: PinyinFuzzyOptions? {
        switch self {
        case .legacy: nil
        case .configured(let options): options
        case .mobile(let enabled): enabled ? .all : []
        }
    }
}
