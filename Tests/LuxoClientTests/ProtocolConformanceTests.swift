import Foundation
import XCTest
@testable import LuxoClient

final class ProtocolConformanceTests: XCTestCase {
    func testDateTimeSharedBoundaries() throws {
        let cases = try loadProtocolFixture().dateTimeBoundaryCases
        XCTAssertEqual(cases.count, 34)
        for item in cases {
            var encoder = Encoder()
            if let canonical = item.canonical {
                do { try encoder.writeDateTime(item.input) } catch {
                    XCTFail("rejected \(item.input): \(error)"); continue
                }
                var decoder = Decoder(encoder.data)
                XCTAssertEqual(decoder.readDateTime(), canonical, item.input)
                XCTAssertNil(decoder.error)
            } else {
                XCTAssertThrowsError(try encoder.writeDateTime(item.input), item.input)
                XCTAssertTrue(encoder.data.isEmpty)
            }
        }
    }

    func testJSONUnicodeMatchesSharedCorpus() throws {
        let cases = try loadProtocolFixture().jsonUnicodeCases
        XCTAssertFalse(cases.isEmpty)
        for item in cases {
            let data = Data(item.raw.utf8)
            if item.valid {
                XCTAssertNoThrow(try JSONValue.parse(data), item.name)
            } else {
                XCTAssertThrowsError(try JSONValue.parse(data), item.name)
            }
        }
    }

    func testUUIDCanonicalSharedCasesRejectMisplacedSeparators() throws {
        let cases = try loadProtocolFixture().uuidCanonicalCases
        XCTAssertEqual(cases.count, 11)
        for item in cases {
            let value = UUID(uuidString: item.input)
            guard let canonical = item.canonical else {
                XCTAssertNil(value, item.input)
                continue
            }
            var encoder = Encoder()
            encoder.writeUUID(try XCTUnwrap(value))
            XCTAssertEqual(encoder.data.count, 16)
            var decoder = Decoder(encoder.data)
            XCTAssertEqual(decoder.readUUID().uuidString.lowercased(), canonical)
            XCTAssertNil(decoder.error)
        }
    }

    func testDateTimeMatchesCanonicalNanoseconds() throws {
        let cases = try loadProtocolFixture().dateTimeCases
        XCTAssertFalse(cases.isEmpty)
        for item in cases {
            var encoder = Encoder()
            try encoder.writeDateTime(item.input)
            var decoder = Decoder(encoder.data)
            XCTAssertEqual(decoder.readSvarint(), Int64(item.seconds), item.input)
            XCTAssertEqual(decoder.readVarint(), item.nanoseconds, item.input)
            XCTAssertNil(decoder.error)
            XCTAssertEqual(decoder.remaining, 0)
            var golden = Encoder()
            golden.writeSvarint(try XCTUnwrap(Int64(item.seconds)))
            golden.writeVarint(item.nanoseconds)
            var timestamp = Decoder(golden.data)
            XCTAssertEqual(timestamp.readDateTime(), item.canonical, item.input)
        }
    }

    func testDateTimeFormattingIsSafeAcrossConcurrentRequests() throws {
        let cases = try loadProtocolFixture().dateTimeCases
        XCTAssertFalse(cases.isEmpty)
        DispatchQueue.concurrentPerform(iterations: 1000) { index in
            let item = cases[index % cases.count]
            do {
                let parts = try dateTimeParts(item.input)
                XCTAssertEqual(String(parts.seconds), item.seconds, item.input)
                XCTAssertEqual(parts.nanoseconds, item.nanoseconds, item.input)
                XCTAssertEqual(dateTimeString(parts), item.canonical, item.input)
            } catch {
                XCTFail("DateTime failed for \(item.input): \(error)")
            }
        }
    }

    func testExplicitJSONNumberConversionsMatchCanonicalCorpus() throws {
        let cases = try loadProtocolFixture().jsonNumberConversions
        XCTAssertFalse(cases.isEmpty)
        for item in cases {
            let number = try JSONNumber(item.token)
            let data = Data(item.token.utf8)
            let integers: [() throws -> Int64] = [
                { try number.toInt64() }, { try LuxoJSONDecoder().decode(Int64.self, from: data) },
            ]
            for convert in integers {
                if let expected = item.int64 {
                    XCTAssertEqual(String(try convert()), expected, item.token)
                } else {
                    XCTAssertThrowsError(try convert(), item.token)
                }
            }
            let floats: [() throws -> Double] = [
                { try number.toDouble() }, { try LuxoJSONDecoder().decode(Double.self, from: data) },
            ]
            for convert in floats {
                if let expected = item.float64Bits {
                    XCTAssertEqual(try convert().bitPattern, UInt64(expected, radix: 16), item.token)
                } else {
                    XCTAssertThrowsError(try convert(), item.token)
                }
            }
            XCTAssertEqual(number.literal, item.token)
            XCTAssertEqual(try JSONValue.parse(data).jsonData(), data)
        }
    }

    func testInt64MatchesCanonicalWireAndJSON() throws {
        for item in try loadProtocolFixture().int64Cases {
            let value = try XCTUnwrap(Int64(item.value))
            let wire = try data(from: item.wire)
            assertEncoding(item.wire) { $0.writeSvarint(value) }
            var decoder = Decoder(wire)
            XCTAssertEqual(decoder.readSvarint(), value)
            XCTAssertNil(decoder.error)
            let containerWire = Data([1]) + wire
            var nullable = Decoder(containerWire)
            XCTAssertEqual(nullable.readIntPtr(), value)
            XCTAssertNil(nullable.error)
            var array = Decoder(containerWire)
            XCTAssertEqual(array.readArray { $0.readSvarint() }, [value])
            XCTAssertNil(array.error)
            var column = ColumnarDecoder(data: Data([1, 0, 1]) + wire + Data([0]))
            XCTAssertTrue(column.nextColumn())
            XCTAssertEqual(column.readColumnInt(), [value])
            XCTAssertNil(column.error)
            var nullableColumn = ColumnarDecoder(data: Data([1, 0, 1]) + containerWire + Data([0]))
            XCTAssertTrue(nullableColumn.nextColumn())
            XCTAssertEqual(nullableColumn.readColumnIntPtr(), [value])
            XCTAssertNil(nullableColumn.error)
            XCTAssertEqual(try JSONDecoder().decode(Int64.self, from: Data(item.value.utf8)), value)
        }
    }

    func testRejectInvalidInt64InRowsAndColumns() throws {
        for item in try loadProtocolFixture().invalidInt64 {
            let wire = try data(from: item)
            var decoder = Decoder(wire)
            _ = decoder.readSvarint()
            XCTAssertNotNil(decoder.error, item)
            var column = ColumnarDecoder(data: Data([1, 0, 1]) + wire)
            _ = column.nextColumn()
            _ = column.readColumnInt()
            XCTAssertNotNil(column.error, item)
        }
    }

    func testPrimitiveEncodingsMatchCanonicalFixture() throws {
        let fixture = try loadProtocolFixture().primitives

        assertEncoding(fixture.varint300) { $0.writeVarint(300) }
        assertEncoding(fixture.svarintNegative42) { $0.writeSvarint(-42) }
        try assertEncoding(fixture.fixed64OnePoint25) { try $0.writeFixed64(1.25) }
        assertEncoding(fixture.booleans) {
            $0.writeBool(true)
            $0.writeBool(false)
        }
        assertEncoding(fixture.utf8String) { $0.writeString("Luxo世界") }
        assertEncoding(fixture.bytes) { $0.writeBytes(Data([0x00, 0xff, 0x10])) }
        assertEncoding(fixture.uuid) {
            $0.writeUUID(UUID(uuidString: "01234567-89ab-cdef-0123-456789abcdef")!)
        }
        try assertEncoding(fixture.intArray) {
            try $0.writeArrayHeader(3)
            $0.writeSvarint(-3)
            $0.writeSvarint(0)
            $0.writeSvarint(9)
        }
        assertEncoding(fixture.nullableNull) { $0.writeBool(false) }
        assertEncoding(fixture.nullableString) {
            $0.writeBool(true)
            $0.writeString("Luxo")
        }
    }

    func testRequestsMatchCanonicalFixture() throws {
        let expected = try loadProtocolFixture().requests
        let schema = APISchema(
            id: 300,
            params: [
                .init(fieldID: 1, name: "int", type: "Int"),
                .init(fieldID: 2, name: "duration", type: "Duration"),
                .init(fieldID: 3, name: "float", type: "Float"),
                .init(fieldID: 4, name: "text", type: "String"),
                .init(fieldID: 5, name: "enum", type: "Enum"),
                .init(fieldID: 6, name: "decimal", type: "Decimal"),
                .init(fieldID: 7, name: "bool", type: "Boolean"),
                .init(fieldID: 8, name: "date", type: "DateTime"),
                .init(fieldID: 9, name: "uuid", type: "UUID"),
                .init(fieldID: 10, name: "bytes", type: "Bytes"),
                .init(fieldID: 11, name: "json", type: "JSON"),
                .init(fieldID: 12, name: "tags", type: "String", isList: true),
            ]
        )
        let body = try LuxoBinaryProtocol.encodeRequest(
            schema: schema,
            params: [
                "int": -3,
                "duration": 9,
                "float": 1.25,
                "text": "Luxo世界",
                "enum": "OPEN",
                "decimal": "12.50",
                "bool": true,
                "date": "1970-01-01T00:01:00Z",
                "uuid": "01234567-89ab-cdef-0123-456789abcdef",
                "bytes": .bytes(Data([0x00, 0xff])),
                "json": ["ok": true],
                "tags": ["a", "世界"],
            ]
        )
        XCTAssertEqual(body, try data(from: expected.allTypes))

        let nullableSchema = APISchema(
            id: 9,
            params: [
                .init(fieldID: 1, name: "nickname", type: "String", nullable: true),
                .init(fieldID: 2, name: "age", type: "Int", nullable: true),
            ]
        )
        XCTAssertEqual(
            try LuxoBinaryProtocol.encodeRequest(
                schema: nullableSchema,
                params: ["nickname": .null, "age": 42]
            ),
            try data(from: expected.nullable)
        )

        let selectedSchema = APISchema(
            id: 7,
            fields: [
                "id": .init(fieldID: 1),
                "profile": .init(fieldID: 3, typeName: "Profile"),
            ],
            types: ["Profile": ["displayName": .init(fieldID: 2)]]
        )
        XCTAssertEqual(
            try LuxoBinaryProtocol.encodeRequest(
                schema: selectedSchema,
                params: ["$select": "id, profile { displayName }"]
            ),
            try data(from: expected.selected)
        )
    }

    func testEnvelopesAndFramesMatchCanonicalFixture() throws {
        let fixture = try loadProtocolFixture()
        let envelope = try data(from: fixture.errorEnvelope)
        let error = LuxoBinaryProtocol.decodeError(envelope, statusCode: 400)

        XCTAssertEqual(error.code, 400)
        XCTAssertEqual(error.name, "BadRequest")
        XCTAssertEqual(error.message, "bad")
        XCTAssertEqual(error.traceId, "t")
        XCTAssertEqual((error.data as? [String: Any])?.count, 0)
        XCTAssertEqual(error.cause, "c")
        XCTAssertEqual(
            LuxoBinaryProtocol.callFrame(sequence: 253, body: Data([7, 0, 0])),
            try data(from: fixture.frames.callRequest)
        )
        XCTAssertEqual(
            LuxoWebSocketProtocol.decodeBinaryFrame(
                try data(from: fixture.frames.subscribeSuccess)
            ).flatMap(LuxoWebSocketProtocol.subscriptionAcknowledgement)?.id,
            253
        )
    }

    func testColumnarBatchMatchesCanonicalFixture() throws {
        let fixture = try loadProtocolFixture()
        var decoder = ColumnarDecoder(data: try data(from: fixture.columnar))

        XCTAssertEqual(decoder.count, 3)
        XCTAssertEqual(decoder.arenaSize, 7)
        XCTAssertTrue(decoder.nextColumn())
        XCTAssertEqual(decoder.fieldID, 1)
        XCTAssertEqual(decoder.readColumnInt(), [-3, 0, 9])
        XCTAssertTrue(decoder.nextColumn())
        XCTAssertEqual(decoder.fieldID, 2)
        XCTAssertEqual(decoder.readColumnString(), ["a", "世界", ""])
        XCTAssertTrue(decoder.nextColumn())
        XCTAssertEqual(decoder.fieldID, 3)
        XCTAssertEqual(decoder.readColumnBoolPtr(), [true, nil, false])
        XCTAssertFalse(decoder.nextColumn())
        XCTAssertNil(decoder.error)
    }

    private func assertEncoding(
        _ expectedHex: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        encode: (inout Encoder) throws -> Void
    ) rethrows {
        var encoder = Encoder()
        try encode(&encoder)
        XCTAssertEqual(encoder.data.hexEncoded, expectedHex, file: file, line: line)
    }

    private func data(from hex: String) throws -> Data {
        try XCTUnwrap(Data(hexEncoded: hex))
    }
}

private struct ProtocolFixture: Decodable {
    let dateTimeBoundaryCases: [UUIDCanonicalFixture]
    let jsonUnicodeCases: [JSONUnicodeFixture]
    let uuidCanonicalCases: [UUIDCanonicalFixture]
    let dateTimeCases: [DateTimeFixture]
    let jsonNumberConversions: [JSONNumberConversionFixture]
    let version: Int
    let int64Cases: [Int64Fixture]
    let invalidInt64: [String]
    let primitives: PrimitiveFixtures
    let requests: RequestFixtures
    let errorEnvelope: String
    let frames: FrameFixtures
    let columnar: String
}

private struct JSONUnicodeFixture: Decodable {
    let name, raw: String
    let valid: Bool
}

private struct UUIDCanonicalFixture: Decodable {
    let input: String
    let canonical: String?
}

private struct DateTimeFixture: Decodable, Sendable {
    let input: String
    let seconds: String
    let nanoseconds: UInt64
    let canonical: String
}

private struct JSONNumberConversionFixture: Decodable {
    let token: String
    let int64: String?
    let float64Bits: String?
}

private struct Int64Fixture: Decodable {
    let value: String
    let wire: String
}

private struct PrimitiveFixtures: Decodable {
    let varint300: String
    let svarintNegative42: String
    let fixed64OnePoint25: String
    let booleans: String
    let utf8String: String
    let bytes: String
    let uuid: String
    let intArray: String
    let nullableNull: String
    let nullableString: String
}

private struct RequestFixtures: Decodable {
    let allTypes: String
    let nullable: String
    let selected: String
}

private struct FrameFixtures: Decodable {
    let callRequest: String
    let subscribeSuccess: String
}

private func loadProtocolFixture() throws -> ProtocolFixture {
    let environment = ProcessInfo.processInfo.environment
    let bundled = try XCTUnwrap(
        Bundle.module.url(forResource: "protocol-v1", withExtension: "json", subdirectory: "Fixtures")
    )
    let url: URL
    if let path = environment["LUXO_PROTOCOL_FIXTURE"] {
        url = URL(fileURLWithPath: path)
        XCTAssertEqual(
            try Data(contentsOf: url), try Data(contentsOf: bundled),
            "The bundled protocol corpus must match the core fixture"
        )
    } else {
        url = bundled
    }
    let fixture = try JSONDecoder().decode(ProtocolFixture.self, from: Data(contentsOf: url))
    XCTAssertEqual(fixture.version, 1)
    return fixture
}

private extension Data {
    init?(hexEncoded: String) {
        guard hexEncoded.count.isMultiple(of: 2) else { return nil }
        self.init()
        reserveCapacity(hexEncoded.count / 2)
        var index = hexEncoded.startIndex
        while index < hexEncoded.endIndex {
            let next = hexEncoded.index(index, offsetBy: 2)
            guard let byte = UInt8(hexEncoded[index..<next], radix: 16) else { return nil }
            append(byte)
            index = next
        }
    }

    var hexEncoded: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
