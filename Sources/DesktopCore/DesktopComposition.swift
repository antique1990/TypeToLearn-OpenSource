import Foundation
import KeyboardCore

/// A generation token prevents late lookup/translation results from editing a newer composition.
public struct DesktopComposition: Sendable {
    public private(set) var composition = Composition()
    public private(set) var generation = UUID()
    public private(set) var candidates: [Candidate] = []
    public private(set) var selected = 0
    public private(set) var english = false
    public private(set) var englishInput = ""
    private var originalInput = ""
    private var englishCursor = 0
    public private(set) var browsingSymbols = false
    private var pages: [Range<Int>] = []
    public static let pageSize = 5
    public init() {}
    public var input: String { english ? englishInput : composition.input }
    public var displayInput: String { english ? englishInput : originalInput }
    public var cursor: Int { english ? englishCursor : composition.cursor }
    private var pageIndex: Int { pages.firstIndex(where: { $0.contains(selected) }) ?? 0 }
    public var visibleRange: Range<Int> { pages.indices.contains(pageIndex) ? pages[pageIndex] : 0..<0 }
    public var pageStart: Int { visibleRange.lowerBound }
    public var visible: [Candidate] { Array(candidates[visibleRange]) }
    public var isActive: Bool { !input.isEmpty || browsingSymbols }

    /// Symbol browsing has no marked spelling and must never insert a synthetic input code.
    public mutating func presentSymbols(_ symbols: [String]) {
        clear()
        browsingSymbols = true
        candidates = symbols.map { Candidate(text: $0, reading: "", consumed: 0) }
        paginate(widths: Array(repeating: 1, count: candidates.count), availableWidth: Double(Self.pageSize))
    }

    public mutating func configure(layout: KeyboardLayout, english: Bool) {
        clear()
        composition.switchLayout(layout == .nineKey ? .pinyin : layout)
        self.english = english
    }
    @discardableResult public mutating func append(_ text: String) -> Bool {
        if browsingSymbols { clear() }
        if english {
            guard englishInput.count + text.count <= Composition.maximumLength else { return false }
            englishInput.insert(contentsOf: text, at: englishInput.index(englishInput.startIndex, offsetBy: englishCursor))
            englishCursor += text.count
        } else {
            let index = composition.cursor
            guard composition.append(text) else { return false }
            originalInput.insert(contentsOf: text, at: originalInput.index(originalInput.startIndex, offsetBy: index))
        }
        invalidate()
        return true
    }
    public mutating func backspace() {
        if english {
            if englishCursor > 0 {
                englishInput.remove(at: englishInput.index(englishInput.startIndex, offsetBy: englishCursor - 1))
                englishCursor -= 1
            }
        } else {
            if composition.cursor > 0 {
                originalInput.remove(at: originalInput.index(originalInput.startIndex, offsetBy: composition.cursor - 1))
            }
            _ = composition.backspace()
        }
        invalidate()
    }
    public mutating func deleteForward() {
        guard cursor < input.count else { return }
        if english {
            englishInput.remove(at: englishInput.index(englishInput.startIndex, offsetBy: englishCursor))
        } else {
            originalInput.remove(at: originalInput.index(originalInput.startIndex, offsetBy: composition.cursor))
            composition.moveCursor(by: 1)
            _ = composition.backspace()
        }
        invalidate()
    }
    public mutating func moveCursor(_ offset: Int) {
        if english { englishCursor += min(englishInput.count - englishCursor, max(-englishCursor, offset)) }
        else { composition.moveCursor(by: offset) }
    }
    public mutating func moveSelection(_ offset: Int) {
        selected = min(max(0, selected + offset), max(0, candidates.count - 1))
    }
    public mutating func highlight(_ index: Int) {
        guard candidates.indices.contains(index) else { return }
        selected = index
    }
    public var canPageBackward: Bool { pageIndex > 0 }
    public var canPageForward: Bool { pageIndex + 1 < pages.count }
    public mutating func movePage(_ direction: Int) {
        guard direction != 0 else { return }
        let next = pageIndex + (direction > 0 ? 1 : -1)
        guard pages.indices.contains(next) else { return }
        selected = pages[next].lowerBound
    }
    /// Keeps every candidate reachable when long translations need wider cells.
    /// Selection is tied to the candidate, never to its old page number.
    public mutating func paginate(widths: [Double], availableWidth: Double, maximumCount: Int = Self.pageSize) {
        guard widths.count == candidates.count, availableWidth > 0 else { return }
        var output: [Range<Int>] = []
        var start = 0
        var used = 0.0
        for index in candidates.indices {
            let width = min(availableWidth, max(1, widths[index]))
            if index > start, index - start >= max(1, maximumCount) || used + width > availableWidth {
                output.append(start..<index); start = index; used = 0
            }
            used += width
        }
        if start < candidates.count { output.append(start..<candidates.count) }
        pages = output
    }
    @discardableResult public mutating func publish(_ values: [Candidate], generation token: UUID) -> Bool {
        guard generation == token, !input.isEmpty else { return false }
        candidates = values.filter { ($0.consumed > 0 && $0.consumed <= input.count) || $0.engineIndex != nil }
        selected = 0
        paginate(widths: Array(repeating: 1, count: candidates.count), availableWidth: Double(Self.pageSize))
        return true
    }
    public mutating func commit(index: Int) -> String? {
        guard candidates.indices.contains(index) else { return nil }
        let candidate = candidates[index]
        if browsingSymbols { clear(); return candidate.text }
        guard candidate.consumed > 0, candidate.consumed <= input.count else { return nil }
        let text: String?
        if english { text = candidate.text; englishInput = ""; englishCursor = 0 }
        else {
            text = composition.commit(candidate)
            originalInput = String(originalInput.dropFirst(candidate.consumed)).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
        }
        invalidate()
        return text
    }
    @discardableResult public mutating func resolveCandidate(_ candidate: Candidate, at index: Int, generation token: UUID) -> Bool {
        guard token == generation, candidates.indices.contains(index),
              candidates[index].text == candidate.text,
              candidate.consumed > 0, candidate.consumed <= input.count else { return false }
        candidates[index] = candidate
        return true
    }
    public mutating func clear() {
        composition.clear(); englishInput = ""; originalInput = ""; englishCursor = 0; browsingSymbols = false; invalidate()
    }
    private mutating func invalidate() {
        generation = UUID(); candidates = []; pages = []; selected = 0
    }
}
