import XCTest
@testable import LuxoClient

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

final class CodegenEnumTests: XCTestCase {
    func testEmptyEnumGenerationPreservesUnknownOnlyValues() async throws {
        let artifact = ProcessInfo.processInfo.environment["LUXO_EMPTY_ENUM_OUTPUT"]
        let output = artifact ?? ".tmp/codegen-empty-enum-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        defer { if artifact == nil { try? FileManager.default.removeItem(atPath: output) } }
        let body =
            #"{"models":{},"apis":{"read":{"id":1,"name":"read","module":"test","returnType":"Empty","params":[{"id":1,"name":"value","type":"Enum","typeName":"Empty"}]}},"enums":{"Empty":{"name":"Empty","values":[]}}}"#
        let generator = try LuxoCodegen(endpoint: "https://example.com/luvia", introspectionKey: "test") { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: 200, httpVersion: "HTTP/2", headerFields: nil))
            return (Data(body.utf8), response)
        }
        try await generator.generate(outputDir: output)
        let source = try String(contentsOfFile: "\(output)/Models.swift", encoding: .utf8)
        XCTAssertTrue(source.contains("public static var knownCases: [Self] { [] }"))
        XCTAssertTrue(source.contains("case unknown(String)"))
        XCTAssertFalse(source.contains("case :"))
    }
    func testEmptySchemaNamesPreserveExistingFiles() async throws {
        let field = #"{"id":1,"name":"value","type":"Int"}"#
        let invalid = #"{"id":1,"name":"","type":"Int"}"#
        let bodies = [
            #"{"models":{"":{"name":"","fields":[\#(field)]}},"apis":{}}"#,
            #"{"models":{},"types":{"":{"name":"","fields":[\#(field)]}},"apis":{}}"#,
            #"{"models":{},"enums":{"":{"name":"","values":["READY"]}},"apis":{}}"#,
            #"{"models":{},"apis":{"":{"id":1,"name":"","module":"test","returnType":"Int"}}}"#,
            #"{"models":{"Payload":{"name":"Payload","fields":[\#(invalid)]}},"apis":{"read":{"id":1,"name":"read","module":"test","returnType":"Payload"}}}"#,
            #"{"models":{},"apis":{"read":{"id":1,"name":"read","module":"test","returnType":"Int","params":[\#(invalid)]}}}"#,
        ]
        try await assertRejectedBeforeWriting(bodies)
    }

    func testUndeclaredMemberTypesPreserveExistingFiles() async throws {
        var bodies: [String] = []
        for target in ["models", "types", "params", "unused"] {
            for type in ["", "Missing", "Int64"] {
                for list in [false, true] {
                    let field = #"{"id":1,"name":"value","type":"\#(type)","isList":\#(list)}"#
                    if target == "params" {
                        bodies.append(
                            #"{"models":{},"apis":{"read":{"id":1,"name":"read","module":"test","returnType":"Int","params":[\#(field)]}}}"#
                        )
                    } else {
                        let directory = target == "unused" ? "types" : target
                        let models = target == "models" ? "" : #""models":{},"#
                        let usage = target == "unused" ? #", "usage":"unused""# : ""
                        bodies.append(
                            #"{\#(models)"apis":{},"\#(directory)":{"Payload":{"name":"Payload"\#(usage),"fields":[\#(field)]}}}"#
                        )
                    }
                }
            }
        }
        try await assertRejectedBeforeWriting(bodies)
    }

    func testDeclaredVoidModelUsesValueDecoderAndStandardCallbackResult() async throws {
        let artifact = ProcessInfo.processInfo.environment["LUXO_CODEGEN_COMPILE_OUTPUT"]
        let output = artifact ?? ".tmp/codegen-void-\(UUID().uuidString)"
        defer { if artifact == nil { try? FileManager.default.removeItem(atPath: output) } }
        let body =
            #"{"models":{"Void":{"name":"Void","fields":[{"id":1,"name":"id","type":"Int"}]}},"apis":{"read":{"id":1,"name":"read","module":"test","returnType":"Void"},"watch":{"id":2,"name":"watch","module":"test","returnType":"Void","stream":true}}}"#
        let generator = try LuxoCodegen(endpoint: "https://example.com/luvia", introspectionKey: "test") { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: 200, httpVersion: "HTTP/2", headerFields: nil))
            return (Data(body.utf8), response)
        }
        try await generator.generate(outputDir: output)
        let client = try String(contentsOfFile: "\(output)/Client.swift", encoding: .utf8)
        XCTAssertTrue(client.contains("decodeVoid("))
        XCTAssertTrue(client.contains("LuxoClient.SubscriptionHandler<Void>"))
        XCTAssertTrue(client.contains("() -> Swift.Void"))
        XCTAssertFalse(client.contains("return ()"))
    }

    func testUnknownEnumGenerationRetainsRawStringsAndExactMatching() throws {
        let schema = LuxoSchema(
            models: [:], apis: [:],
            enums: ["Status": LuxoEnum(name: "Status", values: ["OPEN", "K", "UNKNOWN", "unknown", "case"])],
            types: nil)
        let generator = try LuxoCodegen(endpoint: "https://example.com/luvia", introspectionKey: "test")
        let source = generator.generateModels(schema)
        XCTAssertTrue(source.contains("case unknown(String)"))
        XCTAssertTrue(source.contains("public init(rawValue: String)"))
        XCTAssertTrue(source.contains("default: self = .unknown(rawValue)"))
        XCTAssertTrue(source.contains("rawValue.utf8.elementsEqual(\"K\".utf8)"))
        XCTAssertTrue(source.contains("public static var knownCases: [Self]"))
        XCTAssertTrue(source.contains("case `case`"))
        XCTAssertFalse(source.contains("CaseIterable"))
        XCTAssertFalse(source.contains("public enum Status: String"))
    }

    func testEnumDecoderDoesNotDiscardUnknownMembers() throws {
        let generator = try LuxoCodegen(endpoint: "https://example.com/luvia", introspectionKey: "test")
        let api = LuxoAPI(
            id: 1, name: "read", module: "test", returnType: "Status",
            returnList: true, paginated: false, stream: true, params: [])
        let schema = LuxoSchema(
            models: [:], apis: ["read": api],
            enums: ["Status": LuxoEnum(name: "Status", values: ["OPEN"])], types: nil)
        XCTAssertTrue(generator.generateClient(schema).contains("Status(rawValue: decoder.readString())"))
        XCTAssertTrue(generator.generateClient(schema).contains("decodeLuxoJSONResponse([Status].self"))
        XCTAssertFalse(generator.generateDecoders(schema).contains("func decodeEnum"))
    }

    func testInvalidEnumMetadataDoesNotOverwriteGeneratedFiles() async throws {
        try await assertRejectedBeforeWriting(invalidSchemas)
    }

    func testMissingModelReferencesDoNotOverwriteGeneratedFiles() async throws {
        var bodies: [String] = []
        for target in ["models", "types", "params"] {
            for name: String? in [nil, "", "Missing"] {
                for list in [false, true] {
                    let reference = name.map { ",\"typeName\":\"\($0)\"" } ?? ""
                    let field = """
                        {"id":1,"name":"child","type":"Model","isList":\(list),"nullable":\(list)\(reference)}
                        """
                    if target == "params" {
                        bodies.append(
                            """
                            {"models":{},"apis":{"read":{"id":1,"name":"read","module":"test","returnType":"Int","params":[\(field)]}}}
                            """)
                    } else {
                        let models = target == "types" ? "\"models\":{}," : ""
                        bodies.append(
                            """
                            {\(models)"apis":{},"\(target)":{"Payload":{"name":"Payload","fields":[\(field)]}}}
                            """)
                    }
                }
            }
        }
        try await assertRejectedBeforeWriting(bodies)
    }

    private func assertRejectedBeforeWriting(_ bodies: [String]) async throws {
        let root = ".tmp/codegen-enum-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        for (index, body) in bodies.enumerated() {
            let output = "\(root)/\(index)"
            try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
            let files = [
                "Models.swift", "Decoders.swift", "Schema.swift", "Client.swift", "Queries.swift", "LuxoSelection.json",
            ]
            for name in files {
                try "existing \(name)".write(toFile: "\(output)/\(name)", atomically: true, encoding: .utf8)
            }
            let generator = try LuxoCodegen(endpoint: "https://example.com/luvia", introspectionKey: "test") {
                request in
                let response = try XCTUnwrap(
                    HTTPURLResponse(
                        url: XCTUnwrap(request.url), statusCode: 200,
                        httpVersion: "HTTP/2", headerFields: nil))
                return (Data(body.utf8), response)
            }
            do {
                try await generator.generate(outputDir: output)
                XCTFail("invalid schema accepted: \(body)")
            } catch let error as LuxoError {
                XCTAssertEqual(error.name, "SchemaError")
            }
            for name in files {
                XCTAssertEqual(try String(contentsOfFile: "\(output)/\(name)", encoding: .utf8), "existing \(name)")
            }
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: output)), Set(files))
        }
    }

    func testOmittedAPIReturnsPreserveExistingFiles() async throws {
        let bodies = [false, true].map { list in
            """
            {"models":{},"apis":{"read":{"id":1,"name":"read","module":"test","returnList":\(list)}}}
            """
        }
        try await assertRejectedBeforeWriting(bodies)
    }

    func testUndeclaredAPIReturnsPreserveExistingFiles() async throws {
        let bodies = ["Missing", "", "Enum", "Void"].flatMap { type in
            [false, true].map { list in
                """
                {"models":{},"apis":{"read":{"id":1,"name":"read","module":"test","returnType":"\(type)","returnList":\(list)}}}
                """
            }
        }
        try await assertRejectedBeforeWriting(bodies)
    }

    func testMismatchedDeclarationNamesPreserveExistingFiles() async throws {
        try await assertRejectedBeforeWriting([
            #"{"models":{"Payload":{"name":"Other","fields":[{"id":1,"name":"id","type":"Int"}]}},"apis":{}}"#,
            #"{"models":{},"types":{"Payload":{"name":"Other","fields":[{"id":1,"name":"id","type":"Int"}]}},"apis":{}}"#,
            #"{"models":{},"apis":{"read":{"id":1,"name":"other","module":"test","returnType":"Int"}}}"#,
        ])
    }

    func testDuplicateMemberNamesPreserveExistingFiles() async throws {
        var bodies: [String] = []
        for target in ["models", "types", "params"] {
            for type in ["Int", "String"] {
                let fields = """
                    [{"id":1,"name":"value","type":"Int"},{"id":2,"name":"value","type":"\(type)"}]
                    """
                if target == "params" {
                    bodies.append(
                        """
                        {"models":{},"apis":{"read":{"id":1,"name":"read","module":"test","returnType":"Int","params":\(fields)}}}
                        """)
                } else {
                    let models = target == "types" ? "\"models\":{}," : ""
                    bodies.append(
                        """
                        {\(models)"apis":{},"\(target)":{"Payload":{"name":"Payload","fields":\(fields)}}}
                        """)
                }
            }
        }
        try await assertRejectedBeforeWriting(bodies)
    }

    func testCanonicallyEquivalentMemberNamesDoNotCrashGeneration() async throws {
        try await assertRejectedBeforeWriting([
            #"{"models":{"Payload":{"name":"Payload","fields":[{"id":1,"name":"caf\u00e9","type":"Int"},{"id":2,"name":"cafe\u0301","type":"Int"}]}},"apis":{}}"#,
            #"{"models":{},"types":{"Payload":{"name":"Payload","fields":[{"id":1,"name":"caf\u00e9","type":"Int"},{"id":2,"name":"cafe\u0301","type":"Int"}]}},"apis":{}}"#,
            #"{"models":{},"apis":{"read":{"id":1,"name":"read","module":"test","returnType":"Int","params":[{"id":1,"name":"caf\u00e9","type":"Int"},{"id":2,"name":"cafe\u0301","type":"Int"}]}}}"#,
        ])
    }

    func testCrossNamespaceTypeCollisionsPreserveExistingFiles() async throws {
        let fields = #"{"Payload":{"name":"Payload","fields":[{"id":1,"name":"id","type":"Int"}]}}"#
        let enumeration = #"{"Payload":{"name":"Payload","values":["OPEN"]}}"#
        try await assertRejectedBeforeWriting([
            "{\"models\":\(fields),\"types\":\(fields),\"apis\":{}}",
            "{\"models\":\(fields),\"enums\":\(enumeration),\"apis\":{}}",
            "{\"models\":{},\"types\":\(fields),\"enums\":\(enumeration),\"apis\":{}}",
        ])
    }

    func testDeclaredRecursiveModelAndTypeReferencesGenerate() async throws {
        let body = #"""
            {"models":{"Container":{"name":"Container","fields":[
                {"id":1,"name":"node","type":"Model","typeName":"Node"}]}},
             "types":{"Node":{"name":"Node","fields":[
                {"id":1,"name":"child","type":"Model","typeName":"Node","nullable":true},
                {"id":2,"name":"parent","type":"Model","typeName":"Container","nullable":true}]}},
             "apis":{"read":{"id":1,"name":"read","module":"test","returnType":"Container"}}}
            """#
        let root = ".tmp/codegen-model-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let generator = try LuxoCodegen(endpoint: "https://example.com/luvia", introspectionKey: "test") { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: 200, httpVersion: "HTTP/2", headerFields: nil))
            return (Data(body.utf8), response)
        }
        try await generator.generate(outputDir: root)
        let source = try String(contentsOfFile: "\(root)/Models.swift", encoding: .utf8)
        if let directory = ProcessInfo.processInfo.environment["LUXO_CODEGEN_RECURSIVE_EVIDENCE"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            for file in try FileManager.default.contentsOfDirectory(atPath: root) {
                let destination = directory + "/" + file
                if FileManager.default.fileExists(atPath: destination) {
                    try FileManager.default.removeItem(atPath: destination)
                }
                try FileManager.default.copyItem(atPath: root + "/" + file, toPath: destination)
            }
        }
        XCTAssertTrue(source.contains("final class Container"))
        XCTAssertTrue(source.contains("final class Node"))
    }

    private var invalidSchemas: [String] {
        [
            #"{"models":{},"apis":{},"enums":{"State":{"name":"State","values":["A","A"]}}}"#,
            #"{"models":{},"apis":{},"enums":{"State":{"name":"Other","values":["A"]}}}"#,
            #"{"models":{"Item":{"name":"Item","fields":[{"id":1,"name":"state","type":"Enum"}]}},"apis":{}}"#,
            #"{"models":{},"apis":{"read":{"id":1,"name":"read","module":"test","returnType":"Enum"}}}"#,
            #"{"models":{},"apis":{"read":{"id":1,"name":"read","module":"test","returnType":"Int","params":[{"id":1,"name":"state","type":"Enum","typeName":"Missing"}]}}}"#,
        ]
    }
}
