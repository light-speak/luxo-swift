import Foundation

// A non-cooperative user refresh must not keep its caller waiting after cancellation.
final class HTTPCallDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var continuation: CheckedContinuation<TransportPayload, Error>?
    private var operation: Task<Void, Never>?
    private var timer: DispatchSourceTimer?
    private var parameters: RequestParameters?
    private var body: Data?

    init(parameters: RequestParameters? = nil) { self.parameters = parameters }

    func prepareRequest(_ encode: (RequestParameters) throws -> Data) throws {
        let parameters = try lock.withLock {
            guard !finished, let parameters = self.parameters else { throw CancellationError() }
            self.parameters = nil
            return parameters
        }
        let encoded = try encode(parameters)
        try lock.withLock {
            guard !finished else { throw CancellationError() }
            body = encoded
        }
    }

    func requestBody() throws -> Data {
        try lock.withLock {
            guard !finished, let body else { throw CancellationError() }
            return body
        }
    }

    func run(
        timeout: TimeInterval,
        execute: @escaping @Sendable () async throws -> TransportPayload
    ) async throws -> TransportPayload {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let installed = lock.withLock {
                    guard !finished else { return false }
                    self.continuation = continuation
                    let timer = DispatchSource.makeTimerSource(queue: .global())
                    timer.schedule(deadline: .now() + timeout)
                    timer.setEventHandler { [weak self] in
                        self?.finish(
                            .failure(LuxoError(code: 0, message: "request timed out", name: "TimeoutError")),
                            cancel: true)
                    }
                    self.timer = timer
                    operation = Task {
                        do {
                            try Task.checkCancellation()
                            self.finish(.success(try await execute()))
                        } catch { self.finish(.failure(error)) }
                    }
                    timer.activate()
                    return true
                }
                if !installed { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            self.finish(.failure(CancellationError()), cancel: true)
        }
    }

    private func finish(_ result: Result<TransportPayload, Error>, cancel: Bool = false) {
        let pending = lock.withLock {
            () -> (
                CheckedContinuation<TransportPayload, Error>?, Task<Void, Never>?, DispatchSourceTimer?,
                RequestParameters?, Data?
            )? in
            guard !finished else { return nil }
            finished = true
            let pending = (continuation, operation, timer, parameters, body)
            continuation = nil
            operation = nil
            timer = nil
            parameters = nil
            body = nil
            return pending
        }
        guard var pending else { return }
        // User-owned values may run deinitializers that reenter the transport.
        pending.3 = nil
        pending.4 = nil
        pending.2?.cancel()
        if cancel { pending.1?.cancel() }
        pending.0?.resume(with: result)
    }
}
