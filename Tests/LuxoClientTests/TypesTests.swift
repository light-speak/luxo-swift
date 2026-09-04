import XCTest
@testable import LuxoClient

final class TypesTests: XCTestCase {
    private struct EncodedInput: Codable, Sendable {
        let count: Int64
        let ratio: Double
        let enabled: Bool
        let names: [String]
    }

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

    func testLuxoValueIsSendableAndPreservesWireTypes() throws {
        let value = LuxoValue.object([
            "null": .null,
            "bool": .bool(true),
            "int": .int(9_007_199_254_740_993),
            "float": .float(1.5),
            "string": .string("luxo"),
            "bytes": .bytes(Data([0, 1, 2])),
            "array": .array([.int(1), .string("two")]),
        ])

        func requireSendable<T: Sendable>(_: T) {}
        requireSendable(value)
        let wireValue = try LuxoValue.decodeJSONData(value.jsonData())
        XCTAssertEqual(
            wireValue,
            .object([
                "null": .null,
                "bool": .bool(true),
                "int": .int(9_007_199_254_740_993),
                "float": .float(1.5),
                "string": .string("luxo"),
                "bytes": .string("AAEC"),
                "array": .array([.int(1), .string("two")]),
            ])
        )
    }

    func testLuxoValueEncodesStructuredInputsWithoutLosingIntegers() throws {
        let value = try LuxoValue.encode(
            EncodedInput(count: 9_007_199_254_740_993, ratio: 1.25, enabled: true, names: ["a", "b"])
        )

        XCTAssertEqual(
            value,
            .object([
                "count": .int(9_007_199_254_740_993),
                "ratio": .float(1.25),
                "enabled": .bool(true),
                "names": .array([.string("a"), .string("b")]),
            ])
        )
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
