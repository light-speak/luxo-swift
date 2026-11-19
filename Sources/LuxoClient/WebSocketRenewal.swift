import Foundation

// Allocated only during token renewal; cancellation retires one waiter, not the shared refresh.
final class WebSocketRenewal: @unchecked Sendable {
    private final class Waiter: @unchecked Sendable {
        var cancelled = false
    }
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var waiters: [ObjectIdentifier: CheckedContinuation<Void, Error>] = [:]

    func wait() async throws {
        let waiter = Waiter()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let ready = lock.withLock { () -> Result<Void, Error>? in
                    if waiter.cancelled { return .failure(CancellationError()) }
                    if let result { return result }
                    waiters[ObjectIdentifier(waiter)] = continuation
                    return nil
                }
                if let ready { continuation.resume(with: ready) }
            }
        } onCancel: {
            let continuation = self.lock.withLock {
                waiter.cancelled = true
                return self.waiters.removeValue(forKey: ObjectIdentifier(waiter))
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func finish(_ result: Result<Void, Error>) {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            guard self.result == nil else { return [] }
            self.result = result
            let pending = Array(waiters.values)
            waiters.removeAll()
            return pending
        }
        for continuation in pending { continuation.resume(with: result) }
    }
}
