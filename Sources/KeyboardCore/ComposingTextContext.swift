import Foundation

/// Identifies the active composing text using only the proxy's bounded context.
/// No host text is persisted. Ambiguous/unavailable context ends local composition.
public struct ComposingTextContext: Sendable {
    public var text: String
    private let leading: String
    private let trailing: String

    public init(text: String, preceding: String, following: String) {
        self.text = text
        leading = String(preceding.suffix(32))
        trailing = String(following.prefix(32))
    }

    public func editingCursor(preceding: String?, following: String?, selected: String?, includingEnd: Bool = false) -> Int? {
        guard selected?.isEmpty != false, !text.isEmpty else { return nil }
        let preceding = preceding ?? ""
        let following = following ?? ""
        var matches: [Int] = []
        // The trailing boundary also represents a tap in blank space after the code.
        // It finishes composition; positions inside the code remain editable.
        for offset in 0..<(text.count + (includingEnd ? 1 : 0)) {
            let before = leading + text.prefix(offset)
            let after = text.dropFirst(offset) + trailing
            let leftMatches = before.isEmpty ? preceding.isEmpty : !preceding.isEmpty &&
                (preceding.hasSuffix(before) || before.hasSuffix(preceding))
            let rightMatches = after.isEmpty ? following.isEmpty : !following.isEmpty &&
                (following.hasPrefix(after) || after.hasPrefix(following))
            // Require the entire owned span before allowing replacement. Anchors
            // may be truncated by the proxy, but composing text may not be.
            if leftMatches && rightMatches && preceding.hasSuffix(String(text.prefix(offset))) &&
                following.hasPrefix(String(text.dropFirst(offset))) { matches.append(offset) }
        }
        return matches.count == 1 ? matches.first : nil
    }
}
