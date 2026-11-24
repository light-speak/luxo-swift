import Foundation

final class BenchmarkSession: LuxoWebSocketSession {
    let socket: BenchmarkSocket
    init(_ socket: BenchmarkSocket) { self.socket = socket }
    func makeWebSocketTask(with request: URLRequest) -> LuxoWebSocketTask { socket }
}

final class BenchmarkSocket: LuxoWebSocketTask, @unchecked Sendable {
    var closeCode: URLSessionWebSocketTask.CloseCode { .invalid }
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
