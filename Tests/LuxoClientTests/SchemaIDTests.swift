import Foundation
import XCTest
@testable import LuxoClient

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

final class SchemaIDTests: XCTestCase {
    func testRuntimeRegistrationRejectsInvalidIDs() throws {
        let transports: [any Transport] = [
            try URLSessionTransport(endpoint: "https://example.com/luvia"),
            try WebSocketTransport(url: "wss://example.com/socket"),
        ]
        for transport in transports {
            for target in ["apis", "params", "fields", "types"] {
                let maximum = target == "apis" ? 2147483647 : target == "params" ? 2147483645 : 65535
                for id in [0, -1, maximum + 1, Int.max] {
                    XCTAssertThrowsError(try transport.setSchema(runtimeSchema(target, id: id))) { error in
                        XCTAssertEqual((error as? LuxoError)?.name, "ConfigError")
                    }
                }
                XCTAssertThrowsError(try transport.setSchema(runtimeSchema(target, id: 1, duplicate: true)))
                XCTAssertNoThrow(try transport.setSchema(runtimeSchema(target, id: maximum)))
            }
            XCTAssertNoThrow(try transport.setSchema([:]))
        }
    }

    private func runtimeSchema(_ target: String, id: Int, duplicate: Bool = false) -> [String: APISchema] {
        let field = APISchema.SelectionFieldSchema(fieldID: id, type: "Int")
        let fields = duplicate ? ["value": field, "other": field] : ["value": field]
        let param = APISchema.ParamSchema(fieldID: id, name: "value", type: "Int")
        let params = duplicate ? [param, .init(fieldID: id, name: "other", type: "Int")] : [param]
        let api = APISchema(
            id: target == "apis" ? id : 1,
            params: target == "params" ? params : nil,
            fields: target == "fields" ? fields : [:],
            types: target == "types" ? ["Input": fields] : [:])
        return target == "apis" && duplicate ? ["read": api, "other": api] : ["read": api]
    }

    func testInvalidSchemaIDsPreserveGeneratedFiles() async throws {
        for target in ["models", "types", "apis", "params"] {
            let maximum = target == "apis" ? 2147483647 : target == "params" ? 2147483645 : 65535
            for id in [0, -1, maximum + 1, Int.max] {
                try await rejectSchema(numberedSchema(target, id: id))
            }
            try await rejectSchema(numberedSchema(target, id: 1, duplicate: true))
        }
    }

    func testLegalSparseMaximaArePreserved() async throws {
        for (target, id) in [("models", 65535), ("types", 65535), ("apis", 2147483647), ("params", 2147483645)] {
            let output = ".tmp/schema-id-valid-\(UUID().uuidString)"
            defer { try? FileManager.default.removeItem(atPath: output) }
            try await codegen(numberedSchema(target, id: id)).generate(outputDir: output)
            let source = try String(contentsOfFile: "\(output)/Schema.swift", encoding: .utf8)
            XCTAssertTrue(source.contains(String(id)))
        }
    }

    private func rejectSchema(_ body: Data) async throws {
        let output = ".tmp/schema-id-invalid-\(UUID().uuidString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: output, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: output) }
        try "existing client".write(toFile: "\(output)/Models.swift", atomically: true, encoding: .utf8)
        do {
            try await codegen(body).generate(outputDir: output)
            XCTFail("invalid ID accepted")
        } catch let error as LuxoError {
            XCTAssertEqual(error.name, "ConfigError")
            XCTAssertTrue(error.message.contains("ID"))
        }
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: output), ["Models.swift"])
        XCTAssertEqual(try String(contentsOfFile: "\(output)/Models.swift", encoding: .utf8), "existing client")
    }

    private func codegen(_ body: Data) throws -> LuxoCodegen {
        try LuxoCodegen(endpoint: "https://example.com/luvia", introspectionKey: "test") { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil
                ))
            return (body, response)
        }
    }

    private func numberedSchema(_ target: String, id: Int, duplicate: Bool = false) -> Data {
        let field = #"{"id":\#(id),"name":"value","type":"Int"}"#
        let fields = "[" + field + (duplicate ? "," + field.replacingOccurrences(of: "value", with: "other") : "") + "]"
        let apiID = target == "apis" ? id : 1
        let params = target == "params" ? #", "params":\#(fields)"# : ""
        let api = #"{"id":\#(apiID),"name":"read","module":"test","returnType":"Int"\#(params)}"#
        let apis =
            #""apis":{"read":\#(api)"#
            + (target == "apis" && duplicate
                ? #", "other":\#(api.replacingOccurrences(of: "read", with: "other"))"# : "") + "}"
        let declaration = #"{"Payload":{"name":"Payload","fields":\#(fields)}}"#
        let models = target == "models" ? declaration : "{}"
        let types = target == "types" ? #", "types":\#(declaration)"# : ""
        return Data(#"{"models":\#(models),\#(apis)\#(types)}"#.utf8)
    }
}
