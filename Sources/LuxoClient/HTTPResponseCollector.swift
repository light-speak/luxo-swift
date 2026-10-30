import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A task owns its bounded body; cancellation never invalidates the shared session.
final class HTTPResponseCollector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private typealias Output = (Data, URLResponse)
    private let maximum: Int
    private let lock = NSLock()
    private var body = Data()
    private var response: URLResponse?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<Output, any Error>?
    private var finished = false

    init(maximum: Int) { self.maximum = maximum }

    func read(session: URLSession, request: URLRequest) async throws -> (Data, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = lock.withLock { () -> URLSessionDataTask? in
                    guard !finished else { return nil }
                    self.continuation = continuation
                    let task = session.dataTask(with: request)
                    task.delegate = self
                    self.task = task
                    return task
                }
                guard let task else { continuation.resume(throwing: CancellationError()); return }
                task.resume()
            }
        } onCancel: {
            self.finish(CancellationError(), cancel: true)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let oversized = lock.withLock { () -> Bool in
            guard !finished else { return false }
            if response == nil {
                response = dataTask.response
                if responseExceedsLimit(response) { return true }
            }
            guard data.count <= maximum - body.count else { return true }
            body.append(data)
            return false
        }
        if oversized { finish(sizeError(dataTask.response), cancel: true) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        finish(error)
    }

    private func responseExceedsLimit(_ response: URLResponse?) -> Bool {
        guard let response else { return false }
        let encoding = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Encoding")
        return (encoding == nil || encoding == "identity") && response.expectedContentLength > maximum
    }

    private func sizeError(_ response: URLResponse?) -> LuxoError {
        LuxoError(
            code: (response as? HTTPURLResponse)?.statusCode ?? 0,
            message: "HTTP response body exceeds limit", name: "ParseError")
    }

    private func finish(_ error: (any Error)? = nil, cancel: Bool = false) {
        let completion = lock.withLock {
            () -> (CheckedContinuation<Output, any Error>?, URLSessionDataTask?, Result<Output, any Error>)? in
            guard !finished else { return nil }
            finished = true
            let result: Result<Output, any Error>
            if let error {
                result = .failure(error)
            } else if let received = response ?? task?.response {
                if response == nil && responseExceedsLimit(received) {
                    result = .failure(sizeError(received))
                } else {
                    result = .success((body, received))
                }
            } else {
                result = .failure(URLError(.badServerResponse))
            }
            let completion = (continuation, task, result)
            continuation = nil
            task = nil
            body = Data()
            response = nil
            return completion
        }
        guard let (continuation, task, result) = completion else { return }
        if cancel { task?.cancel() }
        continuation?.resume(with: result)
    }
}
