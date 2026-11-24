import Foundation
import LuxoClient

public typealias AutomaticHTTPTransport = HTTPTransport<AutomaticHTTPBackend>

/// Chooses once, before sending any business request. Never retries on another backend.
public final class AutomaticHTTPBackend: HTTPBackend, @unchecked Sendable {
    public enum SelectedBackend: Sendable { case http2, urlSession }
    private enum Connection {
        case http2(NIOHTTPBackend)
        case urlSession(URLSessionHTTPBackend)
    }

    public let selectedBackend: SelectedBackend
    private let connection: Connection
    private let maximumRequest: Int
    private let maximumConcurrent: Int
    private let lock = NSLock()
    private var active = 0
    private var closed = false

    private init(http2: NIOHTTPBackend) {
        connection = .http2(http2)
        selectedBackend = .http2
        maximumRequest = 0
        maximumConcurrent = 0
    }

    init(fallback: URLSessionHTTPBackend, maximumRequest: Int, maximumConcurrent: Int) {
        connection = .urlSession(fallback)
        selectedBackend = .urlSession
        self.maximumRequest = maximumRequest
        self.maximumConcurrent = maximumConcurrent
    }

    public static func connect(
        endpoint: String, timeout: TimeInterval = 30,
        maxResponseBytes: Int = 2 * 1024 * 1024, maxRequestBytes: Int = 2 * 1024 * 1024,
        maximumConcurrent: Int = 16, trustRootsFile: String? = nil
    ) async throws -> AutomaticHTTPBackend {
        try await select(
            maximumRequest: maxRequestBytes, maximumConcurrent: maximumConcurrent,
            connectHTTP2: {
                try await NIOHTTPBackend.connectForSelection(
                    endpoint: endpoint, timeout: timeout, maxResponseBytes: maxResponseBytes,
                    maxRequestBytes: maxRequestBytes, maximumConcurrent: maximumConcurrent,
                    trustRootsFile: trustRootsFile)
            },
            makeFallback: {
                // Foundation and NIOSSL have different trust stores; never discard custom roots.
                guard trustRootsFile == nil else {
                    throw LuxoError(
                        code: 0, message: "HTTP/1 fallback requires system trust roots", name: "ConfigError")
                }
                return try URLSessionTransport(
                    endpoint: endpoint, timeout: timeout, maxResponseBytes: maxResponseBytes
                ).backend
            })
    }

    static func select(
        maximumRequest: Int, maximumConcurrent: Int,
        connectHTTP2: () async throws -> NIOHTTPBackend,
        makeFallback: () throws -> URLSessionHTTPBackend,
        isolation: isolated (any Actor)? = #isolation
    ) async throws -> AutomaticHTTPBackend {
        do { return try await AutomaticHTTPBackend(http2: connectHTTP2()) } catch ConnectionFailure.requiresHTTP2 {
            try Task.checkCancellation()
            return try AutomaticHTTPBackend(
                fallback: makeFallback(), maximumRequest: maximumRequest, maximumConcurrent: maximumConcurrent)
        }
    }

    public func send(body: Data, mode: TransportMode, headers: [String: String]) async throws -> HTTPBackendResponse {
        switch connection {
        case .http2(let backend):
            return try await backend.send(body: body, mode: mode, headers: headers)
        case .urlSession(let backend):
            try Task.checkCancellation()
            guard body.count <= maximumRequest else {
                throw LuxoError(code: 0, message: "HTTP request body exceeds limit", name: "ConfigError")
            }
            _ = try requestHeaders(mode: mode, headers: headers)
            try acquire()
            defer { lock.withLock { active -= 1 } }
            return try await backend.send(body: body, mode: mode, headers: headers)
        }
    }

    private func acquire() throws {
        try lock.withLock {
            guard !closed else {
                throw LuxoError(code: 0, message: "HTTP transport is closed", name: "NetworkError")
            }
            guard active < maximumConcurrent else {
                throw LuxoError(code: 503, message: "HTTP concurrency limit reached", name: "Overloaded")
            }
            active += 1
        }
    }

    public func close() async throws {
        switch connection {
        case .http2(let backend): try await backend.close()
        case .urlSession(let backend):
            let first = lock.withLock {
                if closed { return false }
                closed = true
                return true
            }
            if first { backend.close() }
        }
    }

    deinit {
        if case .urlSession(let backend) = connection { backend.close() }
    }
}

public extension HTTPTransport where Backend == AutomaticHTTPBackend {
    static func connect(
        endpoint: String, token: String? = nil, timeout: TimeInterval = 30,
        maxResponseBytes: Int = 2 * 1024 * 1024, maxRequestBytes: Int = 2 * 1024 * 1024,
        maximumConcurrent: Int = 16, trustRootsFile: String? = nil
    ) async throws -> AutomaticHTTPTransport {
        let backend = try await AutomaticHTTPBackend.connect(
            endpoint: endpoint, timeout: timeout, maxResponseBytes: maxResponseBytes,
            maxRequestBytes: maxRequestBytes, maximumConcurrent: maximumConcurrent, trustRootsFile: trustRootsFile)
        return AutomaticHTTPTransport(backend: backend, token: token, timeout: timeout)
    }

    func close() async throws { try await backend.close() }
}
