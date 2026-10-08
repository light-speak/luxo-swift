import XCTest
@testable import LuxoClient

final class QueryCodegenTests: XCTestCase {
    func testRejectsMalformedQueryCapabilities() throws {
        for field in [
            LuxoQueryFilter(field: "raw", type: "JSON", operators: ["eq"]),
            LuxoQueryFilter(field: "active", type: "Boolean", operators: ["gt"]),
            LuxoQueryFilter(field: "id", type: "Int", operators: []),
            LuxoQueryFilter(field: "id", type: "Int", operators: ["eq", "eq"]),
            LuxoQueryFilter(field: "bad\"", type: "Int", operators: ["eq"]),
        ] {
            let api = LuxoAPI(
                id: 1, name: "read", module: "x", paginated: true,
                query: LuxoQueryCapabilities(filters: [field]))
            let schema = LuxoSchema(models: [:], apis: ["read": api], enums: nil, types: nil)
            XCTAssertThrowsError(try SwiftQueryCodegen.generate(schema))
        }
    }
    func testQueryBuildersFollowAPICapabilities() throws {
        let data = Data(
            #"{"models":{},"apis":{"listUsers":{"id":1,"name":"listUsers","module":"user","paginated":true,"query":{"filters":[{"field":"id","type":"Int","operators":["eq","gt"]}],"sorters":["id"]}},"custom":{"id":2,"name":"custom","module":"user","returnList":true}}}"#
                .utf8)
        let schema = try JSONDecoder().decode(LuxoSchema.self, from: data)
        let source = try SwiftQueryCodegen.generate(schema)
        XCTAssertTrue(source.contains("enum LuxoQuery_listUsers"))
        XCTAssertTrue(source.contains("func id_eq(_ value: Int64)"))
        XCTAssertTrue(source.contains("func id_desc()"))
        XCTAssertFalse(source.contains("id_contains"))
        XCTAssertFalse(source.contains("LuxoQuery_custom"))
    }
}
