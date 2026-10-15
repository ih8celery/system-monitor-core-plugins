import Foundation

/// A dictionary that keeps at most `capacity` entries, dropping the one set longest ago when a
/// new one would pass it. The Network tab's hostname caches use it, so a tab left open for days
/// does not keep every address it ever saw.
struct BoundedCache<Key: Hashable, Value> {
    static var defaultCapacity: Int { 512 }

    let capacity: Int
    private var values: [Key: Value] = [:]
    /// Keys from the one set longest ago to the newest.
    private var order: [Key] = []

    init(capacity: Int = defaultCapacity) {
        self.capacity = max(capacity, 1)
    }

    subscript(key: Key) -> Value? { values[key] }

    var count: Int { values.count }

    /// A copy with `value` stored for `key` as the newest entry, and the oldest dropped if that
    /// passes the capacity.
    func setting(_ value: Value, for key: Key) -> BoundedCache {
        var next = self
        next.order.removeAll { $0 == key }
        next.order.append(key)
        next.values[key] = value
        if next.order.count > capacity {
            let dropped = next.order.prefix(next.order.count - capacity)
            dropped.forEach { next.values[$0] = nil }
            next.order.removeFirst(dropped.count)
        }
        return next
    }
}
