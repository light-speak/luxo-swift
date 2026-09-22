import XCTest
@testable import LuxoClient

final class TypesTests: XCTestCase {
    func testComputedSourceMetadataRoundTrips() throws {
        let input = #"""
            {"name":"User","fields":[{"id":1,"name":"postCount","type":"Int"}],
            "computedSources":{"postCount":{"model":"Post","module":"blog"},"localCount":{"model":"Local"}}}
            """#
        let model = try JSONDecoder().decode(LuxoModel.self, from: Data(input.utf8))
        XCTAssertEqual(model.computedSources?["postCount"]?.model, "Post")
        XCTAssertEqual(model.computedSources?["postCount"]?.module, "blog")
        XCTAssertNil(model.computedSources?["localCount"]?.module)
        XCTAssertEqual(model.fields.first?.type, "Int")
        let roundTrip = try JSONDecoder().decode(LuxoModel.self, from: JSONEncoder().encode(model))
        XCTAssertEqual(roundTrip.computedSources?["postCount"]?.model, "Post")
        let plain = try JSONDecoder().decode(LuxoModel.self, from: Data(#"{"name":"Plain","fields":[]}"#.utf8))
        XCTAssertNil(plain.computedSources)
    }

    func testJSONValueKeepsIntegersOnTheExactIntegerPath() throws {
        for source in ["0", "1", "42", "9007199254740991"] {
            let value = try JSONValue.parse(Data(source.utf8))
            guard case .integer(let number) = value else { return XCTFail("expected exact integer") }
            XCTAssertEqual(number, Int64(source))
        }
    }

    func testJSONValueNumericEqualityNeverRoundsAnInteger() throws {
        XCTAssertEqual(JSONValue.integer(42), .number(42))
        XCTAssertEqual(JSONValue.number(42), .integer(42))
        XCTAssertEqual(JSONValue.integer(0), .number(-0.0))
        XCTAssertNotEqual(JSONValue.integer(1), .number(1.5))
        XCTAssertNotEqual(JSONValue.integer(Int64.max), .number(Double(Int64.max)))
        XCTAssertNotEqual(JSONValue.integer(9_007_199_254_740_993), .number(9_007_199_254_740_992))
        XCTAssertNotEqual(JSONValue.integer(0), .bool(false))
        XCTAssertEqual(JSONValue.array([.integer(42)]), .array([.number(42)]))
        XCTAssertEqual(JSONValue.object(["n": .number(42)]), .object(["n": .integer(42)]))
    }

    func testJSONValuePreservesNegativeZero() throws {
        for literal in ["-0", "-0.0", "-0e0"] {
            let value = try JSONValue.parse(Data(literal.utf8))
            guard case .rawNumber(let number) = value else { return XCTFail("negative zero must retain its token") }
            XCTAssertEqual(number.literal, literal)
            XCTAssertEqual(try number.toDouble().bitPattern, (-0.0).bitPattern)
        }
    }

    func testJSONValuePreservesFullWidthIntegers() throws {
        for value in [Int64.min, -9_007_199_254_740_993, -1, 0, 1, 9_007_199_254_740_993, Int64.max] {
            let source = Data("{\"value\":\(value)}".utf8)
            let parsed = try LuxoJSONDecoder().decode(JSONValue.self, from: source)
            let result = try JSONEncoder().encode(parsed)
            XCTAssertEqual(try JSONDecoder().decode([String: Int64].self, from: result)["value"], value)
            XCTAssertEqual(try LuxoValue(parsed).jsonData(), source)
        }
    }

    private struct ProjectedInput: LuxoBinaryEncodable {
        let count: Int64

        func writeLuxo(to encoder: inout Encoder) throws {
            encoder.writeSvarint(count)
        }

        func luxoJSONValue() throws -> LuxoValue {
            .object(["count": .int(count)])
        }

        func encode(to encoder: Swift.Encoder) throws {
            throw LuxoError(code: 0, message: "intermediate serialization must not run", name: "TestError")
        }
    }

    func testStructuredInputUsesTypedProjectionWithoutIntermediateSerialization() throws {
        for count in [Int64.min, 9_007_199_254_740_993, Int64.max] {
            let value = LuxoValue.structured(ProjectedInput(count: count))
            XCTAssertEqual(try value.jsonData(), Data("{\"count\":\(count)}".utf8))
            XCTAssertEqual(value, .structured(ProjectedInput(count: count)))
        }
    }

    func testFiniteFloatConversionPreservesValuesAndRejectsNonFiniteInputs() throws {
        for value in [-Double.greatestFiniteMagnitude, -0.0, 0.0, 1.0, 1.5, Double.leastNonzeroMagnitude] {
            let converted = try LuxoValue(finiteFloat: value)
            guard case .float(let number) = converted else { return XCTFail("expected Float") }
            XCTAssertEqual(number.bitPattern, value.bitPattern)
        }
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try LuxoValue(finiteFloat: value)) { error in
                XCTAssertEqual((error as? LuxoError)?.name, "EncodingError")
            }
        }
    }

    private struct EncodedInput: Codable, Sendable {
        let count: Int64
        let ratio: Double
        let enabled: Bool
        let names: [String]
    }

    private struct BinaryInput: Codable, Sendable, LuxoBinaryEncodable {
        let name: String

        func writeLuxo(to encoder: inout Encoder) throws {
            encoder.writeVarint(UInt64(name.utf8.count))
            encoder.writeVarint(1)
            encoder.writeString(name)
            encoder.writeEnd()
        }
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
            "array": .array([.null, .bool(true), .integer(42), .rawNumber(try JSONNumber("1.5")), .string("luxo")]),
            "object": .object(["enabled": .bool(false)]),
        ])

        let data = try LuxoJSONEncoder().encode(value)

        XCTAssertEqual(try LuxoJSONDecoder().decode(JSONValue.self, from: data), value)
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
                "float": .jsonNumber(try JSONNumber("1.5")),
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

    func testLuxoValuePreservesUnsignedJSONWithoutExpandingSchemaInt() throws {
        let schema = APISchema(id: 1, params: [.init(fieldID: 1, name: "value", type: "Int")])
        for value in [UInt64(Int64.max) + 1, UInt64.max] {
            let encoded = try LuxoValue.encode(value)
            XCTAssertEqual(try encoded.jsonData(), Data(String(value).utf8))
            XCTAssertEqual(try LuxoValue.encode(["values": [value]]).jsonData(), Data("{\"values\":[\(value)]}".utf8))
            XCTAssertThrowsError(
                try LuxoJSONRequest.encode(api: "echo", params: ["value": encoded], plan: schema.jsonParameters))
            XCTAssertThrowsError(try LuxoBinaryProtocol.encodeRequest(schema: schema, params: ["value": encoded]))
        }
    }

    func testLuxoValuePreservesSignedBoundariesAndValidUnsignedInputs() throws {
        for value in [Int64.min, -1, 0, 1, 9_007_199_254_740_993, Int64.max] {
            XCTAssertEqual(try LuxoValue.encode(value), .int(value))
            XCTAssertEqual(try LuxoValue.decodeJSONData(LuxoValue.int(value).jsonData()), .int(value))
        }
        for value in [UInt64(0), 1, UInt64(Int64.max)] {
            XCTAssertEqual(try LuxoValue.encode(value), .int(Int64(value)))
        }
        XCTAssertEqual(try LuxoValue.encode(true), .bool(true))
        XCTAssertEqual(try LuxoValue.encode(false), .bool(false))
        XCTAssertEqual(try LuxoValue.encode(1.5), .float(1.5))
    }

    func testStructuredLuxoValueDefersToJSONUntilJSONTransportNeedsIt() throws {
        let value = LuxoValue.structured(BinaryInput(name: "Luxo"))
        XCTAssertEqual(
            try LuxoValue.decodeJSONData(value.jsonData()),
            .object(["name": .string("Luxo")])
        )
        XCTAssertEqual(value, .structured(BinaryInput(name: "Luxo")))
        XCTAssertNotEqual(value, .structured(BinaryInput(name: "Other")))
        XCTAssertNotEqual(value, .string("Luxo"))
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
