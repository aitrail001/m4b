import Foundation

/// Test-only counters for `sha256Hex`. Off by default so production hashing
/// does not retain per-call records. Reset between tests.
package enum DigestProbe {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var enabled = false
        var calls: [Call] = []
        var chunkHandler: (@Sendable () -> Void)?
    }

    private static let state = State()

    package struct Call: Sendable {
        package var path: String
        package var bytes: Int
        package var onMainThread: Bool
    }

    package struct Snapshot: Equatable, Sendable {
        package var callCount: Int
        package var bytesHashed: Int
        package var mainThreadCallCount: Int
        package var mainThreadBytes: Int
    }

    package static func reset() {
        state.lock.lock()
        state.enabled = false
        state.calls = []
        state.chunkHandler = nil
        state.lock.unlock()
    }

    package static func setEnabled(_ isEnabled: Bool) {
        state.lock.lock()
        state.enabled = isEnabled
        if isEnabled {
            state.calls = []
        }
        state.lock.unlock()
    }

    package static var onChunk: (@Sendable () -> Void)? {
        get {
            state.lock.lock()
            defer { state.lock.unlock() }
            return state.chunkHandler
        }
        set {
            state.lock.lock()
            state.chunkHandler = newValue
            state.lock.unlock()
        }
    }

    package static func noteChunk() {
        let handler: (@Sendable () -> Void)?
        state.lock.lock()
        handler = state.chunkHandler
        state.lock.unlock()
        handler?()
    }

    package static func record(url: URL, bytes: Int, onMainThread: Bool) {
        state.lock.lock()
        defer { state.lock.unlock() }
        guard state.enabled else { return }
        state.calls.append(
            Call(
                path: url.standardizedFileURL.path,
                bytes: bytes,
                onMainThread: onMainThread
            )
        )
    }

    package static func snapshot() -> Snapshot {
        state.lock.lock()
        defer { state.lock.unlock() }
        return Snapshot(
            callCount: state.calls.count,
            bytesHashed: state.calls.reduce(0) { $0 + $1.bytes },
            mainThreadCallCount: state.calls.filter(\.onMainThread).count,
            mainThreadBytes: state.calls.filter(\.onMainThread).reduce(0) { $0 + $1.bytes }
        )
    }

    package static func callCount(for url: URL) -> Int {
        let path = url.standardizedFileURL.path
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.calls.count { $0.path == path }
    }
}
