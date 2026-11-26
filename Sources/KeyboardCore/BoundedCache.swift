import Foundation

/// Small in-memory LRU. Text never goes into a persistent translation cache.
public struct BoundedCache<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    private var values: [Key: Value] = [:]
    private var order: [Key] = []
    public let capacity: Int
    public init(capacity: Int) { self.capacity = max(1, capacity) }
    public var count: Int { values.count }
    public mutating func value(for key: Key) -> Value? {
        guard let value = values[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return value
    }
    public mutating func insert(_ value: Value, for key: Key) {
        order.removeAll { $0 == key }
        values[key] = value
        order.append(key)
        while order.count > capacity { values.removeValue(forKey: order.removeFirst()) }
    }
    public mutating func removeAll() { values.removeAll(); order.removeAll() }
}
