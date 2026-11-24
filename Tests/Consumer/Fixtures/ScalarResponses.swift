import Foundation
import LuxoClient

func verifyScalarResponses() async throws {
    try await verifyResponseModeOwnership()
    try verifyDecoderErrorNames()
    try await verifyScalar(
        Int.max, wire: Data([0xfe] + Array(repeating: 0xff, count: 8) + [1]),
        read: { try await $0.readInt() }, readList: { try await $0.readIntList() },
        watch: { try await $0.subscribeWatchInt(handler: $1) },
        watchList: { try await $0.subscribeWatchIntList(handler: $1) })
    try await verifyScalar(
        Int64.min, wire: Data(Array(repeating: 0xff, count: 9) + [1]),
        read: { try await $0.readDuration() }, readList: { try await $0.readDurationList() },
        watch: { try await $0.subscribeWatchDuration(handler: $1) },
        watchList: { try await $0.subscribeWatchDurationList(handler: $1) })
    try await verifyScalar(
        1.25, wire: Data([0, 0, 0, 0, 0, 0, 0xf4, 0x3f]),
        read: { try await $0.readFloat() }, readList: { try await $0.readFloatList() },
        watch: { try await $0.subscribeWatchFloat(handler: $1) },
        watchList: { try await $0.subscribeWatchFloatList(handler: $1) })
    try await verifyScalar(
        "精度 café", wire: scalarText("精度 café"),
        read: { try await $0.readString() }, readList: { try await $0.readStringList() },
        watch: { try await $0.subscribeWatchString(handler: $1) },
        watchList: { try await $0.subscribeWatchStringList(handler: $1) })
    try await verifyScalar(
        true, wire: Data([1]),
        read: { try await $0.readBoolean() }, readList: { try await $0.readBooleanList() },
        watch: { try await $0.subscribeWatchBoolean(handler: $1) },
        watchList: { try await $0.subscribeWatchBooleanList(handler: $1) })
    try await verifyScalar(
        "1970-01-01T00:00:00Z", wire: Data([0, 0]),
        read: { try await $0.readDateTime() }, readList: { try await $0.readDateTimeList() },
        watch: { try await $0.subscribeWatchDateTime(handler: $1) },
        watchList: { try await $0.subscribeWatchDateTimeList(handler: $1) })
    try await verifyDateTimeBoundaries()
    try await verifyScalar(
        UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!,
        wire: Data(stride(from: 0, through: 255, by: 17).map(UInt8.init)),
        read: { try await $0.readUUID() }, readList: { try await $0.readUUIDList() },
        watch: { try await $0.subscribeWatchUUID(handler: $1) },
        watchList: { try await $0.subscribeWatchUUIDList(handler: $1) })
    try await verifyScalar(
        "12345678901234567890.125", wire: scalarText("12345678901234567890.125"),
        read: { try await $0.readDecimal() }, readList: { try await $0.readDecimalList() },
        watch: { try await $0.subscribeWatchDecimal(handler: $1) },
        watchList: { try await $0.subscribeWatchDecimalList(handler: $1) })
    try await verifyScalar(
        Data([0, 255]), wire: Data([2, 0, 255]),
        read: { try await $0.readBytes() }, readList: { try await $0.readBytesList() },
        watch: { try await $0.subscribeWatchBytes(handler: $1) },
        watchList: { try await $0.subscribeWatchBytesList(handler: $1) })
    try await verifyScalar(
        JSONValue.object([:]), wire: scalarText("{}"),
        read: { try await $0.readJSON() }, readList: { try await $0.readJSONList() },
        watch: { try await $0.subscribeWatchJSON(handler: $1) },
        watchList: { try await $0.subscribeWatchJSONList(handler: $1) })
    try await verifyScalar(
        Status.open, wire: scalarText("OPEN"),
        read: { try await $0.readStatus() }, readList: { try await $0.readStatusList() },
        watch: { try await $0.subscribeWatchStatus(handler: $1) },
        watchList: { try await $0.subscribeWatchStatusList(handler: $1) })
    try await verifyRejectedResponse(
        Data([2]), read: { try await $0.readBoolean() },
        watch: { try await $0.subscribeWatchBoolean(handler: $1) })
    for raw in ["FUTURE", "", "open", "K", "é", "e\u{301}"] {
        try await verifyScalar(
            Status.unknown(raw), wire: scalarText(raw),
            read: { try await $0.readStatus() }, readList: { try await $0.readStatusList() },
            watch: { try await $0.subscribeWatchStatus(handler: $1) },
            watchList: { try await $0.subscribeWatchStatusList(handler: $1) })
    }
    for binary in [false, true] {
        try await verifyRejectedResponse(
            binary ? Data([1, 0xff]) : Data("42".utf8), binary: binary,
            read: { try await $0.readStatus() }, watch: { try await $0.subscribeWatchStatus(handler: $1) })
    }
    for json in ["null", "true", "{}", "[42]", "[null]"] {
        try await verifyRejectedResponse(
            Data(json.utf8), binary: false, read: { try await $0.readStatusList() },
            watch: { try await $0.subscribeWatchStatusList(handler: $1) })
    }
    try await verifyRejectedResponse(
        Data([1, 0xff]), read: { try await $0.readString() },
        watch: { try await $0.subscribeWatchString(handler: $1) })
    try await verifyBinaryJSONValueBoundaries()
    print("44 generated scalar/list call/stream methods passed JSON/Binary and malformed-response checks")
}

private func verifyBinaryJSONValueBoundaries() async throws {
    try await verifyJSONContainerDepth()
    for text in ["{", "\u{feff}null", "\u{feff}42", "\u{feff}{}", "\u{feff}[]"] {
        try await verifyRejectedResponse(
            scalarText(text), read: { try await $0.readJSON() },
            watch: { try await $0.subscribeWatchJSON(handler: $1) })
        try await verifyRejectedResponse(
            Data([1]) + scalarText(text), read: { try await $0.readJSONList() },
            watch: { try await $0.subscribeWatchJSONList(handler: $1) })
    }
    try await verifyScalar(
        JSONValue.string("\u{feff}text"), wire: scalarText("\"\u{feff}text\""),
        read: { try await $0.readJSON() }, readList: { try await $0.readJSONList() },
        watch: { try await $0.subscribeWatchJSON(handler: $1) },
        watchList: { try await $0.subscribeWatchJSONList(handler: $1) })
}

private func verifyJSONContainerDepth() async throws {
    for depth in 127...129 {
        for empty in [false, true] {
            let count = depth - (empty ? 1 : 0)
            let raw =
                String(repeating: "[", count: count) + (empty ? "[]" : "0")
                + String(repeating: "]", count: count)
            var encoder = Encoder()
            encoder.writeString(raw)
            if depth > 128 {
                try await verifyRejectedResponse(
                    encoder.data, read: { try await $0.readJSON() },
                    watch: { try await $0.subscribeWatchJSON(handler: $1) })
                try await verifyRejectedResponse(
                    Data([1]) + encoder.data, read: { try await $0.readJSONList() },
                    watch: { try await $0.subscribeWatchJSONList(handler: $1) })
                try await verifyRejectedResponse(
                    Data(raw.utf8), binary: false, read: { try await $0.readJSON() },
                    watch: { try await $0.subscribeWatchJSON(handler: $1) })
            } else {
                let expected = try JSONValue.parseBinary(Data(raw.utf8))
                try await verifyReply(
                    expected, wire: encoder.data, read: { try await $0.readJSON() },
                    watch: { try await $0.subscribeWatchJSON(handler: $1) })
                let client = try scalarClient(Data([1]) + encoder.data, binary: true)
                guard try await client.readJSONList() == [expected] else {
                    throw scalarFailure("JSON list depth changed")
                }
                let received = ScalarReceiver<[JSONValue]>()
                let cancel = try await client.subscribeWatchJSONList { received.append($0) }
                cancel()
                guard received.values == [[expected]] else { throw scalarFailure("JSON list stream depth changed") }
            }
        }
    }
}

private func verifyDecoderErrorNames() throws {
    for name in ["ParseError", "DecodingError", "DecodeError"] {
        do {
            let _: Int = try decodeLuxoResponse(Data()) { _ in
                throw LuxoError(code: 0, message: "invalid nested payload", name: name)
            }
            throw scalarFailure("decoding error became success")
        } catch let error as LuxoError where error.name == "DecodeError" {
            guard error.message == "invalid nested payload", error.code == 0 else {
                throw scalarFailure("decoding diagnostic changed")
            }
        }
    }
}

private func scalarText(_ value: String) -> Data {
    let bytes = Data(value.utf8)
    precondition(bytes.count < 128)
    return Data([UInt8(bytes.count)]) + bytes
}

private func verifyDateTimeBoundaries() async throws {
    var encoder = Encoder()
    try encoder.writeDateTime("1969-12-31T23:59:59.123456789Z")
    try await verifyScalar(
        "1969-12-31T23:59:59.123456789Z", wire: encoder.data,
        read: { try await $0.readDateTime() }, readList: { try await $0.readDateTimeList() },
        watch: { try await $0.subscribeWatchDateTime(handler: $1) },
        watchList: { try await $0.subscribeWatchDateTimeList(handler: $1) })
    for text in [
        "2000-01-01T00:00:00.1234567890Z", "2001-02-29T00:00:00Z",
        "0000-01-01T00:00:00+00:01", "9999-12-31T23:59:59-00:01",
        "2000-01-01T00:00:00",
    ] {
        try await verifyRejectedResponse(
            JSONEncoder().encode(text), binary: false,
            read: { try await $0.readDateTime() },
            watch: { try await $0.subscribeWatchDateTime(handler: $1) })
        try await verifyRejectedResponse(
            JSONEncoder().encode([text]), binary: false,
            read: { try await $0.readDateTimeList() },
            watch: { try await $0.subscribeWatchDateTimeList(handler: $1) })
    }
}

func verifyResponseModeOwnership() async throws {
    let configured = try LuxoGeneratedClient(transport: ScalarTransport(payload: Data([4]), mode: .binary))
    guard try await configured.readInt() == 2 else { throw scalarFailure("preconfigured response mode was ignored") }
    for binary in [false, true] {
        let transport = ModeSwitchTransport()
        let client = try LuxoGeneratedClient(transport: transport)
        if binary { client.enableBinary() }
        let result = Task { try await client.readInt() }
        var starts = transport.starts.makeAsyncIterator()
        guard await starts.next() != nil else { throw scalarFailure("call did not start") }
        if binary { transport.setMode(.json) } else { client.enableBinary() }
        transport.finishCall()
        guard try await result.value == 2 else { throw scalarFailure("in-flight call used the new mode") }

        transport.setMode(binary ? .binary : .json)
        let received = ScalarReceiver<Int>()
        let cancel = try await client.subscribeWatchInt { received.append($0) }
        if binary { transport.setMode(.json) } else { client.enableBinary() }
        transport.deliver()
        cancel()
        guard received.values == [2] else { throw scalarFailure("existing subscription used the new mode") }
    }
    print("Generated client keeps the decoding mode of in-flight calls and subscriptions")
}

private final class ModeSwitchTransport: ConsumerTransport, @unchecked Sendable {
    let starts: AsyncStream<Void>
    private let started: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private var mode: TransportMode = .json
    private var waiting: (CheckedContinuation<TransportPayload, Error>, TransportPayload)?
    private var subscription: ((@Sendable (TransportPayload) -> Void), TransportPayload)?

    init() { (starts, started) = AsyncStream.makeStream(of: Void.self) }

    func call(_ api: String, params: [String: LuxoValue]?) async throws -> TransportPayload {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            waiting = (continuation, payloadLocked())
            lock.unlock()
            started.yield(())
        }
    }

    func finishCall() {
        lock.lock()
        let state = waiting
        waiting = nil
        lock.unlock()
        if let state { state.0.resume(returning: state.1) }
    }

    func subscribe<Value: Sendable>(
        _ api: String, decoder: @escaping @Sendable (TransportPayload) throws -> Value,
        params: [String: LuxoValue]?, observer: StreamObserver?,
        handler: @escaping @Sendable (Value) -> Void
    ) async throws -> (@Sendable () -> Void) {
        install { deliverConsumerPayload($0, decoder: decoder, observer: observer, handler: handler) }
        return { [weak self] in self?.install(nil) }
    }
    private func install(_ handler: (@Sendable (TransportPayload) -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        subscription = handler.map { ($0, payloadLocked()) }
    }
    func deliver() {
        lock.lock()
        let handler = subscription
        lock.unlock()
        if let handler { handler.0(handler.1) }
    }
    private func payloadLocked() -> TransportPayload {
        TransportPayload(data: mode == .json ? Data("2".utf8) : Data([4]), mode: mode)
    }
    func setMode(_ mode: TransportMode) {
        lock.lock(); defer { lock.unlock() }
        self.mode = mode
    }
    func setToken(_ token: String) {}
    func setSchema(_ schema: [String: APISchema]) {}
}

typealias ScalarCall<Value> = (LuxoGeneratedClient) async throws -> Value
typealias ScalarWatch<Value> =
    (LuxoGeneratedClient, @escaping @Sendable (Value) -> Void) async throws -> (@Sendable () -> Void)

private func verifyScalar<Value: Codable & Equatable & Sendable>(
    _ expected: Value, wire: Data,
    read: ScalarCall<Value>, readList: ScalarCall<[Value]>,
    watch: ScalarWatch<Value>, watchList: ScalarWatch<[Value]>
) async throws {
    try await verifyReply(expected, wire: wire, read: read, watch: watch)
    try await verifyReply(
        [expected, expected], wire: Data([2]) + wire + wire, read: readList, watch: watchList)
    try await verifyReply([Value](), wire: Data([0]), read: readList, watch: watchList)
}

private func verifyReply<Value: Codable & Equatable & Sendable>(
    _ expected: Value, wire: Data, read: ScalarCall<Value>, watch: ScalarWatch<Value>
) async throws {
    for binary in [false, true] {
        let payload = binary ? wire : try JSONEncoder().encode(expected)
        let client = try scalarClient(payload, binary: binary)
        guard try await read(client) == expected else { throw scalarFailure("valid reply changed value") }
        let received = ScalarReceiver<Value>()
        let cancel = try await watch(client) { received.append($0) }
        cancel()
        guard received.values == [expected] else { throw scalarFailure("stream changed value") }
    }
    for count in 0..<wire.count {
        try await verifyRejectedResponse(Data(wire.prefix(count)), read: read, watch: watch)
    }
    try await verifyRejectedResponse(wire + Data([0]), read: read, watch: watch)
}

func verifyRejectedResponse<Value: Sendable>(
    _ payload: Data, binary: Bool = true, read: ScalarCall<Value>, watch: ScalarWatch<Value>
) async throws {
    let client = try scalarClient(payload, binary: binary)
    do {
        _ = try await read(client)
        throw scalarFailure("malformed reply became a successful value")
    } catch let error as LuxoError where error.name == "DecodeError" {}
    let received = ScalarReceiver<Value>()
    let cancel = try await watch(client) { received.append($0) }
    cancel()
    guard received.values.isEmpty else { throw scalarFailure("malformed stream invoked success handler") }
}

private func scalarClient(_ payload: Data, binary: Bool) throws -> LuxoGeneratedClient {
    let client = try LuxoGeneratedClient(transport: ScalarTransport(payload: payload, mode: binary ? .binary : .json))
    if binary { client.enableBinary() }
    return client
}

private func scalarFailure(_ message: String) -> LuxoError {
    LuxoError(code: 0, message: message, name: "ConsumerError")
}

private struct ScalarTransport: ConsumerTransport {
    let payload: Data
    let mode: TransportMode

    func call(_ api: String, params: [String: LuxoValue]?) async throws -> TransportPayload {
        TransportPayload(data: payload, mode: mode)
    }
    func subscribe<Value: Sendable>(
        _ api: String, decoder: @escaping @Sendable (TransportPayload) throws -> Value,
        params: [String: LuxoValue]?, observer: StreamObserver?,
        handler: @escaping @Sendable (Value) -> Void
    ) async throws -> (@Sendable () -> Void) {
        deliverConsumerPayload(
            TransportPayload(data: payload, mode: mode), decoder: decoder, observer: observer, handler: handler)
        return {}
    }
    func setToken(_ token: String) {}
    func setMode(_ mode: TransportMode) {}
    func setSchema(_ schema: [String: APISchema]) {}
}

// These response fixtures deliver once; lifecycle isolation is tested against the actual WebSocket transport.
func deliverConsumerPayload<Value>(
    _ payload: TransportPayload, decoder: (TransportPayload) throws -> Value,
    observer: StreamObserver?, handler: (Value) -> Void
) {
    let value: Value
    do { value = try decoder(payload) } catch {
        observer?.onError?(
            LuxoError(code: 0, message: (error as? LuxoError)?.message ?? "invalid payload", name: "DecodeError"))
        return
    }
    handler(value)
}

// The callback can run on a transport thread; protect all captured mutable state.
final class ScalarReceiver<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []
    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
    func append(_ value: Value) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(value)
    }
}
