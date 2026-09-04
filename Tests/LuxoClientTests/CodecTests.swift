import XCTest
@testable import LuxoClient

final class CodecTests: XCTestCase {
    func testVarintRoundTrip() {
        var encoder = Encoder()
        encoder.writeVarint(300)
        var decoder = Decoder(encoder.data)
        XCTAssertEqual(decoder.readVarint(), 300)
    }

    func testSvarintRoundTrip() {
        var encoder = Encoder()
        encoder.writeSvarint(-42)
        encoder.writeSvarint(42)
        var decoder = Decoder(encoder.data)
        XCTAssertEqual(decoder.readSvarint(), -42)
        XCTAssertEqual(decoder.readSvarint(), 42)
    }

    func testStringRoundTrip() {
        var encoder = Encoder()
        encoder.writeString("hello 世界")
        var decoder = Decoder(encoder.data)
        XCTAssertEqual(decoder.readString(), "hello 世界")
    }

    func testBoolRoundTrip() {
        var encoder = Encoder()
        encoder.writeBool(true)
        encoder.writeBool(false)
        var decoder = Decoder(encoder.data)
        XCTAssertTrue(decoder.readBool())
        XCTAssertFalse(decoder.readBool())
    }

    func testFixed64RoundTrip() {
        var encoder = Encoder()
        encoder.writeFixed64(3.14)
        var decoder = Decoder(encoder.data)
        XCTAssertEqual(decoder.readFixed64(), 3.14, accuracy: 0.001)
    }

    func testFieldMask() {
        var mask: [UInt8] = []
        fieldMaskSet(&mask, fieldID: 1)
        fieldMaskSet(&mask, fieldID: 5)
        fieldMaskSet(&mask, fieldID: 16)

        XCTAssertTrue(fieldMaskHas(mask, fieldID: 1))
        XCTAssertTrue(fieldMaskHas(mask, fieldID: 5))
        XCTAssertTrue(fieldMaskHas(mask, fieldID: 16))
        XCTAssertFalse(fieldMaskHas(mask, fieldID: 0))
        XCTAssertFalse(fieldMaskHas(mask, fieldID: 2))
        XCTAssertFalse(fieldMaskHas(mask, fieldID: 17))
    }

    // MARK: - Edge Cases

    func testNegativeSvarints() {
        var encoder = Encoder()
        encoder.writeSvarint(-1)
        encoder.writeSvarint(Int64.min)
        encoder.writeSvarint(Int64.max)
        var decoder = Decoder(encoder.data)
        XCTAssertEqual(decoder.readSvarint(), -1)
        XCTAssertEqual(decoder.readSvarint(), Int64.min)
        XCTAssertEqual(decoder.readSvarint(), Int64.max)
    }

    func testEmptyString() {
        var encoder = Encoder()
        encoder.writeString("")
        var decoder = Decoder(encoder.data)
        XCTAssertEqual(decoder.readString(), "")
    }

    func testLargeVarint() {
        var encoder = Encoder()
        encoder.writeVarint(UInt64.max)
        encoder.writeVarint(0)
        encoder.writeVarint(UInt64.max / 2)
        var decoder = Decoder(encoder.data)
        XCTAssertEqual(decoder.readVarint(), UInt64.max)
        XCTAssertEqual(decoder.readVarint(), 0)
        XCTAssertEqual(decoder.readVarint(), UInt64.max / 2)
    }

    func testFixed64SpecialValues() {
        var encoder = Encoder()
        encoder.writeFixed64(0.0)
        encoder.writeFixed64(-0.0)
        encoder.writeFixed64(Double.infinity)
        encoder.writeFixed64(-Double.infinity)
        var decoder = Decoder(encoder.data)
        XCTAssertEqual(decoder.readFixed64(), 0.0)
        XCTAssertEqual(decoder.readFixed64(), -0.0)
        XCTAssertEqual(decoder.readFixed64(), Double.infinity)
        XCTAssertEqual(decoder.readFixed64(), -Double.infinity)
    }

    func testBytesRoundTrip() {
        var encoder = Encoder()
        let testData = Data([0x01, 0x02, 0xFF, 0x00, 0xAB])
        encoder.writeBytes(testData)
        var decoder = Decoder(encoder.data)
        XCTAssertEqual(decoder.readBytes(), testData)
    }

    func testEmptyBytes() {
        var encoder = Encoder()
        encoder.writeBytes(Data())
        var decoder = Decoder(encoder.data)
        XCTAssertEqual(decoder.readBytes(), Data())
    }

    func testWriteEnd() {
        var encoder = Encoder()
        encoder.writeEnd()
        XCTAssertEqual(encoder.data, Data([0x00]))
    }

    func testDecoderIsAtEnd() {
        var encoder = Encoder()
        encoder.writeBool(true)
        var decoder = Decoder(encoder.data)
        XCTAssertFalse(decoder.isAtEnd)
        _ = decoder.readBool()
        XCTAssertTrue(decoder.isAtEnd)
    }

    func testDecoderEmptyData() {
        var decoder = Decoder(Data())
        XCTAssertTrue(decoder.isAtEnd)
        // Reading from empty should return defaults
        XCTAssertEqual(decoder.readVarint(), 0)
        XCTAssertFalse(decoder.readBool())
        XCTAssertEqual(decoder.readFixed64(), 0)
        XCTAssertEqual(decoder.readString(), "")
        XCTAssertEqual(decoder.readBytes(), Data())
    }

    func testNextField() {
        var encoder = Encoder()
        encoder.writeVarint(5)  // field ID 5
        encoder.writeEnd()  // field ID 0 = end
        var decoder = Decoder(encoder.data)
        XCTAssertEqual(decoder.nextField(), 5)
        XCTAssertEqual(decoder.nextField(), 0)
    }

    func testWriteFieldInt() throws {
        var encoder = Encoder()
        try encoder.writeField(1, value: 99 as Int, type: "Int")
        var decoder = Decoder(encoder.data)
        XCTAssertEqual(decoder.readVarint(), 1)  // field ID
        XCTAssertEqual(decoder.readSvarint(), 99)
    }

    func testWriteFieldString() throws {
        var encoder = Encoder()
        try encoder.writeField(2, value: "test", type: "String")
        var decoder = Decoder(encoder.data)
        XCTAssertEqual(decoder.readVarint(), 2)  // field ID
        XCTAssertEqual(decoder.readString(), "test")
    }

    func testWriteFieldBool() throws {
        var encoder = Encoder()
        try encoder.writeField(3, value: true, type: "Boolean")
        var decoder = Decoder(encoder.data)
        XCTAssertEqual(decoder.readVarint(), 3)  // field ID
        XCTAssertTrue(decoder.readBool())
    }

    func testWriteFieldFloat() throws {
        var encoder = Encoder()
        try encoder.writeField(4, value: 2.718, type: "Float")
        var decoder = Decoder(encoder.data)
        XCTAssertEqual(decoder.readVarint(), 4)  // field ID
        XCTAssertEqual(decoder.readFixed64(), 2.718, accuracy: 0.0001)
    }

    func testFieldMaskOutOfRange() {
        let mask: [UInt8] = [0xFF]  // only byte 0 set
        XCTAssertFalse(fieldMaskHas(mask, fieldID: 9))
        XCTAssertFalse(fieldMaskHas(mask, fieldID: 100))
    }

    func testFieldMaskLargeFieldID() {
        var mask: [UInt8] = []
        fieldMaskSet(&mask, fieldID: 64)
        XCTAssertTrue(fieldMaskHas(mask, fieldID: 64))
        XCTAssertFalse(fieldMaskHas(mask, fieldID: 63))
        XCTAssertEqual(mask.count, 8)
    }

    // MARK: - ColumnarDecoder Tests

    func testColumnarDecode2Records() {
        var enc = Encoder()
        // count = 2
        enc.writeVarint(2)
        enc.writeVarint(10)  // arena size
        // Column 1: fieldID=1, int values [42, -7]
        enc.writeVarint(1)
        enc.writeSvarint(42)
        enc.writeSvarint(-7)
        // Column 2: fieldID=2, string values ["hello", "world"]
        enc.writeVarint(2)
        enc.writeString("hello")
        enc.writeString("world")
        // Column 3: fieldID=3, float values [3.14, 2.718]
        enc.writeVarint(3)
        enc.writeFixed64(3.14)
        enc.writeFixed64(2.718)
        // End marker
        enc.writeEnd()

        var dec = ColumnarDecoder(data: enc.data)
        XCTAssertEqual(dec.count, 2)
        XCTAssertEqual(dec.arenaSize, 10)

        XCTAssertTrue(dec.nextColumn())
        XCTAssertEqual(dec.fieldID, 1)
        let ints = dec.readColumnInt()
        XCTAssertEqual(ints, [42, -7])

        XCTAssertTrue(dec.nextColumn())
        XCTAssertEqual(dec.fieldID, 2)
        let strings = dec.readColumnString()
        XCTAssertEqual(strings, ["hello", "world"])

        XCTAssertTrue(dec.nextColumn())
        XCTAssertEqual(dec.fieldID, 3)
        let floats = dec.readColumnFloat()
        XCTAssertEqual(floats[0], 3.14, accuracy: 0.0001)
        XCTAssertEqual(floats[1], 2.718, accuracy: 0.0001)

        XCTAssertFalse(dec.nextColumn())
    }

    func testColumnarEmptyList() {
        var enc = Encoder()
        enc.writeVarint(0)  // count=0
        enc.writeVarint(0)  // arena size
        enc.writeEnd()  // end marker

        var dec = ColumnarDecoder(data: enc.data)
        XCTAssertEqual(dec.count, 0)
        XCTAssertFalse(dec.nextColumn())
    }

    func testColumnarNullableColumns() {
        var data = Data()
        // count = 3
        appendVarint(&data, 3)
        appendVarint(&data, 2)  // arena size
        // Column 1: fieldID=1, nullable int [null, 99, null]
        appendVarint(&data, 1)
        data.append(0x00)  // null
        data.append(0x01); appendSvarint(&data, 99)  // present
        data.append(0x00)  // null
        // Column 2: fieldID=2, nullable string [null, "hi", ""]
        appendVarint(&data, 2)
        data.append(0x00)  // null
        data.append(0x01); appendString(&data, "hi")  // present
        data.append(0x01); appendString(&data, "")  // present empty
        // End marker
        data.append(0x00)

        var dec = ColumnarDecoder(data: data)
        XCTAssertEqual(dec.count, 3)

        XCTAssertTrue(dec.nextColumn())
        XCTAssertEqual(dec.fieldID, 1)
        let nullInts = dec.readColumnIntPtr()
        XCTAssertNil(nullInts[0])
        XCTAssertEqual(nullInts[1], 99)
        XCTAssertNil(nullInts[2])

        XCTAssertTrue(dec.nextColumn())
        XCTAssertEqual(dec.fieldID, 2)
        let nullStrings = dec.readColumnStringPtr()
        XCTAssertNil(nullStrings[0])
        XCTAssertEqual(nullStrings[1], "hi")
        XCTAssertEqual(nullStrings[2], "")

        XCTAssertFalse(dec.nextColumn())
    }

    func testColumnarBoolColumn() {
        var enc = Encoder()
        enc.writeVarint(3)  // count=3
        enc.writeVarint(0)  // arena size
        enc.writeVarint(1)  // fieldID=1
        enc.writeVarint(1)  // true
        enc.writeVarint(0)  // false
        enc.writeVarint(1)  // true
        enc.writeEnd()

        var dec = ColumnarDecoder(data: enc.data)
        XCTAssertEqual(dec.count, 3)
        XCTAssertTrue(dec.nextColumn())
        XCTAssertEqual(dec.readColumnBool(), [true, false, true])
        XCTAssertFalse(dec.nextColumn())
    }

    func testColumnarOffsetAndReadSvarint() {
        var enc = Encoder()
        enc.writeVarint(0)  // count=0
        enc.writeVarint(0)  // arena size
        enc.writeEnd()  // end marker
        enc.writeSvarint(-42)  // pagination metadata

        var dec = ColumnarDecoder(data: enc.data)
        XCTAssertFalse(dec.nextColumn())
        XCTAssertEqual(dec.readSvarint(), -42)
    }

    // MARK: - Columnar Test Helpers

    private func appendVarint(_ data: inout Data, _ value: UInt64) {
        var v = value
        while v > 0x7F {
            data.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }

    private func appendSvarint(_ data: inout Data, _ value: Int64) {
        let encoded = UInt64(bitPattern: (value << 1) ^ (value >> 63))
        appendVarint(&data, encoded)
    }

    private func appendString(_ data: inout Data, _ value: String) {
        let bytes = Array(value.utf8)
        appendVarint(&data, UInt64(bytes.count))
        data.append(contentsOf: bytes)
    }

    // MARK: - UUID (fixed 16-byte)

    func testUUIDRoundTrip() {
        let uuid = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
        var encoder = Encoder()
        encoder.writeUUID(uuid)
        // UUID must be exactly 16 bytes — no length prefix.
        XCTAssertEqual(encoder.data.count, 16)
        var decoder = Decoder(encoder.data)
        XCTAssertEqual(decoder.readUUID(), uuid)
        XCTAssertTrue(decoder.isAtEnd)
    }

    func testUUIDWireBytes() {
        let uuid = UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!
        var encoder = Encoder()
        encoder.writeUUID(uuid)
        XCTAssertEqual(
            encoder.data,
            Data([
                0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
                0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
            ]))
    }

    func testUUIDTruncated() {
        var decoder = Decoder(Data([0x01, 0x02, 0x03]))  // < 16 bytes
        let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        XCTAssertEqual(decoder.readUUID(), zero)
    }

    func testUUIDPtr() {
        let uuid = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
        var encoder = Encoder()
        encoder.writeBool(true)  // present flag (0x01)
        encoder.writeUUID(uuid)
        encoder.writeBool(false)  // null flag (0x00)
        var decoder = Decoder(encoder.data)
        XCTAssertEqual(decoder.readUUIDPtr(), uuid)
        XCTAssertNil(decoder.readUUIDPtr())
    }

    func testWriteFieldUUID() throws {
        let uuid = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
        var encoder = Encoder()
        try encoder.writeField(7, value: uuid, type: "UUID")
        var decoder = Decoder(encoder.data)
        XCTAssertEqual(decoder.readVarint(), 7)  // field ID
        XCTAssertEqual(decoder.readUUID(), uuid)
    }

    func testWriteFieldUUIDFromString() throws {
        let str = "01234567-89AB-CDEF-0123-456789ABCDEF"
        var encoder = Encoder()
        try encoder.writeField(1, value: str, type: "UUID")
        var decoder = Decoder(encoder.data)
        _ = decoder.readVarint()
        XCTAssertEqual(decoder.readUUID(), UUID(uuidString: str)!)
    }

    // MARK: - Scalar Arrays (row form)

    func testUUIDArrayRowForm() {
        let u1 = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
        let u2 = UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!
        var encoder = Encoder()
        encoder.writeArrayHeader(2)
        encoder.writeUUID(u1)
        encoder.writeUUID(u2)
        var decoder = Decoder(encoder.data)
        let got = decoder.readArray { d in d.readUUID() }
        XCTAssertEqual(got, [u1, u2])
    }

    func testStringArrayRowForm() {
        var encoder = Encoder()
        encoder.writeArrayHeader(3)
        encoder.writeString("a")
        encoder.writeString("b")
        encoder.writeString("c")
        var decoder = Decoder(encoder.data)
        let got = decoder.readArray { d in d.readString() }
        XCTAssertEqual(got, ["a", "b", "c"])
    }

    func testIntArrayRowForm() {
        var encoder = Encoder()
        encoder.writeArrayHeader(3)
        encoder.writeSvarint(-1)
        encoder.writeSvarint(0)
        encoder.writeSvarint(42)
        var decoder = Decoder(encoder.data)
        let got = decoder.readArray { d in d.readSvarint() }
        XCTAssertEqual(got, [-1, 0, 42])
    }

    func testFieldListUUID() throws {
        let u1 = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
        let u2 = UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!
        var encoder = Encoder()
        try encoder.writeFieldList(3, values: [u1, u2], type: "UUID")
        var decoder = Decoder(encoder.data)
        XCTAssertEqual(decoder.readVarint(), 3)  // field ID
        let got = decoder.readArray { d in d.readUUID() }
        XCTAssertEqual(got, [u1, u2])
    }

    func testFieldListInt() throws {
        var encoder = Encoder()
        try encoder.writeFieldList(2, values: [Int64(1), Int64(-2), Int64(3)], type: "Int")
        var decoder = Decoder(encoder.data)
        XCTAssertEqual(decoder.readVarint(), 2)
        let got = decoder.readArray { d in d.readSvarint() }
        XCTAssertEqual(got, [1, -2, 3])
    }

    func testWriteFieldRejectsInvalidValuesWithoutPartialOutput() {
        let invalid: [(Any, String)] = [
            ("not-an-int", "Int"),
            ("not-a-float", "Float"),
            (0, "Boolean"),
            ("not-a-uuid", "UUID"),
            (0, "String"),
            ("not-a-date", "DateTime"),
            ("not-data", "Bytes"),
            (Date(), "JSON"),
            ("value", "Unknown"),
        ]
        for (value, type) in invalid {
            var encoder = Encoder()
            XCTAssertThrowsError(try encoder.writeField(1, value: value, type: type))
            XCTAssertTrue(encoder.data.isEmpty)
        }

        var listEncoder = Encoder()
        XCTAssertThrowsError(try listEncoder.writeFieldList(1, values: [1, "bad"], type: "Int"))
        XCTAssertTrue(listEncoder.data.isEmpty)
    }

    func testWriteFieldSupportsEveryCanonicalValueRepresentation() throws {
        var encoder = Encoder()
        try encoder.writeField(1, value: Int64(-9), type: "Duration")
        try encoder.writeField(2, value: Float(1.25), type: "Float")
        try encoder.writeField(3, value: "OPEN", type: "Enum")
        try encoder.writeField(4, value: "12.50", type: "Decimal")
        try encoder.writeField(5, value: Date(timeIntervalSince1970: 60), type: "DateTime")
        try encoder.writeField(6, value: Data([1, 2]), type: "Bytes")
        try encoder.writeField(7, value: JSONValue.bool(true), type: "JSON")
        try encoder.writeField(8, value: ["ok": true], type: "JSON")
        try encoder.writeField(9, value: "fragment", type: "JSON")

        var decoder = Decoder(encoder.data)
        XCTAssertEqual(decoder.nextField(), 1)
        XCTAssertEqual(decoder.readSvarint(), -9)
        XCTAssertEqual(decoder.nextField(), 2)
        XCTAssertEqual(decoder.readFixed64(), 1.25)
        XCTAssertEqual(decoder.nextField(), 3)
        XCTAssertEqual(decoder.readString(), "OPEN")
        XCTAssertEqual(decoder.nextField(), 4)
        XCTAssertEqual(decoder.readString(), "12.50")
        XCTAssertEqual(decoder.nextField(), 5)
        XCTAssertEqual(decoder.readSvarint(), 60)
        XCTAssertEqual(decoder.nextField(), 6)
        XCTAssertEqual(decoder.readBytes(), Data([1, 2]))
        XCTAssertEqual(decoder.nextField(), 7)
        XCTAssertEqual(decoder.readBytes(), Data("true".utf8))
        XCTAssertEqual(decoder.nextField(), 8)
        XCTAssertEqual(decoder.readBytes(), Data(#"{"ok":true}"#.utf8))
        XCTAssertEqual(decoder.nextField(), 9)
        XCTAssertEqual(decoder.readBytes(), Data(#""fragment""#.utf8))
        XCTAssertNil(decoder.error)
    }

    func testWriteFieldListUsesScalarCodecForEveryElement() throws {
        var dates = Encoder()
        try dates.writeFieldList(
            1,
            values: ["1970-01-01T00:01:00Z", Int64(120)],
            type: "DateTime"
        )
        var dateDecoder = Decoder(dates.data)
        XCTAssertEqual(dateDecoder.nextField(), 1)
        XCTAssertEqual(dateDecoder.readArray { $0.readSvarint() }, [60, 120])

        var values = Encoder()
        try values.writeFieldList(2, values: [true, false], type: "Boolean")
        var valueDecoder = Decoder(values.data)
        XCTAssertEqual(valueDecoder.nextField(), 2)
        XCTAssertEqual(valueDecoder.readArray { $0.readBool() }, [true, false])
    }

    // MARK: - Columnar UUID + scalar-array cells

    func testColumnarUUIDColumn() {
        let u1 = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
        let u2 = UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!
        var enc = Encoder()
        enc.writeVarint(2)  // count
        enc.writeVarint(0)  // arena size
        enc.writeVarint(1)  // fieldID=1
        enc.writeUUID(u1)
        enc.writeUUID(u2)
        enc.writeEnd()

        var dec = ColumnarDecoder(data: enc.data)
        XCTAssertEqual(dec.count, 2)
        XCTAssertTrue(dec.nextColumn())
        XCTAssertEqual(dec.readColumnUUID(), [u1, u2])
        XCTAssertFalse(dec.nextColumn())
    }

    func testColumnarUUIDPtrColumn() {
        let u1 = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
        var enc = Encoder()
        enc.writeVarint(3)  // count
        enc.writeVarint(0)  // arena size
        enc.writeVarint(1)  // fieldID=1
        enc.writeBool(false)  // null
        enc.writeBool(true); enc.writeUUID(u1)  // present
        enc.writeBool(false)  // null
        enc.writeEnd()

        var dec = ColumnarDecoder(data: enc.data)
        XCTAssertTrue(dec.nextColumn())
        let got = dec.readColumnUUIDPtr()
        XCTAssertNil(got[0])
        XCTAssertEqual(got[1], u1)
        XCTAssertNil(got[2])
    }

    func testColumnarScalarArrayCells() {
        // A [String] field becomes a Bytes column: each cell is a length-prefixed
        // blob containing an inline [count][items...] array.
        var cell0 = Encoder()
        cell0.writeArrayHeader(2)
        cell0.writeString("x")
        cell0.writeString("y")
        var cell1 = Encoder()
        cell1.writeArrayHeader(1)
        cell1.writeString("z")

        var enc = Encoder()
        enc.writeVarint(2)  // count
        enc.writeVarint(0)  // arena size
        enc.writeVarint(1)  // fieldID=1
        enc.writeBytes(cell0.data)  // length-prefixed blob
        enc.writeBytes(cell1.data)
        enc.writeEnd()

        var dec = ColumnarDecoder(data: enc.data)
        XCTAssertTrue(dec.nextColumn())
        let cells = dec.readColumnBytes()
        XCTAssertEqual(cells.count, 2)

        var d0 = Decoder(cells[0])
        XCTAssertEqual(d0.readArray { d in d.readString() }, ["x", "y"])
        var d1 = Decoder(cells[1])
        XCTAssertEqual(d1.readArray { d in d.readString() }, ["z"])
    }

    func testColumnarUUIDArrayCells() {
        let u1 = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
        let u2 = UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!
        var cell0 = Encoder()
        cell0.writeArrayHeader(2)
        cell0.writeUUID(u1)
        cell0.writeUUID(u2)

        var enc = Encoder()
        enc.writeVarint(1)  // count
        enc.writeVarint(0)  // arena size
        enc.writeVarint(1)  // fieldID=1
        enc.writeBytes(cell0.data)
        enc.writeEnd()

        var dec = ColumnarDecoder(data: enc.data)
        XCTAssertTrue(dec.nextColumn())
        let cells = dec.readColumnBytes()
        var d0 = Decoder(cells[0])
        XCTAssertEqual(d0.readArray { d in d.readUUID() }, [u1, u2])
    }

    func testMultipleStrings() {
        var encoder = Encoder()
        encoder.writeString("alpha")
        encoder.writeString("beta")
        encoder.writeString("gamma")
        var decoder = Decoder(encoder.data)
        XCTAssertEqual(decoder.readString(), "alpha")
        XCTAssertEqual(decoder.readString(), "beta")
        XCTAssertEqual(decoder.readString(), "gamma")
    }

    // MARK: - DateTime decode (svarint unix seconds -> RFC3339 String)

    func testReadDateTimeEpoch() {
        // unix 0 = 1970-01-01T00:00:00Z
        var encoder = Encoder()
        encoder.writeSvarint(0)
        var decoder = Decoder(encoder.data)
        XCTAssertEqual(decoder.readDateTime(), "1970-01-01T00:00:00Z")
    }

    func testReadDateTimeKnownTimestamp() {
        // unix 1626230400 = 2021-07-14T02:40:00Z
        var encoder = Encoder()
        encoder.writeSvarint(1_626_230_400)
        var decoder = Decoder(encoder.data)
        XCTAssertEqual(decoder.readDateTime(), "2021-07-14T02:40:00Z")
    }

    func testReadDateTimePtrPresent() {
        var encoder = Encoder()
        encoder.writeBool(true)  // null flag = present
        encoder.writeSvarint(1_626_230_400)
        var decoder = Decoder(encoder.data)
        XCTAssertEqual(decoder.readDateTimePtr(), "2021-07-14T02:40:00Z")
    }

    func testReadDateTimePtrNull() {
        var encoder = Encoder()
        encoder.writeBool(false)  // null flag = absent
        var decoder = Decoder(encoder.data)
        XCTAssertNil(decoder.readDateTimePtr())
    }

    // MARK: - Duration decode (svarint nanoseconds -> Int64 raw nanos)

    func testReadDurationSvarint() {
        // 1.5s = 1_500_000_000 ns; decoded as raw nanoseconds (Int64), matching JSON mode.
        var encoder = Encoder()
        encoder.writeSvarint(1_500_000_000)
        var decoder = Decoder(encoder.data)
        XCTAssertEqual(decoder.readSvarint(), 1_500_000_000)
    }

    func testReadDurationPtr() {
        var encoder = Encoder()
        encoder.writeBool(true)
        encoder.writeSvarint(250_000_000)  // 0.25s in nanos
        var decoder = Decoder(encoder.data)
        XCTAssertEqual(decoder.readIntPtr(), 250_000_000)

        var enc2 = Encoder()
        enc2.writeBool(false)
        var dec2 = Decoder(enc2.data)
        XCTAssertNil(dec2.readIntPtr())
    }

    // MARK: - Columnar DateTime / Duration

    func testColumnarDateTimeColumn() {
        var enc = Encoder()
        enc.writeArrayHeader(2)  // row count
        enc.writeVarint(0)  // arena size
        enc.writeVarint(7)  // field ID
        enc.writeSvarint(0)
        enc.writeSvarint(1_626_230_400)
        enc.writeEnd()

        var dec = ColumnarDecoder(data: enc.data)
        XCTAssertEqual(dec.count, 2)
        XCTAssertTrue(dec.nextColumn())
        XCTAssertEqual(dec.fieldID, 7)
        XCTAssertEqual(dec.readColumnDateTime(), ["1970-01-01T00:00:00Z", "2021-07-14T02:40:00Z"])
    }

    func testColumnarDateTimePtrColumn() {
        var enc = Encoder()
        enc.writeArrayHeader(2)
        enc.writeVarint(0)  // arena size
        enc.writeVarint(7)
        enc.writeBool(false)  // null
        enc.writeBool(true)  // present
        enc.writeSvarint(1_626_230_400)
        enc.writeEnd()

        var dec = ColumnarDecoder(data: enc.data)
        _ = dec.nextColumn()
        let got = dec.readColumnDateTimePtr()
        XCTAssertEqual(got.count, 2)
        XCTAssertNil(got[0])
        XCTAssertEqual(got[1], "2021-07-14T02:40:00Z")
    }

    func testColumnarDurationColumn() {
        // Duration columns are plain Int columns (raw nanoseconds).
        var enc = Encoder()
        enc.writeArrayHeader(2)
        enc.writeVarint(0)  // arena size
        enc.writeVarint(8)
        enc.writeSvarint(1_500_000_000)
        enc.writeSvarint(250_000_000)
        enc.writeEnd()

        var dec = ColumnarDecoder(data: enc.data)
        _ = dec.nextColumn()
        XCTAssertEqual(dec.readColumnInt(), [1_500_000_000, 250_000_000])
    }

    func testRejectsNonCanonicalBooleanAndNullableMarkers() {
        var boolDecoder = Decoder(Data([0x02]))
        XCTAssertFalse(boolDecoder.readBool())
        XCTAssertNotNil(boolDecoder.error)

        var nullableDecoder = Decoder(Data([0x02]))
        XCTAssertNil(nullableDecoder.readIntPtr())
        XCTAssertNotNil(nullableDecoder.error)
    }

    func testDecoderRejectsMalformedLengthsAndOversizedCollections() {
        var stringDecoder = Decoder(Data([0x02, 0x41]))
        XCTAssertEqual(stringDecoder.readString(), "")
        XCTAssertNotNil(stringDecoder.error)

        var utf8Decoder = Decoder(Data([0x01, 0xFF]))
        XCTAssertEqual(utf8Decoder.readString(), "")
        XCTAssertNotNil(utf8Decoder.error)

        var bytesDecoder = Decoder(Data([0x02, 0x01]))
        XCTAssertEqual(bytesDecoder.readBytes(), Data())
        XCTAssertNotNil(bytesDecoder.error)

        var arrayEncoder = Encoder()
        arrayEncoder.writeVarint(1_000_001)
        var arrayDecoder = Decoder(arrayEncoder.data)
        XCTAssertEqual(arrayDecoder.readArray { $0.readString() }, [])
        XCTAssertNotNil(arrayDecoder.error)
    }

    func testColumnarDecoderRejectsInvalidHeadersAndMissingTerminator() {
        var empty = ColumnarDecoder(data: Data())
        XCTAssertNotNil(empty.error)
        XCTAssertFalse(empty.nextColumn())

        var count = Encoder()
        count.writeVarint(10_000_001)
        let oversizedCount = ColumnarDecoder(data: count.data)
        XCTAssertNotNil(oversizedCount.error)

        var arena = Encoder()
        arena.writeVarint(0)
        arena.writeVarint(64 * 1024 * 1024 + 1)
        let oversizedArena = ColumnarDecoder(data: arena.data)
        XCTAssertNotNil(oversizedArena.error)

        var unterminated = Encoder()
        unterminated.writeVarint(0)
        unterminated.writeVarint(0)
        var missingTerminator = ColumnarDecoder(data: unterminated.data)
        XCTAssertFalse(missingTerminator.nextColumn())
        XCTAssertNotNil(missingTerminator.error)
    }

    func testColumnarDecoderRejectsTruncatedAndInvalidValues() {
        assertMalformedColumn(Data(), read: { $0.readColumnInt() })
        assertMalformedColumn(Data(repeating: 0, count: 7), read: { $0.readColumnFloat() })
        assertMalformedColumn(Data([0x02, 0x41]), read: { $0.readColumnString() })
        assertMalformedColumn(Data([0x01, 0xFF]), read: { $0.readColumnString() })
        assertMalformedColumn(Data([0x02]), read: { $0.readColumnBool() })
        assertMalformedColumn(Data([0x01]), read: { $0.readColumnIntPtr() })
        assertMalformedColumn(Data([0x01]), read: { $0.readColumnFloatPtr() })
        assertMalformedColumn(Data([0x01, 0x02, 0x41]), read: { $0.readColumnStringPtr() })
        assertMalformedColumn(Data([0x01, 0x02]), read: { $0.readColumnBoolPtr() })
        assertMalformedColumn(Data(repeating: 0, count: 15), read: { $0.readColumnUUID() })
        assertMalformedColumn(Data([0x01]), read: { $0.readColumnUUIDPtr() })
        assertMalformedColumn(Data([0x02, 0x01]), read: { $0.readColumnBytes() })
        assertMalformedColumn(Data([0x01, 0x02, 0x01]), read: { $0.readColumnBytesPtr() })
    }

    private func assertMalformedColumn<T>(
        _ payload: Data,
        read: (inout ColumnarDecoder) -> T
    ) {
        var encoder = Encoder()
        encoder.writeVarint(1)
        encoder.writeVarint(0)
        encoder.writeVarint(1)
        encoder.writeRawBytes(payload)
        var decoder = ColumnarDecoder(data: encoder.data)
        XCTAssertTrue(decoder.nextColumn())
        _ = read(&decoder)
        XCTAssertNotNil(decoder.error)
    }
}
