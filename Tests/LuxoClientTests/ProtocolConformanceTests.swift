import Foundation
import XCTest
@testable import LuxoClient

final class ProtocolConformanceTests: XCTestCase {
    func testPrimitiveEncodingsMatchCanonicalFixture() throws {
        let fixture = try loadProtocolFixture().primitives

        assertEncoding(fixture.varint300) { $0.writeVarint(300) }
        assertEncoding(fixture.svarintNegative42) { $0.writeSvarint(-42) }
        assertEncoding(fixture.fixed64OnePoint25) { $0.writeFixed64(1.25) }
        assertEncoding(fixture.booleans) {
            $0.writeBool(true)
            $0.writeBool(false)
        }
        assertEncoding(fixture.utf8String) { $0.writeString("Luxo世界") }
        assertEncoding(fixture.bytes) { $0.writeBytes(Data([0x00, 0xff, 0x10])) }
        assertEncoding(fixture.uuid) {
            $0.writeUUID(UUID(uuidString: "01234567-89ab-cdef-0123-456789abcdef")!)
        }
        assertEncoding(fixture.intArray) {
            $0.writeArrayHeader(3)
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
            LuxoWebSocketProtocol.decodeBinarySubscriptionAcknowledgement(
                try data(from: fixture.frames.subscribeSuccess)
            )?.apiID,
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
        encode: (inout Encoder) -> Void
    ) {
        var encoder = Encoder()
        encode(&encoder)
        XCTAssertEqual(encoder.data.hexEncoded, expectedHex, file: file, line: line)
    }

    private func data(from hex: String) throws -> Data {
        try XCTUnwrap(Data(hexEncoded: hex))
    }
}

private struct ProtocolFixture: Decodable {
    let version: Int
    let primitives: PrimitiveFixtures
    let requests: RequestFixtures
    let errorEnvelope: String
    let frames: FrameFixtures
    let columnar: String
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
    let url: URL
    if let path = environment["LUXO_PROTOCOL_FIXTURE"] {
        url = URL(fileURLWithPath: path)
    } else {
        url = try XCTUnwrap(
            Bundle.module.url(forResource: "protocol-v1", withExtension: "json", subdirectory: "Fixtures")
        )
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
