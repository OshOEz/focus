import Foundation

/// Emits a candidate once it has been proposed continuously for `duration`.
public struct Dwell<T: Equatable & Sendable>: Sendable {
    private var pending: T?
    private var since = 0.0

    public init() {}

    public mutating func propose(_ candidate: T?, at now: Double, duration: Double) -> T? {
        guard let candidate else { pending = nil; return nil }
        if candidate != pending { pending = candidate; since = now }
        guard now - since >= duration else { return nil }
        pending = nil
        return candidate
    }

    public mutating func reset() { pending = nil }
}
