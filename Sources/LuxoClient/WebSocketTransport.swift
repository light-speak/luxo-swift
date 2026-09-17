import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// MARK: - WebSocket Transport

protocol LuxoWebSocketTask: AnyObject, Sendable {
    func resume()
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping @Sendable (Error?) -> Void)
    func receive(completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void)
}

extension URLSessionWebSocketTask: LuxoWebSocketTask {}

protocol LuxoWebSocketSession: AnyObject {
    func makeWebSocketTask(with request: URLRequest) -> LuxoWebSocketTask
}

extension URLSession: LuxoWebSocketSession {
    func makeWebSocketTask(with request: URLRequest) -> LuxoWebSocketTask { webSocketTask(with: request) }
}

/// WebSocket transport for streaming (subscriptions) and bidirectional communication.
/// Connections reconnect with backoff; interrupted subscriptions must be created again.
public final class WebSocketTransport: Transport, @unchecked Sendable {
    // A callback retains only this identity, never the socket that retains its receiver.
    private final class ConnectionIdentity: Sendable {}

    private struct Subscription {
        let mode: TransportMode
        let handler: @Sendable (TransportPayload) -> Void
        let observer: StreamObserver?
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

    private struct RetiredConnection {
        let calls: [Pending<TransportPayload>]
        let subscriptions: [Pending<UInt64>]
        let observers: [StreamObserver]
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
    private var pending: [UInt64: Pending<TransportPayload>] = [:]
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
            let error = LuxoError(code: 0, message: "WebSocket reconnected", name: "NetworkError")
            finishPending(
                previous.1, error: LuxoError(code: 0, message: "WebSocket reconnected", name: "ConnectionError"),
                subscriptionError: error)
            openConnection()
            notifyDisconnected(previous.1.observers, error: error)
        }
    }

    public func call(_ api: String, params: [String: LuxoValue]? = nil) async throws -> TransportPayload {
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

    public func subscribe<Value: Sendable>(
        _ api: String, decoder: @escaping @Sendable (TransportPayload) throws -> Value,
        params: [String: LuxoValue]? = nil,
        observer: StreamObserver? = nil,
        handler: @escaping @Sendable (Value) -> Void
    ) async throws -> (@Sendable () -> Void) {
        let attempt = SubscriptionAttempt()
        let id = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startSubscription(
                    api, decoder: decoder, params: params, observer: observer, handler: handler, attempt: attempt,
                    continuation: continuation)
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

    private func startSubscription<Value: Sendable>(
        _ api: String, decoder: @escaping @Sendable (TransportPayload) throws -> Value,
        params: [String: LuxoValue]?, observer: StreamObserver?,
        handler: @escaping @Sendable (Value) -> Void,
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
                        mode: request.mode,
                        handler: subscriptionHandler(request.id, decoder: decoder, handler: handler), observer: observer
                    )
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

    private func subscriptionHandler<Value: Sendable>(
        _ id: UInt64, decoder: @escaping @Sendable (TransportPayload) throws -> Value,
        handler: @escaping @Sendable (Value) -> Void
    ) -> @Sendable (TransportPayload) -> Void {
        { [weak self] payload in
            let value: Value
            do {
                value = try decoder(payload)
            } catch {
                self?.failDecoding(id, cause: error)
                return
            }
            // Application callbacks are outside the decoding error boundary.
            handler(value)
        }
    }

    private func failDecoding(_ id: UInt64, cause: Error) {
        let message = (cause as? LuxoError)?.message ?? "invalid subscription payload"
        let error = LuxoError(code: 0, message: message, name: "DecodeError")
        guard let observer = failSubscription(id, error: error, cancelRemote: true),
            let notify = observer.onError
        else { return }
        // A socket may invoke receive inside send; never notify while an outer send-order lock is held.
        DispatchQueue.global().async { notify(error) }
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

    @discardableResult
    private func failSubscription(_ id: UInt64, error: Error, cancelRemote: Bool, pendingOnly: Bool = false)
        -> StreamObserver?
    {
        sendOrder.withLock {
            let state = lock.withLock { () -> (Pending<UInt64>?, LuxoWebSocketTask?, Subscription?) in
                if pendingOnly && pendingSubscriptions[id] == nil { return (nil, nil, nil) }
                let subscription = subscriptions.removeValue(forKey: id)
                return (pendingSubscriptions.removeValue(forKey: id), task, subscription)
            }
            state.0?.fail(error)
            guard cancelRemote, let socket = state.1, let subscription = state.2 else { return state.2?.observer }
            let message: URLSessionWebSocketTask.Message =
                subscription.mode == .binary
                ? .data(LuxoBinaryProtocol.unsubscribeFrame(sequence: id))
                : .string("{\"$unsub\":\(id)}")
            socket.send(message) { _ in }
            return subscription.observer
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
                let waiting = removePendingLocked(notify: false)
                return (socket, waiting)
            }
            state.0?.cancel(with: .normalClosure, reason: nil)
            finishPending(
                state.1, error: LuxoError(code: 0, message: "WebSocket closed by client", name: "ConnectionError"))
        }
    }

    // Caller holds sendOrder; no request from a previous connection is replayed.
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
        let installed = lock.withLock { () -> Bool in
            guard shouldReconnect, task == nil else { return false }
            task = socket
            connectionIdentity = identity
            return true
        }
        guard installed else { socket.cancel(with: .goingAway, reason: nil); return }
        socket.resume()
        receiveLoop(socket, identity: identity)
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
        guard let envelope = try? JSONEnvelope.decode(data) else {
            let failure = LuxoError(code: 0, message: "invalid WebSocket JSON message", name: "ParseError")
            retireConnection(socket, error: failure, subscriptionError: failure)
            return
        }
        let json = envelope.fields
        if envelope.hasTerminalMetadata {
            if let terminal = LuxoWebSocketProtocol.jsonTerminal(envelope) {
                finishSubscription(terminal.id, error: terminal.error, mode: .json, socket: socket)
            }
        } else if json["$sub"] != nil {
            if let fields = try? envelope.materializedFields(),
                let acknowledgement = LuxoWebSocketProtocol.decodeJSONSubscriptionAcknowledgement(values: fields)
            {
                acknowledgeSubscription(acknowledgement, mode: .json, socket: socket)
            }
        } else if json["$stream"] != nil {
            guard let id = LuxoWebSocketProtocol.jsonRequestID(value: json["$stream"]),
                let handler = streamHandler(id, mode: .json, socket: socket)
            else { return }
            handler(TransportPayload(data: envelope.responseData, mode: .json))
        } else {
            handleJSONCall(envelope, socket: socket)
        }
    }

    private func handleJSONCall(_ envelope: JSONEnvelope, socket: LuxoWebSocketTask) {
        let json = envelope.fields
        guard let id = LuxoWebSocketProtocol.jsonRequestID(value: json["$id"]),
            let state = takePending(id, socket: socket)
        else { return }
        state.timeoutTask.cancel()
        if json["error"] != nil {
            state.continuation.resume(throwing: JSONEnvelope.decodeError(envelope, statusCode: 0))
        } else {
            state.continuation.resume(returning: TransportPayload(data: envelope.responseData, mode: .json))
        }
    }

    private func handleBinaryMessage(_ data: Data, socket: LuxoWebSocketTask) {
        guard let frame = LuxoWebSocketProtocol.decodeBinaryFrame(data) else { return }
        if let acknowledgement = LuxoWebSocketProtocol.subscriptionAcknowledgement(frame) {
            acknowledgeSubscription(acknowledgement, mode: .binary, socket: socket)
            return
        }
        switch frame.type {
        case LuxoBinaryProtocol.callSuccess:
            if let state = takePending(frame.id, socket: socket) {
                state.timeoutTask.cancel()
                state.continuation.resume(returning: TransportPayload(data: frame.payload, mode: .binary))
            }
        case LuxoBinaryProtocol.callError:
            takePending(frame.id, socket: socket)?.fail(LuxoBinaryProtocol.decodeError(frame.payload, statusCode: 0))
        case LuxoBinaryProtocol.stream:
            streamHandler(frame.id, mode: .binary, socket: socket)?(
                TransportPayload(data: frame.payload, mode: .binary))
        case LuxoBinaryProtocol.streamComplete:
            let error =
                frame.payload.isEmpty
                ? nil
                : LuxoError(code: 0, message: "completion frame has trailing payload", name: "ParseError")
            finishSubscription(frame.id, error: error, mode: .binary, socket: socket)
        case LuxoBinaryProtocol.streamError:
            finishSubscription(
                frame.id, error: LuxoBinaryProtocol.decodeError(frame.payload, statusCode: 0),
                mode: .binary, socket: socket)
        default: break
        }
    }

    private func streamHandler(_ id: UInt64, mode: TransportMode, socket: LuxoWebSocketTask) -> (
        @Sendable (TransportPayload) -> Void
    )? {
        lock.withLock {
            guard task === socket, let subscription = subscriptions[id], subscription.mode == mode,
                subscription.acknowledged
            else { return nil }
            return subscription.handler
        }
    }

    private func acknowledgeSubscription(
        _ acknowledgement: LuxoWebSocketProtocol.SubscriptionAcknowledgement, mode: TransportMode,
        socket: LuxoWebSocketTask
    ) {
        if let error = acknowledgement.error {
            finishSubscription(acknowledgement.id, error: error, mode: mode, socket: socket, terminal: false)
            return
        }
        let state = lock.withLock { () -> Pending<UInt64>? in
            guard task === socket, subscriptions[acknowledgement.id]?.mode == mode else { return nil }
            subscriptions[acknowledgement.id]?.acknowledged = true
            return pendingSubscriptions.removeValue(forKey: acknowledgement.id)
        }
        guard let state else { return }
        state.timeoutTask.cancel()
        state.continuation.resume(returning: acknowledgement.id)
    }

    private func finishSubscription(
        _ id: UInt64, error: LuxoError?, mode: TransportMode, socket: LuxoWebSocketTask, terminal: Bool = true
    ) {
        let state = lock.withLock { () -> (Subscription, Pending<UInt64>?)? in
            guard task === socket, let subscription = subscriptions[id], subscription.mode == mode else { return nil }
            subscriptions.removeValue(forKey: id)
            return (subscription, pendingSubscriptions.removeValue(forKey: id))
        }
        guard let (subscription, waiting) = state else { return }
        let failure =
            terminal && !subscription.acknowledged
            ? LuxoError(code: 0, message: "stream ended before subscription acknowledgement", name: "ParseError")
            : error
        if let waiting {
            // Pending setup is unacknowledged, so a terminal always supplies ParseError;
            // a failed acknowledgement supplies its decoded error instead.
            if let failure { waiting.fail(failure) }
            return
        }
        // State is removed and the state lock released before invoking user callbacks.
        if let failure { subscription.observer?.onError?(failure) } else { subscription.observer?.onComplete?() }
    }

    private func takePending(_ id: UInt64, socket: LuxoWebSocketTask) -> Pending<TransportPayload>? {
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

    private func removePendingLocked(notify: Bool = true) -> RetiredConnection {
        let observers: [StreamObserver] =
            notify
            ? subscriptions.values.compactMap { subscription in
                guard subscription.acknowledged, let observer = subscription.observer, observer.onError != nil else {
                    return nil
                }
                return observer
            } : []
        let state = RetiredConnection(
            calls: Array(pending.values), subscriptions: Array(pendingSubscriptions.values), observers: observers)
        subscriptions.removeAll()
        pending.removeAll()
        pendingSubscriptions.removeAll()
        return state
    }

    private func finishPending(_ state: RetiredConnection, error: Error, subscriptionError: Error? = nil) {
        state.calls.forEach { $0.fail(error) }
        state.subscriptions.forEach { $0.fail(subscriptionError ?? error) }
    }

    private func notifyDisconnected(_ observers: [StreamObserver], error: LuxoError) {
        guard !observers.isEmpty else { return }
        // A socket may fail inline while its caller still owns the recursive send lock.
        // Queue only disconnect notifications, never per-message data delivery.
        DispatchQueue.global().async {
            for observer in observers { observer.onError?(error) }
        }
    }

    private static func networkError(_ error: Error) -> LuxoError {
        LuxoError(code: 0, message: error.localizedDescription, name: "NetworkError")
    }

    private func connectionLost(_ socket: LuxoWebSocketTask, error: Error) {
        let message = "WebSocket connection lost: \(error.localizedDescription)"
        retireConnection(
            socket,
            error: LuxoError(code: 0, message: message, name: "ConnectionError"),
            subscriptionError: LuxoError(code: 0, message: message, name: "NetworkError"))
    }

    private func retireConnection(_ socket: LuxoWebSocketTask, error: LuxoError, subscriptionError: LuxoError) {
        sendOrder.withLock {
            let waiting = lock.withLock { () -> RetiredConnection? in
                guard task === socket else { return nil }
                task = nil
                return removePendingLocked()
            }
            guard let waiting else { return }
            socket.cancel(with: .goingAway, reason: nil)
            finishPending(waiting, error: error, subscriptionError: subscriptionError)
            scheduleReconnect()
            notifyDisconnected(waiting.observers, error: subscriptionError)
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
