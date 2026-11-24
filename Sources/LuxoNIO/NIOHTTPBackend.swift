import Foundation
import LuxoClient
import NIOCore
import NIOHTTP1
import NIOPosix

public typealias NIOHTTPTransport = HTTPTransport<NIOHTTPBackend>

/// Explicitly established TLS/H2 connection; no request replay or H1 fallback.
public final class NIOHTTPBackend: HTTPBackend, @unchecked Sendable {
    private let client: NIOHTTPClient
    private let group: MultiThreadedEventLoopGroup
    private let path: String
    private let authority: String
    private let timeout: TimeAmount
    private let maximumRequest: Int
    private let lock = NSLock()
    private var shutdown: Task<Void, Error>?

    private init(client: NIOHTTPClient, group: MultiThreadedEventLoopGroup, configuration: Configuration) {
        self.client = client
        self.group = group
        path = configuration.path
        authority = configuration.authority
        timeout = configuration.timeout
        maximumRequest = configuration.maximumRequest
    }

    public static func connect(
        endpoint: String, timeout: TimeInterval = 30,
        maxResponseBytes: Int = 2 * 1024 * 1024, maxRequestBytes: Int = 2 * 1024 * 1024,
        maximumConcurrent: Int = 16, trustRootsFile: String? = nil
    ) async throws -> NIOHTTPBackend {
        do {
            return try await connectForSelection(
                endpoint: endpoint, timeout: timeout, maxResponseBytes: maxResponseBytes,
                maxRequestBytes: maxRequestBytes, maximumConcurrent: maximumConcurrent,
                trustRootsFile: trustRootsFile, allowHTTP1: false)
        } catch is CancellationError { throw CancellationError() } catch let error as LuxoError { throw error } catch {
            throw normalizedNIOError(error)
        }
    }

    static func connectForSelection(
        endpoint: String, timeout: TimeInterval = 30,
        maxResponseBytes: Int = 2 * 1024 * 1024, maxRequestBytes: Int = 2 * 1024 * 1024,
        maximumConcurrent: Int = 16, trustRootsFile: String? = nil, allowHTTP1: Bool = true
    ) async throws -> NIOHTTPBackend {
        let configuration = try Configuration(
            endpoint: endpoint, timeout: timeout,
            maximumResponse: maxResponseBytes, maximumRequest: maxRequestBytes, concurrent: maximumConcurrent)
        try Task.checkCancellation()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let client = try await NIOHTTPClient.connect(
                group: group, host: configuration.host,
                port: configuration.port, trustRootsFile: trustRootsFile,
                maximumResponseBytes: maxResponseBytes, maximumConcurrent: maximumConcurrent, allowHTTP1: allowHTTP1)
            if Task.isCancelled { try? await client.close(); throw CancellationError() }
            return NIOHTTPBackend(client: client, group: group, configuration: configuration)
        } catch {
            try? await group.shutdownGracefully()
            if error is CancellationError { throw CancellationError() }
            if case ConnectionFailure.requiresHTTP2 = error { throw error }
            throw normalizedNIOError(error)
        }
    }

    public func send(body: Data, mode: TransportMode, headers: [String: String]) async throws -> HTTPBackendResponse {
        try Task.checkCancellation()
        guard lock.withLock({ shutdown == nil }), client.isActive else {
            throw LuxoError(code: 0, message: "HTTP/2 connection is closed", name: "NetworkError")
        }
        guard body.count <= maximumRequest else {
            throw LuxoError(code: 0, message: "HTTP request body exceeds limit", name: "ConfigError")
        }
        let fields = try requestHeaders(mode: mode, headers: headers)
        do {
            let response = try await client.post(
                path: path, authority: authority, body: body,
                headers: fields, timeout: timeout)
            return HTTPBackendResponse(status: response.status, body: response.body)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw normalizedNIOError(error)
        }
    }

    /// Idempotent; releases in-flight streams and the owned event-loop thread.
    public func close() async throws {
        let task = lock.withLock { () -> Task<Void, Error> in
            if let shutdown { return shutdown }
            let client = client, group = group
            let task = Task {
                try? await client.close()
                try await group.shutdownGracefully()
            }
            shutdown = task
            return task
        }
        try await task.value
    }

    deinit {
        if shutdown == nil {
            let client = client, group = group
            Task {
                try? await client.close()
                try? await group.shutdownGracefully()
            }
        }
    }
}

public extension HTTPTransport where Backend == NIOHTTPBackend {
    static func connect(
        endpoint: String, token: String? = nil, timeout: TimeInterval = 30,
        maxResponseBytes: Int = 2 * 1024 * 1024, maxRequestBytes: Int = 2 * 1024 * 1024,
        maximumConcurrent: Int = 16, trustRootsFile: String? = nil
    ) async throws -> NIOHTTPTransport {
        let backend = try await NIOHTTPBackend.connect(
            endpoint: endpoint, timeout: timeout,
            maxResponseBytes: maxResponseBytes, maxRequestBytes: maxRequestBytes,
            maximumConcurrent: maximumConcurrent, trustRootsFile: trustRootsFile)
        return NIOHTTPTransport(backend: backend, token: token, timeout: timeout)
    }

    func close() async throws { try await backend.close() }
}

private struct Configuration {
    let host: String
    let port: Int
    let path: String
    let authority: String
    let timeout: TimeAmount
    let maximumRequest: Int

    init(endpoint: String, timeout: TimeInterval, maximumResponse: Int, maximumRequest: Int, concurrent: Int) throws {
        guard let url = URLComponents(string: endpoint), url.scheme == "https",
            let host = url.host, !host.isEmpty, url.user == nil, url.password == nil, url.fragment == nil,
            timeout.isFinite, timeout > 0, timeout < Double(Int64.max) / 1_000_000_000,
            maximumResponse > 0, maximumResponse <= Int(Int32.max),
            maximumRequest > 0, maximumRequest <= Int(Int32.max), (1...65535).contains(concurrent)
        else { throw LuxoError(code: 0, message: "invalid NIO HTTP configuration", name: "ConfigError") }
        let port = url.port ?? 443
        guard (1...65535).contains(port) else {
            throw LuxoError(code: 0, message: "invalid HTTPS port", name: "ConfigError")
        }
        self.host = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        self.port = port
        path =
            (url.percentEncodedPath.isEmpty ? "/" : url.percentEncodedPath)
            + (url.percentEncodedQuery.map { "?" + $0 } ?? "")
        authority = (self.host.contains(":") ? "[\(self.host)]" : self.host) + ":\(port)"
        self.timeout = .nanoseconds(max(1, Int64(timeout * 1_000_000_000)))
        self.maximumRequest = maximumRequest
    }
}

func requestHeaders(mode: TransportMode, headers: [String: String]) throws -> HTTPHeaders {
    var fields = HTTPHeaders()
    for (key, value) in headers {
        guard validHeader(key, value) else {
            throw LuxoError(code: 0, message: "invalid HTTP header", name: "ConfigError")
        }
        fields.add(name: key, value: value)
    }
    fields.replaceOrAdd(name: "content-type", value: mode == .binary ? "application/x-luxo" : "application/json")
    fields.replaceOrAdd(name: "cache-control", value: "no-store")
    if mode == .binary { fields.replaceOrAdd(name: "x-luxo-mode", value: "binary") }
    return fields
}

private func validHeader(_ name: String, _ value: String) -> Bool {
    !name.isEmpty
        && name.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                || "!#$%&'*+-.^_`|~".utf8.contains($0)
        } && value.utf8.allSatisfy { $0 == 9 || ($0 >= 32 && $0 != 127) }
}

private func normalizedNIOError(_ error: any Error) -> LuxoError {
    switch error {
    case ResponseFailure.malformed, ResponseFailure.tooLarge:
        LuxoError(code: 0, message: "invalid or oversized HTTP response", name: "ParseError")
    case ConnectionFailure.overloaded:
        LuxoError(code: 503, message: "HTTP concurrency limit reached", name: "Overloaded")
    case ConnectionFailure.deadline:
        LuxoError(code: 0, message: "HTTP request deadline exceeded", name: "TimeoutError")
    default:
        LuxoError(code: 0, message: "HTTP/2 connection failed", name: "NetworkError")
    }
}
