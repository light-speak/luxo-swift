import Foundation
import XCTest
@testable import LuxoClient

struct BinaryPresenceRequest: GeneratedRequest {
    let apiID: Int
    func writeParameters(to encoder: inout Encoder) throws {}
    func toJSONParameters() throws -> [String: LuxoValue] {
        throw LuxoError(code: 0, message: "Binary request used JSON parameters", name: "ConfigError")
    }
}

final class WebSocketDecodeTests: XCTestCase {
    private struct NativeDepthRequest: GeneratedRequest {
        let apiID = 1
        let models: Int64
        let json: Int64
        let dataFirst: Bool
        func writeParameters(to encoder: inout Encoder) throws {
            throw LuxoError(code: 0, message: "JSON-only peer request", name: "ConfigError")
        }
        func toJSONParameters() throws -> [String: LuxoValue] {
            ["models": .int(models), "json": .int(json), "dataFirst": .bool(dataFirst)]
        }
    }

    private struct NativePeerStats: Decodable {
        let connection: Int
        let calls: Int
        let active: Int
        let subscriptions: Int
        let unsubscriptions: Int
    }

    private func liveNativeTransport() throws -> WebSocketTransport {
        guard let endpoint = ProcessInfo.processInfo.environment["LUXO_WS_CODABLE_URL"] else {
            throw XCTSkip("requires owned core WS Codable peer")
        }
        let transport = try WebSocketTransport(url: endpoint, timeout: 5)
        transport.connect()
        return transport
    }

    private func nativePeerStats(_ transport: WebSocketTransport) async throws -> NativePeerStats {
        let payload = try await transport.call("stats")
        return try LuxoJSONDecoder().decode(NativePeerStats.self, from: payload.data)
    }

    private static func nativeModelDepth(_ payload: TransportPayload) throws -> Int {
        var node = try LuxoJSONDecoder().decode(PlainNode.self, from: payload.data)
        var count = 1
        while let child = node.child { node = child; count += 1 }
        var expected = JSONValue.integer(0)
        for _ in 0..<128 { expected = .array([expected]) }
        guard payload.mode == .json, node.metadata == expected else {
            throw LuxoError(code: 0, message: "lost native JSON leaf", name: "TestError")
        }
        return count
    }

    func testLiveGoPeerCallsKeepNativeDepthBudgetsAndRecover() async throws {
        let transport = try liveNativeTransport()
        defer { transport.close() }
        let before = try await nativePeerStats(transport)
        for generated in [false, true] {
            for dataFirst in [false, true] {
                for (models, json, valid) in [(64, 128, true), (65, 128, false), (64, 129, false), (64, 128, true)] {
                    let request = NativeDepthRequest(models: Int64(models), json: Int64(json), dataFirst: dataFirst)
                    let payload: TransportPayload
                    if generated {
                        payload = try await transport.call("depth", request: request)
                    } else {
                        payload = try await transport.call("depth", params: request.toJSONParameters())
                    }
                    if valid {
                        XCTAssertEqual(try Self.nativeModelDepth(payload), 64)
                    } else {
                        XCTAssertThrowsError(try Self.nativeModelDepth(payload)) { error in
                            XCTAssertEqual((error as? LuxoError)?.name, models == 65 ? "DecodingError" : "ParseError")
                        }
                    }
                }
            }
        }
        let after = try await nativePeerStats(transport)
        XCTAssertEqual(after.connection, before.connection)
        XCTAssertEqual(after.calls, before.calls + 17)
        XCTAssertEqual(after.active, 0)
    }

    func testLiveGoPeerStreamDepthFailureOnlyRetiresItsSubscription() async throws {
        for (models, json) in [(65, 128), (64, 129)] {
            for dataFirst in [false, true] {
                try await verifyLiveNativeStreamFailure(models: models, json: json, dataFirst: dataFirst)
            }
        }
    }

    private func emitNative(
        _ transport: WebSocketTransport, target: String, models: Int = 64, json: Int = 128, dataFirst: Bool
    ) async throws {
        var params = try NativeDepthRequest(models: Int64(models), json: Int64(json), dataFirst: dataFirst)
            .toJSONParameters()
        params["target"] = .string(target)
        _ = try await transport.call("emit", params: params)
    }

    private func verifyLiveNativeStreamFailure(models: Int, json: Int, dataFirst: Bool) async throws {
        let transport = try liveNativeTransport()
        defer { transport.close() }
        let before = try await nativePeerStats(transport)
        let values = DecodeValues(), peer = DecodeValues()
        let first = expectation(description: "native model64 JSON128 stream value")
        let failed = expectation(description: "one typed depth error")
        let continued = expectation(description: "peer subscription continues")
        first.assertForOverFulfill = true; failed.assertForOverFulfill = true; continued.assertForOverFulfill = true
        let stop = try await transport.subscribe(
            "watch", decoder: Self.nativeModelDepth,
            observer: StreamObserver(onError: {
                values.fail($0); failed.fulfill()
            })
        ) {
            values.append($0); first.fulfill()
        }
        defer { stop() }
        let stopPeer = try await transport.subscribe("peer", decoder: Self.integer) {
            peer.append($0); continued.fulfill()
        }
        defer { stopPeer() }
        try await emitNative(transport, target: "watch", dataFirst: dataFirst)
        await fulfillment(of: [first], timeout: 5)
        try await emitNative(transport, target: "watch", models: models, json: json, dataFirst: dataFirst)
        try await emitNative(transport, target: "peer", dataFirst: dataFirst)
        await fulfillment(of: [failed, continued], timeout: 5)
        XCTAssertEqual(values.rows, [64]); XCTAssertEqual(values.errors.map(\.name), ["DecodeError"])
        XCTAssertEqual(peer.rows, [7]); XCTAssertTrue(peer.errors.isEmpty)
        let after = try await nativePeerStats(transport)
        XCTAssertEqual(after.connection, before.connection)
        XCTAssertEqual(after.active, 1); XCTAssertEqual(after.subscriptions, 2);
        XCTAssertEqual(after.unsubscriptions, 1)
        stop(); stopPeer()
        let ended = try await nativePeerStats(transport)
        XCTAssertEqual(ended.connection, before.connection)
        XCTAssertEqual(ended.active, 0); XCTAssertEqual(ended.unsubscriptions, 2)
    }

    private final class PlainNode: Decodable, Sendable {
        let child: PlainNode?
        let metadata: JSONValue?
    }

    private static func plainPayload(_ layers: Int, json: Int) -> String {
        var text =
            "{\"metadata\":" + String(repeating: "[", count: json) + "0" + String(repeating: "]", count: json) + "}"
        for _ in 1..<layers { text = "{\"child\":\(text)}" }
        return text
    }

    func testNoSchemaWSHandsModelBytesToCodableAndIsolatesDepthFailure() async throws {
        for dataFirst in [false, true] {
            let (transport, socket) = try fixture(.json)
            defer { transport.close() }
            let values = DecodeValues(), peer = DecodeValues()
            let failed = expectation(description: "typed depth failure reaches its observer")
            let stop = try await transport.subscribe(
                "watch",
                decoder: { payload in
                    var node = try LuxoJSONDecoder().decode(PlainNode.self, from: payload.data)
                    var count = 1
                    while let child = node.child { node = child; count += 1 }
                    guard node.metadata != nil else {
                        throw LuxoError(code: 0, message: "lost JSON leaf", name: "TestError")
                    }
                    return count
                },
                observer: StreamObserver(onError: {
                    values.fail($0); failed.fulfill()
                })
            ) { values.append($0) }
            let stopPeer = try await transport.subscribe("watch", decoder: Self.integer) { peer.append($0) }
            let good = Self.plainPayload(64, json: 128)
            socket.deliver(
                .success(.string(dataFirst ? "{\"data\":\(good),\"$stream\":1}" : "{\"$stream\":1,\"data\":\(good)}")))
            XCTAssertEqual(values.rows, [64])
            XCTAssertTrue(values.errors.isEmpty)
            let bad = Self.plainPayload(65, json: 0)
            socket.deliver(.success(.string("{\"$stream\":1,\"data\":\(bad)}")))
            socket.deliver(.success(.string("{\"$stream\":2,\"data\":7}")))
            await fulfillment(of: [failed], timeout: 1)
            XCTAssertEqual(values.rows, [64])
            XCTAssertEqual(values.errors.map(\.name), ["DecodeError"])
            XCTAssertEqual(peer.rows, [7])
            XCTAssertNil(socket.cancelCode)
            stop(); stopPeer()
        }
    }

    func testNoSchemaWSCallPreservesOpaqueModelBytes() async throws {
        let (transport, socket) = try fixture(.json)
        defer { transport.close() }
        let text = Self.plainPayload(64, json: 128)
        socket.onSend = { [weak socket] _ in
            socket?.deliver(.success(.string("{\"data\":\(text),\"$id\":1}")))
        }
        let payload = try await transport.call("watch")
        XCTAssertEqual(payload.data, Data(text.utf8))
        XCTAssertNoThrow(try LuxoJSONDecoder().decode(PlainNode.self, from: payload.data))
        XCTAssertNil(socket.cancelCode)
    }

    func testWSCallUsesResponseSchemaRegardlessOfMetadataOrder() async throws {
        let json = String(repeating: "[", count: 128) + "null" + String(repeating: "]", count: 128)
        let payload = "[\(json)]"
        for dataFirst in [false, true] {
            let (transport, socket) = try fixture(.json)
            defer { transport.close() }
            try transport.setSchema(["watch": APISchema(id: 77, response: .list(.json))])
            socket.onSend = { [weak socket] _ in
                do { try transport.setSchema(["watch": APISchema(id: 77, response: .json)]) } catch {
                    XCTFail("schema update failed: \(error)")
                }
                let fields = dataFirst ? "\"data\":\(payload),\"$id\":1" : "\"$id\":1,\"data\":\(payload)"
                socket?.deliver(.success(.string("{\(fields)}")))
            }
            let response = try await transport.call("watch")
            XCTAssertEqual(response.data, Data(payload.utf8))
            socket.deliver(.success(.string("{\"data\":\(payload),\"$id\":1}")))
            XCTAssertNil(socket.cancelCode)
        }
    }

    func testWSStreamRetainsResponseSchemaAcrossSchemaChanges() async throws {
        let json = String(repeating: "[", count: 128) + "null" + String(repeating: "]", count: 128)
        let (transport, socket) = try fixture(.json)
        defer { transport.close() }
        try transport.setSchema(["watch": APISchema(id: 77, response: .list(.json))])
        let values = DecodeValues()
        let stop = try await transport.subscribe(
            "watch",
            decoder: { payload in
                try LuxoJSONDecoder().decode([JSONValue].self, from: payload.data).count
            }, observer: StreamObserver(onError: { values.fail($0) })
        ) { values.append($0) }
        try transport.setSchema(["watch": APISchema(id: 77, response: .json)])
        let peer = DecodeValues()
        let stopPeer = try await transport.subscribe("watch", decoder: Self.integer) { peer.append($0) }
        socket.deliver(.success(.string("{\"$stream\":2,\"data\":[\(json)],\"$stream\":1}")))
        XCTAssertEqual(values.rows, [1])
        XCTAssertTrue(values.errors.isEmpty)
        XCTAssertNil(socket.cancelCode)
        stop()
        socket.deliver(.success(.string("{\"data\":[\(json)],\"$stream\":1}")))
        socket.deliver(.success(.string("{\"$stream\":2,\"data\":7}")))
        XCTAssertEqual(peer.rows, [7])
        XCTAssertNil(socket.cancelCode)
        stopPeer()
    }

    func testMissingBinaryDataRetiresOnlyItsOperation() async throws {
        let (transport, socket) = try fixture(.binary)
        defer { transport.close() }
        let values = DecodeValues(), peer = DecodeValues(), decoded = DecodeValues()
        let failed = expectation(description: "one missing Binary data failure")
        let decoder: @Sendable (TransportPayload) throws -> Int? = { payload in
            decoded.append(1)
            if payload.data == Data([0]) { return nil }
            return try Self.integer(payload)
        }
        let stop = try await transport.subscribe(
            "watch", decoder: decoder,
            observer: StreamObserver(
                onComplete: { XCTFail("missing Binary data is not completion") },
                onError: {
                    values.fail($0); failed.fulfill()
                })
        ) { values.append($0 ?? -1) }
        let stopPeer = try await transport.subscribe("watch", decoder: decoder) { peer.append($0 ?? -1) }
        socket.deliver(.success(.data(Self.frame(0x12, 1, Data([0])))))
        for _ in 0..<2 { socket.deliver(.success(.data(Self.frame(0x12, 1)))) }
        socket.deliver(.success(completion(.binary, 1)))
        socket.deliver(.success(.data(Self.frame(0x12, 2, Data([0])))))
        await fulfillment(of: [failed], timeout: 1)
        XCTAssertEqual(values.rows, [-1])
        XCTAssertEqual(values.errors.map(\.name), ["ParseError"])
        XCTAssertEqual(peer.rows, [-1])
        XCTAssertEqual(decoded.rows, [1, 1])
        let normal = socket.onSend
        socket.onSend = { [weak socket] message in
            guard case .data(let bytes) = message else { return }
            var decoder = Decoder(bytes)
            guard decoder.readVarint() == 1 else { return }
            socket?.deliver(.success(.data(Self.frame(2, decoder.readVarint()))))
        }
        do { _ = try await transport.call("watch"); XCTFail("missing Binary call data accepted") } catch let error
            as LuxoError
        { XCTAssertEqual(error.name, "ParseError") }
        socket.onSend = normal
        let result = try await transport.call("watch", request: BinaryPresenceRequest(apiID: 77))
        XCTAssertEqual(try Self.integer(result), 7)
        XCTAssertNil(socket.cancelCode)
        stop(); stopPeer()
    }

    func testMissingJSONDataRetiresOnlyItsOperation() async throws {
        let (transport, socket) = try fixture(.json)
        defer { transport.close() }
        let values = DecodeValues(), peer = DecodeValues()
        let failed = expectation(description: "one missing data failure")
        let decoder: @Sendable (TransportPayload) throws -> Int? = { payload in
            if payload.data == Data("null".utf8) { return nil }
            return try Self.integer(payload)
        }
        let stop = try await transport.subscribe(
            "watch", decoder: decoder,
            observer: StreamObserver(
                onComplete: { XCTFail("missing data is not completion") },
                onError: {
                    values.fail($0); failed.fulfill()
                })
        ) { values.append($0 ?? -1) }
        let stopPeer = try await transport.subscribe("watch", decoder: decoder) { peer.append($0 ?? -1) }
        socket.deliver(.success(.string(#"{"$stream":1,"data":null}"#)))
        for _ in 0..<2 { socket.deliver(.success(.string(#"{"$stream":1}"#))) }
        socket.deliver(.success(completion(.json, 1)))
        socket.deliver(.success(.string(#"{"$stream":2,"data":null}"#)))
        await fulfillment(of: [failed], timeout: 1)
        XCTAssertEqual(values.rows, [-1])
        XCTAssertEqual(values.errors.map(\.name), ["ParseError"])
        XCTAssertEqual(peer.rows, [-1])
        let normal = socket.onSend
        socket.onSend = { [weak socket] message in
            guard case .string(let text) = message,
                case .object(let fields) = try? LuxoValue.decodeJSONData(Data(text.utf8)),
                let id = LuxoWebSocketProtocol.jsonRequestID(value: fields["$id"])
            else { return }
            socket?.deliver(.success(.string("{\"$id\":\(id)}")))
        }
        do { _ = try await transport.call("watch"); XCTFail("missing call data accepted") } catch let error as LuxoError
        { XCTAssertEqual(error.name, "ParseError") }
        socket.onSend = normal
        let result = try await transport.call("watch")
        XCTAssertEqual(try Self.integer(result), 7)
        XCTAssertNil(socket.cancelCode)
        stop(); stopPeer()
    }

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

    func testModelDepthFailureRetiresOnlyItsSubscription() async throws {
        let model = Self.recursiveModelSchema
        let payload = Self.nestedModelPayload()
        for routeFirst in [true, false] {
            let (transport, socket) = try fixture(.json)
            defer { transport.close() }
            try transport.setSchema(["watch": APISchema(id: 77, response: model)])
            let failed = expectation(description: "only the model subscription fails")
            let values = DecodeValues(), peer = DecodeValues()
            let stop = try await transport.subscribe(
                "watch",
                decoder: { response in
                    _ = try JSONReader.decode(response.data, schema: model)
                    return 1
                },
                observer: StreamObserver(onError: {
                    values.fail($0); failed.fulfill()
                })
            ) { values.append($0) }
            try transport.setSchema(["watch": APISchema(id: 77, response: .json)])
            let stopPeer = try await transport.subscribe("watch", decoder: Self.integer) { peer.append($0) }
            let fields = routeFirst ? "\"$stream\":1,\"data\":\(payload)" : "\"data\":\(payload),\"$stream\":1"
            socket.deliver(.success(.string("{\(fields)}")))
            await fulfillment(of: [failed], timeout: 1)
            socket.deliver(.success(.string("{\(fields)}")))
            socket.deliver(.success(.string("{\"$stream\":2,\"data\":7}")))
            XCTAssertEqual(values.errors.map(\.name), ["DecodeError"])
            XCTAssertTrue(values.rows.isEmpty)
            XCTAssertEqual(peer.rows, [7])
            XCTAssertNil(socket.cancelCode)
            stop(); stopPeer()
        }
    }

    func testModelDepthFailureRetiresOnlyItsCall() async throws {
        for routeFirst in [true, false] {
            let (transport, socket) = try fixture(.json)
            defer { transport.close() }
            let peer = DecodeValues()
            let stopPeer = try await transport.subscribe("watch", decoder: Self.integer) { peer.append($0) }
            try transport.setSchema(["watch": APISchema(id: 77, response: Self.recursiveModelSchema)])
            let normal = socket.onSend
            let payload = Self.nestedModelPayload()
            socket.onSend = { [weak socket] _ in
                let fields = routeFirst ? "\"$id\":2,\"data\":\(payload)" : "\"data\":\(payload),\"$id\":2"
                socket?.deliver(.success(.string("{\(fields)}")))
            }
            do {
                _ = try await transport.call("watch")
                XCTFail("model depth violation accepted")
            } catch let error as LuxoError {
                XCTAssertEqual(error.name, "DecodeError")
            }
            socket.onSend = normal
            socket.deliver(.success(.string("{\"$stream\":1,\"data\":7}")))
            XCTAssertEqual(peer.rows, [7])
            XCTAssertNil(socket.cancelCode)
            try transport.setSchema(["watch": APISchema(id: 77, response: .json)])
            let response = try await transport.call("watch")
            XCTAssertEqual(try Self.integer(response), 7)
            stopPeer()
        }
    }

    func testMalformedJSONBelowModelLimitStillRetiresConnection() async throws {
        for routeFirst in [true, false] {
            let (transport, socket) = try fixture(.json)
            defer { transport.close() }
            try transport.setSchema(["watch": APISchema(id: 77, response: Self.recursiveModelSchema)])
            let failed = expectation(description: "malformed source fails both subscriptions")
            failed.expectedFulfillmentCount = 2
            let values = DecodeValues(), peer = DecodeValues()
            let observer = StreamObserver(onError: {
                values.fail($0); failed.fulfill()
            })
            let stop = try await transport.subscribe("watch", decoder: Self.integer, observer: observer) {
                values.append($0)
            }
            let stopPeer = try await transport.subscribe("watch", decoder: Self.integer, observer: observer) {
                peer.append($0)
            }
            let payload = Self.nestedModelPayload(leaf: "{\"bad\":[1,]}")
            let fields = routeFirst ? "\"$stream\":1,\"data\":\(payload)" : "\"data\":\(payload),\"$stream\":1"
            socket.deliver(.success(.string("{\(fields)}")))
            await fulfillment(of: [failed], timeout: 1)
            XCTAssertEqual(values.errors.map(\.name), ["ParseError", "ParseError"])
            XCTAssertTrue(values.rows.isEmpty)
            XCTAssertTrue(peer.rows.isEmpty)
            XCTAssertNotNil(socket.cancelCode)
            stop(); stopPeer()
        }
    }

    func testModelPayloadBeforeAcknowledgementIsDiscarded() async throws {
        let (transport, socket) = try fixture(.json)
        defer { transport.close() }
        try transport.setSchema(["watch": APISchema(id: 77, response: Self.recursiveModelSchema)])
        let normal = socket.onSend
        socket.onSend = { [weak socket] message in
            if Self.isSubscription(message) {
                socket?.deliver(.success(.string("{\"$stream\":1,\"data\":\(Self.nestedModelPayload())}")))
            }
            normal?(message)
        }
        let values = DecodeValues()
        let stop = try await transport.subscribe(
            "watch",
            decoder: { response in
                _ = try JSONReader.decode(response.data, schema: Self.recursiveModelSchema)
                return 1
            }, observer: StreamObserver(onError: { values.fail($0) })
        ) { values.append($0) }
        XCTAssertTrue(values.rows.isEmpty)
        socket.deliver(.success(.string("{\"$stream\":1,\"data\":{}}")))
        XCTAssertEqual(values.rows, [1])
        XCTAssertTrue(values.errors.isEmpty)
        XCTAssertNil(socket.cancelCode)
        stop()
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

    func testDecoderDiagnosticsDoNotDescribeArbitraryErrors() async throws {
        for mode in [TransportMode.json, .binary] {
            let (transport, socket) = try fixture(mode)
            defer { transport.close() }
            let descriptions = DecodeValues(), errors = DecodeValues(), peer = DecodeValues()
            let failed = expectation(description: "one error without custom diagnostic access")
            let stop = try await transport.subscribe(
                "watch", decoder: { _ -> Int in throw DescribedDecodeFailure(reads: descriptions) },
                observer: StreamObserver(onError: {
                    XCTAssertEqual($0.name, "DecodeError")
                    XCTAssertEqual($0.message, "invalid subscription payload")
                    errors.fail($0); failed.fulfill()
                })
            ) { _ in XCTFail("bad data") }
            let stopPeer = try await transport.subscribe("watch", decoder: Self.integer) { peer.append($0) }
            for _ in 0..<2 { socket.deliver(.success(data(mode, 1, bad: true))) }
            socket.deliver(.success(completion(mode, 1)))
            socket.deliver(.success(data(mode, 2)))
            await fulfillment(of: [failed], timeout: 1)
            XCTAssertEqual(errors.errors.count, 1)
            XCTAssertEqual(descriptions.rows, [])
            XCTAssertEqual(peer.rows, [7])
            stop(); stopPeer()
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

    private static let recursiveModelSchema = LuxoJSONReadSchema.model(
        "Node", types: ["Node": ["child": .init(fieldID: 1, typeName: "Node", type: "Model")]])

    private static func nestedModelPayload(leaf: String = "{}") -> String {
        String(repeating: "{\"child\":", count: 64) + leaf + String(repeating: "}", count: 64)
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

private struct DescribedDecodeFailure: LocalizedError, CustomStringConvertible {
    let reads: DecodeValues
    var errorDescription: String? { reads.append(1); return "custom decoder diagnostic" }
    var description: String { reads.append(2); return "custom decoder diagnostic" }
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
