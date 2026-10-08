import Foundation
import XCTest
@testable import LuxoClient

final class GeneratedRequestTests: XCTestCase {
    private struct Request: GeneratedRequest {
        let apiID = 7
        let id: Int64
        var filters: [LuxoFilter]? = nil
        var sorters: [LuxoSorter]? = nil
        func writeParameters(to encoder: inout Encoder) throws {
            encoder.writeVarint(3)
            encoder.writeSvarint(id)
        }
        func toJSONParameters() throws -> [String: LuxoValue] {
            throw LuxoError(code: 0, message: "JSON on Binary", name: "ConfigError")
        }
    }

    func testDirectWireWithoutParameterSchema() throws {
        let request = Request(id: 9_007_199_254_740_993)
        var expected = Encoder()
        expected.writeVarint(7)
        expected.writeVarint(0)
        expected.writeVarint(3)
        expected.writeSvarint(request.id)
        expected.writeEnd()
        XCTAssertEqual(try LuxoBinaryProtocol.encodeRequest(schema: APISchema(id: 7), request: request), expected.data)
        XCTAssertThrowsError(try LuxoBinaryProtocol.encodeRequest(schema: APISchema(id: 8), request: request))
    }

    func testTypedControlsMatchDynamicWireAndRejectInvalidValues() throws {
        let filters: [LuxoFilter] = [
            .init(field: "id", op: "eq", value: .int(9_007_199_254_740_993)),
            .init(field: "max", op: "eq", value: .int64(Int64.max)),
            .init(field: "min", op: "eq", value: .int64(Int64.min)),
            .init(field: "enabled", op: "eq", value: .bool(true)),
            .init(field: "score", op: "gt", value: .double(1.25)),
            .init(field: "name", op: "contains", value: .string("中文")),
        ]
        let sorters = [LuxoSorter(field: "id", order: "desc")]
        let schema = APISchema(id: 7, params: [.init(fieldID: 3, name: "id", type: "Int")])
        let dynamic: [String: LuxoValue] = [
            "id": .int(42), "$filters": .array(filters.map(\.transportValue)),
            "$sorters": .array(sorters.map(\.transportValue)),
        ]
        let request = Request(id: 42, filters: filters, sorters: sorters)
        XCTAssertEqual(
            try LuxoBinaryProtocol.encodeRequest(schema: schema, request: request),
            try LuxoBinaryProtocol.encodeRequest(schema: schema, params: dynamic))
        for bad in [
            LuxoFilter(field: "score", op: "eq", value: .double(.nan)),
            LuxoFilter(field: "score", op: "unknown", value: .int(1)),
            LuxoFilter(field: "", op: "eq", value: .int(1)),
        ] {
            XCTAssertThrowsError(
                try LuxoBinaryProtocol.encodeRequest(
                    schema: schema,
                    request: Request(id: 42, filters: [bad])))
        }
        XCTAssertThrowsError(
            try LuxoBinaryProtocol.encodeRequest(
                schema: schema,
                request: Request(id: 42, sorters: [.init(field: "id", order: "bad")])))
        XCTAssertThrowsError(
            try LuxoBinaryProtocol.encodeRequest(
                schema: schema,
                request: Request(id: 42, filters: Array(repeating: filters[0], count: 1001))))
        XCTAssertThrowsError(
            try LuxoBinaryProtocol.encodeRequest(
                schema: schema,
                request: Request(id: 42, sorters: Array(repeating: sorters[0], count: 101))))
    }
}
