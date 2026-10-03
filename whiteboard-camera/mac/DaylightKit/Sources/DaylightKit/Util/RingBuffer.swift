import Foundation

/// Fixed-capacity ring; push overwrites the oldest entry.
public struct RingBuffer<T> {
    private var items: [T?]
    private var head = 0
    public private(set) var count = 0

    public init(capacity: Int) {
        items = Array(repeating: nil, count: max(capacity, 1))
    }

    public var capacity: Int { return items.count }

    public mutating func push(_ item: T) {
        items[(head + count) % items.count] = item
        if count < items.count {
            count += 1
        } else {
            head = (head + 1) % items.count
        }
    }

    public mutating func drain() -> [T] {
        var out: [T] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            if let v = items[(head + i) % items.count] { out.append(v) }
        }
        items = Array(repeating: nil, count: items.count)
        head = 0
        count = 0
        return out
    }
}
