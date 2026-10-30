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
    private struct HTTPFailure: Error {
        let statusCode: Int
        let error: LuxoError
    }

    private struct State {
        let headers: [String: String]
        let mode: TransportMode
        let schema: [String: APISchema]
    }

    /// The concrete backend owns its network lifecycle.
    public let backend: Backend
    private let lock = NSLock()
    private var headers: [String: String] = [:]
    private var mode: TransportMode = .json
    private var schema: [String: APISchema] = [:]
    private var tokenExpiredHandler: (() async -> String?)?

    /// Called only when HTTP status and the validated error code are both 401.
    /// Return a new token to retry once, or nil to propagate the original error.
    public var onTokenExpired: (() async -> String?)? {
        get { lock.withLock { tokenExpiredHandler } }
        set { lock.withLock { tokenExpiredHandler = newValue } }
    }

    public init(backend: Backend, token: String? = nil) {
        self.backend = backend
        if let token { headers["Authorization"] = "Bearer \(token)" }
    }

    public func setToken(_ token: String) {
        lock.withLock { headers["Authorization"] = "Bearer \(token)" }
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
        do {
            return try await doCall(api, params: params)
        } catch let failure as HTTPFailure {
            let error = failure.error
            guard failure.statusCode == 401, error.code == 401, error.name != "ParseError" else {
                throw error
            }
            let refresh = lock.withLock { tokenExpiredHandler }
            if let refresh, let newToken = await refresh() {
                setToken(newToken)
                do {
                    return try await doCall(api, params: params)
                } catch let retryFailure as HTTPFailure {
                    throw retryFailure.error
                }
            }
            throw error
        }
    }

    private func doCall(_ api: String, params: RequestParameters) async throws -> TransportPayload {
        let state = lock.withLock {
            State(headers: headers, mode: mode, schema: schema)
        }
        let data: Data
        switch state.mode {
        case .json:
            data = try await jsonCall(
                api, params: params.json(), headers: state.headers, plan: state.schema[api]?.jsonParameters)
        case .binary:
            data = try await binaryCall(
                api,
                params: params,
                headers: state.headers,
                schema: state.schema
            )
        }
        return TransportPayload(data: data, mode: state.mode)
    }

    private func jsonCall(
        _ api: String,
        params: [String: LuxoValue]?,
        headers: [String: String],
        plan: JSONParameterPlan?
    ) async throws -> Data {
        let body = try LuxoJSONRequest.encode(api: api, params: params, plan: plan)
        let response = try await backend.send(body: body, mode: .json, headers: headers)
        let data = response.body
        let envelope = try decodeJSONEnvelope(data, statusCode: response.status)
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

    private func decodeJSONEnvelope(_ data: Data, statusCode: Int) throws -> JSONEnvelope {
        do {
            return try JSONEnvelope.decode(data, errorResponse: statusCode != 200)
        } catch {
            throw LuxoError(code: statusCode, message: "invalid JSON response", name: "ParseError")
        }
    }

    private func binaryCall(
        _ api: String,
        params: RequestParameters,
        headers: [String: String],
        schema: [String: APISchema]
    ) async throws -> Data {
        guard let apiSchema = schema[api] else {
            throw LuxoError(
                code: 0,
                message: "no schema for API \"\(api)\" — binary mode requires schema",
                name: "ConfigError"
            )
        }
        let body = try params.binary(schema: apiSchema)

        let response = try await backend.send(body: body, mode: .binary, headers: headers)
        let data = response.body
        guard response.status == 200 else {
            throw HTTPFailure(
                statusCode: response.status,
                error: LuxoBinaryProtocol.decodeError(data, statusCode: response.status))
        }

        return data  // Return raw bytes for binary decoding
    }
}
