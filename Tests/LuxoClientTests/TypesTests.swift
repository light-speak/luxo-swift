import XCTest
@testable import LuxoClient

final class TypesTests: XCTestCase {
    private struct SelectedRecord: Codable {
        let name: Selected<String>
        let note: Selected<String?>
    }

    func testSelectedDistinguishesMissingNullAndValueDuringCodableRoundTrip() throws {
        let decoded = try JSONDecoder().decode(
            SelectedRecord.self,
            from: Data(#"{"note":null}"#.utf8)
        )

        if case .unselected = decoded.name {} else { XCTFail("name should be unselected") }
        if case .value(nil) = decoded.note {} else { XCTFail("note should be selected null") }

        let encoded = try JSONEncoder().encode(decoded)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["name"])
        XCTAssertTrue(object["note"] is NSNull)
    }

    func testSelectedRequireValueRejectsUnselectedAndPreservesNull() throws {
        XCTAssertThrowsError(try Selected<Int>.unselected.requireValue())
        XCTAssertNil(try Selected<Int?>.value(nil).requireValue())
        XCTAssertEqual(try Selected.value(42).requireValue(), 42)
    }

    func testJSONValueRoundTripsEveryCase() throws {
        let value = JSONValue.object([
            "array": .array([.null, .bool(true), .number(1.5), .string("luxo")]),
            "object": .object(["enabled": .bool(false)]),
        ])

        let data = try JSONEncoder().encode(value)

        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), value)
    }

    func testPageCanBeConstructedAndDecoded() throws {
        let page = Page(items: [1, 2], total: 5, page: 1, pageSize: 2)
        XCTAssertEqual(page.items, [1, 2])
        XCTAssertEqual(page.total, 5)
        XCTAssertEqual(page.page, 1)
        XCTAssertEqual(page.pageSize, 2)

        let decoded = try JSONDecoder().decode(
            Page<Int>.self,
            from: Data(#"{"items":[3],"total":1,"page":2,"pageSize":10}"#.utf8)
        )
        XCTAssertEqual(decoded.items, [3])
        XCTAssertEqual(decoded.total, 1)
        XCTAssertEqual(decoded.page, 2)
        XCTAssertEqual(decoded.pageSize, 10)
    }

    func testCursorDecodesOptionalCursor() throws {
        let decoder = JSONDecoder()
        let next = try decoder.decode(
            Cursor<String>.self,
            from: Data(#"{"items":["a"],"nextCursor":"cursor-2","hasMore":true}"#.utf8)
        )
        XCTAssertEqual(next.items, ["a"])
        XCTAssertEqual(next.nextCursor, "cursor-2")
        XCTAssertTrue(next.hasMore)

        let end = try decoder.decode(
            Cursor<String>.self,
            from: Data(#"{"items":[],"nextCursor":null,"hasMore":false}"#.utf8)
        )
        XCTAssertNil(end.nextCursor)
        XCTAssertFalse(end.hasMore)
    }
}
