import XCTest
@testable import LuxoClient

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

final class CodegenEnumTests: XCTestCase {
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
        let root = ".tmp/codegen-enum-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        for (index, body) in invalidSchemas.enumerated() {
            let output = "\(root)/\(index)"
            try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
            try "existing client".write(toFile: "\(output)/Models.swift", atomically: true, encoding: .utf8)
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
                XCTFail("invalid enum schema accepted: \(body)")
            } catch let error as LuxoError {
                XCTAssertEqual(error.name, "SchemaError")
            }
            XCTAssertEqual(try String(contentsOfFile: "\(output)/Models.swift", encoding: .utf8), "existing client")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output), ["Models.swift"])
        }
    }

    private var invalidSchemas: [String] {
        [
            #"{"models":{},"apis":{},"enums":{"State":{"name":"State","values":[]}}}"#,
            #"{"models":{},"apis":{},"enums":{"State":{"name":"State","values":["A","A"]}}}"#,
            #"{"models":{},"apis":{},"enums":{"State":{"name":"Other","values":["A"]}}}"#,
            #"{"models":{"Item":{"name":"Item","fields":[{"id":1,"name":"state","type":"Enum"}]}},"apis":{}}"#,
            #"{"models":{},"apis":{"read":{"id":1,"name":"read","module":"test","returnType":"Enum"}}}"#,
            #"{"models":{},"apis":{"read":{"id":1,"name":"read","module":"test","returnType":"Int","params":[{"id":1,"name":"state","type":"Enum","typeName":"Missing"}]}}}"#,
        ]
    }
}
