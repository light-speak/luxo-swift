import XCTest
@testable import LuxoClient

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

final class CodegenTests: XCTestCase {
    func testNullableRootResponsesPreserveSchemaAndGeneratedTypes() throws {
        let generator = try makeCodegen()
        for (name, type) in [("Int", "Int"), ("DateTime", "String"), ("Snapshot", "Snapshot")] {
            for list in [false, true] {
                for stream in [false, true] {
                    let payload = Data(
                        """
                        {"models":{},"types":{"Snapshot":{"name":"Snapshot","usage":"output","fields":[
                        {"id":1,"name":"value","type":"Int"}]}},"apis":{"read":{"id":1,"name":"read",
                        "module":"test","returnType":"\(name)","returnNullable":true,
                        "returnList":\(list),"stream":\(stream)}}}
                        """.utf8)
                    let schema = try JSONDecoder().decode(LuxoSchema.self, from: payload)
                    let encoded = String(decoding: try JSONEncoder().encode(schema), as: UTF8.self)
                    XCTAssertTrue(encoded.contains("\"returnNullable\":true"))
                    let source = generator.generateClient(schema)
                    let result = (list ? "[\(type)]" : type) + "?"
                    XCTAssertTrue(source.contains("throws -> \(result) {"), source)
                    XCTAssertTrue(source.contains("if try isNullRoot(result.data) { return nil }"))
                    XCTAssertTrue(source.contains("offset: 1"))
                    XCTAssertFalse(source.contains("dropFirst"))
                    if stream { XCTAssertTrue(source.contains("@Sendable (\(result)) -> Void")) }
                }
            }
        }
    }

    func testInternalScopeDoesNotDependOnAPIPrefix() throws {
        let payload = Data(
            #"{"models":{},"apis":{"ping":{"id":1,"name":"ping","module":"test","returnType":"Int","internal":false},"privateOperation":{"id":2,"name":"privateOperation","module":"test","returnType":"Int","internal":true}}}"#
                .utf8)
        let schema = try JSONDecoder().decode(LuxoSchema.self, from: payload)
        let generator = try makeCodegen()
        for source in [generator.generateClient(schema), generator.generateSchema(schema)] {
            XCTAssertTrue(source.contains("ping"))
            XCTAssertFalse(source.contains("privateOperation"))
        }
    }
    func testInternalRPCsAreExcludedFromClientAndTransportSchema() throws {
        let publicAPI = LuxoAPI(
            id: 1, name: "listItems", module: "test", returnType: "Int", returnList: true,
            paginated: false, stream: false, params: [])
        let internalAPI = LuxoAPI(
            id: 2, name: "svc:batchLoad:Item", module: "test", returnType: "Int", returnList: true,
            paginated: false, stream: false, params: [], isInternal: true)
        let schema = LuxoSchema(
            models: [:], apis: [publicAPI.name: publicAPI, internalAPI.name: internalAPI],
            enums: nil, types: nil)
        let generator = try makeCodegen()
        let client = generator.generateClient(schema)
        let transport = generator.generateSchema(schema)
        XCTAssertTrue(client.contains("func listItems("))
        XCTAssertTrue(transport.contains("listItems"))
        XCTAssertFalse(client.contains(internalAPI.name))
        XCTAssertFalse(transport.contains(internalAPI.name))
    }

    func testOutputModelsValidateSelectedStateWithoutRescanningJSONKeys() throws {
        let schema = LuxoSchema(
            models: [
                "Item": LuxoModel(
                    name: "Item", usage: .output,
                    fields: [
                        field(1, "decoder", "Int"), field(2, "container", "String", nullable: true),
                        LuxoField(
                            id: 3, name: "implicit", type: "Boolean", typeName: nil, nullable: nil, isList: nil,
                            relation: nil),
                    ])
            ], apis: [:], enums: nil, types: nil)
        let source = try makeCodegen().generateModels(schema)
        XCTAssertTrue(source.contains("public init(from decoder: Swift.Decoder) throws"))
        XCTAssertTrue(
            source.contains(
                "self.decoder = try container.decode(Selected<Int>.self, forKey: .decoder, selected: &hasSelectedField)"
            ))
        XCTAssertTrue(source.contains("if hasSelectedField { return }"))
        XCTAssertTrue(source.contains("Selected<Bool>.self, forKey: .implicit"))
        XCTAssertTrue(source.contains("LuxoClient.LuxoJSONDecoder.validateEmptyModelProjection(from: decoder)"))
        XCTAssertFalse(source.contains("allKeys"))
        XCTAssertFalse(source.contains(".isSelected"))
        XCTAssertFalse(source.contains("JSONSerialization"))
    }

    func testEmptyOutputStillRequiresAnObjectAndRejectsListItems() throws {
        let schema = LuxoSchema(
            models: ["Empty": LuxoModel(name: "Empty", usage: .output, fields: [])],
            apis: [:], enums: nil, types: nil)
        let source = try makeCodegen().generateModels(schema)
        XCTAssertTrue(source.contains("private enum CodingKeys: CodingKey {}"))
        XCTAssertTrue(source.contains("_ = try decoder.container(keyedBy: CodingKeys.self)"))
        XCTAssertTrue(source.contains("LuxoClient.LuxoJSONDecoder.validateEmptyModelProjection(from: decoder)"))
        XCTAssertTrue(
            try makeCodegen().generateSchema(schema).contains(
                "LUXO_SELECTION_FIELDS_Empty: [String: APISchema.SelectionFieldSchema] = [:]"))
        XCTAssertTrue(try makeCodegen().generateDecoders(schema).contains("for _ in 0..<decoder.count"))
    }

    func testClientDecodesEachPayloadUsingItsTransportMode() throws {
        let call = LuxoAPI(
            id: 1, name: "read", module: "test", returnType: "Int", returnList: false,
            paginated: false, stream: false, params: [])
        let stream = LuxoAPI(
            id: 2, name: "watch", module: "test", returnType: "Int", returnList: false,
            paginated: false, stream: true, params: [])
        let source = try makeCodegen().generateClient(
            LuxoSchema(models: [:], apis: ["read": call, "watch": stream], enums: nil, types: nil))
        XCTAssertFalse(source.contains("binaryEnabled"))
        XCTAssertFalse(source.contains("modeLock"))
        XCTAssertFalse(source.contains("@unchecked Sendable"))
        XCTAssertFalse(source.contains("[weak self]"))
        XCTAssertTrue(source.contains("result.mode == .binary"))
        XCTAssertTrue(source.contains("decoder: Self.decode_watch"))
        XCTAssertTrue(source.contains("decodeLuxoResponse(result.data)"))
        XCTAssertEqual(source.components(separatedBy: "result.mode == .binary").count - 1, 2)
    }

    func testClientRegistersSchemaAtInitializationForBothModes() throws {
        let schema = LuxoSchema(models: [:], apis: [:], enums: nil, types: nil)
        let source = try makeCodegen().generateClient(schema)
        let start = try XCTUnwrap(source.range(of: "public init(transport: Transport) throws {"))
        let end = try XCTUnwrap(source.range(of: "    }", range: start.upperBound..<source.endIndex))
        XCTAssertTrue(source[start.upperBound..<end.lowerBound].contains("try transport.setSchema(LUXO_SCHEMA)"))
        XCTAssertEqual(source.components(separatedBy: "transport.setSchema(LUXO_SCHEMA)").count - 1, 1)
    }

    func testScalarListsOnlyUseTryForThrowingReaders() throws {
        for type in ["Int", "Duration", "Float", "String", "Boolean", "DateTime", "UUID", "Decimal", "Bytes", "JSON"] {
            let api = LuxoAPI(
                id: 1, name: "values", module: "test", returnType: type, returnList: true,
                paginated: false, stream: false, params: [])
            let schema = LuxoSchema(models: [:], apis: ["values": api], enums: nil, types: nil)
            let source = try makeCodegen().generateClient(schema)
            let prefix =
                type == "JSON"
                ? "decoder in try decoder.readArray"
                : type == "DateTime" ? "decoder in decoder.readDateTimeArray" : "decoder in decoder.readArray"
            XCTAssertTrue(source.contains(prefix), "unexpected generated array read for \(type)")
        }
    }

    func testScalarRepliesShareCheckedDecodingAcrossCallsAndStreams() throws {
        for type in [
            "Int", "Duration", "Float", "String", "Boolean", "DateTime", "UUID", "Decimal", "Bytes", "JSON", "Status",
        ] {
            for list in [false, true] {
                for stream in [false, true] {
                    let api = LuxoAPI(
                        id: 1, name: "values", module: "test", returnType: type, returnList: list,
                        paginated: false, stream: stream, params: [])
                    let schema = LuxoSchema(
                        models: [:], apis: ["values": api],
                        enums: ["Status": LuxoEnum(name: "Status", values: ["OPEN", "CLOSED"])], types: nil)
                    let source = try makeCodegen().generateClient(schema)
                    if !stream {
                        XCTAssertTrue(
                            source.contains("transport.call(\"values\", request: _valuesRequest(values: .init()))"))
                    }
                    XCTAssertTrue(source.contains("try decodeLuxoResponse(result"))
                    XCTAssertFalse(source.contains("try? decodeLuxoResponse"))
                    if type == "Status" {
                        XCTAssertTrue(
                            source.contains("Status(rawValue: decoder.readString())")
                        )
                    }
                    if stream {
                        XCTAssertTrue(
                            source.contains(
                                "decoder: Self.decode_values, request: _valuesRequest(values: .init()), observer: observer, handler: handler"
                            ))
                    }
                }
            }
        }
    }

    func testGeneratedResponseBoundaryRejectsDecoderErrorsAndTrailingData() throws {
        let source = try makeCodegen().generateDecoders(LuxoSchema(models: [:], apis: [:], enums: nil, types: nil))
        XCTAssertTrue(source.contains("func decodeLuxoResponse<Value>"))
        XCTAssertTrue(source.contains("if let error = decoder.error"))
        XCTAssertTrue(source.contains("guard decoder.isAtEnd else"))
        XCTAssertTrue(source.contains("if error.name == \"DecodeError\" { throw error }"))
        XCTAssertTrue(source.contains("message: decoder.error ?? error.message, name: \"DecodeError\""))
    }

    func testNestedPayloadsAndScalarArrayCellsUseCompleteBoundaries() throws {
        let child = LuxoTypeDecl(name: "Child", fields: [field(1, "id", "Int")])
        let parent = LuxoModel(
            name: "Parent", usage: .output,
            fields: [
                field(1, "child", "Model", typeName: "Child"),
                field(2, "children", "Model", typeName: "Child", isList: true),
                field(3, "values", "Int", isList: true),
                field(4, "optional", "Model", typeName: "Child", nullable: true),
            ])
        let schema = LuxoSchema(models: ["Parent": parent], apis: [:], enums: nil, types: ["Child": child])
        let source = try makeCodegen().generateDecoders(schema)
        XCTAssertTrue(source.contains("decodeLuxoResponse(decoder.readBytes())"))
        XCTAssertTrue(source.contains("decodeColumnarChild(decoder.readBytes())"))
        XCTAssertTrue(source.contains("decodeLuxoResponse(d.readBytes())"))
        XCTAssertTrue(source.contains("decodeLuxoResponse(data[i])"))
        XCTAssertTrue(source.contains("guard decoder.isAtEnd else"))
        XCTAssertFalse(source.contains("var d = Decoder(data[i]); return .value"))
    }

    func testClientConstructsTypedScalarAndListParametersDirectly() throws {
        let cases = [
            ("Int", "LuxoValue(value)"), ("Duration", "LuxoValue(value)"),
            ("String", "LuxoValue(value)"), ("Boolean", "LuxoValue(value)"),
            ("DateTime", "LuxoValue(value)"), ("UUID", "LuxoValue(value)"),
            ("Decimal", "LuxoValue(value)"), ("Bytes", "LuxoValue(value)"),
            ("JSON", "LuxoValue(value)"), ("Float", "try LuxoValue(finiteFloat: value)"),
            ("Enum", ".string(value.rawValue)"),
        ]
        for (type, expression) in cases {
            for list in [false, true] {
                let param = LuxoParam(
                    id: 1, name: "value", type: type, typeName: type == "Enum" ? "Status" : nil,
                    nullable: false, hasDefault: false, isList: list)
                let api = LuxoAPI(
                    id: 1, name: "echo", module: "test", returnType: "Void", returnList: false,
                    paginated: false, stream: false, params: [param])
                let schema = LuxoSchema(
                    models: [:], apis: ["echo": api],
                    enums: ["Status": LuxoEnum(name: "Status", values: ["OPEN"])], types: nil)
                let source = try makeCodegen().generateClient(schema)
                let expected =
                    list
                    ? ".array(value.map { \(expression.replacingOccurrences(of: "value", with: "$0")) })"
                    : expression
                XCTAssertFalse(source.contains("LuxoValue.encode("), type)
                XCTAssertTrue(source.contains(expected), type)
            }
        }
    }

    func testInputJSONProjectionPreservesNestedAndNullableShape() throws {
        let child = LuxoTypeDecl(
            name: "Child", usage: .input,
            fields: [
                LuxoField(id: 1, name: "id", type: "Int", typeName: nil, nullable: nil, isList: nil, relation: nil)
            ])
        let input = LuxoTypeDecl(
            name: "Input", usage: .input,
            fields: [
                field(1, "child", "Model", typeName: "Child"),
                field(2, "children", "Model", typeName: "Child", isList: true),
                field(3, "note", "String", nullable: true),
            ])
        let schema = LuxoSchema(models: [:], apis: [:], enums: nil, types: ["Input": input, "Child": child])
        let source = try makeCodegen().generateModels(schema)
        for expected in [
            "public func luxoJSONValue() throws -> LuxoValue",
            "values[\"child\"] = .structured(self.child)",
            "values[\"children\"] = .array(self.children.map { .structured($0) })",
            "if let value = self.note { values[\"note\"] = LuxoValue(value) }",
        ] {
            XCTAssertTrue(source.contains(expected), expected)
        }
        XCTAssertFalse(source.contains("JSONEncoder"))
    }

    func testInputProjectionResolvesNamedTypesAndEmptyInputs() throws {
        let role = LuxoEnum(name: "Role", values: ["OPEN"])
        let model = LuxoModel(name: "ModelInput", usage: .input, fields: [])
        let empty = LuxoTypeDecl(name: "EmptyInput", usage: .input, fields: [])
        let outer = LuxoTypeDecl(
            name: "Outer", usage: .input,
            fields: [
                field(1, "role", "Role"), field(2, "model", "ModelInput"),
                field(3, "values", "EmptyInput", isList: true),
            ])
        let schema = LuxoSchema(
            models: ["ModelInput": model], apis: [:], enums: ["Role": role],
            types: ["EmptyInput": empty, "Outer": outer])
        let source = try makeCodegen().generateModels(schema)
        for expected in [
            "return .object([:])", "values[\"role\"] = .string(self.role.rawValue)",
            "values[\"model\"] = .structured(self.model)",
            "values[\"values\"] = .array(self.values.map { .structured($0) })",
        ] {
            XCTAssertTrue(source.contains(expected), expected)
        }
    }

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
        XCTAssertTrue(
            source.contains("\"data\": .init(fieldID: 4, type: \"Bytes\", isList: false, nullable: false)")
        )
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

        XCTAssertTrue(source.contains("decodeLuxoResponse(result.data) { decoder in Int(decoder.readSvarint()) }"))
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
        XCTAssertTrue(client.contains("return try decodeColumnarPayload(result.data)"))
        XCTAssertTrue(client.contains("return try decodePaginatedPayload(result.data)"))
        XCTAssertTrue(client.contains("async throws -> Page<Payload>"))
        XCTAssertTrue(client.contains("filters: [LuxoFilter]? = nil, sorters: [LuxoSorter]? = nil"))
        XCTAssertTrue(client.contains("callParams[\"$filters\"] = .array(filters.map(\\.transportValue))"))
        XCTAssertTrue(client.contains("callParams[\"$sorters\"] = .array(sorters.map(\\.transportValue))"))
    }

    func testClientKeepsStructuredParamsStronglyTypedAndUsesNativeBinaryEncoding() throws {
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
                    id: 1, name: "input", type: "Model", typeName: "CreateInput", nullable: false, hasDefault: false,
                    isList: false)
            ]
        )
        let payload = LuxoModel(name: "Payload", fields: [])
        let schema = LuxoSchema(
            models: ["Payload": payload], apis: ["createPayload": api], enums: nil, types: ["CreateInput": input])
        let codegen = try makeCodegen()
        let source = codegen.generateClient(schema)
        let models = codegen.generateModels(schema)
        let generatedSchema = codegen.generateSchema(schema)

        XCTAssertTrue(source.contains("input: CreateInput"))
        XCTAssertTrue(source.contains("callParams[\"input\"] = .structured(input)"))
        XCTAssertTrue(source.contains("input: CreateInput, select: String? = nil"))
        XCTAssertTrue(source.contains("callParams[\"$select\"] = .string(select)"))
        XCTAssertTrue(models.contains("public struct CreateInput: Codable, Sendable, LuxoBinaryEncodable"))
        XCTAssertTrue(models.contains("public func writeLuxo(to encoder: inout Encoder) throws"))
        XCTAssertTrue(models.contains("encoder.writeString(name)"))
        XCTAssertTrue(
            generatedSchema.contains(
                "type: \"Model\", typeName: \"CreateInput\", isList: false, nullable: false"
            )
        )
    }

    func testStructuredInputGeneratesNestedListsNullableValuesAndArenaLength() throws {
        let role = LuxoEnum(name: "Role", values: ["ADMIN", "USER"])
        let child = LuxoTypeDecl(
            name: "ChildInput",
            fields: [field(1, "label", "String")]
        )
        let input = LuxoTypeDecl(
            name: "CreateInput",
            fields: [
                field(1, "name", "String"),
                field(2, "role", "Enum", typeName: "Role"),
                field(3, "child", "Model", typeName: "ChildInput"),
                field(4, "tags", "String", isList: true),
                field(5, "note", "String", nullable: true),
            ]
        )
        let api = LuxoAPI(
            id: 1, name: "create", module: "test", returnType: "Boolean", returnList: false, paginated: false,
            stream: false,
            params: [
                LuxoParam(
                    id: 1, name: "input", type: "Model", typeName: "CreateInput", nullable: false,
                    hasDefault: false, isList: false)
            ]
        )
        let schema = LuxoSchema(
            models: [:], apis: ["create": api], enums: ["Role": role],
            types: ["CreateInput": input, "ChildInput": child]
        )

        let source = try makeCodegen().generateModels(schema)
        for expected in [
            "encoder.writeVarint(UInt64(name.utf8.count + role.rawValue.utf8.count + (note.map { $0.utf8.count } ?? 0)))",
            "encoder.writeString(role.rawValue)",
            "try child.writeLuxo(to: &encoder)",
            "encoder.writeArrayHeader(tags.count)",
            "for item in tags",
            "encoder.writeBool(false)",
            "encoder.writeBool(true)",
        ] {
            XCTAssertTrue(source.contains(expected), "missing \(expected):\n\(source)")
        }
    }

    func testStructuredParamListsAndOptionalStatesStayNative() throws {
        let input = LuxoTypeDecl(name: "Input", fields: [field(1, "name", "String")])
        let api = LuxoAPI(
            id: 1, name: "write", module: "test", returnType: "Boolean", returnList: false, paginated: false,
            stream: false,
            params: [
                LuxoParam(
                    id: 1, name: "inputs", type: "Model", typeName: "Input", nullable: false, hasDefault: false,
                    isList: true),
                LuxoParam(
                    id: 2, name: "optional", type: "Model", typeName: "Input", nullable: true, hasDefault: false,
                    isList: false),
                LuxoParam(
                    id: 3, name: "defaulted", type: "Model", typeName: "Input", nullable: false, hasDefault: true,
                    isList: false),
                LuxoParam(
                    id: 4, name: "patch", type: "Model", typeName: "Input", nullable: true, hasDefault: true,
                    isList: false),
            ]
        )
        let schema = LuxoSchema(models: [:], apis: ["write": api], enums: nil, types: ["Input": input])
        let source = try makeCodegen().generateClient(schema)

        for expected in [
            "callParams[\"inputs\"] = .array(inputs.map { .structured($0) })",
            "if let optional { callParams[\"optional\"] = .structured(optional) }",
            "if let defaulted { callParams[\"defaulted\"] = .structured(defaulted) }",
            "case .present(let value):",
            "if let value { callParams[\"patch\"] = .structured(value) }",
        ] {
            XCTAssertTrue(source.contains(expected), "missing \(expected):\n\(source)")
        }
    }

    func testUnsupportedStructuredFieldGeneratesExplicitError() throws {
        let input = LuxoTypeDecl(name: "Input", fields: [field(1, "value", "Unsupported")])
        let api = LuxoAPI(
            id: 1, name: "write", module: "test", returnType: "Boolean", returnList: false, paginated: false,
            stream: false,
            params: [
                LuxoParam(
                    id: 1, name: "input", type: "Model", typeName: "Input", nullable: false, hasDefault: false,
                    isList: false)
            ]
        )
        let schema = LuxoSchema(models: [:], apis: ["write": api], enums: nil, types: ["Input": input])
        let source = try makeCodegen().generateModels(schema)

        XCTAssertTrue(
            source.contains("throw LuxoError(code: 0, message: \"unsupported binary field type: Unsupported\""))
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
        XCTAssertTrue(source.contains("callParams[\"caption\"] = LuxoValue(value)"))
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
                "public func subscribeWatchOrders(status: String, select: String? = nil, observer: StreamObserver? = nil, handler: @escaping @Sendable (OrderEvent) -> Void) async throws -> (@Sendable () -> Void)"
            ))
        XCTAssertTrue(
            source.contains(
                "try await transport.subscribe(\"watchOrders\", decoder: Self.decode_watchOrders, request: _watchOrdersRequest(values: .init(status: status, select: select)), observer: observer, handler: handler)"
            ))
        XCTAssertTrue(
            source.contains("private static func decode_watchOrders(_ result: TransportPayload) throws -> OrderEvent"))
        XCTAssertTrue(
            source.contains("try decodeLuxoResponse(result.data) { decoder in try decodeOrderEvent(&decoder) }"))
        XCTAssertFalse(source.contains("guard let decoded = try?"))
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

        for file in ["Models.swift", "Decoders.swift", "Schema.swift", "Client.swift", "LuxoSelection.json"] {
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

    func testNullableArraysKeepOuterMarkersSeparateFromColumnCells() throws {
        let model = LuxoModel(
            name: "ArrayRecord",
            fields: [
                field(1, "values", "Int", nullable: true, isList: true),
                field(2, "metadata", "JSON", nullable: true, isList: true),
                field(3, "statuses", "Enum", typeName: "Status", nullable: true, isList: true),
                field(4, "children", "Model", typeName: "ArrayRecord", nullable: true, isList: true),
            ])
        let schema = LuxoSchema(
            models: ["ArrayRecord": model], apis: [:],
            enums: ["Status": LuxoEnum(name: "Status", values: ["OPEN"])], types: nil)
        let source = try makeCodegen().generateDecoders(schema)
        XCTAssertTrue(source.contains("Selected<[Int]?> = .unselected"))
        XCTAssertTrue(
            source.contains(".value(decoder.readBool() ? decoder.readArray { d in Int(d.readSvarint()) } : nil)"))
        XCTAssertTrue(source.contains("var _values: [Data?]?\n"))
        XCTAssertTrue(source.contains("_values = decoder.readColumnBytesPtr()"))
        XCTAssertTrue(
            source.contains("values[i].map { data in try decodeLuxoResponse(data) { decoder in decoder.readArray"))
        XCTAssertFalse(source.contains("decodeLuxoResponse(data) { decoder in decoder.readBool()"))
        XCTAssertTrue(source.contains("values[i].map { try decodeColumnarArrayRecord($0) }"))
    }

    private func makeCodegen() throws -> LuxoCodegen {
        try LuxoCodegen(endpoint: "http://localhost", introspectionKey: "test")
    }
}
