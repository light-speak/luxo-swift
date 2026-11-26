import Foundation

/// A statically selected HTTP backend; protocol encoding and authentication are shared.
public protocol HTTPBackend: Sendable {
    func send(body: Data, mode: TransportMode, headers: [String: String]) async throws -> HTTPBackendResponse
}

public struct HTTPBackendResponse: Sendable {
    public let status: Int
    public let body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

private class HTTPRefreshContext: @unchecked Sendable {
    @TaskLocal static var current: HTTPRefreshContext? = nil

    private let inherited: HTTPRefreshContext?

    init() { inherited = HTTPRefreshContext.current }

    static func contains(_ refresh: HTTPRefreshContext) -> Bool {
        var ancestor = current
        while let context = ancestor {
            if context === refresh { return true }
            ancestor = context.inherited
        }
        return false
    }
}

public final class HTTPTransport<Backend: HTTPBackend>: Transport, @unchecked Sendable {
    private final class CredentialRevision: @unchecked Sendable {
        private let original: CredentialRevision?
        // The transport lock protects the outcome retained by already-sent requests.
        var refreshSucceeded: Bool?

        init(previous: CredentialRevision? = nil) { original = previous?.identity }

        var identity: CredentialRevision { original ?? self }
    }

    private typealias RefreshContinuation = CheckedContinuation<Bool, Error>

    private struct RefreshWaiters {
        private var first: (key: ObjectIdentifier, continuation: RefreshContinuation)?
        private var remaining: [ObjectIdentifier: RefreshContinuation] = [:]

        var isEmpty: Bool { first == nil && remaining.isEmpty }

        mutating func insert(_ continuation: RefreshContinuation, for key: ObjectIdentifier) {
            if first == nil {
                first = (key, continuation)
            } else {
                remaining[key] = continuation
            }
        }

        mutating func removeValue(forKey key: ObjectIdentifier) -> RefreshContinuation? {
            if let first, first.key == key {
                self.first = nil
                return first.continuation
            }
            return remaining.removeValue(forKey: key)
        }

        func resume(with result: Result<Bool, Error>) {
            first?.continuation.resume(with: result)
            for continuation in remaining.values { continuation.resume(with: result) }
        }
    }

    private final class Refresh: HTTPRefreshContext, @unchecked Sendable {
        // The transport lock protects registration, retirement and settlement.
        var waiters = RefreshWaiters()
        var task: Task<Void, Never>?
    }

    // One worker owns this snapshot of the configured callback. The inherited refresh context does not retain it.
    private struct RefreshCallback: @unchecked Sendable {
        let call: () async -> String?
    }

    private final class RefreshWaiter: @unchecked Sendable {
        // Protected by the transport lock, even before registration.
        var cancelled = false
    }

    private struct HTTPFailure: Error {
        let statusCode: Int
        let error: LuxoError
    }

    private struct State {
        let headers: [String: String]
        let mode: TransportMode
        let schema: [String: APISchema]
        let credentialRevision: CredentialRevision
    }

    /// The concrete backend owns its network lifecycle.
    public let backend: Backend
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var headers: [String: String] = [:]
    private var credentialRevision = CredentialRevision()
    private var mode: TransportMode = .json
    private var schema: [String: APISchema] = [:]
    private var tokenExpiredHandler: (() async -> String?)?
    private var activeRefresh: Refresh?

    /// Called only when HTTP status and the validated error code are both 401.
    /// Concurrent calls for the current credential share an active refresh.
    /// Return a new token to retry once, or nil to propagate each call's error.
    public var onTokenExpired: (() async -> String?)? {
        get { lock.withLock { tokenExpiredHandler } }
        set { lock.withLock { tokenExpiredHandler = newValue } }
    }

    public init(backend: Backend, token: String? = nil, timeout: TimeInterval = 30) {
        self.timeout = timeout
        self.backend = backend
        if let token { headers["Authorization"] = "Bearer \(token)" }
    }

    public func setToken(_ token: String) {
        let obsolete = lock.withLock {
            credentialRevision = CredentialRevision()
            headers["Authorization"] = "Bearer \(token)"
            return activeRefresh.map(retireRefresh)
        }
        if let obsolete {
            obsolete.waiters.resume(with: .success(false))
            obsolete.task?.cancel()
        }
    }

    public func setMode(_ mode: TransportMode) {
        lock.withLock { self.mode = mode }
    }

    public func setSchema(_ schema: [String: APISchema]) throws {
        try validateRuntimeSchemaIDs(schema)
        lock.withLock { self.schema = schema }
    }

    public func call(_ api: String, params: [String: LuxoValue]? = nil) async throws -> TransportPayload {
        try await callRequest(api, params: .dynamic(params))
    }

    public func call(_ api: String, request: any GeneratedRequest) async throws -> TransportPayload {
        try await callRequest(api, params: .generated(request))
    }

    private func callRequest(_ api: String, params: RequestParameters) async throws -> TransportPayload {
        guard timeout.isFinite && timeout > 0 else {
            throw LuxoError(code: 0, message: "timeout must be finite and greater than zero", name: "ConfigError")
        }
        let state = lock.withLock {
            State(headers: headers, mode: mode, schema: schema, credentialRevision: credentialRevision)
        }
        let operation = HTTPCallDeadline(parameters: params)
        return try await operation.run(timeout: timeout) {
            try operation.prepareRequest { try self.encodeRequest(api, params: $0, state: state) }
            return try await self.performRequest(api, operation: operation, state: state)
        }
    }

    private func performRequest(_ api: String, operation: HTTPCallDeadline, state: State) async throws
        -> TransportPayload
    {
        do {
            return try await doCall(operation: operation, state: state, responseSchema: state.schema[api]?.response)
        } catch let failure as HTTPFailure {
            let error = failure.error
            guard failure.statusCode == 401, error.code == 401, error.name != "ParseError" else {
                throw error
            }
            try Task.checkCancellation()
            guard try await waitForRefresh(after: state.credentialRevision) else { throw error }
            try Task.checkCancellation()
            let retry = lock.withLock { () -> State? in
                guard credentialRevision.identity === state.credentialRevision.identity else { return nil }
                return State(
                    headers: headers, mode: state.mode, schema: state.schema, credentialRevision: credentialRevision)
            }
            guard let retry else { throw error }
            do {
                return try await doCall(operation: operation, state: retry, responseSchema: state.schema[api]?.response)
            } catch let retryFailure as HTTPFailure {
                throw retryFailure.error
            }
        }
    }

    private func waitForRefresh(after revision: CredentialRevision) async throws -> Bool {
        let waiter = RefreshWaiter()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let ready = lock.withLock { registerRefresh(waiter, continuation, after: revision) }
                if let ready { continuation.resume(with: ready) }
            }
        } onCancel: {
            let pending = self.lock.withLock { () -> (waiter: RefreshContinuation?, task: Task<Void, Never>?) in
                waiter.cancelled = true
                guard let refresh = self.activeRefresh,
                    let continuation = refresh.waiters.removeValue(forKey: ObjectIdentifier(waiter))
                else { return (nil, nil) }
                return (continuation, refresh.waiters.isEmpty ? self.retireRefresh(refresh).task : nil)
            }
            pending.waiter?.resume(throwing: CancellationError())
            pending.task?.cancel()
        }
    }

    private func registerRefresh(
        _ waiter: RefreshWaiter, _ continuation: RefreshContinuation, after revision: CredentialRevision
    ) -> Result<Bool, Error>? {
        if waiter.cancelled { return .failure(CancellationError()) }
        guard credentialRevision.identity === revision.identity else { return .success(false) }
        if let succeeded = revision.refreshSucceeded { return .success(succeeded) }
        let key = ObjectIdentifier(waiter)
        if let refresh = activeRefresh {
            // An ancestor callback cannot finish while the nested call waits for it.
            guard !HTTPRefreshContext.contains(refresh) else { return .success(false) }
            refresh.waiters.insert(continuation, for: key)
            return nil
        }
        guard let handler = tokenExpiredHandler else { return .success(false) }
        let refresh = Refresh()
        refresh.waiters.insert(continuation, for: key)
        activeRefresh = refresh
        let callback = RefreshCallback(call: handler)
        refresh.task = Task { [weak self, callback] in
            guard self?.mayStartRefresh(refresh) == true else { return }
            let token = await HTTPRefreshContext.$current.withValue(refresh, operation: callback.call)
            self?.finishRefresh(refresh, token: token, cancelled: Task.isCancelled)
        }
        return nil
    }

    private func mayStartRefresh(_ refresh: Refresh) -> Bool {
        lock.withLock { activeRefresh === refresh }
    }

    private func finishRefresh(_ refresh: Refresh, token: String?, cancelled: Bool) {
        let settlement = lock.withLock { () -> (RefreshWaiters, Result<Bool, Error>)? in
            guard activeRefresh === refresh else { return nil }
            let pending = retireRefresh(refresh)
            guard let token, !cancelled else {
                advanceCredential(refreshSucceeded: false)
                let result: Result<Bool, Error> =
                    cancelled && token != nil ? .failure(CancellationError()) : .success(false)
                return (pending.waiters, result)
            }
            advanceCredential(refreshSucceeded: true)
            headers["Authorization"] = "Bearer \(token)"
            return (pending.waiters, .success(true))
        }
        if let (waiters, outcome) = settlement {
            waiters.resume(with: outcome)
        }
    }

    // Keep the outcome with the requests that shared this refresh.
    private func advanceCredential(refreshSucceeded: Bool) {
        credentialRevision.refreshSucceeded = refreshSucceeded
        credentialRevision = CredentialRevision(previous: credentialRevision)
    }

    // The caller verifies the current refresh under the transport lock.
    private func retireRefresh(_ refresh: Refresh) -> (task: Task<Void, Never>?, waiters: RefreshWaiters) {
        activeRefresh = nil
        let pending = (refresh.task, refresh.waiters)
        refresh.task = nil
        refresh.waiters = RefreshWaiters()
        return pending
    }

    private func doCall(operation: HTTPCallDeadline, state: State, responseSchema: LuxoJSONReadSchema?) async throws
        -> TransportPayload
    {
        try Task.checkCancellation()
        let response = try await backend.send(body: operation.requestBody(), mode: state.mode, headers: state.headers)
        switch state.mode {
        case .json:
            return TransportPayload(data: try decodeJSONResponse(response, schema: responseSchema), mode: .json)
        case .binary:
            guard response.status == 200 else {
                throw HTTPFailure(
                    statusCode: response.status,
                    error: LuxoBinaryProtocol.decodeError(response.body, statusCode: response.status))
            }
            guard !response.body.isEmpty else {
                throw LuxoBinaryProtocol.missingResponse(statusCode: response.status)
            }
            // Return raw bytes for binary decoding.
            return TransportPayload(data: response.body, mode: .binary)
        }
    }

    private func decodeJSONResponse(_ response: HTTPBackendResponse, schema: LuxoJSONReadSchema?) throws -> Data {
        let data = response.body
        let envelope = try decodeJSONEnvelope(data, statusCode: response.status, schema: schema)
        if response.status != 200 || envelope.fields["error"] != nil {
            throw HTTPFailure(
                statusCode: response.status,
                error: JSONEnvelope.decodeError(envelope, statusCode: response.status))
        }
        guard let data = envelope.responseData else {
            throw LuxoError(code: response.status, message: "missing JSON response data", name: "ParseError")
        }
        return data
    }

    private func decodeJSONEnvelope(_ data: Data, statusCode: Int, schema: LuxoJSONReadSchema?) throws -> JSONEnvelope {
        do {
            return try JSONEnvelope.decode(
                data, errorResponse: statusCode != 200, schema: schema, untypedSuccess: schema == nil)
        } catch {
            throw LuxoError(code: statusCode, message: "invalid JSON response", name: "ParseError")
        }
    }

    private func encodeRequest(_ api: String, params: RequestParameters, state: State) throws -> Data {
        switch state.mode {
        case .json:
            return try LuxoJSONRequest.encode(api: api, params: params.json(), plan: state.schema[api]?.jsonParameters)
        case .binary:
            guard let apiSchema = state.schema[api] else {
                throw LuxoError(
                    code: 0,
                    message: "no schema for API \"\(api)\" — binary mode requires schema",
                    name: "ConfigError")
            }
            return try params.binary(schema: apiSchema)
        }
    }
}
