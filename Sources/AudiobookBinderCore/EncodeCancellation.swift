import Foundation

/// Cancellation flag shared between a Swift `Task` and the GCD encode worker.
/// `Task.isCancelled` is false on `DispatchQueue.global()`, so the worker must
/// read this token instead.
package final class EncodeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelledFlag = false

    package init() {}

    package func cancel() {
        lock.lock()
        cancelledFlag = true
        lock.unlock()
    }

    package var isCancelled: Bool {
        lock.lock()
        let flag = cancelledFlag
        lock.unlock()
        return flag || Task.isCancelled
    }

    package func checkCancelled() throws {
        if isCancelled {
            cancel()
            throw BinderError.cancelled
        }
    }
}
