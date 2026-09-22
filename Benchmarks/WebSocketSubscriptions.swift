import Foundation

enum WebSocketSubscriptionBenchmark {
    static func runTerminals() async throws {
        for mode in [TransportMode.json, .binary] {
            for id in [UInt64(1), .max] {
                for observed in [false, true] {
                    let observer = observed ? StreamObserver(onComplete: {}, onError: { _ in }) : nil
                    let before = try await Fixture(
                        mode: mode, id: id, legacy: false, preTerminal: true, observer: observer)
                    let after = try await Fixture(mode: mode, id: id, legacy: false, observer: observer)
                    defer { before.transport.close(); after.transport.close() }
                    TransportMetadataBenchmark.compare(
                        "Terminal-aware dispatch \(mode) id=\(id) observer=\(observed)", iterations: 50_000,
                        warmup: 10_000,
                        before: { _ in before.deliver() }, after: { _ in after.deliver() })
                    precondition(before.socket.receivedCount == 880_000 && after.socket.receivedCount == 880_000)
                }
            }
        }
        for id in [UInt64(1), .max] {
            let frame = Data("{\"$id\":\(id),\"data\":7}".utf8)
            try TransportMetadataBenchmark.compare(
                "Terminal-aware JSON unary envelope id=\(id)", iterations: 50_000, warmup: 10_000,
                before: { _ in UInt64(try PreTerminalJSONEnvelope.decode(frame).responseData.count) },
                after: { _ in UInt64(try JSONEnvelope.decode(frame).responseData.count) })
        }
    }

    static func run() async throws {
        for mode in [TransportMode.json, .binary] {
            for id in [UInt64(1), 129, .max] {
                let before = try await Fixture(mode: mode, id: id, legacy: true)
                let after = try await Fixture(mode: mode, id: id, legacy: false)
                defer { before.transport.close(); after.transport.close() }
                TransportMetadataBenchmark.compare(
                    "Subscription dispatch \(mode) id=\(id)", iterations: 50_000, warmup: 10_000,
                    before: { _ in before.deliver() }, after: { _ in after.deliver() })
                precondition(before.socket.receivedCount == 880_000)
                precondition(after.socket.receivedCount == 880_000)
            }
        }
    }

    private struct Fixture {
        let transport: any BenchmarkTransport
        let socket: BenchmarkSocket
        let frame: URLSessionWebSocketTask.Message

        init(mode: TransportMode, id: UInt64, legacy: Bool, preTerminal: Bool = false, observer: StreamObserver? = nil)
            async throws
        {
            let socket = BenchmarkSocket(legacy: legacy)
            self.socket = socket
            let session = BenchmarkSession(socket)
            let schema = ["watch": APISchema(id: 7)]
            if preTerminal {
                let transport = try PreTerminalWebSocketTransport(
                    url: "ws://localhost/bench", session: session, initialSequence: id - 1)
                transport.setMode(mode)
                transport.setSchema(schema)
                transport.connect()
                self.transport = transport
            } else if legacy {
                let transport = try LegacyWebSocketTransport(url: "ws://localhost/bench", session: session)
                transport.setMode(mode)
                transport.setSchema(schema)
                transport.connect()
                self.transport = transport
            } else {
                let transport = try WebSocketTransport(
                    url: "ws://localhost/bench", session: session, initialSequence: id - 1)
                transport.setMode(mode)
                try transport.setSchema(schema)
                transport.connect()
                self.transport = PayloadBenchmarkTransport(base: transport)
            }
            _ = try await transport.subscribe("watch", observer: observer) { data in
                precondition(data == Data([mode == .json ? 55 : 7]))
                socket.record()
            }
            if mode == .json {
                frame = .string("{\"$stream\":\(legacy ? "\"watch\"" : String(id)),\"data\":7}")
            } else {
                var encoder = Encoder()
                encoder.writeVarint(legacy ? 6 : 0x12)
                encoder.writeVarint(legacy ? 7 : id)
                encoder.writeRawBytes(Data([7]))
                frame = .data(encoder.data)
            }
        }

        func deliver() -> UInt64 {
            socket.deliver(frame)
            return 1
        }
    }
}

// Keep frozen baselines on their original Data-only contract.
protocol BenchmarkTransport: Sendable {
    func connect()
    func close()
    func setMode(_ mode: TransportMode)
    func setSchema(_ schema: [String: APISchema]) throws
    func call(_ api: String, params: [String: LuxoValue]?) async throws -> Data
    func subscribe(
        _ api: String, params: [String: LuxoValue]?, observer: StreamObserver?,
        handler: @escaping @Sendable (Data) -> Void
    ) async throws -> (@Sendable () -> Void)
}

extension BenchmarkTransport {
    func subscribe(
        _ api: String, observer: StreamObserver? = nil, handler: @escaping @Sendable (Data) -> Void
    ) async throws -> (@Sendable () -> Void) {
        try await subscribe(api, params: nil, observer: observer, handler: handler)
    }
}

// Historical benchmarks now include this extraction adapter. New mode-specific
// measurements must use the native payload API directly, without this adapter.
struct PayloadBenchmarkTransport: BenchmarkTransport {
    let base: WebSocketTransport
    func connect() { base.connect() }
    func close() { base.close() }
    func setMode(_ mode: TransportMode) { base.setMode(mode) }
    func setSchema(_ schema: [String: APISchema]) throws { try base.setSchema(schema) }
    func call(_ api: String, params: [String: LuxoValue]?) async throws -> Data {
        try await base.call(api, params: params).data
    }
    func subscribe(
        _ api: String, params: [String: LuxoValue]?, observer: StreamObserver?,
        handler: @escaping @Sendable (Data) -> Void
    ) async throws -> (@Sendable () -> Void) {
        try await base.subscribe(api, decoder: { $0.data }, params: params, observer: observer, handler: handler)
    }
}

final class BenchmarkSession: LuxoWebSocketSession {
    let socket: BenchmarkSocket
    init(_ socket: BenchmarkSocket) { self.socket = socket }
    func makeWebSocketTask(with request: URLRequest) -> LuxoWebSocketTask { socket }
}

final class BenchmarkSocket: LuxoWebSocketTask, @unchecked Sendable {
    private let lock = NSLock()
    private var receiver: (@Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void)?
    private var count = 0
    private let legacy: Bool
    var receivedCount: Int { lock.withLock { count } }
    init(legacy: Bool) { self.legacy = legacy }
    func record() { lock.withLock { count += 1 } }
    func resume() {}
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {}
    func receive(completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
        lock.withLock { receiver = completionHandler }
    }
    func deliver(_ message: URLSessionWebSocketTask.Message) {
        deliverResult(.success(message))
    }
    func disconnect() {
        deliverResult(.failure(LuxoError(code: 0, message: "benchmark disconnect", name: "NetworkError")))
    }
    private func deliverResult(_ result: Result<URLSessionWebSocketTask.Message, Error>) {
        let handler = lock.withLock { () -> (@Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void)? in
            let current = receiver
            receiver = nil
            return current
        }
        precondition(handler != nil)
        handler?(result)
    }

    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping @Sendable (Error?) -> Void) {
        switch message {
        case .string(let text):
            guard case .object(let values) = try? LuxoValue.decodeJSONData(Data(text.utf8)) else {
                return completionHandler(nil)
            }
            let id = LuxoWebSocketProtocol.jsonRequestID(value: values["$id"]) ?? 0
            if values["$sub"] != nil {
                deliver(.string("{\"$sub\":\(legacy ? "\"watch\"" : String(id)),\"ok\":true}"))
            } else if values["$api"] != nil {
                deliver(.string("{\"$id\":\(id),\"data\":7}"))
            }
        case .data(let data):
            var decoder = Decoder(data)
            let type = decoder.readVarint()
            let subscription = type == (legacy ? 4 : 0x10)
            guard subscription || type == LuxoBinaryProtocol.callRequest else { return completionHandler(nil) }
            let id = decoder.readVarint()
            var encoder = Encoder()
            encoder.writeVarint(subscription ? (legacy ? 7 : 0x13) : LuxoBinaryProtocol.callSuccess)
            encoder.writeVarint(id)
            if !subscription { encoder.writeRawBytes(Data([7])) }
            deliver(.data(encoder.data))
        @unknown default: preconditionFailure("unknown fixture frame")
        }
        completionHandler(nil)
    }
}
