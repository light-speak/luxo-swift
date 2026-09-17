import Foundation
import XCTest
@testable import LuxoClient

final class JSONCodableTests: XCTestCase {
    private struct EmptyProjection: Decodable {
        init(from decoder: Swift.Decoder) throws {
            try LuxoJSONDecoder.validateEmptyModelProjection(from: decoder)
        }
    }

    func testEmptyProjectionUsesLuxoArrayIdentityNotNumericObjectKeys() throws {
        let decoder = LuxoJSONDecoder()
        XCTAssertNoThrow(try decoder.decode(EmptyProjection.self, from: Data("{}".utf8)))
        XCTAssertNoThrow(try decoder.decode([String: EmptyProjection].self, from: Data(#"{"0":{}}"#.utf8)))
        XCTAssertThrowsError(try decoder.decode([EmptyProjection].self, from: Data("[{}]".utf8))) { error in
            guard case DecodingError.dataCorrupted(let context) = error else {
                return XCTFail("missing projection error")
            }
            XCTAssertEqual(context.codingPath.map(\.stringValue), ["0"])
        }
        // The generated Codable conformance is also usable outside the Luxo wire decoder.
        XCTAssertNoThrow(try JSONDecoder().decode(EmptyProjection.self, from: Data("{}".utf8)))
        XCTAssertNoThrow(
            try LuxoJSONDecoder.validateEmptyModelProjection(
                from: JSONTreeDecoder(value: .object([:]), key: JSONCodingKey(stringValue: "0"))))
    }

    func testSelectedPresenceAccumulatesWithoutTreatingNullAsMissing() throws {
        enum Key: String, CodingKey { case missing, null, value, invalid }
        let decoder = JSONTreeDecoder(value: .object(["null": .null, "value": 7, "invalid": "wrong"]))
        let container = try decoder.container(keyedBy: Key.self)
        var selected = false
        _ = try container.decode(Selected<Int>.self, forKey: .missing, selected: &selected)
        XCTAssertFalse(selected)
        XCTAssertThrowsError(try container.decode(Selected<Int>.self, forKey: .invalid, selected: &selected))
        XCTAssertFalse(selected)
        XCTAssertNil(try container.decode(Selected<Int?>.self, forKey: .null, selected: &selected).requireValue())
        XCTAssertTrue(selected)
        _ = try container.decode(Selected<Int>.self, forKey: .missing, selected: &selected)
        XCTAssertTrue(selected)
        selected = false
        XCTAssertEqual(try container.decode(Selected<Int>.self, forKey: .value, selected: &selected).requireValue(), 7)
        XCTAssertTrue(selected)
    }

    private struct Primitives: Codable, Equatable {
        var boolean = true
        var string = "text"
        var double: Double = 1.25
        var float: Float = 1.25
        var int = Int.min
        var int8 = Int8.min
        var int16 = Int16.min
        var int32 = Int32.min
        var int64 = Int64.min
        var uint = UInt.max
        var uint8 = UInt8.max
        var uint16 = UInt16.max
        var uint32 = UInt32.max
        var uint64 = UInt64.max
    }

    func testSpecializedPrimitiveContainers() throws {
        try roundTrip(Primitives())
        let data = Data(#"[true,"text",1.25,1.25,-1,-1,-1,-1,-1,1,1,1,1,1]"#.utf8)
        var array = try JSONTreeDecoder(value: JSONReader.decode(data)).unkeyedContainer()
        XCTAssertEqual(try array.decode(Bool.self), true)
        XCTAssertEqual(try array.decode(String.self), "text")
        XCTAssertEqual(try array.decode(Double.self), 1.25)
        XCTAssertEqual(try array.decode(Float.self), 1.25)
        XCTAssertEqual(try array.decode(Int.self), -1)
        XCTAssertEqual(try array.decode(Int8.self), -1)
        XCTAssertEqual(try array.decode(Int16.self), -1)
        XCTAssertEqual(try array.decode(Int32.self), -1)
        XCTAssertEqual(try array.decode(Int64.self), -1)
        XCTAssertEqual(try array.decode(UInt.self), 1)
        XCTAssertEqual(try array.decode(UInt8.self), 1)
        XCTAssertEqual(try array.decode(UInt16.self), 1)
        XCTAssertEqual(try array.decode(UInt32.self), 1)
        XCTAssertEqual(try array.decode(UInt64.self), 1)
        XCTAssertTrue(array.isAtEnd)
    }

    func testContainerPathsAndSelectedValues() throws {
        let decoder = JSONTreeDecoder(value: .int(42), parentPath: [JSONCodingKey(stringValue: "root")])
        XCTAssertEqual(try decoder.singleValueContainer().codingPath.map(\.stringValue), ["root"])
        let encoder = JSONTreeEncoder(node: JSONEncodingNode(), codingPath: [JSONCodingKey(stringValue: "root")])
        var container = encoder.unkeyedContainer()
        XCTAssertEqual(container.codingPath.map(\.stringValue), ["root"])
        let objectEncoder = JSONTreeEncoder(
            node: JSONEncodingNode(), codingPath: [JSONCodingKey(stringValue: "object")])
        let object = objectEncoder.container(keyedBy: JSONCodingKey.self)
        XCTAssertEqual(object.codingPath.map(\.stringValue), ["object"])
        try container.encode(Selected.value(42))
        XCTAssertEqual(try LuxoJSONDecoder().decode(Selected<Int>.self, from: Data("42".utf8)).requireValue(), 42)
        XCTAssertThrowsError(try LuxoJSONEncoder().encode(Selected<Int>.unselected))
        XCTAssertEqual(try JSONTreeDecoder(value: .float(1.25)).decode(Double.self), 1.25)
        let empty = try JSONTreeDecoder(value: .object([:])).container(keyedBy: JSONCodingKey.self)
        XCTAssertNil(try Int?(from: empty.superDecoder()))
    }
    func testEveryPrimitiveAndCollection() throws {
        try roundTrip(true); try roundTrip(false); try roundTrip("東京\u{feff}\n")
        try roundTrip(Int.min); try roundTrip(Int8.min); try roundTrip(Int16.min)
        try roundTrip(Int32.min); try roundTrip(Int64.min)
        try roundTrip(UInt.max); try roundTrip(UInt8.max); try roundTrip(UInt16.max)
        try roundTrip(UInt32.max); try roundTrip(UInt64.max)
        try roundTrip(Float(1.25)); try roundTrip(Double(1.25))
        try roundTrip(Int?.none); try roundTrip(Int?.some(42))
        try roundTrip([1, 2, 3]); try roundTrip([Int]()); try roundTrip([1, nil, 2] as [Int?])
        try roundTrip(["a": [1, 2], "b": [3]]); try roundTrip([String: Int]())
        try roundTrip(Data([0, 255])); try roundTrip(Data())
        try roundTrip(UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!)
        try roundTrip(Date(timeIntervalSinceReferenceDate: 100.25))
    }

    private func roundTrip<T: Codable & Equatable>(_ value: T, file: StaticString = #filePath, line: UInt = #line)
        throws
    {
        let data = try LuxoJSONEncoder().encode(value)
        XCTAssertEqual(try LuxoJSONDecoder().decode(T.self, from: data), value, file: file, line: line)
    }

    func testTypedRejectionsAndCodingPaths() throws {
        for text in ["null", "true", "\"42\"", "[]", "{}", "1.0", "9223372036854775808"] {
            XCTAssertThrowsError(try decode(Int64.self, text), text)
        }
        XCTAssertEqual(try decode(Int64.self, "-0"), 0)
        XCTAssertThrowsError(try decode(Int8.self, "128"))
        XCTAssertThrowsError(try decode(UInt8.self, "-1"))
        XCTAssertThrowsError(try decode(UInt64.self, "18446744073709551616"))
        XCTAssertThrowsError(try decode(Bool.self, "1"))
        XCTAssertThrowsError(try decode(String.self, "false"))
        XCTAssertThrowsError(try decode([Int].self, "{}"))
        XCTAssertThrowsError(try decode([String: Int].self, "[]"))
        XCTAssertThrowsError(try decode(Data.self, "[]"))
        XCTAssertThrowsError(try decode(Data.self, "\"bad%\""))
        XCTAssertThrowsError(try decode(Double.self, "null"))
        XCTAssertThrowsError(try decode(Float.self, "1e39"))
        XCTAssertThrowsError(try decode(Float.self, "1e-50"))
        XCTAssertEqual(try decode(Double.self, "1"), 1)
        for value in [Double.infinity, -.infinity, .nan] { XCTAssertThrowsError(try LuxoJSONEncoder().encode(value)) }
        XCTAssertThrowsError(try LuxoJSONEncoder().encode(Float.infinity))
        struct Nested: Decodable { let numbers: [Int8] }
        XCTAssertThrowsError(try decode(Nested.self, #"{"numbers":[128]}"#)) { error in
            guard case DecodingError.typeMismatch(_, let context) = error else { return XCTFail("missing path") }
            XCTAssertEqual(context.codingPath.map(\.stringValue), ["numbers", "0"])
        }
        XCTAssertThrowsError(try decode(Nested.self, "{}")) { error in
            guard case DecodingError.keyNotFound(let key, _) = error else { return XCTFail("missing key error") }
            XCTAssertEqual(key.stringValue, "numbers")
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
        try LuxoJSONDecoder().decode(type, from: Data(text.utf8))
    }

    func testLazyContainerPathsRemainComplete() throws {
        struct Item: Decodable { let value: Int8 }
        struct Group: Decodable { let items: [Item] }
        struct Root: Decodable { let groups: [Group] }
        let valid = #"{"groups":[{"items":[{"value":1}]}]}"#
        XCTAssertEqual(try decode(Root.self, valid).groups[0].items[0].value, 1)
        let invalid = #"{"groups":[{"items":[{"value":128}]}]}"#
        XCTAssertThrowsError(try decode(Root.self, invalid)) { error in
            guard case DecodingError.typeMismatch(_, let context) = error else { return XCTFail("missing path") }
            XCTAssertEqual(context.codingPath.map(\.stringValue), ["groups", "0", "items", "0", "value"])
        }
        XCTAssertThrowsError(try decode(Root.self, #"{"groups":[{"items":[{}]}]}"#)) { error in
            guard case DecodingError.keyNotFound(let key, let context) = error else {
                return XCTFail("missing key error")
            }
            XCTAssertEqual(key.stringValue, "value")
            XCTAssertEqual(context.codingPath.map(\.stringValue), ["groups", "0", "items", "0"])
        }
        let decoder = JSONTreeDecoder(value: try JSONReader.decode(Data(valid.utf8)))
        let root = try decoder.container(keyedBy: JSONCodingKey.self)
        var groups = try root.nestedUnkeyedContainer(forKey: .init(stringValue: "groups"))
        let group = try groups.nestedContainer(keyedBy: JSONCodingKey.self)
        var items = try group.nestedUnkeyedContainer(forKey: .init(stringValue: "items"))
        let item = try items.nestedContainer(keyedBy: JSONCodingKey.self)
        XCTAssertEqual(group.codingPath.map(\.stringValue), ["groups", "0"])
        XCTAssertEqual(items.codingPath.map(\.stringValue), ["groups", "0", "items"])
        XCTAssertEqual(item.codingPath.map(\.stringValue), ["groups", "0", "items", "0"])
    }

    func testNestedAndSuperContainers() throws { try roundTrip(Containers()) }

    private struct Containers: Codable, Equatable {
        enum Key: String, CodingKey { case nested, array, child, value, missing, explicitNull }
        init() {}

        func encode(to encoder: Swift.Encoder) throws {
            XCTAssertTrue(encoder.userInfo.isEmpty)
            var root = encoder.container(keyedBy: Key.self)
            try root.encodeNil(forKey: .explicitNull)
            var nested = root.nestedContainer(keyedBy: Key.self, forKey: .nested)
            try nested.encode(7, forKey: .value)
            try JSONValue.rawNumber(JSONNumber("1.5")).encode(to: root.superEncoder(forKey: .child))
            try "parent".encode(to: root.superEncoder())
            var array = root.nestedUnkeyedContainer(forKey: .array)
            try array.encodeNil()
            try array.encode(1)
            var list = array.nestedUnkeyedContainer()
            try list.encode(true)
            var object = array.nestedContainer(keyedBy: Key.self)
            try object.encode("nested", forKey: .value)
            try "last".encode(to: array.superEncoder())
            XCTAssertEqual(array.count, 5)
        }

        init(from decoder: Swift.Decoder) throws {
            XCTAssertTrue(decoder.userInfo.isEmpty)
            let root = try decoder.container(keyedBy: Key.self)
            XCTAssertTrue(root.allKeys.contains(.array))
            XCTAssertFalse(root.contains(.missing))
            XCTAssertTrue(try root.decodeNil(forKey: .explicitNull))
            XCTAssertFalse(try root.decodeNil(forKey: .nested))
            let nested = try root.nestedContainer(keyedBy: Key.self, forKey: .nested)
            XCTAssertEqual(try nested.decode(Int.self, forKey: .value), 7)
            XCTAssertEqual(try Double(from: root.superDecoder(forKey: .child)), 1.5)
            XCTAssertEqual(try String(from: root.superDecoder()), "parent")
            var array = try root.nestedUnkeyedContainer(forKey: .array)
            XCTAssertEqual(array.count, 5)
            XCTAssertTrue(try array.decodeNil())
            XCTAssertFalse(try array.decodeNil())
            XCTAssertEqual(try array.decode(Int.self), 1)
            var list = try array.nestedUnkeyedContainer()
            XCTAssertTrue(try list.decode(Bool.self))
            let object = try array.nestedContainer(keyedBy: Key.self)
            XCTAssertEqual(try object.decode(String.self, forKey: .value), "nested")
            XCTAssertEqual(try String(from: array.superDecoder()), "last")
            XCTAssertTrue(array.isAtEnd)
            XCTAssertThrowsError(try array.decode(Int.self))
            XCTAssertThrowsError(try array.decodeNil())
        }
    }

    func testRecursiveCustomEncodableAndStructuredInputsFailAtDepthLimit() {
        struct Recursive: Encodable {
            func encode(to encoder: Swift.Encoder) throws {
                var container = encoder.singleValueContainer()
                try container.encode(self)
            }
        }
        XCTAssertThrowsError(try LuxoJSONEncoder().encode(Recursive()))
        struct NestedContainers: Encodable {
            func encode(to encoder: Swift.Encoder) throws {
                var array = encoder.unkeyedContainer()
                for _ in 0..<129 { array = array.nestedUnkeyedContainer() }
            }
        }
        XCTAssertThrowsError(try LuxoJSONEncoder().encode(NestedContainers()))
        var value: JSONValue = .null
        for _ in 0..<129 { value = .array([value]) }
        XCTAssertThrowsError(try LuxoJSONEncoder().encode(value))
    }
}
