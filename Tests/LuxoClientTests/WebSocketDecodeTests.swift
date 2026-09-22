import Foundation
import XCTest
@testable import LuxoClient

final class WebSocketDecodeTests: XCTestCase {
    func testRejectedSchemaPreservesLiveConnection() async throws {
        for mode in [TransportMode.json, .binary] {
            let (transport, socket) = try fixture(mode)
            defer { transport.close() }
            XCTAssertThrowsError(try transport.setSchema(["watch": APISchema(id: 0)]))
            let result = try await transport.call("watch")
            XCTAssertEqual(try Self.integer(result), 7)
            let values = DecodeValues()
            let cancel = try await transport.subscribe("watch", decoder: Self.integer) { values.append($0) }
            socket.deliver(.success(data(mode, 2)))
            XCTAssertEqual(values.rows, [7])
            XCTAssertNil(socket.cancelCode)
            cancel()
        }
    }

    func testBadPayloadRetiresOnlyItsSubscription() async throws {
        for mode in [TransportMode.json, .binary] {
            let (transport, socket) = try fixture(mode)
            defer { transport.close() }
            let values = DecodeValues()
            let failed = expectation(description: "one decode error")
            let stop = try await transport.subscribe(
                "watch", decoder: Self.integer,
                observer: StreamObserver(
                    onComplete: { XCTFail("decoding failure is not completion") },
                    onError: { error in
                        values.fail(error); failed.fulfill()
                    }
                )
            ) { values.append($0) }
            let peer = DecodeValues()
            let stopPeer = try await transport.subscribe("watch", decoder: Self.integer) { peer.append($0) }
            socket.deliver(.success(data(mode, 1)))
            for _ in 0..<2 { socket.deliver(.success(data(mode, 1, bad: true))) }
            socket.deliver(.success(data(mode, 1)))
            socket.deliver(.success(completion(mode, 1)))
            stop(); stop()
            socket.deliver(.success(data(mode, 2)))
            await fulfillment(of: [failed], timeout: 1)
            XCTAssertEqual(values.rows, [7])
            XCTAssertEqual(values.errors.map(\.name), ["DecodeError"])
            XCTAssertEqual(peer.rows, [7])
            let result = try await transport.call("watch")
            XCTAssertEqual(try Self.integer(result), 7)
            XCTAssertNil(socket.cancelCode)
            stopPeer()
        }
    }

    func testNoObserverStillRemovesAndCancels() async throws {
        for mode in [TransportMode.json, .binary] {
            let (transport, socket) = try fixture(mode)
            defer { transport.close() }
            let stop = try await transport.subscribe("watch", decoder: Self.integer) { _ in XCTFail("bad data") }
            let sent = socket.sentMessages.count
            for _ in 0..<2 { socket.deliver(.success(data(mode, 1, bad: true))) }
            stop()
            XCTAssertEqual(socket.sentMessages.count, sent + 1)
            XCTAssertNil(socket.cancelCode)
        }
    }

    func testFailedRemoteCancellationStillNotifiesOnce() async throws {
        for mode in [TransportMode.json, .binary] {
            let (transport, socket) = try fixture(mode)
            defer { transport.close() }
            let failed = expectation(description: "local failure survives a failed cancel write")
            let stop = try await transport.subscribe(
                "watch", decoder: Self.integer,
                observer: StreamObserver(onError: {
                    XCTAssertEqual($0.name, "DecodeError"); failed.fulfill()
                })
            ) { _ in XCTFail("bad data") }
            socket.sendError = URLError(.cannotWriteToFile)
            for _ in 0..<2 { socket.deliver(.success(data(mode, 1, bad: true))) }
            stop()
            await fulfillment(of: [failed], timeout: 1)
            socket.sendError = nil
            XCTAssertNil(socket.cancelCode)
            let result = try await transport.call("watch")
            XCTAssertEqual(try Self.integer(result), 7)
        }
    }

    func testDecoderReentrantCloseDoesNotSendSecondNotification() async throws {
        for mode in [TransportMode.json, .binary] {
            let (transport, socket) = try fixture(mode)
            let stop = try await transport.subscribe(
                "watch",
                decoder: { _ -> Int in
                    transport.close()
                    throw LuxoError(code: 0, message: "retired", name: "Example")
                }, observer: StreamObserver(onError: { _ in XCTFail("already closed") })
            ) { _ in XCTFail("bad data") }
            socket.deliver(.success(data(mode, 1, bad: true)))
            stop()
            XCTAssertEqual(socket.cancelCode, .normalClosure)
        }
    }

    func testDecoderDiagnosticAndObserverReentryOutsideSendOrder() async throws {
        for mode in [TransportMode.json, .binary] {
            let (transport, socket) = try fixture(mode)
            defer { transport.close() }
            let acknowledged = socket.onSend
            let bad = data(mode, 1, bad: true)
            socket.onSend = { [weak socket] message in
                acknowledged?(message)
                if Self.isSubscription(message) { socket?.deliver(.success(bad)) }
            }
            let failed = expectation(description: "observer can wait for close on another thread")
            let stop = try await transport.subscribe(
                "watch",
                decoder: { _ -> Int in
                    throw LuxoError(code: 0, message: "invalid integer", name: "RangeError")
                },
                observer: StreamObserver(onError: {
                    XCTAssertEqual($0.name, "DecodeError")
                    XCTAssertEqual($0.message, "invalid integer")
                    let closed = DispatchSemaphore(value: 0)
                    DispatchQueue.global().async {
                        transport.close(); closed.signal()
                    }
                    XCTAssertEqual(closed.wait(timeout: .now() + 1), .success)
                    failed.fulfill()
                })
            ) { _ in XCTFail("bad data") }
            await fulfillment(of: [failed], timeout: 1)
            stop()
        }
    }

    func testDecoderFailureOnMaximumIDAndModeSwitch() async throws {
        for mode in [TransportMode.json, .binary] {
            let (transport, socket) = try fixture(mode, start: .max - 1)
            defer { transport.close() }
            let failed = expectation(description: "maximum ID fails in its original mode")
            let stop = try await transport.subscribe(
                "watch", decoder: Self.integer,
                observer: StreamObserver(onError: {
                    XCTAssertEqual($0.name, "DecodeError"); failed.fulfill()
                })
            ) { _ in XCTFail("bad data") }
            let other: TransportMode = mode == .json ? .binary : .json
            transport.setMode(other)
            socket.deliver(.success(data(other, .max, bad: true)))
            socket.deliver(.success(data(mode, .max, bad: true)))
            await fulfillment(of: [failed], timeout: 1)
            let sent = socket.sentMessages.count
            stop()
            XCTAssertEqual(sent, socket.sentMessages.count)
            if mode == .json {
                guard case .string(let text) = socket.sentMessages.last else { return XCTFail("wrong cancel mode") }
                XCTAssertEqual(text, #"{"$unsub":18446744073709551615}"#)
            } else {
                XCTAssertEqual(socket.dataMessage(at: sent - 1), Self.frame(0x11, .max))
            }
        }
    }

    private static func integer(_ payload: TransportPayload) throws -> Int {
        if payload.mode == .binary {
            var decoder = Decoder(payload.data)
            let value = Int(decoder.readSvarint())
            guard decoder.error == nil, decoder.isAtEnd else {
                throw LuxoError(code: 0, message: decoder.error ?? "trailing data", name: "DecodeError")
            }
            return value
        }
        return try LuxoJSONDecoder().decode(Int.self, from: payload.data)
    }

    private func fixture(_ mode: TransportMode, start: UInt64 = 0) throws -> (WebSocketTransport, MockWebSocketTask) {
        let socket = MockWebSocketTask()
        let transport = try WebSocketTransport(
            url: "ws://localhost/test", timeout: 1,
            session: MockWebSocketSession(socket: socket), initialSequence: start)
        transport.setMode(mode)
        try transport.setSchema(["watch": APISchema(id: 77)])
        transport.connect()
        socket.onSend = { [weak socket] message in
            switch message {
            case .string(let text):
                guard case .object(let json) = try? LuxoValue.decodeJSONData(Data(text.utf8)),
                    let id = LuxoWebSocketProtocol.jsonRequestID(value: json["$id"])
                else { return }
                socket?.deliver(
                    .success(
                        .string(
                            json["$sub"] != nil
                                ? "{\"$sub\":\(id),\"ok\":true}" : "{\"$id\":\(id),\"data\":7}")))
            case .data(let bytes):
                var decoder = Decoder(bytes)
                let kind = decoder.readVarint()
                let id = decoder.readVarint()
                if kind == 0x10 {
                    socket?.deliver(.success(.data(Self.frame(0x13, id))))
                } else if kind == 1 {
                    socket?.deliver(.success(.data(Self.frame(2, id, Data([14])))))
                }
            @unknown default: break
            }
        }
        return (transport, socket)
    }

    private static func isSubscription(_ message: URLSessionWebSocketTask.Message) -> Bool {
        switch message {
        case .string(let text): text.contains("\"$sub\"")
        case .data(let bytes): bytes.first == 0x10
        @unknown default: false
        }
    }

    private func data(_ mode: TransportMode, _ id: UInt64, bad: Bool = false) -> URLSessionWebSocketTask.Message {
        mode == .json
            ? .string("{\"$stream\":\(id),\"data\":\(bad ? "true" : "7")}")
            : .data(Self.frame(0x12, id, Data([bad ? 0x80 : 14])))
    }

    private func completion(_ mode: TransportMode, _ id: UInt64) -> URLSessionWebSocketTask.Message {
        mode == .json ? .string("{\"$end\":\(id),\"ok\":true}") : .data(Self.frame(0x15, id))
    }

    private static func frame(_ kind: UInt64, _ id: UInt64, _ data: Data = Data()) -> Data {
        var encoder = Encoder()
        encoder.writeVarint(kind); encoder.writeVarint(id); encoder.writeRawBytes(data)
        return encoder.data
    }
}

private final class DecodeValues: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRows: [Int] = []
    private var storedErrors: [LuxoError] = []
    var rows: [Int] { lock.withLock { storedRows } }
    var errors: [LuxoError] { lock.withLock { storedErrors } }
    func append(_ value: Int) { lock.withLock { storedRows.append(value) } }
    func fail(_ error: LuxoError) { lock.withLock { storedErrors.append(error) } }
}
