import Foundation
import XCTest
@testable import LuxoClient

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

final class SchemaIDTests: XCTestCase {
    func testRuntimeRegistrationRejectsDuplicateParameterNamesWithDistinctIDs() throws {
        let transports: [any Transport] = [
            try URLSessionTransport(endpoint: "https://example.com/luvia"),
            try WebSocketTransport(url: "wss://example.com/socket"),
        ]
        for transport in transports {
            for name in ["value", "__proto__", "用户"] {
                let first = APISchema.ParamSchema(fieldID: 1, name: name, type: "Int")
                let second = APISchema.ParamSchema(fieldID: 2, name: name, type: "Int")
                XCTAssertThrowsError(try transport.setSchema(["read": APISchema(id: 1, params: [first, second])])) {
                    error in
                    XCTAssertEqual((error as? LuxoError)?.name, "ConfigError")
                    XCTAssertTrue((error as? LuxoError)?.message.contains("duplicate name") == true)
                }
                XCTAssertNoThrow(
                    try transport.setSchema([
                        "read": APISchema(id: 1, params: [first]), "other": APISchema(id: 2, params: [first]),
                    ]))
            }
        }
    }

    func testDuplicateParameterNamesKeepPreviousHTTPRegistration() async throws {
        for mode in [TransportMode.json, .binary] {
            let transport = HTTPTransport(backend: RegistrationBackend())
            transport.setMode(mode)
            try transport.setSchema(["read": APISchema(id: 1, params: [.init(fieldID: 1, name: "value", type: "Int")])])
            XCTAssertThrowsError(
                try transport.setSchema([
                    "read": APISchema(
                        id: 9,
                        params: [
                            .init(fieldID: 1, name: "value", type: "Int"),
                            .init(fieldID: 2, name: "value", type: "Int"),
                        ])
                ]))
            let response = try await transport.call("read", params: ["value": .int(7)])
            XCTAssertEqual(response.data, mode == .binary ? Data([1]) : Data("true".utf8))
        }
    }

    private struct RegistrationBackend: HTTPBackend {
        func send(body: Data, mode: TransportMode, headers: [String: String]) async throws -> HTTPBackendResponse {
            if mode == .binary {
                XCTAssertEqual(Array(body), [1, 0, 1, 14, 0])
                return HTTPBackendResponse(status: 200, body: Data([1]))
            }
            XCTAssertEqual(String(data: body, encoding: .utf8), #"{"$api":"read","value":7}"#)
            return HTTPBackendResponse(status: 200, body: Data(#"{"data":true}"#.utf8))
        }
    }

    func testPaginationRequiresStableParameterDirectory() throws {
        for missing in ["page", "pageSize"] {
            let other = missing == "page" ? "pageSize" : "page"
            let data = Data(
                """
                {"models":{},"apis":{"browse":{"id":1,"name":"browse","module":"test","paginated":true,
                "params":[{"id":7,"name":"\(other)","type":"Int"}]}}}
                """.utf8)
            let schema = try JSONDecoder().decode(LuxoSchema.self, from: data)
            XCTAssertThrowsError(try schema.validateIDs())
        }
    }

    func testPaginationRejectsMalformedParameterShapes() throws {
        for invalid in [
            #"{"id":7,"name":"page","type":"String"}"#,
            #"{"id":7,"name":"page","type":"Int","nullable":true}"#,
            #"{"id":7,"name":"page","type":"Int","isList":true}"#,
            #"{"id":7,"name":"page","type":"Int"},{"id":8,"name":"page","type":"Int"}"#,
        ] {
            let data = Data(
                """
                {"models":{},"apis":{"browse":{"id":1,"name":"browse","module":"test","paginated":true,
                "params":[\(invalid),{"id":9,"name":"pageSize","type":"Int"}]}}}
                """.utf8)
            let schema = try JSONDecoder().decode(LuxoSchema.self, from: data)
            XCTAssertThrowsError(try schema.validateIDs())
        }
    }

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
