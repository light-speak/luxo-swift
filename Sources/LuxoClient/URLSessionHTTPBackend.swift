import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

public typealias URLSessionTransport = HTTPTransport<URLSessionHTTPBackend>

public final class URLSessionHTTPBackend: HTTPBackend, Sendable {
    private let endpoint: URL
    private let session: URLSession
    private let timeout: TimeInterval
    private let maximum: Int

    init(endpoint: String, timeout: TimeInterval, maximum: Int, session: URLSession) throws {
        self.endpoint = try validatedURL(endpoint, schemes: ["http", "https"])
        guard timeout.isFinite && timeout > 0 else {
            throw LuxoError(code: 0, message: "timeout must be finite and greater than zero", name: "ConfigError")
        }
        guard maximum > 0 && maximum <= Int(Int32.max) else {
            throw LuxoError(code: 0, message: "invalid HTTP response byte limit", name: "ConfigError")
        }
        self.timeout = timeout
        self.maximum = maximum
        self.session = session
    }

    /// Invalidates this backend session and cancels its pending requests.
    public func close() { session.invalidateAndCancel() }

    public func send(body: Data, mode: TransportMode, headers: [String: String]) async throws -> HTTPBackendResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.httpBody = body
        request.setValue(
            mode == .binary ? "application/x-luxo" : "application/json", forHTTPHeaderField: "Content-Type")
        if mode == .binary { request.setValue("binary", forHTTPHeaderField: "X-Luxo-Mode") }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await HTTPResponseCollector(maximum: maximum).read(
            session: session, request: request)
        guard let response = response as? HTTPURLResponse else {
            throw LuxoError(code: 0, message: "Invalid response", name: "NetworkError")
        }
        return HTTPBackendResponse(status: response.statusCode, body: data)
    }
}

public extension HTTPTransport where Backend == URLSessionHTTPBackend {
    convenience init(
        endpoint: String, token: String? = nil, timeout: TimeInterval = 30,
        maxResponseBytes: Int = 2 * 1024 * 1024
    ) throws {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["Content-Type": "application/json"]
        try self.init(
            endpoint: endpoint, token: token, timeout: timeout,
            maxResponseBytes: maxResponseBytes, session: URLSession(configuration: config))
    }
}

extension HTTPTransport where Backend == URLSessionHTTPBackend {
    convenience init(
        endpoint: String, token: String? = nil, timeout: TimeInterval = 30,
        maxResponseBytes: Int = 2 * 1024 * 1024, session: URLSession
    ) throws {
        let backend = try URLSessionHTTPBackend(
            endpoint: endpoint, timeout: timeout, maximum: maxResponseBytes, session: session)
        self.init(backend: backend, token: token)
    }
}
