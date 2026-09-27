import Foundation

// Small FIFO cache used by the markdown renderer. Reads are O(1) and never
// reorder, because streaming re-renders look up every block of a message on
// each frame; recency bookkeeping would cost more than it saves. Eviction
// drops the oldest half at once so trimming amortises to O(1) per insert.
// An optional cost limit (e.g. bytes) bounds memory the same way.
final class MarkdownFIFOCache<Key: Hashable, Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Key: (value: Value, cost: Int)] = [:]
    private var order: [Key] = []
    private var totalCost = 0
    private let limit: Int
    private let costLimit: Int

    init(limit: Int, costLimit: Int = .max) {
        self.limit = max(1, limit)
        self.costLimit = max(1, costLimit)
    }

    func value(for key: Key) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]?.value
    }

    func insert(_ value: Value, for key: Key, cost: Int = 0) {
        lock.lock()
        defer { lock.unlock() }
        if let old = storage.updateValue((value, cost), forKey: key) {
            totalCost -= old.cost
        } else {
            order.append(key)
        }
        totalCost += cost
        guard order.count > limit || totalCost > costLimit else { return }
        var dropCount = 0
        while dropCount < order.count, order.count - dropCount > limit / 2 || totalCost > costLimit / 2 {
            totalCost -= storage.removeValue(forKey: order[dropCount])?.cost ?? 0
            dropCount += 1
        }
        order.removeFirst(dropCount)
    }
}
