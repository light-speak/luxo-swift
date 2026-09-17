import Foundation

// Frozen pre-UInt64-subscription transport for paired benchmarks only.
// Only symbol names, old wire helpers and the closure's Sendable annotation differ.
// Shared JSON/codec implementations deliberately remain identical on both sides.
final class LegacyWebSocketTransport: BenchmarkTransport, @unchecked Sendable {
    private struct Subscription {
        let params: [String: LuxoValue]
        let handler: @Sendable (Data) -> Void
    }

    private struct PendingCall {
        let continuation: CheckedContinuation<Data, Error>
        let timeoutTask: DispatchWorkItem
    }

    private struct PendingSubscription {
        let continuation: CheckedContinuation<Void, Error>
        let timeoutTask: DispatchWorkItem
    }

    private let url: URL
    private let session: LuxoWebSocketSession
    private let lock = NSLock()
    private let timeout: TimeInterval
    private var task: LuxoWebSocketTask?
    private var subscriptions: [String: Subscription] = [:]
    private var pending: [UInt64: PendingCall] = [:]
    private var pendingSubscriptions: [String: PendingSubscription] = [:]
    private var schema: [String: APISchema] = [:]
    private var apiByID: [UInt64: String] = [:]
    private var mode: TransportMode = .json
    private var token: String?
    private var sequence: UInt64 = 0

    private var shouldReconnect = true
    private var reconnectAttempt = 0
    private let maxBackoff: TimeInterval
    private let baseBackoff: TimeInterval

    public convenience init(
        url: String,
        token: String? = nil,
        timeout: TimeInterval = 30
    ) throws {
        try self.init(
            url: url,
            token: token,
            timeout: timeout,
            session: URLSession(configuration: .default),
            baseBackoff: 1,
            maxBackoff: 30
        )
    }

    init(
        url: String,
        token: String? = nil,
        timeout: TimeInterval = 30,
        session: LuxoWebSocketSession,
        baseBackoff: TimeInterval = 1,
        maxBackoff: TimeInterval = 30,
        initialSequence: UInt64 = 0
    ) throws {
        self.url = try validatedURL(url, schemes: ["ws", "wss"])
        guard timeout > 0 else {
            throw LuxoError(code: 0, message: "timeout must be greater than zero", name: "ConfigError")
        }
        guard baseBackoff > 0, maxBackoff >= baseBackoff else {
            throw LuxoError(code: 0, message: "invalid reconnect backoff", name: "ConfigError")
        }
        self.token = token
        self.timeout = timeout
        self.session = session
        self.baseBackoff = baseBackoff
        self.maxBackoff = maxBackoff
        self.sequence = initialSequence
    }

    public func setToken(_ token: String) {
        lock.withLock { self.token = token }
    }

    public func setMode(_ mode: TransportMode) {
        lock.withLock { self.mode = mode }
    }

    public func setSchema(_ schema: [String: APISchema]) {
        lock.withLock {
            self.schema = schema
            self.apiByID = Dictionary(uniqueKeysWithValues: schema.map { (UInt64($0.value.id), $0.key) })
        }
    }

    public func connect() {
        let previous = lock.withLock { () -> LuxoWebSocketTask? in
            shouldReconnect = true
            reconnectAttempt = 0
            let current = task
            task = nil
            return current
        }
        previous?.cancel(with: .goingAway, reason: nil)
        openConnection()
    }

    public func call(_ api: String, params: [String: LuxoValue]? = nil) async throws -> Data {
        let request = try lock.withLock { () throws -> (UInt64, LuxoWebSocketTask, URLSessionWebSocketTask.Message) in
            guard let socket = task else {
                throw LuxoError(code: 0, message: "WebSocket not connected", name: "ConnectionError")
            }
            guard sequence < UInt64.max else {
                throw LuxoError(code: 0, message: "WebSocket request IDs exhausted", name: "RequestIDExhausted")
            }
            sequence += 1
            let requestID = sequence
            if mode == .binary {
                guard let apiSchema = schema[api] else {
                    throw LuxoError(
                        code: 0,
                        message: "no schema for API \"\(api)\" — binary mode requires schema",
                        name: "ConfigError"
                    )
                }
                let body = try LuxoBinaryProtocol.encodeRequest(schema: apiSchema, params: params)
                return (requestID, socket, .data(LuxoBinaryProtocol.callFrame(sequence: requestID, body: body)))
            }
            let data = try LegacySubscriptionProtocol.jsonCallFrame(
                sequence: requestID, api: api, params: params, plan: schema[api]?.jsonParameters)
            return (requestID, socket, .string(String(decoding: data, as: UTF8.self)))
        }

        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = DispatchWorkItem { [weak self] in
                self?.failPending(
                    request.0,
                    error: LuxoError(
                        code: 0,
                        message: "WebSocket call \"\(api)\" timed out",
                        name: "TimeoutError"
                    ))
            }
            lock.withLock {
                pending[request.0] = PendingCall(
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutTask)
            let requestID = request.0
            request.1.send(request.2) { [weak self] error in
                guard let error else { return }
                self?.failPending(
                    requestID,
                    error: LuxoError(
                        code: 0,
                        message: error.localizedDescription,
                        name: "NetworkError"
                    ))
            }
        }
    }

    public func subscribe(
        _ api: String,
        params: [String: LuxoValue]? = nil,
        observer: StreamObserver? = nil,
        handler: @escaping @Sendable (Data) -> Void
    ) async throws -> (@Sendable () -> Void) {
        let values = params ?? [:]
        let request = try subscriptionMessage(api, params: values)
        try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = DispatchWorkItem { [weak self] in
                self?.failSubscription(
                    api,
                    error: LuxoError(
                        code: 0,
                        message: "WebSocket subscription \"\(api)\" timed out",
                        name: "TimeoutError"
                    ))
            }
            let duplicate = lock.withLock { () -> Bool in
                guard subscriptions[api] == nil else { return true }
                subscriptions[api] = Subscription(params: values, handler: handler)
                pendingSubscriptions[api] = PendingSubscription(
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
                return false
            }
            if duplicate {
                continuation.resume(
                    throwing: LuxoError(
                        code: 0,
                        message: "already subscribed to \"\(api)\"",
                        name: "ConfigError"
                    ))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutTask)
            request.0.send(request.1) { [weak self] error in
                guard let error else { return }
                self?.failSubscription(
                    api,
                    error: LuxoError(
                        code: 0,
                        message: error.localizedDescription,
                        name: "NetworkError"
                    ))
            }
        }
        return { [weak self] in self?.unsubscribe(api) }
    }

    public func unsubscribe(_ api: String) {
        let result: (LuxoWebSocketTask?, URLSessionWebSocketTask.Message?) = lock.withLock {
            guard subscriptions.removeValue(forKey: api) != nil else { return (nil, nil) }
            pendingSubscriptions.removeValue(forKey: api)?.timeoutTask.cancel()
            if mode == .binary, let apiSchema = schema[api] {
                return (task, .data(LegacySubscriptionProtocol.unsubscribeFrame(apiID: apiSchema.id)))
            }
            let data = try? JSONSerialization.data(withJSONObject: ["$unsub": api])
            return (task, data.map { .string(String(decoding: $0, as: UTF8.self)) })
        }
        if let socket = result.0, let message = result.1 { socket.send(message) { _ in } }
    }

    public func close() {
        let state = lock.withLock {
            () -> (
                LuxoWebSocketTask?,
                [PendingCall],
                [PendingSubscription]
            ) in
            shouldReconnect = false
            let socket = task
            task = nil
            subscriptions.removeAll()
            let calls = Array(pending.values)
            let acknowledgements = Array(pendingSubscriptions.values)
            pending.removeAll()
            pendingSubscriptions.removeAll()
            return (socket, calls, acknowledgements)
        }
        state.0?.cancel(with: .normalClosure, reason: nil)
        let error = LuxoError(code: 0, message: "WebSocket closed by client", name: "ConnectionError")
        state.1.forEach {
            $0.timeoutTask.cancel()
            $0.continuation.resume(throwing: error)
        }
        state.2.forEach {
            $0.timeoutTask.cancel()
            $0.continuation.resume(throwing: error)
        }
    }

    private func openConnection() {
        let request: URLRequest = lock.withLock {
            var request = URLRequest(url: url)
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            return request
        }
        let socket = session.makeWebSocketTask(with: request)
        lock.withLock { task = socket }
        socket.resume()
        let currentSubscriptions = lock.withLock { subscriptions }
        for (api, subscription) in currentSubscriptions {
            sendConfirmedSubscription(api, params: subscription.params, socket: socket)
        }
        receiveLoop(socket)
    }

    private func receiveLoop(_ socket: LuxoWebSocketTask) {
        socket.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                self.lock.withLock { self.reconnectAttempt = 0 }
                self.handleMessage(message)
                self.receiveLoop(socket)
            case .failure(let error):
                let current = self.lock.withLock { () -> Bool in
                    guard self.task === socket else { return false }
                    self.task = nil
                    return true
                }
                guard current else { return }
                self.failAllPending(error)
                self.scheduleReconnect()
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .data(let data):
            if lock.withLock({ mode }) == .binary {
                handleBinaryMessage(data)
            } else {
                handleJSONData(data)
            }
        case .string(let text):
            handleJSONData(Data(text.utf8))
        @unknown default:
            break
        }
    }

    private func handleJSONData(_ data: Data) {
        guard let value = try? LuxoValue.decodeJSONData(data), case .object(let json) = value else { return }
        if let acknowledgement = LegacySubscriptionProtocol.decodeJSONSubscriptionAcknowledgement(values: json),
            let api = acknowledgement.api
        {
            acknowledgeSubscription(api, error: acknowledgement.error)
            return
        }
        if case .string(let api) = json["$stream"] {
            let handler = lock.withLock { subscriptions[api]?.handler }
            if let data = try? (json["data"] ?? .null).jsonData() {
                handler?(data)
            }
            return
        }
        guard let requestID = LegacySubscriptionProtocol.jsonRequestID(value: json["$id"]) else { return }
        guard let state = lock.withLock({ pending.removeValue(forKey: requestID) }) else { return }
        state.timeoutTask.cancel()
        if json["error"] != nil {
            state.continuation.resume(throwing: LuxoError.fromResponse(values: json, statusCode: 0))
        } else {
            do {
                let data = try (json["data"] ?? .null).jsonData()
                state.continuation.resume(returning: data)
            } catch {
                state.continuation.resume(
                    throwing: LuxoError(code: 0, message: "invalid JSON response", name: "ParseError")
                )
            }
        }
    }

    private func handleBinaryMessage(_ data: Data) {
        guard let frame = LegacySubscriptionProtocol.decodeBinaryFrame(data) else { return }
        if let acknowledgement = LegacySubscriptionProtocol.subscriptionAcknowledgement(frame),
            let apiID = acknowledgement.apiID,
            let api = lock.withLock({ apiByID[apiID] })
        {
            acknowledgeSubscription(api, error: acknowledgement.error)
            return
        }
        switch frame.type {
        case LuxoBinaryProtocol.callSuccess:
            if let state = lock.withLock({ pending.removeValue(forKey: frame.id) }) {
                state.timeoutTask.cancel()
                state.continuation.resume(returning: frame.payload)
            }
        case LuxoBinaryProtocol.callError:
            if let state = lock.withLock({ pending.removeValue(forKey: frame.id) }) {
                state.timeoutTask.cancel()
                state.continuation.resume(
                    throwing: LuxoBinaryProtocol.decodeError(frame.payload, statusCode: 0)
                )
            }
        case 6:
            let handler = lock.withLock { () -> (@Sendable (Data) -> Void)? in
                guard let api = apiByID[frame.id] else { return nil }
                return subscriptions[api]?.handler
            }
            handler?(frame.payload)
        default:
            break
        }
    }

    private func subscriptionMessage(
        _ api: String,
        params: [String: LuxoValue]
    ) throws -> (LuxoWebSocketTask, URLSessionWebSocketTask.Message) {
        try lock.withLock {
            guard let socket = task else {
                throw LuxoError(code: 0, message: "WebSocket not connected", name: "ConnectionError")
            }
            if mode == .binary {
                guard let apiSchema = schema[api] else {
                    throw LuxoError(code: 0, message: "no schema for API \"\(api)\"", name: "ConfigError")
                }
                let body = try LuxoBinaryProtocol.encodeRequest(schema: apiSchema, params: params)
                return (socket, .data(LegacySubscriptionProtocol.subscribeFrame(body: body)))
            }
            let data = try LuxoJSONRequest.encode(
                api: api, params: params, plan: schema[api]?.jsonParameters, subscription: true)
            return (socket, .string(String(decoding: data, as: UTF8.self)))
        }
    }

    private func sendConfirmedSubscription(
        _ api: String,
        params: [String: LuxoValue],
        socket: LuxoWebSocketTask
    ) {
        guard let request = try? subscriptionMessage(api, params: params), request.0 === socket else { return }
        socket.send(request.1) { _ in }
    }

    private func failPending(_ id: UInt64, error: Error) {
        guard let state = lock.withLock({ pending.removeValue(forKey: id) }) else { return }
        state.timeoutTask.cancel()
        state.continuation.resume(throwing: error)
    }

    private func failSubscription(_ api: String, error: Error) {
        let state = lock.withLock { () -> PendingSubscription? in
            subscriptions.removeValue(forKey: api)
            return pendingSubscriptions.removeValue(forKey: api)
        }
        guard let state else { return }
        state.timeoutTask.cancel()
        state.continuation.resume(throwing: error)
    }

    private func acknowledgeSubscription(_ api: String, error: LuxoError?) {
        let state = lock.withLock { () -> PendingSubscription? in
            if error != nil { subscriptions.removeValue(forKey: api) }
            return pendingSubscriptions.removeValue(forKey: api)
        }
        state?.timeoutTask.cancel()
        guard let state else { return }
        if let error {
            state.continuation.resume(throwing: error)
        } else {
            state.continuation.resume()
        }
    }

    private func failAllPending(_ underlyingError: Error) {
        let state = lock.withLock { () -> ([PendingCall], [PendingSubscription]) in
            let calls = Array(pending.values)
            let acknowledgements = Array(pendingSubscriptions.values)
            for api in pendingSubscriptions.keys { subscriptions.removeValue(forKey: api) }
            pending.removeAll()
            pendingSubscriptions.removeAll()
            return (calls, acknowledgements)
        }
        let error = LuxoError(
            code: 0,
            message: "WebSocket connection lost: \(underlyingError.localizedDescription)",
            name: "ConnectionError"
        )
        state.0.forEach {
            $0.timeoutTask.cancel()
            $0.continuation.resume(throwing: error)
        }
        state.1.forEach {
            $0.timeoutTask.cancel()
            $0.continuation.resume(throwing: error)
        }
    }

    private func scheduleReconnect() {
        let delay: TimeInterval? = lock.withLock {
            guard shouldReconnect else { return nil }
            let value = min(baseBackoff * pow(2, Double(reconnectAttempt)), maxBackoff)
            reconnectAttempt += 1
            return value
        }
        guard let delay else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.lock.withLock({ self.shouldReconnect }) else { return }
            self.openConnection()
        }
    }
}
private enum LegacySubscriptionProtocol {
    struct Acknowledgement {
        var api: String?
        var apiID: UInt64?
        var error: LuxoError?
    }

    static func jsonCallFrame(
        sequence: UInt64, api: String, params: [String: LuxoValue]?, plan: JSONParameterPlan? = nil
    ) throws -> Data {
        try LuxoWebSocketProtocol.jsonCallFrame(sequence: sequence, api: api, params: params, plan: plan)
    }

    static func jsonRequestID(value: LuxoValue?) -> UInt64? {
        LuxoWebSocketProtocol.jsonRequestID(value: value)
    }

    static func decodeJSONSubscriptionAcknowledgement(values: [String: LuxoValue]) -> Acknowledgement? {
        guard case .string(let api) = values["$sub"] else { return nil }
        if case .bool(true) = values["ok"] { return Acknowledgement(api: api) }
        guard values["error"] != nil else { return nil }
        return Acknowledgement(api: api, error: LuxoError.fromResponse(values: values, statusCode: 0))
    }

    static func decodeBinaryFrame(_ data: Data) -> LuxoWebSocketProtocol.BinaryFrame? {
        guard let byte = data.first else { return nil }
        switch byte {
        case 2, 3, 6, 7, 8: break
        default: return nil
        }
        var decoder = Decoder(data)
        let type = decoder.readVarint()
        let id = decoder.readVarint()
        guard decoder.error == nil else { return nil }
        return LuxoWebSocketProtocol.BinaryFrame(type: type, id: id, payload: decoder.readRemainingData())
    }

    static func subscriptionAcknowledgement(_ frame: LuxoWebSocketProtocol.BinaryFrame) -> Acknowledgement? {
        guard frame.type == 7 || frame.type == 8 else { return nil }
        if frame.type == 7 && !frame.payload.isEmpty { return nil }
        return Acknowledgement(
            apiID: frame.id, error: frame.type == 8 ? LuxoBinaryProtocol.decodeError(frame.payload, statusCode: 0) : nil
        )
    }

    static func subscribeFrame(body: Data) -> Data { frame(4, body) }

    static func unsubscribeFrame(apiID: Int) -> Data {
        var encoder = Encoder()
        encoder.writeVarint(UInt64(apiID))
        return frame(5, encoder.data)
    }

    private static func frame(_ type: UInt64, _ body: Data) -> Data {
        var encoder = Encoder()
        encoder.writeVarint(type)
        encoder.writeRawBytes(body)
        return encoder.data
    }
}
