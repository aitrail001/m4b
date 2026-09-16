import Foundation

/// Cancellation flag shared between a Swift `Task` and the GCD encode worker.
/// `Task.isCancelled` is false on `DispatchQueue.global()`, so the worker must
/// read this token instead.
public final class EncodeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelledFlag = false

    public init() {}

    public func cancel() {
        lock.lock()
        cancelledFlag = true
        lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock()
        let flag = cancelledFlag
        lock.unlock()
        return flag || Task.isCancelled
    }

    public func checkCancelled() throws {
        if isCancelled {
            cancel()
            throw BinderError.cancelled
        }
    }
}
