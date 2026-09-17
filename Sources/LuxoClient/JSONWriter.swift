import Foundation

/// Writes directly from the transport tree, including validated raw number tokens.
struct JSONWriter {
    var bytes: [UInt8] = []

    static func encode(_ value: LuxoValue) throws -> Data {
        var writer = JSONWriter()
        try writer.value(value, depth: 0)
        return Data(writer.bytes)
    }

    mutating func value(_ value: LuxoValue, depth: Int) throws {
        guard depth <= 128 else {
            throw LuxoError(code: 0, message: "JSON nesting exceeds 128 levels", name: "EncodingError")
        }
        switch value {
        case .null: bytes.append(contentsOf: "null".utf8)
        case .bool(let value): bytes.append(contentsOf: (value ? "true" : "false").utf8)
        case .int(let value): bytes.append(contentsOf: String(value).utf8)
        case .float(let value):
            guard value.isFinite else {
                throw LuxoError(code: 0, message: "non-finite Float parameter", name: "EncodingError")
            }
            bytes.append(contentsOf: String(value).utf8)
        case .jsonNumber(let value): bytes.append(contentsOf: value.literal.utf8)
        case .string(let value): string(value)
        case .bytes(let value): string(value.base64EncodedString())
        case .array(let values): try array(values, depth: depth)
        case .object(let values): try object(values, depth: depth)
        case .structured(let value): try self.value(value.luxoJSONValue(), depth: depth + 1)
        }
    }

    private mutating func array(_ values: [LuxoValue], depth: Int) throws {
        bytes.append(91)
        for (index, item) in values.enumerated() {
            if index != 0 { bytes.append(44) }
            try value(item, depth: depth + 1)
        }
        bytes.append(93)
    }

    private mutating func object(_ values: [String: LuxoValue], depth: Int) throws {
        bytes.append(123)
        for (index, key) in values.keys.sorted().enumerated() {
            if index != 0 { bytes.append(44) }
            string(key)
            bytes.append(58)
            if let item = values[key] { try value(item, depth: depth + 1) }
        }
        bytes.append(125)
    }

    private mutating func string(_ value: String) {
        bytes.append(34)
        for byte in value.utf8 {
            switch byte {
            case 34, 92: bytes.append(92); bytes.append(byte)
            case 8: bytes.append(contentsOf: [92, 98])
            case 9: bytes.append(contentsOf: [92, 116])
            case 10: bytes.append(contentsOf: [92, 110])
            case 12: bytes.append(contentsOf: [92, 102])
            case 13: bytes.append(contentsOf: [92, 114])
            case 0..<32:
                bytes.append(contentsOf: [92, 117, 48, 48, hex(byte >> 4), hex(byte & 15)])
            default: bytes.append(byte)
            }
        }
        bytes.append(34)
    }

    private func hex(_ value: UInt8) -> UInt8 { value < 10 ? 48 + value : 87 + value }
}
