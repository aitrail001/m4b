import Foundation

/// Monotonic token so only the newest library scan may commit UI state.
public struct ScanGeneration: Equatable, Sendable {
    public private(set) var current: UInt64 = 0

    public init() {}

    /// Starts a new generation and returns its id. Older ids are no longer current.
    public mutating func begin() -> UInt64 {
        current += 1
        return current
    }

    public func isCurrent(_ id: UInt64) -> Bool {
        id == current
    }
}
