import XCTest
@testable import LuxoClient

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

final class TransportTests: XCTestCase {
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
        XCTAssertEqual(decoder.readSvarint(), 60)
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

    func testUnknownParamTypesAndNonStringDateTimeAreRejected() {
        XCTAssertThrowsError(
            try LuxoBinaryProtocol.encodeRequest(
                schema: APISchema(id: 1, params: [.init(fieldID: 1, name: "input", type: "Model")]),
                params: ["input": ["name": "luxo"]]
            ))
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

    func testBinaryCallFrameSupportsMultiByteSequence() {
        let frame = LuxoBinaryProtocol.callFrame(sequence: 253, body: Data([7, 0, 0]))
        XCTAssertEqual(frame, Data([1, 0xfd, 0x01, 7, 0, 0]))
    }

    func testJSONSubscriptionAcknowledgements() {
        let success = LuxoWebSocketProtocol.decodeJSONSubscriptionAcknowledgement([
            "$sub": "watchOrders",
            "ok": true,
        ])
        XCTAssertEqual(success?.api, "watchOrders")
        XCTAssertNil(success?.error)

        let failure = LuxoWebSocketProtocol.decodeJSONSubscriptionAcknowledgement([
            "$sub": "watchOrders",
            "error": "BadRequest",
            "code": 400,
            "message": "invalid status",
        ])
        XCTAssertEqual(failure?.api, "watchOrders")
        XCTAssertEqual(failure?.error?.name, "BadRequest")
        XCTAssertEqual(failure?.error?.code, 400)
        XCTAssertEqual(failure?.error?.message, "invalid status")
        XCTAssertNil(
            LuxoWebSocketProtocol.decodeJSONSubscriptionAcknowledgement([
                "$stream": "watchOrders",
                "data": [:],
            ]))
    }

    func testBinarySubscriptionAcknowledgements() {
        XCTAssertEqual(
            LuxoWebSocketProtocol.decodeBinarySubscriptionAcknowledgement(Data([7, 0xfd, 0x01]))?.apiID,
            253
        )

        let errorBody = Data([
            1, 0xa0, 0x06,
            2, 10, 66, 97, 100, 82, 101, 113, 117, 101, 115, 116,
            3, 3, 98, 97, 100,
            0,
        ])
        let failure = LuxoWebSocketProtocol.decodeBinarySubscriptionAcknowledgement(
            Data([8, 7]) + errorBody
        )
        XCTAssertEqual(failure?.apiID, 7)
        XCTAssertEqual(failure?.error?.name, "BadRequest")
        XCTAssertEqual(failure?.error?.code, 400)
        XCTAssertEqual(failure?.error?.message, "bad")
        XCTAssertNil(LuxoWebSocketProtocol.decodeBinarySubscriptionAcknowledgement(Data([6, 7])))
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
        transport.setSchema(schema)
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
            JSONSerialization.jsonObject(with: result) as? [String: Int]
        )
        XCTAssertEqual(object["id"], 7)
    }

    func testURLSessionTransportJSONErrorUsesHTTPStatus() async throws {
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
            XCTAssertEqual(error.name, "ValidationError")
            XCTAssertEqual(error.message, "invalid input")
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
                        "message": "expired",
                    ])
            }
            return try self.mockResponse(request, status: 200, body: ["data": "ok"])
        }
        transport.setToken("expired")
        transport.onTokenExpired = { "fresh" }

        let result = try await transport.call("viewer")

        XCTAssertEqual(try JSONDecoder().decode(String.self, from: result), "ok")
        XCTAssertEqual(
            requestLock.withLock { authorizations },
            ["Bearer expired", "Bearer fresh"]
        )
    }

    func testURLSessionTransportPropagates401WithoutRefreshToken() async throws {
        let transport = try makeURLSessionTransport { request in
            try self.mockResponse(
                request, status: 401,
                body: [
                    "error": "Unauthorized",
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
        transport.setSchema([
            "getUser": APISchema(
                id: 9,
                params: [.init(fieldID: 1, name: "id", type: "Int")]
            )
        ])

        let result = try await transport.call("getUser", params: ["id": 3])

        XCTAssertEqual(result, Data([1, 2, 3]))
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
        transport.setSchema(["fail": APISchema(id: 1)])

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
        nonHTTP.setSchema(["invalid": APISchema(id: 1)])
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
            _ = try await transport.subscribe("events") { _ in }
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
            (try JSONSerialization.jsonObject(with: result) as? [String: String])?["name"],
            "Ada"
        )

        transport.close()
        XCTAssertEqual(socket.cancelCode, .normalClosure)
    }

    func testWebSocketBinaryCallAndErrorFrames() async throws {
        let socket = MockWebSocketTask()
        let transport = try WebSocketTransport(
            url: "wss://example.com/socket",
            session: MockWebSocketSession(socket: socket)
        )
        transport.setMode(.binary)
        transport.setSchema(["getUser": APISchema(id: 7)])
        transport.connect()

        socket.onSend = { [weak socket] _ in
            socket?.deliver(.success(.data(Data([2, 1, 9, 8]))))
        }
        let successValue = try await transport.call("getUser")
        XCTAssertEqual(successValue, Data([9, 8]))

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
            socket?.deliver(.success(.string(#"{"$sub":"watchOrders","ok":true}"#)))
        }

        let unsubscribe = try await transport.subscribe(
            "watchOrders",
            params: ["status": "OPEN"]
        ) { value in
            XCTAssertEqual(
                (try? JSONSerialization.jsonObject(with: value) as? [String: Int])?["id"],
                9
            )
            streamReceived.fulfill()
        }
        socket.onSend = nil

        socket.deliver(.success(.string(#"{"$stream":"watchOrders","data":{"id":9}}"#)))
        await fulfillment(of: [streamReceived], timeout: 1)
        unsubscribe()

        guard case .string(let text) = socket.sentMessages.last else {
            return XCTFail("expected unsubscribe message")
        }
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String],
            ["$unsub": "watchOrders"]
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
            _ = try await transport.subscribe("offline") { _ in }
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
            _ = try await transport.subscribe("missing") { _ in }
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
            _ = try await transport.subscribe("failed") { _ in }
            XCTFail("expected subscription send failure")
        } catch let error as LuxoError {
            XCTAssertEqual(error.name, "NetworkError")
        }

        socket.sendError = nil
        do {
            _ = try await transport.subscribe("timeout") { _ in }
            XCTFail("expected subscription timeout")
        } catch let error as LuxoError {
            XCTAssertEqual(error.name, "TimeoutError")
        }
        transport.unsubscribe("missing")
        transport.close()
    }

    func testWebSocketRejectsDuplicateAndServerRejectedSubscription() async throws {
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
                _ = try await transport.subscribe("watchOrders") { _ in }
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
        socket.onSend = nil

        do {
            _ = try await transport.subscribe("watchOrders") { _ in }
            XCTFail("expected duplicate subscription failure")
        } catch let error as LuxoError {
            XCTAssertEqual(error.name, "ConfigError")
        }

        socket.deliver(
            .success(
                .string(
                    #"{"$sub":"watchOrders","error":"Forbidden","code":403,"message":"denied"}"#
                )))
        await fulfillment(of: [finished], timeout: 1)
        transport.close()
    }

    func testWebSocketBinarySubscriptionStreamsAndUnsubscribes() async throws {
        let socket = MockWebSocketTask()
        let transport = try WebSocketTransport(
            url: "wss://example.com/socket",
            session: MockWebSocketSession(socket: socket)
        )
        transport.setMode(.binary)
        transport.setSchema(["watchOrders": APISchema(id: 7)])
        transport.connect()
        let streamed = expectation(description: "binary stream received")
        socket.onSend = { [weak socket] _ in
            socket?.deliver(.success(.data(Data([7, 7]))))
        }

        let unsubscribe = try await transport.subscribe("watchOrders") { value in
            XCTAssertEqual(value, Data([9, 8]))
            streamed.fulfill()
        }
        socket.onSend = nil
        XCTAssertEqual(socket.dataMessage(at: 0), Data([4, 7, 0, 0]))

        socket.deliver(.success(.data(Data([6, 7, 9, 8]))))
        await fulfillment(of: [streamed], timeout: 1)
        unsubscribe()
        XCTAssertEqual(socket.dataMessage(at: 1), Data([5, 7]))
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

    func testWebSocketReconnectsAndRestoresConfirmedSubscriptions() async throws {
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
            firstSocket?.deliver(.success(.string(#"{"$sub":"watchOrders","ok":true}"#)))
        }
        _ = try await transport.subscribe("watchOrders") { _ in }

        let restored = expectation(description: "subscription restored")
        secondSocket.onSend = { _ in restored.fulfill() }
        firstSocket.deliver(.failure(URLError(.networkConnectionLost)))
        await fulfillment(of: [restored], timeout: 1)

        XCTAssertTrue(secondSocket.isResumed)
        guard case .string(let text) = secondSocket.sentMessages.first else {
            return XCTFail("expected restored JSON subscription")
        }
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String],
            ["$sub": "watchOrders"]
        )
        transport.close()
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

private final class MockWebSocketSession: LuxoWebSocketSession {
    private let lock = NSLock()
    private var sockets: [MockWebSocketTask]
    private(set) var lastRequest: URLRequest?

    init(socket: MockWebSocketTask) {
        self.sockets = [socket]
    }

    init(sockets: [MockWebSocketTask]) {
        self.sockets = sockets
    }

    func makeWebSocketTask(with request: URLRequest) -> LuxoWebSocketTask {
        lock.withLock {
            lastRequest = request
            return sockets.count == 1 ? sockets[0] : sockets.removeFirst()
        }
    }
}

private final class MockWebSocketTask: LuxoWebSocketTask, @unchecked Sendable {
    private let lock = NSLock()
    private var receiver: (@Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void)?
    private(set) var sentMessages: [URLSessionWebSocketTask.Message] = []
    private(set) var isResumed = false
    private(set) var cancelCode: URLSessionWebSocketTask.CloseCode?
    var sendError: Error?
    var onSend: ((URLSessionWebSocketTask.Message) -> Void)?

    func resume() {
        lock.withLock { isResumed = true }
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        lock.withLock { cancelCode = closeCode }
    }

    func send(
        _ message: URLSessionWebSocketTask.Message,
        completionHandler: @escaping @Sendable (Error?) -> Void
    ) {
        let state = lock.withLock { () -> (Error?, ((URLSessionWebSocketTask.Message) -> Void)?) in
            sentMessages.append(message)
            return (sendError, onSend)
        }
        state.1?(message)
        completionHandler(state.0)
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
            guard sentMessages.indices.contains(index), case .data(let data) = sentMessages[index] else {
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
