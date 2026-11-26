import Foundation

public struct SavedClip: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let text: String
    public let createdAt: Date
    public init(text: String) { id = UUID(); self.text = text; createdAt = Date() }
}

public enum ClipError: Error, LocalizedError {
    case empty, tooLong, full
    public var errorDescription: String? {
        switch self {
        case .empty: "没有可收藏的文本。"
        case .tooLong: "文本超过 2,000 字，请缩短后再收藏。"
        case .full: "已收藏 30 条，请先删除不需要的文本。"
        }
    }
}

public struct SavedClips: Codable, Sendable {
    public private(set) var items: [SavedClip] = []
    public init() {}
    public mutating func save(_ text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ClipError.empty }
        guard text.count <= 2000 else { throw ClipError.tooLong }
        guard !items.contains(where: { $0.text == text }) else { return }
        guard items.count < 30 else { throw ClipError.full }
        items.insert(SavedClip(text: text), at: 0)
    }
    public mutating func remove(_ id: UUID) { items.removeAll { $0.id == id } }
    public mutating func removeAll() { items = [] }
}
