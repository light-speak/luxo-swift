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

public final class HTTPTransport<Backend: HTTPBackend>: Transport, @unchecked Sendable {
    private final class CredentialRevision: Sendable {}

    private struct HTTPFailure: Error {
        let statusCode: Int
        let error: LuxoError
    }

    private struct State {
        let headers: [String: String]
        let mode: TransportMode
        let schema: [String: APISchema]
        let credentialRevision: CredentialRevision?
    }

    /// The concrete backend owns its network lifecycle.
    public let backend: Backend
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var headers: [String: String] = [:]
    private var credentialRevision: CredentialRevision?
    private var mode: TransportMode = .json
    private var schema: [String: APISchema] = [:]
    private var tokenExpiredHandler: (() async -> String?)?

    /// Called only when HTTP status and the validated error code are both 401.
    /// Return a new token to retry once, or nil to propagate the original error.
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
        lock.withLock {
            credentialRevision = CredentialRevision()
            headers["Authorization"] = "Bearer \(token)"
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
            let refresh = lock.withLock {
                credentialRevision === state.credentialRevision ? tokenExpiredHandler : nil
            }
            if let refresh, let newToken = await refresh() {
                try Task.checkCancellation()
                let retry = try lock.withLock {
                    guard credentialRevision === state.credentialRevision else { throw error }
                    credentialRevision = CredentialRevision()
                    headers["Authorization"] = "Bearer \(newToken)"
                    return State(
                        headers: headers, mode: state.mode, schema: state.schema,
                        credentialRevision: credentialRevision)
                }
                do {
                    return try await doCall(
                        operation: operation, state: retry, responseSchema: state.schema[api]?.response)
                } catch let retryFailure as HTTPFailure {
                    throw retryFailure.error
                }
            }
            throw error
        }
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
