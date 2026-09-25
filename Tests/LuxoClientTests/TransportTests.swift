import XCTest
@testable import LuxoClient

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

final class TransportTests: XCTestCase {
    func testHTTPSuccessRequiresDataButAllowsExplicitNull() async throws {
        for body in ["{}", #"{"ok":true}"#, #"{"value":42}"#] {
            let transport = try makeURLSessionTransport { request in
                try self.mockResponse(request, status: 200, data: Data(body.utf8))
            }
            transport.onTokenExpired = {
                XCTFail("missing data triggered refresh"); return nil
            }
            do {
                _ = try await transport.call("echo")
                XCTFail("missing data was accepted")
            } catch let error as LuxoError {
                XCTAssertEqual(error.name, "ParseError")
                XCTAssertEqual(error.code, 200)
            }
        }
        for value in ["null", "false", "0", "\"\"", "[]", "{}"] {
            let transport = try makeURLSessionTransport { request in
                try self.mockResponse(request, status: 200, data: Data("{\"data\":\(value)}".utf8))
            }
            let payload = try await transport.call("echo")
            XCTAssertEqual(payload.data, Data(value.utf8))
        }
    }

    func testHTTPCacheOverloadPreservesIdentityWithoutRetryOrRefresh() async throws {
        for mode in [TransportMode.json, .binary] {
            let lock = NSLock()
            var calls = 0
            let transport = try makeURLSessionTransport { request in
                let attempt = lock.withLock {
                    calls += 1; return calls
                }
                if attempt == 1 {
                    return try self.mockResponse(request, status: 503, data: self.cacheOriginError(mode))
                }
                return try self.mockResponse(
                    request, status: 200, data: mode == .json ? Data(#"{"data":42}"#.utf8) : Data([84]))
            }
            transport.setMode(mode)
            try transport.setSchema(["echo": APISchema(id: 1)])
            transport.onTokenExpired = {
                XCTFail("cache overload must not refresh authentication")
                return "must-not-refresh"
            }
            do {
                _ = try await transport.call("echo")
                XCTFail("expected cache overload")
            } catch let error as LuxoError {
                XCTAssertEqual(error.name, "CacheOriginBusy")
                XCTAssertEqual(error.code, 503)
                XCTAssertEqual(error.message, "Cache origin capacity exhausted")
            }
            XCTAssertEqual(lock.withLock { calls }, 1)
            let next = try await transport.call("echo")
            XCTAssertEqual(next.mode, mode)
            XCTAssertEqual(next.data, mode == .json ? Data("42".utf8) : Data([84]))
            XCTAssertEqual(lock.withLock { calls }, 2)
        }
    }

    private func cacheOriginError(_ mode: TransportMode) -> Data {
        if mode == .json {
            return Data(#"{"error":"CacheOriginBusy","code":503,"message":"Cache origin capacity exhausted"}"#.utf8)
        }
        var encoder = Encoder()
        encoder.writeVarint(1)
        encoder.writeSvarint(503)
        encoder.writeVarint(2)
        encoder.writeString("CacheOriginBusy")
        encoder.writeVarint(3)
        encoder.writeString("Cache origin capacity exhausted")
        encoder.writeEnd()
        return encoder.data
    }

    func testRejectedHTTPSchemaPreservesEncodingAndValidation() async throws {
        for mode in [TransportMode.json, .binary] {
            let original = APISchema(id: 7, params: [.init(fieldID: 1, name: "value", type: "Int")])
            let transport = try makeURLSessionTransport { request in
                let body = try self.requestBody(request)
                if mode == .binary {
                    XCTAssertEqual(
                        body, try LuxoBinaryProtocol.encodeRequest(schema: original, params: ["value": .int(7)]))
                } else {
                    XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("\"value\":7"))
                }
                return try self.mockResponse(
                    request, status: 200, data: mode == .binary ? Data([14]) : Data("{\"data\":7}".utf8))
            }
            try transport.setSchema(["echo": original])
            transport.setMode(mode)
            XCTAssertThrowsError(
                try transport.setSchema([
                    "echo": APISchema(
                        id: 9, params: [.init(fieldID: 0, name: "value", type: "String")])
                ]))
            let result = try await transport.call("echo", params: ["value": .int(7)])
            XCTAssertEqual(result.mode, mode)
            do {
                _ = try await transport.call("echo", params: ["value": .string("invalid")])
                XCTFail("old Int validation was replaced")
            } catch is LuxoError {}
        }
    }

    func testPayloadRetainsOriginalByteStorage() {
        let bytes = Data(repeating: 0x61, count: 4096)
        let payload = TransportPayload(data: bytes, mode: .json)
        XCTAssertEqual(payload.mode, .json)
        bytes.withUnsafeBytes { original in
            payload.data.withUnsafeBytes { retained in
                XCTAssertEqual(original.baseAddress, retained.baseAddress)
                XCTAssertEqual(original.count, retained.count)
            }
        }
    }

    func testHTTPResponseRetainsItsModeAfterConfigurationChanges() async throws {
        for original in [TransportMode.json, .binary] {
            let sent = expectation(description: "request sent")
            let release = DispatchSemaphore(value: 0)
            let transport = try makeURLSessionTransport { request in
                sent.fulfill()
                guard release.wait(timeout: .now() + 2) == .success else {
                    throw LuxoError(code: 0, message: "test request not released", name: "TestFailure")
                }
                let data = original == .json ? Data(#"{"data":2}"#.utf8) : Data([4])
                return try self.mockResponse(request, status: 200, data: data)
            }
            try transport.setSchema(["echo": APISchema(id: 1)])
            transport.setMode(original)
            let pending = Task { try await transport.call("echo") }
            await fulfillment(of: [sent], timeout: 1)
            transport.setMode(original == .json ? .binary : .json)
            release.signal()
            let result = try await pending.value
            XCTAssertEqual(result.mode, original)
            XCTAssertEqual(result.data, original == .json ? Data("2".utf8) : Data([4]))
        }
    }

    func testHTTPRefreshReturnsTheRetriedRequestsMode() async throws {
        let transport = try makeURLSessionTransport { request in
            if request.value(forHTTPHeaderField: "Content-Type") == "application/json" {
                return try self.mockResponse(
                    request, status: 401, body: ["error": "Unauthorized", "code": 401, "message": "expired"])
            }
            return try self.mockResponse(request, status: 200, data: Data([4]))
        }
        try transport.setSchema(["echo": APISchema(id: 1)])
        transport.onTokenExpired = { [weak transport] in
            transport?.setMode(.binary)
            return "fresh"
        }
        let result = try await transport.call("echo")
        XCTAssertEqual(result.mode, .binary)
        XCTAssertEqual(result.data, Data([4]))
    }

    func testWebSocketConcurrentCallsCarryTheirActualFrameMode() async throws {
        let socket = MockWebSocketTask()
        let transport = try WebSocketTransport(
            url: "wss://example.com/socket", session: MockWebSocketSession(socket: socket))
        try transport.setSchema(["echo": APISchema(id: 7)])
        transport.connect()
        defer { transport.close() }
        let jsonSent = expectation(description: "JSON sent")
        socket.onSend = { _ in jsonSent.fulfill() }
        let json = Task { try await transport.call("echo") }
        await fulfillment(of: [jsonSent], timeout: 1)
        transport.setMode(.binary)
        let binarySent = expectation(description: "Binary sent")
        socket.onSend = { _ in binarySent.fulfill() }
        let binary = Task { try await transport.call("echo") }
        await fulfillment(of: [binarySent], timeout: 1)
        transport.setMode(.json)
        socket.deliver(.success(.data(Data([2, 2, 4]))))
        socket.deliver(.success(.string(#"{"$id":1,"data":2}"#)))
        let jsonResult = try await json.value
        let binaryResult = try await binary.value
        XCTAssertEqual(jsonResult.mode, .json)
        XCTAssertEqual(jsonResult.data, Data("2".utf8))
        XCTAssertEqual(binaryResult.mode, .binary)
        XCTAssertEqual(binaryResult.data, Data([4]))
    }

    func testHTTPRejectsCorruptionOutsideThePayload() async throws {
        for body in [#"{"data":1,"extra":[1,]}"#, #"{"data":1}garbage"#, #"{"data":1,"extra":"\ud800"}"#] {
            let transport = try makeURLSessionTransport { request in
                try self.mockResponse(request, status: 200, data: Data(body.utf8))
            }
            do {
                _ = try await transport.call("echo")
                XCTFail("corrupt envelope was delivered")
            } catch let error as LuxoError {
                XCTAssertEqual(error.name, "ParseError")
                XCTAssertEqual(error.code, 200)
            }
        }
    }

    func testWebSocketErrorsPreserveDataInEitherFieldOrder() async throws {
        let payload = #"{"number":123456789012345678901234567890,"zero":-0}"#
        let metadata = #""code":422,"error":"Rejected","message":"bad""#
        for subscription in [false, true] {
            for dataFirst in [false, true] {
                let socket = MockWebSocketTask()
                let transport = try WebSocketTransport(
                    url: "wss://example.com/socket", session: MockWebSocketSession(socket: socket))
                transport.connect()
                defer { transport.close() }
                socket.onSend = { [weak socket] _ in
                    let correlation = subscription ? "$sub" : "$id"
                    let data = "\"data\":\(payload)"
                    let fields = dataFirst ? "\(data),\(metadata)" : "\(metadata),\(data)"
                    socket?.deliver(.success(.string("{\"\(correlation)\":1,\(fields)}")))
                }
                do {
                    if subscription {
                        _ = try await transport.subscribe("watch", decoder: { $0 }) { _ in }
                    } else {
                        _ = try await transport.call("echo")
                    }
                    XCTFail("error response was delivered as success")
                } catch let error as LuxoError {
                    XCTAssertEqual(error.name, "Rejected")
                    XCTAssertEqual(error.code, 422)
                    let fields = try XCTUnwrap(error.data as? [String: Any])
                    XCTAssertEqual((fields["number"] as? JSONNumber)?.literal, "123456789012345678901234567890")
                    XCTAssertEqual((fields["zero"] as? JSONNumber)?.literal, "-0")
                }
            }
        }
    }

    func testHTTPReturnsUnmodifiedJSONPayloadBytes() async throws {
        let payload = #"{ "z":1E+003, "z":9007199254740993, "a":"\u6771\u4eac", "zero":-0 }"#
        let transport = try makeURLSessionTransport { request in
            try self.mockResponse(request, status: 200, data: Data("{\"extra\":[1,2],\"data\": \(payload) }".utf8))
        }
        let result = try await transport.call("echo")
        XCTAssertEqual(result.data, Data(payload.utf8))
        XCTAssertEqual(try LuxoValue.decodeJSONData(result.data), try LuxoValue.decodeJSONData(Data(payload.utf8)))
    }

    func testWebSocketReturnsUnmodifiedJSONCallAndStreamPayloadBytes() async throws {
        let payload = #"{ "z":1E+003, "a":"\u6771\u4eac", "n":0.12345678901234567890, "zero":-0 }"#
        let socket = MockWebSocketTask()
        let transport = try WebSocketTransport(
            url: "wss://example.com/socket", session: MockWebSocketSession(socket: socket))
        transport.connect()
        defer { transport.close() }
        socket.onSend = { [weak socket] _ in
            socket?.deliver(.success(.string("{\"$id\":1,\"data\":\(payload)}")))
        }
        let result = try await transport.call("echo")
        XCTAssertEqual(result.data, Data(payload.utf8))
        socket.onSend = { [weak socket] _ in
            socket?.deliver(.success(.string(#"{"$sub":2,"ok":true}"#)))
        }
        let received = expectation(description: "untouched JSON stream")
        let cancel = try await transport.subscribe("watch", decoder: { $0 }) { data in
            XCTAssertEqual(data.data, Data(payload.utf8))
            received.fulfill()
        }
        socket.onSend = nil
        socket.deliver(.success(.string("{\"$stream\":2,\"data\":\(payload)}")))
        await fulfillment(of: [received], timeout: 1)
        cancel()
    }

    func testHTTPPreservesRawNumbersInResponsesAndErrors() async throws {
        let payload = #"{"large":123456789012345678901234567890,"small":1e-400,"zero":-0}"#
        for failure in [false, true] {
            let transport = try makeURLSessionTransport { request in
                let body = String(decoding: try self.requestBody(request), as: UTF8.self)
                XCTAssertTrue(body.contains(payload))
                let envelope =
                    failure
                    ? "{\"code\":400,\"error\":\"RemoteError\",\"message\":\"failed\",\"data\":\(payload)}"
                    : "{\"data\":\(payload)}"
                return try self.mockResponse(request, status: failure ? 400 : 200, data: Data(envelope.utf8))
            }
            do {
                let result = try await transport.call(
                    "echo", params: ["value": try LuxoValue.decodeJSONData(Data(payload.utf8))])
                XCTAssertFalse(failure)
                XCTAssertEqual(result.data, Data(payload.utf8))
            } catch let error as LuxoError {
                XCTAssertTrue(failure)
                XCTAssertEqual(error.name, "RemoteError")
                let fields = try XCTUnwrap(error.data as? [String: Any])
                XCTAssertEqual((fields["small"] as? JSONNumber)?.literal, "1e-400")
                XCTAssertEqual((fields["zero"] as? JSONNumber)?.literal, "-0")
            }
        }
    }

    func testWebSocketPreservesRawNumbersInCallAndStreamData() async throws {
        let payload = #"{"number":1E+03,"small":1e-400}"#
        let socket = MockWebSocketTask()
        let transport = try WebSocketTransport(
            url: "wss://example.com/socket", session: MockWebSocketSession(socket: socket))
        transport.connect()
        defer { transport.close() }
        socket.onSend = { [weak socket] _ in
            socket?.deliver(.success(.string("{\"$id\":1,\"data\":\(payload)}")))
        }
        let result = try await transport.call("echo")
        XCTAssertEqual(result.data, Data(payload.utf8))
        socket.onSend = { [weak socket] _ in
            socket?.deliver(.success(.string(#"{"$sub":2,"ok":true}"#)))
        }
        let received = expectation(description: "raw stream data")
        let cancel = try await transport.subscribe("watch", decoder: { $0 }) { data in
            XCTAssertEqual(data.data, Data(payload.utf8))
            received.fulfill()
        }
        socket.deliver(.success(.string("{\"$stream\":2,\"data\":\(payload)}")))
        await fulfillment(of: [received], timeout: 1)
        cancel()
    }
    private struct TestInput: Codable, Sendable, LuxoBinaryEncodable {
        let value: String

        func writeLuxo(to encoder: inout Encoder) throws {
            encoder.writeVarint(UInt64(value.utf8.count))
            encoder.writeVarint(1)
            encoder.writeString(value)
            encoder.writeEnd()
        }
    }

    // MARK: - TransportMode

    func testTransportModeRawValues() {
        XCTAssertEqual(TransportMode.json.rawValue, "json")
        XCTAssertEqual(TransportMode.binary.rawValue, "binary")
    }

    // MARK: - APISchema

    func testAPISchemaConstruction() {
        let param = APISchema.ParamSchema(fieldID: 1, name: "id", type: "Int")
        let schema = APISchema(id: 42, params: [param], fields: ["id": .init(fieldID: 1)])
        XCTAssertEqual(schema.id, 42)
        XCTAssertEqual(schema.params?.count, 1)
        XCTAssertEqual(schema.params?[0].fieldID, 1)
        XCTAssertEqual(schema.params?[0].name, "id")
        XCTAssertEqual(schema.params?[0].type, "Int")
        XCTAssertEqual(schema.fields["id"]?.fieldID, 1)
    }

    func testBinaryRequestIncludesFieldMaskAndTypedParams() throws {
        let schema = APISchema(
            id: 7,
            params: [.init(fieldID: 1, name: "id", type: "Int")],
            fields: ["id": .init(fieldID: 1), "name": .init(fieldID: 2)]
        )

        let body = try LuxoBinaryProtocol.encodeRequest(
            schema: schema,
            params: ["id": 3, "$select": "name"]
        )

        XCTAssertEqual(body, Data([7, 2, 1, 2, 1, 6, 0]))
    }

    func testBinaryRequestEncodesNestedSelectionsRecursively() throws {
        let schema = APISchema(
            id: 1,
            fields: [
                "id": .init(fieldID: 1),
                "posts": .init(fieldID: 3, typeName: "Post"),
            ],
            types: [
                "Post": [
                    "id": .init(fieldID: 1),
                    "title": .init(fieldID: 2),
                ]
            ]
        )
        let body = try LuxoBinaryProtocol.encodeRequest(
            schema: schema,
            params: ["$select": "id,posts{title}"]
        )
        XCTAssertEqual(body, Data([1, 6, 1, 5, 3, 2, 1, 2, 0]))
    }

    func testBinaryRequestRequiresSelectionForStructuredResponsesOnly() throws {
        let structured = APISchema(id: 1, fields: ["id": .init(fieldID: 1)])
        XCTAssertThrowsError(try LuxoBinaryProtocol.encodeRequest(schema: structured, params: [:]))
        XCTAssertThrowsError(
            try LuxoBinaryProtocol.encodeRequest(
                schema: structured,
                params: ["$select": .string("   ")]
            )
        )
        XCTAssertEqual(
            try LuxoBinaryProtocol.encodeRequest(schema: APISchema(id: 2), params: [:]),
            Data([2, 0, 0])
        )
    }

    func testBinaryRequestSupportsBytesAndJSON() throws {
        let schema = APISchema(
            id: 1,
            params: [
                .init(fieldID: 1, name: "blob", type: "Bytes"),
                .init(fieldID: 2, name: "metadata", type: "JSON"),
            ])

        let body = try LuxoBinaryProtocol.encodeRequest(
            schema: schema,
            params: ["blob": .bytes(Data([0, 0xff])), "metadata": ["ok": true]]
        )

        XCTAssertEqual(
            body,
            Data([
                1, 0,
                1, 2, 0, 0xff,
                2, 11, 123, 34, 111, 107, 34, 58, 116, 114, 117, 101, 125,
                0,
            ]))
    }

    func testBinaryRequestEncodesFiltersAndSorters() throws {
        let schema = APISchema(id: 5)
        let body = try LuxoBinaryProtocol.encodeRequest(
            schema: schema,
            params: [
                "$filters": .array([
                    LuxoFilter(field: "age", op: "gte", value: .int(18)).transportValue
                ]),
                "$sorters": .array([
                    LuxoSorter(field: "createdAt", order: "desc").transportValue
                ]),
            ]
        )

        XCTAssertEqual(
            body,
            Data([
                5, 0,
                0xfe, 0xff, 0xff, 0xff, 0x07, 1, 3, 97, 103, 101, 4, 2, 49, 56,
                0xff, 0xff, 0xff, 0xff, 0x07, 1, 9, 99, 114, 101, 97, 116, 101, 100, 65, 116, 1,
                0,
            ]))
    }

    func testBinaryRequestRejectsInvalidListControls() {
        XCTAssertThrowsError(
            try LuxoBinaryProtocol.encodeRequest(
                schema: APISchema(id: 1),
                params: [
                    "$filters": .array([
                        LuxoFilter(field: "age", op: "invalid", value: .int(18)).transportValue
                    ])
                ]
            ))
        XCTAssertThrowsError(
            try LuxoBinaryProtocol.encodeRequest(
                schema: APISchema(id: 1),
                params: [
                    "$sorters": .array([
                        LuxoSorter(field: "age", order: "sideways").transportValue
                    ])
                ]
            ))
        XCTAssertThrowsError(
            try LuxoBinaryProtocol.encodeRequest(
                schema: APISchema(id: 1),
                params: [
                    "$filters": .array([
                        LuxoFilter(field: "score", op: "eq", value: .double(.infinity)).transportValue
                    ])
                ]
            ))
    }

    func testFilterAndSorterJSONObjectsPreserveTypedValues() {
        let values: [LuxoFilterValue] = [.string("value"), .int(7), .double(1.5), .bool(true)]
        XCTAssertEqual(
            values.map { LuxoFilter(field: "field", op: "eq", value: $0).jsonObject["value"] as? String },
            ["value", nil, nil, nil]
        )
        XCTAssertEqual(
            LuxoFilter(field: "field", op: "eq", value: .int(7)).jsonObject["value"] as? Int,
            7
        )
        XCTAssertEqual(
            LuxoFilter(field: "field", op: "eq", value: .double(1.5)).jsonObject["value"] as? Double,
            1.5
        )
        XCTAssertEqual(
            LuxoFilter(field: "field", op: "eq", value: .bool(true)).jsonObject["value"] as? Bool,
            true
        )
        XCTAssertEqual(
            LuxoSorter(field: "createdAt", order: "desc").jsonObject as? [String: String],
            ["field": "createdAt", "order": "desc"]
        )
    }

    func testBinaryRequestEncodesEveryScalarAndListType() throws {
        let uuid = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
        let schema = APISchema(
            id: 4,
            params: [
                .init(fieldID: 1, name: "int", type: "Int"),
                .init(fieldID: 2, name: "duration", type: "Duration"),
                .init(fieldID: 3, name: "float", type: "Float"),
                .init(fieldID: 4, name: "string", type: "String"),
                .init(fieldID: 5, name: "enum", type: "Enum"),
                .init(fieldID: 6, name: "decimal", type: "Decimal"),
                .init(fieldID: 7, name: "bool", type: "Boolean"),
                .init(fieldID: 8, name: "date", type: "DateTime"),
                .init(fieldID: 9, name: "uuid", type: "UUID"),
                .init(fieldID: 10, name: "uuidText", type: "UUID"),
                .init(fieldID: 11, name: "bytes", type: "Bytes"),
                .init(fieldID: 12, name: "json", type: "JSON"),
                .init(fieldID: 13, name: "jsonValue", type: "JSON"),
                .init(fieldID: 14, name: "items", type: "String", isList: true),
            ])
        let body = try LuxoBinaryProtocol.encodeRequest(
            schema: schema,
            params: [
                "int": -3,
                "duration": .int(9),
                "float": 1.25,
                "string": "text",
                "enum": "OPEN",
                "decimal": "12.50",
                "bool": true,
                "date": "1970-01-01T00:01:00Z",
                "uuid": LuxoValue(uuid),
                "uuidText": .string(uuid.uuidString),
                "bytes": .bytes(Data([1, 2])),
                "json": ["ok": true],
                "jsonValue": LuxoValue(.string("value")),
                "items": ["a", "b"],
            ])

        var decoder = Decoder(body)
        XCTAssertEqual(decoder.readVarint(), 4)
        XCTAssertEqual(decoder.readVarint(), 0)
        XCTAssertEqual(decoder.nextField(), 1)
        XCTAssertEqual(decoder.readSvarint(), -3)
        XCTAssertEqual(decoder.nextField(), 2)
        XCTAssertEqual(decoder.readSvarint(), 9)
        XCTAssertEqual(decoder.nextField(), 3)
        XCTAssertEqual(decoder.readFixed64(), 1.25)
        XCTAssertEqual(decoder.nextField(), 4)
        XCTAssertEqual(decoder.readString(), "text")
        XCTAssertEqual(decoder.nextField(), 5)
        XCTAssertEqual(decoder.readString(), "OPEN")
        XCTAssertEqual(decoder.nextField(), 6)
        XCTAssertEqual(decoder.readString(), "12.50")
        XCTAssertEqual(decoder.nextField(), 7)
        XCTAssertTrue(decoder.readBool())
        XCTAssertEqual(decoder.nextField(), 8)
        XCTAssertEqual(decoder.readDateTime(), "1970-01-01T00:01:00Z")
        XCTAssertEqual(decoder.nextField(), 9)
        XCTAssertEqual(decoder.readUUID(), uuid)
        XCTAssertEqual(decoder.nextField(), 10)
        XCTAssertEqual(decoder.readUUID(), uuid)
        XCTAssertEqual(decoder.nextField(), 11)
        XCTAssertEqual(decoder.readBytes(), Data([1, 2]))
        XCTAssertEqual(decoder.nextField(), 12)
        XCTAssertEqual(decoder.readBytes(), Data(#"{"ok":true}"#.utf8))
        XCTAssertEqual(decoder.nextField(), 13)
        XCTAssertEqual(decoder.readBytes(), Data(#""value""#.utf8))
        XCTAssertEqual(decoder.nextField(), 14)
        XCTAssertEqual(decoder.readArray { $0.readString() }, ["a", "b"])
        XCTAssertEqual(decoder.nextField(), 0)
        XCTAssertNil(decoder.error)
    }

    func testBinaryRequestRejectsOutOfRangeSelectionMetadata() {
        for id in [0, -1, 65536, Int.max] {
            let schema = APISchema(id: 1, fields: ["value": .init(fieldID: id)])
            XCTAssertThrowsError(try LuxoBinaryProtocol.encodeRequest(schema: schema, params: ["$select": "value"])) {
                XCTAssertEqual(($0 as? LuxoError)?.name, "ConfigError")
            }
        }
    }

    func testBinaryRequestRejectsInvalidParamsAndSelections() {
        let invalidParams: [(APISchema.ParamSchema, LuxoValue)] = [
            (.init(fieldID: 1, name: "value", type: "Int"), "bad"),
            (.init(fieldID: 1, name: "value", type: "Float"), "bad"),
            (.init(fieldID: 1, name: "value", type: "String"), 1),
            (.init(fieldID: 1, name: "value", type: "Boolean"), 1),
            (.init(fieldID: 1, name: "value", type: "UUID"), "bad"),
            (.init(fieldID: 1, name: "value", type: "Bytes"), "bad"),
            (.init(fieldID: 1, name: "value", type: "DateTime"), "bad"),
            (.init(fieldID: 1, name: "value", type: "Unknown"), "bad"),
            (.init(fieldID: 1, name: "value", type: "String", isList: true), "bad"),
            (.init(fieldID: 1, name: "value", type: "String"), .null),
        ]
        for (param, value) in invalidParams {
            XCTAssertThrowsError(
                try LuxoBinaryProtocol.encodeRequest(
                    schema: APISchema(id: 1, params: [param]),
                    params: ["value": value]
                ))
        }

        let schema = APISchema(
            id: 1,
            fields: ["id": .init(fieldID: 1), "child": .init(fieldID: 2)]
        )
        for selection in ["missing", "id,id", "child{id}", "id{}", "id,"] {
            XCTAssertThrowsError(
                try LuxoBinaryProtocol.encodeRequest(
                    schema: schema,
                    params: ["$select": .string(selection)]
                ))
        }
        let nested = String(repeating: "child{", count: 32) + "id" + String(repeating: "}", count: 32)
        XCTAssertThrowsError(
            try LuxoBinaryProtocol.encodeRequest(
                schema: schema,
                params: ["$select": .string(nested)]
            ))
    }

    func testBinaryRequestAcceptsDictionaryFiltersAndSorters() throws {
        let body = try LuxoBinaryProtocol.encodeRequest(
            schema: APISchema(id: 1),
            params: [
                "$filters": [
                    ["field": "name", "op": "eq", "value": "Ada"],
                    ["field": "active", "op": "eq", "value": true],
                    ["field": "score", "op": "gte", "value": 1.5],
                ],
                "$sorters": [["field": "name", "order": "asc"]],
            ])
        XCTAssertFalse(body.isEmpty)

        XCTAssertThrowsError(
            try LuxoBinaryProtocol.encodeRequest(
                schema: APISchema(id: 1),
                params: [
                    "$filters": .array(
                        Array(
                            repeating: ["field": "x", "op": "eq", "value": 1],
                            count: 1001
                        ))
                ]
            ))
        XCTAssertThrowsError(
            try LuxoBinaryProtocol.encodeRequest(
                schema: APISchema(id: 1),
                params: [
                    "$sorters": .array(
                        Array(repeating: ["field": "x", "order": "asc"], count: 101)
                    )
                ]
            ))
    }

    func testStructuredParamsUseNativeLengthDelimitedMessages() throws {
        let scalar = APISchema(
            id: 1,
            params: [.init(fieldID: 2, name: "input", type: "Model", typeName: "Input")]
        )
        XCTAssertEqual(
            try LuxoBinaryProtocol.encodeRequest(
                schema: scalar,
                params: ["input": .structured(TestInput(value: "x"))]
            ),
            Data([1, 0, 2, 5, 1, 1, 1, 120, 0, 0])
        )

        let list = APISchema(
            id: 1,
            params: [.init(fieldID: 2, name: "inputs", type: "Model", typeName: "Input", isList: true)]
        )
        XCTAssertEqual(
            try LuxoBinaryProtocol.encodeRequest(
                schema: list,
                params: [
                    "inputs": .array([
                        .structured(TestInput(value: "x")),
                        .structured(TestInput(value: "x")),
                    ])
                ]
            ),
            Data([1, 0, 2, 2, 5, 1, 1, 1, 120, 0, 5, 1, 1, 1, 120, 0, 0])
        )

        XCTAssertThrowsError(
            try LuxoBinaryProtocol.encodeRequest(schema: scalar, params: ["input": ["name": "luxo"]])
        )
    }

    func testUnknownParamTypesAndNonStringDateTimeAreRejected() {
        XCTAssertThrowsError(
            try LuxoBinaryProtocol.encodeRequest(
                schema: APISchema(id: 1, params: [.init(fieldID: 1, name: "at", type: "DateTime")]),
                params: ["at": 0]
            ))
    }

    func testNullableParamsEncodeNullPresentAndAbsentDistinctly() throws {
        let schema = APISchema(
            id: 9,
            params: [
                .init(fieldID: 1, name: "nickname", type: "String", nullable: true),
                .init(fieldID: 2, name: "age", type: "Int", nullable: true),
            ])
        let body = try LuxoBinaryProtocol.encodeRequest(
            schema: schema,
            params: ["nickname": .null, "age": 42]
        )
        XCTAssertEqual(body, Data([9, 0, 1, 0, 2, 1, 84, 0]))
        XCTAssertEqual(try LuxoBinaryProtocol.encodeRequest(schema: schema, params: [:]), Data([9, 0, 0]))
    }

    func testCanonicalBinaryErrorEnvelope() {
        let body = Data([
            1, 0xa0, 0x06,
            2, 10, 66, 97, 100, 82, 101, 113, 117, 101, 115, 116,
            3, 3, 98, 97, 100,
            4, 1, 116,
            5, 2, 123, 125,
            6, 1, 99,
            0,
        ])

        let error = LuxoBinaryProtocol.decodeError(body, statusCode: 400)

        XCTAssertEqual(error.name, "BadRequest")
        XCTAssertEqual(error.code, 400)
        XCTAssertEqual(error.message, "bad")
        XCTAssertEqual(error.traceId, "t")
        XCTAssertEqual(error.data as? [String: Int], [:])
        XCTAssertEqual(error.cause, "c")
    }

    func testNonCanonicalBinaryErrorEnvelopesAreRejected() {
        let invalid = [
            Data([1]),
            Data([1, 0xa0, 0x06, 0]),
            Data([1, 0xa0, 0x06, 2, 1, 69, 3, 1, 109]),
            Data([1, 0xa0, 0x06, 2, 1, 69, 3, 1, 109, 0, 1]),
        ]
        for body in invalid {
            XCTAssertEqual(LuxoBinaryProtocol.decodeError(body, statusCode: 400).name, "ParseError")
        }
        XCTAssertEqual(
            LuxoBinaryProtocol.decodeError(Data([7, 0]), statusCode: 400).name,
            "ParseError"
        )
        XCTAssertEqual(
            LuxoBinaryProtocol.decodeError(
                Data([1, 0xa0, 0x06, 2, 1, 69, 3, 1, 109, 5, 1, 0xff, 0]),
                statusCode: 400
            ).name,
            "ParseError"
        )
    }

    func testBinaryErrorRejectsDuplicateFields() {
        let fields = [
            Data([1, 0xa0, 0x06]), Data([2, 1, 69]), Data([3, 1, 109]),
            Data([4, 1, 116]), Data([5, 2, 123, 125]), Data([6, 1, 99]),
        ]
        let body = fields.reduce(into: Data()) { $0.append($1) }
        for field in fields {
            let error = LuxoBinaryProtocol.decodeError(body + field + Data([0]), statusCode: 502)
            XCTAssertEqual(error.name, "ParseError", "field \(field[0])")
            XCTAssertEqual(error.code, 502)
        }
    }

    func testBinaryCallFrameSupportsMultiByteSequence() {
        let frame = LuxoBinaryProtocol.callFrame(sequence: 253, body: Data([7, 0, 0]))
        XCTAssertEqual(frame, Data([1, 0xfd, 0x01, 7, 0, 0]))
    }

    func testJSONSubscriptionAcknowledgements() {
        let success = LuxoWebSocketProtocol.decodeJSONSubscriptionAcknowledgement(values: [
            "$sub": 253,
            "ok": true,
        ])
        XCTAssertEqual(success?.id, 253)
        XCTAssertNil(success?.error)

        let failure = LuxoWebSocketProtocol.decodeJSONSubscriptionAcknowledgement(values: [
            "$sub": 253,
            "error": "BadRequest",
            "code": 400,
            "message": "invalid status",
        ])
        XCTAssertEqual(failure?.id, 253)
        XCTAssertEqual(failure?.error?.name, "BadRequest")
        XCTAssertEqual(failure?.error?.code, 400)
        XCTAssertEqual(failure?.error?.message, "invalid status")
        XCTAssertNil(
            LuxoWebSocketProtocol.decodeJSONSubscriptionAcknowledgement(values: [
                "$stream": "watchOrders",
                "data": [:],
            ]))
    }

    func testBinarySubscriptionAcknowledgements() {
        XCTAssertEqual(
            decodeBinaryAcknowledgement(Data([0x13, 0xfd, 0x01]))?.id,
            253
        )

        let errorBody = Data([
            1, 0xa0, 0x06,
            2, 10, 66, 97, 100, 82, 101, 113, 117, 101, 115, 116,
            3, 3, 98, 97, 100,
            0,
        ])
        let failure = decodeBinaryAcknowledgement(
            Data([0x14, 7]) + errorBody
        )
        XCTAssertEqual(failure?.id, 7)
        XCTAssertEqual(failure?.error?.name, "BadRequest")
        XCTAssertEqual(failure?.error?.code, 400)
        XCTAssertEqual(failure?.error?.message, "bad")
        XCTAssertNil(decodeBinaryAcknowledgement(Data([6, 7])))
    }

    func testAPISchemaNilParams() {
        let schema = APISchema(id: 1, params: nil)
        XCTAssertEqual(schema.id, 1)
        XCTAssertNil(schema.params)
    }

    // MARK: - URLSessionTransport construction

    func testURLSessionTransportSetToken() throws {
        let transport = try URLSessionTransport(endpoint: "http://localhost:4000/api")
        transport.setToken("test-token-123")
        // No crash, method callable
    }

    func testURLSessionTransportSetMode() throws {
        let transport = try URLSessionTransport(endpoint: "http://localhost:4000/api")
        transport.setMode(.binary)
        transport.setMode(.json)
        // No crash, modes set correctly
    }

    func testURLSessionTransportSetSchema() throws {
        let transport = try URLSessionTransport(endpoint: "http://localhost:4000/api")
        let schema: [String: APISchema] = [
            "getUser": APISchema(
                id: 1,
                params: [
                    APISchema.ParamSchema(fieldID: 1, name: "id", type: "Int")
                ])
        ]
        try transport.setSchema(schema)
        // No crash, schema set correctly
    }

    func testURLSessionTransportWithToken() throws {
        let transport = try URLSessionTransport(endpoint: "http://localhost:4000/api", token: "init-token")
        // No crash, initializer with token works
        transport.setToken("new-token")
    }

    func testURLSessionTransportRejectsInvalidEndpoint() {
        XCTAssertThrowsError(try URLSessionTransport(endpoint: "not a URL")) { error in
            XCTAssertEqual((error as? LuxoError)?.name, "ConfigError")
        }
        XCTAssertThrowsError(try URLSessionTransport(endpoint: "ws://localhost/socket")) { error in
            XCTAssertEqual((error as? LuxoError)?.name, "ConfigError")
        }
        XCTAssertThrowsError(try URLSessionTransport(endpoint: "https://example.com", timeout: 0))
    }

    func testURLSessionTransportJSONCallIncludesStateSnapshot() async throws {
        let transport = try makeURLSessionTransport { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            XCTAssertEqual(request.timeoutInterval, 12)
            let body = try self.requestBody(request)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["$api"] as? String, "getUser")
            XCTAssertEqual(json["id"] as? Int, 7)
            return try self.mockResponse(request, status: 200, body: ["data": ["id": 7]])
        }
        transport.setToken("secret")

        let result = try await transport.call("getUser", params: ["id": 7])

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: result.data) as? [String: Int]
        )
        XCTAssertEqual(object["id"], 7)
    }

    func testJSONTransportRejectsInvalidSchemaIntegersBeforeSending() async throws {
        let schema = APISchema(
            id: 1,
            params: [
                .init(fieldID: 1, name: "value", type: "Int"),
                .init(fieldID: 2, name: "durations", type: "Duration", isList: true, nullable: true),
            ])
        let invalid: [LuxoValue] = [.float(1), .float(1.5), .bool(true), .string("1"), .null, .object([:]), .array([])]
        for params in invalid.map({ ["value": $0] }) + invalid.map({ ["durations": .array([$0])] }) {
            let transport = try makeURLSessionTransport { request in
                XCTFail("invalid integers must not be sent")
                return try self.mockResponse(request, status: 200, body: ["data": 0])
            }
            try transport.setSchema(["echo": schema])
            XCTAssertThrowsError(try LuxoBinaryProtocol.encodeRequest(schema: schema, params: params))
            do {
                _ = try await transport.call("echo", params: params)
                XCTFail("JSON must reject the same invalid integers as Binary")
            } catch let error as LuxoError {
                XCTAssertEqual(error.name, "ConfigError")
            }
        }
    }

    func testJSONTransportChecksNestedIntegerMetadata() async throws {
        let schema = APISchema(
            id: 1,
            params: [
                .init(fieldID: 1, name: "input", type: "Model", typeName: "Input")
            ],
            types: [
                "Input": [
                    "children": .init(fieldID: 1, typeName: "Input", type: "Model", isList: true),
                    "id": .init(fieldID: 2, type: "Int"),
                ]
            ])
        let transport = try makeURLSessionTransport { request in
            XCTFail("invalid nested integers must not be sent")
            return try self.mockResponse(request, status: 200, body: ["data": 0])
        }
        try transport.setSchema(["echo": schema])
        do {
            _ = try await transport.call(
                "echo",
                params: [
                    "input": ["children": .array([.object(["id": .float(1.0)])])]
                ])
            XCTFail("expected a schema error")
        } catch let error as LuxoError {
            XCTAssertEqual(error.name, "ConfigError")
        }
    }

    func testJSONTransportPreservesValidValuesAndReplacesCompiledSchema() async throws {
        let transport = try makeURLSessionTransport { request in
            let body = try self.requestBody(request)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["$api"] as? String, "echo")
            return try self.mockResponse(request, status: 200, body: ["data": try XCTUnwrap(json["value"])])
        }
        try transport.setSchema(["echo": APISchema(id: 1, params: [.init(fieldID: 1, name: "value", type: "Int")])])
        for value in [Int64.min, Int64.max] {
            let response = try await transport.call("echo", params: ["value": .int(value), "$api": .float(.nan)])
            XCTAssertEqual(try JSONDecoder().decode(Int64.self, from: response.data), value)
        }
        try transport.setSchema(["echo": APISchema(id: 1, params: [.init(fieldID: 1, name: "value", type: "Float")])])
        let floating = try await transport.call("echo", params: ["value": .float(1.5)])
        XCTAssertEqual(try JSONDecoder().decode(Double.self, from: floating.data), 1.5)
        try transport.setSchema([:])
        let untyped = try await transport.call("echo", params: ["value": true])
        XCTAssertTrue(try JSONDecoder().decode(Bool.self, from: untyped.data))
    }

    func testWebSocketJSONChecksSchemaBeforeCallsAndSubscriptionsAreSent() async throws {
        let socket = MockWebSocketTask()
        let transport = try WebSocketTransport(
            url: "wss://example.com/socket", timeout: 0.01, session: MockWebSocketSession(socket: socket))
        try transport.setSchema(["echo": APISchema(id: 1, params: [.init(fieldID: 1, name: "id", type: "Int")])])
        transport.connect()
        defer { transport.close() }
        for subscription in [false, true] {
            do {
                if subscription {
                    _ = try await transport.subscribe("echo", decoder: { $0 }, params: ["id": .float(1)]) { _ in }
                } else {
                    _ = try await transport.call("echo", params: ["id": .float(1)])
                }
                XCTFail("expected schema rejection")
            } catch let error as LuxoError {
                XCTAssertEqual(error.name, "ConfigError")
            }
        }
        XCTAssertTrue(socket.sentMessages.isEmpty)
    }

    func testURLSessionTransportJSONErrorRequiresExplicitCode() async throws {
        let transport = try makeURLSessionTransport { request in
            try self.mockResponse(
                request, status: 422,
                body: [
                    "error": "ValidationError",
                    "message": "invalid input",
                ])
        }

        do {
            _ = try await transport.call("createUser")
            XCTFail("expected the call to fail")
        } catch let error as LuxoError {
            XCTAssertEqual(error.code, 422)
            XCTAssertEqual(error.name, "ParseError")
        }
    }

    func testURLSessionTransportRejectsMalformedJSONErrors() async throws {
        let bodies = [
            #"{"error":"RemoteError","code":true,"message":"failed"}"#,
            #"{"error":"RemoteError","code":400.5,"message":"failed"}"#,
            #"{"error":"RemoteError","code":9223372036854775808,"message":"failed"}"#,
            #"{"error":"RemoteError","code":400}"#,
            #"{"name":"RemoteError","code":400,"message":"failed"}"#,
            #"{"error":null,"code":400,"message":"failed"}"#,
            #"{"error":"RemoteError","code":400,"message":"failed","traceId":42}"#,
        ]
        for body in bodies {
            let transport = try makeURLSessionTransport { request in
                try self.mockResponse(request, status: 502, data: Data(body.utf8))
            }
            do {
                _ = try await transport.call("fail")
                XCTFail("expected a parse error: \(body)")
            } catch let error as LuxoError {
                XCTAssertEqual(error.name, "ParseError", body)
                XCTAssertEqual(error.code, 502, body)
            }
        }
    }

    func testURLSessionTransportDoesNotReplaceValidErrorCodeOrRetryMalformed401() async throws {
        let zero = try makeURLSessionTransport { request in
            try self.mockResponse(request, status: 500, body: ["error": "RemoteError", "code": 0, "message": "failed"])
        }
        do {
            _ = try await zero.call("fail")
            XCTFail("expected remote error")
        } catch let error as LuxoError {
            XCTAssertEqual(error.code, 0)
            XCTAssertEqual(error.name, "RemoteError")
        }
        let malformed = try makeURLSessionTransport { request in
            try self.mockResponse(
                request, status: 401, body: ["error": "Unauthorized", "code": true, "message": "failed"])
        }
        malformed.onTokenExpired = {
            XCTFail("malformed responses must not trigger a token refresh")
            return nil
        }
        do {
            _ = try await malformed.call("fail")
            XCTFail("expected parse error")
        } catch let error as LuxoError {
            XCTAssertEqual(error.code, 401)
            XCTAssertEqual(error.name, "ParseError")
        }
    }

    func testURLSessionTransportRefreshesTokenOnceAfter401() async throws {
        let requestLock = NSLock()
        var authorizations: [String?] = []
        let transport = try makeURLSessionTransport { request in
            let attempt = requestLock.withLock { () -> Int in
                authorizations.append(request.value(forHTTPHeaderField: "Authorization"))
                return authorizations.count
            }
            if attempt == 1 {
                return try self.mockResponse(
                    request, status: 401,
                    body: [
                        "error": "Unauthorized",
                        "code": 401,
                        "message": "expired",
                    ])
            }
            return try self.mockResponse(request, status: 200, body: ["data": "ok"])
        }
        transport.setToken("expired")
        transport.onTokenExpired = { "fresh" }

        let result = try await transport.call("viewer")

        XCTAssertEqual(try JSONDecoder().decode(String.self, from: result.data), "ok")
        XCTAssertEqual(
            requestLock.withLock { authorizations },
            ["Bearer expired", "Bearer fresh"]
        )
    }

    func testHTTPRefreshRequiresMatchingStatusAndErrorCode() async throws {
        for mode in [TransportMode.json, .binary] {
            for (status, code) in [(200, 401), (403, 401), (500, 401), (401, 403), (401, 0), (401, 401)] {
                if mode == .binary, status == 200 { continue }
                let lock = NSLock()
                var calls = 0
                var refreshes = 0
                let transport = try makeURLSessionTransport { request in
                    lock.withLock { calls += 1 }
                    return try self.mockResponse(request, status: status, data: self.unauthorizedBody(mode, code: code))
                }
                transport.setMode(mode)
                try transport.setSchema(["viewer": APISchema(id: 1)])
                transport.onTokenExpired = {
                    lock.withLock { refreshes += 1 }
                    return "renewed"
                }
                do {
                    _ = try await transport.call("viewer")
                    XCTFail("expected the original error")
                } catch let error as LuxoError {
                    XCTAssertEqual(error.code, code)
                    XCTAssertEqual(error.name, "Unauthorized")
                }
                let eligible = status == 401 && code == 401
                XCTAssertEqual(lock.withLock { refreshes }, eligible ? 1 : 0, "\(mode)/\(status)/\(code)")
                XCTAssertEqual(lock.withLock { calls }, eligible ? 2 : 1, "\(mode)/\(status)/\(code)")
            }
        }
    }

    private func unauthorizedBody(_ mode: TransportMode, code: Int) -> Data {
        if mode == .json {
            return Data("{\"error\":\"Unauthorized\",\"code\":\(code),\"message\":\"expired\"}".utf8)
        }
        var encoder = Encoder()
        encoder.writeVarint(1)
        encoder.writeSvarint(Int64(code))
        encoder.writeVarint(2)
        encoder.writeString("Unauthorized")
        encoder.writeVarint(3)
        encoder.writeString("expired")
        encoder.writeEnd()
        return encoder.data
    }

    func testURLSessionTransportPropagates401WithoutRefreshToken() async throws {
        let transport = try makeURLSessionTransport { request in
            try self.mockResponse(
                request, status: 401,
                body: [
                    "error": "Unauthorized",
                    "code": 401,
                    "message": "expired",
                ])
        }
        transport.onTokenExpired = { nil }

        do {
            _ = try await transport.call("viewer")
            XCTFail("expected the call to fail")
        } catch let error as LuxoError {
            XCTAssertEqual(error.code, 401)
            XCTAssertEqual(error.name, "Unauthorized")
        }
    }

    func testURLSessionTransportBinaryCallUsesCanonicalHeadersAndBody() async throws {
        let transport = try makeURLSessionTransport { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-luxo")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Luxo-Mode"), "binary")
            XCTAssertEqual(try self.requestBody(request), Data([9, 0, 1, 6, 0]))
            return try self.mockResponse(request, status: 200, data: Data([1, 2, 3]))
        }
        transport.setMode(.binary)
        try transport.setSchema([
            "getUser": APISchema(
                id: 9,
                params: [.init(fieldID: 1, name: "id", type: "Int")]
            )
        ])

        let result = try await transport.call("getUser", params: ["id": 3])

        XCTAssertEqual(result.data, Data([1, 2, 3]))
    }

    func testURLSessionTransportBinaryCallRequiresSchema() async throws {
        let transport = try makeURLSessionTransport { _ in
            XCTFail("request must not be sent")
            throw URLError(.badURL)
        }
        transport.setMode(.binary)

        do {
            _ = try await transport.call("missing")
            XCTFail("expected the call to fail")
        } catch let error as LuxoError {
            XCTAssertEqual(error.name, "ConfigError")
        }
    }

    func testURLSessionTransportBinaryErrorIsDecoded() async throws {
        let transport = try makeURLSessionTransport { request in
            let body = Data([
                1, 0xa0, 0x06,
                2, 10, 66, 97, 100, 82, 101, 113, 117, 101, 115, 116,
                3, 3, 98, 97, 100,
                0,
            ])
            return try self.mockResponse(request, status: 400, data: body)
        }
        transport.setMode(.binary)
        try transport.setSchema(["fail": APISchema(id: 1)])

        do {
            _ = try await transport.call("fail")
            XCTFail("expected the call to fail")
        } catch let error as LuxoError {
            XCTAssertEqual(error.code, 400)
            XCTAssertEqual(error.name, "BadRequest")
            XCTAssertEqual(error.message, "bad")
        }
    }

    func testURLSessionTransportRejectsMalformedAndNonHTTPResponses() async throws {
        let invalidJSON = try makeURLSessionTransport { request in
            try self.mockResponse(request, status: 200, data: Data("not-json".utf8))
        }
        do {
            _ = try await invalidJSON.call("invalid")
            XCTFail("expected parse error")
        } catch let error as LuxoError {
            XCTAssertEqual(error.name, "ParseError")
        }

        let nonHTTP = try makeURLSessionTransport { request in
            let response = URLResponse(
                url: try XCTUnwrap(request.url),
                mimeType: nil,
                expectedContentLength: 0,
                textEncodingName: nil
            )
            return (response, Data())
        }
        do {
            _ = try await nonHTTP.call("invalid")
            XCTFail("expected invalid response")
        } catch let error as LuxoError {
            XCTAssertEqual(error.message, "Invalid response")
        }

        nonHTTP.setMode(.binary)
        try nonHTTP.setSchema(["invalid": APISchema(id: 1)])
        do {
            _ = try await nonHTTP.call("invalid")
            XCTFail("expected network error")
        } catch let error as LuxoError {
            XCTAssertEqual(error.name, "NetworkError")
        }
    }

    func testDefaultSubscriptionReportsUnsupportedTransport() async throws {
        let transport = try URLSessionTransport(endpoint: "https://example.com/api")
        do {
            _ = try await transport.subscribe("events", decoder: { $0 }) { _ in }
            XCTFail("expected subscribe to fail")
        } catch let error as LuxoError {
            XCTAssertEqual(error.name, "ConfigError")
        }
    }

    func testWebSocketTransportRejectsInvalidEndpoint() {
        XCTAssertThrowsError(try WebSocketTransport(url: "not a URL")) { error in
            XCTAssertEqual((error as? LuxoError)?.name, "ConfigError")
        }
        XCTAssertThrowsError(try WebSocketTransport(url: "https://example.com/socket")) { error in
            XCTAssertEqual((error as? LuxoError)?.name, "ConfigError")
        }
        XCTAssertThrowsError(try WebSocketTransport(url: "wss://example.com/socket", timeout: 0))
        let socket = MockWebSocketTask()
        XCTAssertThrowsError(
            try WebSocketTransport(
                url: "wss://example.com/socket",
                session: MockWebSocketSession(socket: socket),
                baseBackoff: 0,
                maxBackoff: 1
            ))
        XCTAssertThrowsError(
            try WebSocketTransport(
                url: "wss://example.com/socket",
                session: MockWebSocketSession(socket: socket),
                baseBackoff: 2,
                maxBackoff: 1
            ))
    }

    func testWebSocketJSONCallAndCloseLifecycle() async throws {
        let socket = MockWebSocketTask()
        let session = MockWebSocketSession(socket: socket)
        let transport = try WebSocketTransport(
            url: "wss://example.com/socket",
            token: "secret",
            session: session
        )
        socket.onSend = { [weak socket] _ in
            socket?.deliver(.success(.string(#"{"$id":1,"data":{"name":"Ada"}}"#)))
        }

        transport.connect()
        let result = try await transport.call("getUser", params: ["id": 7])

        XCTAssertTrue(socket.isResumed)
        XCTAssertEqual(session.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        let message = try XCTUnwrap(socket.sentMessages.first)
        guard case .string(let text) = message else { return XCTFail("expected JSON message") }
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
        XCTAssertEqual(json["$id"] as? Int, 1)
        XCTAssertEqual(json["$api"] as? String, "getUser")
        XCTAssertEqual(json["id"] as? Int, 7)
        XCTAssertEqual(
            (try JSONSerialization.jsonObject(with: result.data) as? [String: String])?["name"],
            "Ada"
        )

        transport.close()
        XCTAssertEqual(socket.cancelCode, .normalClosure)
    }

    func testWebSocketJSONSendsFullWidthRequestIDs() async throws {
        for id in [UInt64(1), 9_007_199_254_740_993, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max] {
            let socket = MockWebSocketTask()
            let transport = try WebSocketTransport(
                url: "wss://example.com/socket", session: MockWebSocketSession(socket: socket),
                initialSequence: id - 1
            )
            defer { transport.close() }
            socket.onSend = { [weak socket] message in
                guard case .string(let text) = message else { return XCTFail("expected JSON") }
                XCTAssertEqual(text, "{\"$api\":\"getUser\",\"$id\":\(id),\"id\":-9223372036854775808}")
                socket?.deliver(.success(.string("{\"$id\":\(id),\"data\":9007199254740993}")))
            }
            transport.connect()
            let result = try await transport.call("getUser", params: ["id": .int(Int64.min)])
            XCTAssertEqual(result.data, Data("9007199254740993".utf8))
        }
    }

    func testWebSocketMalformedJSONErrorsCompleteCallsAndSubscriptions() async throws {
        for subscription in [false, true] {
            for fields in [
                #""code":true,"message":"failed""#,
                #""code":9223372036854775808,"message":"failed""#,
                #""message":"missing code""#,
                #""code":400,"message":false"#,
                #""code":400,"message":"failed","cause":42"#,
            ] {
                let socket = MockWebSocketTask()
                let transport = try WebSocketTransport(
                    url: "wss://example.com/socket", timeout: 0.2, session: MockWebSocketSession(socket: socket))
                defer { transport.close() }
                socket.onSend = { [weak socket] _ in
                    let correlation = subscription ? #""$sub":1"# : #""$id":1"#
                    socket?.deliver(.success(.string("{\(correlation),\"error\":\"RemoteError\",\(fields)}")))
                }
                transport.connect()
                do {
                    if subscription {
                        _ = try await transport.subscribe("fail", decoder: { $0 }) { _ in }
                    } else {
                        _ = try await transport.call("fail")
                    }
                    XCTFail("expected parse error")
                } catch let error as LuxoError {
                    XCTAssertEqual(error.name, "ParseError", fields)
                    XCTAssertEqual(error.code, 0, fields)
                }
            }
        }
    }

    func testWebSocketSequenceExhaustionPreservesPendingCalls() async throws {
        for mode in [TransportMode.json, .binary] {
            let socket = MockWebSocketTask()
            let transport = try WebSocketTransport(
                url: "wss://example.com/socket", session: MockWebSocketSession(socket: socket),
                initialSequence: UInt64.max - 1
            )
            defer { transport.close() }
            transport.setMode(mode)
            try transport.setSchema(["getUser": APISchema(id: 7)])
            let sent = expectation(description: "last available ID sent")
            socket.onSend = { _ in sent.fulfill() }
            transport.connect()
            let last = Task { try await transport.call("getUser") }
            await fulfillment(of: [sent], timeout: 1)
            socket.onSend = nil
            for _ in 0..<2 {
                do {
                    _ = try await transport.call("getUser")
                    XCTFail("exhausted request IDs must not wrap")
                } catch let error as LuxoError {
                    XCTAssertEqual(error.name, "RequestIDExhausted")
                }
            }
            XCTAssertEqual(socket.sentMessages.count, 1)
            if mode == .json {
                socket.deliver(.success(.string("{\"$id\":\(UInt64.max),\"data\":42}")))
            } else {
                var frame = Encoder()
                frame.writeRawBytes(Data([2]))
                frame.writeVarint(UInt64.max)
                frame.writeRawBytes(Data("42".utf8))
                socket.deliver(.success(.data(frame.data)))
            }
            let result = try await last.value
            XCTAssertEqual(result.data, Data("42".utf8))
        }
    }

    func testWebSocketJSONRejectsNonIntegerRequestIDs() async throws {
        let invalidIDs = [
            "true", "false", "1.5", "1.0", "1e0", "-1", "null", "\"1\"", "[]", "{}",
            "18446744073709551617", "1.0000000000000001",
        ]
        for id in invalidIDs {
            let socket = MockWebSocketTask()
            let transport = try WebSocketTransport(
                url: "wss://example.com/socket",
                session: MockWebSocketSession(socket: socket)
            )
            defer { transport.close() }
            socket.onSend = { [weak socket] _ in
                socket?.deliver(.success(.string("{\"$id\":\(id),\"data\":0}")))
                socket?.deliver(.success(.string("{\"$id\":1,\"data\":9007199254740993}")))
            }
            transport.connect()
            let result = try await transport.call("getUser")
            XCTAssertEqual(result.data, Data("9007199254740993".utf8), "request ID: \(id)")
        }
    }

    func testWebSocketBinaryRejectsMultiByteFrameType() async throws {
        let socket = MockWebSocketTask()
        let transport = try WebSocketTransport(
            url: "wss://example.com/socket",
            session: MockWebSocketSession(socket: socket)
        )
        defer { transport.close() }
        transport.setMode(.binary)
        try transport.setSchema(["getUser": APISchema(id: 7)])
        socket.onSend = { [weak socket] _ in
            socket?.deliver(.success(.data(Data([0x82, 0, 1, 0]))))
            socket?.deliver(.success(.data(Data([2, 1, 42]))))
        }
        transport.connect()
        let result = try await transport.call("getUser")
        XCTAssertEqual(result.data, Data([42]))
    }

    func testBinarySubscriptionAcknowledgementRejectsMalformedHeaders() {
        let invalid = [
            Data(), Data([7]), Data([7, 0x80]), Data([0x87, 0, 7]),
            Data([7, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 2]),
        ]
        for data in invalid {
            XCTAssertNil(decodeBinaryAcknowledgement(data))
        }
    }

    func testWebSocketBinaryCallAndErrorFrames() async throws {
        let socket = MockWebSocketTask()
        let transport = try WebSocketTransport(
            url: "wss://example.com/socket",
            session: MockWebSocketSession(socket: socket)
        )
        transport.setMode(.binary)
        try transport.setSchema(["getUser": APISchema(id: 7)])
        transport.connect()

        socket.onSend = { [weak socket] _ in
            socket?.deliver(.success(.data(Data([2, 1, 9, 8]))))
        }
        let successValue = try await transport.call("getUser")
        XCTAssertEqual(successValue.data, Data([9, 8]))

        let errorBody = Data([
            1, 0xa0, 0x06,
            2, 10, 66, 97, 100, 82, 101, 113, 117, 101, 115, 116,
            3, 3, 98, 97, 100,
            0,
        ])
        socket.onSend = { [weak socket] _ in
            socket?.deliver(.success(.data(Data([3, 2]) + errorBody)))
        }
        do {
            _ = try await transport.call("getUser")
            XCTFail("expected binary error")
        } catch let error as LuxoError {
            XCTAssertEqual(error.name, "BadRequest")
        }
        transport.close()
    }

    func testWebSocketJSONSubscriptionReceivesStreamAndUnsubscribes() async throws {
        let socket = MockWebSocketTask()
        let transport = try WebSocketTransport(
            url: "wss://example.com/socket",
            session: MockWebSocketSession(socket: socket)
        )
        transport.connect()
        let streamReceived = expectation(description: "stream received")
        socket.onSend = { [weak socket] _ in
            socket?.deliver(.success(.string(#"{"$sub":1,"ok":true}"#)))
        }

        let unsubscribe = try await transport.subscribe(
            "watchOrders", decoder: { $0 },
            params: ["status": "OPEN"]
        ) { value in
            XCTAssertEqual(
                (try? JSONSerialization.jsonObject(with: value.data) as? [String: Int])?["id"],
                9
            )
            streamReceived.fulfill()
        }
        socket.onSend = nil

        socket.deliver(.success(.string(#"{"$stream":1,"data":{"id":9}}"#)))
        await fulfillment(of: [streamReceived], timeout: 1)
        unsubscribe()

        guard case .string(let text) = socket.sentMessages.last else {
            return XCTFail("expected unsubscribe message")
        }
        XCTAssertEqual(
            try LuxoValue.decodeJSONData(Data(text.utf8)),
            .object(["$unsub": .int(1)])
        )
        transport.close()
    }

    func testWebSocketReportsConnectionSendAndTimeoutFailures() async throws {
        let socket = MockWebSocketTask()
        let transport = try WebSocketTransport(
            url: "wss://example.com/socket",
            timeout: 0.02,
            session: MockWebSocketSession(socket: socket)
        )
        do {
            _ = try await transport.call("offline")
            XCTFail("expected disconnected call to fail")
        } catch let error as LuxoError {
            XCTAssertEqual(error.name, "ConnectionError")
        }

        transport.connect()
        socket.sendError = URLError(.cannotConnectToHost)
        do {
            _ = try await transport.call("failedSend")
            XCTFail("expected send to fail")
        } catch let error as LuxoError {
            XCTAssertEqual(error.name, "NetworkError")
        }

        socket.sendError = nil
        do {
            _ = try await transport.call("timeout")
            XCTFail("expected timeout")
        } catch let error as LuxoError {
            XCTAssertEqual(error.name, "TimeoutError")
        }
        transport.close()
    }

    func testWebSocketValidatesBinarySchemaAndSubscriptionConnection() async throws {
        let socket = MockWebSocketTask()
        let transport = try WebSocketTransport(
            url: "wss://example.com/socket",
            session: MockWebSocketSession(socket: socket)
        )
        do {
            _ = try await transport.subscribe("offline", decoder: { $0 }) { _ in }
            XCTFail("expected disconnected subscription")
        } catch let error as LuxoError {
            XCTAssertEqual(error.name, "ConnectionError")
        }

        transport.setToken("secret")
        transport.setMode(.binary)
        transport.connect()
        do {
            _ = try await transport.call("missing")
            XCTFail("expected missing call schema")
        } catch let error as LuxoError {
            XCTAssertEqual(error.name, "ConfigError")
        }
        do {
            _ = try await transport.subscribe("missing", decoder: { $0 }) { _ in }
            XCTFail("expected missing subscription schema")
        } catch let error as LuxoError {
            XCTAssertEqual(error.name, "ConfigError")
        }

        transport.connect()
        XCTAssertEqual(socket.cancelCode, .goingAway)
        transport.close()
    }

    func testWebSocketSubscriptionSendFailureAndTimeout() async throws {
        let socket = MockWebSocketTask()
        let transport = try WebSocketTransport(
            url: "wss://example.com/socket",
            timeout: 0.02,
            session: MockWebSocketSession(socket: socket)
        )
        transport.connect()
        socket.sendError = URLError(.cannotConnectToHost)
        do {
            _ = try await transport.subscribe("failed", decoder: { $0 }) { _ in }
            XCTFail("expected subscription send failure")
        } catch let error as LuxoError {
            XCTAssertEqual(error.name, "NetworkError")
        }

        socket.sendError = nil
        do {
            _ = try await transport.subscribe("timeout", decoder: { $0 }) { _ in }
            XCTFail("expected subscription timeout")
        } catch let error as LuxoError {
            XCTAssertEqual(error.name, "TimeoutError")
        }
        transport.close()
    }

    func testWebSocketServerRejectionOnlyFailsItsSubscriptionID() async throws {
        let socket = MockWebSocketTask()
        let transport = try WebSocketTransport(
            url: "wss://example.com/socket",
            session: MockWebSocketSession(socket: socket)
        )
        transport.connect()
        let sent = expectation(description: "subscription sent")
        let finished = expectation(description: "subscription rejected")
        socket.onSend = { _ in sent.fulfill() }
        Task {
            do {
                _ = try await transport.subscribe("watchOrders", decoder: { $0 }) { _ in }
                XCTFail("expected server rejection")
            } catch let error as LuxoError {
                XCTAssertEqual(error.code, 403)
                XCTAssertEqual(error.name, "Forbidden")
            } catch {
                XCTFail("unexpected error: \(error)")
            }
            finished.fulfill()
        }
        await fulfillment(of: [sent], timeout: 1)
        socket.onSend = { [weak socket] _ in
            socket?.deliver(.success(.string(#"{"$sub":2,"ok":true}"#)))
        }
        let cancel = try await transport.subscribe("watchOrders", decoder: { $0 }) { _ in }
        socket.onSend = nil

        socket.deliver(
            .success(
                .string(
                    #"{"$sub":1,"error":"Forbidden","code":403,"message":"denied"}"#
                )))
        await fulfillment(of: [finished], timeout: 1)
        cancel()
        transport.close()
    }

    func testWebSocketBinarySubscriptionStreamsAndUnsubscribes() async throws {
        let socket = MockWebSocketTask()
        let transport = try WebSocketTransport(
            url: "wss://example.com/socket",
            session: MockWebSocketSession(socket: socket)
        )
        transport.setMode(.binary)
        try transport.setSchema(["watchOrders": APISchema(id: 7)])
        transport.connect()
        let streamed = expectation(description: "binary stream received")
        socket.onSend = { [weak socket] _ in
            socket?.deliver(.success(.data(Data([0x13, 1]))))
        }

        let unsubscribe = try await transport.subscribe("watchOrders", decoder: { $0 }) { value in
            XCTAssertEqual(value.data, Data([9, 8]))
            streamed.fulfill()
        }
        socket.onSend = nil
        XCTAssertEqual(socket.dataMessage(at: 0), Data([0x10, 1, 7, 0, 0]))

        socket.deliver(.success(.data(Data([0x12, 1, 9, 8]))))
        await fulfillment(of: [streamed], timeout: 1)
        unsubscribe()
        XCTAssertEqual(socket.dataMessage(at: 1), Data([0x11, 1]))
        transport.close()
    }

    func testWebSocketConnectionLossFailsPendingCall() async throws {
        let socket = MockWebSocketTask()
        let transport = try WebSocketTransport(
            url: "wss://example.com/socket",
            session: MockWebSocketSession(socket: socket)
        )
        transport.connect()
        socket.onSend = { [weak socket] _ in
            socket?.deliver(.failure(URLError(.networkConnectionLost)))
        }
        do {
            _ = try await transport.call("getUser")
            XCTFail("expected connection loss")
        } catch let error as LuxoError {
            XCTAssertEqual(error.name, "ConnectionError")
        }
        transport.close()
    }

    func testWebSocketReconnectsWithoutRestoringInterruptedSubscriptions() async throws {
        let firstSocket = MockWebSocketTask()
        let secondSocket = MockWebSocketTask()
        let session = MockWebSocketSession(sockets: [firstSocket, secondSocket])
        let transport = try WebSocketTransport(
            url: "wss://example.com/socket",
            session: session,
            baseBackoff: 0.001,
            maxBackoff: 0.002
        )
        transport.connect()
        firstSocket.onSend = { [weak firstSocket] _ in
            firstSocket?.deliver(.success(.string(#"{"$sub":1,"ok":true}"#)))
        }
        let ended = expectation(description: "subscription interrupted")
        let cancel = try await transport.subscribe(
            "watchOrders", decoder: { $0 },
            observer: StreamObserver(onError: { error in
                XCTAssertEqual(error.name, "NetworkError")
                ended.fulfill()
            })
        ) { _ in XCTFail("old subscription delivered data") }

        let reconnected = expectation(description: "connection restored")
        secondSocket.onResume = { reconnected.fulfill() }
        firstSocket.deliver(.failure(URLError(.networkConnectionLost)))
        await fulfillment(of: [ended, reconnected], timeout: 1)

        XCTAssertTrue(secondSocket.isResumed)
        XCTAssertTrue(secondSocket.sentMessages.isEmpty)
        cancel()
        XCTAssertTrue(secondSocket.sentMessages.isEmpty)
        transport.close()
    }

    private func decodeBinaryAcknowledgement(_ data: Data) -> LuxoWebSocketProtocol.SubscriptionAcknowledgement? {
        LuxoWebSocketProtocol.decodeBinaryFrame(data).flatMap(LuxoWebSocketProtocol.subscriptionAcknowledgement)
    }

    private func makeURLSessionTransport(
        handler: @escaping (URLRequest) throws -> (URLResponse, Data)
    ) throws -> URLSessionTransport {
        let handlerID = MockURLProtocol.registerHandler(handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        configuration.httpAdditionalHeaders = [MockURLProtocol.handlerHeader: handlerID]
        let session = URLSession(configuration: configuration)
        return try URLSessionTransport(
            endpoint: "https://example.com/api",
            timeout: 12,
            session: session
        )
    }

    private func mockResponse(
        _ request: URLRequest,
        status: Int,
        body: [String: Any]
    ) throws -> (URLResponse, Data) {
        try mockResponse(
            request,
            status: status,
            data: JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        )
    }

    private func mockResponse(
        _ request: URLRequest,
        status: Int,
        data: Data
    ) throws -> (URLResponse, Data) {
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: status,
                httpVersion: "HTTP/2",
                headerFields: nil
            ))
        return (response, data)
    }

    private func requestBody(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw try XCTUnwrap(stream.streamError) }
            if count == 0 { break }
            body.append(contentsOf: buffer[..<count])
        }
        return body
    }
}

private final class MockURLProtocol: URLProtocol {
    static let handlerHeader = "X-Luxo-Test-Handler"
    private static let registry = MockURLProtocolRegistry()

    static func registerHandler(
        _ handler: @escaping (URLRequest) throws -> (URLResponse, Data)
    ) -> String {
        registry.register(handler)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler = request.value(forHTTPHeaderField: Self.handlerHeader)
            .flatMap { Self.registry.handler(for: $0) }
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class MockURLProtocolRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [String: (URLRequest) throws -> (URLResponse, Data)] = [:]

    func register(
        _ handler: @escaping (URLRequest) throws -> (URLResponse, Data)
    ) -> String {
        let id = UUID().uuidString
        lock.withLock { handlers[id] = handler }
        return id
    }

    func handler(for id: String) -> ((URLRequest) throws -> (URLResponse, Data))? {
        lock.withLock { handlers[id] }
    }
}

final class MockWebSocketSession: LuxoWebSocketSession {
    private let lock = NSLock()
    private var sockets: [MockWebSocketTask]
    private var requestStorage: URLRequest?
    var lastRequest: URLRequest? { lock.withLock { requestStorage } }

    init(socket: MockWebSocketTask) {
        self.sockets = [socket]
    }

    init(sockets: [MockWebSocketTask]) {
        self.sockets = sockets
    }

    func makeWebSocketTask(with request: URLRequest) -> LuxoWebSocketTask {
        lock.withLock {
            requestStorage = request
            return sockets.count == 1 ? sockets[0] : sockets.removeFirst()
        }
    }
}

final class MockWebSocketTask: LuxoWebSocketTask, @unchecked Sendable {
    private let lock = NSLock()
    private var receiver: (@Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void)?
    private var messages: [URLSessionWebSocketTask.Message] = []
    private var resumed = false
    private var closedWith: URLSessionWebSocketTask.CloseCode?
    private var failure: Error?
    private var sendHandler: ((URLSessionWebSocketTask.Message) -> Void)?
    private var resumeHandler: (() -> Void)?
    private var delayedSends = false
    private var completions: [@Sendable (Error?) -> Void] = []
    var holdSendCompletions: Bool {
        get { lock.withLock { delayedSends } }
        set { lock.withLock { delayedSends = newValue } }
    }
    var sentMessages: [URLSessionWebSocketTask.Message] { lock.withLock { messages } }
    var isResumed: Bool { lock.withLock { resumed } }
    var cancelCode: URLSessionWebSocketTask.CloseCode? { lock.withLock { closedWith } }
    var sendError: Error? {
        get { lock.withLock { failure } }
        set { lock.withLock { failure = newValue } }
    }
    var onSend: ((URLSessionWebSocketTask.Message) -> Void)? {
        get { lock.withLock { sendHandler } }
        set { lock.withLock { sendHandler = newValue } }
    }
    var onResume: (() -> Void)? {
        get { lock.withLock { resumeHandler } }
        set { lock.withLock { resumeHandler = newValue } }
    }

    func resume() {
        let callback = lock.withLock {
            resumed = true; return resumeHandler
        }
        callback?()
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        lock.withLock { closedWith = closeCode }
    }

    func send(
        _ message: URLSessionWebSocketTask.Message,
        completionHandler: @escaping @Sendable (Error?) -> Void
    ) {
        let state = lock.withLock { () -> (Error?, ((URLSessionWebSocketTask.Message) -> Void)?, Bool) in
            messages.append(message)
            if delayedSends { completions.append(completionHandler) }
            return (failure, sendHandler, delayedSends)
        }
        state.1?(message)
        if !state.2 { completionHandler(state.0) }
    }

    func completeSend(at index: Int, error: Error?) {
        let completion = lock.withLock { completions[index] }
        completion(error)
    }

    func receive(
        completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void
    ) {
        lock.withLock { receiver = completionHandler }
    }

    func deliver(_ result: Result<URLSessionWebSocketTask.Message, Error>) {
        let handler = lock.withLock { () -> (@Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void)? in
            let current = receiver
            receiver = nil
            return current
        }
        handler?(result)
    }

    func dataMessage(at index: Int) -> Data? {
        lock.withLock {
            guard messages.indices.contains(index), case .data(let data) = messages[index] else {
                return nil
            }
            return data
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
