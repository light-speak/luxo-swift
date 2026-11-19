import Foundation

@inline(__always)
func requireJSONContainerDepth(_ depth: Int, name: String) throws {
    guard depth < 128 else {
        throw LuxoError(code: 0, message: "JSON nesting exceeds 128 levels", name: name)
    }
}

/// Writes directly from the transport tree, including validated raw number tokens.
struct JSONWriter {
    var bytes: [UInt8] = []

    static func encode(_ value: LuxoValue, genericJSON: Bool = false) throws -> Data {
        var writer = JSONWriter()
        try writer.value(value, depth: 0, genericJSON: genericJSON)
        return Data(writer.bytes)
    }

    mutating func value(_ value: LuxoValue, depth: Int, genericJSON: Bool = false) throws {
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
        case .bytes(let value):
            guard !genericJSON else { throw invalidJSONValue() }
            string(value.base64EncodedString())
        case .array(let values):
            try array(values, depth: depth) { writer, _, item in
                try writer.value(item, depth: depth + 1, genericJSON: genericJSON)
            }
        case .object(let values):
            try object(values, depth: depth) { writer, _, item in
                try writer.value(item, depth: depth + 1, genericJSON: genericJSON)
            }
        case .json(let value): try jsonValue(value, depth: genericJSON ? depth : 0)
        case .structured(let value):
            guard !genericJSON else { throw invalidJSONValue() }
            try structuredValue(.structured(value), models: 0, arrays: 0)
        }
    }

    private mutating func structuredValue(
        _ value: LuxoValue, models: Int, arrays: Int, projectedRoot: Bool = false
    ) throws {
        switch value {
        case .structured(let input):
            guard models < 64 else { throw JSONTreeEncoder.modelDepthError() }
            try structuredValue(input.luxoJSONValue(), models: models + 1, arrays: arrays, projectedRoot: true)
        case .object(let values):
            guard projectedRoot || models < 64 else { throw JSONTreeEncoder.modelDepthError() }
            let nested = projectedRoot ? models : models + 1
            try object(values, depth: 0) { writer, _, item in
                try writer.structuredValue(item, models: nested, arrays: arrays)
            }
        case .array(let values):
            try requireJSONContainerDepth(arrays, name: "EncodingError")
            try array(values, depth: 0) { writer, _, item in
                try writer.structuredValue(item, models: models, arrays: arrays + 1)
            }
        default: try self.value(value, depth: 0)
        }
    }

    private func invalidJSONValue() -> LuxoError {
        LuxoError(code: 0, message: "not a JSON value", name: "EncodingError")
    }

    private mutating func jsonValue(_ value: JSONValue, depth: Int) throws {
        switch value {
        case .array(let values):
            try array(values, depth: depth) { writer, _, item in
                try writer.jsonValue(item, depth: depth + 1)
            }
        case .object(let values):
            try object(values, depth: depth) { writer, _, item in
                try writer.jsonValue(item, depth: depth + 1)
            }
        default: try self.value(LuxoValue(value), depth: 0)
        }
    }

    mutating func array<Element>(
        _ values: [Element], depth: Int,
        write: (inout JSONWriter, Int, Element) throws -> Void
    ) throws {
        try requireJSONContainerDepth(depth, name: "EncodingError")
        bytes.append(91)
        for (index, item) in values.enumerated() {
            if index != 0 { bytes.append(44) }
            try write(&self, index, item)
        }
        bytes.append(93)
    }

    mutating func object<Element>(
        _ values: [String: Element], depth: Int,
        write: (inout JSONWriter, String, Element) throws -> Void
    ) throws {
        try requireJSONContainerDepth(depth, name: "EncodingError")
        bytes.append(123)
        for (index, key) in values.keys.sorted().enumerated() {
            if index != 0 { bytes.append(44) }
            string(key)
            bytes.append(58)
            if let item = values[key] { try write(&self, key, item) }
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
