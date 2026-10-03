import Foundation

/// A value guarded by an NSLock; held for microseconds (the governor hop between queues).
public final class Locked<Value> {
    private let lock = NSLock()
    private var value: Value

    public init(_ value: Value) {
        self.value = value
    }

    public func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
