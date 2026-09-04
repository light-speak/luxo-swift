import XCTest
@testable import LuxoClient

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

final class CodegenTests: XCTestCase {
    func testSchemaUsesIntrospectionIDsAndReturnFields() throws {
        let payload = LuxoModel(
            name: "Payload",
            fields: [
                LuxoField(
                    id: 4,
                    name: "data",
                    type: "Bytes",
                    typeName: nil,
                    nullable: false,
                    isList: false,
                    relation: false
                )
            ]
        )
        let api = LuxoAPI(
            id: 7,
            name: "upload",
            module: "file",
            returnType: "Payload",
            returnList: false,
            paginated: false,
            stream: false,
            params: [
                LuxoParam(
                    id: 9, name: "blob", type: "Bytes", typeName: nil, nullable: false, hasDefault: false, isList: false
                )
            ]
        )
        let schema = LuxoSchema(
            models: ["Payload": payload],
            apis: ["upload": api],
            enums: nil,
            types: nil
        )

        let codegen = try makeCodegen()
        let source = codegen.generateSchema(schema)

        XCTAssertTrue(source.contains("fieldID: 9"))
        XCTAssertTrue(source.contains("\"data\": .init(fieldID: 4)"))
        XCTAssertTrue(source.contains("fields: LUXO_SELECTION_FIELDS_Payload"))
        XCTAssertFalse(source.contains("LUXO_SELECTION_TYPES[\"Payload\"]!"))
    }

    func testClientDecodesRawScalarWithoutTLVFieldPrefix() throws {
        let api = LuxoAPI(
            id: 1,
            name: "countUsers",
            module: "user",
            returnType: "Int",
            returnList: false,
            paginated: false,
            stream: false,
            params: nil
        )
        let schema = LuxoSchema(
            models: [:],
            apis: ["countUsers": api],
            enums: nil,
            types: nil
        )

        let codegen = try makeCodegen()
        let source = codegen.generateClient(schema)

        XCTAssertTrue(source.contains("return Int(decoder.readSvarint())"))
        XCTAssertFalse(source.contains("decoder.nextField()"))
    }

    func testClientUsesColumnarAndPaginatedStructuredDecoders() throws {
        let payload = LuxoModel(
            name: "Payload",
            fields: [
                LuxoField(
                    id: 1, name: "id", type: "Int", typeName: nil, nullable: false, isList: false, relation: false),
                LuxoField(
                    id: 2, name: "metadata", type: "JSON", typeName: nil, nullable: false, isList: false,
                    relation: false),
            ]
        )
        let list = LuxoAPI(
            id: 2, name: "listPayloads", module: "file", returnType: "Payload", returnList: true, paginated: false,
            stream: false, params: nil)
        let page = LuxoAPI(
            id: 3, name: "listPayloadPage", module: "file", returnType: "Payload", returnList: true, paginated: true,
            stream: false, params: nil)
        let schema = LuxoSchema(
            models: ["Payload": payload], apis: ["listPayloads": list, "listPayloadPage": page], enums: nil, types: nil)
        let codegen = try makeCodegen()

        let decoders = codegen.generateDecoders(schema)
        let client = codegen.generateClient(schema)

        XCTAssertTrue(decoders.contains("decodeColumnarPayload(_ data: Data) throws -> [Payload]"))
        XCTAssertTrue(decoders.contains("decodePaginatedPayload(_ data: Data) throws -> Page<Payload>"))
        XCTAssertTrue(decoders.contains("readColumnBytes()"))
        XCTAssertTrue(client.contains("return try decodeColumnarPayload(result)"))
        XCTAssertTrue(client.contains("return try decodePaginatedPayload(result)"))
        XCTAssertTrue(client.contains("async throws -> Page<Payload>"))
        XCTAssertTrue(client.contains("filters: [LuxoFilter]? = nil, sorters: [LuxoSorter]? = nil"))
        XCTAssertTrue(client.contains("callParams[\"$filters\"] = .array(filters.map(\\.transportValue))"))
        XCTAssertTrue(client.contains("callParams[\"$sorters\"] = .array(sorters.map(\\.transportValue))"))
    }

    func testClientKeepsStructuredParamsStronglyTypedAndJSONEncodesThem() throws {
        let input = LuxoTypeDecl(
            name: "CreateInput",
            fields: [
                LuxoField(
                    id: 1, name: "name", type: "String", typeName: nil, nullable: false, isList: false, relation: false)
            ]
        )
        let api = LuxoAPI(
            id: 4,
            name: "createPayload",
            module: "file",
            returnType: "Payload",
            returnList: false,
            paginated: false,
            stream: false,
            params: [
                LuxoParam(
                    id: 1, name: "input", type: "JSON", typeName: "CreateInput", nullable: false, hasDefault: false,
                    isList: false)
            ]
        )
        let payload = LuxoModel(name: "Payload", fields: [])
        let schema = LuxoSchema(
            models: ["Payload": payload], apis: ["createPayload": api], enums: nil, types: ["CreateInput": input])
        let source = try makeCodegen().generateClient(schema)

        XCTAssertTrue(source.contains("input: CreateInput"))
        XCTAssertTrue(source.contains("try LuxoValue.encode(input)"))
        XCTAssertTrue(source.contains("input: CreateInput, select: String? = nil"))
        XCTAssertTrue(source.contains("callParams[\"$select\"] = .string(select)"))
    }

    func testClientDistinguishesRequiredNullFromAbsentPatchValue() throws {
        let api = LuxoAPI(
            id: 5,
            name: "updatePayload",
            module: "file",
            returnType: "Payload",
            returnList: false,
            paginated: false,
            stream: false,
            params: [
                LuxoParam(
                    id: 1, name: "id", type: "Int", typeName: nil, nullable: false, hasDefault: false, isList: false),
                LuxoParam(
                    id: 2, name: "note", type: "String", typeName: nil, nullable: true, hasDefault: false, isList: false
                ),
                LuxoParam(
                    id: 3, name: "caption", type: "String", typeName: nil, nullable: true, hasDefault: true,
                    isList: false),
            ]
        )
        let schema = LuxoSchema(models: [:], apis: ["updatePayload": api], enums: nil, types: nil)
        let source = try makeCodegen().generateClient(schema)

        XCTAssertTrue(source.contains("note: String?"))
        XCTAssertFalse(source.contains("note: String? = nil"))
        XCTAssertTrue(source.contains("caption: LuxoOptional<String> = .absent"))
        XCTAssertTrue(source.contains("case .present(let value):"))
        XCTAssertTrue(source.contains("callParams[\"caption\"] = try LuxoValue.encode(value)"))
        XCTAssertTrue(source.contains("callParams[\"caption\"] = .null"))
    }

    func testClientGeneratesTypedStreamSubscription() throws {
        let event = LuxoTypeDecl(
            name: "OrderEvent",
            fields: [
                LuxoField(
                    id: 1, name: "id", type: "Int", typeName: nil, nullable: false, isList: false, relation: false)
            ]
        )
        let api = LuxoAPI(
            id: 6,
            name: "watchOrders",
            module: "order",
            returnType: "OrderEvent",
            returnList: false,
            paginated: false,
            stream: true,
            params: [
                LuxoParam(
                    id: 1, name: "status", type: "String", typeName: nil, nullable: false, hasDefault: false,
                    isList: false)
            ]
        )
        let schema = LuxoSchema(models: [:], apis: ["watchOrders": api], enums: nil, types: ["OrderEvent": event])
        let source = try makeCodegen().generateClient(schema)

        XCTAssertTrue(
            source.contains(
                "public func subscribeWatchOrders(status: String, select: String? = nil, handler: @escaping @Sendable (OrderEvent) -> Void) async throws -> () -> Void"
            ))
        XCTAssertTrue(source.contains("try await transport.subscribe(\"watchOrders\", params: callParams)"))
        XCTAssertTrue(source.contains("guard let decoded = try? decodeOrderEvent(&decoder) else { return }"))
        XCTAssertFalse(source.contains("public func watchOrders("))
    }

    func testCodegenRejectsInvalidEndpoint() {
        XCTAssertThrowsError(try LuxoCodegen(endpoint: "not a URL", introspectionKey: "test"))
        XCTAssertThrowsError(try LuxoCodegen(endpoint: "ws://example.com", introspectionKey: "test"))
    }

    func testGenerateFetchesSchemaAndWritesCompletePackageFiles() async throws {
        let schema = LuxoSchema(
            models: [
                "User": LuxoModel(
                    name: "User",
                    fields: [
                        LuxoField(
                            id: 1,
                            name: "id",
                            type: "Int",
                            typeName: nil,
                            nullable: false,
                            isList: false,
                            relation: false
                        )
                    ])
            ],
            apis: [
                "getUser": LuxoAPI(
                    id: 1,
                    name: "getUser",
                    module: "user",
                    returnType: "User",
                    returnList: false,
                    paginated: false,
                    stream: false,
                    params: nil
                )
            ],
            enums: nil,
            types: nil
        )
        let payload = try JSONEncoder().encode(schema)
        let codegen = try LuxoCodegen(
            endpoint: "https://example.com/luvia",
            introspectionKey: "secret"
        ) { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Introspection-Key"), "secret")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(
                try XCTUnwrap(request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
                    .queryItems?.first?.name, "$schema")
            XCTAssertNil(request.httpBody)
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: "HTTP/2",
                    headerFields: nil
                ))
            return (payload, response)
        }
        let output = ".tmp/codegen-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: ".tmp", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: output) }

        try await codegen.generate(outputDir: output)

        for file in ["Models.swift", "Decoders.swift", "Schema.swift", "Client.swift"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: "\(output)/\(file)"))
        }
        let models = try String(contentsOfFile: "\(output)/Models.swift", encoding: .utf8)
        XCTAssertTrue(models.contains("public let id: Selected<Int>"))
    }

    func testGenerateRejectsHTTPFailureBeforeWritingFiles() async throws {
        let output = ".tmp/codegen-http-failure-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: output) }
        let codegen = try LuxoCodegen(
            endpoint: "https://example.com/luvia",
            introspectionKey: "secret"
        ) { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 503,
                    httpVersion: "HTTP/2",
                    headerFields: nil
                ))
            return (Data(), response)
        }

        do {
            try await codegen.generate(outputDir: output)
            XCTFail("expected introspection failure")
        } catch let error as LuxoError {
            XCTAssertEqual(error.code, 503)
            XCTAssertEqual(error.name, "IntrospectionError")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output))
    }

    func testGeneratedDecodersPropagateMalformedPayloadsWithoutCrashing() throws {
        let status = LuxoEnum(name: "Status", values: ["OPEN", "CLOSED"])
        let child = LuxoTypeDecl(
            name: "Child",
            fields: [field(1, "name", "String")]
        )
        let record = LuxoModel(
            name: "Record",
            fields: [
                field(1, "status", "Enum", typeName: "Status"),
                field(2, "child", "JSON", typeName: "Child", relation: true),
            ]
        )
        let schema = LuxoSchema(
            models: ["Record": record],
            apis: [:],
            enums: ["Status": status],
            types: ["Child": child]
        )

        let source = try makeCodegen().generateDecoders(schema)

        XCTAssertTrue(source.contains("func decodeRecord(_ decoder: inout Decoder) throws -> Record"))
        XCTAssertTrue(source.contains("throw LuxoError"))
        XCTAssertFalse(source.contains("fatalError"))
        XCTAssertFalse(source.contains("rawValue: decoder.readString())!"))
    }

    func testModelsSeparateStrictInputsFromSelectedOutputs() throws {
        let profile = LuxoTypeDecl(
            name: "Profile",
            usage: .unused,
            fields: [
                field(1, "name", "String"),
                field(2, "bio", "String", nullable: true),
            ]
        )
        let api = LuxoAPI(
            id: 1,
            name: "updateProfile",
            module: "profile",
            returnType: "Profile",
            returnList: false,
            paginated: false,
            stream: false,
            params: [
                LuxoParam(
                    id: 1, name: "profile", type: "Model", typeName: "Profile", nullable: false, hasDefault: false,
                    isList: false)
            ]
        )
        let schema = LuxoSchema(models: [:], apis: ["updateProfile": api], enums: nil, types: ["Profile": profile])
        let codegen = try makeCodegen()

        let models = codegen.generateModels(schema)
        let client = codegen.generateClient(schema)

        XCTAssertTrue(models.contains("public let name: Selected<String>"))
        XCTAssertTrue(models.contains("public let bio: Selected<String?>"))
        XCTAssertTrue(models.contains("public struct ProfileInput: Codable, Sendable"))
        XCTAssertTrue(models.contains("public let name: String"))
        XCTAssertTrue(models.contains("public let bio: String?"))
        XCTAssertTrue(client.contains("profile: ProfileInput"))
        XCTAssertTrue(client.contains("async throws -> Profile"))
    }

    private func field(
        _ id: Int,
        _ name: String,
        _ type: String,
        typeName: String? = nil,
        nullable: Bool = false,
        isList: Bool = false,
        relation: Bool = false
    ) -> LuxoField {
        LuxoField(
            id: id,
            name: name,
            type: type,
            typeName: typeName,
            nullable: nullable,
            isList: isList,
            relation: relation
        )
    }

    private func makeCodegen() throws -> LuxoCodegen {
        try LuxoCodegen(endpoint: "http://localhost", introspectionKey: "test")
    }
}
