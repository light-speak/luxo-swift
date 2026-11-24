import Foundation

// Frozen UInt64 transport before terminal support; benchmark-only, never a production fallback.
/// WebSocket transport for streaming (subscriptions) and bidirectional communication.
/// Supports exponential backoff auto-reconnect on disconnect.
public final class PreTerminalWebSocketTransport: BenchmarkTransport, @unchecked Sendable {
    // A callback retains only this identity, never the socket that retains its receiver.
    private final class ConnectionIdentity: Sendable {}

    private struct Subscription {
        let mode: TransportMode
        let message: URLSessionWebSocketTask.Message
        let handler: @Sendable (Data) -> Void
        var acknowledged = false
    }

    private struct Pending<Value> {
        let continuation: CheckedContinuation<Value, Error>
        let timeoutTask: DispatchWorkItem

        func fail(_ error: Error) {
            timeoutTask.cancel()
            continuation.resume(throwing: error)
        }
    }

    // Both fields are accessed only under the owning transport's state lock.
    private final class SubscriptionAttempt: @unchecked Sendable {
        var id: UInt64?
        var cancelled = false
    }

    private struct Request {
        let id: UInt64
        let socket: LuxoWebSocketTask
        let mode: TransportMode
        let message: URLSessionWebSocketTask.Message
    }

    private let url: URL
    private let session: LuxoWebSocketSession
    private let lock = NSLock()
    // No state lock is held while calling a socket. Recursive entry permits inline callbacks.
    private let sendOrder = NSRecursiveLock()
    private let timeout: TimeInterval
    private var task: LuxoWebSocketTask?
    private var connectionIdentity = ConnectionIdentity()
    private var subscriptions: [UInt64: Subscription] = [:]
    private var pending: [UInt64: Pending<Data>] = [:]
    private var pendingSubscriptions: [UInt64: Pending<UInt64>] = [:]
    private var schema: [String: APISchema] = [:]
    private var mode: TransportMode = .json
    private var token: String?
    private var sequence: UInt64 = 0
    private var shouldReconnect = true
    private var reconnectAttempt = 0
    private var reconnectWork: DispatchWorkItem?
    private let maxBackoff: TimeInterval
    private let baseBackoff: TimeInterval

    public convenience init(url: String, token: String? = nil, timeout: TimeInterval = 30) throws {
        try self.init(url: url, token: token, timeout: timeout, session: URLSession(configuration: .default))
    }

    init(
        url: String, token: String? = nil, timeout: TimeInterval = 30,
        session: LuxoWebSocketSession, baseBackoff: TimeInterval = 1,
        maxBackoff: TimeInterval = 30, initialSequence: UInt64 = 0
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
        sequence = initialSequence
    }

    public func setToken(_ token: String) { lock.withLock { self.token = token } }
    public func setMode(_ mode: TransportMode) { lock.withLock { self.mode = mode } }
    public func setSchema(_ schema: [String: APISchema]) { lock.withLock { self.schema = schema } }

    public func connect() {
        sendOrder.withLock {
            let previous = lock.withLock {
                shouldReconnect = true
                reconnectAttempt = 0
                reconnectWork?.cancel()
                reconnectWork = nil
                let socket = task
                task = nil
                return (socket, removePendingLocked())
            }
            previous.0?.cancel(with: .goingAway, reason: nil)
            finishPending(
                previous.1, error: LuxoError(code: 0, message: "WebSocket reconnected", name: "ConnectionError"))
            openConnection()
        }
    }

    public func call(_ api: String, params: [String: LuxoValue]? = nil) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            do {
                try sendOrder.withLock {
                    let state = try lock.withLock { () throws -> (Request, DispatchWorkItem) in
                        let request = try prepareRequestLocked(api, params: params, subscription: false)
                        let timer = callTimeout(request.id, api: api)
                        pending[request.id] = Pending(continuation: continuation, timeoutTask: timer)
                        return (request, timer)
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: state.1)
                    let id = state.0.id
                    state.0.socket.send(state.0.message) { [weak self] error in
                        if let error { self?.failPending(id, error: Self.networkError(error)) }
                    }
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    public func subscribe(
        _ api: String, params: [String: LuxoValue]? = nil,
        observer: StreamObserver? = nil,
        handler: @escaping @Sendable (Data) -> Void
    ) async throws -> (@Sendable () -> Void) {
        let attempt = SubscriptionAttempt()
        let id = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startSubscription(api, params: params, handler: handler, attempt: attempt, continuation: continuation)
            }
        } onCancel: {
            self.cancelAttempt(attempt)
        }
        if Task.isCancelled {
            unsubscribe(id)
            throw CancellationError()
        }
        return { [weak self] in self?.unsubscribe(id) }
    }

    private func startSubscription(
        _ api: String, params: [String: LuxoValue]?, handler: @escaping @Sendable (Data) -> Void,
        attempt: SubscriptionAttempt, continuation: CheckedContinuation<UInt64, Error>
    ) {
        do {
            try sendOrder.withLock {
                let state = try lock.withLock { () throws -> (Request, DispatchWorkItem) in
                    if attempt.cancelled { throw CancellationError() }
                    let request = try prepareRequestLocked(api, params: params, subscription: true)
                    attempt.id = request.id
                    let timer = subscriptionTimeout(request.id, api: api)
                    subscriptions[request.id] = Subscription(
                        mode: request.mode, message: request.message, handler: handler)
                    pendingSubscriptions[request.id] = Pending(continuation: continuation, timeoutTask: timer)
                    return (request, timer)
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: state.1)
                let id = state.0.id
                state.0.socket.send(state.0.message) { [weak self] error in
                    if let error {
                        self?.failSubscription(
                            id, error: Self.networkError(error), cancelRemote: false, pendingOnly: true)
                    }
                }
            }
        } catch {
            continuation.resume(throwing: error)
        }
    }

    private func prepareRequestLocked(_ api: String, params: [String: LuxoValue]?, subscription: Bool) throws -> Request
    {
        guard let socket = task else {
            throw LuxoError(code: 0, message: "WebSocket not connected", name: "ConnectionError")
        }
        guard sequence < UInt64.max else {
            throw LuxoError(code: 0, message: "WebSocket request IDs exhausted", name: "RequestIDExhausted")
        }
        sequence += 1
        let message: URLSessionWebSocketTask.Message
        if mode == .binary {
            guard let apiSchema = schema[api] else {
                throw LuxoError(
                    code: 0, message: "no schema for API \"\(api)\" — binary mode requires schema", name: "ConfigError")
            }
            let body = try LuxoBinaryProtocol.encodeRequest(schema: apiSchema, params: params)
            message = .data(
                subscription
                    ? LuxoBinaryProtocol.subscribeFrame(sequence: sequence, body: body)
                    : LuxoBinaryProtocol.callFrame(sequence: sequence, body: body))
        } else {
            let body = try LuxoJSONRequest.encode(
                api: api, params: params, plan: schema[api]?.jsonParameters, sequence: sequence,
                subscription: subscription)
            message = .string(String(decoding: body, as: UTF8.self))
        }
        return Request(id: sequence, socket: socket, mode: mode, message: message)
    }

    private func cancelAttempt(_ attempt: SubscriptionAttempt) {
        let id = lock.withLock { () -> UInt64? in
            attempt.cancelled = true
            return attempt.id
        }
        if let id { unsubscribe(id) }
    }

    private func unsubscribe(_ id: UInt64) {
        failSubscription(id, error: CancellationError(), cancelRemote: true)
    }

    private func failSubscription(_ id: UInt64, error: Error, cancelRemote: Bool, pendingOnly: Bool = false) {
        sendOrder.withLock {
            let state = lock.withLock { () -> (Pending<UInt64>?, LuxoWebSocketTask?, TransportMode?) in
                if pendingOnly && pendingSubscriptions[id] == nil { return (nil, nil, nil) }
                let subscription = subscriptions.removeValue(forKey: id)
                return (pendingSubscriptions.removeValue(forKey: id), task, subscription?.mode)
            }
            state.0?.fail(error)
            guard cancelRemote, let socket = state.1, let mode = state.2 else { return }
            let message: URLSessionWebSocketTask.Message =
                mode == .binary
                ? .data(LuxoBinaryProtocol.unsubscribeFrame(sequence: id))
                : .string("{\"$unsub\":\(id)}")
            socket.send(message) { _ in }
        }
    }

    public func close() {
        sendOrder.withLock {
            let state = lock.withLock {
                shouldReconnect = false
                reconnectWork?.cancel()
                reconnectWork = nil
                let socket = task
                task = nil
                let waiting = removePendingLocked()
                subscriptions.removeAll()
                return (socket, waiting)
            }
            state.0?.cancel(with: .normalClosure, reason: nil)
            finishPending(
                state.1, error: LuxoError(code: 0, message: "WebSocket closed by client", name: "ConnectionError"))
        }
    }

    // Caller holds sendOrder: restored IDs are queued before any new subscription.
    private func openConnection() {
        let request = lock.withLock { () -> URLRequest? in
            guard shouldReconnect, task == nil else { return nil }
            var request = URLRequest(url: url)
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            return request
        }
        guard let request else { return }
        let socket = session.makeWebSocketTask(with: request)
        let identity = ConnectionIdentity()
        let restored = lock.withLock { () -> [URLSessionWebSocketTask.Message]? in
            guard shouldReconnect, task == nil else { return nil }
            task = socket
            connectionIdentity = identity
            return subscriptions.keys.sorted().compactMap { id in
                subscriptions[id]?.acknowledged = false
                return subscriptions[id]?.message
            }
        }
        guard let restored else { socket.cancel(with: .goingAway, reason: nil); return }
        socket.resume()
        receiveLoop(socket, identity: identity)
        for message in restored {
            guard lock.withLock({ task === socket }) else { break }
            socket.send(message) { [weak self, weak socket] error in
                if let error, let socket { self?.connectionLost(socket, error: error) }
            }
        }
    }

    private func receiveLoop(_ socket: LuxoWebSocketTask, identity: ConnectionIdentity) {
        socket.receive { [weak self] result in
            guard let self else { return }
            let current = self.lock.withLock { () -> LuxoWebSocketTask? in
                guard self.connectionIdentity === identity, let current = self.task else { return nil }
                if case .success = result { self.reconnectAttempt = 0 }
                return current
            }
            guard let socket = current else { return }
            switch result {
            case .success(let message):
                self.handleMessage(message, socket: socket)
                if self.lock.withLock({ self.task === socket }) { self.receiveLoop(socket, identity: identity) }
            case .failure(let error):
                self.connectionLost(socket, error: error)
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message, socket: LuxoWebSocketTask) {
        switch message {
        case .data(let data): handleBinaryMessage(data, socket: socket)
        case .string(let text): handleJSONData(Data(text.utf8), socket: socket)
        @unknown default: break
        }
    }

    private func handleJSONData(_ data: Data, socket: LuxoWebSocketTask) {
        guard let envelope = try? PreTerminalJSONEnvelope.decode(data) else { return }
        let json = envelope.fields
        if json["$sub"] != nil {
            if let fields = try? envelope.materializedFields(),
                let acknowledgement = PreTerminalWebSocketProtocol.decodeJSONSubscriptionAcknowledgement(values: fields)
            {
                acknowledgeSubscription(acknowledgement, mode: .json, socket: socket)
            }
        } else if json["$stream"] != nil {
            guard let id = PreTerminalWebSocketProtocol.jsonRequestID(value: json["$stream"]),
                let handler = streamHandler(id, mode: .json, socket: socket)
            else { return }
            handler(envelope.responseData)
        } else {
            handleJSONCall(envelope, socket: socket)
        }
    }

    private func handleJSONCall(_ envelope: PreTerminalJSONEnvelope, socket: LuxoWebSocketTask) {
        let json = envelope.fields
        guard let id = PreTerminalWebSocketProtocol.jsonRequestID(value: json["$id"]),
            let state = takePending(id, socket: socket)
        else { return }
        state.timeoutTask.cancel()
        if json["error"] != nil {
            state.continuation.resume(throwing: PreTerminalJSONEnvelope.decodeError(envelope, statusCode: 0))
        } else {
            state.continuation.resume(returning: envelope.responseData)
        }
    }

    private func handleBinaryMessage(_ data: Data, socket: LuxoWebSocketTask) {
        guard let frame = PreTerminalWebSocketProtocol.decodeBinaryFrame(data) else { return }
        if let acknowledgement = PreTerminalWebSocketProtocol.subscriptionAcknowledgement(frame) {
            acknowledgeSubscription(acknowledgement, mode: .binary, socket: socket)
            return
        }
        switch frame.type {
        case LuxoBinaryProtocol.callSuccess:
            if let state = takePending(frame.id, socket: socket) {
                state.timeoutTask.cancel()
                state.continuation.resume(returning: frame.payload)
            }
        case LuxoBinaryProtocol.callError:
            takePending(frame.id, socket: socket)?.fail(LuxoBinaryProtocol.decodeError(frame.payload, statusCode: 0))
        case LuxoBinaryProtocol.stream:
            streamHandler(frame.id, mode: .binary, socket: socket)?(frame.payload)
        default: break
        }
    }

    private func streamHandler(_ id: UInt64, mode: TransportMode, socket: LuxoWebSocketTask) -> (
        @Sendable (Data) -> Void
    )? {
        lock.withLock {
            guard task === socket, let subscription = subscriptions[id], subscription.mode == mode,
                subscription.acknowledged
            else { return nil }
            return subscription.handler
        }
    }

    private func acknowledgeSubscription(
        _ acknowledgement: PreTerminalWebSocketProtocol.SubscriptionAcknowledgement, mode: TransportMode,
        socket: LuxoWebSocketTask
    ) {
        let state = lock.withLock { () -> Pending<UInt64>? in
            guard task === socket, subscriptions[acknowledgement.id]?.mode == mode else { return nil }
            if acknowledgement.error != nil {
                subscriptions.removeValue(forKey: acknowledgement.id)
            } else {
                subscriptions[acknowledgement.id]?.acknowledged = true
            }
            return pendingSubscriptions.removeValue(forKey: acknowledgement.id)
        }
        guard let state else { return }
        state.timeoutTask.cancel()
        if let error = acknowledgement.error {
            state.continuation.resume(throwing: error)
        } else {
            state.continuation.resume(returning: acknowledgement.id)
        }
    }

    private func takePending(_ id: UInt64, socket: LuxoWebSocketTask) -> Pending<Data>? {
        lock.withLock {
            guard task === socket else { return nil }
            return pending.removeValue(forKey: id)
        }
    }

    private func failPending(_ id: UInt64, error: Error) {
        lock.withLock { pending.removeValue(forKey: id) }?.fail(error)
    }

    private func callTimeout(_ id: UInt64, api: String) -> DispatchWorkItem {
        DispatchWorkItem { [weak self] in
            self?.failPending(
                id, error: LuxoError(code: 0, message: "WebSocket call \"\(api)\" timed out", name: "TimeoutError"))
        }
    }

    private func subscriptionTimeout(_ id: UInt64, api: String) -> DispatchWorkItem {
        DispatchWorkItem { [weak self] in
            self?.failSubscription(
                id,
                error: LuxoError(code: 0, message: "WebSocket subscription \"\(api)\" timed out", name: "TimeoutError"),
                cancelRemote: true, pendingOnly: true)
        }
    }

    private func removePendingLocked() -> ([Pending<Data>], [Pending<UInt64>]) {
        let state = (Array(pending.values), Array(pendingSubscriptions.values))
        for id in pendingSubscriptions.keys { subscriptions.removeValue(forKey: id) }
        pending.removeAll()
        pendingSubscriptions.removeAll()
        return state
    }

    private func finishPending(_ state: ([Pending<Data>], [Pending<UInt64>]), error: Error) {
        state.0.forEach { $0.fail(error) }
        state.1.forEach { $0.fail(error) }
    }

    private static func networkError(_ error: Error) -> LuxoError {
        LuxoError(code: 0, message: error.localizedDescription, name: "NetworkError")
    }

    private func connectionLost(_ socket: LuxoWebSocketTask, error: Error) {
        sendOrder.withLock {
            let waiting = lock.withLock { () -> ([Pending<Data>], [Pending<UInt64>])? in
                guard task === socket else { return nil }
                task = nil
                return removePendingLocked()
            }
            guard let waiting else { return }
            socket.cancel(with: .goingAway, reason: nil)
            finishPending(
                waiting,
                error: LuxoError(
                    code: 0, message: "WebSocket connection lost: \(error.localizedDescription)",
                    name: "ConnectionError"))
            scheduleReconnect()
        }
    }

    private func scheduleReconnect() {
        let state = lock.withLock { () -> (TimeInterval, DispatchWorkItem)? in
            guard shouldReconnect, task == nil else { return nil }
            reconnectWork?.cancel()
            let delay = min(baseBackoff * pow(2, Double(min(reconnectAttempt, 64))), maxBackoff)
            reconnectAttempt = min(reconnectAttempt + 1, 64)
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.sendOrder.withLock { self.openConnection() }
            }
            reconnectWork = work
            return (delay, work)
        }
        if let state { DispatchQueue.global().asyncAfter(deadline: .now() + state.0, execute: state.1) }
    }
}
