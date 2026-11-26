import Foundation

/// Owns only the uncommitted code. Never deletes host-app text while a code is active.
public struct Composition: Equatable, Sendable {
    public private(set) var input = ""
    public private(set) var cursor = 0
    public private(set) var layout: KeyboardLayout
    public static let maximumLength = 256

    public init(layout: KeyboardLayout = .pinyin) { self.layout = layout }

    @discardableResult
    public mutating func append(_ key: String) -> Bool {
        let allowed = layout == .nineKey ? "23456789" : "abcdefghijklmnopqrstuvwxyz'"
        let lower = key.lowercased()
        guard !lower.isEmpty, lower.allSatisfy({ allowed.contains($0) }),
              input.count + lower.count <= Self.maximumLength,
              layout != .cangjie || (input.count + lower.count <= 5 && !lower.contains("'"))
        else { return false }
        let insertion = input.index(input.startIndex, offsetBy: cursor)
        if lower == "'" {
            guard cursor > 0, input[input.index(before: insertion)] != "'",
                  insertion == input.endIndex || input[insertion] != "'" else { return false }
        }
        input.insert(contentsOf: lower, at: insertion)
        cursor += lower.count
        return true
    }

    /// Returns true only when the host application should receive a backspace.
    public mutating func backspace() -> Bool {
        guard !input.isEmpty else { return true }
        // At the beginning of marked text, never delete committed host text.
        guard cursor > 0 else { return false }
        input.remove(at: input.index(input.startIndex, offsetBy: cursor - 1))
        cursor -= 1
        return false
    }

    public mutating func moveCursor(by offset: Int) {
        cursor += min(input.count - cursor, max(-cursor, offset))
    }

    public mutating func clear() { input = ""; cursor = 0 }

    public mutating func switchLayout(_ layout: KeyboardLayout) {
        self.layout = layout
        clear()
    }

    public mutating func commit(_ candidate: Candidate) -> String? {
        guard !input.isEmpty, candidate.consumed > 0, candidate.consumed <= input.count else { return nil }
        let remainder = String(input.dropFirst(candidate.consumed))
        let leadingSeparators = remainder.prefix(while: { $0 == "'" }).count
        input = remainder.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
        cursor = min(input.count, max(0, cursor - candidate.consumed - leadingSeparators))
        return candidate.text
    }
}
